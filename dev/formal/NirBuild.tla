-------------------------------- MODULE NirBuild --------------------------------
(***************************************************************************)
(* A TLA+ model of `build_nir`/`_nir_classify`, WasmTarget's NIR boundary     *)
(* between Julia's typed CodeInfo and codegen (src/frontend/nir.jl:529-553,   *)
(* :455-520). dart2wasm's AstCodeGenerator consumes ~81 finite Kernel node    *)
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
(* no cross-statement state (each `out[i]` is computed from `code[i]` and the *)
(* CodeInfo's own type/line tables alone) — so, mirroring ConsultChain's      *)
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
(*       "Unsupported" — `_nir_classify` (nir.jl:455-520) has NO branch that   *)
(*       returns anything else: the outer dispatch's final `else` at :517      *)
(*       wraps any non-Expr/non-IR-node shape as a value via `resolve_operand`*)
(*       (itself total, its own final `else` at :344-345 wraps ANYTHING as     *)
(*       NirLiteral), and the Expr-head dispatch's final `else` at :514-515    *)
(*       wraps any unrecognized head as NirUnsupported. No head is ever        *)
(*       silently dropped INSIDE `_nir_classify` — the historical p53 bug      *)
(*       class (an early `elseif head === :dropped ... # no-op` arm            *)
(*       intercepting BEFORE that final `else`, e.g. the pre-fix               *)
(*       :throw_undef_if_not) is modeled as the                                *)
(*       CensusDropBug flag: for `s \in DroppedStmts`, classification is        *)
(*       corrupted from the real "Unsupported" outcome into the illegal        *)
(*       pseudo-value "SilentNoOpAtBuild" (a value TypeOK still accepts, so     *)
(*       only NoVanishing — not TypeOK — catches it, matching how              *)
(*       Diagnostics.tla's TrapNeedsProof, not its TypeOK, catches its own      *)
(*       regression).                                                          *)
(*   (2) ALIGNMENT      -- Aligned / AlignmentBug. `build_nir`'s loop is        *)
(*       `for i in 1:n; out[i] = NirStmt(_nir_classify(code[i], …), …) end` *)
(*       (nir.jl:546-549): position never shifts, INCLUDING for a statement     *)
(*       the builder cannot classify (it still gets `out[i]`, just with a       *)
(*       NirUnsupported node — see (1)). AlignmentBug models the OTHER          *)
(*       plausible bug shape: a builder that used `push!`/`continue` instead    *)
(*       of an indexed write and SKIPPED a statement it couldn't classify —      *)
(*       for every position in `ShiftedStmts`, `nir[s]` would actually describe *)
(*       `code[Succ[s]]`, and the true final statement gets no NIR entry at all  *)
(*       ("Missing").                                                            *)
(*       Every current NIR-reading consumer indexes positionally               *)
(*       (stackified.jl:254 `ctx.nir[i].node`, statements.jl's compile_state-   *)
(*       ment! dispatch) — a shift like this would silently swap in the WRONG   *)
(*       statement's node at every later index.                                *)
(*   (3) IDENTITY-ONCE  -- IdentityOnce / DivergentResolveBug. `:invoke`'s      *)
(*       operand is resolved to a Method/MethodInstance identity EXACTLY        *)
(*       ONCE, in `build_nir`, via `resolve_invoke_mi`/`resolve_invoke_method` *)
(*       (nir.jl:252-262): a bare MethodInstance, or (two-tier compilation) a   *)
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
(*       julia_type` and `NirStmt.julia_type` both come from ONE widening of    *)
(*       Julia INFERENCE's own answer, `_widened_ssa_types` (nir.jl:310-320):   *)
(*       `widenconst(code_info.ssavaluetypes[i])`, `Any` where inference had     *)
(*       nothing. `build_nir` takes no context and runs BEFORE the analysis      *)
(*       passes (which are themselves NIR consumers), so there is no second      *)
(*       type source it could consult; the docstrings at nir.jl:53-56/:522-527   *)
(*       name this explicitly as an R3/R5 ratchet ("0 new get_concrete_wasm_     *)
(*       type/infer_value_type call sites"). AnalyzerType models that one         *)
(*       widened inference answer, the single source of truth; RederivedType     *)
(*       models a hypothetical SECOND, independently-computed type a future edit  *)
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
(* FINDING (raised 2026-09-02, CLOSED by the Phase 12.D statements.jl migration).      *)
(* Read from the source, not the docstring — the Diagnostics.tla precedent: check      *)
(* what the code actually implements, state THAT invariant, not a stronger unenforced  *)
(* one. `_nir_classify`'s Expr-head dispatch used to have explicit arms for            *)
(* :call/:invoke/:new/:foreigncall/:boundscheck/:throw_undef_if_not/:leave/            *)
(* :pop_exception/:the_exception — but NOT for :gc_preserve_begin, :gc_preserve_end,   *)
(* or :loopinfo. These are NOT exotic: `code_typed` on an ordinary `GC.@preserve` or   *)
(* `@simd` loop (verified directly against this checkout) contains them in real        *)
(* optimized IR, and statements.jl DOES lower them correctly, as legitimate no-ops —   *)
(* it did so completely independently of NIR. So `build_nir` silently over-classified  *)
(* three real, common, correctly-handled constructs as NirUnsupported; and it was NOT  *)
(* alone — :phic/:upsilon (Core.PhiCNode/Core.UpsilonNode) were named in nir.jl's own  *)
(* header as an intentional "Quarantine" returning NirUnsupported, yet statements.jl   *)
(* ALSO lowered these directly and correctly (Upsilon is a real `local.set`, not even  *)
(* a no-op), by pattern-matching the RAW statement type. Harmless while claim (5)'s    *)
(* consumer had zero implementations — a LANDMINE the moment one appeared: the day a   *)
(* consumer honors "NirUnsupported => reject" unconditionally (the letter of           *)
(* nir.jl's NirUnsupported docstring) it would newly, incorrectly reject GC.@preserve, *)
(* @simd, AND unoptimized-IR exception-phi code. Phase 12.D migrated exactly such a    *)
(* consumer (compile_statement! dispatches on `ctx.nir[idx].node`), so the census was  *)
(* CLOSED first, in this model and then in the code: NirNewvar/NirNoOp/NirUpsilon/     *)
(* NirPhiC are classified quarantine-tier nodes with real lowerings, and the only      *)
(* kind still reaching NirUnsupported is one with no lowering anywhere (the            *)
(* p53/splatnew class). `RealClass` below records that; `HasLowering`/`Documented`     *)
(* keep tracking the distinction the finding turned on (which "Unsupported" kinds have *)
(* a real lowering elsewhere, and whether nir.jl's own header says so) and remain      *)
(* deliberately NOT wired into a checked TLC invariant — an invariant is stated over   *)
(* what the code implements, never strengthened past it to make a point.               *)
(* `NoSilentSwallow` checks the claim the code supports: a statement with NO lowering  *)
(* anywhere (`~HasLowering`) is never silently swallowed by a migrated consumer.       *)
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
(* The census, read directly from nir.jl:455-520 -- fixed facts about the      *)
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
(* the kind reaches the Expr `else` (nir.jl:514-515) and is wrapped as          *)
(* NirUnsupported. Since the FINDING was closed, exactly ONE modeled kind does: *)
(* every construct with a real lowering is classified, quarantine tier included *)
(* (PhiCNode -> NirPhiC nir.jl:477, UpsilonNode -> NirUpsilon :479,             *)
(* gc_preserve_begin/end + loopinfo -> NirNoOp :512-513). *)
RealClass(k) ==
    CASE k = "ExprSplatnew" -> "Unsupported"  \* no arm, no lowering anywhere -- the p53 class
      [] OTHER              -> "Known"

(* HasLowering(k): does a CORRECT lowering exist ANYWHERE in the compiler for   *)
(* this kind? Ground truth about the WIDER compiler, independent of what        *)
(* `_nir_classify` itself returns -- deliberately NOT wired into a checked      *)
(* invariant (see FINDING). It is what made the pre-migration classification a  *)
(* landmine, and what makes the current one safe: RealClass(k) = "Unsupported"  *)
(* now implies ~HasLowering(k). *)
HasLowering(k) == k # "ExprSplatnew"

(* Documented(k): does nir.jl's own header name this kind as an intentional     *)
(* Julia-only quarantine node (a construct dart's Kernel has no equivalent      *)
(* for, classified here rather than left Unsupported)? Informational only, like *)
(* Diagnostics.tla's tracked-but-unenforced Kind/CallerHint fields. *)
Documented(k) == k \in {"PhiCNode", "UpsilonNode", "ExprGcPreserveBegin",
                        "ExprGcPreserveEnd", "ExprLoopinfo",
                        "ExprBoundscheck", "ExprThrowUndefIfNot"}

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

(* `resolve_invoke_mi` (nir.jl:252-256): a bare MethodInstance stands as-is; a   *)
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

(* `_widened_ssa_types` (nir.jl:310-320): inference's own answer, widened once,  *)
(* never re-derived -- corrupted by TypeRederiveBug for its chosen targets. *)
TypeOf(s) == IF TypeRederiveBug /\ s \in RederiveStmts THEN RederivedType[s] ELSE AnalyzerType[s]

(* `out[i] = ...` (nir.jl:546-549): position s always describes position s.     *)
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
(* `build_nir`'s per-statement write (the for-loop body at nir.jl:536-550)      *)
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
