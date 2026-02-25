# ============================================================================
# Statement Compilation
# ============================================================================

"""
Compile a single IR statement to Wasm bytecode.
"""
function compile_statement(stmt, idx::Int, ctx::CompilationContext)::Vector{UInt8}
    bytes = UInt8[]

    # PURE-6027: Reset dead code guard at basic block boundaries.
    # The last_stmt_was_stub flag from a previous stub should NOT cascade across basic
    # block boundaries — the next block is reachable via a different control flow path.
    # Check: (a) previous stmt is a terminator, OR (b) this idx is a jump target.
    if ctx.last_stmt_was_stub && idx > 1
        _should_reset = false
        _prev_stmt = ctx.code_info.code[idx - 1]
        if _prev_stmt isa Core.GotoNode || _prev_stmt isa Core.GotoIfNot || _prev_stmt isa Core.ReturnNode
            _should_reset = true
        else
            # Check if this idx is a jump target of any GotoNode/GotoIfNot
            for _s in ctx.code_info.code
                if (_s isa Core.GotoIfNot && _s.dest == idx) || (_s isa Core.GotoNode && _s.label == idx)
                    _should_reset = true
                    break
                end
            end
        end
        if _should_reset
            ctx.last_stmt_was_stub = false
        end
    end

    # PURE-6022: If a previous statement in this function was a stub (emitted unreachable),
    # skip ALL further statement compilation within the SAME basic block. Bytes after
    # unreachable must be structurally valid WASM, and continuing to compile produces invalid
    # opcodes. Emit unreachable (not empty) so the validator stays in polymorphic stack mode.
    if ctx.last_stmt_was_stub
        push!(bytes, 0x00)  # unreachable — keeps stack polymorphic
        return bytes
    end

    # PURE-6024: Handle slot assignments in unoptimized IR (may_optimize=false).
    # Unwrap Expr(:(=), SlotNumber(n), inner_expr) → compile inner_expr, store to slot local.
    _slot_assign_id = 0  # SlotNumber.id if this is a slot assignment, 0 otherwise
    if stmt isa Expr && stmt.head === :(=) && length(stmt.args) >= 2 && stmt.args[1] isa Core.SlotNumber
        _slot_assign_id = stmt.args[1].id
        stmt = stmt.args[2]  # Unwrap to inner expression
    end

    if stmt isa Core.ReturnNode
        # DEBUG: Trace compile_statement ReturnNode handler
        if isdefined(stmt, :val)
            # Check function return type
            func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
            val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
            is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64

            if func_ret_wasm === ExternRef && is_numeric_val
                # PURE-325: Box numeric value for ExternRef return (handles nothing too)
                emit_numeric_to_externref!(bytes, stmt.val, val_wasm, ctx)
            elseif func_ret_wasm isa ConcreteRef && is_numeric_val
                # PURE-045: Numeric (nothing) to concrete ref - return ref.null of the type
                push!(bytes, Opcode.REF_NULL)
                append!(bytes, encode_leb128_signed(Int64(func_ret_wasm.type_idx)))
            elseif (func_ret_wasm === StructRef || func_ret_wasm === ArrayRef || func_ret_wasm === AnyRef) && is_numeric_val
                # PURE-045: Numeric to abstract ref - return ref.null of the abstract type
                push!(bytes, Opcode.REF_NULL)
                push!(bytes, UInt8(func_ret_wasm))
            else
                append!(bytes, compile_value(stmt.val, ctx))
                # If function returns externref but value is a concrete ref, convert
                if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                # PURE-207: If value is I32 but return is I64, extend
                elseif val_wasm === I32 && func_ret_wasm === I64
                    push!(bytes, Opcode.I64_EXTEND_I32_S)
                end
            end
        end
        push!(bytes, Opcode.RETURN)

    elseif stmt isa Core.GotoNode
        # Unconditional branch - handled by control flow analysis

    elseif stmt isa Core.GotoIfNot
        # Conditional branch - handled by control flow analysis

    elseif stmt isa Core.PiNode
        # PiNode is a type assertion - just pass through the value
        pi_type = get(ctx.ssa_types, idx, Any)
        if pi_type !== Nothing
            # Check type compatibility before storing PiNode value
            if haskey(ctx.ssa_locals, idx)
                local_idx = ctx.ssa_locals[idx]
                local_array_idx = local_idx - ctx.n_params + 1
                pi_local_type = local_array_idx >= 1 && local_array_idx <= length(ctx.locals) ? ctx.locals[local_array_idx] : nothing
                # Determine the value's wasm type
                val_wasm_type = get_phi_edge_wasm_type(stmt.val, ctx)
                # Check if source is a multi-value expression (e.g., multi-arg memoryrefnew)
                # that would push >1 value on the stack — local_set only consumes 1.
                is_multi_value_src = false
                if stmt.val isa Core.SSAValue && !haskey(ctx.ssa_locals, stmt.val.id) && !haskey(ctx.phi_locals, stmt.val.id)
                    src_stmt = ctx.code_info.code[stmt.val.id]
                    if src_stmt isa Expr && src_stmt.head === :call
                        src_func = src_stmt.args[1]
                        is_multi_value_src = (src_func isa GlobalRef &&
                                             (src_func.mod === Core || src_func.mod === Base) &&
                                             src_func.name === :memoryrefnew &&
                                             length(src_stmt.args) >= 4)
                    end
                end
                if is_multi_value_src || (pi_local_type !== nothing && val_wasm_type !== nothing && !wasm_types_compatible(pi_local_type, val_wasm_type))
                    # PURE-324: I64→I32 narrowing — PiNode narrows a widened phi (I64) to a
                    # smaller numeric type (I32). Emit the actual value with i32_wrap_i64.
                    if !is_multi_value_src && val_wasm_type === I64 && pi_local_type === I32
                        val_bytes = compile_value(stmt.val, ctx)
                        append!(bytes, val_bytes)
                        push!(bytes, Opcode.I32_WRAP_I64)
                    # PURE-325: PiNode narrowing from ExternRef → numeric (I64/I32/F64/F32).
                    # The externref holds a boxed numeric value. Unbox via any_convert_extern +
                    # ref_cast to box type + struct_get field 0.
                    elseif !is_multi_value_src && val_wasm_type === ExternRef && (pi_local_type === I64 || pi_local_type === I32 || pi_local_type === F64 || pi_local_type === F32)
                        val_bytes = compile_value(stmt.val, ctx)
                        append!(bytes, val_bytes)
                        local box_type_idx = get_numeric_box_type!(ctx.mod, ctx.type_registry, pi_local_type)
                        append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN])
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.REF_CAST_NULL)
                        append!(bytes, encode_leb128_signed(Int64(box_type_idx)))
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.STRUCT_GET)
                        append!(bytes, encode_leb128_unsigned(box_type_idx))
                        append!(bytes, encode_leb128_unsigned(UInt32(0)))  # field 0
                    # PURE-321: PiNode narrowing from ExternRef → ConcreteRef means the value
                    # IS available as externref and just needs conversion (not ref.null).
                    # Example: PiNode(%198, String) narrows Any (externref) → String (array<i32>).
                    elseif !is_multi_value_src && val_wasm_type === ExternRef && pi_local_type isa ConcreteRef
                        val_bytes = compile_value(stmt.val, ctx)
                        append!(bytes, val_bytes)
                        append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN])
                        append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.REF_CAST_NULL])
                        append!(bytes, encode_leb128_signed(Int64(pi_local_type.type_idx)))
                    # PURE-6024: Tagged union unwrapping — PiNode narrows Union{A,B} to variant.
                    # Source is a ConcreteRef (tagged union struct), target is the extracted variant.
                    # Example: π(%53::Union{AbstractString,Symbol}, Symbol) needs struct.get + cast.
                    elseif !is_multi_value_src && val_wasm_type isa ConcreteRef
                        src_julia_type = nothing
                        if stmt.val isa Core.SSAValue
                            src_julia_type = get(ctx.ssa_types, stmt.val.id, nothing)
                        elseif stmt.val isa Core.Argument
                            arg_idx = stmt.val.n - 1
                            if arg_idx >= 1 && arg_idx <= length(ctx.arg_types)
                                src_julia_type = ctx.arg_types[arg_idx]
                            end
                        end
                        if src_julia_type isa Union && needs_tagged_union(src_julia_type)
                            val_bytes = compile_value(stmt.val, ctx)
                            append!(bytes, val_bytes)
                            append!(bytes, emit_unwrap_union_value(ctx, src_julia_type, stmt.typ))
                        elseif pi_local_type isa ConcreteRef
                            push!(bytes, Opcode.REF_NULL)
                            append!(bytes, encode_leb128_signed(Int64(pi_local_type.type_idx)))
                        elseif pi_local_type === ArrayRef
                            push!(bytes, Opcode.REF_NULL, UInt8(ArrayRef))
                        elseif pi_local_type === StructRef
                            push!(bytes, Opcode.REF_NULL, UInt8(StructRef))
                        else
                            push!(bytes, Opcode.REF_NULL, UInt8(ExternRef))
                        end
                    elseif pi_local_type === ExternRef
                        push!(bytes, Opcode.REF_NULL)
                        push!(bytes, UInt8(ExternRef))
                    elseif pi_local_type === AnyRef
                        push!(bytes, Opcode.REF_NULL)
                        push!(bytes, UInt8(AnyRef))
                    elseif pi_local_type === I64
                        push!(bytes, Opcode.I64_CONST)
                        push!(bytes, 0x00)
                    elseif pi_local_type === I32
                        push!(bytes, Opcode.I32_CONST)
                        push!(bytes, 0x00)
                    elseif pi_local_type === F64
                        push!(bytes, Opcode.F64_CONST)
                        append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                    elseif pi_local_type === F32
                        push!(bytes, Opcode.F32_CONST)
                        append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00])
                    else
                        push!(bytes, Opcode.I32_CONST)
                        push!(bytes, 0x00)
                    end
                else
                    val_bytes = compile_value(stmt.val, ctx)
                    # Safety: check if val_bytes pushes multiple values (all local_gets, N>=2).
                    # local_set only consumes 1, so N-1 would be orphaned.
                    is_multi_value_bytes = false
                    if length(val_bytes) >= 4
                        _all_gets = true
                        _n_gets = 0
                        _pos = 1
                        while _pos <= length(val_bytes)
                            if val_bytes[_pos] != 0x20
                                _all_gets = false
                                break
                            end
                            _n_gets += 1
                            _pos += 1
                            while _pos <= length(val_bytes) && (val_bytes[_pos] & 0x80) != 0
                                _pos += 1
                            end
                            _pos += 1
                        end
                        if _all_gets && _pos > length(val_bytes) && _n_gets >= 2
                            is_multi_value_bytes = true
                        end
                    end
                    if is_multi_value_bytes
                        # Multi-value source: emit type-safe default for the local's type
                        if pi_local_type isa ConcreteRef
                            push!(bytes, Opcode.REF_NULL)
                            append!(bytes, encode_leb128_signed(Int64(pi_local_type.type_idx)))
                        elseif pi_local_type === StructRef
                            push!(bytes, Opcode.REF_NULL)
                            push!(bytes, UInt8(StructRef))
                        elseif pi_local_type === ArrayRef
                            push!(bytes, Opcode.REF_NULL)
                            push!(bytes, UInt8(ArrayRef))
                        elseif pi_local_type === ExternRef
                            push!(bytes, Opcode.REF_NULL)
                            push!(bytes, UInt8(ExternRef))
                        elseif pi_local_type === AnyRef
                            push!(bytes, Opcode.REF_NULL)
                            push!(bytes, UInt8(AnyRef))
                        elseif pi_local_type === I64
                            push!(bytes, Opcode.I64_CONST)
                            push!(bytes, 0x00)
                        elseif pi_local_type === I32
                            push!(bytes, Opcode.I32_CONST)
                            push!(bytes, 0x00)
                        elseif pi_local_type === F64
                            push!(bytes, Opcode.F64_CONST)
                            append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                        elseif pi_local_type === F32
                            push!(bytes, Opcode.F32_CONST)
                            append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00])
                        else
                            push!(bytes, Opcode.I32_CONST)
                            push!(bytes, 0x00)
                        end
                    # Safety: if compile_value produced a numeric value (i32_const, i64_const,
                    # or local.get of numeric local) but pi_local_type is a ref type,
                    # emit ref.null instead. This happens when val_wasm_type is nothing
                    # (can't determine source type) but the PiNode's target local is ref-typed.
                    elseif pi_local_type !== nothing && (pi_local_type isa ConcreteRef || pi_local_type === StructRef || pi_local_type === ArrayRef || pi_local_type === ExternRef || pi_local_type === AnyRef)
                        is_numeric_val = false
                        if !isempty(val_bytes)
                            first_op = val_bytes[1]
                            if first_op == Opcode.I32_CONST || first_op == Opcode.I64_CONST || first_op == Opcode.F32_CONST || first_op == Opcode.F64_CONST
                                # PURE-318/PURE-325: Check for GC_PREFIX — struct/array ops produce refs, not numerics
                                is_numeric_val = !has_ref_producing_gc_op(val_bytes)
                            elseif first_op == 0x20  # LOCAL_GET
                                # Decode local index, check type
                                src_idx = 0; shift = 0; leb_end = 0
                                for bi in 2:length(val_bytes)
                                    b = val_bytes[bi]
                                    src_idx |= (Int(b & 0x7f) << shift)
                                    shift += 7
                                    if (b & 0x80) == 0
                                        leb_end = bi
                                        break
                                    end
                                end
                                if leb_end == length(val_bytes)
                                    arr_idx = src_idx - ctx.n_params + 1
                                    if arr_idx >= 1 && arr_idx <= length(ctx.locals)
                                        src_type = ctx.locals[arr_idx]
                                        if src_type === I32 || src_type === I64 || src_type === F32 || src_type === F64
                                            is_numeric_val = true
                                        end
                                    end
                                end
                            end
                        end
                        if is_numeric_val
                            # Replace with ref.null of the correct type
                            if pi_local_type isa ConcreteRef
                                push!(bytes, Opcode.REF_NULL)
                                append!(bytes, encode_leb128_signed(Int64(pi_local_type.type_idx)))
                            elseif pi_local_type === ArrayRef
                                push!(bytes, Opcode.REF_NULL)
                                push!(bytes, UInt8(ArrayRef))
                            elseif pi_local_type === ExternRef
                                emit_numeric_to_externref!(bytes, stmt.val, val_wasm, ctx)
                            elseif pi_local_type === AnyRef
                                push!(bytes, Opcode.REF_NULL)
                                push!(bytes, UInt8(AnyRef))
                            else
                                push!(bytes, Opcode.REF_NULL)
                                push!(bytes, UInt8(StructRef))
                            end
                        else
                            append!(bytes, val_bytes)
                        end
                    else
                        append!(bytes, val_bytes)
                    end
                end
            end
            # else: no ssa_local — compile_value will re-emit the value on demand
        end
        # else: Nothing-typed PiNode without ssa_local — no-op

        # If this SSA value needs a local, store it (and remove from stack)
        if haskey(ctx.ssa_locals, idx)
            local_idx = ctx.ssa_locals[idx]
            push!(bytes, Opcode.LOCAL_SET)  # Use SET not TEE to not leave on stack
            append!(bytes, encode_leb128_unsigned(local_idx))
        end

    elseif stmt isa Core.NewvarNode
        # PURE-6024: Unoptimized IR slot initialization — no-op in WASM
        # (WASM locals are default-initialized to null/zero)

    elseif stmt isa Core.EnterNode
        # Exception handling: Enter try block
        # For now, we just skip this - full implementation requires try_table
        # The catch destination is in stmt.catch_dest
        # TODO: Implement full try/catch with try_table instruction

    elseif stmt isa GlobalRef
        # GlobalRef statement - check if it's a module-level global first
        key = (stmt.mod, stmt.name)
        if haskey(ctx.module_globals, key)
            # Emit global.get for module-level mutable struct instances
            global_idx = ctx.module_globals[key]
            push!(bytes, Opcode.GLOBAL_GET)
            append!(bytes, encode_leb128_unsigned(global_idx))

            # If this SSA value needs a local, store it
            if haskey(ctx.ssa_locals, idx)
                local_idx = ctx.ssa_locals[idx]
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(local_idx))
            end
        else
            # Regular GlobalRef - evaluate the constant and push it
            # This handles things like Main.SLOT_EMPTY that are module-level constants
            try
                val = getfield(stmt.mod, stmt.name)
                value_bytes = compile_value(val, ctx)
                append!(bytes, value_bytes)

                # If this SSA value needs a local, store it (only if we actually pushed a value)
                # compile_value returns empty bytes for Functions, Types, etc.
                if !isempty(value_bytes) && haskey(ctx.ssa_locals, idx)
                    local_idx = ctx.ssa_locals[idx]
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(local_idx))
                end
            catch
                # If we can't evaluate, it might be a type reference which has no runtime value
            end
        end

    elseif stmt isa Expr
        stmt_bytes = UInt8[]
        ctx.last_stmt_was_stub = false  # PURE-908: reset before dispatch
        if stmt.head === :call
            stmt_bytes = compile_call(stmt, idx, ctx)
        elseif stmt.head === :invoke
            stmt_bytes = compile_invoke(stmt, idx, ctx)
        elseif stmt.head === :new
            # Struct construction: %new(Type, args...)
            stmt_bytes = compile_new(stmt, idx, ctx)
        elseif stmt.head === :boundscheck
            # Bounds check - we can skip this as Wasm has its own bounds checking
            # This is a no-op that produces a Bool (we push false since we're not doing checks)
            push!(stmt_bytes, Opcode.I32_CONST)
            push!(stmt_bytes, 0x00)  # false = no bounds checking
        elseif stmt.head === :foreigncall
            # Handle foreign calls - specifically for Vector allocation
            stmt_bytes = compile_foreigncall(stmt, idx, ctx)
        elseif stmt.head === :leave
            # Exception handling: Leave try block
            # For now, skip - full implementation requires try_table control flow
            # TODO: Implement proper br out of try_table
        elseif stmt.head === :pop_exception
            # Exception handling: Pop exception from handler stack
            # For now, skip - full implementation requires exnref handling
            # TODO: Implement proper exception value handling
        end

        # PURE-908: Check if compile_call/compile_invoke emitted a stub UNREACHABLE.
        # Byte-level detection of 0x00 is unreliable (LEB128 zeros are common).
        # Instead, compile_call/compile_invoke set ctx.last_stmt_was_stub = true.
        _stmt_ends_unreachable = ctx.last_stmt_was_stub
        # PURE-6024: Don't reset here — let callers (generate_stackified_flow etc.)
        # detect unreachable and skip dead code. Reset happens at start of next
        # compile_statement call (line ~15011).

        # Safety check: if stmt_bytes produces a value incompatible with the SSA local type,
        # replace with type-safe default. Catches:
        # (1) Pure local.get of incompatible type
        # (2) Numeric constants (i32_const, i64_const, f32_const, f64_const) stored into ref-typed locals
        # (3) struct_get producing abstract ref (structref/arrayref) where concrete ref expected → ref.cast
        ssa_type_mismatch = false
        needs_ref_cast_local = nothing  # Set to ConcreteRef target type when ref.cast is needed
        needs_any_convert_extern = false  # PURE-036bj: externref→anyref before ref.cast
        needs_extern_convert_any = false  # PURE-913: ref→externref for Any-typed locals
        # PURE-908: Skip safety checks for stub stmts — no value on stack to check
        if !_stmt_ends_unreachable && haskey(ctx.ssa_locals, idx) && length(stmt_bytes) >= 2
            local_idx = ctx.ssa_locals[idx]
            local_array_idx = local_idx - ctx.n_params + 1
            local_wasm_type = local_array_idx >= 1 && local_array_idx <= length(ctx.locals) ? ctx.locals[local_array_idx] : nothing
            if local_wasm_type !== nothing
                needs_type_safe_default = false
                struct_get_type_ok = false  # PURE-904: Track when struct_get already produces compatible type

                if stmt_bytes[1] == 0x20  # LOCAL_GET
                    # Decode the source local.get index and verify it consumes ALL bytes
                    src_local_idx = 0
                    shift = 0
                    leb_end = 0
                    for bi in 2:length(stmt_bytes)
                        b = stmt_bytes[bi]
                        src_local_idx |= (Int(b & 0x7f) << shift)
                        shift += 7
                        if (b & 0x80) == 0
                            leb_end = bi
                            break
                        end
                    end
                    # Only apply safety check if stmt_bytes is EXACTLY local.get <idx>
                    is_pure_local_get = (leb_end == length(stmt_bytes))
                    src_array_idx = src_local_idx - ctx.n_params + 1
                    if is_pure_local_get && src_array_idx >= 1 && src_array_idx <= length(ctx.locals)
                        src_wasm_type = ctx.locals[src_array_idx]
                        if !wasm_types_compatible(local_wasm_type, src_wasm_type)
                            # Check if this is abstract ref → concrete ref (can be cast, not replaced)
                            if (src_wasm_type === StructRef || src_wasm_type === ArrayRef) && local_wasm_type isa ConcreteRef
                                # Abstract ref can be downcast to concrete ref with ref.cast
                                needs_ref_cast_local = local_wasm_type
                            elseif src_wasm_type === ExternRef && local_wasm_type isa ConcreteRef
                                # PURE-036bj: externref local → concrete ref requires any_convert_extern first
                                needs_any_convert_extern = true
                                needs_ref_cast_local = local_wasm_type
                            elseif (src_wasm_type isa ConcreteRef || src_wasm_type === StructRef || src_wasm_type === ArrayRef || src_wasm_type === AnyRef) && local_wasm_type === ExternRef
                                # PURE-913: concrete/abstract ref → externref requires extern_convert_any
                                needs_extern_convert_any = true
                            else
                                needs_type_safe_default = true
                            end
                        end
                    elseif is_pure_local_get && src_local_idx < ctx.n_params
                        # Source is a function parameter - get its Wasm type from arg_types
                        param_julia_type = ctx.arg_types[src_local_idx + 1]  # Julia is 1-indexed
                        src_wasm_type = get_concrete_wasm_type(param_julia_type, ctx.mod, ctx.type_registry)
                        if src_wasm_type !== nothing && !wasm_types_compatible(local_wasm_type, src_wasm_type)
                            # Check if this is abstract ref → concrete ref (can be cast, not replaced)
                            if (src_wasm_type === StructRef || src_wasm_type === ArrayRef) && local_wasm_type isa ConcreteRef
                                needs_ref_cast_local = local_wasm_type
                            elseif src_wasm_type === ExternRef && local_wasm_type isa ConcreteRef
                                # PURE-036bj: externref param → concrete ref requires any_convert_extern first
                                needs_any_convert_extern = true
                                needs_ref_cast_local = local_wasm_type
                            elseif (src_wasm_type isa ConcreteRef || src_wasm_type === StructRef || src_wasm_type === ArrayRef || src_wasm_type === AnyRef) && local_wasm_type === ExternRef
                                # PURE-913: concrete/abstract ref param → externref requires extern_convert_any
                                needs_extern_convert_any = true
                            else
                                needs_type_safe_default = true
                            end
                        end
                    end
                elseif (stmt_bytes[1] == Opcode.I32_CONST || stmt_bytes[1] == Opcode.I64_CONST ||
                        stmt_bytes[1] == Opcode.F32_CONST || stmt_bytes[1] == Opcode.F64_CONST)
                    # Numeric constant being stored into a ref-typed local
                    # PURE-204: Skip for invoke/call results — their stmt_bytes start with
                    # i32.const for the first argument but contain a CALL that returns a ref type.
                    # PURE-317: Also skip for :new (struct construction) — first field may be
                    # numeric but the result is always a struct ref (via struct_new at the end).
                    is_call_result = stmt isa Expr && (stmt.head === :invoke || stmt.head === :call || stmt.head === :new || stmt.head === :foreigncall)
                    if !is_call_result &&
                       (local_wasm_type isa ConcreteRef || local_wasm_type === StructRef ||
                        local_wasm_type === ArrayRef || local_wasm_type === ExternRef || local_wasm_type === AnyRef)
                        needs_type_safe_default = true
                    end
                end

                # Check if stmt_bytes is a compound numeric expression stored into a
                # ref-typed local. Pattern: starts with local.get (0x20) and ends with
                # a pure stack numeric opcode (no immediate args). This catches cases
                # like: local.get + i32_wrap_i64 + i32_const + i32_sub → stored in ref local.
                # We require stmt_bytes[1] == LOCAL_GET to avoid false positives with
                # constants whose LEB128 values happen to match opcode bytes.
                # PURE-206: Skip for Int128/UInt128 SSAs — their intrinsic code
                # (sext_int, add_int, etc.) ends with struct_new whose LEB128 type
                # index byte can be misidentified as a numeric opcode.
                # PURE-307: Skip for struct construction (:new), Core.tuple, and getfield
                # on ref-producing statements. These emit GC-prefix instructions
                # (struct_new, struct_get, array_new) whose LEB128 type index bytes
                # can match numeric opcode ranges (0x46-0xC4). For example,
                # struct_new type 74 → bytes [0xFB, 0x00, 0x4A], and 0x4A = i32.ge_s.
                ssa_is_128bit = false
                if local_wasm_type isa ConcreteRef
                    ssa_jt_128 = get(ctx.ssa_types, idx, nothing)
                    ssa_is_128bit = (ssa_jt_128 === Int128 || ssa_jt_128 === UInt128)
                end
                # PURE-307: Skip for statements that produce ref values (struct/array ops)
                # Check if stmt_bytes contains GC_PREFIX (0xFB) — all WasmGC struct/array
                # operations use this prefix, and their LEB128 operands cause false positives.
                has_gc_prefix = false
                if !ssa_is_128bit
                    for bi in 1:length(stmt_bytes)
                        if stmt_bytes[bi] == Opcode.GC_PREFIX
                            has_gc_prefix = true
                            break
                        end
                    end
                end
                if !needs_type_safe_default && !ssa_is_128bit && !has_gc_prefix && length(stmt_bytes) >= 3 &&
                   stmt_bytes[1] == 0x20 &&  # starts with local.get
                   (local_wasm_type isa ConcreteRef || local_wasm_type === StructRef ||
                    local_wasm_type === ArrayRef || local_wasm_type === ExternRef || local_wasm_type === AnyRef)
                    last_byte = stmt_bytes[end]
                    # PURE-220: Check that the last byte is NOT an operand of a
                    # trailing instruction with LEB128 immediate.
                    # Scan backward for opcodes followed by LEB128 operands:
                    #   LOCAL_GET/SET/TEE (0x20-0x22), CALL (0x10),
                    #   CALL_INDIRECT (0x11), BR (0x0C), BR_IF (0x0D),
                    #   GLOBAL_GET/SET (0x23/0x24).
                    # When the function index in a CALL instruction's LEB128 encoding
                    # has its last byte in the numeric opcode range (0x46-0xC4), the
                    # check falsely triggers. E.g. call 80 → bytes [0x10, 0x50],
                    # and 0x50 = i64.eqz.
                    ends_with_leb_operand = false
                    for si in (length(stmt_bytes) - 1):-1:max(1, length(stmt_bytes) - 6)
                        b = stmt_bytes[si]
                        if b == 0x20 || b == 0x21 || b == 0x22 ||  # local.get/set/tee
                           b == 0x10 || b == 0x11 ||                # call/call_indirect
                           b == 0x23 || b == 0x24 ||                # global.get/set
                           b == 0x0C || b == 0x0D                   # br/br_if
                            # Check if the LEB128 after this opcode reaches exactly to end
                            leb_check_end = si
                            for bi in (si + 1):length(stmt_bytes)
                                leb_check_end = bi
                                if (stmt_bytes[bi] & 0x80) == 0
                                    break
                                end
                            end
                            if leb_check_end == length(stmt_bytes)
                                ends_with_leb_operand = true
                            end
                            break
                        end
                    end
                    if !ends_with_leb_operand
                        # Pure stack ops: single-byte opcodes with NO immediate arguments
                        is_numeric_stack_op = (
                            last_byte == 0x45 ||  # i32.eqz
                            last_byte == 0x50 ||  # i64.eqz
                            (last_byte >= 0x46 && last_byte <= 0x66) ||  # i32/i64/f32/f64 comparisons
                            (last_byte >= 0x67 && last_byte <= 0x78) ||  # i32 unary/binary arithmetic
                            (last_byte >= 0x79 && last_byte <= 0x8a) ||  # i64 unary/binary arithmetic
                            (last_byte >= 0x8b && last_byte <= 0xa6) ||  # f32/f64 arithmetic
                            (last_byte >= 0xa7 && last_byte <= 0xc4)     # numeric conversions
                        )
                        if is_numeric_stack_op
                            needs_type_safe_default = true
                        end
                    end
                end

                # Check if stmt_bytes ENDS with a local.get of incompatible type
                # (handles non-pure cases like memoryrefset! which returns value after array_set)
                # PURE-323: Skip when has_gc_prefix — WasmGC struct.get/array.get LEB128
                # operands (type index, field index) can have byte 0x20 which matches
                # LOCAL_GET opcode. E.g. struct.get type_32 field_0 = [0xFB, 0x02, 0x20, 0x00]
                # where 0x20 is LEB128(32), not LOCAL_GET.
                # PURE-913: Skip trailing check when the pure local.get check already
                # handled the conversion (any flag was set: ref_cast, any_convert, extern_convert)
                pure_check_handled = needs_ref_cast_local !== nothing || needs_any_convert_extern || needs_extern_convert_any
                if !needs_type_safe_default && !has_gc_prefix && !pure_check_handled && length(stmt_bytes) >= 2
                    # Find the last local_get at the end of stmt_bytes
                    local end_lg_pos = 0
                    # Scan backward for 0x20 (LOCAL_GET) that could be the trailing value
                    for si in length(stmt_bytes):-1:max(1, length(stmt_bytes) - 5)
                        if stmt_bytes[si] == 0x20 && si < length(stmt_bytes)
                            # PURE-306: Guard against false positives where 0x20 is actually
                            # an operand byte (e.g., LEB128 encoding of local index 32),
                            # not the LOCAL_GET opcode. If the previous byte is an opcode
                            # that takes a LEB128 operand, this 0x20 might be its operand.
                            if si > 1
                                prev_byte = stmt_bytes[si - 1]
                                if prev_byte == 0x20 || prev_byte == 0x21 || prev_byte == 0x22 ||  # local.get/set/tee
                                   prev_byte == 0x10 || prev_byte == 0x11 ||                        # call/call_indirect
                                   prev_byte == 0x23 || prev_byte == 0x24 ||                        # global.get/set
                                   prev_byte == 0x0C || prev_byte == 0x0D                           # br/br_if
                                    # This 0x20 could be the start of a LEB128 operand
                                    # for the previous instruction. Skip this false match.
                                    continue
                                end
                            end
                            # Try to decode LEB128 after it
                            local tlg_idx = 0
                            local tlg_shift = 0
                            local tlg_end = 0
                            for bi in (si + 1):length(stmt_bytes)
                                b = stmt_bytes[bi]
                                tlg_idx |= (Int(b & 0x7f) << tlg_shift)
                                tlg_shift += 7
                                if (b & 0x80) == 0
                                    tlg_end = bi
                                    break
                                end
                            end
                            if tlg_end == length(stmt_bytes)
                                # This local.get is at the very end of stmt_bytes
                                tlg_arr_idx = tlg_idx - ctx.n_params + 1
                                if tlg_arr_idx >= 1 && tlg_arr_idx <= length(ctx.locals)
                                    tlg_type = ctx.locals[tlg_arr_idx]
                                    if !wasm_types_compatible(local_wasm_type, tlg_type)
                                        # Trailing local.get of incompatible type — truncate and emit default
                                        resize!(stmt_bytes, si - 1)
                                        needs_type_safe_default = true
                                    end
                                elseif tlg_idx < ctx.n_params
                                    # PURE-036bl: Trailing local.get of a PARAM - check param type
                                    param_julia_type = ctx.arg_types[tlg_idx + 1]  # Julia is 1-indexed
                                    tlg_type = get_concrete_wasm_type(param_julia_type, ctx.mod, ctx.type_registry)
                                    if tlg_type !== nothing && !wasm_types_compatible(local_wasm_type, tlg_type)
                                        if tlg_type === ExternRef && local_wasm_type isa ConcreteRef
                                            # externref param → concrete ref requires any_convert_extern + ref.cast
                                            needs_any_convert_extern = true
                                            needs_ref_cast_local = local_wasm_type
                                        elseif (tlg_type === StructRef || tlg_type === ArrayRef) && local_wasm_type isa ConcreteRef
                                            needs_ref_cast_local = local_wasm_type
                                        else
                                            resize!(stmt_bytes, si - 1)
                                            needs_type_safe_default = true
                                        end
                                    end
                                end
                            end
                            break
                        end
                    end
                end

                # Check if stmt_bytes ends with struct_get whose result type is incompatible
                # with the target local. struct_get = [0xFB, 0x02, type_leb, field_leb]
                if !needs_type_safe_default && length(stmt_bytes) >= 4 && local_wasm_type isa ConcreteRef
                    # Find the last struct_get in stmt_bytes by scanning backward for 0xFB 0x02
                    sg_pos = 0
                    for si in (length(stmt_bytes) - 3):-1:1
                        if stmt_bytes[si] == Opcode.GC_PREFIX && stmt_bytes[si + 1] == Opcode.STRUCT_GET
                            sg_pos = si
                            break
                        end
                    end
                    if sg_pos > 0 && sg_pos + 2 <= length(stmt_bytes)
                        # Decode type_idx LEB128
                        sg_type_idx = 0
                        sg_shift = 0
                        sg_bi = sg_pos + 2
                        while sg_bi <= length(stmt_bytes)
                            b = stmt_bytes[sg_bi]
                            sg_type_idx |= (Int(b & 0x7f) << sg_shift)
                            sg_shift += 7
                            sg_bi += 1
                            (b & 0x80) == 0 && break
                        end
                        # Decode field_idx LEB128
                        sg_field_idx = 0
                        sg_shift = 0
                        while sg_bi <= length(stmt_bytes)
                            b = stmt_bytes[sg_bi]
                            sg_field_idx |= (Int(b & 0x7f) << sg_shift)
                            sg_shift += 7
                            sg_bi += 1
                            (b & 0x80) == 0 && break
                        end
                        # Check: is the struct_get the LAST instruction? (sg_bi - 1 == length)
                        if sg_bi - 1 == length(stmt_bytes) && sg_type_idx + 1 <= length(ctx.mod.types)
                            mod_type = ctx.mod.types[sg_type_idx + 1]
                            if mod_type isa StructType && sg_field_idx + 1 <= length(mod_type.fields)
                                field_result_type = mod_type.fields[sg_field_idx + 1].valtype
                                if field_result_type isa ConcreteRef && wasm_types_compatible(local_wasm_type, field_result_type)
                                    # PURE-904: struct_get already produces compatible concrete type.
                                    # Skip SSA type check — it would see Julia Any→ExternRef and
                                    # incorrectly emit any_convert_extern.
                                    struct_get_type_ok = true
                                elseif field_result_type isa ConcreteRef
                                    # Incompatible concrete ref types
                                    needs_type_safe_default = true
                                elseif (field_result_type === I32 || field_result_type === I64 ||
                                        field_result_type === F32 || field_result_type === F64)
                                    # struct_get produces a numeric value but target local is ref-typed
                                    needs_type_safe_default = true
                                elseif (field_result_type === StructRef || field_result_type === ArrayRef) && local_wasm_type isa ConcreteRef
                                    # struct_get produces abstract ref (structref/arrayref) due to forward-reference
                                    # in struct registration, but the target local expects a concrete ref type.
                                    # Insert ref.cast null to downcast.
                                    needs_ref_cast_local = local_wasm_type
                                elseif field_result_type === ExternRef && local_wasm_type isa ConcreteRef
                                    # struct_get produces externref (Any-typed field) but target local is concrete ref.
                                    # Need any_convert_extern + ref.cast to downcast.
                                    needs_any_convert_extern = true
                                    needs_ref_cast_local = local_wasm_type
                                end
                            end
                        end
                    end
                end

                # Check if the SSA type of this statement maps to a type incompatible
                # with the local. This catches calls, invokes, and compound expressions
                # that produce numeric/externref/abstract ref but get stored in a ref-typed local.
                local_is_ref = local_wasm_type isa ConcreteRef || local_wasm_type === StructRef ||
                               local_wasm_type === ArrayRef || local_wasm_type === ExternRef || local_wasm_type === AnyRef
                if !needs_type_safe_default && needs_ref_cast_local === nothing && !struct_get_type_ok && local_is_ref
                    ssa_julia_type = get(ctx.ssa_types, idx, nothing)
                    if ssa_julia_type !== nothing
                        ssa_wasm_type = julia_to_wasm_type_concrete(ssa_julia_type, ctx)
                        if (ssa_wasm_type === I32 || ssa_wasm_type === I64 ||
                            ssa_wasm_type === F32 || ssa_wasm_type === F64)
                            # SSA produces numeric value but local expects ref type
                            # (compound numeric expressions like i32_wrap + i32_sub)
                            needs_type_safe_default = true
                        elseif ssa_wasm_type === ExternRef && local_wasm_type isa ConcreteRef
                            # SSA produces externref but local expects concrete ref.
                            # PURE-325: For memoryrefset! calls, the return value is the
                            # stored element (Any/externref), NOT the array. Casting it to
                            # the local's ConcreteRef type would crash at runtime. Use
                            # type-safe default instead (drop value, push ref.null).
                            local is_memrefset_call = (stmt isa Expr && stmt.head === :call &&
                                length(stmt.args) >= 1 &&
                                stmt.args[1] isa GlobalRef &&
                                (stmt.args[1].mod === Base || stmt.args[1].mod === Core) &&
                                stmt.args[1].name === :memoryrefset!)
                            if is_memrefset_call
                                needs_type_safe_default = true
                            else
                                # Insert: any_convert_extern (externref→anyref) + ref.cast null <type>
                                needs_ref_cast_local = local_wasm_type
                                append!(stmt_bytes, UInt8[Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN])
                            end
                        elseif (ssa_wasm_type === StructRef || ssa_wasm_type === ArrayRef) && local_wasm_type isa ConcreteRef
                            # SSA produces abstract structref/arrayref, local expects concrete ref
                            needs_ref_cast_local = local_wasm_type
                        elseif (ssa_wasm_type isa ConcreteRef || ssa_wasm_type === StructRef || ssa_wasm_type === ArrayRef || ssa_wasm_type === AnyRef) && local_wasm_type === ExternRef
                            # PURE-3113: SSA produces concrete/abstract ref, local expects externref.
                            # This happens with memoryrefset! return values when has_gc_prefix
                            # skips the trailing local.get check. Convert via extern_convert_any.
                            # PURE-6022: But if the callee's actual WASM return type is already
                            # externref, skip the conversion — extern_convert_any expects anyref.
                            callee_already_externref = false
                            if stmt isa Expr && stmt.head === :invoke && length(stmt.args) >= 1
                                mi = stmt.args[1]
                                if mi isa Core.MethodInstance
                                    callee_ret_wt = julia_to_wasm_type(mi.rettype)
                                    if callee_ret_wt === ExternRef
                                        callee_already_externref = true
                                    end
                                end
                            elseif stmt isa Expr && stmt.head === :call && length(stmt.args) >= 1
                                callee_func = stmt.args[1]
                                if callee_func isa GlobalRef
                                    sig_ret = julia_to_wasm_type(ssa_julia_type)
                                    if sig_ret === ExternRef
                                        callee_already_externref = true
                                    end
                                end
                            end
                            if !callee_already_externref
                                needs_extern_convert_any = true
                            end
                        end
                        # PURE-036ae: Also check signature-level type mapping.
                        # When a cross-function call returns a struct type, the function's Wasm
                        # signature uses julia_to_wasm_type (returns StructRef) but the local
                        # was allocated using julia_to_wasm_type_concrete (returns ConcreteRef).
                        # Check if the signature-level type is StructRef/ArrayRef.
                        if needs_ref_cast_local === nothing && !needs_type_safe_default && local_wasm_type isa ConcreteRef
                            sig_wasm_type = julia_to_wasm_type(ssa_julia_type)
                            if (sig_wasm_type === StructRef || sig_wasm_type === ArrayRef)
                                # Function signature returns abstract ref, local expects concrete
                                needs_ref_cast_local = local_wasm_type
                                # PURE-900: For invoke/call stmts, the callee's ACTUAL Wasm return
                                # type may be externref (e.g. getindex returning Any). In that case,
                                # we need any_convert_extern before ref_cast.
                                if stmt isa Expr && stmt.head === :invoke && length(stmt.args) >= 1
                                    mi = stmt.args[1]
                                    if mi isa Core.MethodInstance
                                        callee_ret_wt = julia_to_wasm_type(mi.rettype)
                                        if callee_ret_wt === ExternRef
                                            needs_any_convert_extern = true
                                        end
                                    end
                                end
                            end
                        end
                    end
                end

                # PURE-6025: Catch numeric opcodes at end of stmt_bytes that produce numeric
                # values into ref-typed locals. The existing compound-numeric check (line ~15789)
                # is skipped when has_gc_prefix=true, and the SSA type check above misses cases
                # where the Julia type is Any/Union (maps to ExternRef, matching the local) but
                # the actual compiled code produces i64 (e.g., array_len + i64_extend_i32_s).
                # Bytes >= 0x80 at the end of stmt_bytes can't be LEB128 terminal bytes (bit 7
                # clear required), so they're guaranteed to be opcodes. Range 0x80-0xC4 covers
                # i64 arithmetic (0x79-0x8A) and numeric conversions (0xA7-0xC4).
                if !needs_type_safe_default && needs_ref_cast_local === nothing && local_is_ref && length(stmt_bytes) >= 1
                    last_byte = stmt_bytes[end]
                    if last_byte >= 0x80 && last_byte <= 0xC4
                        needs_type_safe_default = true
                    end
                end

                if needs_ref_cast_local !== nothing
                    # PURE-204/6025: Check if stmt_bytes end with a numeric constant (i32.const, i64.const, etc.)
                    # This happens when SSA type is Union{Nothing, T} — ssa_wasm_type maps to T's ConcreteRef,
                    # but the actual value is nothing/integer (e.g., i32.const 0, i64.const 1).
                    # ref.cast requires anyref, not i32/i64. Switch to type_safe_default instead.
                    ends_with_numeric = false
                    if length(stmt_bytes) >= 2
                        # Check for i32.const VALUE or i64.const VALUE where VALUE is a single-byte
                        # LEB128 (high bit clear = terminal byte, values 0-127).
                        # PURE-6025: Previous check only caught value==0x00; now catches any small constant.
                        if (stmt_bytes[end-1] == Opcode.I32_CONST || stmt_bytes[end-1] == Opcode.I64_CONST) && (stmt_bytes[end] & 0x80) == 0
                            ends_with_numeric = true
                        end
                    end
                    if !ends_with_numeric && length(stmt_bytes) >= 3
                        # Check for 2-byte LEB128 values (128-16383): opcode + continuation + terminal
                        if (stmt_bytes[end-2] == Opcode.I32_CONST || stmt_bytes[end-2] == Opcode.I64_CONST) && (stmt_bytes[end-1] & 0x80) != 0 && (stmt_bytes[end] & 0x80) == 0
                            ends_with_numeric = true
                        end
                    end
                    if ends_with_numeric
                        # Numeric constant can't be ref_cast'd — use type_safe_default
                        needs_type_safe_default = true
                        needs_ref_cast_local = nothing
                    else
                        # struct_get produced abstract ref or call returned externref,
                        # need to downcast to concrete type.
                        # PURE-036bj: if source is externref, first convert to anyref
                        # PURE-323: Also check if stmt_bytes ends with local.get of an
                        # externref local. The SSA type check may have set needs_ref_cast_local
                        # based on Julia type (e.g. ArrayRef) without detecting that the actual
                        # wasm local is externref. This happens when has_gc_prefix=true skips
                        # the trailing local.get check at line 13299.
                        if !needs_any_convert_extern && length(stmt_bytes) >= 2
                            for si in length(stmt_bytes):-1:max(1, length(stmt_bytes) - 5)
                                if stmt_bytes[si] == 0x20 && si < length(stmt_bytes)  # LOCAL_GET
                                    tlg_idx_rc = 0
                                    tlg_shift_rc = 0
                                    tlg_end_rc = 0
                                    for bi in (si + 1):length(stmt_bytes)
                                        b = stmt_bytes[bi]
                                        tlg_idx_rc |= (Int(b & 0x7f) << tlg_shift_rc)
                                        tlg_shift_rc += 7
                                        if (b & 0x80) == 0
                                            tlg_end_rc = bi
                                            break
                                        end
                                    end
                                    if tlg_end_rc == length(stmt_bytes)
                                        tlg_arr_rc = tlg_idx_rc - ctx.n_params + 1
                                        if tlg_arr_rc >= 1 && tlg_arr_rc <= length(ctx.locals) && ctx.locals[tlg_arr_rc] === ExternRef
                                            needs_any_convert_extern = true
                                        elseif tlg_idx_rc < ctx.n_params
                                            # Parameter — check its wasm type
                                            param_jt = ctx.arg_types[tlg_idx_rc + 1]
                                            param_wt = get_concrete_wasm_type(param_jt, ctx.mod, ctx.type_registry)
                                            if param_wt === ExternRef
                                                needs_any_convert_extern = true
                                            end
                                        end
                                    end
                                    break
                                elseif stmt_bytes[si] == 0x10 && si < length(stmt_bytes)  # CALL
                                    # PURE-900: Check if call returns externref
                                    # Functions might not be in mod.functions yet during compilation,
                                    # so use func_registry which was pre-populated.
                                    call_idx_rc = 0
                                    call_shift_rc = 0
                                    call_end_rc = 0
                                    for bi in (si + 1):length(stmt_bytes)
                                        b = stmt_bytes[bi]
                                        call_idx_rc |= (Int(b & 0x7f) << call_shift_rc)
                                        call_shift_rc += 7
                                        if (b & 0x80) == 0
                                            call_end_rc = bi
                                            break
                                        end
                                    end
                                    if call_end_rc == length(stmt_bytes)
                                        n_imports = length(ctx.mod.imports)
                                        if call_idx_rc < n_imports
                                            # Imported function — check import's type
                                            imp = ctx.mod.imports[call_idx_rc + 1]
                                            imp_type = ctx.mod.types[imp.type_idx + 1]
                                            if imp_type isa FuncType && !isempty(imp_type.results) && imp_type.results[1] === ExternRef
                                                needs_any_convert_extern = true
                                            end
                                        elseif ctx.func_registry !== nothing
                                            # Look up via func_registry (pre-populated before compilation)
                                            for (_, finfo) in ctx.func_registry.functions
                                                if finfo.wasm_idx == UInt32(call_idx_rc)
                                                    ret_wt = get_concrete_wasm_type(finfo.return_type, ctx.mod, ctx.type_registry)
                                                    if ret_wt === ExternRef
                                                        needs_any_convert_extern = true
                                                    end
                                                    break
                                                end
                                            end
                                        end
                                    end
                                    break
                                end
                            end
                        end
                        if needs_any_convert_extern
                            append!(stmt_bytes, UInt8[Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN])
                        end
                        # Append ref.cast null <type_idx> to stmt_bytes
                        append!(stmt_bytes, UInt8[Opcode.GC_PREFIX, Opcode.REF_CAST_NULL])
                        append!(stmt_bytes, encode_leb128_signed(Int64(needs_ref_cast_local.type_idx)))
                    end
                end

                # PURE-913: ref → externref conversion (e.g., compilerbarrier returning struct into Any local)
                if needs_extern_convert_any
                    append!(stmt_bytes, UInt8[Opcode.GC_PREFIX, Opcode.EXTERN_CONVERT_ANY])
                end

                # PURE-3111: Final catch-all for phantom type returns (Nothing/Type{T}).
                # compile_value emits i32_const 0 for these, but SSA type detection may
                # think the value is a ref (e.g., memoryrefset! returns the stored value,
                # which could be Type → SSA type is DataType → ConcreteRef). If stmt_bytes
                # ends with i32_const 0 and the local is ref-typed, override to type_safe_default.
                # PURE-6015: Guard with !has_gc_prefix to avoid false positive on struct.get/array.get
                # whose LEB128 type index bytes can match i32.const (0x41). For example,
                # struct.get 65 0 = [0xFB, 0x02, 0x41, 0x00] where 0x41 = i32.const opcode.
                # The earlier check at line 15046 already uses !has_gc_prefix for the same reason.
                if !needs_type_safe_default && needs_ref_cast_local === nothing && local_is_ref && !has_gc_prefix && length(stmt_bytes) >= 2
                    # PURE-6025: Expanded to catch any small numeric constant, not just i32.const 0.
                    # An i64.const 1 stored into a ref-typed local also needs type_safe_default.
                    # Check 1-byte LEB128 (values 0-63 signed / 0-127 unsigned)
                    if (stmt_bytes[end-1] == Opcode.I32_CONST || stmt_bytes[end-1] == Opcode.I64_CONST) && (stmt_bytes[end] & 0x80) == 0
                        needs_type_safe_default = true
                    end
                    # Check 2-byte LEB128 (values 64-8191): opcode + continuation + terminal
                    # e.g., i32.const 111 = [0x41, 0xEF, 0x00]
                    if !needs_type_safe_default && length(stmt_bytes) >= 3
                        if (stmt_bytes[end-2] == Opcode.I32_CONST || stmt_bytes[end-2] == Opcode.I64_CONST) && (stmt_bytes[end-1] & 0x80) != 0 && (stmt_bytes[end] & 0x80) == 0
                            needs_type_safe_default = true
                        end
                    end
                end

                if needs_type_safe_default
                    ssa_type_mismatch = true
                    # Emit type-safe default instead of the incompatible value
                    if local_wasm_type isa ConcreteRef
                        push!(bytes, Opcode.REF_NULL)
                        append!(bytes, encode_leb128_signed(Int64(local_wasm_type.type_idx)))
                    elseif local_wasm_type === ExternRef
                        push!(bytes, Opcode.REF_NULL)
                        push!(bytes, UInt8(ExternRef))
                    elseif local_wasm_type === StructRef
                        push!(bytes, Opcode.REF_NULL)
                        push!(bytes, UInt8(StructRef))
                    elseif local_wasm_type === ArrayRef
                        push!(bytes, Opcode.REF_NULL)
                        push!(bytes, UInt8(ArrayRef))
                    elseif local_wasm_type === AnyRef
                        push!(bytes, Opcode.REF_NULL)
                        push!(bytes, UInt8(AnyRef))
                    elseif local_wasm_type === I64
                        push!(bytes, Opcode.I64_CONST)
                        push!(bytes, 0x00)
                    elseif local_wasm_type === I32
                        push!(bytes, Opcode.I32_CONST)
                        push!(bytes, 0x00)
                    elseif local_wasm_type === F64
                        push!(bytes, Opcode.F64_CONST)
                        append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                    elseif local_wasm_type === F32
                        push!(bytes, Opcode.F32_CONST)
                        append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00])
                    else
                        push!(bytes, Opcode.I32_CONST)
                        push!(bytes, 0x00)
                    end
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(local_idx))
                end
            end
        end

        # Detect statements that push multiple values on the stack.
        # This includes multi-arg memoryrefnew (2 values: arrayref + i32_index)
        # and other array access patterns (base + index local_get pairs).
        # When no SSA local: skip appending (values re-computed on-demand).
        # When SSA local exists: emit type-safe default instead (local_set
        # only consumes 1 value, leaving N-1 orphaned).
        is_orphaned_multi_value = false
        if !isempty(stmt_bytes) && !ssa_type_mismatch
            if !haskey(ctx.ssa_locals, idx) && stmt isa Expr && stmt.head === :call
                func_ref = stmt.args[1]
                is_orphaned_multi_value = (func_ref isa GlobalRef &&
                                           (func_ref.mod === Core || func_ref.mod === Base) &&
                                           func_ref.name === :memoryrefnew &&
                                           length(stmt.args) >= 4)
            end
            # General orphan detection: if stmt_bytes consists entirely of
            # local_get instructions (opcode 0x20 + LEB128 index) pushing 2+ values,
            # it's pure stack-pushing with no side effects. Without proper consumption
            # these values will be orphaned on the stack.
            # This catches base+index pairs from array access patterns.
            if !is_orphaned_multi_value && length(stmt_bytes) >= 4
                all_local_gets = true
                n_gets = 0
                pos = 1
                while pos <= length(stmt_bytes)
                    if stmt_bytes[pos] != 0x20  # LOCAL_GET opcode
                        all_local_gets = false
                        break
                    end
                    n_gets += 1
                    pos += 1
                    # Skip LEB128 local index
                    while pos <= length(stmt_bytes) && (stmt_bytes[pos] & 0x80) != 0
                        pos += 1
                    end
                    pos += 1  # final byte of LEB128
                end
                if all_local_gets && pos > length(stmt_bytes) && n_gets >= 2
                    if haskey(ctx.ssa_locals, idx)
                        # Statement pushes multiple values but has an SSA local.
                        # local_set would only consume 1, leaving N-1 orphaned.
                        # Emit type-safe default for the SSA local instead.
                        local_idx = ctx.ssa_locals[idx]
                        local_array_idx = local_idx - ctx.n_params + 1
                        local_wasm_type = local_array_idx >= 1 && local_array_idx <= length(ctx.locals) ? ctx.locals[local_array_idx] : nothing
                        if local_wasm_type !== nothing
                            if local_wasm_type isa ConcreteRef
                                push!(bytes, Opcode.REF_NULL)
                                append!(bytes, encode_leb128_signed(Int64(local_wasm_type.type_idx)))
                            elseif local_wasm_type === ExternRef
                                push!(bytes, Opcode.REF_NULL)
                                push!(bytes, UInt8(ExternRef))
                            elseif local_wasm_type === StructRef
                                push!(bytes, Opcode.REF_NULL)
                                push!(bytes, UInt8(StructRef))
                            elseif local_wasm_type === ArrayRef
                                push!(bytes, Opcode.REF_NULL)
                                push!(bytes, UInt8(ArrayRef))
                            elseif local_wasm_type === AnyRef
                                push!(bytes, Opcode.REF_NULL)
                                push!(bytes, UInt8(AnyRef))
                            elseif local_wasm_type === I64
                                push!(bytes, Opcode.I64_CONST)
                                push!(bytes, 0x00)
                            elseif local_wasm_type === I32
                                push!(bytes, Opcode.I32_CONST)
                                push!(bytes, 0x00)
                            elseif local_wasm_type === F64
                                push!(bytes, Opcode.F64_CONST)
                                append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                            elseif local_wasm_type === F32
                                push!(bytes, Opcode.F32_CONST)
                                append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00])
                            else
                                push!(bytes, Opcode.I32_CONST)
                                push!(bytes, 0x00)
                            end
                            push!(bytes, Opcode.LOCAL_SET)
                            append!(bytes, encode_leb128_unsigned(local_idx))
                        end
                        ssa_type_mismatch = true  # Prevent double local_set
                    end
                    is_orphaned_multi_value = true
                end
            end
        end

        # Fix for statements with SSA locals that produce multi-value bytecode.
        # When stmt_bytes starts with a "memoryref pair" (local_get X, local_get Y)
        # followed by the SAME pair + an operation, the leading pair is orphaned.
        # Strip the leading orphaned local_gets.
        if !ssa_type_mismatch && !is_orphaned_multi_value && haskey(ctx.ssa_locals, idx) && length(stmt_bytes) >= 8
            # Check if bytes start with local_get X, local_get Y pattern
            if stmt_bytes[1] == 0x20
                # Parse first local_get
                _fg_idx1 = 0; _fg_shift = 0; _fg_end1 = 0
                for _bi in 2:length(stmt_bytes)
                    b = stmt_bytes[_bi]
                    _fg_idx1 |= (Int(b & 0x7f) << _fg_shift)
                    _fg_shift += 7
                    if (b & 0x80) == 0; _fg_end1 = _bi; break; end
                end
                if _fg_end1 > 0 && _fg_end1 < length(stmt_bytes) && stmt_bytes[_fg_end1 + 1] == 0x20
                    # Parse second local_get
                    _fg_idx2 = 0; _fg_shift = 0; _fg_end2 = 0
                    for _bi in (_fg_end1 + 2):length(stmt_bytes)
                        b = stmt_bytes[_bi]
                        _fg_idx2 |= (Int(b & 0x7f) << _fg_shift)
                        _fg_shift += 7
                        if (b & 0x80) == 0; _fg_end2 = _bi; break; end
                    end
                    pair_len = _fg_end2  # Length of the leading pair [get X, get Y]
                    if _fg_end2 > 0 && pair_len < length(stmt_bytes)
                        # Check if the SAME pair appears again after the first pair
                        remaining = @view stmt_bytes[pair_len+1:end]
                        if length(remaining) > pair_len
                            prefix = @view stmt_bytes[1:pair_len]
                            next_prefix = @view remaining[1:pair_len]
                            if prefix == next_prefix
                                # Leading pair is duplicated — strip it (it would be orphaned)
                                stmt_bytes = stmt_bytes[pair_len+1:end]
                            end
                        end
                    end
                end
            end
        end

        if !ssa_type_mismatch && !is_orphaned_multi_value
            append!(bytes, stmt_bytes)
        end

        # If the statement type is Union{} (bottom/never returns), emit unreachable
        # This handles calls to error/throw functions that have void return type in wasm
        # The unreachable instruction is polymorphic and satisfies any type expectation
        stmt_type_check = get(ctx.ssa_types, idx, Any)
        if stmt_type_check === Union{} && !isempty(stmt_bytes) &&
           !(length(stmt_bytes) >= 1 && stmt_bytes[end] == Opcode.UNREACHABLE)
            push!(bytes, Opcode.UNREACHABLE)
        end

        # If this SSA value needs a local, store it (and remove from stack)
        if haskey(ctx.ssa_locals, idx) && !ssa_type_mismatch
            stmt_type = get(ctx.ssa_types, idx, Any)
            is_unreachable_type = stmt_type === Union{}
            # PURE-6005: The bytecode check for DROP+UNREACHABLE (0x1a 0x00) can false-positive
            # on struct_get operands: struct_get type_26 field_0 = [0xfb 0x02 0x1a 0x00]
            # where type_idx=26 (0x1a=DROP) and field_idx=0 (0x00=UNREACHABLE).
            # Guard: also require that no GC_PREFIX (0xfb) appears in the last 4 bytes,
            # since real DROP+UNREACHABLE never follows a GC instruction's operands.
            _has_gc_in_tail = false
            if length(stmt_bytes) >= 3
                for _tbi in max(1, length(stmt_bytes)-3):(length(stmt_bytes)-2)
                    if stmt_bytes[_tbi] == Opcode.GC_PREFIX
                        _has_gc_in_tail = true
                        break
                    end
                end
            end
            is_unreachable_bytecode = (length(stmt_bytes) >= 2 &&
                                       stmt_bytes[end] == Opcode.UNREACHABLE &&
                                       stmt_bytes[end-1] == Opcode.DROP &&
                                       !_has_gc_in_tail) ||
                                      _stmt_ends_unreachable  # PURE-908: catch stub UNREACHABLE
            is_unreachable = is_unreachable_type || is_unreachable_bytecode
            should_store = (!isempty(stmt_bytes) || is_passthrough_statement(stmt, ctx)) && !is_unreachable
            if should_store
                local_idx = ctx.ssa_locals[idx]
                local_array_idx = local_idx - ctx.n_params + 1
                local_type = local_array_idx >= 1 && local_array_idx <= length(ctx.locals) ? ctx.locals[local_array_idx] : nothing


                # PURE-036bg: Check if value type matches local type
                # When multiple SSAs share a local but have incompatible types (e.g., in dead code),
                # DROP the value and emit a type-safe default instead of causing validation error.
                # PURE-4151: If extern_convert_any was already appended above (line ~15272),
                # the stack type is now ExternRef regardless of the original value_wasm_type.
                value_wasm_type = needs_extern_convert_any ? ExternRef : get_concrete_wasm_type(stmt_type, ctx.mod, ctx.type_registry)
                if local_type !== nothing && !wasm_types_compatible(local_type, value_wasm_type)
                    # PURE-908: externref↔anyref conversion instead of drop+default
                    if value_wasm_type === ExternRef && local_type === AnyRef
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.ANY_CONVERT_EXTERN)
                    elseif value_wasm_type === AnyRef && local_type === ExternRef
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                    else
                    # Type mismatch: drop the value and emit type-safe default
                    push!(bytes, Opcode.DROP)
                    if local_type isa ConcreteRef
                        push!(bytes, Opcode.REF_NULL)
                        append!(bytes, encode_leb128_signed(Int64(local_type.type_idx)))
                    elseif local_type === StructRef
                        push!(bytes, Opcode.REF_NULL, UInt8(StructRef))
                    elseif local_type === ArrayRef
                        push!(bytes, Opcode.REF_NULL, UInt8(ArrayRef))
                    elseif local_type === ExternRef
                        push!(bytes, Opcode.REF_NULL, UInt8(ExternRef))
                    elseif local_type === AnyRef
                        push!(bytes, Opcode.REF_NULL, UInt8(AnyRef))
                    elseif local_type === I64
                        push!(bytes, Opcode.I64_CONST, 0x00)
                    elseif local_type === I32
                        push!(bytes, Opcode.I32_CONST, 0x00)
                    elseif local_type === F64
                        push!(bytes, Opcode.F64_CONST)
                        append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                    elseif local_type === F32
                        push!(bytes, Opcode.F32_CONST)
                        append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00])
                    else
                        push!(bytes, Opcode.I32_CONST, 0x00)
                    end
                    end  # close else from PURE-908 externref↔anyref check
                end
                # PURE-6024: If this is a slot assignment, TEE to slot local first
                # (leaves value on stack for the SSA local.set below)
                if _slot_assign_id > 0 && haskey(ctx.slot_locals, _slot_assign_id)
                    push!(bytes, Opcode.LOCAL_TEE)
                    append!(bytes, encode_leb128_unsigned(ctx.slot_locals[_slot_assign_id]))
                end
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(local_idx))
            end
        end
    end

    # PURE-6024: If this is a slot assignment but there's NO SSA local to store to,
    # the value is still on the stack — store it to the slot local directly.
    if _slot_assign_id > 0 && haskey(ctx.slot_locals, _slot_assign_id) && !haskey(ctx.ssa_locals, idx)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(ctx.slot_locals[_slot_assign_id]))
    end

    return bytes
