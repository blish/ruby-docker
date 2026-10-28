# ruby-docker

Shared base images for the Rails production Dockerfiles of base-app, website, buchkultur and kiosk.

| Image | Use |
|---|---|
| `ghcr.io/blish/ruby:<ruby>` | Runtime, the final stage of an app image |
| `ghcr.io/blish/ruby:<ruby>-build` | Build stage: `bundle install`, asset precompile |
| `ghcr.io/blish/ruby-ghostscript:<version>` | Opt-in Ghostscript, see [Ghostscript](#ghostscript) |

Ruby versions: 3.4.12, 4.0.9. The list lives in the matrices of `.github/workflows/test.yml` and `build.yml`; keep both in sync. All images are `linux/amd64` and are rebuilt on push to `main`, and without cache weekly and on manual dispatch (with `apt-get upgrade`).

## Contents

**Runtime** (`ruby:<ruby>-slim-trixie`):
- `curl file imagemagick libjemalloc2 libmagickcore-7.q16-10-extra postgresql-client` (the `-extra` package adds ImageMagick's built-in SVG coder)
- jemalloc enabled via `LD_PRELOAD` and tuned via `MALLOC_CONF` (2 arenas, background purging, no transparent huge pages); `MAGICK_THREAD_LIMIT=1`. Apps can override both at runtime
- `RAILS_ENV=production`, `BUNDLE_DEPLOYMENT=1`, `BUNDLE_PATH=/usr/local/bundle`, `BUNDLE_WITHOUT=development`
- runs as user `rails` (UID/GID 1000)

**Build** (runtime +):
- `build-essential git libpq-dev libyaml-dev pkg-config python-is-python3`
- Node 24 LTS (from the official `node` image) in `/usr/local/node/bin`, with corepack enabled: `pnpm` and `yarn` use the version from the app's `packageManager` field in `package.json`
- runs as root

**Left to the app:** `WORKDIR`, `ENTRYPOINT`/`CMD`/`EXPOSE`, the JS package manager and its version (`packageManager` in `package.json`), app-specific packages, gem credentials (use build secrets). Apps installing extra packages in the runtime stage wrap them in `USER root` … `USER 1000:1000`.

## App Dockerfile

```dockerfile
ARG RUBY_VERSION=3.4.12
FROM ghcr.io/blish/ruby:${RUBY_VERSION}-build AS build
WORKDIR /rails
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

## Ghostscript

Ghostscript is not part of the runtime image. Only apps that generate ZUGFeRD invoice PDFs (blish 9+, `embed_zugferd_invoice`) need it; Debian trixie's Ghostscript 10.05 produces PDFs that PDFBox can't read, so 10.06+ is built from source here. Leaving it out keeps the runtime image smaller and avoids handing uploaded PDF/EPS files to Ghostscript in apps that don't need it.

To opt in, copy it into the app's final stage:

```dockerfile
FROM ghcr.io/blish/ruby:${RUBY_VERSION}
COPY --from=ghcr.io/blish/ruby-ghostscript:10.08.0 /usr/local/ /usr/local/
```

This adds `/usr/local/bin/gs` and its resources in `/usr/local/share/ghostscript`. Nothing is compiled in the app.

Ghostscript isn't tracked by Dependabot or covered by Debian security updates. Instead, `.github/workflows/update-ghostscript.yml` checks for a new release every Monday and has blish-bot open a PR. To update manually, run `bin/update-ghostscript` (needs an authenticated `gh`): it bumps `GHOSTSCRIPT_VERSION`, `GHOSTSCRIPT_TAG` and the sha256 in `ADD --checksum` in `ghostscript/Dockerfile` after verifying the tarball against the release's `SHA512SUMS`. After merging, bump the version in each app's `COPY --from`.

## Pull access

The packages are private. In the package settings of `ruby` and `ruby-ghostscript`, grant read access to the app repositories so their workflows can pull with `GITHUB_TOKEN`. Kamal hosts and builders log in to `ghcr.io` with a token that has `read:packages`.

## Tests

```sh
test/run.sh 3.4.12        # runtime and build images
test/ghostscript.sh       # Ghostscript image, copied into Debian trixie
```

`test/run.sh` builds the images locally for `linux/amd64` and checks their contents, including a native gem compiled in the build image and loaded in the runtime image. Needs network access: the corepack checks download pnpm and yarn.

`test/ghostscript.sh` builds `ghostscript/`, copies it into `debian:trixie-slim` (the base of the ruby images) as described above and checks that `gs` works there.

Both run on every PR as jobs of `test.yml`.
