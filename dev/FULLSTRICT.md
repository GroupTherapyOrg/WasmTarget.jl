# FULL-STRICT (Dale: ASAP) — the campaign state

GOAL: burn the 1267 collected type-mismatches → flip _check! to throw on EVERYTHING →
extend the L-strict lock → gate.

## DONE
- The LIVE locals provider (b.locals_fn — builders read ctx.locals truth, not a
  snapshot; instr_builder.jl + _seed_builder_locals!). Smoke green. Infrastructure.

## THE MAPPED ROOT (the exemplar trace, warm-3 full-strict, f = Any[]-loop-isa-cond):
[7] local.set 72 (I32 stored)  [8] local.get 72 → tracker says AnyRef  [10] i32.eq → mismatch.
- ctx.locals is APPEND-ONLY (no retype) → 72's declared type WAS AnyRef at emission,
  yet the emitted module VALIDATES → the fragment's local indices are REMAPPED at merge
  (`get(temp_map, local_idx, local_idx)` in stackified.jl) — the tracker validates the
  PRE-map index's type while the bytes get the POST-map index. THE ROOT = index-keyed
  type lookups inside remapped fragments.
- NEXT: find where temp_map is built + applied (stackified.jl); either (a) validate
  against the POST-map type (thread the map into the provider: b.locals_fn consults
  ctx's map first), or (b) eliminate the remap (allocate finals directly). (a) is
  contained: the provider closure can capture ctx and the map — one edit in
  _seed_builder_locals! IF the map lives on ctx.
## THEN: re-harvest → burn residual classes → flip `_uf = true` in _check! (drop the
UNDERFLOW-only staging) → L-lock extension (@test_throws on a MISMATCH) → gate → PR.