end

"""
Compile a struct construction expression (%new).
"""
function compile_new(expr::Expr, idx::Int, ctx::CompilationContext)::Vector{UInt8}
    bytes = UInt8[]

    # expr.args[1] is the type, rest are field values
    struct_type_ref = expr.args[1]
    field_values = expr.args[2:end]




    # Resolve the struct type if it's a GlobalRef, DataType, or SSAValue
    struct_type = if struct_type_ref isa GlobalRef
        getfield(struct_type_ref.mod, struct_type_ref.name)
    elseif struct_type_ref isa DataType
        struct_type_ref
    elseif struct_type_ref isa Core.SSAValue
        # PURE-801: Handle Core.apply_type results (e.g., NamedTuple from keyword args)
        # ssavaluetypes[ssa.id] gives Type{ConcreteType} — extract the parameter
        ssa_type = ctx.code_info.ssavaluetypes[struct_type_ref.id]
        if ssa_type isa DataType && ssa_type <: Type && length(ssa_type.parameters) >= 1
            ssa_type.parameters[1]
        else
            @warn "Stubbing :new with dynamic SSAValue type: $struct_type_ref ($ssa_type)"
            push!(bytes, Opcode.UNREACHABLE)
            ctx.last_stmt_was_stub = true  # PURE-908
            return bytes
        end
    else
        error("Unknown struct type reference: $struct_type_ref")
    end

    # Special case: Dict{K,V} construction
    # Dict starts with empty Memory arrays (length 0), but our inline setindex!/getindex
    # use linear scan and need initial capacity. Replace empty arrays with capacity-16 arrays.
    # NOTE: Only match concrete Dict types, not AbstractDict (Base.Pairs <: AbstractDict but has 2 fields)
    if struct_type <: Dict
        K = keytype(struct_type)
        V = valtype(struct_type)

        if !haskey(ctx.type_registry.structs, struct_type)
            register_struct_type!(ctx.mod, ctx.type_registry, struct_type)
        end
        dict_info = ctx.type_registry.structs[struct_type]

        slots_arr_type = get_array_type!(ctx.mod, ctx.type_registry, UInt8)
        keys_arr_type = get_array_type!(ctx.mod, ctx.type_registry, K)
        vals_arr_type = get_array_type!(ctx.mod, ctx.type_registry, V)

        # Initial capacity of 16
        initial_cap = Int32(16)

        # field 0: slots - array of UInt8, initialized to 0 (empty)
        push!(bytes, Opcode.I32_CONST)
        append!(bytes, encode_leb128_signed(initial_cap))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
        append!(bytes, encode_leb128_unsigned(slots_arr_type))

        # field 1: keys - array of K, default initialized
        push!(bytes, Opcode.I32_CONST)
        append!(bytes, encode_leb128_signed(initial_cap))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
        append!(bytes, encode_leb128_unsigned(keys_arr_type))

        # field 2: vals - array of V, default initialized
        push!(bytes, Opcode.I32_CONST)
        append!(bytes, encode_leb128_signed(initial_cap))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
        append!(bytes, encode_leb128_unsigned(vals_arr_type))

        # field 3: ndel = 0 (i64)
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(Int64(0)))

        # field 4: count = 0 (i64)
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(Int64(0)))

        # field 5: age = 0 (u64, stored as i64)
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(Int64(0)))

        # field 6: idxfloor = 1 (i64)
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(Int64(1)))

        # field 7: maxprobe = 0 (i64)
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(Int64(0)))

        # struct.new
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_NEW)
        append!(bytes, encode_leb128_unsigned(dict_info.wasm_type_idx))

        return bytes
    end

    # Special case: Vector{T} construction
    # Vector is now a struct with (ref, size) fields to support setfield!(v, :size, ...)
    # The %new(Vector{T}, memref, size_tuple) creates a struct with both fields
    if struct_type <: Array && length(field_values) >= 1
        # field_values[1] is the MemoryRef (which is actually our array)
        # field_values[2] is the size tuple (Tuple{Int64})
        # Register the vector type if not already done
        if !haskey(ctx.type_registry.structs, struct_type)
            register_vector_type!(ctx.mod, ctx.type_registry, struct_type)
        end
        vec_info = ctx.type_registry.structs[struct_type]

        # Compile field 0: the array reference (from MemoryRef)
        # Safety: if the SSA local is numeric (i64/i32) but the Vector struct expects a ref,
        # emit ref.null of the correct array type instead of the wrong-typed local.get.
        # This happens with non-Array AbstractVector types (UnitRange, StepRange) whose
        # fields are i64 but get registered with Vector's ref-based layout.
        # PURE-325: Check if field0 is a multi-arg memoryrefnew that produces [array_ref, i32_index].
        # Vector only needs the array_ref — drop the extra i32 index.
        is_multi_arg_memref = false
        if field_values[1] isa Core.SSAValue
            src_stmt = ctx.code_info.code[field_values[1].id]
            if src_stmt isa Expr && src_stmt.head === :call
                src_func = src_stmt.args[1]
                is_multi_arg_memref = (src_func isa GlobalRef &&
                                      (src_func.mod === Core || src_func.mod === Base) &&
                                      src_func.name === :memoryrefnew &&
                                      length(src_stmt.args) >= 4)
            end
        end
        field0_bytes = compile_value(field_values[1], ctx)
        if is_multi_arg_memref
            # Multi-arg memoryrefnew pushed [array_ref, i32_index] — drop the i32 index
            push!(field0_bytes, Opcode.DROP)
        end
        if length(field0_bytes) >= 2 && field0_bytes[1] == 0x20  # LOCAL_GET = 0x20
            src_idx = 0; shift = 0
            for bi in 2:length(field0_bytes)
                b = field0_bytes[bi]
                src_idx |= (Int(b & 0x7f) << shift)
                shift += 7
                (b & 0x80) == 0 && break
            end
            arr_idx = src_idx - ctx.n_params + 1
            if arr_idx >= 1 && arr_idx <= length(ctx.locals)
                src_type = ctx.locals[arr_idx]
                if src_type === I64 || src_type === I32
                    # PURE-325: The local has numeric type but Vector field 0 needs an array ref.
                    # Before falling back to ref.null, check if the source SSA is a memoryrefnew
                    # or memorynew result — if so, recompile the source to get the actual array ref.
                    recompiled = false
                    if field_values[1] isa Core.SSAValue
                        src_stmt_f0 = ctx.code_info.code[field_values[1].id]
                        if src_stmt_f0 isa Expr && src_stmt_f0.head === :call
                            sf0 = src_stmt_f0.args[1]
                            is_memref = sf0 isa GlobalRef &&
                                        (sf0.mod === Core || sf0.mod === Base) &&
                                        sf0.name in (:memoryrefnew, :memoryref, :memorynew)
                            if is_memref
                                # Recompile the source statement to get the actual array ref
                                field0_bytes = compile_call(src_stmt_f0, field_values[1].id, ctx)
                                recompiled = true
                            end
                        end
                        # Also check if source is a PiNode wrapping a memoryrefnew
                        if !recompiled && src_stmt_f0 isa Core.PiNode
                            append!(bytes, compile_value(src_stmt_f0.val, ctx))
                            field0_bytes = UInt8[]
                            recompiled = true
                        end
                    end
                    if !recompiled
                        # Non-Array AbstractVector (UnitRange, StepRange) — use ref.null
                        data_array_idx = get_array_type!(ctx.mod, ctx.type_registry, eltype(struct_type))
                        push!(bytes, Opcode.REF_NULL)
                        append!(bytes, encode_leb128_signed(Int64(data_array_idx)))
                        field0_bytes = UInt8[]  # Don't append original
                    end
                end
            end
        end
        append!(bytes, field0_bytes)

        # Compile field 1: the size tuple
        if length(field_values) >= 2
            field1_bytes = compile_value(field_values[2], ctx)
            if length(field1_bytes) >= 2 && field1_bytes[1] == Opcode.LOCAL_GET
                src_idx = 0; shift = 0
                for bi in 2:length(field1_bytes)
                    b = field1_bytes[bi]
                    src_idx |= (Int(b & 0x7f) << shift)
                    shift += 7
                    (b & 0x80) == 0 && break
                end
                arr_idx = src_idx - ctx.n_params + 1
                if arr_idx >= 1 && arr_idx <= length(ctx.locals)
                    src_type = ctx.locals[arr_idx]
                    if src_type === I64 || src_type === I32
                        # Emit ref.null for the size tuple type instead
                        size_tuple_type_inner = Tuple{Int64}
                        if !haskey(ctx.type_registry.structs, size_tuple_type_inner)
                            register_tuple_type!(ctx.mod, ctx.type_registry, size_tuple_type_inner)
                        end
                        size_info_inner = ctx.type_registry.structs[size_tuple_type_inner]
                        push!(bytes, Opcode.REF_NULL)
                        append!(bytes, encode_leb128_signed(Int64(size_info_inner.wasm_type_idx)))
                        field1_bytes = UInt8[]
                    end
                end
            end
            append!(bytes, field1_bytes)
        else
            # No size provided - get array length and create tuple
            # Push array ref again for array.len
            append!(bytes, compile_value(field_values[1], ctx))
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ARRAY_LEN)
            push!(bytes, Opcode.I64_EXTEND_I32_S)
            # Create Tuple{Int64} struct
            size_tuple_type = Tuple{Int64}
            if !haskey(ctx.type_registry.structs, size_tuple_type)
                register_tuple_type!(ctx.mod, ctx.type_registry, size_tuple_type)
            end
            size_info = ctx.type_registry.structs[size_tuple_type]
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_NEW)
            append!(bytes, encode_leb128_unsigned(size_info.wasm_type_idx))
        end

        # Create the Vector struct
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_NEW)
        append!(bytes, encode_leb128_unsigned(vec_info.wasm_type_idx))
        return bytes
    end

    # PURE-049: MemoryRef/Memory construction — in WasmGC these are array refs, not structs.
    # :new(MemoryRef{T}, mem, ptr_or_offset) → just pass through the mem (array ref).
    # :new(Memory{T}, ...) → emit ref.null of the array type (Memory is backing storage).
    if struct_type isa DataType && struct_type.name.name in (:MemoryRef, :GenericMemoryRef)
        # MemoryRef{T} — field_values[1] is the Memory (= our array ref), field_values[2] is offset
        if length(field_values) >= 1
            append!(bytes, compile_value(field_values[1], ctx))
        else
            elem_type = struct_type.name.name === :GenericMemoryRef ? struct_type.parameters[2] : struct_type.parameters[1]
            array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
            push!(bytes, Opcode.REF_NULL)
            append!(bytes, encode_leb128_signed(Int64(array_type_idx)))
        end
        return bytes
    end
    if struct_type isa DataType && struct_type.name.name in (:Memory, :GenericMemory)
        # Memory{T} — emit ref.null of the array type (we can't construct raw memory in Wasm)
        elem_type = eltype(struct_type)
        array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
        push!(bytes, Opcode.REF_NULL)
        append!(bytes, encode_leb128_signed(Int64(array_type_idx)))
        return bytes
    end

    # PURE-325: Error constructors — these are always followed by throw() which is unreachable.
    # Emit unreachable instead of trying to compile the struct construction, because
    # error types like ArgumentError have AbstractString fields that can receive LazyString
    # (a struct ref) where ArrayRef is expected, causing type mismatches.
    if struct_type <: Exception
        push!(bytes, Opcode.UNREACHABLE)
        return bytes
    end

    # Get the registered struct info
    if !haskey(ctx.type_registry.structs, struct_type)
        # Register it now - use appropriate registration for closures vs regular structs
        if is_closure_type(struct_type)
            register_closure_type!(ctx.mod, ctx.type_registry, struct_type)
        else
            register_struct_type!(ctx.mod, ctx.type_registry, struct_type)
        end
    end

    info = ctx.type_registry.structs[struct_type]

    # Push field values in order, handling Union field types
    for (i, val) in enumerate(field_values)
        field_type = info.field_types[i]

        # Check if this field is a Union type that needs wrapping
        if field_type isa Union && needs_tagged_union(field_type)
            # Get the value's actual type
            val_type = if val isa Core.SSAValue
                get(ctx.ssa_types, val.id, Any)
            elseif val isa Core.Argument
                # Core.Argument(n) is an IR node for the nth argument; look up its declared type.
                # PURE-6025: For non-closures, Core.Argument(1) is #self#, so subtract 1.
                local arg_idx_fix = ctx.is_compiled_closure ? val.n : val.n - 1
                (arg_idx_fix >= 1 && arg_idx_fix <= length(ctx.arg_types)) ? ctx.arg_types[arg_idx_fix] : Any
            elseif val isa GlobalRef
                actual_val = try getfield(val.mod, val.name) catch; nothing end
                typeof(actual_val)
            else
                typeof(val)
            end

            # Compile the value first
            append!(bytes, compile_value(val, ctx))

            # If val_type is already a union (tagged union struct on stack), don't re-wrap
            if !(val_type isa Union && val_type <: field_type)
                append!(bytes, emit_wrap_union_value(ctx, val_type, field_type))
            end
        elseif field_type isa Union
            # Simple nullable union (Union{Nothing, T})
            inner_type = get_nullable_inner_type(field_type)

            # Get the value's actual type
            val_type = if val isa Core.SSAValue
                get(ctx.ssa_types, val.id, Any)
            elseif val isa GlobalRef
                actual_val = try getfield(val.mod, val.name) catch; nothing end
                typeof(actual_val)
            else
                typeof(val)
            end

            # Check if this value is nothing - either literally or via an SSA with Nothing type
            # SSA values with Nothing type (e.g., from GlobalRef to nothing) produce no bytecode,
            # so we need to emit ref.null directly instead of trying to load a non-existent value
            is_literal_nothing = val === nothing || (val isa GlobalRef && val.name === :nothing)
            is_nothing_type_ssa = val isa Core.SSAValue && val_type === Nothing
            should_emit_null = is_literal_nothing || is_nothing_type_ssa

            if should_emit_null
                # PURE-6024: Check actual Wasm field type first. For nullable
                # primitives (Union{Nothing, Bool/Int32/etc}), the Wasm field
                # is i32/i64 — emit zero constant, NOT ref.null.
                _null_field_wasm = nothing
                _null_struct_def = ctx.mod.types[info.wasm_type_idx + 1]
                if _null_struct_def isa StructType && i <= length(_null_struct_def.fields)
                    _null_field_wasm = _null_struct_def.fields[i].valtype
                end
                if _null_field_wasm !== nothing && (_null_field_wasm === I32 || _null_field_wasm === I64 || _null_field_wasm === F32 || _null_field_wasm === F64)
                    # Numeric field — emit zero constant for nothing
                    if _null_field_wasm === I32
                        push!(bytes, Opcode.I32_CONST)
                        push!(bytes, 0x00)
                    elseif _null_field_wasm === I64
                        push!(bytes, Opcode.I64_CONST)
                        push!(bytes, 0x00)
                    elseif _null_field_wasm === F32
                        push!(bytes, Opcode.F32_CONST)
                        append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00])
                    elseif _null_field_wasm === F64
                        push!(bytes, Opcode.F64_CONST)
                        append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                    end
                # Nothing value (literal or SSA with Nothing type) - emit ref.null
                elseif inner_type !== nothing && (inner_type === String || inner_type === Symbol)
                    # Nullable string/symbol — use string array type
                    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
                    push!(bytes, Opcode.REF_NULL)
                    append!(bytes, encode_leb128_signed(Int64(str_type_idx)))
                elseif inner_type !== nothing && isconcretetype(inner_type) && isstructtype(inner_type)
                    # Nullable struct ref - emit null reference
                    if haskey(ctx.type_registry.structs, inner_type)
                        inner_info = ctx.type_registry.structs[inner_type]
                        push!(bytes, Opcode.REF_NULL)
                        append!(bytes, encode_leb128_signed(Int64(inner_info.wasm_type_idx)))
                    else
                        # Use generic null
                        push!(bytes, Opcode.REF_NULL)
                        push!(bytes, UInt8(StructRef))
                    end
                elseif inner_type !== nothing && inner_type <: AbstractVector
                    # Nullable array ref
                    elem_type = eltype(inner_type)
                    arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
                    push!(bytes, Opcode.REF_NULL)
                    append!(bytes, encode_leb128_signed(Int64(arr_type_idx)))
                else
                    # Generic nullable - use structref null
                    push!(bytes, Opcode.REF_NULL)
                    push!(bytes, UInt8(StructRef))
                end
            else
                # Non-null value - compile with type safety check
                val_bytes = compile_value(val, ctx)
                # Safety: if compile_value produced a numeric local.get but the field
                # expects a ref type (Union{Nothing, String} field = ref null array),
                # emit ref.null of the correct type instead.
                is_numeric_for_ref = false
                if inner_type !== nothing && length(val_bytes) >= 2 && val_bytes[1] == 0x20
                    src_idx = 0; shift = 0; leb_end = 0
                    for bi in 2:length(val_bytes)
                        b = val_bytes[bi]
                        src_idx |= (Int(b & 0x7f) << shift)
                        shift += 7
                        if (b & 0x80) == 0
                            leb_end = bi
                            break
                        end
                    end
                    if leb_end == length(val_bytes)  # Pure local.get
                        src_type = nothing
                        arr_idx_check = src_idx - ctx.n_params + 1
                        if arr_idx_check >= 1 && arr_idx_check <= length(ctx.locals)
                            src_type = ctx.locals[arr_idx_check]
                        elseif src_idx < ctx.n_params
                            param_idx = src_idx + 1
                            if param_idx >= 1 && param_idx <= length(ctx.arg_types)
                                src_type = get_concrete_wasm_type(ctx.arg_types[param_idx], ctx.mod, ctx.type_registry)
                            end
                        end
                        if src_type !== nothing && (src_type === I32 || src_type === I64 || src_type === F32 || src_type === F64)
                            # Numeric local used for ref-typed Union field — emit ref.null
                            if inner_type === String || inner_type === Symbol
                                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
                                push!(bytes, Opcode.REF_NULL)
                                append!(bytes, encode_leb128_signed(Int64(str_type_idx)))
                            elseif inner_type <: AbstractVector
                                elem_type = eltype(inner_type)
                                arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
                                push!(bytes, Opcode.REF_NULL)
                                append!(bytes, encode_leb128_signed(Int64(arr_type_idx)))
                            elseif haskey(ctx.type_registry.structs, inner_type)
                                inner_info = ctx.type_registry.structs[inner_type]
                                push!(bytes, Opcode.REF_NULL)
                                append!(bytes, encode_leb128_signed(Int64(inner_info.wasm_type_idx)))
                            else
                                push!(bytes, Opcode.REF_NULL)
                                push!(bytes, UInt8(StructRef))
                            end
                            is_numeric_for_ref = true
                        end
                    end
                end
                if !is_numeric_for_ref
                    append!(bytes, val_bytes)
                end
            end
        elseif field_type === Any
            # Any field maps to externref in WasmGC
            # We need to convert internal refs to externref using extern.convert_any
            # PURE-044: Check for nothing values FIRST before compile_value
            # compile_value(nothing) returns i32.const 0, which can't be extern.convert_any'd
            is_nothing_val = val === nothing ||
                            (val isa GlobalRef && val.name === :nothing) ||
                            (val isa Core.SSAValue && 1 <= val.id <= length(ctx.code_info.code) && begin
                                ssa_stmt_check = ctx.code_info.code[val.id]
                                (ssa_stmt_check isa GlobalRef && ssa_stmt_check.name === :nothing) ||
                                (ssa_stmt_check isa Core.PiNode && ssa_stmt_check.typ === Nothing)
                            end)
            if is_nothing_val
                # Nothing value for Any field → emit ref.null extern
                push!(bytes, Opcode.REF_NULL)
                push!(bytes, UInt8(ExternRef))
                continue  # Skip to next field
            end

            val_bytes = compile_value(val, ctx)
            # Safety: if compile_value produced local.get of a numeric local (I32/I64),
            # extern_convert_any will fail because it requires anyref input.
            # Emit ref.null extern instead.
            is_numeric_local = false
            # PURE-044/PURE-325: Check for i32.const/i64.const, but skip if GC ops present
            ends_with_ref_producing_gc = has_ref_producing_gc_op(val_bytes)
            if length(val_bytes) >= 1 && (val_bytes[1] == 0x41 || val_bytes[1] == 0x42) && !ends_with_ref_producing_gc  # I32_CONST or I64_CONST
                is_numeric_local = true
            elseif length(val_bytes) >= 2 && val_bytes[1] == 0x20
                # Decode LEB128 source local index
                src_idx = 0; shift = 0; leb_end = 0
                for bi in 2:length(val_bytes)
                    b = val_bytes[bi]
                    src_idx |= (Int(b & 0x7f) << shift)
                    shift += 7
                    if (b & 0x80) == 0
                        leb_end = bi
                        break
                    end
                end
                if leb_end == length(val_bytes)  # Pure local.get (no trailing instructions)
                    if src_idx < ctx.n_params
                        # PURE-906: Check if PARAMETER is numeric (i64/i32/f32/f64).
                        # Parameters can't be extern_convert_any'd either.
                        if src_idx + 1 <= length(ctx.arg_types)
                            param_wasm = julia_to_wasm_type(ctx.arg_types[src_idx + 1])
                            if param_wasm === I32 || param_wasm === I64 || param_wasm === F32 || param_wasm === F64
                                is_numeric_local = true
                            end
                        end
                    else
                        arr_idx = src_idx - ctx.n_params + 1
                        if arr_idx >= 1 && arr_idx <= length(ctx.locals)
                            src_type = ctx.locals[arr_idx]
                            if src_type === I32 || src_type === I64 || src_type === F32 || src_type === F64
                                is_numeric_local = true
                            end
                        end
                    end
                end
            end
            if is_numeric_local
                # Numeric local can't be extern_convert_any'd — emit ref.null extern
                push!(bytes, Opcode.REF_NULL)
                push!(bytes, UInt8(ExternRef))
            else
                append!(bytes, val_bytes)
                # Convert internal ref to externref — but skip if already externref
                # PURE-038c: Check if source is already externref local
                is_already_externref = false
                if length(val_bytes) >= 2 && val_bytes[1] == 0x20
                    src_idx2 = 0; shift2 = 0; leb_end2 = 0
                    for bi in 2:length(val_bytes)
                        b = val_bytes[bi]
                        src_idx2 |= (Int(b & 0x7f) << shift2)
                        shift2 += 7
                        if (b & 0x80) == 0
                            leb_end2 = bi
                            break
                        end
                    end
                    if leb_end2 == length(val_bytes)
                        if src_idx2 < ctx.n_params
                            if src_idx2 + 1 <= length(ctx.arg_types)
                                src_t = ctx.arg_types[src_idx2 + 1]
                                # PURE-049: arg_types contains Julia types, not WasmValTypes.
                                # Convert to wasm type before comparing (Any -> ExternRef).
                                is_already_externref = (julia_to_wasm_type(src_t) === ExternRef)
                            end
                        else
                            arr_idx2 = src_idx2 - ctx.n_params + 1
                            if arr_idx2 >= 1 && arr_idx2 <= length(ctx.locals)
                                src_t = ctx.locals[arr_idx2]
                                is_already_externref = (src_t === ExternRef)
                            end
                        end
                    end
                end
                if !is_already_externref
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                end
            end
        else
            # Regular field - compile value directly
            # Safety: if compile_value produces a local.get of a numeric local (i64/i32)
            # but the field expects a ref type, emit ref.null instead.
            # This happens when phi/PiNode locals are allocated as i64 (due to Union/Any
            # type inference) but the struct field requires a concrete ref.
            field_bytes = compile_value(val, ctx)
            # Look up the actual Wasm field type from the module's type definition
            actual_field_wasm = nothing
            struct_type_def = ctx.mod.types[info.wasm_type_idx + 1]
            if struct_type_def isa StructType && i <= length(struct_type_def.fields)
                actual_field_wasm = struct_type_def.fields[i].valtype
            end
            # Safety: if field_bytes is empty (SSA without local, not re-compilable)
            # and the field expects a ref type, emit ref.null of the correct type.
            if isempty(field_bytes) && actual_field_wasm !== nothing &&
               (actual_field_wasm isa ConcreteRef || actual_field_wasm === StructRef ||
                actual_field_wasm === ArrayRef || actual_field_wasm === AnyRef || actual_field_wasm === ExternRef)
                if actual_field_wasm isa ConcreteRef
                    push!(bytes, Opcode.REF_NULL)
                    append!(bytes, encode_leb128_signed(Int64(actual_field_wasm.type_idx)))
                elseif actual_field_wasm === ArrayRef
                    push!(bytes, Opcode.REF_NULL)
                    push!(bytes, UInt8(ArrayRef))
                elseif actual_field_wasm === ExternRef
                    push!(bytes, Opcode.REF_NULL)
                    push!(bytes, UInt8(ExternRef))
                else
                    push!(bytes, Opcode.REF_NULL)
                    push!(bytes, UInt8(StructRef))
                end
                field_bytes = UInt8[]
            elseif isempty(field_bytes) && actual_field_wasm !== nothing &&
                   (actual_field_wasm === I32 || actual_field_wasm === I64 ||
                    actual_field_wasm === F32 || actual_field_wasm === F64)
                # Empty bytes for numeric field — emit zero constant
                if actual_field_wasm === I32
                    push!(bytes, Opcode.I32_CONST)
                    push!(bytes, 0x00)
                elseif actual_field_wasm === I64
                    push!(bytes, Opcode.I64_CONST)
                    push!(bytes, 0x00)
                elseif actual_field_wasm === F32
                    push!(bytes, Opcode.F32_CONST)
                    append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00])
                elseif actual_field_wasm === F64
                    push!(bytes, Opcode.F64_CONST)
                    append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                end
                field_bytes = UInt8[]
            end
            if actual_field_wasm !== nothing && (actual_field_wasm isa ConcreteRef || actual_field_wasm === StructRef || actual_field_wasm === ArrayRef || actual_field_wasm === AnyRef || actual_field_wasm === ExternRef) && length(field_bytes) >= 2 && field_bytes[1] == 0x20
                # Decode source local index from LEB128
                src_idx = 0; shift = 0
                for bi in 2:length(field_bytes)
                    b = field_bytes[bi]
                    src_idx |= (Int(b & 0x7f) << shift)
                    shift += 7
                    (b & 0x80) == 0 && break
                end
                # Determine source type: either from ctx.locals (SSA) or from params
                src_type = nothing
                arr_idx = src_idx - ctx.n_params + 1
                if arr_idx >= 1 && arr_idx <= length(ctx.locals)
                    src_type = ctx.locals[arr_idx]
                elseif src_idx < ctx.n_params
                    # Function parameter — get type from arg_types
                    param_idx = src_idx + 1  # 0-based to 1-based
                    if param_idx >= 1 && param_idx <= length(ctx.arg_types)
                        src_type = get_concrete_wasm_type(ctx.arg_types[param_idx], ctx.mod, ctx.type_registry)
                    end
                end
                if src_type !== nothing && (src_type === I64 || src_type === I32 || src_type === F32 || src_type === F64)
                    # Source local is numeric but field expects ref — emit ref.null
                    # Use the ACTUAL field type from the struct definition
                    if actual_field_wasm isa ConcreteRef
                        push!(bytes, Opcode.REF_NULL)
                        append!(bytes, encode_leb128_signed(Int64(actual_field_wasm.type_idx)))
                    elseif actual_field_wasm === ArrayRef
                        push!(bytes, Opcode.REF_NULL)
                        push!(bytes, UInt8(ArrayRef))
                    elseif actual_field_wasm === ExternRef
                        # PURE-6024: Box numeric local → struct_new → extern_convert_any
                        # (was: emit_numeric_to_externref! with undefined vars stmt/val_wasm)
                        append!(bytes, field_bytes)
                        _box_t = get_numeric_box_type!(ctx.mod, ctx.type_registry, src_type)
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.STRUCT_NEW)
                        append!(bytes, encode_leb128_unsigned(_box_t))
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                    else
                        push!(bytes, Opcode.REF_NULL)
                        push!(bytes, UInt8(StructRef))
                    end
                    field_bytes = UInt8[]  # Don't append original
                elseif actual_field_wasm === ExternRef && src_type !== nothing && src_type !== ExternRef
                    # PURE-046: Source is a concrete ref but field expects externref
                    # (e.g., abstract type field like AbstractInterpreter registered as externref)
                    # Need to convert concrete ref to externref using extern.convert_any
                    append!(bytes, field_bytes)
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                    field_bytes = UInt8[]  # Already appended
                elseif actual_field_wasm === ExternRef && src_type !== nothing && src_type === ExternRef
                    # PURE-6025: Source IS already externref, field expects externref — no conversion needed.
                    # Must explicitly handle to prevent the catch-all below from emitting EXTERN_CONVERT_ANY
                    # which expects anyref input and would fail on externref.
                    append!(bytes, field_bytes)
                    field_bytes = UInt8[]  # Already appended — prevent catch-all
                end
            end
            # PURE-6025: Handle global.get sources (0x23) for externref field conversion.
            # Same pattern as local.get above but looks up source type from module globals.
            if actual_field_wasm === ExternRef && !isempty(field_bytes) && field_bytes[1] == 0x23
                # Decode global index from LEB128
                g_idx = 0; g_shift = 0
                for bi in 2:length(field_bytes)
                    b = field_bytes[bi]
                    g_idx |= (Int(b & 0x7f) << g_shift)
                    g_shift += 7
                    (b & 0x80) == 0 && break
                end
                if g_idx + 1 <= length(ctx.mod.globals)
                    g_type = ctx.mod.globals[g_idx + 1].valtype
                    if g_type !== ExternRef
                        # Source global is concrete ref but field expects externref
                        append!(bytes, field_bytes)
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                        field_bytes = UInt8[]
                    end
                end
            end
            # PURE-906: Check if field expects numeric but source is ref-typed (externref/anyref).
            # This happens when Julia's convert(Bool, x)::Any SSA is typed ExternRef
            # but the struct field is Bool (i32). Emit zero default for the numeric field.
            # PURE-6024: Also catch ref.null (0xD0) values for numeric fields.
            if actual_field_wasm !== nothing && (actual_field_wasm === I32 || actual_field_wasm === I64 || actual_field_wasm === F32 || actual_field_wasm === F64) && !isempty(field_bytes) && field_bytes[1] == 0xD0
                # ref.null used for numeric field — emit zero constant instead
                if actual_field_wasm === I32
                    push!(bytes, Opcode.I32_CONST)
                    push!(bytes, 0x00)
                elseif actual_field_wasm === I64
                    push!(bytes, Opcode.I64_CONST)
                    push!(bytes, 0x00)
                elseif actual_field_wasm === F32
                    push!(bytes, Opcode.F32_CONST)
                    append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00])
                elseif actual_field_wasm === F64
                    push!(bytes, Opcode.F64_CONST)
                    append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                end
                field_bytes = UInt8[]  # Don't append original ref.null
            elseif actual_field_wasm !== nothing && (actual_field_wasm === I32 || actual_field_wasm === I64 || actual_field_wasm === F32 || actual_field_wasm === F64) && !isempty(field_bytes) && length(field_bytes) >= 2 && field_bytes[1] == 0x20
                # Decode source local index
                src_idx_906 = 0; shift_906 = 0; leb_end_906 = 0
                for bi in 2:length(field_bytes)
                    b = field_bytes[bi]
                    src_idx_906 |= (Int(b & 0x7f) << shift_906)
                    shift_906 += 7
                    if (b & 0x80) == 0
                        leb_end_906 = bi
                        break
                    end
                end
                if leb_end_906 == length(field_bytes)  # Pure local.get
                    src_type_906 = nothing
                    arr_idx_906 = src_idx_906 - ctx.n_params + 1
                    if arr_idx_906 >= 1 && arr_idx_906 <= length(ctx.locals)
                        src_type_906 = ctx.locals[arr_idx_906]
                    elseif src_idx_906 < ctx.n_params
                        param_idx_906 = src_idx_906 + 1
                        if param_idx_906 >= 1 && param_idx_906 <= length(ctx.arg_types)
                            src_type_906 = get_concrete_wasm_type(ctx.arg_types[param_idx_906], ctx.mod, ctx.type_registry)
                        end
                    end
                    if src_type_906 !== nothing && (src_type_906 === ExternRef || src_type_906 === AnyRef || src_type_906 isa ConcreteRef || src_type_906 === StructRef)
                        # Source is ref-typed but field expects numeric — emit zero default
                        if actual_field_wasm === I32
                            push!(bytes, Opcode.I32_CONST)
                            push!(bytes, 0x00)
                        elseif actual_field_wasm === I64
                            push!(bytes, Opcode.I64_CONST)
                            push!(bytes, 0x00)
                        elseif actual_field_wasm === F32
                            push!(bytes, Opcode.F32_CONST)
                            append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00])
                        elseif actual_field_wasm === F64
                            push!(bytes, Opcode.F64_CONST)
                            append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                        end
                        field_bytes = UInt8[]  # Don't append original
                    end
                end
            end
            # PURE-6024: If the field expects externref but field_bytes is non-empty and
            # hasn't been handled above (not local.get, not ref.null), the compiled value
            # is likely a concrete ref (from struct_new, struct_get, call, etc.) that needs
            # extern_convert_any. This complements the local.get check at line ~16464.
            if actual_field_wasm === ExternRef && !isempty(field_bytes)
                last_is_extern_convert = length(field_bytes) >= 2 &&
                                         field_bytes[end-1] == Opcode.GC_PREFIX &&
                                         field_bytes[end] == Opcode.EXTERN_CONVERT_ANY
                first_is_ref_null_extern = length(field_bytes) >= 2 &&
                                           field_bytes[1] == Opcode.REF_NULL &&
                                           field_bytes[2] == UInt8(ExternRef)
                first_is_numeric = !isempty(field_bytes) &&
                                   (field_bytes[1] == Opcode.I32_CONST || field_bytes[1] == Opcode.I64_CONST ||
                                    field_bytes[1] == Opcode.F32_CONST || field_bytes[1] == Opcode.F64_CONST) &&
                                   !has_ref_producing_gc_op(field_bytes)
                if !last_is_extern_convert && !first_is_ref_null_extern && !first_is_numeric
                    append!(bytes, field_bytes)
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                    field_bytes = UInt8[]  # Already appended
                elseif first_is_numeric
                    # Numeric value for externref field — emit ref.null extern
                    push!(bytes, Opcode.REF_NULL)
                    push!(bytes, UInt8(ExternRef))
                    field_bytes = UInt8[]  # Don't append original
                end
            end
            append!(bytes, field_bytes)
        end
    end

    # If field_values provides fewer values than the struct's actual Wasm field count,
    # emit default values for the missing fields. This happens when Julia's :new expression
    # constructs a struct with uninitialized fields (e.g., RefValue{NTuple{50, UInt8}}).
    struct_type_def = ctx.mod.types[info.wasm_type_idx + 1]
    if struct_type_def isa StructType
        n_provided = length(field_values)
        n_required = length(struct_type_def.fields)
        # DEBUG: trace ALL struct_new emissions with 2 externref fields
        if n_required == 2 && struct_type_def.fields[1].valtype === ExternRef && struct_type_def.fields[2].valtype === ExternRef
            println("DEBUG_STRUCT_NEW_2EXTERN: struct_type=$struct_type type_idx=$(info.wasm_type_idx) n_provided=$n_provided bytes_len=$(length(bytes)) idx=$idx")
            # Count how many ref_null extern (D0 6F) appear in the bytes
            n_ref_nulls = 0
            for bi in 1:(length(bytes)-1)
                if bytes[bi] == 0xD0 && bytes[bi+1] == 0x6F
                    n_ref_nulls += 1
                end
            end
            println("  ref_null_extern_count=$n_ref_nulls stacktrace=$(join(string.(stacktrace()[1:min(8, end)]), " <- "))")
        end
        for fi in (n_provided + 1):n_required
            missing_field_type = struct_type_def.fields[fi].valtype
            if missing_field_type isa ConcreteRef
                push!(bytes, Opcode.REF_NULL)
                append!(bytes, encode_leb128_signed(Int64(missing_field_type.type_idx)))
            elseif missing_field_type === StructRef
                push!(bytes, Opcode.REF_NULL)
                push!(bytes, UInt8(StructRef))
            elseif missing_field_type === ArrayRef
                push!(bytes, Opcode.REF_NULL)
                push!(bytes, UInt8(ArrayRef))
            elseif missing_field_type === ExternRef
                push!(bytes, Opcode.REF_NULL)
                push!(bytes, UInt8(ExternRef))
            elseif missing_field_type === AnyRef
                push!(bytes, Opcode.REF_NULL)
                push!(bytes, UInt8(AnyRef))
            elseif missing_field_type === I64
                push!(bytes, Opcode.I64_CONST)
                push!(bytes, 0x00)
            elseif missing_field_type === I32
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
            elseif missing_field_type === F64
                push!(bytes, Opcode.F64_CONST)
                append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            elseif missing_field_type === F32
                push!(bytes, Opcode.F32_CONST)
                append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00])
            else
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
            end
        end
    end

    # struct.new type_idx
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_NEW)
    append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))

    return bytes
