#!/usr/bin/env bash
# Builds the runtime and build images for one Ruby version and asserts their contents.
# Usage: test/run.sh <ruby-version>
set -uo pipefail

ruby="${1:?usage: test/run.sh <ruby-version>}"
node="24.22.1"
root="$(cd "$(dirname "$0")/.." && pwd)"
base="ruby-docker-test"
runtime="$base:$ruby"
build="$base:$ruby-build"
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

for target in runtime build; do
  tag="$runtime"; [ "$target" = build ] && tag="$build"
  docker build --quiet --platform "$platform" --build-arg RUBY_VERSION="$ruby" \
    --target "$target" -t "$tag" "$root" >/dev/null || { echo "not ok - build $target"; exit 1; }
done

equals "runtime: ruby version" "$runtime" "ruby -e 'print RUBY_VERSION'" "$ruby"
check "runtime: debian trixie" "$runtime" "grep -q VERSION_CODENAME=trixie /etc/os-release"
check "runtime: packages" "$runtime" "command -v curl convert psql file"
check "runtime: postgres client 17" "$runtime" "psql --version | grep -Eq '^psql \(PostgreSQL\) 17\.'"
check "runtime: env" "$runtime" 'env | grep -qx RAILS_ENV=production &&
  env | grep -qx BUNDLE_DEPLOYMENT=1 &&
  env | grep -qx BUNDLE_PATH=/usr/local/bundle &&
  env | grep -qx BUNDLE_WITHOUT=development &&
  env | grep -qx LD_PRELOAD=/usr/local/lib/libjemalloc.so'
jemalloc='ruby -e "exit File.read(%(/proc/self/maps)).include?(%(jemalloc))"'
check "runtime: jemalloc" "$runtime" "$jemalloc"
check_as 1000 "runtime: jemalloc as uid 1000" "$runtime" "$jemalloc"
equals "runtime: rails user" "$runtime" "id rails" "uid=1000(rails) gid=1000(rails) groups=1000(rails)"
check "runtime: rails home+shell" "$runtime" "getent passwd rails | grep -q ':/home/rails:/bin/bash\$'"
equals "runtime: runs as uid 1000" "$runtime" "id -u" "1000"
equals "runtime: no workdir" "$runtime" "pwd" "/"
check "runtime: no node/gcc" "$runtime" "! command -v node && ! command -v gcc"
equals "runtime: imagemagick works" "$runtime" \
  "convert -size 1x1 xc:red /tmp/a.png && identify -format %m /tmp/a.png" "PNG"
check_as 0 "runtime: debian packages up to date" "$runtime" \
  'apt-get update -qq && [ -z "$(apt list --upgradable 2>/dev/null | tail -n +2)" ]'
check "runtime: apt lists cleaned" "$runtime" 'test -z "$(ls -A /var/lib/apt/lists 2>/dev/null)"'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.ExposedPorts}}' "$runtime")" = "null null" ]
report "runtime: no entrypoint/expose" $?

equals "build: node version" "$build" "node --version" "v$node"
check "build: npm" "$build" "npm --version"
equals "build: node path" "$build" "command -v node" "/usr/local/node/bin/node"
check "build: toolchain" "$build" "command -v gcc make git pkg-config python && dpkg -s libpq-dev libyaml-dev"
check "build: single node" "$build" "! test -e /usr/bin/node && ! dpkg -s nodejs"
check "build: npm node-gyp" "$build" 'test -f "$(npm prefix -g)/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js"'
check "build: no corepack/pnpm/yarn" "$build" "! command -v corepack && ! command -v pnpm && ! command -v yarn"
check "build: inherits runtime env" "$build" \
  "env | grep -qx BUNDLE_PATH=/usr/local/bundle && env | grep -qx LD_PRELOAD=/usr/local/lib/libjemalloc.so"
equals "build: runs as root" "$build" "id -u" "0"

docker build --platform "$platform" --build-arg RUBY_VERSION="$ruby" --build-arg BASE="$base" \
  --no-cache --progress plain "$root/test/e2e" 2>&1 | grep -E 'libpq|ERROR'
report "e2e: pg gem" "${PIPESTATUS[0]}"

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
