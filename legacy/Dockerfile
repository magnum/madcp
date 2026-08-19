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
ARG GWS_VERSION=0.22.5
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

FROM ruby:4.0.6-slim-bookworm

RUN useradd --create-home --uid 10001 emcp \
    && apt-get update \
    && apt-get install -y --no-install-recommends gosu curl build-essential libpq-dev libpq5 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=basecamp-build /out/basecamp /usr/local/bin/basecamp
COPY --from=hey-build /out/hey /usr/local/bin/hey
COPY --from=gws-download /out/gws /usr/local/bin/gws

WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN gem install bundler --no-document \
    && bundle config set --local deployment false \
    && bundle config set --local without development \
    && bundle install --jobs 4 \
    && apt-get purge -y --auto-remove build-essential libpq-dev \
    && apt-get install -y --no-install-recommends libpq5 \
    && rm -rf /var/lib/apt/lists/*

COPY lib ./lib
COPY servers ./servers
COPY views ./views
COPY scripts ./scripts
COPY server.rb config.ru entrypoint.sh ./
RUN chmod +x /app/entrypoint.sh /app/scripts/run-with-reload.sh

ENV HOME=/home/emcp \
    HEY_NO_KEYRING=1 \
    BASECAMP_NO_KEYRING=1 \
    GOOGLE_WORKSPACE_CLI_CONFIG_DIR=/home/emcp/.config/gws \
    GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
    EMCP_HOST=0.0.0.0 \
    EMCP_PORT=8765

EXPOSE 8765

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["bundle", "exec", "ruby", "server.rb"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
    CMD curl -fsS http://127.0.0.1:8765/healthz > /dev/null || exit 1
