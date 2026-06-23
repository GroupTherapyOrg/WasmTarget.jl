# WT Strict Mode — "narrow but bulletproof" (Approach A)

> Branch: `wt-strict-mode`. Companion to `LOOP.md`. Decided 2026-06-23 (Dale).

## The one-line goal
WT **refuses to emit wasm for code it cannot compile faithfully** — with a loud,
source-attributed error — instead of silently emitting an `unreachable` stub that traps
at runtime (or, worse, valid-but-wrong wasm). The contract becomes: **if it compiled, it
is faithful to the Julia.** Coverage grows via *demand-driven overlays*, not best-effort
dynamic machinery.

## Why (grounded — see the 2026-06-23 conversation)
- **Soundness mandate + the commercial product.** The notary for *frozen, verifiable*
  Julia algorithm artifacts (Beacon/FDA, Pumas) REQUIRES "compiled ⟹ correct." You can
  never hand a regulator a wasm that silently computes the wrong answer. Loud-reject *is*
  the value proposition.
- **Near-zero downstream cost.** WT only compiles "leaf" computations (cell bodies, plot
  kernels). The Dict-heavy framework code (Therapy 173 / PI 45 Dicts) runs host-side in
  native Julia and never touches WT. There are **zero** mixed-int-width Dict literals (the
  abstract-key trigger) anywhere in real downstream code — that whole cluster is a fuzzer
  artifact. So strict-reject refuses almost nothing real.
- **Precedent.** AssemblyScript (the leading TS→wasm compiler) bakes rejection into its
  type model (no `any`/unions; primitives + declared classes; escape hatches = generics /
  `Map` / `@unmanaged`) and thrives. Julia's `--trim` verifier already loud-rejects dynamic
  dispatch for static compilation.

## Scope — GOOD NEWS: the machinery already exists (this is coverage, not a rewrite)
`src/codegen/diagnostics.jl` already has:
- `record_unsupported!(ctx, kind, construct; soundness_fatal, idx, detail)` — under
  `ctx.strict && soundness_fatal` it **throws `WasmCompileError`** (source-attributed)
  instead of stubbing.
- `WasmCompileError`, the `:value_stub` "never silently downgrade" rule, `soundness_fatal`.

The gap is COVERAGE:
- **78** raw `Opcode.UNREACHABLE` emissions across `src/codegen/`; only **10** sites route
  through `record_unsupported!`.
- **23** `last_stmt_was_stub = true` markers in `calls.jl` alone.
- The boxing→dynamic-dispatch stubs (abstract-Dict, the dispatch-isolation ladder, etc.)
  take the **silent** `unreachable` path → compile + trap. They must take the **loud** path.

## Plan (in order; commit + verify per step)
1. **Classify the ~78 `UNREACHABLE` sites** into:
   - (a) **benign dead-code** — emitted after a `br`/in a provably-dead branch / Union dead
     arm. These are CORRECT; LEAVE them.
   - (b) **real "can't lower this construct" stubs** — route through
     `record_unsupported!(...; soundness_fatal=true)` so `strict=true` rejects loudly.
   Build the inventory first (grep + per-site read); do not bulk-convert.
2. **Dynamic-dispatch / boxing stub sites** (the calls.jl `last_stmt_was_stub` set + the
   dispatch-isolation path in `compile.jl`/`trimcollect.jl`): these are category (b). Route
   them to a strict error naming the offending call + its inferred (abstract) arg type +
   source location. This is the class that turns "silent trap" → "loud reject" (Dict is one
   instance; closures/vararg are others).
3. **Default policy** (decide; gate on FULL CI matrix incl 1.13 — never 1.12-local alone):
   - Keep `strict=false` the library default for back-compat, BUT make the differential
     fuzzer, downstream CI, and the notary/PlutoSpace build path use `strict=true`. OR flip
     the default to strict. Lean: flip downstream/product to strict first, measure, then
     consider flipping the global default.
4. **Trim verifier** (optional escalation): run `collect_closed_world(verify=true)` under
   strict to get inference-level dynamic-dispatch rejection with upstream's source-located
   diagnostics, as a second net above codegen-site detection.
5. **Fuzzer / loop integration** (LOOP.md §2): the subset is *already* defined as "strict
   ACCEPTS ∧ validates ∧ differential agrees." Now strict will actually reject, so:
   - Teach the loop that **strict-reject = out-of-subset = SOUND = close-the-gap** (not an
     open bug). Add a gap status like `out_of_subset`.
   - Re-classify the ~14 abstract-Dict + the depth-4 sweep gaps as out-of-subset (they were
     never really in-subset; loud rejection is the sound resolution).
   - The generator only emits *inside* the subset, so it stops re-spawning the cluster.
6. **Escape hatch (Approach B, surgical):** demand-driven overlays for specific high-value
   constructs only when REAL downstream needs them. The validated `_WTDict` (i64-normalized
   linear-scan, dispatch-free — see 05b2b084ef65 conversation) is the shelf-ready example;
   build it only on demand.

## Verify gates (every change)
- **Full `Pkg.test` green** — the MAIN RISK is over-rejection: a stub site that's actually a
  WORKING fallback getting routed to strict-error → false rejection of valid code. Each site
  must be classified, not bulk-converted.
- **Differential fuzzer**: no new false-rejections of in-subset programs.
- **Downstream CI (PlutoIslands / WasmMakie / Therapy) green** — confirms the strict guard
  doesn't reject real compiled cells/figures. This is the decisive "did we break coverage"
  check.
- `loop_guard.sh` clean.

## Non-goals
- NOT the codegen-level dynamic-dispatch frontier (the risky `_try_inline_typeid_dispatch`
  primitive-candidate work). Strict mode *rejects* that class; we don't try to *compile* it.
- NOT a dependency on JET / AllocCheck / DispatchDoctor / StrictMode.jl. WT enforces at the
  compiler level (stronger for correctness-vs-native than a linter). Those remain optional
  author-side pre-flight tools at most.

## Research references (2026-06-23)
- AssemblyScript: type-model-based rejection + escape hatches + capability imports.
  https://www.assemblyscript.org/concepts.html
- Julia `--trim` verifier (the official static-compilation loud-reject): JuliaLang#58458.
- Keno strict mechanism (syntactic, not boxing): JuliaLang#54903.
- DispatchDoctor.jl `@stable` (split-fn + `isconcretetype` return-type check), AllocCheck.jl
  (LLVM-IR scan → object-creation / dynamic-dispatch / runtime-alloc), StrictMode.jl
  (`@assert_noboxing`/`@assert_trim_safe` bundling) — author-side linters; reference designs.
