"""
Generate code using Wasm's structured control flow.
For simple if-then-else patterns, we use the `if` instruction.
"""
function generate_structured(ctx::AbstractCompilationContext, blocks::Vector{BasicBlock})::Vector{UInt8}
    b = InstrBuilder(; func_name="generate_structured", strict=false)
    code = ctx.code_info.code
    # Check for try/catch first
    if has_try_catch(code)
        emit_raw!(b, generate_try_catch(ctx, blocks, code))
    # Check for loops: use stackified flow for complex loops with phi nodes,
    # simple loop code for basic single-loop patterns
    elseif has_loop(ctx)
        # Count conditionals and phi nodes to decide routing
        has_phi = any(stmt isa Core.PhiNode for stmt in code)
        if has_phi
            # Loop with phi nodes: the stackified flow handles loops, forward
            # jumps, and phi merge points all together correctly.
            # generate_loop_code can't handle phi nodes at loop headers.
            emit_raw!(b, generate_complex_flow(ctx, blocks, code))
        else
            emit_raw!(b, generate_loop_code(ctx))
        end
    elseif length(blocks) == 1
        # Single block - just generate statements
        emit_raw!(b, generate_block_code(ctx, blocks[1]))
    elseif is_simple_conditional(blocks, code)
        # Simple if-then-else pattern
        emit_raw!(b, generate_if_then_else(ctx, blocks, code))
    else
        # More complex control flow - use block/br structure
        emit_raw!(b, generate_complex_flow(ctx, blocks, code))
    end

    # Always end with END opcode
    end_block!(b)

    return builder_code(b)
end

"""
Generate code for "branched loops" pattern where a conditional before the first loop
jumps past it to an alternate code path with its own loop.
Example: float_to_string where negative/positive branches each have their own loop.

Structure:
  if (condition)
    ; first branch code (with loop 1)
  else
    ; second branch code (with loop 2)
  end
"""
function generate_branched_loops(ctx::AbstractCompilationContext, first_header::Int, first_back_edge::Int,
                                  cond_idx::Int, second_branch_start::Int,
                                  ssa_use_count::Dict{Int, Int})::Vector{UInt8}
    b = InstrBuilder(; func_name="generate_branched_loops", strict=false)
    code = ctx.code_info.code

    # Identify dead code regions (boundscheck patterns)
    # Since we emit i32.const 0 for ALL boundscheck expressions,
    # the GotoIfNot following a boundscheck ALWAYS jumps to the target.
    # Pattern: boundscheck at line N, GotoIfNot %N at line N+1
    # Dead code: lines from N+2 to target-1 (the fall-through path)
    # Note: We DON'T skip the boundscheck or GotoIfNot - we compile them normally
    # so the control flow (BR) is properly emitted.
    dead_regions = Set{Int}()
    for i in 1:length(code)
        stmt = code[i]
        if stmt isa Expr && stmt.head === :boundscheck && length(stmt.args) == 1
            if i + 1 <= length(code) && code[i + 1] isa Core.GotoIfNot
                goto_stmt = code[i + 1]
                if goto_stmt.cond isa Core.SSAValue && goto_stmt.cond.id == i
                    # Mark lines between the GotoIfNot and its target as dead
                    # (the fall-through path that's never taken)
                    for j in (i + 2):(goto_stmt.dest - 1)
                        push!(dead_regions, j)
                    end
                end
            end
        end
    end

    # For now, just use simple sequential code generation with explicit returns
    # Both branches end with return, so we can just compile sequentially

    # The conditional is at cond_idx: goto %second_branch_start if not %cond
    # If condition is TRUE: fall through to first branch (lines cond_idx+1 to second_branch_start-1)
    # If condition is FALSE: jump to second branch (lines second_branch_start to end)

    # First, compile statements before the conditional
    for i in 1:(cond_idx - 1)
        # Skip dead code (boundscheck patterns)
        if i in dead_regions
            continue
        end

        stmt = code[i]
        if stmt === nothing
            continue
        elseif stmt isa Core.GotoIfNot || stmt isa Core.GotoNode || stmt isa Core.PhiNode
            # Control flow handled specially
            continue
        else
            emit_raw!(b, compile_statement(stmt, i, ctx))
        end
    end

    # Get the condition and compile it
    cond_stmt = code[cond_idx]::Core.GotoIfNot
    emit_raw!(b, compile_condition_to_i32(cond_stmt.cond, ctx); pushes=WasmValType[I32])

    # Create if/else structure
    # When condition is TRUE: first branch
    # When condition is FALSE (after EQZ): second branch
    if_!(b)  # void block type

    # THEN branch: first loop branch (lines cond_idx+1 to second_branch_start-1)
    # This includes the first loop
    for i in (cond_idx + 1):(second_branch_start - 1)
        # Skip dead code (boundscheck patterns)
        if i in dead_regions
            continue
        end

        stmt = code[i]
        if stmt === nothing
            continue
        elseif stmt isa Core.ReturnNode
            if isdefined(stmt, :val)
                val_wasm_type = infer_value_wasm_type(stmt.val, ctx)
                ret_wasm_type = julia_to_wasm_type_concrete(ctx.return_type, ctx)
                func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                # PURE-315: Check numeric-to-ref BEFORE return_type_compatible
                is_numeric_val = val_wasm_type === I32 || val_wasm_type === I64 || val_wasm_type === F32 || val_wasm_type === F64
                is_ref_ret = func_ret_wasm isa ConcreteRef || func_ret_wasm === ExternRef || func_ret_wasm === StructRef || func_ret_wasm === ArrayRef || func_ret_wasm === AnyRef
                b = emit_return_coerced!(b, stmt.val, ctx)
            else
                unreachable!(b)
            end
        elseif stmt isa Core.GotoIfNot
            # Inner conditional - use IF to properly consume the condition
            # GotoIfNot: if NOT condition, jump to target
            # With IF: if condition is TRUE, execute then-branch (do nothing)
            #          if condition is FALSE, skip (which matches GotoIfNot semantics)
            # Since the dead code is already skipped via dead_regions,
            # we just need to consume the condition value
            emit_raw!(b, compile_condition_to_i32(stmt.cond, ctx); pushes=WasmValType[I32])
            if_!(b)  # void
            end_block!(b)  # Empty then-branch
            # Fall through to continue (else branch is the continuation)
        elseif stmt isa Core.GotoNode
            # Skip goto - control flow handled
            if stmt.label == first_header
                # Back-edge to loop - emit br
                # For now, just skip (the loop structure handles this)
            end
        elseif stmt isa Core.PhiNode
            # Phi - handled via locals
            continue
        else
            emit_raw!(b, compile_statement(stmt, i, ctx))

            # Drop unused values
            if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke) && !ctx.last_stmt_was_stub
                # P6-ioprint: unified with the main-path contract — the crude
                # `stmt_type !== Nothing` check dropped on an empty stack for
                # handlers that push no value (memoryrefset! et al.).
                stmt_type = get(ctx.ssa_types, i, Any)
                is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                if !is_nothing_union && statement_produces_wasm_value(stmt, i, ctx)
                    if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                        use_count = get(ssa_use_count, i, 0)
                        if use_count == 0
                            drop!(b)
                        end
                    end
                end
            end
        end
    end

    # ELSE branch: second loop branch (lines second_branch_start to end)
    else_!(b)

    for i in second_branch_start:length(code)
        # Skip dead code (boundscheck patterns)
        if i in dead_regions
            continue
        end

        stmt = code[i]
        if stmt === nothing
            continue
        elseif stmt isa Core.ReturnNode
            if isdefined(stmt, :val)
                val_wasm_type = infer_value_wasm_type(stmt.val, ctx)
                ret_wasm_type = julia_to_wasm_type_concrete(ctx.return_type, ctx)
                func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                # PURE-315: Check numeric-to-ref BEFORE return_type_compatible
                is_numeric_val = val_wasm_type === I32 || val_wasm_type === I64 || val_wasm_type === F32 || val_wasm_type === F64
                is_ref_ret = func_ret_wasm isa ConcreteRef || func_ret_wasm === ExternRef || func_ret_wasm === StructRef || func_ret_wasm === ArrayRef || func_ret_wasm === AnyRef
                b = emit_return_coerced!(b, stmt.val, ctx)
            else
                return_!(b)
            end
        elseif stmt isa Core.GotoIfNot
            # Inner conditional - use IF to consume condition
            emit_raw!(b, compile_condition_to_i32(stmt.cond, ctx); pushes=WasmValType[I32])
            if_!(b)  # void
            end_block!(b)  # Empty then-branch
        elseif stmt isa Core.GotoNode
            # Skip goto
            continue
        elseif stmt isa Core.PhiNode
            continue
        else
            emit_raw!(b, compile_statement(stmt, i, ctx))

            # Drop unused values
            if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke) && !ctx.last_stmt_was_stub
                # P6-ioprint: unified with the main-path contract — the crude
                # `stmt_type !== Nothing` check dropped on an empty stack for
                # handlers that push no value (memoryrefset! et al.).
                stmt_type = get(ctx.ssa_types, i, Any)
                is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                if !is_nothing_union && statement_produces_wasm_value(stmt, i, ctx)
                    if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                        use_count = get(ssa_use_count, i, 0)
                        if use_count == 0
                            drop!(b)
                        end
                    end
                end
            end
        end
    end

    end_block!(b)  # End if/else

    # Both branches return, so code after the if/else is unreachable
    # Add UNREACHABLE to satisfy WASM validation (function end needs result value on stack)
    unreachable!(b)

    return builder_code(b)
