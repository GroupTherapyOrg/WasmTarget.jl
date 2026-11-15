------------------------- MODULE ConstantImageIds ----------------------------
(***************************************************************************)
(* A TLA+ model of a constant's image id: the id a module answers for a     *)
(* mutable constant whose identity the program reads. Julia's image writer  *)
(* stores, before the header of every object whose id is its identity, the  *)
(* id the compiling process gave it (julia/src/staticdata.c:1512, :1524     *)
(* `write_uint(f, jl_object_id(v))`); jl_object_id__cold reads it back      *)
(* under GC_IN_IMAGE (julia/src/builtins.c:482-483). The construction       *)
(* (src/julia/runtime/hashing.jl image_slot!, image_object_id; src/julia/   *)
(* classes.jl memory_constant_object; src/constants.jl): each module        *)
(* constant whose identity the program reads is made with its identity     *)
(* hash slot -k, IMAGE_IDS[k] the compiling process's objectid of the Julia  *)
(* object its key names (ConstantOwner): a constant's own value, or, for a  *)
(* live copy the compiler makes of a Memory (an Array shorter than its      *)
(* Memory, a Dict's vals with a deleted slot), the ORIGINAL Memory. An      *)
(* object made at run time is given a serial n and the id int64hash(n);     *)
(* int64hash is a bijection, so a compile-time id whose preimage is a       *)
(* serial would be shared, and the compile refuses it (image_id_meets_      *)
(* serial).                                                                  *)
(*                                                                           *)
(* ABSTRACTION. Julia's objects at compile time: K1 and K2, distinct        *)
(* constants of equal contents, and O3, a Memory two Arrays wrap beyond     *)
(* their length. The module's constants: K1 and K2 themselves and K3, O3's  *)
(* live copy (MEMORY_OWNERS: one copy a Memory, shared by both Arrays).     *)
(* Paths: P1 and P2 name K1, P3 names K2, P4 and P5 name O3 (through each   *)
(* Array). Run-time objects C1, C2 take serials from 1..MaxSerial. Ids are  *)
(* tags: <<"img", j>> the compiling process's id of Julia object j,         *)
(* <<"ser", n>> a serial's. The compiling process may place K2 at an        *)
(* address below 2^31 (its id then serial 1's, collide); the compile        *)
(* refuses that, so no module of it runs. Every object a path names is     *)
(* folded at compile time (seen's initial state), whether or not inference  *)
(* folds it: the strongest case.                                            *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   AgreesWithEgal  every id answered for a Julia object, folded at        *)
(*                   compile time or read at run time through any path, is  *)
(*                   one id                                                  *)
(*   Unique          two distinct objects are never answered one id         *)
(* Beside dev/formal/ObjectIdentity.tla, whose AgreesWithEgal and Unique    *)
(* these restate for the image arm: ObjectIdentity checks the slot, the     *)
(* serial counter and the constants' storage; this model the ids a         *)
(* constant's image keeps, which ObjectIdentity's claims cannot take in     *)
(* without rewriting definitions they read.                                 *)
(* Broken variants (MC*Broken.cfg): CopyOwnKey (a live copy's key names the  *)
(* copy, its image id the copy's own against O3's fold: AgreesWithEgal) and *)
(* NoCollisionCheck (a compile-time id equal to serial 1's not refused:     *)
(* Unique).                                                                  *)
(***************************************************************************)
EXTENDS Integers, Sequences

CONSTANTS
    MaxSerial,        \* the last serial the counter gives (2^31 - 1 in the module)
    CopyOwnKey,       \* Broken: a live copy's key names the copy, not the original Memory
    NoCollisionCheck  \* Broken: an image id equal to a serial's is not refused at compile time

Julia    == {"K1", "K2", "O3"}                \* Julia's objects the program's paths name
ImageSeq == <<"K1", "K2", "K3">>             \* the module's constants, IMAGE_IDS's order
Fresh    == {"C1", "C2"}                      \* objects made at run time
Objects  == {"K1", "K2", "K3"} \cup Fresh
Ways     == {"P1", "P2", "P3", "P4", "P5"}
Named(p) == IF p = "P3" THEN "K2" ELSE IF p \in {"P4", "P5"} THEN "O3" ELSE "K1"
Reached(p) == IF p \in {"P4", "P5"} THEN "K3" ELSE Named(p)
\* the Julia object a module constant stands for: its key's object, a live copy's original
KeyObject(m) == IF m = "K3" /\ ~CopyOwnKey THEN "O3" ELSE m

ImgId(j) == <<"img", j>>
SerId(n) == <<"ser", n>>

VARIABLES
    collide,    \* the Julia objects the compiling process placed below 2^31 (their ids a serial's)
    compiled,   \* the compile succeeded: no collision, or none refused
    slot,       \* each module object's identity slot: 0 empty, n > 0 a serial, -k IMAGE_IDS[k]
    counter,    \* the next serial
    seen        \* every <<Julia object or fresh object, id>> answered, the folds included
vars == <<collide, compiled, slot, counter, seen>>

CId(j) == IF j \in collide THEN SerId(1) ELSE ImgId(j)
Ids == {CId(j) : j \in Julia \cup {"K3"}} \cup {SerId(n) : n \in 1..MaxSerial}

TypeOK ==
    /\ collide \subseteq {"K2"}
    /\ compiled \in BOOLEAN
    /\ slot \in [Objects -> -Len(ImageSeq)..MaxSerial]
    /\ counter \in 1..(MaxSerial + 1)
    /\ seen \subseteq ((Julia \cup Fresh) \X Ids)

Init ==
    /\ collide \in SUBSET {"K2"}
    /\ compiled = (collide = {} \/ NoCollisionCheck)
    /\ slot = [o \in Objects |-> IF o \in Fresh THEN 0 ELSE -(CHOOSE k \in 1..Len(ImageSeq) : ImageSeq[k] = o)]
    /\ counter = 1
    /\ seen = IF compiled THEN {<<j, CId(j)>> : j \in Julia} ELSE {}

\* the identity of module object o read through its slot: an image slot reads IMAGE_IDS, the id of
\* the object its key names; a filled slot its serial; an empty one the next serial, stored
IdOf(o, Record(_)) ==
    IF slot[o] < 0 THEN
        /\ Record(CId(KeyObject(ImageSeq[-slot[o]])))
        /\ UNCHANGED <<slot, counter>>
    ELSE IF slot[o] > 0 THEN
        /\ Record(SerId(slot[o]))
        /\ UNCHANGED <<slot, counter>>
    ELSE
        /\ counter <= MaxSerial
        /\ slot' = [slot EXCEPT ![o] = counter]
        /\ counter' = counter + 1
        /\ Record(SerId(counter))

\* objectid of a constant through a path: the module object it reaches answers for the Julia object it names
ObjectIdVia(p) ==
    /\ compiled
    /\ IdOf(Reached(p), LAMBDA id : seen' = seen \cup {<<Named(p), id>>})
    /\ UNCHANGED <<collide, compiled>>

\* objectid of an object made at run time
ObjectIdFresh(c) ==
    /\ compiled
    /\ IdOf(c, LAMBDA id : seen' = seen \cup {<<c, id>>})
    /\ UNCHANGED <<collide, compiled>>

\* a refused compile, or a run whose every read is done, stays as it is
Rest == UNCHANGED vars

Next ==
    \/ \E p \in Ways : ObjectIdVia(p)
    \/ \E c \in Fresh : ObjectIdFresh(c)
    \/ Rest

Spec == Init /\ [][Next]_vars

AgreesWithEgal ==
    \A x, y \in seen : x[1] = y[1] => x[2] = y[2]

Unique ==
    \A x, y \in seen : x[1] # y[1] => x[2] # y[2]
=============================================================================
