# ═══════════════════════════════════════════════════════════════════════════
# march16: FIRST-CLASS CLOSURES — trampolines + vtable globals
# (dart ClosureLayouter/ClosureRepresentation, closures.dart:41-118;
#  the closure object = {classId, identityHash, context, vtable, functionType})
# ═══════════════════════════════════════════════════════════════════════════

"""True when an erased value or every runtime inhabitant of `T` is callable."""
function is_callable_julia_type(@nospecialize(T))::Bool
    T === Any && return true
    T isa Type || return false
    T <: Function && return true
    T isa Union || return false
    local members = Base.uniontypes(T)
    return !isempty(members) && all(U -> U isa Type && U <: Function, members)
end

"""
    ensure_closure_vtable!(mod, registry, closure_type, body_idx, body_params, body_results;
                           body_return_type=nothing)
        -> (vtable_global_idx, vtable_struct_idx)

One immutable vtable GLOBAL per closure body. Its single populated entry (the
body's positional arity) is a TRAMPOLINE: (closureBase-as-anyref, args...) →
cast base → context → cast captured struct → call body. dart: the vtable entry
at vtableBaseIndex + posArgCount (closures.dart:105-118).

For capturing closures, `body_params` includes the captured-struct self at slot
0 and `takes_context=true`. Static tear-offs have only their public parameters
and `takes_context=false`; both use the same closure object and vtable ABI.
"""
function ensure_closure_vtable!(mod::WasmModule, registry::TypeRegistry,
                                closure_type::Type, body_idx::UInt32,
                                body_params::Vector{WasmValType},
                                body_results::Vector{WasmValType};
                                body_return_type=nothing,
                                takes_context::Bool=is_closure_type(closure_type))::Tuple{UInt32, UInt32}
    cache = registry.closure_vtable_globals
    cache === nothing && error("closure layouter unavailable on a minimal registry")
    key = closure_type   # T-keyed: the wrap looks up by type alone
    if haskey(cache, key)
        cached = cache[key]
        local cached_arity = length(body_params) - (takes_context ? 1 : 0)
        return (cached, get_closure_vtable_struct!(mod, registry, cached_arity))
    end

    arity = length(body_params) - (takes_context ? 1 : 0)
    base_idx = get_closure_base_struct!(mod, registry)
    vt_struct = get_closure_vtable_struct!(mod, registry, arity)
    captured_info = takes_context ? get(registry.structs, closure_type, nothing) : nothing
    takes_context && captured_info === nothing && error("closure type not registered: $closure_type")

    # ── the trampoline: the UNIFORM DYNAMIC SIGNATURE (anyref^(1+arity)) → anyref
    # (dart's dynamic-call entries: args arrive boxed/erased; the trampoline
    # unboxes/casts per the body's REAL signature and re-boxes the result).
    # fullstrict: the trampoline builder declares its params + scratch local so the
    # tracker reads truth (params anyref^(1+arity) → anyref; scratch = the body width)
    tb = InstrBuilder(WasmValType[AnyRef for _ in 0:arity],
                      isempty(body_results) ? WasmValType[] : WasmValType[AnyRef];
                      func_name="closure_trampoline", mod=mod)
    if takes_context
        local_get!(tb, UInt32(0))
        ref_cast!(tb, Int64(base_idx), false)
        struct_get!(tb, base_idx, UInt32(2), AnyRef)               # .context
        ref_cast!(tb, Int64(captured_info.wasm_type_idx), false)   # captured struct
    end
    for j in 1:arity
        local_get!(tb, UInt32(j))
        local pt = body_params[j + (takes_context ? 1 : 0)]
        if pt in (I32, I64, F32, F64)
            emit_classid_unbox!(tb, mod, registry, pt)
        elseif pt isa ConcreteRef
            ref_cast!(tb, Int64(pt.type_idx), pt.nullable)
        end   # anyref/eq/struct params take the value as-is
    end
    call!(tb, body_idx, WasmValType[], body_results)
    if !isempty(body_results) && body_results[1] in (I32, I64, F32, F64)
        # Re-box with the body's REAL Julia classId. The compile pre-pass owns this
        # vtable creation and therefore owns the authoritative inferred return type;
        # a Wasm width alone cannot distinguish Bool/Int32 or the other same-width
        # Julia types.
        body_return_type isa Type ||
            error("numeric closure trampoline requires its inferred Julia return type")
        local rw = body_results[1]
        local box_idx = get_numeric_box_type!(mod, registry, rw)
        local scratch = UInt32(1 + arity)
        builder_set_local_type!(tb, Int(scratch), rw)   # fullstrict: the scratch's truth
        local_set!(tb, scratch)
        i32_const!(tb, Int64(ensure_type_id!(registry, body_return_type)))
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
{classId, identityHash, context, vtable, functionType} (dart's implicit function-value creation at the
erasure seam — convertType when a closure meets a top type).
"""
function emit_closure_wrap!(b::InstrBuilder, ctx, closure_type::Type, body_idx::UInt32,
                            body_params::Vector{WasmValType}, body_results::Vector{WasmValType};
                            takes_context::Bool=is_closure_type(closure_type))
    base_idx = get_closure_base_struct!(ctx.mod, ctx.type_registry)
    # POST-FREEZE: lookup only — the pre-pass created the vtable; creating here
    # would add functions mid-body-compile (the index-freeze skew).
    local cache = ctx.type_registry.closure_vtable_globals
    (cache !== nothing && haskey(cache, closure_type)) || return nothing
    g, _ = ensure_closure_vtable!(ctx.mod, ctx.type_registry, closure_type, body_idx,
                                  body_params, body_results; takes_context)
    # stack: [captured] → {classId, identityHash=0, context, vtable, functionType}
    local ctx_scratch = allocate_local!(ctx, AnyRef)
    if takes_context
        local_set!(b, UInt32(ctx_scratch))
    else
        # The source singleton struct is only its pre-erasure representation.
        # Static tear-offs have no receiver/context, so use Julia's real Nothing
        # singleton as Dart uses its canonical dummy context object.
        drop!(b)
        local ng = get_nothing_global!(ctx.mod, ctx.type_registry)
        global_get!(b, ng, ctx.mod.globals[Int(ng) + 1].valtype)
        local_set!(b, UInt32(ctx_scratch))
    end
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, closure_type)))
    i32_const!(b, 0)
    local_get!(b, UInt32(ctx_scratch))
    local arity = length(body_params) - (takes_context ? 1 : 0)
    global_get!(b, g, ConcreteRef(get_closure_vtable_struct!(ctx.mod, ctx.type_registry, arity), false))
    local type_globals = ctx.type_registry.type_constant_globals
    (type_globals !== nothing && haskey(type_globals, closure_type)) ||
        error("closed-world type object missing for closure $closure_type")
    local type_global = type_globals[closure_type]
    global_get!(b, type_global, ctx.mod.globals[Int(type_global) + 1].valtype)
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
        local takes_context = is_closure_type(closure_type)
        local matches = takes_context ? info.func_ref === closure_type :
                        (info.func_ref isa Function && typeof(info.func_ref) === closure_type)
        matches || continue
        # fullstrict: the PLACEHOLDER (pre-declared signatures) is THE truth — the
        # same source the call! deriver enforces; the julia re-derivation could
        # disagree (the trampoline then mismatched at its own call).
        local _m = ctx.mod
        local _ni = count(imp -> imp.kind == 0x00, _m.imports)
        local _fi = Int(info.wasm_idx) - _ni
        if _fi >= 0 && _fi < length(_m.functions)
            local _ft = _m.types[Int(_m.functions[_fi + 1].type_idx) + 1]
            if _ft isa FuncType
                return (info.wasm_idx, WasmValType[q for q in _ft.params], WasmValType[r for r in _ft.results], takes_context)
            end
        end
        # fallback: the julia derivation (bare registries)
        local ps = WasmValType[]
        for T in info.arg_types
            push!(ps, get_concrete_wasm_type(T, ctx.mod, ctx.type_registry))
        end
        local rs = (info.return_type === Nothing || info.return_type === Union{}) ?
                   WasmValType[] :
                   WasmValType[get_concrete_wasm_type(info.return_type, ctx.mod, ctx.type_registry)]
        return (info.wasm_idx, ps, rs, takes_context)
    end
    return nothing
end

"""
    maybe_wrap_closure!(b, ctx, from_julia) -> Bool

