# ═══════════════════════════════════════════════════════════════════════════
# march16: FIRST-CLASS CLOSURES — trampolines + vtable globals
# (dart ClosureLayouter/ClosureRepresentation, closures.dart:41-118;
#  the closure object = {classId, context, vtable}, class_info.dart FieldIndex)
# ═══════════════════════════════════════════════════════════════════════════

"""
    ensure_closure_vtable!(mod, registry, closure_type, body_idx, body_params, body_results)
        -> (vtable_global_idx, vtable_struct_idx)

One immutable vtable GLOBAL per closure body. Its single populated entry (the
body's positional arity) is a TRAMPOLINE: (closureBase-as-anyref, args...) →
cast base → context → cast captured struct → call body. dart: the vtable entry
at vtableBaseIndex + posArgCount (closures.dart:105-118).

`body_params` = the body's wasm param types WITH the closure self at slot 0
(the captured-struct ref); the trampoline's public args are body_params[2:end].
"""
function ensure_closure_vtable!(mod::WasmModule, registry::TypeRegistry,
                                closure_type::Type, body_idx::UInt32,
                                body_params::Vector{WasmValType},
                                body_results::Vector{WasmValType})::Tuple{UInt32, UInt32}
    cache = registry.closure_vtable_globals
    cache === nothing && error("closure layouter unavailable on a minimal registry")
    key = closure_type   # T-keyed: the wrap looks up by type alone
    if haskey(cache, key)
        cached = cache[key]
        return (cached, get_closure_vtable_struct!(mod, registry, length(body_params) - 1))
    end

    arity = length(body_params) - 1          # public args (minus the closure self)
    base_idx = get_closure_base_struct!(mod, registry)
    vt_struct = get_closure_vtable_struct!(mod, registry, arity)
    captured_info = get(registry.structs, closure_type, nothing)
    captured_info === nothing && error("closure type not registered: $closure_type")

    # ── the trampoline: the UNIFORM DYNAMIC SIGNATURE (anyref^(1+arity)) → anyref
    # (dart's dynamic-call entries: args arrive boxed/erased; the trampoline
    # unboxes/casts per the body's REAL signature and re-boxes the result).
    tb = InstrBuilder(; func_name="closure_trampoline", mod=mod)
    local_get!(tb, UInt32(0))
    ref_cast!(tb, Int64(base_idx), false)
    struct_get!(tb, base_idx, UInt32(1), AnyRef)               # .context
    ref_cast!(tb, Int64(captured_info.wasm_type_idx), false)   # the captured struct
    for j in 1:arity
        local_get!(tb, UInt32(j))
        local pt = body_params[j + 1]
        if pt in (I32, I64, F32, F64)
            emit_classid_unbox!(tb, mod, registry, pt)
        elseif pt isa ConcreteRef
            ref_cast!(tb, Int64(pt.type_idx), pt.nullable)
        end   # anyref/eq/struct params take the value as-is
    end
    call!(tb, body_idx, WasmValType[], body_results)
    if !isempty(body_results) && body_results[1] in (I32, I64, F32, F64)
        # re-box the numeric result (inline shape — no ctx here; scratch local 1+arity)
        local rw = body_results[1]
        local box_idx = get_numeric_box_type!(mod, registry, rw)
        local scratch = UInt32(1 + arity)
        local_set!(tb, scratch)
        i32_const!(tb, Int64(0))          # width-default classId (un-migrated callers discriminate by width)
        local_get!(tb, scratch)
        struct_new!(tb, box_idx)
        tramp_locals = WasmValType[rw]
    else
        tramp_locals = WasmValType[]
    end
    end_block!(tb)   # the function frame's own end
    tramp_params = WasmValType[AnyRef for _ in 0:arity]
    tramp_results = isempty(body_results) ? WasmValType[] : WasmValType[AnyRef]
    tramp_idx = add_function!(mod, tramp_params, tramp_results, tramp_locals, builder_code(tb))
    declare_funcs!(mod, UInt32[tramp_idx])

    # ── the vtable global: entries 0..arity-1 null, entry[arity] = the trampoline ──
    init = UInt8[]
    for _ in 0:(arity - 1)
        push!(init, 0xD0)                                       # ref.null
        push!(init, 0x70)                                       # funcref heap type
    end
    push!(init, Opcode.REF_FUNC)
    append!(init, encode_leb128_unsigned(UInt64(tramp_idx)))
    push!(init, Opcode.GC_PREFIX, 0x00)                          # struct.new
    append!(init, encode_leb128_unsigned(UInt64(vt_struct)))
    g = add_global_ref!(mod, vt_struct, false, init; nullable=false)
    cache[key] = g
    return (g, vt_struct)
end

