# syntax=docker/dockerfile:1

# --- build stage ------------------------------------------------------
# Build the production release (with a bundled ERTS) so the runtime image
# needs no Erlang install of its own. The runtime stage below MUST share
# this image's Debian release (currently trixie) so the bundled ERTS
# links against a matching glibc.
FROM erlang:28 AS build

WORKDIR /src

# Copy only what the build needs; leverages layer caching for deps.
COPY rebar.config rebar.lock ./
COPY config ./config
COPY src ./src
COPY priv ./priv

RUN rebar3 as prod release

# --- runtime stage ----------------------------------------------------
# Slim Debian base matching the erlang:28 build image's release (trixie)
# so the bundled ERTS finds its shared libraries (glibc, OpenSSL, ncurses).
FROM debian:trixie-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         libssl3 libncurses6 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Run as a non-root user.
RUN useradd --system --create-home --home-dir /opt/stw stw
WORKDIR /opt/stw

COPY --from=build --chown=stw:stw /src/_build/prod/rel/stw ./

USER stw

# HTTP (ws) and, when TLS is configured, HTTPS (wss).
EXPOSE 8080 8443

# `foreground` keeps the BEAM in the foreground so Docker owns PID 1's
# lifecycle and signals flow through cleanly.
ENTRYPOINT ["/opt/stw/bin/stw"]
CMD ["foreground"]
