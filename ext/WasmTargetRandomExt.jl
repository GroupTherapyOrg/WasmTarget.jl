# WasmTargetRandomExt — Random stdlib integration.
#
# Seeded Xoshiro streams compile from the real implementations; the one
# overlay below reroutes Random.hash_seed(::Integer) through SHA's
# TYPE-STABLE Vector{UInt8} update path. The native implementation feeds the
# hash 4-byte NTuple chunks through `Base.write`'s reflection machinery
# (Any-typed foldl/==/type-intersection guards — runtime dispatch WasmGC
# does not support). SHA-256 is streaming, so hashing one concatenated byte
# vector is bit-identical to hashing the chunks: same digest, same seed
# expansion, same stream as native (verified across positive/negative/wide
# seeds). now()-style OS entropy (seed-less RNGs, TaskLocalRNG) defers to
# embedding-side imports, like Dates.now().
module WasmTargetRandomExt

using WasmTarget
using Random
import SHA
using Base.Experimental: @overlay

@overlay WasmTarget.WASM_METHOD_TABLE function Random.hash_seed(seed::Integer)
    ctx = SHA.SHA2_256_CTX()
    neg = signbit(seed)
    if neg
        seed = ~seed
    end
    bytes = UInt8[]
    while true
        word = (seed % UInt32) & 0xffffffff
        seed >>>= 32
        push!(bytes, word % UInt8)
        push!(bytes, (word >> 8) % UInt8)
        push!(bytes, (word >> 16) % UInt8)
        push!(bytes, (word >> 24) % UInt8)
        iszero(seed) && break
    end
    neg && push!(bytes, 0x01)
    SHA.update!(ctx, bytes)
    return SHA.digest!(ctx)
end

end # module
