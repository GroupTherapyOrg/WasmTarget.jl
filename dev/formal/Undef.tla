-------------------------------- MODULE Undef --------------------------------
(***************************************************************************)
(* A TLA+ model of how WT represents Julia's `#undef` beside `nothing` in a *)
(* slot of the any hierarchy (src/codegen/undef.jl): an element of an `Any` *)
(* or abstract Memory that `undef` made, a mutable field `new` leaves       *)
(* unset, a Core.Box's contents before its first write.                     *)
(*                                                                         *)
(* JULIA. `nothing` is an object (jl_nothing, julia.h) and `#undef` is      *)
(* NULL: a store of `nothing` makes the slot assigned (isassigned,          *)
(* isdefined answer true, jl_f_memoryref_isassigned, builtins.c), and a     *)
(* read of an unset slot throws UndefRefError (null_pointer_check,          *)
(* cgutils.cpp), never answering a value.                                   *)
(*                                                                         *)
(* WT. `nothing` is dart's null, the wasm null at every nullable reference *)
(* of the any hierarchy (Coercion.tla NothingIsNull). So `#undef` is a      *)
(* sentinel object of its own, the module's one undefined value: a slot is *)
(* made with it, an unset stores it, a read tests it and throws Julia's     *)
(* UndefRefError, and isassigned and isdefined compare against it.          *)
(* parity(quarantine: dart has no uninitialized slot a nullable type can   *)
(* see: its late lowering marks a non-nullable late field unset by null and *)
(* a nullable one by a separate isSet field (late_lowering.dart IsSetEncoding, *)
(* target.dart:565 supportsLateLoweringSentinel => false), and its arrays   *)
(* are always filled; Julia's `#undef` differs from `nothing`, which is     *)
(* dart's null in WT, so it is a sentinel.)                                 *)
(*                                                                         *)
(* THE CLAIMS. Agrees: after every sequence of operations on the slots,    *)
(* WT's isassigned and read answer Julia's. NothingIsNull: a stored        *)
(* `nothing` is the null. UndefNotNothing: `#undef` and `nothing` have two  *)
(* representations. The Broken instance (MCUndefAsNullBroken) represents    *)
(* `#undef` as the null, the code before: a slot holding `nothing` and an   *)
(* unset one are one value, so isassigned of a stored `nothing` answers     *)
(* false and a read of an unset slot answers `nothing` (Agrees fails too);  *)
(* MCUndefReadUncheckedBroken reads the sentinel as a value, where Julia    *)
(* throws.                                                                  *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Slots, UndefRep, ReadTests, Depth
\* UndefRep: "sentinel" (the code) or "null" (the code before); ReadTests: a read tests the
\* sentinel (the code) or takes it as a value (Broken: an unchecked read leaks it)

ASSUME UndefRep \in {"sentinel", "null"} /\ ReadTests \in BOOLEAN

Values == {"nothing", "obj"}
Julia == {"undef"} \cup Values
Rep(j) == CASE j = "undef"   -> UndefRep
            [] j = "nothing" -> "null"
            [] OTHER         -> "obj"

VARIABLES julia, wt, answer, steps
vars == <<julia, wt, answer, steps>>

\* a slot made by `undef` (an allocation, an unset field, a fresh box) holds #undef
Init == julia = [s \in Slots |-> "undef"] /\ wt = [s \in Slots |-> UndefRep]
        /\ answer = <<"none", "none">> /\ steps = 0

Store(s, v) == julia' = [julia EXCEPT ![s] = v] /\ wt' = [wt EXCEPT ![s] = Rep(v)] /\ answer' = <<"none", "none">>
\* Julia's _unsetindex! (an atomic_pointerset of C_NULL): the slot is #undef again
Unset(s) == julia' = [julia EXCEPT ![s] = "undef"] /\ wt' = [wt EXCEPT ![s] = UndefRep] /\ answer' = <<"none", "none">>
\* isassigned / isdefined: Julia's against NULL, WT's against the undefined value
IsAssigned(s) == answer' = <<julia[s] # "undef", wt[s] # "sentinel" /\ (UndefRep = "sentinel" \/ wt[s] # "null")>>
                 /\ UNCHANGED <<julia, wt>>
\* a read: Julia throws on #undef; WT throws on the sentinel and decodes the null as nothing
Decode(r) == CASE r = "sentinel" -> (IF ReadTests THEN "throw" ELSE "obj") [] r = "null" -> "nothing" [] OTHER -> "obj"
Read(s) == answer' = <<IF julia[s] = "undef" THEN "throw" ELSE julia[s], Decode(wt[s])>>
           /\ UNCHANGED <<julia, wt>>

Next == steps < Depth /\ steps' = steps + 1 /\
        \E s \in Slots : (\E v \in Values : Store(s, v)) \/ Unset(s) \/ IsAssigned(s) \/ Read(s)
Terminal == steps = Depth /\ UNCHANGED vars
Spec == Init /\ [][Next \/ Terminal]_vars

TypeOK == julia \in [Slots -> Julia] /\ steps \in 0..Depth

Agrees == answer[1] = answer[2]
NothingIsNull == \A s \in Slots : julia[s] = "nothing" => wt[s] = "null"
UndefNotNothing == \A s, t \in Slots : (julia[s] = "undef" /\ julia[t] = "nothing") => wt[s] # wt[t]
=============================================================================
