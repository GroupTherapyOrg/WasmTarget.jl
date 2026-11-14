---------------------------- MODULE EgalDispatch ----------------------------
(***************************************************************************)
(* A TLA+ model of WT's `===` (emit_egal!, _emit_egal_same!, and the       *)
(* runtime egal function get_egal_function! defines and fill_egal_function!*)
(* fills; src/codegen/calls.jl) against Julia's own `===` (builtins.c      *)
(* jl_egal).                                                               *)
(*                                                                         *)
(* WHAT THE REAL CODE DOES. emit_egal! picks one arm from the operands'    *)
(* STATIC types: disjoint types are never egal; two String/Symbol operands *)
(* compare content; one concrete type compares in its representation      *)
(* (_emit_egal_same!: a singleton is its one instance, a primitive its     *)
(* bits, an immutable struct or closure every field by the same rule, a    *)
(* mutable object its identity, and a mutable callable struct, which may   *)
(* be its context or its closure object, goes to the runtime function);    *)
(* `nothing` against a value that may be `nothing` is its null/Nothing-    *)
(* class test; every other pair boxes both operands and calls the runtime  *)
(* egal function. That function's arms, in order (_egal_body):             *)
(*   1. `nothing` on either side: the other must be `nothing`;             *)
(*   2. identity (ref.eq) on the operands as given;                        *)
(*   (type objects and SimpleVector: not modeled, no value here is one)    *)
(*   3. a closure object is read as its context, unless that context is    *)
(*      the shared dummy one (a function used as a value);                 *)
(*   4. identity again, on the unwrapped operands;                         *)
(*   5. the closure-class arm: for each class in `closures` (numbered,     *)
(*      its context laid out, an immutable closure type), when the first   *)
(*      operand is a context of that class, the answer is: the second is   *)
(*      one too (classId), and every capture is egal;                      *)
(*   6. both operands classed (a context is not: it has no Object          *)
(*      header), one classId, then that class's rule when the class can be *)
(*      equal without being identical (a singleton answers 1); otherwise 0 *)
(*      (identity, already false).                                         *)
(* The body is filled after codegen (compile.jl), from the registries as   *)
(* they stand; filling can lay out a class (arm 6's _egal_rep registers an *)
(* immutable closure's context), so fill_egal_function! refills until the *)
(* registries stop growing.                                                *)
(*                                                                         *)
(* THE CLAIM. For every pair of values the static types admit, under every *)
(* order in which codegen numbers and lays out the closure classes, the    *)
(* answer is Julia's `===` (Agrees). A trap is never an answer. Seven      *)
(* Broken variants are the mistakes the arms exist to avoid: floats        *)
(* compared by value (0.0 === -0.0 would be true, NaN === NaN false),      *)
(* Strings by identity (two equal strings built apart would differ),       *)
(* immutable structs by identity (two equal-field values would differ),    *)
(* closures by reference (the code before batch 96: two closures of one    *)
(* type with equal captures differed, native 1, wasm 2; dev/AUDIT.md       *)
(* A7S1), closures unwrapped to their contexts even when the context is    *)
(* the dummy (batch 96: two functions used as values compared equal,       *)
(* native 18, wasm 118, A10B1), a mutable callable struct admitted to      *)
(* `closures` and compared by its fields (batch 96: native 2, wasm 1,      *)
(* A10B2), and the body filled once, before a closure class is laid out   *)
(* (batch 96 took the list at first use: native 1, wasm 2, A10B3).         *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. A value universe with one representative of  *)
(* every distinction the rules draw: Int64 0 and 1; Float64 0.0, -0.0 and  *)
(* two NaN payloads; two "a" Strings built apart and one "b"; two mutable  *)
(* objects with equal contents; two immutable structs with equal fields    *)
(* and one with another; `nothing`; a closure class Clo: two contexts with *)
(* equal captures built apart, a closure object wrapping the first (WT's   *)
(* two representations, A7S1), one with other captures; a second closure  *)
(* class CloL with two equal contexts; a mutable callable class MCall: two *)
(* instances with equal fields and an object wrapping the first; two      *)
(* functions of classes TA and TB used as values, holding the dummy        *)
(* context, and a second erasure of the TA function (a fresh object).      *)
(* A wasm reference is a name; a context's ref.test plus its classId field *)
(* is its class (two context types may share one wasm layout, which is    *)
(* why the arm reads the classId). Codegen numbers each closure class and  *)
(* may or may not lay out its context before the fill: the code lays out   *)
(* every context it builds, so a class only numbered when its values exist *)
(* is a superset of what codegen reaches, kept to check the refill.        *)
(* Static types are classes, `Any`, and Union{Nothing, Mut}. An operand    *)
(* held in a numeric register under a non-concrete type rejects at compile *)
(* time (loud) and is left out.                                            *)
(*                                                                         *)
(* formal(src/codegen/calls.jl emit_egal!): the arm the static types pick  *)
(* answers Julia's `===` for every pair of values they admit.              *)
(*                                                                         *)
(* parity(intrinsics.dart:1409 StaticIntrinsic.identical): static arms by  *)
(* the operands' types, else one runtime comparison (intrinsics.dart:2974  *)
(* MemberIntrinsic.identical: ref.eq, the null arm, the classId compare,   *)
(* one compare per value class); the value-struct arm is Julia's           *)
(* (builtins.c compare_fields); the closure arms are quarantined (a WT     *)
(* closure is its context or a closure object holding it, MARCH 13.17      *)
(* A7S1).                                                                  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS FloatByValue, StringByIdentity, ImmutableByIdentity,  \* TRUE = a broken rule
          ClosureByIdentity, UnwrapFirst, MutableByFields, FilledEarly

Values == {"i0", "i1", "f0", "fn0", "nan1", "nan2", "sa1", "sa2", "sb",
           "m1", "m2", "k0", "k0b", "k1", "nothing", "c0", "c0b", "c0o", "c1",
           "l0", "l0b", "mc1", "mc2", "mc1o", "t1", "t1b", "t2"}
Class(v) ==
    CASE v \in {"i0", "i1"} -> "Int64"
      [] v \in {"f0", "fn0", "nan1", "nan2"} -> "Float64"
      [] v \in {"sa1", "sa2", "sb"} -> "String"
      [] v \in {"m1", "m2"} -> "Mut"
      [] v \in {"k0", "k0b", "k1"} -> "Imm"
      [] v = "nothing" -> "Nothing"
      [] v \in {"c0", "c0b", "c0o", "c1"} -> "Clo"
      [] v \in {"l0", "l0b"} -> "CloL"
      [] v \in {"mc1", "mc2", "mc1o"} -> "MCall"
      [] v \in {"t1", "t1b"} -> "TA"
      [] v = "t2" -> "TB"
Payload(v) ==   \* bits (Int, Float), content (String), fields (Imm, closures), none otherwise
    CASE v = "i0" -> "0"  [] v = "i1" -> "1"
      [] v = "f0" -> "+0" [] v = "fn0" -> "-0" [] v = "nan1" -> "nanA" [] v = "nan2" -> "nanB"
      [] v \in {"sa1", "sa2"} -> "a" [] v = "sb" -> "b"
      [] v \in {"k0", "k0b"} -> "0" [] v = "k1" -> "1"
      [] v \in {"c0", "c0b", "c0o", "l0", "l0b", "mc1", "mc2", "mc1o"} -> "0" [] v = "c1" -> "1"
      [] OTHER -> v
FloatValue(v) == CASE v \in {"f0", "fn0"} -> "zero" [] OTHER -> "nan"   \* by value: NaN never equal
\* the Julia object a value is: an erasure of a mutable callable is that callable
JuliaObj(v) == IF v = "mc1o" THEN "mc1" ELSE v

\* Julia's `===`
JuliaEgal(a, b) ==
    /\ Class(a) = Class(b)
    /\ CASE Class(a) \in {"Int64", "Float64", "String", "Imm", "Clo", "CloL"} -> Payload(a) = Payload(b)
         [] Class(a) \in {"Mut", "MCall"} -> JuliaObj(a) = JuliaObj(b)
         [] OTHER -> TRUE   \* Nothing, and the singleton functions TA and TB

\* ---- WT's representations ----
\* the wasm reference a value is held as: a closure's context, a closure object, or the value
Ref(v) == CASE v = "c0" -> "x0" [] v = "c0b" -> "x0b" [] v = "c1" -> "x1" [] v = "c0o" -> "o0"
             [] v = "l0" -> "z0" [] v = "l0b" -> "z0b"
             [] v = "mc1" -> "y1" [] v = "mc2" -> "y2" [] v = "mc1o" -> "omc1"
             [] v = "t1" -> "ot1" [] v = "t1b" -> "ot1b" [] v = "t2" -> "ot2"
             [] OTHER -> v
IsObject(v) == v \in {"c0o", "mc1o", "t1", "t1b", "t2"}
\* the context a closure object holds: a function used as a value holds the shared dummy
Ctx(v) == CASE v = "c0o" -> "x0" [] v = "mc1o" -> "y1" [] OTHER -> "dummy"
\* a context's class (its ref.test and classId field) and captured fields; "none": not a context
CtxClass(r) == CASE r \in {"x0", "x0b", "x1"} -> "Clo" [] r \in {"z0", "z0b"} -> "CloL"
                 [] r \in {"y1", "y2"} -> "MCall" [] OTHER -> "none"
IsCtx(r) == CtxClass(r) # "none"
CtxFields(r) == IF r = "x1" THEN "1" ELSE "0"

ClosureClasses == {"Clo", "CloL", "MCall"}          \* is_closure_type: a callable with fields
MutableCallables == {"MCall"}
ValueClasses == {"Int64", "Float64", "String", "Imm"}    \* _egal_needs_value_compare
SingletonClasses == {"Nothing", "TA", "TB"}

\* one class's rule, as WT emits it (broken flags select the classic mistakes)
SameClass(a, b) ==
    CASE Class(a) = "Int64" -> Payload(a) = Payload(b)
      [] Class(a) = "Float64" ->
            IF FloatByValue THEN FloatValue(a) = "zero" /\ FloatValue(b) = "zero"
            ELSE Payload(a) = Payload(b)
      [] Class(a) = "String" -> IF StringByIdentity THEN a = b ELSE Payload(a) = Payload(b)
      [] Class(a) = "Imm" -> IF ImmutableByIdentity THEN a = b ELSE Payload(a) = Payload(b)
      [] Class(a) = "Mut" -> a = b
      [] Class(a) \in {"Clo", "CloL"} -> IF ClosureByIdentity THEN a = b ELSE Payload(a) = Payload(b)
      [] OTHER -> TRUE

\* ---- the registries and the fill ----
\* the lists _egal_body reads from the registries: `closures` (numbered, laid out, and
\* immutable unless MutableByFields) and the classed arm's classes (numbered, a singleton or
\* compared by value)
Lists(num, laid) ==
    [clo |-> {C \in num \cap laid : MutableByFields \/ C \notin MutableCallables},
     cls |-> ValueClasses \cup SingletonClasses \cup (num \ MutableCallables)]
\* what one fill lays out: arm 6's _egal_rep registers each numbered immutable closure's context
FillLays(num) == num \ MutableCallables

\* ---- the runtime egal function, on the body the fill wrote ----
\* arm 3: a closure object is its context unless that is the dummy (UnwrapFirst: always;
\* ClosureByIdentity: never, the code before batch 96)
U(v) == IF ~ClosureByIdentity /\ IsObject(v) /\ (UnwrapFirst \/ Ctx(v) # "dummy") THEN Ctx(v)
        ELSE Ref(v)
\* the classId of a classed reference after arm 3 (the dummy context is the `nothing` object)
UClass(v) == IF U(v) = "dummy" THEN "Nothing" ELSE Class(v)

B(p) == IF p THEN "T" ELSE "F"   \* an answer: "T", "F", or "trap"

Runtime(bd, a, b) ==
    IF a = "nothing" \/ b = "nothing" THEN B(a = b)                     \* 1. nothing
    ELSE IF Ref(a) = Ref(b) THEN "T"                                    \* 2. identity
    ELSE IF U(a) = U(b) THEN "T"                                        \* 3-4. unwrap, identity
    ELSE IF ~ClosureByIdentity /\ IsCtx(U(a)) /\ CtxClass(U(a)) \in bd.clo  \* 5. closures
         THEN B(CtxClass(U(b)) = CtxClass(U(a)) /\ CtxFields(U(a)) = CtxFields(U(b)))
    ELSE IF IsCtx(U(a)) \/ IsCtx(U(b)) THEN "F"                        \* 6. a context is not classed
    ELSE IF UClass(a) # UClass(b) THEN "F"                              \*    classIds differ
    ELSE IF UClass(a) \notin bd.cls THEN "F"                            \*    an identity class
    ELSE IF UClass(a) \in SingletonClasses THEN "T"
    ELSE IF UClass(a) \in ClosureClasses THEN "trap"   \* _emit_egal_class! casts an object to its context
    ELSE B(SameClass(a, b))

\* ---- emit_egal!'s static arms ----
Classes == {"Int64", "Float64", "String", "Mut", "Imm", "Nothing", "Clo", "CloL", "MCall", "TA", "TB"}
StaticTypes == Classes \cup {"Any", "NothingOrMut"}
Members(T) == IF T = "Any" THEN Values
              ELSE IF T = "NothingOrMut" THEN {"nothing", "m1", "m2"}
              ELSE {v \in Values : Class(v) = T}

Arm(T1, T2) ==
    IF Members(T1) \cap {v \in Values : \E w \in Members(T2) : Class(v) = Class(w)} = {}
    THEN "disjoint"
    ELSE IF T1 = T2 /\ T1 = "String" THEN "string"
    ELSE IF T1 = T2 /\ T1 \in MutableCallables THEN "runtime"   \* _emit_egal_same!'s last branch
    ELSE IF T1 = T2 /\ T1 \in Classes THEN "same"
    ELSE IF T1 = "Nothing" \/ T2 = "Nothing" THEN "nothingtest"
    ELSE "runtime"

Answer(bd, T1, T2, a, b) ==
    LET arm == Arm(T1, T2) IN
    CASE arm = "disjoint" -> "F"
      [] arm = "string" -> B(SameClass(a, b))
      [] arm = "same" -> B(SameClass(a, b))
      [] arm = "nothingtest" -> B((IF T1 = "Nothing" THEN b ELSE a) = "nothing")
      [] arm = "runtime" -> Runtime(bd, a, b)

\* ---- the compile: codegen numbers and lays out closure classes in any order, the `===` site
\* first uses the egal function, then the fill (FilledEarly: once, possibly before codegen ends)
VARIABLES numbered, laid, used, ended, fills, grew, body, t1, t2, x, y, answer, done
vars == <<numbered, laid, used, ended, fills, grew, body, t1, t2, x, y, answer, done>>

Init == /\ numbered = {} /\ laid = {} /\ used = FALSE /\ ended = FALSE
        /\ fills = 0 /\ grew = FALSE /\ body = Lists({}, {})
        /\ t1 = "Any" /\ t2 = "Any" /\ x = "nothing" /\ y = "nothing"
        /\ answer = "F" /\ done = FALSE

Number(C) == /\ ~ended /\ C \notin numbered       \* ensure_type_id! / assign_type_ids!
             /\ numbered' = numbered \cup {C}
             /\ UNCHANGED <<laid, used, ended, fills, grew, body, t1, t2, x, y, answer, done>>
Build(C) == /\ ~ended /\ C \notin laid            \* a %new: numbers it and lays out its context
            /\ numbered' = numbered \cup {C} /\ laid' = laid \cup {C}
            /\ UNCHANGED <<used, ended, fills, grew, body, t1, t2, x, y, answer, done>>
Use == /\ ~ended /\ ~used /\ used' = TRUE         \* get_egal_function! at the `===` site
       /\ UNCHANGED <<numbered, laid, ended, fills, grew, body, t1, t2, x, y, answer, done>>
EndCodegen == /\ ~ended /\ used /\ numbered = ClosureClasses   \* every class with values is numbered
              /\ ended' = TRUE
              /\ UNCHANGED <<numbered, laid, used, fills, grew, body, t1, t2, x, y, answer, done>>
Fill == /\ used
        /\ IF FilledEarly THEN fills = 0                \* one fill, whenever, no refill
           ELSE ended /\ (fills = 0 \/ grew)            \* after codegen, until nothing grows
        /\ body' = Lists(numbered, laid)
        /\ laid' = laid \cup FillLays(numbered)
        /\ grew' = (laid' # laid)
        /\ fills' = fills + 1
        /\ UNCHANGED <<numbered, used, ended, t1, t2, x, y, answer, done>>
Ask == /\ ended /\ fills > 0 /\ (FilledEarly \/ ~grew) /\ ~done
       /\ \E T1, T2 \in StaticTypes : \E a \in Members(T1), b \in Members(T2) :
            /\ t1' = T1 /\ t2' = T2 /\ x' = a /\ y' = b
            /\ answer' = Answer(body, T1, T2, a, b)
       /\ done' = TRUE
       /\ UNCHANGED <<numbered, laid, used, ended, fills, grew, body>>

\* the comparison has been asked: the end of the run, not a deadlock
Terminal == done /\ UNCHANGED vars
Next == \/ \E C \in ClosureClasses : Number(C) \/ Build(C)
        \/ Use \/ EndCodegen \/ Fill \/ Ask \/ Terminal
Spec == Init /\ [][Next]_vars

TypeOK == /\ numbered \subseteq ClosureClasses /\ laid \subseteq numbered
          /\ used \in BOOLEAN /\ ended \in BOOLEAN /\ grew \in BOOLEAN
          /\ fills \in 0..(Cardinality(ClosureClasses) + 1)
          /\ t1 \in StaticTypes /\ t2 \in StaticTypes /\ x \in Values /\ y \in Values
          /\ answer \in {"T", "F", "trap"} /\ done \in BOOLEAN

\* the answer is Julia's `===` (a trap never agrees)
Agrees == done => answer = B(JuliaEgal(x, y))
=============================================================================
