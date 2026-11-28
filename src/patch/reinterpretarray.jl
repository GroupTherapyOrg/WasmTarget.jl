# Base's reinterpret of one bits value as another by overlay, as src/patch's String and Memory
# operations: Base boxes the value in a Ref, takes the two Refs' addresses (unsafe_convert(Ptr{In}, in),
# pointer_from_objref, the runtime's jl_value_ptr) and copies sizeof(Out) bytes between them by memcpy
# (julia/base/reinterpretarray.jl:853 _reinterpret), and a WasmGC reference has no address. The bytes the
# two Refs hold are a byte Memory here, a data array: the value's leaves stored at their field offsets,
# each primitive's bytes in little-endian order (wasm's linear memory order and the native host's), and
# the result's leaves read back from the same offsets, as dart's ByteData writes a value's bytes into its
# WasmArray<WasmI8> and reads another type's back (sdk/lib/_internal/wasm/common/typed_data.dart). The
# layout is Julia's own (fieldoffset, sizeof, Base's padding and packedsize). The overlay is consistent:
# natively it computes Base's answer.
# precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; gpucompiler: a device's
# overlays of Base in its method table).



# the unsigned integer of a leaf's size, Julia's own answer for each: unsigned of a bit integer,
# uinttype of a float (julia/base/float.jl), and the UInt8 and UInt32 Bool and Char are stored as
@quarantine pin"precedent(dart: sdk/lib/_internal/wasm/common/typed_data.dart:425 ByteDataBase._setFloat64Unchecked)" "dart's ByteData stores a double as the bytes of its bits, doubleToIntBits, an unsigned integer of its size (precedent(dart: sdk/lib/_internal/wasm/common/typed_data.dart:425 ByteDataBase._setFloat64Unchecked)); Julia differs: each primitive's unsigned integer is Base's own, unsigned and uinttype" Base.unsigned _packed_uint(::Type{T}) where {T<:Base.BitInteger} = unsigned(T)
@quarantine pin"precedent(dart: sdk/lib/_internal/wasm/common/typed_data.dart:425 ByteDataBase._setFloat64Unchecked)" "dart's ByteData stores a double as the bytes of its bits, doubleToIntBits, an unsigned integer of its size (precedent(dart: sdk/lib/_internal/wasm/common/typed_data.dart:425 ByteDataBase._setFloat64Unchecked)); Julia differs: a float's unsigned integer is Base's uinttype" Base.uinttype _packed_uint(::Type{T}) where {T<:Base.IEEEFloat} = Base.uinttype(T)
@quarantine pin"precedent(dart: sdk/lib/_internal/wasm/common/typed_data.dart:425 ByteDataBase._setFloat64Unchecked)" "dart's ByteData stores a value as the bytes of an unsigned integer of its size (precedent(dart: sdk/lib/_internal/wasm/common/typed_data.dart:425 ByteDataBase._setFloat64Unchecked)); Julia differs: a Bool is one byte, sizeof(Bool), its unsigned integer UInt8" Core.UInt8 _packed_uint(::Type{Bool}) = UInt8
@quarantine pin"precedent(dart: sdk/lib/_internal/wasm/common/typed_data.dart:425 ByteDataBase._setFloat64Unchecked)" "dart's ByteData stores a value as the bytes of an unsigned integer of its size (precedent(dart: sdk/lib/_internal/wasm/common/typed_data.dart:425 ByteDataBase._setFloat64Unchecked)); Julia differs: a Char is four bytes, sizeof(Char), its unsigned integer UInt32" Core.UInt32 _packed_uint(::Type{Char}) = UInt32

# a leaf's bytes stored at byte offset `o` of the Ref's bytes, least significant first, as dart's
# _setUint64Unchecked's little-endian arm stores each byte of the value shifted down
@quarantine pin"precedent(dart: sdk/lib/_internal/wasm/common/typed_data.dart:351 ByteDataBase._setUint64Unchecked)" "Base's Ref{In}(x) stores x's bytes at its box's address; WasmGC has no address, so each byte of the leaf's bits is stored into the byte Memory's element, as dart's ByteData stores each byte of the value into its WasmArray<WasmI8>, little-endian; Julia differs: the leaf's size is sizeof of its type, any of 1, 2, 4, 8 and 16 bytes, where dart names one setter per size" Core.Intrinsics.bitcast @inline function _packed_store!(m::Memory{UInt8}, o::Int, x::Union{Base.BitInteger, Base.IEEEFloat, Bool, Char})::Nothing
    local u = Core.Intrinsics.bitcast(_packed_uint(typeof(x)), x)
    for k in 0:sizeof(x)-1
        @inbounds m[o + k + 1] = (u >> (8 * k)) % UInt8
    end
    return nothing
end

