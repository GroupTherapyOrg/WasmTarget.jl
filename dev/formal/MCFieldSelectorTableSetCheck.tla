------------------- MODULE MCFieldSelectorTableSetCheck --------------------
(***************************************************************************)
(* THE SITE CHECK OF A WRITE: setfield! on a receiver Julia left abstract,   *)
(* the read's site check (MCFieldSelectorTableSiteCheck.tla) in Julia's      *)
(* order for a write. jl_f_setfield (julia/src/builtins.c:1057) checks the   *)
(* value's own type before it writes, get_checked_fieldindex (:994) with    *)
(* mutabl: an immutable struct raises whatever the key (:1000), then the key *)
(* finding no field raises as a read's (BoundsError past a position, :1006; *)
(* FieldError for a name, :1010), then a const field raises (:1018); then    *)
(* jl_f_setfield's atomic check (:1068). The port raises each class's error *)
(* at the site, before the setter selector's call, whose row holds only the *)
(* classes holding a field the site may write (DispatchTable.build's        *)
(* setters, a field's `mutable`), as dart's dynamic setter tests the class  *)
(* id before its call (dart2wasm/lib/dynamic_dispatchers.dart:134           *)
(* _generateSetterCode).                                                    *)
(*                                                                           *)
(* ABSTRACTION. MCFieldSelectorTableSiteCheck's, the table now the setter    *)
(* selectors': has[c] the fields class c holds that a write may take (the    *)
(* row's classes, NoFieldError = TRUE), held[c] the fields it holds, a      *)
(* superset (a const field, or an atomic one the site writes plainly, held *)
(* but not written: Unwritable), frozen the immutable classes, which hold   *)
(* no writable field. A Module receiver is an immutable one here (its own   *)
(* message, the same place in the order).                                    *)
(*                                                                           *)
(* Claims (at the end of packing), beside SlotUnique and DispatchExact:      *)
(*   SetCheckTraps   a class of the receiver's type whose write Julia        *)
(*                   refuses reaches Julia's error at the site, the first    *)
(*                   of its checks in jl_f_setfield's order, never the       *)
(*                   selector's call, a null slot or another class's setter *)
(*   SetWritesExact  a class whose write Julia takes passes the check and    *)
(*                   reaches its own setter through the selector             *)
(* Broken variants: NoSetCheck (MCFieldSelectorTableSetCheckNoSetCheckBroken *)
(* .cfg): no check before the call, so a refused write reaches the selector, *)
(* whose row has no target for it: SetCheckTraps. FieldFirst               *)
(* (MCFieldSelectorTableSetCheckFieldFirstBroken.cfg): the field checked    *)
(* before the mutability, so an immutable class without the field raises a  *)
(* read's error, not Julia's immutable one: SetCheckTraps.                  *)
(***************************************************************************)
EXTENDS MCFieldSelectorTableSiteCheck

CONSTANTS
    NoSetCheck,    \* Broken: no class-id check before the setter selector's call
    FieldFirst     \* Broken: the key's field checked before the class's mutability

VARIABLES held, frozen
setVars == <<vars, held, frozen>>

ImmutableErr == <<-4, "immutable">>
UnwritableErr == <<-5, "unwritable">>
NoRaise == <<-6, "none">>

\* Julia's answer for a write of field f on a value of class c: the first of jl_f_setfield's checks that fails
JuliaSetRaise(f, c) ==
    IF c \in frozen THEN ImmutableErr
    ELSE IF f \notin held[c] THEN SiteError(f)
    ELSE IF f \notin has[c] THEN UnwritableErr
    ELSE NoRaise

\* the port's answer (setfield_raise); FieldFirst checks the field before the mutability
PortSetRaise(f, c) == IF FieldFirst /\ f \notin held[c] THEN SiteError(f) ELSE JuliaSetRaise(f, c)

\* the write of field f on a receiver of class c: the class-id check at the site, then the setter selector's call
SetSiteCall(f, c) == IF ~NoSetCheck /\ PortSetRaise(f, c) # NoRaise THEN PortSetRaise(f, c) ELSE Call(f, c)

SetTypeOK ==
    /\ held \in [Classes -> SUBSET Names]
    /\ frozen \subseteq Classes
    /\ \A c \in Classes : has[c] \subseteq held[c] /\ (c \in frozen => has[c] = {})
    /\ NoSetCheck \in BOOLEAN
    /\ FieldFirst \in BOOLEAN

SetInit ==
    /\ Init
    /\ held \in [Classes -> SUBSET Names]
    /\ frozen \in SUBSET Classes
    /\ \A c \in Classes : has[c] \subseteq held[c] /\ (c \in frozen => has[c] = {})

SetNext == Next /\ UNCHANGED <<held, frozen>>
SetSpec == SetInit /\ [][SetNext]_setVars /\ WF_setVars((Pack \/ Finish) /\ UNCHANGED <<held, frozen>>)

SetCheckTraps == phase = "done" =>
    \A f \in Names : \A c \in recv[f] : JuliaSetRaise(f, c) # NoRaise => SetSiteCall(f, c) = JuliaSetRaise(f, c)

SetWritesExact == phase = "done" =>
    \A f \in Names : \A c \in recv[f] : JuliaSetRaise(f, c) = NoRaise => SetSiteCall(f, c) = Get(c, f)
=============================================================================
