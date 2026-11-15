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

# Base's body (julia/base/genericmemory.jl:141), word for word, for two memories of one element type: an
# overlay table answers a call from its own methods alone when one covers it (Julia's OverlayMethodTable,
# Compiler/src/methodtable.jl:73), so the fallback's overlay below would otherwise take this call from
# Base's more specific method; held here, specificity picks it, its memoryrefs checking both ranges before
# the MemoryRef copy above (one array.copy) writes anything
@quarantine pin"julia/base/genericmemory.jl:141 unsafe_copyto!" "Base's copy between two memories of one element type, word for word: WasmTarget's overlay table answers from its own methods alone once the fallback's overlay covers a call, so Base's more specific method is held here beside it" Base.unsafe_copyto! @consistent_overlay METHOD_TABLE function Base.unsafe_copyto!(dest::Memory{T}, doffs, src::Memory{T}, soffs, n) where {T}
    n == 0 && return dest
    unsafe_copyto!(memoryref(dest, doffs), memoryref(src, soffs), n)
    return dest
end

# Base's body (julia/base/genericmemory.jl:148), the fallback where the memories' element types differ:
# each element converted and stored, or left #undef where the source's is, walked forwards unless the
# destination's first element lies among the source's, its pointer math the alias test of the two
# memories' data (wasm_memory_overlaps, src/julia/wasm_array.jl)
@quarantine pin"julia/base/genericmemory.jl:148 unsafe_copyto!" "Base's copy between memories of different element types decides its direction by pointer math on their elements' addresses; WasmGC has no addresses, so the direction is wasm_memory_overlaps's, its data arrays' identity and offsets" Base.unsafe_copyto! @consistent_overlay METHOD_TABLE function Base.unsafe_copyto!(dest::Memory, doffs, src::Memory, soffs, n)
    Base.@_terminates_locally_meta
    n == 0 && return dest
    @inbounds if !wasm_memory_overlaps(dest, Int(doffs), src, Int(soffs), Int(n))
        for i = 1:n
            if isassigned(src, soffs + i - 1)
                dest[doffs + i - 1] = src[soffs + i - 1]
            else
                Base._unsetindex!(dest, doffs + i - 1)
            end
        end
    else
        for i = n:-1:1
            if isassigned(src, soffs + i - 1)
                dest[doffs + i - 1] = src[soffs + i - 1]
            else
                Base._unsetindex!(dest, doffs + i - 1)
            end
        end
    end
    return dest
end

@quarantine "julia/base/genericmemory.jl:78 _unsetindex! of a MemoryRef stores its #undef through pointers (atomic_pointerset of C_NULL); WasmGC stores the data array's null" Base._unsetindex! @consistent_overlay METHOD_TABLE @inline function Base._unsetindex!(A::MemoryRef{T}) where {T}
    Base.@_propagate_inbounds_meta
    @boundscheck memoryref(A, 1)
    wasm_memory_unset!(A)
    return A
end

@quarantine "julia/base/genericmemory.jl:204 fill! of a byte memory memsets its elements through its address; WasmGC fills the data array" Base.fill! @consistent_overlay METHOD_TABLE function Base.fill!(a::Union{Memory{UInt8},Memory{Int8}}, x::Integer)
    wasm_memory_fill!(memoryref(a), x isa eltype(a) ? x : convert(eltype(a), x), length(a))
    return a
end

# Base's body (julia/base/array.jl:430), its memset through the Array's reference's address
# (unsafe_convert(Ptr{Cvoid}, a.ref)) the fill of the reference's memory from its offset for the Array's
# length (wasm_memory_fill!, src/julia/wasm_array.jl), the memory's fill! above from its first element
@quarantine pin"julia/base/array.jl:430 fill!" "fill! of a byte Array memsets its elements through its reference's address, Julia's element address; WasmGC fills the data array from the reference's offset, its element index" Base.fill! @consistent_overlay METHOD_TABLE function Base.fill!(a::Union{Array{UInt8},Array{Int8}}, x::Integer)
    wasm_memory_fill!(a.ref, x isa eltype(a) ? x : convert(eltype(a), x), length(a))
    return a
end

# Base's byte-memory method (julia/base/Base.jl:72) asks codegen's data-owner reader (the jl_genericmemory_owner
# ccall, julia/src/cgutils.cpp:3371 emit_genericmemoryowner, src/intrinsics.jl's lowering of it over the byte
# memory's `data#owner`) who owns the memory's data, to keep a String's bytes in a String: its first arm a new
# Memory, its second a new String's bytes as a Memory. Base's own body, its jl_string_to_genericmemory foreigncall
# WasmTarget's wasm_string_memory (src/julia/wasm_array.jl), natively that very call
@quarantine pin"julia/base/Base.jl:72 array_new_memory" "Base's byte-memory array_new_memory wraps a new String's bytes by the jl_string_to_genericmemory foreigncall; WasmTarget's is wasm_string_memory, natively that very call" Base.array_new_memory @consistent_overlay METHOD_TABLE function Base.array_new_memory(mem::Memory{UInt8}, newlen::Int)
    if (Base.@assume_effects :total @ccall jl_genericmemory_owner(mem::Any,)::Any) === mem
        return typeof(mem)(undef, newlen)
    else
        return wasm_string_memory(Base._string_n(newlen))
    end
end

# Base's dataids of a Memory (julia/base/abstractarray.jl:1591) is its data's address, `(UInt(A.ptr),)`, one per
# data: its own, or the String's whose bytes it wraps (julia/src/genericmemory.c:113). WasmGC has no address, so
# the data's id is its owner's (codegen's data-owner reader, as array_new_memory above reads it): a serial of the
# one identity counter (src/runtime/common/object_patch.jl Object__object_hash_code), written into the owner's
# identity hash field by the data owner's arm (set_owner_identity_hash_field, src/julia/runtime/hashing.jl
# jl_genericmemory_owner_arm), which admits a String, whose field holds its data's id and nothing else. Two
# Memories answer one id exactly when their data is one, as natively; an image constant's is its image id. A plain
# overlay, as muladd's (src/patch/floatfuncs.jl): natively the answer is an address, never the module's serial.
# formal(dev/formal/ObjectIdentity.tla): DataIdsExact; formal(dev/formal/ObjectIdentityStrings.tla): StringSlotDataOnly
@quarantine pin"julia/base/abstractarray.jl:1591 dataids" "Base's dataids of a Memory is its data's address, A.ptr; WasmGC has none, so the data's id is its owner's, read by codegen's data-owner reader (julia/src/cgutils.cpp:3371 emit_genericmemoryowner), a serial of the one identity counter; natively the answer is the address, never the module's" Base.dataids @overlay METHOD_TABLE function Base.dataids(A::Memory)
    local owner = A isa Memory{UInt8} ? (@ccall jl_genericmemory_owner(A::Any,)::Any)::Union{String,Memory{UInt8}} : A
    return (UInt(Runtime.Object__object_hash_code(owner, set_owner_identity_hash_field)),)
end

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
