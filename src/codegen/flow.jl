"""
Generate code using Wasm's structured control flow.
For simple if-then-else patterns, we use the `if` instruction.
"""
function generate_structured(ctx::AbstractCompilationContext, blocks::Vector{BasicBlock})::Vector{UInt8}
    b = InstrBuilder(; func_name="generate_structured", strict=false)
    code = ctx.code_info.code
    # parity(M1) ONE LOWERING (dart: one CodeGenerator, one structured lowering, no strategy
    # choice): try/catch keeps its EH driver; a single block is plain statement emission;
    # EVERYTHING else — conditionals, loops (with or without header phis), mixed shapes —
    # goes through THE stackifier. Retired strategies this replaced: the nested-conditional
    # family (a documented multivar-phi miscompiler), generate_void_flow (missing pre-loop
    # phi init, PURE-314), and generate_loop_code + generate_branched_loops (no-phi loops).
    if has_try_catch(code)
        emit_raw!(b, generate_try_catch(ctx, blocks, code))
    elseif length(blocks) == 1
        # Single block - just generate statements
        emit_raw!(b, generate_block_code(ctx, blocks[1]))
    else
        emit_raw!(b, generate_stackified_flow(ctx, blocks, code))
    end

    # Always end with END opcode
    end_block!(b)

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
        elseif val.id >= 1 && val.id <= length(ctx.code_info.slottypes)
            return julia_to_wasm_type_concrete(ctx.code_info.slottypes[val.id], ctx)
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
        # PURE-036ba: Symbol and String compile to array<i32> (string array type)
        str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
        return ConcreteRef(str_type_idx, false)  # non-nullable since array.new_fixed produces non-nullable ref
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
    _emit_phi_edge_convert!(b, ctx, phi_local_type, src_type, value_bytes) -> Bool

THE single-source phi-edge value conversion (Loop C flow/phi dedup). `value_bytes` pushes the
source value (already typed `src_type`); this emits the box / cast / UNBOX needed to land it in
a phi local of `phi_local_type`, leaving the converted value on `b`'s stack (the caller does the
local.set). Returns true if an arm applied, false if none did (caller emits a type-safe default).

