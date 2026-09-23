------------------------- MODULE MCNumericJoinDroppedPhi -------------------------
(* VERIFY rechecks each phi's join but drops only the phi (Verify = "Join"): *)
(* a call typed THROUGH the dropped phi keeps its type -- NumericJoin.tla     *)
(* FINDING 2, which the real code (Verify = "Real") shares.                  *)
EXTENDS NumericJoin
MCN == 4
MCVerify == "Join"
=============================================================================
