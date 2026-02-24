# trace_critical_path_v2.jl — Profile eval_julia with may_optimize=false
# Traces runtime critical path to see which functions are actually called

using WasmTarget
using JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

using Profile
Profile.clear()

# Warm up
eval_julia_native("1+1")

# Profile with multiple expressions
Profile.@profile begin
    eval_julia_native("2+3")
    eval_julia_native("10-3")
    eval_julia_native("6*7")
end

# Extract unique function/method instances
frames = Profile.retrieve()
if frames === nothing || isempty(frames)
    println("No profile data collected")
    exit(1)
end

data, lidict = frames
seen = Set{String}()
for ip in data
    if haskey(lidict, UInt64(ip))
        for frame in lidict[UInt64(ip)]
            key = "$(frame.func) @ $(frame.file):$(frame.line)"
            push!(seen, key)
        end
    end
end
println("Profiled $(length(seen)) unique frames")

# Count Core.Compiler frames
cc_frames = filter(s -> occursin("Core.Compiler", s) || occursin("compiler/", s), collect(seen))
println("Core.Compiler frames: $(length(cc_frames))")

# Check for optimization pass functions
opt_names = ["compact!", "adce_pass", "sroa_pass", "construct_ssa", "builtin_effects", "may_optimize"]
opt_frames = filter(s -> any(n -> occursin(n, s), opt_names), collect(seen))
println("Optimization pass frames: $(length(opt_frames))")
if isempty(opt_frames)
    println("  NONE — may_optimize=false confirmed eliminating opt passes from runtime")
else
    for f in sort(collect(opt_frames))
        println("  - $f")
    end
end

# Now enumerate the full dependency tree for WASM compilation
println("\n--- Enumerating WASM dependency tree ---")
seed = [(eval_julia_to_bytes, (String,))]
try
    all_funcs = WasmTarget.discover_dependencies(seed)
    println("Dependency tree size: $(length(all_funcs)) functions")

    # Check for optimization pass functions in deps
    opt_deps = filter(f -> begin
        name = string(f[3])
        any(n -> occursin(n, name), ["compact!", "adce_pass", "sroa_pass", "construct_ssa", "builtin_effects"])
    end, all_funcs)
    println("Optimization pass functions in dep tree: $(length(opt_deps))")
    for f in opt_deps
        println("  - $(f[3])")
    end
catch e
    println("discover_dependencies failed: $e")
    # Try simpler enumeration
    println("Trying compile_multi enumeration...")
end
