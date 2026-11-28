---------------------------- MODULE MCClosureLayout ----------------------------
(* Instance shape: two closure types with DIFFERENT declared shapes on both  *)
(* axes -- t1 captures TWO distinct-class fields at arity 1, t2 captures ONE *)
(* field at a DIFFERENT arity (2) -- so struct/global/vtable-struct sharing  *)
(* is exercised non-trivially (two distinct arities, two distinct field      *)
(* multisets) and t1's 2-element field list gives HashOrderCapture a real,   *)
(* non-vacuous permutation to find (Perms(2) has 2 elements, one of them     *)
(* wrong). MaxArrivals=2 is the smallest budget that lets a T be revisited   *)
(* at all -- exactly what both Broken variants need to exhibit their bug on  *)
(* a second arrival.                                                         *)
EXTENDS ClosureLayout

MCTypes == {"t1", "t2"}
MCArities == {0, 1, 2}
MCFieldClasses == {"Num", "Ref"}

MCDeclaredFields == [T \in MCTypes |->
    IF T = "t1" THEN <<"Num", "Ref">> ELSE <<"Ref">>]

MCDeclaredArity == [T \in MCTypes |->
    IF T = "t1" THEN 1 ELSE 2]

MCMaxArrivals == 2
=============================================================================
