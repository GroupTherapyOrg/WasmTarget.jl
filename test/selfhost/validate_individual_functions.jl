# validate_individual_functions.jl — CG-003a: Catalog validation errors
#
# RESEARCH ONLY: Compile each of the 51 functions INDIVIDUALLY, validate each,
# then compare standalone vs combined module validation.
#
# Run: julia +1.12 --project=. test/selfhost/validate_individual_functions.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, compile_module_from_ir_frozen, compile_module_from_ir_frozen_no_dict,
                  to_bytes, to_bytes_no_dict,
                  CompilationContext, WasmModule, TypeRegistry, FunctionRegistry,
                  FrozenCompilationState, WasmValType, BasicBlock,
                  compile_const_value, get_concrete_wasm_type,
                  encode_leb128_signed, encode_leb128_unsigned,
                  copy_wasm_module, copy_type_registry
using Dates

println("=" ^ 70)
println("CG-003a: Catalog validation errors — individual vs combined")
println("=" ^ 70)

# Same function list as build_codegen_full_module.jl
all_functions = Tuple{Any, Tuple, String, Bool}[
    # Level 0: Entry points
    (compile_module_from_ir_frozen, (Vector, FrozenCompilationState), "compile_module_from_ir_frozen", false),
    (compile_module_from_ir_frozen_no_dict, (Vector, FrozenCompilationState), "compile_module_from_ir_frozen_no_dict", false),
    (to_bytes_no_dict, (WasmModule,), "to_bytes_no_dict", false),
    # Level 1: Direct callees
    (copy_wasm_module, (WasmModule,), "copy_wasm_module", false),
    (copy_type_registry, (TypeRegistry,), "copy_type_registry", false),
    (WasmTarget.register_struct_type!, (WasmModule, TypeRegistry, Type), "register_struct_type!", false),
    (get_concrete_wasm_type, (Type, WasmModule, TypeRegistry), "get_concrete_wasm_type", false),
    (WasmTarget.needs_anyref_boxing, (Union,), "needs_anyref_boxing", false),
    (WasmTarget.populate_type_constant_globals!, (WasmModule, TypeRegistry), "populate_type_constant_globals!", false),
    # Level 2: Code generation core
    (WasmTarget.generate_body, (CompilationContext,), "generate_body", false),
    (WasmTarget.generate_structured, (CompilationContext, Vector{BasicBlock}), "generate_structured", false),
    (WasmTarget.generate_block_code, (CompilationContext, BasicBlock), "generate_block_code", false),
    (WasmTarget.analyze_blocks, (Vector{Any},), "analyze_blocks", false),
    # Level 3: Statement compilation
    (WasmTarget.compile_statement, (Expr, Int64, CompilationContext), "compile_statement", true),
    # Level 4: Call/invoke dispatchers
    (WasmTarget.compile_call, (Expr, Int64, CompilationContext), "compile_call", true),
    (WasmTarget.compile_invoke, (Expr, Int64, CompilationContext), "compile_invoke", true),
    (WasmTarget.compile_value, (Any, CompilationContext), "compile_value", true),
    (WasmTarget.compile_new, (Expr, Int64, CompilationContext), "compile_new", true),
    (WasmTarget.compile_foreigncall, (Expr, Int64, CompilationContext), "compile_foreigncall", true),
    # Level 5: compile_call handlers
    (WasmTarget._compile_call_checked_mul, (Any, Any, Vector{UInt8}, CompilationContext, Bool, Bool), "_compile_call_checked_mul", false),
    (WasmTarget._compile_call_flipsign, (Any, Vector{UInt8}, CompilationContext, Bool, Bool, Any), "_compile_call_flipsign", false),
    (WasmTarget._compile_call_egaleq, (Any, Vector{UInt8}, CompilationContext, Bool, Bool, Any), "_compile_call_egaleq", false),
    (WasmTarget._compile_call_fpext, (Any, Vector{UInt8}, CompilationContext), "_compile_call_fpext", false),
    (WasmTarget._compile_call_isa, (Any, Vector{UInt8}, CompilationContext), "_compile_call_isa", false),
    (WasmTarget._compile_call_symbol, (Any, Vector{UInt8}, CompilationContext), "_compile_call_symbol", false),
    # Level 6: compile_invoke handlers
    (WasmTarget._compile_invoke_str_hash, (Any, CompilationContext), "_compile_invoke_str_hash", false),
    (WasmTarget._compile_invoke_str_find, (Any, CompilationContext), "_compile_invoke_str_find", false),
    (WasmTarget._compile_invoke_str_contains, (Any, CompilationContext), "_compile_invoke_str_contains", false),
    (WasmTarget._compile_invoke_str_startswith, (Any, CompilationContext), "_compile_invoke_str_startswith", false),
    (WasmTarget._compile_invoke_str_endswith, (Any, CompilationContext), "_compile_invoke_str_endswith", false),
    (WasmTarget._compile_invoke_str_uppercase, (Any, CompilationContext), "_compile_invoke_str_uppercase", false),
    (WasmTarget._compile_invoke_str_lowercase, (Any, CompilationContext), "_compile_invoke_str_lowercase", false),
    (WasmTarget._compile_invoke_str_trim, (Any, CompilationContext), "_compile_invoke_str_trim", false),
    (WasmTarget._compile_invoke_print, (Symbol, Any, CompilationContext), "_compile_invoke_print", false),
    # Level 7: Bytecode post-processing
    (WasmTarget.fix_broken_select_instructions, (Vector{UInt8},), "fix_broken_select_instructions", false),
    (WasmTarget.fix_consecutive_local_sets, (Vector{UInt8},), "fix_consecutive_local_sets", false),
    (WasmTarget.strip_excess_after_function_end, (Vector{UInt8},), "strip_excess_after_function_end", false),
    (WasmTarget.fix_array_len_wrap, (Vector{UInt8},), "fix_array_len_wrap", false),
    (WasmTarget.fix_i32_wrap_after_i32_ops, (Vector{UInt8},), "fix_i32_wrap_after_i32_ops", false),
    (WasmTarget.fix_i64_local_in_i32_ops, (Vector{UInt8}, Vector{WasmValType}), "fix_i64_local_in_i32_ops", false),
    (WasmTarget.fix_local_get_set_type_mismatch, (Vector{UInt8}, Vector{WasmValType}), "fix_local_get_set_type_mismatch", false),
    (WasmTarget.fix_numeric_to_ref_local_stores, (Vector{UInt8}, Vector{WasmValType}, Int64), "fix_numeric_to_ref_local_stores", false),
    # Level 8: LEB128
    (encode_leb128_unsigned, (UInt32,), "encode_leb128_unsigned", false),
    (encode_leb128_signed, (Int32,), "encode_leb128_signed_i32", false),
    (encode_leb128_signed, (Int64,), "encode_leb128_signed_i64", false),
    # Level 9: Constants
    (compile_const_value, (Int64, WasmModule, TypeRegistry), "compile_const_value_i64", false),
    (compile_const_value, (Int32, WasmModule, TypeRegistry), "compile_const_value_i32", false),
    (compile_const_value, (Float64, WasmModule, TypeRegistry), "compile_const_value_f64", false),
    (compile_const_value, (Bool, WasmModule, TypeRegistry), "compile_const_value_bool", false),
    # Level 10: Byte extraction
    (WasmTarget.wasm_bytes_length, (Vector{UInt8},), "wasm_bytes_length", false),
    (WasmTarget.wasm_bytes_get, (Vector{UInt8}, Int32), "wasm_bytes_get", false),
]

