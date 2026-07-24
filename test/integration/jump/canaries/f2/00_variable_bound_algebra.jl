module JumpF2VariableBoundCanaries

import MathOptInterface as MOI

const U = MOI.Utilities

float_from_bits(bits::Int64)::Float64 = reinterpret(Float64, bits)
bits_from_float(value::Float64)::Int64 = reinterpret(Int64, value)

"""
Exercise the pinned MOI one-hot flag and reverse-Type vocabulary. The Type
value returned by `_flag_to_set_type` remains inside Wasm; the boundary is an
exact integer witness rather than a marshalled representation of a Julia Type.
"""
function f2_flag_type_vocabulary(tag::Int64)::Int64
    expected_type = MOI.EqualTo{Float64}
    flag = UInt16(0)
    if tag == 1
        expected_type = MOI.EqualTo{Float64}
        flag = U._single_variable_flag(MOI.EqualTo{Float64})
    elseif tag == 2
        expected_type = MOI.GreaterThan{Float64}
        flag = U._single_variable_flag(MOI.GreaterThan{Float64})
    elseif tag == 3
        expected_type = MOI.LessThan{Float64}
        flag = U._single_variable_flag(MOI.LessThan{Float64})
    elseif tag == 4
        expected_type = MOI.Interval{Float64}
        flag = U._single_variable_flag(MOI.Interval{Float64})
    elseif tag == 5
        expected_type = MOI.Integer
        flag = U._single_variable_flag(MOI.Integer)
    elseif tag == 6
        expected_type = MOI.ZeroOne
        flag = U._single_variable_flag(MOI.ZeroOne)
    elseif tag == 7
        expected_type = MOI.Semicontinuous{Float64}
        flag = U._single_variable_flag(MOI.Semicontinuous{Float64})
    elseif tag == 8
        expected_type = MOI.Semiinteger{Float64}
        flag = U._single_variable_flag(MOI.Semiinteger{Float64})
    elseif tag == 9
        expected_type = MOI.Parameter{Float64}
        flag = U._single_variable_flag(MOI.Parameter{Float64})
    else
        error("set tag must be in 1:9")
    end
    recovered_type = U._flag_to_set_type(flag, Float64)
    type_ok = recovered_type === expected_type
    lower_ok = !iszero(flag & U._LOWER_BOUND_MASK)
    upper_ok = !iszero(flag & U._UPPER_BOUND_MASK)
    return Int64(flag) |
           (Int64(type_ok) << 16) |
           (Int64(lower_ok) << 17) |
           (Int64(upper_ok) << 18)
end

"""
Prove that zero, composite, deleted, and unknown masks do not silently map to
`Parameter`. The exact pinned MOI assertion must be caught as an
`AssertionError`; zero means silent acceptance and -1 means the failure class
changed.
"""
function f2_invalid_flag_rejected(flag_bits::Int64)::Int64
    try
        U._flag_to_set_type(UInt16(flag_bits), Float64)
        return 0
    catch error
        return error isa AssertionError ? 1 : -1
    end
end

"""
Prove that a set outside the pinned variable-bound vocabulary remains
unsupported by the actual MOI flag method rather than receiving a fabricated
flag.
"""
function f2_unsupported_set_rejected(::Int64)::Int64
    try
        U._single_variable_flag(MOI.Reals)
        return 0
    catch error
        return error isa MethodError ? 1 : -1
    end
end

