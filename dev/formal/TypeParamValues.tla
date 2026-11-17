--------------------------- MODULE TypeParamValues ----------------------------
(***************************************************************************)
(* formal(dev/formal/TypeParamValues.tla): the pass of closed_world_classes  *)
(* (src/julia/classes.jl) over a held class's parameters, where a parameter  *)
(* is a VALUE (beside TypeParamClasses.tla, whose parameters are types and   *)
(* type variables): a type value's constant holds its `parameters` svec     *)
(* (julia/src/jltypes.c:2089 inst_datatype_inner), a value of a bits type    *)
(* boxed in it (GenericMemory's Core.AddrSpace{Core}(0x00), a Val's Int64), *)
(* so each such value's class must be listed for the constant to be made    *)
(* (src/julia/classes.jl type_value_unmade, constant_unmade: a class with no *)
(* class info has no constant). A Vararg parameter (the abstract Tuple's) is *)
(* of no class: never met, the type value of its holder unmade.             *)
(*                                                                           *)
(* ABSTRACTION. A program lists some classes and holds a type value or not.  *)
(* Mem has a type parameter and a value of class AS; ValI a value of class   *)
(* I64; TupA (abstract) a Vararg. The pass meets each listed class's         *)
(* parameters where a type value is held, a value by its class.             *)
(*                                                                           *)
(* Claims:                                                                   *)
(*   TypeValuesMade   where a type value is held, every listed class whose  *)
(*                    parameters hold no Vararg has every parameter value's *)
(*                    class listed: its type value is made                  *)
(*   NoVarargClass    no class is listed for a Vararg                       *)
(* Broken variants: TypesOnly (the pass meets types and type variables      *)
(* alone: TypeValuesMade, Mem's AS never listed), MeetsVararg (the pass     *)
(* meets a Vararg as a value: NoVarargClass).                                *)
(***************************************************************************)
EXTENDS FiniteSets

CONSTANTS
    TypesOnly,    \* Broken: only type and type-variable parameters are met
    MeetsVararg   \* Broken: a Vararg parameter is met, its kind listed as a class

\* each class's parameters: [kind |-> "type" | "value" | "vararg", cls |-> the class the parameter brings]
Params(t) == CASE t = "Mem"  -> {[kind |-> "type", cls |-> "AnyT"], [kind |-> "value", cls |-> "AS"]}
               [] t = "ValI" -> {[kind |-> "value", cls |-> "I64"]}
               [] t = "TupA" -> {[kind |-> "vararg", cls |-> "VarargKind"]}
               [] OTHER      -> {}
Seeds  == {"Mem", "ValI", "TupA", "Str"}
Programs == {[cls |-> s, held |-> h] : s \in SUBSET Seeds, h \in BOOLEAN}

Met(p) == CASE p.kind = "type"   -> TRUE
            [] p.kind = "value"  -> ~TypesOnly
            [] p.kind = "vararg" -> MeetsVararg

\* the pass to its fixpoint: each listed class's met parameters' classes, where a type value is held
RECURSIVE Pass(_, _)
Pass(S, h) == LET N == S \cup (IF h THEN UNION {{p.cls : p \in {q \in Params(t) : Met(q)}} : t \in S} ELSE {})
              IN IF N = S THEN S ELSE Pass(N, h)

VARIABLE program
Init == program \in Programs
Next == UNCHANGED program
Spec == Init /\ [][Next]_program

Listed == Pass(program.cls, program.held)
TypeOK == program \in Programs
TypeValuesMade == program.held =>
    \A t \in Listed : (\A p \in Params(t) : p.kind # "vararg") =>
        \A p \in Params(t) : p.kind = "value" => p.cls \in Listed
NoVarargClass == "VarargKind" \notin Listed
=============================================================================
