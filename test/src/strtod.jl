# Base's parse of a Float64 or a Float32 by overlay (src/patch/strtod.jl): jl_try_substrtod and jl_try_substrtof
# over Julia's portable jl_strtod_c, its digits converted by LLVM's APFloat. Each overlay answers as Base's, which
# calls the host libc's strtod_l, natively, bit for bit (=== on the value, nothing alike): every example of Base's
# own parse tests (julia/test/parse.jl), the syntax's edges (space, signs, inf and nan spellings, hexadecimal
# floats, exponents with no digits, overflow and underflow, denormals, ties at the precision's boundary) and
# random decimal and hexadecimal strings, each also inside a SubString with bytes around it; a NaN's n-char-
# sequence payload, the host's, raises, named; and a sample compiled and run answers as native Julia.
module StrtodTest
using Test, Random, WasmTarget
const W = WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

# julia/test/parse.jl's examples: the values with space before and after, .5, "1.23", "12", inf and nan in both
# cases with signs and spaces, the complex parse's parts
const BASE_EXAMPLES = vcat(
    [string(b, v, a) for v in (0.05, -0.05, 2.5, -2.5) for (b, a) in (("    ", ""), ("    ", "\n"), ("", "    "), ("    ", "    "))],
    ["    .5", "    .5\n", "    .5    ", ".5    ", "1.23", "12", "1e-3", "-1e-9", "1.0", "-1.0", "0.0"],
    [case(string(sb, sign, vs, sa)) for vs in ("nan", "inf", "infinity") for sb in ("", "  ") for sa in ("", "  ")
                                    for sign in ("", "-") for case in (lowercase, uppercase)])

# the syntax's and the rounding's edges
const EDGES = [
    "", " ", "\t\n\v\f\r", "+", "-", ".", "e5", ".e5", "1e", "1e+", "1e-", "1E5", "1e+5", "1e-5", "1.", ".1", "+.1", "-.1",
    "1.2.3", "+-1", "-+1", "--1", "1_000", "1 x", "1 ", " 1", "1\0", "1,", "1x", "0", "-0", "+0", "00", "-0.0e0", "0e999999",
    "0x", "0x.", "0xg", "0x1", "0x1p3", "0x1P-3", "0x1.8p1", "0x1.8", "0x.8", "0x.8p1", "0xp1", "0x1p", "0x1p+", "0X1A",
    "-0x1p-1074", "0x1p-1075", "0x1.0000000000000p-1074", "0x1.fffffffffffff8p0", "0x1.00000000000008p0", "0x1.00000000000018p0",
    "0x1.fffffffffffffp1023", "0x1.fffffffffffff8p1023", "0x1p1024", "0x1p-1076", "0x.0000000000001p-1022", "0x123456789abcdef0123p0",
    "inf", "infinit", "infinityx", "INFiNiTy", "-iNf", "+inf", "nan", "-nan", "+NaN", "nan()", "nan(", "nan(x", "nana", "in", "na",
    "1e308", "1.7976931348623157e308", "1.7976931348623158e308", "1.7976931348623159e308", "1e309", "-1e309", "1e400", "-1e400",
    "1e-400", "-1e-400", "5e-324", "4.9406564584124654e-324", "2.4703282292062327e-324", "2.4703282292062328e-324", "3e-324",
    "2.2250738585072011e-308", "2.2250738585072014e-308", "2.225073858507201e-308", "1e-320", "123e-330",
    "9007199254740992", "9007199254740993", "9007199254740994", "9007199254740995", "9007199254740993.0000000000000000001",
    "0.1", "0.2", "0.3", "0.30000000000000004", "3.141592653589793", "2.718281828459045", "1e23", "8.589973e9", "1e22",
    "123456789012345678901234567890", "0.000000000000000000000000000000000000000001", "1" * "0"^400, "0." * "0"^400 * "1",
    "1" * "0"^400 * "e-400", "4.35679e-10", "1.448997445238699", "179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497791.9999999999999999999999999999999999999999999999999999999999999999999999",
    "3.4028234e38", "3.4028235e38", "3.4028236e38", "3.40282357e38", "3.4028236e+38", "1e39", "1.4e-45", "7e-46", "7.1e-46",
    "1e-46", "1.17549435e-38", "1.1754942e-38", "16777216", "16777217", "16777218", "16777219", "0x1.000001p0", "0x1.fffffep127",
    "0x1.ffffffp127", "0x1p128", "0x1p-149", "0x1p-150", "0x1.8p-150",
]

