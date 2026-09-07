# Agent Deck v0.4.1 convergence

## Objective

Make Agent Deck safe and easy for project owners to use: remaining capacity must be unambiguous,
and evidence-review tasks must be bound to immutable, ready inputs so a green handoff cannot silently
describe a later or incomplete revision.

## Proof obligations

- [ ] A task can be sealed to a clean Git revision/tree and required artifact SHA-256 digests.
- [ ] Dispatch fails before claiming or starting a hand when a sealed revision or artifact has drifted.
- [ ] A successful sealed run records the input-manifest digest and verification timestamps in a receipt.
- [ ] Human status output says capacity remaining, consistently with routing output.
- [ ] The default/compact owner status clearly separates active, completed, and attention-needed work.
- [ ] Existing unsealed task flows remain backward compatible.
- [ ] The full deterministic smoke suite passes repeatedly on macOS and in the GitHub macOS/Linux,
      Python 3.8/3.12 matrix.
- [ ] An independent read-only refute finds no P0/P1 issue in the revised flow.
- [ ] A tagged release installs from its immutable URL and verifies its published checksums.

## Gate matrix

| Gate | Current state | Evidence |
|---|---|---|
| Baseline CLI behavior | PASS | v0.4.0 smoke suite and clean release install |
| Owner UX audit | FAIL | 65.6/100; sealed-input readiness is a stop-ship gap |
| Remaining-capacity semantics | FAIL | `route` showed 90% remaining while `status` showed 10% under HEADROOM |
| Sealed-input behavior | NOT RUN | Build round pending |
| Cross-platform CI | NOT RUN | Run after integration |
| Independent refute | NOT RUN | Run after build gates pass |
| Release install/assets | NOT RUN | Run only after all prior gates pass |

## Decisions

- Keep Agent Deck file-native and zero-dependency; do not add a scheduler, database, or dashboard.
- Add one coherent trust boundary: seal, verify-before-dispatch, and receipt.
- Preserve existing task behavior for general work; owners opt into sealing for evidence-sensitive tasks.
- Report all usage windows remaining-first; raw JSON retains both `used` and `frac` for agents.

## Next step

Finish owner feedback synthesis, implement the bounded trust/status slice with one writer, execute the
behavioral gates, then run an independent refute before publishing v0.4.1.
