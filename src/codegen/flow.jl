"""
Generate code using Wasm's structured control flow.
For simple if-then-else patterns, we use the `if` instruction.
"""
function generate_structured(ctx::AbstractCompilationContext, blocks::Vector{BasicBlock})::Vector{UInt8}
    b = _ctx_builder(ctx, "generate_structured")
    code = ctx.code_info.code
    # parity(M1) ONE LOWERING (dart: one CodeGenerator, one structured lowering, no strategy
    # choice): every CFG shape, including a single block and try/catch, goes through
    # THE stackifier. Retired strategies this replaced: the nested-conditional
    # family (a documented multivar-phi miscompiler), generate_void_flow (missing pre-loop
    # phi init, PURE-314), and generate_loop_code + generate_branched_loops (no-phi loops).
    # Try regions are first-class stackifier metadata; handler blocks remain plain
    # CFG blocks and the same phi machinery owns all of their edges.
    regions = has_try_catch(code) ? Vector{Any}(find_try_regions(code)) : Any[]
    generate_stackified_flow!(b, ctx, blocks, code; try_regions=regions)

    # Close exactly the seeded function frame. Any remaining block/loop is a
    # stackifier bug and must fail here, never serialize into malformed Wasm.
    finish_function!(b)

    return builder_code(b)
end


"""
Determine the Wasm type that a phi edge value will produce on the stack.
Used to check compatibility before storing to a phi local.
"""
function get_phi_edge_wasm_type(val, ctx::AbstractCompilationContext)::Union{WasmValType, Nothing}
    # PURE-036ai: Handle nothing literal - compile_value(nothing) emits i32_const 0
    if val === nothing
        return I32
    end
    # PURE-045: Handle GlobalRef to nothing (e.g., Compiler.nothing, Base.nothing)
    # These compile to i32_const 0 just like literal nothing
    if val isa GlobalRef && val.name === :nothing
        return I32
    end
    if val isa Core.SSAValue
        # If the SSA has a local allocated, return the local's actual Wasm type.
        # This is what local.get will actually push on the stack, which may differ
        # from the Julia-inferred type when PiNodes narrow types.
        if haskey(ctx.ssa_locals, val.id)
            local_idx = ctx.ssa_locals[val.id]
            local_array_idx = local_idx - ctx.n_params + 1
            if local_array_idx >= 1 && local_array_idx <= length(ctx.locals)
                return ctx.locals[local_array_idx]
            end
        elseif haskey(ctx.phi_locals, val.id)
            local_idx = ctx.phi_locals[val.id]
            local_array_idx = local_idx - ctx.n_params + 1
            if local_array_idx >= 1 && local_array_idx <= length(ctx.locals)
                return ctx.locals[local_array_idx]
            end
        end
        edge_julia_type = get(ctx.ssa_types, val.id, nothing)
        if edge_julia_type !== nothing
            return julia_to_wasm_type_concrete(edge_julia_type, ctx)
        end
    elseif val isa Core.SlotNumber
        # PURE-6024: SlotNumber in unoptimized IR — check slot_locals first
        if haskey(ctx.slot_locals, val.id)
            local_idx = ctx.slot_locals[val.id]
            local_array_idx = local_idx - ctx.n_params + 1
            if local_array_idx >= 1 && local_array_idx <= length(ctx.locals)
                return ctx.locals[local_array_idx]
            end
        end
        # Fall back to param mapping or slottypes
        arg_types_idx = val.id - 1
        if arg_types_idx >= 1 && arg_types_idx <= length(ctx.arg_types)
            return get_concrete_wasm_type(ctx.arg_types[arg_types_idx], ctx.mod, ctx.type_registry)
        else
            source_type = source_slot_type(ctx, val.id)
            source_type !== nothing && return julia_to_wasm_type_concrete(source_type, ctx)
        end
    elseif val isa Core.Argument
        # PURE-036ab: Use the ACTUAL Wasm parameter type from arg_types, not the Julia slottype.
        # Julia IR uses _1 for function type (not in arg_types), _2 for first arg (arg_types[1]), etc.
        # So arg_types index = val.n - 1 for non-closures.
        arg_types_idx = val.n - 1  # _2 → arg_types[1], _3 → arg_types[2], etc.
        if arg_types_idx >= 1 && arg_types_idx <= length(ctx.arg_types)
            local _arg_t = ctx.arg_types[arg_types_idx]
            # PURE-9030: Union params promoted to anyref for dispatch
            if _arg_t isa Union && needs_anyref_boxing(_arg_t)
                return AnyRef
            end
            return get_concrete_wasm_type(_arg_t, ctx.mod, ctx.type_registry)
        end
    elseif val isa Int64 || val isa UInt64 || val isa Int
        return I64
    elseif val isa Int32 || val isa UInt32 || val isa Bool || val isa UInt8 || val isa Int8 || val isa UInt16 || val isa Int16
        return I32
    elseif val isa Float64
        return F64
    elseif val isa Float32
        return F32
    elseif val isa Symbol || val isa String
        # parity(M9): String/Symbol constants are the CLASSED string struct
        str_type_idx = get_string_struct_type!(ctx.mod, ctx.type_registry)
        return ConcreteRef(str_type_idx, false)
    elseif val isa GlobalRef
        # PURE-317: Resolve GlobalRef to actual value to determine Wasm type
        if val.name === :nothing
            return I32
        end
        try
            actual_val = getfield(val.mod, val.name)
            return get_phi_edge_wasm_type(actual_val, ctx)
        catch
            return nothing
        end
    elseif val isa Char
        # PURE-317: Char is a 4-byte primitive, compiled as I32
        return I32
    elseif val isa Type
        # PURE-4155: Type{T} values are now represented as DataType struct refs (global.get).
        # PURE-9063: Use $JlDataType when hierarchy is available
        dt_idx = get_datatype_type_idx(ctx.type_registry)
        return ConcreteRef(dt_idx, true)
    end
    return nothing
