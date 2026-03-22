# build_e2e_medium.jl — Build medium-sized E2E self-hosting WASM module
#
# Medium subset of codegen functions: avoids type-index-divergence validation issue
# by including only the core codegen, bytecode post-processing, serialization,
# and byte extraction functions (no extracted call/invoke handlers).
#
# Run: julia +1.12 --project=. test/selfhost/build_e2e_medium.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, compile_from_ir_inplace,
                  CompilationContext, WasmModule, TypeRegistry, FunctionRegistry,
                  WasmValType, BasicBlock,
                  compile_const_value, get_concrete_wasm_type,
                  encode_leb128_signed, encode_leb128_unsigned,
                  wasm_bytes_length, wasm_bytes_get

println("=" ^ 70)
println("E2E-MEDIUM: Building self-hosted-e2e-medium.wasm")
println("=" ^ 70)

# =============================================================================
# Step 0: Bake CodeInfo at module load time
# =============================================================================

ci_baked, rt_baked = Base.code_typed(x -> x * x + 1, (Int64,); optimize=true)[1]
entries_baked = [(ci_baked, rt_baked, (Int64,), "f")]

function wasm_compile_baked()::Vector{UInt8}
    return compile_from_ir_inplace(entries_baked)
end

# =============================================================================
# Step 1: Define all functions
#   Format: (function, arg_types, export_name, opt_false)
#   opt_false=true means we pass optimize=false to code_typed
# =============================================================================

all_functions = Tuple{Any, Tuple, String, Bool}[
    # Entry point
    (wasm_compile_baked, (), "wasm_compile_baked", false),

    # Core codegen (opt=true -- self-contained)
    (get_concrete_wasm_type, (Type, WasmModule, TypeRegistry), "get_concrete_wasm_type", false),
    (WasmTarget.needs_anyref_boxing, (Union,), "needs_anyref_boxing", false),
    (WasmTarget.populate_type_constant_globals!, (WasmModule, TypeRegistry), "populate_type_constant_globals!", false),
    (WasmTarget.generate_body, (CompilationContext,), "generate_body", false),
    (WasmTarget.generate_structured, (CompilationContext, Vector{BasicBlock}), "generate_structured", false),
    (WasmTarget.generate_block_code, (CompilationContext, BasicBlock), "generate_block_code", false),
    (WasmTarget.analyze_blocks, (Vector{Any},), "analyze_blocks", false),

    # Statement compilation (opt=false -- large dispatch functions)
    (WasmTarget.compile_statement, (Expr, Int64, CompilationContext), "compile_statement", true),
    (WasmTarget.compile_call, (Expr, Int64, CompilationContext), "compile_call", true),
    (WasmTarget.compile_invoke, (Expr, Int64, CompilationContext), "compile_invoke", true),
    (WasmTarget.compile_value, (Any, CompilationContext), "compile_value", true),

    # Bytecode post-processing
    (WasmTarget.fix_broken_select_instructions, (Vector{UInt8},), "fix_broken_select_instructions", false),
    (WasmTarget.fix_consecutive_local_sets, (Vector{UInt8},), "fix_consecutive_local_sets", false),
    (WasmTarget.strip_excess_after_function_end, (Vector{UInt8},), "strip_excess_after_function_end", false),
    (WasmTarget.fix_array_len_wrap, (Vector{UInt8},), "fix_array_len_wrap", false),
    (WasmTarget.fix_i32_wrap_after_i32_ops, (Vector{UInt8},), "fix_i32_wrap_after_i32_ops", false),
    (WasmTarget.fix_i64_local_in_i32_ops, (Vector{UInt8}, Vector{WasmValType}), "fix_i64_local_in_i32_ops", false),
    (WasmTarget.fix_local_get_set_type_mismatch, (Vector{UInt8}, Vector{WasmValType}), "fix_local_get_set_type_mismatch", false),
    (WasmTarget.fix_numeric_to_ref_local_stores, (Vector{UInt8}, Vector{WasmValType}, Int64), "fix_numeric_to_ref_local_stores", false),

    # Serialization + LEB128
    (WasmTarget.to_bytes_no_dict, (WasmModule,), "to_bytes_no_dict", false),
    (encode_leb128_unsigned, (UInt32,), "encode_leb128_unsigned", false),
    (encode_leb128_signed, (Int32,), "encode_leb128_signed_i32", false),
    (encode_leb128_signed, (Int64,), "encode_leb128_signed_i64", false),

    # Constant values
    (compile_const_value, (Int64, WasmModule, TypeRegistry), "compile_const_value_i64", false),
    (compile_const_value, (Int32, WasmModule, TypeRegistry), "compile_const_value_i32", false),
    (compile_const_value, (Float64, WasmModule, TypeRegistry), "compile_const_value_f64", false),
    (compile_const_value, (Bool, WasmModule, TypeRegistry), "compile_const_value_bool", false),

    # Byte extraction
    (wasm_bytes_length, (Vector{UInt8},), "wasm_bytes_length", false),
    (wasm_bytes_get, (Vector{UInt8}, Int32), "wasm_bytes_get", false),
]

