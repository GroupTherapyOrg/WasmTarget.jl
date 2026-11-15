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
# the hash of its address (jl_object_id__cold's inthash((uintptr_t)v)), which a module's serial stands
# for (jl_object_id_identity), or the id an image constant keeps; of a type value its DataType's,
# TypeName's or kind's own hash, which a module does not hold: those stay Base's ccall, a located
# rejection where it is reached.

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

# a bits value's bytes stored at byte offset `o` of `m` in its layout: none for a value of no size (a
# singleton field of a struct occupies no byte of the block bits_hash reads, its jl_field_size 0, so
# Julia's hash never reads it), a leaf's least significant first (src/patch/reinterpretarray.jl
# _packed_store!), any other primitive's as Base's reinterpret reads its bytes, and a struct's fields
# each at its field offset (Julia's fieldoffset)
@quarantine "julia/src/builtins.c:315 bits_hash reads a bits value's bytes at its address; WasmGC has none, so its leaves are stored into a byte Memory at their field offsets" Base.fieldoffset @inline function bits_store!(m::Memory{UInt8}, o::Int, x::T)::Nothing where {T}
    if sizeof(T) == 0
        # no bytes: the block holds none of it (julia/src/builtins.c:424 bits_hash(v, sz) over the parent's)
    elseif x isa Union{Base.BitInteger, Base.IEEEFloat, Bool, Char}
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
    jl_object_id_by_hash(T) -> Bool

Whether `T` is a mutable type whose id Julia's runtime answers by the value's own hash or content, never
by its identity: a Symbol (jl_object_id_'s julia/src/builtins.c:491, its stored hash), a concrete
DataType's (:496) and a TypeName's (:499) stored hash, and jl_object_id__cold's String (:463, its bytes'
memhash), SimpleVector (:470, hash_svec), DataType (:472) and Module (:477, its hash): the one list,
whose complement among mutable types is the identity arm (jl_object_id_identity_arm), the set Julia's
image writer keeps an id for (julia/src/staticdata.c:1512 object_id_expected).
"""
@quarantine pin"julia/src/builtins.c:489 jl_object_id_" "jl_object_id_ and jl_object_id__cold answer a Symbol, a TypeName, a DataType, a String, a SimpleVector and a Module by a hash of their own, every other mutable by its identity" Core.SimpleVector function jl_object_id_by_hash(T::DataType)::Bool
    return T === Symbol || T === DataType || T === Core.TypeName || T === String || T === Core.SimpleVector || T === Module
end

"""
    jl_object_id_identity_arm(T) -> Bool

Whether Julia's runtime answers the id of a value of `T` by the object's identity: the last arm of
jl_object_id__cold (julia/src/builtins.c:482-484, `inthash((uintptr_t)v)`, or the id kept before the
header of an object saved in an image), which a mutable type takes unless jl_object_id_ answers it by
its stored hash first (a Symbol, :491; a TypeName, :499; a concrete DataType, :496) or the cold arm by
its content (a String, :463, its bytes' memhash; a SimpleVector, :470, hash_svec; a DataType, :472; a
Module, :477, its hash): exactly the objects Julia's image writer keeps an id for (julia/src/
staticdata.c:1512 object_id_expected; a Symbol it writes apart, :1247). The one answer of which values
are identities, read by the constants a module keeps the compiling process's id for (image_slot!).
"""
@quarantine pin"julia/src/builtins.c:459 jl_object_id__cold" "a mutable's id is its identity unless the runtime answers it by the value (a String, a SimpleVector, a DataType, a Module) or jl_object_id_ by its stored hash (a Symbol, a TypeName), the set the image writer keeps an id for (julia/src/staticdata.c:1512)" Base.ismutabletype function jl_object_id_identity_arm(T::DataType)::Bool
    return ismutabletype(T) && !jl_object_id_by_hash(T)
end

"""
    jl_genericmemory_owner_arm(T) -> Bool

