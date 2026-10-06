---------------------------- MODULE Enrollment ----------------------------
(***************************************************************************)
(* A TLA+ model of which method bodies a dynamic call to a callable gets,  *)
(* and in what order its vtable entry tries them: the closed-world         *)
(* collector's enrollment for a closure or function called with erased     *)
(* arguments (`_dynamic_dispatch_candidate_mis`, src/codegen/trimcollect.jl) *)
(* and the row order of the dispatching entry                              *)
(* (`_closure_dispatch_trampoline!`, src/codegen/closures.jl).             *)
(*                                                                         *)
(* JULIA. A call dispatches on the value's class: of the callable's        *)
(* methods that admit the class, the most specific runs; none admits it:   *)
(* MethodError (a trap here, with dev/AUDIT.md A3S1).                      *)
(*                                                                         *)
(* WT. The call site's static type S admits a set of classes. The          *)
(* collector enrolls a body for each method Julia's matching returns for S *)
(* (Base._methods_by_ftype: every method whose parameter type intersects   *)
(* S, specialized at the intersection), and the entry tries the enrolled   *)
(* bodies most specific first, each testing the value's class against its  *)
(* parameter type (`_emit_closure_arg_tests!`).                            *)
(*                                                                         *)
(* THE CLAIM. For every class that may reach the call, the entry runs the  *)
(* method Julia selects (NoWrongMethod), and traps only where Julia has no *)
(* method (TrapOnlyWhenNoMethod). Broken variants: the rule before         *)
(* 2026-10-06, a method enrolled only when its parameter type contains S   *)
(* (SubsetRule: a closure with h(::Int64) and h(x) called with an erased   *)
(* Int64 enrolled only h(x) and answered 5 where Julia answers 4; one with *)
(* only h(::Int64) enrolled nothing); and rows tried in program order      *)
(* (ProgramOrder: a less specific method listed first runs instead).       *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Classes and methods are opaque; a method's   *)
(* parameter type is the set of classes it admits; specificity is a       *)
(* strict order on methods consistent with set inclusion (a method that    *)
(* admits fewer classes is more specific); one dispatch position.          *)
(*                                                                         *)
(* formal(src/codegen/trimcollect.jl _dynamic_dispatch_candidate_mis): a   *)
(* dynamic call enrolls, for every class that may reach it, the body Julia *)
(* selects.                                                                *)
(*                                                                         *)
(* parity(quarantine: Julia dispatches a call to a callable value on its   *)
(* arguments' runtime classes over the callable's methods; a dart closure  *)
(* has one body and its static types guarantee its arguments.)            *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Classes, Methods,
          Param,        \* [Methods -> SUBSET Classes]
          Spec,         \* [Methods -> Nat]: lower is more specific
          POrd,         \* [Methods -> Nat]: program order
          Statics,      \* SUBSET (SUBSET Classes): the call sites' static types
          SubsetRule,   \* TRUE = enroll m only when S \subseteq Param[m] (broken)
          ProgramOrder  \* TRUE = rows in program order (broken)

VARIABLES s, v, outcome, done
vars == <<s, v, outcome, done>>
Trap == "trap"

Julia(c) == LET ms == {m \in Methods : c \in Param[m]} IN
            IF ms = {} THEN Trap ELSE CHOOSE m \in ms : \A n \in ms : Spec[m] <= Spec[n]

Enrolled(S) == IF SubsetRule THEN {m \in Methods : S \subseteq Param[m]}
               ELSE {m \in Methods : S \cap Param[m] # {}}

Key(m) == IF ProgramOrder THEN POrd[m] ELSE Spec[m]

Entry(S, c) == LET hit == {m \in Enrolled(S) : c \in Param[m]} IN
               IF hit = {} THEN Trap ELSE CHOOSE m \in hit : \A n \in hit : Key(m) <= Key(n)

Init == s \in Statics /\ v \in s /\ outcome = Trap /\ done = FALSE
Step == ~done /\ outcome' = Entry(s, v) /\ done' = TRUE /\ UNCHANGED <<s, v>>
Spec_ == Init /\ [][Step]_vars

TypeOK == outcome \in Methods \cup {Trap} /\ done \in BOOLEAN
NoWrongMethod == done /\ outcome # Trap => outcome = Julia(v)
TrapOnlyWhenNoMethod == done /\ outcome = Trap => Julia(v) = Trap
=============================================================================
