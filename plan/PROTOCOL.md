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
Non-binding working selection (used to drive ghost-path preview and to persist
in-progress choices). May be sent multiple times before locking.

```json
{
  "type": "program_registers",
  "payload": {
    "registers": ["card_7", "card_2", "card_9", "card_1", "card_4"]
  }
}
```

### `lock_registers`
Final, binding submission of 5 ordered cards for the round. Card IDs must be
from the player's currently dealt hand.

```json
{
  "type": "lock_registers",
  "payload": {
    "registers": ["card_7", "card_2", "card_9", "card_1", "card_4"]
  }
}
```

### `set_sonar_mode`
Choose active or passive sonar for the upcoming resolution.

```json
{
  "type": "set_sonar_mode",
  "payload": { "mode": "passive" }
}
```

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
Signals transition from lobby to match. Includes the static board.

```json
{
  "type": "game_started",
  "payload": {
    "map_id": "trench_alpha",
    "board": {
      "width": 20,
      "height": 12,
      "tiles": [
        { "x": 0, "y": 0, "kind": "wall" },
        { "x": 1, "y": 0, "kind": "trench" }
      ]
    },
    "players": [
      { "player_id": "p_ab12", "color": "#3cf" }
    ]
  }
}
```

Tile `kind` values: `wall`, `trench`, `mine`, `vent`, `data_node`,
`extraction`. Hidden attributes (mines, data nodes) are omitted from a player's
view until revealed — see `game_state`.

### `round_started`
Begins a new round; announces round number and hand size.

```json
{
  "type": "round_started",
  "payload": { "round": 3, "hand_size": 8 }
}
```

### `deal_hand`
Private per-player message delivering the round's cards.

```json
{
  "type": "deal_hand",
  "payload": {
    "round": 3,
    "cards": [
      { "id": "card_7", "kind": "ahead_flank" },
      { "id": "card_2", "kind": "port_bank" },
      { "id": "card_9", "kind": "torpedo" },
      { "id": "card_1", "kind": "dive" },
      { "id": "card_4", "kind": "ahead_standard" },
      { "id": "card_5", "kind": "ink_cloud" }
    ]
  }
}
```

Card `kind` values:
`ahead_standard`, `ahead_flank`, `reverse`, `port_bank`, `starboard_bank`,
`dive`, `surface`, `torpedo`, `depth_charge`, `sonar_ping`, `decoy_torpedo`,
`emp_burst`, `ink_cloud`, `drift` (chaotic auto-fill).

### `timer_started`
The 30-second Ping Timer has begun (first player locked in).

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
  "payload": { "player_id": "p_cd34", "locked_count": 2, "total": 4 }
}
```

### `registers_resolving`
All players are locked (or the timer expired). Auto-filled players are flagged.

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
Authoritative per-player view snapshot. Sent after resolution and on reconnect.
Only includes what the receiving player can currently see (fog of war).

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
Broadcast when a player has enough data to extract; reveals their position to
all for one turn.

```json
{
  "type": "extraction_announced",
  "payload": {
    "player_id": "p_ab12",
    "position": { "x": 5, "y": 5 }
  }
}
```

### `game_over`
The match has ended.

```json
{
  "type": "game_over",
  "payload": {
    "winner_id": "p_ab12",
    "reason": "extracted",
    "final_standings": [
      { "player_id": "p_ab12", "data_collected": 3, "extracted": true },
      { "player_id": "p_cd34", "data_collected": 1, "extracted": false }
    ]
  }
}
```

`reason` values: `extracted`, `last_sub_standing`, `round_limit`, `aborted`.

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
