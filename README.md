# Submarine Trench War
> A real-time multiplayer submarine game of **programmed movement**

Submarine Trench War is a turn-based tactics game built around **programmed
movement**: you don't drive your submarine directly. Instead, each round you
**secretly program a sequence of navigation cards**, everyone locks in, and then
all fleets' orders execute simultaneously — subs surge forward, collide, fire
torpedoes, and drift on the currents while you watch the chaos play out. The
underwater setting makes the inevitable overshoots and misfires feel natural: you
*meant* to stop, but the current had other plans.

It runs as an **Erlang/OTP server** with an authoritative game engine, and the
client is a **single self-contained HTML file** rendering to a `<canvas>` and
talking to the server over WebSockets. No build step, no framework — open the
page and play.

---

## Quick start

**Prerequisites**

- Erlang/OTP 28+
- rebar3 3.24+

**Build, test, and run**

```sh
rebar3 compile      # build
rebar3 eunit        # run the test suite
rebar3 shell        # start the server
```

The `Makefile` wraps the same commands: `make compile`, `make test`, `make run`.

Once the server is up:

- Open **http://localhost:8080** in two or more browser tabs (or share the URL
  on your LAN).
- The static client is served at `/`; the WebSocket endpoint is `/ws`.

**Play**

1. Enter a name. One player **creates** a room (optionally picking one of the
   trench maps) and shares the room code; the others **join** with it.
2. Everyone clicks **Ready Up**. The host then clicks **Start**.
3. Program your registers each round and **Lock In** (see below).

Supports **2–4 players** (one per trench spawn corner). Your name and session
are remembered in the browser, so a refresh or dropped connection reconnects you
straight back into your match.

---

## How a round works

Each round is a plan-then-watch cycle:

1. **Draft.** You're dealt a hand of navigation and tactical cards.
2. **Program.** Place up to **5 cards** into your five registers, in order. A
   dotted **ghost path** previews where you'd end up if nobody interfered.
3. **Lock In.** When the first player locks, a **30-second Ping Timer** starts
   for everyone else. Fail to lock in time and your empty slots are filled with
   random cards — your damaged nav-computer improvising badly.
4. **Resolve.** All five registers execute one at a time. Within each register,
   every sub acts simultaneously, then collisions, weapons, currents, and
   hazards resolve.
5. **Replay.** The client animates the whole round — subs sliding, torpedoes
   streaking, explosions blooming, with sonar and impact audio — so you can see
   exactly how your plan met everyone else's.

Locking in with **no cards** is a valid pass: you hold position.

### The death spiral

Taking hull damage shrinks your hand next round (down to a minimum of 5 = no
choice at all). A wounded submarine is also a *dumber* submarine — fewer options,
more chaos. Comebacks are hard; that's the tension.

---

## Cards

### Navigation

| Card | Effect |
| --- | --- |
| **Ahead Standard** | Move forward 1 tile. |
| **Ahead Flank** | Move forward 2 tiles — fast, but hard to stop. |
| **Reverse** | Move backward 1 tile without turning. |
| **Port Bank** | Rotate 90° left. No movement. |
| **Starboard Bank** | Rotate 90° right. No movement. |
| **Dive** | Descend to the Deep layer. |
| **Surface** | Rise to the Shallow layer. |

### Tactical

| Card | Effect |
| --- | --- |
| **Torpedo** | Fire straight ahead (2 damage). Only hits enemies **at your depth**; stops at walls. |
| **Depth Charge** | Arm a charge that detonates on your tile on the *next* register (3 damage), hitting **any depth**. |
| **Sonar Ping** | Ping straight ahead (1 damage). Hits any depth **and reveals the struck enemy's programmed cards** to you. |
| **Ink Cloud** | Release ink on your tile; it blocks vision through that tile for 2 rounds. |

Tactical cards are mixed into the deck alongside navigation cards, so a good hand
is never guaranteed.

---

## Depth

Submarines occupy one of two layers, **Shallow** or **Deep**, and depth is central
to combat and stealth:

- **Torpedoes only hit targets on the same layer** — dive to dodge a torpedo lane.
- **Depth charges cross layers** (with a one-phase delay) — the answer to a diver.
- **Deep subs have shorter sonar range** — protection costs you sight.
- **Thermal vents** shove a Deep sub back up to Shallow involuntarily.

