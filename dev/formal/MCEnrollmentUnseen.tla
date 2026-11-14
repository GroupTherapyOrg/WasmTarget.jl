---------------------------- MODULE MCEnrollmentUnseen ----------------------------
(* A class no statement makes. P is a vararg method's packed tuple            *)
(* (`pack(xs...)` at (Int8, Int64): Tuple{Int8, Int64}), which WT rebuilds    *)
(* from the flattened parameters; I is Int64. The callable h has p1, a method *)
(* with a static parameter at the first position (`h(x::Tuple{T,Int}) where  *)
(* T`), and p2 (`h(x::Int)`); an erased value of either class reaches the     *)
(* call. The set observes P from the body's slot; without it                  *)
(* (MCEnrollmentUnseenSlotDroppedBroken) p1 has no row for P and the call     *)
(* traps where Julia runs p1.                                                 *)
EXTENDS Enrollment
UNX == {"I", "P"}
UNMethods == {"p1", "p2"}
UNOwner == [m \in UNMethods |-> "h"]
UNParam == [m \in UNMethods |-> IF m = "p1" THEN {<<"P", "I">>} ELSE {<<"I", "I">>}]
UNPOrd == [m \in UNMethods |-> IF m = "p1" THEN 1 ELSE 2]
UNPFix == [m \in UNMethods |-> IF m = "p1" THEN {1} ELSE {}]
UNStatics == {UNX \X {"I"}}
UNNoFix == [m \in UNMethods |-> {}]
UNUnseen == {"P"}
UNSlotsDropped == FALSE
=============================================================================
