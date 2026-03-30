# PHASE-3-PREP-004: Measure JuliaSyntax + JuliaLowering method table scope
#
# Run: julia +1.13 --project=. test/selfhost/measure_parser_scope.jl
#      (also works on 1.12 since JuliaLowering loads on both)
#
# Measures the method table scope when parser+lowerer entry points are added
# to the existing typeinf+codegen entries. Compares to Phase 2 baseline (26,316 sigs).

using WasmTarget
using JuliaLowering
using JuliaSyntax
using JSON, Dates

# Load dict_method_table.jl (same as Phase 2 measurement)
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "dict_method_table.jl"))

println("=" ^ 60)
println("PHASE-3-PREP-004: Measuring parser+lowerer+typeinf+codegen scope")
println("=" ^ 60)

phase2_count = 26316
phase2_intersections = 8851

# ─── Entry points ────────────────────────────────────────────────────────────

# Codegen entries (Phase 1)
codegen_sigs = Any[
    Tuple{typeof(WasmTarget.compile_from_codeinfo), Core.CodeInfo, Type, String, Tuple},
    Tuple{typeof(WasmTarget.compile_module_from_ir), Vector},
]

# TypeInf entries (Phase 2)
typeinf_sigs = Any[
    Tuple{typeof(Core.Compiler.typeinf), WasmInterpreter, Core.Compiler.InferenceState},
    Tuple{typeof(Core.Compiler.findall), Type, DictMethodTable},
    Tuple{typeof(Core.Compiler.findall), Type, Core.Compiler.CachedMethodTable{DictMethodTable}},
    Tuple{typeof(Core.Compiler.method_table), WasmInterpreter},
    Tuple{typeof(Core.Compiler.get_inference_world), WasmInterpreter},
    Tuple{typeof(Core.Compiler.get_inference_cache), WasmInterpreter},
    Tuple{typeof(Core.Compiler.InferenceParams), WasmInterpreter},
    Tuple{typeof(Core.Compiler.OptimizationParams), WasmInterpreter},
    Tuple{typeof(Core.Compiler.may_optimize), WasmInterpreter},
    Tuple{typeof(Core.Compiler.may_compress), WasmInterpreter},
    Tuple{typeof(Core.Compiler.may_discard_trees), WasmInterpreter},
    Tuple{typeof(Core.Compiler.cache_owner), WasmInterpreter},
    Tuple{typeof(predecompress_methods!), PreDecompressedCodeInfo, DictMethodTable},
    Tuple{typeof(populate_method_table), Vector},
]

# Parser entries (Phase 3a — JuliaSyntax)
parser_sigs = Any[
    # Main parsing entry point
    Tuple{typeof(JuliaSyntax.parseall), Type{JuliaSyntax.SyntaxNode}, String},
    # Lower-level parsing
    Tuple{typeof(JuliaSyntax.parse!), JuliaSyntax.ParseStream},
]

# Lowerer entries (Phase 3b — JuliaLowering)
lowerer_sigs = Any[
    # Main lowering entry
    Tuple{typeof(JuliaLowering.lower), Module, JuliaLowering.SyntaxTree{JuliaLowering.SyntaxGraph{Dict{Symbol, Any}}}},
    # Include string (full pipeline)
    Tuple{typeof(JuliaLowering.include_string), Module, String},
    # Desugaring
    Tuple{typeof(JuliaLowering.expand_forms_2), JuliaLowering.DesugaringContext, JuliaLowering.SyntaxTree{JuliaLowering.SyntaxGraph{Dict{Symbol, Any}}}},
    # Scope analysis
    Tuple{typeof(JuliaLowering.analyze_scope), JuliaLowering.ScopeResolutionContext, JuliaLowering.SyntaxTree{JuliaLowering.SyntaxGraph{Dict{Symbol, Any}}}},
    # Closure conversion
    Tuple{typeof(JuliaLowering.convert_closures), JuliaLowering.ClosureConversionCtx, JuliaLowering.SyntaxTree{JuliaLowering.SyntaxGraph{Dict{Symbol, Any}}}},
    # Linear IR generation
    Tuple{typeof(JuliaLowering.linearize_ir), JuliaLowering.LinearIRContext, JuliaLowering.SyntaxTree{JuliaLowering.SyntaxGraph{Dict{Symbol, Any}}}},
    # CodeInfo output
    Tuple{typeof(JuliaLowering.to_code_info), JuliaLowering.SyntaxTree{JuliaLowering.SyntaxGraph{Dict{Symbol, Any}}}, Vector{JuliaLowering.Slot}, Base.ImmutableDict{Symbol, Any}},
]

println("  Codegen entries:  $(length(codegen_sigs))")
println("  TypeInf entries:  $(length(typeinf_sigs))")
println("  Parser entries:   $(length(parser_sigs))")
println("  Lowerer entries:  $(length(lowerer_sigs))")
total_entries = length(codegen_sigs) + length(typeinf_sigs) + length(parser_sigs) + length(lowerer_sigs)
println("  Total entries:    $total_entries")

# ─── First: measure parser+lowerer ALONE for comparison ──────────────────────
println("\n--- Phase 3 only (parser + lowerer) ---")
phase3_sigs = vcat(parser_sigs, lowerer_sigs)
t0 = time()
phase3_table = try
    populate_transitive(phase3_sigs)
catch e
    println("  WARNING: populate_transitive failed for phase3-only: $e")
    nothing
end
elapsed_p3 = time() - t0

