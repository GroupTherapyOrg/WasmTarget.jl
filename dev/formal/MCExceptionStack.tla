---------------------------- MODULE MCExceptionStack ----------------------------
(* Every run of host calls nested at most MaxCalls deep, each a program nesting at   *)
(* most MaxFrames try and catch bodies, over MaxSteps steps and two exception values. *)
(* The Broken instances: the value-save lowering (a `rethrow(e)` in a region nested   *)
(* in a catch is undone by its pop), a rethrow at depth 0 that throws the top, a push *)
(* at the catch's landing, an export with no entry (KeepsEntry), and an entry that    *)
(* nulls the top it saved (ResetAtEntry).                                             *)
EXTENDS ExceptionStack
=============================================================================
