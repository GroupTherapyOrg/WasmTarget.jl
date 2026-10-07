---------------------------- MODULE EgalDispatch ----------------------------
(***************************************************************************)
(* A TLA+ model of WT's `===` (emit_egal!, _emit_egal_same!, the runtime   *)
(* egal function; src/codegen/calls.jl) against Julia's own `===`          *)
(* (builtins.c jl_egal).                                                   *)
(*                                                                         *)
(* WHAT THE REAL CODE DOES. emit_egal! picks one arm from the operands'    *)
(* STATIC types: disjoint types are never egal; two String/Symbol operands *)
(* compare content; one concrete type compares in its representation      *)
(* (_emit_egal_same!: a singleton is its one instance, a primitive its     *)
(* bits, an immutable struct every field by the same rule, a mutable       *)
(* object its identity); `nothing` against a value that may be `nothing`   *)
(* is its null/Nothing-class test; every other pair boxes both operands    *)
(* and calls the runtime egal function, which compares classIds and then   *)
(* applies the same per-class rule.                                        *)
(*                                                                         *)
(* THE CLAIM. For every pair of values the static types admit, the answer  *)
(* is Julia's `===` (Agrees). Five Broken variants are the mistakes the    *)
(* arms exist to avoid: floats compared by value (0.0 === -0.0 would be    *)
(* true, NaN === NaN false), Strings by identity (two equal strings built  *)
(* apart would differ), immutable structs by identity (two equal-field     *)
(* values would differ), closures by reference (the code before batch 96:  *)
(* two closures of one type with equal captures differed, native 1, wasm   *)
(* 2, and two erasures of one closure trapped; dev/AUDIT.md A7S1), and     *)
(* closures unwrapped to their contexts before their classes are compared  *)
(* (batch 96: two functions used as values share one dummy context, and    *)
(* compared equal, native 18, wasm 118, A10B1).                            *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. A value universe with one representative of  *)
(* every distinction the rules draw: Int64 0 and 1; Float64 0.0, -0.0 and  *)
(* two NaN payloads; two "a" Strings built apart and one "b"; two mutable  *)
(* objects with equal contents; two immutable structs with equal fields    *)
(* and one with another; `nothing`; closures of one type: two contexts     *)
(* with equal captures built apart, a closure object wrapping the first    *)
(* (WT's two representations, A7S1), one with other captures, and two      *)
(* functions of other classes used as values, sharing the dummy context.   *)
(* Static                                                                    *)
(* types are classes, `Any`, and Union{Nothing, Mut}. An operand held in a *)
(* numeric register under a non-concrete type rejects at compile time      *)
(* (loud) and is left out.                                                 *)
(*                                                                         *)
(* formal(src/codegen/calls.jl emit_egal!): the arm the static types pick  *)
(* answers Julia's `===` for every pair of values they admit.              *)
(*                                                                         *)
(* parity(intrinsics.dart:1409 StaticIntrinsic.identical): static arms by  *)
(* the operands' types, else one runtime comparison; the value-struct arm  *)
(* is Julia's (builtins.c compare_fields).                                 *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS FloatByValue, StringByIdentity, ImmutableByIdentity,  \* TRUE = a broken rule
          ClosureByIdentity, UnwrapFirst

\* value -> [class, bits/content/fields, object identity]
Values == {"i0", "i1", "f0", "fn0", "nan1", "nan2", "sa1", "sa2", "sb",
           "m1", "m2", "k0", "k0b", "k1", "nothing", "c0", "c0b", "c0o", "c1", "t1", "t2"}
Class(v) ==
    CASE v \in {"i0", "i1"} -> "Int64"
      [] v \in {"f0", "fn0", "nan1", "nan2"} -> "Float64"
      [] v \in {"sa1", "sa2", "sb"} -> "String"
      [] v \in {"m1", "m2"} -> "Mut"
      [] v \in {"k0", "k0b", "k1"} -> "Imm"
      [] v = "nothing" -> "Nothing"
      [] v \in {"c0", "c0b", "c0o", "c1"} -> "Clo"
      [] v = "t1" -> "TA"
      [] v = "t2" -> "TB"
Payload(v) ==   \* bits (Int, Float), content (String), fields (Imm), none otherwise
    CASE v = "i0" -> "0"  [] v = "i1" -> "1"
      [] v = "f0" -> "+0" [] v = "fn0" -> "-0" [] v = "nan1" -> "nanA" [] v = "nan2" -> "nanB"
      [] v \in {"sa1", "sa2"} -> "a" [] v = "sb" -> "b"
      [] v \in {"k0", "k0b"} -> "0" [] v = "k1" -> "1"
      [] v \in {"c0", "c0b", "c0o"} -> "0" [] v = "c1" -> "1"
      [] OTHER -> v
\* the context a closure value holds: an object holds its closure's; a function used as a value
\* (a tear-off) and a closure with no captures hold the one shared dummy context
Ctx(v) == CASE v \in {"c0", "c0o"} -> "x0" [] v = "c0b" -> "x0b" [] v = "c1" -> "x1"
            [] v \in {"t1", "t2"} -> "dummy" [] OTHER -> v
FloatValue(v) == CASE v \in {"f0", "fn0"} -> "zero" [] OTHER -> "nan"   \* by value: NaN never equal

\* Julia's `===`
JuliaEgal(a, b) ==
    /\ Class(a) = Class(b)
    /\ CASE Class(a) \in {"Int64", "Float64", "String", "Imm", "Clo"} -> Payload(a) = Payload(b)
         [] Class(a) = "Mut" -> a = b
         [] OTHER -> TRUE

\* one class's rule, as WT emits it (broken flags select the classic mistakes)
SameClass(a, b) ==
    CASE Class(a) = "Int64" -> Payload(a) = Payload(b)
      [] Class(a) = "Float64" ->
            IF FloatByValue THEN FloatValue(a) = "zero" /\ FloatValue(b) = "zero"
            ELSE Payload(a) = Payload(b)
      [] Class(a) = "String" -> IF StringByIdentity THEN a = b ELSE Payload(a) = Payload(b)
      [] Class(a) = "Imm" -> IF ImmutableByIdentity THEN a = b ELSE Payload(a) = Payload(b)
      [] Class(a) = "Mut" -> a = b
      [] Class(a) = "Clo" -> IF ClosureByIdentity THEN a = b ELSE Payload(a) = Payload(b)
      [] OTHER -> TRUE

Classes == {"Int64", "Float64", "String", "Mut", "Imm", "Nothing", "Clo", "TA", "TB"}
StaticTypes == Classes \cup {"Any", "NothingOrMut"}
Members(T) == IF T = "Any" THEN Values
              ELSE IF T = "NothingOrMut" THEN {"nothing", "m1", "m2"}
              ELSE {v \in Values : Class(v) = T}

\* emit_egal!'s arm for the static types
Arm(T1, T2) ==
    IF Members(T1) \cap {v \in Values : \E w \in Members(T2) : Class(v) = Class(w)} = {}
    THEN "disjoint"
    ELSE IF T1 = T2 /\ T1 = "String" THEN "string"
    ELSE IF T1 = T2 /\ T1 \in Classes THEN "same"
    ELSE IF T1 = "Nothing" \/ T2 = "Nothing" THEN "nothingtest"
    ELSE "runtime"

Answer(T1, T2, a, b) ==
    LET arm == Arm(T1, T2) IN
    CASE arm = "disjoint" -> FALSE
      [] arm = "string" -> SameClass(a, b)
      [] arm = "same" -> SameClass(a, b)
      [] arm = "nothingtest" -> (IF T1 = "Nothing" THEN b ELSE a) = "nothing"
      [] arm = "runtime" -> IF UnwrapFirst /\ Ctx(a) = Ctx(b) /\ Class(a) \in {"Clo", "TA", "TB"}
                            THEN TRUE   \* unwrapped contexts compared before the classes (batch 96)
                            ELSE Class(a) = Class(b) /\ SameClass(a, b)

VARIABLES t1, t2, x, y, answer, done
vars == <<t1, t2, x, y, answer, done>>

Init == /\ t1 \in StaticTypes /\ t2 \in StaticTypes
        /\ x \in Members(t1) /\ y \in Members(t2)
        /\ answer = FALSE /\ done = FALSE
Step == ~done /\ answer' = Answer(t1, t2, x, y) /\ done' = TRUE /\ UNCHANGED <<t1, t2, x, y>>
Spec == Init /\ [][Step]_vars

Agrees == done \in BOOLEAN /\ (done => answer = JuliaEgal(x, y))
=============================================================================