end

"""
Generate code for a loop structure.
Wasm loop structure:
  (block \$exit
    (loop \$continue
      ... body ...
      (br_if \$exit)  ; exit condition
      (br \$continue) ; loop back
    )
  )

Following dart2wasm patterns for inner conditionals:
- Loop exit: GotoIfNot with target > back_edge → br_if to outer block
- Inner conditional: GotoIfNot with target <= back_edge → nested block/br pattern
- Dead code (boundscheck false): Skip unreachable branches entirely
"""

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
            value_bytes = compile_value(val, ctx)
            if !isempty(value_bytes)
                emit_raw!(lb, value_bytes; pushes=WasmValType[edge_val_type])
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
            value_bytes = compile_value(val, ctx)
            if !isempty(value_bytes)
                emit_raw!(lb, value_bytes; pushes=WasmValType[edge_val_type])
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

function generate_loop_code(ctx::AbstractCompilationContext)::Vector{UInt8}
    b = InstrBuilder(; func_name="generate_loop_code", strict=false)
    code = ctx.code_info.code

    # Bridge for the byte-mutating helper emit_phi_local_set!(bytes,...) (net-0 stack
    # effect: pushes a value then local.set, or skips). Build into a temp buffer and
    # splice via emit_raw! so the byte output is unchanged.
    _phi_set! = (val, idx) -> (local tb = UInt8[]; emit_phi_local_set!(tb, val, idx, ctx); emit_raw!(b, tb))

    # Count SSA uses (for drop logic)
    ssa_use_count = Dict{Int, Int}()
    for stmt in code
        count_ssa_uses!(stmt, ssa_use_count)
    end

    # Find loop bounds (header to back-edge)
    first_header = findfirst(ctx.loop_headers)
    back_edge_idx = nothing
    for (i, stmt) in enumerate(code)
        if stmt isa Core.GotoNode && stmt.label == first_header
            back_edge_idx = i
            break
        end
    end
    if back_edge_idx === nothing
        back_edge_idx = length(code)
    end

    # Check for "branch past first loop" pattern (e.g., float_to_string)
    # This is when a conditional BEFORE the loop jumps PAST the loop to an alternate code path
    # that also contains its own loop (both branches have loops and end with return)
    branch_past_target = nothing
    branch_past_cond_idx = nothing
    for i in 1:(first_header - 1)
        stmt = code[i]
        if stmt isa Core.GotoIfNot && stmt.dest > back_edge_idx
            # Check if the alternate path actually has a SECOND LOOP
            # (i.e., there's a backward jump in the alternate path)
            has_second_loop = false
            for j in stmt.dest:length(code)
                if code[j] isa Core.GotoNode && code[j].label < j && code[j].label >= stmt.dest
                    has_second_loop = true
                    break
                end
            end
            if has_second_loop
                branch_past_target = stmt.dest
                branch_past_cond_idx = i
                break
            end
        end
    end

    # If we have a branch-past-loop pattern (both branches have loops), use a special handler
    if branch_past_target !== nothing
        return generate_branched_loops(ctx, first_header, back_edge_idx,
                                       branch_past_cond_idx, branch_past_target, ssa_use_count)
    end

    # Original single-loop code follows
    loop_header = first_header

    # Identify dead code regions (boundscheck patterns)
    # Since we emit i32.const 0 for ALL boundscheck expressions (both true and false),
    # the GotoIfNot following a boundscheck ALWAYS jumps to the target.
    # Pattern: boundscheck(true/false) at line N, GotoIfNot %N at line N+1
    # With boundscheck=0: GotoIfNot "if NOT 0" = "if TRUE" = always jump
    # Dead code: lines from N+2 to target-1 (the fall-through path)
    dead_regions = Set{Int}()
    boundscheck_jumps = Dict{Int, Int}()  # GotoIfNot line → target (for always-jump)
    for i in 1:length(code)
        stmt = code[i]
        # Handle BOTH boundscheck(true) and boundscheck(false) - we emit 0 for both
        if stmt isa Expr && stmt.head === :boundscheck && length(stmt.args) == 1
            # Check if next line is GotoIfNot using this boundscheck
            if i + 1 <= length(code) && code[i + 1] isa Core.GotoIfNot
                goto_stmt = code[i + 1]
                if goto_stmt.cond isa Core.SSAValue && goto_stmt.cond.id == i
                    # This GotoIfNot always jumps (we emit 0 for boundscheck)
                    boundscheck_jumps[i + 1] = goto_stmt.dest
                    # Mark the boundscheck itself and lines from i+2 to target-1 as dead
                    push!(dead_regions, i)  # boundscheck - no need to emit (it's always 0)
                    for j in (i + 2):(goto_stmt.dest - 1)
                        push!(dead_regions, j)
                    end
                end
            end
        end
    end

    # Identify inner conditional GotoIfNot statements (target within loop body)
    # Only for REAL conditionals (not boundscheck always-jump patterns or dead code)
    # IMPORTANT: Only scan from loop_header to back_edge_idx, NOT from line 1
    # Pre-loop conditionals (early returns) are NOT inner conditionals
    inner_conditionals = Dict{Int, Int}()  # GotoIfNot line → merge point
    for i in loop_header:back_edge_idx
        # Skip dead code and boundscheck jumps
        if i in dead_regions || haskey(boundscheck_jumps, i)
            continue
        end
        stmt = code[i]
        if stmt isa Core.GotoIfNot
            target = stmt.dest
            # Inner conditional: target is within loop, not the exit
            if target <= back_edge_idx && target > i
                inner_conditionals[i] = target
            end
        end
    end

    # ============================================================
    # PHASE 1: Generate PRE-LOOP code (lines 1 to loop_header - 1)
    # This handles early return guards, pre-loop conditionals, etc.
    # These must be generated BEFORE the block/loop structure.
    # ============================================================

    # Track if we open an IF for a pre-loop conditional that skips past the loop
    # This IF will be closed AFTER the loop ends
    post_loop_skip_phi_target = nothing  # phi target line if we have such a pattern

    if loop_header > 1
        # Track pre-loop blocks and their types:
        # :if_end - simple if-then, emit END at this line
        # :if_else - if-then-else, emit ELSE at this line (else branch start)
        # :if_else_end - if-then-else, emit END at this line (merge point after else)
        pre_loop_block_type = Dict{Int, Symbol}()  # line → type
        pre_loop_depth = 0
        # Track which GotoNodes should be skipped (they become implicit in if-else)
        skip_goto_at = Set{Int}()

        for i in 1:(loop_header - 1)
            # Skip dead code
            if i in dead_regions
                continue
            end

            stmt = code[i]

            # Check if we need to emit ELSE or END at this line
            if haskey(pre_loop_block_type, i)
                block_type = pre_loop_block_type[i]

                if block_type == :if_end
                    # Simple if-then: close the block
                    # Handle pre-loop phi at merge point (set then-value before END)
                    if code[i] isa Core.PhiNode && haskey(ctx.phi_locals, i)
                        phi_stmt = code[i]::Core.PhiNode
                        for (edge_idx, edge) in enumerate(phi_stmt.edges)
                            edge_stmt = get(code, edge, nothing)
                            if edge_stmt !== nothing && !(edge_stmt isa Core.GotoIfNot)
                                val = phi_stmt.values[edge_idx]
                                _phi_set!(val, i)
                                break
                            end
                        end
                    end
                    end_block!(b)
                    delete!(pre_loop_block_type, i)
                    pre_loop_depth -= 1

                elseif block_type == :if_else
                    # If-then-else: emit ELSE to start else branch
                    # First, set phi value from then-branch before leaving it
                    # Find the phi at the actual merge point
                    local _if_else_merge_point = 0
                    for (mp, mt) in pre_loop_block_type
                        if mt == :if_else_end && mp > i
                            _if_else_merge_point = mp
                            if code[mp] isa Core.PhiNode && haskey(ctx.phi_locals, mp)
                                phi_stmt = code[mp]::Core.PhiNode
                                # Find the then-edge (comes from before else_start)
                                for (edge_idx, edge) in enumerate(phi_stmt.edges)
                                    if edge < i
                                        val = phi_stmt.values[edge_idx]
                                        _phi_set!(val, mp)
                                        break
                                    end
                                end
                            end
                            break
                        end
                    end
                    # PURE-314: Also set then-branch edges for consecutive phis after merge point
                    if _if_else_merge_point > 0
                        for j in (_if_else_merge_point+1):min(length(code), loop_header - 1)
                            code[j] isa Core.PhiNode || break
                            haskey(ctx.phi_locals, j) || continue
                            succ_phi = code[j]::Core.PhiNode
                            for (edge_idx, edge) in enumerate(succ_phi.edges)
                                if edge < i  # then-branch edge
                                    _phi_set!(succ_phi.values[edge_idx], j)
                                end
                            end
                        end
                    end
                    else_!(b)
                    delete!(pre_loop_block_type, i)
                    # Note: depth stays the same (still inside the if-else)

                elseif block_type == :if_else_end
                    # If-then-else merge point: set else-branch phi value and END
                    if code[i] isa Core.PhiNode && haskey(ctx.phi_locals, i)
                        phi_stmt = code[i]::Core.PhiNode
                        # Find the else-edge: it's the edge with the LARGEST line number
                        # (else branch comes after then branch)
                        max_edge_idx = 0
                        max_edge = 0
                        for (edge_idx, edge) in enumerate(phi_stmt.edges)
                            if edge > max_edge
                                max_edge = edge
                                max_edge_idx = edge_idx
                            end
                        end
                        if max_edge_idx > 0
                            val = phi_stmt.values[max_edge_idx]
                            _phi_set!(val, i)
                        end
                    end
                    # PURE-314: Initialize consecutive single-edge phis AFTER the merge point.
                    # These are phis at i+1, i+2, etc. that only receive values from
                    # one branch (e.g., else-only). They must be set while still inside
                    # the if-else block (before END), otherwise they stay at default (0).
                    for j in (i+1):min(length(code), loop_header - 1)
                        code[j] isa Core.PhiNode || break
                        haskey(ctx.phi_locals, j) || continue
                        succ_phi = code[j]::Core.PhiNode
                        for (edge_idx, edge) in enumerate(succ_phi.edges)
                            _phi_set!(succ_phi.values[edge_idx], j)
                        end
                    end
                    end_block!(b)
                    delete!(pre_loop_block_type, i)
                    pre_loop_depth -= 1
                end
            end

            if stmt isa Core.PhiNode
                # Pre-loop phi nodes - they should have been initialized
                # by their incoming edges. Just skip.
                continue
            elseif stmt isa Core.GotoIfNot
                target = stmt.dest
                # Skip boundscheck always-jump patterns
                if haskey(boundscheck_jumps, i)
                    continue
                elseif target > back_edge_idx
                    # This conditional jumps PAST the loop (skip if-body AND loop)
                    # We need to use IF/ELSE: if condition true, execute if-body+loop
                    #                         if condition false, skip to post-loop

                    # Check for phi at target (post-loop phi)
                    # We need to set the phi local BEFORE the IF
                    if code[target] isa Core.PhiNode && haskey(ctx.phi_locals, target)
                        phi_stmt = code[target]::Core.PhiNode
                        for (edge_idx, edge) in enumerate(phi_stmt.edges)
                            if edge == i
                                val = phi_stmt.values[edge_idx]
                                _phi_set!(val, target)
                                break
                            end
                        end
                    end

                    # Use IF structure: if condition is TRUE, fall through to if-body
                    # The ELSE branch (implicit) skips to post-loop
                    emit_raw!(b, compile_condition_to_i32(stmt.cond, ctx); pushes=WasmValType[I32])
                    if_!(b)  # void block type
                    # This IF will be closed after the loop completes
                    # Store the target for later (we'll close this IF after loop ends)
                    post_loop_skip_phi_target = target  # Track phi target for post-loop skip
                    pre_loop_depth += 1
                elseif target >= loop_header
                    # This conditional jumps to or near the loop header
                    # It's a pre-loop conditional with fall-through to loop
                    # We need to handle this with a block for the then-branch

                    # Open block for the then-branch (fall-through path)
                    # The block ends at loop_header (when we transition to loop)
                    block!(b)
                    # Mark this block for closing - but since target >= loop_header,
                    # we'll need to close it before entering the loop
                    pre_loop_block_type[loop_header] = :if_end
                    pre_loop_depth += 1

                    # Branch past the block if condition is FALSE (skip then-branch)
                    emit_raw!(b, compile_condition_to_i32(stmt.cond, ctx); pushes=WasmValType[I32])
                    num!(b, Opcode.I32_EQZ)
                    br_if!(b, 0)
                elseif target > i && target < loop_header
                    # Inner pre-loop conditional (both branches before loop)
                    # Pattern: GotoIfNot jumps to target (else-branch start), fall-through is then-branch
                    #
                    # CRITICAL: Need to detect if-then-else-phi pattern:
                    #   GotoIfNot → then-branch → goto merge → else-branch → goto merge → phi at merge
                    #
                    # Check if this is if-then-else-phi pattern:
                    # 1. Look for a goto at target-1 that jumps past target
                    # 2. If found, that goto's target is the TRUE merge point

                    then_end_idx = target - 1
                    then_end_stmt = get(code, then_end_idx, nothing)

                    if then_end_stmt isa Core.GotoNode && then_end_stmt.label > target && then_end_stmt.label < loop_header
                        # This IS if-then-else-phi pattern
                        # then_end_stmt.label is the TRUE merge point (where phi is)
                        merge_point = then_end_stmt.label
                        else_start = target

                        # Compile condition BEFORE any control structure
                        emit_raw!(b, compile_condition_to_i32(stmt.cond, ctx); pushes=WasmValType[I32])

                        # Use IF/ELSE structure
                        if_!(b)  # void block type

                        # Mark: when we reach else_start, emit ELSE
                        # Mark: when we reach merge_point, emit END
                        pre_loop_block_type[else_start] = :if_else
                        pre_loop_block_type[merge_point] = :if_else_end
                        pre_loop_depth += 1

                        # Mark gotos at end of then-branch and else-branch to be skipped
                        # (they become implicit in the if/else structure)
                        push!(skip_goto_at, then_end_idx)  # goto at end of then-branch
                        # Find goto at end of else-branch (just before merge_point)
                        for j in (else_start):(merge_point - 1)
                            if code[j] isa Core.GotoNode && code[j].label == merge_point
                                push!(skip_goto_at, j)
                            end
                        end
                    else
                        # Simple if-then pattern (no else branch or simple merge)
                        # Handle pre-loop phi at target (set else-branch value)
                        if code[target] isa Core.PhiNode && haskey(ctx.phi_locals, target)
                            phi_stmt = code[target]::Core.PhiNode
                            for (edge_idx, edge) in enumerate(phi_stmt.edges)
                                if edge == i
                                    val = phi_stmt.values[edge_idx]
                                    _phi_set!(val, target)
                                    break
                                end
                            end
                        end

                        # Compile condition BEFORE any control structure
                        emit_raw!(b, compile_condition_to_i32(stmt.cond, ctx); pushes=WasmValType[I32])

                        # Use if-then structure: if condition is TRUE, execute then-branch
                        if_!(b)  # void block type
                        pre_loop_block_type[target] = :if_end
                        pre_loop_depth += 1
                        # The then-branch code follows (lines i+1 to target-1)
                        # When we reach target, we'll emit END
                    end
                end
            elseif stmt isa Core.GotoNode
                # Skip gotos that are implicit in if-else structure
                if i in skip_goto_at
                    continue
                end

                # Unconditional jump in pre-loop code
                if stmt.label >= loop_header
                    # Jump to loop - becomes fall-through (we're about to enter loop)
                    # Handle phi at target if needed
                    if stmt.label == loop_header
                        for (j, phi_stmt) in enumerate(code)
                            if j >= loop_header && phi_stmt isa Core.PhiNode && haskey(ctx.phi_locals, j)
                                for (edge_idx, edge) in enumerate(phi_stmt.edges)
                                    if edge == i
                                        val = phi_stmt.values[edge_idx]
                                        _phi_set!(val, j)
                                        break
                                    end
                                end
                            end
                        end
                    end
                    # No actual jump needed - will fall through to loop
                elseif haskey(pre_loop_block_type, stmt.label)
                    # Jump to a pre-loop merge point
                    if code[stmt.label] isa Core.PhiNode && haskey(ctx.phi_locals, stmt.label)
                        phi_stmt = code[stmt.label]::Core.PhiNode
                        for (edge_idx, edge) in enumerate(phi_stmt.edges)
                            if edge == i
                                val = phi_stmt.values[edge_idx]
                                _phi_set!(val, stmt.label)
                                break
                            end
                        end
                    end
                    br!(b, 0)
                end
            elseif stmt isa Core.ReturnNode
                # PURE-036ag/PURE-045: Early return in pre-loop code with ref conversion
                if isdefined(stmt, :val)
                    val_wasm_type = infer_value_wasm_type(stmt.val, ctx)
                    ret_wasm_type = julia_to_wasm_type_concrete(ctx.return_type, ctx)
                    func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                    # PURE-315: Check numeric-to-ref BEFORE return_type_compatible
                    is_numeric_val = val_wasm_type === I32 || val_wasm_type === I64 || val_wasm_type === F32 || val_wasm_type === F64
                    is_ref_ret = func_ret_wasm isa ConcreteRef || func_ret_wasm === ExternRef || func_ret_wasm === StructRef || func_ret_wasm === ArrayRef || func_ret_wasm === AnyRef
                    b = emit_return_coerced!(b, stmt.val, ctx)
                else
                    return_!(b)
                end
            elseif stmt === nothing
                # Skip nothing statements
            else
                # Regular statement
                emit_raw!(b, compile_statement(stmt, i, ctx))
            end
        end

        # Close any remaining pre-loop blocks
        for (line, block_type) in pre_loop_block_type
            # This shouldn't happen if control flow is handled correctly,
            # but emit END for any unclosed blocks
            end_block!(b)
            pre_loop_depth -= 1
        end
    end

    # ============================================================
    # Initialize LOOP phi node locals with their entry values
    # This MUST happen AFTER PHASE 1 (pre-loop code) because loop phi entry
    # values may reference pre-loop phi results.
    # ============================================================
    for (i, stmt) in enumerate(code)
        if stmt isa Core.PhiNode && haskey(ctx.phi_locals, i)
            # Only initialize if this is a LOOP phi (at or AFTER loop header)
            if i < loop_header
                continue
            end

            # Loop phis have an entry edge from before the loop header
            is_loop_phi = false
            entry_val = nothing

            for (edge_idx, edge) in enumerate(stmt.edges)
                if edge < loop_header
                    is_loop_phi = true
                    entry_val = stmt.values[edge_idx]
                    break
                end
            end

            if is_loop_phi && entry_val !== nothing
                _phi_set!(entry_val, i)
            end
        end
    end

    # ============================================================
    # PHASE 2: Generate LOOP code (lines loop_header to back_edge_idx)
    # ============================================================

    # block $exit (for breaking out of loop)
    block!(b)  # void block type

    # loop $continue
    loop!(b)  # void block type

    # Track block depth for inner conditionals
    # Key: merge point line number, Value: true if block is open
    open_blocks = Dict{Int, Bool}()
    current_depth = 0  # 0 = inside loop, additional depth for inner blocks

    # PURE-6024: Track dead code state to skip instructions after unreachable.
    # When a statement emits unreachable (Union{} type), record the depth.
    # Skip all subsequent statements until the block at that depth closes.
    dead_code_depth = -1  # -1 = not in dead code

    # Generate loop body (statements from loop_header to back_edge_idx)
    i = loop_header
    while i <= back_edge_idx
        # Check if we need to close any blocks at this merge point
        if haskey(open_blocks, i) && open_blocks[i]
            # Before closing the block, set the then-value for any phi at this merge point
            # The then-branch ends here, so we need to store the value
            if code[i] isa Core.PhiNode && haskey(ctx.phi_locals, i)
                phi_stmt = code[i]::Core.PhiNode
                # Find the then-value (edge from before this line, NOT the GotoIfNot)
                # The then-branch is the fall-through, so look for edge from line i-1
                for (edge_idx, edge) in enumerate(phi_stmt.edges)
                    # The then-edge comes from the line just before the merge (the last then-stmt)
                    # Or more precisely, any edge that's not the GotoIfNot line
                    edge_stmt = get(code, edge, nothing)
                    if edge_stmt !== nothing && !(edge_stmt isa Core.GotoIfNot)
                        val = phi_stmt.values[edge_idx]
                        _phi_set!(val, i)
                        break
                    end
                end
            end
            end_block!(b)
            open_blocks[i] = false
            current_depth -= 1
            # PURE-6024: If we were in dead code and the block at dead_code_depth
            # just closed, we're no longer in dead code
            if dead_code_depth >= 0 && current_depth <= dead_code_depth
                dead_code_depth = -1
                # PURE-6027: Also reset stub flag — this merge point starts a reachable block
                ctx.last_stmt_was_stub = false
            end
        end

        stmt = code[i]

        # P4-stdlib (Random / FINDINGS P4 dead-coding class): mirror
        # compile_statement's PURE-6027 boundary reset here — the walker
        # compiles GotoIfNot CONDITIONS via compile_condition_to_i32 without
        # passing through compile_statement, so a stub/throw flag from a
        # previous block leaked into conditions at reachable jump targets
        # (`i64.const 0; unreachable; i32.eqz` poisoned-condition trap).
        if ctx.last_stmt_was_stub && i > 1
            local _bw_prev = code[i - 1]
            if _bw_prev isa Core.GotoNode || _bw_prev isa Core.GotoIfNot || _bw_prev isa Core.ReturnNode
                ctx.last_stmt_was_stub = false
            else
                for _bw_s in code
                    local _bw_d = _bw_s isa Core.GotoNode ? _bw_s.label :
                                  _bw_s isa Core.GotoIfNot ? _bw_s.dest : 0
                    if _bw_d == i
                        ctx.last_stmt_was_stub = false
                        break
                    end
                end
            end
        end

        # PURE-6024: Skip statements in dead code (after unreachable in current block)
        if dead_code_depth >= 0
            i += 1
            continue
        end

        # Skip dead code regions
        if i in dead_regions
            i += 1
            continue
        end

        if stmt isa Core.PhiNode
            # Phi nodes in loops are handled via locals
            # For inner conditional phi nodes, we need to handle the merge
            if haskey(ctx.phi_locals, i)
                # The phi local should already have the correct value
                # (set by either branch)
            end
            i += 1
            continue
        elseif stmt isa Core.GotoIfNot
            target = stmt.dest

            # Skip boundscheck always-jump patterns (condition is always false)
            if haskey(boundscheck_jumps, i)
                # The dead region will be skipped, just continue
                i += 1
                continue
            elseif target > back_edge_idx
                # This is the LOOP EXIT condition
                emit_raw!(b, compile_condition_to_i32(stmt.cond, ctx); pushes=WasmValType[I32])
                num!(b, Opcode.I32_EQZ)  # Invert: if NOT condition
                br_if!(b, 1 + current_depth)  # Break to exit block
            elseif haskey(inner_conditionals, i)
                # This is an INNER CONDITIONAL
                # dart2wasm pattern: block + br_if to skip then-branch
                merge_point = inner_conditionals[i]

                # Check if there's a phi node at the merge point
                merge_phi = nothing
                if code[merge_point] isa Core.PhiNode
                    merge_phi = merge_point
                end

                # If this conditional has a phi node, we need to set the else-value
                # before the branch (it gets set if we skip the then-branch)
                if merge_phi !== nothing && haskey(ctx.phi_locals, merge_phi)
                    phi_stmt = code[merge_phi]::Core.PhiNode
                    # Find the value for the else branch (edge from this GotoIfNot)
                    for (edge_idx, edge) in enumerate(phi_stmt.edges)
                        if edge == i
                            val = phi_stmt.values[edge_idx]
                            _phi_set!(val, merge_phi)
                            break
                        end
                    end
                end

                # Open a block for the then-branch
                block!(b)  # void block type
                open_blocks[merge_point] = true
                current_depth += 1

                # Branch to merge point if condition is FALSE
                emit_raw!(b, compile_condition_to_i32(stmt.cond, ctx); pushes=WasmValType[I32])
                num!(b, Opcode.I32_EQZ)  # Invert condition
                br_if!(b, 0)  # Branch to the block we just opened (depth 0)
            else
                # Fallback: treat as simple forward branch (skip to target)
                block!(b)
                open_blocks[target] = true
                current_depth += 1
                emit_raw!(b, compile_condition_to_i32(stmt.cond, ctx); pushes=WasmValType[I32])
                num!(b, Opcode.I32_EQZ)
                br_if!(b, 0)
            end
        elseif stmt isa Core.GotoNode
            if stmt.label >= 1 && stmt.label <= length(ctx.loop_headers) && ctx.loop_headers[stmt.label]
                # This is the loop-back jump
                # First update phi locals with their iteration values
                for (j, phi_stmt) in enumerate(code)
                    if phi_stmt isa Core.PhiNode && haskey(ctx.phi_locals, j)
                        # Find the iteration value (from the back-edge - AFTER the phi node)
                        for (edge_idx, edge) in enumerate(phi_stmt.edges)
                            if edge > j  # Back-edge (from after the phi node)
                                val = phi_stmt.values[edge_idx]
                                _phi_set!(val, j)
                                break
                            end
                        end
                    end
                end
                # Continue loop
                br!(b, current_depth)  # Branch to loop (accounting for open blocks)
            elseif stmt.label > i && stmt.label <= back_edge_idx
                # Forward jump within loop - branch to that point
                # This handles the then-branch jumping to merge point
                if haskey(open_blocks, stmt.label) && open_blocks[stmt.label]
                    # Jump to merge point - handle phi update if needed
                    if code[stmt.label] isa Core.PhiNode && haskey(ctx.phi_locals, stmt.label)
                        phi_stmt = code[stmt.label]::Core.PhiNode
                        for (edge_idx, edge) in enumerate(phi_stmt.edges)
                            if edge == i
                                val = phi_stmt.values[edge_idx]
                                _phi_set!(val, stmt.label)
                                break
                            end
                        end
                    end
                    br!(b, 0)  # Branch to inner block
                end
            elseif stmt.label > back_edge_idx
                # Jump past loop end - this is a BREAK statement
                # Need to branch to the exit block (depth = 1 + current_depth)
                br!(b, 1 + current_depth)  # Branch to exit block
            end
        elseif stmt isa Core.ReturnNode
            if isdefined(stmt, :val)
                val_wasm_type = infer_value_wasm_type(stmt.val, ctx)
                ret_wasm_type = julia_to_wasm_type_concrete(ctx.return_type, ctx)
                func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                # PURE-315: Check numeric-to-ref BEFORE return_type_compatible
                is_numeric_val = val_wasm_type === I32 || val_wasm_type === I64 || val_wasm_type === F32 || val_wasm_type === F64
                is_ref_ret = func_ret_wasm isa ConcreteRef || func_ret_wasm === ExternRef || func_ret_wasm === StructRef || func_ret_wasm === ArrayRef || func_ret_wasm === AnyRef
                b = emit_return_coerced!(b, stmt.val, ctx)
            else
                return_!(b)
            end
        elseif stmt === nothing
            # Skip nothing statements
        else
            compiled_stmt_bytes = compile_statement(stmt, i, ctx)
            emit_raw!(b, compiled_stmt_bytes)

            # Drop unused values from calls (prevents stack pollution in loops)
            # PURE-6027c: Skip DROP if the statement was a stub (ended in unreachable).
            # After a stub, the stack is polymorphic/dead — emitting DROP can cause
            # "nothing on stack" validation errors when the stub doesn't actually push a value.
            if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke) && !ctx.last_stmt_was_stub
                # PURE-220: Skip if compile_statement already emitted a DROP
                # PURE-6006: Guard against false positive where call function_index=0x1a (26)
                # matches DROP opcode. Call instruction is [0x10, LEB128(func_idx)]; if func_idx
                # fits in 1 byte as 0x1a, the last byte == DROP but it's an operand, not DROP.
                already_dropped = !isempty(compiled_stmt_bytes) && compiled_stmt_bytes[end] == Opcode.DROP &&
                                  !(length(compiled_stmt_bytes) >= 2 && compiled_stmt_bytes[end-1] == Opcode.CALL)
                # Use statement_produces_wasm_value for consistent handling
                # This checks the function registry for accurate return type info
                if !already_dropped && statement_produces_wasm_value(stmt, i, ctx)
                    if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                        use_count = get(ssa_use_count, i, 0)
                        if use_count == 0
                            drop!(b)
                        end
                    end
                end
            end

            # Check if this statement has Union{} type or emitted unreachable - stop generating code
            # Code after unreachable/throw is dead and causes validation errors
            # PURE-6024: Use ctx.last_stmt_was_stub flag (set by compile_call/compile_invoke
            # when stub emits UNREACHABLE). Byte-level detection of 0x00 is unreliable.
            stmt_type = get(ctx.ssa_types, i, Any)
            if stmt_type === Union{} || ctx.last_stmt_was_stub
                # PURE-6024: Set dead_code_depth to skip ALL subsequent statements
                # in this block until the block closes. The merge point skip below
                # handles the common case, but dead_code_depth handles edge cases
                # where merge point tracking is incomplete.
                dead_code_depth = current_depth
                # Skip to next merge point (block end) or back-edge
                # Find the next merge point
                next_merge = nothing
                for (merge_point, is_open) in open_blocks
                    if is_open && merge_point > i
                        if next_merge === nothing || merge_point < next_merge
                            next_merge = merge_point
                        end
                    end
                end
                if next_merge !== nothing
                    # Skip to just before merge point
                    i = next_merge - 1
                else
                    # No merge point - skip to back edge
                    i = back_edge_idx
                end
            end
        end
        i += 1
    end

    # Close any remaining open blocks
    for (merge_point, is_open) in open_blocks
        if is_open
            end_block!(b)
        end
    end

    # End loop
    end_block!(b)

    # End block
    end_block!(b)

    # Close any IF block for pre-loop conditional that skips past the loop
    # This was opened by `target > back_edge_idx` case in pre-loop handling
    if post_loop_skip_phi_target !== nothing
        # Before closing the IF, we need to set the phi value for the then-branch (loop completed)
        if code[post_loop_skip_phi_target] isa Core.PhiNode && haskey(ctx.phi_locals, post_loop_skip_phi_target)
            phi_stmt = code[post_loop_skip_phi_target]::Core.PhiNode
            # Find the edge that comes from inside/after the loop (not the pre-loop skip)
            # This is the edge that leads to here (end of loop, before post-loop code)
            for (edge_idx, edge) in enumerate(phi_stmt.edges)
                # The loop exit edge is the one from the loop exit condition (line 27 in our IR)
                # or any edge that's > the loop header and <= back_edge_idx
                if edge >= loop_header && edge <= back_edge_idx
                    val = phi_stmt.values[edge_idx]
                    _phi_set!(val, post_loop_skip_phi_target)
                    break
                end
            end
        end
        end_block!(b)  # Close the IF block
    end

    # Generate code AFTER the loop (statements that run after loop exits)
    # This code may contain conditionals (GotoIfNot) that need proper handling
    # Track blocks as a stack: each entry is a merge point
    post_loop_block_stack = Int[]

    for i in (back_edge_idx + 1):length(code)
        stmt = code[i]

        # Close any open blocks at this merge point
        while !isempty(post_loop_block_stack) && post_loop_block_stack[end] == i
            # If this merge point is a phi, set the phi local from the fall-through edge
            # The fall-through edge is the line right before this merge point (i-1)
            if i <= length(code) && code[i] isa Core.PhiNode && haskey(ctx.phi_locals, i)
                phi_stmt = code[i]::Core.PhiNode
                prev_line = i - 1
                # Find edge value from fall-through (the line just before phi)
                for (edge_idx, edge) in enumerate(phi_stmt.edges)
                    if edge == prev_line
                        edge_val = phi_stmt.values[edge_idx]
                        _phi_set!(edge_val, i)
                        break
                    end
                end
            end
            end_block!(b)
            pop!(post_loop_block_stack)
        end

        if stmt isa Core.ReturnNode
            if isdefined(stmt, :val)
                val_wasm_type = infer_value_wasm_type(stmt.val, ctx)
                ret_wasm_type = julia_to_wasm_type_concrete(ctx.return_type, ctx)
                func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                # PURE-315: Check numeric-to-ref BEFORE return_type_compatible
                is_numeric_val = val_wasm_type === I32 || val_wasm_type === I64 || val_wasm_type === F32 || val_wasm_type === F64
                is_ref_ret = func_ret_wasm isa ConcreteRef || func_ret_wasm === ExternRef || func_ret_wasm === StructRef || func_ret_wasm === ArrayRef || func_ret_wasm === AnyRef
                b = emit_return_coerced!(b, stmt.val, ctx)
            else
                return_!(b)
            end
        elseif stmt isa Core.GotoIfNot
            target = stmt.dest
            # This is a conditional that jumps forward
            # Use block + br_if pattern
            block!(b)  # void block type
            push!(post_loop_block_stack, target)

            # If target is a phi, set the phi local BEFORE branching
            # When condition is FALSE, we skip to phi with edge value from this line
            if target <= length(code) && code[target] isa Core.PhiNode && haskey(ctx.phi_locals, target)
                phi_stmt = code[target]::Core.PhiNode
                # Find edge value for when we skip (edge from this line)
                for (edge_idx, edge) in enumerate(phi_stmt.edges)
                    if edge == i
                        edge_val = phi_stmt.values[edge_idx]
                        _phi_set!(edge_val, target)
                        break
                    end
                end
            end

            # Branch if condition is FALSE (skip then-branch)
            emit_raw!(b, compile_condition_to_i32(stmt.cond, ctx); pushes=WasmValType[I32])
            num!(b, Opcode.I32_EQZ)
            br_if!(b, 0)
        elseif stmt isa Core.GotoNode
            # Unconditional forward jump - find how many blocks to close
            # and branch to the right depth
            depth = 0
            for j in length(post_loop_block_stack):-1:1
                if post_loop_block_stack[j] == stmt.label
                    depth = length(post_loop_block_stack) - j
                    break
                end
            end

            # If target is a phi, set the phi local BEFORE branching
            if stmt.label <= length(code) && code[stmt.label] isa Core.PhiNode && haskey(ctx.phi_locals, stmt.label)
                phi_stmt = code[stmt.label]::Core.PhiNode
                # Find edge value for this GotoNode (edge from this line)
                for (edge_idx, edge) in enumerate(phi_stmt.edges)
                    if edge == i
                        edge_val = phi_stmt.values[edge_idx]
                        _phi_set!(edge_val, stmt.label)
                        break
                    end
                end
            end

            if depth >= 0 && !isempty(post_loop_block_stack)
                br!(b, depth)
            end
        elseif stmt isa Core.PhiNode
            # Phi nodes in post-loop are merge points - they're handled when blocks close
            # The phi local should already be set by the branches leading here
            continue
        elseif stmt === nothing
            # Skip nothing statements
        else
            emit_raw!(b, compile_statement(stmt, i, ctx))
        end
    end

    # Close any remaining open blocks
    while !isempty(post_loop_block_stack)
        end_block!(b)
        pop!(post_loop_block_stack)
    end

    # If the function has a non-void return type and the code after the loop
    # doesn't end with a RETURN, add UNREACHABLE to satisfy the validator.
    # This happens for infinite loops (while true) that only exit via return.
    # Byte-inspecting branch: examine the serialized builder output so far.
    local _tail = builder_code(b)
    if ctx.return_type !== Nothing && (isempty(_tail) || (_tail[end] != Opcode.RETURN && _tail[end] != Opcode.UNREACHABLE))
        unreachable!(b)
    end

    return builder_code(b)
