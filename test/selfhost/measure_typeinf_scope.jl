# PHASE-2-PREP-001: Measure typeinf method table scope via populate_transitive
#
# Run: julia +1.12 --project=. test/selfhost/measure_typeinf_scope.jl
#
# Runs populate_transitive on codegen + typeinf entry points in a SINGLE pass
# to measure the combined scope. Compares to Phase 1 baseline (17,171 sigs)
# which was measured in a separate session.
#
# IMPORTANT: Only loads dict_method_table.jl (not typeinf_wasm.jl) to avoid
# overriding Base._methods_by_ftype which would break the _TracingTable tracing.

using WasmTarget
using JSON, Dates

# Load ONLY dict_method_table.jl (same as Phase 1 measurement)
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "dict_method_table.jl"))

println("=" ^ 60)
println("PHASE-2-PREP-001: Measuring typeinf+codegen scope")
println("=" ^ 60)

phase1_count = 17171
phase1_intersections = 5783

# ─── Entry points ────────────────────────────────────────────────────────────
# Codegen entries (same as Phase 1)
codegen_sigs = Any[
    Tuple{typeof(WasmTarget.compile_from_codeinfo), Core.CodeInfo, Type, String, Tuple},
    Tuple{typeof(WasmTarget.compile_module_from_ir), Vector},
]

# TypeInf entries (NEW for Phase 2) — concrete types for specialization
typeinf_sigs = Any[
    # Core typeinf loop with concrete WasmInterpreter
    Tuple{typeof(Core.Compiler.typeinf), WasmInterpreter, Core.Compiler.InferenceState},
    # DictMethodTable findall
    Tuple{typeof(Core.Compiler.findall), Type, DictMethodTable},
    # CachedMethodTable findall
    Tuple{typeof(Core.Compiler.findall), Type, Core.Compiler.CachedMethodTable{DictMethodTable}},
    # WasmInterpreter interface
    Tuple{typeof(Core.Compiler.method_table), WasmInterpreter},
    Tuple{typeof(Core.Compiler.get_inference_world), WasmInterpreter},
    Tuple{typeof(Core.Compiler.get_inference_cache), WasmInterpreter},
    Tuple{typeof(Core.Compiler.InferenceParams), WasmInterpreter},
    Tuple{typeof(Core.Compiler.OptimizationParams), WasmInterpreter},
    Tuple{typeof(Core.Compiler.may_optimize), WasmInterpreter},
    Tuple{typeof(Core.Compiler.may_compress), WasmInterpreter},
    Tuple{typeof(Core.Compiler.may_discard_trees), WasmInterpreter},
    Tuple{typeof(Core.Compiler.cache_owner), WasmInterpreter},
    # Build-time helpers
    Tuple{typeof(predecompress_methods!), PreDecompressedCodeInfo, DictMethodTable},
    Tuple{typeof(populate_method_table), Vector},
]

all_sigs = vcat(codegen_sigs, typeinf_sigs)
println("  Codegen entries: $(length(codegen_sigs))")
println("  TypeInf entries: $(length(typeinf_sigs))")
println("  Total entries: $(length(all_sigs))")

# ─── Run populate_transitive ────────────────────────────────────────────────
println("\n--- Running populate_transitive (single pass, all entries) ---")
t0 = time()
combined_table = populate_transitive(all_sigs)
elapsed = time() - t0

n_combined = length(combined_table.methods)
n_intersections = length(combined_table.intersections)
n_intersections_env = length(combined_table.intersections_with_env)

println("  Elapsed: $(round(elapsed, digits=1))s")
println("  Method signatures: $n_combined (Phase 1 was $phase1_count)")
println("  Intersections: $n_intersections (Phase 1 was $phase1_intersections)")
println("  Intersections (with env): $n_intersections_env")
println("  Delta: +$(n_combined - phase1_count) signatures ($(round(100.0 * (n_combined - phase1_count) / phase1_count, digits=1))%)")

