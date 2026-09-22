# The plan — open work only

`dev/CHARTER.md` defines done; this file lists the work still open against it and nothing
else. When an item closes, the commit that closes it deletes its row here and adds one line to
`dev/HISTORY.md`; results, counts and narrative live in commit messages and in the ratchet's
output, not here (L129 keeps this file short and free of finished work).

## Phase 13 — close the charter

The plan is derived from `dev/CHARTER.md`'s open clauses and four read-only audits of every
definition in `src/` against dart2wasm `898a1e4b` (tables kept outside the repo; each row names
a dart anchor or the reason there is none): 1,237 definitions — DART 367, QUARANTINE 396,
INVENTION 450, DEAD? 26 (per area: call lowering 190 rows / 55 INVENTION, values+types 239 /
65, driver+analyses 570 / 281 — 124 of them overlays in interpreter.jl, builder 240 / 49). The
floor audit classified all 252 sites of R3 R5 R7 R14 R15 R17 R27: 172 DEBT, 78 legitimate,
2 unsure. Order: soundness first, then one path, then dart structure, then strictness.
Every item lands on a `march/*` branch with its clause in the `Charter:` trailer.

| # | Clause | Work | Exit (measured) |
|---|---|---|---|
| 13.0 | C1 C6 | land the stack: D stage 1 → stage 2 → located chains → D stage 3 (calls/invoke/compile/context onto the NIR; delete `nir_operand`, `_ctx_ir`, `NirStmt.raw`, the context's `code_info`; one callee resolution incl. the singleton-Argument rule now in both calls.jl and trimcollect.jl) | R29a = R29b = 0 → locks |
| 13.1 | C6 | reproduce every silent-wrong-value suspect the audits found by reading (27 classes: mixed-width and float `===`, String/Symbol identity, per-use rebuilt mutable constants, non-ASCII `length`/`nextind`/`SubString`/`first`, `fill!` with a runtime value, `bswap` of narrow ints, `fma` as two roundings, narrow → Int128 sign extension, `Bool+Bool`, exception payloads of `_throw_argerror`/`throw_boundserror`/`_tuple_error`, `truncate`, `setfield!` on an unregistered `RefValue`, `unalias`, `memoryrefoffset` from an argument); fix each confirmed one at its root with its smoke case first | every confirmed suspect has a smoke case and is green; `test/soundness_suspects.jl` classifies all |
| 13.2 | C6 | the 52 silent catches: rethrow, reject located, or an exact allowlist for handlers on the diagnostic path itself | R34 = 0 → lock |
| 13.3 | C5 C3 | cases for the 116 unexercised registry entries; each bespoke `INVOKE_INTRINSICS` / `STANDALONE_INTRINSIC_BODIES` lowering (0 of 36 reached by any case) is deleted when Julia's body compiles, or kept with its reason | R33 = 0 → lock; C3's planned check replaced by a lock |
| 13.4 | C1 C9 | one mechanism per fact, from the audits: `===`/`!==` → dart's `identical` (three cases, intrinsics.dart:1409) instead of two disagreeing ladders; one representation of `nothing`; one struct-field translation (class_info.dart:539 `_generateFields` → translateStorageType) instead of four copies, and dart's define-then-fill for recursive types instead of placeholder-and-patch; one width classifier; one GlobalRef resolution at the boundary; one numeric-box tail (convertType); one operator table; the callee from the `:invoke`'s MethodInstance instead of fuzzy `get_function` matching; WT's re-inference beside Julia's deleted (`infer_call_type`, `analyze_ssa_types!` overriding inference); one CFG; one export namer | per item a lock; R3 → 0 with `infer_value_type` deleted |
| 13.5 | C9 | the floor ratchets per the floor audit: R5 → exact allowlist of its 20 declaring sites (locals, signature, array element, box field, is-test targets); R7 and R27 (duplicates) → one exact allowlist of 26 sites; R14's metric restated (`struct_new!` inside the constant path) → 0 via one lazy global per mutable constant (constants.dart:147); R15 → 0 (every long literal pre-registered); R17 → 0 (`emit_memoryref_pair!`) | each ratchet 0 or an exact allowlist lock |
| 13.6 | C2 | anchors: a lock that every cited dart `file:line` exists at the pinned commit and names its symbol (CI fetches the pinned sources; a missing checkout fails); the anchors the audits judged wrong corrected; every definition anchored from the audit tables — builder first, then files stage 3 does not touch | R32 = 0 → lock; the resolve lock at 0 |
| 13.7 | C2 C3 | the inventions without a Julia necessity, restructured or deleted: the 124 overlays in interpreter.jl each deleted (Julia's body compiles) or quarantined with its differential proof; `cache.jl` (key omits `optimize`, export names, kwargs); process-global side channels → per-compilation state; bypasses of closed-world collection (compile.jl:810, WasmTarget.jl:224); the name-keyed println/print/show pre-scan (compile.jl ~390); runtime type objects materialised on demand, not one global and hierarchy row per numbered type (dart: types.dart makeType / constants.dart ensureConstant) | INVENTION count in a re-run audit → 0 |
| 13.8 | C4 | return types on every definition; no `Any` field outside named seams | R30 = R31 = 0 → locks |
| 13.9 | C8 | the list of algorithmic components, each mapped to its model; a model for any unmapped one | C8's planned check replaced by a lock |
| 13.10 | — | capability gaps (need a clause decision before they start): H(1) SimpleATsit5 (`march/p12H-atsit5`, ungated), H(3) `:invoke_modify`, H(5) two-position dispatch, erased multi-method callables | per gap a smoke case |
| 13.12 | C9 | the repository clean outside `src/`: 257 committed fuzz gap files (most `status: fixed`) and nine finished-campaign plans in `test/fuzz/`; `dev/PARITY_MASTER.md` and `dev/CERTIFICATION.md` (July, pre-charter) folded into the charter or regenerated at K; `dev/run_full_gate.sh`, `dev/migration_baseline.txt` checked for a consumer; then C9's liveness check as a lock | C9's planned check replaced by a lock at 0 |
| 13.11 | all | K: the charter's status block all CLOSED on the head CI tested green; release notes; merge; tag | every clause CLOSED |
