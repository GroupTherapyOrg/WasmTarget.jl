---------------------------- MODULE MCOperandStack ----------------------------
(* Every program of at most five instructions (block with zero or one i32   *)
(* result, end, br 0/1, unreachable, i32/i64 constants and adds, drop, and  *)
(* IfInstrs: a sub constant, else, if with five block types over the pair   *)
(* sub <: super). MCOperandStackDropResultsBroken drops block results from  *)
(* the tracker: it accepts `block (result i32) end`, which the spec         *)
(* rejects. MCOperandStackDeadCodeBroken records every instruction,         *)
(* dead ones included: `unreachable; i32.const` in a function with no       *)
(* results is recorded, and the spec rejects it. MCOperandStackIf checks    *)
(* if/else alone one instruction deeper.                                    *)
EXTENDS OperandStack

MCInstrs == CoreInstrs \cup IfInstrs
=============================================================================
