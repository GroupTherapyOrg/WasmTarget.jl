------------------------------ MODULE StoragePointer ------------------------------
(***************************************************************************)
(* A TLA+ model of WasmTarget's storage-relative pointer algebra: the two   *)
(* graph procedures that let a Julia pointer into a Memory's storage        *)
(* compile at all, since WasmGC has no addresses (src/codegen/statements.jl)*)
(*                                                                          *)
(*   _storage_relative_pointer_is_closed(ctx, root; storage_pointer=true)   *)
(*     -- a FORWARD worklist from a storage pointer (a Memory's `ptr`, a    *)
(*        MemoryRef's `ptr_or_offset`, `jl_value_ptr`) over its consumers.  *)
(*        Pi and phi results and the offset arithmetic (add_int/sub_int/    *)
(*        mul_int), add_ptr/sub_ptr and bitcast are followed; a recognized  *)
(*        storage foreigncall (memmove, memchr, ...) consumes it; a still-  *)
(*        `Ptr` value may be returned or passed on; anything else -- a      *)
(*        numeric comparison, a store into an aggregate or slot, an unknown *)
(*        call, returning it as an integer -- rejects the compilation.      *)
(*   _trace_memmove_ptr(arg, ctx)                                           *)
(*     -- a BACKWARD walk from a consumer's pointer operand to the ONE       *)
(*        storage object it points into: Pi, bitcast and add_ptr are walked *)
(*        through; a phi traces EVERY arm (a direct self-reference skipped) *)
(*        and answers only when all arms reach the same object; a revisited *)
(*        node (a pointer carried round a loop) fails; add_int fails.       *)
(*                                                                          *)
(* The consumer's lowering then reads and writes the object the trace named.*)
(* parity(quarantine: Julia pointer intrinsics; Dart has no raw pointers    *)
(* outside dart:ffi, and dart's WasmArrayExt.copy/fill take the array and   *)
(* an element offset, intrinsics.dart:1255/:1279).                          *)
(*                                                                          *)
(* THE CLAIMS.                                                              *)
(*   NoEscape      -- a root the closure accepts reaches no escaping        *)
(*                    consumer along any data-flow path.                    *)
(*   UniqueBacking -- when the trace names object O for a consumer's        *)
(*                    operand, every storage root whose pointer can flow    *)
(*                    into that operand is O: the lowering never reads one  *)
(*                    Memory while the program meant another.               *)
(*                                                                          *)
(* WHAT IS ABSTRACTED, AND WHY IT SUFFICES.                                 *)
(*  - Offsets are not modeled: both procedures decide on the IDENTITY of   *)
(*    the backing object and on which consumers a pointer reaches; the     *)
(*    offset stays a run-time value the consumer compiles.                  *)
(*  - Two storage objects A and B, and node kinds for every operation the  *)
(*    procedures distinguish: root(obj), pi, phi, add_ptr, add_int,        *)
(*    bitcast (Ptr -> integer), memmove (a recognized consumer), return,   *)
(*    store (an aggregate/slot store) and lt (a numeric comparison). A phi *)
(*    may name any node (the loop back edge, itself included); every other *)
(*    operand names an earlier node (SSA dominance).                       *)
(*  - `===` against another storage pointer (_storage_pointer_backing) is  *)
(*    not modeled; it reads the trace this model checks.                   *)
(*  - Init chooses the program: every well-formed graph of N nodes, so the *)
(*    class is exhaustive at that size.                                    *)
(*                                                                          *)
(* VARIANTS.                                                                *)
(*   PhiArms = "All" (the real trace) | "First" -- a phi answers with its  *)
(*     first arm's object, the "invent a single backing identity" the      *)
(*     trace's MemoryRef comment warns against.                            *)
(*   ClosureFollowsPhi = TRUE (the real closure) | FALSE -- a phi or pi    *)
(*     consumer is accepted without following its uses.                    *)
(*                                                                          *)
(* formal(dev/formal/StoragePointer.tla): a storage pointer the closure     *)
(* accepts never escapes, and the object the trace names is the only one a  *)
(* consumer's pointer can point into.                                      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS N, PhiArms, ClosureFollowsPhi

ASSUME N \in Nat /\ N >= 1
ASSUME PhiArms \in {"All", "First"}
ASSUME ClosureFollowsPhi \in BOOLEAN

Idx  == 1..N
Objs == {"A", "B"}
Unary == {"pi", "addptr", "addint", "bitcast", "memmove", "ret", "store", "lt"}

Roots   == {[k |-> "root", o |-> o] : o \in Objs}
Unaries(i) == {[k |-> u, a |-> a] : u \in Unary, a \in 1..(i - 1)}
Phis(i) == {[k |-> "phi", a |-> a, b |-> b] : a \in Idx, b \in Idx}
NodesAt(i) == Roots \cup Unaries(i) \cup {p \in Phis(i) : p.a < p.b}

Programs == {p \in [Idx -> UNION {NodesAt(i) : i \in Idx}] : \A i \in Idx : p[i] \in NodesAt(i)}

VARIABLE prog
vars == <<prog>>

Operands(p, i) == CASE p[i].k = "root" -> {}
                    [] p[i].k = "phi"  -> {p[i].a, p[i].b}
                    [] OTHER           -> {p[i].a}

\* the value of node i is a pointer (Julia type Ptr)
RECURSIVE IsPtr(_, _, _)
IsPtr(p, i, seen) ==
    CASE p[i].k \in {"root", "addptr"} -> TRUE
      [] p[i].k = "pi" -> p[i].a \notin seen /\ IsPtr(p, p[i].a, seen \cup {i})
      [] p[i].k = "phi" -> \A v \in {p[i].a, p[i].b} \ {i} :
                               v \notin seen /\ IsPtr(p, v, seen \cup {i})
      [] OTHER -> FALSE
Ptr(p, i) == IsPtr(p, i, {})

\* the nodes whose value carries (is derived from) node i's value
Flows(p, i) == {c \in Idx : i \in Operands(p, c) /\ p[c].k \in {"pi", "phi", "addptr", "addint", "bitcast"}}

RECURSIVE Reach(_, _)
Reach(p, S) == LET nxt == S \cup UNION {Flows(p, s) : s \in S} IN IF nxt = S THEN S ELSE Reach(p, nxt)

----------------------------------------------------------------------------
(* Ground truth *)

\* the storage objects whose pointer can flow into node i
RtObjs(p, i) == {p[r].o : r \in {r \in Idx : p[r].k = "root" /\ i \in Reach(p, {r})}}

\* a consumer the pointer escapes into
Escapes(p, c, src) == p[c].k \in {"store", "lt"} \/ (p[c].k = "ret" /\ ~Ptr(p, src))

----------------------------------------------------------------------------
(* _storage_relative_pointer_is_closed *)

\* the sources the worklist visits from root r (`pending`)
RECURSIVE Visit(_, _)
Visit(p, S) ==
    LET followed == UNION {{c \in Idx : s \in Operands(p, c) /\
                                         (\/ p[c].k \in {"addint", "addptr", "bitcast"}
                                          \/ (ClosureFollowsPhi /\ p[c].k \in {"pi", "phi"}))} : s \in S}
        nxt == S \cup followed
    IN IF nxt = S THEN S ELSE Visit(p, nxt)

\* a consumer of a visited source rejects when it is none of the accepted kinds
Closed(p, r) ==
    \A s \in Visit(p, {r}) : \A c \in Idx :
        s \in Operands(p, c) =>
            \/ p[c].k \in {"pi", "phi", "addint", "addptr", "bitcast", "memmove"}
            \/ (p[c].k = "ret" /\ Ptr(p, s))

----------------------------------------------------------------------------
(* _trace_memmove_ptr: an object, or "fail" *)

RECURSIVE Trace(_, _, _)
Trace(p, x, seen) ==
    IF x \in seen THEN "fail"
    ELSE CASE p[x].k = "root" -> p[x].o
           [] p[x].k \in {"pi", "bitcast", "addptr"} -> Trace(p, p[x].a, seen \cup {x})
           [] p[x].k = "phi" ->
                 LET arms == IF PhiArms = "First" THEN {p[x].a} \ {x}
                             ELSE {p[x].a, p[x].b} \ {x}
                     ts == {Trace(p, v, seen \cup {x}) : v \in arms}
                 IN IF "fail" \in ts \/ Cardinality(ts) # 1 THEN "fail" ELSE CHOOSE t \in ts : TRUE
           [] OTHER -> "fail"

----------------------------------------------------------------------------
Init == prog \in Programs
Next == UNCHANGED vars
Spec == Init /\ [][Next]_vars

TypeOK == prog \in Programs

\* a root the closure accepts reaches no escaping consumer
NoEscape ==
    \A r \in Idx : prog[r].k = "root" /\ Closed(prog, r) =>
        \A s \in Reach(prog, {r}) : \A c \in Idx :
            s \in Operands(prog, c) => ~Escapes(prog, c, s)

\* the object a consumer's trace names is the only one its pointer can point into
UniqueBacking ==
    \A c \in Idx : prog[c].k = "memmove" =>
        LET t == Trace(prog, prog[c].a, {}) IN
        t # "fail" => RtObjs(prog, prog[c].a) \subseteq {t}
=============================================================================
