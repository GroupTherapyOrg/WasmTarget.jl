module JumpMOIValueCanaries

using MathOptInterface
using OrderedCollections

const MOI = MathOptInterface

function moi_affine_value(x::Float64)::Float64
    v1 = MOI.VariableIndex(1)
    v2 = MOI.VariableIndex(2)
    terms = MOI.ScalarAffineTerm{Float64}[
        MOI.ScalarAffineTerm(2.0, v1),
        MOI.ScalarAffineTerm(-0.5, v2),
    ]
    f = MOI.ScalarAffineFunction(terms, 3.0)
    return MOI.Utilities.eval_variables(v -> x + Float64(v.value), f)
end

function moi_quadratic_value(x::Float64)::Float64
    v1 = MOI.VariableIndex(1)
    v2 = MOI.VariableIndex(2)
    qterms = MOI.ScalarQuadraticTerm{Float64}[
        MOI.ScalarQuadraticTerm(2.0, v1, v1),
        MOI.ScalarQuadraticTerm(-1.0, v1, v2),
    ]
    aterms = MOI.ScalarAffineTerm{Float64}[
        MOI.ScalarAffineTerm(0.25, v2),
    ]
    f = MOI.ScalarQuadraticFunction(qterms, aterms, 1.5)
    return MOI.Utilities.eval_variables(v -> x + Float64(v.value), f)
end

function moi_set_value(x::Float64)::Float64
    lower = MOI.GreaterThan(-2.0)
    upper = MOI.LessThan(5.0)
    equal = MOI.EqualTo(1.25)
    interval = MOI.Interval(-3.0, 7.0)
    return x + lower.lower + upper.upper + equal.value +
           interval.lower + interval.upper
end

function ordered_dict_value(x::Int64)::Int64
    d = OrderedDict{Int64,Int64}()
    d[3] = x
    d[1] = x + 2
    d[2] = x - 1
    delete!(d, 1)
    total = Int64(0)
    for (k, v) in d
        total += 10k + v
    end
    return total
end

const CASES = Dict{String,NamedTuple}(
    "moi_affine_value" => (f=moi_affine_value, inputs=[(-4.0,), (0.0,), (3.5,)]),
    "moi_quadratic_value" => (f=moi_quadratic_value, inputs=[(-2.0,), (0.5,), (4.0,)]),
    "moi_set_value" => (f=moi_set_value, inputs=[(-3.0,), (0.0,), (8.0,)]),
    "ordered_dict_value" => (f=ordered_dict_value, inputs=[(-7,), (0,), (12,)]),
)

end
