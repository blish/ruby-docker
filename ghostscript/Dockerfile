# syntax=docker/dockerfile:1
# check=error=true

# ghcr.io/blish/ruby-ghostscript:<version>
# Ghostscript for ZUGFeRD invoice PDFs. Debian trixie ships 10.05.1, whose ZUGFeRD embedding
# PDFBox can't read; 10.06+ is needed. Not part of the ruby images: apps that need it copy
# this image's /usr/local into their final stage. Separate from ../Dockerfile, which is
# built per Ruby version.
# Releases: https://github.com/ArtifexSoftware/ghostpdl-downloads/releases
# The debian image is pinned by digest; Dependabot updates it.
# Updated by bin/update-ghostscript (weekly via .github/workflows/update-ghostscript.yml).
FROM docker.io/library/debian:trixie-slim@sha256:89c1ea91e897f0fe0a3731595330bc45b8bdef4047464a07116f891a94054b31 AS ghostscript-build
ARG GHOSTSCRIPT_VERSION=10.08.0
ARG GHOSTSCRIPT_TAG=gs10080
ADD --checksum=sha256:caf199e3f233f1290b27d0972d636f66c303355f2353309b7bfddf1edda06b3d \
    https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/${GHOSTSCRIPT_TAG}/ghostscript-${GHOSTSCRIPT_VERSION}.tar.gz /tmp/
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential && \
    tar xzf "/tmp/ghostscript-${GHOSTSCRIPT_VERSION}.tar.gz" -C /tmp
WORKDIR /tmp/ghostscript-${GHOSTSCRIPT_VERSION}
RUN ./configure --without-x --disable-cups --disable-gtk --disable-dbus --disable-fontconfig \
      --without-tesseract --without-libidn --without-libpaper && \
    make -j"$(nproc)" && \
    make install DESTDIR=/ghostscript && \
    rm -rf /ghostscript/usr/local/share/man /ghostscript/usr/local/share/doc

FROM scratch AS ghostscript
COPY --from=ghostscript-build /ghostscript/usr/local/ /usr/local/
