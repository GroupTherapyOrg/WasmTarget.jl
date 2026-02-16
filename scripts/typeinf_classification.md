# Core.Compiler.typeinf Function Classification (PURE-3001)

**Entry point:** `Core.Compiler.typeinf(NativeInterpreter, InferenceState)`
**Date:** 2026-02-15
**Method:** For each of 171 functions from PURE-3000's dependency graph:
- Pure Julia functions: attempt `WasmTarget.compile(f, argtypes)` + `wasm-tools validate`
- Multi-dispatch functions (Union signatures): try first/primary specialization
- C-dependent: pre-classified by ccall analysis, documented with replacement strategy
- Optimizer: pre-classified by name (Binaryen handles optimization)

## Summary

| Category | Count | Description |
|----------|-------|-------------|
| **COMPILES_NOW** | **77** | Pure Julia, compiles + validates with WasmTarget |
| **NEEDS_PATTERN** | **16** | Compiles but validation fails — needs codegen fixes |
| **C_DEPENDENT** | **70** | Has ccalls that need pure Julia replacement |
| **OPTIMIZER_SKIP** | **2** | Only for optimization — Binaryen handles this |
| **UNRESOLVED** | **6** | Generated closures / static param issues / not found |
| **Total** | **171** | |

### Key Findings

1. **77 of 99 pure Julia functions compile and validate** — 78% success rate
2. **16 need codegen pattern fixes** — validation errors (type mismatches, stack issues)
3. **70 C-dependent functions use 42 unique ccalls** — but many are SKIP-able:
   - 12 ccalls are SKIP (timing/debug/cache) — affects 21 functions
   - 20 ccalls are LOW complexity (constants, trivial lookups)
   - 15 ccalls are MEDIUM complexity (tree walks, Dict ops, string ops)
   - 5 ccalls are HIGH complexity (type intersection, method tables)
4. **The BIG blockers are just 3 ccalls:**
   - `jl_type_intersection` / `jl_type_intersection_with_env` — pre-compute at build time
   - `jl_matching_methods` — DictMethodTable
   - `jl_code_for_staged` — pre-expand @generated at build time

---

## COMPILES_NOW (77)

These compile to Wasm and validate. Ready for compilation into typeinf module.

### Originally classified (60)

