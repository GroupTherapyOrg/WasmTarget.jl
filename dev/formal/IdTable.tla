-------------------------- MODULE IdTable -------------------------------------
(***************************************************************************)
(* A TLA+ model of Julia's identity table, the C under Base's IdDict       *)
(* (julia/src/iddict.c, Julia 1.12.7), which WasmTarget ports line by line *)
(* into src/julia/runtime/iddict.jl:                                       *)
(*   jl_table_peek_bp   probe from the key's home slot, h2index(keyhash),  *)
(*                      one slot at a time, wrapping, at most maxprobe     *)
(*                      steps past the first and never back to the home;   *)
(*                      a NULL key ends the walk; an egal key with a value *)
(*                      is the hit; an egal key without one (a deleted     *)
(*                      slot) ends the walk unless the key is `nothing`,   *)
(*                      the deletion sentinel                              *)
(*   jl_table_assign_bp the same walk: an egal key with a value is         *)
(*                      overwritten (inserted 0); else the first deleted   *)
(*                      or NULL slot met takes the pair (inserted 1); with *)
(*                      neither, the table grows (jl_idtable_rehash) and   *)
(*                      the insert is retried                              *)
(*   jl_eqtable_pop     the hit's key becomes `nothing`, its value NULL    *)
(*   jl_idtable_rehash  a new table, each live pair assigned in slot order *)
(*   jl_eqtable_nextind the slots whose value is not NULL                  *)
(* and Base's count (julia/base/iddict.jl:76 setindex! adds `inserted`,    *)
(* :102 pop! subtracts one per hit).                                       *)
(*                                                                         *)
(* The keys' hash is jl_object_id (iddict.c keyhash). A table can be an    *)
(* image constant, laid out natively by the ids the compiling process gave *)
(* its keys (Init's NativeId) and then used by the module (ModId): Julia's *)
(* image keeps every identity-keyed object's id (julia/src/staticdata.c:   *)
(* 1512 object_id_expected), and WasmTarget's image_slot! keeps it the     *)
(* same way (src/julia/runtime/hashing.jl), so ModId = NativeId.           *)
(*                                                                         *)
(* ABSTRACTION. A slot is a key-value pair of the C's 2*sz Memory{Any}     *)
(* (slot j is the C's index 2j, h2index's `* 2` and the probe's `+ 2`      *)
(* divided out); keys are atoms, so egal is equality; an id is a natural   *)
(* and the home slot its residue mod sz, h2index's `hv & (sz-1)` for a     *)
(* power of two. MaxProbe is a constant (the C's max_probe(sz) is 16 for   *)
(* every sz <= 1024, larger than these tables, so a small one exercises    *)
(* the bound the C's `iter <= maxprobe` sets); a full table grows by       *)
(* doubling (the C's `sz << 1` arm; its first growth to HT_N_INLINE and    *)
(* its `sz << 2` arm change no claim).                                     *)
(*                                                                         *)
(* Claims:                                                                 *)
(*   LookupAgrees    jl_eqtable_get of every key answers the map's value,  *)
(*                   or the default where the map holds none               *)
(*   OneSlotPerKey   no key is live in two slots                           *)
(*   NextindVisitsMap the live slots' keys are exactly the map's keys      *)
(*   CountAgrees     Base's count, kept from `inserted` and pop!'s hits,   *)
(*                   is the map's size                                     *)
(* Broken variants (MC*Broken.cfg): PopClearsKey (pop! stores NULL in the  *)
(* key slot, not `nothing`: a key probed past it is lost, LookupAgrees),   *)
(* NothingStops (a deleted slot ends the walk for the key `nothing` too:   *)
(* a live `nothing` past its own deleted slot is lost, LookupAgrees),      *)
(* IdsRecomputed (the module ids an image table's identity key anew,       *)
(* ModId # NativeId: the native layout misses, LookupAgrees).              *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Keys,           \* the keys, Nothing among them
    Nothing,        \* the deletion sentinel, a key too
    Vals,           \* the values
    NativeId,       \* each key's id as the compiling process gave it
    RecomputedId,   \* Broken: the id a module that keeps no image id gives
    InitPairs,      \* the image constant's pairs, a function on a subset of Keys
    Sizes,          \* the slot counts a table may have
    InitSize,       \* the image table's slot count
    MaxProbe,       \* the probe bound
    PopClearsKey,   \* Broken: pop! clears the key to NULL
    NothingStops,   \* Broken: a deleted slot ends the walk for `nothing` too
    IdsRecomputed   \* Broken: the module recomputes an identity key's id

NULL == "NULL"
Absent == "Absent"
KeyOrNull == Keys \cup {NULL}
ValOrNull == Vals \cup {NULL}

ModId == IF IdsRecomputed THEN RecomputedId ELSE NativeId

Empty(n) == [sz |-> n, key |-> [j \in 0..n-1 |-> NULL], val |-> [j \in 0..n-1 |-> NULL]]
Grow(n) == 2 * n

\* jl_table_peek_bp: the slot holding `k` live, or -1
RECURSIVE PeekLoop(_, _, _, _, _)
PeekLoop(T, k, idx, iter, orig) ==
    LET k2 == T.key[idx]
        n == (idx + 1) % T.sz
    IN IF k2 = NULL THEN -1
       ELSE IF k2 = k /\ T.val[idx] # NULL THEN idx
       ELSE IF k2 = k /\ (k # Nothing \/ NothingStops) THEN -1
       ELSE IF iter + 1 <= MaxProbe /\ n # orig THEN PeekLoop(T, k, n, iter + 1, orig)
       ELSE -1

PeekSlot(T, k, ids) == LET h == ids[k] % T.sz IN PeekLoop(T, k, h, 0, h)

\* jl_eqtable_get
Get(T, k, ids) == LET s == PeekSlot(T, k, ids) IN IF s = -1 THEN Absent ELSE T.val[s]

\* jl_table_assign_bp's walk: "found" at the live slot of `k`, else the first empty or deleted slot met (-1 if none)
RECURSIVE AssignLoop(_, _, _, _, _, _)
AssignLoop(T, k, idx, iter, orig, empty) ==
    LET k2 == T.key[idx]
        n == (idx + 1) % T.sz
        e2 == IF empty = -1 /\ (k2 = k \/ T.val[idx] = NULL) THEN idx ELSE empty
    IN IF k2 = NULL THEN [res |-> "empty", slot |-> IF empty = -1 THEN idx ELSE empty]
       ELSE IF k2 = k /\ T.val[idx] # NULL THEN [res |-> "found", slot |-> idx]
       ELSE IF iter + 1 <= MaxProbe /\ n # orig THEN AssignLoop(T, k, n, iter + 1, orig, e2)
       ELSE [res |-> "empty", slot |-> e2]

\* jl_table_assign_bp and jl_idtable_rehash, which call each other: the new table and `inserted`
RECURSIVE Assign(_, _, _, _), RehashFrom(_, _, _, _)
Assign(T, k, v, ids) ==
    LET h == ids[k] % T.sz
        r == AssignLoop(T, k, h, 0, h, -1)
    IN IF r.res = "found" THEN [tab |-> [T EXCEPT !.val[r.slot] = v], ins |-> 0]
       ELSE IF r.slot # -1 THEN [tab |-> [T EXCEPT !.key[r.slot] = k, !.val[r.slot] = v], ins |-> 1]
       ELSE Assign(RehashFrom(T, Empty(Grow(T.sz)), 0, ids), k, v, ids)
RehashFrom(T, N, i, ids) ==
    IF i = T.sz THEN N
    ELSE RehashFrom(T, IF T.val[i] # NULL THEN Assign(N, T.key[i], T.val[i], ids).tab ELSE N, i + 1, ids)

Rehash(T, n, ids) == RehashFrom(T, Empty(n), 0, ids)

\* the image constant: its pairs assigned natively in turn (any order gives a table holding them)
RECURSIVE BuildFrom(_, _)
BuildFrom(T, S) ==
    IF S = {} THEN T
    ELSE LET k == CHOOSE x \in S : TRUE IN BuildFrom(Assign(T, k, InitPairs[k], NativeId).tab, S \ {k})

VARIABLES tab, map, count
vars == <<tab, map, count>>

Live(T) == {j \in 0..T.sz-1 : T.val[j] # NULL}

TypeOK ==
    /\ tab.sz \in Sizes
    /\ tab.key \in [0..tab.sz-1 -> KeyOrNull]
    /\ tab.val \in [0..tab.sz-1 -> ValOrNull]
    /\ map \in [Keys -> Vals \cup {Absent}]
    /\ count \in Nat

Init ==
    /\ tab = BuildFrom(Empty(InitSize), DOMAIN InitPairs)
    /\ map = [k \in Keys |-> IF k \in DOMAIN InitPairs THEN InitPairs[k] ELSE Absent]
    /\ count = Cardinality(DOMAIN InitPairs)

\* Base's setindex! (julia/base/iddict.jl:76): jl_eqtable_put, count += inserted
Put == \E k \in Keys, v \in Vals :
    LET r == Assign(tab, k, v, ModId) IN
    /\ tab' = r.tab
    /\ map' = [map EXCEPT ![k] = v]
    /\ count' = count + r.ins

\* Base's pop! (julia/base/iddict.jl:102): jl_eqtable_pop, count -= 1 on a hit
Pop == \E k \in Keys :
    LET s == PeekSlot(tab, k, ModId) IN
    IF s = -1 THEN UNCHANGED vars
    ELSE /\ tab' = [tab EXCEPT !.key[s] = IF PopClearsKey THEN NULL ELSE Nothing, !.val[s] = NULL]
         /\ map' = [map EXCEPT ![k] = Absent]
         /\ count' = count - 1

\* Base's rehash! and sizehint! (julia/base/iddict.jl:61, :66): jl_idtable_rehash to a size of Base's choosing
RehashAct == \E n \in Sizes :
    /\ tab' = Rehash(tab, n, ModId)
    /\ UNCHANGED <<map, count>>

Next == Put \/ Pop \/ RehashAct
Spec == Init /\ [][Next]_vars

LookupAgrees == \A k \in Keys : Get(tab, k, ModId) = map[k]
OneSlotPerKey == \A i, j \in Live(tab) : i # j => tab.key[i] # tab.key[j]
NextindVisitsMap == {tab.key[j] : j \in Live(tab)} = {k \in Keys : map[k] # Absent}
CountAgrees == count = Cardinality({k \in Keys : map[k] # Absent})
=============================================================================
