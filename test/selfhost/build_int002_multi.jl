# build_int002_multi.jl — INT-002: Multi-function codegen E2E
#
# Strategy: Compile codegen as a multi-function module where :invoke calls
# between functions are wired via the FunctionRegistry.
#
# Key functions: wasm_codegen (entry) → generate_body → add_function! → to_bytes_no_dict
#
# Run: julia +1.12 --project=. test/selfhost/build_int002_multi.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, compile_from_ir_inplace,
                  compile_from_ir_prebaked, WasmModule, TypeRegistry,
                  wasm_bytes_length, wasm_bytes_get,
                  InplaceCompilationContext, AbstractCompilationContext,
                  FunctionRegistry,
                  generate_body, get_concrete_wasm_type, needs_anyref_boxing,
                  add_function!, add_export!, populate_type_constant_globals!,
                  to_bytes_no_dict

println("=" ^ 70)
println("INT-002: Multi-Function Codegen E2E")
println("=" ^ 70)

# Step 1: Pre-compute CodeInfo
ci_f, rt_f = Base.code_typed(x -> x * x + Int64(1), (Int64,))[1]
println("Target: f(x::Int64) = x*x+1 → $(length(ci_f.code)) stmts")

# Verify native E2E
native_bytes = compile_from_ir_inplace([(ci_f, Int64, (Int64,), "f")])
println("Native compile: $(length(native_bytes)) bytes")

const _baked_ci = ci_f

# Step 2: Create simplified codegen function (no register_function!, no populate_type_constant_globals!)
function wasm_codegen_simple(mod::WasmModule, reg::TypeRegistry)::Vector{UInt8}
    # Single function: f(x::Int64) = x*x+1
    code_info = _baked_ci
    return_type = Int64
    arg_types = (Int64,)

    # Create compilation context (Dict-free, no func_registry needed for single function)
    n_imports = length(mod.imports)
    func_idx = UInt32(n_imports)
    ctx = InplaceCompilationContext(code_info, arg_types, return_type, mod, reg;
                                   func_registry=nothing, func_idx=func_idx, func_ref=nothing)

    # Run the REAL codegen pipeline
    body = generate_body(ctx)
    locals = ctx.locals

    # Get param/result types (Int64 → I64 directly, no Dict)
    param_types = WasmTarget.WasmValType[get_concrete_wasm_type(Int64, mod, reg)]
    result_types = WasmTarget.WasmValType[get_concrete_wasm_type(Int64, mod, reg)]

    # Add function to module
    actual_idx = add_function!(mod, param_types, result_types, locals, body)
    add_export!(mod, "f", UInt32(0), actual_idx)

    # Skip populate_type_constant_globals! — not needed for Int64 arithmetic
    return to_bytes_no_dict(mod)
end

# Verify native
test_mod = WasmModule()
test_reg = TypeRegistry(Val(:minimal))
test_bytes = wasm_codegen_simple(test_mod, test_reg)
println("wasm_codegen_simple native: $(length(test_bytes)) bytes")
tmpfile = tempname() * ".wasm"
write(tmpfile, test_bytes)
native_ok = try
    run(pipeline(`wasm-tools validate --features=gc $tmpfile`, stderr=devnull, stdout=devnull))
    true
catch; false; end
println("Native validates: $native_ok")
if native_ok
    out = strip(read(`node -e "
    const bytes = require('fs').readFileSync('$tmpfile');
    WebAssembly.instantiate(bytes).then(m => console.log(String(m.instance.exports.f(5n))));
    "`, String))
    println("Native f(5n) = $out")
end
rm(tmpfile, force=true)

# Check IR
ci_wc, rt_wc = Base.code_typed(wasm_codegen_simple, (WasmModule, TypeRegistry); optimize=true)[1]
n_stmts = length(ci_wc.code)
n_gif = count(x -> x isa Core.GotoIfNot, ci_wc.code)
n_inv = count(x -> x isa Expr && x.head === :invoke, ci_wc.code)
println("\nSimplified IR: $n_stmts stmts, $n_gif GotoIfNots, $n_inv invokes")