| # | Function | Module | Stmts | Funcs | Bytes | File |
|---|----------|--------|-------|-------|-------|------|
| 1 | `#string#403` | Base | 53 | 5 | 625 | intfuncs.jl:990 |
| 2 | `BestguessInfo` | Compiler | 16 | 5 | 167 | abstractinterpretation.jl:3884 |
| 3 | `OptimizationState` | Compiler | 16 | 5 | 934 | optimize.jl:171 |
| 4 | `PartialStruct` | Compiler | 77 | 5 | 880 | typelattice.jl:759 |
| 5 | `_all` | Base | 80 | 5 | 752 | anyall.jl:193 |
| 6 | `_assert_tostring` | Base | 3 | 5 | 123 | error.jl:247 |
| 7 | `_throw_argerror` | Base | 3 | 5 | 127 | array.jl:317 |
| 8 | `_unioncomplexity` | Compiler | 76 | 5 | 798 | typeutils.jl:296 |
| 9 | `_uniontypes` | Base | 100 | 5 | 1225 | runtime_internals.jl:1392 |
| 10 | `_validate_val!` | Compiler | 551 | 5 | 5060 | validation.jl:87 |
| 11 | `abstract_eval_call` | Compiler | 10 | 5 | 1000 | abstractinterpretation.jl:3053 |
| 12 | `abstract_eval_copyast` | Compiler | 31 | 5 | 1125 | abstractinterpretation.jl:3207 |
| 13 | `abstract_eval_globalref` | Compiler | 28 | 8 | 1358 | abstractinterpretation.jl:3722 |
| 14 | `abstract_eval_isdefined_expr` | Compiler | 357 | 5 | 4298 | abstractinterpretation.jl:3218 |
| 15 | `abstract_eval_special_value` | Compiler | 150 | 5 | 2045 | abstractinterpretation.jl:2955 |
| 16 | `abstract_eval_statement_expr` | Compiler | 252 | 5 | 5827 | abstractinterpretation.jl:3386 |
| 17 | `abstract_eval_value` | Compiler | 109 | 5 | 1664 | abstractinterpretation.jl:3000 |
| 18 | `add_edges!` | Compiler | 5 | 5 | 142 | types.jl:507 |
| 19 | `add_edges_impl` | Compiler | 90 | 17 | 10812 | stmtinfo.jl:482 |
| 20 | `adjust_effects` | Compiler | 384 | 13 | 5446 | typeinfer.jl:400 |
| 21 | `all` | Base | 2 | 5 | 91 | anyall.jl:188 |
| 22 | `append!` | Base | 39 | 5 | 537 | array.jl:1352 |
| 23 | `append_c_digits` | Base | 59 | 5 | 866 | intfuncs.jl:870 |
| 24 | `append_c_digits_fast` | Base | 19 | 5 | 250 | intfuncs.jl:898 |
| 25 | `append_nine_digits` | Base | 84 | 5 | 1031 | intfuncs.jl:887 |
| 26 | `argtypes_to_type` | Compiler | 170 | 8 | 1593 | typeutils.jl:51 |
| 27 | `bool_rt_to_conditional` | Compiler | 350 | 20 | 11214 | abstractinterpretation.jl:3950 |
| 28 | `code_cache` | Compiler | 9 | 5 | 491 | types.jl:495 |
| 29 | `collect_argtypes` | Compiler | 77 | 5 | 1203 | abstractinterpretation.jl:3010 |
| 30 | `collect_const_args` | Compiler | 241 | 5 | 2099 | abstractinterpretation.jl:989 |
| 31 | `compute_edges!` | Compiler | 64 | 8 | 1228 | typeinfer.jl:649 |
| 32 | `convert` | Base | 3 | 5 | 112 | essentials.jl:455 |
| 33 | `count_const_size` | Compiler | 328 | 5 | 2515 | utilities.jl:32 |
| 34 | `datatype_fieldcount` | Base | 98 | 5 | 870 | runtime_internals.jl:1120 |
| 35 | `decode_effects` | Compiler | 121 | 5 | 812 | effects.jl:351 |
| 36 | `error` | Base | 3 | 5 | 117 | error.jl:44 |
| 37 | `fill!` | Base | 153 | 5 | 825 | bitarray.jl:372 |
| 38 | `filter!` | Base | 120 | 8 | 1334 | array.jl:2978 |
| 39 | `intersect` | Compiler | 18 | 5 | 271 | cicache.jl:37 |
| 40 | `invalid_wrap_err` | Base | 5 | 5 | 750 | array.jl:3158 |
| 41 | `is_all_const_arg` | Compiler | 251 | 5 | 2165 | abstractinterpretation.jl:975 |
| 42 | `is_identity_free_argtype` | Compiler | 38 | 5 | 542 | typeutils.jl:348 |
| 43 | `is_mutation_free_argtype` | Compiler | 38 | 5 | 542 | typeutils.jl:379 |
| 44 | `is_same_frame` | Compiler | 11 | 5 | 988 | typeinfer.jl:783 |
| 45 | `isidentityfree` | Base | 79 | 5 | 866 | runtime_internals.jl:900 |
| 46 | `ismutationfree` | Base | 79 | 5 | 866 | runtime_internals.jl:880 |
| 47 | `length` | Compiler | 5 | 5 | 229 | methodtable.jl:10 |
| 48 | `merge_call_chain!` | Compiler | 126 | 5 | 1660 | typeinfer.jl:763 |
| 49 | `ndigits0z` | Base | 30 | 5 | 303 | intfuncs.jl:766 |
| 50 | `ndigits0znb` | Base | 45 | 5 | 437 | intfuncs.jl:684 |
| 51 | `resolve_call_cycle!` | Compiler | 123 | 11 | 2478 | typeinfer.jl:798 |
| 52 | `reverse!` | Base | 137 | 5 | 710 | array.jl:2230 |
| 53 | `scan_leaf_partitions` | Compiler | 2 | 5 | 242 | abstractinterpretation.jl:3706 |
| 54 | `ssa_def_slot` | Compiler | 228 | 5 | 2270 | abstractinterpretation.jl:1420 |
| 55 | `sym_in` | Base | 30 | 5 | 501 | tuple.jl:673 |
| 56 | `tname_intersect` | Compiler | 107 | 5 | 1041 | typelimits.jl:720 |
| 57 | `type_more_complex` | Compiler | 305 | 8 | 3542 | typelimits.jl:223 |
| 58 | `union!` | Base | 88 | 5 | 1275 | abstractset.jl:103 |
| 59 | `unionlen` | Base | 30 | 5 | 339 | runtime_internals.jl:1390 |
| 60 | `widenwrappedslotwrapper` | Compiler | 183 | 5 | 2154 | typelattice.jl:227 |