# ═════════════════════════════════════════════════════════════════
# Part 1: Compile + validate each function INDIVIDUALLY
# ═════════════════════════════════════════════════════════════════

println("\n--- Part 1: Individual function validation ---\n")

tmpdir = mktempdir()
results = Dict{String, Any}[]

for (i, (f, atypes, name, opt_false)) in enumerate(all_functions)
    result = Dict{String, Any}(
        "index" => i,
        "name" => name,
        "opt_false" => opt_false,
    )

    # Step A: code_typed
    ci = nothing
    rt = nothing
    try
        ci, rt = Base.code_typed(f, atypes; optimize=!opt_false)[1]
        result["stmts"] = length(ci.code)
        result["gotoifnots"] = count(s -> s isa Core.GotoIfNot, ci.code)
        result["code_typed"] = "ok"
    catch e
        result["code_typed"] = "FAIL: $(sprint(showerror, e)[1:min(100,end)])"
        result["standalone_validates"] = "N/A"
        result["standalone_error"] = "code_typed failed"
        push!(results, result)
        println("  $(rpad(i, 3)) $(rpad(name, 45)) code_typed FAIL")
        continue
    end

    # Step B: Compile standalone module
    wasm_path = joinpath(tmpdir, "func_$(i)_$(name).wasm")
    try
        entry = (ci, rt, atypes, name, f)
        mod = compile_module_from_ir([entry])
        bytes = to_bytes(mod)
        write(wasm_path, bytes)
        result["standalone_size"] = length(bytes)
        result["standalone_types"] = length(mod.types)
        result["standalone_compiled"] = true
    catch e
        result["standalone_compiled"] = false
        result["standalone_error"] = "compile failed: $(sprint(showerror, e)[1:min(200,end)])"
        result["standalone_validates"] = "N/A"
        push!(results, result)
        println("  $(rpad(i, 3)) $(rpad(name, 45)) compile FAIL: $(result["standalone_error"][1:min(60,end)])")
        continue
    end

    # Step C: Validate standalone — capture stderr via temp file
    err_file = joinpath(tmpdir, "err_$(i).txt")
    proc = run(pipeline(ignorestatus(`wasm-tools validate --features=gc $wasm_path`), stdout=devnull, stderr=err_file))
    if proc.exitcode == 0
        result["standalone_validates"] = true
        result["standalone_error"] = nothing
    else
        err_msg = try strip(read(err_file, String)) catch; "unknown error" end
        result["standalone_validates"] = false
        result["standalone_error"] = err_msg
    end

    status = result["standalone_validates"] === true ? "✓ PASS" : "✗ FAIL"
    stmts = get(result, "stmts", "?")
    gin = get(result, "gotoifnots", "?")
    sz = get(result, "standalone_size", 0)
    println("  $(rpad(i, 3)) $(rpad(name, 45)) $status  $(lpad(stmts, 6)) stmts  $(lpad(gin, 5)) GIfN  $(lpad(round(sz/1024, digits=1), 6)) KB")

    push!(results, result)
