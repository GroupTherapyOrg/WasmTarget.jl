# Phase 1 Roadmap — A Fast, Full-Language Supposition Fuzzing Environment

> **Goal of Phase 1.** A *speedy*, *robust* differential-fuzzing apparatus that exercises
> the **full Julia language** as WasmTarget claims to support it — not a handful of Base
> scalar ops, but arbitrary well-typed compositions across primitives, collections,
> **structs**, **tuples/namedtuples**, **arbitrary/parametric types**, **control flow**
> (if / loops / comprehensions / short-circuit), and **try/catch**. The apparatus finds the
> brittle parts, records them as ledger gaps, and the *codegen* work (Phase 2) fixes them.
> Phase 1 is "done" when we can point the fuzzer at essentially all of supported Base + the
> language constructs above, run it fast enough to gate every commit, and trust a red result.

This file is a **map, not a script.** It states the shape of the work and the open questions
so a future agent can investigate, re-plan, and adapt. Verify every claim against the code —
some of it was written mid-investigation.

---

## 0. STATUS (2026-06-09, end of build-out)

All milestones are IMPLEMENTED and validated; see §5 for the map and §6 for the
sign-off checklist. The apparatus now: generates well-typed programs across
primitives (all widths) / strings / tuples / namedtuples / vectors (nested, of
structs) / dicts / sets / SEEDED GENERATED STRUCT TYPES, through statement-level
control flow (let/if/ternary/loops/comprehensions/early-return/short-circuit)
and try/catch/finally biased toward throw-tagged ops; transports every value
BIT-EXACTLY through the typed bridge (`bridge.jl` results, `bridge_args.jl`
arguments incl. MUTATION PARITY); matches known gaps STRUCTURALLY
(`canon.jl`, no substring holes) and dedupes new gaps by canonical root cause;
sweeps in parallel processes (`run.jl sweep`) and regenerates the
per-catalogue-entry coverage matrix (`run.jl coverage` → `COVERAGE.md`).
Headline findings the build-out itself ledgered: 32-bit reinterpret emits
invalid wasm; integer-index getfield traps on JS-crossed refs; Char's internal
representation is incoherent (transport-blocked); builtin error paths
(DivideError/InexactError/BoundsError) trap UNCATCHABLY while explicit Julia
throws are catchable; wasm-opt builds return garbage where native throws
(traps-never-happen unsoundness). The section below this one is the historical
state at the time of the blocker investigation; read it as history.

## 1. Where we were at the start (historical)

**The apparatus exists and works for a subset.** `test/fuzz/` is a Supposition.jl
choice-sequence fuzzer with: type-directed generators (`gen.jl`), a native-vs-wasm oracle
with 5-way classification (`property.jl` → `wrong_value` / `runtime_trap` / `divergent_throw`
/ `compile_error` / `optimizer_unsound`), shrinking, a DirectoryDB corpus, and a
self-closing **ledger** (`ledger.jl`, gaps in `failures/<id>.md` + `INDEX.md`). Entry points:
`run.jl` (deep sweeps, `verify`, the self-fulfilling loop) and `fuzz_suite.jl` (the bounded,
in-suite CI gate via `ci_fuzz_passes`).

**Speed is largely solved (~7 min → ~3:25).** The codegen test suite runs as **process
shards** (`WT_SHARD="i,N"`), each compiling a disjoint 1/N slice of ~80 lazily-registered
phases (`@pphase` → `_PHASES`), with a **PrecompileTools** `@compile_workload` baking the
wasm-compiler's JIT warmup into the `.ji` cache. Processes (not threads) because the wasm
compiler holds shared mutable state that races under threads — made task-local where needed
(`structs.jl`, `strings.jl`) but processes remain the robust choice.

**Robustness fixes landed this session (UNCOMMITTED, mostly validated):**
- World-age fix: `helpers/subtype.jl` include hoisted to module level.
- PrecompileTools dep collateral resolved (`test/fuzz` loads WasmTarget again).
- **Exit-propagation bug fixed** — the orchestrator's `failed` was a soft-scoped `for`-loop
  local that never reached `exit`, so a *failing shard silently went green*. Now
  assignment-free: `exit(any(!=(0), codes) || fp.exitcode != 0 ? 1 : 0)`. **Confirmed.**
- **Fuzz de-contention** — the differential fuzz now runs in its own pass (`WT_FUZZ=1`)
  *after* the codegen shards join, so its Node pool isn't CPU-starved.
