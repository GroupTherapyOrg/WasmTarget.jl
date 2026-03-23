# build_int002_closure.jl — INT-002: Transitive closure codegen E2E
#
# Strategy: Automatically collect ALL functions needed by wasm_codegen_mvp
# (transitive closure of :invoke targets), compile them all into one module.
# FunctionRegistry wires cross-function :invoke calls.
#
# Run: julia +1.12 --project=. test/selfhost/build_int002_closure.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, compile_from_ir_inplace,
                  compile_from_ir_prebaked, WasmModule, TypeRegistry,
                  wasm_bytes_length, wasm_bytes_get,
                  InplaceCompilationContext, AbstractCompilationContext,
                  FunctionRegistry, register_function!,
                  generate_body, get_concrete_wasm_type, needs_anyref_boxing,
                  add_function!, add_export!, populate_type_constant_globals!,
                  to_bytes_no_dict, to_bytes_mvp, _wasm_valtype_byte,
                  analyze_ssa_types!, analyze_control_flow!, allocate_ssa_locals!,
                  WasmStackValidator, IntKeyMap, WasmValType, I64,
                  encode_leb128_unsigned

println("=" ^ 70)
println("INT-002: Transitive Closure Codegen E2E")
println("=" ^ 70)

# Bake CodeInfo
ci_f, rt_f = Base.code_typed(x -> x * x + Int64(1), (Int64,))[1]
const _baked_ci = ci_f

# Entry function: codegen with closure-free serializer
function wasm_codegen_mvp(mod::WasmModule, reg::TypeRegistry)::Vector{UInt8}
    code_info = _baked_ci
    n_code = length(code_info.code)
    ctx = InplaceCompilationContext(
        code_info, (Int64,), Int64, Int(1),
        WasmValType[], IntKeyMap{Type}(n_code), IntKeyMap{Int}(n_code), IntKeyMap{Int}(n_code),
        fill(false, n_code), mod, reg,
        nothing, UInt32(0), nothing,
        Set{Int}(), false,
        nothing, nothing, nothing, nothing,
        Tuple{Tuple{Module, Symbol}, UInt32}[],
        nothing, nothing,
        WasmStackValidator(enabled=true, func_name="func_0"),
        false, nothing, nothing, nothing
    )
    analyze_ssa_types!(ctx)
    analyze_control_flow!(ctx)
    allocate_ssa_locals!(ctx)
    body = generate_body(ctx)
    locals = ctx.locals
    return to_bytes_mvp(body, locals)
end

# Verify native
test_bytes = wasm_codegen_mvp(WasmModule(), TypeRegistry(Val(:minimal)))
println("Native: $(length(test_bytes)) bytes, f(5n) = ", begin
    tmp = tempname() * ".wasm"; write(tmp, test_bytes)
    out = strip(read(`node -e "require('fs').readFileSync('$tmp').then||void 0;WebAssembly.instantiate(require('fs').readFileSync('$tmp')).then(m=>console.log(String(m.instance.exports.f(5n))))"`, String))
    rm(tmp, force=true); out
end)

# ═══════════════════════════════════════════════════════════════════════════
# Collect transitive closure of :invoke targets
# ═══════════════════════════════════════════════════════════════════════════

println("\n--- Collecting transitive closure ---")

# Track: (function, arg_types) → code_typed result
collected = Dict{Tuple{Any, Tuple}, Any}()  # (func, types) → (ci, rt, func_ref)
to_process = Vector{Tuple{Any, Tuple}}()

function extract_invoke_targets(ci)
    targets = Set{Tuple{Any, Tuple}}()
    for stmt in ci.code
        if stmt isa Expr && stmt.head === :invoke
            mi_or_ci = stmt.args[1]
            mi = if isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
                mi_or_ci.def
            elseif mi_or_ci isa Core.MethodInstance
                mi_or_ci
            else
                nothing
            end
            if mi !== nothing
                spec = mi.specTypes
                spec isa DataType || continue
                params = spec.parameters
                length(params) >= 1 || continue
                func_type = params[1]
                func_type isa DataType || continue

                # Get function object and arg types
                arg_types = try
                    Tuple(params[2:end])
                catch
                    continue
                end

                # Try singleton function
                func_obj = try
                    func_type.instance
                catch
                    # Try resolving from GlobalRef
                    func_ref_expr = stmt.args[2]
                    if func_ref_expr isa GlobalRef
                        try getfield(func_ref_expr.mod, func_ref_expr.name) catch; nothing end
                    else
                        nothing
                    end
                end

                if func_obj !== nothing
                    push!(targets, (func_obj, arg_types))
                end
            end
        end
    end
    return targets
end

# Seed with entry function
ci_entry, rt_entry = Base.code_typed(wasm_codegen_mvp, (WasmModule, TypeRegistry); optimize=true)[1]
collected[(wasm_codegen_mvp, (WasmModule, TypeRegistry))] = (ci_entry, rt_entry, wasm_codegen_mvp)

# Add entry's invoke targets
for target in extract_invoke_targets(ci_entry)
    if !haskey(collected, target)
        push!(to_process, target)
    end
end

