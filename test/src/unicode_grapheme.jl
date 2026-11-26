# Base's grapheme breaks by overlay (src/patch/unicode.jl): utf8proc's grapheme_break_simple, grapheme_break_extended,
# utf8proc_grapheme_break_stateful and utf8proc_grapheme_break over the boundclass and indic_conjunct_break columns
# of its property table, copied from the pinned utf8proc_data.c. The columns equal the pinned file's, entry for
# entry, read again here; the overlays answer as Base's isgraphemebreak and isgraphemebreak!, which call libjulia's
# utf8proc, natively, at every pair of the table's (boundclass, indic_conjunct_break) kinds from every state three
# code points reach, and over every code point after a few; and compiled, the cases answer as native Julia, their
# closed world reaching the port, never the foreigncall.
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module GraphemeCases
# one stateful step from a state: its break in bit 0, the state it leaves above it
function step(a::Int64, b::Int64, s::Int64)::Int64
    local r = Ref{Int32}(Int32(s))
    local br = Base.Unicode.isgraphemebreak!(r, Char(a), Char(b))
    return Int64(br) + 2 * Int64(r[])
end
brk(a::Int64, b::Int64) = Base.Unicode.isgraphemebreak(Char(a), Char(b)) ? 1 : 0
# a malformed character resets the state and breaks
malformed(s::Int64) = (r = Ref{Int32}(Int32(s)); br = Base.Unicode.isgraphemebreak!(r, reinterpret(Char, 0xff000000), 'a'); Int64(br) + 2 * Int64(r[]))
# emoji ZWJ sequences with modifiers, regional indicators, Indic conjuncts (GB9c), Hangul syllables and jamo, CR LF,
# prepend and spacing marks: each string's grapheme count, and the bits of its breaks
const _S1 = "e\u0301a\U1F1FA\U1F1F8x\U1F468\u200d\U1F469\u200d\U1F467\u200d\U1F466!\U1F44D\U1F3FD"
const _S2 = "\U1F1FA\U1F1F8\U1F1EB\U1F1F7\U1F1E9\U1F1EA\U1F1EF"
const _S3 = "\u0915\u094d\u0937\u093f \u0915\u094d\u200d\u0937 \u0915\u094d\u094d\u0937 \u0915\u093c\u094d\u0924"
const _S4 = "\ud55c\uad6d\uc5b4\u1100\u1161\u11a8\u1100\u1100\uac00\u11a8"
const _S5 = "a\r\nb\n\r\u0600x\u0903\u200dy\u263a\u200d\u263a"
_str(i::Int64) = i == 1 ? _S1 : i == 2 ? _S2 : i == 3 ? _S3 : i == 4 ? _S4 : _S5
ngraph(i::Int64) = length(Base.Unicode.graphemes(_str(i)))
function breaks(i::Int64)::Int64
    local state = Ref{Int32}(0)
    local c0 = '\0'
    local bits, k = Int64(0), 0
    for c in _str(i)
        bits |= Int64(Base.Unicode.isgraphemebreak!(state, c0, c)) << (k % 63)
        c0 = c
        k += 1
    end
    return bits
end
end

# the pinned utf8proc_data.c's property lines, each its fields
function pinned_property_fields(dir::String)::Vector{Vector{String}}
    local lines = readlines(joinpath(dir, "utf8proc_data.c"))
    local p = findfirst(==("static const utf8proc_property_t utf8proc_properties[] = {"), lines)
    @test p !== nothing
    local out = Vector{String}[]
    for l in lines[p + 1:end]
        l == "};" && break
        @test startswith(l, "  {") && endswith(l, "},")
        push!(out, String.(strip.(split(l[4:end-2], ','))))
    end
    return out
end

@testset "the boundclass and indic_conjunct_break columns are the pinned file's, entry for entry" begin
    local dir = WasmTarget._c_pin_checkout(:utf8proc)
    @test dir !== nothing   # bash dev/fetch_julia.sh makes it, at the commit julia/deps/utf8proc.version names
    if dir !== nothing
        local h = read(joinpath(dir, "utf8proc.h"), String)
        local enum = Dict(m[1] => parse(Int, m[2]) for m in eachmatch(r"(UTF8PROC_(?:BOUNDCLASS|INDIC_CONJUNCT_BREAK)_[A-Z_]+)\s*=\s*(\d+)", h))
        # each constant the port names holds its enum value
        for (k, v) in enum
            isdefined(WasmTarget, Symbol(k)) && @test getfield(WasmTarget, Symbol(k)) === Int32(v)
        end
        @test count(k -> isdefined(WasmTarget, Symbol(k)), keys(enum)) == 21
        local rows = pinned_property_fields(dir)
        @test all(r -> length(r) == 21, rows)
        @test length(rows) == length(WasmTarget.UTF8PROC_PROPERTIES_CATEGORY)
        @test [UInt8(enum[r[20]]) for r in rows] == WasmTarget.UTF8PROC_PROPERTIES_BOUNDCLASS
        @test [UInt8(enum[r[21]]) for r in rows] == WasmTarget.UTF8PROC_PROPERTIES_INDIC_CONJUNCT_BREAK
    end
