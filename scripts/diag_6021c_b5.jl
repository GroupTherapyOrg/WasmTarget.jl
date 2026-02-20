#!/usr/bin/env julia
# diag_6021c_b5.jl — get Julia IR for builtin_effects [111] and examine IntrinsicFunction usage
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
using JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)

manifest_path = joinpath(@__DIR__, "eval_julia_manifest.txt")
all_lines = readlines(manifest_path)
data_lines = filter(l -> !startswith(l, "#") && !isempty(strip(l)), all_lines)

function resolve_func_entry(line)
    parts = split(line, " | ")
    length(parts) < 4 && return nothing
    idx = Base.parse(Int, strip(parts[1]))
    mod_name = strip(parts[2])
    func_name = strip(parts[3])
    arg_types_str = strip(parts[4])
    mod = try eval(Meta.parse(mod_name)) catch; return nothing end
    mod isa Module || return nothing
    func = try getfield(mod, Symbol(func_name)) catch; return nothing end
    arg_types = try
        t = eval(Meta.parse(arg_types_str))
        t isa Tuple ? t : (t,)
    catch; return nothing end
    return (idx=idx, mod=mod_name, name=func_name, func=func, arg_types=arg_types)
end

line111 = data_lines[findfirst(l -> startswith(l, "111 |"), data_lines)]
entry111 = resolve_func_entry(line111)
println("Entry: [$(entry111.idx)] $(entry111.mod).$(entry111.name)")
println("Args: $(entry111.arg_types)")

# Get optimized IR via code_typed
println("\n=== Optimized Julia IR (code_typed) ===")
try
    results = code_typed(entry111.func, entry111.arg_types; optimize=true)
    if !isempty(results)
        ci, rt = results[1]
        println("Return type: $rt")
        # ci is CodeInfo
        for (i, stmt) in enumerate(ci.code)
            t = ci.ssavaluetypes[i]
            println("  %$i ::$t = $stmt")
        end
    end
catch e
    println("code_typed failed: $(sprint(showerror, e))")
end

# Try InteractiveUtils.@code_typed
println("\n=== Checking IntrinsicFunction constants ===")
# Values 19, 22, 35, 38, 37, 21, 36, 18, 78, 20
# These are IntrinsicFunction IDs - let's see which ones
for id in [19, 22, 35, 38, 37, 21, 36, 18, 78, 20]
    # IntrinsicFunction ID to name mapping
    # They're accessible via Core.Intrinsics
    for name in names(Core.Intrinsics; all=true)
        try
            f = getfield(Core.Intrinsics, name)
            if f isa Core.IntrinsicFunction
                # IntrinsicFunction stores its ID as a primitive value
                id_val = reinterpret(Int32, f)
                if id_val == id
                    println("  ID $id = Core.Intrinsics.$name")
                    break
                end
            end
        catch; end
    end
end

# Check julia_to_wasm_type for IntrinsicFunction
println("\n=== julia_to_wasm_type for IntrinsicFunction ===")
# What type does IntrinsicFunction get?
ctx_dummy = WasmTarget.CompileContext()
println("julia_to_wasm_type(Core.IntrinsicFunction) = $(WasmTarget.julia_to_wasm_type_concrete(Core.IntrinsicFunction, ctx_dummy))")
println("isprimitivetype(Core.IntrinsicFunction) = $(isprimitivetype(Core.IntrinsicFunction))")
println("sizeof(Core.IntrinsicFunction) = $(sizeof(Core.IntrinsicFunction))")
println("Core.IntrinsicFunction <: Function = $(Core.IntrinsicFunction <: Function)")