# =============================================================================
# Step 2: Get typed IR for all functions
# =============================================================================

println("\n--- Step 1: code_typed $(length(all_functions)) functions ---")
entries = Tuple[]
failed = String[]
for (f, atypes, name, opt_false) in all_functions
    try
        ci, rt = Base.code_typed(f, atypes; optimize=!opt_false)[1]
        n_stmts = length(ci.code)
        n_gin = count(s -> s isa Core.GotoIfNot, ci.code)
        opt_str = opt_false ? "opt=false" : "opt=true"
        push!(entries, (ci, rt, atypes, name, f))
        println("  OK  $(rpad(name, 45)) $(lpad(n_stmts, 6)) stmts  $(lpad(n_gin, 5)) GIfN  ($opt_str)")
    catch e
        push!(failed, name)
        msg = sprint(showerror, e)
        println("  FAIL $name: $(msg[1:min(120,end)])")
    end
end
println("  Succeeded: $(length(entries)) / $(length(all_functions))")
if !isempty(failed)
    println("  Failed: $(join(failed, ", "))")
end

if isempty(entries)
    println("\nNo functions compiled. Exiting.")
    exit(1)
end

# =============================================================================
# Step 3: Compile combined module
# =============================================================================

println("\n--- Step 2: Compile combined module ---")

module_bytes = UInt8[]
module_compiled = false

try
    global mod = compile_module_from_ir(entries)
    global module_bytes = WasmTarget.to_bytes(mod)
    global module_compiled = true
    println("  Module size: $(length(module_bytes)) bytes ($(round(length(module_bytes)/1024, digits=1)) KB)")
    println("  Functions: $(length(mod.functions))")
    println("  Types: $(length(mod.types))")
    println("  Exports: $(length(mod.exports))")
catch e
    println("  Module compilation FAILED:")
    msg = sprint(showerror, e)
    println("    $(msg[1:min(500,end)])")
    bt = catch_backtrace()
    lines = split(sprint(Base.show_backtrace, bt), '\n')
    for line in lines[1:min(25, length(lines))]
        println("    $line")
    end
end

# =============================================================================
# Step 4: Save and validate
# =============================================================================

output_path = joinpath(@__DIR__, "..", "..", "self-hosted-e2e-medium.wasm")
validate_ok = false

if module_compiled
    write(output_path, module_bytes)
    println("\n--- Step 3: wasm-tools validate ---")

    try
        run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
        println("  wasm-tools validate: PASSED")
        validate_ok = true
    catch
        println("  wasm-tools validate: FAILED")
        # Get error details
        try
            err_output = read(pipeline(ignorestatus(`wasm-tools validate --features=gc $output_path`)), String)
            for line in split(err_output, '\n')[1:min(15, end)]
                println("    $line")
            end
        catch ex
            println("    Error details: $(sprint(showerror, ex)[1:min(200,end)])")
        end
    end
