---------------------------- MODULE MCEnrollmentOneSet ----------------------------
(* One class set and one match rule. Classes I (Int64), Q1 and Q2 (the two       *)
(* subclasses of an abstract QAB), K (the kind DataType); T is the type object    *)
(* Int64, held as a literal.                                                      *)
(* u: u1 admits {Q1, Q2} x X (`h(x::QAB, y)`), u2 admits X x {Q1, Q2}             *)
(* (`h(x, y::QAB)`), u3 only (Q1, Q1), more specific than both. Q2 is numbered    *)
(* (a statement is typed by it) and no value has it: Unreached. Over the classes  *)
(* that reach the call no tuple is ambiguous; at (Q2, Q2) Julia's dispatch would  *)
(* be, which AskNumbered (broken) asks about and rejects (A7C4: native 3).        *)
(* w: wP admits {K, T} x X with a static parameter of the first position          *)
(* (`h(::Type{S}) where S`); its match at the kind K leaves S a TypeVar (NoFix):  *)
(* that match is not one signature, and the row comes from T. NoTypeVarCheck      *)
(* (broken) builds the body at K, which cannot be compiled (A9C6: native 1).      *)
EXTENDS Enrollment
OSX == {"I", "Q1", "Q2", "K", "T"}
OSNumbered == {"I", "Q1", "Q2", "K"}
OSCallables == {"u", "w"}
OSMethods == {"u1", "u2", "u3", "wP"}
OSOwner == [m \in OSMethods |-> IF m = "wP" THEN "w" ELSE "u"]
OSParam == [m \in OSMethods |-> CASE m = "u1" -> {"Q1", "Q2"} \X OSX
                                  [] m = "u2" -> OSX \X {"Q1", "Q2"}
                                  [] m = "u3" -> {<<"Q1", "Q1">>}
                                  [] OTHER -> {"K", "T"} \X OSX]
OSMore == {<<"u3", "u1">>, <<"u3", "u2">>}
OSPOrd == [m \in OSMethods |-> CASE m = "u1" -> 1 [] m = "u2" -> 2 [] OTHER -> 3]
OSPFix == [m \in OSMethods |-> IF m = "wP" THEN {1} ELSE {}]
OSStatics == {OSX \X OSX}
OSLiterals == {"T"}
OSUnreached == {"Q2"}
OSNoFix == [m \in OSMethods |-> IF m = "wP" THEN {"K"} ELSE {}]
=============================================================================
