------------------------------ MODULE Diagnostics -------------------------------
(***************************************************************************)
(* A TLA+ model of WasmTarget's correct-or-loud two-tier diagnostics funnel, *)
(* `record_unsupported!` (src/codegen/diagnostics.jl), plus the emission-     *)
(* ordering discipline its two eval/readline call sites establish            *)
(* (src/codegen/invoke.jl `compile_invoke!`, src/codegen/statements.jl        *)
(* `_task_ssa_used_unsafely`). dart2wasm's equivalent split is a structured    *)
(* `DiagnosticReporter.report(...)` at the AST boundary (target.dart:719-751, *)
(* wasm_library_checks.dart) versus intrinsics.dart's internal                *)
(* `throw StateError('Unhandled ... intrinsic')` deep inside lowering — WT's   *)
(* claim is that the FIRST tier is always what answers an unsupported          *)
(* construct, never the second.                                               *)
(*                                                                           *)
(* ABSTRACTION. One TLA+ "statement" `t \in Stmts` stands for one SSA          *)
(* statement/call site reaching codegen. Real `record_unsupported!` is a       *)
(* single sequential Julia function: it unconditionally pushes a               *)
(* `WasmDiagnostic` onto `ctx.diagnostics` (and mirrors it to                  *)
(* `DIAGNOSTICS_SINK` when the caller supplied one — that mirroring is a       *)
(* strict superset of the `ctx.diagnostics` write and adds no new decision,    *)
(* so only the always-populated ledger is modeled), THEN resolves `fatal` and  *)
(* either throws `WasmCompileError` or warns-and-returns. We split that one    *)
(* function call into two atomic TLA+ steps, `RecordDiagnostic` (the           *)
(* unconditional ledger write) followed immediately by `ResolveFatal` (the     *)
(* throw-or-return branch), because TLC's interleaving semantics need two      *)
(* named actions to state "the ledger write always precedes the branch" as an  *)
(* invariant (`LedgerComplete`) rather than an assumption; nothing else can     *)
(* interleave between them for a given `t`; no other statement's actions        *)
(* touch statement t's own progress, so this split changes nothing              *)
(* observable. That is sufficient for the algorithmic claims below, which are  *)
(* about which TERMINAL state each statement reaches and whether the ledger    *)
(* covers it — not about scheduling nondeterminism within one Julia call.      *)
(*                                                                           *)
(* Two static facts are fixed per statement (computed once, before codegen     *)
(* runs, exactly as in the source): `ProvenDead[t]` mirrors                    *)
(* `stmt_is_proven_unreachable(ctx.code_info.code, idx)` — a CFG reachability   *)
(* analysis over the *caller's own* Julia IR, independent of `t`'s kind — and  *)
(* `ClassifyAtBoundary[t]` records whether `t`'s call site performs its         *)
(* unsupported-ness check BEFORE attempting to emit/recurse into anything      *)
(* (true of essentially every direct `record_unsupported!`/                    *)
(* `emit_unsupported_stub!` call site, because the funnel is only ever         *)
(* reached via an `if name === :foo ... record_unsupported!` pattern-match      *)
(* that runs before any bytes are written — and, since Phase 6.2, TRUE ALSO    *)
(* for the two call sites that used to recurse first: `Core.eval`, rejected     *)
(* by MethodInstance identity at invoke.jl:825-834 before compiling its body,   *)
(* and `jl_get_current_task` misuse in readline's IOStream lock path, rejected  *)
(* by the static `_task_ssa_used_unsafely` scan at statements.jl:1262 before     *)
(* the phantom-task value is ever asked to produce bytes).                      *)
(*                                                                           *)
(* FINDING (read from the source, not the docstring): `record_unsupported!`'s   *)
(* own `fatal` formula never inspects `kind`. The docstring above it claims     *)
(* `:value_stub` is "unsound regardless of reachability, so it throws" —        *)
(* unconditionally — but of the 13 direct `:value_stub` call sites in the       *)
(* source (statements.jl, calls.jl, values.jl), only 7 pass                     *)
(* `soundness_fatal=true`; the other 6 (struct-field-undefined, memset,         *)
(* objectid, jl_id_start_char/jl_id_char, constant-exception-undefined-field)    *)
(* pass no override and so fall through to the SAME reachability-gated          *)
(* default every `:unsupported_method`/`:unsupported_type` call gets via        *)
(* `emit_unsupported_stub!` (whose own default argument makes it collapse to     *)
(* the identical `!stmt_is_proven_unreachable` gate — grep confirms zero call    *)
(* sites anywhere override it). This is still SOUND — a block the CFG proves     *)
(* dead never executes, so a wrong-value stub placed there is never observed,    *)
(* regardless of kind — but it means "kind ≠ value_stub" is not the real         *)
(* invariant the funnel enforces; "provenDead" is. This model checks the         *)
(* invariant the code actually implements (`TrapNeedsProof`, kind-independent)   *)
(* rather than the docstring's stronger, unenforced claim; per-statement kind    *)
(* and caller-hint are still tracked (as `Kind`/`CallerHint`) so the ledger and   *)
(* TypeOK stay faithful to `WasmDiagnostic`'s real shape, and so the instance     *)
(* can exhibit both the 7-site and 6-site conventions side by side.              *)
(*                                                                           *)
(* Two independent regression classes, each gated by its own boolean CONSTANT   *)
(* "flag that disables one step" (MODEL_RULES): `AllowTrapWithoutProof`          *)
(* models a hypothetical earlier `record_unsupported!` that permitted a          *)
(* Default-hint statement to resolve non-fatal WITHOUT the                       *)
(* `stmt_is_proven_unreachable` gate — the class of bug where compile-time        *)
(* rejection of live unsupported code silently degrades into a runtime trap.      *)
(* `ClassifyAfterEmit` models reverting the Phase 6.2 fix: emission is             *)
(* attempted before classification for every non-normal statement, so the         *)
(* funnel is never reached at all and the InstrBuilder's own stack-shape           *)
(* validator (`StackImbalanceError`, builder/instr_builder.jl) is what answers     *)
(* the unsupported construct instead — exactly what                                *)
(* test/capability_negative_controls.jl's D3 (readline) and D9 (eval) regress      *)
(* against (`!(err isa WasmTarget.StackImbalanceError)`).                          *)
(***************************************************************************)
CONSTANTS
    Stmts,                  \* small set of statement/call-site ids reaching codegen
    Kind,                    \* Stmts -> {"normal","value_stub","unsupported_method"} -- WasmDiagnostic.kind ("normal" = fully handled, never enters the funnel)
    CallerHint,              \* Stmts -> {"ForceReject","Default"} -- the call site's `soundness_fatal` argument: TRUE ("ForceReject") or nothing ("Default")
    ProvenDead,              \* Stmts -> BOOLEAN -- stmt_is_proven_unreachable(ctx.code_info.code, idx) for t's statement
    ClassifyAtBoundary,      \* Stmts -> BOOLEAN -- this call site checks unsupported-ness before attempting emission (true of every current call site; see header)
    AllowTrapWithoutProof,   \* BOOLEAN -- broken-variant flag: Default-hint statements resolve non-fatal unconditionally, ignoring ProvenDead
    ClassifyAfterEmit        \* BOOLEAN -- broken-variant flag: forces every non-normal statement's ordering to "emit first", overriding ClassifyAtBoundary

VARIABLES
    state,   \* state[t] \in States -- this statement's position in the funnel
    ledger   \* SUBSET Stmts -- models ctx.diagnostics: statements with a WasmDiagnostic recorded

vars == <<state, ledger>>

States == {"Lowering", "UnsupportedSeen", "ClassifiedReject", "ProvenDeadTrap", "EmittedValue", "InternalError"}
Kinds == {"normal", "value_stub", "unsupported_method"}
Hints == {"ForceReject", "Default"}

TypeOK ==
    /\ state \in [Stmts -> States]
    /\ ledger \subseteq Stmts
    /\ Kind \in [Stmts -> Kinds]
    /\ CallerHint \in [Stmts -> Hints]
    /\ ProvenDead \in [Stmts -> BOOLEAN]
    /\ ClassifyAtBoundary \in [Stmts -> BOOLEAN]
    /\ AllowTrapWithoutProof \in BOOLEAN
    /\ ClassifyAfterEmit \in BOOLEAN

Init ==
    /\ state = [t \in Stmts |-> "Lowering"]
    /\ ledger = {}

----------------------------------------------------------------------------
(* `fatal = soundness_fatal === nothing ? !stmt_is_proven_unreachable(...) :   *)
(* soundness_fatal` (diagnostics.jl, `record_unsupported!`). `AllowTrapWithout- *)
(* Proof` disables the `!ProvenDead[t]` half of that ternary for Default-hint   *)
(* statements -- the "regardless of reachability" gate the (unenforced) kind-   *)
(* based docstring claim was trying to describe.                               *)
Fatal(t) ==
    IF CallerHint[t] = "ForceReject"
    THEN TRUE
    ELSE IF AllowTrapWithoutProof
         THEN FALSE
         ELSE ~ProvenDead[t]

(* Phase 6.2: a statement's unsupported-ness is checked before any emission     *)
(* is attempted. `ClassifyAfterEmit` is the global revert of that fix.          *)
ClassifiesFirst(t) == ClassifyAtBoundary[t] /\ ~ClassifyAfterEmit

----------------------------------------------------------------------------
(* A fully-handled ("normal") statement emits its value directly and never      *)
(* touches the funnel or the ledger. *)
EmitNormal(t) ==
    /\ state[t] = "Lowering"
    /\ Kind[t] = "normal"
    /\ state' = [state EXCEPT ![t] = "EmittedValue"]
    /\ UNCHANGED ledger

(* record_unsupported!'s unconditional `push!(ctx.diagnostics, diag)` (and the  *)
(* DIAGNOSTICS_SINK mirror, abstracted away -- see header). *)
RecordDiagnostic(t) ==
    /\ state[t] = "Lowering"
    /\ Kind[t] # "normal"
    /\ ClassifiesFirst(t)
    /\ state' = [state EXCEPT ![t] = "UnsupportedSeen"]
    /\ ledger' = ledger \cup {t}

(* record_unsupported!'s throw-or-warn branch. *)
ResolveFatal(t) ==
    /\ state[t] = "UnsupportedSeen"
    /\ state' = [state EXCEPT ![t] = IF Fatal(t) THEN "ClassifiedReject" ELSE "ProvenDeadTrap"]
    /\ UNCHANGED ledger

(* The pre-Phase-6.2 bug class: emission is attempted for an unsupported        *)
(* construct without ever calling record_unsupported! first, and the            *)
(* InstrBuilder's own stack-shape validator is what eventually answers it       *)
(* (StackImbalanceError) -- with no WasmDiagnostic, no source attribution, and   *)
(* no ledger entry. *)
EmitUnsupportedBypassed(t) ==
    /\ state[t] = "Lowering"
    /\ Kind[t] # "normal"
    /\ ~ClassifiesFirst(t)
    /\ state' = [state EXCEPT ![t] = "InternalError"]
    /\ UNCHANGED ledger

Next == \E t \in Stmts : EmitNormal(t) \/ RecordDiagnostic(t) \/ ResolveFatal(t) \/ EmitUnsupportedBypassed(t)

Spec == Init /\ [][Next]_vars /\ \A t \in Stmts : WF_vars(ResolveFatal(t))

----------------------------------------------------------------------------
(* Invariants. *)

(* No path from having recorded a diagnostic reaches a state that emits a      *)
(* value as though nothing were wrong -- the whole point of the funnel.        *)
NoSilentValue == \A t \in Stmts : t \in ledger => state[t] # "EmittedValue"

(* A validating trap is retained only where the CFG actually proves the        *)
(* statement dead -- kind-independent (see the FINDING in the header): this    *)
(* is the invariant the funnel really enforces, not the stronger,               *)
(* kind-gated one its docstring claims. *)
TrapNeedsProof == \A t \in Stmts : state[t] = "ProvenDeadTrap" => ProvenDead[t]

(* An unsupported construct is never answered by the internal builder          *)
(* invariant (StackImbalanceError) -- it is always classified first. *)
InternalNeverTerminal == \A t \in Stmts : state[t] # "InternalError"

(* Every classified terminal (reject or trap) has a ledger record. *)
LedgerComplete == \A t \in Stmts : state[t] \in {"ClassifiedReject", "ProvenDeadTrap"} => t \in ledger

----------------------------------------------------------------------------
(* Liveness: classification never gets stuck. *)
NoStuckUnsupported ==
    \A t \in Stmts : (state[t] = "UnsupportedSeen") ~> (state[t] \in {"ClassifiedReject", "ProvenDeadTrap"})

=============================================================================