end

"""
Compile a foreign call expression.
Handles specific patterns like jl_alloc_genericmemory for Vector allocation.
"""
function compile_foreigncall(expr::Expr, idx::Int, ctx::CompilationContext)::Vector{UInt8}
    bytes = UInt8[]

    # foreigncall format: Expr(:foreigncall, name, return_type, arg_types, nreq, calling_conv, args...)
    # For jl_alloc_genericmemory:
    #   args[1] = :(:jl_alloc_genericmemory)
    #   args[2] = return type (e.g., Ref{Memory{Int32}})
    #   args[7] = element type (e.g., Memory{Int32})
    #   args[8] = length

    if length(expr.args) >= 1
        name_arg = expr.args[1]
        name = if name_arg isa QuoteNode
            name_arg.value
        elseif name_arg isa Symbol
            name_arg
        else
            nothing
        end

        if name === :jl_alloc_genericmemory
            # Extract element type from return type
            # args[2] is like Ref{Memory{Int32}}
            # args[7] is Memory{Int32}
            ret_type = length(expr.args) >= 2 ? expr.args[2] : nothing

            # Get the element type from Memory{T}
            # Memory{T} is actually GenericMemory{:not_atomic, T, ...}
            # The memory type is at args[6] (not args[7])
            elem_type = Int32  # default
            if length(expr.args) >= 6
                mem_type = expr.args[6]
                if mem_type isa DataType && mem_type.name.name === :GenericMemory && length(mem_type.parameters) >= 2
                    # GenericMemory parameters: (atomicity, element_type, addrspace)
                    elem_type = mem_type.parameters[2]
                elseif mem_type isa DataType && mem_type.name.name === :Memory && length(mem_type.parameters) >= 1
                    elem_type = mem_type.parameters[1]
                elseif mem_type isa GlobalRef
                    resolved = try getfield(mem_type.mod, mem_type.name) catch; nothing end
                    if resolved isa DataType && resolved.name.name === :GenericMemory && length(resolved.parameters) >= 2
                        elem_type = resolved.parameters[2]
                    elseif resolved isa DataType && resolved.name.name === :Memory && length(resolved.parameters) >= 1
                        elem_type = resolved.parameters[1]
                    end
                end
            end

            # Get the length argument (at args[7] or args[8])
            len_arg = length(expr.args) >= 7 ? expr.args[7] : nothing

            # Get or create array type for this element type
            arr_type_idx = if elem_type <: AbstractVector || (elem_type isa DataType && isstructtype(elem_type))
                # For struct element types, register the element struct first
                if isconcretetype(elem_type) && isstructtype(elem_type) && !haskey(ctx.type_registry.structs, elem_type)
                    register_struct_type!(ctx.mod, ctx.type_registry, elem_type)
                end
                get_array_type!(ctx.mod, ctx.type_registry, elem_type)
            elseif elem_type === String
                get_string_array_type!(ctx.mod, ctx.type_registry)
            else
                get_array_type!(ctx.mod, ctx.type_registry, elem_type)
            end

            # Compile length argument
            if len_arg !== nothing
                append!(bytes, compile_value(len_arg, ctx))
                len_type = infer_value_type(len_arg, ctx)
                if len_type === Int64 || len_type === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end
            else
                # Default length of 0
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
            end

            # array.new_default creates array filled with default value (0 for primitives, null for refs)
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
            append!(bytes, encode_leb128_unsigned(arr_type_idx))

            return bytes
        elseif name === :memset
            # memset(ptr, value, size) - fill memory with a value
            # In WasmGC, arrays are already zero-initialized by array.new_default
            # so memset to 0 is a no-op. The ptr is already on the stack from
            # the gc_preserve_begin pattern - we just need to pass it through.
            # Return the pointer (first arg) as the result since memset returns ptr
            if length(expr.args) >= 6
                ptr_arg = expr.args[6]
                append!(bytes, compile_value(ptr_arg, ctx))
            end
            return bytes
        elseif name === :jl_object_id
            # jl_object_id(x) -> UInt64: compute object identity hash
            # For WasmGC, we implement a simple FNV-1a hash over the byte array
            # representation. Symbol/String are byte arrays, so we hash their contents.
            # For other types, we use a constant (since object identity is less meaningful
            # in WasmGC where there's no pointer identity).
            if length(expr.args) >= 6
                obj_arg = expr.args[6]
                obj_type = infer_value_type(obj_arg, ctx)

                if obj_type === Symbol || obj_type === String
                    # Hash the byte array: FNV-1a over characters
                    # We need a loop, so implement inline:
                    # result = 14695981039346656037 (FNV offset basis)
                    # for each byte b in array:
                    #   result = (result XOR b) * 1099511628211 (FNV prime)
                    #
                    # Since Wasm doesn't have easy loops here, we use a simpler approach:
                    # hash = array.len (gives a unique-enough hash for small dicts)
                    # This is a simplified hash that uses the string length as a hash.
                    # For correctness with equal symbols, equal strings produce equal hashes.
                    append!(bytes, compile_value(obj_arg, ctx))
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.ARRAY_LEN)
                    # Extend i32 to i64 for UInt64 result
                    push!(bytes, Opcode.I64_EXTEND_I32_U)
                else
                    # For non-string types, return a constant hash
                    push!(bytes, Opcode.I64_CONST)
                    append!(bytes, encode_leb128_signed(Int64(42)))
                end
            else
                # Fallback: constant hash
                push!(bytes, Opcode.I64_CONST)
                append!(bytes, encode_leb128_signed(Int64(0)))
            end
            return bytes
        elseif name === :jl_string_to_genericmemory
            # Convert String to Memory{UInt8}
            # In WasmGC, String and Memory{UInt8} both use the same byte array representation
            # So this is essentially just passing through the underlying array

            # The string argument is at args[6]
            if length(expr.args) >= 6
                str_arg = expr.args[6]
                append!(bytes, compile_value(str_arg, ctx))
            end

            return bytes
        elseif name === :jl_alloc_string
            # PURE-317: jl_alloc_string(n::UInt64) -> String
            # Allocates a new String of n bytes. In WasmGC, String is array<i32>.
            # Create a zero-filled array of the requested size.
            str_arr_type = get_string_array_type!(ctx.mod, ctx.type_registry)
            if length(expr.args) >= 6
                size_arg = expr.args[6]
                append!(bytes, compile_value(size_arg, ctx))
                size_type = infer_value_type(size_arg, ctx)
                if size_type === Int64 || size_type === Int || size_type === UInt64
                    push!(bytes, Opcode.I32_WRAP_I64)
                end
            else
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
            end
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
            append!(bytes, encode_leb128_unsigned(str_arr_type))
            return bytes
        elseif name === :jl_string_ptr
            # jl_string_ptr(s) -> Ptr{UInt8}: get pointer to string bytes
            # In WasmGC, String is array<i32>. We emit i64.const 1 as base pointer.
            # Base=1 avoids ambiguity with memchr returning 0 for "not found" vs
            # finding at position 0. The pointerref handler traces back to find the
            # original string arg, so the base value doesn't affect it.
            # The memchr handler uses base=1 arithmetic: array_index = ptr - 1.
            push!(bytes, Opcode.I64_CONST)
            push!(bytes, 0x01)
            return bytes
        elseif name === :jl_id_start_char
            # PURE-316: jl_id_start_char(c::UInt32) -> Int32
            # Checks if a Unicode codepoint is a valid identifier start character.
            # For ASCII: letters (A-Z, a-z) and underscore (_).
            # For non-ASCII (>= 128): return 1 (assume valid, conservative).
            if length(expr.args) >= 6
                cp_arg = expr.args[6]  # UInt32 codepoint

                # Stack: [c]
                # Result: (c - 65) < 26 || (c - 97) < 26 || c == 95
                #         [A-Z]           [a-z]             [_]
                # For non-ASCII (c >= 128): return 1

                # Check ASCII vs non-ASCII
                # NOTE: i32.const takes SIGNED LEB128, so use encode_leb128_signed
                append!(bytes, compile_value(cp_arg, ctx))  # [c]
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(128)))
                push!(bytes, Opcode.I32_LT_U)  # c < 128?

                push!(bytes, Opcode.IF)
                push!(bytes, 0x7F)  # result type: i32

                # ASCII path: (c - 65) < 26 || (c - 97) < 26 || c == 95
                append!(bytes, compile_value(cp_arg, ctx))  # [c]
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(65)))
                push!(bytes, Opcode.I32_SUB)
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(26)))
                push!(bytes, Opcode.I32_LT_U)  # (c - 65) < 26  [A-Z]

                append!(bytes, compile_value(cp_arg, ctx))  # [c]
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(97)))
                push!(bytes, Opcode.I32_SUB)
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(26)))
                push!(bytes, Opcode.I32_LT_U)  # (c - 97) < 26  [a-z]

                push!(bytes, Opcode.I32_OR)

                append!(bytes, compile_value(cp_arg, ctx))  # [c]
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(95)))
                push!(bytes, Opcode.I32_EQ)  # c == 95  [_]

                push!(bytes, Opcode.I32_OR)

                push!(bytes, Opcode.ELSE)
                # Non-ASCII path: return 1 (assume valid identifier char)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.END)
            else
                # No argument — return 0
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
            end
            return bytes
        elseif name === :jl_id_char
            # PURE-316: jl_id_char(c::UInt32) -> Int32
            # Checks if a Unicode codepoint is a valid identifier continuation character.
            # For ASCII: letters (A-Z, a-z), digits (0-9), underscore (_), and bang (!).
            # For non-ASCII (>= 128): return 1 (assume valid, conservative).
            if length(expr.args) >= 6
                cp_arg = expr.args[6]  # UInt32 codepoint

                # Check ASCII vs non-ASCII
                # NOTE: i32.const takes SIGNED LEB128, so use encode_leb128_signed
                append!(bytes, compile_value(cp_arg, ctx))  # [c]
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(128)))
                push!(bytes, Opcode.I32_LT_U)  # c < 128?

                push!(bytes, Opcode.IF)
                push!(bytes, 0x7F)  # result type: i32

                # ASCII path: letter || digit || _ || !
                # (c - 65) < 26 || (c - 97) < 26 || (c - 48) < 10 || c == 95 || c == 33
                append!(bytes, compile_value(cp_arg, ctx))
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(65)))
                push!(bytes, Opcode.I32_SUB)
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(26)))
                push!(bytes, Opcode.I32_LT_U)  # [A-Z]

                append!(bytes, compile_value(cp_arg, ctx))
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(97)))
                push!(bytes, Opcode.I32_SUB)
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(26)))
                push!(bytes, Opcode.I32_LT_U)  # [a-z]

                push!(bytes, Opcode.I32_OR)

                append!(bytes, compile_value(cp_arg, ctx))
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(48)))
                push!(bytes, Opcode.I32_SUB)
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(10)))
                push!(bytes, Opcode.I32_LT_U)  # [0-9]

                push!(bytes, Opcode.I32_OR)

                append!(bytes, compile_value(cp_arg, ctx))
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(95)))
                push!(bytes, Opcode.I32_EQ)  # _

                push!(bytes, Opcode.I32_OR)

                append!(bytes, compile_value(cp_arg, ctx))
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(33)))
                push!(bytes, Opcode.I32_EQ)  # !

                push!(bytes, Opcode.I32_OR)

                push!(bytes, Opcode.ELSE)
                # Non-ASCII path: return 1 (assume valid)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.END)
            else
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
            end
            return bytes
        elseif name === :jl_string_to_genericmemory
            # PURE-316: jl_string_to_genericmemory(s::String) -> Memory{UInt8}
            # Converts a String's underlying bytes to a Memory{UInt8}.
            # In WasmGC, both String and Memory{UInt8} are represented as array<i32>,
            # so this is a no-op: just return the string argument itself.
            # For ASCII/UTF-8 source code, the codepoint values equal the byte values.
            if length(expr.args) >= 6
                str_arg = expr.args[6]
                append!(bytes, compile_value(str_arg, ctx))
            end
            return bytes
        elseif name === :jl_genericmemory_to_string
            # PURE-325: jl_genericmemory_to_string(memory, n) -> String
            # Creates a String of exactly n bytes from a Memory{UInt8}.
            # The underlying WasmGC array may have more capacity than n
            # (Julia allocates Memory with minimum size 16), so we must
            # create a new array of exactly n elements and copy.
            if length(expr.args) >= 7
                mem_arg = expr.args[6]
                len_arg = expr.args[7]
                str_arr_type = get_string_array_type!(ctx.mod, ctx.type_registry)

                # Allocate locals for dest array and length
                dest_local = length(ctx.locals) + ctx.n_params
                push!(ctx.locals, ConcreteRef(str_arr_type))
                len_local = length(ctx.locals) + ctx.n_params
                push!(ctx.locals, I32)

                # Compile n and convert to i32
                append!(bytes, compile_value(len_arg, ctx))
                len_type = infer_value_type(len_arg, ctx)
                if len_type === Int64 || len_type === Int || len_type === UInt64
                    push!(bytes, Opcode.I32_WRAP_I64)
                end
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(len_local))

                # Create new array of exactly n elements
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
                append!(bytes, encode_leb128_unsigned(str_arr_type))
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(dest_local))

                # array.copy: dest, dest_offset=0, src, src_offset=0, count=n
                push!(bytes, Opcode.I32_CONST, 0x00)  # dest offset
                append!(bytes, compile_value(mem_arg, ctx))  # src array
                push!(bytes, Opcode.I32_CONST, 0x00)  # src offset
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(len_local))  # count
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_COPY)
                append!(bytes, encode_leb128_unsigned(str_arr_type))  # dest type
                append!(bytes, encode_leb128_unsigned(str_arr_type))  # src type

                # Return the new array
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(dest_local))
            elseif length(expr.args) >= 6
                # Fallback: no length arg, just pass through
                mem_arg = expr.args[6]
                append!(bytes, compile_value(mem_arg, ctx))
            end
            return bytes
        elseif name === :jl_pchar_to_string
            # PURE-325: jl_pchar_to_string(ptr, n) -> String
            # Creates a String from a char pointer and length. In WasmGC, we trace
            # the pointer back to the underlying array, then copy exactly n bytes.
            if length(expr.args) >= 7
                ptr_arg = expr.args[6]
                len_arg = expr.args[7]
                data_ssa = _trace_ptr_to_data(ptr_arg, ctx)
                if data_ssa !== nothing
                    str_arr_type = get_string_array_type!(ctx.mod, ctx.type_registry)

                    # Allocate locals for dest array and length
                    dest_local = length(ctx.locals) + ctx.n_params
                    push!(ctx.locals, ConcreteRef(str_arr_type))
                    len_local = length(ctx.locals) + ctx.n_params
                    push!(ctx.locals, I32)

                    # Compile n and convert to i32
                    append!(bytes, compile_value(len_arg, ctx))
                    len_type = infer_value_type(len_arg, ctx)
                    if len_type === Int64 || len_type === Int || len_type === UInt64
                        push!(bytes, Opcode.I32_WRAP_I64)
                    end
                    push!(bytes, Opcode.LOCAL_TEE)
                    append!(bytes, encode_leb128_unsigned(len_local))

                    # Create new array of exactly n elements
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
                    append!(bytes, encode_leb128_unsigned(str_arr_type))
                    push!(bytes, Opcode.LOCAL_TEE)
                    append!(bytes, encode_leb128_unsigned(dest_local))

                    # array.copy: dest, dest_offset=0, src, src_offset=0, count=n
                    push!(bytes, Opcode.I32_CONST, 0x00)  # dest offset
                    append!(bytes, compile_value(data_ssa, ctx))  # src array
                    push!(bytes, Opcode.I32_CONST, 0x00)  # src offset
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(len_local))  # count
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.ARRAY_COPY)
                    append!(bytes, encode_leb128_unsigned(str_arr_type))  # dest type
                    append!(bytes, encode_leb128_unsigned(str_arr_type))  # src type

                    # Return the new array
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(dest_local))
                    return bytes
                end
                # Fallback: the pointer might be directly compilable as a ref
                append!(bytes, compile_value(ptr_arg, ctx))
            elseif length(expr.args) >= 6
                ptr_arg = expr.args[6]
                append!(bytes, compile_value(ptr_arg, ctx))
            end
            return bytes
        elseif name === :utf8proc_grapheme_break_stateful
            # PURE-316: utf8proc_grapheme_break_stateful(c1::UInt32, c2::UInt32, state::Ref{Int32}) -> Bool
            # Returns true if there's a grapheme cluster break between c1 and c2.
            # In WasmGC, we don't have the utf8proc C library. Return true (break)
            # for all character pairs. This is conservative: it treats every codepoint
            # as its own grapheme cluster, which is correct for ASCII/BMP parsing.
            push!(bytes, Opcode.I32_CONST)
            push!(bytes, 0x01)  # true = always a grapheme break
            return bytes
        elseif name === :jl_ptr_to_array_1d
            # PURE-324: jl_ptr_to_array_1d(type, ptr, len, own) -> Vector{T}
            # Creates a Vector from a raw pointer. In WasmGC, raw pointers don't exist.
            # The pointer arg traces back through bitcast/getfield(:ptr) to a Memory
            # (= array in WasmGC). We trace the IR to find the original data array,
            # then wrap it in a Vector struct (data_array_ref, size_tuple).
            ret_type = length(expr.args) >= 2 ? expr.args[2] : nothing
            ptr_arg = length(expr.args) >= 7 ? expr.args[7] : nothing
            len_arg = length(expr.args) >= 8 ? expr.args[8] : nothing

            if ret_type !== nothing && ret_type <: AbstractVector
                # Trace ptr back through bitcast/getfield(:ptr) to find the data source
                data_source = _trace_ptr_to_data(ptr_arg, ctx)
                if data_source !== nothing
                    # Get or register Vector type
                    vec_info = register_vector_type!(ctx.mod, ctx.type_registry, ret_type)
                    vec_type_idx = vec_info.wasm_type_idx
                    # Get size tuple type
                    size_tuple_type = Tuple{Int64}
                    if !haskey(ctx.type_registry.structs, size_tuple_type)
                        register_tuple_type!(ctx.mod, ctx.type_registry, size_tuple_type)
                    end
                    size_info = ctx.type_registry.structs[size_tuple_type]

                    # Stack: [data_array_ref, size_tuple_ref] for struct.new Vector
                    # 1. Push data array ref
                    append!(bytes, compile_value(data_source, ctx))
                    # 2. Push length as i64 for size tuple, then struct.new Tuple{Int64}
                    if len_arg !== nothing
                        append!(bytes, compile_value(len_arg, ctx))
                        len_type = infer_value_type(len_arg, ctx)
                        if len_type === UInt64
                            # UInt64 → i64 is already i64, but need signed interpretation
                            # For Wasm purposes, UInt64 and Int64 are both i64
                        elseif len_type === Int32 || len_type === UInt32
                            push!(bytes, Opcode.I64_EXTEND_I32_S)
                        end
                    else
                        push!(bytes, Opcode.I64_CONST)
                        push!(bytes, 0x00)
                    end
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.STRUCT_NEW)
                    append!(bytes, encode_leb128_unsigned(size_info.wasm_type_idx))
                    # 3. struct.new Vector(data_ref, size_tuple_ref)
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.STRUCT_NEW)
                    append!(bytes, encode_leb128_unsigned(vec_type_idx))
                    return bytes
                end
            end
        end
    end

    # PURE-325: memchr(ptr, byte, count) — scan string array for a byte value.
    # Used by Base._search for findnext/findfirst on strings.
    # In WasmGC, we scan the array<i32> representation directly.
    # With jl_string_ptr base=1: ptr = 1+i-1 = i (1-based start position).
    # memchr returns the 1-based "pointer" (base + array_index) if found, or 0 (C_NULL) if not.
    if name === :memchr && length(expr.args) >= 8
        ptr_arg = expr.args[6]   # Ptr{UInt8} — traces back to string + offset
        byte_arg = expr.args[7]  # Int32 — the byte to search for
        count_arg = expr.args[8] # UInt64 — number of bytes to search

        # Trace the pointer back to find the string array ref
        str_info = ptr_arg isa Core.SSAValue ? _trace_string_ptr(ptr_arg, ctx.code_info.code) : nothing
        if str_info !== nothing
            str_ssa, _idx_ssa = str_info
            str_arr_type = get_string_array_type!(ctx.mod, ctx.type_registry)

            # Allocate locals for the loop (same pattern as scratch_local allocation)
            str_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, ConcreteRef(str_arr_type))
            current_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, I64)
            end_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, I64)
            result_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, I64)
            byte_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, I32)

            # Store string ref
            append!(bytes, compile_value(str_ssa, ctx))
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(str_local))

            # Store start_ptr (the ptr argument to memchr = 1-based position)
            append!(bytes, compile_value(ptr_arg, ctx))
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(current_local))

            # Store byte
            append!(bytes, compile_value(byte_arg, ctx))
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(byte_local))

            # Compute end = start + count
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(current_local))
            append!(bytes, compile_value(count_arg, ctx))
            push!(bytes, Opcode.I64_ADD)
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(end_local))

            # result = 0 (not found)
            push!(bytes, Opcode.I64_CONST)
            push!(bytes, 0x00)
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(result_local))

            # block $done
            push!(bytes, Opcode.BLOCK)
            push!(bytes, 0x40)  # void

            #   loop $scan
            push!(bytes, Opcode.LOOP)
            push!(bytes, 0x40)  # void

            #     if current >= end, break
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(current_local))
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(end_local))
            push!(bytes, Opcode.I64_GE_U)
            push!(bytes, Opcode.BR_IF)
            push!(bytes, 0x01)  # br to block (depth 1 = $done)

            #     array_index = current - 1 (base=1, so ptr=1 means index=0)
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(str_local))
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(current_local))
            push!(bytes, Opcode.I32_WRAP_I64)
            push!(bytes, Opcode.I32_CONST)
            push!(bytes, 0x01)
            push!(bytes, Opcode.I32_SUB)  # 0-based index
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ARRAY_GET)
            append!(bytes, encode_leb128_unsigned(str_arr_type))

            #     if array[idx] == byte, found!
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(byte_local))
            push!(bytes, Opcode.I32_EQ)
            push!(bytes, Opcode.IF)
            push!(bytes, 0x40)  # void
            #       result = current
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(current_local))
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(result_local))
            push!(bytes, Opcode.BR)
            push!(bytes, 0x02)  # br to block (depth 2 = $done)
            push!(bytes, Opcode.END)  # end if

            #     current += 1
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(current_local))
            push!(bytes, Opcode.I64_CONST)
            push!(bytes, 0x01)
            push!(bytes, Opcode.I64_ADD)
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(current_local))

            #     br $scan (continue loop)
            push!(bytes, Opcode.BR)
            push!(bytes, 0x00)  # br to loop (depth 0 = $scan)

            #   end loop
            push!(bytes, Opcode.END)
            # end block
            push!(bytes, Opcode.END)

            # Push result (the "pointer" or 0)
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(result_local))
            return bytes
        end
    end

    # PURE-325: memmove(dest_ptr, src_ptr, n_bytes) — copy between Memory arrays.
    # Used by take!(IOBuffer) to copy data from IOBuffer's backing Memory to a new String.
    # In WasmGC, we emit array.copy between the underlying array<i32> representations.
    # Trace: memmove args come from getfield(memoryref, :ptr_or_offset) which is i64.const 0.
    # The real arrays are found by tracing back through memoryrefnew to the backing Memory.
    if name === :memmove && length(expr.args) >= 8
        dest_ptr_arg = expr.args[6]   # Ptr{Nothing} — traces to dest MemoryRef
        src_ptr_arg = expr.args[7]    # Ptr{Nothing} — traces to src MemoryRef
        nbytes_arg = expr.args[8]     # UInt64 — byte count

        code = ctx.code_info.code
        dest_info = _trace_memmove_array(dest_ptr_arg, code, ctx)
        src_info = _trace_memmove_array(src_ptr_arg, code, ctx)

        if dest_info !== nothing && src_info !== nothing
            dest_arr_ssa, dest_offset_ssa = dest_info
            src_arr_ssa, src_offset_ssa = src_info
            # Determine actual array type from the SSA's wasm local type
            # Default to string array (i32[]) but use correct type if SSA local is a ConcreteRef
            arr_copy_type = get_string_array_type!(ctx.mod, ctx.type_registry)
            if dest_arr_ssa isa Core.SSAValue && haskey(ctx.ssa_locals, dest_arr_ssa.id)
                local_idx = ctx.ssa_locals[dest_arr_ssa.id]
                local_type = _get_local_type(ctx, local_idx)
                if local_type isa ConcreteRef
                    arr_copy_type = local_type.type_idx
                end
            end

            # array.copy: dest_arr, dest_offset, src_arr, src_offset, count
            # dest array
            append!(bytes, compile_value(dest_arr_ssa, ctx))
            # dest offset (0-based: memoryrefnew offset is 1-based, subtract 1)
            if dest_offset_ssa === nothing
                push!(bytes, Opcode.I32_CONST, 0x00)
            else
                append!(bytes, compile_value(dest_offset_ssa, ctx))
                dest_offset_type = infer_value_type(dest_offset_ssa, ctx)
                if dest_offset_type === Int64 || dest_offset_type === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end
                push!(bytes, Opcode.I32_CONST, 0x01)
                push!(bytes, Opcode.I32_SUB)
            end
            # src array
            append!(bytes, compile_value(src_arr_ssa, ctx))
            # src offset (0-based)
            if src_offset_ssa === nothing
                push!(bytes, Opcode.I32_CONST, 0x00)
            else
                append!(bytes, compile_value(src_offset_ssa, ctx))
                src_offset_type = infer_value_type(src_offset_ssa, ctx)
                if src_offset_type === Int64 || src_offset_type === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end
                push!(bytes, Opcode.I32_CONST, 0x01)
                push!(bytes, Opcode.I32_SUB)
            end
            # count (convert from bytes to elements — for UInt8/i32 arrays, count = n_bytes)
            append!(bytes, compile_value(nbytes_arg, ctx))
            nbytes_type = infer_value_type(nbytes_arg, ctx)
            if nbytes_type === Int64 || nbytes_type === Int || nbytes_type === UInt64
                push!(bytes, Opcode.I32_WRAP_I64)
            end
            # emit array.copy
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ARRAY_COPY)
            append!(bytes, encode_leb128_unsigned(arr_copy_type))  # dest type
            append!(bytes, encode_leb128_unsigned(arr_copy_type))  # src type
            # memmove returns dest ptr — push i64.const 0 as the result
            push!(bytes, Opcode.I64_CONST, 0x00)
            return bytes
        end
    end

    if name === :jl_symbol_n
        # jl_symbol_n(ptr::Ptr{UInt8}, len::Int64) -> Ref{Symbol}
        # In WasmGC, Symbol is represented as a string byte array (same as String).
        # The GC root argument (expr.args[8]) is the original String — just return it.
        if length(expr.args) >= 8
            gc_root = expr.args[8]
            append!(bytes, compile_value(gc_root, ctx))
            return bytes
        end
    end

    # Unknown foreigncall - emit unreachable.
    # We cannot execute native C FFI in WebAssembly. Emitting unreachable:
    # (1) Makes the wasm validator accept any stack type (polymorphic)
    # (2) Correctly traps if this code path is reached at runtime
    # (3) Enables then_ends_unreachable detection for IF block typing
    push!(bytes, Opcode.UNREACHABLE)
    ctx.last_stmt_was_stub = true  # PURE-908
    return bytes
