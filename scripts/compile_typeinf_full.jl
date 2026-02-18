#!/usr/bin/env julia
# PURE-4152: Compile full typeinf.wasm — Core.Compiler.typeinf + Julia reimplementations
#
# Strategy:
# 1. Load all typeinf infrastructure (stubs, reimpl, DictMethodTable, WasmInterpreter)
# 2. compile_multi with:
#    - Core.Compiler.typeinf(WasmInterpreter, InferenceState) as entry point
#    - All 30 reimplementation functions (subtype + intersection + matching)
#    - Test wrapper functions (for Node.js CORRECT verification in PURE-4153)
# 3. Validate with wasm-tools
# 4. Report function count and module size

using WasmTarget

# Load all typeinf infrastructure
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))

using Core.Compiler: InferenceState

println("=" ^ 80)
println("PURE-4152: Full typeinf.wasm compilation")
println("=" ^ 80)

# ─── Phase 1: Try basic compile of typeinf with WasmInterpreter ───
println("\n--- Phase 1: Single compile of typeinf(WasmInterpreter, InferenceState) ---")

try
    bytes = compile(Core.Compiler.typeinf, (WasmInterpreter, InferenceState))
    println("  compile SUCCESS: $(length(bytes)) bytes")
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    nfuncs = try
        parse(Int, readchomp(`bash -c "wasm-tools print $tmpf 2>/dev/null | grep -c '(func (;'"` ))
    catch; 0 end
    println("  Functions: $nfuncs")
    try
        run(`wasm-tools validate --features=gc $tmpf`)
        println("  VALIDATES ✓")
    catch
        valerr = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf 2>&1 || true"`) catch; "" end
        println("  VALIDATE_ERROR: $(first(valerr, 300))")
    end
    rm(tmpf, force=true)
catch e
    println("  COMPILE_ERROR: $(first(sprint(showerror, e), 300))")
end

# ─── Phase 2: compile_multi with reimpl functions + typeinf entry point ───
println("\n--- Phase 2: compile_multi with all functions ---")

# All reimplementation functions (from compile_reimpl.jl / test_reimpl_node.jl)
subtype_functions = [
    (wasm_subtype, (Any, Any)),
    (_subtype, (Any, Any, SubtypeEnv, Int)),
    (lookup, (SubtypeEnv, TypeVar)),
    (VarBinding, (TypeVar, Bool)),
    (_var_lt, (VarBinding, Any, SubtypeEnv, Int)),
    (_var_gt, (VarBinding, Any, SubtypeEnv, Int)),
    (_subtype_var, (VarBinding, Any, SubtypeEnv, Bool, Int)),
    (_record_var_occurrence, (VarBinding, SubtypeEnv, Int)),
    (_subtype_unionall, (Any, UnionAll, SubtypeEnv, Bool, Int)),
    (_subtype_inner, (Any, Any, SubtypeEnv, Bool, Int)),
    (_is_leaf_bound, (Any,)),
    (_type_contains_var, (Any, TypeVar)),
    (_subtype_check, (Any, Any)),
    (_subtype_datatypes, (DataType, DataType, SubtypeEnv, Int)),
    (_forall_exists_equal, (Any, Any, SubtypeEnv)),
    (_tuple_subtype_env, (DataType, DataType, SubtypeEnv, Int)),
    (_subtype_tuple_param, (Any, Any, SubtypeEnv)),
    (_datatype_subtype, (DataType, DataType)),
    (_tuple_subtype, (DataType, DataType)),
    (_subtype_param, (Any, Any)),
]

intersection_functions = [
    (wasm_type_intersection, (Any, Any)),
    (_no_free_typevars, (Any,)),
    (_intersect, (Any, Any, Int)),
    (_simple_join, (Any, Any)),
    (_intersect_datatypes, (DataType, DataType, Int)),
    (_intersect_tuple, (DataType, DataType, Int)),
    (_intersect_same_name, (DataType, DataType, Int)),
    (_intersect_invariant, (Any, Any)),
    (_intersect_different_names, (DataType, DataType, Int)),
]

matching_functions = [
    (wasm_matching_methods, (Any,)),
]

# Core.Compiler.typeinf entry point with WasmInterpreter
typeinf_entry = [
    (Core.Compiler.typeinf, (WasmInterpreter, InferenceState)),
]

all_functions = vcat(subtype_functions, intersection_functions, matching_functions, typeinf_entry)

println("  Total explicit functions: $(length(all_functions))")

try
    bytes = compile_multi(all_functions)
    println("  compile_multi SUCCESS: $(length(bytes)) bytes")
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    nfuncs = try
        parse(Int, readchomp(`bash -c "wasm-tools print $tmpf 2>/dev/null | grep -c '(func (;'"` ))
    catch; 0 end
    println("  Functions: $nfuncs")
    try
        run(`wasm-tools validate --features=gc $tmpf`)
        println("  VALIDATES ✓")
    catch
        valerr = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf 2>&1 || true"`) catch; "" end
        println("  VALIDATE_ERROR: $(first(valerr, 300))")
    end

    # Save for analysis
    outpath = joinpath(@__DIR__, "typeinf_full.wasm")
    write(outpath, bytes)
    println("  Saved to scripts/typeinf_full.wasm")
    rm(tmpf, force=true)
catch e
    println("  COMPILE_ERROR: $(first(sprint(showerror, e), 300))")
    bt = catch_backtrace()
    println("  Backtrace: $(first(sprint(showerror, e, bt), 500))")
end

println("\nDone.")