Whether a value of `T` can own a Memory's data, read by codegen's data-owner reader
(julia/src/cgutils.cpp:3371 emit_genericmemoryowner, the `jl_genericmemory_owner` ccall, ccall.cpp:1872,
reading julia.h:1326 jl_genericmemory_data_owner_field): the Memory itself (julia/src/genericmemory.c:48, :167)
or the String whose bytes a byte Memory wraps (julia/src/genericmemory.c:113), Julia's every store of the field;
no other value, an identity or not, is ever an owner.
The write arm of a data id's identity hash field (identity_hash_field_holder), which dataids(::Memory) alone
writes (src/patch/genericmemory.jl): a String's field holds its data's id, the one id its data has
(julia/base/abstractarray.jl:1591, `UInt(A.ptr)`, the String's bytes for every Memory over them), and
nothing else; objectid of a String is its bytes' hash (builtins.c:463), never the field.
formal(dev/formal/ObjectIdentityStrings.tla): StringSlotDataOnly.
"""
@quarantine pin"julia/src/cgutils.cpp:3371 emit_genericmemoryowner" "a Memory's data is its own or the String's whose bytes it wraps (julia/src/genericmemory.c:113), the owner codegen reads from the data-owner field" Core.String function jl_genericmemory_owner_arm(T::DataType)::Bool
    return T === Core.String || T <: Core.GenericMemory
end

"""
    set_owner_identity_hash_field(obj, hash) -> Nothing

Stores `hash` in the identity hash field of `obj`, the data id of the Memory data `obj` owns: the write of
setIdentityHashField (src/runtime/common/object_helper.jl) under the data owner's arm
(jl_genericmemory_owner_arm), which admits a String, the owner of the bytes a byte Memory wraps
(julia/src/genericmemory.c:113), beside the Memory that owns its own (:48, :167). The intrinsifier
lowers a call of it (src/intrinsics.jl); its one caller is dataids(::Memory) (src/patch/genericmemory.jl),
through Object__object_hash_code. Natively no object carries the field, so the body raises.
"""
@quarantine pin"julia/base/abstractarray.jl:1591 dataids" "dart writes a String's identity hash field only to cache its hash (sdk/lib/_internal/wasm/js_common/js_string.dart:642); Julia's String keeps its data's id there, the address dataids reads" Core.Int64 @noinline set_owner_identity_hash_field(@nospecialize(obj::Any), hash::Core.Int64)::Nothing =
    (_wasm_only(Int64); nothing)

# the inverse of an odd 64-bit multiplier modulo 2^64, by Newton's iteration (each step doubles the correct
# low bits: 3 from x = a, then 6, 12, 24, 48, 96)
@quarantine pin"julia/src/support/hashing.c:28 int64hash" "int64hash's multiplications by odd constants are bijections of 64-bit words, each undone by the multiplier's inverse modulo 2^64" Base.:* function _odd_inverse(a::UInt64)::UInt64
    local x = a
    for _ in 1:5
        x *= 0x0000000000000002 - a * x
    end
    return x
end

# `x = y ⊻ (y >> s)` solved for y, its bits recovered from the top, s at a time
@quarantine pin"julia/src/support/hashing.c:28 int64hash" "int64hash's `key ^ (key >> s)` steps are bijections of 64-bit words, each undone from the top bits down" Base.xor function _xorshift_inverse(x::UInt64, s::Int)::UInt64
    local y = x
    local k = s
    while k < 64
        y = xor(x, y >> s)
        k += s
    end
    return y
end

"""
    int64hash_inverse(h) -> UInt64

The word `int64hash` (julia/src/support/hashing.c:28) maps to `h`: each of its steps undone in reverse
order, a multiplication by its odd multiplier's inverse, an xor-shift solved from the top bits. Read at
compile time only (image_id_meets_serial): an image object's id is int64hash of an address, and the
address is what a serial could meet.
"""
@quarantine pin"julia/src/support/hashing.c:28 int64hash" "int64hash is a bijection of 64-bit words: the address an image object's id hashed is its preimage" Base.:* function int64hash_inverse(h::UInt64)::UInt64
    local key = h * _odd_inverse(0x0000000080000001)         # key + (key << 31)
    key = _xorshift_inverse(key, 28)
    key *= _odd_inverse(0x0000000000000015)                  # key + (key << 2) + (key << 4)
    key = _xorshift_inverse(key, 14)
    key *= _odd_inverse(0x0000000000000109)                  # key + (key << 3) + (key << 8)
    key = _xorshift_inverse(key, 24)
    return (key + 0x0000000000000001) * _odd_inverse(0x00000000001fffff)   # ~key + (key << 21)
end

"""
    image_id_meets_serial(id) -> Bool

Whether an image object's compile-time id is one a serial gives: int64hash of a word from 1 to 2^31 - 1,
the id a module gives an object made at run time (dev/formal/ConstantImageIds.tla: NoCollisionCheck is the
compile that does not ask). int64hash is a bijection, so the two meet exactly when the image object's
address, the id's preimage, lies in that range. The one check, read by image_slot!.
"""
@quarantine pin"julia/src/support/hashing.c:28 int64hash" "an image object's id is int64hash of an address and a serial's int64hash of the serial: the two meet exactly when the preimage is a serial" Base.typemax image_id_meets_serial(id::UInt64)::Bool =
    UInt64(1) <= int64hash_inverse(id) <= UInt64(typemax(Int32))

"""
    image_slot!(statics, component, object, at) -> Union{Int32,Nothing}

formal(dev/formal/ConstantImageIds.tla): a constant's id is the compiling process's id of the Julia object its key names; none a serial gives

The identity hash slot a constant standing for `object` is made with. Julia's image writer stores, before
the header of every object whose id is its identity, the id the compiling process gave it
(julia/src/staticdata.c:1512 object_id_expected, :1524 `write_uint(f, jl_object_id(v))`), and
jl_object_id__cold reads it back when the header's GC_IN_IMAGE bit is set (julia/src/builtins.c:482-483),
so a module's id of a constant is the one the compiling process folded and laid its Dicts out by. A
WasmGC object has no word before its header: its identity hash slot (dart's, src/class_info.jl
FieldIndex_identity_hash) holds -k, the sign standing for GC_IN_IMAGE, and the module's table IMAGE_IDS
holds the id at k (image_object_id). Taken when the program reads an object's identity slot (its closed
world calls Runtime.get_identity_hash_field, decided once a compile) and `object`'s id is its identity
(jl_object_id_identity_arm). `object` is the Julia object the constant stands for, the one its key names
(src/julia/classes.jl memory_constant_object: a live copy's original), so its id is that object's whether
or not inference folds objectid of it. Else nothing: the constant keeps dart's initialIdentityHash, so a
program that never reads identity is the same module, byte for byte. Refused, located: an id a serial
could give (image_id_meets_serial), more image objects than an i32 slot's negative range, and a constant
made after the table (WasmTarget's fault), and a program whose identity counter the compiling process
holds at anything but 0 (a native run of a program that wrote it).

precedent(julia: julia/src/staticdata.c:1485 jl_write_values, the id kept with the object; dart: the
header's identity hash slot, object_patch.dart:16 Object._objectHashCode, which reads 0 as "never hashed"
and any other value as the hash). Julia's differs from dart's: a constant's id is fixed at compile time,
since Julia's compiler folds objectid of a constant (@_total_meta) and a constant Dict's slots are laid
out by it.
"""
@quarantine pin"julia/src/staticdata.c:1485 jl_write_values" "a WasmGC object has no word before its header for the id Julia's image keeps; its identity slot's sign marks the image and indexes the module's table of the compiling process's ids" Base.objectid function image_slot!(statics::CompileStatics, component::NirWorld, object, at::String)::Union{Int32,Nothing}
    local reads = statics.reads_identity[]
    if reads === nothing
        reads = any(nb -> nb.ci.def.def in methods(Runtime.get_identity_hash_field), component)
        statics.reads_identity[] = reads
        # the module's identity counter is a constant, its value the compiling process's, as every
        # constant's is; it means "no serial given" only at 0, and the compiling process never gives one
        # (natively the slot's read raises first), so a cell a program run natively wrote is refused,
        # located, never emitted as a module's start
        reads && Runtime.Object__hash_code_rnd[] != 0 &&
            reject!(ProgramError("src/julia/runtime/hashing.jl image_slot!: the identity counter Runtime.Object__hash_code_rnd holds $(Runtime.Object__hash_code_rnd[]) in the compiling process, not 0: a program run natively wrote it, so a module made now would give its first object that serial's successor and spend its serials early; restore it to 0"), at)
    end
    (reads && jl_object_id_identity_arm(typeof(object))) || return nothing
    # the constant named in each refusal, its text cut to 80 characters
    local named() = (local t = rejection_text(object); "the constant $(typeof(object)) $(length(t) > 80 ? first(t, 80) * "…" : t)")
    statics.image_ids_made[] &&
        reject!(Internal("src/julia/runtime/hashing.jl image_slot!: $(named()) made after the module's table of image ids"), at)
    local id = objectid(object)
    image_id_meets_serial(id) &&
        reject!(Unported("src/julia/runtime/hashing.jl image_slot!: $(named())'s compile-time id is int64hash($(int64hash_inverse(id))), the id that serial gives an object made at run time, so the module could not tell the two apart (its address lies below 2^31 on this host)"), at)
    length(statics.image_ids) < typemax(Int32) ||
        reject!(Unported("src/julia/runtime/hashing.jl image_slot!: $(named()) is one image object more than an i32 slot's negative range holds"), at)
    push!(statics.image_ids, reinterpret(Int64, id))
    return -Int32(length(statics.image_ids))
end

"""
    image_object_id(k) -> UInt64

The id an image object keeps, IMAGE_IDS's entry k (from 1): the word jl_object_id__cold reads before
the header of an object saved in an image (julia/src/builtins.c:483 `((uintptr_t*)v)[-2]`), here the
module's table of the ids the compiling process gave its constants (image_slot!). The intrinsifier
lowers a call to the read of the table's element (src/intrinsics.jl); natively no table exists, so the
body raises.
"""
@quarantine pin"julia/src/builtins.c:459 jl_object_id__cold" "an object saved in an image keeps its id in a word before its header, read at julia/src/builtins.c:483; a WasmGC object has none, so the module's table holds it" Core.UInt64 @noinline image_object_id(k::Int)::Core.UInt64 =
    _wasm_only(Core.UInt64)

"""
    identity_hash_field_holder(classes, member, at; arm) -> Nothing

The read or write of dart's identity hash field (`member`, getIdentityHashField or setIdentityHashField,
src/runtime/common/object_helper.jl) on an operand whose classes are `classes`, refused, located at `at`,
where one of them is a class Julia boxes fresh each time it flows to Any (an immutable struct, a
primitive): such a box holds no field that lasts, its read a plausible 0 and its write lost. A read
(`arm`, nothing) admits every mutable class, a String among them though Julia's egal compares Strings by
content: a String is a heap object carrying the field, and dart reads a String's field itself
(sdk/lib/_internal/wasm/js_common/js_string.dart:642). A write names its arm, each a separate writer:
objectid's (set_identity_hash_field, `arm` jl_object_id_identity_arm, the one definition of which values
Julia answers by their identity) admits only the identities, the field an identity's serial, so a
String's, whose id is its bytes', is never written there; a data id's (set_owner_identity_hash_field,
`arm` jl_genericmemory_owner_arm) admits what owns a Memory's data, a Memory or a String, whose field
then holds its data's id.

