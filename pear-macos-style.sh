#!/usr/bin/env bash
# pear-macos-style - give the KDE Plasma desktop the look of a different macOS release.
#
#   pear-macos-style                 open the settings window (needs kdialog)
#   pear-macos-style list            show every style and whether its theme pieces are installed
#   pear-macos-style apply <style> [--dark|--light] [--accent <colour>] [--keep-buttons] [--once]
#   pear-macos-style accent <blue|purple|pink|red|orange|yellow|green|graphite>
#   pear-macos-style buttons <mac|default>
#   pear-macos-style font <inter|default>
#   pear-macos-style status
#   pear-macos-style restore         go back to how the desktop was before the first change
#
# Styles: aqua-cheetah aqua-leopard aqua-mavericks mojave catalina bigsur monterey
#         ventura sonoma sequoia tahoe
set -u

APP=pear-macos-style
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE="$CFG/$APP"
BACKUP="$STATE/backup"
ERAS="aqua-cheetah aqua-leopard aqua-mavericks mojave catalina bigsur monterey ventura sonoma sequoia tahoe"

GTK_DIRS=(/usr/share/themes "$HOME/.themes" "$HOME/.local/share/themes")
ICON_DIRS=(/usr/share/icons "$HOME/.icons" "$HOME/.local/share/icons")
LNF_DIRS=(/usr/share/plasma/look-and-feel "$HOME/.local/share/plasma/look-and-feel")

say()  { printf '%s\n' "$*"; }
warn() { printf '  - %s\n' "$*"; }
die()  { printf '%s: %s\n' "$APP" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }

