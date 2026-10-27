# syntax=docker/dockerfile:1
# Runtime image with Ghostscript added the way apps opt in (see README).
ARG BASE
ARG RUBY_VERSION
FROM ${BASE}:ghostscript AS ghostscript

FROM ${BASE}:${RUBY_VERSION}
COPY --from=ghostscript /usr/local/ /usr/local/
