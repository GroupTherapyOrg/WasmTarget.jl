# build_int002_inlined.jl — INT-002: Inlined codegen E2E
#
# Strategy: Manually inline compile_from_ir_prebaked's body into the wrapper
# function so Julia's optimizer can inline deeper callees (generate_body,
# compile_statement, etc.) into a single WASM function.
#
# Run: julia +1.12 --project=. test/selfhost/build_int002_inlined.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, compile_from_ir_inplace,
                  compile_from_ir_prebaked, WasmModule, TypeRegistry,
                  wasm_bytes_length, wasm_bytes_get,
                  InplaceCompilationContext, AbstractCompilationContext,
                  FunctionRegistry, register_function!,
                  generate_body, get_concrete_wasm_type, needs_anyref_boxing,
                  add_function!, add_export!, populate_type_constant_globals!,
                  to_bytes_no_dict

println("=" ^ 70)
println("INT-002: Inlined Codegen E2E")
println("=" ^ 70)

# Step 1: Pre-compute CodeInfo
ci_f, rt_f = Base.code_typed(x -> x * x + Int64(1), (Int64,))[1]
println("Target: f(x::Int64) = x*x+1 → $(length(ci_f.code)) stmts")

# Verify native E2E
native_bytes = compile_from_ir_inplace([(ci_f, Int64, (Int64,), "f")])
println("Native compile: $(length(native_bytes)) bytes")

# Step 2: Create inlined codegen function
const _baked_ci = ci_f

# THIS IS THE KEY: compile_from_ir_prebaked's body is INLINED here.
# Julia's optimizer will inline generate_body, compile_statement, etc.
# into this function body (optimize=true), creating a self-contained
# all-in-one codegen function.
function wasm_codegen_inlined(mod::WasmModule, reg::TypeRegistry)::Vector{UInt8}
    func_registry = FunctionRegistry()

    # Single function: f(x::Int64) = x*x+1
    code_info = _baked_ci
    return_type = Int64
    arg_types = (Int64,)
    name = "f"

    # Register in function registry
    n_imports = length(mod.imports)
    func_idx = UInt32(n_imports)
    register_function!(func_registry, name, nothing, arg_types, func_idx, return_type)

    # Create compilation context (Dict-free)
    ctx = InplaceCompilationContext(code_info, arg_types, return_type, mod, reg;
                                   func_registry=func_registry, func_idx=func_idx, func_ref=nothing)

    # Run the REAL codegen pipeline
    body = generate_body(ctx)
    locals = ctx.locals

    # Get param/result types
    param_types = WasmTarget.WasmValType[get_concrete_wasm_type(Int64, mod, reg)]
    result_types = WasmTarget.WasmValType[get_concrete_wasm_type(Int64, mod, reg)]

    # Add function to module
    actual_idx = add_function!(mod, param_types, result_types, locals, body)
    add_export!(mod, "f", UInt32(0), actual_idx)

    populate_type_constant_globals!(mod, reg)
    return to_bytes_no_dict(mod)
end

# Verify native
test_mod = WasmModule()
test_reg = TypeRegistry(Val(:minimal))
test_bytes = wasm_codegen_inlined(test_mod, test_reg)
println("wasm_codegen_inlined native: $(length(test_bytes)) bytes")

# Validate native output
tmpfile = tempname() * ".wasm"
write(tmpfile, test_bytes)
native_ok = try
    run(pipeline(`wasm-tools validate --features=gc $tmpfile`, stderr=devnull, stdout=devnull))
    true
catch; false; end
println("Native output validates: $(native_ok ? "PASS" : "FAIL")")
if native_ok
    out = strip(read(`node -e "
    const bytes = require('fs').readFileSync('$tmpfile');
    WebAssembly.instantiate(bytes).then(m => console.log(String(m.instance.exports.f(5n))));
    "`, String))
    println("Native f(5n) = $out")
end
rm(tmpfile, force=true)

# Check IR of inlined version
ci_wc, rt_wc = Base.code_typed(wasm_codegen_inlined, (WasmModule, TypeRegistry); optimize=true)[1]
n_stmts = length(ci_wc.code)
n_gif = count(x -> x isa Core.GotoIfNot, ci_wc.code)
n_inv = count(x -> x isa Expr && x.head === :invoke, ci_wc.code)
println("\nInlined IR: $n_stmts stmts, $n_gif GotoIfNots, $n_inv invokes")

