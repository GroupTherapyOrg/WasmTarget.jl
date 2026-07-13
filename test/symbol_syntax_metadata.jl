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
