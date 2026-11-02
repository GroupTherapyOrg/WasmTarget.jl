# The anti-drift audit log

The locks check what they measure; drift hides in what none of them counts. So a full audit
against `dev/CHARTER.md` runs beside the work, at every session start and at most every 5
commits, never holding a landing (dev/LEDGER.md D21), and records it here. L148 fails when the
entries do not chain (an entry's range must start at the commit the entry before it was
audited through, and every audited-through commit must be an ancestor of HEAD) or when an
entry leaves out an area or a `Resolution:`; it prints how many commits the last entry is
behind HEAD (merges not counted), a report, never a failure.

The method:

1. Re-read `dev/CHARTER.md`, `AGENTS.md` and `dev/MARCH.md` in full.
2. Audit every change since the last entry, `git diff <audited through>..HEAD`, in four
   areas, each by a read-only auditor (no edits, no Julia runs):
   - **builder**: `src/builder/`: wasm_builder's structure, and a builder that knows
     nothing of Julia;
   - **collection and planning**: `trimcollect.jl`, `compile.jl`, the frontend: the closed
     world as Julia's compiler builds it;
   - **emission and diagnostics**: the rest of `src/codegen/`: dart's lowering, correct or
     loud;
   - **enforcement and prose**: `test/`, `dev/`, the docs: locks that guarantee behavior,
     charter edits that only strengthen, prose that is true.
3. Check each changed definition against every clause: its dart anchor by what the dart
   code does at the pinned commit (not only by the symbol's name); a quarantine's Julia
   necessity is real; no layering leak; no process-global state; no second path; correct
   or loud; a new lock negative-tested.
4. Fix what the audited range broke (a wrong answer, a trap, an invalid module, an internal
   error, one-line prose) before new work, at about 150 src lines at most and with no new
   mechanism; every other finding joins its MARCH row. Record the entry: the range, one
   `Area:` paragraph per area with its findings, and a `Resolution:` for each finding (the
   commit that fixed it, or the MARCH item and ratchet that now carry it).

### History: the plan the rebuild superseded (archived 2026-10-21 when dev/MARCH.md restarted at Phase 1)

Phase 14 converted WT1 in place; the rebuild (WT2-DESIGN §E, PR #128) replaced it. Its rows, in short (full
text: `git log -p -- dev/MARCH.md`, the commit that opened Phase 1):
- 14.0 (C10 C0): the loop kept in minutes and proven by `dev/land.sh land`; carried as the rebuild's loop.
- 14.1 (C4 C5 C6 C7): strict by construction on WT1, first its eleven silent catch-alls; WT2 starts at 0 stopgaps.
- 14.2 (C1 C9): one source of truth on WT1 (R5's 58 re-guesses → the typed value channel); WT2 carries the type on every value.
- 14.2b (C1 C2 C9): the nuke inventory of WT1's parallel paths; WT2 has none to nuke, WT1 leaves whole by legacy/'s rule.
- 14.3 (C2 C3 C5 C6 C10): the audit-fix queues (120x, A22E9, 120x-2/3); their cases join the corpus as requirements.
- 14.4 (all): clauses close as consequences with `Closes: C<n>` matrices; unchanged under the rebuild.
- 14.5 (C0 C10): decisions Dale held (C10's sentence, the final gate); carried to the charter proposals.

Phase 13 closed the charter on WT1; the rebuild's charter change (Planned text re-pointed to Phase 1's rows)
archived it. Its rows, in short (full text: `git log -p -- dev/MARCH.md`):
- 13.1, 13.10, 13.14 (C3 C5 C6): WT1's silent-wrong-value suspects, capability gaps and run-time type objects; their
  programs are corpus requirements for phases D and E.
- 13.3, 13.4, 13.5, 13.7 (C1 C2 C3 C5 C9): WT1's registry witnesses, facts computed twice, floor ratchets and
  inventions; WT2 is generated from dart and has none of them to retire.
- 13.17 (all): the audits' open findings, grouped; each stays in its audit entry below, the rebuild's requirements.
- 13.18, 13.24–13.27 (C10): WT1's ratchet-stage timing rows; the rebuild's ratchet holds the process locks only.
- 13.20 (C0 C4–C8): strict by construction on WT1; its C0 part is Phase 1's row 1.S, its C4–C8 part rows A3–A9.
- 13.11, 13.16: the merge and the downstream adoption, carried as Phase 1's rows 1.M and 1.P.

## 2026-09-29 — audited through 7acc21c9 (4fc785d2~1..7acc21c9: batches 51–59)

The first audit, done because none had been: 45 findings. Two were read as silent wrong
values; measured (batch 61), neither was: E1 raised a codegen bug where a rejection belongs,
and E7 did not reproduce. The fix batches run in the order below, before any new work.

Area: builder — (B1) `StatementTrace` and `WasmModule.trace` put Julia's CodeInfo and
MethodInstance in the builder; dart's ModuleBuilder holds wasm parts only. (B2) a block's type
has two sources (a positional block type and `inputs`/`results`): `try_table!(b, cs, I32)` is
tracked void and encoded with a result; dart's `_beginBlock` derives the encoding from the
label. (B3) branch typing is checked four times (`validate_br!`, `validate_br_if!`,
`validate_branch_types!`, `try_table!`); dart has one `_verifyBranchTypes`. (B4)
`validate_pop_any!`'s quarantine is false: `global_set!`, `ref_is_null!`, `ref_as_non_null!`,
the `call_ref` callee, `local_set!` of an unknown index and five validator arms pop untyped.
(B5) anchors naming other code: `_local_type` invents AnyRef; `_true_field_type`,
`_true_elem_type`, `_true_call_sig` fall back to the claimed type; `write_valtype!(::RefType)`
never writes the one-byte shorthand; `add_global_ref!` takes raw initializer bytes
(closures.jl writes them by hand, unvalidated); `julia_to_wasm_type` is a translator in the
builder; `builder_diagnose` is dead; `reset_validator!`'s quarantine is false. (B6) 15 opcode
constants without a use, unreachable CATCH_REF/CATCH_ALL_REF branches, `add_export!`'s
docstring, campaign narration. (B7) the sourceMappingURL section writes its own framing;
`source_map_url` is set after construction (an `existing_module` records a partial map);
sources are paths, not URIs; `append_builder!` carries a fragment's last mapping. (adjacent)
`diagnostics.jl:313` turns an unknown line 0 into line 1.

Area: collection and planning — (P2) `_ENROLLMENT_REASONS`, a new process-global Ref, and an
invented fallback reason for every base-collected function (entries were never recorded);
the same trim quarantine on `_DYNAMIC_ROOT_MIS`, `_ENROLLED_CALLABLE_TYPES`,
`_TRIM_DISPATCH_CANDIDATES`, `_TRIM_INVOKE_ONLY`, which explains the collector, not why its
state is process-global. (P3) the invoke_in_world edge is worked out in three places with
different operand types; a non-unique target becomes neither an edge nor a dynamic site; no
exact-type check. (P4) MCClosedWorld never enables Prune; HiddenEdges cannot express the
collector and pruner disagreeing; the fma roots are not modeled. (P5) the catch-alls re-infer
on an interrupt or out-of-memory; internal ArgumentErrors pass unlocated. (P6)
`throw_located_collection_failure` cites CFECrashError for WT's own re-inference;
`add_codegen_export!` cites ExportsBuilder.export but renames silently. (P7) a source-mapped
build is a second module shape, and the extra entry points drifted (no diagnostics_sink).
(S6) the plan compile normalizes 2-tuples it never receives; `optimize_ir=false` errors for
every planned function. (side) a third loop-bounds definition (context.jl:1243);
`count_ssa_uses!`, a second operand table missing Upsilon and PhiC; statements.jl:902 scans
the whole body.

Area: emission and diagnostics — (E1) SILENT WRONG VALUE: `_emit_getfield_runtime_name!`
reads a field by Julia's field order from a projected layout: `getfield(::DataType, :hash)`
reads `dfs_high`, `:instance` reads `abstract`; TypeName too; Module always throws. (E7)
`_lower_invoke_in_world!` re-infers the return type, and for a callee returning `Nothing` can
box an earlier statement's value (`isempty(b.v.stack)` on a seeded fragment). (E8) the vararg
dynamic-getfield arm emits a Symbol operand as I64 (the trap batch 53 removed from the tuple
arm). (H1 = P1 = E2) a rethrow records a fresh stack, not the caught one (dart `visitRethrow`
rethrows `stackTraceLocal`; Julia keeps the backtrace); a throw records its stack only in a
source-mapped build (dart: `errorThrowWithCurrentStackTrace` always). (E3) L142 incomplete:
`Union{Nothing,Matrix}` reaches `register_vector_type!` with no rank check. (E4) which types
have a dedicated layout is decided twice. (E5) L143's one rule is three (calls.jl:293,
statements.jl:1804, :1861). (E6) `_is_direct_struct_constructor` cites a dart mechanism that
never substitutes `struct.new`. (E9) unmapped prologue and trailing unreachables; a statement
with no location borrows the previous one's; `map_to_statement!` runs outside the located try.
(E10) the titlecase overlay's reason may be stale. (E11) a false docstring.

Area: enforcement and prose — (H2) smoke and the differential files run only the
source-mapped shape; the plain build is never run. (H3) L138's tolerance covers all 40
SimpleDiffEq cases, and `_sde_step_calls_muladd` passes on any method of the file. (M4) C6
and C10 read CLOSED while MARCH 13.1, 13.14, 13.15 are open; C10's "one verdict in minutes"
has no check. (M5) six commits added citations to the charter without recorded direction
(each only strengthens; L125 requires a citation for every new check). (M6) locks that pin
text: L101 counts deleted names while `SymbolicTryCatch(CATCH_ALL)` still validates; L143
forbids one spelling; L145 exempts all of generate.jl; L65 was loosened (misses `;` and line
start); L12 is vacuous and names the retired R2; L144, L147 pin comment text. (M7 = P8)
tracing forces locals and the locator never checks that the traced build still answers
wrong; an unroutable closure calling a routable callee reports a spurious parting. (L8)
MARCH 13.15 holds finished work and results; HISTORY has no entries for e226aab7..7acc21c9.
(L9, L10) README: `discovery=:legacy`, Statistics "bit-exact", removed mechanisms, absent
overlays, "tolerance-aware"; the retracted "cyclic Method" reason in two files; the
`ensure_exception_tag!` docstring; formal/README maps one function to two models. (L11) the
statement lane's draw digest is printed, not asserted. (self) no ratchet counted
process-global state (MARCH 13.7); a requested validation without wasm-tools warned and
skipped; `discovery` took one legal value.

Resolution: batch 60 (this commit) — B1: the trace is codegen state on a per-compilation
Translator (dart translator.dart:96), passed in by the caller; L149 locks the builder free of
Julia compiler objects, and moved `julia_to_wasm_type` and its union helpers to codegen (B5
in part). P2: collection returns a ClosedWorld and planning a ClosedWorldPlan, values that
replace five process-global Refs; every planned function carries its recorded reason (entries,
each :invoke callee by its call site), and a missing one is a collector defect raised at
planning. R40 counts the process-global state left (8), with an exact allowlist. A requested
validation without wasm-tools throws. `discovery` is gone. P5: interrupts and out-of-memory
pass through both catch-alls. L9, L10: README and the stale reasons corrected. M4, M5:
proposed to Dale, who answered "don't wait on me" (2026-09-29): C1, C3, C6, C7, C8 and C10
now name their open findings as `Planned:` and read OPEN until those land; a citation L125
requires for a new check is added with the check. Batch 61 — E1: a runtime-name getfield rejects at its statement, with
why, on a Module (Julia reads the global binding; WT threw FieldError where Julia returns) and
on a layout that does not hold Julia's fields in Julia's order (DataType, TypeName: measured,
the original raised a WasmInternalError, not a silent value) or a MemoryRef field. E7: the
call's result is detected by stack height (not reproduced by a planted Nothing-returning
callee; the height is the exact test). E8: a runtime tuple or vararg index is taken only when
its type is an integer (a Symbol on a vararg pack raised a WasmInternalError; it now throws
FieldError as Julia does). Batch 61b — Therapy.jl's downstream job paused at Dale's
direction (MARCH 13.16 restores it). Batch 62 — H1, H2, P7: one module shape. Every module
imports `wasmtarget.stack_trace` and exports its tag; every throw carries the stack at the
throw, and a rethrow the stack its catch stored in `\$current_stack` (the source-map test
rethrows and still names the first throw; with the fresh-stack rethrow planted back it fails);
a source-mapped build is the plain build plus its URL section (a test checks the bytes); every
host import WT creates is answered by one HOST_RUNTIME (`host_runtime_js()`, L150), which every
harness and the docs example use; a framework module declares the imports before its own
definitions or is told how. N1 (found while fixing H1): `\$current_exn` was found by its type,
the first mutable anyref global; globals now carry dart's names and are found by name. Also
fixed here, what batch 60's CI found: the fuzz bridges still passed `discovery`, and on Julia
1.13 the planning check found an enrollment nobody recorded — an atomic modify's operator
(`:invoke_modify`), now recorded with its statement. E9 (unmapped instructions, borrowed
locations) is not done: it stays with MARCH 13.15. Batch 63 — B2: block!, loop!, if_! and try_table!
take only the frame's inputs and results and derive the encoding as dart's `_beginBlock` does
(void, the one result's value type, or a function type it defines); the positional block type
is gone, so `try_table!(b, cs, I32)` cannot be written (a test asserts no such method). Only 5
of 225 probes changed, and modulo renumbering their modules are identical: one-result blocks
now encode their value type instead of a hand-made function type. B3: br, br_if and every
try_table catch go through validate_branch_types!, dart's one `_verifyBranchTypes`. Measured
first: with br's check removed, all of Phase 29 still passed — no test rejected a wrong-typed
branch; module_builder_validation now does, for br and br_if, each negative-tested. Next, in
order: the second audit (L148); 64 B4, B5 (typed pops,
no fallback types); 65 H3 (the native reference computes muladd as fma: bit-exact); 66 M7, L11; then P3
with P4 (the model first), E3–E6, B5–B7, P6, S6, M6, L8, E10, E11 and the side notes.

## 2026-09-30 — audited through 9366d55b (7acc21c9..9366d55b: batches 60–63)

The second audit, of the first audit's fix batches: 37 findings. Three were wrong answers,
all reproduced (A2E1–A2E3), all older than the range and carried into it.

Area: builder — (A2B1) `return_!` checks nothing; dart's `return_` checks the function's
results. (A2B2) one-result block types are encoded by codegen's `encode_block_type`, a second
value-type encoder that disagrees with `write_valtype!` and has no NonNullAbstractRef arm.
(A2B3) `_block_type!` accepts a raw byte (0x40, a packed type) as a result. (A2B4)
`validate_else!` drops an if's inputs; an if with results and no else is not rejected. (A2B5)
`throw_!` checks the caller's `inputs`, not the tag's. (A2B6) N1's lookup by name is not dart's:
dart keeps the global it defines and writes names only into the name section. (A2B7)
`select_t!` takes raw bytes; `global_get!`, `call_indirect!` and `call_ref!` fall back to the
caller's types. (A2B8) the builder still reads `OPTIONS[]` and hosts `JSValue`, `WasmGlobal`.
(A2B9) stale prose (OperandStack.tla, `validate_br!`'s loop claim, instr_ir.jl:94) and a
twice-computed catch depth. (A2B10) C1 and C7 still listed B2 and B3.

Area: collection and planning — (A2C1) the reason table misses edges Julia's compile queue
follows: a finalizer, a `:cfunction`, and on 1.13 `:new` of a Function; the pruner follows
neither those nor `:invoke_modify`. (A2C2) two more catch-alls re-infer on an interrupt, and
internal ArgumentErrors still pass unlocated. (A2C3) the Translator holds only the trace; the
plan is republished through TRIM_IR_CACHE, whose reset to `nothing` lets a later read fall to
a second inference. (A2C4) `:invoke` edges are walked twice and the planner mutates the
ClosedWorld's dict. (A2C5) `collect_new_pairs!` keeps a default reason. (A2C6) the source-map
and trace entries lack `diagnostics_sink` and the framework keywords. (A2C7) the
existing_module check runs after collection; the tag is found by position. (A2C8) a closure's
dispatch-candidate key lacks the prepended closure type. (A2C9) new locks pin text.

Area: emission and diagnostics — (A2E1) WRONG ANSWER: `pop_exception` did nothing, so after a
nested catch a `rethrow()` rethrew the nested exception (reproduced: native 1, wasm 2). (A2E2)
WRONG ANSWER: `catch e` read the last region entered before it, so an outer catch after a
nested try region bound the nested exception (reproduced inside A2E1's case and alone).
(A2E3) WRONG ANSWER: `rethrow(e)` ignored `e` (reproduced: native 1, wasm 2). (A2E4)
HOST_RUNTIME is a second list, not generated from the module. (A2E5) a Union mixing a
primitive and a struct-stored number is not boxed (`Union{Int64,Int128}` → i64), and
`julia_to_wasm_type` keeps placeholder fallbacks. (A2E6) E8 takes any Integer; Julia's field
index is an Int. (A2E7) the exception tag is found by position. (A2E8) false prose.

Area: enforcement and prose — (A2P1 = A2E1). (A2P2) README and docs instantiate modules with
no imports, false since batch 62. (A2P3) the new import breaks WasmMakie, Snapshot and the
docs islands too, and only Therapy is tracked. (A2P4) the clause status counted a ratchet at 0
as closed; the charter requires a lock; Planned markers were stale and incomplete. (A2P5) L148
checks recency, not coverage (unchained entries, `--ancestry-path` on merges, rebases). (A2P6)
first-audit findings left only in this file's "Next" line; E9 claimed by 13.15 but absent.
(A2P7) C3's tolerance wording is narrower than L138; cov and cor claims disagree. (A2P8) R40
depends on spelling; STANDALONE_INTRINSIC_BODIES fills during a compilation. (A2P9) L150's
text match; B3 has no lock; restated locks not negative-tested. (A2P10) prose: README's stray
quote, "a lock" for R38, "the builder checks every instruction" while B4 is open,
ClosedWorld.tla's retired name, and "At Dale's direction" where Dale delegated.

Resolution: batch 64 — A2E1, A2E2, A2E3 fixed as Julia's exception stack: a try region's
enter saves the exception and stack being handled, its pop_exception restores them, `catch e`
reads the top, and `rethrow(e)` puts `e` on top and keeps the caught stack. Smoke group
exception_stack pins each case; planting the pop no-op back and planting `rethrow(e)` back each
fail it. Planting the pop no-op back also exposed a fourth defect, now fixed: the wrong-value
locator aborted Julia's process on IR with try regions (a probe after an Upsilon or PhiC node),
so a wrong answer took the whole run down; it now names the first divergent statement, and a
function compiled from a bespoke body (rethrow) is not traced. A2P4: a cited ratchet keeps its
clause OPEN until it is a lock; the 14 ratchets at 0 became locks (R36 negative-tested); every
clause's Planned names its open MARCH rows and findings. A2P6: every open finding is now on
dev/MARCH.md 13.17 in the order it is taken, and E9 is on 13.15. On A2P10's last point:
Dale's "don't wait on me" (2026-09-29) delegated the charter markers; ed7f2323 said "direction".
Everything else: MARCH 13.17. Batch 65 — A2B2, A2B3, and B5's shorthand: one value-type
writer, dart's one-byte nullable abstract references, no raw byte as a block type (all 225
probe modules print identical text). Batch 66 — A2B1, A2B4, A2B5, B4, most of A2B7: return,
throw, global.set/get, ref.is_null, ref.as_non_null, array.len, extern.convert_any, ref.test,
select and call_ref check what dart checks, else re-pushes the if's inputs, an if with
results needs an else, and every codegen builder has its module (L151). The stricter pops
found the closure vtable's funcref fields declared as the raw byte 0x70; FieldType now
refuses a raw byte that is not a packed type. A2P3 measured: WasmMakie fails on the new
import (paused with Therapy, MARCH 13.16); Snapshot passes. A2E5 measured: not reproduced. Batch 67 — A2C3's IR half: the Translator carries the
plan, and codegen reads every function's IR from it (plan_ir) or, in collection, from the
collected pairs; the box-capture analysis takes its closure bodies as a required lookup (the
smoke corpus never reached its second inference, but nothing forbade it); TRIM_IR_CACHE is
gone (R40 8 → 7), and L152 forbids any other IR source in codegen.

## 2026-09-30 — audited through 23cdab07 (9366d55b..23cdab07: batches 64–68)

The third audit, of the second audit's fix batches: 51 findings, 47 distinct. Four are wrong
answers, all reproduced: two the auditors found by reading (A3E1, A3E2) and two found while
measuring those (A3E10, A3E11); three more are traps where Julia answers (A3S1 under a catch,
A3S2, A3S3). Two resolutions of the second entry do not hold: A2B1's return check never runs
on compiled code, and A2P6's "every open finding is on 13.17" left thirteen out.

Area: builder — (A3B1) `return_!`'s check never runs on compiled code: the function and
fragment builders carry no results, so only the int128, egal, trampoline and selector-caller
builders are checked (A2B1's resolution is false for codegen). (A3B2) `ref_test!` validates
without its target, `ref_cast!(::RefType)` pops untyped, `local_set!` of an unknown index pops
untyped, `builder_set_local_type!` invents AnyRef. (A3B3) the validator calls `wasm_subtype`
and `_wt_same_hierarchy` from codegen/values.jl; `_non_null` duplicates `_wt_drop_nullable`;
`_wt_heap_kind` guesses a struct for an unknown index. (A3B4) `WasmValType` admits a raw
UInt8, so a raw byte passes through signatures, locals, globals, labels and `select!`; void is
the byte 0x40 in `BlockTypeArg`; no test of the `_block_type!` guard. (A3B5) L151 matches the
text `mod=`, which `mod=nothing` satisfies (selector_table.jl:287), and the module-less
fallbacks stay reachable. (A3B6) `ref_null!` pushes the caller's claimed type (a non-null
claim tracks a null as `(ref $T)`); `struct_new!`'s explicit form pops the caller's field list
(23 sites), and its module form pops a packed field as its raw byte. (A3B7) `num!` encodes every
opcode the validator models as one byte (consts, loads, stores, memory.size/grow without
immediates); `ref.eq` goes through it. (A3B8) extern.convert_any and any.convert_extern
always push a nullable result; dart keeps the input's nullability. (A3B9) the signed/unsigned
packed read, immutable-field writes, and the kind of a new-default/new-data/copy index are
not checked. (A3B10) one rule, the module's type against the caller's claim, has four
policies; `_true_call_sig` re-implements `_function_type`. (A3B11) batch 66 changed the
if/else rule without changing OperandStack.tla, and rejects a valid else-less if whose inputs
are subtypes of its results. (A3B12) A2B9 and two of B5's items on no list. (A3B13) prose.
(A3B14) batch 66's checks untested: global.get, ref.as_non_null, ref.eq, extern.convert_any,
ref.cast, call_indirect, call_ref, an unknown index. (A3B15) A2B6 stands: `global_named` is a
lookup by name, and no global name reaches a name section. (A3B16) no define-then-fill
function API: codegen writes `mod.functions[slot]` directly.

Area: collection and planning — (A3C1) codegen still asks Julia's inference at six sites
(context.jl:1547 re-infers a return type the plan holds; :1578; builtins.jl:92;
box_capture.jl:124, 355, 502, the last three in collection too), each a fresh interpreter at
the current world; L152, plan_ir's docstring and batch 67's resolution say never. (A3C2)
box_capture.jl:230 skips a captor body the lookup misses, so its writes leave the join; the
old path raised. (A3C3) plan_ir, the loud reader, runs where a miss is impossible; four sites
read `get(plan.ir_cache, mi, nothing)`. (A3C4) the capture record is computed twice, over two
domains; six copies of the collected-pair walk. (A3C5) ir_cache's `(f, arg_types)` keys have
no reader; R31's allowlist reason is false. (A3C6) dead code from batch 67. (A3C7)
`rethrow(e)` of a non-reference raises an unlocated internal error. (A3C8) "compiled from a
bespoke body" decided twice, by two keys. (A3C9) L152 pins text. (A3C10) stale prose, among it
ir.jl's claim that `get_typed_ir` shows the IR codegen compiles (collection rewrites invokes).
(A3C11) batch 67's invoke-MI keying is a behavior change no case pins. (A3C12) A2C7's
existing_module half, A2C9, P3 and P4 on no row.

Area: emission and diagnostics — (A3E1) WRONG ANSWER, reproduced (native 2, wasm 1): a try
region's enter saves the exception's value where Julia saves the stack's depth, and
`rethrow(e)` overwrites the top in place, so a `rethrow(e)` inside a region nested in a catch
is undone by that region's pop. (A3E2) WRONG ANSWER, reproduced three ways (native 4, wasm 3,
1, 3): `rethrow()` and `rethrow(e)` outside a catch throw `$current_exn` or `e`, where Julia
raises ErrorException("rethrow() not allowed outside a catch block"), including after a catch
has finished. (A3E3) batch 64's protocol has no TLA+ model. (A3E6) a twin of batch 68's
deleted path: calls.jl unboxes any AnyRef operand of div/rem/mod and numeric intrinsics as
Int64 or Int32 without its class. (A3E7) dated history in src comments; MARCH 13.10 moved the
capability gaps "after the merge" without Dale's decision (rule 5). (A3E9) two channels for
the thrown value; `_lower_ifelse!` takes its type from a re-inference.
Found while measuring: (A3E10) WRONG ANSWER, reproduced (native 7, wasm 8):
`Core.throw_methoderror` threw `$current_exn`, the exception last handled or null, never a
MethodError. (A3E11) WRONG ANSWER, reproduced (native −7, wasm 5, three shapes): typeassert
checked only a classed struct against a concrete target; `x::Integer` of a Float64,
`x::AbstractString` of a struct and `nothing::T` passed. (A3S1) a dynamic call with no method
traps; Julia throws a catchable MethodError and dart calls noSuchMethod. (A3S2) `add_type!`
dedups Memory{Any}'s array with SimpleVector's, and Memory{Int64} with Memory{UInt64}: a
dynamic dispatch among them traps (reproduced: native 3, wasm illegal cast). (A3S3) a dynamic
`getindex` on a tuple held as Any traps where Julia has the method (reproduced: native 3, wasm
unreachable), against ClassIdSwitch's "a trap only where Julia has no method". (A3S4)
compile.jl:701 calls `generate_dispatch_caller_body`, deleted in aa809d94.

Area: enforcement and prose — (A3P1 = A3C1) L152 counts one spelling. (A3P2 = A3E7) 13.10's
premise "each rejects at its statement" is false for three of its gaps (a `repr` that does not
finish, an unlocated MethodError in inference, a WasmInternalError at a tuple of an Any).
(A3P3) the known traps sit outside every lane. (A3P4) the Planned markers drifted: C0 reads
CLOSED while A2P5 is open; C7 lists fixed findings; C8 points to a finished 13.9; thirteen IDs
(P3 P4 E3 E4 E5 H3 M7 L11 A2B7 A2B9 A2C7 A2C9 A2E8) are on no row. (A3P5) the xfail lane
counts any compile exception as a located rejection (`catch; :loud`), so a WasmInternalError
passes as one. (A3P6 = A3B14) (A3P7 = A3B5) (A3P8) runtests' `total <= 65` raw-emission check
is a ratchet no clause cites, at 37 measured. (A3P9) the status passes a lock equal to its
baseline; the 14 converted locks still sit under [metrics]. (A3P10) prose (smoke's "each case
answered 2", misplaced headings, three places naming get_typed_ir as codegen's IR, R40's
file, downstream.yml's date). (A3P11) text pins in L152, L147, L142; three copies of the f3
test helper.

Resolution: batch 69 (this commit) — A3E10: `Core.throw_methoderror(f, args...)` throws
`MethodError(f, (args...,), world)`, its args tuple typed by one answer the collector numbers
and codegen builds (`methoderror_args_type`); when an argument's runtime type is known only at
run time it traps, as the class switch traps where Julia has no method, and A3S1 carries both.
Smoke group method_error_value reads the caught value (Julia folds `e isa MethodError` here);
the old throw planted back fails all three cases. A3E11: typeassert is dart's emitAsCheck, the
one `isa` test and a throw: a value of concrete static type is decided at compile time, every
other through `_compile_call_isa`, which now narrows a test to S ∩ T as Julia's emit_isa does
(without it, `using WasmTarget` fails: Base._accumulate1!'s `x::Tuple{Any,Any}` of a
`Union{Nothing,Tuple{Int64,Int64}}`). Smoke group typeassert_checks: the old lowering planted
back answers 3 wrong and traps once. A3E7: MARCH 13.10 is back in the rewrite (rule 5), and
its gaps that do not reject at their statement are on 13.17. A3P4, A3B12, A3C12: every open
finding of the three audits is on 13.17, in the order it is taken. Everything else: MARCH 13.17. Batch 70 — A3E1, A3E2, A3E3,
and A3E9's two channels: Julia's exception stack, modeled first (dev/formal/ExceptionStack.tla,
its Julia side read from task.c and rtutils.c). A throw pushes an entry (its exception and the
stack it captured) and throws the tag with it, one channel; a rethrow throws the top entry,
pushing nothing, and `rethrow(e)` overwrites it; an enter saves the top, its depth, and its
pop_exception restores it; the_exception reads the top; a rethrow at depth 0 throws Julia's
ErrorException. TLC's first counterexample was against the design, not the code: pushing at the
catch's landing gives a rethrow's landing a second entry, which a later `rethrow(e)` overwrites
instead of Julia's (the LandingPush instance). Smoke group exception_stack's five new cases: the
old lowering planted back answers four wrong. The stack across calls is on 13.17. Batch 71 — A3S4: a dispatch caller is
only a function whose table has a selector route; the other tables' functions compile from
Julia's IR, whose dynamic call dispatches or rejects, where the deleted function was called.
test/no_undefined_globals.jl reads every method the package's modules define, in Julia's
lowered code, for a global that names no binding: it found that call and nothing else. A3P5:
the xfail lane counts a rejection only when it is a WasmCompileError naming its statement; any
other exception is a crash, which fails the lane. It found three, each now Julia's answer or a
located rejection: `compilerbarrier(:type, x)` boxes x with its class into the statement's Any
(inferencebarrier_int passes, promoted out of the xfails), `getfield(T, :layout)` is C_NULL for
a type with no layout as in Julia (sizeof of an Any element now rejects at `Core.sizeof(Any)`),
and a tuple whose type is known only at run time rejects at its statement. Batch 72 — A3S2, the trap. A
SimpleVector is dart's immutable array (translator.dart:1218 wasmArrayType, `mutable: false`),
so it and a Memory{Any} are two wasm types and a value of either is told apart; every probe
module changes only in that one type line (all 225 printed and compared). Core.svec could not
be tested: a function the IR embeds as the object itself (`(Core.svec)(x, 2)`) was a literal
operand at the NIR boundary, where a GlobalRef to it is the function, so every `func === X`
arm missed it; resolve_call_callee now gives both one representation for a function of a
singleton type, which is its instance (0 probes change; the fuzz lane caught the first version,
which also took a capturing closure for a name and dropped SparseArrays' throwTi's captured Ti),
and Core.svec and `Core.sizeof(Any)` reach their lowerings. Memory classes that still share an
array type (Memory{Int64} and Memory{UInt64}) are told apart by no test: a typeof over them,
the inline class switch and the closure trampoline reject at compile time where they trapped
(measured: the trampoline trapped with an illegal cast where native answered 3). The inline
switch's rejection has no case that reaches it; a program whose runtime value is another class
now rejects where it answered, a capability loss. The root, a Memory as a classed object, and
the trampoline's unlocated rejection are on 13.17.


## 2026-09-30 — audited through f3791ced (23cdab07..f3791ced: batches 69–72)

The fourth audit, of the third audit's fix batches: 36 findings. Six are wrong answers, all
reproduced; one of them batch 69 caused (A4E1 c). Batch 72's resolution claimed every class
read over two Memory classes of one array type rejects; `isa` and typeassert answered.

Area: builder — (A4B1) add_global!'s typed-null arm writes its initializer by hand, a third
route beside `ref_null!` into add_global_ref!; dart's initializer is a validating builder
(global.dart:13-21). (A4B2) SimpleVector keeps dead mutable fallbacks (structs.jl:268,
types.jl:3009, calls.jl:3545) and prose saying "externref array". (A4B3) `builder_diagnose`
and `reset_validator!`'s false quarantine are on no row. (A4B4) the exception cell type is found
by content through add_type!'s dedup, not held by handle. (A4B5) add_global!'s arms reject a
wrong call unevenly. (A4B6) batch 72 fixed an unnamed `===` wrong answer on two Memory{Any}
(each passed the SimpleVector arm of the runtime egal); no case pins it. (A4B7) 13.7's "dart
dedups only function types" misses dart's array cache (translator.dart:231, :1223). (A4B8) stale
prose on the exception payload. (A4B9) L145 pins text; a throw that calls `_emit_throw_top!`
without pushing passes it.

Area: collection and planning — (A4C1) the shared-array check read `reg.arrays`, which fills as
bodies compile, so a class no signature names looked unshared; measured: the program the
auditor gave rejects in this order, the premise holds. (A4C2 = A4E1) WRONG ANSWER, reproduced:
`isa(x, Memory{Int64})` of a Memory{UInt64} answered 1 where native answers 2, and
`x::Memory{Int64}` returned 3 where Julia throws TypeError. (A4C3) WRONG ANSWER, reproduced
(native 23, wasm 13): the single-body closure entry cast its argument, so a struct of another
class with one deduplicated layout ran this body. (A4C4) a singleton callee no longer enters the
dispatch-candidate class boundary (trimcollect.jl:430). (A4C5) the one callee representation
covers singleton functions only; intrinsics and capturing closures stay literals. (A4C6) a third
key for "compiles to rethrow's body". (A4C7) batch 71's selector-less route is in no lane. (A4C8)
stale prose.

Area: emission and diagnostics — (A4E1) WRONG ANSWERS, reproduced: (a) and (b) as A4C2; (c)
batch 69's S ∩ T narrowing sent `x::Union{Int64,Memory{Int64},Memory{UInt64}} isa
AbstractVector{Int64}` to the concrete arm, answering 1 where native answers 2 (it had
rejected). (A4E2) WRONG ANSWERS, reproduced (native 1, wasm 2, twice): a tuple of a type operand
is classed `Tuple{Type{Int64},Int64}`, a type no Julia value has (jl_f_tuple types an element by
its kind), so `typeof` and `===` over it answer wrong. (A4E3 = A4P1) (A4E4) the shared-array fact
computed three times and too broadly (a class that cannot be the value counted). (A4E5) the
TypeError built in two places. (A4E6) a MethodError WT cannot build is an unrecorded trap, and a
test pins the trap. (A4E7) stale prose. (A4E8) unverified: Julia's emit_isa may guard its S <: T
fold (jl_is_not_broken_subtype).

Area: enforcement and prose — (A4P1) batch 72 changed the class switch without its model:
ClassIdSwitch.tla still allowed the trap, and no Broken instance kept the old rule. (A4P2) the
trampoline's rejection is unlocated, and L118 exempts compile.jl as a whole file. (A4P3) a known
trap (gu) is asserted as a pass outside R39; A3P3 and A3C6 are on no row; the Planned markers
omit findings again. (A4P4) test/no_undefined_globals.jl misses closure bodies, methods added to
Base/Core, overlays, return and branch operands, and Core.Compiler; its "for a year" is false
(aa809d94 is 2026-07-02). (A4P5 = A4B9) and no test that `rethrow(e)` keeps its throw's stack.
(A4P6) the LandingPush counterexample has no differential case. (A4P7) stale prose. (A4P8 = A4C7)
(A4P9) the gm test passes on any WasmCompileError.

Found while fixing: (A4S1) a vtable entry tries its rows in program order, so a row taking `Any`
placed first runs where Julia selects a more specific method (not measured). (A4S2) the closure
of A4C3 has one method over `Any`, and the closed world enrolls only its SA specialization, so a
call with an SB traps where Julia answers 23 (with A3S3).

Resolution: batch 73 (this commit) — model first: ClassIdSwitch.tla's rows test a parameter
type's classes, a call with a candidate class no test tells apart rejects, and a trap is allowed
only where Julia has no method; its Broken instances keep the old no-row rule (SharedNoRow) and a
row that tests only the layout (CastOnly, A4C3's counterexample). A4C1, A4E4: one partition,
`bare_array_partition`, over the numbered classes a value of the static type may be, each class's
array type decided from its element (get_array_type!), serves typeof, the class read, both isa
arms, the inline switch, the trampolines and the planner's check; the dead second check goes.
A4C2, A4E1: an isa or typeassert of a Memory class whose array type another class the value may
be is too rejects at its statement (smoke xfails isa_either, typeassert_either,
narrowed_isa_either; with the check removed each answers wrong). A4C3: every vtable entry, one
body or several, tests each argument against its parameter type (`_emit_closure_arg_tests!`: a
classId, a kind, an abstract type's classes, a bare array's own type); the trampolines declare
their scratch locals to the builder (the dispatch entry's anyref scratch had been an invented
AnyRef). test/dispatch_method_error.jl pins that the SA body never runs for an SB; with the test
removed, it answers. Everything else: MARCH 13.17. Batch 74 — A4E2: one
`tuple_runtime_type` answers a tuple's type as jl_f_tuple does (a concrete element type is
itself; `Type{X}` of a known X is `typeof(X)`; anything else is known only at run time and the
tuple rejects), for `_lower_tuple!`, the collector's numbering and a MethodError's args;
`_lower_tuple!` reads its operands' types from Julia's IR as the collector does
(`_collector_static_type`), not from WT's re-inference. Smoke group tuple_runtime_types: the old
typing planted back answers 4 of its 5 cases wrong. Batch 75 — A3S3, A4S2: three
traps where Julia answers, measured (native, wasm): a closure called with an erased struct of
another class (23, trap), `getindex` and `length` of a tuple held as Any (3 and 2, trap). The
candidate collector never noted a tuple as instantiated (Core.tuple allocates without a %new)
and excluded tuple classes from candidates ("tuples keep their own path"); it now observes the
class Core.tuple builds (tuple_runtime_type) and treats a tuple as the classed struct it is, and
the inline switch takes tuple rows. A closure called with an erased argument enrolled no body
(its signature had to be all concrete); it now enrolls the body specialized on the argument's
static type, which the trampoline's abstract row tests. Smoke group dynamic_enrollment: with
the collector change reverted, all three trap. A4S1 measured unreachable: an erased
generic-function value rejects (13.10) and the inline switch's rows are concrete classes (false:
only the inline switch was measured, and the vtable reaches it, audit #5 A5P2). Batch 76 — A4E8: Julia's emit_isa
(cgutils.cpp) folds S <: T only under jl_is_not_broken_subtype (subtype.c: never a `Type{…}`
against a kind, JuliaLang/julia#27078); `_compile_call_isa` now guards its fold the same way
and tests the type object's kind there (smoke group kind_isa; no program was found that the
unguarded fold answered wrong). A3E6 closed by measurement (on a false description, reopened by audit #5, A5P5): the AnyRef unbox in compile_call!
had 0 hits over the smoke corpus, a dynamic div/rem/mod over an erased operand dispatches and
answers as Julia (four cases), and the unbox applies only where Julia's IR types the operand
concretely and WT holds it in an anyref local, at the width Julia states. Batch 77 — A3C2: the box-capture walk
skipped a captor whose body its lookup did not hold, so that closure's writes left the join and
the box could narrow to its creator's init; the walk now reports the view incomplete and the
box stays erased (BoxJoin.tla: an invisible write never narrows the cell).
test/f3_box_capture_l0.jl asserts both with a lookup that holds nothing; the old walk fails 2 of
its 4 checks.


## 2026-10-06 — audited through e225334d (f3791ced..e225334d: batches 73–76)

The fifth audit, of the fourth audit's fix batches: 37 findings. Each wrong answer an auditor
predicted was measured (each program compiled with WasmTarget.compile and run against native Julia). Five are wrong
answers today: one batch 75 caused (A5E1 = A5C1 = A5P2), four were already there (A5E2,
A5E3, A5E4 = A5B3). Batch 75's resolution claimed A4S1 unreachable; the vtable reaches it.

Area: builder — (A5B1) the closure entry's DataType row admits a TypeVar: populate never
writes a $JlTypeVar's $kind, so it reads 0, DATATYPE's code, and the field comment says 3
(measured: native 22, wasm trap, not the predicted wrong answer). (A5B2) a CodeUnits has
Memory{UInt8}'s array type and is not in bare_array_partition (native 2, wasm trap). (A5B3 =
A5E4) add_type_group! never deduplicates, so two isomorphic recursion groups get two indices
for one wasm type, and the concrete isa arm's `ref.test` cannot tell them (native 2, wasm 1;
over Memory{LA} and Memory{LB} the isa rejects at its statement). (A5B4 = A5E10) an inline
switch with a DataType row; not reproduced: native 1 and 21, wasm 1 and 21. (A5B5) the
single-body argument test has a dart anchor: a dynamic closure call checks its argument types
(dynamic_dispatchers.dart:596). (A5B6) no case for the kind, `Type{X}`, abstract-with-Nothing,
bare-array or TypeVar rows. (A5B7) the second shared-array check in the entry survived, with a
message false for the only class that can reach it. (A5B8) stale prose (the dispatch entry's
docstring, the TypeVar kind, `told`). (A5B9) trampoline locals declared in three places.

Area: collection and planning — (A5C1 = A5E1 = A5P2, A5P3) WRONG ANSWER batch 75 caused: an
erased argument enrolled only the methods whose signature contains the call's static type, so
a closure with h(::Int64) and h(x) called with an erased Int64 ran h(x) (native 4, wasm 5), and
one whose only method is h(::Int64) got no body (native 6, wasm rejection); with both methods
enrolled, rows were tried in program order (A4S1). (A5C2 = A5P1) a tuple's `Type{X}` element is
typed `typeof(X)` where tuple_tfunc does so only under `hasuniquerep(X)` (measured: traps,
illegal cast, where Julia answers 1). (A5C3) a kind observed from a tuple's parameters becomes
an inline-switch candidate; not reproduced (native 1, wasm 1). (A5C4 = A5E6) a body enrolled on
an abstract parameter that admits a bare array fails the module with a WasmInternalError
(native 13). (A5C5 = A5E5) `_canonical_tuple_type` keeps a second `Type{X}` rule. (A5C6) the
dynamic signature ignored the capture joins `_call_type` applies. (A5C7) a dead Vararg test,
stale prose in ClosedWorld.tla and MARCH 13.10.

Area: emission and diagnostics — (A5E2) WRONG ANSWER: `isa(x, Type{Int64})` of an erased
type object answers 2 where native answers 1, and `x::Type{Int64}` throws (wasm -7, native 1):
the abstract arm keeps a kind only when the kind is contained in T. (A5E3) WRONG ANSWER: a tuple
of run-time length is classed `Tuple{Vararg{Int64}}`, so typeof, `===` and isa answer 2 where
native answers 1. (A5E7) a dormant 4-argument ClosureBody whose `nothing` parameters read as
"accepts anything". (A5E8) the type-object kind partition is over every class, not the value's
static type. (A5E9 = A5P4) no kind_isa case reaches batch 76's guard. (A5E11) prose.

Area: enforcement and prose — (A5P5) A3E6 was closed on a false description: the unbox takes
its width from the operator and tests no class. (A5P6) ClassIdSwitch.tla omits the abstract
parameter refusal and overlapping rows. (A5P7) A4C3's negative test depended on row order, and
gq matched "23" as a substring. (A5P8) A4P3 and 25 audit-4 IDs on no Planned list. (A5P9) no
model of enrollment. (A5P10) the dead Vararg test; "measured unreachable" cites no command.

Resolution: batch 78 (this commit) — model first: Enrollment.tla claims that for every class
that may reach a dynamic call the body Julia selects runs; its Broken instances keep the subset
rule (SubsetRule, the w2 counterexample) and program order (ProgramOrder). A5C1, A5E1, A5P2,
A5P3, A4S1, A5P9: the collector enrolls what Julia's matching gives the call's static signature
(`Base._methods_by_ftype`, each method at its intersection), and an entry tries its rows most
specific first (`_most_specific_first`, Base.morespecific). Smoke dynamic_enrollment gains
closure_two_methods_erased, closure_narrow_method_erased, closure_overlapping_rows and
closure_overlapping_any_vector: the old enrollment planted back answers 5 where native answers 4
and fails to compile the second; program order planted back answers 3 of them wrong. A5C6: the
dynamic signature types its operands by `_call_type`. A5C7, A5P10: the dead test goes; 13.10's
prose says what WT does. A5E7: `julia_params` is required and its `nothing` arms go. A5C4,
A5E6: the refusal is a WasmCompileError naming the callable, raised before the vtable is built
by the one predicate `_closure_param_untestable` (e6 measured), the entry keeping only an
internal guard; rows per observed class are on 13.17. A5B7: the guard's message says what it
found. A5B4, A5C3, A5E10: measured correct; smoke kind_and_class_rows pins A5B4 and A5E10, and
kind_row_beside_type_tuple (batch 82) pins A5C3. A5B5: the anchor.
A5B8, A5E11: the prose. A5P6: ClassIdSwitch.tla states what it leaves to Enrollment.tla and the
refusal. A5P7: rows now come most specific first, so with the argument tests removed gq answers
13 (test/dispatch_method_error.jl:129 fails) and closure_erased_argument answers 13; gq
compares the value exactly. A5P8, A4P3: the open IDs are on their Planned lists. A5P1 (= A5C2),
A5P4 (= A5E9): MARCH 13.14. Everything else, A5P5 included (A3E6 reopened): MARCH 13.17.
`tuple_runtime_type` now reads its operands: a literal or constant-global operand's type is its
value's (a type object's kind). Batch 79 — A5E2: `_compile_call_isa` takes emit_isa's cases for
a test that meets `Type{…}`, asking Julia's own predicates: an intersection `Type{X}` whose values
are pointer-unique (jl_pointer_egal) is X's identity (ref.eq against X's type constant), the
intersection `Type` and a kind stay the kind test (jl_isa answers by the kind there), and a
tested type that meets `Type{…}` otherwise (jl_has_intersect_type_not_kind) is jl_isa's type
equality at run time, which rejects at its statement (smoke kind_isa's UnionAll case, whose
intersection is `Type{Vector}`, keeps its kind test). Batch 80 — A5E3: a runtime-length tuple
is an NTuple{n,E} for its run-time n, but its representation's header names Tuple{Vararg{E}},
which no value has. No class read sees that class now: isa against a concrete tuple type under
its static type tests its size; its typeof rejects; a statement that puts it in a slot Julia's
IR types otherwise (a return, a phi, a callee's parameter, a dynamic call, a Memory element, a
field: `_erased_vararg_tuple_operand`) rejects, and so does WT's own widening of it to a slot of
any class (emit_value!). Smoke group runtime_length_tuple and xfails runtime_length_tuple_class:
the old code answers isa_ntuple_length 2 where native answers 1, and compiles the three xfails
to wrong answers (typeof, `===`, an Any vector's isa). Batch 81 — A5E4 = A5B3: model first,
TypeIdentity.tla claims two distinct type indices are never one runtime type under wasm's
iso-recursive canonicalization; its Broken instance (a group added without looking for an
equal one) is the old code, and TLC's counterexample is two self-referential single-member
groups. add_type_group! returns the first index of an equal recursion group already in the
section (`_group_member_equal`, dart's _areGroupsStructurallyEqual: a reference inside the
group by position, outside by index), and finish_pending! takes its members' indices from
it. Smoke group isomorphic_recursive_classes: the old builder answers isa_other_class 1 where
native answers 2. dart instead brands the equal groups so each class keeps its own type
(A5B3 remainder, MARCH 13.17). Smoke group type_isa: the old
lowering answers 2 and -7 where native answers 1; xfail type_or_nothing_isa, which the old
lowering answered wrong, rejects.

## 2026-10-06 — audited through 5a3e1604 (e225334d..5a3e1604: batches 77–81)

The sixth audit, of the fifth audit's fix batches: 37 findings. Each predicted wrong answer was
measured (native, then wasm): six are wrong answers today (A6B1 measured on two programs), and
batch 78 caused three of them
(A6C1, A6C2, A6C3 = A6P3 = A6B5 = A6E5, in the enrollment and row order it introduced). Batch
78's resolution claimed that "for every class that may reach a dynamic call the body Julia
selects runs"; Enrollment.tla modeled specificity as a total order, so it could not see an
ambiguity, a tie or a missing row (A6C4). Batch 80's "no class read sees that header" is false
(A6E1, A6E2).

Area: builder — (A6B1 = A6P2) WRONG ANSWER: is_shared_wasm_type reads the structs registered
when the isa compiles, and registration is lazy, so an isa compiled before the class that shares
its index registers is a bare ref.test (native 2, wasm 1, for two one-field structs PA/PB, which
predates batch 81, and for LA/LB in either call order). (A6B2) batch 81 anchored the group merge
to dart's _areGroupsStructurallyEqual, which compares heap types by identity to decide which
groups to brand; dart leaves LA and LB one runtime type and tells the classes by classId.
(A6B3 = A6P5) TypeIdentity.tla never recorded which index a request got back, so an
over-merging equality passed it, and its group guard was not a strongly connected component;
checking the served index found add_type! handing a lone type the index of a recursion group's
member whose fields read equal. (A6B4 = A6E7 = A6C6) the closure row's `Type{X}` identity test
is a second, looser predicate beside batch 79's jl_pointer_egal (c6: an internal error where
Julia answers 1). (A6B6) prose on finish_pending!, RecGroup.tla and is_shared_wasm_type.
(A6B7) every add_type_group! reran Tarjan over the whole section. (A6B8) emit_isa swaps
Type{Union{}} for typeof(Union{}) before its pointer test.

Area: collection and planning — (A6C1) WRONG ANSWER: a method with static parameters intersects
an erased argument to a UnionAll; its MethodInstance was planned as no function, silently, so a
less specific row ran (native 1, wasm 2). (A6C2) WRONG ANSWER: a body reached only by `invoke`
became a row and tied with the dispatch target, rows being ranked by their specialized types
(native 12, wasm 22). (A6C3) WRONG ANSWER: an ambiguous pair of methods ran the first row where
Julia throws MethodError (native -1, wasm 1). (A6C4) the model. (A6C5) enrollment asks Base's
method table at the latest world, the plan the WasmInterpreter's overlay table. (A6C7) the box
walk's "complete" covers only captors invoked in the scanned body. Prose: the candidate
collector's docstring, `_most_specific_first`'s.

Area: emission and diagnostics — (A6E1 = A6P1) WRONG ANSWER: an isa against an abstract tuple
type of a runtime-length tuple reads its header class (native 1, wasm 2). (A6E2) WRONG ANSWER: a
failed typeassert puts the tuple in TypeError.got unchecked (native 1, wasm 2). (A6E3) a passing
isa's narrowed value is cast to the NTuple struct (a trap where native answers 6). (A6E4) the
statement check and the emit_value! check are two partial paths for one fact. (A6E6) a Vararg
tail in a callee's specTypes made the statement check raise a MethodError. (A6E8) no test pinned
the untestable-parameter rejection. Prose: the vararg collector comment, bare_array_partition's.

Area: enforcement and prose — (A6P4) A5P4 = A5E9 on no Planned list. (A6P6) the group merge
needs its quarantine. (A6P7) MCEnrollment.tla described a callable it never defined. (A6P8)
Enrollment.tla's quarantine contradicted dart's dynamic call type check. (A6P9) a "program
order" comment in build_closure_vtable!. (A6P10) batches 80 and 81 put their smoke groups
between type_isa's comment and its group. (A6P11) kind_and_class_rows was said to pin A5C3.

Resolution: batch 82 (this commit) — model first: Enrollment.tla ranks methods by a strict
partial order and lets Julia answer MethodError for an ambiguity; its rows are (method,
specialization) pairs; it claims the entry runs Julia's method, traps only where Julia has no
method, and rejects only where a call over S is ambiguous; six Broken instances keep each rule WT
had (SubsetRule, ProgramOrder, SpecOrder, IncludeInvoke with SpecOrder, IgnoreAmbig,
SkipParametric), and TLC rejects each. A6C1: a method whose intersection is a UnionAll is enrolled
at each observed class it admits (Julia's own matching per class; a method no observed class
fixes is reached by no value of the closed world and has no row, as the candidate loop reads
it), and the plan raises on a MethodInstance that is not one signature. A6C2: an invoke-only body is no row,
and rows are ranked by Julia's method specificity (Base.morespecific on Methods), two rows of one
method by their specializations. A6C3: two enrolled methods Julia finds ambiguous
(Base.isambiguous) over values both rows admit reject the callable with a WasmCompileError.
Smoke dynamic_enrollment gains closure_parametric_method and closure_invoke_only_body;
test/dispatch_method_error.jl pins the ambiguity rejection (gam) and the untestable-parameter
rejection (gab, A6E8). With batch 81's collector, row order and pre-pass planted back, the two
smoke cases answer 2 and 22 where native answers 1 and 12, and gam runs a body. A6B3, A6B7:
TypeIdentity.tla records the index each request is served and claims it is the runtime type
requested; Broken instances LengthOnly and AnyMember (the old add_type!) fail it; the builder
keeps its recursion groups as it adds them (WasmModule.type_groups) and add_type! takes an
existing index only for a lone type with no inside reference; test/module_builder_validation.jl
pins the lone type. A6B4, A6C6: the closure row's identity test asks jl_pointer_egal, and any
other `Type{X}` parameter is untestable. A6B2, A6P6: the merge is quarantined as wasm's
iso-recursive equivalence, which WT needs because it numbers a type when it adds it. A6B6, A6B8,
A6E6, A6P1, A6P4, A6P7 to A6P11 and the prose: as found. Everything else (A6B1, A6E1 to A6E4,
A6C5, A6C7): MARCH 13.17. Batch 83 — A6B1 = A6P2: an isa of a class whose values carry the
class prefix tests its classId (emit_isa_classid!, through `classed_struct_idx`), as dart's is
checker loads the classId and range-checks it; a bare array, which has no header, keeps its
`ref.test`; is_shared_wasm_type, whose answer depended on which classes were registered when the
isa compiled, is gone, and so is the externref arm's fallback that answered "not null" for a
type with no class test (it rejects at its statement). Smoke group class_test_any_order: the old
arms answer 1, 12 and 1 where native answers 2, 22 and 2. Batch 84 — A6E1: an isa of a
runtime-length tuple against any tuple type tests the lengths that type admits (an NTuple{n,E}
with E concrete is a T exactly for those lengths: a list of exact and least lengths,
`tuple_lengths_admitting`, or a rejection where it is not one). A6E4, A6E2: the WT-internal
widening check is one check in the coercion funnel (convert_type!, keyed on the
representation's struct and trusting a known Julia source type, since another struct may share
the layout), in place of emit_value!'s; it also rejects the failed typeassert's TypeError.got.
The statement check stays for the widenings Julia's IR shows. Smoke runtime_length_tuple gains
isa_least_length, isa_least_length_fails, isa_union_of_lengths and same_layout_struct_erased, and
xfail typeassert_got: the old code answers 2 for the least-length and union tests where native
answers 1, and compiles typeassert_got to a wrong answer. A6E3 stays on 13.17. Batch 85 — A5B1, and A6B4's
two emitters: one emitter, `emit_type_object_test!`, answers whether a value is a type object
of T (X's identity for a pointer-unique `Type{X}`, else its kind, a TypeVar first, since its
`$kind` is never written and reads as DataType's); isa's type-object arm and identity arm and
a closure entry's `Type{X}`, kind and TypeVar rows all use it (a TypeVar row read a class header
it lacks, and a TypeVar passed the DataType row). Smoke group type_object_rows: the old rows trap
on typevar_row where native answers 22. typeof and jl_has_typevar read a kind, not test one, and
already test $JlTypeVar first. Batch 86 — A5B2: a String's CodeUnits is the String's byte array,
Memory{UInt8}'s array type, and bare_array_partition now counts it with the Memory and
SimpleVector classes, so a class read over both rejects at its statement (smoke xfails
codeunits_isa_memory, codeunits_typeof; the old partition traps on both, illegal cast, where
native answers 2). A Memory as a classed object, A3S2, tells them apart.

## 2026-10-06 — audited through 18a25734 (5a3e1604..18a25734: batches 82–86)

The seventh audit, of the sixth audit's fix batches: 28 findings. Each predicted wrong answer
was measured (native, then wasm): four are wrong answers today, with three roots. Batch 82 left
one of them (A7C1, the fix for A6C1 covering one erased position), batch 86 another (A7C2, its
CodeUnits counted at one of five sites), and one predates batch 83, which kept it (A7E2).

Area: builder — (A7B1) the recursion groups live in two records nothing compares: the builder's
type_groups, which deduplication reads, and recursion_groups, which the section is written from;
add_type_group! never checks that its members are one component (a builder-only program gives
two indices for one runtime type; finish_pending! always passes a component). (A7B2 = A7P2)
batch 82 dropped A5B3 with no resolution; dart brands equal flat class structs at -O2
(`uniqueTypes`, class_info.dart:435), and TypeIdentity.tla's header still said dart brands the
equal groups. (A7B3 = A7E2) classed_struct_idx misses String, Symbol and the boxes, which carry
the class prefix outside registry.structs. (A7B4) the type_groups comment misdescribes dart.
(A7B5) eager numbering, a WT choice (A3B16), is what forces the equal-group merge. (A7B6) prose:
add_type!'s docstring, "the old add_type!" for LengthOnly, tuple_lengths_admitting's reason (jl_isa
of a tuple is jl_subtype of its type, subtype.c).

Area: collection and planning — (A7C1) WRONG ANSWER: a method whose static parameters two
erased arguments fix was rowed one position at a time and so never (native 1, wasm 2), and it
then failed to cover an ambiguity of two less specific methods (native 3, wasm 1). (A7C2 = A7E1 =
A7P3) WRONG ANSWER: four sites decide "a bare-array class" by Memory or SimpleVector alone, so a
closure row taking a String's CodeUnits never matches (native 1, wasm 2) and an isa against one
traps. (A7C3) Enrollment.tla modeled one position and rowed a parametric method whole. (A7C4)
the ambiguity check asked Base.isambiguous over every type, rejecting a program Julia runs.
(A7C5) `something(k, 1)` hid a cycle in the specificity order. (A7C6) the generic-function
candidate loop specialized with empty static parameter values.

Area: emission and diagnostics — (A7E2) WRONG ANSWER: an isa of a closure type tested the
captured-fields struct, which a closure value is not (native 16, wasm 26). (A7E3) a vararg
method's packed tail is classed by its slot types (measured: rejected at its statement). (A7E4)
convert_type!'s widening check trusts a from_julia some callers give as the sink's type. (A7E5,
A7E6) prose: batch 85's "instructions unchanged" (a tee became set and get in an arm no probe
reaches), emit_isa_classid!'s and _emit_isa_type_object_kinds!'s docstrings.

Area: enforcement and prose — (A7P4) A6E4 was recorded resolved, but the statement check still
stands beside convert_type!'s. (A7P5) the IncludeInvoke Broken instance failed only through
SpecOrder. (A7P6 = A7B1, A7B4) (A7P7) TypeIdentity.tla's parity text, add_type! description and
Broken list. (A7P8) four behavior changes of batches 82–83 have no test. (A7P9) jl_egal reads a
kind without testing TypeVar (right because a TypeVar is mutable, so egal is identity). (A7P10)
prose: the audit #6 entry's "seven" (six), type_object_rows' place in smoke.

Resolution: batch 87 (this commit) — model first: Enrollment.tla has two dispatch positions,
values are pairs, and a method with static parameters needs Fix[m] positions fixed; its rows are
at each tuple of the call's pairs it admits, and the ambiguity check asks Julia per pair of
numbered classes. Broken instances PerPosition (A7C1) and AllTypesAmbig (A7C4) join the five kept
(IncludeInvoke goes, A7P5); TLC rejects each, and the positive passes. A7C1: the collector enrolls a
parametric method at each tuple of observed classes over the erased positions, each limited to
the classes the method's signature admits there, in one sorted order. A7C4: an ambiguous pair
rejects only when Julia's dispatch (Base._which) is ambiguous for a tuple of numbered classes in
their overlap (`ambiguous_class_tuple`; over 4096 tuples, or an overlap that is not one tuple type,
it rejects as before); the numbered classes include classes no value reaches, so a program whose
only ambiguity is over an unreached Int32 still rejects (MARCH 13.17, with A3S3). A7C5: a cycle
raises. A7C6: the candidate loop takes the static parameters' values from Julia's intersection
environment (smoke generic_parametric_candidate documents it; the empty svec happened not to
change that program's answer). Smoke dynamic_enrollment gains closure_two_position_parametric and
closure_parametric_covers_ambiguity: batch 86's code answers 2 and 1 where native answers 1 and 3.
A7B2 = A7P2: A5B3's premise was half true; dart brands equal flat class structs only with
`uniqueTypes` (-O2), and without it equal structs are one type and classes are told by classId,
which WT follows; dart's group comparison treats LA and LB as different, so it brands neither,
and they are one wasm type in dart too; the quarantine on _group_member_equal and TypeIdentity.tla
say so. A7B4, A7P7, A7P10's count: as found. Everything else (A7B1, A7B3 = A7E2, A7B5, A7B6, A7C2,
A7E3, A7E4 = A6E4 remainder, A7E5, A7E6, A7P8, A7P9, A7P10's smoke place): MARCH 13.17. Batch
88 — A7C2 = A7E1 = A7P3: one predicate, `is_bare_array_class` (a Memory, a SimpleVector, a String's
CodeUnits), answers every site that asks whether a class is a bare array: bare_array_partition,
isa's shared-array arm, the closure rows, the vtable pre-pass, the candidate switch. A7E2 = A7B3: a
class test reads the classId through the object header (`emit_isa_class_header!`: `$JlBase`, then
its classId), as dart's is checker does, for every concrete class that is not a bare array, in both
isa arms; `classed_struct_idx` and the externref arm's numeric-box branch, which it subsumes, go.
Smoke class_test_any_order gains closure_isa_own_type and closure_codeunits_row, and
shared_bare_arrays the xfail codeunits_isa_codeunits: the old code answers 26 and 2 where native
answers 16 and 1, and traps on the xfail. Found while fixing: (A7S1) a closure value has two
representations, its captured-fields context while its type is known (outside the class
hierarchy) and its closure object once erased; the header test alone answered false for the
context, which smoke closures/erased_nested_mul caught (native 112, wasm -12), so a closure
type's test accepts either; one representation is on MARCH 13.17. Batch 89 — A7B1:
add_type_group! rejects members that are not one strongly connected component, and the writer
compares the recorded groups with the section's (test/module_builder_validation.jl: the builder
counterexample now raises). A7P8: smoke type_bottom_isa and type_bottom_isa_other (A6B8),
type_identity_row (A6B4), and test/dispatch_method_error.jl gte (A6C6, a WasmCompileError where a
WasmInternalError was); A6E6's Vararg tail and the externref arm's rejection stay untested (no
Int64 program reaches either, MARCH 13.17). A7P9, A7B6, A7E6: the comment and docstrings say what
the code does; A7E5's commit message stays as written (this entry corrects it). A7P10:
type_object_rows follows type_isa's xfail. Batch 90 — A3E6 (reopened by audit #5, A5P5): the arm
in compile_call! that unboxed an operand held as any value at the operator's width, with no class
test, is a located rejection; planted to reject every operand, it leaves the whole smoke corpus
passing, so no case reached it with a class Julia's IR states, and the tail rebox it fed, dead with
it, goes. Smoke narrowed_union_arithmetic pins arithmetic on a value narrowed out of a Union, and
xfail erased_div_any the rejection.

## 2026-10-07 — audited through b62cc656 (18a25734..b62cc656: batches 87–90)

The eighth audit, of the seventh audit's fix batches: 39 findings. Each predicted wrong answer
was measured (native, then wasm): four are wrong answers today, all from one root batch 87 put in.
Its candidates at a position were the closed world's numbered classes alone, and no class is a
`Type{X}`: an ambiguity at a `Type{Int64}` position found no tuple to ask about and ran a row
(native -1, wasm 1; native -7, wasm 1; native -1, wasm 1), and a static parameter a `Type{X}`
argument fixes got no row (native 1, wasm 2). Batch 82's check had rejected the ambiguity.

Area: builder — (A8B1 = A8C1 = A8P1) the wrong answers above. (A8B2) the externref isa arm
lost its rejection for a class whose values are host references, and answered 0. (A8B3) an
Exception-only classId read in that arm was a second path. (A8B4 = A8P10) the writer's group
comparison is untested, and skipped after a direct push. (A8B5) TypeIdentity.tla assumes the
component precondition. (A8B6, A8B7) prose: the type_groups comment, TypeIdentity's class test.
(A8B8 = A8E7) emit_isa_class_header!'s `$JlBase` guard and closure branch are not dart's.

Area: collection and planning — (A8C2) the wrong answer above. (A8C3) the candidate loop's
monomorphic branch still specialized with no static parameter values. (A8C4 = A8P3) the selector
table's `_classid_dispatchable` admitted a String's CodeUnits and SimpleVector (measured: an
internal error planning the module). (A8C5 = A8E4) a String's CodeUnits is decided four more ways,
three by bare name, and its byte-array layout is WT's. (A8C6) a match whose static parameter is a
free TypeVar went to the one-signature branch (measured: rejected). (A8C7) the product ran over
every erased position, unbounded. (A8C8) the 4096 bound is not in the model. (A8C9 = A8P9) a cycle
raised an unlocated ArgumentError. (A8C10 = A8P11) observed classes sorted by string, a second
order. (A8C11) prose.

Area: emission and diagnostics — (A8E1, A8E2) a closure held as its context reaching other class
readers (measured: e1 and e1t answer 1 as native does, e2 rejects; A7S1 carries the root).
(A8E3) the AnyRef isa arm tests numerics, String, Symbol and MemoryRef by layout, a second path.
(A8E5 = A8P4) batch 90 left prose saying the arm unboxes. (A8E6) the externref intrinsic arm
unboxes at the operator's width. (A8E8 = A8C11) prose.

Area: enforcement and prose — (A8P2) nothing pins batch 90. (A8P5) A7C4 and A7C6 have no
behavioral pin. (A8P6) A7B5 and the A7C4 remainder on no Planned row. (A8P7) no Fix=1 method in
Enrollment's instance, so SkipParametric and PerPosition checked one thing. (A8P8, A8P12) prose
and placement.

Resolution: batch 91 (this commit) — model first: Enrollment.tla's values include a type object
with no numbered class, whose dispatch type is `Type{X}`; a method's static parameters name the
positions they fix (PFix, a one-position method included, A8P7); a position's candidates are the
numbered classes and, for a static type that is one dispatch type, that type. The Broken instance
ClassesOnly keeps batch 87's numbered-only candidates, and TLC rejects it with the seven others.
A8B1 = A8C1 = A8P1, A8C2: `dispatch_candidates` (Base.isdispatchelem, else the classes under the
type) gives both the ambiguity search and the parametric product their candidates; a position
with none, or a Vararg one, rejects. A8C6: a match leaving a static parameter a TypeVar is rowed
per candidate. A8C7: the product runs over the positions a static parameter mentions, the others
kept. A8C10: type_order_key. A8C3: the monomorphic branch takes Julia's static parameter values.
A8C4 = A8P3: `_classid_dispatchable` asks is_bare_array_class; the CodeUnits program now traps
instead of failing the plan, and the trap is on MARCH 13.17. A8C9 = A8P9: the cycle raises
_closure_layout_error naming the callable. A8B2, A8B3: the externref arm rejects a class whose
values are host references, and the Exception read goes. A8B6, A8B7, A8B8 = A8E7, A8C11,
A8E5 = A8P4: as found. Smoke dynamic_enrollment gains closure_parametric_type_position and
closure_unbounded_parameter, and test/dispatch_method_error.jl gtam: batch 90's code answers 2,
rejects, and runs a body where native answers 1, 1 and -7. A8P6: A7B5 is on C7's Planned list
(the A7C4 remainder stays with A3S3). Everything else (A8B4 = A8P10, A8B5, A8C4's trap, A8C5 =
A8E4, A8C8, A8E3, A8E6, A8P2, A8P5): MARCH 13.17. Batch 92 — A8E6: the externref intrinsic
arm, planted to raise, left the smoke corpus passing; it unboxed at the operator's width with no
class test and is a located rejection, as A3E6's twin was. A8E3: the AnyRef isa arm's three
layout tests (MemoryRef box, numeric box, the classed string layout) are the one header test, as
in the externref arm; every one of those classes carries the object header. A8C5: one predicate,
`is_string_codeunits`, by Base's typename, answers the four sites that matched `:CodeUnits` by
bare name; the representation itself (A8E4) stays on 13.17. Batch 93 — A6E3: a runtime-length
tuple a PiNode narrows to the NTuple its isa tested it to be is built as that NTuple
(`emit_vararg_to_fixed_tuple!`: the fixed struct, its header classed, its fields read from the
representation's data array), where a cast between the two structs trapped (native 6). Smoke
runtime_length_tuple's isa_narrowed_fields: the old code traps. A typeassert on one still
rejects, its failure's TypeError carrying the value as any value (xfail typeassert_got).
Batch 94 — A8B4 = A8P10: test/module_builder_validation.jl records one group where a module has
two and asks the writer to write it; it refuses (with the comparison planted out, the test
fails). The comparison still skips a module whose types were pushed past the builder, whose
record is incomplete (MARCH 13.17). A8P2: no case can fail without batch 90, since no program
reaches the arm it turned into a rejection: planted to reject every operand, it left the smoke
corpus passing (batch 90's resolution), and the arm it replaced unboxed only operands that reach
it. A8P5: A7C4's change is not observable while the numbered classes include every class a
method's signature names (the A7C4 remainder, with A3S3), and A7C6's is not observable by a
differential case, since the native run creates the MethodInstance with Julia's static parameter
values first and the method cache returns it (audit #8, A8C3); smoke generic_parametric_candidate
documents the call shape.

## 2026-10-07 — audited through d9433740 (b62cc656..d9433740: batches 91–94)

The ninth audit, of the eighth audit's fix batches: 36 findings. Each prediction was measured
(native, then wasm): one wrong answer and one invalid module today. Batch 91 gave a position its
`Type{X}` candidate only when its static type was that `Type{X}`, so a type object reaching an
erased argument found its parametric method without a row (A9C1 = A9P1: native 1, wasm 2), and
batch 93's narrowing read Int8 elements with a plain `array.get`, which the engine refused
(A9B3 = A9E2: native 6, wasm a module that does not instantiate). Enrollment.tla's candidate rule
ignored the static type, so it checked a candidate set the code did not build.

Area: builder — (A9B1) a runtime-length tuple held in a Union slot is tested by its header class
(measured: rejected at its statement). (A9B2 = A9E1) batch 92 dropped the AnyRef arm's rejection
for a class whose values are host references, which then answered 0. (A9B3 = A9E2) the wrong
module above; WT's array_get! did not assert dart's packed rule. (A9B4) julia_numeric_tier's
docstring claimed a rejection those ops never reach. (A9B5, A9B6) quarantine reasons naming WT's
own open defects. (A9B7) a docstring named `_lower_arith!`. (A9B8 = A9P8) an unreachable error().
(A9B9) the type_groups comment.

Area: collection and planning — (A9C1) the wrong answer above. (A9C2) the parametric product is
unbounded beside the bounded ambiguity search. (A9C3 = A9P4) batch 91 turned the CodeUnits
selector-table program's plan failure into a run-time trap (native 100). (A9C4) A7C6 and A8C3 can
be pinned by a test that compiles before the native run. (A9C5 = A9P5) compile.jl's comment was
unchanged. (A9C6) two rules for "one signature". (A9C7) prose.

Area: emission and diagnostics — (A9E3) a PiNode with no local is not built as the NTuple.
(A9E4) a fixed tuple into a slot typed as a runtime-length tuple casts (predates the range).
(A9E5) emit_isa_class_header!'s quarantine was false about dart's type objects. (A9E6) flow.jl's
class test is a second path. (A9E7–A9E9) prose.

Area: enforcement and prose — (A9P2) A8P2's "no program reaches the arm" contradicted batch 90's
xfail, and the xfail lane checks only that a case is loud. (A9P3) A8P5's citation for A7C4 was
false: a program whose ambiguity sits at an unreached subclass compiles today and was rejected by
batch 82's rule (measured: native 3, wasm 3). (A9P6) prose. (A9P9) gtam's message also matches
the empty-candidate rejection. (A9P10) R14 counts placement. (A9P11) a name used twice.

Resolution: batch 95 (this commit) — model first: Enrollment.tla's Broken instance StaticOnly
keeps batch 91's rule (a type object a candidate only where the static type is its `Type{X}`),
and TLC rejects it with the eight others. A9C1 = A9P1: the collector records each type object the
program holds as a value (a literal or constant-global operand whose values are one pointer) and
offers its `Type{X}` at every position that admits it; found while fixing (A9S1), the vtable
pre-pass's ambiguity search had the same blind spot, and the held type objects now reach it
through ClosedWorld and ClosedWorldPlan (L146 restated on the call that passes them). A9B3 =
A9E2: the narrowing reads a packed element signed or unsigned, and array_get! refuses a plain read
of a packed array or a signed read of an unpacked one. A9E1 = A9B2: the AnyRef arm rejects a
host-reference class. Smoke dynamic_enrollment gains closure_type_object_erased and
closure_ambiguity_unreached_class (A9P3, the A7C4 pin), runtime_length_tuple
isa_narrowed_int8_fields, test/dispatch_method_error.jl gdiv (A9P2: the A3E6 arm's own message),
test/module_builder_validation.jl the packed-read check; batch 94's code answers 2 and builds the
refused module, and batch 82's ambiguity rule rejects the unreached-class program. A9B4, A9B7 =
A9E8, A9B8 = A9P8, A9B9, A9C5, A9E5, A9P6's prose: as found. A8P5's A7C4 citation is withdrawn
(A9P3); A8P2 is closed by gdiv. Everything else: MARCH 13.17. Batch 96 — found while mapping
A7S1 (A9S2): `===` on closures compared references. Two closures of one type with equal captures,
erased, answered 2 where native answers 1, and two erasures of one closure with a vtable trapped
(native 1), the per-class rule having no representation for a closure. Model first:
EgalDispatch.tla gains a closure class (two contexts with equal captures, an object wrapping one,
one with other captures) and the Broken instance ClosureByIdentity, which TLC rejects. The runtime
egal unwraps a closure object to its context, retries identity, and compares a closure's classId
and captures field by field; a closure whose type is known is compared as the immutable struct of
its captures. Smoke closure_egal (four cases): the old egal answers 2 and traps twice. Batch 97 —
A9E4: a fixed tuple joining a runtime-length one at a phi (Tuple{E} <: Tuple{Vararg{E}}) was cast
between the two structs and trapped where native answers 7; convert_type! now builds the
runtime-length representation from the tuple's fields (`emit_fixed_to_vararg_tuple!`, the inverse
of batch 93's narrowing), and any other value into such a slot rejects. Smoke runtime_length_tuple
gains fixed_joins_runtime_length and runtime_length_joins_fixed; the old code traps on the first.
A9E3 measured: the audit's program answers 5 as native does. Batch 98 — A7S1, stage 1: a
closure type has one registration, its captured-fields context; register_struct_type! hands a
closure type to register_closure_type!, where a struct field, a tuple element, a constant (Base's
Fix2 and the like) or a local could register it as an ordinary class struct first (a third
layout, decided by registration order). Probes 225/225 and smoke 730/730 unchanged: no case
reached the third layout, so no case pins it.

## 2026-10-07 — audited through f95a1aa6 (d9433740..f95a1aa6: batches 95–98)

The tenth audit, of the ninth audit's fix batches and the first A7S1 stage: 37 findings. Each
prediction was measured (native, then wasm, at f95a1aa6 and at the batch before each change):
seven wrong answers and five traps today. Batch 96's runtime egal read a closure object as its
context before comparing classes, and every function used as a value holds the one dummy context,
so two of them answered equal (A10B1 = A10E1 = A10P1: native 18, wasm 118); its closure list was
taken when the egal function was first built, before a later body registered its context
(A10B3 = A10E2: native 1, wasm 2); it compared a mutable callable's fields (A10B2: native 2,
wasm 1); and a closure captured by another, compared statically, was cast from its object to its
context (A10E3: trap). Batch 98 left an erased closure with no vtable as a context with no class
header, which typeof and the class switch cast (A10C2: native 1, wasm trap), and `isa(x, Fix2)`
of it answered 0 (native 1, before the range). Batch 95's held set took only literal operands
whose values are one pointer: a type object a `typeof` made, a phi or return held, a constant
tuple held, or one tested by type equality was no candidate (A10C1 = A10P2: native 1, wasm 2 or a
trap). Batch 95's narrowing read a Bool element with a signedness of its own rule, which the
builder refused (A10B4 = A10E5), and batch 97's arm built the runtime-length tuple only from a
concrete struct, so a value of any class asserted into one was cast and trapped (A10E4: native 3).

Area: builder — (A10B1–A10B4) above. (A10B5) EgalDispatch.tla had no function used as a value
and no shared context. (A10B6) convert_type!'s new arm decides by type index and builds where
Coercion.tla casts. (A10B7) the egal docstring omitted its closure arm, which had no quarantine.
(A10B8) types.jl's closure comment. (A10B9) struct_get!'s unused signedness.

Area: collection and planning — (A10C1, A10C2) above. (A10C3) no test fails without the held set
in the ambiguity search. (A10C4) the generic-function switch's `Type{X}` row (measured: answers 1
as native does, the held literal enrolling it). (A10C5) Enrollment.tla took every type object as
held, its StaticOnly instance had no static type of one type object, and Cand read the state's
`s`. (A10C6) branches batch 98 made redundant. (A10C7) required `held`, prose, docstrings.

Area: emission and diagnostics — (A10E1–A10E5) above. (A10E6 = A10P7) a phi edge with no Julia
type gets its NTuple from the struct's layout. (A10E7) prose. (A10E8 = A10P5) batch 98 had no pin.

Area: enforcement and prose — (A10P1, A10P2) above. (A10P3) the CodeUnits selector program (A9C3
= A9P4, A8C4's remainder) had no lane case. (A10P4) 13.17's A7S1 stage 2 misstated dart. (A10P6)
isa_narrowed_int8_fields read the same value signed or not. (A10P8) A9S1 stated without evidence.
(A10P9) Enrollment.tla and trimcollect prose. (A10P10) A9P7, cited by C9 and 13.17, was never
named here: it is is_string_codeunits' quarantine reason, which names WT's own representation
(A8E4); A9E7 was resolved with A9B4; A9P5's open parts are A8P8, A8P12 and A8P7's second half.
(A10P11) smoke's comment order. (A10P12) gdiv's message pin matched the externref arm too.
(A10P13) batch 96's probe re-record kept no diff.

Resolution: batch 99 (this commit) — models first. EgalDispatch.tla gains two functions used as
values sharing the dummy context and the Broken instance UnwrapFirst; Enrollment.tla a constant
of the type objects held as literals (the rest a `typeof` makes), the Broken instance
LiteralsOnly, a static type of one type object, and Cand over its own S; Coercion.tla a fixed
tuple and the runtime-length tuple, their build and narrowing arms, the claim NoTupleCast and the
Broken instance CastTuple. TLC rejects each new Broken instance and passes each model. A10B1: a
closure object whose context is the dummy stays whole, compared by its classId. A10B2: a mutable
callable by identity. A10B3 = A10E2: `fill_egal_function!` fills the egal body after codegen,
refilling until the registries stop growing; a use after the fill raises. A10E3: a closure held
in a wider slot goes to the runtime egal. A10C2: batch 98's redirect is reverted (two layouts
again, A7S1); the class read (`emit_class_id!`, which typeof now reads through) and the abstract
isa test a closure context's field 0. A10C1 = A10P2: the held set takes every type object a
literal or constant global holds (in a statement, phi, π, upsilon or return, and inside a
constant tuple or immutable struct) and the `Type{C}` of each class a `typeof` operand may be; a
`Type{X}` tested by type equality then rejects the callable. A10B4 = A10E5:
packed_array_signedness. A10E4: `_narrow_ref!` builds the runtime-length tuple from whichever
fixed NTuple class the value is. Found while measuring: the CodeUnits selector program trapped
because a tuple field of CodeUnits type had a class-struct layout and the narrowing read an erased
CodeUnits as a String (A8C4's remainder: now native 100, wasm 100); and an abstract Vararg tuple
(`Tuple`) raised a WasmInternalError registering a layout, and now has none, so its statement
rejects. Smoke gains closure_values (11 cases), codeunits_values (3), type_object_rows' typeof,
unsigned and constant-tuple rows, runtime_length_tuple's Bool, value-edge and erased-assert cases,
and the xfail abstract_tuple_values; test/dispatch_method_error.jl
gtu (a held UnionAll rejects) and gtn (A10C3 = A10P8: without the held set the search rejects the
call as ambiguous, measured). Negative tests: the old egal answers 118, 2 and 1 and traps; the
held set without typeof results and composites answers 2, 2 and traps; the mutable rule removed
answers 1. Probes: five string probes change, the same types renumbered and the egal function's
dummy-context test (diff kept, resume-notes/b99). A10B6, A10B7, A10B8, A10B9, A10C5, A10C7, A10E7,
A10P4, A10P6, A10P9, A10P10, A10P11, A10P12, A10P13: as found. A10C4: measured right. A10C6:
batch 98 reverted, the branches are A7S1's. A10E8 = A10P5: smoke closure_in_field. Everything
else (A10E6): MARCH 13.17. Batch 100 — A7S1, stages 2 and 3 as Julia's
value semantics allow: every closure context erased into a slot of any class becomes its object
(maybe_wrap_closure!; a closure no dynamic call reaches gets the empty vtable,
get_empty_closure_vtable!), including a heterogeneous tuple's field read at a run-time index,
which pushed the context bare; a narrowing to a context unwraps an object whether or not the
module has vtables. With no context left at an erased position, the class read, typeof, isa and
the class-header test lose their context alternatives, and register_struct_type! sends a closure
type to its context again (batch 98's one registration, now safe). Smoke 750/750 and probes
225/225 unchanged; with the context wrap removed, closure_values' typeof_erased_fix2,
typeof_erased_fix2_held and isa_erased_fix2 trap or answer 2. Batch 101 — A7S1 stage 4: a closure passed to an
erased closure call trapped where native answers 4, twice over: the callee, a capture-less
closure the program passed on only as a literal operand, was never observed as a callable (no
row, no object), and the trampoline cast the argument's object to its context. The collector now
observes a function held as a literal or constant operand as it observes one an SSA type names,
and the trampoline reads an object's context (field 2), as dart's direct closure call does.
Smoke closure_values gains closure_argument_erased_call and fix2_argument_erased_call; with the
trampoline unwrap removed both trap, and batch 95 and 99 trap on both. Batch 102 — A10E6 = A10P7:
a constant tuple states its type at a phi edge (_value_julia_type), as Julia's IR does, and
convert_type!'s fixed-to-runtime-length arm takes the edge's type only; the guess from the
struct's layout is gone, and an edge with no type rejects. Without the stated type, smoke
varargs/splat_vararg_nonempty rejects. Batch 103 — A3S1: a dynamic call with no method for
its argument's class trapped where Julia throws a MethodError the program catches (native -1,
wasm trap; measured on Julia's union split `Core.throw_methoderror(f, x::Any)`, a closure's
vtable entry and the class switch). Model first: ClassIdSwitch.tla's no-row outcome is the
MethodError, its args the value's class, with the claims ErrorIsJulias and
ThrowWhereJuliaThrows and the Broken instances TrapNoMethod and StaticArgs. The collector
numbers the args tuple of each no-method call (a union split's open position over the classes
under its static type; the candidate tuples a closure or generic dynamic call has no method
for, and the callee's class), and each no-row path builds `MethodError(f, (args...,), world)`
from the class it reads. Smoke method_error (7 cases): with the builders removed all trap.

## 2026-10-07 — audited through 623f19dc (f95a1aa6..623f19dc: batches 99–103)

The eleventh audit, of the tenth audit's fixes, A7S1's stages 2–4, A10E6 and A3S1: 36 findings.
Each prediction was measured (native, then wasm, at 623f19dc): five wrong answers, three traps,
an invalid module and an internal error. Batch 100 removed the class reads' context alternatives
on the claim that no bare context reaches an erased position, which is false: a vtable entry's,
a dispatch wrapper's and the class switch's result passed a closure's context on bare, so an
erased closure returning a closure answered `isa Function` 2 (native 1) and trapped when called
(A11E1). Its wrap and redirect also took in mutable callable structs: `===` compared two fresh
objects (A11B1 = A11E3: native 1, wasm 2, three programs) and a field write built a module that
does not validate (A11C5). The held set left out a type object a mutable constant holds (A11C1:
native 1, wasm 2) and the kind a `typeof` of a type object returns (trap). A null `nothing`
reaching a MethodError arm trapped at the class read (A11E2 = A11B2 = A11C4), and a tuple holding
`nothing` raised a WasmInternalError (found measuring A11C4; also batch 101's `iterate(::Int64)`).

Area: builder — (A11B1) above. (A11B2) above. (A11B3) a coercion that states no Julia type left
a context bare. (A11B4) the MethodError builders' anchors. (A11B5 = A11E6) the empty vtable's
raw-byte initializer. (A11B6) fill_egal_function!'s quarantine names WT's lazy registration.
(A11B7, A11B8) one consult and second paths. (A11B9) struct_get! did not reject a packed field.
(A11B10) prose. (A11B11) a second signedness rule (calls.jl, outside the range).

Area: collection and planning — (A11C1) above. (A11C2) the closure no-method product drops its
tuples past 4096. (A11C3) builtin operands and constant composites are not observed callables.
(A11C4) above. (A11C5) above. (A11C6) the held set's typeassert operands reject a correct
program. (A11C7) one fact, several paths.

Area: emission and diagnostics — (A11E1) above. (A11E2) above. (A11E3) above. (A11E4) codegen
asks the method table again. (A11E5) anchors. (A11E6) the raw initializer. (A11E7) the
heterogeneous tuple read keeps its own ladder. (A11E8, numbered A11P1 in that report) batch
103's "each no-row path" and batch 100's "no context left" are false: the selector table and dispatch wrapper still
trap, and three result seams passed contexts bare.

Area: enforcement and prose — (A11P1) ClassIdSwitch.tla took every args tuple as numbered.
(A11P2) "the gate runs what CI runs" overstated it: no WT_VALIDATE, a commented-out lane passed
L153, a `JULIA=` run skipped 1.13 and stayed green. (A11P3) batch 101's internal error was not on
MARCH. (A11P4) isa_narrowed_int8_fields' answer equalled its else branch. (A11P5) lanes.sh's "~2
minutes". (A11P6) Enrollment's LiteralsOnly behaved as ClassesOnly. (A11P7) EgalDispatch's correct
branch is Julia's answer, not the code's rule. (A11P8) anchors. (A11P9) stale MARCH text and an
order contradiction. (A11P10) ClassIdSwitch's Static was a class with a method.

Resolution: batch 104 (this commit). A11E1: emit_context_object! makes a context its object at
each result seam outside a body (the vtable entries, the dispatch wrapper), the class switch's
result goes through the funnel, and _emit_closure_object! is the one construction
(emit_closure_wrap! uses it; closure_vtable_global the one vtable lookup). A11B1 = A11E3: `===` on a
mutable callable takes the runtime egal (its contexts by identity). A11C5: a mutable callable's
context fields are mutable. A11C1: the held set follows every value a constant reaches through an
array, a Memory or a struct's or tuple's fields, mutable ones included, each mutable object or array once (an
immutable one once per path, recursively, until batch 109's worklist; A12C1). It skips a module and Core's
TypeName, MethodTable, TypeMapEntry, TypeMapLevel, Method, MethodInstance, CodeInstance, CodeInfo,
Binding and SimpleVector: none is a value a program reads out of a constant, walking them reached
the whole method graph, and a constant SimpleVector does not compile yet (MARCH 13.17 A11C9); a
walk past 10^6 objects raises. It holds the kind of each type object a value may be where a `typeof`
can return one. A11E2 = A11C4: emit_class_id! reads Nothing's id for a null where the static
type admits Nothing (dart's null branch before loadClassId), and the closure entry's MethodError
test reads a null as `nothing`. The tuple with `nothing`: a Nothing field holds the Nothing
singleton (its class struct was a type no value has), `nothing` is built as that singleton, and
the dynamic tuple read converts into a nullable box. A11B9: struct_get! rejects a packed field.
A11B11: packed_array_signedness. Models: ClassIdSwitch.tla gains Unnumbered, pinned by the Broken
instance MCClassIdSwitchUnnumberedBroken (an args tuple numbered no class traps, which the
unchanged ThrowWhereJuliaThrows rejects: the open A3S1 defect), and a Static outside the classes;
Enrollment.tla a literal type object U with a method it fixes. A11P2: the suite lane runs
validated, L153 reads lanes.sh's code without its comments and states what stays CI's (the 1.13
suite, three platforms, the deep TLC), a `JULIA=` run fails the gate. A11P4: Int8[-n, 2, 5].
A11P5: lanes.sh's time. A11P8 = A11B4 = A11E5: dynamic_dispatchers.dart:178 _generateMethodCode.
A11P9: MARCH. A11P3: the internal error is fixed (the tuple with `nothing`). A11E8 = A11B10:
batch 103's sentence holds only for the union split's throw, the closure entry and the class
switch (the selector table and the dispatch wrapper still trap, MARCH 13.17 A3S1); batch 100's
"no context left" was false until this batch's result-seam wrap; A10B3's "a use after the fill
raises" holds for a first use, a later one reusing the filled index. A11B3: a context with no
stated Julia type rejects at its statement instead of being guessed from its layout (no program
reaching it was found). Smoke gains
closure_values' closure_returned_erased and the four mutable_callable cases (identity, captured,
field_write, held_in_closure), method_error's two
`nothing` cases, type_object_rows' mutable-constant and typeof-kind rows; batch 103's code answers
2, traps, fails validation or raises an internal error on each. Probes 225/225 unchanged.
Everything else (A11E1's dynamic call of a closure created elsewhere, A11C2, A11C3, A11C6, the
c1b-class kind rows, A11P7, A11E4 = A11B7 = A11C7, A11B8, A11E7, A11E6 = A11B5, A11B6, Nothing's
three layouts): MARCH 13.17.

## 2026-10-08 — audited through eb412a31 (623f19dc..eb412a31: batches 104–108)

The twelfth audit, of the eleventh audit's fixes, C0's locks, three models brought to the code,
the else-less if, and the export entry: 31 findings. Each predicted wrong answer was measured,
native then wasm, at eb412a31 and again at 623f19dc. None is new to the range: an undefined
element read as `nothing` (A12E1: native -1, wasm 2), a function singleton crossing a vtable
result seam (A12E2: trap, native 18), and an escape that is not the tag leaving a catch's entry
(A12B1 = A12C4 = A12E3 = A12P1: after a stack exhaustion inside a catch, the next export's
`rethrow()` answers 1, native 2) answer the same at both commits. What the range did break:
batch 104's walk of the constants recursed per path and without a depth bound (A12C1: a 10^6
chain overflowed the stack inside it), batch 106 weakened a positive claim to fit the code
(A12P4), batch 108 dropped half of A3B15 unfixed (A12B2 = A12P3), and the range's prose claimed
more than its code does (A12C2, A12E6 = A12P11, the export entry's scope). H5, which batch 108
introduced and recorded, is not reachable from WT's own imports; A12P2 shows its planned fix
unsound.

Area: builder — (A12B1) above. (A12B2) above. (A12B3) a function's name has three sources and
the export is decided twice. (A12B4) the MethodError builders' anchors lack the quarantine of
their per-class tuple selection. (A12B5) signedness and storage spell the packed types twice.
(A12B6) the packed-storage test is spelled five times.

Area: collection and planning — (A12C1) above. (A12C2) P4's restatement says "unreachable" where
the evidence shows "not observed". (A12C3) the walk's arms have no case. (A12C4) above. (A12C5)
the export repoint is a post-hoc rewrite of every export.

Area: emission and diagnostics — (A12E1) above. (A12E2) above. (A12E3) above. (A12E4) the
export decided twice (with A12B3, A12C5). (A12E5) the export-escape test pins half the claim.
(A12E6) ExceptionStack.tla's header states a linked cell and julia.h's analyzer lines. (A12E7) a
null is `nothing` by two rules. (A12E8) maybe_wrap_closure!'s rejection is reached by no case.

Area: enforcement and prose — (A12P1) above. (A12P2) the planned H5 landing push by `ref.eq` is
unsound. (A12P3) above. (A12P4) RejectOnlyWhenAmbiguous was weakened by `\/ Unaskable`, and the
bound's message says Julia throws MethodError where no tuple need be ambiguous. (A12P5) a
ratchet missing from the baseline passed at any count. (A12P6) the gate passed green while it
skipped the formal, probe and coverage lanes. (A12P7) no case calls an export re-entrantly.
(A12P8) a Broken instance passed on any violated invariant, TypeOK included. (A12P9) L154's ID
regex missed L8, L11 and three unnumbered findings. (A12P10) A11P3's iterate fix had no case.
(A12P11) stale prose. (A12P12, the report's note) L129 counts lines, and 13.17 is one line.

Resolution: batch 109 fixes what the range broke. Found by CI after the audit, and first: batch
108's export entry trapped in every shard on Node 22 (V8 12.4 traps entering a try_table with a
concrete reference result); its try_table is result-less now, L155 keeps every one so, and the gate runs
CI's Node (lanes.sh reads ci.yml's node-version; L153). A12C1: the walk is a worklist over addresses,
each heap object once and kept alive for the walk, counting every heap object it visits but type
objects and the skipped kinds (and each fresh box getfield or getindex makes of an inline
immutable), raising past 10^6 an error (hold!'s `error`) that _compile_module_trim reports as a
WasmInternalError naming the statement holding the constant (a direct collect_closed_world caller
sees the ErrorException); the 10^6+1 chain now rejects there, and the DAG's remaining
hang sits in _collect_reachable_ir_types (value!, contents!), which hung at 623f19dc too (13.17). A12C3: cases for
the field, Memory and cycle arms and for the bound, each negative-tested. A12P4: the claim is
restored; today's code past the bound is MCEnrollmentBoundOverRejectBroken.cfg (module MCEnrollmentBoundOverReject.tla), pinned to A8C8
(13.17), and the message names the overlap it cannot ask about. A12P5, A12P6, A12P8, A12P9: the
locks fail on each hole (negative-tested). A12P10: smoke iterate_held (623f19dc: an internal
error). A12B4, A12B5, A12C2, A12B2 = A12P3, A12E6 = A12P11 and the export entry's scope: the
prose and the one rule. Everything else is on MARCH 13.17: the export boundary for every escape,
model first, as batch 110 (A12B1 = A12C4 = A12E3 = A12P1, A12P2, A12P7 = A12E5, A12B3 = A12E4 =
A12C5, H5); A12E1, A12E2, A8C8 and A12C1's remainder (C3 C6); A12E7 and A12B6 (C1); A12E8 (C5);
A12P12 (C9); A3B15's global names. Found writing A12C3's cases and measured at batch 109: a
constant Memory{Any} the program indexes raises a WasmInternalError (A12C6), and a cyclic mutable
constant rejects at its statement (A12C7): both on 13.17 (C3 C6).

## 2026-10-08 — audited through 8bc17d65 (eb412a31..8bc17d65: batches 109–111)

The thirteenth audit covers:
- batch 109, the twelfth audit's fixes. The first reports left it out, and a second pass audited
  it (A13P2);
- batch 110, the export boundary for every escape;
- cac9d64b, the formal lane sharded;
- batch 111, the trim deleted and one edge enumerator, and 8bc17d65, the gate stopping at its
  first red lane (its lanes.sh is the one the reports read).

It made 27 findings on batches 110–111, read at batch 111's staged tree (5ca3f2d0), and 22 on
batch 109, four of them one finding seen from two areas, plus one outside the range. Batch 111's
commit took eight fixes before it landed. Two findings broke something:
- A13C1. Batch 111's rule that every candidate is a dispatch root hid a statically invoked method
  from its caller. The `:invoke` rejected where native answers 29. This was predicted, then
  measured with the smoke case.
- A13E1. Batch 110 claimed A12B1 closed. V8's stack-overflow RangeError is uncatchable by wasm, as a
  trap is, so the entry's catch_all_ref never runs for it. Only the next top-level call's reset
  clears the stack, and inside a host-declared import or a re-entrant call the reset does not run.
  Measured, natively and in wasm on Node 22: the import variant, `a(1)` then `r(0)`, native 2, wasm
  1 at the head and 1 at c7f0c250; the re-entrant variant, `o(1)`, native 1, wasm 2 at both. So
  batch 110 regressed nothing: it fixed the top-level shape and claimed the other two.

The rest of the range is prose that claims more than the code does, locks with holes, and one
invalid module the builder accepts.

Area: builder — (A13B1) The export entry keeps its results in locals across its try_table. A
non-defaultable result makes a function the engine rejects, and the builder accepts it, because it
does not track local initialization (dart: instructions.dart:215-219, :382-410). (A13B2) catch_ref
and catch_all_ref deliver a nullable exnref; dart and the spec deliver `(ref exn)`. (A13B3) L101
counts a catch clause by its three constructor names only, so a new builder constructor passes it.
(A13B4) try_table checks a catch's types only in reachable code. (A13B5) "The inner keeps the
export's name" is false for a hook export. Batch 109: (A13B6) A13B1's origin is batch 109's
result-less try_table, reachable at c7f0c250 through an existing_module's or a hook's export of a
function with a `(ref $t)` result. (A13B7) L155 scans text, so `try_table!(b, cs; results)` and
`inputs=` passed it, and the builder accepted what L155 forbids. (A13B8) Two sites say "a
reference" where only a concrete reference traps.

Area: collection and planning — (A13C1) above. (A13C2) The post-codegen repoint batch 110 called gone
still retargets a hook's export, and the entry was named before the export was renamed, so
"esc (export)" could be exported as "esc_d2". (A13C3) functions.dart:178 was cited as parity for
exporting every function a compile defines; dart exports only a wasm:export member. (A13C4) Three
sentences were false: L78's "protected roots", smoke's "on 1.13" for `:invoke_modify`, and entry 12's
A12C1 sentence (hold! raised an ErrorException that _compile_module_trim wrapped). (A13C5)
invoke_seen never gains a later round's merged MethodInstances. (A13C6) The `:new` edge is gated on
a version number. Batch 109: (A13C7) past hold!'s bound, WT's own, the rejection was a compiler
bug at no statement, and its test was retargeted after its recorded negative. (A13C8) Why
ambiguous_class_tuple answers nothing had three spellings, and the message named causes that need
not hold. (A13C9) "10^6 heap objects" also counts fresh boxes. Outside the range: (A13C10)
`contents!` stops silently past 4096 objects.

Area: emission and diagnostics — (A13E1) above. (A13E2) No test failed when emit_direct_call!'s import
count or a region enter's save of it was reverted; Julia's J2, a re-entrant callee reading its
caller's stack, had no case. (A13E3) "catch_all is the only wasm construct that observes a foreign
unwind" is false: dart catches the imported WebAssembly.JSTag (tags.dart:45; code_generator.dart:1030,
:1160), and a Julia `finally` does not run on a host import's JS exception, where dart's does.
(A13E4) The import at a function index is computed a third time. (A13E5) One Dict holds two facts,
told apart by the key's sign. (A13E6) A function exported under two names gets two entries. Batch
109: (A13E7) dart2wasm emits only legacy exception handling (code_generator.dart:945 try_legacy,
:999 catch_legacy); WT's try_table lowering is a C2 divergence and the root of the Node 22 trap L155
works around, with no anchor. (A13E8) MARCH stated the trap contract as Julia's behavior ("as
Julia's task would be dead"); where WT traps, Julia often raises a catchable error. (A13E9)
get_array_type!'s docstring documented packed_array_storage.

Area: enforcement and prose — (A13P1) H9's row cited the `:new`-built 1.13 bodies, which its model
counts as reachable. (A13P2) The audit's range started at c7f0c250, leaving batch 109 unaudited.
(A13P3) No lock held the premise that every host-import call is counted. (A13P4) Batch 111 changed
the dynamic step before its model. (A13P5) The nightly formal run started three full jobs.
(A13P6) H10 was not reproduced. (A13P7) The models and 13.17 narrate batches and cite files outside
the repository. (A13P8) `_closed_world_edge` claimed Julia's queue's operand types but uses WT's
join, and L49 pins that join as text. (A13P9) The export-boundary test asserts H8's RangeError as a
pass, with no citation. (A13P10) README's Broken definition and TrimDrops's flags. Batch 109:
(A13P11) three Broken instances expect a claim other than the one each variant breaks, so
NoPartialIntern, NoFabrication and FailureIsLoud had no Broken instance. (A13P12) Enrollment's
BoundIsLoud and RejectOnlyWhenAmbiguous cannot hold together at the bound. (A13P13) run_tlc.sh
accepts `expect: TypeOK`. (A13P14) run_tlc.sh passes `-deadlock`, which disables deadlock
checking. (A13P15) H5's sentence describes the ref.eq landing as the fix. (A13P16) L155's scan gaps
(with A13B7). (A13P17) ExceptionStack.tla says a stack travels with its value, false for
`rethrow(e)`. (A13P18) _read_baseline keeps the last of two duplicate keys. (A13P19) The gchn test
does not check that the error names gchn or its statement, and entry 12 says the walk counts type
objects.

Resolution:
- In batch 111's commit, before it landed:
  - A13C1: an `:invoke` takes the function its MethodInstance compiles to when signature lookup
    misses. Smoke closed_world_edges static_and_dynamic_call_one_method passes on 1.12 and 1.13 and
    errors without the line. The callee still has two derivations; the one path, the callee from
    the MethodInstance first, is 13.4's item (A13C1);
  - A13P1: H9 restated to the widened-original shape its model pins, with the 1.13 bodies named by
    their edge;
  - A13P4: the commit message states the order;
  - A13P6: H10 withdrawn. Four shapes on both versions reject at their statement, and smoke gains
    finalizer_registered;
  - A13C4: L78 and smoke's comment;
  - A13P8: the docstring names `_call_site_arg_type` where Julia reads argextype. The remainder is
    on 13.17 beside A3C1;
  - A13P10: README and the TrimDrops header.
- In cac9d64b, amended: A13P5. A scheduled run has one empty shard.
- Already fixed when audited: A13P15 (batch 110 removed the ref.eq clause with H5).
- Batch 112 fixes the rest of what the range broke:
  - A13E1: the false closure is re-opened as 13.17 A13E1 (C3 C6), model first. ExceptionStack.tla
    gives stack exhaustion its own kind, uncatchable by wasm, and the host keeps the instance,
    unlike a trap. MCExceptionStackExhaustImportBroken and MCExceptionStackExhaustReentrantBroken pin
    the residual, and every positive instance holds top-level exhaustion. The docstring, H8 and the
    model's header are corrected. The fix, the count kept host-side by the generated glue, is the
    row's, with A13E7's port;
  - A13E2: real_bottom_exceptions.jl gains J2 (`o`, native 1: 2 with the count reverted) and the
    save case (`o2`, native 1: 2 with the enter's save reverted). The planned save case (`cb2`,
    then `tp` and `r`) could not see the revert: Julia deleted the call of a stub it inferred
    effect-free, and the next region's landing restores its own save, so the count healed before
    `r`. The case now calls `cbr` inside the same catch;
  - A13E3: the quarantine and L101's reason say what catch_all_ref observes and what dart does.
    Adopting JSTag is 13.17 (C2 C6);
  - A13C2: the entry is named by the export's final name (`esc_d2 (export)`, tested), and the namer
    runs before the export and its entry are made. The comment states the hook export's retarget.
    The hook requesting its exports is 13.17 (C1);
  - A13C3: the anchor stays on what it supports, and exporting every function is 13.17 (C2);
  - A13B1 = A13B6: an export whose result is not defaultable rejects, naming the export (tested;
    without the check the module is invalid, "uninitialized local"). The builder gains
    `defaultable` (type.dart:233). Dart's local-initialization tracking is 13.17 (C7);
  - A13B3: L101 counts a clause built from its opcode in src/builder too, catch_all_ref_clause's
    body the one allowed site;
  - A13P3: L156 (C6). test/utils.jl's uncounted_host_import_calls reads a module's code and counts
    each call of a host-declared import that is not counted; the boundary module and host_imports.jl's
    module assert 0. One call site routed raw reads 7 and 1;
  - A13B7 = A13P16: try_table! refuses inputs and results however the keyword is spelled; L155
    pins the check, counts an InstrIR.TryTable built in codegen, and scans for `inputs` and the
    shorthand;
  - A13E7: L155's reason names the divergence and 13.17's row (C2 C6). The port to dart's legacy
    form, model first and with A13E1's fix, is batch 112b, before any C10 batch;
  - A13C7 and A13P19: past the bound the walk rejects with a WasmCompileError at the statement
    holding the constant, located as a codegen rejection is (`_held_bound_rejection`; L118 lists
    it as an exact site). The gchn test asserts the class, gchn and its statement, and fails with
    the bound raised;
  - A13C8: ambiguous_class_tuple returns its reason and the message prints it. A new case, gamn,
    reaches the no-candidate reason (native 3; WT rejects, A8C8);
  - A13B5, A13B8, A13C9, A13E8, A13E9, A13P9: prose; entry 12's A12C1 sentence (A13C4) and its
    counting wording (A13P19);
  - A13P11, A13P12, A13P13, A13P14 and A13P17: the models and run_tlc.sh. Each Broken instance's
    expect line is its own claim (SkipChild at N = 2; Fabricate and Swallow as dedicated
    instances). The pinned Enrollment instance says the bound's two claims conflict at an
    unambiguous pair past the bound, so A8C8's fix must restate BoundIsLoud (on its row).
    `expect: TypeOK` is refused. run_tlc.sh no longer passes `-deadlock`: 26 instances then
    reported a deadlock, each a finished state, and each model got a stutter guarded by exactly
    that state. The stack slot is stated as abstracted. TypeIdentity, the one model with no
    TypeOK, gains one, checked by its five cfgs (negative recorded);
  - A13P18: a duplicate baseline key fails loudly;
  - A13P2: this entry starts at eb412a31, and batch 109 is audited.
  Each lock and case was negative-tested. Probes 225/225 unchanged.
- Everything else is on MARCH 13.17: A13B2, A13B4, A13C5, A13C6, A13C10, A13E4, A13E5 (filed
  under C1; a C4 finding), A13E6, A13P7, and the remainders named above.

## 2026-10-09 — audited through f071e55a (8bc17d65..f071e55a: batches 112, 112b-1, the gate, 113)

The fourteenth audit covers:
- f36d346d, batch 112, the thirteenth audit's fixes;
- 8ed47881, batch 112b-1, the export boundary as the host's glue;
- f490f693, the gate on CI's runners;
- f071e55a, batch 113, every function named, one compile entry, every Julia offset mapped, read at
  its reviewed tree (c3f1c3a4).

It made 29 findings, one of them seen from two areas (A14E1 = A14P1). Three were silent wrong
answers, each measured at the start on Node 22.23.3:
- A14C1. With the module exporting "x", the compile's "x" was renamed "x_d2", and the entry
  requested as "x_d2" became "x_d2_d2": exports.x_d2(2) answered 3 where native answers 20.
- A14C2. An import_stubs index that names no import bound the stub's calls to the function at that
  index: native 4, wasm 0, the module valid (at a recursive index, stack exhaustion). Outside the
  range: the check has returned quietly since before it.
- A14E1 = A14P1. The glue's count is the glued object's, not the instance's. After `o(0n)`, a host
  that called the glued `cbr` itself got `r`'s 1 where Julia's top-level call answers 2; two
  instances of one glued object, A's import calling B's `r`, answered 1, or trapped on B's null
  array.

Area: builder — (A14B1) Two writers recorded a body's unmapped end: builder_code_mapped and a
conditional append in the code-section writer (dart has one, instructions.dart:78). (A14B2) The
import-order quarantines gave WT's eager numbering as their reason, a WT choice open on A3B16, not
a Julia necessity. (A14B3) add_function! and WasmFunction accepted `name=""`, which the
name-section writer then dropped silently: L157 held by spelling. (A14B4) `defaultable` had no
caller. (A14B5) try_table!'s comment derived a block type from inputs and results it refuses, and
its CATCH_REF and CATCH_ALL_REF arms type clauses no constructor builds, so A13B2 described an
unreachable path. (A14B6) add_function!'s docstring said dart names every definition; its
cross-module global getter and setter are unnamed (globals.dart:52, :79).

Area: collection and planning — (A14C1) and (A14C2) above. (A14C3) The constant walk's 10^6 bound
counted every constant together and blamed the statement that crossed the running total. (A14C4)
The imported-global refusal refused every imported global, where its quarantine justifies only the
count, and the imported-root refusal's case passed without its guard. (A14C5) compile_module kept a
public docstring as a second entry, and options.jl named a compile_with_base that no longer sets
OPTIONS[]. (A14C6) Two naming comments in compile.jl were false.

Area: emission and diagnostics — (A14E1) above. (A14E2) A closure trampoline was named by its full
printed type, unbounded. (A14E3) `_stmt_line` and `_nir_lines` kept the backward walk the source
map's decoding dropped, two rules for one fact. (A14E4) A function's definition came from two
sources. (A14E5) A stackified.jl comment called a recomputed statement unmapped. (A14E6) A
GENERATED_CONSTRUCTS anchor named a local function's symbol path wrongly, and
host_imports_open_global! kept a mutator's `!`.

Area: enforcement and prose — (A14P1) = A14E1. (A14P2) L156's "every host-import call is saved and
restored" was checked on two modules only. (A14P3) The imported-root case passed without its guard
(with A14C4). (A14P4) L157 counted `name=` by text. (A14P5) C10's Planned cited 13.15 for an item
13.15 did not hold. (A14P6) ExceptionStack.tla cited a deleted row. (A14P7) L158's "typed"
keywords: `optimize` had no type. (A14P8) located_frames called a host-built function's frame "a
statement with no source location in Julia's IR". (A14P9) gate.yml and run_tlc.sh described the
TLC dealing two ways. (A14P10) 13.17 kept A13E8 with no open work, and the trap-discard policy was
stated nowhere a host reads. (A14P11) 13.17's A3B15 and A13P7 rows were stale.

Resolution:
- In batch 113's commit, its own changes, before it landed: A14B1, A14B3, A14C5, A14C6,
  A14E2-A14E6, A14P3-A14P9 and A14P11.
- In batch 114 (the commit carrying this entry), each case run at the start first:
  - A14C1: the export names are decided together. A requested name the module already exports is
    refused, as are two entries requesting one name and one entry requested under two names; a
    name nobody requested is disambiguated past every name already taken or decided;
  - A14C2: a stub whose index is not a host-declared function import is refused, naming the stub;
  - A14E1 = A14P1: model first. ExceptionStack.tla gains HostCallsGlued, and
    MCExceptionStackHostCallsGluedBroken violates Agrees; the design instances are unchanged. The
    glue hands each wrapped import and the count out once, to the instantiation that reads them,
    and a second read throws, naming the import, so one glued object serves one instance and the
    host never calls a glued import;
  - A14C3: the bound counts one constant's own objects (two constants of 999,995 and 10 nodes
    plan; the second was rejected);
  - A14C4: the refusal is narrowed to the count, and a global the host imports for itself is read
    and written (a case); the imported-root case asserts its own text;
  - A14P2: every module the suite builds with import_stubs asserts the count of unsaved calls is 0
    (seven more), and L156 counts them;
  - A14P10: host_glue_js's and host_runtime_js's docstrings state the policy; A13E8 leaves 13.17;
  - A14B2, A14B4, A14B5 and A14B6: the quarantines name A3B16, `defaultable` is deleted, the
    try_table! comment is true and A13B2 is restated as the arms' deletion, the docstring is true.
  The cases of A14C1-A14C4 and A14E1 failed at the start and pass, each reverted fix failed its
  case again, and L156's extension was negative-tested; the probes change only by batch 114's
  exported class reader.
- Everything else is on MARCH 13.17 under its row: none of this entry's findings.

## 2026-10-11 — audited through 685c1b93 (f071e55a..685c1b93: batches 114, 112b-2, 115a, 115b, 116a)

The fifteenth audit covers:
- 92527cc1, batch 114, the fourteenth audit's fixes;
- bd40fafe, batch 112b-2, Julia's try regions in dart's legacy form;
- 3f062ec8, batch 115a, every instruction typed as dart types it;
- 3ceb2065, batch 115b, every body a builder the module made;
- 685c1b93, batch 116a, the plan as the one consult, read at its reviewed tree (ebdb70b0).

It made 28 findings, two of them seen from two areas (A15C3 = A15P2, A15C6 = A15P3). One was a
silent wrong answer, measured on Node 26.11.0:
- A15E1. Julia's JL_CATCH restores the exception stack only after the host's catch block
  (julia.h:2555); WT's export entry starts as after the restore. With the host calling `r` from
  inside its catch of `b`'s escape, `rethrow()` in `r` answers 2 where native answers 3; with the
  import calling `r` inside its catch of a re-entrant escape, `o(1)` answers 1 where native
  answers 3. Outside the range (batch 112b-1); audit #14's check of the entry missed it.
One was an unlocated internal error: A15C1, a callable whose methods are overlays called as a value
raised from the vtable pre-pass's ambiguity check.

Area: builder — (A15B1) The builder recorded dead code unchecked, where dart's `_add` drops every
instruction emitted while unreachable (instructions.dart:363-368): `unreachable; f64.const 0;
i32.eqz; drop` built, and only wasm-tools rejected it; OperandStack.tla claimed soundness only where
reachable. (A15B2) 161 codegen sites pushed onto the locals list the builder shares, beside
builder_add_local!'s type check. (A15B3) append_builder! accepted a parameterless fragment sharing
its function's locals, typing local k by the wrong list. (A15B4) trunc_sat! accepted any FC
sub-op, encoding memory and table instructions it does not type; STRUCT_GET_S/U arms were dead.
(A15B5) The name section skipped an unnamed import silently. (A15B6) add_minified_class_names
re-parsed the map WT had just written (dart adds the names before encoding), and the JSON reader's
quarantine gave a dependency choice as its reason. (A15B7) global_get!'s globals.dart:56 citation
and the validator's "i64 family" comment were false.

Area: collection and planning — (A15C1) above: the pre-pass asked Base's isambiguous where an
overlay method lies in the intersection. (A15C2) entry_method_instance and the enrollment sites
specialized with an empty svec, not Julia's match. (A15C3) "codegen asks no method table" was
false (closed_world_call_result asks it). (A15C4) An import stub's MethodInstance was derived a
second time at codegen. (A15C5) The consult's docstrings stated an order the overlay table does
not give. (A15C6) The per-callee no-method record was called pinned by a behavior no answer shows.
(A15C7) The plan dropped a rooted lowering callee silently.

Area: emission and diagnostics — (A15E1) above. (A15E2) compile_invoke! kept a self-call arm,
_closure_body_for a julia fallback, and dispatch.jl indexed functions by the import count.
(A15E3) The exported class reader trapped on an escaped type object, where Julia names its kind
(DataType). (A15E4) A second compile into a module compiled from exception-free code failed at its
end, on a duplicate `wasmtarget.class_id` export, not at its entry. (A15E5)
generate_selector_caller_body!'s type_registry had a `nothing` default.

Area: enforcement and prose — (A15P1) L156 pinned a count of assertion texts: five modules built
with import_stubs went unasserted (two in real_bottom_exceptions.jl, source_maps.jl's two host
modules and its later-round one), so A14P2's resolution was false. (A15P2) = A15C3. (A15P3) =
A15C6. (A15P4) L169's behavior half read the expected global names from the section it checks.
(A15P5) The import-order quarantines cited a 13.7 that did not hold them. (A15P6) ref_func!
refused a valid module (a global initializer declares its ref.func's function), and a test pinned
the rule. (A15P7) codegen_export_names and the source-map JSON reader had no Components row.
(A15P8) MARCH's order of work and a 13.17 label still froze work on clauses since closed;
runtests.jl:1304 credited `_const_init!`; the builder sandbox loaded options.jl, so nothing caught
a builder OPTIONS read (A2B8). (A15P9) R31's reason for ClosedWorldPlan.ir_cache argued for `Type`.

Resolution:
- In batch 116a (685c1b93), its own changes, before it landed: A15C1-A15C7, A15P2, A15P3 and
  A15E2 (Amendment 4 of its contract).
- In batch 116x (the commit carrying this entry), each case run at the start first:
  - A15B1: _emit! records nothing while the code is unreachable; unreachable, br, return and throw
    are recorded before they end reachability, end, else and catch after they restore it, and a
    fragment appended where its function's code is unreachable adds nothing. Model first:
    OperandStack.tla's claim is Sound, over the recorded program, with
    MCOperandStackDeadCodeBroken (every instruction recorded) violating it. test/builder_cases.jl's
    dead_cases rows a-f failed and hold; L172. The probes lose dead instructions only: 225
    changed, every change a deletion, each module valid, the 1,593 lines removed 1,576
    `unreachable` and 17 `return`, each right after an unreachable, a throw or a return;
  - A15E1: model first, ExceptionStack.tla's HostCallInCatch keeps Julia's escaped entry until the
    host's catch block ends, and MCExceptionStackHostCallInCatchBroken violates Agrees in four
    steps (a call, its escape, a call inside the catch, a read: native the escaped exception, wasm
    nothing); the design instances are unchanged. host_glue_js's and host_runtime_js's docstrings
    state the contract (an export called inside a host's catch starts as after JL_CATCH's restore),
    and test/real_bottom_exceptions.jl measures both sequences (wasm 2 and 1, native 3 and 3). The
    wrong answer stays on 13.17 (A15E1); a host API mirroring JL_CATCH is Dale's decision;
  - A15E3: the reader answers a type object's class by its kind (emit_type_object_kind!, the rule
    typeof reads), so `throw(Int64)` escapes named DataType (the case reported the class
    unreadable at the start); A15E4: recover_module_handles! refuses a module exporting
    `wasmtarget.class_id`, naming it (a case); A15E5: the keyword is required;
  - A15B2: one declaration path, declare_local!, which builder_add_local! and allocate_local! call
    (L173); all 165 raw sites declare through it (int128.jl 109, calls.jl 23, context.jl 9,
    statements.jl 9, builtins.jl 6, closures.jl's trampolines 6, julia_numeric_tier.jl 3), and
    R41, counting a raw push, is a lock at 0; the probes are byte-identical across the move;
  - A15B3: a fragment sharing its function's locals must carry its parameters; A15B4: trunc_sat!
    refuses a sub-op above 0x07, and the dead STRUCT_GET_S/U arms and constants go; A15B5:
    WasmImport refuses an unnamed function import, and the writer names every import (rows t, u
    and v of test/builder_cases.jl failed and hold); A15B6: source_map_json names the classes before
    encoding (add_minified_class_names!, dart's map-object form), the wasm-opt path decodes,
    names and encodes, and the reader's reason is a Julia fact; A15B7: both comments are true;
  - A15P1: L156 counts each test file's import_stubs compile sites, refusals excepted, against its
    assertions, and the five modules are asserted; A15P4: probe_bytes.jl takes the names from the
    module object (compile_module, whose bytes equal compile_multi's on all 225 probes); A15P5:
    13.7 holds the import numbering; A15P6: a ref.func in a global's initializer needs no other
    declaration, a body's names one an element segment or an export names, and the test says so;
    A15P7: both rows; A15P8: the order of work states Dale's 2026-10-09 priority, the label and
    the runtests comment are true, and the sandbox starts at builder/types.jl, L149 counting an
    OPTIONS read in src/builder; A15P9: ir_cache's return type is `Type`, its R31 entry gone.
  The cases failed at the start and pass; L172, L173, R41 and the changes to L149, L156, L160 and
  L169 were negative-tested; the probes change only by the dead-code drop and the class reader.
- Everything else is on MARCH 13.17 under its row: A15E1 (the host's catch).

## 2026-10-12 — audited through baae2757 (685c1b93..baae2757: batches 116x, 116b, 116c, 116d-1, 116d-2)

The sixteenth audit covers:
- 5eacce30, batch 116x, the fifteenth audit's fixes;
- 0218bffa, batch 116b, one reader of what a node is;
- b5f5175c, batch 116c, one class set, one match rule, one walk of the edges;
- 5abb4b1b, batch 116d-1, one conversion and one type test per construct;
- baae2757, batch 116d-2, one table per construct.

It made 28 findings, one seen from two areas (A16B1 = A16E1). Each program was run native, on
685c1b93 (before the range) and on baae2757 (Julia 1.12.7, Node 22.23.3). Silent wrong answers at
baae2757, older than the range but claimed fixed by it or beside a fix it made, but one the range
introduced:
- A16B1 = A16E1. sext_int and zext_int into a target of 32 bits or fewer left a narrow source's
  junk in place, and sext_int into Int64 and sitofp normalised by the source's type, not by the
  op: `Int64(Int32(d8(n)))` with `d8(n) = Int8(n) + Int8(100)` answered 200 (native -56),
  `Int64(UInt16(du8(n)))` 300 (native 44), `sext_int(Int64, n % UInt8)` 128 (native -128),
  `sitofp(Float64, n % UInt8)` 255.0 (native -1.0); 685c1b93 answered the same.
- A16E2 (introduced by 5abb4b1b). `isa(x, Nothing)` read only ref.is_null, and the funnel boxed a
  nothing bound for an abstract reference: `t = (n, nothing, 2.5); t[(n % 3) + 1] isa Nothing`
  answered 2 at 5abb4b1b and baae2757 (native 1), where b5f5175c and 685c1b93 raised a
  WasmInternalError: inside the range it went from loud to wrong. The program the report gives (a
  nothing into an `Any` field) answered 1 on every tree, and so did three variants.
- A16E3. sitofp's target named by a GlobalRef took the default register, F64, and demoted:
  `sitofp(Float32, 2^60 + 2^36 + 1)` rounded twice (2^60, native 2^60 + 2^37), on both trees.
- A16E4. An intrinsic splatted over a vector folded at any length: three elements answered their
  sum and one element itself (native ArgumentError), on both trees.
Traps where Julia answers:
- A16C1 (introduced by 0218bffa). The report's program does not reach the path: its `g(c)` is a
  dynamic call, and both trees answer 19. With `g(@nospecialize(x))`, an :invoke Julia leaves
  abstract, the first round retargeted it to g(::Int64) before the round's dynamic step collected
  the captor that writes 2.5, and no later round undid it: an illegal cast at baae2757, 19 at
  685c1b93.
- A16C3. A closure built inside a captor from its box field wrote into the creator's box unseen:
  the creator's read stayed Int64, an illegal cast on both trees (native 1).
- A16C2. No program reproduced a wrong answer: nine variants (the report's, real erasures, a
  parametric method, a class only a vararg slot names) answer as native at baae2757; 685c1b93
  trapped or rejected four of them. The class reached the set through another statement's type in
  each (a memoryrefset!, an :invoke specialized at the tuple); the gap is the model's.
- A16B5. A 128-bit primitive that is no Int128 raised an unlocated error from the width rule, on
  both trees.
While reproducing A16C1, a closure created in one function and called dynamically in another
(`run_any(f, y) = (f(y); nothing)`) trapped on both trees (native 19): A7S1's remainder on 13.17.

Area: builder — (A16B1) above. (A16B2) A constant fragment holding a ref.func the module declares
nowhere was accepted into a function body (unreachable today). (A16B3) "dart has no bitcast" was
false: dart reinterprets by doubleToIntBits (intrinsics.dart:1541). (A16B4) A closure
trampoline's, the dispatch wrapper's and the dispatch trampoline's scratch locals were indices
computed beside the declaration path (`1 + arity`, `dt.arity`, a default 0). (A16B5) above.
(A16B6) struct_get!'s comment named struct.get_s/u, gone, and StructGet's `op` held one value.
(A16B7) validate_block_end!'s formal sentence kept the claim before 116x. (A16B8) source_map.jl
cited io_util.dart:209 for jsonEncode, at :211.

Area: collection and planning — (A16C1) above. (A16C2) The one class set missed a vararg
method's packed tuple, a value no statement makes, though its docstring said only H13 was missed;
Enrollment.tla drew every value from the set. (A16C3) above; BoxJoin.tla's TransitiveDiscovery
describes box_contents_type, which the plan's reads do not use, and CaptureType.tla modeled two
direct captors only. (A16C4) The plan's capture record was copied into a registry field nothing
read. (A16C5) A quoted GlobalRef was read through to its binding, where Julia evaluates a
QuoteNode to the GlobalRef itself. (A16C6) The `:splat` edge typed its container with no joins,
though its docstring said by arg_type; calls.jl cited ir.jl for it. (A16C7) 13.17's A12C1 named a
walk 116c deleted; LOWERING_INSTANTIATED_CLASSES attributed WT's holds_exceptions gate to dart.

Area: emission and diagnostics — (A16E1) = A16B1. (A16E2), (A16E3), (A16E4) above. (A16E5) The
operator citations named no Julia version: base/int.jl:86-88 holds `- + *` on 1.12.7 and :85-87 on
1.13.1 (the report's :85-87 for both is right for 1.13.1 only); base/float.jl:495-497 on 1.12.7 is
:492-494 on 1.13.1.

Area: enforcement and prose — (A16P1) L180 saw no 128-bit or float width list and no `=>` table:
twelve 128-bit lists, four float lists and TRACED_STATEMENT_TYPES were uncounted, so 13.4's width
item was removed unearned. (A16P2) L180's allowlist was a count per file. (A16P3) _compile_call_isa
re-read a global's binding with Core.eval, which L175's needle did not cover. (A16P4) L152 exempted
a qualified `Base.infer_return_type(` and named no other inference entry; its behavior test
counted only WasmTarget's. (A16P5) L178, L179 and L180 cited cases that passed before their fixes.
(A16P6) L180 said sext_int(Int128, 0x80) answered 128 (it raised a StackImbalanceError); L179 cited
types.dart:907 for loadClassId (code_generator.dart:6076); smoke's Bool comment sat above another
case; compile.jl kept a dead interpreter local under a false comment. (A16P7) Three xfails lacked
their native answer on 13.10. (A16P8) 116b and 116c moved forward without an evaluator PASS on
their last round, and two landed commits differ from the trees gated (b5f5175c from 13700fd4, a
docstring and MARCH; 5eacce30 from 2a6c5d22, R41's broadened needle).

Resolution: in batch 116dx (the commit carrying this entry), each case added and run on both trees
first:
- A16B1 = A16E1: one widening rule in emit_conversion!: a source narrower than 32 bits is
  normalised before sext_int, zext_int, sitofp or uitofp reads it, signed for sext_int and
  sitofp, unsigned for zext_int and uitofp, whatever the target's register (smoke
  narrow_widening, eight cases; seven failed on both trees). A16E3: the target of all ten
  conversions is resolved once, at the call, from a literal type or a constant global, an
  unresolved one rejecting at its statement; `reg(T, default)`, every default register and the
  bitcast name ladder are gone (an integer conversion whose target is held in no integer register
  rejects), fpext and fptrunc read the conversion table (smoke conversion_target). A16B5:
  numeric_register answers `nothing` for a primitive wider than 64 bits, and a conversion to or
  from one that is no Int128, or a statement whose value is one, rejects at its statement (smoke
  xfail wide_primitive, loud); held in a parameter or a field it still raises
  julia_to_wasm_type's unlocated error, on 13.17 (A16B5). L180 checks the rule,
  the resolution and its cases.
- A16E2: model first, Coercion.tla's NothingIsNull covers every nullable reference of the any
  hierarchy, MCCoercionBoxNothingBroken (a nothing boxed at an abstract sink, the code before)
  violates it; convert_type! makes such a nothing null, and `isa(x, Nothing)` of a value of any
  class reads `===`'s one test, _emit_is_nothing! (smoke heterogeneous_tuple_read/nothing_isa;
  test/diagnostic_attribution.jl's 'nothing at every nullable reference of the any hierarchy is
  its null'; L178). The first fast lane of this batch found the other half: a closure entry
  unboxed an erased nothing for the body's Nothing parameter, and the null trapped (smoke
  closure_union_nothing_erased). The model gained NothingNeverCast (a nothing held in a reference
  is never unboxed, cast to a non-null type or made non-null: its placeholder, boxed under
  Nothing's class for a non-null reference its box is, any other sink rejecting), and
  MCCoercionUnboxNothingBroken violates it; convert_type!, the closure entry's narrowing and its
  MethodError's arguments take a nothing so (smoke method_error/closure_nothing_no_method).
- A16C1: model first, ClosedWorld.tla's typed sites retarget while their captor is uncollected,
  each scan recomputing them (ReType), RetargetsSound at the fixpoint; MCClosedWorldTyping holds
  and its InPlaceRetarget variant violates it. _missing_explicit_invoke_mis recomputes each
  retarget every round from the :invoke's own MethodInstance (invoke_originals), restoring a site
  the round's typing no longer retargets (smoke capture_typed_invoke; L40).
- A16C3: model first, CaptureType.tla's nested captor and the creator's read,
  MCCaptureTypeNestedCaptorBroken violating Covered; record_capture_contents puts a nested
  captor's field in the class of the field it was built from, at any depth, and a class with a
  created field is created (smoke nested_captor).
- A16C2: model first, Enrollment.tla draws a value a class no statement makes may have
  (Reaches), and MCEnrollmentUnseenSlotDroppedBroken violates TrapOnlyWhenNoMethod; the one class
  set observes a vararg method's packed tuple from its slot (L176). No case: no program reproduced.
- A16E4: an intrinsic splatted over vectors runs at its arity, two, else throws Julia's
  ArgumentError (smoke reduce_intrinsic_arity).
- A16B2: append_builder! refuses a constant fragment into a function body (row w of
  test/builder_cases.jl failed and holds; L166). A16B4: the three scratch locals are read by the
  index their declaration returns, none by arithmetic or a default (L173). A16B3, A16B6 (no `op`
  field), A16B7, A16B8: the texts are true.
- A16C4: the registry field and its merge, and the plan's copy, are gone. A16C5: a literal is its
  value, unresolved (L176). A16C6: the `:splat` edge types its container by arg_type. A16C7:
  13.17's A12C1 is re-measured and restated (the hang is ensure_constant_global!'s `===` table,
  whose jl_object_id recurses along every path: past 360 s at baae2757 with this batch's draft),
  and the gate is stated as WT's own.
- A16P1, A16P2: L180 counts 8- to 128-bit integer and float lists, `<: Union{…}` and `=>` tables,
  each line on one exact allowlist with its reason; sixteen lists read the rule now
  (`_julia_int_width(T, false) == 128`, `numeric_register(T) in (F32, F64)`), and 13.4's width
  item stays closed. A16P3: the isa reads the boundary's value of a constant global and rejects
  any other; L175 counts `eval(`, `get_binding_type(` and `isdefinedglobal(`. A16P4: L152 counts a
  qualified call and typeinf, typeinf_ext, typeinf_frame, code_typed and abstract_call; its test
  counts every query of the interpreter's cache (CC.cache_owner), 0 during the plan's compile.
  A16P5: L178, L179 and L180 cite cases that fail with their fixes reverted (L179 a unit test of
  the one `Type{X}` element rule, test/dispatch_method_error.jl) and name the others regression
  cases. A16P6: the four texts are true, the dead local gone. A16P7: 13.10 states the three native
  answers. A16E5: both versions' lines are cited.
- A16P8, a process finding: no push without an evaluator PASS on the exact final tree (the
  orchestrator's rule of 2026-10-12); 116d-1 and 116d-2 have PASS on their exact trees (116d-1
  re-checked after its rebase onto b5f5175c).
  The cases failed at the start and pass; each tightened lock (L40, L152, L166, L173, L175, L176,
  L178, L179, L180) was negative-tested on the exact commit; the probes change in one function.
- Everything else is on MARCH 13.17 under its row: A7S1's remainder (the callable created in one
  function and called in another), A12C1 (restated) and A16B5's remainder (a wide primitive in a
  parameter or a field).

## 2026-10-14 — audited through 52c0a9bd (baae2757..52c0a9bd: batches 116dx, 116d-3, 116d-4, 116e-1)

The seventeenth audit covers:
- fece20cb, batch 116dx, the sixteenth audit's fixes;
- ae8f71ee, batch 116d-3, one CFG, Julia's own;
- 5fab8286, batch 116d-4, a constant callee is its object; one as-checker per target and static
  type;
- 52c0a9bd, batch 116e-1, one owner of a compile's state.

It made 29 findings, three seen from two or three areas (A17P5 = A17C6 = A17E9, A17P3 = A17E4,
A17E5 within A17P8). Each program was run native, on baae2757 (before the range) and on 52c0a9bd
(Julia 1.12.7, Node 22.23.3; the closure ones on 1.13.1 too). Silent wrong answers at 52c0a9bd,
older than the range:
- A17E1. One wasm null stood for both `#undef` and `nothing` in a pointer slot whose type admits
  `nothing`: `isassigned` of a `Vector{Any}` slot holding `nothing` answered 2 (native 1),
  `isdefined` of a field set to `nothing` answered 2 (native 1), and reading an `#undef`
  `Vector{Any}` slot answered 0 where native throws UndefRefError, on both trees. The report's third
  program (a captured `local x` set to `nothing`) answered as native on both trees and both
  versions. The same root, measured on 52c0a9bd while fixing it: a `Union{Nothing,String}` slot,
  held as String's nullable reference, answered `isassigned` of a stored `nothing` 2 (native 1)
  and read its `#undef` as `nothing` (native UndefRefError), and so did such a field `new` leaves
  unset; a slot whose type admits no `nothing` (a `Vector{String}`'s) read its `#undef` unchecked,
  a `try` around the read answering 1 (native 2) and a `length` of it trapping on a null
  dereference; a splat `[v...]` copied an unset slot as an assigned one (its `isassigned` 2, its
  `length` 2, native UndefRefError).
- A17E2. The width rule gave a user primitive narrower than its i32 register the register's
  width: `zext_int(Int64, bitcast(P8, (n % UInt8) + 0xc8))` answered 300 (native 44), its
  `sext_int` 400 (native -112) and its `ult_int` against `bitcast(P8, 0x50)` 2 (native 1), on both
  trees; the egal of two such values answered as native. Its other widths, measured while fixing
  it: a dirty 24-bit primitive sign-extended through `extend16_s` (`sext_int` answered 32754,
  native -32782; `slt_int` 2, native 1), and a 40-bit one in an i64 was never normalised (`zext_int`
  answered -1099511627774, native 2; `sext_int` 1099511627762, native -14; `ashr_int` and `===`
  wrong alike); a literal of a 24- or 40-bit primitive raised an internal error.
Traps where Julia answers:
- A17C1. A captor's body inlined into a function taking the closure as an argument wrote through
  that argument, which the capture record did not key: `c1` (the report's program) trapped, illegal
  cast, on both trees under 1.12 (native 1); 1.13 collects the closure's own body and answered 1.
- A17E3 did not reproduce at 52c0a9bd: a nothing reaching a selector-dispatched `::Nothing`
  method, through ten methods, three methods and a body that is the selector call alone, answered
  4 as native; baae2757 trapped on all three (illegal cast).
Loud, not wrong: A17C2's program rejects on both trees, its constant a cyclic Core.Box (A12C7 on
13.17); a non-cyclic capturing closure constant called only as an :invoke callee answered as
native on both. A17E6's program rejects on both trees (the typeassert's target is an SSA value).

Area: builder — (A17B1) The closure entry's object scratch was a `-1` sentinel and a keyword
default, beside the `Union{Nothing,UInt32}` its siblings use, and the argument tests' scratch a
`(-1, -1)` pair; L173's four needles saw only the old spellings, and nothing tested that a scratch
is the declared local. (A17B2) _closure_narrow_arg!'s Nothing arm raised two bare errors in the
vtable pre-pass, not _closure_layout_error. (A17B3) ref_func!'s message named a global's
initializer as a declaration its check does not read, and append_builder!'s comment repeated the
half-rule. (A17B4) as_checker!'s quarantine did not state why it builds the body before defining
the function, where dart defines first.

Area: collection and planning — (A17C1) above; A16C3's nested-captor link had the same blind spot.
(A17C2) The class set and the callable observation walked a call's operands without its `self`,
the constant callable 5fab8286 introduced, so statement_operands' comment was false. (A17C3)
CaptureType.tla's positive typing held by definition, never modeling how a field joins its box;
Enrollment.tla's InSet equalled Reaches likewise; ClosedWorld.tla's TypedRetargets only widened,
where the code's typing also narrows. (A17C4) nir_operand_callee read a singleton function type
where nir_callee_self reads Compiler's singleton_type. (A17C5) A vararg body's short slot table
dropped the packed tuple's class silently. (A17C6) = A17P5. (A17C7) nir_callee's docstring did
not say why a bound non-constant global is taken as its value, and _closed_world_edge's named
the numeric joins only.

Area: emission and diagnostics — (A17E1), (A17E2), (A17E3) above. (A17E4) = A17P3. (A17E5)
compute_basic_blocks is at Compiler ir.jl:94 on 1.12.7 and 1.13.1, cited :93. (A17E6) typeassert
took a bound global's value whether constant or not, where isa and the conversions reject one that
is not. (A17E7) The definite-initialization proof rebuilt the caller's CFG on every partial `%new`.
(A17E8) ProvenDead.tla and DefiniteInit.tla did not model the trailing-`nothing` rule (a statement
in no block), and DefiniteInit.tla's catch edge sat at the Enter only, so no start_pc inside a try
body was checked and the upsilon rule went unstated. (A17E9) = A17P5.

Area: enforcement and prose — (A17P1) E5 was called resolved, but four sites still subtracted a
String's pointer base themselves (_emit_storage_pointer_offset!, memcmp, memchr, beside the rule),
and L143 counted one spelling. (A17P2) L180's detector missed a numeric list as a named or keyword
tuple, a ternary's tuples, an `!isa` chain and a `Union{…}` const. (A17P3) = A17E4: entry 16's
resolution of A16E5 was itself wrong: base/int.jl holds `- + *` at :86-88 on 1.13.1 too (entry 16's
":85-87 on 1.13.1" is false; this entry corrects it). (A17P4) xfail partial_new_handler_read was on
no plan row, and functor_invoke lacked its native answer. (A17P5) compile_module's keyword default
read the options beside the entry, codegen read WASMTARGET_DEBUG_LOCALS with a process-wide `@warn
maxlog`, and options.jl's "ENV read from nowhere else" was false. (A17P6) R40's ledger half passed
on the process-wide design too. (A17P7) gate-fast.yml named a round-robin dealing, R40's text and
section comment cited a 13.7 that no longer lists the side channels, L76 kept a dead `required`
list, and ae8f71ee's message said L148 read 1 where the landed commit reads 0. (A17P8) L180 cited
translator.dart:1113 for translateExternalType (:1239) and four texts cited ir.jl:93 (:94); its
third claim, types.dart:1039 for AsCheckerCallTarget.name, is true at 898a1e4b (`String get name`
is line 1039). (A17P9) smoke's dealing skipped a missing timing file, dropped an unparsed value
and took the median for an unrecorded group silently.

Resolution: in batch 116ex (the commit carrying this entry), each case added and run on both
trees first, but A17E1, fixed in 116ex-2, the commit after it, model first (Undef.tla's four slot
kinds, a Broken instance per wrong encoding): a pointer slot whose type admits `nothing` (a
`Union{Nothing,S}` or abstract Memory element, a field `new` may leave unset) is held in the any
hierarchy and marks `#undef` with one undefined value, every other reference slot with its null,
and every read of a reference slot tests it and throws UndefRefError, as Julia's
null_pointer_check does, which closes A12E1 (13.17) too (smoke undef_slots; L63):
- A17C1 + A17C3: model first, CaptureType.tla's record joins a write by the operand carrying its
  captor (`#self#`, an SSA value, an argument), and MCCaptureTypeArgumentCarrierBroken (the key
  reading `#self#` and an SSA value only) violates Covered; _captured_box_field keys a box read by
  value_type over any carrier operand and the body's slot types, the nested-captor link included
  (smoke inlined_captor; test/f3_box_capture_l2_prepass.jl's 'a write through an argument joins the
  box'). Its first fast lane found smoke xfail box_type_recovery/box_value_literal_phi (the same
  shape: `_sm_bump!(f) = f()` inlines its argument's `s += 1`) raising an unlocated internal error
  on 1.13 where it had rejected located: the stackifier's return of a numeric local into an `Any`
  result converted it with no source type to box it by; it now passes the returned value's own type,
  and the case answers 1 as native on 1.12 and 1.13 (moved to smoke inlined_captor).
  ClosedWorld.tla's typed sites retarget in both directions, RetargetsSound states exactness, and
  MCClosedWorldTypingNarrow holds while its ReTypeOnlyRestores variant violates it.
- A17E2: `_julia_int_width(T)` is 8*sizeof for every primitive WT represents and `nothing` for any
  other type, `_operand_width` its reader for an intrinsic's operand, and no width keyword defaults
  to a register; every width narrower than its register (a 24-bit primitive in an i32, a 40-, 48-
  or 56-bit one in an i64) is sign-extended or masked by one rule, emit_extend_from_width!, which
  normalise_narrow!, the shifts, the comparisons and divisions, the egal and the checked
  arithmetic read (a checked product wider than its register rejects at its statement), and a
  literal of any width up to 64 bits is its bits (smoke narrow_primitive's 8-, 24- and 40-bit
  cases; L180).
- A17E3: the selector caller reads its receiver's class through emit_class_id! (a null is
  Nothing's), and the dispatch wrapper takes a nothing for a `::Nothing` parameter as its
  placeholder, as the closure entry does (smoke selector_nothing, regression cases).
- A17C5: the packed tuple's slot type is read by value_type, which raises on a short table.
  A17E6: isa, typeassert and the ten conversions read a type operand by one rule,
  nir_type_operand (test/ir_one_inference_path.jl). A17E7: the proof reads the context's CFG for
  the caller's body (L181). A17E8: model first, ProvenDead.tla and DefiniteInit.tla carry the
  trailing-`nothing` rule (their AnyNothing variants violate Sound), and DefiniteInit.tla's ground
  truth throws from every statement of a try body, with the upsilon rule stated and start_pc any
  statement (MCDefiniteInitRegion; its UpsilonNotUse variant violates Sound).
- A17C2: the class set and the callable observation walk nir_expr_operands, `self` included.
  A17C4: nir_operand_callee reads CC.singleton_type (L76). A17C7: both docstrings are true.
- A17B1: every scratch is `Union{Nothing,UInt32}`, required, and the box producer refuses one that
  is a parameter or a local of another type (L173; test/dispatch_method_error.jl). A17B2: both
  errors are _closure_layout_error. A17B3: the rule and the comment state WT's narrower rule
  truly. A17B4: the quarantine states the order and its reason.
- A17P1: one storage-pointer rule, _emit_storage_byte_offset!, read by the element offset, the
  pointer load and store offset, memcmp and memchr; L143 counts any String-or-Symbol subtraction
  outside it. A17P2: L180 counts the new spellings; the two duplicated pointer-element tuples read
  _STORAGE_PRIMITIVE_ELTYPES, `eltypes` is required, the ternary reads Base.uinttype, and the others
  are on the allowlist with their reasons. A17P3 = A17E4, A17E5, A17P8: the citations are true
  (A17E5: nir.jl's three texts and nir_cfg's docstring cite ir.jl:94). A17P4: 13.10 holds both with
  their native answers. A17P5: the `locals` trace point replaces the ENV reads, and WT_VALIDATE is
  CompilerOptions.validate, an entry's `validate` keyword deciding when given; L158 and L107 count
  any ENV or WT_* read in src outside options.jl (compile_module's options default, by the
  orchestrator's ruling, and `optimize`, the post-pass over finished bytes, are the other readers
  of the options). A17P6: R40's text and its test name the ledger check a regression check. A17P7:
  the texts are true and the dead count gone. A17P9: the dealing errors on each, and L163 checks
  the timing file lists exactly the groups. The cases failed at the start and pass; each tightened
  lock (L76, L107, L143, L158, L163, L173, L176, L178, L180, L181) was negative-tested on the exact
  commit; the probes change in three, the memchr read's (fc_memchr_findfirst_char,
  string_findfirst, string_occursin: the String base is subtracted in i64 before the narrowing, by
  the rule).
- Everything else is on MARCH 13.17 under its row: A17C3's Enrollment remainder, and A17E2's
  checked product wider than its register, which rejects at its statement.

## 2026-10-21 — audited through 25e6a5b7 (52c0a9bd..25e6a5b7: 4363ec4e, batches 116ex and 118a)

The eighteenth audit covers:
- 4363ec4e, a type's order key printed once per registry; the dispatch wrappers read one class map;
- 0ebf6352 and 0bc84e05, batch 116ex, the seventeenth audit's fixes and `#undef` in a pointer slot;
- 25e6a5b7, batch 118a, this audit's first fix (A18B1), in the range by the order of work.

It made 30 findings on 52c0a9bd..0bc84e05, three seen from two or three areas (A18B1 = A18C1 =
A18E1, A18B3 = A18E3, A18B2 = A18E2 (a)(b)). Each program was run native and on the tree before
its fix (Julia 1.12.7, Node 26.11.0). Silent wrong answers at 0bc84e05, introduced in the range:
- A18B1. pointer_slot answered by allocatedinline alone, so an inline struct with a pointer field
  was never `#undef`: isassigned of an unset `Vector{Some{String}}` slot answered 11 (native 21),
  isdefined of such a field `new` leaves unset 1 (native 2), a splat's length 5 (native -1), and
  each read of an unset slot trapped on the null (native UndefRefError).
- A18B3 = A18E3. A constant Dict's unoccupied reference slot was the null, `nothing` where the slot
  holds `nothing` too: `isassigned(D.vals, i)` of a `Dict{Int,Any}` constant answered 1 (native 2),
  its read `nothing` (native UndefRefError), `count(i -> isassigned(D.vals, i), eachindex(D.vals))`
  16 (native 1); a Vector constant with an unset slot raised an internal error and a Memory one
  rejected: three rules for one fact.
Older than the range:
- A18B2 = A18E2 (a)(b). The narrow ctlz/cttz/ctpop and flipsign_int read the register's full width
  (by reading: `leading_zeros(0x01)` 31, native 7; `Int(abs(Int8(100) + Int8(100)))` -56, native 56).
- A18E2 (c). The 128-bit sext and zext normalised only a source held in an i32: measured on
  25e6a5b7, `slt_int(sext_int(Int128, trunc_int(P40, 2^40 - 2)), Int128(0))` answered 2 (native 1)
  and the zext of a dirty 40-bit value 1099511627778 (native 2).
Traps where Julia answers:
- A18C3. A closure held in a constant global, its call inlined, wrote through the constant, which
  the capture record did not key: a read of the same closure type through an argument took the
  world's Int64 join and trapped, illegal cast, on 0bc84e05 (native 14).
Loud, not located: A18E4's `Vector{Union{Nothing,Function}}(undef, n)` raised an internal error at
type registration on 0bc84e05 and 25e6a5b7, where 52c0a9bd compiled it with one null for `#undef`
and `nothing`. A18E6's numeric-element read raised an unlocated error; no program reaches it
(measured: `Union{Int32,Int64}`, `Union{Int8,UInt8}`, `Union{Float32,Float64}` and
`Union{Int64,UInt64}` elements are held in anyref, get_concrete_wasm_type), so it has no case.
A18C4 changes no answer (the class set numbers the class `self` carries), measured by its unit
testset, which fails on 0bc84e05 (2 of 3).

Area: builder — (A18B1) above. (A18B2) above. (A18B3) above. (A18B4) The quarantine named a Memory
slot's missing companion field as the necessity, which covers Memory elements only, where fields
and Core.Box contents take the sentinel too, and cited computeIsSetEncoding at its :570 case.
(A18B5) 4363ec4e's class map read `get(_type_of_id, tid, nothing)`, a default, typed
`Dict{Int32,Any}`. (A18B6) calls.jl's isdefined of a Box named a typed reference box no code makes,
its TYPED arm and builtins.jl's ConcreteRef branch dead; emit_extend_from_width!'s anchor claimed
dart's narrowing arms "at every width"; undef_slot_storage's text said a funcref representation
raises on that line.

Area: collection and planning — (A18C1) = A18B1. (A18C2) 4363ec4e's "printed once" was false:
closed_world_class_list is re-sorted per MethodError args tuple and class_candidates per ambiguous
pair and per round. (A18C3) above; CaptureType.tla's Carriers, record_capture_contents' docstring,
the README row and entry 17's A17C1 resolution omitted the constant carrier. (A18C4) The numbering
walk read `node.operands`, a third reader of a statement's values beside the one operand table,
omitting `self`, and L176 pinned A17C2 by text. (A18C5) A compile infers in two cache partitions:
the collection's fresh `WasmInterpreter(Base.RefValue(0))` per pass and get_wasm_interpreter()'s
shared `:wasm_target`, which infer_return_type and the method consult ask (measured:
compiling a captured `c = _c5g(c)` leaves `_c5g(::Int64)` one CodeInstance in each). (A18C6)
LOWERING_INSTANTIATED_CLASSES' docstring omitted the `#undef` read check's UndefRefError.

Area: emission and diagnostics — (A18E1) = A18B1. (A18E2) above. (A18E3) = A18B3. (A18E4)
undef_slot_storage error()ed at type registration for a Nothing-admitting slot held in a host
reference. (A18E5) Four readers of a MemoryRef's element type kept their own rule with a dead
`:MemoryRef` arm (builtins.jl's ptr_or_offset, statements.jl's two, context.jl's), a fifth in
types.jl's value translation, found while fixing it, and `Memory{T}.instance` kept an `Int32  #
default` element type. (A18E6) above.

Area: enforcement and prose — (A18P1) C10's "alone reads the options" was softened by entry 17's
A17P5 resolution: compile_module's keyword default and optimize's validate default read the
options too, and L158's text said both. (A18P2) Two from_julia defaults remained, `get(ctx.ssa_types,
…, Any)` and `get(…, typeof(val))`, and calls.jl's `from_julia=fieldtype(T, i)` was neither counted
nor allowlisted. (A18P3) Entry 17's "negative-tested on the exact commit" ran on 6a5490ae, not on
0ebf6352. (A18P4) Undef.tla's Representable and two UndefNotNothing Broken instances were violated
at Init by the constant Enc alone, checking no rule. (A18P5) smoke.jl cited b6597d80, a draft
commit, and 0bc84e05's message narrated "as the previous commit states". (A18P6) "a Union{Nothing,S}
or abstract slot" (undef.jl, Undef.tla, entry 17, L63): an abstract type that excludes Nothing,
Number's, is a reference slot whose null is `#undef`. (A18P7) calls.jl's shift comments and two
quarantine texts named 8- and 16-bit widths only. (A18P8) Entry 17's "the cases failed at the
start" was false for its regression cases. (A18P9) MARCH's A12E7 sequenced on A12E1, closed.
(A18P10) HISTORY's audit #17 line omitted the closing of A17E1 and A12E1. (A18P11) "late_lowering.dart"
named no path and ":570 computeIsSetEncoding" its case, not its declaration (:560). (A18P12) The
README's Undef row omitted pointer_slot and field_may_be_undef, and L143's text and A17P1's
resolution said "any String-or-Symbol subtraction" where it counts two spellings.

Resolution: A18B1 = A18C1 = A18E1 fixed in 118a (25e6a5b7): pointer_slot is Julia's rule, boxed or
inline with a pointer (`!allocatedinline(T) || !datatype_pointerfree(T)`), smoke undef_slots
inline_ptr_*. A18B2 = A18E2 (a)(b) fixed by 117a (its W2 and W7: smoke registry_unops'
ctlz_int/cttz_int/ctpop_int and registry_misc's flipsign_int cases), which lands after this commit,
as does A18E5's `Int32  # default` (it raises in 117a).
A18C2 is pending on wip/eff-compile2 9d59c973 (one sorted class list, built when the class set is
final; dev/MARCH.md 13.17); the registry_order_key docstring states its scope truly here. Everything else in batch 118x (the
commit carrying this entry), each case added and run on the tree before it first (native,
0bc84e05 or 25e6a5b7, and this commit), model first:
- A18P4 + A18B3 + A18B4 + A18P6 + A18P11: Undef.tla derives a slot's kind and storage from the
  attributes the code reads (pointer_slot, pointer_slot_admits_nothing, undef_slot_storage,
  undef_slot), every slot unmade at the start, so each of its eight Broken instances reaches its
  violation by a step (MCUndefConstAsNullBroken, a constant's unset slot emitted as the null,
  violates UndefNotNothing; 118a's MCUndefInlinePointerBroken is one rule of it); its quarantine and
  undef.jl's state the necessity for fields and the Box, one `#undef` read by one rule (C1), and
  cite pkg/front_end/lib/src/kernel/late_lowering.dart's computeIsSetEncoding :560, its case :570.
  A18B3: one constant-slot emission, emit_constant_slots! (values.jl), reads isassigned and emits an
  unset slot through emit_undef!, for a Dict's keys and vals, a Vector and a Memory (a Dict's
  unoccupied isbits slot, uninitialized memory, takes its storage's zero as before) (smoke
  undef_slots' const_ cases; L38, L63). A18P6: smoke undef_slots number_unset_read_throws and
  number_isassigned (answering as native on 0bc84e05; on 0ebf6352 the read answered 2, native -1).
- A18C3: model first, CaptureType.tla's Carriers gain "constant" and
  MCCaptureTypeConstantCarrierBroken (the key without it) violates Covered; _captured_box_field keys
  any operand by value_type (smoke inlined_captor write_through_constant).
- A18C4: the numbering walk reads nir_expr_operands, `self` included, for every statement
  (test/lazy_classid_isa.jl's 'the numbering walk reads a call's operands through the one table, its
  self included', failing on 0bc84e05; L176).
- A18E2 (c): the 128-bit sext and zext normalise through normalise_narrow! whatever the source's
  register (smoke narrow_primitive sext128_p40, zext128_dirty_p40; L180 counts a normalisation
  gated on an i32-held operand).
- A18E4: a Nothing-admitting slot held in a host reference keeps its representation, and every
  allocation, unset, test and read of its `#undef` rejects at its statement
  (_undef_unrepresentable!; smoke xfail undef_host_reference, an unlocated internal error on
  25e6a5b7); holding it in anyref with the extern bridges is on 13.17 (the anyref storage alone
  failed the builder's check at a store of `nothing`, measured). A18E5: the five readers read
  memoryref_eltype (L63); the remaining name tests' dead arm is on 13.17. A18E6: the read rejects
  through emit_unsupported_stub! at its statement.
- A18B5: `_type_of_id[tid]`, a `Dict{Int32,Type}`. A18B6: the dead arms deleted (a Core.Box
  reference of another type raises); the anchor cites :2037-2061 for the 8- and 16-bit arms and a
  quarantine for the 24-, 40-, 48- and 56-bit ones (intrinsics.dart:2037 is the case label of
  wasmI32Int8FromInt at 898a1e4b, not :2036 as the report read); undef_slot_storage's text is true.
  A18C6: the docstring names the read check.
- A18P1: compile_module's `options` is required (each test passes options_from_env()), optimize
  takes `validate` required from its caller and reads no options (no default stands in for
  WT_VALIDATE); compile_with_base is one call of the entry, as its siblings are, and passes its
  post-pass the options that compile used (CompileResult.options) unless its own `validate`
  decides (L158 counts it among the entries); options_from_env has one caller in src,
  the entry (L158 counts it); entry 17's A17P5 sentence "compile_module's options default, by the
  orchestrator's ruling, and `optimize` … are the other readers of the options" is withdrawn: C10's
  "alone" holds. A18P2: both read ctx.ssa_types[i], which raises on a missing entry; L178 counts
  `from_julia=get(` and `from_julia=fieldtype(`, the run-time-name field read on its allowlist as
  the read's own type; 39 other reads of a statement's type with a default are on 13.17.
- A18P3: probe_bytes on 0ebf6352 and on 0bc84e05 gave 225 probes, 0 changed; entry 17's
  "each tightened lock … was negative-tested on the exact commit" reads: the negatives ran on
  6a5490ae, whose tree differs from 0ebf6352 by 4363ec4e's byte-identical change. A18P5: the smoke
  comment cites 0ebf6352 (measured there: the prefixed splat answered isassigned 2 and length 3);
  0bc84e05's message cannot change. A18P8: entry 17's "The cases failed at the start and pass"
  reads: each case's start answer as recorded; its regression cases answered as native. A18P12 and
  entry 17's A17P1 sentence: L143 counts a String-or-Symbol test spelled `=== String || … ===
  Symbol` or `in (String, Symbol)` followed within three lines by a constant 1 and a subtraction.
  A18P7, A18P9, A18P10: the texts are true. Entry 17's A17C1 "any carrier operand" and A17C2 "one
  operand table" hold since this commit (A18C3, A18C4).
- Each new or tightened lock (L38, L63, L158, L176, L178, L180) was planted, fired and restored on
  tree 80a5aa27 (2c18700e), which this commit amends only by optimize's required `validate`,
  compile_with_base through the entry (L158's added check planted and fired on this commit), the
  Memory constant's dead-code guard, R5's baseline (59 to 58, measured) and prose. L180's needle counting a narrow ctlz/cttz/ctpop or flipsign that reads the full register
  outside the width rule arrives with 117a, whose W2 and W7 fix both sites: at this commit they read
  the register (the unary table's I32_CLZ, I32_CTZ and I32_POPCNT rows, intrinsics_table.jl, and
  _compile_call_flipsign, calls.jl), so the needle would count them and break L180, a lock at 0.
  Everything else is on MARCH 13.17 under its row: A18C5 (one WasmInterpreter per compile, more
  than ~150 lines), A18C2, A18P2's remainder, A18E4's representation, A18E5's remainder.

## 2026-10-21 — audited through f1c16321 (25e6a5b7..f1c16321: 4d8357c7, the blocking gate, 116e-2, A18C2 and the JIT fix)

The nineteenth audit covers:
- 4d8357c7, batch 118x, the eighteenth audit's fixes (its entry);
- 22f9cea4, the blocking gate (`bash dev/gate.sh --block`, its budgets and timing ratchet, the landing on its record);
- 99c12264, batch 116e-2, one export namer, a function named by its Julia identity, one import query, the host runtime
  per module;
- fe7b5405, A18C2, one sorted class list per round, and f1c16321, methods that take a type compile once (an addendum,
  read in all four areas).

It made 41 findings on 4d8357c7..99c12264 (34) and on fe7b5405 and f1c16321 (the addendum, 7), and one more while this
commit was verified (A19P12), several seen from two
areas (A19B1 = A19E3, A19B2 + A19B3 = A19E6, A19C1 = A19E2, A19C2 = A19E1, A19C7 = A19E5, A19C8 = A19E7). No silent
wrong answer is in the range. A valid program refused, introduced in the range: A19C2 = A19E1, two generic functions
of one name in two modules (`_GNA.f(x::Int64)`, `_GNB.f(x::Int64)`) printed alike and raised a WasmInternalError, where
4d8357c7 compiled them and native `_gn_alike(3)` answers 9. A wrong answer the blocking gate lets land: A19E2, a changed
operator-table row (`intrinsics_table.jl:111` F32_COPYSIGN to F32_MIN validates, answers `copysign(1.0f0, -2.0f0)`
-2.0f0, native -1.0f0) runs no stage of the gate (by reading).

Area: builder — (A19B1) the host runtime was built by reading the module's bytes back (writer.jl module_sections,
module_function_imports, a port of wasm_builder's Deserializer), where dart2wasm generates its runtime from the
translator's own record of the imports it used (runtime_generator.dart:60, :128) and writes it beside the module
(compile.dart:648-669), its Deserializer serving only tools and tests: two readers of the import list. (A19B2) the
reader read u64/s64 where the format gives u32 and s33, and host_imports.jl asserted a ten-byte heap type accepted.
(A19B3) a global import's value type, heap type and mutability were read past unchecked. (A19B4) write_name! wrote a
name without checking it is UTF-8. (A19B5) WasmImport took any kind byte and serialized every one as a function import,
three `kind == 0x00` filters reading the dead case. (A19B6) L185 credited a `.imports` read to the last `^function` line
and saw only a receiver spelled `mod`.

Area: collection and planning — (A19C1) block_impact.jl's "ran a line" is not "detects a change" (overlay and ext bodies,
const tables and `@static` blocks unkeyed, same-name definitions sharing keys, 40-line pieces, a 1-cover, no QA family,
no 1.13 run for a src change). (A19C2) above. (A19C3) _user_shown_in_signature asked `which(show, Tuple{IO,T})`, not what
the printer runs: a show for IOContext, `print` on the function slot, and Base shows that call a value's own methods
(`show(io, ::Signed)` its `string`) decided a name. (A19C4) which of two methods over one specialization Julia's dispatch
selects was decided twice (invoke_only by wt_method_which, the bare name by `morespecific`). (A19C5) "as Julia prints
it in a stack trace" was false with aliases off. (A19C6) root bindings and invoke targets were checked against every
planned function, not plan.roots. (A19C7) a hook's negative index raised an InexactError wrapped as an internal error, one
past the end failed only after codegen. (A19C8) two ExportNamers per compile. (A19C9) a name printed up to three times;
"does not depend on the session" overstated (a union's member order past three parameters, jltypes.c:434-455); an
unnamed entry's form depends on the other entries.

Area: emission and diagnostics — (A19E1) = A19C2. (A19E2) = A19C1, the copysign row above. (A19E3) = A19B1. (A19E4) the
reader's messages gave a section offset as a module byte ("byte 6" for a fault at byte 16). (A19E5) = A19C7. (A19E6) =
A19B2 + A19B3. (A19E7) = A19C8. (A19E8) a signature holding a closure type is named by its gensym, which Main's lowering
counter decides, so a name and the probe bytes follow the session.

Area: enforcement and prose — (A19P1) the blocking gate runs no QA test file the locks cite as behavior, and land.sh
never reads the landed head's matrix verdict. (A19P2) a red record under the warm runner was overwritten by a green rerun.
(A19P3) the stages inherit WT_*/TLC_* from the caller; `clean` is read once. (A19P4) the warm runner lives outside the
repository and its stages are not ratcheted. (A19P5) the machine factor is uncapped, so "60 s" is not enforced. (A19P6)
a calibration lowering loosens every best; a hand edit can raise a budget. (A19P7) the timing exemption accepts any
existing MARCH row. (A19P8) a record of a narrowed change (`--base HEAD`) lands. (A19P9) 99c12264's message states as
its own the smoke, probe and shard numbers measured on 0cefd742 (tree 0865d25f, on 0bc84e05); the landed record has no
1.13 stage. (A19P10) gate.sh:6, block_groups.tsv:4 (84 core cases, not 58), HISTORY.md:151, block.jl:116's -U0 comment.
(A19P11) the gate's selections are run by no lock. (A19P12, found while verifying this commit) a warm session collects
what a fresh process does not: diagnostic_attribution.jl's receiver-free `print(x)` raised a WasmInternalError ("Base.string_index_err(::AbstractString,
::Int64) @ Base was collected with no recorded reason") under the out-of-tree warm runner, on this commit and
after a restart, where a fresh `julia --project=.` on this commit and on f1c16321 rejects it at its statement
(current_task, lock.jl:10), so the warm runner's verdict is not a fresh process's. Addendum — (A19X1) fe7b5405's message states smoke "902 passed" and
every timing and profile figure as its own; they were measured on 40934990 (A18C2 on 0bc84e05), and the landed record
ran 115 smoke cases; its probe claims hold (b9b4d1f5's src equals fe7b5405's: 225 probes, 0 changed, 0 differ in reverse
order). (A19X2) f1c16321's `@nospecialize(func_ref=nothing)` on CompilationContext's keyword reaches the body, not the
kwcall sorter, which specializes on the NamedTuple (measured at 98d0e16f: 264 samples in the kwcall): the claim is
false. (A19X3) f1c16321's timings compare 99c12264 with c614c0c9, whose parent is b9b4d1f5 (A18C2), so they include
A18C2's gain; its probe claims hold (c614c0c9's src equals f1c16321's). (A19X4) nothing pins either perf fix. (A19X5)
ClosedWorldClasses keeps the default constructor beside the deriving one. (A19X6) dfs! and box_capture.jl still sort
their children by `string` per comparison. (A19X7) entry 18 still says A18C2 is pending on 9d59c973.

Resolution: A18C2 is fixed by fe7b5405 (A19X7); entry 18's "pending on wip/eff-compile2 9d59c973" reads so. A19C1 =
A19E2 and A19P1-A19P11 are fixed in 119g (march/119g, pending, after this commit), the copysign plant its acceptance test
and L194's negative. A19P12 is on MARCH 13.17 (the warm runner collects what a fresh process collects, the receiver-free print its witness),
for 119g's in-tree runner. A19X4, A19X5 and A19X6 are fixed in eff-compile3 (pending), and A19X2's code there (site 9,
func_ref positional, 03fafe27), the decorative keyword form going with it. A19X1, A19X3 and A19P9: the numbers are
attributed above (the landed messages cannot change); RULES-agents.md requires every number in a message to be measured
on the exact commit or to name its sha. A19E8 is on MARCH 13.17 (a closure type printed by its parent method and its
declaration ordinal, a case of two fresh processes and a session that lowered other closures first), fixed in 120x,
the commit carrying entry 20;
this commit retitles generated_names.jl's testset ("does not depend on Main's `using`s") and states the load-order
dependence in julia_function_name's docstring and L184. Everything else in this commit, each case added and run on the
tree before it first (native, f1c16321, and this commit):
- A19B1 = A19E3: host_runtime_js takes the record of a module's function imports, `(module, field)` in index order
  (RuntimeFinalizer.generate over the translator's record, runtime_generator.dart:128/:60), and _compile generates the
  module's runtime from its own record (function_import_names, through imported_function) and returns it beside the
  bytes, CompileResult.runtime (compile.dart:648-669), projected by compile_with_runtime and compile_multi_with_runtime
  (L158's entries; the docs example uses the first); the reader leaves src: test/wasm_reader.jl, a test tool as dart's
  wasm2wat and wasm_read_write_test are, through which the byte-holding harnesses read the record (module_runtime_js).
  host_imports.jl's 'the host runtime is the module's own imports' checks the compile's runtime equals the one built from
  what the bytes declare and the engine's WebAssembly.Module.imports; L150 and L65 restated (no codegen definition takes a
  module's bytes, no reader name in src); MARCH 13.16 and downstream.yml state the API.
- A19B2 + A19B3 = A19E6, A19E4 (in test/wasm_reader.jl): read_u32! (at most 5 bytes, the 5th holding bits 28-31 alone)
  and read_s33! (the 5th's high bits the sign's extension) for every field; a global's value type, heap type and
  mutability as ValueType/RefType/HeapType.deserialize accept them (type.dart:67, :256, :361), mutability 0 or 1; each
  section a view over the module's bytes, so a message names the module's byte. host_imports.jl's reader testset:
  `gref(0x7f)`, a ten-byte heap type, refused (asserted accepted before); a 6-byte u32 and a 5-byte u32 holding bit 32
  refused, a long 5-byte count read; extern spelled in five bytes and a type index read; an unknown value type, an
  unknown heap type, a prefix-less index and mutability 5 refused; the section's end named at byte 16.
- A19B4: write_name! refuses a name that is not UTF-8 through _module_invalid (test/builder_cases.jl row x, held by L166);
  no program reaches it: Julia's own MethodInstance printer throws InvalidCharError for such a Symbol first (A19B7, on
  MARCH 13.17). A19B5: WasmImport is an imported function (ImportedFunction, function.dart:183), its kind field gone and
  the serializer writing 0x00 (:202); the four filters (num_imported_funcs, imported_function, the name section,
  _is_host_declared_import) go. A19B6: L185 finds each reader through the parser (field_readers), any receiver, and
  counts the readers exactly.
- A19C2 = A19E1: a function's name is the call form Julia prints for its MethodInstance (show_mi, show.jl:1388:
  argument types only, the function qualified unless exported from its module or Main's), then ` @ ` and its method's
  module as a stack frame prints it; the invoke-only suffix before the module. `_gn_alike` compiles and answers 9 (a
  WasmInternalError on f1c16321); the name's one limit, two same-named functions printed unqualified whose methods of
  one signature one module defines (`_gn_res`), is a WasmCompileError naming both methods' lines (L118's third site);
  any other same-text pair stays a WasmInternalError, forced by a unit test (one specialization planned twice). A19C5:
  the docstrings and compile_multi's say so (aliases off: `Array{Int64, 1}`). The probes are re-recorded: 54 of 225
  baseline lines change, and with custom sections stripped and export names dropped all 225 modules print as on
  f1c16321 (1,463 functions: export names 29,950 to 32,270 bytes, function names 58,449 to 63,406).
- A19C3: the printer's questions asked as it runs them, one site (_printer_method, L171's allowlist): `show` and `print`
  over IOContext{IOBuffer}, `print` for the function slot unless it is a function's own singleton type, a value
  parameter accepted only when Base or Core shows it and its type is theirs or its show is the generic one
  (generated_names.jl `_gn_ctx`, `_gn_call`, `_gn_signed`, each named by the user's text on f1c16321); the capability
  this refuses (a package-shown value parameter, Unitful's units) is on MARCH 13.10.
- A19C4 + A19C9: plan_function_names! names by `mi ∈ plan.invoke_only`, the one consult's answer; the grouping by text
  and `morespecific` go; each signature is printed once per plan (an IdDict beside the plan); the two claims restated
  (trim_compile_plan's unnamed entries, julia_function_name's load order).
- A19C6: the bindings are checked against `values(plan.roots)` (real_bottom_exceptions.jl: a binding and an invoke target
  naming a non-root's signature refused, both accepted on f1c16321). A19C7 = A19E5: run_link_roots refuses an index
  outside the module's functions, an ArgumentError naming the request (`-1`: an internal error on f1c16321; `10000`: a
  ModuleValidationError after codegen). A19C8 = A19E7: one ExportNamer, made at the compile's setup before the tag is
  exported and held by its Translator (translator.dart:163), read by the tag, the compile's exports and the class reader;
  a host's setup of the module it prepares, before any compile, names its one export through its own (L184).
- Each new or tightened lock (L65, L118, L150, L158, L166's row x, L171, L184, L185) was planted, fired and restored on
  this commit, and the QA files ran through runtests.jl's shards.

## 2026-10-21 — audited through 36e3966e (f1c16321..36e3966e: 119x, 117a, the blocking gate hardened and its best re-recorded)

The twentieth audit covers:
- a0cbd7cb, batch 119x, the nineteenth audit's fixes (its entry);
- cfaacbb4, batch 117a, the numeric tables' generated cases and the emission-diff check (an addendum, all four areas);
- d5b96e97, batch 119g, the blocking gate hardened (an addendum, all four areas);
- 36e3966e, timing-1318, ratchet@warm's best re-recorded and cfaacbb4's red matrix filed (an addendum, enforcement).

It made 62 findings in the four areas: 44 on a0cbd7cb and cfaacbb4 (builder A20B1-A20B8, emission A20E1-A20E10,
collection A20C1-A20C11, enforcement A20P1-A20P16), 13 on d5b96e97 (A20B9, A20E11, A20E12, A20C12-A20C14,
A20P17-A20P22) and 5 on 36e3966e (A20P24-A20P28); beside them A20P23 (the orchestrator's, on 13.18), A20P29 (the
orchestrator's, on L154), A20X1-A20X4 (117a's own two, the gate's busy threshold, Windows CI's crash) and three found while the fixes were made (A20N1-A20N3). Several
were seen from two areas (A20B1 = A20E1 = A20E8 = A20P9, A20B7 = A20E10, A20E4 = A20C2 = A20P1, A20E6 = A20P3, A20C7 =
A20P10, A20C8 = A20P2, A20E11 = A20C12 = A20P17 with A19C1 = A19E2, A20P21 = A20P27). No silent wrong answer is in the range. A valid program refused, in the
range: A20E4 = A20C2 = A20P1, two distinct functions that print alike (a module and the module that replaced it,
`Val{1}` and `Val{Int32(1)}`) raised a WasmInternalError, a planner defect by its kind, where Julia answers. Two silent
losses of what was asked: A20C5, an entry the planner skipped (an unpackable Vararg, a metadata operation) left out of
the module with no error (on d5b96e97 `compile(_va, (Vararg{Any},))` returns a module with no export for it); A20C10, a
generator type dropped by any exception its sample call raised. A20E9's suspect wrong answer, a narrow shift amount on a
128-bit value, was run and raised (every 128-bit shift by a narrow amount, 252 inputs, at 8170df59): loud, not wrong.

Area: builder — (A20B1 = A20E1 = A20E8) the shipped runtime ran in no lane: every harness read it back from the bytes,
and one testset compared the two, for two compiles. (A20B2) a name not UTF-8 was refused in to_bytes, not where it
entered the module, naming neither its kind nor its index. (A20B3) the reader took a negative heap type code in more
than one byte, and host_imports.jl asserted extern in five bytes accepted. (A20B4) L185 read no src file outside
codegen, frontend and ext, and no spelling but `.imports`. (A20B5) "one namer per compile" counted one spelling,
`ExportNamer(mod)`. (A20B6 = A20E2) compile_with_base's module had no runtime, and 13.16 pointed at a non-public
function. Addendum cfaacbb4 — (A20B7 = A20E10) a second test-side decoder in emission_fingerprint.jl, with none of the
reader's bounds. (A20B8) 117a's "the 5 probes differ only by the saturation" named no sha, measured before its rebase.
Addendum d5b96e97 — (A20B9) the warm runner's reset_main! stores Main's binding table and key set without Main's lock
and checks no task a request left running; its start check writes before it verifies the offsets.

Area: emission and diagnostics — (A20E1) = A20B1. (A20E2) no public entry but the two `_with_runtime` ones handed back a
runtime. (A20E3) under optimize the runtime is the module's before wasm-opt, and no row checked declared ⊆ given.
(A20E4) = A20C2. (A20E5) the alike-names diagnostic carried no location, its test one line of two. (A20E6) = A20P3.
(A20E7) the fingerprint logs named no tree. Addendum cfaacbb4 — (A20E8) = A20B1. (A20E9) above. (A20E10) = A20B7.
Addendum d5b96e97 — (A20E11) = A20C12. (A20E12) emission code no blocking runner for its file runs (481 lines of
calls.jl, 206 of builtins.jl, int128.jl's sub, ctlz and neg emitters whole, measured on d77ad3e1).

Area: collection and planning — (A20C1) a value parameter's type was not asked (`show(io, typeof(x))` is the generic
show's first call), and "its type is theirs" read the outer type alone (`Complex{UserReal}`'s Base show runs the
user's `signbit`). (A20C2) two distinct modules print alike by their path of names, so "alike only when unqualified"
was false and the check fell to a WasmInternalError. (A20C3) the refusal always said `show`, named no printer method,
and was false for a Base show calling a value's own methods. (A20C4) `Val{myf}` refused though show_function prints its
name alone. (A20C5) above, and plan.roots the requested entries, not the planned ones. (A20C6) no case tells the one
consult from `morespecific`. (A20C7 = A20P10) an invoke-only function's signature printed twice, an unnamed entry's
outside the memo. (A20C8 = A20P2) the docstring's example unqualified. Addendum cfaacbb4 — (A20C9) smoke's main ran a
selected lazy group never built as 0 cases, green. (A20C10) above. (A20C11) the eager-equals-lazy hash and the load
times named no sha (measured on a1b4a7cd). Addendum d5b96e97 — (A20C12 = A20E11 = A20P17) A19C1 = A19E2 did not land in
119g: the const tables' entry lines unkeyed, so the copysign plant still selects no stage, the 1.13 core not run on
every src change, no copysign plant run through the gate; entry 19 says it did. (A20C13) a stale map only notes,
`pieces_moved` counts keyed lines alone, and no overlay body is in any set. (A20C14) the map's header and L194 do not
state what the selection cannot see.

Area: enforcement and prose — (A20P1) = A20C2, with `_v(Val(1)) + _v(Val(Int32(1)))` its witness. (A20P4) two of entry
19's negatives tested a string, not the rule. (A20P5) L150 and L65 pinned the deleted reader's names, not the absence of
a reader. (A20P6) no test called compile_multi_with_runtime or passed a runtime entry a diagnostics sink. (A20P7)
resolution claims with no evidence file or none naming a tree (the QA files ran through a script of their own, not the
shards; the negatives ran on baf17fca; MARCH's byte counts dated, not shas). (A20P8) open findings with no MARCH row.
(A20P11) L166 and L185's prose. Addendum cfaacbb4 — (A20P12) no row of the gate's map named registry_sample or
narrow_primitive, so a W revert in calls.jl selected neither. (A20P13) the sample dropped Amendment 117-14's "plus every
case that found a wrong answer". (A20P14) cfaacbb4's tree 5d8555b7 gated three times (4.05 green, 1.79 red at 60.5 s,
3.04 green, the red overwritten in place), a live A19P2/A19P5 witness; a0cbd7cb and cfaacbb4 landed on scaled greens
with every stage inside its unscaled budget. (A20P15) smoke_times.tsv's twelve new lines named no run, registry_sample's
an unmarked estimate. (A20P16) the landed message's numbers measured on other trees: load 4.7 → 1.2-1.4 s on a1b4a7cd,
17,074 bodies on 19328551, 317/277 s whole stages of 817/740 cases. Addendum d5b96e97 — (A20P17) = A20C12. (A20P18) d5b96e97
landed under cfaacbb4's land.sh, the record copied by hand to the old name, after 119g's own land.sh refused on
cfaacbb4's red matrix (gate.yml run 39569266159, the emission check); the matrix rule reads the last landed head's red
alone. (A20P19) the exemption landed without
its best raised (ratchet@warm 10.69, measured 15.6). (A20P20) the new bests name no sha (warm 963425c6, fresh 68a40294
at factor 1.54). (A20P21) a red binds one tree. (A20P22) AGENTS.md lost "only" and "every" and names `--block` without
`--warm`.
Addendum 36e3966e — (A20P24) 13.18's check, "ratchet@warm at or under its recorded best", is met by the re-record itself.
(A20P25) the best 14.1 was set by hand, the loosest quiet figure from one record of another tree. (A20P26) an existing
row's exemption is re-armed by editing its text, which timing_exemption counts as an added row. (A20P27) = A20P21,
witnessed: record 8c31a1f7-1's red escaped by amending the commit's prose. (A20P28) the 35-body row omits that its base
file came from unlanded bootstrap code and states "each real" as fact. (A20P29) L154 refuses with a count alone, naming
neither the ID or row nor the rule's form it breaks, and a group label may start at a finding ID, so a finding ahead of
it is read as part of the label's name.
Outside the areas — (A20X4) Windows shard 0 died with 0xC0000005 in real_bottom_exceptions.jl (gate.yml runs 39569271775
and 39588838768, Julia 1.12 and 1.13): the test's native oracle exhausts the native stack on a task, which Julia on
Windows does not reliably detect (no guard page reset on a task switch), flaky and not a0cbd7cb's.

Resolution: entry 19 corrected first. A19C1 = A19E2 was not fixed by 119g: d5b96e97's message claims A19P1-A19P11
alone, and at d5b96e97 the copysign plant still selected no stage (A20E11 = A20C12 = A20P17). Entry 19's "planted, fired
and restored on this commit" ran on baf17fca, whose src and test equal a0cbd7cb's; its "the QA files ran through
runtests.jl's shards" ran through a script of their own. A20B8: the landed message's probe claim was measured on
66c4238e against 52c0a9bd; on the landed pair, a0cbd7cb against cfaacbb4, the 5 probes differ by additions alone, 1
saturation per shift probe and 5 in fc_types_equal_pow. A20C11: the eager-equals-lazy hash (dc88165b) and the load
times were measured on a1b4a7cd; on cfaacbb4 the hash over every case, every lazy group built, is c7ff0b96 (1,781
cases). A20P14 and A20P16 are recorded above; the landed messages cannot change. A20P18, as the orchestrator states it:
d5b96e97 landed under cfaacbb4's land.sh with the per-run record copied to the single-file name because 119g's land.sh
refused on cfaacbb4's red matrix. A20P26 and A20P27, as the orchestrator states them: 36e3966e raised a best by editing
the existing 13.18 row, which the gate counted as an added row, and escaped a red record by amending prose. A20E9's
128-bit narrow shift raised where Julia answers, never a wrong value: the builder's typed-stack check
(instr_builder.jl:239) refused the module, correct by construction doing its job.

This entry lands alone, prose only: the fixes for the range are not in it. They are on march/120x (7d395ea0: A19E8,
A20E9 with A20P13, A20C12 = A20E11 = A20P17 = A19C1 (a)-(c) = A19E2 with A20C13 and A20C14, A20B1 = A20E1 = A20E2 = A20E8 =
A20P9, A20B2-A20B7, A20E3, A20E7, A20C1-A20C10, A20P2-A20P8, A20P11, A20P12, A20P15, A20X4's stand-in oracles), on
march/120x-2 (A20B9, A20P19-A20P29, A20X1, A20X3) and with eff-compile3 (A20N3), none landed; each lands as its own
commit through `dev/land.sh land` with its case, and until then every one of them is open on MARCH 13.17 (C10's on
13.18). Open besides, on 13.17: A19C1's remainder (d) a piece is 40 lines, (e) the cover is a 1-cover, (g) the 1.13 core
does not run on every src change; A20X2, the 35 bodies the registry cases emit that no case enters (120x-3); A19X2,
A19X4, A19X5, A19X6 (eff-compile3); A20N1, an entry over a packed runtime Vararg raising an internal stack underflow (on
cfaacbb4 too); A20N2, planning running a value parameter's own `hash` and, in the IR's text, its `show`; A20E12, the
emission code no blocking runner for its file runs.

Addendum 268c4d9b (the self-serve landing, L197, L198, the factor cap voiding timing only): the author's statement, not
an independent audit; the enforcement lane audits it in entry 21. `dev/land.sh land` lands from any worktree through
`merge`, the one landing path, which logs each landing to the main tree's git-ignored dev/.loop/landings.tsv; L197 holds
every landing to a line and the median of the last five to 180 s (src) or 90 s, L198 records whether each landing's
timing was judged; past the gate's factor cap the timing ratchet is unjudged while the checks and literal budgets are
still judged. Its own landing took 153 s edit to landed against its 90 s target (MARCH 13.18 names the cause).

## 2026-10-21 — audited through 2da1eab3 (36e3966e..2da1eab3: the self-serve landing and its four fixes)

The twenty-first audit covers 268c4d9b (`dev/land.sh land`, the landing log, L197, L198, the factor cap voiding the
timing ratchet only), e7da6e9c (entry 20, prose), ba4aea80 (a cold green run lands, its timing judged by a warm run
after the push; busy read against the machine's CPUs), 69332381 (a landing's own line out of its gate's judgement;
SLOWER and OVER only under the cap; a red timing's debt lifted by a MARCH row; a stale Manifest.toml refused) and
2da1eab3 (L197 judges its median from three lines). Until this entry they were audited by their author alone (entry
20's addendum is the author's statement); this is the second reader. No wrong answer: no landing in the range landed
on a red record, each landed record's checks all ok (268c4d9b on 8fbe5fff-2, warm; ba4aea80 on c2c041e2-1, cold;
69332381 on a7e7e415-1, cold; 2da1eab3 on d554ed33-1, warm). The nearest are A21E1, a correctness red found on a
landed head after its push dismissed or dropped, and A21E2, ba4aea80's literal budgets never held. Fourteen findings:
A21E1-A21E9, A21N1-A21N5.

Verified as stated: ba4aea80's judgement after its push (record c2c041e2-2, red, "a check fails") ran L197 on that
landing's own new line, and 69332381 leaves the gated commit's line out (l197_check's `head`); ba4aea80's line was
written FAILED and rewritten to unjudged by hand, the correction stated in 13.18 alone; the code does what the
orchestrator ruled (a cold run judges its checks only, timing_failures empty when cold; a budget missed past the cap
is no verdict; the unjudged streak printed, never refused; a 13.x row in the landing's own tree naming the red
landing lifts its debt), A21E1 aside.

Area: builder — empty by diff: `git diff 36e3966e..2da1eab3 --stat` names no file under src/ or ext/.

Area: collection and planning — empty by diff, as above.

Area: emission and diagnostics — empty by diff, as above.

Area: enforcement and prose — the whole audit: every hunk of dev/land.sh, dev/block.jl, dev/block_runner.jl,
test/parity_ratchet.jl, dev/MARCH.md, dev/CHARTER.md, AGENTS.md and .gitignore, against the gate records in wt-loop.
(A21E1, high) After a cold landing the warm run's correctness reds lose their force: a failed check other than the
ratchet's is written FAILED and lifted by any 13.x row holding the landing's first 8 hex digits (owed_lifted reads a
row, not a fix), where a red matrix refuses until fixed; a failed ratchet check is dropped (`grep -vx ratchet`), so a
lock red on the landed head is written SLOWER, OVER or unjudged and owes nothing. With the own line left out, a lock
that passes cold and fails warm on one tree is nondeterminism this hides. (A21E2, high) A literal budget is not held
after a cold landing on a machine past the cap: the cold run judges no budget, and the warm run's missed budget past
the cap is no verdict, written unjudged, owing nothing. Witness: ba4aea80 landed on c2c041e2-1 (cold, 253.2 s,
factor 3.89, a stage over its budget); its judgement c2c041e2-2 missed the total (62.1 s of 60) and the ratchet's
(34.8 s of 30) at factor 2.84; its line reads unjudged. (A21E3, medium) L197 is met without a fast loop: any MARCH
table line holding a landing's 8 hex digits takes it out of the window, without bound and without stating a cause;
the median is judged only over three unexcused lines, so excused slow landings leave it unjudged (today two lines,
69332381 at 1.40 and 2da1eab3 at 0.54: it has never judged); the edit is the author time, which a re-commit resets
(268c4d9b's line reads 153 s; its first attempt, 762cffbc, began at 14:04Z, 76 minutes before it landed). (A21E4,
medium) L197's evidence is the main tree's git-ignored landings.tsv: landed_at and timing are checked against nothing
git holds, so an edit leaves no trace (ba4aea80's FAILED rewritten by hand), CI counts nothing, and no lock reads
steps.tsv. (A21E5, high) Two landing paths and two holds: `dev/land.sh merge <branch>` still lands alone, without the
hold, the Charter: and Charter-change refusals or the Manifest refusal, which only the land arm has; the
orchestrator's hold (locks/HOLD) and land's (dev/.block/HOLD) are separate files outside git, land reads only its
own and runs julia outside the agents' scheduler, and that scheduler lets a job at priority 1 or below, and every job
already running, through land's hold. (A21E6, high) The standing Charter-change authorisation is unbounded:
`CHARTER_AUTHORISED="C10:2026-10-21"` admits any later edit inside C10, a raised budget or a deleted check, by any
commit carrying the line, landed self-serve and reviewed only after (the orchestrator's charter-diff review before a
landing no longer runs); the clause-scope program has no fixed-text case, L197 pinning the constant by needle alone;
the row-number exemption also passes a deleted Planned citation and a deleted "and". (A21E7, medium) A change to the
landing's own rules lands judged by itself: land runs the rebased branch's land.sh and block.jl, so each commit of
the range landed under the rules it brought, and ba4aea80's judged its own line. (A21E8, medium) No timing judgement
is ever forced: the unjudged streak is printed, never refused, and CI judges no timing, so on a machine past the cap
L195 is never judged and nothing fails (the orchestrator's ruling, recorded for Dale). (A21E9, low) The negatives the
four messages state have no evidence naming the command, the tree and its output (charter rule 6); the loop's
measurements record the landings alone.
(A21N1, high) dev/CHARTER.md C10 is untrue of the code: "a landing's gate ... at most 60 s of wall" and L195's "its
checks and budgets still judged", where since ba4aea80 a cold run lands with no budget judged (ba4aea80 on 253.2 s,
69332381 on 87.2 s), and ba4aea80 carried no Charter-change line; L197's text names neither the MARCH exclusion nor
the three-line threshold, and its "changes src" is src/, ext/ or Project.toml in the lock. (A21N2, medium)
268c4d9b's diff to dev/CHARTER.md lies inside C10, adds L197 and L198 with the contract's 180 s and 90 s targets, and
also relaxes L195 past the cap from no verdict to green with timing unjudged; whether "C10's speed checks" covers a
relaxation is Dale's to confirm. (A21N3, low) AGENTS.md's table names the landing gate `bash dev/gate.sh --block`, at
most 60 s, where a landing is `dev/land.sh land`, its gate `--block --warm`, a cold run unbounded; "a new lock fires
when broken before it counts" drops the restore. (A21N4, low) dev/land.sh's comments: "no other agent's Julia job
starts" (A21E5); the log's timing "judged, or unjudged when past the cap" (also cold, SLOWER, OVER, FAILED); the owed
comments name SLOWER or FAILED without OVER or the row's lift. dev/block.jl's header calls a budget missed past the
cap red; since ba4aea80 it is no verdict. (A21N5, low) MARCH 13.18: "defect (1)" names an item of an agent's report;
"the cold run leaves the critical path in the next commit" records finished work; 268c4d9b's 153 s omits its three
refused attempts; the row's check, ratchet@warm at or under its best, checks none of the landing items it now holds.

Resolution: this entry lands alone, prose only, and fixes nothing. Every finding is open on MARCH 13.18. A21E1, A21E2
and A21E5 come first, one commit each through `dev/land.sh land` with its case and its negative's evidence. A21N1,
A21N2 and the charter halves of A21E6 and A21E8 are proposals to Dale through the orchestrator; dev/CHARTER.md is not
edited here. A21E9 stands recorded: the next negatives carry their evidence.

## 2026-10-21 — audited through d41b08ab (2da1eab3..d41b08ab: entry 21, one landing path, the gate's map and tables, the stack stand-ins)

The twenty-second audit covers b0466fa0 (entry 21, prose; its own author's, nothing to add), f83c3365 (one landing
path and one hold, A21E5), da8d5b69 (the gate's map keys every top-level form, a plan's overlay bodies count as run,
the lowering files' rows name the sample), cd42cae5 (a changed numeric lowering-table entry runs the generated cases
that case it, test/block_tables.tsv) and d41b08ab (stand-ins raise StackOverflowError where the wasm body exhausts its
stack; R36 counts a native exhaustion in a test statement). It is audited against Dale's order of 17:05Z as well: a
large run (the full matrix, a full Pkg.test, lanes.sh, a long re-record) only when a clause closes, a landing's evidence
its blocking-gate record. No wrong answer, and no landing in the range landed on a red record. Eleven findings:
A22E1-A22E9, A22N1, A22N2. A21E5 is fixed by f83c3365: `merge` refuses unless the landing holding the hold called it,
and the orchestrator's hold is the same file with owner 0.

Area: builder — empty by diff: `git diff 2da1eab3..d41b08ab --stat` names no file under src/ or ext/.

Area: collection and planning — empty by diff in src; the gate's map of src, its recorder (test/block_impact.jl) and
the generated cases' entry records are tooling, audited under enforcement.

Area: emission and diagnostics — empty by diff, as above.

Area: enforcement and prose — every hunk of dev/land.sh, dev/block.jl, test/block_impact.jl, test/block_groups.tsv,
test/block_tables.tsv, test/registry_cases.jl, test/smoke.jl, test/real_bottom_exceptions.jl, test/parity_ratchet.jl
and dev/MARCH.md, against the landing log. (A22E1, high) L197 has never judged and is now met by mention: 13.18 names
seven of the ten landings since its start, six by their cause and f83c3365 (308 s, 3.42 times its target) only inside
da8d5b69's cause, which takes it out of the window; the window holds 2da1eab3 and d41b08ab, two lines, not judged.
f83c3365's first tree was red on L197 and the answer was rows naming landings. A21E3, witnessed. (A22E2, medium)
cd42cae5's and d41b08ab's author_at equal their land_start to the second: edit to landed measures commit to landed.
(A22E3, medium) A changed entry of INT128_OPS (julia_numeric_tier.jl) runs no generated case and fails nothing:
dev/block.jl skips any const no generator cases (`(e[1], e[2]) in known || continue`), and block_tables.tsv holds
seven tables; a numeric lowering table no generator cases should fail or sit on an exact allowlist with its reason.
(A22E4, medium) The map is part measured, part hand-written: five rows of block_groups.tsv gain registry_sample and
narrow_primitive by hand on a map measured on src tree d77ad3e1, 17 pieces moved since, and nothing marks the hand
rows; its re-record, about 34 minutes of one Julia process, is a long re-record Dale's order confines to a clause's
closure, so A20C13's "the map re-recorded" cannot land before C10 closes as written. (A22E5, medium) The warm runner
answers differently from a fresh process: on d41b08ab test/diagnostic_attribution.jl's "receiver-free
print/println/show reject loudly" fails under the runner (string_index_err collected with no recorded reason) and
passes in a fresh process (119x's measurement); the orchestrator reads it as A20N3, Base.stdout's live value read as a
program value, fixed in compile3's first commit, not landed. No check compares the runner's answer with a fresh one.
(A22E6, low) The merge guard is a convention: a shell that writes its pid into dev/.block/HOLD and passes LAND_HOLDER
passes it; the owner-0 hold reads as alive only because `kill -0 0` succeeds for the caller's process group; jlhold
and the scheduler that honours the hold are outside the repository, so no lock reads them. (A22E7, medium) Against
Dale's order, at d41b08ab every landing pushes march/<leaf>, gate.yml runs the full matrix on it, and `merge` reads the
last landed head's matrix and refuses on its red: each landing relies on a full run; C10's text (the full matrix on
every landed head, L153, L162) and AGENTS.md say the same. opus-loop's commit 8 moves gate.yml; C10's text is Dale's.
(A22E8, low) cd42cae5's plant evidence ran on 42f4e6b2, another tree (A20P16's class). (A22E9, medium, C3 C5)
d41b08ab's stand-ins replace the native oracle on every platform: `_wt_eb_sn` and `_wt_hb_s2n` throw
StackOverflowError by hand, so s_then_r, o and o_again compare the wasm body with the test's account of what Julia
does, not Julia's answer, on macOS and Linux too, where the native exhaustion was caught; a stand-in only where Julia
cannot detect the exhaustion, or the native oracle in a process whose death is reported, keeps Julia the oracle.
(A22N1, low) 13.18 records finished work ("holds: fixed, `merge` runs only as land's internal step"). (A22N2, low)
`prepare` still ends by printing "dev/land.sh merge <branch> lands it", a command that now refuses.

Resolution: this entry lands alone, prose only, and fixes nothing. A22E1-A22E8, A22N1 and A22N2 are open on MARCH 13.18,
A22E9 on 13.17; A22E4's re-record and A22E7's charter text are for Dale under the order of 17:05Z; A22E5 closes when
compile3's first commit lands and the case passes under the runner.

## 2026-10-21 — audited through 0459332a (d41b08ab..0459332a: entry 22, the charter pin, a red lock owes a fix, the closure matrix, the carried log)

The twenty-third audit covers b31a7671 (entry 22, prose; its author's, nothing to add), d9d5a2db (a dev/CHARTER.md
change lands only as the exact change authorised, A21E6; a budget missed past the factor cap lands as unjudged),
41d48aef (any check failing after a cold landing is FAILED and owes a warm green fix, never a row, A21E1), 90a6984d
(the full matrix runs only at clause closure, a `Closes: C<n>` line its trigger) and 0459332a (each landing carries the
landing log in its own tree, A21E4). Its range starts at d41b08ab, where entry 22 was audited through. It reads the loop by one 300-s target, a landing over it a finding about what
blocked it. No wrong answer; no landing landed on a red record. A21E1, A21E4 and A21E6 are fixed as their commits
state (FAILED owed by `merge` until a warm green record; the carried copy a line-by-line prefix of the ignored log;
the blob pair listed in the main tree's dev/.block/charter_authorised). A22E5 is not verifiable yet: compile3's first
commit is not on origin at 0459332a. Eight findings: A23E1-A23E7, A23N1.

Area: builder — empty by diff: `git diff b31a7671..0459332a --stat` names no file under src/ or ext/.

Area: collection and planning — empty by diff, as above.

Area: emission and diagnostics — empty by diff, as above.

Area: enforcement and prose — every hunk of dev/land.sh, dev/block.jl, dev/gate.sh, dev/hooks/commit-msg,
.github/workflows/gate.yml, test/parity_ratchet.jl, .gitignore, AGENTS.md, dev/MARCH.md and dev/.loop/landings.log,
against the landing log and gh's runs of the march branch. (A23E1, high) The timing has gone unjudged on five
landings in a row, b31a7671 to 0459332a, each past the cap (factor 1.75 to 3.47) with the ratchet's budget missed
(36.4 to 44.5 s of 30) and two totals over 60 s; since d9d5a2db such a run lands, so no budget binds a landing on this
machine as it now runs, and nothing ends the streak (A21E8). C10's "at most 60 s" and L195's "its checks and budgets
still judged" are untrue (A21N1), d9d5a2db carrying no Charter-change line. (A23E2, high) Four landings took past 300
s, each blocked by the same two causes: d9d5a2db 3346 s, 41d48aef 2675 s, 90a6984d 1424 s and 0459332a 1020 s waited
for entry 22 (L148 refused the sixth commit after entry 21 until it landed, 17:51Z, twenty minutes after its fourth
commit) and then for one another through the one hold, on a machine at load 12 to 14 whose cold gate took 180.9 and
212.7 s. The audit lane is on the landing path at every fifth commit; its trigger must leave the entry landed before
the fifth. (A23E3, medium) Each of the four is excused from L197 by the next commit's 13.18 text naming it (d9d5a2db
named in 41d48aef, 41d48aef in 90a6984d, 90a6984d in 0459332a): every landing over target in the range is out of the
window by a mention, A22E1 unchanged until the excuse files land. (A23E4, medium) Against Dale's order a full CI run
still starts on every landing: PR #122's ci.yml, formal.yml and downstream.yml run on each push of the march branch
(gh lists them for d9d5a2db, 41d48aef, 90a6984d and 0459332a), each cancelled only by the next landing; 90a6984d moved
gate.yml alone. (A23E5, medium) Four clauses read CLOSED, C0, C4, C7 and C8, and no closure matrix has run for any:
no commit carries `Closes:`, and CLOSED is the ratchet's reading alone; nothing ties a CLOSED clause to a green
closure matrix of its closing commit. (A23E6, low) gate.yml names its run "Gate closure" when the pushed message
contains "Closes: C" anywhere (90a6984d's own prose does) while its decision step runs the matrix only on a line
`^Closes: C<n>`: a run named for a closure ran none. `land` reads the commit from git and is not misled. (A23E7, low)
The authorisation of a charter change, the exact blob pair, lives in the main tree's git-ignored
dev/.block/charter_authorised: the landed commit carries its Charter-change line, but who listed the pair and when
leaves no trace in git; and `land` amends the branch head to carry the log, so the landed tree is never the tree its
author's evidence names. (A23N1, low) dev/.loop/landings.log carries ba4aea80's line as rewritten by hand before the
carry; the carried log freezes the lines from 0459332a on, not before.

Resolution: this entry lands alone, prose only, and fixes nothing. A23E1-A23E7 and A23N1 are open on MARCH 13.18;
A23E1's charter text and A23E5's closure runs are for Dale through the orchestrator; A22E5 is verified in entry 24 on the
record of compile3's first commit.

## 2026-10-21 — audited through 96d0a472 (0459332a..96d0a472: entry 23 and the stale map)

The twenty-fourth audit covers cb9666bb and be2416a2 (entry 23 and its correction, prose; their author's), fc9db3b8 (a
stale map fails a src change; the map's header states what the selection cannot see, A20C13, A20C14) and 96d0a472
(L194's stale-map cases read the budget as a value; 13.18 names be2416a2). From this entry each one carries the
red-flag class of Dale's order of 18:50Z: a claim of strictness, closure or a guarantee resting on a scan, an
allowlist or a ratchet. No wrong answer. Each landed head's record is green, but two landed commits have red trees
(A24E1). A22E5 is still not verifiable: compile3's first commit is not on origin at 96d0a472. The timing is unjudged
on all three landings, eight in a row (A23E1, not filed again). Four findings: A24E1-A24E3 and A24S1.

Area: builder — empty by diff: `git diff 0459332a..96d0a472 --stat` names no file under src/ or ext/.

Area: collection and planning — empty by diff, as above.

Area: emission and diagnostics — empty by diff, as above.

Area: enforcement and prose — every hunk of dev/block.jl, test/block_groups.tsv, test/parity_ratchet.jl, dev/MARCH.md
and dev/.loop/landings.log. (A24E1, medium) A multi-commit landing puts a commit with a red tree into the march
branch's history, because `merge` judges the head's tree alone. fc9db3b8's tree e70d776e is red on L194: its new case
threw, so at that commit L194 checked nothing past it. cb9666bb's tree d009e529 is red on L148 and L197: this auditor's
own entry 23, landed with its correction on top. Neither head landed red, and history carries both. (A24E2, high) Every
src landing is now refused until the map is re-recorded. fc9db3b8 counts 17 pieces moved against a budget of 8 and
says so. The re-record is about 34 minutes of one Julia process at JLRUN_PRIO=5, and longer at the machine's present
factor of about 3. No one is assigned to run it and nothing starts it. Once it lands, every 8 pieces of src movement
puts the next src landing behind another re-record. (A24E3, medium) 96d0a472 took 977 s edit to landed, over the
300-s reading. Its first gate was red on L194's throw and on L197, which read be2416a2's 436 s with no named cause. Each
landing is again hostage to a row naming the one before it, the pattern 2da1eab3 meant to end; loop2's excuse files
and its one 300-s target retire it. (A24S1, red flag) fc9db3b8's header for test/block_groups.tsv calls A19C1's (f),
"the universe", closed because "a stale map and ext/ fail the gate", and calls (a)-(c) closed in the code. The
stopgaps are a gate-time staleness count over a measured coverage map and a gate-time refusal of ext/. The map is a
measurement of which cases ran which lines, and a selection read from it is a heuristic however fresh it is. The
construction that would retire it: the gate runs every case whose plan compiles a changed body, read from the plan's
own record of what it compiled. dart2wasm's whole-program compile has no selection to go stale. Until that exists,
A19C1 (a)-(c) and (f) stay open.

Resolution: this entry lands alone, prose only, and fixes nothing. A24E1-A24E3 and A24S1 are open on MARCH 13.18. A24S1's
reopening of A19C1 (a)-(c) and (f) is the orchestrator's to rule, and A24E2's re-record has no owner yet.

## 2026-10-21 — audited through ea417dd0 (96d0a472..ea417dd0: entry 24, the one 300-s target, the stack oracle)

The twenty-fifth audit covers 0b236537 and b85da40f (entry 24 and its excuse row, prose; their author's), 246c7762 (one
300-s loop target; an excuse is exactly its tracked file dev/.loop/excuse/<sha8>, A22E1, A22N2), d2d1f7bc (a stack
exhaustion's oracle is Julia's own answer wherever Julia detects it, the stand-in only on Windows, A22E9) and ea417dd0
(246c7762's 765 s excused). No wrong answer. Each landed head's record is green. A22E1, A22N2 and A22E9 are fixed as
their commits state. On A22E9: `_wt_stack_oracle` takes the stand-in only when `Sys.iswindows()`. The orchestrator's
ruling on A24S1 is recorded: A19C1 (a)-(c) and (f) reopen, and 13.17 says so. Their construction is the gate running
every case whose plan compiles a changed body, read from the plan's own record. A22E5 is still not verifiable, because
compile3's first commit is not on origin. The timing is unjudged on every landing since d41b08ab (A23E1). Four
findings: A25E1-A25E4.

Area: builder — empty by diff: `git diff 96d0a472..ea417dd0 --stat` names no file under src/ or ext/.

Area: collection and planning — empty by diff, as above.

Area: emission and diagnostics — empty by diff, as above.

Area: enforcement and prose — every hunk of dev/land.sh, test/parity_ratchet.jl, test/real_bottom_exceptions.jl,
.gitignore, dev/MARCH.md, dev/.loop/landings.log and the nine excuse files. (A25E1, medium) The excuse files still leave
each landing hostage to the slow one before it. The median of the last five unexcused landings holds a slow landing
until a later commit excuses it. ea417dd0 was red until it excused 246c7762. This entry, on ea417dd0's tree, reads
d41b08ab 0.17, b31a7671 0.31, 96d0a472 3.26, b85da40f 1.06 and ea417dd0 5.26, a median of 1.06, and carries
ea417dd0's excuse to land. A24E3 is not retired. (A25E2, medium) An excuse is checked for its form alone: one line
headed machine, lock or crossing. Its cause is not held against the landing log or steps.tsv, such as a "lock" excuse
against the measured hold wait. An author can still excuse any landing with one line, now in git where it can be
reviewed. (A25E3, medium) d2d1f7bc changed R36's rule and landed with "the lock's negatives owed to a run outside the
landing". A lock rule counts only once it has fired when broken (AGENTS.md), and no run is assigned to these
negatives. (A25E4, low) ea417dd0 landed d2d1f7bc with it, two commits in one landing, before the one-commit rule.
d2d1f7bc's tree 4a9455ca is red on L197 and stands in history (A24E1). ea417dd0 took 1577 s from d2d1f7bc's commit:
the L148 slot order the orchestrator set (entry 24, then 246c7762), the hold, and a first gate red on L197.

Resolution: this entry lands alone, as one commit, prose and one excuse file (dev/.loop/excuse/ea417dd0, its measured
cause, A25E4), and fixes nothing. A25E1-A25E4 are open on MARCH 13.18. A24E1's rule, one commit per landing, is the
loop lane's next commit. The charter commit audited ahead of its landing (wt-strict-adt) is entry 26's, under the
red-flag class.

## 2026-10-21 — audited through a3c27bab (ea417dd0..a3c27bab: entry 25, A22E3, the workflows at closure)

The twenty-sixth audit covers 31d6ca4b (entry 25, prose and an excuse; its author's), 3cec876a (a changed entry of a
lowering table that no generator cases fails, naming the table, A22E3), 29bc7e61 (CI, Formal models and Downstream
trigger only at clause closure, as gate.yml does, A23E4, A23E6), 61333d25 (AGENTS.md back to 90 lines, the workflows'
row its own) and a3c27bab (b85da40f's 318 s excused: 145 s behind march/phase-14's hold, which the orchestrator
approved as measured). 29bc7e61, 61333d25 and a3c27bab landed as one landing. No wrong answer. Each landed head's
record is green. A22E3, A23E4 and A23E6 are fixed as their commits state: the shared closure predicate checks for a
line `Closes: C<digit>` in all four workflows. No red flag: no commit in the range claims strictness, closure or a
guarantee. A22E5 is still not verifiable, because compile3's first commit is not on origin. The timing is unjudged on
every landing since d41b08ab (A23E1). Five findings: A26E1-A26E4 and A26N1.

Area: builder — empty by diff: `git diff ea417dd0..a3c27bab --stat` names no file under src/ or ext/.

Area: collection and planning — empty by diff, as above.

Area: emission and diagnostics — empty by diff, as above.

Area: enforcement and prose — every hunk of dev/block.jl, test/parity_ratchet.jl, the four workflows, AGENTS.md,
dev/MARCH.md, dev/.loop/landings.log and the excuse file. (A26E1, medium) A24E1 is still open. `land` has no
one-commit refusal, and loop2 landed three commits in one landing. 29bc7e61's first tree, gated as 761f5cfa (record
b6c22df5-1), was red on L128. The rebased 29bc7e61 in history still has AGENTS.md at 91 lines, and its fix 61333d25
rides on top of it. (A26E2, medium) A full L148 window turns a landing's gate red. 3cec876a's first tree fb74dc1f
(record 0484d432-1, 19:31:25Z) was red on L148 alone while entry 25 was being written. It waited for entry 25 and then
behind its hold, 332 s in all, where its own landing took 55.7 s. This is A23E2's cause, the audit entry on the landing
path, at a smaller scale. (A26E3, medium) 3cec876a's new L194 cases and its rule that every multi-line const of `key =>
value` entries is a lowering table landed with no negative. The rule is decided by syntax, so a changed entry of a
non-lowering table of that shape would fail as uncased. (A26E4, low) PR #122 now carries no check run. The pull
request triggers nothing, and its final gate is a gate/** push that the pull request does not show. (A26N1, low)
29bc7e61 keeps formal.yml's nightly schedule "beside" the march's triggers. A schedule runs on the default branch, so
the nightly checks main's models, not the march's.

Resolution: this entry lands alone, as one commit, prose and one excuse file (dev/.loop/excuse/3cec876a, its measured
cause, A26E2), and fixes nothing. A26E1-A26E4 and A26N1 are open on MARCH 13.18. A24E1's refusal is the loop lane's
next commit. The charter commit is entry 27's, under the red-flag class.

## 2026-10-21 — audited through 2d0227c1 (a3c27bab..2d0227c1: entry 26, one commit per landing, Phase 14, the timing exemption, the median best)

The twenty-seventh audit covers ae556c79 (entry 26, prose and an excuse; its author's), b3d258fa (one landing is one
commit, A24E1; a Charter-change line names several clauses; excuses corrected as measured), 360811dd (Phase 14 in
MARCH), e6e00706 (a timing exemption is a new MARCH row, never an edited one, A20P26; test/lock_negatives.jl plants
negatives in a scratch checkout) and 2d0227c1 (a best is the median of three judged runs and names its records; 13.24;
C10's Planned text cites 13.24, an added row number the exemption admits). No wrong answer. Each landed head's record is
green. A24E1 is fixed: `land` refuses a branch more than one commit ahead of the tip (land.sh:332). A20P26 is fixed, and
A25E3's class now has a home in lock_negatives.jl. No red flag: Phase 14 plans strictness and claims none. A22E5 is still
not verifiable, because compile3's first commit is not on origin. Three findings: A27E1-A27E3.

Area: builder — empty by diff: `git diff a3c27bab..2d0227c1 --stat` names no file under src/ or ext/.

Area: collection and planning — empty by diff, as above.

Area: emission and diagnostics — empty by diff, as above.

Area: enforcement and prose — every hunk of dev/land.sh, dev/block.jl, test/parity_ratchet.jl, test/lock_negatives.jl,
test/runtests.jl, dev/timing_best.toml, dev/CHARTER.md, dev/MARCH.md, dev/.loop/landings.log and the excuse files.
(A27E1, medium, C10) The locks cost the gate its own speed. On a quiet machine the ratchet stage reads 19.7 s of wall,
19.3 s scaled at factor 1.02 (record c96ec515-3, ae556c79's tree), and 20.1 s at factor 1.09 (record 6fc15995-2,
e6e00706's tree), against its 14.1 s best. Today's additions (L197 to L201, the excuse checks, the STRICT table) grew
it by about 40 per cent. Nothing measures the ratchet's time per lock, so a new lock's cost is seen only as a stage
grown past its best. (A27E2, medium) The 13.24 exemption serves only the commit that added the row: e6e00706 refuses an
existing row. Until the median-of-three update re-records ratchet@warm, every judged run after 2d0227c1 reads the
ratchet SLOWER and owes a debt. 2d0227c1 documents its bests' sources and re-records none: ratchet@warm is still "set
by hand in 36e3966e", and three bests come from one run at factor 1.54, past the cap. (A27E3, low) e6e00706 took 4652 s
and 2d0227c1 3649 s, both past 300. Both were blocked by L148's full windows and the slot order behind entries 24 to 26
and loop2's commits, and e6e00706 also by L197's hostage reading (its excuse states it, measured). The audit lane's
cadence is still the landing path's throttle (A23E2, A26E2).

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A27E1-A27E3 are open on MARCH 13.18.
A27E2 closes when the median-of-three update lands its re-recorded bests under a new row. This entry's own gate read the ratchet SLOWER (record a74e721a-1, 21.2 s at factor 1.13, the red standing),
so by the orchestrator's ruling it carries the exemption row 13.25, backed by the three records, and C10's Planned
text cites it.

## 2026-10-21 — audited through 21e36053 (2d0227c1..21e36053: entry 27, the map re-recorded, incremental re-records, sourced bests)

The twenty-eighth audit covers 13e3b925 (entry 27 with its exemption row 13.25; its author's), d7419914 (the map
re-recorded in full on b85da40f, 31 minutes at JLRUN_PRIO=1; its header states A19C1 (a)-(c) and (f) OPEN as A24S1
ruled), 3ab2fb81 (`test/block_impact.jl --pieces` re-records incrementally; a lowering table is one by its
registration, LOWERING_TABLES, A26E3), 733f4785 (a best is set only by the update; an unsourced one bounds nothing,
A20P25) and 21e36053 (the warm bests and the calibration re-recorded by the update's median of three, 13.27; a timing
line may name a best's key). C10's Planned text gains 13.26 and 13.27, added row numbers alone. No wrong answer. Each
landed head's record is green. A20C13, A26E3, A20P20, A20P25 and A27E2 are fixed as their commits state. No red flag:
no commit claims strictness or closure. A22E5 is still not verifiable, because compile3's first commit is not on
origin. Four findings: A28E1-A28E3 and A28N1.

Area: builder — empty by diff: `git diff 2d0227c1..21e36053 --stat` names no file under src/ or ext/.

Area: collection and planning — empty by diff, as above.

Area: emission and diagnostics — empty by diff, as above.

Area: enforcement and prose — every hunk of dev/block.jl, test/block_impact.jl, test/block_groups.tsv,
test/parity_ratchet.jl, test/lock_negatives.jl, dev/timing_best.toml, dev/CHARTER.md, dev/MARCH.md, dev/HISTORY.md and
the excuse files. (A28E1, high) The re-record loosened the scale every timing judgement reads. Its three runs read
machine factors 1.24, 1.25 and 1.44 against the old calibration, and it re-recorded the calibration itself from them,
0.003477 to 0.004047, 16 per cent slower. A machine 16 per cent slower than before now reads as factor 1.0, and the
1.5 cap now admits one about 1.75 times slower than the old best. The raised bests were measured on that machine and
scaled by that calibration: ratchet@warm 14.1 to 20.45 s, smoke-core@warm 19.75 to 24.2 s, probes@warm 5.57 to 9.92
s. Some of that rise is real: the locks' growth (A27E1) and the probe core's 21 to 41. Their [best_from] entries name
commit cca6cfef, which no branch on origin holds, so the source cannot be checked from the repository. A calibration
should be recorded only at factor 1.0 by its own measure. A best's source should be the landed commit. (A28E2,
medium) 733f4785 left every best unsourced, and its judgement after the push wrote "SLOWER calibration load@warm …".
L198 read a stage name without `@`, so that true line failed L198. Every gate after it was red on the ratchet (record
f91082b4-3) until 21e36053. The rule change had no case that ran its own output through L198, and it stopped every
lane. Its message says "a cold landing of anyone's change still lands". (A28E3, low) d7419914 measured the map with
three cited QA families failing under the measuring harness, their src lines counted. 3ab2fb81 retires A26E3 by a
hand-kept registration of ten consts, held by a scan of their declarations: a stopgap, not claimed strict. A lowering
table that is a type of its own, found by type, would be the construction. (A28N1, low) MARCH is 58 lines of L129's 60,
four of them timing rows (13.24 to 13.27) that each record one exemption already used. Each further exemption is a
line, and the cap is two lines away.

Over 300 s, each blocked by causes outside its change: d7419914 632 s, 3ab2fb81 1450 s, 733f4785 1031 s and 21e36053
603 s. The causes were the hold's queue, the map's 31-minute run on the slot order, and A28E2's red on every gate
between 733f4785 and 21e36053. Excuse files name the first three causes.

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A28E1-A28E3 and A28N1 are open on
MARCH 13.18. A28E1's calibration is for the orchestrator to rule, since it sets what every later timing verdict means.

## 2026-10-21 — audited through e2371eca (21e36053..e2371eca: entry 28, the by-construction charter, one interpreter per compile, the march branch wt2)

The twenty-ninth audit covers 82c16480 (entry 28, prose; its author's), b104dfbb (the charter: strict means by
construction; L201; R44; C4, C7 and C8 reopen; 13.20; landed by hand under `Charter-change: C0 C4 C5 C6 C7 C8
authorised by Dale 2026-10-21`), 82a227bd (one WasmInterpreter per compile, A18C5; a compile reads no stream of the
compiling session, A20N3; every collected body has its reason, ClosedWorld.tla ReasonsComplete; the type-taking methods
pinned, A19X4, L196 cited in C10 under its Charter-change line; ClosedWorldClasses one constructor, A19X5) and e2371eca
(the march branch is wt2 in land.sh, block.jl and L197, with 82a227bd's excuse). No wrong answer. Each landed head's
record is green. b104dfbb's landing gate's ratchet log (wt-strict-adt, tree 44ff74b0) reads C4, C7 and C8 OPEN, each
stopgap named beside its planned check, C0 alone CLOSED, R44 = 225. A18C5, A20N3, A19X4, A19X5 and A22E5 are fixed as
82a227bd states. Two red flags: A29S1 and A29S2. From this entry on each landing also answers two questions: does every
requirement it touches have its programmatic check, and does a lock fire inside its stated intent band. Eleven
findings: A29S1-A29S3, A29C1-A29C4 and A29E1-A29E4.

Area: builder — empty by diff: `git diff 21e36053..e2371eca --stat` names no file under src/builder/.

Area: collection and planning — every hunk of 82a227bd in src/codegen/trimcollect.jl, interpreter.jl, ir.jl,
compile.jl, closures.jl, src/frontend/nir.jl, dev/formal/ClosedWorld.tla and MCClosedWorldGarbage.cfg. The compile's one
interpreter is made by trim_compile_plan (trimcollect.jl:1821) and held by the ClosedWorld and the plan; every consult
takes it positionally (wt_method_matches(interp, …), wt_method_which(interp, …), ambiguous_class_tuple(interp, …),
wt_methods_ambiguous(plan.interp, …)), so no consult can run without it. That is what dart does: one
ClosedWorldClassHierarchy for the compilation (translator.dart:108 Translator.hierarchy). The model changed first:
MCClosedWorldGarbage checks ReasonsComplete, TLC rejected it, then passed. is_host_stream asks Base.binding_module, so
`println(stdout, 1)` in the test's own module rejects naming the stream. (A29C1, medium, C3 C6) The class A20N3 belongs
to is wider than three names. resolve_operand takes any bound non-constant global at the compiling session's value.
juliac snapshots globals but re-runs each module's `__init__` at load, and Base.__init__ re-initializes more than the
three streams (reinit_stdio, the depot and load paths, the active project, the environment-derived state).
is_host_stream enumerates `:stdout`, `:stderr` and `:stdin` (nir.jl:450). (A29C4, medium, C1, the nuke rule) The second
path stays. get_wasm_interpreter() and its shared :wasm_target partition remain the keyword default of get_typed_ir and
infer_return_type (ir.jl:25, :41, :58), so a collection call that omits `interp` infers in the shared partition and
compiles. Only L120's count of other `WasmInterpreter(` constructions and `get_wasm_interpreter()` calls holds it.
infer_return_type has no caller outside the compile's _rettype_question; its `interp` can be required, with the
inspection default kept only on the exported get_typed_ir. (A29C3, low) The dead widened original stays collected (H9,
open, its row updated).
stopgap in disguise: one interpreter per compile is a construction for the consult (no consult method without
`interp`). Its second path is a keyword default held by a count: a stopgap (A29C4). "A compile reads no stream" is one
predicate at the one boundary that resolves a global (L175), a funnel; its stream set is an enumerated list, a stopgap
for A29C1's class. A19X5's inner constructor is a construction: the four-argument default that took caller-sorted
lists no longer exists. A19X4's pin and ReasonsComplete are behavior and a model, and claim nothing more.
precedent: one interpreter: dart2wasm's one hierarchy (translator.dart:108), and juliac's one interpreter per world
(typeinfer.jl typeinf_ext_toplevel). Host streams: dart2wasm has no console global and prints through an import
(printToConsole); a non-constant static field is initialized by its own initializer in the module (globals.dart:19,
:189 staticFieldInitializer), never the compiler's value. juliac re-creates the streams in Base.__init__ (reinit_stdio).
WT differs because it runs no `__init__`, so a session-initialized global must be named; the construction is to derive
the set from the `__init__` bodies the closed world holds, not from a list. One constructor: Rust's private fields with
one `new`; dart's single generative constructor.

Area: emission and diagnostics — 82a227bd's hunks in statements.jl and values.jl. An unbound global rejects through
unbound_global_text at its statement: loud and located, one text for the three sites. Nothing else in the range touches
src/codegen/ outside collection. (A29C2, low, C9) Every measurement 82a227bd's message cites ran on another tree
(2a1bffe8, e3ddab45, ff8c1f71, 76d37b15, working trees of 7fec4fda), each named, none the landed commit: A20P16's
class. Its landing gate is the only evidence on the landed tree.

Area: enforcement and prose — every hunk of b104dfbb (dev/CHARTER.md, test/parity_ratchet.jl, dev/MARCH.md,
dev/parity_baseline.toml), 82a227bd's tests and prose (test/ir_one_inference_path.jl, test/diagnostic_attribution.jl,
test/generated_names.jl, test/host_imports.jl, the C10 citation of L196, the 13.17 and H9 rows), e2371eca (dev/land.sh,
dev/block.jl, test/parity_ratchet.jl, the excuse), and dev/.loop/landings.log with the main tree's landings.tsv.
(A29S1, high, red flag) C7's six :construction entries are not all constructions by b104dfbb's own sentence, "a lock
that reads src to find the wrong choice is :stopgap, whatever definition holds the rule". L6 is a count_sites scan for
a strict field, an environment switch or a setter: the wrong choice can be written and compiled, and the scan finds
it. L29 holds a list of forbidden names found by text. L165's union excludes UInt8 by type, a real construction, but
its other checks are a per-file allowlist of `::StorageType` counts and scans for the raw bytes 0x77, 0x78 and 0x40.
L172 and L151 mix a pin of the mechanism with scans that find its misuse. L168 pins `_require_local!` in the emitters
and is the closest to a construction. L201 resolves each entry by a regex over src that a definition of the named name
exists (strict_construction_defined), which holds whatever the lock's body does: a hand label carrying a name. The
construction that retires it: a :construction lock asserts facts about its definition only by reflection or a
load-time check (its fields, signature or method table), and L201 refuses one whose body reads src text. C7 cannot
close today (14 stopgaps), so nothing closed on it. (A29S2, low, red flag) C0 stays CLOSED on six checks (L125 L126
L128 L148 L154 L201) that each scan the charter's, AGENTS.md's, AUDIT.md's or MARCH's text. The standard names C1 to C8
and gives no reason C0 sits outside it; C0 has no closure matrix (A23E5). (A29S3, medium) The precedent rule (Dale,
20:45Z: a construction names its definition and its precedent, `precedent(rust|dart|ocaml|wasm: …)`, and the Julia
reason it differs) has no programmatic check: STRICT_KINDS's six entries carry no precedent and L201 asks for none.
The ledger lane's L204-L206 are its home. (A29E1, medium) The staleness budget turns every large src landing into a
map landing. 82a227bd moved 55 src pieces, so the next src landing went red on the budget, not on its own change, and
the map's re-record had to land between them: A24E2's shape, shortened by the incremental re-record, not ended. The
construction is `land` re-recording the moved pieces in the landing's own tree. (A29E2, medium, intent band) Two locks
read their literals outside their intent. L197 refused 82a227bd twice for b104dfbb's 3218 s, which lacked its excuse
until 82a227bd carried it, a cause the permission classifier made: a lock firing on a landing for another's time
(A25E1's class). The 60-s gate wall bound nothing on 82a227bd's own landing: 244.3 s of gate wall, every stage over
its budget (ratchet 56.1, smoke-core 70.2, tests 110.9, tlc 174.8, total 238.6 s), landed green as "unjudged, past
cap" at factor 1.96 (A21N1, A23E1: C10's "budgets still judged" is untrue of run_verdict). block.jl's header (lines
65-69) still says the budgets hold at any factor. Neither lock states its band. (A29E3, low) Prose names the wrong PR
and the old plan. e2371eca's message names the rebuild PR #123; it is #128. land.sh, the four workflows, AGENTS.md and
C10 still name PR #122's merge head as the final gate, and MARCH's Phase 14 plans WT1's in-place conversion, which the
rebuild replaced (WT2-DESIGN §E: MARCH restarts at the rebuild's Phase 1). e2371eca says "No other change" and also
adds 82a227bd's excuse and landing line. C10's text is Dale's to direct. (A29E4, low) Requirements and checks:
b104dfbb's standard has its check (L201, A29S1 aside); e2371eca's branch rename is held by L197 reading wt2; 82a227bd's
one interpreter is held by L120's count and a behavior test, with no construction (A29C4).

Landing times: b104dfbb 3218 s (the agent permission classifier denied its `land` for about 50 minutes; excuse file),
82a227bd 9166 s (committed 18:25Z, rebased four times and refused twice by L197; excuse file), e2371eca 214 s,
judged, its gate 36.4 s.

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A29S1 is accepted by the
orchestrator and is the strict lane's fix in flight (a :construction asserts only by reflection or a load-time check;
L201 refuses one whose body reads src text; the six reclassified); it and A29S3 are open on MARCH 13.20. A29S2 is
Dale's decision, on 14.5. A29C1-A29C4 are open on 13.17. A29E1-A29E4 are open on 13.18.

## 2026-10-21 — audited through 4f63d628 (e2371eca..4f63d628: entry 29, a stale plant, measured excuses, the plan restarted, one push per landing)

The thirtieth audit covers 3911e790 (entry 29; its author's), 9d6cdedd (the L195 [best_from] plant names its line by
the best's key), 24690061 (`land` writes the previous landing's measurable excuse from its steps; a hand excuse is
checked against them, A25E1, A25E2; cherry-picked from 5fd0a637), cd8defc9 (dev/MARCH.md restarts as the rebuild's
Phase 1; Phase 14 archived in this file's preamble) and 4f63d628 (a landing pushes wt2 alone; the four workflows
trigger on gate/** and wt2, a wt2 run its head's own concurrency group; PR #128 named outside the charter, A29E3). The
precedent locks (360cb793) and the skeleton's 1.A1 (945eef47) went red at their gates and are not in the range. No
wrong answer. Each landed head's record is green. A25E1 and A25E2 are fixed as 24690061 states; A29E3 is fixed outside
dev/CHARTER.md, whose preamble and C10 still name PR #122 (Dale's), and has its row 1.L. No red flag: no commit in the
range claims strictness or closure. Six findings: A30E1-A30E6.

Area: builder — empty by diff: `git diff e2371eca..4f63d628 --stat` names no file under src/ or ext/.

Area: collection and planning — empty by diff, as above.

Area: emission and diagnostics — empty by diff, as above.

Area: enforcement and prose — every hunk of 24690061 (dev/land.sh, dev/loop_excuse.sh, test/parity_ratchet.jl,
test/lock_negatives.jl, the two corrected excuses), 9d6cdedd (test/lock_negatives.jl), cd8defc9 (dev/MARCH.md, this
file's preamble), 4f63d628 (dev/land.sh, the four workflows, AGENTS.md, dev/gate.sh, dev/block_runner.jl,
dev/emission_diff.sh, test/block_groups.tsv's header, test/parity_ratchet.jl, test/lock_negatives.jl), the landing log,
steps.tsv and the red records of 360cb793 and 945eef47. 4f63d628's closure read is right: `merge` keeps a wt2 run only
when its head carries `Closes: C<n>` (land.sh:241-246), so the skipped runs of plain landings never stand in for the
matrix. (A30E1, medium, intent band) 24690061 takes out of L197's window every landing over 300 s whose overrun the
hold, a runner start, a gate run again or a gate past its 60-s budget explains, a cold gate included, whose time on a
src change is compiling that change. L197's median then measures the landings that met no blocker, so the 300-s intent
no longer bounds what a landing takes on this machine (A21E3's class). 24690061 itself took 2777 s from its author
time, kept from 5fd0a637 of a cancelled stack, with 57 s of steps; the writer measures none of the wait, and no excuse
names it. No precedent is named for the writer, a dev-side mechanism outside src. (A30E2, low) 9d6cdedd fixes one stale
plant, not its cause. The gate runs test/lock_negatives.jl only when that file changes, so a plant whose target another
file changes (here dev/timing_best.toml, re-recorded by 21e36053) goes stale until someone touches the negatives. The
construction is each plant naming its target files and the gate selecting the negatives when one changes. (A30E3,
medium) cd8defc9 dropped findings from the ledger. A29S2 sat on 14.5 as item 7 and is now on no row. 14.5's six
decisions Dale holds are archived as "carried to the charter proposals", which no file holds. A finding about C0 has
no row L154 admits, since C0 has no Planned text. 13.18 keeps A25E1 and A25E2 as "fixed" notes, finished work in the
plan (L129's class). (A30E4, low) Phase 1's preamble says "the stopgap count measuring WT2 is 0 at every landing",
true only while WT2 has no code; the head's ratchet measures 73. (A30E5, medium, intent band) The staleness budget
refused 360cb793, whose src hunks are four comment and docstring lines, on 55 pieces 82a227bd moved (record
ab57e81e-1: its one failed check "test/block_groups.tsv is stale"). The map selects the cases a changed body runs, and
a comment changes no body: a lock firing outside its intent, A29E1's class, and it held the A29S1 fix out of the range.
(A30E6, low) Requirements and checks: 24690061's measured excuses are held by L197 running loop_excuse.sh check;
cd8defc9's open plan by L129 and L154; 4f63d628's one push by L153 (one `git push`, no refs/heads/march/), with a
lock-negative plant; none of the five has a construction, and none is claimed.

Landing times: 3911e790 142 s, 9d6cdedd 185 s, 24690061 2777 s (unexcused, A30E1), cd8defc9 149 s, all judged;
4f63d628 599 s, unjudged (cold), its excuse the next landing's to write.

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A30E1-A30E6 are open on MARCH 13.18.
A29S2 returns to 13.20, where C0's findings sit until a row may carry them (A30E3).

## 2026-10-21 — audited through 9eb30016 (4f63d628..9eb30016: entry 30, one smoke corpus, the audit window read before the hold, the change's own stale pieces)

The thirty-first audit covers 3c2e735c (entry 30; its author's), 0d2ab5b5 (the smoke cases moved, unchanged and in
order, into test/smoke_corpus.jl; touched lines read with git's rename and copy detection; 1.A1's first half),
6e061943 (`land` reads L148's window before its hold through dev/audit_window.sh, the ratchet's own program, and
refuses a full one) and 9eb30016 (the staleness budget counts the change's own pieces among the moved ones; a file
whose code a change leaves alone moves none, by Julia's own parse, A30E5). No wrong answer. Each landed head's record
is green. A30E5 is fixed as 9eb30016 states. The corpus moved verbatim: the removed lines of test/smoke.jl and the added
lines of test/smoke_corpus.jl differ by one three-line header comment and two blank lines. No red flag: no commit
claims strictness or closure. Four findings: A31E1-A31E4.

Area: builder — empty by diff: `git diff 4f63d628..9eb30016 --stat` names no file under src/ or ext/.

Area: collection and planning — empty by diff, as above.

Area: emission and diagnostics — empty by diff, as above.

Area: enforcement and prose — every hunk of 0d2ab5b5 (dev/block.jl, test/parity_ratchet.jl, test/registry_cases.jl,
test/smoke.jl, test/smoke_corpus.jl), 6e061943 (dev/audit_window.sh, dev/land.sh, test/parity_ratchet.jl,
test/lock_negatives.jl) and 9eb30016 (dev/block.jl, test/parity_ratchet.jl, test/lock_negatives.jl), and the red
records of 945eef47 and 360cb793. (A31E1, high, intent band) 6e061943's preflight refuses the commit L148 exists to
admit. It reads origin's last entry and adds the landing's own commits, so once five commits sit past the last
audited-through commit, the audit entry that would empty the window counts as the sixth and is refused before its hold,
and no later landing passes either: a deadlock that only a hand landing ends. Measured on origin/wt2 at 9eb30016:
`bash dev/audit_window.sh . origin/wt2 1` reads "4f63d628 5 5 30"; with a fifth commit landed it would read 6, exit 1,
for this entry. L148 itself reads the landing's own tree, where the new entry resets the count. The construction is the
preflight reading the landing's own dev/AUDIT.md, the tree L148 judges. (A31E2, medium) 9eb30016 judges a map's
staleness by the change's own pieces, but a map row is a fact of the whole tree: which cases run a piece changes when
other code moves (a new caller, a collection rule, a dispatch reached), as 82a227bd's 55 pieces did. A change to a piece
no landing moved now passes on a row measured before those landings, and a case that newly reaches it may go unselected.
The 8-piece budget now bounds what the change alters, not what the selection may misread; the full matrix runs only at
closure (A28E3's and A24S1's class: the selection's universe stays a gate-time staleness count). (A31E3, low) 1.A1 lands
its corpus and not its driver: test/smoke.jl still calls WasmTarget.compile at its two sites, where 1.A1's row asks one
driver parametrised by the compiler module; its exit, smoke counts and probe hashes identical to the base, is evidenced
by 21 cases of two groups and the gate's core. The row stays open, as it should. (A31E4, low) Requirements and checks:
6e061943's window has one program run by L148 and land, L148 also requiring its entry to equal L148's own chain
reading, two readers of the last entry reconciled by a check; 9eb30016's decisions are pinned by L194 on fixed texts
with a negative plant; 0d2ab5b5's one corpus has no check that cases live only in the corpus. None claims a
construction.

Landing times: 3c2e735c 135 s, judged; 0d2ab5b5, 6e061943 and 9eb30016 as the landing log records.

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A31E1-A31E4 are open on MARCH 13.18.
A31E1 is the loop lane's next fix: until it lands, every audit entry must land as the fifth commit at the latest.

## 2026-10-21 — audited through 20f41493 (9eb30016..20f41493: the precedent locks, entry 31, the requirements ledger, WT1's checks retired; and the preflight's own-tree count)

The thirty-second audit covers c77c0ba4 (precedent is a gate rule: a construction's lock is ConstructionLock, calling
the check src registers beside its definition; L202 asks a precedent of each @enum, `@closed` sum and named
construction; L203; C0 inside the standard; `Charter-change: C0 authorised by Dale 2026-10-21`; carried from
59695ef5), ded191a0 (entry 31; its author's), bb2c2fee (dev/LEDGER.md, Dale's requirements as 39 rows tied to their
checks; L204 to L207 and R45; every budget a target with a band, BUDGET_BAND 2 and L197_BAND 600; AGENTS.md's ledger
block; `Charter-change: C0 C10 authorised by Dale 2026-10-21`) and 20f41493 (1.A2a: the 202 locks and ratchets that
measured WT1's source leave the ratchet, each clause listing them on a plain Legacy line; Planned text cites Phase 1's
rows; Phase 13 archived; R45 14; `Charter-change: C0 C1 C2 C3 C4 C5 C6 C7 C8 C9 C10 authorised by Dale 2026-10-21`).
This commit also fixes A31E1 (below). loop4's (6) went red and is not in the range. No wrong answer. Each landed head's
record is green but ded191a0's judgement (SLOWER load ratchet, A32E2). Fixed as their commits state: A29S2 (C0 reads
OPEN), A30E2 (L207: a lock's negative runs in every gate) and the three red flags the audit lane raised on 360cb793
before it landed. Verified in this lane's Kaimon session (e1d51284) on bb2c2fee's tree: the status block reads C0 OPEN
on L125 L126 L128 L148 L154 L201 to L207 and R45 = 208, every lock C4 to C8 cite a stopgap or behavior, no clause
closed. One ruling recorded; six findings: A32S1, A32S2 and A32E1-A32E4.

Area: builder — c77c0ba4's three docstring lines in src/builder/types.jl, `precedent(...)` on NumType, RefType and
PackedType, no code. The open hierarchies (WasmInstr, AbstractCompilationContext, NirNode) carry parity alone, as
L202's planted "open abstract type, asked nothing" case requires.

Area: collection and planning — empty by diff: no file under src/ outside src/builder/ changes in the range.

Area: emission and diagnostics — empty by diff, as above.

stopgap in disguise: c77c0ba4 deletes the deny-list reader (STRICT_SRC_READERS, strict_lock_source, the regex name
resolution) and holds a construction's lock to one type, ConstructionLock, checked by reflection: that part is a
construction of the lock table. (A32S1, low) The construction's own assertion, construction_check(::Val{definition}),
runs when the ratchet calls it at gate time, and nothing yet requires its body to be reflection or a load-time fact
rather than a scan; the src macro that would hold that, @construction_check, lands with the first construction (1.S,
1.A3, 1.A8). No construction exists, so nothing rests on it today. L201 to L207 are classified stopgaps; none is
claimed otherwise. (A32S2, medium, red flag in waiting) After 20f41493 every clause C1 to C8 cites no check, only Planned
text, and the status block reads a clause CLOSED when no cited check is open and it has no Planned text
(parity_ratchet.jl's verdict loop): a clause whose Planned text is dropped reads CLOSED on nothing, vacuously, and L201
allows it (its "cites only constructions" holds of an empty list). 20f41493's message says none is vacuously CLOSED; that
holds today and nothing keeps it. The construction is the verdict requiring at least one cited construction.
precedent: NumType and PackedType, dart's enums (type.dart:82 NumTypeKind, :1367 PackedTypeKind), Rust's closed enum;
RefType, wasm's fixed abstract heap types. ConstructionLock: Rust's `const _: () = assert!(..)` beside its item and
dart's exhaustive switch over a sealed class where it is declared (functions.dart:836); Julia has no compile time but
load, so the check must run at load to be their equal (A32S1). The ledger: Rust's RFCs and tracking issues.

Area: enforcement and prose — every hunk of c77c0ba4 (dev/CHARTER.md, test/parity_ratchet.jl, dev/MARCH.md), bb2c2fee
(AGENTS.md, dev/CHARTER.md, dev/LEDGER.md, dev/MARCH.md, dev/block.jl, dev/parity_baseline.toml, dev/timing_best.toml,
test/parity_ratchet.jl), 20f41493 (AGENTS.md, dev/AUDIT.md's preamble, dev/CHARTER.md, dev/LEDGER.md, dev/MARCH.md,
dev/parity_baseline.toml, test/parity_ratchet.jl), the landing log, steps.tsv and the gate records. Ruling recorded:
the bands are Dale's words read as lock mechanics, the gate's twice its budget (red past 120 s) and the loop's 600 s,
chosen by the orchestrator from "like blocking a run for being 61s when I said under a minute goal" and "idc at all if
a thing takes 3 mins or 40s — as long as it's wicked fast and not tens of mins to hours" (Dale, 2026-10-21), authorised
with bb2c2fee's Charter-change. (A32E1, low) bb2c2fee's message carries a second, indented Co-Authored-By trailer.
(A32E2, medium) The ratchet's best no longer measures the ratchet. c77c0ba4 and bb2c2fee grew the stage past its
20.45-s best (22.61 s scaled on c77c0ba4's judged run, record f55ec47e-2; 23.7 s at factor 1.0 on ded191a0's, record
a7d986ba-2, SLOWER by 0.2 s on a prose change), and 20f41493 cut 4,531 lines of locks, so the best now bounds a stage a
fraction of its size. ded191a0's debt could carry no excuse (the writer writes none for a red timing, the check
refuses a measurable hand line); loop4's (6), not landed, deletes the writer. (A32E3, medium) Findings sit on no row.
20f41493 archives Phase 13 with "each stays in its audit entry below", and L154 no longer checks that a finding sits on a
row, while C0's text still says L154 holds "every finding sits on a row". The process findings were never WT1's: the
gate's, the loop's and the audit window's (A28E1, A30E1, A31E2, A32E2) apply to the rebuild's tooling unchanged.
(A32E4, medium, nuke order) The checks retire before the code they guard. WT1 stays the root compiler until 1.A2c, but
202 of its locks are gone from the gate now, and nothing refuses an edit to WT1's src in the interval; the ledger's D9
(correct or loud), D10 (valid by construction) and D12 now cite planned rows only. The Legacy lines say WT1 is kept
"only as the agreement oracle" in legacy/, which is true only after 1.A2c. Kaimon and requirements: c77c0ba4 and
bb2c2fee measured by Python mirrors without Julia, before the Kaimon rule (22:40Z); 20f41493 cites a fresh
`julia --project=. test/parity_ratchet.jl` run where the warm session answers the same; from this entry each landing
is asked whether its lane developed in a live Kaimon session. bb2c2fee's L204 makes a requirement with no check red.
No lock fired inside its band in the range.

The preflight's own-tree count (A31E1), in this commit: dev/audit_window.sh takes the landing's head as an optional
fourth argument and reads that head's dev/AUDIT.md when it holds more entries than origin's, the tree L148 judges once
rebased; land.sh's preflight passes HEAD. L148's scratch case adds two outcomes in a full window: a landing adding the
next entry fits, one adding none is refused; test/lock_negatives.jl plants the own-tree read dropped. Measured in the
Kaimon session on this change's tree before its rebase: the ratchet exit 0, L148 locked (run-2); planted, exit 1, "L148
1 ❌ LOCK BROKEN" (run-3); restored from a copy, cmp-identical.

Landing times (edit to landed): c77c0ba4 3032 s, ded191a0 364 s (SLOWER), bb2c2fee 2347 s, 20f41493 as the landing log
records: 20f41493 446 s, judged, its gate 90.3 s and its ratchet stage 7.5 s. This entry's first tree, d2f0a99e (record d2f0a99e-1), was red on no check of its own: its runner's 20-minute idle stop fired (server.log, "idle 20 min, stopping") after `land` had found it alive and before the smoke stage reached it, so smoke-core, probes and tests read "no server" as failed checks, and the tree's red record stands for a machine fault (a finding for the next entry). On the rebased tree L197 read the median of c77c0ba4, ded191a0, bb2c2fee, 20f41493 and e1b70c75 at 921 s, past its 600-s band, refusing every landing; this commit carries dev/.loop/excuse/c77c0ba4, a hand line loop_excuse.sh check passes: carried from 59695ef5 of the lane the rebuild cancelled, its author time kept, refused once by the stale-map budget alone (record ab57e81e-1, A30E5), its own rework for audit 30's red flags named as its own. The median is then 446 s. Its second tree, fee8b6a4 (record fee8b6a4-1), was red on its own fault: the new lock-negative plant wrote `$otext` in an interpolating string (UndefVarError); a raw string now, lock_negatives.jl 33 of 33 in the Kaimon session.

Resolution: this entry and A31E1's fix land as one commit. A32S1, A32S2 and A32E3 are open on MARCH 1.S; A32E1 and A32E2
on 1.L, with the live process findings A28E1, A30E1 and A31E2; A32E4 on 1.A2c.

## 2026-10-21 — audited through c1c74a43 (20f41493..c1c74a43: WT1's test tree retired, entry 32, L197 on a landing's own time, the timing band, c1c74a43)

The thirty-third audit covers e1b70c75 (1.A2b: WT1's test infrastructure leaves, 124 files and 32,927 lines: 53 QA
families, the fuzz pass, registry coverage, the sidecar and the emission-diff check; the lanes are ratchet, formal,
smoke on 1.12 and 1.13, probes and the suite), 33ca8afa (entry 32 and land's own-tree preflight count, A31E1; its
author's), f9e3d277 (L197 judges a landing's own_s, from its change's first red gate run to its push less its hold
wait, queue_wait_s the rest; the excuse writer deleted; the audit window read again on the rebased head, A30E1),
f9d5e820 (the timing ratchet's band: SLOWER only past 1.5 times a best and 0.3 s, a note past 15%; L128 caps
AGENTS.md's hand-written lines at 60 beside L206's generated block; `Charter-change: C10 authorised by Dale
2026-10-21`) and c1c74a43 (a clause citing no check reads OPEN, the verdict in one function, clause_open_reasons, and L201 refusing a scoped clause with no Planned text that cites nothing, A32S2; L154 reads the latest entry's Resolution and holds every finding it leaves open `on <row>` on that row until a `Fixes:` line names it, A32E3; R45 13; `Charter-change: C0 authorised by Dale 2026-10-21`). No wrong answer. Each landed head's record is green. A31E1 is fixed (33ca8afa;
e1b70c75 landed as the fifth past 9eb30016 and entry 32 as the sixth, the case the fix admits). A30E1 is fixed in
intent by f9e3d277 (no excuse leaves L197's window; the writer and its stuck-debt class, A32E2's second half, are
gone), with A33E3 on how own_s counts. A32E2's flapping ratchet is ruled by f9d5e820's band. No red flag: no commit
claims strictness or closure. Two rulings recorded; findings A33E1-A33E8 and A33S1. A32S2 and A32E3 are fixed as c1c74a43 states.

Area: builder — empty by diff: `git diff 20f41493..c1c74a43 --stat` names no file under src/ or ext/.

Area: collection and planning — empty by diff, as above.

Area: emission and diagnostics — empty by diff, as above.

Area: enforcement and prose — every hunk of e1b70c75 (the workflows, .gitignore, AGENTS.md, dev/MARCH.md,
dev/PARITY_MASTER.md, dev/block.jl, dev/emission_diff.sh, dev/formal/README.md, dev/gate.sh, dev/lanes.sh,
test/block_groups.tsv, test/runtests.jl and the deleted files), f9e3d277 (dev/land.sh, dev/loop_excuse.sh,
test/lock_negatives.jl, test/parity_ratchet.jl), f9d5e820 (dev/CHARTER.md, dev/LEDGER.md, dev/block.jl,
dev/timing_best.toml, test/parity_ratchet.jl), c1c74a43, the landing log and the gate records in every worktree.
(A33E1, medium, a weakened check) e1b70c75 carries a dev/block.jl line its message never names, added by an amend
with --no-edit after its red first run (record 8cf9cd7d-1): `startswith(f, "test/") && !ispath(joinpath(ROOT, f)) &&
continue`, so a test file the change deletes selects nothing, where before it had no block_groups row and the gate
refused it. What still catches a deletion: test/smoke_corpus.jl and test/probe_corpus.jl, which locks read
(_smoke_text, parity_ratchet.jl:93; the probe corpus, :1160), fail the ratchet loudly when gone. What does not:
test/lock_negatives.jl deleted with its include (runtests.jl:54) takes its 33 plants silently, since L207 counts only a
negative inside parity_ratchet.jl ("a negative in test/lock_negatives.jl ... counts for nothing", :706) and R45 counts
only NEGATIVE_OWED; and no lock counts the corpus's cases, so a case removed from it, or a test file deleted with its
include, passes the gate. The fix: the gate treats a deleted test file or a removed smoke case as a change that names
its reason (its ledger or plan row), and L207 owes each NEGATIVE_OWED lock's plant until it lives in the ratchet.
(A33E2, low) A commit's message describes every change it makes; e1b70c75's amend hid one. (A33E3, medium) The
runner's 20-minute idle stop races `land`: on 33ca8afa's first tree (record d2f0a99e-1) land found the runner alive,
the runner stopped ("idle 20 min, stopping", its server.log) before the smoke stage reached it, and "no server" read
as three failed checks, so the tree's red record stands for a machine fault; the gate's own rule calls a runner that
did not state its state no verdict, yet the stage's exit 2 counted as a failed check. The construction: the runner
refuses to stop while a hold names its worktree, and a stage that reached no server is no verdict, never red (loop4's
(7)). (A33E4, medium, intent band) own_s measures the lead's ordering and other landings' faults, not a landing's own
mechanics. f9e3d277's own_s, 2364 s, runs from its first red run (record fa27dc40-1, 22:40Z, red on L198's needle and
on L148, the window c77c0ba4 filled during its hold) through a second red of its own (294d669e-1, 22:52Z) and then about
25 minutes waiting for its slot behind entry 32, 1.A2a and 1.A2b, which the lead ordered ahead; only its hold wait is
subtracted (land.sh: the earliest red record of the same author time, author and subject, whatever failed it).
f9d5e820's own_s, 1664 s, starts at a red on the probes stage's timing alone (096293338-1, 22:53Z, 24.5 s against its
9.9-s best, a stage its change does not touch) and passes a red on L197 alone (515aaae6-1, 23:12Z, the window's median
past its band on other landings' times): neither red was its change's. The construction: own time is the sum of the
change's own gate runs and the spans after a red whose failed checks are its own, the slot waits after them queue
time, and a red on L148, L197 or a timing alone the queue's. (A33E5, low) own_s finds a change's reds by author time,
author and subject over every worktree's git-ignored records: a lane's records leave with its worktree (dev/lane.sh
stop removes it) and a reworded subject unlinks them, so own_s also undercounts. (A33E6, low) f9d5e820 changes what
L128 measures: AGENTS.md was at most 90 lines in all, and is now at most 60 hand-written lines beside L206's generated
block, which grows one line per live requirement, so the file has no bound; the band's words in D25 changed with it,
under a C10 authorisation. Rulings recorded: the timing ratchet's 1.5-times band (f9d5e820, authorised) and the
excuse for c77c0ba4, which stands for 33ca8afa's landing alone (the lead). Kaimon: f9d5e820 measured its ratchet in a
warm Kaimon session; e1b70c75 cites fresh runs (`test/parity_ratchet.jl`, smoke numerics, lock negatives 31 of 31) after
the Kaimon rule (22:40Z) where the warm session answers the same; f9e3d277 ran no Julia (bash mirrors), committed
before it. Requirements: e1b70c75 retires D9's, D10's and D12's last live behavior checks with WT1's families while
WT1 ships (A32E4's class); f9e3d277's own time is held by L197 on fixed texts; no lock fired inside its band.

stopgap in disguise: (A33S1, medium, red flag class) L202 cannot see an open type called a closed sum. It recognises
a closed sum only by its spelling, an @enum or a `@closed` macro, so `abstract type Rejection end` with five subtypes
and a docstring calling it "A closed sum" (1.A2c's first draft, 2658e1db, not landed, sent back by the lead to become a
concrete Union with construction_check(Val(:Rejection))) would have passed: the word "closed" on a type any module may
subtype, the class A30S1 named. The check is reflection, not a text scan: when the package loads, walk
`names(WasmTarget; all = true)` and each submodule's for every abstract type (`isabstracttype`), and refuse the load
unless it is a registered construction (a `construction_check(::Val{name})` method exists, `hasmethod`) or a mirror of a
dart abstract class whose binding's docstring (Base.Docs, read by reflection) carries its `parity(<file>.dart:<line>
<Symbol>)` anchor; a closed sum is then a Union or an @enum by its type, never by its comment.
precedent: dart's `sealed class` against its open `abstract class` (the analyzer knows the subtypes of the first only);
Rust's enum against a trait; Julia's abstract types are open by language, so a closed sum must be a Union of concrete
types or an @enum, and the load-time walk is how WT refuses the open spelling.

c1c74a43, item (d): the verdict. Verified on c1c74a43's tree: clause_open_reasons (parity_ratchet.jl:263) reads a
clause citing no check OPEN, "no check" (:267), and run() prints it; strict_violations refuses a scoped clause with no
Planned text and no check, "CLOSED on nothing" (:288); the negatives plant the dropped Planned text, a passing lock, a
broken lock and a ratchet (:378-386). Judged: the verdict is a gate-time rule over the charter's parsed text, a
stopgap of C0's own kind, classified so, and claims no construction; its precedent, a match on an empty enum proving
nothing, is apt. (A33E7, low) The empty-clause rule is written twice, in clause_open_reasons and in strict_violations:
one fact, two sources. The construction would be the parsed clause's own type refusing an empty check list when the
charter is read, so the verdict and L201 read one fact. (A33E8, low) L154's Resolution reader (open_findings, :516)
takes each finding ID it sees, so a range written "A30E1-A30E6" holds only its two ends to their row; entries have
written ranges since entry 25. This entry names each ID.

Landing times (edit to landed; own, queue): e1b70c75 920 s; 33ca8afa 1065 s (two reds: d2f0a99e-1 the runner, A33E3;
fee8b6a4-1 its own plant); f9e3d277 2447 s (2364, 83); f9d5e820 1864 s (1664, 200); c1c74a43 656 s (60.1, 595.9), unjudged past the cap at factor 2.11.

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A33E1, A33E2, A33E3, A33E4, A33E5, A33E6, A33E7
and A33E8 are open on MARCH 1.L; A33S1 on 1.A2c, whose commit lands its check.

## 2026-10-22 — audited through 30654e4b (c1c74a43..30654e4b: entry 33, Kaimon per lane, own_s from a red history, the switch to the rebuild, AGENTS.md bounded)

The thirty-fourth audit covers 7b8a0c82 (entry 33; its author's), b3e0b602 (every lane in a live Kaimon session:
dev/lane.sh makes the lane, `land` refuses a worktree with no live session, dev/kaimon_session.sh, D39), 3b3a0a0c (own_s
counts only a change's own reds, read from the main tree's dev/.loop/reds.tsv, red_kind calling a red on timing, L148
or L197 alone `queue`, A33E4, A33E5), 86105198 (1.A2c, the switch, landed by the lead: WT1 to legacy/ as
WasmTargetLegacy; root src/ the rebuild, the Rejection closed sum and a compile entry rejecting Unported; L218
check_closed_sum and L219 check_no_open_abstract, refused at load; ConstructionLock running the construction's plants;
the Removes-test rule, A33E1; the legacy freeze; the smoke ladder derived from each compile; `Charter-change: C5 C6
C10 authorised by Dale 2026-10-21`) and 30654e4b (L128 bounds AGENTS.md's whole, 60 lines plus one per live
requirement, A33E6). No wrong answer: the rebuild compiles nothing yet, and every corpus case rejects loud (81 of the
core, 995 of the corpus, 86105198's message). Each landed head's record is green. Fixed as their commits state: A32E4
(WT1 left the root, the freeze with it), A33E1 in its first form, A33S1 in its first form, A33E4, A33E5 and A33E6.
The lead wrote part of 86105198, so this entry audits it as any other change. Three red flags: A34S1, A34S2 and A34S4.
Findings A34S1-A34S4 and A34E1-A34E7.

Area: builder — empty by diff: the rebuild's src/ holds no builder yet; WT1's builder moved whole to legacy/src/builder
(a rename, 0 lines changed in instr_builder.jl, instructions.jl, source_map.jl, types.jl, validator.jl and writer.jl).

Area: collection and planning — empty by diff for the rebuild: WT1's collection moved whole to legacy/src.

Area: emission and diagnostics — 86105198's src/julia/reject.jl and src/julia/entry.jl. compile(f, argtypes) rejects
through reject!(Unported("compile.dart:216 compile"), at), its one path, typed `Union{}`: loud and located at the
entry. (a) Rejection is a construction for what it states. It is a `const` Union of five concrete structs that
subtype nothing, so no module adds a kind without editing that line, and RejectionError's field is typed Rejection.
check_closed_sum, run when the package precompiles and again by ConstructionLock in every gate, refuses a kind with no
`_reason`, a `_reason` method for any other type (a `_reason(::Any)` catch-all among them) and a kind under an abstract
type, as its plants show. (A34S3, low) Its exhaustiveness covers `_reason` alone. The next function that matches on a
Rejection kind is not checked until `@exhaustive` (1.A8) exists, so "exhaustive match" in its precedent holds for
`_reason` and for no later match.

stopgap in disguise: L219's check_no_open_abstract claims "no open hierarchy passes for a closed one" and lets two through,
both measured in this lane's Kaimon session (e1d51284) on 86105198's tree. (A34S1, medium, red flag) A parametric
abstract type passes: `abstract type Open{T} end` in a module reads 0, because its binding is a UnionAll
and the walk takes only `b isa DataType`. (A34S4, medium, red flag) An open abstract type passes on a mention: a docstring "an open type; it
only mentions parity(misc.dart:57 TreeNode)" reads 0, where the same type with no docstring is refused. The exemption
is a regex over docstring text (`occursin(r"parity\([\w/]+\.dart:\d+ \w+\)", _docstring_text(mod, n))`): the docs
are fetched by reflection, then read as text, so a comment exempts a type, the label A33S1 objected to. It also does
not tell an open dart class from a sealed one: a mirror of a sealed class passes as an open abstract type. Its plants
cover neither case. The construction: walk every abstract type through `Base.unwrap_unionall`, and exempt a mirror
only by a registered `dart_mirror(::Type{T})` method naming its anchor, which L213 resolves at the pin to an
`abstract class` declaration, never a sealed one. (A34S2, medium, red flag) The Removes-test rule does not see a lazy
group. corpus_case_keys reads a case as a `("name", …)` line under a `_g`/`_xf` group, so a `_lazy_g("<group>",
"<file>")` group's cases, generated from its file, have no keys. 86105198 removed ten of them from the corpus
(registry_foreign, _binops, _unops, _conversions, _checked, _shift, _fma, _misc, _operators and _sample),
with no Removes-test line for any, and its gate passed: the rule's guarantee, "a dropped case is never silent", is
claimed where it does not hold. The fix: a lazy group is a key of its own (`<corpus>:<group>/*`), and a removed one is named. (A34E7, low)
The move itself went undeclared: the ten groups went to legacy/test/smoke.jl, so nothing was lost, and the message's
prose says WT1's registry groups moved, but no Removes-test line names them, as the rule asks of every removal.
precedent: Rejection: Rust's enum with an exhaustive match, dart's sealed class with an exhaustive switch; Julia has
no closed declaration, so a Union of concrete types, checked at load. check_no_open_abstract: dart's sealed class
against its open abstract class, Rust's enum against a trait; Julia's abstract types are open by language. The
legacy freeze and the Removes-test rule are gate rules with no ecosystem precedent named; each is a stopgap of C10's
kind and claims no construction.

Area: enforcement and prose — every hunk of b3e0b602 (dev/kaimon_session.sh, dev/lane.sh, dev/land.sh, dev/LEDGER.md,
test/lock_negatives.jl, test/parity_ratchet.jl), 3b3a0a0c (dev/block.jl, dev/land.sh, test/lock_negatives.jl,
test/parity_ratchet.jl), 86105198 (the workflows, AGENTS.md, Project.toml, dev/CHARTER.md, dev/LEDGER.md,
dev/MARCH.md, dev/block.jl, dev/block_runner.jl, dev/land.sh, dev/lanes.sh, legacy/Project.toml,
legacy/src/WasmTargetLegacy.jl and the renamed files' changed lines, src/, test/), 30654e4b, the landing log and the
gate records. (c) ConstructionLock is sound: it calls the src check and then construction_negatives_missed, whose
`else` arm reports a construction with no plants as a fault, so a ConstructionLock naming an unplanted definition is
red; ratchet_source maps `function (c::ConstructionLock)()` to the name ConstructionLock so L207 reaches the plants
through the lock table's text, and the run, not the text, decides. (f) is sound: probes_touched slices
`corpus[1:min(h, length(corpus))]`, an empty slice at h = 0, and the baseline arm tests `1 <= h`, so a file emptied
whole selects nothing. (A34E1, medium, (d)) A Removes-test line naming `<corpus>:*`, or the corpus path itself, admits
the removal of any subset of its cases under one reason (`(corpus * ":*") in named || corpus in named`), whether the
corpus loses one case or all; the gate prints no count. The fix: `<corpus>:*` only when the corpus loses every case,
the count in the record. (A34E2, low, (e)) The legacy freeze has a two-landing bypass: land refuses a change to
legacy/ only while both the march tip and the head hold it, so one landing that deletes legacy/ whole and a next that
re-creates it edited both pass (the second is "the commit that creates it"). The fix: the creation exemption names its
commit (86105198) and every later re-creation is refused. (A34E3, low) own_s still charges a slot wait after an own
red: an own red counts from its start to the next attempt's start, and the next attempt starts when its slot comes, so
the lead's ordering after a fixed red is own time. A timing red on a stage the change itself slows is `queue`, so a
change's real cost to the gate counts nothing. 86105198's own_s, 45.9 s, leaves out its own red (record 0227b14e, the
BoundsError), which ran before reds.tsv existed. (A34E4, low) The map (test/block_groups.tsv) is now written by hand,
and its `measured` row names the switch's own src tree, which no measurement ran on, so the staleness budget reads a
hand map as measured; harmless while src holds four files of stubs, not after 1.B. (A34E5, low) 3b3a0a0c carries a
second, indented Co-Authored-By trailer, as bb2c2fee did (A32E1). (A34E6, low) Kaimon: 86105198 measured "each in a
fresh process", after the Kaimon rule, where the warm session answers the same; b3e0b602, 3b3a0a0c and 30654e4b name
bash mirrors or the Kaimon session. The Kaimon refusal itself holds: this entry's land runs with session e1d51284 live.
Requirements: D39 has its check (b3e0b602); D9's rejection is a construction (L218); the smoke ladder counts loud as
green, so the differential gate is vacuous until a path compiles (1.D), by design and stated. No lock fired inside its
band.

Landing times (edit to landed; own, queue): b3e0b602 2705 s (169.5, 2535.5); 3b3a0a0c 199 s (55.4, 143.6); 86105198
2495 s (45.9, 2449.1); 30654e4b 2331 s (24.7, 2306.3).

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A34S1, A34S3 and A34S4 are open on
MARCH 1.S. A34S2, A34E1, A34E2, A34E3, A34E4, A34E5, A34E6 and A34E7 are open on MARCH 1.L.

## 2026-10-22 — audited through acee85e0 (30654e4b..acee85e0: entry 34, audit 34's four holes closed, src progress, warm gates, the landing queue)

The thirty-fifth audit covers 3451859d (entry 34; its author's), 5582a4f1 (L219 unwraps a UnionAll; a lazy group is one
key, `<group>/*`; `<corpus>:*` only when the corpus empties; the legacy freeze holds once any commit of the tip's
history touched legacy/; Fixes: A34S1 A34S2 A34E1 A34E2; landed by the lead), 0d87ec4e (D40 and L208: the rebuild's src
progress printed after every landing, dev/src_progress.sh; `Charter-change: C0 authorised by Dale 2026-10-21`),
edf2327b (the runner stays up 120 idle minutes; a check counts warm only after a finished run; `land warm`; each
landing's gate_state; the warm bests re-recorded by two median-of-three updates, A32E2) and acee85e0 (one landing
queue, dev/land_queue.sh and the main tree's dev/.loop/QUEUE: the hold goes to the head or to anyone while it is empty,
`land wait` lands a lane at its turn, a head that takes no free hold within 300 s is skipped; dev/manifest_check.sh).
No wrong answer: the rebuild compiles nothing yet. Each landed head's record is green. A34S1, A34S2, A34E1 and A34E2
are fixed as 5582a4f1 states; A34S1's fix measured in this lane's Kaimon session (e1d51284) on acee85e0's tree:
`abstract type Open{T} end` in a module now refuses ("Main.Probe5.Open is an abstract type that is neither a
registered construction nor a dart abstract class's mirror"). A32E2 is fixed by edf2327b's re-recorded bests (its
message names the ID without a `Fixes:` line). A34S4 stays open, as 5582a4f1 says. One red flag: A35S1. Findings
A35S1 and A35E1-A35E5.

Area: builder — empty by diff: src/ holds no builder yet.

Area: collection and planning — empty by diff.

Area: emission and diagnostics — 5582a4f1's src/julia/construction.jl: check_no_open_abstract unwraps a UnionAll
binding before it asks whether the type is abstract, so every abstract type a module binds is walked; its plants gain
the parametric case.

stopgap in disguise: L219 is a construction for the parametric case now; its docstring exemption is still a regex
over text (A34S4, 1.A3). (A35S1, medium, red flag) 0d87ec4e's progress line counts text, and setup passes for
building on it, the thing D40 forbids. dev/src_progress.sh counts `grep -rho 'parity(' src`: on acee85e0's tree its
"5 parity( anchors under src/" are three `parity(quarantine: …)` comments (construction.jl:6, reject.jl:5,
entry.jl:3) and two mentions of the anchor's form in a docstring and an error string (construction.jl:67, :83). Not one
is a dart definition ported. The fix: the progress line counts dart anchors on definitions, `parity(<file>.dart:<line>
<Symbol>)`, apart from quarantines and with prose excluded, read from the @parity registry once 1.A3 lands; until then
it says "0 dart definitions ported".
precedent: check_no_open_abstract, dart's sealed class against its open abstract class and Rust's enum against a
trait, with Julia's parametric abstract types unwrapped as Julia binds them. The landing queue: bors and GitHub's merge
queue, one total order, as its message names; it differs in running on one machine's files with a stale-head skip
where bors has a CI timeout.

Area: enforcement and prose — every hunk of 5582a4f1 (dev/MARCH.md, dev/block.jl, dev/land.sh, test/lock_negatives.jl,
test/parity_ratchet.jl), 0d87ec4e (AGENTS.md, dev/CHARTER.md, dev/LEDGER.md, dev/land.sh, dev/src_progress.sh,
test/parity_ratchet.jl), edf2327b (dev/block_runner.jl, dev/land.sh, dev/timing_best.toml, test/lock_negatives.jl,
test/parity_ratchet.jl), acee85e0 (dev/LEDGER.md, dev/land.sh, dev/land_queue.sh, dev/lane.sh, dev/manifest_check.sh,
test/lock_negatives.jl, test/parity_ratchet.jl), the landing log and the gate records. The queue, audited for
wait-cycles and a dropped landing, as the lead asked. Sound: every read and write holds the queue's lock (a directory
holding its owner's pid, taken over from a dead one); the head's clock restarts whenever the head changes or the hold
is held, the orchestrator's owner-0 hold included, so a head waiting on a busy machine is never skipped; a lane is
queued once; `may` and the hold's check read one file. (A35E1, medium, a wait-cycle back) `land`'s preflight refusals
run before the queue's trap is set (land.sh, in `land`: the dirty tree, the Manifest, the Kaimon session and the audit
window refuse with `exit 1` before `trap release EXIT`), and `wait` `exec`s `land`, so a head refused in its preflight
is neither popped nor watched: it holds the head until the 300-s clock skips it. With the audit window full, every
non-audit head is refused there, and the audit entry that would empty the window queues behind them all, so it lands
only after each is skipped, about 300 s apiece: the wait-cycle the queue removes, returned as a stall. The fix: `wait`
runs `land` as a child and acts on its exit (pops on a refusal it cannot outwait, re-queues on the audit window), and
a commit that adds the next audit entry goes to the head, since every refused lane waits on it. (A35E2, low) A turn
that ends after the trap (a red gate, a rebase conflict, a charter refusal) pops the lane by design, and nothing
re-queues it, since its `wait` became `land`; the lane learns it only from that run's output. A refused landing's
re-queue is the lane's to make, and no line in dev/.loop/QUEUE.log records it. (A35E3, low) A33E3's race is narrowed,
not ended: edf2327b keeps the runner 120 idle minutes, so the idle stop now fires only after two idle hours, but a
stage that reaches no server still counts as a failed check rather than no verdict, the second half of A33E3's fix.
(A35E4, low) edf2327b carries a second, indented Co-Authored-By trailer, the third such (A32E1, A34E5). (A35E5, low)
Kaimon: 5582a4f1 measured "in a fresh process" after the Kaimon rule; 0d87ec4e and edf2327b measured in their lanes'
Kaimon sessions; acee85e0 replayed in bash. Requirements: D13 names the queue among its checks; D40 has its check
(L208), whose count is A35S1's; no lock fired inside its band.

Landing times (edit to landed; own, queue): 5582a4f1 195 s (37.7, 157.3); 0d87ec4e 2428 s (22.5, 2405.5); edf2327b
4685 s (35.6, 4649.4); acee85e0 2563 s (33.3, 2529.7).

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A35S1 is open on MARCH 1.S. A35E1,
A35E2, A35E3, A35E4 and A35E5 are open on MARCH 1.L.

## 2026-10-22 — audited through 32b7e806 (acee85e0..32b7e806: entry 35, own_s without waits, one empty-clause rule, the file map and the quarantine, the strict subset)

The thirty-sixth audit covers d23e14b5 (entry 35; its author's), 371373c2 (own_s leaves out a change's waits inside
an own red's span, from the main tree's waits.tsv; queue_wait_s floored at 0, A34E3), 0806bf56 (the empty-clause rule
written once, in the clause verdict; Fixes: A33E7), 10064fa7 (1.A3: src/julia/parity.jl; include_dart from the pin
table DART_FILES; @parity, @unported and @quarantine, each checked where it is written and total at load by a walk of
the method table and the bindings, L210-L212; L219 exempts a mirror only by its @parity entry; src progress from the
registry; Fixes: A34S4 A35S1; `Charter-change: C2 authorised by Dale 2026-10-21`) and 32b7e806 (1.A7: src/julia/subset.jl,
Julia's trim verifier decides the strict subset, a program outside it rejecting with Julia's own text; ClosedWorld a
typestate with one constructor taking a token, L220; `Charter-change: C2 C3 C6 authorised by Dale 2026-10-22`). No
wrong answer: the rebuild compiles nothing; the corpus reads 996 loud, 820 unported and 176 outside the subset
(32b7e806's message). Each landed head's record is green. Fixed as their commits state: A33E7, A34E3, A34S4 and A35S1
(the progress line now reads "0 of 0 anchored dart definitions ported", run on this tree). The builder's first group
(wt2-builder, 681bdd62 and 56a3b629) is not in the range: it is based on c1c74a43, before 1.A2c and 1.A3, and must
rebase onto them. One red flag: A36S3. Findings A36S1-A36S3 and A36E1.

Area: builder — empty by diff: src/wasm_builder/ does not exist on 32b7e806.

Area: collection and planning — 32b7e806's src/julia/subset.jl. check_subset infers once, as trimming does: Base._which
for the entry's method, Core.Compiler.specialize_method, then typeinf_ext_toplevel in TRIM_UNSAFE mode at one world
(with 1.13's external_linkage false), and TrimVerifier.get_verify_typeinf_trim judges the result, its errors
OutsideSubset in Julia's verify_print_error text, its warnings notes. No other inference path exists in src: a search of
src for typeinf, infer, code_typed, return_type, code_lowered, specialize_method and _which finds them in subset.jl
alone (entry.jl names inference only in prose). That is D3 and D32 as written.

Area: emission and diagnostics — 10064fa7's and 32b7e806's src/julia/entry.jl, reject.jl and construction.jl:
compile runs check_subset, then compile_world, which takes a ClosedWorld and rejects Unported at compile.dart:216;
every path is a located rejection.

(a) The totality walk is a construction in its kind: when the package precompiles (and again when a ConstructionLock
calls it), `Base.visit(Core.methodtable)` reflects over every method whose module lies in WasmTarget and the bindings
`names(mod; all = true)`, and refuses the load for any the registry does not cover. No text is read. Its coverage test,
though, is a location: a method counts as marked when its (file, line) lies inside some entry's [first, last] span
(parity.jl:490, read, not planted), never by identity. (A36S1, low) So a method of a function
another module owns (`Base.show(io::IO, x::T) = …`), written on a marked definition's line after a `;` or inside its
span (an inner definition, an `@eval` in a body), passes: the binding check does not see it (Base owns `show`), and the
span holds its line. Methods with no location (`m.file === :none`) are excused entirely on the src/julia side. The
construction: each macro expansion registers the methods it creates by their signatures (the Method objects the
expansion's evaluation adds), and the walk matches methods to entries by identity.
(b) include_dart's directory dependency is honest: `include_dependency(dir; track_content = true)` on each directory
under src/ makes the image depend on `join(readdir(dir))` (Julia 1.12's docstring, read in the Kaimon session), so a
file added anywhere rebuilds the image and meets check_include_dart, which compares the listing to the loaded set. The
bootstrap block registers the registry's own definitions honestly: it evaluates each, then passes each through
_quarantine_entry, the same function the macro calls, with the same checks (a necessity stated, the API resolved, the
file in src/julia); a statement that is not a @quarantine definition errors. (A36S2, medium, stopgap in disguise)
@quarantine's API is checked for existence only: `_resolve_api` (parity.jl:167) asks that the qualified name resolve, never that the
definition uses it. On 10064fa7's tree `_register!` names `Base.push!` (it calls push!, true), but `_at` names
`Core.LineNumberNode`, `SRC` names `Base.dirname`, and any resolvable name passes for any definition, so the Julia
ground truth D3 asks a quarantine to name is a label checked to exist. The check is possible by reflection: the
definition's lowered code (`code_lowered` of its methods, a const's initializer) references the named API as a
GlobalRef.
(c) src_progress reads the registry: on acee85e0's successor tree it prints "0 of 0 anchored dart definitions ported",
the honest count A35S1 asked; "ported" is an entry without @unported, so a body that is a placeholder of any other
form counts ported (noted, no finding while none exists).
(A7) ClosedWorld's typestate (L220): check_sole_constructor reflects over both method tables when the package
loads and finds one ClosedWorld constructor, in subset.jl, taking _SubsetToken first, and one token constructor, in
subset.jl. That is reflection, no text read, and it holds for the definition site. (A36S3, medium, red flag) It does not
hold for the caller, which is what the typestate claims ("no code outside this file makes a ClosedWorld", "none can be
reached by a program Julia's verifier did not accept"). Measured in this lane's Kaimon session (e1d51284) on
32b7e806's tree, from Main: `WasmTarget.ClosedWorld(WasmTarget._SubsetToken(), Any[], String[])` returns a ClosedWorld,
and `Core.eval(Main, Expr(:new, WasmTarget.ClosedWorld, Any[], String[]))` returns one too, while
construction_check(Val(:ClosedWorld)) reads 0. The token's constructor is defined in subset.jl and callable from any
file, so it is a convention, not Rust's module privacy. Today only subset.jl calls either, so no stage runs on an
unverified program; nothing keeps it so. The check is possible by reflection: walk the lowered code of every method
WasmTarget defines (Base.uncompressed_ir of each Method) and refuse the load for a call of _SubsetToken or ClosedWorld,
or a `:new` of ClosedWorld, in any method outside subset.jl's check_subset.

stopgap in disguise: @parity's anchor is checked for form, file and the naming rule where it is written; its line and
symbol are not resolved at the pin (L213, 1.A6), so "each checked where it is written" holds for the form only, as C2's
Planned text says; A36S2 and A36S3 above.
precedent: include_dart, dart's `part`/`part of` and Rust's `mod`; @parity, Rust's deny(missing_docs); @quarantine,
Rust's `unsafe` with clippy's undocumented_unsafe_blocks; the registry, a Union of two structs, Rust's enum; ClosedWorld,
Rust's typestate with a private constructor, whose privacy Rust's compiler enforces at every caller and Julia's
reflection here checks only at the definition (A36S3). Julia's differs: no declaration table and no privacy, so the
macros build the one and a load-time walk must stand in for the other.

Area: enforcement and prose — every hunk of 371373c2 (dev/land.sh, test/lock_negatives.jl, test/parity_ratchet.jl),
0806bf56 (dev/MARCH.md, test/parity_ratchet.jl), 10064fa7 (AGENTS.md, dev/CHARTER.md, dev/HISTORY.md, dev/LEDGER.md,
dev/MARCH.md, dev/PARITY_MASTER.md, dev/src_progress.sh, test/parity_ratchet.jl), 32b7e806 (dev/CHARTER.md, dev/LEDGER.md,
dev/MARCH.md, test/parity_ratchet.jl, test/smoke_corpus.jl, test/smoke_times.tsv), the landing log and the gate records.
371373c2: own_s subtracts the change's waits inside an own red's span (waits.tsv), queue_wait_s floored at 0: A34E3
fixed (no Fixes: line; its prose names it). 0806bf56: the empty-clause rule written once: A33E7 fixed; its message
carries a fourth indented Co-Authored-By trailer. (A36E1, low) dev/src_progress.sh, which land runs after every landing, starts a fresh
`julia --project=.` to load WasmTarget and read the registry, beside the gate's own processes (D31); 10064fa7 measured
"on this commit", a fresh run, and 32b7e806 in its lane's Kaimon session. Requirements: D32 has its check (the subset
group's LOUD-OUTSIDE case, L220); D3's `planned: 1.A7` now cites L220; no lock fired inside its band.

Landing times (edit to landed; own, queue): 371373c2 186 s (100.2, 85.8); 0806bf56 450 s (22.0, 428.0); 10064fa7 523 s
(31.5, 491.5), unjudged past the cap at factor 1.58; 32b7e806 450 s (27.1, 422.9).

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A36S1, A36S2 and A36S3 are open on
MARCH 1.S. A36E1 is open on MARCH 1.L.

## 2026-10-22 — audited through 53ded292 (32b7e806..53ded292: entry 36, a refused head never holds the queue, one trailer, ClosedWorld's makers read in lowered code, NIR read once from the ClosedWorld)

The thirty-seventh audit covers 676671c0 (entry 36; its author's), 4c0140a4 (9c: `land wait` runs `land` as its child,
pops and re-queues a lane refused before the hold, exit 4, or on a full audit window, exit 5; a commit touching
dev/AUDIT.md queues at the head; red turns and rebase conflicts logged in dev/.loop/QUEUE.log; a stage that reached no
runner is no verdict; A35E1, A35E2, A35E3), f6ae4b7c (one Co-Authored-By trailer: the hook and CI refuse a second,
L209; Fixes: A35E4; `Charter-change: C0 authorised by Dale 2026-10-21`), dbef1df6 (check_sole_maker reads every
WasmTarget method's lowered code at load and refuses one that names the token, calls ClosedWorld or makes either with
`:new`, other than the allowed methods; Fixes: A36S3; written by the lead) and 53ded292 (1.A10: src/julia/nir.jl reads every function of the ClosedWorld into NIR, its operands the closed sum
NirValue and its statements the closed sum NirStmt, 25 kinds, each statement typed by Julia's ssavaluetypes or the
CodeInstance's rettype; L221 and L222 ConstructionLocks over check_closed_sum; `Charter-change: C1 C3 C5 authorised by
Dale 2026-10-22`). No wrong answer.
Each landed head's record is green. A35E1, A35E2 and A35E3 are fixed as 4c0140a4 states. A retraction leads this
entry. One red flag: A37S1. Findings A37S1, A37S2 and A37E1-A37E4.

Retraction (the audit lane's error). A32E1, A34E5 and A35E4, and entry 36's remark on 0806bf56, were false. Each was
read from `git show -s --format=%B <c>` followed in the same command by `git show --stat <c> | tail`, whose output
reprints the whole message indented four spaces; its last line, the trailer, read as a second, indented trailer.
Counted precisely, `git log -1 --format=%B <c> | grep -ciE '^[[:space:]]*co-authored-by'` reads 1 for bb2c2fee, 3b3a0a0c,
edf2327b, 0806bf56, f9d5e820 and dbef1df6. f6ae4b7c therefore fixed a defect that did not exist, and its message's "each
carried a second, indented Co-Authored-By line" repeats this lane's error; its hook rule and L209 are harmless and
stand as a guard. The three IDs leave their rows with this entry. The lesson for this lane: a count is read with one
command whose output is the count.

Area: builder — empty by diff: src/wasm_builder/ does not exist on 53ded292.

Area: collection and planning — 53ded292's src/julia/nir.jl: build_nir reads the ClosedWorld check_subset made, once,
and _nir_stmt projects Julia's open statement forms onto the closed sum NirStmt with one ladder over Expr heads and node
types, its last arm a located Unquarantined rejection; _nir_operand rejects every IR node form and an Expr as an
operand and takes anything else as a literal, NirConst(Core.Const(x)), which is Julia's own rule for an operand of
optimized IR (argextype: what is no SSAValue, Argument, GlobalRef, QuoteNode or IR node is a constant); a statement's
type is Julia's (ssavaluetypes, or the CodeInstance's rettype for a one-statement body stored without them), and a type
that is no Type rejects. The ladder is the one place an open Julia classification becomes a closed sum, as WT2-DESIGN's
NIR is meant to be. (A37E4, low) NirConst holds a `Core.Const`, whose `val` is typed Any, so the operand sum carries an
Any field by proxy, the kind of field 1.A8's L215 will refuse. dbef1df6's src/julia/subset.jl: construction_check(::Val{:ClosedWorld}) adds
check_sole_maker over Base.moduleroot(WasmTarget), the makers (check_subset,) and the check's own method.

Area: emission and diagnostics — dbef1df6's src/julia/construction.jl, check_sole_maker and _makes.

stopgap in disguise: (A37S1, medium, red flag) check_sole_maker reads lowered IR, reflection at load, no source text:
in its kind a construction, Julia's stand-in for Rust's privacy checker, which is itself a compiler pass over every
item. Its coverage, though, is an enumerated set of IR forms, a GlobalRef to the token, a call whose callee resolves
to ClosedWorld, a `:new` of either, and Julia has more ways to build a struct than it names. Measured in this lane's
Kaimon session (e1d51284) on dbef1df6's tree, with check_sole_maker run on a probe module (a token `Tok`, a struct
`W(::Tok, x)`, a maker `maker(x) = W(Tok(), x)`): a method calling `W(Tok(), 1)` is refused, as it should be, while
five others pass at 0, and four of them, run, each return a W: `Expr(:splatnew, W, (1,))` (only `:new` is read), a
`ccall(:jl_new_struct, Any, (Any, Any...), W, 1)` (a foreigncall's arguments are read only for the token), the token
fetched as `getfield(@__MODULE__, Symbol("To", "k"))()` (no GlobalRef names it), an `@generated` body returning
`Expr(:new, W, 1)` (a generator's code is not the method's lowered source); and a second method of the maker,
`maker(x::String) = W(Tok(), 2)`, passes because the allowed set is every method of each maker function, taken from
`methods(f)` when the check runs, so identity is matched against a set that grows with the function. The fix: read
`:splatnew` and the foreigncalls jl_new_struct, jl_new_structv and jl_new_structt beside `:new`; refuse in WasmTarget's
own code any `@generated` function, `eval`, `invokelatest` of a non-constant callee and `getfield`/`getglobal` of a
module with a computed name (WasmTarget needs none); allow the maker by the one Method it is, captured beside its
definition. The claim limited to WasmTarget's own code is honest and stated so; package extensions are modules outside
Base.moduleroot(WasmTarget), so ext/ (re-ported in 1.F) falls outside it, which the claim should name.
precedent: NirStmt and NirValue, Rust's enum with an exhaustive match and dart's sealed class with its switch (a
Union of concrete structs checked at load, as Rejection); check_sole_maker, Rust's private constructor, enforced by the compiler at every caller; Julia has neither privacy nor a
closed set of ways to construct, so a load-time read of the package's IR stands in, sound only for the forms it reads.

Area: enforcement and prose — every hunk of 4c0140a4 (dev/land.sh, dev/land_queue.sh, dev/block.jl, test/lock_negatives.jl,
test/parity_ratchet.jl), f6ae4b7c (dev/hooks/commit-msg, .github/workflows/ci.yml, dev/LEDGER.md, test/parity_ratchet.jl),
dbef1df6's test/parity_ratchet.jl and dev/MARCH.md, the landing log, the queue's log and the gate records. 9c is sound
where its message says: a refusal before the hold pops, logs and re-queues once the preflight passes, so a refused
head no longer holds the queue. (A37S2, low) `front` is granted to any commit whose diff touches dev/AUDIT.md
(`git diff --quiet <base> HEAD -- dev/AUDIT.md`), not to one that adds the next entry, so a lane that edits the audit
log's preamble or an old entry jumps the queue; audit_window.sh's own-tree reading (HEAD's entries more than origin's)
is the test the message states. (A37E1, low) A lane refused at its turn by the queue check itself (`may` lost to a
stale skip between `wait`'s read and `land`'s) exits 4 like a preflight refusal, is popped, and re-queues at the tail,
its place lost; and lanes refused by a full window re-enter in the order their 30-s polls happen to wake, not their
order before. (A37E2, low) The trailer rule binds by the installed hook, and the shared hook
(`$(git rev-parse --git-common-dir)/hooks/commit-msg`) differs from dev/hooks/commit-msg and holds no Co-Authored-By
rule; `land` runs no hook on a landing commit; L209 tests the tracked file; CI's message-hygiene runs only at closure.
A rule a lane's installed copy lacks binds no landing. (A37E3, low) Kaimon: dbef1df6 and f6ae4b7c measured "in fresh
processes" and "by hand"; 4c0140a4 replayed in bash. 53ded292 measured in its lane's Kaimon session and on Julia 1.13.1. Requirements: D13's queue holds its turn order; L220
gains its maker check; no lock fired inside its band.

Landing times (edit to landed; own, queue): 4c0140a4 319 s (37.8, 281.2); f6ae4b7c 71 s (26.1, 44.9); dbef1df6 34 s (33.3, 0.7); 53ded292 642 s
(32.2, 609.8), unjudged (cold).

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A37S1 and A37S2 are open on MARCH
1.S. A37E1, A37E2, A37E3 and A37E4 are open on
MARCH 1.L.

## 2026-10-22 — audited through 97ed7e3a (53ded292..97ed7e3a: entry 37, one _within and a red load without an image, the ClosedWorld check widened, private depots, L220 and L224 split)

The thirty-eighth audit covers 4f1ecde9 (entry 37; its author's), 1abb9261 (one `_within`; the load stage asserts
Base.isprecompiled, red unless Julia saved the package image), 29602959 (check_sole_maker reads `:splatnew` and the
jl_new_struct foreigncalls, resolves a call's callee through its SSA statement, allows the maker as its one Method, and
refuses an @generated method, eval, include_string, include and a computed module lookup outside parity.jl and
construction.jl; Fixes: A37S1; written by the lead), ea466c71 (a private depot per worktree, dev/depot.sh, dev/lane.sh
depot, test/depot_isolation.jl) and 97ed7e3a (L220 stays a construction for the sole constructor that takes the token; who calls it is L224,
a stopgap cited by C6 and run at load, its read resolving operands through SSA statements and module getproperty and
getfield, eval caught in any operand position, its plants real methods; `Charter-change: C6 authorised by Dale
2026-10-22`; written by the lead, in answer to this entry's draft). No wrong answer. Each landed head's record is green. Every finding
below rests on one exact command, quoted. Two corrections lead. One red flag, A38S1, which 97ed7e3a answers in the range. Findings A38S1, A38S2, A38E1 and A38E2.

Corrections (the audit lane's). (1) After entry 37 landed, this lane told the lead that every gate ran cold because
twelve worktrees evicted each other's images in a shared depot. That was wrong. The exact commands, on wt2-audit at
4f1ecde9: `grep -n "function _within" src/julia/*.jl` printed construction.jl:104 and parity.jl:455, and
`julia --project=. --startup-file=no -e 'using WasmTarget'` printed "WARNING: Method definition _within(Module, Module)
in module WasmTarget at …/parity.jl:455 overwritten" and "ERROR: Method overwriting is not permitted during Module
precompilation": no image was saved, so every load rebuilt it. The loader's "wrong source" rejections were its normal
lookup by path, and the shared depot held 9 images under its cap of 10. loop4 found the cause; 1abb9261 fixes it.
(2) ea466c71's message and dev/depot.sh's header state the retracted cause ("each tree's image evicted another's").
Private depots are harmless isolation, and test/depot_isolation.jl measures what they do, but the premise is this
lane's error, and 1abb9261 had measured the real cause before ea466c71 landed. Measured after both, on wt2-audit with
its private depot, twice: `.wtd/julia --project=. --startup-file=no -e '@time using WasmTarget;
println(Base.isprecompiled(Base.PkgId(Base.UUID("9f3a1415-1112-405b-ae89-c61daf9872bd"), "WasmTarget")))'` printed
0.011 s and true, then 0.009 s and true.

Area: builder — empty by diff.

Area: collection and planning — 29602959's src/julia/subset.jl: the maker is `only(methods(check_subset))`, so a
second check_subset method refuses the load and a second method of any maker is no maker (A37S1's fifth case, fixed).

Area: emission and diagnostics — 29602959's src/julia/construction.jl: _makes, _ccall_name, _resolve, _callee_name and
_escapes.

stopgap in disguise: (A38S1, medium, red flag) check_sole_maker still lets five forms build a ClosedWorld, and its new
`:splatnew` arm cannot fire on real lowered code. Measured in this lane's Kaimon session (e1d51284) on a probe module
(`struct Tok`, `struct W; W(::Tok, x::Int) = new(x); end`, `maker(x::Int) = W(Tok(), x)`), each checked with
`WasmTarget.check_sole_maker(P, P.W, P.Tok, (only(methods(P.maker)),), (), ())` and then run: `(@__MODULE__).W((@__MODULE__).Tok(), 1)`,
`getfield(@__MODULE__, :W)(getfield(@__MODULE__, :Tok)(), 1)`, `Core.eval((@__MODULE__, :(W(Tok(), 1)))...)`,
`Base.invokelatest(Core.eval, @__MODULE__, :(W(Tok(), 1)))` and `$(Expr(:splatnew, :W, :((1,))))` each read 0 and
each returned a W. The causes. Lowered code spells `M.x` as a getproperty call, never a GlobalRef, so the natural
`WasmTarget.ClosedWorld(WasmTarget._SubsetToken(), …)` is not seen; a callee that is an SSA value of a getfield is
resolved to an Expr that `is` does not match; eval in an argument position (Core._apply_iterate for a splat,
invokelatest) is not read, since _escapes reads the callee only. And `:new` and `:splatnew` take their type through a
statement of its own: `Base.uncompressed_ast(only(methods(P2.sneak_new))).code` reads `Any[:(Main.P2.W), :(%new(%1,
1)), :(return %2)]`, while the arm tests `is(x.args[1], T)` with no `_resolve`, so no lowered `:new` or `:splatnew` is
ever seen; that arm was dead in dbef1df6 as well. L220's plants pass regardless: the `:splatnew` plant
(parity_ratchet.jl:366) is refused only because it calls Core.eval, an escape, and the "read directly" plant (:380)
hands _makes a hand-built `Expr(:splatnew, clean.W, :t)` with the type inline, a shape lowering never makes. The fix:
resolve every SSA operand (the `:new` and `:splatnew` type, the callee, getproperty and getfield chains to the binding
they name); read eval, include_string and include in any argument position; write each plant as a real method whose
lowered code the walk reads. 97ed7e3a answers it inside the range, and honestly: L220 claims only what reflection
makes true (one constructor, taking the token, both in subset.jl), and the caller read is L224, a stopgap, so C6's
status reads "L224 stopgap". Re-measured in this lane's new Kaimon session (3e431c53, DEPOT_PATH[1] the worktree's
private depot) on 97ed7e3a's tree, with the same probe and call: the module-qualified form, the splatted eval and the
`:splatnew` each read "refused". (A38S2, medium) L224 still misses a local variable. `sneak() = (T = W; t = Tok;
T(t(), 1))` reads 0 and returns a W; `Base.uncompressed_ast(only(methods(P3.sneak))).code` reads `_3 = Main.P3.W`,
`_2 = Main.P3.Tok`, `_3`, `_2`, `(%4)()`, `(%3)(%5, 1)`, `return %6`: lowering holds a local in a slot, `_binding`
stops at a SlotNumber, and an assignment's right side is never read as naming the token. The same with the token
taken by reflection, `tk = Base.unwrap_unionall(first(methods(T)).sig).parameters[2]`, reads 0 and returns a W. The
fix: resolve a slot through its assignments (one assignment, its right side; more, refuse), and read a GlobalRef to the
token wherever it stands, an assignment's right side included.
precedent: Rust's private constructor, enforced by the compiler at every caller; Julia's lowered IR is the nearest
thing it has to read, and the read must follow its SSA form to see what it claims to see.

Area: enforcement and prose — every hunk of 1abb9261 (dev/block.jl, test/parity_ratchet.jl, src/julia/construction.jl),
29602959's test/parity_ratchet.jl, ea466c71 (dev/depot.sh, dev/gate.sh, dev/land.sh, dev/lane.sh, dev/block.jl,
dev/block_runner.jl, test/lock_negatives.jl, test/depot_isolation.jl, test/runtests.jl, test/block_groups.tsv), 97ed7e3a (dev/CHARTER.md, src/WasmTarget.jl, test/block_groups.tsv, test/parity_ratchet.jl), the landing log and the gate records. 1abb9261 is sound: the load stage asks Julia's own Base.isprecompiled, so a
precompile error is a red load, never a cold run; this answers the gate-side half of the cold-gate class (a method
overwrite during precompilation passed every stage for three landings, dbef1df6, 53ded292 and 4f1ecde9, each
"unjudged (cold)"). (A38E1, low) ea466c71's message and dev/depot.sh's header give a cause measured false (the
corrections above); the fix is a one-line header that names the real cause, or the isolation as the reason.
(A38E2, low) Kaimon: 1abb9261 and 29602959 measured "in fresh processes"; ea466c71 in its lane's Kaimon session.
97ed7e3a measured in fresh processes. Requirements: D9 and D32 hold where the subset's typestate holds (A38S2 bounds it); no lock fired inside its
band.

Landing times (edit to landed; own, queue; gate state): 1abb9261 233 s (121.6, 111.4; warm); 29602959 25 s (24.6, 0.4;
cold); ea466c71 145 s (51.0, 94.0; cold); 97ed7e3a 25 s (24.0, 1.0; warm).

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A38S1 is answered by 97ed7e3a,
which carries no Fixes: line for it. A38S2 is open on MARCH 1.S. A38E1 and A38E2 are open on MARCH 1.L.

## 2026-10-22 — audited through 739d623d (97ed7e3a..739d623d: entry 38, the class-id model, anchors resolved at the pin, the closed world's classes, the two-pass loader)

The thirty-ninth audit covers 713a8872 (entry 38; its author's), 5b3573a0 (dev/formal/ClassIdNumbering.tla, dart's
class-id walk before its port, 1.C), 973a216e (1.A6, L213: every @parity anchor resolves at the pin, read where it is
written and at load; `Charter-change: C2 authorised by Dale 2026-10-21`), 55c5a967 (src/julia/classes.jl, the closed
world's classes in program order, 1.C) and 739d623d (include_dart in two passes into a module per dart package; a method
matched to its definition by identity; a quarantine's API referenced; Fixes: A36S1 A36S2). No wrong answer: the
rebuild compiles nothing yet. Each landed head's record is green. Every finding rests on one exact command, quoted.
One ruling recorded. Findings A39S1, A39E1 and A39E2.

Area: builder — empty by diff: src/wasm_builder/ does not exist on 739d623d.

Area: collection and planning — 55c5a967's src/julia/classes.jl: closed_world_classes walks each NIR body's signature,
statement types and return type; every edge is Julia's (supertype, fieldtypes, and typeof for a type held as a value,
Base.iskindtype's four kinds when the type is not known); any other UnionAll rejects as Unquarantined, located; Union{}
brings nothing. Sound. 5b3573a0's model: its anchors read at the pin with `sed -n 831p pkg/dart2wasm/lib/class_info.dart`
(`List<Range> getConcreteClassIdRange(Class klass) {`) and `sed -n 864p` (`static ClassIdNumbering _number(`); dart
starts concrete ids at 1 ("`0` is occupied by artificial non-Dart top class") and abstract ids at
`nextConcreteClassId + concreteClassCount`, as the model; dart's saved ids (classIds, dynamic modules) are out of scope
and left out. Sound.

Area: emission and diagnostics — empty by diff for emission; 739d623d's src/julia/nir.jl and reject.jl change only
their quarantine APIs and docstrings.

stopgap in disguise: 739d623d's A36S1 fix is identity in kind: each entry records the worlds its evaluation spanned, and
each method is matched to the entry whose evaluation made it (its primary_world), saved in the package image. Its A36S2
fix asks that a definition's expression reference its API, and admits "the form standing for it": a type declaration
for Core.DataType, an interpolated string for Base.string. (A39S1, medium) That admission makes the API a label again
for the mirrors. Measured on 739d623d: `grep -n "^@quarantine" src/julia/nir.jl` names Core.DataType for 24
definitions and Core.String for 29; `grep -n "Core.DataType struct" src/julia/nir.jl` lists NirSSA ("names a
statement's value by SSAValue"), NirArgument, NirCall, NirNew, NirForeignCall, NirBoundscheck and the rest of the
statement mirrors, where 53ded292 named Core.SSAValue, Core.Argument and Core.Expr; the handlers `value_form` and
`stmt_form` name Core.String because they return a string. The ground truth D3 asks a quarantine to name is the Julia
form a mirror mirrors, and it can be checked by reflection and a run at load: each mirror names its form (NirSSA
Core.SSAValue, NirCall Expr(:call), …), and the load converts a sample of each form through _nir_operand or _nir_stmt and
requires the mirror back. As the lead ruled, this is filed as a requirement for the mirrors.
precedent: the module per dart package, dart's library prefixes (`import 'ir/ir.dart' as ir`); the class list, dart's
component classes (class_info.dart:864), Julia's types inferred for its values; the anchors, Rust's deny(missing_docs)
with each doc's target resolved.

Area: enforcement and prose — every hunk of 973a216e (dev/HISTORY.md, dev/LEDGER.md, dev/MARCH.md,
dev/fetch_dart_sdk.sh, src/WasmTarget.jl, src/julia/parity.jl, test/parity_ratchet.jl), 55c5a967 (test/classes.jl,
test/runtests.jl, test/block_groups.tsv), 739d623d (src/julia/packages.jl, src/julia/parity.jl, the quarantine APIs,
test/parity_ratchet.jl), the landing log and the gate records. Ruling recorded: A6's load-time resolution skips when
~/.cache/wasmtarget/dart-sdk is absent, by design (users load WasmTarget without the dart SDK; the gate's L213 requires
the checkout). (A39E1, medium) L207 holds a lock to calling its negatives function, not to its plants running: 973a216e's
message records that L210 to L212's plants "ran in no gate since 32b7e806's rebase: a conflict resolution left an empty
`elseif` above the branch that runs them in construction_negatives_missed", so three locks read as negative-tested for
several landings with no plant run. The fix the lead wants, queued after the port: each negatives function returns its
plant count, and L207 requires every lock's count above 0. (A39E2, low) Kaimon: 55c5a967 measured "WT_QA_ONLY=classes.jl,
26 of 26" with no session named; 973a216e and 739d623d measured "on this commit". Requirements: D3 (A39S1); D1's anchors
now resolve at the pin; no lock fired inside its band.

Landing times (edit to landed; own, queue; gate state): 5b3573a0 185 s (25.9, 159.1; cold), unjudged past the cap at
factor 1.6; 973a216e 3181 s (22.8, 3158.2; cold); 55c5a967 24 s (22.9, 1.1; cold); 739d623d 1540 s (105.4, 1434.6;
cold-after-warm).

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A39S1 is open on MARCH 1.S. A39E1 and
A39E2 are open on MARCH 1.L.

## 2026-10-22 — audited through 24ed6a9e (739d623d..24ed6a9e: entry 39, a charter change authorised by its patch-id, closed sums matched @exhaustive, functions declared between the passes, dart's late final field)

The fortieth audit covers 55ea0727 (entry 39; its author's), 560247c4 (dev/.block/charter_authorised also takes
`patch:<id> - <clauses> <date>`, the change's `git patch-id --stable`, so a rebase that keeps the hunks keeps the
authorisation; written by the lead), 6ea4b04b (1.A8: `@closed` and `@exhaustive`, L217; A34S4's sealed half; one inner
constructor per ported struct; L214 typed parameters, L215 no Any field; `Charter-change: C4 C5 authorised by Dale
2026-10-21`), 41faad3b (every function a marked definition binds is declared between the loader's passes) and 24ed6a9e
(src/julia/late.jl: Late{T}, dart's `late final` field, carrying its field's anchor; a read before the assignment
rejects as Unported with the anchor, a second assignment as Internal; with an initializer, init runs on the first read;
written by loop4). No wrong answer. Each landed head's record is green. Every finding rests on one exact command, quoted.
A34S4 is fixed as 6ea4b04b states. Findings A40S1, A40E1, A40E2, A40E4 and A40E5.

Area: builder — empty by diff: src/wasm_builder/ does not exist on 24ed6a9e. Skeleton commit 1, which writes it, was
refused by the full window and falls in entry 41's range.

Area: collection and planning — 41faad3b's src/julia/parity.jl: between the passes, `function f end` for each bare
function name a marked definition binds, so an implementation in a later module's file finds its generic function;
no method is made, so identity matching stands. Sound; precedent dart's resolution of a library's names before its
bodies.

Area: emission and diagnostics — 6ea4b04b's src/julia/reject.jl and nir.jl: `_reason`, `stmt_form` and `value_form` are
each one @exhaustive match.

stopgap in disguise: @closed and @exhaustive are constructions in kind: the match refuses, where it is written, a missing,
extra, repeated, wildcard or untyped arm, and its expansion is an isa chain under a type assertion on the subject, its
last arm the chain's else, so a value outside the sum throws a TypeError and no arm is taken by default
(construction.jl's `macro exhaustive`, read). (A40S1, low) The guarantee covers the matches written with @exhaustive and
no other: a hand `isa` ladder or a method per kind over a @closed sum is not read, so D8 ("match a closed sum with
@exhaustive") binds by convention for those; and the arms are matched to kinds by name (`k in kinds`, `nameof(T)`), while
the expansion's `isa(v, k)` resolves `k` where the match is written, so a local binding of a kind's name (a parameter
named `A`) would test another type and fall to the last arm.
precedent: @closed and @exhaustive, Rust's enum and match (E0004) and dart's sealed class and switch; Julia has no closed
declaration and no match, so a macro checks each match where it is written and the load checks every sum and match
again. Late{T}: dart's `late final`, Rust's OnceCell and LazyCell (late.jl:22).

Area: enforcement and prose — every hunk of 560247c4 (dev/land.sh, test/parity_ratchet.jl), 6ea4b04b (dev/CHARTER.md,
dev/HISTORY.md, dev/LEDGER.md, dev/MARCH.md, src/julia/*, test/parity_ratchet.jl), 41faad3b, 24ed6a9e (src/julia/late.jl, src/julia/packages.jl, test/late.jl, test/runtests.jl, test/block_groups.tsv), the landing log and
the gate records. (A40E1, medium) A patch-id authorisation admits a changed hunk whose change is whitespace, and it is
reusable without bound. `git patch-id --stable` drops every whitespace character, measured on a scratch repository whose
CHARTER.md held "the gate takes at most 60 s of wall": the reviewed change to "at most 90 s of wall" gave
d1d4421252d1eb4f2a0b213dd0b19cd1d755bfbc, and so did "at most 90 s  of  wall", "atmost90sofwall" and "at most 9 0 s of
wall", while "at most 900 s of wall" gave c11798e143527bc24859e23edbbc3a32b0b985bd. Whitespace carries meaning in the
charter's check lists ("L19 2" and "L192" hash alike). The authorisation also names no commit, so any later commit making
the same change (a revert re-applied, another lane's copy) is admitted under it. The fix: key the authorisation to the
patch-id and the diff's text with whitespace kept (`git diff` hashed as it is), and spend it once, on the commit it
admitted. 560247c4 is otherwise sound: the clause rule (every changed line inside the authorised clauses) and the date
still bind, and a changed hunk changes the id. (A40E2, low) Kaimon: 560247c4, 6ea4b04b and 41faad3b measured "in fresh
processes" or "on this commit"; 24ed6a9e "in a fresh process". (A40E4, low) Late{T}'s initializer value is
`convert(T, init())` (late.jl:42): dart's static type makes init return a T, where Julia's convert can change a value's
representation without a word (an Int64 initializer for a Late{Float64} becomes 2.0), and late.jl's test "the value
converted to the field's type" holds that conversion; a typeassert, `init()::T`, rejects a wrong type where dart's
types would. (A40E5, low) Its state is a byte with three meanings (`state::UInt8`, "0 unassigned, 1 its initializer
running, 2 assigned", late.jl:29), a classification A8's @closed or an @enum would make closed; and a read before the
assignment rejects as Unported, the right kind while the assigning code is unported and the wrong one after it is.
Requirements: D8 (A40S1); D19's authorisation pair (A40E1); no lock fired inside
its band.

Landing times (edit to landed; own, queue; gate state): 560247c4 25 s (23.5, 1.5; cold); 6ea4b04b 3529 s (24.3, 3504.7;
cold); 41faad3b 25 s (23.5, 1.5; cold); 24ed6a9e 49 s (48.3, 0.7; cold), unjudged past the cap at factor 2.13.

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A40S1 is open on MARCH 1.S. A40E1 is fixed by
59ba9f14, which lands after this entry (a whitespace-kept content hash and a spent-once mark), and is open on MARCH 1.L
until it does. A40E2, A40E4 and A40E5 are open on MARCH 1.L.

## 2026-10-28 — audited through 8f63b00c (24ed6a9e..8f63b00c: entry 40, the loader's last fixes, the two skeletons, the restart on dev/ship.sh and dev/check.sh, the dart test map, Range, TranslatorOptions, ClassIdNumbering, FieldIndex, util and Namer)

The forty-first audit runs beside the work (D21 as Dale restated it 2026-10-28) and covers 56eeec5e (entry 40; its
author's), 82ce1cf5 (a package member function defined only from a prefixed library declared in the package module),
9589972d (each mirror names its Julia form, L225; Fixes: A39S1), 1d56789d (A40E1's whitespace-kept content hash in
dev/land.sh), 6fd28817 (check_typed_fields by field index; a `const` field orders its declaration), 44eade5c (dev/skeleton.jl
and src/wasm_builder/'s 45 files, the source map and serializer filled), 07aa7542 (the dart2wasm skeleton, 1,405
`@unported` definitions), b3adca48, c917ee6d and decdad82 (the restart: dev/ship.sh lands, dev/check.sh is the evidence,
L148 listed open, D13 D14 D16 D21 D23 restated, every lane on wt2), 868ba6cc (test/dart_tests.toml and L226), 2c32af79
(Range, normalize), 8ef0b817 (TranslatorOptions), 12e6e66a, 1bdcadf5 and 7e825dcb (46 behavior and 10 structural dart
tests written as Julia cases), 95447a02 (ClassIdNumbering over the closed world's classes; Translator), 704d64b4
(FieldIndex) and 8f63b00c (util.dart's helpers, Namer). The range starts at 24ed6a9e, where entry 40 ends, so the
entries chain (L148). No wrong answer: WasmTarget compiles nothing yet. Every finding rests on one exact command, quoted.
Rulings recorded on the lead's four points. Findings A41S1 to A41S4 and A41E1 to A41E7.

Area: builder — 44eade5c's src/wasm_builder/: an unported definition is a construction, read in src/julia/parity.jl's
`_unported` (686–706): a function's body must be empty and becomes `reject!(Unported(anchor), …)`; a struct must have no
fields and no type parameters, and its one constructor rejects, so a stub can return no value. The filled serializer's
test takes its bytes from the binary format, never from the code under test: `write_unsigned(s, 624485) == [0xe5, 0x8e,
0x26]` is the LEB128 example the spec gives (test/wasm_builder/serializer.jl:27). Sound.

Area: collection and planning — the lead's rulings, each read in the code at 8f63b00c. Translator's fields arrive with
their pieces: `struct Translator <: KernelNodes` holds `options`, `component::Vector{NirBody}` and
`class_id_numbering::Late{ClassIdNumbering}` (src/translator.jl), no placeholder, dart's other fields named in its
docstring; sound. Class = DataType by identity: ClassIdNumbering's maps are `IdDict{DataType,…}`, class_superclass is
`supertype` with Any the root, class_is_abstract `!isconcretetype`, and a covariant Tuple (neither concrete nor abstract)
rejects, located (src/julia/classes.jl); sound as far as it goes, see A41S3. implementedTypes: `implementors` is built
empty in `ClassIdNumbering__number`, Julia having no interfaces; `_get_transitive_implementors` and
`get_concrete_class_id_range` keep dart's `?? const []` (class_info.dart:837–843), a faithful read of an empty map, no
default past a gap. No masquerades: `first_non_masqueraded_interface_class_cid` is dart's late closure over `_masqueraded`,
which arrives as the caller's set, ported 1:1 (class_info.dart:853); none is invented. Range and normalize, TranslatorOptions
and its six getters (translator.dart:48–88: thirty fields, each initializer and each `??` getter, read side by side) and
Namer (namer.dart:23–62) are dart's line for line; FieldIndex's 37 constants are dart's values. `_number` keeps dart's
walk, its counts, its pre and post closures and even its never-updated `inDfsOrder` (class_info.dart:962–963), and drops
only the `order` sort of the root's children, which its docstring names (dart's core-class preference). Is 1:1 becoming
nominal where dart reads Kernel? Not in this range: each port keeps dart's body and swaps the Kernel read for one Julia
answer at a quarantined seam (classes.jl's `closed_world_classes`, `class_superclass`, `class_is_abstract`); the anchors
name the dart that the bodies follow. The risk is where a Kernel read has no Julia answer, and three findings sit there.

(A41S1, medium) The skeleton's scope drops a whole dart file on a reason true of part of it. dev/skeleton_scope.toml:28
lists `"dart2wasm/lib/modules.dart" = "deferred loading is out of scope"`, but modules.dart also holds the monolithic path
every compile takes: `sed -n 182,195p pkg/dart2wasm/lib/modules.dart` shows DefaultModuleStrategy's
buildModuleOutputData, "If deferred loading is not enabled then put every library in the main module", returning
`ModuleOutputData.monolithic(mainModule)`, and translator.dart:417 holds `final ModuleOutputData _moduleOutputData;`, read
by `translate` (translator.dart:524, `Map<ModuleMetadata, w.Module>`). The skeleton keeps the reader and drops the type:
`git show 07aa7542:src/translator.jl | grep -n _module_output_data` gives line 139, Translator's stub taking
`_module_output_data`. This is the pattern the lead ruled out for test directories (a group excluded only if every member
is): modules.dart joins the pin table, its deferred-only definitions each rejecting as out of scope where they are
written.

(A41S2, medium) L220's typestate stops short of the Translator. The commit says "a translator exists only for a program
Julia's trim verifier accepted"; the code lets any caller build one. Translator's inner constructor takes
`component::Vector{NirBody}`, and NirBody has Julia's default constructor (src/julia/nir.jl:214–218, three fields, no
inner constructor). Measured on 8f63b00c with this tree's depot, a script building a NirBody from `sin`'s CodeInstance and
no ClosedWorld (`julia --project=. --startup-file=no tr.jl`): "built without a ClosedWorld:
WasmTarget.Dart2Wasm.Translator with 1 body of MethodInstance for sin(::Float64)". L224 holds ClosedWorld's makers, not
NirBody's. The fix by construction: NirBody's one inner constructor takes the ClosedWorld's token or is reachable only
from build_nir, and L224's maker check covers it (precedent: Rust's private field making a type constructible only in its
module).

(A41S3, medium) A class's id ranges answer Julia's `<:` between DataTypes, and a value's membership is `isa`, which
differs for the kinds. Measured, `julia --startup-file=no -e 'println((Int isa Type{Int}, DataType <: Type{Int},
isabstracttype(Type{Int}), supertype(Type{Int})))'`: "(true, false, true, Any)". Type{Int} is an abstract class whose
supertype is Any, so no concrete class sits under it and `get_concrete_class_id_range(Type{Int})` is empty, while the value
Int, of class DataType, is a member. Nothing reads the ranges for `isa` yet; when a type test lowers to a class-id range
check (dart's `isSubtype` by ranges), `x isa Type{Int}` answers false for Int, a wrong answer with no rejection. Type{T},
like the covariant Tuple class_is_abstract already rejects, needs a located rejection at the range query until the classes
implement it (D3: `isa` is Julia's answer, the supertype tree an approximation of it for the kinds).

(A41S4, low) 82ce1cf5's `_generic_name(st)::Union{Tuple{Any,Symbol},Nothing}` (src/julia/parity.jl) types its module path
Any, where the values are `nothing`, a Symbol or a dotted Expr (C4: no Any outside a named seam). 6fd28817 is sound:
`Meta.isexpr(f, :const) && (f = f.args[1])` unwraps a mutable struct's const field, and the by-index loop asks Julia the
same three facts.

stopgap in disguise: the @unported stub is a construction (its body cannot be written); the ClosedWorld typestate is one
for compile_world and, by A41S2, not yet for the Translator; L226 is a check over a map, as C2 says, and its directory
entries carry coverage they have not earned (A41E6).
precedent: the skeleton, Rust's todo!() (parity.jl:688); class ids, dart's DFS numbering (class_info.dart:864) over
Julia's supertype tree; Late fields, dart's `late final` (late.jl).

Area: emission and diagnostics — empty by diff for emission: code_generator.jl, intrinsics.jl and functions.jl are
07aa7542's stubs. 8f63b00c's util.jl: `compiler_asserts_enabled()::Bool = true`, dart's flag fixed on, so every dart
`assert` a port reaches is a located Internal rejection (Namer.reserveName's, intToMinString's): stricter than dart,
named. Sound.

Area: enforcement and prose — every hunk of b3adca48, c917ee6d, decdad82 (AGENTS.md, dev/LEDGER.md, dev/check.sh,
dev/ship.sh, dev/lane.sh, test/ratchet_open.txt, test/src_tests.jl), 868ba6cc (dev/CHARTER.md, dev/LEDGER.md,
dev/MARCH.md, test/dart_tests.toml, test/parity_ratchet.jl), 12e6e66a, 1bdcadf5, 7e825dcb, 9589972d's and 1d56789d's
dev/ and test/ hunks. Both charter changes in the range are authorised: 9589972d's blobs 0d6556d4→17e4ab40 (C3) and
868ba6cc's 17e4ab40→134fc9fa (C2 C3) are lines 40 and 43 of the main tree's dev/.block/charter_authorised. Ruling on
"does dev/check.sh fail on what it claims": on a broken lock or ratchet, yes; on a stray baseline key, no (A41E1).
dev/ship.sh pushes only the tree it checked: a push a faster lane beat is refused as non-fast-forward and the loop
rebases and checks again. The dart cases record native Julia's answer and check it: `@test f(args...) === native`
(test/dart_tests.jl), so Julia is the ground truth, as D3 asks; and a compile that moves past its recorded rejection fails
the case until it is recorded again, so none passes silently.

(A41E1, medium) dev/check.sh judges the ratchet by grepping its lines and never reads its exit status, so a failure
printed in another form passes. The ratchet fails on a stray baseline key, printing `❌ STRAY baseline key [metrics]
<key>: …, FAIL` (test/parity_ratchet.jl, run's last loop, `ok = false`). check.sh's pattern does not match it: `printf
'%s\n' '❌ STRAY baseline key [metrics] R46_gone: names no METRICS ratchet, FAIL' 'R45_locks_owing_negatives       13  ❌
RATCHET BROKEN (+1)' 'L148_changes_are_audited         1  ❌ LOCK BROKEN (want 0)' | grep -oE
'^[LR][0-9]+_[a-z0-9_]+ +[^ ]+ +(❌|BROKEN)|^[LR][0-9]+_[a-z0-9_]+.*BROKEN'` prints the second and third lines alone.
The fix: the ratchet's exit status decides, and test/ratchet_open.txt's locks are passed to the ratchet to exempt.

(A41E2, medium) b3adca48 opened L148 whole (test/ratchet_open.txt: "L148 the audit window"), where D21's restatement
frees the window alone: the chain, the four areas and the Resolution of every entry stopped binding with it, since
check.sh exempts by lock id (`comm -23` on ids). The ratchet output the tests lane's check left at 10:09
(.worktrees/wt3-tests/.wtd/ratchet.out) holds `L148_changes_are_audited 1 ❌ LOCK BROKEN (want 0)`, and its check passed.

(A41E3, medium) The loop's timing has had no check since the restart, while a lock read as locked. L197 read the local
`wt2` branch of the worktree holding it and that tree's landings.tsv (test/parity_ratchet.jl, `git -C $ROOT rev-parse
wt2`), which ship.sh never advances or writes: `git -C WasmTarget.jl rev-parse --short wt2` gives 6fd28817, and the same
lane's check printed "L197: 101 commits landed since 36e3966e; the window 56eeec5e 0.14, 82ce1cf5 0.13, 9589972d 0.16,
1d56789d 0.75, 6fd28817 0.13" where `git rev-list --count --no-merges 36e3966e..7e825dcb` is 114. D13's band (a 300-s
target for the median edit to landed of the last five landings) and D14's (a 60-s target for the check, red past 120 s)
cite dev/ship.sh and dev/check.sh as their checks; both print seconds and judge none, and ship.sh lands any number of
commits, checking only the head's tree, where D13 says one small commit (D17, D18: a band stated with no check).

(A41E4, medium) One path: dev/land.sh, dev/land_queue.sh, dev/block.jl and `dev/gate.sh --block` stayed beside
dev/ship.sh and dev/check.sh, their text held in place by L194, L195, L197 and L198 (`ls dev/land.sh dev/gate.sh
dev/block.jl dev/land_queue.sh` on 8f63b00c lists all four), and D23's row still cited `L197` `dev/land.sh` (D5: the
commit adding a path deletes the other).

(A41E5, medium) A charter change lands unchecked. `grep -rln charter_authorised dev test src` on 8f63b00c lists
dev/land.sh, dev/AUDIT.md and test/parity_ratchet.jl: only land.sh read the authorisations, and ship.sh never calls it,
so since b3adca48 a commit changing dev/CHARTER.md under a `Charter-change: … authorised by Dale <date>` line lands on the
line's word alone (D19: propose charter edits only). The precedent the lead had, a review recorded outside the tree and
matched by content, needs a reader in dev/check.sh.

(A41E6, medium) The test map's not_portable directories carry files that are portable. Counted at 8f63b00c with a
python3 reading of test/dart_tests.toml against `git -C ~/.cache/wasmtarget/dart-sdk ls-tree -r --name-only 898a1e4b`:
109 directory entries are not_portable and cover 3,081 files, 109 file entries 109 more, 3,190 of 4,716; seven directory
reasons say so themselves, "mostly static diagnostics" or "largely static" (class_modifiers, const, dot_shorthands, nnbd,
primary_constructors, type_variable, variable: 604 files). Of the 276 files under tests/language/nnbd/ and const/, 166
carry no static-error marker (`grep -q 'compile-time error\|\[analyzer\]\|\[cfe\]'` fails), 86 of them with runtime
`Expect.` checks; nnbd/late/chained_assignment_test.dart checks `b = a = 1` and `b = foo.x = 3`, a Julia program as it
stands. L226 asks a not_portable entry only for `what` and `reason` (test/parity_ratchet.jl:1115), and its summary counts
entries ("78 behavior (46 ported) … 218 not portable"), not the 3,190 files, so the map reads more complete than it is. As
the lead ruled, a directory is not_portable only if every file in it is; the tests lane is splitting them, and L226 should
refuse a not_portable directory entry holding a file without a static-error marker.

(A41E7, low) test/dart_tests.toml's reason for tests/web/wasm/source_map_unminification_test.dart, "a dart2wasm option
(--minify); WT does not minify names", is false since 8f63b00c: Namer's minified path and TranslatorOptions.minify (on
from optimization level 2, translator.dart:81) are ported (src/namer.jl:32, src/translator.jl). The test is a behavior
entry. Requirements: D3 (A41S2, A41S3); D5 (A41E4); D17 and D18 (A41E3); D19 (A41E5); D21 (A41E2); no lock fired inside
its band.

Recorded after landing, from this audit's three read-only sub-audits (their reports reached the lead and this
log at 10:59, each finding resting on the command its report quotes) and the lead's rulings of 2026-10-28. Skeleton
(44eade5c, 07aa7542; owner wt3-skeleton, which owns dev/skeleton.jl): (A41S5, high) dev/skeleton.jl's `declaring()`
resolved an unprefixed name without dart's imports, so 29 stub parameters took WasmBuilder's Block, Expression, Throw,
Rethrow and FunctionType where dart means Kernel's (`sed -n '768p' code_generator.dart`: `void visitBlock(Block node)`;
src/code_generator.jl:186 `node::WasmBuilder.Block`), the orchestrator's H1, fixed by 1fabf0c0; (A41S6, medium) a Kernel
type has no Julia counterpart, its parameters left untyped (`_create_struct_for_class(…, class_ids::Dict{Any,Int64}, cls;
…)` for dart's `Map<Class, int>`), the table entry 43 files as A43S2, its rows the lead's to rule; (A41S7, medium) no gate
runs `skeleton.jl diff` or `check` (`grep -rln skeleton dev/*.sh test/*.jl .github` lists dev/src_progress.sh alone);
(A41S8, medium) the out-of-scope deserializer and printer keep 294 `_deserialize` and 101 print stubs, counted in the
total and unportable with types; (A41S9, medium) nothing checks a ported struct keeps every dart field (serializer.dart:26's
`_traces` is absent from serializer.jl:6–12); (A41S10, medium) CompilationTask, Table and _WithMutability, concrete dart
classes others extend, are Julia abstract types, so `CompilationTask(function, codegen)` (functions.dart:228) has no
concrete type to return; (A41S11, low) every optional named parameter defaults to `nothing` whatever dart's default
(global.dart:35 `includeInitializer = true`); (A41S12, low) seven in-scope typedefs carry no anchor; (A41S13, low)
`generated()` claims any one-line abstract type, @enum or @closed const as its own, so a deliberate edit of that form is
regenerated; (A41S14, low) `snake` is written twice (skeleton.jl:586, parity.jl:657), and serializer.jl:126 hand-writes
an anchor naming no symbol at the pin; (A41S15, low, unverified) an unported struct has no fields, so Julia makes it a
singleton whose `T.instance` exists without the rejecting constructor. Its all-anchors read found every one of 3,897
anchors declaring its symbol at the pin. Translator (owner wt3-translator): dart's sort of the root's children
(class_info.dart:910–944) is dropped by the lead's ruling, no masquerades occurring, and the code cites it
(src/class_info.jl:589); the Translator's loose-NirBody constructor is A41S2; (A41S16, medium) its subtype-range test
skipped f_int32, the program that brings the kinds, A41S3's case; (A41S17, low) `module_name_to_id` parses with
`base = 10`, where dart's `int.tryParse` without a radix also reads `0x` (int.dart:435–437):
`julia -e 'println((tryparse(Int64, "0x10"; base=10), tryparse(Int64, "0x10")))'` gives (nothing, 16); (A41S18, low)
ClassIdNumbering's `translator::KernelNodes` carries no precedent for its abstract type; the `class_id_numbering` field
with no writer is written by 8c659360's collect (src/class_info.jl:434). Tests (owner wt3-tests): its 25-file sample of
the five largest not_portable directories found 3 mis-labelled and 3 borderline, and L226's own negative plants a
not_portable directory as a fault-free map (test/parity_ratchet.jl:1245, 1257), A41E6's evidence; (A41E8, medium) thin
ports: double_literal_coercion checks 6 of dart's 117 `expectDouble`s, dropping 2^63, 2^64 and maxValue though its `what`
says powers of two included; source_map_simple checks only that an error is caught, large_const_set one member and the
length; (A41E9, low) bool_bool's `% 10^5` drops its `tf() && tf()` digits.

Landing times: not measured since b3adca48, dev/ship.sh writing no landing log (A41E3); before it, 82ce1cf5 to 6fd28817
landed through dev/land.sh as entry 40's landings did.

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A41E2 and A41E4 are fixed by 4bf77429
(L148 checks the log's shape and reports the lag; the old landing path deleted), past this range, to be read in entry 42.
A41S1 is open on MARCH 1.A4. A41S2 and A41S3 are open on MARCH 1.C. A41S4, A41E1 and A41E3 are open on MARCH 1.L.
A41E6 and A41E7 are open on MARCH 1.T. A41E5 is resolved by the lead's ruling of 2026-10-28: Dale's "can you build aggressively now"
retired the landing machinery with dev/.block/charter_authorised, and a charter change is now authorised in its commit's
`Charter-change:` trailer naming Dale's words, which the audit reads. A41S5 is fixed by 1fabf0c0; A41S6 to A41S15 are
wt3-skeleton's, A41S16 to A41S18 wt3-translator's, A41E8 and A41E9 wt3-tests'.

## 2026-10-28 — audited through 1fabf0c0 (8f63b00c..1fabf0c0: CompilationQueue, RecordShape, L154's entry commit, the old landing path deleted, ClassInfo and its collector, wasm_builder's IR and sections, translateType, entry 41, a Translator only from a ClosedWorld, the skeleton's imports)

The forty-second audit, beside the work, covers 27fe9c7c (CompilationQueue, drainCompletionQueue, isStandalone,
writeULEB128), b0c6d789 (RecordShape), 6e96d768 (L154 reads the fixes after the commit adding the latest entry's heading),
4bf77429 (the old landing path deleted; L148 the log's shape with the lag reported; C0 and C10 rewritten;
`Charter-change: C0 C10 authorised by Dale 2026-10-28`), 8c659360 (ClassInfo, ClassInfoCollector, collect; ClassField),
e0b7e226 (src/wasm_builder/ir/ and serialize/sections.jl ported in place of their stubs), 5f974c99 (translateType,
translateStorageType, translateReturnType, the builtin types), 6a52b2cf (their tests), 629d8c39 (entry 41; its author's),
653fbfc1 (a Translator only from a ClosedWorld; implemented types by Julia's `<:`) and 1fabf0c0 (the skeleton resolves a
type name through its file's imports). No wrong answer: WasmTarget compiles nothing yet. Every finding rests on one exact
command, quoted. Entry 41 missed one defect in its own range, the orchestrator's H1: 07aa7542 typed 29 stub parameters
with WasmBuilder's Block, Expression, Throw, Rethrow and FunctionType where dart means Kernel's, fixed at its source by
1fabf0c0. Findings A42S1 to A42S5 and A42E1.

Area: builder — e0b7e226: each IR class's struct has its one inner constructor; dart's abstract members reject as
Internal on the abstract type; `late final` fields are Late cells. Its goldens come from outside the code under test,
`wasm-tools parse` 1.244.0's bytes for each instruction's text (test/wasm_builder/ir_modules.jl:1–6). It departs from
dart at one place, measured against the format: dart writes a multi-memory memarg's offset before its memory index
(`sed -n 1593,1601p pkg/wasm_builder/lib/src/ir/instruction.dart`: `s.writeByte(64 + align); s.writeUnsigned(offset);
s.writeUnsigned(memory.index);`), where the multi-memory binary format reads the index first; the port writes the index
first, a dart defect fixed at the source with a case (D12), not a drift. (A42S4, low) `const Indexable__global_id =
Ref{Int}(0)` (src/wasm_builder/ir/indexable.jl) ports dart's `static int _globalId` as process-global state: every part's
debugging `name` counts the parts built before it in the session, so two compiles of one program name their parts apart,
and a value a precompile workload leaves in the Ref is saved in the package image. The name reaches no emitted section
(sections.dart reads `functionName`, `grep -n '\.name\b' serialize/sections.dart` gives only line 886's defType.name),
so it is low; the counter belongs to the ModuleBuilder, the one owner of a compile's parts. (A42S5, low) Serializer.write
takes `Union{Serializable, IR.ElementSegment, IR.DataSegment, IR.DefinedFunction, …, IR.Module}`
(src/wasm_builder/serialize/serializer.jl:118): Julia's one supertype cannot also place dart's interface implementors under
Serializable, so the interface is a hand list at one method, and an implementor left out fails as a MethodError at the
call, not a located rejection where it is declared; the list matches `grep -rn 'implements Serializable\|implements
Import' pkg/wasm_builder/lib/src` today.

Area: collection and planning — 8c659360, 653fbfc1, b0c6d789, 27fe9c7c. 653fbfc1 fixes A41S2: Translator's one inner
constructor is `Translator(::Val{:_}, world::ClosedWorld, options)` (src/translator.jl:129), the component read from the
ClosedWorld. Its implemented types are Julia's `<:` off the supertype chain for a concrete class
(`class_implemented_types`, src/julia/classes.jl), so `Tuple{Int64}` implements `Tuple{Any}` and the ranges follow
Julia's subtyping for the covariant Tuples, where 95447a02 rejected them. A41S3 stands: `DataType <: Type{Int}` is false,
so no class implements Type{Int} while the value Int is a member. Masquerades: `_compute_masquerades` is empty because
`typeof` is a value's own class; sound. CompilationQueue keeps dart's last-in, first-out `removeLast`, an empty pop a
located Internal rejection; sound.

(A42S2, medium) A field Julia may leave undefined gets a non-nullable wasm field. dart's typeOfField asserts its field is
not `late` (`sed -n 2087,2090p translator.dart`: `assert(!node.isLate);`), its late fields lowered to nullable storage
before; the port drops the assertion, `type_of_field(self, node::ClassField)::Type = node.type` (src/translator.jl:467),
and _generate_fields stores `translate_type_of_field` as the field's type. Julia's compiler answers which fields may be
undefined: `julia --startup-file=no -e 'mutable struct M; a::Vector{Int}; b::Int; M() = new(); M(a) = new(a); end;
println(Base.Compiler.datatype_min_ninitialized(M))'` gives 0, and `isdefined(M(), :a)` is false, yet M's field `a` would
be a non-nullable reference, which wasm cannot leave unset. When `new` with fewer arguments is emitted, the choice is a
default value or a rejection; D3 asks for Julia's answer at the field: a reference field past
datatype_min_ninitialized(T) is nullable, read with Julia's UndefRefError check, or the field rejects, located, until it
is.

(A42S3, medium) RecordShape takes dart's records, whose named fields form a sorted set, where Julia's named tuples are
ordered. `julia --startup-file=no -e 'println((typeof((b=1,a=2)) == typeof((a=2,b=1)), (b=1,a=2) == (a=2,b=1),
fieldnames(typeof((b=1,a=2)))))'` gives "(false, false, (:b, :a))". The port sorts the names
(`sort!(collect(index); by = first)`, src/records.jl) and test/records.jl:15–16 expects shapes "equal by positionals and
names, whatever the names' given order; hashed alike", dart's answer as the expected value. When fromType maps
NamedTuple{(:b,:a)} and NamedTuple{(:a,:b)}, they would share one shape, one record class and one field order, two Julia
types made one. The shape of a NamedTuple keeps Julia's field order, and the test expects what Julia says.

Area: emission and diagnostics — 5f974c99's translateStorageType: Union{} and Nothing are the nullable none reference,
Any the top type, a Union with Nothing nullable over `Base.nonnothingtype`, other Unions `typejoin`'s class, a type as a
value its kind, and a UnionAll, an open Type{T} and a primitive class with no wasm type reject, located; the structure is
dart's (`sed -n 1067,1140p translator.dart`), the DartType reads replaced at named points. (A42S1, medium) The packed
integers carry dart's representation without dart's reason. dart's translateType: "We represent the packed i8/i16 types
as zero-extended i32 type. Dart code can currently only obtain them via loading from packed arrays and only use them for
storing into packed arrays (there are no conversion or other operations on WasmI8/WasmI16)" (`sed -n 1048,1051p
translator.dart`). The port keeps the first sentence (src/translator.jl, translate_type) and maps Julia's Int8, UInt8,
Int16 and UInt16 to i8 and i16 (builtin_types), integers Julia computes with, compares signed and converts. Julia's answer
for a small integer held in a wider register is its ABI's: `julia --startup-file=no -e 'using InteractiveUtils; f(x)=x;
code_llvm(stdout, f, (Int8,); debuginfo=:none); code_llvm(stdout, f, (UInt8,); debuginfo=:none)' | grep define` gives
`define i8 @julia_f_129(i8 signext %"x::Int8")` and `define i8 @julia_f_131(i8 zeroext %"x::UInt8")`: Int8 sign-extended,
UInt8 zero-extended. A zero-extended Int8(-1) is 255 in its i32, so a signed compare or a widening that trusts the i32
answers wrong unless every signed operation re-extends; the representation needs Julia's answer (signext for the signed
classes, zeroext for the unsigned), stated with its precedent and checked where a value is read from a packed field
(struct.get_s for Int8 and Int16, struct.get_u for UInt8 and UInt16). One smaller point: the nullable primitive path
reads `self.class_info[cls]`, a KeyError when the box was never collected, where the class path beside it rejects
`the class … has no class info`, located.

stopgap in disguise: the ClosedWorld typestate now reaches the Translator by construction (653fbfc1); the Serializable
interface is a hand list at one method (A42S5); RecordShape's sorted names and the packed integers' zero extension are
dart's semantics passing for Julia's (A42S3, A42S1).
precedent: the Translator's tagged constructor, Rust's private-field construction; implemented types, dart's
implementedTypes answered by Julia's `<:`; the memarg order, the multi-memory binary format and wasm-tools, its alarm.

Area: enforcement and prose — every hunk of 4bf77429 (.github/workflows, .gitignore, AGENTS.md, dev/, test/), 6e96d768
and 653fbfc1's and 1fabf0c0's test and dev hunks. 4bf77429 fixes A41E2 (L148 checks the chain, the four areas and the
Resolution and reports the lag, its own negative) and A41E4 (dev/land.sh, land_queue.sh, block.jl, the runner and
L194, L195, L197 and L198 deleted). 6e96d768 is sound: `git log -1 -S<heading> -- dev/AUDIT.md` finds the commit that
added the entry's heading, so a later header edit hides no Fixes: line, and its scratch-repository case reaches it.
(A42E1, medium) 4bf77429 rewrites C10 and drops its numbers with nothing to check them: the old text's "a 60-s target, red
only past twice it" and L197's "a 300-s target for every change red only past 600 s" leave the charter (`git show
4bf77429 -- dev/CHARTER.md`), while dev/LEDGER.md's D13 and D14 still state those bands and cite dev/ship.sh and
dev/check.sh, which judge no time (A41E3). The change is a weakening of C10 under `Charter-change: C0 C10 authorised by
Dale 2026-10-28`, and no program can confirm the line: `grep -c 2026-10-28 dev/.block/charter_authorised` in the main
tree gives 0, and since 4bf77429 no file in the tree reads that record (A41E5). Requirements: D3 (A42S1, A42S2, A42S3);
D9 (A42S5, the KeyError); D17 and D19 (A42E1); no lock fired inside its band.

Landing times: not measured; dev/ship.sh writes no landing log (A41E3). Entry 41 landed in 37.5 s of `bash dev/ship.sh`
wall, its check 35 s.

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A41S2 is fixed by 653fbfc1, and A41E2
and A41E4 by 4bf77429. A42S1, A42S2 and A42S3 are open on MARCH 1.C. A42S4 and A42S5 are open on MARCH 1.B. A42E1 is
resolved by 8bbf527d, which restores both bands in C10 and judges them (the lead's ruling: retiring the machinery
was Dale's approval, dropping his numbers went beyond it).

## 2026-10-28 — audited through 11688e8b (1fabf0c0..11688e8b: the typejoin ruling, dev/gate.sh pushing nothing, the check's exit status and bands, check slots, entry 42, translateStatement)

The forty-third audit, beside the work, covers e2fe09d7 (translateStorageType's ruling: a Union's typejoin its
representation only, values exact), 114b30a4 (dev/gate.sh pushes nothing, gate-fast.yml and L163 deleted, the workflows
on wt2 alone; `Charter-change: C10 authorised by Dale 2026-10-28`), 8bbf527d (dev/check.sh's exit status decides, dev/ship.sh
checks every commit with `git rebase --exec`, TLC on touched models, D13's and D14's bands; C10 restates them), de199a9e (at
most three checks at once, one Julia thread each), 60a55268 (entry 42; its author's) and 11688e8b (translateStatement, an
@exhaustive arm per NIR form). No wrong answer: WasmTarget compiles nothing yet. Every finding rests on one exact command,
quoted. A41E1 is fixed by 8bbf527d, and A41E3 by 8bbf527d for D14 and for checking every commit. Findings A43S1 to A43S4
and A43E1 to A43E4.

Area: builder — empty by diff: no commit of the range changes src/wasm_builder/.

Area: collection and planning — e2fe09d7 is a docstring and its cases: a value of a Union keeps its exact class, the
join is its representation only, `nothing` the null of the nullable one; test/translator.jl checks, by native runs, that
each box is a wasm subtype of the join's struct and not of the other's. Sound as a ruling. (A43S1, low) Its precedent names
a case other than the one it rules. "julia: codegen boxes a value of a non-isbits Union behind jl_value_t" governs
Union{Int64,Float64} in its own test, an isbits Union, which Julia's codegen holds unboxed with a selector byte:
`julia --startup-file=no -e 'println(Base.isbitsunion(Union{Int64,Float64}))'` gives true. Boxing is a sound choice,
but the precedent for it is dart's (an upper bound's struct), and the ruling should say that Julia's own representation
of an isbits Union differs (D7). Its "a value or local of an 8- or 16-bit integer or a Bool is i32 … as dart's are"
leaves A42S1 open: dart's WasmI8 and WasmI16 are never values with operations (translator.dart:1048–1051), and the
extension of a signed one is not stated.

(A43S2, medium) No table maps Kernel's types to their Julia answers, and no plan row asks for one, so the answers are
made one port at a time. 1fabf0c0 leaves a Kernel-typed stub parameter untyped "until the Kernel table types it", and
`grep -n -i 'kernel table\|kernel_table' dev/skeleton.jl src/julia/*.jl dev/MARCH.md` finds nothing. Today, Class is
DataType (classes.jl), Field is ClassField, Component is `Vector{NirBody}`, and Statement is NirStmt with a `used` flag
(A43S3), each chosen where it was first needed. WT2-DESIGN gives the whole mapping in one line, "typed IR, not Kernel …
NIR is its closed-sum projection". That is how 1:1 becomes nominal: every port that reads a Kernel node decides again
what the node is in Julia (D5: one fact at its one source; D26: map Julia's IR before writing). The fix is one quarantined
table, src/julia/kernel.jl, listing each Kernel class a pinned file reads, with its Julia counterpart and the Julia API
that answers it. dev/skeleton.jl types the stubs from that table, and a MARCH row plans the classes the table lacks.

Area: emission and diagnostics — 11688e8b's translate_statement. Each Julia-only form rejects in its own arm and names
its MARCH row, and no arm is a wildcard (@exhaustive over NirStmt; construction.jl now accepts an imported sum, checked
at its declaring module by `Base.binding_module`). Sound as a construction. (A43S3, medium) The anchor names a dart
function whose body this is not. dart's translateStatement (`sed -n 714,724p code_generator.dart`) is ten lines: set the
source-map offset, `node.accept(this)`, print the node's location if it throws, restore the offset. The port under that
anchor holds a different decision, the projection of a flat SSA statement onto Kernel's statement classes: a used
value is a VariableDeclaration, an unused one an ExpressionStatement, and twenty Julia-only forms each reject. That
projection is forced by Julia (Kernel nests a used expression in its parent; Julia's IR names it by SSA), so it belongs
in a @quarantine definition beside NIR, `accept`'s counterpart. translateStatement then keeps dart's ten lines, and its
anchor names what its body does (D1, D7). (A43S4, medium) A rejection names the dart anchor and the plan row, not the
statement of the user's program. `reject!(r, at) = throw(RejectionError(r, at))` (src/julia/reject.jl:79), and here
`at` is "dart2wasm/lib/code_generator.dart:714 AstCodeGenerator.translateStatement". dart's own catch prints
"Exception in ${node.runtimeType} at ${node.location}" (code_generator.dart:728), and the port drops it. C6 asks
for a located rejection. A rejection from a NIR statement should name its function (the CodeInstance's MethodInstance)
and its statement index and line from the body's line table, as Julia's own errors do. This comes before the
JuliaLowering provenance the plan defers.

stopgap in disguise: the @exhaustive match is a construction; the check slots are a mutex by mkdir, a mechanism, not a
claimed construction; D13's band is a printed line (A43E1).
precedent: the slots, a counting semaphore by atomic mkdir (make's jobserver bounds jobs the same way); every commit
checked, bors's not-rocket-science rule; the typejoin box, dart's upper-bound struct.

Area: enforcement and prose — every hunk of 114b30a4 (dev/gate.sh, the workflows, dev/CHARTER.md, test/parity_ratchet.jl,
test/smoke.jl, test/smoke_times.tsv, dev/parity_baseline.toml), 8bbf527d, de199a9e and 11688e8b's test hunks. 8bbf527d is
sound on A41E1: `julia … test/parity_ratchet.jl …; rc=$?` and `[ $rc -ne 0 ]` decide (dev/check.sh). `git rebase --exec`
runs its command on a branch already on top of its upstream, measured on a scratch repository (`git rebase -q up --exec
'echo EXEC-RAN …'` printed "EXEC-RAN on mine", git 2.52.0), so a one-commit landing is checked too. 114b30a4 is sound:
`grep -c 'git push' dev/gate.sh` gives 0. (A43E1, low) D13's band is printed, never judged: ship.sh echoes "ship: RED — the
median of the last five landings is …s, past D13's band" after its push and exits 0 (dev/ship.sh), so a red median
changes nothing. The 600-s edge needs a consequence: the next ship refuses until a landing under the band, or the
orchestrator is told, as L197 failed the next gate. (A43E2, medium) A41E5 is named in 8bbf527d's subject but not fixed:
`grep -n charter dev/check.sh dev/ship.sh` gives only check.sh:33, the ratchet's `── charter` marker. In the range,
two commits change dev/CHARTER.md under lines no program reads. 114b30a4's `authorised by Dale 2026-10-28` has no line of
that date in the main tree's dev/.block/charter_authorised (`grep -c 2026-10-28` gives 0). 8bbf527d's is a
self-certification, "no requirement loosened", and it adds TLC on touched models to C10, new charter content (D19:
propose charter edits only). (A43E3, low) D14's band has no machine calibration. My first ship of entry 42 went red on
time alone, "check: RED — 125s, past D14's band", src tests 1m27.7s, with `uptime` load averages 63.11 34.63 18.98 on 10
cores. The retry on the same content passed in 76 s. de199a9e bounds the checks to three at a time, one thread each, and
times the check without its wait, but `uptime` at 11:00 still read 46.64 44.59 32.01 (D31). A check red on a loaded
machine fails a sound landing, which the retired gate marked unjudged (D17). (A43E4, low) A check slot can stay held
forever: dev/check.sh makes the slot with `mkdir` and writes its pid on the next line, and a holder that dies between the
two leaves an empty pid, which `[ -n "$holder" ] && ! kill -0 …` never frees. Write the pid first, into a temporary directory renamed into the slot. Requirements: D1 and D7 (A43S3, A43S1); D5 and D26 (A43S2); C6 (A43S4); D13 (A43E1); D19
(A43E2); D17 and D31 (A43E3); no lock fired inside its band.

Landing times: dev/ship.sh now logs them in the common dir's wt-landings.tsv; entry 42 landed 462 s from its first commit,
the median of five 244 s (ship's own line).

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A41E1 is fixed by 8bbf527d; A41E3 by
8bbf527d for D14 and every commit checked, its D13 half carried as A43E1. A43S1, A43S2, A43S3 and A43S4 are open on MARCH
1.C. A43E1 and A43E4 are open on MARCH 1.L. A43E2 is resolved by
the lead's ruling (A41E5): 114b30a4's trailer and body name Dale's words of 2026-10-28, and 8bbf527d's restores his
bands of 2026-10-21 and adds TLC under D11. A43E3 is resolved by fbb5e5da, past this range: over 120 s with the
one-minute load above the core count, the band is unjudged, the time and load printed, never a scaled pass. A43S2
is A41S6, owned by wt3-skeleton.

## 2026-10-28 — audited through f93c38b2 (11688e8b..f93c38b2: the load-aware band, the skeleton's definition-level scope, the kinds' layout, L227, the type checkers, the straight-line code generator and intrinsics, the builders, closures, the registry's identities, field reads and allocation, per-module part ids)

The forty-fourth audit, beside the work, covers fbb5e5da (D14's band unjudged past the core count), e30ac311 (the
runtime blob's templates, minified class names, JS string helpers), 215a8e6e (the skeleton scoped by definition:
modules.dart's monolithic path in, the deserializer and printer members out), bdccee5c (the Translator's fields for the
other lanes; the kinds' fields), 4272a9f2 (L227, a removed test named by `Removes-test:`), 111ec9c5 (types.dart's
helpers, the is and as checkers), 0e569d58 (the straight-line code generator over the NIR; the operator maps), cedcd905
(a range query for Type{X} rejects; Fixes: A41S3), fabc7847 (globals and table-based globals), 1340d586 (entry 43; its
author's), 2ff69bf8 (src/wasm_builder/builder/ ported, every emission checked), edea306b, 6a0dde5c and 30161ad2
(closures: representations, Lambda, Context, Capture, ClosureLayouter), 8c65e07c (dispatch_table's row displacement),
f87d39e7 (`===`, ifelse, conversions, shifts), ade5d64b (a re-evaluated definition replaces its registry entry), af883790
(entries 41 to 43 record the sub-audits and rulings; its author's), cf92e5d3 (getfield and Expr(:new)) and f93c38b2
(each module numbers its parts; Serializer.write's implementors checked at load). No wrong answer measured: the code
generator emits only straight-line code and no program has run on wasm against native. Every finding rests on one exact
command, quoted. The lead's rulings since entry 43: A43E1 is by design (D13's band judges the loop, so a RED printed after
the push is a finding about the slowest step, not a refused landing); the charter changes of 4bf77429 and 114b30a4 are
authorised by Dale's approval of the restart plan ("can you build aggressively now", reported to him); the Kernel
table, src/julia/kernel.jl, is approved and owned by wt3-skeleton (A43S2, A41S6). Findings A44S1, A44S2 and A44E1.

Area: builder — 2ff69bf8: each instruction builder runs dart's checks (`_verify_types`, `_verify_branch_types`,
`_verify_cast`, src/wasm_builder/builder/instructions.jl:508–543, 1331) on every emission, where dart runs them inside
asserts; a misuse rejects as InvalidModule at the emitting call (D10), and its three modules' bytes are `wasm-tools
parse`'s for the text beside them. f93c38b2 fixes A42S4 (the part counter is IR.Module's `_global_id`) and A42S5
(src/julia/serializable.jl reads each struct with a serialize method back to its dart class at the pin and refuses the
load when Serializer.write does not take one that reaches Serializable). Sound. The builder sub-audit's report is
pending and joins entry 45.

Area: collection and planning — 215a8e6e fixes A41S1 and A41S8: dev/skeleton_scope.toml's `[out_definitions]` and
`[out_types]` scope by definition, modules.dart joins the pin table with its 23 monolithic-path definitions, and 401
deserializer and printer stubs go. cedcd905 fixes A41S3: `get_concrete_class_id_range` rejects, located, for a Type{X}
whose member's class typeof(X) is not under it. ade5d64b keys a registry entry by its module and its signature without
line numbers, so a Revise re-evaluation replaces its entry; sound, its case re-evaluates compile's and check_subset's
definitions. 111ec9c5's helpers take Julia's answers (`Base.has_free_typevars`, `typeof(T)`, `Nothing <: T`), and its test
checks `isa(x, T) == typeof(x) <: T` over values of every kind for each type the checkers serve. 6a0dde5c's
`_findCaptures` is Julia's lowering, which has already made each nested function a closure struct of its captures, a
Core.Box where assigned; sound, D3. (A44S1, low) A type as a value takes dart's runtime-type layout
(`_kind_instance_fields`, src/julia/classes.jl): a DataType holds `isDeclaredNullable` and `classId`, both
`ClassField(c, 0, …)`, so a Julia program reading a type's own fields (`T.name`, `T.parameters`, `T.super`) finds no
field, and cf92e5d3's visit_instance_get answers `reject!(Internal("$at: $cls has no field $key"), …)`, the kind for a
compiler bug, where the program is valid Julia outside the representation: Unquarantined, naming the kind's layout, is
the located answer (C6).

stopgap in disguise: the instruction checks are constructions at the emitting call; the Serializer.write list is now a
list checked against dart at load (A42S5's fix, a check, not a construction, named so in its commit); L227 is a check over
a diff, as block.jl's was.
precedent: the type checkers, dart's class-id range checks (types.dart) answered by Julia's `<:`; the registry identity,
Julia's method table keying a method by its signature; union-find, vm's UnionFind (union by weight, path compression).

Area: emission and diagnostics — 0e569d58, f87d39e7 and cf92e5d3. The operator maps key Julia's IntrinsicFunction (D4)
and give each intrinsic the instruction Julia's codegen answers with: wrapping integer arithmetic; shifts that saturate
as Julia's do (the count unsigned; a count of the width or more gives 0, or the sign for ashr_int, a select over wasm's
modular shift; read in generate_static_intrinsic); `===` on floats compares bits. An operand narrower than its wasm type
has no arm except Bool under and, or, xor and equality, so `!x` on a Bool (not_int, an all-ones xor) cannot be emitted
over its 0 or 1. cf92e5d3 reads a packed field with struct.get_s for a Signed type and struct.get_u otherwise, and an
allocation leaving fields undefined rejects, located: together these answer A42S1 for reads and A42S2 for allocations,
both as rejections until narrow arithmetic and undefined fields are written. Rejections now carry
`self.enclosing_member` (37 sites in src/code_generator.jl), the MethodInstance, which answers A43S4 in part; the
statement index and line are still absent. (A44S2, low) Float `===` compares bits, and a NaN's bits are not a property of
the program: wasm gives an arithmetic NaN a nondeterministic payload and sign, and the host's own NaN differs by
architecture. Here, `julia --startup-file=no -e 'z = Base.inferencebarrier(0.0); x = z/z; println((x === NaN,
bitstring(x)[1:12], Sys.ARCH))'` gives "(true, 011111111111, aarch64)", where x86's 0/0 sets the sign bit and the same
program answers false natively. A differential case comparing a computed NaN with `===` passes or fails by host; the
corpus should hold such a case with its host named, never as a general expectation.

Area: enforcement and prose — every hunk of fbb5e5da, 4272a9f2, af883790 and the test hunks of the range. fbb5e5da
answers A43E3 as ruled: past 120 s with the one-minute load above `hw.ncpu`, the band prints UNJUDGED with the time and
the load, never a scaled pass. 4272a9f2 restores block.jl's Removes-test rule as L227 over the change from CHECK_BASE's
merge base, its negative the seven planted messages and a scratch repository. (A44E1, low) fbb5e5da reads the load as
`sysctl -n vm.loadavg | awk '{ print int($2) }'` and the cores as `sysctl -n hw.ncpu`, both macOS-only; on CI or Linux
both fall back (`load` empty, read as 0; cores 1), so a slow Linux run is always judged, and a dev/check.sh run there
under load reds where the same run here is unjudged: `/proc/loadavg` and `nproc` are the other host's answers.
Requirements: C6 (A44S1); D2 and D3 (A44S2); D17 (A44E1); no lock fired inside its band.

Landing times: dev/ship.sh's log; entry 43's landing took 804 s and af883790 888 s from first commit to landed, each
losing races to other lanes' landings (the lead's d246bb34, a landing lock with the check outside it, is landing).

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A41S1, A41S8 are fixed by 215a8e6e;
A41S3 by cedcd905; A42S4 and A42S5 by f93c38b2; A43E3 by fbb5e5da; A43E1 is ruled by design. A44S1 and A44S2 are open on
MARCH 1.C. A44E1 is open on MARCH 1.L.

## 2026-10-28 — audited through cf5f6a0c (f93c38b2..cf5f6a0c: constants, one main module, the target, the landing lock, stubs with no value, tuple shapes, four check slots, entry 44, every builder check refusing, type constants, RuntimeTypeInformation, D42 and the llvm pin, NirWorld, landing from a scratch worktree)

The forty-fifth audit, beside the work, covers d26fb815 (constants.dart's definitions, ConstantInfo, the instantiator
and creator; src/julia/constant.jl), bfcaceee (modules.dart's monolithic path, WasmCompilerOptions, the Translator's
module data), 49f5c043 (target.dart, MemoryLimits), 143876a4 (dev/ship.sh checks outside a landing lock and lands under
it; the `Charter-change: … — Dale <date>: "<words>"` rule; stale slots freed), 22fd99e6 (an @unported struct holds one
`Union{}` field, so it has no value), b369cfab (RecordShape.fromType over Tuple and NamedTuple types; no class per
shape), 3b07fee9 (four check slots and the holder's; the load read on Linux), ebf9678a (`dev/lanes.sh --fast`
deleted), 0b81c2ac (entry 44; its author's), ab6d985e (a type value lowers to its kind's instance), 20897b5e (one
refusal case per builder check), 34dbefff (RuntimeTypeInformation), 150c3dae (ledger D42; the llvm pin and
dev/fetch_llvm.sh), a6e83015 (the code generator's translator helpers, ParameterInfo), 53333011 (NirWorld, a typestate
only build_nir makes from a ClosedWorld) and cf5f6a0c (dev/ship.sh lands from a scratch worktree of the lane's HEAD). It
also records the builder sub-audit's report on entry 44's 2ff69bf8, 8c65e07c, fabc7847 and e30ac311, each finding
resting on the command its report quotes, the highest one re-measured here. No wrong answer measured: no program has
run on wasm against native. Findings A45S1 to A45S5 and A45E1.

Area: builder — 20897b5e: one case per InstructionsBuilder check and per module-part check, each asserting the
InvalidModule rejection and its text beside the valid sequence the same check accepts, and four of dart's RangeErrors
the port hit as BoundsErrors now refused, located; sound, D10. The sub-audit counted the emitting builders of 2ff69bf8:
307 of 309 run a check, dart's 306 of 309. (A45S1, low) `throw_ref` (src/wasm_builder/builder/instructions.jl:724–728,
`_add(b, IR.ThrowRef()); b._reachable = false`) pops no exnref and checks nothing, as dart's instructions.dart:836–839;
D10 asks the builder to refuse invalid wasm at the emitting line, so dart's gap is a defect to fix at its source with a
case, as the memarg order was, not to carry. The goldens of test/wasm_builder/builder_modules.jl are wasm-tools' bytes,
with broad_module's data count section patched in by dart's serializer rule (sections.dart:663), as its comment says.

Area: collection and planning — 53333011 completes A41S2: NirWorld's one constructor takes nir.jl's token, build_nir
from a ClosedWorld is its maker, and ClosedWorld's construction check asserts both states (L220). 22fd99e6 fixes A41S15:
a stub struct's `_unported::Union{}` field leaves it no value and no singleton instance, its plant in L211. d26fb815's
constants are Julia values as Core.Const holds them, one @closed kind per form, canonicalized by egal; an 8- or 16-bit
integer constant is pushed by its value (Int8(-1) as -1, UInt8(255) as 255: constants.jl, "an 8- or 16-bit one by its
value"), which with cf92e5d3's struct.get_s and get_u gives the signed classes Julia's sign extension (A42S1, in
practice; translate_type's docstring still says zero-extended). (A45S2, medium) A42S3 stands after b369cfab: fromType
gives a NamedTuple's names their declared indices, but RecordShape sorts the pairs and `==` and `hash` compare names
only. Measured with this tree's depot, `julia --project=. -e 'using WasmTarget; R = WasmTarget.Dart2Wasm; a =
R.RecordShape_from_type(typeof((b=1,a=2))); b = R.RecordShape_from_type(typeof((a=2,b=1))); println((a == b, hash(a) ==
hash(b), R.get_name_index(a, "a"), R.get_name_index(b, "a")))'` prints "(true, true, 3, 2)": two shapes equal and
hashed alike whose field `a` sits at different indices, so a map keyed by shape gives one of the two types the other's
layout. The shape's equality must include each name's index (Julia's field order), and test/records.jl:15's "equal …
whatever the names' given order" go. (A45S3, medium) `check_forward` (src/julia/forward.jl:59, `elseif b isa DataType &&
b <: forward && b !== forward && b !== sole`), now guarding AbstractModuleBuilder and AbstractInstructionsBuilder as
well, is a scan of the package's bound names: a parametric `struct X{T} <: AbstractModuleBuilder` is bound to a UnionAll
and passes, as does a subtype defined in a module outside the package's tree. Julia answers the question whole: InteractiveUtils.subtypes(AbstractModuleBuilder) reads every loaded module's
types, UnionAll-bound ones included; better, the back-pointer's owner takes the builder as a type parameter, and no
forward declaration or check is needed (D6).

stopgap in disguise: NirWorld and the stub's `Union{}` field are constructions; check_forward is a scan (A45S3); the
Charter-change trailer rule is a stopgap, as 143876a4 says, its claim read here.
precedent: NirWorld, Rust's private-field construction; the empty field, Rust's `!` (the never type) as a field making a
struct uninhabited; the landing lock, bors's optimistic check then serialized merge.

Area: emission and diagnostics — the sub-audit's fabc7847 finding, re-measured. (A45S4, medium)
`_initialize_at_startup` answers the opposite of the dart it names: src/globals.jl:180, `… DartGlobals._initializeAtStartup"
_initialize_at_startup(self::DartGlobals, node::GlobalRef)::Bool = true`, its docstring "whose default is `true`: Julia
declares no pragmas, so every binding takes the default". dart's globals.dart:292–293 is `util.getPragma<bool>(…,
'wasm:initialize-at-startup', defaultValue: true) ?? false`, and getPragma returns `defaultValue` only when the pragma is
present with no value (`sed -n 47,48p util.dart`: `if (value == null || value is NullConstant) { return
defaultValue; }`) and `null` when it is absent (util.dart:64, `return null;`), so a field with no pragma answers false
and is initialized lazily; test/globals.jl:29 asserts the true. If eager initialization is Julia's answer (a top-level
binding's value is computed when its module loads, and juliac's image holds it), that is a departure to state with its
precedent; as written, the anchor claims dart's answer and gives its opposite. bfcaceee's (A45S5, low) `emit_codegen`
(src/compiler_options.jl:85) compares `phases[end]` with `CompilerPhase_tfa`, dart's own defect at compiler_options.dart:138
(`bool get emitCodegen => phases.last == CompilerPhase.tfa;`, beside emitTfa's identical line 137), copied without a
word, where 2ff69bf8's memarg order fixed dart's defect at its source; one rule for both: a dart defect is fixed with a
case and named (D12).

Area: enforcement and prose — every hunk of 143876a4, 3b07fee9, ebf9678a, cf5f6a0c, 150c3dae and the test hunks of the
range. 143876a4 answers the starvation entry 43 measured: the check runs first, outside any lock, and under the landing
lock a lane re-checks only when another landed meanwhile; a slot or the lock whose holder died before writing its pid is
freed after 10 minutes (A43E4). 3b07fee9 fixes A44E1: `{ sysctl -n vm.loadavg || cat /proc/loadavg; }` and `sysctl -n
hw.ncpu || nproc` (dev/check.sh:67–68). cf5f6a0c lands from `$common/wt-ship/<lane>`, a detached worktree of the lane's
HEAD, and rebases the lane's branch afterwards only if it is clean with HEAD unmoved; sound, and it removes the
lost-edits hazard. No commit of the range changes dev/CHARTER.md (`git log f93c38b2..cf5f6a0c -- dev/CHARTER.md` is
empty). D42's words are Dale's of 2026-10-28 as the ledger row quotes them, and its precedent, LLVM's WebAssembly
backend at a pinned commit, is the production compiler the words ask for. (A45E1, low) D42's checks column cites
`dev/fetch_llvm.sh`, a script that makes a checkout and enforces nothing (D18: each requirement with its check); its
check is L213's counterpart for anchors at the llvm pin, planned on 1.D, which the row should cite alone until it
exists. Requirements: D10 (A45S1); D3 (A45S2, A45S4); D6 (A45S3); D12 (A45S5); D18 (A45E1); no lock fired inside its
band.

Landing times: entry 44 landed 330 s from its first commit; ship printed the median of five at 636 s, past D13's band,
before 143876a4 and cf5f6a0c landed (the lead reports 246 s since).

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A41S2 is completed by 53333011, A41S15
fixed by 22fd99e6, A43E4 by 143876a4 and A44E1 by 3b07fee9. A45S1 is open on MARCH 1.B. A45S2, A45S4 and A45S5 are open
on MARCH 1.C. A45S3 is open on MARCH 1.S. A45E1 is open on MARCH 1.R.

## 2026-10-28 — audited through 95dd5b6e (cf5f6a0c..95dd5b6e: closure representations, field writes and Symbols, constants as NIR literals, the dart test map split by file, entry 45, the Kernel table, the first compile, side-by-side checks, entry spans)

The forty-sixth audit, beside the work, covers b4cb4ab2 (ClosureLayouter._createRepresentation), dc70c410 (SRC_TESTS one
per line), 297a8133 (setfield! as InstanceSet; symbols.dart over Julia's Symbol), e87188cb (a constant is the NIR's
NirConst), 42eba74e (an instance constant's type; the instantiation function), c5364b6c and 202d90e4 (nine tests/language
directories split by file and ported), 9153798a (L226 refuses a not-portable directory outside dev/PARITY_MASTER.md's
scope exclusions and any hedged reason; the map counted by file; Fixes A41E6, A41E7 by its subject), 8480d9f2 (entry 45;
its author's), d153e4a1 (type literals as NirConst; two dropped stubs restored), a1c06047 (the runtime blob's finals as
Late cells), d1143fba (src/julia/kernel.jl, the Kernel table typing every stub), 79c5face (the first compile, f(x::Int32)
= x + Int32(1)), e5c72872 (the ratchet and the src tests side by side) and 95dd5b6e (an entry's last line read by Julia's
parser). The first module WT compiles answers as native Julia by the commit's word; no test runs it (A46E1). Every finding
rests on one exact command, quoted. The lead's standing item, the in-scope total: `julia dev/skeleton.jl count` on
8480d9f2 gives "in scope, in all 3498", the count 215a8e6e reported and d1143fba measured again; no commit of this range
changes dev/skeleton_scope.toml (`git log cf5f6a0c..95dd5b6e -- dev/skeleton_scope.toml` is empty), so the skeleton's
total did not move. The progress line's total moved from 3589 (entry 45's landing) to 3591 (the ratchet at 95dd5b6e:
"src: 2792 of 3591 anchored dart definitions ported"), the two stubs d153e4a1 restored (A46S2). Findings A46S1, A46S2
and A46E1.

Area: builder — empty by diff: no commit of the range changes src/wasm_builder/.

Area: collection and planning — d1143fba: KERNEL_TYPES holds 168 rows, `(library, name) => (Julia type, why)` (`git
show origin/wt2:src/julia/kernel.jl | grep -c ' => ("'`), 76 of them NoCounterpart, a struct whose one field is Union{}
so no stub taking one can be called; dev/skeleton.jl refuses a type with no row and a row no definition names. It answers
A43S2 and A41S6 for the stubs. (A46S1, medium) The table types stubs only, and the ported definitions answer the same
Kernel classes otherwise, so the one fact still has two sources (D5). The table's rows (src/julia/kernel.jl:152–154)
make Block, EmptyStatement and ExpressionStatement NoCounterpart, "Julia's IR is a flat statement list"; the filled code
takes `visit_block(self::AstCodeGenerator, node::NirBody)` (src/code_generator.jl:492), `visit_empty_statement(…,
node::NirNothing)` (:516) and `visit_expression_statement(…, node::NirStmt)` (:526), which translate_statement calls
(:441–446). And the table maps IfStatement to NirGotoIfNot and BreakStatement to NirGoto (:146, :148), a structured
statement to a flat jump, while WhileStatement, LabeledStatement and Block are NoCounterpart (:152–158): once the LLVM
stackifier (D42) gives the code generator structured regions, visitIfStatement's dart body (its then and otherwise
statements) has nothing to read in a jump. The table should be the type every Kernel-typed parameter takes, filled or
stubbed, read by the loader beside L214, and the structured statements one answer: the stackifier's regions or
NoCounterpart, not a jump for one and none for the rest. e87188cb and 42eba74e make a constant the NIR's literal, as the
table's `Constant => NirConst` row says; sound. b4cb4ab2's generic branch rejects as Internal at its top, a Julia function
taking no type arguments; sound.

stopgap in disguise: the Kernel table is a construction for stubs (a missing row refuses the generator, a NoCounterpart
stub cannot be called), a convention for the filled code (A46S1); L226's directory rule is a check over a map, its
exclusion list read from PARITY_MASTER's Scope section so it cannot drift.
precedent: NoCounterpart, Rust's `!` as the uninhabited parameter; the table, dart's own `import 'package:kernel/ast.dart'`
resolved once; a closure representation, dart's vtable and closure structs under their bases.

Area: emission and diagnostics — 297a8133's visit_instance_set writes a concretely inferred receiver's field by
struct.set, the value kept by a tee where used, and rejects a write Julia forbids (an immutable struct's field, a const
field) as Unquarantined, located; the field-not-found arm is Internal, as A44S1 says of reads. 79c5face's module is
`local.get, i32.const 1, i32.add, local.set, local.get, return`. (A46E1, medium) "a valid module that answers as native
Julia" rests on a run the test does not repeat: test/code_generator.jl compares the module's bytes with a golden (`@test
B.data(s) == UInt8[0x00, 0x61, 0x73, 0x6d, …]`) and checks native `f_add(typemax(Int32)) == typemin(Int32)`, and its
comment says node "answers as native Julia (1 42 0 -2147483648 -2147483647 for 0 41 -1 typemax typemin)"; no test
instantiates the module. The golden is the code's own output recorded, so the test detects a change and proves nothing
about wasm's answer; the charter's third oracle, native-vs-wasm differential execution, has its first case only in a
commit message. The runner the plan names (1.B: "the module is judged against native once the rebuild has its runner")
is due now that a module exists: node or wasmtime runs the bytes, each answer compared with native's in the test.

Area: enforcement and prose — every hunk of 9153798a, dc70c410, e5c72872, 95dd5b6e, c5364b6c's and 202d90e4's test
hunks. 9153798a fixes A41E6 and A41E7: the ratchet at 95dd5b6e prints "dart tests at the pin, by file: 4716 files in
1130 entries: behavior 590 ported, 3455 pending; structural 10 ported, 1 pending; 615 not portable; 45 helpers", every
not-portable directory names a PARITY_MASTER exclusion, and a hedged reason refuses. A sampled port reads true to its dart
test: dart_nnbd/late_chained_assignment (test/smoke_corpus.jl:4478–) writes `b = a = one`, `b = foo.x = 3one` and leaves
a field unset by `new()`, as nnbd/late/chained_assignment_test.dart's late field. 95dd5b6e is sound: Julia's parser gives
a definition's closing line, and its test holds that every entry's span parses as one statement. (A46S2, medium) The
in-scope total can shrink without a word: d153e4a1 restored Types.coreTypes (types.dart:119) and the _TypeCheckers
constructor (:615), which "types.jl's first port rewrote the file and lost", and nothing failed when they went: `git
show origin/wt2:dev/check.sh | grep -c skeleton` gives 0 and test/parity_ratchet.jl names no `skeleton.jl diff`, so the
generator's no-diff check (A41S7, MARCH 1.A6's exit, "a hand-edited stub fails") runs in no landing. And the total has two
sources: the skeleton's 3498 and the progress line's 3591 (unique anchors in the registry, which counts each enum value
and field a port anchors). The lead's denominator rule needs one total, the skeleton's, and the diff in every check, so a
lost definition fails the landing that loses it. Requirements: D5 (A46S1, A46S2); the third oracle (A46E1); no lock fired
inside its band.

Landing times: entry 45 landed 562 s from its first commit, the median of five 562 s (ship's line); e5c72872 runs the
check's two halves side by side to shorten the serial re-check.

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A41E6 and A41E7 are fixed by 9153798a;
A43S2 and A41S6 are answered for stubs by d1143fba, their filled half carried as A46S1. A46S1 is open on MARCH 1.A4.
A46S2 is open on MARCH 1.A6. A46E1 is open on MARCH 1.B.

## 2026-10-28 — audited through 360363ab (95dd5b6e..360363ab: the call path, ordered shapes, native answers by change, Bool's not and the bit counts, entry 46, Abstract<X>, kinds from Base, call targets, one lock check, the CFGStackify model, the closures' visitors, the collaborators, audit fixes, LLVM anchors, dart defaults, facts that name themselves, the spec's validation rules, translate end to end)

The forty-seventh audit, beside the work, covers de918a8c (FunctionCollector, the call path), a94bf136 (a shape is its
names with their indices), 9f47da82 (native answers proven only for the cases a change touches), b7c2ab9f (Bool's
not, flipsign_int, ctlz/cttz/ctpop, the fast-math floats), b465c22f (entry 46; its author's), f69d97f9 (a concrete
class another extends is Abstract<X> and struct X), 0ed2f502 (Julia's kinds from Base.iskindtype), 98b5fd9c (one
`snake`; watch-point rejections named), 3761d543 (CallTarget, AstCallTarget), d10956d6 (under the landing lock the
rebased tip checked once), 74f9fa48 (dev/formal/CFGStackify.tla, the invented Stackifier model deleted), 078a8fd5 (a type
value brings the classes it denotes), c27588f3 (the capture finder and context collector over the NIR), e602591f (the
collaborators the Translator's constructor builds; the importers), 59c80dcc (Fixes: A41S17 A41S18 A42S1 A42S2 A43S1
A45S5), f7e90da0 (CompilationTask's struct), adb62ca3 (LLVM_FILES and LLVM anchors resolved at the llvm pin), 02e8f55e
(types.dart's last five definitions), 93b7ecea (a stub's named parameter takes dart's default or none), aa2e552a (the
600 dart cases return their facts and depend on their argument; A41E8, A41E9), 33c8969c (the spec's validation rules
dart leaves to the engine, refused at the builder) and 360363ab (translate, end to end; the entry exported). Every
finding rests on one exact command, quoted. The two standing items: the in-scope total, `julia dev/skeleton.jl count`
at 360363ab, is "in scope, in all 3498", unmoved, and no commit changes dev/skeleton_scope.toml (`git log
95dd5b6e..360363ab -- dev/skeleton_scope.toml` is empty); the progress line reads "src: 2922 of 3590", its total one
less than entry 46's 3591 as f69d97f9 counts Abstract<X> and struct X as one definition. Traps: one instruction that can
trap where Julia defines a value (A47S1); Julia's `div` and `rem` reach WT as checked_sdiv_int and checked_srem_int
(`julia -e 'f(x,y)=div(x,y); g(x,y)=rem(x,y); …code_typed…'` lists `Base.checked_sdiv_int` and `Base.checked_srem_int`),
which have no arm and reject, so no DivideError is a trap today; when they are ported each is a check that throws, never
i64.div_s's trap. Findings A47S1, A47E1, A47E2 and A47E3.

Area: builder — 33c8969c inventories WebAssembly 3.0's validation rules in test/wasm_builder/builder_validation.jl and
names each rule's refusing check: 20 rules dart leaves to V8 now refuse at the emitting or defining call (br_table's one
arity, a mutable field for struct.set, array.copy's element subtype, call_indirect's funcref table, an immutable global in
a constant expression, lane bounds, a u32 memarg offset), one case each, one partial and said so; sound, D10. 98b5fd9c
fixes A41S14: skeleton.jl reads parity.jl's `snake`, and four watch-point rejections name real anchors.

Area: collection and planning — a94bf136 fixes A42S3 and A45S2, re-measured at 360363ab with this tree's depot: the
two NamedTuple orders now give "(false, false, 3, 2)", unequal shapes with their own indices. 59c80dcc fixes A42S2 (a
reference field past `Core.Compiler.datatype_min_ninitialized` is nullable), A42S1 (Julia's ABI stated: signext for
the signed classes, zeroext for the unsigned and Bool), A43S1, A41S17 (moduleNameToId reads 0x), A41S18 and A45S5
(emitCodegen fixed at its source, D12). f69d97f9 fixes A41S10 with Julia's own shape for a concrete dart class others
extend, `abstract type Abstract<X>` and `struct X <: Abstract<X>` (precedent AbstractArray and Array); 0ed2f502 reads
Julia's kinds from Base.iskindtype where a copy of its list would miss Julia 1.14's three new kinds (D3, D5); 93b7ecea
fixes A41S11 (a named parameter takes dart's default, or stays required where it does not translate, never `nothing`).
de918a8c's typeOfReturnValue is the CodeInstance's rettype, Julia's answer. 74f9fa48 models LLVM's CFGSort and
CFGStackify over every reducible CFG of N blocks with a Broken instance per claim, before the port (D11, D42).
adb62ca3's LLVM anchors resolve at the llvm pin by clang-format's columns, L213's plants grown by nine wrong forms.

stopgap in disguise: Abstract<X> and the anchors are constructions; the validation inventory is a test that names a check
per rule; the native-answer selection is a diff over text (A47E1).
precedent: Abstract<X>, Julia's AbstractArray and Array; CFGStackify, LLVM's WebAssembly backend at its pin; the
validation rules, the WebAssembly 3.0 specification's.

Area: emission and diagnostics — b7c2ab9f's not_int on a Bool is an xor with 1 (Julia's Bool an i1), flipsign_int a select
over the wrapping negation, the bit counts the width for zero, as Julia's. (A47S1, medium) fptosi and fptoui lower to
wasm's trapping truncations (src/intrinsics.jl:269–272: `i64_trunc_f64_s`, `i32_trunc_f64_u`, …) on the comment
"fptosi and fptoui trap where Julia leaves the value undefined" (:244). Julia does not leave it an error: its
`unsafe_trunc` is a bare fptosi (`code_typed(x -> unsafe_trunc(Int64, x), (Float64,))` holds `Base.fptosi` alone) and
"an arbitrary value will be returned" when the value is not representable; natively `unsafe_trunc(Int64, NaN)` is 0
and `unsafe_trunc(Int64, 1e30)` 9223372036854775807 on this machine. A wasm trap there is no Julia behavior, and under
dart's wasm-opt flags (`--traps-never-happen`, compile.dart:159) the optimizer may treat the trapping path as
unreachable. The saturating `i64.trunc_sat_f64_s` and kin give a value for every input, and aarch64's native answers
exactly.

Area: enforcement and prose — every hunk of 9f47da82, d10956d6, aa2e552a and the test hunks of the range. aa2e552a
fixes A41E8 and A41E9: each case returns its dart test's facts as a tuple, `_dw_bits` and the folds are gone, and 104
cases whose typed IR was a single `return <constant>` now depend on their argument. (A47E1, medium) 9f47da82 proves a
case's native answer only when its group's text changed, and a group's text is everything from the previous group's
close to its own (`_dart_group_texts`, test/dart_tests.jl), so a helper written in one group's text and used in others
re-proves only the first: `_dw_facts(xs...) = xs` sits at test/smoke_corpus.jl:2489, inside dart_web_wasm's text, and
`awk '/^_g\("dart_/{g=$0} /_dw_facts\(/{print g}' test/smoke_corpus.jl | sort | uniq -c` counts it in dart_patterns 520
times, dart_nnbd 91, dart_const 60 and every other group; an edit to it leaves those groups' recorded answers unproven.
The unit should be the corpus file outside each group's case list (any change there re-proves every group), or each
case's free names resolved to their definitions. (A47E2, medium) The progress numerator counts a definition whose body is
only a rejection as ported. Across src/, an awk count of filled one-line definitions whose body is `reject!(` gives 41
(record_class_generator.jl 11, types.jl 7, constants.jl 7, code_generator.jl 5, …), among them 02e8f55e's
`core_types(self::Types)::NoCounterpart = reject!(Internal(… "Kernel's CoreTypes has no Julia counterpart" …))`
(src/types.jl:326) and b369cfab's eleven record-class generators. Where dart's body is itself a throw, the rejection is
its port; where it stands for "no Julia counterpart", the definition is answered, not ported, and "2922 of 3590" counts
it beside running code. The line should count the two apart, so 100% means every definition runs or ports a throw.
(A47E3, low) dev/ship.sh still says "every commit is checked on its own tree, against its parent (… each landed commit
passes)" (dev/ship.sh:31–32), but since d10956d6 a stack rebased under the lock onto a new base has only its tip checked
there, each earlier commit checked on its old base alone, so an intermediate landed commit can be red on the base it
landed on. A merge queue's choice, the comment should say so. The first compile's run by node is again in a message
alone (360363ab: "Run by node, the serialized module answers 1 42 0 …"), A46E1, which the lead routed to wt3-tests.
Requirements: the standing trap rule and D3 (A47S1); D5 (A47E1); the denominator rule (A47E2); C9 (A47E3); no lock
fired inside its band.

Landing times: entry 46 landed with the median of five at 530 s (ship's line); d10956d6 holds the lock for one check.

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A42S3 and A45S2 are fixed by
a94bf136; A41S17, A41S18, A42S1, A42S2, A43S1 and A45S5 by 59c80dcc; A41S10 by f69d97f9; A41S11 by 93b7ecea; A41S14 by
98b5fd9c; A41E8 and A41E9 by aa2e552a. A47S1 is open on MARCH 1.D. A47E1 is open on MARCH 1.T. A47E2 is open on MARCH
1.A6. A47E3 is open on MARCH 1.L.

## 2026-10-28 — audited through 34065d0e (360363ab..34065d0e: the closures' Kernel visitors [out], C2's LLVM anchor, the startup flag and constant initializers, entry 47, one ship per lane, LoopInfo, CFGSort, CFGStackify, the FixIrreducible model, the selectors, the field check, barrel exports, closureInfo, saturating truncations, throw_ref, PiNode, one progress total, the rest of the intrinsics)

The forty-eighth audit, beside the work, covers 0ff72a54 (closures.dart's Kernel visitors [out]), be1a65ef (C2 admits
an @parity anchor at the llvm pin; `Charter-change: C2 — Dale 2026-10-28: "yes" (to the wording …)`), 025b30cc
(`_initialize_at_startup` false; a binding's initializer only when const and mutation-free), c1db3621 (ParameterInfo's
sentinel, local functions, merge), 3a253fc3 (WasmI32 and wasm array constants), 4ddec0f3 (entry 47; its author's),
a5621640 (one ship per lane; the header says what is checked where), b8b8d61f (LoopInfo over Julia's CFG), afa34011
(SelectorInfo, DynamicSelector), cfafd72e (`skeleton.jl diff` checks each filled struct's dart fields), 0a3deefe
(DartGlobals over the bindings the closed world reads), d063a327 (the barrel files' export directives), ce722aa5 and
465f1738 (closureInfo is Function's), f5ea3cba (RuntimeTypeInformation's tables against Julia's `<:`), 02ae4bf2
(fptosi and fptoui saturate; A47S1), 5cf29a7f (answered definitions' reasons in Julia's terms), f42f5f39 (throw_ref
takes an exnref; element expressions; check_forward over every loaded module; A45S1, A45S3), 517aac7a (CFGSort), b166efb6
(CFGStackify), c85ad6af (a PiNode as dart's unchecked AsExpression), fe3ad4d0 (wasm_builder_reach's ruling cited),
ee829408 (dev/formal/FixIrreducible.tla), 81103f31 (src progress counts the generator's definitions) and 34065d0e (the
remainder of intrinsics.dart). The LLVM ports (b8b8d61f, 517aac7a, b166efb6, ee829408) are read against the llvm pin by a
sub-audit whose report joins entry 49. Every finding rests on one exact command, quoted. Standing items. The total:
`julia dev/skeleton.jl count` in a scratch worktree of each commit gives 3498 at 0ff72a54's parent, 3449 at 0ff72a54
(closures.dart 112 → 63: its 15 rows, _CaptureFinder and _ContextCollector with their members and ClosureLayouter's
thirteen walkers), 3449 at afa34011's parent and 3446 at afa34011 (DynamicCallSiteCollector's visitDynamicInvocation,
visitDynamicGet and visitDynamicSet); since 81103f31 the progress line reads the same total ("src: 2808 of 3446"). Each
row names the Julia step that does the work: lowering's closure conversion, and the trim verifier admitting no call it
cannot resolve (D32). Traps: 02ae4bf2 lowers fptosi and fptoui to the saturating truncations (0xfc prefix), its test
checking the trapping opcodes are not emitted; 34065d0e adds no trapping instruction (`git show 34065d0e -- src | grep
'^+' | grep -c 'unreachable(\|ref_cast(\|_trunc_f\|_div_[su](\|_rem_[su]('` gives 0); c85ad6af's PiNode reaches
convertType's ref.cast only for a narrowing Julia's inference proved, a cast that cannot fail. Test integrity: compile()
has not landed; the first entry of its own follows it. Findings A48S1 and A48E1.

Area: builder — f42f5f39 fixes A45S1 (throw_ref verifies an exnref and refuses otherwise, dart's gap fixed at its
source) and the inventory's partial row (an element expression's result checked against its table's element type: 0 of
the 22 rules missing). d063a327 ports the barrel files' `export … show/hide` directives as `@dart_export`, Julia `public`
in their module, checked at load against the pin; sound (precedent: dart's export, Rust's `pub use`).

Area: collection and planning — 025b30cc fixes A45S4: no pragma answers false (util.dart:64's `return null;`), and a
binding's value is its initializer only when it is const and `Base.ismutationfree` of its type, since a module's
`__init__` runs again at load; Julia's answer, D3. 0a3deefe counts the closed world's global bindings as dart's static
fields, typed by `Core.get_binding_type`. ce722aa5's closureInfo is Function's class, the supertype of every function
object. afa34011's dispatch tables are empty by Julia's answer, the same code filling them were the subset to admit
dynamic calls, as the lead's rule wants of a runtime structure. (A48S1, low) The rule says the dispatch tables are never
[out], and afa34011's three rows sit in dynamic_dispatch_table.dart: they take out DynamicCallSiteCollector's visitors, a
Kernel walk, not the table, so they meet kind (b); the file's header should say which of its definitions are the
structure (ported) and which the walk ([out]), so the next row there is read against that line.

stopgap in disguise: the [out] rows are an exact list, each with its reason, read by the generator; the field check
(cfafd72e) is a check that `diff` runs, not yet a landing's (A48E1).
precedent: the initializer rule, juliac's image and Julia's `__init__`; closureInfo, Julia's Function; the export
directives, dart's show/hide and Rust's `pub use`.

Area: emission and diagnostics — 34065d0e: generateEqualsIntrinsic lowers Base's `==` on two operands of one type at
its own width to i32.eq, i64.eq, f32.eq or f64.eq, which compute Base's answer (bit equality of integers, IEEE equality
of floats: NaN unequal, 0.0 == -0.0); the unary map folds a literal operand as Julia computes it. 02ae4bf2 fixes A47S1
(native and node agree on unsafe_trunc of NaN, ±1e30, ±3.7 per its message; its test checks the opcodes). Sound.

Area: enforcement and prose — every hunk of a5621640, cfafd72e, 81103f31, be1a65ef and fe3ad4d0. be1a65ef's trailer
follows 143876a4's form and quotes Dale's "yes" to the wording, which D42's ledger row supports ("julia compiler ITSELF
along with another language like RUST or c-sharp"). 81103f31 fixes A46S2's two totals: the progress line's total is the
generator's, a definition ported when no stub is left at it, so the 93 enum values and field accessors count no more;
A47E2 stands, a definition answered by a rejection still counting as ported until the three-way count the lead routed
to wt3-skeleton lands. a5621640 fixes A47E3. (A48E1, medium) The generator's diff still runs in no landing:
cfafd72e's own words, "`diff` is not yet a landing gate", and `git show 34065d0e:dev/check.sh | grep -c skeleton` gives
0, while its new field check reports 242 missing dart fields on wt2 (Translator's 201 KernelNodes mixin fields among
them). A46S2's gate half stands: a port that drops a stub or a field lands unseen, and the 100% gate the lead set (stubs
at 0) cannot hold until the diff is in every check. Requirements: D5 (A48E1); the [out] rule (A48S1); no lock fired
inside its band.

Landing times: entry 47 landed with the median of five shown by ship; a5621640 adds the per-lane slot.

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A47S1 is fixed by 02ae4bf2; A45S4
by 025b30cc; A45S1 and A45S3 by f42f5f39; A47E3 by a5621640; A41S9 by cfafd72e for `diff`; A46S2's two totals by
81103f31. A48S1 is open on MARCH 1.A4. A48E1 is open on MARCH 1.A6.

## 2026-10-28 — audited through 9a5c5a21 (34065d0e..9a5c5a21: entry 48, MacroAssembler's class-id search, FixIrreducibleControlFlow, CallShape, StaticGet, the selector use; and the LLVM sub-audit of entry 48's stackifier)

The forty-ninth audit, beside the work, covers 85013a47 (entry 48; its author's), 13807930 (MacroAssembler's class-id
range check and searches, loops, tables, invoke, inlineCallTo, loadClassId), 514aa322 (WebAssemblyFixIrreducibleControlFlow
ported over Julia's CFG), bdb79816 (CallShape, a @closed sum of its three kinds), 82c7360c (a binding's read as
StaticGet) and 9a5c5a21 (FunctionCollector's selector use and stub names). It records the sub-audit of entry 48's LLVM
ports (b8b8d61f, 517aac7a, b166efb6, ee829408), read against the llvm pin 7a941dfb, each finding resting on the command
its report quotes. Standing items: no commit changes dev/skeleton_scope.toml (`git log 34065d0e..9a5c5a21 --
dev/skeleton_scope.toml` is empty), so the total stays 3446; compile() has not landed, so the test-integrity entry waits
on it; traps below. Findings A49S1, A49S2 and A49S3.

Area: builder — empty by diff for src/wasm_builder/. The stackifier's ports (src/llvm/, src/julia/machine.jl) are read
here, as the code generator's input. The sub-audit found sortBlocks (cfg_sort.jl:72–181) LLVM's step for step (back edges
skipped in the predecessor counts, the Preferred and Ready queues, the deferral where the region header does not dominate,
the loop-rotation test, maybeUpdateTerminator at both places, NDEBUG asserts as located rejections), placeBlockMarker and
placeLoopMarker with the ScopeTops walk-out, getEarliestInsertPos and getLatestInsertPos, getBranchDepth and the depth
rewrite, and LoopInfoBase::analyze over Julia's DomTree, and the CFG and dominator tree Julia's own
(`compute_basic_blocks`, `construct_domtree`, `dominates`, `nearest_common_dominator`); try regions reject at
machine.jl:141, located. Its tests check properties (WellNested, BranchTargetsEnclosingLabel, DepthCorrect, PathsPreserved
by interpreting the structured program against compute_basic_blocks, test/llvm_cfg_stackify.jl:134–184), not recorded
answers. Its F1, an irreducible-CFG check of WT's own (`irreducible_entries`, machine.jl:274), is gone with 514aa322's port
of LLVM's ReachabilityGraph (`git show origin/wt2:src/julia/machine.jl | grep -c irreducible_entries` gives 0), and its
F6 (FixIrreducible.tla naming a file that did not exist) with the same commit. (A49S1, low) Three LLVM steps the port
drops without a word or a rejection: CFGStackify's balanced-marker assertion for a BLOCK's end (cfg_stackify.jl:280–282
checks only a non-empty stack, where LLVM asserts `ScopeTops[Stack.back().first->getNumber()]->getNumber() <=
MBB.getNumber()`, WebAssemblyCFGStackify.cpp:2647–2650), and runOnMachineFunction's appendEndToFunction and
cleanupFunctionData (cfg_stackify.jl:332–337 against LLVM 2701–2735), with fix_ends_at_end_of_function writing the
stand-in `BLOCK_TYPE_RESULTS = 0xffff` for every block type where LLVM writes the result's value type for a single
result; each dropped step is a located rejection or a ported line (D42: no algorithm of our own, none left out silently).
(A49S2, low) CFGStackify.tla checks maybeUpdateTerminator's outcome on the final layout (`TermToks`, lines 279–298) and
loops from `BodyOf` (130–135), so the port's per-move terminator rewrites (the FBB rewrite, the reversed condition) and
analyze's own steps are not model-checked (D11: the model is of the algorithm as ported).

Area: collection and planning — bdb79816's CallShape is a @closed sum with dart's predicates, equality and hash, a Julia
method read as dart's FunctionNode (no type parameters a call passes, positional parameters after the callee, a trailing
vararg, keywords as Core.kwcall's own method); sound. 9a5c5a21's recordSelectorUse records each target for every class id
of its ranges; sound.

stopgap in disguise: none new; the stackifier's checks are LLVM's assertions as located rejections.
precedent: the stackifier, LLVM's WebAssembly backend at its pin (D42); CallShape, dart's sealed class.

Area: emission and diagnostics — 13807930's sequences are dart's over the ported builder; its two `unreachable`
instructions (`git show 13807930 -- src | grep '^+' | grep -n 'unreachable('` gives lines 171 and 206) end an empty
search that has no miss branch, where dart's own sequence is unreachable, never a Julia error. (A49S3, medium) Two rules
for one fact, whether a binding's value is a compile-time constant (D5). visit_static_get (src/code_generator.jl:706–712)
instantiates any `isconst` binding's current value as a constant: `isconst(node.ref.mod, node.ref.name) || reject!(…)`
then `instantiate_constant(self, NirConst(Core.Const(getglobal(…))), …)`. 025b30cc's get_constant_initializer
(src/globals.jl:178–188) admits a const binding only when its value is free of mutation, `Base.ismutationfree(typeof(value))
|| return nothing`, because a module's `__init__` runs again at load and can fill a const Ref or array. So `const R =
Ref(0)` with `__init__() = (R[] = …)` is a lazy global by the one and a compile-time snapshot by the other; the read
should ask the globals' rule, one function both call.

Area: enforcement and prose — the test hunks of 13807930, 514aa322, bdb79816, 82c7360c and 9a5c5a21, and the sub-audit's
reading of the stackifier tests. 13807930's and 514aa322's node runs ("every answer equals Julia's any(r -> contains(r, id),
ranges)") are again in their messages alone; A46E1's runner is wt3-tests'. The sub-audit's F2 holds: nothing in src
calls the stackifier yet (`git grep -n "run_on_machine_function\|sort_blocks(" origin/wt2 -- src test` lists
target_machine.jl and the tests alone), so no stackified function runs against native, and no test holds LLVM's own
output (an llc oracle) beside the port's; the property tests stand in. Requirements: D42 (A49S1); D11 (A49S2); D5 (A49S3);
no lock fired inside its band.

Landing times: entry 48 landed by dev/ship.sh with its median printed.

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A49S1 and A49S2 are open on MARCH 1.D.
A49S3 is open on MARCH 1.C.

## 2026-10-28 — audited through 9f479d76 (9a5c5a21..9f479d76: the generator in every check and its 45 [out] rows, one anchor parser, entry 48, control flow through LLVM's stackifier, dynamic signatures, the forwarders, the member visitor's arms, the hard limit, entry 49, the type tests' builder, topTypeNonNullable, makeFunctionTypeForBody)

The fiftieth audit, beside the work, covers 233fee7d (L210 runs dev/skeleton.jl: src is what `write` writes, or the
landing fails; dev/skeleton_scope.toml's rows each labelled `julia:` or `scope:`, and 45 definitions [out]), 1ba1c08c
(one anchor parser for both pins; D42 cites L213 alone), 85013a47 (entry 48; its author's), 991ac565 (visitBlock runs
LLVM's addPreEmitPass over Julia's CFG and lowers its machine code), 5513cb5c (the dynamic dispatcher's and forwarder's
signatures by call shape), 11019ac7 (branchIf and _conditional), fa8a81ae (FunctionCollector's dynamic forwarders,
invocation creator stubs and lambdas), a9e9a998 (the member visitor's Constructor and Field arms reject), 392ba6f5 (no
check stage outlives a hard limit), 1692b182 (entry 49; its author's), 37fd1806 (the type tests read the builder through
its cell), a4c65cc9 (topTypeNonNullable) and 9f479d76 (makeFunctionTypeForBody; the invocation creator rejects). Every
finding rests on one exact command, quoted. Standing items. The total: `julia dev/skeleton.jl count` in scratch
worktrees gives 3446 at 9a5c5a21 and 3401 at 233fee7d, unchanged to a9e9a998; the 45 are 233fee7d's new
[out_definitions]: about thirty of target.dart's front-end hooks (the concrete*LiteralClass queries,
perform*Transformations, flags, instantiateInvocation, enabledLateLowerings, …), ConstantEvaluator, runtime_generator's two
JS-interop passes, generate_wasm.dart's generateWasm, ParameterInfo._defaultValue and wasm_annotations.dart's three
MemoryLimits readers. Each names its Julia step or its scope exclusion, and the lead ruled on the two in question:
generateWasm is kind (a), dart's command-line driver, accepted; the MemoryLimits readers are the codegen side that
configures the module's memory, to be ported answering "no annotation" (A50S1). Traps: 991ac565 lowers NIR's
`unreachable` (`git show 991ac565 -- src | grep '^+' | grep -n 'unreachable('`: `(s::NirUnreachable) =>
WasmBuilder.unreachable(self.b[])`), where Julia's own IR is unreachable, as the rule allows. Recursion: the stackifier
walks keep `IdDict{MachineInstr,Int}` (991ac565), linear; the class walk is memoized by `IdSet{DataType}`
(src/julia/classes.jl:32); NirConst's hash, the 2^40 blow-up the lead reported, is fixed in the compile() landing, not
yet on wt2, and is read in the entry that follows it. Test integrity: compile() has not landed. Findings A50S1, A50S2
and A50E1.

Area: builder — empty by diff for src/wasm_builder/.

Area: collection and planning — 233fee7d fixes A48E1 and A46S2's gate: L210's negatives load the generator and require
its two readers to agree, every in-scope src file to be what `write` writes and no Kernel-table row stale, with plants
for a hand-edited stub, a deleted stub and a stale row. 1ba1c08c fixes A45E1 and puts both pins' anchors on one parser,
`parse_anchor`, which every reader calls (D5). (A50S1, medium) Three [out] rows the lead ruled ported:
`"dart2wasm/lib/wasm_annotations.dart MemoryLimits.readAnnotation"`, `… MemoryLimits._readMemoryType` and `…
MemoryLimits._readLimits`, each "julia: reads dart's wasm:memory-type pragma …; Julia declares no pragmas" (233fee7d's
hunk of dev/skeleton_scope.toml). The rule keeps a codegen structure whose Julia answer is empty in the port, answering
it: here, no binding carries a memory type, so readAnnotation answers none. The three leave the [out] list and count in
the total again (3404).

stopgap in disguise: L210 is now a construction-checking lock (the generator's output must equal src), its plants
reaching each fault; the `julia:`/`scope:` labels are read by the generator.
precedent: the stackifier, LLVM's addPreEmitPass at its pin; PHI elimination, LLVM's per-predecessor copies.

Area: emission and diagnostics — 991ac565: BLOCK, LOOP, their ENDs, BR, BR_IF and BR_UNLESS lower to wasm's block,
loop, end, br and br_if as LLVM's MCInstLower; a phi is a local assigned on each edge into its block, every incoming value
pushed before any is set, so `a, b = b, a + b` reads the old a; sound. 11019ac7 answers dart's _hasLogicalOperator false,
Julia having lowered `!`, `&&` and `||` to calls and jumps. a9e9a998's arms reject as Internal, a Julia member never being
a Kernel Field or Constructor. 9f479d76's typeOfCheckedParameterVariable is the MethodInstance's exact specialization,
Julia's answer. (A50S2, medium) A49S3 stands as ruled: visit_static_get (src/code_generator.jl:706–712) still takes any
`isconst` binding's value as a constant, where the lead's one rule is const and `Base.ismutationfree` of its type, the
globals' predicate, defined once; routed to wt3-codegen. A50S2 is that predicate's single definition and its two callers.

Area: enforcement and prose — every hunk of 233fee7d, 1ba1c08c and 392ba6f5, and the test hunks of the range. 392ba6f5
kills a check stage past 480 s and names the running file or case: the hard floor Dale asked for after a 50-minute hang.
(A50E1, low) The floor is an environment default, `WT_HARD_LIMIT=${WT_HARD_LIMIT:-480}` (dev/check.sh:40), so a lane
whose shell exports a larger value raises it for its own landing; D14 says never edit a budget, and a number the check
states should be the check's literal, its band beside it (D17), not a variable the landing's environment can move.
Requirements: the [out] rule (A50S1); D5 (A50S2); D14 and D17 (A50E1); no lock fired inside its band.

Landing times: entry 48 and entry 49 each landed by dev/ship.sh with the median of five printed.

Resolution: this entry lands alone, as one commit, prose only, and fixes nothing. A48E1 and A46S2 are fixed by 233fee7d;
A45E1 by 1ba1c08c; A49S3 is carried as A50S2. A50S1 is open on MARCH 1.A4. A50S2 is open on MARCH 1.C. A50E1 is open on
MARCH 1.L.

## 2026-10-28 — audited through ff20d5d8 (9f479d76..ff20d5d8: compile() end to end, the entry as Julia's compileable specialization, the verifier's records, the opt phase and Binaryen_jll, constants, constructor_info, dynamic_dispatchers, tags, PHI elimination, records, 8- and 16-bit integers, the exports, the Translator's fields, isa and typeassert, module binding reads, D43 and D44, entry 50; and the tests themselves: dart cases judged by a property, the landing core, dev/corpus.sh, test/src/ walked)

The fifty-first audit, beside the work, covers the 34 commits from edc2a995 to ff20d5d8 (26c21437 is entry 50, its
author's). The builder area was read by diff alone; the collection and emission areas were read by two read-only
sub-auditors, each finding below re-run here by the command quoted; the enforcement area and the fifth area Dale asked
for, now that compile() runs tests end to end (the tests themselves, for hacks that mislead), were read here. Every
finding rests on one exact command, quoted. Standing items. Corpus: `tail -2 "$(git rev-parse --git-common-dir)/wt-corpus.tsv"`
gives `6be635af green 105` then `ff20d5d8 red 101 dart_nnbd/is_type_test_null_is: Test Failed at …/test/src/dart_tests.jl:746`;
its Test Summary reads `1667 3 1670`, the three `:rejects` cases dart_nnbd/is_type_test_null_is,
dart_patterns/exhaustiveness_restrictive_cast_pattern_3_2 and dart_closure/implicit_closure now rejecting as Internal,
while the landing of c1df0ae6 and ff20d5d8 was green (A51S1, A51E3). Traps and invalid modules: none written in the
range. Recursion: NirConst's hash (7de69761, src/julia/nir.jl:38–41) ends the 2^40 walk the lead reported; its
same-type collisions are A51S13. Silent catches: `_dart_at_base` (test/src/dart_tests.jl:32–46) falls back to the
whole base text or "" on a git failure, which runs more native answers, never fewer; not a finding. Test integrity:
eleven findings, A51E1 to A51E9 and A51S1's and A51S3's test halves. Findings A51S1 to A51S16 and A51E1 to A51E9.

Area: builder — empty by diff: `git diff --stat 9f479d76..ff20d5d8 -- src/wasm_builder` prints nothing.

Area: collection and planning — 7de69761 runs compile.dart's phases end to end, the closed world carrying its entry;
c4108b80 takes the entry as the specialization Julia compiles (sound on 1.13, A51S4 on 1.12); 2a20e4a4 keeps the
verifier's records (TrimError), which broke one caller (A51S2); 2e891670 states WT's subset is the verifier over
unmodified Base, confirmed by juliac-buildscript.jl's trim-base include; 3271a341 and f380dcf2 add dart's opt phase
with dart's flags verbatim (dartdev's default phases, compile.dart:874–875 there, not the library's
compiler_options.dart:64–68), Binaryen_jll pinned `=0.130.0` beside dart's binaryen rev 9926156a; 6be635af's
sampled Translator anchors (translator.dart :100 :157 :198 :228 :294 :455 :866 :1328) each declare their field.
(A51S2, high) src/functions.jl:111 builds an OutsideSubset from a String: `grep -rn "OutsideSubset(" src` gives
`src/functions.jl:111: reject!(OutsideSubset("CCallableMissing: the @ccallable …` beside subset.jl:125/127/137, each
`OutsideSubset([TrimError(…)])`; 2a20e4a4 made the field `errors::Vector{TrimError}` (src/julia/reject.jl:72), so a
ccallable whose signature disagrees with inference raises a MethodError, not a rejection (C6, D9). The check itself
re-derives the verifier's CCallableMissing (`member.specTypes == sig && body.ci.rettype <: rettype`, functions.jl:110),
where juliac queues each ccallable `svec(rt, sig)` for the verifier (juliac-buildscript.jl:70) and _trim_infer queues
only the entry (D3, D5). Fix: queue the ccallables as juliac does, delete functions.jl:107–112, and add the
mismatching case. (A51S3, high) compile() returns wasm-opt's rewrite by default, judged by nothing:
`grep -rn "differential runner" src dev/PARITY_MASTER.md` gives src/julia/wasm_opt.jl:21 and dev/PARITY_MASTER.md:46,
"the differential runner checks the optimized module against native Julia beside the unoptimized one", while
`grep -n "no runner" test/smoke.jl` gives `120: … the rebuild has no runner to judge it against native yet (dev/MARCH.md
1.B)`. The default user path now returns bytes WT's builder never built (C7: nothing bypasses emitted bytes) and
test/src/dart_tests.jl, test/smoke.jl and test/probe_bytes.jl all call that default. Fix: `optimize = false` the default
until the runner exists (dart's library default), both texts saying what is true, and the probes pinned to the
unoptimized module. (A51S4, medium) c4108b80's 1.12 arm is not juliac's answer by evidence:
`nm -U …/julia-1.12.7…/lib/julia/libjulia-internal.1.12.7.dylib | grep -i "compile_hint_spec\|add_entrypoint"` gives
`T _jl_add_entrypoint` and `t _jl_get_compile_hint_specialization` (local); base/experimental.jl:494–495's entrypoint
calls jl_add_entrypoint, whose choice of MethodInstance no source here shows, and the arm calls
compileable_specialization_for_call, the verifier's resolver for dynamic calls (typeinfer.jl:1286, verifytrim.jl:227).
Fix: on 1.13, where both exist, a case asserting the two agree on every corpus entry, or the 1.12 arm ruled by the
lead. (A51S5, medium) NIR is built twice per compile: `grep -n "build_nir(" src/translator.jl src/compile.jl` gives
compile.jl:217 (`generate_record_classes(build_nir(component, …))`) and translator.jl:217, and
record_class_generator.jl:35 ignores its argument (`= Dict{RecordShape,DataType}()`) (C1). Fix: build once, at the TFA
phase, and hand it on. (A51S6, medium) src/compile.jl:250 answers an unrecognised module name with the main module's id
(`something(WasmCompilerOptions_id_for_module_name(…), WasmCompilerOptions_main_module_id())`) where dart asserts
non-null (compile.dart's `idForModuleName(…)!`) (D9). Fix: reject, located. (A51S9, medium) TrimError's
`cause::Any` (src/julia/reject.jl:68) is matched with a fallthrough `print(io, c)` (:88) after two `isa` arms (C4, D8).
Fix: a `@closed` Union of CallMissing, CCallableMissing and String, matched `@exhaustive`. (A51S10, low) the body
lookup is written three more times beside nir_body_of (nir.jl:476): `grep -rn "b.ci.def === " src` gives
translator.jl:989, constructor_info.jl:130 (942375ed) and functions.jl:109 (96737610), whose `first(…)` throws an
unlocated ArgumentError (D5). (A51S13, low) NirConst hashes every structured immutable by its type alone
(nir.jl:40), so N same-type constants make the constant cache quadratic, a slow walk where the rule is linear. (A51S16,
low) stale prose: `grep -n "module names emitted" src/compile.jl` gives :257 where the flag list omits it;
test/dart_tests.toml:150 and :759 say "WT runs no wasm-opt"; dev/PARITY_MASTER.md:51 cites `record_unsupported!`, of
which `grep -rn record_unsupported src | wc -l` gives 0 (C9).

stopgap in disguise: `optimize = true` citing dartdev's phases rests on a differential runner no file holds (A51S3).
precedent: the entry, juliac's Base.Experimental.entrypoint (1.13's add_entrypoint ccall); the opt phase, dartdev's
`--optimization-level` phases; PHI elimination, LLVM's PHIElimination.cpp at the llvm pin; the verifier's error kinds,
an @enum read from verifytrim.jl's description text, an unknown text Internal.

Area: emission and diagnostics — 516247f6's phis follow PHIElimination.cpp:317/:365, copies before each predecessor's
terminator; e87d9c73's Internals sit only on paths with no Julia counterpart; 1f7e7276's conversions, shifts,
compares and divides were each traced and are sound; 4942b4ae's dropped stack-trace payload is the lead's recorded
ruling; ff20d5d8 fixes A50S2, visit_static_get now calling get_constant_initializer, globals.dart's one rule.
(A51S1, high) isa and typeassert reach an Internal wherever a checker is called: `grep -rn 'var"function"(self::' src`
gives only `code_generator.jl:1690 … CallTarget.function" var"function"(self::CallTarget)::Union{} =` (an Internal,
"abstract in …") and `:1713 … AstCallTarget.function`, while IsCheckerCallTarget and AsCheckerCallTarget (types.jl:152,
:196) and _DynamicDispatcherCallTarget (dynamic_dispatchers.jl:30) each hold a `function_::Late` that dart exposes as
`late final w.BaseFunction function` (types.dart:877, :1047) and MacroAssembler_invoke calls `var"function"(target)`
(code_generator.jl:1594). Behind it, `sed -n 740p src/types.jl` gives `is_checkers_for_module(self.translator.types, …)`,
a `Late{Types}` (translator.jl:138) where the one method takes Types: a MethodError. Read, not measured: the three
corpus cases each test a nullable operand or a typeassert, so each calls a checker, which is how c1df0ae6 turned their
located stubs into Internals (C6, D12). Fix: the three getters, `self.translator.types[]`, and a nullable isa and a
typeassert compiled end to end. (A51S7, medium) 6eeed056's "empty by Julia's answer" is contradicted in src:
dynamic_dispatchers.jl:10–11 says the verifier "rejects every call it cannot resolve statically, so no NIR statement is a
dynamic call", and code_generator.jl:770–771 (edc2a995) says the verifier admits "a generic call … only as a warning,
its result Union{} … which is dart's dynamic invocation" (C3, C9). Fix: the docstring true, and the lead's ruling on
whether a must-throw call is a dispatcher or Julia's MethodError throw. (A51S8, medium) ff20d5d8 leaves a second answer
to the binding question: `sed -n 189,190p src/code_generator.jl` gives dart_type_of's `isconst(g.ref.mod, g.ref.name) ?
… : reject!(Unquarantined(…))`, where visit_static_get rejects Unported (D5). Fix: dart_type_of through
get_constant_initializer, one kind at both sites. (A51S11, medium) `sed -n 232p src/julia/nir.jl` gives `code::Vector{Any}`
(516247f6), the raw statements LLVM.add_pre_emit_pass reads (code_generator.jl:520), a second IR reader beside L221 and
L222's closed sums (C1, C5). (A51S12, low) `sed -n 44p src/llvm/phi_elimination.jl` gives `pred in mf.blocks[mbb].preds
|| continue`, an edge skipped silently where a CFG-mapping bug belongs loud (C6). (A51S14, low) a type computed at run
time rejects as `Unquarantined("src/julia: …")` (code_generator.jl:1012, :1035) where dart's counterpart is its
unported makeType path, an Unported. (A51S15, low) functions.jl:288 parses Julia's gensym name with a regex, no Julia
API (C3).

stopgap in disguise: none new in src; the Internal-asserting tests are A51E5.
precedent: the type tests, types.dart's emitIsTest and emitAsCheck; the phi copies, LLVM's per-predecessor copies.

Area: enforcement and prose — every hunk of dev/check.sh, dev/ship.sh, dev/corpus.sh, test/parity_ratchet.jl,
test/src_tests.jl, dev/MARCH.md and dev/LEDGER.md in the range, and the fifth area: test/src/dart_tests.jl whole,
test/src/*.jl's new and changed tests, the landing core. D43 and D44 are rows with planned checks (1.U to 1.Z). The
records' native answers are native Julia's, re-proven whenever a record or its group changes (`_dart_same`, type and
isequal): no self-golden there. No corpus case was rewritten (`git diff --stat 9f479d76..ff20d5d8 --
test/smoke_corpus.jl` prints nothing), so none routes around Base. (A51E1, high) the `:rejects` property admits WT's
own defects: test/src/dart_tests.jl:746–747 passes `got isa WasmTarget.Rejection && !(got isa WasmTarget.Internal)`,
and reject.jl's docstring names `InvalidModule` and `Internal` together "a defect of WasmTarget itself"; `grep -rn
"InvalidModule(" src` gives the builder's own refusals (instructions.jl:473, a ValidationError) and wasm_opt.jl's
"wasm-opt failed", so a case whose module the builder or wasm-opt refuses reads as a located rejection, D10's alarm
muted. Nor is "located" checked: `_dart_outcome` drops `e.at`, and an Unported's anchor is any String. Pinning the
anchor would bring back the snapshot that oscillated; the property should pin that it is located instead. Fix: `:rejects`
admits Unported, Unquarantined and OutsideSubset alone; an Unported's anchor parses by parse_anchor to a definition
at its pin, an Unquarantined's row exists, `at` is not empty. (A51E2, high) the full matrix cannot run:
test/runtests.jl:54, :58 and :60 include `late.jl`, `classes.jl` and `wasm_builder/serializer.jl`, and `test -e` gives
each `MISSING` since c4682adc moved them under test/src/; ci.yml and gate.yml run runtests.jl at clause closure, and
it runs four families where test/src/ holds over thirty files. Fix: runtests.jl includes test/src_tests.jl in their
place, and the ratchet checks every include path of test/*.jl exists. (A51E3, high) the landing core lets a regression
land and nothing holds the next: the core is the first five cases of each `_g` block by position
(dart_tests.jl:722); counted by script over the corpus and the records, it holds 65 of 600 cases and 15 of 121
`:compiled` ones (`core {'rejects': 48, 'compiled': 15, 'wt_bug': 2}`, `outside core {'rejects': 421, 'compiled': 106,
'wt_bug': 8}`), and the three cases above sit at positions 5, 8 and 24. dev/corpus.sh caught them about three
minutes after the landing (wt-landings.tsv `00:00:07Z ff20d5d8`, wt-corpus.tsv `00:03:02Z ff20d5d8 red`), but
`grep -rn "wt-corpus" dev/*.sh test/parity_ratchet.jl` names it in dev/corpus.sh alone: "its red the next landing's first
item" binds no landing, a later regression hides behind the first recorded failure, and a stack's intermediate
commits are never run whole. Fix: dev/ship.sh refuses a landing while the corpus's last row for origin/wt2's head is red,
unless the stack changes a failing case's outcome; the core gains every case the last red run names (fixed in size,
D14). (A51E4, high) `:wt_bug` asserts nothing and its list can grow: dart_tests.jl:743 passes `got === :compiled ||
got isa _Outside || got isa WasmTarget.Rejection`, anything but a raw exception; `grep -rn "wt_bug" test dev src`
outside the records gives only dart_tests.jl's comment and branch, so no check holds "the list only shrinks", nor a
`:compiled` record against being lowered to `:rejects` (`grep -n "dart_tests\|:compiled\|DART_CASES"
test/parity_ratchet.jl` reads only test/dart_tests.toml); and `grep -n "wt_bug\|no class info\|type-literal" dev/MARCH.md`
prints nothing, so the ten known Internals are tracked by no row (C5: no known failure hides behind a passing test).
Fix: `:wt_bug` asserts the case is still Internal (fixed, it fails and is re-recorded); a lock measured against
CHECK_BASE that refuses a `:wt_bug` key added or a `:compiled` record lowered unless a message line names it, as L227
names removals; each of the ten on its MARCH row. (A51E5, high) tests that pass on a WT Internal, a visitor run
outside its stage: `grep -rn "undefined variable" test/src` gives eight asserts of `Internal` "undefined variable", four
added in the range (code_generator.jl:110 by 1f7e7276, :537 by c1df0ae6, intrinsics.jl:95 by df9c1f14, records.jl:114 by
fe84bcfa); c1df0ae6's builds an `isa` NirCall by hand, its operand's local never defined, so emit_is_test and
emit_as_check ran in no test and A51S1 landed unseen. The RefValue{Union{Nothing,Int64}} entry is faithful (an entry
with a Union argument has no compileable specialization, c4108b80) and routes around nothing; the hand-built call is
the mimicry. Fix: each through compile() or a defined operand, asserting emitted code or an Unported/Unquarantined.
(A51E6, medium) comments claim runs no test makes: test/src/code_generator.jl:252, :293, :368, :441 and :504 say "run by
node … answers as native Julia", and `grep -n node test/src/code_generator.jl` finds only those comments (:252 by
7de69761 and :504 by 1f7e7276 in the range); the checks are the magic header and `0xc0 in compile_one(…)`, a byte
anywhere in the module; `@test CodegenCases.f_add(typemax(Int32)) == typemin(Int32)` and records.jl's `@test
RecordCodegenCases.sa((b = 2, a = 7)) == 5` test Julia, not WT; and 7de69761's message says test/compile.jl runs "against
native" where test/src/compile.jl checks the header and byte equality. Fix: run them with llvm_control_flow.jl's
node_answers, or delete the claims; the 0xc0 check read at its instruction. Extends A46E1. (A51E7, medium) 7de69761, a
feature commit, loosened D14's judgement to land itself: `git log -S'"$cores" ]; then echo' 9f479d76..ff20d5d8 --
dev/check.sh` names 7de69761, whose hunk turns `-gt "$cores"` into `-ge "$cores"` because "this landing went red twice at
load 10 on 10 cores" (D14, D17). Landing this entry first printed `check: RED — 181s, past D14's band (a 60-s target, red past 120 s) at load 8 on 10 cores`, every test green; 8bfde7ff measures the same check at 57 s on idle performance cores against 136–166 s on efficiency cores, so that time was the machine's, not the check's. Fix: the judgement in its own commit with its intent. (A51E8, low) L227's
`--find-renames=90%` (parity_ratchet.jl:1913) keeps a test that stops running: in a scratch repository, `git mv
test/src/kept.jl test/src/kept.jl.off` then L227's own query prints `deleted by L227's query: []` and
`R100 test/src/kept.jl test/src/kept.jl.off`; a move out of test/src/ or off `.jl` leaves src_tests.jl's walk
silently. A deleted @testset inside a kept file was never L227's (unchanged). Fix: a rename whose destination the walk
does not read counts as a removal. (A51E9, low) a failing case names no rejection: the corpus's three failures print
only the expression (`grep -c "internal error\|Internal(" wt-corpus.out` gives 0). Fix: the reason in the failure.
Requirements: C6 and D9 (A51S1, A51S2, A51S6, A51S12); C7 and D10 (A51S3, A51E1); C1 and D5 (A51S5, A51S8, A51S10,
A51S11); D3 (A51S2, A51S4); C5 (A51E4, A51E5); D14 and D17 (A51E3, A51E7); C9 (A51S7, A51S16, A51E6); no lock fired
inside its band.

Landing times: wt-landings.tsv gives 435 s for 6be635af and 6501 s for the stack c1df0ae6 and ff20d5d8 (first commit to
landed, a lane's wait included).

Resolution: this entry lands alone, prose only, and fixes nothing. A51S1 is fixed by 321cabff, landed after ff20d5d8
(the three getters and the translator's types read through its Late at three sites, with a test compiling a called is
checker and as checker, and a @test_broken waiting on the class walk); A50S2 is fixed by ff20d5d8. A51E7 is fixed by
8bfde7ff, the judgement in its own commit with its intent: a load read against the four performance cores, the band and
the hard limit unchanged. A51S3 is ruled by the lead: wasm-opt stays on by default, dartdev's default, judged by
wt3-tests' runner, which compares the 121 compiled cases against native on 709 facts, optimized and not; the finding
stays open until that runner lands with a `Fixes:` line naming it. A51S2 and A51E2 are what the range broke beside
A51S1, the next fixes of their lanes before new work. By owner: the translator lane holds A51S2 (the String
OutsideSubset and the ccallable re-derivation), A51S4, A51S5, A51S6, A51S9, A51S10, A51S13, A51S15 and A51S16; the
codegen lane holds A51S8, A51S11, A51S12, A51S14 and A51E5, with A51E6's code_generator tests; the tests lane holds
A51E1, A51E4's assertion, A51E9, and A51S3's runner; the lead holds A51E2, A51E3, A51E4's lock and A51E8, and owes the
ruling A51S7 asks (whether a must-throw generic call is a dynamic dispatcher or Julia's MethodError throw); f969a257,
landed after ff20d5d8, touches A51E3's core and is the next entry's to read. A51S11, A51S12, A51S14 and A51E5 are open
on MARCH 1.D. A51S3 is open on MARCH 1.B, with A51E6. A51S2, A51S6 and A51S15 are open on MARCH 1.F. A51S4, A51S5,
A51S8, A51S9, A51S10, A51S13 and A51S16 are open on MARCH 1.C. A51S7 is open on MARCH 1.E, the lead's ruling. A51E1 and
A51E9 are open on MARCH 1.T. A51E4 is open on MARCH 1.Q. A51E2, A51E3 and A51E8 are open on MARCH 1.L.

## 2026-10-28 — audited through 8e926b8b (ff20d5d8..8e926b8b: D14's judge on the performance cores, the checker getters, the src tests' times and the codegen-only core, the full matrix through src_tests.jl, entry 51 and its resolution, f32_const's narrowing, one optimistic check and the corpus on efficiency cores, the differential runner, constants met by the class walk, the code generator's fields, type tests over whole bodies)

The fifty-second audit, beside the work, covers the ten commits of ff20d5d8..8e926b8b that are not entry 51 (85ce23e7
and a844658a, its author's): 8bfde7ff, 321cabff, f969a257, fd2dd0ba, ec12d4e2, d6aab352, fd193c22, f64334a6, 7abfc7e2
and 8e926b8b. Every finding rests on one exact command, quoted; the one Julia run (typed IR, A52S2) ran under
`taskpolicy -b` with a 120-s alarm. Standing items. Fixed in the range: A51S1 by 321cabff (recorded in entry 51), A51E2
by ec12d4e2 (test/runtests.jl includes test/src_tests.jl, the walk a landing runs), A51S14 by 8e926b8b (both type-test
sites reject Unported at code_generator.dart:3212 instantiateTypeParameter), A51E7 by 8bfde7ff (recorded). Claimed and
not whole: A51E5 (8e926b8b's subject names it; `grep -rn "undefined variable" test/src` still gives seven asserts of an
Internal, code_generator.jl:119, :126, :183, :365, intrinsics.jl:62, :95 and records.jl:114, three of them audit 51's
range, :126 by 1f7e7276, :95 by df9c1f14, :114 by fe84bcfa: one of eight fixed) and A51S8 (moved into the class walk,
read below). The known
Internals: 7abfc7e2 re-records eight `:wt_bug` cases `:rejects`, each in that landing's core (its records changed) and
judged by the property there; `grep -c ":wt_bug)," test/src/dart_tests.jl` gives 2 left (identity_equality_tearoff,
no_such_method_dispatcher), still on no row (A51E4). Traps and invalid modules: none written. Recursion: the class
walk's new operand loop (src/julia/classes.jl:38) is one pass over each body's statements, linear. Test integrity:
A52E1, A52E3, A52S1's pinned kind, and A51E5 above. Findings A52S1, A52S2, A52E1, A52E2 and A52E3.

Area: builder — d6aab352: f32_const narrows dart's double with Float32, round to nearest, where dart's serializer
narrows at writeF32; IR.F32Const holds the Float32 itself, so the narrowing moved to its one caller and every f32.const
no longer raises a MethodError. A Float32 literal widens to Float64 exactly and narrows back to itself; sound. No
finding.

Area: collection and planning — 7abfc7e2: closed_world_classes meets each literal's and constant binding's type its
statements read as values, nir_value_type the one source of an operand's type (dartTypeOf's copy deleted), so a `const`
Ref or a compared String has its class, where dart's ClassInfoCollector has every class of the component. (A52S2,
medium) nir_value_operands drops every Symbol operand of a builtin call on a claim about Julia that is false: `grep -n
"builtins take no Symbol" src/julia/nir.jl` gives `576:order: Julia's builtins take no Symbol as data)`, and `perl -e
'alarm 120; exec @ARGV' taskpolicy -b julia --startup-file=no -e 'f(x::Symbol) = x === :a; g(x::Int) = Core.tuple(:k,
x); display(code_typed(f,(Symbol,))[1]); display(code_typed(g,(Int,))[1])'` prints `%1 = builtin (x === :a)::Bool` and
`%1 = builtin (tuple)(:k, x)::Tuple{Symbol, Int64}`: a Symbol compared or stored is data, and the walk leaves it unmet
(C3, D3). Fix: drop a Symbol only at the operand positions that name a field or an ordering (getfield, setfield!,
isdefined, the memoryref orderings), from Julia's builtin signatures, and say so. A51S8 stays open and grows: `grep -n
'reject!(Unquarantined("src/julia: a read of the non-constant' src/julia/nir.jl` gives :470 in nir_value_type, which the
class walk now calls on every constant or binding operand (`grep -n "for st in b.stmts, v in nir_value_operands"
src/julia/classes.jl` gives :38), so a read of a changing binding rejects Unquarantined in the class walk before
visit_static_get's Unported getter is reached: two kinds for one cause, the earlier one the wrong one.

stopgap in disguise: none new.
precedent: the class walk, dart's ClassInfoCollector over every class the component holds; an operand's type, Julia's
inferred ssavaluetypes and specTypes.

Area: emission and diagnostics — 321cabff: the three call targets read their `late final function` (types.dart:877,
:1047, dynamic_dispatchers.dart:53) and types' Late is read at three sites. fd2dd0ba: the code generator holds each of
dart's 25 fields or states Julia's answer; `git show 898a1e4b:pkg/dart2wasm/lib/code_generator.dart | sed -n "<n>p"` for
72, 73, 74, 76, 77, 82, 90, 98, 101, 104, 108 and 159 gives each field the anchor names (`late w.InstructionsBuilder b;`
… `Source? _sourceMapSource;`). 8e926b8b: a run-time tested type rejects Unported at instantiateTypeParameter, and isa
and typeassert are tested over whole generated bodies. (A52S1, medium) emitIsTest and emitAsCheck reject a missing dart
runtime function as a Julia-only gap, and 8e926b8b's test pins it: `grep -n "Unquarantined(" src/types.jl` gives :471,
:489, :511 (`emitAsCheck: … needs the runtime's _asSubtype, which has no Julia counterpart`) and :749, all 111ec9c5's,
and test/src/code_generator.jl:578 asserts `e.rejection isa W.Unquarantined && e.at == "dart2wasm/lib/types.dart:527
Types.emitAsCheck"`; `git -C ~/.cache/wasmtarget/dart-sdk grep -n "_asSubtype" -- '*.dart'` gives
`sdk/lib/_internal/wasm/common/type.dart:1561:void _asSubtype(…)`, a dart definition. The kind A51S14 fixed at the call
sites stands here (C6). Fix: Unported at the runtime's anchor, or the lead's ruling on how the runtime library
(sdk/lib/_internal/wasm) is anchored, and the test pinning the corrected kind.

stopgap in disguise: none new.
precedent: the getters, dart's `late final` field overriding CallTarget's abstract getter; the type tests, types.dart's
emitIsTest null check (`ref.is_null`, negated).

Area: enforcement and prose — every hunk of dev/check.sh, dev/corpus.sh, test/runtests.jl, test/src_tests.jl,
test/runner.jl and the range's test files. fd193c22 holds one optimistic check beside the landing-lock holder's, and the
corpus at background QoS with no slot; f969a257 prints each src file's time and compiles the landing core to codegen
(`optimize = !_DART_CORE_ONLY`), wasm-opt left to the corpus run, where `:rejects` still admits InvalidModule (A51E1),
so a wasm-opt refusal of a `:rejects` case passes in both runs. The runner (f64334a6) is sound as written: each
marshalled type crosses as its bits, `===` at native's type, both modules compared with native and with each other, an
unmarshalled type, an import, a missing entry, a trap and a hang each a located failure, never a skip; its selftest
plants a wrong answer, a miscompile and a loop. (A52E1, high) the runner judges no case of the corpus: `grep -rln
"WTRunner\|answer_cases\|run_cases" test dev src` gives test/runner.jl and test/src/runner.jl alone, and
test/src/dart_tests.jl:88–89 still says a `:compiled` case's run is "checked against native once the runner lands";
f64334a6's message says "Every compiled case now runs the module wasm-opt returns beside codegen's own" and "This is the
fix for audit #51's A51S3", and entry 51's resolution records the lead's ruling as judged by a runner comparing 121
compiled cases on 709 facts, a run no tracked file makes. A46E1 and A51S3 stay open (no `Fixes:` line names them: `git
log --format=%B ff20d5d8..8e926b8b | grep -n "^Fixes:"` prints nothing). Fix: dart_tests.jl's `:compiled` branch builds
answer_cases and runs run_cases, each fact its own @test (the core with `optimized = false`, the corpus run both
modules), and that commit's `Fixes: A46E1, A51S3`. (A52E2, medium) D14's band is judged almost never: dev/check.sh
leaves it unjudged when the load average reaches `hw.perflevel0.physicalcpu`, 4 here, and the load average counts the
landing's own two checks (four processes) and the corpus's efficiency-core work; landing entry 51 and its resolution,
`bash dev/ship.sh` printed `check: 191s, past D14's band but UNJUDGED: load 6 on 4 cores` and `check: 212s, past D14's
band but UNJUDGED: load 10 on 4 cores`. A band no landing is judged by is no band (D14, D17). Fix: judge a
load-independent measure, the check processes' CPU seconds (user plus system), with its band, so a check slow by its own
cost is red at any load and one slow by the machine is not. (A52E3, low) two new asserts judge nothing of WT:
test/src/code_generator.jl:574 pins WT's own instruction names for `maybe` (`["local.get", "struct.get", "local.set", …,
"ref.is_null", "i32.eqz", …]`), a self-golden, correct by reading but never run, and :542 asserts
`Float32Cases.addf(1.0f0) === 2.5f0`, native Julia (A51E6's pattern). Fix: run both through the runner (an entry of
Int64 that builds the Ref inside, until a RefValue argument is marshalled), the Julia-only assert deleted. Requirements:
the third oracle (A52E1); D14 and D17 (A52E2); C3 and D3 (A52S2); C6 (A52S1); no lock fired inside its band.

Landing times: wt-landings.tsv's last landings include entry 51 (3136 s from its first commit, a lane's wait included)
and its resolution (452 s); `bash dev/ship.sh` printed the median of the last five at 598 s, under D13's 600-s edge.

Resolution: this entry lands alone, prose only, and fixes nothing. A51E2 is fixed by ec12d4e2 and A51S14 by 8e926b8b,
each leaving its row. A51E5 and A51S8 stay open on their rows, A51S8 now reaching the class walk. A52E1 is open on MARCH
1.B, with A46E1 and A51S3. A52S1 is open on MARCH 1.D. A52S2 is open on MARCH 1.C. A52E2 is open on MARCH 1.L. A52E3 is
open on MARCH 1.B. By owner: the tests lane holds A52E1 and A52E3; the codegen lane holds A52S1 and A51E5; the
translator lane holds A52S2 and A51S8; the lead holds A52E2 and the ruling A52S1 may need.

## 2026-10-28 — audited through 695f1985 (8e926b8b..695f1985: the Internal-asserting tests replaced, entry 52, the node claims run, PHIElimination's dead edge, D14's band in CPU seconds, a type literal as its type object, each case's compile budget, the corpus run against native)

The fifty-third audit, beside the work, covers the seven commits of 8e926b8b..695f1985 that are not entry 52 (cfd3e8a7,
its author's): ceab7ff0, 22696995, bb5ed475, 1ad6fb67, 2d4cd956, f5270a3d and 695f1985. Every finding rests on one exact
command, quoted; the one Julia run is the landing check itself. Standing items. Fixed in the range: A51E5 by ceab7ff0
(`grep -rn "undefined variable" test/src` prints nothing; the Internals the tests still assert are invariant guards, a
misuse rejected, not a visitor run outside its stage), A51E6 by 22696995 (the five "run by node" sites call
answers_native, test/runner.jl's run_cases, and `0xc0 in` is gone), A51S12 by bb5ed475, A52E2 by 1ad6fb67 (`Fixes:
A52E2`), and A46E1, A51S3 and A52E1 by 695f1985 (`Fixes: A46E1, A51S3`): the whole run reads every compiled case's
answer through the runner, both modules, fact by fact. The known Internals: 2d4cd956 re-records the last two `:wt_bug`
cases `:rejects`; `grep -c ":wt_bug)," test/src/dart_tests.jl` gives 0. Corpus: `tail -4 wt-corpus.tsv` gives 7abfc7e2
to 2d4cd956 green; dev/corpus.sh is running 695f1985 now (its progress `dart_tests.jl: compiling …`). Not on wt2: the
lead's rulings since entry 52, codegen-b's unreachable sub-generators rejecting with Julia's replacement named and the
control-flow visitors NoCounterpart beside visit_block: `grep -n "visit_while_statement\|visit_if_statement"
src/code_generator.jl` still gives `@unported` stubs at :659 and :663, so the next entry reads them as they land; the
rule for both, read now: reaching a sub-generator Julia's IR never produces breaks WT's own invariant, an Internal
naming the replacement (never an Unported, which counts toward the port), and each NoCounterpart names its Kernel-table
row and visit_block's LLVM anchor (D42). Test integrity: A53E2, A53E3, and A52E3 still open (code_generator.jl:636
asserts `Float32Cases.addf(1.0f0) === 2.5f0`, :652 WT's own instruction names). Findings A53E1, A53E2, A53E3 and A53S1.

Area: builder — empty by diff: `git diff --stat 8e926b8b..695f1985 -- src/wasm_builder` prints nothing.

Area: collection and planning — empty by diff for src/compile.jl, src/translator.jl and src/julia/ (`git diff --stat
8e926b8b..695f1985 -- src` names src/constants.jl and src/llvm/phi_elimination.jl alone). A52S1 and A52S2 stand open,
nothing in the range touching them.

Area: emission and diagnostics — bb5ed475: lower_phi_node skips an edge only from a block Julia's dominator tree names
unreachable (mf.domtree is over the machine blocks, Julia's block k as k + 1, src/julia/machine.jl:131–140, so the index
agrees), LLVM's UnreachableMachineBlockElim having removed that operand, and any other edge from no predecessor is an
Internal at PHIEliminationImpl::LowerPHINode; its test plants a diamond, a dead edge and a stray edge. 2d4cd956: a
lowered type literal goes to visitInstanceConstant, Julia's type object being an instance of its kind; a SimpleVector's
one field is its elements as an immutable array (make_array_of); _makeWasmArrayLiteral reads the element type through
its Late; and the int, double and Bool boxes take `i32.const classId` alone, as dart's do, the builder having refused
the header-and-hash form (InvalidModule). That last is A51E1 measured: `git show -s --format=%B 2d4cd956 | grep -n
"InvalidModule"` gives `the builder refused the struct.new (InvalidModule, D10)`, a WT defect every `:rejects` case that
reached a box passed as a located rejection until another fix exposed it. (A53S1, low) the boxes' docstrings still give
the difference 2d4cd956 removed: `grep -n "deliberate difference from dart" src/constants.jl` gives :534 ("this box is
the class's struct … its object header (pushObjectHeaderFields: the class id and the identity hash)"), :575 ("the box
carries class_info's object header … not dart's class id alone") and :697 ("A deliberate difference from dart, whose
`_BoxedBool` takes `i32.const classId` alone") (C9). Fix: each says the box is dart's, the class id and the value.

stopgap in disguise: none new.
precedent: the dead edge, LLVM's UnreachableMachineBlockElim before PHIElimination; the boxes, dart's
`_BoxedInt`/`_BoxedDouble`/`_BoxedBool` with `i32.const classId`.

Area: enforcement and prose — every hunk of dev/check.sh, test/src/dart_tests.jl and the range's test files. 695f1985
runs every module the whole run compiles, whatever its record, native's answer computed afresh, one @test per fact, a
reader that does not compile a named failure; f5270a3d gives each compile a 10-s budget after a warm-up compile. The
differential so lives only in dev/corpus.sh's run, which `grep -n "corpus" dev/ship.sh` shows no landing reads: a module
answering otherwise than native lands green and is red minutes later on a run that holds nothing, so A51E3 (open on 1.L)
now carries the third oracle itself. (A53E1, high) D14's CPU-second band depends on which cores the check gets:
dev/check.sh:100 says "another job's load cannot turn a landing red", while :102 says "An efficiency core spends about
twice the CPU seconds", and `sysctl -n hw.perflevel0.physicalcpu hw.perflevel1.physicalcpu vm.loadavg` gives `4`, `6`,
`{ 6.10 6.17 6.36 }`. Run on 695f1985 unchanged, `CHECK_BASE=origin/wt2 bash dev/check.sh` printed `check: waited 100s
for a slot`, `src | 3332 3332 1m51.5s`, `check: 131 CPU-s on the critical path (load 19, ratchet 32, src tests 112);
129s wall` and `check: RED — 131 CPU-s, past D14's band`: a tree with no change is red when another check holds the
performance cores (D14, D17); shipping this entry onto d77c8289 (a src change, so the lane's depot recompiled) then
printed `check: 223 CPU-s on the critical path (load 36, ratchet 88, src tests 187); 248s wall` at load 7.39, the same
prose-only change: the CPU seconds count the precompile a src change forces and the efficiency cores' slower work alike.
Fix: a measure no core type moves, the instructions retired that macOS's `/usr/bin/time -l` reports (`/usr/bin/time -l
true` prints `10138510 instructions retired`), its band re-stated from an idle run, or the check's processes held to the
performance cores. (A53E2, medium) 695f1985 widens `:wt_bug` to silence a wrong answer: dart_tests.jl's header now says
a `:wt_bug` record covers a case whose "module answers otherwise than native", and the run is skipped for it (`got ===
:compiled && today !== :wt_bug && !_DART_CORE_ONLY`), while A51E4's lock does not exist (`grep -n "wt_bug"
test/parity_ratchet.jl` prints nothing): one record edit turns the worst outcome, a module returning the wrong value
(D9's why), green. Fix: `:wt_bug` never covers a module's answer (a wrong answer always fails), and A51E4's lock before
any record uses it. (A53E3, low) the compile budget times JIT: f5270a3d's message measures a new path's first compile at
"about 20 s" against the 10-s band, and the warm-up compiles one path (`WasmTarget.compile(x -> x + 1, (Int64,))`), so
which case pays depends on corpus order. Fix: budget `@timed`'s time less its `compile_time`. Requirements: D14 and D17
(A53E1); D9 (A53E2); C9 (A53S1); no lock fired inside its band but A53E1's.

Resolution: this entry lands alone, prose only, and fixes nothing. A51E5 is fixed by ceab7ff0, A51E6 by 22696995, A51S12
by bb5ed475, A52E2 by 1ad6fb67, and A46E1, A51S3 and A52E1 by 695f1985, each leaving its row. A53E1 is open on MARCH
1.L. A53E2 is open on MARCH 1.Q, with A51E4. A53E3 is open on MARCH 1.T. A53S1 is open on MARCH 1.C. By owner: the lead
holds A53E1 and A51E3; the tests lane holds A53E2, A53E3 and A52E3; the translator lane holds A53S1.

## 2026-10-28 — audited through 6eb9d85f (695f1985..6eb9d85f: BrTableInfo, one check holding the performance cores and three shards, a one-case dart core, entry 53, the landing lock first, D14 in instructions retired, @nospecializeinfer, a builtin's names by its tfunc, singleTarget and the entries, ccallables queued for the trim inference, a global builtin's module a name)

The fifty-fourth audit, beside the work, covers the nine commits of 695f1985..6eb9d85f that are not entry 53 (66fbe3e0,
its author's): d77c8289, a995ed8a, 4913600f, a5834b8d, 0fb51d68, 1a53f370, cdbb712c, 0c40c27e and 6eb9d85f. Every
finding rests on one exact command, quoted; the one Julia run, listing Core's builtins, ran under `taskpolicy -b` with a
100-s alarm. Standing items. Fixed in the range: A53E1 by a995ed8a and a5834b8d (`Fixes: A53E1`, the band in
instructions retired, A54E1 below on what they omit), A52S2 by 1a53f370 and 6eb9d85f, A51S2 by 0c40c27e (the re-derived
check and its String rejection deleted, the ccallables queued for Julia's verifier), A53S1 by cdbb712c. Not on wt2 yet:
the tests lane's lowering-record rule folded into L227, read when it lands. Test integrity: the landing core is now the
first case of each `_g` block (dart_tests.jl:736, `cs[1:min(1, end)]`); counted by script over the corpus and the
records it holds `{'rejects': 12, 'compiled': 1} of 13`, against `{'rejects': 479, 'compiled': 121}` in all, so a
landing compiles one of the 121 compiling cases and runs none, and A51E3 (open on 1.L: `grep -n "corpus" dev/ship.sh`
still prints nothing) is the only thing that could hold a regression of the other 120 or a wrong answer; d77c8289's test
judges br_table against the test's own formula (`lo <= v <= hi ? Int32(v - lo) : Int32(-1)`), not a Julia program's
answer (A54S3). Findings A54S1, A54S2, A54S3, A54S4 and A54E1.

Area: builder — 0fb51d68: InstructionsBuilder._add, _debugTrace and _verifyTypesFun take their argument @nospecialize
under @nospecializeinfer, one inference and one body where _add held 91 specializations; the instruction is only pushed,
`is_constant` and `name` now dispatched at run time, a compile-cost fix in src (D15), sound. (A54S4, low) the macros
@parity looks through are listed three times, and the lists differ: `git show 0fb51d68 -- src/julia/parity.jl | grep
'^+'` gives _identity's `(@inline, @noinline, @nospecializeinfer, @closed, @unported)`, _defines's `(@inline, @noinline,
@nospecializeinfer, @closed)` and _generic_name's `(@inline, @noinline, @nospecializeinfer)`, each edited by hand in one
commit (D5). Fix: one constant naming the transparent macros, each reader taking what it needs from it, the difference
stated where a reader differs.

Area: collection and planning — 1a53f370 and 6eb9d85f: a builtin's literal is dropped only at the positions its tfunc
takes a name (getfield's name and order, the global builtins' module and name, the memoryref orderings, the atomic
pointer orders), every position checked here against Compiler/src/tfuncs.jl's signatures. (A54S1, low) three builtins
that take a binding's or a field's name are missing from the table: `perl -e 'alarm 100; exec @ARGV' taskpolicy -b julia
--startup-file=no -e 'for n in names(Core; all=true); …; f isa Core.Builtin && println(n); end'` lists
`get_binding_type`, `getproperty` and `setproperty!` among Core's builtins, and `grep -n "get_binding_type\|getproperty"
src/julia/nir.jl` finds none in _builtin_name_operands, so `get_binding_type(M, :x)`, which a typed global's assignment
lowers to, meets Symbol as a value and stops at Symbol's layout where it needs no Symbol (C3). Fix: the three rows.
0c40c27e: check_subset infers again with each reached ccallable queued as `svec(rettype, signature)`, the verifier
judging it. (A54S2, low) the set is not juliac's: juliac-buildscript.jl:69–70 runs `ccall(:jl_add_ccallable_entrypoints,
Cvoid, ())` under `--compile-ccallable`, which juliac.jl:28 documents as "Include all methods marked `@ccallable` in
output", while _reached_ccallables keeps only those the entry's inference reached; and build_nir's `ci in seen &&
continue` drops a repeated CodeInstance's second CodeInfo unread. Fix: the selection named as WT's (one entry, no image)
with its necessity, or the lead's ruling; the repeated pair asserted to be the same CodeInfo before one is dropped.
cdbb712c: singleTarget is an invoke's MethodInstance, getFunctionEntry the member itself, canUseUncheckedEntry true,
each Julia's answer where inference resolved the call; sound.

stopgap in disguise: none new.
precedent: a builtin's name operands, Julia's tfunc signatures (Compiler/src/tfuncs.jl); the ccallables, juliac's
`svec(rettype, signature)` queue item.

Area: emission and diagnostics — d77c8289 ports BrTableInfo: its thresholds, rangeSize, build, _isTooSparse and
emitBrTableExpr. (A54S3, medium) it is a port Julia never reaches: case_map is `Dict{Int64,NoCounterpart}`, and `grep -n
"struct NoCounterpart" src/julia/kernel.jl` gives `:18 … an uninhabited struct is the type of no value there`, so every
table is empty; `grep -rn "BrTableInfo_build\|BrTableInfo__(" src | grep -v "@parity"` gives only build's own call; the
test builds empty tables; and the definitions count toward src progress (ship's src line read 3012 ported at cfd3e8a7
and 3021 at 66fbe3e0, d77c8289 among the src changes between). Julia's IR has no switch, the reason d77c8289 gives for
SwitchInfo and the lead's ruling gives for the control-flow visitors (C2: a mechanism Julia never reaches is a defect
even when its tests pass; A47E2's numerator). `_br_table_expr` is a `Function` field, an abstract type where dart's is
`void Function(...)` (C4). Fix: the BrTableInfo family answered as Julia's (no switch statement, a jump table being
LLVM's lowering if one ever comes), uncounted, or kept only with the caller that reaches it.

stopgap in disguise: none new.
precedent: BrTableInfo, dart's dense-switch lowering, unreachable from Julia's IR.

Area: enforcement and prose — every hunk of dev/check.sh, dev/ship.sh, test/src_tests.jl and test/src/dart_tests.jl.
a995ed8a holds one check slot, its ratchet and three src shards (a longest-first split by file size, WT_SRC_SHARD) one
per performance core; 4913600f takes the landing lock first and checks each commit once on the rebased stack, a refused
push when the base moved under the lock (bors's one-at-a-time mode). (A54E1, medium) the instructions retired that
a5834b8d judges count the Julia process alone, never its children: `/usr/bin/time -l perl -e 'for(1..3e7){}'` prints
`4605557532 instructions retired` with `0.42 user`, and `/usr/bin/time -l sh -c 'perl -e "for(1..3e7){}"; true'` prints
`25220006 instructions retired` with the same `0.42 user`. The src shards run node (answers_native in code_generator.jl
and code_generator_sub.jl, the runner's selftest, llvm_control_flow.jl) and wasm-opt (test/src/compile.jl), and the
ratchet runs git for its history locks, so that work is in no judged number; the ratchet's rate (`RATE_RATCHET=2.4`
against `RATE_SRC=5.3` G per CPU-s) is lower partly because its CPU seconds hold its git children's and its instructions
do not. A check can grow by work in a subprocess and stay green (D14, D17). Fix: each stage's children measured too
(each node, wasm-opt and git run under `/usr/bin/time -l`, its instructions summed into its stage), or the children's
CPU seconds judged beside the band. Requirements: C2 (A54S3); D14 and D17 (A54E1); D5 (A54S4); C3 (A54S1); no lock fired
inside its band.

Landing times: entry 53 landed at 1378 s from its first commit, a lane's wait for the band's fix included; ship printed
the median of the last five at 370 s, inside D13's band.

Resolution: this entry lands alone, prose only, and fixes nothing. A53E1 is fixed by a995ed8a and a5834b8d, A52S2 by
1a53f370 and 6eb9d85f, A51S2 by 0c40c27e and A53S1 by cdbb712c, each leaving its row. A54S1 and A54S2 are open on MARCH
1.C. A54S3 is open on MARCH 1.D. A54S4 is open on MARCH 1.A6. A54E1 is open on MARCH 1.L. By owner: the translator lane
holds A54S1 and A54S2; the codegen lane holds A54S3; the lead holds A54E1, A54S4 (src/julia/parity.jl) and A51E3.

## 2026-10-28 — audited through f77d8b39 (6eb9d85f..f77d8b39: perf of Late and the maps, the runtime's anchors, the must-throw call, the 45 visitors Julia never reaches, EqualsNull, StaticTearOff and StaticSet, Not, the structured statements as NoCounterpart, the compile-once dispatchers, the intrinsics' families, the generators Julia replaces, entry 54, a check only inside a landing and each green commit pushed, smoke against native, UInt crossing, six language directories and the strict records, the audit-51 S fixes, the literal visitors, the switch family, the serializer's buffers, CompilerPhase, the pragma readers, fourteen translator ports, the builtin names)

The fifty-fifth audit, beside the work, covers the 47 commits of 6eb9d85f..f77d8b39 that are not entry 54 (2c036a90, its
author's). The collection and emission areas were read by two read-only sub-auditors, each finding below re-run here by
the command quoted; the builder's one commit, the enforcement area and the tests were read here. Standing items. Corpus:
`tail wt-corpus.tsv` gives `9d0cba81 green` then `82fcef17 red … dart_closure/implicit_closure`, `977d5959 red …
implicit_closure`, `cb4ef2b4 red … dart_language/record_literal` (its run: `corpus | 4621 45 4666`, the failures `a
WasmTarget defect: WasmTarget rejects InstructionsBuilder: invalid module at i32.const 6 / i32.const 0 / global.get C1
42 …` in ten groups) and `9e31fe7e red`, while every landing after 82fcef17 went green: A51E3 (open on 1.L; `grep -n
"corpus" dev/ship.sh` prints nothing) is no longer a risk but the state of the branch, its corpus red for four heads and
counting. Fixed in the range (each checked): A51E1, A51E4, A51E9, A53E2 and A53E3 by 9d719901 (`:rejects` admits a
compile, an OutsideSubset, or an Unported whose anchor parses into a pin table or an Unquarantined whose row opens with
a file, never InvalidModule or Internal; `:wt_bug` asserts the defect still stands and never covers a module; a failure
prints `_dart_breaks`'s reason; the budget is `@timed` less `compile_time`; a `:compiled` record lowered or a `:wt_bug`
added is named `Lowers-record:`, L227's second half, with ten plants); A51S5 by 129c5acf, A51S6 by 76341323, A51S10 by
1e9d7839 (A55S1 its breakage), A51S11 by 762d5514, A51S15 by 6904535d, A51S16 by b412b1f4, A51S4 by 977d5959 (on 1.13,
over every `_g`/`_xf` entry), A52S1 and A52E3 by 7d8f3e62 (A55S11 its scope), A54S3 by 3cb7f7c6, A51S7 ruled by 0a69fbb6
(A55S17 its claim); partly: A51S8 by 35642ae7 (A55S6), A51S9 by 439a1606 (A55S8), A51S13 by 484f3351 (A55S5), A54S1 by
f77d8b39 (A55S3). Findings A55S1 to A55S17 and A55E1.

Area: builder — 03ab4430: writeF32 and writeF64 write through serializer.dart's scratch buffers, the bytes unchanged.
(A55S9, low) the buffers are process-global `const`s (serializer.jl:92, :107) where dart's static lives in one isolate;
two compiles on two threads would share them, a difference no text names (D7). Fix: one buffer per Serializer, or the
difference named.

Area: collection and planning — 762d5514 computes the CFG once at NIR build (nir.jl:252), which machine_function,
eliminate_phi_nodes and visit_block's copies all read; 129c5acf reads the world as NIR once, at the TFA phase. (A55S1,
medium) 1e9d7839 reads a field 762d5514 removed: `sed -n 236,241p src/julia/nir.jl` gives NirBody's fields `ci`,
`stmts`, `types`, `cfg`, and `grep -n "nir_body_of(translator.component, self.reference)" src/translator.jl` gives
`1410: for (i, st) in enumerate(nir_body_of(translator.component, self.reference).code)`: a compile with print_kernel
set raises a FieldError naming no site, and no case sets it (C6, D12). Fix: `.stmts`, and a case with print_kernel.
(A55S2, medium) ports Julia never reaches, counted as ported, A54S3's defect again: `for f in ffi_memory find_memory
get_polymorphic_dispatchers_for_module get_partial_instantiator_for_module _lazy_initialize_global; do grep -rn "$f("
src | grep -v "@parity" | wc -l; done` gives 0 for each; their own docstrings say so (translator.jl:414 "no module makes
one until the subset admits a dynamic call", :397 "so no program makes one", :806 "no call reaches here"), and ffiMemory
and getInternalizedStringGlobal serve a JS host every standalone compile lacks (52e5fccf, 79e5b94a, a5f55918, 8c4e9de8,
900d5810, 1e56b146, f1f5ad72) (C2). Fix: each rejects naming Julia's answer and leaves the ported count, as 6fa334e7 and
3cb7f7c6 do, under the one rule A55S14 asks. (A55S3, medium) f77d8b39 added the wrong rows: `sed -n 605,615p
src/julia/nir.jl` gives `f === Base.getproperty && return (2,)` and `f === Base.setproperty! && return (2,)`, while
`perl -e 'alarm 100; exec @ARGV' taskpolicy -b julia --startup-file=no -e 'println(Core.getproperty === Core.getfield, "
", Core.setproperty! === Core.setfield!); …'` prints `true true`: Core's builtins are getfield and setfield!, already in
the table, and Base's generic getproperty is a function call whose Symbol, left unresolved, is a real argument; and
`grep -n "_builtin_name_operands(callee)" src/julia/nir.jl` gives :664 with the `callee isa Core.Builtin` guard gone
(C3, D3). A54S1's premise was half wrong, its get_binding_type row sound. Fix: drop the two Base rows, restore the
guard. (A55S4, medium) c4c37345's validate and _validate_phases have no caller but each other (`grep -rn
"validate(\|_validate_phases(" src | grep -v "@parity"` gives `src/compiler_options.jl:133: _validate_phases(self)`);
called, the default cfe phase requires a `.dart` input (:154) and rejects every Julia compile, and dart's exhaustive
`switch (phases.first)` is an if/elseif chain (C2, C3, D8). Fix: Julia's answer for the input or a rejection naming it,
and an exhaustive phase match. (A55S5, low) 484f3351 hashes a mutable leaf by content (nir.jl:43) where its comment says
address: Julia's `hash` of a self-containing vector overflows the stack and a mutated one changes hash (C6, C9). Fix:
`hash(objectid(v), h)` for mutables. (A55S6, low) the rebindable test is decided twice: nir.jl:496 `isconst(g.ref.mod,
g.ref.name)` and globals.jl:162 `isdefinedglobal && isconst` (D5). (A55S7, low) translator.jl:1338 rejects "a Julia
binding declares no pragmas" Internal where 60092888's pragma readers reject the same fact Unquarantined (C6). (A55S8,
low) reject.jl:114 tests `e.cause isa TrimEntryText` outside the @exhaustive match, and subset.jl:137's CallMissing
typeassert would raise a TypeError naming no site on a third record (D8, C6).

stopgap in disguise: A55S2's full bodies, which cannot run and count toward src progress.
precedent: the CFG, Julia's compute_basic_blocks; a builtin's name operands, its tfunc signature (builtins only); a
mutable constant's identity, objectid.

Area: emission and diagnostics — the lead's rulings hold in substance: 86605f08 and cedaa61f type the 45 visitors of
constructs Julia never produces by the uninhabited NoCounterpart and reject Internal, visit_block (CFGStackify's port)
the structured statements' replacement; 41ab48cb (EqualsNull, dart :2022), 305549d5's tear-off (:2193), b3ce967c (Not,
:2803, the intrinsifier's copy deleted) and 22fd8a4f (:2984–:3008) match dart at their lines. (A55S10, high) 45 corpus
cases are InvalidModule, the builder refusing a constant's struct.new (the corpus line above: `i32.const 6`, `i32.const
0`, then the fields' `global.get … ref Int64`), new between 977d5959 and cb4ef2b4 (`git log --oneline
977d5959..cb4ef2b4` gives aa8aa069, 22fd8a4f, 3cb7f7c6, 03ab4430, c4c37345, 60092888, d92bd5ee, 4414459f, a5f55918,
cb4ef2b4); the lead's bisection names d92bd5ee, translator's getRecordClassInfo port, which exposed visitRecordConstant
instantiating each field at the top type where its struct holds the field's own type (C7, D10, D12); fixed by b54115e0
(`fix(constants): a record constant's fields at its class's own field types, as the record literal builds it`), its case
in 3a039a43; this entry first named 22fd8a4f, read and not measured, wrongly. Fix: at its source, the failing constants'
struct layout and header agreeing, with one of the 45 as its case. (A55S11, medium) the runtime's anchors are outside
every pin table, so 9d719901's located check refuses 7d8f3e62's rejections: the corpus's implicit_closure line reads
`its Unported anchor names sdk/lib/_internal/wasm/common/errors_patch.dart, in no pin table`, and `grep -c "sdk/lib"
src/julia/parity.jl` gives 0, so those Unported never enter the anchored total either (D43, C9). The anchors themselves
are right at the pin (type.dart:1561 `void _asSubtype(…`). Fix: the runtime files in the pin table and the skeleton's
scope, or the lead's ruling that names their kind. (A55S12, medium) one fact, two kinds: `grep -o 'reject!([A-Za-z]*'
src/code_generator.jl | sort | uniq -c` gives `88 reject!(Internal`, `13 reject!(Unported`, `87 reject!(Unquarantined`;
the replaced generators' methods (6fa334e7's 30, 76426b48, dbaa98ed, 3cb7f7c6) reject Unquarantined, which reject.jl:12
defines as a Julia-only definition not yet written, where the visitors of the same kind of gap reject Internal (tasks:
visit_yield_statement Internal, dbaa98ed's suspend-state helpers Unquarantined) (C6, D5). Fix: Internal everywhere, the
tests re-pinned (code_generator_sub.jl:42, :93, :120). (A55S13, medium) a rejecting stub counts as ported:
dev/src_progress.sh:40 `stubbed = Set(x.anchor for x in e if !x.ported)`, and `grep -n 'local ported = '
src/julia/parity.jl` gives `1135: local ported = !_is_macro(def, Symbol("@unported"))`, so the 110 bodies that only
reject (45 Internal, 65 Unquarantined) count as filled, as does 305549d5's visit_static_set, a body that only rejects
Unported at the setter where dart's :2199 translates the value and calls it (D40, D43). Fix: a third registry state for
a replaced definition, printed apart from ported and unported, its rejection generated from the Kernel row. (A55S14,
medium) two rulings in one range for a port Julia never reaches: 3cb7f7c6 replaced BrTableInfo's working port with
rejections because nothing reaches it, while dbaa98ed ported restore_this_and_context_chain (`grep -rn
"restore_this_and_context_chain(" src | grep -v @parity` prints nothing; its one dart caller,
restoreSuspendStateContext, rejects here) and 76426b48 InvocationCreationStubGenerator.generate (reached only past
make_invocation_creator_signature, which rejects), and dev/skeleton_scope.toml says codegen structures "are never out,
even where Julia's answer leaves them empty: they are ported" (C2, D5). Fix: the lead's one rule, applied to all three
and to A55S2. (A55S15, medium) 7573876b's speed fields hold Any: `sed -n 28p src/julia/late.jl` gives `value::Any # T
once assigned; held untyped so one compiled body serves every T`, LinkedHashMap's `_slots::Dict{Any,Int}`, and
`_late_get` has no return annotation; behavior is sound (reads typeassert), but C4 names Any only at heterogeneous
seams, and L215 reads ported structs alone. Fix: each an exact allowlisted seam (D20) with `_late_get` annotated, or the
typed form back. (A55S16, low) the 45 rejections name neither their Kernel row nor visitBlock's anchor, and copies
disagree (kernel.jl:146 FileUriExpression against code_generator.jl:1264) (D5, C9). (A55S17, low) 0a69fbb6's "a
must-throw call is Julia's MethodError throw" is wider than Julia's rule: verifytrim.jl:254–256 downgrades any
Union{}-typed unresolved call (`if extyp === Union{} warn = true`), which may throw the matched method's own exception
(C3, D3). Fix: the text as verifytrim states it; the payload from Julia's method table when visitThrow is ported.

stopgap in disguise: the hand-written rejection bodies, counted as ported until A55S13's state generates them from the
Kernel row.
precedent: the unreachable visitors, NoCounterpart's uninhabited type (no value reaches them by construction);
EqualsNull, dart's visitEqualsNull.

Area: enforcement and prose — 9d0cba81: dev/check.sh refuses outside a landing (`CHECK_LANDING=1`, set by ship under the
lock; a mark any shell can set, a stopgap against the accident it names), each green commit is pushed inside the
rebase's exec, and a red landing appends to wt-ship-failures.tsv with its outputs copied; sound. 70e23474 runs smoke's
compiled cases in node; c838733a crosses UInt32 and UInt64 as their bits' signed integer. 9d719901 is read above (its
fixes) and below. (A55E1, low) L227's lowering half leaves two doors: `unnamed_lowerings` flags only a new `:wt_bug` or
a lowered `:compiled` (parity_ratchet.jl:1979), so `:outside` relaxed to `:rejects` (from "must reject as Julia's
verifier says" to "anything located") needs no line; and dart_record_kinds reads a record only on one line (`grep -cE
'^\s*"dart_[^"]+" => \(' test/src/dart_tests.jl` and the full one-line pattern both give 820 today), so a record written
across lines leaves both sides' readings silently. Fix: `:outside` to anything but `:compiled` named, and the record
form checked (every `"dart_…" =>` line the pattern reads). The landing core stays the first case of each group, new
cases now compiled only by dev/corpus.sh: 9d719901 added 68 `:compiled` records no landing compiles. Requirements: C6
and D12 (A55S1, A55S10); C2 (A55S2, A55S14); C3 (A55S3, A55S17); C4 (A55S15); D40 and D43 (A55S13, A55S11); D5 (A55S6,
A55S12, A55S16); no lock fired inside its band.

Landing times: entry 54 landed at 2352 s from its first commit, its wait behind two port stacks included.

Resolution: this entry lands alone, prose only, and fixes nothing. A51E1, A51E4, A51E9, A53E2 and A53E3 are fixed by
9d719901; A51S4 by 977d5959; A51S5 by 129c5acf; A51S6 by 76341323; A51S10 by 1e9d7839; A51S11 by 762d5514; A51S15 by
6904535d; A51S16 by b412b1f4; A52S1 and A52E3 by 7d8f3e62; A54S3 by 3cb7f7c6; A51S7 is ruled by 0a69fbb6; A51S8, A51S9,
A51S13 and A54S1 are carried by A55S6, A55S8, A55S5 and A55S3; each leaves its row. A55S10 is fixed by b54115e0
(translator's, the cause d92bd5ee) and A55S11's located half by ebc68afe (the runtime library's anchors admitted),
dev/corpus.sh's run on b54115e0 to confirm both. A55S1 is what the range broke beside A55S10, the next fix of its lane.
A55S12, A55S16 and A55S17 are open on MARCH 1.D. A55S1, A55S2, A55S3, A55S4, A55S5, A55S6, A55S7 and A55S8 are open on
MARCH 1.C. A55S9 is open on MARCH 1.B. A55S11, its anchored-total half, A55S13 and A55S14 are open on MARCH 1.A6. A55S15
is open on MARCH 1.L. A55E1 is open on MARCH 1.T. By owner: the codegen lane holds A55S12, A55S16 and A55S17; the
translator lane holds A55S1 to A55S8; the lead holds A51E3 first, then A55S11's anchored total, A55S13, A55S14 and
A55S15; the tests lane holds A55E1; A55S9 the builder's owner.

## 2026-10-28 — audited through f7345c7b (f77d8b39..f7345c7b: the reached ccallables named and a repeated CodeInstance compared, the closure target and importer, the interop namer, modules, KernelNodes' getters, the JS runtime finalizer, the serializer's watch points, the cfe phase and dry run, Table, the record layout's rejections, makeArray, InstanceInvocation, EqualsCall, the closure visitors, the code generator's types and source map, no context, entry 55 and its correction, record constants at their fields' types, the runtime's anchors admitted, the void answer, four language directories, Throw, translateVariable, children at half their CPU, a six-commit landing, the progress line's replaced and gaps, NodeCounter, the inlining questions)

The fifty-sixth audit, beside the work, covers the 31 commits of f77d8b39..f7345c7b that are not entries 55 (ae190d59
and its correction 6927759d, its author's). The lead's named commits (9640ad5f, a8144598, 16ee0e2f, b54115e0, 517826a5,
fdd1567d, 502ca9ea, 963d9975) were read here; the other twenty by one read-only sub-auditor, each finding below re-run
here. Two Julia runs, each a probe under `taskpolicy -b` with an alarm, compiled a program and ran it through
test/runner.jl beside native (scratchpad eqprobe2.jl and eqprobe3.jl). Standing items. Corpus: `tail -1 wt-corpus.tsv`
gives `b54115e0 red 561 dart_closure/self_reference: Test Failed`, the fifth red head in a row, its first failure no
longer record_literal (A55S10's 45 no longer lead it); the landings beside it all went green, A51E3 (open on 1.L)
unchanged. Fixed in the range: A55S10 by b54115e0 (recorded), A55S13 by 16ee0e2f (`Fixes: A55S13`; A56E2 on what it
calls Julia's answer), A54E1 by 9640ad5f (`Fixes: A54E1`; children at half weight, A56E3), A54S2 by c4482fa7 (why the
reached ccallables, juliac's library precedent) and a64d7751 (a repeated CodeInstance with other code an Internal;
A56S6). A54S4 grows: 16ee0e2f writes the transparent macros a fourth time (`grep -n 'Symbol("@inline"),
Symbol("@noinline")' src/julia/parity.jl | wc -l` gives 4). Findings A56S1 to A56S8 and A56E1 to A56E3.

Area: builder — 9208ee42 ports dart's Table (table.dart:9) and _WithMutability (type.dart:1289) as the concrete classes
they are; 1ee696ba ports the serializer's watch points, reached only by tests (src/wasm_builder/ir/module.jl:101 still
rejects Unported at Module.serialize when one is set): sound as ports, the reachability A56S3's.

Area: collection and planning — b54115e0 instantiates a record constant's fields at its class's own field types (the
layout visitRecordLiteral builds, Julia's where dart's record class holds the top type), its case run beside native in
517826a5. (A56S3, medium) ports no call reaches, counted as ported, A55S2's defect again: `grep -rn
"interop_member_namer" src | grep -v "@parity"` gives the field (`translator.jl:143
interop_member_namer::Late{InteropMemberNamer}`), never an assignment, and one read, `compile.jl:313 local
js_runtime_finalizer = JS.RuntimeFinalizer(translator.interop_member_namer[])`, behind `!standalone`, while `grep -n
"standalone" src/julia/entry.jl` gives `27: options.translator_options.standalone = true`; so RuntimeFinalizer and its
generate (f2fa6c7f), InteropMemberNamer and its namers (5898a0d1), the cfe phase's error results and
CompilationDryRunError (61fd216b), SingleClosureTarget (9e31fe7e), make_array_from_expressions (b96aa762),
module_for_constant (9bc6e7bf), instantiate_constant_backend_use (df496774) and _initialize_context_locals (ef0161a4, a
silent `nothing`) are bodies no compile runs (C2). Fix: the lead's one rule (A55S14), each answered as Julia's or
reached. (A56S4, medium) 5898a0d1 leaves the export name computed twice: `grep -n "function get_export_name"
src/namer.jl src/functions.jl` gives namer.jl:106 and functions.jl:111, the same body, where dart's
FunctionCollector.getExportName delegates to the namer (functions.dart:68–69), and the port's _handle_exports reserves
no name (D5). Fix: delegate, delete the copy. (A56S6, low) a64d7751 compares `src.code == first_src.code` (`grep -n
"code == first" src/julia/nir.jl` gives :414), Vector{Any} `==`, where `isequal` is the identity of code (a NaN literal
rejects spuriously, a `missing` throws a TypeError), and no case reaches it (D12). (A56S7, low) `sed -n 261p
src/compile.jl` gives `options.dry_run && return CompilationDryRunSuccess()`: the dry run reports success without
running the stages, where dart's summarizer decides (C6). (A56S8, low) src/julia/entry.jl:20 says standalone because
"the JS runtime that loads a module is not yet ported", which f2fa6c7f ported (C9).

stopgap in disguise: A56S3's bodies, which cannot run and count toward src progress.
precedent: the record layout, Julia's own field types (class_info.jl); the reached ccallables, juliac's library build.

Area: emission and diagnostics — fdd1567d: visitThrow translates the exception as topTypeNonNullable and rejects at the
runtime's Error._throwWithCurrentStackTrace (`git show 898a1e4b:sdk/lib/_internal/wasm/common/errors_patch.dart | sed -n
19p` gives `static Never _throwWithCurrentStackTrace(Object object) =>`), dart's :2955 line for line; 502ca9ea's
translateVariable and initializeVariable match :702 and :842; 963d9975 answers NodeCounter by Julia's inliner (D3);
915f6b63 and 49155ae2 route a callee that carries fields and the closure visitors. (A56S1, high) a call Julia left to
Base's fallback `==` compiles to a reference comparison, a wrong answer: src/code_generator.jl:965 `if single_target_
!== nothing && single_target_.def === which(==, Tuple{Any,Any}) || …` emits `ref_eq` (146a516e), where the fallback is
`x === y`, Julia's egal, true for two immutable structs of equal fields; measured, `perl -e 'alarm 300; exec @ARGV'
taskpolicy -b julia --project=. --startup-file=no
/private/tmp/claude-501/-Users-daleblack-Documents-dev-GroupTherapyOrg-WasmTarget-jl/d67060e8-8b95-4213-b288-76d0f68067d8/scratchpad/eqprobe3.jl`
(struct Q; x::Int64; `q1 = Q(a); q2 = Q(a); (@noinline q1 == q2) ? 1 : 0`, its typed IR `invoke
Main.P.:(==)(%1::Main.P.Q, %2::Main.P.Q)::Bool`) printed `native: 1 runner: … "the module answers 0, native Julia 1; the
wasm-opt'd module answers 0, native Julia 1"` (C3, D9: the worst outcome, a module returning the wrong value). Fix: the
fallback goes through ==='s own lowering (the identical intrinsic, which rejects located for a type it does not cover)
until egal is ported, and the probe joins the corpus. (A56S2, medium) 915f6b63 routes an invoke of a constructor to
visitInstanceInvocation, an Internal: its arm reads `Base.issingletontype(dart_type_of(self, i.args[1])) ?
visit_static_invocation(…) : visit_instance_invocation(…)`, and a constructor's callee `Q` is a `Type{Q}`, no singleton
type, so the same probe with the constructors left as calls
(`/private/tmp/claude-501/-Users-daleblack-Documents-dev-GroupTherapyOrg-WasmTarget-jl/d67060e8-8b95-4213-b288-76d0f68067d8/scratchpad/eqprobe2.jl`,
`invoke Main.P.Q(a::Int64)::Main.P.Q`) printed `WasmTarget.Internal("dart2wasm/lib/translator.dart:1909
Translator.preciseThisFor: MethodInstance for Main.P.Q(::Int64), no instance member or constructor, has no `this`")`, an
Internal for a plain program (C6, D12). Fix: the callee's kind decides by what it is (a Type value is a constructor
call, Kernel's ConstructorInvocation or a static call), with this probe its case. (A56S5, low) 502ca9ea anchors the JS
embedding's runtime for a standalone compile: its rejections name
`sdk/lib/_internal/wasm/js_common/stack_trace_patch.dart:13` and `js_common/print_patch.dart:8`, while `git ls-tree -r
--name-only 898a1e4b sdk/lib/_internal/ | grep -iE "wasm.*(stack_trace|print)_patch"` lists
`wasm/standalone/print_patch.dart` and `wasm/standalone/stack_trace_patch.dart` (printToConsole at :9,
StackTrace.current at :15), the library a standalone compile links (C2). Fix: the standalone anchors.

stopgap in disguise: none new.
precedent: Throw, dart's visitThrow calling its runtime; NodeCounter, Julia's inliner (ssa_inlining_pass) deciding.

Area: enforcement and prose — a8144598 caps a landing at six commits, its oldest (the scratch worktree made at the
sixth), and narrows the failure record to the check's own red lines; sound. 032d5066's 220 cases are native answers,
none routing around Base. (A56E1, medium) the runner's void answer reads no wasm value: `grep -n "if (t === 'void')"
test/runner.jl` gives `169: if (t === 'void') return '-';`, the kind taken from native's answer's type, so an answer
inferred `Union{Nothing,T}` passes whenever native returns nothing, whatever the module returned (8988a847). Fix: '-'
only for undefined or null, any other value a failing answer. (A56E2, medium) 16ee0e2f calls an Unquarantined-only body
Julia's answer: its line counts `get(WasmTarget.REJECTION_ONLY, a, :body) in (:Internal, :Unquarantined)` as "one
rejection where Julia's answer replaces dart's construct", while `sed -n 12p src/julia/reject.jl` gives `A path reached
a Julia-only definition (src/julia/) not yet written`, a gap; and the range adds such bodies outside the code generator
(`git show 963d9975 -- src | grep '^+' | grep -o "reject!([A-Za-z]*" | sort | uniq -c` gives `24 reject!(Unquarantined`,
f7345c7b 3 more), A55S12's split now in translator.jl. Fix: the replaced count reads Internal alone once A55S12's one
kind lands everywhere, an Unquarantined counted a gap. (A56E3, low) 9640ad5f judges a stage at the larger of its
instructions at the rate and half its CPU seconds, so a child's work on a performance core counts half; the lead's
RUSAGE_CHILDREN follow-up (each test process printing its children's CPU at full weight) closes it. Requirements: C3 and
D9 (A56S1); C6 and D12 (A56S2, A56S6); C2 (A56S3, A56S5); D5 (A56S4); D40 and D43 (A56E2); D14 (A56E3); no lock fired
inside its band.

Landing times: entry 55 at 311 s and its correction inside D13's band (ship's median of the last five, 103 s).

Resolution: this entry lands alone, prose only, and fixes nothing. A55S13 is fixed by 16ee0e2f, A54E1 by 9640ad5f
(carried by A56E3), A54S2 by c4482fa7 and a64d7751 (carried by A56S6), each leaving its row. A56S1 and A56S2 are what
the range broke, the next fixes of the codegen lane. A56S1, A56S2 and A56S5 are open on MARCH 1.D. A56S3, A56S4, A56S6,
A56S7 and A56S8 are open on MARCH 1.C. A56E1 is open on MARCH 1.T. A56E2 and A56E3 are open on MARCH 1.L. By owner: the
codegen lane holds A56S1, A56S2 and A56S5; the translator lane holds A56S3 to A56S8 (A56S3 under the lead's rule,
A55S14); the tests lane holds A56E1; the lead holds A56E2, A56E3 and A51E3.

## 2026-10-29 — audited through 0a14e3a2 (f7345c7b..0a14e3a2: TFA's readers, moduleForConstant, the external storage types, the parameters to check, the corpus's red output kept, the Kernel-row rejections, the runtime's named definitions, DominanceFrontier and WebAssemblyExceptionInfo, the landing queue, the two unreached ports collapsed, the serializer's buffers, one Internal kind, the progress line's gaps, classForType, printKernel, the audit-55 S fixes, the exception sort regions, the interop namer, functions' replaced constructs, four language directories, the corpus in shards, EH pads, visitSymbolConstant, the egal fix, entry 56, PARITY_MASTER's dispatch line)

The fifty-seventh audit, beside the work, covers the 38 commits of f7345c7b..0a14e3a2 that are not entry 56 (88a6568d,
its author's), through the head the lead named. The LLVM exception pieces (532caafb, 8c0b4cd0, 568b5ccc) and the
translator and codegen commits were read by two read-only sub-auditors, each finding below re-run here; the enforcement
commits here. Standing items. Corpus: `tail -5 wt-corpus.tsv` gives `b54115e0`, `c6d48af5`, `8ebfc984` and `67a77afe`
red, each on `dart_closure/self_reference`, then `bd0b473a green` (a later head); each red run's kept output (c6d48af5's
wt-corpus-red-<head>.out) holds one failure, `its Unquarantined row "src/julia: an allocation of Core.Box leaving 1 of
its fields undefined" opens with no file of the repository or the pin` (A57E1). Fixed in the range, each re-read: A56S1
by 5c5407d6 (a sub-auditor's probe: the immutable pair now rejects at the identical intrinsic, two mutables and a
mutable against an immutable answer native's 0 in both modules), A56S4 by 9a2a58a8 (one get_export_name, names
reserved), A56E2 by 188dd968, A55S1 by 84edc2cb, A55S2 by f867fc62, A55S3 by 8550637d, A55S4 by c6da6a12, A55S5 by
28f81079, A55S6 by a33d791d, A55S8 by 6f597971, A55S9 by cc05321a, A55S12, A55S16 and A55S17 by 400a7cf0 (every replaced
definition's rejection generated from its Kernel row, all 45 names in KERNEL_TYPES), A55S14 by 14eeb665; carried: A56S3
by A57S6, A56S5 by A57S10. Still open: A56S2 (`grep -n issingletontype src/code_generator.jl` gives `486: (i::NirInvoke)
=> !Base.issingletontype(dart_type_of(self, i.args[1])) ? visit_instance_invocation(…)`), A56S6, A56S7, A56S8. Findings
A57S1 to A57S11, A57E1 and A57E2.

Area: builder — cc05321a gives each serializer its own f32 and f64 scratch buffers (A55S9). No finding.

Area: collection and planning — 9a2a58a8 makes the interop namer on every compile and names exports through it; a33d791d
decides a binding's constancy once (nir_binding_is_constant); 28f81079 hashes a mutable leaf by objectid, as === tells
it. (A57S5, medium) two facts computed twice beside their uncalled ports: `for f in type_of_parameter_variable
get_parameters_to_check; do grep -rn "$f(" src | grep -v '@parity' | wc -l; done` gives 0 and 0, while dart's
_setupLocalParameters calls getParametersToCheck (code_generator.dart:262) and translateTypeOfParameter calls
typeOfParameterVariable (translator.dart:2093); the ported callers compute inline (code_generator.jl:305's positional
list; translator.jl:1257 `translate_type_of_parameter(...) = translate_type(self, type_)`, is_required ignored) (D5,
C2). Fix: the callers through the ports, the inline copies deleted. (A57S6, medium) more bodies no compile runs, counted
as ported, carrying A56S3: the same grep gives 0 for index_list, get_list_length and translate_external_storage_type
(93bbcf05, 4734da5c), beside make_array_from_expressions, instantiate_constant_backend_use and
_initialize_context_locals; and RuntimeFinalizer is reached by a test alone, entry.jl:27 forcing standalone (C2). Fix:
reached, or Internal by the lead's rule. (A57S7, low) translate_external_type's docstring says dart's wasm classes "have
no Julia counterpart" while 4734da5c's is_wasm_type (translator.jl:903) names WasmArray, and dart's
translateExternalType gives a wasm array RefType.def over translateExternalStorageType (translator.dart:1252–1253) (C2,
C9). (A57S8, low) constants.jl:728 reads get_internalized_string_global for every non-standalone String constant, which
rejects Internal (translator.jl:1413, "no constant imports one"), a JS string import being a gap, not Julia's answer
(C6). (A57S9, low) kernel_nodes.jl:26, a comment line 4366f98a left running into the next (C9). (A57S11, low) two
@ccallable methods of one function share an export name (namer.jl:106 `string(method.name)`), and reserving it twice
rejects Internal (namer.jl:69), a user's error reported as WT's (C6).

stopgap in disguise: A57S6's bodies, which cannot run and count toward src progress.
precedent: an export's name, dart's interop namer (functions.dart:68); a mutable constant's identity, objectid.

Area: emission and diagnostics — 5c5407d6 compiles Base's fallback `==` to ref.eq only for two mutable operands, else
the method Julia resolved, its `===` at the identical intrinsic (A56S1, measured above); 400a7cf0 generates each
replaced definition's Internal from its Kernel row and states a Union{} call as verifytrim does. The exception pieces
are faithful at the pin: 532caafb's frontier is DominanceFrontierBase::analyze (DominanceFrontierImpl.h:77–159) and
recalculate, discoverAndMapException and getOutermostException match WebAssemblyExceptionInfo.cpp:53–171, LLVM's asserts
located rejections; 8c0b4cd0's getRegionFor, getBottom, isLoop and sortBlocks' checks match
WebAssemblySortRegion.cpp:17–80 and WebAssemblyCFGSort.cpp:303–378; 568b5ccc takes each handler from Julia's
compute_trycatch and may-throw from the absence of IR_FLAG_NOTHROW. (A57S1, high) the exception algorithms have no
model: `grep -n -i "pad\|exception" dev/formal/CFGStackify.tla` gives `76:(* No EH pads: try_table placement extends the
model when it is ported. *)`, and `git log --oneline f7345c7b..0a14e3a2 -- dev/formal` prints nothing, while the three
commits change the modeled sort and add DominanceFrontier and the exception tree (C8, D11: model first, with a Broken
variant). Fix: CFGStackify.tla with EH pads, exception discovery and exception sort regions, and a Broken variant TLC
rejects (a subexception followed by its successors instead of its frontier), before the next EH port. (A57S2, medium) a
`:leave` gets an unwind edge Julia never gives it: `git show 0a14e3a2:src/julia/machine.jl | grep -n
"handler_at\|nothrow"` gives `156: local h = handlers.handler_at[i]` and `157: (h == 0 || handlers.nothrow[i]) &&
continue`, so any statement without the nothrow flag unwinds, while inference treats `:leave` as control flow
(Compiler/src/abstractinterpretation.jl:4255–4257, `elseif isexpr(stmt, :leave) … @goto fallthrough`, never reaching
:4365's propagate_to_error_handler!) and stmt_effect_flags gives it no nothrow (optimize.jl:374); a block whose one
flagless statement is a `:leave` gains a spurious edge, changing dominators, frontiers and the exception (C3, D3; read,
not measured). Fix: inference's rule at its one source, control-flow statements excluded, with a case of a `:leave`
alone in its block. (A57S3, medium) at 0a14e3a2 an EH pad keeps Julia's virtual EnterNode edge, which LLVM's verifier
forbids: `git -C <llvm> show 7a941dfb:llvm/lib/IR/Verifier.cpp | sed -n 4837p` gives `Check(false, "EH pad must be
jumped to via an unwind edge", ToPad, TI);` and test/src/llvm_exception_info.jl:91 asserts `2 in mf.blocks[pad].preds`;
9be2abca, landed after this range ("an EH pad is reached only by unwinding"), reads as its fix, for the next entry to
confirm (C2). (A57S4, medium) the exception tests are hand-labelled synthetic pads: `git show
0a14e3a2:test/src/llvm_exception_info.jl | grep -n "ehpad = true"` gives :29, :38, :39, :55, pads reached by normal
edges, a shape LLVM never builds, their expected values hand labels, and the nested case's inner pad has an empty
frontier, so exception_info.jl:230's frontier-follow never runs (C2, D12). Fix: a case from LLVM's own exception tests
with a non-empty subexception frontier, and cases from real Julia try/catch IR. (A57S10, low) A56S5 now beside its fix:
code_generator.jl:441 and :1436 still name `js_common/` literals while 47e8946f's stack_trace_current and
print_to_console choose by target (D5). Fix: call them.

stopgap in disguise: none new.
precedent: the frontier and exception tree, LLVM's DominanceFrontierBase and WebAssemblyExceptionInfo at the pin; the
handler of a statement, Julia's compute_trycatch.

Area: enforcement and prose — d97450d0 queues lanes for the landing lock by ticket, oldest live first; c6d48af5 keeps a
red run's whole output; 8a7ecd5f runs the corpus in three shards, each checking its own groups' records; 0a14e3a2 states
no call is dispatched at run time, measured. (A57E1, medium) a `src/julia:` row reads unlocated: `grep -n
'isfile(joinpath(_DART_ROOT, file))' test/src/dart_tests.jl` gives :1033, and `isfile` of the directory `src/julia` is
false, so each of the 14 `Unquarantined("src/julia: …")` rows (`grep -rn 'Unquarantined("src/julia:' src | wc -l`) fails
a `:rejects` case that reaches it; the corpus was red four heads on exactly that line (above), and bd0b473a cleared the
one case by changing the code, not the check (C6). Fix: every Unquarantined row names its file (src/julia/<file>.jl),
the check then exact; or a directory of the repository admitted, with a plant. (A57E2, low) the coverage check no longer
covers a record whose group is gone: dart_tests.jl:1135 keeps only `keys(DART_CASES) if first(split(k, '/')) in
_DART_SHARD_GROUPS`, a set of the groups the corpus defines (:1100), so a record of a removed or misspelt group is
checked by no shard, and not by the landing either, where the old `setdiff(keys(DART_CASES), seen)` failed it (C9). Fix:
the unsharded run (the landing) checks every record against every group. Requirements: C8 and D11 (A57S1); C3 and D3
(A57S2); C2 (A57S3, A57S4, A57S6); D5 (A57S5, A57S10); C6 (A57E1, A57S8, A57S11); no lock fired inside its band.

Resolution: this entry lands alone, prose only, and fixes nothing. A56S1 is fixed by 5c5407d6, A56S4 by 9a2a58a8, A56E2
by 188dd968, A55S1 by 84edc2cb, A55S2 by f867fc62, A55S3 by 8550637d, A55S4 by c6da6a12, A55S5 by 28f81079, A55S6 by
a33d791d, A55S8 by 6f597971, A55S9 by cc05321a, A55S12, A55S16 and A55S17 by 400a7cf0, A55S14 by 14eeb665; A56S3 and
A56S5 are carried by A57S6 and A57S10; each leaves its row. A57S1, A57S2, A57S3, A57S4 and A57S10 are open on MARCH 1.D.
A57S5, A57S6, A57S7, A57S8, A57S9 and A57S11 are open on MARCH 1.C. A57E1 and A57E2 are open on MARCH 1.T. By owner: the
stackify lane holds A57S1 to A57S4; the codegen lane holds A57S10 and A56S2; the translator lane holds A57S5 to A57S9
and A57S11; the tests lane holds A57E1 and A57E2.

## 2026-10-29 — audited through a302f567 (0a14e3a2..a302f567: a partial allocation's null fields, EH pads reached by unwinding, autoship, placeTryTableMarker, getTearOffType, isequal for a repeated CodeInstance, entry 57, why standalone, ConstantHash, the vector reader, four language directories, the pragma readers, the dry run rejecting, the generator's stubs, NirHandoff retiring ClosedWorld and NirBuild, L227 reading records by Julia's parser)

The fifty-eighth audit, beside the work, covers the 17 commits of 0a14e3a2..a302f567 that are not entry 57 (a86583e4,
its author's), read here. Every finding rests on one exact command, quoted; one probe ran under `taskpolicy -b` with an
alarm
(/private/tmp/claude-501/-Users-daleblack-Documents-dev-GroupTherapyOrg-WasmTarget-jl/d67060e8-8b95-4213-b288-76d0f68067d8/scratchpad/undefprobe.jl),
and TLC ran both new models. Standing items. The new models break as they claim: `TLC_ONLY=… perl -e 'alarm 500; exec
@ARGV' taskpolicy -b bash dev/formal/run_tlc.sh` over MCConstantHash*.cfg and MCNirHandoff*.cfg printed `ok
MCConstantHash.cfg … 16 distinct states`, `violation of StableKeys`, `violation of FirstValuesTell`, `violation of
Bounded` for its three Broken instances, and `ok MCNirHandoff.cfg … 2640 distinct states` with `violation of
CcallablesJudged`, `OneBodyPerCI`, `QueuedReached`, `RejectsOnlyGaps`, `Aligned` and `RepeatAsserted` for its six, each
the claim its `\* expect:` line names, which run_tlc.sh requires. Fixed in the range: A57S3 by 9be2abca (an EH pad
reached only by unwinding; the test's `2 in mf.blocks[pad].preds` is gone), A56S6 by 1b7df1f2 (isequal), A56S7 by
535bf084 (the dry run rejects Internal), A56S8 by 63eec7b5, A55E1 by a302f567 (records read by Julia's parser, kinds
ranked, so `:outside` to `:rejects` and a multi-line record count), and part of A56S3 (carried by A57S6) by dd4d1a30.
Still open: A57S1, which the range deepens (b16f76c5 ports placeTryTableMarker and `git log --oneline 0a14e3a2..a302f567
-- dev/formal` lists only 28b3e541 and e756e711, neither an exception model); A57S2 (`grep -n "handler_at\|nothrow"
src/julia/machine.jl` gives `177: local h = handlers.handler_at[i]` and `178: (h == 0 || handlers.nothrow[i]) &&
continue`); A57S4 (the tests' `ehpad = true` at :29, :38, :39, :55); A56S2. Findings A58S1.

Area: builder — empty by diff for src/wasm_builder in the range's src (b16f76c5's try_table opcodes come with 9be2abca,
read below).

Area: collection and planning — 1b7df1f2 compares a repeated CodeInstance's code by isequal; dd4d1a30 answers
getTearOffType and rejects SingleClosureTarget._ and moduleForConstant Internal; b39a28ab reads `@inline`, `@noinline`
and a ccallable's or the entry's name as dart's pragma readers answer, the namer's own copy of the export rule deleted
(D5); e756e711 retires WT1's ClosedWorld and NirBuild models with their code. No finding.

stopgap in disguise: none new.
precedent: the closed world's handoff, Julia's trim inference and compute_basic_blocks, modeled by NirHandoff; the
constant key's hash, ===, modeled by ConstantHash.

Area: emission and diagnostics — 9be2abca makes an EH pad reachable only by unwinding and starts it with a CATCH;
b16f76c5 places each try_table at the nearest common dominator of its pad's unwind predecessors, inside the block its
catch clause branches to (WebAssemblyCFGStackify.cpp:695). (A58S1, high) bd0b473a makes an undefined field read as
`nothing`: an allocation that leaves fields past Julia's initialized count now pushes their null references, and
WasmTarget's `nothing` is the null reference, while _direct_get reads the field with no check (`struct_get`,
code_generator.jl's _directGet); measured, `perl -e 'alarm 400; exec @ARGV' taskpolicy -b julia --project=.
--startup-file=no
/private/tmp/claude-501/-Users-daleblack-Documents-dev-GroupTherapyOrg-WasmTarget-jl/d67060e8-8b95-4213-b288-76d0f68067d8/scratchpad/undefprobe.jl`
(`mutable struct M; x::Any; M() = new(); end; f(a) = (m = M(); y = m.x; y === nothing ? a : a + 100)`, typed IR `%1 =
%new(Main.P.M)`, `%2 = builtin Base.getfield(%1, :x)::Any`) printed `native: UndefRefError` and `wasm: … "the module
answers 3"`: where Julia throws, the module answers as though the field held nothing (D9: a plausible value past a gap;
C6). Core.Box, the case bd0b473a fixed, is guarded by Julia's own `isdefined` before each read; a struct whose inner
constructor leaves a field undefined is not. Fix: a read of a field past Julia's initialized count checks it, as Julia's
getfield does (`ref.is_null` then the UndefRefError throw, rejecting at the runtime's throw until it is ported), or the
partial allocation rejects until that check exists; the probe joins the corpus.

stopgap in disguise: none new.
precedent: a field past the initialized count, Julia's datatype_min_ninitialized; the try_table, LLVM's
placeTryTableMarker at the pin.

Area: enforcement and prose — 9cf4d2eb and 5b3439da land a lane's settled commits through dev/ship.sh's queue, a red
HEAD not shipped again until it moves; a302f567 closes A55E1 by Julia's parser; 7801e028 reads a vector leaf by leaf;
28b3e541 and e756e711 add two models whose Broken instances each violate their named claim (above). No finding.
Requirements: D9 and C6 (A58S1); C8 and D11 (A57S1, still open); no lock fired inside its band.

Resolution: this entry lands alone, prose only, and fixes nothing. A57S3 is fixed by 9be2abca, A56S6 by 1b7df1f2, A56S7
by 535bf084, A56S8 by 63eec7b5 and A55E1 by a302f567, each leaving its row. A58S1 is what the range broke, the next fix
of the codegen lane. A58S1 is open on MARCH 1.D. By owner: the codegen lane holds A58S1 and A56S2; the stackify lane
holds A57S1, A57S2 and A57S4.

## 2026-10-29 — audited through ff811421 (a302f567..ff811421: a partial allocation rejecting at the runtime's late-error throw, the unwind-mismatch finders, one autoship loop per lane, ValueClasses, RecordLayout and LateCell, purity from Julia's effects, the Kernel table's Type parameters, the runtime's anchors under sdk/, entry 58, the void answer read, ship and autoship by patch, one list of transparent macros, translateExternalType's wasm array)

The fifty-ninth audit, beside the work, covers the 14 commits of a302f567..ff811421 that are not entry 58 (a0573e28, its
author's), read here. Every finding rests on one exact command, quoted; one probe ran under `taskpolicy -b` with an
alarm, and TLC ran the three new models. Standing items. The new models break as they claim: `TLC_ONLY=… taskpolicy -b
bash dev/formal/run_tlc.sh` printed `ok MCRecordLayout.cfg … 441 distinct states` with `violation of EqualIsLayout`,
`OpenRejects` and `IndexIsPlace`; `ok MCValueClasses.cfg … 1880 distinct states` with `violation of ValuesCovered`,
`NothingExtra`, `FieldsClosed`, `Once` and `SupertypeClosed`; and `ok MCLateCell.cfg … 43 distinct states` with
`violation of OneInitAtATime`, `NoDefaultRead`, `InitAtMostOnce`, `Stable` and `RejectsOnlyMisuse`, each its expect
line's claim. Fixed in the range: A58S1 by e8bafd28, measured: `perl -e 'alarm 400; exec @ARGV' taskpolicy -b julia
--project=. --startup-file=no
/private/tmp/claude-501/-Users-daleblack-Documents-dev-GroupTherapyOrg-WasmTarget-jl/d67060e8-8b95-4213-b288-76d0f68067d8/scratchpad/undefprobe.jl`
now prints `native: UndefRefError` and `wasm:
WasmTarget.RejectionError(WasmTarget.Unported("sdk/lib/_internal/wasm/common/error_utils.dart:188
_throwLateErrorLocalNI"), "… an allocation of Main.P.M leaving 1 of its fields undefined …")`, a located gap where it
answered 3, its anchor right at the pin (`Never _throwLateErrorLocalNI(String fieldName) {`); A54S4 by 4f6e871c (`grep
-n 'Symbol("@inline"), Symbol("@noinline")' src/julia/parity.jl | wc -l` gives 1, the const _TRANSPARENT_MACROS every
reader reads); A56E1 by a54bd0f6 (a void answer must be undefined or null, any value a difference); A57S7 by ff811421.
Still open and deeper: A57S1 (3156199a ports fixCallUnwindMismatches and fixCatchUnwindMismatches, and `git log
--oneline a302f567..ff811421 -- dev/formal` lists only the three models above, none of exceptions) and A57S2 (`grep -n
"nothrow" src/llvm/utilities.jl` gives `16: return any(i -> !mf.handlers.nothrow[i], first_:last_)`:
WebAssembly::mayThrow reads the same flag rule, so a `:leave` may throw there too). A57S4 and A56S2 unchanged. Findings
A59S1.

Area: builder — empty by diff (`git diff --stat a302f567..ff811421 -- src/wasm_builder` prints nothing).

Area: collection and planning — 264df44f names a runtime anchor's file under the checkout's sdk/ where parse_anchor had
joined it under pkg/; 4f6e871c reads one list of the macros a definition stands under; 5f6f6656 answers
hasWasmPureFunctionPragma by Julia's proof, `is_removable_if_unused` of the body's decoded `ipo_purity_bits` (D3);
ec803969 and 89a209e7 take the Kernel table's Type and say why each narrows; ff811421 gives a wasm array its elements'
boundary type, as is_wasm_type names. No finding.

stopgap in disguise: none new.
precedent: purity, Julia's effect analysis (is_removable_if_unused); the closed world's classes, a record's shape and a
late cell, modeled by ValueClasses, RecordLayout and LateCell.

Area: emission and diagnostics — 3156199a ports fixCallUnwindMismatches (WebAssemblyCFGStackify.cpp:1592),
splitEndLoopBB (:1556) and fixCatchUnwindMismatches (:2076), mayThrow and findCatch (WebAssemblyUtilities.cpp:41, :149),
each Julia catch LLVM's catch-all, addNestedTryTable (:1383) rejecting Unported until ported. (A59S1, low) e8bafd28
folds two impossible allocations into the gap: `git show e8bafd28 -- src/code_generator.jl | grep '^-' | grep -n
"Internal"` gives the deleted `given <= length(fields) || reject!(Internal(…))` and `given >=
Core.Compiler.datatype_min_ninitialized(cls) || reject!(Internal(…))`, so a `new` with more values than fields, or fewer
than Julia's own initialized count, neither of which Julia's IR produces, now rejects Unported at _throwLateErrorLocalNI
as a gap; and its text calls a Core.Box read before assignment Julia's UndefRefError, where Julia's lowering guards that
read with `isdefined` and throws UndefVarError (C6). Fix: the two Internal checks back before the gap's rejection, the
text Julia's.

stopgap in disguise: none new.
precedent: the unwind mismatches, LLVM's fixCallUnwindMismatches and fixCatchUnwindMismatches at the pin; a read before
assignment, dart's _throwLateErrorLocalNI.

Area: enforcement and prose — e5507348 keeps one autoship loop per lane, its pid in the common dir's wt-autoship/<lane>;
dabce89b counts a lane's work by `git cherry` (a commit another ship carried as the same patch is not ahead, and ship
exits with nothing to land rather than red); sound. Requirements: C6 (A59S1); C8 and D11 (A57S1, still open); no lock
fired inside its band.

Resolution: this entry lands alone, prose only, and fixes nothing. A58S1 is fixed by e8bafd28, A54S4 by 4f6e871c, A56E1
by a54bd0f6 and A57S7 by ff811421, each leaving its row. A59S1 is open on MARCH 1.D. By owner: the codegen lane holds
A59S1 and A56S2; the stackify lane holds A57S1, A57S2 and A57S4.

## 2026-10-29 — audited through 7c3b49e4 (ff811421..7c3b49e4: the bounds-check flag, try regions in wasm, the try statements' Kernel rows, the JS string global, a check only in a landing, String over UTF-8 code units, StaticFieldInit, the runtime's gaps counted, the lazy static field, addNestedTryTable, shared export names, four corpus shards, the Reshaped and field exemptions and their skeleton checks, String's data operations, the parameter ports, the switch structs, ExceptionInfo, an empty commit, four language directories, a closure's this, the replaced generators as structs, visitTypeLiteral, :unread, the overlay method table, lanetest, the runtime section, instantiateTypeParameter, the interpreter's inference and its revert)

The sixtieth audit, beside the work, covers the 40 commits of ff811421..7c3b49e4 that are not entry 59 (aca8c7a7, its
author's), read here. Every finding rests on one exact command, quoted; TLC ran the two new models; the per-file timing
of the src tests the lead asked for did not finish (`perl -e 'alarm 1500; exec @ARGV' taskpolicy -b julia --project=.
--startup-file=no test/src_tests.jl` ended at its alarm, exit 142, on the efficiency cores) and moves to entry 61; the
range's growth by lines (`for f in $(git ls-files test/src | grep '\.jl$'); do …; done` against f77d8b39) is largest in
test/src/code_generator.jl (+177), llvm_exception_info.jl (+162, new), dart_tests.jl (+88) and constants.jl (+67). The
lead reports wt3-tests' harness self-audit, its findings a, b, c and e in hand; entry 61 reads their fixes. Standing
items. The models break as claimed: `TLC_ONLY=… taskpolicy -b bash dev/formal/run_tlc.sh` printed `ok
MCStaticFieldInit.cfg … 56 distinct states` with `violation of NoPlaceholderRead` and `ReadsTruth`, and `ok
MCExceptionInfo.cfg … 47616 distinct states` with `violation of MapInnermost`, `ParentInnermost` and `BlocksDominated`,
each its expect line's claim. Fixed in the range: A59S1 by 08546acd (`git show 7c3b49e4:src/code_generator.jl | grep -n
"datatype_min_ninitialized"` gives :1251 `given >= Core.Compiler.datatype_min_ninitialized(cls) ||
reject!(Internal(…))`, and the gap's text names UndefVarError for a Core.Box read), A57S5 by 52cce972
(typeOfParameterVariable and getParametersToCheck each one caller now), A57S8 by 5cd16654; 5cd16654's subject also names
A57S5 and A57S2, which it does not touch. Still open: A57S2 (`git show 7c3b49e4:src/julia/machine.jl | grep -n
"handlers.nothrow\[i\]"` gives :197), A57S4 (four synthetic `ehpad = true`), A56S2 (`… | grep -n
"issingletontype(dart_type_of"` gives :754). Findings A60S1, A60E1 and A60E2, and A57S1's state.

The exemptions (the lead's order, from this entry on): `git diff ff811421..7c3b49e4 -- src | grep -E
'^\+.*(Reshaped:|Fields with no Julia counterpart)'` lists six field exemptions and ten reshapes, each judged:
closures.jl:90 `procedureAttributeMetadata`, `visitedConstants` (TFA's metadata is Julia's inference, the NIR no
constant tree), record_class_generator.jl:14 the record class generator's `coreTypes` to `objectToStringProcedure` (no
record class is generated, a tuple type being Base's), :27 `constantCache` (a NirConst holds no tree), types.jl:107 and
:128 `typeEnvironment` (Julia's subtype test takes no environment): each concrete and true. Reshaped: the five
FunctionCollector `target`s, MethodInstance or the binding's GlobalRef (4e8220b9: the Kernel table has no Reference row
for a static initializer), the two `init`s (a NirConst, an absent one dart's DummyValueConstant), the closures'
`arguments` (keyword names in the NamedTuple operand's type), the parameter `node` (member and position), and the five
type tests' `testedAgainstType`/`type` (any constant Julia type a class-id range check covers, under the lead's ruling
R2): each concrete and true, none a gap disguised.

Area: builder — empty by diff (`git diff --stat ff811421..7c3b49e4 -- src/wasm_builder` prints nothing).

Area: collection and planning — d87bdf22 and its two data-operation commits make a String dart's string class over
Julia's UTF-8 code units (Dale's choice B), its precedent dart2wasm's earlier OneByteString, unanchored as the shallow
pin allows; 4e8220b9 the lazy static field keyed by the binding, StaticFieldInit its model; 52cce972 routes the
parameter facts through their ports; a230adc6 inferred the closed world over WasmTarget's interpreter with a copy of
Julia's verifier changed in one place, reverted by 7c3b49e4 for its load cost. (A60E1, medium) the overlay table stays
with no reader, and its precompile workload runs in every package image: `grep -rn
"WasmInterpreter\|METHOD_TABLE\|WasmMethodTable" src | grep -v src/julia/interpreter.jl` finds no reader, while `grep
-rn "precompile_interpreter" src` gives `src/WasmTarget.jl:66 precompile_interpreter()`, whose body
(interpreter.jl:120–123) runs `check_subset(…)` while the image is written, so each src change's load stage pays an
inference the reverted reader no longer needs (the lead measured the revert's check at 24 CPU-s of load against about 12
before a230adc6) (D14, C9). Fix: the workload leaves with the reader and returns with it, made lazy as the re-land
plans. (A60S1, low) 6cd77cec adds `shared_export_name` to TrimErrorKind (reject.jl:52), whose docstring says each member
is a description Julia's verifier carries, and reports it as OutsideSubset, "Julia's trim verifier rejects the program":
two exports of one name is WasmTarget's judgment of juliac's linking, not the verifier's (C3, C6). Fix: its own
rejection naming the rule, or the verifier's kinds kept the verifier's.

stopgap in disguise: none new.
precedent: the overlay method table, GPUCompiler's GLOBAL_METHOD_TABLE and GPUInterpreter; String, dart's string class
with its code units, Julia's layout.

Area: emission and diagnostics — b107ca36 answers the bounds-check flag as Julia's codegen does (the process's
--check-bounds, else the statement's argument, which Julia's adjust_boundscheck! fills on inlining:
inlining.jl:351–358); 2db99073 lowers try_table, catch and the exception-edge values (Julia's emit_upsilonnode the
precedent), no test throwing yet since throw is unported; c1038d02 and 08546acd answer the try statements and the switch
structs by their Kernel rows. A57S1, high, now in part: 8a728e50 models WebAssemblyExceptionInfo (recalculate,
discoverAndMapException, getOutermostException), but 4342aac4 lands addNestedTryTable, getTrampolineBlock,
cleanupFunctionData and the successor edits (WebAssemblyCFGStackify.cpp:1383, :1312, :2686), with placeTryTableMarker
(b16f76c5) and the unwind-mismatch finders (3156199a) before it, and `git log --oneline ff811421..7c3b49e4 --
dev/formal` lists only fa9e9d72 and 8a728e50: the try placement, the mismatch fixes and the exception sort regions have
no model, and 4342aac4 shipped after the order to model first (C8, D11). Fix: CFGStackify.tla extended over EH pads,
try_table placement and the mismatch fixes, with Broken variants, before the next EH commit.

stopgap in disguise: none new.
precedent: the exception tree, WebAssemblyExceptionInfo at the pin, now modeled by ExceptionInfo; the nested try_table
and its trampolines, LLVM's addNestedTryTable.

Area: enforcement and prose — d7a38c1b refuses a hand run of the whole suite outside background QoS; 18208f07 runs the
corpus in four shards (918 s against its 1200-s limit); 17113f35 lands no empty commit; 6e6db6ec adds `:unread` for a
compiled case holding a fact the runner does not marshal; a1fadf69, b9a54031, ae7a98ab and a5e89d25 give the skeleton's
checks the two exemption forms judged above. (A60E2, low) lanetest takes a performance-core slot by the landing's state
at its start alone: `grep -n "busy" dev/lanetest.sh` shows the lock test before the slot is taken and none after, so a
run started before a landing keeps its performance core through the landing's check for up to its 900-s limit, the
check's four processes then sharing four cores with it (D31). Fix: a lane run yields its slot when a landing's check
starts (re-niced to background QoS), or waits for none. Requirements: C8 and D11 (A57S1); D14 and C9 (A60E1); C3 and C6
(A60S1); D31 (A60E2); no lock fired inside its band.

Resolution: this entry lands alone, prose only, and fixes nothing. A59S1 is fixed by 08546acd, A57S5 by 52cce972 and
A57S8 by 5cd16654, each leaving its row. A60E1 and A60E2 are open on MARCH 1.L. A60S1 is open on MARCH 1.C. By owner
(the lead's of this morning): the EH model's owner, wt3-translator, holds A57S1 and A57S2; wt3-cgstubs holds
code_generator.jl's A56S2 and A57S4's tests; the translator lane holds A60S1; the lead holds A60E1 (with wt3-constants'
re-land) and A60E2.

## 2026-10-29 — audited through e017e6c9 (7c3b49e4..e017e6c9: located Unquarantined rows and whole-group coverage, a native throw wanting a wasm exception, measured shards, SIMD lanes, a tuple's class by inference, CFGStackifyEH, :leave and return sending no exception, the exception tree from LLVM's tests, a String immutable by convention, the static-field generators, the runtime's file map, module __init__ and session values, no interpreter workload, FieldSelectorTable, smoke's throws, the try_table's marker class, MemoryLimits, guardCanMatchJSException, errorThrow, nir_carries_data, Symbol, checked division, a constructor with no receiver, the corpus's hung shards, entry 60)

The sixty-first audit, beside the work, covers the 44 commits of 7c3b49e4..e017e6c9 that are not entry 60 (75abac23, its
author's), read here. Every finding rests on one exact command, quoted; three probes ran under `taskpolicy -b` with an
alarm, and TLC ran the exception models. Standing items. Timing (the lead's watch point): each green check now keeps
every src file's seconds (cd3f191b), and `sort -t$'\t' -k2 -rn "$(git rev-parse --git-common-dir)/wt-src-costs.tsv" |
head` gives `code_generator.jl 40.9`, `code_generator_control.jl 36.2`, `code_generator_intrinsics.jl 33.3`, then
`runner.jl 5.7`, `wasm_builder/ir_modules.jl 5.0`, `translator.jl 4.3`, `records.jl 4.3`, of 171 s in all (`awk …
{s+=$2}`): the code generator's three files hold 110 s, nearly two thirds, and the largest of them alone is a 41-s shard
of the four; code_generator.jl is also the fastest-growing by lines (+177 over audit 60's window). A one-by-one rerun at
background QoS was stopped as the table answers the same question with the check's own measure. The exception models
break as claimed: `TLC_ONLY=… taskpolicy -b bash dev/formal/run_tlc.sh` over MCCFGStackifyEH*.cfg and
MCCFGStackifyPad*.cfg printed `ok MCCFGStackifyEH.cfg … 623 distinct states`, its twelve Broken instances each violating
its expect line's claim (EveryBlockOnce, CatchDepthCorrect, DepthCorrect, NoAssertion, PadsOnlyUnwound,
UnwindEdgesExact, UnwindPreserved three times, WellNested twice, PathsPreserved), `ok MCCFGStackifyPad.cfg … 9096` and
`ok MCCFGStackifyPadWitness.cfg … 196` with its three. Fixed in the range: A57S1 by 1970ead7 and fe7ad6c6 (the models
above, after the code, which C8 orders the other way), A57S2 by 89856afa (a `:leave` and a return send no exception,
inference's rule), A57S4 by c7f93a0b (LLVM's own TEST0 and TEST1 at the pin and Julia's try/catch IR), A56S2 by e0e9a2c0
(nir_carries_data, `!(Base.issingletontype(T) || Core.Compiler.isconstType(T))`, the one receiver test; `grep -rn
issingletontype src` now gives classes.jl:180 and that line alone) with 0ac26385's case run against native, A60E1 by
3df75cae, A57E1 and A57E2 by 05521f8b, A50S1 by a1fadf69 and b54dbc1a (MemoryLimits' readers in scope, answering no
annotation). Exemptions (the lead's order): `git diff 7c3b49e4..e017e6c9 -- src | grep -E '^\+.*(Reshaped:|Fields with
no Julia counterpart)'` lists ten: makeArrayOf's `elementType` (a UnionAll where dart's is an InterfaceType), the
FunctionCollector and translator `target`s and `reference`s and modules.jl's `reference` (MethodInstance or the
binding's GlobalRef, the Kernel table having no Reference row for a static initializer), the namer's `coreTypes` reshape
and its two `coreTypes` fields (:72, :107: the closed world stands for Kernel's core types), and runtime_generator.jl's
`_coreTypes` (:55: it serves only JS interop annotations, which a Julia method carries none of): each concrete and true,
none a gap disguised. 2e9ead2f landed as `wip`, a subject naming nothing, superseded by e0e9a2c0; the hook refusing such
a placeholder (92b1496f) is not on wt2 (`git log --oneline origin/wt2 | grep -c "^92b1496f"` gives 0). Findings A61S1 to
A61S4 and A61E1.

Area: builder — empty by diff (`git diff --stat 7c3b49e4..e017e6c9 -- src/wasm_builder` prints nothing).

Area: collection and planning — e0e9a2c0 makes one test of whether a callee carries data, Julia's codegen's (a singleton
type or a constant `Type{X}` passes no value), and removes 2e9ead2f's Type{C}-to-C receiver; acb9a9ed lays out a Symbol
as dart's Symbol class, one `_name::String`; 9577e682 takes a tuple statement's class from Julia's tuple inference;
b54dbc1a answers MemoryLimits' readers by util's get_pragma. 310a3a84 starts a binding at its session value under
dev/MODULE_INIT.md's ruling (the session has run every `__init__`, juliac's heap after startup). (A61S4, low) the ruling
equates the session's heap with juliac's after startup, which holds only until program code runs in the session:
dart_tests.jl and the runner run each case natively before and after its compile, so a binding the program writes would
start at the written value; today no such binding compiles, `perl -e 'alarm 400; exec @ARGV' taskpolicy -b julia
--project=. --startup-file=no
/private/tmp/claude-501/-Users-daleblack-Documents-dev-GroupTherapyOrg-WasmTarget-jl/d67060e8-8b95-4213-b288-76d0f68067d8/scratchpad/sessionprobe2.jl`
(`counter::Int64 = 0; bump(x) = (global counter += x; counter)`, bumped natively once) printing
`Unported("dart2wasm/lib/code_generator.dart:4937 StaticFieldImplicitAccessorCodeGenerator._generateGetter")`, but
dev/MODULE_INIT.md's "Known deviation from juliac" names only values an `__init__` derived from the host (C3). Fix: the
deviation named in the ruling, and a binding the program writes compiled from its post-`__init__` value or rejected,
before the getter is wired.

stopgap in disguise: none new.
precedent: a callee with no value, Julia's codegen's ghost and constant-type arguments; a binding's start, juliac's heap
after its startup's `__init__`s (dev/MODULE_INIT.md).

Area: emission and diagnostics — 8eefd0d5 and 7301ac6c are the first runtime throws: checked division raises DivideError
through the runtime's thrower, Error._throw an intrinsic throwing the program's tag (intrinsics.dart:3449), as Julia's
codegen checks (src/intrinsics.cpp), never a trap; 18180f8d's guardCanMatchJSException is dart's standalone arm. (A61S1,
medium) a binding's read rejects at a definition a5d3192e ported: `grep -n "4937
StaticFieldImplicitAccessorCodeGenerator._generateGetter" src/code_generator.jl` gives `1517: reject!(Unported(…
_generateGetter)` in visit_static_get and `2209: @parity "…:4937
StaticFieldImplicitAccessorCodeGenerator._generateGetter" function _generate_getter(…)`, a5d3192e's port, which no read
calls, so the probe above rejects as a gap at a definition that is written (C6, C9). Fix: visit_static_get calls the
binding's getter as dart's visitStaticGet does, or names the real gap. (A61S2, low) 355c70e5 ports
EagerStaticFieldInitializerCodeGenerator, whose own message says DartGlobals makes it "only for the pragma that
initializes a field at startup, and no Julia binding carries it", a body no compile reaches, driven only by its test
(C2, A55S14's rule). Fix: its Internal naming Julia's answer.

stopgap in disguise: none new.
precedent: a checked division's throw, Julia's emit_checked_srem_int and its siblings; the thrower, dart's Error._throw.

Area: enforcement and prose — 05521f8b makes an Unquarantined row name a file and checks each record's group whole;
eb85ab48 and 0fe7aed8 make a native throw want a wasm exception, a trap or a return each a named failure; cd3f191b
splits the four src shards by measured cost; e017e6c9 kills a hung corpus run's shards. (A61E1, medium) the runner's
throw verdict reads neither the tag nor the exception: `sed -n 156,159p test/runner.jl` gives `its module must raise a
wasm exception (WasmTarget's exception tag, a WebAssembly.Exception in JS) … The exception's type is not read yet: its
class id needs an exported reader the runtime has not ported`, and the script tests `e instanceof WebAssembly.Exception`
(:275), so a module raising the wrong Julia exception, or one of another tag, passes where native threw DivideError (a
weakened comparison, D9). Fix: the tag exported and matched (`e.is(tag)`), the class id read once the reader is ported,
until then the gap on a row. (A61S3, medium) the two EH models write one algorithm twice: `grep -n "^PlaceTry"
dev/formal/CFGStackify.tla dev/formal/CFGStackifyEH.tla` gives `CFGStackify.tla:442: PlaceTry(st, i) ==` and
`CFGStackifyEH.tla:330: PlaceTryTable(st, i) ==`, and each carries fixCallUnwindMismatches's walk (`grep -n "Mismatch"`
gives CFGStackify.tla:623 and CFGStackifyEH.tla:435), while 389bcd93 divides only their claims (contiguity and exactness
here, placement and routing there): two specifications of the try placement and the mismatch walk can drift apart as two
copies of code do (D5, C8). Fix: one module defining the placement and the walk, which both instances EXTEND.
Requirements: C6 and C9 (A61S1); C2 (A61S2); D5 and C8 (A61S3); C3 (A61S4); D9 (A61E1); no lock fired inside its band.

Resolution: this entry lands alone, prose only, and fixes nothing. A57S1 is fixed by 1970ead7 and fe7ad6c6, A57S2 by
89856afa, A57S4 by c7f93a0b, A56S2 by e0e9a2c0, A60E1 by 3df75cae, A57E1 and A57E2 by 05521f8b, A50S1 by a1fadf69 and
b54dbc1a, each leaving its row. A61S1 and A61S2 are open on MARCH 1.D. A61S4 is open on MARCH 1.C. A61S3 is open on
MARCH 1.A6. A61E1 is open on MARCH 1.T. By owner: wt3-cgstubs holds A61S1 and A61S2; the EH model's owner,
wt3-translator, holds A61S3; the lead holds A61S4 (dev/MODULE_INIT.md); the tests lane holds A61E1.

## 2026-10-29 — audited through 98481e33 (e017e6c9..98481e33: the code generator's tests in three files, the new dependency's image outside the judged load, getPragma the one source, the parameter Any rule, WasmInterpreter a package of its own, src/patch, unimplemented never reached, String's internalized global, the hard limit per case, the Kernel table's Reference sum, the static field's getter and setter called, Error._throw on Any, the exception tag exported, StackifyTry, String's operations, convertType boxing by Julia's class, ProgramError, a Module's class, the landing lock and ticket priority, ClassIdNumbering, ImplicitFieldAccessorCodeGenerator, entry 61)

The sixty-second audit, beside the work, covers the 41 commits of e017e6c9..98481e33 that are not entry 61 (aa3a47a2,
its author's), read here, the lead's line stop between (autoship halted in this worktree, restarted on the lead's word).
Every finding rests on one exact command, quoted; TLC ran the refactored models and ClassIdNumbering. Standing items.
Timing (the lead's watch point): `sort -t$'\t' -k2 -rn "$(git rev-parse --git-common-dir)/wt-src-costs.tsv" | head`
gives `dart_tests.jl 67.7`, `code_generator.jl 40.5`, `code_generator_control.jl 32.4`, `dart_core_1.jl 30.4`,
`dart_core_2.jl 29.8`, `dart_core_3.jl 27.8`, `code_generator_intrinsics.jl 25.4`, `runner.jl 5.4`, of 322 s in all:
dart_tests.jl, one 67.7-s file, is the whole of the line stop's red, and the code generator's three files (98 s) follow;
the dart_core rows belong to a tree origin/wt2 does not hold (A62E1). Models: `TLC_ONLY=… taskpolicy -b bash
dev/formal/run_tlc.sh` printed `ok MCCFGStackify.cfg … 2634`, `ok MCCFGStackifyEH.cfg … 623` over the extracted
StackifyTry, and `ok MCClassIdNumbering.cfg … 1250` with `violation of Normalized`, `RangeIsa` twice and
`ConcreteDense`, each its expect line's claim. Fixed in the range: A61S1 by e647f449 and 39e2739a (`grep -n
'Unported("dart2wasm/lib/code_generator.dart:4937' src/code_generator.jl` prints nothing: a binding's read calls its
getter), A61S2 by 39e2739a (the eager initializer rejects Internal, code_generator.jl:331, :2208), A61S3 by 00486801
(`grep -n "EXTENDS" dev/formal/CFGStackify.tla dev/formal/CFGStackifyEH.tla` gives both `EXTENDS Integers, Sequences,
FiniteSets, StackifyTry`, PlaceTry and PlaceTryTable each one call of PlaceTryTableMarker), A61S4 by f6a3608e, A60S1 by
b9cceac0 (ProgramError, the sum's sixth kind, matched by construction). Partly: A61E1, the tag now exported as
`$exceptionTag` (721238bf), but `grep -n "exceptionTag" test/runner.jl` prints nothing, the verdict still `instanceof
WebAssembly.Exception`. Exemptions (the lead's order): `git diff e017e6c9..98481e33 -- src | grep -E
'^\+.*(Reshaped:|Fields with no Julia counterpart)'` gives one, e069a453's `boxed_class` ("dart's boxedClasses keys a
box by the wasm type, which names no one Julia class", true: Int64 and UInt64 share i64); ten Reshaped notes leave with
4c2aca97, the Reference sum taking their place (D5). Findings A62S1 and A62E1.

Area: builder — empty by diff (`git diff --stat e017e6c9..98481e33 -- src/wasm_builder` prints nothing).

Area: collection and planning — 4c2aca97 makes the Kernel table's Reference one `@closed` sum, `Union{MethodInstance,
FieldReference}` (src/julia/kernel.jl:69), FieldReference(field, kind) refusing an instance field's initializer, every
match over it @exhaustive; ad35d98a re-lands the interpreter as lib/WasmInterpreter, its image built apart (ef697a60,
dd8b6586: outside the judged load only while the change leaves it untouched); c0e70e10 and d12ef978 load src/patch's
overlays through include_patch, each under a @quarantine naming the Base function it replaces; 78a74ad5 reads every
pragma through getPragma; f5e99514 types a parameter Any exactly where its pin says Object. (A62S1, medium, the lead's
watch point) the field references are made by the constructor, but a field's generator and the translator keep a bare
binding as a member beside the sum: `grep -rn "FieldReference(" src | grep -v src/julia/kernel.jl` gives globals.jl:219,
code_generator.jl:1526, :1548 and :2221, each through the constructor, while `grep -rn
"Union{Core.MethodInstance,GlobalRef}" src` gives code_generator.jl:266, :312 and :342 (`const
enclosing_member::Union{Core.MethodInstance,GlobalRef}` in StaticFieldInitializerCodeGenerator,
EagerStaticFieldInitializerCodeGenerator and StaticFieldImplicitAccessorCodeGenerator) and translator.jl:157 holds
`members_being_generated::Base.IdSet{Union{Core.MethodInstance,ClassField,GlobalRef}}`: a member is a Reference in one
place and a GlobalRef or a ClassField in another, so the next site that hands a generator's member to a Reference-typed
parameter is the MethodError monitor-a saw, found again only when a test runs it (D5, D6). Fix: each generator's member
is its FieldReference (the binding with its initializer, getter or setter kind), and members_being_generated an
`IdSet{Reference}`, so no bare GlobalRef or ClassField names a member anywhere.

stopgap in disguise: none new.
precedent: the Reference sum, Kernel's Reference naming a member or a field's accessor (kernel/lib/canonical_name.dart);
the overlays, dart's @patch libraries and GPUCompiler's method table.

Area: emission and diagnostics — e647f449 calls a static field's implicit getter and setter as dart's visitStaticGet and
visitStaticSet do; 98481e33 ports ImplicitFieldAccessorCodeGenerator, a field selector's target; 97e4e515 lowers a
String's data operations and egal on two Strings; e069a453 boxes a number as its value's Julia class; 818669a0 answers
unimplemented as never reached, every NIR form having its visitor; 721238bf exports the exception tag (emscripten's
__cpp_exception the precedent). No finding.

stopgap in disguise: none new.
precedent: a field's accessor, dart's ImplicitFieldAccessorCodeGenerator and StaticFieldImplicitAccessorCodeGenerator;
the exported tag, emscripten's __cpp_exception.

Area: enforcement and prose — 89504c31 drops the separate check slot, a check waiting on the landing lock alone;
6d540b66 queues a stack's ticket earlier by what it carries (an audit finding's fix 40 minutes, a ported stub 20);
5fbea416 frees a pidless lock after 20 s; 3604ddea re-ships a red HEAD when origin/wt2 moves; 6f02bf6a gives each case's
compile and read a hard limit; 0ad293d4 splits the corpus shards by each group's measured seconds. (A62E1, low) the
measured costs the shards are split by mix trees: wt-src-costs.tsv holds `dart_core_1.jl`, `dart_core_2.jl` and
`dart_core_3.jl` while `git ls-tree --name-only origin/wt2 test/src/ | grep -i dart` gives `test/src/dart_tests.jl`
alone, so a green check of a lane's tree writes rows by file name alone, and the next check of another tree plans its
shards from them (C10). Fix: the costs keyed by the head they were measured on, or each check reading only rows of files
its tree holds and writing its own. Requirements: D5 and D6 (A62S1); C10 (A62E1); D9 (A61E1, still open); no lock fired
inside its band.

Resolution: this entry lands alone, prose only, and fixes nothing. A61S1 is fixed by e647f449 and 39e2739a, A61S2 by
39e2739a, A61S3 by 00486801, A61S4 by f6a3608e and A60S1 by b9cceac0, each leaving its row. A62S1 is open on MARCH 1.D.
A62E1 is open on MARCH 1.L. By owner: wt3-cgstubs holds A62S1 (code_generator.jl's generators, with translator.jl's
set); the lead holds A62E1; the tests lane holds A61E1, its runner now to match `$exceptionTag`.

## 2026-10-29 — audited through 84b02f8f (98481e33..84b02f8f: visitThrow through the runtime, a placeholder subject refused, the line stop, the kept costs pruned, a vararg parameter rejected, intrinsified members external, _svec_ref's BoundsError, InstanceCheck, a fieldless mutable struct, a reader's typeasserted pick, the exception tag matched, a field left undefined holding its null, the rows that named dev/MARCH.md, entry 62)

The sixty-third audit, beside the work, covers the 14 commits of 98481e33..84b02f8f that are not entry 62 (6d24a3ff, its
author's), read here, with the lead's five watch points. Every finding rests on one exact command, quoted; TLC ran
InstanceCheck: `TLC_ONLY=… taskpolicy -b bash dev/formal/run_tlc.sh` printed `ok MCInstanceCheck.cfg … 27720 distinct
states` and `violation of CheckIsJuliaIsa` for each of its three Broken instances. Exemptions: `git diff
98481e33..84b02f8f -- src | grep -cE '^\+.*(Reshaped:|Fields with no Julia counterpart)'` gives 0. Fixed in the range:
A61E1 by 49350460 (a WebAssembly.Exception counts only under the module's one exported tag, matched with `e.is(tag)`;
the exception's type is still unread, as test/runner.jl's Throws docstring says, until its class-id reader is ported),
A62E1 by 5925d113 (a kept cost for a file the checked tree does not hold is dropped). 4602f109 answers an undefined
field as Julia does where it can: the field holds its null and _directGet tests it, raising UndefRefError through the
runtime's throw_undef_ref_error, while a field whose type admits `nothing` (whose null would read as `nothing`) or an
isbits field still rejects, located (D9). Watch points. (1) The Reference sum after A62S1: not yet; `grep -rn
"Union{Core.MethodInstance,GlobalRef}\|Union{Core.MethodInstance,ClassField,GlobalRef}" src` still gives
translator.jl:157 and :243 and code_generator.jl:266, :312 and :342, A62S1 unchanged. (2) The Vararg rejections: three
sites (A63S1). (3) RUNTIME_DEMANDS is one table of statement predicates keyed by the demand RUNTIME_ENTRY_POINTS names,
each demand checked to have its predicate when the package loads (`haskey(RUNTIME_DEMANDS, demand) ||
throw(ConstructionViolation(…))`, subset.jl:256); the `:bounds` rename has not landed; A63S2 on how the predicates read.
(4) The line stop (01ebcfa6) refuses every other lane's check, naming the stop's file and lane (`check: REFUSED — line
stop: only <lane> lands until <file> is removed`), a manual flag the text calls no construction; the cost pruning is
A62E1's fix. (5) 84b02f8f's eleven rows each open with a file (`git show 84b02f8f -- src | grep '^+' | grep -c reject!`
over src/functions.jl, src/code_generator.jl and src/julia/runtime/rtutils.jl, each present); its two Internals are
right, a PhiNode or an EnterNode reaching translateExpression as a value being WasmTarget's own defect (visit_block
reads a phi from its register; an EnterNode's token is read only by `:leave` and `:pop_exception`, which emit nothing);
A63S3 on two of the other rows. Findings A63S1, A63S2, A63S3 and A63E1.

Area: builder — empty by diff (`git diff --stat 98481e33..84b02f8f -- src/wasm_builder` prints nothing).

Area: collection and planning — 00a0cfad records an intrinsified member's call without collecting its body, dart's
external member; 4602f109 adds the undefined-field demand to the runtime's roots. (A63S1, low) the Vararg parameter
rejects at three sites, one naming another file's definition: `grep -rn "Vararg\|vararg" src/functions.jl
src/param_info.jl | grep reject` gives param_info.jl:60 and :76 (fromMember, fromLocalFunction), functions.jl:444
`reject!(Unquarantined("src/param_info.jl fromMember: the Vararg signature …"), "dart2wasm/lib/functions.dart:731 …")`,
param_info's row copied into functions.jl, and functions.jl:454 (cd7f0db9, `_getInputTypes: the vararg parameter …`):
one gap, Julia's packed vararg convention, decided three times (D5; 8e4e0a15, which merges the functions.jl two, is not
on wt2). Fix: one rejection at the one place the packed vararg first meets a port, its row its own file's, until
codegen-b's port replaces it. (A63S2, low) the runtime's demands read Julia's raw IR beside the NIR: `grep -n
"Meta.isexpr(st, :call)\|Meta.isexpr(st, :new)" src/julia/subset.jl` gives `199:` (`_calls_builtin`) and `207:`
(`_leaves_field_undefined`), each matching over each CodeInfo's `code`, a second reader of Julia's statement forms
beside build_nir's closed NirStmt sums (L221, L222), and the second decides "a field left undefined" apart from
visit_constructor_invocation's own count (C1, D5); the necessity, that the demand is read before the NIR exists, is
named nowhere. Fix: the necessity in each @quarantine, and one predicate of a leaving allocation that the NIR's NirNew
and the demand both call.

stopgap in disguise: none new.
precedent: the runtime's roots, dart's wasm:entry-point pragmas kept by TFA; an intrinsified member, dart's external
member recorded by its call.

Area: emission and diagnostics — 633107e0 throws through the runtime's Error._throwWithCurrentStackTrace; aa25a7ce reads
a SimpleVector's element behind Julia's bounds check, raising BoundsError; 2458b890 gives a fieldless mutable struct
instances of their own. (A63S3, low) two of the rewritten rows reject a statement whose own text gives Julia's answer:
`git show 84b02f8f -- src | grep '^+' | grep -n "GCPreserve\|LoopInfo"` gives `Unquarantined("src/code_generator.jl
translateStatement: Julia's GC preservation region, which WasmGC's references keep alive …")` and `… Julia's loop hints,
LLVM's loop metadata …"`: a GC preservation region keeps nothing alive that WasmGC's references do not, and a loop hint
is metadata Julia's codegen may drop, so each is an expression statement with no effect, not a gap (C6: a gap rejects;
an answered form compiles). Fix: each answered as the statement Julia's codegen gives no wasm effect, with its reason.

stopgap in disguise: none new.
precedent: an undefined field, Julia's NULL and jl_undefref_exception; the exception's match, emscripten's e.is on its
exported tag.

Area: enforcement and prose — 3d3e7672 refuses a placeholder subject in dev/hooks/commit-msg; 7e0bacf7 typeasserts a
reader's pick to its leaves' native type. (A63E1, low) the subject rule binds only a client hook: `grep -n
"wip\|placeholder" dev/check.sh dev/ship.sh test/parity_ratchet.jl .github/workflows/*.yml` prints nothing, so a commit
made with `--no-verify`, or in a clone without the hook, lands its subject unread, as 2e9ead2f did (D6: the rule the
code's, at the landing). Fix: dev/ship.sh's carry check reads each subject by the hook's own pattern. Requirements: D5
(A63S1, A63S2); C1 (A63S2); C6 (A63S3); D6 (A63E1, A62S1 still open); no lock fired inside its band.

Resolution: this entry lands alone, prose only, and fixes nothing. A61E1 is fixed by 49350460 and A62E1 by 5925d113,
each leaving its row. A63S1 is open on MARCH 1.F. A63S2 is open on MARCH 1.C. A63S3 is open on MARCH 1.D. A63E1 is open
on MARCH 1.L. By owner: codegen-b holds A63S1 with its vararg port; wt3-cgstubs holds A63S3 and A62S1; the translator
lane holds A63S2; the lead holds A63E1.

## 2026-10-29 — audited through 5a89f571 (84b02f8f..5a89f571: the corpus image shared, a foreign call as wasm:import, a binding read at its one source, a constant's object graph, dart:_wasm's storage classes, a field generator's member its FieldReference, Core.svec, one Vararg rejection, a shard's first-compile start, Memory and MemoryRef laid out, a tear-off's binding, entry 63; and Dale's two rules over src/julia)

The sixty-fourth audit, beside the work, covers the 11 commits of 84b02f8f..5a89f571 that are not entry 63 (5d22a67c,
its author's), read here, and from this entry on two sections for Dale's rules of 2026-10-29: R1, no piece bespoke, each
a near 1-1 port of a named source at a pin; R2, no stub called complete. src/julia was swept for R1 by a read-only
sub-auditor, each item below re-run here. Every finding rests on one exact command, quoted. Standing items. Fixed in the
range: A62S1 by a4655a55 (`grep -rn
"Union{Core.MethodInstance,GlobalRef}\|Union{Core.MethodInstance,ClassField,GlobalRef}\|enclosing_member::Union" src`
prints nothing; `grep -n "members_being_generated::" src/translator.jl` gives `157:
members_being_generated::Base.IdSet{Reference}`); A63S1 by 8c265eb8, one Vararg rejection at _getInputTypes beside
param_info's two (`grep -rn "Vararg\|vararg" src/functions.jl src/param_info.jl | grep -c reject` gives 3:
functions.jl's one and param_info.jl:60, :76, each its own file's row). The corpus image (28ca38f0) is sound against
judged cost: `sed -n 61,81p dev/check.sh` shows unjudged_build returning before any build when the change touches
`test/smoke_corpus.jl` or `test/DartCorpus` (`git diff --quiet "${CHECK_BASE:-HEAD~1}" HEAD -- "${paths[@]}" || return
0`), so a change to the corpus pays its image inside the judged stage and only a change that leaves it untouched builds
it unjudged, its cost printed; the dart tests' load fell from 32.2 s to 3.0 s at its source. The line stop in use: `grep
"T14:1" "$(git rev-parse --git-common-dir)/wt-ship-failures.tsv"` shows six refusals between 14:15Z and 14:18Z, each
`check: REFUSED — line stop: only wt3-tests lands until …/wt-line-stop is removed`, entry 63's among them, which landed
when the stop lifted: located, and binding every lane's ship. The hang (A64E1). Exemptions: 9acfe5b4's two,
classes.jl:386 `T` (an inline union of bits stored boxed, genericmemory.c's jl_genericmemory_typetagdata) and :438
`ptr_or_offset` (the index form, Julia's own, genericmemory.c's jl_memoryrefoffset): each concrete, true and cited.
Findings A64E1, A64E2 and the R1 items A64R1 to A64R6.

Area: builder — empty by diff (`git diff --stat 84b02f8f..5a89f571 -- src/wasm_builder` prints nothing).

Area: collection and planning — 9acfe5b4 lays out a Memory as dart's WasmListBase over Julia's jl_genericmemory_t
(`data` one wasm array, Julia's const `length`, `ptr` left out), a MemoryRef as its index and its memory, each
difference cited to genericmemory.c; memoryrefget has no arm yet, so no element is read; when it comes, an undefined
reference element must raise UndefRefError and an element type admitting `nothing` must not share the null, as 4602f109
rules for fields. 31a4ddfa walks a constant's object graph for its classes (ValueClasses modeled first); fda31616 reads
a binding at its one source. No finding beyond R1's.

stopgap in disguise: none new.
precedent: Memory, dart's WasmListBase (list.dart:15) over julia.h's jl_genericmemory_t; a binding's value,
nir_binding_value under dev/MODULE_INIT.md.

Area: emission and diagnostics — 9e406a4a builds a SimpleVector at run time as dart's WasmArray.literal; 5a89f571 makes
Julia's egal by identity one rule and reads a tear-off's binding at its source. No finding beyond R1's.

stopgap in disguise: none new.
precedent: Core.svec, dart's WasmArray.literal under its struct.

Area: enforcement and prose — 28ca38f0 shares the corpus image across lanes (above); b09c322c charges a measured shard's
first-compile start before its first file. (A64E1, medium) a hang outlived its case's watchdog: `grep "T14:1"
…/wt-ship-failures.tsv` gives `2026-10-29T14:12:09Z wt3-constants 05571622 … check: RED — past the hard limit of 480s, a
hang or a blow-up: src tests shard 1, at: dart_tests.jl: dart_is/function compiling #8011#8012 Tuple{Int64}`, while
test/src/dart_tests.jl's _dart_limited (`sed -n 1148,1172p`) interrupts a case past 120 s with SIGINT once a second from
a perl watchdog, caught as InterruptException: so either no SIGINT reached a safepoint in 360 s, or an interrupt was
taken and the case went on; the 480-s stage limit, not the case's, named it (D17, Dale's no-hang rule). Fix: the case's
limit a process boundary (the case compiled in a child under its own hard limit) or a cause found for the missed
interrupt, with a plant that hangs in the same place. (A64E2, high, R2) the progress line calls stubs ported: `sed -n
63p dev/src_progress.sh` prints `src: $ported of $anchored anchored dart definitions ported …`, `ported` every counted
anchor with no @unported stub (:40–:41), the 288 bodies that are one Internal rejection and the 1 gap counted inside it
and only listed after (`of the ported, $replaced are one Internal rejection …`), so the landing printed `src: 3403 of
3404 anchored dart definitions ported` with 289 of them rejections; MARCH 1.U's exit, `dev/src_progress.sh's ported
count equals its anchored total`, would read that complete; and a rejection-only body is recognized only when its whole
body is a single `reject!` (parity.jl's _rejection_only_kind), so a guard and then a rejection counts as a body (R2,
D43). Fix: `ported` counts bodies alone; the line prints ported, replaced (each named by a skeleton scope rule or a port
to do, the lead's triage), gaps and stubs apart, and 1.U's exit reads the first against the in-scope total. (A64E3,
medium, the lead's, D17) the landing check runs at 106–120 s against its 60-s target, its floor the first compile each
shard pays, about 49 s (the lead's trace: the code generator 47%, Base 29%, wasm_builder 3%); `sort -t$'\t' -k2 -rn
"$(git rev-parse --git-common-dir)/wt-src-costs.tsv" | head` puts the code generator's three files at the top (audit
62). The fix is a real cut to WasmTarget's first-compile latency, placed after the port (D44), brought forward at once
if D14's reds exceed one check in three over any hour (wt-ship-failures.tsv against wt-landings.tsv). Requirements: D17
(A64E1, A64E3); R2 and D43 (A64E2); no lock fired inside its band.

R1, no piece bespoke (Dale, 2026-10-29), swept over src/julia, src/julia/runtime and src/runtime. Ported with a named
source: 9acfe5b4's Memory (dart's WasmListBase over genericmemory.c), 4602f109's undefined field (Julia's NULL and
jl_undefref_exception), the stackifier and exception tree (LLVM at its pin), the closed world (Julia's trim inference).
Bespoke, each to port: (A64R1, high, translator, beside A63S2) RUNTIME_DEMANDS' predicates (subset.jl:214) decide which
runtime roots join the closed world by scanning raw CodeInfo (`grep -n "Meta.isexpr(st, :call)\|Meta.isexpr(st, :new)"
src/julia/subset.jl`), an invented rule computing again what the code generator decides (code_generator.jl's
throw_undef_ref_error rule, D5): port GPUCompiler's rtlib (link the runtime functions the emitted code calls) or dart's
wasm:entry-point (the roots always kept). (A64R2, high, codegen-b) nir_host_import calls a method an import only when
its whole body is one foreign call and a return (`grep -n "length(body.stmts) == 2" src/julia/runtime/rtutils.jl` gives
`83: length(body.stmts) == 2 || return nothing`), a shape test no source has: port Julia's ccall lowering (ccall.cpp
emit_ccall, each (symbol, library) call site its import) as emscripten imports each called symbol. (A64R3, high, the
lead's: it crosses dev/MODULE_INIT.md) nir_binding_value (nir.jl:595) bakes the values every `__init__` computed into
the module, where juliac runs the init list at startup (dev/MODULE_INIT.md's ruling, its deviation named): the source to
port is juliac's own, staticdata.c's restored init list and jl_init_restored_modules run at the start function. (A64R4,
medium) host_modules finds the host's libraries by a regex over the JS template (`grep -n "baseImports"
src/julia/runtime/rtutils.jl` gives `53: local block = match(r"const baseImports = \{\n(.*?)\n\s*\};"s, text)`): port
dart's js/runtime_generator.dart's import object as data, or emscripten's --js-library. (A64R5, medium) the closed
world's class rules and a kind's layout (classes.jl's closed_world_classes, :27 citing only class_info.dart:864's list;
_kind_instance_fields keeping Julia's Union and UnionAll fields beside dart's _Type) mix two layouts by hand: port
julia.h's jl_datatype_t, jl_uniontype_t and jl_unionall_t throughout, or dart's type.dart throughout. (A64R6, low)
`BLOCK_TYPE_CATCH::Int = -2` (`grep -n BLOCK_TYPE_CATCH src/julia/machine.jl` gives `46: … const BLOCK_TYPE_CATCH::Int =
-2`), an invented sentinel: LLVM's CFGStackify types the catch destination from the caught value's register class. Not
yet written, to port when they are: the varargs convention (codegen.cpp's va handling, today rejected at _getInputTypes)
and a Memory's element reads (genericmemory.c's memoryref get and its undefined-reference check).

R2's triage (the lead's request, by a read-only sub-auditor; its raw hits kept in the session's scratchpad): of the
@parity definitions whose body is one `reject!(Internal(…))` or `no_counterpart_rejection(…)`, 331 at 06d23373 (49
through no_counterpart_rejection, all in code_generator.jl), 265 are (a), no counterpart in Julia's IR: the structured
statements (If, Do, While, For, Labeled, Break, Assert, Switch, the logical and conditional expressions, BrTableInfo and
SwitchInfo, TryCatch and TryFinally, 0c711af9's NoCounterpart rows among them), Julia's IR being a CFG the CFGStackify
port structures; the initializer lists and constructor generators (a constructor is a method and `%new`); super calls;
dynamic invocations, dispatchers and forwarders (D32); closures' contexts, trampolines and instantiation (a closure is a
struct and its call method); TFA's readers and NodeCounter (Julia's inference and inliner); the literal visitors Julia's
lowering turns into calls; tasks, deferred loading and the front end (scope rules); 63 are (p), dart's own body throwing
or abstract at the pin, faithful ports; 1 is (b), visitRethrow (code_generator.jl:1767), a port to do from dart's body
over rtutils.c's jl_rethrow; 2 are (c): translator.jl:613 ffiMemory (Julia's pointerref and pointerset would need it,
Ptr's scope undecided) and intrinsics.jl:923 readIntArray (its signed and unsigned packed reads are what memoryrefget on
a Memory{Int8} needs, intrinsics.jl emitting array_get_u alone). visit_block's try_table covers dart's visitTryCatch and
visitTryFinally only in part: the try region, the catch of the tag and the finally on normal, return and break exits are
covered; the rethrow on an exception exit (every finally's, every unmatched catch's), the JS-tag catch arm and the stack
trace are not. The lead's rulings: nothing leaves the denominator (dev/skeleton_scope.toml's "codegen and runtime
structures are never out" stands), the (a) rows shown as "no Julia counterpart (triaged)", never ported, as 96fbcdf7's
headline counts them; the (p) rows told apart in the registry so they count as bodies (wt3-skeleton); visitRethrow, the
JS-exception arm and the stack trace to wt3-cgstubs, readIntArray to wt3-codegen; ffiMemory a located gap, never done,
until 1.F decides Ptr's scope.

Resolution: this entry lands alone, prose only, and fixes nothing. A62S1 is fixed by a4655a55 and A63S1 by 8c265eb8,
each leaving its row; A63S2 is carried by A64R1. A64E1 is open on MARCH 1.T. A64E2 is open on MARCH 1.U. A64E3 is open
on MARCH 1.L. A64R1, A64R3 and A64R5 are open on MARCH 1.C. A64R2 and A64R4 are open on MARCH 1.F. A64R6 is open on
MARCH 1.D. By owner: the tests lane holds A64E1; the lead holds A64E2, A64E3 and A64R3 (dev/MODULE_INIT.md's ruling);
the translator lane holds A64R1 and A64R5; codegen-b holds A64R2; the 1.F lane holds A64R4; the EH model's owner holds
A64R6; the triage's (b) and try/catch gaps go to wt3-cgstubs, its readIntArray to wt3-codegen, its (p) registry state to
wt3-skeleton.

## 2026-10-29 — audited through 327dfc5b (5a89f571..327dfc5b: generated imports of src/julia, the runner's native answer after its compiles, the watchdog's kill, an Unquarantined row located only by src or the pin, the honest headline, the parse check before queuing, the line stop read again, entry 64 and its follow-up)

The sixty-fifth audit, beside the work, covers the 7 commits of 5a89f571..327dfc5b that are not entry 64 or its
follow-up (614f9cbe, a0df288f, its author's), read here, under Dale's R1 and R2 as standing sections and the lead's four
points. Every finding rests on one exact command, quoted. Standing items. src changes by one generated file alone (`git
diff --stat 5a89f571..327dfc5b -- src` gives `src/julia/packages.jl | 149`); no exemption lands (`… | grep -cE
'^\+.*(Reshaped:|Fields with no Julia counterpart)'` gives 0). Fixed in the range: A64E1 by c08dd653 (the watchdog, past
DART_CASE_LIMIT and then DART_CASE_GRACE = 5 s unanswered, prints the case to stderr and kills the process, a plant over
an allocation-free loop in a child julia proving it), the cause of the 14:12Z hang still open with wt3-tests; A64E2's
headline half by fa1d5dad (`src: $body of $anchored anchored dart definitions ported with a body`, `body = ported -
replaced - gaps`, the rejection-only ones beside it, never in it). The lead's points. (1) 570f8269's generated imports
are refused by L210 when hand-edited, and the plants are real: test/parity_ratchet.jl:491–502 plants a Dart2Wasm block
missing a name and a hand-added `import ..planted_by_hand` in a block, each required to differ from what
`dev/skeleton.jl` writes, and reports "the tree's … packages.jl differs … its plants cannot run" when the real file
does. (2) fa1d5dad is the honest headline above; 545ef8ca parses every changed .jl with `Meta.parseall` before the stack
queues, naming the file and its error; 327dfc5b reads the line stop again as the check's last step. (3) c08dd653 is
A64E1's fix, A64E4 its cost; 3f907d24 computes the native answer once, after the compiles it is compared against
(A61S4's order), its docstring naming the remaining limit (a reader compiled after the native run starts a step on, a
false failure, never a false pass), A65E1 a site left out. (4) The #undef port has not landed: `grep
"efbc62d3\|4a024512" …/wt-ship-failures.tsv` gives both red at 15:08Z and 15:12Z, `check: src tests red`, their outputs
naming `visitConstructorInvocation: the isbits field x#isSet of … left undefined` and `… a#isSet of BoundsError left
undefined`: the layout's isSet fields arrived before the allocation that fills them, and the landing refused it, as the
rule asks. Findings A65E1 and A64E4.

Area: builder — empty by diff (`git diff --stat 5a89f571..327dfc5b -- src/wasm_builder` prints nothing).

Area: collection and planning — 570f8269 writes each module's imports of src/julia from the names its files use, the
module bindings and the Base and Core imports hand-written; computed once, refused when edited by hand (D5, D6). No
finding.

stopgap in disguise: none new.
precedent: the generated imports, the generator's own output, as dev/skeleton.jl writes every stub.

Area: emission and diagnostics — empty by diff for src/ outside the generated imports. No finding.

stopgap in disguise: none new.
precedent: none new.

Area: enforcement and prose — f45cefaf locates an Unquarantined row only by a file of src/ or of the pin, never a plan
document. (A65E1, low) the landing's core still runs a case's native answer before its compile: `grep -n
"_dart_same(f(args...)" test/src/dart_tests.jl` gives `1308: _DART_CORE_ONLY && key in DART_NATIVE_DUE && @test
_dart_same(f(args...), _dart_native(key))`, before the compile at :1310, so a core case the change edits compiles from
the heap its native run moved, 3f907d24's order left out at that one site (A61S4's rule, C3). Fix: the proof of a
recorded answer reads the native after the compile, as the runner's native_answer does. (A64E4, low, the watchdog's
cost) the kill ends the whole process: c08dd653's watchdog kills the test process when a case takes no interrupt, so
every later case of that shard goes unrun and the shard's red names only the hung case; loud and located (D17), but the
cases after it are neither passed nor failed until the hang's cause, still open, is fixed. Fix: the hang's cause found,
with a plant that hangs after the earlier file that leaves the state behind. Requirements: C3 (A65E1); D17 (A64E4); no
lock fired inside its band.

R1 and R2. R1: the range ports no src definition; 570f8269 generates a file, not a design. R2: fa1d5dad stops the
headline counting a rejection-only body as ported. Still open under R2: the lead's ruling 2, the (p) rows (dart's own
body throws or is abstract) told apart in the registry so they count as bodies, not yet landed (wt3-skeleton), so today
they stand among the "not counted ported"; and parity.jl's _rejection_only_kind still recognizes a rejection-only body
only when it is one `reject!` statement, a guard and then a rejection counting as a body (A64E2's second half,
wt3-skeleton).

Resolution: this entry lands alone, prose only, and fixes nothing. A64E1 is fixed by c08dd653, leaving its row, its cost
carried by A64E4; A64E2's headline half is fixed by fa1d5dad, its registry half open on its row. A65E1 is open on MARCH
1.T. A64E4 is open on MARCH 1.T. By owner: the tests lane holds A65E1 and A64E4 (with the hang's cause); wt3-skeleton
holds A64E2's registry half and the (p) state.

## 2026-11-01 — audited through e0cd6392 (327dfc5b..e0cd6392: the name section's UTF-8, one landings row per commit, D45 and D46, the third pin, L213's pinned sources and their debt list, WasmListBase as Array{T,1}, the name section's precedent, ship's early class, host references and the JS string)

The sixty-sixth audit, beside the work, covers the 9 commits of 327dfc5b..e0cd6392 that are not audit entries 64 and 65
(fbc1d741, a0df288f, b1068ffd): 58b25a5d, b29ce5ca, 28ed33e6, d8b01dc9, e292e618, 2bad8676, b2b4bf59, f4cc916d and
e0cd6392, read here, under Dale's R1 and R2 as standing sections. Every finding rests on
one exact command, quoted. Standing items. src changes in 13 files (`git diff --stat 327dfc5b..e0cd6392 -- src | tail
-1` gives `13 files changed, 499 insertions(+), 82 deletions(-)`); one exemption lands (`git diff 327dfc5b..e0cd6392 --
src | grep -cE '^\+.*(Reshaped:|Fields with no Julia counterpart)'` gives 1, src/runtime/js_common/js_string.jl:35,
A66S2). e0cd6392, committed after 2bad8676, is the first landing under L213's new check, and each @quarantine it adds
cites a dart path (wasm_types.dart:59, :142, :151, :737, :748; runtime_generator.dart:150), each line read at the pin
and holding the symbol it names. b29ce5ca writes one landings row per pushed commit, so a stack red after
some landings still records them. Findings A66E1, A66E2, A66E3, A66E4, A66E5, A66S1, A66S2, A66S3 and A66S4.

Area: builder — 58b25a5d refuses a name section name that is not valid UTF-8, InvalidModule naming the entity;
f4cc916d, comment only, cites WebAssembly Core 2.0 §5.2.4 for it by URL. (A66S4, low, D10) the refusal is at
serialization, not at the line that records the name: `grep -n 'checked(name::String' src/wasm_builder/serialize/sections.jl`
gives `430:`, the one check, in NameSection.serializeContents, so the rejection names `function i` or `field k of type
i`, never the define, add_local or Dart2Wasm write that recorded it, where an import or export name is refused as it
is recorded. Fix: each recording site's builder refuses an invalid name as it records it, the serializer's check then
an Internal. Requirements: D10 (A66S4). f4cc916d's precedent grammar, `precedent(<spec>, <URL>)`, is not the `precedent(<ecosystem>: <file:line>)` L213 reads,
which only matters once comments in @parity bodies are checked.

stopgap in disguise: none new.
precedent: the spec's Names rule, by URL and version.

Area: collection and planning — b2b4bf59 answers KernelNodes.listBaseClass Internal (WasmListBase is Array{T,1}, a
class per element type); the dart readers at the pin (`grep -rn "listBaseClass" pkg/dart2wasm/lib` gives
class_info.dart:126, :127, :916, types.dart:53, translator.dart:250, :2473, :2480) are each answered elsewhere in src
(class_info.jl:604 drops the fixed order; types.jl:79 names Core.SimpleVector; translator.jl:1493 Internal). (A66E5,
low, R2) get_list_base_array counts as a body and can never succeed: `sed -n 1497,1501p src/translator.jl` is three
statements whose first, `self.class_info[list_base_class(self)]`, always rejects Internal, so `_rejection_only_kind`
(one `reject!` statement only, A64E2's open half) counts it ported with a body; test/src/translator.jl:288 asserts its
Internal. Fix: get_list_base_array answers Internal itself (its WT callers, indexList and the Function.apply
intrinsic, reach none), so it counts rejection-only.

stopgap in disguise: none new.
precedent: Base's Array{T,1} over its Memory, compiled as it is (D3).

Area: emission and diagnostics — e0cd6392: WasmArray{T} and WasmExternRef inhabited primitive types; dart:_wasm's
array new, write and length intrinsified (intrinsics.dart:1959, :1290, :626); `===` on two 8- or 16-bit integers an
i32.eq, sound under the put_form invariant (intrinsics.jl:359); js_string.dart's fromCharCodeArray and fromAsciiBytes.
(A66S1, medium, D1/D5) the host import's function type is a second path: `grep -n "local declared = Type\[\|
_make_function_type(translator, target, nothing; is_import_or_export = true" src/functions.jl` gives `176: local
declared = Type[(m.def::Method).sig.parameters[2:end]...]` and `194: _make_function_type(...)`: the import arm builds
its type inline with `define_function` from the method's declared signature, while the export arm still calls the port
of dart's `_makeFunctionType` (functions.dart:890), which reads the specialization through `_get_input_types`; dart
calls `_makeFunctionType` for both. Fix: `_get_input_types` reads the member's declared signature for an import or
export, at its one source, and the import arm calls `_make_function_type` again. (A66S2, medium, R1/D5) fromAsciiBytes'
body is a copy of Base's algorithm under dart's anchor: js_string.jl's loop read beside `sed -n 181,230p
…/julia-1.12.7…/base/strings/cstring.jl` is, branch for branch, `transcode(UInt16, ::AbstractVector{UInt8})`,
`push!` replaced by `wasm_array_write!`; dart's body at js_string.dart:151 widens bytes. The citation
`strings/cstring.jl:181` (js_string.jl:30) lies in no pin table (JULIA_FILES holds C units only), so L213 cannot resolve
it, and the algorithm now has two copies, Base's and this one, that drift apart when Base changes. Its `Reshaped:` note
(js_string.jl:35) also drops dart's `_codeUnitsCache`, a `wasm:initialize-at-startup` static that globals.jl:296
answers false for every binding. Fix: Base's transcode compiled as is, its Memory{UInt16} the i16 array the builtin
takes; failing that, Julia's base/ files pinned as a unit of JULIA_FILES and the copy anchored there. The differential
case (test/src/js_string.jl) covers each branch either way.

stopgap in disguise: A66S2's copy, a port of Julia's answer by transcription rather than by compiling it (D3).
precedent: dart:_wasm's WasmExternRef and wasm-bindgen's JsValue; Base's transcode.

Area: enforcement and prose — d8b01dc9 records D45 and D46 the same day (D18); e292e618 pins Julia's C and C++ sources
(JULIA_PIN 6d172b02, v1.12.7) with resolving plants; 2bad8676 adds check_quarantine_pinned to L213 with an exact debt
list; 28ed33e6 ranks a src stack early. The plants are real (test/parity_ratchet.jl:846–869: an unlisted unpinned
definition, an anchor with no checkout, a stale line and a gone line each refused, a front_end citation at a moved line
refused), and the commit reports them missed with the check stubbed. (A66E1, high, R1) a precedent pins without being
read: `grep -n 'occursin(REASON_PRECEDENT_RX' src/julia/parity.jl` gives `1318: occursin(REASON_PRECEDENT_RX, reason)
&& return nothing`, a text match of `precedent(<eco>: <path>:<line>)` with no file opened, and the lock's own plant
passes an invented one (`grep -n 'mod.rs:400' test/parity_ratchet.jl` gives `850: … precedent(rust:
library/alloc/src/vec/mod.rs:400)`): any of the 400 debt lines leaves the list by writing a precedent that names no
real line, the bespoke build D45 forbids passing as ported. Fix: a precedent names a pinned checkout (an ecosystem's
pin table and commit) and resolves as an anchor does, or it pins nothing; a plant with a precedent at a missing file
refused. (A66E2, medium, D20) the debt list is exact but not shrink-only: `grep -rn "quarantine_unpinned" src test
dev/*.sh` finds only parity.jl's reader (:1299) and its messages; a stale line is refused, an added one never, so a new
unpinned @quarantine lands by adding its line; and keys are names, not definitions (`grep -v '^#'
dev/quarantine_unpinned.txt | grep . | sort | uniq -c | sort -rn | head -1` gives `7 julia/parity.jl
construction_check`), so pinning one method and adding an unpinned one of the same name trades invisibly. Fix: ship and
the gate refuse a stack whose diff adds a non-comment line to dev/quarantine_unpinned.txt, with a plant; the 1.K
construction (the source a required argument) ends the list. (A66S3, low, R1) a path citation pins on a substring:
`grep -n 'occursin(sym, l)' src/julia/parity.jl` gives `1342: (sym === nothing || occursin(sym, l)) && return nothing`;
a citation without a symbol pins on any code line, and wasm_array.jl:160's `_wasm_only`, a native-raise helper dart has
no counterpart of, passes by citing wasm_types.dart:737, the WasmArray constructor's line, not its own source. Fix: a
path citation names its symbol and the line declares it (`_anchor_fault`'s rule), and `_wasm_only` is listed or cites
what it ports. (A66E3, low, D17) the Julia pin's plant is vacuous off one version: `grep -n 'VERSION != v"1.12.7"'
test/parity_ratchet.jl` gives `844: getfield(wt, :JULIA_PIN) == Base.GIT_VERSION_INFO.commit || VERSION !=
v"1.12.7" || …`, so CI's `'1.12'` (the latest 1.12.x) and `'~1.13.0-0'` ratchet lanes pass it without comparing, and
nothing checks JULIA_PIN against dev/PARITY_MASTER.md as :807 does LLVM_PIN. Fix: a julia whose commit is not JULIA_PIN
fails loud unless the pin moves with it, and PARITY_MASTER's pin is checked. (A66E4, low, D40) the early class counts a
comment: `grep -n 'git diff --quiet "origin/$MARCH...HEAD" -- src' dev/ship.sh` is the whole test, so f4cc916d
("Comment only; no behaviour changes") ranks 20 minutes early as "port work (D40)". Fix: the class reads a change to a
src definition's code, comments and docstrings aside. Requirements: D20 (A66E2); D17 (A66E3); D40 (A66E4); no lock fired
inside its band.

R1 and R2. R1: L213's check is a stopgap, honestly labelled, a load-time scan of prose with an exact allowlist; the
construction is MARCH 1.K's. Its debt list is exact by name but not shrink-only (A66E2), its precedent unread (A66E1),
its path citations substring-matched (A66S3); its four refusing plants fire. The third pin carries no anchor yet (`grep
-rn '@quarantine "[^"]*julia/src/' src | wc -l` gives 0). e0cd6392 ports dart's runtime with one copied Base algorithm
(A66S2) and one second path (A66S1). R2: nothing in the range counts a one-statement rejection as ported; b2b4bf59 moves
two definitions from Unported to Internal, apart from bodies; A66E5 is a body that only rejects through its callee,
counted ported, A64E2's second half again.

Resolution: this entry lands alone, prose only, and fixes nothing. A66E1 is open on MARCH 1.K. A66E2 is open on MARCH
1.K. A66S3 is open on MARCH 1.K. A66E3 is open on MARCH 1.K. A66S1 is open on MARCH 1.F. A66S2 is open on MARCH 1.F.
A66E5 is open on MARCH 1.C. A66S4 is open on MARCH 1.B. A66E4 is open on MARCH 1.L. By owner: lead holds A66E1, A66E2,
A66S3's check, A66E3, A66E4 and A66S4 (src/julia/parity.jl, test/parity_ratchet.jl, dev/ship.sh,
src/wasm_builder/serialize/sections.jl); wt3-runtime holds A66S1 (src/functions.jl) and A66S2
(src/runtime/js_common/js_string.jl); wt3-memory holds A66S3's `_wasm_only` (src/julia/wasm_array.jl); wt3-cgstubs2
holds A66E5 (src/translator.jl).

## 2026-11-01 — audited through 0d69d3c2 (e0cd6392..0d69d3c2: an undefinable field's read demanding UndefRefError, a Memory constant as its class's struct, === by identity, five shards, visitRethrow over Julia's exception stack, a precedent resolved, the non-standalone catch refused, debt lines by signature, host foreign calls per call site, GC preservation and loop hints, the debt list shrink-only)

The sixty-seventh audit, beside the work, covers the 11 commits of e0cd6392..0d69d3c2 that are not audit entry 66
(f8ec7d2b): 04dcb5d8, b1134735, af8319f4, 70b857dc, dd9c2109, e46d66b4, 47a7668e, 665146f1, 247ea3a1, 7fe30d10 and
0d69d3c2, read here, under Dale's R1 and R2 as standing sections. Every finding rests on one exact command, quoted.
Standing items. src changes in 13 files (`git diff --stat e0cd6392..0d69d3c2 -- src | tail -1` gives `13 files
changed, 387 insertions(+), 170 deletions(-)`); no exemption lands (`git diff e0cd6392..origin/wt2 -- src | grep -cE
'^\+.*(Reshaped:|Fields with no Julia counterpart)'` gives 0). Fixed in the range: A66E1 by e46d66b4 (a precedent names
a symbol and resolves at its ecosystem's pinned checkout, `_precedent_fault`, every precedent of a reason required);
A66E2 by 665146f1 (a debt line names one definition, by signature where a file quarantines several of one name) and
0d69d3c2 (L227 refuses a change adding a line, counted, with a scratch repository's five plants); A66S1's import half by
247ea3a1 (the import's type is `_make_function_type`'s; its export half is open, below, A67S3); A64R2 by 247ea3a1
(nir_host_import's whole-body shape test deleted, D5); A63S3 by 7fe30d10. A66E5 has not landed (`sed -n 1497,1501p
src/translator.jl` unchanged). The debt list reads 400 at both ends (`git show <c>:dev/quarantine_unpinned.txt | grep -v
'^#' | grep -c .` gives 400, 401 at 665146f1, 400 at 247ea3a1 and 0d69d3c2): 665146f1 added `julia/parity.jl
_written_signature`, an unpinned definition, by its line, the last addition the list can take now that 0d69d3c2
refuses one. Findings A67E1, A67E2, A67S1, A67S2, A67S3 and A67S4.

Area: builder — no change under src/wasm_builder. 247ea3a1's get_function for a NirForeignImport reuses an import only
of the same module, name and type (functions.jl:210), as emit_a_ccall's getOrInsertFunction does (ccall.cpp:1980,
read at JULIA_PIN).

stopgap in disguise: none new.
precedent: Julia's emit_a_ccall, by line at the pin.

Area: collection and planning — 04dcb5d8 demands throw_undef_ref_error where a getfield reads a field Julia's
field_may_be_null (cgutils.cpp:2768, read at the pin: `idx < nfields - n_uninitialized` and the pointer test, both
ported) may read as null, the operand typed by argextype with the method instance's sptypes; its `strct.constant` arm is
not ported, which demands more, never less, and `!(Nothing <: F)` follows _directGet's rule that a nothing-admitting
field's undefined allocation rejects (A63's entry). b1134735 meets a constant memory's length and written elements in
the class walk, never `ptr`. dd9c2109 adds NirHandlers.exception_at, compute_trycatch's exception stack top, Julia's
answer (D3). 247ea3a1 adds NirForeignImport and nir_foreign_import, read as interpret_symbol_arg (:571) and
convert_cconv (:1307) read a foreigncall, each line read at the pin. (A67S1, low, R1/D3) an Any argument of a host
call crosses as the operand's inferred class: `grep -n 'local params = Type\[t === Any' src/julia/runtime/rtutils.jl`
gives `139: local params = Type[t === Any ? Union{Nothing, nir_value_type(body, operands[i])} : t …]`, so the import's
type is the call site's inference, where julia_to_native (ccall.cpp:528, cited as its source) passes every boxed
argument as one jl_value_t* whatever its class and dart types the import by its declaration; two sites passing
different classes import one `<lib>.<sym>` twice under two types. Its docstring's precedent, `grep -n 'precedent(julia:
julia/' src/julia/runtime/rtutils.jl` giving `86:`, doubles the prefix `_precedent_fault` adds (`"julia/$path"`), so
it reads julia/julia/src/ccall.cpp and is refused the day it moves into a reason. Fix: an Any argument crosses as one
reference type at every site, its operand converted to it (Julia's one pointer type), or rejects located; the precedent
written `precedent(julia: src/ccall.cpp:1980 function_sig_t::emit_a_ccall)`.

stopgap in disguise: A67S1's narrowing, Julia's boxed arm read as a per-class one.
precedent: Julia's field_may_be_null, compute_trycatch and emit_ccall, by line.

Area: emission and diagnostics — af8319f4 adds identical's ref.eq arm where either operand's class is one
egal_by_identity names, julia.h:1885 jl_egal_ and :1874 jl_egal__unboxed_ read at the pin (a mutable datatype past
the small tags returns 0; String, SimpleVector and DataType carry small tags, compared by content); dd9c2109 ports
visitRethrow's body (code_generator.dart:2966), the_exception reading the same stack top; 47a7668e rejects Unported at
boxJsException wherever guardCanMatchJSException holds; 7fe30d10 answers gc_preserve_begin, gc_preserve_end and
loopinfo with no wasm effect, each a value Internal. (A67S3, low, D1/D5) A66S1's import half closes by a third copy of
_makeFunctionType's body: `grep -c '@parity "dart2wasm/lib/functions.dart:890 _makeFunctionType"' src/functions.jl`
gives 3 (MethodInstance :548, NirForeignImport :567, FieldReference :582), the external-type and void rules written in
each, where dart's one body reads its target through _getInputTypes and the member's return type; and the export arm
still reads the specialization through `_get_input_types` (A66S1's open half). Fix: one `_make_function_type` body,
`_get_input_types` and the return type read per target kind, an export's from its declared signature. (A67S4, low,
prose) a comment dd9c2109 falsified: `grep -n "Julia.s exception stack has no reader" src/code_generator.jl` gives
`995:`, which says the_exception rejects outside its catch's first block; it now reads exception_at. Fix: the comment
says the stack's reader is NirHandlers.exception_at (visit_block). Watch points. (1) Base.rethrow is routed only as an
invoke; inlined, its foreigncall `:jl_rethrow` names no library and rejects at nir_foreign_import as "whose library no
host supplies", located but misnamed. (2) b1134735 holds an unset Memory element as its null; memoryrefget is not yet
lowered (`grep -rn memoryrefget src` gives only nir.jl's tfunc table), so its UndefRefError test lands with it.

stopgap in disguise: none new.
precedent: dart's identical and visitRethrow, Julia's jl_egal_ and codegen's gc_preserve and loopinfo arms.

Area: enforcement and prose — e46d66b4, 665146f1 and 0d69d3c2 close A66E1 and A66E2 with plants that fire when their
checks are stubbed (nine, two and five). 70b857dc runs the src tests in five shards. (A67E1, medium, D14/D31) the
check's growth is answered by another process: `grep -n '^SHARDS=' dev/check.sh` gives `100:SHARDS=5`, six Julia
processes with the ratchet on the four performance cores during every landing, each shard paying the ~49 CPU-s first
compile A64E3 names, a fifth time; the band judges the slowest shard, so a shard lowers the judged number while the
wall clock and total work rise, and the first src change after it reds anyway (`tail -2 "$(git rev-parse --git-common-dir)/wt-ship-failures.tsv"`
gives 13845711 `check: RED — 135 s` and `123 s`, 12:08Z and 12:10Z). 70b857dc does not name A64E3, whose fix is the
first-compile cut. Fix: the shard count the cores hold (four processes), and A64E3's latency cut as the fix (D15).
(A67E2, medium, R1) `_precedent_fault` is pinned by an analogy it does not port: `grep -n 'function _precedent_fault'
src/julia/parity.jl` gives `1334: @quarantine "… as pkg/analyzer/lib/src/dart/resolver/comment_reference_resolver.dart:15
CommentReferenceResolver resolves a doc comment's"`; that class resolves `[name]` in a doc comment against the AST's
scope (`sed -n 15p` at the pin, `class CommentReferenceResolver {`), and the body, an ecosystem switch, prefix checks
and JULIA_FILES membership, ports none of it; it pins only because a path citation pins on any code line naming its
symbol (A66S3). Fix: the line returns to the debt list until a pinned near 1:1 match is named, and A66S3's fix (a
citation's line declares what the definition ports) refuses such a pin. (A67S2, low, R1) 665146f1 adds
`_written_signature` (parity.jl:199, reason "a method is its signature, which Julia's parser gives as written") to the
debt list, the last addition before 0d69d3c2: `grep -n _written_signature dev/quarantine_unpinned.txt` gives `309:`.
Fix: pinned to the source it ports, its line deleted. Requirements: D14 and D31 (A67E1); no lock fired inside its band.

R1 and R2. R1: each new src/julia definition's citation resolves at its pin (cgutils.cpp:2768, ccall.cpp:528, :571,
:1307, :1419, :1980; julia.h:1874, :1885, read here); one is pinned by analogy (A67E2), one narrows Julia's answer
(A67S1), one joined the debt list (A67S2), and _makeFunctionType's body is copied a third time (A67S3). L213's precedent
now resolves and its list only shrinks; its path citations still pin on a substring (A66S3). R2: visitRethrow and three
translateStatement arms move from a rejection to a body; nothing in the range counts a one-statement rejection as
ported; A66E5 is open.

Resolution: this entry lands alone, prose only, and fixes nothing. A67E1 is open on MARCH 1.L. A67E2 is open on MARCH
1.K. A67S2 is open on MARCH 1.K. A67S1 is open on MARCH 1.F. A67S3 is open on MARCH 1.F. A67S4 is open on MARCH 1.D.
A66S1's row names its open export half. By owner: lead holds A67E1 (dev/check.sh), A67E2 and A67S2
(src/julia/parity.jl); wt3-runtime holds A67S1 (src/julia/runtime/rtutils.jl) and A67S3 (src/functions.jl);
wt3-cgstubs2 holds A67S4 (src/code_generator.jl).

## 2026-11-01 — audited through cad03f24 (0d69d3c2..cad03f24: dart's embedder imports in the runner, the landing compiling no dart case, Julia's Memory builtins, the shards split by instructions, an #undef field's set flag, a sixth shard, a constant Vector as its Array{T,1}, === on DataTypes)

The sixty-eighth audit, beside the work, covers the 8 commits of 0d69d3c2..cad03f24 that are not audit entry 67
(0ddfa633): bcdd3cc1, bbc1ded7, 7a1fc91c, 25f5d125, 779986b2, 0db086ee, 7023257b and cad03f24, read here, under Dale's
R1 and R2 as standing sections. Every finding rests on one exact command, quoted. Standing items. src changes in 8
files (`git diff --stat 0d69d3c2..origin/wt2 -- src | tail -1` gives `8 files changed, 645 insertions(+), 78
deletions(-)`); two exemptions land (`git diff 0d69d3c2..origin/wt2 -- src | grep -nE '^\+.*(Reshaped:|Fields with no
Julia counterpart)'` gives `Reshaped: data#isSet` and `Reshaped: element_type`, each naming how Julia differs). The debt
list reads 400 at both ends (`grep -v '^#' dev/quarantine_unpinned.txt | grep -c .` gives 400). Nothing in the range
touches a file of an open finding of audit 67 (`git diff --stat 0d69d3c2..origin/wt2 -- src/functions.jl
src/translator.jl src/julia/parity.jl dev/quarantine_unpinned.txt` lists none of them), so A67E2, A67S1 (now
rtutils.jl:151), A67S2, A67S3, A67S4, A66E5 and A66S1's export half are open as audit 67 left them; A67E1 is open and
worse (A68E2). Findings A68E1, A68E2, A68E3, A68S1, A68S2 and A68S3.

Area: builder — no change under src/wasm_builder. 7a1fc91c ports readIntArray (intrinsics.dart:3490, read at the pin:
`w.ValueType readIntArray(StaticInvocation node, {required bool unsigned})`): a packed signed element array.get_s, any
other packed array.get_u, every other array.get. The Memory arms emit only builder instructions over typed locals.

stopgap in disguise: none new.
precedent: dart's readIntArray, by line.

Area: collection and planning — 779986b2 makes field_may_be_null (classes.jl:282) the one test, ported from
cgutils.cpp:2768 (read at JULIA_PIN 6d172b02: the n_uninitialized start and `jl_field_isptr || jl_type_hasptr`; its
`strct.constant` arm is isdefined's `known`), and deletes subset.jl's copy (D5); holds_reference (classes.jl:272) is the
one reference rule, and 7a1fc91c's inline copy in the memory arms now reads it (`grep -rn datatype_pointerfree src` gives
classes.jl:273 alone). class_is_set_field and _needs_is_set port computeIsSetEncoding's useIsSetFieldOrNull arm
(late_lowering.dart:560-569, read: `type.isPotentiallyNullable ? useIsSetField : useNull`), nothing standing for dart's
null, and lateIsSetSuffix (:12, `'#isSet'`). 7023257b's visitListConstant (constants.dart:1128) and immutableListClass
(kernel_nodes.dart:73) move from a rejection to a body: a constant Vector is its Array{T,1}'s instance constant, keyed
by ===, so its writes reach one global; the class walk meets a MemoryRef's Int offset and memory, never Julia's Ptr.

stopgap in disguise: none new.
precedent: Julia's field_may_be_null, dart's late lowering, by line.

Area: emission and diagnostics — 7a1fc91c lowers memorynew, memoryrefnew, memoryrefget, memoryrefset!, memoryrefoffset
and memoryref_isassigned, each arm cited by line and read at the pin (codegen.cpp:4206, :4230, :4241, :4247, :4255,
:4266, :3876, :4391; cgutils.cpp:4563, :4686, :2067), bounds_check_enabled as Julia's (`--check-bounds`, then the flag
constant false); atomic orders and swap/replace/setonce/modify reject Unquarantined, located, inside full bodies.
779986b2's isdefined arm follows codegen.cpp:4864. (A68S2, low, D3/D9) its atomic tests are not ported: `grep -n
'isfieldatomic\|isatomic' src/intrinsics.jl` gives nothing, so isdefined(x, :f, :not_atomic) on an @atomic field answers
the defined test where Julia's arm raises (`isdefined: atomic field cannot be accessed non-atomically`, codegen.cpp:4932),
and an order on a field the struct lacks answers false where Julia raises (:4918). Fix: both emit_atomic_error arms
ported, or rejected located. (A68S3, low, D6) cad03f24 compares two DataTypes by ref.eq on a soundness argument that
rests on an absence: its comment says each type is one constant "with no type made at run time", true today (`grep -n
'Core.typeof\|Core.apply_type' src/intrinsics.jl src/code_generator.jl` gives nothing), but nothing ties the arm to it,
so the commit that first lowers typeof or apply_type to a built type turns === on two egal types false, silently. Fix:
the invariant held where it can be broken: the one producer of a DataType value is _lowerTypeToConstant, any other
producer rejecting located, or the arm's plant failing once a run-time type exists. Watch points. (1) memorynew raises
OutOfMemoryError past 2^32 elements, but an engine's own array limit sits lower, so a count between them traps in the
engine. (2) bcdd3cc1's runner admits `i.name in dartEmbedder`, which reaches Object.prototype (toString, constructor);
Object.hasOwn is the exact test. bcdd3cc1's embedder is dart's test runner's (browser.dart:441, :695, :509-519, read).

stopgap in disguise: none new.
precedent: Julia's codegen Memory and isdefined arms, by line.

Area: enforcement and prose — 25f5d125 splits the src shards by each file's instructions retired, the measure D14's
band judges (ri_instructions is the 30th 64-bit field after ri_uuid in the SDK's rusage_info_v4, read: info[32], as
written); 0db086ee adds a sixth shard named a stopgap; bbc1ded7 compiles no dart case in the landing. Item (a). (A68E1,
medium, D14/D9) src changes landed on a load stage that built no image: cad03f24's ship output
reads `105 s on the critical path (load 0 CPU-s, ratchet 78, src shards 101 85 103 72
97 105 …)` for cad03f24, a change to src/intrinsics.jl whose first attempt f40cbcd2 read RED 135 s
(wt-ship-failures.tsv, 12:48:55Z), and a0e123ff's message records 779986b2 landing on `120 s (load 0 …)`; 8581639e read
load 0 too (wt3-codegen's autoship.out). The fix, deleting WasmTarget's images in the lane's depot when the change
touches src/ or Project.toml, is right and by construction (a retry cannot read a cached image; depot.sh always sets
JULIA_DEPOT_PATH, so the path is never empty), and it landed after the range as 7794d773 (`git log --oneline
cad03f24..origin/wt2` lists it; `git show origin/wt2:dev/check.sh | grep -n 'compiled/v\*/WasmTarget'` gives `95:`):
A68E1 is fixed. Its honest load (~13 CPU-s) now counts toward A68E2. Item (b). (A68E2, medium, D14/D31/D20) sharding is
exhausted and the stopgap's exit is prose: `grep -n '^SHARDS=' dev/check.sh` gives `103:SHARDS=6`, seven Julia
processes with the ratchet on four performance cores (`sysctl -n hw.perflevel0.physicalcpu` gives 4); after 0db086ee
every src check reads red (`tail -8 wt-ship-failures.tsv`: 125, 135, 128, 123, 131, 137 s, 12:44-13:01Z); each shard
carries ~305 G of its own load and first compile (0db086ee's message), ~58 s at RATE_SRC 5.3, so a seventh shard buys
~6 s. 25f5d125's larger-of-two cost inflates the summed suite (`awk` over wt-src-instr.tsv: 1483 G by the larger, 1249
by the newest) and the split still reads 420-655 G (8581639e: `src shards 99 79 107 93 94 123`). On D17/D20: the 60/120
band is untouched (no budget edited), the split's measure is the band's own, and the shard count is no ratchet; but
0db086ee's exit, "deleted, back to four (A67E1), by the commit that cuts that first-compile cost (wt3-latency)", is a
comment no check holds, the larger-of-two names no exit, and `grep -n 'five shards beside' dev/check.sh` gives `95:`
beside SHARDS=6. Fix: no seventh shard; A64E3's first-compile cut (wt3-latency, D15) is the line's blocker for every src
change; its commit sets SHARDS=4, deletes the larger-of-two with the shared first compile it measures around, and
rewrites the comment. After the range, 0bc356c5 replaces the static split with one queue each shard claims from
(its precedent, Julia's test/runtests.jl:267, lies outside the pinned checkout, which holds src/ alone, and is unread
here), which answers the imbalance; the larger-of-two still orders the queue (`git show origin/wt2:test/src_tests.jl |
grep -n 'maximum(v)'` gives `35:`) and SHARDS is still 6, so A68E2 stands. (A68E3, medium, C10/D9) no dart compile has been judged since bbc1ded7: its message says "Every
compile is judged by dev/corpus.sh on wt2's head", but `tail -1 "$(git rev-parse --git-common-dir)/wt-corpus.tsv"`
gives `2026-11-01T12:13:16Z 665146f1 red 866 [shard CPU-s: 170 102 457 102]`, a head before the range, red with four
hard-limit kills (wt-corpus-red-665146f1.out) and its first-failure column the shard costs, not a failure; no row exists
for any of the eight heads since and no corpus loop runs (`ps` shows only a shell polling origin/wt2 for
dev/corpus_shard.sh). Fix: the corpus runs on every head and a killed shard names its case in the row; a red or absent
corpus head is the next lane's first fix, as corpus.sh's header says. (A68S1, low, R1/L213) a reason's anchors after the
first resolving one are never read: `sed -n 1376p src/julia/parity.jl` gives `f === nothing && return nothing` inside
the anchor loop, so rtutils.jl:15's second anchor `julia/src/genericmemory.c:54 _new_genericmemory_` lands off by one
(`sed -n 54,55p` at the pin gives a blank line, then the declaration at :55), as 7a1fc91c's message cites it. Fix: every
anchor of a reason resolves, as every precedent already must; the citation :55. Requirements: D14 and D31 (A68E1,
A68E2); no lock fired inside its band.

R1 and R2. R1: each new definition's citation resolves at its pin (codegen.cpp, cgutils.cpp, builtins.c:100 and :243,
genericmemory.c:30, late_lowering.dart:12, :295, :382, :560, target.dart:565, constants.dart:1128 and :1719,
kernel_nodes.dart:73, intrinsics.dart:1194, :1409, :1454 and :3490, each line read here), each a near 1:1 port of the
line it names; one second anchor is off by one and unread (A68S1); nothing joins the debt list. R2: visitListConstant
(both visitors) and immutableListClass move from a rejection to a body; the Memory and isdefined gaps reject inside full
bodies and are counted gaps; nothing in the range counts a rejection-only body as ported; A66E5 is open.

Follow-up, two items the lead raised after the entry landed. (1) A dated stopgap ruling, 2026-11-01 13:10Z: a src
commit gets at most one retry on a red that is D14's alone, march-monitor-a counting the greens a retry gives apart from
first-attempt greens; it is deleted by wt3-latency's invalidation fix. Recorded on MARCH 1.L. Judged: the band is not
edited and, since 7794d773, a retry pays its precompile, so a retry re-reads the change honestly; what it samples is
which file first pays the ~110 G shared compile in its shard, a cost of the check, not of the change. (A68S4, low, D20)
the exit names a suspected cause, not a measure: nothing records when the ruling ends, and if the cause is elsewhere
(item 2) the fix may land and the retries stay. Fix: the ruling ends when the shared first compile is gone from the
measure (a file's two kept measures within a band of each other), or with SHARDS back to four, whichever comes first,
and the check prints each retry-green for the audit. (2) wt3-latency's suspicion that the corpus's Base methods
invalidate WasmTarget's compiled pipeline: no finding against the tests. Every Base method the corpus defines
dispatches on a corpus type in its first argument (`grep -cE '^\s*(function\s+)?Base\.' test/smoke_corpus.jl` gives
172; filtered for a first argument not of a `_`-named corpus type, `::Type{_…}`, or `io::IO, ::_…`, only `==` methods
on corpus types and calls of Base.ImmutableDict and Base.Ryu.writeexp remain; no `import Base`, no convert or
promote_rule, nothing in test/DartCorpus), so none widens a signature of Base's own; they port dart's operator
overrides, which the cases exist to compile, and they change no dispatch on Base's types. Such methods can invalidate
only code compiled at a call site whose argument types are abstract, so if a measurement confirms the invalidation, its
fix is WasmTarget's own call sites typed concretely (D15, src, wt3-latency), not the tests. Only two of the 52 src test
files load the corpus (`grep -rlE 'smoke_corpus|DartCorpus' test/src` gives dart_tests.jl and subset.jl), while the
shared cost shows in files that load none (records.jl 136 G then 24, globals.jl 67 then 3, 0bc356c5's message); the
measurement that decides it is whether that cost appears only in a shard where one of the two ran first. Owner of the
measurement: wt3-latency.

Resolution: this entry lands alone, prose only, and fixes nothing. A68E1 is fixed by 7794d773, after the range. A68E2
is open on MARCH 1.L (A67E1's text there now names A68E2). A68E3 is open on MARCH 1.T. A68S1 is open on MARCH 1.K. A68S2 and A68S3 are open on MARCH 1.D. A68S4 is open on MARCH 1.L (the follow-up).
By owner: lead holds A68E2 and A68S4 (dev/check.sh, test/src_tests.jl), with wt3-latency holding the first-compile cut;
wt3-tests2 holds A68E3 (dev/corpus.sh, test/src/dart_tests.jl); wt3-parity holds A68S1's check (src/julia/parity.jl)
and wt3-runtime its citation (src/julia/runtime/rtutils.jl); wt3-memory holds A68S2 and A68S3 (src/intrinsics.jl).

## 2026-11-01 — audited through 1bed6b74 (cad03f24..1bed6b74: field selectors and their table call, convertType's unboxing, the shards' one queue, src images deleted before the judged load, grep under pipefail, Base's MemoryRef copy and unset by overlay, the corpus file last, one program per family, isdefined's atomic errors, run-time types rejected, a killed corpus case failed by name, the constant walk once per object, a parametric union's class)

The sixty-ninth audit, beside the work, covers the 16 commits of cad03f24..1bed6b74 that are not audit entry 68 (bc74cd55,
0be10d4d): 0bc356c5, 7794d773, 6f48fa35, 3a8c06c1, b5f056a0, ed8085cd, a4f60ad3, 88bc946f, 582e6e0a, eb5655ce, c955b037,
a1f78cbc, 0993dc79, 134a0198 and 1bed6b74, read here, under Dale's R1 and R2 as standing sections. Every finding rests on
one exact command, quoted. Standing items. src changes in 14 files (`git diff --stat cad03f24..origin/wt2 -- src | tail -1`
gives `14 files changed, 638 insertions(+), 152 deletions(-)`); one exemption lands (`git diff cad03f24..origin/wt2 -- src
| grep -nE '^\+.*(Reshaped:|Fields with no Julia counterpart)'` gives `Reshaped: unreachableMetadata dropped`, naming how
Julia differs). The debt list reads 400 at both ends (`grep -v '^#' dev/quarantine_unpinned.txt | grep -c .`). Audit 68's
findings: A68S2 and A68S3 are fixed by 582e6e0a (below); A68E2 is open (`grep -n '^SHARDS=' dev/check.sh` gives
`112:SHARDS=6`, `grep -n 'maximum(v)' test/src_tests.jl` gives `35:`); A68E3 is open (`tail -1 wt-corpus.tsv` still gives
665146f1's row; a `dev/corpus.sh --once` on this head was running at the audit, its shards under dev/corpus_shard.sh);
A68S1 is open (`grep -n 'f === nothing && return nothing' src/julia/parity.jl` gives `1376:`, rtutils.jl:15 still cites
genericmemory.c:54); A68S4 is open (MARCH 1.L's ruling still ends at "wt3-latency's invalidation fix"). Audit 67's A67E2,
A67S1, A67S2, A67S3 (`grep -c '@parity "dart2wasm/lib/functions.dart:890 _makeFunctionType"' src/functions.jl` gives 3),
A67S4 (`grep -n "Julia.s exception stack has no reader" src/code_generator.jl` gives `995:`), A66E5 and A66S1's export
half are open as audit 68 left them. Findings A69E1, A69S1, A69S2, A69S3 and A69S4.

Area: builder — no change under src/wasm_builder. 3a8c06c1, a1f78cbc and 134a0198 emit only builder instructions over
typed locals: array.copy and array.set of the memories' data arrays, call_indirect at the selector's signature.

stopgap in disguise: none new.
precedent: dart's WasmArrayExt arms and callDispatchTable, by line.

Area: collection and planning — 3a8c06c1 builds dart's table for field selectors: DispatchTable.build's member loop, the
ranges merged by consecutive class id, one range static, the rest through the table, rows sorted by weight and packed
(dispatch_table.dart:118, :291, :360, :436, :451, :453, :919, :926, :1040, :1045, param_info.dart:59, each read at the
pin), its model dev/formal/FieldSelectorTable.tla with two Broken configs (d200c316, D11); a class a call's receiver
admits without the field rejects Unquarantined at Julia's FieldError, never an empty slot. field_selector_calls
(classes.jl:577) cites TFA's registerGetterCall (table_selector_assigner.dart:142, read: `void registerGetterCall(Member
member, bool calledOnNull) {`). (A69S2, low, D3/D9) a positional field names no field: `grep -n 'name_op.c.val isa Int'
src/julia/classes.jl` gives `587:`, so `getfield(x, 1)` on an abstract receiver is a call of the selector "1", while a
struct's ClassField is named by its fieldname (`classes.jl:260 … string(fieldname(c, i))`), so no class has a member
"1" and every admitted struct reaches dispatch_table.jl:415's rejection, a FieldError Julia never raises (it answers the
field at that position). Loud, never silent, but a wrong diagnosis. Fix: a positional field is resolved per class to its
name before the selector is chosen, or a positional access on an abstract receiver rejects with its own located reason;
a case reaches it. Owner: wt3-translator2. c955b037 keys the constant walk by NirConst, === for an immutable object, as
dev/formal/ValueClasses.tla's seenObj holds every object: the port was wrong, not the model, and the fix makes the walk
linear on a shared DAG (D12, a case of 41 nodes).

stopgap in disguise: none new.
precedent: dart's DispatchTable.build and TFA's selector registration, by line; the walk's model.

Area: emission and diagnostics — b5f056a0 and 0993dc79 port convertType's Unboxing arm (translator.dart:1597, read: the
box class's value field, a ref.cast where the reference is wider), the class the PiNode's (Reshaped boxed_class, named),
a packed value read signed by the class. 582e6e0a ports isdefined's order checks (codegen.cpp:4910-4934, read: invalid
order, an order on a missing field, atomic against non-atomic, each emit_atomic_error) through throw_atomic_error
(rtutils.c:181 jl_atomic_error, read), jl_get_atomic_order's load set as written: A68S2 is fixed. Its run_time_type arm
rejects Core.apply_type and Core.typeof at their statements, so a DataType value comes only from a canonical constant
(`grep -n "f === Core.apply_type || f === Core.typeof" src/intrinsics.jl` gives `344:`): A68S3 is fixed, the guard an arm
rather than a construction. ed8085cd's === over an immutable class's fields compares by ref.eq or integer bits only where
egal is identity or bits (by_reference is egal_by_identity or a DataType), Julia's compare_fields (builtins.c:100, read).
134a0198 ports callDispatchTable (translator.dart:911, read line by line) and moves the ten PolymorphicDispatchers
definitions from Internal to Unported, gaps, outside the headline. 1bed6b74 joins a Union whose typejoin is a UnionAll by
the supertype walk typejoin itself makes, stopping at the first DataType. Overlays, item (a). src/patch/genericmemory.jl
mirrors base/genericmemory.jl as dart's sdk/lib/_internal/wasm/lib/*_patch.dart files mirror the libraries they patch,
registered in PATCH_FILES, and each overlay calls a helper the intrinsifier lowers, as a dart patch calls dart:_wasm's
WasmArray.copy: the structure is dart's. Against Julia: the unsafe_copyto! overlay keeps Base's checks (base/genericmemory.jl:116
at 1.12.7, read), and two array.copy's (data, data#isSet) have jl_genericmemory_copyto's overlap semantics (genericmemory.c:223,
read); the _unsetindex! overlay leaves bits and isbits-union elements as Base does (`arrayelem == isbits &&
datatype_pointerfree(T) && return A`, and nothing for isunion), holds_reference being false for both. (A69S3, low, D9/D6) an
overlay's consistency is asserted, never checked: an intrinsified helper (`@noinline`, lowered by the intrinsifier) still
types its callers by its native body inferred in METHOD_TABLE, and a1f78cbc's message records that the body ed8085cd landed
for wasm_memory_copy!, a call of unsafe_copyto!, is the overlay's own there, "a cycle Julia's inference answers Union{}, which
made the code after the call unreachable, a trap in the module", found only by a1f78cbc's shrinking cases. Fix: the patch
load infers each overlay and each intrinsified helper in METHOD_TABLE and natively and refuses a return type that differs,
Union{} where the native one is not above all. Owner: wt3-memory (src/patch, src/julia/wasm_array.jl). Watch points. (1)
a1f78cbc's message cites `intrinsics.dart:1223 WasmArrayExt.[]= (array.set)`; :1223 is `case StaticIntrinsic.wasmArrayIndex:`,
the get, and `[]=` is :1239 (src cites neither). (2) Field selectors are keyed by name across unrelated classes, dart's
dynamic-call grouping, not TFA's override sets; Julia's fields override nothing, so this is the faithful choice, at the cost
of wider rows.

stopgap in disguise: none new.
precedent: dart's convertType, callDispatchTable and @patch libraries; Julia's codegen isdefined arm and Base's copy, by line.

Area: enforcement and prose — 7794d773 deletes WasmTarget's images before the judged load (A68E1, fixed, audit 68).
6f48fa35's diagnosis is right: under pipefail `grep -q` can close the pipe while git log writes; the one remaining
`git log -1 … | grep -qE` (check.sh:148) is safe while a message fits the pipe buffer. eb5655ce relaunches a shard past a
killed case, failed by name (ReTestItems' record_timeout!, src/ReTestItems.jl:453, as cited): a past-limit verdict
always fails (`_dart_breaks`' first line), so a relaunch cannot turn a shard green over an earlier failure. 88bc946f
merges each family's cases into one program, every case still run in both modules against native; no test hack.
Item (b). 0bc356c5's claim queue is a deterministic sort (corpus last, then cost, then name) claimed by mkdir; which shard
runs a file varies with timing, which changes no verdict while files are independent, and its precedent resolves in
Julia 1.12.7's test tree (`sed -n 267p test/runtests.jl` gives `test = popfirst!(tests)`, outside the pinned checkout); no
finding against D17. (A69E1, medium, D12/D15) a4f60ad3 routes around a src defect: its comment records that loading the
corpus "invalidates the compiled code of every caller that reached those generics at an abstract type … (3145 method
instances, the next WasmTarget.compile then 174 G instead of 0.2)", and fixes it by order, "so here the order isolates
them" (test/src_tests.jl:59). Every user program that adds a method to a Base generic pays the same recompile; the gate no
longer measures it, no case reaches it (`grep -rln invalidat test/src src` gives nothing), and the order names no exit.
Seven landings followed with no D14 red (`wt-ship-failures.tsv` after 13:33:46Z holds none). Fix: a case in test/src that
defines a Base method on a fresh type and then compiles, its instructions within a band, red today (wt3-latency); the
order is deleted by the src commit that turns it green. Owners: lead (test/src_tests.jl), wt3-latency (src). (A69S4, low,
D12) the corpus-last test reads text, not what loads the corpus: `grep -n '_wt_loads_corpus(f::String)' test/src_tests.jl`
gives `60: … occursin("DartCorpus", …)`, but subset.jl:95 includes smoke_corpus.jl under `@static if VERSION >= v"1.13-"`
(:90) and holds no "DartCorpus" (`grep -c DartCorpus test/src/subset.jl` gives 0), so on 1.13 (the full matrix) it is
queued by cost and its invalidations reach the later files of its shard. Fix: the predicate names the corpus's files
(smoke_corpus.jl, DartCorpus), or falls with A69E1's order. Owner: lead. Requirements: D12, D14, D15; no lock fired inside
its band.

R1 and R2. R1: each new definition's citation resolves at its pin (dispatch_table.dart, param_info.dart:59,
translator.dart:911 and :1597, code_generator.dart:3170, intrinsics.dart:1194, rtutils.c:181, builtins.c:100,
genericmemory.c:223, names.dart:25, table_selector.dart:10, table_selector_assigner.dart:142, each line read here). The
known item: c955b037's _meet_constant! names Base.isdefined in its @quarantine's API slot, which L213 never reads
(`_reason_unpinned(e.necessity, sdk)` reads the reason alone); its reason holds no anchor, so it is on the debt list
(`grep -n '_meet_constant!' dev/quarantine_unpinned.txt` gives `15:`): a bare Julia symbol cannot pass L213, no finding
there. (A69S1, medium, R1/L213) an anchor that resolves passes whatever the body ports, and Base's Julia sources have no
pin: `grep -A2 'const JULIA_FILES' src/julia/parity.jl` lists C units only and dev/fetch_julia.sh checks out
`<unit>.h/.c/.cpp` alone, so wasm_memory_unset! (wasm_array.jl:293) and the _unsetindex! overlay (patch/genericmemory.jl:17),
whose bodies port base/genericmemory.jl:78 _unsetindex! (1.12.7, read), cite `julia/src/genericmemory.c:223
jl_genericmemory_copyto`, a copy (`grep -rn 'genericmemory.c:223' src` gives 4 sites), and pass. As the overlay section
grows, every Base port must cite a C neighbour. Fix: the Julia pin table holds base/*.jl (JULIA_FILES' units with a .jl
form, a `function X` or `X(` at column 0 resolving), and the four sites cite Base's lines. Related, open: A66S3 (a path
citation pins on a substring or no symbol). Owner: wt3-parity; the citations wt3-memory. R2: the ten PolymorphicDispatchers
rejection-only bodies move from Internal to Unported and stay outside the headline (dev/src_progress.sh:67 subtracts both
kinds); callDispatchTable, selectorForTarget and _createSelectorForTarget move from a rejection to a body; nothing in the
range counts a rejection-only body as ported. wt3-parity's A64E2 recount did not land in range (`git diff
cad03f24..origin/wt2 | grep -c DartAbstract` gives 0); A66E5 is open.

Resolution: this entry lands alone, prose only, and fixes nothing. A68S2 and A68S3 are fixed by 582e6e0a and leave MARCH
1.D. A69E1 and A69S4 are open on MARCH 1.L. A69S1 is open on MARCH 1.K. A69S2 is open on MARCH 1.E. A69S3 is open on MARCH 1.F. By owner: lead holds A69E1's order and
A69S4 (test/src_tests.jl), wt3-latency A69E1's src fix; wt3-parity holds A69S1's pin table, wt3-memory its citations and
A69S3 (src/patch/genericmemory.jl, src/julia/wasm_array.jl); wt3-translator2 holds A69S2 (src/julia/classes.jl
field_selector_calls, src/dispatch_table.jl).

Follow-up, one item the lead raised after the entry landed: c6707ae0 (landed after 1bed6b74, so outside the range) and
D11. It rewrites dev/formal/Constants.tla (`git show --stat c6707ae0 | tail -1` gives `20 files changed, 313 insertions(+),
677 deletions(-)`) from WT1's interning (ensure_constant_global!, gone) to the port's ConstantCreator, and drops five
claims of the old model (`git show c6707ae0^:dev/formal/Constants.tla | grep -nE
'^(NoFabrication|DeterministicNumbering|NoPartialIntern|Canonicalization|RejectHalts)\b'` gives :371, :400, :410, :426,
:432) with the Broken configs that held them (Fabricate, HashOrder, SkipChild, InternMutable, Isequal). Judged claim by
claim against the new MCConstants.cfg (TypeOK, SharesOnlyEgal, ChildrenFirst, EagerChildrenEager, OperandsTyped,
CyclesReject). Canonicalization (egal eager occurrences share a global) is carried by SharesOnlyEgal's `<=>`;
NoPartialIntern (one non-eager child makes the whole value non-eager) by EagerChildrenEager, with ParentFirst and
IgnoreChildLaziness as its Broken variants; MutableNeverAliases described WT1's design, which the port reverses (a mutable
constant interned by identity, M1 and M2 equal and apart under SharesOnlyEgal), so its drop is right; RejectHalts is
vacuous in a model whose run is one functional step (`Next == UNCHANGED vars`), the outcome terminal by structure. Two
claims are port-independent and have no successor. (A69E2, medium, D11/D9/D17) NoFabrication and DeterministicNumbering
were dropped with their Broken variants, and the model no longer reaches either: `grep -c 'undef\|Undef'
dev/formal/Constants.tla` gives 0, so no constant with an #undef field is in its universe, though the port compiles them
(779986b2's set flag, 7023257b's constant Vector, a1f78cbc's unset elements); and no claim fixes a constant's number to
its discovery order, independent of hashing, which byte-identical modules rest on. The commit names what it replaced,
not what it dropped. D11's "never weaken an invariant" is checked by nothing: dev/formal/run_tlc.sh reads the cfgs as
they stand, so a rewrite can delete a claim and stay green. Fix: both claims restated over the new model's state (a
constant holding an #undef field reaching an outcome other than its located rejection or its sanctioned sentinel; an
info's number the rank of its first use), each with a Broken cfg TLC rejects (wt3-runtime, as the lead routed it);
then a lock that the claims named by the cfgs' INVARIANTS and `\* expect:` lines shrink only in a commit that names each
dropped claim and its successor (wt3-parity). A69E2 is open on MARCH 1.C.

## 2026-11-01 — audited through 498bb40d (1bed6b74..498bb40d: getListBaseArray Internal, the memory overlays' grow and delete cases, varargs packed as Julia's codegen packs them, the corpus-last predicate, a demand's argument types, StackTrace.current, the dart run's warm-up, getfield of a tuple at a run-time index, a positional field's selector, Constants' two claims restated)

The seventieth audit, beside the work, covers the 10 commits of 1bed6b74..498bb40d that are not audit entry 69 (45d3430c,
96c321f2; c6707ae0 judged in 69's follow-up): db12aa4a, 8a3daed8, 9059aa71, da22dcf8, c672f6e4, 0d1d234a, 7600f4d3,
e7915a8b, f05b2fa8 and 498bb40d, read here, under Dale's R1 and R2 as standing sections. Every finding rests on one exact
command, quoted. Standing items. src changes in 17 files (`git diff --stat 1bed6b74..origin/wt2 -- src | tail -1` gives
`17 files changed, 434 insertions(+), 87 deletions(-)`); no exemption lands (`git diff 1bed6b74..origin/wt2 -- src | grep
-cE '^\+.*(Reshaped:|Fields with no Julia counterpart)'` gives 0). The debt list reads 400 at both ends (`grep -v '^#'
dev/quarantine_unpinned.txt | grep -c .`). Earlier findings: A66E5 is fixed by db12aa4a; A69S2 by f05b2fa8; A69S4 by
da22dcf8 (`grep -rln 'smoke_corpus.jl\|DartCorpus' test/src` gives dart_tests.jl and subset.jl, both matched by the new
`r"DartCorpus|smoke_corpus\.jl"`); A69E2 by 498bb40d for NoFabrication, its DeterministicNumbering half reopened as A70E1.
Open as they stood: A69E1 (`grep -rln invalidat test/src src` gives only test/src/dart_tests.jl, the warm-up's comment; no
case reaches the invalidation, and 7600f4d3 now carries its ~174 G inside a 300-s warm-up, a second place the src fix must
delete); A69S1 (`grep -A3 'const JULIA_FILES' src/julia/parity.jl` still lists C units only; `grep -rn 'genericmemory.c:223'
src | wc -l` gives 4); A69S3; A68E2 (`grep -n '^SHARDS=' dev/check.sh` gives `112:SHARDS=6`); A68E3 (`tail -1
.git/wt-corpus.tsv` gives eb5655ce's `hung 1213` row, no corpus run judged since); A68S1 (`grep -n 'f === nothing && return
nothing' src/julia/parity.jl` gives `1378:`); A68S4; A67E2, A67S1-A67S4, A66S1's export half, A66S3, A64E2. The
_meet_constant! anchor (wt3-runtime) is unchanged: `grep -n '_meet_constant!' dev/quarantine_unpinned.txt` gives `15:`, its
@quarantine (classes.jl:76) still naming Base.isdefined with no pinned anchor in its reason. Findings A70S1, A70S2, A70S3,
A70S4, A70E1, A70E2 and A70E3.

Area: builder — no change under src/wasm_builder. e7915a8b emits a select per field over a typed local, ref.cast per
class arm and a trailing unreachable; 9059aa71 a struct.new of the packed tuple. 9059aa71's two dart cases reach the
builder's own refusal, "Uninitialized local with non-defaultable type" (D10 working). (A70E3, low, D12) that refusal is a
code generator defect in try_table regions, now recorded :wt_bug (`grep -n 'nested_catch_rethrow' test/src/dart_tests.jl`
gives `636: … :wt_bug`), and no MARCH row names it or an owner (`grep -c 'non-defaultable' dev/MARCH.md` gives 0). Fix: a
case in test/src reaching the try/finally local, red, and its fix at the local's definite initialisation. Owner:
wt3-cgstubs2 (src/code_generator.jl).

stopgap in disguise: none new.
precedent: dart's MacroAssembler.classIdSearch (code_generator.dart:5709, read), Julia's CreateSelect (cgutils.cpp:2855).

Area: collection and planning — 9059aa71 numbers the packed tuple and each call's packed operands (classes.jl), and
f05b2fa8 resolves a position to the field each admitted class holds there (builtins.c:994 get_checked_fieldindex, read):
a name is its own selector, a position past a class's fields or naming two fields rejects Unquarantined, located. Watch:
`isempty(names) ? string(f)` (classes.jl:590) still answers the selector "1" when no class is admitted, and a position
below 1 reaches `fieldname(c, f)` as a host error, not a located rejection. c672f6e4 types a demand's arguments by the
specialization, where a cached body carries no slottypes (D12, a case). (A70S4, low, D3/D5) its slottypes unwrap each
specTypes parameter (`grep -n 'slottypes = Any\[Base.unwrapva' src/julia/subset.jl` gives `260:`), so a varargs method's
slot is typed by its first trailing argument and a slot past a zero-length tail indexes past the vector; Julia's codegen
types that slot by the packed tuple (`sed -n 8289p ~/.cache/wasmtarget/julia/src/codegen.cpp` gives `vatyp = specsig ?
compute_va_type(abi, nreq) : (jl_tuple_type);`), and 9059aa71, in the same range, made NirVarargPacking that type's one
source. Fix: the slottypes read nir_argument_type (or NirVarargPacking) for the va slot; a case demands through a varargs
entry. Owner: wt3-runtime (src/julia/subset.jl). (A70S1, medium, D5) e7915a8b's arms come from one list at the site, and an
empty list rejects located (`Unquarantined(… which no class of the closed world is)`), but that list is a third reading of
the closed world's concrete classes below a type: `grep -n 'isconcretetype(c) && c <:' src/*.jl` gives types.jl:681 and
:729 (over `numbering.class_ids`) and intrinsics.jl:302 (over `keys(t.class_info)`, then indexed into class_ids), none
through get_concrete_class_id_range (class_info.jl:544, dart's getConcreteClassIdRange). Two sources can disagree, and a
class in class_info without an id is a host KeyError, not a rejection. Fix: ClassIdNumbering answers a Julia type with no
class of its own (a tuple's UnionAll or Vararg) from its one numbering, and all three sites read it, the commit deleting the
comprehensions. Owner: wt3-memory (src/class_info.jl, src/intrinsics.jl; types.jl's two sites in the same commit).

stopgap in disguise: none new.
precedent: dart's getConcreteClassIdRange and Julia's get_checked_fieldindex, by line.

Area: emission and diagnostics — e7915a8b, item (a). For a concrete tuple it ports Julia's bounds check as written
(cgutils.cpp:2067 bounds_check_enabled, :2081 emit_bounds_check, read: `i - 1 <u len`, the flag's constant false,
jl_options' ON and OFF), nfields 0 and 1 as emit_getfield_unknownidx has them (:2805-:2817, read), and the select chain
(:2855-:2866, read). The trailing unreachable is justified: every allocation of a class rejects without its class_info
(9059aa71's `info === nothing && reject!`), A68S3's arm makes no type at run time, and Julia's type soundness puts every value
of static type T in a class below T, so the closed world's list is complete and the miss cannot run. (A70S2, low, R1/D3)
the heterogeneous tuple (Int64, String, Float64) and a run-time-length tuple whose elements are not one leaf type are arms
Julia does not take: the unboxed select chain runs only `if (isboxed || (issame && isa<ArrayType>…))` (cgutils.cpp:2855),
the run-time-length arm only for `is_tupletype_homogeneous(utt->parameters, true)` (codegen.cpp:4585), and every other read
is `prepare_call(jlgetnthfieldchecked_func)` (codegen.cpp:4620), the runtime's boxed field. The answer agrees (a boxed
field); the citation names the inlined arm, and the comment does not say how WasmTarget differs (no runtime layout to read,
so the closed world's switch and a boxed select stand for jl_get_nth_field_checked). Fix: cite :4620 for those two cases and
name the difference in the @parity's comment. Owner: wt3-memory. Watch: the module now follows the compiling process's
--check-bounds (`grep -n 'opt = Base.JLOptions().check_bounds' src/intrinsics.jl` gives `298:` and `671:`), as Julia's own
code does; Pkg.test runs with it on, so the probes must hold one setting. 9059aa71, item (c). The packing criterion is
uses_specsig's vararg test (codegen.cpp:2792, read: `jl_vararg_kind(…) == JL_VARARG_UNBOUND` returns false), the entry
pack is codegen.cpp:8859's specsig arm (emit_new_struct for a concrete tuple, jl_f_tuple otherwise, here a located
rejection), and the call pack is the jlcall arm's jl_f_tuple (:8881, the message's :8879 is the brace above it) moved to the
caller, a reshape the quarantine names. uses_specsig's other false answers (needsparams, a non-DataType sig) are ABI choices
with no behavior; the port treats a UnionAll specTypes as specsig, harmless while no needsparams body compiles. (A70S3,
medium, D3) the packed tuple's class is inference's, not codegen's: `grep -n 'va_process_argtypes(Core.Compiler.fallback_lattice'
src/julia/nir.jl` gives `573:` (NirVarargPacking.packed) and `grep -n 'return Tuple{(nir_value_type' src/julia/nir.jl` gives
`591:`, but codegen builds the entry tuple as compute_va_type (`sed -n 8110,8115p codegen.cpp`: `if
(is_uniquerep_Type(argType)) argType = jl_typeof(jl_tparam0(argType));`), and jl_f_tuple types the call's tuple by each
value's typeof. So f(xs...) called as f(Int) packs Tuple{DataType} in Julia and rejects in WasmTarget at
"whose class only run time knows" (Tuple{Type{Int64}} is not concrete). Located, never silent, but an approximation where
Julia answers. Fix: the tuple's class from compute_va_type's rule (the slot's type stays inference's), and the call's from
each operand's class; a case with a type argument against native. Owner: wt3-cgstubs2 (src/julia/nir.jl,
src/code_generator.jl). Watch: only _visitArguments packs an open count; _virtualCall (Unported) and any closure call must
read nir_vararg_call_tuple when ported. 0d1d234a ports StackTrace.current, _EmbedderStackTrace and stackTraceGetCurrent at
their lines (stack_trace_patch.dart:15, :21, embedder.dart:238, each read at the pin), the non-standalone import a located
rejection.

stopgap in disguise: none new.
precedent: Julia's emit_getfield_unknownidx, emit_bounds_check, uses_specsig and the rest-argument arms, dart's standalone
patch, by line.

Area: enforcement and prose — 8a3daed8 adds seven cases against native in an already compiled program; no hack. da22dcf8
is A69S4's fix as asked. 7600f4d3 gives the dart run's first compile its own 300-s band (D17, "about twice the 129 s"),
printed with its G, a plant failing by name; it is honest, and it is the second carrier of A69E1's 174 G. db12aa4a's
rejection is right; its prose says dart calls getListBaseArray "only from the Function.apply intrinsic", but `grep -rn
getListBaseArray pkg/dart2wasm/lib` also gives translator.dart:2466 (indexList, itself with no caller at the pin); a
watch point, the conclusion holds. Item (b), 498bb40d against D11. Each Broken cfg lists its own claim first, so TLC's first
violation is that claim; whether a Broken also breaks another is not checked (HashOrder does, ChildrenFirst, by its own
cfg's comment). NoFabrication is restated faithfully: U's #undef field reads as the null, Dflt never gets an info, Ubad
rejects, and Fabricate violates it. (A70E1, medium, D11/L112) DeterministicNumbering no longer has a ground truth:
`grep -n 'nextGlobal = @ + 1, !.order = Append' dev/formal/Constants.tla` gives `164:`, the number and the recorded order
advanced in one step, and the claim reads that record (`:203 DeterministicNumbering == Ok => \A n \in 1..Len(st.order) :
st.def[st.order[n]] = n`), so it holds for any walk order. The claim it replaced computed each rank from the program alone,
"without reference to classId/globalOf" (`git show c6707ae0^:dev/formal/Constants.tla | sed -n 413,425p`). The L112 class
the cfg names is a Dict's walk, which changes the order, not the counter; HashOrder breaks the counter only. Fix: the rank
computed apart from Ensure, the children-first walk of the program's uses in operand order, and a Broken variant that walks
siblings or uses in HashSeq's order with the counter intact; then the shrink-only claim lock A69E2 asked for (wt3-parity).
Owner: wt3-translator2 (dev/formal Constants). (A70E2, low, D13) a landed commit was logged twice: `awk -F'\t'
'$1>="2026-11-01"' .git/wt-landings.tsv | cut -f2 | sort | uniq -d` gives `f05b2fa8` (14:46:00Z and 14:47:31Z), and
wt-ship-failures.tsv shows wt3-constants shipping it a third time at 14:48:58Z. ship.sh's exec line pushes and appends a
row whether or not the commit was already on the march, so a lane re-shipping a landed head inflates D13's band. Fix: the row
written only when the push moved origin's branch. Owner: lead (dev/ship.sh). Requirements: D3, D5, D11, D12, D13; no lock
fired inside its band.

R1 and R2. R1: each new definition's citation resolves at its pin: intrinsics.dart:607 and :1194, code_generator.dart:2299,
:5684, :5709, kernel_nodes.dart:620, embedder.dart:238, stack_trace_patch.dart:15 and :21; codegen.cpp:2792, :4564, :8102,
:8859; cgutils.cpp:2067, :2081, :2768, :2794; builtins.c:994, each line read here. The bodies port what they cite, except
A70S2's two arms (cited to an inlined arm Julia does not take) and A70S3's tuple class (inference's where codegen's
decides). Nothing in the range is built without a precedent. R2: by the diffs, db12aa4a moves get_list_base_array from a body
to an Internal rejection (headline -1, Internal +1); 0d1d234a moves stack_trace_current from one Unported rejection to a body
(gaps -1, headline +1) and adds three runtime bodies (stack_trace_get_current, _EmbedderStackTrace, StackTrace_current);
e7915a8b adds one body (generateStaticIntrinsic's tuple_index arm) and fills generate_instance_getter_intrinsic, a body
before. Net from 1bed6b74: headline +1, Internal +1, gaps -1. This entry's own landing measured the head after the range:
`src: 3119 of 3404 anchored dart definitions ported with a body … 273 whose body is one Internal rejection … and 11 one
Unported or Unquarantined rejection` (ship.sh on 2be875a4), so the 3119/273/11 given at the audit's start is the range's end,
not its start, which no record holds; each move above is a real body or a rejection leaving the headline (the three
runtime bodies outside the dart count). dart's _EmbedderStackTrace.toString is not ported and no rejection names it, so the runtime's gap count does not
hold it; a watch point while no Julia call reaches it.

Resolution: this entry lands alone, prose only, and fixes nothing. A66E5 leaves MARCH 1.C, A69S2 1.E, A69S4 1.L, A69E2 1.C.
A70E1 and A70S4 are open on MARCH 1.C; A70S1, A70S2, A70S3 and A70E3 on 1.D; A70E2 on 1.L. By owner: wt3-memory holds A70S1
and A70S2 (src/class_info.jl, src/intrinsics.jl); wt3-cgstubs2 A70S3 and A70E3 (src/julia/nir.jl, src/code_generator.jl);
wt3-runtime A70S4 (src/julia/subset.jl); wt3-translator2 A70E1 (dev/formal/Constants.tla), wt3-parity its claim lock; lead
A70E2 (dev/ship.sh).

## 2026-11-01 — audited through 6378f3b4 (498bb40d..6378f3b4: the late read inferred once, the overlays' agreement checked at load, one landings row per commit, ship's held-lane and retry refusals, a seventh shard, Constants' numbering against the program's order, one reading of a type's classes, a run-time tuple index's BoundsError demand, a PiNode's ghost and trap, D14 raised to 140 s by Dale's word, open-count varargs read)

The seventy-first audit, beside the work, covers the 12 commits of 498bb40d..6378f3b4 that are not audit entry 70 (2be875a4,
77a46e8e): 6b79bdf9, 3ea90d3b, a3d6a52e, 3d0e7725, 2ebfbe5b, 918117d1, a7515a01, d23c9f8b, 898999d9, 1189af25, 872107aa and
6378f3b4, read here, under Dale's R1 and R2 as standing sections. Every finding rests on one exact command, quoted. Standing
items. src changes in 9 files (`git diff --stat 498bb40d..origin/wt2 -- src | tail -1` gives `9 files changed, 172
insertions(+), 39 deletions(-)`); one exemption lands (`git diff 498bb40d..origin/wt2 -- src | grep -cE '^\+.*(Reshaped:|Fields
with no Julia counterpart)'` gives 1: a7515a01's `Reshaped: klass`, class_info.jl:545, which names how Julia differs, a type
that is no class of the closed world, D7 met). The debt list reads 400 at both ends (`grep -v '^#' dev/quarantine_unpinned.txt
| grep -c .`). Earlier findings: A69S3 is fixed by 3ea90d3b; A70S1 by a7515a01 and reopened by 872107aa as A71S1; A70S2 by
a7515a01 (`sed -n 4620p codegen.cpp` gives the `prepare_call(jlgetnthfieldchecked_func)` call the comment now cites); A70S4 by
872107aa, which does not name it (subset.jl:278-279 type the va slot by NirVarargPacking.packed, `first` being m.nargs, so a
zero-length tail indexes no further than specTypes holds); A70E2 by a3d6a52e (`awk -F'\t' '$1>="2026-11-01T15"'
.git/wt-landings.tsv | cut -f2 | sort | uniq -d` gives nothing); A70E1 by 918117d1 for its ground truth, the rest carried as
A71E2. Open as they stood: A69E1 (6b79bdf9 cuts one tree and measures no residual; `grep -rln invalidat test/src src` gives
dart_tests.jl's warm-up and late.jl's comment, no case); A69S1 (`grep -A3 'const JULIA_FILES' src/julia/parity.jl` lists C
units only); A68E2 and A67E1, now seven shards (`grep -n '^SHARDS=' dev/check.sh` gives `115:SHARDS=7`); A68E3 (`tail -1
.git/wt-corpus.tsv` gives f05b2fa8's `hung 1216` row); A68S1 (`grep -n 'f === nothing && return nothing'
src/julia/parity.jl` gives `1421:`); A68S4, which 3d0e7725 makes worse (below); A70S3 (`grep -n
'va_process_argtypes(Core.Compiler.fallback_lattice' src/julia/nir.jl` gives `573:`); A70E3 (`grep -n nested_catch_rethrow
test/src/dart_tests.jl` gives `636: … :wt_bug`); A67E2, A67S1-A67S4, A66S1's export half, A66S3, A64E2. Item (d):
at 6378f3b4 _late_get was still unpinned (`git show 6378f3b4:dev/quarantine_unpinned.txt | grep -n _late_get` gives
`90:julia/late.jl _late_get`); 9d72a168, landed after the range, pins it by dart's late getter lowering
(late_lowering.dart:22 createGetterWithInitializer and :271 createGetterBodyWithoutInitializer, both read at the pin) and
deletes the line. Seven commits landed after 6378f3b4 while this entry queued (`git log --oneline 6378f3b4..c03a8ba9`:
9d72a168, 8db1a970, e55edc4d, 667bd48f, 4dfdfc88, 3c1b8ede, c03a8ba9); their fixes (A69S1, A66S3, A67E2, A67S2, A66E3,
A66S4, A66E4) are audit 72's to judge, and the statuses above are 6378f3b4's. Findings A71S1, A71S2, A71S3, A71E1, A71E2
and A71E3.

Area: builder — no change under src/wasm_builder. 898999d9 emits `unreachable` for a PiNode between two concrete types and
the singleton's constant for a narrowing to a ghost; 872107aa an i64.const per class arm of class_id_search with an
unreachable miss, the arm's list complete by A68S3's argument (#70's area: emission). Nothing new reaches the builder's own
refusals.

stopgap in disguise: none new.
precedent: dart's classIdSearch (code_generator.dart:5709, read in #70); Julia's convert_julia_type (codegen.cpp:2638, read).

Area: collection and planning — a7515a01 makes get_concrete_class_id_range (class_info.dart:831, read at the pin: `List<Range>
getConcreteClassIdRange(Class klass)`) the one reading of a type's concrete classes: its Reshaped arm scans class_ids once per
type, cached in `IdDict{Type,…}`, normalize sorts (class_info.dart:1093's port, class_info.jl:717), and the run-time index maps
each id to `t.classes[][id + 1].cls`, the indexing class_info.jl:373 fills. types.jl's two scans and intrinsics.jl's are gone.
(A71S1, medium, D5) 872107aa, in the same range, writes the deleted reading back for nfields: `grep -n 'isconcretetype(c) &&
c <:' src/*.jl src/julia/*.jl` gives class_info.jl:564 (the one reading) and `intrinsics.jl:1318: local classes =
sort!(DataType[c for c in keys(t.class_info) if c isa DataType && isconcretetype(c) && c <: T];`, over class_info and indexed
into class_ids, A70S1's exact shape, a class with info and no id a host KeyError. Fix: the nfields arm takes its ids from
get_concrete_class_id_range and its classes from t.classes, as the tuple_index arm does at intrinsics.jl:309-311, the commit
deleting :1318. Owner: wt3-memory (src/intrinsics.jl), 872107aa's lane told. d23c9f8b and 872107aa extend RUNTIME_DEMANDS'
:bounds by _reads_tuple_at_run_time_index (subset.jl), its operand typed by argextype as the trim verifier types it, matching
the intrinsifier's own predicate (a DataType tuple; a literal index only where the type has no layout, codegen.cpp:4563, read:
`if (jl_struct_try_layout(utt))`, the constant-index arm inside it).

stopgap in disguise: none new.
precedent: dart's getConcreteClassIdRange and normalize, Julia's argextype and jl_struct_try_layout, by line.

Area: emission and diagnostics — 872107aa's nfields arm ports codegen.cpp:4712's (read: a constant for a concrete type, else
`emit_datatype_nfields(ctx, emit_typeof(…))`), only for tuples, the rest rejecting as before; its constant-index read of a
layout-less tuple goes where Julia's does (codegen.cpp:4580, `vidx = emit_unbox(…)`, then the homogeneous arm or :4620's
runtime call, both now cited). 898999d9 answers convert_julia_type's two early arms in its order (read: `if
(type_is_ghost(T)) return ghostValue(ctx, typ);` before `if (jl_is_concrete_type(typ)) { if (jl_is_concrete_type(v.typ))`),
and its three cases run against native. (A71S3, low, R1/D7) the PiNode's call passes a skip flag: `sed -n 6382,6385p
codegen.cpp` gives `Value *skip = NULL; return convert_julia_type(ctx, emit_expr(…), jl_fieldref_noalloc(expr, 1), &skip);`,
and with skip set convert_julia_type stores 1 into it and returns `jl_cgval_t()` (:2651-2655), never CreateTrap. So Julia
emits no trap for a PiNode between two concrete types, an empty value on a dead path; WasmTarget's `unreachable` is stricter
and sound there, but the comment says Julia's answer is a trap and does not say how WasmTarget differs. Fix: cite :6384's skip
and state the difference (a trap where Julia leaves the value undefined). Owner: wt3-cgstubs2 (src/code_generator.jl). Watch:
the ghost arm's `own !== narrowed` gives the ghost for a Union{} operand, where Julia's fast path (`v.typ == jl_bottom_type`)
returns the operand; unreachable either way. d23c9f8b cites cgutils.cpp:2794 emit_getfield_unknownidx (read), its case the
program's only raising read.

stopgap in disguise: none new.
precedent: Julia's emit_builtin_call nfields arm, emit_getfield's arms and convert_julia_type, by line.

Area: enforcement and prose — item (a), 1189af25: exactly Dale's choice. `D14_RED=140` (check.sh:198), a literal assigned in the
script, the target still 60 s in the message and the header; the exit is stated in check.sh (:195-197, the first-compile cut
back to 120 s and SHARDS to four) and in the ledger's D14 band (`red past 140 s from 2026-11-01 until the first-compile cut
lands, Dale: "Raise to 140 s until the cut"`); the trailer reads `Ledger-change: D14 — Dale 2026-11-01: "Raise to 140 s
until the cut"`. 6378f3b4 makes the retry count read that band. (A71E3, low, D19) the charter still says 120: `sed -n 138p
dev/CHARTER.md` gives `target, red past 120 s: WasmTarget loads, …`, C10's clause, so the code and the clause that decides done
disagree for the raise's life. Fix: propose the C10 edit carrying Dale's words and the same exit, by land.sh's charter
authorisation. Owner: lead (dev/CHARTER.md proposal). Item (b), 2ebfbe5b. (A71E1, medium, D31/D20) the seventh shard bought
14 G on the slowest shard (`git show 1189af25 | grep -c '589 G to 575'` gives 1; about 3 s at the commit's 111 s for 589 G)
and costs one more process paying the ~300 G first compile on every src check: eight Julia processes (load, ratchet, seven
shards) on a machine of four performance cores, the saturation D31 forbids, for a gain inside the noise the retry ruling
exists for. With the band at 140 s the reason given for it (every change past 120 s) is gone. Revert it, back to six, in one
commit that reads the critical path at six against 140 s; keep the sixth until the cut, and measure five before keeping
six. Owner: lead (dev/check.sh). Watch: 3ea90d3b's check costs "cold, 5.2 s of first inference" by its own message, inside
every src change's load on D14's critical path (load 13 s at the sixth shard's commit, 15 s at the seventh's). Item (c),
3d0e7725. The held-lane refusal and the retry cap live in ship.sh, the one landing path; a direct `git push origin HEAD:wt2`
or a reworded subject (the cap keys on its first 60 characters) passes both, so they are D6 stopgaps, which the cap's
comment says and the hold's does not. The cap's exit: ship.sh:22 says `ended by A68S4's measure`, a finding whose text is
that the exit names no measure, and MARCH 1.L says `deleted by wt3-latency's invalidation fix`: two exits, neither a measure,
so A68S4 stays open and now holds both. Fix (A68S4's): one exit, a measure (the last N src checks under D14_RED with a stated
margin), written in ship.sh and 1.L alike. a3d6a52e is A70E2's fix (a log lookup rather than "the push moved origin's branch";
equivalent while a hash is pushed once). Item (e), 918117d1. DeterministicNumbering now has a ground truth from the program
alone (Pos over the program, Reaches over Ensure's reads), and the walk's record is gone from the state. (A71E2, low, D11) its
second conjunct, the order of use, has no Broken variant that breaks it alone: HashOrder numbers by `Hash(c)` (`grep -n 'n ==
IF HashOrder' dev/formal/Constants.tla` gives the counter replaced), which the first conjunct (`= 1..Cardinality(Defined)`)
catches, and `ls dev/formal/MCConstants*Broken.cfg` lists no variant that walks siblings or uses out of order with the counter
intact, the variant A70E1 asked for. Fix: that Broken variant, its cfg expecting DeterministicNumbering, TLC reporting it; the
claim lock A69E2 asked for (wt3-parity) still absent. Owner: wt3-translator2 (dev/formal/Constants.tla). Item (d).
6b79bdf9's @nospecializeinfer precedent (abstractinterpretation.jl:3904, read in the 1.12.7 install: `@nospecializeinfer
function widenreturn(@nospecialize(rt), info::BestguessInfo)`) sits in a comment, and `ls ~/.cache/wasmtarget/julia/Compiler/src`
gave only typeinfer.jl at the audit; a watch point now that c03a8ba9 lets a Compiler unit be pinned. Requirements:
D5, D6, D7, D11, D19, D20, D31; no lock fired inside its band.

R1 and R2. R1: each new definition's citation resolves at its pin: class_info.dart:831 and :1093, intrinsics.dart:607 and
:1194, code_generator.dart:3170 (dart at 898a1e4b); codegen.cpp:2638, :4563, :4620, :4712, :6382; cgutils.cpp:2794; each line
read here. (A71S2, low, R1) 3ea90d3b's check_overlays_agree and _methods_of_file cite `julia/src/julia.h:905 jl_methtable_t`,
which `sed -n 905p julia.h` gives as `} jl_methtable_t;`, the struct's closing brace: a data layout, not the algorithm (infer
each signature over both tables and compare). Its docstring's precedent, `test/compiler/AbstractInterpreter.jl`, carries no
line and is not in the pinned checkout (`ls ~/.cache/wasmtarget/julia` gives base, Compiler, src). The check is enforcement,
not a compiler port, and catches a real class (the a1f78cbc cycle); but its precedent must resolve. Fix: cite the overlay
interpreter test's lines at the pin (the file added to the checkout) and @consistent_overlay's definition by line. Owner:
wt3-parity (src/julia/parity.jl). Nothing else in the range is built without a precedent. R2: by the diffs (`git diff
498bb40d..origin/wt2 -- src | grep -nE '^[-+].*(@parity|@unported|reject!\((Unported|Internal|Unquarantined))'`), one method
is added to an anchored definition (generateStaticIntrinsic's nfields arm, a body with a located rejection for an empty
class list) and get_concrete_class_id_range's signature widens; no definition moves between body, Internal and gap, so the
headline is unchanged by the range. The lead's last measure (3119 bodies, 273 Internal, 12 stubs or gaps) differs from #70's
landing (11 gaps) with no diff here that adds a gap; a watch point, read again from this entry's landing.

Resolution: this entry lands alone, prose only, and fixes nothing. A69S3 leaves MARCH 1.F; A70S1, A70S2 1.D; A70S4, A70E1
1.C; A70E2 1.L. A71S1 and A71S3 are open on 1.D; A71S2 on 1.F; A71E2 on 1.C; A71E1 and A71E3 on 1.L. By owner:
wt3-memory A71S1 (src/intrinsics.jl); wt3-cgstubs2 A71S3 (src/code_generator.jl), with A70S3 and A70E3; wt3-parity A71S2
(src/julia/parity.jl); wt3-translator2 A71E2 (dev/formal/Constants.tla); lead A71E1 (dev/check.sh), A71E3 (dev/CHARTER.md
proposal) and A68S4 (dev/ship.sh, 1.L).

Follow-up, R1's runtime clause (Dale, after the entry landed: each definition of src/julia/runtime/, src/patch/ and
wasm_array.jl ports the nearest existing implementation, dart's runtime at the pin, Julia's Base or C runtime at JULIA_PIN,
or a named production implementation, its citation read against its body). In 498bb40d..6378f3b4 one such definition
changes (`git diff --stat 498bb40d..6378f3b4 -- src/julia/runtime src/patch src/julia/wasm_array.jl` gives `src/julia/runtime/rtutils.jl
| 5 +++--`): 6b79bdf9's nir_foreign_operands, cited to julia/src/ccall.cpp:1419 emit_ccall. The line resolves at JULIA_PIN
(`sed -n 1419p ~/.cache/wasmtarget/julia/src/ccall.cpp` gives `static jl_cgval_t emit_ccall(jl_codectx_t &ctx, jl_value_t
**args, size_t nargs)`), and the body is what it ports: five header operands (args[1..5]: pointer, rettype, argtypes, nreq,
cconv; :1423-1428), `nccallargs = jl_svec_len(at)` (:1425) and the arguments from `args[fc_args_start + i]`, fc_args_start 6
(:1416, :1491), which is `node.args[6:5 + length(types)]`. 6b79bdf9 only binds the svec before taking its length; the
answer is unchanged. src/patch/ and wasm_array.jl are unchanged in the range (3ea90d3b reads wasm_array.jl's methods and
changes none). No finding; the clause is a standing section of R1 from audit 72 on.

## 2026-11-01 — audited through 5f05f54e (6378f3b4..5f05f54e: _late_get pinned to dart's late getter lowering, path citations that declare their symbol, ship's port class by code lines, the precedent resolver and written signature folded away, JULIA_PIN read against the master, names refused where recorded, Base's and the compiler's .jl files pinned, fill! of a byte memory by overlay, PolymorphicDispatchers, the dynamic table's guards Internal, back to six shards, C10's 140-s band, the memory overlays re-cited to Base, Constants' ReverseUses, Node 26, per-compile dart readings)

The seventy-second audit, beside the work, covers the 17 commits of 6378f3b4..5f05f54e that are not audit entries (b3dcc076,
entry 71; c70c3c67, its follow-up): 9d72a168, 8db1a970, e55edc4d, 667bd48f, 4dfdfc88, 3c1b8ede, c03a8ba9, 70207e38, 27cec3a2,
08cb5604, e825ebf2, 61ffebbb, 85d54f4a, 73b64c1e, 4c682f55, 26e75a8c and 5f05f54e, read here, under Dale's R1 (its runtime
clause standing from this audit on) and R2 as standing sections. Every finding rests on one exact command, quoted. Standing
items. src changes in 20 files (`git diff --stat 6378f3b4..origin/wt2 -- src | tail -1` gives `20 files changed, 261
insertions(+), 142 deletions(-)`); no exemption lands (`git diff 6378f3b4..origin/wt2 -- src | grep -cE
'^\+.*(Reshaped:|Fields with no Julia counterpart)'` gives 0). The debt list reads 398, from 400 (`grep -v '^#'
dev/quarantine_unpinned.txt | grep -c .`): 9d72a168 deletes `julia/late.jl _late_get`, 667bd48f `julia/parity.jl
_written_signature`. Earlier findings: A66S3 is fixed by 8db1a970 for its citation rule and its other half dropped (A72S2);
A66E4 by e55edc4d; A67E2 and A67S2 by 667bd48f (the resolver a local function of _reason_unpinned, whose line covers it; the
signature folded into _identity, itself listed, since L227 refuses a line added); A66E3 by 4dfdfc88; A66S4 by 3c1b8ede; A69S1
by c03a8ba9 (Base's and the compiler's .jl units) with 85d54f4a (the four memory citations moved to Base's methods, below);
A71E1 by e825ebf2 (`grep -n '^SHARDS=' dev/check.sh` gives `114:SHARDS=6`; five not measured, a watch); A71E3 and A68S4 by
61ffebbb (below); A71E2 by 73b64c1e for its Broken variant, its claim-lock half (A69E2's) left open. Open as they stood:
A71S1 (`grep -n 'isconcretetype(c) && c <: T' src/intrinsics.jl` gives `1340:`); A71S2 (`grep -n 'julia.h:905'
src/julia/parity.jl` gives `655:` and `673:`); A71S3 (code_generator.jl:2016 cites codegen.cpp:2638 alone, no :6384 skip);
A70S3 (`grep -n 'va_process_argtypes(Core.Compiler.fallback_lattice' src/julia/nir.jl` gives `573:`); A68S1 (`grep -n 'f ===
nothing && return nothing' src/julia/parity.jl` gives `1428:` and `1440:`); A68E3 (`tail -1 .git/wt-corpus.tsv` gives
f05b2fa8's `hung 1216` row); A68E2 and A67E1 at six shards; A69E1, A67S1, A67S3, A67S4 and A66S1's export half, carried, not
re-read; A64E2 not landed (`git log --oneline --grep=A64E2 6378f3b4..origin/wt2` gives only c03a8ba9, which names it as the
typeinfer unit's reason). Two commits landed while this entry queued (`git log --oneline 5f05f54e..origin/wt2`: bdd5539c,
5bfcb2b7); 5bfcb2b7 names A70E3 fixed (a catch's stash defaultable, both :wt_bug cases :compiled) and drops it from 1.D,
audit 73's to judge. Findings A72S1, A72S2 and A72E1.

Area: builder — 3c1b8ede moves D10's UTF-8 refusal of a name-section name from NameSection.serializeContents to each
recording site, InvalidModule naming the site's dart line: StructType and ArrayType (type.jl:158, :180), FunctionBuilder,
FunctionsBuilder.import's function name, GlobalBuilder, ModuleBuilder, InstructionsBuilder.addLocal, and Dart2Wasm's three
writes. The serializer's check becomes an Internal. The writes into the name maps are covered: `grep -rnE
'(local_names|field_names)\[[^]]*\] *=' src` gives seven sites; the computed ones (code_generator.jl:744, class_info.jl:250,
closures.jl:425, instructions.jl:420) each refuse first; code_generator.jl:821 and closures.jl:132, :538 write literals;
types.jl:224 copies a recorded name. The other writes of a name, `grep -rnE '\.(global_name|function_name|name) *= ' src`,
are translator.jl:2014 and :2023 (copies of recorded definitions) and types.jl:220 (a recgroup name made of recorded ones).
27cec3a2 emits through the builder's class_id_search and call paths only.

stopgap in disguise: none new.

precedent: wasm_builder's own constructors by line; the serializer's check kept as the alarm (D10).

Area: collection and planning — 27cec3a2 ports PolymorphicDispatchers (translator.dart:3686-3800, read at the pin against
each body). getPolymorphicDispatchersForModule is `??=` as `get!`. getPolymorphicDispatcher picks the cache as dart does
(`useUncheckedEntry && selector.useMultipleEntryPoints`), and dart's assert of more than one target range becomes a located
Internal (D9). The call target's signature is `[i32, ...selector.signature.inputs]`; shouldInline is
`staticDispatchRanges.length <= 1`. The late `function` is defined in the calling module by name and queued with
inliningCodeGen, as dart's initializer is. generate reads paramLocals[classIdParameterOffset + i] 1-based as `+ i + 1`,
pushes paramLocals[1] as `param_locals[2]` before callDispatchTable, and passes the fallback only when allTargetRanges
outnumber staticDispatchRanges. No difference found. Watch: no differential case reaches it (WasmTarget.compile leaves
polymorphic_specialization off, and _virtualCall, its one caller, is Unported); the structural test is
test/src/dispatch_table.jl. 08cb5604 makes the dynamic table's three guards Internal under D32 (the collector collects no
shape, so build places no entry), each naming its own dart definition; for the count, see R2.

stopgap in disguise: none new.

precedent: dart's PolymorphicDispatchers, PolymorphicDispatcherCallTarget and PolymorphicDispatcherCodeGenerator, by line.

Area: emission and diagnostics — 70207e38 lowers wasm_memory_fill! to one array.fill of the memory's data array, offset 0,
for its length wrapped to i32, the value translated to the element's unpacked type; dart's wasmArrayFill case
(intrinsics.dart:1279, read: `case StaticIntrinsic.wasmArrayFill:`) takes the same four operands. A memory type with no class
info rejects Internal, located. The overlay's body is Base's (`sed -n 204,211p
~/.cache/wasmtarget/julia/base/genericmemory.jl` gives `function fill!(a::Union{Memory{UInt8}, Memory{Int8}}, x::Integer)` …
`memset(p, x isa T ? x : convert(T, x), length(a) % UInt)`), the same conversion written around the intrinsic, and the native
body is Base's memset, never the overlaid method. Its cases are six more equal against native, Dict{Int64,Int64} among them.
5f05f54e records local_null_initialization :unread with both of its causes named (no String marshalling yet;
Types.emitAsCheck at types.dart:527); it is no pass.

stopgap in disguise: none new.

precedent: Base's fill! (genericmemory.jl:204) and dart's wasmArrayFill, by line.

Area: enforcement and prose — item (a), 61ffebbb, D19: the C10 text reads `target, red past 120 s, past 140 s until each
shard's first compile is cut (Dale, 2026-11-01)`, and its trailer `Charter-change: C10 — Dale 2026-11-01: "Raise to 140 s
until the cut"`. That is Dale's choice and nothing more: the same exit as the ledger's D14 band (`until the first-compile cut
lands`) and check.sh's (back to 120 s and four shards), and no other clause text changes (`git show 61ffebbb --stat` gives
dev/CHARTER.md 2 +- and dev/MARCH.md 2 +-). It also gives MARCH 1.L's retry ruling one exit, a measure: SHARDS back to four,
or every row of wt-src-instr.tsv keeping its two measures within 15%. ship.sh:22 points to that measure (`ended by A68S4's
measure`) rather than restating it, one source (D5). (A72E1, low, D17) the second arm fails on rounding, not on noise: `awk
-F'\t' '{a=$2;b=$3;d=(a>b?a-b:b-a)/(a<b?a:b); if(d>0.15)n++} END{print n" of "NR}' .git/wt-src-instr.tsv` gives `10 of 53`,
among them `compiler_options.jl 0.3 0.4` and `target.jl 0.6 0.7`. The log keeps one decimal of G, so one 0.1-G step on a file
under 0.7 G is past 15%, and the arm cannot fire while such files exist, whatever the first compile does. Fix: the arm judges
the measure D14 judges, the slowest shard's summed G across two checks within a band, or each row within 15% or 1 G. Owner:
lead (dev/MARCH.md 1.L). Item (b), e825ebf2: six shards, the seventh's reason gone with the 140-s band; A71E1's measure of
five is not made, a watch for the first-compile cut. Item (c), 4dfdfc88: julia_pin_faults requires the master's `**`<pin>`**
(v<x.y.z>)` and a julia of the pinned minor series at the pin, and its four refusing plants and two passing ones are each
written. Item (d), e55edc4d: the port class is a code line under src/ (src_progress.sh's `code`), its pipeline read without
pipefail for the SIGPIPE it names. Watch: a change to a @quarantine reason or a docstring alone is a code line by this rule,
so a re-cite like 85d54f4a ranks as port work unless its message names a finding (it does). Item (e), c03a8ba9: a .jl unit's
anchor resolves when Julia's parser, reading from the line, gives a definition whose _defines name is the symbol; a blank or
comment line is refused, since the parser would skip it. The sparse checkout holds the three units (`ls
~/.cache/wasmtarget/julia/base ~/.cache/wasmtarget/julia/Compiler/src` gives array.jl, genericmemory.jl, typeinfer.jl). Item
(f), 73b64c1e: ReverseUses runs Run over the program reversed, the count 1..n intact, and by its message breaks
DeterministicNumbering alone (not re-run here). Item (g), 26e75a8c: the per-compile reading matches the budget's own
definition (`git show 26e75a8c^:test/src/dart_tests.jl | sed -n 1143p` gives `# each compile's budget (D17)`), the number
unchanged, so it is a measure fixed, not a budget edited (D14). 4c682f55 pins Node 26 in ci.yml, one source, the floor the
lowest major that was run. Requirements: D5, D9, D10, D17, D19, D20, D32, D40; no lock fired inside its band.

R1 and R2. R1: each new citation is read against its body at its pin. late_lowering.dart:22 and :271 (`sed -n 22p` and `271p`
of pkg/front_end/lib/src/kernel/late_lowering.dart give `Statement createGetterWithInitializer(` and `Statement
createGetterBodyWithoutInitializer(`), the three branches of _late_get's body. 8db1a970's five: wasm_types.dart:748 `external
void operator []=(int index, T value);`, :142 `external int get length;`, runtime_blob.dart:126 `const jsStringPolyfill = {`,
names.dart:25 `final String text;` and table_selector_assigner.dart:142 `void registerGetterCall(Member member, bool
calledOnNull) {`. The runtime clause (src/julia/runtime/, src/patch/, wasm_array.jl): `git diff --stat 6378f3b4..origin/wt2
-- src/julia/runtime src/patch src/julia/wasm_array.jl` gives rtutils.jl 2, wasm_array.jl 20 and genericmemory.jl 9. 70207e38
cited jl_alloc_genericmemory_unchecked (genericmemory.c:30, an allocator) for the fill! it replaces; 85d54f4a, in the range,
re-cites it and its three siblings to the Base methods replaced (`sed -n 78p`, `116p` of base/genericmemory.jl give `function
_unsetindex!(A::MemoryRef{T}) where T` and `function unsafe_copyto!(dest::MemoryRef{T}, src::MemoryRef{T}, n) where {T}`;
:204 is fill!, above), so the re-cite routed to wt3-memory has landed. (A72S2, low, R1) A66S3's second half was dropped
untracked. 8db1a970 says `_wasm_only`'s citation "stays with its owner", and `grep -n A66S3 dev/MARCH.md` gives nothing at
the head. wasm_array.jl:160 still pins by `sdk/lib/_wasm/wasm_types.dart:737 WasmArray`, which `sed -n 737p` gives as
`external factory WasmArray(int length);`: the line now resolves, since 8db1a970's `external` rule admits it, but it does not
port the helper. _wasm_only is a native body that raises behind compilerbarrier, and dart's external has no body at all. Fix:
_wasm_only cites a pinned definition it ports (Julia's own native-raise helper for a codegen-only intrinsic, if one exists at
JULIA_PIN), or the debt list admits an audit-named re-listing by a rule L227 states. Owner: wt3-runtime
(src/julia/wasm_array.jl).

R2: 27cec3a2 fills eleven whole-body Unported definitions (`git diff 6378f3b4..origin/wt2 -- src/translator.jl | grep -cE
'^-.*reject!\(Unported'` gives 11, `^\+` 0). Ten are counted: skeleton.jl:2312's counted() excludes an instance field, and
:3757 is dart's `late final w.BaseFunction function`. So bodies rise by 10 and gaps fall by 10, and 3129 bodies with 1 gap
agrees with 3119 and #70's 11, #71's 12 reading as a mismeasure. Each of the ten is a dispatcher body read above. 08cb5604
changes no count: its three guards precede other statements, so _rejection_only_kind reads each definition as a body before
and after. build's body defines the empty tables, the answer of the only case Julia reaches. (A72S1, medium, R2) the other
two are stubs counted as complete. `sed -n 124,132p src/dynamic_dispatch_table.jl` gives output_target_table and
output_class_id_table as `any(!isnothing, self._table[]) && reject!(Internal(…))` then `return nothing`, none of dart's entry
loop (dynamic_dispatch_table.dart:199-255, read). 08cb5604's message says "They count as rejection-only, never as ported",
but the predicate counts them in the headline: parity.jl:1533 `length(stmts) == 1 || return nothing` and :1535 `st.args[1]
=== :reject!`, so a guard (`&&`/`||`) or a trailing `return nothing` makes a body. An awk scan of each `@parity … function`
whose two-line body is a rejection then `return nothing` finds these two alone. Fix: _rejection_only_kind reads a body that
is one rejection, guarded or not, followed by nothing but `return nothing`, as rejection-only by its kind, with a plant of
each shape; the headline then reads 3127 with 275 Internal. Owner: wt3-parity (src/julia/parity.jl), beside A47E2 on 1.A6.
A64E2 has not landed, so DartAbstract has no count to read.

Resolution: this entry lands alone, prose only, and fixes nothing. A69S1 leaves MARCH 1.K; A71E1 and A71E3 leave 1.L; A71E2
stays on 1.C narrowed to its claim-lock half. A72S1 is open on 1.A6; A72S2 on 1.K; A72E1 on 1.L. By owner: wt3-parity
A72S1 (src/julia/parity.jl), with A71S2, A68S1 and A71E2's claim lock; wt3-runtime A72S2 (src/julia/wasm_array.jl); lead
A72E1 (dev/MARCH.md 1.L); wt3-memory A71S1; wt3-cgstubs2 A71S3 and A70S3.

## 2026-11-01 — audited through 110c2936 (5f05f54e..110c2936: the exception tag's stack trace, a catch's stash defaultable, the retry exit's 1-G floor, the shared julia checkout's sparse list grown and refreshed per check, rejection_text and a typed enclosing-module getter, the host's modules by dart's MiniJsParser, _throwAsCheckError, hash(::String) by Julia's MurmurHash3)

The seventy-third audit, beside the work, covers the 9 commits of 5f05f54e..110c2936 that are not audit entries (3930a67a,
entry 72): bdd5539c, 5bfcb2b7, 5c0f44cf, 9743c109, b2d8d811, d6638a61, 414aa5c0, 686966ac and 110c2936, read here, under
Dale's R1 and R2 as standing sections. Every finding rests on one exact command, quoted. Standing items. src changes in 18
files (`git diff --stat 5f05f54e..origin/wt2 -- src | tail -1` gives `18 files changed, 579 insertions(+), 103
deletions(-)`); no exemption lands (`git diff 5f05f54e..origin/wt2 -- src | grep -cE '^\+.*(Reshaped:|Fields with no Julia
counterpart)'` gives 0). The debt list reads 397, from 398 (`grep -v '^#' dev/quarantine_unpinned.txt | grep -c .`):
d6638a61 deletes `julia/runtime/rtutils.jl host_modules`. Earlier findings: A70E3 is fixed by 5bfcb2b7 (below); A67S4 by the
same commit (`git show 5bfcb2b7 -- src/code_generator.jl` replaces "Julia's exception stack has no reader" with a comment
naming NirHandlers.exception_at), so it leaves 1.D; A72E1 by 5c0f44cf (`awk -F'\t' '{a=$2;b=$3;e=(a>b?a-b:b-a);
d=e/(a<b?a:b); if(d>0.15 && e>1)n++} END{print n+0" of "NR}' .git/wt-src-instr.tsv` gives `8 of 53`, closures.jl 10.9/8.3 and
types.jl 17.6/28.9 among them, real differences, none a rounding step), its "audit 72, open" text left on 1.L by that commit
and removed here; A64R4 by d6638a61 (the regex gone, dart's own parser read; its residue A73S2). Open as they stood: A72S1
(`grep -n 'length(stmts) == 1 || return nothing' src/julia/parity.jl` gives `1534:`); A72S2 (`grep -n 'wasm_types.dart:737'
src/julia/wasm_array.jl` gives `173:`); A71S1 (`grep -n 'isconcretetype(c) && c <: T' src/intrinsics.jl` gives `1342:`);
A71S2 (`grep -n 'julia.h:905' src/julia/parity.jl` gives `656:` and `674:`); A71S3 (`grep -n 'codegen.cpp:2638'
src/code_generator.jl` gives `2026:`); A70S3 (`grep -n 'va_process_argtypes(Core.Compiler.fallback_lattice'
src/julia/nir.jl` gives `573:`); A68S1 (`grep -n 'f === nothing && return nothing' src/julia/parity.jl` gives `1429:` and
`1441:`); A68E3 (`tail -1 .git/wt-corpus.tsv` gives f05b2fa8's `hung 1216` row); A64R1, grown by one (A73S3); A68E2 and
A67E1 at six shards; A69E1, A67S1, A67S3 and A66S1's export half, carried, not re-read; A64E2 not landed (`git log --oneline
--grep=A64E2 5f05f54e..origin/wt2` gives nothing). Findings A73S1, A73S2, A73S3, A73E1 and A73E2.

Area: builder — no change under src/wasm_builder but b2d8d811's Exportable.enclosingModule getter (exports.jl:22), which now
answers `x.enclosing_module::Module`: the field stays AbstractModule, Module's one subtype, declared so because Module is
defined after its parts. The five module_to_builder lookups (dispatch_table.jl:509, static_dispatch_table.jl:43,
translator.jl:843, :1106, :2004) read the getter. bdd5539c's tag type is `[top_type_non_nullable, stack_trace_type]`
(tags.dart:37 with translator.dart:285), the builder checking each throw's and catch's operands against it. 5bfcb2b7's two
stash locals are nullable and each read converts (rethrow to the tag's inputs), so the builder's "Uninitialized local with
non-defaultable type" no longer fires past the CATCH block's end; it is LLVM's choice, every wasm local defaultable, and
visit_block's phi registers' precedent. Both A70E3 cases move :wt_bug to :compiled.

stopgap in disguise: none new.

precedent: dart's tag (tags.dart:37) and visitRethrow (:2966); visit_block's defaultable phi registers.

Area: collection and planning — 414aa5c0 keeps _TypeError._throwAsCheckError in the closed world by a RUNTIME_ENTRY_POINTS row
whose demand is `:typeassert` (`grep -n 'typeassert' src/julia/subset.jl` gives `199: ((:Runtime,),
:_TypeError__throw_as_check_error, (Any, Type), :typeassert),` and `264: :typeassert => (st, src, sptypes, slottypes) ->
_calls_builtin(st, (Core.typeassert,)),`). Core.typeassert is the one form reaching the as checker (code_generator.jl:910 calls
visit_as_expression on it; the NirPi arm, :2031, emits no as check), so the predicate's reading is right. (A73S3, medium,
R1/D1) the mechanism is not dart's. dart keeps the method by `@pragma("wasm:entry-point")` (`git show
898a1e4b:sdk/lib/_internal/wasm/common/errors_patch.dart | sed -n 75,76p` gives the pragma and `static Never
_throwAsCheckError(Object? operand, Type? type) {`), a root TFA keeps, never a list of forms; this is A64R1's bespoke class,
one row more, and RUNTIME_ENTRY_POINTS' docstring (subset.jl:168-187) still lists six demands, not :typeassert. And dart's as
checker calls `translator.throwAsCheckError` (types.dart:1165), KernelNodes' late field (`sed -n 630,634p
pkg/dart2wasm/lib/kernel_nodes.dart` gives `late final Procedure throwAsCheckError = index.getProcedure(` … `"_throwAsCheckError",`);
`grep -rn 'kernel_nodes.dart:630' src` gives nothing, the call being an inline `nir_runtime_member(…,
Runtime._TypeError__throw_as_check_error, at)` at types.jl:787 with a comment naming the field, where :620 stackTraceCurrent
is ported as its own definition (kernel_nodes.jl:62). Fix: KernelNodes.throw_as_check_error anchored at kernel_nodes.dart:630,
read by the as checker; the root carried by the runtime method itself as dart's pragma is (A64R1's fix), or, until then, the
docstring names :typeassert. Owner: wt3-runtime (src/types.jl, src/kernel_nodes.jl, src/julia/subset.jl).

stopgap in disguise: A73S3's demand predicate, A64R1's class.

precedent: dart's AsCheckerCodeGenerator.generate (types.dart:1094-1175, read): the failure path passes `b.locals[0]` and the
TypeLiteralConstant at nonNullableTypeType, then unreachable, end, the operand converted, return; the port matches, its
check_arguments arm an Internal (a Julia class has no type arguments), and its minify arm absent with its reason.

Area: emission and diagnostics — bdd5539c: Error._throw takes the stack trace (errors_patch.jl:14), the errorThrow intrinsic
pushes both values (intrinsics.dart:3449), _throwWithCurrentStackTrace passes StackTrace_current(), each catch stashes both
(visitTryCatch :956-960), and Translator.stackTraceInfo rejects Unported at JavaScriptStack (js_helper.dart:830) outside
standalone mode. b2d8d811's rejection_text (reject.jl:210) is `string(x)` behind @nospecialize and @nospecializeinfer, its
precedent jl_static_show (`sed -n 1496p ~/.cache/wasmtarget/julia/src/rtutils.c` gives `JL_DLLEXPORT size_t
jl_static_show(JL_STREAM *out, jl_value_t *v) JL_NOTSAFEPOINT`), the text unchanged. (A73E1, low, D5) its commit leaves
the other path beside it: `grep -rnE '\$\(?mi\)?\b' src | grep -E 'reject!|Internal\(|Unquarantined\(' | grep -v
rejection_text` gives `src/julia/nir.jl:727: m isa Method || reject!(Unquarantined("src/julia/nir.jl: $mi instantiates no
method"), "$mi")`, nir_method_nargs, eleven lines above nir_body_of's converted sites. Fix: that site reads rejection_text,
and a rejection's text of a MethodInstance has the one spelling. Owner: wt3-latency (src/julia/nir.jl).

stopgap in disguise: none new.

precedent: dart's errorThrow intrinsic and visitTryCatch, by line; jl_static_show for the error path's printing.

Area: enforcement and prose — 5c0f44cf: the retry exit's second arm takes "within 15% or within 1 G", read above against the
log. 9743c109 makes dev/fetch_julia.sh's sparse list the union of what it holds and what this tree names (`sort -u` over
both); 110c2936 runs this tree's script at the head of dev/check.sh. (A73E2, low, D12) the shared checkout is still
rewritten by any tree whose script predates 9743c109: 110c2936's own message records src/support stripped at 17:14Z, after
9743c109 (17:01Z in .git/wt-landings.tsv), and the check restores it only at its start, so a strip during a check still fails
it ("the julia pin has no …", L213). The source is a sparse list written by whichever tree last ran. Fix: the list a function
of the pin, not of a tree (the pinned commit's src/support, base and Compiler/src units checked out whole, or a checkout per
JULIA_FILES digest), so no tree's run can remove another's unit. Owner: lead (dev/fetch_julia.sh, dev/check.sh).
Requirements: D5, D9, D10, D12, D17, D32; no lock fired inside its band.

R1 and R2. R1: each new citation is read against its body at its pin. 686966ac: `sed -n 47p` and `220p` of
src/support/MurmurHash3.c give `FORCE_INLINE uint64_t fmix64 ( uint64_t k )` and `void MurmurHash3_x64_128 ( const void * key,
const size_t len,`; `sed -n 68p src/support/hashing.c` gives `uint64_t memhash_seed(const char *buf, size_t n, uint32_t
seed)`, which returns `out[1]`. Line by line: fmix64's three xor-shifts and two multiplies by 0xff51afd7ed558ccd and
0xc4ceb9fe1a85ec53 match; the body's k1/k2 rotations 31/33, h1/h2 rotations 27/31, `*5+0x52dce729` and `*5+0x38495ab5` match;
murmur3_block reads bytes j=0..7 into bit 8j, jl_load_unaligned_i64 little-endian; the tail's k2 takes tail[8..rest-1] at
8(j-8) and k1 tail[0..min(rest,8)-1] at 8j, the C switch's shifts (case 15 `tail[14] << 48` down to case 9 `tail[8] << 0`,
case 8 `tail[7] << 56` down to case 1), each mixed only where rest > 8 and rest > 0 as the fall-through mixes them; the
finalization `h1 ^= len; h2 ^= len`, two adds, fmix64 twice, two adds, `out[1]` = h2 match. No difference found in the port.
(A73S1, low, R1) the overlay's citation and effects. src/patch/hashing.jl's @quarantine cites hashing.c:68, the C its body
calls, where 85d54f4a's rule (A69S1) cites each overlay at the Base method it replaces (the three of
src/patch/genericmemory.jl cite `julia/base/genericmemory.jl:116`, `:78`, `:204`); `grep -c '"julia/base/hashing"'
src/julia/parity.jl` gives 0. And Base's method is `@assume_effects :total function hash(s::String, h::UInt)` (`git -C
~/.cache/wasmtarget/julia show HEAD:base/hashing.jl | sed -n 198p`), while `grep -c assume_effects src/patch/hashing.jl` gives
0: the overlay drops the effects Base asserts, so a hash Julia folds natively is not folded in the overlay's inference. Fix:
the overlay cites julia/base/hashing.jl:198 (JULIA_FILES gains julia/base/hashing) and carries Base's @assume_effects :total.
Owner: wt3-memory (src/patch/hashing.jl, src/julia/parity.jl). d6638a61: the seventeen js_parser.jl anchors each resolve to
their definition at the dart pin (`sed -n Np pkg/js_ast/lib/src/builder.dart` for 394, 417, 462, 481, 489, 528, 541, 550,
580, 620, 725, 730, 762, 784, 888, 899 and 929 gives `enum _Category {`, `static const _asciiTable`, `class MiniJsParser {`,
`_singleCharCategory`, `BINARY_PRECEDENCE`, `UNARY_OPERATORS`, `OPERATORS_THAT_LOOK_LIKE_IDENTIFIERS`, `_category`,
`getString`, `getToken`, `_expectCategory`, `_acceptCategory`, `error`, `parsePrimary`, `parseObjectInitializer`,
`parseMethodDefinitionOrProperty` and `parseMember`). Read against dart's bodies: the 127-entry ASCII table matches row for
row; getString's escapes match, dart's `\t` as 8 kept; getToken's comment skips, hex literal, `/` token, the do-while with
its `!`/`~`/`/` rule, and the operator classification match, 0-based positions over 1-based indexing checked at each read;
the object initializer and property loops match, a hole's name taken as parseHash takes it (the positional/named mix check
dropped, the template having one hole). (A73S2, low, R1) two readings are not dart's. js_parse_assignment! cites
`builder.dart:929 MiniJsParser.parseMember` (js_parser.jl:299), a second definition at parseMember's line, while it stands
in for parseAssignment (`grep -n 'Expression parseAssignment' pkg/js_ast/lib/src/builder.dart` gives `1076:`) and its chain
down to parseMember; and host_modules finds the object by `findfirst("const baseImports = ", text)` (rtutils.jl:87), a
fixed-text search where the commit's subject says "never a pattern over the template". Fix: js_parse_assignment! anchored at
:1076 with what it drops named; the declaration read as dart's parser reads a `const` statement (parseVariableDeclarationList),
or the search's reason in host_modules' quarantine. Owner: wt3-runtime (src/julia/js_parser.jl, src/julia/runtime/rtutils.jl).
414aa5c0: errors_patch.dart:76 is the method (above), and jl_type_error_rt (`sed -n 113p src/rtutils.c` of the julia pin) is
the TypeError the body builds; its mechanism is A73S3.

R2: the headline does not move in the range. `git diff 5f05f54e..origin/wt2 -- src | grep -E '^[-+].*reject!\(Unported'`
gives four lines: boxJsException moved (one out, one in, bdd5539c's catch_tag), JavaScriptStack added inside
Translator.stackTraceInfo's Late thunk (a gap within a body, outside the standalone answer), and errors_patch.dart:76's
removed from AsCheckerCodeGenerator.generate. That generate was already a body (its rejection the last of several
statements), so its fill completes a partial body and leaves bodies at 3129, 273 Internal and 1 Unported. The runtime clause
gains one @parity definition (`git diff 5f05f54e..origin/wt2 -- src | grep -E '^\+@parity'` gives errors_patch.dart:40's
re-signed Error._throw, :76 _throwAsCheckError and exports.dart:11's getter re-typed), the runtime count up by one, honestly a
body: `Error__throw(TypeError(:typeassert, "", type, operand), StackTrace_current())`. A64E2 has not landed, so the
3086-or-below headline and DartAbstract's separate count have nothing to read, and A72S1's guarded-rejection rule is not
applied (parity.jl:1534 unchanged).

Resolution: this entry lands alone, prose only, and fixes nothing. A67S4 leaves MARCH 1.D (A70E3 had left it with 5bfcb2b7);
A72E1's stale text leaves 1.L. A73S1 is open on 1.K; A73S2 on 1.F; A73S3 on 1.C; A73E1 and A73E2 on 1.L. By owner:
wt3-runtime A73S3 (src/types.jl, src/kernel_nodes.jl, src/julia/subset.jl) and A73S2 (src/julia/js_parser.jl,
src/julia/runtime/rtutils.jl), with A72S2; wt3-memory A73S1 (src/patch/hashing.jl), with A71S1; wt3-latency A73E1
(src/julia/nir.jl); lead A73E2 (dev/fetch_julia.sh, dev/check.sh); wt3-parity A72S1, A71S2, A68S1 and A71E2's claim lock;
wt3-cgstubs2 A71S3 and A70S3.

## 2026-11-01 — audited through a44c25d6 (110c2936..a44c25d6: nfields' classes through getConcreteClassIdRange, _meet_constant! anchored at dart's visit-once walk, a String's hash at 7 and 8 bytes, the julia checkout's sparse list a function of the pin, every citation of a reason resolved, ported-with-a-body read from Julia's inference with DartThrow and DartAbstract apart, the overlay check cited at OverlayMethodTable, the debt-body lock, the D11 lock)

The seventy-fourth audit, beside the work, covers the 9 commits of 110c2936..a44c25d6 that are not audit entries (88cbefa7,
entry 73): f459aba1, d88b3e71, 4fd0e871, 36720fe3, f1a65f36, 334b7ac6, 858c559a, 9791ed9f and a44c25d6, read here, under
Dale's R1 and R2 as standing sections. Every finding rests on one exact command, quoted. Standing items. src changes in 4
files (`git diff --stat 110c2936..origin/wt2 -- src | tail -1` gives `4 files changed, 179 insertions(+), 56
deletions(-)`); no exemption lands (`git diff 110c2936..origin/wt2 -- src | grep -cE '^\+.*(Reshaped:|Fields with no Julia
counterpart)'` gives 0). The debt list reads 393, from 397 (`grep -v '^#' dev/quarantine_unpinned.txt | grep -c .`):
4fd0e871 deletes `_meet_constant!`, 334b7ac6 `REJECTION_ONLY`, `_rejection_only_kind` (both gone) and `_parity_entry`
(pinned). Earlier findings: A71S1 is fixed by f459aba1 (`grep -c 'isconcretetype(c) && c <: T' src/intrinsics.jl` gives 0;
the one scan left is getConcreteClassIdRange's own, class_info.jl:565), its text left on 1.D by that commit and removed
here; A68S1 by f1a65f36 (each anchor, path citation and precedent now returns its fault or sets `cited`, parity.jl's
_reason_unpinned, with plants); A73E2 by 36720fe3 (the list `src/`, `base/`, `Compiler/src/` whole, so no tree's list
removes another's unit; a tree whose script predates 9743c109 shrinks it only until its rebase), removed from 1.L here;
A72S1 and A64E2 by 334b7ac6 (`grep -c 'length(stmts) == 1 || return nothing' src/julia/parity.jl` gives 0), A47E2 with them
(the numerator now leaves out every definition inference finds never returns, a dart throw counted as A47E2 asked),
removed from 1.A6 here; A71S2 by 858c559a (`sed -n 37p Compiler/src/methodtable.jl` of the julia pin gives `struct
OverlayMethodTable <: MethodTableView`, and `sed -n 935p Compiler/src/abstractinterpretation.jl` gives `function
concrete_eval_eligible(interp::AbstractInterpreter,`, whose body runs the native method under `is_consistent_overlay`), its
residue A74S4; A69E2 by a44c25d6, its residue A74E1. Open as they stood: A72S2 (`grep -n 'wasm_types.dart:737'
src/julia/wasm_array.jl` gives `160:` and `173:`); A71S3 (`grep -n 'codegen.cpp:2638' src/code_generator.jl` gives
`2026:`); A70S3 (`grep -n 'va_process_argtypes(Core.Compiler.fallback_lattice' src/julia/nir.jl` gives `573:`); A73S1
(`grep -n 'hashing.c:68' src/patch/hashing.jl` gives `10:`); A73S2 (`grep -n 'const baseImports = '
src/julia/runtime/rtutils.jl` gives `86:`); A73S3 (`grep -n ':typeassert),' src/julia/subset.jl` gives `199:`); A73E1
(`grep -n 'instantiates no' src/julia/nir.jl` gives `727:`); A68E3 (`tail -1 .git/wt-corpus.tsv` gives f05b2fa8's `hung
1216` row); A71E2, A69E1, A68E2, A67E1, A67S1 and A67S3, carried, not re-read. Findings A74S1, A74S2, A74S3, A74S4 and
A74E1.

Area: builder — no change under src/wasm_builder.

Area: collection and planning — f459aba1: the nfields arm reads ids through get_concrete_class_id_range and each id's
class from translator.classes, the scan deleted (class_info.dart:831 ported, the cases varargs 19 and records 48 kept).
4fd0e871: _meet_constant!'s @quarantine now cites `pkg/dart2wasm/lib/record_class_generator.dart:773
_RecordVisitor.defaultConstantReference` (`sed -n 772,776p` gives `void defaultConstantReference(Constant node) {` / `if
(constantCache.add(node)) {` / `node.visitChildren(this);`), the visit-once rule the body follows, its === key for an
immutable value the stated difference; its body is unchanged. d88b3e71 runs the hash at 7 bytes, exactly 8 and a 6-byte
non-ASCII String against native, the lengths 686966ac's ruling named.

stopgap in disguise: none new.

precedent: dart's getConcreteClassIdRange and _RecordVisitor, by line.

Area: emission and diagnostics — no change under the emitting code in the range.

Area: enforcement and prose — 36720fe3 and 858c559a read above. 9791ed9f (debt_bodies_changed, L227): each src file the
change touches is read at the merge base and at HEAD, every @quarantine keyed by the package's own _defines, _identity and
_quarantine_key (one keying, D5), compared as Julia's parser reads it with line numbers dropped; a body that differs while
its line stays is refused. D6/D20: a diff scan, a stopgap whose exit, 1.K's required source, its text names; its allowlist
is exact (PIN_TABLES, three keys, `pin_rows_added` taking only rows added in order) and its exit the same. By reading, its
plants fire when stubbed: debt_bodies_changed returning nothing fails "a debt-listed body rewritten with its line kept
passes", pin_rows_added returning true fails "a row removed from a pin table passes". f1a65f36 edited two debt-listed
bodies (REASON_ANCHOR_RX, _reason_unpinned) before the lock landed, the lead's recorded exception (its message), both
still listed (`grep -n 'julia/parity.jl _reason_unpinned' dev/quarantine_unpinned.txt` gives `294:`). a44c25d6
(invariants_dropped, L227): each MC*.cfg's INVARIANT and PROPERTY names at the merge base and at HEAD, a dropped name or a
removed Broken cfg refused without an `Invariant-dropped:` line naming a successor its cfg lists or a moot reason; its
plants fire when stubbed (an empty result fails "a dropped invariant with no line passes"). (A74E1, medium, D11/D6) the
lock reads names, not what they claim: `grep -c '\.tla' test/parity_ratchet.jl` gives 0, so `Safe == TRUE` written in the
model, or a cfg's CONSTANTS shrunk to a trivial instance, drops nothing it reads; and a correct cfg removed is refused
whatever lines name its claims (`endswith(f, "Broken.cfg") || (isempty(before) || push!(out, …); continue)` never reads
`lines`), where its message says such a removal "names each of its claims the same way", with no plant for either. Fix:
the claim read at its source, each named operator's definition in the .tla and the cfg's CONSTANTS compared at both
revisions, a change refused unless named; a removed correct cfg passes when each claim is named, with plants. Owner:
wt3-parity (test/parity_ratchet.jl). Requirements: D5, D6, D8, D9, D11, D20; no lock fired inside its band.

R1 and R2. R1: each new citation is read against its body at its pin. 334b7ac6's precedent: `sed -n 1115p
Compiler/src/typeinfer.jl` of the julia pin gives `function typeinf_frame(interp::AbstractInterpreter, mi::MethodInstance,
run_optimizer::Bool)`, the overload method_kind calls with the method's own MethodMatch, unoptimized; the inference half
rests on it. The guard rule (A72S1) is stated in the comment and L208, with plants (guard_only a rejection; checks, effect
and returned bodies). (A74S1, medium, R1/D5) the other half is bespoke: dart_member (parity.jl:1603) tells a throwing or
abstract dart member by a bracket walk to the first `;`, `=>` or `{` and a regex for `throw`, `external` and `get`, with no
precedent, beside dev/skeleton.jl, the one reader of dart's declarations (its Decl's kinds and modifiers). Its rules misread
an enum value as abstract: for `V128Instruction.i8x16Splat` (`sed -n 4442p pkg/wasm_builder/lib/src/ir/instruction.dart`
gives `  i8x16Splat(0x0F, 'i8x16.splat'),`) the head runs to :4524's `;`, holds `(`, no `=` and no constructor's name, so
DartAbstract; harmless today only because those ports are consts with no methods (`e.ported && !isempty(e.methods)`,
parity.jl:1638). Fix: abstract and throwing read from the skeleton's Decl (its statement end already parsed), or from
dart's analyzer (ExecutableElement.isAbstract) with that as precedent. (A74S2, medium, D9/D8/R2) rejection_only_kinds
defaults to a body past a gap: `grep -n 'return :body' src/julia/parity.jl` gives `1546:` (no MethodMatch), `1548:` (no
frame) and `1583:` (the rule's own exit), the first two a definition inference cannot read counted ported; `sed -n 1589,1590p` matches the closed sum Rejection with a
wildcard, `t <: Rejection ? :check : :Internal`, so a rejection typed `Union{Unported,Internal}` reads as a check's and
the method as a body, and an argument not an SSA value reads Internal; and the guard rule at :1577 takes a call whose value
is stored to a local no return reads as a guard, so `r = push!(v, 1); return nothing` after a guard counts as rejection-only
with no plant; L208's text says `typeinf_code` (`grep -c typeinf_code src/julia/parity.jl` gives 0). Fix: an unreadable
method refused, located; the kind matched @exhaustive over Rejection's arms, a Union refused; a stored value followed to
its readers as an SSA value is, with plants; L208 names typeinf_frame. Owner of both: wt3-parity (src/julia/parity.jl,
test/parity_ratchet.jl). (A74S3, low, R1) _parity_entry's map to `pkg/analyzer/lib/src/error/override_verifier.dart:68
OverrideVerifier.visitMethodDeclaration` (resolving, `sed -n 68p` gives `  void visitMethodDeclaration(MethodDeclaration
node) {`) is not one to one: hasOverride to parse_anchor, _isOverride to _anchor_fault and _form_fault, the report to
`refuse` are mapped, but dart's switch on the element's kind (:71, three diagnostics), _isOverride's null class (:123) and
nameless member (:131) returns and `super.visitMethodDeclaration` (:86) are neither mapped nor said to have no
counterpart, nor on WT's side the string-literal check, the @unported expansion (`_unported`) and the resolution only for
WasmTarget's own modules (`own ? _pin_sdk() : nothing`). Fix: each named in the comment's map. Owner: wt3-parity. (A74S4,
low, R1) A71S2's residue: `grep -n 'julia.h:905' src/julia/parity.jl` gives `675:`, _methods_of_file citing the same
`} jl_methtable_t;` line for "Julia's one table of every method". Fix: cited at the code that keeps a method's file.
Owner: wt3-parity. f1a65f36's re-pins resolve: rtutils.jl's `genericmemory.c:55` and
`ffi_native_transformer.dart:160 WasmFfiNativeTransformer.visitProcedure`, both checked by the load (L213).

R2: the first progress line after 334b7ac6, from its landing's check (`grep -oE 'src: [0-9]+ of 3404 .*' r25.log` in the
lead's ship logs, 17:29Z, before the 17:34Z landing): `src: 3083 of 3404 anchored dart definitions ported with a body (…),
32 of them a dart body that itself throws, ported as its throw; … not counted ported: 274 that never return, Julia's
inference finds, rejecting Internal (…), 5 gap(s) still to fill (4 rejecting Unported or Unquarantined, 1 an @unported
stub) and 42 in place of a dart abstract declaration (no body to port); 3083 + 274 + 5 + 42 = 3404 of 3404`, as the lead
stated; a44c25d6's ship prints the same head (`tasks/benmcq0k2.output`). The registry's kinds are not printed, so the
samples come from dart_member's rules transcribed (a scratch script over every @parity anchor, 42 abstract and 32 throwing
among those whose body rejects Internal, matching the line), each read at the dart pin. DartThrow: code_generator.dart:1356
visitForInStatement (`throw "ForInStatement should have been desugared: $node";`), constants.dart:862 visitIntConstant
(`throw StateError('Int constants should be handled at instantiation');`), type.dart:49 ValueType.byteSize (`int get
byteSize => throw "Size of non-primitive type $runtimeType";`), type.dart:412 CommonHeapType.topType (`=> throw "No top
type of internal common supertype"`), constants.dart:1667 DummyValueConstant.getType (`throw UnsupportedError(…)`): each
a throw first. DartAbstract: globals.dart:306 DartGlobalDefinition.type (`w.ValueType get type;`), kernel_nodes.dart:12
KernelNodes.index (`LibraryIndex get index;` in the mixin), modules.dart:220 ModuleStrategy.addEntryPoints (`void
addEntryPoints();`), type.dart:14 StorageType.isSubtypeOf (`bool isSubtypeOf(StorageType other);`), instructions.dart:43
Label.targetTypes (`List<ir.ValueType> get targetTypes;`): each abstract. The 42 stand beside the headline, never in it;
the one @unported stub, AstCodeGenerator._virtualCall, is counted a gap, so the line totals its anchored count.

Resolution: this entry lands alone, prose only, and fixes nothing. A71S1 leaves 1.D, A73E2 1.L, A47E2 1.A6. A74S1 and
A74S2 are open on 1.A6; A74S3 and A74S4 on 1.K; A74E1 on 1.L. By owner: wt3-parity A74S1, A74S2, A74S3, A74S4
(src/julia/parity.jl) and A74E1 (test/parity_ratchet.jl), with A71E2's claim lock; wt3-runtime A73S3 and A73S2, with A72S2;
wt3-memory A73S1; wt3-latency A73E1; wt3-cgstubs2 A71S3 and A70S3.

## 2026-11-01 — audited through e84214d1 (a44c25d6..e84214d1: _wasm_only with no dart counterpart, a varargs tuple and a tuple literal of open elements by a product of classes bounded by max_union_splitting, the String hash overlay at base/hashing.jl:198, the rejection count refusing what it cannot read, generateJsMethods and the JS printToConsole, the D11 lock reading definitions and constants)

The seventy-fifth audit, beside the work, covers the 7 commits of a44c25d6..e84214d1 that are not audit entries (0cf3bd32,
entry 74): 72d0d42d, bee9ca3c, 18acb938, 11c9e8a2, d5db52fa, 92e6b448 and e84214d1, read here, under Dale's R1 and R2 as
standing sections. Every finding rests on one exact command, quoted. Standing items. src changes in 13 files (`git diff
--stat a44c25d6..origin/wt2 -- src | tail -1` gives `13 files changed, 332 insertions(+), 73 deletions(-)`); no exemption
lands (`git diff a44c25d6..origin/wt2 -- src | grep -cE '^\+.*(Reshaped:|Fields with no Julia counterpart)'` gives 0).
The debt list reads 389, from 393 (`grep -v '^#' dev/quarantine_unpinned.txt | grep -c .`): bee9ca3c pins
closed_world_classes (`sed -n 1534p Compiler/src/typeinfer.jl` gives `function typeinf_ext_toplevel(methods::Vector{Any},
worlds::Vector{UInt}, trim_mode::UInt8)`) and Dart2Wasm (`sed -n 298p pkg/dart2wasm/lib/dart2wasm.dart` gives `Future<int>
main(List<String> args) async {`), 18acb938 _TRANSPARENT_MACROS (base/expr.jl :277 `macro inline(x)`, :354 `macro
noinline(x)`, :764 `macro assume_effects(args...)`), d5db52fa RUNTIME_FILES. Earlier findings: A72S2 is fixed by 72d0d42d
(`sed -n 2065p src/builtins.c` of the julia pin gives `JL_CALLABLE(jl_f_compilerbarrier)`, the builtin _wasm_only rests
on, its want of a dart counterpart stated; wasm_array.jl:175 keeps `wasm_types.dart:737` for wasm_array_new, whose dart
counterpart that factory is); A73S1 by 18acb938 (`sed -n 198p base/hashing.jl` gives `@assume_effects :total function
hash(s::String, h::UInt)`, the overlay carrying the same claim; `grep -c 'hashing.c:68' src/patch/hashing.jl` gives 0);
A70S3 by bee9ca3c in its call half (tuple_classes reads each element as compute_va_type does, `sed -n 8102p
src/codegen.cpp` giving `static jl_datatype_t *compute_va_type(jl_value_t *sig, size_t nreq)`), its entry half still
inference's (`grep -n 'va_process_argtypes(Core.Compiler.fallback_lattice' src/julia/nir.jl` gives `573:`, rejecting at
_setupLocalParameters, which the commit says no case reaches), carried in A75S1; A74S2 by 11c9e8a2, its residue A75E3;
A74E1 by 92e6b448, its residue A75E2. Open as they stood: A71S3 (`grep -n 'codegen.cpp:2638' src/code_generator.jl` gives
`2040:`); A73S2 (`grep -n 'const baseImports = ' src/julia/runtime/rtutils.jl` gives `113:`); A73S3 (`grep -n
':typeassert),' src/julia/subset.jl` gives `199:`); A73E1 (`grep -n 'instantiates no' src/julia/nir.jl` gives `727:`);
A74S1 (`grep -n 'local dart_member' src/julia/parity.jl` gives `1628:`); A74S3 (`grep -n 'override_verifier.dart:68'
src/julia/parity.jl` gives `1700:`); A74S4 (`grep -n 'julia.h:905' src/julia/parity.jl` gives `677:`); A68E3 (`tail -1
.git/wt-corpus.tsv` gives f05b2fa8's `hung 1216` row); A71E2, A69E1, A68E2, A68S4, A72E1, A67E1, A67S1 and A67S3, carried,
not re-read. Findings A75S1 to A75S6 and A75E1 to A75E3.

Area: builder — no change under src/wasm_builder.

Area: collection and planning — bee9ca3c: closed_world_classes collects each open varargs tuple and, after the walk, meets
every class tuple_classes gives it; e84214d1 does the same for a Core.tuple literal and, past the bound, brings none
(`past_bound = :none`), so a statement no code reaches no longer refuses the compile. (A75S2, low, D5) tuple_classes has two
`below` sources: the walk passes `p -> DataType[c for c in out if isconcretetype(c) && c <: p]` (classes.jl, the loop over
open_tuples), read while `out` grows, so a later open tuple sees the classes an earlier one added and the result depends on
the order of the loop; the code generator passes getConcreteClassIdRange over the final numbering (intrinsics.jl, the
open_tuple arm's `below`), which also holds every tuple class the loop added. Where an open element's type is above such a
class (`Tuple`, `Tuple{Any,…}`, `Any`), the generator's product holds a class the walk never met, so the leaf reads no
class info and rejects as Internal, or the two counts fall on opposite sides of the bound; the docstring's "the one source"
holds only for the function, not its input. No case covers it. Fix: one class list for both, the walk's open tuples
expanded to a fixpoint over the met classes and the code generator reading that same list (or the numbering alone), with
a case that nests an open tuple in one. Owner: wt3-memory (src/julia/classes.jl, src/intrinsics.jl).

stopgap in disguise: the bound, A75S1.

precedent: compute_va_type and jl_f_tuple by line; the bound, A75S1.

Area: emission and diagnostics — bee9ca3c's open_tuple arm (intrinsics.jl, generate_static_intrinsic Val(:open_tuple))
switches on each open element's class id, nested element by element, through class_id_search (dart's classIdSearch,
code_generator.dart:5709), null its own arm and a miss unreachable (A68S3); each leaf allocates the concrete tuple class, so
a value built here and one built at a concrete site share one class, Julia's invariant that each value's class is its
concrete type. e84214d1 routes visitRecordLiteral's open case through the same arm. d5db52fa: an inline JS site is a
foreign call to `"dart2wasm"`, its symbol the JS code (rtutils.jl JS_INTEROP_LIBRARY, nir_js_code); getFunction imports it
under _InteropHelperMemberNamer's name (`sed -n 117p pkg/dart2wasm/lib/namer.dart` gives `  ImportName?
getImportName(Member member) {`); generateJsMethods (`sed -n 60p pkg/dart2wasm/lib/js/runtime_generator.dart` gives `
String generateJsMethods(Iterable<Procedure> translatedProcedures) {`) writes `<name>: <code>,` in natural order;
printToConsole is ported over it (`sed -n 8p sdk/lib/_internal/wasm/js_common/print_patch.dart` gives `void
printToConsole(String line) => JS<void>(`); JsCodeData is cited in the comments (functions.jl:204, rtutils.jl:76). (A75S3,
medium, D2) the "héllo" case is a self-golden: it compares node's output with the literal `"héllo\n1 7"` (`grep -n 'out ==
"héllo' test/src/js_string.jl`), never with Julia's println of the same line, and the host it runs under binds every
`dart2wasm` import to the test's own `s => console.log(s)` (`Object.fromEntries(imps.map(i => [i.name, s =>
console.log(s)]))`), so neither the JS text generate_js_methods writes nor the JS runtime's printToConsole ever runs; the
text is checked only as a string. Fix: the module run under the JS runtime the runtime generator writes, its methods from
generate_js_methods, and the printed bytes compared with `sprint(println, "héllo")`. Owner: wt3-runtime
(test/src/js_string.jl). (A75S4, medium, D9/D10) JS code is admitted from any body and never read:
`nir_foreign_import` admits the library whatever method holds the call (`grep -n 'lib == JS_INTEROP_LIBRARY'
src/julia/runtime/rtutils.jl` gives `181:`), and generate_js_methods writes the symbol verbatim, so a program's
`ccall(("s => (", "dart2wasm"), Nothing, ())` puts invalid JS into the runtime, refused only by the JS engine at load; dart's
JS<T> lives in dart:_js_helper, an internal library a user program cannot import, and its specializer reads the template.
Fix: the interop module admitted only in a Runtime-module method (dart's internal-library rule), any other a located
rejection, and the code parsed where it is read, by the ported MiniJsParser (src/julia/js_parser.jl), a parse failure
located. Owner: wt3-runtime (src/julia/runtime/rtutils.jl). (A75S5, low, R1/D4) one name per enclosing method:
get_import_name keys `interop_member_names` by the enclosing MethodInstance, and nir_js_code refuses a body holding two
different codes as Internal, where dart's specializer makes one procedure per JS<T> site; Julia inlining two JS patches into
one caller (printToConsole and the next) is a valid program that this refuses as WasmTarget's own defect. And the Julia-side
precedent for code carried as a foreign call's argument, Base.llvmcall (its IR text an argument), is not cited (`grep -rn
llvmcall src | grep -c .` gives 0). Fix: keyed by the site (enclosing method and statement), with a two-site case, and
llvmcall cited beside JsCodeData. Owner: wt3-runtime (src/namer.jl, src/julia/runtime/rtutils.jl).

Area: enforcement and prose — 11c9e8a2: a method with no match of its own signature or no frame now throws
ConstructionViolation, located (parity.jl :1557, :1559); the kinds of Rejection sit in one table checked against
`Base.uniontypes(Rejection)`; a rejection's type read by argextype; the guard rule follows a stored value to its readers,
with plants `stored`, `hidden` and `loose`. (A75E3, low, D17) L208's text says the no-match and no-frame refusals have
plants ("a method with no match or no inference frame a located refusal"), but none exists (`grep -c 'own signature matches
no method\|no frame for its signature' test/parity_ratchet.jl` gives 0). Fix: a plant whose method's signature matches no
method (a method deleted after its entry is taken), or the text trimmed. Owner: wt3-parity (test/parity_ratchet.jl).
18acb938: (A75S6, low, D6) `@assume_effects` joins _TRANSPARENT_MACROS (`grep -n 'Symbol("@assume_effects")'
src/julia/parity.jl` gives `177:`), so any src definition may carry an effects claim, which Julia's inference trusts to fold
or delete a call (a `:nothrow` on a body that rejects deletes the rejection), as a macro that "wraps a definition without
changing what it defines"; the one use (hashing.jl:12) repeats Base's own claim. Fix: admitted only where the definition it
overlays carries the same claim, read from that Base method, else refused. Owner: wt3-parity (src/julia/parity.jl).
92e6b448: invariants_dropped now compares each claim's definition in every .tla (comments and whitespace aside), a cfg's
CONSTANTS and a removed correct cfg's claims, with plants that fire when stubbed. (A75E2, medium, D11) it reads only the
claim's own text: `defs_named` holds the claims and the `<-` constants' definitions (`sed -n 2617,2619p
test/parity_ratchet.jl`), so an operator a claim names (Soundness's helpers) rewritten to TRUE, or the cfg's SPECIFICATION
operator, Init or Next rewritten (`Next == UNCHANGED vars` makes every invariant hold), passes unnamed. Fix: the definitions
read transitively from each claim and from the SPECIFICATION (or INIT/NEXT) operator, with plants for a helper and for
Next. Owner: wt3-parity (test/parity_ratchet.jl). (A75E1, medium, D13/D23) e84214d1 landed after the lead asked to hold it:
the lane shipped 7f975e4d at 18:44:45Z and the wt3-codegen autoship loop (pid 56055, running since 2026-10-29) at 18:44:58Z
and 18:50:46Z, all red (`grep -n 'tuple literal of open operands' .git/wt-ship-failures.tsv` gives rows 254, 255 and 256, the
third ad4c35c0, and 258, wt3-constants' conflict naming the new head),
its log ending there (`tail -1 .wtd/autoship.log` in that worktree: `autoship: 7f975e4d went red; not shipped again until HEAD
moves`, 18:53:23Z); the lane then amended to e9e81a83 and its own ship.sh rebased it onto 92e6b448 (`git reflog` there:
`rebase (start): checkout origin/wt2`, `rebase (pick)`, e84214d1) and landed it at 18:55:21Z (`tail -1
.git/wt-landings.tsv`: `e84214d1 729`). Nothing in dev/ship.sh or dev/autoship.sh honours a hold, and a lane's committed HEAD
lands by itself once it settles. Eight autoship loops are alive since 2026-10-29 (`ps aux | grep -c '[b]ash
dev/autoship.sh'` gives 8), among them wt3-constants', which conflicts on test/src/constants.jl at each of the six landings
since 18:04Z (rows 246 to 258 of the failures file). Fix: a hold a ship refuses (a file per lane under the common dir that
dev/ship.sh reads, set by the lead), and the stale loops stopped. Owner: lead (dev/ship.sh, dev/autoship.sh).
Requirements: D5, D6, D8, D9, D11, D20; no lock fired inside its band.

R1 and R2. R1: each new citation is read at its pin (above). The lead's and the monitor's holding is judged here. (A75S1,
medium, R1/D3/D32) the bound in tuple_classes is a wrong pin: `sed -n 199,201p Compiler/src/types.jl` gives `struct
InferenceParams` / `    max_methods::Int` / `    max_union_splitting::Int`, a bound read at a call
(`sed -n 352,353p Compiler/src/abstractinterpretation.jl` gives `is_union_split_eligible(𝕃::AbstractLattice,
argtypes::Vector{Any}, max_union_splitting::Int) =` / `    1 < unionsplitcost(𝕃, argtypes) <= max_union_splitting`), which
counts the members of a Union in the argument types and never the concrete types below an abstract one: by Julia's measure
Tuple{Type{Int64}, Any} costs 1, and jl_f_tuple builds its tuple with no enumeration at all, its type made from the values
(`sed -n 946,950p src/builtins.c` gives `JL_CALLABLE(jl_f_tuple)` … `return arg_tuple(args[0], &args[1], nargs);`). So the
product of classes has no Julia precedent, and its bound is a number taken from another limit (D3: the answer
approximated). By reading, the code it generates is sound (each leaf the concrete class Julia's value has, the search's miss
unreachable under A68S3) but for A75S2; it over-rejects: an open element of type `Any`, or any abstract type with five or more
classes met, rejects (the cases' own Tuple{Type{Int64}, Any} with 26 classes and (Any, Int64)), each located (D9 met), each a
program inside Julia's verifier (D32 not). The nearest 1:1 match is dart's record model: one class per shape (`sed -n 84p
pkg/dart2wasm/lib/record_class_generator.dart` gives `Map<RecordShape, Class> generateRecordClasses(`, its fields untyped,
:280 `_generateFields`), its run-time type made from its fields' (:653 `_generateRecordRuntimeType`, the
_RecordType of sdk/lib/_internal/wasm/common/type.dart:573), an is-check field by field (type.dart:587 `return
unsafeCast<Record>(o)._checkRecordType(fieldTypes, names);`, :547 `_generateCheckRecordType`). Ported, it needs: a shape
class per tuple length whose fields hold the top type, built where the static type is not concrete; the Julia type of such a
value made from its fields at run time, Julia's own arg_tuple (builtins.c) ported, which lifts A68S3 for tuples and needs
type identity for the result; isa, typeassert and dispatch on such a value read field by field as _checkRecordType does;
and, because WasmTarget lays a concrete tuple class out with Julia's field types, a conversion from the shape class to the
concrete class where a concrete static type meets it, which dart (one layout per shape) has no counterpart for, so that step
needs its own precedent (Julia boxes a jl_f_tuple result with its concrete type, one layout per type). The entry half of
A70S3 joins this: a tuple packed at entry is the same jl_f_tuple tuple. Fix: the lead rules between the record model so
ported and the enumeration kept as a @quarantine that names no borrowed bound (its budget then a D17 target with a band);
either way max_union_splitting leaves the citation, in bee9ca3c's and e84214d1's text and in tuple_classes' reason. Owner:
wt3-memory (src/julia/classes.jl, src/intrinsics.jl), with wt3-cgstubs2 (src/code_generator.jl _visitArguments,
_setupLocalParameters, visit_record_literal).

R2: the first progress line after 11c9e8a2, from its landing (the lead's ship log of 18:34:11Z, `grep -oE 'pushed
[0-9a-f]{8}|src: [0-9]+ of 3404 .*' ship18.log`): `pushed 11c9e8a2`, `src: 3083 of 3404 anchored dart definitions ported with
a body (…), 32 of them a dart body that itself throws, ported as its throw; … not counted ported: 274 that never return,
Julia's inference finds, rejecting Internal (…), 5 gap(s) still to fill (4 rejecting Unported or Unquarantined, 1 an
@unported stub) and 42 in place of a dart abstract declaration (no body to port); 3083 + 274 + 5 + 42 = 3404 of 3404`, the
lead's headline, matching 11c9e8a2's own read-back (3051 body + 32 DartThrow). No definition hits the new refusal: it throws
ConstructionViolation, which stops the count, and every landing since prints its line. d5db52fa moves one gap to a body
(KernelNodes.printToConsole, Unported to a body): its landing prints `3084 + 274 + 4 + 42 = 3404 of 3404` and `13 rejecting
site(s) name 10 definition(s) of sdk/lib/_internal/wasm/` (from 15 and 11; wt3-codegen-b's .wtd/autoship.out, `pushed
d5db52fa`), as 92e6b448's does (ship19.log); so the headline at the head is 3084 of 3404.

Resolution: this entry lands alone, prose only, and fixes nothing. A70S3 leaves 1.D, A73S1 1.K, A74S2 1.A6, A74E1 1.L.
A75S1 and A75S2 are open on 1.D; A75S3, A75S4 and A75S5 on 1.F; A75S6 on 1.K; A75E3 on 1.A6; A75E1 and A75E2 on 1.L. By
owner: wt3-memory A75S1 (with wt3-cgstubs2) and A75S2; wt3-runtime A75S3, A75S4, A75S5, with A73S2 and A73S3; wt3-parity
A75S6, A75E2, A75E3, with A74S1, A74S3, A74S4; lead A75E1; wt3-latency A73E1; wt3-cgstubs2 A71S3.

## 2026-11-01 — audited through c7e8b37b (e84214d1..c7e8b37b: dart's throwing and abstract members read by dev/skeleton.jl, _makeFunctionType one body, the OverrideVerifier step map and jl_method_def, the progress history file, the rejection kinds cached per src tree, the D11 lock's closure over the definitions a claim reads, the héllo case under the JS runtime)

The seventy-sixth audit, beside the work, covers the 7 commits of e84214d1..c7e8b37b that are not audit entries (318c4c93,
entry 75): a945477c, 12ed37ae, 9acc0b92, 8e4d4d73, 0ccae918, 709bfbee and c7e8b37b, read here, under Dale's R1 and R2 as
standing sections. Every finding rests on one exact command, quoted. Standing items. src changes in 3 files (`git diff
--stat e84214d1..origin/wt2 -- src | tail -1` gives `3 files changed, 64 insertions(+), 122 deletions(-)`); no exemption
lands (`git diff e84214d1..origin/wt2 -- src | grep -cE '^\+.*(Reshaped:|Fields with no Julia counterpart)'` gives 0). The
debt list reads 389, unchanged (`grep -v '^#' dev/quarantine_unpinned.txt | grep -c .`). Earlier findings: A74S1 is fixed
by a945477c (`grep -c 'local dart_member' src/julia/parity.jl` gives 0; the body forms read from skeleton's tokens,
dart_kinds composing them, with plants); A74S3 by 9acc0b92, its residue A76S2; A74S4 by 9acc0b92 (`grep -c 'julia.h:905'
src/julia/parity.jl` gives 0; `sed -n 1191p src/method.c` of the julia pin gives `JL_DLLEXPORT jl_method_t*
jl_method_def(jl_svec_t *argdata,`, and :1315 `m->file = file;`); A67S3 by 12ed37ae (`grep -c 'functions.dart:890
_makeFunctionType' src/functions.jl` gives 1), its residue A76S1; A75E2 by 709bfbee, its residue A76E4; A75S3 by c7e8b37b
(the case compiles by Dart2Wasm.compile, runs under the generated .mjs in node and compares `sprint(println, "héllo") *
sprint(println, 7)`). A75E1 is corrected: dev/ship.sh has refused a lane named in the common dir's wt-held since 3d0e7725
(07:24 -0800, `git log -S'wt-held' -- dev/ship.sh`), but a lane runs the ship.sh of its own base (A76E3), so a lane based
before 3d0e7725 lands past a hold; eight autoship loops still run (`ps aux | grep -c '[b]ash dev/autoship.sh'` gives 8).
Open as they stood: A75S1 (`grep -n max_union_splitting src/julia/classes.jl` gives `86:`, `90:`); A75S4 (`grep -n 'lib ==
JS_INTEROP_LIBRARY' src/julia/runtime/rtutils.jl` gives `181:`); A75S6 (`grep -n 'Symbol("@assume_effects")'
src/julia/parity.jl` gives `177:`); A75E3 (`grep -c 'own signature matches no method\|no frame for its signature'
test/parity_ratchet.jl` gives 0); A71S3 (`grep -n 'codegen.cpp:2638' src/code_generator.jl` gives `2040:`); A73S2 (`grep -n
'const baseImports = ' src/julia/runtime/rtutils.jl` gives `113:`); A73S3 (`grep -n ':typeassert),' src/julia/subset.jl`
gives `199:`); A73E1 (`grep -n 'instantiates no' src/julia/nir.jl` gives `727:`); A68E3 (`tail -1 .git/wt-corpus.tsv` gives
f05b2fa8's `hung 1216` row); A75S2, A75S5, A75E1, A71E2, A69E1, A68E2, A68S4, A72E1, A67E1 and A67S1, carried, not re-read.
Findings A76S1, A76S2 and A76E1 to A76E6.

Area: builder — no change under src/wasm_builder.

Area: collection and planning — no change to the closed world's walk; 12ed37ae's inputs, below.

Area: emission and diagnostics — 12ed37ae: one _make_function_type (functions.jl:560) for every target, a static field's
accessors in dart's first arm, every other target through _get_input_types (dart's Field arm for an instance field's
setter value, a NirForeignImport's declared argument types) and type_of_return_value (translator.jl:1413); the callers pass
the target and its receiver. (A76S1, low, D8) the three match `Union{Reference,NirForeignImport}` by isa chains whose last
arm is a wildcard: `target isa FieldReference ? … : target isa NirForeignImport ? target.params :
nir_parameter_types(target)[2:end]` (functions.jl, _get_input_types), the same chain in type_of_return_value, and the
static-field arm's FieldReferenceKind tested for getter and initializer with the setter the fall-through; Reference is a
closed sum (`grep -n '@closed const Reference' src/julia/kernel.jl` gives `69:`) that functions.jl itself matches
@exhaustive (`grep -n '@exhaustive target::Reference' src/functions.jl` gives `119:`, `160:`, `302:`, `313:`, `322:`), so a
third Reference arm would take the MethodInstance path silently. Fix: each matched @exhaustive over Reference's arms, with
NirForeignImport its own arm, and FieldReferenceKind matched @exhaustive. Owner: wt3-runtime (src/functions.jl,
src/translator.jl). c7e8b37b: the héllo case, above.

Area: enforcement and prose — a945477c: Decl carries each member's body form from its tokens (body_form: `;` abstract unless
external, `=>` or `{` then `throw` a throw at its line, `=` a body); dart_kinds turns Internal into DartThrow and
DartAbstract; rejection_only_kinds reads no dart. 0ccae918: the kinds (rejection_only_kinds then dart_kinds, with their
lines) written to `<common dir>/wt-rejection-kinds/<key>.tsv`, the key a sha256 of src/'s files, dev/skeleton.jl,
dev/skeleton_scope.toml and `julia --version`; the line ends `the kinds cache: hit` or `miss`. Against the lead's four
conditions: (2) holds, the plants call rejection_only_kinds and dart_kinds directly and the planted-number lines run no
Julia (`sed -n 1584,1680p test/parity_ratchet.jl`); (4) holds (wt3-codegen-b's .wtd/autoship.out for c7e8b37b ends `3084 +
274 + 4 + 42 = 3404 of 3404; the kinds cache: hit`). (A76E1, medium, D5/D17, the snapshot record) (1) and (3) fail. The key
(`sed -n 36,41p dev/src_progress.sh`) leaves out dev/src_progress.sh itself, whose inline program chooses the entries
(`_within(x.mod, WasmTarget)`) and writes and parses the file; lib/WasmInterpreter/, which src imports (`grep -rln
WasmInterpreter src` gives src/WasmTarget.jl, src/julia/subset.jl, src/julia/interpreter.jl) and whose callees inference
reads in deciding that a src method never returns; and Project.toml/Manifest.toml. The dart, julia and llvm pins are in
src/julia/parity.jl (:918, :1048, :1029), held to dev/PARITY_MASTER.md by the ratchet, so they are covered. `julia
--version` gives `julia version 1.12.7`, a release name, where Julia's own cache checks the build (`sed -n 4049p
base/loading.jl` of the julia pin gives `@constprop :none function stale_cachefile(modkey::PkgId, build_id::UInt128,
modpath::String, cachefile::String;`, which checks each include's content and each dependency's build id). No plant changes
one input alone and expects a miss (`git show 0ccae918 -- test/parity_ratchet.jl` changes only L208's text), and the commit
names no precedent (D7). Fix: the key read as stale_cachefile reads it, from WasmTarget's own include list (its cache
header's includes, which hold lib/WasmInterpreter and every src file) and Base's build id, plus dev/skeleton.jl, its scope
and dev/src_progress.sh, cited at loading.jl:4049; plants in L208 on a scratch copy: a change to dev/skeleton.jl alone, to
the program alone and to a src file alone, each a miss. Owner: wt3-parity (dev/src_progress.sh, test/parity_ratchet.jl).
(A76E2, low, D5) the cache's read and write are written twice, verbatim (`grep -n 'cache = ENV\["WT_KINDS_CACHE"\]\|the
newest sixteen kept' dev/src_progress.sh` gives `52:`, `68:`, `118:`, `134:`), and the kinds branch builds `es` and then the
same filter again in its miss arm. Fix: one function both call. Owner: wt3-parity (dev/src_progress.sh). 8e4d4d73: ship.sh
appends each landing's line to `<common dir>/wt-progress.tsv`. (A76E3, medium, D5, R2) the history holds one row in four
landings: `cut -f1,2 .git/wt-progress.tsv` gives only `2026-11-01T19:24:37Z 8e4d4d73`, where `tail -4 .git/wt-landings.tsv`
gives 8e4d4d73, 0ccae918, 709bfbee and c7e8b37b; c7e8b37b's ship printed its line (wt3-codegen-b's .wtd/autoship.out,
`ship: pushed c7e8b37b`) and wrote no row, because the ship.sh that ran is the lane's own (`git -C
../.worktrees/wt3-codegen-b show HEAD:dev/ship.sh | grep -c wt-progress` gives 0, that lane's HEAD a22bcfd7). Every change to
ship.sh, the hold of 3d0e7725 among them, binds a landing only once its lane is based past it. Fix: dev/ship.sh, after its
fetch, runs origin/wt2's own copy (`git show origin/$MARCH:dev/ship.sh`) when it differs from the lane's, or refuses; the
stale autoship loops stopped. Owner: lead (dev/ship.sh, dev/autoship.sh). 709bfbee: invariants_dropped closes the compared
definitions over every operator a claim's text names, recursively, from the claims, Init, Next and the constants'
definitions. (A76E4, medium, D11) the roots are the literal names `Init` and `Next` (`union!(defs_named, ("Init",
"Next"))`), never a cfg's SPECIFICATION: `grep -h '^SPECIFICATION\|^INIT\|^NEXT' dev/formal/MC*.cfg | sort | uniq -c` gives
207 `SPECIFICATION Spec`, 21 `SPECIFICATION Spec_`, 5 `INIT Init` and 5 `NEXT Next`, so `Spec == Init /\ [][UNCHANGED
vars]_vars` passes unnamed, and a model whose next-state relation is named otherwise (`grep -h '^Spec ==' dev/formal/*.tla`
gives `Spec == Init /\ [][Step \/ Terminal]_vars`) has neither read; Next has no plant (the plant's cfg names `Spec`, which
its module does not define). Fix: the roots read from each cfg (SPECIFICATION, INIT, NEXT, its claims), with plants for Spec
rewritten and for a Next rewritten. Owner: wt3-parity (test/parity_ratchet.jl). (A76E5, low, the 19:35Z rule) 709bfbee
changes L227 (committed 19:37:25Z) and its body states no measured G cost (`git log -1 --format=%B 709bfbee | grep -ciE 'G
cost|CPU-s|[0-9]+ ?G\b'` gives 0). Fix: the cost measured and stated with the A76E4 fix. Owner: wt3-parity. 9acc0b92:
_parity_entry's map, read against `pkg/analyzer/lib/src/error/override_verifier.dart` at the pin line by line: :70
hasOverride, :71 the switch, :73 the report (its diag on :74), :86 the super call, :121 _isOverride, :123 the null class,
:131 the nameless member, each as cited. (A76S2, low, R1) 9acc0b92's subject claims every step of OverrideVerifier, but the
map covers visitMethodDeclaration and _isOverride only: visitFunctionDeclaration (:50, a top-level function's annotation),
visitFieldDeclaration and _checkField (:39, :110, a field's), visitPrimaryConstructorDeclaration (:97) and the class
visitors that set the `_currentClass` :122 reads (:25, :32, :90) are neither mapped nor said to have no counterpart, where
@parity anchors top-level functions and a class's fields too. Fix: each named in the map or the subject trimmed. Owner:
wt3-parity (src/julia/parity.jl). (A76E6, low, evidence) a945477c's body says `The count is unchanged: 3083 + 274 + 5 + 42 =
3404` and 0ccae918's `the same line both times (3083 + 274 + 5 + 42 = 3404 of 3404)`, where the head both landed onto read
`3084 + 274 + 4 + 42` since d5db52fa (audit 75's R2; the one wt-progress.tsv row): measured on trees before their rebase.
Fix: a landing's numbers taken from its own check's line. Owner: wt3-parity.

stopgap in disguise: the kinds cache, a record whose key a hand-picked list of inputs bounds, A76E1; the D11 lock's roots, two names written in rather than read from the cfg, A76E4.

precedent: jl_method_def (method.c:1191) for _methods_of_file; OverrideVerifier by line for _parity_entry; the cache has none cited, Base's stale_cachefile (loading.jl:4049) the nearest, A76E1.

Requirements: D5, D7, D8, D11, D17; no lock fired inside its band.

R1 and R2. R1: each new citation is read at its pin (above): method.c:1191 and :1315 resolve; the step map's lines resolve;
c7e8b37b's oracle is Julia's println. The cache is the one bespoke construction, its precedent Base's stale_cachefile
(A76E1). R2: the latest row of `.git/wt-progress.tsv` (8e4d4d73, 19:24:37Z) reads `3084 + 274 + 4 + 42 = 3404 of 3404`,
32 of the 3084 a dart body that throws, the one @unported stub (_virtualCall) and 3 rejecting Unported or Unquarantined
counted as the 4 gaps, 42 DartAbstract beside the headline; c7e8b37b's ship prints the same. `bash dev/src_progress.sh
kinds` was not run: in this new worktree its private depot would precompile WasmTarget, and its answer would be read from
the same cache (this tree's key, computed as the script computes it, is 8ae17673…, whose file exists). The cached file's
kinds over every entry (`cut -f2 .git/wt-rejection-kinds/8ae1767342da5ce3cda3a9cd36e55f496925504a.tsv | sort | uniq -c`)
give 32 DartThrow and 42 DartAbstract, as the line; 278 Internal and 6 Unported or Unquarantined over all entries, the
line's 274 and 3 being those at counted anchors. The agreement rests on the cache this entry finds unkeyed (A76E1), so it
is no independent read.

Resolution: this entry lands alone, prose only, and fixes nothing. A74S1 leaves 1.A6; A74S3 and A74S4 1.K; A75E2 1.L;
A67S3 and A75S3 had left 1.F by their fixing commits. A76E1, A76E2 and A76E6 are open on 1.A6; A76E3, A76E4 and A76E5 on
1.L; A76S1 on 1.F; A76S2 on 1.K. By owner: wt3-parity A76E1, A76E2, A76E4, A76E5, A76E6 and A76S2, with A75S6 and A75E3;
lead A76E3, with A75E1; wt3-runtime A76S1, with A75S4, A75S5, A73S2 and A73S3; wt3-memory A75S1 and A75S2; wt3-latency
A73E1; wt3-cgstubs2 A71S3.

## 2026-11-01 — audited through 903a3332 (c7e8b37b..903a3332: ship.sh run from origin's copy, a pre-push hook admitting origin's ship.sh by its blob, the packed i16 element, a runtime binding judged by its initializers' closed world and Julia's effects, inline JS admitted only from Runtime's ports and named once per code, js_parse_assignment! anchored at parseAssignment)

The seventy-seventh audit, beside the work, covers the 7 commits of c7e8b37b..903a3332 that are not audit entries (84885030,
entry 76): dab5842d, 84f7098d, 40d2c6d9, 449338c0, 77f7126a, 43bb71d3 and 903a3332, read here, under Dale's R1 and R2 as
standing sections. Every finding rests on one exact command, quoted. Standing items. src changes in 9 files (`git diff
--stat c7e8b37b..origin/wt2 -- src | tail -1` gives `9 files changed, 202 insertions(+), 40 deletions(-)`); no exemption
lands (`git diff c7e8b37b..origin/wt2 -- src | grep -cE '^\+.*(Reshaped:|Fields with no Julia counterpart)'` gives 0), and
no catch (`grep -cE '^\+.*catch'` of the same diff gives 0). The debt list reads 387, two fewer (`grep -v '^#'
dev/quarantine_unpinned.txt | grep -c .`; _memory_element_storage and nir_binding_value now cite their pin lines). Earlier
findings: A75S5 is fixed by 449338c0 (two sites in one caller are two imports; `sed -n 721p src/ccall.cpp` of the julia pin
gives `static jl_cgval_t emit_llvmcall(...`), its residue A77S2; A75S4's admission half by 449338c0 (`grep -n 'lib ==
JS_INTEROP_LIBRARY' src/julia/runtime/rtutils.jl` gives `196:` and `199:`, the second refusing a call written outside
Runtime as a ProgramError), its parse half open on 1.F, where the commit's ground holds (`git grep -n MiniJsParser 898a1e4b
-- pkg/dart2wasm/lib` of the dart pin gives nothing, and pkg/js_ast/lib/src/builder.dart:801 reaches
parseExpressionOrArrowFunction, the one arrow form, only after a `(`); A73S2 by 903a3332 (builder.dart:1076 `Expression
parseAssignment() {` and :1142 `VariableDeclarationList parseVariableDeclarationList() {` at the pin; the blob is a module
with classes, `export` and `class` the mini parser has no rule for); A76E3 by dab5842d, 77f7126a and 43bb71d3, every
landing since 43bb71d3 with its row (`cut -f2 .git/wt-progress.tsv | tail -2` gives 43bb71d3, 903a3332), its residue A77E2;
A75E1 by 43bb71d3, an older copy's push refused at the hook, its residue A77E1. Open as they stood: A75S1 (`grep -n
max_union_splitting src/julia/classes.jl` gives `86:`, `90:`, `97:`, `100:`); A75S6 (`grep -n 'Symbol("@assume_effects")'
src/julia/parity.jl` gives `177:`); A75E3 (`grep -c 'own signature matches no method\|no frame for its signature'
test/parity_ratchet.jl` gives 0); A71S3 (`grep -n 'codegen.cpp:2638' src/code_generator.jl` gives `2040:`); A73S3 (`grep -n
':typeassert),' src/julia/subset.jl` gives `199:`); A73E1 (`grep -n 'instantiates no' src/julia/nir.jl` gives `827:`);
A68E3 (`tail -1 .git/wt-corpus.tsv` gives f05b2fa8's `hung 1216` row); A76E2 (`grep -n 'cache = ENV\["WT_KINDS_CACHE"\]\|the
newest sixteen kept' dev/src_progress.sh` gives `52:`, `68:`, `118:`, `134:`); A76E4 (`grep -n 'union!(defs_named, ("Init"'
test/parity_ratchet.jl` gives `2630:`); A76S1 (`grep -n 'target isa FieldReference ?' src/functions.jl` gives `481:`);
A76E1 (`sed -n 36,41p dev/src_progress.sh | grep -c 'src_progress.sh\|WasmInterpreter\|Manifest'` gives 0); A76S2, A76E5,
A76E6, A75S2, A71E2, A69E1, A68E2, A68S4, A72E1, A67E1 and A67S1, carried, not re-read. Findings A77S1, A77S2 and A77E1 to
A77E3.

Area: builder — no change under src/wasm_builder.

Area: collection and planning — 40d2c6d9: runtime_initializers (construction.jl) walks Core's and Base's submodules for an
`__init__` each defines (Base, GMP, MPFR, Sys); runtime_init_bindings (nir.jl) runs `Core.Compiler.typeinf_ext_toplevel(Any[mi],
[world], TRIM_NO)` on each and collects (a) every GlobalRef, setglobal! and getglobal target its CodeInfos name and (b) each
GlobalRef, or SSA value holding one, passed to a call Julia's effects do not infer effect_free; nir_binding_value rejects a
non-const binding in (a) or a const object in (b). Its citations resolve at the julia pin: init.c:563 `static NOINLINE void
_finish_jl_init_(`, :618-628 the init-order loop; precompile.c:98 `JL_DLLEXPORT void jl_write_compiler_output(void)`, whose
worklist compiles each init-list module's `__init__` under trim; Compiler/src/typeinfer.jl:1534 `function
typeinf_ext_toplevel(methods::Vector{Any}, worlds::Vector{UInt}, trim_mode::UInt8)`; effects.jl:119 `struct Effects`;
toplevel.c:207-230 pushing and deferring the init order. (A77S1, medium, D9, R1) the closed world is the one juliac verifies,
read unverified: compile! (typeinfer.jl:1451) follows only `:invoke` edges (collectinvokes!, :1336), so a dynamic call's
callees are never in it, and juliac's TRIM_SAFE would refuse each where TRIM_NO passes them silently. Measured on the four
initializers (`taskpolicy -b julia --startup-file=no scratchpad/init_world.jl`, counting each CodeInfo's `:call` to a
non-builtin or to _apply_iterate, invoke or invokelatest): `Base.__init__: 1006 bodies, 225 dynamic call(s)` (60 of them
invokelatest in stale_cachefile alone), `Base.Sys.__init__: 127 bodies, 1`, `Base.GMP.__init__: 178 bodies, 8`,
`Base.MPFR.__init__: 60 bodies, 0`. A binding an initializer sets only behind one of these (a logging handler invokelatest
reaches, a show method) is never in (a), and starts at its session value unnamed: a plausible value past a gap. (b) follows a
const object only through an SSA value whose statement is the bare GlobalRef (`holds[k] = st` for `st isa GlobalRef`), not
through getfield, a PiNode or a PhiNode, so an object reached from a const (a field of a const struct) and mutated is never
in it; no plant reaches either (`git show 40d2c6d9 -- test/src/globals.jl` adds stdout, DEPOT_PATH, CPU_THREADS,
base36digits and powers_of_ten, each reached directly). Fix: each dynamic call's callees enqueued as juliac's verifier
enumerates them (verify_typeinf_trim, typeinfer.jl:1567), a call with no finite match set rejecting every binding read the
initializers could reach, located at that call; (b) through Julia's own flow of a value (the IR's def-use, PiNode and
PhiNode included); runtime_init_bindings taking its initializers, so a plant passes one setting a global behind
invokelatest and one mutating a const's field, each named. Owner: wt3-memory (src/julia/nir.jl, src/julia/construction.jl).
Cost (the lead's question): lazy, `_RUNTIME_INIT_BINDINGS` nothing until nir_binding_value first meets a runtime binding
that is not a mutation-free const; nothing computes it at precompile (`grep -rn
'compile_workload\|PrecompileTools\|precompile(' src/WasmTarget.jl src/*.jl` gives nothing). One landing check pays it once,
in the shard that runs globals.jl: `grep globals .git/wt-src-instr.tsv` gives `globals.jl 7.2 3.2`, 4.0 G more than before,
its cases' own cost; the four closed worlds took 2.4 s wall in a plain julia (above).

Area: emission and diagnostics — 84f7098d: _memory_element_storage gives a 2-byte non-float primitive WasmI16 and
read_int_array's inner extend already takes PackedType_i16; dart's own at the pin: wasm_types.dart:151 `class WasmI16 extends
_WasmBase {}`, intrinsics.dart:3490 readIntArray's `wasmType == w.PackedType.i8 || wasmType == w.PackedType.i16`; the
quarantine's genericmemory.c:55 is `_new_genericmemory_(...)`. Its cases read a signed and an unsigned element in range and
one past it against native; Float16 still rejects, located. 449338c0: nir_statement_module reads the innermost frame of a
statement's debug info (Compiler/src/ssair/show.jl:405 `function buildLineInfoNode(debuginfo, @nospecialize(def), pc::Int)`);
nir_js_codes reads each code of a body once; the interop namer keys a site by its code. (A77S2, low, R1, D4) dart makes one
procedure per JS<T> site, named by a counter: `git show 898a1e4b:pkg/dart2wasm/lib/js/inline_expander.dart | sed -n 62,64p`
gives `dartProcedure = makeInteropProcedure(`, `_staticTypeContext.enclosingLibrary,`, `'_JS_Inline_${_counter++}',`, and
that procedure is the key of interopMemberNames (namer.dart:109 `final Map<Member, String> interopMemberNames = {};`, :123
`interopMemberNames[member] ??= _interopHelperNamer.getName(member.name.text`). get_import_name keys by the code text and
mints the name from the enclosing method, the first caller the site was inlined into (`get!(() -> get_name(...,
string((enclosing.def::Method).name); ...), self.interop_member_names, site.name)`), so two sites written apart with one
code are one import and a site's name changes with the caller met first, where Julia records the site itself: the method
and line that wrote the foreign call, the innermost frame nir_statement_module already reads. Fix: a site keyed by its
innermost frame (method and line), named `_JS_Inline_<n>` in the order generateJsMethods meets sites, cited at
inline_expander.dart:62. Owner: wt3-runtime (src/namer.jl, src/julia/runtime/rtutils.jl, src/js/runtime_generator.jl).
903a3332, above.

Area: enforcement and prose — dab5842d: after a fetch, a lane whose dev/ship.sh differs from origin's runs `git show
origin/wt2:dev/ship.sh` saved as .wtd/ship.origin.sh, by `WT_SHIP_ORIGIN=1 exec bash .wtd/ship.origin.sh`; its paths resolve
(`cd "$(dirname "$0")/.."` takes .wtd/.. to the lane, and `git hash-object "$0"` reads .wtd/ship.origin.sh from there).
77f7126a's `export WT_SHIP_RULES=2` was a hand-bumped number; 43bb71d3 replaces it with ship.sh's own blob, which the hook
requires to equal `git rev-parse origin/wt2:dev/ship.sh`, a comparison, not a version. The installed copy is today's (`cmp
.git/hooks/pre-push dev/hooks/pre-push` silent; core.hooksPath is the common dir's hooks). (A77E1, medium, D6) the hook
admits by an environment variable, which every child process inherits: a ship.sh from before 77f7126a sets none and reads
the caller's, so an older copy run from a shell holding origin's blob (as 43bb71d3's own test set it) passes, and `git push
--no-verify` skips it; and the installed hook is a copy nothing compares with dev/hooks/pre-push (`grep -rn
'hooks/pre-push' dev test src` gives only ship.sh's comment and the hook's install line), so a change to the hook or its
removal goes unnoticed. Fix: the marker written where only a running ship.sh writes it, the landing lock (`$common/wt-landing-lock`,
beside its pid), and the hook admitting a push only while that lock's live pid holds origin's blob; ship.sh refusing unless
`git hash-object $common/hooks/pre-push` equals `git rev-parse origin/wt2:dev/hooks/pre-push`. The source that would make
an unchecked push unwritable is origin itself (a ruleset on wt2), recorded below. Owner: lead (dev/hooks/pre-push,
dev/ship.sh). (A77E2, medium, D5, R2) eight autoship loops still run (`ps aux | grep -c '[b]ash dev/autoship.sh'` gives 8),
in wt3-audit, wt3-cgstubs, wt3-codegen, wt3-codegen-b, wt3-constants, wt3-fix, wt3-loop and wt3-tests, five on trees whose
ship.sh has no trampoline (`git -C ../<lane> show HEAD:dev/ship.sh | grep -c WT_SHIP_ORIGIN` gives 0 for all but the two
codegen lanes): wt3-constants' writes a conflict row to wt-ship-failures.tsv every few minutes, each naming origin's newest
landed commit as the failed one (`tail -5 .git/wt-ship-failures.tsv` gives rows at 19:50:41, 19:59:46, 20:04:51 and
20:07:54 naming dab5842d, 449338c0, 77f7126a and 43bb71d3), and wt3-loop's ship.sh has waited since Thursday (pid 80814).
84f7098d and 40d2c6d9 landed from older copies before the hook and have no progress row (`cut -f2 .git/wt-progress.tsv` gives
84885030, dab5842d, 449338c0, ..., where `tail -7 .git/wt-landings.tsv` has 84f7098d and 40d2c6d9 between dab5842d and
449338c0). Fix: the loops stopped, A76E3's second half, and an autoship loop that finds its ship.sh differs from origin's
exits. Owner: lead (dev/autoship.sh). (A77E3, low, D5) the trampoline swaps ship.sh alone: line 42 reads D14_RED from the
lane's own dev/check.sh (`sed -n 's/^D14_RED=...' dev/check.sh`, run before `cd "$scratch"` at :85) and line 168 ranks the
queue by the scratch's dev/src_progress.sh, the lane's HEAD before its rebase; and the blob is compared only at the push, so a
ship.sh that lands while a lane waits in the queue makes that lane's whole check run before the hook refuses it (the fetch
under the lock, :193, is followed by checked_rebase, :206, with no comparison). Fix: D14_RED and the port class read from
origin's blobs; WT_SHIP_RULES compared with origin's blob after the locked fetch, before the check. Owner: lead (dev/ship.sh).

stopgap in disguise: the pre-push hook, a client-side check keyed by an inherited environment variable where a ruleset on
origin's wt2 is the source, A77E1; the binding rule's closed world, juliac's trim read with its verifier off, A77S1.

precedent: juliac's init list and trim (init.c:563, precompile.c:98, typeinfer.jl:1534) for runtime_init_bindings, its
dynamic callees left out (A77S1); Julia's effects (effects.jl:119) per call; buildLineInfoNode (show.jl:405) for a
statement's module; llvmcall's emit_llvmcall (ccall.cpp:721) for code carried as a call's argument; dart's
`_JS_Inline_<n>` (inline_expander.dart:62) the naming 449338c0 leaves (A77S2); MiniJsParser.parseAssignment (builder.dart:1076)
for js_parse_assignment!.

Requirements: D4, D5, D6, D9; no lock fired inside its band.

R1 and R2. R1: each citation of the range is read at its pin, above, and resolves. 84f7098d is dart's WasmI16 and
readIntArray as written. 40d2c6d9 ports juliac's mechanism, with the verifier half of it dropped (A77S1). 449338c0 parses
nothing, as dart2wasm writes a JS<T> code verbatim (generateJsMethods), and its naming departs from dart's counter (A77S2).
903a3332 names the parser levels it drops, each a located rejection. R2: the latest row of `.git/wt-progress.tsv`
(903a3332, 20:11:39Z; 43bb71d3's, 20:07:46Z, the same) reads `3084 + 274 + 4 + 42 = 3404 of 3404; the kinds cache: hit`:
3084 ported with a body, 32 of them a dart body that throws, 274 Internal (never returning, by Julia's inference), 4 gaps (3
Unported or Unquarantined, 1 the @unported stub) and 42 DartAbstract, none counted ported; the sum is 3404, unchanged since
d5db52fa. 84f7098d and 40d2c6d9 changed src without moving the count, each filling an arm inside a body already counted.
The line is read from the kinds cache A76E1 finds keyed short of its inputs, so it is no independent read.

Resolution: this entry lands alone, prose only, and fixes nothing. A75S5 and A73S2 leave 1.F; A75E1 and A76E3 leave 1.L.
A77S1 is open on 1.C, beside A64R3; A77S2 on 1.F; A77E1, A77E2 and A77E3 on 1.L. By owner: lead A77E1, A77E2 and A77E3;
wt3-memory A77S1, with A75S1 and A75S2; wt3-runtime A77S2, with A75S4, A76S1, A73S3 and A67S1; wt3-parity A76E1, A76E2,
A76E4, A76E5, A76E6, A76S2, A75S6 and A75E3; wt3-latency A73E1; wt3-cgstubs2 A71S3.

## 2026-11-01 — audited through 0f92ada6 (903a3332..0f92ada6: a changed ship.sh refused under the lock before its check, a String argument bound as a literal of the program, an effects claim only on an overlay keeping Base's, the no-match refusal planted, the kinds cache keyed by Base's staleness rule in one script and one block)

The seventy-eighth audit, beside the work, covers the 5 commits of 903a3332..0f92ada6 that are not audit entries (16981666,
entry 77): 3b1a4643, 6732d4a6, a36ed084, 98390e9e and 0f92ada6, read here, under Dale's R1 and R2 as standing sections.
Every finding rests on one exact command, quoted. Standing items. src changes in 1 file (`git diff --stat
903a3332..0f92ada6 -- src | tail -1` gives `1 file changed, 24 insertions(+), 2 deletions(-)`, src/julia/parity.jl); no
exemption lands (`git diff 903a3332..0f92ada6 -- src | grep -cE '^\+.*(Reshaped:|Fields with no Julia counterpart)'` gives
0), and no catch (`grep -cE '^\+.*catch'` of the same diff gives 0). The debt list reads 387, unchanged (`grep -v '^#'
dev/quarantine_unpinned.txt | grep -c .`). Each commit names its clause (C0, C10, C2, C2, C0). Earlier findings: A75S6 is
fixed by a36ed084 for a Method's purity, its residue A78E2; A75E3 by 98390e9e (`grep -c 'matches no method of its own'
test/parity_ratchet.jl` gives 4), its residue A78S1; A76E2 by 0f92ada6 (`grep -n 'the newest sixteen kept'
dev/src_progress.sh dev/progress_kinds.jl` gives only `dev/progress_kinds.jl:25:`); A76E1 by 0f92ada6, its residue A78E1
and A78S2; A77E3's blob half by 3b1a4643 (dev/ship.sh:197 compares `origin/$MARCH:dev/ship.sh` with WT_SHIP_RULES after the
locked fetch, before the rebase), its message naming no finding, the first half open (`grep -n 'D14_RED=' dev/ship.sh`
gives `42:`, the lane's dev/check.sh). Open as they stood: A77E1 (`grep -n 'hooks/pre-push' dev/ship.sh` gives only the
comments at `17:` and `194:`, no comparison of the installed copy); A77E2 (`ps aux | grep -c '[b]ash dev/autoship.sh'` gives
8; `tail -1 .git/wt-ship-failures.tsv` is wt3-constants' conflict at 20:40:22 naming 0f92ada6); A77S1 (`grep -n TRIM_NO
src/julia/nir.jl` gives `704:`, `760:`); A77S2 (`grep -n 'interop_member_names, site' src/namer.jl` gives `143:`); A75S1
(`grep -n max_union_splitting src/julia/classes.jl` gives `86:`, `90:`, `97:`, `100:`); A71S3 (`grep -n 'codegen.cpp:2638'
src/code_generator.jl` gives `2040:`); A73S3 (`grep -n ':typeassert),' src/julia/subset.jl` gives `199:`); A73E1 (`grep -n
'instantiates no' src/julia/nir.jl` gives `827:`); A76E4 (`grep -n 'union!(defs_named, ("Init"' test/parity_ratchet.jl`
gives `2679:`); A76S1 (`grep -n 'target isa FieldReference ?' src/functions.jl` gives `481:`); A68E3 (`tail -1
.git/wt-corpus.tsv` gives 6732d4a6's `hung 1218` row); A76S2, A76E5, A76E6, A75S2, A71E2, A69E1, A68E2, A68S4, A72E1, A67E1
and A67S1, carried, not re-read. Findings A78E1 to A78E3, A78S1 and A78S2.

Area: builder — no change under src/wasm_builder.

Area: collection and planning — no change to the collection or the plan in src.

Area: emission and diagnostics — 6732d4a6 (test/runner.jl): a case's String argument becomes a literal of a method
`_call_bound` generates, passed to the function inside the program, its native answer Bound's own and its label naming the
position bound. Its precedent resolves at the dart pin: `git -C ~/.cache/wasmtarget/dart-sdk show
898a1e4b:tests/language/identity/identical_test.dart` has `notIdenticalTest1(a) {`, `if (!identical("ho", a)) {` and a
main calling `notIdenticalTest1("ho")`, the shape Bound reproduces. The literal is not folded through the call by Julia's
inference: a Const String is no const-prop argument (abstractlattice.jl:232 `!ismutable(val)`, and jltypes.c:3190-3191 makes
String a mutable type). The corpus run at its head bears the commit's count out: `grep -c 'marshals no String'
.git/wt-corpus-red-f05b2fa8.out .git/wt-corpus-red-6732d4a6.out` gives 109 and 0. Its self-test hands a recording compile,
so no landing case compiles a bound String; the corpus is its judge, as the commit says.

Area: enforcement and prose — 3b1a4643: the blob comparison under the lock, above; the hook's refusal reaches
wt-ship-failures.tsv (record_failure greps `^pre-push: REFUSED`, which the rebase's `2>&1 | tee .wtd/rebase.out` captures).
a36ed084: check_overlays_agree compares each overlay's purity, decoded by decode_effects_override less the
consistent-overlay bit, with its Base method's of the same signature, and refuses a purity on any other method of `root`.
(A78E2, medium, D6, R1) Julia carries an effects claim in three places, and the check reads one: `sed -n 764,786p
base/expr.jl` of the julia pin gives the function-definition case `pushmeta!(lastex::Expr, form_purity_expr(override))`
(a Method's purity, read), the `@ccall` case `lastex.args[1] = GlobalRef(Base, Symbol("@ccall_effects"))` (the claim an
argument of the foreigncall), and the call-site case `Expr(:block, form_purity_expr(override), ..., Expr(:purity), :val)`,
whose region `sed -n 508,553p src/method.c` sets into the statements' ssaflags (`flag |= ... (1 << (NUM_IR_FLAGS+j))`,
`jl_array_uint32_set(li->ssaflags, j, flag)`), never into the Method's purity. So `Base.@assume_effects :nothrow
reject!(...)` written inside any src body passes `claims(m.purity) != none`, and it is A75S6's own hazard: a nothrow claim
deleting a rejection. Fix: the scan reads each WasmTarget method's lowered code beside its purity (the ssaflags bits from
NUM_IR_FLAGS on, julia.h:281, and each :foreigncall's effects argument), refusing any claim outside an overlay that keeps
its Base method's; plants: a call-site claim and an @assume_effects @ccall each refused. Owner: wt3-parity
(src/julia/parity.jl). 98390e9e: a method deleted after its entry is taken is refused, naming the reason. (A78S1, low, D17)
L208's text now says the no-frame refusal is "unplanted since no definition reaches it", where a plant reaches it as the
no-match one does, in the scratch module: `typeinf_frame` returns nothing when InferenceState does (Compiler/src/typeinfer.jl
:1118), which returns nothing when retrieve_code_info does (inferencestate.jl:603); `get_staged` swallows a generator that
throws (`sed -n 87,91p Compiler/src/utilities.jl` gives `try`, `return call_get_staged(...)`, `catch # user code might throw
errors – ignore them`, `return nothing`), and a generated-only method keeps no source (`sed -n 969,971p src/method.c` gives
`if (gen_only) {`, `m->source = NULL;`). src forbids @generated (construction.jl:279), which bars a src definition, not a
plant. Fix: a plant in rp, `@generated g(x::Int) = error()`, refused naming "no frame". Owner: wt3-parity
(test/parity_ratchet.jl). 0f92ada6: dev/cache_key.sh keys a cached verdict by the julia's commit, tagged commit, machine
and cache flags, the three checkouts' heads and each named file's path and blob id; one block, dev/progress_kinds.jl, reads
and writes the kinds; its citation resolves (`sed -n 4049p base/loading.jl` gives `@constprop :none function
stale_cachefile(modkey::PkgId, build_id::UInt128, modpath::String, cachefile::String;`). (A78E1, medium, D9) the key is
computed past a failed input and handed on. The file hashes run in a process substitution whose status nothing reads, and
the header in a brace group that `set -e` ends; measured on a copy of the script in a scratch repository, its julia line
replaced by `echo header` (src/a.jl, b.jl, c.jl committed): `bash dev/cache_key.sh src` gives `3a27d8b6...`; after `rm
src/a.jl` it prints `fatal: could not open 'src/a.jl' for reading` and `5114f837a44faa0f0d7e44bd11f8c7ef9134c9d0`, `exit=0`,
and after editing src/c.jl as well, `5114f837a44faa0f0d7e44bd11f8c7ef9134c9d0` again: every file after the missing one
leaves the key. With the header replaced by `false`, it prints `e69de29bb2d1d6434b8b29ae775ad8c2e48c5391` (the empty blob,
one key for every tree), `exit=1`, and a caller shaped as kinds_cache under `set -euo pipefail` (`kc() { local key;
key=$(bash dev/cache_key.sh src); echo "/d/$key.tsv"; }; X=$(kc)`) gets `/d/e69de29bb2d1d6434b8b29ae775ad8c2e48c5391.tsv`,
since bash runs a command substitution without errexit. A lane's tree with a tracked file removed and not yet staged, or
a julia that fails to start, reads another tree's kinds as a hit. Fix: cache_key.sh hashing the files with a status it
checks (the count of blob ids equal to the count of paths), the header's status checked, and kinds_cache refusing a
non-zero exit or a key that is not 40 hex, located; plants: a tracked file missing and a failing header each refused.
Owner: wt3-parity (dev/cache_key.sh, dev/src_progress.sh). (A78S2, low, D5, R1) the port keeps stale_cachefile's
comparison and drops its list: Base checks the includes the load itself recorded in the image's header, where cache_key.sh
checks the pathspecs its caller names by hand, so a file the kinds come to read is keyed only if a lane adds it there
(dev/skeleton.jl:26 reads dev/PARITY_MASTER.md, which no pathspec names; today it only guards the checkout's head); and the
lock's "an edit only to a pin" plant edits a text under src/, none moving a checkout's head, the input it adds. Fix:
WasmTarget's files read from its image's recorded includes, the readers' from what they open, and a plant moving a
checkout's head. Owner: wt3-parity. (A78E3, medium, D5, R2) wt-progress.tsv holds one row per ship, not per landing: `cut
-f2 .git/wt-progress.tsv | tail -5` gives `903a3332 16981666 3b1a4643 6732d4a6 0f92ada6`, where `.git/wt-landings.tsv` has
`20:36:46Z a36ed084`, `20:38:37Z 98390e9e` and `20:40:19Z 0f92ada6`, one ship's three pushes. dev/ship.sh:102 checks and
pushes each commit inside the rebase's `--exec` and writes the landings row there; :241 writes the progress row once,
after, from .wtd/ratchet.out, which each commit's check overwrites (dev/check.sh:109 `> .wtd/ratchet.out`); the comment at
:237 says "one row per landing". a36ed084, the one src commit of the range, has no count of its own. This is A76E3's and
A77E2's missing rows from the current ship.sh, not an older copy. Fix: the progress row written in the --exec beside the
landings row, from that commit's ratchet output. Owner: lead (dev/ship.sh).

stopgap in disguise: none new; A78S2 is a precedent ported without its source of the list.

precedent: dart's tests/language/identity/identical_test.dart, a main passing its literal through a call, for Bound;
decode_effects_override and the @assume_effects forms (base/expr.jl:764) for the overlay check, two of three read (A78E2);
typeinf_frame and get_staged (typeinfer.jl:1115, utilities.jl:83) for the no-frame refusal (A78S1); stale_cachefile
(loading.jl:4049) for the cache key, its recorded include list left out (A78S2).

Requirements: D5, D6, D9, D17; no lock fired inside its band.

R1 and R2. R1: each citation of the range is read at its pin, above, and resolves. 6732d4a6 reproduces the dart test's
shape. a36ed084 reads Julia's own decoding of a claim, of one of the three places Julia writes one (A78E2). 0f92ada6 ports
stale_cachefile's comparison without its recorded list (A78S2). R2: the latest row of `.git/wt-progress.tsv` (0f92ada6,
20:40:21Z) reads `3084 + 274 + 4 + 42 = 3404 of 3404; the kinds cache: hit (cc625125e91b)`: 3084 ported with a body, 32 of
them a dart body that throws, 274 Internal (never returning, by Julia's inference), 4 gaps (3 Unported or Unquarantined, 1
the @unported stub) and 42 DartAbstract, none counted ported; the sum is 3404, unchanged. a36ed084 changed src/julia, which
holds no dart-anchored definition, so the count could not move; it has no row of its own (A78E3). The hit was read in a
landing's clean scratch, where A78E1's missing file cannot arise.

Resolution: this entry lands alone, prose only, and fixes nothing. A75S6 leaves 1.K; A75E3, A76E1 and A76E2 leave 1.A6;
A77E3 stays on 1.L for its first half. A78E1, A78S1 and A78S2 are open on 1.A6; A78E2 on 1.K; A78E3 on 1.L. By owner: lead
A78E3, with A77E1, A77E2 and A77E3; wt3-parity A78E1, A78E2, A78S1 and A78S2, with A76E4, A76E5, A76E6 and A76S2;
wt3-memory A77S1, with A75S1 and A75S2; wt3-runtime A77S2, with A76S1, A73S3 and A67S1; wt3-latency A73E1; wt3-cgstubs2
A71S3.

## 2026-11-01 — audited through 4b171979 (0f92ada6..4b171979: dev/MARCH.md the lead's alone, a progress row per landed commit, the push rules on the push, the generator loaded from its image and its verdict kept per file, the load counted by its whole tree's instructions, D14 raised to 160 s by Dale's word)

The seventy-ninth audit, beside the work, covers the 7 commits of 0f92ada6..4b171979 that are not audit entries (826d8641,
entry 78): a054922a, 909e874f, 013beff4, b67274ee, ad31d8f6, 94dbbc61 and 4b171979, read here, under Dale's R1 and R2 as
standing sections. Every finding rests on one exact command, quoted. Standing items. No src change (`git diff --stat
0f92ada6..4b171979 -- src | tail -1` gives nothing); no exemption lands (`git diff 0f92ada6..4b171979 -- src | grep -cE
'^\+.*(Reshaped:|Fields with no Julia counterpart)'` gives 0), and no catch outside entry 78's prose (`git diff
0f92ada6..4b171979 | grep -nE '^\+.*catch'` gives two lines, both of dev/AUDIT.md). The debt list reads 387, unchanged
(`grep -v '^#' dev/quarantine_unpinned.txt | grep -c .`). Each commit names its clause (C10, C2, C10, C10, C10, C10, C10).
Earlier findings: A78E3 is fixed by 013beff4: for every first-parent head of 0f92ada6..origin/wt2, `grep -c "	$h	"` gives 1
in `.git/wt-landings.tsv` and 1 in `.git/wt-progress.tsv` (826d8641, a054922a, 909e874f, 013beff4, b67274ee, ad31d8f6,
94dbbc61, 4b171979, 19efb42b), b67274ee and ad31d8f6, one ship, each with a row of its own (23:09:28Z, 23:12:44Z). A77E3's
band half is fixed by 013beff4 (dev/ship.sh:52 reads `git show "origin/$MARCH:dev/check.sh"`); its port-class half stays
open (dev/ship.sh:188 runs `bash dev/src_progress.sh code` in the scratch at the lane's HEAD, before the rebase). A77E1 is
narrowed, not fixed: 013beff4 sets WT_SHIP_RULES on the pushes alone, but the hook still admits by that variable, `--no-verify`
still skips it, and the installed copy is still compared with nothing (`grep -n 'hooks/pre-push' dev/ship.sh` gives only
the comments at `17:` and `214:`). A77E2 stands (`ps aux | grep -c '[b]ash dev/autoship.sh'` gives 8). A78E1 now reaches a
second cache, L210's (below). A78E2, A78S1, A78S2, A77S1, A77S2, A75S1, A71S3, A73S3, A73E1, A76E4, A76S1, A68E3, A76S2,
A76E5, A76E6, A75S2, A71E2, A69E1, A68E2, A68S4, A72E1, A67E1 and A67S1, carried, not re-read. Findings A79E1 to A79E4 and
A79S1 to A79S5.

Area: builder — no change under src/wasm_builder.

Area: collection and planning — no change to the collection or the plan in src. 909e874f (test/src/dispatch_table.jl)
says why no admitted program collects a dynamic call shape; its citation holds: `grep -n 'verify_trim' src/julia/subset.jl`
gives `64:` (the quarantined `_verify_trim` over Compiler/src/verifytrim.jl) and `337:` (check_subset calling it).

Area: emission and diagnostics — no change to emission or to a diagnostic in src.

Area: enforcement and prose — a054922a: ship.sh refuses a lane, by worktree name, whose commits since the merge base touch
dev/MARCH.md. (A79S3, low, D6) the owner is a name, `case "$(basename "$lane")" in wt3-lead*) ;;` (dev/ship.sh:40-41), so
any worktree named wt3-lead<anything> passes, and the comment does not mark it a stopgap; the diff it reads is
`merge-base..HEAD` (:42), where the landing carries only the oldest SHIP_MAX commits (`start`, :75), so a seventh commit
touching the file refuses the six before it. Fix: the comment marks the STOPGAP and its end (a CODEOWNERS rule on origin's
wt2 ruleset); the diff read over `$base..$start`. Owner: lead (dev/ship.sh). 013beff4: the --exec writes
`$common/wt-ship/<lane>.landed.sh` and runs it after each push, writing that head's landings and progress rows, each once
per head, from the ratchet output its own check just wrote (dev/check.sh:117 writes .wtd/ratchet.out on every path that
reaches a push). To the lead's question: one row per landed head, as the table above reads; a head whose ratchet output has
no `· src:` line gets none, said on the ship's output alone (dev/ship.sh:119). (A79S2, low, D9) the retry cap reads the band
as `band + 0` (dev/ship.sh:52-53): when `git show origin/$MARCH:dev/check.sh` fails, the band is empty, reads 0, and every
D14 red in the last hour counts, a plausible default past a gap. Fix: an empty band refuses, naming the read that failed.
Owner: lead (dev/ship.sh).

b67274ee and ad31d8f6: dev/SkeletonImage includes dev/skeleton.jl in a package whose precompile workload runs the reader
and the generator's checks (dev/SkeletonImage/src/SkeletonImage.jl:11-18); L210 loads it through LOAD_PATH and keeps its
verdict in `.git/wt-skeleton-faults/` under dev/cache_key.sh's key over SKELETON_INPUTS (test/parity_ratchet.jl:469), each
in-scope file's diff under that key with its src file's content and the anchors touching it. (A79E1, high, D9, D5, R1) the
image keeps the tree it was built from. dev/skeleton.jl fills its tables lazily into module constants (`isempty(KERNEL) ||
return KERNEL`, :1000, from src/julia/kernel.jl; DART_BASE, :637, from src/julia/parity.jl; OUT_DEFINITIONS and OUT_TYPES,
:2307-2308, from dev/skeleton_scope.toml; KERNEL_USED, :878; SDK, :29) and evaluates `snake` from src/julia/parity.jl when it
loads (:629); the workload fills every table at precompile, the image serializes them, and none of those files is an
include of the image, so Base's staleness rule (loading.jl:4049) keeps it when they change. The image wt3-parity's check
built at 15:09 holds them: `LC_ALL=C grep -a -o '<s>' .worktrees/wt3-parity/.wtd/depot/compiled/v1.12/SkeletonImage/IVLXl_wkdCF.dylib
| wc -l` gives 5 for `deferred loading is out of scope` and 1 for `NirWorld`, where `grep -o` of the same strings in
dev/skeleton.jl gives 0 and 0: dev/skeleton_scope.toml's reasons and a KERNEL_TYPES value, baked. So after a commit that
edits only kernel.jl, parity.jl or the scope, every later load reads the old table and the old naming rule, and a row used
when the image was built stays in KERNEL_USED, so the stale-row fault (:1667) misses it silently. The precedent the
package names, PrecompileTools' @compile_workload, keeps compiled code, never state a later process must recompute. Fix:
the image keeps no tree state: SkeletonImage's `__init__` empties every lazily filled table and evaluates `snake` from the
loading tree, and `include_dependency` names src/julia/kernel.jl, src/julia/parity.jl and dev/skeleton_scope.toml, so
stale_cachefile tracks what the include reads; plant: an image built, a KERNEL_TYPES row and a scope line then edited, the
next load's verdict reading both. Owner: wt3-parity (dev/SkeletonImage, dev/skeleton.jl). (A79E2, medium, D5, D9) the
verdict's key leaves out files every verdict reads: SKELETON_INPUTS (test/parity_ratchet.jl:469) names dev/skeleton.jl,
dev/skeleton_scope.toml, dev/SkeletonImage, test/parity_ratchet.jl and dev/cache_key.sh, and the per-file key adds only the
file and its anchors, while generate() reads KERNEL_TYPES for every type it annotates (dev/skeleton.jl:875-877, src/julia/
kernel.jl) and names every definition by parity.jl's snake. A KERNEL_TYPES row moved from `planned:` to a type changes the
text written for each file naming it while every key stays, so a hit returns the old verdict, even with A79E1 fixed.
kernel.jl is no quiet file (`git log --oneline -5 -- src/julia/kernel.jl` gives five commits of 2026-10-28 and 29). It is
A78S2's hand-listed inputs, now at a lock, and dev/cache_key.sh's own header says each cache passes src/ among its
pathspecs; the plants edit only the generator and the lock. The key also inherits A78E1 (a tracked file missing reads exit 0
with a wrong key, which `readchomp` accepts). Fix: the key over every file the generator opens (A78S2's fix: dev/skeleton.jl
records each path it reads), until then src/julia/kernel.jl, src/julia/parity.jl and dev/PARITY_MASTER.md added to
SKELETON_INPUTS; plant: an edit only to KERNEL_TYPES gives a new shared key. Owner: wt3-parity (test/parity_ratchet.jl).

94dbbc61: dev/tree_instructions.jl runs the load and reads every process of its tree each 2 ms (proc_pid_rusage's
ri_instructions, the 30th field after ri_uuid; `info[2 + 29 + 1]` reads it, :25), and check.sh judges the load at
G/RATE_SRC. To the lead's question: it skews with core type, beyond its stated bound, both ways, and the judged term has no
bound. (A79E3, medium, D17, D9) the header says an efficiency core reads "up to about a fifth fewer" (:16-17), and the plant's
band is 30% (:66-68). Measured: `cat .git/wt-ship-failed/wt3-latency/tree_plant.out` (15:06) gives `the plant reads 9.64 G at
default QoS and 7.39 at background` (23% fewer); `cat .git/wt-ship-failed/wt3-codegen-b/tree_plant.out` (15:26:51) gives `the
tree at background QoS read 5.56 G, at default 9.71` (43% fewer), and `tail -6 .git/wt-ship-failures.tsv` shows that plant
refusing 7ae93d77 at 23:26:51Z, a red for where the scheduler put a process, not for the change; 94dbbc61's own load read
177.8 G at default and 191.3 G at background (8% more). dev/check.sh:205 judges the load as `$1 / r` alone, dropping the
CPU-s/2 floor that ps_of (:203) keeps for the ratchet and every shard, so a load placed on efficiency cores can read some 40%
low (33 s as about 19) and be admitted; and :190-191 still says the instructions are what "neither the core it ran on nor
another job's load moves". Fix: the load judged as ps_of judges a stage, the larger of G/RATE_SRC and half its CPU-s
(load.time's CPU-s hold the reaped tree); the plant keeps its counting claim (`normal > alone + 1`) and prints the QoS
comparison unjudged, or a band from a measured spread; the header's bound and check.sh:190-191 made true. Owner: wt3-latency
(dev/tree_instructions.jl), lead (dev/check.sh:205). (A79S1, low, D17) the load is judged at the shards' rate: 94dbbc61's
measure gives 177.8 G in 28.7 + 1.5 CPU-s, 5.9 G a CPU-s, so 33 s judged stand for about 30 of a performance core. Fix: the
load's own measured rate, or the 10% stated as its band. Owner: wt3-latency. (A79S4, low, D7, R1) the tree count names no
precedent for polling a process tree's counters; the closest production ones are psutil's `Process.children(recursive=True)`
sampling, the same walk, and perf stat's inherited counters, what it stands in for on macOS. Fix: the header names them.
Owner: wt3-latency.

4b171979: D14 red past 160 s. To the lead's question: Dale's words stand in the trailer (`Charter-change: C10 — Dale
2026-11-01: "Raise to 160 until the cuts"`), the ledger's D14 row and check.sh's comment, as his answer read less the option's
"(Recommended)" tag; the steps to 140 s and 120 s are the lead's reading of "until the cuts", not his words. (A79E4, medium,
D14, D5) the exit is stated three ways. dev/check.sh:212-215: 160 until the shards' first-compile cut and the ratchet's L210
cache land, then 140 until SHARDS is four, then 120. dev/CHARTER.md:138: "past 160 s until the shards' first compile and
the ratchet are cut, then 140 s", with no exit from 140 (the commit replaced the old "past 140 s until each shard's first
compile is cut"). dev/LEDGER.md:37: 140 "until the first-compile cut lands", 160 "until the shard and ratchet cuts land",
so by the ledger the first-compile cut ends both raises, back to 120, and by check.sh it reaches only 140. And the L210
cache named as pending had already landed (`git merge-base --is-ancestor ad31d8f6 4b171979 && echo ancestor` gives
`ancestor`), so "the ratchet cut" is either met or undefined. Fix: one schedule, check.sh's, written alike in C10 and the
ledger, its L210 condition marked met at ad31d8f6 or the further ratchet cut named; C10's exit from 140 restored. Owner: lead.

stopgap in disguise: A79S3, a refusal by worktree name not marked a stopgap.

precedent: Base.stale_cachefile (loading.jl:4049, its includes check at :4190 resolving the image per tree) and
PrecompileTools' @compile_workload for SkeletonImage, the state the workload leaves kept (A79E1); stale_cachefile for the
verdict key, its include list again a hand list (A79E2); /usr/bin/time -l's ri_instructions for the tree count, the
polling walk unnamed (A79S4); CODEOWNERS for dev/MARCH.md's owner, by name (A79S3).

Requirements: D5, D6, D7, D9, D14, D17; one check fired outside the change's doing (A79E3's plant on 7ae93d77).

R1 and R2. R1: the range ports no src definition. Each citation is read: loading.jl:4049 and :4190 resolve; verifytrim's
use in check_subset resolves (subset.jl:64, :337); SkeletonImage follows PrecompileTools without its rule on state (A79E1);
tree_instructions names no precedent (A79S4). R2: the latest rows of `.git/wt-progress.tsv` read `src: 3084 of 3404
anchored dart definitions ported` for b67274ee, ad31d8f6, 94dbbc61 and 4b171979, unchanged, as no commit of the range
touches src; 19efb42b, past the range, reads 3086. No stub is called complete here; A79E1 and A79E2 put at risk the lock
(L210) that keeps a stub regenerated from the pin, and so R2's count of what the generator writes.

Resolution: this entry lands alone, prose only, and fixes nothing. A78E3 leaves 1.L; A77E3 stays on 1.L for its port-class
half; A77E1 stays, narrowed. Open, their rows the lead's to write, since a054922a refuses a lane's edit of dev/MARCH.md:
A79E1 and A79E2 for row 1.A6; A79E3, A79E4, A79S1, A79S2, A79S3, A79S4 and A79S5 for row 1.L. (A79S5, low, D5) L154 holds an
audit entry red until each finding its Resolution leaves open sits in the dev/MARCH.md row it names (`grep -n 'which does
not hold it' test/parity_ratchet.jl` gives `1568:`), which a054922a forbids a lane to write: this entry's first check went red
on L154 with 8 such faults (`.git/wt-ship-failed/wt3-audit79/ratchet.out`), so an audit from a lane must name its rows in
words L154 does not read. Fix: L154 reads the lead's queue of rows to add, or the lead lands each audit's row with the
entry. Owner: lead (dev/ship.sh), wt3-parity (test/parity_ratchet.jl). By owner: lead A79E3 (check.sh:205), A79E4, A79S2,
A79S3 and A79S5, with A77E1, A77E2 and A77E3; wt3-parity A79E1 and A79E2, with
A78E1, A78E2, A78S1, A78S2, A76E4, A76E5, A76E6 and A76S2; wt3-latency A79E3 (tree_instructions.jl), A79S1 and A79S4, with
A73E1; wt3-memory A77S1, with A75S1 and A75S2; wt3-runtime A77S2, with A76S1, A73S3 and A67S1; wt3-cgstubs2 A71S3.

## 2026-11-01 — audited through 9c2d9848 (4b171979..9c2d9848: an open tuple the record of its arity, boxed by convertType; an Any host argument crossing by class; the load counted by an exit-time counter and judged at its own rate with a CPU-seconds floor; generateStaticIntrinsic's families and translateExpression inferred once; the generator's image emptied at load; a cache key refused past a failed input)

The eightieth audit, beside the work, covers the 13 commits of 4b171979..9c2d9848 that are not audit entries (c98bfcc5,
entry 79): 19efb42b, 08bf22f5, 261493b5, 5a6bec51, b150fc00, 1fd4ff21, f60e45a1, 7a2f804e, ebba5ad7, f8afd6e5, d0444541,
b5ab0feb and 9c2d9848, read here, under Dale's R1 and R2 as standing sections. Every finding rests on one exact command,
quoted. Standing items. src changes (`git diff --stat 4b171979..9c2d9848 -- src | tail -1` gives `13 files changed, 444
insertions(+), 200 deletions(-)`); no exemption lands (`git diff 4b171979..9c2d9848 -- src | grep -cE
'^\+.*(Reshaped:|Fields with no Julia counterpart)'` gives 1, getConcreteClassIdRange's Reshaped rewritten, the open tuple
type moved out of its "abstract tuple" case to the records it holds), and no silent catch (`git diff 4b171979..9c2d9848 |
grep -nE '^\+.*\bcatch\b'` gives four lines: two of entry 79's prose, two test captures of a RejectionError in
test/src/records.jl). The debt list reads 384, from 387 (`grep -v '^#' dev/quarantine_unpinned.txt | grep -c .`):
_meet_class!, class_instance_fields and nir_method_nargs pinned. Each commit names its clause in a `Charter:` line (C2, C3,
C10, C9, C10, C10, C10, C10, C10, C10, C10, C10, C0). Every head has one row in `.git/wt-progress.tsv`; src reads 3086 of
3404 from 19efb42b on, 3084 before. Earlier findings: A78E1 is fixed by 9c2d9848 (L208's plants: a tracked input missing
and a julia whose header fails, each refused). A79E1 and A79E2 are fixed by b5ab0feb (SkeletonImage's `__init__` calls
reset!, include_dependency names parity.jl, kernel.jl and the scope, SKELETON_INPUTS holds kernel.jl and parity.jl, each
planted); its residual is A80S4. A79E4, A79S2, A79S3 and A79S5 are fixed by ebba5ad7. A79S1 and A79S4 are fixed by
f8afd6e5 (RATE_LOAD, dev/check.sh:203; perf stat named, dev/tree_instructions.jl:23-26). A79E3 is narrowed by f8afd6e5,
not fixed: the floor is back and the plant judges counting alone, but the header's bound stands and the floor's own
residual is unstated (A80E1). A75S1 and A75S2 are fixed by 19efb42b (`grep -rn tuple_classes src | wc -l` gives 0), and
A73E1 by 7a2f804e (src/julia/nir.jl:827 names its MethodInstance through rejection_text). A67S1, A76S1 and A75S4 are
fixed by 08bf22f5, their row cleared by 5a6bec51. A77E2 stands (`ps aux | grep -c '[b]ash dev/autoship.sh'` gives 8; wt3-constants' loop wrote 12 CONFLICT rows naming
origin's landed heads from 23:23Z to 00:48Z, `awk -F'\t' '$1 >= "2026-11-01T23:20" && $2 == "wt3-constants"'
.git/wt-ship-failures.tsv | wc -l` giving 12).
A77E1, A77E3, A78E2, A78S1, A78S2, A77S1, A77S2, A71S3, A73S3, A76E4, A76E5, A76E6, A76S2, A68E3, A71E2, A69E1, A68E2,
A68S4, A72E1 and A67E1, carried, not re-read. Findings A80E1, A80E2 and A80S1 to A80S6.

Area: builder — no change under src/wasm_builder (`git diff --stat 4b171979..9c2d9848 -- src/wasm_builder` gives nothing).

Area: collection and planning — 19efb42b: the walk deletes the open-tuple product and meets, for every concrete tuple
class it holds, the record of its arity (src/julia/classes.jl:66-70), and for a literal or varargs tuple of open elements
the record of its fixed arity (_meet_tuple_record!, :76). (A80E2, medium, D11, D6) the record model is an algorithm with no
model, and it breaks the claim of the one model its walk cites. Its soundness rests on one representation invariant
every reader assumes, a value in a top-typed slot is a record and never a concrete tuple's own struct (types.jl:745 and
:760 test tuple members against records alone; class_info.jl:558-564 gives an open tuple type records alone), kept by hand
at four producers (translator.jl:1181 and :1225, intrinsics.jl:1081, constants.jl:492); a concrete tuple's struct is a
wasm subtype of the top struct, so a fifth producer that skips the box validates and answers `isa` false where native
answers true, the failure RecordModelCases' own comment names. `git show --stat 19efb42b | grep -c formal` gives 0;
`grep -rn 'formal(dev/formal/Coercion' src | wc -l` gives 0: dev/formal/Coercion.tla models the coercion funnel, its
tuple_build arm WT1's counterpart of this box (Coercion.tla:154), and anchors legacy's convert_type!, so WT2's
convert_type (translator.jl:1154) with its new arms cites none. And classes.jl:32 cites formal(dev/formal/ValueClasses.tla)
"nothing extra" (NothingExtra, ValueClasses.tla:205), while :68-70 meets a record for every concrete tuple whether or not
any reaches an open slot. Fix: the record arms modelled (Coercion.tla's tuple arms re-anchored at translator.jl
convert_type: a concrete tuple Tc, its record Rn; box Tc to top builds Rn, null kept; unbox top to Tc casts Rn; the claim
that a top slot never holds Tc; Broken variants a producer that leaves Tc in a top slot and a null boxed), and the walk's
pass either modelled in ValueClasses.tla's Required or narrowed to the tuples that meet an open slot. Owner: wt3-memory.

To the lead's question: yes. A concrete static type keeps its own class (translate_type maps only an open tuple type to
the top type, translator.jl:1002-1005); convertType boxes it into its arity's record where its reference flows into a
slot of another type and unboxes it where Julia narrows it back (translator.jl:1181-1224, :1225-1264), nothing kept the
null. dart's own record values are always their shape's class, every field `Object?` (record_class_generator.dart:280), so
the split is Julia's difference, stated in TupleRecord's docstring ("a tuple of a concrete static type keeps its own class
and only an open one is a record"), and the box's precedent is dart's value-type boxing in convertType
(translator.dart:1597), named at :1171-1175. === on two open tuples and typeof of one reject, located (RecordModelCases'
egal; the run_time_type arm). The range's tests run 26 native-differential cases of the model (round_trip 1:8 and
producers 1:5, two inputs each).

Area: emission and diagnostics — 7a2f804e and d0444541: the 15 builtin families take @nospecialize(f) with
@nospecializeinfer, and translate_expression @nospecialize(expected_type). To the lead's questions: @nospecialize is used as
Julia's compiler uses it (builtin_tfunction's @nospecialize(f), Compiler/src/tfuncs.jl:2759), a fix to WT's own compile cost
that every user pays, no dev flag (D15). (A80S2, low, D7) the @nospecializeinfer half names that same precedent, which
does not carry it: `grep -c '@nospecializeinfer' ~/.cache/wasmtarget/julia/Compiler/src/tfuncs.jl` gives 0 (the checkout at
6d172b0); Julia's compiler pairs the two on its lattice functions (`grep -n '@nospecializeinfer'
Compiler/src/typelattice.jl` gives `210:` assert_nested_slotwrapper and `218:` widenslotwrapper; abstractinterpretation.jl
:3904 widenreturn). Fix: src/intrinsics.jl:478-481 cites those. Owner: wt3-latency. (A80S3, low, AGENTS.md's rule, D12)
no case shows the cuts change no output: both say "Behavior is unchanged" with only instruction counts as evidence
(`git log -1 --format=%B d0444541 | grep -ci 'probe'` gives 0), and the gate runs no probe (`grep -n probe dev/check.sh`
gives only the comment at `194:`), where AGENTS.md has a pure restructuring byte-identical on the probes. By mechanism
none should: the two annotations change what is compiled and inferred, and a result moves only through a value read from
inference (an empty comprehension's eltype, Core.Compiler.return_type), of which `grep -n 'return_type\|promote_op'
src/intrinsics.jl src/code_generator.jl` finds only WT's own return_type(self); and the src shards' differential cases
passed at both landings. The counts were also taken at background QoS, which f8afd6e5 finds misreads by core (12.2 G and
6.2 G for one loop). Fix: test/probe_bytes.jl at 4b171979 and at d0444541, the identity quoted; the cut re-read at default
QoS. Owner: wt3-latency.

08bf22f5: an Any host argument crosses as the top reference type by its class (nir_foreign_param_type), a WasmArray or
WasmExternRef as its nullable wasm type; getFunction admits anyref only for an argument declared Any. (A80S5, low, D9) the
two throwWasmRefError rejections become Internal on the ground that "no Julia value is a dart:_wasm reference"
(src/kernel_nodes.jl:69-73, src/code_generator.jl:867-871), where the same commit crosses a WasmExternRef, one of
dart:_wasm's references, by class (translator.jl:1070); what no Julia program reaches is the two intrinsics that throw it,
WasmAnyRef.toObject and WasmFunction.fromFuncRef (intrinsics.dart:704, :2013), which `grep -rn 'WasmAnyRef\|WasmFuncRef'
src` finds only in intrinsics.jl:256's list of dart:_wasm classes WT does not have. Fix: each Internal names those two
intrinsics as the unreached callers. Owner: wt3-runtime (kernel_nodes.jl), wt3-cgstubs2 (code_generator.jl).

Area: enforcement and prose — the load measure. 261493b5 stops the plant refusing; b150fc00 floors the load by its CPU
seconds; 1fd4ff21 replaces the 2-ms poll with a library inserted by DYLD_INSERT_LIBRARIES whose destructor writes each
process's ri_instructions at exit, and drops the floor; f60e45a1 restores it; f8afd6e5 judges every stage at
max(G / its rate, CPU-s / ECORE_SLOWDOWN 1.4), the load at RATE_LOAD 11.6. To the lead's questions: RATE_LOAD is derived
from measurement, the lowest of three check readings, so the load reads high (check.sh:198-203; its sample, A80S1); the
residual of a stage split across core types is not stated anywhere (`grep -n 'split\|residual\|9%' dev/check.sh
dev/tree_instructions.jl` finds no such text). (A80E1, medium, D17, D9) the measure's stated bounds are false both ways.
Low: check.sh:210 says the CPU term reads "high there, never low", and :210-211 "Intent: never read low". A stage with a
share f of its work on efficiency cores reads G/rate x (1 - (1 - r) f) and CPU/1.4 reads (1 + (s - 1) f)/1.4; with the
commit's own r = 6.2/12.2 (a hash loop's counter on the two core types) and s = 1.56 (its measured minimum slowdown),
`awk` over f in 0..1 gives a worst reading of 0.843 of the true seconds at f = 0.32, 16% low (with r = 0.75, 11%), the
monitor's ~9% at a milder r. High: the load on efficiency cores is judged at max(182.3 / 11.6 = 15.7, 91.8 / 1.4 = 65.6)
= 65.6 s against 21.6 on performance cores (f8afd6e5's own 91.8 and 30.2 CPU-s), 44 s of critical path from where the
scheduler put the load, enough to turn a 120-s path red past 160: A79E3's red for placement, moved from the plant to the
band. And the header disagrees with both: dev/tree_instructions.jl:28-30 says a stage on efficiency cores "reads up to
about a third low ... the plant's band states it", where check.sh:206 quotes 12.2 against 6.2 G (half) and the plant
has had no band since f8afd6e5 (`grep -c BAND dev/tree_instructions.jl` gives 0). The kernel reports the split: `grep -n
'ri_pinstructions\|ri_user_ptime' $(xcrun --show-sdk-path)/usr/include/sys/resource.h` gives `406:` ri_user_ptime and
`408:` ri_pinstructions (rusage_info_v6). Fix: the exit-time library reads RUSAGE_INFO_V6 and writes each process's
P-core instructions and its P-core and total CPU time; each stage judged by its P-core instructions at its rate plus its
E-core seconds over the measured slowdown, so neither bound rests on placement; until then both residuals (16% low at
worst by the commit's numbers, up to s_E/1.4 high) stated beside ECORE_SLOWDOWN as its band, and tree_instructions.jl:28-30
made true. Owner: wt3-latency. (A80S1, low, D17) RATE_LOAD's band is prose and its samples mixed: "a load reading outside
11-13 G a CPU-s on a performance core re-measures it" (`grep -n '11-13' dev/check.sh` gives only the comment at `201:`), no
line reads it; two of its three samples, 08bf22f5 and 261493b5, were counted by the poll 1fd4ff21 replaced as reading low
(`git show 261493b5:dev/tree_instructions.jl | grep -n '^const POLL'` gives `18:`, and `git merge-base --is-ancestor
261493b5 1fd4ff21` holds); and 1fd4ff21's own exact count, 182.3 G in 26.0 + 2.1 CPU-s, is 6.5 G a CPU-s, outside the band,
with no core named. Fix: three exact-count readings with their core shares (A80E1's counters), and the check printing a
note when a load read wholly on performance cores falls outside the band. Owner: wt3-latency.

b5ab0feb and 9c2d9848: the generator's image empties its lazy tables at load and the key refuses a failed input, each
planted. (A80S4, low, D6, D5) the tables emptied are a hand list: LAZY_TABLES (dev/skeleton.jl:2317-2318) names the 14
tables the generator fills today, which `grep -cE '^const [A-Z_]+ *= *(Dict\{|Set\{|String\[\]|Pair\{)' dev/skeleton.jl` counts
as 14, and the plant fills only KERNEL_USED (test/parity_ratchet.jl, skeleton_negatives_missed); a table added later
and not listed is served from the image again, A79E1's fault, unrefused. Fix: a lazy table declared through one form that
registers it, LAZY_TABLES read from that registry, the plant adding a table outside the list; or lazy_tables_filled
walking every mutable container constant of the module. Owner: wt3-parity.

ebba5ad7: one D14 schedule in check.sh, C10 and the ledger; the retry cap refuses an unreadable band; the MARCH.md owner
rule marked a stopgap. (A80S6, low, D19) the charter now states the steps as Dale's, "past 160 s until the shards'
first-compile cut ..., then 140 s, then 120 s with four shards (Dale, 2026-11-01)" (dev/CHARTER.md:138), under the trailer
4b171979 already carried (`git log -1 --format=%B ebba5ad7 | grep '^Charter-change'` gives `Charter-change: C10 — Dale
2026-11-01: "Raise to 160 until the cuts"`), while entry 79 read the steps to 140 s and 120 s as the lead's reading of
"until the cuts"; the ledger now calls them "the steps of the option he chose", whose text no commit quotes, and check.sh's
D19 test (:163-165) admits any trailer of that form. Fix: the trailer quotes the option's text that holds the steps, or the
charter marks them the lead's schedule. Owner: lead.

stopgap in disguise: none new; b150fc00 and f60e45a1 mark their floor a STOPGAP, and f8afd6e5 makes the floor the rule,
its premise stated as evidence (A80E1 finds its bounds unstated).

precedent: dart's record class per shape (record_class_generator.dart:84, :246, :280) and _RecordType._checkInstance
(type.dart:585) for the record model, dart's value-type boxing in convertType (translator.dart:1597) for the box, the
coercion model unported (A80E2); builtin_tfunction's @nospecialize for the families, typelattice.jl's @nospecializeinfer
unnamed (A80S2); LD_PRELOAD interposition and perf stat's inherited counters for the tree count, rusage_info_v6's P-core
fields unused (A80E1); julia_to_native's boxed argument (ccall.cpp:528) for an Any host argument; include_dependency and
stale_cachefile for the image.

Requirements: D6, D7, D9, D11, D17, D19; one check fired outside the change's doing, the plant refusing 7ae93d77 at
23:26:51Z (A79E3's case, before 261493b5; since f8afd6e5 the plant judges only counting).

R1 and R2. R1: 19efb42b ports _generateClass and _generateFields with bodies and pins _meet_class! and
class_instance_fields to class_info.dart:420 and :539; the box is anchored at dart's convertType and the record check at
_checkRecordType; nir_foreign_param_type names julia_to_native and js_string.dart:858; each citation resolves (`sed -n
2759p ~/.cache/wasmtarget/julia/Compiler/src/tfuncs.jl` gives builtin_tfunction's signature; dart's intrinsics.dart:704
and :2013 hold the two throwWasmRefError calls). The bespoke pieces are dev tooling: the CPU-seconds floor names no
precedent for its rule (A80E1); the record arms of convert_type have no model (A80E2). R2: `.git/wt-progress.tsv` reads
`src: 3086 of 3404 anchored dart definitions ported with a body` from 19efb42b on, the two added being _generate_class and
_generate_fields, each a body that returns (a record class, its fields); 08bf22f5's two throwWasmRefError arms moved from
Unported to Internal and the count stayed 3086, so no rejection-only body is counted ported. No stub is called complete.

Resolution: this entry lands alone, prose only, and fixes nothing. A78E1, A79E1 and A79E2 leave 1.A6; A79E3, A79S1,
A79S4 and A73E1 leave 1.L; A75S1 and A75S2 leave 1.D. Open, their rows the lead's to write: A80E2 for row 1.C; A80S5 for
row 1.F; A80S4 for row 1.A6; A80E1, A80S1, A80S2, A80S3 and A80S6 for row 1.L. By owner: wt3-memory A80E2, with A77S1; wt3-latency A80E1, A80S1,
A80S2 and A80S3; wt3-parity A80S4, with A78E2, A78S1, A78S2, A76E4, A76E5, A76E6 and A76S2; wt3-runtime A80S5 (kernel_nodes.jl),
with A77S2 and A73S3; wt3-cgstubs2 A80S5 (code_generator.jl), with A71S3; lead A80S6, with A77E1, A77E2 and A77E3.

## 2026-11-01 — audited through 6baa3349 (9c2d9848..6baa3349: the split-core limit stated, D14 stepped back to 140 s, the floor's band stated both ways, every stage run under the exit-time counter reading rusage_info_v6, the counter's streams restored, a stage that reports nothing red)

The eighty-first audit, beside the work, covers the 7 commits of 9c2d9848..6baa3349 that are not audit entries (10cf7ec1,
entry 80): 26b5649f, c8d25950, 1f13996d, 3d8ab557, fd65f41e, f4ea3125 and 6baa3349, read here, under Dale's R1 and R2 as
standing sections. Every finding rests on one exact command, quoted. Standing items. No change under src/, test/ or
legacy/ (`git diff --stat 9c2d9848..6baa3349 -- src test legacy | tail -1` gives nothing); no silent catch (`git diff
9c2d9848..6baa3349 | grep -cE '^\+.*\bcatch\b'` gives 1, entry 80's own prose). The debt list reads 384 (`grep -v '^#'
dev/quarantine_unpinned.txt | grep -c .`). Each commit names its clause in a `Charter:` line (C10, C10, C0, C10, C10, C10,
C10, C10). Every head but one has its row in `.git/wt-progress.tsv`: fd65f41e has none (`grep -c fd65f41e
.git/wt-progress.tsv` gives 0, `.git/wt-landings.tsv` holds `fd65f41e	139`), since its check lost the ratchet's output
and ship.sh writes no row without a `· src:` line; src reads 3086 of 3404 throughout. Earlier findings: A80S6 is fixed by
3d8ab557 (its trailer quotes the option's text, "The four queued commits land now. The band drops to 140 and then 120 as
the shard and ratchet cuts land, the same exit as before."). A80E1 is narrowed by 1f13996d (both residuals stated) and
fd65f41e (each stage's split read), and A80E1 and A80S1 are fixed after this range by 89a5deb2 (its `Fixes:` line), whose
judged number A81E1 reaches. A80E2, A80S2, A80S3, A80S4 and A80S5 stand, untouched (`git diff --stat 9c2d9848..6baa3349`
names only dev/AUDIT.md, CHARTER.md, LEDGER.md, MARCH.md, check.sh and tree_instructions.jl). A77E1, A77E2, A77E3, A78E2,
A78S1, A78S2, A77S1, A77S2, A71S3, A73S3, A76E4, A76E5, A76E6, A76S2, A68E3, A71E2, A69E1, A68E2, A68S4, A72E1 and A67E1,
carried, not re-read; A77E2 still writes (wt3-constants' loop wrote 6 CONFLICT rows naming origin's landed heads from
00:48Z to 01:13Z, `awk -F'\t' '$1 >= "2026-11-02T00:40" && $2 == "wt3-constants"' .git/wt-ship-failures.tsv | wc -l`).
Findings A81E1 to A81E3 and A81S1 to A81S3.

Area: builder — no change under src/wasm_builder (`git diff --stat 9c2d9848..6baa3349 -- src/wasm_builder` gives nothing).

Area: collection and planning — no change under src/ (above).

Area: emission and diagnostics — no change under src/ (above). The check's own diagnostics: f4ea3125 hands the counted
command this process's streams (dev/tree_instructions.jl:88-91), which `run(...; wait = false)` had sent to devnull, so
fd65f41e's own check read `src tests  passed in 6 shards; 0 of 6 reported` and landed on exit statuses alone; 6baa3349
makes that red (dev/check.sh:170-175, :172 and :175: every shard's `^src ` summary row counted against SHARDS, the ratchet's `── charter`
block, which test/parity_ratchet.jl:3367 prints, required). Sound for the shards and the ratchet; the stage's counts are
the gap it leaves (A81E2).

Area: enforcement and prose — the band. To the lead's first question: yes. c8d25950 steps D14_RED from 160 to 140 (a
tightening) on cuts 1 and 2 of the shards' first compile (7a2f804e, d0444541: 348 -> 263 G) with the ratchet's L210 cache
(ad31d8f6) landed, d0444541's own check reading 131 s; the option Dale chose says "drops to 140 and then 120 as the shard and
ratchet cuts land, the same exit as before", and the exit before was SHARDS back to four (A68S4). The four texts agree:
`grep -n -o '140 s until four shards[^;]*' dev/check.sh` gives `6:140 s until four shards, Dale 2026-11-01`, dev/CHARTER.md:138
reads "red past 120 s, past 140 s until four shards", dev/LEDGER.md:37 "so red past 140 until four shards", and
check.sh:249 prints "red past ${D14_RED} s until four shards, then 120 s". (A81S1, low, D6, D20) the 120 step is prose
alone: `grep -n 'D14_RED\|^SHARDS' dev/check.sh` gives `129:SHARDS=6` and `248:D14_RED=140`, two literals nothing ties,
and `grep -c 'D14_RED' test/parity_ratchet.jl` gives 0; the commit that sets SHARDS=4 can keep 140 and every check stays
green past 120. Fix: D14_RED derived from SHARDS at the line that judges (140 while SHARDS > 4, else 120), the one source
of the step, the charter and ledger citing it. Owner: lead.

fd65f41e, f4ea3125: every stage runs under the counter. To the lead's second question: no, and the stated limits are
false. The library's destructor writes a process's counts only when that process loads the library and leaves by exit().
A copy of COUNTER_C taken from the head (`awk '/^const COUNTER_C = """/{f=1;next} f&&/^"""/{exit} f'
dev/tree_instructions.jl`), built by clang and run by a 30-line spawner in the audit's scratch that sets
DYLD_INSERT_LIBRARIES and WT_TREE_COUNT_DIR as tree_instructions.jl:91 does, sums the files and reads
getrusage(RUSAGE_CHILDREN), gives, for a node loop of 1e9 steps:
direct `reported processes 1 ... library: 61.48 G, 3.45 CPU-s; kernel RUSAGE_CHILDREN: 3.45 CPU-s`;
under `perl -e 'alarm 30; exec @ARGV'` (test/src/compile.jl:75's wrapper) `reported processes 0 ... library: 0.00 G, 0.00
CPU-s; kernel RUSAGE_CHILDREN: 3.56 CPU-s; status exit 0`; under `/bin/bash -c` `reported processes 0 ... 0.00 CPU-s;
kernel RUSAGE_CHILDREN: 3.89 CPU-s; status exit 0`; a node child SIGKILLed while its node parent exits 0 `reported
processes 1 ... library: 0.66 G, 0.08 CPU-s; kernel RUSAGE_CHILDREN: 4.62 CPU-s; status exit 0`; a C loop leaving by
_exit `reported processes 0 ... kernel RUSAGE_CHILDREN: 0.74 CPU-s; status exit 0`; `/usr/bin/git rev-list --count HEAD`
`reported processes 0`, /opt/homebrew/bin/git `reported processes 1`. The stages hold such processes: `grep -nE '`perl '
test/src/*.jl` finds four perl-wrapped node runs (compile.jl:75, :86, js_string.jl:84, js_runtime.jl:68) and two watchdogs,
and `grep -cE '`(ba)?sh ' test/parity_ratchet.jl` gives 12 shell runs, each with every process below it.

(A81E1, medium, D9, D17) fd65f41e replaced the kernel's whole-tree CPU seconds with the library's sum, so the judged
number drops every process that does not report. Before it, each stage ran under /usr/bin/time -l (`git show
9c2d9848:dev/check.sh | grep -c '/usr/bin/time -l -o'` gives 3), whose wait4 rusage holds every reaped descendant, as
tree_instructions.jl's own children_cpu (RUSAGE_CHILDREN) did; fd65f41e deletes both, and check.sh:227 and :235 read the
CPU term from .gi's third field, the library's sum, while check.sh:232-233 still said "its CPU seconds hold them all". The
floor existed for exactly the children the instruction term misses (A54E1: node, wasm-opt, the ratchet's git); a child
behind perl or bash, or killed, is now in neither term on any placement, and A80E1's stated 0.84 band assumed the CPU term
whole. 89a5deb2, after this range, judges every term from the library (`ps_of` reads `$2 / r + ($3 - $4)`) under "Intent:
never read low", so the same processes are missing from the whole judged number. Fix: tree_instructions.jl reads the
tree's CPU seconds from the kernel again (getrusage(RUSAGE_CHILDREN) around the command, as before fd65f41e), writes the
unreported remainder (kernel minus the library's sum) as a sixth field, and check.sh judges that remainder one for one as
seconds beside the split, printing it; the plant gains a perl-wrapped grandchild whose seconds the remainder must hold.
Owner: wt3-latency.

(A81E2, medium, D9) a tree that reports nothing reads 0 and passes. tree_instructions.jl:94 starts `local sums = zeros(4);
local root_g = 0.0` and :98 sets root_g only when a file bears the root's pid, so a root that never reports (a protected
binary, an exec into one, _exit) writes `0.0 0.0 0.0 0.0 0.0` and exits with the command's status 0 (the spawner's bash
and _exit runs above: `reported processes 0`, `status exit 0`); check.sh then judges that stage at 0 s, green. 6baa3349
refuses a lost summary; nothing refuses a lost count. Fix: tree_instructions.jl exits non-zero, naming the command, when
the root's pid wrote no file, and with A81E1's remainder the plant plants a bash-rooted tree that must refuse. Owner:
wt3-latency.

(A81E3, low, D17, D7) the counter's stated limits are false for the stages it now counts. tree_instructions.jl:22 says one
killed by a signal "writes none, and the command fails": true of the root alone, where the SIGKILLed child above left
`status exit 0` with 0.08 of 4.62 CPU-s counted; :23-24 says a protected binary and what it starts cost "a few
milliseconds in the load", written when only the load ran under the counter, where the ratchet's 12 shell runs and the
shards' perl-wrapped node runs now run under it, unmeasured. Fix: the header states each class (a non-root killed by a
signal, a process leaving by _exit, a protected binary and its descendants) and the remainder A81E1 measures, the
"few milliseconds" replaced by that measure. Owner: wt3-latency.

To the lead's third question: inside the range no new low reading on placement beyond A80E1's stated 0.84 (fd65f41e keeps
the formula and prints the split unjudged), but A81E1's dropped processes read low on every placement, the binding CPU term
missing them whole; the measurement itself is right where it reports (the spawner's library CPU equals the kernel's, 3.45
and 3.45, 0.60 and 0.60, and at background QoS `taskpolicy -b` five runs of the C loop read 0.000-0.001 P-core seconds of
7.13-9.65, the plant's known split). Prose fixed after the range: check.sh's "(/usr/bin/time -l)" (:197-198), "taskpolicy
does not hold work on the efficiency cores" (:224, against the plant's new assertion) and the header's "measured slowdown
printed" (tree_instructions.jl:8-9, the ratio deleted by fd65f41e) are gone at 89a5deb2.

3d8ab557: the plan's rows. (A81S2, low, D25, C9) two rows carry audit 80's findings outside their cells: `grep -o '| a
hand-edited stub fails |.\{0,60\}' dev/MARCH.md` gives `| a hand-edited stub fails |; audit 80, open: A80S4 LAZY_TABLES a
hand list, the plant f`, and `grep -o 'cited in place of this row |.\{0,40\}' dev/MARCH.md` gives `cited in place of this
row |; audit 80, open: A80E1 the floor max(G/`; the text sits after each row's closing pipe, a sixth cell a rendered table
drops, so 1.A6's A80S4 and 1.L's A80E1, A80S1, A80S2, A80S3 are read only by L154's whole-line regex. Fix: each moved inside
its row's Work cell, before the Exit cell. Owner: lead.

1f13996d and fd65f41e: the partial fixes. (A81S3, low, R2, D9) a partial fix closes its finding for L154: 1f13996d carries
`Fixes: A80E1 (interim: both residuals stated)` and fd65f41e `Fixes: A80E1 (step one: each stage's split read and
printed)`, and audit_fixes (test/parity_ratchet.jl, findings_off_row_here) takes every ID on a `Fixes:` line, so audit 80's
A80E1 was free to leave its row at 1f13996d while its exit had not landed; the lead kept it there by hand. Fix: a partial
fix's trailer a distinct word (`Narrows:`), L154 reading only `Fixes:` and dev/hooks/commit-msg refusing a parenthetical on a
`Fixes:` line. Owner: wt3-parity.

stopgap in disguise: none new; 1f13996d marks the floor a STOPGAP with its exit, and fd65f41e prints the split unjudged
until the exit lands (89a5deb2).

precedent: LD_PRELOAD interposition and perf stat's inherited counters for the tree count (tree_instructions.jl:27-30);
perf stat inherits its counters into every child the kernel creates, killed or not, where an exit-time destructor reports
only a process that loads it and calls exit(), the difference A81E1 and A81E3 name; rusage_info_v6's P-core fields
(sys/resource.h:406-408) for the split.

Requirements: D6, D9, D17, D19 (3d8ab557's trailer quotes the option, closing A80S6), D25; one check passed outside its
doing, fd65f41e's own, green on `0 of 6 reported` (closed by 6baa3349).

R1 and R2. R1: no src change in the range; the dev tooling's one new mechanism, the rusage_info_v6 read, is the kernel's
own counter, its precedent named, and its reach short of perf stat's (A81E1). R2: `.git/wt-progress.tsv` reads `src: 3086
of 3404 anchored dart definitions ported with a body` at every row of the range; no body changed, so no stub is called
complete. A partial fix called a fix is A81S3.

Resolution: this entry lands alone, prose only, and fixes nothing. A80S6 leaves row 1.L, fixed by 3d8ab557; A80E1 and
A80S1 leave row 1.L, fixed by 89a5deb2. Open, their rows the lead's to write: A81E1, A81E2, A81E3, A81S1 and A81S3 for row
1.L; A81S2 for row 1.L and row 1.A6, as the rows' own repair. By owner: wt3-latency A81E1, A81E2 and A81E3, with A80S2 and
A80S3; wt3-parity A81S3, with A80S4, A78E2, A78S1, A78S2, A76E4, A76E5, A76E6 and A76S2; lead A81S1 and A81S2, with A77E1,
A77E2 and A77E3.

## 2026-11-01 — audited through 4ad7e0a1 (6baa3349..4ad7e0a1, after entry 81: D14_RED tied to SHARDS, a call-site effects claim refused, the no-frame plant, the kernel's whole-tree CPU back beside the reported, throwWasmRefError's reason, === over an open slot by a ported jl_egal; with 89a5deb2 and 81427cbd, _virtualCall, read here)

The eighty-second audit, beside the work, covers the 8 commits of 6baa3349..4ad7e0a1 that are not audit entries
(5b9ada65, entry 81): 89a5deb2 and 81427cbd, which landed before entry 81 and no range held, and a53b3c0c, 61a68809,
9c971f08, a1c1f1d5, 1dad244a and 4ad7e0a1, read here under Dale's R1 and R2 as standing sections. Every finding rests on one exact command, quoted.
Standing items. Each commit names its clause in a `Charter:` line (89a5deb2 C10, 81427cbd C2, a53b3c0c C10, 61a68809 C2,
9c971f08 C2, a1c1f1d5 C10, 1dad244a C6, 4ad7e0a1 C3). No silent catch: `git diff 5b9ada65..4ad7e0a1 | grep -cE
'^\+.*\bcatch\b'` gives 2 (89a5deb2 and 81427cbd add none), both plants in test/parity_ratchet.jl that rethrow or test what they catch. The debt list reads
382 (`grep -v '^#' dev/quarantine_unpinned.txt | grep -c .`), two fewer, RUNTIME_DEMANDS and RUNTIME_ENTRY_POINTS pinned
by 4ad7e0a1 (A82S1). src reads 3086 of 3404 at 89a5deb2 and 3087 from 81427cbd on (`.git/wt-progress.tsv`), the one step
_virtualCall's body, its stub count 1 -> 0. Earlier findings: A81E1, A81E2 and A81E3 are fixed by a1c1f1d5; A81S1 and
A81S2 by a53b3c0c; A78E2 by 61a68809; A78S1 by 9c971f08; A80S5 by 1dad244a only in half (A82S5); A71S3's text is written
by 81427cbd (code_generator.jl's visitAsExpression comment cites codegen.cpp:6384's &skip and says WasmTarget differs) with
no `Fixes:` line. A80E2, A80S2, A80S3, A80S4, A81S3, A77E1, A77E2, A77E3, A78S2, A73S3, A76E4, A76E5, A76E6, A76S2, A68E3,
A71E2, A69E1, A68E2, A68S4, A72E1, A67E1 and A64R1, carried, not re-read. Findings A82E1 and A82S1 to A82S7.

Area: builder — no change under src/wasm_builder (`git diff --stat 5b9ada65..4ad7e0a1 -- src/wasm_builder` gives
nothing).

Area: collection and planning — 4ad7e0a1 keeps jl_egal in the closed world by a RUNTIME_ENTRY_POINTS row whose demand is
`:egal` (`grep -n ':egal => _compares_by_egal' src/julia/subset.jl` gives `289:    :egal => _compares_by_egal,`).
_compares_by_egal (subset.jl:261) decides, from Julia's argextype, which `===` the intrinsifier compares inline. (A82S1,
medium, R1, D5, D7) that decision is now written three times: the identical arm's own cases (intrinsics.jl:1227-1300, the
`typeintersect(first_type, second_type) === Union{}` test at :1295), the code generator's EqualsNull test
(`code_generator.jl:908: equals_null() = f === Core.:(===) && length(c.ar…`), and the predicate, each hand-kept to the
others, the predicate's comment saying its over-approximation "keeps jl_egal unused, never missing". It is A64R1's class
(RUNTIME_DEMANDS' predicates bespoke, row 1.C), one row more, as A73S3 was. And the same commit takes both tables off the
exact debt list by pinning: `sed -n 278p src/julia/subset.jl` begins `@quarantine "julia/src/codegen.cpp:4064
emit_builtin_call lowers each builtin, calling the runtime where one raises; a runtime root is demanded by the builtin or
intrinsic whose raise it lowers"`. emit_builtin_call (`sed -n 4064,4068p src/codegen.cpp` at the julia pin gives `static
bool emit_builtin_call(jl_codectx_t &ctx, jl_cgval_t *ret, jl_value_t *f, … // returns true if the call has been
handled`) lowers a call; it decides no root, Julia linking its whole runtime, and the reason does not say how WasmTarget
differs (D7). RUNTIME_ENTRY_POINTS' docstring gains `:egal` and still lacks `:typeassert` (A73S3). Fix: the inline
decision is one function the identical arm and the predicate both call (D5); until A64R1's roots land, row 1.C's A64R1
names `:egal`; each of the two reasons states Julia's differing answer (libjulia linked whole, no demand). Owner:
wt3-memory (the predicate and the arm), wt3-runtime (the roots, A64R1).

81427cbd: _virtualCall. To the lead's second question: yes, a 1:1 port. Read beside `git show
898a1e4b:pkg/dart2wasm/lib/code_generator.dart | sed -n 2028,2125p`, code_generator.jl:1631-1695 takes dart's steps in
dart's order: the getter's unchecked-entry assert, selectorForTarget, the signature and entry name, the name check, the
receiver pushed, targets' allTargetRanges and staticDispatchRanges, noTarget / directCall / callPolymorphicDispatcher as
dart computes them, the unreachable call, the direct call through getFunctionEntry, signatureForDirectCall and
paramInfoForDirectCall, the receiver local and its non-nullable assert, loadClassId before the polymorphic dispatcher,
callDispatchTable with the interface target, then synthesizeNullReturnValue and synthesizeNoReturn with their asserts;
dart's `node.location` is the enclosing member. visitInstanceSet's virtual arm is dart's (:2451-2475: the temp, the drop of
the setter's null). paramInfoForDirectCall's instance arm loops `_selector_info` for the selector containing the target
(translator.jl:1430) where dart reads selectorForTarget then containsTarget; the result is the same while a target lies in
one selector, as signatureForDirectCall's port already loops (:1400). (A82S2, medium, D5) the classes a receiver admits are
read again: `grep -n 'info.cls <: cls\|c <: receiver\|isconcretetype(c) &&' src/*.jl src/julia/*.jl` gives
`class_info.jl:573` (get_concrete_class_id_range, the one reading A71S1 ruled), `code_generator.jl:1784` and `:1894` (each a
scan of `translator.classes[]` with `!class_is_abstract(info.cls) && info.cls <: cls`) and `classes.jl:672`
(field_selector_calls' own list); the selector's name comes from the visitors' list at the call and from
field_selector_calls' at build, and a disagreement rejects Internal at selector_for_target ("no selector for the field").
Fix: one reading of a type's admitted classes, from get_concrete_class_id_range, called by field_selector_calls and both
visitors, the two scans deleted. Owner: wt3-cgstubs2 (code_generator.jl), wt3-memory (classes.jl). (A82S3, low, D6) the
interface target is a ClassField no class holds: `grep -n 'FieldReference(ClassField(class_for_type' src/code_generator.jl`
gives :1784 and :1894, each `ClassField(class_for_type(...), 0, <name>, Any, ...)`, index 0 (a primitive class's `value`,
`sed -n 309p src/julia/classes.jl`: `ClassField(c, 0, "value", c, false)`) and type Any, read only for its name and kind
(dispatch_table.jl:320-323); any reader of its index or type, field_index's Dict among them, would read a field that is not
there. Fix: a Reference variant naming the selector (the receiver's type, the field's name, the kind), so no fabricated field
is writable. Owner: wt3-cgstubs2. (A82S7, low, D12) the direct setter path is untested: test/src/code_generator_sub.jl's
VirtualCases hold a direct read (`154:struct D1 <: T; v::Int; end`, one class) and writes over two classes (`160:mutable
struct M1 <: U` and `161:mutable struct M2 <: U`), so directCall's setter branch, then the visitor's drop of the null
`call` synthesizes, runs in no case. Fix: a case with one mutable class under its abstract type, setfield! on it, run
against native. Owner: wt3-tests2.

Area: emission and diagnostics — 4ad7e0a1: jl_egal. To the lead's first question: a faithful port in its structure, one
departure sound and one not. Read against the julia pin: jl_egal_ (julia.h:1885: `a == b`, then `jl_typetagof` apart, then
jl_egal__unboxed_) is the arm's ref.eq, null and class-id tests; jl_egal__unboxed_ (:1874) answers a mutable class 0
(egal_by_identity); jl_egal__bitstag and compare_fields (builtins.c:243, :100) are the per-class switch, a field of bits by
its bits (a float reinterpreted, bits_equal), a pointer field by jl_egal again, a String's bytes and a SimpleVector's
elements by length and elements (memcmp, compare_svec :87); emit_f_is's exhaustive test (`jl_type_intersection(rt1, rt2) ==
jl_bottom_type`, codegen.cpp:3607) is the identical arm's disjoint answer; emit_box_compare (:3379) the boxed call. The
kinds answer by reference, sound only while each type is one canonical constant (A68S3), as the inline arm already relies.
The boxed Bool: sound. Julia answers Bool by its tag because its two Bools are canonical, so `a == b` failed means two
values; WasmTarget's boxes are not canonical, and comparing the i32 gives Julia's answer on every pair. The host
reference: unsound. (A82E1, medium, D3, D9) a class holding an externref answers not egal past the reference test:
`sed -n 1459,1461p src/intrinsics.jl` gives `if Base.iskindtype(cls) || egal_by_identity(cls) || any(f ->
host(info.struct_.fields[t.field_index[f] + 1].type), fields)` / `WasmBuilder.i32_const(b, 0)`, host being any reference
not under eqref (:1449). Julia's WasmExternRef is bits (`grep -n 'primitive type WasmExternRef' src/julia/wasm_array.jl`
gives line 209, `primitive type WasmExternRef <: Any 64`), so jl_egal compares its bits, and one host reference boxed twice
(two stores of one unboxed value into Any slots) is egal in Julia and not in WasmTarget: a plausible false past a gap. The
cited precedent does not fit: dart's identical answers false for a class it does not compare by value because dart's
identity is by reference for every such class; dart's answer for two host references is
`sdk/lib/_internal/wasm/js_common/js_helper.dart:151` (`git show 898a1e4b:… | sed -n 151,152p` gives `bool
areEqualInJS(WasmExternRef? l, WasmExternRef? r) =>` / `JS<bool>("(l, r) => l === r", l, r);`), which JSValue's `==`
calls (:42-43). The differential cannot see it (native Julia runs no host), and `grep -c WasmExternRef test/src/records.jl`
gives 0. Fix: areEqualInJS ported into the runtime (an inline-JS port beside Runtime's others) and an externref field
compared by it; until then the arm rejects, located, rather than answering. Owner: wt3-memory (the arm), wt3-runtime (the
port). (A82S4, low, D9) the arm's own rejection names wasm_egal, not a statement: `sed -n 1330p src/intrinsics.jl` gives
`local at = "$(code_gen.enclosing_member): Julia's jl_egal"`, and the arm is compiled as wasm_egal's body, so a class of
the closed world holding a wasm type no arm compares (:1444's Unquarantined) rejects every program with an open `===`,
naming none of its `===` statements. Fix: the rejection names the first `===` statement that demanded jl_egal (the demand
already finds it). Owner: wt3-memory.

1dad244a: throwWasmRefError. The new reason is true (`git grep -n throwWasmRefError 898a1e4b -- pkg/dart2wasm/lib` gives
the definition :655, its call :658, intrinsics.dart:704 and :2013, kernel_nodes.dart:645). (A82S5, low, R2, D9) its
`Fixes: A80S5` closes a finding half fixed: A80S5 named two reasons (kernel_nodes.jl and code_generator.jl), the commit says
"kernel_nodes.jl's half is wt3-runtime's", and `sed -n 73p src/kernel_nodes.jl` still says `… and no Julia value is a
dart:_wasm reference"`, the false ground A80S5 named; L154 reads A80S5 as closed. A81S3's class (a fix trailer on a
partial fix). Fix: kernel_nodes.jl:73's reason names the two intrinsics; A82S5 carries the half. Owner: wt3-runtime.

Area: enforcement and prose — a1c1f1d5, to the lead's third question: yes, for every process the tree waits for, and the
refusal leaves no 0-s green. tree_instructions.jl:95-99 and :106-113 read getrusage(RUSAGE_CHILDREN) around the command (the struct's
two timevals, buf[1..4], RUSAGE_CHILDREN = -1, as macOS lays them), write `max(0, kernel - reported)` as the sixth field,
and check.sh:224-229 judge it one for one in `ps_of`, `cpu` and the printed split. A process that never reports (perl,
bash, a killed child, _exit) is in the kernel's sum once its parent reaps it; the header states the one escape, a
descendant re-parented before it exits (the watchdogs, test/src/dart_tests.jl:1200, sleep). The root that reports nothing
returns 70 before writing the .gi (tree_instructions.jl:175), and every stage's non-zero exit is red before any .gi is
read (check.sh:113 the load, :151-157 the ratchet, :169 the shards), so no stale or zero count is judged. The plant plants
both (a perl-wrapped grandchild, a bash-rooted command). a53b3c0c: (A82S6, low, D6) the tie of D14_RED to SHARDS is
checked after every stage has run: `grep -n 'SHARDS > 4 ? 140\|^SHARDS=' dev/check.sh` gives `129:SHARDS=6` and `248:[ $((
SHARDS > 4 ? 140 : 120 )) -eq $D14_RED ] || …`, so a mismatched commit spends the whole check before red, and the tie is a
check over two literals (a stopgap) not marked as one. Fix: the tie moves above the stages, marked STOPGAP with its exit (one
value ship.sh and the band both read). Owner: lead. 61a68809 reads both forms Base writes (`sed -n 768,786p base/expr.jl`
at the pin: an @ccall rewritten to @ccall_effects, a call site's `Expr(:purity)` region), a generated method skipped there
being refused already (construction.jl:279). 9c971f08's plant reaches the refusal it names.

stopgap in disguise: A82S1's pins, a reason citing a lowering function for a root rule Julia does not have; A82S6's tie.

precedent: julia.h:1874-1895 jl_egal_ and jl_egal__unboxed_, builtins.c:87-300 compare_svec, compare_fields and
jl_egal__bitstag, codegen.cpp:3379 emit_box_compare and :3566 emit_f_is, at the julia pin, for jl_egal; dart's
js_helper.dart:151 areEqualInJS for a host reference (A82E1); code_generator.dart:2028 _virtualCall, :2434 visitInstanceSet,
translator.dart:1896 paramInfoForDirectCall; getrusage(RUSAGE_CHILDREN) for the tree's CPU.

Requirements: D3 and D9 (A82E1), D5 (A82S1, A82S2), D6 (A82S3, A82S6), D7 (A82S1), D9 (A82S4, A82S5), D11 (no model
touched; jl_egal's switch has no TLA+ model, an algorithm over a closed set of classes the differential reads), D12
(A82S7), D14 and D17 (a1c1f1d5's band stated: half the grandchild's seconds and a tenth of a second).

R1 and R2. R1: _virtualCall is dart's, line for line; jl_egal is Julia's runtime, ported by line, with dart's identical as
the precedent for an intrinsified runtime function; its host-reference arm is the one piece answered without a source
(A82E1), and its demand is A64R1's bespoke class (A82S1). R2: _virtualCall's stub became a body (3086 -> 3087, 1 -> 0
@unported stubs); 1dad244a's rejection stays Internal, counted with the 273 that never return, not ported; a half fix
called a fix is A82S5.

Resolution: this entry lands alone, prose only, and fixes nothing. A81E1, A81E2, A81E3, A81S1 and A81S2 leave row 1.L,
fixed by a1c1f1d5 and a53b3c0c; A78E2 leaves row 1.K, fixed by 61a68809; A78S1 leaves row 1.A6, fixed by 9c971f08; A80S5
leaves row 1.F, its open half carried as A82S5; A71S3 may leave row 1.D, its text written by 81427cbd. Open, their rows
the lead's to write: A82E1, A82S2, A82S3, A82S4 and A82S7 for row 1.D; A82S1 for row 1.C, beside A64R1; A82S5 for row
1.F; A82S6 for row 1.L. By owner: wt3-memory A82E1, A82S1 and A82S4, with A82S2's classes.jl half; wt3-runtime A82S5, A82E1's
areEqualInJS port and A82S1's roots (A64R1); wt3-cgstubs2 A82S2 and A82S3; wt3-tests2 A82S7; lead A82S6.

## 2026-11-01 — audited through d84934e0 (4ad7e0a1..d84934e0: the ratchet's cuts and lazy tables, a non-dominated value's defaultable local, string(::Int), every non-const runtime binding refused under dynamic calls, the tuple record modeled, CPU-second limits, Fixes: IDs alone, the band tie moved, an undefined isbits field's zero bits, the runtime's roots read from dart's pragmas, an inline JS site named where written, muladd_float, have_fma, fpiseq and bswap_int)

The eighty-third audit, beside the work, covers the 15 commits of 4ad7e0a1..d84934e0 that are not audit entries
(0d42a2bc, entry 82): d33e14e7, 96a9d6af, bd80a2f3, a2324b37, f0d77945, ada7613a, 53a91cd0, 4f67a2d4, b576744e, c30ce7a4,
1322a4ec, 4651ec94, 5264ac7e, bdd08864 and d84934e0, read under Dale's R1 and R2 as standing sections. Every finding rests on one exact command, quoted.
Standing items. Each commit names its clause in a `Charter:` line (d33e14e7 C0, 96a9d6af C0, bd80a2f3 C10, a2324b37 C7,
f0d77945 C3, ada7613a C6, 53a91cd0 C8, 4f67a2d4 C10, b576744e C0, c30ce7a4 C10, 1322a4ec C6, 4651ec94 C6, 5264ac7e C2,
bdd08864 C3, d84934e0 C3). No silent catch: `git diff 4ad7e0a1..d84934e0 | grep -cE '^\+.*\bcatch\b'` gives 6, two in
entry 82's own prose, two inside compiled test programs (test/src/code_generator_control.jl's UndefSlotCases, which test
the UndefRefError they catch), test/dart_limit.jl's `_dart_limited` (moved, it rethrows all but an InterruptException) and
test/src/globals.jl's, which tests what it catches. The debt list reads 372 (`grep -v '^#' dev/quarantine_unpinned.txt |
grep -c .`), ten fewer: nine lines 4651ec94 deletes with RUNTIME_ENTRY_POINTS and RUNTIME_DEMANDS, PATCH_FILES pinned by
bdd08864. src reads 3087 of 3404 at every commit of the range (`.git/wt-progress.tsv`, d33e14e7 to d84934e0): no dart
definition gained a body; the range's src work is Julia-only breadth (four intrinsics, two overlays, the roots). Earlier
findings: A80S4 is fixed by bd80a2f3; A81S3 by b576744e; A82S6 by c30ce7a4, its claim half true (A83S7); A64R1 and
A73S3 by 4651ec94, jl_egal's demand, A64R1's class, standing as A82S1 (A83S1); A77S2 by 5264ac7e (A83S6 its residue).
A80E2 is answered by 53a91cd0 and A77S1 narrowed by ada7613a, neither with a `Fixes:` line, so both stay open (A83E1 sits
in A80E2's model; A77S1's rule is the conservative stand-in, not verify_typeinf_trim's enumeration). A82E1, A82S1 to A82S5,
A82S7, A80S2, A80S3, A77E1, A77E2, A77E3, A78S2, A76E4, A76E5, A76E6, A76S2, A68E3, A71E2, A69E1, A68E2, A68S4, A72E1 and
A67E1, carried, not re-read. Findings A83E1 and A83S1 to A83S10.

Area: builder — no change under src/wasm_builder (`git diff --stat 4ad7e0a1..d84934e0 -- src/wasm_builder` gives
nothing).

Area: collection and planning — 4651ec94: the runtime's roots. To the lead's question: the procedures are exactly dart's,
with no hand list of roots, and every world pays for them; one demand predicate is left. RUNTIME_ROOTS
(src/julia/packages.jl:18-29) is generated by dev/skeleton.jl roots_block (:2132) from each Runtime port whose anchored
dart declaration carries wasm:entry-point, read by the reader at the pin, and each rtutils.jl definition declared
`::Union{}`. Read at the dart pin (`grep -n -A2 "wasm:entry-point"` over the five ported files): errors_patch.dart:17-19
(_throwWithCurrentStackTrace), :75-76 (_throwAsCheckError) and stack_trace_patch.dart:13-15 (StackTrace.current) carry it
and are the three Runtime roots; errors_patch.dart:39-40 (_throw) carries wasm:intrinsic and is not one; the other
anchors (js_string.dart:151, :171 and :858, print_patch.dart:8, embedder.dart:238) carry none. Julia's seven raisers are
rtutils.jl:9-43, throw_method_error now among them. check_subset queues every root beside the entry (subset.jl:367) and
check_runtime_roots refuses a root of no function or of two methods at load; KernelNodes.throwAsCheckError is ported
(kernel_nodes.jl, anchored at kernel_nodes.dart:630) and read by the as checker, A73S3's fix. The cost, the commit's own
probe: every world holds 14 bodies (f's held 1), 1.7 MB allocated per compile against 0.5 MB, and a fresh process's first
compile 128.7 s against 146.1 s, as dart's modules carry each entry point. (A83S1, medium, D5, R1) the demand predicates
are not deleted: the message says "RUNTIME_ENTRY_POINTS, RUNTIME_DEMANDS, _demanded and the IR-form predicates
(_calls_builtin, _ir_value, …) are deleted", and `git show 4651ec94:src/julia/subset.jl | grep -n 'function
_demanded\|function _calls_builtin\|_ir_value(x) =\|_demanded(codeinfos'` gives `176:@quarantine … _ir_value(x) =`,
`180:… function _calls_builtin(…`, `212:… function _demanded(…` and `374:    if _demanded(codeinfos,
_compares_by_egal)`: jl_egal is still queued by a CodeInfo scan, the third copy of the inline decision (A82S1), now the
one root outside the generated list. The commit roots Julia's raisers because "every Julia process links" libjulia, and
jl_egal (rtutils.jl:51) is libjulia's too; the rule reads the return annotation, so jl_egal, returning Bool, is left to
the predicate. And types.jl:917 cites `julia/src/subtype.c:1419` for the Type{X} arm, the head of `subtype`; the arm is
:1550-1558 (`return jl_typeof(tp0) == (jl_value_t*)yd;` at :1558). Fix: jl_egal rooted as the raisers are, Julia's
runtime functions (rtutils.jl:9-62) in one file the generator roots whole, apart from rtutils.jl's compile-time helpers;
or jl_egal demanded by the call the intrinsifier emits (GPUCompiler's rtlib, A64R1's other precedent). Either deletes
_compares_by_egal, _demanded, _calls_builtin and _ir_value and closes A82S1; types.jl:917 cites :1550. Owner: wt3-runtime
(the roots, the citation), wt3-memory (A82S1's arm).

ada7613a: A77S1. The new rule is strict, never a default: `isconst(ref.mod, ref.name) || isempty(dynamic) || reject!`
refuses every non-const runtime binding while any initializer holds a dynamic call (Base.__init__ 94), so the touched
set decides nothing for a non-const binding, and the const-mutation flow now follows a field read, a PiNode and a PhiNode
to a fixed point. The message names it the stand-in for verify_typeinf_trim's enumeration, and leaves A77S1 open, as it
is. bd80a2f3: lazy_tables() reads every module constant holding an AbstractDict (not an ImmutableDict), an AbstractSet or
a Vector; skeleton.jl's one Ref (`grep -n '^const .*Ref' dev/skeleton.jl` gives `1658:const SRC_READ =
Ref{Function}(…)`) is assigned nowhere, so no table escapes the walk today.

Area: emission and diagnostics — bdd08864 and d84934e0, to the lead's question: ported from intrinsics.cpp and lowered
as LLVM's WebAssembly backend does, but for the 16-bit swap, with differential cases that miss two paths. Read at the
julia pin: intrinsics.cpp:1408 is `case have_fma:`, :1555 `case muladd_float:` (`CreateFAdd(mathb().CreateFMul(x, y),
z)`, contractible), :1639 `case fpiseq:` (fcmp uno of each, their and, or'd with the bits' icmp eq), each arm emitted
as written; llvm-cpufeatures.cpp:50 have_fma answers by AArch64, ARM vfp4 and x86 fma, so false for wasm32, and core wasm
has no fused multiply-add, so the scalar fmul and fadd stay two. The fma overlay (src/patch/floatfuncs.jl:10) is Base's
own else branch (floatfuncs.jl:357-358). bswap: expandBSWAP (TargetLowering.cpp:11513 at the llvm pin, `git show
HEAD:llvm/lib/CodeGen/SelectionDAG/TargetLowering.cpp`) is ported for i32 by its ROTR path (wasm has i32.rotr) and for
i64 by its eight Tmp terms in its order. (A83S4, low, R1, D3) the 16-bit arm takes the wrong branch of
PromoteIntRes_BSWAP: WebAssembly marks BSWAP Expand for i32 and i64 (WebAssemblyISelLowering.cpp:174-180, `{ISD::BSWAP,
…}` then `setOperationAction(Op, T, Expand)`), so LegalizeIntegerTypes.cpp:675-678 (`if (!OVT.isVector() &&
!TLI.isOperationLegalOrCustomOrPromote(ISD::BSWAP, NVT)) { if (SDValue Res = TLI.expandBSWAP(N, DAG)) return
DAG.getNode(ISD::ANY_EXTEND, dl, NVT, Res);`) runs expandBSWAP on the i16 node, whose arm is a rotate by 8
(TargetLowering.cpp:11526-11528, `case MVT::i16:` / `// Use a rotate by 8.` / `return DAG.getNode(ISD::ROTL, …)`);
the swap-then-shift at :681-685 that intrinsics.jl:2058-2067 ports is LLVM's path only where the wider BSWAP is legal.
The answers agree, so it is sound; it is not the lowering the comment names, at about twice the instructions. Fix: the
16-bit arm is expandBSWAP's i16 rotate, promoted (the zero-extended value's `shl 8` or'd with its `shr_u 8`, put back in
its type's form), citing :675-678 and :11526. Owner: wt3-memory. (A83S5, low, D12) the cases reach neither have_fma's
arm nor Float64's emulation: fma32 runs through the overlay, which never calls have_fma, and `sed -n 307p
base/floatfuncs.jl` gives `function fma_emulated(a::Float64, b::Float64,c::Float64)` (twomul and its subnormal and
non-finite branches), which no case runs; have_fma's arm is checked only by emitted_by. Base reaches it where `grep -n
have_fma base/math.jl` gives `55:` and `63:` (two_mul) and `769:` (hypot, whose else branch is "within one ulp", so it may
differ from native AArch64 by an ulp, Julia's own two answers). Fix: a Float64 fma case over subnormal, infinite and
cancelling inputs, and Base.Math.two_mul(::Float64, ::Float64) against native (exact on either branch). Owner: wt3-tests2.

1322a4ec, to the lead's question: yes, stated as Julia's undef refined, not a D9 default, and the verdict holds; the
cited line is not the arm WasmTarget's cases take. (A83S3, low, D7) `grep -n "assert(!init_as_value)\|CreateMemSet(strct\|emit_allocobj(ctx, sty, nargs >= nf)\|CreateFreeze" src/cgutils.cpp`
at the julia pin gives `4190:` (the freeze, the init_as_value path for a vector-like struct), `4371:` (`assert(!init_as_value)`
where nargs < nf), `4377:` (`CreateMemSet(strct, … 0 …)`), `4394:` (`emit_allocobj(ctx, sty, nargs >= nf)`) and `4434:`.
So an inline immutable struct `new` leaves short is zero-filled, Julia's own answer, and a mutable or boxed one
(UndefBitsCases' `Late`) is allocated with only its pointers nulled (codegen.cpp:2189 undef_derived_strct), its isbits
bytes the allocator's, which zero refines. Fix: code_generator.jl:1487-1492 cites :4371-4377 (Julia's zero) and :4394 with
codegen.cpp:2189 (the heap's unwritten bytes), not the freeze. Owner: wt3-cgstubs2.

a2324b37: the defaultable local is binaryen's rule and sound for an SSA value set once (a read outside the set's
innermost open scope is not structurally dominated; the layout keeps a dominator first, so no read precedes its set).
(A83S9, low, D1, D7, R1) the port has no anchor: `grep -n 'handleNonDefaultableLocals' src/code_generator.jl` gives only
the comment at :1146, inside visit_block's @parity body (:1142-1175), with no file at dart's binaryen pin
(dev/PARITY_MASTER.md:54-55, `9926156a…`). Fix: its own definition anchored at binaryen's src/ir/LocalStructuralDominance.cpp
and src/ir/type-updating.cpp handleNonDefaultableLocals at that rev, stating where the walk differs (the stackified layout,
not binaryen's expression tree). Owner: wt3-memory. f0d77945: jl_genericmemory_to_string is ported with its departures
stated (the length not zeroed; a copy where the take is short). (A83S10, low, D3) jl_string_to_genericmemory's empty arm
is not: `sed -n 104,107p src/genericmemory.c` at the pin gives `… jl_string_to_genericmemory(jl_value_t *str)` / `{` /
`if (jl_string_len(str) == 0)` / `return (jl_genericmemory_t*)((jl_datatype_t*)jl_memory_uint8_type)->instance;`, the one
empty Memory, while wasm_string_memory (wasm_array.jl:272) builds a fresh struct, so `unsafe_wrap(Memory{UInt8}, "")` is
not `===` Julia's empty Memory; the difference is not stated. Fix: the arm ported (the empty Memory's constant) or its
departure stated. Owner: wt3-memory.

5264ac7e: the site is the innermost debug frame, so an inlined site is one site, as dart's inline expander makes one
procedure per JS<T> call. (A83S6, low, D9, D6) the key is not one written site: `sed -n 136,137p
src/julia/runtime/rtutils.jl` gives `local site = "$m.$f:$line"` / `any(x -> x[1] == site, out) || push!(out, …)`, so two
JS sites on one line, or two methods of one name in two files of a module at one line number, share a key; the second's
code is dropped there and namer.jl:144 gives both one import, so the second site runs the first's JS, silently. Latent:
print_patch.jl:14 is today's one site. Fix: a site keyed by its Method (its file) and line, and a second distinct code at
one key refused, located (Julia's debug info has no column). Owner: wt3-runtime.

Area: enforcement and prose — 53a91cd0, to the lead's question: confirmed, and the other ten are true. (A83E1, medium,
D11, R2) `sed -n 232,241p dev/formal/ValueClasses.tla` gives `Done == stack = <<>> /\ phase = "done"` and
`ValuesCovered == Done => …`, `SupertypeClosed == Done => …`, `FieldsClosed == Done => …`: a stronger antecedent is a
weaker claim, so "Done — moot: strengthened" weakens all three, each now unchecked where the walk's stack first empties.
The weakening is not needed. A scratch instance (MCVCRest, extending ValueClasses with `AtRest == stack = <<>>` and the three
claims under it, ValuesCovered less the record classes, with MCValueClasses.cfg's constants) run by `java -cp
~/.cache/wasmtarget/tla2tools.jar tlc2.TLC -config MCVCRest.cfg MCVCRest.tla` gives `Model checking completed. No error has
been found.` / `4370 states generated, 4130 distinct states found, 0 states left on queue.`: SupertypeClosed and
FieldsClosed hold at every rest, unweakened, and ValuesCovered holds there for every class but the records. The other ten
lines are extensions: Classes, FieldTypes, ValueClassesOf, FieldClasses, MeetValue and MeetClass gain arms for Tup, Rec1
and OT, which no earlier program or form reaches; TypeOK, Init and Step gain the phase; Next gains RecordPass and Finish.
FieldClasses(Rec1) = {} where the model's own rule gives a top-typed field {"Any"} (Box's), harmless while Any is listed by
every supertype chain. And Spec's fairness changed (`WF_vars(Step)` to `WF_vars(Step \/ RecordPass \/ Finish)`), unnamed
(A83S2). TupleRecord.tla models the producers and convertType's arms as written, its two Broken variants each its claim.
Fix: SupertypeClosed and FieldsClosed under `stack = <<>>`, ValuesCovered there for the non-record classes and under Done
for the records; a weakening, where one is needed, says so in its line. Owner: wt3-memory. (A83S2, low, D6, D11) the lock
that let it pass is a stopgap: test/parity_ratchet.jl:2744 accepts `moot: \S.*`, any text, and :2841-2842 (`local
defs_named = Set{String}(claims_before)` / `union!(defs_named, ("Init", "Next"))`) asks a line for the rewritten
definition alone, never for the claims that read it, and never for the SPECIFICATION's definition, so a fairness change
is free. Fix: a rewritten definition that a claim reads requires a line naming that claim, and Spec's definition joins
Init and Next. Owner: wt3-parity.

c30ce7a4. (A83S7, low, D6, D31) "refused before any stage" is half true: `grep -n "" dev/check.sh` gives the counter's plant
at :112, the load at :113, the ratchet started in the background at :118 (`… test/parity_ratchet.jl > .wtd/ratchet.out 2>&1
& rpid=$!`) and the tie at :141, and `grep -n trap dev/check.sh` gives nothing, so a mismatch spends the load and exits 1
with the ratchet still running, an orphan on the shared cores. Fix: SHARDS, D14_RED and the tie above :112. Owner: lead.
96a9d6af. (A83S8, low, D5, D6) a key input read from the ambient environment: `sed -n 21,22p dev/cache_key.sh` gives `if [
-n "${WT_JULIA_HEADER:-}" ]; then` / `header=$WT_JULIA_HEADER`, trusted unchecked, and the header's expression is written
twice (cache_key.sh:24-25 and parity_ratchet.jl:3394), so a stale export in a lane's shell keys every other caller (the
kinds cache) to another julia. Fix: the ratchet passes the header as an argument it alone sets, read from one definition.
Owner: wt3-parity. 4f67a2d4: each limit's number states its band (a case's 120 CPU-s, its 600-s wall the CPU limit over
the lowest share measured, 0.2), the watchdog starts before inference, and its plant reaches the cut. b576744e's hook and
L154's reading agree, each planted. d33e14e7 moves L208's counting in-process, one function shared.

stopgap in disguise: A83S1's demand predicate, a root outside the generated list; A83S2's moot line, any text; A83S7's
tie, below the stages it guards.

precedent: native_code.dart:144 PragmaEntryPointsVisitor.visitProcedure, gf.c:3910 jl_add_entrypoint, verifytrim.jl:300
get_verify_typeinf_trim (the roots); kernel_nodes.dart:630 throwAsCheckError; subtype.c:1550-1558 (Type{X} below its kind);
intrinsics.cpp:1408, :1555, :1639, llvm-cpufeatures.cpp:50, floatfuncs.jl:357; TargetLowering.cpp:11513 expandBSWAP and
LegalizeIntegerTypes.cpp:665 PromoteIntRes_BSWAP; cgutils.cpp:4151 emit_new_struct with codegen.cpp:2189; genericmemory.c:104
and :189; binaryen's handleNonDefaultableLocals at dart's binaryen pin; inline_expander.dart:21; POSIX RLIMIT_CPU and
ReTestItems.jl:409 (the corpus limits).

Requirements: D3 (A83S4, A83S10), D5 (A83S1, A83S8), D6 (A83S2, A83S6, A83S7, A83S8), D7 (A83S3, A83S9), D9 (A83S6;
1322a4ec's zero is a refinement, not a default; ada7613a rejects, never defaults), D11 (A83E1, A83S2), D12 (A83S5),
D17 (4f67a2d4's limits each a number with its band; D14's band untouched).

R1 and R2. R1: the roots are dart's pragma read at the pin, not a list; the intrinsics are Julia's codegen arms lowered as
LLVM's WebAssembly backend lowers them, but the 16-bit swap (A83S4); the defaultable local is binaryen's, unanchored
(A83S9); jl_egal's demand is the one bespoke rule left (A83S1). R2: no stub is called complete; src stays 3087 of 3404,
and no commit claims a port it lacks; a fix called done that is not: 4651ec94's deletion claim (A83S1), c30ce7a4's "before
any stage" (A83S7), and 53a91cd0's "moot: strengthened" (A83E1), which a `Fixes: A80E2` would have closed with the weakening
in it.

Resolution: this entry lands alone, prose only, and fixes nothing. A80S4 leaves row 1.A6, fixed by bd80a2f3; A81S3 leaves
row 1.L, fixed by b576744e; A64R1 and A73S3 leave row 1.C, fixed by 4651ec94; A77S2 leaves row 1.F, fixed by 5264ac7e.
A80E2 and A77S1 stay in row 1.C, no `Fixes:` line naming them. Open, their rows the lead's to write: A83E1 for row 1.C,
beside A80E2; A83S1 for row 1.C, beside A82S1; A83S3, A83S4, A83S5, A83S9 and A83S10 for row 1.D; A83S6 for row 1.F;
A83S2, A83S7 and A83S8 for row 1.L. By owner: wt3-memory A83E1, A83S4, A83S9 and A83S10, with A83S1's arm (A82S1);
wt3-runtime A83S1 and A83S6; wt3-cgstubs2 A83S3; wt3-tests2 A83S5; wt3-parity A83S2 and A83S8; lead A83S7.

## 2026-11-01 — audited through 111b93c6 (d84934e0..111b93c6: a class's null case checked by type.dart's _asInterfaceSubtype0, muladd and fma in one rounding with have_fma true, D13 judged from ship start, one julia header definition, the D11 lock's readers and antecedents, the wall-backstop plant in a child, OverrideVerifier's visitors mapped)

The eighty-fourth audit, beside the work, covers the 8 commits of d84934e0..111b93c6 that are not audit entries
(2313d029, entry 83): 399ba903, 787f152f, d3cfc78f, f08173cf, 5feef74f, c964a22f, 56687090 and 111b93c6, read under
Dale's R1 and R2 as standing sections. Every finding rests on one exact command, quoted.
Standing items. Each commit names its clause in a `Charter:` line (399ba903 C2, 787f152f C10, d3cfc78f C3, f08173cf
C10, 5feef74f C0, c964a22f C10, 56687090 C10, 111b93c6 C2). No silent catch: `git diff d84934e0..111b93c6 | grep -cE
'^\+.*\bcatch\b'` gives 3, two in entry 83's own prose and test/src/runtime.jl's, which tests the TypeError it catches.
The debt list reads 371 (`grep -v '^#' dev/quarantine_unpinned.txt | grep -c .`), one fewer: 399ba903 deletes
`julia/packages.jl Runtime`. src reads 3087 of 3404 at every commit of the range (`.git/wt-progress.tsv`, d84934e0 to
111b93c6), the runtime library's 13 rejecting sites naming 9 definitions before and after 399ba903: no dart definition
of dart2wasm gained a body; the range's src work is type.dart's and class_id.dart's runtime ports (12 definitions) and
the fma overlays. Earlier findings: A83S7 is fixed by 787f152f (`grep -n "^SHARDS=6\|tree_instructions.jl --plant"
dev/check.sh` gives `106:` and `125:`, the tie at :118 between them); A83S8 by 5feef74f (`grep -rn WT_JULIA_HEADER dev
test src` gives only MARCH's row, entry 83 and the plant at test/parity_ratchet.jl:1867 that sets it to prove it
ignored); A83S2 and A76E4 by c964a22f, their residues A84E4, A84S1 and A84S2; A76S2 by 111b93c6 (each visitor's line
read at the dart pin: `grep -n "void visit\|_checkField\|_isOverride" override_verifier.dart` gives :25, :32, :39, :50,
:68, :90, :97, :110 and :121, as the map cites). A83S5 is narrowed by d3cfc78f, with no `Fixes:` line, so it stays: mad's
second muladd over 1.5 and -2.5 now runs Float64's fma_emulated against native, while have_fma's arm is still checked
only by emitted_by. A77E2 stands, re-read: `ps` finds an autoship loop in .worktrees/wt3-constants (held: `cat
.git/wt-held` gives `wt3-constants`), its dev/ship.sh holding neither the hold's refusal nor origin's trampoline
(`grep -c "wt-held\|ship.origin.sh"` gives 0), 117 failure rows (110 of them rebase conflicts) in wt-ship-failures.tsv since 2026-10-29T09:11Z; the
pre-push hook is what keeps it from landing. A51E3 stands, worse (A84E2). A83E1, A83S1, A83S3, A83S4, A83S6, A83S9,
A83S10, A82E1, A82S1 to A82S5, A82S7, A80E2, A77S1, A80S2, A80S3, A77E1, A77E3, A78S2, A76E5, A76E6, A68E3, A71E2, A69E1,
A68E2, A68S4, A72E1 and A67E1, carried, not re-read. Findings A84E1 to A84E4 and A84S1 to A84S6.

Area: builder — no change under src/wasm_builder (`git diff --stat d84934e0..111b93c6 -- src/wasm_builder` gives
nothing).

Area: collection and planning — 399ba903: the runtime ports and their roots. Each anchor read at the dart pin (`sed -n
<line>p sdk/lib/_internal/wasm/common/type.dart` for 665, 670, 687, 695, 1005, 1185, 1196, 1498, 1518, 1589 and 1651
gives each declaration as cited), and emit_as_check (src/types.jl:535-570) is types.dart:527-595 line for line: the
operand teed to a local, encodedBool, the nullability and class id, the call, its outputs dropped, the local read.
Two departures, each stated: dart's `assert(!_isObjectClassId(tId))` (:1188) is not written, and `if (minify)
_throwErrorWithoutDetails()` (:1599) is not ported ("WasmTarget has no minified build of its runtime"). told_by_class
(src/julia/classes.jl) replaces the inline kind test in can_use_type_check_helper, one definition for both callers (D5).
(A84S4, low, D12) the table path is ported and no case runs it, and none can through the code generator: `sed -n
595,602p src/types.jl` gives can_use_type_check_helper answering `(tested_against_type, false)` or rejecting for every
type with no free type variable that its kinds do not split, so is_interface_class_type (classes.jl) reaches the
non-null arm of emit_is_test (:499) and emit_as_check (:553) for no class of the closed world; `grep -ln
"_check_subclass_relationship\|wasm_array_read\|_type_row_displacement\|_is_interface_subtype0" test/src/*.jl
test/smoke_corpus.jl` gives nothing. So _checkSubclassRelationshipViaTable (src/runtime/common/type.jl:61), the three
table getters' lowering (generate_static_getter_intrinsic), WasmArray's read and readUnsigned, and ClassID.getID's
header load are compiled into every module (rooted by their pragmas) and executed by none; the commit's cases test the
null case alone. Fix: a case compiling `Runtime._is_interface_subtype0` as an entry, called with a value of a class, of
its subclass, of an unrelated class and `nothing`, each answer against native `isa` on the class the id names. Owner:
wt3-runtime.

Area: emission and diagnostics — d3cfc78f, to the lead's questions. Is one rounding Julia's own answer on this host:
for an inlined Float32 or Float64 muladd, yes. At the julia pin, `sed -n 1555,1561p src/intrinsics.cpp` gives `case
muladd_float:` emitting `mathb().CreateFAdd(mathb().CreateFMul(x, y), z)` under math_builder(ctx, true, true), the
contract flags AArch64's backend fuses into one fmadd; `sed -n 40,47p src/llvm-cpufeatures.cpp` gives always_have_fma
answering `typ == "f32" || typ == "f64"` on AArch64; the runtime intrinsic (runtime_intrinsics.c:1517 `#define
muladd(a, b, c) a * b + c`) is one C expression. Float16, the third IEEEFloat the overlay names, is refused before any
arithmetic (src/translator.jl:978), so fma_emulated(::Float16)'s Float32 double rounding is never reached. Is the
departure stated: yes, in the floatfuncs.jl header, both @quarantine reasons and have_fma's comment (intrinsics.jl:
1924-1932): core wasm has no fused multiply-add, the oracle is the native FMA host. Does another path lower muladd
unfused: no. `git grep -c muladd -- src` gives `src/intrinsics.jl:2` (have_fma's comment) and
`src/patch/floatfuncs.jl:5`; muladd_float reached directly rejects; legacy's julia_numeric_tier.jl:144 lowers it fused,
so WT1 agrees. Have_fma true sends Base's two_mul (math.jl:55, :63) and hypot (:769) to their fma branches, each fma the
overlay's fma_emulated. (A84E1, medium, D3, D9) one rounding is not Julia's answer at every muladd, and the overlay
claims it is: `sed -n 716,718p test/smoke_corpus.jl` gives "x^n is not here: muladd lets the compiler round once or
twice, and native / Julia 1.12 fuses the muladds in pow_body where native 1.13 does not (measured on all 4001", while
`grep -n consistent_overlay src/patch/floatfuncs.jl` gives `15:@quarantine "julia/base/float.jl:500 muladd is
muladd_float, which LLVM fuses on an FMA host; … one rounding as natively" Base.muladd @consistent_overlay`. LLVM's
contraction is a choice per site, not a function of the source; a consistent overlay tells WasmTarget's inference it
may evaluate the call with Base's native method, so on 1.13 a constant-folded x^n (native pow_body, unfused) and a
run-time x^n (the overlay, fused) can differ in one module, where native agrees with itself; and the reason states the
fused answer as native's unconditionally, with the measured exception only in a test comment. Fix: the overlay
declared without @consistent_overlay (the call evaluated only by the overlay), and its reason stating that native's
answer is LLVM's contraction per site, fused at every muladd here, x^n on 1.13 the measured departure; or the departure
made a located rejection. Owner: wt3-memory. (A84S6, low, D9) the oracle's fusing is assumed, never checked: `grep -rn
have_fma test dev` gives the corpus comment, the intrinsics test and MARCH's row, and nothing asserts that the native
side fuses, so on a host whose CPU lacks FMA every bit_exact_math case would read WasmTarget wrong. Fix: the
differential harness (test/runner.jl's native answer) asserts native `Core.Intrinsics.have_fma(Float64)` once and
refuses, located, on a host that answers false. Owner: wt3-tests2.

399ba903's failure type. (A84S5, low, D9) the table jl_to_typeof reads is null past a gap: `sed -n 831p src/intrinsics.jl`
gives `local entries = NirConst[NirConst(Core.Const(get(small_typeof, id, nothing))) for id in
0:length(t.classes[])-1]`, every class no as check names a null entry, guarded by :837's `ref_as_non_null`, a trap
with no location, and a comment arguing that no read reaches one; small_typeof is a second map from class id to type
beside translator.classes. Fix: jl_to_typeof's callers pass only ids the table holds by construction (the linking
action refuses, located, a called id with no entry), or the table's entries read from translator.classes for every
class whose type is a constant, its exceptions named. Owner: wt3-runtime.

Area: enforcement and prose — (A84E2, high, D2, D12) the landing check runs no group of test/smoke.jl, so a wrong
answer lands green. `grep -n smoke dev/check.sh dev/ship.sh dev/gate.sh` gives only check.sh:72 and :87, the corpus
image's build; `grep -oE '_g\("[a-z0-9_]+"' test/smoke_corpus.jl | sort -u | wc -l` gives 140 groups, 35 of them
`dart_` (`grep -cE '^_g\("dart_'` gives 35), and dev/corpus.sh, the runner beside the landings, runs only the dart_
groups (test/src/dart_tests.jl:2, "every case of test/smoke_corpus.jl's `dart_*` groups"); the other 105, bit_exact_math
among them, run only in dev/lanes.sh at a clause's closure. So bdd08864 landed 14 wrong bit_exact_math answers green,
its own case built not to tell (`git show bdd08864 -- test/src/code_generator_intrinsics.jl | grep -n "product is"`
gives `46:+# muladd_float as an fmul then an fadd (core wasm has no fused multiply-add; inputs whose product is`, "exact,
where fused and unfused agree"), and audit #83 read the lowering sound without running the group; d3cfc78f found it by
running WT_SMOKE_EXACT=1 test/smoke.jl by hand. And the runner itself is down: `ps aux | grep -c "[c]orpus.sh"` gives
0, and `.git/wt-corpus.tsv`'s verdicts read 26 green, 24 red and 7 hung, the last green 2026-10-29T08:13:38Z at
a0573e28, the last run 2026-11-01T20:46:19Z at 6732d4a6, hung. D2 says a green differential means sound; the charter
(dev/CHARTER.md:162) makes the differential lanes "the soundness gate", and D2's ledger row names test/smoke.jl as its
check. That needs the differential to run on a semantic change before it lands, or a red on the head to stop the next
landing, which neither does today (A51E3's half). Fix: row 1.Q's construction, each smoke group's outcome recorded in
the tree and the landing refused where a case PASS at the tip is not PASS; until it lands, dev/corpus.sh runs every
group, not the dart_ groups alone, on each new head, restarted, and a red head writes the line stop naming the lane
that landed it. Owner: lead (the check's stage and the stop), wt3-tests2 (the runner's coverage and its restart).

f08173cf, to the lead's question: it judges the queue and the check honestly and no longer the backlog, but it changed
the measure Dale's row names, and a lane can hide a slow landing in it. (A84E3, medium, D13, D17, D18) `grep -n
"edit-to-landed" dev/LEDGER.md` gives `36:`, D13's band "a 300-s target for the median edit-to-landed of the last five
landings, red past 600 s", while dev/ship.sh:260 reads field 4, seconds from this ship's start, and the ledger row
is unchanged. A red attempt restarts the clock: `tail -4 .git/wt-landings.tsv` gives `111b93c6 1209 173 wt3-parity`,
and `awk -F'\t' '$1 >= "2026-11-02T04:12:50Z"' .git/wt-ship-failures.tsv` gives the same change red at
2026-11-02T04:28:19Z as 4d819ea9, so it landed at least 648 s after its first ship began, past D13's red line, and was
recorded at 173 s; 5feef74f, red at 04:19:52Z as ace1e8c3, was recorded at 117 s. The backlog is printed and judged by
nothing, so a lane holding a stack for hours is invisible to every band (A41E3's half). And `sed -n 22p dev/ship.sh`
gives `export WT_SHIP_START="${WT_SHIP_START:-$(date +%s)}"`, a value any lane's shell can set (A50E1's class).
Fix: D13 measured from the first ship of a change (its patch-id's first row in wt-ship-failures.tsv or its first ship
start, kept in the common dir) to its landing, the backlog judged per lane with its own band, and WT_SHIP_START
inherited only under WT_SHIP_ORIGIN=1 (the trampoline); a change to what D13 measures arrives with its ledger row,
quoting Dale. Owner: lead.

c964a22f, to the lead's question: it refuses an antecedent strengthened under a moot line where the claim names it
left of `=>`, and its carry is satisfied by a definition nothing checks. (A84E4, medium, D11, D6, R2) `sed -n
2980p;2985,2987p test/parity_ratchet.jl` gives the cfg `SPECIFICATION Spec\nINVARIANT Holds\n`, the module adding
`HoldsThen == DoneThen => y = 1`, the lines `Done — carried by DoneThen` and `Holds — carried by HoldsThen`, and
`isempty(invariants_dropped(t, a0))` expected: the plant passes with HoldsThen in no cfg, so the claim at the old
antecedent is defined and never model-checked. The check (:2917-2921) asks only that some definition at HEAD hold the
antecedent's old text, while its refusal says "its line keeps no claim judged at its old text", and a reader claim's
line is accepted by `haskey(lines, c)` (:2914) whatever it names. Fix: a carried claim's successor must be listed by a
cfg at HEAD and read the carried definition (the successor's reach), the plant's cfg listing HoldsThen and a plant
with it unlisted refused. Owner: wt3-parity. (A84S1, low, D11, D6) the polarity residuals, each a negative position
the regex misses: `sed -n 2903p test/parity_ratchet.jl` gives `local segs = split(split(d[c], "=="; limit = 2)[end],
"=>")`, so `~P \/ Q` and `IF P THEN Q ELSE TRUE` (P's), `P ~> Q` (leads-to: no `=>` in `~>`), the right side of `P <=> Q`
(split gives `P <` and `Q`, only P taken), a definition the antecedent reads (Finished under `Done == Finished /\ …`:
the test reads the claim's own text, never its reach) and the specification itself, the antecedent of every claim
(`Spec => []Inv`): Init, Next, Spec's fairness and a cfg's CONSTANTS, each accepted under any moot line, so a narrower
Init, Next or bound, or a stronger fairness, weakens every claim with one line. And `sed -n 2758p` still says
definitions are compared "with comments and whitespace dropped", where the code now collapses whitespace. Fix: the
antecedent read by polarity over TLA+'s connectives (the negative positions of `~`, `=>`, both sides of `<=>`, IF's
condition, `~>`'s left), through the reach, and Init, Next, the SPECIFICATION's conjuncts and the CONSTANTS treated as
antecedents of every claim; the comment as the code. Owner: wt3-parity. (A84S2, low, D11) a positive-position
weakening is excused by any moot reason: `sed -n 2994,2998p` gives `Limit == 4` over `Holds == x <= Limit` (the
bound 3 raised to 4, Holds weaker) passing with `Limit — moot: the bound moved` and `Holds — moot: judged at the new
bound`; D11 says never weaken an invariant. Fix: a rewritten definition a claim reads carried like an antecedent, the
claim at its old text kept in a cfg, moot only where the variable or the claim's subject is gone. Owner: wt3-parity.

56687090. (A84S3, low, D12, D6) the untaken interrupt is routed around, not found: `sed -n 1477,1478p
test/src/dart_tests.jl` passes the plant on either end, "past its 2-s wall backstop, at \d+ CPU-s" (the interrupt
taken) or "took no interrupt in 1 s: the process is killed", so the interrupt path, the one the shard showed broken, is
checked by nothing; the commit does not say why a sleeping task under `Base.exit_on_sigint(false)`
(test/dart_limit.jl:33) took no SIGINT in the shard's process, and `grep -c "took no interrupt" .git/wt-corpus.tsv`
gives 1, the same failure on the corpus runner (eb5655ce, hung). Fix: the cause found and fixed in _dart_limited, and
the plant requiring the interrupt's end. Owner: wt3-tests2. 5feef74f: the header has one definition
(dev/julia_header.jl), passed as `--header`, the environment read nowhere. 787f152f: the tie at check.sh:118, before
the plant (:125), the load and the ratchet. 111b93c6: comments only, each line as cited.

stopgap in disguise: A84E4's carry, a definition with the old text standing in for a claim kept judged; A84S1's
antecedent, a regex over `=>` standing in for polarity; A84E3's D13, a narrower measure under the same name.

precedent: intrinsics.cpp:1555 muladd_float and :1408 have_fma, llvm-cpufeatures.cpp:40 always_have_fma, floatfuncs.jl
:279-357 fma_emulated and float.jl:500 muladd (d3cfc78f); types.dart:434 emitIsTest and :527 emitAsCheck, type.dart:665
to :1651, class_id.dart:10, intrinsics.dart:1059 and :1577, constants.dart:1913, julia.h:971 jl_to_typeof (399ba903);
override_verifier.dart:25 to :121 (111b93c6); base/loading.jl's stale_cachefile header (5feef74f); TLA+'s polarity of
`=>`, `~`, `<=>` and `~>` (Lamport, Specifying Systems), which c964a22f's antecedent rule names none of.

Requirements: D2 (A84E2), D3 (A84E1), D5 (5feef74f's header and told_by_class each one definition; A84S5's second id
map), D6 (A84E3, A84E4, A84S1, A84S3), D9 (A84E1, A84S5, A84S6), D11 (A84E4, A84S1, A84S2), D12 (A84E2, A84S3, A84S4),
D13 (A84E3), D17 (A84E3; 56687090's 2-s wall and 1-s grace, each in a plant; D14's band untouched).

R1 and R2. R1: d3cfc78f ports Julia's own fma_emulated and the host's have_fma answer; 399ba903 ports type.dart and
emitAsCheck one to one, its one Julia piece, the type table, after jl_small_typeof; c964a22f's antecedent rule is
bespoke, a regex with no precedent named (A84S1); 56687090 is a test-side bypass with no counterpart (A84S3). R2: no
stub is called complete; src stays 3087 of 3404 and 399ba903 says the general arm still rejects, Unported. Fixes
called done that are not: c964a22f's "refuses a moot line for an antecedent", whose own passing plant carries the
claim to a definition no cfg lists (A84E4); f08173cf's "D13 judges the loop", which drops each red attempt (A84E3); and
399ba903's table path, ported but run by nothing (A84S4).

Resolution: this entry lands alone, prose only, and fixes nothing. A83S8 leaves row 1.L, fixed by 5feef74f; A83S2 and
A76E4 leave row 1.L, fixed by c964a22f; A76S2 leaves row 1.K, fixed by 111b93c6; A83S7 sat in no row, fixed by
787f152f. A83S5 stays in row 1.D, narrowed, no `Fixes:` line naming it. Open, their rows the lead's to write: A84E1 for
row 1.D; A84E2 for row 1.Q; A84E3, A84E4, A84S1 and A84S2 for row 1.L; A84S3 and A84S6 for row 1.T; A84S4 and A84S5
for row 1.F. By owner: wt3-memory A84E1; wt3-runtime A84S4 and A84S5; wt3-tests2 A84S3 and A84S6, with A84E2's runner;
wt3-parity A84E4, A84S1 and A84S2; lead A84E2 and A84E3.

## 2026-11-01 — audited through c17cd8f8 (111b93c6..c17cd8f8: D13 judged edit to landed again, 105 byte-identity probes, an FMA host required, an interface target a SelectorReference, a receiver's admitted classes read by getConcreteClassIdRange and tuple receivers given no field selector, the wall-backstop plant's cause measured)

The eighty-fifth audit, beside the work, covers the 5 commits of 111b93c6..c17cd8f8 that are not audit entries
(01cde546, entry 84): 144e7812, 12b49771, 620c2c86, c01e360b and c17cd8f8, read under Dale's R1 and R2 as standing
sections. Every finding rests on one exact command, quoted.
Standing items. Each commit names its clause in a `Charter:` line (144e7812 C10, 12b49771 C10, 620c2c86 C10, c01e360b
C5, c17cd8f8 C10). No silent catch: `git diff 111b93c6..c17cd8f8 | grep -cE '^\+.*\bcatch\b'` gives 4, one in entry
84's prose and three in test/src/dispatch_table.jl, each testing the RejectionError it catches. The debt list reads
370 (`grep -v '^#' dev/quarantine_unpinned.txt | grep -c .`), one fewer: c01e360b deletes `julia/kernel.jl Reference`.
src reads 3087 of 3404 at every commit of the range (`.git/wt-progress.tsv`), as at the 39 landings from
81427cbd (2026-11-02T01:21:35Z, `awk -F'\t' '$3 ~ /src: 3087 of/' .git/wt-progress.tsv | wc -l` gives 39): no dart
definition gained a body in this range or the last (D40). D13 at the head: `tail -5 .git/wt-landings.tsv | cut -f3`
gives 248, 419, 561, 1285 and 314, a median of 419 s, past the 300-s target and inside the 600-s red line. Earlier
findings: A84E3 is fixed by 144e7812; A82S2, A82S3 and A83S3 by c01e360b (A83S3's anchors read at the julia pin:
`sed -n 4371,4377p src/cgutils.cpp` gives `if (nargs < nf)` and the CreateMemSet of zero, `sed -n 4394p` gives
`emit_allocobj(ctx, sty, nargs >= nf)`, `sed -n 2189p src/codegen.cpp` gives undef_derived_strct, which nulls the
pointers and the bytes before the first field), its residues A85S1 and A85S3. A84S6 is fixed by 620c2c86, read here as
complete though its body carries no `Fixes:` line: test/runner.jl:33 refuses a host where
`Core.Intrinsics.have_fma(Float64)` is false, at load, and test/smoke.jl:27 and test/src/dart_tests.jl:39 include
the runner before any native answer. A84S3 is narrowed by c17cd8f8 (`Narrows:`), so it stays: the measured cause is
Julia's runtime, and its own measurement (the interrupt taken 5 of 5 times with one interactive thread) leaves the
plant able to require the interrupt in a child it starts with JULIA_NUM_THREADS=1,1, which it does not. A77E2 stands,
re-read: `awk -F'\t' '$1 >= "2026-11-02T04:40"' .git/wt-ship-failures.tsv` gives three wt3-constants rebase conflicts
in test/src/constants.jl in this range, at 05:04:48Z, 05:10:54Z and 05:22:27Z. A84E1, A84E2, A84E4, A84S1, A84S2,
A84S4, A84S5, A83E1, A83S1, A83S4, A83S5, A83S6, A83S9, A83S10, A82E1, A82S1, A82S4, A82S5, A82S7, A80E2, A77S1,
A80S2, A80S3, A77E1, A77E3, A78S2, A76E5, A76E6, A68E3, A71E2, A69E1, A68E2, A68S4, A72E1, A67E1 and A51E3, carried,
not re-read. Findings A85E1 and A85S1 to A85S5.

Area: builder — no change under src/wasm_builder (`git diff --stat 111b93c6..c17cd8f8 -- src/wasm_builder` gives
nothing).

Area: collection and planning — c01e360b's admitted classes, to the lead's question: is the reading now one source.
The reading is: field_selector_calls takes it from DispatchTable.build as a function, and both visitors call
ClassIdNumbering.getConcreteClassIdRange (class_info.dart:831, `sed -n 831p` at the dart pin gives
`List<Range> getConcreteClassIdRange(Class klass) {`). The class list built from it is not one definition. (A85S3,
low, D5) `grep -n "id + 1\].cls for r in get_concrete_class_id_range\|t.classes\[\]\[id + 1\].cls for id in ids"
src/*.jl` gives src/code_generator.jl:1841, :1951, src/intrinsics.jl:357 and :1802, beside src/dispatch_table.jl:373,
the same projection from ranges to classes written five times; and the selector's name for one receiver and field is
computed twice, by field_selector_name in field_selector_calls (src/julia/classes.jl:713) when the table is built
and again in each visitor (code_generator.jl:1841, :1951), so a receiver build skips (A85E1's tuples) still gets a
name in the visitor that finds no selector. The test reads neither: `sed -n 142p test/src/dispatch_table.jl` gives
`admitted_of(cs::Vector{DataType}) = r -> DataType[c for c in cs if c <: r]`, the `<:` filter c01e360b deleted from
src, so field_selector_calls's own cases never run getConcreteClassIdRange (DD.build's case does). Fix: one
definition of a type's concrete classes over get_concrete_class_id_range, called at all five sites, and the visitors
reading the selector field_selector_calls named for that call, not naming it again; the test's admitted classes read
from a numbered translator. Owner: wt3-cgstubs2.

Area: emission and diagnostics — c01e360b, to the lead's questions. Is the SelectorReference a faithful counterpart
of dart's interface target: in its use, yes. `sed -n 2037,2044p pkg/dart2wasm/lib/code_generator.dart` gives
`interfaceTarget.referenceAs(getter:, setter:)` passed to selectorForTarget and `assert(selector.name ==
interfaceTarget.name.text)`, and src/code_generator.jl:1687-1691 does the same with the reference's name and kind;
expressions.dart:581 is InstanceGet's `Reference interfaceTargetReference;` (the class at :551), as cited; every
functions.dart, translator.dart:2195, dispatch_table.dart:118 and code_generator.dart:3528 anchor of the new arms
reads as cited. In its type, no. (A85S1, low, D6, D7) dart's interface target is a member's Reference, so every
consumer of the sum accepts it; WasmTarget's names no member, and the sum makes each consumer refuse it by hand:
`git grep -n "SelectorReference) => reject!(Internal" -- src | cut -d: -f1,2` gives code_generator.jl:2450,
dispatch_table.jl:195, functions.jl:122, :165, :309, :321, :332, :350 and translator.jl:1604, nine arms, and
_virtual_call (code_generator.jl:1679) types its target Reference and refuses the other two kinds at :1690. Passing a
SelectorReference to getFunction can be written and fails only when run. The prose was not carried: `sed -n
89,95p src/julia/kernel.jl` gives "Julia's differs: … so the sum is a method's specialization or a field's accessor"
and the @quarantine "names a member or one of its accessors" over a Union whose third kind "is no member". Fix: the
SelectorReference outside the Reference sum, _virtual_call's interface target typed SelectorReference and
selector_for_target given its method, so the nine arms and :1690's test cannot be written; or, kept in the sum, its
docstring and @quarantine reason stating the third kind and how it differs from Kernel's (D7). Owner: wt3-cgstubs2.

Does skipping tuple receivers match dart's record field access: the behavior holds for an open tuple type, the cited
counterpart does not. (A85S2, low, D7, D26) `sed -n 326,332p pkg/kernel/lib/src/ast/expressions.dart` gives
`class RecordIndexGet` with `RecordType receiverType;` and `assert(0 <= index && index <
receiverType.positional.length)`: dart reads a record by RecordIndexGet only where the static type is one record
shape, Julia's concrete tuple, and `sed -n 705p src/julia/classes.jl` gives `isconcretetype(receiver) && continue`,
so a concrete tuple never reaches the skip at :709. The receivers the skip removes are tuples of no single shape,
which dart types as Record or a supertype and reads by DynamicGet (code_generator.dart:2317 visitDynamicGet, its
dynamic dispatcher switching over the classes that have the member: the record classes' `$1` fields,
record_class_generator.dart:23). The intrinsifier's class-id switch (intrinsics.jl:310-317) is that dispatcher's
shape, and is the counterpart to cite. Fix: classes.jl:706-708's comment and the commit's reasoning anchored at
visitDynamicGet and the dynamic dispatcher, with how Julia differs (the switch over records is generated at the read,
not in a shared dispatcher). Owner: wt3-cgstubs2.

(A85E1, medium, D2, D9, D12) c01e360b changes which selectors the dispatch table holds, with no case and no probe
run, and leaves one receiver shape at an Internal rejection. `git show --stat --format= c01e360b` lists src and
test/src/dispatch_table.jl only, and `git log -1 --format=%B c01e360b | grep -ciE "probe|smoke|differential"` gives
0, though AGENTS.md asks a semantic change for its cases in smoke and 12b49771 landed the probes five minutes before
it. The skip drops every tuple receiver (classes.jl:709); the intrinsifier takes over only `T isa DataType && T <:
Tuple` with an Int index (`sed -n 315p src/intrinsics.jl`). A receiver that is a Union of tuples is no DataType: the
intrinsifier returns nothing, the visitor names a SelectorReference (code_generator.jl:1841), and the table, which
build no longer gave that selector, answers `sed -n 327p src/dispatch_table.jl`: `reject!(Internal("$at: no selector
for the field $name, which no call reads on a receiver Julia left abstract"), at)`, an Internal, a statement WasmTarget
claims cannot be reached, for a direct getfield the subset admits. `git grep -n 'Union{Tuple\|Union{NTuple' --
test/src` gives nothing: no case reaches a tuple receiver of either kind, before or after. Fix: a case in
test/smoke_corpus.jl reading a field of an open tuple and of a Union of tuples, each against native; the Union read
lowered by the same class-id switch (getConcreteClassIdRange admits its classes) or refused, located, as
Unquarantined; and the commit's probe run, `bash dev/lanetest.sh test/probe_bytes.jl` at c01e360b against its parent,
reported. Owner: wt3-cgstubs2.

620c2c86: the refusal is at load, once, and names why; CI's runners answer true. c17cd8f8: a comment only, each
measurement stated with its configuration; `grep -n "JULIA_NUM_THREADS" dev/check.sh dev/corpus.sh` gives
check.sh:39 and corpus.sh:47, both `=1`, as the comment says.

Area: enforcement and prose — 12b49771, to the lead's questions. Does the set cover every group exactly once: by
name, yes. `grep -oE '^_(g|xf)\("[^"]+"' test/smoke_corpus.jl | sort -u | wc -l` gives 165, PROBE_NAMES 105 and
PROBE_UNCOVERED 60; the first compiled row of each group in the common dir's wt-compile-cases.tsv, recomputed by awk,
equals PROBE_NAMES as a set and its groups with none equal PROBE_UNCOVERED (`diff` of the sorted lists gives
nothing). One name stands for two blocks: `grep -n '^_g("dart_nnbd"' test/smoke_corpus.jl` gives :4488 and :5384,
both pushed into DartCorpus.GROUPS, and probe_corpus.jl's key map merges them. Is it a real byte-identity check a
restructuring can fail: yes when run. test/probe_bytes.jl hashes `WasmTarget.compile(f, argtypes)` per probe and
exits 1 on a changed, new or missing hash; a probe that stops compiling throws. It runs at a clause's closure only
(`grep -rn probe_bytes dev/*.sh .github/workflows/*.yml` gives dev/lanes.sh:136 and ci.yml:141); the landing runs
test/src/probe_set.jl, names alone. (A85S4, low, D20, D6) the uncovered list is called exact and shrinks by nothing:
test/probe_set.jl:5 says a group "moves from PROBE_UNCOVERED to PROBE_NAMES, never stays (D20)", while
test/src/probe_set.jl:10-12 checks only that each group stands in one list, and the set's source, the compile
measurement at 0f92ada6, is a file in the common dir, outside the tree. A group of PROBE_UNCOVERED whose case
compiles today stays uncovered, unnoticed. Fix: test/probe_bytes.jl (or dev/corpus.sh, which compiles every case)
fails when the first compiling case of a group differs from its probe or a PROBE_UNCOVERED group compiles. Owner:
wt3-tests2. (A85S5, low, D17, D9) the baseline is compared where it was never measured: the 105 hashes were recorded
with julia 1.12.7 on this aarch64 macOS host (`julia --version` gives `julia version 1.12.7`), and `sed -n 73,82p
.github/workflows/ci.yml` gives the closure matrix's version `'1.12'`, unpinned, with lanes slices on ubuntu-latest
(x86_64) and macos-latest, where :141 runs probe_bytes. Base's IR, and the module WasmTarget builds from it, is a
function of Julia's patch release and may be of the host; test/probe_baseline.txt records neither, so a closure red
there would be a false alarm and a green on a moved release is luck. Fix: the baseline's first line names the julia
version and host it was recorded on and probe_bytes refuses, located, any other; CI's 1.12 pinned to JULIA_PIN
(src/julia/parity.jl); a Linux record, or the probes lane on the recording host's kind only. Owner: wt3-tests2 (the
baseline's header), lead (ci.yml's pin).

144e7812, to the lead's question: D13 is back to its ledger's measure, and the ship start is a diagnostic only.
`sed -n 36p dev/LEDGER.md` bands "the median edit-to-landed of the last five landings", and dev/ship.sh:260 reads
field 3 of wt-landings.tsv, written at :125 as now less the landed commit's author time (`git log -1 --format=%at
HEAD`), which a rebase keeps, so a red attempt no longer restarts it. Field 4 (WT_SHIP_START) is printed at :261 and
read by nothing else (`grep -rn "WT_SHIP_START" dev/*.sh test src .github` gives ship.sh:23, :125 and :261). The
MARCH rows match audit 84's Resolution: A84E1 in 1.D, A84E2 in 1.Q, A84E4, A84S1 and A84S2 in 1.L, A84S3 and A84S6 in
1.T, A84S4 and A84S5 in 1.F; A83S2, A83S8, A76E4 and A76S2 gone. WT_SHIP_ORIGIN, which now gates the start's
inheritance, is itself read from the environment at ship.sh:28 (A50E1's class), harmless while the start judges
nothing.

stopgap in disguise: A85S1's nine Internal arms, a run-time refusal standing in for a type that keeps an interface
target out of the member paths; A85S4's "exact list", a names check standing in for the shrink it claims.

precedent: code_generator.dart:2028 _virtualCall and :2037-2044, dispatch_table.dart:436 selectorForTarget,
expressions.dart:551/:581 InstanceGet.interfaceTargetReference, canonical_name.dart:429 Reference, class_info.dart:831
getConcreteClassIdRange (c01e360b); cgutils.cpp:4151 emit_new_struct, :4371-4377, :4394 and codegen.cpp:2189
undef_derived_strct (c01e360b's A83S3 comment); and the counterpart c01e360b should have named for an open tuple,
expressions.dart:326 RecordIndexGet's RecordType against code_generator.dart:2317 visitDynamicGet (A85S2).

Requirements: D1 (c01e360b's anchors each resolve at the pin), D2 (A85E1), D5 (A85S3), D6 (A85S1, A85S4), D7 (A85S1,
A85S2), D9 (A85E1, A85S5), D12 (A85E1), D13 (144e7812 restores the ledger's measure; the median 419 s), D17 (A85S5;
c17cd8f8's 2-s wall and 1-s grace unchanged), D40 (src flat at 3087 for 39 landings).

R1 and R2. R1: c01e360b's SelectorReference is a quarantined Julia construction with dart's interfaceTargetReference
as its precedent, and the admitted classes now come from dart's getConcreteClassIdRange; its tuple skip cites the
wrong dart counterpart (A85S2). 12b49771's probe selection is test machinery with no dart counterpart owed. R2: no
stub is called complete; src stays 3087 of 3404 at every commit, and no commit claims a port. Fixes called done that
are not whole: c01e360b's A82S2 ("one reading"), whose projection is written five times (A85S3), and A82S3, whose
sum's prose still describes two kinds (A85S1); 12b49771's D20 claim for PROBE_UNCOVERED, which nothing shrinks
(A85S4).

Resolution: this entry lands alone, prose only, and fixes nothing. A82S2, A82S3 and A83S3 leave row 1.D, fixed by
c01e360b; A84E3 sat in no row, fixed by 144e7812; A84S6 leaves row 1.T, fixed by 620c2c86 in substance (no `Fixes:` line, read complete here). A84S3 stays in row 1.T, narrowed by
c17cd8f8. Open, their rows the lead's to write: A85E1, A85S1, A85S2 and A85S3 for row 1.E (dispatch tables and
records); A85S4 and A85S5 for row 1.B (the probes are its exit). By owner: wt3-cgstubs2 A85E1, A85S1, A85S2 and
A85S3; wt3-tests2 A85S4 and A85S5's baseline header; lead A85S5's CI pin.

## 2026-11-01 — audited through 47865b93 (c17cd8f8..47865b93: CI pinned to julia 1.12.7, jl_egal a root with the demand scan deleted, a 128-bit integer as two i64 halves with its constants, conversions, equality, add, sub, neg, bitwise operations and compares, an inline JS site keyed by method, signature and line)

The eighty-sixth audit, beside the work, covers the 5 commits of c17cd8f8..47865b93 that are not audit entries
(958ea5d1, entry 85): 3d30144c, ba45a6c5, 95d33e78, db6e65ac and 47865b93, read under Dale's R1 and R2 as standing
sections. Every finding rests on one exact command, quoted.
Standing items. Each commit names its clause in a `Charter:` line (3d30144c C10, ba45a6c5 C1, 95d33e78 C3, db6e65ac
C6, 47865b93 C3). No silent catch: `git diff c17cd8f8..47865b93 | grep -cE '^\+.*\bcatch\b'` gives 3, one in entry
85's prose and two in tests (test/src/js_string.jl and test/src/translator.jl), each testing the RejectionError it
catches. The debt list reads 370 (`grep -v '^#' dev/quarantine_unpinned.txt | grep -c .`), unchanged. src reads 3087
of 3404 at every commit of the range (`.git/wt-progress.tsv`), and at 45 landings since 81427cbd
(`awk -F'\t' '$3 ~ /src: 3087 of/' .git/wt-progress.tsv | wc -l` gives 45). The range's compiler work, Int128, sits
inside one dart definition that was already counted, so it adds nothing to the count (D40; A86E1). D13 at the head:
`tail -5 .git/wt-landings.tsv | cut -f3` gives 137, 154, 1153, 178 and 186, a median of 178 s, inside the 300-s
target. Earlier findings: A83S1 is fixed by ba45a6c5 (`Fixes:`): `grep -rn "_demanded\|_compares_by_egal\|_calls_builtin\|_ir_value\|union_raisers"
src dev/skeleton.jl test/parity_ratchet.jl` gives nothing, and types.jl's cite reads at the julia pin: `sed -n
'1550p;1558p' src/subtype.c` gives `if (jl_is_type_type(x) && !jl_is_type_type(y)) {` and `return jl_typeof(tp0) ==
(jl_value_t*)yd;`. A82S1 is fixed by the same commit in substance, though no `Fixes:` line names it: the third copy
of the inline === decision is deleted, and RUNTIME_ROOTS' reason (src/julia/packages.jl:19) now ends "where Julia
differs: libjulia has no demand to keep one out, so every one is a root". A83S6 is fixed by db6e65ac (`Fixes:`) for
one body; its residue is A86S1. A85S5 is narrowed by 3d30144c (`Narrows:`): ci.yml:77 and :143 name 1.12.7, and the
baseline's header, wt3-tests2's half, is still owed. 3d30144c's MARCH rows match audit 85's Resolution: A85E1 and
A85S1 to A85S3 in 1.E, A85S4 and A85S5 in 1.B, A82S2, A82S3 and A83S3 gone from 1.D, A84S6 gone from 1.T. Carried,
not re-read: A85E1, A85S1 to A85S4, A84E1, A84E2, A84E4, A84S1 to A84S5, A83E1, A83S4, A83S5, A83S9, A83S10, A82E1,
A82S4, A82S5, A82S7, A80E2, A77S1, A80S2, A80S3, A77E1, A77E2, A77E3, A78S2, A76E5, A76E6, A68E3, A71E2, A69E1,
A68E2, A68S4, A72E1, A67E1 and A51E3. Findings: A86E1 and A86S1 to A86S3.

Area: builder — no change under src/wasm_builder (`git diff --stat c17cd8f8..47865b93 -- src/wasm_builder` gives
nothing).

Area: collection and planning — ba45a6c5, to the lead's questions. Is jl_egal rooted with no demand mechanism
left: yes. dev/skeleton.jl's julia_runtime_functions roots every definition between rtutils.jl's markers ("# ----
Julia's runtime: ..." at rtutils.jl:1, "# ---- end of Julia's runtime ----" after jl_to_typeof), and the generated
block adds `((), :jl_egal)`, `((), :jl_to_typeof)` and `((), :wasm_egal)` (packages.jl:30-31, :39). check_subset
infers once over roots and entry (`sed -n 316,318p src/julia/subset.jl` gives `_runtime_roots(world)` and one
`_infer_verified`); the second inference under `_demanded` is gone. L220's plant now adds a function inside the
section, which must be rooted, and one outside it, which must not (parity_ratchet.jl:414-420). Is the +2.8 G
first-compile cost stated: in the commit message only. `git log -1 --format=%B ba45a6c5 | grep -n "2.8 G"` gives the
line "on this tree against 283.7 G on its base, 3d30144c's parent tree: +2.8 G for three more roots", with the case
(test/instructions.jl's counter, f(x) = 3x + 1), in a fresh process. It does not name the unit (G of what, as
`@time` reports allocation), and no check bands it. That is no finding: no first-compile allocation check exists
for it to break. Will a module that never calls a root still exclude it? The 105 byte-identity probes would catch a
change there: a root emitted where nothing calls it changes every probe's bytes.

Area: emission and diagnostics — 95d33e78 and 47865b93, to the lead's questions. Is each 128-bit operation anchored
at its LLVM function so that L213 resolves it: no, they are named in comments only, in both commits. (A86E1, medium,
R1, D1, D7, D40) `grep -c '@parity "llvm\|@quarantine.*LegalizeIntegerTypes\|precedent(llvm' src/intrinsics.jl
src/julia/classes.jl src/constants.jl` gives 0 for each file. Every expansion is one closure inside
`@parity "dart2wasm/lib/intrinsics.dart:1194 Intrinsifier.generateStaticIntrinsic" ... ::Val{:int128}` (intrinsics.jl:1951):
sext/zext/trunc/bitcast at :1988-2015, eq/ne at :2016-2026, add/sub at :2030-2050, neg at :2051-2058, and the
logical ops and compares at :2059-2080. Each is anchored at a dart line it does not port. LLVM's file is outside the
pin table and the checkout: `grep -n "LegalizeIntegerTypes" dev/fetch_llvm.sh src/julia/parity.jl` gives nothing,
and `git -C ~/.cache/wasmtarget/llvm-project sparse-checkout list | grep -c SelectionDAG` gives 0. So no line can be
resolved and none is cited. The stackifier, Dale's model for R1, is one file of src/llvm per LLVM unit, each
definition `@parity` at its LLVM line (`ls src/llvm` gives fourteen such files, cfg_stackify.jl:19
`@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:49 WebAssemblyCFGStackify"`). The functions exist
at the pin (7a941dfb, LegalizeIntegerTypes.cpp fetched from the raw blob):
ExpandIntRes_ADDSUB :3905, ExpandIntRes_Logical :4695, ExpandIntRes_SIGN_EXTEND :5332, ExpandIntRes_ZERO_EXTEND
:5619, IntegerExpandSetCCOperands :5879, ExpandIntOp_SETCC :6055, ExpandIntOp_TRUNCATE :6228. Fix: add
llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes to LLVM_FILES and dev/fetch_llvm.sh's sparse list. Port each
expansion as its own definition in src/llvm/legalize_integer_types.jl, `@parity` at the lines above, its operands
the halves (GetExpandedInteger) and its result two i64 values. The int128 arm then calls these functions, as the
code generator calls the stackifier. The class layout (classes.jl:345-348) cites ExpandIntegerResult :3214 and
TargetLowering's getTypeAction (TypeExpandInteger) as its precedent. Owner: wt3-memory.

Does the port follow LLVM's text where it claims to: not everywhere, though each departure gives the same answer.
(A86S2, low, R1, D7) The fetched file shows: (a) equality. ExpandIntOp_SETCC's operands come from :5895-5898, the
halves xor'd, or'd and compared with 0, with a -1 special case at :5888-5892. The port (intrinsics.jl:2016-2026)
uses two i64.eq and an i32.and, and its comment admits it ("here their compares and'd", :1942). (b) The ordered
compares. HiCmp takes the original condition (:5942-5943 `RHSHi, CCCode, false`, so SETLE stays LE), but the port
makes it strict (:2076, `i64_lt_s`/`i64_lt_u` for sle and ule, commented "each strict" at :2073). The sign-bit
shortcut at :5902-5908 (X < 0 compares the high halves alone) is not ported. (c) ExpandIntRes_ADDSUB's carry forms
for a constant 1 and an all-ones constant (:4003-4012, :4024) are not ported, although NirConst operands can be
seen. (d) The comment at :1948 and 47865b93's message cite `TargetLowering::IntegerExpandSetCCOperands`, but the
function is `DAGTypeLegalizer::IntegerExpandSetCCOperands` in LegalizeIntegerTypes.cpp:5879. Fix: within A86E1's
port, each function follows its LLVM body branch for branch, an omitted branch named with its reason, and the cite
corrected. Owner: wt3-memory.

(A86S3, low, D5) One fact, whether a type is a 128-bit integer, is computed at six sites. `grep -rn
"sizeof([a-zA-Z_]*) == 16" src` gives translator.jl:1029, intrinsics.jl:576, :1445 and :1958, constants.jl:810 and
classes.jl:347. constants.jl:852 also finds the halves by their names (`field.name == "lo" || field.name ==
"hi"`), strings classes.jl:348 writes. Fix: one definition, LLVM's TypeExpandInteger action read once for a Julia
type (the class layout's), called at all six sites. constants.jl reads the halves by their ClassField from
class_instance_fields, as the int128 arm's `halves` does. Owner: wt3-memory.

Are there differential cases against native, including carries and borrows at the 2^64 boundary: yes.
test/src/code_generator_intrinsics.jl:279-281 runs Int128Cases.arith over the 64 pairs of
`Int64[0, 1, 2, 3, -1, -3, typemax(Int64), typemin(Int64)]`. NEARTOP = 2^64 - 3 plus a crosses 2^64 for a >= 3.
BIG - b borrows across the halves for b > 12345 and for typemin. `typemax(Int128) + Int128(a) < 0` wraps. Every
compare runs signed and unsigned. Shifts are not ported, so the high halves are observed only through compares
against constants (`r > BIG`, `s < -BIG`, `x > Int128(typemax(UInt64))`). 95d33e78's `wide` covers sext and zext
from 64, 32 and 8 bits, trunc, bitcast and eq/ne/=== over six inputs. Both run at landing: dev/check.sh:149 runs
test/src_tests.jl, which walks test/src (test/src_tests.jl:1, :15). Any other 128-bit operation reaches
`return nothing` (intrinsics.jl:2081), and visit_static_invocation rejects it Unported, located at the statement
(`sed -n 1561,1564p src/code_generator.jl`). That holds D9. jl_egal's class arm compares an Int128 by both halves,
since it reads class_instance_fields (intrinsics.jl:1683-1709).

db6e65ac, to the lead's question. Is a second distinct JS code at one key refused, located: within one body, yes.
rtutils.jl:163-170 refuses it Internal, naming the key and both codes, and test/src/js_string.jl's two_on_one_line
case reaches that refusal. Across bodies, no. (A86S1, low, D9) The refusal runs inside nir_js_sites, one method
instance at a time. The names are keyed across the whole world: `sed -n 144p src/namer.jl` gives `get!(() ->
get_name(..., site.site_name; ...), self.interop_member_names, site.site)`, one name per key over every body. And
`sed -n 106,107p src/js/runtime_generator.jl` gives `for (site, _, js_code) in nir_js_sites(component, p)` and
`site in used_sites && continue`, which keeps the first body's code for a key and skips any later body's without
comparing them. Here is how it happens: a runtime port with two sites on one line, inlined into two callers whose
constants prune a different site in each. Each body then holds one site under the same key. Neither nir_js_sites
call refuses, and the second caller runs the first's JS, the D9 fault A83S6 named. Fix: generate_js_methods keeps
site => code and refuses, Internal and located, a second distinct code at a key (or the namer's get! does). Add a
case where one line's two sites are inlined into two callers with constant branches. Owner: wt3-runtime.

Area: enforcement and prose — 3d30144c: ci.yml's matrix and its probe step both name 1.12.7 (`grep -n "1.12" .github/workflows/ci.yml`
lines 77 and 143), JULIA_PIN's release. Probes and pin now agree on CI. ba45a6c5's L220 prose describes the section
and its plant. 95d33e78 and 47865b93 each say every other 128-bit operation still rejects. No lock or ratchet
changed in the range beyond L220's plant.

stopgap in disguise: none new. A86E1's arm is a port given a dart anchor it does not port, so L213 checks a line
that has nothing to do with it. That is the gap the stackifier's anchors were built to close.

precedent: LegalizeIntegerTypes.cpp at the llvm pin, ExpandIntegerResult :3214, ExpandIntRes_ADDSUB :3905 (its
no-carry path :3998-4045, SETULT on the low result), ExpandIntRes_Logical :4695, ExpandIntRes_SIGN_EXTEND :5332,
ExpandIntRes_ZERO_EXTEND :5619, IntegerExpandSetCCOperands :5879, ExpandIntOp_SETCC :6055, ExpandIntOp_TRUNCATE
:6228. WebAssemblyISelLowering.cpp:54 `setBooleanContents(ZeroOrOneBooleanContent)` and :178 ADDC/ADDE/SUBC/SUBE
Expand, with UADDO custom only under wide arithmetic (:186-191), so wasm takes the no-carry path, as 47865b93
says. dart's inline_expander.dart:21 InlineExpander.expand, one procedure per site (db6e65ac). native_code.dart:144
PragmaEntryPointsVisitor.visitProcedure (ba45a6c5).

Requirements: D1 and D7 (A86E1, A86S2). D2: 95d33e78 and 47865b93 are differential, native the oracle, though not
yet LLVM-faithful (A86S2). D3: an i128 is what Julia's codegen hands LLVM, so LLVM's legalization is Julia's
answer, rightly chosen. D5 (A86S3; ba45a6c5 deletes the demand copy, A82S1). D6: the roots are generated, never
written. D9 (A86S1; Int128's other operations reject, located). D12: ba45a6c5 fixes A83S1 where it arose,
db6e65ac fixes A83S6 for one body. D13 (median 178 s). D40 (src flat at 3087 for 45 landings).

R1 and R2. R1: the 128-bit work follows LLVM's legalization in substance, a pinned 1:1 counterpart, but it is not
built as a port. It has no LLVM anchor, file or pin entry, and sits inside a dart definition (A86E1), and it departs
from LLVM's text in four places (A86S2). db6e65ac and ba45a6c5 rest on dart's inline expander and entry-point
roots. R2: no stub is called complete. 95d33e78 and 47865b93 each say every other 128-bit operation still rejects,
and src stays 3087 of 3404. A fix called done that is not whole: db6e65ac's A83S6, refused per body only (A86S1).

Resolution: this entry lands alone, prose only, and fixes nothing. A83S1 and A83S6 leave their rows, fixed by
ba45a6c5 and db6e65ac; A82S1 leaves row 1.C, fixed in substance by ba45a6c5 (no `Fixes:` line, read complete
here). A85S5 stays in row 1.B, narrowed by 3d30144c, for the baseline's header. Open, their rows the lead's to write:
A86E1, A86S2 and A86S3 for row 1.D (intrinsics, the LLVM ports anchored at the llvm pin); A86S1 for row 1.F (runtime
and host imports). By owner: wt3-memory A86E1, A86S2 and A86S3; wt3-runtime A86S1.

## 2026-11-01 — audited through a5a6fa39 (47865b93..a5a6fa39: a 128-bit product and shifts as compiler-rt's __multi3, __ashlti3, __lshrti3 and __ashrti3, the class-table path run against native isa, jl_to_typeof's table read from translator.classes, a second JS code at one site refused across procedures, js_helper.dart's areEqualInJS)

The eighty-seventh audit, beside the work, covers the 5 commits of 47865b93..a5a6fa39 that are not audit entries
(d8b65794, entry 86): 969b1cf0, d732aeb5, 30e9397e, 0d7a4769 and a5a6fa39, read under Dale's R1 and R2 as standing
sections. Every finding rests on one exact command, quoted.
Standing items. Each commit names its clause in a `Charter:` line (969b1cf0 C9, d732aeb5 C3, 30e9397e C1, 0d7a4769
C6, a5a6fa39 C2). No silent catch: `git diff 47865b93..a5a6fa39 | grep -nE '^\+.*\bcatch\b'` gives 3 lines, two in
entry 86's prose and one in test/src/js_string.jl, which tests the RejectionError it catches. The debt list reads 370
(`grep -v '^#' dev/quarantine_unpinned.txt | grep -c .`), unchanged. src reads 3087 of 3404 at every commit of the
range (`.git/wt-progress.tsv`), and at 51 landings (`awk -F'\t' '$3 ~ /src: 3087 of/' .git/wt-progress.tsv | wc -l`
gives 51). d732aeb5's compiler work sits inside the int128 arm, one dart definition already counted (A86E1, A87E1);
js_helper.dart joins RUNTIME_FILES, a runtime file, which the count does not read. D13 at the head: `tail -5
.git/wt-landings.tsv | cut -f3` gives 150, 199, 164, 133 and 153, a median of 153 s, inside the 300-s target.
Earlier findings: 969b1cf0's MARCH rows match audit 86's Resolution: A86E1, A86S2 and A86S3 in 1.D, A86S1 in 1.F,
A83S1 and A82S1 gone from 1.C, A83S6 gone from 1.F, A85S5 kept in 1.B. A84S4 is fixed by 30e9397e (`Fixes:`):
test/src/runtime.jl:134 compiles `Runtime._is_interface_subtype0` as the entry, over Shape, Circle and Plain and a
Circle, a Square, a Plain and nothing, each against native `isa` (its ids read by a hand-staged pipeline, A87S3).
A84S5 is fixed by 30e9397e in its D5 half only: `grep -rn small_typeof src test` gives nothing, and the table's
entries read translator.classes (intrinsics.jl:839-840); its D9 half stands (A87S2). A86S1 is fixed by 0d7a4769
(`Fixes:`): runtime_generator.jl:102-116 keeps site => code across procedures and refuses a second code, Internal,
naming the site and both codes, at `dart2wasm/lib/js/runtime_generator.dart:60 RuntimeFinalizer.generateJsMethods`,
and js_string.jl's keeps_first/keeps_second case reaches it. A82E1 is fixed by a5a6fa39 in its wt3-runtime half
only: the arm still answers (A87E2). Carried, not re-read: A86E1, A86S2, A86S3, A85E1, A85S1 to A85S5, A84E1, A84E2,
A84E4, A84S1 to A84S3, A83E1, A83S4, A83S5, A83S9, A83S10, A82S4, A82S5, A82S7, A80E2, A77S1, A80S2, A80S3, A77E1,
A77E2, A77E3, A78S2, A76E5, A76E6, A68E3, A71E2, A69E1, A68E2, A68S4, A72E1, A67E1 and A51E3. Findings: A87E1,
A87E2 and A87S1 to A87S3.

Area: builder — no change under src/wasm_builder (`git diff --stat 47865b93..a5a6fa39 -- src/wasm_builder` gives
nothing).

Area: collection and planning — 30e9397e, to the lead's question. With null entries left for classes no as check
names, can a read reach one at run time: not through the code generator, but by an argument, not by construction.
`grep -rn "jl_to_typeof" src` shows one reader, `_throw_interface_type_as_check_error0` (src/runtime/common/type.jl:111),
called only by `_as_interface_subtype0` (:101), whose one compiled call site is emitAsCheck (types.jl:561), which
records its id the line before (:560). (A87S2, low, D9, R2) A84S5's D9 half stands under a `Fixes:` line. `sed -n
839,846p src/intrinsics.jl` gives `NirConst(Core.Const(id in named ? info.cls : nothing))`, every other class's entry
null, read by `WasmBuilder.ref_as_non_null(b)`, a trap with no location. `_as_interface_subtype0` is a runtime root
(src/julia/packages.jl:23) and a Julia method a program can call, as the commit's own case calls its sibling
`_is_interface_subtype0` (test/src/runtime.jl:134). A program calling it with a class id no as check names, in a
module with no as check, reads a null entry and traps unlocated. A84S5's fix offered two forms: a called id the table
lacks refused, located, or the entries read from translator.classes "for every class whose type is a constant, its
exceptions named". 30e9397e reads translator.classes but keeps the as-checked ids alone. Is the remaining block
stated: yes, in intrinsics.jl:824-827 and the commit message, and constants.jl:811 rejects it, Unquarantined and
located (`a constant of the primitive type $cls, with no wasm representation`). But no row holds it: `grep -c
"AddrSpace\|primitive constant" dev/MARCH.md` gives 0. Fix: the table holds the type of every class whose type value
constants.jl makes; the classes it cannot make (GenericMemory's Core.AddrSpace{Core} parameter) are named in one list,
and an as check naming one refuses at types.jl:560, located; the block goes to row 1.F. Owner: wt3-runtime.

(A87S3, low, D12, Dale's rule on tests: no stage mimicry) Two of the range's cases stage the pipeline by hand instead
of compiling. `sed -n 138,140p test/src/runtime.jl` gives `D.Translator(W.build_nir(W.check_subset(probe, ...)), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())`
and `D._init_modules(t, nothing); collect(D.ClassInfoCollector(t))`. That is a second translator, built apart from
the compile whose bytes run, without `_run_tfa_phase`'s generate_record_classes, _create_module_strategy,
add_entry_points and prepare_component (src/compile.jl:278-282), and the case's class ids come from it. Likewise
js_string.jl:128-141 builds an InteropMemberNamer, calls get_import_name per body ("as the code generator names it at
the call") and calls generate_js_methods directly. a5a6fa39's case in the same file shows the direct route:
`D.compile(opts, W.check_subset(f, (), "js_helper"))` (js_string.jl:48). Fix: 0d7a4769's case asserts the
RejectionError from D.compile of `both`; 30e9397e's case reads each class id from the translator that emitted the
bytes it runs. Owner: wt3-runtime.

Area: emission and diagnostics — d732aeb5, to the lead's questions. Are __multi3, __ashlti3, __lshrti3 and
__ashrti3 ported line for line: in substance, yes. The text was fetched at the llvm pin (`git show
7a941dfb:compiler-rt/lib/builtins/<file>` in ~/.cache/wasmtarget/llvm-project, a blob:none clone). __mulddi3
(multi3.c:19-36) and __multi3 (:40-49) match intrinsics.jl:2148-2175 statement for statement, each commented with its
C line. __lshrti3 and __ashrti3 (lshrti3.c:21-36, ashrti3.c:21-38) match their arms at :2081-2104. __ashlti3
(ashlti3.c:21-37) matches as well. Are they anchored at file:line: no, they are cited in comments only, the class
A86E1 named an hour before. (A87E1, medium, R1, D1, D7) `grep -c '@parity "llvm\|@parity "compiler-rt\|precedent(llvm\|precedent(compiler-rt' src/intrinsics.jl`
gives 0. `grep -n "compiler-rt\|LegalizeIntegerTypes" dev/fetch_llvm.sh src/julia/parity.jl` gives nothing, so
neither compiler-rt nor LegalizeIntegerTypes.cpp is in LLVM_FILES or the fetch list. The four routines and
ExpandIntRes_MUL and ExpandIntRes_Shift's libcall paths are three more closures inside `@parity
"dart2wasm/lib/intrinsics.dart:1194 Intrinsifier.generateStaticIntrinsic" ... ::Val{:int128}`. The shifts are at
intrinsics.jl:2043-2106 and the product at :2148-2175, each cited by file name, no line (:1954-1961), and `ls src/llvm`
gives no such file. The owner of A86E1 added to its debt while the row held it open. The claim the commit rests on
holds at the pin: WebAssemblyISelLowering.cpp:175-181 expands SMUL_LOHI, UMUL_LOHI, MULHS, MULHU and SHL/SRA/SRL_PARTS
for i32 and i64, with UMUL_LOHI custom only under wide arithmetic (:186-191). WebAssemblyRuntimeLibcallSignatures.cpp
:103, :107, :111 and :116 give SHL_I128, SRL_I128 and SRA_I128 `i64_i64_func_i64_i64_i32` and MUL_I128
`i64_i64_func_i64_i64_i64_i64`. And ExpandIntRes_MUL (LegalizeIntegerTypes.cpp:4710) falls to `RTLIB::getMUL(VT)`
once expandMUL's OnlyLegalOrCustom fails. Fix: within A86E1's port, add compiler-rt/lib/builtins/multi3.c, ashlti3.c,
lshrti3.c and ashrti3.c to LLVM_FILES and dev/fetch_llvm.sh. Port each routine as its own definition in a src file
mirroring its path, `@parity "compiler-rt/lib/builtins/multi3.c:19 __mulddi3"`, :40 `__multi3`, ashlti3.c:21,
lshrti3.c:21 and ashrti3.c:21, over two i64 halves. ExpandIntRes_MUL (:4710) and ExpandIntRes_Shift (:5227) go in
src/llvm/legalize_integer_types.jl and call them, and the int128 arm calls those. Owner: wt3-memory.

Do the ports follow the text where they claim to: with two departures, each giving the same answer. (A87S1, low, R1,
D7) (a) Each compiler-rt shift tests `b & bits_in_dword` first and `b == 0` only inside its else (ashlti3.c:26-31,
lshrti3.c:26-31, ashrti3.c:26-32). The port hoists the zero test above both (intrinsics.jl:2081-2083, `lget(amt);
WasmBuilder.i64_eqz(b); WasmBuilder.br_if(b, blk)` before :2085's `i64_and` with 64). (b) The message says
ExpandIntRes_Shift is ported, but its first two branches are neither ported nor named. `sed -n '5235,5236p;5240,5241p'
llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp` gives `if (ConstantSDNode *CN = dyn_cast<ConstantSDNode>(N->getOperand(1)))`
/ `return ExpandShiftByConstant(N, CN->getAPIntValue(), Lo, Hi);` and `if (ExpandShiftWithKnownAmountBit(N, Lo, Hi))`.
The port takes the libcall path (:5315) for a NirConst amount too. Fix: within A87E1's port, each compiler-rt routine
in its own branch order, and ExpandIntRes_Shift's constant and known-bit branches ported or named, with their reason.
Owner: wt3-memory.

Do the cases cover shift counts 0, 63, 64 and 127, and products overflowing across the halves: yes.
test/src/code_generator_intrinsics.jl:294-296 runs Int128Cases.mulshift over six values of a (0, 1, -1, 3,
typemax(Int64), typemin(Int64)) and the amounts 0, 1, 31, 63, 64, 65, 100, 127, 128, 129, 200, -1 and -64. The amounts
reach Int64 shifts (`x << n`, `x >> n`, `u >>> n`), a UInt8 one (`n % UInt8`: 200, 255 and 192 cross the width) and a
UInt128 one (`n % UInt128`: a negative n sets the high half, which :2054-2056 tests). Every __mulddi3 line runs with
nonzero operands. `NEARTOP * Int128(a)` (:280) has a low half 2^64 - 3 whose upper 32 bits are set, against Int128(a)'s
low half, all ones for a = -1 and 0x7fff... for typemax. So multi3.c:31 and :34 contribute, though y's low half
(`BIG - n`, below 2^32) zeroes them in `x * y`. typemin(Int128) times a and the signed and unsigned products wrap past
2^128. Both halves of each result are observed (`halves`, `uhalves`). The cases run at landing (dev/check.sh:149,
test/src_tests.jl). Julia's rule for an amount of the width or more is read correctly: `sed -n 1653,1661p
src/intrinsics.cpp` at the julia pin (6d172b0) gives `CreateShl(x, uint_cnvt(ctx, t, y))` under `CreateICmpUGE(y,
... getPrimitiveSizeInBits())`, the compare at y's own width, unsigned. The port zero-extends a narrow amount after
its unsigned view (:2060-2061), so an Int8 -1 reads 255 and is the width or more, as Julia's i8 compare answers.
ifelse's widening to references (:1848-1853) emits wasm's typed select with the type (`WasmBuilder.select(b[], w)`), so a
struct operand is valid.

a5a6fa39, to the lead's questions. Is areEqualInJS a 1:1 port: yes. `git show
898a1e4b:sdk/lib/_internal/wasm/js_common/js_helper.dart | sed -n 151,152p` gives `bool areEqualInJS(WasmExternRef?
l, WasmExternRef? r) =>` / `JS<bool>("(l, r) => l === r", l, r);`, and js_helper.jl:12-13 is the same inline JS as a
foreign call to the interop module, anchored at js_helper.dart:151. Is it reached by a case: yes. js_string.jl:43-60
compiles same_in_js and differ_in_js with D.compile, beside the JS runtime, and runs each in node (1 for two JS strings
of one text made apart, 0 for two texts). Each runtime holds `: (l, r) => l === r,`. But the finding it fixes is not
fixed. (A87E2, medium, R2, D9, D12) `Fixes: A82E1` closes a finding whose substance, jl_egal's plausible false, stands.
`sed -n 1687,1688p src/intrinsics.jl` gives `if Base.iskindtype(cls) || egal_by_identity(cls) || any(f ->
host(info.struct_.fields[t.field_index[f] + 1].type), fields)` / `WasmBuilder.i32_const(b, 0)`. `grep -rn
are_equal_in_js src` gives only its definition (js_helper.jl:12). A82E1's fix read "an externref field compared by it;
until then the arm rejects, located, rather than answering". The commit message says the opposite of the code: `git
log -1 --format=%B a5a6fa39` gives "wt3-memory's arm of jl_egal for such a field rejects until it exists". js_helper.jl:8
says, in the present tense, "jl_egal compares a field holding a host reference by it". The comment above the arm
(intrinsics.jl:1550-1552) still states the false answer as dart's. So one host reference boxed twice is egal natively
and not here, as before, and a `Fixes:` line now frees the row that held it. Fix: the arm compares an externref field
by `are_equal_in_js` (a runtime root, called as jl_egal is), or rejects, located, at once. js_helper.jl:8's sentence
waits for that arm. A82E1's residue stays on a row. Owner: wt3-memory (the arm), wt3-runtime (js_helper.jl:8).

0d7a4769, read under D9: the refusal is located at generateJsMethods' anchor and names the site and both codes
(runtime_generator.jl:113). The same site with the same code in two procedures is still written once (:114).

Area: enforcement and prose — 969b1cf0 changes MARCH.md alone, as audit 86's Resolution asked. No lock or ratchet
changed in the range (`git diff --stat 47865b93..a5a6fa39 -- test/parity_ratchet.jl` gives nothing). Two commit
messages call a finding fixed whose residue stands (A87S2, A87E2). Each is caught here, not by a check: L154 frees
any row whose ID a `Fixes:` line names, so a fix called whole cannot be told from a whole fix (R2's ground).

stopgap in disguise: none new. A87S2's argument that no read reaches a null is the same reasoning A84S5 named. It is
correct today and enforced by nothing.

precedent: compiler-rt/lib/builtins at the llvm pin (7a941dfb): multi3.c:19 __mulddi3 and :40 __multi3, ashlti3.c:21,
lshrti3.c:21 and ashrti3.c:21. LegalizeIntegerTypes.cpp:4710 ExpandIntRes_MUL and :5227 ExpandIntRes_Shift (libcall
at :5315). WebAssemblyISelLowering.cpp:175-191 and WebAssemblyRuntimeLibcallSignatures.cpp:103-116. julia/src/
intrinsics.cpp:1653 (6d172b0). js_helper.dart:151 areEqualInJS and runtime_generator.dart:60 generateJsMethods at the
dart pin. type.dart:1589 _asInterfaceSubtype0 and :1651 _throwInterfaceTypeAsCheckError0.

Requirements: D1 and D7 (A87E1, A87S1). D2: d732aeb5 is differential, native the oracle, 78 cases; a5a6fa39's cases
run in node, natively unrunnable, so they check JS's answer rather than Julia's. D3: Julia's codegen hands LLVM an
i128, so LLVM's libcalls are Julia's answer, and intrinsics.cpp:1653's rule is ported. D5: small_typeof deleted, one
map (30e9397e); A86S3's six sites unchanged (`grep -rn "sizeof([a-zA-Z_]*) == 16" src` still gives six). D9 (A87E2,
A87S2; 0d7a4769 refuses across procedures). D12 (A87S3; A84S4's case reaches the path it names). D13 (median 153 s).
D40 (src flat at 3087 for 51 landings).

R1 and R2. R1: d732aeb5 ports compiler-rt's four routines faithfully, the nearest 1:1 counterpart, but it is not built
as a port. It has no anchor, no pin entry and no own file, and sits inside a dart definition (A87E1, extending A86E1),
with two departures from the text (A87S1). areEqualInJS is a 1:1 port, anchored. R2: two `Fixes:` lines call a
finding fixed whose substance stands. A82E1's plausible false is unchanged (A87E2), and A84S5's null-past-a-gap is
unchanged (A87S2). No stub is called complete, and src stays 3087 of 3404.

Resolution: this entry lands alone, prose only, and fixes nothing. A84S4 and A86S1 leave row 1.F, fixed by 30e9397e
and 0d7a4769. A84S5 leaves row 1.F, its D5 half fixed by 30e9397e and its D9 half carried as A87S2. A82E1 leaves row
1.D, its port fixed by a5a6fa39 and its arm carried as A87E2. Open, their rows the lead's to write: A87E1, A87E2 and
A87S1 for row 1.D (intrinsics, the compiler-rt ports anchored at the llvm pin, jl_egal's host arm); A87S2 and A87S3
for row 1.F (runtime and host imports). By owner: wt3-memory A87E1, A87S1 and A87E2's arm; wt3-runtime A87S2, A87S3
and A87E2's js_helper.jl:8 sentence.

## 2026-11-02 — audited through 5520cb1d (a5a6fa39..5520cb1d: ValueClasses' closure facts judged at the walk's end, a run-time type test through type.dart's _isSubtype and _asSubtype, a getfield on a Union of tuples rejected located, the runtime.jl and js_string.jl cases run through the compile)

The eighty-eighth audit, beside the work, covers the 5 commits of a5a6fa39..5520cb1d that are not audit entries
(e5ed12a3, entry 87): 8fbd1f67, 96cd8929, 1b0faed6, aea36fc5 and 5520cb1d, read under Dale's R1 and R2 as standing
sections. Standing items. Each commit names its clause. No silent catch: the 4 new catches, all in tests, each check
the RejectionError they catch. The debt list reads 370, unchanged. src reads 3087 of 3404 at every commit of the
range; the runtime library moved from 13 sites naming 9 definitions to 13 naming 11 (1b0faed6). D13: a median of
158 s; aea36fc5's 626 s was queue wait behind 1b0faed6, not the gate. Earlier findings: 8fbd1f67's rows match audit
87's Resolution. A83E1 is fixed by 96cd8929, A85E1 by aea36fc5, A87S3 by 5520cb1d. A87E2 is narrowed: js_helper.jl's
sentence is corrected, the arm at intrinsics.jl:1687 still answers false. Findings: A88E1 and A88S1 to A88S4.

Area: builder — no change under src/wasm_builder.

Area: collection and planning — 96cd8929 restores the invariants and weakens none (D11). WalkEnd is the old Done
(stack empty); SupertypeClosed and FieldsClosed are judged there again; ValuesCovered adds a Done conjunct for
records. Each Broken variant still breaks its claim, by reading the model. One narrowing: WalkEnd subtracts every
record, so the record an open tuple owes the walk is judged at Done only, no weaker than either earlier text.

Area: emission and diagnostics — (A88E1, medium, D9, R1, R2) a run-time type test answers a plausible false in two
cases. Any: rtutils.jl's link-time walk lets Any through and type.jl:150-152 compares class ids, but the type rules
skip every row whose superclass is Any (types.jl:957-958) and dart's _TopType._checkInstance (type.dart:138, `=>
true`) has no port, so `1 isa T` with T = Any known only at run time answers false. A concrete tuple type: the walk
rejects only open tuple types (rtutils.jl:123); a tuple held in a top-typed operand is its arity's TupleRecord, and
no rule puts a record under a concrete tuple class (types.jl:967-971), so `(1, 2) isa T` with T = Tuple{Int64,Int64}
answers false, where the static arm sends every tuple member to the record field check (types.jl:790). rt_isa's
types include neither. The walk itself, check_run_time_type_values, is a scan (D6): it reads NirConst operands only,
not NirGlobal values (classes.jl:72 meets those), so the claim that a program's type value is a literal is enforced
by nothing. (A88S1, low, D1, D5, R2) the run-time arm is written inline in visit_is_expression and
visit_as_expression (code_generator.jl:2201-2213, :2262-2282); in dart it is the general arm of emitIsTest and
emitAsCheck (types.dart:495-504, :586-588), whose ports at types.jl:525, :567, :812 and :828 still reject Unported
naming _isSubtype and _asSubtype, now ported. The commit lists ":97 _Type._checkInstance" among the ports while
rtutils.jl:122 counts that anchor a gap, and its switch folds dart's overrides (:111 _BottomType, :138 _TopType,
:291 _InterfaceType) under the abstract :97, which hides that :138 is missing; the Type{X} rejection names :97, not
a Julia-only row. (A88S2, low, D12) aea36fc5's union_tuple_first reaches the new rejection, replacing the Internal
the commit measured at the same read, but nothing pins it: smoke.jl:121 counts any Unported or Unquarantined green,
and the Unquarantined row names "src/intrinsics.jl generateInstanceGetterIntrinsic", a dart-anchored definition.
(A88S3, low, D12) 5520cb1d's two rewritten cases compile, with no hand-built Translator, namer or generator; the same
staging stands beside them: js_string.jl:133 builds a separate NIR for a precondition, js_string.jl:90-95 its own
InteropMemberNamer and generate_js_methods call, runtime.jl:38 its own Translator.

Area: enforcement and prose — no lock or ratchet changed. (A88S4, low, prose) 1b0faed6's subject cites A44S1, whose
substance is a type value's own fields (T.name) rejecting as Internal; the commit does not touch it and carries no
`Fixes:` line, so the row stands.

stopgap in disguise: check_run_time_type_values, the link-time walk 1b0faed6 offers as the guarantee that a program's
type value is a literal, is a scan (D6): it reads NirConst operands only, not NirGlobal values (classes.jl:72 meets
those), so the claim is enforced by nothing (A88E1).

precedent: type.dart:68, :97, :111, :138, :276, :585, :1484 and :1561 at the dart pin; types.dart:495-504 and
:586-588; kernel_nodes.dart:701 and :721; julia builtins.c:584 and :591, subtype.c:1419 and :2511.

R1: _isSubtype, _asSubtype, isDeclaredNullable and classId are 1:1 ports (type.dart:68, :276, :1484, :1561;
kernel_nodes.dart:701, :721; julia builtins.c:584, :591, subtype.c:1419, :2511); two overrides (:138 _TopType, :585 _RecordType)
are neither ported nor named (A88E1). R2: :97 is called ported while counted a gap, and two definitions with bodies
are still counted to port at their emit sites (A88S1).

Resolution: this entry lands alone, prose only. A83E1, A85E1 and A87S3 leave their rows; A87E2 stays on 1.D (the
arm). Fix first: A88E1, wt3-runtime's ahead of A87S2. 1.F: A88E1, A88S1 (wt3-cgstubs2 the general arm, wt3-runtime
the kind anchors), A88S3 (wt3-runtime) and A88S4 (A44S1's row stands). 1.E: A88S2 (wt3-tests2, wt3-cgstubs2 the row).

## 2026-11-02 — audited through 4e87b54c (5520cb1d..4e87b54c: the interface target outside the Reference sum, the tuple skip at visitDynamicGet, the plant's default-QoS refusal, @nospecializeinfer's precedent, jl_to_typeof's full table, _isTypeSubtype over _TypeUniverse.isSubtype)

The eighty-ninth audit, beside the work, covers the 6 commits of 5520cb1d..4e87b54c that are not audit entries
(d2da291c, entry 88): e20a1c46, c1dcd162, 60c269ee, 812c7779, b7f86566 and 4e87b54c, read under Dale's R1 and R2 as
standing sections. Standing items. Each commit names its clause. No silent catch: the one new catch, in a test, checks
the RejectionError it catches. The debt list reads 370 at both ends. src reads 3087 of 3404 at every commit of the
range. The runtime library reads 13 sites naming 11 at every commit, unmoved. D13: a median of 207 s; c1dcd162's 579 s
and 60c269ee's 734 s waited behind the 08:35 red on the 480-s hard limit. Earlier findings: e20a1c46 fixes A85S1,
c1dcd162 fixes A85S2, 812c7779 fixes A80S2 and b7f86566 fixes A87S2. A80S3 is narrowed: the cut's identity is shown,
its default-QoS re-read is not done. A88E1 stands; nothing in the range claims it. Findings: A89E1 and A89S1 to A89S3.

Area: builder — no change under src/wasm_builder.

Area: collection and planning — e20a1c46 leaves every match over the Reference sum exhaustive: the ten @exhaustive
matches each carry exactly a MethodInstance arm and a FieldReference arm, with no wildcard (D8); the SelectorReference
reaches only _virtual_call, call_dispatch_table and selector_for_target's own method. (A89S1, low, D5, D12)
type_value_unmade (classes.jl:27) is offered as "the one list", but it restates visitInstanceConstant's conditions
(constants.jl:810-813) and the builtin dispatch ahead of them; nothing asks the constant path itself. Its refusal at
types.jl:561-562 has no case that reaches it: runtime.jl:118-119 reaches the layout's rejection first, and its test
`occursin("AddrSpace")` matches either message. Each null entry is unreachable today: no as check against Any can
fail, and the unmade entries are read only past that refusal.

Area: emission and diagnostics — (A89E1, medium, D9, D3, R1, R2) _TypeUniverse_is_subtype (type.jl:221) answers every
pair of DataTypes from the class table, only part of Julia's DataType arm (subtype.c:1546-1590): Type{X} (:1550-1559)
and tuples (:1581, subtype_tuple :1348) have supertype Any in that table, so `Type{Int64} <: DataType` and
`Tuple{Int64,Int64} <: Tuple{Integer,Integer}` answer false where Julia answers true. dart's record rule
(type.dart:1322, applied :1440-1447) is unported, and the docstring (type.jl:202) says it has "no Julia kind here",
against classes.jl:148, where a tuple is dart's record. runtime.jl:206's 64 pairs hold neither kind. This is A88E1's
tuple half again, in a second definition. The UnionAll fallthrough (:222) is a wildcard raised at run time, not a
located rejection; the Null step (:219) cites no source. The rule order is otherwise dart's at :1351, and the Union
step matches subtype.c:1419, left before right.

Area: enforcement and prose — 60c269ee's refusal is a real check in the gate (check.sh:125), and the commit quotes it
firing under taskpolicy -b. (A89S2, low, D17) its band (tree_instructions.jl:151) borrows the background run's 2%
(:146), whose precedent is a process's first microseconds before its QoS applies: an upper bound on a background run
that says nothing about a default run's share. No reading of a default run is quoted, and a default run with every
performance core held is refused by text. (A89S3, low, prose, AGENTS.md's rule) 812c7779 says test/probe_corpus.jl
holds no probes; at its parent probe_set.jl names 105 (12b49771) and probe_baseline.txt holds 105 lines. The identity
it shows rests on an ad hoc fingerprint of 774 cases with no command in the tree, not on test/probe_bytes.jl.

stopgap in disguise: type_value_unmade, called the one list of which type values have no constant, is a second reading
of constants.jl's rejection conditions. The two can drift with nothing to tell, and its refusal is unreached (A89S1).

precedent: type.dart:974, :1322, :1351, :1440-1447, :1555, :1744 and :1759 at the dart pin; code_generator.dart:2317
visitDynamicGet; julia subtype.c:1348, :1419 and :1546-1590; julia.h:971; Compiler/src/typelattice.jl:210 and :218,
abstractinterpretation.jl:3904.

R1: _isTypeSubtype, isInterfaceSubtype and _TypeCheckVerificationError with its toString are 1:1 ports (type.dart:974,
:1555, :1744, :1759). isSubtype follows :1351's order, and its Union step is anchored at subtype.c:1419. Its Null step
and its UnionAll raise cite nothing, and the record rule (:1322) is neither ported nor named (A89E1). R2: :1351 is
called ported while its DataType arm answers Type{X} and tuple pairs with a plausible false (A89E1). b7f86566's
refusal guards a future and is called a fix with no case that reaches it (A89S1).

Resolution: this entry lands alone, prose only. A85S1, A85S2, A80S2 and A87S2 leave their rows; A80S3 stays on 1.L
(its default-QoS re-read). Fix first: A89E1, with A88E1. 1.F: A89E1, A89S1. 1.L: A89S2, A89S3.

## 2026-11-02 — audited through d995126a (4e87b54c..d995126a: the ratchet's rate at 9.2, one projection of concrete classes, Any's arm and the tuple rejections, cases reading the compile, the 128-bit expansions in src/llvm, the selector recorded by call site)

The ninetieth audit, beside the work, covers the 6 commits of 4e87b54c..d995126a that are not audit entries (7ba1fc1b,
entry 89): 293f84a5, a124256e, 827878cb, 492e0962, 32dbc45d and d995126a, read under Dale's R1 and R2 as standing
sections. Standing items. Each commit names its clause. No silent catch: the seven new catches, all in tests, check
what they catch. The debt list goes from 370 to 364, its six lines leaving at 32dbc45d (A90E1). src reads 3087 of 3404
at every commit. The runtime library reads 13 sites naming 11 at every commit, unmoved, as 492e0962 says. D13: a
median of 546 s; 32dbc45d took 7234 s from authoring, 239 s from its ship. D14: 293f84a5 changes RATE_P_RATCHET alone,
10.9 to 9.2, the lowest of its three quoted splits; D14_RED stays 140, and a lower rate judges the ratchet heavier.
Earlier findings: 827878cb fixes A88E1 and A89E1 by located rejection; 492e0962 fixes A88S3; 32dbc45d fixes A86E1,
A87E1, A86S2 and A87S1, but for A90S2; a124256e with d995126a fixes A85S3, but for A90S1. A88S1, A88S4, A89S1 and
A87E2 stand. Findings: A90E1, A90S1 to A90S4.

Area: builder — no change under src/wasm_builder.

Area: collection and planning — d995126a carries the statement index on both paths that reach the visitors,
translate_statement's NirCall arm and visitVariable's node.id; a missing index rejects Internal, located, and so does
a site build never met (dispatch_table.jl:327). FieldAccessSite's quarantine says dart keys by member
(dispatch_table.dart:399, `Map<TreeNode, …>`): honest. (A90S1, low, D5) a124256e's "all five sites" leaves the
projection whole at types.jl:803-804 and its ids-to-classes half at intrinsics.jl:1682: `grep -n "classes\[\]\[id +
1\]"` over src gives both, beside classes.jl:726. (A90S3, low, D5, prose) dispatch_table.jl:316 still says a
SelectorReference "names its selector's name and kind itself", and a member's selector (:319-330) is still found by a
scan of names, where dart's one procedureAttributeMetadata serves both (:438-443).

Area: emission and diagnostics — 827878cb's skip of a literal isa or typeassert type is sound: a NirConst's type is
Core.Typeof, Type{T} (nir.jl:833), so visit_is_expression takes emitIsTest's static arm, which answers or rejects
Unported (types.jl:530); a NirGlobal there is constant or rejected (nir.jl:840-842). No run-time isa answering a
plausible false was found. The expansions match LegalizeIntegerTypes.cpp :3905-4024 and :5227, and compiler-rt's
multi3.c and ashlti3.c, line for line. (A90S2, low, R1) legalize_integer_types.jl:172-175 says SimplifySetCC folds
only when both halves are constant, so the known-half shortcut (:5959) is never taken; but
TargetLowering.cpp:5308-5310 (X >= MIN, true) and :5348-5349 (X < MIN, false) fold with one constant. So `x <
Int128(1) << 64` takes LLVM's HiCmp-only branch, while WT emits LoCmp and the select: the same answer by a different
branch, with no case.

Area: enforcement and prose — (A90E1, medium, R1, D7, D20) 32dbc45d pins six definitions to sources that are not
ported counterparts: ANCHOR_RX, parse_anchor and REASON_ANCHOR_RX (parity.jl:1176, :1203, :1443) cite julia
base/stacktraces.jl:51 StackFrame, a struct of func, file and line that reads no string; module LLVM and LLVM_MODULES
(packages.jl:48, parity.jl:760) cite WebAssemblyUtilities.cpp:41 WebAssembly::mayThrow, an opcode switch, while the
module now holds llvm:: units (LegalizeIntegerTypes.cpp:30 `using namespace llvm`) and compiler-rt's C, neither in
that namespace; _jl_rel (:954) cites loading.jl:931 entry_path, which returns a package's entry file. Each is a shared
shape, not a near 1:1 match, and the six debt lines leave on them. (A90S4, low, D10, D12) runtime.jl:41-46 asserts on
`wasm-tools print` text, the only test/src file that does (`git grep -c`); its occursin shows that a name is in the
module, not the call the comment claims. runtime.jl:240's kind_sub matches any error naming Type{Int64}.

stopgap in disguise: the StackFrame, mayThrow and entry_path pins pass L213 and L227 and shrink the debt list by six
with no ported counterpart; the regex readers are as bespoke as before (A90E1).

precedent: class_info.dart:831, dispatch_table.dart:399 and :436-443, type.dart:97, :138, :585 and :1351 at the dart
pin; LegalizeIntegerTypes.cpp:30, :3476, :3905, :5227 and :5879-5959, TargetLowering.cpp:5308 and :5348,
WebAssemblyUtilities.cpp:41, compiler-rt multi3.c:19 and :40 and ashlti3.c:21 at the llvm pin; julia
base/stacktraces.jl:51 and base/loading.jl:931.

R1: the expansions, compiler-rt's routines, _TopType._checkInstance (type.dart:138) and concrete_classes
(class_info.dart:831) name near 1:1 counterparts. The parity.jl and packages.jl pins do not (A90E1), and one omitted
branch gives a false reason (A90S2). R2: nothing in range calls a rejection-only body ported; the tuple and Type{X}
arms reject Unported, and 827878cb names them open.

Resolution: this entry lands alone, prose only. A88E1, A89E1, A88S3, A86E1, A87E1, A86S2, A87S1 and A85S3 leave their
rows. Fix first: A90E1. 1.K: A90E1. 1.E: A90S1, A90S3. 1.D: A90S2. 1.F: A90S4.
