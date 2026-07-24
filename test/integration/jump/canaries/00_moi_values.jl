module JumpMOIValueCanaries

using MathOptInterface
using OrderedCollections
using Random

const MOI = MathOptInterface
const PROPERTY_SEED = UInt64(0x4a554d505741534d)
const PROPERTY_RANDOM_SAMPLES = 64

function bounded_float_inputs()
    rng = Xoshiro(PROPERTY_SEED)
    boundaries = Float64[
        -1.0e6,
        -1.0e3,
        -10.0,
        -1.0,
        -eps(Float64),
        -0.0,
        0.0,
        eps(Float64),
        1.0,
        10.0,
        1.0e3,
        1.0e6,
    ]
    randoms = [
        Float64(rand(rng, -1_000_000:1_000_000)) / 64.0
        for _ in 1:PROPERTY_RANDOM_SAMPLES
    ]
    return [(x,) for x in unique(vcat(boundaries, randoms))]
end

function bounded_int_inputs()
    rng = Xoshiro(PROPERTY_SEED ⊻ UInt64(0x6f726465726564))
    boundaries = Int64[
        -1_000_000,
        -1_000,
        -10,
        -1,
        0,
        1,
        10,
        1_000,
        1_000_000,
    ]
    randoms = Int64[
        rand(rng, -1_000_000:1_000_000)
        for _ in 1:PROPERTY_RANDOM_SAMPLES
    ]
    return [(x,) for x in unique(vcat(boundaries, randoms))]
end

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
    "moi_affine_value" => (
        f=moi_affine_value,
        inputs=bounded_float_inputs(),
        property=:bounded_deterministic,
    ),
    "moi_quadratic_value" => (
        f=moi_quadratic_value,
        inputs=bounded_float_inputs(),
        property=:bounded_deterministic,
    ),
    "moi_set_value" => (
        f=moi_set_value,
        inputs=bounded_float_inputs(),
        property=:bounded_deterministic,
    ),
    "ordered_dict_value" => (
        f=ordered_dict_value,
        inputs=bounded_int_inputs(),
        property=:bounded_deterministic,
    ),
)

end
