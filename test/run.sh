#!/usr/bin/env bash
# Builds the runtime and build images for one Ruby version and asserts their contents.
# Usage: test/run.sh <ruby-version>
set -uo pipefail
source "$(dirname "$0")/lib.sh"

ruby="${1:?usage: test/run.sh <ruby-version>}"
node="$(grep -oE 'library/node:[0-9.]+' "$root/Dockerfile" | cut -d: -f2)"
runtime="$base:$ruby"
build="$base:$ruby-build"

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
  env | grep -qx LD_PRELOAD=libjemalloc.so.2 &&
  env | grep -qx MALLOC_CONF=narenas:2,background_thread:true,thp:never,dirty_decay_ms:1000,muzzy_decay_ms:0 &&
  env | grep -qx MAGICK_THREAD_LIMIT=1'
jemalloc='ruby -e "exit File.read(%(/proc/self/maps)).include?(%(jemalloc))"'
check "runtime: jemalloc" "$runtime" "$jemalloc"
check_as 1000 "runtime: jemalloc as uid 1000" "$runtime" "$jemalloc"
check "runtime: jemalloc uses 2 arenas" "$runtime" \
  'MALLOC_CONF="$MALLOC_CONF,stats_print:true" ruby -e0 2>&1 | grep -Eq "opt.narenas: 2\$"'
equals "runtime: rails user" "$runtime" "id rails" "uid=1000(rails) gid=1000(rails) groups=1000(rails)"
check "runtime: rails home+shell" "$runtime" "getent passwd rails | grep -q ':/home/rails:/bin/bash\$'"
equals "runtime: runs as uid 1000" "$runtime" "id -u" "1000"
equals "runtime: no workdir" "$runtime" "pwd" "/"
check "runtime: no node/gcc" "$runtime" "! command -v node && ! command -v gcc"
equals "runtime: imagemagick works" "$runtime" \
  "convert -size 1x1 xc:red /tmp/a.png && identify -format %m /tmp/a.png" "PNG"
equals "runtime: svg identified as svg" "$runtime" \
  "echo '<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"/>' > /tmp/a.svg && identify -format %m /tmp/a.svg" "SVG"
check "runtime: no ghostscript" "$runtime" "! command -v gs"
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
check "build: corepack" "$build" "corepack --version && command -v pnpm yarn"
equals "build: pnpm via packageManager" "$build" \
  "cd \$(mktemp -d) && echo '{\"packageManager\":\"pnpm@10.8.0\"}' > package.json && pnpm --version" "10.8.0"
equals "build: yarn via packageManager" "$build" \
  "cd \$(mktemp -d) && echo '{\"packageManager\":\"yarn@1.22.22\"}' > package.json && yarn --version" "1.22.22"
check "build: inherits runtime env" "$build" \
  "env | grep -qx BUNDLE_PATH=/usr/local/bundle && env | grep -qx LD_PRELOAD=libjemalloc.so.2"
equals "build: runs as root" "$build" "id -u" "0"

docker build --platform "$platform" --build-arg RUBY_VERSION="$ruby" --build-arg BASE="$base" \
  --no-cache --progress plain "$root/test/e2e" 2>&1 | grep -E 'libpq|ERROR'
report "e2e: pg gem" "${PIPESTATUS[0]}"

finish
