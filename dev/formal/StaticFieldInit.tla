------------------------- MODULE StaticFieldInit --------------------------------
(***************************************************************************)
(* A TLA+ model of a lazily initialized static field: dart's lazy arm of     *)
(* DartGlobals.getDefinitionForStaticField (globals.dart:126), its getter    *)
(* (code_generator.dart:4937 StaticFieldImplicitAccessorCodeGenerator.       *)
(* _generateGetter), setter (:4969) and initializer function (:4851          *)
(* StaticFieldInitializerCodeGenerator), as src/globals.jl ports them for a  *)
(* Julia global binding whose image value is a mutable object.               *)
(*   The global starts uninitialized: its flag false (or, for a non-nullable *)
(*   reference, the global itself null). The getter reads the global when    *)
(*   the flag is set, and otherwise calls the initializer, which stores the  *)
(*   binding's value and sets the flag. The setter stores and sets the flag. *)
(*   Julia's answer for the initializer: a fresh copy of the binding's image *)
(*   value (the heap after the top level ran), built with no user code, so   *)
(*   the initializer never reads the field (no read while initializing) and  *)
(*   a binding's value before any write is its image value.                  *)
(* precedent(dart: the lazy static field; rust: LazyLock, its value computed *)
(* on the first read).                                                       *)
(*                                                                           *)
(* ABSTRACTION. One field and the program, single threaded. The program      *)
(* reads or writes one of two values; truth is what Julia's binding holds:   *)
(* the image value until a write, then the last write. At most MaxOps steps. *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   ReadsTruth        every read of a value returns what the binding holds  *)
(*   NoPlaceholderRead a read never returns the uninitialized placeholder    *)
(*   InitAtMostOnce    the initializer runs at most once                     *)
(*   Ends              every run ends (PROPERTY)                             *)
(* Broken variants: ReadBeforeFlag (the getter reads the global without      *)
(* checking the flag: NoPlaceholderRead), SetterNoFlag (the setter leaves    *)
(* the flag, so a later read runs the initializer over the write:            *)
(* ReadsTruth).                                                              *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    MaxOps,          \* the program's steps
    ReadBeforeFlag,  \* Broken: the getter returns the global without checking the flag
    SetterNoFlag     \* Broken: the setter stores the value but leaves the flag unset

Image == "image"
Values == {"v1", "v2"}
Placeholder == "placeholder"

VARIABLES flag, glob, state, truth, reads, runs, ops
vars == <<flag, glob, state, truth, reads, runs, ops>>

TypeOK ==
    /\ flag \in BOOLEAN
    /\ glob \in {Placeholder, Image} \cup Values
    /\ state \in {"uninitialized", "initializing", "initialized"}
    /\ truth \in {Image} \cup Values
    /\ runs \in Nat /\ ops \in 0..MaxOps

Init ==
    /\ flag = FALSE /\ glob = Placeholder /\ state = "uninitialized"
    /\ truth = Image /\ reads = <<>> /\ runs = 0 /\ ops = 0

\* the getter: the global when the flag is set, else the initializer's call. The initializer runs no
\* user code, so no read starts while it runs.
Read ==
    /\ ops < MaxOps /\ state # "initializing"
    /\ IF flag \/ ReadBeforeFlag
       THEN /\ reads' = Append(reads, [got |-> glob, truth |-> truth])
            /\ ops' = ops + 1
            /\ UNCHANGED <<flag, glob, state, truth, runs>>
       ELSE /\ state' = "initializing" /\ ops' = ops + 1
            /\ UNCHANGED <<flag, glob, truth, reads, runs>>

\* the initializer: a fresh copy of the image value stored, the flag set, the value returned to the read
InitStores ==
    /\ state = "initializing"
    /\ glob' = Image /\ flag' = TRUE /\ state' = "initialized"
    /\ runs' = runs + 1
    /\ reads' = Append(reads, [got |-> Image, truth |-> truth])
    /\ UNCHANGED <<truth, ops>>

\* the setter: the value stored and (unless SetterNoFlag) the flag set; Julia's binding holds it
Write == \E v \in Values :
    /\ ops < MaxOps /\ state # "initializing"
    /\ glob' = v /\ truth' = v
    /\ flag' = IF SetterNoFlag THEN flag ELSE TRUE
    /\ ops' = ops + 1
    /\ UNCHANGED <<state, reads, runs>>

Done == ops = MaxOps /\ state # "initializing"
Terminal == Done /\ UNCHANGED vars

Next == Read \/ InitStores \/ Write \/ Terminal
Spec == Init /\ [][Next]_vars /\ WF_vars(Read \/ InitStores \/ Write)

ReadsTruth        == \A i \in 1..Len(reads) : reads[i].got # Placeholder => reads[i].got = reads[i].truth
NoPlaceholderRead == \A i \in 1..Len(reads) : reads[i].got # Placeholder
InitAtMostOnce    == runs <= 1
Ends              == <>Done
=============================================================================
