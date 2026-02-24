#!/usr/bin/env julia
# Diagnostic: Is the crash caused by stubs, module context, or both?
#
# Tests 3 compilation modes for test_parse_only:
# A) test_parse_only ALONE, no stubs (should work)
# B) test_parse_only + full seed list, NO stubs
# C) test_parse_only + full seed list, WITH stubs (current broken config)

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
using JuliaSyntax
using Dates

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

function test_parse_only(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps, rule=:statement)
    expr = JuliaSyntax.build_tree(Expr, ps)
    if expr isa Expr
        return Int32(1)
    end
    return Int32(0)
end

function eval_julia_result_length(v::Vector{UInt8})::Int32
    return Int32(length(v))
end
function eval_julia_result_byte(v::Vector{UInt8}, idx::Int32)::Int32
    return Int32(v[idx])
end

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

function compute_stubs(all_funcs)
    stubs = Set{String}()
    for (f, arg_types, name) in all_funcs
        mod = try parentmodule(f) catch; nothing end
        mod_name = try string(nameof(mod)) catch; "" end
        base_name = replace(name, r"_\d+$" => "")
        is_compiler_mod = mod_name == "Compiler"
        is_opt_submod = mod_name == "EscapeAnalysis"
        if (is_compiler_mod && !(base_name in INFERENCE_WHITELIST)) || is_opt_submod
            push!(stubs, name)
        end
    end
    return stubs
end

function try_compile(label, seed; stub_names=Set{String}())
    println("\n=== $label ===")
    local wasm_bytes
    try
        t = time()
        wasm_bytes = WasmTarget.compile_multi(seed; stub_names=stub_names)
        println("  COMPILE: $(length(wasm_bytes)) bytes ($(round(time()-t, digits=1))s)")
    catch e
        println("  COMPILE_ERROR: $(first(sprint(showerror, e), 300))")
        return nothing
    end

    outf = joinpath(@__DIR__, "..", "output", "diag_$(replace(lowercase(label), r"[^a-z0-9]+" => "_")).wasm")
    write(outf, wasm_bytes)

    errbuf = IOBuffer()
    valid = try
        Base.run(pipeline(`wasm-tools validate --features=gc $outf`, stderr=errbuf, stdout=devnull))
        true
    catch; false end

    if valid
        println("  VALIDATES")
    else
        println("  VALIDATE_ERROR: $(first(String(take!(errbuf)), 300))")
        return nothing
    end

    # Count funcs
    pbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $outf`, stdout=pbuf))
    wt = String(take!(pbuf))
    fc = count(l -> contains(l, "(func "), split(wt, '\n'))
    println("  Functions: $fc")

    # List exports (first 20)
    exports = String[]
    for line in split(wt, '\n')
        m = match(r"\(export \"([^\"]+)\"", line)
        if m !== nothing
            push!(exports, m.captures[1])
        end
    end
    println("  Exports ($(length(exports))): $(join(first(exports, 20), ", "))$(length(exports) > 20 ? "..." : "")")

    return outf
end

println("=" ^ 70)
println("DIAGNOSTIC: Context vs Stubs")
println("Started: $(Dates.now())")
println("=" ^ 70)

# === A: test_parse_only ALONE, no stubs ===
seed_a = [(test_parse_only, (Vector{UInt8},)), (make_byte_vec, (Int32,)), (set_byte_vec!, (Vector{UInt8}, Int32, Int32))]
wasm_a = try_compile("A: parse_only ALONE no stubs", seed_a)

# === B: test_parse_only + full seeds, NO stubs ===
seed_full = [
    (test_parse_only, (Vector{UInt8},)),
    (eval_julia_to_bytes_vec, (Vector{UInt8},)),
    (eval_julia_result_length, (Vector{UInt8},)),
    (eval_julia_result_byte, (Vector{UInt8}, Int32)),
    (make_byte_vec, (Int32,)),
    (set_byte_vec!, (Vector{UInt8}, Int32, Int32)),
]
wasm_b = try_compile("B: parse_only + full seeds NO stubs", seed_full)

# === C: test_parse_only + full seeds, WITH stubs ===
# Need to discover deps first for stub computation
all_funcs = WasmTarget.discover_dependencies(seed_full)
stubs = compute_stubs(all_funcs)
println("\nStub count: $(length(stubs))")
wasm_c = try_compile("C: parse_only + full seeds WITH stubs", seed_full; stub_names=stubs)

println("\n" * "=" ^ 70)
println("SUMMARY")
println("=" ^ 70)
println("  A (alone, no stubs):         $(wasm_a === nothing ? "FAILED" : "OK")")
println("  B (full seeds, no stubs):    $(wasm_b === nothing ? "FAILED" : "OK")")
println("  C (full seeds, with stubs):  $(wasm_c === nothing ? "FAILED" : "OK")")
println()
println("If A=OK, B=FAILED → module context (other seeds) breaks codegen")
println("If A=OK, B=OK, C=FAILED → stubs break it (validation or runtime)")
println("If A=OK, B=OK, C=OK → issue is runtime only, test in Node.js")
println()
println("Done: $(Dates.now())")
