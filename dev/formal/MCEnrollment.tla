---------------------------- MODULE MCEnrollment ----------------------------
(* Classes I (Int64), S (String), F (Float64). Callable h: hA admits every class *)
(* (`h(x)`), hP admits I and has a static parameter (`h(x::T) where T<:Integer`).*)
(* Callable g: gI admits I (`g(x::Int64)`), gN admits I too (`g(x::Integer)`,    *)
(* listed first), gI more specific; gN's body at {I} is also reached by invoke.  *)
(* Callable a: aS admits I and S, aF admits I and F (`a(x::Union{Int64,String})`,*)
(* `a(x::Union{Int64,Float64})`), neither more specific: an I is ambiguous.      *)
(* Callable k: kI admits I only (a closure with one Int64 method; SubsetRule     *)
(* gives it no row). Static types: Any (all classes), {I}, {S}.                  *)
EXTENDS Enrollment
MCClasses == {"I", "S", "F"}
MCCallables == {"h", "g", "a", "k"}
MCMethods == {"hA", "hP", "gI", "gN", "aS", "aF", "kI"}
MCOwner == [m \in MCMethods |-> CASE m \in {"hA", "hP"} -> "h"
                                  [] m \in {"gI", "gN"} -> "g"
                                  [] m \in {"aS", "aF"} -> "a"
                                  [] OTHER -> "k"]
MCParam == [m \in MCMethods |-> CASE m = "hA" -> MCClasses
                                  [] m = "aS" -> {"I", "S"}
                                  [] m = "aF" -> {"I", "F"}
                                  [] OTHER -> {"I"}]
MCMore == {<<"hP", "hA">>, <<"gI", "gN">>}
MCPOrd == [m \in MCMethods |-> CASE m \in {"hA", "gN", "aS", "kI"} -> 1 [] OTHER -> 2]
MCParametric == {"hP"}
MCInvokeRows == {<<"gN", {"I"}>>}
MCStatics == {MCClasses, {"I"}, {"S"}}
=============================================================================
