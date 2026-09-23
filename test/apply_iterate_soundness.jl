function _wt_runtime_tuple_empty(v::Vector{Int64})::Int32
    t = (v...,)
    return t isa Tuple{} ? Int32(1) : Int32(0)
end


function _wt_runtime_tuple_index(v::Vector{Int64}, i::Int64)::Int64
    t = (v...,)
    return t[i] + length(t)
end

_wt_multi_splat_add(a::Vector{Int64}, b::Vector{Int64})::Int64 = +(a..., b...)
_wt_multi_splat_mul(a::Vector{Float64}, b::Vector{Float64})::Float64 = *(a..., b...)

module _WTNamedPlus
    +(xs::Int64...) = Core.Intrinsics.add_int(Int64(100), Int64(length(xs)))
end
_wt_same_name_not_base(a::Vector{Int64}, b::Vector{Int64})::Int64 =
    _WTNamedPlus.:+(a..., b...)

function _wt_empty_splat_methoderror(a::Vector{Int64}, b::Vector{Int64})::Int32
    try
        +(a..., b...)
        return Int32(0)
    catch err
        return err isa MethodError ? Int32(1) : Int32(2)
    end
end

function _wt_empty_splat_methoderror_payload(a::Vector{Int64}, b::Vector{Int64})::Int32
    try
        +(a..., b...)
        return Int32(0)
    catch err
        err isa MethodError || return Int32(-1)
        score = err.f === (+) ? Int32(1) : Int32(0)
        score += err.args === () ? Int32(2) : Int32(0)
        score += err.world != typemax(UInt64) ? Int32(4) : Int32(0)
        return score
    end
end

# --- Phase 12 H: `f(t...)` with `t` a RUNTIME-LENGTH Vararg tuple -----------
# The callee's own trailing `Vararg{E}` parameter IS `t`'s {Object, data, size}
# representation, so this is a direct call, not an iteration
# (parity(quarantine: Julia varargs) — dart has no runtime-length parameter list).
@noinline _wt_va_sum(xs::Int64...)::Int64 = (s = 0; for x in xs; s += x; end; s)
@noinline _wt_va_maxf(xs::Float64...)::Float64 = (m = -Inf; for x in xs; x > m && (m = x); end; m)
# the three spellings of the same splat target — the arm resolves the callee OBJECT,
# so `Core.tuple` (the builtin value) and `tuple` (a Main GlobalRef) lower like `Tuple`
@noinline _wt_va_mk_value(v::Vector{Int64}) = Core.tuple(v...)
@noinline _wt_va_mk_globalref(v::Vector{Int64}) = tuple(v...)
@noinline _wt_va_mk_ctor(v::Vector{Int64}) = Tuple(v)
@noinline _wt_va_mkf(v::Vector{Float64}) = tuple(v...)
# a non-empty narrowing Tuple{T, Vararg{T}} — the same canonical layout
@noinline _wt_va_mk_nonempty(v::Vector{Int64}) = (t = Core.tuple(v...); isempty(t) ? (0,) : t)
# NO vararg specialization: two arity-specific methods, so the open-ended signature
# has no single static target and the splat must stay a loud reject
@noinline _wt_va_two_arity(a::Int64)::Int64 = a
@noinline _wt_va_two_arity(a::Int64, b::Int64)::Int64 = a + b

_wt_va_splat_value(v::Vector{Int64})::Int64 = _wt_va_sum(_wt_va_mk_value(v)...)
_wt_va_splat_globalref(v::Vector{Int64})::Int64 = _wt_va_sum(_wt_va_mk_globalref(v)...)
_wt_va_splat_ctor(v::Vector{Int64})::Int64 = _wt_va_sum(_wt_va_mk_ctor(v)...)
_wt_va_splat_nonempty(v::Vector{Int64})::Int64 = _wt_va_sum(_wt_va_mk_nonempty(v)...)
_wt_va_splat_float(v::Vector{Float64})::Float64 = _wt_va_maxf(_wt_va_mkf(v)...)
_wt_va_splat_no_vararg(v::Vector{Int64})::Int64 = _wt_va_two_arity(_wt_va_mk_value(v)...)

@testset "_apply_iterate over a runtime Vararg tuple" begin
    for f in (_wt_va_splat_value, _wt_va_splat_globalref, _wt_va_splat_ctor)
        @test compare_julia_wasm_vec(f, Int64[]).pass
        @test compare_julia_wasm_vec(f, Int64[7]).pass
        @test compare_julia_wasm_vec(f, Int64[1, 2, 3, 4]).pass
    end
    @test compare_julia_wasm_vec(_wt_va_splat_nonempty, Int64[1, 2, 3]).pass
    @test compare_julia_wasm_vec(_wt_va_splat_float, Float64[1.5, -2.0, 9.25]).pass

    # the callee IS in the plan, with the packed {Object, data, size} parameter —
    # ONE physical parameter, not a flattened tail
    plan, _ = WasmTarget.trim_compile_plan(
        Any[(_wt_va_splat_value, (Vector{Int64},), "f")])
    @test any(e -> e[1] === _wt_va_sum && e[2] == (Tuple{Vararg{Int64}},), plan)

    # correct or loud: no single static target ⇒ reject, never a guessed arity
    err = try
        WasmTarget.compile(_wt_va_splat_no_vararg, (Vector{Int64},))
        nothing
    catch caught
        caught
    end
    @test err isa WasmTarget.WasmCompileError
    @test occursin("runtime Vararg tuple", sprint(showerror, err))
end

@testset "_apply_iterate runtime Vararg tuple" begin
    @test WasmTarget.is_runtime_vararg_tuple_type(Tuple{Vararg{Int64}})
    @test !WasmTarget.is_runtime_vararg_tuple_type(Tuple)
    # a non-empty narrowing of the same homogeneous layout (a typeassert/PiNode after
    # `isempty` is ruled out) shares the canonical runtime representation
    @test WasmTarget.is_runtime_vararg_tuple_type(Tuple{Int64,Vararg{Int64}})
    @test WasmTarget.runtime_vararg_canonical(Tuple{Int64,Vararg{Int64}}) === Tuple{Vararg{Int64}}
    @test !WasmTarget.is_runtime_vararg_tuple_type(Tuple{Float64,Vararg{Int64}})
    @test compare_julia_wasm_vec(_wt_runtime_tuple_empty, Int64[]).pass
    @test compare_julia_wasm_vec(_wt_runtime_tuple_empty, Int64[1]).pass
    @test compare_julia_wasm_vec(_wt_runtime_tuple_empty, Int64[1, 2, 3]).pass
    @test compare_julia_wasm_vec(_wt_runtime_tuple_index, Int64[10, 20, 30], Int64(2)).pass
    @test compare_julia_wasm_vec(_wt_multi_splat_add, Int64[1, 2], Int64[3, 4]).pass
    @test compare_julia_wasm_vec(_wt_multi_splat_mul, Float64[2, 3], Float64[4]).pass
    @test compare_julia_wasm_vec(_wt_empty_splat_methoderror, Int64[], Int64[]).pass
    @test compare_julia_wasm_vec(_wt_empty_splat_methoderror, Int64[1], Int64[]).pass
    @test compare_julia_wasm_vec(_wt_empty_splat_methoderror_payload, Int64[], Int64[]).pass

    err = try
        WasmTarget.compile(_wt_same_name_not_base, (Vector{Int64}, Vector{Int64}))
        nothing
    catch caught
        caught
    end
    @test err isa WasmTarget.WasmCompileError
    @test occursin("unsupported operator/target", sprint(showerror, err))
end