# a tuple's leaves each stored at its field's offset (Julia's fieldoffset), as Base's memcpy copies the
# tuple's bytes in its layout
@quarantine pin"julia/base/reinterpretarray.jl:853 _reinterpret" "Base's memcpy copies a tuple's bytes in its layout through its Ref's address; WasmGC has no address, so each leaf is stored at its field's offset, Julia's fieldoffset" Base.fieldoffset @inline function _packed_store!(m::Memory{UInt8}, o::Int, x::Tuple{Vararg{Union{Base.BitInteger, Base.IEEEFloat, Bool, Char}}})::Nothing
    ntuple(i -> _packed_store!(m, o + Int(fieldoffset(typeof(x), i)), getfield(x, i)), Val(nfields(x)))
    return nothing
end

# a leaf read from byte offset `o` of the Ref's bytes, least significant first, as dart's
# _getUint64Unchecked's little-endian arm ors each byte shifted up, its bits the leaf's
@quarantine pin"precedent(dart: sdk/lib/_internal/wasm/common/typed_data.dart:315 ByteDataBase._getUint64Unchecked)" "Base's out[] loads Out's bytes from its box's address; WasmGC has no address, so each byte is read from the byte Memory's element and the leaf's bits are their little-endian or, as dart's ByteData reads its WasmArray<WasmI8>; Julia differs: the leaf's size is sizeof of its type, any of 1, 2, 4, 8 and 16 bytes, and the bits are cast to the leaf's type, where dart names one getter per size" Core.Intrinsics.bitcast @inline function _packed_load(::Type{T}, m::Memory{UInt8}, o::Int)::T where {T<:Union{Base.BitInteger, Base.IEEEFloat, Bool, Char}}
    local U = _packed_uint(T)
    local u = zero(U)
    for k in 0:sizeof(T)-1
        u |= ((@inbounds m[o + k + 1]) % U) << (8 * k)
    end
    return Core.Intrinsics.bitcast(T, u)
end

# a tuple's leaves each read from its field's offset (Julia's fieldoffset), the tuple of their values
@quarantine pin"julia/base/reinterpretarray.jl:853 _reinterpret" "Base's out[] loads a tuple's bytes in its layout through its Ref's address; WasmGC has no address, so each leaf is read from its field's offset, Julia's fieldoffset, and the tuple is made of them" Base.fieldoffset @inline function _packed_load(::Type{T}, m::Memory{UInt8}, o::Int)::T where {T<:Tuple{Vararg{Union{Base.BitInteger, Base.IEEEFloat, Bool, Char}}}}
    return ntuple(i -> _packed_load(fieldtype(T, i), m, o + Int(fieldoffset(T, i))), Val(fieldcount(T)))
end

# Base's body (julia/base/reinterpretarray.jl:853), its two Refs one byte Memory of sizeof(In) bytes: x
# stored into it (Ref{In}(x)), and Out read from it, the bytes memcpy(ptr_out, ptr_in, sizeof(Out)) gives
# Ref{Out}() (struct_subpadding holds, so their sizes and padding agree); mismatched padding stays Base's
# _reinterpret_padding, its Refs' addresses a located rejection where it is reached
# The overlay takes a leaf (a bit integer, a float, a Bool or a Char, each a primitive type of 1, 2, 4,
# 8 or 16 bytes, whose bytes ByteData reads and writes as one unsigned integer of its size) or a tuple of
# leaves; any other bits type (a struct, a nested tuple) stays Base's method, its jl_value_ptr a located
# rejection where it is reached
@quarantine pin"julia/base/reinterpretarray.jl:853 _reinterpret" "Base's _reinterpret copies sizeof(Out) bytes by memcpy between two Refs' addresses, pointer_from_objref's jl_value_ptr; a WasmGC reference has no address, so the Refs' bytes are one byte Memory, x stored into it and Out read from it" Base._reinterpret @consistent_overlay METHOD_TABLE @inline function Base._reinterpret(::Type{Out}, x::In) where {Out<:Union{Union{Base.BitInteger, Base.IEEEFloat, Bool, Char}, Tuple{Vararg{Union{Base.BitInteger, Base.IEEEFloat, Bool, Char}}}}, In<:Union{Union{Base.BitInteger, Base.IEEEFloat, Bool, Char}, Tuple{Vararg{Union{Base.BitInteger, Base.IEEEFloat, Bool, Char}}}}}
    isbitstype(Out) || throw(ArgumentError("Target type for `reinterpret` must be isbits"))
    isbitstype(In) || throw(ArgumentError("Source type for `reinterpret` must be isbits"))
    local inpackedsize = Base.packedsize(In)
    local outpackedsize = Base.packedsize(Out)
    inpackedsize == outpackedsize ||
        throw(ArgumentError(LazyString("Packed sizes of types ", Out, " and ", In,
            " do not match; got ", outpackedsize, " and ", inpackedsize, ", respectively.")))
    if Base.struct_subpadding(Out, In)
        local bytes = Memory{UInt8}(undef, sizeof(In))
        _packed_store!(bytes, 0, x)
        return _packed_load(Out, bytes, 0)::Out
    else
        return Base._reinterpret_padding(Out, x)
    end
end
