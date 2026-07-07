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

## THE SHARPENED BAR (Dale, 2026-07-07): VALID-BY-CONSTRUCTION IN FULL
"NEVER ever need wasm-tools ever again." The full scope — NO rug-sweeping:
1. NO collect-mode anywhere; NO opt-outs. The flow builder's opt-out DIES: the
   temp_map threading + exact fragment contracts make whole-body tracking complete.
2. The tracker models the ENTIRE wasm validation surface:
   - value stack + types + control frames + br target arities (have)
   - locals: LIVE provider + POST-REMAP truth (in flight)
   - globals: const-expr validity at add_global_ref! (init bytes type-checked)
   - type section: subtype-ordering + field-prefix validity at add_type!
   - elem/data segments, exports, start-fn signature — at their add_*! chokepoints
3. Every mismatch = a modeling debt to FIX. The harvest must hit ZERO with everything
   throwing, no exclusions.
4. TRANSITION: wasm-tools stays in CI as the DISAGREEMENT ALARM (builder-pass +
   wasm-tools-fail = P0 builder bug) until proven, then optional. The L-lock family
   asserts: default strict, throws on mismatch AND underflow AND frame errors,
   zero opt-out count.

## CONVERGENCE LEDGER (2026-07-07)
1267 → 689 (struct_get/set derive) → 556 (array/global derive) → 210 (_ctx_builder:
the universal provider, 180 creations swept) → 26 mismatches + ~48 flow-opt-out
underflows. THE CURES THAT WORKED: derive-the-truth at builder chokepoints (the module
outranks callers); the live locals provider; entry-narrowing at _sub_builder (helpers
declare widths, erased seeds funnel at entry).
THE LAST FIELD: (a) ~26 mismatches — the getfield-tuple arm's frame-result direction
(hom tuple: expected AnyRef found …) + I32-vs-CR flow pairs; (b) the FLOW OPT-OUT's
underflows (~48, all ⟨GotoIfNot cond⟩ — the whole-body tracking completion: the cond
value crossing label boundaries in the tracker's view; complete the inter-block
contracts, then strict=false DIES). Then: _uf=true in main, the L-lock extension
(mismatch @test_throws + opt-out-count=0), ladder, gate, PR.
