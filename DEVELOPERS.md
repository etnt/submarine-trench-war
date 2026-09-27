# Developer guide

This guide covers how to build, test, and deploy Submarine Trench War. For game rules, see [README.md](README.md).

## Requirements

- Erlang/OTP 28 or newer
- rebar3 3.24 or newer

## Build, test, and run

```sh
rebar3 compile
rebar3 eunit
rebar3 shell
```

The `Makefile` provides the same commands: `make compile`, `make test`, and `make run`.

The server listens on port `8080` by default. It serves the client at `/` and the WebSocket endpoint at `/ws`. Open `http://localhost:8080` in a browser to play.

## Tests

Run the EUnit suite with `rebar3 eunit` or `make test`. Tests are in `test/`. The engine and vision modules are pure, so most tests for game logic do not need to start server processes.

## Architecture

The Erlang server keeps the full match state. For players, it filters each game state and replay to their visibility. Spectators get a full-board view.

- `stw_app` and `stw_sup` start and supervise the application.
- `stw_lobby` manages players, sessions, and rooms.
- `stw_game_sup` starts one `stw_game` process for each match. The game process holds the match state.
- `stw_engine` resolves a round. It is a deterministic pure function that returns the new state and a replay for each phase.
- `stw_board` stores maps, including walls, spawn points, currents, mines, and vents.
- `stw_vision` calculates what a submarine can see.
- `stw_ws_handler` connects WebSocket clients to their game process.
- `priv/index.html` contains the client: drawing, animation, input, and WebSocket code.

The client and server exchange JSON messages in an envelope with `type`, `seq`, `ts`, and `payload` fields. The server filters each player's game state and round replay according to that player's visibility.

The message format is documented in [plan/PROTOCOL.md](plan/PROTOCOL.md).

## Project layout

```text
src/       Erlang server modules
priv/      HTML, CSS, and JavaScript client
test/      EUnit tests
config/    Runtime configuration and VM arguments
plan/      Design, protocol, and implementation documents
Makefile   Build, test, and deployment commands
```

## Production release

Build a release with a bundled Erlang runtime. The host does not need a separate Erlang installation.

```sh
make release
_build/prod/rel/stw/bin/stw foreground
```

The release executable also supports `daemon` and `stop` commands.

## Container

The multi-stage `Dockerfile` builds a small runtime image that runs as a non-root user. The `Makefile` uses Podman by default. Set `CONTAINER=docker` to use Docker.

```sh
make container-build
make container-run
```

The container publishes port `8080`. For Docker, run `make container-build CONTAINER=docker` and `make container-run CONTAINER=docker`.

Pushing a `v*` tag starts the [container image workflow](.github/workflows/container.yml). It builds the image with Podman and publishes it to `ghcr.io/<owner>/submarine-trench-war`, with the version and `latest` tags.

```sh
git tag v0.1.0
git push --tags
```

## Runtime configuration

Runtime settings are in [`config/sys.config`](config/sys.config). Set gameplay overrides there before starting the release, or set them in a running shell with `application:set_env(stw, Key, Value)`. They apply to new matches. A recompile is not needed.

| Setting | Default | Description |
| --- | --- | --- |
| `http_port` | `8080` | HTTP and WebSocket listener port. |
| `tls` | Off | Optional HTTPS and WSS listener. Configure `https_port`, `certfile`, and `keyfile`. |
| `base_hand` / `min_hand` | `9` / `5` | Hand size at full hull and minimum hand size. |
| `win_data` | `3` | Data nodes needed to win. |
| `ping_timer_ms` | `30000` | Time before unlocked registers are filled automatically. |
| `collapse_interval` | `3` | A trench section collapses every N rounds. |

### TLS

To use HTTPS and WSS, configure the `tls` setting with paths to PEM certificate and key files. You can also run HTTP behind a reverse proxy that handles TLS. The client chooses `ws://` or `wss://` based on the page's protocol.

### Health and metrics

The server provides two unauthenticated HTTP endpoints:

- `GET /health` returns `200 ok` for liveness checks.
- `GET /metrics` returns JSON with `active_games`, `players_in_rooms`, `tracked_sessions`, and `uptime_ms`.

The server logs game creation, start, and end events at the `info` level.

## Project plan

See [plan/IMPLEMENTATION-PLAN.md](plan/IMPLEMENTATION-PLAN.md) for the project plan and milestones.
