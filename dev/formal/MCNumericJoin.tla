----------------------------- MODULE MCNumericJoin -----------------------------
(* Every well-formed program of 4 statements (literal / opaque Any value /   *)
(* phi / `+`), with the rechecked, restarting VERIFY (Verify = "Restart"):   *)
(* the algorithm propagate_numeric_value_types needs to be sound.            *)
EXTENDS NumericJoin
MCN == 4
MCVerify == "Restart"
=============================================================================
