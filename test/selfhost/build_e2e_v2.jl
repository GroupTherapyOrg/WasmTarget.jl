# build_e2e_v2.jl — INT-002-e2e-impl: Build E2E self-hosting module
#
# Strategy: run_selfhost_v2 calls generate_block_code (now @inline) which brings
# ALL compile_statement/call/value logic into ONE function. No cross-function
# Core IR type divergence. Safe cross-function calls only: new_wasm_module,
# to_bytes_mvp (Vector{UInt8}), bytes_len, bytes_get.
#
# Run: julia +1.12 --project=. test/selfhost/build_e2e_v2.jl

using WasmTarget
using WasmTarget: run_selfhost_v2, new_wasm_module,
    to_bytes_mvp, wasm_bytes_length, wasm_bytes_get,
    compile_module_from_ir, compile_from_codeinfo,
    WasmModule, TypeRegistry, InplaceCompilationContext,
    WasmValType, BasicBlock

println("=" ^ 70)
println("INT-002-e2e-impl: E2E Self-Hosting via run_selfhost_v2")
println("=" ^ 70)

# ═══════════════════════════════════════════════════════════════════════════
# Step 1: Native verification
# ═══════════════════════════════════════════════════════════════════════════
println("\n--- Step 1: Native verification ---")
native_result = run_selfhost_v2()
println("run_selfhost_v2 native: $(length(native_result)) bytes")
tmp = tempname() * ".wasm"
write(tmp, native_result)
val_result = try read(`wasm-tools validate --features=gc $tmp`, String) catch e; "fail: $e" end
println("Validate: $(isempty(val_result) ? "PASS" : strip(val_result))")
node_out = strip(read(`node -e "WebAssembly.instantiate(require('fs').readFileSync('$tmp')).then(m=>console.log(String(m.instance.exports.f(5n))))"`, String))
rm(tmp, force=true)
println("f(5n) = $node_out (expected: 26)")

# ═══════════════════════════════════════════════════════════════════════════
# Step 2: Analyze code_typed for run_selfhost_v2
# ═══════════════════════════════════════════════════════════════════════════
println("\n--- Step 2: code_typed analysis ---")
ci_rsv2, rt_rsv2 = Base.code_typed(run_selfhost_v2, (); optimize=true)[1]
println("run_selfhost_v2: $(length(ci_rsv2.code)) stmts, $(count(x->x isa Core.GotoIfNot, ci_rsv2.code)) GIfN")

# Count invokes by name
invoke_names = String[]
for stmt in ci_rsv2.code
    if stmt isa Expr && stmt.head === :invoke && stmt.args[1] isa Core.CodeInstance
        push!(invoke_names, String(stmt.args[1].def.def.name))
    end
end
invoke_counts = Dict{String,Int}()
for n in invoke_names; invoke_counts[n] = get(invoke_counts, n, 0) + 1; end
println("Invokes ($(length(invoke_names))):")
for (n, c) in sort(collect(invoke_counts), by=x->-x[2])
    println("  $n: ×$c")
end

# ═══════════════════════════════════════════════════════════════════════════
# Step 3: Collect functions for module
# ═══════════════════════════════════════════════════════════════════════════
println("\n--- Step 3: Collect functions ---")
entries = Any[]

# 1. Entry: run_selfhost_v2 (zero-arg)
push!(entries, (ci_rsv2, rt_rsv2, (), "run", run_selfhost_v2))
println("  run (run_selfhost_v2): $(length(ci_rsv2.code)) stmts")

# 2. new_wasm_module (safe cross-function: returns WasmModule, no Core IR)
ci_nwm, rt_nwm = Base.code_typed(new_wasm_module, (); optimize=true)[1]
push!(entries, (ci_nwm, rt_nwm, (), "new_wasm_module", new_wasm_module))
println("  new_wasm_module: $(length(ci_nwm.code)) stmts")

# 3. to_bytes_mvp (safe cross-function: Vector{UInt8} only)
ci_tbm, rt_tbm = Base.code_typed(to_bytes_mvp, (Vector{UInt8}, Vector{WasmValType}); optimize=true)[1]
push!(entries, (ci_tbm, rt_tbm, (Vector{UInt8}, Vector{WasmValType}), "to_bytes_mvp", to_bytes_mvp))
println("  to_bytes_mvp: $(length(ci_tbm.code)) stmts")

# 4. bytes_len
ci_bl, rt_bl = Base.code_typed(wasm_bytes_length, (Vector{UInt8},); optimize=true)[1]
push!(entries, (ci_bl, rt_bl, (Vector{UInt8},), "bytes_len", wasm_bytes_length))
println("  bytes_len: $(length(ci_bl.code)) stmts")

