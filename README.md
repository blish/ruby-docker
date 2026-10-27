# ruby-docker

Shared base images for the Rails production Dockerfiles of base-app, website, buchkultur and kiosk.

| Image | Use |
|---|---|
| `ghcr.io/blish/ruby:<ruby>` | Runtime, the final stage of an app image |
| `ghcr.io/blish/ruby:<ruby>-build` | Build stage: `bundle install`, asset precompile |

Ruby versions: 3.4.12, 4.0.9. The list lives in the matrices of `.github/workflows/test.yml` and `build.yml`; keep both in sync. All images are `linux/amd64` and are rebuilt on push to `main`, and without cache weekly and on manual dispatch (with `apt-get upgrade`).

## Contents

**Runtime** (`ruby:<ruby>-slim-trixie`):
- `curl libjemalloc2 imagemagick postgresql-client file`
- jemalloc enabled via `LD_PRELOAD`
- `RAILS_ENV=production`, `BUNDLE_DEPLOYMENT=1`, `BUNDLE_PATH=/usr/local/bundle`, `BUNDLE_WITHOUT=development`
- runs as user `rails` (UID/GID 1000)

**Build** (runtime +):
- `build-essential git libpq-dev libyaml-dev pkg-config python-is-python3`
- Node 24 LTS in `/usr/local/node/bin`, without corepack
- runs as root

**Left to the app:** `WORKDIR`, `ENTRYPOINT`/`CMD`/`EXPOSE`, the JS package manager (pnpm/yarn), app-specific packages, gem credentials (use build secrets). Apps installing extra packages in the runtime stage wrap them in `USER root` … `USER 1000:1000`.

## App Dockerfile

```dockerfile
ARG RUBY_VERSION=3.4.9
FROM ghcr.io/blish/ruby:${RUBY_VERSION}-build AS build
WORKDIR /rails
RUN npm install -g pnpm@10.8.0
COPY Gemfile Gemfile.lock .ruby-version ./
RUN --mount=type=secret,id=BUNDLE_GITHUB__COM,env=BUNDLE_GITHUB__COM bundle install
COPY . .
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile && rm -rf node_modules

FROM ghcr.io/blish/ruby:${RUBY_VERSION}
WORKDIR /rails
COPY --chown=rails:rails --from=build /usr/local/bundle /usr/local/bundle
COPY --chown=rails:rails --from=build /rails /rails
CMD ["./bin/thrust", "./bin/rails", "server"]
```

## Pull access

The package is private. In its package settings, grant read access to the app repositories so their workflows can pull with `GITHUB_TOKEN`. Kamal hosts and builders log in to `ghcr.io` with a token that has `read:packages`.

## Tests

```sh
test/run.sh 3.4.9
```

Builds both images locally for `linux/amd64` and checks their contents, including a native gem compiled in the build image and loaded in the runtime image.
