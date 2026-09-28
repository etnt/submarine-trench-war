---
goal: Guarantee forward and turning options in every dealt hand
version: 1.0
date_created: 2026-09-28
last_updated: 2026-09-28
owner: Submarine Trench War
status: 'Completed'
tags: [feature, gameplay, cards]
---

# Introduction

![Status: Completed](https://img.shields.io/badge/status-Completed-brightgreen)

Guarantee that every dealt hand contains at least one Ahead card and at least one Port or Starboard Bank card, without changing hand size or card IDs.

## 1. Requirements & Constraints

- **REQ-001**: Every dealt hand contains at least one card returned by `stw_engine:ahead_cards/0`.
- **REQ-002**: Every dealt hand contains at least one card returned by `stw_engine:turn_cards/0`.
- **REQ-003**: Preserve the random deal, hand size, and card IDs; replace card kinds only when a required category is absent.
- **CON-001**: Actual hand sizes are at least five cards, so both guarantees can coexist.
- **GUD-001**: Reuse the server-authoritative deal path in `src/stw_game.erl`.
- **PAT-001**: Keep hand composition checks in the existing EUnit suite and document the rule in existing gameplay documentation.

## 2. Implementation Steps

### Implementation Phase 1

- GOAL-001: Implement and document the movement-card guarantees.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-001 | Add `stw_engine:turn_cards/0`; compose `ensure_movement/1` in `src/stw_game.erl` so missing categories are inserted without overwriting the sole card satisfying the other category. | ✅ | 2026-09-28 |
| TASK-002 | Update `test/stw_game_tests.erl` and `test/stw_engine_tests.erl` to verify both categories, stable hand size and IDs, and preservation of existing Ahead or turn cards. | ✅ | 2026-09-28 |
| TASK-003 | Document the deal guarantee in `README.md`, `plan/GAME-IDEA.md`, and `plan/IMPLEMENTATION-PLAN.md`. | ✅ | 2026-09-28 |

## 3. Alternatives

- **ALT-001**: Force the same fixed movement cards into every hand. Rejected because it would make the random draw less varied than replacing only missing categories.
- **ALT-002**: Guarantee a specific turn direction. Rejected because the request allows either Port or Starboard and a random choice preserves variety.

## 4. Dependencies

- **DEP-001**: Existing `stw_engine` card-kind helpers and `stw_game` random card dealing; no new package dependencies.

## 5. Files

- **FILE-003**: `test/stw_game_tests.erl` covers hand composition invariants.
- **FILE-004**: `test/stw_engine_tests.erl` pins the turning-card category.
- **FILE-005**: `README.md`, `plan/GAME-IDEA.md`, and `plan/IMPLEMENTATION-PLAN.md` document the rule.

## 6. Testing

- **TEST-001**: Run `rebar3 eunit`; verify hand repair preserves length and IDs, and `turn_cards/0` returns the Port and Starboard Bank kinds.
- **TEST-002**: Verify hands already satisfying both categories remain unchanged and neither a sole Ahead nor sole turn card is overwritten while adding the missing category.

## 7. Risks & Assumptions

- **RISK-001**: Replacing one or two random card kinds slightly changes the drawn distribution, especially in small damaged hands; this is intentional to guarantee the requested movement options.
- **ASSUMPTION-001**: “One port/starboard card” means at least one of Port Bank or Starboard Bank, not one of each.

## 8. Related Specifications / Further Reading

- `plan/GAME-IDEA.md`, “The Movement Programming (The Nav-Computer)”
- `README.md`, “A round” and “Cards”