- **Retry-on-timeout** in `run_driver` — a watchdog timeout retries on a fresh worker twice
  before being reported as a `:trap` (a real hang still surfaces; a load blip clears).
- **Regression-ratchet gate** — `ci_fuzz_passes` skips already-open ledger gaps
  (`_known_gap_bodies` + `_hits_known_gap` substring match) so only a *new* divergence reds
  the gate. Ledger gap `fa64c0d70add` records the real `Float64(typemax(Int64))` conversion bug.

**The current blocker (Section 2).** The bounded in-suite fuzz **fails under `Pkg.test`**
but **passes under `--project=test/fuzz`**, with the *same* Supposition 0.3.5. Root cause not
yet pinned. This must be resolved before committing — a gate that depends on which
environment runs it is not a gate.

**Open ledger backlog:** 25 open gaps (real WasmTarget codegen bugs). Surfacing them is
Phase 1's job; fixing them is Phase 2.

---

## 2. Immediate blocker — make the gate deterministic & reproducible

**Symptom.** `ci_fuzz_passes(types=(Int64,Float64), depth=2, max_examples=30, seed=0xCD)`
returns `true` standalone (`--project=test/fuzz`, both type-checks clean) but the Float64
check fails inside `Pkg.test`. Supposition is 0.3.5 in both; `known` loads 25 gaps in both.

**Leads worth chasing (in rough priority).** Don't assume — *capture the actual failing
body in the real `Pkg.test` env*, then compare.
1. **Instrument & run the real gate.** Add temporary diagnostics to `ci_fuzz_passes` (print
   `length(known)`, and on a `Supposition.Fail` print the minimal body, `string(body)`,
   `_hits_known_gap(...)`, and the `differential(...)` category/native/wasm). Run real
   `Pkg.test`; the orchestrator already prints the fuzz pass's log tail on failure. This tells
   you whether it's (a) a *different* body not covered by `known`, or (b) the same body whose
   `string` form doesn't match the stored construct.
2. **Dependency drift other than Supposition.** The Node bridge uses **JSON**, and the repo
   carries a `JSON = "0.21, 1"` compat that spans *two major versions*. JSON 0.21 vs 1.x can
   decode large numbers / BigInt differently — which is exactly the kind of thing that flips a
   `Float64(typemax)` comparison. Diff the full resolved Manifests of the two environments.
3. **`string(body)` rendering.** The known-gap skip matches on the *printed* form. If the
   generated literal renders differently across contexts (`9223372036854775807` vs
   `typemax(Int64)` vs a float literal), the `occursin` misses. Consider matching on a
   normalized/structural key instead of the raw string.
4. **Corpus replay vs fresh generation.** `ci_fuzz_passes` seeds the temp DB from
   `corpus/` then generates fresh. Determine which half produces the failing example.

**Structural fixes to consider (pick after diagnosis).**
- **Pin the test environment.** Commit a test `Manifest.toml` (or a tight `[compat]`,
  including JSON) so `Pkg.test` resolves *exactly* what we validate against. A regression
  ratchet must be reproducible bit-for-bit.
- **Separate the GATE from DISCOVERY.** The in-suite gate should be *deterministic and
  cheap*: replay the committed corpus (regression-only) plus a *small, fixed, hand-curated*
  program set — no env-sensitive fresh generation. Move fresh, seed-swept discovery to
  `run.jl` sweeps run on-demand / nightly, where non-determinism is a feature, not a flake.
- Make `known`-gap matching **structural** (compare canonicalized exprs), not string-substring.

**Definition of done for the blocker:** the same fuzz verdict in `Pkg.test`,
`--project=test/fuzz`, and a clean CI checkout; the suite is green; a *new* injected
divergence reliably reds it.

---

## 3. Coverage workstreams — toward the full language

The generator today covers a curated subset of Base scalar/vector ops. "Full Julia" is a
layered expansion. Each layer needs three things in lockstep: **(g)** generation, **(m)**
marshalling across the Node oracle, and **(v)** wasm-opt dual verification. A layer isn't
"covered" until a generated value of that shape can round-trip the oracle.

### 3A. Type universe (the spine everything hangs off)
Build a **type-directed generator**: `gen_of(::Type{T})` produces a well-typed expression of
type `T`, recursively (Supposition `Recursive` / `@composed`). Grow the universe of `T`:
- Primitives: all Int/UInt widths, `Float16/32/64`, `Bool`, `Char` (edge-biased literals:
  typemin/typemax, ±0.0, Inf, NaN, subnormals).
