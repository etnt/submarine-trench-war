# Submarine Trench War — Implementation Plan

This plan sequences the work to build Submarine Trench War: an Erlang WebSocket
server and a single-file HTML/JavaScript canvas client. Work items are grouped
into logical phases. Each phase builds on the previous one and ends with a
playable or testable milestone so progress is always demonstrable.

## Guiding Principles

* **Server is authoritative.** All game state, rules, and randomness live on the
  Erlang server. The client only renders state and sends intents.
* **Vertical slices.** Prefer end-to-end features (server + protocol + client)
  over building one layer completely before the other.
* **Deterministic core.** The simulation engine should be a pure function of
  `(state, actions, seed)` so it can be unit-tested without networking.
* **Ship a playable loop early.** Get movement + phase resolution on screen
  before layering combat, fog of war, and objectives.

## Technology Baseline

* **Server:** Erlang/OTP. WebSocket via Cowboy. Supervision tree with a
  game-session process per match and a lobby/matchmaking process.
* **Client:** One `index.html` with inline CSS/JS. HTML canvas 2D rendering.
  Native `WebSocket` API. Optional Web Audio API for sound.
* **Protocol:** JSON messages over WebSocket (simple to debug; revisit binary
  only if needed).

---

## Phase 0 — Project Scaffolding & Tooling

Goal: a running server and a connectable client that exchange a single message.

* [ ] Initialize `rebar3` project structure (`apps/`, `rebar.config`).
* [ ] Add Cowboy dependency and a minimal HTTP listener.
* [ ] Serve the static `index.html` client from the server.
* [ ] Establish a WebSocket endpoint (`/ws`) that echoes messages.
* [ ] Client connects, sends a `ping`, renders the `pong` reply.
* [ ] Add a `Makefile` / rebar aliases for build, run, and test.
* [ ] Set up EUnit / Common Test skeleton.

**Milestone:** Open browser → client connects → round-trips a message.

---

## Phase 1 — Protocol & Session Foundations

Goal: define the message contract and player/session lifecycle.

* [ ] Define JSON message envelope (`type`, `payload`, `seq`, `timestamp`).
* [ ] Document the message catalog (client→server and server→client) in
  `plan/PROTOCOL.md`.
* [ ] Implement a lobby process: create game, join game, list players.
* [ ] Assign player IDs and session tokens; handle reconnect by token.
* [ ] Implement a game-session `gen_server` (one per match) under a supervisor.
* [ ] Handle client disconnect/reconnect without dropping the match.
* [ ] Client: lobby screen (create/join by room code, show player list).

**Milestone:** 3-4 clients join a room and see each other in a lobby.

---

## Phase 2 — Board & State Model

Goal: represent the trench map and submarine state on the server.

* [x] Define the grid/tile model (walls, open trench, depth layers).
* [x] Tile attributes: mines, thermal vents, data nodes, extraction zone.
* [x] Submarine state: position, facing, depth, hull, data collected.
* [x] Author a first static map (hand-designed narrow trench with forks).
* [x] Serialize board + submarine state to the client (full view for now).
* [x] Client: render the grid, walls, and submarines on the canvas.
* [x] Client: render submarine facing and depth (visual distinction).

**Milestone:** Server holds a board; all clients render it identically.

---

## Phase 3 — Core Movement & Phase Resolution

Goal: the programmed-movement heart of the game, without combat yet.

* [x] Implement the navigation card set (Ahead Standard/Flank, Reverse,
  Port/Starboard Bank, Dive/Surface).
* [x] Implement register programming: clients submit 5 ordered cards.
* [x] Build the deterministic resolution engine as a pure module:
  * [x] Execute all subs' current register simultaneously.
  * [x] Resolve movement conflicts (walls block, out-of-bounds).
  * [x] Apply currents (push 1-2 tiles, turbulence rotation).
* [x] Sequence all 5 registers per round on the server.
* [x] Emit a per-phase state delta / event stream to clients.
* [x] Client: card programming UI (drag/drop or click into 5 slots, lock in).
* [x] Client: animated phase replay (step through registers with movement).
* [x] Client: ghost path preview while programming.

**Milestone:** Players program 5 cards; subs move and drift each round with
animated replay. This is the first genuinely playable loop.

---

## Phase 4 — Card Drafting & The Ping Timer

Goal: card economy and the multiplayer pacing mechanic.

* [x] Deal 7-9 cards per turn; players pick 5 to program.
* [x] Enforce hand size reduction based on hull damage (min 5).
* [x] Implement the 30-second Ping Timer once the first player locks in.
* [x] Auto-fill unlocked registers with random chaotic cards on timeout.
* [x] Client: hand display, draft selection, and countdown timer UI.
* [x] Handle a player locking early / all players locked early.

**Milestone:** Full round cadence: draft → program → timer → resolve.

---

## Phase 5 — Hazards & Combat

Goal: add danger and direct player interaction.

