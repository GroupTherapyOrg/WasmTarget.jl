-------------------------------- MODULE Undef --------------------------------
(***************************************************************************)
(* A TLA+ model of how WT represents Julia's `#undef` in a pointer slot     *)
(* (src/codegen/undef.jl): an element of a Memory that `undef` made, a      *)
(* field `new` leaves unset, a Core.Box's contents before its first write,  *)
(* and an unset slot of a constant (a Dict's unoccupied slot, a Vector's or *)
(* a Memory's unset element).                                               *)
(*                                                                         *)
(* JULIA. `nothing` is an object (jl_nothing, julia.h) and `#undef` is      *)
(* NULL: a store of `nothing` makes the slot assigned (isassigned and       *)
(* isdefined answer true, jl_f_memoryref_isassigned, builtins.c), and a     *)
(* read of an unset slot throws UndefRefError (null_pointer_check,          *)
(* cgutils.cpp:1633), never answering a value. A slot can be `#undef` when  *)
(* it is a pointer: a boxed slot, or an inline one whose type has a pointer *)
(* (an immutable struct with a pointer field, Some{String}: its first       *)
(* pointer NULL, typed_load's null_pointer_check of extract_first_ptr,      *)
(* cgutils.cpp:2270; jl_field_isdefined, datatype.c:2293). A pointer-free  *)
(* inline slot (an isbits union, Union{Nothing,Int64}) is its bits, never  *)
(* `#undef`.                                                                *)
(*                                                                         *)
(* WT. `nothing` is dart's null, the wasm null at every nullable reference *)
(* (Coercion.tla NothingIsNull). A slot's type is given by the attributes   *)
(* the code reads, and every decision is derived from them as the code      *)
(* derives it:                                                              *)
(*   PointerSlot   pointer_slot: boxed, or inline with a pointer;           *)
(*   AdmitsNothing pointer_slot_admits_nothing: a pointer slot whose type   *)
(*                 admits `nothing` (Any, a Union with Nothing, any other   *)
(*                 supertype of Nothing; not Number, which excludes it);    *)
(*   Storage       undef_slot_storage: such a slot is held in the any       *)
(*                 hierarchy (eqref for a concrete reference: S's own       *)
(*                 nullable reference holds the null and S's objects        *)
(*                 alone), any other in its own representation;             *)
(*   UndefSlot     undef_slot: a Nothing-admitting slot held in the any     *)
(*                 hierarchy marks `#undef` with the module's one undefined *)
(*                 value (the sentinel), any other reference slot with its  *)
(*                 null;                                                    *)
(*   IsUnset       emit_is_unset!: no test for a slot that is no pointer,   *)
(*                 else the sentinel or the null;                           *)
(*   Checked       emit_undef_read_check!: a pointer slot's read tests it.  *)
(* An allocation (emit_new_slots!) and an unset store `#undef`'s            *)
(* representation, a read tests it and throws Julia's UndefRefError, and    *)
(* isassigned and isdefined compare against it; a constant's unset slot is  *)
(* emitted as `#undef` too (emit_constant_slots!, values.jl).               *)
(* parity(quarantine: dart marks an unset late variable by null where its *)
(* type is non-nullable and, where it is potentially nullable, by a         *)
(* sentinel (pkg/front_end/lib/src/kernel/late_lowering.dart:522            *)
(* useSentinel, the useSentinelOrNull strategy, :549; computeIsSetEncoding *)
(* :560, its useSentinelOrNull case :570) or a companion isSet field       *)
(* (useIsSetFieldOrNull, which dart2wasm selects: target.dart:565           *)
(* supportsLateLoweringSentinel => false). Julia's `#undef` is one fact     *)
(* read by one rule (C1) wherever a pointer slot holds it: a Memory         *)
(* element, which has no companion field for an isSet bit to live in, a     *)
(* field `new` may leave unset and a Core.Box's contents. A companion isSet *)
(* field per field and per Box beside the elements' mark would be a second  *)
(* encoding of that one fact, so every slot whose type admits `nothing`     *)
(* marks `#undef` by one value of its own, the sentinel.)                   *)
(*                                                                         *)
(* THE CLAIMS. Agrees: after every sequence of operations on the slots,    *)
(* WT's isassigned and read answer Julia's. NothingIsNull: a stored        *)
(* `nothing` is the null. UndefNotNothing: in a slot that holds `nothing`  *)
(* too, `#undef` is not the null. Representable: the undefined value sits  *)
(* only in a slot whose storage is of the any hierarchy. Every slot starts *)
(* unmade, so every claim holds initially and a Broken instance, one wrong *)
(* rule each (Rule), reaches its violation by a step:                      *)
(* MCUndefAnyAsNullBroken (no sentinel: an Any slot's `#undef` the null)   *)
(* and MCUndefUnionAsNullBroken (a Union{Nothing,S} slot left in S's own   *)
(* reference, so undef_slot marks it with the null) violate                *)
(* UndefNotNothing; MCUndefUnionConcreteBroken (S's own reference kept and *)
(* the sentinel decided by the type alone) violates Representable;         *)
(* MCUndefRefUncheckedBroken (a null read unchecked: a null dereference),  *)
(* MCUndefAnyUncheckedBroken (the undefined value read as a value),        *)
(* MCUndefInlineCheckedBroken (a pointer-free inline slot's null, its      *)
(* `nothing`, tested as `#undef`) and MCUndefInlinePointerBroken           *)
(* (pointer_slot by allocatedinline alone: an inline struct with a pointer *)
(* field's unset null answered assigned) violate Agrees;                   *)
(* MCUndefConstAsNullBroken (a constant's unset slot emitted as the null,  *)
(* as a Dict's unoccupied slot was) violates UndefNotNothing.              *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Slots, Ty, Rule, Depth
\* Ty: each slot's type, by the attributes the code reads: boxed (not allocated inline), ptr (an
\* inline type with a pointer, not datatype_pointerfree), admits (`nothing` is a value of it) and
\* repr (its own representation: "anyh" an abstract reference of the any hierarchy, "concrete" a
\* concrete, array or i31 nullable reference).
\* Rule: the code's rules, one flag each, TRUE in the code; a Broken instance flips one:
\*   firstptr (pointer_slot reads first_ptr), promote (undef_slot_storage holds a
\*   Nothing-admitting slot in the any hierarchy), sentinel (undef_slot marks such a slot with the
\*   undefined value), bytype (the broken rule: the sentinel decided by the type, not the
\*   storage), checknull / checksentinel (a read tests a null / the undefined value), inlinetest
\*   (the broken rule: a slot that is no pointer tested), constundef (a constant's unset slot is
\*   `#undef`).

ASSUME \A s \in Slots : Ty[s].boxed \in BOOLEAN /\ Ty[s].ptr \in BOOLEAN /\ Ty[s].admits \in BOOLEAN
                        /\ Ty[s].repr \in {"anyh", "concrete"}

\* Julia: a slot `undef` leaves NULL
JuliaPointer(t) == t.boxed \/ t.ptr
\* the code's decisions, from the attributes alone
PointerSlot(t) == t.boxed \/ (Rule.firstptr /\ t.ptr)
AdmitsNothing(t) == PointerSlot(t) /\ t.admits
Storage(t) == IF AdmitsNothing(t) /\ Rule.promote THEN "anyh" ELSE t.repr
UndefSlot(t) == Rule.sentinel /\ AdmitsNothing(t) /\ (Storage(t) = "anyh" \/ Rule.bytype)
UndefRep(t) == IF UndefSlot(t) THEN "sentinel" ELSE "null"
IsUnset(t, r) == IF ~PointerSlot(t) /\ ~Rule.inlinetest THEN FALSE ELSE r = UndefRep(t)
Checked(t, r) == (PointerSlot(t) \/ Rule.inlinetest)
                 /\ (IF r = "null" THEN Rule.checknull ELSE Rule.checksentinel)

Stores(t) == IF t.admits THEN {"nothing", "obj"} ELSE {"obj"}
Rep(j) == IF j = "nothing" THEN "null" ELSE "obj"

VARIABLES julia, wt, answer, steps
vars == <<julia, wt, answer, steps>>

\* every slot unmade ("none") until a step makes it
Init == julia = [s \in Slots |-> "none"] /\ wt = [s \in Slots |-> "none"]
        /\ answer = <<"none", "none">> /\ steps = 0

\* an allocation (memorynew, an unset field, a fresh box): Julia leaves a pointer slot NULL and
\* an inline isbits-union slot its zeroed selector's value, `nothing`; WT fills a slot undef_slot
\* admits with the undefined value, any other with its default, the null (emit_new_slots!)
Alloc(s) == julia[s] = "none" /\ julia' = [julia EXCEPT ![s] = IF JuliaPointer(Ty[s]) THEN "undef" ELSE "nothing"]
            /\ wt' = [wt EXCEPT ![s] = IF UndefSlot(Ty[s]) THEN "sentinel" ELSE "null"]
            /\ answer' = <<"none", "none">>
\* a constant's slot (emit_constant_slots!): an assigned one its value, an unset one `#undef`
ConstSlot(s, j) == julia[s] = "none" /\ julia' = [julia EXCEPT ![s] = j]
                   /\ wt' = [wt EXCEPT ![s] = IF j = "undef" THEN (IF Rule.constundef THEN UndefRep(Ty[s]) ELSE "null")
                                                             ELSE Rep(j)]
                   /\ answer' = <<"none", "none">>
Store(s, v) == julia[s] # "none" /\ julia' = [julia EXCEPT ![s] = v] /\ wt' = [wt EXCEPT ![s] = Rep(v)]
               /\ answer' = <<"none", "none">>
\* Julia's _unsetindex! (an atomic_pointerset of C_NULL): the slot is #undef again (emit_undef!)
Unset(s) == julia[s] # "none" /\ julia' = [julia EXCEPT ![s] = "undef"] /\ wt' = [wt EXCEPT ![s] = UndefRep(Ty[s])]
            /\ answer' = <<"none", "none">>
\* isassigned / isdefined: Julia's against NULL, WT's emit_is_unset!
IsAssigned(s) == julia[s] # "none" /\ answer' = <<julia[s] # "undef", ~IsUnset(Ty[s], wt[s])>>
                 /\ UNCHANGED <<julia, wt>>
\* a read: Julia throws on #undef; WT throws where it tests and finds #undef, else the
\* representation is taken as a value: the null a `nothing` in a slot that admits it, a null
\* dereference in one that does not, the undefined value an object
Decode(t, r) == CASE Checked(t, r) /\ IsUnset(t, r) -> "throw"
                  [] r = "null" -> (IF t.admits THEN "nothing" ELSE "trap")
                  [] OTHER      -> "obj"
Read(s) == julia[s] # "none" /\ answer' = <<IF julia[s] = "undef" THEN "throw" ELSE julia[s], Decode(Ty[s], wt[s])>>
           /\ UNCHANGED <<julia, wt>>

Next == steps < Depth /\ steps' = steps + 1 /\
        \E s \in Slots : Alloc(s) \/ (\E j \in Stores(Ty[s]) : ConstSlot(s, j))
                         \/ (JuliaPointer(Ty[s]) /\ (ConstSlot(s, "undef") \/ Unset(s)))
                         \/ (\E v \in Stores(Ty[s]) : Store(s, v)) \/ IsAssigned(s) \/ Read(s)
Terminal == steps = Depth /\ UNCHANGED vars
Spec == Init /\ [][Next \/ Terminal]_vars

TypeOK == julia \in [Slots -> {"none", "undef", "nothing", "obj"}]
          /\ wt \in [Slots -> {"none", "null", "sentinel", "obj"}] /\ steps \in 0..Depth

Agrees == answer[1] = answer[2]
NothingIsNull == \A s \in Slots : julia[s] = "nothing" => wt[s] = "null"
UndefNotNothing == \A s \in Slots : (Ty[s].admits /\ julia[s] = "undef") => wt[s] # "null"
Representable == \A s \in Slots : wt[s] = "sentinel" => Storage(Ty[s]) = "anyh"
=============================================================================
