# syntax=docker/dockerfile:1
# check=error=true;skip=InvalidDefaultArgInFrom

# Shared base images for Rails production builds.
#   --target runtime  ghcr.io/blish/ruby:<ruby>        final stage of app images
#   --target build    ghcr.io/blish/ruby:<ruby>-build  gem install and asset precompile
ARG RUBY_VERSION

# The node image is pinned by digest; Dependabot updates tag and digest.
# Node LTS for asset precompile; Dependabot bumps minor and patch versions of this tag.
FROM docker.io/library/node:24.22.1-trixie-slim@sha256:89c5244bc22a9bc3287d89ebc7e49b9cb5bb84cd40e6175ac3421d5a9f68b95a AS node

FROM docker.io/library/ruby:${RUBY_VERSION}-slim-trixie AS runtime

# Install base packages.
# The upgrade applies Debian security patches the upstream ruby tag may not have picked up yet.
# libmagickcore-*-extra ships ImageMagick's built-in SVG coder, so `identify` reports SVGs
# correctly. Without it SVGs go through the rsvg-convert delegate, are identified as PNG,
# and Alchemy rasterizes them on upload.
RUN apt-get update -qq && \
    apt-get upgrade -y && \
    apt-get install --no-install-recommends -y \
      curl \
      file \
      imagemagick \
      libjemalloc2 \
      libmagickcore-7.q16-10-extra \
      postgresql-client && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development"

# Preload jemalloc 5.3 for reduced memory usage and latency. By default it creates 4 arenas per
# CPU and counts the host's CPUs, not the container's limit, so every Puma worker and Sidekiq
# process gets 4 × host CPUs arenas, which fragments memory. Ruby runs one thread at a time per
# process (GVL), so narenas:2 is enough and the most important setting.
# MAGICK_THREAD_LIMIT keeps ImageMagick from spawning a thread per CPU in every process.
ENV LD_PRELOAD="libjemalloc.so.2" \
    MALLOC_CONF="narenas:2,background_thread:true,thp:never,dirty_decay_ms:1000,muzzy_decay_ms:0" \
    MAGICK_THREAD_LIMIT="1"

# Fail the build if jemalloc isn't loaded or MALLOC_CONF has a typo.
RUN out="$(MALLOC_CONF="${MALLOC_CONF},stats_print:true" ruby -e0 2>&1)" && \
    echo "$out" | grep -q "Begin jemalloc statistics" && \
    ! echo "$out" | grep -q "Invalid conf"

# Run as non-root by default; apps installing extra packages switch to `USER root` and back.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --no-log-init --create-home --shell /bin/bash
USER 1000:1000

FROM runtime AS build
USER root

# Install packages needed to build gems and node modules.
# No Debian node-gyp: it pulls in Debian's nodejs; npm bundles its own node-gyp.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      git \
      libpq-dev \
      libyaml-dev \
      pkg-config \
      python-is-python3 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Node, npm and corepack. Corepack provides pnpm and yarn shims; each app pins its package
# manager via `packageManager` in package.json. Node 25+ no longer bundles corepack: with the
# next LTS, install it via `npm install -g corepack` instead of copying it.
COPY --from=node /usr/local/bin/node /usr/local/node/bin/node
COPY --from=node /usr/local/lib/node_modules/npm /usr/local/node/lib/node_modules/npm
COPY --from=node /usr/local/lib/node_modules/corepack /usr/local/node/lib/node_modules/corepack
ENV PATH=/usr/local/node/bin:$PATH \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/node/bin/npm && \
    ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/node/bin/npx && \
    ln -s ../lib/node_modules/corepack/dist/corepack.js /usr/local/node/bin/corepack && \
    corepack enable --install-directory /usr/local/node/bin