Julia-forced (D7): dart has no such check, its every Object a heap object with its header; Julia
boxes an immutable value or a primitive anew wherever it flows to Any, so the header such a box
carries is no value's.
"""
@quarantine pin"julia/src/builtins.c:459 jl_object_id__cold" "dart's every Object is a heap object carrying its identity hash field; Julia boxes an immutable value or a primitive anew where it flows to Any, so only a mutable object keeps the field" Base.ismutabletype function identity_hash_field_holder(classes::Vector{DataType}, member::String, at::String;
        arm::Union{typeof(jl_object_id_identity_arm),typeof(jl_genericmemory_owner_arm),Nothing})::Nothing
    for c in classes
        ismutabletype(c) ||
            reject!(Unquarantined("src/julia/runtime/hashing.jl identity_hash_field_holder: $member of a value that may be a $c, which Julia boxes fresh each time it flows to Any, so no identity hash field of it lasts"), at)
        arm === nothing || arm(c) ||
            reject!(Unquarantined(arm === jl_object_id_identity_arm ?
                "src/julia/runtime/hashing.jl identity_hash_field_holder: $member of a value that may be a $c, whose id Julia answers by its own hash or content, not its identity, so its identity hash field holds no serial" :
                "src/julia/runtime/hashing.jl identity_hash_field_holder: $member of a value that may be a $c, which owns no Memory's data (Julia's owner is the Memory or a String, julia/src/genericmemory.c:48, :113, :167), so its identity hash field holds no data id"), at)
    end
    return nothing
end

"""
    jl_object_id(x) -> UInt64

