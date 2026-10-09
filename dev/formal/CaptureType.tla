---------------------------- MODULE CaptureType ----------------------------
(***************************************************************************)
(* A TLA+ model of how a read of a captured variable's `Core.Box` contents *)
(* is typed (src/codegen/box_capture.jl; numeric_local_joins, context.jl). *)
(*                                                                         *)
(* WHAT THE REAL CODE DOES. Julia lowers a captured variable that is       *)
(* reassigned to a `Core.Box` whose `contents::Any` erases its type. WT    *)
(* recovers the type a read carries: before any body compiles, one         *)
(* fixpoint over the closed world (record_capture_contents) joins every    *)
(* write into each captured field -- the creator's (an argument typed by   *)
(* its signature) and every closure body's writing through the field --    *)
(* keyed by (closure type, field); a body's reads take the record          *)
(* (capture_read_types). Until 2026-09-28 a closure body compiled before   *)
(* its creator, or reading the box through a closure value a callee        *)
(* returned, had no record and guessed the type itself: the join of the    *)
(* other operands of the arithmetic consuming the contents, verified       *)
(* against the body's own writes with the guess assumed. The body never    *)
(* sees the creator's writes, and the verify is circular: `c = c + 1` over *)
(* a box its creator filled with 0.25 guessed Int64, verified Int64 + Int64 *)
(* = Int64, and the read unboxed a Float64 box as an Int64 one (illegal     *)
(* cast; Julia answers 2.25).                                               *)
(*                                                                         *)
(* THE CLAIM. The type a read carries covers every value the box can hold  *)
(* at run time (Covered). The Broken variant is the body-local guess.      *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Two numeric types with Julia's promotion. A  *)
(* box has one creator write (its initial value, of a fixed type) and      *)
(* closure writes, each either a value of a fixed type or the contents     *)
(* combined with an operand of a fixed type (`c = c + x`). The closure's   *)
(* reads are consumed by `c + x` for the operands its writes use. Every    *)
(* combination of creator type (or none: the creator declares the         *)
(* variable and never writes it) and closure writes is checked.            *)
(*                                                                         *)
(* formal(src/codegen/box_capture.jl record_capture_contents): a captured  *)
(* box's read is typed by the join of every write into the box, its        *)
(* creator's included.                                                     *)
(*                                                                         *)
(* parity(closures.dart:1436 Capture.type): dart types a captured variable *)
(* by its declaration, in the function that declares it.                   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS BodyLocalGuess   \* TRUE = the broken typing (the closure guesses alone)

Types == {"Int64", "Float64"}
Promote(a, b) == IF a = "Float64" \/ b = "Float64" THEN "Float64" ELSE "Int64"
\* the join of a set of numeric types, as one type or both
Join(S) == S

\* a closure write: a value of type t, or the contents combined with an operand of type t
Writes == {[kind |-> "value", t |-> t] : t \in Types} \cup {[kind |-> "combine", t |-> t] : t \in Types}

VARIABLES init, ws, typing, done
vars == <<init, ws, typing, done>>

\* the types the box can hold: the creator's value (none: the box starts undefined, and a read
\* before any write throws), closed under the closure's writes
RECURSIVE Hold(_, _)
Hold(S, n) ==
    LET step == S \cup {w.t : w \in {x \in ws : x.kind = "value"}}
                  \cup {Promote(c, w.t) : c \in S, w \in {x \in ws : x.kind = "combine"}}
    IN IF n = 0 \/ step = S THEN S ELSE Hold(step, n - 1)
Runtime == Hold(IF init = "none" THEN {} ELSE {init}, 4)

\* the creator's join: every write, its own included, iterated to a fixpoint (BoxJoin)
CreatorJoin == Runtime

\* the body-local guess: the writes' own value types if any, else the operands the contents
\* is combined with; verified by typing each write with the guess assumed
Direct == {w.t : w \in {x \in ws : x.kind = "value"}}
Consumers == {w.t : w \in {x \in ws : x.kind = "combine"}}
Guess == IF Direct # {} THEN Direct ELSE Consumers
Verified == \A w \in ws : (IF w.kind = "value" THEN {w.t}
                           ELSE {Promote(g, w.t) : g \in Guess}) \subseteq Guess
BodyTyping == IF Guess # {} /\ Verified THEN Guess ELSE Types   \* Types = left erased

Init == init \in Types \cup {"none"} /\ ws \in SUBSET Writes /\ ws # {} /\ typing = {} /\ done = FALSE
Step == ~done /\ typing' = (IF BodyLocalGuess THEN BodyTyping ELSE CreatorJoin)
        /\ done' = TRUE /\ UNCHANGED <<init, ws>>
Terminal == done /\ UNCHANGED vars   \* the one step has run: the end of the run, not a deadlock
Spec == Init /\ [][Step \/ Terminal]_vars

\* the read's type covers every value the box can hold
Covered == done \in BOOLEAN /\ (done => Runtime \subseteq typing)
=============================================================================
