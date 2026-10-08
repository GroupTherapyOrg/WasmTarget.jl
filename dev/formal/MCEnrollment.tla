---------------------------- MODULE MCEnrollment ----------------------------
(* Classes I (Int64), J (Int32), S (String), F (Float64); a value is a pair.     *)
(* h: hA admits every pair (`h(x, y)`), hP only (I, I) with static parameters  *)
(* both positions fix (`h(x::T, y::S) where {T<:Integer, S<:Integer}`).        *)
(* a: aX admits (I, _), aY admits (_, I), aP only (I, I) with two static        *)
(* parameters, more specific than both: (I, I) is not ambiguous.               *)
(* g: gI admits (I, _), gN admits (I, _) and (J, _) and is listed first; gI is *)
(* more specific; at (I, I) both rows have one specialization.                 *)
(* q: q1 admits {I, J, S} x X, q2 {I, J, F} x X, q3 {I} x X, more specific     *)
(* than both: only a J is ambiguous, and no J reaches a call at (I, I).        *)
(* b: b1 admits {I, S} x X, b2 {I, F} x X: an I is ambiguous.                  *)
(* k: kI admits only (I, I).                                                  *)
(* t: t1 admits (T, _) (`h(::Type{Int64}, y)`; T is the type object Int64),  *)
(* t2 admits (_, I) (`h(x, ::Int64)`): (T, I) is ambiguous.                  *)
(* p: pA admits every pair, pP only (I, T) with static parameters both       *)
(* positions mention (`h(x::T, ::Type{S}) where {T<:Integer, S}`).           *)
(* o: oA admits every pair, oP admits (I, _) with a static parameter of the  *)
(* first position only (`h(x::T, y) where T<:Integer`).                      *)
(* Static types: every pair, (I, I), and (I, T) (`h(x::Int64, ::Type{T})`,  *)
(* whose second position is one type object). T is made by a               *)
(* `typeof`; the type object U is held as a literal, and pU (`h(x::T,       *)
(* ::Type{S}) where {T<:Integer, S}` at U) is fixed by it.                   *)
EXTENDS Enrollment
MCX == {"I", "J", "S", "F", "T", "U"}
MCNumbered == {"I", "J", "S", "F"}
MCCallables == {"h", "a", "g", "q", "b", "k", "t", "p", "o"}
MCMethods == {"hA", "hP", "aX", "aY", "aP", "gI", "gN", "q1", "q2", "q3", "b1", "b2", "kI", "t1", "t2", "pA", "pP", "pU", "oA", "oP"}
MCOwner == [m \in MCMethods |-> CASE m \in {"hA", "hP"} -> "h"
                                  [] m \in {"aX", "aY", "aP"} -> "a"
                                  [] m \in {"gI", "gN"} -> "g"
                                  [] m \in {"q1", "q2", "q3"} -> "q"
                                  [] m \in {"b1", "b2"} -> "b"
                                  [] m \in {"t1", "t2"} -> "t"
                                  [] m \in {"pA", "pP", "pU"} -> "p"
                                  [] m \in {"oA", "oP"} -> "o"
                                  [] OTHER -> "k"]
Row(xs) == xs \X MCX
MCParam == [m \in MCMethods |-> CASE m \in {"hA", "pA", "oA"} -> MCX \X MCX
                                  [] m = "t1" -> Row({"T"})
                                  [] m = "t2" -> MCX \X {"I"}
                                  [] m = "pP" -> {<<"I", "T">>}
                                  [] m = "pU" -> {<<"I", "U">>}
                                  [] m = "oP" -> Row({"I"})
                                  [] m \in {"hP", "aP", "kI"} -> {<<"I", "I">>}
                                  [] m = "aX" -> Row({"I"})
                                  [] m = "aY" -> MCX \X {"I"}
                                  [] m = "gI" -> Row({"I"})
                                  [] m = "gN" -> Row({"I", "J"})
                                  [] m = "q1" -> Row({"I", "J", "S"})
                                  [] m = "q2" -> Row({"I", "J", "F"})
                                  [] m = "q3" -> Row({"I"})
                                  [] m = "b1" -> Row({"I", "S"})
                                  [] OTHER -> Row({"I", "F"})]
MCMore == {<<"pP", "pA">>, <<"pU", "pA">>, <<"oP", "oA">>, <<"hP", "hA">>, <<"aP", "aX">>, <<"aP", "aY">>, <<"gI", "gN">>, <<"q3", "q1">>, <<"q3", "q2">>}
MCPOrd == [m \in MCMethods |-> CASE m \in {"hA", "aX", "gN", "q1", "b1", "kI", "t1", "pA", "oA"} -> 1
                                  [] m \in {"aY", "q2", "b2", "t2"} -> 2
                                  [] OTHER -> 3]
MCPFix == [m \in MCMethods |-> CASE m \in {"hP", "aP", "pP", "pU"} -> {1, 2}
                                 [] m = "oP" -> {1}
                                 [] OTHER -> {}]
MCStatics == {MCX \X MCX, {<<"I", "I">>}, {<<"I", "T">>}}
\* T is made by a `typeof` (`h(typeof(x))`), held as no literal; U is held as a literal
MCLiterals == {"U"}
=============================================================================
