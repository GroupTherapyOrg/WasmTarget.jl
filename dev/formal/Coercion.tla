--------------------------- MODULE Coercion --------------------------------
(* formal(dev/formal/Coercion.tla): models convert_type! — the ONE coercion    *)
(* funnel (src/codegen/values.jl; parity translator.dart:1597 convertType) —   *)
(* over the whole finite lattice of wasm value representations, and claims     *)
(* that for EVERY (from, to) pair it either emits a sequence whose result      *)
(* type is a wasm subtype of `to`, or rejects loudly. Anchor: convert_type!.   *)
(***************************************************************************)
(* WHAT IS MODELED                                                           *)
(*                                                                           *)
(* convert_type!(b, from, to, ctx; from_julia) receives a value of wasm type  *)
(* `from` on the builder stack and must leave a value of type `to`. It is a   *)
(* decision tree over (from, to): numeric→ref boxes, ref→numeric unboxes,     *)
(* ref→ref bridges extern↔any / narrows nullability / downcasts through       *)
(* ref.cast, numeric→numeric runs the widening/narrowing ladder. Each arm      *)
(* emits a short instruction sequence. The claim that matters — the one the   *)
(* differential oracle cannot exhaust because every wrong pair needs its own   *)
(* program to reach it — is TOTALITY WITH CORRECT TYPING:                     *)
(*                                                                           *)
(*   Total: for all from # to, Emit(from, to) = REJECT or                     *)
(*          Sub(ResultType(from, Emit(from, to)), to)                         *)
(*                                                                           *)
(* i.e. no pair falls through an arm leaving the wrong representation on the  *)
(* stack, silently. A silent fallthrough validates far from its cause or, for *)
(* i64→i32, computes with the wrong width. The second claim mirrors dart's    *)
(* structure: an upcast emits NOTHING (NoRedundantCast).                      *)
(*                                                                           *)
(* WHAT IS ABSTRACTED, AND WHY IT SUFFICES                                    *)
(*                                                                           *)
(*  - The type universe is a small finite lattice with one representative per *)
(*    heap kind the real function distinguishes: the four numerics; the       *)
(*    abstract GC kinds any/eq/struct/array/i31; the extern, func and exn      *)
(*    hierarchies; two concrete structs S2 <: S1 <: struct; one concrete      *)
(*    array; the four numeric box structs (the boxing arm's targets); and the  *)
(*    classed string Str and its byte array StrArr (the string arms). Each ref *)
(*    kind appears nullable and non-null. Every branch of convert_type! is a   *)
(*    predicate over kind, hierarchy, nullability and the declared supertype  *)
(*    chain — never over the type INDEX — so one representative per kind      *)
(*    exercises every branch exactly as the real registry would.              *)
(*  - The closure-object wrap/unwrap arms (maybe_wrap_closure!, the .context   *)
(*    unwrap on a downcast to a closure struct) are omitted: they emit a       *)
(*    ref.cast to the same target after the wrap, so their result type is the *)
(*    downcast's; they are guarded by a registry lookup this model has no      *)
(*    counterpart for. The typing claim is unchanged by them.                  *)
(*  - Instruction sequences are abstract ops with the wasm typing rule of the  *)
(*    real opcode (ResultType folds them); the byte encoding is irrelevant.    *)
(*  - `from_julia` collapses to one BOOLEAN — whether a concrete Julia source  *)
(*    type is known — since the boxing arm reads nothing else from it.         *)
(*                                                                           *)
(* The spec walks the pair list deterministically (one pair per step) so a    *)
(* violation names its pair in a one-step trace.                              *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    DropNarrowingArm,       \* Broken: the ladder has no i64→i32 arm and no reject
                            \* (the silent fallthrough fixed in 752ad55e)
    CastBeforeUpcastCheck,  \* Broken: ref→ref downcasts before asking wasm_subtype
    IgnoreNullability       \* Broken: wasm_subtype ignores nullability (the P2 bug)

NumKinds == {"i32", "i64", "f32", "f64"}

Kinds == {"any", "eq", "struct", "array", "i31", "extern", "func", "exn",
          "S1", "S2", "A1", "Bi32", "Bi64", "Bf32", "Bf64", "Str", "StrArr"}

\* every type is a record [k, n]; numerics carry n = FALSE (they are never nullable)
Ref(k, n) == [k |-> k, n |-> n]
NumT(k) == [k |-> k, n |-> FALSE]
Num == {NumT(k) : k \in NumKinds}
Refs == {Ref(k, n) : k \in Kinds, n \in BOOLEAN}
Types == Num \cup Refs

IsRef(t) == t \in Refs
IsNum(t) == t \in Num

\* Heap kind of a ref (wasm_subtype's _wt_heap_kind): concrete structs collapse
\* to :concrete_struct, the array to :concrete_array.
Concrete == {"S1", "S2", "A1", "Bi32", "Bi64", "Bf32", "Bf64", "Str", "StrArr"}
ConcreteStructs == Concrete \ {"A1", "StrArr"}
ConcreteArrays == {"A1", "StrArr"}
AbstractGC == {"any", "eq", "struct", "array", "i31"}

Hier(k) == IF k = "extern" THEN "extern"
           ELSE IF k = "func" THEN "func"
           ELSE IF k = "exn" THEN "exn"
           ELSE "any"

\* the declared supertype chain: S2 <: S1; boxes, Str and S1 have no concrete super
ChainReaches(a, b) == a = b \/ (a = "S2" /\ b = "S1")

AbsKind(k) == IF k \in ConcreteStructs THEN "struct"
              ELSE IF k \in ConcreteArrays THEN "array"
              ELSE k

\* wasm_subtype(a, b) — values.jl:309, dart RefType.isSubtypeOf + DefType.isSubtypeOf.
\* This is the GROUND TRUTH the claims are checked against (the wasm type system).
Sub(a, b) ==
    IF a = b THEN TRUE
    ELSE IF IsNum(a) \/ IsNum(b) THEN FALSE
    ELSE IF a.n /\ ~b.n THEN FALSE
    ELSE IF Hier(a.k) # Hier(b.k) THEN FALSE
    ELSE IF Hier(a.k) # "any" THEN TRUE            \* extern<:extern, func<:func; exn only if equal kinds
    ELSE IF b.k \in Concrete THEN a.k \in Concrete /\ ChainReaches(a.k, b.k)
    ELSE IF b.k = "any" THEN TRUE
    ELSE IF b.k = "eq" THEN AbsKind(a.k) # "any"
    ELSE AbsKind(a.k) = b.k

\* The subtype test the ALGORITHM consults. Equal to the truth unless the Broken
\* IgnoreNullability variant models the pre-P2 wasm_subtype, which had no
\* nullability clause and so let a nullable source pass silently to a non-null sink.
AlgoSub(a, b) == IF IgnoreNullability /\ IsRef(a) /\ IsRef(b)
                 THEN Sub(Ref(a.k, FALSE), Ref(b.k, FALSE))
                 ELSE Sub(a, b)

DropNull(t) == IF IsRef(t) THEN Ref(t.k, FALSE) ELSE t

\* ---------------------------------------------------------------------------
\* Abstract instructions and their wasm typing (ResultType folds a sequence).
\*   <<"box", k>>            struct.new of box k: numeric → (ref k)
\*   <<"unbox", n>>          ref.cast (ref Bn) + struct.get: ref → n
\*   <<"extern_convert_any">>  (ref null? any) → (ref null? extern)
\*   <<"any_convert_extern">>  (ref null? extern) → (ref null? any)
\*   <<"as_non_null">>       (ref null k) → (ref k)
\*   <<"cast", k, n>>        ref.cast (ref null? k)
\*   <<"str_data">>          ref.cast $Str + struct.get data → (ref null StrArr)
\*   <<"str_wrap">>          the one string producer: (ref null StrArr) → (ref Str)
\*   <<"num", n>>            a numeric conversion opcode whose result is n
INVALID == [k |-> "INVALID", n |-> FALSE]   \* an opcode whose operand is outside its hierarchy: not valid wasm

\* Every cast-family op (ref.cast, the unbox cast, the string data cast) casts WITHIN
\* the any hierarchy; extern.convert_any needs an any-hierarchy operand and
\* any.convert_extern an extern one. Anything else is a validation error — the
\* loud-but-unlocated failure the funnel must never produce.
StepOK(t, op) ==
    CASE op[1] \in {"cast", "unbox", "str_data"} -> IsRef(t) /\ Hier(t.k) = "any"
      [] op[1] = "extern_convert_any"             -> IsRef(t) /\ Hier(t.k) = "any"
      [] op[1] = "any_convert_extern"             -> IsRef(t) /\ t.k = "extern"
      [] op[1] = "as_non_null"                    -> IsRef(t)
      [] op[1] = "str_wrap"                       -> IsRef(t) /\ t.k = "StrArr"
      [] op[1] = "box"                            -> IsNum(t)
      [] op[1] = "num"                            -> IsNum(t)

Step(t, op) ==
    IF t = INVALID \/ ~StepOK(t, op) THEN INVALID ELSE
    CASE op[1] = "box"                -> Ref(op[2], FALSE)
      [] op[1] = "unbox"              -> op[2]
      [] op[1] = "extern_convert_any" -> Ref("extern", t.n)
      [] op[1] = "any_convert_extern" -> Ref("any", t.n)
      [] op[1] = "as_non_null"        -> Ref(t.k, FALSE)
      [] op[1] = "cast"               -> Ref(op[2], op[3])
      [] op[1] = "str_data"           -> Ref("StrArr", TRUE)
      [] op[1] = "str_wrap"           -> Ref("Str", FALSE)
      [] op[1] = "num"                -> op[2]

RECURSIVE Fold(_, _)
Fold(t, ops) == IF ops = << >> THEN t ELSE Fold(Step(t, Head(ops)), Tail(ops))
ResultType(from, ops) == Fold(from, ops)

REJECT == <<"REJECT">>

\* ---------------------------------------------------------------------------
\* convert_type!(from, to; from_julia concrete?) — values.jl:406, arm by arm.
BoxKind(t) == CASE t.k = "i32" -> "Bi32" [] t.k = "i64" -> "Bi64"
                [] t.k = "f32" -> "Bf32" [] t.k = "f64" -> "Bf64"

Ladder(from, to) ==
    LET f == from.k
        t == to.k
    IN
    IF f = "i32" /\ t = "i64" THEN <<<<"num", to>>>>
    ELSE IF f = "i64" /\ t = "f64" THEN <<<<"num", to>>>>
    ELSE IF f = "i32" /\ t = "f64" THEN <<<<"num", to>>>>
    ELSE IF f = "f32" /\ t = "f64" THEN <<<<"num", to>>>>
    ELSE IF f = "i64" /\ t = "f32" THEN <<<<"num", to>>>>
    ELSE IF f = "i32" /\ t = "f32" THEN <<<<"num", to>>>>
    ELSE IF f = "i64" /\ t = "i32" /\ ~DropNarrowingArm THEN <<<<"num", to>>>>
    ELSE IF f = "f64" /\ t = "f32" THEN <<<<"num", to>>>>
    ELSE IF DropNarrowingArm THEN << >>           \* the old silent fallthrough
    ELSE REJECT

\* extern→GC then narrow if `to` is below any (the from === ExternRef arm)
\* Land a value of type `cur` (already in the any hierarchy) on `to`: nothing on an
\* upcast, ref.as_non_null when only nullability blocks it, else ref.cast to `to`'s
\* heap kind with `to`'s nullability (concrete index or abstract kind alike).
Narrow(cur, to) ==
    IF AlgoSub(cur, to) THEN << >>
    ELSE IF AlgoSub(DropNull(cur), to) THEN <<<<"as_non_null">>>>
    ELSE <<<<"cast", to.k, to.n>>>>

\* the extern hierarchy is bridged to/from any by exactly two ops; func and exn have
\* no bridge to anything, so a pair crossing into or out of them is inexpressible
Bridgeable(from, to) ==
    \/ Hier(from.k) = Hier(to.k)
    \/ (from.k = "extern" /\ Hier(to.k) = "any")
    \/ (to.k = "extern" /\ Hier(from.k) = "any")

RECURSIVE Emit(_, _, _)
Emit(from, to, conc) ==
    IF IsNum(from) /\ IsRef(to) THEN
        IF ~conc THEN REJECT
        ELSE IF AbsKind(to.k) \in {"array", "i31"} THEN REJECT   \* a box is a struct
        ELSE LET boxed == Ref(BoxKind(from), FALSE)
                 rest == Emit(boxed, to, conc)
             IN IF rest = REJECT THEN REJECT ELSE <<<<"box", BoxKind(from)>>>> \o rest
    ELSE IF IsRef(from) /\ IsNum(to) THEN
        IF from.k = "extern" THEN <<<<"any_convert_extern">>, <<"unbox", to>>>>
        ELSE IF Hier(from.k) # "any" THEN REJECT      \* a func/exn ref holds no box
        ELSE <<<<"unbox", to>>>>
    ELSE IF IsRef(from) /\ IsRef(to) THEN
        \* the string arms
        IF to.k = "StrArr" /\ from.k # "StrArr" THEN
            IF ~Bridgeable(from, to) THEN REJECT ELSE
            (IF from.k = "extern" THEN <<<<"any_convert_extern">>>> ELSE << >>)
            \o (IF from.k = "Str" THEN << >> ELSE <<<<"cast", "Str", FALSE>>>>)
            \o <<<<"str_data">>>>
            \o (IF to.n THEN << >> ELSE <<<<"as_non_null">>>>)
        ELSE IF from.k = "StrArr" /\ to.k # "StrArr" THEN
            LET wrapped == Ref("Str", FALSE)
                rest == IF to.k = "Str" THEN << >> ELSE Emit(wrapped, to, conc)
            IN IF rest = REJECT THEN REJECT ELSE <<<<"str_wrap">>>> \o rest
        \* dart convertType ref→ref with WT's extern boundary ops
        ELSE IF ~Bridgeable(from, to) THEN REJECT
        ELSE IF to.k = "extern" /\ from.k # "extern" THEN
            <<<<"extern_convert_any">>>> \o (IF from.n /\ ~to.n THEN <<<<"as_non_null">>>> ELSE << >>)
        ELSE IF from.k = "extern" /\ to.k # "extern" THEN
            <<<<"any_convert_extern">>>> \o Narrow(Ref("any", from.n), to)
        ELSE IF CastBeforeUpcastCheck THEN <<<<"cast", to.k, to.n>>>>
        ELSE Narrow(from, to)
    ELSE Ladder(from, to)

\* ---------------------------------------------------------------------------
\* The walk: one (from, to, conc) triple per step, in a fixed order.
Triples == {<<f, t, c>> : f \in Types, t \in Types, c \in BOOLEAN}

VARIABLES todo, checked, last, bad
vars == <<todo, checked, last, bad>>

\* One triple's verdicts (the claims, applied to a computed emission `out`).
TotalOK(f, t, c, out) == f = t \/ out = REJECT
                         \/ (ResultType(f, out) # INVALID /\ Sub(ResultType(f, out), t))

\* An upcast emits nothing (dart convertType: `if (from.isSubtypeOf(to)) return;`);
\* the string arms precede the subtype check by design.
NoRedundantCastOK(f, t, c, out) == out = REJECT
    \/ ~(IsRef(f) /\ IsRef(t) /\ Sub(f, t))
    \/ f.k = "StrArr" \/ t.k = "StrArr"
    \/ out = << >>

\* The funnel rejects only what the wasm type system cannot express.
RejectsOnlyInexpressibleOK(f, t, c, out) == out # REJECT
    \/ (IsNum(f) /\ IsRef(t) /\ ~c)                          \* boxing without a concrete Julia type
    \/ (IsNum(f) /\ IsNum(t))                                 \* a pair Julia never converts implicitly
    \/ (IsNum(f) /\ IsRef(t) /\ (AbsKind(t.k) \in {"array", "i31"}     \* a box is a struct, never an array/i31,
                                 \/ Hier(t.k) \in {"func", "exn"}))   \* and lives in the any hierarchy
    \/ (IsRef(f) /\ IsRef(t) /\ Hier(f.k) # Hier(t.k)
        /\ ~(f.k = "extern" /\ Hier(t.k) = "any")
        /\ ~(t.k = "extern" /\ Hier(f.k) = "any"))            \* cross-hierarchy, no bridge op
    \/ (IsRef(f) /\ IsNum(t) /\ Hier(f.k) # "any" /\ f.k # "extern")   \* unboxing a func/exn ref

Init == /\ todo = Triples
        /\ checked = {}
        /\ last = << >>
        /\ bad = {}

Next == /\ todo # {}
        /\ LET tr == CHOOSE x \in todo : TRUE
               out == Emit(tr[1], tr[2], tr[3])
               ok == /\ TotalOK(tr[1], tr[2], tr[3], out)
                     /\ NoRedundantCastOK(tr[1], tr[2], tr[3], out)
                     /\ RejectsOnlyInexpressibleOK(tr[1], tr[2], tr[3], out)
           IN /\ todo' = todo \ {tr}
              /\ checked' = checked \cup {tr}
              /\ last' = <<tr[1], tr[2], tr[3], out>>
              /\ bad' = IF ok THEN bad ELSE bad \cup {<<tr[1], tr[2], tr[3], out>>}

Spec == Init /\ [][Next]_vars

TypeOK == /\ todo \subseteq Triples
          /\ checked \subseteq Triples
          /\ last = << >> \/ Len(last) = 4

\* Per-step claims (a one-step trace names the first offending triple) …
Total == last = << >> \/ TotalOK(last[1], last[2], last[3], last[4])
NoRedundantCast == last = << >> \/ NoRedundantCastOK(last[1], last[2], last[3], last[4])
RejectsOnlyInexpressible == last = << >> \/ RejectsOnlyInexpressibleOK(last[1], last[2], last[3], last[4])

\* … and the whole-lattice claim: at the end of the walk nothing was flagged. Checked
\* on its own (without the per-step invariants) it lists EVERY offending triple at once.
AllPairsOK == todo # {} \/ bad = {}

Done == todo = {}
=============================================================================
