---------------------------- MODULE MCOperandStack ----------------------------
(* Every program of at most five instructions (block with zero or one i32   *)
(* result, end, br 0/1, unreachable, i32/i64 constants and adds, drop, and  *)
(* IfInstrs: a sub constant, else, if with five block types over the pair   *)
(* sub <: super). The Broken instance drops block results from the tracker: *)
(* `block (result i32) i32.const 0 end drop` is valid, and the tracker      *)
(* rejects it. MCOperandStackIf checks if/else alone one instruction        *)
(* deeper.                                                                  *)
EXTENDS OperandStack

MCInstrs == CoreInstrs \cup IfInstrs
=============================================================================
