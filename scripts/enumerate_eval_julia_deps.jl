#!/usr/bin/env julia
# enumerate_eval_julia_deps.jl — PURE-6018
#
# Enumerate ALL transitive functions that eval_julia_to_bytes(String) depends on
# when compiled via compile_multi. Uses WasmTarget's discover_dependencies.
#
# Output: scripts/eval_julia_manifest.txt
# Format: INDEX | MODULE | FUNCTION | ARG_TYPES | STMT_COUNT | CAN_CODE_TYPED

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax
using Dates

# Load typeinf (required for eval_julia_to_bytes)
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
# Load eval_julia_to_bytes
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("=== PURE-6018: Enumerating eval_julia_to_bytes transitive deps ===")
println("Starting dependency discovery for eval_julia_to_bytes(String)...")
println()

# Seed: eval_julia_to_bytes(String)
seed = [(eval_julia_to_bytes, (String,))]

# Discover all transitive dependencies using WasmTarget's internal mechanism
println("Running WasmTarget.discover_dependencies...")
all_funcs = WasmTarget.discover_dependencies(seed)
println("Found $(length(all_funcs)) functions total (including seed)")
println()

# Build manifest
manifest_lines = String[]
push!(manifest_lines, "# PURE-6018: eval_julia_to_bytes(String) transitive dependency manifest")
push!(manifest_lines, "# Generated: $(Dates.now())")
push!(manifest_lines, "# Total functions: $(length(all_funcs))")
push!(manifest_lines, "#")
push!(manifest_lines, "# Format: INDEX | MODULE | FUNCTION | ARG_TYPES | STMT_COUNT | CAN_CODE_TYPED")
push!(manifest_lines, "")

# Sort by module then function name for readability
function func_sort_key(entry)
    f, arg_types, name = entry
    mod_name = try string(parentmodule(f)) catch; "?" end
    return (mod_name, name)
end

sorted_funcs = sort(all_funcs; by=func_sort_key)

# Stats
module_counts = Dict{String, Int}()
stmt_total = Ref(0)
n_ok = Ref(0)
n_err = Ref(0)

for (idx, (f, arg_types, name)) in enumerate(sorted_funcs)
    local mod_name = try string(parentmodule(f)) catch; "Unknown" end
    local arg_str = "(" * join([string(t) for t in arg_types], ", ") * ")"

    # Get statement count
    local stmt_count = -1
    local can_ct = false
    try
        local ct = Base.code_typed(f, Tuple{arg_types...}; optimize=false)
        if !isempty(ct) && ct[1][1] isa Core.CodeInfo
            stmt_count = length(ct[1][1].code)
            can_ct = true
        end
    catch e
        stmt_count = -1
        can_ct = false
    end

    if can_ct
        n_ok[] += 1
        stmt_total[] += stmt_count
    else
        n_err[] += 1
    end

    module_counts[mod_name] = get(module_counts, mod_name, 0) + 1

    push!(manifest_lines, "$idx | $mod_name | $name | $arg_str | $stmt_count | $can_ct")
end

# Summary section
push!(manifest_lines, "")
push!(manifest_lines, "# === SUMMARY ===")
push!(manifest_lines, "# Total functions: $(length(all_funcs))")
push!(manifest_lines, "# code_typed OK: $(n_ok[])")
push!(manifest_lines, "# code_typed FAIL: $(n_err[])")
push!(manifest_lines, "# Total statements (code_typed OK): $(stmt_total[])")
push!(manifest_lines, "# Average statements per function: $(n_ok[] > 0 ? round(stmt_total[]/n_ok[], digits=1) : 0)")
push!(manifest_lines, "")
push!(manifest_lines, "# === BY MODULE ===")
for (mod_name, count) in sort(collect(module_counts); by=x->-x[2])
    push!(manifest_lines, "#   $mod_name: $count functions")
end

# Write output
outfile = joinpath(@__DIR__, "eval_julia_manifest.txt")
write(outfile, join(manifest_lines, "\n") * "\n")

println("=== MANIFEST WRITTEN: $outfile ===")
println()
println("SUMMARY:")
println("  Total functions: $(length(all_funcs))")
println("  code_typed OK:   $(n_ok[])")
println("  code_typed FAIL: $(n_err[])")
println("  Total stmts:     $(stmt_total[])")
println("  Avg stmts/func:  $(n_ok[] > 0 ? round(stmt_total[]/n_ok[], digits=1) : 0)")
println()
println("BY MODULE:")
for (mod_name, count) in sort(collect(module_counts); by=x->-x[2])
    println("  $mod_name: $count")
end
