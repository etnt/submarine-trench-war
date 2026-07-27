# Submarine Trench War — WebSocket Protocol

This document defines the message contract between the HTML/JavaScript client
and the Erlang server. The server is authoritative: clients send **intents**,
the server validates them and broadcasts **authoritative state and events**.

## Transport

* WebSocket at `/ws` (use `wss://` in production).
* Payload format: UTF-8 JSON, one JSON object per WebSocket frame.
* The server never trusts client-supplied game state — only intents.

## Message Envelope

Every message (both directions) shares a common envelope:

```json
{
  "type": "string",
  "seq": 42,
  "ts": 1753248000000,
  "payload": { }
}
```

| Field     | Type    | Direction | Description                                           |
| --------- | ------- | --------- | ----------------------------------------------------- |
| `type`    | string  | both      | Message type identifier (see catalog below).          |
| `seq`     | integer | both      | Monotonic per-connection sequence number.             |
| `ts`      | integer | both      | Unix epoch milliseconds when the message was created. |
| `payload` | object  | both      | Type-specific body. May be `{}` for empty payloads.   |

### Conventions

* **Naming:** `type` values are `lower_snake_case`. Client→server types read as
  commands/intents (`join_game`, `lock_registers`). Server→client types read as
  facts/events (`game_state`, `phase_event`).
* **IDs:** All IDs are strings. `player_id` is server-assigned; `room_code` is a
  short human-shareable string.
* **Coordinates:** Tiles use `{ "x": <col>, "y": <row> }`, origin top-left.
* **Facing:** One of `"N"`, `"E"`, `"S"`, `"W"`.
* **Depth:** One of `"shallow"`, `"deep"`.
* **Errors:** Any request may be answered with an `error` message referencing
  the offending `seq`.

### Protocol Versioning

The first client→server message must be `hello` with a `protocol_version`. The
server replies with `welcome` (accepting) or `error` (incompatible). Bump the
version on any breaking change to this catalog.

---

## Connection & Lobby Lifecycle

```
client            server
  | -- hello ------->|
  | <-- welcome -----|
  | -- create_game ->|            (or join_game)
  | <-- game_joined -|
  | <-- lobby_state -|   (broadcast on any lobby change)
  | -- set_ready --->|
  | <-- lobby_state -|
  | <-- game_started |   (when all ready / host starts)
```

---

## Round Lifecycle

```
server -> clients : round_started        (deal hands)
server -> clients : deal_hand            (per-player, private)
client -> server  : program_registers    (working selection, optional)
client -> server  : lock_registers       (final 5 cards)
server -> clients : timer_started         (30s Ping Timer begins)
server -> clients : player_locked         (who has locked)
server -> clients : registers_resolving   (all locked / timer expired)
server -> clients : phase_event (xN)      (one per register, animated)
server -> clients : round_result          (end-of-round summary)
```

---

## Client → Server Messages

### `hello`
Initiates the connection and negotiates protocol version. Also used to resume a
session via a previously issued `session_token`.

```json
{
  "type": "hello",
  "payload": {
    "protocol_version": 1,
    "display_name": "Nautilus",
    "session_token": "optional-existing-token"
  }
}
```

### `create_game`
Create a new room and become its host.

```json
{
  "type": "create_game",
  "payload": {
    "max_players": 4,
    "map_id": "trench_alpha"
  }
}
```

### `join_game`
Join an existing room by code.

```json
{
  "type": "join_game",
  "payload": { "room_code": "REEF12" }
}
```

### `leave_game`
Leave the current room. Empty payload.

### `set_ready`
Toggle ready state in the lobby.

```json
{
  "type": "set_ready",
  "payload": { "ready": true }
}
```

### `start_game`
Host-only request to start the match early.

### `program_registers`
Working selection of 5 ordered cards for the round, given as **card IDs**
drawn from this round's dealt hand (see `deal_hand`). May be sent multiple
times before locking (the server keeps the latest). The 5 IDs must be distinct
and all present in the current hand.

```json
{
  "type": "program_registers",
  "payload": {
    "registers": ["r3c7", "r3c2", "r3c9", "r3c1", "r3c4"]
  }
}
```

