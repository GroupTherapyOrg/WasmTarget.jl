# Base's case mappings, character width, case predicates and identifier-character predicates by overlay
# (src/patch/unicode.jl): utf8proc's utf8proc_tolower, utf8proc_toupper, utf8proc_totitle, utf8proc_charwidth,
# utf8proc_islower and utf8proc_isupper over the property columns and the sequence table copied from the pinned
# utf8proc_data.c, and julia_extensions.c's jl_id_start_char and jl_id_char over utf8proc's category. The
# tables equal the pinned file's, entry for entry, read again here; each overlay answers as Base's, which calls
# libjulia, at every code point, natively; no overlay covers a more specific method it does not hold; and a sample compiled and run answers as native Julia, its closed world reaching the ports.
module UnicodeCaseTest
using Test, WasmTarget
const W = WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module Cases
lower(x::Int64) = Int64(UInt32(lowercase(Char(x))))
upper(x::Int64) = Int64(UInt32(uppercase(Char(x))))
title(x::Int64) = Int64(UInt32(titlecase(Char(x))))
width(x::Int64) = Int64(textwidth(Char(x)))
cased(x::Int64) = Int64(islowercase(Char(x))) + 2 * Int64(isuppercase(Char(x)))
ident(x::Int64) = Int64(Base.is_id_start_char(Char(x))) + 2 * Int64(Base.is_id_char(Char(x)))
# a String's case mapping, each character's: the bytes of the result and its length
upstr(x::Int64) = (s = uppercase(x > 0 ? "straße λǆ ﬀ" : "x"); Int64(sum(codeunits(s))) * 1000 + ncodeunits(s))
lowstr(x::Int64) = (s = lowercase(x > 0 ? "ΣΑΣ ǅ İ" : "X"); Int64(sum(codeunits(s))) * 1000 + ncodeunits(s))
end

include(joinpath(@__DIR__, "..", "pinned_tables.jl"))

@testset "utf8proc's sequence table and property columns are the pinned file's, entry for entry" begin
    local dir = W._c_pin_checkout(:utf8proc)
    @test dir !== nothing   # bash dev/fetch_julia.sh makes it, at the commit julia/deps/utf8proc.version names
    if dir !== nothing
        local lines = readlines(joinpath(dir, "utf8proc_data.c"))
        local seq = pinned_entries(lines, "static const utf8proc_uint16_t utf8proc_sequences[] = {")
        @test parse.(UInt16, seq) == W.UTF8PROC_SEQUENCES
        # each property entry's fields: utf8proc.h's utf8proc_property_t, 21 of them in every entry
        local p = findfirst(==("static const utf8proc_property_t utf8proc_properties[] = {"), lines)
        local rows = Vector{String}[]
        for l in lines[p + 1:end]
            l == "};" && break
            local m = match(r"^  \{(.*)\},$", l)
            @test m !== nothing
            m === nothing || push!(rows, String.(strip.(split(m[1], ','))))
        end
        @test all(r -> length(r) == 21, rows)
        @test length(rows) == length(W.UTF8PROC_PROPERTIES_CATEGORY)
        local u16(t) = t == "UINT16_MAX" ? typemax(UInt16) : parse(UInt16, t)
        # utf8proc.h:255-257 uppercase_seqindex, lowercase_seqindex, titlecase_seqindex: fields 7, 8, 9;
        # utf8proc.h:306 charwidth: field 17
        @test [u16(r[7]) for r in rows] == W.UTF8PROC_PROPERTIES_UPPERCASE_SEQINDEX
        @test [u16(r[8]) for r in rows] == W.UTF8PROC_PROPERTIES_LOWERCASE_SEQINDEX
        @test [u16(r[9]) for r in rows] == W.UTF8PROC_PROPERTIES_TITLECASE_SEQINDEX
        @test [parse(UInt8, r[17]) for r in rows] == W.UTF8PROC_PROPERTIES_CHARWIDTH
        # every mapping indexes the sequence table
        for col in (W.UTF8PROC_PROPERTIES_UPPERCASE_SEQINDEX, W.UTF8PROC_PROPERTIES_LOWERCASE_SEQINDEX, W.UTF8PROC_PROPERTIES_TITLECASE_SEQINDEX)
            @test maximum(filter(!=(typemax(UInt16)), col)) < length(W.UTF8PROC_SEQUENCES)
        end
    end
end

# the overlay of `f` whose signature is `sig`, a method of WasmTarget's table
overlay(f, sig) = only(filter(m -> m.sig == sig, Base.MethodList(W.METHOD_TABLE).ms))

