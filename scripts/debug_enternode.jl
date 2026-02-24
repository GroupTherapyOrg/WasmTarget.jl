using WasmTarget

# Find what types have exactly 2 externref fields
# These are types where both fields are Any-typed in Julia
candidates = [
    Core.PiNode,
    Core.PhiCNode,
    Core.UpsilonNode,
]

for T in candidates
    if isconcretetype(T) && isstructtype(T)
        fc = fieldcount(T)
        println("$T: $fc fields")
        for i in 1:fc
            println("  $(fieldname(T, i)) :: $(fieldtype(T, i))")
        end
    end
end

# Get the typed IR using Core.Compiler directly
println("\n--- :new expressions in construct_ssa! unoptimized IR ---")
# Find the method for construct_ssa!
ms = methods(Core.Compiler.construct_ssa!)
println("Methods: ", length(collect(ms)))
for m in ms
    println("  ", m)
end

# Use code_typed_by_type
try
    arg_types = Tuple{Core.Compiler.IncrementalCompact, Vector{Any}, Vector{Any}, Type, Bool, Bool}
    ci = code_typed(Core.Compiler.construct_ssa!, arg_types; optimize=false)
    if !isempty(ci)
        code_info = ci[1][1]
        println("IR has $(length(code_info.code)) statements")
        for (i, stmt) in enumerate(code_info.code)
            if stmt isa Expr && stmt.head === :new
                struct_type_ref = stmt.args[1]
                nargs = length(stmt.args) - 1
                struct_type = if struct_type_ref isa GlobalRef
                    try getfield(struct_type_ref.mod, struct_type_ref.name) catch; struct_type_ref end
                elseif struct_type_ref isa DataType
                    struct_type_ref
                else
                    struct_type_ref
                end
                fc = 0
                try fc = fieldcount(struct_type) catch; end
                flag = nargs < fc ? " *** MISSING FIELDS ($nargs/$fc)" : ""
                println("Stmt $i: :new($struct_type) $nargs args$flag")
            end
        end
    end
catch e
    println("Error: ", e)
    # Try direct method instance approach
    mi = first(Base.method_instances(Core.Compiler.construct_ssa!))
    println("Method instance: ", mi)
end
