# Agent Deck v0.4.1 convergence

## Objective

Make Agent Deck safe and easy for project owners to use: remaining capacity must be unambiguous,
and evidence-review tasks must be bound to immutable, ready inputs so a green handoff cannot silently
describe a later or incomplete revision.

## Proof obligations

- [x] A task can be sealed to a clean Git revision/tree and required artifact SHA-256 digests.
- [x] Dispatch fails before claiming or starting a hand when a sealed revision or artifact has drifted.
- [x] A successful sealed run records the input/output digests and verification timestamps in an immutable receipt.
- [x] Human status output says capacity remaining, consistently with routing output.
- [x] The default/compact owner status clearly separates active, completed, and attention-needed work.
- [x] Existing unsealed task flows remain backward compatible.
- [ ] The full deterministic smoke suite passes repeatedly on macOS and in the GitHub macOS/Linux,
      Python 3.8/3.12 matrix.
- [x] An independent read-only refute finds no P0/P1 issue in the revised flow.
- [ ] A tagged release installs from its immutable URL and verifies its published checksums.

## Gate matrix

| Gate | Current state | Evidence |
|---|---|---|
| Baseline CLI behavior | PASS | Existing smoke behavior remained green in the v0.4.1 build run |
| Owner UX audit | PASS | Final independent score 96.9/100; no P0/P1/soft gaps at 80x24 and 120x36 |
| Remaining-capacity semantics | PASS | Status and route now report remaining percentage; deterministic assertion green |
| Sealed-input behavior | PASS | Final bounded refute reproduced every prior P1 closure and found no P0/P1; release-hook mutation emits STALE, never false END |
| Cross-platform CI | NOT RUN | Run after integration |
| Independent refute | PASS | Exact output rewrite, claim/release-hook race, metadata bypass, and overwrite attempts all fail closed |
| Release install/assets | NOT RUN | Run only after all prior gates pass |

## Decisions

- Keep Agent Deck file-native and zero-dependency; do not add a scheduler, database, or dashboard.
- Add one coherent trust boundary: seal, verify-before-dispatch, and receipt.
- Preserve existing task behavior for general work; owners opt into sealing for evidence-sensitive tasks.
- Report all usage windows remaining-first; raw JSON retains both `used` and `frac` for agents.

## Next step

Repeat the deterministic suite, rerun independent technical and owner-UX refutes on the hardened diff,
then run cross-platform CI. Do not publish v0.4.1 until those and immutable release-install checks are green.
