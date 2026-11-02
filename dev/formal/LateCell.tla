---------------------------- MODULE LateCell ----------------------------------
(***************************************************************************)
(* A TLA+ model of the cell for dart's `late final` field: Late{T},          *)
(* _late_get and _late_set! (src/julia/late.jl).                             *)
(*   Late{T}(anchor): a read before the assignment rejects Unported(anchor); *)
(*     a second assignment rejects Internal (LateInitializationError).       *)
(*   Late{T}(anchor, init): the first read runs init, its value the field's; *)
(*     an init that throws leaves the field unassigned, so a later read runs *)
(*     it again; a read from inside init rejects Internal (cyclic            *)
(*     initialization); an assignment rejects Internal.                      *)
(*   state: 0 unassigned, 1 its initializer running, 2 assigned.             *)
(* precedent(rust: OnceCell, set once; LazyCell, computed on first read).    *)
(*                                                                           *)
(* ABSTRACTION. One cell and its client, single threaded as the compiler is. *)
(* The client reads, assigns, or catches what an init threw; an init's body  *)
(* returns one of two values, throws, or reads its own field. depth counts   *)
(* the init calls running (a nested read is a nested call). A rejection      *)
(* ends the run, as reject! ends a compile. At most MaxOps client steps.     *)
(* kept records the value the field was first assigned, for Stable.         *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   Stable             an assigned field keeps the value first assigned     *)
(*   ReadsAgree         every read that returns returns the one value        *)
(*   NoDefaultRead      a read never returns a value nobody gave it          *)
(*   InitAtMostOnce     an init completes at most once                       *)
(*   OneInitAtATime     no init runs inside its own field's init             *)
(*   RejectsOnlyMisuse  an Internal rejection names a real misuse: a read   *)
(*                      inside init, an assignment of a field with an init,  *)
(*                      a second assignment                                  *)
(*   Ends               every run ends (PROPERTY)                            *)
(* Broken variants: DefaultRead (an unassigned read returns nothing:         *)
(* NoDefaultRead), NoMemo (init's value never stored: InitAtMostOnce),       *)
(* CycleReruns (a read inside init runs init again: OneInitAtATime),         *)
(* ThrowSticks (a throw leaves state 1, so a later read is taken for a       *)
(* cycle: RejectsOnlyMisuse), Overwrite (a second assignment replaces the    *)
(* value: Stable).                                                           *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    MaxOps,       \* the client's steps
    DefaultRead,  \* Broken: an unassigned read with no init returns nothing
    NoMemo,       \* Broken: init's value is returned but never stored
    CycleReruns,  \* Broken: a read inside init runs init again
    ThrowSticks,  \* Broken: an init that throws leaves the field in state 1
    Overwrite     \* Broken: a second assignment replaces the value

Values == {"v1", "v2"}
Nothing == "nothing"
NoHalt == [kind |-> "", cause |-> ""]

VARIABLES hasInit, state, value, depth, results, runs, ops, halt, kept
vars == <<hasInit, state, value, depth, results, runs, ops, halt, kept>>

TypeOK ==
    /\ hasInit \in BOOLEAN
    /\ state \in {0, 1, 2}
    /\ value \in Values \cup {Nothing} /\ kept \in Values \cup {Nothing}
    /\ depth \in Nat /\ runs \in Nat /\ ops \in 0..MaxOps
    /\ halt.kind \in {"", "Internal", "Unported"}

Init ==
    /\ hasInit \in BOOLEAN
    /\ state = 0 /\ value = Nothing /\ depth = 0 /\ results = <<>> /\ runs = 0 /\ ops = 0
    /\ halt = NoHalt /\ kept = Nothing

Live == halt = NoHalt
Reject(k, c) == /\ halt' = [kind |-> k, cause |-> c]
                /\ UNCHANGED <<hasInit, state, value, depth, results, runs, ops, kept>>

\* _late_get, from the client or (depth > 0) from inside init
Read ==
    /\ Live /\ (depth > 0 \/ ops < MaxOps)
    /\ IF state = 2 THEN /\ results' = Append(results, value)
                         /\ ops' = IF depth = 0 THEN ops + 1 ELSE ops
                         /\ UNCHANGED <<hasInit, state, value, depth, runs, halt, kept>>
       ELSE IF state = 1 /\ ~(CycleReruns /\ depth > 0)
            THEN Reject("Internal", IF depth > 0 THEN "selfread" ELSE "stale")
       ELSE IF ~hasInit
            THEN IF DefaultRead
                 THEN /\ results' = Append(results, Nothing) /\ ops' = ops + 1
                      /\ UNCHANGED <<hasInit, state, value, depth, runs, halt, kept>>
                 ELSE Reject("Unported", "unassigned")
       ELSE /\ state' = 1 /\ depth' = depth + 1
            /\ ops' = IF depth = 0 THEN ops + 1 ELSE ops
            /\ UNCHANGED <<hasInit, value, results, runs, halt, kept>>

\* init's body returns: the value stored (unless NoMemo) and returned to the read
InitReturns == \E v \in Values :
    /\ Live /\ depth > 0
    /\ value' = IF NoMemo THEN value ELSE v
    /\ kept' = IF NoMemo THEN kept ELSE v
    /\ state' = IF NoMemo THEN 0 ELSE 2
    /\ depth' = depth - 1 /\ runs' = runs + 1
    /\ results' = Append(results, v)
    /\ UNCHANGED <<hasInit, ops, halt>>

\* init's body throws: the field left unassigned (ThrowSticks: in state 1), the client catching it
InitThrows ==
    /\ Live /\ depth > 0
    /\ state' = IF ThrowSticks THEN 1 ELSE 0
    /\ depth' = depth - 1
    /\ UNCHANGED <<hasInit, value, results, runs, ops, halt, kept>>

\* _late_set!, from the client
Assign == \E v \in Values :
    /\ Live /\ depth = 0 /\ ops < MaxOps
    /\ IF hasInit THEN Reject("Internal", "assign-with-init")
       ELSE IF state = 2 /\ ~Overwrite THEN Reject("Internal", "second-assign")
       ELSE /\ value' = v /\ state' = 2 /\ ops' = ops + 1
            /\ kept' = IF state = 2 THEN kept ELSE v
            /\ UNCHANGED <<hasInit, depth, results, runs, halt>>

Done == ~Live \/ (depth = 0 /\ ops = MaxOps)
Terminal == Done /\ UNCHANGED vars

Next == Read \/ InitReturns \/ InitThrows \/ Assign \/ Terminal
Spec == Init /\ [][Next]_vars /\ WF_vars(Read \/ InitReturns \/ InitThrows \/ Assign)

Range(q) == {q[i] : i \in 1..Len(q)}

Stable            == state = 2 => value = kept
ReadsAgree        == \A i, j \in 1..Len(results) : results[i] = results[j]
NoDefaultRead     == Nothing \notin Range(results)
InitAtMostOnce    == runs <= 1
OneInitAtATime    == depth <= 1
RejectsOnlyMisuse == halt.kind = "Internal" => halt.cause \in {"selfread", "assign-with-init", "second-assign"}
Ends              == <>Done
=============================================================================