Base.@noinline function index_family(index)::Int64
    if index isa MOI.ConstraintIndex{
        MOI.VariableIndex,
        MOI.EqualTo{Float64},
    }
        return 1
    elseif index isa MOI.ConstraintIndex{
        MOI.VariableIndex,
        MOI.GreaterThan{Float64},
    }
        return 2
    elseif index isa MOI.ConstraintIndex{
        MOI.VariableIndex,
        MOI.LessThan{Float64},
    }
        return 3
    elseif index isa MOI.ConstraintIndex{
        MOI.VariableIndex,
        MOI.Interval{Float64},
    }
        return 4
    elseif index isa MOI.ConstraintIndex{MOI.VariableIndex,MOI.Integer}
        return 5
    elseif index isa MOI.ConstraintIndex{MOI.VariableIndex,MOI.ZeroOne}
        return 6
    elseif index isa MOI.ConstraintIndex{
        MOI.VariableIndex,
        MOI.Semicontinuous{Float64},
    }
        return 7
    elseif index isa MOI.ConstraintIndex{
        MOI.VariableIndex,
        MOI.Semiinteger{Float64},
    }
        return 8
    elseif index isa MOI.ConstraintIndex{
        MOI.VariableIndex,
        MOI.Parameter{Float64},
    }
        return 9
    end
    error("uncertified variable-constraint index family")
end

"""
Construct one union-typed real parametric MOI index, cross a no-inline dynamic
type-family barrier, and encode the recovered family independently from the
stored Int64 payload. This prevents nine statically self-equal branch-local
checks from collapsing to the same witness.
"""
function f2_index_identity(tag::Int64, value::Int64)::Int64
    variable = MOI.VariableIndex(value)
    index = if tag == 1
        MOI.ConstraintIndex{
            MOI.VariableIndex,
            MOI.EqualTo{Float64},
        }(variable.value)
    elseif tag == 2
        MOI.ConstraintIndex{
            MOI.VariableIndex,
            MOI.GreaterThan{Float64},
        }(variable.value)
    elseif tag == 3
        MOI.ConstraintIndex{
            MOI.VariableIndex,
            MOI.LessThan{Float64},
        }(variable.value)
    elseif tag == 4
        MOI.ConstraintIndex{
            MOI.VariableIndex,
            MOI.Interval{Float64},
        }(variable.value)
    elseif tag == 5
        MOI.ConstraintIndex{
            MOI.VariableIndex,
            MOI.Integer,
        }(variable.value)
    elseif tag == 6
        MOI.ConstraintIndex{
            MOI.VariableIndex,
            MOI.ZeroOne,
        }(variable.value)
    elseif tag == 7
        MOI.ConstraintIndex{
            MOI.VariableIndex,
            MOI.Semicontinuous{Float64},
        }(variable.value)
    elseif tag == 8
        MOI.ConstraintIndex{
            MOI.VariableIndex,
            MOI.Semiinteger{Float64},
        }(variable.value)
    elseif tag == 9
        MOI.ConstraintIndex{
            MOI.VariableIndex,
            MOI.Parameter{Float64},
        }(variable.value)
    else
        error("set tag must be in 1:9")
    end
    family = index_family(index)
    payload_match = index.value == variable.value
    return index.value ⊻
           (family * Int64(0x0101010101010101)) ⊻
           (Int64(payload_match) << 62)
end

function bounds(
    flag::UInt16,
    lower::Float64,
    upper::Float64,
)
    return U.VariablesContainer{Float64}(
        UInt16[flag],
        Float64[lower],
        Float64[upper],
    )
end

function f2_equal_roundtrip(
    which::Int64,
    lower_bits::Int64,
    upper_bits::Int64,
)::Int64
    lower = float_from_bits(lower_bits)
    original = MOI.EqualTo(lower)
    flag = U._single_variable_flag(MOI.EqualTo{Float64})
    value = U._lower_bound(original)
    carrier = bounds(flag, value, U._upper_bound(original))
    reconstructed =
        U.set_from_constants(carrier, MOI.EqualTo{Float64}, 1)
    return bits_from_float(
        which == 0 ? U._lower_bound(reconstructed) :
        U._upper_bound(reconstructed),
    )
end

function f2_greater_roundtrip(
    which::Int64,
    lower_bits::Int64,
    upper_bits::Int64,
)::Int64
    lower = float_from_bits(lower_bits)
    original = MOI.GreaterThan(lower)
    flag = U._single_variable_flag(MOI.GreaterThan{Float64})
    carrier = bounds(
        flag,
        U._lower_bound(original),
        U._no_upper_bound(Float64),
    )
    reconstructed =
        U.set_from_constants(carrier, MOI.GreaterThan{Float64}, 1)
    return bits_from_float(
        which == 0 ? U._lower_bound(reconstructed) :
        carrier.upper[1],
    )
