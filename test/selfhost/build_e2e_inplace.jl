# build_e2e_inplace.jl — Build minimal E2E module with compile_from_ir_inplace
#
# This compiles the Dict-free codegen entry point + IR constructor exports
# into a single WASM module for the true self-hosting E2E test.
#
# Run: julia +1.12 --project=. test/selfhost/build_e2e_inplace.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, compile_from_ir_inplace,
                  wasm_set_code_info!, wasm_create_any_vector, wasm_set_any_expr!,
                  wasm_set_any_return!, wasm_set_any_i64!, wasm_set_any_ssa!, wasm_set_any_arg!,
                  wasm_create_ssatypes_all_i64, wasm_create_expr, wasm_create_ssa_value,
                  wasm_create_argument, wasm_create_return_node, wasm_symbol_call,
                  wasm_bytes_length, wasm_bytes_get

println("=" ^ 70)
println("Building E2E inplace module")
println("=" ^ 70)

# Functions to include in the module
functions = [
    # The REAL codegen entry point — Dict-free, no FrozenCompilationState
    (compile_from_ir_inplace, (Vector,), "compile_from_ir_inplace"),

    # CodeInfo manipulation
    (wasm_set_code_info!, (Core.CodeInfo, Vector{Any}, Vector{Any}, Int32), "wasm_set_code_info"),

    # Vector{Any} builders
    (wasm_create_any_vector, (Int32,), "wasm_create_any_vector"),
    (wasm_set_any_expr!, (Vector{Any}, Int32, Expr), "wasm_set_any_expr"),
    (wasm_set_any_return!, (Vector{Any}, Int32, Core.ReturnNode), "wasm_set_any_return"),
    (wasm_set_any_i64!, (Vector{Any}, Int32, Int64), "wasm_set_any_i64"),
    (wasm_set_any_ssa!, (Vector{Any}, Int32, Int32), "wasm_set_any_ssa"),
    (wasm_set_any_arg!, (Vector{Any}, Int32, Int32), "wasm_set_any_arg"),

    # Type constructors
    (wasm_create_ssatypes_all_i64, (Int32,), "wasm_create_ssatypes_all_i64"),
    (wasm_create_expr, (Symbol, Vector{Any}), "wasm_create_expr"),
    (wasm_create_ssa_value, (Int32,), "wasm_create_ssa_value"),
    (wasm_create_argument, (Int32,), "wasm_create_argument"),
    (wasm_create_return_node, (Int32,), "wasm_create_return_node"),
    (wasm_symbol_call, (), "wasm_symbol_call"),

    # Byte extraction
    (wasm_bytes_length, (Vector{UInt8},), "wasm_bytes_length"),
    (wasm_bytes_get, (Vector{UInt8}, Int32), "wasm_bytes_get"),
]

# Step 1: code_typed all functions
println("\n--- Step 1: code_typed $(length(functions)) functions ---")
entries = Tuple[]
for (f, atypes, name) in functions
    try
        ci, rt = Base.code_typed(f, atypes; optimize=true)[1]
        n_stmts = length(ci.code)
        n_gin = count(s -> s isa Core.GotoIfNot, ci.code)
        push!(entries, (ci, rt, atypes, name, f))
        println("  ✓ $(rpad(name, 40)) $(lpad(n_stmts, 6)) stmts  $(lpad(n_gin, 5)) GIfN")
    catch e
        println("  ✗ $name: $(sprint(showerror, e)[1:min(120,end)])")
    end
end
println("  Succeeded: $(length(entries))/$(length(functions))")

# Step 2: Compile combined module
println("\n--- Step 2: Compile combined module ---")
mod = nothing
module_bytes = UInt8[]
try
    global mod = compile_module_from_ir(entries)
    global module_bytes = WasmTarget.to_bytes(mod)
    println("  ✓ Module: $(length(module_bytes)) bytes ($(round(length(module_bytes)/1024, digits=1)) KB)")
    println("  Functions: $(length(mod.functions))")
    println("  Types: $(length(mod.types))")
    println("  Exports: $(length(mod.exports))")
    for exp in mod.exports
        println("    - $(exp.name)")
    end
catch e
    println("  ✗ FAILED: $(sprint(showerror, e)[1:min(300,end)])")
    rethrow()
end

# Step 3: Write and validate
output_path = joinpath(@__DIR__, "..", "..", "self-hosted-e2e-inplace.wasm")
write(output_path, module_bytes)

println("\n--- Step 3: Validate + Load ---")
validate_ok = try
    run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
    println("  ✓ wasm-tools validate PASSED")
    true
catch
    err_msg = try read(pipeline(`wasm-tools validate --features=gc $output_path`; stderr=stderr), String) catch; "unknown" end
    println("  ✗ wasm-tools validate FAILED: $err_msg")
    false
end

load_ok = try
    node_script = """
    const fs = require('fs');
    const bytes = fs.readFileSync('$(output_path)');
    WebAssembly.compile(bytes).then(async mod => {
        const stubs = {};
        for (const imp of WebAssembly.Module.imports(mod)) {
            if (!stubs[imp.module]) stubs[imp.module] = {};
            if (imp.kind === 'function') stubs[imp.module][imp.name] = (...args) => {};
        }
        const inst = await WebAssembly.instantiate(mod, stubs);
        const exports = Object.keys(inst.exports);
        console.log(exports.length + ' exports loaded');
        exports.forEach(e => console.log('  ' + e));
    }).catch(e => { console.error('LOAD ERROR: ' + e.message); process.exit(1); });
    """
    node_result = read(`node -e $node_script`, String)
    println("  ✓ Node.js: $(strip(split(node_result, '\n')[1]))")
    true
catch e
    println("  ✗ Node.js: $(string(e)[1:min(200,end)])")
    false
end

# Step 4: Native Julia E2E test (verify our codegen path works natively)
println("\n--- Step 4: Native Julia E2E (compile_from_ir_inplace) ---")
try
    f_ir = Base.code_typed(x -> x * x + 1, (Int64,); optimize=true)[1]
    ci, rt = f_ir
    ir_entries = [(ci, rt, (Int64,), "f")]
    result_bytes = compile_from_ir_inplace(ir_entries)
    println("  ✓ compile_from_ir_inplace produced $(length(result_bytes)) bytes")

    # Validate the OUTPUT
    tmp_path = tempname() * ".wasm"
    write(tmp_path, result_bytes)
    try
        run(pipeline(`wasm-tools validate --features=gc $tmp_path`, stderr=devnull, stdout=devnull))
        println("  ✓ Output WASM validates")
    catch
        println("  ✗ Output WASM validation failed")
    end

    # Execute the output
    node_exec = """
    const fs = require('fs');
    const bytes = fs.readFileSync('$(tmp_path)');
    WebAssembly.instantiate(bytes).then(inst => {
        const f = inst.instance.exports.f;
        const result = f(5n);
        console.log('f(5n) = ' + result);
        console.log('correct = ' + (result === 26n));
    }).catch(e => { console.error('ERROR: ' + e.message); process.exit(1); });
    """
    exec_result = read(`node -e $node_exec`, String)
    println("  ✓ Native E2E: $(strip(exec_result))")
    rm(tmp_path; force=true)
catch e
    println("  ✗ Native E2E failed: $(sprint(showerror, e)[1:min(300,end)])")
end

println("\n" * "=" ^ 70)
println("Summary:")
println("  Module: $(round(length(module_bytes)/1024, digits=1)) KB, $(length(entries)) functions")
println("  Validates: $validate_ok")
println("  Node.js loads: $load_ok")
println("=" ^ 70)
