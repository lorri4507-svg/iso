#!/usr/bin/env bash
# sequoia-features.sh <rootfs>
# Layers macOS-Sequoia-style features onto an already-bootstrapped Debian rootfs.
# Pass "/" if you are already running inside the chroot.
#
# Toggles (export before the build, or edit the defaults):
#   SEQ_THEME=1   also install the WhiteSur GTK + icon themes (off by default,
#                 because pearOS probably ships its own look and they could clash)
set -euo pipefail

ROOT="${1:?usage: sequoia-features.sh <rootfs>}"
ROOT="${ROOT%/}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEQ_THEME="${SEQ_THEME:-0}"

run() {                      # run a command inside the rootfs
  if [ -z "$ROOT" ]; then
    DEBIAN_FRONTEND=noninteractive "$@"
  else
    chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive "$@"
  fi
}
have_pkg() { run dpkg -s "$1" >/dev/null 2>&1; }

HAS_GNOME=0; HAS_KDE=0
have_pkg gnome-shell && HAS_GNOME=1
have_pkg plasma-desktop && HAS_KDE=1

echo "[sequoia] desktop detected: gnome=$HAS_GNOME kde=$HAS_KDE"

# ---------------------------------------------------------------- packages
# Passwords app      -> KeePassXC
# Math Notes         -> Qalculate (closest equivalent, not a clone)
# iPhone Mirroring   -> KDE Connect / GSConnect (phone integration; Android only)
PKGS=(keepassxc qalculate-gtk)
if   [ "$HAS_GNOME" = 1 ]; then PKGS+=(gnome-shell-extension-gsconnect)
elif [ "$HAS_KDE"   = 1 ]; then PKGS+=(kdeconnect)
fi

run apt-get update
run apt-get install -y --no-install-recommends "${PKGS[@]}"

# -------------------------------------------------------------- wallpapers
# Apple's Sequoia wallpapers are copyrighted, so none are bundled. Drop your own
# images into profiles/sequoia/wallpapers/ and they are installed + set as default.
WP_DST="$ROOT/usr/share/backgrounds/sequoia"
FIRST_WP=""
if compgen -G "$HERE/wallpapers/*" >/dev/null; then
  mkdir -p "$WP_DST"
  cp -a "$HERE"/wallpapers/* "$WP_DST/"
  FIRST_WP="$(ls -1 "$WP_DST" | head -n1)"
fi

# ----------------------------------------- window tiling + defaults (GNOME)
if [ "$HAS_GNOME" = 1 ]; then
  mkdir -p "$ROOT/etc/dconf/profile" "$ROOT/etc/dconf/db/local.d"

  # make sure the system "local" db is read (don't clobber an existing profile)
  if [ ! -f "$ROOT/etc/dconf/profile/user" ]; then
    printf 'user-db:user\nsystem-db:local\n' > "$ROOT/etc/dconf/profile/user"
  elif ! grep -q '^system-db:local' "$ROOT/etc/dconf/profile/user"; then
    echo 'system-db:local' >> "$ROOT/etc/dconf/profile/user"
  fi

  {
    cat <<'EOF'
# Sequoia-style window tiling: drag to edges, plus Ctrl+Super+Arrow shortcuts
[org/gnome/mutter]
edge-tiling=true

[org/gnome/mutter/keybindings]
toggle-tiled-left=['<Control><Super>Left']
toggle-tiled-right=['<Control><Super>Right']

[org/gnome/desktop/wm/keybindings]
maximize=['<Control><Super>Up']
unmaximize=['<Control><Super>Down']
EOF
    if [ -n "$FIRST_WP" ]; then
      cat <<EOF

[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/sequoia/$FIRST_WP'
picture-uri-dark='file:///usr/share/backgrounds/sequoia/$FIRST_WP'
EOF
    fi
  } > "$ROOT/etc/dconf/db/local.d/90-sequoia"

  run dconf update
fi

if [ "$HAS_KDE" = 1 ]; then
  echo "[sequoia] KDE detected: Plasma already supports edge/quick tiling; no extra tiling config applied."
fi

# ------------------------------------------------------- optional WhiteSur
if [ "$SEQ_THEME" = 1 ]; then
  run apt-get install -y --no-install-recommends git sassc
  run sh -c '
    set -e
    d=$(mktemp -d); cd "$d"
    git clone --depth 1 https://github.com/vinceliuice/WhiteSur-gtk-theme.git
    git clone --depth 1 https://github.com/vinceliuice/WhiteSur-icon-theme.git
    (cd WhiteSur-gtk-theme  && ./install.sh -d /usr/share/themes)
    (cd WhiteSur-icon-theme && ./install.sh -d /usr/share/icons)
    rm -rf "$d"
  '
fi

echo "[sequoia] done"
