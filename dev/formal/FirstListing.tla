--------------------------- MODULE FirstListing -------------------------------
(***************************************************************************)
(* A TLA+ model of how Julia's code generator reads the closed world its   *)
(* inference lists (julia/src/aotcompile.cpp:805-837 jl_emit_native_impl):  *)
(* each item a CodeInstance and its CodeInfo, one function compiled per     *)
(* CodeInstance, from its FIRST listing; a CodeInstance listed again is     *)
(* skipped by its identity (:814 `if (compiled_functions.count(codeinst))   *)
(* continue;`), unread. Julia lists one again when its invokelatest queue  *)
(* (Compiler/src/typeinfer.jl:1539-1557, its own inspected set) compiles a *)
(* finalizer's or a ccallable's specialization, reaching CodeInstances the *)
(* main queue listed; the repeat's CodeInfo may be another copy of the     *)
(* same code (mutable constants decompressed again), never another         *)
(* function. Two DISTINCT CodeInstances of one MethodInstance (inferred    *)
(* again, their rettype or effects possibly different) are two functions,  *)
(* each compiled: a caller invokes its own.                                 *)
(*   build_nir (src/julia/nir.jl) ports it: one body per CodeInstance, from *)
(*   its first listing, a repeat skipped by identity.                       *)
(* This adds to dev/formal/NirHandoff.tla, whose RepeatAsserted described   *)
(* build_nir asserting a repeat equal to its first listing (UnreadRepeat    *)
(* its Broken); Julia's own reading is this one.                            *)
(*                                                                          *)
(* ABSTRACTION. A CodeInstance is a token; its CodeInfo a copy number, two *)
(* copies of the same code. c1 and c3 are two CodeInstances of one         *)
(* MethodInstance m1; c2 is m2's. Init chooses every listing of up to four *)
(* items in which each CodeInstance appears, so TLC checks every order and *)
(* every repeat. The build takes the items in order, one step each.        *)
(*                                                                          *)
(* Claims:                                                                  *)
(*   EveryCIBuilt  a built world holds a body for every listed CodeInstance *)
(*   FirstWins     each body is built from its CodeInstance's first listing *)
(*   OneBody       no CodeInstance is built twice                           *)
(*   Terminates    the build ends                                           *)
(* Broken variants: LastWins (a repeat rebuilds the body from its later    *)
(* listing: OneBody, at its second build), ByMethod (a repeat skipped by its         *)
(* MethodInstance, so a second CodeInstance of one gets no function:       *)
(* EveryCIBuilt).                                                           *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    LastWins,   \* Broken: a repeat rebuilds its CodeInstance's body
    ByMethod    \* Broken: a repeat is found by MethodInstance, not by CodeInstance identity

CIs == {"c1", "c2", "c3"}
MI(c) == IF c = "c2" THEN "m2" ELSE "m1"
Copies == {1, 2}
Items == CIs \X Copies
MaxLen == 4

Listed(s) == {s[j][1] : j \in 1..Len(s)}
Listings == {s \in UNION {[1..n -> Items] : n \in 1..MaxLen} : Listed(s) = CIs}

\* the first listing of c in s, its copy
FirstCopy(s, c) == s[CHOOSE j \in 1..Len(s) : s[j][1] = c /\ \A k \in 1..(j - 1) : s[k][1] # c][2]

VARIABLES listing, pos, body, builds
vars == <<listing, pos, body, builds>>

\* body[c]: the copy c's function was built from, 0 none; builds[c]: how many times it was built
Init ==
    /\ listing \in Listings
    /\ pos = 1
    /\ body = [c \in CIs |-> 0]
    /\ builds = [c \in CIs |-> 0]

\* aotcompile.cpp:814: the item is skipped when its CodeInstance was compiled already
Skip(c) ==
    IF LastWins THEN FALSE
    ELSE IF ByMethod THEN \E d \in CIs : body[d] # 0 /\ MI(d) = MI(c)
    ELSE body[c] # 0

Step ==
    /\ pos <= Len(listing)
    /\ LET c == listing[pos][1]
           k == listing[pos][2]
       IN IF Skip(c)
          THEN UNCHANGED <<body, builds>>
          ELSE /\ body' = [body EXCEPT ![c] = k]
               /\ builds' = [builds EXCEPT ![c] = @ + 1]
    /\ pos' = pos + 1
    /\ UNCHANGED listing

Done == pos > Len(listing)
Next == Step \/ (Done /\ UNCHANGED vars)
Spec == Init /\ [][Next]_vars /\ WF_vars(Step)

TypeOK ==
    /\ pos \in 1..(MaxLen + 1)
    /\ body \in [CIs -> {0} \cup Copies]
    /\ builds \in [CIs -> 0..MaxLen]

EveryCIBuilt == Done => \A c \in CIs : body[c] # 0
FirstWins == Done => \A c \in CIs : body[c] # 0 => body[c] = FirstCopy(listing, c)
OneBody == \A c \in CIs : builds[c] <= 1
Terminates == <>Done
=============================================================================
