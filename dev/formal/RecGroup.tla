----------------------------- MODULE RecGroup -----------------------------
(***************************************************************************)
(* A TLA+ model of how WT registers struct types whose fields reach back   *)
(* to themselves (register_struct_type!, src/codegen/structs.jl) and how   *)
(* the type section's recursion groups follow (to_bytes, instructions.jl). *)
(*                                                                         *)
(* WHAT THE REAL CODE DOES. A type's wasm index is fixed when it is added: *)
(* function bodies are bytes by the time the module is written, so WT      *)
(* cannot renumber types at the end the way dart2wasm does. Registration   *)
(* is therefore Tarjan's depth-first search over the types the one field   *)
(* translator reaches. A registrar records its type as PENDING before it   *)
(* translates the fields, so a field reaching a type still being           *)
(* registered finds the pending entry and refers to it; when the           *)
(* translation is done (finish_pending!), the type's lowlink is the least  *)
(* lowlink among the pending types it refers to. A type whose lowlink is   *)
(* its own number is the root of a strongly connected component: it and   *)
(* every type pending above it take consecutive indices, and their pending *)
(* references resolve. Every other type a member reaches finished earlier, *)
(* at a smaller index. The type section's recursion groups are the         *)
(* strongly connected components of the finished section (dart's           *)
(* _createAllRecursiveGroups).                                             *)
(*                                                                         *)
(* THE CLAIM. The section is valid wasm (Valid: every reference is to an   *)
(* earlier group or to its own group, and groups are contiguous); no field *)
(* loses its type (Exact); a group is exactly a cycle (Minimal, dart's     *)
(* rec groups); every requested type is registered (Complete). Three      *)
(* Broken variants: the placeholder-and-patch registration this replaced   *)
(* (only a type's direct self-reference reserved an index; a field        *)
(* reaching a type still being registered by another route was erased to  *)
(* `structref`), define-then-fill without the component (a type defined    *)
(* before the types its fields reach, with no groups, refers forward), and *)
(* a lowlink                                                                *)
(* that takes a finished child's number instead of its lowlink (a cycle    *)
(* through the child's descendants is split, and a group refers forward).  *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Types are nodes; an edge is a field whose    *)
(* wasm type is another registered type (a struct, a Vector wrapper, a     *)
(* Memory's array). Every graph over three nodes, and every order in which *)
(* codegen asks for them, is checked. Successors are visited in node      *)
(* order (the real code: field order).                                     *)
(*                                                                         *)
(* formal(src/codegen/structs.jl finish_pending!): a type is added with    *)
(* its strongly connected component, the types it reaches outside it       *)
(* first, so every field keeps its type and every reference is backward or *)
(* within its group.                                                       *)
(*                                                                         *)
(* parity(pkg/wasm_builder/lib/src/builder/types.dart:240                  *)
(* _RecGroupBuilder._createAllRecursiveGroups): recursion groups are the   *)
(* strongly connected components of the type graph, in dependency order;   *)
(* (class_info.dart:420 _createStructForClass, :539 _generateFields):      *)
(* define the struct, then fill its fields.                                *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS N, Variant   \* "scc" (the real code); "lowbyindex", "placeholder", "definefirst" (broken)

Nodes == 1..N
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

\* the transitive closure of a relation over Nodes
RECURSIVE Closure(_, _)
Closure(R, k) == IF k = 0 THEN R
                 ELSE Closure(R \cup {<<x[1][1], x[2][2]>> : x \in {y \in R \X R : y[1][2] = y[2][1]}}, k - 1)

RECURSIVE SeqOf(_)
SeqOf(S) == IF S = {} THEN <<>> ELSE <<Min(S)>> \o SeqOf(S \ {Min(S)})

VARIABLES edges, requests, st, done
vars == <<edges, requests, st, done>>

Reach == Closure(edges, N)
SCC(n) == {n} \cup {m \in Nodes : <<n, m>> \in Reach /\ <<m, n>> \in Reach}

\* registration state: the type section (a sequence of nodes), its groups, the erased fields,
\* and the search's pending stack with each node's number and lowlink (0: never visited)
Registered(s) == {s.order[i] : i \in 1..Len(s.order)}
OnStack(s, n) == \E i \in 1..Len(s.stack) : s.stack[i] = n
Empty == [order |-> <<>>, groups |-> <<>>, erased |-> {}, stack |-> <<>>,
          num |-> [n \in Nodes |-> 0], low |-> [n \in Nodes |-> 0], next |-> 1]
SetOf(q) == {q[i] : i \in 1..Len(q)}

\* ---- the real code: Tarjan's search over the translator's references ----
\* a registrar pushes its node pending, translates the fields (visiting what they reach), then
\* finish_pending!: the lowlink is the least lowlink of the pending nodes the type refers to
RECURSIVE RegScc(_, _), RegSccAll(_, _)
RegScc(n, s) ==
    IF n \in Registered(s) \/ OnStack(s, n) THEN s
    ELSE LET s1   == [s EXCEPT !.num[n] = s.next, !.low[n] = s.next, !.next = s.next + 1,
                               !.stack = Append(s.stack, n)]
             succ == {t \in Nodes : <<n, t>> \in edges}
             s2   == RegSccAll(succ, s1)
             pend == {t \in succ : OnStack(s2, t)}
             ll   == Min({s2.low[n]} \cup
                         {IF Variant = "lowbyindex" /\ t # n /\ s2.num[t] > s2.num[n]
                          THEN s2.num[t] ELSE s2.low[t] : t \in pend})
         IN IF ll = s2.num[n]
            THEN LET k == CHOOSE i \in 1..Len(s2.stack) : s2.stack[i] = n
                     C == SubSeq(s2.stack, k, Len(s2.stack))
                 IN [s2 EXCEPT !.stack = SubSeq(s2.stack, 1, k - 1), !.order = s2.order \o C,
                               !.groups = Append(s2.groups, SetOf(C))]
            ELSE [s2 EXCEPT !.low[n] = ll]
RegSccAll(S, s) == IF S = {} THEN s ELSE RegSccAll(S \ {Min(S)}, RegScc(Min(S), s))

\* ---- broken: placeholder-and-patch (a direct self-reference only) ----
\* a successor still in progress by another route is erased (the caller's StructRef)
RECURSIVE RegPh(_, _, _), RegPhAll(_, _, _)
RegPh(n, s, inprog) ==
    IF n \in Registered(s) \/ n \in inprog THEN s
    ELSE LET succ == {t \in Nodes : <<n, t>> \in edges /\ t # n}
             s1   == RegPhAll(succ, s, inprog \cup {n})
             lost == {<<n, t>> : t \in {u \in succ : u \notin Registered(s1)}}
         IN [s1 EXCEPT !.order = Append(s1.order, n), !.groups = Append(s1.groups, {n}),
                       !.erased = s1.erased \cup lost]
RegPhAll(S, s, inprog) == IF S = {} THEN s ELSE RegPhAll(S \ {Min(S)}, RegPh(Min(S), s, inprog), inprog)

\* ---- broken: define first, then register what the fields reach, no groups ----
RECURSIVE RegDf(_, _), RegDfAll(_, _)
RegDf(n, s) ==
    IF n \in Registered(s) THEN s
    ELSE LET s1 == [s EXCEPT !.order = Append(s.order, n), !.groups = Append(s.groups, {n})]
         IN RegDfAll({t \in Nodes : <<n, t>> \in edges}, s1)
RegDfAll(S, s) == IF S = {} THEN s ELSE RegDfAll(S \ {Min(S)}, RegDf(Min(S), s))

Reg(n, s) == CASE Variant \in {"scc", "lowbyindex"} -> RegScc(n, s)
               [] Variant = "placeholder" -> RegPh(n, s, {})
               [] Variant = "definefirst" -> RegDf(n, s)

RECURSIVE Run(_, _)
Run(rs, s) == IF rs = <<>> THEN s ELSE Run(Tail(rs), Reg(Head(rs), s))

Perms == {p \in [1..N -> Nodes] : \A i, j \in 1..N : i # j => p[i] # p[j]}

Init == /\ edges \in SUBSET (Nodes \X Nodes)
        /\ requests \in Perms
        /\ st = Empty /\ done = FALSE
Step == ~done /\ st' = Run([i \in 1..N |-> requests[i]], Empty) /\ done' = TRUE
        /\ UNCHANGED <<edges, requests>>
Spec == Init /\ [][Step]_vars

\* ---- the claims, on the finished section ----
Index(s, n) == CHOOSE i \in 1..Len(s.order) : s.order[i] = n
GroupOf(s, n) == CHOOSE g \in {s.groups[k] : k \in 1..Len(s.groups)} : n \in g
GroupStart(s, n) == Min({Index(s, m) : m \in GroupOf(s, n)})
Contiguous(s) == \A k \in 1..Len(s.groups) :
    LET ix == {Index(s, m) : m \in s.groups[k]} IN
    \A i \in Min(ix)..(Min(ix) + Cardinality(ix) - 1) : i \in ix

Valid == done => (Contiguous(st) /\
    \A e \in edges \ st.erased :
        Index(st, e[2]) < GroupStart(st, e[1]) \/ GroupOf(st, e[2]) = GroupOf(st, e[1]))
Exact == done => st.erased = {}
Minimal == done => \A k \in 1..Len(st.groups) :
    \A a, b \in st.groups[k] : a = b \/ <<a, b>> \in Reach
Complete == done => (Registered(st) = Nodes /\ Len(st.order) = N)
=============================================================================