# List :invoke targets
println("Invoke targets:")
for (i, stmt) in enumerate(ci_wc.code)
    if stmt isa Expr && stmt.head === :invoke
        mi_or_ci = stmt.args[1]
        mi = if mi_or_ci isa Core.MethodInstance; mi_or_ci
        elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance; mi_or_ci.def
        else nothing end
        func_ref_expr = stmt.args[2]
        if mi !== nothing
            println("  [$i] $(mi.def.name) :: $(mi.specTypes)")
            println("       func_ref = $func_ref_expr")
        end
    end
end

# Step 3: Build entries for ALL critical callees
println("\n--- Building multi-function module ---")

# For each :invoke callee, we need to include it as an entry so the
# FunctionRegistry wires the call. Let's get code_typed for each.

function try_code_typed(f, types; optimize=true)
    try
        result = Base.code_typed(f, types; optimize=optimize)
        if !isempty(result)
            ci, rt = result[1]
            n = length(ci.code)
            println("  $(nameof(f))($(join(types, ","))) → $n stmts, return: $rt")
            return ci, rt
        end
    catch e
        println("  $(nameof(f))($(join(types, ","))) → ERROR: $(sprint(showerror, e)[1:min(100,end)])")
    end
    return nothing, nothing
end

println("\nGathering callees:")

# generate_body — THE codegen, compile with optimize=true to inline compile_statement etc.
ci_gb, rt_gb = try_code_typed(generate_body, (InplaceCompilationContext,); optimize=true)

# to_bytes_no_dict — serializer
ci_tbn, rt_tbn = try_code_typed(to_bytes_no_dict, (WasmModule,); optimize=true)

# add_function! — note: add_function! may have multiple arg signatures
ci_af, rt_af = try_code_typed(add_function!, (WasmModule, Vector{WasmTarget.WasmValType}, Vector{WasmTarget.WasmValType}, Vector{Tuple{UInt32, WasmTarget.WasmValType}}, Vector{UInt8}); optimize=true)

# add_export!
ci_ae, rt_ae = try_code_typed(add_export!, (WasmModule, String, UInt32, UInt32); optimize=true)

# InplaceCompilationContext constructor — check what type Julia uses
# The constructor is called as InplaceCompilationContext(ci, arg_types, ret_type, mod, reg; kwargs...)
# With optimize=true, Julia may inline this

# get_concrete_wasm_type
ci_gcw, rt_gcw = try_code_typed(get_concrete_wasm_type, (Type, WasmModule, TypeRegistry); optimize=true)

# Byte helpers
ci_len, rt_len = Base.code_typed(wasm_bytes_length, (Vector{UInt8},); optimize=true)[1]
ci_get, rt_get = Base.code_typed(wasm_bytes_get, (Vector{UInt8}, Int32); optimize=true)[1]

# Module/Registry constructors
ci_mod, rt_mod = Base.code_typed(() -> WasmModule(), (); optimize=true)[1]
ci_reg, rt_reg = Base.code_typed(() -> TypeRegistry(Val(:minimal)), (); optimize=true)[1]

# Build entries
entries = Any[]

# Entry point: the codegen function
push!(entries, (ci_wc, rt_wc, (WasmModule, TypeRegistry), "codegen", wasm_codegen_simple))

# Critical callees (only include those that code_typed succeeded for)
if ci_gb !== nothing
    push!(entries, (ci_gb, rt_gb, (InplaceCompilationContext,), "generate_body", generate_body))
end
if ci_tbn !== nothing
    push!(entries, (ci_tbn, rt_tbn, (WasmModule,), "to_bytes_no_dict", to_bytes_no_dict))