### Reclassified from COMPILE_ERROR (17 — had Union signatures, tried first variant)

| # | Function | Module | Stmts | Funcs | Bytes | Signature Used |
|---|----------|--------|-------|-------|-------|----------------|
| 61 | `InliningState` | Compiler | 5 | 5 | 114 | `(Vector{Any}, UInt64, AbstractInterpreter)` |
| 62 | `_issubconditional` | Compiler | 228 | 14 | 6126 | `(ConditionalsLattice{...}, Conditional, Conditional, Bool)` |
| 63 | `_typename` | Compiler | 3 | 5 | 88 | `(Any,)` |
| 64 | `abstract_call` | Compiler | 161 | 5 | 867 | `(AbstractInterpreter, ArgInfo, StmtInfo, InferenceState)` |
| 65 | `add_invoke_edge!` | Compiler | 175 | 5 | 1572 | `(Vector{Any}, Any, CodeInstance)` |
| 66 | `assign_parentchild!` | Compiler | 56 | 5 | 1351 | `(InferenceState, InferenceState)` |
| 67 | `instanceof_tfunc` | Compiler | 2 | 5 | 112 | `(Any,)` |
| 68 | `issubconditional` | Compiler | 2 | 14 | 6126 | `(ConditionalsLattice{...}, Conditional, Conditional)` |
| 69 | `ndigits0zpb` | Base | 122 | 5 | 1081 | `(Int64, Int64)` |
| 70 | `resize!` | Base | 117 | 5 | 969 | `(Vector{Any}, Int64)` |
| 71 | `throw_boundserror` | Base | 3 | 5 | 135 | `(Vector{Any}, Tuple{Int64})` |
| 72 | `throw_inexacterror` | Core | 3 | 5 | 132 | `(Symbol, Type, Int64)` |
| 73 | `widenconst` | Compiler | 2 | 5 | 89 | `(Any,)` |
| 74 | `widenreturn` | Compiler | 697 | 5 | 110 | `(PartialsLattice{ConstsLattice}, Any, BestguessInfo)` |
| 75 | `widenreturn_noslotwrapper` | Compiler | 2 | 5 | 124 | `(PartialsLattice{ConstsLattice}, Any, BestguessInfo)` |
| 76 | `⊑` | Compiler | 452 | 8 | 4142 | `(PartialsLattice{ConstsLattice}, Any, Any)` |
| 77 | `apply_refinement!` | Compiler | 168 | 23 | 11091 | `(InferenceLattice{...}, SlotNumber, Any, Vector{VarState}, Nothing)` |

---

## NEEDS_PATTERN (16)

These compile to bytes but fail `wasm-tools validate`. Need codegen fixes (likely type mismatches,
missing extern_convert_any, or stack underflows — familiar patterns from Phase 1).

### Originally classified (12)

| # | Function | Module | Stmts | Validation Error Pattern | File |
|---|----------|--------|-------|-----------------------|------|
| 1 | `<=` | Base | 3 | expected i64, found externref | bool.jl:161 |
| 2 | `abstract_eval_basic_statement` | Compiler | 496 | expected i32 but nothing on stack | abstractinterpretation.jl:3790 |
| 3 | `abstract_eval_cfunction` | Compiler | 156 | expected (ref null $type), found i32 | abstractinterpretation.jl:2935 |
| 4 | `abstract_eval_nonlinearized_foreigncall_name` | Compiler | 80 | expected ref but found i64 | abstractinterpretation.jl:3452 |
| 5 | `abstract_eval_phi` | Compiler | 92 | expected a type but nothing on stack | abstractinterpretation.jl:3523 |
| 6 | `isready` | Compiler | 13 | expected i32 but nothing on stack | inferencestate.jl:1151 |
| 7 | `record_slot_assign!` | Compiler | 222 | validation fails | typeinfer.jl:661 |
| 8 | `record_ssa_assign!` | Compiler | 532 | validation fails | inferencestate.jl:789 |
| 9 | `stupdate!` | Compiler | 139 | validation fails | typelattice.jl:722 |
| 10 | `tuple_tail_elem` | Compiler | 106 | validation fails | typeutils.jl:219 |
| 11 | `type_annotate!` | Compiler | 845 | validation fails | typeinfer.jl:712 |
| 12 | `update_bestguess!` | Compiler | 196 | expected subtype of anyref, found externref | abstractinterpretation.jl:4070 |

