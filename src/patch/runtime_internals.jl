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

# Its effects: Base's @_total_meta (julia/base/essentials.jl:192) but nothrow, which is Base's own
# @_foldable_meta set (:207): consistent, effect-free, terminating, no task state, no memory but its
# own, no undefined behavior, no return-type call, written `:foldable :notaskstate :inaccessiblememonly`
# (julia/base/expr.jl:703 `:foldable` holds the rest). Julia differs (D7): natively objectid cannot
# throw; in a module the identity counter, spent, raises (src/runtime/common/object_patch.jl), so a
# program's own `catch` around objectid must stay to see it, and Julia deletes a `try` around a call it
# believes nothrow. Folding is unchanged: concrete evaluation needs the foldable effects alone.
@quarantine "julia/base/runtime_internals.jl:854 objectid calls the runtime's jl_object_id through a ccall under @_total_meta; WasmGC calls the runtime's function ported, claiming @_total_meta but one effect, nothrow: in a module the spent identity counter raises, where natively objectid cannot throw" Base.objectid @consistent_overlay METHOD_TABLE @assume_effects :foldable :notaskstate :inaccessiblememonly function Base.objectid(x)
    return jl_object_id(x)
end
