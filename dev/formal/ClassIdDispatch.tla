---------------------------- MODULE ClassIdDispatch ----------------------------
(***************************************************************************)
(* A TLA+ model of WasmTarget's two coupled closed-world structures:         *)
(*                                                                           *)
(*   (a) the DFS classId numbering with subtype ranges                       *)
(*       formal(src/codegen/types.jl assign_type_ids!)   -- the ONE DFS      *)
(*       formal(src/codegen/compile.jl _collect_reachable_ir_types)          *)
(*       read by  values.jl:714 emit_isa_classid!  (concrete `isa`: id ==)   *)
(*       and      calls.jl:1978-2006             (abstract `isa`: range)     *)
(*       parity(class_info.dart:831 ClassIdNumbering.getConcreteClassIdRange)*)
(*                                                                           *)
(*   (b) the ONE flat selector dispatch table                                *)
(*       formal(src/codegen/dispatch.jl build_dispatch_tables)               *)
(*       formal(src/codegen/selector_table.jl pack_dispatch_selectors!)      *)
(*       read by  selector_table.jl:226 generate_selector_caller_body        *)
(*       parity(dispatch_table.dart:396 DispatchTable, :501 build;           *)
(*              translator.dart:911 callDispatchTable)                       *)
(*                                                                           *)
(* WHAT IS ABSTRACTED AND WHY IT SUFFICES.                                   *)
(*                                                                           *)
(* Classes are the naturals 1..N and the class NAME is its number: Julia     *)
(* sorts DFS children by `string(T)` (types.jl:498), so "ascending number"    *)
(* is exactly "ascending sort key".  Class 0 is the root (`Any`).  The        *)
(* hierarchy is a tree with parent[c] < c; in Julia the parent map is the     *)
(* nearest supertype in the collected set, which -- because EVERY abstract   *)
(* on a concrete type's supertype chain is collected -- is the direct        *)
(* supertype.  Julia normalizes parametric abstracts to their base type; the *)
(* model has no type parameters, so it models the non-parametric path only.  *)
(*                                                                           *)
(* Concrete classes are exactly the tree's leaves (a concrete Julia type has *)
(* no subtypes; an abstract type enters the numbering only as an ancestor of *)
(* a concrete one, so it always has a child in the walked set -- the         *)
(* `(low, low)` single-id branch of dfs! is kept but is unreachable).        *)
(*                                                                           *)
(* Phase 12B (dev/MARCH.md) deleted the SECOND numbering path: every concrete*)
(* kind that can carry a classId (structs, closures, `Core.Box`, primitives  *)
(* incl. `Char`/`Int128`, `Memory`) is now admitted by                        *)
(* `_collect_reachable_ir_types` BEFORE `assign_type_ids!` runs, so the      *)
(* closed world is numbered exactly ONCE, like dart's ClassIdNumbering       *)
(* (class_info.dart:831) -- there is no more `early`/`Late` split and no     *)
(* lazily-allocated id.  `ensure_type_id!` on an unnumbered type is now a    *)
(* loud collector bug (error), never a second numbering.                    *)
(*                                                                           *)
(* The DFS is modeled step by step with an explicit stack (one frame per      *)
(* abstract node: [node, low, pending kids]), mirroring dfs!'s recursion:     *)
(* a concrete child takes `counter` and bumps it; an abstract child opens a   *)
(* frame; closing a frame writes [low, counter-1].  Numbering is a pure       *)
(* function of the tree PROVIDED siblings are visited in name order          *)
(* (`sort!(kids, by=T->string(T))`, types.jl:498) -- the one remaining        *)
(* nondeterminism risk this model checks is THAT sort being lost.            *)
(* `UnsortedIteration = TRUE` lets `dfs!` visit a node's children in ANY      *)
(* order instead of name order (the Broken variant: someone drops or         *)
(* misapplies the `sort!` call).  Determinism compares the final ids with a   *)
(* closed-form canonical numbering (leaf rank in lexicographic root-path      *)
(* order), which also cross-checks the stepwise DFS.                         *)
(*                                                                           *)
(* Dispatch: a selector is a generic function with a Julia METHOD TABLE       *)
(* (signatures over Types, abstract allowed); Julia's dispatch answer for a  *)
(* concrete tuple is the unique componentwise-most-specific applicable       *)
(* signature (none => MethodError / ambiguity).  WT's DispatchEntry set is   *)
(* one entry per compiled specialization keyed by classId tuple; the model   *)
(* takes the closed world to be total over concrete tuples (every tuple      *)
(* with an answer is a specialization) -- an over-approximation of the       *)
(* compiled set that can only ADD rows, never change a target.  The table is *)
(* built exactly as pack_dispatch_selectors!: varying axes on the id tuples, *)
(* threshold 2, weight = 10*rows, weight-descending order with Dict order on *)
(* ties (any order), first-fit `_fit!` (offset may be negative; start =      *)
(* first_available - min cid), tied first-axis groups packed as a second hop *)
(* through the SAME table.  `NoCascadeReject = TRUE` takes a tied group's    *)
(* first entry instead (the shape the code had before the cascade).          *)
(*                                                                           *)
(* A call is receiver.classId + offset -> call_indirect.  A slot of another  *)
(* selector with the same signature shape runs SILENTLY (add_type! dedupes   *)
(* structurally equal FuncTypes, instructions.jl:487, so call_indirect's     *)
(* type check passes); a differently-shaped one traps; an empty slot traps.  *)
(* A wrapper's downcast of the receiver is modeled as succeeding: WT shares  *)
(* one wasm struct type between Julia types of identical layout              *)
(* (is_shared_wasm_type), so this is the reachable worst case.               *)
(*                                                                           *)
(* Julia's dynamic call on a receiver tuple with NO matching method must     *)
(* trap (MethodError).  dart never guards its virtual call -- static typing  *)
(* guarantees the selector exists on the receiver (code_generator.dart:2028  *)
(* _virtualCall; dispatch_table.dart:405-458 packs rows for exactly the      *)
(* classes that have the member) -- so WT adds three Julia-only guards,      *)
(* quarantined from the dart shape: (a) `_fit!` reserves a selector's WHOLE  *)
(* span [offset+minCid, offset+maxCid] (holes inside it stay null and trap), *)
(* likewise every cascade's level-2 span; (b) the selector caller and every  *)
(* trampoline check minCid <= classId <= maxCid before call_indirect, else   *)
(* `unreachable`; (c) every entry wrapper checks each slot other than the    *)
(* level-1 axis: the receiver's classId must equal the entry's typeId, else  *)
(* `unreachable` (the axis-1 slot is verified by the guarded index itself; a *)
(* singleton group's axis-2 slot is verified by nobody else, so the wrapper  *)
(* checks it; a tied group's is re-checked, cheaply).  `NoSpanGuard = TRUE`  *)
(* removes all three (the pre-fix code, which MissingMethodTraps rejects).   *)
(*                                                                           *)
(* All of this is sequential and finite, so exhaustive enumeration over      *)
(* small trees and method tables checks the algorithmic claims directly; no  *)
(* concurrency or memory model is involved.                                  *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, Sequences

CONSTANTS
    N,                  \* classes are 1..N (the name IS the sort key); 0 is the root `Any`
    Selectors,          \* generic functions that may own a dispatch table
    Arity,              \* [Selectors -> {1, 2}]
    MethodSpace,        \* set of [Selectors -> SUBSET Sigs(Arity[s])] : candidate method tables
    UnsortedIteration,  \* Broken: dfs! visits a node's children in ANY order, not name order
    NoCascadeReject,    \* Broken: a tied first-axis group takes its first entry, no second hop
    NoSpanGuard         \* Broken: no span reservation, no classId guard, no wrapper slot check

Root    == 0
Classes == 1..N
Types   == 0..N
NoSel   == "none"

VARIABLES
    parent,     \* [Classes -> Types] with parent[c] < c : the direct supertype
    methods,    \* [Selectors -> SUBSET Sigs(Arity[s])] : the Julia method tables
    ent,        \* [Selectors -> SUBSET tuples] : Julia's answered tuples (the DispatchEntry set)
    phase,      \* "dfs" -> "pack" -> "done" (the compile.jl order)
    stack,      \* dfs! frames <<[node, low, pend]>>
    counter,    \* the DFS counter (starts at 1; id 0 = unassigned)
    ids,        \* [Classes -> Nat] : registry.type_ids (concrete only; 0 = none)
    ranges,     \* [Types -> <<>> | <<lo, hi>>] : registry.type_ranges
    table,      \* SUBSET slot records : THE flat selector table (occupied cells)
    offs,       \* [Selectors -> Int] : selector_offset
    casc,       \* SUBSET [sel, cid, off2] : selector_cascades
    firstAvail, \* first_available
    packed,     \* SUBSET Selectors : packed so far
    cur,        \* selector whose tied groups are being packed, or NoSel
    pendCasc    \* tied first-axis cids of `cur` still to pack (ascending order)

vars == <<parent, methods, ent, phase, stack, counter, ids, ranges,
          table, offs, casc, firstAvail, packed, cur, pendCasc>>

----------------------------------------------------------------------------
(* Set / sequence helpers. *)

Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Max(S) == CHOOSE x \in S : \A y \in S : x >= y

RECURSIVE SortSeq(_)
SortSeq(S) == IF S = {} THEN <<>> ELSE <<Min(S)>> \o SortSeq(S \ {Min(S)})

(* Every bijective sequence 1..k -> S : every order `dfs!` could visit S's       *)
(* elements in if the `sort!` call were lost or misapplied.                     *)
Perms(S) == LET k == Cardinality(S)
            IN {f \in [1..k -> S] : \A i, j \in 1..k : i # j => f[i] # f[j]}

(* The orders `dfs!` may present a node's children in: exactly the sorted order *)
(* when the code is right, any permutation when UnsortedIteration models the    *)
(* `sort!` call being lost. *)
ChildOrders(S) == IF UnsortedIteration THEN Perms(S) ELSE {SortSeq(S)}

(* Bounded method-table families (used by MC modules to build MethodSpace). *)
Sigs(k)  == [1..k -> Types]
Sets1(S) == {{a} : a \in S}
Sets2(S) == {{a, b} : a \in S, b \in S}
Sets3(S) == {{a, b, c} : a \in S, b \in S, c \in S}
UpTo(S, k) == CASE k = 0 -> {{}}
                [] k = 1 -> {{}} \cup Sets1(S)
                [] k = 2 -> {{}} \cup Sets1(S) \cup Sets2(S)
                [] k = 3 -> {{}} \cup Sets1(S) \cup Sets2(S) \cup Sets3(S)

----------------------------------------------------------------------------
(* The hierarchy. *)

Kids(n)  == {c \in Classes : parent[c] = n}
Concrete == {c \in Classes : Kids(c) = {}}
Abstract == Types \ Concrete

RECURSIVE Anc(_)
Anc(c) == IF c = Root THEN {} ELSE {parent[c]} \cup Anc(parent[c])

Sub(a, b) == a = b \/ b \in Anc(a)          \* a <: b

(* Closed-form canonical numbering: with children visited in name order, the *)
(* DFS numbers leaves in lexicographic order of their root paths.            *)
RECURSIVE Path(_)
Path(c) == IF c = Root THEN <<>> ELSE Append(Path(parent[c]), c)

RECURSIVE LexLess(_, _)
LexLess(p, q) == IF p = <<>> THEN q # <<>>
                 ELSE IF q = <<>> THEN FALSE
                 ELSE IF Head(p) < Head(q) THEN TRUE
                 ELSE IF Head(p) > Head(q) THEN FALSE
                 ELSE LexLess(Tail(p), Tail(q))

DfsRank(c)    == 1 + Cardinality({d \in Concrete : LexLess(Path(d), Path(c))})
CanonicalIds == [c \in Classes |-> IF c \in Concrete THEN DfsRank(c) ELSE 0]

----------------------------------------------------------------------------
(* Julia dispatch on the hierarchy, and WT's DispatchEntry set. *)

K(s) == Arity[s]
Tup(k, S) == [1..k -> S]

Appl(s, t)     == {m \in methods[s] : \A i \in 1..K(s) : Sub(t[i], m[i])}
MostSpec(s, t) == {m \in Appl(s, t) : \A m2 \in Appl(s, t) : \A i \in 1..K(s) : Sub(m[i], m2[i])}
HasEntry(s, t) == Cardinality(MostSpec(s, t)) = 1          \* unique most specific; else MethodError
Target(s, t)   == CHOOSE m \in MostSpec(s, t) : TRUE

JuliaEntries(s) == {t \in Tup(K(s), Concrete) : HasEntry(s, t)}  \* the specializations (dedup by tuple)
Entries(s) == ent[s]                                              \* build_dispatch_tables' entry set

(* pack_dispatch_selectors!: axes that vary on the id tuples; 1 or 2 are routable. *)
HasTable(s) == Cardinality(Entries(s)) >= 2                 \* threshold = 2
Varying(s)  == {i \in 1..K(s) : Cardinality({ids[t[i]] : t \in Entries(s)}) > 1}
Routable(s) == HasTable(s) /\ Cardinality(Varying(s)) \in {1, 2}
Axis1(s)    == Min(Varying(s))
Axis2(s)    == Max(Varying(s))                              \* = Axis1 for a single axis
Cids(s)     == {ids[t[Axis1(s)]] : t \in Entries(s)}
Group(s, cid) == {t \in Entries(s) : ids[t[Axis1(s)]] = cid}
Tied(s, cid)  == Cardinality(Group(s, cid)) > 1
Weight(s)   == Cardinality(Cids(s)) * 10
TiedCids(s) == IF NoCascadeReject THEN {} ELSE {cid \in Cids(s) : Tied(s, cid)}
(* `g[1]`: the first registered entry of a group; registration order is history, so *)
(* the model takes the smallest second-axis id as its stand-in.                    *)
FirstOf(s, G) == CHOOSE t \in G : \A t2 \in G : ids[t[Axis2(s)]] <= ids[t2[Axis2(s)]]

(* The selector's call_indirect signature shape: per slot, one class => AnyRef  *)
(* (dispatch.jl:186-192 gives structs AnyRef), several => the deepest common   *)
(* declared ancestor (the struct-LUB, :193-215; the root means AnyRef).        *)
CommonAnc(S) == {a \in Types : \A c \in S : Sub(c, a)}
Deepest(A)   == CHOOSE a \in A : \A b \in A : Sub(a, b)
SlotType(s, i) == LET S == {t[i] : t \in Entries(s)}
                  IN IF Cardinality(S) = 1 THEN Root ELSE Deepest(CommonAnc(S))
Sig(s) == [i \in 1..K(s) |-> SlotType(s, i)]
SameSig(s1, s2) == K(s1) = K(s2) /\ Sig(s1) = Sig(s2)

----------------------------------------------------------------------------
(* The flat table: first-fit `_fit!`. *)

PosBound  == N * N * Cardinality(Selectors) + 2 * N + 2
OffWindow == (0 - (N + 1))..PosBound

Occ(tbl, p) == \E e \in tbl : e.pos = p
(* The cells a row set claims: its whole span (guarded), or just its rows (NoSpanGuard). *)
Span(cids) == IF NoSpanGuard THEN cids ELSE Min(cids)..Max(cids)
Fits(tbl, off, cids) == \A cid \in Span(cids) : off + cid >= 0 /\ ~Occ(tbl, off + cid)
FirstFit(tbl, cids, start) ==
    CHOOSE off \in OffWindow :
        /\ off >= start
        /\ Fits(tbl, off, cids)
        /\ \A o \in OffWindow : (o >= start /\ o < off) => ~Fits(tbl, o, cids)
Advance(tbl, p) == Min({q \in p..PosBound : ~Occ(tbl, q)})   \* the while-advance of first_available

Unpacked == {s \in Selectors : Routable(s) /\ s \notin packed}
HeaviestUnpacked == {s \in Unpacked : \A s2 \in Unpacked : Weight(s) >= Weight(s2)}

----------------------------------------------------------------------------
Init ==
    /\ parent \in {p \in [Classes -> Types] : \A c \in Classes : p[c] < c}
    /\ methods \in MethodSpace
    /\ ent = [s \in Selectors |-> JuliaEntries(s)]
    /\ phase = "dfs"
    /\ \E p \in ChildOrders(Kids(Root)) : stack = << [node |-> Root, low |-> 1, pend |-> p] >>
    /\ counter = 1
    /\ ids = [c \in Classes |-> 0]
    /\ ranges = [t \in Types |-> <<>>]
    /\ table = {}
    /\ offs = [s \in Selectors |-> 0]
    /\ casc = {}
    /\ firstAvail = 0
    /\ packed = {}
    /\ cur = NoSel
    /\ pendCasc = {}

----------------------------------------------------------------------------
(* (a) assign_type_ids!: dfs!(Any) with children in sort-key order (or ANY   *)
(* order, per UnsortedIteration -- the regression this model now guards).    *)

Top == stack[Len(stack)]

(* dfs!(child): a concrete leaf takes the counter; an abstract child opens a frame. *)
DfsVisit ==
    /\ phase = "dfs"
    /\ Top.pend # <<>>
    /\ LET k    == Head(Top.pend)
           rest == [stack EXCEPT ![Len(stack)].pend = Tail(@)]
       IN IF k \in Concrete
            THEN /\ ids'     = [ids EXCEPT ![k] = counter]
                 /\ ranges'  = [ranges EXCEPT ![k] = <<counter, counter>>]
                 /\ counter' = counter + 1
                 /\ stack'   = rest
            ELSE /\ \E p \in ChildOrders(Kids(k)) :
                      stack' = Append(rest, [node |-> k, low |-> counter, pend |-> p])
                 /\ UNCHANGED <<ids, ranges, counter>>
    /\ UNCHANGED <<parent, methods, ent, phase, table, offs, casc,
                   firstAvail, packed, cur, pendCasc>>

(* All kids visited: [low, counter-1], or the single-id branch when nothing was numbered. *)
DfsClose ==
    /\ phase = "dfs"
    /\ Top.pend = <<>>
    /\ IF Top.low = counter
         THEN /\ ranges'  = [ranges EXCEPT ![Top.node] = <<Top.low, Top.low>>]
              /\ counter' = counter + 1
         ELSE /\ ranges'  = [ranges EXCEPT ![Top.node] = <<Top.low, counter - 1>>]
              /\ counter' = counter
    /\ stack' = SubSeq(stack, 1, Len(stack) - 1)
    /\ phase' = IF Len(stack) = 1 THEN "pack" ELSE "dfs"
    /\ UNCHANGED <<parent, methods, ent, ids, table, offs, casc,
                   firstAvail, packed, cur, pendCasc>>

----------------------------------------------------------------------------
(* (b) build_dispatch_tables + pack_dispatch_selectors!: runs after numbering *)
(* and BEFORE body codegen (compile.jl:1050-1055 vs the bodies at :1100+), so *)
(* every concrete type already has an id (Phase 12B: numbering is complete   *)
(* before this phase runs -- there is no more "a late type has id 0" case).  *)

Slot(p, s, kind, cid, cid2) == [pos |-> p, sel |-> s, kind |-> kind, cid |-> cid, cid2 |-> cid2]

PackLevel1 ==
    /\ phase = "pack"
    /\ cur = NoSel
    /\ Unpacked # {}
    /\ \E s \in HeaviestUnpacked :                       \* weight desc; Dict order on ties
         LET start == IF packed = {} THEN 0 ELSE firstAvail - Min(Cids(s))
             off   == FirstFit(table, Cids(s), start)
             slots == {Slot(off + cid, s,
                            IF cid \notin Cids(s) THEN "hole"
                            ELSE IF cid \in TiedCids(s) THEN "tramp" ELSE "row", cid, 0)
                       : cid \in Span(Cids(s))}
             tbl2  == table \cup slots
         IN /\ table'  = tbl2
            /\ offs'   = [offs EXCEPT ![s] = off]
            /\ packed' = packed \cup {s}
            /\ IF TiedCids(s) = {}
                 THEN /\ firstAvail' = Advance(tbl2, firstAvail)
                      /\ cur' = NoSel
                      /\ pendCasc' = {}
                 ELSE /\ firstAvail' = firstAvail
                      /\ cur' = s
                      /\ pendCasc' = TiedCids(s)
    /\ UNCHANGED <<parent, methods, ent, phase, stack, counter, ids, ranges, casc>>

(* One tied first-axis group: its second-axis rows are first-fit into the SAME table. *)
PackLevel2 ==
    /\ phase = "pack"
    /\ cur # NoSel
    /\ pendCasc # {}
    /\ LET cid   == Min(pendCasc)
           fa    == Advance(table, firstAvail)
           cids2 == {ids[t[Axis2(cur)]] : t \in Group(cur, cid)}
           off2  == FirstFit(table, cids2, fa - Min(cids2))
           slots == {Slot(off2 + c2, cur, IF c2 \in cids2 THEN "row2" ELSE "hole", cid, c2)
                     : c2 \in Span(cids2)}
           tbl2  == table \cup slots
           rest  == pendCasc \ {cid}
       IN /\ table'    = tbl2
          /\ casc'     = casc \cup {[sel |-> cur, cid |-> cid, off2 |-> off2]}
          /\ pendCasc' = rest
          /\ IF rest = {}
               THEN /\ firstAvail' = Advance(tbl2, fa)
                    /\ cur' = NoSel
               ELSE /\ firstAvail' = fa
                    /\ cur' = cur
    /\ UNCHANGED <<parent, methods, ent, phase, stack, counter, ids, ranges, offs, packed>>

PackDone ==
    /\ phase = "pack"
    /\ cur = NoSel
    /\ Unpacked = {}
    /\ phase' = "done"
    /\ UNCHANGED <<parent, methods, ent, stack, counter, ids, ranges,
                   table, offs, casc, firstAvail, packed, cur, pendCasc>>

----------------------------------------------------------------------------
Next ==
    \/ DfsVisit \/ DfsClose
    \/ PackLevel1 \/ PackLevel2 \/ PackDone
    \/ (phase = "done" /\ UNCHANGED vars)      \* terminal: a compiled module

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

----------------------------------------------------------------------------
(* Properties. *)

TypeOK ==
    /\ parent \in [Classes -> Types]
    /\ phase \in {"dfs", "pack", "done"}
    /\ ids \in [Classes -> 0..(2 * N)]
    /\ counter \in 1..(2 * N + 1)
    /\ \A t \in Types : ranges[t] = <<>> \/ (Len(ranges[t]) = 2 /\ ranges[t][1] <= ranges[t][2])
    /\ packed \subseteq Selectors

Numbered   == phase \in {"pack", "done"}
HasRange(t) == ranges[t] # <<>>
Lo(t) == ranges[t][1]
Hi(t) == ranges[t][2]

(* (2) RangesNest: sub-ranges nest, unrelated abstracts' ranges are disjoint. *)
RangesNest ==
    Numbered =>
      \A a, b \in Abstract : (HasRange(a) /\ HasRange(b)) =>
         /\ (Sub(a, b) => (Lo(b) <= Lo(a) /\ Hi(a) <= Hi(b)))
         /\ ((~Sub(a, b) /\ ~Sub(b, a)) => (Hi(a) < Lo(b) \/ Hi(b) < Lo(a)))

(* What the emitted `isa` computes: a concrete target compares classIds        *)
(* (values.jl:714 / calls.jl:1888); an abstract target needs a DFS range,      *)
(* which every abstract ancestor of a numbered concrete type now has          *)
(* (Phase 12B: the closed world is numbered once, so there is no more         *)
(* range-less ancestor).                                                      *)
IsaWT(c, T) ==
    IF T \in Concrete
      THEN ids[c] = ids[T]
      ELSE HasRange(T) /\ ids[c] \in Lo(T)..Hi(T)

(* (1) RangeIsa over every concrete class. T ranges over Classes: `isa(x, Any)` *)
(* is folded by Julia inference before WT sees it, so the root is never a     *)
(* range-check target.                                                        *)
RangeIsa ==
    phase = "done" => \A c \in Concrete, T \in Classes : IsaWT(c, T) <=> Sub(c, T)

(* (3) SlotUnique: no two rows share a table cell. *)
SlotUnique == \A e1, e2 \in table : e1.pos = e2.pos => e1 = e2

(* (4) The virtual call: receiver.classId + offset -> the cell; a trampoline   *)
(* cell re-dispatches on the second axis through the same table.             *)
SlotAt(p) == {e \in table : e.pos = p}

Outcome(k, m) == [k |-> k, m |-> m]
Trap    == Outcome("trap", <<>>)
Silent  == Outcome("foreign", <<>>)     \* another selector's same-shaped row runs
Loop    == Outcome("tramp", <<>>)       \* a trampoline reached again: not a method
Ok(m)   == Outcome("ok", m)

(* The entry a row cell stands for (the wrapper's target specialization). *)
RowEntry(e) ==
    IF e.kind = "row" THEN FirstOf(e.sel, Group(e.sel, e.cid))
    ELSE CHOOSE t \in Group(e.sel, e.cid) : ids[t[Axis2(e.sel)]] = e.cid2

(* (c) the wrapper: every slot but the level-1 axis must carry the entry's class. *)
WrapperOK(s, e, t) == NoSpanGuard \/ \A i \in (1..K(s)) \ {Axis1(s)} : t[i] = RowEntry(e)[i]

RowTarget(s, e, t) ==
    IF e.kind = "hole" THEN Trap
    ELSE IF e.kind = "tramp" THEN Loop
    ELSE IF WrapperOK(s, e, t) THEN Ok(Target(e.sel, RowEntry(e))) ELSE Trap

Foreign(e, s) == IF SameSig(e.sel, s) THEN Silent ELSE Trap

(* (b) the guard before call_indirect: classId inside the packed span. *)
InSpan(cid, cids) == NoSpanGuard \/ cid \in Min(cids)..Max(cids)

Resolve(s, e, t) ==
    IF e.sel # s THEN Foreign(e, s)
    ELSE IF e.kind # "tramp" THEN RowTarget(s, e, t)
    ELSE LET off2  == (CHOOSE k \in casc : k.sel = s /\ k.cid = e.cid).off2
             cids2 == {ids[t2[Axis2(s)]] : t2 \in Group(s, e.cid)}
             c2    == ids[t[Axis2(s)]]
             e2s   == SlotAt(off2 + c2)
         IN IF ~InSpan(c2, cids2) THEN Trap
            ELSE IF e2s = {} THEN Trap
            ELSE LET e2 == CHOOSE x \in e2s : TRUE
                 IN IF e2.sel # s THEN Foreign(e2, s) ELSE RowTarget(s, e2, t)

Lookup(s, t) ==
    LET cid == ids[t[Axis1(s)]]
        e1s == SlotAt(offs[s] + cid)
    IN IF ~InSpan(cid, Cids(s)) THEN Trap
       ELSE IF e1s = {} THEN Trap
       ELSE Resolve(s, CHOOSE e \in e1s : TRUE, t)

(* (4a) Every tuple WITH a Julia answer resolves to exactly that method. *)
DispatchExact ==
    phase = "done" =>
      \A s \in packed : \A t \in Tup(K(s), Concrete) :
         HasEntry(s, t) => Lookup(s, t) = Ok(Target(s, t))

(* (4b) Every tuple WITHOUT a Julia answer (MethodError) must trap, never run *)
(* some other row silently.                                                   *)
MissingMethodTraps ==
    phase = "done" =>
      \A s \in packed : \A t \in Tup(K(s), Concrete) :
         ~HasEntry(s, t) => Lookup(s, t) = Trap

(* (5) Determinism: the numbering is a function of the hierarchy alone. *)
Determinism == phase = "done" => ids = CanonicalIds

=============================================================================
