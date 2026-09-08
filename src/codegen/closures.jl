# ═══════════════════════════════════════════════════════════════════════════
# FIRST-CLASS CLOSURES — trampolines + vtable globals
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
    ClosureBody(body_idx, params, results, return_type)

One compiled specialization of a callable type, as the layouter sees it: the body's
function index, its physical signature, and its inferred Julia return type (the
trampoline re-boxes a numeric result with that type's classId).
"""
struct ClosureBody
    body_idx::UInt32
    params::Vector{WasmValType}
    results::Vector{WasmValType}
    return_type::Type
    julia_params::Union{Nothing, Vector{Type}}   # the specialization's Julia parameter types (self included for capturing closures)
end
ClosureBody(body_idx, params, results, return_type) = ClosureBody(body_idx, params, results, return_type, nothing)

"""
    build_closure_vtable!(mod, registry, closure_type, bodies; takes_context)
        -> (vtable_global_idx, vtable_struct_idx)

ONE immutable vtable GLOBAL per closure TYPE (dart ClosureLayouter: one representation
per function shape, closures.dart:41-118, memoized by the shape itself :1101-1114). The
vtable struct has an entry for every positional arity 0..max; entry[arity] is a
TRAMPOLINE for the body of that arity — (closureBase-as-anyref, args...) → cast base →
context → cast captured struct → call body — and the other entries are null. Every
specialization of the type the closed world contains is passed at once, so a type
called through erased bindings at two arities (`string` as a value, with `string(x)`
and `string(a,b,c,d)` both reachable) gets both entries; two specializations of the
SAME arity cannot share one entry (the dynamic caller's arguments are erased, and the
trampoline would have to dispatch on their runtime classes) and are rejected loudly.

For capturing closures, `params` includes the captured-struct self at slot 0 and
`takes_context=true`. Static tear-offs have only their public parameters and
`takes_context=false`; both use the same closure object and vtable ABI.
"""
# formal(dev/formal/ClosureLayout.tla): captured fields keep declaration order and the vtable global's shape is the one frozen at creation
function build_closure_vtable!(mod::WasmModule, registry::TypeRegistry,
                               closure_type::Type, bodies::Vector{ClosureBody};
                               takes_context::Bool=is_closure_type(closure_type))::Tuple{UInt32, UInt32}
    cache = registry.closure_vtable_globals
    cache === nothing && error("closure layouter unavailable on a minimal registry")
    haskey(cache, closure_type) && error("closure vtable for $closure_type built twice")
    isempty(bodies) && error("closure vtable for $closure_type has no body")
    base_idx = get_closure_base_struct!(mod, registry)
    captured_info = takes_context ? get(registry.structs, closure_type, nothing) : nothing
    takes_context && captured_info === nothing && error("closure type not registered: $closure_type")

    # arity → the bodies of that arity, in program order
    local by_arity = Dict{Int, Vector{ClosureBody}}()
    local arities = Int[]
    for body in bodies
        local arity = length(body.params) - (takes_context ? 1 : 0)
        haskey(by_arity, arity) || (by_arity[arity] = ClosureBody[]; push!(arities, arity))
        push!(by_arity[arity], body)
    end
    # arity → trampoline: the body's own entry, or — a Julia generic function as a value
    # (parity(quarantine: dart has one body per closure; `string` as a value has every
    # reachable specialization)) — a dispatching entry that tests the erased arguments'
    # classIds against each specialization's parameter types in program order
    local tramps = Dict{Int, UInt32}()
    for arity in arities
        local cands = by_arity[arity]
        tramps[arity] = length(cands) == 1 ?
            _closure_trampoline!(mod, registry, cands[1], arity, takes_context, base_idx, captured_info) :
            _closure_dispatch_trampoline!(mod, registry, closure_type, cands, arity, takes_context, base_idx, captured_info)
    end
    local max_arity = maximum(keys(tramps))
    vt_struct = get_closure_vtable_struct!(mod, registry, max_arity)

    # ── the vtable global: entry[a] = trampoline for arity a, null elsewhere ──
    init = UInt8[]
    for a in 0:max_arity
        if haskey(tramps, a)
            push!(init, Opcode.REF_FUNC)
            append!(init, encode_leb128_unsigned(UInt64(tramps[a])))
        else
            push!(init, 0xD0)                                   # ref.null
            push!(init, 0x70)                                   # funcref heap type
        end
    end
    push!(init, Opcode.GC_PREFIX, 0x00)                          # struct.new
    append!(init, encode_leb128_unsigned(UInt64(vt_struct)))
    g = add_global_ref!(mod, vt_struct, false, init; nullable=false)
    cache[closure_type] = g
    return (g, vt_struct)
end

# The trampoline: the UNIFORM DYNAMIC SIGNATURE (anyref^(1+arity)) → anyref (dart's
# dynamic-call entries: args arrive boxed/erased; the trampoline unboxes/casts per the
# body's REAL signature and re-boxes the result). The builder declares its params +
# scratch local so the tracker reads truth (params anyref^(1+arity) → anyref; scratch =
# the body width).
function _closure_trampoline!(mod::WasmModule, registry::TypeRegistry, body::ClosureBody,
                              arity::Int, takes_context::Bool, base_idx::UInt32, captured_info)::UInt32
    tb = InstrBuilder(WasmValType[AnyRef for _ in 0:arity],
                      isempty(body.results) ? WasmValType[] : WasmValType[AnyRef];
                      func_name="closure_trampoline", mod=mod)
    if takes_context
        local_get!(tb, UInt32(0))
        ref_cast!(tb, Int64(base_idx), false)
        struct_get!(tb, base_idx, UInt32(2), AnyRef)               # .context
        ref_cast!(tb, Int64(captured_info.wasm_type_idx), false)   # captured struct
    end
    for j in 1:arity
        local_get!(tb, UInt32(j))
        local pt = body.params[j + (takes_context ? 1 : 0)]
        if pt in (I32, I64, F32, F64)
            emit_classid_unbox!(tb, mod, registry, pt)
        elseif pt isa ConcreteRef
            ref_cast!(tb, Int64(pt.type_idx), pt.nullable)
        elseif pt isa RefType && pt !== AnyRef
            # Dynamic entries receive anyref. Abstract heap-typed body parameters
            # still require the same explicit narrowing as nominal ConcreteRefs.
            ref_cast!(tb, pt, true)
        end   # AnyRef already has the body's exact representation.
    end
    call!(tb, body.body_idx, WasmValType[], body.results)
    if !isempty(body.results) && body.results[1] in (I32, I64, F32, F64)
        # Re-box with the body's REAL Julia classId. The compile pre-pass owns this
        # vtable creation and therefore owns the authoritative inferred return type;
        # a Wasm width alone cannot distinguish Bool/Int32 or the other same-width
        # Julia types.
        body.return_type isa Type ||
            error("numeric closure trampoline requires its inferred Julia return type")
        local rw = body.results[1]
        local box_idx = get_numeric_box_type!(mod, registry, rw)
        local scratch = UInt32(1 + arity)
        builder_set_local_type!(tb, Int(scratch), rw)   # the scratch's truth
        local_set!(tb, scratch)
        local body_return_type = body.return_type
        i32_const!(tb, Int64(ensure_type_id!(registry, body_return_type)))
        local_get!(tb, scratch)
        struct_new!(tb, box_idx)
        tramp_locals = WasmValType[rw]
    else
        tramp_locals = WasmValType[]
    end
    end_block!(tb)   # the function frame's own end
    tramp_params = WasmValType[AnyRef for _ in 0:arity]
    tramp_results = isempty(body.results) ? WasmValType[] : WasmValType[AnyRef]
    tramp_idx = add_function!(mod, tramp_params, tramp_results, tramp_locals, builder_code(tb))
    declare_funcs!(mod, UInt32[tramp_idx])
    return tramp_idx
end

# Push the trampoline's erased argument `j` unboxed/cast to the body's parameter `pt`
# (the same narrowing the single-body trampoline applies).
function _closure_narrow_arg!(tb::InstrBuilder, mod::WasmModule, registry::TypeRegistry, j::Int, pt::WasmValType)::InstrBuilder
    local_get!(tb, UInt32(j))
    if pt in (I32, I64, F32, F64)
        emit_classid_unbox!(tb, mod, registry, pt)
    elseif pt isa ConcreteRef
        ref_cast!(tb, Int64(pt.type_idx), pt.nullable)
    elseif pt isa RefType && pt !== AnyRef
        ref_cast!(tb, pt, true)
    end
    return tb
end

# The re-boxed call of `body` from the trampoline's narrowed arguments, then `return`.
function _closure_call_body!(tb::InstrBuilder, mod::WasmModule, registry::TypeRegistry, body::ClosureBody,
                             arity::Int, takes_context::Bool, base_idx::UInt32, captured_info, scratch::UInt32,
                             has_result::Bool)::InstrBuilder
    if takes_context
        local_get!(tb, UInt32(0))
        ref_cast!(tb, Int64(base_idx), false)
        struct_get!(tb, base_idx, UInt32(2), AnyRef)               # .context
        ref_cast!(tb, Int64(captured_info.wasm_type_idx), false)   # captured struct
    end
    for j in 1:arity
        _closure_narrow_arg!(tb, mod, registry, j, body.params[j + (takes_context ? 1 : 0)])
    end
    call!(tb, body.body_idx, WasmValType[], body.results)
    if isempty(body.results) && has_result
        # a bottom specialization (its every path throws — a MethodError row of the
        # dynamic discovery): the call never returns — structural trap, never reached
        unreachable!(tb)   # structural trap after a call that never returns
        return tb
    end
    if !isempty(body.results) && body.results[1] in (I32, I64, F32, F64)
        body.return_type isa Type ||
            error("numeric closure trampoline requires its inferred Julia return type")
        local rw = body.results[1]
        local box_idx = get_numeric_box_type!(mod, registry, rw)
        builder_set_local_type!(tb, Int(scratch), rw)
        local_set!(tb, scratch)
        i32_const!(tb, Int64(ensure_type_id!(registry, body.return_type)))
        local_get!(tb, scratch)
        struct_new!(tb, box_idx)
    end
    return_!(tb)
    return tb
end

"""
    _closure_dispatch_trampoline!(mod, registry, closure_type, cands, arity, takes_context, base_idx, captured_info)

The vtable entry for an arity that several specializations of `closure_type` share. Every
argument arrives erased (anyref); each candidate is tried in program order — every
argument must carry the classId the candidate's Julia parameter type has (a classed value
is a `\$JlTop` subtype whose field 0 is its classId; a box, a string, a struct alike) —
and the first match is narrowed, called and re-boxed exactly as a single-body entry.
No match traps: Julia would throw MethodError for the same call.
"""
function _closure_dispatch_trampoline!(mod::WasmModule, registry::TypeRegistry, closure_type::Type,
                                       cands::Vector{ClosureBody}, arity::Int, takes_context::Bool,
                                       base_idx::UInt32, captured_info)::UInt32
    local top_idx = registry.base_struct_idx
    top_idx === nothing && error("closure $closure_type: a dispatching entry needs the class base struct")
    # the entry returns a value if any specialization does; the others are bottom
    # (their every path throws) and end in `unreachable` after their call
    local has_result = any(c -> !isempty(c.results), cands)
    all(c -> !isempty(c.results) || c.return_type === Union{}, cands) || error(
        "closure $closure_type: arity-$arity specializations disagree on returning a value")
    tb = InstrBuilder(WasmValType[AnyRef for _ in 0:arity],
                      has_result ? WasmValType[AnyRef] : WasmValType[];
                      func_name="closure_dispatch_trampoline", mod=mod)
    # locals after the params: the classed-value scratch for the tests, then one re-box
    # scratch per numeric result width the candidates return
    local tmp = UInt32(1 + arity)
    local tramp_locals = WasmValType[AnyRef]
    local scratch_of = Dict{WasmValType, UInt32}()
    for c in cands
        if !isempty(c.results) && c.results[1] in (I32, I64, F32, F64) && !haskey(scratch_of, c.results[1])
            push!(tramp_locals, c.results[1])
            scratch_of[c.results[1]] = UInt32(arity + length(tramp_locals))
        end
    end
    for c in cands
        local lbl = block!(tb)
        for j in 1:arity
            local pj = c.params[j + (takes_context ? 1 : 0)]
            pj === AnyRef && continue                   # accepts anything
            local Tj = c.julia_params === nothing ? nothing : c.julia_params[j + (takes_context ? 1 : 0)]
            (Tj isa DataType && isconcretetype(Tj)) || error(
                "closure $closure_type: a dispatching entry needs a concrete Julia parameter type at position $j, got $Tj")
            # arg j is a $JlTop subtype whose classId is Tj's
            local_get!(tb, UInt32(j))
            local_tee!(tb, tmp)
            ref_test!(tb, Int64(top_idx), false)
            num!(tb, Opcode.I32_EQZ)
            br_if!(tb, lbl)
            local_get!(tb, tmp)
            ref_cast!(tb, Int64(top_idx), false)
            struct_get!(tb, UInt32(top_idx), UInt32(0), I32)
            i32_const!(tb, Int64(ensure_type_id!(registry, Tj)))
            num!(tb, Opcode.I32_NE)
            br_if!(tb, lbl)
        end
        local c_scratch = isempty(c.results) ? UInt32(0) : get(scratch_of, c.results[1], UInt32(0))
        _closure_call_body!(tb, mod, registry, c, arity, takes_context, base_idx, captured_info, c_scratch, has_result)
        end_block!(tb)
    end
    unreachable!(tb)   # structural trap: no specialization matched — Julia throws MethodError here
    end_block!(tb)
    tramp_idx = add_function!(mod, WasmValType[AnyRef for _ in 0:arity],
                              has_result ? WasmValType[AnyRef] : WasmValType[], tramp_locals, builder_code(tb))
    declare_funcs!(mod, UInt32[tramp_idx])
    return tramp_idx
end

"""
    closure_vtable(mod, registry, closure_type, arity) -> (vtable_global_idx, vtable_struct_idx)

