------------------------------ MODULE TypesEgal ------------------------------
(***************************************************************************)
(* A TLA+ model of Julia's egal_types (julia/src/builtins.c:167), the      *)
(* comparison jl_egal makes of two UnionAll values (builtins.c:260, the    *)
(* jl_unionall_tag arm of jl_egal__bitstag: egal_types(a, b, NULL, 1)),    *)
(* and of its port in WasmTarget's runtime for a UnionAll made at run time *)
(* (src/julia/runtime/jltypes.jl, jl_type_unionall, jltypes.c:907).        *)
(*                                                                          *)
(* JULIA'S ALGORITHM (JuliaEgal below, the C arm for arm): identity first; *)
(* the type tags must match; a DataType: the same TypeName, as many        *)
(* parameters, each pair egal_types; a TypeVar: looked up in the          *)
(* environment, innermost binding first, egal iff it maps to b, unbound    *)
(* not egal (identity was checked); a UnionAll: (tvar_names) the           *)
(* variables' names equal, the lower and upper bounds egal under the       *)
(* current environment, then the bodies under it extended with            *)
(* ua.var -> ub.var; a Union: its two members pairwise; any other value   *)
(* (an Int parameter, Union{}): jl_egal, here value equality of atoms.    *)
(* The C's && short-circuits left to right; so does the port.              *)
(*                                                                          *)
(* THE PORT (the state machine): the same walk over a worklist of          *)
(* (a, b, env) items, depth first, left to right, as the recursive Julia   *)
(* code walks. WasmTarget's DataType value holds no TypeName, so two       *)
(* DataTypes that are not one object meeting in the DataType arm end the   *)
(* comparison at a named fatal ("gap"): a located gap, never an answer.    *)
(*                                                                          *)
(* ABSTRACTION. A finite universe of objects by identity (Obj): DataTypes  *)
(* Any and Int64 (concrete, one object each: Julia's type cache) and Vec   *)
(* and Arr over type variables, each construction its own object (a type   *)
(* with a free variable is not cached, jltypes.c:2132 inst_datatype_inner);*)
(* TypeVars T1, T2, T3 (named T), S1, S2 (S), U1, U2 (U, upper bound a     *)
(* variable); Int parameters 1 (two boxes) and 2; Union{}; Unions; and     *)
(* UnionAlls, including two distinct objects alpha-equivalent over one     *)
(* variable (UA1a, UA1b), over two variables of one name (UA2), ones that  *)
(* differ only in the variable's name (UAS) or bound (UA3), nested ones    *)
(* whose inner bound mentions the outer variable, ones with a free         *)
(* variable, and two (Cross1, Cross2) that share one body object under     *)
(* crossed binders. Each body mentions its variable (jl_type_unionall's    *)
(* normalization, jltypes.c:941) and no variable is bound twice on one     *)
(* path. Init picks every pair of UnionAlls, the arm's operands.           *)
(*                                                                          *)
(* THE INDEPENDENT REFERENCE (Alpha): alpha-equivalence by canonical de    *)
(* Bruijn renaming (a bound variable is its binder's distance, a free one  *)
(* its identity), the binder's name kept (tvar_names = 1), a DataType its  *)
(* name and parameters, an atom its value. Julia's identity-first test     *)
(* answers egal for one object shared at positions whose binders differ   *)
(* (Cross1, Cross2: Julia true, alpha false), so the alpha claims hold on  *)
(* Separated pairs: a shared object other than a TypeVar mentions no bound *)
(* variable, and a shared TypeVar is bound at the same depth in both.     *)
(* The port answers Julia's answer there too (Agrees holds on every pair). *)
(*                                                                          *)
(* Claims:                                                                 *)
(*   Agrees            where the port answers, it answers JuliaEgal        *)
(*   AgreesAlpha       where it answers on a Separated pair, it answers    *)
(*                     alpha-equivalence                                   *)
(*   JuliaIsAlpha      on a Separated pair, JuliaEgal is Alpha            *)
(*   GapOnlyAtDataTypes the port stops at the gap exactly when Julia's    *)
(*                     short-circuit walk meets two DataTypes that are     *)
(*                     not one object; the gap's pair is two such         *)
(*   Ends              the port's walk ends                                *)
(* Broken, each refuted by TLC:                                            *)
(*   MCTypesEgalIdentityBroken.cfg  UnionAlls by identity only (ref.eq,    *)
(*     else false: WasmTarget's egal arm before the port): Agrees, on two  *)
(*     distinct alpha-equivalent UnionAlls                                 *)
(*   MCTypesEgalNoEnvBroken.cfg     a TypeVar by identity, not through the *)
(*     environment: Agrees                                                 *)
(*   MCTypesEgalNoNameBroken.cfg    the variables' names ignored: Agrees   *)
(*   MCTypesEgalAlphaEverywhereBroken.cfg  AgreesAlpha claimed on every    *)
(*     pair: Julia's identity-first answer is not alpha-equivalence on     *)
(*     Cross1, Cross2 (why the port follows Julia, not the reference)      *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS IdentityOnly, NoEnv, NoName, AlphaEverywhere

DT(n, ps) == [k |-> "dt", name |-> n, ps |-> ps]
TV(n, lb, ub) == [k |-> "tv", name |-> n, lb |-> lb, ub |-> ub]
UA(v, body) == [k |-> "ua", var |-> v, body |-> body]
UN(a, b) == [k |-> "un", a |-> a, b |-> b]
AT(k, v) == [k |-> k, v |-> v]

\* every object, by identity (its id)
Obj == ("Any" :> DT("Any", <<>>)) @@ ("Int" :> DT("Int64", <<>>)) @@ ("Bot" :> AT("bot", "Union{}"))
    @@ ("one_a" :> AT("int", "1")) @@ ("one_b" :> AT("int", "1")) @@ ("two" :> AT("int", "2"))
    @@ ("T1" :> TV("T", "Bot", "Any")) @@ ("T2" :> TV("T", "Bot", "Any")) @@ ("T3" :> TV("T", "Bot", "Int"))
    @@ ("S1" :> TV("S", "Bot", "Any")) @@ ("S2" :> TV("S", "Bot", "Any"))
    @@ ("U1" :> TV("U", "Bot", "T1")) @@ ("U2" :> TV("U", "Bot", "T2"))
    @@ ("VecT1a" :> DT("Vec", <<"T1">>)) @@ ("VecT1b" :> DT("Vec", <<"T1">>)) @@ ("VecT2" :> DT("Vec", <<"T2">>))
    @@ ("VecS1" :> DT("Vec", <<"S1">>)) @@ ("VecT3" :> DT("Vec", <<"T3">>))
    @@ ("ArrT1a" :> DT("Arr", <<"T1", "one_a">>)) @@ ("ArrT2b" :> DT("Arr", <<"T2", "one_b">>))
    @@ ("ArrT1two" :> DT("Arr", <<"T1", "two">>)) @@ ("P12" :> DT("Arr", <<"T1", "T2">>))
    @@ ("UnT1" :> UN("T1", "Int")) @@ ("UnT2" :> UN("T2", "Int")) @@ ("UnS1" :> UN("S1", "Int"))
    @@ ("UnT3" :> UN("T3", "Int")) @@ ("UnT1S1" :> UN("T1", "S1")) @@ ("UnT2S1" :> UN("T2", "S1"))
    @@ ("UnT2S2" :> UN("T2", "S2")) @@ ("UnU1T1" :> UN("U1", "T1")) @@ ("UnU2T2" :> UN("U2", "T2"))
    @@ ("UA1a" :> UA("T1", "VecT1a")) @@ ("UA1b" :> UA("T1", "VecT1b")) @@ ("UA2" :> UA("T2", "VecT2"))
    @@ ("UAS" :> UA("S1", "VecS1")) @@ ("UA3" :> UA("T3", "VecT3"))
    @@ ("UAArrA" :> UA("T1", "ArrT1a")) @@ ("UAArrB" :> UA("T2", "ArrT2b")) @@ ("UAArr2" :> UA("T1", "ArrT1two"))
    @@ ("UAUn1" :> UA("T1", "UnT1")) @@ ("UAUn2" :> UA("T2", "UnT2")) @@ ("UAUnS" :> UA("S1", "UnS1"))
    @@ ("UAUn3" :> UA("T3", "UnT3"))
    @@ ("UAfree1" :> UA("T1", "UnT1S1")) @@ ("UAfree2" :> UA("T2", "UnT2S1")) @@ ("UAfree3" :> UA("T2", "UnT2S2"))
    @@ ("UAin1" :> UA("U1", "UnU1T1")) @@ ("UAnest1" :> UA("T1", "UAin1"))
    @@ ("UAin2" :> UA("U2", "UnU2T2")) @@ ("UAnest2" :> UA("T2", "UAin2"))
    @@ ("Cin1" :> UA("T2", "P12")) @@ ("Cross1" :> UA("T1", "Cin1"))
    @@ ("Cin2" :> UA("T1", "P12")) @@ ("Cross2" :> UA("T2", "Cin2"))

Ids == DOMAIN Obj
UAs == {o \in Ids : Obj[o].k = "ua"}

\* the environment: a sequence of <<var, val>>, innermost first (jl_typeenv_t's prev chain)
Lookup(env, x) == LET is == {i \in DOMAIN env : env[i][1] = x}
                  IN IF is = {} THEN "unbound"
                     ELSE env[CHOOSE i \in is : \A j \in is : i <= j][2]
Extend(x, y, env) == <<<<Obj[x].var, Obj[y].var>>>> \o env

\* ---- Julia's definition: egal_types(a, b, env, tvar_names = 1), arm for arm ----
RECURSIVE JE(_, _, _)
JE(x, y, env) ==
  IF x = y THEN TRUE
  ELSE IF Obj[x].k # Obj[y].k THEN FALSE
  ELSE LET ox == Obj[x]  oy == Obj[y] IN
    CASE ox.k = "dt" -> /\ ox.name = oy.name
                        /\ Len(ox.ps) = Len(oy.ps)
                        /\ \A i \in DOMAIN ox.ps : JE(ox.ps[i], oy.ps[i], env)
      [] ox.k = "tv" -> Lookup(env, x) = y
      [] ox.k = "ua" -> /\ Obj[ox.var].name = Obj[oy.var].name
                        /\ JE(Obj[ox.var].lb, Obj[oy.var].lb, env)
                        /\ JE(Obj[ox.var].ub, Obj[oy.var].ub, env)
                        /\ JE(ox.body, oy.body, Extend(x, y, env))
      [] ox.k = "un" -> JE(ox.a, oy.a, env) /\ JE(ox.b, oy.b, env)
      [] OTHER       -> ox.v = oy.v
JuliaEgal(x, y) == JE(x, y, <<>>)

\* whether Julia's short-circuit walk meets two DataTypes that are not one object
RECURSIVE Meets(_, _, _)
Meets(x, y, env) ==
  IF x = y \/ Obj[x].k # Obj[y].k THEN FALSE
  ELSE LET ox == Obj[x]  oy == Obj[y] IN
    CASE ox.k = "dt" -> TRUE
      [] ox.k = "ua" -> IF Obj[ox.var].name # Obj[oy.var].name THEN FALSE
                        ELSE \/ Meets(Obj[ox.var].lb, Obj[oy.var].lb, env)
                             \/ /\ JE(Obj[ox.var].lb, Obj[oy.var].lb, env)
                                /\ \/ Meets(Obj[ox.var].ub, Obj[oy.var].ub, env)
                                   \/ /\ JE(Obj[ox.var].ub, Obj[oy.var].ub, env)
                                      /\ Meets(ox.body, oy.body, Extend(x, y, env))
      [] ox.k = "un" -> Meets(ox.a, oy.a, env) \/ (JE(ox.a, oy.a, env) /\ Meets(ox.b, oy.b, env))
      [] OTHER       -> FALSE

\* ---- the independent reference: canonical de Bruijn form ----
Idx == <<"0", "1", "2", "3">>
RECURSIVE Canon(_, _)
Canon(t, ctx) ==
  LET o == Obj[t] IN
  CASE o.k = "dt" -> <<"dt", o.name, [i \in DOMAIN o.ps |-> Canon(o.ps[i], ctx)]>>
    [] o.k = "tv" -> LET is == {i \in DOMAIN ctx : ctx[i] = t}
                     IN IF is = {} THEN <<"fv", t>>
                        ELSE <<"bv", Idx[CHOOSE i \in is : \A j \in is : i <= j]>>
    [] o.k = "ua" -> <<"ua", Obj[o.var].name, Canon(Obj[o.var].lb, ctx), Canon(Obj[o.var].ub, ctx),
                       Canon(o.body, <<o.var>> \o ctx)>>
    [] o.k = "un" -> <<"un", Canon(o.a, ctx), Canon(o.b, ctx)>>
    [] OTHER      -> <<o.k, o.v>>
Alpha(x, y) == Canon(x, <<>>) = Canon(y, <<>>)

Children(t) == LET o == Obj[t] IN
  CASE o.k = "dt" -> {o.ps[i] : i \in DOMAIN o.ps}
    [] o.k = "tv" -> {o.lb, o.ub}
    [] o.k = "ua" -> {o.var, o.body}
    [] o.k = "un" -> {o.a, o.b}
    [] OTHER      -> {}
RECURSIVE Reach(_)
Reach(t) == {t} \cup UNION {Reach(c) : c \in Children(t)}
Binders(t) == {Obj[u].var : u \in {r \in Reach(t) : Obj[r].k = "ua"}}
\* the depths at which t binds v
RECURSIVE BD(_, _, _)
BD(t, v, d) == LET o == Obj[t] IN
  (IF o.k = "ua" /\ o.var = v THEN {d} ELSE {})
  \cup UNION {BD(c, v, IF o.k = "ua" /\ c = o.body THEN d + 1 ELSE d) : c \in Children(t)}
Separated(x, y) ==
  \/ x = y
  \/ \A o \in Reach(x) \cap Reach(y) :
       IF Obj[o].k = "tv" THEN BD(x, o, 0) = BD(y, o, 0)
       ELSE Reach(o) \cap (Binders(x) \cup Binders(y)) = {}

\* ---- the port: the walk over a worklist ----
Item(x, y, env) == [x |-> x, y |-> y, env |-> env]
VARIABLES a, b, work, outcome, gapAt
vars == <<a, b, work, outcome, gapAt>>

Init == /\ a \in UAs
        /\ b \in UAs
        /\ work = <<Item(a, b, <<>>)>>
        /\ outcome = "run"
        /\ gapAt = <<>>

Answer(o) == outcome' = o /\ UNCHANGED <<a, b, work, gapAt>>
Pop(rest) == work' = rest /\ UNCHANGED <<a, b, outcome, gapAt>>

Step ==
  /\ outcome = "run"
  /\ IF work = <<>> THEN Answer("egal")
     ELSE LET it == Head(work)  rest == Tail(work)
              x == it.x  y == it.y  env == it.env
              ox == Obj[x]  oy == Obj[y] IN
       CASE x = y -> Pop(rest)
         [] ox.k # oy.k -> Answer("notegal")
         [] ox.k = "dt" -> /\ outcome' = "gap"
                           /\ gapAt' = <<x, y>>
                           /\ UNCHANGED <<a, b, work>>
         [] ox.k = "tv" -> IF ~NoEnv /\ Lookup(env, x) = y THEN Pop(rest) ELSE Answer("notegal")
         [] ox.k = "ua" -> IF IdentityOnly \/ (~NoName /\ Obj[ox.var].name # Obj[oy.var].name)
                           THEN Answer("notegal")
                           ELSE Pop(<<Item(Obj[ox.var].lb, Obj[oy.var].lb, env),
                                      Item(Obj[ox.var].ub, Obj[oy.var].ub, env),
                                      Item(ox.body, oy.body, Extend(x, y, env))>> \o rest)
         [] ox.k = "un" -> Pop(<<Item(ox.a, oy.a, env), Item(ox.b, oy.b, env)>> \o rest)
         [] OTHER -> IF ox.v = oy.v THEN Pop(rest) ELSE Answer("notegal")
Stop == outcome # "run" /\ UNCHANGED vars
Next == Step \/ Stop
Spec == Init /\ [][Next]_vars /\ WF_vars(Step)

Done == outcome # "run"
Answered == Done /\ outcome # "gap"

TypeOK == /\ a \in UAs /\ b \in UAs
          /\ work \in Seq([x : Ids, y : Ids, env : Seq(Ids \X Ids)])
          /\ outcome \in {"run", "egal", "notegal", "gap"}
          /\ gapAt \in {<<>>} \cup (Ids \X Ids)

Agrees == Answered => ((outcome = "egal") = JuliaEgal(a, b))
AgreesAlpha == (Answered /\ (AlphaEverywhere \/ Separated(a, b))) => ((outcome = "egal") = Alpha(a, b))
JuliaIsAlpha == Separated(a, b) => (JuliaEgal(a, b) = Alpha(a, b))
GapOnlyAtDataTypes ==
  /\ Done => ((outcome = "gap") = Meets(a, b, <<>>))
  /\ outcome = "gap" => /\ gapAt[1] # gapAt[2]
                        /\ Obj[gapAt[1]].k = "dt" /\ Obj[gapAt[2]].k = "dt"
Ends == <>Done
=============================================================================
