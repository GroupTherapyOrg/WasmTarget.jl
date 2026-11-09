--------------------------- MODULE TypeCacheLookup ---------------------------
(***************************************************************************)
(* A TLA+ model of the type Julia's apply_type finds at run time where its *)
(* operands are known only there (src/intrinsics.jl, the run_time_type     *)
(* arm, over src/julia/classes.jl apply_type_cache), against Julia's own   *)
(* answer.                                                                 *)
(*                                                                         *)
(* WHAT THE REAL CODE DOES. At compile time the cache is made whole: each  *)
(* operand's values are a literal's one or the members of the union Julia  *)
(* inferred for it, every key one split of those unions (Julia's           *)
(* switchtupleunion), each entry's type Julia's own fold of the call       *)
(* (apply_type_tfunc). At run time the lookup is Julia's                   *)
(* lookup_type_idx_linear (julia/src/jltypes.c:1078): the entries in       *)
(* order, the first whose key is equal to the operands answering. An       *)
(* operand of one value is compared with nothing (it can hold no other);   *)
(* every other operand is compared with the entry's by ref.eq. Past the    *)
(* last entry the lookup traps.                                            *)
(*                                                                         *)
(* THE MODEL. Each operand's values are a set of model values (Cands); a   *)
(* key a function from operands to values; Julia's fold is modeled as the  *)
(* key itself (an injective fold, the strictest: no two keys share an      *)
(* answer, so a lookup that confuses two keys is caught). The cache's      *)
(* entry order is every permutation of its keys.                           *)
(*                                                                         *)
(* THE CLAIMS. For every key the operands can hold, under every entry      *)
(* order: Total, the lookup never traps; Agrees, where it answers, the     *)
(* answer is Julia's fold of the operands' own key.                        *)
(*                                                                         *)
(* BROKEN. FirstOnly: the lookup compares only the first operand of more   *)
(* than one value, leaving another unread (breaks Agrees). Partial: the    *)
(* cache is made from the keys of one operand's first value only, as a     *)
(* cache keyed by the inferred type's first member would be (breaks        *)
(* Total).                                                                 *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Cands,      \* [1..N -> SUBSET Vals]: each operand's values
    FirstOnly,  \* BOOLEAN: the lookup compares one operand only
    Partial     \* BOOLEAN: the cache lacks keys

VARIABLE entries  \* the cache: a sequence of keys, its order

Ops == DOMAIN Cands
Vals == UNION {Cands[j] : j \in Ops}
\* every key the operands can hold at run time
Keys == {k \in [Ops -> Vals] : \A j \in Ops : k[j] \in Cands[j]}
\* the operands compared at run time: those of more than one value
Held == {j \in Ops : Cardinality(Cands[j]) > 1}
Min(S) == CHOOSE i \in S : \A x \in S : i <= x
Compared == IF FirstOnly /\ Held # {} THEN {Min(Held)} ELSE Held
\* the keys the cache is made of
Witness == Min(Held)
Made == IF Partial /\ Held # {}
          THEN {k \in Keys : k[Witness] = CHOOSE v \in Cands[Witness] : TRUE}
          ELSE Keys
Perms(S) == {s \in [1..Cardinality(S) -> S] : \A i, j \in 1..Cardinality(S) : i # j => s[i] # s[j]}

\* lookup_type_idx_linear: the entries whose compared operands are equal to the key's, the first of
\* them answering; none is the trap
Hits(k) == {i \in DOMAIN entries : \A j \in Compared : entries[i][j] = k[j]}

TypeOK == entries \in Perms(Made)

Init == entries \in Perms(Made)
Next == UNCHANGED entries
Spec == Init /\ [][Next]_entries

Total == \A k \in Keys : Hits(k) # {}
Agrees == \A k \in Keys : Hits(k) # {} => entries[Min(Hits(k))] = k
=============================================================================