- Containers: `Tuple`, `NamedTuple`, `Vector`, `Dict`, `Set`, ranges, `String`/`SubString`.
- **Structs** (3D) and parametric structs; eventually small `Union`s / abstract targets.
The hard part is keeping generation *well-typed by construction* as the universe grows.

### 3B. Function catalogue (the vocabulary)
Enumerate Base functions as `(arg types) → return type` combinators feeding 3A. Start
hand-curated (it already is, implicitly, in `gen.jl`); expand methodically by Base module.
Tag each with whether it can throw (drives 3E try/catch) and whether it mutates (drives the
oracle's mutation handling). Long-term: consider reflection (`methods`) to suggest candidates,
but keep a vetted allow-list — raw reflection is too noisy and includes unsupported sigs.

### 3C. Control flow & bindings (statements, not just expressions)
A layer *above* expressions: `let`-bindings, `if/else` as a value, `&&`/`||`/ternary, `for`/
`while` with accumulators, comprehensions, multiple bindings, early `return`. Generate blocks
that thread state. This is where many real codegen bugs live (phi nodes, loop variables,
block result typing).

### 3D. Structs & nested/parametric types
Generate `struct` definitions (random well-typed fields), construct, field-access, pass as
args and return values. Requires **oracle marshalling of structs** (3E). Then parametric
structs (generate type params), mutable vs immutable, inner constructors. The runtests
suite already exercises hand-written structs — fold that knowledge into the generator.

### 3E. The oracle / marshalling bridge (the gating constraint) — CONCRETE DESIGN
The native-vs-wasm bridge currently round-trips scalars + vectors via JSON text — which the
JSON-0.21 incident (gap `fa64c0d70add`) proved is a soundness hazard: any value that crosses
as decimal text inherits the serializer's semantics. The replacement (`bridge.jl`, M1) is a
**type-directed, bit-exact accessor bridge**:

- **Descriptor**: from the static return type `T`, Julia computes a JSON descriptor tree
  (ints/Bool raw, floats as `reinterpret` BITS, Char as codepoint, String as codeunits,
  Tuple/NamedTuple/struct as field lists, Vector as len+get — recursively).
- **Accessor closure**: the minimal set of getter fns the descriptor needs (`getfield`
  wrappers, `_len`/`_get` per concrete Vector type, `_bits_f64`, `_scu` string codeunits…)
  is `@eval`-generated (memoized per type), compiled ALONGSIDE the target via
  `compile_multi((fn, args, mangled_name))`, and driven by ONE generic JS walker.
- **Comparison**: the Julia side walks the same descriptor against the NATIVE value —
  no reconstruction, no text. All numeric policy (NaN classes equal, ULP tolerance for
  transcendentals) lives in one auditable comparator, decoupled from transport.
- Accessor codegen is itself WasmTarget output — a bug there surfaces as a systematic,
  classified failure (it is part of the compiler under test, not a hidden oracle dependency).

Then: **mutation parity** (M2: re-read `!`-function args through the same bridge after the
call), throw/trap parity (already classified), and constructor wrappers so structs/tuples can
also be passed IN as arguments. **This is the pacing item** — no generation layer is real
until the oracle can compare its values.

### 3F. try/catch & error paths
Generate code that may throw (div-by-zero, bounds, conversion, `error(...)`) wrapped in
`try/catch/finally`, and assert native/wasm agree on *both* the value path and the thrown/
caught path. The classifier already distinguishes `divergent_throw`; extend generation to
deliberately provoke and handle throws.

### 3G. wasm-opt dual (already partly in place — finish it)
Every clean program is re-checked through wasm-opt (`OPT_LEVELS = (:size, :speed)` →
`-Os`/`-O3`, classified as `optimizer_unsound` on divergence). Ensure **every** generation
path (scalar, natural/vector, struct, control-flow) runs the dual check, not just some.

---

## 4. Apparatus: scale, speed, and the corpus/ledger

- **Two tiers, clearly separated.** (1) *In-suite GATE*: deterministic, fast, regression-only
  (corpus replay + fixed set) — runs every commit (Section 2). (2) *Discovery SWEEPS*:
  seed-swept, env-tolerant, heavy — run on-demand / nightly via `run.jl`, recording new gaps.
- **Parallel discovery.** Reuse the process-sharding pattern (independent seeds in N
  processes, temp DBs) so a deep sweep scales across cores like the codegen suite does.
- **Corpus hygiene.** Dedup, minimize (shrink-on-commit), and prune entries whose gap is
  fixed (the ledger `verify`/auto-close already does part of this). Keep the committed corpus
  small and meaningful so replay stays fast.
- **Ledger as the backlog.** Each gap is one `failures/<id>.md` with a self-contained
  reproducer; `verify_gaps!` auto-closes fixed ones. Keep `INDEX.md` regenerated. This is the
  hand-off surface to Phase 2 (codegen fixes).

---

## 5. Milestones (sequenced; 1–2 are DONE)

1. ~~**Unblock the gate** (Section 2)~~ — DONE (`db518dd`): JSON-0.21 decode corruption
   root-caused, pinned `JSON = "1"`, same verdict everywhere, suite committed green.
   ~~Speed~~ — DONE (`5631cf9`): LPT phase-packing + overlapped fuzz pass, 4:34 → ~2:24.
2. **M1 — typed bit-exact bridge for RETURN values** (3E): descriptor + accessor closure +
   JS walker + structural comparator. Universe: all int widths, Float32/64, Bool, Char,
   String, Tuple, NamedTuple, plain+nested+parametric structs, Vector{T} (nested).
   Validated by a standalone round-trip test file before the differential adopts it.
3. **M2 — argument side + mutation parity**: constructor wrappers marshal the same universe
   IN; `mutates`-tagged ops re-read their args through the bridge post-call and compare
   against native's post-call args.
4. **M3 — type universe + per-module catalogue** (3A/3B): catalogue files split by Base
   module, entries tagged `can_throw`/`mutates`/version bounds (the version tags are what
   make Phase 3 (julia 1.13) a catalogue DIFF, and Phase 4 (Statistics/LinearAlgebra…)
   just additional catalogue files). Struct POOL: K random struct types pre-`eval`d per
   sweep seed (world-age-safe), then used as ordinary types by the generator.
5. **M4 — statement layer** (3C): type-directed blocks — `let`, `if`/ternary/short-circuit,
   `while`/`for` with accumulators, comprehensions, early `return`.
6. **M5 — try/catch** (3F): provoke throw-tagged catalogue ops under `try/catch/finally`;
   assert parity on BOTH the value path and the caught path.
7. **M6 — discovery scale + the Phase-1-complete artifact** (Section 4): process-parallel
   sweep driver (reuse WT_SHARD pattern); structural (canonicalized-expr) known-gap matching;
   gap dedup by normalized minimal body; and a generated **coverage matrix report**
   (op × verified-passing / ledgered-gap / unsupported). *Phase 1 is checked off when every
   catalogue row is non-empty and the matrix is regenerated by one command* — the matrix is
   then Phase 2's checklist, worked gap-by-gap from the ledger.

## 6. Definition of done (Phase 1) — sign-off checklist
- [x] One command runs a **deterministic, green** bounded gate on every commit in ~minutes
  (`Pkg.test` ≈ 2:20, LPT-balanced shards + overlapped fuzz pass); same verdict under
  `Pkg.test` and `--project=test/fuzz`; known-open gaps skipped STRUCTURALLY, a new
  divergence reds it.
- [x] The generator emits well-typed programs spanning primitives (all int widths,
  Float32/64, Bool) → strings → tuples/namedtuples → vectors (nested, of structs) →
  dicts/sets → generated (parametric-pool) structs, with statement-level control flow
  and try/catch/finally — 0 natively-ill-typed programs in the health batteries.
- [x] Every value round-trips the oracle BIT-EXACTLY (typed bridge both directions,
  mutation parity for `!`-ops); wasm-opt dual-checking on every differential path.
- [x] A parallel discovery sweep (`run.jl sweep`) points at the whole universe and fills
  the ledger with real, deduped, self-reproducing gaps.
- [x] The coverage matrix (`run.jl coverage` → `COVERAGE.md`) reports per-catalogue-entry
  status — the regenerable Phase-2 checklist.
- Known scope notes carried into Phase 2: Char arg/return transport blocked by the
  compiler's Char-repr incoherence (b9d9c2d60d86); builtin error paths uncatchable
  (01aaf26b39e2); optimized builds unsound for trapping programs (dacbfa51e334 et al.).
  These are COMPILER gaps the apparatus correctly surfaces — not apparatus holes.

**→ Phase 2:** work the ledger + coverage matrix to full core-Julia-1.12 compat.
**→ Phase 3:** 1.12 + 1.13 (catalogue diff + version tags). **→ Phase 4:** stdlibs
(Statistics, LinearAlgebra…) as additional catalogue modules + overlays as needed.
Then cut the release.
