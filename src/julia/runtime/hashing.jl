# The hash of a byte string by Julia's own runtime (src/support/hashing.c memhash_seed over
# src/support/MurmurHash3.c MurmurHash3_x64_128), which Base's hash(::String) calls through a pointer
# (base/hashing.jl, ccall(:memhash_seed)). Ported line by line over a String's bytes, read as a wasm
# array's elements (src/julia/wasm_array.jl wasm_string_codeunit), so a module's hash of a String is
# native Julia's, bit for bit. Called by the overlay of hash(::String, ::UInt) (src/patch/hashing.jl).

# MurmurHash3's finalization mix of a 64-bit lane
@quarantine "julia/src/support/MurmurHash3.c:47 fmix64, its shifts and multiplies of a 64-bit lane" Base.xor function murmur3_fmix64(k::UInt64)::UInt64
    k = xor(k, k >> 33)
    k *= 0xff51afd7ed558ccd
    k = xor(k, k >> 33)
    k *= 0xc4ceb9fe1a85ec53
    k = xor(k, k >> 33)
    return k
end

# the bytes MurmurHash3 reads (julia/src/support/hashing.c:68 memhash_seed's `buf` and `n`): a String's,
# its wasm data array's elements, and the bytes of a bits value stored into a byte Memory (bits_hash)
@quarantine "julia/src/support/hashing.c:68 memhash_seed reads `n` bytes at `buf`; a String's are its data array's" Core.String murmur3_length(s::String)::Int = wasm_string_length(s)
@quarantine "julia/src/support/hashing.c:68 memhash_seed reads `n` bytes at `buf`; a bits value's are a byte Memory's elements" Base.length murmur3_length(m::Memory{UInt8})::Int = length(m)
@quarantine "julia/src/support/MurmurHash3.c:220 MurmurHash3_x64_128 reads the byte at `data + i`; a String's is its data array's element" Core.String murmur3_byte(s::String, i::Int)::UInt8 = wasm_string_codeunit(s, i)
@quarantine "julia/src/support/MurmurHash3.c:220 MurmurHash3_x64_128 reads the byte at `data + i`; a bits value's is a byte Memory's element" Core.Memory murmur3_byte(m::Memory{UInt8}, i::Int)::UInt8 = @inbounds m[i + 1]

# the little-endian 64-bit word of `s`'s bytes from `offset` (from 0), jl_load_unaligned_i64's read
@quarantine "julia/src/support/MurmurHash3.c:220 MurmurHash3_x64_128 reads each block as a little-endian 64-bit word (jl_load_unaligned_i64)" Base.:<< function murmur3_block(s::Union{String,Memory{UInt8}}, offset::Int)::UInt64
    local k = UInt64(0)
    for j in 0:7
        k |= UInt64(murmur3_byte(s, offset + j)) << (8j)
    end
    return k
end