end
if ci_af !== nothing
    push!(entries, (ci_af, rt_af, (WasmModule, Vector{WasmTarget.WasmValType}, Vector{WasmTarget.WasmValType}, Vector{Tuple{UInt32, WasmTarget.WasmValType}}, Vector{UInt8}), "add_function!", add_function!))
end
if ci_ae !== nothing
    push!(entries, (ci_ae, rt_ae, (WasmModule, String, UInt32, UInt32), "add_export!", add_export!))
end

# Helper functions
push!(entries, (ci_mod, rt_mod, (), "new_mod", () -> WasmModule()))
push!(entries, (ci_reg, rt_reg, (), "new_reg", () -> TypeRegistry(Val(:minimal))))
push!(entries, (ci_len, rt_len, (Vector{UInt8},), "bytes_len", wasm_bytes_length))
push!(entries, (ci_get, rt_get, (Vector{UInt8}, Int32), "bytes_get", wasm_bytes_get))

println("\n$(length(entries)) functions in module")

# Step 4: Compile to WASM
println("\n--- Compiling multi-function module ---")
mod = compile_module_from_ir(entries)
module_bytes = WasmTarget.to_bytes(mod)
output_path = joinpath(@__DIR__, "..", "..", "e2e-int002-multi.wasm")
write(output_path, module_bytes)
println("Module: $(length(module_bytes)) bytes ($(round(length(module_bytes)/1024, digits=1)) KB)")
println("Exports: $(length(mod.exports))")

valid = try
    run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
    true
catch; false; end
println("wasm-tools validate: $(valid ? "PASS ✓" : "FAIL ✗")")

if !valid
    err = try String(read(pipeline(`wasm-tools validate --features=gc $output_path`; stderr=stderr))) catch e; sprint(showerror, e) end
    for line in split(err, "\n")[1:min(5,end)]
        println("  $line")
    end
end

# Step 5: Test in Node.js
if valid
    println("\n--- E2E: Execute codegen in WASM ---")
    node_script = """
    const fs = require('fs');
    const bytes = fs.readFileSync(process.argv[2]);
    WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } }).then(async ({instance}) => {
        const e = instance.exports;
        console.log('Exports:', Object.keys(e).join(', '));
        try {
            const mod = e.new_mod();
            console.log('WasmModule:', mod ? 'OK' : 'null');
            const reg = e.new_reg();
            console.log('TypeRegistry:', reg ? 'OK' : 'null');
            console.log('Running codegen (compile_from_ir_prebaked in WASM)...');
            const output = e.codegen(mod, reg);
            console.log('Codegen returned:', typeof output, output ? 'non-null' : 'null');
            if (!output) { console.log('ERROR: null output'); process.exit(1); }
            const len = e.bytes_len(output);
            console.log('Output WASM:', len, 'bytes');
            const out = new Uint8Array(len);
            for (let i = 0; i < len; i++) out[i] = e.bytes_get(output, i + 1);
            console.log('WASM magic:', '0x' + out[0].toString(16), '0x' + out[1].toString(16), '0x' + out[2].toString(16), '0x' + out[3].toString(16));
            const compiled = await WebAssembly.instantiate(out);
            const result = compiled.instance.exports.f(5n);
            console.log('f(5n) =', String(result));
            if (result === 26n) {
                console.log('\\n=== SUCCESS: f(5n) === 26n ===');
                console.log('REAL codegen executing in WASM! compile_from_ir_prebaked pipeline.');
            } else {
                console.log('WRONG: expected 26n, got', String(result));
            }
        } catch(err) {
            console.log('TRAP:', err.message);
        }
    }).catch(e => console.error('Load failed:', e.message));
    """
    node_path = tempname() * ".cjs"
    write(node_path, node_script)
    try
        result = read(`node $node_path $output_path`, String)
        println(strip(result))
    catch e
        println("Node.js: $(sprint(showerror, e)[1:min(300,end)])")
    end
    rm(node_path, force=true)
end

println("\n" * "=" ^ 70)
println("INT-002 multi-function build complete")
println("=" ^ 70)
