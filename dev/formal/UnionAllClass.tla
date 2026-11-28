--------------------------- MODULE UnionAllClass ---------------------------
(***************************************************************************)
(* A TLA+ model of unionall_class (src/julia/classes.jl): the class a value *)
(* of a UnionAll type U not under Type is represented by, which the class  *)
(* walk (_meet_value!) meets and the translator's                          *)
(* toMostSpecificInterfaceType answers. U's instances (Vector{Int64},      *)
(* Vector{String} of Vector) are each a class of their own; the walk       *)
(* starts at U's body, a class with U's free variable T, and steps up      *)
(* Julia's supertype chain while the class has a free variable of U's or  *)
(* does not hold every instance of U.                                      *)
(*                                                                          *)
(* ABSTRACTION. A class is a template name and its argument: a type        *)
(* argument, the free variable "T", or "none" for a template with no       *)
(* parameter. Supertype is Julia's answer as a fixed table: a template's   *)
(* supertype template and whether it passes its argument on or fixes one  *)
(* (struct Q{T} <: Abs{Int}). Julia's subtyping of a class with a free     *)
(* variable reads that variable as any type (`Vector <: Array{T,1}` holds),*)
(* JuliaSub below. Init picks every parametric template as U.              *)
(*                                                                          *)
(* Claims, at the walk's end:                                              *)
(*   IsClass   the class met has no free variable: a class a value has     *)
(*   HoldsAll  every instance of U is under it                             *)
(*   Nearest   it is under every class that holds every instance: their    *)
(*             nearest common superclass                                   *)
(*   Ends      the walk ends                                               *)
(* Broken: MCUnionAllClassBroken.cfg, the loop guarded by Julia's `U <: c` *)
(* alone (NoFreeCheck), stops at the body itself, a class no value has:    *)
(* IsClass fails.                                                          *)
(***************************************************************************)
EXTENDS FiniteSets

CONSTANTS NoFreeCheck

Names  == {"Vec", "Dense", "Abs", "Boxed", "Shape", "PB", "PS", "Q", "Any"}
Param  == [n \in Names |-> n \notin {"Shape", "Any"}]
SupName == [n \in Names \ {"Any"} |->
              CASE n = "Vec"   -> "Dense"
                [] n = "Dense" -> "Abs"
                [] n = "Abs"   -> "Any"
                [] n = "Boxed" -> "Shape"
                [] n = "PB"    -> "PS"
                [] n = "PS"    -> "Shape"
                [] n = "Q"     -> "Abs"
                [] n = "Shape" -> "Any"]
\* "pass": the supertype takes the template's own argument; else the argument it fixes
SupArg == [n \in Names \ {"Any"} |-> IF n = "Q" THEN "Int" ELSE "pass"]
Args   == {"Int", "Str"}
Arg    == Args \cup {"T", "none"}
Classes == [n : Names, a : Arg]

Sup(c) == LET s == SupName[c.n]
          IN [n |-> s, a |-> IF ~Param[s] THEN "none"
                              ELSE IF SupArg[c.n] = "pass" THEN c.a ELSE SupArg[c.n]]

RECURSIVE Anc(_)
Anc(c) == IF c.n = "Any" THEN {c} ELSE {c} \cup Anc(Sup(c))
Under(i, d) == d \in Anc(i)

Templates == {n \in Names : Param[n]}
Inst(u) == {[n |-> u, a |-> x] : x \in Args}
Body(u) == [n |-> u, a |-> "T"]
HasFree(c) == c.a = "T"
HoldsEvery(u, c) == \A i \in Inst(u) : Under(i, c)
\* Julia's subtyping with a free variable on the right: the variable read as any type
Subst(c, x) == IF c.a = "T" THEN [c EXCEPT !.a = x] ELSE c
JuliaSub(u, c) == \A i \in Inst(u) : \E x \in Args : Under(i, Subst(c, x))

Continue(u, c) == IF NoFreeCheck THEN ~JuliaSub(u, c)
                  ELSE HasFree(c) \/ ~HoldsEvery(u, c)

VARIABLES u, c, done
vars == <<u, c, done>>

Init == /\ u \in Templates
        /\ c = Body(u)
        /\ done = FALSE

Step == /\ ~done
        /\ IF Continue(u, c) THEN (c' = Sup(c) /\ UNCHANGED done)
                             ELSE (done' = TRUE /\ UNCHANGED c)
        /\ UNCHANGED u
Stop == done /\ UNCHANGED vars
Next == Step \/ Stop
Spec == Init /\ [][Next]_vars /\ WF_vars(Step)

TypeOK == u \in Templates /\ c \in Classes /\ done \in BOOLEAN

IsClass  == done => ~HasFree(c)
HoldsAll == done => HoldsEvery(u, c)
Nearest  == done => \A d \in UNION {Anc(i) : i \in Inst(u)} : HoldsEvery(u, d) => Under(c, d)
Ends     == <>done
=============================================================================
