---------------------------- MODULE ImplicitDefs ----------------------------
(***************************************************************************)
(* A TLA+ model of addImplicitDefs, WebAssemblyFixIrreducibleControlFlow.cpp *)
(* :521 at the llvm pin (dev/PARITY_MASTER.md; dev/LEDGER.md D42), over the *)
(* CFG FixIrreducible.tla's processRegion rewrites (instanced here, never   *)
(* edited, lock L227).                                                      *)
(*                                                                         *)
(* WHAT THE ALGORITHM DOES. When processRegion changed the function, every *)
(* virtual register with a use and no ARGUMENT definition gets an           *)
(* IMPLICIT_DEF at the start of the entry block, so every use has a         *)
(* definition on every path of the rewritten CFG; ExplicitLocals erases    *)
(* each, the register's local holding wasm's default value there.          *)
(*                                                                         *)
(* THE REGISTERS. Two kinds, each a set of defining blocks (a definition   *)
(* at the block's end, before its terminator) and a set of using blocks (a *)
(* use at the block's start), each well-defined in the input CFG:          *)
(*   "value"     a statement's SSA value: one defining block d, its uses in *)
(*               blocks d strictly dominates (Julia's SSA dominance; a use *)
(*               in d itself after the definition crosses no edge);         *)
(*   "incoming"  a PHI's IncomingReg (PHIElimination): defined by the COPY *)
(*               in every predecessor of the PHI's block, used by the       *)
(*               PHI's read at the block's start.                           *)
(* One register a state, every register of each kind over every CFG: the   *)
(* claims are per register.                                                 *)
(*                                                                         *)
(* THE CLAIMS, each with a Broken variant (Bug) TLC must reject:           *)
(*   Defined          every use of the register is reached, on every path  *)
(*                    of the rewritten CFG from the entry, after one of its *)
(*                    definitions, the IMPLICIT_DEFs included (Bug           *)
(*                    "nodefs": none added; Bug "valuesonly": only a        *)
(*                    statement's value gets one, a PHI's IncomingReg none: *)
(*                    a routing block's path through the dispatch reaches   *)
(*                    the PHI's block from a block that copied nothing);    *)
(*   ValuesDominated  a statement's value is defined on every path of the  *)
(*                    rewritten CFG without its IMPLICIT_DEF: a block       *)
(*                    outside an irreducible loop that dominates one of its *)
(*                    entries dominates every predecessor of every entry,   *)
(*                    so the dispatch, and none inside dominates an entry,  *)
(*                    so the value's IMPLICIT_DEF is dead (what            *)
(*                    OptimizeLiveIntervals erases when optimizing) and     *)
(*                    the IncomingRegs are the registers it serves (Bug     *)
(*                    "notssa": a value's uses in any block, not only those *)
(*                    its definition dominates, which no SSA form allows).  *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. A block's instructions are its definitions   *)
(* at the end and its uses at the start: a use and a definition in one     *)
(* block, the use after it, crosses no edge. The label registers           *)
(* FixIrreducibleControlFlow itself makes are set by every routing block   *)
(* before its dispatch reads them, as FixIrreducible.tla's PathsPreserved  *)
(* checks. Dynamic execution, which the label registers steer, never       *)
(* reaches a use undefined (FixIrreducible.tla's PathsPreserved); these    *)
(* claims are over the static CFG, every path of it, as LiveIntervals and  *)
(* wasm's validation read it.                                               *)
(*                                                                         *)
(* formal(src/llvm/fix_irreducible_control_flow.jl add_implicit_defs):     *)
(* every use has a definition on every path of the rewritten CFG.          *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS N, Extra, Fuel, Bug

Bugs == {"none", "nodefs", "valuesonly", "notssa"}
ASSUME Bug \in Bugs

VARIABLES cfg, out, reg
vars == <<cfg, out, reg>>

FI == INSTANCE FixIrreducible WITH Bug <- "none"

Orig == FI!Orig
Entry == FI!Entry

(* a dominates b in the input CFG c *)
OrigDom(c, a, b) == a = b \/ b \notin FI!Closure(LAMBDA y : c[y] \ {a}, IF a = Entry THEN {} ELSE {Entry})

Reg(kind, defs, uses) == [kind |-> kind, defs |-> defs, uses |-> uses]
ValueRegs(c) ==
    UNION {{Reg("value", {d}, U) : U \in (SUBSET {u \in Orig \ {d, Entry} : Bug = "notssa" \/ OrigDom(c, d, u)}) \ {{}}}
           : d \in Orig}
IncomingRegs(c) == {Reg("incoming", {p \in Orig : b \in c[p]}, {b}) : b \in Orig \ {Entry}}

Init ==
    /\ cfg \in {c \in [Orig -> FI!SuccChoices] : FI!AllReach(c) /\ FI!NoEntryPred(c)}
    /\ out = FI!ProcessRegion(FI!Start(cfg), Entry, Orig, Fuel)
    /\ reg \in ValueRegs(cfg) \cup IncomingRegs(cfg)
Next == UNCHANGED vars
Spec == Init /\ [][Next]_vars

TypeOK == out.ok \in BOOLEAN /\ reg.kind \in {"value", "incoming"} /\ reg.defs \subseteq Orig /\ reg.uses \subseteq Orig

G == out.g
(* processRegion changed the function: it added a block *)
Changed == G.n > N
(* addImplicitDefs: when the function changed, every register with a use is defined at the entry *)
ImplicitDefs(r) ==
    IF ~Changed \/ Bug = "nodefs" \/ (Bug = "valuesonly" /\ r.kind = "incoming") THEN {} ELSE {Entry}

(* the blocks whose start a path from the entry reaches with no definition of the register in defs *)
Undefined(defs) == FI!Closure(LAMBDA x : IF x \in defs THEN {} ELSE G.succ[x], {Entry})

Defined == out.ok => reg.uses \cap Undefined(reg.defs \cup ImplicitDefs(reg)) = {}

ValuesDominated == (out.ok /\ reg.kind = "value") => reg.uses \cap Undefined(reg.defs) = {}
=============================================================================
