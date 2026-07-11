using Test
using WasmTarget

@noinline function _wt_prefixed_vararg_sum(seed::Int64, xs::Vararg{Int64})::Int64
    total = seed
    for x in xs
        total += x
    end
    return total
end

@noinline _wt_prefixed_vararg_second(seed::Int64, xs::Vararg{Int64})::Int64 =
    seed + getfield(xs, 2, true)

@testset "fixed-prefix vararg ABI" begin
    cases = [(_wt_prefixed_vararg_sum, (5, 1, 2, 3), 11),
             (_wt_prefixed_vararg_second, (5, 10, 20, 30), 25)]
    for (f, args, expected) in cases
        @test f(args...) == expected
        arg_types = Tuple(typeof.(args))
        bytes = WasmTarget.compile(f, arg_types; validate=true)
        @test run_wasm(bytes, string(nameof(f)), args...) == expected
    end
end