"""
    memhash_seed(s, seed) -> UInt64

Julia's runtime hash of the bytes of `s`, a String or a byte Memory, under `seed`: MurmurHash3_x64_128 over them, its second
64-bit half (hashing.c memhash_seed's `out[1]`), the 16-byte blocks, the tail of up to 15 bytes falling
through as the C switch does, the length mixed in and each half finalized.
"""
@quarantine "julia/src/support/hashing.c:68 memhash_seed answers MurmurHash3_x64_128's second half (julia/src/support/MurmurHash3.c:220)" Base.bitrotate function memhash_seed(s::Union{String,Memory{UInt8}}, seed::UInt32)::UInt64
    local len = murmur3_length(s)
    local nblocks = len ÷ 16
    local h1 = UInt64(seed)
    local h2 = UInt64(seed)
    local c1 = 0x87c37b91114253d5
    local c2 = 0x4cf5ad432745937f
    # body
    for i in 0:nblocks-1
        local k1 = murmur3_block(s, 16i)
        local k2 = murmur3_block(s, 16i + 8)
        k1 *= c1; k1 = bitrotate(k1, 31); k1 *= c2; h1 = xor(h1, k1)
        h1 = bitrotate(h1, 27); h1 += h2; h1 = h1 * 5 + 0x52dce729
        k2 *= c2; k2 = bitrotate(k2, 33); k2 *= c1; h2 = xor(h2, k2)
        h2 = bitrotate(h2, 31); h2 += h1; h2 = h2 * 5 + 0x38495ab5
    end
    # tail: the switch over len & 15, bytes 15 down to 9 into k2, then 8 down to 1 into k1, each byte's
    # bits apart from the others', so they are taken in rising order (a falling range's step is checked)
    local tail = 16nblocks
    local rest = len & 15
    if rest > 8
        local k2 = UInt64(0)
        for j in 8:rest-1
            k2 = xor(k2, UInt64(murmur3_byte(s, tail + j)) << (8 * (j - 8)))
        end
        k2 *= c2; k2 = bitrotate(k2, 33); k2 *= c1; h2 = xor(h2, k2)
    end
    if rest > 0
        local k1 = UInt64(0)
        for j in 0:min(rest, 8)-1
            k1 = xor(k1, UInt64(murmur3_byte(s, tail + j)) << (8 * j))
        end
        k1 *= c1; k1 = bitrotate(k1, 31); k1 *= c2; h1 = xor(h1, k1)
    end
    # finalization
    h1 = xor(h1, len % UInt64); h2 = xor(h2, len % UInt64)
    h1 += h2
    h2 += h1
    h1 = murmur3_fmix64(h1)
    h2 = murmur3_fmix64(h2)
    h1 += h2
    h2 += h1
    return h2
end

# Julia's object id (julia/src/builtins.c:313-508 jl_object_id and its helpers), which Base's objectid
# calls through a ccall (julia/base/runtime_internals.jl:854) and hash(::Any) and hash(::Symbol) call
# (julia/base/hashing.jl:37, :39): a function of the value's content for a Symbol, a String and an
# immutable value, ported line by line and called by the overlay of objectid (src/patch/runtime_internals.jl),
# so a module's id of such a value is native Julia's, bit for bit, an immutable's type hash the
# compiling process's (datatype_hash: for a type of a module made at run time, the answer of that
# process alone). jl_object_id_ keys its arms by the
# value's type tag; here by its type, which a call's specialization knows. The id of a mutable object is
# the hash of its address (jl_object_id__cold's inthash((uintptr_t)v)), and of a type value its
# DataType's, TypeName's or kind's own hash, neither of which a module holds: those stay Base's ccall,
# a located rejection where it is reached.

# the integer hashes of julia/src/support/hashing.c, Thomas Wang's
@quarantine "julia/src/support/hashing.c:17 int32hash, its adds, shifts and xors of a 32-bit word" Base.xor function int32hash(a::UInt32)::UInt32
    a = (a + 0x7ed55d16) + (a << 12)
    a = xor(xor(a, 0xc761c23c), a >> 19)
    a = (a + 0x165667b1) + (a << 5)
    a = xor(a + 0xd3a2646c, a << 9)
    a = (a + 0xfd7046c5) + (a << 3)
    a = xor(xor(a, 0xb55a4f09), a >> 16)
    return a
end

@quarantine "julia/src/support/hashing.c:28 int64hash, its adds, shifts and xors of a 64-bit word" Base.xor function int64hash(key::UInt64)::UInt64
    key = ~key + (key << 21)
    key = xor(key, key >> 24)
    key = (key + (key << 3)) + (key << 8)
    key = xor(key, key >> 14)
    key = (key + (key << 2)) + (key << 4)
    key = xor(key, key >> 28)
    key = key + (key << 31)
    return key
end

# two words mixed, the second byte-swapped (julia/src/support/hashing.h:29, _P64's)
@quarantine "julia/src/support/hashing.h:29 bitmix hashes the first word xored with the second byte-swapped" Base.bswap bitmix(a::UInt64, b::UInt64)::UInt64 = int64hash(xor(a, bswap(b)))

# a Symbol's hash, which mk_symbol stores in it when it interns the name (julia/src/symbol.c:45)
@quarantine "julia/src/symbol.c:23 hash_symbol hashes the name's bytes (memhash) and inthash's the negated id" Base.String function hash_symbol(name::String)::UInt64
    local oid = xor(memhash_seed(name, 0xcafe8881), ~UInt64(0) ÷ 3 * 2)
    return int64hash(-oid)
end

