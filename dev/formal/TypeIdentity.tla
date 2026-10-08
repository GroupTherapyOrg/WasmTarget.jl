---------------------------- MODULE TypeIdentity ----------------------------
(***************************************************************************)
(* A TLA+ model of when two wasm type indices are one runtime type: the    *)
(* builder's structural deduplication (`add_type!`, `add_type_group!`,     *)
(* src/builder/instructions.jl) against wasm's iso-recursive               *)
(* canonicalization.                                                       *)
(*                                                                         *)
(* WASM. Two types are one runtime type when their recursion groups are    *)
(* structurally equal (same length; member by member the same fields, a    *)
(* reference inside the group compared by its position in the group, one   *)
(* outside it by the runtime type it names) and they sit at the same       *)
(* position. `ref.test` and `ref.cast` answer by runtime type. The groups  *)
(* are the ones WRITTEN: the writer computes them (recursion_groups) as    *)
(* the strongly connected components of the type graph, so a recorded      *)
(* group that is not one component would be written as its components.     *)
(*                                                                         *)
(* WT. A class's values have the type at its index. A class test reads the *)
(* classId (emit_isa_class_header!, as dart does), but a bare array, which *)
(* carries no header, is told by `ref.test` of its index                   *)
(* (bare_array_partition), and an index handed to a class is the type its  *)
(* values are built with: index inequality must be type inequality.        *)
(* `add_type!` returns an existing index for a type whose fields are       *)
(* equal; `add_type_group!` adds a recursion group, and raises             *)
(* (_module_invalid :add_type_group) unless its members are one strongly   *)
(* connected component, each reaching every other through references       *)
(* inside the group (one member refers to itself). A raised addition is a  *)
(* step the model never takes: the compile stops there. finish_pending!    *)
(* (src/codegen/structs.jl) passes only components (RecGroup.tla), so      *)
(* codegen never meets the guard; a builder-only program can.              *)
(*                                                                         *)
(* THE CLAIM. Two distinct indices are never one runtime type              *)
(* (IndexTellsType), an existing index handed back for a request is the    *)
(* runtime type requested (ServedIsRequested), and every group the builder *)
(* records is the group the writer writes (AddedGroupsAreComponents).      *)
(* Broken variants: a group added without looking for an equal one (the    *)
(* code before batch 81: two self-referential structs, LA and LB, got two  *)
(* indices for one runtime type, and `isa(x, LA)` of an LB answered 1 where *)
(* native answers 2, dev/AUDIT.md A5E4 = A5B3); add_type! taking a         *)
(* recursion group's member whose fields read equal (the code before batch *)
(* 82, AnyMember, A6B3); a group added without the component guard (the    *)
(* code before batch 89, NonComponent, A7B1); and, to show the             *)
(* served-index claim is not vacuous, a group equality that reads only     *)
(* lengths (LengthOnly, never WT code).                                    *)
(*                                                                         *)
(* THE GUARD'S WITNESS (MaxTypes 3, MaxReq 2). Add [Num] (index 1), then   *)
(* the group <<[Num], [in 1]>>. Its member 1 refers to nothing inside the  *)
(* group, so add_type_group! raises: its reach of member 1 is empty        *)
(* (test/module_builder_validation.jl's A7B1 case is this shape, a         *)
(* struct{} and a struct referring to it, and expects                      *)
(* ModuleValidationError). Without the guard the group is recorded at      *)
(* indices 2-3, member 1 is written alone, and index 2 is index 1's        *)
(* runtime type. The writer's comparison of the two records would refuse   *)
(* that module when it is written, but only after index 2 was handed out.  *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. A field is a number or a reference; a        *)
(* member's fields are a sequence; subtyping and mutability are fields of  *)
(* the same kind (equal or not). Every program of up to MaxReq additions,  *)
(* each a single type or any group of one or two members (a component or   *)
(* not), is checked.                                                       *)
(*                                                                         *)
(* formal(src/builder/instructions.jl add_type_group!): a group equal to   *)
(* one already in the section is that group, so an index is a runtime type. *)
(*                                                                         *)
(* parity(quarantine: wasm's iso-recursive type equivalence, which WT must *)
(* apply when it adds a group, since it numbers a type when it adds it;    *)
(* dart's _areGroupsStructurallyEqual, types.dart:106, compares heap types *)
(* by identity to decide which groups to brand, and brands equal flat      *)
(* class structs only with `uniqueTypes` (-O2); WT follows dart without    *)
(* it, where equal structs are one type and classes are told by classId.)  *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxTypes, MaxReq, NoGroupDedup, LengthOnlyEqual, AnyMemberEqual, NoComponentCheck

\* a field: Num, <<"in", k>> (member k of its own recorded group, 1-based), <<"ex", i>> (index i)
\* a section entry: [base |-> first index of its recorded group, len |-> that group's length,
\* pos, fields] -- the record add_type! and add_type_group! keep (type_groups)
VARIABLES types, nreq, served
vars == <<types, nreq, served>>

Num == <<"num", 0>>
FieldsOver(n, len) == {Num} \cup {<<"in", k>> : k \in 1..len} \cup {<<"ex", i>> : i \in 1..n}
Members(n, len) == UNION {[1..m -> FieldsOver(n, len)] : m \in 1..2}

\* the section entries of group ms appended to section sec
Entries(sec, ms) == [k \in 1..Len(ms) |->
                       [base |-> Len(sec) + 1, len |-> Len(ms), pos |-> k, fields |-> ms[k]]]

\* the writer's grouping (recursion_groups): the section's graph, each reference an edge to the
\* index it names, and the written group of index i its strongly connected component
AbsRef(sec, i, f) == IF f[1] = "in" THEN sec[i].base + f[2] - 1 ELSE f[2]
Succ(sec, i) == {AbsRef(sec, i, sec[i].fields[j]) :
                   j \in {j2 \in DOMAIN sec[i].fields : sec[i].fields[j2][1] # "num"}}
RECURSIVE ReachN(_, _, _)
ReachN(sec, i, n) == IF n = 0 THEN {}
                     ELSE Succ(sec, i) \cup UNION {ReachN(sec, j, n - 1) : j \in Succ(sec, i)}
Reach(sec, i) == ReachN(sec, i, Len(sec))
Written(sec, i) == {i} \cup {j \in Reach(sec, i) : i \in Reach(sec, j)}
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

\* the runtime type of index i in section sec: its WRITTEN group's members, a reference inside
\* that group by its position in it and one outside it by the runtime type it names, and its
\* position. A written group is a contiguous run: a reference leaves a recorded group only
\* backward, so a component lies inside one recorded group of consecutive indices.
RECURSIVE CanonIn(_, _)
CanonRef(sec, lo, n, a) == IF lo <= a /\ a < lo + n THEN <<"in", a - lo + 1>>
                           ELSE <<"ex", CanonIn(sec, a)>>
CanonIn(sec, i) ==
    LET W == Written(sec, i)
        lo == Min(W)
        n == Cardinality(W)
    IN <<[k \in 1..n |->
            [j \in DOMAIN sec[lo + k - 1].fields |->
               LET f == sec[lo + k - 1].fields[j]
               IN IF f[1] = "num" THEN f ELSE CanonRef(sec, lo, n, AbsRef(sec, lo + k - 1, f))]],
         i - lo + 1>>
Canon(i) == CanonIn(types, i)
\* the runtime type a request denotes: the type it would be if it were appended and written
CanonOfSingle(fs) == CanonIn(types \o Entries(types, <<fs>>), Len(types) + 1)
ReqCanon(ms, k) == CanonIn(types \o Entries(types, ms), Len(types) + k)

\* add_type!: a type with no inside reference is an existing index when that entry is its own
\* group with no inside reference and their fields are equal (the rule before 2026-10-06 also
\* took a recursion group's member whose fields read equal: AnyMemberEqual, A6B3)
Abs(i) == [j \in DOMAIN types[i].fields |->
            IF types[i].fields[j][1] = "in"
            THEN <<"ex", types[i].base + types[i].fields[j][2] - 1>> ELSE types[i].fields[j]]

Lone(i) == types[i].len = 1 /\ \A j \in DOMAIN types[i].fields : types[i].fields[j][1] # "in"
SingleEqual(i, fs) == Abs(i) = fs /\ (AnyMemberEqual \/ Lone(i))
AddType(fs) == /\ \A j \in DOMAIN fs : fs[j][1] # "in"
               /\ IF \E i \in DOMAIN types : SingleEqual(i, fs)
                  THEN /\ UNCHANGED types
                       /\ served' = served \cup {<<CanonOfSingle(fs), CHOOSE i \in DOMAIN types : SingleEqual(i, fs)>>}
                  ELSE /\ Len(types) < MaxTypes
                       /\ types' = Append(types, [base |-> Len(types) + 1, len |-> 1, pos |-> 1, fields |-> fs])
                       /\ served' = served

\* add_type_group!'s guard: the members are one strongly connected component, each reaching
\* every other (itself included) through references inside the group
RECURSIVE InReachN(_, _, _)
InSucc(ms, k) == {ms[k][j][2] : j \in {j2 \in DOMAIN ms[k] : ms[k][j2][1] = "in"}}
InReachN(ms, k, n) == IF n = 0 THEN {}
                      ELSE InSucc(ms, k) \cup UNION {InReachN(ms, q, n - 1) : q \in InSucc(ms, k)}
IsComponent(ms) == \A k \in 1..Len(ms) : 1..Len(ms) \subseteq InReachN(ms, k, Len(ms))

\* add_type_group!: a group that is not a component raises (_module_invalid :add_type_group),
\* so no step takes it (NoComponentCheck: the code before batch 89 added it); otherwise a group
\* whose members equal, position by position, an existing recorded group's (inside references
\* by position, outside ones by index) is that group
GroupEqual(b, ms) == /\ types[b].pos = 1 /\ types[b].len = Len(ms)
                     /\ \/ LengthOnlyEqual
                        \/ \A k \in 1..Len(ms) : types[b + k - 1].fields = ms[k]
AddGroup(ms) == /\ NoComponentCheck \/ IsComponent(ms)
                /\ IF ~NoGroupDedup /\ \E b \in DOMAIN types : GroupEqual(b, ms)
                   THEN LET b == CHOOSE x \in DOMAIN types : GroupEqual(x, ms) IN
                        /\ UNCHANGED types
                        /\ served' = served \cup {<<ReqCanon(ms, k), b + k - 1>> : k \in 1..Len(ms)}
                   ELSE /\ Len(types) + Len(ms) <= MaxTypes
                        /\ types' = types \o Entries(types, ms)
                        /\ served' = served

Init == types = <<>> /\ nreq = 0 /\ served = {}
\* any single type, or any group of one or two members over the section so far
Next == /\ nreq < MaxReq /\ nreq' = nreq + 1
        /\ \/ \E fs \in Members(Len(types), 1) : AddType(fs)
           \/ \E len \in 1..2 : \E ms \in [1..len -> Members(Len(types), len)] : AddGroup(ms)
Spec == Init /\ [][Next]_vars

IndexTellsType == \A i, j \in DOMAIN types : i # j => Canon(i) # Canon(j)
\* an existing index handed back for a request is the runtime type requested
ServedIsRequested == \A x \in served : Canon(x[2]) = x[1]
\* every recorded group is the group the writer writes (the comparison the writer makes,
\* instructions.jl to_bytes_mapped)
AddedGroupsAreComponents == \A i \in DOMAIN types :
                              Written(types, i) = types[i].base .. types[i].base + types[i].len - 1
=============================================================================