else
    println("\nModule compilation failed, skipping validation.")
    println("Output path would have been: $output_path")
end

# =============================================================================
# Step 5: Incremental validation (if full module fails)
# =============================================================================

if module_compiled && !validate_ok
    println("\n--- Step 4: Incremental validation (find which function breaks it) ---")

    last_good = 0
    first_bad = 0

    # Start with 3, then add 1 at a time
    for n in 3:length(entries)
        subset = entries[1:n]
        try
            sub_mod = compile_module_from_ir(subset)
            sub_bytes = WasmTarget.to_bytes(sub_mod)
            tmp_path = tempname() * ".wasm"
            write(tmp_path, sub_bytes)
            run(pipeline(`wasm-tools validate --features=gc $tmp_path`, stderr=devnull, stdout=devnull))
            last_good = n
            name = entries[n][4]
            println("  n=$n  OK   ($name) -- $(round(length(sub_bytes)/1024, digits=1)) KB")
            rm(tmp_path; force=true)
        catch e
            first_bad = n
            name = entries[n][4]
            println("  n=$n  FAIL ($name)")
            # Show the validation error for this subset
            try
                sub_mod = compile_module_from_ir(subset)
                sub_bytes = WasmTarget.to_bytes(sub_mod)
                tmp_path = tempname() * ".wasm"
                write(tmp_path, sub_bytes)
                err_output = read(pipeline(ignorestatus(`wasm-tools validate --features=gc $tmp_path`)), String)
                for line in split(err_output, '\n')[1:min(10, end)]
                    println("           $line")
                end
                rm(tmp_path; force=true)
            catch
            end
            break
        end
    end

    if first_bad > 0
        println("\n  RESULT: Functions 1-$(last_good) validate OK.")
        println("  BREAKS at function #$(first_bad): $(entries[first_bad][4])")
    elseif last_good == length(entries)
        println("\n  All individual subsets validate! Issue may be in final combination.")
    end
end

# =============================================================================
# Step 6: Node.js load test (if validates)
# =============================================================================

if validate_ok
    println("\n--- Step 5: Node.js load test ---")
    try
        node_script = """
        const fs = require('fs');
        const bytes = fs.readFileSync('$(output_path)');
        WebAssembly.compile(bytes).then(async mod => {
            const imports = WebAssembly.Module.imports(mod);
            const stubs = {};
            for (const imp of imports) {
                if (!stubs[imp.module]) stubs[imp.module] = {};
                if (imp.kind === 'function') stubs[imp.module][imp.name] = (...args) => {};
                else if (imp.kind === 'global') stubs[imp.module][imp.name] = new WebAssembly.Global({value: 'i32', mutable: true}, 0);
                else if (imp.kind === 'table') stubs[imp.module][imp.name] = new WebAssembly.Table({element: 'anyfunc', initial: 1});
                else if (imp.kind === 'memory') stubs[imp.module][imp.name] = new WebAssembly.Memory({initial: 1});
            }
            const inst = await WebAssembly.instantiate(mod, stubs);
            const exports = Object.keys(inst.exports);
            console.log(exports.length + ' exports loaded successfully');
            exports.forEach(e => console.log('  ' + e));
        }).catch(e => { console.error('LOAD ERROR: ' + e.message); process.exit(1); });
        """
        node_result = read(`node -e $node_script`, String)
        for line in split(strip(node_result), '\n')
            println("  $line")
        end
    catch e
        println("  Node.js load FAILED: $(string(e)[1:min(200,end)])")
    end
end

# =============================================================================
# Summary
# =============================================================================

println("\n" * "=" ^ 70)
println("E2E-MEDIUM Summary:")
println("  Functions compiled: $(length(entries)) / $(length(all_functions))")
println("  Module compiled:    $module_compiled")
println("  Module size:        $(module_compiled ? "$(round(length(module_bytes)/1024, digits=1)) KB" : "N/A")")
println("  wasm-tools valid:   $validate_ok")
println("  Output:             $output_path")
println("=" ^ 70)