---

## Hazards & combat

- **Naval mines** — entering a mine tile triggers an explosion (heavy damage) and
  scrambles one of your later registers into a random "drift". The mine is then
  consumed.
- **Ramming** — two subs contending for the same tile both take damage and are
  pushed apart. In a narrow trench, deliberately blocking a chokepoint is a real
  strategy.
- **Underwater currents** — at the end of a register, currents drift subs a tile
  in a fixed direction, and **turbulence** rotates a sub 90°. Plan around the
  water, not just the walls.
- **Thermal vents** — force Deep → Shallow on entry.
- **Trench collapse** — every few rounds the trench caves in, turning a random
  section to solid rock (never one that would trap a submarine or block every
  route). The playable space shrinks as the match wears on, squeezing everyone
  together.

Every hit chips your hull; reach zero and your submarine becomes a drifting wreck
that still blocks the trench but takes no further orders.

---

## Fog of war & sonar

You never see the whole board. Your submarine sees only:

- a small **ring of tiles** immediately around it, plus
- a **cone** extending in the direction it faces.

**Walls block line of sight**, so you can't see around corners or through rock.
Everything outside your view is dark, and enemy submarines appear **only when they
enter your vision** — they blink in and out of contact as everyone maneuvers.

**Passive vs. Active sonar** is the core risk/reward:

- **Passive** (the default) is silent listening: short range, but nobody is told
  where you are. You stay a ghost.
- **Active** pings for a **wider ring and a longer cone** — but your position is
  **broadcast to every other player** until you go quiet again. The moment you
  ping to find the enemy, you've told the enemy exactly where you are.

Toggle it live with the **Sonar** button; the change takes effect immediately.

**Ink clouds** block vision through a tile for two rounds — cover to break contact
or hide an escape, and one of the few ways to deny an *active* pinger a sightline.

**Sonar pings** do double duty as information warfare: land one on an enemy and
their programmed cards for that round are revealed to you.

**Spectators** (destroyed players or late joiners) watch the whole board with no
fog at all.

---

## Objective

The endgame is a **Black Box hunt**: locate hidden data nodes (visible only within
sonar range), stop on them to download telemetry, then race to a moving surface
extraction zone — which you can only enter at Shallow depth, making the final run
a vulnerable gauntlet. Collecting enough data to extract announces your position
to the whole map, so everyone hunts the leader. Torpedo a data-laden rival and
they drop a node anyone can recover. Reach the patrolling extraction zone at
Shallow depth with enough data and you win the match.

---

## Architecture

The server is authoritative and the game engine is a **pure, deterministic
function** — the same programs always resolve to the same outcome, which keeps
the logic testable and the clients honest.

- **`stw_app` / `stw_sup`** — OTP application and top-level supervisor.
- **`stw_lobby`** — identity, sessions, and the room registry.
- **`stw_game_sup` / `stw_game`** — one `gen_server` per match, holding all
  authoritative match state (subs, hands, programs, sonar modes, ink, timer).
- **`stw_engine`** — the pure round resolver: takes the board, submarines, and
  everyone's programs, and returns the final state plus a phase-by-phase replay.
- **`stw_board`** — the trench map model (walls, spawns, currents, mines, vents).
- **`stw_vision`** — pure fog-of-war visibility (near ring + forward cone, depth
  penalty, Bresenham line-of-sight occlusion).
- **`stw_ws_handler`** — the Cowboy WebSocket handler that bridges clients to
  their game process.
- **`priv/index.html`** — the entire client: rendering, animation, input, and
  the WebSocket protocol.

Clients and server exchange JSON messages in a `{type, seq, ts, payload}`
envelope. Crucially, each player's `game_state` and round replay are **fogged per
player** on the server — the full board never leaves the server, so there's
nothing to peek at in the client.

### Project layout

```
src/           Erlang server modules
priv/          index.html (the whole client)
test/          EUnit test suites
config/        sys.config, vm.args
plan/          design docs — GAME-IDEA.md, IMPLEMENTATION-PLAN.md, PROTOCOL.md
rebar.config   build config
Makefile       convenience targets
```

