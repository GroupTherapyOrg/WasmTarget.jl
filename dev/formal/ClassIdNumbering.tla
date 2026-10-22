--------------------------- MODULE ClassIdNumbering ---------------------------
(***************************************************************************)
(* A TLA+ model of dart2wasm's class-id numbering, the one numbering of the  *)
(* closed world (dev/MARCH.md 1.C):                                          *)
(*   parity(class_info.dart:864 ClassIdNumbering._number)                    *)
(*   parity(class_info.dart:831 ClassIdNumbering.getConcreteClassIdRange)    *)
(* ported onto Julia's type graph, which Julia itself answers (ledger D3):   *)
(* each class's parent is Julia's `supertype`, the root is `Any`.            *)
(*                                                                           *)
(* WHAT dart DOES.  One depth-first pre-order walk from the root.  Its `pre` *)
(* gives a concrete class the next concrete id (from 1; 0 is the artificial  *)
(* top class) and an abstract class the next abstract id (from one past the  *)
(* last concrete id, `nextAbstractClassId = 1 + concreteClassCount`), and    *)
(* returns the concrete counter as it stood; its `post` writes the class's  *)
(* range [first, next concrete id - 1], the concrete ids of its subtree.     *)
(* Siblings are visited in the program's order (dart's component order: its *)
(* libraries, then each library's classes), the root's children sorted by a  *)
(* fixed preference first (`order`, class_info.dart:930), a stable sort.    *)
(*                                                                           *)
(* HOW JULIA DIFFERS, AND WHY THE MODEL HOLDS IT.  Julia has single          *)
(* inheritance and no interfaces, so dart's `implementors` are empty and a  *)
(* class's ranges are its subtree's one range; a concrete Julia type has no  *)
(* subtypes, so every class with a child is abstract; an abstract type may   *)
(* have no concrete subtype in the closed world (a field typed `Real` that  *)
(* holds nothing), its range then empty, as dart's may be.  The sibling     *)
(* order is an input: `ord`                                                  *)
(* ranks every class (the order the closed world's walk first meets it, the  *)
(* root's preferred children first); the model checks every order, so the   *)
(* claims hold for whichever order the port takes, and the ids are a pure    *)
(* function of the tree and the order (the closed form below).               *)
(*                                                                           *)
(* The walk is stepwise with an explicit stack, one frame per abstract class *)
(* ([node, first, pend]), as dart's recursive `dfs`: a concrete child takes  *)
(* its id and its one-id range at once (its `pre` and `post` with no child   *)
(* between); an abstract child takes its id and opens a frame; a frame with  *)
(* no child left writes its range and closes.                                *)
(*                                                                           *)
(* Broken variants: `RangeOffByOne` writes a range's end as the concrete     *)
(* counter itself, not one less (TLC must report RangeIsa violated);         *)
(* `SharedCounter` gives an abstract class the concrete counter's next id,   *)
(* one counter for both (TLC must report ConcreteDense violated).            *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, Sequences

CONSTANTS
    N,              \* classes are 1..N; 0 is the root, `Any`
    RangeOffByOne,  \* Broken: a range ends at the concrete counter, not one before it
    SharedCounter   \* Broken: abstract classes draw from the concrete counter

Root    == 0
Classes == 1..N
Types   == 0..N

VARIABLES
    parent,     \* [Classes -> Types], parent[c] < c : Julia's supertype
    abs,        \* SUBSET Classes : the abstract classes but the root (every class with a child)
    ord,        \* [Classes -> 1..N], a bijection : the sibling order (program order)
    phase,      \* "walk" -> "done"
    stack,      \* the walk's frames <<[node, first, pend]>>
    nextConc,   \* nextConcreteClassId
    nextAbs,    \* nextAbstractClassId
    ids,        \* [Types -> Nat] : classIds (0 = not yet numbered)
    ranges      \* [Types -> <<>> | <<lo, hi>>] : concreteSubclassRanges

vars == <<parent, abs, ord, phase, stack, nextConc, nextAbs, ids, ranges>>

----------------------------------------------------------------------------
(* The hierarchy and the order. *)

Kids(n)  == {c \in Classes : parent[c] = n}
Concrete == Classes \ abs
Abstract == Types \ Concrete

RECURSIVE Anc(_)
Anc(c) == IF c = Root THEN {} ELSE {parent[c]} \cup Anc(parent[c])
Sub(a, b) == a = b \/ b \in Anc(a)          \* a <: b

Perms(S) == {f \in [S -> 1..Cardinality(S)] : \A i, j \in S : i # j => f[i] # f[j]}

MinOrd(S) == CHOOSE x \in S : \A y \in S : ord[x] <= ord[y]
RECURSIVE ByOrd(_)
ByOrd(S) == IF S = {} THEN <<>> ELSE <<MinOrd(S)>> \o ByOrd(S \ {MinOrd(S)})

C == Cardinality(Concrete)

----------------------------------------------------------------------------
(* The closed form: with siblings in `ord`, a concrete class's id is its rank *)
(* among the concrete classes in pre-order, an abstract class's C plus its   *)
(* rank among the abstract classes in pre-order; pre-order is lexicographic  *)
(* order of the root paths, each step keyed by `ord`.                        *)
RECURSIVE Path(_)
Path(c) == IF c = Root THEN <<>> ELSE Append(Path(parent[c]), ord[c])

RECURSIVE LexLess(_, _)
LexLess(p, q) == IF p = <<>> THEN q # <<>>
                 ELSE IF q = <<>> THEN FALSE
                 ELSE IF Head(p) < Head(q) THEN TRUE
                 ELSE IF Head(p) > Head(q) THEN FALSE
                 ELSE LexLess(Tail(p), Tail(q))

Before(S, c) == Cardinality({d \in S : LexLess(Path(d), Path(c))})
ClosedForm == [t \in Types |-> IF t \in Concrete THEN 1 + Before(Concrete, t)
                               ELSE C + 1 + Before(Abstract, t)]

----------------------------------------------------------------------------
(* The walk. *)

Init ==
    /\ parent \in {p \in [Classes -> Types] : \A c \in Classes : p[c] < c}
    /\ abs \in {a \in SUBSET Classes : \A c \in Classes : (\E d \in Classes : parent[d] = c) => c \in a}
    /\ ord \in Perms(Classes)
    /\ phase = "walk"
    \* the root's `pre`: Any is abstract, its id the first abstract id
    /\ nextConc = 1
    /\ nextAbs = C + 2
    /\ ids = [t \in Types |-> IF t = Root THEN C + 1 ELSE 0]
    /\ ranges = [t \in Types |-> <<>>]
    /\ stack = <<[node |-> Root, first |-> 1, pend |-> ByOrd(Kids(Root))]>>

\* the range dart's `post` writes from the class's first concrete id
RangeFrom(first) == LET hi == IF RangeOffByOne THEN nextConc ELSE nextConc - 1
                    IN IF first <= hi THEN <<first, hi>> ELSE <<>>

Top == stack[Len(stack)]

\* the next child of the innermost open class: its `pre` (and a concrete one's `post`)
Visit ==
    /\ phase = "walk"
    /\ stack # <<>>
    /\ Top.pend # <<>>
    /\ LET c == Head(Top.pend)
           rest == [Top EXCEPT !.pend = Tail(Top.pend)]
       IN IF c \in Concrete
          THEN /\ ids' = [ids EXCEPT ![c] = nextConc]
               /\ ranges' = [ranges EXCEPT ![c] = <<nextConc, nextConc>>]
               /\ nextConc' = nextConc + 1
               /\ stack' = [stack EXCEPT ![Len(stack)] = rest]
               /\ UNCHANGED nextAbs
          ELSE /\ ids' = [ids EXCEPT ![c] = IF SharedCounter THEN nextConc ELSE nextAbs]
               /\ IF SharedCounter
                  THEN nextConc' = nextConc + 1 /\ UNCHANGED nextAbs
                  ELSE nextAbs' = nextAbs + 1 /\ UNCHANGED nextConc
               /\ stack' = Append([stack EXCEPT ![Len(stack)] = rest],
                                  [node |-> c, first |-> IF SharedCounter THEN nextConc + 1 ELSE nextConc,
                                   pend |-> ByOrd(Kids(c))])
               /\ UNCHANGED ranges
    /\ UNCHANGED <<parent, abs, ord, phase>>

\* a class with no child left: its `post`
Close ==
    /\ phase = "walk"
    /\ stack # <<>>
    /\ Top.pend = <<>>
    /\ ranges' = [ranges EXCEPT ![Top.node] = RangeFrom(Top.first)]
    /\ stack' = SubSeq(stack, 1, Len(stack) - 1)
    /\ phase' = IF Len(stack) = 1 THEN "done" ELSE "walk"
    /\ UNCHANGED <<parent, abs, ord, nextConc, nextAbs, ids>>

Done == phase = "done" /\ UNCHANGED vars

Next == Visit \/ Close \/ Done
Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* The claims, each of the finished numbering. *)

TypeOK ==
    /\ phase \in {"walk", "done"}
    /\ nextConc \in 1..(N + 2)
    /\ ids \in [Types -> 0..(2 * N + 2)]

\* the concrete classes hold exactly the ids 1..C, one each
ConcreteDense ==
    phase = "done" =>
        /\ {ids[c] : c \in Concrete} = 1..C
        /\ \A c, d \in Concrete : c # d => ids[c] # ids[d]

\* the abstract classes, the root among them, hold the ids after the concrete ones, one each
AbstractAfter ==
    phase = "done" =>
        /\ {ids[a] : a \in Abstract} = (C + 1)..(C + Cardinality(Abstract))
        /\ \A a, b \in Abstract : a # b => ids[a] # ids[b]

\* a class's range holds a concrete class's id exactly when that class is its subtype: the
\* range a type test reads (getConcreteClassIdRange, Julia's implementors being empty)
RangeIsa ==
    phase = "done" =>
        \A t \in Types : \A c \in Concrete :
            (Sub(c, t) <=> (ranges[t] # <<>> /\ ranges[t][1] <= ids[c] /\ ids[c] <= ranges[t][2]))

\* the ids are the closed form's: a pure function of the tree and the sibling order
Determinism == phase = "done" => ids = ClosedForm

=============================================================================
