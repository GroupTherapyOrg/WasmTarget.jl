# An object's id by overlay: Base's objectid calls Julia's runtime jl_object_id through a ccall
# (julia/base/runtime_internals.jl:854), which no host supplies, so the method is replaced in WasmTarget's
# overlay method table (METHOD_TABLE, src/julia/interpreter.jl) by the runtime's function ported
# (src/julia/runtime/hashing.jl jl_object_id), specialized on the value's type. The overlay is
# consistent: natively it computes Base's answer, bit for bit, and a value whose id the port does not
# compute (a mutable object's, a type value's) reaches Base's ccall, natively the runtime's answer and
# in a module a located rejection where it is reached. How a module differs from native: an immutable
# value's id is seeded by its type's hash, the compiling process's folded in as a constant
# (src/julia/runtime/hashing.jl datatype_hash), so the module behaves as a build in which that hash was
# fixed at compile time; for a type of a module made at run time, whose hash differs in every process
# (julia/src/module.c:512 build_id), the id answers as native Julia only against the compiling process.
# precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; gpucompiler: a device's
# overlays of Base in its method table).

@quarantine "julia/base/runtime_internals.jl:854 objectid calls the runtime's jl_object_id through a ccall, keeping its @_total_meta; WasmGC calls the runtime's function ported" Base.objectid @consistent_overlay METHOD_TABLE @assume_effects :total function Base.objectid(x)
    return jl_object_id(x)
end
