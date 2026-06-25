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
    if neg
        push!(bytes, 0x01)
    end
    SHA.update!(ctx, bytes)
    return SHA.digest!(ctx)
end


# Julia 1.13 changed the API: hash_seed(seed, ctx::SHA_CTX) streams into a
# caller-provided context. Same type-stable byte-vector reroute; the native
# tail returns `nothing`.
@static if VERSION >= v"1.13-"
    @overlay WasmTarget.WASM_METHOD_TABLE function Random.hash_seed(seed::Integer, ctx::SHA.SHA_CTX)
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
        if neg
            push!(bytes, 0x01)
        end
        SHA.update!(ctx, bytes)
        return nothing
    end
end

# NB the Float64-ARRAY in-place fills (rand!/randn!/randexp! on `Array{Float64}`)
# are deliberately NOT overlaid. Native dispatches them to a hardware-vectorized
# 8-lane SIMD bulk generator (`Random.xoshiro_bulk_simd`, threshold 64 bytes = 8
# elements, built on `llvmcall` SIMD intrinsics WT can't lower) whose draw stream
# PROVABLY differs from the scalar generator for n ≥ 8 (rand!) / n ≥ 7
# (randn!/randexp!). A scalar-loop overlay is therefore NOT bit-identical, and
# reproducing the fork+interleave (plus the Ziggurat array variants) would be a
# second RNG — a latent wrong-value surface. Classified out-of-scope in
# stdlib_coverage.jl; the SCALAR rand/randn/randexp remain fully verified.

# ── randstring ──────────────────────────────────────────────────────────────
# `randstring(rng, n)` builds a `Base.StringVector` and fills it via the charset
# Sampler, a path that lowers to an `unreachable` stub (StringVector undef-buffer
# + collection-sampler interplay). The default alphabet is the 62-byte
# `[0-9 A-Z a-z]`; drawing one byte per position with the scalar collection
# sampler `rand(rng, CHARS)` (verified to compile + match in wasm) reproduces
# native `randstring`'s exact draw sequence — bit-identical String across 200
# seeds (pure Julia) and the wasm differential sweep.
const _WT_RANDSTRING_CHARS = UInt8['0':'9'; 'A':'Z'; 'a':'z']
@overlay WasmTarget.WASM_METHOD_TABLE function Random.randstring(rng::Xoshiro, n::Integer)
    v = Vector{UInt8}(undef, Int(n))
    @inbounds for i in 1:Int(n)
        v[i] = rand(rng, _WT_RANDSTRING_CHARS)
    end
    String(v)
end
@overlay WasmTarget.WASM_METHOD_TABLE Random.randstring(rng::Xoshiro) = Random.randstring(rng, 8)

end # module
