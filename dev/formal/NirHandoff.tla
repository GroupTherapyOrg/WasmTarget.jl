--------------------------- MODULE NirHandoff ---------------------------------
(***************************************************************************)
(* A TLA+ model of the handoff from Julia's trim inference to the NIR: the   *)
(* closed world a compile reads, and the one NIR built from it.              *)
(*   check_subset (src/julia/subset.jl): Julia's trim inference of the entry *)
(*     (_infer_verified: typeinf_ext_toplevel, then Julia's verifier); the   *)
(*     @ccallable members the inferred world holds (_reached_ccallables),    *)
(*     each queued beside the entry as juliac queues one, svec(rettype,      *)
(*     signature), and the world inferred once more so the verifier judges   *)
(*     each declared signature and return.                                   *)
(*   build_nir (src/julia/nir.jl): every CodeInstance and CodeInfo pair of   *)
(*     that world, a queued record (svec) skipped as no body; a CodeInstance *)
(*     listed again (Julia's invokelatest queue compiles a queued ccallable  *)
(*     a second time) asserted equal to its first listing's code, else an    *)
(*     Internal rejection; each statement its NirStmt at its own position    *)
(*     (nir_code's comprehension over code), a form outside the census an    *)
(*     Unquarantined rejection (_nir_stmt's last line).                      *)
(* dart2wasm reads a Kernel component its front end hands it whole           *)
(* (translator.dart's Translator(component, ...)); a Julia program's        *)
(* component is the closed world Julia's own inference answers (D3), so the *)
(* only algorithm WasmTarget owns here is the ccallable round and the build. *)
(*                                                                           *)
(* WHY ONE CCALLABLE ROUND IS ENOUGH. A record infers its method at the      *)
(* declared signature, and Julia makes every declared argument type          *)
(* concrete (Base._ccallable, c.jl: "@ccallable: argument types must be      *)
(* concrete"), so the method has that one specialization: the record infers  *)
(* the CodeInstance the entry already reached, nothing new. AbstractRecord   *)
(* models a Julia without that rule: a record then infers another            *)
(* specialization, which reaches a ccallable the round never queued.         *)
(*                                                                           *)
(* ABSTRACTION. A specialization is a token; its body's invokes are Calls,   *)
(* fixed facts of the universe, and inference lists every specialization the *)
(* queue reaches (Reach). Which reached ccallables Julia lists twice         *)
(* (repeat), which of those repeats differ (differ: Julia gives no such      *)
(* world; build_nir asserts it), and which bodies hold a form outside the    *)
(* census (odd) are chosen in Init, so TLC checks every such world. A body's *)
(* code is its sequence of statement forms; a NIR statement is named by the  *)
(* form it reads. build_nir's loop takes the listed items one step each, in  *)
(* any order: its claims hold whatever order Julia lists them in.            *)
(*                                                                           *)
(* This model retires WT1's ClosedWorld (its own collection fixpoint over    *)
(* invokes, retargets and an import cut, src/codegen/trimcollect.jl) and     *)
(* NirBuild (src/frontend/nir.jl's classification): both files are gone, the *)
(* one replaced by Julia's inference, the other by this build.               *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   CcallablesJudged  every reached ccallable's record is queued, so the    *)
(*                     verifier judged its declared signature and return     *)
(*   QueuedReached     no record is queued for a ccallable the entry never   *)
(*                     reaches (an executable's queue, not a library's)      *)
(*   OneBodyPerCI      no CodeInstance has two bodies                        *)
(*   Complete          a built NIR holds a body for every reached            *)
(*                     specialization and for no other                       *)
(*   RepeatAsserted    a built NIR's every listing of a CodeInstance agrees  *)
(*                     with the code its body was built from                 *)
(*   Aligned           a body's i-th NIR statement reads its code's i-th     *)
(*   RejectsOnlyGaps   a rejection names a real gap: Internal only for a     *)
(*                     differing repeat, Unquarantined only for an odd form  *)
(*   Terminates        every run ends built or rejected                      *)
(* Broken variants: AbstractRecord (CcallablesJudged), QueueAll (a library's *)
(* queue: QueuedReached), NoDedup (OneBodyPerCI), UnreadRepeat (a repeat     *)
(* dropped unread: RepeatAsserted), SkipOdd (a form outside the census       *)
(* dropped: Aligned), RecordAsBody (a record read as a pair's half: a sound  *)
(* world rejects, RejectsOnlyGaps).                                          *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    AbstractRecord, \* Broken: a record infers a specialization other than the one reached
    QueueAll,       \* Broken: every ccallable of the image queued, reached or not
    NoDedup,        \* Broken: a repeated CodeInstance builds a second body
    UnreadRepeat,   \* Broken: a repeated CodeInstance skipped without comparing its code
    SkipOdd,        \* Broken: a statement form outside the census dropped from the body
    RecordAsBody    \* Broken: a queued record left among the pairs

\* the universe: E the entry; A and B ccallables it reaches; C a plain callee; D a ccallable
\* only Aany reaches, the specialization a record of A would infer were its signature abstract
Specs    == {"E", "A", "B", "C", "Aany", "D"}
Entry    == "E"
Calls(s) == CASE s = "E"    -> {"A", "C"}
              [] s = "A"    -> {"B"}
              [] s = "Aany" -> {"D"}
              [] OTHER      -> {}
CcSpecs  == {"A", "B", "D"}
RecordSpec(s) == IF AbstractRecord /\ s = "A" THEN "Aany" ELSE s

\* the forms nir_code reads (the census) and one outside it
Census == {"call", "invoke", "new", "return", "goto"}
Odd    == "weird"
BaseCode(s) == CASE s = "E"    -> <<"invoke", "invoke", "return">>
                 [] s = "A"    -> <<"invoke", "return">>
                 [] s = "B"    -> <<"call", "return">>
                 [] s = "C"    -> <<"new", "return">>
                 [] s = "Aany" -> <<"invoke", "return">>
                 [] s = "D"    -> <<"return">>

RepeatCand == CcSpecs     \* Julia lists a queued ccallable's CodeInstance again
OddCand    == {"C"}

VARIABLES repeat, differ, odd,     \* the world Julia gives (fixed after Init)
          phase, rounds, queue, listing, todo, seen, nir, count, verdict
vars == <<repeat, differ, odd, phase, rounds, queue, listing, todo, seen, nir, count, verdict>>

\* no body: every body Julia gives ends in a return, so an empty sequence is none
None == <<>>

Code(s) == IF s \in odd THEN <<Head(BaseCode(s)), Odd>> \o Tail(BaseCode(s)) ELSE BaseCode(s)
\* a listing's code: the first, or a repeat's, which differs when Julia's world says so
CodeOf(s, k) == IF k = 2 /\ s \in differ THEN <<"goto">> \o Code(s) ELSE Code(s)

RECURSIVE Closure(_)
Closure(S) == LET N == S \cup UNION {Calls(s) : s \in S} IN IF N = S THEN S ELSE Closure(N)

RootSpec(q) == IF q.kind = "mi" THEN q.spec ELSE RecordSpec(q.spec)
Reach(Q) == Closure({RootSpec(q) : q \in Q})

MI(s)  == [kind |-> "mi", spec |-> s]
Rec(s) == [kind |-> "rec", spec |-> s]
EntryQueue == {MI(Entry)}

\* what Julia's inference lists for a queue: each reached CodeInstance with its CodeInfo, a
\* repeated one twice, and each queued record
Listing(Q) ==
    {[kind |-> "ci", spec |-> s, copy |-> 1] : s \in Reach(Q)} \cup
    {[kind |-> "ci", spec |-> s, copy |-> 2] : s \in Reach(Q) \cap repeat} \cup
    {[kind |-> "svec", spec |-> q.spec, copy |-> 0] : q \in {q \in Q : q.kind = "rec"}}

InCensus(f) == f \in Census

TypeOK ==
    /\ repeat \subseteq RepeatCand /\ differ \subseteq repeat /\ odd \subseteq OddCand
    /\ phase \in {"infer", "build", "done", "rejected"}
    /\ rounds \in {0, 1}
    /\ todo \subseteq listing
    /\ DOMAIN seen = Specs /\ DOMAIN nir = Specs /\ DOMAIN count = Specs
    /\ verdict \in {"", "Internal", "Unquarantined"}

Init ==
    /\ repeat \in SUBSET RepeatCand
    /\ differ \in SUBSET repeat
    /\ odd \in SUBSET OddCand
    /\ phase = "infer" /\ rounds = 0 /\ queue = EntryQueue
    /\ listing = {} /\ todo = {}
    /\ seen = [s \in Specs |-> None] /\ nir = [s \in Specs |-> None] /\ count = [s \in Specs |-> 0]
    /\ verdict = ""

\* check_subset: infer the queue; a first round that reaches ccallables queues their records and
\* infers once more; the world then goes to build_nir, its records filtered out
Infer ==
    /\ phase = "infer"
    /\ LET L    == Listing(queue)
           cc   == {x.spec : x \in {x \in L : x.kind = "ci" /\ x.spec \in CcSpecs}}
           recs == {Rec(s) : s \in IF QueueAll THEN CcSpecs ELSE cc}
       IN IF rounds = 0 /\ recs # {}
          THEN /\ queue' = queue \cup recs /\ rounds' = 1 /\ listing' = L
               /\ UNCHANGED <<phase, todo>>
          ELSE /\ listing' = L
               /\ todo' = IF RecordAsBody THEN L ELSE {x \in L : x.kind = "ci"}
               /\ phase' = "build"
               /\ UNCHANGED <<queue, rounds>>
    /\ UNCHANGED <<repeat, differ, odd, seen, nir, count, verdict>>

Reject(v) == /\ verdict' = v /\ phase' = "rejected"
             /\ UNCHANGED <<repeat, differ, odd, rounds, queue, listing, todo, seen, nir, count>>

\* build_nir: one listed item
BuildItem == \E x \in todo :
    /\ phase = "build"
    /\ IF x.kind = "svec"
       THEN Reject("Internal")     \* only RecordAsBody leaves one: the pairs misalign
       ELSE LET s == x.spec
                c == CodeOf(s, x.copy)
            IN IF seen[s] = None \/ NoDedup
               THEN IF ~SkipOdd /\ \E i \in 1..Len(c) : ~InCensus(c[i])
                    THEN Reject("Unquarantined")
                    ELSE /\ seen' = [seen EXCEPT ![s] = c]
                         /\ nir' = [nir EXCEPT ![s] = SelectSeq(c, InCensus)]
                         /\ count' = [count EXCEPT ![s] = @ + 1]
                         /\ todo' = todo \ {x}
                         /\ UNCHANGED <<repeat, differ, odd, phase, rounds, queue, listing, verdict>>
               ELSE IF seen[s] = c \/ UnreadRepeat
                    THEN /\ todo' = todo \ {x}
                         /\ UNCHANGED <<repeat, differ, odd, phase, rounds, queue, listing, seen, nir, count, verdict>>
                    ELSE Reject("Internal")

\* the loop done: the entry's body asserted, the NirWorld made
Finish ==
    /\ phase = "build" /\ todo = {}
    /\ IF nir[Entry] = None THEN Reject("Internal")
       ELSE /\ phase' = "done"
            /\ UNCHANGED <<repeat, differ, odd, rounds, queue, listing, todo, seen, nir, count, verdict>>

Terminal == phase \in {"done", "rejected"} /\ UNCHANGED vars

Next == Infer \/ BuildItem \/ Finish \/ Terminal
Spec == Init /\ [][Next]_vars /\ WF_vars(Infer \/ BuildItem \/ Finish)

Judged == phase \in {"build", "done"}

CcallablesJudged == Judged => \A s \in Reach(queue) \cap CcSpecs : Rec(s) \in queue
QueuedReached    == \A q \in queue : q.kind = "rec" => q.spec \in Reach(EntryQueue)
OneBodyPerCI     == \A s \in Specs : count[s] <= 1
Complete         == phase = "done" => {s \in Specs : nir[s] # None} = Reach(queue)
RepeatAsserted   == phase = "done" =>
                        \A x \in listing : x.kind = "ci" => CodeOf(x.spec, x.copy) = seen[x.spec]
Aligned          == \A s \in Specs : nir[s] # None =>
                        /\ Len(nir[s]) = Len(seen[s])
                        /\ \A i \in 1..Len(nir[s]) : nir[s][i] = seen[s][i]
RejectsOnlyGaps  == phase = "rejected" =>
                        \/ verdict = "Internal" /\ differ # {}
                        \/ verdict = "Unquarantined" /\ odd # {}
Terminates       == <>(phase \in {"done", "rejected"})
=============================================================================
