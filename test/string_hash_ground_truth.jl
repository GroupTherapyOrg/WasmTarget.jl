using Test

# Ground-truth string hashing (dev/HISTORY.md#string-hash-ground-truth).
#
# hash(::String,::UInt) / hash(::SubString{String},::UInt) are now overlaid
# with a pure-Julia port of Julia's OWN native algorithm (interpreter.jl,
# "String hash Overlay") — bit-exact with native Julia, not merely internally
# consistent. Before this fix, WT used FNV-1a: `hash("bb")` compiled to wasm
# returned 8387206607919070897 while native Julia 1.12.7 returns
# -10065557085131196 (as Int64) — self-consistent for wasm-BUILT Dicts, but
# silently wrong for a Dict{String,V}/Set{String} CONSTANT built natively:
# its slots array was placed by the native hash, so probing it with a
# different wasm hash lands in the wrong slot (KeyError / miss / wrong value).
#
# This file checks two independent things:
#   1. hash(s)/hash(s,h), compiled to wasm, agrees with the SAME Julia
#      process's native hash() — for a spread of string shapes covering
#      every branch of both the 1.12 MurmurHash3_x64_128 port and the 1.13
#      rapidhash port (empty / <4 / 4-7 / 8-15 / exactly-16 / 17-48 / >48
#      bytes, non-ASCII, SubString, a non-default seed).
#   2. Dict{String,Int}/Set{String} CONSTANTS built by NATIVE Julia (not
#      compiled) are looked up correctly from wasm — the actual failure mode
#      the bug produced, since native-built constants are embedded verbatim
#      (compile_memory_elements!, values.jl) with slot placement fixed by
#      the native hash at Julia compile time.
#
# Fixtures are hoisted to file top level (const/function defs are illegal —
# or bind only a testset-local variable — inside a @testset body); see
# mutable_global_initialization.jl for the same pattern.

# The bug as measured: hash("bb") wasm=8387206607919070897 (FNV-1a) vs
# native=-10065557085131196 (as Int64). Now must agree exactly.
@noinline _wt_hash_bb()::Int64 = Int64(hash("bb") % Int64)

# One @noinline no-arg function per string-length/shape class, each embedding
# a Wasm string CONSTANT (the harness has no String-argument marshaling
# across the JS boundary — every existing string test in this suite
# exercises compile-time literals the same way).
@noinline _wt_hash_len0()::Int64  = Int64(hash("") % Int64)
@noinline _wt_hash_len1()::Int64  = Int64(hash("a") % Int64)
@noinline _wt_hash_len3()::Int64  = Int64(hash("abc") % Int64)
@noinline _wt_hash_len4()::Int64  = Int64(hash("abcd") % Int64)
@noinline _wt_hash_len7()::Int64  = Int64(hash("abcdefg") % Int64)
@noinline _wt_hash_len8()::Int64  = Int64(hash("abcdefgh") % Int64)
@noinline _wt_hash_len9()::Int64  = Int64(hash("abcdefghi") % Int64)
@noinline _wt_hash_len15()::Int64 = Int64(hash("abcdefghijklmno") % Int64)
@noinline _wt_hash_len16()::Int64 = Int64(hash("abcdefghijklmnop") % Int64)
@noinline _wt_hash_len17()::Int64 = Int64(hash("abcdefghijklmnopq") % Int64)
@noinline _wt_hash_len32()::Int64 = Int64(hash("abcdefghijklmnopqrstuvwxyz012345") % Int64)
@noinline _wt_hash_len33()::Int64 = Int64(hash("abcdefghijklmnopqrstuvwxyz0123456") % Int64)
@noinline _wt_hash_len48()::Int64 = Int64(hash("abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLM") % Int64)
@noinline _wt_hash_len49()::Int64 = Int64(hash("abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMN") % Int64)
@noinline _wt_hash_len64()::Int64 = Int64(hash("abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ01") % Int64)
@noinline _wt_hash_len97()::Int64 = Int64(hash("abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxy") % Int64)

@noinline _wt_hash_nonascii1()::Int64 = Int64(hash("héllo wörld — 日本語") % Int64)
@noinline _wt_hash_nonascii2()::Int64 = Int64(hash("🎉🎊 emoji padding padding padding padding padding") % Int64)

@noinline _wt_hash_seeded()::Int64 = Int64(hash("some key", UInt(0x123456789abcdef0)) % Int64)
@noinline _wt_hash_seeded_zero()::Int64 = Int64(hash("zero seed string", UInt(0)) % Int64)

@noinline _wt_hash_substring()::Int64 = Int64(hash(SubString("the quick brown fox", 5, 9)) % Int64)
@noinline _wt_hash_substring_long()::Int64 =
    Int64(hash(SubString("the quick brown fox jumps over the lazy dog and keeps running past fifty bytes for sure", 5, 80)) % Int64)

