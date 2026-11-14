------------------------ MODULE FieldSelectorTable -------------------------
(***************************************************************************)
(* A TLA+ model of dart's dispatch table over field selectors, as the port   *)
(* of _virtualCall (code_generator.dart:2028) will use it for Julia's field  *)
(* access on a receiver Julia left abstract: DispatchTable.build             *)
(* (dispatch_table.dart:501) collecting each selector's targets by class id, *)
(* merging consecutive ids of one target into ranges (:622), dispatching a   *)
(* selector of one range statically and every other through the table       *)
(* (:688), and buildRowDisplacementTable (:965) packing the rows first-fit;  *)
(* a call reads table[classId + offset] (translator.dart:911                 *)
(* callDispatchTable).                                                       *)
(*                                                                           *)
(* The selector is a field name and its targets are each class's own field   *)
(* getter: a Julia struct inherits no field, so no two classes share a       *)
(* getter. Julia's getfield(x::T, :f) may reach a concrete subtype of T with *)
(* no field f, and Julia throws FieldError there; dart's typing rules that   *)
(* receiver out, so its table has no answer for it. The port gives each such *)
(* class of the receiver's type one shared target, Julia's FieldError throw, *)
(* in the selector's row (identical targets, so dart's merge folds runs of   *)
(* them into one range).                                                     *)
(* precedent(dart: the selector row displacement table; C++: vtables, a     *)
(* method's slot fixed per class).                                           *)
(*                                                                           *)
(* ABSTRACTION. Classes are the class ids 0..N-1, all concrete. Each class   *)
(* has a set of field names (has); each field name has one call site whose   *)
(* receiver type's concrete classes are recv[f] (any nonempty set). The      *)
(* selectors are packed in any order (dart sorts by a weight; the claims     *)
(* hold for every order). A row's first-fit offset is computed in one step:  *)
(* dart's loop increments the offset from firstAvailable - first index until *)
(* every value's slot is free or past the table's end, which is the least    *)
(* such offset. The table grows with null slots as dart's does.              *)
(*                                                                           *)
(* Claims (at the end of packing):                                           *)
(*   SlotUnique        no row is placed over an occupied slot                *)
(*   DispatchExact     a class with the field reaches its own getter         *)
(*   MissingFieldTraps a class of the receiver's type without the field      *)
(*                     reaches Julia's FieldError, never a slot of another   *)
(*                     selector, a null slot or another class's getter       *)
(* Broken variants: NoOverlapCheck (the fit tests only the row's first       *)
(* value: SlotUnique), NoFieldError (only classes with the field get a       *)
(* target, as dart's addMember gives: MissingFieldTraps).                    *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, Sequences

CONSTANTS
    N,               \* classes are the class ids 0..N-1
    Names,           \* the field names, one selector each
    NoOverlapCheck,  \* Broken: a row fits when its first value's slot is free
    NoFieldError     \* Broken: a class without the field gets no target

Classes == 0..(N - 1)
\* every slot value is a pair (class id, name), so TLC compares them: a getter its class and field, the
\* null slot and Julia's FieldError throw each a pair no class has
Get(c, f) == <<c, f>>
Null == <<-1, "null">>
FieldErr == <<-2, "FieldError">>
Targets == {Get(c, f) : c \in Classes, f \in Names} \cup {FieldErr}

Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Max(S) == CHOOSE x \in S : \A y \in S : x >= y

VARIABLES has, recv, table, off, firstAvail, pending, clash, phase
vars == <<has, recv, table, off, firstAvail, pending, clash, phase>>

\* the classes in selector f's row and each one's target
RowClasses(f) == IF NoFieldError THEN {c \in recv[f] : f \in has[c]} ELSE recv[f]
Target(f, c) == IF f \in has[c] THEN Get(c, f) ELSE FieldErr

\* dart's merge: a range starts at a row class whose predecessor id is no row class of the same target
RangeStarts(f) == {c \in RowClasses(f) :
                     ~(c - 1 \in RowClasses(f) /\ Target(f, c - 1) = Target(f, c))}
Static(f) == Cardinality(RangeStarts(f)) = 1
InTable(f) == RowClasses(f) # {} /\ ~Static(f)

Slot(t, i) == IF i >= 0 /\ i < Len(t) THEN t[i + 1] ELSE Null

\* the call of selector f on a receiver of class c: no target is dart's unreachable call (a trap, here
\* Null); one range is a static call of its target; else the table's slot at classId + offset
Call(f, c) ==
    IF RowClasses(f) = {} THEN Null
    ELSE IF Static(f) THEN Target(f, Min(RowClasses(f)))
    ELSE Slot(table, c + off[f])

TypeOK ==
    /\ has \in [Classes -> SUBSET Names]
    /\ recv \in [Names -> (SUBSET Classes) \ {{}}]
    /\ \A i \in 1..Len(table) : table[i] \in Targets \cup {Null}
    /\ off \in [Names -> Int]
    /\ firstAvail \in Nat
    /\ pending \subseteq Names
    /\ clash \in BOOLEAN
    /\ phase \in {"pack", "done"}

Init ==
    /\ has \in [Classes -> SUBSET Names]
    /\ recv \in [Names -> (SUBSET Classes) \ {{}}]
    /\ table = <<>>
    /\ off = [f \in Names |-> 0]
    /\ firstAvail = 0
    /\ pending = {f \in Names : InTable(f)}
    /\ clash = FALSE
    /\ phase = "pack"

\* buildRowDisplacementTable's step for one row: the least fitting offset from firstAvailable - first
\* index, the row's values written, firstAvailable advanced past occupied slots
Pack == \E f \in pending :
    LET vals  == RowClasses(f)
        lo    == Min(vals)
        hi    == Max(vals)
        start == firstAvail - lo
        Fits(o) == IF NoOverlapCheck THEN Slot(table, o + lo) = Null
                   ELSE \A i \in vals : Slot(table, o + i) = Null
        o     == Min({x \in start..(start + Len(table) + N) : Fits(x)})
        len   == IF o + hi + 1 > Len(table) THEN o + hi + 1 ELSE Len(table)
        new   == [i \in 1..len |-> IF (i - 1 - o) \in vals THEN Target(f, i - 1 - o)
                                   ELSE Slot(table, i - 1)]
    IN /\ phase = "pack"
       /\ clash' = (clash \/ \E i \in vals : Slot(table, o + i) # Null)
       /\ table' = new
       /\ off' = [off EXCEPT ![f] = o]
       /\ firstAvail' = Min({k \in firstAvail..len : Slot(new, k) = Null})
       /\ pending' = pending \ {f}
       /\ UNCHANGED <<has, recv, phase>>

Finish ==
    /\ phase = "pack" /\ pending = {}
    /\ phase' = "done"
    /\ UNCHANGED <<has, recv, table, off, firstAvail, pending, clash>>

\* the run ends: its terminal state stutters explicitly
Done == phase = "done" /\ UNCHANGED vars

Next == Pack \/ Finish \/ Done
Spec == Init /\ [][Next]_vars /\ WF_vars(Pack \/ Finish)

SlotUnique == ~clash

DispatchExact == phase = "done" =>
    \A f \in Names : \A c \in recv[f] : f \in has[c] => Call(f, c) = Get(c, f)

MissingFieldTraps == phase = "done" =>
    \A f \in Names : \A c \in recv[f] : f \notin has[c] => Call(f, c) = FieldErr

Ends == <>(phase = "done")
=============================================================================
