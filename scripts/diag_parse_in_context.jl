#!/usr/bin/env julia
# Compile test_parse as the FIRST seed function alongside the full eval_julia pipeline.
# If test_parse works but eval_julia_to_bytes_vec doesn't, the issue is in the pipeline.
# If test_parse ALSO fails, the issue is in how ParseStream compiles in the full context.

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
using JuliaSyntax
using Dates

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

# Simple test: just call ParseStream, parse, build_tree, return 1
function test_parse_only(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps, rule=:statement)
    expr = JuliaSyntax.build_tree(Expr, ps)
    if expr isa Expr
        return Int32(1)
    end
    return Int32(0)
end

# Helper functions
function eval_julia_result_length(v::Vector{UInt8})::Int32
    return Int32(length(v))
end
function eval_julia_result_byte(v::Vector{UInt8}, idx::Int32)::Int32
    return Int32(v[idx])
end

# SAME stub whitelist as the full compilation
const INFERENCE_WHITELIST = Set([
    "typeinf_frame", "typeinf", "typeinf_nocycle", "typeinf_local",
    "_typeinf", "typeinf_edge",
    "InferenceState", "finish", "retrieve_code_info",
    "most_general_argtypes",
    "abstract_call", "abstract_call_gf_by_type", "abstract_call_method",
    "abstract_call_known", "abstract_call_opaque_closure",
    "abstract_eval_statement", "abstract_eval_special_value",
    "abstract_eval_value", "abstract_eval_cfunction",
    "abstract_eval_ssavalue", "abstract_eval_globalref",
    "abstract_eval_global", "abstract_interpret",
    "abstract_eval_new", "abstract_eval_phi",
    "resolve_call_cycle!",
    "check_inconsistentcy!", "refine_effects!",
    "builtin_effects",
    "issimplertype", "widenconst", "tname_intersect", "tuplemerge",
    "getfield_tfunc", "getfield_nothrow", "fieldtype_nothrow",
    "setfield!_nothrow", "isdefined_tfunc", "isdefined_nothrow",
    "apply_type_nothrow", "sizeof_nothrow", "typebound_nothrow",
    "memoryrefop_builtin_common_nothrow",
    "argextype", "isknowntype", "is_lattice_equal",
    "push!", "scan!", "check_inconsistentcy!", "something",
    "cache_lookup", "transform_result_for_cache",
])

seed = [
    (test_parse_only, (Vector{UInt8},)),
    (eval_julia_to_bytes_vec, (Vector{UInt8},)),
    (eval_julia_result_length, (Vector{UInt8},)),
    (eval_julia_result_byte, (Vector{UInt8}, Int32)),
    (make_byte_vec, (Int32,)),
    (set_byte_vec!, (Vector{UInt8}, Int32, Int32)),
]

all_funcs = WasmTarget.discover_dependencies(seed)
println("Found $(length(all_funcs)) functions")

stub_names = Set{String}()
for (f, arg_types, name) in all_funcs
    mod = try parentmodule(f) catch; nothing end
    mod_name = try string(nameof(mod)) catch; "" end
    base_name = replace(name, r"_\d+$" => "")
    is_compiler_mod = mod_name == "Compiler"
    is_opt_submod = mod_name == "EscapeAnalysis"
    if (is_compiler_mod && !(base_name in INFERENCE_WHITELIST)) || is_opt_submod
        push!(stub_names, name)
    end
end
println("Stubbing $(length(stub_names)) functions")

println("Compiling...")
t = time()
wasm_bytes = WasmTarget.compile_multi(seed; stub_names=stub_names)
println("COMPILE SUCCESS: $(length(wasm_bytes)) bytes ($(round(time()-t, digits=1))s)")

outf = joinpath(@__DIR__, "..", "output", "test_parse_context.wasm")
write(outf, wasm_bytes)
errbuf = IOBuffer()
try
    Base.run(pipeline(`wasm-tools validate --features=gc $outf`, stderr=errbuf))
    println("VALIDATES")
catch
    println("VALIDATE_ERROR: $(String(take!(errbuf)))")
end
