# Build stage
FROM hexpm/elixir:1.17.3-erlang-27.1.2-debian-bookworm-20241016-slim AS build

RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install deps first (caching layer)
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

# Copy source and compile
COPY config config
COPY lib lib
COPY src src
COPY Makefile ./

# Create priv dir and build NIF from source inside container
RUN mkdir -p priv && make

# Compile Elixir (NIF compiler will skip since priv/nifs.so exists)
RUN mix compile

# Build release
RUN mix release

# Runtime stage
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y \
    libstdc++6 \
    openssl \
    libncurses5 \
    locales \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

COPY --from=build /app/_build/prod/rel/minecraft ./

EXPOSE 25565

CMD ["bin/minecraft", "start"]
