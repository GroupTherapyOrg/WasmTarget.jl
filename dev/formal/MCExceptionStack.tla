---------------------------- MODULE MCExceptionStack ----------------------------
(* Every program of at most MaxSteps steps nesting at most MaxFrames try and catch  *)
(* bodies, over two exception values. The Broken instances: the value-save          *)
(* lowering (a `rethrow(e)` in a region nested in a catch is undone by its pop), a   *)
(* rethrow at depth 0 that throws the top, and a push at the catch's landing.       *)
EXTENDS ExceptionStack
=============================================================================
