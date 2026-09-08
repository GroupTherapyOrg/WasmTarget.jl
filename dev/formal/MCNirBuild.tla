---------------------------- MODULE MCNirBuild ----------------------------
(* Model-checking instance for NirBuild.tla: thirteen positions ("s1".."s13",  *)
(* opaque tokens with an explicit successor -- see NirBuild.tla's header)      *)
(* covering every category the header distinguishes.                          *)
(*   s1  ReturnNode                              -- Known, ordinary control     *)
(*   s2  ExprCall                                -- Known, ordinary value       *)
(*   s3  ExprInvoke, OperandShape=DirectMI        -- Known; invoke identity #1  *)
(*   s4  ExprInvoke, OperandShape=WrappedInCI     -- Known; invoke identity #2 -*)
(*      the CodeInstance-unwrap case DivergentResolveBug targets               *)
(*   s5  ExprNew                                 -- Known, resolved field types *)
(*   s6  ExprForeigncall                         -- Known, resolved C symbol    *)
(*   s7  ExprThrowUndefIfNot                     -- Known; the exact head p53   *)
(*      once let fall through (now migrated, statements.jl:557)                *)
(*   s8  PhiNode                                 -- Known; NoReDerivation's      *)
(*      target (AnalyzerType=Float64Ty vs a wrongly-widened RederivedType=      *)
(*      AnyTy under TypeRederiveBug)                                            *)
(*   s9  PhiCNode                                -- Unsupported, documented      *)
(*      quarantine (nir.jl:21-24, :320-321)                                     *)
(*   s10 UpsilonNode                             -- Unsupported, documented      *)
(*      quarantine (nir.jl:21-24, :322-323)                                     *)
(*   s11 ExprGcPreserveBegin                     -- Unsupported, UNDOCUMENTED    *)
(*      gap (see NirBuild.tla's FINDING) -- real in `GC.@preserve` IR           *)
(*   s12 ExprLoopinfo                            -- Unsupported, UNDOCUMENTED    *)
(*      gap -- real in `@simd` IR                                               *)
(*   s13 ExprSplatnew                            -- Unsupported, the p53 class: *)
(*      no lowering anywhere. CensusDropBug's and ConsumerSwallowsUnsupported's *)
(*      target (both bugs corrupt the SAME statement, in different variants)    *)
(*                                                                              *)
(* ShiftedStmts = {s10..s13}: AlignmentBug shifts these positions to describe   *)
(* their successor; Succ[s13] = "Missing" (the true last statement gets no NIR  *)
(* entry at all under the bug). *)
EXTENDS NirBuild

StmtsDef == {"s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "s12", "s13"}

KindDef == [
    p \in StmtsDef |->
        CASE p = "s1"  -> "ReturnNode"
          [] p = "s2"  -> "ExprCall"
          [] p = "s3"  -> "ExprInvoke"
          [] p = "s4"  -> "ExprInvoke"
          [] p = "s5"  -> "ExprNew"
          [] p = "s6"  -> "ExprForeigncall"
          [] p = "s7"  -> "ExprThrowUndefIfNot"
          [] p = "s8"  -> "PhiNode"
          [] p = "s9"  -> "PhiCNode"
          [] p = "s10" -> "UpsilonNode"
          [] p = "s11" -> "ExprGcPreserveBegin"
          [] p = "s12" -> "ExprLoopinfo"
          [] p = "s13" -> "ExprSplatnew"]

OperandShapeDef == [
    p \in StmtsDef |->
        CASE p = "s3" -> "DirectMI"
          [] p = "s4" -> "WrappedInCI"
          [] OTHER    -> "Neither"]

AnalyzerTypeDef == [p \in StmtsDef |-> IF p = "s8" THEN "Float64Ty" ELSE "T1"]
RederivedTypeDef == [p \in StmtsDef |-> IF p = "s8" THEN "AnyTy" ELSE "T1"]

\* CensusDropBug's target: s13 (ExprSplatnew) is real-classified "Unsupported"
\* (no lowering anywhere) -- corrupting it into "SilentNoOpAtBuild" is the exact
\* p53 shape (a would-be-rejected head silently vanishing).
DroppedStmtsDef == {"s13"}

\* TypeRederiveBug's target: s8 (PhiNode), the one statement with a non-trivial
\* AnalyzerType/RederivedType split.
RederiveStmtsDef == {"s8"}

\* ConsumerSwallowsUnsupported's target: the SAME genuinely-dead statement
\* CensusDropBug targets -- swallowing it is unambiguously wrong (NoSilentSwallow
\* forbids swallowing anything without a real lowering).
SwallowStmtsDef == {"s13"}

\* AlignmentBug's target range and the real positional chain it corrupts.
ShiftedStmtsDef == {"s10", "s11", "s12", "s13"}
SuccDef == [
    p \in StmtsDef |->
        CASE p = "s1"  -> "s2"
          [] p = "s2"  -> "s3"
          [] p = "s3"  -> "s4"
          [] p = "s4"  -> "s5"
          [] p = "s5"  -> "s6"
          [] p = "s6"  -> "s7"
          [] p = "s7"  -> "s8"
          [] p = "s8"  -> "s9"
          [] p = "s9"  -> "s10"
          [] p = "s10" -> "s11"
          [] p = "s11" -> "s12"
          [] p = "s12" -> "s13"
          [] p = "s13" -> "Missing"]   \* the true last statement -- nothing to shift into

=============================================================================
