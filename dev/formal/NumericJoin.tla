------------------------------- MODULE NumericJoin -------------------------------
(***************************************************************************)
(* A TLA+ model of `propagate_numeric_value_types` (src/codegen/            *)
(* box_capture.jl), the analysis that recovers a concrete numeric type for   *)
(* SSA values Julia typed `Any` -- the accumulator a scalar-replaced         *)
(* `Core.Box` capture leaves behind:                                        *)
(*                                                                          *)
(*     %acc = phi(0::Int64, %add)::Any                                      *)
(*     %add = %acc + x::Any                                                 *)
(*                                                                          *)
(* Its answer becomes the Wasm type of the SSA's local (allocate_ssa_locals!,*)
(* context.jl) and, for calls, the SSA's type for every consumer. A wrong    *)
(* answer is a silent miscompile: a Float64 value stored in an i64 local.    *)
(* parity(quarantine: Julia leaves a scalar-replaced Core.Box accumulator     *)
(* typed Any; dart types a captured variable by its declared type,          *)
(* closures.dart:1579 translateTypeOfLocalVariable).                         *)
(*                                                                          *)
(* WHAT THE REAL FUNCTION DOES (read from source).                          *)
(*   pend = the SSAs Julia typed Any, in statement order. `_opT(v)` is v's    *)
(*   type: an SSA already in `out` reads out[v], any other SSA reads Julia's *)
(*   type, a literal reads its own type.                                    *)
(*   PROPAGATE: `while changed`, one pass over pend in statement order,     *)
(*   SKIPPING every SSA already in `out` (`haskey(out, i) && continue`):    *)
(*     phi  -- ts = the NUMERIC operand types; if ts is non-empty and       *)
(*             Union(ts) is one numeric type, out[i] = that type. An        *)
(*             operand that is not yet resolved simply does not count: the  *)
(*             OPTIMISTIC seed that breaks the acc <-> add cycle.           *)
(*     call -- every operand type numeric => out[i] = the return type Julia *)
(*             infers for those operand types (here: `+`'s promotion).      *)
(*   VERIFY: `while verifying`, drop any phi in `out` one of whose operands *)
(*   does not resolve numeric. Nothing else is re-checked and nothing that  *)
(*   was typed THROUGH a dropped phi is dropped.                            *)
(*                                                                          *)
(* THE CLAIM. For every SSA the analysis types, every value that can reach  *)
(* it at run time has exactly that type (Soundness); and the analysis       *)
(* terminates.                                                              *)
(*                                                                          *)
(* WHAT IS ABSTRACTED, AND WHY IT SUFFICES.                                 *)
(*  - Types: two numeric types I (Int64) and F (Float64) and one non-numeric*)
(*    S (a String reaching an Any slot). `_f3_is_numeric_jl` of a Union of  *)
(*    two different numerics is false, so the only joins the algorithm can *)
(*    accept are single types -- the lattice here is exactly that decision.*)
(*  - Statements: a literal (Julia gives it its concrete type), an opaque   *)
(*    value Julia typed Any whose run-time type is fixed per program (a     *)
(*    `getindex(::Vector{Any})`, a dynamic call), a 2-operand phi (operands *)
(*    may refer forward: the loop back edge) and a 2-operand `+` (operands  *)
(*    refer backward: SSA dominance), whose run-time result is Julia's      *)
(*    promotion (I+I=I, else F) and which throws on an S operand. Julia     *)
(*    types a `+` of two concretely-typed operands itself; only a `+` over  *)
(*    an Any operand reaches the analysis, as in the real IR.               *)
(*  - The ground truth RT(i) is the least fixpoint of the run-time type     *)
(*    sets over the program graph -- every value any execution can bring to*)
(*    statement i, cycles included.                                        *)
(*  - Init chooses the program: every well-formed program of N statements  *)
(*    over these kinds, so the class is exhaustive at that size.           *)
(*                                                                          *)
(* VARIANTS (CONSTANT Verify):                                              *)
(*   "Real"    -- the real code above.                                      *)
(*   "Join"    -- VERIFY also requires the phi's recorded type to EQUAL the *)
(*                join of all its operands' resolved types, but still drops *)
(*                only the phi.                                             *)
(*   "Restart" -- as "Join", and a phi that fails is banned and propagation *)
(*                restarts from scratch without it, so nothing typed        *)
(*                through it survives. The positive instance: the VERIFY    *)
(*                propagate_numeric_value_types needs.                      *)
(*                                                                          *)
(* FINDING 1 (MCNumericJoinSeededPhiBroken.cfg, "Real"): the optimistic phi *)
(* seed is never revisited. `%phi = phi(0::Int64, %add)`, `%add = %phi +    *)
(* 0.5` -- pass 1 seeds %phi = Int64 from the literal alone (%add not yet   *)
(* resolved), then types %add = Float64; VERIFY sees both operands numeric *)
(* and keeps %phi = Int64. Reproduced on the real function over WT's IR of  *)
(* `s = 0; foreach(i -> (s += 0.5), 1:n)`: out[%16] = Int64 for             *)
(* `%16 = phi(0, %18)`, out[%18] = Float64 for `%18 = %16 + 0.5`; compiling *)
(* it fails at `+(%16, 0.5)`, "expected I64, found F64".                    *)
(* FINDING 2 (MCNumericJoinDroppedPhiBroken.cfg, "Join"): VERIFY drops a    *)
(* phi but keeps what was typed through it. `%p = phi(v[1]::Any, 0)`,       *)
(* `%q = %p + 1` -- %p is seeded Int64 from the literal, %q typed Int64,    *)
(* VERIFY drops %p (v[1] never resolves) and %q stays Int64. Reproduced:    *)
(* `v = Any[1.5]; p = n > 0 ? v[1] : 0; q = p + 1` types q Int64; the wasm  *)
(* traps "illegal cast" for n = 1 where native returns 2.5.                *)
(*                                                                          *)
(* formal(dev/formal/NumericJoin.tla): every SSA propagate_numeric_value_   *)
(* types types holds values of exactly that type on every execution.        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    N,              \* number of statements
    Verify          \* "Real" (the real code) | "Join" | "Restart" -- see the header

ASSUME N \in Nat /\ N >= 1
ASSUME Verify \in {"Real", "Join", "Restart"}

Idx     == 1..N
Num     == {"I", "F"}
RtTypes == {"I", "F", "S"}

\* Julia's promotion for `+` over two numeric run-time types
Promote(x, y) == IF x = "I" /\ y = "I" THEN "I" ELSE "F"

Lits  == {[k |-> "lit", t |-> t] : t \in Num}
Opqs  == {[k |-> "opq", t |-> t] : t \in {"F", "S"}}
Phis  == {[k |-> "phi", a |-> a, b |-> b] : a \in Idx, b \in Idx}
Adds(i) == {[k |-> "add", a |-> a, b |-> b] : a \in 1..(i - 1), b \in 1..(i - 1)}
StmtsAt(i) == Lits \cup Opqs \cup {p \in Phis : p.a < p.b /\ i \notin {p.a, p.b}} \cup Adds(i)

Programs == {p \in [Idx -> UNION {StmtsAt(i) : i \in Idx}] : \A i \in Idx : p[i] \in StmtsAt(i)}

VARIABLES
    prog,     \* the program (chosen once)
    out,      \* the analysis result: a function from typed SSA ids to Num
    phase,    \* "prop" | "verify" | "done"
    idx,      \* the next statement the propagate pass visits (N + 1 = end of pass)
    changed,  \* the pass's `changed` flag
    banned    \* "Restart" only: phis VERIFY rejected, never typed again

vars == <<prog, out, phase, idx, changed, banned>>

----------------------------------------------------------------------------
(* Ground truth *)

\* one step of the run-time type semantics
RtStep(p, rt) == [i \in Idx |->
    CASE p[i].k = "lit" -> {p[i].t}
      [] p[i].k = "opq" -> {p[i].t}
      [] p[i].k = "phi" -> rt[p[i].a] \cup rt[p[i].b]
      [] p[i].k = "add" -> {Promote(x, y) : x \in rt[p[i].a] \cap Num, y \in rt[p[i].b] \cap Num}]

RECURSIVE RtFix(_, _)
RtFix(p, rt) == LET nxt == RtStep(p, rt) IN IF nxt = rt THEN rt ELSE RtFix(p, nxt)

RT == RtFix(prog, [i \in Idx |-> {}])

----------------------------------------------------------------------------
(* The analysis *)

\* Julia's own type for statement i: a literal is concrete, a `+` of two concrete operands is
\* their promotion (inference types it), everything else -- a phi, an opaque value, a `+`
\* over an Any operand -- is Any
RECURSIVE JuliaType(_, _)
JuliaType(p, i) ==
    CASE p[i].k = "lit" -> p[i].t
      [] p[i].k = "add" ->
            LET x == JuliaType(p, p[i].a)
                y == JuliaType(p, p[i].b)
            IN IF x \in Num /\ y \in Num THEN Promote(x, y) ELSE "Any"
      [] OTHER -> "Any"

\* the SSAs Julia typed Any
Pend == {i \in Idx : JuliaType(prog, i) = "Any"}

\* `_opT`: an operand's type as the analysis sees it right now
OpT(v) == IF v \in DOMAIN out THEN out[v] ELSE JuliaType(prog, v)

\* the type the propagate rule gives statement i under the current `out`, or "none"
Rule(i) ==
    LET s == prog[i] IN
    CASE s.k = "phi" ->
            LET ts == {OpT(v) : v \in {s.a, s.b}} \cap Num
            IN IF ts # {} /\ Cardinality(ts) = 1 THEN CHOOSE t \in ts : TRUE ELSE "none"
      [] s.k = "add" ->
            IF OpT(s.a) \in Num /\ OpT(s.b) \in Num THEN Promote(OpT(s.a), OpT(s.b)) ELSE "none"
      [] OTHER -> "none"

Extend(f, i, t) == [j \in DOMAIN f \cup {i} |-> IF j = i THEN t ELSE f[j]]
Restrict(f, S)  == [j \in DOMAIN f \ S |-> f[j]]

\* VERIFY's test for a typed phi
PhiOk(i) ==
    LET s == prog[i] IN
    /\ OpT(s.a) \in Num /\ OpT(s.b) \in Num
    /\ (Verify # "Real" => ({OpT(s.a), OpT(s.b)} = {out[i]}))

Init ==
    /\ prog \in Programs
    /\ out = <<>>
    /\ phase = "prop"
    /\ idx = 1
    /\ changed = FALSE
    /\ banned = {}

Visit ==
    /\ phase = "prop" /\ idx <= N
    /\ IF idx \in Pend /\ idx \notin DOMAIN out /\ idx \notin banned /\ Rule(idx) # "none"
       THEN /\ out' = Extend(out, idx, Rule(idx))
            /\ changed' = TRUE
       ELSE UNCHANGED <<out, changed>>
    /\ idx' = idx + 1
    /\ UNCHANGED <<prog, phase, banned>>

EndPass ==
    /\ phase = "prop" /\ idx = N + 1
    /\ IF changed THEN /\ idx' = 1 /\ changed' = FALSE /\ UNCHANGED phase
                  ELSE /\ phase' = "verify" /\ UNCHANGED <<idx, changed>>
    /\ UNCHANGED <<prog, out, banned>>

\* VERIFY that drops one failing phi (in any order -- the real loop walks a Dict)
DropPhi ==
    /\ phase = "verify" /\ Verify # "Restart"
    /\ \E i \in DOMAIN out :
          /\ prog[i].k = "phi" /\ ~PhiOk(i)
          /\ out' = Restrict(out, {i})
    /\ UNCHANGED <<prog, phase, idx, changed, banned>>

\* the rechecked VERIFY: ban a failing phi and restart propagation from nothing
BanAndRestart ==
    /\ phase = "verify" /\ Verify = "Restart"
    /\ \E i \in DOMAIN out :
          /\ prog[i].k = "phi" /\ ~PhiOk(i)
          /\ banned' = banned \cup {i}
    /\ out' = <<>> /\ phase' = "prop" /\ idx' = 1 /\ changed' = FALSE
    /\ UNCHANGED prog

Finish ==
    /\ phase = "verify"
    /\ \A i \in DOMAIN out : prog[i].k = "phi" => PhiOk(i)
    /\ phase' = "done"
    /\ UNCHANGED <<prog, out, idx, changed, banned>>

Done == phase = "done" /\ UNCHANGED vars

Next == Visit \/ EndPass \/ DropPhi \/ BanAndRestart \/ Finish \/ Done

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

----------------------------------------------------------------------------
(* Claims *)

TypeOK ==
    /\ prog \in Programs
    /\ DOMAIN out \subseteq Idx /\ \A i \in DOMAIN out : out[i] \in Num
    /\ phase \in {"prop", "verify", "done"}
    /\ idx \in 1..(N + 1)
    /\ changed \in BOOLEAN
    /\ banned \subseteq Idx

\* every value that can reach a typed SSA has exactly its recorded type
Soundness == phase = "done" => \A i \in DOMAIN out : RT[i] \subseteq {out[i]}

Terminates == <>(phase = "done")
=============================================================================
