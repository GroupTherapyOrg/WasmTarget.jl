--------------------------- MODULE CFGStackifyEH ---------------------------
(***************************************************************************)
(* The EH extension of CFGStackify.tla: the stackifier over Julia's try    *)
(* regions, as WasmTarget ports LLVM's WebAssembly backend at the llvm pin *)
(* (dev/PARITY_MASTER.md; dev/LEDGER.md D42). CFGStackify.tla models the   *)
(* blocks, loops and branches; this module adds what an EH pad brings:     *)
(*   machine_function (src/julia/machine.jl): Julia's catch block is an EH *)
(*     pad, reached only by unwinding and beginning with a CATCH; the      *)
(*     EnterNode's CFG edge to it dropped; a block unwinds to its handler  *)
(*     when a statement of it sends an exception there, inference's rule   *)
(*     (typeinf_local, Compiler/src/abstractinterpretation.jl): a :leave   *)
(*     and a return never do, every other statement unless Julia flagged   *)
(*     it IR_FLAG_NOTHROW (nir_code; audit A57S2). :pop_exception emits    *)
(*     nothing (the stackifier's structure carries it).                    *)
(*   placeTryTableMarker (WebAssemblyCFGStackify.cpp:695): a TRY_TABLE at  *)
(*     the nearest common dominator of the pad's unwind predecessors,      *)
(*     walked out past every scope that ends inside, inside a BLOCK its    *)
(*     catch clause branches to; END_TRY_TABLE and END_BLOCK at the pad's  *)
(*     start, before its CATCH.                                            *)
(*   addUnreachableAfterTryTables (:2487): each END_TRY_TABLE split into a *)
(*     block of its own, an UNREACHABLE after it.                          *)
(*   fixCatchUnwindMismatches (:2076): every Julia catch catches every     *)
(*     exception (LLVM's catch-all), so it finds none; it is the identity  *)
(*     here, as in the port.                                               *)
(*   fixCallUnwindMismatches (:1592): walking backward with the stack of   *)
(*     the pads the open try_tables catch to, a throwing instruction whose *)
(*     innermost try_table catches to another pad than its own, or that    *)
(*     should unwind to the caller inside a try_table, is a range;         *)
(*     splitEndLoopBB (:1556) for each destination; each range wrapped by  *)
(*     addNestedTryTable (:1383) in a try_table whose catch_all_ref        *)
(*     branches to the destination's trampoline (getTrampolineBlock,       *)
(*     :1312): END_BLOCK, CATCH_ALL_REF, THROW_REF, the caller's last in   *)
(*     the function under a BLOCK opening it, a pad's before the block of  *)
(*     its END_TRY_TABLE under a BLOCK right after its TRY_TABLE.          *)
(*   rewriteDepthImmediates (:2615): END_TRY_TABLE a scope end, a          *)
(*     TRY_TABLE's catch destination a depth counted outside it.           *)
(* dart2wasm has no counterpart (Kernel's try is structured already).      *)
(*                                                                         *)
(* THE SPECIFICATION extends Ramsey's (CFGStackify.tla's PathsPreserved)   *)
(* to exceptions: UnwindPreserved. An exception thrown by a block's        *)
(* throwing instruction, run by wasm's exception semantics (the innermost  *)
(* open try_table catches it; its catch clause branches to the label at    *)
(* its depth outside the try_table; a catch_all_ref's target rethrows with *)
(* THROW_REF from there; no open try_table, the caller), lands at the      *)
(* CATCH of exactly the pad Julia's handler names, or leaves the function  *)
(* exactly when Julia has no handler for it. Normal control flow keeps     *)
(* PathsPreserved, now through try_tables, UNREACHABLEs and trampolines.   *)
(*                                                                         *)
(* THE CLAIMS, each naming its source, each with a Broken variant (Bug):   *)
(*   PadsOnlyUnwound   an EH pad's predecessors are exactly the blocks     *)
(*                     unwinding to it, and it begins with its CATCH       *)
(*                     (LLVM's EH pad, MachineBasicBlock::isEHPad; port    *)
(*                     9be2abca) (Bug "keepenter": Julia's EnterNode edge   *)
(*                     to the catch block kept);                           *)
(*   UnwindEdgesExact  a block unwinds to its handler exactly when Julia's *)
(*                     inference sends an exception there (typeinf_local;  *)
(*                     WebAssembly::mayThrow, WebAssemblyUtilities.cpp:41)  *)
(*                     (Bug "leaveunwinds": a :leave read as throwing,     *)
(*                     A57S2);                                             *)
(*   WellNested        every END closes the innermost open scope, a        *)
(*                     try_table's too (Bug "trampolineatend": a pad's     *)
(*                     trampoline placed last, like the caller's,          *)
(*                     getTrampolineBlock :1312; Bug "notrywalk": the      *)
(*                     TRY_TABLE at the nearest common dominator of the    *)
(*                     pad's unwind predecessors, not walked out, :695);   *)
(*   CatchDepthCorrect a TRY_TABLE's catch destination is the label at its *)
(*                     depth counted outside it (rewriteDepthImmediates    *)
(*                     :2615) (Bug "catchinside": counted with the         *)
(*                     try_table's own label still on the stack);          *)
(*   PathsPreserved    Ramsey's statement for normal flow (CFGStackify.tla)*)
(*                     (Bug "noupdate": Julia's terminators kept, their    *)
(*                     fallthrough to the original next block, which the   *)
(*                     layout may make a pad's CATCH; WebAssemblyCFGSort   *)
(*                     maybeUpdateTerminator :77);                          *)
(*   UnwindPreserved   the statement above (Bug "nocallfix":               *)
(*                     fixCallUnwindMismatches skipped; Bug "nocaller":    *)
(*                     its caller ranges skipped; Bug "nopadfix": its      *)
(*                     ranges to another pad skipped, :1592);              *)
(*   EveryBlockOnce    the sort places every block (sortBlocks :183) (Bug  *)
(*                     "backedges": a back edge counted, a header never    *)
(*                     ready);                                             *)
(*   DepthCorrect      a branch's depth names its target's label           *)
(*                     (rewriteDepthImmediates :2615) (Bug "endloopatend": *)
(*                     END_LOOP pushes its own block);                     *)
(*   NoAssertion       no assertion of the placement fires: the TRY_TABLE  *)
(*                     after every END marker of its header and before     *)
(*                     every marker nested in it (getLatestInsertPos :234) *)
(*                     (Bug "endsafter": the header's END markers taken    *)
(*                     for scopes nested in the try_table).                *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. The CFGs are Julia's own: the optimized IR   *)
(* of ten try/catch functions (code_typed on Julia 1.12, transcribed in    *)
(* Shapes below: a try, a catch that throws, nested trys, a try in a loop, *)
(* a call after a try, a try over a branch, two trys in sequence, a try on *)
(* one arm of a branch, nested trys over a branch, a try around a loop).   *)
(* A block's statements are the set of kinds that matter: a call Julia did *)
(* not flag nothrow, a :leave; every other statement is nothrow. The sort  *)
(* is every layout sortBlocks can produce under any priority: a block is   *)
(* placed once its predecessors but a back edge's source are, inside the   *)
(* innermost region not yet finished (a loop, or an exception: the pad and *)
(* the blocks it dominates, WebAssemblyExceptionInfo), so every layout     *)
(* LLVM's CompareBlockNumbers order picks is among them. A block's body is *)
(* one instruction (STMTS), throwing when the block does.                  *)
(*                                                                         *)
(* WHERE THE PORT DIFFERS FROM LLVM, checked here: place_block_marker      *)
(* classifies a previously placed BLOCK of the header but not a TRY_TABLE  *)
(* (LLVM :351 names TRY_TABLE too); every TRY_TABLE follows its catch      *)
(* BLOCK, whose end is its pad's, so the BLOCK's rule places the new BLOCK *)
(* before both and WellNested holds without the TRY_TABLE arm.             *)
(*                                                                         *)
(* formal(src/llvm/cfg_stackify.jl place_try_table_marker,                 *)
(* fix_call_unwind_mismatches, add_nested_try_table; src/julia/machine.jl  *)
(* machine_function; src/julia/nir.jl nir_code): every exception lands     *)
(* where Julia's handler says.                                             *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS Bug

Bugs == {"none", "keepenter", "leaveunwinds", "trampolineatend", "catchinside",
         "noupdate", "nocallfix", "nocaller", "nopadfix", "endloopatend", "backedges",
         "notrywalk", "endsafter"}
ASSUME Bug \in Bugs

Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Max(S) == CHOOSE x \in S : \A y \in S : y <= x
Last(s) == s[Len(s)]
Pop(s) == SubSeq(s, 1, Len(s) - 1)
Range(s) == {s[i] : i \in 1..Len(s)}
IndexOf(s, x) == CHOOSE i \in 1..Len(s) : s[i] = x
RECURSIVE SortAsc(_)
SortAsc(S) == IF S = {} THEN << >> ELSE <<Min(S)>> \o SortAsc(S \ {Min(S)})
RECURSIVE SortDesc(_)
SortDesc(S) == IF S = {} THEN << >> ELSE <<Max(S)>> \o SortDesc(S \ {Max(S)})
InsertAt(s, j, x) == SubSeq(s, 1, j - 1) \o <<x>> \o SubSeq(s, j, Len(s))

(* ---- Julia's CFGs: the optimized IR of ten try/catch functions ----------- *)
(* a terminator: return, goto t, fallthrough, goto t if not (GotoIfNot: t on  *)
(* false, the next block on true), and the EnterNode (the next block; its     *)
(* catch block t, Julia's CFG edge the machine function drops)               *)
RET == [k |-> "ret", t |-> 0]
FT == [k |-> "ft", t |-> 0]
G(t) == [k |-> "goto", t |-> t]
C(t) == [k |-> "cond", t |-> t]
E(t) == [k |-> "enter", t |-> t]
CL == {"call", "leave"}
CA == {"call"}
LV == {"leave"}
Sh(n, T, K, H) == [n |-> n, T |-> T, K |-> K, H |-> H]
Shapes == {
  \* f1(x) = try g(x) catch; 0 end
  Sh(4, <<E(4), FT, RET, RET>>, <<{}, CL, {}, {}>>, <<0, 4, 0, 0>>),
  \* f2(x) = try g(x) catch; h(x) end  (the catch throws to the caller)
  Sh(5, <<FT, E(5), FT, RET, RET>>, <<{}, {}, CL, {}, CA>>, <<0, 0, 5, 0, 0>>),
  \* f3(x) = try (try g(x) catch; h(x) end) catch; 0 end  (a :leave alone, B7)
  Sh(9, <<E(9), FT, E(6), FT, G(7), FT, FT, RET, RET>>,
        <<{}, {}, {}, CL, {}, CA, LV, {}, {}>>, <<0, 9, 9, 6, 9, 9, 9, 0, 0>>),
  \* f4: for i in 1:n; try s += g(i) catch; end; end  (blocks merged where Julia's
  \* chain of gotos carries no choice)
  Sh(8, <<C(8), E(5), FT, G(6), FT, C(8), G(2), RET>>,
        <<{}, {}, CL, {}, {}, {}, {}, {}>>, <<0, 0, 5, 0, 0, 0, 0, 0>>),
  \* f5(x) = (try g(x) catch end; h(x))  (a call after the try unwinds to the caller)
  Sh(6, <<FT, E(5), FT, G(6), FT, RET>>, <<{}, {}, CL, {}, {}, CA>>, <<0, 0, 5, 0, 0, 0>>),
  \* f6(x) = try (x > 5 ? g(x) : h(x)) catch; 0 end
  Sh(7, <<E(7), C(4), G(5), FT, FT, RET, RET>>, <<{}, {}, CA, CA, LV, {}, {}>>, <<0, 7, 7, 7, 7, 0, 0>>),
  \* f7(x) = try g(x) catch; try h(x) catch; 1 end end
  Sh(9, <<FT, E(5), FT, RET, FT, E(9), FT, RET, RET>>,
        <<{}, {}, CL, {}, {}, {}, CL, {}, {}>>, <<0, 0, 5, 0, 0, 0, 9, 0, 0>>),
  \* f8(x) = x > 5 ? (try g(x) catch; 0 end) : h(x)
  Sh(6, <<C(6), E(5), FT, RET, RET, RET>>, <<{}, {}, CL, {}, {}, CA>>, <<0, 0, 5, 0, 0, 0>>),
  \* f9(x) = try (x > 5 ? (try g(x) catch; 0 end) : h(x)) catch; 1 end
  Sh(11, <<E(11), C(8), E(6), FT, G(7), FT, G(9), FT, FT, RET, RET>>,
         <<{}, {}, {}, CL, {}, {}, {}, CA, LV, {}, {}>>, <<0, 11, 11, 6, 11, 11, 11, 11, 11, 0, 0>>),
  \* f10(x) = try (while c; g(x) end) catch; end  (a try around a loop)
  Sh(6, <<E(6), FT, C(3), FT, RET, RET>>, <<{}, {}, CA, LV, {}, {}>>, <<0, 6, 6, 6, 0, 0>>)
}

VARIABLES shape, placed, phase, flat, scopes, failed
vars == <<shape, placed, phase, flat, scopes, failed>>

n == shape.n
Blocks == 1..n
Entry == 1
T == shape.T
K == shape.K
H == shape.H
Pads == {T[b].t : b \in {x \in Blocks : T[x].k = "enter"}}

(* ---- the machine function's CFG ----------------------------------------- *)
(* inference's rule: a block sends an exception to its handler when it holds  *)
(* a statement Julia did not flag nothrow that is no :leave and no return     *)
ThrowsJ(b) == "call" \in K[b]
ThrowsM(b) == ThrowsJ(b) \/ (Bug = "leaveunwinds" /\ "leave" \in K[b])
NSucc(b) == CASE T[b].k = "ret"   -> {}
           []   T[b].k = "goto"  -> {T[b].t}
           []   T[b].k = "ft"    -> {b + 1}
           []   T[b].k = "cond"  -> {T[b].t, b + 1}
           []   T[b].k = "enter" -> {b + 1} \cup (IF Bug = "keepenter" THEN {T[b].t} ELSE {})
USucc(b) == IF ThrowsM(b) /\ H[b] # 0 THEN {H[b]} ELSE {}
MSucc(b) == NSucc(b) \cup USucc(b)
MPreds(b) == {p \in Blocks : b \in MSucc(p)}
NPreds(b) == {p \in Blocks : b \in NSucc(p)}

RECURSIVE Closure(_, _, _)
Closure(F(_), S, avoid) ==
    LET next == S \cup ((UNION {F(x) : x \in S}) \ {avoid})
    IN IF next = S THEN S ELSE Closure(F, next, avoid)

Dom == [a \in Blocks |->
          LET r == Closure(LAMBDA x : MSucc(x), {Entry} \ {a}, a)
          IN {b \in Blocks : b = a \/ b \notin r}]
Dominates(a, b) == b \in Dom[a]
BodyOf(h) ==
    LET latches == {p \in MPreds(h) : Dominates(h, p)}
    IN IF latches = {} THEN {} ELSE {h} \cup Closure(LAMBDA x : MPreds(x), latches \ {h}, h)
Headers == {h \in Blocks : BodyOf(h) # {}}
BackEdge(p, s) == s \in MSucc(p) /\ s \in Headers /\ p \in BodyOf(s)
(* an exception: its pad and the blocks the pad dominates (WebAssemblyExceptionInfo) *)
ExcOf(p) == Dom[p]
Regions == {BodyOf(h) : h \in Headers} \cup {ExcOf(p) : p \in Pads}

TypeOK ==
    /\ phase \in {"sort", "stackify", "done", "failed"}
    /\ placed \in Seq(Blocks)
    /\ failed \in BOOLEAN

Init ==
    /\ shape \in Shapes
    /\ placed = <<Entry>>
    /\ phase = "sort" /\ flat = << >> /\ scopes = << >> /\ failed = FALSE

(* ---- CFGSort: any priority. A block is ready once every predecessor but a   *)
(* back edge's source is placed; it must lie in every region begun and not    *)
(* finished (the deferral that keeps loops and exceptions contiguous)         *)
Ready(x) == x \notin Range(placed) /\
            \A p \in MPreds(x) : p \in Range(placed) \/ (BackEdge(p, x) /\ Bug # "backedges")
Active == {R \in Regions : (\E y \in R : y \in Range(placed)) /\ ~(R \subseteq Range(placed))}
Admissible == {x \in Blocks : Ready(x) /\ \A R \in Active : x \in R}

SortStep ==
    /\ phase = "sort"
    /\ IF Len(placed) = n THEN phase' = "stackify" /\ UNCHANGED placed
       ELSE IF Admissible = {} THEN phase' = "failed" /\ UNCHANGED placed
       ELSE \E x \in Admissible : placed' = Append(placed, x) /\ UNCHANGED phase
    /\ UNCHANGED <<shape, flat, scopes, failed>>

(* ---- positions after the sort ------------------------------------------- *)
Pos == [b \in Blocks |-> IndexOf(placed, b)]
PB(i) == placed[i]
PDom(i, j) == Dominates(PB(i), PB(j))
PBody(i) == {Pos[x] : x \in BodyOf(PB(i))}
App == n + 1        \* the appendix block, its id and its position

(* a token: k its kind, t a target block id, o a branch's outcome, s a marker's *)
(* scope, jb the Julia block it comes from, cl a try_table's clause, d a depth  *)
Tok(k, t, o, s, jb) == [k |-> k, t |-> t, o |-> o, s |-> s, jb |-> jb, cl |-> "", d |-> 0]
Begins == {"BLOCK", "LOOP", "TRY_TABLE"}
Ends == {"END_BLOCK", "END_LOOP", "END_TRY_TABLE"}
Markers == Begins \cup Ends
Terminators == {"br", "brif", "ret"}

(* maybeUpdateTerminator: explicit branches to every normal successor but the *)
(* layout successor; the EnterNode falls through to its next block            *)
TermToks(b) ==
    LET c == T[b]
        nx == IF Pos[b] < n THEN PB(Pos[b] + 1) ELSE 0
    IN IF Bug = "noupdate"
       THEN CASE c.k = "ret"  -> <<Tok("ret", 0, "always", 0, b)>>
            []   c.k = "goto" -> <<Tok("br", c.t, "always", 0, b)>>
            []   c.k \in {"ft", "enter"} -> << >>
            []   c.k = "cond" -> <<Tok("brif", c.t, "jump", 0, b)>>
       ELSE CASE c.k = "ret"  -> <<Tok("ret", 0, "always", 0, b)>>
       []   c.k = "goto" -> IF c.t = nx THEN << >> ELSE <<Tok("br", c.t, "always", 0, b)>>
       []   c.k \in {"ft", "enter"} -> IF b + 1 = nx THEN << >> ELSE <<Tok("br", b + 1, "always", 0, b)>>
       []   c.k = "cond" ->
               IF b + 1 = nx THEN <<Tok("brif", c.t, "jump", 0, b)>>
               ELSE IF c.t = nx THEN <<Tok("brif", b + 1, "next", 0, b)>>
               ELSE <<Tok("brif", c.t, "jump", 0, b), Tok("br", b + 1, "always", 0, b)>>
ExplicitlyBranchesTo(p, i) ==
    \E k \in 1..Len(TermToks(PB(p))) : TermToks(PB(p))[k].k \in {"br", "brif"} /\ TermToks(PB(p))[k].t = PB(i)

(* ---- placement over positions 1..n and the appendix n + 1 ---------------- *)
EarliestPos(s, Before(_)) ==
    LET js == {j \in 1..Len(s) : Before(s[j])} IN IF js = {} THEN 1 ELSE Max(js) + 1
LatestPos(s, After(_)) ==
    LET js == {j \in 1..Len(s) : After(s[j])} IN IF js = {} THEN Len(s) + 1 ELSE Min(js)
UpdateTop(tops, b, e) == IF tops[e] = 0 \/ tops[e] > b THEN [tops EXCEPT ![e] = b] ELSE tops
RECURSIVE Walk(_, _, _)
Walk(tops, I, Hd) ==
    IF I <= Hd THEN Hd
    ELSE IF tops[I] # 0
         THEN IF tops[I] > Hd THEN Walk(tops, tops[I], Hd) ELSE tops[I]
         ELSE Walk(tops, I - 1, Hd)
NCD(S) == LET cd == {d \in 1..n : \A p \in S : PDom(d, p)}
          IN CHOOSE d \in cd : \A d2 \in cd : PDom(d2, d)

(* a scope: kind, begin and end positions (block ids after the conversion), *)
(* a try_table's catch target block and clause                              *)
Scope(k, b, e) == [kind |-> k, b |-> b, e |-> e, t |-> 0, cl |-> ""]

PlaceLoop(st, i) ==
    IF PB(i) \notin Headers THEN st
    ELSE LET after == Max(PBody(i)) + 1
             sid == Len(st.scopes) + 1
             ins1 == [st.ins EXCEPT ![i] =
                        InsertAt(@, EarliestPos(@, LAMBDA x : x.k = "END_LOOP"), Tok("LOOP", 0, "", sid, 0))]
             ins2 == [ins1 EXCEPT ![after] =
                        InsertAt(@, EarliestPos(@, LAMBDA x : FALSE), Tok("END_LOOP", 0, "", sid, 0))]
         IN [st EXCEPT !.ins = ins2, !.scopes = Append(st.scopes, Scope("loop", i, after)),
                       !.tops = UpdateTop(st.tops, i, after)]

(* placeBlockMarker (283), as the port classifies the header's markers *)
PlaceBlock(st, i) ==
    LET fp == {p \in {Pos[q] : q \in NPreds(PB(i))} : p < i}
        branched == \E p \in fp : ExplicitlyBranchesTo(p, i)
    IN IF fp = {} \/ ~branched THEN st
       ELSE LET h == Walk(st.tops, i - 1, NCD(fp))
                sid == Len(st.scopes) + 1
                After(x) == \/ x.k = "LOOP" /\ st.scopes[x.s].e - 1 < i
                            \/ x.k = "BLOCK" /\ st.scopes[x.s].e <= i
                            \/ x.k \in Terminators
                Before(x) == x.k = "END_LOOP" /\ st.scopes[x.s].b >= h
                ins1 == [st.ins EXCEPT ![h] = InsertAt(@, LatestPos(@, After), Tok("BLOCK", 0, "", sid, 0))]
                ins2 == [ins1 EXCEPT ![i] = InsertAt(@, EarliestPos(@, Before), Tok("END_BLOCK", 0, "", sid, 0))]
            IN [st EXCEPT !.ins = ins2, !.scopes = Append(st.scopes, Scope("block", h, i)),
                          !.tops = UpdateTop(st.tops, h, i)]

(* placeTryTableMarker (695) *)
PlaceTryTable(st, i) ==
    LET p == PB(i)
        preds == {Pos[q] : q \in MPreds(p)}
        fp == {q \in preds : q < i}
    IN IF fp = {} THEN st
       ELSE LET bottom == Max({Pos[x] : x \in ExcOf(p)})
                cont == IF bottom + 1 > App THEN App ELSE bottom + 1
                h == IF Bug = "notrywalk" THEN NCD(fp) ELSE Walk(st.tops, bottom, NCD(fp))
                bsid == Len(st.scopes) + 2      \* registerTryScope, then registerScope
                tsid == Len(st.scopes) + 1
                After(x) == \/ x.k = "LOOP" /\ st.scopes[x.s].e - 1 < i
                            \/ x.k \in {"BLOCK", "TRY_TABLE"}
                            \/ x.k \in Terminators
                            \/ x.k = "body" /\ h \in preds
                            \/ x.k \in Ends /\ Bug = "endsafter"
                at == LatestPos(st.ins[h], After)
                bad == \E j \in at..Len(st.ins[h]) :
                         \/ st.ins[h][j].k \in Ends
                         \/ st.ins[h][j].k = "LOOP" /\ ~(st.scopes[st.ins[h][j].s].e - 1 < i)
                tt == [Tok("TRY_TABLE", p, "", tsid, 0) EXCEPT !.cl = "catch"]
                ins1 == [st.ins EXCEPT ![h] = InsertAt(InsertAt(@, at, Tok("BLOCK", 0, "", bsid, 0)), at + 1, tt)]
                Before2(x) == x.k = "END_LOOP" /\ st.scopes[x.s].b >= h
                at2 == EarliestPos(ins1[i], Before2)
                bad2 == \E j \in 1..(at2 - 1) : ins1[i][j].k \in {"LOOP", "CATCH"}
                ins2 == [ins1 EXCEPT ![i] = InsertAt(InsertAt(@, at2, Tok("END_TRY_TABLE", 0, "", tsid, 0)),
                                                     at2 + 1, Tok("END_BLOCK", 0, "", bsid, 0))]
                tsc == [Scope("try", h, i) EXCEPT !.t = p, !.cl = "catch"]
            IN [st EXCEPT !.ins = ins2,
                          !.scopes = Append(Append(st.scopes, tsc), Scope("block", h, i)),
                          !.tops = UpdateTop(UpdateTop(st.tops, h, i), h, cont),
                          !.bad = st.bad \/ bad \/ bad2]

(* placeMarkers (2509): every LOOP, then in layout order a TRY_TABLE for a pad *)
(* or a BLOCK for any other block                                              *)
RECURSIVE FoldLoops(_, _)
FoldLoops(st, i) == IF i > n THEN st ELSE FoldLoops(PlaceLoop(st, i), i + 1)
RECURSIVE FoldMarks(_, _)
FoldMarks(st, i) == IF i > n THEN st
                    ELSE FoldMarks(IF PB(i) \in Pads THEN PlaceTryTable(st, i) ELSE PlaceBlock(st, i), i + 1)

Start == [ins |-> [i \in 1..App |->
                     IF i <= n
                     THEN (IF PB(i) \in Pads THEN <<Tok("CATCH", PB(i), "", 0, PB(i))>> ELSE << >>)
                          \o <<Tok("body", PB(i), "", 0, PB(i))>> \o TermToks(PB(i))
                     ELSE << >>],
          scopes |-> << >>, tops |-> [i \in 1..App |-> 0], bad |-> FALSE]

(* ---- after placement: block ids. Julia's blocks keep theirs, the appendix   *)
(* is n + 1, every block made later the next free id                           *)
MaxId == n + 16
IdOf(i) == IF i <= n THEN PB(i) ELSE App
ToIds(st) ==
    [ins |-> [x \in 1..MaxId |-> IF x <= n THEN st.ins[Pos[x]] ELSE IF x = App THEN st.ins[App] ELSE << >>],
     lay |-> placed \o <<App>>,
     scopes |-> [j \in 1..Len(st.scopes) |->
                   [st.scopes[j] EXCEPT !.b = IdOf(@), !.e = IdOf(@)]],
     next |-> App + 1, tramp |-> [x \in {} |-> 0], bad |-> st.bad]

(* the block of the layout holding a token satisfying P, and its index there *)
HoldsTok(st, x, P(_)) == \E j \in 1..Len(st.ins[x]) : P(st.ins[x][j])
BlockOf(st, P(_)) == CHOOSE x \in Range(st.lay) : HoldsTok(st, x, P)
TokIdx(st, x, P(_)) == CHOOSE j \in 1..Len(st.ins[x]) : P(st.ins[x][j])
InsertBlockBefore(lay, before, x) == InsertAt(lay, IndexOf(lay, before), x)
InsertBlockAfter(lay, after, x) == InsertAt(lay, IndexOf(lay, after) + 1, x)

(* addUnreachableAfterTryTables (2487): each END_TRY_TABLE and what precedes it *)
(* moved to a new block before its own, an UNREACHABLE after it                 *)
SplitETT(st, sid) ==
    LET IsE(x) == x.k = "END_TRY_TABLE" /\ x.s = sid
        b == BlockOf(st, IsE)
        j == TokIdx(st, b, IsE)
        x == st.next
        moved == SubSeq(st.ins[b], 1, j)
        rest == SubSeq(st.ins[b], j + 1, Len(st.ins[b]))
        unr == Tok("UNREACHABLE", 0, "", 0, 0)
    IN [st EXCEPT !.ins = [st.ins EXCEPT ![x] = moved \o <<unr>>, ![b] = rest],
                  !.lay = InsertBlockBefore(st.lay, b, x),
                  !.scopes[sid].e = x,
                  !.next = x + 1]
RECURSIVE FoldSplit(_, _)
FoldSplit(st, sids) == IF sids = << >> THEN st ELSE FoldSplit(SplitETT(st, Head(sids)), Tail(sids))
TrySids(st) == SortAsc({j \in 1..Len(st.scopes) : st.scopes[j].kind = "try"})

(* ---- the flat program: each token with its block (at) --------------------- *)
AtTok(x, b) == [k |-> x.k, t |-> x.t, o |-> x.o, s |-> x.s, jb |-> x.jb, cl |-> x.cl, d |-> x.d, at |-> b]
RECURSIVE CatL(_, _)
CatL(st, lay) == IF lay = << >> THEN << >>
                 ELSE [j \in 1..Len(st.ins[Head(lay)]) |-> AtTok(st.ins[Head(lay)][j], Head(lay))]
                      \o CatL(st, Tail(lay))
Flat(st) == CatL(st, st.lay)

(* the scopes open at token k of fl, innermost last *)
RECURSIVE OpenFromF(_, _, _, _)
OpenFromF(fl, j, k, stk) ==
    IF j >= k THEN stk
    ELSE OpenFromF(fl, j + 1, k,
             CASE fl[j].k \in Begins -> Append(stk, fl[j].s)
             []   fl[j].k \in Ends   -> IF stk = << >> THEN stk ELSE Pop(stk)
             []   OTHER              -> stk)
OpenAtF(fl, k) == OpenFromF(fl, 1, k, << >>)
(* the pads the try_tables open at k catch to, innermost last (EHPadStack) *)
TryTops(st, fl, k) == LET o == OpenAtF(fl, k)
                          ts == SelectSeq(o, LAMBDA s : st.scopes[s].kind = "try")
                      IN [j \in 1..Len(ts) |-> st.scopes[ts[j]].t]

(* fixCallUnwindMismatches (1592): the ranges, each one throwing body (a      *)
(* block's STMTS is its one instruction), with its right destination: a       *)
(* block's EH pad successor, or "caller"                                       *)
Caller == 0
CallRanges(st) ==
    LET fl == Flat(st)
        Thr(k) == fl[k].k = "body" /\ ThrowsM(fl[k].jb)
        PadMis == {k \in 1..Len(fl) : Thr(k) /\ USucc(fl[k].jb) # {} /\
                     LET tt == TryTops(st, fl, k) IN tt = << >> \/ Last(tt) # H[fl[k].jb]}
        CallerMis == {k \in 1..Len(fl) : Thr(k) /\ USucc(fl[k].jb) = {} /\
                     LET tt == TryTops(st, fl, k) IN tt # << >> /\ Last(tt) # Caller}
    IN [pad |-> IF Bug = "nopadfix" THEN {} ELSE {<<fl[k].jb, H[fl[k].jb]>> : k \in PadMis},
        caller |-> IF Bug = "nocaller" THEN {} ELSE {<<fl[k].jb, Caller>> : k \in CallerMis}]

(* splitEndLoopBB (1556): END_LOOPs before an END_TRY_TABLE move to a block of *)
(* their own before it                                                          *)
SplitEndLoop(st, pad) ==
    LET sid == CHOOSE j \in 1..Len(st.scopes) : st.scopes[j].kind = "try" /\ st.scopes[j].t = pad
                                                 /\ st.scopes[j].cl = "catch"
        IsE(x) == x.k = "END_TRY_TABLE" /\ x.s = sid
        b == BlockOf(st, IsE)
        j == TokIdx(st, b, IsE)
        els == {m \in 1..(j - 1) : st.ins[b][m].k = "END_LOOP"}
        y == st.next
    IN IF els = {} THEN st
       ELSE [st EXCEPT !.ins = [st.ins EXCEPT ![y] = SubSeq(st.ins[b], 1, Max(els)),
                                              ![b] = SubSeq(st.ins[b], Max(els) + 1, Len(st.ins[b]))],
                       !.lay = InsertBlockBefore(st.lay, b, y),
                       !.next = y + 1]

(* getTrampolineBlock (1312), made once per destination *)
Trampoline(st, dest) ==
    IF dest \in DOMAIN st.tramp THEN st
    ELSE LET x == st.next
             sid == Len(st.scopes) + 1
             blk == Tok("BLOCK", 0, "", sid, 0)
             tins == <<Tok("END_BLOCK", 0, "", sid, 0), Tok("CATCH_ALL_REF", 0, "", 0, 0),
                       Tok("THROW_REF", 0, "", 0, 0)>>
             \* the BLOCK and the trampoline's place in the layout
             st1 == IF dest = Caller
                    THEN [st EXCEPT !.ins[Head(st.lay)] = <<blk>> \o @,
                                    !.lay = Append(@, x)]
                    ELSE LET tsid == CHOOSE j \in 1..Len(st.scopes) : st.scopes[j].kind = "try"
                                       /\ st.scopes[j].t = dest /\ st.scopes[j].cl = "catch"
                             IsT(y) == y.k = "TRY_TABLE" /\ y.s = tsid
                             IsE(y) == y.k = "END_TRY_TABLE" /\ y.s = tsid
                             tb == BlockOf(st, IsT)
                             eb == BlockOf(st, IsE)
                         IN [st EXCEPT !.ins[tb] = InsertAt(@, TokIdx(st, tb, IsT) + 1, blk),
                                       !.lay = IF Bug = "trampolineatend" THEN Append(@, x)
                                               ELSE InsertBlockBefore(@, eb, x)]
             pred == st1.lay[IndexOf(st1.lay, x) - 1]
             bb == BlockOf(st1, LAMBDA y : y.k = "BLOCK" /\ y.s = sid)
         IN [st1 EXCEPT !.ins = [st1.ins EXCEPT ![x] = tins,
                                    ![pred] = Append(@, Tok("UNREACHABLE", 0, "", 0, 0))],
                        !.scopes = Append(@, Scope("block", bb, x)),
                        !.tramp = [d \in DOMAIN st1.tramp \cup {dest} |->
                                     IF d = dest THEN x ELSE st1.tramp[d]],
                        !.next = x + 1]

(* addNestedTryTable (1383): the range's body in a try_table whose catch_all_ref *)
(* branches to the trampoline; its END_TRY_TABLE in a block of its own after the  *)
(* body, the block split when the body is not its last token                      *)
NestedTry(st0, jb, dest) ==
    LET st == Trampoline(st0, dest)
        tr == st.tramp[dest]
        IsB(y) == y.k = "body" /\ y.jb = jb
        b == BlockOf(st, IsB)
        j == TokIdx(st, b, IsB)
        sid == Len(st.scopes) + 1
        tt == [Tok("TRY_TABLE", tr, "", sid, 0) EXCEPT !.cl = "catch_all_ref"]
        e == st.next
        post == st.next + 1
        whole == st.ins[b]
        ins1 == [st.ins EXCEPT ![b] = SubSeq(whole, 1, j - 1) \o <<tt>> \o SubSeq(whole, j, j),
                               ![e] = <<Tok("END_TRY_TABLE", 0, "", sid, 0)>>,
                               ![post] = SubSeq(whole, j + 1, Len(whole))]
        last == j = Len(whole)
        lay1 == IF last THEN InsertBlockAfter(st.lay, b, e)
                ELSE InsertBlockAfter(InsertBlockAfter(st.lay, b, post), b, e)
    IN [st EXCEPT !.ins = ins1, !.lay = lay1,
                  !.scopes = Append(@, [Scope("try", b, e) EXCEPT !.t = tr, !.cl = "catch_all_ref"]),
                  !.next = IF last THEN e + 1 ELSE post + 1]
RECURSIVE FoldNested(_, _)
FoldNested(st, rs) == IF rs = {} THEN st
                      ELSE LET r == CHOOSE r \in rs : \A r2 \in rs : r[1] <= r2[1]
                           IN FoldNested(NestedTry(st, r[1], r[2]), rs \ {r})
RECURSIVE FoldSplitLoop(_, _)
FoldSplitLoop(st, ps) == IF ps = {} THEN st
                         ELSE LET p == Min(ps) IN FoldSplitLoop(SplitEndLoop(st, p), ps \ {p})
FixCall(st) ==
    IF Bug = "nocallfix" THEN st
    ELSE LET rs == CallRanges(st)
             dests == {r[2] : r \in rs.pad}
             st1 == FoldSplitLoop(st, dests)
         IN FoldNested(FoldNested(st1, rs.pad), rs.caller)

(* rewriteDepthImmediates (2615): the scope targets the backward walk holds at k *)
RECURSIVE Walkback(_, _, _, _, _)
Walkback(fl, sc, j, k, stk) ==
    IF j <= k THEN stk
    ELSE LET x == fl[j] IN
         Walkback(fl, sc, j - 1, k,
             CASE x.k \in Begins           -> Pop(stk)
             []   x.k \in {"END_BLOCK", "END_TRY_TABLE"} -> Append(stk, x.at)
             []   x.k = "END_LOOP"         -> Append(stk, IF Bug = "endloopatend" THEN x.at ELSE sc[x.s].b)
             []   OTHER                    -> stk)
RECURSIVE DepthIn(_, _, _)
DepthIn(stk, t, d) == IF d >= Len(stk) THEN Len(stk)
                      ELSE IF stk[Len(stk) - d] = t THEN d ELSE DepthIn(stk, t, d + 1)
(* a TRY_TABLE's catch destination is counted outside it: the walk's stack once *)
(* the TRY_TABLE pops, k - 1's                                                   *)
Depths(fl, sc) ==
    [k \in 1..Len(fl) |->
       IF fl[k].k \in {"br", "brif"}
       THEN [fl[k] EXCEPT !.d = DepthIn(Walkback(fl, sc, Len(fl), k, << >>), fl[k].t, 0)]
       ELSE IF fl[k].k = "TRY_TABLE"
       THEN [fl[k] EXCEPT !.d = DepthIn(Walkback(fl, sc, Len(fl), IF Bug = "catchinside" THEN k ELSE k - 1, << >>),
                                       fl[k].t, 0)]
       ELSE fl[k]]

StackifyStep ==
    /\ phase = "stackify"
    /\ LET st1 == FoldMarks(FoldLoops(Start, 1), 1)
           st2 == ToIds(st1)
           st3 == FoldSplit(st2, TrySids(st2))
           st4 == FixCall(st3)
           fl == Flat(st4)
       IN /\ flat' = Depths(fl, st4.scopes)
          /\ scopes' = st4.scopes
          /\ failed' = st4.bad
    /\ phase' = "done"
    /\ UNCHANGED <<shape, placed>>

Terminal == phase \in {"done", "failed"} /\ UNCHANGED vars
Next == SortStep \/ StackifyStep \/ Terminal
Spec == Init /\ [][Next]_vars

(* ---- wasm's semantics of the structured program ------------------------- *)
OpenAt(k) == OpenAtF(flat, k)
(* the block a label names: a BLOCK's or TRY_TABLE's end block, a LOOP's header *)
LabelBlock(sid) == IF scopes[sid].kind = "loop" THEN scopes[sid].b ELSE scopes[sid].e
EndKind(sid) == CASE scopes[sid].kind = "block" -> "END_BLOCK"
                []   scopes[sid].kind = "try"   -> "END_TRY_TABLE"
                []   OTHER                      -> "LOOP"
Resume(sid) == (CHOOSE j \in 1..Len(flat) : flat[j].k = EndKind(sid) /\ flat[j].s = sid) + 1
NonMarker(j) == flat[j].k \notin Markers
(* the first token from j that is no marker: its index, Len + 1 off the end *)
RECURSIVE NextReal(_)
NextReal(j) == IF j > Len(flat) THEN Len(flat) + 1 ELSE IF NonMarker(j) THEN j ELSE NextReal(j + 1)
(* the Julia block whose body is reached from j: -2 off the end, -3 at a token *)
(* that is no body (an UNREACHABLE, a CATCH, a trampoline's)                   *)
NextBody(j) == LET r == NextReal(j) IN
               IF r > Len(flat) THEN -2 ELSE IF flat[r].k = "body" THEN flat[r].t ELSE -3
BrLand(k) == LET stk == OpenAt(k) IN
             IF flat[k].d >= Len(stk) THEN -4 ELSE NextBody(Resume(stk[Len(stk) - flat[k].d]))
TermIdx(i) == SortAsc({k \in 1..Len(flat) : flat[k].jb = i /\ flat[k].k \in Terminators})
BodyIdx(i) == CHOOSE k \in 1..Len(flat) : flat[k].k = "body" /\ flat[k].jb = i
LastIdx(i) == Max({k \in 1..Len(flat) : flat[k].jb = i})
RECURSIVE LandFrom(_, _, _)
LandFrom(i, ks, o) ==
    IF ks = << >> THEN NextBody(LastIdx(i) + 1)
    ELSE LET x == flat[Head(ks)] IN
         CASE x.k = "ret"             -> -1
         []   x.k = "br"              -> BrLand(Head(ks))
         []   x.k = "brif" /\ x.o = o -> BrLand(Head(ks))
         []   OTHER                   -> LandFrom(i, Tail(ks), o)
Outcomes(b) == IF T[b].k = "cond" THEN {"jump", "next"} ELSE {"always"}
Dest(b, o) == CASE T[b].k = "ret"  -> -1
              []   T[b].k = "goto" -> T[b].t
              []   T[b].k \in {"ft", "enter"} -> b + 1
              []   T[b].k = "cond" -> IF o = "jump" THEN T[b].t ELSE b + 1

(* an exception thrown at token k: the innermost open try_table catches it and *)
(* branches to the label at its catch depth outside it; a catch lands at the   *)
(* pad whose CATCH follows, a catch_all_ref's target rethrows (THROW_REF) from *)
(* there; with no try_table open it leaves the function (0); -5 a landing that *)
(* is neither; fuel bounds the rethrows                                        *)
RECURSIVE Throw(_, _)
Throw(k, fuel) ==
    LET o == OpenAt(k)
        tries == {m \in 1..Len(o) : scopes[o[m]].kind = "try"}
    IN IF tries = {} THEN Caller
       ELSE IF fuel = 0 THEN -6
       ELSE LET sid == o[Max(tries)]
                tk == CHOOSE j \in 1..Len(flat) : flat[j].k = "TRY_TABLE" /\ flat[j].s = sid
                out == OpenAt(tk)
            IN IF flat[tk].d >= Len(out) THEN -4
               ELSE LET r == NextReal(Resume(out[Len(out) - flat[tk].d])) IN
                    IF r > Len(flat) THEN -5
                    ELSE IF flat[tk].cl = "catch"
                         THEN IF flat[r].k = "CATCH" /\ NextBody(r + 1) = flat[r].t THEN flat[r].t ELSE -5
                         ELSE IF flat[r].k = "CATCH_ALL_REF" /\ r + 1 <= Len(flat) /\ flat[r + 1].k = "THROW_REF"
                              THEN Throw(r + 1, fuel - 1) ELSE -5

(* ---- the claims ----------------------------------------------------------- *)
EveryBlockOnce == phase # "failed"

PadsOnlyUnwound ==
    \A p \in Pads : MPreds(p) = {b \in Blocks : p \in USucc(b)}

UnwindEdgesExact ==
    \A b \in Blocks : USucc(b) = (IF ThrowsJ(b) /\ H[b] # 0 THEN {H[b]} ELSE {})

NoAssertion == phase = "done" => ~failed

RECURSIVE Nested(_, _)
Nested(j, stk) ==
    IF j > Len(flat) THEN stk = << >>
    ELSE CASE flat[j].k \in Begins -> Nested(j + 1, Append(stk, flat[j].s))
         []   flat[j].k \in Ends   -> stk # << >> /\ Last(stk) = flat[j].s /\ Nested(j + 1, Pop(stk))
         []   OTHER                -> Nested(j + 1, stk)
WellNested == phase = "done" => Nested(1, << >>)

Branches == {k \in 1..Len(flat) : flat[k].k \in {"br", "brif"}}
DepthCorrect ==
    phase = "done" =>
        \A k \in Branches : LET stk == OpenAt(k) IN
            flat[k].d < Len(stk) /\ LabelBlock(stk[Len(stk) - flat[k].d]) = flat[k].t

TryTables == {k \in 1..Len(flat) : flat[k].k = "TRY_TABLE"}
CatchDepthCorrect ==
    phase = "done" =>
        \A k \in TryTables : LET stk == OpenAt(k) IN
            flat[k].d < Len(stk) /\ LabelBlock(stk[Len(stk) - flat[k].d]) = flat[k].t

PathsPreserved ==
    phase = "done" =>
        /\ NextBody(1) = Entry
        /\ \A b \in Blocks : \A o \in Outcomes(b) : LandFrom(b, TermIdx(b), o) = Dest(b, o)

UnwindPreserved ==
    phase = "done" =>
        \A b \in Blocks : ThrowsJ(b) => Throw(BodyIdx(b), 4) = H[b]
=============================================================================
