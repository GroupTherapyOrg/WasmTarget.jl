# build_int002_single.jl — INT-002: Single-function codegen E2E
#
# Strategy: Compile compile_from_ir_prebaked as a SINGLE function with
# optimize=true (Julia inlines callees into ~770 stmts). Then test execution.
#
# The key: compile_from_ir_prebaked takes WasmModule + TypeRegistry as args,
# so Dict construction is avoided. TypeRegistry(Val(:minimal)) creates all-nothing fields.
#
# Run: julia +1.12 --project=. test/selfhost/build_int002_single.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, compile_from_ir_inplace,
                  compile_from_ir_prebaked, WasmModule, TypeRegistry,
                  wasm_bytes_length, wasm_bytes_get,
                  InplaceCompilationContext, AbstractCompilationContext

println("=" ^ 70)
println("INT-002: Single-Function Codegen E2E")
println("=" ^ 70)

# ═══════════════════════════════════════════════════════════════════════════
# Step 1: Pre-compute CodeInfo at build time
# ═══════════════════════════════════════════════════════════════════════════

ci_f, rt_f = Base.code_typed(x -> x * x + Int64(1), (Int64,))[1]
println("Target: f(x::Int64) = x*x+1 → $(length(ci_f.code)) stmts, return: $rt_f")

# Verify native E2E
native_bytes = compile_from_ir_inplace([(ci_f, Int64, (Int64,), "f")])
println("Native compile: $(length(native_bytes)) bytes")

# ═══════════════════════════════════════════════════════════════════════════
# Step 2: Create wrapper that captures CodeInfo + calls prebaked
# ═══════════════════════════════════════════════════════════════════════════

const _baked_ci = ci_f

# This function captures _baked_ci as a constant and calls the REAL codegen.
# With optimize=true, Julia inlines compile_from_ir_prebaked's body.
function wasm_codegen(mod::WasmModule, reg::TypeRegistry)::Vector{UInt8}
    entries = [(_baked_ci, Int64, (Int64,), "f")]
    return compile_from_ir_prebaked(entries, mod, reg)
end

# Verify natively
test_mod = WasmModule()
test_reg = TypeRegistry(Val(:minimal))
test_bytes = wasm_codegen(test_mod, test_reg)
println("wasm_codegen native: $(length(test_bytes)) bytes")

# Check IR
ci_wc, rt_wc = Base.code_typed(wasm_codegen, (WasmModule, TypeRegistry); optimize=true)[1]
n_stmts = length(ci_wc.code)
n_gif = count(x -> x isa Core.GotoIfNot, ci_wc.code)
n_inv = count(x -> x isa Expr && x.head === :invoke, ci_wc.code)
println("wasm_codegen IR: $n_stmts stmts, $n_gif GotoIfNots, $n_inv invokes")

# List all :invoke targets
println("\nInvoke targets in wasm_codegen:")
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
            println("  [$i] $(mi.def.name) :: $(mi.specTypes)")
        else
            println("  [$i] $(stmt.args[2]) (unknown MI)")
        end
    end
end

# ═══════════════════════════════════════════════════════════════════════════
# Step 3: Compile to WASM as single function
# ═══════════════════════════════════════════════════════════════════════════

println("\n--- Compiling to WASM ---")

# Also compile helper functions
ci_mod, rt_mod = Base.code_typed(WasmModule, (); optimize=true)[1]
ci_reg, rt_reg = Base.code_typed(TypeRegistry, (Val{:minimal},); optimize=true)[1]
ci_len, rt_len = Base.code_typed(wasm_bytes_length, (Vector{UInt8},); optimize=true)[1]
ci_get, rt_get = Base.code_typed(wasm_bytes_get, (Vector{UInt8}, Int32); optimize=true)[1]

entries = Any[
    (ci_wc, rt_wc, (WasmModule, TypeRegistry), "codegen", wasm_codegen),
    (ci_mod, rt_mod, (), "new_mod", WasmModule),
    (ci_reg, rt_reg, (Val{:minimal},), "new_reg", TypeRegistry),
    (ci_len, rt_len, (Vector{UInt8},), "bytes_len", wasm_bytes_length),
    (ci_get, rt_get, (Vector{UInt8}, Int32), "bytes_get", wasm_bytes_get),
]

# Try compiling each individually first
println("\nIndividual validation:")
for (ci, rt, args, name, f) in entries
    try
        mod = compile_module_from_ir(Any[(ci, rt, args, name, f)])
        bytes = WasmTarget.to_bytes(mod)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        ok = try
            run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=devnull, stdout=devnull))
            true
        catch; false; end
        println("  $name: $(length(bytes)) bytes → $(ok ? "PASS ✓" : "FAIL ✗")")
        rm(tmpf, force=true)
    catch e
        println("  $name: ERROR — $(sprint(showerror, e)[1:min(200,end)])")
    end
end

# Build combined module
println("\n--- Combined module ---")
mod = compile_module_from_ir(entries)
module_bytes = WasmTarget.to_bytes(mod)
output_path = joinpath(@__DIR__, "..", "..", "e2e-int002-single.wasm")
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

# ═══════════════════════════════════════════════════════════════════════════
# Step 4: Test in Node.js
# ═══════════════════════════════════════════════════════════════════════════

if valid
    println("\n--- E2E: Execute codegen in WASM ---")
    node_script = """
    const fs = require('fs');
    const bytes = fs.readFileSync(process.argv[2]);
    WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } }).then(async ({instance}) => {
        const e = instance.exports;
        console.log('Exports:', Object.keys(e).join(', '));

        try {
            // Create WasmModule and TypeRegistry in WASM
            console.log('Creating WasmModule...');
            const mod = e.new_mod();
            console.log('WasmModule:', mod ? 'created' : 'null');

            console.log('Creating TypeRegistry...');
            const reg = e.new_reg();
            console.log('TypeRegistry:', reg ? 'created' : 'null');

            // Run the REAL codegen in WASM
            console.log('Running codegen (compile_from_ir_prebaked)...');
            const wasm_output = e.codegen(mod, reg);
            console.log('Codegen returned:', typeof wasm_output, wasm_output);

            if (!wasm_output) {
                console.log('ERROR: codegen returned null/undefined');
                process.exit(1);
            }

            // Extract bytes
            const len = e.bytes_len(wasm_output);
            console.log('Output WASM:', len, 'bytes');

            const out = new Uint8Array(len);
            for (let i = 0; i < len; i++) {
                out[i] = e.bytes_get(wasm_output, i + 1);
            }

            // Compile and execute
            const compiled = await WebAssembly.instantiate(out);
            const f = compiled.instance.exports.f;
            const result = f(5n);
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
println("INT-002 single-function build complete")
println("=" ^ 70)
