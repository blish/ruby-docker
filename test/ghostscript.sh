#!/usr/bin/env bash
# Builds the Ghostscript image, copies it into Debian trixie the way apps opt in, and asserts
# that gs works there.
# Usage: test/ghostscript.sh
# Set GHOSTSCRIPT_IMAGE to test an already built image instead (CI).
set -uo pipefail
source "$(dirname "$0")/lib.sh"

ghostscript="$(grep -oE 'GHOSTSCRIPT_VERSION=[0-9.]+' "$root/ghostscript/Dockerfile" | cut -d= -f2)"
ghostscript_image="${GHOSTSCRIPT_IMAGE:-$base:ghostscript}"
image="$base:ghostscript-opt-in"

if [ -z "${GHOSTSCRIPT_IMAGE:-}" ]; then
  docker build --quiet --platform "$platform" -t "$ghostscript_image" "$root/ghostscript" >/dev/null ||
    { echo "not ok - build ghostscript"; exit 1; }
fi
docker build --quiet --platform "$platform" --build-arg GHOSTSCRIPT_IMAGE="$ghostscript_image" \
  -t "$image" "$root/test/ghostscript" >/dev/null || { echo "not ok - build ghostscript opt-in"; exit 1; }

equals "ghostscript: version" "$image" "gs --version" "$ghostscript"
equals "ghostscript: path" "$image" "command -v gs" "/usr/local/bin/gs"
check "ghostscript: libraries" "$image" '! ldd /usr/local/bin/gs | grep -q "not found"'
check_as 1000 "ghostscript: writes pdf as uid 1000" "$image" \
  "gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite -o /tmp/a.pdf -c showpage && head -c 5 /tmp/a.pdf | grep -q %PDF-"

finish
