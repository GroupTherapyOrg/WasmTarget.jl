-------------------------- MODULE MCNumericJoinSeededPhi --------------------------
(* The pre-fix propagate_numeric_value_types (Verify = "Drop"): an        *)
(* optimistically seeded phi is never revisited, and VERIFY checks only that *)
(* each operand resolves numeric. TLC finds phi(1::Int64, %add),             *)
(* the phi typed Int64 -- NumericJoin.tla FINDING 1.            *)
EXTENDS NumericJoin
MCN == 4
MCVerify == "Drop"
=============================================================================
