--------------------------- MODULE EnrollmentArity ---------------------------
(***************************************************************************)
(* A TLA+ model of the observation step of dynamic call sites: which      *)
(* (closure, arity) rows the closed-world collector enrolls bodies for     *)
(* (`_dynamic_dispatch_candidate_mis`, src/codegen/trimcollect.jl), the    *)
(* step Enrollment.tla takes as given (it models the rows of one observed  *)
(* call site over the classes that reach it).                              *)
(*                                                                         *)
(* JULIA. A closure value may reach any dynamic call of the program: the   *)
(* call runs the closure's method for the call's arity, or throws          *)
(* MethodError when the closure has none.                                  *)
(*                                                                         *)
(* WT. The collector walks every collected function once per round. It     *)
(* records each dynamic call's signature and arity (an SSA callee; a call  *)
(* with no argument has arity 0) and each closure type a function builds.  *)
(* The function-local fold enrolls a body for each closure a function      *)
(* builds at each arity that function calls (with the call's typed         *)
(* arguments); then every closure built anywhere is enrolled at every      *)
(* dynamic call made anywhere at an arity it has a method at (with that    *)
(* call's own argument types), as dart's ClosureLayouter builds a closure's vtable  *)
(* from its own signature, an entry for every arity it accepts. A closure  *)
(* object holds a null entry exactly for the arities with no row; a        *)
(* dynamic call at such an arity traps (illegal cast) where Julia runs the *)
(* method.                                                                 *)
(*                                                                         *)
(* THE CLAIM. When the walk is done, every closure the program builds has  *)
(* a row at every arity a dynamic call makes at which it has a method      *)
(* (EveryDynamicArityHasARow), and no row at an arity it has no method for *)
(* (NoRowWithoutMethod).                                                   *)
(*                                                                         *)
(* THE BROKEN VARIANTS. CoOccurrenceOnly: the function-local fold alone (a *)
(* closure built in one function and called dynamically only in another   *)
(* has no row: dev/AUDIT.md A11E1, the inner closure an erased closure     *)
(* returns, called: native 6, a trap). SkipNullary: a call with no         *)
(* argument records no arity (the guard `!isempty(_dargs)`: a closure      *)
(* called `fs[1]()` had no row, native 10, a trap).                        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Fns,              \* the collected functions
    Closures,         \* the closure types
    Builds,           \* [Fns -> SUBSET Closures]: the closures a function builds
    Calls,            \* [Fns -> SUBSET Nat]: the arities of a function's dynamic calls
    Accepts,          \* [Closures -> SUBSET Nat]: the arities a closure has a method at
    CoOccurrenceOnly, \* Broken: the function-local fold alone
    SkipNullary       \* Broken: a call with no argument records no arity

ASSUME Builds \in [Fns -> SUBSET Closures] /\ Accepts \in [Closures -> SUBSET Nat]
ASSUME CoOccurrenceOnly \in BOOLEAN /\ SkipNullary \in BOOLEAN

\* the arities the collector records for a function's calls
Recorded(f) == IF SkipNullary THEN Calls[f] \ {0} ELSE Calls[f]
BuiltAll == UNION {Builds[f] : f \in Fns}
CalledAll == UNION {Calls[f] : f \in Fns}             \* every arity a dynamic call makes
RecordedAll == UNION {Recorded(f) : f \in Fns}

VARIABLES scanned, rows, done
vars == <<scanned, rows, done>>

Init == scanned = {} /\ rows = {} /\ done = FALSE

\* the function-local fold over one function, in any order
Scan(f) ==
    /\ ~done /\ f \notin scanned
    /\ scanned' = scanned \cup {f}
    /\ rows' = rows \cup {r \in Builds[f] \X Recorded(f) : r[2] \in Accepts[r[1]]}
    /\ UNCHANGED done

\* after the walk: every built closure at every recorded arity it accepts
Finish ==
    /\ ~done /\ scanned = Fns
    /\ rows' = IF CoOccurrenceOnly THEN rows
               ELSE rows \cup {r \in BuiltAll \X RecordedAll : r[2] \in Accepts[r[1]]}
    /\ done' = TRUE
    /\ UNCHANGED scanned

Stutter == done /\ UNCHANGED vars

Next == (\E f \in Fns : Scan(f)) \/ Finish \/ Stutter
Spec == Init /\ [][Next]_vars

TypeOK == scanned \subseteq Fns /\ rows \subseteq (Closures \X Nat) /\ done \in BOOLEAN

EveryDynamicArityHasARow ==
    done => \A c \in BuiltAll : \A n \in CalledAll \cap Accepts[c] : <<c, n>> \in rows
NoRowWithoutMethod == \A r \in rows : r[2] \in Accepts[r[1]]
=============================================================================