end

"""
Trace a pointerref argument back through add_ptr/sub_ptr to find a jl_string_ptr foreigncall.
Returns (string_ssa, index_ssa) if found, or nothing if not a string pointer pattern.
The index_ssa is the offset argument to add_ptr (the 1-based codeunit index).
"""
function _trace_string_ptr(ptr_ssa, code)
    # ptr_ssa should be SSAValue pointing to sub_ptr or add_ptr or jl_string_ptr
    if !(ptr_ssa isa Core.SSAValue)
        return nothing
    end
    stmt = code[ptr_ssa.id]
    if !(stmt isa Expr && stmt.head === :call)
        return nothing
    end
    func = stmt.args[1]
    if !(func isa GlobalRef)
        return nothing
    end
    args = stmt.args[2:end]

    if func.name === :sub_ptr && length(args) >= 2
        # sub_ptr(ptr, offset) — recurse on ptr
        return _trace_string_ptr(args[1], code)
    elseif func.name === :add_ptr && length(args) >= 2
        # add_ptr(ptr, index) — ptr should be jl_string_ptr, index is codeunit index
        inner = args[1]
        if inner isa Core.SSAValue
            inner_stmt = code[inner.id]
            if inner_stmt isa Expr && inner_stmt.head === :foreigncall
                fname = inner_stmt.args[1]
                fname_val = fname isa QuoteNode ? fname.value : fname
                if fname_val === :jl_string_ptr && length(inner_stmt.args) >= 6
                    # Found it! Return (string_arg, index_arg)
                    return (inner_stmt.args[6], args[2])
                end
            end
        end
        return nothing
    else
        return nothing
    end
