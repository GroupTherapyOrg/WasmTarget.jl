-------------------------- MODULE HasBoundTypevars --------------------------
(***************************************************************************)
(* A TLA+ model of jl_has_typevar (julia/src/jltypes.c:273), the test     *)
(* jl_type_unionall (:907) makes of its body before it makes a UnionAll: *)
(* whether the type variable v occurs free in t, by jl_has_bound_typevars *)
(* (:220) over the environment {v}. The runtime's port walks it over     *)
(* WasmTarget's type values (src/julia/runtime/jltypes.jl).               *)
(*                                                                          *)
(* ABSTRACTION. Two type variables, "v" (the one asked about) and "w". A  *)
(* term is a type variable, a DataType with its parameters (Leaf, none:  *)
(* Int64 or Any), a Union of two members, a UnionAll binding a variable  *)
(* with its lower and upper bounds and its body, a Vararg with its T and *)
(* N (each None where undefined), Union{} (Bot) or a value that is no  *)
(* type (Val: a parameter such as 1). Terms are built two levels deep    *)
(* from the leaves. A UnionAll's body is never a type variable (Julia's  *)
(* jl_type_unionall answers v.ub or the body itself there, :941), and a  *)
(* variable's bounds never mention it.                                   *)
(*                                                                          *)
(* The walk (Has) is the C's, its environment {v} read as whether v is    *)
(* shadowed: jl_has_bound_typevars adds an entry only for a variable the *)
(* environment holds unshadowed (typeenv_has_ne), so the one entry's     *)
(* rebinding to itself is the flag. A DataType's parameters are walked   *)
(* whatever its hasfreetypevars (the C's shortcut, a field WasmTarget's  *)
(* DataType value does not hold: a parameter with no free variable has   *)
(* no free v).                                                           *)
(*                                                                          *)
(* Claim: Correct, the walk answers whether v occurs free in the term     *)
(* (Free, the definition: under a UnionAll binding v, its body's v is    *)
(* bound; its bounds are outside the binder).                            *)
(* Broken: MCHasBoundTypevarsBroken.cfg, the walk never shadows v         *)
(* (NoShadow): `Vector{v} where v` reads as mentioning v, Correct fails.  *)
(***************************************************************************)
CONSTANTS NoShadow

Vars == {"v", "w"}
TV(x) == [k |-> "tv", x |-> x]
DT(ps) == [k |-> "dt", ps |-> ps]
Leaf == DT(<<>>)
Bot == [k |-> "bot"]
Val == [k |-> "val"]
None == [k |-> "none"]

T0 == {TV("v"), TV("w"), Leaf, Bot, Val}
\* a type or a type variable: what a Union's member, a UnionAll's bound and a Vararg's T are
Types(S) == {t \in S : t.k \in {"tv", "dt", "un", "ua", "bot"}}
Other(x) == CHOOSE y \in Vars : y # x
Step(S) == S \cup {DT(<<a>>) : a \in S}
             \cup {[k |-> "un", a |-> a, b |-> b] : a \in Types(S), b \in Types(S)}
             \cup UNION {{[k |-> "ua", x |-> x, lb |-> l, ub |-> u, body |-> bd] :
                            l \in {Bot, TV(Other(x))}, u \in {Leaf, TV(Other(x)), DT(<<TV(Other(x))>>)},
                            bd \in {t \in Types(S) : t.k # "tv"}} : x \in Vars}
             \cup {[k |-> "va", T |-> None, N |-> None]}
             \cup {[k |-> "va", T |-> t, N |-> n] : t \in Types(S), n \in {None, TV("v"), TV("w"), Val}}
Terms == Step(Step(T0))

\* v occurs free in t
RECURSIVE Free(_)
Free(t) == CASE t.k = "tv" -> t.x = "v"
             [] t.k = "dt" -> \E i \in DOMAIN t.ps : Free(t.ps[i])
             [] t.k = "un" -> Free(t.a) \/ Free(t.b)
             [] t.k = "ua" -> Free(t.lb) \/ Free(t.ub) \/ (t.x # "v" /\ Free(t.body))
             [] t.k = "va" -> t.T # None /\ (Free(t.T) \/ (t.N # None /\ Free(t.N)))
             [] OTHER -> FALSE

\* jl_has_bound_typevars(t, {v}): sh, whether v's entry is rebound to itself
RECURSIVE Has(_, _)
Has(t, sh) ==
    CASE t.k = "tv" -> t.x = "v" /\ ~sh
      [] t.k = "ua" -> \/ (t.lb # Bot /\ Has(t.lb, sh))
                       \/ (t.ub # Leaf /\ Has(t.ub, sh))
                       \/ LET sh2 == IF ~NoShadow /\ t.x = "v" /\ ~sh THEN TRUE ELSE sh
                          \* past the UnionAll loop a type variable reaches no arm: 0
                          IN t.body.k # "tv" /\ Has(t.body, sh2)
      [] t.k = "dt" -> \E i \in DOMAIN t.ps : Has(t.ps[i], sh)
      [] t.k = "un" -> Has(t.a, sh) \/ Has(t.b, sh)
      [] t.k = "va" -> t.T # None /\ ((t.N # None /\ Has(t.N, sh)) \/ Has(t.T, sh))
      [] OTHER -> FALSE

VARIABLE root
Init == root \in Terms
Next == UNCHANGED root
Spec == Init /\ [][Next]_root

TypeOK == root \in Terms
Correct == Has(root, FALSE) = Free(root)
=============================================================================