end

"""
Check if two Wasm types are compatible for local.set (value can be stored in local).
"""
function wasm_types_compatible(local_type::WasmValType, value_type::WasmValType)::Bool
    if local_type == value_type
        return true
    end
    local_is_numeric = local_type === I32 || local_type === I64 || local_type === F32 || local_type === F64
    value_is_numeric = value_type === I32 || value_type === I64 || value_type === F32 || value_type === F64
    local_is_ref = local_type isa ConcreteRef || local_type === StructRef || local_type === ArrayRef || local_type === ExternRef || local_type === AnyRef || local_type === EqRef
    value_is_ref = value_type isa ConcreteRef || value_type === StructRef || value_type === ArrayRef || value_type === ExternRef || value_type === AnyRef || value_type === EqRef
    # Numeric and ref are never compatible
    if (local_is_numeric && value_is_ref) || (local_is_ref && value_is_numeric)
        return false
    end
    # Two different numeric types are NOT compatible (i32 != i64 for local.set)
    if local_is_numeric && value_is_numeric && local_type != value_type
        return false
    end
    # Different concrete refs are not directly compatible
    if local_type isa ConcreteRef && value_type isa ConcreteRef && local_type.type_idx != value_type.type_idx
        return false
    end
    # Abstract ref (StructRef/ArrayRef/AnyRef/EqRef) is NOT directly compatible with ConcreteRef
    # (requires ref.cast to downcast from abstract/super to concrete)
    if local_type isa ConcreteRef && (value_type === StructRef || value_type === ArrayRef || value_type === AnyRef || value_type === EqRef)
        return false
    end
    # PURE-6024: Reverse direction — ConcreteRef value into ArrayRef/StructRef local.
    # A concrete struct ref is NOT an arrayref (and vice versa). Needs unwrapping/casting.
    if (local_type === ArrayRef || local_type === StructRef) && value_type isa ConcreteRef
        return false
    end
    # ExternRef is NOT compatible with ConcreteRef/StructRef/ArrayRef/AnyRef/EqRef
    # (externref is outside the anyref hierarchy in WasmGC)
    if local_type === ExternRef && (value_type isa ConcreteRef || value_type === StructRef || value_type === ArrayRef || value_type === AnyRef || value_type === EqRef)
        return false
    end
    if value_type === ExternRef && (local_type isa ConcreteRef || local_type === StructRef || local_type === ArrayRef || local_type === AnyRef || local_type === EqRef)
        return false
    end
    return true
end