# List all :invoke targets
inv_count = 0
invoke_names = Dict{String,Int}()
for (i, stmt) in enumerate(ci_wc.code)
    if stmt isa Expr && stmt.head === :invoke
        mi_or_ci = stmt.args[1]
        mi = if mi_or_ci isa Core.MethodInstance
            mi_or_ci
        elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
            mi_or_ci.def
        else
            nothing
        end
        if mi !== nothing
            name_str = string(mi.def.name)
            invoke_names[name_str] = get(invoke_names, name_str, 0) + 1
        end
    end
end
println("\nInvoke targets ($(sum(values(invoke_names))) total):")
for (name, count) in sort(collect(invoke_names), by=x->-x[2])
    println("  $name: $count")
end

# Step 3: Compile to WASM
println("\n--- Compiling inlined codegen to WASM ---")

# Helper functions
ci_len, rt_len = Base.code_typed(wasm_bytes_length, (Vector{UInt8},); optimize=true)[1]
ci_get, rt_get = Base.code_typed(wasm_bytes_get, (Vector{UInt8}, Int32); optimize=true)[1]

# Try single-function first
println("\nSingle function validation:")
try
    entry = Any[(ci_wc, rt_wc, (WasmModule, TypeRegistry), "codegen", wasm_codegen_inlined)]
    mod = compile_module_from_ir(entry)
    bytes = WasmTarget.to_bytes(mod)
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    ok = try
        run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=devnull, stdout=devnull))
        true
    catch; false; end
    println("  codegen: $(length(bytes)) bytes → $(ok ? "PASS ✓" : "FAIL ✗")")
    if !ok
        err = try String(read(pipeline(`wasm-tools validate --features=gc $tmpf`; stderr=stderr))) catch e; sprint(showerror, e) end
        println("  $(split(err, "\n")[1])")
    end
    rm(tmpf, force=true)
catch e
    println("  ERROR: $(sprint(showerror, e)[1:min(300,end)])")
end

# Try with new_mod and new_reg separated
println("\nWith separated constructors:")
ci_mod, rt_mod = Base.code_typed(() -> WasmModule(), (); optimize=true)[1]
ci_reg, rt_reg = Base.code_typed(() -> TypeRegistry(Val(:minimal)), (); optimize=true)[1]

entries = Any[
    (ci_wc, rt_wc, (WasmModule, TypeRegistry), "codegen", wasm_codegen_inlined),
    (ci_mod, rt_mod, (), "new_mod", () -> WasmModule()),
    (ci_reg, rt_reg, (), "new_reg", () -> TypeRegistry(Val(:minimal))),
    (ci_len, rt_len, (Vector{UInt8},), "bytes_len", wasm_bytes_length),
    (ci_get, rt_get, (Vector{UInt8}, Int32), "bytes_get", wasm_bytes_get),
]

mod = compile_module_from_ir(entries)
module_bytes = WasmTarget.to_bytes(mod)
output_path = joinpath(@__DIR__, "..", "..", "e2e-int002-inlined.wasm")
write(output_path, module_bytes)
println("Module: $(length(module_bytes)) bytes ($(round(length(module_bytes)/1024, digits=1)) KB)")

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

# Step 4: Test in Node.js
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
            console.log('WasmModule:', mod ? 'created' : 'null');
            const reg = e.new_reg();
            console.log('TypeRegistry:', reg ? 'created' : 'null');
            console.log('Running codegen...');
            const output = e.codegen(mod, reg);
            console.log('Codegen returned:', typeof output, output ? 'non-null' : 'null');
            if (!output) { console.log('ERROR: null output'); process.exit(1); }
            const len = e.bytes_len(output);
            console.log('Output WASM:', len, 'bytes');
            const out = new Uint8Array(len);
            for (let i = 0; i < len; i++) out[i] = e.bytes_get(output, i + 1);
            const compiled = await WebAssembly.instantiate(out);
            const result = compiled.instance.exports.f(5n);
            console.log('f(5n) =', String(result));
            if (result === 26n) {
                console.log('\\n=== SUCCESS: f(5n) === 26n ===');
                console.log('REAL codegen (compile_from_ir_prebaked) executing in WASM!');
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
        println("Node.js failed: $(sprint(showerror, e)[1:min(300,end)])")
    end
    rm(node_path, force=true)
end

println("\n" * "=" ^ 70)
println("INT-002 inlined build complete")
println("=" ^ 70)
