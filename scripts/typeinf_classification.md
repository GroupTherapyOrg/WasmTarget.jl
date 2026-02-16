# Core.Compiler.typeinf Function Classification (PURE-3001)

**Entry point:** `Core.Compiler.typeinf(NativeInterpreter, InferenceState)`
**Date:** 2026-02-15
**Method:** For each function from PURE-3000's dependency graph:
- Pure Julia functions: attempt `WasmTarget.compile(f, argtypes)` + `wasm-tools validate`
- C-dependent: pre-classified by ccall analysis
- Optimizer: pre-classified by name (Binaryen handles optimization)

## Summary

| Category | Count | Description |
|----------|-------|-------------|
| **COMPILES_NOW** | **60** | Pure Julia, compiles + validates |
| **NEEDS_PATTERN** | **12** | Has stubs/validation errors, needs codegen fixes |
| **C_DEPENDENT** | **70** | Has ccalls that need pure Julia replacement |
| **OPTIMIZER_SKIP** | **2** | Only for optimization — Binaryen handles this |
| **COMPILE_ERROR** | **27** | Cannot resolve function/signature |
| **Total** | **171** | |

## COMPILES_NOW (60)

These compile to Wasm and validate. Ready for compilation into typeinf module.

| # | Function | Module | Stmts | Funcs | Bytes | File |
|---|----------|--------|-------|-------|-------|------|
| 1 | `#string#403` | Base | 53 | 5 | 625 | intfuncs.jl:990 |
| 2 | `BestguessInfo` | Compiler | 16 | 5 | 167 | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3884 |
| 3 | `OptimizationState` | Compiler | 16 | 5 | 934 | ../usr/share/julia/Compiler/src/optimize.jl:171 |
| 4 | `PartialStruct` | Compiler | 77 | 5 | 880 | ../usr/share/julia/Compiler/src/typelattice.jl:759 |
| 5 | `_all` | Base | 80 | 5 | 752 | anyall.jl:193 |
| 6 | `_assert_tostring` | Base | 3 | 5 | 123 | error.jl:247 |
| 7 | `_throw_argerror` | Base | 3 | 5 | 127 | array.jl:317 |
| 8 | `_unioncomplexity` | Compiler | 76 | 5 | 798 | ../usr/share/julia/Compiler/src/typeutils.jl:296 |
| 9 | `_uniontypes` | Base | 100 | 5 | 1225 | runtime_internals.jl:1392 |
| 10 | `_validate_val!` | Compiler | 551 | 5 | 5060 | ../usr/share/julia/Compiler/src/validation.jl:87 |
| 11 | `abstract_eval_call` | Compiler | 10 | 5 | 1000 | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3053 |
| 12 | `abstract_eval_copyast` | Compiler | 31 | 5 | 1125 | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3207 |
| 13 | `abstract_eval_globalref` | Compiler | 28 | 8 | 1358 | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3722 |
| 14 | `abstract_eval_isdefined_expr` | Compiler | 357 | 5 | 4298 | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3218 |
| 15 | `abstract_eval_special_value` | Compiler | 150 | 5 | 2045 | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:2955 |
| 16 | `abstract_eval_statement_expr` | Compiler | 252 | 5 | 5827 | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3386 |
| 17 | `abstract_eval_value` | Compiler | 109 | 5 | 1664 | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3000 |
| 18 | `add_edges!` | Compiler | 5 | 5 | 142 | ../usr/share/julia/Compiler/src/types.jl:507 |
| 19 | `add_edges_impl` | Compiler | 90 | 17 | 10812 | ../usr/share/julia/Compiler/src/stmtinfo.jl:482 |
| 20 | `adjust_effects` | Compiler | 384 | 13 | 5446 | ../usr/share/julia/Compiler/src/typeinfer.jl:400 |
| 21 | `all` | Base | 2 | 5 | 91 | anyall.jl:188 |
| 22 | `append!` | Base | 39 | 5 | 537 | array.jl:1352 |
| 23 | `append_c_digits` | Base | 59 | 5 | 866 | intfuncs.jl:870 |
| 24 | `append_c_digits_fast` | Base | 19 | 5 | 250 | intfuncs.jl:898 |
| 25 | `append_nine_digits` | Base | 84 | 5 | 1031 | intfuncs.jl:887 |
| 26 | `argtypes_to_type` | Compiler | 170 | 8 | 1593 | ../usr/share/julia/Compiler/src/typeutils.jl:51 |
| 27 | `bool_rt_to_conditional` | Compiler | 350 | 20 | 11214 | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3950 |
| 28 | `code_cache` | Compiler | 9 | 5 | 491 | ../usr/share/julia/Compiler/src/types.jl:495 |
| 29 | `collect_argtypes` | Compiler | 77 | 5 | 1203 | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3010 |
| 30 | `collect_const_args` | Compiler | 241 | 5 | 2099 | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:989 |
| 31 | `compute_edges!` | Compiler | 64 | 8 | 1228 | ../usr/share/julia/Compiler/src/typeinfer.jl:649 |
| 32 | `convert` | Base | 3 | 5 | 112 | essentials.jl:455 |
| 33 | `count_const_size` | Compiler | 328 | 5 | 2515 | ../usr/share/julia/Compiler/src/utilities.jl:32 |
| 34 | `datatype_fieldcount` | Base | 98 | 5 | 870 | runtime_internals.jl:1120 |
| 35 | `decode_effects` | Compiler | 121 | 5 | 812 | ../usr/share/julia/Compiler/src/effects.jl:351 |
| 36 | `error` | Base | 3 | 5 | 117 | error.jl:44 |
| 37 | `fill!` | Base | 153 | 5 | 825 | bitarray.jl:372 |
| 38 | `filter!` | Base | 120 | 8 | 1334 | array.jl:2978 |
| 39 | `intersect` | Compiler | 18 | 5 | 271 | ../usr/share/julia/Compiler/src/cicache.jl:37 |
| 40 | `invalid_wrap_err` | Base | 5 | 5 | 750 | array.jl:3158 |
| 41 | `is_all_const_arg` | Compiler | 251 | 5 | 2165 | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:975 |
| 42 | `is_identity_free_argtype` | Compiler | 38 | 5 | 542 | ../usr/share/julia/Compiler/src/typeutils.jl:348 |
| 43 | `is_mutation_free_argtype` | Compiler | 38 | 5 | 542 | ../usr/share/julia/Compiler/src/typeutils.jl:379 |
| 44 | `is_same_frame` | Compiler | 11 | 5 | 988 | ../usr/share/julia/Compiler/src/typeinfer.jl:783 |
| 45 | `isidentityfree` | Base | 79 | 5 | 866 | runtime_internals.jl:900 |
| 46 | `ismutationfree` | Base | 79 | 5 | 866 | runtime_internals.jl:880 |
| 47 | `length` | Compiler | 5 | 5 | 229 | ../usr/share/julia/Compiler/src/methodtable.jl:10 |
| 48 | `merge_call_chain!` | Compiler | 126 | 5 | 1660 | ../usr/share/julia/Compiler/src/typeinfer.jl:763 |
| 49 | `ndigits0z` | Base | 30 | 5 | 303 | intfuncs.jl:766 |
| 50 | `ndigits0znb` | Base | 45 | 5 | 437 | intfuncs.jl:684 |
| 51 | `resolve_call_cycle!` | Compiler | 123 | 11 | 2478 | ../usr/share/julia/Compiler/src/typeinfer.jl:798 |
| 52 | `reverse!` | Base | 137 | 5 | 710 | array.jl:2230 |
| 53 | `scan_leaf_partitions` | Compiler | 2 | 5 | 242 | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3706 |
| 54 | `ssa_def_slot` | Compiler | 228 | 5 | 2270 | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:1420 |
| 55 | `sym_in` | Base | 30 | 5 | 501 | tuple.jl:673 |
| 56 | `tname_intersect` | Compiler | 107 | 5 | 1041 | ../usr/share/julia/Compiler/src/typelimits.jl:720 |
| 57 | `type_more_complex` | Compiler | 305 | 8 | 3542 | ../usr/share/julia/Compiler/src/typelimits.jl:223 |
| 58 | `union!` | Base | 88 | 5 | 1275 | abstractset.jl:103 |
| 59 | `unionlen` | Base | 30 | 5 | 339 | runtime_internals.jl:1390 |
| 60 | `widenwrappedslotwrapper` | Compiler | 183 | 5 | 2154 | ../usr/share/julia/Compiler/src/typelattice.jl:227 |

