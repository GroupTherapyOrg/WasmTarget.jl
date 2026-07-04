# March 4 — compile_statement inversion plan (the last deep piece)

State when written: R2=13 (10 real), branch `wt-parity-march4` @ 207f43b, all four
god-fn junctions dissolved (compile_call!/compile_invoke!/compile_new!/compile_foreigncall!
ARE the implementations; bytes shells remain). Full phase gate running.

## Remaining R2 sites (all die with this plan)

| site | what |
|---|---|
| statements.jl:159 | THE front seam — dissolves when compile_statement! is the impl |
| statements.jl:~1555 | the interior accumulator's ONE exit (`emit_raw!(b, bytes)`) |
| stackified.jl:105 | THE flow front — dissolves when generate_stackified_flow inverts |
| stackified.jl:658 | compile_statement declared-push inside compile_phi_value |
| stackified.jl:1119 | the drop-sniff statement splice (kills via real heights) |
| values.jl:693 | condition front — compile_condition_to_i32 inversion |
| values.jl:864 | `_narrow!` declared contract — _narrow_generic_local! inversion |
| flow.jl:15 | generate_try_catch product — its ~8 sub-generators return builders |
| generate.jl:1187 | branch-split front — same |
| compile.jl:3504 | compile_statement product (MVP self-test path) |

## The compile_statement conversion (statements.jl ~605-1555)

1. **Dispatcher → fragment**: `stmt_bytes = compile_call(stmt, idx, ctx)` etc. become
   `_sf = InstrBuilder(seeded); compile_call!(_sf, stmt, idx, ctx)`. The `:boundscheck/
   :the_exception` arms emit into `_sf` directly (they already build local builders).
2. **The tail's ~90 byte-scans → tracked/ir tests** (the store/drop/safety apparatus):
   - `stmt_bytes[1] == 0x20` pure-local.get + LEB walk → `length(_sf.instrs)==1 &&
     _sf.instrs[1] isa InstrIR.LocalGet` (+ `.idx` field for the source local)
   - const first-byte scans → `top(_sf) ∈ {I32,I64,F32,F64}` + `InstrIR.I32Const` kinds
   - `_last_instr_start` LEB backscans (struct_get/array_get/call tails) →
     `_sf.instrs[end] isa InstrIR.StructGet / ArrayGet / Call` (+ their typed fields)
   - `resize!(stmt_bytes, si-1)` trailing-local.get strip → `pop!(_sf.instrs)` + validator
     pop (or better: decide BEFORE emitting — check the IR shape first)
   - the multi-value all-local-gets walk → `length(_sf.v.stack) >= 2` (audit-proven)
   - has_gc_prefix scans → `any(i -> i isa InstrIR.StructNew || …, _sf.instrs)` or the
     tracked top being a ref
   - store/drop: `statement_produces_wasm_value` stays (IR-level query); "already
     dropped" → `_sf.instrs[end] isa InstrIR.Drop`
3. **Exit**: `append_builder!(b, _sf)` + the store/drop ops emitted on b; then
   compile_statement! (b-first) becomes the implementation; the bytes shell delegates;
   the front seam at 159 dissolves (plain delegation, no emit_raw).
4. **stackified.jl:1119 + 658, compile.jl:3504**: call the visitor directly once
   compile_statement! exists (658's declared push becomes the tracked transfer).
5. **Gate cadence**: smoke + shards 0/3/6/7 per slice; full gate at the end.

## Then (order)
- compile_condition_to_i32 inversion (values 693) — a small dispatcher, same recipe.
- generate_try_catch family → builder-returning (flow 15, generate 1187, stackified 105):
  each sub-generator (`generate_try_catch_stackified`, `generate_branch_split_try`,
  `generate_nested_try_catch_2`, `generate_catch_try_chain(+_merge)`,
  `generate_catch_arm_split/skip_merge`, `generate_sequential_try_catch`) already builds
  ONE `bb` and returns builder_code — mechanical `_b` inversions.
- `_narrow_generic_local!` inversion (values 864).
- L13 lock: R2 == 0. R3 (134) → floor (it is dart's getStaticType per the M2
  reclassification — consolidate callers, document, lock). R11 sweep.
- **The fresh dart certification re-audit** against /Users/daleblack/Documents/sdk:
  re-walk PARITY_MASTER's per-dimension anchors (dispatch_table.dart, closures.dart,
  intrinsics.dart, code_generator.dart wrap/convertType/visitors) and record the
  march-4 completion in PARITY_MASTER.

## Traps (burned in this march)
- **Docstring stacking** (7×): never insert a docstring'd function above an existing
  docstring'd one — merge with the existing docstring.
- **Order lesson**: interiors before channel inversions; the audit hooks
  (WT_AUDIT_VALUE_STACK) are the tripwire — run them after each inversion.
- Fragment builders need `_seed_builder_locals!` (local types) or local.get tracking
  degrades.
- perl multi-line sweeps: grep the result immediately (an orphaned-splice repair was
  needed once).