@testset "each overlay holds every Base method its signature covers" begin
    local world = Base.get_world_counter()
    for (f, A) in ((lowercase, AbstractChar), (uppercase, AbstractChar), (titlecase, AbstractChar), (textwidth, Char),
                   (islowercase, AbstractChar), (isuppercase, AbstractChar), (Base.is_id_start_char, AbstractChar),
                   (Base.is_id_char, AbstractChar))
        # Base's methods a call of f on any A may reach, each covered by an overlay of f whose signature it is
        local base = [m.method for m in Base._methods_by_ftype(Tuple{typeof(f),A}, -1, world)]
        local ours = filter(m -> m.sig <: Tuple{typeof(f),Any}, Base.MethodList(W.METHOD_TABLE).ms)
        @test !isempty(ours)
        for m in base
            any(o -> m.sig <: o.sig, ours) || continue
            @test any(o -> o.sig == m.sig, ours)
        end
    end
end

@testset "each overlay answers as Base's at every code point, natively" begin
    local ms = (lowercase => overlay(lowercase, Tuple{typeof(lowercase),Char}), uppercase => overlay(uppercase, Tuple{typeof(uppercase),Char}),
                titlecase => overlay(titlecase, Tuple{typeof(titlecase),Char}), textwidth => overlay(textwidth, Tuple{typeof(textwidth),Char}),
                islowercase => overlay(islowercase, Tuple{typeof(islowercase),AbstractChar}),
                isuppercase => overlay(isuppercase, Tuple{typeof(isuppercase),AbstractChar}),
                Base.is_id_start_char => overlay(Base.is_id_start_char, Tuple{typeof(Base.is_id_start_char),AbstractChar}),
                Base.is_id_char => overlay(Base.is_id_char, Tuple{typeof(Base.is_id_char),AbstractChar}))
    for (f, m) in ms
        local bad = UInt32[]
        for u in UInt32(0):UInt32(0x10ffff)
            local c = Char(u)
            invoke(f, m, c) === f(c) || push!(bad, u)
        end
        @test isempty(bad)
        # past U+10FFFF, and malformed and overlong characters: the same answer, or the same error
        for c in (Char(0x110000), Char(0x1fffff), reinterpret(Char, 0xc0800000), reinterpret(Char, 0xe0800000),
                  reinterpret(Char, 0xff000000), reinterpret(Char, 0xce000000))
            local a = try; invoke(f, m, c); catch e; typeof(e); end
            local b = try; f(c); catch e; typeof(e); end
            @test a === b
        end
    end
    # the case mappings are overlaid for a Char alone: an AnnotatedChar's method, Base's, and LinearAlgebra's
    # WrapperChar's stay theirs, never covered
    for f in (lowercase, uppercase, titlecase)
        @test [m.sig for m in Base.MethodList(W.METHOD_TABLE).ms if m.sig <: Tuple{typeof(f),Any}] == [Tuple{typeof(f),Char}]
    end
end

# code points of every kind: ASCII, Latin-1, Greek, the digraphs and their titlecase, the sharp s and its capital,
# Cherokee, Glagolitic and Deseret (a mapping past U+FFFF, two surrogate entries), wide CJK and emoji, combining
# marks, zero-width and control characters, the identifier exceptions (arrows, primes, math, U+1F8B2), surrogates,
# private use, the last code point and past it; and a stride
const SAMPLE = sort!(unique!(vcat(Int64[0, 9, 0x1f, 0x20, 0x21, 0x30, 0x41, 0x5f, 0x61, 0x7f, 0xa0, 0xa1, 0xa6, 0xb5, 0xdf, 0xff,
    0x130, 0x131, 0x1c4, 0x1c5, 0x1c6, 0x1f0, 0x300, 0x345, 0x390, 0x3a3, 0x3c2, 0x3c3, 0x1e9e, 0x13a0, 0xab70, 0x2c00,
    0x2190, 0x2118, 0x2202, 0x2032, 0x2057, 0x207a, 0x208e, 0x2220, 0x233f, 0x4e2d, 0xac00, 0xfb00, 0xfffc, 0xfffd,
    0xd800, 0xdfff, 0xe000, 0xff21, 0x10400, 0x10428, 0x1d6c1, 0x1d7ce, 0x1f600, 0x1f8b2, 0x200b, 0x20000, 0xe0001,
    0x10fffd, 0x10ffff, 0x110000], collect(Int64, 0:0x2027:0x10ffff))))

@testset "the ports compiled answer as native Julia" begin
    local runs = Main.WTChild.RunCase[]
    for (name, f) in (("lower", Cases.lower), ("upper", Cases.upper), ("title", Cases.title), ("width", Cases.width),
                      ("cased", Cases.cased), ("ident", Cases.ident))
        local bytes = W.compile(f, (Int64,))
        append!(runs, [Main.WTChild.RunCase("$name($x)", bytes, (x,), Main.WTChild.native_answer(f, (x,))) for x in SAMPLE])
    end
    for (name, f) in (("upstr", Cases.upstr), ("lowstr", Cases.lowstr)), x in (Int64(1), Int64(0))
        append!(runs, first(Main.WTChild.answer_cases("unicode_case/$name($x)", W.compile, f, (x,))))
    end
    local results = Main.WTChild.run_cases(runs)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == length(runs) && all(r -> r.ok, results)
end

end