# random decimal and hexadecimal strings, seeded
function random_strings(n::Int)::Vector{String}
    local rng = Xoshiro(20261125)
    local out = String[]
    for _ in 1:n
        local k = rand(rng, 1:6)
        if k == 1
            push!(out, repr(reinterpret(Float64, rand(rng, UInt64))))
        elseif k == 2
            push!(out, string(rand(rng, ("", "-", "+")), rand(rng, '0':'9', rand(rng, 1:25))..., rand(rng, ("", ".")),
                              rand(rng, '0':'9', rand(rng, 0:25))..., "e", rand(rng, -340:320)))
        elseif k == 3
            push!(out, string(rand(rng, '1':'9'), rand(rng, '0':'9', rand(rng, 15:45))..., "e", rand(rng, -360:330)))
        elseif k == 4
            push!(out, string(rand(rng, ("", "-")), "0x", rand(rng, ['0':'9'; 'a':'f'], rand(rng, 1:20))..., rand(rng, ("", ".")),
                              rand(rng, ['0':'9'; 'a':'f'], rand(rng, 0:8))..., rand(rng, ("", "p$(rand(rng, -1100:1030))"))))
        elseif k == 5
            push!(out, repr(reinterpret(Float32, rand(rng, UInt32))))
        else
            # a halfway case: a double's midpoint to its successor, written exactly
            local x = reinterpret(Float64, rand(rng, UInt64) & 0x7fefffffffffffff)
            push!(out, string(BigFloat(x; precision = 128) + (BigFloat(nextfloat(x); precision = 128) - BigFloat(x; precision = 128)) / 2))
        end
    end
    return out
end

const SAMPLE = vcat(BASE_EXAMPLES, EDGES, random_strings(4000))

# the overlay of `f` whose signature is `sig`
overlay(sig) = only(filter(m -> m.sig == sig, Base.MethodList(W.METHOD_TABLE).ms))

# an answer as a value or its error's type
answer(g) = try; g(); catch e; typeof(e); end

@testset "each overlay answers as Base's, bit for bit, natively" begin
    for T in (Float64, Float32)
        local m_s = overlay(Tuple{typeof(tryparse),Type{T},String})
        local m_ss = overlay(Tuple{typeof(tryparse),Type{T},SubString{String}})
        local m_i = overlay(Tuple{typeof(Base.tryparse_internal),Type{T},String,Int,Int})
        local m_is = overlay(Tuple{typeof(Base.tryparse_internal),Type{T},SubString{String},Int,Int})
        local bad = String[]
        for s in SAMPLE
            answer(() -> invoke(tryparse, m_s, T, s)) === answer(() -> tryparse(T, s)) || push!(bad, "String $(repr(s))")
            # inside a SubString with bytes around it that could continue a number, or that end it
            for (b, a) in (("x", "9"), ("9", ","), ("-", "e1"), ("", "x"))
                local whole = string(b, s, a)
                local sub = SubString(whole, ncodeunits(b) + 1, ncodeunits(b) + ncodeunits(s))   # every sample is ASCII
                answer(() -> invoke(tryparse, m_ss, T, sub)) === answer(() -> tryparse(T, sub)) || push!(bad, "SubString $(repr(sub)) of $(repr(whole))")
                isempty(s) && continue
                local i, e = ncodeunits(b) + 1, ncodeunits(b) + ncodeunits(s)
                answer(() -> invoke(Base.tryparse_internal, m_i, T, whole, i, e)) === answer(() -> Base.tryparse_internal(T, whole, i, e)) ||
                    push!(bad, "tryparse_internal $(repr(whole)) $i:$e")
                local ws = SubString(string("ab", whole, "cd"), 3, ncodeunits(whole) + 2)
                answer(() -> invoke(Base.tryparse_internal, m_is, T, ws, i, e)) === answer(() -> Base.tryparse_internal(T, ws, i, e)) ||
                    push!(bad, "tryparse_internal SubString $(repr(ws)) $i:$e")
            end
        end
        foreach(println, first(bad, 20))
        @test isempty(bad)
        @test length(SAMPLE) > 4000
    end
    # a NaN's n-char-sequence payload is the host's: the overlay raises, named, never a NaN of its own choosing
    for T in (Float64, Float32), s in ("nan(1)", "-nan(0x7)", "NAN(abc_9)")
        local err = try; invoke(tryparse, overlay(Tuple{typeof(tryparse),Type{T},String}), T, s); nothing; catch e; e; end
        @test err isa ErrorException && occursin("n-char-sequence", err.msg)
    end
