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
(* k: kI admits only (I, I). Static types: every pair, and (I, I).            *)
EXTENDS Enrollment
MCX == {"I", "J", "S", "F"}
MCCallables == {"h", "a", "g", "q", "b", "k"}
MCMethods == {"hA", "hP", "aX", "aY", "aP", "gI", "gN", "q1", "q2", "q3", "b1", "b2", "kI"}
MCOwner == [m \in MCMethods |-> CASE m \in {"hA", "hP"} -> "h"
                                  [] m \in {"aX", "aY", "aP"} -> "a"
                                  [] m \in {"gI", "gN"} -> "g"
                                  [] m \in {"q1", "q2", "q3"} -> "q"
                                  [] m \in {"b1", "b2"} -> "b"
                                  [] OTHER -> "k"]
Row(xs) == xs \X MCX
MCParam == [m \in MCMethods |-> CASE m = "hA" -> MCX \X MCX
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
MCMore == {<<"hP", "hA">>, <<"aP", "aX">>, <<"aP", "aY">>, <<"gI", "gN">>, <<"q3", "q1">>, <<"q3", "q2">>}
MCPOrd == [m \in MCMethods |-> CASE m \in {"hA", "aX", "gN", "q1", "b1", "kI"} -> 1
                                  [] m \in {"aY", "q2", "b2"} -> 2
                                  [] OTHER -> 3]
MCFix == [m \in MCMethods |-> IF m \in {"hP", "aP"} THEN 2 ELSE 0]
MCStatics == {MCX \X MCX, {<<"I", "I">>}}
=============================================================================