end

"""
Check if this is a simple if-then-else pattern.
Pattern: condition, GotoIfNot, then-code, return, else-code, return

A simple conditional has exactly 2-3 blocks:
- Block 1: condition computation, ends with GotoIfNot
- Block 2: then-branch code
- Block 3 (optional): else-branch code

If there are more blocks or nested conditionals, it's not simple.
"""
function is_simple_conditional(blocks::Vector{BasicBlock}, code)
    # Simple pattern has exactly 2-3 blocks
    if length(blocks) < 2 || length(blocks) > 3
        return false
    end

    # First block should end with GotoIfNot
    if !(blocks[1].terminator isa Core.GotoIfNot)
        return false
    end

    # Check that other blocks don't have GotoIfNot (no nested conditionals)
    for i in 2:length(blocks)
        if blocks[i].terminator isa Core.GotoIfNot
            return false
        end
    end

    # A merge with ≥2 phi nodes (an if/else assigning 2+ vars live past the merge) is NOT
    # "simple": generate_if_then_else carries only ONE phi through the `if (result T)` block
    # value and silently drops the rest (multivar phi-merge miscompile — see
    # test/fuzz/repro_multivar_phi_merge.jl). Fall through to generate_complex_flow, which
    # routes multi-phi merges to the stackifier (stores every live phi local at the edge).
    if count(stmt isa Core.PhiNode for stmt in code) >= 2
        return false
    end

    return true
