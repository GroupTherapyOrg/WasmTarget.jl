---------------------------- MODULE MCTypeofKeysKind ---------------------------
(* typeof of a 2-tuple whose first element is typed Union{Nothing,Type{Int64}}: *)
(* Type{Int64} is no concrete type, its value Int64's type DataType. With the   *)
(* check the operand is refused (Covered and Exact hold vacuously); without it  *)
(* (MCTypeofKeysKindNoConcreteCheckBroken.cfg) the key Tuple{Type{Int64},...}   *)
(* misses the value's Tuple{DataType,...} (Covered).                           *)
EXTENDS TypeofKeys
MCDecl == <<{"Nothing", "TypeInt64"}, {"Int64"}>>
MCRunTypes == [m \in {"Nothing", "TypeInt64", "Int64"} |->
                  IF m = "TypeInt64" THEN {"DataType"} ELSE {m}]
=============================================================================
