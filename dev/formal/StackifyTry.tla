---------------------------- MODULE StackifyTry ----------------------------
(***************************************************************************)
(* The try_table placement and the unwind-mismatch walk of LLVM's          *)
(* WebAssemblyCFGStackify.cpp at the llvm pin (dev/PARITY_MASTER.md;       *)
(* dev/LEDGER.md D42), written once for the two models that use them:      *)
(* CFGStackify.tla (LLVM's sort with its exception arm over every CFG of   *)
(* four blocks) and CFGStackifyEH.tla (the placement, the fix and every    *)
(* throw's routing over Julia's own try/catch CFGs). Each EXTENDS this     *)
(* module and keeps its own claims; a module of definitions only, with no  *)
(* variable and no claim of its own.                                       *)
(*                                                                         *)
(* A placement state is a record holding at least `ins` (each position's   *)
(* instruction tokens, a token a record with `k` its kind and `s` its      *)
(* scope), `scopes` (each scope a record with `kind`, `b` and `e`), `tops` *)
(* (ScopeTops by position) and `bad` (whether a placement assertion of     *)
(* LLVM's fired). A model passes its own token and scope constructors.     *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Max(S) == CHOOSE x \in S : \A y \in S : y <= x
Last(s) == s[Len(s)]
Pop(s) == SubSeq(s, 1, Len(s) - 1)
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
(* the walk out of placeBlockMarker (309) and placeTryTableMarker (727):     *)
(* from I down to the header H, skipping a scope that lies between,          *)
(* stopping at one that begins at or above the header                        *)
RECURSIVE Walk(_, _, _)
Walk(tops, I, H) ==
    IF I <= H THEN H
    ELSE IF tops[I] # 0
         THEN IF tops[I] > H THEN Walk(tops, tops[I], H) ELSE tops[I]
         ELSE Walk(tops, I - 1, H)

(* placeTryTableMarker (695) for the EH pad at position i: `preds` the       *)
(* positions of its unwind predecessors, `bottom` the position of its        *)
(* exception's last block, `last` the last position of the layout, NCD the   *)
(* nearest common dominator of a set of positions. At the nearest common     *)
(* dominator of the predecessors above the pad, walked out from the bottom   *)
(* past every scope between (unless `nowalk`), a BLOCK and the TRY_TABLE     *)
(* catching to it (registerTryScope, then registerScope), after the LOOPs of *)
(* loops ending above the pad, the markers already there, the terminators    *)
(* and, when the header itself unwinds to the pad, its body (plus whatever   *)
(* ExtraAfter adds: a Broken variant's); END_TRY_TABLE and END_BLOCK at the  *)
(* pad's start, after the END_LOOPs of loops beginning inside; the scope     *)
(* tops at the pad and at the block after the bottom, the bottom itself when *)
(* it is last. `bad` records LLVM's assertions: no END marker or LOOP of a   *)
(* loop ending below the pad after the TRY_TABLE, and no LOOP or CATCH       *)
(* before the END_TRY_TABLE.                                                 *)
PlaceTryTableMarker(st, i, preds, bottom, last, NCD(_), nowalk,
                    BlockTok(_), TryTok(_), EndTryTok(_), EndBlockTok(_),
                    TryScope(_, _), BlockScope(_, _), ExtraAfter(_)) ==
    LET fp == {q \in preds : q < i}
    IN IF fp = {} THEN st
       ELSE LET cont == IF bottom + 1 <= last THEN bottom + 1 ELSE bottom
                h == IF nowalk THEN NCD(fp) ELSE Walk(st.tops, bottom, NCD(fp))
                tsid == Len(st.scopes) + 1
                bsid == Len(st.scopes) + 2
                After(x) == \/ x.k = "LOOP" /\ st.scopes[x.s].e - 1 < i
                            \/ x.k \in {"BLOCK", "TRY_TABLE"}
                            \/ x.k \in {"br", "brif", "ret"}
                            \/ x.k = "body" /\ h \in preds
                            \/ ExtraAfter(x)
                at == LatestPos(st.ins[h], After)
                bad == \E j \in at..Len(st.ins[h]) :
                         \/ st.ins[h][j].k \in {"END_BLOCK", "END_LOOP", "END_TRY_TABLE"}
                         \/ st.ins[h][j].k = "LOOP" /\ ~(st.scopes[st.ins[h][j].s].e - 1 < i)
                ins1 == [st.ins EXCEPT ![h] = InsertAt(InsertAt(@, at, BlockTok(bsid)), at + 1, TryTok(tsid))]
                Before2(x) == x.k = "END_LOOP" /\ st.scopes[x.s].b >= h
                at2 == EarliestPos(ins1[i], Before2)
                bad2 == \E j \in 1..(at2 - 1) : ins1[i][j].k \in {"LOOP", "CATCH"}
                ins2 == [ins1 EXCEPT ![i] = InsertAt(InsertAt(@, at2, EndTryTok(tsid)), at2 + 1, EndBlockTok(bsid))]
            IN [st EXCEPT !.ins = ins2,
                          !.scopes = Append(Append(st.scopes, TryScope(h, i)), BlockScope(h, i)),
                          !.tops = UpdateTop(UpdateTop(st.tops, h, i), h, cont),
                          !.bad = st.bad \/ bad \/ bad2]

(* fixCallUnwindMismatches's EHPadStack (1592): walking the flat program fl   *)
(* backward from its end to token k, a TRY_TABLE pops and an END_TRY_TABLE    *)
(* pushes the pad its try_table catches to, PadOf of its scope; the stack     *)
(* held at k, innermost last                                                  *)
RECURSIVE EHPadStackAt(_, _, _, _, _)
EHPadStackAt(PadOf(_), fl, j, k, stk) ==
    IF j <= k THEN stk
    ELSE EHPadStackAt(PadOf, fl, j - 1, k,
             IF fl[j].k = "TRY_TABLE" THEN Pop(stk)
             ELSE IF fl[j].k = "END_TRY_TABLE" THEN Append(stk, PadOf(fl[j].s))
             ELSE stk)
=============================================================================