"""
    _emit_phi_edge_convert!(b, ctx, phi_local_type, src_type, src::InstrBuilder) -> Bool

THE single-source phi-edge value conversion (Loop C flow/phi dedup). `src` is a fragment
builder that pushes the source value (already typed `src_type`); this merges it (typed,
via append_builder!) and emits the box / cast / UNBOX needed to land it in a phi local of
`phi_local_type`, leaving the converted value on `b`'s stack (the caller does the
local.set). Returns true if an arm applied, false if none did (caller emits a type-safe
default — and `src` was NOT merged).

This is the ONE place that knows how a numeric value boxes into a ref phi local — and, the arm
that was missing at every copy of this logic, how a classId box UNBOXES into a numeric phi local
(`v[i]::Any` narrowed to Int64 via an isa-split phi). Without the unbox arm those edges fell to
the default → `i64.const 0`, a silent miscompile (`Any[1,2,3][i]` → 0).
"""
function _emit_phi_edge_convert!(b::InstrBuilder, ctx::AbstractCompilationContext,
                                 phi_local_type, src_type, src::InstrBuilder)::Bool
    isempty(src.instrs) && return false
    _num(t) = (t === I32 || t === I64 || t === F32 || t === F64)
    _ref(t) = (t === AnyRef || t === EqRef || t === StructRef || t === ArrayRef || t === ExternRef || t isa ConcreteRef)
    if phi_local_type === ExternRef && _num(src_type)
        # numeric → ExternRef: classId box (via THE single emitter), then to externref
        append_builder!(b, src)
        emit_classid_box!(b, ctx, src_type, nothing)
        extern_convert_any!(b)
        return true
    elseif phi_local_type === AnyRef && _num(src_type)
        # numeric → AnyRef: classId box (a struct ref is already an anyref subtype)
        append_builder!(b, src)
        emit_classid_box!(b, ctx, src_type, nothing)
        return true
    elseif phi_local_type === ExternRef && _ref(src_type)
        # internal ref → ExternRef
        append_builder!(b, src)
        extern_convert_any!(b)
        return true
    elseif _num(phi_local_type) && _ref(src_type)
        # THE missing arm — UNBOX a classId box into a numeric phi local (inverse of the
        # numeric→AnyRef box arm above). Well-typed numeric phi ⟹ the edge is a numeric box,
        # so the ref.cast inside emit_classid_unbox! succeeds; a genuine mistype traps (loud).
        append_builder!(b, src)
        src_type === ExternRef && any_convert_extern!(b)
        emit_classid_unbox!(b, ctx, phi_local_type)
        return true
    end
    return false
end

"""
Store a phi edge value to a phi local, with type compatibility checking — THE
builder-native implementation.
If the edge value type is incompatible with the phi local type (e.g., ref vs numeric),
the store is skipped (these represent unreachable code paths in Union types).
Returns true if the store was emitted, false if skipped.
"""
function emit_phi_local_set!(b::InstrBuilder, val, phi_ssa_idx::Int, ctx::AbstractCompilationContext)::Bool
    # parity(M2): THE wrap collapse — a phi-edge store IS dart's wrap(val, phi_local_type)
    # followed by local.set (code_generator.dart:879 + convertType): emit typed, coerce the
    # ACTUAL emitted type to the phi local's type through the ONE convert_type! funnel, store.
    # Replaces the ~360-line phi_local_type × edge_val_type elseif-chain (hand-rolled box/
    # extern/cast/widen arms, byte-scans, and the flagged unsigned-LEB REF_CAST_NULL bridge —
    # convert_type!'s ref_cast! emits the spec-correct s33 encoding).
    haskey(ctx.phi_locals, phi_ssa_idx) || return false
    local_idx = ctx.phi_locals[phi_ssa_idx]
    phi_local_type = ctx.locals[local_idx - ctx.n_params + 1]

    # `nothing` into a ref-typed phi local → typed null (compile_value pushes i32 0 for
    # nothing; funneling that would BOX a fabricated zero — dart stores null, not a box).
    if _wt_is_ref(phi_local_type) && is_nothing_value(val, ctx)
        if phi_local_type isa ConcreteRef
            ref_null!(b, Int64(phi_local_type.type_idx), phi_local_type)
        else
            ref_null!(b, phi_local_type)
        end
        local_set!(b, local_idx)
        return true
    end

    local _pv_vb = _compile_value_b(val, ctx)
    local vty = isempty(_pv_vb.v.stack) ? nothing : _pv_vb.v.stack[end]
    isempty(_pv_vb.instrs) && return false   # caller falls back (unresolvable value)
    append_builder!(b, _pv_vb)   # typed merge
    if vty === nothing
        # Dead path — the emission ended unreachable; nothing executes after it.
        return true
    end
    vty === phi_local_type || coerce_stack_top!(b, phi_local_type, ctx)
    local_set!(b, local_idx)
    return true
end
