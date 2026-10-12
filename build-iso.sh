#!/bin/bash
# ==============================================================================
# Debian Live ISO Builder — generic engine, distro identity lives in profiles/
# ==============================================================================
# This script builds a clean chroot base file system, installs packages from
# a profile's repo (or local builds), and packages everything into a bootable
# hybrid Live CD ISO image. What gets built — package list, extra APT repo,
# branding, boot menu text/theme — comes from profiles/<name>/ (see --profile).
#
# Usage:
#   ./build-iso.sh [--clean-base] [--clean-target] [--local] [--profile <name>] [--chroot]
#                  [--no-sequoia] [--sequoia]
#
# Options:
#   --clean-base    Delete the base Debian cache and download it from scratch.
#   --clean-target  Delete the working target rootfs and re-clone it from the base
#                    cache, even if one already exists from a previous run.
#   --local         Use local .deb packages from build/packages/ instead of the repo.
#   --profile       Distro profile to build, from profiles/<name>/. Default: pear.
#   --chroot        Drop into an interactive shell in the target rootfs right before
#                   compression (proc/sys/dev still mounted), then stop -- never falls
#                   through to packaging the ISO in the same run, even without --chroot
#                   errors. The target rootfs is never deleted automatically: if one
#                   already exists (from an earlier --chroot session, a finished build,
#                   or days ago), any run -- --chroot or plain -- reuses it as-is and
#                   skips repo/package install straight to chroot or to packaging.
#                   Pass --clean-target to force a fresh one.
#   --no-sequoia    Skip the macOS-Sequoia-style feature add-on (on by default).
#   --sequoia       Re-apply the Sequoia add-on to an already existing target rootfs.
#
# Safety:
#   By default the script NEVER installs packages on the host machine. If host
#   dependencies are missing it aborts with instructions. To allow host package
#   installation, run with ALLOW_HOST_INSTALL=true (dangerous on Arch hosts).
# ==============================================================================

set -e

# Save the original arguments before they get consumed by shift, for auto-elevation
ORIGINAL_ARGS=("$@")

# ==============================================================================
# Parse Arguments
# ==============================================================================
CLEAN_BASE=false
CLEAN_TARGET=false
USE_LOCAL_DEBS=false
BRANCH="stable"
WITH_NVIDIA=false
PULSAR_VERSION=""
PROFILE="pear"
DROP_TO_CHROOT=false
WITH_SEQUOIA=true
FORCE_SEQUOIA=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean-base)
            CLEAN_BASE=true
            shift
            ;;
        --clean-target)
            CLEAN_TARGET=true
            shift
            ;;
        --local)
            USE_LOCAL_DEBS=true
            shift
            ;;
        --nvidia)
            WITH_NVIDIA=true
            shift
            ;;
        --branch|-b)
            BRANCH="$2"
            shift 2
            ;;
        --version|-v)
            PULSAR_VERSION="$2"
            export PULSAR_VERSION
            shift 2
            ;;
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --chroot)
            DROP_TO_CHROOT=true
            shift
            ;;
        --no-sequoia)
            WITH_SEQUOIA=false
            shift
            ;;
        --sequoia)
            FORCE_SEQUOIA=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "$BRANCH" != "stable" ] && [ "$BRANCH" != "forky" ] && [ "$BRANCH" != "rolling" ]; then
    echo "Error: Branch must be 'stable', 'forky' or 'rolling'. Value received: $BRANCH"
    exit 1
fi

# ==============================================================================
# Load the distro profile
# ==============================================================================
ISO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ISO_DIR/build"
PROFILE_DIR="$ISO_DIR/profiles/$PROFILE"
if [ ! -d "$PROFILE_DIR" ]; then
    echo "Error: Unknown profile '$PROFILE' (expected directory: $PROFILE_DIR)"
    exit 1
fi
for required in profile.conf packages.list repo.sh packages.sh customize.sh; do
    if [ ! -f "$PROFILE_DIR/$required" ]; then
        echo "Error: Profile '$PROFILE' is missing $required"
        exit 1
    fi
done
source "$PROFILE_DIR/profile.conf"
source "$PROFILE_DIR/repo.sh"
source "$PROFILE_DIR/packages.sh"
source "$PROFILE_DIR/customize.sh"

# ==============================================================================
# Check Host Dependencies
# ==============================================================================
check_host_package_installed() {
    local pkg="$1"
    if command -v pacman >/dev/null 2>&1; then
        local arch_pkg="$pkg"
        case "$pkg" in
            mtools)
                arch_pkg="mtools"
                ;;
            debian-archive-keyring)
                arch_pkg="debian-archive-keyring"
                ;;
        esac
        pacman -Qs "^${arch_pkg}$" >/dev/null 2>&1
        return $?
    elif command -v dpkg >/dev/null 2>&1; then
        dpkg -l | grep -q "^ii\s\+${pkg}\b" >/dev/null 2>&1
        return $?
    else
        return 0
    fi
}

MISSING_PACKAGES=()

# Check standard commands
CMDS=("mmdebstrap" "fakeroot" "rsync" "jq" "curl" "unzip" "wget" "mksquashfs" "xorriso" "sassc")

for cmd in "${CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_PACKAGES+=("$cmd")
    fi
done

# Command to package name mapping for special cases
if ! command -v convert >/dev/null 2>&1; then
    MISSING_PACKAGES+=("imagemagick")
fi

if ! command -v fuser >/dev/null 2>&1; then
    MISSING_PACKAGES+=("psmisc")
fi

if ! check_host_package_installed "mtools"; then
    MISSING_PACKAGES+=("mtools")
fi

# IMPORTANT: Check Debian archive keyring on non-Debian host distros (like Ubuntu/Mint)
if [ ! -f "/usr/share/keyrings/debian-archive-keyring.gpg" ]; then
    MISSING_PACKAGES+=("debian-archive-keyring")
fi

