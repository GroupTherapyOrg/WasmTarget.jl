----------------------- MODULE ObjectIdentityStrings --------------------------
(***************************************************************************)
(* ObjectIdentity (dev/formal/ObjectIdentity.tla), its every definition    *)
(* as it is, with objectid of a String beside it: a String's identity-hash *)
(* slot holds its data's id and nothing else.                               *)
(*                                                                           *)
(* dataids(::Memory) answers its data owner's slot (julia/base/            *)
(* abstractarray.jl:1591 reads the data's address, the String's bytes for  *)
(* every Memory over them, julia/src/genericmemory.c:113): ObjectIdentity's *)
(* DataIds fills a String's slot through the data owner's arm. objectid of *)
(* a String is its bytes' hash (julia/src/builtins.c:463 memhash_seed), a  *)
(* content id, and never reads the slot. WasmTarget ports no other reader  *)
(* of a String's slot: dart caches a String's hash there (sdk/lib/_internal/*)
(* wasm/js_common/js_string.dart:642), a cache src/runtime/js_common/       *)
(* js_string.jl does not hold.                                               *)
(*                                                                           *)
(* Added, never rewritten: the String objectids are a variable of their    *)
(* own, sseen, so ObjectIdentity's seen, Ids, TypeOK and every claim read  *)
(* what they read there; NextS is ObjectIdentity's Next, sseen unchanged,  *)
(* or objectid of a String; IdsS is Ids and the content ids.                *)
(*                                                                           *)
(* Claims (with every claim of ObjectIdentity, checked under SpecS):       *)
(*   TypeOKS             TypeOK, and sseen's ids in IdsS                   *)
(*   StringSlotDataOnly  a String's filled slot is the id dataids answered *)
(*                       for a Memory over its bytes, and every objectid   *)
(*                       answered for a String is its content id           *)
(* Broken variant (MCObjectIdentityStringsSlotReadBroken.cfg):              *)
(* StringSlotRead, objectid's write admitting a String (one widened rule   *)
(* where the data owner's arm is its own): objectid of a String reads the  *)
(* slot and fills it with a serial: StringSlotDataOnly.                     *)
(***************************************************************************)
EXTENDS ObjectIdentity

CONSTANT StringSlotRead   \* Broken: objectid of a String reads and fills its slot, as an identity's

VARIABLE sseen            \* every <<String, id>> objectid answered for a String
varsS == <<vars, sseen>>

\* a String's objectid: its bytes' hash, never its slot
ContentId(s) == <<"content", s>>
IdsS == Ids \cup {ContentId(s) : s \in Strs}

TypeOKS ==
    /\ TypeOK
    /\ sseen \subseteq (Strs \X IdsS)

InitS == Init /\ sseen = {}

\* objectid of a String (jl_object_id_'s String arm, builtins.c:463): its content id, the slot untouched; in
\* the Broken variant the identity's arm, ReadSlot, reading the slot and filling it with a serial (a spent
\* counter raises and records nothing)
ObjectIdStr(s) ==
    /\ s \in alive \cap Strs
    /\ IF StringSlotRead
          THEN IF slot[s] = 0 /\ ~RandomIds /\ counter > MaxSerial
                  THEN ReadSlot(s, LAMBDA id : sseen' = sseen \cup {<<s, id>>} /\ UNCHANGED <<seen, dseen>>) /\ sseen' = sseen
                  ELSE ReadSlot(s, LAMBDA id : sseen' = sseen \cup {<<s, id>>} /\ UNCHANGED <<seen, dseen>>)
          ELSE /\ sseen' = sseen \cup {<<s, ContentId(s)>>}
               /\ UNCHANGED <<slot, counter, raised, seen, dseen>>
    /\ UNCHANGED <<alive, owner>>
    /\ UnchangedConsts

NextS ==
    \/ Next /\ UNCHANGED sseen
    \/ \E s \in Strs : ObjectIdStr(s)

SpecS == InitS /\ [][NextS]_varsS

\* a String's slot holds its data's id and nothing else: a filled one is the id dataids answered for a Memory
\* over the String's bytes, and objectid of a String answers its bytes' hash, never the slot
StringSlotDataOnly ==
    /\ \A s \in Strs : slot[s] # 0 => \E m \in Mems : owner[m] = s /\ <<m, SerId(slot[s])>> \in dseen
    /\ \A p \in sseen : p[2] = ContentId(p[1])
=============================================================================
