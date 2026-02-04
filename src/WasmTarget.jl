module WasmTarget

# Builder - Low-level Wasm binary emitter
include("builder/types.jl")
include("builder/writer.jl")
include("builder/instructions.jl")

# Compiler - Julia IR to Wasm translation
include("compiler/ir.jl")
include("compiler/codegen.jl")

# Runtime - Intrinsics and stdlib mapping
include("runtime/intrinsics.jl")
include("runtime/stringops.jl")
include("runtime/arrayops.jl")
include("runtime/simpledict.jl")
include("runtime/bytebuffer.jl")
include("runtime/tokenizer.jl")

# Main API
export compile, compile_multi, WasmModule, to_bytes
export WasmGlobal, global_index, global_eltype
# Therapy.jl integration - direct IR compilation for reactive handlers
export compile_handler, compile_closure_body, DOMBindingSpec, TypeRegistry
export add_import!, add_global!, add_global_export!, add_function!, add_export!
export I32, I64, F32, F64, NumType, Opcode, ExternRef

"""
    compile(f, arg_types) -> Vector{UInt8}

Compile a Julia function `f` with the given argument types to WebAssembly bytes.
Returns a valid WebAssembly binary that can be instantiated and executed.
"""
function compile(f, arg_types::Tuple)::Vector{UInt8}
    # Get function name for export
    func_name = string(nameof(f))

    # Compile to WasmModule
    mod = compile_function(f, arg_types, func_name)

    # Serialize to bytes
    return to_bytes(mod)
end

# Convenience method for single argument type
compile(f, arg_type::Type) = compile(f, (arg_type,))

"""
    compile_multi(functions::Vector) -> Vector{UInt8}

Compile multiple Julia functions into a single WebAssembly module.

Each element should be (function, arg_types) or (function, arg_types, name).

# Example
```julia
wasm_bytes = compile_multi([
    (add, (Int32, Int32)),
    (sub, (Int32, Int32)),
    (helper, (Int32,), "internal_helper"),
])
```

Functions can call each other within the module.
"""
function compile_multi(functions::Vector)::Vector{UInt8}
    mod = compile_module(functions)
    return to_bytes(mod)
end

end # module
