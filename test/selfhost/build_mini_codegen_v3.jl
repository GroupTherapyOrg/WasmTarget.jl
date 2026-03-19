# PHASE-1M-004: Build self-hosted-codegen-mini.wasm (v3 — full transitive closure)
#
# Strategy: Discover ALL WasmTarget functions transitively reachable from generate_body.
# Compile every one that produces valid IR. Assemble into a multi-function module.
# Skip Base/Core functions that can't be compiled.
#
# Run: julia +1.12 --project=. test/selfhost/build_mini_codegen_v3.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, get_typed_ir, to_bytes,
                  CompilationContext, WasmModule, TypeRegistry, FunctionRegistry,
                  compile_const_value, get_concrete_wasm_type,
                  encode_leb128_signed, encode_leb128_unsigned,
                  build_frozen_state, compile_module_from_ir_frozen,
                  preprocess_ir_entries, FrozenCompilationState, BasicBlock,
                  WasmValType

using JSON, Dates

println("=" ^ 60)
println("PHASE-1M-004: Building self-hosted-codegen-mini.wasm (v3)")
println("  Strategy: transitive closure of generate_body")
println("=" ^ 60)

# ─── Step 1: Discover transitive WasmTarget function dependencies ─────────

"""Extract (method_instance, method_name, arg_types) from :invoke calls in CodeInfo."""
function find_invokes(ci)
    result = []
    for stmt in ci.code
        if stmt isa Expr && stmt.head == :invoke
            mi = stmt.args[1]
            try
                method = mi.def  # MethodInstance
                f = method.specTypes.parameters[1]
                sig = method.specTypes
                push!(result, (mi, method, f, sig))
            catch
            end
        end
    end
    return result
end

"""Check if a method belongs to WasmTarget module."""
function is_wasmtarget_method(method)
    try
        mod = method.def.module
        return mod === WasmTarget || string(mod) == "WasmTarget"
    catch
        return false
    end
end

function discover_functions()
    println("\n--- Step 1: Discovering transitive function dependencies ---")

    # Seed: generate_body and its immediate dependencies
    seed_functions = [
        (WasmTarget.generate_body, (CompilationContext,), "generate_body"),
        (WasmTarget.analyze_blocks, (Vector{Any},), "analyze_blocks"),
    ]

    # Track discovered functions
    discovered = Dict{String, Tuple{Any, Any, Any, Any, String}}()
    work_queue = copy(seed_functions)
    processed_sigs = Set{String}()

    iteration = 0
    while !isempty(work_queue)
        iteration += 1
        f, arg_types, name = popfirst!(work_queue)
        sig_key = "$f|$(arg_types)"

        sig_key in processed_sigs && continue
        push!(processed_sigs, sig_key)

        try
            ci, rt = Base.code_typed(f, arg_types)[1]
            key = name
            if haskey(discovered, key)
                key = "$(name)_$(hash(arg_types) % 10000)"
            end
            discovered[key] = (f, arg_types, ci, rt, key)
            println("  [$(iteration)] $key: $(length(ci.code)) stmts → $rt")

            # Find WasmTarget invokes
            for (mi, method, func_type, sig) in find_invokes(ci)
                if is_wasmtarget_method(method)
                    method_name = string(method.def.name)
                    actual_types = Tuple(sig.parameters[2:end])
                    new_sig_key = "$func_type|$(actual_types)"
                    if !(new_sig_key in processed_sigs)
                        try
                            actual_f = getfield(WasmTarget, method.def.name)
                            push!(work_queue, (actual_f, actual_types, method_name))
                        catch
                        end
                    end
                end
            end
        catch e
            println("  [$(iteration)] $name: SKIP — $(sprint(showerror, e)[1:min(150,end)])")
        end
    end

    println("\n  Discovered $(length(discovered)) compilable WasmTarget functions")
    return discovered, processed_sigs
end

function build_ir_entries(discovered, processed_sigs)
    println("\n--- Step 2: Building IR entries ---")

    ir_entries = []
    total_stmts = 0
    for (key, (f, arg_types, ci, rt, name)) in sort(collect(discovered), by=x->x[1])
        push!(ir_entries, (ci, rt, arg_types, name))
        total_stmts += length(ci.code)
    end
    println("  $(length(ir_entries)) functions, $(total_stmts) total IR statements")

    # Also add LEB128 encoding functions (utility)
    println("\n--- Step 3: Adding utility functions ---")
    utility_functions = [
        (encode_leb128_signed, (Int32,), "encode_leb128_signed_i32"),
        (encode_leb128_signed, (Int64,), "encode_leb128_signed_i64"),
        (encode_leb128_unsigned, (UInt32,), "encode_leb128_unsigned"),
        (compile_const_value, (Int32, WasmModule, TypeRegistry), "compile_const_value_i32"),
        (compile_const_value, (Int64, WasmModule, TypeRegistry), "compile_const_value_i64"),
        (compile_const_value, (Float64, WasmModule, TypeRegistry), "compile_const_value_f64"),
        (compile_const_value, (Bool, WasmModule, TypeRegistry), "compile_const_value_bool"),
    ]

    for (f, arg_types, name) in utility_functions
        sig_key = "$f|$(arg_types)"
        if !(sig_key in processed_sigs)
            try
                ci, rt = Base.code_typed(f, arg_types)[1]
                push!(ir_entries, (ci, rt, arg_types, name))
                println("  + $name: $(length(ci.code)) stmts")
                total_stmts += length(ci.code)
            catch e
                println("  - $name: SKIP")
            end
        else
            println("  ~ $name: already discovered")
        end
    end

    println("\n  Final: $(length(ir_entries)) functions, $(total_stmts) total IR statements")
    return ir_entries, total_stmts
