---------------------------- MODULE OperandStack ----------------------------
(***************************************************************************)
(* A TLA+ model of the builder's operand-stack and control-frame check:    *)
(* WT's validator (src/builder/validator.jl: validate_push!/_pop!,         *)
(* validate_block_start!/_end!, validate_if_start!, validate_else!,        *)
(* validate_br!, the reachability flag) set against the WebAssembly        *)
(* specification's own validation algorithm (spec appendix "Validation     *)
(* Algorithm": vals, ctrls, push_ctrl/pop_ctrl, unreachable).              *)
(*                                                                         *)
(* WHAT THE REAL CODE DOES. Like dart2wasm's InstructionsBuilder           *)
(* (_verifyTypes returns early when !_reachable), WT checks types only in  *)
(* reachable code: after `unreachable` or `br` its pops answer the expected *)
(* type and a block's end skips its checks, restoring the stack to the     *)
(* block's entry height plus its results. The spec keeps checking dead     *)
(* code (its stack is bottomless only below the frame's height), so wasm-  *)
(* tools validation of every emitted module is the alarm there (C7).       *)
(* Every type check is by subtyping (wasm_subtype), here Sub.              *)
(*                                                                         *)
(* IF AND ELSE. `if [ins]->[res]` pops an i32 and its inputs, and opens a  *)
(* frame whose arms start from the inputs; `else` checks the then arm      *)
(* against the results and restarts from the inputs. The spec reads an     *)
(* `if` with no `else` as one with an EMPTY else (binary format:           *)
(* `if bt in* end` is `if bt in* else end`), modeled as such: the implicit *)
(* else frame pops the results from the pushed inputs, so it is valid iff  *)
(* Len(ins) = Len(res) and each ins[k] is a subtype of res[k]. WT's        *)
(* validate_block_end! states that rule for an else-less `if`: equal       *)
(* length plus wasm_subtype(in, out) per position -- the FIXED rule        *)
(* (batch 107, A3B11), checked whether or not the end is reachable, as     *)
(* the spec checks it. ElseLessExact = TRUE is batch 66's rule instead,    *)
(* `label.input_types != label.result_types`: it rejects the valid         *)
(* `const sub; const i32; if [sub]->[super] end; drop`.                    *)
(*                                                                         *)
(* THE CLAIM. Complete: WT accepts every program the spec accepts. Sound   *)
(* where reachable: a program WT accepts and that has no instruction in    *)
(* dead code, the spec accepts. The Broken variants: DropBlockResults      *)
(* drops a block's (and an if's) declared result types from the tracker -- *)
(* the bug _blocktype_results fixed (a positional value blocktype reached  *)
(* the bytes but not the tracker, so every `if_!(b, I32)` value was lost   *)
(* at its end); ElseLessExact is batch 66's equality rule.                 *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Four value types, i32, i64 and the pair      *)
(* "sub" <: "super" (a reference type and its supertype); the instructions *)
(* that exercise the stack discipline: a constant, drop, a binary          *)
(* operator, block with zero or one result, if with a block type of at     *)
(* most one param and one result over {sub, super} (IfBlockTypes), else,   *)
(* end, br to depth 0 or 1, unreachable. Each instance picks its           *)
(* instruction set (Instrs, from CoreInstrs and IfInstrs) and checks every *)
(* program of it up to MaxLen instructions, inside one function frame with *)
(* no results.                                                             *)
(*                                                                         *)
(* formal(src/builder/validator.jl validate_block_end!): the builder's     *)
(* check agrees with the spec's algorithm on every program whose           *)
(* instructions are reachable, and never rejects a valid one.              *)
(*                                                                         *)
(* parity(pkg/wasm_builder/lib/src/builder/instructions.dart:494           *)
(* InstructionsBuilder._verifyTypes).                                      *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxLen,
          DropBlockResults,  \* TRUE = the broken tracker
          ElseLessExact,     \* TRUE = batch 66's else-less if rule (input_types != result_types)
          Instrs             \* the instance's instruction set (CoreInstrs, IfInstrs below)

Types == {"i32", "i64", "sub", "super"}
\* the subtype relation (wasm_subtype): reflexive, plus "sub" <: "super"
Sub(a, b) == a = b \/ (a = "sub" /\ b = "super")
Unknown == "unknown"

\* the instructions of the first model: i32/i64 only, blocks without params
CoreInstrs ==
    {[op |-> "const", t |-> t] : t \in {"i32", "i64"}} \cup
    {[op |-> "add", t |-> t] : t \in {"i32", "i64"}} \cup
    {[op |-> "drop"], [op |-> "end"], [op |-> "unreachable"]} \cup
    {[op |-> "block", res |-> r] : r \in {<<>>, <<"i32">>}} \cup
    {[op |-> "br", d |-> d] : d \in {0, 1}}
\* if/else over the subtype pair: a const of "sub", else, and if with five block types:
\* []->[], []->[super] (unequal lengths), [sub]->[sub] (equal), [sub]->[super] (a strict
\* subtype), [super]->[sub] (not a subtype)
IfBlockTypes == {<<<<>>, <<>>>>, <<<<>>, <<"super">>>>, <<<<"sub">>, <<"sub">>>>,
                 <<<<"sub">>, <<"super">>>>, <<<<"super">>, <<"sub">>>>}
IfInstrs ==
    {[op |-> "const", t |-> "sub"], [op |-> "else"]} \cup
    {[op |-> "if", ins |-> bt[1], res |-> bt[2]] : bt \in IfBlockTypes}

\* ---------------- the specification's validation algorithm ----------------
\* frame: [op, start, out, height, unreachable]; state: [vals, ctrls, err, dead]

SPopVal(s) ==   \* returns [s |-> state, v |-> value]
    LET top == s.ctrls[Len(s.ctrls)] IN
    IF Len(s.vals) = top.height /\ top.unreachable THEN [s |-> s, v |-> Unknown]
    ELSE IF Len(s.vals) = top.height THEN [s |-> [s EXCEPT !.err = TRUE], v |-> Unknown]
    ELSE [s |-> [s EXCEPT !.vals = SubSeq(s.vals, 1, Len(s.vals) - 1)], v |-> s.vals[Len(s.vals)]]

SPopExpect(s, t) ==
    LET r == SPopVal(s) IN
    IF r.v # Unknown /\ ~Sub(r.v, t) THEN [r.s EXCEPT !.err = TRUE] ELSE r.s

RECURSIVE SPopVals(_, _)
SPopVals(s, ts) == IF ts = <<>> THEN s
                   ELSE SPopVals(SPopExpect(s, ts[Len(ts)]), SubSeq(ts, 1, Len(ts) - 1))

SUnreachable(s) ==
    LET top == s.ctrls[Len(s.ctrls)] IN
    [s EXCEPT !.vals = SubSeq(s.vals, 1, top.height),
              !.ctrls[Len(s.ctrls)].unreachable = TRUE]

\* push_ctrl(opcode, in, out): the frame's height is below its inputs, which are pushed
SPushCtrl(s, op, in, out) ==
    [s EXCEPT !.ctrls = Append(s.ctrls, [op |-> op, start |-> in, out |-> out,
                                         height |-> Len(s.vals), unreachable |-> FALSE]),
              !.vals = s.vals \o in]

SPopCtrl(s) ==   \* returns [s, frame]
    LET top == s.ctrls[Len(s.ctrls)]
        s1 == SPopVals(s, top.out)
        s2 == IF Len(s1.vals) # top.height THEN [s1 EXCEPT !.err = TRUE] ELSE s1
    IN [s |-> [s2 EXCEPT !.ctrls = SubSeq(s2.ctrls, 1, Len(s2.ctrls) - 1)], f |-> top]

SStep(s, i) ==
    LET s0 == IF s.ctrls[Len(s.ctrls)].unreachable /\ i.op \notin {"end", "else"}
              THEN [s EXCEPT !.dead = TRUE] ELSE s IN
    CASE i.op = "const" -> [s0 EXCEPT !.vals = Append(s0.vals, i.t)]
      [] i.op = "drop"  -> SPopVal(s0).s
      [] i.op = "add"   -> LET s1 == SPopExpect(SPopExpect(s0, i.t), i.t) IN
                           [s1 EXCEPT !.vals = Append(s1.vals, i.t)]
      [] i.op = "block" -> SPushCtrl(s0, "block", <<>>, i.res)
      [] i.op = "if"    -> SPushCtrl(SPopVals(SPopExpect(s0, "i32"), i.ins), "if", i.ins, i.res)
      [] i.op = "else"  -> IF s0.ctrls[Len(s0.ctrls)].op # "if" THEN [s0 EXCEPT !.err = TRUE]
                           ELSE LET r == SPopCtrl(s0) IN SPushCtrl(r.s, "else", r.f.start, r.f.out)
      [] i.op = "end"   -> IF Len(s0.ctrls) = 1 THEN [s0 EXCEPT !.err = TRUE]   \* no open block
                           ELSE LET r == SPopCtrl(s0)
                                    \* an if with no else ends through its implicit empty else
                                    r2 == IF r.f.op = "if"
                                          THEN SPopCtrl(SPushCtrl(r.s, "else", r.f.start, r.f.out)).s
                                          ELSE r.s
                                IN [r2 EXCEPT !.vals = r2.vals \o r.f.out]
      [] i.op = "br"    -> IF i.d >= Len(s0.ctrls) - 1 THEN [s0 EXCEPT !.err = TRUE]
                           ELSE SUnreachable(SPopVals(s0, s0.ctrls[Len(s0.ctrls) - i.d].out))
      [] i.op = "unreachable" -> SUnreachable(s0)

\* ---------------- WT's validator (validator.jl) ----------------
\* label: [kind, ins, results, height, reach, hasElse]; state: [stack, labels, reachable, err]

Base(w) == IF Len(w.labels) = 0 THEN 0 ELSE w.labels[Len(w.labels)].height
Min(a, b) == IF a <= b THEN a ELSE b

WPop(w, t) ==   \* t = Unknown pops any type
    IF ~w.reachable THEN w
    ELSE IF Len(w.stack) <= Base(w) THEN [w EXCEPT !.err = TRUE]
    ELSE [w EXCEPT !.stack = SubSeq(w.stack, 1, Len(w.stack) - 1),
                   !.err = w.err \/ (t # Unknown /\ ~Sub(w.stack[Len(w.stack)], t))]

RECURSIVE WPopSeq(_, _)   \* validate_if_start!'s `for t in reverse(input_types)`
WPopSeq(w, ts) == IF ts = <<>> THEN w
                  ELSE WPopSeq(WPop(w, ts[Len(ts)]), SubSeq(ts, 1, Len(ts) - 1))

\* the arm (or block) ends with exactly its results above the label's height, by subtyping
ArmBad(w, l) == w.reachable /\
                (Len(w.stack) # l.height + Len(l.results) \/
                 \E k \in 1..Len(l.results) :
                     l.height + k <= Len(w.stack) /\ ~Sub(w.stack[l.height + k], l.results[k]))

\* validate_block_end!'s else-less if rule (checked whether or not the end is reachable)
ElseLessBad(l) ==
    l.kind = "if" /\ ~l.hasElse /\
    IF ElseLessExact
    THEN l.ins # l.results                                   \* batch 66: equality
    ELSE Len(l.ins) # Len(l.results) \/                      \* the fix: length, then
         \E k \in 1..Len(l.ins) : ~Sub(l.ins[k], l.results[k])   \* wasm_subtype per position

WStep(w, i) ==
    CASE i.op = "const" -> [w EXCEPT !.stack = Append(w.stack, i.t)]
      [] i.op = "drop"  -> WPop(w, Unknown)
      [] i.op = "add"   -> LET w1 == WPop(WPop(w, i.t), i.t) IN
                           [w1 EXCEPT !.stack = Append(w1.stack, i.t)]
      [] i.op = "block" -> [w EXCEPT !.labels = Append(w.labels,
                              [kind |-> "block", ins |-> <<>>,
                               results |-> IF DropBlockResults THEN <<>> ELSE i.res,
                               height |-> Len(w.stack), reach |-> w.reachable, hasElse |-> FALSE])]
      [] i.op = "if"    ->
            LET w1 == WPopSeq(WPop(w, "i32"), i.ins)
                st == w1.stack \o i.ins
            IN [w1 EXCEPT !.stack = st,
                          !.labels = Append(w1.labels,
                              [kind |-> "if", ins |-> i.ins,
                               results |-> IF DropBlockResults THEN <<>> ELSE i.res,
                               height |-> Len(st) - Len(i.ins), reach |-> w.reachable,
                               hasElse |-> FALSE])]
      [] i.op = "else"  ->
            IF Len(w.labels) = 0 THEN [w EXCEPT !.err = TRUE]
            ELSE LET l == w.labels[Len(w.labels)] IN
                 IF l.kind # "if" \/ l.hasElse THEN [w EXCEPT !.err = TRUE]
                 ELSE [w EXCEPT !.labels[Len(w.labels)].hasElse = TRUE,
                                !.stack = SubSeq(w.stack, 1, Min(l.height, Len(w.stack))) \o l.ins,
                                !.reachable = l.reach,
                                !.err = w.err \/ ArmBad(w, l)]
      [] i.op = "end"   ->
            IF Len(w.labels) = 0 THEN [w EXCEPT !.err = TRUE]
            ELSE LET l == w.labels[Len(w.labels)]
                     kept == SubSeq(w.stack, 1, Min(l.height, Len(w.stack)))
                 IN [w EXCEPT !.labels = SubSeq(w.labels, 1, Len(w.labels) - 1),
                              !.stack = kept \o l.results,
                              !.reachable = l.reach,
                              !.err = w.err \/ ElseLessBad(l) \/ ArmBad(w, l)]
      [] i.op = "br"    ->
            IF ~w.reachable THEN w
            ELSE IF i.d >= Len(w.labels) THEN [w EXCEPT !.err = TRUE, !.reachable = FALSE]
            ELSE LET l == w.labels[Len(w.labels) - i.d]
                     n == Len(l.results)
                     bad == Len(w.stack) - l.height < n \/
                            \E k \in 1..n : ~Sub(w.stack[Len(w.stack) - n + k], l.results[k])
                 IN [w EXCEPT !.err = w.err \/ bad, !.reachable = FALSE]
      [] i.op = "unreachable" -> [w EXCEPT !.reachable = FALSE]

\* ---------------- running a program to its function end ----------------
RECURSIVE SRun(_, _), WRun(_, _)
SRun(p, s) == IF p = <<>> THEN s ELSE SRun(Tail(p), SStep(s, Head(p)))
WRun(p, w) == IF p = <<>> THEN w ELSE WRun(Tail(p), WStep(w, Head(p)))

SInit == [vals |-> <<>>,
          ctrls |-> <<[op |-> "func", start |-> <<>>, out |-> <<>>, height |-> 0,
                       unreachable |-> FALSE]>>,
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

\* every program of at most MaxLen instructions; one function set per length, so TLC
\* enumerates each lazily (a UNION of them is materialized, capped at 10^6 elements)
Init == (\E n \in 0..MaxLen : prog \in [1..n -> Instrs]) /\ done = FALSE
Step == ~done /\ done' = TRUE /\ UNCHANGED prog
Terminal == done /\ UNCHANGED vars   \* the one step has run: the end of the run, not a deadlock
Spec == Init /\ [][Step \/ Terminal]_vars

Complete == done \in BOOLEAN /\ (SpecAccepts(prog) => WtAccepts(prog))
SoundWhereReachable == done \in BOOLEAN /\ ((WtAccepts(prog) /\ AllReachable(prog)) => SpecAccepts(prog))
=============================================================================
