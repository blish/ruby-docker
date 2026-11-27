# ruby-docker

Shared base images for the Rails production Dockerfiles of base-app, website, buchkultur and kiosk.

| Image | Use |
|---|---|
| `ghcr.io/blish/ruby:<ruby>` | Runtime with ImageMagick, the final stage of an app image; also tagged `<ruby>-imagemagick` |
| `ghcr.io/blish/ruby:<ruby>-build` | Build stage: `bundle install`, asset precompile; also tagged `<ruby>-imagemagick-build` |
| `ghcr.io/blish/ruby:<ruby>-vips` | Runtime with libvips instead of ImageMagick |
| `ghcr.io/blish/ruby:<ruby>-vips-build` | Build stage for `<ruby>-vips` |
| `ghcr.io/blish/ghostscript:<version>` | Opt-in Ghostscript, see [Ghostscript](#ghostscript) |

Both variants are identical apart from the image processor, see [Contents](#contents).

These tags always point to the latest build. To pin a build, append the release, e.g. `3.4.13-20261117` or `3.4.13-vips-build-20261117`; these tags are never overwritten. See [Releases](#releases).

Ruby versions: 3.4.13, 4.0.10. The list lives in the matrix of `.github/workflows/build.yml`, next to the image processors. All images are `linux/amd64`. The pipeline builds the images, tests exactly those images and pushes them only from `main`, if they changed since the latest release: on every push, and without cache weekly and on manual dispatch (with `apt-get upgrade`). On PRs it builds and tests without pushing.

## Releases

[GitHub Releases](https://github.com/blish/ruby-docker/releases) are the changelog. On `main`, `build.yml` works in three steps:

1. `bin/release-version` picks the release tag from the date (`YYYYMMDD`, with `.1`, `.2` … for further releases that day) and checks for commits since the latest release.
2. Each image is built and tested. A Ruby image is pushed, as `<ruby>[-imagemagick|-vips]` and `<ruby>[-imagemagick|-vips]-<release>`, if there are new commits or `bin/package-changes` finds a changed package compared to the latest release's package list (`bin/image-packages`). The Ghostscript image is only pushed with new commits.
3. If any image was pushed, a release is published with notes from `bin/release-notes`. Otherwise there is no release.

Each release lists:

- **Images**: the pushed tags with their digests
- **Package updates**: changed Debian packages, Ruby, gems, Node, npm and corepack per Ruby version and variant. This shows what the weekly rebuild picked up. The full lists are attached as `packages-ruby-<ruby>[-vips].txt`
- **Merged PRs**, grouped by label as configured in `.github/release.yml`: image updates (`docker`), CI (`github_actions`) and others

The images carry the release in their labels (`org.opencontainers.image.version`, `org.opencontainers.image.url`), next to a description shown on the package page.

## Contents

**Runtime** (`ruby:<ruby>-slim-trixie`):
- `curl file libjemalloc2 postgresql-client`
- `<ruby>`: `imagemagick libmagickcore-7.q16-10-extra` (the `-extra` package adds ImageMagick's built-in SVG coder) and `MAGICK_THREAD_LIMIT=1`
- `<ruby>-vips`: `libvips42t64` (the default Active Storage variant processor, used via the `ruby-vips` gem) and `VIPS_CONCURRENCY=1`
- jemalloc enabled via `LD_PRELOAD` and tuned via `MALLOC_CONF` (2 arenas, background purging, no transparent huge pages). Apps can override it and the thread limits at runtime
- `RAILS_ENV=production`, `BUNDLE_DEPLOYMENT=1`, `BUNDLE_PATH=/usr/local/bundle`, `BUNDLE_WITHOUT=development`
- runs as user `rails` (UID/GID 1000)

**Build** (runtime +):
- `build-essential git libpq-dev libyaml-dev pkg-config python-is-python3`
- Node 24 LTS (from the official `node` image) in `/usr/local/node/bin`, with corepack enabled: `pnpm` and `yarn` use the version from the app's `packageManager` field in `package.json`
- runs as root

**Left to the app:** `WORKDIR`, `ENTRYPOINT`/`CMD`/`EXPOSE`, the JS package manager and its version (`packageManager` in `package.json`), app-specific packages, gem credentials (use build secrets). Apps installing extra packages in the runtime stage wrap them in `USER root` … `USER 1000:1000`.

## App Dockerfile

```dockerfile
ARG RUBY_VERSION=3.4.13
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

Apps using libvips use `${RUBY_VERSION}-vips-build` and `${RUBY_VERSION}-vips` instead.

## Ghostscript

Ghostscript is not part of the runtime image. Only apps that generate ZUGFeRD invoice PDFs (blish 9+, `embed_zugferd_invoice`) need it; Debian trixie's Ghostscript 10.05 produces PDFs that PDFBox can't read, so 10.06+ is built from source here. Leaving it out keeps the runtime image smaller and avoids handing uploaded PDF/EPS files to Ghostscript in apps that don't need it.

To opt in, copy it into the app's final stage:

```dockerfile
FROM ghcr.io/blish/ruby:${RUBY_VERSION}
COPY --from=ghcr.io/blish/ghostscript:10.08.0 /usr/local/ /usr/local/
```

This adds `/usr/local/bin/gs` and its resources in `/usr/local/share/ghostscript`. Nothing is compiled in the app.

Ghostscript isn't tracked by Dependabot or covered by Debian security updates. Instead, `.github/workflows/update-ghostscript.yml` checks for a new release every Monday and has blish-bot open a PR. To update manually, run `bin/update-ghostscript` (needs an authenticated `gh`): it bumps `GHOSTSCRIPT_VERSION`, `GHOSTSCRIPT_TAG` and the sha256 in `ADD --checksum` in `ghostscript/Dockerfile` after verifying the tarball against the release's `SHA512SUMS`. After merging, bump the version in each app's `COPY --from`.

## Pull access

The packages are public.

## Tests

```sh
test/run.sh 3.4.13 vips   # runtime and build images (imagemagick or vips)
test/ghostscript.sh       # Ghostscript image, copied into Debian trixie
test/release.sh           # release scripts in bin/
```

`test/run.sh` builds the images locally for `linux/amd64` and checks their contents, including a native gem compiled in the build image and loaded in the runtime image. Needs network access: the corepack checks download pnpm and yarn.

`test/ghostscript.sh` builds `ghostscript/`, copies it into `debian:trixie-slim` (the base of the ruby images) as described above and checks that `gs` works there.

`test/release.sh` tests the release scripts against stubbed `docker`, `gh` and `git`, so it needs neither Docker nor network. Needs a local Ruby for `bin/image-packages`.

In CI, `build.yml` runs `test/release.sh` before it picks the release, and the image tests against the images it just built (via `RUNTIME_IMAGE`/`BUILD_IMAGE` and `GHOSTSCRIPT_IMAGE`) before pushing.
