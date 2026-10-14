---------------------------- MODULE MCCaptureType ----------------------------
(* Every creator type and every nonempty set of closure writes. The        *)
(* positive instance types reads by the creator's join; the Broken one by  *)
(* the body-local guess, which covers only the body's own writes:          *)
(* init = Float64 with `c = c + 1` guesses Int64; and the per-field record *)
(* (MCCaptureTypePerFieldRecordBroken.cfg): a reader captor's field holds  *)
(* only the creator's Int64 while the writer captor stores a Float64; and  *)
(* the key that reads `#self#` and an SSA carrier only                     *)
(* (MCCaptureTypeArgumentCarrierBroken.cfg): a captor inlined into a       *)
(* function taking it writes 2.5 through an argument, which joins nothing. *)
EXTENDS CaptureType

\* every operand kind keyed (the code: value_type over any carrier)
MCKeyedAll == {"self", "ssa", "argument"}
\* the key before: `#self#` and an SSA value only
MCKeyedSelfAndValue == {"self", "ssa"}
=============================================================================