end

# ═════════════════════════════════════════════════════════════════
# Part 2: Validate the combined module
# ═════════════════════════════════════════════════════════════════

println("\n--- Part 2: Combined module validation ---\n")

combined_path = joinpath(@__DIR__, "..", "..", "self-hosted-codegen-full.wasm")

combined_error = ""
if isfile(combined_path)
    combined_err_file = joinpath(tmpdir, "combined_err.txt")
    combined_proc = run(pipeline(ignorestatus(`wasm-tools validate --features=gc $combined_path`), stdout=devnull, stderr=combined_err_file))
    if combined_proc.exitcode == 0
        println("  Combined module: ✓ VALIDATES")
    else
        combined_error = try strip(read(combined_err_file, String)) catch; "unknown" end
        println("  Combined module: ✗ FAILS")
        println("  Error: $combined_error")
    end
else
    combined_error = "file not found"
    println("  ✗ self-hosted-codegen-full.wasm not found")
end

# ═════════════════════════════════════════════════════════════════
# Part 3: Summary table
# ═════════════════════════════════════════════════════════════════

println("\n--- Part 3: Summary ---\n")

n_pass = count(r -> r["standalone_validates"] === true, results)
n_fail = count(r -> r["standalone_validates"] === false, results)
n_na = count(r -> r["standalone_validates"] == "N/A", results)

println("  Standalone validation: $n_pass pass, $n_fail fail, $n_na N/A (compile failed)")
println()