end

@testset "each overlay holds every Base method its signature covers" begin
    local world = Base.get_world_counter()
    for f in (tryparse, Base.tryparse_internal), T in (Float64, Float32), S in (String, SubString{String})
        local sig = f === tryparse ? Tuple{typeof(f),Type{T},S} : Tuple{typeof(f),Type{T},S,Int,Int}
        local base = [m.method for m in Base._methods_by_ftype(sig, -1, world)]
        local ours = filter(m -> m.sig <: Tuple{typeof(f),Vararg{Any}}, Base.MethodList(W.METHOD_TABLE).ms)
        @test any(o -> o.sig == sig, ours)
        for m in base
            any(o -> m.sig <: o.sig, ours) && @test any(o -> o.sig == m.sig, ours)
        end
    end
end

module Cases
const STRS = ("1.23", "  -2.5\n", ".5", "1e-3", "-0", "0x1.8p1", "0x1.8", "inf", "-INFINITY", "nan", "-nan", "1e400", "1e-400",
              "5e-324", "2.4703282292062328e-324", "9007199254740993", "1.7976931348623159e308", "0.30000000000000004", "1 x", "",
              "abc", "1e", "3.4028236e38", "1.4e-45", "123456789012345678901234567890", "0." * "0"^60 * "17", "0x1p-1075", "nan()")
p64(i::Int64) = (v = tryparse(Float64, STRS[i]); v === nothing ? Int64(-1) : reinterpret(Int64, v))
p32(i::Int64) = (v = tryparse(Float32, STRS[i]); v === nothing ? Int64(-1) : Int64(reinterpret(Int32, v)))
psub(i::Int64) = (w = string("x", STRS[i], "9"); v = tryparse(Float64, SubString(w, 2, ncodeunits(w) - 1)); v === nothing ? Int64(-1) : reinterpret(Int64, v))
pparse(i::Int64) = (try; reinterpret(Int64, parse(Float64, STRS[i])); catch e; e isa ArgumentError ? Int64(-2) : Int64(-3); end)
end

@testset "the overlays compiled answer as native Julia" begin
    local runs = Main.WTChild.RunCase[]
    for (name, f) in (("p64", Cases.p64), ("p32", Cases.p32), ("psub", Cases.psub), ("pparse", Cases.pparse))
        local bytes = W.compile(f, (Int64,))
        append!(runs, [Main.WTChild.RunCase("$name($i)", bytes, (i,), Main.WTChild.native_answer(f, (i,))) for i in Int64(1):Int64(length(Cases.STRS))])
    end
    local results = Main.WTChild.run_cases(runs)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == length(runs) && all(r -> r.ok, results)
end

end