The ERASURE seam (dart convertType: a callable meeting a top type becomes the
closure OBJECT). A captured-context struct or named-function singleton is on the
stack; when its body was enrolled in the closed world, wrap it. Returns whether
it wrapped.
"""
function maybe_wrap_closure!(b::InstrBuilder, ctx, from_julia)::Bool
    # The Julia static type can remain the captured callable after an earlier
    # heterogeneous/erasure seam has already produced the closure Object. The
    # strict builder stack is the representation truth; never wrap that Object
    # again as if it were a context struct.
    local base_idx = ctx.type_registry.closure_base_idx
    if base_idx !== nothing && !isempty(b.v.stack)
        local actual = b.v.stack[end]
        actual isa ConcreteRef && actual.type_idx == base_idx && return true
    end
    from_julia isa DataType || return false
    from_julia <: Function || return false
    haskey(ctx.type_registry.structs, from_julia) || return false
    local body = _closure_body_for(ctx, from_julia)
    body === nothing && return false
    return emit_closure_wrap!(b, ctx, from_julia, body[1], body[2], body[3];
                              takes_context=body[4]) !== nothing
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
    struct_get!(b, base_idx, UInt32(3), StructRef)          # .vtable
    ref_cast!(b, Int64(vt_struct), false)
    struct_get!(b, vt_struct, UInt32(arity), UInt8(FuncRef)) # entry[arity]
    ref_cast!(b, Int64(sig_idx), false)                      # (ref $sig)
    call_ref!(b, sig_idx, sig.params, sig.results)
    # the uniform result (anyref) converts to the call's inferred type (the funnel
    # unboxes numerics / casts refs — dart converts at the same seam)
    local _rt = get(ctx.ssa_types, idx, Any)
    if _rt isa Type && _rt !== Any && _rt !== Union{}
        local _rw = get_concrete_wasm_type(_rt, ctx.mod, ctx.type_registry)
        _rw !== AnyRef && coerce_stack_top!(b, _rw, ctx)
    end
    return true
end