"""
    emit_closure_wrap!(b, ctx, closure_type, body_idx, body_params, body_results)

The captured struct is ON THE STACK; wraps it into the closure OBJECT
{classId, context, vtable} (dart's implicit function-value creation at the
erasure seam — convertType when a closure meets a top type).
"""
function emit_closure_wrap!(b::InstrBuilder, ctx, closure_type::Type, body_idx::UInt32,
                            body_params::Vector{WasmValType}, body_results::Vector{WasmValType})
    base_idx = get_closure_base_struct!(ctx.mod, ctx.type_registry)
    # POST-FREEZE: lookup only — the pre-pass created the vtable; creating here
    # would add functions mid-body-compile (the PURE-9065 skew).
    local cache = ctx.type_registry.closure_vtable_globals
    (cache !== nothing && haskey(cache, closure_type)) || return nothing
    g, _ = ensure_closure_vtable!(ctx.mod, ctx.type_registry, closure_type, body_idx,
                                  body_params, body_results)
    # stack: [captured] → {classId, captured-as-context, vtable}
    local ctx_scratch = allocate_local!(ctx, AnyRef)
    local_set!(b, UInt32(ctx_scratch))
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, closure_type)))
    local_get!(b, UInt32(ctx_scratch))
    global_get!(b, g, ConcreteRef(get_closure_vtable_struct!(ctx.mod, ctx.type_registry, length(body_params) - 1), false))
    struct_new!(b, base_idx)
    return ConcreteRef(base_idx, false)
end


"""
    _closure_body_for(ctx, closure_type) -> (body_idx, body_params, body_results) | nothing

The compiled body whose SELF param is `closure_type` (WT closures take the
captured struct as arg 1). Reads the wasm signature from the module.
"""
function _closure_body_for(ctx, closure_type::Type)
    fr = ctx.func_registry
    fr === nothing && return nothing
    for (k, info) in fr.functions
        # keyed by the closure TYPE (capturing closures have no instance; compile.jl
        # registers their MI-compiled bodies under func_ref = the DataType)
        # PRECISE match only: the type-keyed registration (the arg_types[1]
        # heuristic once matched throw_boundserror taking the closure as arg 1)
        info.func_ref === closure_type || continue
        # derive the wasm signature from the REGISTRATION (Julia types) — at wrap
        # time the body may not be pushed into mod.functions yet (indices are
        # assigned before bodies compile)
        local ps = WasmValType[]
        for T in info.arg_types
            push!(ps, get_concrete_wasm_type(T, ctx.mod, ctx.type_registry))
        end
        local rs = (info.return_type === Nothing || info.return_type === Union{}) ?
                   WasmValType[] :
                   WasmValType[get_concrete_wasm_type(info.return_type, ctx.mod, ctx.type_registry)]
        return (info.wasm_idx, ps, rs)
    end
    return nothing
end

"""
    maybe_wrap_closure!(b, ctx, from_julia) -> Bool

The ERASURE seam (dart convertType: a closure meeting a top type becomes the
closure OBJECT). The captured struct is on the stack; when `from_julia` is a
registered closure type with a compiled body, wrap. Returns whether it wrapped.
"""
function maybe_wrap_closure!(b::InstrBuilder, ctx, from_julia)::Bool
    from_julia isa DataType || return false
    is_closure_type(from_julia) || return false
    haskey(ctx.type_registry.structs, from_julia) || return false
    local body = _closure_body_for(ctx, from_julia)
    haskey(ENV, "WT_DBG_DYN") && println(stderr, "WRAP-CHECK t=", from_julia, " body=", body === nothing ? "NONE" : "found")
    body === nothing && return false
    return emit_closure_wrap!(b, ctx, from_julia, body[1], body[2], body[3]) !== nothing
end


"""
    emit_dynamic_closure_call!(b, ctx, func, args, idx) -> Bool

march16 slice D: the DYNAMIC function-value call (dart: vtable entry at
vtableBaseIndex+argCount → call_ref). The callee value is the closure OBJECT
(wrapped at the erasure seam); args ride the UNIFORM dynamic signature
(everything anyref). Returns false when the shape doesn't apply.
"""
function emit_dynamic_closure_call!(b::InstrBuilder, ctx, func, args, idx::Int)::Bool
    base_idx = ctx.type_registry.closure_base_idx
    base_idx === nothing && return false   # no closures wrapped in this module
    arity = length(args)
    vt_struct = get_closure_vtable_struct!(ctx.mod, ctx.type_registry, arity)
    # the uniform dynamic signature
    sig = FuncType(WasmValType[AnyRef for _ in 0:arity], WasmValType[AnyRef])
    sig_idx = add_type!(ctx.mod, sig)

    local scratch = allocate_local!(ctx, AnyRef)
    emit_value!(b, func, ctx, AnyRef)             # the closure OBJECT (seam-wrapped)
    ref_cast!(b, Int64(base_idx), false)
    local_set!(b, UInt32(scratch))
    local_get!(b, UInt32(scratch))                # arg0: the base (anyref, upcast free)
    for a in args
        emit_value!(b, a, ctx, AnyRef)            # each arg boxed/erased by the funnel
    end
    local_get!(b, UInt32(scratch))
    ref_cast!(b, Int64(base_idx), false)
    struct_get!(b, base_idx, UInt32(2), StructRef)          # .vtable
    ref_cast!(b, Int64(vt_struct), false)
    struct_get!(b, vt_struct, UInt32(arity), UInt8(FuncRef)) # entry[arity]
    ref_cast!(b, Int64(sig_idx), false)                      # (ref $sig)
    call_ref!(b, sig_idx, sig.params, sig.results)
    # the uniform result (anyref) converts to the call's inferred type (the funnel
    # unboxes numerics / casts refs — dart converts at the same seam)
    local _rt = get(ctx.ssa_types, idx, Any)
    if _rt isa Type && _rt !== Any && _rt !== Union{}
        local _rw = get_concrete_wasm_type(_rt, ctx.mod, ctx.type_registry)
        _rw !== AnyRef && convert_type!(b, AnyRef, _rw, ctx; from_julia=nothing)
    end
    return true
end