## NEEDS_PATTERN (12)

These have stubs or validation errors but no C calls. Need codegen fixes.

| # | Function | Module | Stmts | Error | File |
|---|----------|--------|-------|-------|------|
| 1 | `<=` | Base | 3 | compiles but validation fails | bool.jl:161 |
| 2 | `abstract_eval_basic_statement` | Compiler | 496 | compiles but validation fails | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3790 |
| 3 | `abstract_eval_cfunction` | Compiler | 156 | compiles but validation fails | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:2935 |
| 4 | `abstract_eval_nonlinearized_foreigncall_name` | Compiler | 80 | compiles but validation fails | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3452 |
| 5 | `abstract_eval_phi` | Compiler | 92 | compiles but validation fails | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3523 |
| 6 | `isready` | Compiler | 13 | compiles but validation fails | ../usr/share/julia/Compiler/src/inferencestate.jl:1151 |
| 7 | `record_slot_assign!` | Compiler | 222 | compiles but validation fails | ../usr/share/julia/Compiler/src/typeinfer.jl:661 |
| 8 | `record_ssa_assign!` | Compiler | 532 | compiles but validation fails | ../usr/share/julia/Compiler/src/inferencestate.jl:789 |
| 9 | `stupdate!` | Compiler | 139 | compiles but validation fails | ../usr/share/julia/Compiler/src/typelattice.jl:722 |
| 10 | `tuple_tail_elem` | Compiler | 106 | compiles but validation fails | ../usr/share/julia/Compiler/src/typeutils.jl:219 |
| 11 | `type_annotate!` | Compiler | 845 | compiles but validation fails | ../usr/share/julia/Compiler/src/typeinfer.jl:712 |
| 12 | `update_bestguess!` | Compiler | 196 | compiles but validation fails | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:4070 |

## C_DEPENDENT (70)

These contain foreigncalls and need pure Julia replacements.

### C Calls by Category

