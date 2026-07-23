# Submarine Trench War

The Submarine Trench War concept fits programmed-movement mechanics perfectly.
Water physics provide a natural, thematic explanation for why a vehicle might
drift or overshoot a target, making the chaotic element of the game feel fair
and immersive. Here is a breakdown of how to design this game.

This 2D-game should be implemented as a server written in Erlang and clients
as one single HTML file containing the necessary Javascript, operating
on a HTML canvas, communicating with the server via Websockets.

## Game Parameters

* Player count: 3-4 players (2 is too deterministic, 5+ creates too much
  chaos in narrow trenches)
* Target game length: 15-20 minutes (8-12 rounds with 5 registers each)
* Spectator mode: eliminated players or late joiners see full sonar view
  of the board

## Core Gameplay Mechanics

The underwater setting transforms classic board hazards into nautical
equivalents:

* Underwater Currents: At the end of a phase, currents push submarines
  1 or 2 tiles in a specific direction. Turbulences can rotate the sub
  90 degrees.

* Sonar Pings: Submarines fire straight-line sonar beams. Getting hit
  doesn't just damage the hull; it reveals your programmed cards to the
  enemy player for the next turn (information warfare over raw damage).

* Depth Charges & Torpedoes: Torpedoes travel across the grid at the end
  of each register phase until they hit a wall, a mine, or an enemy
  submarine. Torpedoes only travel on their current depth layer — you must
  be on the same depth to hit. Depth charges are the exception: they drop
  from Shallow to Deep with a 1-phase delay, crossing layers.

* Naval Mines: Entering a mine tile triggers an explosion, dealing heavy
  damage and randomly scrambling one of your active movement registers.

* Ramming: If two subs occupy the same tile in the same phase, both take
  damage and get pushed apart. In narrow trenches, blocking becomes a
  deliberate strategy.

## Fog of War & Visibility

Submarines do not see the entire board. Limited visibility is critical for
multiplayer tension:

* Sonar Range: Each sub sees only 3-4 tiles around it (cone-shaped forward,
  small radius behind).

* Active vs Passive Sonar: Active sonar reveals more of the map but also
  broadcasts your position to all other players. Passive sonar is safe but
  limited to immediate surroundings.

* Ink Cloud: A deployable card that blocks a tile's visibility for all
  players for 2 turns, useful for covering extraction runs or escaping
  pursuit.

## The Movement Programming (The "Nav-Computer")

### Card Drafting

Each turn, players are dealt 7-9 navigation cards and must pick 5 to
program into their registers. This gives agency while preserving chaos.

Damaged systems reduce hand size: taking hull damage means fewer cards
dealt next turn (down to a minimum of 5 = no choice). This creates a
thematic death spiral — a damaged nav-computer offers fewer options.

### Navigation Cards

* Ahead Standard / Ahead Flank: Move forward 1 or 2 tiles.

* Reverse Engines: Move backward 1 tile.

* Port / Starboard Bank: Rotate 90 degrees left or right.

* Dive / Surface: Submarines can occupy two depth layers (Shallow and Deep).
  - Shallow layer allows faster movement but exposes you to surface storms
    and shallow mines.
  - Deep layer protects from surface hazards but limits sonar range and
    risks crushing damage near the trench floor.

### Tactical Cards (mixed into the deck)

* Decoy Torpedo: Creates a false sonar signature on another player's screen
  for one turn.

* EMP Burst: Disables one random register of an adjacent enemy (replaces
  that card with "drift").

* Ink Cloud: Blocks visibility on a tile for 2 turns.

## The Depth Mechanic

The two depth layers interact with combat and the objective:

* Torpedoes only hit targets on the same depth layer.
* Depth charges drop from Shallow to Deep with a 1-phase delay (the one
  weapon that crosses layers).
* Thermal vents on certain tiles push subs upward (Deep → Shallow)
  involuntarily on specific phases.
* Surfacing to extract is mandatory — you must be at Shallow depth to reach
  the extraction zone, making the endgame a vulnerable gauntlet.

## The Objective: The "Black Box" Hunt

Players navigate narrow trenches to:

* Locate Data Nodes: Submarines must stop precisely on top of hidden sonar
  nodes to download "Black Box" telemetry data. Nodes are not visible until
  within sonar range, making exploration essential.

* Extract: Once a sub collects enough data, it must race to a moving
  extraction zone (a naval rescue ship on the surface) before the other
  players destroy it.

### Extraction Tension

* Announcement: When a player has enough data to extract, all other players
  receive a sonar ping revealing that player's position for one turn.
  Everyone hunts the leader.

* Contested Zone: Two subs in the extraction zone at the same time? First to
  arrive extracts; second gets a free torpedo shot.

* Data Theft: Torpedoing a data-laden sub causes it to drop 1 data node on
  the tile, recoverable by anyone. This keeps eliminated-from-the-lead
  players engaged.

## Map Design

* Narrow Trenches: Create natural chokepoints for blocking and ambushes.

* Forking Paths: Multiple routes to data nodes prevent pure blocking
  stalemates.

* Collapse Events: Every N turns, a random trench section collapses (becomes
  impassable wall), forcing rerouting and preventing camping.

* Thermal Vents: Tiles that force depth changes on specific phases.

## Multiplayer Integration & Flow

### The Ping Timer

Once the first player locks in their 5 navigation cards, a 30-second
countdown begins for everyone else. Any player who fails to lock their cards
before the timer expires has their remaining empty slots filled with random,
chaotic cards (e.g., emergency thrusters), leading to hilarious navigation
errors.

### Phase Resolution

All 5 registers resolve sequentially. Each phase:
1. All subs execute their programmed card simultaneously.
2. Collisions and ramming resolve.
3. Torpedoes and depth charges advance.
4. Currents push subs.
5. Sonar pings fire and reveal information.
6. Mine/vent/collapse triggers resolve.

## Client UX Notes

* Phase Replay: Animate all subs moving simultaneously with collisions and
  explosions after each round resolves. This is the payoff moment.

* Ghost Path Preview: While programming cards, show a dotted line of where
  the sub would end up if no interference occurs.

* Sound Design: Sonar pings, torpedo launches, hull creaking under pressure.
  Even simple Web Audio API tones add massive atmosphere underwater.
