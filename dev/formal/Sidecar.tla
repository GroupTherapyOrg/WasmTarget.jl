--------------------------- MODULE Sidecar ---------------------------------
(* formal(dev/formal/Sidecar.tla): models the native linear-memory sidecar's  *)
(* ownership/copy-in-compute-copy-out protocol — future anchor site once the  *)
(* Julia side lands: test/sidecar/sidecar_test.jl `sidecar_daxpy`.            *)
(***************************************************************************)
(* A TLA+ model of WasmTarget's native-sidecar ownership protocol (dev/      *)
(* PARITY_MASTER.md roadmap item 3, design .../scratchpad/p10/DESIGN.md      *)
(* S10.2). Two wasm modules are instantiated by ONE host: a WT-compiled GC   *)
(* module that owns Julia arrays on the GC heap, and a hand-written          *)
(* linear-memory sidecar (test/sidecar/daxpy.wat) with a bump allocator      *)
(* (alloc/reset), scalar accessors store_f64/load_f64, and daxpy(n,a,x,y).   *)
(* A single compiled call runs, in order: alloc(x) -> alloc(y) -> copy-in    *)
(* (GC array get, then store_f64, for x then for y) -> daxpy (the sidecar's  *)
(* own inline f64.load/f64.store loop) -> copy-out (load_f64, then GC array  *)
(* set, into a FRESH result array) -> reset. Ownership rule: the caller owns *)
(* the GC arrays; sidecar linear memory is per-call scratch; no cross-heap   *)
(* reference is ever supposed to survive a call.                            *)
(*                                                                           *)
(* WHAT IS ABSTRACTED, AND WHY IT SUFFICES:                                  *)
(*                                                                           *)
(*  - Concurrency: NONE. This is a single host thread driving both modules   *)
(*    sequentially (unlike SchedulerWake's racing workers) -- the design has *)
(*    no concurrent callers sharing one sidecar instance. The model is a     *)
(*    deterministic phase machine; TLC's exhaustive search degenerates to    *)
(*    checking every state along the one canonical execution per constant    *)
(*    assignment, which is still exactly what we want to mechanically pin.   *)
(*                                                                           *)
(*  - Byte offsets: `alloc` and pointers are counted in ELEMENTS, not bytes  *)
(*    (the real .wat multiplies by 8 for f64 stride; that scaling is a pure  *)
(*    injective relabelling that never participates in any of the claims     *)
(*    below, so tracking it would only inflate the state space).             *)
(*                                                                           *)
(*  - Values: GC-array contents and the "a" scalar are small finite Nats,    *)
(*    not IEEE754 f64. The claims here are about POINTER/OWNERSHIP bookkeep- *)
(*    ing and the STRUCTURE of the copy protocol (does a read ever see data  *)
(*    from the wrong call; does the linear-arithmetic shape a*x+y come out   *)
(*    right, including under GC-array aliasing) -- not about float rounding, *)
(*    which the project's existing native-vs-wasm differential oracle        *)
(*    already checks bit-for-bit. Nat arithmetic is structurally identical   *)
(*    for this claim (daxpy is a single multiply-add per element; nothing    *)
(*    about the ownership/aliasing argument depends on the number system).   *)
(*                                                                           *)
(*  - Real wasm linear memory is bounds-checked by the engine (an            *)
(*    out-of-bounds store/load traps). The .wat allocator itself does NOT    *)
(*    bounds-check (see its own comment: "No bounds checking"). This model   *)
(*    mirrors that: `alloc` never blocks, and capacity is instead a CHECKED  *)
(*    INVARIANT (`CapacityOK`) over the bump pointer -- exactly turning the  *)
(*    "would this trap in real wasm" question into a state predicate TLC can *)
(*    search for, rather than a blocked/disabled action (which would only    *)
(*    ever show up as a deadlock, not a legible counterexample trace). The   *)
(*    backing scratch array is sized to CapDomain > Cap purely so that an    *)
(*    overflowing write stays a well-defined TLA+ function update instead of *)
(*    an undefined-EXCEPT error -- CapDomain is a modeling convenience, NOT  *)
(*    part of the claim (the claim is checked against the real `Cap`).       *)
(*                                                                           *)
(* `owner` is a ghost/history variable (not part of the real protocol's      *)
(* state, no wasm counterpart) recording which call last wrote each scratch  *)
(* address, so that "was this address written in THIS call" -- the crux of  *)
(* claim (1) below -- is directly checkable instead of inferred. `scratch`'s *)
(* content at an address `owner` doesn't attribute to the current call is a  *)
(* meaningless placeholder value, exactly like real (unzeroed) linear memory *)
(* reset only rewinds -- every read site consults `owner` first and never    *)
(* trusts `scratch` on its own; see ComputeStep/CopyOutStep below.           *)
(*                                                                           *)
(* dart2wasm anchors (boundary TYPE surface only -- see daxpy.wat's own      *)
(* header for the fuller citation list): the admission of a real, separate   *)
(* linear memory across the host boundary mirrors dart2wasm's ffiMemory      *)
(* (translator.dart:213-224, lazily-imported "ffi"."memory") and scalar      *)
(* Pointer<T> access (intrinsics.dart:1630-1740, inline f64.load/f64.store,  *)
(* which this model's `compute` phase mirrors exactly). The bump-allocated   *)
(* per-call SCRATCH strategy and the explicit alloc/reset ownership protocol *)
(* are WasmTarget's own invention, not dart2wasm's -- dart emits its inline  *)
(* loads/stores directly against ffiMemory with no analogous per-call arena, *)
(* so there is no dart anchor for the allocation/ownership discipline itself.*)
(***************************************************************************)
EXTENDS Naturals, Sequences, TLC

CONSTANTS
    NumCalls,       \* number of sequential calls the host driver makes
    ArrayIds,       \* set of abstract GC-array identities (model values)
    N,              \* N[c] \in Nat: element count ("n") of call c
    XArr,           \* XArr[c] \in ArrayIds: the GC array bound to x for call c
    YArr,           \* YArr[c] \in ArrayIds: the GC array bound to y for call c
    A,              \* A[c] \in Nat: the scalar "a" for call c
    GC,             \* GC[arr][idx] \in Nat: contents of GC array `arr`
    Cap,            \* the sidecar's real capacity (elements) -- 1 page in the .wat
    CapDomain,      \* backing size of `scratch`'s TLA+ domain (>= Cap; modeling-only)
    MaxN,           \* upper bound on any N[c], for TypeOK's range on `i`
    MaxVal,         \* upper bound on any value that can appear in scratch/out
    SkipReset       \* BOOLEAN: the Broken variant's flag -- skip `reset` if TRUE

Calls == 1..NumCalls

VARIABLES
    call,           \* which call (1..NumCalls) is currently in flight
    pc,             \* phase within the current call
    i,              \* loop index within the current phase
    bump,           \* the sidecar's bump-allocator pointer ($bump global)
    xptr,           \* this call's x scratch base (set by alloc(x))
    yptr,           \* this call's y scratch base (set by alloc(y))
    scratch,        \* scratch[addr] : the sidecar's linear-memory contents
    owner,          \* GHOST: owner[addr] = which call last wrote this address (0 = never)
    out,            \* out[c][idx] : the FRESH result array produced by call c
    overflow,       \* GHOST: latched TRUE once any alloc pushed bump past Cap
    stale           \* GHOST: latched TRUE once any read observed owner # call

vars == <<call, pc, i, bump, xptr, yptr, scratch, owner, out, overflow, stale>>

Phases == {"alloc_x", "alloc_y", "copyin_x", "copyin_y", "compute", "copyout", "reset", "finished"}

ASSUME NumCalls \in Nat \ {0}
ASSUME \A c \in Calls : N[c] \in 0..MaxN
ASSUME \A c \in Calls : XArr[c] \in ArrayIds /\ YArr[c] \in ArrayIds
ASSUME Cap \in Nat /\ CapDomain \in Nat /\ Cap =< CapDomain
ASSUME SkipReset \in BOOLEAN

----------------------------------------------------------------------------
TypeOK ==
    /\ call     \in Calls
    /\ pc       \in Phases
    /\ i        \in 0..MaxN
    /\ bump     \in 0..CapDomain
    /\ xptr     \in 0..CapDomain
    /\ yptr     \in 0..CapDomain
    /\ scratch  \in [0..(CapDomain - 1) -> 0..MaxVal]
    /\ owner    \in [0..(CapDomain - 1) -> {0} \cup Calls]
    /\ out      \in [Calls -> [0..(MaxN - 1) -> 0..MaxVal]]
    /\ overflow \in BOOLEAN
    /\ stale    \in BOOLEAN

Init ==
    /\ call    = 1
    /\ pc      = "alloc_x"
    /\ i       = 0
    /\ bump    = 0
    /\ xptr    = 0
    /\ yptr    = 0
    /\ scratch = [a \in 0..(CapDomain - 1) |-> 0]   \* placeholder; never trusted without owner
    /\ owner   = [a \in 0..(CapDomain - 1) |-> 0]
    /\ out     = [c \in Calls |-> [idx \in 0..(MaxN - 1) |-> 0]]   \* placeholder until CallDone(c)
    /\ overflow = FALSE
    /\ stale    = FALSE

----------------------------------------------------------------------------
(* alloc(x) / alloc(y): the bump allocator has NO bounds checking (mirrors   *)
(* the .wat's own comment) -- it always advances and returns the pre-bump    *)
(* offset. Whether that pushed past the real capacity is recorded in         *)
(* `overflow`, a checked invariant, rather than blocking the step.           *)

AllocX ==
    /\ pc = "alloc_x"
    /\ xptr' = bump
    /\ bump' = bump + N[call]
    /\ overflow' = overflow \/ (bump' > Cap)
    /\ pc' = "alloc_y"
    /\ UNCHANGED <<call, i, yptr, scratch, owner, out, stale>>

AllocY ==
    /\ pc = "alloc_y"
    /\ yptr' = bump
    /\ bump' = bump + N[call]
    /\ overflow' = overflow \/ (bump' > Cap)
    /\ pc' = "copyin_x"
    /\ i' = 0
    /\ UNCHANGED <<call, xptr, scratch, owner, out, stale>>

----------------------------------------------------------------------------
(* copy-in: GC array get, then store_f64 -- one element at a time, x then y. *)
(* Each write publishes `owner[addr] := call`, the fact claim (1) checks.    *)

CopyInXStep ==
    /\ pc = "copyin_x"
    /\ i < N[call]
    /\ LET a == xptr + i IN
        /\ scratch' = [scratch EXCEPT ![a] = GC[XArr[call]][i]]
        /\ owner'   = [owner   EXCEPT ![a] = call]
    /\ i' = i + 1
    /\ UNCHANGED <<call, pc, bump, xptr, yptr, out, overflow, stale>>

CopyInXDone ==
    /\ pc = "copyin_x"
    /\ i >= N[call]
    /\ pc' = "copyin_y"
    /\ i' = 0
    /\ UNCHANGED <<call, bump, xptr, yptr, scratch, owner, out, overflow, stale>>

CopyInYStep ==
    /\ pc = "copyin_y"
    /\ i < N[call]
    /\ LET a == yptr + i IN
        /\ scratch' = [scratch EXCEPT ![a] = GC[YArr[call]][i]]
        /\ owner'   = [owner   EXCEPT ![a] = call]
    /\ i' = i + 1
    /\ UNCHANGED <<call, pc, bump, xptr, yptr, out, overflow, stale>>

CopyInYDone ==
    /\ pc = "copyin_y"
    /\ i >= N[call]
    /\ pc' = "compute"
    /\ i' = 0
    /\ UNCHANGED <<call, bump, xptr, yptr, scratch, owner, out, overflow, stale>>

----------------------------------------------------------------------------
(* compute: the sidecar's OWN daxpy loop -- inline f64.load(x)/f64.load(y), *)
(* f64.store(y) -- one element at a time. `xa` and `ya` are always distinct  *)
(* addresses whenever N[call] > 0 (alloc(x) then alloc(y) are back-to-back,  *)
(* so yptr = xptr + N[call] > xptr), so this is safe even when the CALLER's  *)
(* x and y are the SAME GC array (XArr[call] = YArr[call]): copy-in already  *)
(* duplicated that array's values into two disjoint scratch regions before   *)
(* compute ever runs, so Julia-level aliasing never becomes scratch-level    *)
(* aliasing here. (The one case where xa could equal ya is N[call] = 0, in   *)
(* which case this loop never executes at all -- see CopyInXDone above with  *)
(* i >= N[call] = 0 firing immediately.) A read whose address was NOT        *)
(* written by THIS call (owner # call) still cannot crash the model -- it    *)
(* falls back to 0 -- but it latches `stale`, which claim (1) requires stay  *)
(* FALSE throughout.                                                        *)

ComputeStep ==
    /\ pc = "compute"
    /\ i < N[call]
    /\ LET xa == xptr + i
           ya == yptr + i
           xVal == IF owner[xa] = call THEN scratch[xa] ELSE 0
           yVal == IF owner[ya] = call THEN scratch[ya] ELSE 0
       IN
        /\ stale'   = stale \/ (owner[xa] # call) \/ (owner[ya] # call)
        /\ scratch' = [scratch EXCEPT ![ya] = A[call] * xVal + yVal]
        /\ owner'   = [owner EXCEPT ![ya] = call]
    /\ i' = i + 1
    /\ UNCHANGED <<call, pc, bump, xptr, yptr, out, overflow>>

ComputeDone ==
    /\ pc = "compute"
    /\ i >= N[call]
    /\ pc' = "copyout"
    /\ i' = 0
    /\ UNCHANGED <<call, bump, xptr, yptr, scratch, owner, out, overflow, stale>>

----------------------------------------------------------------------------
(* copy-out: load_f64, then GC array set -- into a FRESH result array `out`,*)
(* never back into x or y. This is the "every load_f64 in copy-out reads a  *)
(* slot written in THIS call" claim's other half (compute's internal loads   *)
(* are the other half, instrumented above).                                 *)

CopyOutStep ==
    /\ pc = "copyout"
    /\ i < N[call]
    /\ LET ya == yptr + i IN
        /\ stale' = stale \/ (owner[ya] # call)
        /\ out' = [out EXCEPT ![call][i] = IF owner[ya] = call THEN scratch[ya] ELSE 0]
    /\ i' = i + 1
    /\ UNCHANGED <<call, pc, bump, xptr, yptr, scratch, owner, overflow>>

CopyOutDone ==
    /\ pc = "copyout"
    /\ i >= N[call]
    /\ pc' = "reset"
    /\ UNCHANGED <<call, i, bump, xptr, yptr, scratch, owner, out, overflow, stale>>

----------------------------------------------------------------------------
(* reset: rewinds the bump pointer to 0 -- the SkipReset CONSTANT is the     *)
(* Broken variant's single deliberately-wrong step, mirroring the realistic  *)
(* bug class (a caller that forgets to call `reset` after `daxpy`). Real     *)
(* wasm memory bytes are NOT cleared by reset (only the pointer rewinds);    *)
(* that is exactly why claim (1) is checked via the `owner`/`stale` ghost    *)
(* state rather than by clearing `scratch` here -- clearing it would hide    *)
(* the very hazard the claim exists to catch.                               *)

DoReset ==
    /\ pc = "reset"
    /\ bump' = IF SkipReset THEN bump ELSE 0
    /\ IF call = NumCalls
        THEN /\ pc'   = "finished"
             /\ call' = call
        ELSE /\ pc'   = "alloc_x"
             /\ call' = call + 1
    /\ i'    = 0
    /\ xptr' = 0
    /\ yptr' = 0
    /\ UNCHANGED <<scratch, owner, out, overflow, stale>>

Stutter == pc = "finished" /\ UNCHANGED vars

Next ==
    \/ AllocX
    \/ AllocY
    \/ CopyInXStep
    \/ CopyInXDone
    \/ CopyInYStep
    \/ CopyInYDone
    \/ ComputeStep
    \/ ComputeDone
    \/ CopyOutStep
    \/ CopyOutDone
    \/ DoReset
    \/ Stutter

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

----------------------------------------------------------------------------
(* Claims. *)

(* (1) No read of stale-from-a-prior-call or uninitialized scratch, in       *)
(* either compute's internal loads or copy-out's load_f64. *)
NoStaleRead == ~stale

(* (2) No alloc ever exceeds the real capacity, AND the bump pointer returns *)
(* to its base (0) after every call once the NEXT call begins -- i.e. reset  *)
(* actually happened. The second clause fires the instant a reset is         *)
(* skipped, before the following alloc even has a chance to overflow.       *)
CapacityOK ==
    /\ ~overflow
    /\ (pc = "alloc_x" /\ call > 1) => (bump = 0)

(* (3) Compute correctness at the abstract level: once a call's copy-out has *)
(* completed, its result equals a*x + y_old element-wise, using the GC       *)
(* arrays' values AT the (never-mutated-by-this-protocol) source, which      *)
(* also covers the aliased case (XArr[c] = YArr[c]) for free -- both reads   *)
(* resolve to the same source array's contents.                             *)
CallDone(c) == (c < call) \/ (c = call /\ pc \in {"reset", "finished"})

OutputCorrect ==
    \A c \in Calls :
        CallDone(c) =>
            \A idx \in (IF N[c] = 0 THEN {} ELSE 0..(N[c] - 1)) :
                out[c][idx] = A[c] * GC[XArr[c]][idx] + GC[YArr[c]][idx]

(* (4) Type separation: nothing that ever lands in `scratch` is a GC-array   *)
(* reference -- only the plain numeric values copy-in reads out of GC arrays *)
(* or compute derives from them.                                            *)
NoRefsInScratch == \A p \in 0..(CapDomain - 1) : scratch[p] \notin ArrayIds

(* Liveness/termination: the driver always finishes all NumCalls calls. *)
Terminates == <>(pc = "finished")

=============================================================================
