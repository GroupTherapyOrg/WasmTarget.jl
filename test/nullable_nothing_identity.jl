using Test

mutable struct _WTNullableIdentityLeaf
    value::Int64
end

mutable struct _WTNullableIdentityAggregate
    values::Vector{Int64}
end

mutable struct _WTNullableIdentityHolder
    leaf::Union{Nothing,_WTNullableIdentityLeaf}
    aggregate::Union{Nothing,_WTNullableIdentityAggregate}
end

const _WT_GLOBAL_NOTHING = nothing
const _WT_GLOBAL_IDENTITY_LEAF = _WTNullableIdentityLeaf(29)

macro _wt_nullable_pair_mask(leaf, aggregate)
    return esc(quote
        (Int64($leaf === nothing) << 0) |
        (Int64(nothing === $leaf) << 1) |
        (Int64($leaf !== nothing) << 2) |
        (Int64(nothing !== $leaf) << 3) |
        (Int64($aggregate === nothing) << 4) |
        (Int64(nothing === $aggregate) << 5) |
        (Int64($aggregate !== nothing) << 6) |
        (Int64(nothing !== $aggregate) << 7)
    end)
end

function _wt_identity_mask(value)::Int64
    return (
        (Int64(value === nothing) << 0) |
        (Int64(nothing === value) << 1) |
        (Int64(value !== nothing) << 2) |
        (Int64(nothing !== value) << 3)
    )
end

function _wt_global_nullable_alias_identity()::Int64
    leaf::Union{Nothing,_WTNullableIdentityLeaf} = _WT_GLOBAL_NOTHING
    aggregate::Union{Nothing,_WTNullableIdentityAggregate} =
        _WT_GLOBAL_NOTHING
    return _wt_identity_mask(leaf) | (_wt_identity_mask(aggregate) << 4)
end

# Keep two distinct nullable reference families live across control flow. Julia's
# optimized IR represents the cleared slots as standalone GlobalRefs typed with
# their widened Union, which is the exact storage boundary this regression guards.
function _wt_globalref_nullable_boundary(state::Int64, x::Int64)::Int64
    holder = _WTNullableIdentityHolder(nothing, nothing)
    payload = Int64(0)
    mask = Int64(0)
    if state == 1
        holder.leaf = _WTNullableIdentityLeaf(x)
        payload = something(holder.leaf).value
        leaf = holder.leaf
        aggregate = holder.aggregate
        mask = @_wt_nullable_pair_mask(leaf, aggregate)
    elseif state == 2
        holder.aggregate = _WTNullableIdentityAggregate(Int64[x])
        payload = something(holder.aggregate).values[1]
        leaf = holder.leaf
        aggregate = holder.aggregate
        mask = @_wt_nullable_pair_mask(leaf, aggregate)
    elseif state == 3
        holder.leaf = _WTNullableIdentityLeaf(x)
        holder.aggregate = _WTNullableIdentityAggregate(Int64[x])
        holder.leaf = nothing
        holder.aggregate = nothing
        leaf = holder.leaf
        aggregate = holder.aggregate
        mask = @_wt_nullable_pair_mask(leaf, aggregate)
    else
        leaf = holder.leaf
        aggregate = holder.aggregate
        mask = @_wt_nullable_pair_mask(leaf, aggregate)
    end
    return payload * 256 + mask
end

# The expected-aware GlobalRef materializer must also preserve a live mutable
# global's concrete value and field access when its SSA local is widened.
function _wt_globalref_live_reference_boundary(state::Int64)::Int64
    holder = _WTNullableIdentityHolder(_WT_GLOBAL_IDENTITY_LEAF, nothing)
    leaf = something(holder.leaf)
    return leaf.value + state
end

function _wt_nullable_field_identity(state::Int64)::Int64
    holder = _WTNullableIdentityHolder(nothing, nothing)
    if state == 1
        holder.leaf = _WTNullableIdentityLeaf(17)
    elseif state == 2
        holder.aggregate = _WTNullableIdentityAggregate(Int64[2, 3])
    elseif state == 3
        holder.leaf = _WTNullableIdentityLeaf(19)
        holder.aggregate = _WTNullableIdentityAggregate(Int64[5])
        holder.leaf = nothing
        holder.aggregate = nothing
    end
    return _wt_identity_mask(holder.leaf) |
           (_wt_identity_mask(holder.aggregate) << 4)
end

