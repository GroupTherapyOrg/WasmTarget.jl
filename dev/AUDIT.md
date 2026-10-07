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
found. A5B4, A5C3, A5E10: measured correct; smoke kind_and_class_rows pins it. A5B5: the anchor.
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
to wrong answers (typeof, `===`, an Any vector's isa). Smoke group type_isa: the old
lowering answers 2 and -7 where native answers 1; xfail type_or_nothing_isa, which the old
lowering answered wrong, rejects.
