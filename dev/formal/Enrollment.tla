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
(* position's candidates are the classes of the one class set under it    *)
(* and the `Type{X}` of each type object the program holds that it admits  *)
(* (a type object has no numbered class of its own). The entry             *)
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
(* candidate. The candidate product of an enrollment shares the bound: a   *)
(* method with static parameters is enrolled at each tuple of candidates   *)
(* over the positions they mention, and past `Bound` tuples the call       *)
(* rejects (ProductPast, `_candidate_product`, trimcollect.jl), as the     *)
(* no-method args-tuple product of the same call does.                     *)
(*                                                                         *)
(* ONE CLASS SET. Every candidate is read from one set, the classes a      *)
(* value of the closed world may have and the type objects it holds        *)
(* (`closed_world_classes`, trimcollect.jl): the enrollment, the no-method *)
(* record and the ambiguity search read it, and the numbering numbers it.  *)
(* `Unreached` are classes the numbering names that no value has (a type   *)
(* a field is typed by, never allocated). A search that asks about them    *)
(* (AskNumbered, A7C4: native 3, rejected) rejects a program Julia runs.   *)
(* `Unseen` are classes a value has that no statement of the program makes *)
(* (a vararg method's packed tuple, which WT rebuilds from its flattened   *)
(* parameters): the set observes them from the body's slot (SlotsObserved),*)
(* and a value of one reaches the call as any other value does. A set      *)
(* without them (SlotsObserved = FALSE, broken) gives a parametric method  *)
(* no row for that value: a trap where Julia runs the method. Both are     *)
(* definitions an instance's cfg overrides (MCEnrollmentUnseen).           *)
(* A MATCH is one signature (`_match_is_one_signature`, trimcollect.jl)    *)
(* when a static parameter it leaves a TypeVar is mentioned only where the *)
(* argument is one value's dispatch type (a concrete class that is not a   *)
(* kind, or a `Type{X}`): Julia leaves that TypeVar unbound at run time    *)
(* too (`h(x::Union{T,Nothing}) where T` at Nothing). `NoFix[m]` is the    *)
(* elements where m's match leaves one at an argument that is no value's   *)
(* dispatch type, a kind facing `Type{S}` or an abstract argument: there   *)
(* Julia fixes it per value (a type object's own `Type{X}` candidate, a    *)
(* class's own row), and a body built at the element cannot be compiled.   *)
(* A match rule without that check (NoTypeVarCheck, A9C6) builds that body *)
(* and rejects where Julia answers.                                        *)
(*                                                                         *)
(* THE CLAIM. For every class that may reach the call, the entry runs the  *)
(* method Julia selects (NoWrongMethod), traps only where Julia has no     *)
(* method (TrapOnlyWhenNoMethod), and rejects only where Julia would find  *)
(* a call over S ambiguous (RejectOnlyWhenAmbiguous), and always rejects   *)
(* past the bound (BoundIsLoud; ProductBoundIsLoud for an enrollment's     *)
(* product, which MCEnrollmentProduct checks beside the bound's other      *)
(* claims). BoundIsLoud and RejectOnlyWhenAmbiguous cannot both hold at    *)
(* the bound: over a pair past the bound whose overlap holds no ambiguous  *)
(* tuple, BoundIsLoud requires a rejection and RejectOnlyWhenAmbiguous     *)
(* forbids one, so no entry keeps both there. BoundIsLoud is the code's    *)
(* rule (loud where it cannot ask), RejectOnlyWhenAmbiguous Julia's.       *)
(* Today's code keeps BoundIsLoud and so breaks RejectOnlyWhenAmbiguous    *)
(* past the bound: it rejects a callable none of whose tuples is ambiguous *)
(* (the over-rejection A8C8, open on dev/MARCH.md 13.17), which            *)
(* MCEnrollmentBoundOverRejectBroken pins; MCEnrollmentBound checks the    *)
(* claims the code keeps past the bound. Fixing A8C8 alone does not make   *)
(* that instance positive: the fix must also restate the bound's claim as  *)
(* Julia requires it (past the bound, no row runs where Julia answers      *)
(* Ambig), or retire BoundIsLoud with the bound. Broken variants, each     *)
(* code WT had: a method enrolled only when its parameter type contains S  *)
(* (SubsetRule, batch 75); rows in program order (ProgramOrder); rows      *)
(* ordered by their specialized types, ties in program order (SpecOrder,   *)
(* batch 78: two methods at one specialization tie, A6C2); an ambiguity    *)
(* run as the first row (IgnoreAmbig: native MethodError, wasm 1, A6C3); a *)
(* method with static parameters given no row (SkipParametric: native 1,   *)
(* wasm 2, A6C1); one whose static parameters two positions fix, rowed one *)
(* position at a time and so never (PerPosition, batch 82: native 1, wasm  *)
(* 2, A7C1); and ambiguity judged over every type, not the classes that    *)
(* reach the call (AllTypesAmbig, batch 82: a program Julia runs rejected, *)
(* A7C4); and candidates taken from the numbered classes alone, so a       *)
(* `Type{X}` position had none (ClassesOnly, batch 87: an ambiguity ran a  *)
(* row, native -7, wasm 1, and a parametric method fixed by a `Type{X}`    *)
(* had no row, native 1, wasm 2, A8C1, A8C2); and a type object a          *)
(* candidate only where the static type is its `Type{X}` (StaticOnly,      *)
(* batch 91: one reaching an erased position found its parametric method   *)
(* without a row, native 1, wasm 2, A9C1); and a type object a candidate   *)
(* only when the program holds it as a literal or a constant               *)
(* (LiteralsOnly, batch 99: one a `typeof` made found its parametric       *)
(* method without a row, native 1, wasm 2, A10C1). One Broken variant is a *)
(* mistake the code could make, not code it had: a pair past the bound     *)
(* read as having no ambiguous tuple, as a `false` answer would be         *)
(* (BoundAccepts: an ambiguity in that overlap runs a row). Three more:    *)
(* an ambiguity asked about a numbered class no value has (AskNumbered,    *)
(* A7C4: native 3, rejected); a match taken as one signature with a static *)
(* parameter left a TypeVar (NoTypeVarCheck, A9C6: native 1, rejected);    *)
(* and an enrollment product past the bound enumerated rather than         *)
(* rejected (ProductUnbounded, A9C2).                                      *)
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
          Bound,        \* Nat: the most candidate tuples one overlap is asked about, or one product enrolls (4096)
          BoundAccepts,
          Unreached,    \* SUBSET X: numbered classes no value has (outside the one class set)
          AskNumbered,  \* BOOLEAN: the ambiguity search reads the numbered classes, not the one set (broken)
          NoFix,        \* [Methods -> SUBSET X]: elements at which a method's match leaves a static parameter a TypeVar
          NoTypeVarCheck, \* BOOLEAN: a match is one signature without the TypeVar check (broken)
          ProductUnbounded \* BOOLEAN: an enrollment product past Bound is enumerated, not rejected (broken)

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

\* the classes a value has that no statement makes, and whether the set observes them
Unseen == {}
SlotsObserved == TRUE
\* a value may have the pair x: every element but the numbered classes no value has
Reaches(x) == x[1] \notin Unreached /\ x[2] \notin Unreached
\* the one class set: every element a value may have (SlotsObserved, broken: but the unseen)
InSet(x) == Reaches(x) /\ (SlotsObserved \/ (x[1] \notin Unseen /\ x[2] \notin Unseen))
\* x is a value's dispatch type for g: no method's match at x leaves a static parameter a TypeVar
IsValue(g, x) == ~\E m \in Of(g) : \E p \in PFix[m] : x[p] \in NoFix[m]
\* a match of m at x is one signature: every static parameter m mentions has a value
OneSig(m, x) == \A p \in PFix[m] : x[p] \notin NoFix[m]

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
\* a method's candidate tuples: the elements it admits, each a candidate of the one class set
Cands(m, S) == {x \in Param[m] \cap S : Cand(x, PFix[m], S) /\ InSet(x)}
RowsOf(m, S) == IF PFix[m] = {} THEN {<<m, Param[m] \cap S>>}
                ELSE IF SkipParametric \/ (PerPosition /\ Cardinality(PFix[m]) = 2) THEN {}
                ELSE {<<m, {u \in Param[m] \cap S : \A p \in PFix[m] : u[p] = t[p]}>> :
                      t \in {x \in Cands(m, S) : OneSig(m, x)}}
Rows(g, S) == UNION {RowsOf(m, S) : m \in Matched(g, S)}
\* a body built at a match that leaves a static parameter a TypeVar (NoTypeVarCheck, broken):
\* it cannot be compiled, and the callable rejects
TypeVarRows(g, S) == NoTypeVarCheck /\ ~SkipParametric /\
    \E m \in Matched(g, S) : PFix[m] # {} /\ \E x \in Cands(m, S) : ~OneSig(m, x)
\* the number of candidate tuples a method's enrollment enumerates: the product of its
\* candidate counts over the positions its static parameters mention (`prod(length, choices)`)
PWidth(m, S) == (IF 1 \in PFix[m] THEN Cardinality({x[1] : x \in Cands(m, S)}) ELSE 1) *
                (IF 2 \in PFix[m] THEN Cardinality({x[2] : x \in Cands(m, S)}) ELSE 1)
\* an enrollment product past the bound: the call rejects (`_candidate_product`)
ProductPast(g, S) == \E m \in Matched(g, S) : PFix[m] # {} /\ PWidth(m, S) > Bound

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
\* the tuples of an overlap the search asks about: those of the one class set (AskNumbered,
\* broken: every numbered class too)
Asked(ov) == {x \in ov : AskNumbered \/ InSet(x)}
\* the number of candidate tuples of an overlap: the product of its positions' candidate
\* counts (`prod(length, choices)`, closures.jl); a position's candidates are the elements
\* the overlap admits there, each a numbered class or a type object the program holds
Width(ov) == Cardinality(Proj(ov, 1)) * Cardinality(Proj(ov, 2))
\* an ambiguous pair whose overlap has more candidate tuples than the check asks about:
\* ambiguous_class_tuple returns `nothing` (A8C8)
Unaskable(g, S) == \E pr \in AmbigPairs(g, S) : Width(Asked(Overlap(pr))) > Bound

\* the compile-time ambiguity check: for each pair within the bound, WT asks Julia's dispatch
\* for each tuple of candidates of the overlap the one class set holds (AskNumbered, broken:
\* every numbered class, A7C4); a pair past the bound is not asked (Unaskable, which
\* Entry rejects; BoundAccepts, broken, reads it as no ambiguity); the rule before
\* (AllTypesAmbig) took Base.isambiguous over every type
AmbiguousOver(g, S) ==
    IF AllTypesAmbig
    THEN \E m, n \in Of(g) : IsAmbiguous(g, m, n)
    ELSE \E pr \in AmbigPairs(g, S) : Width(Asked(Overlap(pr))) <= Bound /\
             \E x \in Asked(Overlap(pr)) : Cand(x, {1, 2}, S) /\ Julia(g, x) = Ambig

Entry(g, S, x) ==
    IF ~IgnoreAmbig /\ (AmbiguousOver(g, S) \/ (~BoundAccepts /\ Unaskable(g, S)) \/
                        (~ProductUnbounded /\ ProductPast(g, S)) \/ TypeVarRows(g, S)) THEN Reject
    ELSE LET hit == {r \in Rows(g, S) : x \in r[2]} IN
         IF hit = {} THEN Trap
         ELSE (CHOOSE r \in hit : \A q \in hit \ {r} : ~Before(q, r) /\ (Before(r, q) \/ r[1] = q[1]))[1]

\* the value that reaches the call: any pair a value may have, a dispatch type for f
Init == f \in Callables /\ s \in Statics /\ v \in {x \in s : Reaches(x) /\ IsValue(f, x)} /\
        outcome = Trap /\ done = FALSE
Step == ~done /\ outcome' = Entry(f, s, v) /\ done' = TRUE /\ UNCHANGED <<f, s, v>>
Terminal == done /\ UNCHANGED vars   \* the one step has run: the end of the run, not a deadlock
Spec_ == Init /\ [][Step \/ Terminal]_vars

TypeOK == outcome \in Methods \cup {Trap, Reject} /\ done \in BOOLEAN
NoWrongMethod == done /\ outcome \in Methods => outcome = Julia(f, v)
TrapOnlyWhenNoMethod == done /\ outcome = Trap => Julia(f, v) = Trap
RejectOnlyWhenAmbiguous == done /\ outcome = Reject =>
    \E x \in s : Reaches(x) /\ IsValue(f, x) /\ Julia(f, x) = Ambig
BoundIsLoud == done /\ Unaskable(f, s) => outcome = Reject
\* past the bound an enrollment's candidate product rejects the call, never enumerated
\* (ProductUnbounded, broken) or dropped silently
ProductBoundIsLoud == done /\ ProductPast(f, s) => outcome = Reject
=============================================================================
