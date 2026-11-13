# A memory's element copy by overlay: Base copies a MemoryRef's elements through raw pointers
# (base/genericmemory.jl unsafe_copyto!: unsafe_convert(Ptr{Cvoid}, ref) and memmove for bits elements,
# the runtime's jl_genericmemory_copyto otherwise), and WasmGC has no raw memory, so the method is
# replaced in WasmTarget's overlay method table (METHOD_TABLE, src/julia/interpreter.jl) by one that
# copies the memories' data arrays (src/julia/wasm_array.jl wasm_memory_copy!), as dart's list patches
# copy their WasmArray. The overlay is consistent: natively it computes Base's answer.
# precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; gpucompiler: a device's
# overlays of Base in its method table).

@quarantine "julia/base/genericmemory.jl:116 unsafe_copyto! of two MemoryRefs copies through pointers (memmove, jl_genericmemory_copyto); WasmGC copies the data arrays" Base.unsafe_copyto! @consistent_overlay METHOD_TABLE function Base.unsafe_copyto!(dest::MemoryRef{T}, src::MemoryRef{T}, n) where {T}
    n == 0 && return dest
    @boundscheck memoryref(dest, n), memoryref(src, n)
    wasm_memory_copy!(dest, src, Int(n))
    return dest
end

@quarantine "julia/base/genericmemory.jl:78 _unsetindex! of a MemoryRef stores its #undef through pointers (atomic_pointerset of C_NULL); WasmGC stores the data array's null" Base._unsetindex! @consistent_overlay METHOD_TABLE @inline function Base._unsetindex!(A::MemoryRef{T}) where {T}
    Base.@_propagate_inbounds_meta
    @boundscheck memoryref(A, 1)
    wasm_memory_unset!(A)
    return A
end

@quarantine "julia/base/genericmemory.jl:204 fill! of a byte memory memsets its elements through its address; WasmGC fills the data array" Base.fill! @consistent_overlay METHOD_TABLE function Base.fill!(a::Union{Memory{UInt8},Memory{Int8}}, x::Integer)
    wasm_memory_fill!(a, x isa eltype(a) ? x : convert(eltype(a), x))
    return a
end

# Base's byte-memory method (julia/base/Base.jl:72) asks the runtime who owns the memory's data
# (jl_genericmemory_owner, Julia's codegen reading its data-owner slot: julia/src/cgutils.cpp:3371
# emit_genericmemoryowner) only to keep a String's bytes in a String: its first arm a new Memory, its
# second a new String's bytes as a Memory (jl_string_to_genericmemory). A WasmGC byte Memory holds no
# owner: its data array is the String's own array type, shared with a String both ways
# (src/intrinsics.jl jl_string_to_genericmemory and jl_genericmemory_to_string), so the two arms build
# one value, a new data array of newlen bytes beside its length, and the overlay is Base's first arm,
# the generic method's body (julia/base/array.jl:1067): natively a Memory of the same type, length and
# unset bytes as either arm's
@quarantine pin"julia/base/Base.jl:72 array_new_memory" "Base's byte-memory array_new_memory asks jl_genericmemory_owner whether a String owns the data, to keep it in one; a WasmGC byte Memory holds no owner, its data array shared with a String both ways, so both arms are a new data array of newlen bytes, Base's generic body" Base.array_new_memory @consistent_overlay METHOD_TABLE Base.array_new_memory(mem::Memory{UInt8}, newlen::Int) =
    typeof(mem)(undef, newlen)

# Base's body (julia/base/array.jl:2106), its memcmp of the two references' bytes through their addresses
# (unsafe_convert(Ptr{T}, a.ref)) the walk of their elements in order, as Base's generic == of two arrays
# (julia/base/abstractarray.jl:3032), whose shortcut it is, compares them, and as dart's VM == of two
# strings tests their lengths and then walks their code units: for a bit integer, equal elements are
# equal bytes, so the answer is memcmp's == 0
@quarantine "julia/base/array.jl:2106 == of two bit-integer Vectors compares their bytes by memcmp through the references' addresses; WasmGC has no addresses, so their lengths are tested and their elements walked in order, as dart's VM == of two strings walks their code units (sdk/lib/_internal/vm/lib/string_patch.dart:318 _StringBase.==) and Base's generic == of two arrays (julia/base/abstractarray.jl:3032), whose shortcut it is, compares their elements" Base.:(==) @consistent_overlay METHOD_TABLE function Base.:(==)(a::Arr, b::Arr) where {Arr <: Base.BitIntegerArray{1}}
    local len = length(a)
    len == length(b) || return false
    for i in 1:len
        @inbounds a[i] == b[i] || return false
    end
    return true
end
