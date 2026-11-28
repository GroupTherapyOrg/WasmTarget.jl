--------------------------- MODULE PhiElimination ---------------------------
(***************************************************************************)
(* A TLA+ model of LLVM's PHIElimination at the llvm pin (dev/LEDGER.md   *)
(* D42; llvm/lib/CodeGen/PHIElimination.cpp:317 EliminatePHINodes, :365    *)
(* LowerPHINode, PHIEliminationUtils' findPHICopyInsertPoint) as WasmTarget *)
(* ports it over Julia's PhiNodes, and of the code that executes its       *)
(* output:                                                                  *)
(*   eliminate_phi_nodes, lower_phi_node (src/llvm/phi_elimination.jl)    *)
(*     lower every PhiNode at the start of a block of the layout: for each *)
(*     edge with a value, a COPY into the PHI's own IncomingReg in the     *)
(*     edge's block, before its first terminator; an edge with no value    *)
(*     copies nothing; an edge from a block no path reaches is skipped;    *)
(*     an edge with a value from any other block that is no predecessor    *)
(*     rejects, located (WasmTarget's own defect);                         *)
(*   visit_block (src/code_generator.jl) emits the block's instructions in *)
(*     order: a PhiNode statement reads its IncomingReg into the PHI's own *)
(*     local, a COPY evaluates its edge's value (reading the PHI locals as *)
(*     they stand) and writes the IncomingReg (emit_phi_incoming!).        *)
(* Julia's semantics, which the lowering must keep, are its codegen's      *)
(* (julia@6d172b0 src/codegen.cpp:9426-9511, emit_function's phi edges):   *)
(* on the edge taken, every PHI of the block takes that edge's value, all  *)
(* read at once from the values as they stood when the predecessor ended   *)
(* (`a, b = b, a + b`); an edge with no value leaves the PHI undefined (it *)
(* is never observed, Compiler/src/ssair/verify.jl); an edge from a block   *)
(* never reached is not emitted (`if (!FromBB) continue`); any other edge   *)
(* names a predecessor (the `assert` there, verify.jl's "not in            *)
(* predecessor list").                                                      *)
(*                                                                         *)
(* THE CFG. Block 1 is codegen's top block (machine_function, src/julia/   *)
(* machine.jl): no statements, its one successor Julia's first block 2,    *)
(* which may itself have predecessors. Every other block ends as           *)
(* machine_function reads Julia's last statement: a return (no successor), *)
(* a fall through to the next block (no terminator: a plain statement, an  *)
(* EnterNode's normal edge, or a GotoIfNot whose target is the next block), *)
(* a GotoNode (BR, its target any block but the top), or a GotoIfNot (BR_UNLESS to its *)
(* target, any block but the top and the next, then the fall through).     *)
(* Every such CFG of N blocks is an initial state. The predecessors of a   *)
(* block are the reachable blocks with an edge to it (machine_function     *)
(* drops an unreachable one's edges).                                      *)
(*                                                                         *)
(* THE PHIS. One reachable block M holds 1..MaxPhis PhiNodes, its first    *)
(* statements (an unreachable block leaves the layout, its PHIs never      *)
(* lowered or read). For every block p, PHI j's edge from p is one of:     *)
(*   NoValue      no edge, or an edge whose value is undefined (both copy  *)
(*                nothing: lower_phi_node's first test, codegen's `if      *)
(*                (!value) continue`);                                      *)
(*   Lit          a value defined before the edge, distinct for each PHI    *)
(*                and edge (<<j, p>>): a constant, or an SSA value of       *)
(*                another block, which no COPY writes;                      *)
(*   Phi(k)       the value of M's own PHI k, on an edge from a block M     *)
(*                dominates (Julia's SSA dominance, verify.jl check_op):     *)
(*                the swap, `a, b = b, a + b`, across a back edge.           *)
(* A predecessor's edge may be any of these, any other block's NoValue or  *)
(* Lit (which of the two is all that lower_phi_node reads of it).           *)
(*                                                                         *)
(* THE RUN. The lowering takes the edges one step each (PHI by PHI, each   *)
(* PHI's edges in block order: the order of a PHI's edges places its        *)
(* COPYs in distinct blocks, so it changes nothing), then the program runs *)
(* from the top block, each step one block's code and the edge it takes:   *)
(* the block's PHI reads where it is M (at its start, before any COPY), its *)
(* COPYs in their order (those after a terminator only where it falls      *)
(* through), then the edge; Julia's values beside it.                      *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Values are tokens: what a COPY computes is    *)
(* which value it moves, and a token per PHI and edge tells a stale or a   *)
(* wrong one from the right one. One block's PHIs a state: the PHIs of two *)
(* blocks write distinct IncomingRegs and read only their own, so a COPY   *)
(* into another block's register changes nothing here (a Lit stands for    *)
(* another block's PHI, which no COPY into M's registers writes).          *)
(* emit_phi_incoming!'s type guard (a value whose run-time type may not be *)
(* the PHI's, stored only where Julia's isa holds) is per value, the       *)
(* model's values all the PHI's type. The passes after PHIElimination      *)
(* (FixIrreducibleControlFlow's routing blocks, CFGSort, CFGStackify) move *)
(* blocks and route edges through blocks that write no IncomingReg; their  *)
(* models are FixIrreducible.tla, ImplicitDefs.tla (an IncomingReg defined *)
(* on every path of the rewritten CFG) and CFGStackify.tla. A PhiCNode is  *)
(* written by its Upsilons, not by a COPY (TaskExcStack.tla's catch        *)
(* landing), and an EH pad's unwind edges carry no PhiNode value.          *)
(*                                                                         *)
(* THE CLAIMS, each with a Broken variant (Bug) TLC must reject:          *)
(*   Agrees      on every path, at the start of M each PHI's local holds    *)
(*               the value Julia gives it on the edge taken, wherever that  *)
(*               value is defined: all PHIs of M read at once (Bug          *)
(*               "noincomingreg": the COPYs write the PHI's own local, the *)
(*               swap reads a value its own edge's COPY already wrote; Bug *)
(*               "copyafterterminator": the COPY placed after the branch,  *)
(*               WT1's d6c23c54, so a taken branch never stores its edge's *)
(*               value; Bug "onephipermerge": only the first PHI of a       *)
(*               merge lowered, WT1's 70deff25, the others reading a       *)
(*               register no edge wrote);                                   *)
(*   EdgeRule    the lowering rejects exactly where an edge with a value    *)
(*               names a reachable block that is no predecessor, and every *)
(*               COPY it places is in a predecessor of M: an edge from an  *)
(*               unreachable block is dropped (Bug "skipanynonpred",        *)
(*               A51S12's class: every edge naming no predecessor skipped,  *)
(*               a malformed edge silently copying nothing);                *)
(*   Terminates  the lowering ends, its edges taken once each.              *)
(*                                                                         *)
(* formal(src/llvm/phi_elimination.jl eliminate_phi_nodes, lower_phi_node; *)
(* src/code_generator.jl visit_block's PHI read and COPY): Agrees,         *)
(* EdgeRule, Terminates.                                                    *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS N, MaxPhis, Bug

Bugs == {"none", "noincomingreg", "copyafterterminator", "onephipermerge", "skipanynonpred"}
ASSUME Bug \in Bugs /\ N >= 2 /\ MaxPhis >= 1

Blocks == 1..N
Top == 1

(* an edge's value: none, one defined before the edge, or M's PHI k *)
NoValue == <<"novalue", 0>>
Lit == <<"lit", 0>>
Phi(k) == <<"phi", k>>
(* a value no edge gave: wasm's default in a register, Julia's undefined PHI *)
Undef == <<0, 0>>

(* how a block ends, machine_function's reading of Julia's last statement *)
Ends(b) ==
    IF b = Top THEN {[k |-> "fall", t |-> 2]}
    ELSE {[k |-> "ret", t |-> 0]}
         \cup (IF b < N THEN {[k |-> "fall", t |-> b + 1]} ELSE {})
         \cup {[k |-> "goto", t |-> t] : t \in 2..N}
         \cup (IF b < N THEN {[k |-> "cond", t |-> d] : d \in (2..N) \ {b + 1}} ELSE {})

Succ(c, b) ==
    CASE c[b].k = "ret"  -> {}
      [] c[b].k = "fall" -> {b + 1}
      [] c[b].k = "goto" -> {c[b].t}
      [] c[b].k = "cond" -> {c[b].t, b + 1}

RECURSIVE Closure(_, _)
(* the blocks reached from S through f, S included *)
Closure(f(_), S) == LET T == S \cup UNION {f(x) : x \in S} IN IF T = S THEN S ELSE Closure(f, T)

Reach(c) == Closure(LAMBDA x : Succ(c, x), {Top})
Preds(c, m) == {p \in Reach(c) : m \in Succ(c, p)}
(* a dominates b, both reachable: no path from the top reaches b avoiding a *)
Dom(c, a, b) == a = b \/ (a # Top /\ b \notin Closure(LAMBDA x : IF x = a THEN {} ELSE Succ(c, x), {Top}))

EdgeVals(c, mb, n, p) ==
    IF p \in Preds(c, mb)
    THEN {NoValue, Lit} \cup {Phi(k) : k \in (IF Dom(c, mb, p) THEN 1..n ELSE {})}
    ELSE {NoValue, Lit}
(* every PHI of M: its edge from each block *)
Rows(c, mb, n) ==
    {f \in [Blocks -> {NoValue, Lit} \cup {Phi(k) : k \in 1..n}] : \A p \in Blocks : f[p] \in EdgeVals(c, mb, n, p)}
CFGs == {c \in [Blocks -> UNION {Ends(b) : b \in Blocks}] : \A b \in Blocks : c[b] \in Ends(b)}

Vals == {Undef} \cup ((1..MaxPhis) \X Blocks)

VARIABLES cfg, merge, np, phis, phase, cur, steps, copies, at, julia, local_, inc
vars == <<cfg, merge, np, phis, phase, cur, steps, copies, at, julia, local_, inc>>

Init ==
    /\ cfg \in CFGs
    /\ merge \in Reach(cfg) \ {Top}
    /\ np \in 1..MaxPhis
    /\ phis \in [1..np -> Rows(cfg, merge, np)]
    /\ phase = "lower"
    /\ cur = <<1, 1>>
    /\ steps = 0
    /\ copies = [b \in Blocks |-> <<>>]
    /\ at = Top
    /\ julia = [j \in 1..MaxPhis |-> Undef]
    /\ local_ = [j \in 1..MaxPhis |-> Undef]
    /\ inc = [j \in 1..MaxPhis |-> Undef]

(* lower_phi_node's test of one edge, in its order *)
EdgeAct(j, p) ==
    LET v == phis[j][p] IN
    IF Bug = "onephipermerge" /\ j > 1 THEN "skip"
    ELSE IF v = NoValue THEN "skip"
    ELSE IF p \notin Preds(cfg, merge)
         THEN IF Bug = "skipanynonpred" \/ p \notin Reach(cfg) THEN "skip" ELSE "reject"
    ELSE "copy"

NextCur(j, p) == IF p < N THEN <<j, p + 1>> ELSE <<j + 1, 1>>

Lower ==
    /\ phase = "lower"
    /\ LET j == cur[1]
           p == cur[2]
           act == EdgeAct(j, p)
           nc == NextCur(j, p)
       IN /\ copies' = IF act = "copy" THEN [copies EXCEPT ![p] = Append(@, <<j, p>>)] ELSE copies
          /\ phase' = IF act = "reject" THEN "rejected" ELSE IF nc[1] > np THEN "run" ELSE "lower"
          /\ cur' = nc
          /\ steps' = steps + 1
    /\ UNCHANGED <<cfg, merge, np, phis, at, julia, local_, inc>>

(* a COPY's value, read where it stands: a PHI's value from its local *)
CopyVal(c, loc) ==
    LET v == phis[c[1]][c[2]] IN
    IF v = Lit THEN c ELSE loc[v[2]]

(* the COPYs in order, each writing its PHI's IncomingReg, or its own local in Bug "noincomingreg" *)
RECURSIVE RunCopies(_, _, _)
RunCopies(s, loc, reg) ==
    IF s = <<>> THEN <<loc, reg>>
    ELSE LET c == Head(s)
             v == CopyVal(c, loc)
         IN IF Bug = "noincomingreg"
            THEN RunCopies(Tail(s), [loc EXCEPT ![c[1]] = v], reg)
            ELSE RunCopies(Tail(s), loc, [reg EXCEPT ![c[1]] = v])

(* the edge's value Julia gives PHI j, read from the values as they stood *)
JuliaVal(j, p, vals) ==
    LET v == phis[j][p] IN
    IF v = NoValue THEN Undef ELSE IF v = Lit THEN <<j, p>> ELSE vals[v[2]]

(* whether the edge to s jumps over the instructions after the block's first terminator *)
Jumps(b, s) == cfg[b].k = "goto" \/ (cfg[b].k = "cond" /\ s = cfg[b].t)

Run ==
    /\ phase = "run"
    /\ \E s \in Succ(cfg, at) :
          LET ran == IF Bug = "copyafterterminator" /\ Jumps(at, s) THEN <<>> ELSE copies[at]
              after == RunCopies(ran, local_, inc)
          IN /\ julia' = IF s = merge THEN [j \in 1..MaxPhis |-> IF j <= np THEN JuliaVal(j, at, julia) ELSE Undef] ELSE julia
             /\ inc' = after[2]
             \* M's PhiNode statements, at its start: each reads its IncomingReg into its local
             /\ local_' = IF s = merge /\ Bug # "noincomingreg"
                          THEN [j \in 1..MaxPhis |-> IF j <= np THEN after[2][j] ELSE Undef]
                          ELSE after[1]
             /\ at' = s
    /\ UNCHANGED <<cfg, merge, np, phis, phase, cur, steps, copies>>

Terminal == (phase = "rejected" \/ (phase = "run" /\ Succ(cfg, at) = {})) /\ UNCHANGED vars

Next == Lower \/ Run \/ Terminal
Spec == Init /\ [][Next]_vars /\ WF_vars(Lower)

TypeOK ==
    /\ merge \in Blocks \ {Top}
    /\ np \in 1..MaxPhis
    /\ phase \in {"lower", "run", "rejected"}
    /\ steps \in 0..(MaxPhis * N)
    /\ \A b \in Blocks : \A i \in 1..Len(copies[b]) : copies[b][i] \in (1..np) \X Blocks
    /\ at \in Blocks
    /\ julia \in [1..MaxPhis -> Vals]
    /\ local_ \in [1..MaxPhis -> Vals]
    /\ inc \in [1..MaxPhis -> Vals]

Agrees == (phase = "run" /\ at = merge) => \A j \in 1..np : julia[j] # Undef => local_[j] = julia[j]

BadEdge == \E j \in 1..np, p \in Blocks : phis[j][p] # NoValue /\ p \notin Preds(cfg, merge) /\ p \in Reach(cfg)
EdgeRule ==
    /\ phase # "lower" => (phase = "rejected" <=> BadEdge)
    /\ \A b \in Blocks : copies[b] # <<>> => b \in Preds(cfg, merge)

Terminates == <>(phase # "lower")
=============================================================================