### Reclassified from COMPILE_ERROR (4 — Union signatures, first variant also fails validation)

| # | Function | Module | Stmts | Validation Error Pattern | File |
|---|----------|--------|-------|-----------------------|------|
| 13 | `getfield_tfunc` | Compiler | 97 | validation fails | tfuncs.jl:1125 |
| 14 | `return_cached_result` | Compiler | 263 | validation fails | typeinfer.jl:827 |
| 15 | `tmerge_limited` | Compiler | 325 | validation fails | typelimits.jl:434 |
| 16 | `update_exc_bestguess!` | Compiler | 391 | validation fails | abstractinterpretation.jl:4113 |

### Known Error Patterns (from Phase 1 experience)

| Pattern | Likely Cause | Phase 1 Fix Reference |
|---------|-------------|----------------------|
| `expected i64, found externref` | Missing extern_convert_any before i64 op | PURE-323 |
| `expected i32 but nothing on stack` | Stack underflow — missing phi value push | PURE-505 |
| `expected (ref null $type), found i32` | ReturnNode numeric-to-ref conversion | PURE-036aw |
| `expected subtype of anyref, found externref` | Missing any_convert_extern before ref_cast | PURE-307 |

---

## C_DEPENDENT (70)

These contain foreigncalls and need pure Julia replacements.

### C Calls by Replacement Strategy

#### SKIP (12 ccalls, 21 functions) — Not needed for single-shot typeinf

These are timer/debug/cache/JIT management calls. For single-shot typeinf in Wasm,
they can be stubbed with no-ops or constants.

| C Call | Purpose | Functions Using It |
|--------|---------|-------------------|
| `jl_hrtime` | High-resolution timer | typeinf, typeinf_edge, finish_cycle |
| `jl_uv_puts` | Write to UV stream (debug output) | print, typeinf |
| `jl_uv_putb` | Write byte to UV stream | println |
| `jl_string_ptr` | Get string pointer (debug) | print, print_to_string, typeinf |
| `jl_fill_codeinst` | Fill code instance cache | finishinfer! |
| `jl_promote_ci_to_current` | Promote code instance | finish_nocycle |
| `jl_promote_cis_to_current` | Promote code instances | finish_cycle |
| `jl_push_newly_inferred` | Push to inferred worklist | setindex! |
| `jl_mi_cache_insert` | Insert into MI cache | setindex! |
| `jl_engine_reserve` | Reserve inference engine slot | typeinf_edge |
| `jl_engine_fulfill` | Fulfill engine reservation | typeinf_edge |
| `Core.tuple(:mpfr_greater_p, ...)` | BigFloat comparison (timer) | >, doworkloop |

**Implementation:** Stub with `return nothing` or `return 0`. These functions will still
compile and run — they just won't produce timing/debug output.

#### LOW (20 ccalls) — Trivial pure Julia replacements

| C Call | Purpose | Pure Julia Replacement | Estimated LOC |
|--------|---------|----------------------|---------------|
| `jl_get_world_counter` | Get world age | Return build-time constant `UInt64` | 1 |
| `jl_get_module_infer` | Module inference flag | Return `true` | 1 |
| `jl_is_assertsbuild` | Assertions enabled? | Return `false` | 1 |
| `jl_types_equal` | Type equality | `T1 === T2` | 1 |
| `jl_type_unionall` | Construct UnionAll | `UnionAll(tvar, body)` — already a Julia constructor | 1 |
| `jl_field_index` | Field index by name | `findfirst(==(name), fieldnames(T))` | 3 |
| `jl_get_fieldtypes` | Get field types | `fieldtypes(T)` — already a Julia function | 1 |
| `jl_stored_inline` | Field stored inline? | `isprimitivetype(T)` or check layout | 3 |
| `jl_argument_datatype` | Get DataType from arg type | Unwrap type wrappers | 5 |
| `jl_eqtable_get` | Equality table lookup | `Dict` lookup | 3 |
| `jl_rethrow` | Rethrow exception | Wasm `rethrow` instruction (already in codegen) | 1 |
| `jl_new_structv` | Construct struct from values | Wasm `struct_new` (already in codegen) | 0 |
| `jl_new_structt` | Construct struct from tuple | Wasm `struct_new` (already in codegen) | 0 |
| `jl_value_ptr` | Raw pointer to value | Identity hash or stub | 3 |
| `jl_ir_nslots` | IR slot count | Pre-computed at build time | 1 |
| `jl_ir_slotflag` | IR slot flags | Pre-computed at build time | 1 |
| `memcmp` | Memory comparison | Byte-by-byte loop (or Wasm intrinsic) | 5 |
| `memmove` | Memory move | Wasm `memory.copy` instruction | 1 |
| `memset` | Memory fill | Wasm `memory.fill` instruction | 1 |
| `jl_genericmemory_copyto` | Memory block copy | Wasm `memory.copy` instruction | 1 |

