#!/usr/bin/env julia
using Pkg
Pkg.activate(dirname(@__DIR__))

using WasmTarget
using InteractiveUtils: @code_typed

parser_skip_fn = getfield(WasmTarget, Symbol("parser_skip_terminators!"))
parser_advance_fn = getfield(WasmTarget, Symbol("parser_advance!"))

# Get code_typed for parser_skip_terminators!
p = WasmTarget.parser_new("test", Int32(100))
code = @code_typed parser_skip_fn(p)

println("SSA types:")
for (i, T) in enumerate(code[1].ssavaluetypes)
    println("  $i: $T")
end

# Find the calls to parser_advance!
println("\nCalls to parser_advance!:")
for (i, stmt) in enumerate(code[1].code)
    if stmt isa Expr && (stmt.head === :invoke || stmt.head === :call)
        mi_or_func = stmt.args[1]
        name = if mi_or_func isa Core.MethodInstance
            mi_or_func.def.name
        elseif mi_or_func isa GlobalRef
            mi_or_func.name
        else
            "unknown"
        end
        println("  Line $i: $name, SSA type = $(code[1].ssavaluetypes[i])")
    end
end

println("\nChecking if line 7 and 12 are in ctx.ssa_locals...")
println("(This requires actual compilation, checking if Any types are skipped...)")
