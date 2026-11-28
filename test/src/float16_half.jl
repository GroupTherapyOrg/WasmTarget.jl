# Float16 as Julia's codegen and LLVM's WebAssembly backend answer it (src/intrinsics.jl Val(:half)): the value
# its 16 bits in an i32 (src/julia/classes.jl type_promote_integer), each operation LLVM's soft-promoted half,
# done in f32 between Julia's own conversions (src/julia/runtime/rtutils.jl julia_half_to_float, julia_float_to_half,
# the runtime_intrinsics.c routines Julia binds __extendhfsf2 and __truncsfhf2 to; a double first rounded to an
# f32 inexact-to-odd, LLVM's expandRoundInexactToOdd). Against native Julia on this host, each result by its bits (a NaN's sign and payload too): every one of the
# 65536 halves extended to Float32 and Float64; every float boundary a half rounds at, truncated from Float32 and
# Float64 (ties, one ulp either side, the double whose float rounding lands on a tie, subnormals, overflow, NaN
# payloads); the comparisons, rounding and sign operations over every half against a set of
# operands; the integer conversions both ways; a Float16 in a Vector, a struct field, an Any slot and a dynamic
# call. An intrinsic the port leaves out (rem_float; add_float and its kin, whose operand extension is compiler-rt's; min_float and max_float)
# rejects at its statement, located.
module Float16HalfTest
using Test, WasmTarget
const W = WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module Cases
# FNV-1a over the results' bits, the one number a case returns
mix(h::UInt64, x::Unsigned) = (h ⊻ UInt64(x)) * 0x00000100000001b3
const H0 = 0xcbf29ce484222325
half(u::Integer) = reinterpret(Float16, u % UInt16)
hbits(x::Float16) = reinterpret(UInt16, x)

# every half in the k-th 4096, extended (fpext)
function ext32(k::Int64)
    h = H0
    for u in (k * 4096):(k * 4096 + 4095)
        h = mix(h, reinterpret(UInt32, Float32(half(u))))
    end
    return reinterpret(Int64, h)
end
function ext64(k::Int64)
    h = H0
    for u in (k * 4096):(k * 4096 + 4095)
        h = mix(h, reinterpret(UInt64, Float64(half(u))))
    end
    return reinterpret(Int64, h)
end

# every float whose low 13 bits are one of a half's rounding boundaries (exact, one below the tie, the tie, one
# above, the last), over the k-th 32768 of the 2^19 upper parts: every sign, exponent and half significand
const F32_LOW = (UInt32(0), UInt32(0x0fff), UInt32(0x1000), UInt32(0x1001), UInt32(0x1fff), UInt32(0x0001))
function trunc32(k::Int64)
    h = H0
    for u in (k * 32768):(k * 32768 + 32767), d in F32_LOW
        h = mix(h, hbits(Float16(reinterpret(Float32, (UInt32(u) << 13) | d))))
    end
    return reinterpret(Int64, h)
end

# doubles at a half's boundaries and at a float's inside them (the tie 2^41, the tie plus one, whose float rounding
# lands on the tie, a float's tie 2^28): every sign and half significand at the exponent 1023 - 30 + k
const F64_LOW = (UInt64(0), UInt64(1), (UInt64(1) << 28) - 1, UInt64(1) << 28, (UInt64(1) << 28) + 1,
                 (UInt64(1) << 41) - 1, UInt64(1) << 41, (UInt64(1) << 41) + 1, (UInt64(1) << 42) - 1)
function trunc64(k::Int64)
    h = H0
    for s in UInt64(0):UInt64(1), m in UInt64(0):UInt64(1023), d in F64_LOW
        local e = UInt64(1023 - 30 + k)
        h = mix(h, hbits(Float16(reinterpret(Float64, (s << 63) | (e << 52) | (m << 42) | d))))
    end
    return reinterpret(Int64, h)
