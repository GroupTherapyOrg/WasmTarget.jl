# MARCH 17 — THE ENFORCING BUILDER (Dale's hard directive: "the whole point of the migration")

## THE DISCOVERY (2026-07-06)
- The enforcement layer EXISTS and is sound: b.strict → StackImbalanceError at the emit
  site w/ rich context; `_wt_builder_strict()` docstring claims ON-since-07-01.
- THE GAP: the ctor hard-defaults strict=false; only int128.jl's 5 emitters pass
  strict=_wt_builder_strict(). The 07-01 "certification" tested nothing — ~150+
  construction sites run in collect mode. wasm-tools has been catching what the
  builder should.
- THE FLIP EXPERIMENT: strict-by-default → smoke 59/59 StackImbalanceError, all
  "stack underflow (past block base)" — NOT tracker false positives: FRAGMENT builders
  consume the parent's stack without declaring it.
- THE ARCHITECTURE IS ALREADY THERE: fragments declare inputs via `src.seeded`
  (append_builder! pops the seeds from the parent, pushes the fragment's results —
  the contract exists!). The debt = sites that pop past base WITHOUT seeding.

## THE PLAN
1. Make "underflow past block base" in a NON-seeded fragment name the site + the
   expected seed (the error already half-does this).
2. Burn down the hot sites (smoke names them): compile_call's arg-consuming arms,
   _emit_div_guard!, _emit_shift_guarded!, … Each site: seed the incoming types
   (_seed_stack! or the seeded vector) — mechanical once the pattern is set.
3. Ratchet: R6 (per-builder opt-outs) drives; add R-strict = # sites constructed
   non-strict, monotone down to 0.
4. FLIP the ctor default when smoke+batteries+gate pass strict; wasm-tools → CI-only.

## BURN-DOWN LEDGER (2026-07-06 evening)
14307 → 184 underflows (+ ~4k type-mismatches = the typed-channel campaign, staged).
DONE: _populate 96k→0 (declared truth + consumer narrows) · _op1! direct · SSA/slot
stores direct · drops direct · _rcb direct · egaleq seeded-from-tracked · the
_sub_builder seeder (div/shift/flipsign/isa/narrow-pair) · error propagation at merge ·
context threading · STAGED enforcement (_check!: UNDERFLOW throws, mismatch collects).
LAST 184: (a) generate_stackified_flow "GotoIfNot cond → i32" family (~56) — the
tracker opens the label BEFORE the cond pop while the bytes pop first (ordering nuance
in the stackifier's GotoIfNot emission — find where block! opens vs where the cond
emits, align the tracker ordering); (b) compile_call int128 sext family; (c) a few
compile_statement.frag tails. THEN: flip the ctor default (strict=_wt_builder_strict()),
run the FULL ladder, L-strict LOCK test (a default builder THROWS on an ill-typed emit),
gate, PR with march-16.

## THE LAST 78 (dict_get exemplar, warm-3 diagnosed): num! inside compile_call! on a
fresh builder holding [I32] popping I64×2 — the seeder copied a SHORT tracked stack:
fb's own stack under-tracks because the OPERAND emission upstream (the dict-key path)
flows through un-tracked arms. The 78 = upstream tracked-stack debt, not wrapper debt.
NEXT: in warm-3, WT_BUILDER_TRACE the dict_get compile; find where fb's tracked height
diverges from the real emission (the first emit whose tracked h drops below truth);
fix THAT arm's tracking (likely an emit_raw!/byte-bridge splice that pushes real values
without validate_push!). Then recount → flip → L-lock → gate.
