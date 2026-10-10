---------------------------- MODULE MCExceptionStack ----------------------------
(* Every run of host calls, top-level and re-entrant through a host-declared import,  *)
(* nested at most MaxCalls deep, each a program nesting at most MaxFrames try, catch  *)
(* and import frames, over MaxSteps steps and two exception values; escapes of every  *)
(* kind (the tag, a foreign exception, stack exhaustion, a trap), a host-declared     *)
(* import that throws or overflows the JS stack, and a re-entrant escape the host     *)
(* catches, propagates, or catches and re-raises. MCExceptionStackDeep nests three    *)
(* calls; MCExceptionStackPlain is a module with no host-declared import. The Broken  *)
(* instances: the count lowered only on a normal return (GlueNormalOnly), a           *)
(* re-entrant entry that keeps the top (EntryKeepsTop), no restore after an import's  *)
(* normal return (NoReturnRestore), the payload dropped at the landing                *)
(* (NoLandingIdentity, H5), the entry found by ref.eq on the exception                *)
(* (ValueIdentity, A12P2), no top-level reset (NoTopLevelReset, A12B1), every entry   *)
(* nulling the top (ResetAtEntry), a glued import the host calls itself or a glued    *)
(* object two instances share (HostCallsGlued), no entry (KeepsEntry), the value-save *)
(* lowering, a rethrow at depth 0 that throws the top, a push at the landing;         *)
(* ReraiseShared pins the open residual dev/MARCH.md 13.17 H11.                       *)
EXTENDS ExceptionStack
=============================================================================
