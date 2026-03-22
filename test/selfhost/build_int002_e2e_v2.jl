# build_int002_e2e_v2.jl — INT-002: Separated constructor E2E self-hosting
#
# Strategy: Separate WasmModule/TypeRegistry construction from codegen.
# - compile_from_ir_prebaked: proven to validate as single function (22KB)
# - wasm_create_module: tiny (35 stmts, 0 invokes)
# - JS orchestrates: mod = create_module(), result = compile(mod)
#
# Run: julia +1.12 --project=. test/selfhost/build_int002_e2e_v2.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, compile_from_ir_inplace,
                  compile_from_ir_prebaked, WasmModule, TypeRegistry,
                  wasm_bytes_length, wasm_bytes_get,
                  InplaceCompilationContext, AbstractCompilationContext

println("=" ^ 70)
println("INT-002 v2: Separated Constructor E2E Self-Hosting")
println("=" ^ 70)

# ═══════════════════════════════════════════════════════════════════════════
# Step 1: Pre-compute CodeInfo at build time
# ═══════════════════════════════════════════════════════════════════════════

ci_f, rt_f = Base.code_typed(x -> x * x + Int64(1), (Int64,))[1]
println("Target: f(x::Int64) = x*x+1 → $(length(ci_f.code)) stmts, return: $rt_f")

# Verify native E2E
native_bytes = compile_from_ir_inplace([(ci_f, Int64, (Int64,), "f")])
println("Native compile: $(length(native_bytes)) bytes")
tmpfile = tempname() * ".wasm"
write(tmpfile, native_bytes)
native_ok = try
    run(pipeline(`wasm-tools validate --features=gc $tmpfile`, stderr=devnull, stdout=devnull))
    true
catch; false; end
println("Native validate: $(native_ok ? "PASS" : "FAIL")")
if native_ok
    out = strip(read(`node -e "
    const bytes = require('fs').readFileSync('$tmpfile');
    WebAssembly.instantiate(bytes).then(m => console.log(String(m.instance.exports.f(5n))));
    "`, String))
    println("Native f(5n) = $out")
end
rm(tmpfile, force=true)

# ═══════════════════════════════════════════════════════════════════════════
# Step 2: Define WASM-compilable functions
# ═══════════════════════════════════════════════════════════════════════════

const _baked_ci = ci_f

# Function A: Codegen — takes pre-baked WasmModule + TypeRegistry
# This is compile_from_ir_prebaked with the CodeInfo captured as a constant.
# With optimize=true, Julia inlines compile_from_ir_prebaked's body.
function wasm_compile_f_prebaked(mod::WasmModule, reg::TypeRegistry)::Vector{UInt8}
    entries = [(_baked_ci, Int64, (Int64,), "f")]
    return compile_from_ir_prebaked(entries, mod, reg)
end

# Function B: Create WasmModule — tiny, 0 invokes
function wasm_create_module()::WasmModule
    return WasmModule()
end

# Function C: Create TypeRegistry — all nothing, inlined to %new
function wasm_create_registry()::TypeRegistry
    return TypeRegistry(Val(:minimal))
end

# Verify native E2E
test_mod = wasm_create_module()
test_reg = wasm_create_registry()
test_bytes = wasm_compile_f_prebaked(test_mod, test_reg)
println("\nSeparated native: $(length(test_bytes)) bytes")

# Check IR for each function
for (name, f, args) in [
    ("wasm_compile_f_prebaked", wasm_compile_f_prebaked, (WasmModule, TypeRegistry)),
    ("wasm_create_module", wasm_create_module, ()),
    ("wasm_create_registry", wasm_create_registry, ()),
]
    ci, rt = Base.code_typed(f, args; optimize=true)[1]
    n_stmts = length(ci.code)
    n_gif = count(x -> x isa Core.GotoIfNot, ci.code)
    n_inv = count(x -> x isa Expr && x.head === :invoke, ci.code)
    println("  $name: $n_stmts stmts, $n_gif GotoIfNots, $n_inv invokes")
end

# ═══════════════════════════════════════════════════════════════════════════
# Step 3: Compile each function individually — validate each
# ═══════════════════════════════════════════════════════════════════════════

println("\n--- Individual validation ---")

funcs_to_compile = [
    (wasm_compile_f_prebaked, (WasmModule, TypeRegistry), "wasm_compile_f"),
    (wasm_create_module, (), "wasm_create_module"),
    (wasm_create_registry, (), "wasm_create_registry"),
    (wasm_bytes_length, (Vector{UInt8},), "wasm_bytes_length"),
    (wasm_bytes_get, (Vector{UInt8}, Int32), "wasm_bytes_get"),
]

