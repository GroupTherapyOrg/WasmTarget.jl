----------------------- MODULE MCBoxJoinCaptorMissed -----------------------
(* THE BROKEN VARIANT (BoxJoin.tla's header, "A captor called elsewhere"):  *)
(* Root creates Level1, a closure capturing the box, and does not call it   *)
(* (it returns it; another function calls it). EveryCaptorBody = FALSE is  *)
(* a walk that reads captor bodies through the `:invoke`s of the scanned    *)
(* code only, so Level1's body is never seen. With Root's init              *)
(* Int64T and Level1's write Float64T, AlgoResult settles on Int64T while   *)
(* TrueWrites holds the Float64T write: a Soundness violation, a narrow     *)
(* cell a real write overflows. The walk takes every body of each captor    *)
(* type the closed world holds (MCBoxJoin.tla, EveryCaptorBody = TRUE).     *)
EXTENDS BoxJoin

MCScopes == {"Root", "Level1"}
MCRoot   == "Root"
MCCaptures == [s \in MCScopes |-> IF s = "Root" THEN {"Level1"} ELSE {}]
MCInvokedIn == [s \in MCScopes |-> {}]   \* Root creates Level1 and never calls it

MCWriteSites == {"w_root", "w_level1"}
MCScopeOf == [w \in MCWriteSites |-> IF w = "w_root" THEN "Root" ELSE "Level1"]

MCConcreteTypes == {"Int64T", "Float64T"}

MCEveryCaptorBody == FALSE
MCTransitiveDiscovery == TRUE
MCOrderDependentJoin  == FALSE
=============================================================================
