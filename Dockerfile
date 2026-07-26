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

FROM ruby:4.0.6-slim-bookworm

RUN useradd --create-home --uid 10001 madcp \
    && apt-get update \
    && apt-get install -y --no-install-recommends gosu curl build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY --from=basecamp-build /out/basecamp /usr/local/bin/basecamp
COPY --from=hey-build /out/hey /usr/local/bin/hey

WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN gem install bundler --no-document \
    && bundle config set --local deployment false \
    && bundle config set --local without development \
    && bundle install --jobs 4 \
    && apt-get purge -y --auto-remove build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY lib ./lib
COPY servers ./servers
COPY views ./views
COPY server.rb config.ru entrypoint.sh ./
RUN chmod +x /app/entrypoint.sh

ENV HOME=/home/madcp \
    HEY_NO_KEYRING=1 \
    BASECAMP_NO_KEYRING=1 \
    MADCP_HOST=0.0.0.0 \
    MADCP_PORT=8765

EXPOSE 8765

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["bundle", "exec", "ruby", "server.rb"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
    CMD curl -fsS http://127.0.0.1:8765/healthz > /dev/null || exit 1