The full wire protocol is documented in [`plan/PROTOCOL.md`](plan/PROTOCOL.md).

---

## Development

```sh
rebar3 eunit        # run all tests
```

The engine, board, vision, game server, and WebSocket handler each have their own
EUnit suite under `test/`. Because the engine and vision modules are pure, most
game logic is tested without spinning up any processes.

---

## Deployment

**Production release.** Build a self-contained release (with a bundled ERTS, so
the target host needs no Erlang install) and run it in the foreground:

```sh
make release                              # rebar3 as prod release
_build/prod/rel/stw/bin/stw foreground    # or: ... daemon / ... stop
```

**Container.** A multi-stage `Dockerfile` produces a slim, non-root runtime
image. The container targets use **Podman** by default (daemonless and
rootless); pass `CONTAINER=docker` to use Docker instead:

```sh
make container-build         # podman build -t submarine-trench-war:latest .
make container-run           # publishes 8080; open http://localhost:8080
# Docker instead of Podman:
make container-build CONTAINER=docker
```

Pushing a version tag publishes the image automatically: the
[`Build container image`](.github/workflows/container.yml) GitHub Action builds
it with Podman on every `v*` tag and pushes it to the GitHub Container Registry
at `ghcr.io/<owner>/submarine-trench-war` (tagged with the version and
`latest`).

```sh
git tag v0.1.0 && git push --tags     # triggers the build & publish
```

**Runtime configuration** lives in [`config/sys.config`](config/sys.config) and
is read from the `stw` application environment. Everything is hot-tunable for
playtesting — change a value and it applies to subsequently created games with
no recompile:

| Key | Default | Meaning |
| --- | ------- | ------- |
| `http_port` | `8080` | Plain HTTP / `ws://` listener port. |
| `tls` | *(off)* | Optional in-process HTTPS / `wss://` listener (`https_port`, `certfile`, `keyfile`). |
| `base_hand` / `min_hand` | `9` / `5` | Cards dealt at full hull, and the floor as hull degrades. |
| `win_data` | `3` | Data nodes a sub must carry to extract and win. |
| `ping_timer_ms` | `30000` | Per-round programming window before auto-lock. |
| `collapse_interval` | `3` | Every Nth round a trench section caves in. |

**TLS / `wss://`.** Either point the `tls` config at real PEM files to terminate
TLS in-process, or run plain HTTP behind a TLS-terminating reverse proxy. The
client auto-selects `ws://` vs `wss://` from the page's protocol, so no client
change is needed.

**Observability.** Two unauthenticated HTTP endpoints support health checks and
monitoring:

- `GET /health` → `200 ok` (liveness probe).
- `GET /metrics` → JSON snapshot of `active_games`, `players_in_rooms`,
  `tracked_sessions`, and `uptime_ms`.

Key lifecycle events (game created/started/over) are logged via `logger` at
`info` level.

---

## Status

The game is built in incremental vertical slices (tracked in
[`plan/IMPLEMENTATION-PLAN.md`](plan/IMPLEMENTATION-PLAN.md)). Currently
implemented and playable end-to-end:

- ✅ Lobby, rooms, reconnect, and session persistence
- ✅ The 20×12 trench board with currents, mines, and vents
- ✅ Programmed movement, register resolution, and animated replay
- ✅ Card drafting, the 30-second Ping Timer, and auto-fill
- ✅ Hazards & combat (torpedoes, depth charges, sonar pings, mines, ramming)
- ✅ Fog of war, active/passive sonar, ink clouds, and spectator mode
- ✅ The Black Box objective: hidden data nodes, data theft, the moving
  extraction zone, extraction announcements, and win/lose end-of-match flow
- ✅ Dynamic maps: trench-collapse events, multiple trench layouts, and host
  map selection
- ✅ Audio (Web Audio sonar, torpedo, and impact cues) and UX polish
- ✅ Production release, Docker image, optional in-process TLS, `/health` and
  `/metrics` endpoints, and hot-tunable gameplay config

On the roadmap:

- ⏳ Additional tactical cards (Decoy, EMP)
- ⏳ Scoring refinements

---

## License

See [`LICENSE`](LICENSE).

