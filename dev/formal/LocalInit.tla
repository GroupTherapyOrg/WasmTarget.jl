---------------------------- MODULE LocalInit ----------------------------
(***************************************************************************)
(* A TLA+ model of the builder's local-initialization check: dart2wasm's   *)
(* rule (_localInitialized, _localInitializationStack, a label's recorded  *)
(* stack height, _resetLocalInitialization at end, else and catch), WT's   *)
(* fragment builders merged by append_builder!'s replay, and the           *)
(* WebAssembly specification's rule they are checked against.              *)
(*                                                                         *)
(* THE SPEC'S RULE. A local whose type is not defaultable (a non-null      *)
(* reference) starts unset; parameters and defaultable locals start set.   *)
(* `local.set x` / `local.tee x` set x for the rest of the instruction     *)
(* sequence; `local.get x` of an unset x is invalid, reachable or not      *)
(* (an instruction type t1* ->x* t2* may claim only locals the context     *)
(* already has set). A structured instruction (block, loop, if, try) types *)
(* as t1* -> t2* with no locals set: each arm (the then and else arms, the *)
(* try body and each catch) is checked under the context at the            *)
(* instruction, and the sequence after its end continues under that same   *)
(* context. Written below as the typing rules read (SeqValid, ArmsValid),  *)
(* not as a machine.                                                       *)
(*                                                                         *)
(* DART'S RULE (instructions.dart). A parameter's flag is set (I:378), a   *)
(* local's flag is `type.defaultable` (I:389; a reference is defaultable   *)
(* iff nullable, ir/type.dart:233); local_set and local_tee set            *)
(* an unset flag and push the local on the initialization stack (I:393);   *)
(* local_get asserts the flag, reachable or not (I:1018-1030); _pushLabel  *)
(* records the stack's height in the label (I:701); _verifyEndOfBlock pops *)
(* the stack to that height, clearing each popped flag (I:405, :588), at   *)
(* end (I:842), else (I:767) and catch_legacy (I:799). A local is pushed   *)
(* only when its flag was unset, so popping to the label's height restores *)
(* exactly the flags of the label's entry: dart's rule is the spec's on    *)
(* this alphabet, with no conservatism. (Dart checks it in asserts, so its *)
(* release builds do not check at all; WT checks always.)                  *)
(*                                                                         *)
(* WT'S FRAGMENTS. WT emits a function through fragment builders that      *)
(* append_builder! merges into a destination (the function's top builder   *)
(* or another fragment) whose initialization state the fragment did not    *)
(* see. Every builder runs dart's rule on its own flags, stack and labels, *)
(* starting from the parameters and defaultable locals (the function's one *)
(* locals vector). A fragment records, in order:                           *)
(*   <<"req", x>>  a local_get of a non-defaultable x unset in it, where   *)
(*                 the top builder rejects;                                *)
(*   <<"init", x>> a local_set/tee that sets x at the fragment's outer     *)
(*                 level (a set inside a nested block is scoped by that    *)
(*                 block, reset at its end, and not recorded).             *)
(* append_builder! (the fragment balanced: no open label) replays the      *)
(* records in order against the destination at its current label, through  *)
(* the destination's own rules: a requirement is the destination's         *)
(* local_get (the top builder rejects an unset local; a fragment           *)
(* destination records it in turn), an initialization the destination's    *)
(* local_set (pushed on its stack, so its current label's end resets it).  *)
(* The interleaving of Open, emit and Append below builds every nesting of *)
(* balanced fragments over a program: a fragment's records depend only on  *)
(* its own instructions, so the order in which independent fragments are   *)
(* built does not matter, only the order in which they are appended.       *)
(*                                                                         *)
(* THE CLAIMS. Agrees: on every program of at most MaxLen instructions,    *)
(* when every block is closed, dart's one builder rejects exactly when the *)
(* spec does (no program the engine rejects is accepted, and no program    *)
(* the spec accepts is rejected: dart's rule here is exact). MergeAgrees:  *)
(* every split of that program into nested balanced fragments, replayed,   *)
(* has the one builder's verdict. The Broken variants: NoResetAtEnd (an    *)
(* initialization survives its block's end), MergeIgnoresRequires (the     *)
(* replay drops the requirements), MergeAppliesNestedSets (a fragment      *)
(* records a set inside a nested block as initializing its destination).   *)
(* ReplayRejectsInFragment rejects an unmet requirement at every append,   *)
(* into a fragment destination too, where the destination's own local_get  *)
(* records it: it rejects the valid `local.set n` followed by a fragment G *)
(* holding a fragment F that reads n, since G has not set n.               *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Two locals: "d", defaultable (a number or a  *)
(* nullable reference), and "n", not (a non-null reference). Operand types *)
(* and the operand stack are OperandStack's; here every instruction is     *)
(* only its effect on initialization. local.tee is local.set; loop is      *)
(* block (both push a label and reset at its end); catch stands for every  *)
(* legacy catch clause (dart has no catch_all_legacy). Programs are well   *)
(* nested (else once per if, catch only in a try), closed within MaxLen.   *)
(*                                                                         *)
(* formal(src/builder/instr_builder.jl local_get!, append_builder!): the   *)
(* builder's local-initialization verdict is the spec's, and a function    *)
(* built from fragments has the verdict of one builder.                    *)
(*                                                                         *)
(* parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1018          *)
(* InstructionsBuilder.local_get).                                         *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS MaxLen,                  \* the longest program checked
          MaxFrags,                \* the most fragments open at once
          NoResetAtEnd,            \* TRUE = end keeps the block's initializations
          MergeIgnoresRequires,    \* TRUE = the replay drops a fragment's requirements
          MergeAppliesNestedSets,  \* TRUE = a fragment records sets inside nested blocks
          ReplayRejectsInFragment  \* TRUE = an unmet requirement rejects at every append

Locals == {"d", "n"}
Defaultable == {"d"}
Openers == {"block", "if", "try"}
Terminators == {"else", "catch", "end"}
None == "-"
Ops == {[op |-> o, x |-> x] : o \in {"get", "set"}, x \in Locals} \cup
       {[op |-> o, x |-> None] : o \in Openers \cup Terminators}

\* ---------------- the specification's rule ----------------
\* (each is applied to a program whose blocks are all closed)

RECURSIVE ArmEnd(_, _, _)
\* the terminator (else, catch or end) of the arm starting at i: the first one at depth 0
ArmEnd(p, i, d) ==
    IF p[i].op \in Terminators /\ d = 0 THEN i
    ELSE ArmEnd(p, i + 1, IF p[i].op \in Openers THEN d + 1
                          ELSE IF p[i].op = "end" THEN d - 1 ELSE d)

RECURSIVE BlockEnd(_, _)
\* the end of the structured instruction whose first arm starts at i
BlockEnd(p, i) == LET t == ArmEnd(p, i, 0) IN IF p[t].op = "end" THEN t ELSE BlockEnd(p, t + 1)

RECURSIVE SeqValid(_, _, _), ArmsValid(_, _, _)
\* the instruction sequence from i to its frame's terminator (or the body's end), under the
\* set S of set locals: a get needs its local set; a set sets it for the rest of the sequence;
\* a structured instruction checks its arms under S and the sequence continues under S
SeqValid(p, i, S) ==
    IF i > Len(p) THEN TRUE
    ELSE IF p[i].op \in Terminators THEN TRUE
    ELSE IF p[i].op = "get" THEN p[i].x \in S /\ SeqValid(p, i + 1, S)
    ELSE IF p[i].op = "set" THEN SeqValid(p, i + 1, S \cup {p[i].x})
    ELSE ArmsValid(p, i + 1, S) /\ SeqValid(p, BlockEnd(p, i + 1) + 1, S)
\* every arm of a structured instruction, each from the instruction's own context S
ArmsValid(p, i, S) ==
    SeqValid(p, i, S) /\ (LET t == ArmEnd(p, i, 0) IN p[t].op # "end" => ArmsValid(p, t + 1, S))

\* a function body: the parameters and defaultable locals set
SpecValid(p) == SeqValid(p, 1, Defaultable)

\* ---------------- dart's rule, one builder (and every fragment's own) ----------------
\* ini: the locals whose flag is set (_localInitialized); stk: _localInitializationStack;
\* hts: the open labels' localInitializationStackHeight; log: a fragment's records

NewBuilder == [ini |-> Defaultable, stk |-> <<>>, hts |-> <<>>, log |-> <<>>]

RECURSIVE ResetTo(_, _)
\* _resetLocalInitialization (I:405): pop to height h, clearing each popped local's flag
ResetTo(b, h) ==
    IF Len(b.stk) <= h THEN b
    ELSE ResetTo([b EXCEPT !.ini = @ \ {b.stk[Len(b.stk)]},
                           !.stk = SubSeq(@, 1, Len(@) - 1)], h)

\* local_get (I:1018-1030): the top builder rejects an unset local; a fragment records it
Get(b, x, top) ==
    IF x \in b.ini THEN [b |-> b, rej |-> FALSE]
    ELSE IF top THEN [b |-> b, rej |-> TRUE]
    ELSE [b |-> [b EXCEPT !.log = Append(@, <<"req", x>>)], rej |-> FALSE]

\* local_set / local_tee (_initializeLocal, I:393); a fragment records a set at its outer level
Set(b, x, top) ==
    IF x \in b.ini THEN b
    ELSE [b EXCEPT !.ini = @ \cup {x}, !.stk = Append(@, x),
                   !.log = IF ~top /\ (Len(b.hts) = 0 \/ MergeAppliesNestedSets)
                           THEN Append(@, <<"init", x>>) ELSE @]

\* _pushLabel (I:701), else and catch_legacy (I:767, :799), end (I:842)
Push(b) == [b EXCEPT !.hts = Append(@, Len(b.stk))]
Mid(b) == ResetTo(b, b.hts[Len(b.hts)])
Close(b) == LET r == IF NoResetAtEnd THEN b ELSE ResetTo(b, b.hts[Len(b.hts)])
            IN [r EXCEPT !.hts = SubSeq(@, 1, Len(@) - 1)]

Emit(b, o, top) ==   \* [b |-> the builder after o, rej |-> o rejected]
    CASE o.op = "get"       -> Get(b, o.x, top)
      [] o.op = "set"       -> [b |-> Set(b, o.x, top), rej |-> FALSE]
      [] o.op \in Openers   -> [b |-> Push(b), rej |-> FALSE]
      [] o.op = "end"       -> [b |-> Close(b), rej |-> FALSE]
      [] OTHER              -> [b |-> Mid(b), rej |-> FALSE]   \* else, catch

\* ---------------- append_builder!'s replay ----------------
RECURSIVE Replay(_, _, _, _)
\* the fragment's records, in order, through the destination d's own rules at its label;
\* top: d is the function's top builder
Replay(d, log, top, rej) ==
    IF log = <<>> THEN [b |-> d, rej |-> rej]
    ELSE LET e == Head(log)
             r == IF e[1] = "init" THEN [b |-> Set(d, e[2], top), rej |-> FALSE]
                  ELSE IF MergeIgnoresRequires THEN [b |-> d, rej |-> FALSE]
                  ELSE Get(d, e[2], top \/ ReplayRejectsInFragment)
         IN Replay(r.b, Tail(log), top, rej \/ r.rej)

\* ---------------- the system ----------------
\* prog: the program, in its final order; ctl: its open structured instructions (to generate
\* well-nested programs); one, oneRej: dart's one builder over all of prog; bs, bsRej: the
\* builders WT holds, bs[1] the function's top builder, the rest open fragments, innermost last

VARIABLES prog, ctl, one, oneRej, bs, bsRej
vars == <<prog, ctl, one, oneRej, bs, bsRej>>

Builders == [ini : SUBSET Locals, stk : Seq(Locals), hts : Seq(Nat),
             log : Seq({"req", "init"} \X Locals)]
TypeOK == /\ prog \in Seq(Ops) /\ Len(prog) <= MaxLen
          /\ ctl \in Seq([k : Openers, els : BOOLEAN])
          /\ one \in Builders /\ oneRej \in BOOLEAN
          /\ bs \in Seq(Builders) /\ 1 <= Len(bs) /\ Len(bs) <= MaxFrags + 1
          /\ bsRej \in BOOLEAN

Init == /\ prog = <<>> /\ ctl = <<>>
        /\ one = NewBuilder /\ oneRej = FALSE
        /\ bs = <<NewBuilder>> /\ bsRej = FALSE

Inner == bs[Len(bs)]
\* o may come next, in the innermost builder, and the program still closes within MaxLen
Allowed(o) ==
    LET room == MaxLen - Len(prog) - Len(ctl) IN   \* instructions left beyond the needed ends
    CASE o.op \in {"get", "set"} -> room >= 1
      [] o.op \in Openers        -> room >= 2
      [] o.op = "else"           -> room >= 1 /\ Len(Inner.hts) > 0
                                    /\ ctl[Len(ctl)].k = "if" /\ ~ctl[Len(ctl)].els
      [] o.op = "catch"          -> room >= 1 /\ Len(Inner.hts) > 0 /\ ctl[Len(ctl)].k = "try"
      [] o.op = "end"            -> Len(Inner.hts) > 0

Instr == \E o \in Ops :
    /\ Allowed(o)
    /\ LET r1 == Emit(one, o, TRUE)
           r2 == Emit(Inner, o, Len(bs) = 1)
       IN /\ prog' = Append(prog, o)
          /\ ctl' = CASE o.op \in Openers -> Append(ctl, [k |-> o.op, els |-> FALSE])
                      [] o.op = "else"    -> [ctl EXCEPT ![Len(ctl)].els = TRUE]
                      [] o.op = "end"     -> SubSeq(ctl, 1, Len(ctl) - 1)
                      [] OTHER            -> ctl
          /\ one' = r1.b /\ oneRej' = (oneRej \/ r1.rej)
          /\ bs' = [bs EXCEPT ![Len(bs)] = r2.b] /\ bsRej' = (bsRej \/ r2.rej)

\* a new fragment builder, filled next
Open == /\ Len(bs) <= MaxFrags /\ Len(prog) < MaxLen
        /\ bs' = Append(bs, NewBuilder)
        /\ UNCHANGED <<prog, ctl, one, oneRej, bsRej>>

\* append_builder!: the innermost fragment, balanced, replayed into the builder below it
AppendFrag == /\ Len(bs) >= 2 /\ Len(Inner.hts) = 0
              /\ LET n == Len(bs)
                     r == Replay(bs[n - 1], Inner.log, n - 1 = 1, FALSE)
                 IN /\ bs' = Append(SubSeq(bs, 1, n - 2), r.b)
                    /\ bsRej' = (bsRej \/ r.rej)
              /\ UNCHANGED <<prog, ctl, one, oneRej>>

Terminal == Len(prog) = MaxLen /\ Len(bs) = 1 /\ UNCHANGED vars   \* the end of the run
Next == Instr \/ Open \/ AppendFrag \/ Terminal
Spec == Init /\ [][Next]_vars

\* every block closed: dart's one builder rejects exactly when the spec does
Agrees == Len(ctl) = 0 => (oneRej = ~SpecValid(prog))
\* every block closed and every fragment appended: the split has the one builder's verdict
MergeAgrees == (Len(ctl) = 0 /\ Len(bs) = 1) => (bsRej = oneRej)
=============================================================================