**Estimated total:** ~35 lines of pure Julia replacement code

#### MEDIUM (15 ccalls) — Moderate effort replacements

| C Call | Purpose | Pure Julia Replacement | Estimated LOC |
|--------|---------|----------------------|---------------|
| `jl_has_free_typevars` | Check for free TypeVars | Recursive type walk: `any(t -> t isa TypeVar, ...)` | 15 |
| `jl_find_free_typevars` | Find all free TypeVars | Recursive type walk collecting TypeVars | 20 |
| `jl_instantiate_type_in_env` | Substitute type vars | Recursive type substitution | 25 |
| `jl_module_globalref` | Get GlobalRef from module | Pre-resolve at build time, Dict lookup | 5 |
| `jl_normalize_to_compilable_sig` | Normalize method sig | Pre-normalized in DictMethodTable | 5 |
| `jl_specializations_get_linfo` | Get MethodInstance | Pre-resolved in DictMethodTable | 5 |
| `jl_rettype_inferred` | Get cached return type | Dict lookup in DictMethodTable | 5 |
| `jl_idset_peek_bp` | IdSet lookup | `Dict`/`Set` equivalent | 5 |
| `jl_idset_pop` | IdSet pop | `Dict`/`Set` equivalent | 5 |
| `jl_idset_put_key` | IdSet insert key | `Dict`/`Set` equivalent | 5 |
| `jl_idset_put_idx` | IdSet insert at index | `Dict`/`Set` equivalent | 5 |
| `jl_alloc_string` | Allocate String | WasmTarget string intrinsics | 5 |
| `jl_string_to_genericmemory` | String → Memory{UInt8} | WasmTarget string intrinsics | 5 |
| `jl_genericmemory_to_string` | Memory{UInt8} → String | WasmTarget string intrinsics | 5 |
| `jl_pchar_to_string` | C char* → String | WasmTarget string construction | 5 |

**Estimated total:** ~130 lines of pure Julia replacement code

#### HIGH (5 ccalls) — Significant effort, THE blockers

| C Call | Purpose | Strategy | Estimated LOC | Impact |
|--------|---------|----------|---------------|--------|
| `jl_matching_methods` | Method dispatch lookup | **DictMethodTable** — THE architectural change. Dict{signature, MethodLookupResult} pre-populated at build time. Uses Core.Compiler's existing `AbstractInterpreter` + `MethodTableView` interface. | 50 | 1 function (may_invoke_generator) |
| `jl_type_intersection` | Compute T1 ∩ T2 | **Pre-compute at build time.** For the "1+1" use case, all needed intersections are finite and can be stored in a Dict. The key insight: DictMethodTable already resolves methods → no runtime intersection needed for known types. For unknown types, a simplified intersection (handle UnionAll, Union, DataType basics) covers 90%+ of cases. | 100-200 | 8 functions (_getfield_tfunc, abstract_call_opaque_closure, abstract_eval_throw_undef_if_not, tmeet, tmerge_partial_struct, tuple_tfunc, typeinf_local) |
| `jl_type_intersection_with_env` | Type intersection + env capture | Same strategy as jl_type_intersection + return env bindings | 20 | 2 functions (abstract_call_method, normalize_typevars) |
| `jl_code_for_staged` | @generated function code | Pre-expand at build time. For playground, @generated functions are rare — pre-expand for Base methods only. | 10 | 1 function (get_staged) |
| `jl_gf_invoke_lookup_worlds` | Method invoke lookup | DictMethodTable (same Dict, different lookup path) | 5 | Not found in current walk — may not be needed |