| C Call | Purpose | Pure Julia Replacement | Complexity | Used By |
|--------|---------|----------------------|------------|---------|
| `Core.tuple(:mpfr_greater_p, Base.MPFR.libmpfr)` | BigFloat comparison | SKIP — only for timer comparison, can stub | SKIP | >, doworkloop |
| `jl_alloc_string` | Allocate a new String of given length | Wasm string handling — use WasmTarget string intrinsics | MEDIUM | _base, _resize!, bin, dec, ensureroom_reallocate, hex, oct, ... |
| `jl_argument_datatype` | Get DataType from argument type | Pure Julia: unwrap type wrappers to get DataType | LOW | argument_datatype |
| `jl_code_for_staged` | Get code for @generated function | Pre-expand at build time | HIGH | get_staged |
| `jl_engine_fulfill` | Fulfill inference engine reservation | SKIP — JIT engine management | SKIP | typeinf_edge |
| `jl_engine_reserve` | Reserve inference engine slot | SKIP — JIT engine management | SKIP | typeinf_edge |
| `jl_eqtable_get` | Get from equality-based table | Pure Julia: Dict lookup | LOW | validate_code! |
| `jl_field_index` | Get field index by name in a DataType | Pure Julia: findfirst(==(name), fieldnames(T)) | LOW — simple lookup | _fieldindex_nothrow, _getfield_tfunc |
| `jl_fill_codeinst` | Fill CodeInstance cache entry | SKIP — cache management, not needed for single-shot typeinf | SKIP | finishinfer! |
| `jl_find_free_typevars` | Find all free type variables in a type | Pure Julia: recursive walk collecting unbound TypeVars | MEDIUM — tree walk | sp_type_rewrap |
| `jl_genericmemory_copyto` | Copy memory block | Wasm: memory.copy instruction | LOW — existing Wasm instruction | #sizehint!#81, abstract_eval_new_opaque_closure, propagate_t... |
| `jl_genericmemory_to_string` | Convert Memory{UInt8} to String | Wasm: construct string from memory buffer bytes | MEDIUM | _base, bin, dec, hex, oct, print_to_string |
| `jl_get_fieldtypes` | Get field types of a DataType | Pure Julia: fieldtypes(T) | LOW — already a Julia function | _getfield_tfunc, valid_as_lattice |
| `jl_get_module_infer` | Get module's inference flag | Return constant (true) | LOW — trivial | typeinf_edge |
| `jl_get_world_counter` | Get current world age counter | Return build-time constant | LOW — trivial | edge_matches_sv, finish_cycle, finish_nocycle |
| `jl_has_free_typevars` | Check if type has free type variables | Pure Julia: recursive walk of type structure, check for unbound TypeVar | MEDIUM — tree walk | abstract_call_opaque_closure, abstract_eval_new, abstract_ev... |
| `jl_hrtime` | High-resolution timer | SKIP — only used for timing/profiling | SKIP | finish_cycle, typeinf, typeinf_edge |
| `jl_idset_peek_bp` | Peek at IdSet backpointer | Pure Julia: Dict/Set equivalent lookup | MEDIUM | cycle_fix_limited, issubset, push! |
| `jl_idset_pop` | Pop from IdSet | Pure Julia: Dict/Set equivalent pop | MEDIUM | cycle_fix_limited |
| `jl_idset_put_idx` | Insert at index into IdSet | Pure Julia: Dict/Set equivalent insert | MEDIUM | push! |
| `jl_idset_put_key` | Insert key into IdSet | Pure Julia: Dict/Set equivalent insert | MEDIUM | push! |
| `jl_instantiate_type_in_env` | Substitute type variables with values | Pure Julia: recursive type substitution | MEDIUM | sp_type_rewrap |
| `jl_ir_nslots` | Get number of slots in IR | Pre-compute at build time | LOW | may_invoke_generator |
| `jl_ir_slotflag` | Get slot flags in IR | Pre-compute at build time | LOW | may_invoke_generator |
| `jl_is_assertsbuild` | Check if assertions enabled in build | Return constant (false) | LOW — trivial | maybe_validate_code |
| `jl_matching_methods` | Method dispatch lookup | DictMethodTable — Dict{Type, MethodLookupResult} pre-populated at build time | HIGH | may_invoke_generator |
| `jl_mi_cache_insert` | Insert into MethodInstance cache | SKIP — cache management | SKIP | setindex! |
| `jl_module_globalref` | Get GlobalRef from module | Pre-resolve at build time | MEDIUM | abstract_eval_foreigncall, abstract_eval_value_expr |
| `jl_new_structt` | Construct struct from tuple | Wasm: struct_new instruction | LOW | abstract_eval_splatnew |
| `jl_new_structv` | Construct struct from values | Wasm: struct_new instruction | LOW — codegen already handles this | abstract_eval_new |
| `jl_normalize_to_compilable_sig` | Normalize method signature for compilation | DictMethodTable — pre-normalized at build time | MEDIUM | _add_edges_impl, abstract_call_method, method_for_inference_... |
| `jl_pchar_to_string` | Convert C char* to Julia String | Wasm: string construction from pointer — may need stub | MEDIUM | print_to_string |
| `jl_promote_ci_to_current` | Promote CodeInstance to current world | SKIP — cache management | SKIP | finish_nocycle |
| `jl_promote_cis_to_current` | Promote CodeInstances to current world | SKIP — cache management | SKIP | finish_cycle |
| `jl_push_newly_inferred` | Push to newly-inferred worklist | SKIP — JIT compilation management | SKIP | setindex! |
| `jl_rethrow` | Rethrow current exception | Wasm: rethrow instruction | LOW | rethrow |
| `jl_rettype_inferred` | Get inferred return type from cache | DictMethodTable — pre-compute at build time | MEDIUM | cache_result!, typeinf_edge |
| `jl_specializations_get_linfo` | Get MethodInstance for specialization | DictMethodTable — pre-resolved at build time | MEDIUM | _add_edges_impl, method_for_inference_heuristics, typeinf_ed... |
| `jl_stored_inline` | Check if field is stored inline | Pure Julia: isprimitivetype or check DataType.layout | LOW | is_undefref_fieldtype |
| `jl_string_ptr` | Get pointer to string data | SKIP — only used for debug/timing output | SKIP | print, print_to_string, typeinf |
| `jl_string_to_genericmemory` | Convert String to Memory{UInt8} | Wasm: extract string bytes into memory buffer | MEDIUM | _base, _resize!, bin, dec, ensureroom_reallocate, hex, oct, ... |
| `jl_type_intersection` | Compute T1 ∩ T2 (type intersection) | Pre-compute at build time for known types, or implement subset of typeintersect in pure Julia | HIGH — ~1000 lines of C in subtype.c | _getfield_tfunc, abstract_call_opaque_closure, abstract_eval... |
| `jl_type_intersection_with_env` | Type intersection + capture environment | Same strategy as jl_type_intersection | HIGH | abstract_call_method, normalize_typevars |
| `jl_type_unionall` | Construct UnionAll type | Pure Julia: UnionAll(tvar, body) — this is just struct construction | LOW — simple constructor | _getfield_tfunc, _limit_type_size, abstract_call_opaque_clos... |
| `jl_types_equal` | Check T1 === T2 (type equality) | Pure Julia: T1 === T2 (Julia's === already works for types) | LOW — trivial | abstract_call_method, is_lattice_equal, issimplertype, tmerg... |
| `jl_uv_putb` | Write byte to UV stream | SKIP — only used for debug output | SKIP | println |
| `jl_uv_puts` | Write string to UV stream | SKIP — only used for debug output | SKIP | print, typeinf |
| `jl_value_ptr` | Get raw pointer to Julia value | SKIP/stub — only for identity comparison | LOW | get_staged, may_invoke_generator, push!, tmerge |
| `memcmp` | Compare memory blocks | Wasm: byte-by-byte comparison loop | LOW | == |
| `memmove` | Move memory block (overlapping) | Wasm: memory.copy instruction | LOW | _resize!, ensureroom_slowpath, unsafe_write |
| `memset` | Fill memory with byte value | Wasm: memory.fill instruction | LOW | empty! |

### Replacement Complexity Summary

| Complexity | Count | Strategy |
|------------|-------|----------|
| **SKIP** | 12 | Strip/stub — not needed for single-shot typeinf |
| **LOW** | 20 | Trivial replacement — constants, simple lookups |
| **MEDIUM** | 15 | Moderate — tree walks, Dict operations, string ops |
| **HIGH** | 5 | Significant — type intersection, method tables, generated functions |

### All C_DEPENDENT Functions

| # | Function | Module | Stmts | C Calls | File |
|---|----------|--------|-------|---------|------|
| 1 | `#sizehint!#81` | Base | 110 | jl_genericmemory_copyto | array.jl:1528 |
| 2 | `==` | Base | 211 | memcmp | abstractarray.jl:3029 |
| 3 | `>` | Base.MPFR | 43 | Core.tuple(:mpfr_greater_p, Base.MPFR.libmpfr) | mpfr.jl:994 |
| 4 | `_add_edges_impl` | Compiler | 820 | jl_normalize_to_compilable_sig, jl_specializations_get_linfo | ../usr/share/julia/Compiler/src/stmtinfo.jl:48 |
| 5 | `_base` | Base | 181 | jl_alloc_string, jl_genericmemory_to_string, jl_string_to_ge... | intfuncs.jl:948 |
| 6 | `_fieldindex_nothrow` | Base | 4 | jl_field_index | runtime_internals.jl:1099 |
| 7 | `_getfield_tfunc` | Compiler | 855 | jl_field_index, jl_get_fieldtypes, jl_type_unionall, jl_type... | ../usr/share/julia/Compiler/src/tfuncs.jl:1211 |
| 8 | `_limit_type_size` | Compiler | 495 | jl_type_unionall | ../usr/share/julia/Compiler/src/typelimits.jl:86 |
| 9 | `_resize!` | Base | 183 | jl_alloc_string, jl_string_to_genericmemory, memmove | iobuffer.jl:535 |
| 10 | `abstract_call_method` | Compiler | 398 | jl_normalize_to_compilable_sig, jl_types_equal, jl_type_inte... | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:600 |
| 11 | `abstract_call_opaque_closure` | Compiler | 111 | jl_type_unionall, jl_type_intersection, jl_has_free_typevars | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:2786 |
| 12 | `abstract_eval_foreigncall` | Compiler | 282 | jl_module_globalref | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3494 |
| 13 | `abstract_eval_new` | Compiler | 802 | jl_has_free_typevars, jl_new_structv | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3069 |
| 14 | `abstract_eval_new_opaque_closure` | Compiler | 427 | jl_genericmemory_copyto | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3171 |
| 15 | `abstract_eval_splatnew` | Compiler | 499 | jl_has_free_typevars, jl_new_structt | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3141 |
| 16 | `abstract_eval_throw_undef_if_not` | Compiler | 117 | jl_type_intersection | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3337 |
| 17 | `abstract_eval_value_expr` | Compiler | 153 | jl_module_globalref | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:2986 |
| 18 | `argument_datatype` | Base | 4 | jl_argument_datatype | runtime_internals.jl:1114 |
| 19 | `bin` | Base | 101 | jl_alloc_string, jl_string_to_genericmemory, jl_genericmemor... | intfuncs.jl:813 |
| 20 | `cache_result!` | Compiler | 46 | jl_rettype_inferred | ../usr/share/julia/Compiler/src/typeinfer.jl:322 |
| 21 | `cycle_fix_limited` | Compiler | 153 | jl_idset_peek_bp, jl_idset_pop | ../usr/share/julia/Compiler/src/typeinfer.jl:338 |
| 22 | `dec` | Base | 37 | jl_alloc_string, jl_string_to_genericmemory, jl_genericmemor... | intfuncs.jl:916 |
| 23 | `doworkloop` | Compiler | 219 | Core.tuple(:mpfr_greater_p, Base.MPFR.libmpfr) | ../usr/share/julia/Compiler/src/inferencestate.jl:1199 |
| 24 | `edge_matches_sv` | Compiler | 438 | jl_get_world_counter | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:738 |
| 25 | `empty!` | Base | 82 | memset | idset.jl:107 |
| 26 | `ensureroom_reallocate` | Base | 35 | jl_alloc_string, jl_string_to_genericmemory | iobuffer.jl:617 |
| 27 | `ensureroom_slowpath` | Base | 393 | memmove | iobuffer.jl:626 |
| 28 | `finish_cycle` | Compiler | 634 | jl_hrtime, jl_get_world_counter, jl_promote_cis_to_current | ../usr/share/julia/Compiler/src/typeinfer.jl:220 |
| 29 | `finish_nocycle` | Compiler | 160 | jl_get_world_counter, jl_promote_ci_to_current | ../usr/share/julia/Compiler/src/typeinfer.jl:198 |
| 30 | `finishinfer!` | Compiler | 513 | jl_fill_codeinst | ../usr/share/julia/Compiler/src/typeinfer.jl:467 |
| 31 | `get_staged` | Compiler | 36 | jl_code_for_staged, jl_value_ptr | ../usr/share/julia/Compiler/src/utilities.jl:83 |
| 32 | `hex` | Base | 87 | jl_alloc_string, jl_string_to_genericmemory, jl_genericmemor... | intfuncs.jl:924 |
| 33 | `is_derived_type` | Compiler | 109 | jl_has_free_typevars | ../usr/share/julia/Compiler/src/typelimits.jl:37 |
| 34 | `is_lattice_equal` | Compiler | 277 | jl_types_equal | ../usr/share/julia/Compiler/src/typelattice.jl:549 |
| 35 | `is_undefref_fieldtype` | Compiler | 16 | jl_has_free_typevars, jl_stored_inline | ../usr/share/julia/Compiler/src/tfuncs.jl:1323 |
| 36 | `issimpleenoughtype` | Compiler | 109 | jl_has_free_typevars | ../usr/share/julia/Compiler/src/typelimits.jl:312 |
| 37 | `issimplertype` | Compiler | 503 | jl_types_equal | ../usr/share/julia/Compiler/src/typelimits.jl:331 |
| 38 | `issubset` | Base | 99 | jl_idset_peek_bp | abstractset.jl:329 |
| 39 | `may_invoke_generator` | Base | 382 | jl_value_ptr, jl_matching_methods, jl_ir_nslots, jl_ir_slotf... | runtime_internals.jl:1473 |
| 40 | `maybe_validate_code` | Compiler | 115 | jl_is_assertsbuild | ../usr/share/julia/Compiler/src/validation.jl:69 |
| 41 | `method_for_inference_heuristics` | Compiler | 48 | jl_normalize_to_compilable_sig, jl_specializations_get_linfo | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:784 |
| 42 | `most_general_argtypes` | Compiler | 409 | jl_has_free_typevars, jl_type_unionall | ../usr/share/julia/Compiler/src/inferenceresult.jl:127 |
| 43 | `normalize_typevars` | Base | 17 | jl_type_intersection_with_env | runtime_internals.jl:1556 |
| 44 | `oct` | Base | 58 | jl_alloc_string, jl_string_to_genericmemory, jl_genericmemor... | intfuncs.jl:840 |
| 45 | `opaque_closure_tfunc` | Compiler | 58 | jl_type_unionall | ../usr/share/julia/Compiler/src/tfuncs.jl:2181 |
| 46 | `print` | Base | 14 | jl_string_ptr | strings/io.jl:32 |
| 47 | `print` | Core | 15 | jl_string_ptr, jl_uv_puts | boot.jl:769 |
| 48 | `print_to_string` | Base | 167 | jl_alloc_string, jl_string_to_genericmemory, jl_string_ptr, ... | strings/io.jl:140 |
| 49 | `println` | Core | 7 | jl_uv_putb | boot.jl:771 |
| 50 | `propagate_to_error_handler!` | Compiler | 491 | jl_genericmemory_copyto | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:4136 |
| 51 | `push!` | Base | 93 | jl_idset_peek_bp, jl_value_ptr, jl_idset_put_key, jl_idset_p... | idset.jl:48 |
| 52 | `rethrow` | Base | 2 | jl_rethrow | error.jl:71 |
| 53 | `rewrap_unionall` | Base | 75 | jl_type_unionall | essentials.jl:541 |
| 54 | `setindex!` | Compiler | 16 | jl_push_newly_inferred, jl_mi_cache_insert | ../usr/share/julia/Compiler/src/cicache.jl:14 |
| 55 | `sp_type_rewrap` | Compiler | 334 | jl_instantiate_type_in_env, jl_type_unionall, jl_has_free_ty... | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:2893 |
| 56 | `subst_trivial_bounds` | Base | 48 | jl_type_unionall | runtime_internals.jl:1533 |
| 57 | `tmeet` | Compiler | 166 | jl_has_free_typevars, jl_type_intersection | ../usr/share/julia/Compiler/src/typelattice.jl:597 |
| 58 | `tmerge` | Compiler | 181 | jl_value_ptr, jl_types_equal | ../usr/share/julia/Compiler/src/typelimits.jl:485 |
| 59 | `tmerge_partial_struct` | Compiler | 599 | jl_type_intersection | ../usr/share/julia/Compiler/src/typelimits.jl:587 |
| 60 | `tmerge_types_slow` | Compiler | 1557 | jl_type_unionall, jl_has_free_typevars | ../usr/share/julia/Compiler/src/typelimits.jl:747 |
| 61 | `tuple_tfunc` | Compiler | 806 | jl_type_intersection | ../usr/share/julia/Compiler/src/tfuncs.jl:1992 |
| 62 | `tuplemerge` | Compiler | 314 | jl_has_free_typevars | ../usr/share/julia/Compiler/src/typelimits.jl:864 |
| 63 | `typeinf` | Compiler | 531 | jl_hrtime, jl_string_ptr, jl_uv_puts | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:4465 |
| 64 | `typeinf_edge` | Compiler | 1308 | jl_normalize_to_compilable_sig, jl_specializations_get_linfo... | ../usr/share/julia/Compiler/src/typeinfer.jl:895 |
| 65 | `typeinf_local` | Compiler | 4844 | jl_genericmemory_copyto, jl_type_intersection | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:4169 |
| 66 | `union_count_abstract` | Compiler | 163 | jl_has_free_typevars | ../usr/share/julia/Compiler/src/typelimits.jl:309 |
| 67 | `unsafe_write` | Base | 135 | memmove | iobuffer.jl:822 |
| 68 | `valid_as_lattice` | Compiler | 65 | jl_get_fieldtypes | ../usr/share/julia/Compiler/src/typeutils.jl:103 |
| 69 | `validate_code!` | Compiler | 1386 | jl_eqtable_get | ../usr/share/julia/Compiler/src/validation.jl:115 |
| 70 | `widenreturn_partials` | Compiler | 268 | jl_genericmemory_copyto | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3996 |

## OPTIMIZER_SKIP (2)

Binaryen handles optimization. These are not compiled to Wasm.

| # | Function | Module | Stmts | File |
|---|----------|--------|-------|------|
| 1 | `finish!` | Compiler | 323 | ../usr/share/julia/Compiler/src/typeinfer.jl:94 |
| 2 | `optimize` | Compiler | 5 | ../usr/share/julia/Compiler/src/optimize.jl:1001 |

## COMPILE_ERROR (27)

Cannot resolve function or parse signature. Needs manual investigation.

| # | Function | Module | Signature | Error | File |
|---|----------|--------|-----------|-------|------|
| 1 | `#argtypes_to_type##0` | Compiler | `Tuple{Any}` | Function not found in module | ../usr/share/julia/Compiler/src/typeutils.jl:52 |
| 2 | `InliningState` | Compiler | `Tuple{Vector{Any}, UInt64, Compiler.AbstractInterpreter} | Tuple{Compiler.InferenceState, Compiler.AbstractInterpreter}` | Cannot parse signature: Tuple{Vector{Any}, UInt64, Compiler.... | ../usr/share/julia/Compiler/src/optimize.jl:147 |
| 3 | `_` | Compiler | `Tuple{Bool, Type{Compiler.Conditional}, Int64, Any, Any}` | Function not found in module | ../usr/share/julia/Compiler/src/typelattice.jl:39 |
| 4 | `__limit_type_size` | Compiler | `Tuple{Any, Any, Core.SimpleVector, Int64, Int64}` | UndefVarError: `T` not defined in static parameter matching
... | ../usr/share/julia/Compiler/src/typelimits.jl:192 |
| 5 | `_issubconditional` | Compiler | `Tuple{Compiler.InterConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}, Core.InterConditional, Core.InterConditional, Bool} | Tuple{Compiler.ConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}, Compiler.Conditional, Compiler.Conditional, Bool}` | Cannot parse signature: Tuple{Compiler.InterConditionalsLatt... | ../usr/share/julia/Compiler/src/typelattice.jl:264 |
| 6 | `_typename` | Compiler | `Tuple{Any} | Tuple{Type}` | Cannot parse signature: Tuple{Any} | Tuple{Type} | ../usr/share/julia/Compiler/src/typeutils.jl:217 |
| 7 | `abstract_call` | Compiler | `Tuple{Compiler.AbstractInterpreter, Compiler.ArgInfo, Compiler.StatementState, Compiler.InferenceState} | Tuple{Compiler.AbstractInterpreter, Compiler.ArgInfo, Compiler.StmtInfo, Compiler.InferenceState}` | Cannot parse signature: Tuple{Compiler.AbstractInterpreter, ... | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3037 |
| 8 | `add_invoke_edge!` | Compiler | `Tuple{Vector{Any}, Any, Union{Method, Core.MethodInstance}} | Tuple{Vector{Any}, Any, Core.CodeInstance}` | Cannot parse signature: Tuple{Vector{Any}, Any, Union{Method... | ../usr/share/julia/Compiler/src/stmtinfo.jl:322 |
| 9 | `apply_refinement!` | Compiler | `Tuple{Compiler.InferenceLattice{Compiler.ConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}}, Core.SlotNumber, Any, Vector{Compiler.VarState}, Compiler.StateUpdate} | Tuple{Compiler.InferenceLattice{Compiler.ConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}}, Core.SlotNumber, Any, Vector{Compiler.VarState}, Nothing}` | Cannot parse signature: Tuple{Compiler.InferenceLattice{Comp... | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:4416 |
| 10 | `assign_parentchild!` | Compiler | `Tuple{Compiler.InferenceState, Compiler.InferenceState} | Tuple{Compiler.IRInterpretationState, Compiler.InferenceState}` | Cannot parse signature: Tuple{Compiler.InferenceState, Compi... | ../usr/share/julia/Compiler/src/inferencestate.jl:934 |
| 11 | `getfield_tfunc` | Compiler | `Tuple{Compiler.PartialsLattice{Compiler.ConstsLattice}, Any, Any} | Tuple{Compiler.InferenceLattice{Compiler.InterConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}}, Any, Any} | Tuple{Compiler.InferenceLattice{Compiler.ConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}}, Any, Any}` | Cannot parse signature: Tuple{Compiler.PartialsLattice{Compi... | ../usr/share/julia/Compiler/src/tfuncs.jl:1125 |
| 12 | `instanceof_tfunc` | Compiler | `Tuple{Any, Bool} | Tuple{Any}` | Cannot parse signature: Tuple{Any, Bool} | Tuple{Any} | ../usr/share/julia/Compiler/src/tfuncs.jl:104 |
| 13 | `issubconditional` | Compiler | `Tuple{Compiler.InterConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}, Core.InterConditional, Core.InterConditional} | Tuple{Compiler.ConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}, Compiler.Conditional, Compiler.Conditional}` | Cannot parse signature: Tuple{Compiler.InterConditionalsLatt... | ../usr/share/julia/Compiler/src/typelattice.jl:262 |
| 14 | `limit_type_size` | Compiler | `Tuple{Any, Any, Any, Int64, Int64}` | UndefVarError: `T` not defined in static parameter matching
... | ../usr/share/julia/Compiler/src/typelimits.jl:17 |
| 15 | `ndigits0zpb` | Base | `Tuple{UInt64, Int64} | Tuple{Int64, Int64}` | Cannot parse signature: Tuple{UInt64, Int64} | Tuple{Int64, ... | intfuncs.jl:702 |
| 16 | `overflow_case` | Base | `Tuple{Int64, Int64}` | Function not found in module | range.jl:364 |
| 17 | `resize!` | Base | `Tuple{Vector{Compiler.CurrentState}, Int64} | Tuple{Vector{Union{Compiler.IRInterpretationState, Compiler.InferenceState}}, Int64} | Tuple{Vector{Any}, Int64}` | Cannot parse signature: Tuple{Vector{Compiler.CurrentState},... | array.jl:1478 |
| 18 | `return_cached_result` | Compiler | `Tuple{Compiler.AbstractInterpreter, Method, Core.CodeInstance, Compiler.InferenceState, Bool, Bool} | Tuple{Compiler.NativeInterpreter, Method, Core.CodeInstance, Compiler.InferenceState, Bool, Bool}` | Cannot parse signature: Tuple{Compiler.AbstractInterpreter, ... | ../usr/share/julia/Compiler/src/typeinfer.jl:827 |
| 19 | `throw_boundserror` | Base | `Tuple{Vector{Core.TypeName}, Tuple{Int64}} | Tuple{Vector{Tuple{Int64, Int64}}, Tuple{Int64}} | Tuple{BitVector, Tuple{Int64}} | Tuple{Vector{Compiler.TryCatchFrame}, Tuple{Int64}} | Tuple{Vector{Union{Compiler.IRInterpretationState, Compiler.InferenceState}}, Tuple{Int64}} | Tuple{Vector{Compiler.VarState}, Tuple{Int64}} | Tuple{Vector{Compiler.CurrentState}, Tuple{Int64}} | Tuple{Vector{BitSet}, Tuple{Int64}} | Tuple{Vector{Compiler.InvalidCodeError}, Tuple{Int64}} | Tuple{Vector{Compiler.MethodMatchInfo}, Tuple{Int64}} | Tuple{Vector{Any}, Tuple{Int64}} | Tuple{Vector{Union{Nothing, Vector{Compiler.VarState}}}, Tuple{Int64}} | Tuple{Vector{UInt8}, Tuple{Int64}} | Tuple{Vector{Union{Nothing, Core.CodeInstance}}, Tuple{Int64}} | Tuple{Vector{Bool}, Tuple{Int64}} | Tuple{Vector{UInt16}, Tuple{Int64}} | Tuple{Vector{Any}, Tuple{UnitRange{Int64}}} | Tuple{Vector{Int64}, Tuple{Int64}} | Tuple{Vector{Tuple{Compiler.InferenceState, Int64}}, Tuple{Int64}} | Tuple{UnitRange{Int64}, Int64} | Tuple{Vector{UInt32}, Tuple{Int64}} | Tuple{Vector{UInt64}, Tuple{Int64}} | Tuple{Vector{Compiler.CallInfo}, Tuple{Int64}} | Tuple{Vector{Compiler.BasicBlock}, Tuple{Int64}}` | Cannot parse signature: Tuple{Vector{Core.TypeName}, Tuple{I... | essentials.jl:15 |
| 20 | `throw_inexacterror` | Core | `Tuple{Symbol, Type, UInt64} | Tuple{Symbol, Type, Int128} | Tuple{Symbol, Type, UInt32} | Tuple{Symbol, Type, Int64}` | Cannot parse signature: Tuple{Symbol, Type, UInt64} | Tuple{... | boot.jl:815 |
| 21 | `tmerge_limited` | Compiler | `Tuple{Compiler.InferenceLattice{Compiler.ConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}}, Any, Any} | Tuple{Compiler.InferenceLattice{Compiler.InterConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}}, Any, Any}` | Cannot parse signature: Tuple{Compiler.InferenceLattice{Comp... | ../usr/share/julia/Compiler/src/typelimits.jl:434 |
| 22 | `update_cycle_worklists!` | Compiler | `Tuple{Compiler.var"#update_exc_bestguess!##0#update_exc_bestguess!##1", Compiler.InferenceState} | Tuple{Compiler.var"#typeinf_local##0#typeinf_local##1", Compiler.InferenceState}` | Cannot parse signature: Tuple{Compiler.var"#update_exc_bestg... | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:4149 |
| 23 | `update_exc_bestguess!` | Compiler | `Tuple{Compiler.AbstractInterpreter, Any, Compiler.InferenceState} | Tuple{Compiler.AbstractInterpreter, DataType, Compiler.InferenceState}` | Cannot parse signature: Tuple{Compiler.AbstractInterpreter, ... | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:4113 |
| 24 | `widenconst` | Compiler | `Tuple{Compiler.LimitedAccuracy} | Tuple{Any}` | Cannot parse signature: Tuple{Compiler.LimitedAccuracy} | Tu... | ../usr/share/julia/Compiler/src/typelattice.jl:695 |
| 25 | `widenreturn` | Compiler | `Tuple{Compiler.PartialsLattice{Compiler.ConstsLattice}, Any, Compiler.BestguessInfo} | Tuple{Compiler.AbstractLattice, Any, Compiler.BestguessInfo} | Tuple{Any, Compiler.BestguessInfo} | Tuple{Compiler.ConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}, Any, Compiler.BestguessInfo} | Tuple{Compiler.InferenceLattice{Compiler.ConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}}, Any, Compiler.BestguessInfo}` | Cannot parse signature: Tuple{Compiler.PartialsLattice{Compi... | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3913 |
| 26 | `widenreturn_noslotwrapper` | Compiler | `Tuple{Compiler.PartialsLattice{Compiler.ConstsLattice}, Any, Compiler.BestguessInfo} | Tuple{Compiler.ConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}, Any, Compiler.BestguessInfo} | Tuple{Compiler.InferenceLattice{Compiler.ConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}}, Any, Compiler.BestguessInfo}` | Cannot parse signature: Tuple{Compiler.PartialsLattice{Compi... | ../usr/share/julia/Compiler/src/abstractinterpretation.jl:3993 |
| 27 | `⊑` | Compiler | `Tuple{Compiler.InferenceLattice{Compiler.InterConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}}, Any, Any} | Tuple{Compiler.PartialsLattice{Compiler.ConstsLattice}, Any, Any} | Tuple{Compiler.InferenceLattice{Compiler.ConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}}, Any, Any} | Tuple{Compiler.ConstsLattice, Any, Any}` | Cannot parse signature: Tuple{Compiler.InferenceLattice{Comp... | ../usr/share/julia/Compiler/src/typelattice.jl:432 |

## Recommendations for PURE-3002 (DictMethodTable Build)

### Priority Order for C Call Replacement

1. **SKIP calls (strip/stub):** jl_hrtime, jl_uv_puts, jl_string_ptr, jl_fill_codeinst,
   jl_promote_ci_to_current, jl_engine_reserve/fulfill, jl_mi_cache_insert,
   jl_push_newly_inferred — these are timer/debug/cache management, not needed for typeinf

2. **LOW complexity:** jl_get_world_counter (constant), jl_types_equal (===),
   jl_type_unionall (constructor), jl_field_index (findfirst), memcmp/memmove/memset (Wasm ops)

3. **MEDIUM complexity:** jl_has_free_typevars (tree walk), jl_instantiate_type_in_env (substitution),
   IdSet operations (Dict equivalent), string operations (Wasm string intrinsics)

4. **HIGH complexity (THE blockers):**
   - `jl_matching_methods` — DictMethodTable (THE architectural change)
   - `jl_type_intersection` — ~1000 lines of C in subtype.c, need subset or pre-compute
   - `jl_code_for_staged` — @generated function expansion, pre-expand at build time

### Key Architecture Decision

For the "1+1" playground use case, the type system operations are limited:
- `+(Int64, Int64)` — intersection with `Tuple{Int64, Int64}` is just itself
- `sin(Float64)` — intersection with `Tuple{Float64}` is just itself

**Strategy: Pre-compute ALL type intersections at build time.**
For each method in DictMethodTable, pre-compute and store the intersection result.
The Dict key IS the answer — no runtime intersection needed for known types.

This means `jl_type_intersection` can return a pre-computed result from the Dict,
rather than implementing the full intersection algorithm.

