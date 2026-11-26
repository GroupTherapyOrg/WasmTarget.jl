---------------------------- MODULE ClassIdSearch ----------------------------
(***************************************************************************)
(* A TLA+ model of WasmTarget's class-id search, the port of dart2wasm's  *)
(* MacroAssembler.classIdSearch (dart-sdk@898a1e4b                        *)
(* pkg/dart2wasm/lib/code_generator.dart:5709, :5729 _binaryClassIdSearch, *)
(* :5805 _linearClassIdSearch, :5684 emitClassIdRangeCheck) as            *)
(* src/code_generator.jl writes it: class_id_search, _binary_class_id_search, *)
(* _linear_class_id_search, emit_class_id_range_check. It decides every   *)
(* abstract isa and typeassert (emit_class_id_range_check: match pushes 1, *)
(* miss pushes 0), === on abstract operands, nfields, tuple_index and     *)
(* every polymorphic dispatcher (translator.jl's generate: match a direct *)
(* call, miss the dispatch-table call or none).                           *)
(*                                                                        *)
(* THE CODE (Emit below, statement for statement): `[i32] -> [outputs]`,  *)
(* a class id consumed. No range and a miss: drop, miss. No range and no  *)
(* miss: the Internal rejection (dart's assert). Else the id is stored    *)
(* to a local and, for at most 3 ranges, the LINEAR form: in a block      *)
(* `done`, for each range in order, `id == start` (length 1) or           *)
(* `(id - start) <u length`, an `if` holding match(value), br done; then  *)
(* miss and br done, or unreachable when no miss is given. For 4 or more, *)
(* the BINARY form: blocks `done` and `fail`; search(left, right, area)   *)
(* over the 0-based indices with the search area [0, 0xffffffff]: a leaf  *)
(* (left = right) first checks its range lies inside the area (the        *)
(* Internal rejection otherwise); with no miss, or a range covering the   *)
(* whole area, it emits match, br done untested; else a test chosen by    *)
(* the area (`== start` for length 1; `>=u start` when the area ends      *)
(* inside the range; `<=u end` when it starts inside; else `(id - start)  *)
(* <u length`), an `if` holding match, br done, and br fail after it. An  *)
(* inner node splits at mid = (left + right) div 2: `id <=u end(mid)`, an *)
(* `if` holding the left search over [area.start, end(mid)], then the     *)
(* right search over [end(mid) + 1, area.end] after it. Every subtree     *)
(* ends in a br (a leaf's last instruction; an inner node's right         *)
(* subtree's), so the left `if` never falls through into the right half:  *)
(* the model executes the emitted instructions, so this is checked, not   *)
(* assumed. After `fail`'s end: miss, br done, or unreachable.            *)
(*                                                                        *)
(* THE PREMISE (dart's doc comment, :5703: "The [ranges] have to be       *)
(* non-empty, non-overlapping and sorted"): each range has start <= end,  *)
(* sorted by start, no two overlapping; adjacent ranges are allowed       *)
(* (a dispatcher's ranges carry different targets). normalize             *)
(* (class_info.jl, dart class_info.dart:1093) gives a class's ranges this *)
(* shape and stronger (not adjacent): ClassIdNumbering.tla's Normalized.  *)
(* A caller with values sorts its own (record_class_generator.jl sorts by *)
(* start). The binary form's leaf guard enforces the premise (leaf i's    *)
(* area starts at end(i-1) + 1, so the guard is start(i) > end(i-1)); the *)
(* linear form checks nothing: an overlap there routes the shared ids to  *)
(* the first range listed (MCClassIdSearchUnnormalizedBroken.cfg).        *)
(*                                                                        *)
(* WITH NO MISS (dart's unchecked last range): the caller asserts the id  *)
(* lies in one of the ranges (a dispatcher with no fallback: every class  *)
(* reaching the selector is a static target, translator.jl:2047's         *)
(* need_fallback). The model takes it as a premise: Init picks, for no    *)
(* miss, only ids the ranges cover. Outside it the linear form traps      *)
(* (unreachable) and the binary form takes the arm of the leaf whose area *)
(* holds the id, its test elided: a plausible match.                      *)
(*                                                                        *)
(* ABSTRACTION. i32 by a W-bit word: ids and constants mod 2^W, the area  *)
(* bound 0xffffffff by Max = 2^W - 1, unsigned compares on 0..Max, a      *)
(* signed compare by two's complement. Class ids lie in 0..IdMax with     *)
(* IdMax < 2^(W-1), as real ids lie far below 2^31 (so a length is        *)
(* positive as a signed constant too); the run-time id ranges over the    *)
(* whole word, so ids above every range are searched too. Every sorted,   *)
(* disjoint list of up to N ranges over 0..IdMax, each with or without a  *)
(* miss, and every id: N = 6 reaches the linear form (0-3 ranges) and the *)
(* binary form at 4, 5 and 6 ranges (depths 2 and 3 of splits). Each     *)
(* range's value is its index (distinct values are the general case: the  *)
(* search is value-blind, emitting match per entry; emit_class_id_range_ *)
(* check's values are all `nothing`). match(k) and miss() are abstracted  *)
(* to recording their arm and leaving the outputs (br done carries them). *)
(* A ghost `leaf` instruction, a no-op, marks each leaf with its area so  *)
(* AreaSound can read it; it emits nothing in src.                        *)
(*                                                                        *)
(* Claims:                                                                *)
(*   Routes     an id lying in range k ends with exactly match(k) taken   *)
(*              (no trap, no other arm), whenever the compile succeeds    *)
(*   Misses     with a miss given, an id in no range ends with exactly    *)
(*              miss() taken                                              *)
(*   AreaSound  the compile is rejected only for no range and no miss     *)
(*              (every leaf's range lies inside its area: the guard never *)
(*              fires on the premise), and an id reaching a leaf lies in  *)
(*              that leaf's area                                          *)
(*   Depth      the `if` tests executed are at most the range count       *)
(*              (linear) or ceil(log2 n) + 1 (binary)                     *)
(*   Ends       the execution ends (no backward branch; with Depth, the   *)
(*              tree's depth bounded)                                     *)
(* Broken, each refuted by TLC:                                           *)
(*   MCClassIdSearchElideWithMissBroken.cfg  the leaf test dropped though *)
(*     a miss is given: Misses (an outside id takes the arm, a plausible  *)
(*     true from isa)                                                     *)
(*   MCClassIdSearchSplitOffByOneBroken.cfg  the split test `<u end(mid)` *)
(*     where `<=u`: Routes (end(mid) itself goes right)                   *)
(*   MCClassIdSearchSignedLinearBroken.cfg  the linear `(id - start)`     *)
(*     compared signed: Misses (an id below start wraps negative, passes) *)
(*   MCClassIdSearchUnnormalizedBroken.cfg  a caller skips normalize, its *)
(*     ranges unsorted or overlapping: Routes                             *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS W, IdMax, N, ElideWithMiss, SplitOffByOne, SignedLinear, Unnormalized

ASSUME W \in 2..8 /\ IdMax \in 0..(2^(W - 1) - 2) /\ N \in 0..8

Word == 2^W
Max == Word - 1                       \* 0xffffffff, the search area's end
Wrap(x) == ((x % Word) + Word) % Word \* an i32 result, mod 2^W
Signed(x) == IF x >= Word \div 2 THEN x - Word ELSE x
MissArm == 99                         \* the arm miss() records (match(k) records k)
DoneL == 1                            \* block `done`
FailL == 2                            \* block `fail`

\* ---- the inputs ----
Rg == {r \in (0..IdMax) \X (0..IdMax) : r[1] <= r[2]}
\* the premise: sorted, disjoint (adjacent allowed), each start <= end, up to k ranges all starting at lo or later
RECURSIVE Sorted(_, _)
Sorted(lo, k) == {<<>>} \cup
    (IF k = 0 THEN {}
     ELSE UNION {UNION {{<<<<s, e>>>> \o t : t \in Sorted(e + 1, k - 1)} : e \in s..IdMax} : s \in lo..IdMax})
\* a caller that skips normalize: any list of ranges, unsorted or overlapping
AnyLists == UNION {[1..j -> Rg] : j \in 0..N}
Inputs == IF Unnormalized THEN AnyLists ELSE Sorted(0, N)
Covered(rs) == UNION {rs[i][1]..rs[i][2] : i \in DOMAIN rs}

\* ---- the emitted instructions ----
I(op) == [op |-> op, x |-> 0, y |-> 0, z |-> 0]
Const(c) == [op |-> "const", x |-> c, y |-> 0, z |-> 0]
Block(l) == [op |-> "block", x |-> l, y |-> 0, z |-> 0]
Br(l) == [op |-> "br", x |-> l, y |-> 0, z |-> 0]
Match(k) == [op |-> "match", x |-> k, y |-> 0, z |-> 0]
Leaf(k, lo, hi) == [op |-> "leaf", x |-> k, y |-> lo, z |-> hi]
Length(r) == 1 + (r[2] - r[1])
\* the miss tail: miss(); br(done), else unreachable()
MissTail(m) == IF m THEN <<I("miss"), Br(DoneL)>> ELSE <<I("unreachable")>>

\* _linear_class_id_search: each range's test, an if holding match(value); br(done)
LinTest(r) == <<I("get"), Const(r[1])>> \o
    (IF Length(r) = 1 THEN <<I("eq")>>
     ELSE <<I("sub"), Const(Length(r)), I(IF SignedLinear THEN "lt_s" ELSE "lt_u")>>)
RECURSIVE LinArms(_, _)
LinArms(rs, k) == IF k = Len(rs) THEN <<>>
                  ELSE LinTest(rs[k + 1]) \o <<I("if"), Match(k), Br(DoneL), I("end")>> \o LinArms(rs, k + 1)
Linear(rs, m) == [ok |-> TRUE,
                  code |-> <<I("set"), Block(DoneL)>> \o LinArms(rs, 0) \o MissTail(m) \o <<I("end")>>]

\* _binary_class_id_search's leaf test, chosen by the area [lo, hi]
LeafTest(s, e, lo, hi) ==
    IF e = s THEN <<Const(s), I("eq")>>
    ELSE IF hi <= e THEN <<Const(s), I("ge_u")>>
    ELSE IF s <= lo THEN <<Const(e), I("le_u")>>
    ELSE <<Const(s), I("sub"), Const(e - s + 1), I("lt_u")>>
LeafCode(rs, m, k, lo, hi) ==
    LET s == rs[k + 1][1]  e == rs[k + 1][2] IN
    IF ~(lo <= s /\ e <= hi) THEN [ok |-> FALSE, code |-> <<>>]   \* contains_range(search_area, range) || reject!
    ELSE IF ~m \/ ElideWithMiss \/ (s <= lo /\ hi <= e)
         THEN [ok |-> TRUE, code |-> <<Leaf(k, lo, hi), Match(k), Br(DoneL)>>]
         ELSE [ok |-> TRUE, code |-> <<Leaf(k, lo, hi), I("get")>> \o LeafTest(s, e, lo, hi)
                                     \o <<I("if"), Match(k), Br(DoneL), I("end"), Br(FailL)>>]
\* search(left, right, search_area)
RECURSIVE Search(_, _, _, _, _, _)
Search(rs, m, l, r, lo, hi) ==
    IF l = r THEN LeafCode(rs, m, l, lo, hi)
    ELSE LET mid == (l + r) \div 2
             me == rs[mid + 1][2]
             L == Search(rs, m, l, mid, lo, me)
             R == Search(rs, m, mid + 1, r, me + 1, hi)
         IN [ok |-> L.ok /\ R.ok,
             code |-> <<I("get"), Const(me), I(IF SplitOffByOne THEN "lt_u" ELSE "le_u"), I("if")>>
                      \o L.code \o <<I("end")>> \o R.code]
Binary(rs, m) ==
    LET S == Search(rs, m, 0, Len(rs) - 1, 0, Max) IN
    [ok |-> S.ok,
     code |-> <<I("set"), Block(DoneL), Block(FailL)>> \o S.code \o <<I("end")>> \o MissTail(m) \o <<I("end")>>]

\* class_id_search, with each form's empty-range head
Emit(rs, m) ==
    IF rs = <<>> THEN IF m THEN [ok |-> TRUE, code |-> <<I("drop"), I("miss")>>]
                       ELSE [ok |-> FALSE, code |-> <<>>]   \* no range and no miss: reject!(Internal)
    ELSE IF Len(rs) <= 3 THEN Linear(rs, m) ELSE Binary(rs, m)

\* structured control: an if's or block's matching end, a br's target the end of its label's block
RECURSIVE Scan(_, _, _)
Scan(p, j, d) == IF p[j].op \in {"if", "block"} THEN Scan(p, j + 1, d + 1)
                 ELSE IF p[j].op = "end" THEN (IF d = 0 THEN j ELSE Scan(p, j + 1, d - 1))
                 ELSE Scan(p, j + 1, d)
EndOf(p, i) == Scan(p, i + 1, 0)
BlockOf(p, l) == CHOOSE i \in DOMAIN p : p[i].op = "block" /\ p[i].x = l
Targets(p) == [i \in DOMAIN p |->
                 CASE p[i].op \in {"if", "block"} -> EndOf(p, i) + 1
                   [] p[i].op = "br" -> EndOf(p, BlockOf(p, p[i].x)) + 1
                   [] OTHER -> 0]

\* ---- the execution ----
VARIABLES rs, m, id, prog, tgt, pc, stk, loc, hits, tests, phase
vars == <<rs, m, id, prog, tgt, pc, stk, loc, hits, tests, phase>>

Init == /\ rs \in Inputs
        /\ m \in BOOLEAN
        \* with no miss, the caller's premise: the id lies in a range
        /\ id \in IF m THEN 0..Max ELSE IF rs = <<>> THEN {0} ELSE Covered(rs)
        /\ prog = Emit(rs, m).code
        /\ tgt = Targets(prog)
        /\ pc = 1
        /\ stk = <<id>>
        /\ loc = 0
        /\ hits = <<>>
        /\ tests = 0
        /\ phase = IF Emit(rs, m).ok THEN "run" ELSE "reject"

Top == stk[Len(stk)]
Pop1 == SubSeq(stk, 1, Len(stk) - 1)
Pop2 == SubSeq(stk, 1, Len(stk) - 2)
A == stk[Len(stk) - 1]   \* the first operand of a binary instruction
B == Top                 \* the second
Bool(c) == IF c THEN 1 ELSE 0
Go(s) == /\ stk' = s /\ pc' = pc + 1
         /\ UNCHANGED <<rs, m, id, prog, tgt, loc, hits, tests, phase>>
BinOp(v) == Go(Append(Pop2, v))

Step ==
  /\ phase = "run"
  /\ IF pc > Len(prog) THEN /\ phase' = "done"
                            /\ UNCHANGED <<rs, m, id, prog, tgt, pc, stk, loc, hits, tests>>
     ELSE LET ins == prog[pc] IN
       CASE ins.op = "set" -> /\ loc' = Top /\ stk' = Pop1 /\ pc' = pc + 1
                              /\ UNCHANGED <<rs, m, id, prog, tgt, hits, tests, phase>>
         [] ins.op = "drop" -> Go(Pop1)
         [] ins.op = "get" -> Go(Append(stk, loc))
         [] ins.op = "const" -> Go(Append(stk, Wrap(ins.x)))
         [] ins.op = "eq" -> BinOp(Bool(A = B))
         [] ins.op = "ge_u" -> BinOp(Bool(A >= B))
         [] ins.op = "le_u" -> BinOp(Bool(A <= B))
         [] ins.op = "lt_u" -> BinOp(Bool(A < B))
         [] ins.op = "lt_s" -> BinOp(Bool(Signed(A) < Signed(B)))
         [] ins.op = "sub" -> BinOp(Wrap(A - B))
         [] ins.op = "if" -> /\ stk' = Pop1
                             /\ pc' = IF Top # 0 THEN pc + 1 ELSE tgt[pc]
                             /\ tests' = tests + 1
                             /\ UNCHANGED <<rs, m, id, prog, tgt, loc, hits, phase>>
         [] ins.op \in {"end", "block", "leaf"} -> Go(stk)
         [] ins.op = "br" -> /\ pc' = tgt[pc]
                             /\ UNCHANGED <<rs, m, id, prog, tgt, stk, loc, hits, tests, phase>>
         [] ins.op = "match" -> /\ hits' = Append(hits, ins.x) /\ pc' = pc + 1
                                /\ UNCHANGED <<rs, m, id, prog, tgt, stk, loc, tests, phase>>
         [] ins.op = "miss" -> /\ hits' = Append(hits, MissArm) /\ pc' = pc + 1
                               /\ UNCHANGED <<rs, m, id, prog, tgt, stk, loc, tests, phase>>
         [] ins.op = "unreachable" -> /\ phase' = "trap"
                                      /\ UNCHANGED <<rs, m, id, prog, tgt, pc, stk, loc, hits, tests>>
Stop == phase # "run" /\ UNCHANGED vars
Next == Step \/ Stop
Spec == Init /\ [][Next]_vars /\ WF_vars(Step)

Done == phase # "run"

Ops == {"set", "drop", "get", "const", "eq", "ge_u", "le_u", "lt_u", "lt_s", "sub", "if", "end", "block", "leaf",
        "br", "match", "miss", "unreachable"}
TypeOK == /\ rs \in Seq(Rg) /\ Len(rs) <= N
          /\ m \in BOOLEAN
          /\ id \in 0..Max
          /\ prog \in Seq([op : Ops, x : Int, y : Int, z : Int])
          /\ tgt \in [DOMAIN prog -> Nat]
          /\ pc \in 1..(Len(prog) + 1)
          /\ stk \in Seq(0..Max)
          /\ loc \in 0..Max
          /\ hits \in Seq((0..(N - 1)) \cup {MissArm})
          /\ tests \in Nat
          /\ phase \in {"run", "done", "trap", "reject"}

\* ceil(log2 n)
RECURSIVE CeilLog2(_)
CeilLog2(n) == IF n <= 1 THEN 0 ELSE 1 + CeilLog2((n + 1) \div 2)
DepthBound(n) == IF n <= 3 THEN n ELSE CeilLog2(n) + 1

Routes == (Done /\ phase # "reject") =>
            \A k \in 0..(Len(rs) - 1) : id \in rs[k + 1][1]..rs[k + 1][2] => (phase = "done" /\ hits = <<k>>)
Misses == (Done /\ phase # "reject" /\ m /\ id \notin Covered(rs)) => (phase = "done" /\ hits = <<MissArm>>)
AreaSound == /\ phase = "reject" => (rs = <<>> /\ ~m)
             /\ (phase = "run" /\ pc <= Len(prog) /\ prog[pc].op = "leaf") => id \in prog[pc].y..prog[pc].z
Depth == tests <= DepthBound(Len(rs))
Ends == <>Done
=============================================================================
