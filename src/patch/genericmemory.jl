# A memory's element copy by overlay: Base copies a MemoryRef's elements through raw pointers
# (base/genericmemory.jl unsafe_copyto!: unsafe_convert(Ptr{Cvoid}, ref) and memmove for bits elements,
# the runtime's jl_genericmemory_copyto otherwise), and WasmGC has no raw memory, so the method is
# replaced in WasmTarget's overlay method table (METHOD_TABLE, src/julia/interpreter.jl) by one that
# copies the memories' data arrays (src/julia/wasm_array.jl wasm_memory_copy!), as dart's list patches
# copy their WasmArray. The overlay is consistent: natively it computes Base's answer.
# precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; gpucompiler: a device's
# overlays of Base in its method table).

@quarantine "julia/src/genericmemory.c:223 jl_genericmemory_copyto is the copy Base's unsafe_copyto! of two MemoryRefs makes through pointers; WasmGC copies the data arrays" Base.unsafe_copyto! @consistent_overlay METHOD_TABLE function Base.unsafe_copyto!(dest::MemoryRef{T}, src::MemoryRef{T}, n) where {T}
    n == 0 && return dest
    @boundscheck memoryref(dest, n), memoryref(src, n)
    wasm_memory_copy!(dest, src, Int(n))
    return dest
end
