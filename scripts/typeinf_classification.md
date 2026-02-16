# Core.Compiler.typeinf Dependency Graph Audit (PURE-3000)

**Entry point:** `Core.Compiler.typeinf(NativeInterpreter, InferenceState)`
**Date:** 2026-02-15
**Method:** Walk call graph via `Base.code_typed(optimize=true)`, recurse into
both `:invoke` targets (resolved MethodInstances) and `:call` targets
(GlobalRef to Core.Compiler functions). Skip optimizer functions.

## Summary

| Category | Count |
|----------|-------|
| **Total unique functions** | **171** |
| **Needed (non-optimizer)** | **169** |
| Pure Julia (compilable) | 99 |
| Has ccall (C-dependent) | 70 |
| Optimizer (SKIP) | 2 |

## Known C Walls (Must Be Replaced)

| C Function | Purpose | Replacement |
|------------|---------|-------------|
| `jl_gf_invoke_lookup_worlds` | method lookup path | DictMethodTable replaces this |
| `jl_matching_methods` | method dispatch lookup | DictMethodTable replaces this |
| `jl_uncompress_ir` | decompress method source | pre-decompress at build time |

### Functions Containing Known C Walls

- **`may_invoke_generator`** (Base): jl_value_ptr, jl_matching_methods, jl_ir_nslots, jl_ir_slotflag, jl_has_free_typevars

## Pure Julia Functions (99)

These can be compiled to Wasm directly.