Errors: `invalid_register` if the list is not exactly 5 distinct IDs, or any ID
is not in the player's hand; `not_in_game` if the sender has no submarine.

### `lock_registers`
Binding lock of the most recently programmed registers. Takes no payload — the
program submitted via `program_registers` is what gets locked. Once every
seated player has locked, the round resolves.

```json
{
  "type": "lock_registers",
  "payload": {}
}
```

Errors: `invalid_register` if no program has been submitted yet.

### `set_sonar_mode`
Choose active or passive sonar. Takes effect immediately: the server stores
the mode and re-broadcasts a fresh `game_state` to every player (active sonar
widens the caller's view but reveals their position to everyone via each
view's `broadcasts` list). The mode persists across rounds until changed.

```json
{
  "type": "set_sonar_mode",
  "payload": { "mode": "passive" }
}
```

`mode` is `passive` (short range, silent — the default) or `active` (longer
range and a wider near radius, but broadcast to all players).

### `ping`
Latency/keepalive probe. Server replies with `pong` echoing `seq`.

---

## Server → Client Messages

### `welcome`
Accepts the connection and assigns identity.

```json
{
  "type": "welcome",
  "payload": {
    "protocol_version": 1,
    "player_id": "p_ab12",
    "session_token": "tok_9f3c...",
    "server_time": 1753248000000
  }
}
```

### `game_joined`
Confirms room membership after `create_game` / `join_game`.

```json
{
  "type": "game_joined",
  "payload": {
    "room_code": "REEF12",
    "player_id": "p_ab12",
    "is_host": true
  }
}
```

### `lobby_state`
Broadcast whenever lobby membership or readiness changes.

```json
{
  "type": "lobby_state",
  "payload": {
    "room_code": "REEF12",
    "map_id": "trench_alpha",
    "host_id": "p_ab12",
    "players": [
      { "player_id": "p_ab12", "display_name": "Nautilus", "ready": true },
      { "player_id": "p_cd34", "display_name": "Kraken", "ready": false }
    ]
  }
}
```

### `game_started`
Signals transition from lobby to match. Carries the static board and the
initial submarine placements. Also re-sent to a player who reconnects while a
match is in progress (followed by `lobby_state`).

The board is sent as rows of single-character tiles plus a `legend` mapping
each character to a `kind`. Rows are top-to-bottom (`y = 0` first); each row is
`width` characters, left-to-right (`x = 0` first).

```json
{
  "type": "game_started",
  "payload": {
    "map_id": "trench_alpha",
    "room_code": "J645EP",
    "board": {
      "width": 20,
      "height": 12,
      "grid": [
        "####################",
        "#S......#..X..#....S#"
      ],
      "legend": {
        "#": "wall",
        ".": "trench",
        "S": "spawn",
        "D": "data_node",
        "X": "extraction",
        "M": "mine",
        "V": "vent"
      }
    },
    "submarines": [
      {
        "player_id": "p_ab12",
        "display_name": "Nautilus",
        "color": "#3cf",
        "x": 2,
        "y": 2,
        "facing": "S",
        "depth": "shallow",
        "hull": 10,
        "data_collected": 0
      }
    ]
  }
}
```

The `grid` snippet above is illustrative (rows abbreviated). Tile `kind`
values: `wall`, `trench`, `spawn`, `mine`, `vent`, `data_node`, `extraction`.
The current phase sends the full board to every player; fog of war (Phase 6)
will trim it to visible tiles via `game_state`.

### `round_started`
Begins a new round; announces the round number and the number of registers.
Each player's dealt hand arrives separately via the private `deal_hand`
message (hand size varies per player with hull damage).

```json
{
  "type": "round_started",
  "payload": { "round": 3, "registers": 5 }
}
```

### `deal_hand`
Private per-player message delivering the round's cards. The number of cards
is the player's hand size: full hull deals 9, and each point of hull damage
removes one card down to a minimum of 5 (never fewer than the register count).
Players pick 5 of these IDs to `program_registers`.

```json
{
  "type": "deal_hand",
  "payload": {
    "round": 3,
    "player_id": "p_ab12",
    "cards": [
      { "id": "r3c1", "kind": "ahead_flank" },
      { "id": "r3c2", "kind": "port_bank" },
      { "id": "r3c3", "kind": "dive" },
      { "id": "r3c4", "kind": "ahead_standard" },
      { "id": "r3c5", "kind": "reverse" },
      { "id": "r3c6", "kind": "starboard_bank" },
      { "id": "r3c7", "kind": "surface" },
      { "id": "r3c8", "kind": "ahead_standard" },
      { "id": "r3c9", "kind": "port_bank" }
    ]
  }
}
```

> **Phase 4 note:** the deck is navigation cards only for now. Tactical card
> kinds (`torpedo`, `sonar_ping`, `ink_cloud`, …) enter the deck with the
> combat phases.
>
> **Phase 6 note:** `ink_cloud` is now a live tactical card. Playing it
> deploys an ink cloud on the sub's current tile: a `round_result` phase emits
> an `ink_cloud` event (`{ "type": "ink_cloud", "player_id": ..., "x", "y" }`)
> and the tile blocks vision through it for the next two rounds. Active clouds
> are reported to clients in every `game_state` via `ink_clouds`.
>
> **Phase 8 note:** two more tactical cards round out the deck:
>
> * `decoy_torpedo` — projects a false sonar signature on the open tile a few
>   squares straight ahead of the sub. A `round_result` phase emits a `decoy`
>   event (`{ "type": "decoy", "player_id": ..., "x", "y" }`) that is **only**
>   sent to the decoy's owner (and spectators); the resulting phantom contact
>   is shown to every *other* player via `game_state.decoys` for one round.
> * `emp_burst` — scrambles one upcoming register of an orthogonally adjacent
>   enemy (lowest-id if several) into an inert `drift`. A phase emits an
>   `emp_burst` event on the source (`x`, `y`, `target`) and a `disabled`
>   event on the victim (`by`, `register`). Deterministic: the disabled
>   register is the one immediately after the burst.

Navigation card `kind` values:
`ahead_standard`, `ahead_flank`, `reverse`, `port_bank`, `starboard_bank`,
`dive`, `surface`.

### `timer_started`
The 30-second Ping Timer has begun (first player locked in). `ends_at` is a
UNIX epoch timestamp in milliseconds; the client counts down to it.

```json
{
  "type": "timer_started",
  "payload": { "duration_ms": 30000, "ends_at": 1753248030000 }
}
```

### `player_locked`
Broadcast when a player locks their registers (no card contents revealed).

```json
{
  "type": "player_locked",
  "payload": { "player_id": "p_cd34", "locked": 2, "total": 4 }
}
```

### `registers_resolving`
All players are locked (or the timer expired) and resolution is about to run.
`auto_filled` lists players whose registers were filled with random cards
because they had not programmed when the timer expired.

```json
{
  "type": "registers_resolving",
  "payload": {
    "round": 3,
    "auto_filled": ["p_ef56"]
  }
}
```

### `phase_event`
Emitted once per register (5 per round), describing everything that happened in
that phase so the client can animate a faithful replay. `events` is an ordered
list applied in sequence.

> **Phase 3 note:** rather than streaming five separate `phase_event`
> messages, the current server delivers all five phases in one `round_result`
> (see its `phases` array below). Each phase carries a full submarine snapshot
> plus an `events` list (`move` is inferred from the snapshot; explicit events
> so far are `rotate`, `dive`, `surface`, `blocked`, `drift`, `turbulence`).
> The richer per-event schema below is the target once combat lands.
>
> **Phase 5 note (combat):** the engine now emits combat events too. Every
> event is `{ "type": <string>, "player_id": <id>, ... }`. The additional
> types and their extra fields are:
>
> | type | player_id | extra fields |
> |------|-----------|--------------|
> | `torpedo` | shooter | `x`, `y`, `depth`, `path: [{x,y}]`, `hit: <id>\|null` |
> | `sonar_ping` | shooter | `x`, `y`, `depth`, `path: [{x,y}]`, `hit: <id>\|null` |
> | `depth_charge_armed` | owner | `x`, `y` |
> | `explosion` | owner | `x`, `y` (depth charge detonating, 1-phase delay) |
> | `hit` | victim | `by: <id>`, `weapon`, `damage` |
> | `mine` | victim | `x`, `y`, `scrambled: <register>\|null` |
> | `vent` | sub | (forced Deep → Shallow) |
> | `ram` | sub | (same-tile collision damage) |
> | `destroyed` | sub | (hull reached 0; becomes a wreck) |
> | `ink_cloud` | sub | `x`, `y` (deploys vision-blocking ink for 2 rounds) |
> | `decoy` | owner | `x`, `y` (phantom contact; owner-only in the replay) |
> | `emp_burst` | source | `x`, `y`, `target: <id>` |
> | `disabled` | victim | `by: <id>`, `register` (register scrambled to drift) |
>
> Each phase snapshot entry now also carries `hull` and `alive`. Depth charges
> armed on the final register detonate at round end and their events are folded
> into the last phase.

```json
{
  "type": "phase_event",
  "payload": {
    "round": 3,
    "register": 2,
    "events": [
      { "kind": "move", "player_id": "p_ab12",
        "from": { "x": 4, "y": 6 }, "to": { "x": 4, "y": 5 }, "facing": "N" },
      { "kind": "rotate", "player_id": "p_cd34", "facing": "E" },
      { "kind": "current_push", "player_id": "p_ab12",
        "to": { "x": 5, "y": 5 } },
      { "kind": "torpedo", "path": [ { "x": 4, "y": 5 }, { "x": 4, "y": 4 } ],
        "depth": "shallow", "hit": "p_ef56" },
      { "kind": "sonar_ping", "source": "p_cd34",
        "path": [ { "x": 6, "y": 6 }, { "x": 6, "y": 5 } ],
        "revealed_player": "p_ab12" },
      { "kind": "mine", "player_id": "p_ef56", "at": { "x": 4, "y": 4 },
        "scrambled_register": 4 },
      { "kind": "damage", "player_id": "p_ef56", "amount": 2, "hull": 6 },
      { "kind": "destroyed", "player_id": "p_ef56" }
    ]
  }
}
```

`event.kind` values: `move`, `rotate`, `depth_change`, `current_push`,
`ram`, `torpedo`, `depth_charge`, `sonar_ping`, `mine`, `vent`, `ink_cloud`,
`decoy`, `emp`, `damage`, `destroyed`, `data_download`, `data_dropped`,
`collapse`, `extraction`.

### `game_state`
Authoritative per-player view snapshot. Sent after resolution, when a player
toggles sonar, and on reconnect. Only includes what the receiving player can
currently see (fog of war).

> **Phase 6 note:** fog of war is now implemented. The server computes a
> personalized snapshot per player. The implemented shape is:
>
> ```json
> {
>   "type": "game_state",
>   "payload": {
>     "round": 3,
>     "sonar_mode": "passive",
>     "spectator": false,
>     "you": { ...full sub_json for the receiver... },
>     "submarines": [ ...sub_json for each visible submarine (incl. self)... ],
>     "visible_tiles": [ { "x": 5, "y": 5 }, { "x": 5, "y": 4 } ],
>     "ink_clouds": [ { "x": 8, "y": 4 } ],
>     "broadcasts": [ "p_cd34" ]
>   }
> }
> ```
>
> * `sonar_mode` — the receiver's current mode (`passive` | `active`).
> * `spectator` — `true` for eliminated or unseated viewers; they get the
>   **full** board (`you` is `null`, `submarines` lists everyone, and
>   `visible_tiles` is empty because nothing is fogged).
> * `submarines` — own sub plus every enemy currently detected. A sub is
>   detected if it is within the viewer's vision (near radius + forward cone,
>   blocked by walls and by ink) **or** is actively pinging.
> * `visible_tiles` — the tiles the viewer can see this round; the client
>   shades everything else. Empty for spectators (no fog).
> * `ink_clouds` — tiles currently covered by an ink cloud (blocks vision for
>   two rounds).
> * `broadcasts` — ids of other players who are on active sonar (their
>   position is revealed to everyone).
>
> **Phase 7 note:** `game_state` now also carries the objective layer:
>
> ```json
> {
>   "round": 3,
>   "sonar_mode": "passive",
>   "spectator": false,
>   "you": { ...sub_json, includes "data_collected": 2 ... },
>   "submarines": [ ... ],
>   "visible_tiles": [ ... ],
>   "ink_clouds": [ ... ],
>   "broadcasts": [ "p_cd34" ],
>   "data_nodes": [ { "x": 3, "y": 5 } ],
>   "extraction": { "x": 10, "y": 1 },
>   "win_data": 3
> }
> ```
>
> * `data_nodes` — data nodes the viewer can currently see (within sonar
>   range and not hidden by ink). Hidden data nodes are **not** baked into the
>   `game_started` board grid; they are revealed only here. Spectators see all
>   remaining nodes.
> * `extraction` — the patrolling extraction zone's current tile. It moves one
>   step along a top-row patrol each round and is visible to everyone.
> * `win_data` — data nodes a submarine must carry to be able to extract.
> * `broadcasts` — also includes any extraction-ready leader that was revealed
>   to all for one turn (see `extraction_announced`).
>
> **Phase 8 note:** `game_state` also carries `decoys` — a list of
> `{ "x", "y" }` false contacts planted by *other* players' decoy torpedoes,
> shown on the receiver's scope for one round. A player never sees their own
> decoy. Spectators see every decoy.

