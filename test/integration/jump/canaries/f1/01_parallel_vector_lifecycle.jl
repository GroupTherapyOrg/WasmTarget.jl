module JumpF1ParallelVectorCanaries

const DELETED_VARIABLE = UInt16(0x8000)

"""
An isolating surrogate for the three parallel vectors used by pinned
`MOI.Utilities.VariablesContainer{Float64}`.

This does not call or certify `VariablesContainer`. It certifies only the
listed ordinary-Vector mechanisms on its exact concrete field topology.
"""
mutable struct ParallelVariableLayout
    set_mask::Vector{UInt16}
    lower::Vector{Float64}
    upper::Vector{Float64}
end

ParallelVariableLayout() =
    ParallelVariableLayout(UInt16[], Float64[], Float64[])

function _bound_code(value::Float64)::Int64
    value == -Inf && return Int64(-99991)
    value == Inf && return Int64(99991)
    # The finite canary values are exact binary quarters. Scaling before the
    # integer checksum makes loss of their fractional component observable.
    return Int64(value * 4.0)
end

function _layout_checksum(layout::ParallelVariableLayout)::Int64
    length(layout.set_mask) == length(layout.lower) == length(layout.upper) ||
        return Int64(-1)
    checksum = Int64(17 + 31 * length(layout.set_mask))
    active = Int64(0)
    for i in eachindex(layout.set_mask)
        mask = layout.set_mask[i]
        if mask != DELETED_VARIABLE
            active += 1
            checksum +=
                Int64(mask) * 3 +
                _bound_code(layout.lower[i]) * 5 +
                _bound_code(layout.upper[i]) * 7 +
                Int64(i) * 11
        end
    end
    return checksum * 64 + active
end

function f1_parallel_variable_layout(mode::Int64, n::Int64)::Int64
    n >= 0 || error("n must be nonnegative")
    layout = ParallelVariableLayout()
    for i in Int64(1):n
        # Match MOI.add_variable: no active set and the AbstractFloat
        # no-bound sentinels are -Inf/Inf.
        push!(layout.set_mask, UInt16(0))
        push!(layout.lower, -Inf)
        push!(layout.upper, Inf)
    end

    if mode == 0
        # Baseline aligned growth and filtered enumeration.
    elseif mode == 1
        if n > 0
            i = Int(cld(n, 2))
            layout.set_mask[i] = DELETED_VARIABLE
        end
    elseif mode == 2
        copied = ParallelVariableLayout(
            copy(layout.set_mask),
            copy(layout.lower),
            copy(layout.upper),
        )
        if n > 0
            layout.set_mask[1] = DELETED_VARIABLE
            layout.lower[1] = -77.25
            layout.upper[1] = 88.75
        end
        return _layout_checksum(layout) * 1000003 +
               _layout_checksum(copied)
    elseif mode == 3
        retained = Int(n ÷ 2)
        resize!(layout.set_mask, retained)
        resize!(layout.lower, retained)
        resize!(layout.upper, retained)
        target = Int(n + 3)
        resize!(layout.set_mask, target)
        resize!(layout.lower, target)
        resize!(layout.upper, target)
        # Julia resize! growth is undef. Assign every new slot before reading.
        for i in (retained + 1):target
            layout.set_mask[i] = UInt16(0)
            layout.lower[i] = -Inf
            layout.upper[i] = Inf
        end
    elseif mode == 4
        empty!(layout.set_mask)
        empty!(layout.lower)
        empty!(layout.upper)
    elseif mode == 5
        # Model successful indexed constraint-bound mutation with exact
        # fractional values, so Float64 storage cannot pass as integer-only.
        for i in eachindex(layout.set_mask)
            layout.set_mask[i] = UInt16(i % 8)
            layout.lower[i] = Float64(i) + 0.25
            layout.upper[i] = Float64(2i) + 0.75
        end
    else
        error("mode must be in 0:5")
    end
    return _layout_checksum(layout)
end

mutable struct VectorLeaf
    value::Int64
end

function _leaf_checksum(values::Vector{VectorLeaf})::Int64
    checksum = Int64(19 + 23 * length(values))
    for i in eachindex(values)
        checksum += values[i].value * Int64(29 + i)
    end
    return checksum
end

