# PHASE-1-001: Measure method table size via populate_transitive
#
# Run: julia +1.12 --project=. test/selfhost/measure_method_table.jl
#
# This script runs populate_transitive on compile_from_codeinfo's entry point
# and records: method signature count, intersection cache size, top-20 method families.

using WasmTarget
using JSON, Dates

# Load typeinf infrastructure (not part of WasmTarget module — standalone)
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "dict_method_table.jl"))

println("=" ^ 60)
println("PHASE-1-001: Measuring method table via populate_transitive")
println("=" ^ 60)

# The target: compile_from_codeinfo processes pre-typed CodeInfo.
# We need to trace what method lookups typeinf makes when inferring
# the codegen functions that compile_from_codeinfo calls.

# Step 1: Create a simple test function to get CodeInfo
test_f(x::Int64) = x + Int64(1)
typed = Base.code_typed(test_f, (Int64,))
ci, ret_type = typed[1]

println("\n--- Test function IR ---")
println("Function: test_f(x::Int64) = x + Int64(1)")
println("Return type: $ret_type")
println("Code statements: $(length(ci.code))")

# Step 2: Build the signature for compile_from_codeinfo
# compile_from_codeinfo(code_info::Core.CodeInfo, return_type::Type,
#                        func_name::String, arg_types::Tuple; optimize=false)
compile_sig = Tuple{typeof(WasmTarget.compile_from_codeinfo),
                    Core.CodeInfo, Type, String, Tuple}
# Also try the inner compile_module_from_ir which is the main compilation function
compile_module_sig = Tuple{typeof(WasmTarget.compile_module_from_ir), Vector}

println("\n--- Running populate_transitive ---")
println("Entry signature 1: $compile_sig")
println("Entry signature 2: $compile_module_sig")

# Step 3: Run populate_transitive with both signatures
t0 = time()
table = populate_transitive([compile_sig, compile_module_sig])
elapsed = time() - t0

println("Elapsed: $(round(elapsed, digits=2))s")

# Step 4: Collect statistics
n_methods = length(table.methods)
n_intersections = length(table.intersections)
n_intersections_env = length(table.intersections_with_env)

println("\n--- Method Table Statistics ---")
println("Method signatures discovered: $n_methods")
println("Type intersections cached: $n_intersections")
println("Type intersections (with env): $n_intersections_env")

# Step 5: Analyze method families (group by function)
method_families = Dict{String, Int}()
for sig in keys(table.methods)
    # Extract the function type from Tuple{typeof(f), args...}
    if sig isa DataType && sig <: Tuple && length(sig.parameters) >= 1
        func_type = sig.parameters[1]
        name = string(func_type)
        method_families[name] = get(method_families, name, 0) + 1
    else
        name = string(sig)
        method_families[name] = get(method_families, name, 0) + 1
    end
end

# Sort by count (descending) and take top 20
sorted_families = sort(collect(method_families), by=x -> -x[2])
top20 = sorted_families[1:min(20, length(sorted_families))]

println("\n--- Top 20 Method Families ---")
for (i, (name, count)) in enumerate(top20)
    short_name = length(name) > 60 ? name[1:60] * "..." : name
    println("  $i. $short_name: $count signatures")
end

# Step 6: Categorize by module
module_counts = Dict{String, Int}()
for sig in keys(table.methods)
    if sig isa DataType && sig <: Tuple && length(sig.parameters) >= 1
        func_type = sig.parameters[1]
        # Try to get the module name
        mod_name = try
            if func_type isa DataType && hasfield(func_type, :name)
                string(func_type.name.module)
            elseif func_type isa Type
                m = parentmodule(func_type)
                string(m)
            else
                "Unknown"
            end
        catch
            "Unknown"
        end
        module_counts[mod_name] = get(module_counts, mod_name, 0) + 1
    end
end

println("\n--- Methods by Module ---")
for (mod, count) in sort(collect(module_counts), by=x -> -x[2])
    println("  $mod: $count")
end

# Step 7: Save results as JSON
results = Dict(
    "story" => "PHASE-1-001",
    "timestamp" => string(Dates.now()),
    "entry_signature" => string(compile_sig),
    "elapsed_seconds" => round(elapsed, digits=2),
    "method_signature_count" => n_methods,
    "intersection_count" => n_intersections,
    "intersection_with_env_count" => n_intersections_env,
    "top20_families" => [(name=name, count=count) for (name, count) in top20],
    "module_distribution" => [(module_name=mod, count=count) for (mod, count) in sort(collect(module_counts), by=x -> -x[2])],
    "acceptance" => n_methods >= 1000 && n_methods <= 10000 ? "PASS" : (n_methods > 0 ? "PARTIAL" : "FAIL")
)

results["timestamp"] = string(Dates.now())

output_path = joinpath(@__DIR__, "method_table_results.json")
open(output_path, "w") do io
    JSON.print(io, results, 2)
end

println("\n--- Results saved to $output_path ---")
println("\n=== ACCEPTANCE: $(results["acceptance"]) ===")
println("  Signature count: $n_methods (expected 1K-10K)")
