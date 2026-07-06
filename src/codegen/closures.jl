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
    key = (closure_type, Int(body_idx))
    if haskey(cache, key)
        cached = cache[key]
        return (cached, get_closure_vtable_struct!(mod, registry, length(body_params) - 1))
    end

    arity = length(body_params) - 1          # public args (minus the closure self)
    base_idx = get_closure_base_struct!(mod, registry)
    vt_struct = get_closure_vtable_struct!(mod, registry, arity)
    captured_info = get(registry.structs, closure_type, nothing)
    captured_info === nothing && error("closure type not registered: $closure_type")

    # ── the trampoline ──
    tb = InstrBuilder(; func_name="closure_trampoline", mod=mod)
    local_get!(tb, UInt32(0))
    ref_cast!(tb, Int64(base_idx), false)
    struct_get!(tb, base_idx, UInt32(1), AnyRef)               # .context
    ref_cast!(tb, Int64(captured_info.wasm_type_idx), false)   # the captured struct
    for j in 1:arity
        local_get!(tb, UInt32(j))
    end
    call!(tb, body_idx, WasmValType[], body_results)
    tramp_params = WasmValType[AnyRef; body_params[2:end]]
    tramp_idx = add_function!(mod, tramp_params, body_results, WasmValType[], builder_code(tb))
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
        (!isempty(info.arg_types) && info.arg_types[1] === closure_type) || continue
        local n_imp = num_imported_funcs(ctx.mod)
        local fi = Int(info.wasm_idx) - n_imp
        (fi >= 0 && fi < length(ctx.mod.functions)) || continue
        local ft = ctx.mod.types[Int(ctx.mod.functions[fi + 1].type_idx) + 1]
        ft isa FuncType || continue
        return (info.wasm_idx, ft.params, ft.results)
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
    body === nothing && return false
    emit_closure_wrap!(b, ctx, from_julia, body[1], body[2], body[3])
    return true
end
