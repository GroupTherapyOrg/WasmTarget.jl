-------------------------- MODULE Constants --------------------------------
(***************************************************************************)
(* A TLA+ model of WasmTarget's constant interning: the funnel that decides *)
(* whether a compile-time constant gets ONE deduplicated Wasm global (an    *)
(* "eager", constant-expression `global` whose initializer is itself a      *)
(* constant expression) or a fresh per-occurrence allocation. Two source    *)
(* sites, both cited by line:                                               *)
(*   - `ensure_constant_global!` / `_const_init_bytes!`                     *)
(*     (src/codegen/types.jl:221-322) -- THE funnel and its recursive       *)
(*     eager-internability test.                                            *)
(*   - the constant-MATERIALIZATION cascade in `compile_value`              *)
(*     (src/codegen/values.jl) -- every branch that either calls the        *)
(*     funnel first (immutable kinds) or unconditionally fresh-constructs   *)
(*     (the mutable kinds).                                                 *)
(*                                                                          *)
(* WHAT THE REAL ALGORITHM DOES.                                            *)
(*   (1) THE MAP. `registry.constant_globals::Dict{Any,UInt32}`             *)
(*       (types.jl:99) is keyed by the constant VALUE itself, so Julia's    *)
(*       default `isequal`/`hash` decide membership: `ensure_constant_      *)
(*       global!` (types.jl:221-230) does `haskey(constant_globals, val) && *)
(*       return constant_globals[val]` BEFORE building anything -- two      *)
(*       DISTINCT value objects that are structurally `isequal` collide on  *)
(*       the SAME dict key and therefore the SAME global, exactly like      *)
(*       dart2wasm's `Map<Constant, ConstantInfo> constantInfo`             *)
(*       (constants.dart:154) keyed by `Constant`'s own structural          *)
(*       equality. `add_global_ref!` (src/builder/instructions.jl:700-710)  *)
(*       assigns the number: `push!(mod.globals, ...); return length(mod.  *)
(*       globals) - 1` -- a plain APPEND, so the number is a pure function  *)
(*       of CALL ORDER (how many prior calls actually pushed a NEW entry),  *)
(*       never of the Dict's own hash-bucket layout.                       *)
(*   (2) EAGERNESS IS RECURSIVE AND MONOTONE. `_const_init_bytes!`          *)
(*       (types.jl:235-322) either returns a struct/array type idx (eager)  *)
(*       or `nothing` (decline), and DECLINES for: a value that is not an   *)
(*       immutable concrete struct/tuple (`!ismutabletype(T)` gate,         *)
(*       types.jl:254 -- mutable kinds NEVER reach this map); a layout      *)
(*       mismatch (types.jl:263-267); or -- the recursive case -- ANY field *)
(*       that is itself `isdefined` but whose OWN recursive                 *)
(*       `_const_init_bytes!` call declines (types.jl:316, "nested          *)
(*       immutable struct constant: recurse"). One declining field aborts   *)
(*       the WHOLE constant-expression build (`=== nothing && return        *)
(*       nothing`) -- there is no half-built global. Int128/UInt128         *)
(*       (types.jl:237-253) are the one primitive (non-struct) eager kind,  *)
(*       matching dart's boxed-numeric globals (constants.dart:622-655)     *)
(*       even though dart's OWN `IntConstant`/`DoubleConstant` need no      *)
(*       unique box at all (constants.dart:793-798, "value types do not     *)
(*       have identity"). dart2wasm's own `createConstant`                  *)
(*       (constants.dart:820-840) states the identical monotone rule in one *)
(*       line: `canBeEager = canBeEager && childConstants.every((c) =>      *)
(*       c.canBeEager);` (line 830) -- WT's recursive decline is the same   *)
(*       AND-over-children fixpoint, read from Julia's `isdefined`/field-    *)
(*       type machinery instead of dart's pre-canonicalized Kernel Constant *)
(*       tree.                                                             *)
(*   (3) NO FABRICATION. types.jl:270-271 and :291 both do `isdefined(val,  *)
(*       k) ? getfield(val, k) : ... return nothing` -- an undefined field   *)
(*       NEVER becomes bytes in a constant expression; it just declines     *)
(*       eagerness (silently, not an error). The FALLBACK inline path       *)
(*       (values.jl, the general-struct branch reached once the funnel      *)
(*       declines) re-checks the SAME fact at line 1769 and this time       *)
(*       REJECTS out loud (`record_unsupported!(...; soundness_fatal=       *)
(*       true)`) UNLESS the value is `Core.Box` with exactly its            *)
(*       `:contents` field undefined (values.jl:1755-1768) -- WT's captured-*)
(*       variable cell for an as-yet-unassigned closure variable, whose     *)
(*       PHYSICAL sentinel (`ref.null AnyRef`) is the one documented        *)
(*       allowed exception; a Dict constant's unoccupied hash-bucket slot   *)
(*       (`compile_memory_elements!`, values.jl:1578-1607) is the OTHER     *)
(*       one -- `dict_slots[i] & 0x80 == 0` emits the destination Wasm      *)
(*       type's own physical zero/null (values.jl:1590-1604), and rejects   *)
(*       only if even THAT has no safe physical default (values.jl:1603).   *)
(*       A `Memory`/`MemoryRef` constant's unassigned slot has no such      *)
(*       exception at all: `isassigned(mem,i) || record_unsupported!(...)`  *)
(*       (values.jl:1708-1711) always rejects. Dart has no anchor for this  *)
(*       claim: Dart's Kernel constant evaluator only ever produces a fully *)
(*       -evaluated `Constant` AST node, so "an undefined constant field"   *)
(*       is not a shape `ensureConstant` can ever see -- this is a          *)
(*       Julia-only extension of the funnel, arising from Julia's           *)
(*       `isdefined`/`UndefRefError` runtime semantics.                    *)
(*   (4) THE MUTABLE-IDENTITY FLOOR. `Vector`/`Dict`/`Memory`/`Core.Box`     *)
(*       constants (values.jl's `typeof(val) <: Dict`/`<: Vector`/          *)
(*       MemoryRef-family/general-struct-Box-case branches) NEVER call the  *)
(*       funnel for THEMSELVES -- each occurrence is an unconditional fresh *)
(*       `struct.new`/`array.new_fixed`, because per-object identity is     *)
(*       observable through `===` and mutation and Julia's mutable types    *)
(*       have no immutable-literal form to canonicalize. This is the exact  *)
(*       mirror of dart's OWN split: `visitListConstant`/`visitMapConstant` *)
(*       (constants.dart:1128/1152) canonicalize ONLY Dart's                *)
(*       `immutableListClass`/`immutableMapClass` -- i.e. a genuine `const` *)
(*       literal -- by rewriting it into an ordinary `InstanceConstant` and *)
(*       routing it through the SAME `ensureConstant` map (constants.dart:  *)
(*       1148/1189+); Julia's `Vector`/`Dict` have no such immutable-literal *)
(*       form, so every occurrence takes dart's OTHER, ordinary            *)
(*       runtime-instantiation shape instead (fresh, never canonicalized).  *)
(*       A NESTED immutable sub-value of a mutable constant is NOT floored  *)
(*       by this: a constant `Vector{T}`'s size tuple `(Int64(length        *)
(*       (val)),)` is a bare immutable `Tuple{Int64}` and goes through the  *)
(*       funnel exactly like any other tuple constant (values.jl:1685-      *)
(*       1687) -- every constant Vector of one length shares ONE size-      *)
(*       tuple global, matching dart's "sub-constants intern regardless of  *)
(*       the composite's own eagerness" (constants.dart:938-959, cited      *)
(*       in-source at that call site).                                     *)
(*                                                                          *)
(* OUT OF SCOPE, AND WHY. `String`/`Symbol`/`Type`/`Core.TypeName`/`Module`  *)
(* constants each own a SEPARATE dedicated dict (`string_constant_globals`, *)
(* `type_constant_globals`, `typename_constant_globals`, and the Module     *)
(* case sharing `constant_globals` itself, types.jl:99-108) -- structurally *)
(* the identical "one map, keyed by value, one global per distinct value"   *)
(* funnel this model already covers; a second copy of the same mechanism    *)
(* teaches TLC nothing new. `GlobalRef`'s `mutable_constant_globals`        *)
(* (types.jl:103, consulted at values.jl:1351-1374) is a GENUINELY          *)
(* different mechanism and is deliberately NOT modeled: it is keyed by      *)
(* OBJECT IDENTITY (`IdDict`) and exists to alias a `GlobalRef` to a real,  *)
(* already-shared Julia module BINDING back to the same Wasm global on      *)
(* every reference -- correct aliasing of one true mutable object, not      *)
(* materialization of a constant-propagated LITERAL value, so it is exempt  *)
(* from (and does not test) the mutable-identity floor at all.              *)
(*                                                                          *)
(* WHAT THIS MODEL ABSTRACTS, AND WHY THAT IS SUFFICIENT.                   *)
(*  - A "constant occurrence" is an opaque index 1..N processed in the      *)
(*    order the compiler actually encounters it (program order); this is   *)
(*    the only order-sensitive input to (1)'s numbering claim.             *)
(*  - Structural nesting (a struct constant's fields) is collapsed to ONE   *)
(*    optional `child` pointer per occurrence rather than a full field      *)
(*    list: the claim under test is the AND-over-children FIXPOINT          *)
(*    (monotone: one bad field spoils the whole value), which is            *)
(*    associative/commutative over however many fields the real source has *)
(*    -- a single modeled child, chained to arbitrary depth (`child[v] \in  *)
(*    1..(v-1)`, so a chain can run the full length of the occurrence       *)
(*    list), already forces TLC through both the "spoils" and "does not     *)
(*    spoil" transitions at every depth; a second, independent sibling      *)
(*    field would only re-run the identical AND, not exercise new state.    *)
(*  - `fstat` (Def / UndefReject / UndefSentinel) collapses "which of       *)
(*    general-struct-field / Memory-element / Dict-bucket-element this is"  *)
(*    into the one fact each of those cases actually reduces to for this    *)
(*    claim: does an unresolvable slot on this value REJECT (no safe        *)
(*    physical default -- general struct fields, Memory elements) or        *)
(*    proceed via a SENTINEL (Core.Box's contents field, a nullable/        *)
(*    numeric Dict bucket)? `fstat` is left INDEPENDENT of `kind` on        *)
(*    purpose (not restricted to kind="Mut"): the real UndefSentinel shapes *)
(*    arise from two structurally different code paths (a struct FIELD     *)
(*    vs. a Memory ARRAY ELEMENT) that this model does not otherwise        *)
(*    distinguish, per MODEL_RULES.md's "if the source's decision procedure *)
(*    has a case you cannot map, say so" -- forcing a kind correlation      *)
(*    here would encode a distinction the claim does not depend on.         *)
(*  - `eqclass` is an unconstrained per-occurrence label standing in for    *)
(*    Julia's real `isequal`/`hash`: TLC is not asked to reprove that       *)
(*    Julia's equality is itself correct, only that the FUNNEL'S reaction   *)
(*    to two occurrences sharing (or not sharing) a class is right --       *)
(*    exactly like Stackifier.tla leaving `target`/`phifree` free within    *)
(*    their supported class rather than deriving them from a real CFG.      *)
(*  - Four historical-shaped bug classes are wired in as CONSTANT flags,    *)
(*    each isolating exactly one of the four claims below; only one is ever *)
(*    TRUE in a given run (the real algorithm is all four FALSE):           *)
(*      InternMutableKind   -- claim (1): the funnel's `!ismutabletype(T)`  *)
(*        gate (types.jl:254) is dropped, so a `kind="Mut"` occurrence      *)
(*        becomes eager-eligible like any struct -- the shape of "someone   *)
(*        adds Vector/Dict to the general struct branch's `isstructtype`    *)
(*        check without excluding mutability."                             *)
(*      SkipChildEagerCheck -- claim (2): the recursive "AND every field's  *)
(*        own `_const_init_bytes!`" (types.jl:316) is skipped, so a value's *)
(*        eagerness is decided from its OWN fields only -- the shape of     *)
(*        forgetting to propagate a nested `=== nothing` decline upward.    *)
(*      FabricateUndefFields -- claim (3): the `isdefined(...) || return    *)
(*        nothing` / `record_unsupported!` checks (types.jl:270-271/291,    *)
(*        values.jl:1769) are skipped, so an UndefReject value is silently  *)
(*        treated as though it were fully defined -- the shape of loosening *)
(*        `isdefined(val,k) ? getfield(val,k) : nothing` into a defaulted   *)
(*        value instead of bailing.                                        *)
(*      HashOrderNumbering -- claim (4): `add_global_ref!`'s append-and-    *)
(*        return-next-index (instructions.jl:709) is replaced by drawing    *)
(*        the new class's slot from whatever is left over in NO particular  *)
(*        order -- the shape of re-deriving global numbering by walking a   *)
(*        `Dict` in hash-bucket order (the L112 bug class, test/            *)
(*        parity_ratchet.jl:1426, lifted from `registry.structs` to         *)
(*        `registry.constant_globals`) instead of by discovery/call order.  *)
(*                                                                          *)
(* Like Stackifier.tla, every action below is atomic and single-threaded    *)
(* (`ensure_constant_global!` has no concurrency to interleave); TLC's      *)
(* exploration is over the INITIAL CHOICE of the occurrence class (kind /   *)
(* fstat / child / eqclass, chosen once in Init) and, only under            *)
(* HashOrderNumbering, over which leftover slot a new class draws.          *)
(*                                                                          *)
(* formal(dev/formal/Constants.tla): two structurally-equal immutable       *)
(* constants intern to exactly one global and a mutable-kind constant never *)
(* shares one; a constant's eagerness is the AND of its children's, so a    *)
(* non-eager child always yields a fresh construction, never a partially-   *)
(* interned global; an unresolvable field either rejects compilation or     *)
(* takes its type's physical default, never a fabricated Julia value; and   *)
(* global numbering is a deterministic function of interning (discovery)    *)
(* order.                                                                   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    N,                      \* number of constant occurrences, processed in program order 1..N
    EqIds,                  \* finite universe of structural-equality classes (stand-in for isequal/hash)
    InternMutableKind,      \* BOOLEAN: TRUE = drop the "!ismutabletype" gate (claim 1 bug)
    SkipChildEagerCheck,    \* BOOLEAN: TRUE = decide eagerness from self only, ignore children (claim 2 bug)
    FabricateUndefFields,   \* BOOLEAN: TRUE = treat an UndefReject field as though defined (claim 3 bug)
    HashOrderNumbering      \* BOOLEAN: TRUE = assign new global ids out of discovery order (claim 4 bug)

ASSUME N \in Nat /\ N >= 1
ASSUME IsFiniteSet(EqIds) /\ EqIds # {}
ASSUME InternMutableKind \in BOOLEAN
ASSUME SkipChildEagerCheck \in BOOLEAN
ASSUME FabricateUndefFields \in BOOLEAN
ASSUME HashOrderNumbering \in BOOLEAN

Occurrences == 1..N
Kinds == {"Imm", "Mut"}
FStats == {"Def", "UndefReject", "UndefSentinel"}

MaxClasses == Cardinality(EqIds)
AvailableIds == {n \in 0..(MaxClasses - 1) : TRUE}
\* Every element of GlobalVal is uniformly a 2-tuple, tagged by shape: TLC's
\* SetEnum \cup normalizes by comparing elements pairwise, and a raw Nat has
\* no defined comparison against a raw tuple (it throws mid-union) -- so a
\* table-assigned global id is wrapped exactly like a fresh one, never left
\* as a bare Nat next to <<"Fresh", v>> in the same set.
TableVals == {<<"Table", n>> : n \in AvailableIds}
FreshVals == {<<"Fresh", v>> : v \in Occurrences}
GlobalVal == TableVals \cup FreshVals \cup {<<"Unprocessed", 0>>}

VARIABLES
    kind,       \* [Occurrences -> Kinds] -- "Imm" (struct/tuple/Int128 shape) or "Mut" (Vector/Dict/Memory/Box shape)
    fstat,      \* [Occurrences -> FStats] -- this occurrence's OWN field-definedness fact
    child,      \* [Occurrences -> {0} \cup Occurrences] -- one nested constant-expressible field, or none
    eqclass,    \* [Occurrences -> EqIds] -- structural-equality class (stand-in for isequal/hash)
    cur,        \* the occurrence currently being (or about to be) processed
    pc,         \* "Run" | "Done" | "Reject"
    globalOf,   \* [Occurrences -> GlobalVal] -- this occurrence's compiled outcome
    \* registry.constant_globals, keyed by class, split into two HOMOGENEOUS
    \* maps rather than one Nat-or-"NoGlobal" sum type: TLC's SetEnum \cup
    \* normalizes by comparing elements pairwise, and neither a raw Nat vs. a
    \* raw String nor a raw Nat vs. a tuple has a defined comparison (both
    \* throw mid-union) -- so "no global yet" is BOOLEAN, never a sentinel
    \* sharing a set with the Nat ids.
    classAssigned,  \* [EqIds -> BOOLEAN] -- has this class been given a global yet?
    classId         \* [EqIds -> AvailableIds] -- meaningful only where classAssigned[e]

vars == <<kind, fstat, child, eqclass, cur, pc, globalOf, classAssigned, classId>>

----------------------------------------------------------------------------
(* Ground truth: what the REAL (unbugged) algorithm decides. Every claim    *)
(* below is checked against THESE, never against the (possibly patched)     *)
(* Algo-prefixed versions Next actually runs -- exactly Stackifier's        *)
(* physical/symbolic split (WellScopedBr checked against `physstack`, not   *)
(* the algorithm's own `labelstack` belief).                                *)

RECURSIVE Eager(_)
Eager(v) == /\ kind[v] = "Imm"
            /\ fstat[v] = "Def"
            /\ (child[v] = 0 \/ Eager(child[v]))

RECURSIVE HasUndef(_)
HasUndef(v) == \/ fstat[v] = "UndefReject"
               \/ (child[v] # 0 /\ HasUndef(child[v]))

----------------------------------------------------------------------------
(* What the (possibly bugged) algorithm actually computes and acts on.      *)

RECURSIVE EagerAlgo(_)
EagerAlgo(v) == /\ (InternMutableKind \/ kind[v] = "Imm")
                /\ (fstat[v] = "Def" \/ (FabricateUndefFields /\ fstat[v] = "UndefReject"))
                /\ (SkipChildEagerCheck \/ child[v] = 0 \/ EagerAlgo(child[v]))

RECURSIVE HasUndefAlgo(_)
HasUndefAlgo(v) == /\ ~FabricateUndefFields
                   /\ \/ fstat[v] = "UndefReject"
                      \/ (child[v] # 0 /\ HasUndefAlgo(child[v]))

----------------------------------------------------------------------------
(* Init: choose one occurrence class (kind/fstat/child/eqclass), unconstrained *)
(* within it -- this existential is what TLC "enumerates" (Stackifier's same  *)
(* framing). `child[v]` ranges over strictly smaller indices so Eager/HasUndef *)
(* are well-founded and a chain can run the whole occurrence list.            *)

Init ==
    /\ kind \in [Occurrences -> Kinds]
    /\ fstat \in [Occurrences -> FStats]
    /\ child \in {f \in [Occurrences -> {0} \cup Occurrences] :
                    \A v \in Occurrences : f[v] \in ({0} \cup 1..(v - 1))}
    /\ eqclass \in [Occurrences -> EqIds]
    /\ cur = 1
    /\ pc = "Run"
    /\ globalOf = [v \in Occurrences |-> <<"Unprocessed", 0>>]
    /\ classAssigned = [e \in EqIds |-> FALSE]
    /\ classId = [e \in EqIds |-> 0]

----------------------------------------------------------------------------
(* Next: process one occurrence per atomic step, in strict program order --  *)
(* mirrors that `ensure_constant_global!`/`compile_value` runs straight-line, *)
(* single-threaded, once per constant as the compiler encounters it. A       *)
(* rejected compile halts everything (matches `soundness_fatal=true`         *)
(* aborting the whole codegen run, never just skipping the one constant).    *)

ProcessOccurrence(v) ==
    /\ pc = "Run"
    /\ cur = v
    /\ UNCHANGED <<kind, fstat, child, eqclass>>
    /\ IF HasUndefAlgo(v)
       THEN /\ pc' = "Reject"
            /\ cur' = v
            /\ UNCHANGED <<globalOf, classAssigned, classId>>
       ELSE LET eagerNow == EagerAlgo(v)
                ec == eqclass[v]
            IN /\ pc' = IF v = N THEN "Done" ELSE "Run"
               /\ cur' = IF v = N THEN v ELSE v + 1
               /\ IF ~eagerNow
                  THEN /\ globalOf' = [globalOf EXCEPT ![v] = <<"Fresh", v>>]
                       /\ UNCHANGED <<classAssigned, classId>>
                  ELSE IF classAssigned[ec]
                       THEN /\ globalOf' = [globalOf EXCEPT ![v] = <<"Table", classId[ec]>>]
                            /\ UNCHANGED <<classAssigned, classId>>
                       ELSE IF ~HashOrderNumbering
                            THEN LET newid == Cardinality({e \in EqIds : classAssigned[e]})
                                 IN /\ classAssigned' = [classAssigned EXCEPT ![ec] = TRUE]
                                    /\ classId' = [classId EXCEPT ![ec] = newid]
                                    /\ globalOf' = [globalOf EXCEPT ![v] = <<"Table", newid>>]
                            ELSE \E newid \in AvailableIds \ {classId[e] : e \in {e2 \in EqIds : classAssigned[e2]}} :
                                    /\ classAssigned' = [classAssigned EXCEPT ![ec] = TRUE]
                                    /\ classId' = [classId EXCEPT ![ec] = newid]
                                    /\ globalOf' = [globalOf EXCEPT ![v] = <<"Table", newid>>]

Terminal == pc \in {"Done", "Reject"} /\ UNCHANGED vars

Next == (\E v \in Occurrences : ProcessOccurrence(v)) \/ Terminal

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* The four claims. *)

TypeOK ==
    /\ kind \in [Occurrences -> Kinds]
    /\ fstat \in [Occurrences -> FStats]
    /\ child \in [Occurrences -> {0} \cup Occurrences]
    /\ eqclass \in [Occurrences -> EqIds]
    /\ cur \in Occurrences
    /\ pc \in {"Run", "Done", "Reject"}
    /\ globalOf \in [Occurrences -> GlobalVal]
    /\ classAssigned \in [EqIds -> BOOLEAN]
    /\ classId \in [EqIds -> AvailableIds]

(* (1a) CANONICALIZATION: two occurrences that are BOTH really eager and     *)
(* share a structural-equality class intern to the SAME global -- the       *)
(* `haskey(constant_globals, val) && return constant_globals[val]` reuse.   *)
Canonicalization ==
    pc = "Done" =>
        \A i, j \in Occurrences :
            (Eager(i) /\ Eager(j) /\ eqclass[i] = eqclass[j]) => globalOf[i] = globalOf[j]

(* (1b) MUTABLE NEVER ALIASES: any two DISTINCT occurrences where at least   *)
(* one is really non-eager (in particular every "Mut"-kind occurrence, which *)
(* is ALWAYS non-eager per Eager's definition) get DISTINCT outcomes -- the  *)
(* mutable-identity floor: never a shared global, so mutation/`===` through  *)
(* one occurrence can never be observed through the other.                  *)
MutableNeverAliases ==
    pc = "Done" =>
        \A i, j \in Occurrences :
            (i # j /\ (~Eager(i) \/ ~Eager(j))) => globalOf[i] # globalOf[j]

(* (2) NO PARTIAL INTERN: a really non-eager occurrence's outcome is ALWAYS  *)
(* its own fresh construction -- never a table id. Eagerness is the AND of a *)
(* value's own fields and its child's eagerness (recursively): one bad      *)
(* (mutable, undefined, or itself-non-eager) child forces the WHOLE value to *)
(* the fallback tail, never a global built from a mix of shared and ad hoc   *)
(* parts.                                                                   *)
NoPartialIntern ==
    pc = "Done" =>
        \A v \in Occurrences : ~Eager(v) => globalOf[v] = <<"Fresh", v>>

(* (3) NO FABRICATION: compilation never reaches Done while some occurrence  *)
(* genuinely has an undefined field with no sanctioned physical sentinel --  *)
(* the ONLY two outcomes for such a value are "reject the whole compile" and *)
(* (only when the value carries the documented UndefSentinel exception) a    *)
(* successful, un-canonicalized fresh construction; never a value invented   *)
(* to fill the hole.                                                        *)
NoFabrication ==
    pc = "Done" => \A v \in Occurrences : ~HasUndef(v)

(* (4) DETERMINISTIC NUMBERING: a really-eager occurrence's global id is the *)
(* RANK of its class among all eager classes' first (smallest-index)         *)
(* occurrence -- a pure function of interning (discovery) order, independent *)
(* of anything hash-bucket-shaped. Ground truth, computed without reference  *)
(* to `classId`/`globalOf` at all. *)
EagerOccs == {v \in Occurrences : Eager(v)}
EagerClasses == {eqclass[v] : v \in EagerOccs}
FirstOccOfClass(ec) ==
    CHOOSE v \in EagerOccs :
        /\ eqclass[v] = ec
        /\ \A w \in EagerOccs : eqclass[w] = ec => v <= w
ClassRank(ec) == Cardinality({ec2 \in EagerClasses : FirstOccOfClass(ec2) < FirstOccOfClass(ec)})

DeterministicNumbering ==
    pc = "Done" => \A v \in Occurrences : Eager(v) => globalOf[v] = <<"Table", ClassRank(eqclass[v])>>

(* Once rejected, the compile stays rejected -- no further label event or    *)
(* global emission occurs (mirrors `soundness_fatal=true` unwinding the      *)
(* whole codegen run, matching Stackifier's RejectNeverEmits). *)
RejectHalts == [][pc = "Reject" => UNCHANGED vars]_vars

=============================================================================