end

function f2_less_roundtrip(
    which::Int64,
    lower_bits::Int64,
    upper_bits::Int64,
)::Int64
    upper = float_from_bits(upper_bits)
    original = MOI.LessThan(upper)
    flag = U._single_variable_flag(MOI.LessThan{Float64})
    carrier = bounds(
        flag,
        U._no_lower_bound(Float64),
        U._upper_bound(original),
    )
    reconstructed =
        U.set_from_constants(carrier, MOI.LessThan{Float64}, 1)
    return bits_from_float(
        which == 0 ? carrier.lower[1] :
        U._upper_bound(reconstructed),
    )
end

function f2_interval_roundtrip(
    which::Int64,
    lower_bits::Int64,
    upper_bits::Int64,
)::Int64
    original = MOI.Interval(
        float_from_bits(lower_bits),
        float_from_bits(upper_bits),
    )
    flag = U._single_variable_flag(MOI.Interval{Float64})
    carrier =
        bounds(flag, U._lower_bound(original), U._upper_bound(original))
    reconstructed =
        U.set_from_constants(carrier, MOI.Interval{Float64}, 1)
    return bits_from_float(
        which == 0 ? U._lower_bound(reconstructed) :
        U._upper_bound(reconstructed),
    )
end

function f2_integer_roundtrip(
    which::Int64,
    lower_bits::Int64,
    upper_bits::Int64,
)::Int64
    original = MOI.Integer()
    flag = U._single_variable_flag(MOI.Integer)
    carrier = bounds(
        flag,
        U._no_lower_bound(Float64),
        U._no_upper_bound(Float64),
    )
    reconstructed = U.set_from_constants(carrier, MOI.Integer, 1)
    empty_ok = typeof(original) === typeof(reconstructed)
    value = which == 0 ? carrier.lower[1] : carrier.upper[1]
    return bits_from_float(value) ⊻ (Int64(empty_ok) << 60)
end

function f2_zero_one_roundtrip(
    which::Int64,
    lower_bits::Int64,
    upper_bits::Int64,
)::Int64
    original = MOI.ZeroOne()
    flag = U._single_variable_flag(MOI.ZeroOne)
    carrier = bounds(
        flag,
        U._no_lower_bound(Float64),
        U._no_upper_bound(Float64),
    )
    reconstructed = U.set_from_constants(carrier, MOI.ZeroOne, 1)
    empty_ok = typeof(original) === typeof(reconstructed)
    value = which == 0 ? carrier.lower[1] : carrier.upper[1]
    return bits_from_float(value) ⊻ (Int64(empty_ok) << 60)
end

function f2_semicontinuous_roundtrip(
    which::Int64,
    lower_bits::Int64,
    upper_bits::Int64,
)::Int64
    original = MOI.Semicontinuous(
        float_from_bits(lower_bits),
        float_from_bits(upper_bits),
    )
    flag = U._single_variable_flag(MOI.Semicontinuous{Float64})
    carrier =
        bounds(flag, U._lower_bound(original), U._upper_bound(original))
    reconstructed =
        U.set_from_constants(carrier, MOI.Semicontinuous{Float64}, 1)
    return bits_from_float(
        which == 0 ? U._lower_bound(reconstructed) :
        U._upper_bound(reconstructed),
    )
end

function f2_semiinteger_roundtrip(
    which::Int64,
    lower_bits::Int64,
    upper_bits::Int64,
)::Int64
    original = MOI.Semiinteger(
        float_from_bits(lower_bits),
        float_from_bits(upper_bits),
    )
    flag = U._single_variable_flag(MOI.Semiinteger{Float64})
    carrier =
        bounds(flag, U._lower_bound(original), U._upper_bound(original))
    reconstructed =
        U.set_from_constants(carrier, MOI.Semiinteger{Float64}, 1)
    return bits_from_float(
        which == 0 ? U._lower_bound(reconstructed) :
        U._upper_bound(reconstructed),
    )
