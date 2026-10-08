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
(* (Base._methods_by_ftype), at the method's intersection with S; a method *)
(* with static parameters at each tuple of candidates over the positions   *)
(* its static parameters fix, the other positions kept as S has them. A    *)
(* position's candidates are the numbered classes under it and the        *)
(* `Type{X}` of each type object the program holds that it admits (a type  *)
(* object has no numbered class of its own). The entry                     *)
(* tries the rows in the methods' specificity order, each testing the      *)
(* value; a body reached only by `invoke` is no row. A tuple of candidates *)
(* for which Julia's dispatch is ambiguous rejects the callable at compile *)
(* time (WT asks Julia per tuple).                                         *)
(*                                                                         *)
(* THE BOUND. The compile-time check (compile.jl, the vtable pre-pass)     *)
(* takes each two rows whose methods are distinct and Base.isambiguous,    *)
(* and asks Julia over the candidate tuples of their overlap               *)
(* (`ambiguous_class_tuple`, closures.jl). When the product of the         *)
(* overlap's per-position candidate counts exceeds `Bound` (4096 in the    *)
(* code) the pair cannot be asked about: the helper returns `nothing` and  *)
(* the callable rejects whether or not a tuple is ambiguous (Unaskable,    *)
(* A8C8). The helper's other `nothing` answers (an overlap that is not one *)
(* tuple type, a Vararg position, a position with no candidate) are not    *)
(* modeled: overlaps here are sets of pairs whose every element is a       *)
(* candidate. NOT MODELED either: the no-method args-tuple product of      *)
(* `_dynamic_dispatch_candidate_mis` (trimcollect.jl:802), which skips a   *)
(* product past 4096 tuples silently, with no rejection (A11C2, A9C2).     *)
(*                                                                         *)
(* THE CLAIM. For every class that may reach the call, the entry runs the  *)
(* method Julia selects (NoWrongMethod), traps only where Julia has no     *)
(* method (TrapOnlyWhenNoMethod), and rejects only where Julia would find  *)
(* a call over S ambiguous (RejectOnlyWhenAmbiguous), and always rejects   *)
(* past the bound (BoundIsLoud). Today's code past the bound breaks        *)
(* RejectOnlyWhenAmbiguous: it rejects a callable none of whose tuples is  *)
(* ambiguous (the over-rejection A8C8, open on dev/MARCH.md 13.17), which  *)
(* MCEnrollmentBoundOverRejectBroken pins; MCEnrollmentBound checks the    *)
(* claims the code keeps past the bound. Broken variants,                  *)
(* each code WT had: a method enrolled only when its parameter type        *)
(* contains S (SubsetRule, batch 75); rows in program order (ProgramOrder);*)
(* rows ordered by their specialized types, ties in program order          *)
(* (SpecOrder, batch 78: two methods at one specialization tie, A6C2);     *)
(* an ambiguity run as the first row (IgnoreAmbig: native MethodError,     *)
(* wasm 1, A6C3); a method with static parameters given no row             *)
(* (SkipParametric: native 1, wasm 2, A6C1); one whose static parameters   *)
(* two positions fix, rowed one position at a time and so never            *)
(* (PerPosition, batch 82: native 1, wasm 2, A7C1); and ambiguity judged   *)
(* over every type, not the classes that reach the call (AllTypesAmbig,    *)
(* batch 82: a program Julia runs rejected, A7C4); and candidates taken     *)
(* from the numbered classes alone, so a `Type{X}` position had none        *)
(* (ClassesOnly, batch 87: an ambiguity ran a row, native -7, wasm 1, and a *)
(* parametric method fixed by a `Type{X}` had no row, native 1, wasm 2,    *)
(* A8C1, A8C2); and a type object a candidate only where the static type   *)
(* is its `Type{X}` (StaticOnly, batch 91: one reaching an erased position  *)
(* found its parametric method without a row, native 1, wasm 2, A9C1); and *)
(* a type object a candidate only when the program holds it as a literal   *)
(* or a constant (LiteralsOnly, batch 99: one a `typeof` made found its    *)
(* parametric method without a row, native 1, wasm 2, A10C1). One Broken  *)
(* variant is a mistake the code could make, not code it had: a pair past  *)
(* the bound read as having no ambiguous tuple, as a `false` answer would  *)
(* be (BoundAccepts: an ambiguity in that overlap runs a row).             *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Classes and methods are opaque; a method's   *)
(* parameter type is the set of classes it admits; specificity is a       *)
(* strict partial order; two dispatch positions, a value a pair of         *)
(* elements; a row's specialization is the pairs it admits; `PFix[m]` is   *)
(* the positions a method's static parameters mention, which a candidate   *)
(* must fix for it to be one signature; an element outside `Numbered` is a *)
(* type object, a candidate only as the dispatch type `Type{X}`, held as a *)
(* literal (`Literals`) or made by a `typeof` of a value of its class.     *)
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

CONSTANTS X, Numbered, Methods, Callables,
          Owner,        \* [Methods -> Callables]
          Param,        \* [Methods -> SUBSET (X \X X)]
          More,         \* SUBSET (Methods \X Methods): <<m, n>> = m is more specific than n
          POrd,         \* [Methods -> Nat]: program order
          PFix,         \* [Methods -> SUBSET {1, 2}]: positions its static parameters mention
          Statics,      \* SUBSET (SUBSET (X \X X)): the pairs (classes, type objects) a call site's static type admits
          SubsetRule, ProgramOrder, SpecOrder, IgnoreAmbig, SkipParametric, PerPosition, AllTypesAmbig,
          Literals,     \* SUBSET X: the type objects the program holds as literals (the rest a `typeof` makes)
          ClassesOnly, StaticOnly, LiteralsOnly,
          Bound,        \* Nat: the most candidate tuples one overlap is asked about (4096)
          BoundAccepts

Values == X \X X
VARIABLES f, s, v, outcome, done
vars == <<f, s, v, outcome, done>>
Trap == "trap"
Ambig == "ambiguous"
Reject == "reject"

Of(c) == {m \in Methods : Owner[m] = c}

\* Julia's selection for the pair x over callable g
Julia(g, x) == LET ms == {m \in Of(g) : x \in Param[m]} IN
               IF ms = {} THEN Trap
               ELSE IF \E m \in ms : \A n \in ms \ {m} : <<m, n>> \in More
                    THEN CHOOSE m \in ms : \A n \in ms \ {m} : <<m, n>> \in More
                    ELSE Ambig

\* the rows WT builds for a call of g at static type S
Matched(g, S) == {m \in Of(g) : IF SubsetRule THEN S \subseteq Param[m] ELSE S \cap Param[m] # {}}
\* a candidate of S: a numbered class, or a type object the program holds (every element outside
\* Numbered here); under ClassesOnly (broken) only a numbered class; under StaticOnly (broken,
\* batch 91) a type object only where S's elements at that position are that one type object
Proj(S, p) == {u[p] : u \in S}
\* under LiteralsOnly (broken, before batch 99) only a type object held as a literal or constant
Cand(t, ps, S) == \A p \in ps : t[p] \in Numbered \/
                    (~ClassesOnly /\ (~LiteralsOnly \/ t[p] \in Literals) /\
                     (~StaticOnly \/ Proj(S, p) = {t[p]}))
RowsOf(m, S) == IF PFix[m] = {} THEN {<<m, Param[m] \cap S>>}
                ELSE IF SkipParametric \/ (PerPosition /\ Cardinality(PFix[m]) = 2) THEN {}
                ELSE {<<m, {u \in Param[m] \cap S : \A p \in PFix[m] : u[p] = t[p]}>> :
                      t \in {x \in Param[m] \cap S : Cand(x, PFix[m], S)}}
Rows(g, S) == UNION {RowsOf(m, S) : m \in Matched(g, S)}

\* row r is tried before row q
Before(r, q) == IF ProgramOrder THEN POrd[r[1]] < POrd[q[1]]
                ELSE IF SpecOrder THEN (r[2] \subseteq q[2] /\ r[2] # q[2]) \/ (r[2] = q[2] /\ POrd[r[1]] < POrd[q[1]])
                ELSE <<r[1], q[1]>> \in More \/
                     (<<q[1], r[1]>> \notin More /\ POrd[r[1]] < POrd[q[1]])

\* two methods neither more specific, whose overlap anywhere no method more specific than
\* both covers (Base.isambiguous)
IsAmbiguous(g, m, n) ==
    m # n /\ <<m, n>> \notin More /\ <<n, m>> \notin More /\
    LET ov == Param[m] \cap Param[n] IN
    ov # {} /\ ~\E p \in Of(g) : <<p, m>> \in More /\ <<p, n>> \in More /\ ov \subseteq Param[p]

\* the pairs of rows the check asks about (compile.jl): distinct methods, Base.isambiguous,
\* their specializations overlapping (typeintersect not Union{})
AmbigPairs(g, S) == {pr \in Rows(g, S) \X Rows(g, S) :
                       pr[1][1] # pr[2][1] /\ IsAmbiguous(g, pr[1][1], pr[2][1]) /\
                       pr[1][2] \cap pr[2][2] # {}}
Overlap(pr) == pr[1][2] \cap pr[2][2]
\* the number of candidate tuples of an overlap: the product of its positions' candidate
\* counts (`prod(length, choices)`, closures.jl); a position's candidates are the elements
\* the overlap admits there, each a numbered class or a type object the program holds
Width(ov) == Cardinality(Proj(ov, 1)) * Cardinality(Proj(ov, 2))
\* an ambiguous pair whose overlap has more candidate tuples than the check asks about:
\* ambiguous_class_tuple returns `nothing` (A8C8)
Unaskable(g, S) == \E pr \in AmbigPairs(g, S) : Width(Overlap(pr)) > Bound

\* the compile-time ambiguity check: for each pair within the bound, WT asks Julia's dispatch
\* for each tuple of candidates of the overlap (the closed world numbers every class a value
\* can have, and more: MARCH 13.17, A3S3); a pair past the bound is not asked (Unaskable, which
\* Entry rejects; BoundAccepts, broken, reads it as no ambiguity); the rule before
\* (AllTypesAmbig) took Base.isambiguous over every type
AmbiguousOver(g, S) ==
    IF AllTypesAmbig
    THEN \E m, n \in Of(g) : IsAmbiguous(g, m, n)
    ELSE \E pr \in AmbigPairs(g, S) : Width(Overlap(pr)) <= Bound /\
             \E x \in Overlap(pr) : Cand(x, {1, 2}, S) /\ Julia(g, x) = Ambig

Entry(g, S, x) ==
    IF ~IgnoreAmbig /\ (AmbiguousOver(g, S) \/ (~BoundAccepts /\ Unaskable(g, S))) THEN Reject
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
BoundIsLoud == done /\ Unaskable(f, s) => outcome = Reject
=============================================================================
