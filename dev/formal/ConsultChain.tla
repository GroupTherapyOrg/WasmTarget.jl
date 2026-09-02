-------------------------- MODULE ConsultChain --------------------------
(***************************************************************************)
(* A TLA+ model of the "ONE lowering path per construct, or a loud reject"   *)
(* claim for WT's call-lowering CONSULT CHAIN: `compile_call!` in            *)
(* src/codegen/calls.jl:2235. dart2wasm dispatches every call node through a *)
(* chain of NULLABLE-RETURN funnels (intrinsics.dart :607/:685/:995/:1007/   *)
(* :1018 -- each funnel returns a lowering or `null`, "not mine, keep        *)
(* looking"); compile_call! is WT's version of that same chain, consulted    *)
(* strictly in PROGRAM ORDER, read here from the actual source (not an       *)
(* idealized textbook chain):                                                *)
(*                                                                           *)
(*   1. BUILTIN       -- the identity-keyed Core/Base registry               *)
(*                       (`_try_builtin_lowering!`, builtins.jl:44, called   *)
(*                       from calls.jl:2254 and again at :2308). Keyed on    *)
(*                       the CALLEE OBJECT's identity (an IdDict), not a     *)
(*                       Symbol -- e.g. `Core.getglobal`, `Core.:(===)`.     *)
(*                       Several of its entries (`_lower_getglobal_          *)
(*                       constfold!` builtins.jl:127, `_lower_egal_early!`   *)
(*                       builtins.jl:838) themselves decline for a SUBSET of *)
(*                       their callee's call shapes, by the SAME nullable-   *)
(*                       return convention, one level down.                  *)
(*   2. GETGLOBAL_ARM  -- `is_func(func, :getglobal)` typename special case, *)
(*                       calls.jl:2258-2270. Reachable ONLY because funnel 1 *)
(*                       already declined for this callee (an early `return` *)
(*                       fires on a BUILTIN hit, calls.jl:2254-2256).        *)
(*   3. TABLE          -- the five parity(intrinsics.dart:...) tables/       *)
(*                       registries, consulted back-to-back and folded into  *)
(*                       ONE funnel here since they share the identical      *)
(*                       nullable-return shape and sit in one unbroken run   *)
(*                       of the source (calls.jl:4021 binop table, :4063-    *)
(*                       :4086 unop table, :4092 Int128 registry, :4106      *)
(*                       Julia-numeric registry, :4126 conversions registry) *)
(*                       -- L104 (test/parity_ratchet.jl:1276) locks that no  *)
(*                       `is_func(func, :key)` ladder arm exists anywhere in  *)
(*                       codegen for any key these five own.                 *)
(*   4. EGAL_ARM       -- `is_func(func, :(===))` / `:(!==)` fallback arm,   *)
(*                       calls.jl:4180-4183, textually right after the       *)
(*                       conversions registry, matching the real order.      *)
(*   5. LATE_ARMS      -- the large remaining bucket: the rest of the        *)
(*                       `is_func` chain plus the generic/dynamic call path  *)
(*                       (getfield/getproperty variants, dynamic closure     *)
(*                       dispatch, apply-iterate reduce, ...), folded into    *)
(*                       one funnel -- none of THIS model's keys are its      *)
(*                       intended prey; it exists so the terminal REJECT is   *)
(*                       reached only after it declines, and so the Broken    *)
(*                       instance has somewhere to plant a stale ladder arm.  *)
(*   6. REJECT         -- the terminal: `record_unsupported!` + `unreachable!` *)
(*                       (calls.jl:5253-5261, "unknown function call (no      *)
(*                       handler arm)"). A loud, defined trap -- never a      *)
(*                       silent fall-through.                                 *)
(*                                                                           *)
(* ABSTRACTION. A "call key" is dart's (type, op) pair -- here a symbolic ID  *)
(* that already encodes both the Julia intrinsic/builtin name AND its arg-    *)
(* shape/width (e.g. "add_i64" is (I64,I64,:add_int); "not_int_bool" is       *)
(* :not_int applied to a Bool-valued operand, which routes BEFORE the unop    *)
(* table per calls.jl:4063). This collapses dart's two-dimensional (lhsType, *)
(* rhsType, op) key into one enumerated ID -- sufficient because every claim  *)
(* in this model is stated PER KEY, never about the internals of a type       *)
(* pairing, and TLC would explore the same state graph either way.            *)
(*                                                                           *)
(* Unlike SchedulerWake's race (several THREADS truly interleaving), a single *)
(* `compile_call!` invocation is straight-line, single-threaded code: there   *)
(* is no genuine concurrency to explore WITHIN one key's walk down the chain. *)
(* So each key's walk is evaluated as ONE atomic transition (`Walk`, a pure   *)
(* fold over the funnel order) rather than exposed as separate TLC-explored   *)
(* micro-steps -- nothing about the claims below depends on interleaving a    *)
(* key's own funnel-by-funnel consultation. The genuine degrees of freedom    *)
(* TLC explores are: WHICH key is processed next (order across keys is        *)
(* provably irrelevant, since keys share no state -- kept nondeterministic     *)
(* anyway so TLC actually explores it and confirms that), and the two         *)
(* CONSTANT bug flags below.                                                  *)
(*                                                                           *)
(* Two historical bug classes, both real (git log), are wired in as CONSTANT  *)
(* flags so the Broken instance rejects for a genuine reason:                 *)
(*                                                                           *)
(*   StaleArmBug      -- EXCLUSIVITY violation: a leftover `is_func` ladder   *)
(*                       arm coexists with a table entry for the SAME key.    *)
(*                       This is L104 (test/parity_ratchet.jl:1276) lifted    *)
(*                       from symbols to keys: "a table entry and an arm can   *)
(*                       never coexist, so a half-wired table cannot stall     *)
(*                       again (the M11 lesson)". The historical incident it   *)
(*                       mirrors is commits e1483400/416090ac: the F32        *)
(*                       copysign ladder arm was deleted assuming table        *)
(*                       coverage that didn't exist yet for that exact         *)
(*                       (type,type,op) row -- i.e. the table and its          *)
(*                       assumed-retired arm drifted out of sync. This model   *)
(*                       encodes the OTHER direction of that same drift (a     *)
(*                       stale arm added back alongside an EXISTING table      *)
(*                       row) because that is the one L104/EXCLUSIVITY can     *)
(*                       actually detect as "two funnels claim one key"; the   *)
(*                       missing-row direction produces a clean loud REJECT    *)
(*                       (a coverage regression, not a totality/exclusivity    *)
(*                       violation under the definitions below) and is         *)
(*                       covered by the differential oracle and the probe      *)
(*                       corpus instead (see 416090ac's commit message).       *)
(*   PartialEmissionBug -- NO-PARTIAL-EMISSION violation: TABLE emits its      *)
(*                       narrow-width normalisation prep (the real             *)
(*                       `_emit_normalise_narrow_pair!` call, calls.jl:4028-   *)
(*                       4034, which today runs strictly INSIDE the           *)
(*                       `haskey(INTRINSIC_BINOPS, ...)` hit) for EVERY key it *)
(*                       is asked about, including ones it goes on to         *)
(*                       decline -- mirroring the plausible refactor mistake   *)
(*                       of hoisting that prep above the `haskey` gate.        *)
(*                                                                           *)
(* Julia function this models: `compile_call!`, src/codegen/calls.jl:2235.    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    StaleArmBug,        \* BOOLEAN -- inject the L104-forbidden stale ladder arm
    PartialEmissionBug  \* BOOLEAN -- inject the hoisted-normalisation partial emit

----------------------------------------------------------------------------
(* Keys: representative call keys, grounded in real source symbols/shapes.   *)

HardTableKeys == {"add_i64", "copysign_f32", "not_int_bool", "ctlz_i32",
                   "int128_add", "checked_sadd", "sext_int"}
FallbackKeys  == {"getglobal_const", "getglobal_typename",
                   "egal_string", "egal_generic"}
Keys == HardTableKeys \cup FallbackKeys \cup {"unknown_call"}

Funnels == {"BUILTIN", "GETGLOBAL_ARM", "TABLE", "EGAL_ARM", "LATE_ARMS"}

(* Real program order (calls.jl: builtins funnel + its getglobal fallback    *)
(* run first at :2254-:2270, the five parity( tables at :4021-:4151, the     *)
(* egal fallback arm at :4180, everything else last before the terminal).    *)
RealOrder == <<"BUILTIN", "GETGLOBAL_ARM", "TABLE", "EGAL_ARM", "LATE_ARMS">>

(* An alternate order used ONLY to probe claim (4), order-independence -- it  *)
(* is never how the real compiler runs; it swaps EGAL_ARM ahead of BUILTIN.  *)
AltOrder == <<"EGAL_ARM", "BUILTIN", "GETGLOBAL_ARM", "TABLE", "LATE_ARMS">>

----------------------------------------------------------------------------
(* Each funnel's claimed keys, read from source:                             *)
(*  - BUILTIN claims "getglobal_const" (`_lower_getglobal_constfold!` hits    *)
(*    the isconst case, builtins.jl:134-139) and "egal_string"                *)
(*    (`_lower_egal_early!` hits the String/Symbol case, builtins.jl:843-852).*)
(*  - GETGLOBAL_ARM claims "getglobal_typename" -- a SPECIFIC, independently  *)
(*    discriminating guard (module_owner === name_owner, calls.jl:2261),      *)
(*    genuinely disjoint from BUILTIN's isconst case.                         *)
(*  - TABLE claims every HardTableKeys entry (its five registries between      *)
(*    them cover add/copysign/not_int-on-bool/ctlz/int128/checked/sext).      *)
(*  - EGAL_ARM's guard (calls.jl:4180/4183) is JUST `is_func(func,:(===))` /   *)
(*    `:(!==))` -- unconditional, with NO re-discrimination of the string/     *)
(*    typeof/nothing cases BUILTIN already special-cases. Read in isolation,  *)
(*    its predicate covers "egal_string" TOO, not only "egal_generic" -- it   *)
(*    is only ever reached for "egal_generic" in practice because BUILTIN     *)
(*    runs first and returns early on "egal_string" (calls.jl:2254-2256,      *)
(*    2308-2310). This is exactly the asymmetry claim (4) asks to surface.    *)
(*  - LATE_ARMS claims nothing among these keys, unless StaleArmBug adds the   *)
(*    forbidden extra claim on "copysign_f32".                                *)
BaseClaims(f) ==
    CASE f = "BUILTIN"       -> {"getglobal_const", "egal_string"}
      [] f = "GETGLOBAL_ARM" -> {"getglobal_typename"}
      [] f = "TABLE"         -> HardTableKeys
      [] f = "EGAL_ARM"      -> {"egal_string", "egal_generic"}
      [] f = "LATE_ARMS"     -> {}

Claims(f) ==
    IF f = "LATE_ARMS" /\ StaleArmBug
    THEN BaseClaims(f) \cup {"copysign_f32"}
    ELSE BaseClaims(f)

----------------------------------------------------------------------------
(* Walk(order, k, bad): fold the funnel `order` for key `k`, returning the    *)
(* terminal (the first claiming funnel, or "Reject" if none) and whether any  *)
(* DECLINING funnel emitted along the way ("bad" = a partial-emission         *)
(* violation). Mirrors dart's nullable-return funnel consult exactly:         *)
(* the first non-null result wins; every prior funnel MUST have returned      *)
(* null (declined) with no side effect for the fold to reach it.              *)
RECURSIVE Walk(_, _, _)
Walk(order, k, bad) ==
    IF order = <<>> THEN [term |-> "Reject", bad |-> bad]
    ELSE LET f == Head(order) IN
         IF k \in Claims(f)
         THEN [term |-> f, bad |-> bad]
         ELSE LET leaked == PartialEmissionBug /\ f = "TABLE"
              IN  Walk(Tail(order), k, bad \/ leaked)

TerminalOf(order, k)   == Walk(order, k, FALSE).term
BadPartialOf(order, k) == Walk(order, k, FALSE).bad

----------------------------------------------------------------------------
VARIABLES
    terminal,   \* [Keys -> Funnels \cup {"Reject", "Unset"}] -- this key's outcome
    badPartial  \* [Keys -> BOOLEAN] -- did a declining funnel emit for this key?

vars == <<terminal, badPartial>>

TypeOK ==
    /\ terminal   \in [Keys -> Funnels \cup {"Reject", "Unset"}]
    /\ badPartial \in [Keys -> BOOLEAN]

Init ==
    /\ terminal   = [k \in Keys |-> "Unset"]
    /\ badPartial = [k \in Keys |-> FALSE]

AllDone == \A k \in Keys : terminal[k] # "Unset"

(* Process one key's ENTIRE consult chain atomically -- see the header for    *)
(* why no interleaving is lost by doing so. *)
ProcessKey(k) ==
    /\ terminal[k] = "Unset"
    /\ terminal'   = [terminal   EXCEPT ![k] = TerminalOf(RealOrder, k)]
    /\ badPartial' = [badPartial EXCEPT ![k] = BadPartialOf(RealOrder, k)]

Next ==
    \/ \E k \in Keys : ProcessKey(k)
    \/ (AllDone /\ UNCHANGED vars)   \* nothing left to do; stutter (mirrors SchedulerWake's QueueEmpty)

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

----------------------------------------------------------------------------
(* Claims. *)

(* (1) TOTALITY, liveness half: every key eventually reaches SOME terminal. *)
EventuallyAllDone == <>AllDone

(* (1) TOTALITY, safety half / (3) NO PARTIAL EMISSION: a key that is still  *)
(* being (or was) processed never carries emitted bytes from a funnel that   *)
(* went on to decline -- a silent fall-through is exactly a key that reaches  *)
(* a terminal (Handled or Rejected) with stack bytes attributable to no one.  *)
NoPartialEmission == \A k \in Keys : ~badPartial[k]

(* (2) EXCLUSIVITY, the L104 lift: every HardTableKeys entry is claimed by AT  *)
(* MOST ONE funnel. Purely a fact about Claims/the CONSTANTS (true or false    *)
(* identically in every state) -- gated on AllDone anyway so TLC checks it as  *)
(* an ordinary per-state invariant (with a counterexample trace) rather than   *)
(* constant-folding it before state exploration starts, which reports a        *)
(* differently-worded, trace-less message that a text-matching harness like    *)
(* dev/formal/run_tlc.sh would not recognize as "Invariant ... is violated".   *)
(* StaleArmBug is the only thing that can break it, by design. *)
TableExclusivity ==
    AllDone =>
        \A k \in HardTableKeys : Cardinality({f \in Funnels : k \in Claims(f)}) <= 1

(* Sanity check that the REAL order resolves the FallbackKeys asymmetry       *)
(* correctly despite BUILTIN and EGAL_ARM's raw predicates overlapping on     *)
(* "egal_string" (see BaseClaims's header comment above). *)
CorrectFallbackResolution ==
    AllDone =>
        /\ terminal["getglobal_const"]    = "BUILTIN"
        /\ terminal["egal_string"]        = "BUILTIN"
        /\ terminal["getglobal_typename"] = "GETGLOBAL_ARM"
        /\ terminal["egal_generic"]       = "EGAL_ARM"

(* (4) ORDER-(IN)DEPENDENCE. Given EXCLUSIVITY, the terminal cannot depend on  *)
(* consult order -- trivially, since at most one funnel's predicate can ever   *)
(* match. TableOrderInvariance checks exactly that for the hard-exclusive      *)
(* class. But BUILTIN and EGAL_ARM are NOT mutually exclusive at the raw-      *)
(* predicate level on "egal_string" (EGAL_ARM's guard alone would also claim   *)
(* it) -- correctness for that key rests on program ORDER (BUILTIN first,      *)
(* returning early), not on disjoint predicates. OrderSensitivityWitness       *)
(* proves that dependency exists: under AltOrder (EGAL_ARM before BUILTIN),    *)
(* "egal_string" resolves to a DIFFERENT funnel than under RealOrder. This is  *)
(* the FINDING claim (4) asked this model to surface, made precise: L104's     *)
(* hard exclusivity governs the TABLE keys only; the BUILTIN/is_func-fallback  *)
(* pairing (getglobal, egal) is safe ONLY because of a program-order            *)
(* invariant that no lock currently checks.                                    *)
TableOrderInvariance ==
    AllDone =>
        \A k \in HardTableKeys : TerminalOf(RealOrder, k) = TerminalOf(AltOrder, k)

OrderSensitivityWitness ==
    AllDone => TerminalOf(RealOrder, "egal_string") # TerminalOf(AltOrder, "egal_string")

=============================================================================
