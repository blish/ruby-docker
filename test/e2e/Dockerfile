# syntax=docker/dockerfile:1
# Compiles a native gem in the build image and loads it in the runtime image as an app would.
ARG BASE
ARG RUBY_VERSION
FROM ${BASE}:${RUBY_VERSION}-build AS build
ENV BUNDLE_FORCE_RUBY_PLATFORM=1
WORKDIR /rails
COPY Gemfile Gemfile.lock ./
RUN bundle install

FROM ${BASE}:${RUBY_VERSION}
WORKDIR /rails
COPY --chown=rails:rails --from=build /usr/local/bundle /usr/local/bundle
COPY --chown=rails:rails --from=build /rails /rails
RUN bundle exec ruby -e 'require "pg"; require "psych"; puts "libpq #{PG.library_version}"'
