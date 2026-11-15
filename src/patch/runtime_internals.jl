# An object's id by overlay: Base's objectid calls Julia's runtime jl_object_id through a ccall
# (julia/base/runtime_internals.jl:854), which no host supplies, so the method is replaced in WasmTarget's
# overlay method table (METHOD_TABLE, src/julia/interpreter.jl) by the runtime's function ported
# (src/julia/runtime/hashing.jl jl_object_id), specialized on the value's type. The overlay is
# consistent: natively Base's own method answers, and a fold of objectid of a constant (@_total_meta) is
# Base's, which the module keeps for that constant (src/julia/runtime/hashing.jl image_slot!); a mutable
# object's id in a module is its identity's (jl_object_id_identity: a serial stands where Julia hashes an
# address); a value whose id the port does not compute (a type value's, a Module's, a SimpleVector's)
# reaches Base's ccall, natively the runtime's answer and in a module a located rejection where it is
# reached. How a module differs from native: an immutable
# value's id is seeded by its type's hash, the compiling process's folded in as a constant
# (src/julia/runtime/hashing.jl datatype_hash), so the module behaves as a build in which that hash was
# fixed at compile time; for a type of a module made at run time, whose hash differs in every process
# (julia/src/module.c:512 build_id), the id answers as native Julia only against the compiling process.
# precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; gpucompiler: a device's
# overlays of Base in its method table).

# Its effects: Base's own, @_total_meta (julia/base/essentials.jl:192), written `:total` (julia/base/expr.jl:735, the
# same set: consistent, effect-free, nothrow, terminating, no task state, no memory but its own, no undefined behavior,
# no return-type call). nothrow holds in a module as natively: the one way the port could stop, its identity counter
# spent, is the fatal form (src/julia/runtime/hashing.jl identity_serials_spent: the text to the host, then the trap),
# which is no exception, so no `try` of the program is there to keep. Folding is unchanged.
@quarantine "julia/base/runtime_internals.jl:854 objectid calls the runtime's jl_object_id through a ccall under @_total_meta; WasmGC calls the runtime's function ported, under the same effects, :total: its one stop, the spent identity counter, is fatal, never an exception" Base.objectid @consistent_overlay METHOD_TABLE @assume_effects :total function Base.objectid(x)
    return jl_object_id(x)
end
