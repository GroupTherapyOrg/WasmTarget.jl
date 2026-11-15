# Base's operator predicates by overlay (src/patch/unicode.jl): the femtolisp parser's operator? and syntactic-op?
# (julia/src/julia-parser.scm), which libjulia's jl_is_operator and jl_is_syntactic_operator answer (julia/src/ast.c:992,
# :1019), ported with the parser's tables. test/src/unicode.jl compares operator? over Strings; this file adds the
# syntactic list, Symbols, suffixes that are no suffix (not in opsuffs, no combining mark) and multi-codepoint names:
# each ported predicate against Julia's own ccall natively over every name of every table, each with and without a
# suffix, then both overlays in both modules against native.
module JuliaParserOpsTest
using Test, WasmTarget
const W = WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

native_op(s::String) = ccall(:jl_is_operator, Cint, (Cstring,), s)
native_syn(s::String) = ccall(:jl_is_syntactic_operator, Cint, (Cstring,), s)

module OpCases
# literal names, each a constant Symbol of the module: bit k set where the k-th name is an operator
const NAMES = (:+, :Int, :(=), Symbol("+′"), Symbol("=′"), Symbol(".+"), Symbol(".="), :in, :isa, Symbol("+₁"),
               Symbol("−"), Symbol("√"), Symbol("..."), Symbol("'"), Symbol(".'"), Symbol("->"), Symbol("<:"), :foo,
               Symbol(""), Symbol("+a"), Symbol("∈̂"), Symbol("⊕ˣ"), Symbol("&&"), Symbol(":="), Symbol("|>"))
ops(x::Int64)::Int64 = sum(Int64(Base._isoperator(NAMES[k])) << (k - 1) for k in 1:length(NAMES)) + x - x
syn(x::Int64)::Int64 = sum(Int64(Base.is_syntactic_operator(NAMES[k])) << (k - 1) for k in 1:length(NAMES)) + x - x
# a String built at run time, an operator or not by its bytes
str_op(x::Int64)::Int64 = Int64(Base._isoperator(string(Char(x), Char(x))))
# a String holding a NUL: Base's ArgumentError
function str_nul(x::Int64)::Int64
    try
        return Int64(Base._isoperator(string(Char(x), '\0')))
    catch e
        return e isa ArgumentError ? Int64(-1) : Int64(-2)
    end
end
end
const OC = OpCases

@testset "the parser's operator predicates, ported, against libjulia's" begin
    # every name of every table, its dotted and suffixed forms: a suffix of julia_opsuffs.h (′ ₁ ² ˣ), a combining mark
    # (category Mn, a suffix by its category), and characters that are no suffix (x, ä, a letter after a combining mark)
    local names = unique(vcat(W.PREC_NAMES..., W.UNARY_OPS, W.SYNTACTIC_OPERATORS, W.FL_NO_SUFFIX, W.FL_OPERATORS))
    local suffixes = ["", "′", "″", "₁", "²", "ˣ", "̂", "x", "ä", "̂x", "!", "1"]
    local words = ["", "in", "isa", "foo", "Int", "x′", "π", "∂", "∇x", "+a", "−x", "√x", ".", "..", "...", "'", ".'", "->",
                   "<:", ">:", "::", "\$", "\$=", "&", "∈̂", "a", "_", "⊕ˣ", "→̂", "🢲", "𝟎", "..=", "+=′", "=>′", "++′", "x=", ".x"]
    local cases = unique(vcat([n * s for n in names for s in suffixes], words, [s for s in suffixes]))
    @test length(cases) > 7000
    local bad_op = [c for c in cases if W.jl_is_operator(c) != native_op(c)]
    local bad_syn = [c for c in cases if W.jl_is_syntactic_operator(c) != native_syn(c)]
    @test isempty(bad_op) || (@info "operator? disagrees" bad_op[1:min(end, 20)]; false)
    @test isempty(bad_syn) || (@info "syntactic-op? disagrees" bad_syn[1:min(end, 20)]; false)
    # a Symbol's name, Base's answer for the Symbol natively: the ported predicates over the name
    @test all(c -> (Base._isoperator(Symbol(c)) == (W.jl_is_operator(String(Symbol(c))) != 0)), cases)
    @test all(c -> (Base.is_syntactic_operator(Symbol(c)) == (W.jl_is_syntactic_operator(String(Symbol(c))) != 0)), cases)
    @test_throws ArgumentError Base._isoperator("+\0")
    # the suffix test over every code point
    @test all(wc -> W.jl_op_suffix_char(wc) == (ccall(:jl_op_suffix_char, Cint, (UInt32,), wc) != 0), UInt32(0):UInt32(0x10ffff))
    # the tables are the parser's: the dotted forms computed (add-dots), the word operators out of operators
    @test "in" in W.PREC_COMPARISON && !("in" in W.FL_OPERATORS) && ".+" in W.PREC_PLUS && ".+" in W.FL_OPERATORS
    # each overlay at Base's own signature: Base defines one method of each, which the overlay table's answers alone
    @test length(methods(Base._isoperator)) == 1 && only(methods(Base._isoperator)).sig == Tuple{typeof(Base._isoperator), Any}
    @test length(methods(Base.is_syntactic_operator)) == 1 && only(methods(Base.is_syntactic_operator)).sig == Tuple{typeof(Base.is_syntactic_operator), Symbol}
    local mt = Core.Compiler.OverlayMethodTable(Base.get_world_counter(), W.METHOD_TABLE)
    @test Base._which(Tuple{typeof(Base._isoperator), Symbol}; method_table = mt).method.module === W
    @test Base._which(Tuple{typeof(Base._isoperator), String}; method_table = mt).method.module === W
    @test Base._which(Tuple{typeof(Base.is_syntactic_operator), Symbol}; method_table = mt).method.module === W
end

@testset "the overlays in a module, against native" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((OC.ops, (1,)), (OC.syn, (1,)), (OC.str_op, (0x2b, 0x61, 0x3d)), (OC.str_nul, (0x2b,)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("julia_parser_ops/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