Julia's object id of `x` (julia/src/builtins.c:489 jl_object_id_, :459 jl_object_id__cold): a
Symbol's stored hash (hash_symbol of its name); a String's memhash of its bytes under the seed
0xedc3b677; an object whose id is its identity (jl_object_id_identity_arm) its identity's
(jl_object_id_identity: the id an image constant keeps, else int64hash of its serial); an immutable
value's immut_id_ from its type's hash, the compiling process's folded in (datatype_hash: native
Julia's in that process, and in every process for a type of a module saved in an image, never for one
of a module made at run time). A type value's id (its DataType's, TypeName's or kind's hash), a
Module's and a SimpleVector's are Base's ccall, a located rejection where it is reached.
"""
@quarantine "julia/src/builtins.c:489 jl_object_id_ answers by the value's type tag: a Symbol's hash, a String's memhash, an immutable's immut_id_" Core.Symbol function jl_object_id(x::T)::UInt64 where {T}
    T === Symbol && return hash_symbol(String(x))
    T === String && return memhash_seed(x, 0xedc3b677)
    jl_object_id_identity_arm(T) && return jl_object_id_identity(x)
    # a type value's id is its own hash, a Module's and a SimpleVector's their own: Base's ccall
    (T <: Type || jl_object_id_by_hash(T)) && return ccall(:jl_object_id, UInt, (Any,), x)
    return immut_id_(x, datatype_hash(T))
end

"""
    jl_object_id_identity(x) -> UInt64