end
# the half nearest a double: Julia's Float16(::Float64) is LLVM's fptrunc (julia/base/float.jl:341), which
# llvm/docs/LangRef.md:12611 defines: "The 'fptrunc' instruction casts a value from a larger floating-point type to
# a smaller floating-point type. This instruction is assumed to execute in the default floating-point environment"
# (round to nearest, ties to even), a NaN's payload's low bits discarded; the IEEE rounding is MPFR's, Base's
# BigFloat conversion, and a NaN is native Julia's truncation of it. Native Float16(::Float64) on a host with no
# half conversion of its own is libjulia's double_to_half (runtime_intrinsics.c:190), which misrounds at a
# subnormal half's tie (hpc3's x86_64); on aarch64 it is the hardware's, the IEEE rounding (checked below)
rounded(x::Float64) = isnan(x) ? Float16(x) : Float16(big(x))
trunc64_ieee(k::Int64) = (h = H0; for s in UInt64(0):UInt64(1), m in UInt64(0):UInt64(1023), d in F64_LOW
        h = mix(h, hbits(rounded(reinterpret(Float64, (s << 63) | (UInt64(1023 - 30 + k) << 52) | (m << 42) | d))))
    end; reinterpret(Int64, h))
# the doubles past both ends and the special ones: zero, subnormal, the largest, infinity, NaNs with payloads
function trunc64_special(k::Int64)
    h = H0
    for e in (UInt64(0), UInt64(1), UInt64(900), UInt64(1100), UInt64(2046), UInt64(2047)), s in UInt64(0):UInt64(1),
        m in (UInt64(0), UInt64(1), UInt64(1) << 51, (UInt64(1) << 51) + UInt64(k), (UInt64(1) << 52) - 1, UInt64(0x5555) << 30)
        h = mix(h, hbits(Float16(reinterpret(Float64, (s << 63) | (e << 52) | m))))
    end
    return reinterpret(Int64, h)
end
trunc64_special_ieee(k::Int64) = (h = H0; for e in (UInt64(0), UInt64(1), UInt64(900), UInt64(1100), UInt64(2046), UInt64(2047)), s in UInt64(0):UInt64(1),
        m in (UInt64(0), UInt64(1), UInt64(1) << 51, (UInt64(1) << 51) + UInt64(k), (UInt64(1) << 52) - 1, UInt64(0x5555) << 30)
        h = mix(h, hbits(rounded(reinterpret(Float64, (s << 63) | (e << 52) | m))))
    end; reinterpret(Int64, h))

# a set of halves: zeros, subnormals, the smallest normal, one and its neighbours, ties, the largest, infinities,
# NaNs (quiet and signalling, both signs, payloads)
const SAMPLE = (0x0000, 0x8000, 0x0001, 0x8001, 0x03ff, 0x0400, 0x3c00, 0x3c01, 0x3bff, 0xbc00, 0x3800, 0x3e00, 0x4000,
                0x4200, 0x5640, 0x7bff, 0xfbff, 0x7c00, 0xfc00, 0x7e00, 0xfe00, 0x7c01, 0x7d55, 0xfc01, 0x3555, 0x1400)
# every half in the k-th 4096 against each sample: the comparisons, isequal, === and copysign
function binary(k::Int64)
    h = H0
    for u in (k * 4096):(k * 4096 + 4095), v in SAMPLE
        local x, y = half(u), half(v)
        h = mix(h, UInt8((x == y) + 2 * (x < y) + 4 * (x <= y) + 8 * (x != y) + 16 * isequal(x, y) + 32 * (x === y)))
        # copysign's sign is the second operand's; a NaN's quiet bit is no fact of Julia's (x86_64 quiets it)
        local c = copysign(x, y)
        h = mix(h, isnan(c) ? (signbit(c) ? 0xfe00 : 0x7e00) : hbits(c))
    end
    return reinterpret(Int64, h)
end
# every half in the k-th 4096: negation, magnitude, square root, the roundings, the predicates
function unary(k::Int64)
    h = H0
    for u in (k * 4096):(k * 4096 + 4095)
        local x = half(u)
        h = mix(h, hbits(-x)); h = mix(h, hbits(abs(x))); h = mix(h, hbits(Core.Intrinsics.sqrt_llvm(x)))
        h = mix(h, hbits(floor(x))); h = mix(h, hbits(ceil(x))); h = mix(h, hbits(trunc(x))); h = mix(h, hbits(round(x)))
        h = mix(h, UInt8(isnan(x) + 8 * signbit(x) + 16 * issubnormal(x) + 32 * iszero(x)))
    end
    return reinterpret(Int64, h)