# BFS: collect all transitive callees (limit depth to avoid explosion)
max_depth = 3
global depth = 0
while !isempty(to_process) && depth < max_depth
    global depth += 1
    current = copy(to_process)
    empty!(to_process)
    println("Depth $depth: $(length(current)) new functions")

    for (f, types) in current
        haskey(collected, (f, types)) && continue

        # Skip error/logging functions — they're safe to stub
        name = try string(nameof(f)) catch; string(f) end
        if occursin("throw_", name) || occursin("Error", name) || occursin("logger", name) ||
           occursin("handle_message", name) || occursin("fixup_stdlib", name) ||
           occursin("print_to_string", name) || occursin("access_env", name)
            continue
        end

        try
            ci, rt = Base.code_typed(f, types; optimize=true)[1]
            collected[(f, types)] = (ci, rt, f)

            # Add this function's invoke targets
            for target in extract_invoke_targets(ci)
                if !haskey(collected, target)
                    push!(to_process, target)
                end
            end
        catch e
            # Can't get code_typed — skip
            # println("  SKIP: $name — $(sprint(showerror, e)[1:min(80,end)])")
        end
    end
end

println("\nTotal: $(length(collected)) functions collected (depth=$depth)")

# ═══════════════════════════════════════════════════════════════════════════
# Build module entries
# ═══════════════════════════════════════════════════════════════════════════

# Add helper functions
ci_mod, rt_mod = Base.code_typed(() -> WasmModule(), (); optimize=true)[1]
ci_reg, rt_reg = Base.code_typed(() -> TypeRegistry(Val(:minimal)), (); optimize=true)[1]
ci_len, rt_len = Base.code_typed(wasm_bytes_length, (Vector{UInt8},); optimize=true)[1]
ci_get, rt_get = Base.code_typed(wasm_bytes_get, (Vector{UInt8}, Int32); optimize=true)[1]

entries = Any[]
push!(entries, (ci_mod, rt_mod, (), "new_mod", () -> WasmModule()))
push!(entries, (ci_reg, rt_reg, (), "new_reg", () -> TypeRegistry(Val(:minimal))))
push!(entries, (ci_len, rt_len, (Vector{UInt8},), "bytes_len", wasm_bytes_length))
push!(entries, (ci_get, rt_get, (Vector{UInt8}, Int32), "bytes_get", wasm_bytes_get))

# Add collected functions (filter out entries with Vararg or other non-Type arg types)
let n_skip = 0
    for ((f, types), (ci, rt, func_ref)) in collected
        all_valid = all(T -> T isa Type, types)
        if !all_valid
            n_skip += 1
            continue
        end
        name = try string(nameof(f)) catch; "func_$(hash(f))" end
        push!(entries, (ci, rt, types, name, func_ref))
    end
    println("Skipped $n_skip entries with non-Type arg types")
end

println("Module entries: $(length(entries))")

# ═══════════════════════════════════════════════════════════════════════════
# Compile to WASM
# ═══════════════════════════════════════════════════════════════════════════

println("\n--- Compiling module ---")
mod = compile_module_from_ir(entries)
module_bytes = WasmTarget.to_bytes(mod)
output_path = joinpath(@__DIR__, "..", "..", "e2e-int002-closure.wasm")
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
# Test in Node.js
# ═══════════════════════════════════════════════════════════════════════════

if valid
    println("\n--- E2E: Execute codegen in WASM ---")
    node_script = """
    const fs = require('fs');
    const bytes = fs.readFileSync(process.argv[2]);
    WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } }).then(async ({instance}) => {
        const e = instance.exports;
        console.log('Exports:', Object.keys(e).length);
        try {
            const mod = e.new_mod();
            console.log('WasmModule:', mod ? 'OK' : 'null');
            const reg = e.new_reg();
            console.log('TypeRegistry:', reg ? 'OK' : 'null');
            console.log('Running codegen...');
            const output = e.wasm_codegen_mvp(mod, reg);
            console.log('Output:', output ? 'non-null' : 'null');
            if (!output) { console.log('ERROR: null'); process.exit(1); }
            const len = e.bytes_len(output);
            console.log('WASM bytes:', len);
            const out = new Uint8Array(len);
            for (let i = 0; i < len; i++) out[i] = e.bytes_get(output, i + 1);
            const compiled = await WebAssembly.instantiate(out);
            const result = compiled.instance.exports.f(5n);
            console.log('f(5n) =', String(result));
            if (result === 26n) {
                console.log('\\n=== SUCCESS: f(5n) === 26n ===');
                console.log('REAL codegen (generate_body pipeline) executing in WASM!');
            } else {
                console.log('WRONG:', String(result));
            }
        } catch(err) {
            console.log('TRAP:', err.message);
        }
    }).catch(e => console.error('Load:', e.message));
    """
    np = tempname() * ".cjs"; write(np, node_script)
    try; result = read(`node $np $output_path`, String); println(strip(result))
    catch e; println("Node: $(sprint(showerror, e)[1:min(200,end)])"); end
    rm(np, force=true)
end

println("\n" * "=" ^ 70)
println("INT-002 closure build complete")
println("=" ^ 70)
