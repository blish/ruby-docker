# syntax=docker/dockerfile:1
# Ghostscript copied into plain Debian trixie, the base of the ruby images, the way apps opt in.
ARG BASE
FROM ${BASE}:ghostscript AS ghostscript

FROM docker.io/library/debian:trixie-slim
COPY --from=ghostscript /usr/local/ /usr/local/
