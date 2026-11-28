---------------------------- MODULE DataTypeEgal ----------------------------
(***************************************************************************)
(* A TLA+ model of the DataType arm of WasmTarget's port of Julia's       *)
(* egal_types (julia/src/builtins.c:167), the walk jl_egal makes of two   *)
(* UnionAlls (builtins.c:260-261, jl_egal__bitstag's jl_unionall_tag arm: *)
(* egal_types(a, b, NULL, 1)), as src/julia/runtime/jltypes.jl writes it: *)
(* jl_egal_unionall (:222) calls jl_egal_types(a, b, nothing, true)       *)
(* (:145-186), whose DataType arm (:148-159) answers two DataTypes by     *)
(* identity, else jl_datatype_same_name (:196, in a module the            *)
(* datatype_same_name arm of src/intrinsics.jl:1555-1582), then as many   *)
(* parameters, then each parameter pair by the recursion.                 *)
(*                                                                        *)
(* TypesEgal.tla models the other arms; its port stops at a named gap     *)
(* where two distinct DataTypes meet (its GapOnlyAtDataTypes), the port   *)
(* before the DataType arm landed. This model is the port as it stands    *)
(* (A124E1): no gap, the DataType arm ported.                             *)
(*                                                                        *)
(* JULIA'S ALGORITHM (JuliaEgal below, the C arm for arm): identity first *)
(* (:169); the type tags must match (:171-173); a DataType (:174-187):    *)
(* the same TypeName (dta->name != dtb->name, :177), as many parameters   *)
(* (jl_nparams, :179-181), each pair egal_types (:182-185); a TypeVar     *)
(* (:188-196): looked up in the environment, innermost binding first,     *)
(* egal iff it maps to b, unbound not egal; a UnionAll (:197-206): the    *)
(* variables' names equal (tvar_names = 1), the bounds egal, the bodies   *)
(* under the environment extended with ua.var -> ub.var; any other value  *)
(* (here Union{}): jl_egal__bitstag (:223), value equality of atoms.      *)
(*                                                                        *)
(* THE PORT (the state machine), arm for arm as jltypes.jl writes it: the *)
(* type tags first (typeof(a) === typeof(b), :146-147), then each kind    *)
(* its own identity test (a DataType's da === db, :151; a TypeVar's       *)
(* va === vb, :163; a UnionAll none: it walks), then the DataType arm:    *)
(* the TypeName compared through the closed world's table, as             *)
(* src/intrinsics.jl:1560-1582 builds and reads it: over the numbering's  *)
(* class ids (an IdDict, so in no fixed order) each class's TypeName      *)
(* (Base.unwrap_unionall(cls).name) given the index of its first          *)
(* appearance, the table indexed by class id, each operand's class id     *)
(* (_InterfaceType.classId, the class the DataType value denotes) read    *)
(* through it, the two indices compared; then the lengths of the          *)
(* parameter vectors (:155); then each pair (:156-158), left to right,    *)
(* depth first, over a worklist of (a, b, env) items. The env is the      *)
(* port's svec(var, val, outer) chain, innermost first (:164-169, :176).  *)
(*                                                                        *)
(* ABSTRACTION. Classes by their TypeName: Any, Int64, Vec, Ref and two   *)
(* classes of the one TypeName Tuple (its arities: Julia's Tuple types of *)
(* two lengths share Core.Tuple's TypeName), every one numbered           *)
(* (ClassIdNumbering.tla); Init picks the table each order the IdDict can *)
(* iterate them in builds (120 tables). Objects by identity (Obj):        *)
(* DataTypes Any and Int64 (concrete, one object each: Julia's type cache); *)
(* TypeVars T1 and T2, both named T with bounds Union{} and Any; DataTypes*)
(* over a type variable, each construction its own object (a type with a  *)
(* free variable is not cached, jltypes.c:2132 inst_datatype_inner):      *)
(* Vec{T1} twice (VecT1a, VecT1b), Vec{T2}, Ref{T1}, Ref{T2}, Vec{Ref{T1}}, *)
(* Vec{Ref{T2}}, Vec{Vec{T1}}, Tuple{T1}, Tuple{T1,Int64}, Tuple{T1,Any}; *)
(* and the UnionAlls over each, the arm's operands. Init picks every pair *)
(* of UnionAlls, so the DataType arm meets: two objects of one structure  *)
(* (identity fails, the walk answers egal), a Vec against a Ref of one    *)
(* parameter (the names), nested names under one parameter, two Tuples of *)
(* different lengths (the length), and two Tuples of one length whose     *)
(* second parameters are Int64 and Any (a parameter pair). Unions and Int *)
(* parameters are TypesEgal.tla's; the port's arms for them are written   *)
(* here as jltypes.jl has them, unreached by this universe.               *)
(*                                                                        *)
(* Claims:                                                                *)
(*   Agrees     the port's answer on every pair is JuliaEgal              *)
(*   NameTable  the table's indices of two classes are equal exactly when *)
(*              their TypeNames are, in every order the IdDict iterates   *)
(*   Ends       the port's walk ends, with an answer (no gap)             *)
(* Broken, each refuted by TLC:                                           *)
(*   MCDataTypeEgalNoTypeNameBroken.cfg  the TypeName compare skipped:    *)
(*     Agrees, on Vec{T} where T against Ref{T} where T                   *)
(*   MCDataTypeEgalNoLengthBroken.cfg    the lengths not compared, the    *)
(*     pairs walked over the shorter's: Agrees, on Tuple{T} where T       *)
(*     against Tuple{T,Int64} where T                                     *)
(*   MCDataTypeEgalTableByClassBroken.cfg  the table indexed by class, not*)
(*     by TypeName (each class its own index): NameTable, on the two      *)
(*     Tuple classes                                                      *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS NoTypeName, NoLength, TableByClass

DT(c, ps) == [k |-> "dt", cls |-> c, ps |-> ps]
TV(n, lb, ub) == [k |-> "tv", name |-> n, lb |-> lb, ub |-> ub]
UA(v, body) == [k |-> "ua", var |-> v, body |-> body]
UN(x, y) == [k |-> "un", a |-> x, b |-> y]
AT(k, v) == [k |-> k, v |-> v]

\* each class and its TypeName (Base.unwrap_unionall(cls).name)
ClassName == ("cAny" :> "Any") @@ ("cInt" :> "Int64") @@ ("cVec" :> "Vec") @@ ("cRef" :> "Ref")
    @@ ("cTup1" :> "Tuple") @@ ("cTup2" :> "Tuple")
Classes == DOMAIN ClassName
NClasses == Cardinality(Classes)

\* every object, by identity (its id)
Obj == ("Any" :> DT("cAny", <<>>)) @@ ("Int" :> DT("cInt", <<>>)) @@ ("Bot" :> AT("bot", "Union{}"))
    @@ ("T1" :> TV("T", "Bot", "Any")) @@ ("T2" :> TV("T", "Bot", "Any"))
    @@ ("VecT1a" :> DT("cVec", <<"T1">>)) @@ ("VecT1b" :> DT("cVec", <<"T1">>)) @@ ("VecT2" :> DT("cVec", <<"T2">>))
    @@ ("RefT1" :> DT("cRef", <<"T1">>)) @@ ("RefT2" :> DT("cRef", <<"T2">>))
    @@ ("VecRefT1" :> DT("cVec", <<"RefT1">>)) @@ ("VecRefT2" :> DT("cVec", <<"RefT2">>))
    @@ ("VecVecT1" :> DT("cVec", <<"VecT1a">>))
    @@ ("TupT1" :> DT("cTup1", <<"T1">>)) @@ ("TupT1Int" :> DT("cTup2", <<"T1", "Int">>))
    @@ ("TupT1Any" :> DT("cTup2", <<"T1", "Any">>))
    @@ ("UV1a" :> UA("T1", "VecT1a")) @@ ("UV1b" :> UA("T1", "VecT1b")) @@ ("UV2" :> UA("T2", "VecT2"))
    @@ ("UR1" :> UA("T1", "RefT1")) @@ ("UVR1" :> UA("T1", "VecRefT1")) @@ ("UVR2" :> UA("T2", "VecRefT2"))
    @@ ("UVV1" :> UA("T1", "VecVecT1"))
    @@ ("UT1" :> UA("T1", "TupT1")) @@ ("UT2" :> UA("T1", "TupT1Int")) @@ ("UT2any" :> UA("T1", "TupT1Any"))

Ids == DOMAIN Obj
UAs == {o \in Ids : Obj[o].k = "ua"}
Name(x) == ClassName[Obj[x].cls]

\* the environment: a sequence of <<var, val>>, innermost first (jl_typeenv_t's prev chain; the port's svec chain)
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
    CASE ox.k = "dt" -> /\ Name(x) = Name(y)
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

\* ---- the port's table: src/intrinsics.jl:1565-1573, over the classes in the IdDict's order ----
RECURSIVE Perms(_)
Perms(S) == IF S = {} THEN {<<>>} ELSE UNION {{<<c>> \o p : p \in Perms(S \ {c})} : c \in S}
Orders == Perms(Classes)
\* names: the TypeNames met so far, in order; idx: each class met, its index (the first appearance of its TypeName,
\* `findfirst(x -> x === tn, names)`, else pushed); TableByClass gives each class an index of its own
RECURSIVE Build(_, _, _)
Build(ord, names, idx) ==
  IF ord = <<>> THEN idx
  ELSE LET c == Head(ord)
           tn == IF TableByClass THEN c ELSE ClassName[c]
           is == {i \in DOMAIN names : names[i] = tn}
           k == IF is = {} THEN Len(names) + 1 ELSE CHOOSE i \in is : \A j \in is : i <= j
       IN Build(Tail(ord), IF is = {} THEN Append(names, tn) ELSE names, idx @@ (c :> k))
Table(ord) == Build(ord, <<>>, <<>>)

\* ---- the port: jl_egal_types's walk over a worklist ----
Item(x, y, env) == [x |-> x, y |-> y, env |-> env]
\* tbl: the table the closed world's order of its classes built (the order itself read no further)
VARIABLES tbl, a, b, work, outcome
vars == <<tbl, a, b, work, outcome>>

Init == /\ tbl \in {Table(o) : o \in Orders}
        /\ a \in UAs
        /\ b \in UAs
        /\ work = <<Item(a, b, <<>>)>>
        /\ outcome = "run"

Answer(o) == outcome' = o /\ UNCHANGED <<tbl, a, b, work>>
Pop(rest) == work' = rest /\ UNCHANGED <<tbl, a, b, outcome>>
\* the shorter parameter vector's length: NoLength walks the pairs over it
Shorter(ox, oy) == IF Len(ox.ps) <= Len(oy.ps) THEN Len(ox.ps) ELSE Len(oy.ps)

Step ==
  /\ outcome = "run"
  /\ IF work = <<>> THEN Answer("egal")
     ELSE LET it == Head(work)  rest == Tail(work)
              x == it.x  y == it.y  env == it.env
              ox == Obj[x]  oy == Obj[y] IN
       CASE ox.k # oy.k -> Answer("notegal")
         [] ox.k = "dt" ->
              IF x = y THEN Pop(rest)
              ELSE IF ~NoTypeName /\ tbl[ox.cls] # tbl[oy.cls] THEN Answer("notegal")
              ELSE IF ~NoLength /\ Len(ox.ps) # Len(oy.ps) THEN Answer("notegal")
              ELSE Pop([i \in 1..Shorter(ox, oy) |-> Item(ox.ps[i], oy.ps[i], env)] \o rest)
         [] ox.k = "tv" ->
              IF x = y THEN Pop(rest)
              ELSE IF Lookup(env, x) = y THEN Pop(rest) ELSE Answer("notegal")
         [] ox.k = "ua" ->
              IF Obj[ox.var].name # Obj[oy.var].name THEN Answer("notegal")
              ELSE Pop(<<Item(Obj[ox.var].lb, Obj[oy.var].lb, env),
                         Item(Obj[ox.var].ub, Obj[oy.var].ub, env),
                         Item(ox.body, oy.body, Extend(x, y, env))>> \o rest)
         [] ox.k = "un" -> Pop(<<Item(ox.a, oy.a, env), Item(ox.b, oy.b, env)>> \o rest)
         [] OTHER -> IF ox.v = oy.v THEN Pop(rest) ELSE Answer("notegal")
Stop == outcome # "run" /\ UNCHANGED vars
Next == Step \/ Stop
Spec == Init /\ [][Next]_vars /\ WF_vars(Step)

Done == outcome # "run"

TypeOK == /\ tbl \in [Classes -> 1..NClasses]
          /\ a \in UAs /\ b \in UAs
          /\ work \in Seq([x : Ids, y : Ids, env : Seq(Ids \X Ids)])
          /\ outcome \in {"run", "egal", "notegal"}

Agrees == Done => ((outcome = "egal") = JuliaEgal(a, b))
NameTable == \A c, d \in Classes : (tbl[c] = tbl[d]) = (ClassName[c] = ClassName[d])
Ends == <>Done
=============================================================================
