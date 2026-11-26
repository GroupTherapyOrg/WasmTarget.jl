------------------------------ MODULE MCTypeofKeys -----------------------------
(* typeof of a 3-tuple: a Union{Nothing,Bool} element, an Int64 element, and a *)
(* Union{Int64,Float64} element (the corpus's NamedTuple field and one more    *)
(* split), all concrete: the keys are the 4 splits. Claims: Covered, Exact.    *)
(* Broken: MCTypeofKeysDeclaredBroken.cfg (Covered); MCTypeofKeysNoConcrete-   *)
(* CheckBroken.cfg over MCTypeofKeysKind.tla, an element typed Type{Int64}     *)
(* whose value's type is DataType (Covered). MCTypeofKeysKind.cfg: the same    *)
(* instance with the check, refused.                                           *)
EXTENDS TypeofKeys
MCDecl == <<{"Nothing", "Bool"}, {"Int64"}, {"Int64", "Float64"}>>
MCRunTypes == [m \in {"Nothing", "Bool", "Int64", "Float64"} |-> {m}]
=============================================================================
