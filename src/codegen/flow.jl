"""
Generate code using Wasm's structured control flow.
For simple if-then-else patterns, we use the `if` instruction.
parity(code_generator.dart:228 AstCodeGenerator.generate)
"""
function generate_structured(ctx::AbstractCompilationContext, blocks::Vector{BasicBlock})::Vector{UInt8}
    b = _ctx_builder(ctx, "generate_structured")
    # parity(code_generator.dart:28 CodeGenerator) ONE LOWERING (dart: one CodeGenerator, one structured lowering, no strategy
    # choice): every CFG shape, including a single block and try/catch, goes through
    # THE stackifier. Retired strategies this replaced: the nested-conditional
    # family (a documented multivar-phi miscompiler), generate_void_flow (missing pre-loop
    # phi init), and generate_loop_code + generate_branched_loops (no-phi loops).
    # Try regions are first-class stackifier metadata; handler blocks remain plain
    # CFG blocks and the same phi machinery owns all of their edges.
    regions = has_try_catch(ctx.nir) ? Vector{Any}(find_try_regions(ctx.nir)) : Any[]
    generate_stackified_flow!(b, ctx, blocks; try_regions=regions)

    # Close exactly the seeded function frame. Any remaining block/loop is a
    # stackifier bug and must fail here, never serialize into malformed Wasm.
    finish_function!(b)

    return builder_code(b)
end


"""
Determine the Wasm type that a phi edge value will produce on the stack.
Used to check compatibility before storing to a phi local.
"""
function get_phi_edge_wasm_type(val::NirNode, ctx::AbstractCompilationContext)::Union{WasmValType, Nothing}
    # Handle GlobalRef to nothing (e.g., Compiler.nothing, Base.nothing)
    # These compile to i32_const 0 just like literal nothing
    if val isa NirGlobalRef && val.name === :nothing
        return I32
    end
    if val isa NirSSA
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
            return get_concrete_wasm_type(edge_julia_type, ctx.mod, ctx.type_registry; for_local=true)
        end
    elseif val isa NirSlot
        # SlotNumber in unoptimized IR — check slot_locals first
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
            source_type !== nothing && return get_concrete_wasm_type(source_type, ctx.mod, ctx.type_registry; for_local=true)
        end
    elseif val isa NirArgument
        # Use the ACTUAL Wasm parameter type from arg_types, not the Julia slottype.
        # Julia IR uses _1 for function type (not in arg_types), _2 for first arg (arg_types[1]), etc.
        # So arg_types index = val.n - 1 for non-closures.
        arg_types_idx = val.n - 1  # _2 → arg_types[1], _3 → arg_types[2], etc.
        if arg_types_idx >= 1 && arg_types_idx <= length(ctx.arg_types)
            local _arg_t = ctx.arg_types[arg_types_idx]
            # Union params promoted to anyref for dispatch
            if _arg_t isa Union && needs_anyref_boxing(_arg_t)
                return AnyRef
            end
            return get_concrete_wasm_type(_arg_t, ctx.mod, ctx.type_registry)
        end
    elseif val isa NirGlobalRef
        # Resolve GlobalRef to actual value to determine Wasm type
        val.bound || return nothing
        return get_phi_edge_wasm_type(NirLiteral(val.value), ctx)
    elseif val isa NirLiteral
        lit = val.value
        # Handle nothing literal - compile_value(nothing) emits i32_const 0
        if lit === nothing
            return I32
        elseif lit isa Int64 || lit isa UInt64 || lit isa Int
            return I64
        elseif lit isa Int32 || lit isa UInt32 || lit isa Bool || lit isa UInt8 || lit isa Int8 || lit isa UInt16 || lit isa Int16
            return I32
        elseif lit isa Float64
            return F64
        elseif lit isa Float32
            return F32
        elseif lit isa Symbol || lit isa String
            # parity(constants.dart:1714 TypeOfConstantVisitor.visitStringConstant, :1739 visitSymbolConstant): String/Symbol constants are the CLASSED string struct
            str_type_idx = get_string_struct_type!(ctx.mod, ctx.type_registry)
            return ConcreteRef(str_type_idx, false)
        elseif lit isa Char
            # Char is a 4-byte primitive, compiled as I32
            return I32
        elseif lit isa Type
            # Type{T} values are now represented as DataType struct refs (global.get).
            # Use $JlDataType when hierarchy is available
            dt_idx = get_datatype_type_idx(ctx.type_registry)
            return ConcreteRef(dt_idx, true)
        elseif isstructtype(typeof(lit))
            # a struct literal is compiled as struct_new → a non-nullable concrete ref
            return get_concrete_wasm_type(typeof(lit), ctx.mod, ctx.type_registry)
        end
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
    # (requires ref.cast to downcast from abstract/super to concrete); the reverse — a
    # concrete ref into its abstract supertype local — is a plain wasm subtype store.
    if local_type isa ConcreteRef && (value_type === StructRef || value_type === ArrayRef || value_type === AnyRef || value_type === EqRef)
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