```json
{
  "type": "game_state",
  "payload": {
    "round": 3,
    "you": {
      "player_id": "p_ab12",
      "position": { "x": 5, "y": 5 },
      "facing": "N",
      "depth": "shallow",
      "hull": 8,
      "data_collected": 2
    },
    "visible_tiles": [
      { "x": 5, "y": 5, "kind": "trench" },
      { "x": 5, "y": 4, "kind": "data_node", "downloaded": false }
    ],
    "contacts": [
      { "player_id": "p_cd34", "position": { "x": 6, "y": 5 },
        "depth": "shallow" }
    ],
    "extraction_zone": { "x": 10, "y": 1 }
  }
}
```

`contacts` lists only enemy submarines currently detected (via visibility or
active sonar). Undetected enemies are omitted entirely.

### `revealed_cards`
Private message when an enemy's programmed cards are revealed to you (e.g., you
hit them with a sonar ping).

```json
{
  "type": "revealed_cards",
  "payload": {
    "player_id": "p_cd34",
    "round": 3,
    "registers": ["ahead_flank", "port_bank", "torpedo", "dive", "reverse"]
  }
}
```

### `round_result`
End-of-round summary after all 5 phases resolve.

> **Phase 3 note:** the current server sends the resolved animation stream
> here as a `phases` array (one entry per register, in order) plus the final
> authoritative `submarines`. As of Phase 5 each phase snapshot includes
> `hull`/`alive`, phases may carry combat `events`, and a top-level
> `mines_cleared` array lists mine tiles consumed this round (so clients can
> remove those markers). The `standings` summary below is the target for
> later phases once hull/data matter.
>
> **Phase 6 note:** `round_result` is now fogged **per player**. Each phase's
> `submarines` snapshot is trimmed to the subs that viewer could see at that
> moment (own sub always shown; active pingers always shown; others only when
> within sonar range and not hidden by ink), while combat `events` are left
> intact so weapon FX still play. The top-level `submarines` is the viewer's
> own fogged end-of-round view. Enemies therefore appear and disappear across
> phases as they move in and out of sonar. Spectators receive the full,
> unfogged `phases` and `submarines`.

