# INT-002-disc: Individual validation of transitive closure functions
#
# DISCOVERY ONLY — DO NOT WRITE FIX CODE
#
# Approach: Collect the same 78 functions as build_int002_closure.jl,
# then individually compile and validate each one.
# Identify which fail, which pass, and whether the failing ones are
# on the critical MVP path for f(x::Int64)=x*x+1.
#
# Run: julia +1.12 --project=. test/selfhost/int002_disc_individual_validation.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, compile_from_codeinfo,
                  CompilationContext, InplaceCompilationContext, AbstractCompilationContext,
                  WasmModule, TypeRegistry, FunctionRegistry,
                  compile_from_ir_prebaked, to_bytes_mvp, to_bytes,
                  wasm_bytes_length, wasm_bytes_get,
                  generate_body, get_concrete_wasm_type, needs_anyref_boxing,
                  add_function!, add_export!, populate_type_constant_globals!,
                  to_bytes_no_dict,
                  analyze_ssa_types!, analyze_control_flow!, allocate_ssa_locals!,
                  WasmStackValidator, IntKeyMap, WasmValType, I64,
                  encode_leb128_unsigned

println("=" ^ 70)
println("INT-002-disc: Individual Validation Discovery")
println("=" ^ 70)

# ═══════════════════════════════════════════════════════════════════════════
# Step 1: Collect transitive closure (same as build_int002_closure.jl)
# ═══════════════════════════════════════════════════════════════════════════

# Bake CodeInfo
ci_f, rt_f = Base.code_typed(x -> x * x + Int64(1), (Int64,))[1]
const _baked_ci = ci_f

# Entry function
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
                arg_types = try Tuple(params[2:end]) catch; continue end
                func_obj = try
                    func_type.instance
                catch
                    func_ref_expr = stmt.args[2]
                    if func_ref_expr isa GlobalRef
                        try getfield(func_ref_expr.mod, func_ref_expr.name) catch; nothing end
                    else nothing end
                end
                if func_obj !== nothing
                    push!(targets, (func_obj, arg_types))
                end
            end
        end
    end
    return targets
end

# BFS collection
collected = Dict{Tuple{Any, Tuple}, Any}()
to_process = Vector{Tuple{Any, Tuple}}()

ci_entry, rt_entry = Base.code_typed(wasm_codegen_mvp, (WasmModule, TypeRegistry); optimize=true)[1]
collected[(wasm_codegen_mvp, (WasmModule, TypeRegistry))] = (ci_entry, rt_entry, wasm_codegen_mvp)

for target in extract_invoke_targets(ci_entry)
    if !haskey(collected, target)
        push!(to_process, target)
    end
end

max_depth = 3
global depth = 0
while !isempty(to_process) && depth < max_depth
    global depth += 1
    current = copy(to_process)
    empty!(to_process)
    println("Depth $depth: $(length(current)) new functions")
    for (f, types) in current
        haskey(collected, (f, types)) && continue
        name = try string(nameof(f)) catch; string(f) end
        if occursin("throw_", name) || occursin("Error", name) || occursin("logger", name) ||
           occursin("handle_message", name) || occursin("fixup_stdlib", name) ||
           occursin("print_to_string", name) || occursin("access_env", name)
            continue
        end
        try
            ci, rt = Base.code_typed(f, types; optimize=true)[1]
            collected[(f, types)] = (ci, rt, f)
            for target in extract_invoke_targets(ci)
                if !haskey(collected, target)
                    push!(to_process, target)
                end
            end
        catch; end
    end
end

println("Total: $(length(collected)) functions collected")

# ═══════════════════════════════════════════════════════════════════════════
# Step 2: Individual validation of each function
# ═══════════════════════════════════════════════════════════════════════════

println("\n--- Individual Validation ---\n")

pass_funcs = []  # (name, func, types, ci, rt)
fail_funcs = []  # (name, func, types, ci, rt, error)

tmp_wasm = tempname() * ".wasm"

for ((f, types), (ci, rt, func_ref)) in collected
    all_valid = all(T -> T isa Type, types)
    if !all_valid
        continue
    end

    name = try string(nameof(f)) catch; "func_$(hash(f))" end

    # Compile individually via compile_from_codeinfo
    local valid = false
    local err_msg = ""
    try
        # compile_module_from_ir with single function entry
        entry = (ci, rt, types, name, func_ref)
        mod = compile_module_from_ir([entry])
        mbytes = to_bytes(mod)
        write(tmp_wasm, mbytes)
        valid = try
            run(pipeline(`wasm-tools validate --features=gc $tmp_wasm`, stderr=devnull, stdout=devnull))
            true
        catch
            err_msg = try
                strip(String(read(pipeline(`wasm-tools validate --features=gc $tmp_wasm`; stderr=stderr), String)))
            catch e
                sprint(showerror, e)
            end
            false
        end
    catch e
        err_msg = sprint(showerror, e)[1:min(200, end)]
        valid = false
    end

    if valid
        push!(pass_funcs, (name, f, types, ci, rt))
    else
        push!(fail_funcs, (name, f, types, ci, rt, err_msg))
    end
end

rm(tmp_wasm, force=true)

println("PASS: $(length(pass_funcs)) / $(length(pass_funcs) + length(fail_funcs))")
println("FAIL: $(length(fail_funcs))")

println("\n--- PASSING functions ---")
for (name, f, types, ci, rt) in sort(pass_funcs, by=x->x[1])
    type_str = join([string(T) for T in types], ", ")
    stmts = length(ci.code)
    gotoifnots = count(s -> s isa Core.GotoIfNot, ci.code)
    println("  ✓ $name($type_str) — $stmts stmts, $gotoifnots GotoIfNots")
