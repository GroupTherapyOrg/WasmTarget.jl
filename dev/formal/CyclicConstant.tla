--------------------------- MODULE CyclicConstant ---------------------------
(***************************************************************************)
(* A TLA+ model of a cyclic constant's emission (src/constants.jl, a lazy   *)
(* constant's initializer for a group of objects that reach each other):    *)
(* the image constant of a Core.Binding and its GlobalRef, which Julia's    *)
(* runtime builds as a cycle, allocate then set: new_binding allocates the  *)
(* Binding with globalref NULL, makes the immutable GlobalRef(mod, name, b) *)
(* and then writes b->globalref (julia/src/module.c:769-780), Binding's one *)
(* const field (julia/src/jltypes.c:3281 binding_constfields). dart's       *)
(* constants are acyclic; a cycle takes dart's lazy constant initializer    *)
(* (constants.dart: a lazy global and its init function, which makes the    *)
(* object and stores the global before the read returns it), in Julia's    *)
(* allocate-then-set order.                                                  *)
(*                                                                          *)
(* ABSTRACTION. Four objects: B (a Binding, a mutable struct), G (its       *)
(* GlobalRef, immutable), P (a BindingPartition, mutable, B's partitions)   *)
(* and M (a Module, a leaf constant made before). Fields, each with its     *)
(* target: B.globalref -> G, B.partitions -> P, G.binding -> B, G.mod -> M. *)
(* A field is wasm-mutable where Julia's struct is mutable and the field   *)
(* not const, or where Julia's runtime writes the const field after       *)
(* allocation (ClassField.runtime_written, an exact list pinned to the C   *)
(* line that writes it: B.globalref, module.c:780). The init function:     *)
(* Alloc(o) is struct.new, every field's target allocated or, for a        *)
(* closing field, null; Set(o, f) is struct.set of a closing field; Publish*)
(* stores the global; Read is the program's read through the global.       *)
(*                                                                          *)
(* Claims:                                                                  *)
(*   Complete     once the init returns, every field holds its target      *)
(*   NoEarlyRead  no read sees a null field                                *)
(*   Valid        every Set wrote a wasm-mutable field                     *)
(*   Ends         the init returns                                         *)
(* Broken: MCCyclicConstantEagerBroken.cfg (EagerCycle), each object an    *)
(* eager global made with a null where its target is not yet made and      *)
(* never set: Complete fails. MCCyclicConstantEarlyBroken.cfg             *)
(* (EarlyPublish), the global stored before the closing set: a read sees   *)
(* the null, NoEarlyRead fails. MCCyclicConstantImmutableBroken.cfg        *)
(* (ImmutableClose), the cycle closed through G's immutable field: Valid   *)
(* fails.                                                                   *)
(***************************************************************************)
CONSTANTS EagerCycle, EarlyPublish, ImmutableClose

Objs   == {"B", "G", "P"}
Leaves == {"M"}
Fields == {"B.globalref", "B.partitions", "G.binding", "G.mod"}
Owner  == [f \in Fields |-> CASE f = "B.globalref" -> "B" [] f = "B.partitions" -> "B"
                              [] f = "G.binding" -> "G" [] f = "G.mod" -> "G"]
Target == [f \in Fields |-> CASE f = "B.globalref" -> "G" [] f = "B.partitions" -> "P"
                               [] f = "G.binding" -> "B" [] f = "G.mod" -> "M"]
MutableStruct == {"B", "P"}
ConstField    == {"B.globalref"}            \* jltypes.c:3281 binding_constfields
SetAfterAlloc == {"B.globalref"}            \* ClassField.runtime_written: module.c:780 new_binding
WasmMutable(f) == (Owner[f] \in MutableStruct /\ f \notin ConstField) \/ f \in SetAfterAlloc
Close == IF EagerCycle THEN {} ELSE IF ImmutableClose THEN {"G.binding"} ELSE {"B.globalref"}
FieldsOf(o) == {f \in Fields : Owner[f] = o}

VARIABLES alloc, val, done, published, readNull, badSet
vars == <<alloc, val, done, published, readNull, badSet>>

Made(x) == x \in Leaves \/ x \in alloc

Init == /\ alloc = {}
        /\ val = [f \in Fields |-> "unset"]
        /\ done = FALSE /\ published = FALSE /\ readNull = FALSE /\ badSet = FALSE

\* struct.new: each field its target, or null for a closing field (or, eagerly, a target not yet made)
Alloc(o) == /\ o \notin alloc /\ ~done
            /\ \A f \in FieldsOf(o) : f \in Close \/ Made(Target[f]) \/ EagerCycle
            /\ alloc' = alloc \cup {o}
            /\ val' = [f \in Fields |-> IF Owner[f] = o
                                         THEN IF f \notin Close /\ Made(Target[f]) THEN Target[f] ELSE "null"
                                         ELSE val[f]]
            /\ UNCHANGED <<done, published, readNull, badSet>>
\* struct.set of a closing field once its target is made
Set(f) == /\ f \in Close /\ Owner[f] \in alloc /\ val[f] = "null" /\ Made(Target[f]) /\ ~done
          /\ val' = [val EXCEPT ![f] = Target[f]]
          /\ badSet' = (badSet \/ ~WasmMutable(f))
          /\ UNCHANGED <<alloc, done, published, readNull>>
\* the init returns once every object is made and every closing field set; its global is stored then
Finish == /\ ~done /\ alloc = Objs /\ \A f \in Close : val[f] # "null"
          /\ done' = TRUE /\ published' = TRUE
          /\ UNCHANGED <<alloc, val, readNull, badSet>>
\* EarlyPublish: the global stored as soon as an object is made, before the init returns
EarlyStore == /\ EarlyPublish /\ ~published /\ alloc # {}
              /\ published' = TRUE
              /\ UNCHANGED <<alloc, val, done, readNull, badSet>>
\* the program reads the group through its global
Read == /\ published
        /\ readNull' = (readNull \/ \E f \in Fields : Owner[f] \in alloc /\ val[f] = "null")
        /\ UNCHANGED <<alloc, val, done, published, badSet>>
Stop == done /\ UNCHANGED vars
Next == (\E o \in Objs : Alloc(o)) \/ (\E f \in Fields : Set(f)) \/ Finish \/ EarlyStore \/ Read \/ Stop
Spec == Init /\ [][Next]_vars /\ WF_vars(Finish)
             /\ \A o \in Objs : WF_vars(Alloc(o)) /\ \A f \in Fields : WF_vars(Set(f))

TypeOK == /\ alloc \subseteq Objs
          /\ val \in [Fields -> Objs \cup Leaves \cup {"null", "unset"}]
          /\ done \in BOOLEAN /\ published \in BOOLEAN /\ readNull \in BOOLEAN /\ badSet \in BOOLEAN

Complete    == done => \A f \in Fields : val[f] = Target[f]
NoEarlyRead == ~readNull
Valid       == ~badSet
Ends        == <>done
=============================================================================
