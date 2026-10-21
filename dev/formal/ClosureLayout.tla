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
(* add_type! hands out, a distinct id space from ensure_type_id!'s           *)
(* Julia-level classIds). One fact joins the two: add_type! merges a struct  *)
(* type equal to one already defined (outside a recursion group), so two     *)
(* closure types whose captured fields translate alike share ONE context     *)
(* struct type, and a context's class is read from its classId field         *)
(* (field 0, ensure_type_id!'s distinct id), never from its struct type.     *)
(*                                                                           *)
(* WHAT THE REAL ALGORITHM DOES (the part this model checks).                *)
(*                                                                           *)
(* (A) CONTEXT STRUCT (register_closure_type!, structs.jl). On the          *)
(*     FIRST sight of T: `field_names/field_types` are read via              *)
(*     `[fieldname(T,i) for i in 1:fieldcount(T)]` -- a plain Julia FIELD-    *)
(*     INDEX range, never a Dict/Set walk -- then each field's Julia type    *)
(*     translates through the ONE struct-field rule, translate_storage_type  *)
(*     (class_info.dart:539 _generateFields → translateStorageType), the     *)
(*     rule a struct's and a tuple's fields take too: a captured struct is   *)
(*     its struct's reference, never erased to structref by a rule of the    *)
(*     closure registrar's own -- and a struct-type index is allocated       *)
(*     (`finish_pending!`, the type section's monotonic counter; a field     *)
(*     reaching T again refers to its pending entry). `registry.structs[T]`  *)
(*     caches it. On EVERY later                                             *)
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
(* (D) A VTABLE ENTRY'S BODY (fill_closure_trampoline!, closures.jl). An     *)
(*     entry of T whose body returns a closure of type U builds U's object   *)
(*     with U's vtable global (`Returns[T] = U`, a CONSTANT). The pre-pass    *)
(*     DEFINES every entry with its global and generates the bodies after    *)
(*     the last global (dart: functions.define, then the compilation queue,  *)
(*     translator.dart:1461), so the object holds U's own vtable. Filling a  *)
(*     body where its entry is defined reads U's global before U's layout    *)
(*     defines it, and the object holds the empty vtable: a dynamic call of  *)
(*     the result traps.                                                     *)
(*                                                                           *)
(* WHAT THIS MODEL ABSTRACTS, AND WHY THAT IS SUFFICIENT.                    *)
(*  - Julia types collapse to opaque ids (`Types`); a captured field's       *)
(*    Julia type collapses to an opaque CLASS (`FieldClasses`), whose        *)
(*    storage the one struct-field rule gives (`FieldStorage`, a CONSTANT:   *)
(*    the rule is a pure function of one field's type). The context records  *)
(*    each field's class and the storage the registrar gave it, so the       *)
(*    model checks both the order (`DeclaredFields[T]`, a CONSTANT -- Julia  *)
(*    fixes a closure struct's field order before WT ever sees T) and that   *)
(*    the storage is the struct field's.                                     *)
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
(* THE FIVE BROKEN VARIANTS.                                                 *)
(*  - `FillAtDefine = TRUE`: an entry's body is generated where the entry is *)
(*    defined, before a later type's vtable global exists. TLC must find an  *)
(*    entry whose closure result holds the empty vtable                     *)
(*    (`EntryResultHoldsItsVtable` violated).                               *)
(*  - `TellApartByStruct = TRUE`: a context's class is read from its struct  *)
(*    type -- the claim that distinct closure types have distinct structs,  *)
(*    which add_type!'s merge of equal structs makes false. TLC must find two *)
(*    closure types with alike fields read as one class                      *)
(*    (`ContextsToldApart` violated).                                        *)
(*  - `OwnFieldRule = TRUE`: register_closure_type! translates a captured    *)
(*    field by a rule of its own (`OwnStorage`: a struct field erased to     *)
(*    structref by julia_to_wasm_type, where the struct registrar gives its  *)
(*    struct's reference) -- the three-translator disagreement 13.4 named.   *)
(*    TLC must find a context whose field storage is not the struct field's *)
(*    (`OneFieldTranslation` violated).                                      *)
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
(* a hash-dependent one, each in the storage the one struct-field rule      *)
(* gives its type; two closure types share a context struct type only when  *)
(* their fields translate alike, and are told apart by their classId field;  *)
(* two distinct closure types never share a vtable-global id; one struct     *)
(* type is shared by every closure                                           *)
(* body of the same arity (dart2wasm's per-shape ClosureRepresentation); and *)
(* the vt_struct annotation returned for a closure type's vtable global      *)
(* always matches the shape that global was actually populated with, so no  *)
(* shape mismatch ever reaches `call_ref`; an entry returning a closure      *)
(* holds that closure type's own vtable global.                              *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Types,             \* finite universe of closure-type ids
    Arities,           \* finite set of Nat: supported positional arities
    FieldClasses,      \* finite universe of captured-field Julia type classes
    FieldStorage,      \* [FieldClasses -> STRING]: the one struct-field rule's storage of a class
    OwnStorage,        \* [FieldClasses -> STRING]: a registrar's own rule (the Broken variant's)
    DeclaredFields,    \* [Types -> Seq(FieldClasses)]: T's real declared capture order
    DeclaredArity,     \* [Types -> Arities]: T's real positional call arity
    MaxArrivals,       \* Nat: bounds how many times each step may revisit one T
    TellApartByStruct, \* BOOLEAN: TRUE = a context's class read from its struct type, not its classId
    HashOrderCapture,  \* BOOLEAN: TRUE = the retired/counterfactual hash-order field variant
    AllowArityDrift,   \* BOOLEAN: TRUE = a revisit of T may request a different arity
    OwnFieldRule,      \* BOOLEAN: TRUE = the closure registrar translates a field by its own rule
    Returns,           \* [Types -> Types \cup {"none"}]: the closure type T's entry returns, if any
    FillAtDefine       \* BOOLEAN: TRUE = an entry's body is generated where the entry is defined

ASSUME IsFiniteSet(Types)
ASSUME Arities \subseteq Nat /\ IsFiniteSet(Arities)
ASSUME IsFiniteSet(FieldClasses)
ASSUME DeclaredFields \in [Types -> Seq(FieldClasses)]
ASSUME DeclaredArity \in [Types -> Arities]
ASSUME MaxArrivals \in Nat /\ MaxArrivals >= 1
ASSUME HashOrderCapture \in BOOLEAN
ASSUME TellApartByStruct \in BOOLEAN
ASSUME AllowArityDrift \in BOOLEAN
ASSUME OwnFieldRule \in BOOLEAN
ASSUME FieldStorage \in [FieldClasses -> STRING] /\ OwnStorage \in [FieldClasses -> STRING]
ASSUME Returns \in [Types -> Types \cup {"none"}]
ASSUME FillAtDefine \in BOOLEAN

Storages == {FieldStorage[c] : c \in FieldClasses} \cup {OwnStorage[c] : c \in FieldClasses}

VARIABLES
    ctxArrivals,      \* [Types -> 0..MaxArrivals] -- register_closure_type! calls so far
    seenCtx,           \* SUBSET Types -- T's whose context struct is registered
    fieldSeq,          \* [Types -> Seq(FieldClasses \X Storages)] -- the RECORDED fields, each its class and
                       \* the storage the registrar gave it (meaningful once seenCtx)
    structId,          \* [Types -> Nat] -- register_closure_type!'s struct-type index (0 = unassigned)
    nextStructId,      \* Nat -- add_struct_type!'s monotonic type-section counter
    vtArrivals,        \* [Types -> 0..MaxArrivals] -- vtable arrivals (build_closure_vtable! / closure_vtable) so far
    seenVt,            \* SUBSET Types -- T's whose vtable global exists
    globalId,          \* [Types -> Nat] -- the one vtable global per closure body (0 = unassigned)
    nextGlobalId,      \* Nat -- define_global!'s monotonic counter
    shapeAtCreation,   \* [Types -> Nat] -- GROUND TRUTH: the vt_struct id T's global was populated with
    lastAnnotated,     \* [Types -> Nat] -- the vt_struct id most recently RETURNED/used for T
    arityOf,           \* [Types -> Nat] -- the arity of T's most recent arrival (diagnostic/history)
    vtStructOf,        \* [Arities -> Nat] -- get_closure_vtable_struct!'s per-arity struct index (0 = unassigned)
    seenArities,       \* SUBSET Arities -- arities with an assigned vtable struct
    nextVtStructId,    \* Nat -- the per-arity monotonic counter
    filled,            \* SUBSET Types -- T's whose entry body is generated
    resultVt           \* [Types -> Nat] -- the vtable global T's entry gives its closure result (0 = the empty vtable)

vars == <<ctxArrivals, seenCtx, fieldSeq, structId, nextStructId,
          vtArrivals, seenVt, globalId, nextGlobalId, shapeAtCreation,
          lastAnnotated, arityOf, vtStructOf, seenArities, nextVtStructId, filled, resultVt>>

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

\* The registrar's field rule over a class sequence: the one struct-field rule, or (Broken) its own.
Translate(cs) == [i \in 1..Len(cs) |->
    <<cs[i], IF OwnFieldRule THEN OwnStorage[cs[i]] ELSE FieldStorage[cs[i]]>>]

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
    /\ filled = {}
    /\ resultVt = [T \in Types |-> 0]

----------------------------------------------------------------------------
(* (A) register_closure_type!: first sight allocates a fresh struct id and  *)
(* records a field order drawn from FieldOrderChoices(T); a cache hit        *)
(* (structs.jl:87 `haskey(...) && return`) leaves EVERYTHING about T         *)
(* unchanged -- the new call's (absent, in this model) arguments are never  *)
(* even inspected on a hit, exactly like the source.                        *)

\* a context struct's wasm fields: the storages, in order (add_type! compares these, not classes)
StorageOf(sq) == [i \in 1..Len(sq) |-> sq[i][2]]

RegisterContext(T) ==
    /\ ctxArrivals[T] < MaxArrivals
    /\ ctxArrivals' = [ctxArrivals EXCEPT ![T] = @ + 1]
    /\ IF T \in seenCtx
       THEN UNCHANGED <<seenCtx, fieldSeq, structId, nextStructId>>
       ELSE /\ seenCtx' = seenCtx \cup {T}
            /\ \E fs \in FieldOrderChoices(T) :
                 LET tr == Translate(fs)
                     same == {U \in seenCtx : StorageOf(fieldSeq[U]) = StorageOf(tr)}
                     \* add_type!: an equal struct already defined is that struct, else a fresh index
                     id == IF same = {} THEN nextStructId ELSE structId[CHOOSE U \in same : TRUE]
                 IN /\ fieldSeq' = [fieldSeq EXCEPT ![T] = tr]
                    /\ structId' = [structId EXCEPT ![T] = id]
                    /\ nextStructId' = IF same = {} THEN nextStructId + 1 ELSE nextStructId
    /\ UNCHANGED <<vtArrivals, seenVt, globalId, nextGlobalId, shapeAtCreation,
                   lastAnnotated, arityOf, vtStructOf, seenArities, nextVtStructId, filled, resultVt>>

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

\* the vtable global an entry of T gives its closure result under the globals `g` (0: none yet, so
\* closure_vtable_global's empty vtable)
ResultGlobal(T, g) == IF Returns[T] = "none" THEN 0 ELSE g[Returns[T]]

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
                  THEN UNCHANGED <<seenVt, globalId, nextGlobalId, shapeAtCreation, filled, resultVt>>
                  ELSE /\ seenVt' = seenVt \cup {T}
                       /\ globalId' = [globalId EXCEPT ![T] = nextGlobalId]
                       /\ nextGlobalId' = nextGlobalId + 1
                       /\ shapeAtCreation' = [shapeAtCreation EXCEPT ![T] = vId]
                       \* (Broken) the entry's body generated here, reading its result's global as it stands
                       /\ IF FillAtDefine
                          THEN /\ filled' = filled \cup {T}
                               /\ resultVt' = [resultVt EXCEPT ![T] = ResultGlobal(T, globalId')]
                          ELSE UNCHANGED <<filled, resultVt>>
    /\ UNCHANGED <<ctxArrivals, seenCtx, fieldSeq, structId, nextStructId>>

----------------------------------------------------------------------------
(* (D) fill_closure_trampoline!: the compilation queue, run once every       *)
(* vtable global is defined (every type's layout done).                       *)

FillEntry(T) ==
    /\ ~FillAtDefine
    /\ seenVt = Types
    /\ T \notin filled
    /\ filled' = filled \cup {T}
    /\ resultVt' = [resultVt EXCEPT ![T] = ResultGlobal(T, globalId)]
    /\ UNCHANGED <<ctxArrivals, seenCtx, fieldSeq, structId, nextStructId,
                   vtArrivals, seenVt, globalId, nextGlobalId, shapeAtCreation,
                   lastAnnotated, arityOf, vtStructOf, seenArities, nextVtStructId>>

----------------------------------------------------------------------------
(* Next: an explicit stutter once every arrival budget is exhausted, so the *)
(* spec never deadlocks (mirrors ClosedWorld.tla's Stutter / Stackifier's   *)
(* Terminal -- the finite arrival budget stands in for `function_data`      *)
(* eventually running out of entries).                                     *)

AllDone ==
    /\ \A T \in Types : ctxArrivals[T] = MaxArrivals /\ vtArrivals[T] = MaxArrivals
    /\ filled = Types
    /\ UNCHANGED vars

Next ==
    \/ \E T \in Types : RegisterContext(T)
    \/ \E T \in Types : EnsureVtable(T)
    \/ \E T \in Types : FillEntry(T)
    \/ AllDone

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* The claims. *)

TypeOK ==
    /\ ctxArrivals \in [Types -> 0..MaxArrivals]
    /\ seenCtx \subseteq Types
    /\ fieldSeq \in [Types -> Seq(FieldClasses \X Storages)]
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
    /\ filled \subseteq Types
    /\ resultVt \in [Types -> Nat]

\* (1) The context struct lists exactly the captured variables in the
\* program's declared order -- never a hash-dependent one.
CapturedFieldsAreDeclaredOrder ==
    \A T \in seenCtx : [i \in 1..Len(fieldSeq[T]) |-> fieldSeq[T][i][1]] = DeclaredFields[T]

\* (1b) Each captured field's storage is the one struct-field rule's answer for its type
\* (translate_storage_type, as a struct's and a tuple's fields take it): one translation.
OneFieldTranslation ==
    \A T \in seenCtx : \A i \in 1..Len(fieldSeq[T]) : fieldSeq[T][i][2] = FieldStorage[fieldSeq[T][i][1]]

\* (3a) Two closure types share a context struct type only when their fields translate alike
\* (add_type! merges equal structs), and two distinct closure types are always told apart: a
\* context's class is its classId field, ensure_type_id!'s distinct id (ClassIdDispatch.tla), never
\* its struct type, which two classes may share.
ReadClass(T) == IF TellApartByStruct THEN structId[T] ELSE T
SharedOnlyIfAlike ==
    \A T1, T2 \in seenCtx : structId[T1] = structId[T2] => StorageOf(fieldSeq[T1]) = StorageOf(fieldSeq[T2])
ContextsToldApart ==
    \A T1, T2 \in seenCtx : T1 # T2 => ReadClass(T1) # ReadClass(T2)

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

\* (4) An entry returning a closure gives it that closure type's own vtable global, never the
\* empty vtable, so a dynamic call of the result reaches its entries.
EntryResultHoldsItsVtable ==
    \A T \in filled : Returns[T] # "none" => resultVt[T] # 0 /\ resultVt[T] = globalId[Returns[T]]

=============================================================================
