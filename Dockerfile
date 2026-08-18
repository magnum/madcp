# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t madcp .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name madcp madcp

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Global build args must be declared before the first FROM (used by later FROM lines).
ARG RUBY_VERSION=4.0.5
ARG GWS_VERSION=0.22.5

# --- MCP CLI binaries (hey, basecamp, gws) ---
FROM golang:1.26-bookworm AS basecamp-build
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 https://github.com/basecamp/basecamp-cli .
RUN CGO_ENABLED=0 go build -trimpath -o /out/basecamp ./cmd/basecamp \
    || CGO_ENABLED=0 go build -trimpath -o /out/basecamp .

FROM golang:1.26-bookworm AS hey-build
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 https://github.com/basecamp/hey-cli .
RUN CGO_ENABLED=0 go build -trimpath -o /out/hey ./cmd/hey \
    || CGO_ENABLED=0 go build -trimpath -o /out/hey .

FROM debian:bookworm-slim AS gws-download
ARG TARGETARCH
ARG GWS_VERSION
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp
RUN case "${TARGETARCH}" in \
      amd64) target="x86_64-unknown-linux-musl" ;; \
      arm64) target="aarch64-unknown-linux-musl" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && archive="google-workspace-cli-${target}.tar.gz" \
    && url="https://github.com/googleworkspace/cli/releases/download/v${GWS_VERSION}" \
    && curl -fsSLO "${url}/${archive}" \
    && curl -fsSLO "${url}/${archive}.sha256" \
    && sha256sum -c "${archive}.sha256" \
    && tar -xzf "${archive}" \
    && mkdir -p /out \
    && install -m 0755 gws /out/gws

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
FROM docker.io/library/ruby:${RUBY_VERSION}-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips libsqlite3-0 ca-certificates && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
# CLI config/cache live under the mounted storage volume so tokens survive deploys.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so" \
    HOME="/rails/storage/home" \
    HEY_NO_KEYRING="1" \
    BASECAMP_NO_KEYRING="1" \
    GOOGLE_WORKSPACE_CLI_CONFIG_DIR="/rails/storage/home/.config/gws" \
    GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND="file"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libsqlite3-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile




# Final stage for app image
FROM base

# MCP CLI binaries
COPY --from=basecamp-build /out/basecamp /usr/local/bin/basecamp
COPY --from=hey-build /out/hey /usr/local/bin/hey
COPY --from=gws-download /out/gws /usr/local/bin/gws

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
