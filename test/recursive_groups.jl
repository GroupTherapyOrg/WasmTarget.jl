# Types whose fields reach back to themselves register with their strongly connected
# component (finish_pending!, dev/formal/RecGroup.tla): every field keeps its exact type and
# the component is one recursion group of the type section (recursion_groups).
mutable struct _WTDirectRecursive
    value::Int64
    next::_WTDirectRecursive
    _WTDirectRecursive(value::Int64) = new(value)
end

mutable struct _WTVectorRecursive
    value::Int64
    children::Vector{_WTVectorRecursive}
end

# a two-type cycle through a type parameter: A{B}.b holds a B, B.a holds an A{B}
mutable struct _WTMutualA{T}
    b::Union{Nothing, T}
    x::Int64
end
mutable struct _WTMutualB
    a::_WTMutualA{_WTMutualB}
    y::Int64
end

# a cycle through a tuple field
mutable struct _WTTupleRecursive
    t::Union{Nothing, Tuple{_WTTupleRecursive, Int64}}
    v::Int64
end

@noinline _wt_make_direct_recursive(value::Int64) = _WTDirectRecursive(value)
@noinline _wt_make_vector_recursive(value::Int64) =
    _WTVectorRecursive(value, _WTVectorRecursive[])
_wt_direct_recursive(value::Int64)::Int64 = _wt_make_direct_recursive(value).value
_wt_vector_recursive(value::Int64)::Int64 = _wt_make_vector_recursive(value).value
function _wt_mutual_recursive(n::Int64)::Int64
    a = _WTMutualA{_WTMutualB}(nothing, n)
    b = _WTMutualB(a, n + 1)
    a.b = b
    return a.b.a.x + a.b.y
end
function _wt_tuple_recursive(n::Int64)::Int64
    leaf = _WTTupleRecursive(nothing, n)
    root = _WTTupleRecursive((leaf, 2n), 1)
    t = root.t::Tuple{_WTTupleRecursive, Int64}
    return root.v + t[1].v + t[2]
end

# the wasm struct field holding Julia field `f` of `T`
function _wt_field_ref(mod, reg, T, f::Symbol)
    info = reg.structs[T]
    return mod.types[info.wasm_type_idx + 1].fields[WasmTarget.wasm_field_idx(info, Base.fieldindex(T, f)) + 1].valtype
end

@testset "Wasm recursive type groups" begin
    @test compare_julia_wasm(_wt_direct_recursive, Int64(41)).pass
    @test compare_julia_wasm(_wt_vector_recursive, Int64(42)).pass
    @test compare_julia_wasm(_wt_mutual_recursive, Int64(5)).pass
    @test compare_julia_wasm(_wt_tuple_recursive, Int64(4)).pass

    mod, reg, _, _ = WasmTarget.compile_module(
        Any[(_wt_make_vector_recursive, (Int64,), "_wt_make_vector_recursive"),
            (_wt_mutual_recursive, (Int64,), "_wt_mutual_recursive")];
        return_registries=true)
    groups = WasmTarget.recursion_groups(mod)
    @test all(g -> !isempty(g), groups) && sum(length, groups) == length(mod.types)
    idx(T) = Int(reg.structs[T].wasm_type_idx)
    group(T) = only(g for g in groups if idx(T) in g)
    # the Vector-recursive struct, its Vector wrapper and its array are one group
    @test group(_WTVectorRecursive) == group(Vector{_WTVectorRecursive})
    @test length(group(_WTVectorRecursive)) == 3
    # the mutual pair is one group, and each field is the other's exact type (placeholder-and-
    # patch erased one of them to structref)
    A = _WTMutualA{_WTMutualB}
    @test group(A) == group(_WTMutualB) && length(group(A)) == 2
    @test _wt_field_ref(mod, reg, A, :b) == WasmTarget.ConcreteRef(UInt32(idx(_WTMutualB)), true)
    @test _wt_field_ref(mod, reg, _WTMutualB, :a) == WasmTarget.ConcreteRef(UInt32(idx(A)), true)
    @test isempty(reg.pending.stack)
    @test validate_wasm(WasmTarget.to_bytes(mod))
end