# 5. bytes_get
ci_bg, rt_bg = Base.code_typed(wasm_bytes_get, (Vector{UInt8}, Int32); optimize=true)[1]
push!(entries, (ci_bg, rt_bg, (Vector{UInt8}, Int32), "bytes_get", wasm_bytes_get))
println("  bytes_get: $(length(ci_bg.code)) stmts")

println("\nTotal: $(length(entries)) functions")

# ═══════════════════════════════════════════════════════════════════════════
# Step 4: Individual validation
# ═══════════════════════════════════════════════════════════════════════════
println("\n--- Step 4: Individual validation ---")
valid_entries = Any[]
for (ci, rt, args, name, fref) in entries
    try
        bytes = compile_from_codeinfo(ci, rt, name, args)
        tmp = tempname() * ".wasm"
        write(tmp, bytes)
        result = try read(`wasm-tools validate --features=gc $tmp`, String) catch; "fail" end
        ok = isempty(result)
        rm(tmp, force=true)
        if ok
            push!(valid_entries, (ci, rt, args, name, fref))
            println("  ✓ $name: $(length(bytes))B")
        else
            println("  ✗ $name: $(length(bytes))B — $(strip(result)[1:min(100,end)])")
        end
    catch e
        println("  ✗ $name: ERR $(sprint(showerror, e)[1:min(100,end)])")
    end
end
println("\nValid: $(length(valid_entries))/$(length(entries))")

# ═══════════════════════════════════════════════════════════════════════════
# Step 5: Build combined module
# ═══════════════════════════════════════════════════════════════════════════
println("\n--- Step 5: Combined module ---")
output_path = joinpath(@__DIR__, "..", "..", "e2e-v2.wasm")
module_ok = false
try
    mod = compile_module_from_ir(valid_entries)
    mbytes = WasmTarget.to_bytes(mod)
    write(output_path, mbytes)
    result = try read(`wasm-tools validate --features=gc $output_path`, String) catch; "fail" end
    module_ok = isempty(result)
    println("Size: $(length(mbytes))B ($(round(length(mbytes)/1024, digits=1))KB)")
    println("Exports: $(length(mod.exports))")
    println("Validate: $(module_ok ? "PASS ✓" : "FAIL: $(strip(result)[1:min(120,end)])")")
catch e
    println("FAIL: $(sprint(showerror, e)[1:min(120,end)])")
end

# ═══════════════════════════════════════════════════════════════════════════
# Step 6: E2E test
# ═══════════════════════════════════════════════════════════════════════════
if module_ok
    println("\n--- Step 6: E2E test ---")
    js_code = """
    const fs = require('fs');
    const bytes = fs.readFileSync('$output_path');
    (async () => {
        try {
            const { instance } = await WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } });
            const e = instance.exports;
            console.log('Exports:', Object.keys(e).filter(k => typeof e[k] === 'function').join(', '));

            // Call run() - the zero-arg entry point
            console.log('Calling run()...');
            const wasm_bytes = e.run();

            if (wasm_bytes && e.bytes_len && e.bytes_get) {
                const n = e.bytes_len(wasm_bytes);
                console.log('Output:', n, 'bytes');

                if (n > 0) {
                    const output = new Uint8Array(n);
                    for (let i = 0; i < n; i++) output[i] = e.bytes_get(wasm_bytes, i + 1);
                    console.log('WASM header:', Array.from(output.slice(0, 8)).map(b => '0x' + b.toString(16).padStart(2, '0')).join(' '));

                    // Compile and run the output
                    const { instance: inner } = await WebAssembly.instantiate(output);
                    const f = inner.exports.f || inner.exports[Object.keys(inner.exports)[0]];
                    const result = f(5n);
                    console.log('f(5n) =', String(result));
                    console.log('f(5n) === 26n:', result === 26n);
                    if (result === 26n) {
                        console.log('');
                        console.log('SUCCESS: TRUE SELF-HOSTING E2E ACHIEVED!');
                        console.log('The REAL WasmTarget codegen (generate_block_code → compile_statement → compile_call)');
                        console.log('executed INSIDE WASM and produced valid WASM output.');
                    }
                }
            } else {
                console.log('run() returned:', wasm_bytes);
            }
        } catch (e) {
            console.log('Error:', e.message || e);
            if (e.stack) console.log(e.stack.split('\\n').slice(0, 5).join('\\n'));
        }
    })();
    """
    node_output = try read(`node -e $js_code`, String) catch e; "Error: $e" end
    for line in split(node_output, '\n')
        println("  $line")
    end

    e2e_ok = occursin("f(5n) === 26n: true", node_output)
    println("\n" * "=" ^ 70)
    println(e2e_ok ? "SUCCESS ✓ f(5n)===26n via TRUE SELF-HOSTING IN WASM" :
        "E2E NOT YET — module=$(module_ok ? "validates" : "FAIL")")
    println("=" ^ 70)
else
    println("\n" * "=" ^ 70)
    println("Module validation failed — E2E test skipped")
    println("=" ^ 70)
end