end

function f2_parameter_roundtrip(
    which::Int64,
    lower_bits::Int64,
    upper_bits::Int64,
)::Int64
    original = MOI.Parameter(float_from_bits(lower_bits))
    flag = U._single_variable_flag(MOI.Parameter{Float64})
    value = U._lower_bound(original)
    carrier = bounds(flag, value, U._upper_bound(original))
    reconstructed =
        U.set_from_constants(carrier, MOI.Parameter{Float64}, 1)
    return bits_from_float(
        which == 0 ? U._lower_bound(reconstructed) :
        U._upper_bound(reconstructed),
    )
end

bits(value::UInt64)::Int64 = reinterpret(Int64, value)

const EDGE_BITS = Int64[
    bits(0x0000000000000000), # +0.0
    bits(0x8000000000000000), # -0.0
    bits(0x0000000000000001), # minimum positive subnormal
    bits(0x8000000000000001), # minimum negative subnormal
    bits(0x000fffffffffffff), # maximum positive subnormal
    bits(0x800fffffffffffff), # maximum negative subnormal
    bits(0x0010000000000000), # minimum positive normal
    bits(0x8010000000000000), # minimum negative normal
    bits(0x7fefffffffffffff), # maximum finite
    bits(0xffefffffffffffff), # minimum finite
    bits(0x7ff0000000000000), # +Inf
    bits(0xfff0000000000000), # -Inf
    bits(0x7ff8000000000001), # quiet NaN payload
    bits(0xfff8000000000042), # negative quiet NaN payload
]

const PAIRS = Tuple{Int64,Int64}[
    (value, value) for value in EDGE_BITS
]
append!(PAIRS, Tuple{Int64,Int64}[
    (bits(0xfff0000000000000), bits(0x7ff0000000000000)),
    (bits(0x8000000000000000), bits(0x0000000000000000)),
    (bits(0x4000000000000000), bits(0x3ff0000000000000)),
    (bits(0x4004000000000000), bits(0x400c000000000000)), # 2.5, 3.5
    (bits(0x4004000000000000), bits(0x3ff8000000000000)), # 2.5, 1.5
    (bits(0x7ff8000000000001), bits(0x3ff0000000000000)),
    (bits(0x3ff0000000000000), bits(0xfff8000000000042)),
])

const FLAG_INPUTS = [(tag,) for tag in Int64(1):Int64(9)]
const INVALID_FLAG_INPUTS = [
    (Int64(0x0000),),
    (Int64(0x0003),),
    (Int64(0x8000),),
    (Int64(0xffff),),
]
const UNSUPPORTED_SET_INPUTS = [(Int64(0),)]
const INDEX_INPUTS = [
    (tag, value)
    for tag in Int64(1):Int64(9)
    for value in
        Int64[typemin(Int64), -1, 0, 1, 17, typemax(Int64)]
]
const ROUNDTRIP_INPUTS = [
    (which, pair[1], pair[2])
    for which in Int64(0):Int64(1)
    for pair in PAIRS
]

const FLAG_EXPECTED_VALUE = Dict(
    Int64(1) => Int64(458753),
    Int64(2) => Int64(196610),
    Int64(3) => Int64(327684),
    Int64(4) => Int64(458760),
    Int64(5) => Int64(65552),
    Int64(6) => Int64(65568),
    Int64(7) => Int64(458816),
    Int64(8) => Int64(458880),
    Int64(9) => Int64(459008),
)
const FLAG_EXPECTED =
    Dict(input => FLAG_EXPECTED_VALUE[input[1]] for input in FLAG_INPUTS)
const INVALID_FLAG_EXPECTED =
    Dict(input => Int64(1) for input in INVALID_FLAG_INPUTS)
const UNSUPPORTED_SET_EXPECTED =
    Dict(input => Int64(1) for input in UNSUPPORTED_SET_INPUTS)
