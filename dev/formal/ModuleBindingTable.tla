------------------------- MODULE ModuleBindingTable -------------------------
(***************************************************************************)
(* A TLA+ model of the module binding table (src/julia/runtime/bindings.jl  *)
(* module_binding_table, and its readers jl_get_module_binding, jl_is_const,*)
(* jl_is_binding_deprecated and jl_boundp): the image of Julia's module     *)
(* bindings a closed world holds, which a query of a (module, name) pair    *)
(* only run time knows reads. Julia's image keeps each module's bindings,   *)
(* pruned to what the image reaches (julia/src/staticdata.c:2694            *)
(* jl_prune_module_bindings), and its runtime answers a query from the      *)
(* module it holds (julia/src/module.c:1524 jl_get_module_binding, :1800    *)
(* jl_is_const, :1853 jl_is_binding_deprecated, :1468 jl_boundp). dart has  *)
(* no counterpart: a dart program reflects on no top-level binding at run   *)
(* time; precedent(julia: staticdata.c's prune and module.c's lookups).     *)
(*                                                                          *)
(* ABSTRACTION. A pair is a module and a name; Native is Julia's answer for *)
(* each pair in the compiling process at the program's world (its binding,  *)
(* "none" where the module holds none, or a binding's facts), any function  *)
(* of the pairs (Init picks every one). The table's domain is every Module  *)
(* constant the program holds by every Symbol constant it holds (the lead's *)
(* ruling, 2026-11-26); a module or a name the program makes at run time    *)
(* (Symbol(...), 3c0c2b38) is outside it. The query is one pair the program *)
(* may reach, any pair (Init picks every one).                              *)
(*                                                                          *)
(* Claims, once the query is answered:                                     *)
(*   Sound     an answer that is not the fatal arm is Native's for the pair*)
(*   Answered  a pair the program holds is answered, never fatal           *)
(*   Ends      the query is answered                                       *)
(* Broken: MCModuleBindingTableAbsentBroken.cfg (AbsentOutside), a pair    *)
(* outside the table answered "none", as if the module held no binding:    *)
(* native answers from the whole module, so Sound fails (D9).              *)
(* MCModuleBindingTableEarlyBroken.cfg (EarlyBuild), the table built before *)
(* the last constant is made: a pair the program holds reads the fatal arm,*)
(* so Answered fails.                                                       *)
(***************************************************************************)
CONSTANTS AbsentOutside, EarlyBuild

Mods      == {"m1", "m2", "m3"}
Syms      == {"s1", "s2", "s3"}
ConstMods == {"m1", "m2"}      \* the Module constants the program holds
ConstSyms == {"s1", "s2"}      \* the Symbol constants the program holds
Pairs     == Mods \X Syms
Held      == ConstMods \X ConstSyms
Answers   == {"none", "b1"}

Lookup(dom, nat, p) == IF p \in dom THEN nat[p]
                       ELSE IF AbsentOutside THEN "none" ELSE "fatal"

VARIABLES native, madeM, madeS, frozen, dom, q, ans
vars == <<native, madeM, madeS, frozen, dom, q, ans>>

Init == /\ native \in [Pairs -> Answers]
        /\ madeM = {} /\ madeS = {}
        /\ frozen = FALSE /\ dom = {}
        /\ q \in Pairs
        /\ ans = "pending"

\* code generation makes the program's constants one at a time, in any order
MakeMod == /\ ~frozen /\ \E m \in ConstMods \ madeM : madeM' = madeM \cup {m}
           /\ UNCHANGED <<native, madeS, frozen, dom, q, ans>>
MakeSym == /\ ~frozen /\ \E s \in ConstSyms \ madeS : madeS' = madeS \cup {s}
           /\ UNCHANGED <<native, madeM, frozen, dom, q, ans>>
\* the linking action: the table built from the constants made, once every body is compiled
Freeze == /\ ~frozen
          /\ (EarlyBuild \/ (madeM = ConstMods /\ madeS = ConstSyms))
          /\ frozen' = TRUE /\ dom' = madeM \X madeS
          /\ UNCHANGED <<native, madeM, madeS, q, ans>>
\* the program runs: one query of a pair it reaches
Answer == /\ frozen /\ ans = "pending"
          /\ ans' = Lookup(dom, native, q)
          /\ UNCHANGED <<native, madeM, madeS, frozen, dom, q>>
Stop == ans # "pending" /\ UNCHANGED vars
Next == MakeMod \/ MakeSym \/ Freeze \/ Answer \/ Stop
Spec == Init /\ [][Next]_vars /\ WF_vars(MakeMod \/ MakeSym \/ Freeze \/ Answer)

TypeOK == /\ native \in [Pairs -> Answers] /\ madeM \subseteq ConstMods /\ madeS \subseteq ConstSyms
          /\ frozen \in BOOLEAN /\ dom \subseteq Pairs /\ q \in Pairs
          /\ ans \in Answers \cup {"pending", "fatal"}

Sound    == ans \notin {"pending", "fatal"} => ans = native[q]
Answered == (ans # "pending" /\ q \in Held) => ans # "fatal"
Ends     == <>(ans # "pending")
=============================================================================
