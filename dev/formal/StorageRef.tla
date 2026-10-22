------------------------------ MODULE StorageRef ------------------------------
(***************************************************************************)
(* A TLA+ model of a Julia Array's storage as WasmTarget represents it: the *)
(* Array struct's data array (the Memory) and its i32 element offset off0   *)
(* (src/codegen/structs.jl `array_offset_field_idx`), and a MemoryRef as     *)
(* the (Memory, off0) pair of the pair channel (src/codegen/builtins.jl,     *)
(* `_memoryref_source`, `_memoryref_operand_is_fixed`). Julia is the ground   *)
(* truth: the operations are the growth and deletion bodies of array.jl       *)
(* (`_growend!`, `_deletebeg!`, `resize!`, `setindex!`) and a MemoryRef is an *)
(* immutable snapshot of (mem, offset) (boot.jl `memoryrefnew`). The dart     *)
(* counterpart is a typed-data view's (_data, _offsetInElements)              *)
(* (sdk/lib/_internal/wasm/common/typed_data.dart:2441 WasmI8ArrayBase).      *)
(*                                                                           *)
(* ABSTRACTION. A Memory is a sequence of slot values; 0 is an unset slot.    *)
(* Memories are allocated from a counter and never freed (WasmGC keeps a      *)
(* referenced array alive). One Array and at most one snapshot MemoryRef are  *)
(* modeled: a second Array sharing the Memory (reshape) adds no new rule —    *)
(* it is one more (mem, off0, len) triple over the same memories. Julia's     *)
(* growth POLICY (how much capacity, whether a reallocation compacts the      *)
(* offset back to 1) is a nondeterministic choice among the allocations that  *)
(* hold the requested length; the claims hold for every policy. `seq` is the  *)
(* Array's value as Julia defines it; `joff` is Julia's memoryrefoffset.      *)
(*                                                                           *)
(* CLAIMS (invariants):                                                      *)
(*   InBounds   1 <= off /\ off + len - 1 <= Len(mem): every element access    *)
(*              the lowering emits is inside its wasm array.                  *)
(*   Contents   the stored slots mem[off .. off+len-1] are the Array's value.   *)
(*   JuliaOffset off0 + 1 = Julia's memoryrefoffset(a.ref).                    *)
(*   RefSnapshot a MemoryRef reads the value Julia gives it: the slot of the     *)
(*              Memory it was taken from, which a later write through the      *)
(*              Array reaches only while the Array still holds that Memory.    *)
(*                                                                           *)
(* BROKEN VARIANTS (a CONSTANT flag each, one per realistic bug class):        *)
(*   ReallocOnPopFirst  popfirst! copies into a fresh Memory at offset 1 (the  *)
(*                      WASM_METHOD_TABLE popfirst! overlay) — JuliaOffset.    *)
(*   IgnoreRequestedLen resize! grows the capacity by one slot whatever length *)
(*                      was requested (the invoke.jl `#_growend!` arm's         *)
(*                      max(2c, c+4) that ignored the request) — InBounds.      *)
(*   ReemitRef          a MemoryRef re-reads the Array's current :ref field     *)
(*                      instead of its own snapshot (re-emitting an indexed     *)
(*                      ref from a mutable operand) — RefSnapshot.              *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Vals,          \* element values; 0 means an unset slot
          MaxCap,        \* largest Memory length
          MaxMems,       \* allocations available
          MaxSteps,      \* bound on operations
          ReallocOnPopFirst, IgnoreRequestedLen, ReemitRef

NoRef == [m |-> 0, o |-> 0, v |-> 0]

VARIABLES mems,   \* MemId -> Seq(Vals \cup {0})
          next,   \* next MemId to allocate
          arr,    \* [mem, off, len]: the Array (data field, off0 + 1, size)
          seq,    \* the Array's value, per Julia
          joff,   \* Julia's memoryrefoffset(a.ref)
          ref,    \* a snapshot MemoryRef [m, o, v]: its Memory, slot, Julia's value
          steps

vars == <<mems, next, arr, seq, joff, ref, steps>>

MemIds == 1..MaxMems
Slot == Vals \cup {0}

Zeros(n) == [i \in 1..n |-> 0]

\* Allocate memory `id` of length `c` holding `old`'s slots [from .. from+n-1] at `to`.
Moved(old, from, n, to, c) ==
    [i \in 1..c |-> IF i >= to /\ i < to + n THEN old[from + (i - to)] ELSE 0]

Init ==
    /\ mems = [i \in MemIds |-> IF i = 1 THEN <<1, 2>> ELSE <<>>]
    /\ next = 2
    /\ arr = [mem |-> 1, off |-> 1, len |-> 2]
    /\ seq = <<1, 2>>
    /\ joff = 1
    /\ ref = NoRef
    /\ steps = 0

Step == steps' = steps + 1

\* A Julia write through the Array reaches a snapshot ref that holds the same slot.
RefAfterWrite(m, o, x) ==
    IF ref # NoRef /\ ref.m = m /\ ref.o = o THEN [ref EXCEPT !.v = x] ELSE ref

\* setindex!(a, x, i)
Write(i, x) ==
    /\ i \in 1..arr.len
    /\ mems' = [mems EXCEPT ![arr.mem][arr.off + i - 1] = x]
    /\ seq' = [seq EXCEPT ![i] = x]
    /\ ref' = RefAfterWrite(arr.mem, arr.off + i - 1, x)
    /\ UNCHANGED <<next, arr, joff>>
    /\ Step

\* r = memoryref(a.ref, i): a snapshot of the Array's (mem, off) at slot i
TakeRef(i) ==
    /\ i \in 1..arr.len
    /\ ref' = [m |-> arr.mem, o |-> arr.off + i - 1, v |-> seq[i]]
    /\ UNCHANGED <<mems, next, arr, seq, joff>>
    /\ Step

\* push!(a, x) = _growend!(a, 1); a[end] = x. In place when the Memory has room past
\* the end; otherwise a new Memory, keeping the offset or compacting it to 1.
Push(x) ==
    /\ arr.len < MaxCap
    /\ IF arr.off + arr.len <= Len(mems[arr.mem])
       THEN /\ mems' = [mems EXCEPT ![arr.mem][arr.off + arr.len] = x]
            /\ arr' = [arr EXCEPT !.len = arr.len + 1]
            /\ joff' = joff
            /\ ref' = RefAfterWrite(arr.mem, arr.off + arr.len, x)
            /\ UNCHANGED next
       ELSE /\ next <= MaxMems
            /\ \E newoff \in {1, arr.off}, c \in 1..MaxCap :
                  /\ c >= newoff + arr.len
                  /\ mems' = [mems EXCEPT ![next] =
                        [Moved(mems[arr.mem], arr.off, arr.len, newoff, c)
                            EXCEPT ![newoff + arr.len] = x]]
                  /\ arr' = [mem |-> next, off |-> newoff, len |-> arr.len + 1]
                  /\ joff' = newoff
            /\ next' = next + 1
            /\ UNCHANGED ref
    /\ seq' = Append(seq, x)
    /\ Step

\* popfirst!(a) = _deletebeg!(a, 1): the ref advances one slot in the same Memory.
PopFirst ==
    /\ arr.len >= 1
    /\ seq' = Tail(seq)
    /\ joff' = joff + 1
    /\ IF ReallocOnPopFirst
       THEN /\ next <= MaxMems
            /\ mems' = [mems EXCEPT ![next] =
                  Moved(mems[arr.mem], arr.off + 1, arr.len - 1, 1, arr.len - 1)]
            /\ arr' = [mem |-> next, off |-> 1, len |-> arr.len - 1]
            /\ next' = next + 1
       ELSE /\ arr' = [arr EXCEPT !.off = arr.off + 1, !.len = arr.len - 1]
            /\ UNCHANGED <<mems, next>>
    /\ UNCHANGED ref
    /\ Step

\* resize!(a, n): shrinking keeps the Memory (the freed slots are unset); growing past
\* the Memory's end allocates one that holds off + n - 1 slots.
Resize(n) ==
    /\ n \in 0..MaxCap
    /\ IF n <= arr.len
       THEN /\ mems' = [mems EXCEPT ![arr.mem] =
                  [i \in 1..Len(mems[arr.mem]) |->
                      IF i >= arr.off + n /\ i < arr.off + arr.len THEN 0
                      ELSE mems[arr.mem][i]]]
            /\ arr' = [arr EXCEPT !.len = n]
            /\ UNCHANGED <<next, joff>>
            /\ ref' = IF ref # NoRef /\ ref.m = arr.mem /\ ref.o >= arr.off + n /\
                          ref.o < arr.off + arr.len
                       THEN [ref EXCEPT !.v = 0] ELSE ref
       ELSE IF arr.off + n - 1 <= Len(mems[arr.mem])
       THEN /\ arr' = [arr EXCEPT !.len = n]
            /\ UNCHANGED <<mems, next, joff, ref>>
       ELSE /\ next <= MaxMems
            /\ \E c \in 1..MaxCap + 1 :
                  /\ IF IgnoreRequestedLen THEN c = Len(mems[arr.mem]) + 1
                                          ELSE c >= arr.off + n - 1 /\ c <= MaxCap
                  /\ mems' = [mems EXCEPT ![next] =
                        Moved(mems[arr.mem], arr.off, arr.len, arr.off, c)]
            /\ arr' = [arr EXCEPT !.mem = next, !.len = n]
            /\ next' = next + 1
            /\ UNCHANGED <<joff, ref>>
    /\ seq' = IF n <= arr.len THEN SubSeq(seq, 1, n)
              ELSE seq \o Zeros(n - arr.len)
    /\ Step

Next ==
    /\ steps < MaxSteps
    /\ \/ \E i \in 1..MaxCap, x \in Vals : Write(i, x)
       \/ \E i \in 1..MaxCap : TakeRef(i)
       \/ \E x \in Vals : Push(x)
       \/ PopFirst
       \/ \E n \in 0..MaxCap : Resize(n)

Done == steps = MaxSteps /\ UNCHANGED vars

Spec == Init /\ [][Next \/ Done]_vars

\* The value the lowering reads for the snapshot ref.
RefRead ==
    IF ReemitRef
    THEN IF ref.o <= Len(mems[arr.mem]) THEN mems[arr.mem][ref.o] ELSE 0
    ELSE mems[ref.m][ref.o]

TypeOK ==
    /\ next \in 1..MaxMems + 1
    /\ arr.mem \in MemIds /\ arr.off \in 1..MaxCap + 2 /\ arr.len \in 0..MaxCap
    /\ steps \in 0..MaxSteps

InBounds == 1 <= arr.off /\ arr.off + arr.len - 1 <= Len(mems[arr.mem])

Contents ==
    /\ Len(seq) = arr.len
    /\ \A i \in 1..arr.len : arr.off + i - 1 <= Len(mems[arr.mem]) =>
          mems[arr.mem][arr.off + i - 1] = seq[i]

JuliaOffset == arr.off = joff

RefSnapshot == ref # NoRef => RefRead = ref.v
=============================================================================
