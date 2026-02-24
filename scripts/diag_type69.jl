# Find which Julia type maps to wasm type index 69
using WasmTarget

f = getfield(Core.Compiler, Symbol("construct_ssa!"))
sig = first(methods(f)).sig
arg_types = Tuple(sig.parameters[2:end])

println("Compiling construct_ssa!...")
bytes = WasmTarget.compile(f, arg_types)

# Access the type registry from the compilation
# We need to hook into the compilation to get the registry
# Let's try a different approach: look at all registered struct types
# by calling compile again with debug

# Alternative: search for struct types with 2 externref fields
# by re-registering candidate types and checking
candidates = [
    Pair{Any, Any},
    Core.EnterNode,
    Core.Const,
    Core.PartialStruct,
    Core.PiNode,
    Core.UpsilonNode,
    Core.GotoIfNot,
    Core.ReturnNode,
]

mod = WasmTarget.WasmModule()
reg = WasmTarget.TypeRegistry()

# Register all candidate types and check their layouts
for T in candidates
    try
        WasmTarget.register_struct_type!(mod, reg, T)
        info = reg.structs[T]
        struct_def = mod.types[info.wasm_type_idx + 1]
        if struct_def isa WasmTarget.StructType
            fields = [(f.valtype) for f in struct_def.fields]
            println("$T → wasm_idx=$(info.wasm_type_idx) fields=$fields")
        end
    catch e
        println("$T → ERROR: $e")
    end
end
