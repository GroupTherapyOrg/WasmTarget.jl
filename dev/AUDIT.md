# The anti-drift audit log

The locks check what they measure; drift hides in what none of them counts. So the work
pauses at every session start and at most every 5 commits for a full audit against
`dev/CHARTER.md` (AGENTS.md, "The anti-drift audit"), and records it here. L148 fails when
the last entry is more than 5 commits behind HEAD or an entry leaves out an area.

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
4. Fix the findings before new work. Record the entry: the range, one `Area:` paragraph per
   area with its findings, and a `Resolution:` for each finding (the commit that fixed it,
   or the MARCH item and ratchet that now carry it).

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
array, a Memory or a struct's or tuple's fields, mutable ones included, each object once. It skips a module and Core's
TypeName, MethodTable, TypeMapEntry, TypeMapLevel, Method, MethodInstance, CodeInstance, CodeInfo,
Binding and SimpleVector: none is a value a program reads out of a constant, walking them reached
the whole method graph, and a constant SimpleVector does not compile yet (MARCH 13.17 A11 svec); a
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