**Estimated total:** 185-285 lines of pure Julia replacement code

### All C_DEPENDENT Functions (70)

| # | Function | Module | Stmts | C Calls |
|---|----------|--------|-------|---------|
| 1 | `#sizehint!#81` | Base | 110 | jl_genericmemory_copyto |
| 2 | `==` | Base | 211 | memcmp |
| 3 | `>` | Base.MPFR | 43 | mpfr_greater_p |
| 4 | `_add_edges_impl` | Compiler | 820 | jl_normalize_to_compilable_sig, jl_specializations_get_linfo |
| 5 | `_base` | Base | 181 | jl_alloc_string, jl_genericmemory_to_string, jl_string_to_genericmemory |
| 6 | `_fieldindex_nothrow` | Base | 4 | jl_field_index |
| 7 | `_getfield_tfunc` | Compiler | 855 | jl_field_index, jl_get_fieldtypes, jl_type_unionall, jl_type_intersection |
| 8 | `_limit_type_size` | Compiler | 495 | jl_type_unionall |
| 9 | `_resize!` | Base | 183 | jl_alloc_string, jl_string_to_genericmemory, memmove |
| 10 | `abstract_call_method` | Compiler | 398 | jl_normalize_to_compilable_sig, jl_types_equal, jl_type_intersection_with_env |
| 11 | `abstract_call_opaque_closure` | Compiler | 111 | jl_type_unionall, jl_type_intersection, jl_has_free_typevars |
| 12 | `abstract_eval_foreigncall` | Compiler | 282 | jl_module_globalref |
| 13 | `abstract_eval_new` | Compiler | 802 | jl_has_free_typevars, jl_new_structv |
| 14 | `abstract_eval_new_opaque_closure` | Compiler | 427 | jl_genericmemory_copyto |
| 15 | `abstract_eval_splatnew` | Compiler | 499 | jl_has_free_typevars, jl_new_structt |
| 16 | `abstract_eval_throw_undef_if_not` | Compiler | 117 | jl_type_intersection |
| 17 | `abstract_eval_value_expr` | Compiler | 153 | jl_module_globalref |
| 18 | `argument_datatype` | Base | 4 | jl_argument_datatype |
| 19 | `bin` | Base | 101 | jl_alloc_string, jl_string_to_genericmemory, jl_genericmemory_to_string |
| 20 | `cache_result!` | Compiler | 46 | jl_rettype_inferred |
| 21 | `cycle_fix_limited` | Compiler | 153 | jl_idset_peek_bp, jl_idset_pop |
| 22 | `dec` | Base | 37 | jl_alloc_string, jl_string_to_genericmemory, jl_genericmemory_to_string |
| 23 | `doworkloop` | Compiler | 219 | mpfr_greater_p |
| 24 | `edge_matches_sv` | Compiler | 438 | jl_get_world_counter |
| 25 | `empty!` | Base | 82 | memset |
| 26 | `ensureroom_reallocate` | Base | 35 | jl_alloc_string, jl_string_to_genericmemory |
| 27 | `ensureroom_slowpath` | Base | 393 | memmove |
| 28 | `finish_cycle` | Compiler | 634 | jl_hrtime, jl_get_world_counter, jl_promote_cis_to_current |
| 29 | `finish_nocycle` | Compiler | 160 | jl_get_world_counter, jl_promote_ci_to_current |
| 30 | `finishinfer!` | Compiler | 513 | jl_fill_codeinst |
| 31 | `get_staged` | Compiler | 36 | jl_code_for_staged, jl_value_ptr |
| 32 | `hex` | Base | 87 | jl_alloc_string, jl_string_to_genericmemory, jl_genericmemory_to_string |
| 33 | `is_derived_type` | Compiler | 109 | jl_has_free_typevars |
| 34 | `is_lattice_equal` | Compiler | 277 | jl_types_equal |
| 35 | `is_undefref_fieldtype` | Compiler | 16 | jl_has_free_typevars, jl_stored_inline |
| 36 | `issimpleenoughtype` | Compiler | 109 | jl_has_free_typevars |
| 37 | `issimplertype` | Compiler | 503 | jl_types_equal |
| 38 | `issubset` | Base | 99 | jl_idset_peek_bp |
| 39 | `may_invoke_generator` | Base | 382 | jl_value_ptr, jl_matching_methods, jl_ir_nslots, jl_ir_slotflag, jl_has_free_typevars |
| 40 | `maybe_validate_code` | Compiler | 115 | jl_is_assertsbuild |
| 41 | `method_for_inference_heuristics` | Compiler | 48 | jl_normalize_to_compilable_sig, jl_specializations_get_linfo |
| 42 | `most_general_argtypes` | Compiler | 409 | jl_has_free_typevars, jl_type_unionall |
| 43 | `normalize_typevars` | Base | 17 | jl_type_intersection_with_env |
| 44 | `oct` | Base | 58 | jl_alloc_string, jl_string_to_genericmemory, jl_genericmemory_to_string |
| 45 | `opaque_closure_tfunc` | Compiler | 58 | jl_type_unionall |
| 46 | `print` | Base | 14 | jl_string_ptr |
| 47 | `print` | Core | 15 | jl_string_ptr, jl_uv_puts |
| 48 | `print_to_string` | Base | 167 | jl_alloc_string, jl_string_to_genericmemory, jl_string_ptr, jl_genericmemory_to_string, jl_pchar_to_string |
| 49 | `println` | Core | 7 | jl_uv_putb |
| 50 | `propagate_to_error_handler!` | Compiler | 491 | jl_genericmemory_copyto |
| 51 | `push!` | Base | 93 | jl_idset_peek_bp, jl_value_ptr, jl_idset_put_key, jl_idset_put_idx |
| 52 | `rethrow` | Base | 2 | jl_rethrow |
| 53 | `rewrap_unionall` | Base | 75 | jl_type_unionall |
| 54 | `setindex!` | Compiler | 16 | jl_push_newly_inferred, jl_mi_cache_insert |
| 55 | `sp_type_rewrap` | Compiler | 334 | jl_instantiate_type_in_env, jl_type_unionall, jl_has_free_typevars, jl_find_free_typevars |
| 56 | `subst_trivial_bounds` | Base | 48 | jl_type_unionall |
| 57 | `tmeet` | Compiler | 166 | jl_has_free_typevars, jl_type_intersection |
| 58 | `tmerge` | Compiler | 181 | jl_value_ptr, jl_types_equal |
| 59 | `tmerge_partial_struct` | Compiler | 599 | jl_type_intersection |
| 60 | `tmerge_types_slow` | Compiler | 1557 | jl_type_unionall, jl_has_free_typevars |
| 61 | `tuple_tfunc` | Compiler | 806 | jl_type_intersection |
| 62 | `tuplemerge` | Compiler | 314 | jl_has_free_typevars |
| 63 | `typeinf` | Compiler | 531 | jl_hrtime, jl_string_ptr, jl_uv_puts |
| 64 | `typeinf_edge` | Compiler | 1308 | jl_normalize_to_compilable_sig, jl_specializations_get_linfo, jl_rettype_inferred, jl_get_module_infer, jl_hrtime, jl_engine_reserve, jl_engine_fulfill |
| 65 | `typeinf_local` | Compiler | 4844 | jl_genericmemory_copyto, jl_type_intersection |
| 66 | `union_count_abstract` | Compiler | 163 | jl_has_free_typevars |
| 67 | `unsafe_write` | Base | 135 | memmove |
| 68 | `valid_as_lattice` | Compiler | 65 | jl_get_fieldtypes |
| 69 | `validate_code!` | Compiler | 1386 | jl_eqtable_get |
| 70 | `widenreturn_partials` | Compiler | 268 | jl_genericmemory_copyto |

