---------------------------- MODULE MCClosureLayout ----------------------------
(* Instance shape: three closure types -- t1 captures TWO distinct-class     *)
(* fields at arity 1, t2 captures ONE field at a DIFFERENT arity (2), and t3 *)
(* captures what t2 does at arity 1 -- so struct/global/vtable-struct        *)
(* sharing is exercised non-trivially (two distinct arities, two distinct    *)
(* field multisets, and two types add_type! gives one context struct type)   *)
(* and t1's 2-element field list gives HashOrderCapture a real,              *)
(* non-vacuous permutation to find (Perms(2) has 2 elements, one of them     *)
(* wrong). MaxArrivals=2 is the smallest budget that lets a T be revisited   *)
(* at all -- exactly what both Broken variants need to exhibit their bug on  *)
(* a second arrival.                                                         *)
EXTENDS ClosureLayout

MCTypes == {"t1", "t2", "t3"}
MCArities == {0, 1, 2}
MCFieldClasses == {"Num", "Ref"}

\* t3 captures what t2 does, so add_type! gives the two one context struct type
MCDeclaredFields == [T \in MCTypes |->
    IF T = "t1" THEN <<"Num", "Ref">> ELSE <<"Ref">>]

MCDeclaredArity == [T \in MCTypes |->
    IF T = "t2" THEN 2 ELSE 1]

MCMaxArrivals == 2

\* the one struct-field rule: a number in its register, a struct field its struct's reference; a
\* rule of the closure registrar's own erased the struct to structref (julia_to_wasm_type)
MCFieldStorage == [c \in MCFieldClasses |-> IF c = "Num" THEN "i64" ELSE "ref_struct"]
MCOwnStorage == [c \in MCFieldClasses |-> IF c = "Num" THEN "i64" ELSE "structref"]
=============================================================================
