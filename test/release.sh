#!/usr/bin/env bash
# Tests the release scripts in bin/ against stubbed docker, gh and git: no Docker, network or GitHub needed.
# Usage: test/release.sh
set -uo pipefail
source "$(dirname "$0")/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stubs="$tmp/stubs"
mkdir -p "$stubs"
export STUBS_LOG="$tmp/calls.log"

# @param name [String] assertion name
# @param expected [String]
# @param actual [String]
assert_equal() {
  [ "$2" = "$3" ]
  report "$1" $?
  [ "$2" = "$3" ] || printf '# expected:\n%s\n# actual:\n%s\n' "$2" "$3"
}

# @param name [String] assertion name
# @param pattern [String] extended regex one line of text must match
# @param text [String]
assert_line() {
  grep -Eq -- "$2" <<< "$3"
  report "$1" $?
}

# @param path [String] file to create as executable
# @param body [String] script body, run by bash
stub() {
  printf '#!/bin/bash\n%s\n' "$2" > "$1"
  chmod +x "$1"
}

# docker: `run --rm --user root <image> sh -c <script>` runs <script> locally, with only $INNER_PATH on the PATH.
stub "$stubs/docker" '
echo "docker $*" >> "$STUBS_LOG"
[ "$1 $2 $3 $4 $6 $7" = "run --rm --user root sh -c" ] || exit 99
PATH="$INNER_PATH" exec /bin/sh -c "$8"'