| # | Function | Module | Stmts | AI? | MT? | File |
|---|----------|--------|-------|-----|-----|------|
| 1 | `#argtypes_to_type##0` | Compiler | 6 |  |  | typeutils.jl:52 |
| 2 | `#string#403` | Base | 53 |  |  | intfuncs.jl:990 |
| 3 | `<=` | Base | 3 |  |  | bool.jl:161 |
| 4 | `BestguessInfo` | Compiler | 16 |  |  | abstractinterpretation.jl:3884 |
| 5 | `InliningState` | Compiler | 5 |  |  | optimize.jl:147 |
| 6 | `OptimizationState` | Compiler | 16 |  |  | optimize.jl:171 |
| 7 | `PartialStruct` | Compiler | 77 |  |  | typelattice.jl:759 |
| 8 | `_` | Compiler | 63 |  |  | typelattice.jl:39 |
| 9 | `__limit_type_size` | Compiler | 77 |  |  | typelimits.jl:192 |
| 10 | `_all` | Base | 80 |  |  | anyall.jl:193 |
| 11 | `_assert_tostring` | Base | 3 |  |  | error.jl:247 |
| 12 | `_issubconditional` | Compiler | 228 |  |  | typelattice.jl:264 |
| 13 | `_throw_argerror` | Base | 3 |  |  | array.jl:317 |
| 14 | `_typename` | Compiler | 3 |  |  | typeutils.jl:217 |
| 15 | `_unioncomplexity` | Compiler | 76 |  |  | typeutils.jl:296 |
| 16 | `_uniontypes` | Base | 100 |  |  | runtime_internals.jl:1392 |
| 17 | `_validate_val!` | Compiler | 551 |  |  | validation.jl:87 |
| 18 | `abstract_call` | Compiler | 161 |  |  | abstractinterpretation.jl:3037 |
| 19 | `abstract_eval_basic_statement` | Compiler | 496 |  |  | abstractinterpretation.jl:3790 |
| 20 | `abstract_eval_call` | Compiler | 10 |  |  | abstractinterpretation.jl:3053 |
| 21 | `abstract_eval_cfunction` | Compiler | 156 |  |  | abstractinterpretation.jl:2935 |
| 22 | `abstract_eval_copyast` | Compiler | 31 |  |  | abstractinterpretation.jl:3207 |
| 23 | `abstract_eval_globalref` | Compiler | 28 |  |  | abstractinterpretation.jl:3722 |
| 24 | `abstract_eval_isdefined_expr` | Compiler | 357 |  |  | abstractinterpretation.jl:3218 |
| 25 | `abstract_eval_nonlinearized_foreigncall_name` | Compiler | 80 |  |  | abstractinterpretation.jl:3452 |
| 26 | `abstract_eval_phi` | Compiler | 92 |  |  | abstractinterpretation.jl:3523 |
| 27 | `abstract_eval_special_value` | Compiler | 150 |  |  | abstractinterpretation.jl:2955 |
| 28 | `abstract_eval_statement_expr` | Compiler | 252 |  |  | abstractinterpretation.jl:3386 |
| 29 | `abstract_eval_value` | Compiler | 109 |  |  | abstractinterpretation.jl:3000 |
| 30 | `add_edges!` | Compiler | 5 |  |  | types.jl:507 |
| 31 | `add_edges_impl` | Compiler | 90 |  |  | stmtinfo.jl:482 |
| 32 | `add_invoke_edge!` | Compiler | 175 |  |  | stmtinfo.jl:322 |
| 33 | `adjust_effects` | Compiler | 384 |  |  | typeinfer.jl:400 |
| 34 | `all` | Base | 2 |  |  | anyall.jl:188 |
| 35 | `append!` | Base | 39 |  |  | array.jl:1352 |
| 36 | `append_c_digits` | Base | 59 |  |  | intfuncs.jl:870 |
| 37 | `append_c_digits_fast` | Base | 19 |  |  | intfuncs.jl:898 |
| 38 | `append_nine_digits` | Base | 84 |  |  | intfuncs.jl:887 |
| 39 | `apply_refinement!` | Compiler | 168 |  |  | abstractinterpretation.jl:4416 |
| 40 | `argtypes_to_type` | Compiler | 170 |  |  | typeutils.jl:51 |
| 41 | `assign_parentchild!` | Compiler | 56 |  |  | inferencestate.jl:934 |
| 42 | `bool_rt_to_conditional` | Compiler | 350 |  |  | abstractinterpretation.jl:3950 |
| 43 | `code_cache` | Compiler | 9 |  |  | types.jl:495 |
| 44 | `collect_argtypes` | Compiler | 77 |  |  | abstractinterpretation.jl:3010 |
| 45 | `collect_const_args` | Compiler | 241 |  |  | abstractinterpretation.jl:989 |
| 46 | `compute_edges!` | Compiler | 64 |  |  | typeinfer.jl:649 |
| 47 | `convert` | Base | 3 |  |  | essentials.jl:455 |
| 48 | `count_const_size` | Compiler | 328 |  |  | utilities.jl:32 |
| 49 | `datatype_fieldcount` | Base | 98 |  |  | runtime_internals.jl:1120 |
| 50 | `decode_effects` | Compiler | 121 |  |  | effects.jl:351 |
| 51 | `error` | Base | 3 |  |  | error.jl:44 |
| 52 | `fill!` | Base | 153 |  |  | bitarray.jl:372 |
| 53 | `filter!` | Base | 120 |  |  | array.jl:2978 |
| 54 | `getfield_tfunc` | Compiler | 97 |  |  | tfuncs.jl:1125 |
| 55 | `instanceof_tfunc` | Compiler | 2 |  |  | tfuncs.jl:104 |
| 56 | `intersect` | Compiler | 18 |  |  | cicache.jl:37 |
| 57 | `invalid_wrap_err` | Base | 5 |  |  | array.jl:3158 |
| 58 | `is_all_const_arg` | Compiler | 251 |  |  | abstractinterpretation.jl:975 |
| 59 | `is_identity_free_argtype` | Compiler | 38 |  |  | typeutils.jl:348 |
| 60 | `is_mutation_free_argtype` | Compiler | 38 |  |  | typeutils.jl:379 |
| 61 | `is_same_frame` | Compiler | 11 |  |  | typeinfer.jl:783 |
| 62 | `isidentityfree` | Base | 79 |  |  | runtime_internals.jl:900 |
| 63 | `ismutationfree` | Base | 79 |  |  | runtime_internals.jl:880 |
| 64 | `isready` | Compiler | 13 |  |  | inferencestate.jl:1151 |
| 65 | `issubconditional` | Compiler | 2 |  |  | typelattice.jl:262 |
| 66 | `length` | Compiler | 5 |  |  | methodtable.jl:10 |
| 67 | `limit_type_size` | Compiler | 36 |  |  | typelimits.jl:17 |
| 68 | `merge_call_chain!` | Compiler | 126 |  |  | typeinfer.jl:763 |
| 69 | `ndigits0z` | Base | 30 |  |  | intfuncs.jl:766 |
| 70 | `ndigits0znb` | Base | 45 |  |  | intfuncs.jl:684 |
| 71 | `ndigits0zpb` | Base | 122 |  |  | intfuncs.jl:702 |
| 72 | `overflow_case` | Base | 16 |  |  | range.jl:364 |
| 73 | `record_slot_assign!` | Compiler | 222 |  |  | typeinfer.jl:661 |
| 74 | `record_ssa_assign!` | Compiler | 532 |  |  | inferencestate.jl:789 |
| 75 | `resize!` | Base | 117 |  |  | array.jl:1478 |
| 76 | `resolve_call_cycle!` | Compiler | 123 |  |  | typeinfer.jl:798 |
| 77 | `return_cached_result` | Compiler | 263 |  |  | typeinfer.jl:827 |
| 78 | `reverse!` | Base | 137 |  |  | array.jl:2230 |
| 79 | `scan_leaf_partitions` | Compiler | 2 |  |  | abstractinterpretation.jl:3706 |
| 80 | `ssa_def_slot` | Compiler | 228 |  |  | abstractinterpretation.jl:1420 |
| 81 | `stupdate!` | Compiler | 139 |  |  | typelattice.jl:722 |
| 82 | `sym_in` | Base | 30 |  |  | tuple.jl:673 |
| 83 | `throw_boundserror` | Base | 3 |  |  | essentials.jl:15 |
| 84 | `throw_inexacterror` | Core | 3 |  |  | boot.jl:815 |
| 85 | `tmerge_limited` | Compiler | 325 |  |  | typelimits.jl:434 |
| 86 | `tname_intersect` | Compiler | 107 |  |  | typelimits.jl:720 |
| 87 | `tuple_tail_elem` | Compiler | 106 |  |  | typeutils.jl:219 |
| 88 | `type_annotate!` | Compiler | 845 |  |  | typeinfer.jl:712 |
| 89 | `type_more_complex` | Compiler | 305 |  |  | typelimits.jl:223 |
| 90 | `union!` | Base | 88 |  |  | abstractset.jl:103 |
| 91 | `unionlen` | Base | 30 |  |  | runtime_internals.jl:1390 |
| 92 | `update_bestguess!` | Compiler | 196 |  |  | abstractinterpretation.jl:4070 |
| 93 | `update_cycle_worklists!` | Compiler | 431 |  |  | abstractinterpretation.jl:4149 |
| 94 | `update_exc_bestguess!` | Compiler | 391 |  |  | abstractinterpretation.jl:4113 |
| 95 | `widenconst` | Compiler | 2 |  |  | typelattice.jl:695 |
| 96 | `widenreturn` | Compiler | 697 |  |  | abstractinterpretation.jl:3913 |
| 97 | `widenreturn_noslotwrapper` | Compiler | 2 |  |  | abstractinterpretation.jl:3993 |
| 98 | `widenwrappedslotwrapper` | Compiler | 183 |  |  | typelattice.jl:227 |
| 99 | `⊑` | Compiler | 452 |  |  | typelattice.jl:432 |

