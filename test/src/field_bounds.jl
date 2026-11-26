# A field read at a constant position on a receiver Julia left abstract (src/code_generator.jl visitInstanceGet), some
# class of which has fewer fields: Julia's codegen reads no field of a Union (julia/src/codegen.cpp:4521, utt no
# DataType) and calls jl_f_getfield, whose get_checked_fieldindex checks the position against the value's own type
# and raises BoundsError of the value and the position past its fields (julia/src/builtins.c:994, :1006), else reads
# it. A tuple held in such a receiver is its arity's record (TupleRecord), read by the record's own field. Each case's
# answer is native Julia's, compared in both modules.
module FieldBoundsTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module BoundsCases
abstract type Shape end
# field names no other class of the world holds: a field selector is named by its field, and a class of another field
# type under the same name (BoundsError's `a`) is another target of that selector
struct Wide <: Shape; wfirst::Int64; wsecond::Int64; end
struct Thin <: Shape; wfirst::Int64; end
_why(e) = e isa BoundsError ? -1 : -2
# the reader of a corpus answer's leaf (test/verdict.jl Leaves): a tuple's fact behind a Union with Int64, whose
# position 1 Int64 reaches past its no fields (BoundsError natively at x < 1)
@noinline _facts(x::Int64) = x > 0 ? (x == 1, x == 2) : Int64(0)
function fact_or_int(x::Int64)::Int64
    try
        return getfield(_facts(x), 1)::Bool ? 10 : 20
    catch e
        return _why(e)
    end
end
# a position past one subtype's fields, its other subtype read by the field's selector (BoundsError at x < 1)
@noinline _shape(x::Int64)::Shape = x > 0 ? Wide(x, 2x) : Thin(x)
function second_field(x::Int64)::Int64
    try
        return getfield(_shape(x), 2)::Int64
    catch e
        return _why(e)
    end
end
# Nothing's value, the null, has no field (BoundsError at x < 1)
@noinline _maybe(x::Int64) = x > 0 ? Wide(x, 3x) : nothing
function first_or_nothing(x::Int64)::Int64
    try
        return getfield(_maybe(x), 1)::Int64
    catch e
        return _why(e)
    end
end
# two tuple arities held as their records, each read by its record's field through the table (BoundsError at x == 0)
@noinline _tuples(x::Int64) = x > 1 ? (x, 2x, 3x) : x == 1 ? (7x, 8x) : Int64(5)
function second_of_tuples(x::Int64)::Int64
    try
        return getfield(_tuples(x), 2)::Int64
    catch e
        return _why(e)
    end
end
# the value and the position BoundsError carries (Julia's jl_bounds_error(v, arg))
function bounds_payload(x::Int64)::Int64
    try
        return getfield(_facts(x), 1)::Bool ? 10 : 20
    catch e
        return e isa BoundsError && (e::BoundsError).i === 1 && (e::BoundsError).a === Int64(0) ? -7 : -8
    end
end
end

const BC = BoundsCases

@testset "a field read past a class's fields raises as jl_f_getfield does" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((BC.fact_or_int, (1, 2, 0)), (BC.second_field, (3, -1)), (BC.first_or_nothing, (2, 0)),
                    (BC.second_of_tuples, (2, 1, 0)), (BC.bounds_payload, (1, 0)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("field_bounds/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: a fact read, BoundsError past Int64's, Thin's, Nothing's and Int64's fields, a record's field
    @test [c.native for c in cases] == [10, 20, -1, 6, -1, 2, -1, 4, 8, -1, 10, -7]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
