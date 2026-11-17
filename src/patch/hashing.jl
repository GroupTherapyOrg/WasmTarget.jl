# A String's hash by overlay: Base hashes a String's bytes through a pointer, a call of Julia's runtime
# (base/hashing.jl hash(::String, ::UInt), ccall(:memhash_seed)), and WasmGC has no raw memory, so the
# method is replaced in WasmTarget's overlay method table (METHOD_TABLE, src/julia/interpreter.jl) by
# Base's same arithmetic around the runtime's hash ported over the String's bytes
# (src/julia/runtime/hashing.jl memhash_seed). The overlay is consistent: natively it computes Base's
# answer, bit for bit.
# precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; gpucompiler: a device's
# overlays of Base in its method table).

using Base: @assume_effects

@quarantine "julia/base/hashing.jl:198 hash of a String calls the runtime's hash through a pointer, keeping its @assume_effects :total; WasmGC reads the String's bytes" Base.hash @consistent_overlay METHOD_TABLE @assume_effects :total function Base.hash(s::String, h::UInt)
    h += Base.memhash_seed
    return memhash_seed(s, h % UInt32) + h
end
