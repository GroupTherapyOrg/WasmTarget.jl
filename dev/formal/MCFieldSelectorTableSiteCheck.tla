------------------ MODULE MCFieldSelectorTableSiteCheck --------------------
(***************************************************************************)
(* THE SITE CHECK, which SUPERSEDES FieldSelectorTable.tla's row plan for a  *)
(* class without the field (its MissingFieldTraps: Julia's FieldError as a   *)
(* target in the selector's row). Julia checks at the read: jl_f_getfield's  *)
(* get_checked_fieldindex (julia/src/builtins.c:994) checks the field of the *)
(* value's own type before it reads, a position against its field count      *)
(* (BoundsError of the value and the position, :1006 jl_bounds_error) and a  *)
(* name by jl_field_index (FieldError of the type and the name,              *)
(* julia/src/rtutils.c:169 jl_has_no_field_error). So the port checks at the *)
(* site, as dart's dynamic getter dispatcher tests the receiver's class id   *)
(* before its call and branches to noSuchMethod on a miss                    *)
(* (dart2wasm/lib/dynamic_dispatchers.dart:99 _generateGetterCode; the test  *)
(* is code_generator.dart:5684 emitClassIdRangeCheck): a class of the        *)
(* receiver's type without the field raises Julia's error there, and the     *)
(* selector's row holds only the classes with the field, the targets dart's   *)
(* addMember gives (FieldSelectorTable's NoFieldError = TRUE rows). One      *)
(* construction for "the field is not there", a name's and a position's.    *)
(*                                                                           *)
(* ABSTRACTION. FieldSelectorTable's, plus: each field's one call site reads *)
(* it by its name or by its position (ByPosition: a position resolves to the *)
(* field each class holds there, a class past it lacking the field); the     *)
(* site's error is FieldError for a name and BoundsError for a position.     *)
(*                                                                           *)
(* Claims (at the end of packing), beside SlotUnique and DispatchExact:      *)
(*   SiteCheckTraps   a class of the receiver's type without the field       *)
(*                    reaches Julia's error at the site, FieldError for a    *)
(*                    name and BoundsError for a position, never the         *)
(*                    selector's call, a null slot or another class's getter *)
(*   SiteReadsExact   a class with the field passes the check and reaches    *)
(*                    its own getter through the selector                    *)
(*   RowsHoldGetters  no slot of the table holds an error: the row plan's    *)
(*                    FieldError target is gone                              *)
(* Broken variant: NoSiteCheck (MCFieldSelectorTableSiteCheckBroken.cfg): no *)
(* check before the call, so a missing field reaches the selector, whose row *)
(* has no target for it: SiteCheckTraps.                                     *)
(***************************************************************************)
EXTENDS FieldSelectorTable

CONSTANTS
    ByPosition,    \* the fields whose call site reads them by position
    NoSiteCheck    \* Broken: no class-id check before the selector's call

BoundsErr == <<-3, "BoundsError">>

\* Julia's error where the field is not there: get_checked_fieldindex's raise for the site's key
SiteError(f) == IF f \in ByPosition THEN BoundsErr ELSE FieldErr

\* the read of field f on a receiver of class c: the class-id check at the site, then the selector's call
SiteCall(f, c) == IF ~NoSiteCheck /\ f \notin has[c] THEN SiteError(f) ELSE Call(f, c)

SiteTypeOK ==
    /\ ByPosition \subseteq Names
    /\ NoSiteCheck \in BOOLEAN

SiteCheckTraps == phase = "done" =>
    \A f \in Names : \A c \in recv[f] : f \notin has[c] => SiteCall(f, c) = SiteError(f)

SiteReadsExact == phase = "done" =>
    \A f \in Names : \A c \in recv[f] : f \in has[c] => SiteCall(f, c) = Get(c, f)

RowsHoldGetters == \A i \in 1..Len(table) : table[i] \notin {FieldErr, BoundsErr}
=============================================================================