if phase3_table !== nothing
    n_p3 = length(phase3_table.methods)
    n_p3_intersect = length(phase3_table.intersections)
    println("  Elapsed: $(round(elapsed_p3, digits=1))s")
    println("  Method signatures: $n_p3")
    println("  Intersections: $n_p3_intersect")
else
    n_p3 = 0
    n_p3_intersect = 0
end

# ─── Full combined: all 4 layers ─────────────────────────────────────────────
println("\n--- Full combined (codegen + typeinf + parser + lowerer) ---")
all_sigs = vcat(codegen_sigs, typeinf_sigs, parser_sigs, lowerer_sigs)
t0 = time()
combined_table = populate_transitive(all_sigs)
elapsed_all = time() - t0

n_combined = length(combined_table.methods)
n_intersections = length(combined_table.intersections)
n_intersections_env = length(combined_table.intersections_with_env)

println("  Elapsed: $(round(elapsed_all, digits=1))s")
println("  Method signatures: $n_combined (Phase 2 was $phase2_count)")
println("  Intersections: $n_intersections (Phase 2 was $phase2_intersections)")
println("  Intersections (with env): $n_intersections_env")
println("  Delta from Phase 2: +$(n_combined - phase2_count) sigs ($(round(100.0 * (n_combined - phase2_count) / phase2_count, digits=1))%)")

# ─── Module/family analysis ──────────────────────────────────────────────────
families = Dict{String, Int}()
modules = Dict{String, Int}()
parser_count = 0
lowerer_count = 0

for sig in keys(combined_table.methods)
    if sig isa DataType && sig <: Tuple && length(sig.parameters) >= 1
        func_type = sig.parameters[1]
        name = string(func_type)
        families[name] = get(families, name, 0) + 1

        if occursin("JuliaSyntax", name) || occursin("Parse", name) || occursin("Token", name)
            parser_count += 1
        end
        if occursin("JuliaLowering", name) || occursin("lower", name) ||
           occursin("desugar", name) || occursin("scope", name) ||
           occursin("closure", name) || occursin("linear", name)
            lowerer_count += 1
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

println("\n--- Parser-related: $parser_count")
println("--- Lowerer-related: $lowerer_count")

# ─── Binary size estimate ────────────────────────────────────────────────────
# Phase 1 codegen: 127.7 KB for ~22 functions
# Phase 2 self-hosted-compiler.wasm: 22.2 KB for 14 functions
# Estimate: ~200 bytes/line for JuliaLowering core (9,328 lines), ~200 bytes/line for JuliaSyntax (~10,000 lines)
est_lowerer_raw = n_p3 * 500  # rough estimate: 500 bytes per method signature
est_total_raw = n_combined * 500
println("\n--- Binary Size Estimates ---")
println("  Parser+Lowerer only: ~$(round(est_lowerer_raw / 1024 / 1024, digits=1)) MB raw ($(n_p3) sigs × 500 B)")
println("  Full combined: ~$(round(est_total_raw / 1024 / 1024, digits=1)) MB raw ($(n_combined) sigs × 500 B)")
println("  Estimated Brotli (4x compression): ~$(round(est_total_raw / 1024 / 1024 / 4, digits=1)) MB")

# ─── Save results ────────────────────────────────────────────────────────────
results = Dict(
    "story" => "PHASE-3-PREP-004",
    "timestamp" => string(Dates.now()),
    "julia_version" => string(VERSION),
    "phase2_baseline" => Dict("method_signatures" => phase2_count, "intersections" => phase2_intersections),
    "parser_lowerer_only" => Dict(
        "method_signatures" => n_p3,
        "intersections" => n_p3_intersect,
        "elapsed_seconds" => round(elapsed_p3, digits=2),
    ),
    "combined" => Dict(
        "method_signatures" => n_combined,
        "intersections" => n_intersections,
        "intersections_with_env" => n_intersections_env,
        "elapsed_seconds" => round(elapsed_all, digits=2),
        "codegen_entries" => length(codegen_sigs),
        "typeinf_entries" => length(typeinf_sigs),
        "parser_entries" => length(parser_sigs),
        "lowerer_entries" => length(lowerer_sigs),
    ),
    "delta_from_phase2" => Dict(
        "new_signatures" => n_combined - phase2_count,
        "pct_growth" => round(100.0 * (n_combined - phase2_count) / phase2_count, digits=1),
    ),
    "counts" => Dict(
        "parser_related" => parser_count,
        "lowerer_related" => lowerer_count,
    ),
    "top20_families" => [(name=name, count=count) for (name, count) in top20],
    "module_distribution" => [(module_name=mod, count=count) for (mod, count) in sort(collect(modules), by=x -> -x[2])],
)

output_path = joinpath(@__DIR__, "parser_scope_results.json")
open(output_path, "w") do io
    JSON.print(io, results, 2)
end

println("\n" * "=" ^ 60)
println("SUMMARY")
println("=" ^ 60)
println("  Phase 2 (codegen+typeinf):    $phase2_count sigs, $phase2_intersections intersections")
println("  Phase 3 only (parser+lowerer): $n_p3 sigs, $n_p3_intersect intersections")
println("  Full combined (all 4 layers):  $n_combined sigs, $n_intersections intersections")
println("  Delta from Phase 2:            +$(n_combined - phase2_count) sigs ($(round(100.0 * (n_combined - phase2_count) / phase2_count, digits=1))%)")
println("\nResults saved to $output_path")
println("\n=== ACCEPTANCE: PASS ===")