end
# integers to halves (sitofp, uitofp) and halves to integers (fptosi, fptoui through unsafe_trunc)
function ints(k::Int64)
    h = H0
    for i in (k * 4096 - 70000):(k * 4096 - 70000 + 4095)
        h = mix(h, hbits(Float16(i))); h = mix(h, hbits(Float16(i % Int32))); h = mix(h, hbits(Float16(i % Int16)))
        h = mix(h, hbits(Float16(i % Int8))); h = mix(h, hbits(Float16(i % UInt64))); h = mix(h, hbits(Float16(i % UInt8)))
        h = mix(h, hbits(Float16(i % UInt16))); h = mix(h, hbits(Float16(isodd(i))))
        local x = half(i)
        if (hbits(x) & 0x7c00) != 0x7c00
            h = mix(h, reinterpret(UInt64, unsafe_trunc(Int64, x))); h = mix(h, reinterpret(UInt32, unsafe_trunc(Int32, x)))
            # a narrow result only in its range: past it fptosi and fptoui are poison (julia/src/intrinsics.cpp generic_cast)
            abs(x) < 32768 && (h = mix(h, reinterpret(UInt16, unsafe_trunc(Int16, x))))
            abs(x) < 256 && (h = mix(h, unsafe_trunc(UInt8, abs(x))))
            h = mix(h, unsafe_trunc(UInt64, abs(x)))
        end
    end
    # the integers past Float16's range round to infinity, either sign
    for i in (typemax(Int64), typemin(Int64), Int64(65519), Int64(65520), Int64(-65520), Int64(1) << 24 + 1, Int64(2049))
        h = mix(h, hbits(Float16(i))); h = mix(h, hbits(Float16(reinterpret(UInt64, i))))
    end
    return reinterpret(Int64, h)
end

# a Float16 held where its bits are stored: a Vector (an i16 element), a struct's field, an Any slot, and a dynamic
# call on a value of either class
struct HPair
    a::Float16
    b::Float16
end
@noinline dyn(x::Float16, y::Int64) = Float64(x) + y
@noinline dyn(x::Float16, y::Float64) = Float64(x) * y
function held(n::Int64)
    local v = Float16[half(u) for u in (n * 7):(n * 7 + 300)]
    v[3] = -v[1]
    local s = 0.0
    for x in v
        s += Float64(x)
    end
    local p = HPair(v[5], -v[6])
    local q = HPair(v[5], -v[6])
    local a = Any[v[7], n, 2.5]
    local d = dyn(Float16(1.5), a[2]) + dyn(Float16(2.0), a[3])
    return s + Float64(p.a) * 3 + Float64(p.b) + (p === q) * 1000 + (a[1] === v[7]) * 10000 + d +
           (a[1] isa Float16) * 100000
end

rem_half(x::Int64) = Core.Intrinsics.rem_float(half(x), half(x + 1))
no_half(x::Int64) = x * 3 + 1
add_half(x::Int64) = Float64(half(x) + half(x + 1))
min_half(x::Int64) = Float64(Core.Intrinsics.min_float(half(x), half(x + 1)))
end

# LLVM's expandRoundInexactToOdd (TargetLowering.cpp:13491) of a double to an f32, as src/intrinsics.jl emits it
# before float_to_half: the f32 kept where exact, odd or NaN, else its odd neighbour away from it
function round_inexact_to_odd(x::Float64)::Float32
    local n = Float32(x)
    local nb = reinterpret(UInt32, n)
    local keep = !(x < Float64(n) || x > Float64(n)) || (nb & 0x1) != 0
    return keep ? n : reinterpret(Float32, nb + (abs(x) > abs(Float64(n)) ? UInt32(1) : typemax(UInt32)))
end

