# The WasmTarget soundness loop — autonomous campaign spec

> **North star.** WasmTarget compiles the *entire set of Julia and Julia packages*.
> Pluto featured notebooks (via PlutoIslands), Therapy `@island`s, and WasmMakie
> figures are **stepping stones / seed corpora**, not the driver.
>
> **The whole campaign is one loop:**
> generate a program *inside the supported subset* → run it **native (ground truth =
> Julia compiling itself)** → run the **wasm** → **diff** → **shrink to a minimal
> counterexample** → **fix WasmTarget codegen** → **regress forever**. An agent `/loop`
> drives it. Because native Julia is the oracle, "we just match WT to native" is a
> *sound* goal — provided both sides agree on the subset (see §2).

This file is the **operational contract** for that loop. Read it every iteration.

---

## ⭐ CURRENT STATE & LESSONS (2026-06-18, post-v0.3.10 — read FIRST; trust this where the older sections below conflict)

The lower sections were written BEFORE the work. This block is the up-to-date overlay.

**Done + RELEASED (v0.3.10, registered in General):** P0 guardrails — G1 paranoid value-stubs
(`WT_PARANOID_STUBS`), G2 frozen hash-pinned oracle + sweep input rotation, G3 `run.jl rank`
leverage ranking. Dynamic dispatch **ON by default** (`WT_DYNDISPATCH=0` to disable):
non-perturbing collection + registry isolation (`FunctionInfo.is_candidate`) + PURE-9060
reconciliation (discovery yields to call_indirect for ≥9-method fns) — verified safe on
WT-suite + WasmMakie + PlutoIslands gate-on. median/quantile cluster closed. PlutoIslands
added to `downstream.yml`. **Open gaps: 15** (was 22). Everything in §7-P0 and T1.1 below is
COMPLETE — do not redo it.

**Remaining = the DEEP TAIL (the real frontier; each a genuine multi-iteration codegen fix):**
abstract-Dict-key cluster (11 — needs PRIMITIVE megamorphic `hash`/`isequal` dispatch over
Int32/Int64 abstract `Signed` keys; a *different* mechanism than the struct typeId dispatch
just shipped), Complex→Ryu reachable-`unreachable` (1), dispatch-ladder `1f6e77980994` (1),
closure-dep i64/i32 in `compile_closure_body` (1), Matrix/hvcat element trap (1).

**LESSONS from the v0.3.10 run — APPLY THESE:**
1. **FALSE-OPEN TRIAGE before grinding.** Some "open" gaps are already-fixed code `verify`
   can't see — `verify` has session-cache + missing-import **false-negatives** (the median
   cluster was 7 such: verify lacked `using Statistics`). Before treating a gap as a codegen
   bug: (a) reproduce in a **FRESH process** (not just `verify`); (b) confirm the verify/harness
   env is complete (stdlib imports; `js-string` builtins). Cheap real wins; avoids deep grinds
   on already-fixed code.
2. **Synthetic gaps ≠ product impact.** Dynamic dispatch landed + is safe but closed ZERO
   ledger gaps AND zero PI wins (Dict needs primitive dispatch; PI sidesteps markdown dispatch
   via its md-skeleton). Do NOT equate ledger progress with the PI/Therapy goal — periodically
   validate against REAL downstream (now wired: `downstream.yml` runs PI/WasmMakie/Therapy).
3. **`rank` count MISLEADS.** The highest-count clusters were the HARDEST or mis-tiered (Dict
   ranked T0 but is T1-dispatch; median was a false-open). Re-verify a gap's tier/reality by
   reproducing before committing to a deep grind.