```json
{
  "type": "round_result",
  "payload": {
    "round": 3,
    "phases": [
      {
        "register": 0,
        "submarines": [
          { "player_id": "p_ab12", "x": 3, "y": 2,
            "facing": "E", "depth": "shallow", "hull": 10, "alive": true }
        ],
        "events": [
          { "type": "torpedo", "player_id": "p_ab12", "x": 3, "y": 2,
            "depth": "shallow", "path": [ { "x": 4, "y": 2 } ],
            "hit": "p_cd34" },
          { "type": "hit", "player_id": "p_cd34", "by": "p_ab12",
            "weapon": "torpedo", "damage": 2 }
        ]
      }
    ],
    "mines_cleared": [ { "x": 6, "y": 3 } ],
    "submarines": [
      { "player_id": "p_ab12", "display_name": "Nautilus", "color": "#3cf",
        "x": 5, "y": 2, "facing": "E", "depth": "shallow",
        "hull": 10, "alive": true, "data_collected": 0 }
    ]
  }
}
```

The target end-of-round summary (later phases):

```json
{
  "type": "round_result",
  "payload": {
    "round": 3,
    "standings": [
      { "player_id": "p_ab12", "hull": 8, "data_collected": 2,
        "alive": true },
      { "player_id": "p_ef56", "hull": 0, "data_collected": 0,
        "alive": false }
    ]
  }
}
```