find_tool() { command -v "$1" 2>/dev/null || ls /usr/lib/*/libexec/kf6/"$1" /usr/libexec/kf6/"$1" 2>/dev/null | head -n1; }
KW="$(find_tool kwriteconfig6)"
KR="$(find_tool kreadconfig6)"
[ -n "$KW" ] || die "kwriteconfig6 not found (this tool is for KDE Plasma 6)"

kw() { "$KW" --file "$CFG/$1" --group "$2" --key "$3" "$4"; }          # file group key value
kr() { [ -n "$KR" ] && "$KR" --file "$CFG/$1" --group "$2" --key "$3" 2>/dev/null; }

# ---------------------------------------------------------------- theme lookup
# pick <regex> <light|dark> <require-subdir|-> <dir>...   -> best matching name
# Prefers the dark/light variant you asked for, avoids solid/nord/alt/round variants,
# and otherwise takes the shortest name (the base variant).
pick() {
    local re="$1" mode="$2" sub="$3"; shift 3
    local d n all="" pref="" clean=""
    for d in "$@"; do
        [ -d "$d" ] || continue
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            printf '%s' "$n" | grep -qiE "$re" || continue
            [ "$sub" = "-" ] || [ -d "$d/$n/$sub" ] || continue
            all+="$n"$'\n'
        done < <(find "$d" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null)
    done
    [ -n "$all" ] || return 1
    if [ "$mode" = dark ]; then pref="$(printf '%s' "$all" | grep -i dark)"
    else                        pref="$(printf '%s' "$all" | grep -vi dark)"; fi
    [ -n "$pref" ] || pref="$all"
    clean="$(printf '%s\n' "$pref" | grep -viE 'solid|nord|-alt|hdpi|round')"
    [ -n "$clean" ] || clean="$pref"
    printf '%s\n' "$clean" | awk 'NF{print length($0), $0}' | sort -n | head -n1 | cut -d' ' -f2-
}

# pick_any "<re1>|<re2>" ...   tries each alternative in priority order
pick_any() {
    local alts="$1" mode="$2" sub="$3" a r; shift 3
    local IFS='|'
    for a in $alts; do
        r="$(IFS=' ' pick "$a" "$mode" "$sub" "$@")" && [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
    done
    return 1
}

# ------------------------------------------------------------------- the styles
# E_GTK / E_ICON / E_CURSOR / E_LNF are regexes; "a|b" means "try a first, then b".
era_load() {
    E_LABEL=""; E_GTK=""; E_ICON=""; E_CURSOR=""; E_LNF=""; E_SCHEME_L=""; E_SCHEME_D=""; E_NOTE=""
    case "$1" in
        aqua-cheetah)
            E_LABEL="Mac OS X 10.0 Cheetah (Aqua)"; E_GTK='^Mac-OS-X-Cheetah$'
            E_SCHEME_L=BreezeLight; E_SCHEME_D=BreezeDark
            E_NOTE="Aqua themes only exist for GTK; Qt/KDE apps get Breeze Light/Dark." ;;
        aqua-leopard)
            E_LABEL="Mac OS X 10.5 Leopard (Aqua)"; E_GTK='^OS-X-Leopard'
            E_SCHEME_L=BreezeLight; E_SCHEME_D=BreezeDark
            E_NOTE="Aqua themes only exist for GTK; Qt/KDE apps get Breeze Light/Dark." ;;
        aqua-mavericks)
            E_LABEL="OS X 10.9 Mavericks (late Aqua)"; E_GTK='^OS-X-Mavericks'
            E_SCHEME_L=BreezeLight; E_SCHEME_D=BreezeDark
            E_NOTE="Aqua themes only exist for GTK; Qt/KDE apps get Breeze Light/Dark." ;;
        mojave)
            E_LABEL="macOS 10.14 Mojave"; E_GTK='^Mojave'; E_ICON='^McMojave-circle'
            E_CURSOR='McMojave'; E_LNF='McMojave' ;;
        catalina)
            E_LABEL="macOS 10.15 Catalina"; E_GTK='^Mojave'; E_ICON='^McMojave-circle'
            E_CURSOR='McMojave'; E_LNF='McMojave'
            E_NOTE="Catalina shares the Mojave pack (the GTK theme is a Catalina-style mod of it)." ;;
        bigsur)
            E_LABEL="macOS 11 Big Sur"; E_GTK='^WhiteSur'; E_ICON='^WhiteSur(-dark)?$'
            E_CURSOR='WhiteSur|Tahoe'; E_LNF='WhiteSur' ;;
        monterey)
            E_LABEL="macOS 12 Monterey"; E_GTK='^WhiteSur'; E_ICON='^WhiteSur(-dark)?$'
            E_CURSOR='WhiteSur|Tahoe'; E_LNF='WhiteSur'
            E_NOTE="No separate Monterey port exists; this is the WhiteSur (Big Sur) pack." ;;
        ventura)
            E_LABEL="macOS 13 Ventura"; E_GTK='^WhiteSur'; E_ICON='^WhiteSur(-dark)?$'
            E_CURSOR='WhiteSur|Tahoe'; E_LNF='MacVentura|WhiteSur' ;;
        sonoma)
            E_LABEL="macOS 14 Sonoma"; E_GTK='^WhiteSur'; E_ICON='^WhiteSur(-dark)?$'
            E_CURSOR='WhiteSur|Tahoe'; E_LNF='MacVentura|WhiteSur'
            E_NOTE="No separate Sonoma port exists; this is the Ventura/WhiteSur pack." ;;
        sequoia)
            E_LABEL="macOS 15 Sequoia"; E_GTK='^WhiteSur'; E_ICON='^WhiteSur(-dark)?$'
            E_CURSOR='WhiteSur|Tahoe'; E_LNF='MacVentura|WhiteSur'
            E_NOTE="No separate Sequoia port exists; this is the Ventura/WhiteSur pack." ;;
        tahoe)
            E_LABEL="macOS 26 Tahoe"; E_GTK='^MacTahoe'; E_ICON='^MacTahoe(-dark)?$'
            E_CURSOR='Tahoe'; E_LNF='MacTahoe|pearos' ;;
        *) return 1 ;;
    esac
    return 0
}

era_status() {   # prints what is installed for an era: gtk icon cursor plasma
    local mode="${2:-light}" g="-" i="-" c="-" l="-"
    era_load "$1" || return 1
    [ -z "$E_GTK" ]    || { pick_any "$E_GTK"    "$mode" -       "${GTK_DIRS[@]}"  >/dev/null && g="yes" || g="no"; }
    [ -z "$E_ICON" ]   || { pick_any "$E_ICON"   "$mode" -       "${ICON_DIRS[@]}" >/dev/null && i="yes" || i="no"; }
    [ -z "$E_CURSOR" ] || { pick_any "$E_CURSOR" "$mode" cursors "${ICON_DIRS[@]}" >/dev/null && c="yes" || c="no"; }
    [ -z "$E_LNF" ]    || { pick_any "$E_LNF"    "$mode" -       "${LNF_DIRS[@]}"  >/dev/null && l="yes" || l="no"; }
    printf 'gtk:%-3s icons:%-3s cursor:%-3s plasma:%-3s' "$g" "$i" "$c" "$l"
}

list_eras() {
    local e
    printf '%-15s %-34s %s\n' STYLE NAME "INSTALLED PIECES"
    for e in $ERAS; do
        era_load "$e"
        printf '%-15s %-34s %s\n' "$e" "$E_LABEL" "$(era_status "$e")"
    done
    say ""
    say "'-' = not part of that style, 'no' = missing from this image (build was offline, or the repo changed)."
}

# ---------------------------------------------------------------- helpers
reload_kwin() {
    if need qdbus6; then qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1
    else dbus-send --session --dest=org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1; fi
    return 0
}

BK_FILES="kdeglobals kwinrc plasmarc kcminputrc gtk-3.0/settings.ini gtk-4.0/settings.ini gtk-4.0/gtk.css gtk-4.0/gtk-dark.css gtk-4.0/assets"

backup_once() {
    [ -e "$BACKUP/.done" ] && return 0
    mkdir -p "$BACKUP"
    local f
    for f in $BK_FILES; do
        if [ -e "$CFG/$f" ] || [ -L "$CFG/$f" ]; then
            mkdir -p "$BACKUP/$(dirname "$f")"; cp -a "$CFG/$f" "$BACKUP/$f"
        fi
    done
    [ -f "$HOME/.gtkrc-2.0" ] && cp -a "$HOME/.gtkrc-2.0" "$BACKUP/gtkrc-2.0"
    touch "$BACKUP/.done"
}

restore_defaults() {
    [ -e "$BACKUP/.done" ] || die "nothing to restore yet (no style has been applied)"
    local f lnf cur
    for f in $BK_FILES; do
        rm -rf "$CFG/$f"
        if [ -e "$BACKUP/$f" ] || [ -L "$BACKUP/$f" ]; then
            mkdir -p "$(dirname "$CFG/$f")"; cp -a "$BACKUP/$f" "$CFG/$f"
        fi
    done
    rm -f "$HOME/.gtkrc-2.0"; [ -f "$BACKUP/gtkrc-2.0" ] && cp -a "$BACKUP/gtkrc-2.0" "$HOME/.gtkrc-2.0"
    lnf="$(kr kdeglobals KDE LookAndFeelPackage)"
    [ -n "$lnf" ] && need plasma-apply-lookandfeel && plasma-apply-lookandfeel -a "$lnf" >/dev/null 2>&1
    cur="$(kr kcminputrc Mouse cursorTheme)"
    [ -n "$cur" ] && need plasma-apply-cursortheme && plasma-apply-cursortheme "$cur" >/dev/null 2>&1
    if need gsettings; then
        gsettings reset org.gnome.desktop.interface gtk-theme 2>/dev/null
        gsettings reset org.gnome.desktop.interface color-scheme 2>/dev/null
    fi
    reload_kwin
    rm -f "$STATE/current"
    say "Restored the original look. Log out and back in for everything to refresh."
}

set_gtk() {   # set_gtk <theme> <light|dark>
    local t="$1" mode="$2" v d src="" f
    for v in 3.0 4.0; do kw "gtk-$v/settings.ini" Settings gtk-theme-name "$t"; done
    kw gtk-3.0/settings.ini Settings gtk-application-prefer-dark-theme "$([ "$mode" = dark ] && echo true || echo false)"
    if [ -f "$HOME/.gtkrc-2.0" ] && grep -q '^gtk-theme-name' "$HOME/.gtkrc-2.0"; then
        sed -i "s|^gtk-theme-name=.*|gtk-theme-name=\"$t\"|" "$HOME/.gtkrc-2.0"
    else
        printf 'gtk-theme-name="%s"\n' "$t" >> "$HOME/.gtkrc-2.0"
    fi
    # libadwaita (GTK4) apps ignore the theme name, so link the theme's own GTK4 css
    for d in "${GTK_DIRS[@]}"; do [ -d "$d/$t/gtk-4.0" ] && { src="$d/$t/gtk-4.0"; break; }; done
    mkdir -p "$CFG/gtk-4.0"
    rm -f "$CFG/gtk-4.0/gtk.css" "$CFG/gtk-4.0/gtk-dark.css"; rm -rf "$CFG/gtk-4.0/assets"
    if [ -n "$src" ]; then
        for f in gtk.css gtk-dark.css; do [ -e "$src/$f" ] && ln -sf "$src/$f" "$CFG/gtk-4.0/$f"; done
        [ -d "$src/assets" ] && ln -sfn "$src/assets" "$CFG/gtk-4.0/assets"
    fi
    if need gsettings; then
        gsettings set org.gnome.desktop.interface gtk-theme "$t" 2>/dev/null
        gsettings set org.gnome.desktop.interface color-scheme "$([ "$mode" = dark ] && echo prefer-dark || echo default)" 2>/dev/null
    fi
}

set_buttons() {
    case "${1:-}" in
        mac)     kw kwinrc org.kde.kdecoration2 ButtonsOnLeft XIA; kw kwinrc org.kde.kdecoration2 ButtonsOnRight "" ;;
        default) kw kwinrc org.kde.kdecoration2 ButtonsOnLeft M;   kw kwinrc org.kde.kdecoration2 ButtonsOnRight IAX ;;
        *) die "usage: $APP buttons <mac|default>" ;;
    esac
    reload_kwin
    say "Window buttons: $1"
}

set_font() {
    case "${1:-}" in
        inter)
            if ! fc-list 2>/dev/null | grep -qi 'Inter'; then die "the Inter font is not installed"; fi
            local k
            for k in font menuFont toolBarFont; do kw kdeglobals General "$k" "Inter,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"; done ;;
        default)
            local k
            for k in font menuFont toolBarFont; do "$KW" --file "$CFG/kdeglobals" --group General --key "$k" --delete; done ;;
        *) die "usage: $APP font <inter|default>" ;;
    esac
    say "Font: $1 (applications pick it up when restarted)"
}

accent_rgb() {
    case "$1" in
        blue) echo 0,122,255;;      purple) echo 175,82,222;;   pink) echo 247,79,158;;
        red) echo 255,82,87;;       orange) echo 247,130,27;;   yellow) echo 252,184,40;;
        green) echo 98,186,70;;     graphite) echo 152,152,157;;
        *) return 1;;
    esac
}

apply_accent() {
    local rgb scheme
    rgb="$(accent_rgb "${1:-}")" || die "accent must be one of: blue purple pink red orange yellow green graphite"
    kw kdeglobals General AccentColor "$rgb"
    kw kdeglobals General accentColorFromWallpaper false
    scheme="$(kr kdeglobals General ColorScheme)"
    [ -n "$scheme" ] && need plasma-apply-colorscheme && plasma-apply-colorscheme "$scheme" >/dev/null 2>&1
    say "Accent colour: $1"
}

apply_wallpaper() {   # looks for user-supplied images in /usr/share/backgrounds/macos/<style>/
    local img
    img="$(find "/usr/share/backgrounds/macos/$1" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.heic' \) 2>/dev/null | sort | head -n1)"
    if [ -n "$img" ] && need plasma-apply-wallpaperimage; then
        plasma-apply-wallpaperimage "$img" >/dev/null 2>&1 && say "  + wallpaper: $(basename "$img")"
    fi
}

# ------------------------------------------------------------------ apply a style
apply_era() {   # apply_era <style> <light|dark> <keep_buttons 0|1>
    local era="$1" mode="${2:-light}" keep="${3:-0}" gtk icon cur lnf scheme
    era_load "$era" || die "unknown style '$era' (run: $APP list)"
    backup_once
    say "Applying $E_LABEL ($mode)..."
    [ -z "$E_NOTE" ] || say "  note: $E_NOTE"

    if [ -n "$E_LNF" ]; then
        lnf="$(pick_any "$E_LNF" "$mode" - "${LNF_DIRS[@]}")"
        if [ -n "$lnf" ] && need plasma-apply-lookandfeel; then
            plasma-apply-lookandfeel -a "$lnf" >/dev/null 2>&1 && say "  + Plasma global theme: $lnf" || warn "could not apply $lnf"
        else warn "Plasma theme for this style is not installed"; fi
    fi
    scheme="$E_SCHEME_L"; [ "$mode" = dark ] && scheme="${E_SCHEME_D:-$E_SCHEME_L}"
    if [ -n "$scheme" ] && need plasma-apply-colorscheme; then
        plasma-apply-colorscheme "$scheme" >/dev/null 2>&1 && say "  + colour scheme: $scheme"
    fi
    if [ -n "$E_ICON" ]; then
        icon="$(pick_any "$E_ICON" "$mode" - "${ICON_DIRS[@]}")"
        if [ -n "$icon" ]; then
            kw kdeglobals Icons Theme "$icon"; say "  + icons: $icon"
        else warn "icon theme not installed"; fi
    fi
    if [ -n "$E_CURSOR" ]; then
        cur="$(pick_any "$E_CURSOR" "$mode" cursors "${ICON_DIRS[@]}")"
        if [ -n "$cur" ] && need plasma-apply-cursortheme; then
            plasma-apply-cursortheme "$cur" >/dev/null 2>&1 && say "  + cursor: $cur"
        else warn "cursor theme not installed"; fi
    fi
    if [ -n "$E_GTK" ]; then
        gtk="$(pick_any "$E_GTK" "$mode" - "${GTK_DIRS[@]}")"
        if [ -n "$gtk" ]; then set_gtk "$gtk" "$mode"; say "  + GTK theme: $gtk"
        else warn "GTK theme not installed"; fi
    fi
    [ "$keep" = 1 ] || set_buttons mac >/dev/null
    apply_wallpaper "$era"
    reload_kwin
    mkdir -p "$STATE"; echo "$era $mode" > "$STATE/current"
    say "Done. Some applications need a restart (or a log out/in) to pick everything up."
}

status() {
    say "Style:        $(cat "$STATE/current" 2>/dev/null || echo 'pearOS default (unchanged)')"
    say "Plasma theme: $(kr kdeglobals KDE LookAndFeelPackage)"
    say "Icons:        $(kr kdeglobals Icons Theme)"
    say "GTK theme:    $(kr gtk-3.0/settings.ini Settings gtk-theme-name)"
    say "Cursor:       $(kr kcminputrc Mouse cursorTheme)"
    say "Accent:       $(kr kdeglobals General AccentColor)"
    say "Buttons L/R:  $(kr kwinrc org.kde.kdecoration2 ButtonsOnLeft) / $(kr kwinrc org.kde.kdecoration2 ButtonsOnRight)"
}

# ------------------------------------------------------------------------- GUI
strip_q() { tr -d '"'; }

gui_apply() {
    local args=() e era mode
    for e in $ERAS; do era_load "$e"; args+=("$e" "$E_LABEL" off); done
    args[2]=on
    era="$(kdialog --title "macOS Style" --radiolist "Choose a macOS version:" "${args[@]}" | strip_q)" || return 0
    [ -n "$era" ] || return 0
    mode="$(kdialog --title "macOS Style" --radiolist "Appearance:" light "Light" on dark "Dark" off | strip_q)" || return 0
    [ -n "$mode" ] || return 0
    local out; out="$(apply_era "$era" "$mode" 0 2>&1)"
    kdialog --title "macOS Style" --msgbox "$out"
}

gui() {
    need kdialog || die "kdialog is not installed; use the command line (see: $APP --help)"
    local pick c
    while :; do
        pick="$(kdialog --title "macOS Style" --menu "Customize how your desktop looks" \
            apply   "Switch macOS version (Aqua to Tahoe)" \
            accent  "Accent colour" \
            buttons "Window buttons" \
            font    "System font" \
            restore "Restore the original pearOS look" | strip_q)" || return 0
        case "$pick" in
            apply)   gui_apply ;;
            accent)  c="$(kdialog --title "Accent colour" --menu "Pick an accent colour" \
                        blue Blue purple Purple pink Pink red Red orange Orange yellow Yellow green Green graphite Graphite | strip_q)" && [ -n "$c" ] && apply_accent "$c" ;;
            buttons) c="$(kdialog --title "Window buttons" --menu "Where should the buttons go?" \
                        mac "macOS style (left)" default "Plasma default" | strip_q)" && [ -n "$c" ] && set_buttons "$c" ;;
            font)    c="$(kdialog --title "System font" --menu "System font" \
                        inter "Inter (SF look-alike)" default "Plasma default" | strip_q)" && [ -n "$c" ] && set_font "$c" ;;
            restore) restore_defaults | kdialog --title "macOS Style" --msgbox "Restored the original pearOS look. Log out and back in for everything to refresh." ;;
            *) return 0 ;;
        esac
    done
}

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------------ entry point
cmd="${1:-gui}"; [ $# -gt 0 ] && shift
case "$cmd" in
    gui)     gui ;;
    list)    list_eras ;;
    status)  status ;;
    accent)  apply_accent "${1:-}" ;;
    buttons) set_buttons "${1:-}" ;;
    font)    set_font "${1:-}" ;;
    restore) restore_defaults ;;
    apply)
        era="${1:-}"; [ -n "$era" ] || die "usage: $APP apply <style> [--dark|--light] [--accent <colour>]"; shift
        mode=light; keep=0; accent=""; once=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --dark) mode=dark ;;
                --light) mode=light ;;
                --accent) accent="${2:-}"; shift ;;
                --keep-buttons) keep=1 ;;
                --once) once=1 ;;
                *) die "unknown option $1" ;;
            esac; shift
        done
        if [ "$once" = 1 ]; then
            [ -e "$STATE/applied-once" ] && exit 0
            mkdir -p "$STATE"; touch "$STATE/applied-once"
        fi
        apply_era "$era" "$mode" "$keep"
        [ -z "$accent" ] || apply_accent "$accent"
        ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
esac