"""
Supplemental ordinary-Vector identity stress. This certifies wrapper aliases
and surviving mutable-element identity, not GC reclamation or physical backing
identity.
"""
function f1_vector_reference_lifecycle(mode::Int64, n::Int64)::Int64
    n >= 0 || error("n must be nonnegative")
    values = VectorLeaf[]
    for i in Int64(1):n
        push!(values, VectorLeaf(10i))
    end
    alias = values
    retained = n > 0 ? values[1] : VectorLeaf(-5)
    identity_mask = Int64(alias === values) << 0

    if mode == 0
        push!(values, VectorLeaf(10n + 7))
        insert!(values, 1, VectorLeaf(-11))
        identity_mask |= Int64(alias === values) << 1
        identity_mask |= Int64(n == 0 || values[2] === retained) << 2
    elseif mode == 1
        if n > 0
            deleteat!(values, Int(cld(n, 2)))
        end
        pushfirst!(values, VectorLeaf(-13))
        first_value = popfirst!(values)
        push!(values, first_value)
        if !isempty(values)
            popped = pop!(values)
            push!(values, popped)
        end
        identity_mask |= Int64(alias === values) << 1
        identity_mask |=
            Int64(n == 0 || retained in values || cld(n, 2) == 1) << 2
    elseif mode == 2
        copied = copy(values)
        identity_mask |= Int64(copied !== values) << 1
        if n > 0
            identity_mask |= Int64(copied[1] === retained) << 2
            retained.value += 3
            identity_mask |= Int64(copied[1].value == values[1].value) << 3
            values[1] = VectorLeaf(-17)
            identity_mask |= Int64(copied[1] === retained) << 4
        end
        return (_leaf_checksum(values) * 1000003 +
                _leaf_checksum(copied)) * 64 + identity_mask
    elseif mode == 3
        original = copy(values)
        append!(values, values)
        identity_mask |= Int64(alias === values) << 1
        identity_mask |= Int64(length(values) == 2length(original)) << 2
        all_identity = true
        for i in eachindex(original)
            all_identity &=
                values[i] === original[i] &&
                values[i + length(original)] === original[i]
        end
        identity_mask |= Int64(all_identity) << 3
    else
        error("mode must be in 0:3")
    end
    return _leaf_checksum(values) * 64 + identity_mask
end

const BOUNDARY_N =
    Int64[0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 32, 33]

const PARALLEL_INPUTS = [
    (mode, n)
    for mode in Int64(0):Int64(5)
    for n in BOUNDARY_N
]

const REFERENCE_INPUTS = [
    (mode, n)
    for mode in Int64(0):Int64(3)
    for n in BOUNDARY_N
]

# These values are a committed oracle, generated once from pinned native Julia
# and independently checked by the promotion verifier on every platform.
const PARALLEL_EXPECTED_VALUES = Int64[
    1088, 12802625, 25604866, 38407811, 89626631, 102433096, 115240265,
    192098063, 204910160, 217722961, 397176095, 409999456, 422823521,
    1088, 3072, 12805313, 25607554, 76824966, 89631431, 102437896,
    179293582, 192105679, 204917776, 384365982, 397189343, 410012704,
    1088004352, 3084811841, 12805377020805, 25608373232585,
    76827398107865, 89633914333725, 102441134562401, 179299239993593,
    192111388241981, 204924240493185, 384378092305721,
    397201504599165, 410025620895425,
    38407811, 51211460, 64015813, 76820870, 128048138, 140856715,
    153665996, 230536466, 243350675, 256165588, 435648290, 448473763,
    461299940,
    1088, 1088, 1088, 1088, 1088, 1088, 1088, 1088, 1088, 1088, 1088,
    1088, 1088,
    1088, 10497, 25666, 46595, 187911, 236104, 290057, 734735, 827472,
    925969, 2897439, 3079264, 3266849,
]

const REFERENCE_EXPECTED_VALUES = Int64[
    -3065, 39175, 103815, 192135, 807815, 1033735, 1291015, 3564935,
    4077575, 4631815, 17475975, 18807815, 20201735,
    -22265, -22265, 16775, 57735, 494855, 679815, 872455, 2764295,
    3215495, 3682055, 15177735, 16407175, 17667335,
    1216004867, -29952062177, 11200102431, 74112354079, 568962333471,
    759875097119, 980227978527, 2992268026655, 3454541875743,
    3956495883551, 15867071525663, 17117828528671, 18428745772319,
    1231, 43215, 128719, 262223, 1365839, 1806543, 2322127, 7238991,
    8404175, 9680079, 41677135, 45151439, 48808143,
]

const PARALLEL_EXPECTED =
    Dict(PARALLEL_INPUTS .=> PARALLEL_EXPECTED_VALUES)
const REFERENCE_EXPECTED =
    Dict(REFERENCE_INPUTS .=> REFERENCE_EXPECTED_VALUES)

const SOURCE_PROVENANCE = (
    math_opt_interface_version="1.51.2",
    git_tree_sha1="7b57dbe5d2c988a0c7a0ea977045e844e3d0b263",
    sources=(
        (
            file="src/Utilities/variables_container.jl",
            lines="164-248,258-307,338-360,392-403",
            operation="three-parallel-vector topology; aligned growth with AbstractFloat no-bound sentinels; indexed fractional bound and mask mutation; tombstone deletion; filtered enumeration; resize and empty prerequisites",
        ),
    ),
    supplemental_runtime_stress=(
        "ordinary Vector wrapper alias identity across backing replacement",
        "surviving mutable-element identity and shallow structural copy",
        "generic Vector mutation including self-append follows native Julia rather than Dart semantics",
    ),
    exclusions=(
        "actual VariablesContainer execution",
        "GC reclamation, WeakRef, finalizers, or physical backing identity",
        "append! conversion-failure partial-mutation and exception transport; this stage certifies successful convertible inputs only",
    ),
)

const CASES = Dict(
    "f1_parallel_variable_layout" => (
        f=f1_parallel_variable_layout,
        inputs=PARALLEL_INPUTS,
        expected=PARALLEL_EXPECTED,
        property=:bounded_deterministic,
        provenance=SOURCE_PROVENANCE,
    ),
    "f1_vector_reference_lifecycle" => (
        f=f1_vector_reference_lifecycle,
        inputs=REFERENCE_INPUTS,
        expected=REFERENCE_EXPECTED,
        property=:bounded_deterministic,
        provenance=SOURCE_PROVENANCE,
    ),
)

end