# ── Native-built Dict{String,Int}/Set{String} CONSTANTS ─────────────────────
# These are embedded verbatim by compile_memory_elements! (values.jl):
# slots/keys/vals are copied straight from the NATIVE Dict's internal Memory,
# so lookup from wasm only works if the wasm hash used to probe those slots
# agrees with the native hash that placed them.
const _WT_HASH_DS = Dict("a" => 1, "bb" => 2, "ccc" => 3, "dddd" => 4)
const _WT_HASH_SS = Set(["x", "yy", "zzz"])

@noinline _wt_ds_hit()::Int64 = Int64(_WT_HASH_DS["bb"])
@noinline _wt_ds_hit2()::Int64 = Int64(_WT_HASH_DS["dddd"])
@noinline _wt_ds_get_default()::Int64 = Int64(get(_WT_HASH_DS, "missing-key", -1))
@noinline _wt_ds_haskey()::Int64 = Int64(haskey(_WT_HASH_DS, "bb")) * 100 + Int64(haskey(_WT_HASH_DS, "zz")) * 10 + Int64(length(_WT_HASH_DS))
# `copy(::Dict{String,V})` is a separate, pre-existing WT coverage gap
# ("unknown function call", unrelated to string hashing — copy(::Dict{Int64,V})
# compiles fine) — copy manually via iteration instead of exercising it here.
@noinline function _wt_ds_copy_insert()::Int64
    d2 = Dict{String,Int64}()
    for (k, v) in _WT_HASH_DS
        d2[k] = v
    end
    d2["ee"] = 5
    return Int64(length(d2)) * 100 + Int64(d2["ee"]) * 10 + Int64(d2["bb"])
end

@noinline _wt_ss_len_and_membership()::Int64 =
    Int64(length(_WT_HASH_SS)) * 1000 + Int64("yy" in _WT_HASH_SS) * 100 +
    Int64("qq" in _WT_HASH_SS) * 10 + Int64("x" in _WT_HASH_SS)

# ── Wasm-built Dict{String} round trip ───────────────────────────────────────
# Self-consistency check (build + probe all in wasm) alongside the
# native-constant checks above — both paths now share the SAME bit-exact hash.
@noinline function _wt_dict_str_roundtrip()::Int64
    d = Dict{String,Int64}()
    d["alpha"] = 1
    d["bravo"] = 2
    d["charlie"] = 3
    d["delta-is-a-longer-key-past-sixteen-bytes"] = 4
    delete!(d, "bravo")
    total = d["alpha"] + d["charlie"] + d["delta-is-a-longer-key-past-sixteen-bytes"]
    return Int64(length(d)) * 1000 + Int64(haskey(d, "bravo")) * 100 + total
end

@testset "string hash ground truth (bit-exact with native)" begin

    @testset "hash(::String) — reproduces the exact reported bug" begin
        r = compare_julia_wasm(_wt_hash_bb)
        @test r.pass
        # the native value is the ground truth; pin it where the algorithm is known
        # (1.12 memhash = MurmurHash3_x64_128[1]; 1.13 rapidhash differs by design)
        @static if VERSION < v"1.13.0-"
            @test r.expected == -10065557085131196
        end
    end

    @testset "hash(::String) — length/shape boundary classes" begin
        for fn in (_wt_hash_len0, _wt_hash_len1, _wt_hash_len3, _wt_hash_len4, _wt_hash_len7,
                   _wt_hash_len8, _wt_hash_len9, _wt_hash_len15, _wt_hash_len16, _wt_hash_len17,
                   _wt_hash_len32, _wt_hash_len33, _wt_hash_len48, _wt_hash_len49, _wt_hash_len64,
                   _wt_hash_len97, _wt_hash_nonascii1, _wt_hash_nonascii2)
            r = compare_julia_wasm(fn)
            @test r.pass
        end
    end

    @testset "hash(::String, ::UInt) — non-default seed" begin
        @test compare_julia_wasm(_wt_hash_seeded).pass
        @test compare_julia_wasm(_wt_hash_seeded_zero).pass
    end

    @testset "hash(::SubString{String})" begin
        @test compare_julia_wasm(_wt_hash_substring).pass
        @test compare_julia_wasm(_wt_hash_substring_long).pass
    end

    @testset "native-built Dict{String,Int} constant — hit/miss/haskey/copy+insert" begin
        r1 = compare_julia_wasm(_wt_ds_hit); @test r1.pass; @test r1.expected == 2
        r2 = compare_julia_wasm(_wt_ds_hit2); @test r2.pass; @test r2.expected == 4
        r3 = compare_julia_wasm(_wt_ds_get_default); @test r3.pass; @test r3.expected == -1
        r4 = compare_julia_wasm(_wt_ds_haskey); @test r4.pass; @test r4.expected == 104
        r5 = compare_julia_wasm(_wt_ds_copy_insert); @test r5.pass; @test r5.expected == 552
    end

    @testset "native-built Set{String} constant — length/membership" begin
        r = compare_julia_wasm(_wt_ss_len_and_membership)
        @test r.pass
        @test r.expected == 3101
    end

    @testset "wasm-built Dict{String} round trip" begin
        r = compare_julia_wasm(_wt_dict_str_roundtrip)
        @test r.pass
        @test r.expected == 3008   # length=3, haskey(bravo)=0, total=1+3+4=8
    end
end