# a DataType's hash, the field `uint32_t hash;` (julia/src/julia.h:614) of the struct whose typedef
# closes as jl_datatype_t at julia/src/julia.h:626, the line the pin names (the C reader resolves a
# typedef's name at its closing line); set when the type is made, a const field of DataType's
# (julia/src/jltypes.c datatype_constfields), so its read of a constant type folds.
# How it differs from native: the hash is the COMPILING process's, folded in as a constant, so the module
# behaves as a build in which the type's hash was fixed at compile time. Julia builds a type's hash from
# its TypeName's (julia/src/datatype.c:84 `tn->hash = bitmix(bitmix(module->build_id.lo, name->hash),
# 0xa1ada1da)`), and a module's build_id from the clock and a random number (julia/src/module.c:512
# `build_id.lo = bitmix(jl_hrtime() + count, jl_rand())`): stable across processes for a module saved in
# an image (Core, Base, Main, a precompiled package), different in every process for a module made at run
# time (a corpus unit's U_<slug>, a test's own module). For a type of such a module the id of its values
# answers as native Julia only against the compiling process; a comparison of ids answers as native
# Julia in any process, an id itself does not
@quarantine "julia/src/julia.h:626 jl_datatype_t holds its hash, a uint32_t, read as a uintptr_t" Core.DataType datatype_hash(T::DataType)::UInt64 = UInt64(reinterpret(UInt32, getfield(T, :hash)))

# whether field `i` of `T` is stored as a reference: the isptr bit compute_field_offsets clears where the
# field's type is laid out inline (jl_islayout_inline, Base's allocatedinline) and the field is not atomic
# or its type a DataType (julia/src/datatype.c:729), which jl_field_isptr reads (julia/src/julia.h:1595)
@quarantine "julia/src/datatype.c:629 jl_compute_field_offsets stores a field inline where its type's layout is inline and it is not atomic or its type is a DataType, which jl_field_isptr reads" Base.allocatedinline function jl_field_isptr(T::DataType, i::Int)::Bool
    local ft = fieldtype(T, i)
    return !(Base.allocatedinline(ft) && (!Base.isfieldatomic(T, i) || ft isa DataType))
end

# a bits value's bytes stored at byte offset `o` of `m` in its layout: a leaf's least significant first
# (src/patch/reinterpretarray.jl _packed_store!), any other primitive's as Base's reinterpret reads its
# bytes, and a struct's fields each at its field offset (Julia's fieldoffset)
@quarantine "julia/src/builtins.c:315 bits_hash reads a bits value's bytes at its address; WasmGC has none, so its leaves are stored into a byte Memory at their field offsets" Base.fieldoffset @inline function bits_store!(m::Memory{UInt8}, o::Int, x::T)::Nothing where {T}
    if x isa Union{Base.BitInteger, Base.IEEEFloat, Bool, Char}
        _packed_store!(m, o, x)
    elseif Int(Base.datatype_nfields(T)) == 0
        local bytes = reinterpret(NTuple{sizeof(T), UInt8}, x)
        for k in 1:sizeof(T)
            @inbounds m[o + k] = bytes[k]
        end
    else
        ntuple(i -> (Base.@constprop :aggressive; bits_store!(m, o + Int(fieldoffset(T, i)), getfield(x, i))), Val(Int(Base.datatype_nfields(T))))
    end
    return nothing
end

# the little-endian word of the first `n` bytes of `m` (bits_hash's jl_load_unaligned_i16, _i32, _i64)
@quarantine "julia/src/builtins.c:315 bits_hash loads a 2-, 4- or 8-byte value unaligned, little-endian (jl_load_unaligned_i64)" Base.:<< function bits_word(m::Memory{UInt8}, n::Int)::UInt64
    local w = UInt64(0)
    for k in 0:n-1
        w |= UInt64(@inbounds m[k + 1]) << (8k)
    end
    return w
end

