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
(* ONE BOX, SEVERAL CAPTORS. Two closures can capture one box (a writer    *)
(* and a reader the creator returns together). Each reaches it through its *)
(* own field. A record keyed by (closure type, field) alone gives the      *)
(* reader's field only the creator's writes: the writer's 2.5 goes into    *)
(* the box the reader unboxes as an Int64 one (illegal cast; Julia answers *)
(* 2.5). The record joins every field that holds one box: a write through  *)
(* any of them is a write into each.                                       *)
(*                                                                         *)
(* A NESTED CAPTOR. A closure built inside a captor's body from the        *)
(* captor's own field (`%new(Ti, getfield(#self#, :c))`) holds the same    *)
(* box through its own field, at any depth. Its writes are writes into the *)
(* box: a `%new` of a closure type from a captured box field puts the new  *)
(* type's field in that field's class, so the creator's read, typed by the *)
(* record, sees them (NestedJoined). Before, the nested field was linked   *)
(* to nothing and itself erased as not created: the creator's read kept    *)
(* the direct captors' join, and a nested `c = 2.5` over a box the creator *)
(* filled with an Int64 unboxed as an Int64 one (illegal cast; Julia       *)
(* answers 1).                                                             *)
(*                                                                         *)
(* WHICH OPERAND CARRIES A CAPTOR. A write reaches the box through a      *)
(* `getfield(carrier, f)` of a captor's box field, and the record joins    *)
(* the write only if it keys that read (_captured_box_field). The carrier  *)
(* is `#self#` in the captor's own body, an SSA value (a closure a callee  *)
(* returned, its body inlined), an argument (a function taking the         *)
(* closure inlines the closure's body, and writes through its own          *)
(* parameter), or a constant: a closure held in a constant global, whose   *)
(* inlined call writes through `getfield(Main.g, :x)` (a mutable Box is no *)
(* inlineable constant, so Julia keeps the getfield). The nested captor's  *)
(* link is keyed the same way, from the operand its `%new` reads the field *)
(* through. The record keys every carrier by the operand's own type        *)
(* (value_type: a literal's Core.Typeof, a global's binding type), so      *)
(* every write joins (Recorded = AllWrites, by the relation). Keyed only   *)
(* through `#self#` and an SSA value, a write through an argument was      *)
(* dropped: the creator's read kept its own Int64 while the inlined captor *)
(* stored 2.5 (illegal cast; Julia answers 1). Keyed without the constant, *)
(* a constant closure's inlined write of 2.5 joined nothing while a read   *)
(* through an argument took the world's Int64 join (illegal cast; Julia    *)
(* answers 14).                                                            *)
(*                                                                         *)
(* THE CLAIM. The type a read carries covers every value the box can hold  *)
(* at run time (Covered), through every captor and in the creator. The     *)
(* Broken variants are the body-local guess, the per-field record, the     *)
(* nested captor left out of the join and a carrier the key does not read  *)
(* (an argument, a constant).                                              *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Two numeric types with Julia's promotion. A  *)
(* box has one creator write (its initial value, of a fixed type) and      *)
(* writes by three captor closures (two direct, one built inside the first *)
(* one's body), each write either a value of a fixed                       *)
(* type or the contents combined with an operand of a fixed type           *)
(* (`c = c + x`). A closure's reads are consumed by `c + x` for the        *)
(* operands its writes use. Every combination of creator type (or none:    *)
(* the creator declares the variable and never writes it) and closure      *)
(* writes is checked, each captor's writes and the nested captor's link   *)
(* carried by any operand kind.                                            *)
(*                                                                         *)
(* formal(src/codegen/box_capture.jl record_capture_contents): a captured  *)
(* box's read is typed by the join of every write into the box, its        *)
(* creator's included.                                                     *)
(*                                                                         *)
(* parity(closures.dart:1436 Capture.type): dart types a captured variable *)
(* by its declaration, in the function that declares it.                   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS BodyLocalGuess,  \* TRUE = the broken typing (the closure guesses alone)
          PerFieldRecord,  \* TRUE = the broken record: a captor's field joins only its own writes
          NestedJoined,    \* FALSE = the broken record: a nested captor's field joins nothing
          Keyed            \* the carriers the record's key reads (Carriers: every operand)

\* the operand a write's `getfield(carrier, f)` reads the box field through
Carriers == {"self", "ssa", "argument", "constant"}
ASSUME Keyed \subseteq Carriers

Captors == {"W", "R", "N"}   \* W and R capture the box directly; N is built inside W's body
Readers == Captors \cup {"creator"}

Types == {"Int64", "Float64"}
Promote(a, b) == IF a = "Float64" \/ b = "Float64" THEN "Float64" ELSE "Int64"
\* the join of a set of numeric types, as one type or both
Join(S) == S

\* a closure write: a value of type t, or the contents combined with an operand of type t
Writes == {[kind |-> "value", t |-> t] : t \in Types} \cup {[kind |-> "combine", t |-> t] : t \in Types}

VARIABLES init, ws, via, typing, done   \* ws[k]: captor k's writes; via[k]: the operand carrying
                                        \* them (for N, the one its `%new` links the field through);
                                        \* typing[k]: the type reader k's reads carry
vars == <<init, ws, via, typing, done>>

\* the types the box can hold given writes W: the creator's value (none: the box starts
\* undefined, and a read before any write throws), closed under W
RECURSIVE Hold(_, _, _)
Hold(S, W, n) ==
    LET step == S \cup {w.t : w \in {x \in W : x.kind = "value"}}
                  \cup {Promote(c, w.t) : c \in S, w \in {x \in W : x.kind = "combine"}}
    IN IF n = 0 \/ step = S THEN S ELSE Hold(step, W, n - 1)
Start == IF init = "none" THEN {} ELSE {init}
AllWrites == UNION {ws[k] : k \in Captors}
Runtime == Hold(Start, AllWrites, 4)

\* the field-join relation: a captor's writes join the box when the key reads their carrier;
\* the nested captor's when its link is made (NestedJoined) and keyed too
Reaches(k) == via[k] \in Keyed /\ (k = "N" => NestedJoined)
Recorded == UNION {ws[k] : k \in {c \in Captors : Reaches(c)}}
\* the record: every write the relation joins, the creator's included, iterated to a fixpoint
\* (BoxJoin); the per-field record joins a captor's own writes only
CreatorJoin == Hold(Start, Recorded, 4)
FieldJoin(k) == Hold(Start, ws[k], 4)

\* the body-local guess: the writes' own value types if any, else the operands the contents
\* is combined with; verified by typing each write with the guess assumed
Direct(k) == {w.t : w \in {x \in ws[k] : x.kind = "value"}}
Consumers(k) == {w.t : w \in {x \in ws[k] : x.kind = "combine"}}
Guess(k) == IF Direct(k) # {} THEN Direct(k) ELSE Consumers(k)
Verified(k) == \A w \in ws[k] : (IF w.kind = "value" THEN {w.t}
                                 ELSE {Promote(g, w.t) : g \in Guess(k)}) \subseteq Guess(k)
BodyTyping(k) == IF Guess(k) # {} /\ Verified(k) THEN Guess(k) ELSE Types   \* Types = left erased

Init == init \in Types \cup {"none"} /\ ws \in [Captors -> SUBSET Writes] /\ AllWrites # {}
        /\ via \in [Captors -> Carriers]
        /\ typing = [k \in Readers |-> {}] /\ done = FALSE
\* a captor whose reads the key does not read (or the nested one linked to no created box,
\* NestedJoined = FALSE) is not seeded: its reads stay erased (Types)
Step == ~done /\ typing' = [k \in Readers |-> IF k = "creator" THEN CreatorJoin
                                             ELSE IF ~Reaches(k) THEN Types
                                             ELSE IF BodyLocalGuess THEN BodyTyping(k)
                                             ELSE IF PerFieldRecord THEN FieldJoin(k)
                                             ELSE CreatorJoin]
        /\ done' = TRUE /\ UNCHANGED <<init, ws, via>>
Terminal == done /\ UNCHANGED vars   \* the one step has run: the end of the run, not a deadlock
Spec == Init /\ [][Step \/ Terminal]_vars

\* each captor's read type covers every value the box can hold
Covered == done \in BOOLEAN /\ (done => \A k \in Readers : Runtime \subseteq typing[k])
=============================================================================