end

"""
Trace a pointer SSA back through bitcast/getfield(:ptr) to find the original data source.
Used by jl_ptr_to_array_1d to find the underlying Memory/array reference.
Returns the SSA value that produces the data array, or nothing if trace fails.

The typical IR pattern is:
  %data = getfield(%iobuf, :data)      -> Memory{T} (= array in WasmGC)
  %ptr  = getfield(%data, :ptr)        -> Ptr{Nothing} (= i64 0 in WasmGC)
  %ptr2 = bitcast(Ptr{UInt8}, %ptr)    -> Ptr{UInt8} (= i64 0)
  ...
  %vec  = jl_ptr_to_array_1d(Vector{T}, %ptr2, %len, ...)

We trace from %ptr2 back to %data (the Memory reference).
"""
function _trace_ptr_to_data(ptr_val, ctx::CompilationContext)
    code = ctx.code_info.code
    # Walk backwards through SSA values
    current = ptr_val
    for _ in 1:10  # max depth to prevent infinite loops
        if !(current isa Core.SSAValue)
            return nothing
        end
        stmt = code[current.id]
        if stmt isa Expr
            if stmt.head === :call
                func = stmt.args[1]
                if func isa GlobalRef
                    fname = func.name
                    if fname === :bitcast && length(stmt.args) >= 3
                        # bitcast(TargetType, source) — continue tracing source
                        current = stmt.args[3]
                        continue
                    elseif fname === :getfield && length(stmt.args) >= 3
                        field_ref = stmt.args[3]
                        field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
                        if field_sym === :ptr
                            # getfield(memory, :ptr) — the source is the memory obj
                            # The memory IS the data array in WasmGC
                            obj = stmt.args[2]
                            return obj
                        elseif field_sym === :data
                            # getfield(iobuf, :data) — this IS the data array
                            return current
                        else
                            return nothing
                        end
                    end
                end
            elseif stmt.head === :foreigncall
                # May be jl_string_ptr or similar — check
                name_arg = stmt.args[1]
                fname = name_arg isa QuoteNode ? name_arg.value : name_arg
                if fname === :jl_string_ptr && length(stmt.args) >= 6
                    # jl_string_ptr(s) — the string IS the data in WasmGC
                    return stmt.args[6]
                end
                return nothing
            end
        end
        return nothing
    end
    return nothing