* [x] Naval mines: trigger explosion, damage, scramble a register.
* [x] Ramming: same-tile collision damage and push-apart resolution.
* [x] Torpedoes: travel per phase on the current depth layer until blocked.
* [x] Depth charges: cross-layer weapon with 1-phase delay.
* [x] Sonar pings: straight-line beams that damage and reveal enemy cards.
* [x] Thermal vents: forced Deep → Shallow on specific phases.
* [x] Hull/damage model and submarine destruction handling.
* [x] Client: render explosions, torpedoes, sonar beams, damage feedback.

**Milestone:** Subs can damage, block, and destroy each other during resolution.

---

## Phase 6 — Fog of War & Visibility

Goal: limited vision that turns navigation into exploration.

* [x] Server-side per-player visibility computation (cone forward + radius).
* [x] Send each player only what they can see (no full-board leaks).
* [x] Active vs Passive sonar: active reveals more but broadcasts position.
* [x] Ink Cloud: block tile visibility for all players for 2 turns.
* [x] Depth affects sonar range (Deep sees less).
* [x] Client: render fog, revealed tiles, and sonar contacts.
* [x] Spectator mode: eliminated/late players get full-board view.

**Milestone:** Players see only their surroundings; information becomes a
resource.

---

## Phase 7 — Objective: The Black Box Hunt

Goal: the win condition and its endgame tension.

* [x] Hidden data nodes: reveal within sonar range; download by stopping on top.
* [x] Data collection tracking per submarine.
* [x] Moving extraction zone (naval rescue ship) with per-turn movement.
* [x] Require Shallow depth to enter the extraction zone.
* [x] Extraction announcement: reveal the leader to all for one turn.
* [x] Contested extraction resolution (first extracts, second gets a shot).
* [x] Data theft: torpedoed sub drops a recoverable data node.
* [x] Win/lose conditions and end-of-match flow.
* [x] Client: data count HUD, extraction zone marker, victory screen.

**Milestone:** A full match can be won by collecting data and extracting.

---

## Phase 8 — Tactical Cards & Depth Interactions

Goal: round out the deck and layer-based tactics.

* [x] Decoy Torpedo: false sonar signature on a target's view for one turn.
* [x] EMP Burst: disable one random register of an adjacent enemy (→ drift).
* [x] Balance tactical card frequency in the deck.
* [x] Verify all depth-layer combat interactions from the design doc.
* [x] Client: UI/feedback for tactical card effects.

**Milestone:** Full card set available and interacting correctly.

---

## Phase 9 — Dynamic Map Events

Goal: keep matches from stalling and prevent camping.

* [x] Collapse events: periodically turn a random trench section into wall.
* [x] Ensure collapses never fully trap a player or block all routes.
* [x] Additional maps and a simple map selection.
* [x] Client: animate collapses and dynamic tile changes.

**Milestone:** The board evolves over the course of a match.

---

## Phase 10 — Polish, Audio & UX

Goal: make it feel good to play.

* [ ] Sound design: sonar pings, torpedo launches, hull creaks (Web Audio).
* [ ] Improved phase-replay animation timing and easing.
* [ ] Visual theming (trench depth gradient, lighting, particle effects).
* [ ] Clear turn/phase indicators and player status panels.
* [ ] Accessibility: colorblind-safe player colors, readable HUD.
* [ ] Error/edge-case messaging (disconnects, room full, invalid moves).

**Milestone:** The game looks and sounds like a submarine trench war.

---

## Phase 11 — Hardening & Testing

Goal: confidence for real multiplayer sessions.

* [ ] Unit tests for the deterministic resolution engine (seeded scenarios).
* [ ] Property-based tests for movement/collision invariants.
* [ ] Integration tests for full round flow across multiple sessions.
* [ ] Load test with concurrent games and players.
* [ ] Reconnection and timeout robustness testing.
* [ ] Validate the server is authoritative (client cannot cheat state).

**Milestone:** Stable, tested multiplayer suitable for playtesting.

---

## Phase 12 — Deployment & Playtesting

Goal: get it in front of players and iterate.

* [ ] Package a release (`rebar3 release`) with runtime config.
* [ ] Containerize (Dockerfile) for reproducible deployment.
* [ ] Host with a public WebSocket endpoint (TLS / `wss://`).
* [ ] Basic metrics/logging (active games, players, errors).
* [ ] Run structured playtests; collect balance feedback.
* [ ] Iterate on tuning: hand sizes, timers, damage, map layouts.

**Milestone:** Publicly playable and improving from real feedback.

---

## Cross-Cutting Concerns (track throughout)

* **Protocol versioning** so client and server can evolve safely.
* **Randomness/seeding** centralized for reproducible replays and tests.
* **Configuration** (board size, timers, deck composition) as data, not code.
* **Documentation** kept current: `GAME-IDEA.md`, `PROTOCOL.md`, this plan.

## Suggested Milestone Order (Critical Path)

1. Phase 0-3 → first playable movement loop with animated replay.
2. Phase 4-5 → full round cadence with hazards and combat.
3. Phase 6-7 → fog of war and a winnable objective (feature-complete core).
4. Phase 8-12 → depth, dynamic events, polish, testing, and release.
