module JumpF1NullableLayoutCanaries

import MathOptInterface as MOI

"""
An isolating surrogate for the nullable concrete-object topology used by
`MOI.Utilities.ObjectiveContainer{Float64}`, plus retained mutable child
ownership as a distinct compiler/runtime prerequisite.

This is deliberately not an `ObjectiveContainer` certification. It isolates
the compiler/runtime layout prerequisite so a failure does not implicate the
full MOI storage API.
"""
mutable struct NullableLayoutLeaf
    value::Int64
end

mutable struct NullableObjectiveLayout
    is_sense_set::Bool
    sense::MOI.OptimizationSense
    is_function_set::Bool
    single_variable::Union{Nothing,MOI.VariableIndex}
    scalar_affine::Union{Nothing,MOI.ScalarAffineFunction{Float64}}
    leaf::NullableLayoutLeaf
end

function f1_nullable_objective_layout(state::Int64, x::Int64)::Int64
    layout = NullableObjectiveLayout(
        false,
        MOI.FEASIBILITY_SENSE,
        false,
        nothing,
        nothing,
        NullableLayoutLeaf(x),
    )
    retained_leaf = layout.leaf
    invariant_mask = Int64(0)
    payload = Int64(0)

    if state == 0
        invariant_mask |= Int64(layout.single_variable === nothing) << 0
        invariant_mask |= Int64(layout.scalar_affine === nothing) << 1
    elseif state == 1
        layout.is_sense_set = true
        layout.sense = MOI.MIN_SENSE
        layout.is_function_set = true
        layout.single_variable = MOI.VariableIndex(x + 19)
        payload = something(layout.single_variable).value
        invariant_mask |= Int64(layout.scalar_affine === nothing) << 1
    elseif state == 2
        original = MOI.ScalarAffineFunction(
            MOI.ScalarAffineTerm{Float64}[
                MOI.ScalarAffineTerm(2.0, MOI.VariableIndex(x + 23)),
            ],
            Float64(x),
        )
        copied = copy(original)
        layout.is_function_set = true
        layout.scalar_affine = copied
        original.terms[1] =
            MOI.ScalarAffineTerm(9.0, MOI.VariableIndex(x + 29))
        stored = something(layout.scalar_affine)
        payload =
            Int64(stored.terms[1].coefficient) +
            stored.terms[1].variable.value +
            Int64(stored.constant)
        invariant_mask |= Int64(layout.single_variable === nothing) << 0
        invariant_mask |= Int64(
            stored.terms[1].coefficient == 2.0 &&
            stored.terms[1].variable == MOI.VariableIndex(x + 23),
        ) << 2
    elseif state == 3
        layout.is_function_set = true
        layout.single_variable = MOI.VariableIndex(x + 37)
        layout.is_function_set = false
        layout.single_variable = nothing
        layout.scalar_affine = MOI.ScalarAffineFunction(
            MOI.ScalarAffineTerm{Float64}[],
            Float64(x),
        )
        layout.scalar_affine = nothing
        invariant_mask |= Int64(
            !layout.is_function_set &&
            layout.single_variable === nothing &&
            layout.scalar_affine === nothing,
        ) << 3
        layout.is_function_set = true
        layout.single_variable = MOI.VariableIndex(x + 41)
        payload = something(layout.single_variable).value
        invariant_mask |= Int64(layout.scalar_affine === nothing) << 1
    else
        error("nullable layout selector must be in 0:3")
    end

    retained_leaf.value += state + 5
    payload += layout.leaf.value
    invariant_mask |= Int64(retained_leaf === layout.leaf) << 4
    invariant_mask |= Int64(layout.leaf.value == x + state + 5) << 5
    invariant_mask |= Int64(
        layout.is_function_set == (state != 0),
    ) << 6
    invariant_mask |= Int64(
        layout.is_sense_set == (state == 1) &&
        layout.sense == (state == 1 ? MOI.MIN_SENSE : MOI.FEASIBILITY_SENSE),
    ) << 7
    return payload * 256 + invariant_mask
end

const BOUNDARY_X = Int64[-2, -1, 0, 1, 2, 17]
const INPUTS = [
    (state, x)
    for state in Int64(0):Int64(3)
    for x in BOUNDARY_X
]

const EXPECTED = Dict(
    (Int64(0), Int64(-2)) => Int64(1011),
    (Int64(0), Int64(-1)) => Int64(1267),
    (Int64(0), Int64(0)) => Int64(1523),
    (Int64(0), Int64(1)) => Int64(1779),
    (Int64(0), Int64(2)) => Int64(2035),
    (Int64(0), Int64(17)) => Int64(5875),
    (Int64(1), Int64(-2)) => Int64(5618),
    (Int64(1), Int64(-1)) => Int64(6130),
    (Int64(1), Int64(0)) => Int64(6642),
    (Int64(1), Int64(1)) => Int64(7154),
    (Int64(1), Int64(2)) => Int64(7666),
    (Int64(1), Int64(17)) => Int64(15346),
    (Int64(2), Int64(-2)) => Int64(6901),
    (Int64(2), Int64(-1)) => Int64(7669),
    (Int64(2), Int64(0)) => Int64(8437),
    (Int64(2), Int64(1)) => Int64(9205),
    (Int64(2), Int64(2)) => Int64(9973),
    (Int64(2), Int64(17)) => Int64(21493),
    (Int64(3), Int64(-2)) => Int64(11770),
    (Int64(3), Int64(-1)) => Int64(12282),
    (Int64(3), Int64(0)) => Int64(12794),
    (Int64(3), Int64(1)) => Int64(13306),
    (Int64(3), Int64(2)) => Int64(13818),
    (Int64(3), Int64(17)) => Int64(21498),
)

const SOURCE_PROVENANCE = (
    math_opt_interface_version="1.51.2",
    git_tree_sha1="7b57dbe5d2c988a0c7a0ea977045e844e3d0b263",
    sources=(
        (
            file="src/Utilities/objective_container.jl",
            lines="13-44,163-238",
            operation="representative isbits and referenced-aggregate nullable objective slots with paired metadata and clear/set transitions",
        ),
    ),
    supplemental_runtime_stress=(
        "retained mutable child identity across nullable-slot transitions",
    ),
)

const CASES = Dict(
    "f1_nullable_objective_layout" => (
        f=f1_nullable_objective_layout,
        inputs=INPUTS,
        expected=EXPECTED,
        property=:bounded_deterministic,
        provenance=SOURCE_PROVENANCE,
    ),
)

end