## C-Dependent Functions (70)

These contain foreigncalls and need pure Julia replacements.

| # | Function | Module | Stmts | C Calls | C Wall? |
|---|----------|--------|-------|---------|---------|
| 1 | `#sizehint!#81` | Base | 110 | `jl_genericmemory_copyto` |  |
| 2 | `==` | Base | 211 | `memcmp` |  |
| 3 | `>` | Base.MPFR | 43 | `Core.tuple(:mpfr_greater_p, Base.MPFR.libmpfr)` |  |
| 4 | `_add_edges_impl` | Compiler | 820 | `jl_normalize_to_compilable_sig, jl_specializations_get_linfo` |  |
| 5 | `_base` | Base | 181 | `jl_alloc_string, jl_genericmemory_to_string, jl_string_to_genericmemory` |  |
| 6 | `_fieldindex_nothrow` | Base | 4 | `jl_field_index` |  |
| 7 | `_getfield_tfunc` | Compiler | 855 | `jl_field_index, jl_get_fieldtypes, jl_type_unionall, jl_type_intersection` |  |
| 8 | `_limit_type_size` | Compiler | 495 | `jl_type_unionall` |  |
| 9 | `_resize!` | Base | 183 | `jl_alloc_string, jl_string_to_genericmemory, memmove` |  |
| 10 | `abstract_call_method` | Compiler | 398 | `jl_normalize_to_compilable_sig, jl_types_equal, jl_type_intersection_with_env` |  |
| 11 | `abstract_call_opaque_closure` | Compiler | 111 | `jl_type_unionall, jl_type_intersection, jl_has_free_typevars` |  |
| 12 | `abstract_eval_foreigncall` | Compiler | 282 | `jl_module_globalref` |  |
| 13 | `abstract_eval_new` | Compiler | 802 | `jl_has_free_typevars, jl_new_structv` |  |
| 14 | `abstract_eval_new_opaque_closure` | Compiler | 427 | `jl_genericmemory_copyto` |  |
| 15 | `abstract_eval_splatnew` | Compiler | 499 | `jl_has_free_typevars, jl_new_structt` |  |
| 16 | `abstract_eval_throw_undef_if_not` | Compiler | 117 | `jl_type_intersection` |  |
| 17 | `abstract_eval_value_expr` | Compiler | 153 | `jl_module_globalref` |  |
| 18 | `argument_datatype` | Base | 4 | `jl_argument_datatype` |  |
| 19 | `bin` | Base | 101 | `jl_alloc_string, jl_string_to_genericmemory, jl_genericmemory_to_string` |  |
| 20 | `cache_result!` | Compiler | 46 | `jl_rettype_inferred` |  |
| 21 | `cycle_fix_limited` | Compiler | 153 | `jl_idset_peek_bp, jl_idset_pop` |  |
| 22 | `dec` | Base | 37 | `jl_alloc_string, jl_string_to_genericmemory, jl_genericmemory_to_string` |  |
| 23 | `doworkloop` | Compiler | 219 | `Core.tuple(:mpfr_greater_p, Base.MPFR.libmpfr)` |  |
| 24 | `edge_matches_sv` | Compiler | 438 | `jl_get_world_counter` |  |
| 25 | `empty!` | Base | 82 | `memset` |  |
| 26 | `ensureroom_reallocate` | Base | 35 | `jl_alloc_string, jl_string_to_genericmemory` |  |
| 27 | `ensureroom_slowpath` | Base | 393 | `memmove` |  |
| 28 | `finish_cycle` | Compiler | 634 | `jl_hrtime, jl_get_world_counter, jl_promote_cis_to_current` |  |
| 29 | `finish_nocycle` | Compiler | 160 | `jl_get_world_counter, jl_promote_ci_to_current` |  |
| 30 | `finishinfer!` | Compiler | 513 | `jl_fill_codeinst` |  |
| 31 | `get_staged` | Compiler | 36 | `jl_code_for_staged, jl_value_ptr` |  |
| 32 | `hex` | Base | 87 | `jl_alloc_string, jl_string_to_genericmemory, jl_genericmemory_to_string` |  |
| 33 | `is_derived_type` | Compiler | 109 | `jl_has_free_typevars` |  |
| 34 | `is_lattice_equal` | Compiler | 277 | `jl_types_equal` |  |
| 35 | `is_undefref_fieldtype` | Compiler | 16 | `jl_has_free_typevars, jl_stored_inline` |  |
| 36 | `issimpleenoughtype` | Compiler | 109 | `jl_has_free_typevars` |  |
| 37 | `issimplertype` | Compiler | 503 | `jl_types_equal` |  |
| 38 | `issubset` | Base | 99 | `jl_idset_peek_bp` |  |
| 39 | `may_invoke_generator` | Base | 382 | `jl_value_ptr, jl_matching_methods, jl_ir_nslots, jl_ir_slotflag, jl_has_free_typevars` | YES |
| 40 | `maybe_validate_code` | Compiler | 115 | `jl_is_assertsbuild` |  |
| 41 | `method_for_inference_heuristics` | Compiler | 48 | `jl_normalize_to_compilable_sig, jl_specializations_get_linfo` |  |
| 42 | `most_general_argtypes` | Compiler | 409 | `jl_has_free_typevars, jl_type_unionall` |  |
| 43 | `normalize_typevars` | Base | 17 | `jl_type_intersection_with_env` |  |
| 44 | `oct` | Base | 58 | `jl_alloc_string, jl_string_to_genericmemory, jl_genericmemory_to_string` |  |
| 45 | `opaque_closure_tfunc` | Compiler | 58 | `jl_type_unionall` |  |
| 46 | `print` | Base | 14 | `jl_string_ptr` |  |
| 47 | `print` | Core | 15 | `jl_string_ptr, jl_uv_puts` |  |
| 48 | `print_to_string` | Base | 167 | `jl_alloc_string, jl_string_to_genericmemory, jl_string_ptr, jl_genericmemory_to_string, jl_pchar_to_string` |  |
| 49 | `println` | Core | 7 | `jl_uv_putb` |  |
| 50 | `propagate_to_error_handler!` | Compiler | 491 | `jl_genericmemory_copyto` |  |
| 51 | `push!` | Base | 93 | `jl_idset_peek_bp, jl_value_ptr, jl_idset_put_key, jl_idset_put_idx` |  |
| 52 | `rethrow` | Base | 2 | `jl_rethrow` |  |
| 53 | `rewrap_unionall` | Base | 75 | `jl_type_unionall` |  |
| 54 | `setindex!` | Compiler | 16 | `jl_push_newly_inferred, jl_mi_cache_insert` |  |
| 55 | `sp_type_rewrap` | Compiler | 334 | `jl_instantiate_type_in_env, jl_type_unionall, jl_has_free_typevars, jl_find_free_typevars` |  |
| 56 | `subst_trivial_bounds` | Base | 48 | `jl_type_unionall` |  |
| 57 | `tmeet` | Compiler | 166 | `jl_has_free_typevars, jl_type_intersection` |  |
| 58 | `tmerge` | Compiler | 181 | `jl_value_ptr, jl_types_equal` |  |
| 59 | `tmerge_partial_struct` | Compiler | 599 | `jl_type_intersection` |  |
| 60 | `tmerge_types_slow` | Compiler | 1557 | `jl_type_unionall, jl_has_free_typevars` |  |
| 61 | `tuple_tfunc` | Compiler | 806 | `jl_type_intersection` |  |
| 62 | `tuplemerge` | Compiler | 314 | `jl_has_free_typevars` |  |
| 63 | `typeinf` | Compiler | 531 | `jl_hrtime, jl_string_ptr, jl_uv_puts` |  |
| 64 | `typeinf_edge` | Compiler | 1308 | `jl_normalize_to_compilable_sig, jl_specializations_get_linfo, jl_rettype_inferred, jl_get_module_infer, jl_hrtime, jl_engine_reserve, jl_engine_fulfill` |  |
| 65 | `typeinf_local` | Compiler | 4844 | `jl_genericmemory_copyto, jl_type_intersection` |  |
| 66 | `union_count_abstract` | Compiler | 163 | `jl_has_free_typevars` |  |
| 67 | `unsafe_write` | Base | 135 | `memmove` |  |
| 68 | `valid_as_lattice` | Compiler | 65 | `jl_get_fieldtypes` |  |
| 69 | `validate_code!` | Compiler | 1386 | `jl_eqtable_get` |  |
| 70 | `widenreturn_partials` | Compiler | 268 | `jl_genericmemory_copyto` |  |

