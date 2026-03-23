# INT-002-disc part 2: Get exact validation errors for failing functions
#
# Run: julia +1.12 --project=. test/selfhost/int002_disc_errors.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, to_bytes,
                  InplaceCompilationContext, AbstractCompilationContext,
                  WasmModule, TypeRegistry,
                  generate_body, to_bytes_mvp,
                  analyze_ssa_types!, analyze_control_flow!, allocate_ssa_locals!,
                  WasmStackValidator, IntKeyMap, WasmValType, I64,
                  needs_local, infer_call_type, generate_loop_code,
                  register_struct_type!, register_vector_type!,
                  wasm_bytes_length, wasm_bytes_get,
                  compile_from_ir_prebaked

println("=" ^ 70)
println("INT-002-disc: Exact Validation Errors for Failing Functions")
println("=" ^ 70)

# Bake CodeInfo
ci_f, rt_f = Base.code_typed(x -> x * x + Int64(1), (Int64,))[1]
const _baked_ci = ci_f

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

# List of failing functions to analyze
failing_functions = [
    ("wasm_codegen_mvp", wasm_codegen_mvp, (WasmModule, TypeRegistry)),
    ("analyze_ssa_types!", analyze_ssa_types!, (InplaceCompilationContext,)),
    ("analyze_control_flow!", analyze_control_flow!, (InplaceCompilationContext,)),
    ("allocate_ssa_locals!", allocate_ssa_locals!, (InplaceCompilationContext,)),
    ("generate_body", generate_body, (InplaceCompilationContext,)),
    ("generate_loop_code", generate_loop_code, (InplaceCompilationContext,)),
    ("infer_call_type", infer_call_type, (Expr, InplaceCompilationContext)),
    ("needs_local", needs_local, (InplaceCompilationContext, Int64)),
    ("register_struct_type!", register_struct_type!, (WasmModule, TypeRegistry, DataType)),
    ("register_vector_type!", register_vector_type!, (WasmModule, TypeRegistry, Type)),
]

tmp_wasm = tempname() * ".wasm"

for (name, func, types) in failing_functions
    println("\n--- $name ---")

    # Get code_typed info
    try
        ci, rt = Base.code_typed(func, types; optimize=true)[1]
        stmts = length(ci.code)
        gotoifnots = count(s -> s isa Core.GotoIfNot, ci.code)
        println("  stmts=$stmts, GotoIfNots=$gotoifnots, return=$rt")
    catch e
        println("  code_typed ERROR: $(sprint(showerror, e)[1:min(100,end)])")
    end

    # Compile and validate
    try
        ci, rt = Base.code_typed(func, types; optimize=true)[1]
        entry = (ci, rt, types, name, func)
        mod = compile_module_from_ir([entry])
        mbytes = to_bytes(mod)
        write(tmp_wasm, mbytes)
        println("  module: $(length(mbytes)) bytes")

        # Get error
        err_io = IOBuffer()
        try
            run(pipeline(`wasm-tools validate --features=gc $tmp_wasm`, stderr=err_io, stdout=devnull))
            println("  SURPRISE: PASSES!")
        catch
            err = String(take!(err_io))
            for line in split(strip(err), "\n")
                println("  ERROR: $line")
            end
        end
    catch e
        println("  compile ERROR: $(sprint(showerror, e)[1:min(200,end)])")
    end
end

rm(tmp_wasm, force=true)

# ═══════════════════════════════════════════════════════════════════════════
# Compare: CompilationContext vs InplaceCompilationContext
# ═══════════════════════════════════════════════════════════════════════════

println("\n" * "=" ^ 70)
println("Comparison: generate_body with CompilationContext vs InplaceCompilationContext")
println("=" ^ 70)

using WasmTarget: CompilationContext

for (ctx_type, ctx_name) in [
    (CompilationContext, "CompilationContext"),
    (InplaceCompilationContext, "InplaceCompilationContext")
]
    println("\n  generate_body($ctx_name):")
    try
        ci, rt = Base.code_typed(generate_body, (ctx_type,); optimize=true)[1]
        stmts = length(ci.code)
        gotoifnots = count(s -> s isa Core.GotoIfNot, ci.code)
        println("    stmts=$stmts, GotoIfNots=$gotoifnots, return=$rt")

        entry = (ci, rt, (ctx_type,), "generate_body", generate_body)
        mod = compile_module_from_ir([entry])
        mbytes = to_bytes(mod)
        write(tmp_wasm * ".tmp", mbytes)
        println("    module: $(length(mbytes)) bytes")

        err_io = IOBuffer()
        try
            run(pipeline(`wasm-tools validate --features=gc $(tmp_wasm).tmp`, stderr=err_io, stdout=devnull))
            println("    validate: PASS ✓")
        catch
            err = String(take!(err_io))
            first_line = split(strip(err), "\n")[1]
            println("    validate: FAIL — $first_line")
        end
        rm("$(tmp_wasm).tmp", force=true)
    catch e
        println("    ERROR: $(sprint(showerror, e)[1:min(200,end)])")
    end
end

# Also check compile_from_ir_prebaked (which works with CompilationContext internally)
println("\n  compile_from_ir_prebaked (uses CompilationContext internally):")
try
    ci, rt = Base.code_typed(compile_from_ir_prebaked, (Vector, WasmModule, TypeRegistry); optimize=true)[1]
    stmts = length(ci.code)
    gotoifnots = count(s -> s isa Core.GotoIfNot, ci.code)
    println("    stmts=$stmts, GotoIfNots=$gotoifnots, return=$rt")

    entry = (ci, rt, (Vector, WasmModule, TypeRegistry), "compile_from_ir_prebaked", compile_from_ir_prebaked)
    mod = compile_module_from_ir([entry])
    mbytes = to_bytes(mod)
    write("$(tmp_wasm).tmp", mbytes)
    println("    module: $(length(mbytes)) bytes")

    err_io = IOBuffer()
    try
        run(pipeline(`wasm-tools validate --features=gc $(tmp_wasm).tmp`, stderr=err_io, stdout=devnull))
        println("    validate: PASS ✓")
    catch
        err = String(take!(err_io))
        first_line = split(strip(err), "\n")[1]
        println("    validate: FAIL — $first_line")
    end
    rm("$(tmp_wasm).tmp", force=true)
catch e
    println("    ERROR: $(sprint(showerror, e)[1:min(200,end)])")
end

println("\n" * "=" ^ 70)
println("Discovery complete")
println("=" ^ 70)
