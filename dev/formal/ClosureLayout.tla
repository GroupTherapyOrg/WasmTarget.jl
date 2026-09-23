-------------------------- MODULE ClosureLayout ----------------------------
(***************************************************************************)
(* A TLA+ model of WasmTarget's closure layouter: the pair                  *)
(*   register_closure_type!   (src/codegen/structs.jl:85-136)  -- the        *)
(*     captured-fields CONTEXT struct for a closure type T                   *)
(*   get_closure_base_struct!/get_closure_vtable_struct!                    *)
(*     (src/codegen/types.jl:2425-2456)  -- the Object prefix and the        *)
(*     one-struct-per-ARITY vtable shape                                     *)
(*   build_closure_vtable!/closure_vtable/emit_closure_wrap!                              *)
(*     (src/codegen/closures.jl:31-162) -- the one vtable GLOBAL per closure *)
(*     body and the erasure-seam wrap that reads it back                     *)
(* dart anchor: ClosureLayouter, closures.dart:41-118 (Object fields          *)
(* classId/identityHash/context/vtable/functionType == closures.jl:2427-2433 *)
(* field-for-field) and closures.dart:1365-1437 (Context.variables/Capture — *)
(* captures are a plain, insertion-ordered List and Capture.type reads the   *)
(* struct field's OWN declared type back, never re-derives it).              *)
(*                                                                           *)
(* SCOPE. classId collision-freedom and the struct-registry Dict's hash-     *)
(* order safety are ALREADY ClassIdDispatch.tla's job -- its own header       *)
(* names "non-enrolled closure types" as exactly the Late/lazy-ensure_type_  *)
(* id! class it models, and its UnsortedIteration constant already tests the *)
(* type_registry.structs walk-order bug class (calls.jl:1891/values.jl:495/  *)
(* structs.jl:1189/dispatch.jl:75/types.jl:521). Re-deriving that here would  *)
(* be exactly the "nothing reinvented" violation the parity march forbids.   *)
(* This model covers what ClassIdDispatch.tla does NOT: the closure-SPECIFIC *)
(* layout facts -- a context struct's OWN field order, and the vtable's      *)
(* per-arity/per-closure-body shape consistency, neither of which touches    *)
(* classId at all (they live in the WASM TYPE SECTION index space that       *)
(* add_struct_type! hands out, a distinct id space from ensure_type_id!'s    *)
(* Julia-level classIds).                                                    *)
(*                                                                           *)
(* WHAT THE REAL ALGORITHM DOES (the part this model checks).                *)
(*                                                                           *)
(* (A) CONTEXT STRUCT (register_closure_type!, structs.jl:85-136). On the    *)
(*     FIRST sight of T: `field_names/field_types` are read via              *)
(*     `[fieldname(T,i) for i in 1:fieldcount(T)]` -- a plain Julia FIELD-    *)
(*     INDEX range, never a Dict/Set walk -- then each field's Julia type    *)
(*     maps through a PURE function to a wasm field type (Vector/Abstract-   *)
(*     Vector/MemoryRef/Memory/String/Symbol get a dedicated wasm shape;     *)
(*     everything else -- numerics, Core.Box, other structs, Any -- goes      *)
(*     through `julia_to_wasm_type`), and a FRESH struct-type index is       *)
(*     allocated (`add_struct_type!`, types.jl's monotonic type-section       *)
(*     counter). `registry.structs[T] = info` then caches it. On EVERY later *)
(*     sight of the SAME T, `haskey(registry.structs,T) && return` fires     *)
(*     FIRST (structs.jl:87) -- the cached info is returned UNCHANGED; the   *)
(*     new call's arguments are never even inspected. This model erases the  *)
(*     per-field wasm-type mapping (a pure, Dict-free function of a field's  *)
(*     Julia type, hence trivially deterministic -- see the "what is         *)
(*     abstracted" note below) and keeps only the FIELD-CLASS SEQUENCE that   *)
(*     mapping is applied to, since order is the only axis a bug could still *)
(*     move.                                                                 *)
(*                                                                           *)
(* (B) VTABLE STRUCT PER ARITY (get_closure_vtable_struct!, types.jl:2447-   *)
(*     2456). `registry.closure_vtable_struct_idxs` is a Dict keyed by the   *)
(*     INTEGER `max_arity` (not by T): first sight of an arity allocates a   *)
(*     fresh `(n+1)`-field struct type (one funcref slot per positional      *)
(*     arity 0..n, dart: vtableBaseIndex + posArgCount); every later request *)
(*     for the SAME arity returns the SAME struct, shared across every       *)
(*     closure body of that arity. This is exactly dart's own               *)
(*     `_representationsForCounts`/`getClosureRepresentation`                *)
(*     (closures.dart:501-560, 1101-1114): a grow-as-needed table indexed by *)
(*     (typeCount, positionalCount), memoized by SHAPE, never by which        *)
(*     closure asked.                                                        *)
(*                                                                           *)
(* (C) VTABLE GLOBAL PER CLOSURE BODY (build_closure_vtable!, closures.jl:  *)
(*     31-118). `registry.closure_vtable_globals` is a Dict keyed by         *)
(*     `closure_type` (T), NOT by shape. On the FIRST sight of T: computes    *)
(*     `arity = length(body_params) - (takes_context?1:0)` from THIS call's  *)
(*     own arguments, builds the (B)-shared struct for that arity, creates a *)
(*     GLOBAL whose only populated slot is `arity` (every other slot         *)
(*     `ref.null func`), and caches `cache[key] = g`. THE ASYMMETRY THIS      *)
(*     MODEL EXISTS TO CHECK: on a CACHE HIT (closures.jl:40-44) the code     *)
(*     does NOT simply return the cached `(global, vt_struct)` pair --        *)
(*     it returns `(cached, get_closure_vtable_struct!(mod, registry,        *)
(*     cached_arity))` where `cached_arity` is RECOMPUTED from THIS call's    *)
(*     `body_params`/`takes_context`, not stored from the ORIGINAL creating   *)
(*     call. `emit_closure_wrap!` (closures.jl:120-162) has the identical     *)
(*     pattern at its own use site (line 153: `local arity = length(body_    *)
(*     params) - (takes_context?1:0)`, recomputed fresh, then used to        *)
(*     annotate the `global_get!` of the ALREADY-CREATED global). The         *)
(*     comment at closures.jl:39 states the ASSUMED invariant this relies    *)
(*     on: "key = closure_type   # T-keyed: the wrap looks up by type alone" *)
(*     -- i.e. every arrival for a given T is assumed to request the SAME    *)
(*     arity. dart2wasm's design makes the analogous mistake STRUCTURALLY    *)
(*     impossible: `getClosureRepresentation`'s cache key IS the shape       *)
(*     itself (typeCount, positionalCount, names), so asking twice for the   *)
(*     same key can never disagree with what was built. WT's cache key (T)   *)
(*     is STRICTLY WEAKER than the shape it derives per call, which is        *)
(*     exactly the gap this model probes: does anything in the real call      *)
(*     graph (compile.jl:944-969's `_cvp` pre-pass loop, which pushes EVERY   *)
(*     `function_data` position whose callable is T with no dedup by T, or   *)
(*     a later `emit_closure_wrap!` lookup) ever request a SECOND, DIFFERENT *)
(*     arity for a T already in the cache? If it can, `ensure_closure_       *)
(*     vtable!`'s own cache-hit code returns a vt_struct id that no longer    *)
(*     matches the shape the underlying global was ACTUALLY populated with   *)
(*     -- silently, with no reject in between, exactly the "no shape         *)
(*     mismatch reaches call_ref" claim below turned on its head.            *)
(*                                                                           *)
(* WHAT THIS MODEL ABSTRACTS, AND WHY THAT IS SUFFICIENT.                    *)
(*  - Julia types collapse to opaque ids (`Types`); a captured field's       *)
(*    Julia type collapses to an opaque wasm-shape CLASS (`FieldClasses`).   *)
(*    The per-field Julia-type -> wasm-type mapping in register_closure_     *)
(*    type! (the Vector/AbstractVector/MemoryRef/Memory/String/Symbol special*)
(*    cases plus the `julia_to_wasm_type` fallback) is a PURE function of    *)
(*    one field's type with NO Dict/registry lookup at all -- it cannot      *)
(*    introduce order- or run-dependent behavior, so it is erased and only   *)
(*    its declared SEQUENCE (`DeclaredFields[T]`, a CONSTANT -- Julia fixes  *)
(*    a closure struct's field order before WT ever sees T) is modeled.      *)
(*    Likewise the box-capture JOIN (box_capture.jl, F3) that would refine a *)
(*    `Core.Box` field to a concrete cell type is NOT wired into register_   *)
(*    closure_type! as of this snapshot (its only consumer is the value-     *)
(*    channel typing in context.jl:520,767, never the struct layout) --      *)
(*    modeling it here would idealize code that does not exist yet; per      *)
(*    "read it from source, never idealize" it is left out, and              *)
(*    `DeclaredFields[T]`'s field-class domain stands for whatever the       *)
(*    CURRENT pure mapping produces today.                                   *)
(*  - `takes_context` and the raw `body_params`/`body_results` lengths       *)
(*    collapse to one CONSTANT `DeclaredArity[T]` (the ABI-relevant integer  *)
(*    both (B) and (C) actually key off of); the trampoline's own byte       *)
(*    emission (casts, `call!`, re-boxing) is erased entirely -- the claims  *)
(*    under test are about which STRUCT SHAPE a slot lives in, never the     *)
(*    bytes inside it, matching Stackifier.tla erasing values/phi for a      *)
(*    purely-control claim.                                                 *)
(*  - `register_closure_type!` must run before `build_closure_vtable!` for  *)
(*    the same T (closures.jl:49-50 throws otherwise for a context-taking    *)
(*    closure) -- modeled as an explicit preconditon, not a free choice.     *)
(*  - Every action is atomic (no concurrency: compilation is single-         *)
(*    threaded per compile task); TLC's exploration is over which T (and,    *)
(*    for the vtable, which requested arity) is processed next and how many *)
(*    times -- an arrival budget (`MaxArrivals`) keeps the trace finite,     *)
(*    mirroring that `function_data` is itself a finite, already-decided     *)
(*    sequence (out of scope here, exactly as ClosedWorld.tla takes the call *)
(*    graph as CONSTANT input rather than re-deriving it).                   *)
(*                                                                           *)
(* THE TWO BROKEN VARIANTS.                                                  *)
(*  - `HashOrderCapture = TRUE`: register_closure_type!'s field-class        *)
(*    sequence for a NEWLY-seen T may come out as ANY permutation of its     *)
(*    declared multiset, mirroring what would happen if a future refactor    *)
(*    built the field list through an unordered/hash-keyed intermediate      *)
(*    (the exact "Dict-constant nondeterminism" class `ordered_pairs`/       *)
(*    `registered_structs` (types.jl:548-575) exist to forbid everywhere     *)
(*    else in this codebase) instead of the current direct `1:fieldcount(T)`*)
(*    range. TLC must find a state where the recorded order differs from    *)
(*    the declared one.                                                     *)
(*  - `AllowArityDrift = TRUE`: a closure_type T already in the vtable-      *)
(*    global cache may be revisited with a DIFFERENT arity than its first    *)
(*    arrival -- lifting the "T-keyed: the wrap looks up by type alone"      *)
(*    assumption (closures.jl:39) that the real code relies on without       *)
(*    checking. TLC must find a state where the returned vt_struct           *)
(*    annotation for T no longer matches the shape T's global was actually  *)
(*    created with (`WellFormedVtable` violated) -- reproducing the literal  *)
(*    cache-hit-recompute code path, not a hypothetical one.                 *)
(*                                                                           *)
(* formal(src/codegen/structs.jl register_closure_type!, src/codegen/       *)
(* closures.jl build_closure_vtable!): a closure type's context struct      *)
(* lists its captured fields in exactly the program's declared order, never *)
(* a hash-dependent one; two distinct closure types never share a context   *)
(* struct or vtable-global id; one struct type is shared by every closure    *)
(* body of the same arity (dart2wasm's per-shape ClosureRepresentation); and *)
(* the vt_struct annotation returned for a closure type's vtable global      *)
(* always matches the shape that global was actually populated with, so no  *)
(* shape mismatch ever reaches `call_ref`.                                   *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Types,             \* finite universe of closure-type ids
    Arities,           \* finite set of Nat: supported positional arities
    FieldClasses,      \* finite universe of captured-field wasm-shape classes
    DeclaredFields,    \* [Types -> Seq(FieldClasses)]: T's real declared capture order
    DeclaredArity,     \* [Types -> Arities]: T's real positional call arity
    MaxArrivals,       \* Nat: bounds how many times each step may revisit one T
    HashOrderCapture,  \* BOOLEAN: TRUE = the retired/counterfactual hash-order field variant
    AllowArityDrift    \* BOOLEAN: TRUE = a revisit of T may request a different arity

ASSUME IsFiniteSet(Types)
ASSUME Arities \subseteq Nat /\ IsFiniteSet(Arities)
ASSUME IsFiniteSet(FieldClasses)
ASSUME DeclaredFields \in [Types -> Seq(FieldClasses)]
ASSUME DeclaredArity \in [Types -> Arities]
ASSUME MaxArrivals \in Nat /\ MaxArrivals >= 1
ASSUME HashOrderCapture \in BOOLEAN
ASSUME AllowArityDrift \in BOOLEAN

VARIABLES
    ctxArrivals,      \* [Types -> 0..MaxArrivals] -- register_closure_type! calls so far
    seenCtx,           \* SUBSET Types -- T's whose context struct is registered
    fieldSeq,          \* [Types -> Seq(FieldClasses)] -- the RECORDED field order (meaningful once seenCtx)
    structId,          \* [Types -> Nat] -- register_closure_type!'s struct-type index (0 = unassigned)
    nextStructId,      \* Nat -- add_struct_type!'s monotonic type-section counter
    vtArrivals,        \* [Types -> 0..MaxArrivals] -- vtable arrivals (build_closure_vtable! / closure_vtable) so far
    seenVt,            \* SUBSET Types -- T's whose vtable global exists
    globalId,          \* [Types -> Nat] -- the one vtable global per closure body (0 = unassigned)
    nextGlobalId,      \* Nat -- add_global_ref!'s monotonic counter
    shapeAtCreation,   \* [Types -> Nat] -- GROUND TRUTH: the vt_struct id T's global was populated with
    lastAnnotated,     \* [Types -> Nat] -- the vt_struct id most recently RETURNED/used for T
    arityOf,           \* [Types -> Nat] -- the arity of T's most recent arrival (diagnostic/history)
    vtStructOf,        \* [Arities -> Nat] -- get_closure_vtable_struct!'s per-arity struct index (0 = unassigned)
    seenArities,       \* SUBSET Arities -- arities with an assigned vtable struct
    nextVtStructId     \* Nat -- the per-arity monotonic counter

vars == <<ctxArrivals, seenCtx, fieldSeq, structId, nextStructId,
          vtArrivals, seenVt, globalId, nextGlobalId, shapeAtCreation,
          lastAnnotated, arityOf, vtStructOf, seenArities, nextVtStructId>>

----------------------------------------------------------------------------
(* Field-order choices: the identity order under the real algorithm, or any *)
(* permutation of the same multiset under the counterfactual HashOrder      *)
(* variant -- Perms(n) is the set of bijections 1..n -> 1..n (a finite set  *)
(* since Types/FieldClasses/Arities are all finite), i.e. every permutation *)
(* of a length-n sequence.                                                  *)

Perms(n) == {p \in [1..n -> 1..n] : \A i, j \in 1..n : i # j => p[i] # p[j]}

PermuteSeq(s, p) == [i \in 1..Len(s) |-> s[p[i]]]

FieldOrderChoices(T) ==
    IF HashOrderCapture
    THEN {PermuteSeq(DeclaredFields[T], p) : p \in Perms(Len(DeclaredFields[T]))}
    ELSE {DeclaredFields[T]}

----------------------------------------------------------------------------
(* Init: nothing registered yet; every monotonic counter starts at 1 (0 is  *)
(* reserved as the "unassigned" sentinel for structId/globalId/vtStructOf,  *)
(* never produced by a real assignment).                                    *)

Init ==
    /\ ctxArrivals = [T \in Types |-> 0]
    /\ seenCtx = {}
    /\ fieldSeq = [T \in Types |-> <<>>]
    /\ structId = [T \in Types |-> 0]
    /\ nextStructId = 1
    /\ vtArrivals = [T \in Types |-> 0]
    /\ seenVt = {}
    /\ globalId = [T \in Types |-> 0]
    /\ nextGlobalId = 1
    /\ shapeAtCreation = [T \in Types |-> 0]
    /\ lastAnnotated = [T \in Types |-> 0]
    /\ arityOf = [T \in Types |-> 0]
    /\ vtStructOf = [a \in Arities |-> 0]
    /\ seenArities = {}
    /\ nextVtStructId = 1

----------------------------------------------------------------------------
(* (A) register_closure_type!: first sight allocates a fresh struct id and  *)
(* records a field order drawn from FieldOrderChoices(T); a cache hit        *)
(* (structs.jl:87 `haskey(...) && return`) leaves EVERYTHING about T         *)
(* unchanged -- the new call's (absent, in this model) arguments are never  *)
(* even inspected on a hit, exactly like the source.                        *)

RegisterContext(T) ==
    /\ ctxArrivals[T] < MaxArrivals
    /\ ctxArrivals' = [ctxArrivals EXCEPT ![T] = @ + 1]
    /\ IF T \in seenCtx
       THEN UNCHANGED <<seenCtx, fieldSeq, structId, nextStructId>>
       ELSE /\ seenCtx' = seenCtx \cup {T}
            /\ structId' = [structId EXCEPT ![T] = nextStructId]
            /\ nextStructId' = nextStructId + 1
            /\ \E fs \in FieldOrderChoices(T) : fieldSeq' = [fieldSeq EXCEPT ![T] = fs]
    /\ UNCHANGED <<vtArrivals, seenVt, globalId, nextGlobalId, shapeAtCreation,
                   lastAnnotated, arityOf, vtStructOf, seenArities, nextVtStructId>>

----------------------------------------------------------------------------
(* (B)+(C) build_closure_vtable!: requires T's context already registered   *)
(* (closures.jl:49-50). Every arrival -- first sight AND every later one --  *)
(* picks an arity `ar` for THIS call: the real algorithm always derives it   *)
(* from T's own compiled body, so a first sight is PINNED to DeclaredArity  *)
(* (unconditionally); a revisit is pinned to the SAME arity UNLESS          *)
(* AllowArityDrift lifts that (the "T-keyed" assumption being tested).      *)
(* get_closure_vtable_struct!(ar) is looked up/created (memoized purely by  *)
(* the integer `ar`, shared across every T of that arity -- (B) above).      *)
(* On a cache hit for T (closures.jl:40-44/153-154) `lastAnnotated` is       *)
(* OVERWRITTEN with THIS call's `vId` while `shapeAtCreation` -- the         *)
(* global's real, frozen-at-birth shape -- never changes: exactly the        *)
(* asymmetry the header explains.                                           *)

EnsureVtable(T) ==
    /\ T \in seenCtx
    /\ vtArrivals[T] < MaxArrivals
    /\ vtArrivals' = [vtArrivals EXCEPT ![T] = @ + 1]
    /\ \E ar \in Arities :
         /\ (T \notin seenVt) => (ar = DeclaredArity[T])
         /\ (T \in seenVt) => (AllowArityDrift \/ ar = DeclaredArity[T])
         /\ arityOf' = [arityOf EXCEPT ![T] = ar]
         /\ LET isNewArity == ar \notin seenArities
                vId == IF isNewArity THEN nextVtStructId ELSE vtStructOf[ar]
            IN /\ seenArities' = seenArities \cup {ar}
               /\ vtStructOf' = [vtStructOf EXCEPT ![ar] = vId]
               /\ nextVtStructId' = IF isNewArity THEN nextVtStructId + 1 ELSE nextVtStructId
               /\ lastAnnotated' = [lastAnnotated EXCEPT ![T] = vId]
               /\ IF T \in seenVt
                  THEN UNCHANGED <<seenVt, globalId, nextGlobalId, shapeAtCreation>>
                  ELSE /\ seenVt' = seenVt \cup {T}
                       /\ globalId' = [globalId EXCEPT ![T] = nextGlobalId]
                       /\ nextGlobalId' = nextGlobalId + 1
                       /\ shapeAtCreation' = [shapeAtCreation EXCEPT ![T] = vId]
    /\ UNCHANGED <<ctxArrivals, seenCtx, fieldSeq, structId, nextStructId>>

----------------------------------------------------------------------------
(* Next: an explicit stutter once every arrival budget is exhausted, so the *)
(* spec never deadlocks (mirrors ClosedWorld.tla's Stutter / Stackifier's   *)
(* Terminal -- the finite arrival budget stands in for `function_data`      *)
(* eventually running out of entries).                                     *)

AllDone ==
    /\ \A T \in Types : ctxArrivals[T] = MaxArrivals /\ vtArrivals[T] = MaxArrivals
    /\ UNCHANGED vars

Next ==
    \/ \E T \in Types : RegisterContext(T)
    \/ \E T \in Types : EnsureVtable(T)
    \/ AllDone

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* The claims. *)

TypeOK ==
    /\ ctxArrivals \in [Types -> 0..MaxArrivals]
    /\ seenCtx \subseteq Types
    /\ fieldSeq \in [Types -> Seq(FieldClasses)]
    /\ structId \in [Types -> Nat]
    /\ nextStructId \in Nat
    /\ vtArrivals \in [Types -> 0..MaxArrivals]
    /\ seenVt \subseteq Types
    /\ globalId \in [Types -> Nat]
    /\ nextGlobalId \in Nat
    /\ shapeAtCreation \in [Types -> Nat]
    /\ lastAnnotated \in [Types -> Nat]
    /\ arityOf \in [Types -> Nat]
    /\ vtStructOf \in [Arities -> Nat]
    /\ seenArities \subseteq Arities
    /\ nextVtStructId \in Nat

\* (1) The context struct lists exactly the captured variables in the
\* program's declared order -- never a hash-dependent one.
CapturedFieldsAreDeclaredOrder == \A T \in seenCtx : fieldSeq[T] = DeclaredFields[T]

\* (3a) Two distinct closure types never share a context struct (each is its
\* own class at the struct-index level -- the id space add_struct_type!
\* hands out).
NoStructIdCollision ==
    \A T1, T2 \in seenCtx : T1 # T2 => structId[T1] # structId[T2]

\* (3b) Two distinct closure types never share a vtable GLOBAL.
NoGlobalIdCollision ==
    \A T1, T2 \in seenVt : T1 # T2 => globalId[T1] # globalId[T2]

\* (2a) One vtable STRUCT type is shared by every closure body of the same
\* arity (dart2wasm's per-shape ClosureRepresentation), and different
\* arities are never assigned the same struct.
OneVtableStructPerArity ==
    \A a1, a2 \in seenArities : a1 # a2 => vtStructOf[a1] # vtStructOf[a2]

\* (2b) THE HEADLINE CLAIM: whatever vt_struct id is currently annotated for
\* T's vtable global always matches the shape that global was ACTUALLY
\* populated with at creation -- so a call_ref reached through T's vtable
\* slot always executes under the signature the trampoline was built with;
\* no shape mismatch ever reaches call_ref.
WellFormedVtable == \A T \in seenVt : lastAnnotated[T] = shapeAtCreation[T]

=============================================================================