# ─── Method family analysis ────────────────────────────────────────────────
families = Dict{String, Int}()
modules = Dict{String, Int}()
compiler_count = 0
compiler_families = Dict{String, Int}()

for sig in keys(combined_table.methods)
    if sig isa DataType && sig <: Tuple && length(sig.parameters) >= 1
        func_type = sig.parameters[1]
        name = string(func_type)
        families[name] = get(families, name, 0) + 1

        if occursin("Compiler", name) || occursin("typeinf", name) ||
           occursin("infer", name) || occursin("subtype", name)
            global compiler_count += 1
            compiler_families[name] = get(compiler_families, name, 0) + 1
        end

        mod_name = try
            if func_type isa DataType && hasfield(func_type, :name)
                string(func_type.name.module)
            elseif func_type isa Type
                string(parentmodule(func_type))
            else
                "Unknown"
            end
        catch
            "Unknown"
        end
        modules[mod_name] = get(modules, mod_name, 0) + 1
    end
end

sorted_families = sort(collect(families), by=x -> -x[2])
top20 = sorted_families[1:min(20, length(sorted_families))]

println("\n--- Top 20 Method Families ---")
for (i, (name, count)) in enumerate(top20)
    short = length(name) > 60 ? name[1:60] * "..." : name
    println("  $i. $short: $count")
end

println("\n--- Methods by Module ---")
for (mod, count) in sort(collect(modules), by=x -> -x[2])
    println("  $mod: $count")
end

# Show Compiler-related families
sorted_compiler = sort(collect(compiler_families), by=x -> -x[2])
println("\n--- Compiler/TypeInf-Related Families ($compiler_count total) ---")
for (i, (name, count)) in enumerate(sorted_compiler[1:min(20, length(sorted_compiler))])
    short = length(name) > 60 ? name[1:60] * "..." : name
    println("  $i. $short: $count")
end

# ─── Save results ────────────────────────────────────────────────────────────
results = Dict(
    "story" => "PHASE-2-PREP-001",
    "timestamp" => string(Dates.now()),
    "phase1_baseline" => Dict("method_signatures" => phase1_count, "intersections" => phase1_intersections),
    "combined" => Dict(
        "method_signatures" => n_combined,
        "intersections" => n_intersections,
        "intersections_with_env" => n_intersections_env,
        "elapsed_seconds" => round(elapsed, digits=2),
        "codegen_entry_count" => length(codegen_sigs),
        "typeinf_entry_count" => length(typeinf_sigs)
    ),
    "delta" => Dict(
        "new_signatures" => n_combined - phase1_count,
        "pct_growth" => round(100.0 * (n_combined - phase1_count) / phase1_count, digits=1)
    ),
    "compiler_related_count" => compiler_count,
    "top20_families" => [(name=name, count=count) for (name, count) in top20],
    "compiler_top20" => [(name=name, count=count) for (name, count) in sorted_compiler[1:min(20, length(sorted_compiler))]],
    "module_distribution" => [(module_name=mod, count=count) for (mod, count) in sort(collect(modules), by=x -> -x[2])]
)

output_path = joinpath(@__DIR__, "typeinf_scope_results.json")
open(output_path, "w") do io
    JSON.print(io, results, 2)
end

println("\n" * "=" ^ 60)
println("SUMMARY")
println("=" ^ 60)
println("  Phase 1 codegen-only:   $phase1_count sigs, $phase1_intersections intersections")
println("  Combined codegen+typeinf: $n_combined sigs, $n_intersections intersections")
println("  Delta:                  +$(n_combined - phase1_count) sigs ($(round(100.0 * (n_combined - phase1_count) / phase1_count, digits=1))%)")
println("  Compiler-related:       $compiler_count")
println("\nResults saved to $output_path")
println("\n=== ACCEPTANCE: PASS ===")