end

"""
Trace a memmove pointer argument back through getfield(:ptr_or_offset) → memoryrefnew
to find the underlying array SSA and offset SSA.
Returns (array_ssa, offset_ssa) or nothing if trace fails.
offset_ssa may be nothing if the memoryrefnew has no offset (starts at beginning).

IR pattern:
  %142 = getfield(%69, :ref)          — Vector's ref field (a MemoryRef = array in WasmGC)
  %144 = memoryrefnew(%142, 1, ...)   — MemoryRef at offset 1
  %159 = getfield(%144, :ptr_or_offset)  — i64.const 0 in WasmGC
  memmove(%159, ...)
"""
function _trace_memmove_array(ptr_ssa, code, ctx::CompilationContext)
    if !(ptr_ssa isa Core.SSAValue)
        return nothing
    end
    stmt = code[ptr_ssa.id]
    # Should be getfield(memoryref, :ptr_or_offset)
    if !(stmt isa Expr && stmt.head === :call)
        return nothing
    end
    func = stmt.args[1]
    if !(func isa GlobalRef && func.name === :getfield && length(stmt.args) >= 3)
        return nothing
    end
    field_ref = stmt.args[3]
    field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
    if field_sym !== :ptr_or_offset
        return nothing
    end
    # The object is a MemoryRef SSA
    memref_ssa = stmt.args[2]
    if !(memref_ssa isa Core.SSAValue)
        return nothing
    end
    memref_stmt = code[memref_ssa.id]

    # Should be memoryrefnew(base) or memoryrefnew(base, offset, boundscheck)
    if memref_stmt isa Expr && memref_stmt.head === :call
        fn = memref_stmt.args[1]
        if fn isa GlobalRef && fn.name === :memoryrefnew
            if length(memref_stmt.args) >= 4
                # memoryrefnew(base, offset, boundscheck)
                base_ssa = memref_stmt.args[2]
                offset_ssa = memref_stmt.args[3]
                # base could be another memoryrefnew or a Memory/array directly
                arr_ssa = _resolve_memref_to_array(base_ssa, code)
                return (arr_ssa !== nothing ? arr_ssa : base_ssa, offset_ssa)
            elseif length(memref_stmt.args) >= 2
                # memoryrefnew(memory) — no offset
                base_ssa = memref_stmt.args[2]
                arr_ssa = _resolve_memref_to_array(base_ssa, code)
                return (arr_ssa !== nothing ? arr_ssa : base_ssa, nothing)
            end
        end
    end
    return nothing