end

println("\n--- FAILING functions ---")
for (name, f, types, ci, rt, err) in sort(fail_funcs, by=x->x[1])
    type_str = join([string(T) for T in types], ", ")
    stmts = length(ci.code)
    # Truncate error to first line
    err_line = split(err, "\n")[1]
    if length(err_line) > 120; err_line = err_line[1:120] * "..."; end
    println("  ✗ $name($type_str) — $stmts stmts — $err_line")
end

# ═══════════════════════════════════════════════════════════════════════════
# Step 3: Build combined module with ONLY validating functions
# ═══════════════════════════════════════════════════════════════════════════

println("\n--- Building combined module with validating functions only ---\n")

# Add helpers
ci_mod, rt_mod = Base.code_typed(() -> WasmModule(), (); optimize=true)[1]
ci_reg, rt_reg = Base.code_typed(() -> TypeRegistry(Val(:minimal)), (); optimize=true)[1]
ci_len, rt_len = Base.code_typed(wasm_bytes_length, (Vector{UInt8},); optimize=true)[1]
ci_get, rt_get = Base.code_typed(wasm_bytes_get, (Vector{UInt8}, Int32); optimize=true)[1]

entries = Any[]
push!(entries, (ci_mod, rt_mod, (), "new_mod", () -> WasmModule()))
push!(entries, (ci_reg, rt_reg, (), "new_reg", () -> TypeRegistry(Val(:minimal))))
push!(entries, (ci_len, rt_len, (Vector{UInt8},), "bytes_len", wasm_bytes_length))
push!(entries, (ci_get, rt_get, (Vector{UInt8}, Int32), "bytes_get", wasm_bytes_get))

# Add only passing functions
for (name, f, types, ci, rt) in pass_funcs
    push!(entries, (ci, rt, types, name, f))
end

println("Entries: $(length(entries)) (4 helpers + $(length(pass_funcs)) passing)")

# Compile
try
    mod = compile_module_from_ir(entries)
    mbytes = to_bytes(mod)
    output_path = joinpath(@__DIR__, "..", "..", "e2e-int002-filtered.wasm")
    write(output_path, mbytes)
    println("Module: $(length(mbytes)) bytes ($(round(length(mbytes)/1024, digits=1)) KB)")
    println("Exports: $(length(mod.exports))")

    valid = try
        run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
        true
    catch; false; end
    println("wasm-tools validate: $(valid ? "PASS ✓" : "FAIL ✗")")

    if !valid
        err = try String(read(pipeline(`wasm-tools validate --features=gc $output_path`; stderr=stderr), String)) catch e; sprint(showerror, e) end
        for line in split(err, "\n")[1:min(5,end)]
            println("  $line")
        end
    end
catch e
    println("Build ERROR: $(sprint(showerror, e)[1:min(300,end)])")
end

# ═══════════════════════════════════════════════════════════════════════════
# Step 4: Trace MVP critical path
# ═══════════════════════════════════════════════════════════════════════════

println("\n--- MVP Critical Path Analysis ---\n")

# Get invoke targets at depth 1 (direct callees of wasm_codegen_mvp)
direct_callees = extract_invoke_targets(ci_entry)
println("wasm_codegen_mvp has $(length(direct_callees)) direct :invoke targets:")

for (f, types) in direct_callees
    name = try string(nameof(f)) catch; "func_$(hash(f))" end
    type_str = join([string(T) for T in types], ", ")
    # Check if it's in pass or fail set
    is_pass = any(p -> p[1] == name && p[3] == types, pass_funcs)
    is_fail = any(p -> p[1] == name && p[3] == types, fail_funcs)
    status = is_pass ? "✓ PASS" : is_fail ? "✗ FAIL" : "? NOT IN SET"
    println("  $status  $name($type_str)")

    # If it passes, check ITS callees (depth 2)
    if is_pass || !is_fail
        try
            ci2, _ = Base.code_typed(f, types; optimize=true)[1]
            d2_targets = extract_invoke_targets(ci2)
            if !isempty(d2_targets)
                for (f2, types2) in d2_targets
                    name2 = try string(nameof(f2)) catch; "func_$(hash(f2))" end
                    type_str2 = join([string(T) for T in types2], ", ")
                    is_pass2 = any(p -> p[1] == name2 && p[3] == types2, pass_funcs)
                    is_fail2 = any(p -> p[1] == name2 && p[3] == types2, fail_funcs)
                    status2 = is_pass2 ? "✓" : is_fail2 ? "✗" : "?"
                    println("    └─ $status2 $name2($type_str2)")
                end
            end
        catch; end
    end
end

# ═══════════════════════════════════════════════════════════════════════════
# Step 5: Compare with INT-001 codegen functions
# ═══════════════════════════════════════════════════════════════════════════

println("\n--- Comparison: INT-001 codegen function set ---\n")
println("INT-001 included 25 codegen functions that all validated and combined.")
println("Key codegen functions in INT-001:")
for fname in ["compile_from_ir_prebaked", "generate_body", "to_bytes_no_dict",
              "encode_leb128_unsigned", "fix_consecutive_local_sets",
              "fix_broken_select_instructions", "fix_array_len_wrap",
              "compile_const_value"]
    in_pass = any(p -> startswith(p[1], fname), pass_funcs)
    in_fail = any(p -> startswith(p[1], fname), fail_funcs)
    status = in_pass ? "✓ in closure set" : in_fail ? "✗ fails individually" : "  not in closure set"
    println("  $status  $fname")
end

println("\n" * "=" ^ 70)
println("INT-002-disc discovery complete")
println("=" ^ 70)
