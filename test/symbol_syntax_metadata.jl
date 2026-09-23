using Test
using WasmTarget

@noinline _wt_is_operator_symbol(s::Symbol)::Bool = Base._isoperator(s)
@noinline _wt_is_syntactic_symbol(s::Symbol)::Bool = Base.is_syntactic_operator(s)

_wt_plus_is_operator()::Bool = _wt_is_operator_symbol(Symbol("+"))
_wt_int_is_operator()::Bool = _wt_is_operator_symbol(:Int)
_wt_equal_is_syntactic()::Bool = _wt_is_syntactic_symbol(Symbol("="))
_wt_plus_is_syntactic()::Bool = _wt_is_syntactic_symbol(Symbol("+"))

@testset "Symbol syntax metadata across calls" begin
    cases = [(_wt_plus_is_operator, true),
             (_wt_int_is_operator, false),
             (_wt_equal_is_syntactic, true),
             (_wt_plus_is_syntactic, false)]
    for (f, expected) in cases
        @test f() == expected
        bytes = WasmTarget.compile(f, (); validate=true)
        @test run_wasm(bytes, string(nameof(f))) == Int(expected)
    end
end

# WT's operator tables (src/codegen/interpreter.jl) are derived at build time from Julia's own
# predicates; the flisp parser's lists, printed by `julia --lisp`, are the oracle they equal.
function _wt_flisp_lines(program::String)::Vector{String}
    # `--lisp` is honored only as the first argument; the flisp REPL exits nonzero at the
    # end of its input, and its printed lines are the answer
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    out = read(pipeline(ignorestatus(`$julia --lisp`); stdin=IOBuffer(program)), String)
    return [String(split(l, "@@")[end]) for l in split(out, '\n') if occursin("@@", l)]
end
_wt_unpack_name(v::UInt64) = String(UInt8[(v >> (8 * i)) % UInt8 for i in 0:7 if (v >> (8 * i)) % UInt8 != 0x00])

@testset "operator tables equal Julia's parser lists" begin
    each(list) = "(for-each (lambda (x) (princ \"@@\" (string x)) (newline)) $list)\n"
    operators = Set(_wt_flisp_lines(each("operators")))
    @test length(operators) > 1000
    @test Set(_wt_unpack_name.(WasmTarget._WT_OPERATORS)) == operators
    @test Set(_wt_unpack_name.(WasmTarget._WT_SYNTACTIC_OPERATORS)) == Set(_wt_flisp_lines(each("syntactic-operators")))
    @test Set(_wt_unpack_name.(WasmTarget._WT_NO_SUFFIX_OPERATORS)) == Set(_wt_flisp_lines(
        "(for-each (lambda (x) (if (no-suffix? x) (begin (princ \"@@\" (string x)) (newline)))) operators)\n"))
end

@testset "the operator-name port answers as jl_is_operator does" begin
    names = String[_wt_unpack_name(v) for v in WasmTarget._WT_OPERATORS]
    corpus = String[]
    for s in names
        push!(corpus, s, s * "′", s * "₁′", s * "̂", "′" * s, s * "+", s * "=", "." * s, s * "a")
    end
    append!(corpus, ["", "a", "in", "isa", "in′", "Int", "..", "....", "<--", "--", ".--", "+++",
                     String(UInt8[0xc3, 0x2b]), String(UInt8[0xe2, 0x80]), String(UInt8[0x2b, 0xcc])])
    for s in corpus
        @test WasmTarget._wt_parser_is_operator(s) == Base._isoperator(s)
        @test WasmTarget._wt_parser_is_syntactic_operator(s) == Base.is_syntactic_operator(Symbol(s))
    end
end