## Optimizer Functions (2 — SKIPPED)

Binaryen handles optimization. These are not compiled to Wasm.

| # | Function | Module | Stmts |
|---|----------|--------|-------|
| 1 | `finish!` | Compiler | 323 |
| 2 | `optimize` | Compiler | 5 |

## Architecture Recommendation

### DictMethodTable Location
```
WasmTarget.jl/src/typeinf/
  dict_method_table.jl  — DictMethodTable <: MethodTableView
  wasm_interpreter.jl   — WasmInterpreter <: AbstractInterpreter
  populate.jl           — Build-time Dict population
  test_dict_typeinf.jl  — Native Julia verification
```

### C Wall Replacement Strategy
| Wall | Strategy |
|------|----------|
| `jl_matching_methods` | DictMethodTable: Dict{Type, MethodLookupResult} pre-populated at build time |
| `jl_gf_invoke_lookup_worlds` | Same DictMethodTable (different lookup path, same data) |
| `jl_uncompress_ir` | Pre-decompress CodeInfo at build time, store in Dict |

### Other ccalls Found (not C walls)

| ccall | Purpose | Strategy |
|-------|---------|----------|
| `Core.tuple(:mpfr_greater_p, Base.MPFR.libmpfr)` | ? | Investigate |
| `jl_alloc_string` | ? | Investigate |
| `jl_argument_datatype` | ? | Investigate |
| `jl_code_for_staged` | ? | Investigate |
| `jl_engine_fulfill` | ? | Investigate |
| `jl_engine_reserve` | ? | Investigate |
| `jl_eqtable_get` | ? | Investigate |
| `jl_field_index` | ? | Investigate |
| `jl_fill_codeinst` | Fill code instance cache | SKIP — cache management, not needed for single-shot typeinf |
| `jl_find_free_typevars` | ? | Investigate |
| `jl_genericmemory_copyto` | Memory copy | Use Wasm memory.copy / memory.fill |
| `jl_genericmemory_to_string` | ? | Investigate |
| `jl_get_fieldtypes` | ? | Investigate |
| `jl_get_module_infer` | ? | Investigate |
| `jl_get_world_counter` | Get world age | Return constant world age (set at build time) |
| `jl_has_free_typevars` | ? | Investigate |
| `jl_hrtime` | High-resolution timer | SKIP — only used for timing/debug output |
| `jl_idset_peek_bp` | ? | Investigate |
| `jl_idset_pop` | ? | Investigate |
| `jl_idset_put_idx` | ? | Investigate |
| `jl_idset_put_key` | ? | Investigate |
| `jl_instantiate_type_in_env` | ? | Investigate |
| `jl_ir_nslots` | ? | Investigate |
| `jl_ir_slotflag` | ? | Investigate |
| `jl_is_assertsbuild` | ? | Investigate |
| `jl_mi_cache_insert` | ? | Investigate |
| `jl_module_globalref` | ? | Investigate |
| `jl_new_structt` | ? | Investigate |
| `jl_new_structv` | ? | Investigate |
| `jl_normalize_to_compilable_sig` | ? | Investigate |
| `jl_pchar_to_string` | ? | Investigate |
| `jl_promote_ci_to_current` | Promote code instance | SKIP — cache management, not needed for single-shot typeinf |
| `jl_promote_cis_to_current` | Promote code instance | SKIP — cache management, not needed for single-shot typeinf |
| `jl_push_newly_inferred` | ? | Investigate |
| `jl_rethrow` | ? | Investigate |
| `jl_rettype_inferred` | ? | Investigate |
| `jl_specializations_get_linfo` | ? | Investigate |
| `jl_stored_inline` | ? | Investigate |
| `jl_string_ptr` | Get string pointer | SKIP — only used for timing/debug output |
| `jl_string_to_genericmemory` | ? | Investigate |
| `jl_type_intersection` | Type intersection | Implement in pure Julia (subtype lattice) |
| `jl_type_intersection_with_env` | ? | Investigate |
| `jl_type_unionall` | ? | Investigate |
| `jl_types_equal` | ? | Investigate |
| `jl_uv_putb` | ? | Investigate |
| `jl_uv_puts` | Write to stream | SKIP — only used for timing/debug output |
| `jl_value_ptr` | ? | Investigate |
| `memcmp` | ? | Investigate |
| `memmove` | ? | Investigate |
| `memset` | Memory set (libc) | Use Wasm memory.copy / memory.fill |

## Next Steps

1. **PURE-3001**: Try compiling each pure Julia function individually with WasmTarget
   - Classify: COMPILES_NOW / NEEDS_PATTERN / C_DEPENDENT
2. **PURE-3002**: Build DictMethodTable (pure Julia Dict replaces jl_matching_methods)
3. **PURE-3003**: Test in native Julia (Dict typeinf CodeInfo == standard CodeInfo)
4. **PURE-3004**: Per-function compilation stories from classification
