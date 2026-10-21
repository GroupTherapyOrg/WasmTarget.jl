# The anti-drift audit log

The locks check what they measure; drift hides in what none of them counts. So the work
pauses at every session start and at most every 5 commits for a full audit against
`dev/CHARTER.md` (AGENTS.md, "The anti-drift audit"), and records it here. L148 fails when
the entries do not chain (an entry's range must start at the commit the entry before it was
audited through, and every audited-through commit must be an ancestor of HEAD), when the
last entry is more than 5 commits behind HEAD (merges not counted), or when an entry leaves
out an area or a `Resolution:`.

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