"""Convert one already-emitted phi edge value to the phi `phi_idx`'s local, using its proven
Julia type. An edge whose Julia type is wider than the phi's numeric type takes the guarded
form of `_emit_phi_edge_guarded_unbox!`.
parity(code_generator.dart:665 AstCodeGenerator.translateExpression)
"""
function _emit_phi_edge_convert!(b::InstrBuilder, ctx::AbstractCompilationContext,
                                 phi_local_type, src_type, src::InstrBuilder,
                                 src_julia::Type, phi_idx::Int)::Bool
    isempty(src.instrs) && return false
    (!_wt_is_ref(src_type) && _wt_is_ref(phi_local_type) && !isconcretetype(src_julia)) &&
        return false
    local phi_julia = get(ctx.ssa_types, phi_idx, Any)
    if _wt_is_ref(src_type) && !_wt_is_ref(phi_local_type) &&
       phi_julia isa DataType && isconcretetype(phi_julia) && !(src_julia <: phi_julia)
        return _emit_phi_edge_guarded_unbox!(b, ctx, phi_local_type, src_type, src,
                                              phi_julia, phi_idx)
    end
    append_builder!(b, src)
    coerce_stack_top!(b, phi_local_type, ctx;
                      from_julia=isconcretetype(src_julia) ? src_julia : nothing)
    return true
end

"""
    _emit_phi_edge_guarded_unbox!(b, ctx, phi_local_type, src_type, src, phi_julia, phi_idx)

A phi's Julia type may be narrower than the type of a value flowing in on one of its
edges: inference types the phi by the paths on which it is used, so `nothing` (or any value
of another class) can reach an `Int64` phi on a path that never reads it. The edge unboxes
only when the value is a `phi_julia` box; otherwise the phi keeps its local's current
content, which no path reads. Unguarded, the unbox's `ref.cast` traps on that path.

parity(quarantine: Julia types a phi narrower than an edge value's type; Julia's own codegen
(src/codegen.cpp emit_phinode: `isvalid = emit_isa_and_defined(ctx, val, phiType)` then
`emit_guarded_test(ctx, isvalid, undef, emit_unbox)`) gives the phi an undefined value on
that edge instead of trapping. dart's phis are typed by the join of their inputs, so dart
has no such edge.)
"""
function _emit_phi_edge_guarded_unbox!(b::InstrBuilder, ctx::AbstractCompilationContext,
                                       phi_local_type::WasmValType, src_type::WasmValType,
                                       src::InstrBuilder, phi_julia::DataType,
                                       phi_idx::Int)::Bool
    haskey(ctx.phi_locals, phi_idx) || return false
    append_builder!(b, src)
    src_type === ExternRef && any_convert_extern!(b)
    # the edge value, held for the class test and the unbox
    local val_local = allocate_local!(ctx, AnyRef)
    builder_set_local_type!(b, val_local, AnyRef)
    local_set!(b, val_local)
    local box_idx = get_numeric_box_type!(ctx.mod, ctx.type_registry, phi_local_type)
    local_get!(b, val_local)
    emit_isa_classid!(b, ctx, box_idx, phi_julia)
    if_!(b, phi_local_type)
    local_get!(b, val_local)
    emit_classid_unbox!(b, ctx, phi_local_type)
    else_!(b)
    local_get!(b, ctx.phi_locals[phi_idx])
    end_block!(b)
    return true
end
