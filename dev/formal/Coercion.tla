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
(*    classed string Str and its byte array StrArr (the string arms); a fixed  *)
(*    tuple Tf (an NTuple{k,E}) and the runtime-length tuple Tv               *)
(*    (Tuple{Vararg{E}}), whose arms build Tv from Tf. Each ref               *)
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
(*  - `from_julia`, the source value's own Julia type, collapses to what the  *)
(*    funnel reads from it (source_class): "none" (not stated), "class" (a     *)
(*    concrete type, the value's class), "nothing" (Nothing, a class too) and  *)
(*    "notclass" (an abstract type: the runtime-length tuple's own type, or a  *)
(*    sink's type a caller gave in its place, the A7E4 shape). Boxing needs a  *)
(*    class; so does a representation another class's layout shares (Tv: its  *)
(*    widening to a top type passes only for another class's struct).        *)
(*  - The runtime-length tuple's widening check lives in this funnel alone:   *)
(*    every sink converts through it, so the model's walk over every pair IS  *)
(*    the check's whole domain.                                               *)
(*                                                                           *)
(* Every triple is an initial state, its emission computed in it, so TLC     *)
(* checks each one and a violation's trace is the one offending triple.       *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    DropNarrowingArm,       \* Broken: the ladder has no i64→i32 arm and no reject
                            \* (the silent fallthrough fixed in 752ad55e)
    CastBeforeUpcastCheck,  \* Broken: ref→ref downcasts before asking wasm_subtype
    IgnoreNullability,      \* Broken: wasm_subtype ignores nullability (the P2 bug)
    CastTuple,              \* Broken: a value bound for the runtime-length tuple is cast to
                            \* it, never built (batches 97 and 99: an NTuple trapped, A9E4, A10E4)
    TrustStatedSource,      \* Broken: the widening check passes any stated source type, so a
                            \* sink's abstract type given as the source's lets the runtime-length
                            \* tuple reach a top type (A7E4)
    CastNothing,            \* Broken: `nothing` reaching a nullable single representation is
                            \* converted as a value (boxed, or cast), not made its null
    NothingNullOnlyConcrete,\* Broken: `nothing` is made null only at a nullable concrete sink; at
                            \* an abstract one (anyref, eqref, structref) it is boxed under
                            \* Nothing's class, a value no null test reads as `nothing`
    UnboxNothing            \* Broken: a `nothing` held in a reference (its null) bound for its
                            \* i32 placeholder or a non-null reference is unboxed or cast as a value:
                            \* the cast of the null traps

NumKinds == {"i32", "i64", "f32", "f64"}

\* what the funnel reads from `from_julia` (source_class)
SrcKinds == {"none", "class", "nothing", "notclass"}
SrcClass(c) == c \in {"class", "nothing"}

Kinds == {"any", "eq", "struct", "array", "i31", "extern", "func", "exn",
          "S1", "S2", "A1", "Bi32", "Bi64", "Bf32", "Bf64", "Str", "StrArr", "Tf", "Tv"}

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
Concrete == {"S1", "S2", "A1", "Bi32", "Bi64", "Bf32", "Bf64", "Str", "StrArr", "Tf", "Tv"}
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
\*   <<"tuple_build">>       emit_fixed_to_vararg_tuple!: an NTuple's fields into a fresh
\*                           runtime-length tuple: (ref null? Tf) → (ref Tv)
\*   <<"tuple_narrow", n>>   the narrowing to the runtime-length tuple (_narrow_ref!): the
\*                           value is Tv, or an NTuple built into it: any-hierarchy → (ref null? Tv)
\*   <<"drop_null", k>>      drop the value, ref.null of the nullable concrete k: any → (ref null k)
\*   <<"drop_placeholder">>  drop the value, `nothing`'s placeholder i32.const 0: any → i32
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
      [] op[1] = "tuple_build"                    -> IsRef(t) /\ t.k = "Tf"
      [] op[1] = "tuple_narrow"                   -> IsRef(t) /\ t.k \in {"any", "eq", "struct"}
      [] op[1] = "drop_null"                      -> TRUE
      [] op[1] = "drop_placeholder"               -> TRUE

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
      [] op[1] = "tuple_build"        -> Ref("Tv", FALSE)
      [] op[1] = "tuple_narrow"       -> Ref("Tv", op[2])
      [] op[1] = "drop_null"          -> Ref(op[2], TRUE)
      [] op[1] = "drop_placeholder"   -> NumT("i32")

RECURSIVE Fold(_, _)
Fold(t, ops) == IF ops = << >> THEN t ELSE Fold(Step(t, Head(ops)), Tail(ops))
ResultType(from, ops) == Fold(from, ops)

REJECT == <<"REJECT">>

\* ---------------------------------------------------------------------------
\* convert_type!(from, to; from_julia) — values.jl, arm by arm; c is source_class's reading.
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
    ELSE IF to.k = "Tv" /\ cur.k \in {"any", "eq", "struct"} /\ ~CastTuple
         THEN <<<<"tuple_narrow", to.n>>>>
    ELSE <<<<"cast", to.k, to.n>>>>

\* the extern hierarchy is bridged to/from any by exactly two ops; func and exn have
\* no bridge to anything, so a pair crossing into or out of them is inexpressible
Bridgeable(from, to) ==
    \/ Hier(from.k) = Hier(to.k)
    \/ (from.k = "extern" /\ Hier(to.k) = "any")
    \/ (to.k = "extern" /\ Hier(from.k) = "any")

Top == {"any", "eq", "struct", "extern"}

RECURSIVE Emit(_, _, _)
Emit(from, to, conc) ==
    \* `nothing` meeting a nullable reference of the any hierarchy is its null, whatever form it
    \* came in (a field's i32 placeholder, a tuple field's non-null singleton, a box): never
    \* boxed, never cast; one already in a nullable reference the sink admits is that null (an
    \* upcast, which emits nothing)
    IF conc = "nothing" /\ ~CastNothing /\ IsRef(to) /\ to.n /\ Hier(to.k) = "any" /\
       (IF NothingNullOnlyConcrete THEN to.k \in Concrete /\ ~(IsRef(from) /\ from.k \in Concrete /\ Sub(from, to))
        ELSE ~(IsRef(from) /\ from.n /\ Sub(from, to)))
    THEN <<<<"drop_null", to.k>>>>
    \* a `nothing` held in a reference (the null it is there) bound for its i32 placeholder or a
    \* non-null reference: never unboxed or cast, its placeholder, boxed under Nothing's class for
    \* a reference its box is (the box arm); any other register or reference holds no nothing
    ELSE IF conc = "nothing" /\ ~UnboxNothing /\ IsRef(from) /\ from # to /\
            (IsNum(to) \/ (~to.n /\ Hier(to.k) = "any" /\ ~Sub(from, to)))
    THEN IF to.k = "i32" THEN <<<<"drop_placeholder">>>>
         ELSE IF IsRef(to) /\ Sub(Ref("Bi32", FALSE), to) THEN <<<<"drop_placeholder">>, <<"box", "Bi32">>>>
         ELSE REJECT
    ELSE IF IsNum(from) /\ IsRef(to) THEN
        IF ~SrcClass(conc) THEN REJECT
        ELSE IF AbsKind(to.k) \in {"array", "i31"} THEN REJECT   \* a box is a struct
        ELSE LET boxed == Ref(BoxKind(from), FALSE)
                 rest == Emit(boxed, to, conc)
             IN IF rest = REJECT THEN REJECT ELSE <<<<"box", BoxKind(from)>>>> \o rest
    ELSE IF IsRef(from) /\ IsNum(to) THEN
        IF from.k = "extern" THEN <<<<"any_convert_extern">>, <<"unbox", to>>>>
        ELSE IF Hier(from.k) # "any" THEN REJECT      \* a func/exn ref holds no box
        ELSE <<<<"unbox", to>>>>
    ELSE IF IsRef(from) /\ IsRef(to) THEN
        \* the runtime-length tuple arms: widened to a slot of any class it rejects (its class
        \* is an NTuple{n,E} for its run-time n); a concrete struct bound for it is built into
        \* it when it is an NTuple of its element (Tf), else rejects
        \* (the one widening check: only another class's struct, its class stated, passes)
        IF from.k = "Tv" /\ to.k \in Top /\
           (IF TrustStatedSource THEN conc = "none" ELSE ~SrcClass(conc)) THEN REJECT
        ELSE IF to.k = "Tv" /\ from.k \in Concrete /\ from.k # "Tv" /\ ~CastTuple THEN
            IF from.k = "Tf" THEN <<<<"tuple_build">>>> ELSE REJECT
        \* the string arms
        ELSE IF to.k = "StrArr" /\ from.k # "StrArr" THEN
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
\* Every (from, to, source) triple, each an initial state.
Triples == {<<f, t, c>> : f \in Types, t \in Types, c \in SrcKinds}

VARIABLE last
vars == <<last>>

\* One triple's verdicts (the claims, applied to a computed emission `out`).
TotalOK(f, t, c, out) == f = t \/ out = REJECT
                         \/ (ResultType(f, out) # INVALID /\ Sub(ResultType(f, out), t))

\* An upcast emits nothing (dart convertType: `if (from.isSubtypeOf(to)) return;`);
\* the string arms precede the subtype check by design.
NoRedundantCastOK(f, t, c, out) == out = REJECT
    \/ ~(IsRef(f) /\ IsRef(t) /\ Sub(f, t))
    \/ f.k = "StrArr" \/ t.k = "StrArr"
    \/ out = << >>
    \/ (c = "nothing" /\ out = <<<<"drop_null", t.k>>>>)   \* a nothing is its null, the one exception

\* A value of a type whose values may be a fixed tuple (an NTuple, or any value) is never cast
\* to the runtime-length tuple, a struct an NTuple is not: the cast traps (A9E4, A10E4).
NoTupleCastOK(f, t, c, out) == out = REJECT \/ ~IsRef(f) \/
    f.k \notin {"Tf", "any", "eq", "struct", "extern"} \/
    \A i \in 1..Len(out) : ~(out[i][1] = "cast" /\ out[i][2] = "Tv")

\* The funnel rejects only what the wasm type system cannot express, and the runtime-length
\* tuple's own two rejections.
RejectsOnlyInexpressibleOK(f, t, c, out) == out # REJECT
    \/ (IsNum(f) /\ IsRef(t) /\ ~SrcClass(c))                \* boxing without the value's class
    \/ (IsNum(f) /\ IsNum(t))                                 \* a pair Julia never converts implicitly
    \/ (IsNum(f) /\ IsRef(t) /\ (AbsKind(t.k) \in {"array", "i31"}     \* a box is a struct, never an array/i31,
                                 \/ Hier(t.k) \in {"func", "exn"}))   \* and lives in the any hierarchy
    \/ (IsRef(f) /\ IsRef(t) /\ Hier(f.k) # Hier(t.k)
        /\ ~(f.k = "extern" /\ Hier(t.k) = "any")
        /\ ~(t.k = "extern" /\ Hier(f.k) = "any"))            \* cross-hierarchy, no bridge op
    \/ (IsRef(f) /\ IsNum(t) /\ Hier(f.k) # "any" /\ f.k # "extern")   \* unboxing a func/exn ref
    \/ (IsRef(f) /\ f.k = "Tv" /\ t.k \in Top /\ ~SrcClass(c))   \* its class is known only at run time
    \/ (t.k = "Tv" /\ (IsNum(f) \/ f.k \in Concrete \ {"Tf", "Tv"}))       \* only an NTuple of its element converts
    \/ (c = "nothing" /\ IsRef(f) /\ IsNum(t) /\ t.k # "i32")               \* a nothing has no other register
    \/ (c = "nothing" /\ IsRef(t) /\ ~t.n /\ ~Sub(Ref("Bi32", FALSE), t))   \* nor a non-null reference its box is not

\* A runtime-length tuple's representation reaches a slot of any class only as another class's
\* struct whose class the source type states: an abstract source type (the sink's, A7E4) or none
\* rejects, so no class read answers for Tuple{Vararg{E}}, which no value has.
NoUnclassedWideningOK(f, t, c, out) == out = REJECT \/
    ~(IsRef(f) /\ f.k = "Tv" /\ IsRef(t) /\ t.k \in Top /\ ~SrcClass(c))

\* `nothing` bound for any nullable reference of the any hierarchy (a nullable single
\* representation, anyref, eqref, structref) is its null: never boxed, never cast, so the one
\* null test (`isa(x, Nothing)`, `x === nothing`) reads it.
NothingIsNullOK(f, t, c, out) == out = REJECT \/
    ~(c = "nothing" /\ IsRef(t) /\ t.n /\ Hier(t.k) = "any" /\ ~(IsRef(f) /\ f.n /\ Sub(f, t))) \/
    \A i \in 1..Len(out) : out[i][1] \notin {"box", "cast", "unbox"}

\* `nothing` held in a reference is its null there: bound for a register or a reference of the any
\* hierarchy it is never unboxed, cast to a non-null type or made non-null (each traps on the
\* null); it is dropped for its placeholder.
NothingNeverCastOK(f, t, c, out) == out = REJECT \/ out = << >> \/
    ~(c = "nothing" /\ IsRef(f) /\ (IsNum(t) \/ Hier(t.k) = "any")) \/
    ~(out[1][1] = "unbox" \/ out[1][1] = "as_non_null" \/ (out[1][1] = "cast" /\ ~out[1][3]))

\* one state per triple: the triple and the funnel's emission for it
Init == last \in {<<tr[1], tr[2], tr[3], Emit(tr[1], tr[2], tr[3])>> : tr \in Triples}
Next == UNCHANGED vars
Spec == Init /\ [][Next]_vars

TypeOK == Len(last) = 4 /\ <<last[1], last[2], last[3]>> \in Triples

\* The claims, each checked in every triple's state
Total == TotalOK(last[1], last[2], last[3], last[4])
NoRedundantCast == NoRedundantCastOK(last[1], last[2], last[3], last[4])
RejectsOnlyInexpressible == RejectsOnlyInexpressibleOK(last[1], last[2], last[3], last[4])
NoTupleCast == NoTupleCastOK(last[1], last[2], last[3], last[4])
NoUnclassedWidening == NoUnclassedWideningOK(last[1], last[2], last[3], last[4])
NothingIsNull == NothingIsNullOK(last[1], last[2], last[3], last[4])
NothingNeverCast == NothingNeverCastOK(last[1], last[2], last[3], last[4])
=============================================================================
