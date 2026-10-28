# Shared helpers for the test scripts; source it after setting `set -uo pipefail`.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base="ruby-docker-test"
platform="linux/amd64"
failures=0

report() {
  if [ "$2" -eq 0 ]; then echo "ok - $1"; else echo "not ok - $1"; failures=$((failures + 1)); fi
}

# @param name [String] assertion name
# @param image [String] image to run
# @param cmd [String] bash command; passes on exit 0
check() {
  docker run --rm --platform "$platform" "$2" bash -c "$3" >/dev/null 2>&1
  report "$1" $?
}

# @param uid [Integer] user to run as
check_as() {
  docker run --rm --platform "$platform" --user "$1" "$3" bash -c "$4" >/dev/null 2>&1
  report "$2" $?
}

# @param expected [String] exact stdout
equals() {
  [ "$(docker run --rm --platform "$platform" "$2" bash -c "$3" 2>/dev/null)" = "$4" ]
  report "$1" $?
}

# Exits non-zero if any assertion failed.
finish() {
  [ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
}
