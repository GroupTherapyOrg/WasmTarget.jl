# The finishing march (PR #122) — one pathway, measured, dart-anchored, adversarially reviewed

This is the single tractable place for the march. Every phase starts from a **measured** number,
follows a **named dart2wasm structure** at the pinned oracle commit (or is explicitly quarantined
as a Julia-only necessity with a differential proof), and ends at a **machine-checked exit**.
Revision 2 incorporates three adversarial reviews (dart fidelity, deletion safety, executability)
and a feasibility spike; every correction they forced is marked **[rev]**.

Oracle: dart-lang/sdk **`898a1e4bbfbc472dc0a9505dc7d2e4c21d6f856e`** (`dev/PARITY_MASTER.md` pin;
local checkout moved to it 2026-09-01). Ground truth: Julia's typed IR under WasmTarget's own
`WasmInterpreter` (`src/codegen/ir.jl:17-35`). Soundness gate: native-vs-wasm differential. Three
oracles; none substitutes for another.

## 0. End state

1. **Zero parallel pathways** — one lowering path per construct, locked.
2. **Zero stale code or bloat** — no dead definitions, no fossil comments, no half-wired campaigns,
   no scattered environment reads **[rev: dart has a debug surface — `TranslatorOptions` — what it
   does not have is fifteen inline `ENV[...]` checks]**.
3. **Nothing dart2wasm doesn't do** — every remaining structure carries a `parity(` anchor to a dart
   file:line at the pinned commit, or lives in the named Julia-only quarantine tier with a
   differential proof.
