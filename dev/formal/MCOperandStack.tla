---------------------------- MODULE MCOperandStack ----------------------------
(* Every program of at most four instructions (block with zero or one i32   *)
(* result, end, br 0/1, unreachable, i32/i64 constants and adds, drop).     *)
(* The Broken instance drops block results from the tracker: `block (result *)
(* i32) i32.const 0 end drop` is valid, and the tracker rejects it.         *)
EXTENDS OperandStack
=============================================================================