"""
    bits_hash(x) -> UInt64

The hash of a bits value's bytes (julia/src/builtins.c:315 bits_hash): a 1-byte value's sign-extended
(read as int8_t), a 2- and 4-byte value's zero-extended (julia/src/support/dtypes.h:322
jl_load_unaligned_i16's uint16_t, :316 _i32's uint32_t), by int32hash, an 8-byte one's by int64hash, any other size's by memhash
over its bytes. The bytes are the value's stored into a byte Memory in its layout (bits_store!).
"""
@quarantine "julia/src/builtins.c:315 bits_hash hashes a bits value's bytes by its size: int32hash, int64hash or memhash" Base.sizeof function bits_hash(x::T)::UInt64 where {T}
    local sz = sizeof(T)
    local m = Memory{UInt8}(undef, sz)
    bits_store!(m, 0, x)
    sz == 1 && return UInt64(int32hash((bits_word(m, 1) % Int8) % UInt32))
    sz == 2 && return UInt64(int32hash(bits_word(m, 2) % UInt32))
    sz == 4 && return UInt64(int32hash(bits_word(m, 4) % UInt32))
    sz == 8 && return int64hash(bits_word(m, 8))
    return memhash_seed(m, 0xcafe8881)
end

"""
    immut_id_(x, h) -> UInt64

The id of the immutable value `x` from the seed `h` (julia/src/builtins.c:412 immut_id_): `~h` for a
value of no bytes; its bits block's hash xor `h` where it has no padding, no reference and its bits
decide its egality, or it is a primitive; else `h` mixed with each field's id in turn (bitmix): a
reference field's jl_object_id, an inline field's (a union's selected member's) immut_id_ from 0, and 0
for a field never set.
"""
@quarantine "julia/src/builtins.c:412 immut_id_ hashes a value's bits block or mixes each field's id into the seed" Base.datatype_nfields function immut_id_(x::T, h::UInt64)::UInt64 where {T}
    sizeof(T) == 0 && return ~h
    local nf = Int(Base.datatype_nfields(T))
    if nf == 0 || (!Base.datatype_haspadding(T) && Base.datatype_isbitsegal(T) && Base.datatype_pointerfree(T))
        return xor(bits_hash(x), h)
    end
    # each field's id mixed into h in turn, the fields unrolled (Base's ntuple over Val); the
    # @constprop :aggressive is this port's hint that each call's field index stays a constant (Base's
    # ntuple carries none), sound because where inference declines it the field's getfield and isdefined
    # by an index run time knows reject, located, never a value
    return foldl(bitmix, ntuple(i -> (Base.@constprop :aggressive; immut_field_id(x, i)), Val(nf)); init = h)
end

# the id of field `i` of `x` (immut_id_'s loop body): 0 for a field never set, a reference field's
# jl_object_id, an inline field's (a union's selected member's) immut_id_ from 0
@quarantine "julia/src/builtins.c:412 immut_id_'s loop takes each field's id by whether it is stored as a reference" Base.isdefined @inline function immut_field_id(x::T, i::Int)::UInt64 where {T}
    Base.@constprop :aggressive
    isdefined(x, i) || return UInt64(0)
    return jl_field_isptr(T, i) ? jl_object_id(getfield(x, i)) : immut_id_(getfield(x, i), UInt64(0))
end

"""
    jl_object_id(x) -> UInt64

Julia's object id of `x` (julia/src/builtins.c:489 jl_object_id_, :459 jl_object_id__cold): a
Symbol's stored hash (hash_symbol of its name); a String's memhash of its bytes under the seed
0xedc3b677; an immutable value's immut_id_ from its type's hash, the compiling process's folded in
(datatype_hash: native Julia's in that process, and in every process for a type of a module saved in an
image, never for one of a module made at run time). A type value's id (its DataType's,
TypeName's or kind's hash) and a mutable object's (its address's hash) are Base's ccall, a located
rejection where it is reached.
"""
@quarantine "julia/src/builtins.c:489 jl_object_id_ answers by the value's type tag: a Symbol's hash, a String's memhash, an immutable's immut_id_" Core.Symbol function jl_object_id(x::T)::UInt64 where {T}
    T === Symbol && return hash_symbol(String(x))
    T === String && return memhash_seed(x, 0xedc3b677)
    # a mutable object's id is its address's hash, a type value's its own hash: Base's ccall
    (ismutabletype(T) || T <: Type) && return ccall(:jl_object_id, UInt, (Any,), x)
    return immut_id_(x, datatype_hash(T))
end
