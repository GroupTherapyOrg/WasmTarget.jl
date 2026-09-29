---------------------------- MODULE OperandStack ----------------------------
(***************************************************************************)
(* A TLA+ model of the builder's operand-stack and control-frame check:    *)
(* WT's validator (src/builder/validator.jl: validate_push!/_pop!,         *)
(* validate_block_start!/_end!, validate_br!, the reachability flag) set   *)
(* against the WebAssembly specification's own validation algorithm       *)
(* (spec appendix "Validation Algorithm": vals, ctrls, push_ctrl/pop_ctrl, *)
(* unreachable).                                                           *)
(*                                                                         *)
(* WHAT THE REAL CODE DOES. Like dart2wasm's InstructionsBuilder           *)
(* (_verifyTypes returns early when !_reachable), WT checks types only in  *)
(* reachable code: after `unreachable` or `br` its pops answer the expected *)
(* type and a block's end skips its checks, restoring the stack to the     *)
(* block's entry height plus its results. The spec keeps checking dead     *)
(* code (its stack is bottomless only below the frame's height), so wasm-  *)
(* tools validation of every emitted module is the alarm there (C7).       *)
(*                                                                         *)
(* THE CLAIM. Complete: WT accepts every program the spec accepts. Sound   *)
(* where reachable: a program WT accepts and that has no instruction in    *)
(* dead code, the spec accepts. The Broken variant drops a block's         *)
(* declared result types from the tracker -- the bug _blocktype_results    *)
(* fixed (a positional value blocktype reached the bytes but not the       *)
(* tracker, so every `if_!(b, I32)` value was lost at its end).            *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Two value types; the instructions that       *)
(* exercise the stack discipline: a constant, drop, a binary operator,     *)
(* block with zero or one result, end, br to depth 0 or 1, unreachable.    *)
(* Every program up to MaxLen instructions, inside one function frame      *)
(* with no results.                                                        *)
(*                                                                         *)
(* formal(src/builder/validator.jl validate_block_end!): the builder's     *)
(* check agrees with the spec's algorithm on every program whose           *)
(* instructions are reachable, and never rejects a valid one.              *)
(*                                                                         *)
(* parity(pkg/wasm_builder/lib/src/builder/instructions.dart:494           *)
(* InstructionsBuilder._verifyTypes).                                      *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxLen, DropBlockResults   \* DropBlockResults: TRUE = the broken tracker

Types == {"i32", "i64"}
Unknown == "unknown"
Instrs ==
    {[op |-> "const", t |-> t] : t \in Types} \cup
    {[op |-> "add", t |-> t] : t \in Types} \cup
    {[op |-> "drop"], [op |-> "end"], [op |-> "unreachable"]} \cup
    {[op |-> "block", res |-> r] : r \in {<<>>, <<"i32">>}} \cup
    {[op |-> "br", d |-> d] : d \in {0, 1}}

\* ---------------- the specification's validation algorithm ----------------
\* frame: [out, height, unreachable]; state: [vals, ctrls, err, dead]

SPopVal(s) ==   \* returns [s |-> state, v |-> value]
    LET top == s.ctrls[Len(s.ctrls)] IN
    IF Len(s.vals) = top.height /\ top.unreachable THEN [s |-> s, v |-> Unknown]
    ELSE IF Len(s.vals) = top.height THEN [s |-> [s EXCEPT !.err = TRUE], v |-> Unknown]
    ELSE [s |-> [s EXCEPT !.vals = SubSeq(s.vals, 1, Len(s.vals) - 1)], v |-> s.vals[Len(s.vals)]]

SPopExpect(s, t) ==
    LET r == SPopVal(s) IN
    IF r.v # Unknown /\ r.v # t THEN [r.s EXCEPT !.err = TRUE] ELSE r.s

RECURSIVE SPopVals(_, _)
SPopVals(s, ts) == IF ts = <<>> THEN s
                   ELSE SPopVals(SPopExpect(s, ts[Len(ts)]), SubSeq(ts, 1, Len(ts) - 1))

SUnreachable(s) ==
    LET top == s.ctrls[Len(s.ctrls)] IN
    [s EXCEPT !.vals = SubSeq(s.vals, 1, top.height),
              !.ctrls[Len(s.ctrls)].unreachable = TRUE]

SPopCtrl(s) ==   \* returns [s, frame]
    LET top == s.ctrls[Len(s.ctrls)]
        s1 == SPopVals(s, top.out)
        s2 == IF Len(s1.vals) # top.height THEN [s1 EXCEPT !.err = TRUE] ELSE s1
    IN [s |-> [s2 EXCEPT !.ctrls = SubSeq(s2.ctrls, 1, Len(s2.ctrls) - 1)], f |-> top]

SStep(s, i) ==
    LET s0 == IF s.ctrls[Len(s.ctrls)].unreachable /\ i.op # "end"
              THEN [s EXCEPT !.dead = TRUE] ELSE s IN
    CASE i.op = "const" -> [s0 EXCEPT !.vals = Append(s0.vals, i.t)]
      [] i.op = "drop"  -> SPopVal(s0).s
      [] i.op = "add"   -> LET s1 == SPopExpect(SPopExpect(s0, i.t), i.t) IN
                           [s1 EXCEPT !.vals = Append(s1.vals, i.t)]
      [] i.op = "block" -> [s0 EXCEPT !.ctrls = Append(s0.ctrls,
                              [out |-> i.res, height |-> Len(s0.vals), unreachable |-> FALSE])]
      [] i.op = "end"   -> IF Len(s0.ctrls) = 1 THEN [s0 EXCEPT !.err = TRUE]   \* no open block
                           ELSE LET r == SPopCtrl(s0) IN
                                [r.s EXCEPT !.vals = r.s.vals \o r.f.out]
      [] i.op = "br"    -> IF i.d >= Len(s0.ctrls) - 1 THEN [s0 EXCEPT !.err = TRUE]
                           ELSE SUnreachable(SPopVals(s0, s0.ctrls[Len(s0.ctrls) - i.d].out))
      [] i.op = "unreachable" -> SUnreachable(s0)

\* ---------------- WT's validator (validator.jl) ----------------
\* label: [results, height, reach]; state: [stack, labels, reachable, err]

Base(w) == IF Len(w.labels) = 0 THEN 0 ELSE w.labels[Len(w.labels)].height

WPop(w, t) ==   \* t = Unknown pops any type
    IF ~w.reachable THEN w
    ELSE IF Len(w.stack) <= Base(w) THEN [w EXCEPT !.err = TRUE]
    ELSE [w EXCEPT !.stack = SubSeq(w.stack, 1, Len(w.stack) - 1),
                   !.err = w.err \/ (t # Unknown /\ w.stack[Len(w.stack)] # t)]

WStep(w, i) ==
    CASE i.op = "const" -> [w EXCEPT !.stack = Append(w.stack, i.t)]
      [] i.op = "drop"  -> WPop(w, Unknown)
      [] i.op = "add"   -> LET w1 == WPop(WPop(w, i.t), i.t) IN
                           [w1 EXCEPT !.stack = Append(w1.stack, i.t)]
      [] i.op = "block" -> [w EXCEPT !.labels = Append(w.labels,
                              [results |-> IF DropBlockResults THEN <<>> ELSE i.res,
                               height |-> Len(w.stack), reach |-> w.reachable])]
      [] i.op = "end"   ->
            IF Len(w.labels) = 0 THEN [w EXCEPT !.err = TRUE]
            ELSE LET l == w.labels[Len(w.labels)]
                     bad == w.reachable /\
                            (Len(w.stack) # l.height + Len(l.results) \/
                             \E k \in 1..Len(l.results) :
                                 l.height + k <= Len(w.stack) /\ w.stack[l.height + k] # l.results[k])
                     kept == SubSeq(w.stack, 1, IF l.height <= Len(w.stack) THEN l.height ELSE Len(w.stack))
                 IN [w EXCEPT !.labels = SubSeq(w.labels, 1, Len(w.labels) - 1),
                              !.stack = kept \o l.results,
                              !.reachable = l.reach,
                              !.err = w.err \/ bad]
      [] i.op = "br"    ->
            IF ~w.reachable THEN w
            ELSE IF i.d >= Len(w.labels) THEN [w EXCEPT !.err = TRUE, !.reachable = FALSE]
            ELSE LET l == w.labels[Len(w.labels) - i.d]
                     n == Len(l.results)
                     bad == Len(w.stack) - l.height < n \/
                            \E k \in 1..n : w.stack[Len(w.stack) - n + k] # l.results[k]
                 IN [w EXCEPT !.err = w.err \/ bad, !.reachable = FALSE]
      [] i.op = "unreachable" -> [w EXCEPT !.reachable = FALSE]

\* ---------------- running a program to its function end ----------------
RECURSIVE SRun(_, _), WRun(_, _)
SRun(p, s) == IF p = <<>> THEN s ELSE SRun(Tail(p), SStep(s, Head(p)))
WRun(p, w) == IF p = <<>> THEN w ELSE WRun(Tail(p), WStep(w, Head(p)))

SInit == [vals |-> <<>>, ctrls |-> <<[out |-> <<>>, height |-> 0, unreachable |-> FALSE]>>,
          err |-> FALSE, dead |-> FALSE]
WInit == [stack |-> <<>>, labels |-> <<>>, reachable |-> TRUE, err |-> FALSE]

\* the function's own end: every block closed, the frame's results (none) on the stack
SpecAccepts(p) == LET s == SRun(p, SInit) IN
    ~s.err /\ Len(s.ctrls) = 1 /\ ~SPopCtrl(s).s.err
WtAccepts(p) == LET w == WRun(p, WInit) IN
    ~w.err /\ Len(w.labels) = 0 /\ (~w.reachable \/ Len(w.stack) = 0)
AllReachable(p) == ~SRun(p, SInit).dead

VARIABLES prog, done
vars == <<prog, done>>

Programs == UNION {[1..n -> Instrs] : n \in 0..MaxLen}
Init == prog \in Programs /\ done = FALSE
Step == ~done /\ done' = TRUE /\ UNCHANGED prog
Spec == Init /\ [][Step]_vars

Complete == done \in BOOLEAN /\ (SpecAccepts(prog) => WtAccepts(prog))
SoundWhereReachable == done \in BOOLEAN /\ ((WtAccepts(prog) /\ AllReachable(prog)) => SpecAccepts(prog))
=============================================================================