function _wt_any_nothing_identity(state::Int64)::Int64
    value::Any =
        state == 0 ? nothing :
        state == 1 ? _WTNullableIdentityLeaf(23) :
        _WTNullableIdentityAggregate(Int64[7, 11])
    return _wt_identity_mask(value)
end

function _wt_literal_and_numeric_nothing_identity()::Int64
    literal_mask =
        (Int64(nothing === nothing) << 0) |
        (Int64(nothing !== nothing) << 1) |
        (Int64(_WT_GLOBAL_NOTHING === nothing) << 2) |
        (Int64(nothing === _WT_GLOBAL_NOTHING) << 3)
    zero_mask =
        (Int64(Int64(0) === nothing) << 4) |
        (Int64(nothing === Int64(0)) << 5) |
        (Int64(Int64(0) !== nothing) << 6) |
        (Int64(nothing !== Int64(0)) << 7)
    return literal_mask | zero_mask
end

@testset "nullable reference identity preserves semantic nothing" begin
    alias = compare_julia_wasm_both(_wt_global_nullable_alias_identity)
    @test alias.expected == 0x33
    @test alias.raw_actual == 0x33
    @test alias.opt_actual == 0x33

    # Refuse to let future Julia optimization silently erase the precise compiler
    # boundary under test: widened GlobalRef-nothing SSA values and both operand
    # orders of identity must remain present in this fixture's optimized IR.
    boundary_ir = only(code_typed(
        _wt_globalref_nullable_boundary,
        (Int64, Int64);
        optimize=true,
    )).first
    widened_nothing = [
        index for (index, statement) in enumerate(boundary_ir.code)
        if statement isa GlobalRef &&
           statement.name === :nothing &&
           boundary_ir.ssavaluetypes[index] isa Union
    ]
    identity_calls = [
        statement for statement in boundary_ir.code
        if statement isa Expr &&
           statement.head === :call &&
           first(statement.args) isa GlobalRef &&
           first(statement.args).mod === Core &&
           first(statement.args).name === :(===)
    ]
    @test length(widened_nothing) >= 2
    @test any(
        first(call.args[2:end]) isa Core.SSAValue &&
        last(call.args[2:end]) isa GlobalRef
        for call in identity_calls
    )
    @test any(
        first(call.args[2:end]) isa GlobalRef &&
        last(call.args[2:end]) isa Core.SSAValue
        for call in identity_calls
    )

    expected_boundary = Int64[0x33, 0x3c, 0xc3, 0x33]
    for state in Int64(0):Int64(3)
        result = compare_julia_wasm_both(
            _wt_globalref_nullable_boundary,
            state,
            Int64(17),
        )
        expected = (state in (1, 2) ? 17 * 256 : 0) +
                   expected_boundary[state + 1]
        @test result.expected == expected
        @test result.raw_actual == expected
        @test result.opt_actual == expected
    end

    live_ir = only(code_typed(
        _wt_globalref_live_reference_boundary,
        (Int64,);
        optimize=true,
    )).first
    @test any(
        statement isa GlobalRef &&
        statement.name === :_WT_GLOBAL_IDENTITY_LEAF &&
        live_ir.ssavaluetypes[index] isa Union
        for (index, statement) in enumerate(live_ir.code)
    )
    for (state, expected) in ((Int64(0), Int64(29)), (Int64(1), Int64(30)))
        result = compare_julia_wasm_both(
            _wt_globalref_live_reference_boundary,
            state,
        )
        @test result.expected == expected
        @test result.raw_actual == expected
        @test result.opt_actual == expected
    end

    for state in Int64(0):Int64(3)
        result = compare_julia_wasm_both(
            _wt_nullable_field_identity,
            state,
        )
        expected = state in (0, 3) ? Int64(0x33) :
                   state == 1 ? Int64(0x3c) : Int64(0xc3)
        @test result.expected == expected
        @test result.raw_actual == expected
        @test result.opt_actual == expected
    end
    for state in Int64(0):Int64(2)
        result = compare_julia_wasm_both(_wt_any_nothing_identity, state)
        expected = state == 0 ? Int64(0x03) : Int64(0x0c)
        @test result.expected == expected
        @test result.raw_actual == expected
        @test result.opt_actual == expected
    end
    literal = compare_julia_wasm_both(
        _wt_literal_and_numeric_nothing_identity,
    )
    @test literal.expected == 0x0cd
    @test literal.raw_actual == 0x0cd
    @test literal.opt_actual == 0x0cd
end
