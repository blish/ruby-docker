# syntax=docker/dockerfile:1
# check=error=true;skip=InvalidDefaultArgInFrom

# Shared base images for Rails production builds.
#   --target runtime  ghcr.io/blish/ruby:<ruby>        final stage of app images
#   --target build    ghcr.io/blish/ruby:<ruby>-build  gem install and asset precompile
ARG RUBY_VERSION
FROM docker.io/library/ruby:${RUBY_VERSION}-slim-trixie AS runtime

# Install base packages and enable jemalloc for reduced memory usage and latency.
# The upgrade applies Debian security patches the upstream ruby tag may not have picked up yet.
RUN apt-get update -qq && \
    apt-get upgrade -y && \
    apt-get install --no-install-recommends -y curl libjemalloc2 imagemagick postgresql-client file && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Run as non-root by default; apps installing extra packages switch to `USER root` and back.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

FROM runtime AS build
USER root

# Install packages needed to build gems and node modules.
# No Debian node-gyp: it pulls in Debian's nodejs; npm bundles its own node-gyp.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config python-is-python3 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Node LTS for asset precompile; the JS package manager is installed by each app.
ARG NODE_VERSION=24.22.1
ENV PATH=/usr/local/node/bin:$PATH
RUN cd /tmp && \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz" && \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" && \
    grep " node-v${NODE_VERSION}-linux-x64.tar.gz\$" SHASUMS256.txt | sha256sum -c - && \
    mkdir -p /usr/local/node && \
    tar xzf "node-v${NODE_VERSION}-linux-x64.tar.gz" -C /usr/local/node --strip-components=1 && \
    rm -f /usr/local/node/bin/corepack && \
    rm -f "node-v${NODE_VERSION}-linux-x64.tar.gz" SHASUMS256.txt