**Honest corrections to the plan below:** §2's "Frontier budget (mandatory)" was NEVER built
(the generator isn't tier-parameterized) — treat as a TODO, not a requirement; the loop reaches
the frontier via the ranked open-gap queue. §5(a) (PI in `downstream.yml`) is DONE. §5(b)
in-repo PI fixtures — once "BLOCKED on js-string" — are now **DONE** (2026-06-18): the real
blocker was that the unit harness only decoded SCALAR returns, fixed by wiring the in-package
bit-exact `WasmTarget.Bridge` into `compare_julia_wasm_bridge`. See the new section below —
**this is now the loop's primary, product-grounded KPI.**

---

## 0.5 ⭐ PI ISLAND FIXTURES — the product-grounded loop KPI (2026-06-18, current driver)

**The loop now targets REAL PlutoIslands island cells directly, in WT's own test suite.**
This resolves Lesson #2 ("synthetic gaps ≠ product impact") at the root: the unit of work is
a **PI island piece**, and the KPI is **"PI pieces green: N / total"** (not synthetic ledger
count). The synthetic fuzzer stays as the soundness *backstop* (finds new bugs); PI fixtures
drive *priority*.

**Mechanism (no PI/Pluto dependency in WT):**
1. **Harvester** (`PlutoIslands.jl/tools/harvest_wt_fixtures.jl`, run in PI's Pluto env)
   walks every featured notebook → every `@bind` group → every extracted cell, emitting
   `WasmTarget.jl/test/integration/pi_island_fixtures.json`: `{notebook, bonds, argtypes,
   preamble, cell{fn_src, rettype, samples, GOLDEN native outputs}}`. Failing/extract-failed
   pieces are recorded too (status tracked, never dropped).
2. **WT test** (`test/integration/pi_islands.jl`, run from `runtests.jl`) evals each piece's
   fn (+ preamble + a vendored `PlutoIslands._plain_body`/`_html_body` shim), compiles via
   `compile_multi`, runs through the in-package bridge (`compare_julia_wasm_bridge`), and
   classifies: `green` / `mismatch` / `runtime_trap` / `compile_fail` / `outside_bridge` /
   `nonscalar_args` / `extract_fail`. A drift guard asserts the vendored fn reproduces the
   captured golden.
3. **Status LOCK** (`pi_island_status.json`): the testset asserts each piece's live status ==
   locked status, so a `green→fail` (regression) AND a `fail→green` (unrecorded fix) BOTH
   fail the suite. Known-failing pieces don't redden CI in steady state; any FLIP is loud.

**The loop iteration becomes:** read the status table → pick the highest-value FAILING piece
(cluster by status reason — `compile_fail`/`runtime_trap`/`outside_bridge`/`nonscalar_args`
are the work-item families) → diagnose → fix WT codegen → piece flips `green` →
`julia --project=. test/integration/regen_pi_lock.jl` → commit lock → regress forever.

**Current state (2026-06-18):** 9 pieces from the 2 light notebooks (Interactivity, Basic
mathematics): **7 green**, 1 `mismatch` (`string(typeof(x))` → empty; Type-name/Type-as-value
gap = a real work item), 1 `nonscalar_args` (6-bond String/Bool/DateTime group — needs
`bridge_run_args`-style arg bridging). **Full-corpus harvest is PENDING** (task #40): the
heavier notebooks (PlutoUI, newton, fractals, convolution, images, dither, turtles, Titration)
returned 0 groups because their embedded Pluto package envs didn't run in the harvest session —
re-run the harvester after warming those envs (e.g. via `tools/island_survey.jl`).
**Re-harvest:** `cd PlutoIslands.jl && julia --project=. tools/harvest_wt_fixtures.jl` then
regen the lock. KPI today: **7/9 green** (will grow to the full ~38-shipping / 65-total corpus).

---

## 0. Read this first — what already exists (DO NOT rebuild)

The apparatus in `test/fuzz/` already implements the entire core loop, and it works
(243 gaps recorded, 221 fixed). Before adding anything, use what's here:

| Capability | Where | Status |
|---|---|---|
| Generate well-typed random programs (Supposition) | `generators.jl`, `statements.jl`, `catalogue.jl` | ✅ |
| **Bit-exact** differential oracle (descriptor-tree bridge, mutation parity) | `property.jl` (`tree_matches`, `_differential_args`) | ✅ — *not a TODO* |
| Optimizer-soundness check (raw vs `-Os`/`-O3`) | `property.jl` (`:optimizer_unsound`) | ✅ |
| Automatic shrinking to minimal counterexample | Supposition `@check` | ✅ |
| Auto-closing gap ledger (`throws-while-broken / runs-when-fixed`) | `ledger.jl`, `failures/<id>.md` | ✅ |
| Structural dedup of gaps | `canon.jl` | ✅ (but weak — see §6) |
| Corpus regression ratchet (replays known CEs first) | `corpus/`, `fuzz_suite.jl` | ✅ |
| Parallel sharded sweeps | `run.jl` (`sweep_parallel`) | ✅ |
| Closed-world (trim) collection of the callgraph | `src/codegen/trimcollect.jl` | ✅ |

**Explicitly CUT from the original design** (they are gold-plating *now*):
- **EMI / metamorphic relations** — the native-Julia differential is a *stronger*
  oracle than any metamorphic relation (it's the ground truth, not a relation between
  outputs). EMI's value is amplifying a *scarce* seed corpus; the generator isn't
  corpus-starved. **Defer EMI to Tier-2+**, where the seeds are real package code you
  *can't* generate (PI/Therapy/WasmMakie cells).
- **Trim verifier as the subset gate** — `collect_closed_world` runs it only under
  `verify=true`, and every caller passes `verify=false`. Keep the trim **collector**
  (consistent-world callgraph); do **not** couple the fuzzer grammar / reducer
  invariant to `Compiler.verify_typeinf_trim` internals, which drift across 1.12/1.13.
  Use it at most as an optional *diagnostic enhancer* on rejection.
- A from-scratch "one machine-readable subset artifact" — the subset is already
  *operationally* defined (see §2); promoting it to a declarative file is a nice refactor,
  not a bottleneck.

---

## 1. The central tension (resolve it or the loop is a treadmill)

A fuzzer that only generates *inside* today's subset will polish the easy interior
forever (Dict-key edges, narrow-int shifts, Ryu) and **never reach the frontier** that
Pluto/Therapy actually need: **dynamic dispatch, type-instability from non-const
globals, `Type`-as-value.** The 221 fixed gaps are real but interior. "Subset-first"
must not become "look productive while never tackling the real frontier."

**Resolution: the subset is TIERED and ADVANCING. The loop's KPI is "floor raised",
not "gaps closed."**

---

## 2. The supported subset — operational definition + tiers

WT's subset is defined **operationally, WT-owned** (not by the trim verifier):

> A program is *in the subset* ⟺ **strict mode accepts it AND validation passes AND
> the differential agrees with native.** This is exactly what `property.jl` computes
> per program. WasmGC-expressibility and codegen-coverage are WT-specific, so the
> subset must be WT's, narrower than juliac `--trim`:
> **WT subset = (trim's *dynamism* boundary) ∩ (WasmGC-expressible) ∩ (codegen-covered).**
> Intersect *downward*: never accept anything native-AOT-Julia would reject, so the
> oracle stays sound. (No raw `ccall`/`Ptr`/`unsafe_load`; exception-handling limits;
> no threads/atomics yet — all narrower than trim.)

**Tiers** (the generator is parameterized by tier; KPI = pulling capability T(n+1)→T(n)):

- **Tier 0 — type-stable, statically-resolvable.** Scalars (all int widths, floats,
  bool, char), strings, tuples/namedtuples, vectors/dicts/sets, structs, control flow
  (if/loops/comprehensions/short-circuit/try-catch). *This is what the fuzzer generates
  today.* **Goal: open gaps → 0, corpus stays green.** (22 open now.)
- **Tier 1 — bounded dynamic dispatch over a CLOSED concrete-type set.** Union-split +
  the `_dynamic_dispatch_candidate_mis` machinery in `trimcollect.jl`, made
  *non-perturbing* (separate collection + merge, NOT re-running `CC.compile!` on the
  shared interp — see its own comment) so `WT_DYNDISPATCH` can default ON. Unblocks
  markdown-AST `plain`/`show` dispatch. **First frontier target.**
- **Tier 2 — `Type`-as-value + Union-typed locals + type-instability from non-const
  globals.** The `julia_fractal(f::UnionAll)` / conv-kernel shape; boxing-in-phi/loop
  gaps. Here **PI/Therapy/WasmMakie cells become scarce real-world SEEDS** → freeze as
  fixtures (§5) and EMI-amplify.
- **Tier 3 — library internals** (objectid / hash-consing / Symbolics `Method`
  constants). Candidate *honest refusals* or precompute-at-extraction; not assumed
  in-subset.

**Frontier budget (mandatory):** every sweep spends a fixed fraction generating
**Tier+1 programs expected to fail**. Those failures *are* the frontier ledger — they
name the next capability to build. A sweep that only generates Tier-0 is incomplete.

---

## 3. Guardrails — the loop must not reward-hack its way green

An autonomous agent told "make the differential pass" can cheat. These are
**non-negotiable**; `loop_guard.sh` enforces the mechanical ones each iteration.

1. **Never bypass the oracle.** No `strict=false`. No widening `rtol`/`atol` or editing
   `vals_match`/`tree_matches`/`sample_inputs` in `property.jl`. No editing the
   generator's input/literal lists to dodge a case. The oracle and generators are
   **frozen** w.r.t. a fix iteration; they change *only* for deliberate tier expansion,
   reviewed by a human.
2. **Never mask with a stub.** A `value_stub` emits a *wrong value* — adding one to make
   a gap "compile" is the cardinal cheat. A bare `unreachable` is sound *only* for
   value semantics; it is **not** equivalent to a catchable Julia exception (we have 12
   `divergent_throw` gaps — at the notebook/try-catch level a wasm trap kills the
   module). Do not close a `divergent_throw`/`runtime_trap` by routing to `unreachable`.
3. **The genuine-fix proof is execution, not compilation.** A real fix means: compiled
   `strict=true` AND `validate=true` AND **executed in Node** AND `tree_matches` native
   (value + mutation parity), or throw↔trap parity. This is exactly what each gap
   reproducer asserts — so *re-running the reproducer and getting no error is the proof.*
4. **No regression.** The full sharded suite (`runtests.jl`) must exit 0 and the corpus
   ratchet (`fuzz_suite.jl`) must not re-diverge any fixed CE.
5. **Known soundness hole (P0, see §7):** `diagnostics.jl:170-181` downgrades
   `:value_stub` from fatal→silent on *discovered* (non-entry) functions. A buried
   value-stub can therefore compile "clean" and only trap off-sample. Until G1 lands,
   `loop_guard.sh` rejects any diff that *adds* a `:value_stub`, and verification must
   rotate inputs (§7-G2) so off-sample stubs surface.
6. **Diff scope.** The loop edits `src/codegen/**` (and, for tier expansion only,
   `generators.jl`/`statements.jl`/`catalogue.jl` with human review). It does **not**
   edit the oracle match logic, the strict-mode fatality table, or delete/skip tests.

**Guard-flag policy (Dale, 2026-06-17):** the **P0 harness tasks (G1/G2/G3) are
sanctioned** to modify the harness itself (diagnostics.jl fatality table, property.jl
oracle/sampling, canon.jl/ledger.jl dedup) — `loop_guard.sh` *will* flag them; show the
diff and proceed **without** a hard stop. The hard-**STOP-and-ask** is reserved for guard
flags during **real gap-fix iterations**, where touching the oracle/generators/fatality
table IS a cheat. Once G1–G3 land, any guard flag is presumed a cheat until a human says
otherwise.

---

## 4. One iteration — the runbook

Cost model (measured): **~80 s precompile** after any `src/**` content edit (per env;
no Revise) · warm repro **~5 s** · full sharded suite **~2.5 min** · fuzz pass tens of s.
So: *batch edits, pay precompile once, then fire many warm checks.*

```bash
ROOT=/Users/daleblack/Documents/dev/GroupTherapyOrg/WasmTarget.jl ; cd "$ROOT"

# 1. PREFLIGHT — refuse to start dirty-cheating; baseline must be green-ish.
test/fuzz/loop_guard.sh HEAD || echo "(clean working tree expected at start)"

# 2. PICK the single highest-leverage open gap (see §6 ranking), or — if a §7 P0
#    guardrail task is unfinished — do that instead. Read its file end-to-end:
#    test/fuzz/failures/INDEX.md  →  test/fuzz/failures/<id>.md (## Analysis matters)
#    (Discover fresh, incl. the Tier+1 frontier budget:)
#    julia --project=test/fuzz test/fuzz/run.jl sweep 600

# 3. CONFIRM the gap is real — copy the ```julia repro into /tmp/repro.jl:
julia --project=test/fuzz /tmp/repro.jl        # MUST throw  (~80s cold once, ~5s warm)

# 4. FIX src/codegen/** — strict semantics, no masks (§3). Port Base semantics verbatim.

# 5. PROVE it (recompile auto, ~80s once):
julia --project=test/fuzz /tmp/repro.jl        # MUST now run clean

# 6. NO-REGRESSION gate:
julia --project=test/fuzz test/fuzz/run.jl verify   # auto-closes the gap → status: fixed
WT_SHARD=0,10 julia --project=. test/runtests.jl    # the shard(s) covering your change
julia --project=. test/runtests.jl                  # full sharded suite — MUST exit 0
julia --project=test/fuzz test/fuzz/run.jl sweep 300 # gap must not immediately resurface

# 7. CHEAT-SCAN the diff — STOP and surface to human if flagged:
test/fuzz/loop_guard.sh HEAD

# 8. COMMIT (branch wt-soundness-loop; standard trailer). Include src/ + the now-`fixed`
#    gap .md + updated INDEX.md, and write root-cause into the gap's ## Analysis.
```

---

## 5. PlutoIslands / Therapy / WasmMakie as integration tests (Reactant pattern)

Reactant does **not** run downstream suites in its CI — it *vendors* targeted tests and
pins each to the bug it guards (`@testset "... #861"`). Copy that:

- **(a) Coarse backstop:** the existing `.github/workflows/downstream.yml` runs
  WasmMakie + Therapy suites against the WT checkout. Add **PlutoIslands** to that
  matrix (PI already path-sources WT at `../WasmTarget.jl`). Borrow the ChainRules
  refinement: catch `Pkg.Resolve.ResolverError → exit 0` so a deliberate breaking WT
  release reads as "compat-incompatible", not "WT regressed".
- **(b) High-value, in-repo:** freeze PI's differential-oracle corpus as fixtures.
  PI's `extract.jl` already yields `(fn_expr, sampled args, native expected)` per cell —
  the same shape as WT's `test/ground_truth/*.json`. A PI-side `tools/` exporter emits
  them; commit into `WasmTarget/test/ground_truth/islands/<notebook>_<cell>.json`; add a
  phase that runs them through `compare_julia_wasm`. Now a codegen regression that would
  break a real island fails as a **named, fast, Pluto-free WT unit test pointing at the
  exact notebook cell** — the "perfect feedback" goal. These cells are Tier-2/3 seeds;
  they also feed EMI later.

---

## 6. Dedup + leverage ranking (so the loop converges, not floods)

`canon.jl` dedups on the *minimal shrunk body*, but shrinking is non-deterministic, so
one root cause spawns many gaps (the open ledger has ~6 `runtime_trap` files that are all
the same Int32-keyed-Dict-with-`sum`-key collision). Fix:

- **Dedup on root cause = `(WasmDiagnostic.kind, julia_loc)`** of the *first*
  `record_unsupported!` the failing compile emits — far more stable than the AST. Two
  programs that trip the same codegen site at the same source line are one gap.
- **Rank open gaps by `(# distinct surface bodies mapping to the same diagnostic site) ×
  tier`.** Work the highest fan-in first — that's the bug blocking the most programs, not
  the easiest shrink. (The 6-form Dict cluster = high fan-in = do first.)
- **Quarantine thrash:** if `verify_gaps!` closes a gap that a sweep re-finds within N
  runs (the module-sensitivity caveat in `ledger.jl:247-256`), tag it `unstable` and
  exclude from the green metric until a human confirms.

**Implemented (G3):** `julia --project=test/fuzz test/fuzz/run.jl rank` →
`Ledger.rank_gaps()` groups open gaps into root-cause **families** and ranks by
`count × (tier+1)`. Run it at the start of each gap-fix iteration and work the top row.
*Precise per-diagnostic-site dedup is DEFERRED* (it needs compile-time instrumentation to
capture the `(kind, julia_loc)` of the failing site — runtime traps carry no site in the
ledger). It isn't blocking: fixing a high-fan-in root auto-closes its whole cluster via
`verify`, which dissolves the flood. Revisit only if near-duplicate gaps keep accreting
*after* the known roots (abstract-Dict-key, median) are closed.

---

## 7. Roadmap — P0 guardrail hardening first, then the frontier

**P0 — harden the harness before trusting it unattended (do these as the first loop
iterations, with the human watching):**
- **G1 — close the value-stub downgrade hole.** Add an env-gated *paranoid* mode
  (e.g. `WT_PARANOID_STUBS=1`) that makes **all** `:value_stub` fatal regardless of
  entry/discovered status; run the loop's verification and CI with it ON. Keep default
  behavior unchanged so the green suite is preserved; the paranoid run reports how many
  discovered value-stubs currently exist (a frontier list in itself).
- **G2 — input rotation.** Seed-rotate `sample_inputs` per verify run (deterministic but
  varied) so off-sample stubs surface. The sample sets + `rtol`/`atol` move into a
  hash-checked artifact `loop_guard.sh` watches.
- **G3 — diagnostic-site dedup + leverage ranking** (§6).

**Then the frontier (KPI = floor raised):**
- **T1.1 — non-perturbing dynamic-dispatch discovery** so `WT_DYNDISPATCH` defaults ON
  (separate collection + merge in `trimcollect.jl`). Unblocks markdown-AST dispatch.
- **T1.2 — union-split `isa`/`π` on `anyref`** (the `Vector{Any}` "validates-then-traps
  illegal cast" class).
- **T2.1 — box-numeric-into-Any-local in phi/loop** (fractals `julia_fractal` first
  validation error).
- Freeze PI/Therapy/WasmMakie seeds as fixtures (§5) as they become reachable.

---

## 8. Launch — the `/loop` invocation

```
/loop Harden WasmTarget per test/fuzz/LOOP.md (read the CURRENT STATE & LESSONS block first),
working on branch wt-soundness-loop-2. P0 guardrails + dynamic dispatch are DONE (v0.3.10) —
don't redo them. Each iteration: run loop_guard preflight; pick the highest-leverage open gap
by `run.jl rank`; FALSE-OPEN-TRIAGE it first (reproduce in a FRESH process + check the
verify/harness env is complete — stdlib imports, js-string — per lesson 1) and if it's a
false-open, fix the verify/harness (not codegen) and move on; otherwise reproduce + confirm it
throws, fix src/codegen/** with strict semantics — NEVER strict=false, a :value_stub, an
unreachable mask, or an edit to the oracle/generator/reproducer logic (§3); recompile, confirm
the repro runs, then verify + the guarding shard + full sharded suite green + a confirming
sweep; run loop_guard.sh and STOP/ask me if it flags a cheat or the suite goes red and you
can't fix it within the iteration; commit with the Co-Authored-By: Claude Opus 4.8 (1M
context) <noreply@anthropic.com> trailer and write root-cause into the gap's ## Analysis.
Remaining tail: Dict-primitive-dispatch (11), Complex/Ryu unreachable, dispatch-ladder,
closure-dep i64/i32, Matrix/hvcat. Don't conflate ledger progress with PI impact (lesson 2).
```
