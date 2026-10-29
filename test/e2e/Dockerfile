# syntax=docker/dockerfile:1
# Compiles a native gem in the build image and loads it in the runtime image as an app would.
ARG BUILD_IMAGE
ARG RUNTIME_IMAGE
FROM ${BUILD_IMAGE} AS build
ENV BUNDLE_FORCE_RUBY_PLATFORM=1
WORKDIR /rails
COPY Gemfile Gemfile.lock ./
RUN bundle install

FROM ${RUNTIME_IMAGE}
WORKDIR /rails
COPY --chown=rails:rails --from=build /usr/local/bundle /usr/local/bundle
COPY --chown=rails:rails --from=build /rails /rails
RUN bundle exec ruby -e 'require "pg"; require "psych"; puts "libpq #{PG.library_version}"'