const INDEX_FAMILY_WITNESS = Dict(
    Int64(1) => Int64(0x0101010101010101),
    Int64(2) => Int64(0x0202020202020202),
    Int64(3) => Int64(0x0303030303030303),
    Int64(4) => Int64(0x0404040404040404),
    Int64(5) => Int64(0x0505050505050505),
    Int64(6) => Int64(0x0606060606060606),
    Int64(7) => Int64(0x0707070707070707),
    Int64(8) => Int64(0x0808080808080808),
    Int64(9) => Int64(0x0909090909090909),
)
const INDEX_EXPECTED = Dict(
    input =>
        input[2] ⊻
        INDEX_FAMILY_WITNESS[input[1]] ⊻
        (Int64(1) << 62)
    for input in INDEX_INPUTS
)
const BOUNDED_EXPECTED = Dict(
    input => input[1] == 0 ? input[2] : input[3]
    for input in ROUNDTRIP_INPUTS
)
const EQUAL_EXPECTED =
    Dict(input => input[2] for input in ROUNDTRIP_INPUTS)
const GREATER_EXPECTED = Dict(
    input => input[1] == 0 ? input[2] : bits(0x7ff0000000000000)
    for input in ROUNDTRIP_INPUTS
)
const LESS_EXPECTED = Dict(
    input => input[1] == 0 ? bits(0xfff0000000000000) : input[3]
    for input in ROUNDTRIP_INPUTS
)
const EMPTY_SET_EXPECTED = Dict(
    input => (
        input[1] == 0 ?
        bits(0xfff0000000000000) :
        bits(0x7ff0000000000000)
    ) ⊻ (Int64(1) << 60)
    for input in ROUNDTRIP_INPUTS
)

const SOURCE_PROVENANCE = (
    math_opt_interface_version="1.51.2",
    git_tree_sha1="7b57dbe5d2c988a0c7a0ea977045e844e3d0b263",
    sources=(
        (
            file="src/indextypes.jl",
            lines="38-71",
            operation="VariableIndex and parametric ConstraintIndex identity and Int64 payload",
        ),
        (
            file="src/sets.jl",
            lines="145-279,311-412",
            operation="nine pinned Float64 variable-bound set layouts",
        ),
        (
            file="src/Utilities/variables_container.jl",
            lines="9-170,178-195",
            operation="actual set reconstruction, flags, reverse Type dispatch, bound extraction, Float64 sentinels, and AbstractVectorBounds carrier",
        ),
    ),
)