The vtable the pre-pass built for `closure_type`, read back from the global's declared
type — never re-derived from the call at hand — and checked to hold an entry for
`arity` (ClosureLayout.tla ArityDrift: a shape the creation did not freeze is a layouter
defect, not a silent re-derivation).
"""
function closure_vtable(mod::WasmModule, registry::TypeRegistry, closure_type::Type, arity::Int)::Tuple{UInt32, UInt32}
    cache = registry.closure_vtable_globals
    cache === nothing && error("closure layouter unavailable on a minimal registry")
    haskey(cache, closure_type) || error("closure vtable for $closure_type was not built by the pre-pass")
    local g = cache[closure_type]
    local vt_decl = mod.globals[Int(g) + 1].valtype
    vt_decl isa ConcreteRef || error("closure vtable global $g has no struct type")
    local vt_fields = length(mod.types[Int(vt_decl.type_idx) + 1].fields)
    arity < vt_fields || error(
        "closure $closure_type is wrapped for arity $arity; its vtable holds arities 0..$(vt_fields - 1)")
    return (g, vt_decl.type_idx)
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
    g, _ = closure_vtable(ctx.mod, ctx.type_registry, closure_type,
                          length(body_params) - (takes_context ? 1 : 0))
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
    global_get!(b, g, ctx.mod.globals[Int(g) + 1].valtype)   # the vtable's declared type, not a re-derivation
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

The DYNAMIC function-value call (dart: vtable entry at
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
