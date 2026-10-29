--------------------------- MODULE FixIrreducible ---------------------------
(***************************************************************************)
(* A TLA+ model of WebAssemblyFixIrreducibleControlFlow.cpp at the llvm    *)
(* pin (dev/PARITY_MASTER.md; dev/LEDGER.md D42): runOnMachineFunction     *)
(* (550), processRegion, makeSingleEntryLoop and ReachabilityGraph's       *)
(* calculate. It runs before CFGSort (addPreEmitPass), so CFGStackify.tla  *)
(* may assume a reducible CFG; this model discharges that assumption.      *)
(*                                                                         *)
(* WHAT THE ALGORITHM DOES. A region is a set of blocks with one entry; the *)
(* whole function is the first. In a region, the strongly connected        *)
(* components of its blocks, branches to the region's entry and out of the *)
(* region ignored, are its loops; a loop entry is a loop block (an SCC of  *)
(* two or more blocks, or a self loop) other than the region's entry with  *)
(* a predecessor outside its SCC. An SCC with two or more entries is an    *)
(* irreducible loop: makeSingleEntryLoop adds a dispatch block, a          *)
(* br_table over the entries in block order indexed by a fresh label       *)
(* register, and for each entry one routing block for the predecessors     *)
(* inside the loop and one for those outside, each setting the register to *)
(* its entry's index and branching to the dispatch; every branch from a    *)
(* predecessor to an entry goes to its routing block instead. The region   *)
(* is then analyzed again from the start. With every loop single-entry, it *)
(* recurses into each loop: the region of the loop's SCC, its entry the    *)
(* loop entry, whose branches back to that entry are then ignored.         *)
(*                                                                         *)
(* THE CLAIMS, each with a Broken variant (Bug) TLC must reject:           *)
(*   Reducible       the output CFG is reducible: without its back edges   *)
(*                   (an edge whose target dominates its source) it is     *)
(*                   acyclic (Bug "norecurse": no recursion into a loop's  *)
(*                   region, so an irreducible loop nested in a reducible  *)
(*                   one stays);                                           *)
(*   PathsPreserved  every original block reaches exactly its original     *)
(*                   successors, routing blocks and dispatches run by      *)
(*                   their registers: a routing block sets its dispatch's  *)
(*                   register, a dispatch jumps to the entry its register  *)
(*                   holds, never one unset (Bug "wronglabel": a routing   *)
(*                   block sets the next entry's index);                   *)
(*   Terminates      the analysis ends within its bound of fixes (Bug      *)
(*                   "noop": a fix found but not applied, so the region is *)
(*                   analyzed again forever; Bug "noinloop": predecessors  *)
(*                   inside the loop keep their branches to the entries,   *)
(*                   which the dispatch outside the loop still enters at   *)
(*                   two, so every analysis finds the loop again).         *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Every CFG of N blocks, each with at most two *)
(* successors, every block reachable and the entry with no predecessors    *)
(* (as CFGStackify.tla); a block is its successor set, its instructions    *)
(* the branches the rewrite remaps. The layout predecessor heuristic that  *)
(* places a routing block after an entry's layout predecessor changes      *)
(* where the block sits, not which routing blocks exist or where they go,  *)
(* so it is not modeled. addImplicitDefs is register liveness, not control *)
(* flow.                                                                   *)
(*                                                                         *)
(* formal(src/llvm/fix_irreducible_control_flow.jl process_region,         *)
(* make_single_entry_loop): the output is reducible with the input's paths. *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS N, Extra, Fuel, Bug

Bugs == {"none", "noinloop", "norecurse", "wronglabel", "noop"}
ASSUME N \in Nat /\ N >= 2 /\ Extra \in Nat /\ Fuel \in Nat /\ Bug \in Bugs

Orig == 1..N
Nodes == 1..(N + Extra)
Entry == 1

Min(S) == CHOOSE x \in S : \A y \in S : x <= y
RECURSIVE SortAsc(_)
SortAsc(S) == IF S = {} THEN << >> ELSE <<Min(S)>> \o SortAsc(S \ {Min(S)})
Range(s) == {s[i] : i \in 1..Len(s)}
Index(s, x) == CHOOSE i \in 1..Len(s) : s[i] = x

RECURSIVE Closure(_, _)
Closure(F(_), S) == LET next == S \cup UNION {F(x) : x \in S}
                    IN IF next = S THEN S ELSE Closure(F, next)

(* a graph: n nodes in use; succ; kind "orig", "disp" or "route"; a routing *)
(* block's register (the dispatch it serves) and label (the entry index); a *)
(* dispatch's br_table, its targets by index                                *)
Graph(n, succ, kind, reg, lab, tab) == [n |-> n, succ |-> succ, kind |-> kind, reg |-> reg, lab |-> lab, tab |-> tab]
Preds(g, x) == {p \in 1..g.n : x \in g.succ[p]}

(* ---- ReachabilityGraph::calculate over region B with entry e -------------- *)
RSucc(g, B, e, x) == (g.succ[x] \cap B) \ {e}
Reach1(g, B, e, x) == Closure(LAMBDA y : RSucc(g, B, e, y), RSucc(g, B, e, x))
SCC(g, B, e, x) == {x} \cup {y \in B : y \in Reach1(g, B, e, x) /\ x \in Reach1(g, B, e, y)}
InLoop(g, B, e, x) == x \in Reach1(g, B, e, x)
LoopEntries(g, B, e) ==
    {x \in B \ {e} : InLoop(g, B, e, x) /\ \E p \in Preds(g, x) : p \notin SCC(g, B, e, x)}
SCCEntries(g, B, e, x) == LoopEntries(g, B, e) \cap SCC(g, B, e, x)

(* ---- makeSingleEntryLoop ----------------------------------------------------- *)
(* the dispatch is node n + 1; the routing blocks follow, one per entry and   *)
(* side (inside the loop or not) some predecessor needs, in order             *)
MakeSingle(g, B, e, es) ==
    LET d == g.n + 1
        seq == SortAsc(es)
        allPreds == (UNION {Preds(g, x) : x \in es}) \ {d}
        inl(p) == \E x \in g.succ[p] \cap es : SCC(g, B, e, x) = SCC(g, B, e, p)
        rewired == IF Bug = "noinloop" THEN {p \in allPreds : ~inl(p)} ELSE allPreds
        code(x, side) == 2 * x + (IF side THEN 1 ELSE 0)
        codes == SortAsc(UNION {{code(x, inl(p)) : x \in g.succ[p] \cap es} : p \in rewired})
        rnode(x, side) == d + Index(codes, code(x, side))
        n2 == d + Len(codes)
        nextEntry(x) == seq[(Index(seq, x) % Len(seq)) + 1]
        entryOf(c) == c \div 2
    IN IF n2 > N + Extra THEN [g |-> g, b |-> B, ok |-> FALSE]
       ELSE [ok |-> TRUE, b |-> B \cup (d..n2),
             g |-> Graph(n2,
                     [x \in Nodes |->
                        IF x = d THEN es
                        ELSE IF x > d /\ x <= n2 THEN {d}
                        ELSE IF x \in rewired
                             THEN (g.succ[x] \ es) \cup {rnode(y, inl(x)) : y \in g.succ[x] \cap es}
                        ELSE g.succ[x]],
                     [x \in Nodes |-> IF x = d THEN "disp" ELSE IF x > d /\ x <= n2 THEN "route" ELSE g.kind[x]],
                     [x \in Nodes |-> IF x > d /\ x <= n2 THEN d ELSE g.reg[x]],
                     [x \in Nodes |->
                        IF x > d /\ x <= n2
                        THEN LET y == entryOf(codes[x - d]) IN
                             Index(seq, IF Bug = "wronglabel" THEN nextEntry(y) ELSE y)
                        ELSE g.lab[x]],
                     (* the br_table's operands remapped where its block is a predecessor *)
                     [x \in Nodes |->
                        IF x = d THEN seq
                        ELSE IF x \in rewired
                             THEN [i \in 1..Len(g.tab[x]) |->
                                     IF g.tab[x][i] \in es THEN rnode(g.tab[x][i], inl(x)) ELSE g.tab[x][i]]
                        ELSE g.tab[x]])]

(* ---- processRegion ------------------------------------------------------------ *)
RECURSIVE ProcessRegion(_, _, _, _), ProcessInner(_, _, _, _)
ProcessRegion(g, e, B, fuel) ==
    IF fuel = 0 THEN [g |-> g, fuel |-> 0, ok |-> FALSE]
    ELSE LET le == LoopEntries(g, B, e)
             bad == {x \in le : Cardinality(SCCEntries(g, B, e, x)) > 1}
         IN IF bad # {}
            THEN LET r == MakeSingle(g, B, e, SCCEntries(g, B, e, Min(bad)))
                 IN IF ~r.ok THEN [g |-> g, fuel |-> 0, ok |-> FALSE]
                    ELSE IF Bug = "noop" THEN ProcessRegion(g, e, B, fuel - 1)
                    ELSE ProcessRegion(r.g, e, r.b, fuel - 1)
            ELSE IF Bug = "norecurse" THEN [g |-> g, fuel |-> fuel, ok |-> TRUE]
            (* each loop entry's region, its SCC in this graph, before any recursion changes it *)
            ELSE ProcessInner(g, SortAsc(le), [x \in le |-> SCC(g, B, e, x)], fuel)
ProcessInner(g, seq, inner, fuel) ==
    IF seq = << >> THEN [g |-> g, fuel |-> fuel, ok |-> TRUE]
    ELSE LET r == ProcessRegion(g, Head(seq), inner[Head(seq)], fuel)
         IN IF ~r.ok THEN r ELSE ProcessInner(r.g, Tail(seq), inner, r.fuel)

(* ---- the input CFGs -------------------------------------------------------------- *)
SuccChoices == {S \in SUBSET Orig : Cardinality(S) <= 2}
Start(c) == Graph(N, [x \in Nodes |-> IF x <= N THEN c[x] ELSE {}],
                  [x \in Nodes |-> IF x <= N THEN "orig" ELSE "none"],
                  [x \in Nodes |-> 0], [x \in Nodes |-> 0], [x \in Nodes |-> << >>])
AllReach(c) == Closure(LAMBDA x : c[x], {Entry}) = Orig
NoEntryPred(c) == \A x \in Orig : Entry \notin c[x]

VARIABLES cfg, out
vars == <<cfg, out>>

Init ==
    /\ cfg \in {c \in [Orig -> SuccChoices] : AllReach(c) /\ NoEntryPred(c)}
    /\ out = ProcessRegion(Start(cfg), Entry, Orig, Fuel)
Next == UNCHANGED vars
Spec == Init /\ [][Next]_vars

TypeOK == out.ok \in BOOLEAN /\ out.g.n \in Nat

(* ---- the claims ------------------------------------------------------------------- *)
Terminates == out.ok

G == out.g
Live == 1..G.n
Reach(x) == Closure(LAMBDA y : G.succ[y], {x})
Reachable == Reach(Entry)
(* a dominates b: b is unreachable from the entry once a is removed *)
Dom(a, b) == a = b \/ b \notin Closure(LAMBDA y : G.succ[y] \ {a}, IF a = Entry THEN {} ELSE {Entry})
Reducible ==
    out.ok =>
        LET Fwd(x) == {s \in G.succ[x] : ~Dom(s, x)}
        IN \A x \in Reachable : x \notin Closure(LAMBDA y : Fwd(y), Fwd(x))

(* where a branch to s lands, run by the registers: a routing block sets its *)
(* dispatch's register; a dispatch jumps to its register's entry (0 unset);  *)
(* -1 for a dispatch read unset or a walk past its bound                     *)
RECURSIVE Land(_, _, _)
Land(s, env, steps) ==
    IF steps = 0 THEN -1
    ELSE CASE G.kind[s] = "orig"  -> s
         []   G.kind[s] = "route" -> Land(CHOOSE t \in G.succ[s] : TRUE,
                                          [env EXCEPT ![G.reg[s]] = G.lab[s]], steps - 1)
         []   G.kind[s] = "disp"  -> IF env[s] = 0 THEN -1
                                     ELSE Land(G.tab[s][env[s]], env, steps - 1)
         []   OTHER               -> -1
PathsPreserved ==
    out.ok =>
        \A x \in Orig : {Land(s, [y \in Nodes |-> 0], 2 * (N + Extra)) : s \in G.succ[x]} = cfg[x]
=============================================================================