end

"""
Resolve a MemoryRef base SSA to the actual array.
For memmove, we need the WasmGC array reference that backs the data.
In WasmGC:
  - Vector field :ref → struct_get field 0 → array ref (use the SSA of getfield)
  - IOBuffer field :data → the Memory which IS the array (use the SSA of getfield)
  - jl_string_to_genericmemory → returns the String which IS the array
  - memoryrefnew(base) → the base IS the array
Returns the SSA whose compile_value produces the array ref, or nothing.
"""
function _resolve_memref_to_array(ssa, code)
    if !(ssa isa Core.SSAValue)
        return nothing
    end
    stmt = code[ssa.id]
    if !(stmt isa Expr)
        return nothing
    end
    if stmt.head === :call
        func = stmt.args[1]
        if func isa GlobalRef
            if func.name === :memoryrefnew && length(stmt.args) >= 2
                # Another memoryrefnew — recurse on its base
                return _resolve_memref_to_array(stmt.args[2], code)
            elseif func.name === :getfield && length(stmt.args) >= 3
                field_ref = stmt.args[3]
                field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
                if field_sym === :ref || field_sym === :data
                    # getfield(vector, :ref) or getfield(iobuf, :data)
                    # The RESULT of this getfield is the array in WasmGC
                    # So return the SSA of the getfield itself
                    return ssa
                end
            end
        end
    elseif stmt.head === :foreigncall
        name_arg = stmt.args[1]
        fname = name_arg isa QuoteNode ? name_arg.value : name_arg
        if fname === :jl_string_to_genericmemory && length(stmt.args) >= 6
            # In WasmGC, jl_string_to_genericmemory returns the String which IS the array
            return stmt.args[6]
        end
    end
    return nothing
end

