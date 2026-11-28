-------------------------- MODULE ConstantHash --------------------------------
(***************************************************************************)
(* A TLA+ model of the constant caches' key hash: a literal of the NIR       *)
(* (NirConst) keys constants.jl's constantInfo and valueTypeConstants, so    *)
(* its hash must agree with ===, cost what === costs, and never change while *)
(* it is a key. src/julia/nir.jl:                                            *)
(*   Base.hash(c::NirConst, h) = _bounded_hash(c.c.val, h, Ref(64))          *)
(*   _bounded_hash: a value Julia stores flat, a String, Symbol or Type is   *)
(*     hashed itself; a mutable object by its address (objectid); a          *)
(*     structured immutable by its type, then its fields depth first, in     *)
(*     field order, while the budget of visited values lasts.                *)
(*                                                                           *)
(* Julia's === (egal): a flat value by its bits, a mutable object by its     *)
(* identity, an immutable by its type and its fields' ===, recursively. It   *)
(* stops at a mutable object, so it is linear on any sharing; Julia's own    *)
(* objectid of an immutable walks every path (2^40 on a 40-level DAG), the   *)
(* reason for the bound (A51S13, A55S5).                                     *)
(*                                                                           *)
(* ABSTRACTION. A value is a node of a fixed universe: a flat leaf (its      *)
(* label), a mutable cell (its identity; its contents a VARIABLE that a      *)
(* Mutate step rewrites, the cell able to hold itself), or an immutable      *)
(* (its type and its ordered children, a DAG with sharing: Chain3 visits 15  *)
(* nodes when every path is walked). A hash is the exact sequence of tokens *)
(* the walk emits, so two hashes are equal only when the walks agree: the   *)
(* model checks the walk, not a mixing function.                            *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   AgreesWithEgal  x === y implies hash x = hash y                         *)
(*   Bounded         every walk visits at most Budget values                 *)
(*   StableKeys      no Mutate step changes any key's hash                   *)
(*   FirstValuesTell two same-type literals whose first values differ hash   *)
(*                   apart (no type-only hash: N of them would collide and   *)
(*                   make the cache quadratic)                               *)
(* Broken variants (MC*Broken.cfg): Unbounded (no budget: Bounded fails on   *)
(* Chain3), MutByContent (a mutable cell hashed by its contents:             *)
(* StableKeys fails after a Mutate), TypeOnly (a structured immutable hashed *)
(* by its type alone: FirstValuesTell fails).                                *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Budget,         \* the walk's budget of visited values (64 in nir.jl)
    Unbounded,      \* Broken: the walk ignores the budget
    MutByContent,   \* Broken: a mutable cell is hashed by its contents
    TypeOnly        \* Broken: a structured immutable is hashed by its type alone

\* the universe: flat leaves, mutable cells, immutables
Leaves == {"La", "Lb"}
Cells  == {"M1", "M2"}
Imms   == {"P", "Pcopy", "Q", "Chain1", "Chain2", "Chain3", "WithCell", "CellFirst"}
Nodes  == Leaves \cup Cells \cup Imms

Label(n) == IF n = "La" THEN "a" ELSE "b"

\* an immutable's type and its ordered fields; Pcopy is a distinct node === to P
ImmType(n) == IF n \in {"Chain1", "Chain2", "Chain3"} THEN "Pair" ELSE
              IF n \in {"WithCell", "CellFirst"} THEN "Holder" ELSE "Pair"
Fields(n) ==
    CASE n = "P"         -> <<"La", "La">>
      [] n = "Pcopy"     -> <<"La", "La">>
      [] n = "Q"         -> <<"Lb", "La">>
      [] n = "Chain1"    -> <<"P", "P">>
      [] n = "Chain2"    -> <<"Chain1", "Chain1">>
      [] n = "Chain3"    -> <<"Chain2", "Chain2">>
      [] n = "WithCell"  -> <<"La", "M1">>
      [] n = "CellFirst" -> <<"M1", "La">>

\* the contents a mutable cell may hold: nothing, a leaf, or itself
CellContents(m) == {<<>>, <<"La">>, <<"Lb">>, <<m>>}

VARIABLES contents, h0
vars == <<contents, h0>>

\* Julia's ===: leaves by label, cells by identity, immutables by type and fields' ===
RECURSIVE Egal(_, _)
Egal(x, y) ==
    IF x \in Leaves \/ y \in Leaves THEN x \in Leaves /\ y \in Leaves /\ Label(x) = Label(y)
    ELSE IF x \in Cells \/ y \in Cells THEN x = y
    ELSE ImmType(x) = ImmType(y) /\ Len(Fields(x)) = Len(Fields(y)) /\
         \A i \in 1..Len(Fields(x)) : Egal(Fields(x)[i], Fields(y)[i])

\* the walk: a stack of values to visit, the budget left, the tokens emitted
RECURSIVE Walk(_, _, _)
Walk(stack, budget, acc) ==
    IF stack = <<>> \/ (~Unbounded /\ budget = 0) THEN acc
    ELSE LET n == Head(stack)
             rest == Tail(stack)
         IN IF n \in Leaves THEN Walk(rest, budget - 1, Append(acc, <<"leaf", Label(n)>>))
            ELSE IF n \in Cells THEN
                 IF MutByContent
                 THEN Walk(contents[n] \o rest, budget - 1, Append(acc, <<"cell", "contents">>))
                 ELSE Walk(rest, budget - 1, Append(acc, <<"cell", n>>))
            ELSE IF TypeOnly THEN Walk(rest, budget - 1, Append(acc, <<"type", ImmType(n)>>))
            ELSE Walk(Fields(n) \o rest, budget - 1, Append(acc, <<"type", ImmType(n)>>))

\* the unbounded walk's budget: past the deepest path count of the universe
Big == 100
Hash(x) == Walk(<<x>>, IF Unbounded THEN Big ELSE Budget, <<>>)

Keys == Cells \cup Imms

TypeOK ==
    /\ \A m \in Cells : contents[m] \in CellContents(m)
    /\ DOMAIN h0 = Keys

Init ==
    /\ contents = [m \in Cells |-> <<>>]
    /\ h0 = [k \in Keys |-> Walk(<<k>>, IF Unbounded THEN Big ELSE Budget, <<>>)]

\* a mutable cell's contents rewritten while the literals holding it are keys
Mutate == \E m \in Cells : \E c \in CellContents(m) :
    /\ c # contents[m]
    /\ contents' = [contents EXCEPT ![m] = c]
    /\ UNCHANGED h0

Next == Mutate \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars

AgreesWithEgal == \A x, y \in Nodes : Egal(x, y) => Hash(x) = Hash(y)
Bounded        == \A x \in Nodes : Len(Hash(x)) <= Budget
StableKeys     == \A k \in Keys : Hash(k) = h0[k]
FirstValuesTell == Hash("P") # Hash("Q")
=============================================================================
