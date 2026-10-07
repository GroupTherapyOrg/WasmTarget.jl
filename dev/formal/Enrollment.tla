---------------------------- MODULE Enrollment ----------------------------
(***************************************************************************)
(* A TLA+ model of which method bodies a dynamic call to a callable gets,  *)
(* and in what order its vtable entry tries them: the closed-world         *)
(* collector's enrollment for a callable called with erased arguments      *)
(* (`_dynamic_dispatch_candidate_mis`, src/codegen/trimcollect.jl) and the *)
(* rows of its entry (`build_closure_vtable!`, `_most_specific_first`,     *)
(* src/codegen/closures.jl).                                               *)
(*                                                                         *)
(* JULIA. A call dispatches on the value's class over the callable's       *)
(* methods: of those that admit the class, the one more specific than all  *)
(* the others runs (jl_method_morespecific, a partial order); none admits  *)
(* it: MethodError (no method); several admit it and none is more specific *)
(* than the rest: MethodError (ambiguous).                                 *)
(*                                                                         *)
(* WT. The call site's static type S admits a set of classes. The          *)
(* collector enrolls a row for each method Julia's matching returns for S  *)
(* (Base._methods_by_ftype), at the method's intersection with S, a method *)
(* with static parameters at its compileable signature. The entry tries    *)
(* the rows in the methods' specificity order, each testing the value's    *)
(* class; a body reached only by `invoke` is no row. A pair of enrolled    *)
(* methods ambiguous over classes of S, with no enrolled method more       *)
(* specific than both covering them, rejects the callable at compile time  *)
(* (Base.isambiguous).                                                     *)
(*                                                                         *)
(* THE CLAIM. For every class that may reach the call, the entry runs the  *)
(* method Julia selects (NoWrongMethod), traps only where Julia has no     *)
(* method (TrapOnlyWhenNoMethod), and rejects only where Julia would find  *)
(* a call over S ambiguous (RejectOnlyWhenAmbiguous). Broken variants,     *)
(* each code WT had: a method enrolled only when its parameter type        *)
(* contains S (SubsetRule, batch 75); rows in program order (ProgramOrder);*)
(* rows ordered by their specialized types, ties in program order          *)
(* (SpecOrder, batch 78: two methods at one specialization tie, A6C2);     *)
(* invoke-only bodies as rows (IncludeInvoke, with SpecOrder: native 12,   *)
(* wasm 22); an ambiguity run as the first row (IgnoreAmbig: native        *)
(* MethodError, wasm 1, A6C3); a method with static parameters given no    *)
(* row (SkipParametric: native 1, wasm 2, A6C1).                           *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Classes and methods are opaque; a method's   *)
(* parameter type is the set of classes it admits; specificity is a       *)
(* strict partial order consistent with set inclusion; one dispatch        *)
(* position; a row's specialization is the classes it admits.             *)
(*                                                                         *)
(* formal(src/codegen/trimcollect.jl _dynamic_dispatch_candidate_mis): a   *)
(* dynamic call enrolls, for every class that may reach it, the body Julia *)
(* selects, and rejects where Julia's selection is ambiguous.              *)
(*                                                                         *)
(* parity(quarantine: Julia selects among a callable's methods by          *)
(* specificity on its arguments' runtime classes; a dart closure has one   *)
(* body, whose argument types its dynamic call checks.)                    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Classes, Methods, Callables,
          Owner,        \* [Methods -> Callables]
          Param,        \* [Methods -> SUBSET Classes]
          More,         \* SUBSET (Methods \X Methods): <<m, n>> = m is more specific than n
          POrd,         \* [Methods -> Nat]: program order
          Parametric,   \* SUBSET Methods: methods with static parameters
          InvokeRows,   \* SUBSET (Methods \X SUBSET Classes): bodies reached only by invoke
          Statics,      \* SUBSET (SUBSET Classes): the call sites' static types
          SubsetRule, ProgramOrder, SpecOrder, IncludeInvoke, IgnoreAmbig, SkipParametric

VARIABLES f, s, v, outcome, done
vars == <<f, s, v, outcome, done>>
Trap == "trap"
Ambig == "ambiguous"
Reject == "reject"

Of(c) == {m \in Methods : Owner[m] = c}

\* Julia's selection for class x over callable g
Julia(g, x) == LET ms == {m \in Of(g) : x \in Param[m]} IN
               IF ms = {} THEN Trap
               ELSE IF \E m \in ms : \A n \in ms \ {m} : <<m, n>> \in More
                    THEN CHOOSE m \in ms : \A n \in ms \ {m} : <<m, n>> \in More
                    ELSE Ambig

\* the rows WT builds for a call of g at static type S
Matched(g, S) == {m \in Of(g) : IF SubsetRule THEN S \subseteq Param[m] ELSE S \cap Param[m] # {}}
Rows(g, S) == {<<m, Param[m] \cap S>> : m \in {x \in Matched(g, S) : ~(SkipParametric /\ x \in Parametric)}}
              \cup (IF IncludeInvoke THEN {r \in InvokeRows : Owner[r[1]] = g} ELSE {})

\* row r is tried before row q
Before(r, q) == IF ProgramOrder THEN POrd[r[1]] < POrd[q[1]]
                ELSE IF SpecOrder THEN (r[2] \subseteq q[2] /\ r[2] # q[2]) \/ (r[2] = q[2] /\ POrd[r[1]] < POrd[q[1]])
                ELSE <<r[1], q[1]>> \in More \/
                     (<<q[1], r[1]>> \notin More /\ POrd[r[1]] < POrd[q[1]])

\* the compile-time ambiguity check: two enrolled methods, neither more specific, whose
\* overlap within S no enrolled method more specific than both covers
AmbiguousOver(g, S) ==
    LET ms == {r[1] : r \in Rows(g, S)} IN
    \E m, n \in ms : m # n /\ <<m, n>> \notin More /\ <<n, m>> \notin More /\
        LET ov == Param[m] \cap Param[n] \cap S IN
        ov # {} /\ ~\E p \in ms : <<p, m>> \in More /\ <<p, n>> \in More /\ ov \subseteq Param[p]

Entry(g, S, x) ==
    IF ~IgnoreAmbig /\ AmbiguousOver(g, S) THEN Reject
    ELSE LET hit == {r \in Rows(g, S) : x \in r[2]} IN
         IF hit = {} THEN Trap
         ELSE (CHOOSE r \in hit : \A q \in hit \ {r} : ~Before(q, r) /\ (Before(r, q) \/ r[1] = q[1]))[1]

Init == f \in Callables /\ s \in Statics /\ v \in s /\ outcome = Trap /\ done = FALSE
Step == ~done /\ outcome' = Entry(f, s, v) /\ done' = TRUE /\ UNCHANGED <<f, s, v>>
Spec_ == Init /\ [][Step]_vars

TypeOK == outcome \in Methods \cup {Trap, Reject} /\ done \in BOOLEAN
NoWrongMethod == done /\ outcome \in Methods => outcome = Julia(f, v)
TrapOnlyWhenNoMethod == done /\ outcome = Trap => Julia(f, v) = Trap
RejectOnlyWhenAmbiguous == done /\ outcome = Reject => \E x \in s : Julia(f, x) = Ambig
=============================================================================