# Install dependencies if they are missing
if [ ${#MISSING_PACKAGES[@]} -ne 0 ]; then
    echo "Essential dependencies detected to be missing from the host: ${MISSING_PACKAGES[*]}"
    echo "These tools are required for the ISO build."
    
    # SAFETY GUARD: never touch the host package manager by default.
    # The ISO build runs on the user's own machine (often Arch), and host-level
    # pacman/apt operations (especially 'pacman -Sy' partial upgrades) can break it.
    # Only auto-install when explicitly requested with --install-host-deps.
    if [ "$ALLOW_HOST_INSTALL" != "true" ]; then
        echo "Missing host dependencies. They will NOT auto-install to protect your system."
        echo "   Manually install missing packages (e.g. sudo pacman -S ${MISSING_PACKAGES[*]})"
        echo "   or repeat the command with the variable ALLOW_HOST_INSTALL=true to authorize the installation."
        exit 1
    fi
    
    # Auto-approve if in non-interactive environment (CI, pipeline, no TTY stdin)
    auto_install=false
    if [ "$GITHUB_ACTIONS" = "true" ] || [ ! -t 0 ]; then
        auto_install=true
    else
        read -p "Do you want to install the missing dependencies now? (y/n):" confirm
        confirm=$(echo "$confirm" | tr -d '\r')
        if [[ "$confirm" =~ ^[sSyY]$ ]] || [ -z "$confirm" ]; then
            auto_install=true
        fi
    fi
    
    if [ "$auto_install" = true ]; then
        # Detect package manager and install mapped packages
        pkg_manager=""
        if command -v pacman >/dev/null 2>&1; then
            pkg_manager="pacman"
        elif command -v apt-get >/dev/null 2>&1; then
            pkg_manager="apt"
        fi

        if [ -z "$pkg_manager" ]; then
            echo "Error: A supported package manager (apt or pacman) was not detected."
            exit 1
        fi

        packages_to_install=()
        for item in "${MISSING_PACKAGES[@]}"; do
            case "$item" in
                mmdebstrap|fakeroot|rsync|jq|curl|unzip|wget|xorriso|imagemagick|psmisc|mtools|debian-archive-keyring|sassc)
                    packages_to_install+=("$item")
                    ;;
                mksquashfs)
                    packages_to_install+=("squashfs-tools")
                    ;;
                *)
                    packages_to_install+=("$item")
                    ;;
            esac
        done

        # Deduplicate
        packages_to_install=($(echo "${packages_to_install[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

        if [ ${#packages_to_install[@]} -gt 0 ]; then
            echo "Installing dependencies on the host using $pkg_manager..."
            if [ "$pkg_manager" = "pacman" ]; then
                # Separate official pacman packages from AUR packages
                pacman_official=()
                aur_packages=()
                for pkg in "${packages_to_install[@]}"; do
                    if pacman -Si "$pkg" >/dev/null 2>&1; then
                        pacman_official+=("$pkg")
                    else
                        aur_packages+=("$pkg")
                    fi
                done

                if [ ${#pacman_official[@]} -gt 0 ]; then
                    echo "Installing official dependencies using pacman..."
                    if command -v pkexec >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
                        pkexec pacman -S --needed --noconfirm "${pacman_official[@]}"
                    else
                        sudo pacman -S --needed --noconfirm "${pacman_official[@]}"
                    fi
                fi

                if [ ${#aur_packages[@]} -gt 0 ]; then
                    echo "The following packages are from the AUR repository and are not in the official repos:"
                    echo "   ${aur_packages[*]}"
                    
                    # Try to locate an AUR helper
                    aur_helper=""
                    if command -v yay >/dev/null 2>&1; then
                        aur_helper="yay"
                    elif command -v paru >/dev/null 2>&1; then
                        aur_helper="paru"
                    fi

                    if [ -n "$aur_helper" ]; then
                        echo "An AUR helper has been detected: $aur_helper. Installing..."
                        # Run AUR helper as the original non-root user if SUDO_USER is defined
                        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                            sudo -u "$SUDO_USER" "$aur_helper" -S --noconfirm "${aur_packages[@]}"
                        else
                            "$aur_helper" -S --noconfirm "${aur_packages[@]}"
                        fi
                    else
                        echo "No AUR helper (like yay or paru) detected."
                        echo "Please install these packages manually before continuing:"
                        echo "   yay -S ${aur_packages[*]}"
                        exit 1
                    fi
                fi
            elif [ "$pkg_manager" = "apt" ]; then
                if command -v pkexec >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
                    pkexec /bin/bash -c "apt-get update && apt-get install -y ${packages_to_install[*]}"
                else
                    sudo apt-get update && sudo apt-get install -y "${packages_to_install[@]}"
                fi
            fi
            echo "Successfully installed dependencies."
        else
            echo "There are no packages to install for your platform."
        fi
    else
        echo "Error: Host requirements cannot be met. Going out..."
        exit 1
    fi
fi

# ==============================================================================
# Helper: Auto-Elevate to Root
# ==============================================================================
if [ "$EUID" -ne 0 ]; then
    echo "This script requires superuser privileges to run."
    echo "Re-executing with pkexec..."
    if command -v pkexec >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
        exec pkexec "$0" "${ORIGINAL_ARGS[@]}"
    else
        exec sudo "$0" "${ORIGINAL_ARGS[@]}"
    fi
fi

SUDO=""

# ==============================================================================
# PHASE 1: Environment Settings and Initialization
# ==============================================================================

# Import global configs if present
if [ -f "../configs/env.sh" ]; then
    source ../configs/env.sh
elif [ -f "configs/env.sh" ]; then
    source configs/env.sh
else
    ARCH="amd64"
    MIRROR="http://deb.debian.org/debian"
fi

# Override Debian version based on the selected branch
case "$BRANCH" in
    stable)
        DEBIAN_VERSION="trixie"
        ;;
    forky)
        DEBIAN_VERSION="forky"
        ;;
    rolling)
        DEBIAN_VERSION="testing"
        ;;
esac

if $WITH_NVIDIA; then
    ROOTFS_BASE="$BUILD_DIR/rootfs-base-$BRANCH-nvidia"
    ROOTFS_TARGET="$BUILD_DIR/rootfs-target-$BRANCH-nvidia"
else
    ROOTFS_BASE="$BUILD_DIR/rootfs-base-$BRANCH"
    ROOTFS_TARGET="$BUILD_DIR/rootfs-target-$BRANCH"
fi

PACKAGE_LIST_FILE="$PROFILE_DIR/packages.list"

# Adjust paths / Fallback to root repo configuration if local config is missing
if [ ! -f "$PACKAGE_LIST_FILE" ]; then
    PACKAGE_LIST_FILE="$ISO_DIR/../profiles/$PROFILE/packages.list"
fi

# Dynamic detection of chroot binary path
CHROOT_BIN=$(command -v chroot || echo "/usr/sbin/chroot")

# ==============================================================================
# Sequoia add-on: macOS-Sequoia-style features for the KDE Plasma image
# ==============================================================================
# Runs in two steps so it can see the pearOS APT repo and not be overwritten by
# the profile's own branding:
#   sequoia_install_packages  -> just before profile_teardown_repo (repo still on)
#   sequoia_configure         -> right after profile_customize (config wins)
# Skip it entirely with --no-sequoia. Re-run it on an existing target rootfs with
# --sequoia. Environment knobs:
#   SEQ_ONLINE=0              don't fetch anything from GitHub (WhiteSur themes)
#   SEQ_NATURAL_SCROLL=0      leave touchpad scroll direction / tap-to-click alone
#   SEQ_PEAR_PKGS="a b c"     pearOS packages to try from the profile's repo
# Own wallpapers: put images in profiles/<name>/wallpapers/ (Apple's Sequoia
# wallpapers are copyrighted, so none are bundled or downloaded).
SEQ_ONLINE="${SEQ_ONLINE:-1}"
SEQ_NATURAL_SCROLL="${SEQ_NATURAL_SCROLL:-1}"
SEQ_PEAR_PKGS="${SEQ_PEAR_PKGS:-pearos-appmenu pearos-dock pearos-keyring}"

seq_log() { echo "[sequoia] $*"; }

seq_chroot() {
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /usr/bin/env DEBIAN_FRONTEND=noninteractive "$@"
}

# Install packages one at a time so a package missing from this suite/repo
# never aborts the whole build.
seq_apt_try() {
    local p rc=0
    for p in "$@"; do
        if seq_chroot apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1; then
            seq_log "  + $p"
        else
            seq_log "  - $p (not available, skipped)"
            rc=1
        fi
    done
    return $rc
}

seq_git_install() {   # seq_git_install <name> <git url> <install command run inside the clone>
    seq_log "Fetching $1 from GitHub..."
    seq_chroot /bin/bash -c "set -e; d=\$(mktemp -d); trap 'rm -rf \"\$d\"' EXIT; cd \"\$d\"; GIT_TERMINAL_PROMPT=0 git clone --depth 1 '$2' src; cd src; $3" >/dev/null 2>&1 \
        || seq_log "  $1 failed (network or upstream change), skipped"
}

sequoia_install_packages() {
    $WITH_SEQUOIA || return 0
    seq_log "Installing Sequoia-style feature packages..."
    seq_chroot apt-get update >/dev/null 2>&1 || seq_log "apt-get update failed (no network?)"

    # Sequoia feature            -> open-source stand-in
    seq_apt_try keepassxc || true                                   # Passwords app
    seq_apt_try qalculate-qt || seq_apt_try qalculate-gtk || true   # Math Notes (closest match, not a clone)
    seq_apt_try kdeconnect scrcpy || true                           # Phone link / notification mirroring / Android mirroring
    seq_apt_try uxplay usbmuxd libimobiledevice-utils ifuse gvfs-backends || true  # iPhone Mirroring: AirPlay mirror + USB access
    seq_apt_try warpinator || true                                  # AirDrop-style local file sharing
    seq_apt_try gamemode || true                                    # Game Mode
    seq_apt_try fonts-inter fonts-noto-color-emoji || true          # SF / Apple Color Emoji look-alikes (installed, not forced)
    seq_apt_try libkf6config-bin spectacle || true                  # kwriteconfig6 for the config step; screenshot tool

    # pearOS open-source components from the profile's own repo (no-op if already installed)
    local p
    for p in $SEQ_PEAR_PKGS; do seq_apt_try "$p" || true; done

    if [ "$SEQ_ONLINE" = "1" ]; then
        seq_apt_try git sassc ca-certificates libglib2.0-dev-bin || true
        seq_git_install WhiteSur-gtk-theme  https://github.com/vinceliuice/WhiteSur-gtk-theme.git  "./install.sh -d /usr/share/themes"
        seq_git_install WhiteSur-icon-theme https://github.com/vinceliuice/WhiteSur-icon-theme.git "./install.sh -d /usr/share/icons"
        seq_git_install WhiteSur-kde        https://github.com/vinceliuice/WhiteSur-kde.git        "./install.sh"
        seq_log "WhiteSur themes are installed and selectable in System Settings (not forced as default)."
    fi
}

SEQ_KW=""
SEQ_TARGETS=()

# seq_kw <file> <group> <key> <value>   (writes into /etc/skel and every existing home)
seq_kw() {
    local t
    for t in "${SEQ_TARGETS[@]}"; do
        seq_chroot mkdir -p "$t/.config"
        seq_chroot chown --reference="$t" "$t/.config" 2>/dev/null || true
        seq_chroot "$SEQ_KW" --file "$t/.config/$1" --group "$2" --key "$3" "$4" || true
        seq_chroot chown --reference="$t" "$t/.config/$1" 2>/dev/null || true
    done
}

# seq_kw2 <file> <group> <subgroup> <key> <value>
seq_kw2() {
    local t
    for t in "${SEQ_TARGETS[@]}"; do
        seq_chroot mkdir -p "$t/.config"
        seq_chroot chown --reference="$t" "$t/.config" 2>/dev/null || true
        seq_chroot "$SEQ_KW" --file "$t/.config/$1" --group "$2" --group "$3" --key "$4" "$5" || true
        seq_chroot chown --reference="$t" "$t/.config/$1" 2>/dev/null || true
    done
}

sequoia_configure() {
    $WITH_SEQUOIA || return 0
    seq_log "Configuring Sequoia-style tiling, shortcuts and wallpaper..."

    SEQ_KW="$(seq_chroot /bin/sh -c 'command -v kwriteconfig6 || ls /usr/lib/*/libexec/kf6/kwriteconfig6 2>/dev/null | head -n1' 2>/dev/null)" || SEQ_KW=""
    SEQ_TARGETS=(/etc/skel)
    local h
    for h in "$ROOTFS_TARGET"/home/*; do
        [ -d "$h" ] && SEQ_TARGETS+=("${h#"$ROOTFS_TARGET"}")
    done || true

    if [ -n "$SEQ_KW" ]; then
        local TAB=$'\t'
        # Window tiling: drag to a screen edge, Ctrl+Meta+Arrow for halves
        # (existing Meta+Arrow keeps working), Ctrl+Meta+Shift+Arrow for quarters.
        seq_kw kwinrc Windows ElectricBorderTiling true
        seq_kw kwinrc Windows ElectricBorderMaximize true
        seq_kw kglobalshortcutsrc kwin "Window Quick Tile Left"   "Meta+Left${TAB}Meta+Ctrl+Left,Meta+Left,Quick Tile Window to the Left"
        seq_kw kglobalshortcutsrc kwin "Window Quick Tile Right"  "Meta+Right${TAB}Meta+Ctrl+Right,Meta+Right,Quick Tile Window to the Right"
        seq_kw kglobalshortcutsrc kwin "Window Quick Tile Top"    "Meta+Up${TAB}Meta+Ctrl+Up,Meta+Up,Quick Tile Window to the Top"
        seq_kw kglobalshortcutsrc kwin "Window Quick Tile Bottom" "Meta+Down${TAB}Meta+Ctrl+Down,Meta+Down,Quick Tile Window to the Bottom"
        seq_kw kglobalshortcutsrc kwin "Window Quick Tile Top Left"     "Meta+Ctrl+Shift+Left,none,Quick Tile Window to the Top Left"
        seq_kw kglobalshortcutsrc kwin "Window Quick Tile Top Right"    "Meta+Ctrl+Shift+Up,none,Quick Tile Window to the Top Right"
        seq_kw kglobalshortcutsrc kwin "Window Quick Tile Bottom Right" "Meta+Ctrl+Shift+Right,none,Quick Tile Window to the Bottom Right"
        seq_kw kglobalshortcutsrc kwin "Window Quick Tile Bottom Left"  "Meta+Ctrl+Shift+Down,none,Quick Tile Window to the Bottom Left"
        seq_kw kglobalshortcutsrc kwin "Window Maximize" "Meta+PgUp${TAB}Meta+Ctrl+F,Meta+PgUp,Maximize Window"

        # Mac-style extras (the original keys keep working)
        seq_kw kglobalshortcutsrc kwin "Walk Through Windows of Current Application" "Alt+\`${TAB}Meta+\`,Alt+\`,Walk Through Windows of Current Application"
        seq_kw kglobalshortcutsrc kwin "Kill Window"   "Ctrl+Alt+Esc${TAB}Meta+Alt+Esc,Ctrl+Alt+Esc,Kill Window"
        seq_kw kglobalshortcutsrc ksmserver "Lock Session" "Meta+L${TAB}Ctrl+Meta+Q${TAB}Screensaver,Meta+L${TAB}Screensaver,Lock Session"
        # Screenshots like Shift+Cmd+3 / 4 / 5
        seq_kw2 kglobalshortcutsrc services org.kde.spectacle.desktop FullScreenScreenShot        "Shift+Print${TAB}Meta+Shift+3,Shift+Print,Capture Entire Desktop"
        seq_kw2 kglobalshortcutsrc services org.kde.spectacle.desktop RectangularRegionScreenShot "Meta+Shift+Print${TAB}Meta+Shift+4,Meta+Shift+Print,Capture Rectangular Region"
        seq_kw2 kglobalshortcutsrc services org.kde.spectacle.desktop _launch                     "Print${TAB}Meta+Shift+5,Print,Launch Spectacle"
    else
        seq_log "kwriteconfig6 not found (is Plasma installed?), tiling/shortcut config skipped."
    fi

    # macOS-style touchpad: natural scrolling + tap to click (Xorg/libinput; Wayland
    # sessions use their own per-device settings in System Settings).
    if [ "$SEQ_NATURAL_SCROLL" = "1" ]; then
        $SUDO mkdir -p "$ROOTFS_TARGET/etc/X11/xorg.conf.d"
        cat <<'EOF' | $SUDO tee "$ROOTFS_TARGET/etc/X11/xorg.conf.d/40-sequoia-touchpad.conf" > /dev/null
Section "InputClass"
    Identifier "Sequoia touchpad"
    MatchIsTouchpad "on"
    MatchDriver "libinput"
    Option "NaturalScrolling" "true"
    Option "Tapping" "on"
    Option "ClickMethod" "clickfinger"
EndSection
EOF
    fi

    # Wallpapers supplied by you in profiles/<name>/wallpapers/
    if compgen -G "$PROFILE_DIR/wallpapers/*" >/dev/null; then
        local first
        $SUDO mkdir -p "$ROOTFS_TARGET/usr/share/backgrounds/sequoia" \
                       "$ROOTFS_TARGET/usr/local/bin" \
                       "$ROOTFS_TARGET/etc/skel/.config/autostart"
        $SUDO cp -a "$PROFILE_DIR"/wallpapers/* "$ROOTFS_TARGET/usr/share/backgrounds/sequoia/"
        first="$(ls -1 "$ROOTFS_TARGET/usr/share/backgrounds/sequoia" | head -n1)"
        cat <<EOF | $SUDO tee "$ROOTFS_TARGET/usr/local/bin/sequoia-wallpaper" > /dev/null
#!/bin/sh
flag="\$HOME/.config/.sequoia-wallpaper-set"
[ -e "\$flag" ] && exit 0
plasma-apply-wallpaperimage "/usr/share/backgrounds/sequoia/$first" && touch "\$flag"
EOF
        $SUDO chmod 0755 "$ROOTFS_TARGET/usr/local/bin/sequoia-wallpaper"
        cat <<'EOF' | $SUDO tee "$ROOTFS_TARGET/etc/skel/.config/autostart/sequoia-wallpaper.desktop" > /dev/null
[Desktop Entry]
Type=Application
Name=Sequoia wallpaper
Exec=/usr/local/bin/sequoia-wallpaper
X-KDE-autostart-phase=2
EOF
        for h in "$ROOTFS_TARGET"/home/*; do
            [ -d "$h" ] || continue
            $SUDO mkdir -p "$h/.config/autostart"
            $SUDO cp "$ROOTFS_TARGET/etc/skel/.config/autostart/sequoia-wallpaper.desktop" "$h/.config/autostart/"
            $SUDO chown -R --reference="$h" "$h/.config/autostart" 2>/dev/null || true
        done
    fi

    seq_chroot apt-get clean >/dev/null 2>&1 || true
    seq_log "Sequoia features done."
}

# Preventative cleanup function to ensure filesystems are unmounted on interruption
cleanup() {
    echo "Terminating and freeing chroot-mounted resources..."
    # Generic sweep (covers ROOTFS_TARGET, ROOTFS_BASE, and anything else
    # mounted under $BUILD_DIR) instead of two hardcoded path lists, so an
    # incremental install into either one (see install_packages_into) is
    # unmounted correctly too, including on a failure exit via set -e.
    awk '$2 ~ "^'"$BUILD_DIR"'/" || $2 == "'"$BUILD_DIR"'" {print $2}' /proc/self/mounts 2>/dev/null | sort -r | while read -r mp; do
        $SUDO umount -l "$mp" 2>/dev/null || true
    done

    # Restore original DNS config if a backup exists
    for dir in "$ROOTFS_TARGET" "$ROOTFS_BASE"; do
        if [ -f "$dir/etc/resolv.conf.bak" ]; then
            $SUDO mv "$dir/etc/resolv.conf.bak" "$dir/etc/resolv.conf" 2>/dev/null || true
        fi
    done
}

# Install packages directly into an already-bootstrapped rootfs (base or
# target) without a full mmdebstrap/clone -- used for additive
# packages.list changes (see PHASE 2) so appending a package doesn't force
# rebuilding everything from scratch.
install_packages_into() {
    local dir="$1"
    shift
    $SUDO mount -t proc proc "$dir/proc"
    $SUDO mount -t sysfs sys "$dir/sys"
    $SUDO mount --bind /dev "$dir/dev"
    $SUDO mount --bind /dev/pts "$dir/dev/pts"
    if [ -f "$dir/etc/resolv.conf" ]; then
        $SUDO cp "$dir/etc/resolv.conf" "$dir/etc/resolv.conf.bak"
    fi
    echo "nameserver 8.8.8.8" | $SUDO tee "$dir/etc/resolv.conf" > /dev/null

    $SUDO "$CHROOT_BIN" "$dir" /bin/bash -c "
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends $*
        apt-get clean
    "

    $SUDO umount -l "$dir/dev/pts" 2>/dev/null || true
    $SUDO umount -l "$dir/dev" 2>/dev/null || true
    $SUDO umount -l "$dir/sys" 2>/dev/null || true
    $SUDO umount -l "$dir/proc" 2>/dev/null || true
    if [ -f "$dir/etc/resolv.conf.bak" ]; then
        $SUDO mv "$dir/etc/resolv.conf.bak" "$dir/etc/resolv.conf"
    fi
}

# Preflight: release any leftover mounts from previous interrupted builds.
# This runs once at startup so a fresh build never fails on stale mounts.
preflight_cleanup() {
    echo "Checking residual mounts from previous builds..."
    # Unmount anything mounted under the build directory (leftover chroot mounts)
    awk '$2 ~ "^'"$BUILD_DIR"'/" || $2 == "'"$BUILD_DIR"'" {print $2}' /proc/self/mounts 2>/dev/null | sort -r | while read -r mp; do
        echo "   Unmounting $mp"
        $SUDO umount -l "$mp" 2>/dev/null || true
    done
    # Free known helper mount points (e.g. ISO verification leftovers)
    for mp in /tmp/iso-mnt /tmp/pulsar-verify /tmp/pulsar-iso; do
        if mountpoint -q "$mp" 2>/dev/null; then
            echo "   Unmounting residual: $mp"
            $SUDO umount -l "$mp" 2>/dev/null || true
        fi
    done
    echo "Residual mnt check completed."
}

trap cleanup EXIT INT TERM
preflight_cleanup

# ==============================================================================
# PHASE 2: Build and Maintain Base Cache
# ==============================================================================

# Auto-cleanup if previous bootstrap was incomplete or corrupted
if [ -d "$ROOTFS_BASE" ] && { [ ! -d "$ROOTFS_BASE/etc" ] || [ ! -d "$ROOTFS_BASE/proc" ] || [ ! -d "$ROOTFS_BASE/boot" ]; }; then
    echo "Incomplete or corrupt base cache detected. Cleaning to regenerate..."
    cleanup
    $SUDO rm -rf "$ROOTFS_BASE"
fi

# Detect if the package list has changed since the cache was created
base_list_changed=false
added_packages=()
removed_packages=()
if [ -d "$ROOTFS_BASE" ] && [ -f "$PACKAGE_LIST_FILE" ]; then
    # Generate the current list of packages to install (line-separated, no comments or empty lines)
    if $WITH_NVIDIA; then
        current_list=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$')
    else
        current_list=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | grep -v -E 'nvidia-driver|nvidia-settings|broadcom-sta-dkms|dkms|linux-headers-amd64')
    fi

    if [ ! -f "$ROOTFS_BASE/etc/build-base-packages.list" ]; then
        echo "build-base-packages.list was not found in the cache. Regenerating base..."
        base_list_changed=true
    else
        cached_list=$(cat "$ROOTFS_BASE/etc/build-base-packages.list")
        if [ "$current_list" != "$cached_list" ]; then
            base_list_changed=true
            mapfile -t added_packages < <(comm -13 <(sort <<<"$cached_list") <(sort <<<"$current_list"))
            mapfile -t removed_packages < <(comm -23 <(sort <<<"$cached_list") <(sort <<<"$current_list"))
        fi
    fi
fi

# A pure addition (nothing removed/renamed) can be installed straight into
# the existing base -- and existing target, if any -- instead of paying for
# a full mmdebstrap rebuild + re-clone just to pick up one new package.
INCREMENTAL_BASE_UPDATE=false
if $base_list_changed && ! $CLEAN_BASE && [ ${#removed_packages[@]} -eq 0 ] && [ ${#added_packages[@]} -gt 0 ]; then
    INCREMENTAL_BASE_UPDATE=true
fi

if $INCREMENTAL_BASE_UPDATE; then
    echo "Package list grew by ${#added_packages[@]} package(s) since the cached base -- installing just those instead of a full rebuild: ${added_packages[*]}"
    install_packages_into "$ROOTFS_BASE" "${added_packages[@]}"
    printf '%s\n' "$current_list" | $SUDO tee "$ROOTFS_BASE/etc/build-base-packages.list" > /dev/null
    echo "Base cache updated in place: $ROOTFS_BASE"
    if [ -d "$ROOTFS_TARGET/etc" ] && ! $CLEAN_TARGET; then
        echo "Applying the same new package(s) to the existing target rootfs..."
        install_packages_into "$ROOTFS_TARGET" "${added_packages[@]}"
        echo "Existing target rootfs updated in place: $ROOTFS_TARGET"
    fi
elif $CLEAN_BASE || [ "$base_list_changed" = true ]; then
    echo "Base cache cleanup requested or package list change detected..."
    cleanup
    $SUDO rm -rf "$ROOTFS_BASE"
    # The target was cloned from the old base -- force a re-clone in Phase 3
    # even if it already exists, so it doesn't keep drifting from a base that
    # no longer matches it.
    CLEAN_TARGET=true
fi

if [ ! -d "$ROOTFS_BASE/etc" ]; then
    mkdir -p "$BUILD_DIR"
    
    if [ ! -f "$PACKAGE_LIST_FILE" ]; then
        echo "Error: Base packages file not found in: $PACKAGE_LIST_FILE"
        exit 1
    fi
    
    echo "--- Creating Clean Debian Base (mmdebstrap) ---"

    if $WITH_NVIDIA; then
        echo "Including proprietary hardware drivers (NVIDIA, Broadcom STA, DKMS, Headers) in the installation..."
        PACKAGE_LIST=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
    else
        echo "Excluding proprietary drivers (NVIDIA, Broadcom STA, DKMS, Headers) from installation..."
        PACKAGE_LIST=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | grep -v -E 'nvidia-driver|nvidia-settings|broadcom-sta-dkms|dkms|linux-headers-amd64' | tr '\n' ',' | sed 's/,$//')
    fi

    # Add Debian keyring parameter if it exists (required on Ubuntu/Mint hosts)
    KEYRING_PARAM=""
    if [ -f "/usr/share/keyrings/debian-archive-keyring.gpg" ]; then
        KEYRING_PARAM="--keyring=/usr/share/keyrings/debian-archive-keyring.gpg"
        echo "Using Debian keyring: /usr/share/keyrings/debian-archive-keyring.gpg"
    fi

    # Execute Debian Bootstrap
    $SUDO /usr/bin/mmdebstrap \
        --architecture="$ARCH" \
        --components="main,contrib,non-free,non-free-firmware" \
        --variant=apt \
        $KEYRING_PARAM \
        --include="$PACKAGE_LIST" \
        "$DEBIAN_VERSION" \
        "$ROOTFS_BASE" \
        "$MIRROR"

    # Save the actually used package list in the base cache for future diffs
    if $WITH_NVIDIA; then
        grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | $SUDO tee "$ROOTFS_BASE/etc/build-base-packages.list" > /dev/null
    else
        grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | grep -v -E 'nvidia-driver|nvidia-settings|broadcom-sta-dkms|dkms|linux-headers-amd64' | $SUDO tee "$ROOTFS_BASE/etc/build-base-packages.list" > /dev/null
    fi

    echo "Base Debian Bootstrap completed in: $ROOTFS_BASE"
else
    echo "Virgin base detected in cache. Jumping bootstrap."
fi

# ==============================================================================
# PHASE 3: Clone clean base for working target
# ==============================================================================

# The target rootfs is never deleted automatically once it exists (matching
# ../iso/'s ./work): any run, --chroot or plain, reuses it as-is and skips
# straight past repo/package install (PHASE 5/5.5/6 below). Pass
# --clean-target (or trigger a base regen, see PHASE 2) to force a fresh clone.
RESUME_TARGET=false
if ! $CLEAN_TARGET && [ -d "$ROOTFS_TARGET/etc" ]; then
    RESUME_TARGET=true
fi

if $RESUME_TARGET; then
    echo "---  Reusing the existing target rootfs in: $ROOTFS_TARGET ---"
else
    echo "--- Cloning Debian base in the working directory (target) ---"
    cleanup
    $SUDO rm -rf "$ROOTFS_TARGET"
    mkdir -p "$ROOTFS_TARGET"

    # Sync keeping special attributes
    $SUDO rsync -aHAXx --delete "$ROOTFS_BASE/" "$ROOTFS_TARGET/"
fi

# ==============================================================================
# PHASE 4: Mount virtual filesystems and network
# ==============================================================================

echo "Configuring virtual mounts and DNS..."
$SUDO mount -t proc proc "$ROOTFS_TARGET/proc"
$SUDO mount -t sysfs sys "$ROOTFS_TARGET/sys"
$SUDO mount --bind /dev "$ROOTFS_TARGET/dev"
$SUDO mount --bind /dev/pts "$ROOTFS_TARGET/dev/pts"

# Ensure working DNS in chroot
if [ -f "$ROOTFS_TARGET/etc/resolv.conf" ]; then
    $SUDO cp "$ROOTFS_TARGET/etc/resolv.conf" "$ROOTFS_TARGET/etc/resolv.conf.bak"
fi
echo "nameserver 8.8.8.8" | $SUDO tee "$ROOTFS_TARGET/etc/resolv.conf" > /dev/null

# Reusing an existing target: repo/package install, branding and initramfs
# were already done when it was created, so PHASES 5, 5.5 and 6 are skipped
# entirely -- straight to the chroot shell or packaging below.
if ! $RESUME_TARGET; then

# ==============================================================================
# PHASE 5: Configure repositories and install the profile
# ==============================================================================

profile_setup_repo

BACKPORTS_INSTALL_CMD=""
if [ ${#PROFILE_BACKPORTS_PACKAGES[@]} -gt 0 ]; then
    if [ "$DEBIAN_VERSION" = "trixie" ]; then
        # backports only exists as a suite for the current stable release --
        # testing/unstable (forky/rolling) already have the newest version.
        BACKPORTS_INSTALL_CMD="yes | apt-get install -y -t ${DEBIAN_VERSION}-backports ${PROFILE_BACKPORTS_PACKAGES[*]}"
    else
        BACKPORTS_INSTALL_CMD="yes | apt-get install -y ${PROFILE_BACKPORTS_PACKAGES[*]}"
    fi
fi

if $USE_LOCAL_DEBS; then
    echo "--- LOCAL DEVELOPMENT MODE: Installing local .deb packages ---"
    pkg_dir_source="$ISO_DIR/../PKG"
    if [ ! -d "$pkg_dir_source" ]; then
        pkg_dir_source="/home/jaime/Documentos/pulsarbase/PKG"
    fi

    if [ -f "$pkg_dir_source/package-and-deploy.sh" ]; then
        echo "Building all local packages fresh for branch $BRANCH..."
        chmod +x "$pkg_dir_source/package-and-deploy.sh" 2>/dev/null || true
        (cd "$pkg_dir_source" && ./package-and-deploy.sh all --branch "$BRANCH")
    else
        echo "Warning: Packaging script not found in $pkg_dir_source/package-and-deploy.sh. An attempt will be made to use pre-existing debs."
    fi

    LOCAL_DEBS_DIR=""
    POSSIBLE_DIRS=(
        "$ISO_DIR/../PKG/build/packages"
        "$ISO_DIR/../build/packages"
        "$ISO_DIR/build/packages"
        "/home/jaime/Documentos/pulsarbase/PKG/build/packages"
    )

    for dir in "${POSSIBLE_DIRS[@]}"; do
        if [ -d "$dir" ] && [ -n "$(ls "$dir"/*.deb 2>/dev/null)" ]; then
            LOCAL_DEBS_DIR="$dir"
            break
        fi
    done

    if [ -z "$LOCAL_DEBS_DIR" ]; then
        echo "Error: No local .deb packages found in any of the search paths:"
        for dir in "${POSSIBLE_DIRS[@]}"; do echo "   - $dir"; done
        echo "Run the packager in the PKG/ folder first."
        exit 1
    fi

    echo "Using local packages from: $LOCAL_DEBS_DIR"
    $SUDO mkdir -p "$ROOTFS_TARGET/tmp/packages"
    $SUDO cp "$LOCAL_DEBS_DIR"/*.deb "$ROOTFS_TARGET/tmp/packages/"

    $SUDO tee "$ROOTFS_TARGET/etc/apt/preferences.d/local-$PROFILE_SLUG" > /dev/null <<EOF
Package: $PROFILE_LOCAL_PIN_GLOB
Pin: release *
Pin-Priority: -1
EOF

    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        set -e
        export DEBIAN_FRONTEND=noninteractive
        echo 'DPkg::options { "--force-overwrite"; };' > /etc/apt/apt.conf.d/99force-overwrite
        apt-get update
        $BACKPORTS_INSTALL_CMD
        yes | apt-get install -y \
            /tmp/packages/*.deb \
            ${PROFILE_COMMON_PACKAGES[*]}
        rm -f /etc/apt/apt.conf.d/99force-overwrite
        apt-get clean
    "
    $SUDO rm -rf "$ROOTFS_TARGET/tmp/packages"
    $SUDO rm -f "$ROOTFS_TARGET/etc/apt/preferences.d/local-$PROFILE_SLUG"
    echo "Local and cross-installed packages successfully."
else
    echo "---PRODUCTION MODE: Installing packages from APT repository ---"
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        set -e
        export DEBIAN_FRONTEND=noninteractive
        echo 'DPkg::options { "--force-overwrite"; };' > /etc/apt/apt.conf.d/99force-overwrite
        apt-get update
        $BACKPORTS_INSTALL_CMD
        yes | apt-get install -y --no-install-recommends \
            ${PROFILE_REPO_PACKAGES[*]} \
            ${PROFILE_COMMON_PACKAGES[*]}
        rm -f /etc/apt/apt.conf.d/99force-overwrite
        apt-get clean
    "
fi

sequoia_install_packages || echo "[sequoia] package step reported problems, continuing"

profile_teardown_repo

# Dynamically adjust Calamares configuration inside chroot based on distribution and selected bootloader
echo "Configuring Calamares in the chroot target..."
$SUDO mkdir -p "$ROOTFS_TARGET/etc/calamares/modules"

# 1. Adjust modules search path in settings.conf to cover all possible Calamares module install paths
if [ -f "$ROOTFS_TARGET/etc/calamares/settings.conf" ]; then
    $SUDO sed -i 's|modules-search: \[ local, /usr/lib/x86_64-linux-gnu/calamares/modules, /usr/share/calamares/modules \]|modules-search: [ local, /usr/lib/x86_64-linux-gnu/calamares/modules, /usr/lib/calamares/modules, /usr/share/calamares/modules ]|' "$ROOTFS_TARGET/etc/calamares/settings.conf"
fi

# 2. Bootloader for the INSTALLED system is stock GRUB (via Calamares'
# standard "bootloader" module, grub-install/update-grub) -- Ploader is
# live-USB only, not installed to disk. Needs grub-efi-amd64-bin/grub-pc
# actually present in the chroot for grub-install to exist at all (see
# packages.list); nothing to adjust in settings.conf, the stock sequence
# already calls "bootloader" as-is.

# 3. Create unpackfs.conf, packages.conf, and users.conf
echo "Generating Calamares configurations for Debian..."

# unpackfs.conf
cat <<EOF | $SUDO tee "$ROOTFS_TARGET/etc/calamares/modules/unpackfs.conf" > /dev/null
---
unpack:
    - source: "/run/live/medium/live/filesystem.squashfs"
      sourcefs: "squashfs"
      destination: ""
    - source: "/lib/live/mount/medium/live/filesystem.squashfs"
      sourcefs: "squashfs"
      destination: ""
      optional: true
EOF

# packages.conf
cat <<EOF | $SUDO tee "$ROOTFS_TARGET/etc/calamares/modules/packages.conf" > /dev/null
---
backend: apt

operations:
  - install:
      - firmware-linux
      - firmware-linux-nonfree
      - firmware-misc-nonfree
      - firmware-iwlwifi
      - firmware-realtek
      - firmware-atheros
      - firmware-brcm80211
      - intel-microcode
      - amd64-microcode
      - firmware-amd-graphics
  - try_remove:
      - calamares
      - calamares-settings-debian
      - $PROFILE_SLUG-calamares
EOF

# users.conf
cat <<EOF | $SUDO tee "$ROOTFS_TARGET/etc/calamares/modules/users.conf" > /dev/null
---
makeuproot: true
defaultGroups:
    - docker
    - sudo
    - users
    - lpadmin
    - sambashare
autologinUserWithWelcome: true
writeUsersPageToDummy: false
userShell: /bin/bash
EOF

# ==============================================================================
# PHASE 5.5: Profile-specific branding and extra apps
# ==============================================================================

profile_customize

sequoia_configure || echo "[sequoia] configure step reported problems, continuing"

# ==============================================================================
# PHASE 6: Final Tasks (Initramfs regeneration and cleanup)
# ==============================================================================

echo "--- Finalizing and updating initramfs ---"
$SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
    update-initramfs -u -k all
"

echo "Chroot rootfs ready and correctly structured in: $ROOTFS_TARGET"

fi # RESUME_TARGET (PHASE 5 / 5.5 / 6)

# --sequoia on a reused rootfs: apply the add-on now (pearOS repo is already torn
# down at this point, so only Debian packages and GitHub sources are fetched).
if $RESUME_TARGET && $FORCE_SEQUOIA; then
    sequoia_install_packages || echo "[sequoia] package step reported problems, continuing"
    sequoia_configure || echo "[sequoia] configure step reported problems, continuing"
fi

if $DROP_TO_CHROOT; then
    echo "=============================================================================="
    echo "--chroot: dropping into an interactive shell in $ROOTFS_TARGET"
    echo "   Virtual filesystems (proc/sys/dev) are still mounted."
    echo "=============================================================================="
    # Reset the controlling terminal before handing it to an interactive
    # shell: earlier non-interactive steps (apt/debconf prompts during
    # Phase 5, mmdebstrap output, etc.) can leave the pty's ECHO bit
    # cleared without restoring it, which would otherwise make everything
    # you type here invisible even though the shell is working fine.
    stty sane 2>/dev/null || true
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash || true
    echo "=============================================================================="
    echo "Exited chroot. Your changes are preserved in $ROOTFS_TARGET."
    echo "   Run again anytime (--chroot or plain) to reuse this exact rootfs, or pass"
    echo "   --clean-target to start over. Run without --chroot to finish the ISO."
    echo "=============================================================================="
    exit 0
fi

# ==============================================================================
# PHASE 6.5: Integrate pear-macos-style into the built desktop
# Runs for fresh AND reused root filesystems.
# The style itself is applied at desktop login, not on the build host.
# ==============================================================================

install_pear_macos_style() {
    local source_script="$ISO_DIR/pear-macos-style.sh"
    local target_script="$ROOTFS_TARGET/usr/local/bin/pear-macos-style"
    local autostart_dir="$ROOTFS_TARGET/etc/xdg/autostart"
    local applications_dir="$ROOTFS_TARGET/usr/share/applications"

    echo "[pear-macos-style] Preparing desktop integration..."

    if [ ! -f "$source_script" ]; then
        echo "[pear-macos-style] ERROR: Missing $source_script"
        echo "Place pear-macos-style.sh in the repository root."
        return 1
    fi

    # Install into the ISO rootfs, never execute against the build host.
    $SUDO install -D -m 0755 "$source_script" "$target_script"

    # kdialog is needed for the graphical style selector.
    seq_apt_try kdialog || \
        echo "[pear-macos-style] WARNING: kdialog could not be installed."

    # Apply the default style once for each user's own configuration.
    $SUDO install -d -m 0755 "$autostart_dir"
    $SUDO tee \
        "$autostart_dir/pear-macos-style-first-login.desktop" \
        >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=pearOS Desktop Appearance
Comment=Apply the default macOS-inspired desktop appearance once
Exec=/usr/local/bin/pear-macos-style apply sequoia --dark --accent blue --once
Terminal=false
NoDisplay=true
X-KDE-autostart-phase=2
EOF

    # Add a launcher so users can change the appearance later.
    $SUDO install -d -m 0755 "$applications_dir"
    $SUDO tee "$applications_dir/pear-macos-style.desktop" \
        >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=pearOS macOS Style
Comment=Change desktop style, accent color, and window buttons
Exec=/usr/local/bin/pear-macos-style gui
Icon=preferences-desktop-theme
Terminal=false
Categories=Settings;DesktopSettings;
EOF

    $SUDO chmod 0644 \
        "$autostart_dir/pear-macos-style-first-login.desktop" \
        "$applications_dir/pear-macos-style.desktop"

    echo "[pear-macos-style] Installed into target rootfs."
}

install_pear_macos_style || {
    echo "[pear-macos-style] ERROR: Integration failed; stopping build."
    exit 1
}

# ==============================================================================
# End pear-macos-style integration
# ==============================================================================

# ==============================================================================
# PHASE 7: Packaging and Live ISO Generation
# ==============================================================================
echo "---Creating $PROFILE_DISPLAY_NAME Live ISO Image ---"

ISO_STAGING="$BUILD_DIR/iso-staging"
$SUDO rm -rf "$ISO_STAGING"
mkdir -p "$ISO_STAGING/live"
mkdir -p "$ISO_STAGING/boot"

# 0. Clean temporary logs, test accounts, and unmount virtual filesystems prior to packaging
echo "Sanitizing rootfs target (cleaning test logs, temporary accounts, and cache)..."
$SUDO rm -rf "$ROOTFS_TARGET"/tmp/* "$ROOTFS_TARGET"/var/tmp/* "$ROOTFS_TARGET"/var/log/* 2>/dev/null || true
$SUDO rm -f "$ROOTFS_TARGET"/etc/sudoers.d/$PROFILE_SLUG-user-* 2>/dev/null || true
$SUDO rm -f "$ROOTFS_TARGET"/var/lib/AccountsService/users/* 2>/dev/null || true
$SUDO find "$ROOTFS_TARGET/home" -mindepth 1 -maxdepth 1 ! -name 'liveuser' -exec rm -rf {} + 2>/dev/null || true

echo "Unmounting virtual filesystems in target..."
$SUDO umount -l "$ROOTFS_TARGET/proc" 2>/dev/null || true
$SUDO umount -l "$ROOTFS_TARGET/sys" 2>/dev/null || true
$SUDO umount -l "$ROOTFS_TARGET/dev/pts" 2>/dev/null || true
$SUDO umount -l "$ROOTFS_TARGET/dev" 2>/dev/null || true

# 1. Compress rootfs into SquashFS
echo "Compressing rootfs into SquashFS..."
# Exclude dynamic/temp directories and virtual filesystems to save space and prevent errors
SQUASHFS_OUT="$ISO_STAGING/live/filesystem.squashfs"
$SUDO mksquashfs "$ROOTFS_TARGET" "$SQUASHFS_OUT" \
    -noappend \
    -comp xz \
    -Xbcj x86 \
    -e proc/* \
    -e sys/* \
    -e dev/* \
    -e run/* \
    -e tmp/* \
    -e var/tmp/* \
    -e var/log/* \
    -e root/.bash_history

# 2. Copy Kernel and Initrd to ISO staging
echo "Copying Kernel and Initrd..."
KERNEL_FILE=$(ls "$ROOTFS_TARGET"/boot/vmlinuz-* 2>/dev/null | head -n 1)
INITRD_FILE=$(ls "$ROOTFS_TARGET"/boot/initrd.img-* 2>/dev/null | head -n 1)

if [ -z "$KERNEL_FILE" ] || [ -z "$INITRD_FILE" ]; then
    echo "Error: Kernel or initrd not found in target chroot."
    exit 1
fi

$SUDO cp "$KERNEL_FILE" "$ISO_STAGING/live/vmlinuz"
$SUDO cp "$INITRD_FILE" "$ISO_STAGING/live/initrd"

KERNEL_PARAMS="boot=live components username=liveuser autologin cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 amdgpu.dcdebugmask=0x10 radeon.modeset=1 nvme_load=yes plymouth.use-simpledrm=0 quiet splash loglevel=3 noprompt --"
RAM_PARAMS="boot=live components username=liveuser autologin cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 amdgpu.dcdebugmask=0x10 radeon.modeset=1 nvme_load=yes toram plymouth.use-simpledrm=0 quiet splash loglevel=3 noprompt --"
DEBUG_PARAMS="boot=live components username=liveuser autologin cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 amdgpu.dcdebugmask=0x10 radeon.modeset=1 nvme_load=yes plymouth.ignore-serial-consoles loglevel=7 rd.debug noprompt --"
LEGACY_PARAMS="boot=live components username=liveuser autologin cow_spacesize=4G module_blacklist=nvidia,nvidia_modeset,nvidia_uvm,nvidia_drm nomodeset nvme_load=yes loglevel=3 noprompt --"

# --------------------------------------------------------------------------
# UEFI: Ploader (pearOS's rEFInd 0.14.1 rebrand — prebuilt binary+theme,
# vendored under profiles/<name>/ploader/, not compiled by this script)
# --------------------------------------------------------------------------
echo "Creating bootable EFI image with Ploader..."
$SUDO mkdir -p "$ISO_STAGING/EFI/BOOT"
EFI_IMG="$ISO_STAGING/boot/efi.img"
PLOADER_DIR="$PROFILE_DIR/ploader"

if [ ! -f "$PLOADER_DIR/ploader_x64.efi" ] || [ ! -d "$PLOADER_DIR/theme" ]; then
    echo "Error: $PLOADER_DIR is missing ploader_x64.efi or theme/ -- this profile can't boot without them."
    exit 1
fi

# Create a 350MB empty file and format it as FAT16 (eliminates FAT32 cluster warnings and has space for kernel/initrd)
$SUDO dd if=/dev/zero of="$EFI_IMG" bs=1M count=350 2>/dev/null
$SUDO mkfs.vfat -F 16 "$EFI_IMG" >/dev/null

# ploader.conf uses rEFInd's own config syntax: one explicit menuentry per boot
# variant (Ploader's auto-detection would otherwise add a 4th, duplicate tile).
cat <<EOF > "$BUILD_DIR/ploader.conf"
timeout 10
silent_menu false
enable_mouse
mouse_speed 4
mouse_size 16
default_selection "+,$PROFILE_SLUG,$PROFILE_DISPLAY_NAME Live (RAM)"

menuentry "$PROFILE_DISPLAY_NAME Live (RAM)" {
    icon    /EFI/BOOT/theme/icons/os_${PROFILE_SLUG}.png
    loader  /EFI/BOOT/vmlinuz
    initrd  /EFI/BOOT/initrd
    options "$RAM_PARAMS"
}

menuentry "$PROFILE_DISPLAY_NAME Live (Normal)" {
    icon    /EFI/BOOT/theme/icons/os_${PROFILE_SLUG}.png
    loader  /EFI/BOOT/vmlinuz
    initrd  /EFI/BOOT/initrd
    options "$KERNEL_PARAMS"
}

menuentry "$PROFILE_DISPLAY_NAME Live (No Plymouth / Debug)" {
    icon    /EFI/BOOT/theme/icons/os_linux.png
    loader  /EFI/BOOT/vmlinuz
    initrd  /EFI/BOOT/initrd
    options "$DEBUG_PARAMS"
}

menuentry "$PROFILE_DISPLAY_NAME Live (Legacy Hardware / GPU nomodeset)" {
    icon    /EFI/BOOT/theme/icons/os_recovery.png
    loader  /EFI/BOOT/vmlinuz
    initrd  /EFI/BOOT/initrd
    options "$LEGACY_PARAMS"
}
EOF

echo "Copying Ploader binary, theme and kernel/initrd to the ISO staging root..."
$SUDO cp "$PLOADER_DIR/ploader_x64.efi" "$ISO_STAGING/EFI/BOOT/BOOTx64.EFI"
$SUDO cp -r "$PLOADER_DIR/theme" "$ISO_STAGING/EFI/BOOT/theme"
$SUDO cp "$BUILD_DIR/ploader.conf" "$ISO_STAGING/EFI/BOOT/ploader.conf"
$SUDO cp "$ISO_STAGING/live/vmlinuz" "$ISO_STAGING/EFI/BOOT/vmlinuz"
$SUDO cp "$ISO_STAGING/live/initrd" "$ISO_STAGING/EFI/BOOT/initrd"

echo "Copying files to efi.img using mtools..."
$SUDO mmd -i "$EFI_IMG" ::/EFI
$SUDO mmd -i "$EFI_IMG" ::/EFI/BOOT
$SUDO mcopy -i "$EFI_IMG" "$PLOADER_DIR/ploader_x64.efi" ::/EFI/BOOT/BOOTx64.EFI
$SUDO mcopy -s -i "$EFI_IMG" "$PLOADER_DIR/theme" ::/EFI/BOOT/theme
$SUDO mcopy -i "$EFI_IMG" "$BUILD_DIR/ploader.conf" ::/EFI/BOOT/ploader.conf
$SUDO mcopy -i "$EFI_IMG" "$ISO_STAGING/live/vmlinuz" ::/EFI/BOOT/vmlinuz
$SUDO mcopy -i "$EFI_IMG" "$ISO_STAGING/live/initrd" ::/EFI/BOOT/initrd

$SUDO rm -f "$BUILD_DIR/ploader.conf"

# --------------------------------------------------------------------------
# BIOS: syslinux/isolinux, pulled straight from the built chroot's own
# packages so the boot binaries stay architecture/build-consistent regardless
# of the host OS (see profiles/<name>/packages.list: isolinux + syslinux-common)
# --------------------------------------------------------------------------
echo "Configuring syslinux for BIOS boot..."
$SUDO mkdir -p "$ISO_STAGING/syslinux"
ISOLINUX_BIN=$(find "$ROOTFS_TARGET/usr/lib/ISOLINUX" -name "isolinux.bin" 2>/dev/null | head -n 1)
if [ -z "$ISOLINUX_BIN" ]; then
    echo "Error: isolinux.bin not found in rootfs (is the 'isolinux' package installed?)."
    exit 1
fi
$SUDO cp "$ISOLINUX_BIN" "$ISO_STAGING/syslinux/isolinux.bin"
$SUDO cp "$ROOTFS_TARGET/usr/lib/syslinux/modules/bios/"*.c32 "$ISO_STAGING/syslinux/" 2>/dev/null || true
$SUDO cp "$PROFILE_DIR/syslinux/splash.png" "$ISO_STAGING/syslinux/splash.png"

cat <<EOF | $SUDO tee "$ISO_STAGING/syslinux/syslinux.cfg" > /dev/null
SERIAL 0 38400
UI vesamenu.c32
MENU TITLE $PROFILE_DISPLAY_NAME
MENU BACKGROUND splash.png

MENU WIDTH 78
MENU MARGIN 4
MENU ROWS 6
MENU VSHIFT 10
MENU TABMSGROW 13
MENU CMDLINEROW 13
MENU HELPMSGROW 15
MENU HELPMSGENDROW 27

MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

MENU CLEAR
MENU IMMEDIATE

LABEL live
TEXT HELP
Boot $PROFILE_DISPLAY_NAME on BIOS.
ENDTEXT
MENU LABEL $PROFILE_DISPLAY_NAME Live (x86_64, BIOS)
LINUX /live/vmlinuz
INITRD /live/initrd
APPEND $KERNEL_PARAMS

LABEL live-debug
TEXT HELP
Boot $PROFILE_DISPLAY_NAME on BIOS without Plymouth.
Use this option if Plymouth freezes or crashes during boot.
ENDTEXT
MENU LABEL $PROFILE_DISPLAY_NAME Live (No Plymouth / Debug)
LINUX /live/vmlinuz
INITRD /live/initrd
APPEND $DEBUG_PARAMS

LABEL live-legacy
TEXT HELP
Boot $PROFILE_DISPLAY_NAME on BIOS with kernel modesetting disabled.
Use this option if the screen stays black or the GPU is very old.
ENDTEXT
MENU LABEL $PROFILE_DISPLAY_NAME Live (Legacy Hardware / GPU nomodeset)
LINUX /live/vmlinuz
INITRD /live/initrd
APPEND $LEGACY_PARAMS

LABEL existing
TEXT HELP
Boot an existing operating system.
Press TAB to edit the disk and partition number to boot.
ENDTEXT
MENU LABEL Boot existing OS
COM32 chain.c32
APPEND hd0 0

LABEL reboot
TEXT HELP
Reboot computer.
ENDTEXT
MENU LABEL Reboot
COM32 reboot.c32

LABEL poweroff
TEXT HELP
Power off computer.
ENDTEXT
MENU LABEL Power Off
COM32 poweroff.c32
EOF

VER_SUFFIX=""
if [ -n "$PULSAR_VERSION" ]; then
    VER_SUFFIX="-${PULSAR_VERSION}"
fi

# Mirrors ../iso/'s pearOS-<codename>-<version>-<arch>.iso naming, with the
# archiso codename slot (there hardcoded to "NiceC0re") replaced by this
# engine's --profile name so different profiles get distinct filenames.
case "$ARCH" in
    amd64) ISO_ARCH="x86_64" ;;
    arm64) ISO_ARCH="aarch64" ;;
    *) ISO_ARCH="$ARCH" ;;
esac

ISO_CODENAME="${PROFILE_CODENAME:-$PROFILE}"
if $WITH_NVIDIA; then
    ISO_OUTPUT="$ISO_DIR/pearOS-${ISO_CODENAME}-$(date +%Y.%m)-${ISO_ARCH}${VER_SUFFIX}-nvidia.iso"
else
    ISO_OUTPUT="$ISO_DIR/pearOS-${ISO_CODENAME}-$(date +%Y.%m)-${ISO_ARCH}${VER_SUFFIX}.iso"
fi

echo "Generating hybrid ISO file at: $ISO_OUTPUT..."
# Add a hybrid MBR so the ISO is a valid disk image: balenaEtcher requires it
# and direct USB flashing (dd) needs it for UEFI to find the GPT ESP partition.
# Prefer the chroot's own isohdpfx.bin (build-consistent), fall back to the host's.
HYBRID_MBR=""
for mbr in \
    "$ROOTFS_TARGET/usr/lib/ISOLINUX/isohdpfx.bin" \
    "$ROOTFS_TARGET/usr/lib/syslinux/mbr/isohdpfx.bin" \
    "/usr/lib/ISOLINUX/isohdpfx.bin" \
    "/usr/lib/syslinux/mbr/isohdpfx.bin"; do
    if [ -f "$mbr" ]; then
        HYBRID_MBR="$mbr"
        break
    fi
done
if [ -z "$HYBRID_MBR" ]; then
    echo "Error: No hybrid MBR template found (isohdpfx.bin). Install 'syslinux-common' in the chroot or on the host."
    exit 1
fi

$SUDO xorriso -as mkisofs \
  -o "$ISO_OUTPUT" \
  -iso-level 3 \
  -J -R -V "$PROFILE_ISO_LABEL" \
  -isohybrid-mbr "$HYBRID_MBR" \
  -eltorito-boot syslinux/isolinux.bin \
  -eltorito-catalog syslinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/efi.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  "$ISO_STAGING"

SHA256_OUTPUT="${ISO_OUTPUT}.sha256.txt"
echo "Computing SHA-256 checksum..."
(cd "$ISO_DIR" && $SUDO sha256sum "$(basename "$ISO_OUTPUT")" | $SUDO tee "$SHA256_OUTPUT" > /dev/null)

echo "=============================================================================="
echo "$PROFILE_DISPLAY_NAME ISO generated successfully!"
echo "Location: $ISO_OUTPUT"
echo "Checksum: $SHA256_OUTPUT"
echo "=============================================================================="