const CASES = Dict(
    "f2_flag_type_vocabulary" => (
        f=f2_flag_type_vocabulary,
        inputs=FLAG_INPUTS,
        expected=FLAG_EXPECTED,
        expected_ledger_sha256="e0a95670ea5354855d58f2d8ada3f0b923aa5d72fd67e8665a90c10aad57f186",
        property=:exhaustive_closed_vocabulary,
        provenance=SOURCE_PROVENANCE,
    ),
    "f2_invalid_flag_rejected" => (
        f=f2_invalid_flag_rejected,
        inputs=INVALID_FLAG_INPUTS,
        expected=INVALID_FLAG_EXPECTED,
        expected_ledger_sha256="4d8b5454340b688b539a8e0815e83dda655c67e44f6bfd66751289d8bbb7cf2d",
        property=:bounded_correct_or_loud_invalid_masks,
        provenance=SOURCE_PROVENANCE,
    ),
    "f2_unsupported_set_rejected" => (
        f=f2_unsupported_set_rejected,
        inputs=UNSUPPORTED_SET_INPUTS,
        expected=UNSUPPORTED_SET_EXPECTED,
        expected_ledger_sha256="e487010c174bea80b804c870f658e8f289819e291f9f18ad83661a922b542ffb",
        property=:bounded_correct_or_loud_unsupported_set,
        provenance=SOURCE_PROVENANCE,
    ),
    "f2_index_identity" => (
        f=f2_index_identity,
        inputs=INDEX_INPUTS,
        expected=INDEX_EXPECTED,
        expected_ledger_sha256="df5b56cd5af3ddd592e23564bb4a7466b29f24ee17f70025398daf55708961f3",
        property=:bounded_structural_identity,
        provenance=SOURCE_PROVENANCE,
    ),
    "f2_equal_roundtrip" => (
        f=f2_equal_roundtrip, inputs=ROUNDTRIP_INPUTS,
        expected=EQUAL_EXPECTED,
        expected_ledger_sha256="c85de3a886237dc2f143d4b3c1ceaa1d2c641bfc2dee53e7ec57f91e486ca938",
        property=:ieee_bit_ledger, provenance=SOURCE_PROVENANCE,
    ),
    "f2_greater_roundtrip" => (
        f=f2_greater_roundtrip, inputs=ROUNDTRIP_INPUTS,
        expected=GREATER_EXPECTED,
        expected_ledger_sha256="b1e09a6dd24c410417b820c1ce9bbe997f255bc822a2039962df4c4d5c50a5cb",
        property=:ieee_bit_ledger, provenance=SOURCE_PROVENANCE,
    ),
    "f2_less_roundtrip" => (
        f=f2_less_roundtrip, inputs=ROUNDTRIP_INPUTS,
        expected=LESS_EXPECTED,
        expected_ledger_sha256="c47a32fa255d5b82bc0c65dd618cbb415a97841ae628526555e31d8c75dfa0bf",
        property=:ieee_bit_ledger, provenance=SOURCE_PROVENANCE,
    ),
    "f2_interval_roundtrip" => (
        f=f2_interval_roundtrip, inputs=ROUNDTRIP_INPUTS,
        expected=BOUNDED_EXPECTED,
        expected_ledger_sha256="4f658fd6c31b424d39e1be87847fd1d78fb2f19347c50628dc84206143d2a3e1",
        property=:ieee_bit_ledger, provenance=SOURCE_PROVENANCE,
    ),
    "f2_integer_roundtrip" => (
        f=f2_integer_roundtrip, inputs=ROUNDTRIP_INPUTS,
        expected=EMPTY_SET_EXPECTED,
        expected_ledger_sha256="d82e793f80be031c4e8d92d0c2d405dd04d9d16ef659a455a161c28b4cbca967",
        property=:empty_layout_and_sentinel_ledger,
        provenance=SOURCE_PROVENANCE,
    ),
    "f2_zero_one_roundtrip" => (
        f=f2_zero_one_roundtrip, inputs=ROUNDTRIP_INPUTS,
        expected=EMPTY_SET_EXPECTED,
        expected_ledger_sha256="d82e793f80be031c4e8d92d0c2d405dd04d9d16ef659a455a161c28b4cbca967",
        property=:empty_layout_and_sentinel_ledger,
        provenance=SOURCE_PROVENANCE,
    ),
    "f2_semicontinuous_roundtrip" => (
        f=f2_semicontinuous_roundtrip, inputs=ROUNDTRIP_INPUTS,
        expected=BOUNDED_EXPECTED,
        expected_ledger_sha256="4f658fd6c31b424d39e1be87847fd1d78fb2f19347c50628dc84206143d2a3e1",
        property=:ieee_bit_ledger, provenance=SOURCE_PROVENANCE,
    ),
    "f2_semiinteger_roundtrip" => (
        f=f2_semiinteger_roundtrip, inputs=ROUNDTRIP_INPUTS,
        expected=BOUNDED_EXPECTED,
        expected_ledger_sha256="4f658fd6c31b424d39e1be87847fd1d78fb2f19347c50628dc84206143d2a3e1",
        property=:ieee_bit_ledger, provenance=SOURCE_PROVENANCE,
    ),
    "f2_parameter_roundtrip" => (
        f=f2_parameter_roundtrip, inputs=ROUNDTRIP_INPUTS,
        expected=EQUAL_EXPECTED,
        expected_ledger_sha256="c85de3a886237dc2f143d4b3c1ceaa1d2c641bfc2dee53e7ec57f91e486ca938",
        property=:ieee_bit_ledger, provenance=SOURCE_PROVENANCE,
    ),
)

end
