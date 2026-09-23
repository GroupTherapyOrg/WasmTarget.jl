------------------------------ MODULE BoxValueTypes ------------------------------
(***************************************************************************)
(* A TLA+ model of `f3_box_value_types` (src/codegen/box_capture.jl), the   *)
(* forward fixpoint that carries a `Core.Box`'s recovered contents type     *)
(* (BoxJoin.tla's `box_contents_type`) to the values derived from reading   *)
(* it: the `getfield(box, :contents)` reads, the Pi narrowings and phis     *)
(* over them, and arithmetic over those. allocate_ssa_locals! types those   *)
(* SSAs' locals by its answer, so a wrong answer stores a value of one type *)
(* in a local of another.                                                   *)
(* parity(quarantine: values read from a Julia `Core.Box` are inferred Any  *)
(* because `contents::Any` erased the captured variable's type; dart's      *)
(* visitor returns the ValueType it produced).                              *)
(*                                                                          *)
(* WHAT THE REAL FUNCTION DOES (read from source). `while changed`, one     *)
(* pass over the statements, skipping every SSA already in `out`:           *)
(*   box read -- out[i] = the box's contents type (seeded from BoxJoin).    *)
(*   pi       -- the narrowed SSA's type, when resolved.                    *)
(*   phi      -- every SSA operand resolved and the Union of THEIR types    *)
(*               one concrete type => that type. A phi operand that is not *)
(*               an SSA -- a literal -- is skipped (`v isa NirSSA ||        *)
(*               continue`) and contributes nothing to the join.            *)
(*   call     -- the result type Julia infers for the operands' types.      *)
(*                                                                          *)
(* THE CLAIM (Soundness): every SSA it types holds values of exactly that   *)
(* type on every execution.                                                 *)
(*                                                                          *)
(* WHAT IS ABSTRACTED. Types I (Int64), F (Float64); a box read whose       *)
(* contents type is correct (BoxJoin's claim, assumed here); literals; a    *)
(* 2-operand phi (operands may refer forward); a 2-operand `+` (backward    *)
(* operands) with Julia's promotion. Init chooses every program of N        *)
(* statements.                                                              *)
(*                                                                          *)
(* VARIANT LiteralsJoin: FALSE = the real code (literal phi operands        *)
(* skipped); TRUE = a literal operand's own type joins like an SSA's.       *)
(*                                                                          *)
(* FINDING (MCBoxValueTypesLiteralBroken.cfg, the real code): `%x = phi(    *)
(* %read, 0.5)` over an Int64 box read is typed Int64. Reproduced on the    *)
(* real function over WT's IR of `s = 0; g = () -> (s += 1); ...;           *)
(* x = n > 0 ? s : 0.5`: out[%17] = Int64 for `%17 = phi(%12, 0.5)`.        *)
(*                                                                          *)
(* formal(dev/formal/BoxValueTypes.tla): every SSA f3_box_value_types types *)
(* holds values of exactly that type on every execution.                    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS N, LiteralsJoin

ASSUME N \in Nat /\ N >= 1
ASSUME LiteralsJoin \in BOOLEAN

Idx == 1..N
Num == {"I", "F"}
Promote(x, y) == IF x = "I" /\ y = "I" THEN "I" ELSE "F"

Lits  == {[k |-> "lit", t |-> t] : t \in Num}
Reads == {[k |-> "read", t |-> t] : t \in Num}
Phis  == {[k |-> "phi", a |-> a, b |-> b] : a \in Idx, b \in Idx}
Adds(i) == {[k |-> "add", a |-> a, b |-> b] : a \in 1..(i - 1), b \in 1..(i - 1)}
StmtsAt(i) == Lits \cup Reads \cup {p \in Phis : p.a < p.b /\ i \notin {p.a, p.b}} \cup Adds(i)
Programs == {p \in [Idx -> UNION {StmtsAt(i) : i \in Idx}] : \A i \in Idx : p[i] \in StmtsAt(i)}

VARIABLES prog, out, idx, changed, done
vars == <<prog, out, idx, changed, done>>

\* ground truth: least fixpoint of the run-time type sets
RtStep(p, rt) == [i \in Idx |->
    CASE p[i].k \in {"lit", "read"} -> {p[i].t}
      [] p[i].k = "phi" -> rt[p[i].a] \cup rt[p[i].b]
      [] p[i].k = "add" -> {Promote(x, y) : x \in rt[p[i].a], y \in rt[p[i].b]}]
RECURSIVE RtFix(_, _)
RtFix(p, rt) == LET nxt == RtStep(p, rt) IN IF nxt = rt THEN rt ELSE RtFix(p, nxt)
RT == RtFix(prog, [i \in Idx |-> {}])

\* an operand's type as the analysis sees it: a literal is its own type, an SSA is out[] or unresolved
OpT(v) == IF prog[v].k = "lit" THEN prog[v].t ELSE IF v \in DOMAIN out THEN out[v] ELSE "none"
IsSSA(v) == prog[v].k # "lit"

Rule(i) ==
    LET s == prog[i] IN
    CASE s.k = "read" -> s.t
      [] s.k = "phi" ->
            LET ops  == {s.a, s.b}
                ssa  == {v \in ops : IsSSA(v)}
                join == {OpT(v) : v \in IF LiteralsJoin THEN ops ELSE ssa}
            IN IF ssa # {} /\ (\A v \in ssa : v \in DOMAIN out) /\ Cardinality(join) = 1
               THEN CHOOSE t \in join : TRUE ELSE "none"
      [] s.k = "add" ->
            IF OpT(s.a) \in Num /\ OpT(s.b) \in Num THEN Promote(OpT(s.a), OpT(s.b)) ELSE "none"
      [] OTHER -> "none"

Extend(f, i, t) == [j \in DOMAIN f \cup {i} |-> IF j = i THEN t ELSE f[j]]

Init == /\ prog \in Programs /\ out = <<>> /\ idx = 1 /\ changed = FALSE /\ done = FALSE

Visit ==
    /\ ~done /\ idx <= N
    /\ IF idx \notin DOMAIN out /\ prog[idx].k # "lit" /\ Rule(idx) # "none"
       THEN out' = Extend(out, idx, Rule(idx)) /\ changed' = TRUE
       ELSE UNCHANGED <<out, changed>>
    /\ idx' = idx + 1
    /\ UNCHANGED <<prog, done>>

EndPass ==
    /\ ~done /\ idx = N + 1
    /\ IF changed THEN idx' = 1 /\ changed' = FALSE /\ UNCHANGED done
                  ELSE done' = TRUE /\ UNCHANGED <<idx, changed>>
    /\ UNCHANGED <<prog, out>>

Stop == done /\ UNCHANGED vars

Next == Visit \/ EndPass \/ Stop
Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

TypeOK ==
    /\ prog \in Programs
    /\ DOMAIN out \subseteq Idx /\ \A i \in DOMAIN out : out[i] \in Num
    /\ idx \in 1..(N + 1) /\ changed \in BOOLEAN /\ done \in BOOLEAN

Soundness == done => \A i \in DOMAIN out : RT[i] \subseteq {out[i]}
Terminates == <>done
=============================================================================