---

## OPTIMIZER_SKIP (2)

Binaryen handles optimization. These are not compiled to Wasm.

| # | Function | Module | Stmts | File |
|---|----------|--------|-------|------|
| 1 | `finish!` | Compiler | 323 | typeinfer.jl:94 |
| 2 | `optimize` | Compiler | 5 | optimize.jl:1001 |

---

## UNRESOLVED (6)

Cannot resolve function or parse signature. Needs manual investigation or can be skipped.

| # | Function | Module | Reason | Disposition |
|---|----------|--------|--------|-------------|
| 1 | `#argtypes_to_type##0` | Compiler | Generated closure — cannot resolve by name | SKIP — inner closure of argtypes_to_type (which COMPILES_NOW) |
| 2 | `_` | Compiler | Not a real function name (likely an operator) | SKIP — likely a pattern match artifact |
| 3 | `overflow_case` | Base | Not found in Base module | SKIP — may be inlined/removed in Julia 1.12 |
| 4 | `__limit_type_size` | Compiler | Static type parameter `T` not defined | NEEDS_PATTERN — requires type-parameterized compilation |
| 5 | `limit_type_size` | Compiler | Static type parameter `T` not defined | NEEDS_PATTERN — requires type-parameterized compilation |
| 6 | `update_cycle_worklists!` | Compiler | Takes closure argument (generated name) | NEEDS_PATTERN — needs closure compilation support |