### `extraction_announced`
Broadcast when a submarine has collected enough data to extract; its position
is revealed to all players for one turn.

> **Phase 7 note:** implemented. The payload carries the leader's id, current
> data count, and position. The leader is also force-visible in the next
> `game_state` (listed in `broadcasts`).

```json
{
  "type": "extraction_announced",
  "payload": {
    "player_id": "p_ab12",
    "data_collected": 3,
    "x": 5,
    "y": 5
  }
}
```

### `game_over`
The match has ended. The server also sends a final, fully revealed
`game_state` so every player sees the finish.

> **Phase 7 note:** implemented shape below. `winner`/`runner_up` may be
> `null` (e.g. mutual destruction). `standings` lists every submarine in join
> order with its color, data, hull, and alive flag.

```json
{
  "type": "game_over",
  "payload": {
    "winner": "p_ab12",
    "reason": "extracted",
    "runner_up": "p_cd34",
    "standings": [
      { "player_id": "p_ab12", "display_name": "Nautilus", "color": "#3cf",
        "data_collected": 3, "hull": 8, "alive": true },
      { "player_id": "p_cd34", "display_name": "Seawolf", "color": "#f83",
        "data_collected": 1, "hull": 0, "alive": false }
    ]
  }
}
```

`reason` values: `extracted` (a laden sub reached the zone at shallow depth),
`survivor` (last submarine running), `draw` (no survivors). Contested
extraction is resolved by most data (join order breaks ties); the loser is
reported as `runner_up`.

