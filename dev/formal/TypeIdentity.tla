---------------------------- MODULE TypeIdentity ----------------------------
(***************************************************************************)
(* A TLA+ model of when two wasm type indices are one runtime type: the     *)
(* builder's structural deduplication (`add_type!`, `add_type_group!`,      *)
(* src/builder/instructions.jl) against wasm's iso-recursive               *)
(* canonicalization.                                                       *)
(*                                                                         *)
(* WASM. Two types are one runtime type when their recursion groups are    *)
(* structurally equal (same length; member by member the same fields, a    *)
(* reference inside the group compared by its position in the group, one   *)
(* outside it by the runtime type it names) and they sit at the same       *)
(* position. `ref.test` and `ref.cast` answer by runtime type.             *)
(*                                                                         *)
(* WT. A class's values have the type at its index. Codegen reads index    *)
(* inequality as type inequality: `ref.test` of one index tells its class  *)
(* from a class at another (the concrete isa arm, bare_array_partition),    *)
(* and only classes at one index are told by classId                       *)
(* (is_shared_wasm_type). `add_type!` returns an existing index for a type *)
(* whose fields are equal; `add_type_group!` adds a recursion group.        *)
(*                                                                         *)
(* THE CLAIM. Two distinct indices are never one runtime type              *)
(* (IndexTellsType). Broken variant: a group added without looking for an  *)
(* equal one (the code before 2026-10-06: two self-referential structs,    *)
(* LA and LB, got two indices for one runtime type, and `isa(x, LA)` of an *)
(* LB answered 1 where native answers 2, dev/AUDIT.md A5E4 = A5B3).         *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. A field is a number or a reference; a        *)
(* member's fields are a sequence; subtyping and mutability are fields of  *)
(* the same kind (equal or not). Every program of up to MaxReq additions,  *)
(* each a single type or a group of up to two members, is checked.         *)
(*                                                                         *)
(* formal(src/builder/instructions.jl add_type_group!): a group equal to   *)
(* one already in the section is that group, so an index is a runtime type. *)
(*                                                                         *)
(* parity(pkg/wasm_builder/lib/src/builder/types.dart:106                   *)
(* _RecGroupBuilder._areGroupsStructurallyEqual): dart compares rec groups *)
(* the same way, and brands the equal ones so each class stays its own      *)
(* type (_assignBrandTypes); WT shares the index and tells the classes by  *)
(* classId.                                                                *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxTypes, MaxReq, NoGroupDedup

\* a field: Num, <<"in", k>> (member k of its own group, 1-based), <<"ex", i>> (index i)
\* a section entry: [base |-> first index of its group, len |-> group length, pos, fields]
VARIABLES types, nreq
vars == <<types, nreq>>

Num == <<"num", 0>>
FieldsOver(n, len) == {Num} \cup {<<"in", k>> : k \in 1..len} \cup {<<"ex", i>> : i \in 1..n}
Members(n, len) == UNION {[1..m -> FieldsOver(n, len)] : m \in 1..2}

\* the runtime type of index i: its group's members with outside references replaced by the
\* runtime type they name, and its position
RECURSIVE Canon(_)
CanonField(f) == IF f[1] # "ex" THEN f ELSE <<"ex", Canon(f[2])>>
CanonMember(i) == [j \in DOMAIN types[i].fields |-> CanonField(types[i].fields[j])]
Canon(i) == <<[k \in 1..types[i].len |-> CanonMember(types[i].base + k - 1)], types[i].pos>>

\* add_type!: a type with no inside reference is an existing index when its fields equal
\* that entry's, an inside reference read as the index it names
Abs(i) == [j \in DOMAIN types[i].fields |->
            IF types[i].fields[j][1] = "in"
            THEN <<"ex", types[i].base + types[i].fields[j][2] - 1>> ELSE types[i].fields[j]]
AddType(fs) == /\ \A j \in DOMAIN fs : fs[j][1] # "in"
               /\ IF \E i \in DOMAIN types : Abs(i) = fs
                  THEN UNCHANGED types
                  ELSE /\ Len(types) < MaxTypes
                       /\ types' = Append(types, [base |-> Len(types) + 1, len |-> 1, pos |-> 1, fields |-> fs])

\* add_type_group!: a group whose members equal, position by position, an existing group's
\* (inside references by position, outside ones by index) is that group
GroupEqual(b, ms) == /\ types[b].pos = 1 /\ types[b].len = Len(ms)
                     /\ \A k \in 1..Len(ms) : types[b + k - 1].fields = ms[k]
AddGroup(ms) == IF ~NoGroupDedup /\ \E b \in DOMAIN types : GroupEqual(b, ms)
                THEN UNCHANGED types
                ELSE /\ Len(types) + Len(ms) <= MaxTypes
                     /\ types' = types \o [k \in 1..Len(ms) |->
                            [base |-> Len(types) + 1, len |-> Len(ms), pos |-> k, fields |-> ms[k]]]

Init == types = <<>> /\ nreq = 0
Next == /\ nreq < MaxReq /\ nreq' = nreq + 1
        /\ \/ \E fs \in Members(Len(types), 1) : AddType(fs)
           \/ \E len \in 1..2 : \E ms \in [1..len -> Members(Len(types), len)] :
                 \* a group is a strongly connected component: every member refers inside it
                 /\ \A k \in 1..len : \E j \in DOMAIN ms[k] : ms[k][j][1] = "in"
                 /\ AddGroup(ms)
Spec == Init /\ [][Next]_vars

IndexTellsType == \A i, j \in DOMAIN types : i # j => Canon(i) # Canon(j)
=============================================================================