The id of an object whose id is its identity, jl_object_id__cold's last arm (julia/src/builtins.c:482-
484): an object saved in an image keeps the id the compiling process gave it (`((uintptr_t*)v)[-2]`
under GC_IN_IMAGE), here IMAGE_IDS's entry k where the identity hash slot holds -k (image_slot!,
image_object_id); any other object's id is `inthash((uintptr_t)v)`, int64hash on a 64-bit word
(julia/src/support/hashing.h:19), of its address. Julia differs: a WasmGC object has no address, so the
serial dart's lazy fill gives it (Runtime.Object__object_hash_code, object_patch.dart:16, from a
counter) stands for the address; int64hash is a bijection, so distinct serials give distinct ids as
distinct addresses do (dev/formal/ObjectIdentity.tla Unique; an image id a serial could give is
refused at compile time, dev/formal/ConstantImageIds.tla). The slot is dart's i32 read zero-extended,
so its sign is recovered (`% Int32`) before it is read as the image's mark. Natively no object carries
the slot and the read raises: natively Base's own objectid is the answer, and this arm exists only in
a module.
"""
@quarantine pin"julia/src/builtins.c:459 jl_object_id__cold" "a mutable's id is inthash of its address, or the id an image object keeps; a WasmGC object has none, so the serial dart's identity hash slot holds stands for the address" Core.Int32 function jl_object_id_identity(x::T)::UInt64 where {T}
    local s = Runtime.Object__object_hash_code(x, Runtime.set_identity_hash_field) % Core.Int32
    s < 0 && return image_object_id(-Int(s))
    return int64hash(UInt64(s))
end