end

"""
Generate code for a simple if-then-else pattern.
Handles both return-based patterns and phi node patterns (ternary expressions).
"""
function generate_if_then_else(ctx::AbstractCompilationContext, blocks::Vector{BasicBlock}, code)::Vector{UInt8}
    b = InstrBuilder(; func_name="generate_if_then_else", strict=false)
    # For void return types (like event handlers), delegate to generate_void_flow
    # which properly handles if blocks with void block type (0x40) instead of trying
    # to produce a value
    if ctx.return_type === Nothing
        return generate_void_flow(ctx, blocks, code)
    end

    # Count SSA uses (for drop logic)
    ssa_use_count = Dict{Int, Int}()
    for stmt in code
        count_ssa_uses!(stmt, ssa_use_count)
    end

    # First block: statements up to the condition
    first_block = blocks[1]
    goto_if_not = first_block.terminator::Core.GotoIfNot
    target_label = goto_if_not.dest

    # Generate statements in first block (including condition computation)
    for i in first_block.start_idx:first_block.end_idx-1
        emit_raw!(b, compile_statement(code[i], i, ctx))
    end

    # The condition value should be on the stack (it's an SSA reference)
    # We need to push it
    emit_raw!(b, compile_condition_to_i32(goto_if_not.cond, ctx); pushes=WasmValType[I32])

    # Find the then-branch and else-branch boundaries
    then_start = first_block.end_idx + 1
    else_start = target_label

    # Check if there's a phi node that merges the branches
    # Pattern: then-branch jumps to merge point, else-branch falls through, phi at merge
    phi_idx = nothing
    phi_node = nothing
    for i in else_start:length(code)
        if code[i] isa Core.PhiNode
            phi_idx = i
            phi_node = code[i]
            break
        end
    end

    if phi_node !== nothing
        # Phi node pattern (ternary expression)
        # The phi provides values for each branch - use those directly
        # PURE-048: Use ssavaluetypes fallback instead of Int32 default
        phi_type = get(ctx.ssa_types, phi_idx, nothing)
        if phi_type === nothing
            ssatypes = ctx.code_info.ssavaluetypes
            phi_type = (ssatypes isa Vector && phi_idx <= length(ssatypes)) ? ssatypes[phi_idx] : Int32
        end
        result_type = julia_to_wasm_type_concrete(phi_type, ctx)

        # Start if block with phi result type
        if_!(b, result_type)

        # Get the phi values for each edge
        # The phi edges reference statement numbers that lead to the phi
        then_value = nothing
        else_value = nothing

        for (edge_idx, edge) in enumerate(phi_node.edges)
            val = phi_node.values[edge_idx]
            if edge < else_start
                # This edge comes from the then-branch (before else_start)
                then_value = val
            else
                # This edge comes from the else-branch
                else_value = val
            end
        end

        # Then-branch: generate all statements in the then-branch, then push the then-value
        # Note: compile_statement already stores to local if SSA has one (via LOCAL_SET)
        then_hit_unreachable = false
        for i in then_start:else_start-1
            stmt = code[i]
            if stmt isa Core.GotoNode
                # Skip the goto - we're handling control flow with if/else
            elseif stmt === nothing
                # Skip nothing statements
            else
                stmt_bytes = compile_statement(stmt, i, ctx)
                emit_raw!(b, stmt_bytes; pushes=WasmValType[AnyRef])
                # PURE-907/908: If statement emitted unreachable (stub call), stop emitting
                # code in this branch. unreachable makes the stack polymorphic, which
                # satisfies the typed block's result type. Emitting more values after
                # unreachable causes "values remaining on stack" validation errors.
                if !isempty(stmt_bytes) && stmt_bytes[end] == Opcode.UNREACHABLE
                    then_hit_unreachable = true
                    break
                end
            end
        end
        # Now push the then-value for the phi result
        # compile_value will do LOCAL_GET if the value has a local
        # Skip if we hit unreachable - stack is already polymorphic
        if !then_hit_unreachable && then_value !== nothing
            emit_raw!(b, compile_value(then_value, ctx); pushes=WasmValType[AnyRef])
            # PURE-1101: Convert numeric type to match IF block result type
            then_val_type = infer_value_wasm_type(then_value, ctx)
            convert_type!(b, then_val_type, result_type, ctx)
        end

        # Else branch
        else_!(b)

        # Else-branch: generate all statements in the else-branch, then push the else-value
        else_hit_unreachable = false
        for i in else_start:phi_idx-1
            stmt = code[i]
            if stmt isa Core.GotoNode
                # Skip the goto
            elseif stmt === nothing
                # Skip nothing statements
            else
                stmt_bytes = compile_statement(stmt, i, ctx)
                emit_raw!(b, stmt_bytes; pushes=WasmValType[AnyRef])
                # PURE-907: Same unreachable detection as then-branch
                if !isempty(stmt_bytes) && stmt_bytes[end] == Opcode.UNREACHABLE
                    else_hit_unreachable = true
                    break
                end
            end
        end
        # Now push the else-value for the phi result
        # Skip if we hit unreachable - stack is already polymorphic
        if !else_hit_unreachable && else_value !== nothing
            emit_raw!(b, compile_value(else_value, ctx); pushes=WasmValType[AnyRef])
            # PURE-1101: Convert numeric type to match IF block result type
            else_val_type = infer_value_wasm_type(else_value, ctx)
            convert_type!(b, else_val_type, result_type, ctx)
        end

        # End if - phi result is on the stack
        end_block!(b)

        # Store phi result to local if it has one
        if haskey(ctx.phi_locals, phi_idx)
            local_idx = ctx.phi_locals[phi_idx]
            local_set!(b, local_idx)
        end

        # Generate code after the phi node
        for i in phi_idx+1:length(code)
            stmt = code[i]
            if stmt isa Core.ReturnNode
                if isdefined(stmt, :val)
                    val_wasm_type = infer_value_wasm_type(stmt.val, ctx)
                    ret_wasm_type = julia_to_wasm_type_concrete(ctx.return_type, ctx)
                    func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                    # PURE-315: Check numeric-to-ref BEFORE return_type_compatible
                    is_numeric_val = val_wasm_type === I32 || val_wasm_type === I64 || val_wasm_type === F32 || val_wasm_type === F64
                    is_ref_ret = func_ret_wasm isa ConcreteRef || func_ret_wasm === ExternRef || func_ret_wasm === StructRef || func_ret_wasm === ArrayRef || func_ret_wasm === AnyRef
                    b = emit_return_coerced!(b, stmt.val, ctx)
                else
                    return_!(b)
                end
            elseif !(stmt === nothing)
                emit_raw!(b, compile_statement(stmt, i, ctx))
            end
        end
    else
        # Return-based pattern OR void-if-then pattern
        # First, check if then-branch contains a return
        then_has_return = false
        for i in then_start:else_start-1
            if code[i] isa Core.ReturnNode
                then_has_return = true
                break
            end
        end

        if !then_has_return
            # Void-if-then pattern: then-branch has no return, falls through to common return
            # Generate void IF block for side effects, then continue to shared return path
            if_!(b)  # void block type

            for i in then_start:else_start-1
                stmt = code[i]
                if stmt === nothing
                    # Skip nothing statements
                elseif stmt isa Core.GotoNode
                    # Skip goto - handled by control flow
                else
                    emit_raw!(b, compile_statement(stmt, i, ctx))

                    # Drop unused values from calls
                    # P6-ioprint: unified with the main-path contract — the crude
                    # `stmt_type !== Nothing` check dropped on an empty stack for
                    # handlers that push no value (memoryrefset! et al.).
                    if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke) && !ctx.last_stmt_was_stub
                        stmt_type = get(ctx.ssa_types, i, Any)
                        is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                        if !is_nothing_union && statement_produces_wasm_value(stmt, i, ctx)
                            if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                                use_count = get(ssa_use_count, i, 0)
                                if use_count == 0
                                    drop!(b)
                                end
                            end
                        end
                    end
                end
            end

            end_block!(b)  # End the void IF block

            # Generate the common return path (else-branch which both paths reach)
            for i in else_start:length(code)
                stmt = code[i]
                if stmt isa Core.ReturnNode
                    if isdefined(stmt, :val)
                        func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                        val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                        is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                        # PURE-036ag/PURE-045: Handle numeric-to-ref case
                        if func_ret_wasm === ExternRef && is_numeric_val
                            let tb=UInt8[]; emit_numeric_to_externref!(tb, stmt.val, val_wasm, ctx); emit_raw!(b, tb; pushes=WasmValType[ExternRef]); end
                        elseif func_ret_wasm isa ConcreteRef && is_numeric_val
                            # PURE-045: Numeric (nothing) to concrete ref - return ref.null of the type
                            ref_null!(b, Int64(func_ret_wasm.type_idx), func_ret_wasm)
                        elseif func_ret_wasm === AnyRef && is_numeric_val
                            # PURE-9030: Box numeric value for AnyRef return (Union return type)
                            local _ret_box_idx_flow = get_numeric_box_type!(ctx.mod, ctx.type_registry, val_wasm)
                            let tb=UInt8[]; emit_box_type_id!(tb, ctx.type_registry, val_wasm); emit_raw!(b, tb; pushes=WasmValType[I32]); end
                            emit_raw!(b, compile_value(stmt.val, ctx); pushes=WasmValType[AnyRef])
                            struct_new!(b, _ret_box_idx_flow, WasmValType[])
                    elseif (func_ret_wasm === StructRef || func_ret_wasm === ArrayRef) && is_numeric_val
                            # PURE-045: Numeric to abstract ref - return ref.null of the abstract type
                            ref_null!(b, func_ret_wasm)
                        else
                            emit_raw!(b, compile_value(stmt.val, ctx); pushes=WasmValType[AnyRef])
                            # If function returns externref but value is concrete ref, convert
                            if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                                extern_convert_any!(b)
                            end
                        end
                    end
                    return_!(b)
                elseif stmt === nothing
                    # Skip
                else
                    emit_raw!(b, compile_statement(stmt, i, ctx))
                end
            end

            return builder_code(b)
        end

        # Original return-based pattern: both branches have returns
        # Determine result type for the if block
        result_type = julia_to_wasm_type_concrete(ctx.return_type, ctx)

        # Start if block (condition is on stack)
        if_!(b, result_type)

        # Generate then-branch (executed when condition is TRUE)
        for i in then_start:else_start-1
            stmt = code[i]
            if stmt isa Core.ReturnNode
                if isdefined(stmt, :val)
                    # PURE-036ag/PURE-045: Handle numeric-to-ref case
                    func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                    val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                    is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                    if func_ret_wasm === ExternRef && is_numeric_val
                        let tb=UInt8[]; emit_numeric_to_externref!(tb, stmt.val, val_wasm, ctx); emit_raw!(b, tb; pushes=WasmValType[ExternRef]); end
                    elseif func_ret_wasm isa ConcreteRef && is_numeric_val
                        # PURE-045: Numeric (nothing) to concrete ref - return ref.null of the type
                        ref_null!(b, Int64(func_ret_wasm.type_idx), func_ret_wasm)
                    elseif func_ret_wasm === AnyRef && is_numeric_val
                        # PURE-9030: Box numeric value for AnyRef return (Union return type)
                        local _ret_box_idx_f2 = get_numeric_box_type!(ctx.mod, ctx.type_registry, val_wasm)
                        let tb=UInt8[]; emit_box_type_id!(tb, ctx.type_registry, val_wasm); emit_raw!(b, tb; pushes=WasmValType[I32]); end
                        emit_raw!(b, compile_value(stmt.val, ctx); pushes=WasmValType[AnyRef])
                        struct_new!(b, _ret_box_idx_f2, WasmValType[])
                    elseif (func_ret_wasm === StructRef || func_ret_wasm === ArrayRef) && is_numeric_val
                        # PURE-045: Numeric to abstract ref - return ref.null of the abstract type
                        ref_null!(b, func_ret_wasm)
                    else
                        emit_raw!(b, compile_value(stmt.val, ctx); pushes=WasmValType[AnyRef])
                        if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                            extern_convert_any!(b)
                        else
                            # PURE-1101: Numeric widening for typed IF block result (B1 funnel).
                            convert_type!(b, val_wasm, result_type, ctx)
                        end
                    end
                end
                # Don't emit return - the value stays on stack for the if result
            elseif stmt === nothing
                # Skip nothing statements
            else
                emit_raw!(b, compile_statement(stmt, i, ctx))

                # Drop unused values from calls (like setfield! which returns a value)
                # Also drop Any-typed values (like bb_read) when unused
                if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                    # Default to Any (not Nothing) so unknown types get drop check
                    stmt_type = get(ctx.ssa_types, i, Any)
                    if stmt_type !== Nothing  # Only skip if type is definitely Nothing
                        is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                        if !is_nothing_union
                            if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                                use_count = get(ssa_use_count, i, 0)
                                if use_count == 0
                                    drop!(b)
                                end
                            end
                        end
                    end
                end
            end
        end

        # Else branch
        else_!(b)

        # Generate else-branch
        # Track compiled statements to handle nested conditionals properly
        compiled_in_else = Set{Int}()
        for i in else_start:length(code)
            if i in compiled_in_else
                continue
            end
            stmt = code[i]
            if stmt isa Core.ReturnNode
                if isdefined(stmt, :val)
                    # PURE-036ag/PURE-045: Handle numeric-to-ref case
                    func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                    val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                    is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                    if func_ret_wasm === ExternRef && is_numeric_val
                        let tb=UInt8[]; emit_numeric_to_externref!(tb, stmt.val, val_wasm, ctx); emit_raw!(b, tb; pushes=WasmValType[ExternRef]); end
                    elseif func_ret_wasm isa ConcreteRef && is_numeric_val
                        # PURE-045: Numeric (nothing) to concrete ref - return ref.null of the type
                        ref_null!(b, Int64(func_ret_wasm.type_idx), func_ret_wasm)
                    elseif func_ret_wasm === AnyRef && is_numeric_val
                        # PURE-9030: Box numeric value for AnyRef return (Union return type)
                        local _ret_box_idx_f2 = get_numeric_box_type!(ctx.mod, ctx.type_registry, val_wasm)
                        let tb=UInt8[]; emit_box_type_id!(tb, ctx.type_registry, val_wasm); emit_raw!(b, tb; pushes=WasmValType[I32]); end
                        emit_raw!(b, compile_value(stmt.val, ctx); pushes=WasmValType[AnyRef])
                        struct_new!(b, _ret_box_idx_f2, WasmValType[])
                    elseif (func_ret_wasm === StructRef || func_ret_wasm === ArrayRef) && is_numeric_val
                        # PURE-045: Numeric to abstract ref - return ref.null of the abstract type
                        ref_null!(b, func_ret_wasm)
                    else
                        emit_raw!(b, compile_value(stmt.val, ctx); pushes=WasmValType[AnyRef])
                        if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                            extern_convert_any!(b)
                        else
                            # PURE-1101: Numeric widening for typed IF block result (B1 funnel).
                            convert_type!(b, val_wasm, result_type, ctx)
                        end
                    end
                end
            elseif stmt === nothing
                # Skip nothing statements
            elseif stmt isa Core.GotoIfNot
                # Nested conditional in else branch - generate nested if/else
                nested_result = compile_nested_if_else(ctx, code, i, compiled_in_else, ssa_use_count)
                emit_raw!(b, nested_result; pushes=WasmValType[AnyRef])
            elseif stmt isa Core.GotoNode
                # Skip goto statements (they're control flow markers)
                push!(compiled_in_else, i)
            else
                emit_raw!(b, compile_statement(stmt, i, ctx))

                # Drop unused values from calls (like setfield! which returns a value)
                # Also drop Any-typed values (like bb_read) when unused
                if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                    # Default to Any (not Nothing) so unknown types get drop check
                    stmt_type = get(ctx.ssa_types, i, Any)
                    if stmt_type !== Nothing  # Only skip if type is definitely Nothing
                        is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                        if !is_nothing_union
                            if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                                use_count = get(ssa_use_count, i, 0)
                                if use_count == 0
                                    drop!(b)
                                end
                            end
                        end
                    end
                end
            end
        end

        # End if
        end_block!(b)

        # The result of if...else...end is on the stack, return it
        return_!(b)
    end

    return builder_code(b)
