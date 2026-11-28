---------------------------- MODULE ExceptionInfo ----------------------------
(***************************************************************************)
(* A TLA+ model of the exception tree WasmTarget ports from LLVM's         *)
(* WebAssembly backend at the llvm pin (dev/PARITY_MASTER.md; dev/LEDGER.md*)
(* D42): WebAssemblyExceptionInfo.cpp's recalculate (53),                  *)
(* discoverAndMapException (117) and getOutermostException (164), over the *)
(* dominator tree and the dominance frontier (DominanceFrontierImpl.h's    *)
(* calculate). dart2wasm has no counterpart: Kernel's try is already       *)
(* structured. The inputs are Julia's own (D3): Core.Compiler's dominator  *)
(* tree stands for the MachineDominatorTree, and an EH pad is a try        *)
(* region's catch block (compute_trycatch), reached by the unwind edges of *)
(* the blocks whose statements may throw under it.                         *)
(*                                                                         *)
(* THE SPECIFICATION is LLVM's statement of the analysis (the header of    *)
(* WebAssemblyExceptionInfo.h): an exception is the set of blocks its EH   *)
(* pad dominates. Each block maps to the innermost exception holding it,   *)
(* the one of the pad that dominates it and is dominated by every other    *)
(* pad dominating it; an exception's parent is the innermost exception of  *)
(* the pads strictly dominating its own.                                   *)
(*                                                                         *)
(* WHAT THE ALGORITHM DOES. recalculate visits the pads in a postorder of  *)
(* the dominator tree, so a pad's every dominated pad is discovered first. *)
(* discoverAndMapException walks a worklist from the pad: an undiscovered  *)
(* block maps to the pad's exception and pushes its successors the pad     *)
(* dominates; a block already discovered whose outermost exception is      *)
(* another becomes that exception's parent, and the walk goes on from that *)
(* subexception's pad's dominance frontier, the blocks the pad dominates;  *)
(* a block of this exception is skipped. Each exception's blocks are then  *)
(* those mapped to it or to an exception below it.                         *)
(*                                                                         *)
(* THE CLAIMS, each with a Broken variant (Bug) TLC must reject:           *)
(*   MapInnermost      each block maps to its innermost exception (Bug     *)
(*                     "nofrontier": a subexception skipped without its    *)
(*                     frontier, so a block reached only through two       *)
(*                     subexceptions stays unmapped);                      *)
(*   BlocksDominated   each exception's blocks are those its pad dominates *)
(*                     (Bug "unfiltered": the frontier followed whether    *)
(*                     the pad dominates it or not);                       *)
(*   ParentInnermost   each exception's parent is the innermost exception  *)
(*                     of the pads strictly dominating its pad (Bug        *)
(*                     "preorder": the pads visited outermost first, so an *)
(*                     outer exception takes an inner pad's blocks).       *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Every CFG of N blocks whose edges run        *)
(* forward, at most two from a block, with at most one back edge (a loop), *)
(* every block reachable and the entry with no predecessors (LLVM IR's     *)
(* rule; Julia codegen's top block stands before Julia's first), and every *)
(* set of pads among the other blocks. The analysis reads only the edges,  *)
(* the dominator tree and the frontier, so a pad's edges are modeled as    *)
(* any others: an unwind edge is a successor edge in LLVM's                *)
(* MachineBasicBlock and in WasmTarget's machine code alike. A worklist    *)
(* pushes a set in ascending order; the result does not depend on it. The  *)
(* postorder is by dominator-tree depth, deepest first, which visits every *)
(* pad after the pads it dominates, all LLVM's postorder guarantees.       *)
(*                                                                         *)
(* formal(src/llvm/exception_info.jl recalculate,                          *)
(* discover_and_map_exception, get_outermost_exception): each exception is *)
(* the blocks its pad dominates, each block in its innermost.              *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS N, Bug

Bugs == {"none", "nofrontier", "unfiltered", "preorder"}
ASSUME N \in Nat /\ N >= 2 /\ Bug \in Bugs

Blocks == 1..N
Entry == 1

Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Last(s) == s[Len(s)]
Pop(s) == SubSeq(s, 1, Len(s) - 1)
RECURSIVE SortAsc(_)
SortAsc(S) == IF S = {} THEN << >> ELSE <<Min(S)>> \o SortAsc(S \ {Min(S)})

(* ---- the CFGs: forward edges, at most two from a block, one back edge ---- *)
FwdChoices(b) == {S \in SUBSET ((b + 1)..N) : Cardinality(S) <= 2}
RECURSIVE FwdFns(_)
FwdFns(k) == IF k = 0 THEN {<< >>} ELSE {f \o <<s>> : f \in FwdFns(k - 1), s \in FwdChoices(k)}
(* <<0, 0>> for none, else <<from, to>>, to at or before from, never the entry *)
BackChoices == {<<0, 0>>} \cup {e \in Blocks \X (2..N) : e[2] <= e[1]}

SuccOf(f, be) == [b \in Blocks |-> f[b] \cup (IF be[1] = b THEN {be[2]} ELSE {})]

(* the blocks reachable from S over F's edges, never entering `avoid` *)
RECURSIVE Closure(_, _, _)
Closure(F(_), S, avoid) ==
    LET next == S \cup ((UNION {F(x) : x \in S}) \ {avoid})
    IN IF next = S THEN S ELSE Closure(F, next, avoid)

VARIABLES succ, pads, phase, exc, parent
vars == <<succ, pads, phase, exc, parent>>

Preds(b) == {p \in Blocks : b \in succ[p]}
(* a dominates b: every path from the entry to b passes a *)
DomSet == [a \in Blocks |->
             LET r == Closure(LAMBDA x : succ[x], {Entry} \ {a}, a)
             IN {b \in Blocks : b = a \/ b \notin r}]
Dom(a, b) == b \in DomSet[a]
SDom(a, b) == a # b /\ Dom(a, b)
(* the dominance frontier: the blocks a dominates a predecessor of but does *)
(* not strictly dominate (DominanceFrontierImpl.h's calculate)              *)
DF(a) == {y \in Blocks : (\E p \in Preds(y) : Dom(a, p)) /\ ~SDom(a, y)}
Depth(b) == Cardinality({a \in Blocks : SDom(a, b)})

TypeOK ==
    /\ phase \in {"run", "done"}
    /\ exc \in [Blocks -> Blocks \cup {0}]
    /\ parent \in [Blocks -> Blocks \cup {0}]

Init ==
    \E f \in FwdFns(N), be \in BackChoices, ps \in SUBSET (Blocks \ {Entry}) :
        /\ succ = SuccOf(f, be)
        /\ Closure(LAMBDA x : succ[x], {Entry}, 0) = Blocks
        /\ pads = ps
        /\ phase = "run"
        /\ exc = [b \in Blocks |-> 0] /\ parent = [b \in Blocks |-> 0]

(* getOutermostException: the exception of b, followed up its parents (N  *)
(* steps at most: a Broken variant may make a cycle, which a claim catches) *)
RECURSIVE Up(_, _, _)
Up(par, e, k) == IF e = 0 \/ par[e] = 0 \/ k = 0 THEN e ELSE Up(par, par[e], k - 1)
Outermost(m, par, b) == Up(par, m[b], N)

FrontierPush(sub, p) ==
    CASE Bug = "nofrontier" -> {}
    []   Bug = "unfiltered" -> DF(sub)
    []   OTHER              -> {y \in DF(sub) : Dom(p, y)}

(* discoverAndMapException's worklist loop for pad p over the map m and    *)
(* the parents par                                                          *)
RECURSIVE Discover(_, _, _, _)
Discover(wl, m, par, p) ==
    IF wl = << >> THEN [m |-> m, par |-> par]
    ELSE LET b == Last(wl)
             rest == Pop(wl)
             sub == Outermost(m, par, b)
         IN IF sub # 0
            THEN IF sub # p
                 THEN Discover(rest \o SortAsc(FrontierPush(sub, p)), m, [par EXCEPT ![sub] = p], p)
                 ELSE Discover(rest, m, par, p)
            ELSE Discover(rest \o SortAsc({s \in succ[b] : Dom(p, s)}), [m EXCEPT ![b] = p], par, p)

(* recalculate's postorder of the pads: every pad after those it dominates *)
RECURSIVE Order(_)
Order(S) ==
    IF S = {} THEN << >>
    ELSE LET pick == IF Bug = "preorder"
                     THEN CHOOSE x \in S : \A y \in S : Depth(x) < Depth(y) \/ (Depth(x) = Depth(y) /\ x <= y)
                     ELSE CHOOSE x \in S : \A y \in S : Depth(x) > Depth(y) \/ (Depth(x) = Depth(y) /\ x <= y)
         IN <<pick>> \o Order(S \ {pick})

RECURSIVE Recalc(_, _)
Recalc(ps, st) ==
    IF ps = << >> THEN st
    ELSE Recalc(Tail(ps), Discover(<<Head(ps)>>, st.m, st.par, Head(ps)))

Run ==
    /\ phase = "run"
    /\ LET st == Recalc(Order(pads), [m |-> [b \in Blocks |-> 0], par |-> [b \in Blocks |-> 0]])
       IN /\ exc' = st.m /\ parent' = st.par
    /\ phase' = "done"
    /\ UNCHANGED <<succ, pads>>

Terminal == phase = "done" /\ UNCHANGED vars

Next == Run \/ Terminal
Spec == Init /\ [][Next]_vars

(* ---- the claims ----------------------------------------------------------- *)
(* the innermost of the pads in S dominating b, 0 when none *)
Innermost(S, b) ==
    LET ds == {q \in S : Dom(q, b)}
    IN IF ds = {} THEN 0 ELSE CHOOSE q \in ds : \A q2 \in ds : Dom(q2, q)
(* an exception's blocks: those mapped to it or to an exception below it *)
RECURSIVE Below(_, _, _)
Below(e, p, k) == e # 0 /\ k > 0 /\ (e = p \/ Below(parent[e], p, k - 1))
ExcBlocks(p) == {b \in Blocks : Below(exc[b], p, N)}

MapInnermost == phase = "done" => \A b \in Blocks : exc[b] = Innermost(pads, b)
BlocksDominated == phase = "done" => \A p \in pads : ExcBlocks(p) = DomSet[p]
ParentInnermost ==
    phase = "done" => \A p \in pads : parent[p] = Innermost({q \in pads : SDom(q, p)}, p)
=============================================================================
