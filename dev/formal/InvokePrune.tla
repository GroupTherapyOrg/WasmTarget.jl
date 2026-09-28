------------------------------ MODULE InvokePrune ------------------------------
(***************************************************************************)
(* A TLA+ model of how the closed-world collector retargets explicit       *)
(* `:invoke` edges and then prunes the plan: `_missing_explicit_invoke_mis` *)
(* and `_prune_external_leaf_subgraphs` as `collect_closed_world` drives    *)
(* them (src/codegen/trimcollect.jl).                                      *)
(*                                                                         *)
(* WHAT THE REAL CODE DOES. Julia may leave an explicit invoke's           *)
(* MethodInstance abstract (a `@nospecialize` argument, a widened call).   *)
(* When a site's operand types are concrete, `_missing_explicit_invoke_mis` *)
(* rebuilds the MethodInstance from them, rewrites that ONE site to it     *)
(* (`nir_retarget_invoke!`), has it collected, and records the original    *)
(* MethodInstance as superseded (never an entry). After a round that       *)
(* superseded something, the collector prunes the plan: it keeps the       *)
(* bodies reachable from the roots (entries and dynamic-dispatch selector  *)
(* roots) over the invoke edges as they now stand, and never keeps a       *)
(* declared import (an external leaf: the host supplies its body). The     *)
(* loop ends when no site can be retargeted and the last supersession has  *)
(* been pruned.                                                           *)
(*                                                                         *)
(* THE CLAIM. A MethodInstance is superseded AT A SITE, not everywhere:    *)
(* another site whose operands are not concrete still invokes the original *)
(* (`_subtype_var(::VarBinding, @nospecialize(a), ...)` from test/helpers/ *)
(* subtype.jl: one call passes a TypeVar and is retargeted, one passes Any *)
(* and keeps the original). So pruning must follow reachability alone:    *)
(* every invoke in a kept body names a kept body or an import              *)
(* (NoDanglingInvoke), and every kept body is reachable (Minimal). The     *)
(* Broken variant prunes superseded MethodInstances as leaves -- what the  *)
(* collector did until 2026-09-28: the Any site then names a body the plan *)
(* no longer has, and codegen bound it by subtyping to the TypeVar copy    *)
(* (get_function's reverse-subtype pass), which ran it on any value.       *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. MethodInstances, sites and the retargeted    *)
(* MethodInstance a site's concrete operands select are opaque constants: *)
(* the claim is about which bodies the plan keeps, not about how Julia     *)
(* specializes. A site's retarget is fixed per site (the collector's       *)
(* rebuild is a function of the site's operand types). Sites are scanned   *)
(* in any order and a prune may follow any retarget, as in the real loop,  *)
(* which prunes after every round that superseded something.              *)
(*                                                                         *)
(* formal(src/codegen/trimcollect.jl _prune_external_leaf_subgraphs):      *)
(* after the collector retargets invokes and prunes, every invoke in a     *)
(* kept body names a kept body or an import, and every kept body is        *)
(* reachable from the roots.                                               *)
(*                                                                         *)
(* No dart anchor: parity(quarantine: dart's calls name a fixed member;    *)
(* Julia's explicit invokes may name an abstract MethodInstance the        *)
(* closed-world subset specializes per site).                              *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Methods,             \* MethodInstances: bodies the collector can hold
    Roots,               \* SUBSET Methods: entries and selector roots, always kept
    Leaves,              \* SUBSET Methods: declared imports, reachable but never kept
    Sites,               \* explicit :invoke sites
    Host,                \* [Sites -> Methods]: the body holding the site
    Orig,                \* [Sites -> Methods]: the MethodInstance Julia's IR names
    Retarget,            \* [Sites -> Methods \cup {NoRetarget}]: the rebuilt MethodInstance
    NoRetarget,          \* a site whose operands are not concrete
    SupersededAreLeaves  \* BOOLEAN: TRUE = the broken pruner

VARIABLES
    target,      \* [Sites -> Methods]: what each site invokes now
    present,     \* SUBSET Methods: the bodies in the plan (codeinfos)
    superseded,  \* SUBSET Methods: originals some site was retargeted away from
    dirty,       \* BOOLEAN: a supersession not yet pruned
    phase        \* "collect" | "done"

vars == <<target, present, superseded, dirty, phase>>

\* The leaves a prune stops at and never keeps: the imports -- and, in the broken pruner, every
\* superseded MethodInstance.
StopAt == IF SupersededAreLeaves THEN Leaves \cup superseded ELSE Leaves

\* The bodies reachable from Roots over the current edges, walking only bodies the plan
\* holds (a pruned body's edges are gone) and never into a leaf's body.
RECURSIVE ReachFrom(_, _)
ReachFrom(S, n) ==
    IF n = 0 THEN S
    ELSE ReachFrom(S \cup {target[s] : s \in {x \in Sites :
                                    Host[x] \in S /\ Host[x] \in present /\ Host[x] \notin StopAt}},
                   n - 1)
Reach == ReachFrom(Roots, Cardinality(Methods))

\* What a prune keeps.
Kept == (Reach \cap present) \ StopAt

InitialReach ==
    LET RECURSIVE R(_, _)
        R(S, n) == IF n = 0 THEN S
                   ELSE R(S \cup {Orig[s] : s \in {x \in Sites : Host[x] \in S /\ Host[x] \notin Leaves}}, n - 1)
    IN R(Roots, Cardinality(Methods))

TypeOK ==
    /\ target \in [Sites -> Methods]
    /\ present \subseteq Methods
    /\ superseded \subseteq Methods
    /\ dirty \in BOOLEAN
    /\ phase \in {"collect", "done"}

Init ==
    /\ target = Orig
    /\ present = InitialReach \ Leaves
    /\ superseded = {}
    /\ dirty = FALSE
    /\ phase = "collect"

Retargetable(s) ==
    /\ Retarget[s] # NoRetarget
    /\ target[s] = Orig[s]
    /\ Host[s] \in present

\* _missing_explicit_invoke_mis rewrites one site and collect_new_pairs! collects its target.
DoRetarget(s) ==
    /\ phase = "collect"
    /\ Retargetable(s)
    /\ target' = [target EXCEPT ![s] = Retarget[s]]
    /\ present' = present \cup ({Retarget[s]} \ Leaves)
    /\ superseded' = IF Orig[s] \in Roots THEN superseded ELSE superseded \cup {Orig[s]}
    /\ dirty' = ((Orig[s] \notin Roots) \/ dirty)
    /\ UNCHANGED phase

\* _prune_external_leaf_subgraphs after a round that superseded something.
Prune ==
    /\ phase = "collect"
    /\ dirty
    /\ present' = Kept
    /\ dirty' = FALSE
    /\ UNCHANGED <<target, superseded, phase>>

Finish ==
    /\ phase = "collect"
    /\ ~dirty
    /\ \A s \in Sites : ~Retargetable(s)
    /\ phase' = "done"
    /\ UNCHANGED <<target, present, superseded, dirty>>

Done == phase = "done" /\ UNCHANGED vars

Next == (\E s \in Sites : DoRetarget(s)) \/ Prune \/ Finish \/ Done

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* Between prunes the plan only grows, so the claim is checked whenever no prune is due.
NoDanglingInvoke ==
    ~dirty => \A s \in Sites :
        (Host[s] \in present /\ Host[s] \notin Leaves) => target[s] \in present \cup Leaves

Minimal == phase = "done" => present \subseteq Reach

Terminates == <>(phase = "done")
=============================================================================
