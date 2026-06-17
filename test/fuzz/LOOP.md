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
/loop Harden WasmTarget per test/fuzz/LOOP.md, working on branch wt-soundness-loop.
Each iteration, follow §4 exactly: run loop_guard preflight; if a §7 P0 task (G1/G2/G3)
is unfinished do the next one, else pick the single highest-leverage open gap by the §6
ranking (diagnostic-site fan-in × tier) and also honor the §2 frontier budget; reproduce
and confirm it throws; fix src/codegen/** with strict semantics — NEVER strict=false, a
:value_stub, an unreachable mask, or an edit to the oracle/generator input lists (§3);
recompile, confirm the repro runs, then verify + the guarding shard + full sharded suite
green + a confirming sweep; run loop_guard.sh on the diff and STOP/ask me if it flags a
cheat or the suite goes red and you can't fix it within the iteration; commit with the
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com> trailer and write
root-cause into the gap's ## Analysis. Then continue. KPI = open gaps → 0 at the current
tier AND capabilities pulled from the next tier in (§1), not just gaps closed.
```
