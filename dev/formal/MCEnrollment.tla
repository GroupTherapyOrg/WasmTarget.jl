---------------------------- MODULE MCEnrollment ----------------------------
(* Classes I (Int64), S (String), F (Float64). hI admits I; hA admits every class *)
(* (`h(x)`), listed first in program order; gI admits I only (a closure with one  *)
(* Int64 method). Static types: Any (all classes), {I}. The positive instance     *)
(* runs hI for an I and hA for the rest. SubsetRule: an erased I runs hA (w2) and *)
(* gI is never enrolled; ProgramOrder: an I runs hA.                              *)
EXTENDS Enrollment
MCClasses == {"I", "S", "F"}
MCMethods == {"hA", "hI"}
MCParam == [m \in MCMethods |-> IF m = "hI" THEN {"I"} ELSE MCClasses]
MCSpec == [m \in MCMethods |-> IF m = "hI" THEN 1 ELSE 2]
MCPOrd == [m \in MCMethods |-> IF m = "hA" THEN 1 ELSE 2]
MCStatics == {MCClasses, {"I"}}
=============================================================================
