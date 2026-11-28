------------------------ MODULE ObjectIdSiteValues -------------------------
(***************************************************************************)
(* A TLA+ model of which classes an objectid site admits, beside            *)
(* ObjectIdDispatch.tla, whose sites' classes (recv) it takes as given. A   *)
(* site of an abstract operand admits the classes a value reaching it can   *)
(* have: the closed world's classes (src/julia/classes.jl                   *)
(* closed_world_classes, ValueClasses.tla) that the operand's type admits.  *)
(* That walk also meets each body's function type, the first parameter of  *)
(* its MethodInstance's signature (Julia's callee slot, jl_invoke's args[0],*)
(* julia/src/gf.c), a class no value need have: a singleton function whose *)
(* object is only ever the callee of its own call. A value of a class is    *)
(* held only where some body meets that class as a value (an argument after *)
(* the callee, a statement's type, a constant, a field), so a site admits    *)
(* the classes met as a value, never one met only as a function type. The  *)
(* second inference round of objectid's dispatch adds bodies whose function *)
(* types (jl_object_id, immut_id_, ...) a site of ::Function would admit,   *)
(* refusing every such site, though no value of them reaches it.           *)
(*                                                                           *)
(* ABSTRACTION. Classes are 0..N-1, the bodies 1..B in the walk's order,    *)
(* each with its function type callee[b] and the classes vals[b] it meets   *)
(* as values; a site's operand admits the classes op. The walk keeps the    *)
(* class list it always kept (met), and beside it the classes first met as *)
(* a function type and never met as a value since (calleeOnly): a callee    *)
(* slot of an unmet class marks it, a value meet unmarks it, a callee slot  *)
(* of a class already met changes nothing.                                  *)
(*                                                                           *)
(* Claims (at the end of the walk):                                        *)
(*   SiteCovers     every class a value reaching the site can have (held by *)
(*                  some body, admitted by the operand) the site admits    *)
(*   NoExtra        the site admits no class no body holds as a value       *)
(*   ListUnchanged  the class list is every class met, the function types   *)
(*                  among them, as before                                   *)
(* Broken variants: FunctionTypeCounted (a function-type-only class         *)
(* admitted: NoExtra), StaleCallee (a value meet leaves the mark: a class   *)
(* first met as a function type and then held is dropped: SiteCovers).      *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    N,                    \* classes are 0..N-1
    B,                    \* bodies are 1..B, in the walk's order
    FunctionTypeCounted,  \* Broken: a site admits a class met only as a function type
    StaleCallee           \* Broken: a value meet does not unmark a class first met as a function type

Classes == 0..(N - 1)
Bodies == 1..B

VARIABLES callee, vals, op, k, stage, met, calleeOnly, phase
vars == <<callee, vals, op, k, stage, met, calleeOnly, phase>>

\* the classes some body holds as a value
Held == UNION {vals[b] : b \in Bodies}
\* the classes the site admits
Admitted == {c \in met : c \in op /\ (FunctionTypeCounted \/ c \notin calleeOnly)}

TypeOK ==
    /\ callee \in [Bodies -> Classes]
    /\ vals \in [Bodies -> SUBSET Classes]
    /\ op \subseteq Classes
    /\ k \in Bodies
    /\ stage \in {"callee", "vals"}
    /\ met \subseteq Classes
    /\ calleeOnly \subseteq met
    /\ phase \in {"walk", "done"}

Init ==
    /\ callee \in [Bodies -> Classes]
    /\ vals \in [Bodies -> SUBSET Classes]
    /\ op \in SUBSET Classes
    /\ k = 1
    /\ stage = "callee"
    /\ met = {}
    /\ calleeOnly = {}
    /\ phase = "walk"

\* body k's function type: a class not met before is met and marked; one met before is unchanged
MeetCallee ==
    /\ phase = "walk" /\ stage = "callee"
    /\ IF callee[k] \in met
         THEN UNCHANGED <<met, calleeOnly>>
         ELSE /\ met' = met \cup {callee[k]}
              /\ calleeOnly' = calleeOnly \cup {callee[k]}
    /\ stage' = "vals"
    /\ UNCHANGED <<callee, vals, op, k, phase>>

\* body k's values: each met, and unmarked (StaleCallee leaves the mark)
MeetVals ==
    /\ phase = "walk" /\ stage = "vals"
    /\ met' = met \cup vals[k]
    /\ calleeOnly' = IF StaleCallee THEN calleeOnly ELSE calleeOnly \ vals[k]
    /\ stage' = "callee"
    /\ IF k = B THEN phase' = "done" /\ UNCHANGED k ELSE k' = k + 1 /\ UNCHANGED phase
    /\ UNCHANGED <<callee, vals, op>>

\* the walk ends: its terminal state stutters explicitly
Done == phase = "done" /\ UNCHANGED vars

Next == MeetCallee \/ MeetVals \/ Done
Spec == Init /\ [][Next]_vars /\ WF_vars(MeetCallee \/ MeetVals)

SiteCovers == phase = "done" => (Held \cap op) \subseteq Admitted

NoExtra == phase = "done" => Admitted \subseteq Held

ListUnchanged == phase = "done" => met = Held \cup {callee[b] : b \in Bodies}

Ends == <>(phase = "done")
=============================================================================
