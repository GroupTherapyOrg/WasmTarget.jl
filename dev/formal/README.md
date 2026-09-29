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
| `MC<Name>.tla` / `MC<Name>.cfg` | a small instance: `TypeOK`, the claim invariants/properties, a deadlock check |
| `MC<Name>[Variant]Broken.cfg` | a deliberately wrong variant (a CONSTANT flag mirroring a realistic bug class) that TLC MUST reject — a model no wrong variant can violate proves nothing |
| `run_tlc.sh` | runs every `MC*.cfg`; fails if a Broken instance passes or a positive one fails; fetches TLC v1.7.4 to `~/.cache/wasmtarget` if absent |

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
| Stackifier | `generate_stackified_flow!`, `generate_stackified_flow`, `_thread_backward_trampolines!`, `emit_duplicated_terminal!` (stackified.jl) | Stackifier |
| ClassId numbering | `assign_type_ids!` (types.jl) | ClassIdDispatch |
| Selector table and dispatch guards | `build_dispatch_tables`, `emit_dispatch_wrappers!` (dispatch.jl), `fill_selector_table_elements!`, `_fit!` (selector_table.jl) | ClassIdDispatch |
| Closed-world collection | `collect_closed_world`, `collect_new_pairs!`, `_missing_explicit_invoke_mis`, `_dynamic_dispatch_candidate_mis`, `_builtin_call_edge_mi`, `_prune_external_leaf_subgraphs` (trimcollect.jl) | ClosedWorld |
| Closure layout | `register_closure_type!` (structs.jl), `build_closure_vtable!` (closures.jl) | ClosureLayout |
| Coercion funnel | `convert_type!` (values.jl) | Coercion |
| Constant interning | `ensure_constant_global!` (types.jl) | Constants |
| Call consult chain | `compile_call!` (calls.jl) | ConsultChain |
| Fatal/trap resolution | `record_unsupported!` (diagnostics.jl) | Diagnostics |
| NIR boundary | `build_nir` (nir.jl) | NirBuild |
| Box contents join | `box_contents_type` (box_capture.jl) | BoxJoin |
| Box-derived value types | `f3_box_value_types` (box_capture.jl) | BoxValueTypes |
| Numeric accumulator types | `propagate_numeric_value_types` (box_capture.jl) | NumericJoin |
| Storage-relative pointers | `_storage_relative_pointer_is_closed`, `_trace_memmove_ptr` (statements.jl) | StoragePointer |
| Dead-statement proof | `stmt_is_proven_unreachable`, `analyze_blocks` (generate.jl) | ProvenDead |
| Definite initialization of a partial `%new` | `_definitely_initializes_in_nir` (statements.jl) | DefiniteInit |
| Native sidecar protocol | test/sidecar | Sidecar |
| Captured-variable types | `record_capture_contents`, `capture_read_types` (box_capture.jl) | CaptureType |
| External-leaf pruning | `_prune_external_leaf_subgraphs` (trimcollect.jl) | InvokePrune |
| Inline classId switch | `_try_inline_typeid_dispatch` (calls.jl), `_closure_dispatch_trampoline!` (closures.jl) | ClassIdSwitch |
| `===` over representations | `emit_egal!`, `get_egal_function!` (calls.jl) | EgalDispatch |
| Recursive type groups | `begin_pending!`, `finish_pending!` (structs.jl), `recursion_groups`, `add_type_group!` (instructions.jl) | RecGroup |
| Builder operand stack and control frames | `InstrBuilder` (instr_builder.jl), `validate_block_end!`, `validate_br!` (validator.jl) | OperandStack |
| Int128 over i64 limbs | `emit_int128_*`, `get_u128_divrem_function!` (int128.jl) | Int128Limbs |
| SSA stack residency | `allocate_ssa_locals!`, `needs_local` (context.jl) | — no claim to check: every SSA a statement reads gets a local |
| Cast-result refinement | `refine_checked_cast_types!` (context.jl) | — no fixpoint: one local rule per statement |
| Concrete-evaluation rule | interpreter.jl | — a per-function predicate list (C3), not an algorithm |
| Closed-world binding lookups | `_closed_world_type_bounds`, `_closed_world_isvisible` (interpreter.jl) | — a walk down one binding's partitions or import chain to its end; no fixpoint |
| Array element offset and MemoryRef snapshots | `array_offset_field_idx` (structs.jl), `_memoryref_operand_is_fixed`, `allocate_memoryref_offset_locals!` (builtins.jl) | StorageRef |
| LEB128 and source-map VLQ encoders | `encode_leb128_unsigned` (writer.jl), `vlq_encode` (sourcemap.jl) | — encodings; wasm-tools parses every module |

## Rules

- A change to a modeled algorithm updates the model FIRST and lands with TLC green.
- A new protocol or algorithm is modeled spec-first; the code is checked against the model.
- A TLC counterexample against the real algorithm is a finding: reproduce it in Julia, fix the
  algorithm, keep the invariant. Never weaken an invariant to make TLC pass. (ConsultChain → L113;
  ClassIdDispatch → the dispatch guards; Stackifier's Broken instances are the `b9f4d229` miscompile
  and the `8424acd3` dropped phi store.)
- Keep instances small enough for CI (seconds to a couple of minutes). If exhaustive enumeration at
  the size that contains a witness is intractable, the Broken instance uses a fixed witness CFG and
  the positive instance stays exhaustive at the tractable size (Stackifier: N=4 exhaustive; N=5 is
  not CI-tractable).
- Commit messages for algorithmic fixes narrate the protocol: the exact shape that breaks, the
  invariant, and why the fix restores it.

## Nightly

`formal.yml` also runs on a schedule with `TLC_NIGHTLY=1` and a 5-hour budget: the harness then
adds `dev/formal/nightly/MC*.cfg` — instances too large for the 20-minute gate, checked against
the same model modules (a `nightly/MCStackifierN5.cfg` would check `MCStackifier.tla` at N=5).
Nothing lives there yet: every current instance fits the gate. Add one only when it terminates
in the budget on a 2-core runner — a job that never finishes proves nothing either.

## Running

```
bash dev/formal/run_tlc.sh            # every instance
WORKERS=auto bash dev/formal/run_tlc.sh
java -cp ~/.cache/wasmtarget/tla2tools.jar tlc2.TLC -workers auto -config MCStackifier.cfg -deadlock MCStackifier.tla
```