end

const _OV = Base.MethodList(WasmTarget.METHOD_TABLE).ms
const _M_STATEFUL = only(filter(m -> m.name === :isgraphemebreak!, _OV))
const _M_STATELESS = only(filter(m -> m.name === :isgraphemebreak, _OV))
ov!(r, a, b) = invoke(Base.Unicode.isgraphemebreak!, _M_STATEFUL, r, a, b)
ov(a, b) = invoke(Base.Unicode.isgraphemebreak, _M_STATELESS, a, b)

# one code point of each (boundclass, indic_conjunct_break) kind the table holds, its first
function kinds()::Vector{Char}
    local seen = Dict{Tuple{UInt8,UInt8},Char}()
    for u in UInt32(0):UInt32(0x10ffff)
        0xd800 <= u <= 0xdfff && continue
        local p = WasmTarget.utf8proc_get_property(reinterpret(Int32, u)) + 1
        get!(seen, (WasmTarget.UTF8PROC_PROPERTIES_BOUNDCLASS[p], WasmTarget.UTF8PROC_PROPERTIES_INDIC_CONJUNCT_BREAK[p]), Char(u))
    end
    return sort!(collect(values(seen)))
end
const KINDS = kinds()

@testset "the overlays answer as Base's isgraphemebreak and isgraphemebreak!, natively" begin
    @test length(KINDS) >= 18
    local bad = Any[]
    # without state, every pair of kinds, and every code point after a few
    for a in KINDS, b in KINDS
        ov(a, b) === Base.Unicode.isgraphemebreak(a, b) || push!(bad, (a, b))
    end
    for a in ('a', '\u200d', '\U1F1FA', '\u0915', '\r'), u in UInt32(0):UInt32(0x10ffff)
        0xd800 <= u <= 0xdfff && continue
        ov(a, Char(u)) === Base.Unicode.isgraphemebreak(a, Char(u)) || push!(bad, (a, u))
    end
    # with state: every sequence of three kinds from state 0, each step's break and the state it leaves
    for a in KINDS, b in KINDS, c in KINDS
        local r1, r2 = Ref{Int32}(0), Ref{Int32}(0)
        for (x, y) in ((a, b), (b, c))
            (ov!(r1, x, y) === Base.Unicode.isgraphemebreak!(r2, x, y) && r1[] === r2[]) || push!(bad, (a, b, c))
        end
    end
    # malformed characters and states no sequence reaches (C reads any int32's bytes)
    for s in Int32[0, 1, 0x105, 0x214, 0x313, 0x7fff_ffff, -1], (x, y) in ((reinterpret(Char, 0xff000000), 'a'), ('a', '\u0301'), ('\u0915', '\u0937'))
        local r1, r2 = Ref{Int32}(s), Ref{Int32}(s)
        (ov!(r1, x, y) === Base.Unicode.isgraphemebreak!(r2, x, y) && r1[] === r2[]) || push!(bad, (s, x, y))
    end
    @test isempty(bad)
end

@testset "the grapheme breaks compiled answer as native Julia" begin
    local runs = Main.WTChild.RunCase[]
    local codes = Int64.(codepoint.(KINDS))
    local f = GraphemeCases.step
    local bytes = WasmTarget.compile(f, (Int64, Int64, Int64))
    for a in codes, b in codes, s in (Int64(0), Int64(0x214))
        push!(runs, Main.WTChild.RunCase("step($a,$b,$s)", bytes, (a, b, s), Main.WTChild.native_answer(f, (a, b, s))))
    end
    local bytes2 = WasmTarget.compile(GraphemeCases.brk, (Int64, Int64))
    for a in codes, b in codes
        push!(runs, Main.WTChild.RunCase("brk($a,$b)", bytes2, (a, b), Main.WTChild.native_answer(GraphemeCases.brk, (a, b))))
    end
    for (name, g, args) in (("malformed", GraphemeCases.malformed, (Int64(0x105),)),
                            (("ngraph", GraphemeCases.ngraph, (Int64(i),)) for i in 1:5)...,
                            (("breaks", GraphemeCases.breaks, (Int64(i),)) for i in 1:5)...)
        append!(runs, first(Main.WTChild.answer_cases("unicode_grapheme/$name$args", WasmTarget.compile, g, args)))
    end
    local results = Main.WTChild.run_cases(runs)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == length(runs) && all(r -> r.ok, results)
end

# an overlay hides every method its signature covers (Compiler/src/methodtable.jl:73): each grapheme overlay covers
# only Base's method of its own signature
@testset "the grapheme overlays hide no other method" begin
    for (f, m) in ((Base.Unicode.isgraphemebreak!, _M_STATEFUL), (Base.Unicode.isgraphemebreak, _M_STATELESS))
        @test only(methods(f)).sig == m.sig
    end
end
