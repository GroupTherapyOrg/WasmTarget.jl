# build_e2e_minimal.jl — Build MINIMAL E2E self-hosting WASM module
#
# Compiles only the 16 functions needed for the E2E self-hosting test:
#   - compile_module_from_ir_frozen_no_dict (main entry point)
#   - wasm_set_code_info! (CodeInfo field setter)
#   - wasm_create_any_vector, wasm_set_any_expr!, wasm_set_any_return!,
#     wasm_set_any_i64!, wasm_set_any_ssa!, wasm_set_any_arg! (IR builders)
#   - wasm_create_ssatypes_all_i64 (SSA type vector)
#   - wasm_create_expr, wasm_create_ssa_value, wasm_create_argument,
#     wasm_create_return_node (IR node constructors)
#   - wasm_symbol_call (Symbol factory)
#   - wasm_bytes_length, wasm_bytes_get (byte extraction)
#
# Run: julia +1.12 --project=. test/selfhost/build_e2e_minimal.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, compile_module_from_ir_frozen_no_dict,
                  FrozenCompilationState, WasmModule, TypeRegistry,
                  wasm_set_code_info!, wasm_create_any_vector, wasm_set_any_expr!,
                  wasm_set_any_return!, wasm_set_any_i64!, wasm_set_any_ssa!, wasm_set_any_arg!,
                  wasm_create_ssatypes_all_i64, wasm_create_expr, wasm_create_ssa_value,
                  wasm_create_argument, wasm_create_return_node, wasm_symbol_call,
                  wasm_bytes_length, wasm_bytes_get

println("=" ^ 70)
println("E2E-MINIMAL: Building self-hosted-e2e-minimal.wasm")
println("  16 functions for minimal E2E self-hosting test")
println("=" ^ 70)

# =============================================================================
# Step 1: Define the minimal set of functions
# =============================================================================

# (function, arg_types, export_name)
functions_list = [
    # Main entry point — compiles IR to WASM bytes
    (compile_module_from_ir_frozen_no_dict, (Vector, FrozenCompilationState), "compile_module_from_ir_frozen_no_dict"),

    # CodeInfo field setter
    (wasm_set_code_info!, (Core.CodeInfo, Vector{Any}, Vector{Any}, Int32), "wasm_set_code_info"),

    # Vector{Any} builders
    (wasm_create_any_vector, (Int32,), "wasm_create_any_vector"),
    (wasm_set_any_expr!, (Vector{Any}, Int32, Expr), "wasm_set_any_expr"),
    (wasm_set_any_return!, (Vector{Any}, Int32, Core.ReturnNode), "wasm_set_any_return"),
    (wasm_set_any_i64!, (Vector{Any}, Int32, Int64), "wasm_set_any_i64"),
    (wasm_set_any_ssa!, (Vector{Any}, Int32, Int32), "wasm_set_any_ssa"),
    (wasm_set_any_arg!, (Vector{Any}, Int32, Int32), "wasm_set_any_arg"),

    # SSA type vector
    (wasm_create_ssatypes_all_i64, (Int32,), "wasm_create_ssatypes_all_i64"),

    # IR node constructors
    (wasm_create_expr, (Symbol, Vector{Any}), "wasm_create_expr"),
    (wasm_create_ssa_value, (Int32,), "wasm_create_ssa_value"),
    (wasm_create_argument, (Int32,), "wasm_create_argument"),
    (wasm_create_return_node, (Int32,), "wasm_create_return_node"),

    # Symbol factory
    (wasm_symbol_call, (), "wasm_symbol_call"),

    # Byte extraction
    (wasm_bytes_length, (Vector{UInt8},), "wasm_bytes_length"),
    (wasm_bytes_get, (Vector{UInt8}, Int32), "wasm_bytes_get"),
]

# =============================================================================
# Step 2: Get typed IR for all functions
# =============================================================================

println("\n--- Step 1: code_typed $(length(functions_list)) functions ---")

entries = Tuple[]
failed = String[]
for (f, atypes, name) in functions_list
    try
        ci, rt = Base.code_typed(f, atypes; optimize=true)[1]
        n_stmts = length(ci.code)
        n_gin = count(s -> s isa Core.GotoIfNot, ci.code)
        push!(entries, (ci, rt, atypes, name, f))
        println("  OK  $(rpad(name, 45)) $(lpad(n_stmts, 5)) stmts  $(lpad(n_gin, 4)) GIfN")
    catch e
        push!(failed, name)
        msg = sprint(showerror, e)
        println("  FAIL $name: $(msg[1:min(120,end)])")
    end
end
println("  Succeeded: $(length(entries)) / $(length(functions_list))")
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
    global module_bytes = to_bytes(mod)
    global module_compiled = true
    println("  Module size: $(length(module_bytes)) bytes ($(round(length(module_bytes)/1024, digits=1)) KB)")
    println("  Functions: $(length(mod.functions))")
    println("  Types: $(length(mod.types))")
    println("  Exports: $(length(mod.exports))")
    println("  Export list:")
    for exp in mod.exports
        println("    - $(exp.name)")
    end
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
# Step 4: Save, validate, and load
# =============================================================================

output_path = joinpath(@__DIR__, "..", "..", "self-hosted-e2e-minimal.wasm")
validate_ok = false
load_ok = false

if module_compiled
    write(output_path, module_bytes)
    println("\n--- Step 3: wasm-tools validate ---")

    # Validate
    try
        result = read(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=stderr), String)
        println("  wasm-tools validate: PASSED")
        global validate_ok = true
    catch e
        println("  wasm-tools validate: FAILED")
        # Get error details
        try
            err_output = read(pipeline(ignorestatus(`wasm-tools validate --features=gc $output_path`), stderr=stdout), String)
            # Show first few lines of error
            for line in split(err_output, '\n')[1:min(10, end)]
                println("    $line")
            end
        catch
            println("    (could not capture error details)")
        end
    end

    # Try Node.js load
    println("\n--- Step 4: Node.js load test ---")
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
        global load_ok = true
    catch e
        println("  Node.js load FAILED: $(string(e)[1:min(200,end)])")
    end
else
    println("\nModule compilation failed, skipping validate/load steps.")
    println("Output path would have been: $output_path")
end

# =============================================================================
# Summary
# =============================================================================

println("\n" * "=" ^ 70)
println("E2E-MINIMAL Summary:")
println("  Functions compiled: $(length(entries)) / $(length(functions_list))")
println("  Module compiled:    $module_compiled")
println("  Module size:        $(round(length(module_bytes)/1024, digits=1)) KB")
println("  wasm-tools valid:   $validate_ok")
println("  Node.js loads:      $load_ok")
println("  Output:             $output_path")
println("=" ^ 70)