@testset "julia_half_to_float and julia_float_to_half are runtime_intrinsics.c's, and answer as native, natively" begin
    # each port against the libjulia routine it ports (runtime_intrinsics.c:253 julia_half_to_float, :247
    # julia_float_to_half), at every half and at every float rounding boundary of a half
    @test all(u -> reinterpret(UInt32, W.julia_half_to_float(u)) === reinterpret(UInt32, ccall(:julia_half_to_float, Float32, (UInt16,), u)), UInt16(0):typemax(UInt16))
    local f32s = [reinterpret(Float32, (UInt32(u) << 13) | d) for u in UInt32(0):UInt32(1 << 19 - 1) for d in Cases.F32_LOW]
    @test all(f -> W.julia_float_to_half(f) === ccall(:julia_float_to_half, UInt16, (Float32,), f), f32s)
    # and each the value native Julia's Float16 conversions give, NaNs by their bits
    @test all(u -> reinterpret(UInt32, W.julia_half_to_float(u)) === reinterpret(UInt32, Float32(reinterpret(Float16, u))), UInt16(0):typemax(UInt16))
    @test all(f -> W.julia_float_to_half(f) === reinterpret(UInt16, Float16(f)), f32s)
    # a double: rounded inexact-to-odd to an f32, then float_to_half, is the correctly rounded half at every
    # boundary (Cases.rounded), where libjulia's julia_double_to_half (runtime_intrinsics.c:190) is not at every one
    local f64s = [reinterpret(Float64, (s << 63) | (UInt64(e) << 52) | (m << 42) | d) for s in UInt64(0):UInt64(1) for e in 950:1100
                  for m in UInt64(0):UInt64(1023) for d in Cases.F64_LOW]
    append!(f64s, [reinterpret(Float64, (s << 63) | (UInt64(e) << 52) | m) for s in UInt64(0):UInt64(1) for e in (0, 1, 900, 2046, 2047)
                   for m in (UInt64(0), UInt64(1), UInt64(1) << 51, (UInt64(1) << 52) - 1, UInt64(0x5555) << 30)])
    @test all(x -> W.julia_float_to_half(round_inexact_to_odd(x)) === reinterpret(UInt16, Cases.rounded(x)), f64s)
    # on aarch64, whose native Float16(::Float64) is the hardware's conversion, native is that IEEE rounding at every
    # sampled double, so there native, the IEEE answer and the port agree (x86_64's is libjulia's double_to_half)
    Sys.ARCH === :aarch64 && @test all(x -> Cases.rounded(x) === Float16(x), f64s)
end

@testset "the half routines are in a closed world where an intrinsic on a Float16 reaches them, none in any other" begin
    local held(f) = (local w = W.build_nir(W.check_subset(f, (Int64,), "float16_half", Base.get_world_counter()), "float16_half");
                     Set(b.ci.def.def.name for b in w))
    @test :julia_half_to_float in held(Cases.ext32) && :julia_float_to_half in held(Cases.ext32)
    @test !(:julia_half_to_float in held(Cases.no_half)) && !(:julia_float_to_half in held(Cases.no_half))
end

@testset "a soft-promoted half compiled answers as native Julia, bit for bit" begin
    local runs = Main.WTChild.RunCase[]
    for (name, f, ks) in (("ext32", Cases.ext32, 0:15), ("ext64", Cases.ext64, 0:15), ("trunc32", Cases.trunc32, 0:15),
                          ("trunc64", Cases.trunc64, 0:50), ("trunc64_special", Cases.trunc64_special, 0:3),
                          ("binary", Cases.binary, 0:15), ("unary", Cases.unary, 0:15), ("ints", Cases.ints, 0:40),
                          ("held", Cases.held, 0:3))
        local bytes = W.compile(f, (Int64,))
        # a double's truncation against the IEEE rounding (Cases.rounded), any other case against native
        local expected(k) = f === Cases.trunc64 ? Cases.trunc64_ieee(Int64(k)) : f === Cases.trunc64_special ? Cases.trunc64_special_ieee(Int64(k)) :
                            Main.WTChild.native_answer(f, (Int64(k),))
        append!(runs, [Main.WTChild.RunCase("$name($k)", bytes, (Int64(k),), expected(k)) for k in ks])
    end
    local results = Main.WTChild.run_cases(runs)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == length(runs) && all(r -> r.ok, results)
end

@testset "an intrinsic on a Float16 the port leaves out rejects at its statement, located" begin
    local e = try; W.compile(Cases.rem_half, (Int64,)); nothing; catch err; err isa W.RejectionError ? err : rethrow(); end
    @test e !== nothing && occursin("rem_float", sprint(show, e.rejection))
    # an add's operands are extended by compiler-rt's __extendhfsf2, not ported (no file of the LLVM pin's checkout)
    local a = try; W.compile(Cases.add_half, (Int64,)); nothing; catch err; err isa W.RejectionError ? err : rethrow(); end
    @test a !== nothing && a.rejection isa W.Unquarantined && occursin("add_float on a Float16, whose operands LLVM extends by compiler-rt's __extendhfsf2", a.rejection.row)
    # min_float's f32 operation answers wasm's canonical NaN where native propagates a payload
    local m = try; W.compile(Cases.min_half, (Int64,)); nothing; catch err; err isa W.RejectionError ? err : rethrow(); end
    @test m !== nothing && m.rejection isa W.Unquarantined && occursin("min_float on a Float16", m.rejection.row)
end

end
