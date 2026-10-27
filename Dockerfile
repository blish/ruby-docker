# syntax=docker/dockerfile:1
# check=error=true;skip=InvalidDefaultArgInFrom

# Shared base images for Rails production builds.
#   --target runtime  ghcr.io/blish/ruby:<ruby>        final stage of app images
#   --target build    ghcr.io/blish/ruby:<ruby>-build  gem install and asset precompile
#   --target ghostscript  ghcr.io/blish/ruby-ghostscript:<version>  opt-in, see README
ARG RUBY_VERSION

# Node LTS for asset precompile; Dependabot bumps minor and patch versions of this tag.
FROM docker.io/library/node:24.22.1-trixie-slim AS node

# Ghostscript for ZUGFeRD invoice PDFs. Debian trixie ships 10.05.1, whose ZUGFeRD embedding
# PDFBox can't read; 10.06+ is needed. Not part of runtime: apps that need it copy the
# `ghostscript` image's /usr/local into their final stage.
# Releases: https://github.com/ArtifexSoftware/ghostpdl-downloads/releases
FROM docker.io/library/debian:trixie-slim AS ghostscript-build
ARG GHOSTSCRIPT_VERSION=10.08.0
ARG GHOSTSCRIPT_TAG=gs10080
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential ca-certificates curl && \
    cd /tmp && \
    curl -fsSLO "https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/${GHOSTSCRIPT_TAG}/ghostscript-${GHOSTSCRIPT_VERSION}.tar.gz" && \
    curl -fsSLO "https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/${GHOSTSCRIPT_TAG}/SHA512SUMS" && \
    grep " ghostscript-${GHOSTSCRIPT_VERSION}.tar.gz\$" SHA512SUMS | sha512sum -c - && \
    tar xzf "ghostscript-${GHOSTSCRIPT_VERSION}.tar.gz" && \
    cd "ghostscript-${GHOSTSCRIPT_VERSION}" && \
    ./configure --without-x --disable-cups --disable-gtk --disable-dbus --disable-fontconfig \
      --without-tesseract --without-libidn --without-libpaper && \
    make -j"$(nproc)" && \
    make install DESTDIR=/ghostscript && \
    rm -rf /ghostscript/usr/local/share/man /ghostscript/usr/local/share/doc

FROM scratch AS ghostscript
COPY --from=ghostscript-build /ghostscript/usr/local/ /usr/local/

FROM docker.io/library/ruby:${RUBY_VERSION}-slim-trixie AS runtime

# Install base packages and enable jemalloc for reduced memory usage and latency.
# The upgrade applies Debian security patches the upstream ruby tag may not have picked up yet.
# libmagickcore-*-extra ships ImageMagick's built-in SVG coder, so `identify` reports SVGs
# correctly. Without it SVGs go through the rsvg-convert delegate, are identified as PNG,
# and Alchemy rasterizes them on upload.
RUN apt-get update -qq && \
    apt-get upgrade -y && \
    apt-get install --no-install-recommends -y curl libjemalloc2 imagemagick libmagickcore-7.q16-10-extra postgresql-client file && \
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
