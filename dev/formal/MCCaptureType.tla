---------------------------- MODULE MCCaptureType ----------------------------
(* Every creator type and every nonempty set of closure writes. The        *)
(* positive instance types reads by the creator's join; the Broken one by  *)
(* the body-local guess, which covers only the body's own writes:          *)
(* init = Float64 with `c = c + 1` guesses Int64.                          *)
EXTENDS CaptureType
=============================================================================