if n_fail > 0
    println("  Functions that FAIL standalone validation:")
    for r in results
        if r["standalone_validates"] === false
            err = get(r, "standalone_error", "?")
            # Truncate error for display
            err_short = length(err) > 120 ? err[1:120] * "..." : err
            println("    $(rpad(r["name"], 45)) $err_short")
        end
    end
end

if n_na > 0
    println("\n  Functions that failed to compile:")
    for r in results
        if r["standalone_validates"] == "N/A"
            err = get(r, "standalone_error", "?")
            err_short = length(err) > 100 ? err[1:100] * "..." : err
            println("    $(rpad(r["name"], 45)) $err_short")
        end
    end
end

# ═════════════════════════════════════════════════════════════════
# Part 4: Save as JSON
# ═════════════════════════════════════════════════════════════════

output = Dict(
    "timestamp" => string(now()),
    "combined_module" => Dict(
        "path" => combined_path,
        "validates" => isempty(combined_error) || combined_error == "",
        "error" => combined_error,
        "func_count" => 52,
        "export_count" => 51,
    ),
    "individual_results" => results,
    "summary" => Dict(
        "total" => length(results),
        "standalone_pass" => n_pass,
        "standalone_fail" => n_fail,
        "standalone_na" => n_na,
    ),
)

json_path = joinpath(@__DIR__, "cg003a_validation_catalog.json")

# Manual JSON output (no JSON3 dependency)
function escape_json(s::AbstractString)
    s = replace(s, "\\" => "\\\\")
    s = replace(s, "\"" => "\\\"")
    s = replace(s, "\n" => "\\n")
    s = replace(s, "\r" => "\\r")
    s = replace(s, "\t" => "\\t")
    return s
end

function json_val(v)
    v === nothing && return "null"
    v === true && return "true"
    v === false && return "false"
    v isa Number && return string(v)
    v isa AbstractString && return "\"$(escape_json(v))\""
    return "\"$(escape_json(string(v)))\""
end

open(json_path, "w") do io
    println(io, "{")
    println(io, "  \"timestamp\": $(json_val(string(now()))),")
    println(io, "  \"combined_module\": {")
    println(io, "    \"validates\": $(json_val(isempty(combined_error))),")
    println(io, "    \"error\": $(json_val(combined_error)),")
    println(io, "    \"func_count\": 52,")
    println(io, "    \"export_count\": 51")
    println(io, "  },")
    println(io, "  \"summary\": {")
    println(io, "    \"total\": $(length(results)),")
    println(io, "    \"standalone_pass\": $n_pass,")
    println(io, "    \"standalone_fail\": $n_fail,")
    println(io, "    \"standalone_na\": $n_na")
    println(io, "  },")
    println(io, "  \"individual_results\": [")
    for (ri, r) in enumerate(results)
        println(io, "    {")
        println(io, "      \"index\": $(r["index"]),")
        println(io, "      \"name\": $(json_val(r["name"])),")
        println(io, "      \"opt_false\": $(json_val(r["opt_false"])),")
        println(io, "      \"code_typed\": $(json_val(get(r, "code_typed", "N/A"))),")
        println(io, "      \"stmts\": $(json_val(get(r, "stmts", nothing))),")
        println(io, "      \"gotoifnots\": $(json_val(get(r, "gotoifnots", nothing))),")
        println(io, "      \"standalone_compiled\": $(json_val(get(r, "standalone_compiled", false))),")
        println(io, "      \"standalone_size\": $(json_val(get(r, "standalone_size", nothing))),")
        println(io, "      \"standalone_types\": $(json_val(get(r, "standalone_types", nothing))),")
        println(io, "      \"standalone_validates\": $(json_val(r["standalone_validates"])),")
        println(io, "      \"standalone_error\": $(json_val(get(r, "standalone_error", nothing)))")
        sep = ri < length(results) ? "," : ""
        println(io, "    }$sep")
    end
    println(io, "  ]")
    println(io, "}")
end
println("\n  Catalog saved to: $json_path")

# Cleanup
rm(tmpdir, recursive=true, force=true)

println("\n" * "=" ^ 70)
println("CG-003a COMPLETE")
println("=" ^ 70)