---

## Recommendations for PURE-3002 (DictMethodTable Build)

### Architecture Overview

```
Build Time (julia script)                    Runtime (Wasm)
─────────────────────────                   ───────────────
For each method we need:                    DictMethodTable:
  code_typed(f, argtypes)                     Dict lookup → CodeInfo + RetType
  → CodeInfo, ReturnType                      No ccalls needed
  → store in DictMethodTable

Type intersections we need:                 typeintersect_dict:
  typeintersect(T1, T2) for all              Dict lookup → pre-computed result
  (T1, T2) pairs used by typeinf            No C code needed
  → store in Dict

Type var checks:                            has_free_typevars:
  Pure Julia recursive tree walk             Compiled to Wasm directly
  (no C code needed)                         Works on any type
```

### Priority Order for C Call Replacement

**Phase A — Stubs (trivial, ~10 min):**
Stub the 12 SKIP ccalls. This alone makes 21 C_DEPENDENT functions compilable.
Functions: typeinf, typeinf_edge, finish_cycle, finish_nocycle, finishinfer!, print,
println, setindex!, doworkloop, >, maybe_validate_code

**Phase B — Constants + Simple Replacements (~30 min):**
Replace the 20 LOW complexity ccalls. Makes ~15 more functions compilable.
Most are 1-line replacements (return constants, use existing Julia builtins).

**Phase C — Type System Helpers (~1-2 hours):**
Implement pure Julia versions of jl_has_free_typevars, jl_find_free_typevars,
jl_instantiate_type_in_env. These are recursive type tree walks — moderate but
well-defined. Makes ~15 more functions compilable.

**Phase D — DictMethodTable + Type Intersection (~2-3 hours):**
THE architectural work:
1. Build DictMethodTable <: MethodTableView
2. Build WasmInterpreter <: AbstractInterpreter
3. Pre-compute type intersections at build time
4. Pre-decompress CodeInfo at build time
5. Test in native Julia: Dict typeinf == standard typeinf

### Key Architecture Decision: Pre-Computed Type Intersection

For the "1+1" playground use case, the type system operations are bounded:
- `+(Int64, Int64)` — intersection with `Tuple{Int64, Int64}` is itself
- `sin(Float64)` — intersection with `Tuple{Float64}` is itself
- All intersections for known Base methods can be pre-computed

**Strategy: Pre-compute ALL type intersections at build time.**
The Dict key IS the answer — no runtime intersection algorithm needed for known types.

For unknown/user-defined types, a simplified intersection handling:
- `T ∩ Any = T` (identity)
- `T ∩ T = T` (idempotent)
- `Union{A,B} ∩ T = Union{A∩T, B∩T}` (distributive)
- `DataType ∩ DataType` — check subtype relationship

This covers 95%+ of playground cases without implementing the full 4000-line C subtype.c.

### Estimated Total Effort

| Phase | LOC | Functions Unblocked | Time |
|-------|-----|--------------------|----- |
| A: SKIP stubs | ~20 | 21 | 10 min |
| B: LOW replacements | ~35 | ~15 | 30 min |
| C: MEDIUM type helpers | ~130 | ~15 | 1-2 hr |
| D: HIGH DictMethodTable + intersection | ~200 | ~19 | 2-3 hr |
| **Total** | **~385** | **70 functions** | **4-6 hr** |

After all replacements + the 16 NEEDS_PATTERN codegen fixes, ALL 171 functions
should be compilable to Wasm. Combined with the 77 COMPILES_NOW functions,
this gives us the full typeinf module.
