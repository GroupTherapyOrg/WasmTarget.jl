# PHASE-2-PREP-004: Validate DictMethodTable.findall compiles to WasmGC
#
# Run: julia +1.12 --project=. test/selfhost/validate_findall.jl

using WasmTarget
using JSON, Dates

# Load typeinf infrastructure
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "ccall_stubs.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "ccall_replacements.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "dict_method_table.jl"))

println("=" ^ 70)
println("PHASE-2-PREP-004: Validate DictMethodTable.findall compiles to WasmGC")
println("=" ^ 70)

function try_compile(name::String, @nospecialize(f), @nospecialize(argtypes::Tuple))
    println("\n--- $name ---")
    ct_ok = false
    comp_ok = false
    wasm_size = 0
    n_stmts = 0
    ret = nothing
    ci = nothing

    try
        ct_result = Base.code_typed(f, argtypes; optimize=true)
        if !isempty(ct_result)
            ci = ct_result[1][1]
            ret = ct_result[1][2]
            n_stmts = length(ci.code)
            ct_ok = true
            println("  code_typed: OK ($n_stmts stmts, returns $ret)")
        else
            println("  code_typed: EMPTY")
        end
    catch e
        println("  code_typed: FAIL — $(first(sprint(showerror, e), 100))")
    end

    if ct_ok
        try
            bytes = WasmTarget.compile_from_codeinfo(ci, ret, name, argtypes)
            wasm_size = length(bytes)
            comp_ok = true
            println("  compile: OK ($wasm_size bytes)")
        catch e
            println("  compile: FAIL — $(first(sprint(showerror, e), 150))")
        end
    end

    # Document transitive deps from IR
    if ct_ok && ci !== nothing
        targets = String[]
        for stmt in ci.code
            if stmt isa Expr && stmt.head === :invoke && length(stmt.args) >= 1
                arg = stmt.args[1]
                if arg isa Core.CodeInstance
                    push!(targets, string(arg.def))
                elseif arg isa Core.MethodInstance
                    push!(targets, string(arg))
                end
            end
        end
        if !isempty(targets)
            println("  Transitive :invoke targets ($(length(targets))):")
            for t in unique(targets)
                println("    - $t")
            end
        end
    end

    return (name=name, ct_ok=ct_ok, comp_ok=comp_ok, wasm_size=wasm_size, n_stmts=n_stmts)
end

CachedDMT = Core.Compiler.CachedMethodTable{DictMethodTable}

results = [
    try_compile("findall_dict", Core.Compiler.findall, (Type, DictMethodTable)),
    try_compile("findall_cached", Core.Compiler.findall, (Type, CachedDMT)),
    try_compile("isoverlayed", Core.Compiler.isoverlayed, (DictMethodTable,)),
    try_compile("DictMethodTable_ctor", DictMethodTable, (UInt64,)),
    try_compile("get_code_info", get_code_info, (PreDecompressedCodeInfo, Core.MethodInstance)),
]

# Summary
println("\n" * "=" ^ 70)
println("SUMMARY")
println("=" ^ 70)

n_ok = count(r -> r.comp_ok, results)
println(rpad("Name", 25) * rpad("code_typed", 12) * rpad("compile", 12) * "size")
println("─" ^ 55)
for r in results
    println(rpad(r.name, 25) * rpad(r.ct_ok ? "OK" : "FAIL", 12) * rpad(r.comp_ok ? "OK" : "FAIL", 12) * (r.wasm_size > 0 ? "$(r.wasm_size)B" : "-"))
end
println("\n  $n_ok / $(length(results)) compile OK")

# Save results
output = Dict(
    "story" => "PHASE-2-PREP-004",
    "timestamp" => string(Dates.now()),
    "results" => [Dict("name" => r.name, "ct_ok" => r.ct_ok, "comp_ok" => r.comp_ok,
                        "wasm_size" => r.wasm_size, "n_stmts" => r.n_stmts) for r in results],
    "total_ok" => n_ok,
    "total_tested" => length(results),
)

output_path = joinpath(@__DIR__, "findall_results.json")
open(output_path, "w") do io
    JSON.print(io, output, 2)
end
println("\nResults saved to $output_path")
println("\n=== ACCEPTANCE: $(n_ok == length(results) ? "PASS" : "PARTIAL ($n_ok/$(length(results)))") ===")
