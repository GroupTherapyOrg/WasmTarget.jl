---------------------------- MODULE MCOperandStackIf ----------------------------
(* if/else over the subtype pair "sub" <: "super", one instruction deeper   *)
(* than MCOperandStack: every program of at most MaxLen = 6 instructions    *)
(* over IfInstrs (a sub constant, else, if with five block types) and an    *)
(* i32 constant, drop, end, br 0, unreachable. Twelve instructions keep     *)
(* MaxLen 6 under two minutes on two workers (thirteen took 2 min 13 s).    *)
(* The Broken instance (ElseLessExact, batch 66's rule) rejects the valid   *)
(* `const sub; const i32; if [sub]->[super] end; drop`, whose implicit else *)
(* passes its sub input as its super result.                                *)
EXTENDS OperandStack

MCInstrs ==
    IfInstrs \cup
    {[op |-> "const", t |-> "i32"], [op |-> "drop"], [op |-> "end"],
     [op |-> "unreachable"], [op |-> "br", d |-> 0]}
=============================================================================
