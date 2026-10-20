-------------------------------- MODULE Undef --------------------------------
(***************************************************************************)
(* A TLA+ model of how WT represents Julia's `#undef` in a pointer slot     *)
(* (src/codegen/undef.jl): an element of a Memory that `undef` made, a      *)
(* field `new` leaves unset, a Core.Box's contents before its first write.  *)
(*                                                                         *)
(* JULIA. `nothing` is an object (jl_nothing, julia.h) and `#undef` is      *)
(* NULL: a store of `nothing` makes the slot assigned (isassigned and       *)
(* isdefined answer true, jl_f_memoryref_isassigned, builtins.c), and a     *)
(* read of an unset slot throws UndefRefError (null_pointer_check,          *)
(* cgutils.cpp:1633), never answering a value.                              *)
(*                                                                         *)
(* WT. `nothing` is dart's null, the wasm null at every nullable reference *)
(* (Coercion.tla NothingIsNull). The four slot kinds:                      *)
(*   "ref"   a slot whose type admits no `nothing` (a Vector{String}'s     *)
(*           element): its null is `#undef`, and a read tests it;          *)
(*   "union" a Union{Nothing,S} slot, and                                   *)
(*   "any"   an Any or abstract slot: both hold `nothing` too, so `#undef`  *)
(*           is the module's one undefined value, which only a reference   *)
(*           of the any hierarchy (eqref, anyref, structref) can hold: a    *)
(*           Union{Nothing,S} slot is held in one, not in S's own nullable *)
(*           reference, which holds the null and S's objects alone.         *)
(*   "inline" an isbits union (Union{Nothing,Int64}): Julia stores it      *)
(*           inline, never `#undef`; WT may hold it in a nullable box whose *)
(*           null is `nothing`, which no read or isassigned tests.          *)
(* A slot is made `#undef`, an unset stores `#undef`'s representation, a   *)
(* read tests it and throws Julia's UndefRefError, and isassigned and      *)
(* isdefined compare against it.                                            *)
(* parity(quarantine: dart marks an unset late variable by null where its *)
(* type is non-nullable and, where it is potentially nullable, by a         *)
(* sentinel (late_lowering.dart:522 useSentinel, the useSentinelOrNull     *)
(* strategy, :549, computeIsSetEncoding :570) or a companion isSet field   *)
(* (useIsSetFieldOrNull, which dart2wasm selects: target.dart:565           *)
(* supportsLateLoweringSentinel => false). A Julia Memory slot has no      *)
(* companion field for an isSet bit to live in, so a slot whose type       *)
(* admits `nothing` marks `#undef` by a value of its own, the sentinel.)   *)
(*                                                                         *)
(* THE CLAIMS. Agrees: after every sequence of operations on the slots,    *)
(* WT's isassigned and read answer Julia's. NothingIsNull: a stored        *)
(* `nothing` is the null. UndefNotNothing: in a slot that holds `nothing`  *)
(* too, `#undef` is not the null. Representable: the undefined value sits  *)
(* only in a slot held in the any hierarchy. The Broken instances, one per *)
(* wrong encoding: MCUndefAnyAsNullBroken (an Any slot's `#undef` the      *)
(* null) and MCUndefUnionAsNullBroken (a Union{Nothing,S} slot held in S's *)
(* own reference, its `#undef` the null) violate UndefNotNothing;          *)
(* MCUndefUnionConcreteBroken (the undefined value in S's own reference)    *)
(* violates Representable; MCUndefRefUncheckedBroken (a no-nothing slot's  *)
(* null read unchecked: a null dereference), MCUndefAnyUncheckedBroken     *)
(* (the undefined value read as a value) and MCUndefInlineCheckedBroken    *)
(* (an inline slot's null, its `nothing`, tested as `#undef`: a stored      *)
(* `nothing` read as UndefRefError) violate Agrees.                         *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Slots, Kind, Enc, Depth
\* Kind: each slot's kind. Enc: per kind, `#undef`'s representation (undef: "null" or
\* "sentinel"), whether a read tests it (check), and where the slot is held (held: "any" for a
\* reference of the any hierarchy, "own" for the Julia type's own nullable reference).

Kinds == {"ref", "union", "any", "inline"}
Admits(k) == k \in {"union", "any", "inline"}   \* the slot's type admits `nothing`
Pointer(k) == k # "inline"                      \* Julia's `undef` leaves the slot NULL

ASSUME Kind \in [Slots -> Kinds]
\* undef "none": a representation no slot holds (an inline slot has no #undef)
ASSUME \A k \in Kinds : Enc[k].undef \in {"null", "sentinel", "none"} /\ Enc[k].check \in BOOLEAN
                        /\ Enc[k].held \in {"any", "own"}

Stores(k) == IF Admits(k) THEN {"nothing", "obj"} ELSE {"obj"}
Rep(k, j) == CASE j = "undef"   -> Enc[k].undef
               [] j = "nothing" -> "null"
               [] OTHER         -> "obj"

VARIABLES julia, wt, answer, steps
vars == <<julia, wt, answer, steps>>

\* a slot made by `undef` (an allocation, an unset field, a fresh box) holds #undef; an inline
\* isbits-union slot holds a value (its zeroed selector's, `nothing`)
Init == julia = [s \in Slots |-> IF Pointer(Kind[s]) THEN "undef" ELSE "nothing"]
        /\ wt = [s \in Slots |-> IF Pointer(Kind[s]) THEN Enc[Kind[s]].undef ELSE "null"]
        /\ answer = <<"none", "none">> /\ steps = 0

Store(s, v) == julia' = [julia EXCEPT ![s] = v] /\ wt' = [wt EXCEPT ![s] = Rep(Kind[s], v)]
               /\ answer' = <<"none", "none">>
\* Julia's _unsetindex! (an atomic_pointerset of C_NULL): the slot is #undef again
Unset(s) == julia' = [julia EXCEPT ![s] = "undef"] /\ wt' = [wt EXCEPT ![s] = Enc[Kind[s]].undef]
            /\ answer' = <<"none", "none">>
\* isassigned / isdefined: Julia's against NULL, WT's against its kind's #undef
IsAssigned(s) == answer' = <<julia[s] # "undef", wt[s] # Enc[Kind[s]].undef>> /\ UNCHANGED <<julia, wt>>
\* a read: Julia throws on #undef; WT throws on its kind's #undef when it tests it, else the
\* representation is taken as a value: the null a `nothing`, but a null dereference in a slot
\* holding no `nothing`, the undefined value an object
Decode(k, r) == CASE r = Enc[k].undef /\ Enc[k].check -> "throw"
                  [] r = "null" -> (IF Admits(k) THEN "nothing" ELSE "trap")
                  [] OTHER      -> "obj"
Read(s) == answer' = <<IF julia[s] = "undef" THEN "throw" ELSE julia[s], Decode(Kind[s], wt[s])>>
           /\ UNCHANGED <<julia, wt>>

Next == steps < Depth /\ steps' = steps + 1 /\
        \E s \in Slots : (\E v \in Stores(Kind[s]) : Store(s, v)) \/ (Pointer(Kind[s]) /\ Unset(s))
                         \/ IsAssigned(s) \/ Read(s)
Terminal == steps = Depth /\ UNCHANGED vars
Spec == Init /\ [][Next \/ Terminal]_vars

TypeOK == julia \in [Slots -> {"undef", "nothing", "obj"}] /\ steps \in 0..Depth

Agrees == answer[1] = answer[2]
NothingIsNull == \A s \in Slots : julia[s] = "nothing" => wt[s] = "null"
UndefNotNothing == \A s \in Slots : (Admits(Kind[s]) /\ julia[s] = "undef") => wt[s] # "null"
Representable == \A s \in Slots : wt[s] = "sentinel" => Enc[Kind[s]].held = "any"
=============================================================================