4. **Strict in every regard** — typed internal APIs, import hygiene enforced, structured
   source-located diagnostics for every unsupported construct (dart's two-tier model), unknown IR
   heads reject loudly.
5. **Fast, precise feedback** — any family verifiable in seconds; a failure names its site. The
   analogue is Rust's borrow checker: the structure makes whole classes of wrong implementations
   impossible to land silently.

## 1. Measured baseline (2026-09-01, `wt-p0-strict-hygiene` @ `7897b316`)

| Dimension | Measurement |
|---|---|
| src | 39,052 lines / 37 files; `compile_call!` 4,583 lines, `compile_invoke!` 2,045, `compile_foreigncall!` 995 |
| Enforcement | 102 zero-locks; ratchets R3 127 · R5 82 · R7 109 · R11 454 · R14 **12 (orphaned — no phase, no dart anchor until now)** · R15 2 · R17 29 |
| Ladder arms **[rev: anchored regexes]** | calls.jl `is_func(func, :` **123** (35 on table-covered ops) · invoke.jl `(?<![.\w])name === :` **54** (61 loose) · statements.jl foreigncall-symbol arms **23** (the loose 59 counted `vt.name === :Memory`-style field checks) |
| Sediment | 839 campaign tags (`march*` 244 + `P2-batch*` 34 = narration, **132 whole-line + 146 inline**; `parity(` 95 keep) · commented-out code: census said 693 but its regex counted prose with parentheses — **must be re-measured with the `Meta.parse` rule below** · 15 scattered `WT_*` env reads (+ `WT_VALIDATE`, a documented gate) · 1,107 `local` decls (load-bearing) |
| Dead definitions **[rev: census bug fixed — negation-prefix `!f!(` and docstring prose]** | **17 codegen leftovers** (`has_loop`, `has_branch_past_first_loop`, `has_short_circuit_patterns`, `_emit_string_data!`-class helpers, `JL_TYPE_KIND_*`, `get_return_type`, `get_param_types`, `is_supported_intrinsic`, `_WASM_LN2`, `_IB`, `SimpleCodeInfo`, `_dv`, `f64bits`, `has_dispatch_table`, `get_string_ref_array_type!`) — list committed inline in R23 · ~42 unused **builder** primitives (kept: dart's `wasm_builder` is a complete instruction library; locks L2/L99/L101 already assume "definition kept, zero callers") · 10 exports with zero references outside src |
| Duplication vs dart | type translation: two ~200-line chains — **the `Union{Nothing,T}` asymmetry is deliberate** (`CG-003d`: locals take `EqRef` because the Nothing edge may produce the base tagged struct / `ref.null`), i.e. dart's `unbox` flag, not drift · coercion funnel: 4 callers vs **98 raw coercion sites outside values.jl** (7 legitimate floor in int128/hash; ~70–90 foldable by fixing `emit_value!`'s expected type — per-site list to be measured) · **strings: 1,291 lines of bespoke builders in invoke.jl; 923 confirmed deletable by spike**, the Julia bodies compile generically and pass differential (output 48 bytes smaller) · `compile.jl` `generate_intrinsic_body` re-derives concat/eq a third time · boxing / value emission / dispatch at parity |
| Downstream surface | 21 of 55 exports used; `WasmValType` used 60+ times **unexported**; 7 builder internals reached by Therapy; all 6 `compile_multi` kwargs live |
| Inner loop | `using WasmTarget` 0.43 s · first `compile` 0.17 s · ratchet 2.9 s · smoke 14.4 s · shard 0 5.4 min local / 23 min CI · full 18–46 min · **no per-phase filter, no probe lane** (both built in Phase 1; costs measured after) |
| Canary frontier | SimpleDiffEq: `saveat`/interpolation/`sol.u`/callbacks compile (differential owed); adaptive blocked by `apply_type(Pairs,…)` · OrdinaryDiffEq: blocked at construction (overlay in the SimpleDiffEq ext) · MOI `Model{Float64}()`: **crash** in `struct_set!` (calls.jl:3663-3666, value not cast to the field's concrete type) · negatives: 7/10 classified, `readline(stdin)`/`eval` **crash** |

## 2. Oracle anchors (dart2wasm @ `898a1e4b`, `pkg/dart2wasm/lib/`)

| Structure | dart | What WT copies |
|---|---|---|
| Numeric operator table | `_binaryOperatorMap` intrinsics.dart:436-472 — diagonal only, 22 entries, keyed on canonical wasm value types after narrowing | `INTRINSIC_BINOPS` stays diagonal; never grows width keys |
| Unary / conversion tables | `_unaryOperatorMap` :474-503, `_inlineUnaryOperatorMap` :505-576, `_unaryResultMap` :578-583 | `INTRINSIC_UNOPS` + result map |
| Low-level numeric switch | WasmI32/F64 member switch :710-929 incl. copysign/min/max :902-925 | float `_fast`/copysign/min/max below the table |
| Entry funnels | nullable-return fall-through: :607, :685 (binary lookup :995, unary :1007), :1018 | every registry entry returns `nothing` = generic lowering |
| Call primitives | exactly two: `call()` code_generator.dart:733, `_virtualCall` :2028 | already mirrored |
| Identity registries | `MemberIntrinsic`/`StaticIntrinsic` keyed on **(library, class, name)** resolved through `KernelNodes`, `_lookup` :75-100/:401-428; unknown ⇒ `throw 'Unhandled…'` | **[rev]** invoke registry keyed on **`Method` identity** (already in hand at invoke.jl:2220), never bare `Symbol`; foreigncall registry keyed on the C symbol (that *is* the identity, like dart's import names) |
| Static call map | `FunctionCollector._functions: Map<Reference, w.BaseFunction>` functions.dart:26; `staticParamInfo` translator.dart:196 | **[rev]** `FunctionRegistry`'s `func_ref`-keyed core is dart-shaped — anchored, not quarantined; only `get_function(registry, name::String)` is Julia-only |
| Type translation | `translateType` translator.dart:1044 → `translateStorageType(…, unbox)` :1067; nullability once | one `get_concrete_wasm_type(T, mod, registry; for_local)` |
| Coercion | `convertType` translator.dart:1597 | `convert_type!` + `coerce_stack_top!`, adopted everywhere |
| Constants **[rev: missed]** | `constants.dart` `ConstantInfo` canonicalization (`Map<Constant, ConstantInfo>`) | the anchor for R14 `fresh_constant_structs` |
| Debug surface **[rev: was wrongly "absent"]** | `TranslatorOptions` translator.dart:48-89 (`printKernel`, `printWasm`, `verbose`, `watchPoints`), wired :520; `compiler_options.dart:53-55` dumps | one typed options struct threaded from the entry point |
| Diagnostics | internal `throw` vs structured `DiagnosticReporter` with location (target.dart:719-751; `wasm_library_checks.dart` is a **CFE-time pragma/misuse checker**, not a classifier) | `StackImbalanceError` is internal-tier; every user-facing unsupported construct is `record_unsupported!` |
| Host boundary **[rev: missed a phase]** | pragma funnel functions.dart:90-189; **`translateExternalType`** translator.dart:1239-1268 restricting what crosses | Phase 7 |
| Strings **[rev: from the spike]** | **no string intrinsics** — corelib bodies through the one code generator | delete the bespoke builders; compile the Julia bodies |
| Absent in dart | checked overflow, Int128, first-class narrow ints in arithmetic, a name-string static lookup | the quarantine tier (`parity(quarantine: …)` + differential proof) |

## 3. Julia ground truth (typed IR under `WasmInterpreter`)

Intrinsics arrive as `GlobalRef`s (module varies), never `:invoke`. Base does not normalize narrow
types; mixed-width promotion inserts explicit `sext_int`/`zext_int`. `div`/`rem` → value-returning
`checked_sdiv_int`; `checked_add` → tuple-returning `checked_sadd_int` + branch. `Int128` is an
opaque primitive. Node kinds are stable 1.12 ↔ 1.13; drift is in inferred type shapes. `:splatnew`
and `:copyast` have zero handling. 152 overlays; `inline_cost_threshold=500`; concrete-eval off
except a type-level allowlist. `str_setchar!` is a native no-op (strings are immutable), so the
native oracle cannot judge `uppercase`/`lowercase` today — Phase 5 fixes that at the source.

## 4. The pathway

Repo law: metricized campaigns finish, unmetricized ones stall. Instrument → delete → unify → lock →
canaries. Each phase: dart anchor, verification lane, agent tier, exit.

### Phase 1 — Instrument and build the inner loop **[rev: everything here measured after it exists]**

1. Ratchets in `test/parity_ratchet.jl`, all with **anchored** regexes: `R19_call_is_func_arms`
   (123) · `R20_invoke_name_arms` — `(?<![.\w])name === :\w+` (54) · `R21_foreigncall_arms` — rooted
   on the real dispatch variable `_fc_sym`/`fname` inside `compile_foreigncall!` (23; rebaselined by
   reading the ladder, not grepping a bare word) · `R22_table_covered_ladder_arms` — keys parsed
   from **every `const INTRINSIC_*` dict** in `intrinsics_table.jl` (35 today; catches the unop
   table the moment it exists) · `R23_dead_codegen_defs` — the 17 names **inline in the thunk** ·
   `R24_scattered_env_reads` — `ENV\[\s*"WT_` outside the options struct (15) ·
   `R26_campaign_narration` (278) and `R25_commented_out_code` (re-measured) via a **second counting
   primitive**, a comment-aware line scanner (`count_sites` skips comment lines by design, which is
   also the gaming hole where an arm is commented out to satisfy R19) · `R27_coercion_bypass` — the
   explicit per-site regex, measured before the brief (superset 98) · `R14` re-homed to Phase 4.4.
   `R28` is not a ratchet: it becomes lock **L105** (no second type-translation chain definition)
   the moment Phase 4.1 lands.
2. `function_body_lines(src, "function name(")` — a depth-tracking helper (no lock counts a
   function's span today) for the Phase 5 funnel locks.
3. `WT_PHASE=<substring>`: two-touch diff — the auto-spawn guard at runtests.jl:23 gains
   `&& get(ENV,"WT_PHASE","") == ""`; `_run_phases` (~:456-464) selects by
   `occursin(lowercase(ENV["WT_PHASE"]), lowercase(name))` instead of `_phase_owner`.
4. `test/probe_bytes.jl`: sha256 of a **verbatim** probe corpus — one call per `INTRINSIC_*` op
   family incl. the six dead float arms, one invoke and one foreigncall per registry key to be
   migrated (`println`, `kwerr`, `throw_inexacterror`, `memoryrefnew`, `jl_string_ptr`), three
   `Union{Nothing,T}` local/phi/field cases, the string ops, plus the STRESS-1000/1001/1004 slices;
   `WT_PROBE_RECORD=1` re-baselines.
5. Exits are measured **after** 3–4 exist (no cost is quoted before it is timed).

Tier: haiku for thunks and the two-touch diff (exact lines given); orchestrator negative-tests every
thunk and writes the probe corpus.

### Phase 1 — result (2026-09-02)

Done and committed: nine ratchets (`f05045a1`), `WT_PHASE` (`62c42fd0`; measured 24–48 s per
family, ~20 s of it harness setup), the probe lane (`2c4a0cb8`; 123 probes, 26–29 s,
deterministic). Three of the nine delivered thunks were vacuous until reviewed (a missing multiline
flag read 17 dead names as 0; a narrow regex read 15 env reads as 1; the span helper exited at 675
of 4,583 lines and had lowered its own sanity bar) — every thunk is now negative-tested before its
number is trusted, and R19/R22 became file-agnostic after the "move the arm to another file" dodge
was demonstrated.

### Phase 2 — result (2026-09-02)

| Step | Outcome | Lock |
|---|---|---|
| 2a dead definitions | 15 deleted, 141 lines (`a14d94ca`); two census entries were JavaScript inside `bridge.jl`'s template and stayed | **L106** |
| 2b test-only names | `emit_phi_local_set!` deleted (superseded, per the phi-edge postmortem); five builder primitives, three real APIs, and six false positives kept (`aa65cccf`) | — |
| 2c debug surface | 17 scattered reads → `src/codegen/options.jl` `CompilerOptions` (dart `TranslatorOptions`); `WT_CUR_FN` deleted; `WasmValidationError` carries the rejected bytes (`3fb4e035`) | **L107** |
| 2d commented-out code | **retired**: every parser-flagged range was pseudo-code annotation of the emitted wasm; R25 removed | — |
| 2e narration tags | 278 → 0 (`378e7ee7`, `0afbf979`) | **L108** |
| patch markers | 454 → 0 (`c5d2aa4b`, `3f6b49f4`, `ff57901d`) | **L109** |
| anchor audit (added) | 93 of 95 `parity(` anchors were phase labels; now 86 dart citations at the pinned commit + 4 explicit quarantines, 20 spot-checked, two stale 2024 line ranges and one wrong citation corrected (`2003973c`) | **L110** |
| 2f exports | 10 undocumented zero-reference exports de-exported, kept as internals (`aa65cccf`) | — |

Every commit was byte-identical to the compiled output (probe lane 0 changed). Locks 102 → 107.

### Phase 2 — plan as executed (kept for the record)

| Step | Start | Action **[rev]** | Exit |
|---|---|---|---|
| 2a dead codegen defs | 17 | delete — but each name is **hand-verified first** (grep incl. `!name(`, docstrings excluded, downstream, and the lock required-string lists) | R23 → 0 → lock |
| 2b test-only names | 15 | classify, don't bulk-delete: `emit_phi_local_set!` is dead (read `test/fuzz/FINDINGS.md:520-530` + the `a517b4c8372d` postmortem first); `catch_all_clause`/`ref_i31!`/`emit_raw!`/`Limits`/`toggle` are **kept builder primitives** (L2/L99/L101 assume def-kept); `serialize/deserialize_ir_entries`, `Counter`/`build`/`increment`/`walk` are classified by reading their test use | census = 0 |
| 2c env toggles | 15 scattered reads | **consolidate, not delete**: one typed `CompilerOptions` (dart `TranslatorOptions`) threaded from `compile`/`compile_multi`; `WT_DUMP_INVALID` is **root-fixed first** — `WasmValidationError` carries the rejected module bytes (dart always writes the module) — then its toggle goes | R24 → 0 → lock |
| 2d commented-out code | re-measured | mechanical rule: delete a contiguous `#` block **only if every line, stripped of `#`, `Meta.parse`s as a complete Julia expression**; prose never does, so overlay narration in interpreter.jl survives | R25 → 0 → lock |
| 2e narration | 278 tags | three shapes only: whole-line tag comment → delete; tag inside a docstring → delete the parenthetical, keep the docstring; inline trailing tag → delete the comment, never the code. **Before any strip, grep every lock closure for the tag text** (L60 embeds `PURE-9032` as a forbidden string). **The `CG-003d` comment in `julia_to_wasm_type_concrete` is protected until Phase 4.1.** Anything not matching a shape → stop, sonnet reviews | R26 → 0 → lock |
| 2f exports | 10 zero-reference | de-export the undocumented; documented API (`compile_with_sourcemap`, cache API, `compile_with_base`, `compile_from_codeinfo`) **stays** — its removal is a release decision, not a census outcome | ExplicitImports + downstream CI green |

Tier: haiku per file with the probe lane; sonnet for 2c. Orchestrator reviews every diff.

### Phase 3 — Numeric registry (R22: 35 → 0)

1. Table completeness: `gt_float`/`ge_float`; delete the six dead float arms (probe-identical).
2. `INTRINSIC_UNOPS` + result map — dart's second map (`not_int`, `neg_int` ≤64-bit, `ctlz/cttz/
   ctpop_int`, `neg/abs_float`, `sqrt_llvm`, `floor/ceil/trunc/rint_llvm`, `sext/zext/trunc_int`,
   the six int↔float conversions, `bitcast`); the arm count is measured when the key list is
   enumerated, not assumed. R22 walks this dict from its first commit.
3. **[rev: quarantine, not dart-verbatim]** the narrow-width normalization used by comparisons,
   div/rem and shift counts is Julia-only semantics (dart's `int` is uniformly i64;
   `readIntArray`'s extension is array-storage-specific) — one function in the quarantine tier with
   a differential proof; **sonnet/orchestrator work, never a haiku brief**.
4. `src/codegen/julia_numeric_tier.jl` (`parity(quarantine: no dart equivalent)`): Int128 (14 arms →
   one op-keyed registry), checked overflow (6 arms, `Tuple{T,Bool}` contract), 3-arg
   (`muladd`/`fma`), mixed-width shifts, `bswap`; nullable-return fall-through.
5. `min/max/copysign_float` `_fast` aliases; arms deleted.
6. `compile_call!`'s binary-op section → thin funnel (table → unop table → quarantine → generic).

Exit: R22 = 0 → lock `L104` (every `INTRINSIC_*` key ⇒ zero unannotated `is_func(func, :key)`).
Verify: probe for 1/2/5/6; differential for 3/4 (smoke `numerics`, `WT_PHASE` on Phases 59/60/72,
STRESS-1000/1001).

### Phase 4 — Duplication collapse

1. **[rev: preserve, don't "fix"]** fold `julia_to_wasm_type_concrete` into
   `get_concrete_wasm_type(T, mod, registry; for_local::Bool)` where `for_local=true` keeps `EqRef`
   for `Union{Nothing,T}` locals exactly as `CG-003d` documents (dart's `unbox` flag). Gate: the
   producer audit (every `local.set` of a `Union{Nothing,T}` value) **and four smoke `phi_union`
   cases added first** — two-edge Nothing/T phi; ≥3-predecessor phi; a value passing through an
   `Any`-typed intermediate before the phi; a `Union{Nothing,T}` field read stored straight into a
   local. Also fold `resolve_union_type` into `_resolve_multivariant_union`. Exit: **L105** — no
   second chain definition exists (a thin wrapper that becomes permanent is what L105 forbids).
2. Coercion funnel adoption at the measured per-site list; byte-identical. R27 → 0 → lock.
3. `FunctionRegistry`: anchor the `func_ref` core to `FunctionCollector._functions`; retire the
   name-string lookup path (same fix as Phase 5's keys).
4. **[rev: R14 gets a home]** constants: anchor `fresh_constant_structs` to `constants.dart`'s
   canonicalization; R14 12 → 0 → lock.

Tier: sonnet (1, 3, 4); haiku (2).

### Phase 5 — Strings first, then registries (R20: 54 → 0, R21: 23 → 0) **[rev: from the spike]**

1. **Delete the seven bespoke string builders** (`find/contains/startswith/endswith/uppercase/
   lowercase/trim`, 923 lines + wrappers + their dispatch arms at invoke.jl:1965-2076/2806-2849):
   generic codegen compiles the `stringops.jl` bodies correctly today (differential green, unicode
   and empty-string cases, output 48 bytes smaller). First make `str_uppercase`/`str_lowercase`
   natively correct (build the result via a byte vector, not the no-op `str_setchar!`) so the Julia
   compiler is a real oracle for them. Then delete `compile.jl`'s `generate_intrinsic_body`
   concat/eq re-derivations and the 2-arg concat duplicate. Spike `hash/repeat/lpad/rpad` (368
   lines) before deciding them. Verify: differential (this is not byte-identical) — smoke
   `strings_classed` + `WT_PHASE` on Phases 15/71/73 + STRESS-1004.
2. Remaining invoke arms → `INVOKE_INTRINSICS` keyed on **`Method` identity** (invoke.jl:2220 has
   it); unknown ⇒ loud. `compile_invoke!` → funnel: registry → devirtualized direct call → generic.
3. Foreigncall arms (23) → `FOREIGN_LOWERINGS` keyed on the C symbol; `compile_foreigncall!` →
   funnel; unknown ⇒ `record_unsupported!`. Registry population and arm deletion land in the
   **same commit** (R20/R21 make an abandoned migration visible every run).
4. Funnel locks via `function_body_lines` (the visitor shape; registry bodies may be any size).

Tier: sonnet (1, funnel + registry skeletons); haiku for moving bodies.

### Phase 6 — Two-tier diagnostics and correct-or-loud completion

1. Root-fix `setfield!`: cast the value to the field's concrete type when it arrives as `AnyRef`
   (calls.jl:3663-3666); differential test.
2. `readline(stdin)` / `eval`: classify at the boundary (`record_unsupported!`), never an internal
   `StackImbalanceError`.
3. `test/capability_negative_controls.jl` — a **testset** (behavior is not a ratchet's business):
   all 10 controls assert a classified diagnostic.
4. `:splatnew` / `:copyast`: loud reject or a lowering with a test.
5. **[rev: re-anchored]** the capability manifest is the **import section** — derived from the
   existing import stubs and foreigncall lowerings (dart's import funnel, functions.dart:90-189) —
   not a new visitor. Diagnostics report the call chain through `WasmDiagnostic`'s location.

### Phase 7 — Public surface and the host boundary

1. Export `WasmValType` and the builder API Therapy reaches for (`add_type`, `add_table`,
   `add_elem_segment`, `FuncType`, `FuncRef`, `register_vector_type!`, `encode_leb128_unsigned`);
   document `Bridge` as public.
2. **[rev: missed]** `translate_external_type` — the host-boundary type translator (what may cross:
   numeric primitives, extern/func refs, typed arrays), mirroring translator.dart:1239-1268, used by
   the import-stub path and any future sidecar ABI; metric: host signatures typed through it.

Exit: downstream CI green; ExplicitImports green.

### Phase 8 — Capability canaries (roadmap item 1)

1. Move the `ODEProblem`/`isinplace` construction overlay to a **SciMLBase-keyed** ext.
2. Adaptive `SimpleATsit5`: one `_is_typelevel_foldable` entry for `apply_type(Pairs, …)`.
3. Differential-verify `saveat` / interpolation / callbacks.
4. MOI construction after 6.1; the next edge (`jl_clock_now`) is recorded.
   **[rev: trip-wire shape]** every recorded edge is `@test_throws WasmCompileError` **plus**
   `@test occursin("<exact blocker>", sprint(showerror, err))` — if the edge moves, the test goes
   red and the record is updated deliberately.


### Phases 3–8 — results (2026-09-02)

| Phase | Outcome | Locks / ratchets |
|---|---|---|
| 3 numeric registry | `INTRINSIC_BINOPS` diagonal completed (`e1483400`), `INTRINSIC_UNOPS` + result map (`416090ac` — which also fixed the Float32 `copysign` row the arm deletion had exposed: "dead below the table" needs a row for every width, and the corpus now fingerprints every op×width), integer negation as dart does it (`dd4a6085`), the Julia-only tier `julia_numeric_tier.jl` — Int128 registry, checked overflow, shifts, fma, bswap/flipsign (`883203f0`, `20a82c9e`), the callback-shaped table carrying the div/rem guard (`1cb2ddb1`), one narrow-width normaliser and the conversions registry (`64df7f97`) | R22 35 → **0 → L104** (per-symbol exclusivity: a table key can never have a ladder arm anywhere in codegen) |
| 4 duplication | one Julia-type → wasm-type chain, dart `translateStorageType` with an unbox flag (`79d74456`); the probe lane made a pure function of codegen — `nameof` gensyms had leaked into export names (`70afbf62`); `FunctionRegistry` anchored to `FunctionCollector`, constants to `constants.dart` with one fallback tail (`23f61196`); Int128 and the Vector size tuple intern through `ensure_constant_global!` (`4bf09c1b`) | R5 82 → 81, R14 12 → **10** |
| 5 strings, then registries | the seven bespoke string builders deleted — the one code generator compiles the `stringops.jl` bodies (`898c373b`); Core/Base builtins through an identity-keyed `BUILTIN_LOWERINGS` (`86e4f70c`); invoke intrinsics through the Method-keyed `INVOKE_INTRINSICS` — the spike's verdict was that hash/repeat/lpad/rpad need no intrinsic at all (`f1baebd2`); foreigncalls through the symbol-keyed `FOREIGN_LOWERINGS`, every unknown IR head rejecting loudly (`ba4b66d4`) | R19 123 → **31**, R20 54 → **32** (residue in flight), R21 25 → **5** (in flight), R3 127 → 96, R7 109 → 62, R27 94 → 55; **L113** (registry consulted before any name-keyed arm — the ConsultChain model's finding) |
| 6 diagnostics | `setfield!` of a GlobalRef-aliased `nothing` into a concrete-ref field root-fixed (the MOI crash was a coercion-funnel gap, not the hypothesised layout); `eval`/`readline` classify at the boundary; ten negative controls (`b3e101a7`) | `test/capability_negative_controls.jl` |
| 7 host boundary | `translate_external_type` (dart `translateExternalType`, total, widening to anyref) and the import-stub signature check in the closed-world plan (`4f6666a5`); the framework-host builder surface declared `public` (`bc37f374`) | `test/host_boundary_types.jl` |
| 8 canaries | the capability trip-wires; the SciML surface stayed on the existing `WasmTargetSimpleDiffEqExt` (SimpleDiffEq + SciMLBase + DiffEqBase keyed) — measured as sufficient, so no new ext was cut | — |

Found and root-fixed along the way (each with its own narrative in the log): class ids depended
on `Dict` hash order (`9bc3d859`, **L112**); a Dict constant serialised uninitialised host memory
— heap pointers — for its unoccupied slots, and `:new(Dict)` ignored its arguments so a copied
constant lost its entries on insert (`4bf09c1b`); the host's world counter was baked into
binaries (`4a823f9f`, one `WASM_WORLD_AGE`); the stackifier declared everything between an
`@inbounds` jump and its target dead, which dropped the live loop of `reduce(max, 1:n)` on Julia
1.13 (`b9f4d229`, dead = unreachable in the folded CFG, **L89 re-pinned**); CI had never run the
smoke lane, which is why that miscompile was invisible — it runs it now.

### Phase 9 — Close

Promote every ratchet at 0 to a lock; refresh `dev/PARITY_MASTER.md`'s audit stamp and the changed
rows of `dev/CERTIFICATION.md`.

### Phase 10 — The first builds, brought into the march (2026-09-02 scope expansion)

The three roadmap items the pathway had deferred are in: item 4 (normalized frontend boundary,
`src/frontend/nir.jl`, converted consumer by consumer under `R29_raw_codeinfo_reads`), item 3 (the
native sidecar prototype — a linear-memory `.wat` module linked by the host, dart's `ffi`.`memory`
channel translator.dart:213-224, with the GC-array transfer as a quarantined scalar loop because dart
has no bulk primitive either), and item 5 (UnifiedIR — measured unavailable on every installed Julia
and upstream still a draft, JuliaLang/julia#62334; the deliverable is `test/shadow_compile.jl`, a
two-frontend recorder/comparator whose `:unified` leg throws `UnifiedIRUnavailableError` rather than
silently no-op'ing). Designs in the scratchpad `p10/DESIGN.md` were adversarially reviewed before
execution.

### Phase 11 — The formal layer (adopted 2026-09-02, from Keno's recommendation)

JuliaLang/julia#61826 ships `SchedulerWake.tla`, a TLA+ model of the scheduler wake handshake that
abstracts weak memory and lets TLC exhaust every interleaving — "sufficient to check the algorithmic
claim". WasmTarget adopts the pattern and gates on it. `dev/formal/<Name>.tla` models the ACTUAL
Julia algorithm (read from source, `formal(src/…)` anchor in the header and a one-line
`# formal(dev/formal/<Name>.tla): <claim>` at the top of the modeled function), `MC<Name>.tla/.cfg`
is a small instance with `TypeOK` plus the claim invariants and a deadlock check, and
`MC<Name>Broken.cfg` flags a deliberately wrong variant (the realistic bug class) that TLC MUST
reject — a model with no counterexample-producing variant is vacuous, the same rule the locks live
by. `dev/formal/run_tlc.sh` runs every instance and fails if a Broken one passes; `formal.yml` runs
it on every PR.

Models in the march: `Stackifier` (well-scoped `br` targets, balanced labels, every edge realized
once, the reject path never emits), `Diagnostics` (the two-tier automaton: no silent value, a trap
needs a proof, an internal error is unreachable from the unsupported tier), `ClosedWorld` (fixpoint
termination and completeness under any discovery order; failure is loud), `ClassIdDispatch` (isa ⇔
range containment, nested ranges, selector slot uniqueness, the cascade rejects ties, and
determinism — the open unsorted-`structs` iteration finding), `ConsultChain` (every call key reaches
exactly one funnel or the loud reject; a declining funnel emits nothing — L104 lifted from symbols to
keys), `Sidecar` (the ownership protocol: per-call scratch, no stale reads across calls, no GC
reference in linear memory, aliasing handled).

The rule from here on — for everything in this push and after: a change to a modeled algorithm
updates the model FIRST and lands with TLC green; a new protocol or algorithm is modeled spec-first
and the code is checked against the model, never the reverse; a TLC counterexample against the real
algorithm is a finding to reproduce in Julia, never a reason to weaken the invariant; every landing
answers "which model does this change, or which new model does it need?" (pure data or test-only
changes say so explicitly); commit messages for algorithmic fixes narrate the protocol the way
Keno's futex commit does — the exact shape that breaks, the invariant, and why the fix restores it.

## 5. Verification contract

| Lane | Command | Cost | Use |
|---|---|---|---|
| structure | `julia --project=. test/parity_ratchet.jl` | 3 s | every edit |
| behavior (curated) | `julia --project=. test/smoke.jl [group]` | 14 s | every edit |
| byte identity | `julia --project=. test/probe_bytes.jl` | 26–29 s | every pure restructuring |
| family | `WT_PHASE=<name> julia --project=. test/runtests.jl` | 24–48 s | the family touched |
| behavioral locks | `test/*.jl` testsets (negative controls, canary trip-wires) | per file | never in the ratchet |
| formal | `bash dev/formal/run_tlc.sh` | seconds–minutes | every change to a modeled algorithm; every commit that touches `dev/formal` |
| commit | `WT_SHARD=0,4 …` + the touched family's shard | 5–8 min | before each commit |
| PR | CI matrix | 18–46 min | the authoritative full gate |

Rules: pure restructuring must be byte-identical; semantic unification must be differential with
its cases added to smoke first; every new lock is negative-tested before it counts; a ratchet never
loosens; registry population and arm deletion land in the same commit.

## 6. Agent protocol

One march branch. Cheap agents get mechanical briefs with exact lines and the verification commands;
no tree-modifying git commands; the orchestrator reviews every diff and commits each verified item
immediately; every enforcement thunk is negative-tested; hygiene checks run with **all** extension
parents loaded; an oddly-shaped construct is assumed load-bearing until its scope is read (the
`optimize` kwarg shadowing incident); a census is never acted on before an adversarial pass
(the `!f!(` negation-prefix bug would have deleted live phi-merge code).

Learned in Phase 2: an agent's completion claim is never trusted — the tree is measured before a
commit (files were reported "processed" with 40 tags left, and "verified" edits that did not
exist); verified work commits immediately, before the next agent starts (finished edits were wiped
twice by another agent's `git checkout` despite the ban); the scanner decides and the agent
executes, with "stop and report" for anything off-shape — and the stops are honored (both 2d stops
were correct); parallel agents get disjoint file sets and lists regenerated from the current tree
at every hand-off; a commit gates on a negative test's exit code, not on the command sequence
completing (L109 was once committed as "negative-tested" when it had not registered at all).
