-------------------------------- MODULE NirBuild --------------------------------
(***************************************************************************)
(* A TLA+ model of `build_nir`/`_nir_classify`, WasmTarget's NIR boundary     *)
(* between Julia's typed CodeInfo and codegen (src/frontend/nir.jl:378-389,   *)
(* :301-370). dart2wasm's AstCodeGenerator consumes ~81 finite Kernel node    *)
(* kinds and reads every node's type through ONE StaticTypeContext, never     *)
(* re-derived per visitor (code_generator.dart:77 typeContext, :135           *)
(* getStaticType — cited verbatim in nir.jl:3-10). WT's ground truth is       *)
(* Julia's typed IR instead of Kernel; `build_nir` is the analogous ONE pass  *)
(* that builds a discriminated node per statement, once, with already-        *)
(* resolved identities as struct fields, so a consumer holding a NirNode has  *)
(* no way back to `Expr.args`.                                               *)
(*                                                                           *)
(* ABSTRACTION. One TLA+ "statement" `s \in Stmts` stands for one position    *)
(* in `code_info.code`/`ctx.nir`, statement id = position, exactly as the     *)
(* source indexes both arrays by the same `i`; `Stmts` is a set of opaque      *)
(* position tokens with an explicit successor CONSTANT (`Succ`) standing for   *)
(* "the next position", rather than a raw integer interval — TLC 2.19's `\in`/  *)
(* `=` do not tolerate comparing a string against an integer interval (a real   *)
(* TLC limitation, not a modeling choice), and every other value in this model  *)
(* is a symbolic string, so positions are kept symbolic too. `Kind[s]`       *)
(* names which real Julia statement TYPE or Expr HEAD occupies that position *)
(* (ReturnNode, GotoNode, ..., the Expr heads, or one of three representative *)
(* "outside the explicit arms" cases — see FINDING below). `RealClass(k)`     *)
(* and `HasLowering(k)`/`Documented(k)` are FIXED operators, not per-instance *)
(* CONSTANTS: they transcribe a fact about the ACTUAL source (every instance  *)
(* of this algorithm runs the same `_nir_classify`), so an MC instance cannot *)
(* quietly assert a classification the code doesn't actually produce.        *)
(* `build_nir` itself is straight-line, single-statement-at-a-time code with  *)
(* no cross-statement state (each `out[i]` is computed from `code[i]` and     *)
(* `ctx`'s already-populated maps alone) — so, mirroring ConsultChain's        *)
(* reasoning for its per-key `Walk`, each statement's build is ONE atomic     *)
(* TLA+ step, and the only genuine nondeterminism TLC explores is WHICH        *)
(* statement is built/consumed next (order-irrelevant, since no formula below *)
(* reads another statement's variables) and the bug-flag CONSTANTS.          *)
(*                                                                           *)
(* FIVE CLAIMS, one automaton state machine per statement (Diagnostics.tla's  *)
(* shape: Unbuilt -> a terminal state), one CONSTANT bug flag per claim so    *)
(* each Broken instance isolates exactly one violated invariant:              *)
(*   (1) TOTALITY       -- NoVanishing / CensusDropBug. Every statement        *)
(*       Julia's typed IR can contain classifies to exactly "Known" or        *)
(*       "Unsupported" — `_nir_classify` (nir.jl:301-370) has NO branch that   *)
(*       returns anything else: the outer dispatch's final `else` at :368      *)
(*       wraps any non-Expr/non-IR-node shape as a value via `resolve_operand`*)
(*       (itself total, its own final `else` at :251-252 wraps ANYTHING as     *)
(*       NirLiteral), and the Expr-head dispatch's final `else` at :364-365    *)
(*       wraps any unrecognized head as NirUnsupported. No head is ever        *)
(*       silently dropped INSIDE `_nir_classify` — the historical p53 bug      *)
(*       class (an early `elseif head === :dropped ... # no-op` arm            *)
(*       intercepting BEFORE that final `else`, e.g. the pre-fix               *)
(*       :throw_undef_if_not, statements.jl:557) is modeled as the             *)
(*       CensusDropBug flag: for `s \in DroppedStmts`, classification is        *)
(*       corrupted from the real "Unsupported" outcome into the illegal        *)
(*       pseudo-value "SilentNoOpAtBuild" (a value TypeOK still accepts, so     *)
(*       only NoVanishing — not TypeOK — catches it, matching how              *)
(*       Diagnostics.tla's TrapNeedsProof, not its TypeOK, catches its own      *)
(*       regression).                                                          *)
(*   (2) ALIGNMENT      -- Aligned / AlignmentBug. `build_nir`'s loop is        *)
(*       `for i in 1:n; out[i] = NirStmt(_nir_classify(code[i], ctx), ...) end` *)
(*       (nir.jl:382-387): position never shifts, INCLUDING for a statement     *)
(*       the builder cannot classify (it still gets `out[i]`, just with a       *)
(*       NirUnsupported node — see (1)). AlignmentBug models the OTHER          *)
(*       plausible bug shape: a builder that used `push!`/`continue` instead    *)
(*       of an indexed write and SKIPPED a statement it couldn't classify —      *)
(*       for every position in `ShiftedStmts`, `nir[s]` would actually describe *)
(*       `code[Succ[s]]`, and the true final statement gets no NIR entry at all  *)
(*       ("Missing").                                                            *)
(*       Every current NIR-reading consumer indexes positionally               *)
(*       (stackified.jl:157 `ctx.nir[i].node`, statements.jl:557 `ctx.nir      *)
(*       [idx].node`) — a shift like this would silently swap in the WRONG      *)
(*       statement's node at every later index.                                *)
(*   (3) IDENTITY-ONCE  -- IdentityOnce / DivergentResolveBug. `:invoke`'s      *)
(*       operand is resolved to a Method/MethodInstance identity EXACTLY        *)
(*       ONCE, in `build_nir`, via `resolve_invoke_mi`/`resolve_invoke_method` *)
(*       (nir.jl:198-208): a bare MethodInstance, or (two-tier compilation) a   *)
(*       CodeInstance whose `.def` is unwrapped. This is the R29 migration's    *)
(*       premise: invoke.jl still has ~4 DUPLICATED ad hoc sites doing the      *)
(*       identical resolution from the raw operand (e.g. invoke.jl:1469-1473,   *)
(*       `mi_or_ci isa Core.MethodInstance ? mi_or_ci : isdefined(Core,          *)
(*       :CodeInstance) && mi_or_ci isa Core.CodeInstance ? mi_or_ci.def :       *)
(*       nothing` — hand-copied, not calling nir.jl's helper) — so a consumer    *)
(*       can safely be migrated to just read `nir[s].mi` ONLY if every            *)
(*       duplicate site would have resolved the SAME identity. DivergentResolve-*)
(*       Bug models one duplicate drifting on the CodeInstance-unwrap arm (the   *)
(*       exact shape a partial copy-paste of invoke.jl:1470-1472 could miss).    *)
(*   (4) NO-RE-DERIVATION -- NoReDerivation / TypeRederiveBug. `NirSSA.         *)
(*       julia_type` and `NirStmt.julia_type` both come from `get(ctx.          *)
(*       ssa_types, id, Any)` (nir.jl:236, :384) — `ctx.ssa_types` is           *)
(*       populated ONCE by `analyze_ssa_types!` before `build_nir` runs           *)
(*       (nir.jl:373-376) and is never re-inferred; the docstrings at nir.jl:    *)
(*       41-46/216-218 name this explicitly as an R3/R5 ratchet ("NOT a new     *)
(*       get_concrete_wasm_type/infer_value_type call site"). AnalyzerType      *)
(*       models `ctx.ssa_types`, the one source of truth; RederivedType models  *)
(*       a hypothetical SECOND, independently-computed type a future edit        *)
(*       might introduce — TypeRederiveBug switches `nirType[s]` to that          *)
(*       second computation for `s \in RederiveStmts`, which R3/R5 exist          *)
(*       precisely to keep from ever landing.                                    *)
(*   (5) UNSUPPORTED-IS-LOUD -- NoSilentSwallow / ConsumerSwallowsUnsupported.   *)
(*       nir.jl's own docstring (:160-162): "A consumer MUST route this           *)
(*       [NirUnsupported] to record_unsupported! (never silently) — never          *)
(*       reinterpreted as a no-op." `ConsumeStmt` models a fully NIR-migrated       *)
(*       consumer honoring that contract (the R29 END STATE — TODAY, `grep`         *)
(*       confirms ZERO call sites anywhere pattern-match `isa NirUnsupported`,       *)
(*       so this half of the model is the target the migration is building          *)
(*       toward, not a description of an already-enforced behavior). Consumer-       *)
(*       SwallowsUnsupported models the historical failure mode directly: a          *)
(*       migrated consumer that silently treats an Unsupported node as a no-op       *)
(*       instead of rejecting.                                                       *)
(*                                                                                   *)
(* FINDING (read from the source, not the docstring — the Diagnostics.tla            *)
(* precedent: check what the code actually implements, state THAT invariant,          *)
(* not a stronger unenforced one). `_nir_classify`'s Expr-head dispatch                *)
(* (nir.jl:324-370) has explicit arms for :call/:invoke/:new/:foreigncall/             *)
(* :boundscheck/:throw_undef_if_not/:leave/:pop_exception/:the_exception — but          *)
(* NOT for :gc_preserve_begin, :gc_preserve_end, or :loopinfo. These are NOT            *)
(* exotic: `code_typed` on an ordinary `GC.@preserve` or `@simd` loop (verified          *)
(* directly against this checkout) contains them in real optimized IR, and               *)
(* statements.jl DOES lower them correctly, as legitimate no-ops, at :551-556 —           *)
(* completely independently of NIR. So today `build_nir` silently over-classifies          *)
(* three real, common, correctly-handled constructs as NirUnsupported. This is             *)
(* harmless RIGHT NOW (claim 5's consumer has zero implementations, per above) —            *)
(* but it means nir.jl's own "census" is narrower than its header comment implies,          *)
(* and it is NOT alone: :phic/:upsilon (Core.PhiCNode/Core.UpsilonNode) are EXPLICITLY       *)
(* named in nir.jl's own header as an intentional "Quarantine" returning NirUnsupported       *)
(* (nir.jl:21-24, :320-323) — yet statements.jl ALSO lowers these directly and correctly       *)
(* as legitimate no-ops, entirely outside NIR (statements.jl:380-406), by pattern-matching       *)
(* the RAW statement type, never touching `ctx.nir`. So even nir.jl's DOCUMENTED quarantine       *)
(* list is, for the same reason as the undocumented gc_preserve/loopinfo gap, a LANDMINE for        *)
(* claim (5): the day some consumer is migrated to honor "NirUnsupported => reject"                 *)
(* unconditionally (the letter of nir.jl:160-162), it will newly, incorrectly reject GC.@preserve,    *)
(* @simd, AND unoptimized-IR exception-phi code — four real constructs, not one. `HasLowering`/         *)
(* `Documented` below track this distinction (which "Unsupported" kinds have a real lowering             *)
(* elsewhere, and whether nir.jl's own header says so) but deliberately are NOT wired into a               *)
(* checked TLC invariant — doing so would fail the positive instance against the real, current              *)
(* algorithm, exactly the "never weaken an invariant to make TLC pass" trap this file's own README            *)
(* warns against in the other direction. `NoSilentSwallow` instead checks the claim the code CAN               *)
(* actually support today: a statement with NO lowering anywhere (`~HasLowering`, the p53/splatnew               *)
(* class) is never silently swallowed by a migrated consumer.                                                     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Stmts,                        \* opaque position tokens; statement id = code_info.code/ctx.nir position
    Kind,                         \* [Stmts -> Kinds] -- which real head/statement-type sits at each position
    OperandShape,                 \* [Stmts -> {"DirectMI","WrappedInCI","Neither"}] -- meaningful only where Kind[s] = "ExprInvoke"
    AnalyzerType,                 \* [Stmts -> Types] -- ctx.ssa_types[s] (populated before build_nir runs; the one source of truth)
    RederivedType,                \* [Stmts -> Types] -- a hypothetical SECOND, independently-computed type (TypeRederiveBug only)
    DroppedStmts,                 \* SUBSET Stmts -- Unsupported-kind statements CensusDropBug corrupts into a silent no-op
    RederiveStmts,                \* SUBSET Stmts -- statements TypeRederiveBug corrupts
    SwallowStmts,                 \* SUBSET Stmts -- Unsupported-kind statements ConsumerSwallowsUnsupported corrupts
    ShiftedStmts,                 \* SUBSET Stmts -- AlignmentBug shifts every position in this set
    Succ,                         \* [Stmts -> Stmts \cup {"Missing"}] -- the position immediately after s ("Missing" for the last one)
    CensusDropBug,                \* BOOLEAN -- inject the p53-class census-drop-to-no-op bug
    AlignmentBug,                 \* BOOLEAN -- inject the position-skip bug
    DivergentResolveBug,          \* BOOLEAN -- inject a duplicated invoke-resolution site that disagrees with resolve_invoke_mi
    TypeRederiveBug,              \* BOOLEAN -- inject a second, independent type computation that disagrees with ctx.ssa_types
    ConsumerSwallowsUnsupported   \* BOOLEAN -- inject a migrated consumer that treats NirUnsupported as a no-op

----------------------------------------------------------------------------
(* The census, read directly from nir.jl:301-370 -- fixed facts about the      *)
(* algorithm, not per-instance data (see header). *)

Kinds == {
    "ReturnNode", "GotoNode", "GotoIfNot", "PhiNode", "PiNode", "EnterNode",
    "PhiCNode", "UpsilonNode",
    "ExprCall", "ExprInvoke", "ExprNew", "ExprForeigncall", "ExprBoundscheck",
    "ExprThrowUndefIfNot", "ExprLeave", "ExprPopException", "ExprTheException",
    "PlainValue",
    "ExprGcPreserveBegin", "ExprGcPreserveEnd", "ExprLoopinfo", "ExprSplatnew"
}

(* RealClass(k): `_nir_classify`'s actual, as-read outcome for kind k.          *)
(* "Known" = an explicit arm returns a non-NirUnsupported node. "Unsupported" = *)
(* the kind reaches one of the two documented quarantine arms (:320-323) or the *)
(* Expr `else` (:364-365) and is wrapped as NirUnsupported. *)
RealClass(k) ==
    CASE k = "PhiCNode"            -> "Unsupported"  \* nir.jl:320-321, documented quarantine (nir.jl:21-24)
      [] k = "UpsilonNode"         -> "Unsupported"  \* nir.jl:322-323, documented quarantine (nir.jl:21-24)
      [] k = "ExprGcPreserveBegin" -> "Unsupported"  \* no arm (nir.jl:324-363) -> Expr `else` (nir.jl:364-365) -- UNDOCUMENTED gap, see FINDING
      [] k = "ExprGcPreserveEnd"   -> "Unsupported"  \* ditto
      [] k = "ExprLoopinfo"        -> "Unsupported"  \* ditto
      [] k = "ExprSplatnew"        -> "Unsupported"  \* no arm, no lowering anywhere -- the p53 class
      [] OTHER                     -> "Known"

(* HasLowering(k): does a CORRECT lowering exist ANYWHERE in the compiler for   *)
(* this kind -- nir.jl's own Known arm, OR a raw-dispatch handler entirely       *)
(* outside NIR (PhiCNode/UpsilonNode: statements.jl:380-406; gc_preserve_begin/  *)
(* end: statements.jl:551-554; loopinfo: statements.jl:555-556)? Ground truth    *)
(* about the WIDER compiler, independent of what `_nir_classify` itself returns *)
(* -- deliberately NOT wired into a checked invariant (see FINDING). *)
HasLowering(k) == k # "ExprSplatnew"

(* Documented(k): does nir.jl's own header (:21-24) name this kind as an        *)
(* intentional quarantine case? Only PhiCNode/UpsilonNode are -- the            *)
(* gc_preserve/loopinfo gap reaches the identical Unsupported outcome           *)
(* UNDOCUMENTED (see FINDING). Informational only, like Diagnostics.tla's       *)
(* tracked-but-unenforced Kind/CallerHint fields. *)
Documented(k) == k \in {"PhiCNode", "UpsilonNode"}

----------------------------------------------------------------------------
(* Per-statement pure computations -- each is ONE atomic Julia function call,   *)
(* reading only CONSTANTS and this statement's own id (see header on why        *)
(* cross-statement interleaving is irrelevant here). *)

(* `_nir_classify`'s real outcome, corrupted by CensusDropBug for its chosen    *)
(* targets into the illegal "silently a no-op" pseudo-value TypeOK still         *)
(* accepts (see NoVanishing). *)
ClassifyOf(s) ==
    IF CensusDropBug /\ s \in DroppedStmts
    THEN "SilentNoOpAtBuild"
    ELSE RealClass(Kind[s])

(* `resolve_invoke_mi` (nir.jl:198-202): a bare MethodInstance stands as-is; a   *)
(* CodeInstance is unwrapped via `.def`. Never buggy -- this IS the canonical,   *)
(* single implementation nir.jl centralizes; the bug lives only in a DUPLICATE  *)
(* (see DuplicatedResolve). *)
CanonicalResolve(shape) ==
    CASE shape = "DirectMI"    -> "MI_A"
      [] shape = "WrappedInCI" -> "MI_A"
      [] shape = "Neither"     -> "NoIdentity"

ResolveOf(s) == IF Kind[s] = "ExprInvoke" THEN CanonicalResolve(OperandShape[s]) ELSE "NotApplicable"

(* A hypothetical duplicated resolution site (invoke.jl's own ~4 sites, e.g.     *)
(* :1469-1473) computing the SAME identity independently from the raw operand,   *)
(* instead of reading `nir[s].mi`. Correct by construction unless                *)
(* DivergentResolveBug flips the CodeInstance-unwrap arm -- the exact plausible  *)
(* drift a partial copy of invoke.jl:1470-1472 could introduce. *)
DuplicatedResolve(shape) ==
    CASE shape = "DirectMI"    -> "MI_A"
      [] shape = "WrappedInCI" -> IF DivergentResolveBug THEN "NoIdentity" ELSE "MI_A"
      [] shape = "Neither"     -> "NoIdentity"

ConsumerResolveOf(s) == IF Kind[s] = "ExprInvoke" THEN DuplicatedResolve(OperandShape[s]) ELSE "NotApplicable"

(* `get(ctx.ssa_types, i, Any)` (nir.jl:236, :384): the analyzer's answer,       *)
(* never re-derived -- corrupted by TypeRederiveBug for its chosen targets. *)
TypeOf(s) == IF TypeRederiveBug /\ s \in RederiveStmts THEN RederivedType[s] ELSE AnalyzerType[s]

(* `out[i] = ...` (nir.jl:382-387): position s always describes position s.     *)
(* AlignmentBug shifts every position in ShiftedStmts to describe its successor  *)
(* instead, mirroring a builder that skipped one statement instead of writing    *)
(* it at its own index; `Succ` already yields "Missing" for the true last         *)
(* statement (it never gets a NIR entry at all). *)
PosOf(s) ==
    IF AlignmentBug /\ s \in ShiftedStmts
    THEN Succ[s]
    ELSE s

----------------------------------------------------------------------------
VARIABLES
    state,         \* [Stmts -> States] -- this statement's progress
    classKind,     \* [Stmts -> {"Unset","Known","Unsupported","SilentNoOpAtBuild"}] -- set once processed
    resolvedId,    \* [Stmts -> {"Unset","MI_A","NoIdentity","NotApplicable"}] -- set once processed
    nirType,       \* [Stmts -> Types \cup {"Unset"}] -- set once processed
    describesPos,  \* [Stmts -> Stmts \cup {"Unset","Missing"}] -- set once processed
    ledger         \* SUBSET Stmts -- statements a consumer has routed to record_unsupported!

vars == <<state, classKind, resolvedId, nirType, describesPos, ledger>>

States == {"Unbuilt", "EmittedFromNir", "Rejected", "SilentNoOpAtConsume"}

TypeOK ==
    /\ state \in [Stmts -> States]
    /\ classKind \in [Stmts -> {"Unset", "Known", "Unsupported", "SilentNoOpAtBuild"}]
    /\ resolvedId \in [Stmts -> {"Unset", "MI_A", "NoIdentity", "NotApplicable"}]
    /\ DOMAIN nirType = Stmts
    /\ \A s \in Stmts : nirType[s] \in {"Unset", AnalyzerType[s], RederivedType[s]}
    /\ describesPos \in [Stmts -> Stmts \cup {"Unset", "Missing"}]
    /\ ledger \subseteq Stmts

Init ==
    /\ state = [s \in Stmts |-> "Unbuilt"]
    /\ classKind = [s \in Stmts |-> "Unset"]
    /\ resolvedId = [s \in Stmts |-> "Unset"]
    /\ nirType = [s \in Stmts |-> "Unset"]
    /\ describesPos = [s \in Stmts |-> "Unset"]
    /\ ledger = {}

----------------------------------------------------------------------------
(* `build_nir`'s per-statement write (the for-loop body at nir.jl:382-387)      *)
(* immediately followed by a fully NIR-migrated consumer's handling (the R29    *)
(* end state -- header claim (5)): a "Known" node is emitted directly; an       *)
(* "Unsupported" node is routed to record_unsupported! UNLESS                   *)
(* ConsumerSwallowsUnsupported corrupts this statement into the historical      *)
(* silent-no-op failure mode. ONE atomic TLA+ step per statement -- mirroring    *)
(* ConsultChain.tla's `ProcessKey` (build_nir's write, like `compile_call!`'s    *)
(* per-key walk, is straight-line single-statement code with no genuine          *)
(* concurrency to expose WITHIN one statement, and splitting build from consume  *)
(* into separate TLC-visible steps would only inflate the state space without    *)
(* changing which interleavings are observable -- no invariant below depends     *)
(* on another statement's progress between a statement's own build and its own   *)
(* consumption). *)
ProcessStmt(s) ==
    LET ck == ClassifyOf(s)
        swallowed == ConsumerSwallowsUnsupported /\ s \in SwallowStmts
    IN
    /\ state[s] = "Unbuilt"
    /\ classKind' = [classKind EXCEPT ![s] = ck]
    /\ resolvedId' = [resolvedId EXCEPT ![s] = ResolveOf(s)]
    /\ nirType' = [nirType EXCEPT ![s] = TypeOf(s)]
    /\ describesPos' = [describesPos EXCEPT ![s] = PosOf(s)]
    /\ state' = [state EXCEPT ![s] =
                    IF ck = "Unsupported"
                    THEN (IF swallowed THEN "SilentNoOpAtConsume" ELSE "Rejected")
                    ELSE "EmittedFromNir"]
    /\ ledger' = IF (ck = "Unsupported" /\ ~swallowed) THEN ledger \cup {s} ELSE ledger

Next == \E s \in Stmts : ProcessStmt(s)

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

----------------------------------------------------------------------------
(* Claims. *)

(* (1) TOTALITY: `_nir_classify` never produces anything outside {"Known",       *)
(* "Unsupported"} -- the pseudo-value CensusDropBug injects is the ONLY way      *)
(* to reach a third outcome. *)
NoVanishing == \A s \in Stmts : state[s] # "Unbuilt" => classKind[s] \in {"Known", "Unsupported"}

(* (2) ALIGNMENT: `nir[s]` always describes `code[s]`. *)
Aligned == \A s \in Stmts : state[s] # "Unbuilt" => describesPos[s] = s

(* (3) IDENTITY-ONCE: the once-resolved invoke identity equals what any          *)
(* independent re-derivation from the raw operand would compute -- the R29       *)
(* migration's premise that a consumer never needs the raw statement to be       *)
(* correct. *)
IdentityOnce == \A s \in Stmts :
    (state[s] # "Unbuilt" /\ Kind[s] = "ExprInvoke") => ConsumerResolveOf(s) = resolvedId[s]

(* (4) NO-RE-DERIVATION: the static type nir carries is always the analyzer's    *)
(* (ctx.ssa_types), never a second, independent computation. *)
NoReDerivation == \A s \in Stmts : state[s] # "Unbuilt" => nirType[s] = AnalyzerType[s]

(* (5) UNSUPPORTED-IS-LOUD, the invariant the algorithm can actually support     *)
(* today (see FINDING -- NOT the unconditional "every Unsupported kind must       *)
(* reject", which is false today for the documented quarantine AND the           *)
(* gc_preserve/loopinfo gap alike): a statement with NO lowering ANYWHERE is      *)
(* never silently treated as a no-op by a migrated consumer. *)
NoSilentSwallow == \A s \in Stmts :
    state[s] = "SilentNoOpAtConsume" => HasLowering(Kind[s])

(* Every statement a consumer actually rejected carries a ledger record          *)
(* (mirrors Diagnostics.tla's LedgerComplete). *)
LedgerComplete == \A s \in Stmts : state[s] = "Rejected" => s \in ledger

----------------------------------------------------------------------------
(* Liveness: every statement eventually reaches a terminal state. *)
AllDone == \A s \in Stmts : state[s] \in {"EmittedFromNir", "Rejected", "SilentNoOpAtConsume"}
EventuallyAllDone == <>AllDone

=============================================================================