end

"""
Compile a nested if/else inside a return-based pattern.
This handles the case where there's a GotoIfNot inside an else branch
that creates a nested conditional, each branch ending with a return.
"""
function compile_nested_if_else(ctx::AbstractCompilationContext, code, goto_idx::Int, compiled::Set{Int}, ssa_use_count::Dict{Int,Int})::Vector{UInt8}
    b = InstrBuilder(; func_name="compile_nested_if_else", strict=false)

    goto_if_not = code[goto_idx]::Core.GotoIfNot
    else_target = goto_if_not.dest  # Where to jump if condition is FALSE
    then_start = goto_idx + 1

    # The condition is already computed (it's an SSA reference)
    # Push it
    emit_raw!(b, compile_condition_to_i32(goto_if_not.cond, ctx); pushes=WasmValType[I32])
    push!(compiled, goto_idx)

    # Determine result type - should match the enclosing function's return type
    result_type = julia_to_wasm_type_concrete(ctx.return_type, ctx)

    # Start if block
    if_!(b, result_type)

    # Then branch: from then_start to else_target-1
    for i in then_start:else_target-1
        if i in compiled
            continue
        end
        stmt = code[i]
        push!(compiled, i)

        if stmt isa Core.ReturnNode
            if isdefined(stmt, :val)
                # PURE-036ag/PURE-045: Handle numeric-to-ref case
                func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                if func_ret_wasm === ExternRef && is_numeric_val
                    let tb=UInt8[]; emit_numeric_to_externref!(tb, stmt.val, val_wasm, ctx); emit_raw!(b, tb; pushes=WasmValType[ExternRef]); end
                elseif func_ret_wasm isa ConcreteRef && is_numeric_val
                    # PURE-045: Numeric (nothing) to concrete ref - return ref.null of the type
                    ref_null!(b, Int64(func_ret_wasm.type_idx), func_ret_wasm)
                elseif func_ret_wasm === AnyRef && is_numeric_val
                    # PURE-9030: Box numeric value for AnyRef return (Union return type)
                    local _ret_box_idx_f3 = get_numeric_box_type!(ctx.mod, ctx.type_registry, val_wasm)
                    let tb=UInt8[]; emit_box_type_id!(tb, ctx.type_registry, val_wasm); emit_raw!(b, tb; pushes=WasmValType[I32]); end
                    emit_raw!(b, compile_value(stmt.val, ctx); pushes=WasmValType[AnyRef])
                    struct_new!(b, _ret_box_idx_f3, WasmValType[])
                elseif (func_ret_wasm === StructRef || func_ret_wasm === ArrayRef) && is_numeric_val
                    # PURE-045: Numeric to abstract ref - return ref.null of the abstract type
                    ref_null!(b, func_ret_wasm)
                else
                    emit_raw!(b, compile_value(stmt.val, ctx); pushes=WasmValType[AnyRef])
                    if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                        extern_convert_any!(b)
                    else
                        # PURE-1101: Numeric widening for typed IF block result (B1 funnel).
                        convert_type!(b, val_wasm, result_type, ctx)
                    end
                end
            end
            # Value stays on stack for the if result
        elseif stmt === nothing
            # Skip
        elseif stmt isa Core.GotoNode
            # Skip forward gotos
        else
            emit_raw!(b, compile_statement(stmt, i, ctx))

            # Drop unused values
            if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                # Default to Any (not Nothing) so unknown types get drop check
                stmt_type = get(ctx.ssa_types, i, Any)
                use_count = get(ssa_use_count, i, 0)
                if stmt_type !== Nothing
                    is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                    if !is_nothing_union
                        if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                            if use_count == 0
                                drop!(b)
                            end
                        end
                    end
                end
            end
        end
    end

    # Else branch
    else_!(b)

    # Else branch: from else_target to end
    for i in else_target:length(code)
        if i in compiled
            continue
        end
        stmt = code[i]
        push!(compiled, i)

        if stmt isa Core.ReturnNode
            if isdefined(stmt, :val)
                # PURE-036ag/PURE-045: Handle numeric-to-ref case
                func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                if func_ret_wasm === ExternRef && is_numeric_val
                    let tb=UInt8[]; emit_numeric_to_externref!(tb, stmt.val, val_wasm, ctx); emit_raw!(b, tb; pushes=WasmValType[ExternRef]); end
                elseif func_ret_wasm isa ConcreteRef && is_numeric_val
                    # PURE-045: Numeric (nothing) to concrete ref - return ref.null of the type
                    ref_null!(b, Int64(func_ret_wasm.type_idx), func_ret_wasm)
                elseif func_ret_wasm === AnyRef && is_numeric_val
                    # PURE-9030: Box numeric value for AnyRef return (Union return type)
                    local _ret_box_idx_f3 = get_numeric_box_type!(ctx.mod, ctx.type_registry, val_wasm)
                    let tb=UInt8[]; emit_box_type_id!(tb, ctx.type_registry, val_wasm); emit_raw!(b, tb; pushes=WasmValType[I32]); end
                    emit_raw!(b, compile_value(stmt.val, ctx); pushes=WasmValType[AnyRef])
                    struct_new!(b, _ret_box_idx_f3, WasmValType[])
                elseif (func_ret_wasm === StructRef || func_ret_wasm === ArrayRef) && is_numeric_val
                    # PURE-045: Numeric to abstract ref - return ref.null of the abstract type
                    ref_null!(b, func_ret_wasm)
                else
                    emit_raw!(b, compile_value(stmt.val, ctx); pushes=WasmValType[AnyRef])
                    if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                        extern_convert_any!(b)
                    else
                        # PURE-1101: Numeric widening for typed IF block result (B1 funnel).
                        convert_type!(b, val_wasm, result_type, ctx)
                    end
                end
            end
            # Value stays on stack for the if result
        elseif stmt === nothing
            # Skip
        elseif stmt isa Core.GotoNode
            # Skip forward gotos
        elseif stmt isa Core.GotoIfNot
            # Another nested conditional - recurse
            nested = compile_nested_if_else(ctx, code, i, compiled, ssa_use_count)
            emit_raw!(b, nested; pushes=WasmValType[AnyRef])
        else
            emit_raw!(b, compile_statement(stmt, i, ctx))

            # Drop unused values
            if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                # Default to Any (not Nothing) so unknown types get drop check
                stmt_type = get(ctx.ssa_types, i, Any)
                if stmt_type !== Nothing
                    is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                    if !is_nothing_union
                        if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                            use_count = get(ssa_use_count, i, 0)
                            if use_count == 0
                                drop!(b)
                            end
                        end
                    end
                end
            end
        end
    end

    # End nested if
    end_block!(b)

    return builder_code(b)
end

