# Base's Unicode category by overlay (src/patch/unicode.jl): utf8proc's lookup over its tables, copied
# from the pinned utf8proc_data.c. Its tables equal the pinned file's, entry for entry, read again here
# (the guard against a table regenerated or edited); its lookup answers as Base's category_code, which
# calls libjulia's utf8proc, at every code point, natively; and a sample compiled and run answers as
# native Julia, its closed world reaching the port, never the foreigncall.
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module UnicodeCases
cat(x::Int64) = Int64(Base.Unicode.category_code(x))              # a code point's category, and 30 past 0x10ffff
letter(x::Int64) = isletter(Char(x))                                # Lu..Lo, Base's isletter of a Char
space(x::Int64) = isspace(Char(x))                                  # Base's isspace, Zs at or above '\ua0'
strip3(n::Int64) = ncodeunits(strip(n > 0 ? "  a　b ﻿ " : " x\t"))   # strip of Unicode space
end

# the pinned utf8proc_data.c's table `decl`, its entries in order, each token as it stands
function pinned_entries(lines::Vector{String}, decl::String)::Vector{String}
    local i = findfirst(==(decl), lines)
    @test i !== nothing
    local out = String[]
    while true
        i += 1
        local l = lines[i]
        append!(out, filter(!isempty, strip.(split(replace(l, "};" => ""), ','))))
        endswith(rstrip(l), "};") && return out
    end
end

@testset "utf8proc's tables are the pinned file's, entry for entry" begin
    local dir = WasmTarget._c_pin_checkout(:utf8proc)
    @test dir !== nothing   # bash dev/fetch_julia.sh makes it, at the commit julia/deps/utf8proc.version names
    if dir !== nothing
        local lines = readlines(joinpath(dir, "utf8proc_data.c"))
        local s1 = pinned_entries(lines, "static const utf8proc_uint16_t utf8proc_stage1table[] = {")
        local s2 = pinned_entries(lines, "static const utf8proc_uint16_t utf8proc_stage2table[] = {")
        @test length(s1) == length(WasmTarget.UTF8PROC_STAGE1TABLE) == 0x110000 >> 8
        @test parse.(UInt16, s1) == WasmTarget.UTF8PROC_STAGE1TABLE
        @test length(s2) == length(WasmTarget.UTF8PROC_STAGE2TABLE)
        @test parse.(UInt16, s2) == WasmTarget.UTF8PROC_STAGE2TABLE
        # each property's first field, its category: 0 or a utf8proc_category_t name, its value read from
        # the pinned utf8proc.h's enum, which Base.Unicode's constant of that name holds too
        local enum = Dict(m[1] => parse(Int16, m[2]) for m in
                          eachmatch(r"(UTF8PROC_CATEGORY_[A-Z]{2})\s*=\s*(\d+)", read(joinpath(dir, "utf8proc.h"), String)))
        @test length(enum) == 30 && all(k -> getfield(Base.Unicode, Symbol(k)) == enum[k], keys(enum))
        local p = findfirst(==("static const utf8proc_property_t utf8proc_properties[] = {"), lines)
        local cats = Int16[]
        local unread = String[]   # a property line whose first field is no category this reads
        for l in lines[p + 1:end]
            l == "};" && break
            local m = match(r"^  \{([A-Z0-9_]+),", l)
            m === nothing || !(m[1] == "0" || haskey(enum, m[1])) ? push!(unread, l) : push!(cats, m[1] == "0" ? Int16(0) : enum[m[1]])
        end
        @test isempty(unread)
        @test cats == WasmTarget.UTF8PROC_PROPERTIES_CATEGORY
        # every stage-2 entry indexes the property table, every stage-1 offset a full block of stage 2
        @test maximum(WasmTarget.UTF8PROC_STAGE2TABLE) < length(cats)
        @test maximum(WasmTarget.UTF8PROC_STAGE1TABLE) + 256 <= length(s2)
    end
end

@testset "the overlay answers as Base's category_code at every code point, natively" begin
    # the overlay's own method, called natively (invoke of a Method), against Base's, which calls libjulia's utf8proc
    local m = only(filter(m -> m.name === :category_code, Base.MethodList(WasmTarget.METHOD_TABLE).ms))
    local bad = UInt32[]
    for x in UInt32(0):UInt32(0x10ffff)
        invoke(Base.Unicode.category_code, m, x) === Base.Unicode.category_code(x) || push!(bad, x)
    end
    @test isempty(bad)
    for x in (0x110000, typemax(UInt32), Int64(0x10ffff), Int8(65), true)
        @test invoke(Base.Unicode.category_code, m, x) === Base.Unicode.category_code(x)
    end
    @test_throws InexactError invoke(Base.Unicode.category_code, m, -1)
    @test_throws InexactError Base.Unicode.category_code(-1)
end

# code points of every kind: ASCII, Latin-1's and Unicode's spaces and line and paragraph separators,
# the BOM, CJK, surrogates, private use, astral letters, the last code point and past it; and a stride
const SAMPLE = sort!(unique!(vcat(Int64[0, 9, 0x20, 0x41, 0x61, 0x7f, 0xa0, 0xaa, 0xd7, 0x370, 0x3b1, 0x1680, 0x2000,
    0x200b, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0x3042, 0x4e2d, 0xd800, 0xdfff, 0xe000, 0xfeff, 0xfffd, 0x10400,
    0x1d400, 0x1f600, 0x20000, 0xe0001, 0xf0000, 0x10fffd, 0x10ffff, 0x110000], collect(Int64, 0:0x1013:0x10ffff))))

@testset "category_code compiled answers as native Julia" begin
    local runs = Main.WTChild.RunCase[]
    for (name, f, xs) in (("cat", UnicodeCases.cat, SAMPLE), ("letter", UnicodeCases.letter, filter(x -> x <= 0x10ffff, SAMPLE)),
                          ("space", UnicodeCases.space, filter(x -> x <= 0x10ffff, SAMPLE)))
        local bytes = WasmTarget.compile(f, (Int64,))
        append!(runs, [Main.WTChild.RunCase("$name($x)", bytes, (x,), Main.WTChild.native_answer(f, (x,))) for x in xs])
    end
    for (name, f, args) in (("strip3", UnicodeCases.strip3, (Int64(1),)), ("strip3", UnicodeCases.strip3, (Int64(0),)))
        append!(runs, first(Main.WTChild.answer_cases("unicode/$name$args", WasmTarget.compile, f, args)))
    end
    local results = Main.WTChild.run_cases(runs)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == length(runs) && all(r -> r.ok, results)
end

# isletter's module reads utf8proc's own stage-2 table, never a foreigncall into libjulia: translated as
# WasmTarget.compile translates (standalone), its one data segment is that table's 46,592 entries, little-endian
# (constants.dart's data-initialised i16 array, src/constants.jl _make_wasm_array_literal)
@testset "isletter's module holds utf8proc's stage-2 table as its data segment" begin
    local D = WasmTarget.Dart2Wasm
    local t = D.Translator(WasmTarget.build_nir(WasmTarget.check_subset(UnicodeCases.letter, (Int64,), "unicode", Base.get_world_counter()), "unicode"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions(; standalone = true))
    D.translate(t, nothing)
    local seg = only(values(t.constants[]._byte_segments))
    @test seg.content == Vector{UInt8}(reinterpret(UInt8, htol.(WasmTarget.UTF8PROC_STAGE2TABLE)))
end
