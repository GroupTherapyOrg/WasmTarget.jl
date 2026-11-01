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

# the little-endian 64-bit word of `s`'s bytes from `offset` (from 0), jl_load_unaligned_i64's read
@quarantine "julia/src/support/MurmurHash3.c:220 MurmurHash3_x64_128 reads each block as a little-endian 64-bit word (jl_load_unaligned_i64)" Base.:<< function murmur3_block(s::String, offset::Int)::UInt64
    local k = UInt64(0)
    for j in 0:7
        k |= UInt64(wasm_string_codeunit(s, offset + j)) << (8j)
    end
    return k
end

"""
    memhash_seed(s, seed) -> UInt64

Julia's runtime hash of the String `s`'s bytes under `seed`: MurmurHash3_x64_128 over them, its second
64-bit half (hashing.c memhash_seed's `out[1]`), the 16-byte blocks, the tail of up to 15 bytes falling
through as the C switch does, the length mixed in and each half finalized.
"""
@quarantine "julia/src/support/hashing.c:68 memhash_seed answers MurmurHash3_x64_128's second half (julia/src/support/MurmurHash3.c:220)" Base.bitrotate function memhash_seed(s::String, seed::UInt32)::UInt64
    local len = wasm_string_length(s)
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
            k2 = xor(k2, UInt64(wasm_string_codeunit(s, tail + j)) << (8 * (j - 8)))
        end
        k2 *= c2; k2 = bitrotate(k2, 33); k2 *= c1; h2 = xor(h2, k2)
    end
    if rest > 0
        local k1 = UInt64(0)
        for j in 0:min(rest, 8)-1
            k1 = xor(k1, UInt64(wasm_string_codeunit(s, tail + j)) << (8 * j))
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