This is the ONE place that knows how a numeric value boxes into a ref phi local — and, the arm
that was missing at every copy of this logic, how a classId box UNBOXES into a numeric phi local
(`v[i]::Any` narrowed to Int64 via an isa-split phi). Without the unbox arm those edges fell to
the default → `i64.const 0`, a silent miscompile (`Any[1,2,3][i]` → 0).
"""
function _emit_phi_edge_convert!(b::InstrBuilder, ctx::AbstractCompilationContext,
                                 phi_local_type, src_type, value_bytes::Vector{UInt8})::Bool
    isempty(value_bytes) && return false
    _num(t) = (t === I32 || t === I64 || t === F32 || t === F64)
    _ref(t) = (t === AnyRef || t === EqRef || t === StructRef || t === ArrayRef || t === ExternRef || t isa ConcreteRef)
    if phi_local_type === ExternRef && _num(src_type)
        # numeric → ExternRef: classId box (via THE single emitter), then to externref
        emit_raw!(b, value_bytes; pushes=WasmValType[src_type])
        emit_classid_box!(b, ctx, src_type, nothing)
        extern_convert_any!(b)
        return true
    elseif phi_local_type === AnyRef && _num(src_type)
        # numeric → AnyRef: classId box (a struct ref is already an anyref subtype)
        emit_raw!(b, value_bytes; pushes=WasmValType[src_type])
        emit_classid_box!(b, ctx, src_type, nothing)
        return true
    elseif phi_local_type === ExternRef && _ref(src_type)
        # internal ref → ExternRef
        emit_raw!(b, value_bytes; pushes=WasmValType[src_type])
        extern_convert_any!(b)
        return true
    elseif _num(phi_local_type) && _ref(src_type)
        # THE missing arm — UNBOX a classId box into a numeric phi local (inverse of the
        # numeric→AnyRef box arm above). Well-typed numeric phi ⟹ the edge is a numeric box,
        # so the ref.cast inside emit_classid_unbox! succeeds; a genuine mistype traps (loud).
        emit_raw!(b, value_bytes; pushes=WasmValType[src_type])
        src_type === ExternRef && any_convert_extern!(b)
        emit_classid_unbox!(b, ctx, phi_local_type)
        return true
    end
    return false
end

"""
Emit bytecode to store a phi edge value to a phi local, with type compatibility checking.
If the edge value type is incompatible with the phi local type (e.g., ref vs numeric),
the store is skipped (these represent unreachable code paths in Union types).
If the edge value is i32 but the local is i64, adds I64_EXTEND_I32_S.
Returns true if the store was emitted, false if skipped.
"""
function emit_phi_local_set!(bytes::Vector{UInt8}, val, phi_ssa_idx::Int, ctx::AbstractCompilationContext)::Bool
    # Migrated onto the typed InstrBuilder: all straight-line emission goes onto the
    # local builder `lb`; the byte-INSPECTING branches (which scan `value_bytes` from
    # compile_value) keep their raw buffers; at every exit we flush lb into the
    # passed-in `bytes` accumulator (byte-identical splice). _ret wraps each return.
    lb = InstrBuilder(; func_name="emit_phi_local_set!", strict=false)
    _ret = (x) -> (append!(bytes, builder_code(lb)); x)
    if !haskey(ctx.phi_locals, phi_ssa_idx)
        return _ret(false)
    end
    local_idx = ctx.phi_locals[phi_ssa_idx]
    phi_local_type = ctx.locals[local_idx - ctx.n_params + 1]
    edge_val_type = get_phi_edge_wasm_type(val, ctx)

    if edge_val_type !== nothing && !wasm_types_compatible(phi_local_type, edge_val_type)
        # PURE-324: Allow I32→I64 widening — handled by I64_EXTEND_I32_S below.
        # PURE-1101: Allow numeric widening to F64/F32 (Union{Int64,Float64} etc.)
        if phi_local_type === I64 && edge_val_type === I32
            # Handled below by I64_EXTEND_I32_S
        elseif phi_local_type === F64 && (edge_val_type === I64 || edge_val_type === I32 || edge_val_type === F32)
            # Handled below by F64_CONVERT_I64_S / F64_CONVERT_I32_S / F64_PROMOTE_F32
        elseif phi_local_type === F32 && (edge_val_type === I64 || edge_val_type === I32)
            # Handled below by F32_CONVERT_I64_S / F32_CONVERT_I32_S
        elseif phi_local_type === ExternRef && (edge_val_type === I32 || edge_val_type === I64 || edge_val_type === F32 || edge_val_type === F64)
            # PURE-325: Box numeric value for ExternRef phi local (Union return).
            # When a function with Union return type is inlined, the return becomes
            # a phi node assignment. Numeric values must be boxed to externref.
            value_bytes, _pe_vty = compile_value_typed(val, ctx)
            if !isempty(value_bytes)
                emit_raw!(lb, value_bytes; pushes=(_pe_vty === nothing ? WasmValType[] : WasmValType[_pe_vty]))
                emit_classid_box!(lb, ctx, edge_val_type, nothing)   # THE single box emitter
                extern_convert_any!(lb)
                local_set!(lb, local_idx)
                return _ret(true)
            end
            return _ret(false)
        elseif phi_local_type === AnyRef && (edge_val_type === I32 || edge_val_type === I64 || edge_val_type === F32 || edge_val_type === F64)
            # SELFHOST-008: Box numeric value for AnyRef phi local (Union{Nothing,T}).
            # When nothing is compiled as i32.const 0 but the phi local is anyref,
            # we need ref.null any for nothing, or boxing for real numeric values.
            if (val === nothing || (val isa GlobalRef && val.name === :nothing))
                # nothing → ref.null any
                ref_null!(lb, AnyRef)
                local_set!(lb, local_idx)
                return _ret(true)
            end
            # Real numeric value → box to anyref via THE single box emitter
            value_bytes, _pe_vty = compile_value_typed(val, ctx)
            if !isempty(value_bytes)
                emit_raw!(lb, value_bytes; pushes=(_pe_vty === nothing ? WasmValType[] : WasmValType[_pe_vty]))
                emit_classid_box!(lb, ctx, edge_val_type, nothing)
                local_set!(lb, local_idx)
                return _ret(true)
            end
            return _ret(false)
        elseif phi_local_type === ExternRef && (edge_val_type isa ConcreteRef || edge_val_type === StructRef || edge_val_type === ArrayRef || edge_val_type === AnyRef)
            # PURE-3113: ConcreteRef/StructRef/ArrayRef/AnyRef → ExternRef conversion
            # Mirrors the handling in set_phi_locals_for_edge! (line 10213) and compile_phi_value (line 9825)
            @debug "PURE-3113 FIX A: phi=$phi_ssa_idx edge_val_type=$edge_val_type phi_local_type=$phi_local_type"
            value_bytes = compile_value(val, ctx)
            if !isempty(value_bytes)
                emit_raw!(lb, value_bytes; pushes=(edge_val_type === nothing ? WasmValType[] : WasmValType[edge_val_type]))
                # ref.null is already externref — don't wrap
                if !is_nothing_value(val, ctx)
                    extern_convert_any!(lb)
                end
                local_set!(lb, local_idx)
                return _ret(true)
            end
            return _ret(false)
        elseif phi_local_type isa ConcreteRef && (edge_val_type === AnyRef || edge_val_type === EqRef || edge_val_type === StructRef || edge_val_type === ArrayRef)
            # AnyRef/EqRef/StructRef/ArrayRef → ConcreteRef: narrow with ref.cast_nullable
            value_bytes = compile_value(val, ctx)
            if !isempty(value_bytes)
                if is_nothing_value(val, ctx)
                    # ref.null can't be cast — emit type-appropriate null instead
                    ref_null!(lb, Int64(phi_local_type.type_idx), phi_local_type)
                else
                    emit_raw!(lb, value_bytes; pushes=(edge_val_type === nothing ? WasmValType[] : WasmValType[edge_val_type]))
                    # REF_CAST_NULL with UNSIGNED-LEB idx (preserve exact original bytes;
                    # the typed ref_cast! encodes signed, so bridge this site).
                    let cb = UInt8[]
                        push!(cb, Opcode.GC_PREFIX); push!(cb, Opcode.REF_CAST_NULL)
                        append!(cb, encode_leb128_unsigned(phi_local_type.type_idx))
                        emit_raw!(lb, cb; pops=1, pushes=(phi_local_type === nothing ? WasmValType[] : WasmValType[phi_local_type]))
                    end
                end
                local_set!(lb, local_idx)
                return _ret(true)
            end
            return _ret(false)
        elseif (phi_local_type === I64 || phi_local_type === I32 || phi_local_type === F64 || phi_local_type === F32) &&
               (edge_val_type === AnyRef || edge_val_type === EqRef || edge_val_type === StructRef || edge_val_type === ExternRef || edge_val_type isa ConcreteRef)
            # Loop C flow/phi dedup: UNBOX a classId box into a numeric phi local via the single
            # shared converter (the arm that was missing here → i64.const 0, Any[i]→0).
            if _emit_phi_edge_convert!(lb, ctx, phi_local_type, edge_val_type, compile_value(val, ctx))
                local_set!(lb, local_idx)
                return _ret(true)
            end
            return _ret(false)
        else
            # PURE-6025: Type mismatch — emit type-safe default instead of skipping.
            # Skipping leaves the local uninitialized, but we need a valid value
            # for the Wasm type checker (e.g., ConcreteRef local must have ref.null, not i32).
            if phi_local_type isa ConcreteRef
                ref_null!(lb, Int64(phi_local_type.type_idx), phi_local_type)
            elseif phi_local_type === StructRef
                ref_null!(lb, StructRef)
            elseif phi_local_type === ArrayRef
                ref_null!(lb, ArrayRef)
            elseif phi_local_type === ExternRef
                ref_null!(lb, ExternRef)
            elseif phi_local_type === AnyRef
                ref_null!(lb, AnyRef)
            elseif phi_local_type === I64
                i64_const!(lb, 0)
            elseif phi_local_type === I32
                i32_const!(lb, 0)
            else
                i32_const!(lb, 0)
            end
            local_set!(lb, local_idx)
            return _ret(true)
        end
    end

    # When edge_val_type is nothing (Any/Union SSA type), check the actual local's Wasm type
    if edge_val_type === nothing && val isa Core.SSAValue
        val_local_idx = nothing
        if haskey(ctx.ssa_locals, val.id)
            val_local_idx = ctx.ssa_locals[val.id]
        elseif haskey(ctx.phi_locals, val.id)
            val_local_idx = ctx.phi_locals[val.id]
        end
        if val_local_idx !== nothing
            val_local_array_idx = val_local_idx - ctx.n_params + 1
            if val_local_array_idx >= 1 && val_local_array_idx <= length(ctx.locals)
                val_local_type = ctx.locals[val_local_array_idx]
                if !wasm_types_compatible(phi_local_type, val_local_type)
                    # Loop C flow/phi dedup: box / cast / UNBOX via the single shared converter.
                    # The UNBOX arm (numeric phi local ← classId-box SSA local) is what was
                    # missing on THIS Any-typed-edge path → i64.const 0 → Any[1,2,3][i] → 0.
                    if _emit_phi_edge_convert!(lb, ctx, phi_local_type, val_local_type, compile_value(val, ctx))
                        local_set!(lb, local_idx)
                        return _ret(true)
                    end
                    # Incompatible: emit type-safe default for phi local type
                    if phi_local_type isa ConcreteRef
                        ref_null!(lb, Int64(phi_local_type.type_idx), phi_local_type)
                    elseif phi_local_type === StructRef
                        ref_null!(lb, StructRef)
                    elseif phi_local_type === ArrayRef
                        ref_null!(lb, ArrayRef)
                    elseif phi_local_type === ExternRef
                        ref_null!(lb, ExternRef)
                    elseif phi_local_type === AnyRef
                        ref_null!(lb, AnyRef)
                    elseif phi_local_type === I64
                        i64_const!(lb, 0)
                    elseif phi_local_type === I32
                        i32_const!(lb, 0)
                    elseif phi_local_type === F64
                        f64_const!(lb, 0.0)
                    elseif phi_local_type === F32
                        f32_const!(lb, 0.0)
                    else
                        i32_const!(lb, 0)
                    end
                    local_set!(lb, local_idx)
                    return _ret(true)
                end
            end
        end
    end

    value_bytes = compile_value(val, ctx)
    if isempty(value_bytes)
        return _ret(false)
    end

    # Safety check: if compile_value produced MULTIPLE local_get instructions
    # (e.g., from a multi-value SSA like memoryrefnew that pushes [base, index]),
    # we can't store 2+ values in a single phi local. Emit type-safe default instead.
    if length(value_bytes) >= 4 && value_bytes[1] == 0x20
        _multi_pos = 1
        _multi_count = 0
        _all_local_gets = true
        while _multi_pos <= length(value_bytes)
            if value_bytes[_multi_pos] != 0x20
                _all_local_gets = false
                break
            end
            _multi_pos += 1
            while _multi_pos <= length(value_bytes) && (value_bytes[_multi_pos] & 0x80) != 0
                _multi_pos += 1
            end
            _multi_pos += 1
            _multi_count += 1
        end
        if _all_local_gets && _multi_pos > length(value_bytes) && _multi_count > 1
            # Multi-value: emit type-safe default for phi local instead
            if phi_local_type isa ConcreteRef
                ref_null!(lb, Int64(phi_local_type.type_idx), phi_local_type)
            elseif phi_local_type === ExternRef
                ref_null!(lb, ExternRef)
            elseif phi_local_type === StructRef
                ref_null!(lb, StructRef)
            elseif phi_local_type === ArrayRef
                ref_null!(lb, ArrayRef)
            elseif phi_local_type === AnyRef
                ref_null!(lb, AnyRef)
            elseif phi_local_type === I64
                i64_const!(lb, 0)
            elseif phi_local_type === I32
                i32_const!(lb, 0)
            elseif phi_local_type === F64
                f64_const!(lb, 0.0)
            elseif phi_local_type === F32
                f32_const!(lb, 0.0)
            else
                i32_const!(lb, 0)
            end
            local_set!(lb, local_idx)
            return _ret(true)
        end
    end

    # Safety check: if compile_value produced a local.get, verify actual local type
    if length(value_bytes) >= 2 && value_bytes[1] == 0x20  # LOCAL_GET
        got_local_idx = 0
        shift = 0
        for bi in 2:length(value_bytes)
            b = value_bytes[bi]
            got_local_idx |= (Int(b & 0x7f) << shift)
            shift += 7
            if (b & 0x80) == 0
                break
            end
        end
        got_local_array_idx = got_local_idx - ctx.n_params + 1
        actual_val_type = nothing
        if got_local_array_idx >= 1 && got_local_array_idx <= length(ctx.locals)
            actual_val_type = ctx.locals[got_local_array_idx]
        elseif got_local_idx < ctx.n_params
            # It's a parameter - get Wasm type from arg_types
            param_julia_type = ctx.arg_types[got_local_idx + 1]  # Julia is 1-indexed
            actual_val_type = get_concrete_wasm_type(param_julia_type, ctx.mod, ctx.type_registry)
        end
        if actual_val_type !== nothing && !wasm_types_compatible(phi_local_type, actual_val_type)
                # PURE-324: Allow I32→I64 — will be extended at line below
                # PURE-1101: Allow numeric widening to F64/F32
                if phi_local_type === I64 && actual_val_type === I32
                    # Handled below by I64_EXTEND_I32_S
                elseif phi_local_type === F64 && (actual_val_type === I64 || actual_val_type === I32 || actual_val_type === F32)
                    # Handled below by F64_CONVERT_I64_S / F64_CONVERT_I32_S / F64_PROMOTE_F32
                elseif phi_local_type === F32 && (actual_val_type === I64 || actual_val_type === I32)
                    # Handled below by F32_CONVERT_I64_S / F32_CONVERT_I32_S
                elseif phi_local_type === ExternRef && (actual_val_type === I32 || actual_val_type === I64 || actual_val_type === F32 || actual_val_type === F64)
                    # PURE-325: Box numeric local.get for ExternRef phi local — THE single box emitter
                    emit_raw!(lb, value_bytes; pushes=WasmValType[actual_val_type])
                    emit_classid_box!(lb, ctx, actual_val_type, nothing)
                    extern_convert_any!(lb)
                    local_set!(lb, local_idx)
                    return _ret(true)
                elseif phi_local_type === ExternRef && (actual_val_type isa ConcreteRef || actual_val_type === StructRef || actual_val_type === ArrayRef || actual_val_type === AnyRef)
                    # PURE-3113: ConcreteRef/StructRef/ArrayRef/AnyRef → ExternRef conversion
                    emit_raw!(lb, value_bytes; pushes=(actual_val_type === nothing ? WasmValType[] : WasmValType[actual_val_type]))
                    if !is_nothing_value(val, ctx)
                        extern_convert_any!(lb)
                    end
                    local_set!(lb, local_idx)
                    return _ret(true)
                else
                    # Incompatible actual type: emit type-safe default
                    if phi_local_type isa ConcreteRef
                        ref_null!(lb, Int64(phi_local_type.type_idx), phi_local_type)
                    elseif phi_local_type === ExternRef
                        ref_null!(lb, ExternRef)
                    elseif phi_local_type === StructRef
                        ref_null!(lb, StructRef)
                    elseif phi_local_type === ArrayRef
                        ref_null!(lb, ArrayRef)
                    elseif phi_local_type === AnyRef
                        ref_null!(lb, AnyRef)
                    elseif phi_local_type === I64
                        i64_const!(lb, 0)
                    elseif phi_local_type === I32
                        i32_const!(lb, 0)
                    elseif phi_local_type === F64
                        f64_const!(lb, 0.0)
                    elseif phi_local_type === F32
                        f32_const!(lb, 0.0)
                    else
                        i32_const!(lb, 0)
                    end
                    local_set!(lb, local_idx)
                    return _ret(true)
                end
        end
    end

    # PURE-3113: Final safety net — if we're about to store a ConcreteRef-typed local.get into an ExternRef phi,
    # add extern_convert_any. This catches cases where edge_val_type/actual_val_type reported ExternRef
    # but the underlying Wasm local was allocated as a ConcreteRef.
    if phi_local_type === ExternRef && length(value_bytes) >= 2 && value_bytes[1] == 0x20  # LOCAL_GET
        _final_got_idx = 0; _final_shift = 0; _final_leb_end = 0
        for bi in 2:length(value_bytes)
            b = value_bytes[bi]
            _final_got_idx |= (Int(b & 0x7f) << _final_shift)
            _final_shift += 7
            if (b & 0x80) == 0
                _final_leb_end = bi
                break
            end
        end
        if _final_leb_end == length(value_bytes)  # Pure local.get (no trailing ops)
            _final_arr_idx = _final_got_idx - ctx.n_params + 1
            if _final_arr_idx >= 1 && _final_arr_idx <= length(ctx.locals)
                _final_src_type = ctx.locals[_final_arr_idx]
                if _final_src_type isa ConcreteRef || _final_src_type === StructRef || _final_src_type === ArrayRef || _final_src_type === AnyRef
                    emit_raw!(lb, value_bytes; pushes=(_final_src_type === nothing ? WasmValType[] : WasmValType[_final_src_type]))
                    extern_convert_any!(lb)
                    local_set!(lb, local_idx)
                    return _ret(true)
                end
            end
        end
    end

    # PURE-6025: Final safety net — if value_bytes is a numeric constant (i32_const, i64_const, etc.)
    # but the phi local is ref-typed, emit type-safe default instead.
    # This catches cases where a UInt8 enum value (e.g., ExternRef=0x6f=111) is compiled
    # as i32_const 111 but the phi local expects (ref null $type).
    if !isempty(value_bytes) && (phi_local_type isa ConcreteRef || phi_local_type === StructRef || phi_local_type === ArrayRef || phi_local_type === AnyRef) &&
       (value_bytes[1] == Opcode.I32_CONST || value_bytes[1] == Opcode.I64_CONST || value_bytes[1] == Opcode.F32_CONST || value_bytes[1] == Opcode.F64_CONST)
        if phi_local_type isa ConcreteRef
            ref_null!(lb, Int64(phi_local_type.type_idx), phi_local_type)
        elseif phi_local_type === StructRef
            ref_null!(lb, StructRef)
        elseif phi_local_type === ArrayRef
            ref_null!(lb, ArrayRef)
        elseif phi_local_type === AnyRef
            ref_null!(lb, AnyRef)
        end
        local_set!(lb, local_idx)
        return _ret(true)
    end

    emit_raw!(lb, value_bytes; pushes=WasmValType[edge_val_type === nothing ? AnyRef : edge_val_type])
    # Widen numeric types if needed
    # PURE-324: Skip extend if value bytes are already the target type (e.g., i64_const default)
    if edge_val_type !== nothing && phi_local_type === I64 && edge_val_type === I32 && (isempty(value_bytes) || value_bytes[1] != Opcode.I64_CONST)
        num!(lb, Opcode.I64_EXTEND_I32_S)
    elseif edge_val_type !== nothing && phi_local_type === F64 && edge_val_type === I64
        num!(lb, Opcode.F64_CONVERT_I64_S)
    elseif edge_val_type !== nothing && phi_local_type === F64 && edge_val_type === I32
        num!(lb, Opcode.F64_CONVERT_I32_S)
    elseif edge_val_type !== nothing && phi_local_type === F64 && edge_val_type === F32
        num!(lb, Opcode.F64_PROMOTE_F32)
    elseif edge_val_type !== nothing && phi_local_type === F32 && edge_val_type === I64
        num!(lb, Opcode.F32_CONVERT_I64_S)
    elseif edge_val_type !== nothing && phi_local_type === F32 && edge_val_type === I32
        num!(lb, Opcode.F32_CONVERT_I32_S)
    end
    local_set!(lb, local_idx)
    return _ret(true)
end

