using WasmTarget

f = getfield(Core.Compiler, Symbol("construct_ssa!"))

# Check EnterNode registration
println("=== Core.EnterNode fields ===")
println("fieldnames: ", fieldnames(Core.EnterNode))
println("fieldtypes: ", fieldtypes(Core.EnterNode))
println("fieldcount: ", fieldcount(Core.EnterNode))
println("ismutable: ", ismutabletype(Core.EnterNode))

# Register it and check what gets stored
mod = WasmTarget.WasmModule()
reg = WasmTarget.TypeRegistry()
WasmTarget.register_struct_type!(mod, reg, Core.EnterNode)
info = reg.structs[Core.EnterNode]
println("\nRegistered info:")
println("  wasm_type_idx: ", info.wasm_type_idx)
println("  field_types: ", info.field_types)
println("  n_fields (field_types): ", length(info.field_types))

# Check wasm struct definition
struct_def = mod.types[info.wasm_type_idx + 1]
println("  wasm struct type: ", typeof(struct_def))
if struct_def isa WasmTarget.StructType
    println("  wasm fields: ", length(struct_def.fields))
    for (i, field) in enumerate(struct_def.fields)
        println("    field $i: $(field.valtype) (mutable=$(field.mutable_))")
    end
end

# Now look at the :new expressions in construct_ssa! IR
println("\n=== :new(Core.EnterNode, ...) in IR ===")
sig = first(methods(f)).sig
arg_types = Tuple(sig.parameters[2:end])
ci_list = code_typed(f, arg_types)
if !isempty(ci_list)
    ci, ret = ci_list[1]
    for (i, stmt) in enumerate(ci.code)
        if stmt isa Expr && stmt.head === :new
            struct_type_ref = stmt.args[1]
            resolved_type = if struct_type_ref isa DataType
                struct_type_ref
            elseif struct_type_ref isa GlobalRef
                try getfield(struct_type_ref.mod, struct_type_ref.name) catch; nothing end
            else
                nothing
            end
            if resolved_type === Core.EnterNode
                field_values = stmt.args[2:end]
                println("  Statement $i: $stmt")
                println("    n_field_values: $(length(field_values))")
                println("    field_values: $field_values")
                println("    ssa_type: $(ci.ssavaluetypes[i])")
                println()
            end
        end
    end
end
