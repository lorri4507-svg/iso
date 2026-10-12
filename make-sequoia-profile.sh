#!/usr/bin/env bash
# make-sequoia-profile.sh
# Run from the root of your iso repo (the folder containing build-iso.sh and profiles/).
# Creates profiles/sequoia as a full copy of profiles/pear, then layers the
# Sequoia features on top via sequoia-features.sh (must sit next to this script).
set -euo pipefail

SRC="profiles/pear"
DST="profiles/sequoia"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -d "$SRC" ] || { echo "Run this from the repo root: $SRC not found." >&2; exit 1; }
[ ! -e "$DST" ] || { echo "$DST already exists, refusing to overwrite." >&2; exit 1; }
[ -f "$HERE/sequoia-features.sh" ] || { echo "sequoia-features.sh must be next to this script." >&2; exit 1; }

cp -a "$SRC" "$DST"
mkdir -p "$DST/wallpapers"
install -m 0755 "$HERE/sequoia-features.sh" "$DST/sequoia-features.sh"

# Wrap the copied profile_customize() so the Sequoia step runs after pear's own.
cat >> "$DST/customize.sh" <<'EOF'

# ---- Sequoia additions (appended by make-sequoia-profile.sh) ----
_SEQ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if declare -F profile_customize >/dev/null; then
  eval "pear_$(declare -f profile_customize)"
  profile_customize() {
    pear_profile_customize "$@"
    # TODO: set this to whatever variable build-iso.sh uses for the target rootfs
    local _root="${TARGET_ROOTFS:-${ROOTFS:-${TARGET_DIR:-${TARGET:-}}}}"
    [ -n "$_root" ] || { echo "[sequoia] rootfs variable not found; edit customize.sh" >&2; return 1; }
    bash "$_SEQ_DIR/sequoia-features.sh" "$_root"
  }
fi
EOF

echo
echo "Created $DST. Now rename it in profile.conf (display name, slug, ISO label/prefix)."
echo "Lines that still mention pear/pulsar:"
grep -nEi 'pear|pulsar' "$DST/profile.conf" || true
echo
echo "Optional: put wallpapers in $DST/wallpapers/, then build with:"
echo "  sudo ./build-iso.sh --profile sequoia"
