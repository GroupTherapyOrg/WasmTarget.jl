# build_e2e_final.jl — INT-002-impl2-impl: Build final E2E self-hosting module
#
# Strategy: run_direct(opt=true) as entry + all its invoke targets.
# ictx_prebaked(opt=true) now validates (RC2 fix resolved i64/i32).
# generate_structured(ICtx, opt=true) has compile_statement/call/value INLINED.
#
# Run: julia +1.12 --project=. test/selfhost/build_e2e_final.jl

using WasmTarget
using WasmTarget: run_direct, run_e2e_baked, ictx_prebaked,
    WasmModule, TypeRegistry, InplaceCompilationContext,
    WasmValType, BasicBlock,
    analyze_blocks, generate_structured, generate_block_code,
    to_bytes_mvp, wasm_bytes_length, wasm_bytes_get,
    get_concrete_wasm_type, new_wasm_module, IntKeyMap,
    fix_broken_select_instructions, fix_numeric_to_ref_local_stores,
    fix_consecutive_local_sets, strip_excess_after_function_end,
    fix_local_get_set_type_mismatch, fix_array_len_wrap,
    fix_i64_local_in_i32_ops, fix_i32_wrap_after_i32_ops,
    compile_module_from_ir, compile_from_codeinfo

println("=" ^ 70)
println("INT-002-impl2-impl: Final E2E Self-Hosting Module")
println("=" ^ 70)

# ═══════════════════════════════════════════════════════════════════════════
# Step 1: Native verification
# ═══════════════════════════════════════════════════════════════════════════
println("\n--- Step 1: Native verification ---")
f_test(x::Int64) = x * x + Int64(1)
ci_test = Base.code_typed(f_test, (Int64,); optimize=true)[1][1]
native_result = run_direct(ci_test)
println("run_direct native: $(length(native_result)) bytes")
tmp = tempname() * ".wasm"
write(tmp, native_result)
node_result = strip(read(`node -e "WebAssembly.instantiate(require('fs').readFileSync('$tmp')).then(m=>console.log(String(m.instance.exports.f(5n))))"`, String))
rm(tmp, force=true)
println("f(5n) = $node_result (expected: 26)")

# ═══════════════════════════════════════════════════════════════════════════
# Step 2: Collect all functions for the module
# ═══════════════════════════════════════════════════════════════════════════
println("\n--- Step 2: Collect functions ---")

# Entry function: run_e2e_baked (0 params, returns Vector{UInt8})
entries = Any[]

# run_e2e_baked: zero-arg entry, calls run_direct
ci_eb, rt_eb = Base.code_typed(run_e2e_baked, (); optimize=true)[1]
push!(entries, (ci_eb, rt_eb, (), "run", run_e2e_baked))
println("  run (run_e2e_baked): $(length(ci_eb.code)) stmts")

# run_direct: core pipeline function
ci_rd, rt_rd = Base.code_typed(run_direct, (Any,); optimize=true)[1]
push!(entries, (ci_rd, rt_rd, (Any,), "run_direct", run_direct))
println("  run_direct: $(length(ci_rd.code)) stmts")

# Now collect all invoke targets from run_direct
invoke_targets = Dict{String, NamedTuple}()
for stmt in ci_rd.code
    if stmt isa Expr && stmt.head === :invoke && stmt.args[1] isa Core.CodeInstance
        mi = stmt.args[1].def
        name = String(mi.def.name)
        # Skip error handlers and closures
        if name in ("throw_boundserror", "throw_inexacterror")
            continue
        end
        if occursin("#_growend!", name)
            continue  # closure, can't resolve
        end
        sig = mi.specTypes
        key = "$name-$sig"
        if !haskey(invoke_targets, key)
            invoke_targets[key] = (name=name, mi=mi, sig=sig)
        end
    end
end

# Resolve function references and add to entries
for (key, info) in invoke_targets
    mi = info.mi
    func = nothing
    try
        f_type = mi.def.sig.parameters[1]
        if f_type isa DataType && isdefined(f_type, :instance)
            func = f_type.instance
        end
    catch; end

    if func === nothing
        println("  ? $(info.name): can't resolve → will be stubbed")
        continue
    end

    arg_types = tuple(info.sig.parameters[2:end]...)

    # Get code_typed
    opt = true
    try
        ci, rt = Base.code_typed(func, arg_types; optimize=opt)[1]
        push!(entries, (ci, rt, arg_types, info.name, func))
        println("  $(info.name): $(length(ci.code)) stmts ($(count(x->x isa Core.GotoIfNot, ci.code)) GIfN)")
    catch e
        println("  ✗ $(info.name): code_typed failed: $e")
    end
end

# Also add generate_block_code (called from generate_structured)
try
    ci_gbc, rt_gbc = Base.code_typed(generate_block_code, (InplaceCompilationContext, BasicBlock); optimize=true)[1]
    push!(entries, (ci_gbc, rt_gbc, (InplaceCompilationContext, BasicBlock), "generate_block_code", generate_block_code))
    println("  generate_block_code: $(length(ci_gbc.code)) stmts")
catch e
    println("  ✗ generate_block_code: $e")
end

# Add byte extraction helpers
ci_bl, rt_bl = Base.code_typed(wasm_bytes_length, (Vector{UInt8},); optimize=true)[1]
push!(entries, (ci_bl, rt_bl, (Vector{UInt8},), "bytes_len", wasm_bytes_length))
println("  bytes_len: $(length(ci_bl.code)) stmts")

ci_bg, rt_bg = Base.code_typed(wasm_bytes_get, (Vector{UInt8}, Int32); optimize=true)[1]
push!(entries, (ci_bg, rt_bg, (Vector{UInt8}, Int32), "bytes_get", wasm_bytes_get))
println("  bytes_get: $(length(ci_bg.code)) stmts")

println("\nTotal: $(length(entries)) functions")

# ═══════════════════════════════════════════════════════════════════════════
# Step 3: Individually validate each function
# ═══════════════════════════════════════════════════════════════════════════
println("\n--- Step 3: Individual validation ---")
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
            println("  ✗ $name: $(length(bytes))B — $(strip(result)[1:min(80,end)])")
        end
    catch e
        println("  ✗ $name: ERR $(sprint(showerror, e)[1:min(80,end)])")
    end
end
println("\nValid: $(length(valid_entries))/$(length(entries))")

# ═══════════════════════════════════════════════════════════════════════════
# Step 4: Build combined module
# ═══════════════════════════════════════════════════════════════════════════
println("\n--- Step 4: Combined module ---")
println("Functions: $(join([e[4] for e in valid_entries], ", "))")

output_path = joinpath(@__DIR__, "..", "..", "e2e-final.wasm")
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
# Step 5: E2E test
# ═══════════════════════════════════════════════════════════════════════════
if module_ok
    println("\n--- Step 5: E2E test ---")
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
                        console.log('The REAL WasmTarget codegen (generate_structured → compile_statement → compile_call)');
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
        "E2E NOT YET — module=$(module_ok ? "PASS" : "FAIL")")
    println("=" ^ 70)
else
    println("\n" * "=" ^ 70)
    println("Module validation failed — E2E test skipped")
    println("=" ^ 70)
end
