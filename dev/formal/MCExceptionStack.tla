---------------------------- MODULE MCExceptionStack ----------------------------
(* Every run of host calls, top-level and re-entrant through a host-declared import, *)
(* nested at most MaxCalls deep, each a program nesting at most MaxFrames try, catch  *)
(* and import frames, over MaxSteps steps and two exception values; escapes of every  *)
(* kind (the tag, a foreign exception, a trap), and a host-declared import that       *)
(* throws. MCExceptionStackDeep nests three calls; MCExceptionStackPlain is a module  *)
(* with no host-declared import. The Broken instances: an entry that catches only the *)
(* tag (EntryTagOnly, the stuck count), a catch_all_ref at the import call sites      *)
(* instead of the entry (ImportSiteOnly), the payload dropped at the landing          *)
(* (NoLandingIdentity, H5), the entry found by ref.eq on the exception                *)
(* (ValueIdentity, A12P2), no top-level reset (NoTopLevelReset, A12B1), a count not   *)
(* restored at a landing or at the entry's handler (NoCountRestore,                   *)
(* NoEntryCountRestore), every entry nulling the top (ResetAtEntry), no entry         *)
(* (KeepsEntry), the value-save lowering, a rethrow at depth 0 that throws the top, a *)
(* push at the landing; H6Broken and H7Broken pin the open residuals of dev/MARCH.md  *)
(* 13.17, the re-entrant traps, outside the host contract (a trapped instance is      *)
(* discarded).                                                                        *)
EXTENDS ExceptionStack
=============================================================================
