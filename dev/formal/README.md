# The formal layer

Model checking is the third enforcement layer beside the locks (syntactic, `test/parity_ratchet.jl`)
and the differential oracle (behavioral, native vs wasm). It exists for the claims neither of those
can exhaust — "for every CFG in the class", "under any discovery order", "no two selectors
collide" — the classes WasmTarget's real bugs lived in. The pattern is JuliaLang/julia's
`doc/src/devdocs/scheduler-wakeup/SchedulerWake.tla` (a TLA+ model of the scheduler wake handshake,
authored with Claude for #61826, checked by TLC over every interleaving); WasmTarget goes one step
further and gates on it.

## Files

| File | Role |
|---|---|
| `<Name>.tla` | the model of the ACTUAL Julia algorithm, read from source; its header says what is abstracted and why that suffices, names the modeled function, and cites the dart anchor (or the quarantine reason) |
| `MC<Name>.tla` / `MC<Name>.cfg` | a small instance: `TypeOK`, the claim invariants/properties, and TLC's deadlock check (on unless the cfg says `CHECK_DEADLOCK FALSE`; a run that ends gives its terminal states an explicit stutter in the model, e.g. `Terminal == done /\ UNCHANGED vars`) |
| `MC<Name>[Variant]Broken.cfg` | a variant TLC MUST reject: a deliberately wrong one (a CONSTANT flag mirroring a realistic bug class; a model no wrong variant can violate proves nothing), or a pinned open finding of the code itself (its header names the dev/MARCH.md row) |
| `run_tlc.sh` | runs every `MC*.cfg`; fails if a positive instance fails or a Broken one does not violate exactly the claim its first line names (`\* expect: <Invariant>`, checked on one worker so the first violation TLC reports is fixed; never `TypeOK`, which a Broken cfg must not name: it breaks a claim, not the type invariant); fetches TLC v1.7.4 to `~/.cache/wasmtarget` if absent |

The modeled Julia function carries a one-line `formal(dev/formal/<Name>.tla): <claim>` anchor —
inside its docstring when it has one (a comment line between a docstring and its definition
detaches the docstring; R35 counts those), otherwise as a `#` comment directly above it;
L111 keeps every model paired with its instance, a Broken variant, and an anchor. `formal.yml`
runs the harness on every push.

## Components

Every algorithmic component of `src/` — a fixpoint, a graph walk, a numbering, a proof the
compiler acts on — and the model that checks it. A row with no model names why. (C8's
proposed lock reads this table: each modeled function carries its `formal(` anchor, and every
anchor in `src/` has a row.)

| Component | Functions | Model |
|---|---|---|
| Stackifier, LLVM's (dev/LEDGER.md D42) | `sort_blocks` (src/llvm/cfg_sort.jl), `place_markers`, `place_loop_marker`, `place_block_marker`, `rewrite_depth_immediates` (src/llvm/cfg_stackify.jl), over Core.Compiler's CFG and dominator tree | CFGStackify |
| FixIrreducibleControlFlow, LLVM's (dev/LEDGER.md D42) | `process_region`, `make_single_entry_loop`, `calculate` (src/llvm/fix_irreducible_control_flow.jl), before CFGSort | FixIrreducible |
| ClassId numbering | `assign_type_ids!` (types.jl) | ClassIdDispatch |
| Selector table and dispatch guards | `build_dispatch_tables`, `emit_dispatch_wrappers!` (dispatch.jl), `fill_selector_table_elements!`, `_fit!` (selector_table.jl) | ClassIdDispatch |
| Closed world and its NIR | `check_subset`'s ccallable round, `_reached_ccallables` (subset.jl: Julia's trim inference answers the rest), `build_nir` (a record no body, a repeat asserted, one body per CodeInstance), `nir_code`, `_nir_stmt` (each statement at its position, a form outside the census rejected) (nir.jl) | NirHandoff |
| Closure layout | `register_closure_type!` (structs.jl), `build_closure_vtable!` (closures.jl) | ClosureLayout |
| Coercion funnel | `convert_type!` (the one widening check, read through `source_class`; `nothing` at every nullable reference of the any hierarchy its null, and never unboxed or cast), `_narrow_ref!`'s runtime-length tuple arm (values.jl) | Coercion |
| Constant interning | `ensure_constant_global!` (types.jl) | Constants |
| Call consult chain | `compile_call!` (calls.jl) | ConsultChain |
| Fatal/trap resolution | `record_unsupported!` (diagnostics.jl) | Diagnostics |
| Closed-world classes | `closed_world_classes`, `_meet_value!`, `_meet_class!` (classes.jl: every class a value can have, once, its supertype and its fields' classes with it), read by class_info.jl's numbering | ValueClasses |
| Record layout | `RecordShape`, `RecordShape_from_type`, `==`, `get_name_index`, `get_positional_index` (records.jl: a name's index its declared place, == exactly when the indices agree, an open tuple type rejected) | RecordLayout |
| Late final cells | `Late{T}`, `_late_get`, `_late_set!` (late.jl: assigned once or initialized on the first read, a cycle and a misuse rejected, an unassigned read Unported) | LateCell |
| Constant cache keys | `_bounded_hash`, `Base.hash(::NirConst)` (nir.jl) | ConstantHash |
| Box contents join | `box_contents_type` (box_capture.jl) | BoxJoin |
| Box-derived value types | `f3_box_value_types` (box_capture.jl) | BoxValueTypes |
| Numeric accumulator types | `propagate_numeric_value_types` (box_capture.jl) | NumericJoin |
| Storage-relative pointers | `_storage_relative_pointer_is_closed`, `_trace_memmove_ptr` (statements.jl) | StoragePointer |
| Dead-statement proof | `stmt_is_proven_unreachable` (generate.jl) over the one CFG, `nir_cfg` (nir.jl: Julia's compute_basic_blocks, an Enter's catch edge included) | ProvenDead |
| Definite initialization of a partial `%new` | `_definitely_initializes_in_nir` (statements.jl), its successors the one CFG's (`nir_cfg`) | DefiniteInit |
| Native sidecar protocol | — (WT1's test/sidecar retired with the rebuild; re-ported with the host imports, dev/MARCH.md 1.F) | Sidecar |
| Captured-variable types | `record_capture_contents` (a write through any operand carrying the captor joins its box, a constant included, a nested captor's field the field it was built from), `capture_read_types` (box_capture.jl) | CaptureType |
| `#undef` in a pointer slot | `pointer_slot`, `field_may_be_undef`, `undef_slot`, `pointer_slot_admits_nothing`, `undef_slot_storage` (read by `get_array_type!`, types.jl, and `_struct_fields!`, structs.jl), `undef_value_global!`, `emit_undef!`, `emit_is_undef!`, `emit_is_unset!`, `emit_undef_read_check!`, `emit_slots_undef_check!`, `emit_new_slots!`, `_emit_field_undef_check!` (undef.jl), `emit_constant_slots!` (a constant's slots, values.jl), read by memorynew, memoryrefget, memoryref_isassigned, the slot unset, a Box's contents read (builtins.jl), a partial `%new` (statements.jl), a field read by a run-time name, isdefined and a splat's copy (calls.jl) | Undef |
| Inline classId switch | `_try_inline_typeid_dispatch`, `_emit_switch_methoderror!`, `_emit_throw_methoderror_by_class!` (calls.jl), `_emit_closure_arg_tests!`, `_closure_dispatch_trampoline!`, `_closure_trampoline!`, `_emit_trampoline_methoderror!` (closures.jl), `bare_array_partition` (builtins.jl), the no-method args tuples: `_dynamic_dispatch_candidate_mis`'s recorded per callee on the plan (`no_method`) from the one consult (`wt_method_matches`, `wt_method_which`); `methoderror_args_types`'s over the one class set (`_collect_reachable_ir_types` reading `closed_world_class_list`) (trimcollect.jl) | ClassIdSwitch |
| `:invoke` callee | `compile_invoke!` (invoke.jl) | — one lookup by MethodInstance (`get_function_by_mi`), no algorithm |
| Dynamic-call enrollment and row order | `_dynamic_dispatch_candidate_mis`, the one class set `closed_world_classes` (a vararg method's packed tuple observed from its slot, SlotsObserved) and its walk of the held constants `hold!`, the one match rule `_match_is_one_signature`, the one bound `_candidate_product` (trimcollect.jl), `_most_specific_first`, `ambiguous_class_tuple` (closures.jl), the vtable pre-pass's invoke-only and ambiguity rules (compile.jl) | Enrollment |
| Type identity under iso-recursive canonicalization | `add_type!`, `add_type_group!`, `_group_member_equal` (instructions.jl), `finish_pending!` (structs.jl) | TypeIdentity |
| `===` over representations | `emit_egal!`, `get_egal_function!`, `fill_egal_function!`, `_egal_body` (calls.jl) | EgalDispatch |
| Recursive type groups | `begin_pending!`, `finish_pending!` (structs.jl), `recursion_groups`, `add_type_group!` (instructions.jl) | RecGroup |
| Builder operand stack and control frames | `InstrBuilder`, `_emit!`, `_br_depth!` (instr_builder.jl), `validate_block_end!`, `validate_branch_types!` (validator.jl) | OperandStack |
| Local initialization | `local_get!`, `local_set!`, `local_tee!`, the reset at `end_block!`, `else_!` and `catch_legacy!`, `append_builder!`'s replay (instr_builder.jl) | LocalInit |
| Int128 over i64 limbs | `emit_int128_*`, `get_u128_divrem_function!` (int128.jl) | Int128Limbs |
| Julia's exception stack | `emit_throw_value!`, `emit_rethrow!`, `emit_current_exception!`, `exc_saved_local!`, `emit_export_entry!` (a prologue), `emit_direct_call!` (the slot save and restore around a host-declared import call), `host_glue_js` (the count, the host's) (generate.jl), the one-time export of each function in `_compile_closed_world_plan` (compile.jl), a region's enter and pop_exception (statements.jl), the catch landing (stackified.jl) | ExceptionStack |
| SSA stack residency | `allocate_ssa_locals!`, `needs_local` (context.jl) | — no claim to check: every SSA a statement reads gets a local |
| Cast-result refinement | `refine_checked_cast_types!` (context.jl) | — no fixpoint: one local rule per statement |
| `isa` and typeassert lowering | `_compile_call_isa` (calls.jl) | — a per-statement port of emit_isa's case order (cgutils.cpp), not an algorithm |
| Concrete-evaluation rule | interpreter.jl | — a per-function predicate list (C3), not an algorithm |
| Value-type subtyping | `wasm_subtype` (builder/types.jl) | — a per-type rule, type.dart isSubtypeOf; test_wasm_subtype_lattice.jl |
| Closed-world binding lookups | `_closed_world_type_bounds`, `_closed_world_isvisible` (interpreter.jl) | — a walk down one binding's partitions or import chain to its end; no fixpoint |
| Array element offset and MemoryRef snapshots | `array_offset_field_idx` (structs.jl), `_memoryref_operand_is_fixed`, `allocate_memoryref_offset_locals!` (builtins.jl) | StorageRef |
| LEB128 and source-map VLQ encoders | `encode_leb128_unsigned` (writer.jl), `_encode_vlq!` (builder/source_map.jl) | — encodings; wasm-tools parses every module |
| Export names | `plan_function_names!`, `julia_function_name` (trimcollect.jl), `ExportNamer`, `export_name!`, `generated_export_name!` (compile.jl) | — no fixpoint: a function's name is its signature, one rule per function (the less specific of two methods over one specialization suffixed by `morespecific`), and each export name is taken once or refused; test/generated_names.jl "a compiled function is named by its signature", test/real_bottom_exceptions.jl "each export is made once" |
| Source-map JSON reader | `_json_read`, `_json_value`, `_json_skip` and the readers below them (builder/source_map.jl) | — a recursive-descent recognizer of JSON's grammar (RFC 8259) with no state beyond its position; test/source_maps.jl "the map's JSON reader refuses what JSON does not allow" |

## Rules

- A change to a modeled algorithm updates the model FIRST and lands with TLC green.
- A new protocol or algorithm is modeled spec-first; the code is checked against the model.
- A TLC counterexample against the real algorithm is a finding: reproduce it in Julia, fix the
  algorithm, keep the invariant. Never weaken an invariant to make TLC pass. (ConsultChain → L113;
  ClassIdDispatch → the dispatch guards.)
- Keep instances small enough for CI (seconds to a couple of minutes). If exhaustive enumeration at
  the size that contains a witness is intractable, the Broken instance uses a fixed witness CFG and
  the positive instance stays exhaustive at the tractable size (CFGStackify: N=4 in the gate, every
  Broken instance at N=4 too).
- Commit messages for algorithmic fixes narrate the protocol: the exact shape that breaks, the
  invariant, and why the fix restores it.

## Nightly

`formal.yml` also runs on a schedule with `TLC_NIGHTLY=1` and a 5-hour budget: the harness then
adds `dev/formal/nightly/MC*.cfg` — instances too large for the 20-minute gate, checked against
the same model modules (a `nightly/MCCFGStackifyN5.cfg` would check its own `MCCFGStackifyN5.tla` at N=5).
Nothing lives there yet: every current instance fits the gate. Add one only when it terminates
in the budget on a 2-core runner — a job that never finishes proves nothing either.

## Running

```
bash dev/formal/run_tlc.sh            # every instance
TLC_WORKERS=auto bash dev/formal/run_tlc.sh
java -cp ~/.cache/wasmtarget/tla2tools.jar tlc2.TLC -workers auto -config MCCFGStackify.cfg MCCFGStackify.tla
```