individual_results = []
for (f, args, name) in funcs_to_compile
    ci, rt = Base.code_typed(f, args; optimize=true)[1]
    entry = Any[(ci, rt, args, name, f)]
    try
        mod = compile_module_from_ir(entry)
        bytes = WasmTarget.to_bytes(mod)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        ok = try
            run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=devnull, stdout=devnull))
            true
        catch; false; end
        println("  $name: $(length(bytes)) bytes → $(ok ? "PASS ✓" : "FAIL ✗")")
        push!(individual_results, (name, ok, length(bytes)))
        rm(tmpf, force=true)
    catch e
        println("  $name: COMPILE ERROR — $(sprint(showerror, e)[1:min(100,end)])")
        push!(individual_results, (name, false, 0))
    end
end

all_pass = all(r -> r[2], individual_results)
println("\nIndividual validation: $(count(r -> r[2], individual_results))/$(length(individual_results)) PASS")

# ═══════════════════════════════════════════════════════════════════════════
# Step 4: Compile combined module
# ═══════════════════════════════════════════════════════════════════════════

println("\n--- Combined module ---")

entries = Any[]
for (f, args, name) in funcs_to_compile
    ci, rt = Base.code_typed(f, args; optimize=true)[1]
    push!(entries, (ci, rt, args, name, f))
end

mod = compile_module_from_ir(entries)
module_bytes = WasmTarget.to_bytes(mod)
println("Module: $(length(module_bytes)) bytes ($(round(length(module_bytes)/1024, digits=1)) KB)")
println("Exports: $(length(mod.exports))")

output_path = joinpath(@__DIR__, "..", "..", "e2e-int002.wasm")
write(output_path, module_bytes)

valid = try
    run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
    true
catch; false; end
println("wasm-tools validate: $(valid ? "PASS ✓" : "FAIL ✗")")

if !valid
    err_output = try
        String(read(pipeline(`wasm-tools validate --features=gc $output_path`; stderr=stderr)))
    catch e
        sprint(showerror, e)
    end
    for line in split(err_output, "\n")[1:min(5, end)]
        println("  $line")
    end
end

if valid
    # ═══════════════════════════════════════════════════════════════════════
    # Step 5: Execute in Node.js — THE CRITICAL TEST
    # ═══════════════════════════════════════════════════════════════════════

    println("\n--- E2E: Execute codegen in WASM ---")

    node_script = raw"""
    const fs = require('fs');
    const bytes = fs.readFileSync(process.argv[2]);
    WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } }).then(async ({instance}) => {
        const e = instance.exports;
        console.log('Exports:', Object.keys(e).join(', '));

        try {
            // Step 1: Create WasmModule and TypeRegistry in WASM
            console.log('Creating WasmModule...');
            const mod = e.wasm_create_module();
            console.log('Creating TypeRegistry...');
            const reg = e.wasm_create_registry();

            // Step 2: Run the REAL codegen in WASM
            console.log('Running codegen...');
            const wasm_output = e.wasm_compile_f(mod, reg);
            console.log('Codegen returned:', typeof wasm_output);

            // Step 3: Extract compiled bytes
            const len = e.wasm_bytes_length(wasm_output);
            console.log('Output WASM:', len, 'bytes');

            const out = new Uint8Array(len);
            for (let i = 0; i < len; i++) {
                out[i] = e.wasm_bytes_get(wasm_output, i + 1);
            }

            // Step 4: Compile and execute
            const compiled = await WebAssembly.instantiate(out);
            const result = compiled.instance.exports.f(5n);
            console.log('f(5n) =', String(result));

            if (result === 26n) {
                console.log('SUCCESS: f(5n) === 26n — REAL codegen in WASM!');
            } else {
                console.log('WRONG: expected 26n, got', String(result));
            }
        } catch(err) {
            console.log('TRAP:', err.message);
        }
    }).catch(e => console.error('Load failed:', e.message));
    """

    node_script_path = tempname() * ".js"
    write(node_script_path, node_script)
    try
        result = read(`node $node_script_path $output_path`, String)
        println(strip(result))
    catch e
        println("Node.js failed: $(sprint(showerror, e)[1:min(300,end)])")
    end
    rm(node_script_path, force=true)
end

println("\n" * "=" ^ 70)
println("INT-002 v2 build complete")
println("=" ^ 70)