# gh: GH_PREVIOUS is the latest release, GH_COMMITS the commits since it, GH_ASSETS its attached files.
stub "$stubs/gh" '
echo "gh $*" >> "$STUBS_LOG"
case "$1 $2" in
  "release view") [ -n "${GH_PREVIOUS:-}" ] || exit 1; echo "$GH_PREVIOUS" ;;
  "api "*) echo "${GH_COMMITS:-0}" ;;
  "release download") cp "$GH_ASSETS"/* "${@: -1}" ;;
  *) exit 99 ;;
esac'

# git: GIT_TAGS are the tags on origin; GIT_FAIL makes ls-remote fail like an unreachable remote.
stub "$stubs/git" '
case "$1" in
  rev-parse) echo head-sha ;;
  ls-remote)
    [ -z "${GIT_FAIL:-}" ] || exit 128
    [[ " ${GIT_TAGS:-} " == *" ${5#refs/tags/} "* ]] && exit 0
    exit 2 ;;
  *) exit 99 ;;
esac'

export PATH="$stubs:$PATH"

# --- bin/package-changes

printf 'tzdata 2025b\nlibssl3 3.5.1-1\nfoo 1\n' > "$tmp/old"
printf 'bar 2\nlibssl3 3.5.1-2\ntzdata 2025b\n' > "$tmp/new"

assert_equal "package-changes: lists changed, added and removed packages" \
  "$(printf -- '- `bar` 2 (added)\n- `foo` 1 (removed)\n- `libssl3` 3.5.1-1 → 3.5.1-2')" \
  "$("$root/bin/package-changes" "$tmp/old" "$tmp/new")"
assert_equal "package-changes: prints nothing for equal lists" \
  "" "$("$root/bin/package-changes" "$tmp/old" "$tmp/old")"

# --- bin/image-packages

inner="$tmp/inner"
inner_node="$tmp/inner-node"
mkdir -p "$inner" "$inner_node"
stub "$inner/dpkg-query" 'printf "zlib1g 1:1.3\nlibc6 2.41-12\n"'
stub "$inner/ruby" "exec $(command -v ruby) \"\$@\""
stub "$inner/tr" "exec $(command -v tr) \"\$@\""
stub "$inner_node/node" 'echo v24.22.2'
stub "$inner_node/npm" 'echo 11.6.2'
stub "$inner_node/corepack" 'echo 0.34.0'
ruby_version="$(ruby -e 'print RUBY_VERSION')"

: > "$STUBS_LOG"
packages="$(INNER_PATH="$inner_node:$inner" "$root/bin/image-packages" ghcr.io/blish/ruby:3.4.13-build)"
assert_line "image-packages: runs the image as root" "^docker run --rm --user root ghcr.io/blish/ruby:3.4.13-build " "$(cat "$STUBS_LOG")"
assert_line "image-packages: debian packages" "^libc6 2\.41-12$" "$packages"
assert_line "image-packages: ruby" "^ruby $ruby_version$" "$packages"
assert_line "image-packages: gems with prefix" "^gem:bundler [0-9.,]+$" "$packages"
assert_line "image-packages: node" "^node 24\.22\.2$" "$packages"
assert_line "image-packages: npm" "^npm 11\.6\.2$" "$packages"
assert_line "image-packages: corepack" "^corepack 0\.34\.0$" "$packages"
assert_equal "image-packages: sorted" "$(LC_ALL=C sort <<< "$packages")" "$packages"
assert_equal "image-packages: one version per name" "" "$(cut -d ' ' -f 1 <<< "$packages" | uniq -d)"

packages="$(INNER_PATH="$inner" "$root/bin/image-packages" ghcr.io/blish/ruby:3.4.13)"
! grep -Eq '^(node|npm|corepack) ' <<< "$packages"
report "image-packages: no node lines without node" $?

# --- bin/release-version

today="$(date -u +%Y%m%d)"

assert_equal "release-version: first release" \
  "$(printf 'tag=%s\nprevious=\ncode-changed=true' "$today")" \
  "$(GIT_TAGS="" GH_PREVIOUS="" "$root/bin/release-version")"

: > "$STUBS_LOG"
assert_equal "release-version: no commits since the latest release" \
  "$(printf 'tag=%s\nprevious=20261110\ncode-changed=false' "$today")" \
  "$(GIT_TAGS="20261110" GH_PREVIOUS="20261110" GH_COMMITS=0 "$root/bin/release-version" abc123)"
assert_line "release-version: compares the latest release with the given commit" \
  "^gh api repos/\{owner\}/\{repo\}/compare/20261110\.\.\.abc123 " "$(cat "$STUBS_LOG")"

: > "$STUBS_LOG"
assert_equal "release-version: commits since the latest release" \
  "code-changed=true" \
  "$(GIT_TAGS="20261110" GH_PREVIOUS="20261110" GH_COMMITS=3 "$root/bin/release-version" | tail -n 1)"
assert_line "release-version: compares with HEAD by default" "/compare/20261110\.\.\.head-sha " "$(cat "$STUBS_LOG")"

assert_equal "release-version: counts up for further releases that day" \
  "tag=$today.2" \
  "$(GIT_TAGS="$today $today.1" GH_PREVIOUS="$today.1" "$root/bin/release-version" | head -n 1)"

GIT_FAIL=1 "$root/bin/release-version" > /dev/null 2>&1
[ $? -ne 0 ]
report "release-version: fails if origin can't be read" $?

# --- bin/release-notes

current="$tmp/current"
assets="$tmp/assets"
mkdir -p "$current" "$assets"
printf 'ghcr.io/blish/ruby:3.4.13@sha256:aaa\nghcr.io/blish/ruby:3.4.13-build@sha256:bbb\n' > "$current/images-ruby-3.4.13.txt"
printf 'ghcr.io/blish/ghostscript:10.08.0@sha256:ccc\n' > "$current/images-ghostscript.txt"
printf 'libssl3 3.5.1-2\nruby 3.4.13\n' > "$current/packages-ruby-3.4.13.txt"
printf 'ruby 4.0.10\n' > "$current/packages-ruby-4.0.10.txt"
printf 'libssl3 3.5.1-1\nruby 3.4.13\n' > "$assets/packages-ruby-3.4.13.txt"

images='## Images

- `ghcr.io/blish/ghostscript:10.08.0` `sha256:ccc`
- `ghcr.io/blish/ruby:3.4.13` `sha256:aaa`
- `ghcr.io/blish/ruby:3.4.13-build` `sha256:bbb`

## Package updates'

assert_equal "release-notes: package changes per Ruby version, new Ruby versions" "$images

### Ruby 3.4.13

- \`libssl3\` 3.5.1-1 → 3.5.1-2

### Ruby 4.0.10

New in this release." \
  "$(GH_ASSETS="$assets" "$root/bin/release-notes" "$current" 20261110)"

: > "$STUBS_LOG"
assert_equal "release-notes: first release" "$images

First release. The package lists are attached." \
  "$("$root/bin/release-notes" "$current")"
assert_equal "release-notes: first release doesn't call gh" "" "$(cat "$STUBS_LOG")"

cp "$current/packages-ruby-3.4.13.txt" "$current/packages-ruby-4.0.10.txt" "$assets/"
assert_equal "release-notes: no package changes" "$images

No package changes." \
  "$(GH_ASSETS="$assets" "$root/bin/release-notes" "$current" 20261110)"

finish