### `pong`
Reply to `ping`, echoing the original `seq` in `payload.reply_to`.

```json
{
  "type": "pong",
  "payload": { "reply_to": 42, "server_time": 1753248000000 }
}
```

### `error`
Reports a rejected request or protocol violation.

```json
{
  "type": "error",
  "payload": {
    "reply_to": 17,
    "code": "invalid_register",
    "message": "Card 'card_9' is not in your current hand."
  }
}
```

Error `code` values: `protocol_version_unsupported`, `room_not_found`,
`room_full`, `not_host`, `not_in_game`, `no_identity`, `unknown_type`,
`invalid_register`, `already_locked`, `not_your_turn_phase`, `rate_limited`,
`internal_error`, `bad_json`, `missing_type`.

---

## Reconnection

1. Client reconnects and sends `hello` with its stored `session_token`.
2. Server validates the token and rebinds the connection to the existing player.
3. Server replies with `welcome`, then the current `lobby_state` or a full
   `game_state` (plus `game_started` board if mid-match).
4. If the token is unknown/expired, the server returns `error` with
   `not_in_game` and the client returns to the lobby.

## Rate Limiting & Validation

* The server validates every intent against current game phase and player state.
* Out-of-phase intents (e.g., `lock_registers` outside programming) return
  `error` with `not_your_turn_phase`.
* Excessive message rates return `rate_limited`; clients should back off.

## Open Questions

* Binary framing (e.g., compact board deltas) if JSON proves too heavy — defer
  until load testing indicates a need.
* Whether `program_registers` previews should be throttled server-side or
  computed purely client-side for ghost-path preview.
* Spectator-specific message set (full-board `game_state` variant) — to be
  detailed alongside Phase 6.
