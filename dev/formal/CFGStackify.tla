---------------------------- MODULE CFGStackify ----------------------------
(***************************************************************************)
(* A TLA+ model of the stackifier WasmTarget ports from LLVM's WebAssembly *)
(* backend at the llvm pin (dev/PARITY_MASTER.md; dev/LEDGER.md D42):      *)
(* WebAssemblyCFGSort.cpp's sortBlocks (183) and WebAssemblyCFGStackify    *)
(* .cpp's placeLoopMarker (434), placeBlockMarker (283), updateScopeTops   *)
(* (67) and rewriteDepthImmediates (2615) with getBranchDepth (2551), over *)
(* the natural loops GenericLoopInfoImpl.h's LoopInfoBase::analyze (578)   *)
(* builds from the dominator tree. dart2wasm has no counterpart: Kernel is *)
(* already structured. The inputs are Julia's own (D3): Core.Compiler's    *)
(* CFG and its dominator tree stand where LLVM reads the MachineFunction's *)
(* blocks and its MachineDominatorTree.                                    *)
(*                                                                         *)
(* THE SPECIFICATION is Ramsey's, "Beyond Relooper" (ICFP 2022): the       *)
(* structured program has exactly the CFG's control-flow paths. Here it is *)
(* PathsPreserved: from the function's start the program reaches the entry *)
(* block's body first, and from each block's terminator each of its        *)
(* outcomes, run by wasm's semantics (a br to a block label resumes after  *)
(* its end, to a loop label at the loop, a fallthrough after the block's   *)
(* last instruction, marker instructions skipped), reaches exactly the     *)
(* body of the block the CFG names for that outcome.                       *)
(*                                                                         *)
(* WHAT THE ALGORITHM DOES. CFGSort lays the blocks out in a topological   *)
(* order of the CFG without its back edges, keeping each loop contiguous:  *)
(* a block a loop's header does not dominate is deferred until the loop's  *)
(* last block is placed. Two ready lists choose the next block, Preferred  *)
(* (successors just made ready, smallest number first, unless it was      *)
(* numbered before the current block outside a loop rotation) and Ready    *)
(* (the rest, largest number first), LLVM's CompareBlockNumbers and        *)
(* CompareBlockNumbersBackwards. Each block's terminator then becomes      *)
(* explicit branches to every successor but the layout successor, which it *)
(* falls through to (maybeUpdateTerminator, 77; a two-way branch whose     *)
(* jump target is the layout successor branches on the reversed condition, *)
(* WebAssemblyInstrInfo's reverseBranchCondition). CFGStackify places a    *)
(* LOOP at each loop header and its END_LOOP at the start of the block     *)
(* after the loop's bottom (an appendix block when the bottom is last),    *)
(* then a BLOCK for each block a forward predecessor branches to           *)
(* explicitly: at the nearest common dominator of its forward predecessors *)
(* walked out past every scope ending in between (ScopeTops), before the   *)
(* markers it encloses and the terminator, its END_BLOCK at the start of   *)
(* the target, after the END_LOOPs of loops that begin inside it. Last,    *)
(* walking the program backwards with a stack of the scopes' targets       *)
(* (END_BLOCK pushes its own block, END_LOOP its loop's header), each      *)
(* branch's target block becomes its depth.                                *)
(*                                                                         *)
(* THE CLAIMS, each with a Broken variant (Bug) TLC must reject:           *)
(*   EveryBlockOnce   the layout is a permutation of the blocks            *)
(*                    (Bug "backedges": NumPredsLeft counts back edges, so *)
(*                    a loop header never becomes ready);                  *)
(*   Topological      every predecessor but a back edge's source is placed *)
(*                    before its successor (Bug "nosort": the original     *)
(*                    order kept);                                         *)
(*   LoopsContiguous  every block between a loop's header and its bottom   *)
(*                    is dominated by the header (Bug "nodefer": no        *)
(*                    deferral);                                           *)
(*   WellNested       every END closes the innermost open scope, and every *)
(*                    scope closes (Bug "nowalk": the BLOCK placed at the  *)
(*                    nearest common dominator, not walked out);           *)
(*   BranchTargetsEnclosingLabel  every branch's target is the target of a *)
(*                    label open at the branch (Bug "singlepred": a BLOCK  *)
(*                    only for a block with two forward predecessors);     *)
(*   DepthCorrect     the label at the branch's depth is its target's      *)
(*                    (Bug "endloopatend": END_LOOP pushes its own block); *)
(*   PathsPreserved   Ramsey's statement above (Bug "noupdate": Julia's    *)
(*                    terminators kept, their fallthrough to the original  *)
(*                    next block).                                         *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Every CFG of N blocks whose terminators are  *)
(* Julia's: return, goto t, a fallthrough to the next block, and goto t if *)
(* not c (GotoIfNot: t on false, the next block on true); every block      *)
(* reachable (LLVM's UnreachableBlockElim runs first), the entry with no   *)
(* predecessors (LLVM IR's rule; Julia codegen's `top` block stands before *)
(* Julia's first block), and reducible (FixIrreducibleControlFlow makes    *)
(* it so; its own model is separate). A block's body is one instruction    *)
(* that is not a stackified child, so no expression tree moves a marker.   *)
(* No EH pads: try_table placement extends the model when it is ported.    *)
(* Block types (fixEndsAtEndOfFunction) are not control flow.              *)
(*                                                                         *)
(* formal(src/llvm/cfg_sort.jl sort_blocks, src/llvm/cfg_stackify.jl       *)
(* place_markers, rewrite_depth_immediates): the structured program has    *)
(* the CFG's paths.                                                        *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS N, Bug

Bugs == {"none", "backedges", "nosort", "nodefer", "nowalk", "singlepred",
         "endloopatend", "noupdate"}
ASSUME N \in Nat /\ N >= 2 /\ Bug \in Bugs

Blocks == 1..N
Entry == 1

Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Max(S) == CHOOSE x \in S : \A y \in S : y <= x
Last(s) == s[Len(s)]
Pop(s) == SubSeq(s, 1, Len(s) - 1)
RECURSIVE SortAsc(_)
SortAsc(S) == IF S = {} THEN << >> ELSE <<Min(S)>> \o SortAsc(S \ {Min(S)})
RECURSIVE SortDesc(_)
SortDesc(S) == IF S = {} THEN << >> ELSE <<Max(S)>> \o SortDesc(S \ {Max(S)})

(* ---- the CFG: Julia's terminators ---------------------------------------- *)
Term(k, t) == [k |-> k, t |-> t]
AllTerms == {Term("ret", 0), Term("ft", 0)} \cup {Term("goto", x) : x \in Blocks}
            \cup {Term("cond", x) : x \in Blocks}
TermChoices(b) ==
    {Term("ret", 0)} \cup {Term("goto", x) : x \in Blocks}
    \cup (IF b < N THEN {Term("ft", 0)} \cup {Term("cond", x) : x \in Blocks \ {b + 1}}
          ELSE {})

Succ(c, b) == CASE c[b].k = "ret"  -> {}
              []   c[b].k = "goto" -> {c[b].t}
              []   c[b].k = "ft"   -> {b + 1}
              []   c[b].k = "cond" -> {c[b].t, b + 1}
Preds(c, b) == {p \in Blocks : b \in Succ(c, p)}

(* the blocks reachable from S over F's edges, never entering `avoid` *)
RECURSIVE Closure(_, _, _)
Closure(F(_), S, avoid) ==
    LET next == S \cup ((UNION {F(x) : x \in S}) \ {avoid})
    IN IF next = S THEN S ELSE Closure(F, next, avoid)

(* a dominates b: every path from the entry to b passes a (GenericDomTree's  *)
(* relation; Julia's construct_domtree computes it)                         *)
DomOf(c) == [a \in Blocks |->
               LET r == Closure(LAMBDA x : Succ(c, x), {Entry} \ {a}, a)
               IN {b \in Blocks : b = a \/ b \notin r}]

(* the natural loop of header h: h and every block reaching a back edge's   *)
(* source without passing h, LoopInfoBase::analyze's discoverAndMapSubloop  *)
(* (GenericLoopInfoImpl.h:459); {} when h heads no loop                     *)
BodyOf(c, d, h) ==
    LET latches == {p \in Preds(c, h) : p \in d[h]}
    IN IF latches = {} THEN {}
       ELSE {h} \cup Closure(LAMBDA x : Preds(c, x), latches \ {h}, h)

(* reducible: the CFG without its back edges (an edge whose target          *)
(* dominates its source) is acyclic                                         *)
Reducible(c, d) ==
    LET Fwd(x) == {s \in Succ(c, x) : x \notin d[s]}
    IN \A x \in Blocks : x \notin Closure(LAMBDA y : Fwd(y), Fwd(x), 0)

AllReach(c) == Closure(LAMBDA x : Succ(c, x), {Entry}, 0) = Blocks
CandidateCFGs == {c \in [Blocks -> AllTerms] : \A b \in Blocks : c[b] \in TermChoices(b)}

VARIABLES cfg, dom, body,                         \* the CFG and Julia's analyses
          placed, cur, npl, pref, ready, entries,   \* sortBlocks's state
          phase, flat, scopes                       \* the structured program
vars == <<cfg, dom, body, placed, cur, npl, pref, ready, entries, phase, flat, scopes>>

Dominates(a, b) == b \in dom[a]
IsHeader(h) == body[h] # {}
Headers == {h \in Blocks : IsHeader(h)}
(* MachineLoopInfo::getLoopFor: the innermost loop holding b, by its header *)
LoopFor(b) ==
    LET hs == {h \in Headers : b \in body[h]}
    IN IF hs = {} THEN 0
       ELSE CHOOSE h \in hs : \A h2 \in hs : body[h] \subseteq body[h2]
BackEdge(p, s) == s \in Succ(cfg, p) /\ IsHeader(s) /\ p \in body[s]

TypeOK ==
    /\ phase \in {"sort", "stackify", "done", "failed"}
    /\ placed \in Seq(Blocks) /\ cur \in Blocks
    /\ pref \subseteq Blocks /\ ready \subseteq Blocks

Init ==
    \E c \in CandidateCFGs :
        /\ AllReach(c)
        /\ Preds(c, Entry) = {}
        /\ LET d == DomOf(c)
               bd == [h \in Blocks |-> BodyOf(c, d, h)]
           IN /\ Reducible(c, d)
              /\ cfg = c /\ dom = d /\ body = bd
              \* sortBlocks: each block's predecessors, a header's back edges uncounted
              /\ npl = [b \in Blocks |->
                          Cardinality(Preds(c, b))
                          - (IF bd[b] # {} /\ Bug # "backedges"
                             THEN Cardinality(Preds(c, b) \cap bd[b]) ELSE 0)]
        /\ placed = <<Entry>> /\ cur = Entry
        /\ pref = {} /\ ready = {} /\ entries = << >>
        /\ phase = "sort" /\ flat = << >> /\ scopes = << >>

(* ---- CFGSort: one iteration of sortBlocks's loop (WebAssemblyCFGSort.cpp:  *)
(* 213-298), placing the block after cur                                     *)
(* the top active region's header: a block it does not dominate is deferred *)
Defers(es, x) == Bug # "nodefer" /\ Len(es) > 0 /\ ~Dominates(Last(es).h, x)

(* Preferred, popped smallest first: deferred, moved to Ready, or chosen    *)
RECURSIVE PickPref(_, _, _, _, _)
PickPref(seq, es, R, rd, df) ==
    IF seq = << >> THEN [nx |-> 0, rd |-> rd, df |-> df, rest |-> {}]
    ELSE LET x == Head(seq) IN
         IF Defers(es, x) THEN PickPref(Tail(seq), es, R, rd, df \cup {x})
         ELSE IF x < cur /\ (R = 0 \/ x \notin body[R] \/ R < x)
              THEN PickPref(Tail(seq), es, R, rd \cup {x}, df)
              ELSE [nx |-> x, rd |-> rd, df |-> df,
                    rest |-> {Tail(seq)[i] : i \in 1..Len(Tail(seq))}]

(* Ready, popped largest first: deferred or chosen; -1 when it runs out     *)
(* (LLVM's Ready.top() on an empty queue)                                   *)
RECURSIVE PickReady(_, _, _)
PickReady(seq, es, df) ==
    IF seq = << >> THEN [nx |-> -1, df |-> df, rest |-> {}]
    ELSE LET x == Head(seq) IN
         IF Defers(es, x) THEN PickReady(Tail(seq), es, df \cup {x})
         ELSE [nx |-> x, df |-> df, rest |-> {Tail(seq)[i] : i \in 1..Len(Tail(seq))}]

RECURSIVE PopDone(_)
PopDone(es) == IF es # << >> /\ Last(es).left = 0 THEN PopDone(Pop(es)) ELSE es

IsPerm(s) == Len(s) = N /\ {s[i] : i \in 1..Len(s)} = Blocks

SortStep ==
    /\ phase = "sort" /\ Bug # "nosort"
    /\ LET R == LoopFor(cur)
           e1 == IF R # 0 /\ R = cur
                 THEN Append(entries, [h |-> R, left |-> Cardinality(body[R]), d |-> {}])
                 ELSE entries
           e2 == [i \in 1..Len(e1) |->
                    IF R # 0 /\ cur \in body[e1[i].h]
                    THEN [e1[i] EXCEPT !.left = @ - 1] ELSE e1[i]]
           readied == UNION {e2[i].d : i \in {j \in 1..Len(e2) :
                                R # 0 /\ cur \in body[e2[j].h] /\ e2[j].left = 0}}
           es == PopDone(e2)
           fs == {s \in Succ(cfg, cur) : ~BackEdge(cur, s)}
           npl1 == [b \in Blocks |-> IF b \in fs THEN npl[b] - 1 ELSE npl[b]]
           pref1 == pref \cup {s \in fs : npl1[s] = 0}
           p == PickPref(SortAsc(pref1), es, R, ready \cup readied, {})
           r == PickReady(SortDesc(p.rd), es, p.df)
           nx == IF p.nx # 0 THEN p.nx ELSE IF p.rd = {} THEN 0 ELSE r.nx
           df == IF p.nx # 0 \/ p.rd = {} THEN p.df ELSE r.df
           es2 == IF df = {} THEN es
                  ELSE [es EXCEPT ![Len(es)].d = @ \cup df]
       IN /\ nx # -1        \* LLVM's assertion: Ready never runs out while deferring
          /\ npl' = npl1
          /\ entries' = es2
          /\ pref' = p.rest
          /\ ready' = IF p.nx # 0 \/ p.rd = {} THEN p.rd ELSE r.rest
          /\ IF nx = 0
             THEN /\ phase' = IF IsPerm(placed) THEN "stackify" ELSE "failed"
                  /\ UNCHANGED <<placed, cur>>
             ELSE /\ placed' = Append(placed, nx) /\ cur' = nx
                  /\ UNCHANGED phase
    /\ UNCHANGED <<cfg, dom, body, flat, scopes>>

NoSort ==
    /\ phase = "sort" /\ Bug = "nosort"
    /\ placed' = [i \in Blocks |-> i] /\ phase' = "stackify"
    /\ UNCHANGED <<cfg, dom, body, cur, npl, pref, ready, entries, flat, scopes>>

(* ---- the layout's positions: after MF.RenumberBlocks a block's number is   *)
(* its position                                                              *)
Pos == [b \in Blocks |-> CHOOSE i \in Blocks : placed[i] = b]
PB(i) == placed[i]
PPreds(i) == {Pos[p] : p \in Preds(cfg, PB(i))}
PDom(i, j) == Dominates(PB(i), PB(j))
PIsHeader(i) == IsHeader(PB(i))
PBody(i) == {Pos[x] : x \in body[PB(i)]}

(* a token: k its kind, t a target position (a body's own), o the outcome a  *)
(* branch takes, s a marker's scope                                          *)
Tok(k, t, o, s) == [k |-> k, t |-> t, o |-> o, s |-> s]
Markers == {"BLOCK", "LOOP", "END_BLOCK", "END_LOOP"}
Terminators == {"br", "brif", "ret"}

(* the outcomes of block i's terminator and the position each reaches; -1   *)
(* is the return                                                             *)
Outcomes(i) == IF cfg[PB(i)].k = "cond" THEN {"jump", "next"} ELSE {"always"}
Dest(i, o) ==
    LET b == PB(i) IN
    CASE cfg[b].k = "ret"  -> -1
    []   cfg[b].k = "goto" -> Pos[cfg[b].t]
    []   cfg[b].k = "ft"   -> Pos[b + 1]
    []   cfg[b].k = "cond" -> IF o = "jump" THEN Pos[cfg[b].t] ELSE Pos[b + 1]

(* maybeUpdateTerminator (WebAssemblyCFGSort.cpp:77): explicit branches to   *)
(* every successor but the layout successor i + 1                            *)
TermToks(i) ==
    LET b == PB(i)
        c == cfg[b]
    IN IF Bug = "noupdate"
       THEN CASE c.k = "ret"  -> <<Tok("ret", 0, "always", 0)>>
            []   c.k = "goto" -> <<Tok("br", Pos[c.t], "always", 0)>>
            []   c.k = "ft"   -> << >>
            []   c.k = "cond" -> <<Tok("brif", Pos[c.t], "jump", 0)>>
       ELSE CASE c.k = "ret"  -> <<Tok("ret", 0, "always", 0)>>
            []   c.k = "goto" -> IF Pos[c.t] = i + 1 THEN << >>
                                 ELSE <<Tok("br", Pos[c.t], "always", 0)>>
            []   c.k = "ft"   -> IF Pos[b + 1] = i + 1 THEN << >>
                                 ELSE <<Tok("br", Pos[b + 1], "always", 0)>>
            []   c.k = "cond" ->
                    LET j == Pos[c.t]
                        n == Pos[b + 1]
                    IN IF n = i + 1 THEN <<Tok("brif", j, "jump", 0)>>
                       ELSE IF j = i + 1 THEN <<Tok("brif", n, "next", 0)>>
                       ELSE <<Tok("brif", j, "jump", 0), Tok("br", n, "always", 0)>>

ExplicitlyBranchesTo(p, i) ==
    \E k \in 1..Len(TermToks(p)) : TermToks(p)[k].k \in {"br", "brif"} /\ TermToks(p)[k].t = i

(* ---- CFGStackify's placement over positions 1..N and the appendix N + 1   *)
InsertAt(s, j, x) == SubSeq(s, 1, j - 1) \o <<x>> \o SubSeq(s, j, Len(s))
(* getEarliestInsertPos (WebAssemblyCFGStackify.cpp:210): after the last     *)
(* instruction of the before set, else at the start                          *)
EarliestPos(s, Before(_)) ==
    LET js == {j \in 1..Len(s) : Before(s[j])} IN IF js = {} THEN 1 ELSE Max(js) + 1
(* getLatestInsertPos (234): before the first instruction of the after set,  *)
(* else at the end                                                           *)
LatestPos(s, After(_)) ==
    LET js == {j \in 1..Len(s) : After(s[j])} IN IF js = {} THEN Len(s) + 1 ELSE Min(js)
(* updateScopeTops (67): the farthest-spanning scope ending at e            *)
UpdateTop(tops, b, e) == IF tops[e] = 0 \/ tops[e] > b THEN [tops EXCEPT ![e] = b] ELSE tops

(* placeLoopMarker (434) *)
PlaceLoop(st, i) ==
    IF ~PIsHeader(i) THEN st
    ELSE LET after == Max(PBody(i)) + 1
             sid == Len(st.scopes) + 1
             ins1 == [st.ins EXCEPT ![i] =
                        InsertAt(@, EarliestPos(@, LAMBDA x : x.k = "END_LOOP"), Tok("LOOP", 0, "", sid))]
             ins2 == [ins1 EXCEPT ![after] =
                        InsertAt(@, EarliestPos(@, LAMBDA x : FALSE), Tok("END_LOOP", 0, "", sid))]
         IN [ins |-> ins2,
             scopes |-> Append(st.scopes, [kind |-> "loop", b |-> i, e |-> after]),
             tops |-> UpdateTop(st.tops, i, after)]

(* placeBlockMarker's walk out (309-321): from the layout predecessor down   *)
(* to the header, skipping a scope that lies between, stopping at one that   *)
(* begins at or above the header                                             *)
RECURSIVE Walk(_, _, _)
Walk(tops, I, H) ==
    IF I <= H THEN H
    ELSE IF tops[I] # 0
         THEN IF tops[I] > H THEN Walk(tops, tops[I], H) ELSE tops[I]
         ELSE Walk(tops, I - 1, H)

(* the nearest common dominator of S (MachineDominatorTree's                 *)
(* findNearestCommonDominator)                                               *)
NCD(S) == LET cd == {d \in Blocks : \A p \in S : PDom(d, p)}
          IN CHOOSE d \in cd : \A d2 \in cd : PDom(d2, d)

(* placeBlockMarker (283) *)
PlaceBlock(st, i) ==
    LET fp == {p \in PPreds(i) : p < i}
        branched == \E p \in fp : ExplicitlyBranchesTo(p, i)
    IN IF fp = {} \/ ~branched \/ (Bug = "singlepred" /\ Cardinality(fp) < 2) THEN st
       ELSE LET h0 == NCD(fp)
                h == IF Bug = "nowalk" THEN h0 ELSE Walk(st.tops, i - 1, h0)
                sid == Len(st.scopes) + 1
                After(x) == \/ x.k = "LOOP" /\ st.scopes[x.s].e - 1 < i
                            \/ x.k = "BLOCK" /\ st.scopes[x.s].e <= i
                            \/ x.k \in Terminators
                Before(x) == x.k = "END_LOOP" /\ st.scopes[x.s].b >= h
                ins1 == [st.ins EXCEPT ![h] = InsertAt(@, LatestPos(@, After), Tok("BLOCK", 0, "", sid))]
                ins2 == [ins1 EXCEPT ![i] = InsertAt(@, EarliestPos(@, Before), Tok("END_BLOCK", 0, "", sid))]
            IN [ins |-> ins2,
                scopes |-> Append(st.scopes, [kind |-> "block", b |-> h, e |-> i]),
                tops |-> UpdateTop(st.tops, h, i)]

(* placeMarkers (2509): every LOOP first, then every BLOCK, in layout order *)
RECURSIVE FoldLoops(_, _)
FoldLoops(st, i) == IF i > N THEN st ELSE FoldLoops(PlaceLoop(st, i), i + 1)
RECURSIVE FoldBlocks(_, _)
FoldBlocks(st, i) == IF i > N THEN st ELSE FoldBlocks(PlaceBlock(st, i), i + 1)

Start == [ins |-> [i \in 1..N + 1 |-> IF i <= N THEN <<Tok("body", i, "", 0)>> \o TermToks(i) ELSE << >>],
          scopes |-> << >>,
          tops |-> [i \in 1..N + 1 |-> 0]]

(* the function body, each instruction with its block (at) and, a branch,  *)
(* its depth (d)                                                             *)
At(x, i, d) == [k |-> x.k, t |-> x.t, o |-> x.o, s |-> x.s, at |-> i, d |-> d]
RECURSIVE Cat(_, _)
Cat(ins, i) == IF i > N + 1 THEN << >>
               ELSE [j \in 1..Len(ins[i]) |-> At(ins[i][j], i, 0)] \o Cat(ins, i + 1)

(* rewriteDepthImmediates (2615): the stack of scope targets the backward    *)
(* walk holds when it reaches instruction k                                  *)
RECURSIVE Walkback(_, _, _, _, _)
Walkback(fl, sc, j, k, stk) ==
    IF j <= k THEN stk
    ELSE LET x == fl[j] IN
         Walkback(fl, sc, j - 1, k,
             CASE x.k \in {"BLOCK", "LOOP"} -> Pop(stk)
             []   x.k = "END_BLOCK"         -> Append(stk, x.at)
             []   x.k = "END_LOOP"          -> Append(stk, IF Bug = "endloopatend" THEN x.at ELSE sc[x.s].b)
             []   OTHER                     -> stk)
(* getBranchDepth (2551): scopes counted from the top until the target's;   *)
(* the stack's length when it holds none                                     *)
RECURSIVE DepthIn(_, _, _)
DepthIn(stk, t, d) == IF d >= Len(stk) THEN Len(stk)
                      ELSE IF stk[Len(stk) - d] = t THEN d ELSE DepthIn(stk, t, d + 1)

StackifyStep ==
    /\ phase = "stackify"
    /\ LET st == FoldBlocks(FoldLoops(Start, 1), 1)
           fl == Cat(st.ins, 1)
       IN /\ flat' = [k \in 1..Len(fl) |->
                        IF fl[k].k \in {"br", "brif"}
                        THEN At(fl[k], fl[k].at, DepthIn(Walkback(fl, st.scopes, Len(fl), k, << >>), fl[k].t, 0))
                        ELSE fl[k]]
          /\ scopes' = st.scopes
    /\ phase' = "done"
    /\ UNCHANGED <<cfg, dom, body, placed, cur, npl, pref, ready, entries>>

Terminal == phase \in {"done", "failed"} /\ UNCHANGED vars

Next == SortStep \/ NoSort \/ StackifyStep \/ Terminal
Spec == Init /\ [][Next]_vars

(* ---- wasm's semantics of the structured program ------------------------- *)
(* the labels open at instruction k, innermost last *)
RECURSIVE OpenFrom(_, _, _)
OpenFrom(j, k, stk) ==
    IF j >= k THEN stk
    ELSE OpenFrom(j + 1, k,
             CASE flat[j].k \in {"BLOCK", "LOOP"}         -> Append(stk, flat[j].s)
             []   flat[j].k \in {"END_BLOCK", "END_LOOP"} -> IF stk = << >> THEN stk ELSE Pop(stk)
             []   OTHER                                   -> stk)
OpenAt(k) == OpenFrom(1, k, << >>)
(* the block a label names: a BLOCK's end block, a LOOP's header *)
LabelBlock(sid) == IF scopes[sid].kind = "block" THEN scopes[sid].e ELSE scopes[sid].b
(* where a branch to label sid resumes: after a BLOCK's END, after its LOOP *)
Resume(sid) ==
    LET mk == IF scopes[sid].kind = "block" THEN "END_BLOCK" ELSE "LOOP"
    IN (CHOOSE j \in 1..Len(flat) : flat[j].k = mk /\ flat[j].s = sid) + 1
(* the body reached from instruction j, markers skipped: -2 off the end, -3 *)
(* at an instruction that is no marker                                       *)
RECURSIVE NextBody(_)
NextBody(j) == IF j > Len(flat) THEN -2
               ELSE IF flat[j].k = "body" THEN flat[j].t
               ELSE IF flat[j].k \in Markers THEN NextBody(j + 1)
               ELSE -3
BrLand(k) == LET stk == OpenAt(k) IN
             IF flat[k].d >= Len(stk) THEN -4 ELSE NextBody(Resume(stk[Len(stk) - flat[k].d]))
(* block i's terminator run on outcome o *)
TermIdx(i) == SortAsc({k \in 1..Len(flat) : flat[k].at = i /\ flat[k].k \in Terminators})
LastIdx(i) == Max({k \in 1..Len(flat) : flat[k].at = i})
RECURSIVE LandFrom(_, _, _)
LandFrom(i, ks, o) ==
    IF ks = << >> THEN NextBody(LastIdx(i) + 1)
    ELSE LET x == flat[Head(ks)] IN
         CASE x.k = "ret"                -> -1
         []   x.k = "br"                 -> BrLand(Head(ks))
         []   x.k = "brif" /\ x.o = o    -> BrLand(Head(ks))
         []   OTHER                      -> LandFrom(i, Tail(ks), o)
Branches == {k \in 1..Len(flat) : flat[k].k \in {"br", "brif"}}

(* ---- the claims ----------------------------------------------------------- *)
EveryBlockOnce == phase \in {"stackify", "done", "failed"} => IsPerm(placed)

Topological ==
    phase = "done" =>
        \A b \in Blocks : \A p \in Preds(cfg, b) : ~BackEdge(p, b) => Pos[p] < Pos[b]

LoopsContiguous ==
    phase = "done" =>
        \A h \in Headers : \A j \in Pos[h]..Max(PBody(Pos[h])) : Dominates(h, placed[j])

RECURSIVE Nested(_, _)
Nested(j, stk) ==
    IF j > Len(flat) THEN stk = << >>
    ELSE CASE flat[j].k \in {"BLOCK", "LOOP"} -> Nested(j + 1, Append(stk, flat[j].s))
         []   flat[j].k \in {"END_BLOCK", "END_LOOP"} ->
                  stk # << >> /\ Last(stk) = flat[j].s /\ Nested(j + 1, Pop(stk))
         []   OTHER -> Nested(j + 1, stk)
WellNested == phase = "done" => Nested(1, << >>)

BranchTargetsEnclosingLabel ==
    phase = "done" =>
        \A k \in Branches : \E m \in 1..Len(OpenAt(k)) : LabelBlock(OpenAt(k)[m]) = flat[k].t

DepthCorrect ==
    phase = "done" =>
        \A k \in Branches :
            LET stk == OpenAt(k) IN
            flat[k].d < Len(stk) /\ LabelBlock(stk[Len(stk) - flat[k].d]) = flat[k].t

PathsPreserved ==
    phase = "done" =>
        /\ NextBody(1) = Pos[Entry]
        /\ \A i \in Blocks : \A o \in Outcomes(i) : LandFrom(i, TermIdx(i), o) = Dest(i, o)
=============================================================================
