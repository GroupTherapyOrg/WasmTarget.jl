# Strict-Mode `unreachable` site inventory (step 1)

> Branch `wt-strict-mode`. 78 raw `Opcode.UNREACHABLE` emissions in `src/codegen/`.
> **Approach A default = LOUD.** We keep an `unreachable` only for a *physics* reason
> (it's required valid-wasm for a genuinely-dead point) or a *Base-ubiquity* reason
> (native throws there too, and erroring would reject most of the standard library).
> Everything else — a stub hiding a real operation we can't lower — flips to a
> source-attributed `WasmCompileError` under `strict=true`.

## Classification rule
A site is **LOUD (route through `record_unsupported!`, soundness_fatal=true)** iff the
construct it replaces would **return a value natively** (wasm-trap = silent divergence).
It is **KEEP** iff:
- **(A) structural dead-code** — the point is genuinely unreachable (all branches
  returned / loop only exits via return / `br`-terminated); wasm *requires* an
  `unreachable` here. Not a stub, not a failure. *(physics — erroring = erroring on
  correct codegen)*
- **(B) native-throws parity** — the stubbed callee throws natively (`Union{}`-return =
  always-throws; `throw_*`/`kwerr`/error fns). trap ≈ throw, AND nearly every Base fn
  carries dead `throw_domainerror`/`boundserror`/`kwerr` arms the IR can't prove dead, so
  erroring rejects the standard library. *(Base-ubiquity — see DECISION below)*

## Category A — structural / validator-required (KEEP; not stubs) — ~18
- flow.jl: 309 (both branches return), 1895/1896 (infinite loop exits via return)
- conditionals.jl: 194 (post-return safety), 2754 (dead else, `goto_if_not_type===Union{}`),
  3230 (all paths RETURN), 3270 (all paths RETURN)
- compile.jl: 1166, 1265 (end-loop, all paths `br`)
- dispatch.jl: 634, 1214 (megamorphic call_indirect table miss — "shouldn't happen"
  backstop ≈ MethodError native throws; lean KEEP, revisit if reachable)
- strings.jl: 763 (loop always `br`)
- stackified.jl: 2203 (trailing-unreachable guard)
- generate.jl: 92, 183/184/186 (validator scan + dead-RETURN→UNREACHABLE *rewrite*, not new)

## Category B — native-throws parity (KEEP, narrow + justified) — ~4
- calls.jl: 6899 (callee `return_type === Union{}` → always-throws)
- invoke.jl: 2983 (callee `return_type === Union{}`)
- statements.jl: 1568/1569 (SSA type `Union{}`, void error/throw call)
- **DECISION FOR DALE:** keep these exempt (reject most of Base if not), or go maximally
  pure and make even native-throw stubs loud? My rec: KEEP, because the trap *matches*
  native for uncaught throws and erroring would reject ubiquitous dead error-arms. Caveat:
  a *caught* throw (try/catch) diverges (wasm trap is uncatchable) — already covered by the
  differential fuzzer's try/catch parity checks.

## Category C — real-operation stubs → FLIP TO LOUD (the Approach-A core) — ~20
Native returns a value; wasm silently traps. These get `record_unsupported!(...; soundness_fatal=true)`.
- calls.jl: 658 (Int128 checked mul), 2020 (typeId dispatch-ladder miss = boxing→dispatch),
  4517 (externref-as-numeric = boxing), 4971 (Int128 checked div/rem/etc), 5125 (externref
  numeric, SSA `Any` = boxing), 5149 (externref numeric = boxing), 5241 (Int128 checked add),
  5317 (Int128 checked sub), 6485 (`pointerset` — no linear memory), 6594 (unknown reduce
  target), 6600 (multi-container `_apply_iterate`), 6608 (`Core.svec`)
- statements.jl: 1785, 1799 (`:new` of dynamic/unresolvable type — struct build)
- invoke.jl: 4242 (`getindex_continued`), 4443 (`parse_float_literal`), 4451
  (`parse_uint_literal`), 4484+ (further parse intrinsics — confirm)
- compile.jl: 1379 (`str_substr` standalone body), 1832 (`stub_names` deliberate stub),
  1882 + 1979 (**dispatch-isolation**: discovered fn crashed codegen / invalid — THIS is the
  path the abstract-Dict BigInt ladder takes; under Approach A it must be LOUD: a reachable
  function in the closed world that won't compile)

## Category D — gray: `return_type_compatible` mismatch + fallthroughs — ~11 (verify individually)
These trap when a value can't be returned as the function's declared wasm type. Some are
GENUINE (return real → unsound → make LOUD); some are FALSE (e.g. stackified.jl:1890 notes
the check "incorrectly fails" when a phi local was overridden to i64 — value is correct, the
*check* is wrong → FIX the check to return the value, don't trap).
- flow.jl: 149, 171, 248, 1332, 1628, 1796, 2133 — `!return_type_compatible(...)`
- conditionals.jl: 62 — `!return_type_compatible(...)`; 2025 (else fallthrough — read)
- stackified.jl: 406, 1625, 1890 — `!return_type_compatible(...)` (1890 = known false-alarm)
- calls.jl: 4781, 4960, 6476, 6649 — handler fallthroughs (read each)

## Net
- **~20 sites flip to LOUD** (Category C) — the real Approach-A work; includes every
  boxing→dispatch path (abstract-Dict resolves here as a loud reject = out-of-subset).
- **~18 KEEP** (A, structural — physics).
- **~4 KEEP pending DECISION** (B, native-throws — Base-ubiquity).
- **~11 verify individually** (D — fix false-alarms, make genuine ones loud).
- **~7 are detection/rewrite, not emissions** (no action).

## Next (step 2)
Add `emit_unsupported_stub!(ctx, bytes, kind, construct; idx, soundness_fatal=true)` helper
(record → throws under strict → else emit unreachable + set last_stmt_was_stub), convert the
Category-C sites to it, resolve Category-D per-site, then gate on full Pkg.test + downstream CI
(over-rejection of valid code is the risk).

## DECISION RESOLVED (2026-06-23) — Category B stays PRAGMATIC (data-backed)
`test/fuzz/strict_pure_probe.jl` measured the "maximally pure" blast radius (make
native-throws/`Union{}`-return stubs fatal) on 20 ordinary functions:

**PURE rejects 11/20**, including `sqrt`, `log`, `v[1]`, `v[end]`, `sum`, `maximum`,
`s*"x"`, `length(s)`, `parse(Int,s)` (308 throw-arms across 25 fns!), `floor(Int,x)`,
`sort`. Survivors are only error-path-free arithmetic (`1/x`, `div`, `%`, `x^3`, `abs`,
`clamp`, `muladd`, polynomials). Cause: every one carries `@boundscheck`/DomainError/
InexactError arms the IR can't prove dead — traps that never fire on valid inputs.

⇒ **Pure is a non-starter** (it rejects basic indexing/strings/math). Category B stays
NON-FATAL (keep the silent `unreachable`). Residual gap: an uncatchable wasm trap vs a
catchable native throw — but ONLY when the error path is both *reached* and *caught*; the
differential fuzzer already guards try/catch parity. FUTURE (best-of-both, deferred):
compile throw-arms to real *catchable* wasm exceptions so they're faithful instead of
uncatchable traps — closes the residual without rejecting. Not needed now.

**Net effect on the plan:** only Category C (~20 real-operation stubs) flips to LOUD;
Categories A (structural) and B (native-throws) stay as-is; Category D verified per-site.

## BATCH-4 RESULT (2026-06-23) — the dynamic-dispatch cross-call stub CANNOT be made loud
Converting the unresolved-cross-call stub (calls.jl ~7036, where `dict_with_eltype` and
other dynamic dispatch land) to a loud reject — even with a `Union{}`-return (always-throws)
guard — **OVER-REJECTS valid code**: full Pkg.test failed 6 shards + the fuzz pass, and a
GREEN PI fixture (`dither.jl#1`) regressed to `compile_fail`. Root: this site is
overwhelmingly **dead Union-branch code the IR can't prove dead** (its own comment says so),
not reachable dynamic dispatch — and WT has no static reachability analysis to tell the
abstract-Dict `dict_with_eltype` (reachable) apart from a dead-branch `f(::WrongUnionMember)`
(never executed). The `Union{}` guard only catches the always-throws subset; value-returning
dead-branch calls are everywhere. **Batch 4 REVERTED.**

Consequence: the abstract-Dict-key cluster (and general type-instability dynamic dispatch)
**stays a silent trap (deferred), NOT reclassified to out_of_subset** — the loud-reject floor
can't reach it without reachability analysis or actually compiling it (the gated dyndispatch
frontier). Approach A's clean wins are the DEFINITE-unsupported operations (batches 1–3).
The `out_of_subset` ledger machinery (designed: `_run_reproducer` → :fixed/:out_of_subset
[caught WasmCompileError]/:open) is DEFERRED — with batch 4 reverted it would reclassify ~0
current ledger gaps.

## SHIPPED (batches 1–3) — Approach A for definite-unsupported operations
Loud `WasmCompileError` (strict, default) instead of silent `unreachable` for: Int128 checked
mul/div/rem/add/sub, `Base.pointerset`, `Core.svec`, parse_float/int/uint_literal,
`_apply_iterate` (unknown reduce target / multi-container), numeric intrinsic on an
Any/externref (boxed) operand, `:new` of a non-constant/unresolvable struct type. Full
Pkg.test green; PI fixtures hitting these correctly flip `runtime_trap → compile_fail`
(loud, source-attributed); ZERO green regressions.