end

function compile_and_save(ir_entries, total_stmts)
    println("\n--- Step 4: Compiling multi-function WASM module ---")
    println("  This may take 1-10 minutes for large codegen functions...")

    t0 = time()
    mod = compile_module_from_ir(ir_entries)
    bytes = to_bytes(mod)
    elapsed = time() - t0

    println("  SUCCESS: $(length(bytes)) bytes ($(round(length(bytes)/1024, digits=1)) KB) in $(round(elapsed, digits=1))s")
    println("  Functions: $(length(mod.functions))")
    println("  Types: $(length(mod.types))")
    println("  Exports: $(length(mod.exports))")

    println("\n  Exports:")
    for exp in mod.exports
        println("    - $(exp.name) (kind=$(exp.kind), idx=$(exp.idx))")
    end

    # Save module
    output_path = joinpath(@__DIR__, "..", "..", "self-hosted-codegen-mini.wasm")
    write(output_path, bytes)
    println("\n  Saved to $output_path")

    # Validate
    wasm_tools = Sys.which("wasm-tools")
    if wasm_tools !== nothing
        try
            run(pipeline(`$(wasm_tools) validate --features all $(output_path)`, stdout=devnull, stderr=devnull))
            println("  wasm-tools validate: PASS")
        catch
            println("  wasm-tools validate: FAIL")
            try
                err = Base.read(pipeline(`$(wasm_tools) validate --features all $(output_path)`, stderr=stdout), String)
                println("    $err")
            catch e2
                println("    $(sprint(showerror, e2)[1:min(200,end)])")
            end
        end
    end

    # Test loading in Node.js
    node = Sys.which("node")
    if node !== nothing
        js_code = """
        const fs = require('fs');
        const buf = fs.readFileSync('$(output_path)');
        WebAssembly.compile(buf).then(mod => {
            const exps = WebAssembly.Module.exports(mod);
            console.log('Node.js: OK, ' + exps.length + ' exports');
        }).catch(e => {
            console.error('Node.js FAIL: ' + e.message.substring(0, 300));
            process.exit(1);
        });
        """
        try
            result = Base.read(`$(node) -e $(js_code)`, String)
            print("  $result")
        catch e
            println("  Node.js load: FAIL — $(sprint(showerror, e)[1:min(200,end)])")
        end
    end

    # Save metadata
    metadata = Dict(
        "story" => "PHASE-1M-004",
        "timestamp" => string(Dates.now()),
        "version" => "v3-transitive",
        "functions_compiled" => length(ir_entries),
        "function_names" => [name for (_, _, _, name) in ir_entries],
        "total_ir_stmts" => total_stmts,
        "wasm_bytes" => length(bytes),
        "wasm_kb" => round(length(bytes)/1024, digits=1),
        "compile_time_s" => round(elapsed, digits=1),
        "module_functions" => length(mod.functions),
        "module_types" => length(mod.types),
        "module_exports" => length(mod.exports),
        "acceptance_size" => length(bytes) < 5_000_000 ? "PASS (< 5 MB)" : "FAIL (> 5 MB)",
    )

    meta_path = joinpath(@__DIR__, "mini_codegen_build_results.json")
    open(meta_path, "w") do io
        JSON.print(io, metadata, 2)
    end
    println("\n  Metadata saved to $meta_path")

    return bytes, mod
end

# ─── Main execution ──────────────────────────────────────────────────────

discovered, processed_sigs = discover_functions()
ir_entries, total_stmts = build_ir_entries(discovered, processed_sigs)

try
    bytes, mod = compile_and_save(ir_entries, total_stmts)
    println("\n=== PHASE-1M-004 v3: Build complete ===")
    println("  Size: $(round(length(bytes)/1024, digits=1)) KB (budget: 5 MB)")
    println("  Functions: $(length(ir_entries)) compiled")
catch e
    println("\n  COMPILATION FAILED:")
    msg = sprint(showerror, e)
    println("  $(msg[1:min(2000,end)])")
    println("\n=== PHASE-1M-004 v3: Build FAILED ===")
end
