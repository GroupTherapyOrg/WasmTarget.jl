-------------------------- MODULE ObjectIdentity ------------------------------
(***************************************************************************)
(* A TLA+ model of a mutable value's identity in a WasmGC module, where no  *)
(* object has an address. Julia reads an address in two places:             *)
(*   jl_object_id__cold (julia/src/builtins.c:483) hashes it,               *)
(*     inthash((uintptr_t)v), for any mutable that is no String, svec,      *)
(*     type or Module; an object saved in an image keeps the id the         *)
(*     compiling process gave it in a header word (staticdata.c:1512-1524  *)
(*     writes it, builtins.c:480-482 reads it back when GC_IN_IMAGE);       *)
(*   dataids(::Memory) (julia/base/abstractarray.jl:1591) returns it,       *)
(*     UInt(A.ptr), the address of the data, which is its owner's: the      *)
(*     Memory itself, or the String whose bytes it wraps (the data-owner    *)
(*     field, julia/src/genericmemory.c:110).                               *)
(* The construction (src/julia/runtime/hashing.jl, src/runtime/common/       *)
(* object_helper.jl): every object under Any carries dart's identity-hash   *)
(* slot (dart2wasm/lib/class_info.dart:29), filled lazily as dart's          *)
(* Object._objectHashCode fills it (sdk/lib/_internal/wasm/common/           *)
(* object_patch.dart:16: read the slot, if 0 store a nonzero value), the    *)
(* value a SERIAL from one module-global counter, which raises when spent   *)
(* and never wraps; the id of a mutable is int64hash(serial), a bijection,  *)
(* so it is modelled as the serial itself, tagged. A constant mutable is an *)
(* image object: its slot holds -k, selecting IMAGE_IDS[k], the compiling   *)
(* process's objectid of the original object (the sign plays GC_IN_IMAGE). *)
(* A constant is its Julia object's module object, with its own storage:   *)
(* the constant's key is its owner's identity, never its contents, so two   *)
(* distinct constants of equal contents are two objects with two data       *)
(* arrays, and one constant reached by two paths is one object.             *)
(*                                                                           *)
(* ABSTRACTION. A fixed universe: two mutable cells made at run time, one   *)
(* String alive from the start, two Memories each made by memorynew (its    *)
(* data its own) or by wrapping the String's bytes (its data the String's), *)
(* and two constant Memories of the image, K1 and K2, of EQUAL contents,    *)
(* each with a data array fixed at compile time, reached by three paths:    *)
(* P1 and P2 name K1, P3 names K2. Data arrays are named, so two Memories   *)
(* share data exactly when they name one array (the use of a String after   *)
(* its bytes are taken is Base's UB and excluded). A write through a path   *)
(* stores the path's name in the data the path reaches; native Julia's      *)
(* answer is the same write into the constant the path names; a read       *)
(* through a path compares the two. A compile-time id is the tag            *)
(* <<"img", c>>, distinct per constant; a run-time id <<"ser", n>>. That    *)
(* the two never meet is R3 of the design study (serials are below 2^31,    *)
(* addresses at least 2^32 on 64-bit macOS), an assumption of the encoding, *)
(* not a claim checked here. A fold, inference answering objectid of a      *)
(* constant at compile time with the compiling process's id, is recorded in *)
(* the initial state for every constant: every constant folded somewhere.  *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   AgreesWithEgal  an object's id never changes, and every folded id is   *)
(*                   the id the module computes at run time (x === y, the   *)
(*                   same object, implies equal ids)                         *)
(*   Unique          two distinct objects never hold one identity, and no   *)
(*                   two objects were ever answered one id (HAMT's need,    *)
(*                   julia/base/hamt.jl:14-17, :205-207)                     *)
(*   DataIdsExact    dataids of two Memories, made at run time or constants *)
(*                   read by path, agree exactly when their data is one     *)
(*                   array                                                   *)
(*   NoWrap          every serial assigned is below the counter, which      *)
(*                   never passes MaxSerial + 1: a spent counter raises      *)
(*   ConstantStorage, the constants' storage observed by writes and reads   *)
(*   through paths, three claims a constants table keyed by its owner's     *)
(*   identity satisfies:                                                     *)
(*     WriteSeenSameConstant         a write through one path is seen      *)
(*                   through every path to the same constant (P1, P2)       *)
(*     WriteUnseenDistinctConstants  a write through a path is never seen  *)
(*                   through a path to a distinct constant, equal contents  *)
(*                   or not (P3 against P1 and P2)                           *)
(*     ConstantDataAgrees  every read through a path answers what native   *)
(*                   Julia reads in the constant the path names              *)
(* Broken variants (MC*Broken.cfg): RandomIds (dart's _Random draw, here a   *)
(* 2-value draw: Unique), MemHeaderIds (dataids from the Memory's own slot:  *)
(* DataIdsExact on two wraps of one String), LazyConsts (constants given    *)
(* serials at run time like any object: AgreesWithEgal after a fold), Wraps *)
(* (a spent counter starts again at 1: NoWrap), ConstByValue (a constant's  *)
(* storage keyed by its contents: K1 and K2 stay two objects with two       *)
(* identities but share one data array, origin's bug with two constant      *)
(* Arrays of equal contents: DataIdsExact, and WriteUnseenDistinctConstants *)
(* in a variant that leaves DataIdsExact out) and ConstPerPath (each path a *)
(* module object of its own: K1 by P2 is a copy with its own array, carrying *)
(* K1's image id, so no id tells it apart: WriteSeenSameConstant).          *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, Sequences

CONSTANTS
    MaxSerial,      \* the last serial the counter gives (2^31 - 1 in the module)
    RandomIds,      \* Broken: an empty slot is filled by a random draw, dart's _Random
    MemHeaderIds,   \* Broken: dataids reads the Memory's own slot, not its data owner's
    LazyConsts,     \* Broken: constants carry no image id; their slot fills at run time
    Wraps,          \* Broken: a spent counter starts again at 1
    ConstByValue,   \* Broken: a constant's storage is keyed by its contents, not its owner's identity
    ConstPerPath    \* Broken: each path to a constant makes a module object of its own

Cells   == {"C1", "C2"}              \* mutables made at run time
ConstSeq == <<"K1", "K2">>          \* the image's constant Memories, IMAGE_IDS's order
Consts  == {ConstSeq[k] : k \in 1..Len(ConstSeq)}
Strs    == {"S1"}                    \* a String, alive from the start
Mems    == {"M1", "M2"}              \* Memories, made at run time

\* the program's paths to its constants: K1 by two, K2 by one; K1 and K2 hold equal contents
Paths   == {"P1", "P2", "P3"}
Target(p) == IF p = "P3" THEN "K2" ELSE "K1"
Content(c) == "zeros"
\* the module object a path reaches: its constant's own; per path, a copy for the second path
ModObj(p) == IF ConstPerPath /\ p = "P2" THEN "K1p" ELSE Target(p)
ModConsts == {ModObj(p) : p \in Paths}
\* the Julia object each module constant was made for, and the module's constants in IMAGE_IDS's order
Original(m) == IF m = "K1p" THEN "K1" ELSE m
ImageSeq == IF ConstPerPath THEN ConstSeq \o <<"K1p">> ELSE ConstSeq
\* the data array a module constant holds, fixed at compile time: its own, or, keyed by contents,
\* the one array of every constant of those contents
CData(m) == IF ConstByValue THEN <<"by-content", Content(Original(m))>> ELSE <<"own", m>>

Objs    == Cells \cup Consts \cup {"K1p"} \cup Strs \cup Mems
NoOwner == "none"
Values  == Paths \cup {"init"}

ImgId(c) == <<"img", c>>
SerId(n) == <<"ser", n>>
Ids == {ImgId(c) : c \in Consts} \cup {SerId(n) : n \in 1..MaxSerial}

VARIABLES
    alive,      \* the objects made so far
    slot,       \* each object's identity-hash slot: 0 empty, n > 0 a serial, -k IMAGE_IDS[k]
    counter,    \* the next serial
    owner,      \* each Memory's data owner: itself, or the String it wraps
    seen,       \* every <<object, id>> objectid answered, the folds included
    dseen,      \* every <<Memory, id>> dataids answered, a constant read by path among them
    raised,     \* a spent counter raised
    store,      \* the module's constant data arrays: the last path written into each
    native,     \* native Julia's constants: the last path written into each
    lastread    \* the last read through a path: <<path, the module's answer, native's>>, or <<>>
vars == <<alive, slot, counter, owner, seen, dseen, raised, store, native, lastread>>

DataNames == {CData(m) : m \in ModConsts}

TypeOK ==
    /\ alive \subseteq Objs
    /\ slot \in [Objs -> -Len(ImageSeq)..MaxSerial]
    /\ counter \in 1..(MaxSerial + 1)
    /\ owner \in [Mems -> Mems \cup Strs \cup {NoOwner}]
    /\ seen \subseteq (Objs \X Ids)
    /\ dseen \subseteq ((Mems \cup Consts \cup {"K1p"}) \X Ids)
    /\ raised \in BOOLEAN
    /\ store \in [DataNames -> Values]
    /\ native \in [Consts -> Values]
    /\ lastread \in {<<>>} \cup (Paths \X Values \X Values)

\* the image: each module constant's slot -k, the compiling process's id of each constant folded
Init ==
    /\ alive = Consts \cup Strs \cup ModConsts
    /\ slot = [o \in Objs |-> IF (\E k \in 1..Len(ImageSeq) : ImageSeq[k] = o) /\ ~LazyConsts
                                THEN -(CHOOSE k \in 1..Len(ImageSeq) : ImageSeq[k] = o)
                                ELSE 0]
    /\ counter = 1
    /\ owner = [m \in Mems |-> NoOwner]
    /\ seen = {<<c, ImgId(c)>> : c \in Consts}
    /\ dseen = {}
    /\ raised = FALSE
    /\ store = [d \in DataNames |-> "init"]
    /\ native = [c \in Consts |-> "init"]
    /\ lastread = <<>>

UnchangedConsts == UNCHANGED <<store, native, lastread>>

\* a mutable made at run time: its slot 0, dart's initialIdentityHash (class_info.dart:193)
Alloc(o) ==
    /\ o \in Cells \ alive
    /\ alive' = alive \cup {o}
    /\ UNCHANGED <<slot, counter, owner, seen, dseen, raised>>
    /\ UnchangedConsts

\* memorynew: a Memory owning a data array of its own
MemNew(m) ==
    /\ m \in Mems \ alive
    /\ alive' = alive \cup {m}
    /\ owner' = [owner EXCEPT ![m] = m]
    /\ UNCHANGED <<slot, counter, seen, dseen, raised>>
    /\ UnchangedConsts

\* jl_string_to_genericmemory: a Memory over a String's bytes, its owner the String
Wrap(m, s) ==
    /\ m \in Mems \ alive
    /\ s \in Strs \cap alive
    /\ alive' = alive \cup {m}
    /\ owner' = [owner EXCEPT ![m] = s]
    /\ UNCHANGED <<slot, counter, seen, dseen, raised>>
    /\ UnchangedConsts

\* the identity of object o read through its slot (object_serial and its image arm), the
\* answer recorded by Record(id): an image slot reads IMAGE_IDS, a filled slot its serial, an
\* empty one takes the next serial and stores it, a spent counter raises and stores nothing
ReadSlot(o, Record(_)) ==
    IF slot[o] < 0 THEN
        /\ Record(ImgId(Original(ImageSeq[-slot[o]])))
        /\ UNCHANGED <<slot, counter, raised>>
    ELSE IF slot[o] > 0 THEN
        /\ Record(SerId(slot[o]))
        /\ UNCHANGED <<slot, counter, raised>>
    ELSE IF RandomIds THEN
        \E r \in 1..2 :
            /\ slot' = [slot EXCEPT ![o] = r]
            /\ Record(SerId(r))
            /\ UNCHANGED <<counter, raised>>
    ELSE IF counter <= MaxSerial THEN
        /\ slot' = [slot EXCEPT ![o] = counter]
        /\ counter' = IF Wraps /\ counter = MaxSerial THEN 1 ELSE counter + 1
        /\ Record(SerId(counter))
        /\ UNCHANGED raised
    ELSE
        /\ raised' = TRUE
        /\ UNCHANGED <<slot, counter, seen, dseen>>

\* objectid of an object whose id is its identity (jl_object_id__cold's last arm)
ObjectId(o) ==
    /\ o \in alive \cap (Cells \cup Mems)
    /\ ReadSlot(o, LAMBDA id : seen' = seen \cup {<<o, id>>} /\ UNCHANGED dseen)
    /\ UNCHANGED <<alive, owner>>
    /\ UnchangedConsts

\* objectid of a constant, through one of the program's paths to it: the module object the path
\* reaches answers for the Julia object the path names
ObjectIdVia(p) ==
    /\ ReadSlot(ModObj(p), LAMBDA id : seen' = seen \cup {<<Target(p), id>>} /\ UNCHANGED dseen)
    /\ UNCHANGED <<alive, owner>>
    /\ UnchangedConsts

\* dataids of a Memory made at run time: the identity of its data's owner
DataIds(m) ==
    /\ m \in alive \cap Mems
    /\ ReadSlot(IF MemHeaderIds THEN m ELSE owner[m],
                LAMBDA id : dseen' = dseen \cup {<<m, id>>} /\ UNCHANGED seen)
    /\ UNCHANGED <<alive, owner>>
    /\ UnchangedConsts

\* dataids of a constant Memory, through a path: its data's owner is the module object itself
DataIdsVia(p) ==
    /\ ReadSlot(ModObj(p), LAMBDA id : dseen' = dseen \cup {<<ModObj(p), id>>} /\ UNCHANGED seen)
    /\ UNCHANGED <<alive, owner>>
    /\ UnchangedConsts

\* a write through a path: the module stores into the data the path reaches, native Julia into the
\* constant the path names
WriteVia(p) ==
    /\ store' = [store EXCEPT ![CData(ModObj(p))] = p]
    /\ native' = [native EXCEPT ![Target(p)] = p]
    /\ lastread' = <<>>
    /\ UNCHANGED <<alive, slot, counter, owner, seen, dseen, raised>>

\* a read through a path: the module's answer beside native Julia's
ReadVia(p) ==
    /\ lastread' = <<p, store[CData(ModObj(p))], native[Target(p)]>>
    /\ UNCHANGED <<store, native>>
    /\ UNCHANGED <<alive, slot, counter, owner, seen, dseen, raised>>

Next ==
    \/ \E o \in Cells : Alloc(o)
    \/ \E m \in Mems : MemNew(m)
    \/ \E m \in Mems, s \in Strs : Wrap(m, s)
    \/ \E o \in Objs : ObjectId(o)
    \/ \E p \in Paths : ObjectIdVia(p)
    \/ \E m \in Mems : DataIds(m)
    \/ \E p \in Paths : DataIdsVia(p)
    \/ \E p \in Paths : WriteVia(p)
    \/ \E p \in Paths : ReadVia(p)

Spec == Init /\ [][Next]_vars

\* the data array a Memory reads: a run-time one's named by its owner, a constant's its own
Data(m) == IF m \in Mems THEN <<"run", owner[m]>> ELSE CData(m)

AgreesWithEgal ==
    \A p, q \in seen : p[1] = q[1] => p[2] = q[2]

Unique ==
    /\ \A o1, o2 \in Objs : (o1 # o2 /\ slot[o1] # 0) => slot[o1] # slot[o2]
    /\ \A p, q \in seen : p[1] # q[1] => p[2] # q[2]

DataIdsExact ==
    \A p, q \in dseen : (p[2] = q[2]) <=> (Data(p[1]) = Data(q[1]))

NoWrap ==
    \A o \in Objs : slot[o] > 0 => slot[o] < counter

\* the last read through a path, after native Julia's last write into that path's constant came
\* through a path to the same constant: the module shows that write
WriteSeenSameConstant ==
    lastread # <<>> /\ lastread[3] \in Paths => lastread[2] = lastread[3]

\* the last read through a path never shows a write through a path to a distinct constant
WriteUnseenDistinctConstants ==
    lastread # <<>> /\ lastread[2] \in Paths => Target(lastread[2]) = Target(lastread[1])

\* the last read through a path answers what native Julia reads in the constant the path names
ConstantDataAgrees ==
    lastread # <<>> => lastread[2] = lastread[3]
=============================================================================
