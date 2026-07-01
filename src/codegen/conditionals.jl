function generate_void_flow(ctx::AbstractCompilationContext, blocks::Vector{BasicBlock}, code)::Vector{UInt8}
    b = InstrBuilder(; func_name="generate_void_flow", strict=false)

    # Track which statements we've already compiled
    compiled = Set{Int}()

    # Count how many times each SSA value is used (to determine if we need to DROP)
    # SSA values that are used elsewhere should NOT be dropped - they stay on stack
    ssa_use_count = Dict{Int, Int}()
    for stmt in code
        count_ssa_uses!(stmt, ssa_use_count)
    end

    # Process statements in order
    i = 1
    while i <= length(code)
        if i in compiled
            i += 1
            continue
        end

        stmt = code[i]

        if stmt === nothing
            push!(compiled, i)
            i += 1
            continue
        end

        if stmt isa Core.ReturnNode
            # PURE-036ag/PURE-045: Handle ReturnNodes with values, not just void returns
            if isdefined(stmt, :val)
                func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64

                if func_ret_wasm === ExternRef && is_numeric_val
                    nb = UInt8[]; emit_numeric_to_externref!(nb, stmt.val, val_wasm, ctx); emit_raw!(b, nb; pushes=WasmValType[ExternRef])
                elseif func_ret_wasm isa ConcreteRef && is_numeric_val
                    # PURE-045: Numeric (nothing) to concrete ref - return ref.null of the type
                    ref_null!(b, Int64(func_ret_wasm.type_idx), ConcreteRef(UInt32(func_ret_wasm.type_idx), true))
                elseif func_ret_wasm === AnyRef && is_numeric_val
                    # PURE-9030: Box numeric value for AnyRef return
                    emit_raw!(b, compile_value(stmt.val, ctx); pushes=WasmValType[val_wasm])
                    emit_classid_box!(b, ctx, val_wasm, nothing)   # THE single box emitter (was a copy-pasted return box)
                elseif (func_ret_wasm === StructRef || func_ret_wasm === ArrayRef) && is_numeric_val
                    # PURE-045: Numeric to abstract ref - return ref.null of the abstract type
                    ref_null!(b, func_ret_wasm)
                else
                    emit_raw!(b, compile_value(stmt.val, ctx); pushes=WasmValType[val_wasm === nothing ? AnyRef : val_wasm])
                    # If function returns externref but value is a concrete ref, convert
                    if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                        extern_convert_any!(b)
                    end
                end
            end
            return_!(b)
            push!(compiled, i)
            i += 1
            continue
        end

        if stmt isa Core.GotoNode
            # Unconditional jump - skip (handled by structured control flow)
            push!(compiled, i)
            i += 1
            continue
        end

        if stmt isa Core.GotoIfNot
            # Conditional - compile as void if-block
            goto_if_not = stmt
            else_target = goto_if_not.dest

            # Determine if this is an if-then-else or just if-then by checking for a GotoNode
            # at the end of the then-branch that jumps past the else_target.
            # If-then-else pattern:
            #   GotoIfNot → else_target
            #   then-code
            #   GotoNode → merge_point  ← jumps PAST else_target
            #   else_target: else-code
            #   merge_point: ...
            # If-then pattern (no else):
            #   GotoIfNot → merge_point
            #   then-code
            #   merge_point: continuation  ← no GotoNode, code continues sequentially
            has_else_branch = false
            for j in (i+1):(else_target-1)
                if code[j] isa Core.GotoNode
                    goto_node = code[j]::Core.GotoNode
                    # If the GotoNode jumps past else_target, we have an else branch
                    if goto_node.label > else_target
                        has_else_branch = true
                        break
                    end
                end
            end

            # Push condition
            emit_raw!(b, compile_condition_to_i32(goto_if_not.cond, ctx); pushes=WasmValType[I32])
            push!(compiled, i)

            # Start void if block
            if_!(b)

            # Compile then-branch (i+1 to else_target-1)
            for j in (i+1):(else_target-1)
                if j in compiled
                    continue
                end
                inner = code[j]
                if inner === nothing
                    push!(compiled, j)
                elseif inner isa Core.GotoNode
                    push!(compiled, j)
                elseif inner isa Core.ReturnNode
                    # Early return inside conditional - compile value and emit return
                    # PURE-036af: Must compile the return value, not just emit RETURN
                    if isdefined(inner, :val)
                        func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                        val_wasm = get_phi_edge_wasm_type(inner.val, ctx)
                        is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64

                        if func_ret_wasm === ExternRef && is_numeric_val
                            nb = UInt8[]; emit_numeric_to_externref!(nb, inner.val, val_wasm, ctx); emit_raw!(b, nb; pushes=WasmValType[ExternRef])
                        else
                            emit_raw!(b, compile_value(inner.val, ctx); pushes=WasmValType[val_wasm === nothing ? AnyRef : val_wasm])
                            if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                                extern_convert_any!(b)
                            end
                        end
                    end
                    # BUT: If the return type is Union{} (unreachable), don't emit RETURN
                    stmt_type = get(ctx.ssa_types, j, Any)
                    if stmt_type !== Union{}
                        return_!(b)
                    end
                    push!(compiled, j)
                elseif inner isa Core.GotoIfNot
                    # Check if this GotoIfNot is a ternary pattern (has a phi node)
                    # If so, use compile_ternary_for_phi to produce the phi value
                    inner_goto_if_not = inner::Core.GotoIfNot
                    inner_else_target = inner_goto_if_not.dest

                    # Look for a phi node after the inner else target
                    phi_idx_for_ternary = nothing
                    for k in inner_else_target:length(code)
                        if code[k] isa Core.PhiNode
                            phi_idx_for_ternary = k
                            break
                        end
                        if code[k] isa Core.GotoIfNot || (code[k] isa Expr && code[k].head === :call)
                            break  # Past the ternary
                        end
                    end

                    if phi_idx_for_ternary !== nothing && haskey(ctx.phi_locals, phi_idx_for_ternary)
                        # This is a ternary pattern - use compile_ternary_for_phi
                        emit_raw!(b, compile_ternary_for_phi(ctx, code, j, compiled))
                    else
                        # Regular nested conditional in void context (from && operator)
                        emit_raw!(b, compile_void_nested_conditional(ctx, code, j, compiled, ssa_use_count))
                    end
                elseif inner isa Core.PhiNode
                    # Phi already handled by compile_ternary_for_phi if it was part of a ternary
                    # If not handled, just skip it
                    push!(compiled, j)
                else
                    compiled_bytes = compile_statement(inner, j, ctx)
                    emit_raw!(b, compiled_bytes)
                    push!(compiled, j)

                    # Check if this statement produces Union{} (never returns, e.g., throw)
                    # If so, stop compiling - any code after is dead code
                    stmt_type = get(ctx.ssa_types, j, Any)
                    if stmt_type === Union{}
                        break
                    end

                    # Check if this statement leaves a value on stack that we need to drop
                    # In void functions, return statements are skipped, so values meant for
                    # returns stay on stack. We need to drop them.
                    if inner isa Expr && (inner.head === :call || inner.head === :invoke)
                        # PURE-220: Skip if compile_statement already emitted a DROP
                        # (e.g., compile_invoke adds DROP for higher-order Core.Argument calls)
                        # PURE-6006: Guard against call instruction false-positive (func_idx 0x1a == DROP)
                        already_has_drop = !isempty(compiled_bytes) && compiled_bytes[end] == Opcode.DROP &&
                                           !(length(compiled_bytes) >= 2 && compiled_bytes[end-1] == Opcode.CALL)

                        # First check if this is a signal setter invoke - these ALWAYS need DROP
                        # because setters push a return value that won't be used in void context
                        is_setter_call = false
                        if inner.head === :invoke && length(inner.args) >= 2
                            func_ref = inner.args[2]
                            if func_ref isa Core.SSAValue
                                is_setter_call = haskey(ctx.signal_ssa_setters, func_ref.id)
                            end
                        end

                        if is_setter_call && !already_has_drop && !haskey(ctx.ssa_locals, j)
                            # Signal setters push a return value that won't be used
                            # THERAPY-2401: Skip DROP if compile_statement already stored
                            # the value to an ssa_local via LOCAL_SET (which consumed the stack value)
                            drop!(b)
                        elseif !already_has_drop
                            # For other calls, check if statement produces a value and use count
                            if statement_produces_wasm_value(inner, j, ctx)
                                if !haskey(ctx.ssa_locals, j) && !haskey(ctx.phi_locals, j)
                                    use_count = get(ssa_use_count, j, 0)
                                    if use_count == 0
                                        drop!(b)
                                    end
                                end
                            end
                        end
                    end
                end
            end

            if has_else_branch
                # Else branch - only emit when there's actual else code
                else_!(b)

                # Find where the else branch ends (the merge point from the GotoNode)
                else_end = length(code)
                for j in (i+1):(else_target-1)
                    if code[j] isa Core.GotoNode
                        goto_node = code[j]::Core.GotoNode
                        if goto_node.label > else_target
                            else_end = goto_node.label - 1
                            break
                        end
                    end
                end

                # Compile else-branch (else_target to else_end)
                for j in else_target:else_end
                    if j in compiled
                        continue
                    end
                    inner = code[j]
                    if inner === nothing
                        push!(compiled, j)
                    elseif inner isa Core.ReturnNode
                        # PURE-036ag: Early return inside else branch - compile value before return
                        stmt_type = get(ctx.ssa_types, j, Any)
                        if stmt_type !== Union{}
                            if isdefined(inner, :val)
                                func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                                val_wasm = get_phi_edge_wasm_type(inner.val, ctx)
                                is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64

                                if func_ret_wasm === ExternRef && is_numeric_val
                                    nb = UInt8[]; emit_numeric_to_externref!(nb, inner.val, val_wasm, ctx); emit_raw!(b, nb; pushes=WasmValType[ExternRef])
                                else
                                    emit_raw!(b, compile_value(inner.val, ctx); pushes=WasmValType[val_wasm === nothing ? AnyRef : val_wasm])
                                    if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                                        extern_convert_any!(b)
                                    end
                                end
                            end
                            return_!(b)
                        end
                        push!(compiled, j)
                    elseif inner isa Core.GotoNode
                        push!(compiled, j)
                    elseif inner isa Core.GotoIfNot
                        # Check if this GotoIfNot is a ternary pattern (has a phi node)
                        inner_goto_if_not = inner::Core.GotoIfNot
                        inner_else_target = inner_goto_if_not.dest

                        phi_idx_for_ternary = nothing
                        for k in inner_else_target:length(code)
                            if code[k] isa Core.PhiNode
                                phi_idx_for_ternary = k
                                break
                            end
                            if code[k] isa Core.GotoIfNot || (code[k] isa Expr && code[k].head === :call)
                                break
                            end
                        end

                        if phi_idx_for_ternary !== nothing && haskey(ctx.phi_locals, phi_idx_for_ternary)
                            emit_raw!(b, compile_ternary_for_phi(ctx, code, j, compiled))
                        else
                            emit_raw!(b, compile_void_nested_conditional(ctx, code, j, compiled, ssa_use_count))
                        end
                    elseif inner isa Core.PhiNode
                        # Phi already handled by compile_ternary_for_phi
                        push!(compiled, j)
                    else
                        emit_raw!(b, compile_statement(inner, j, ctx))
                        push!(compiled, j)

                        # Check if this statement produces Union{} (never returns, e.g., throw)
                        # If so, stop compiling - any code after is dead code
                        stmt_type = get(ctx.ssa_types, j, Any)
                        if stmt_type === Union{}
                            break
                        end

                        # Drop unused values in void context (else branch)
                        if inner isa Expr && (inner.head === :call || inner.head === :invoke)
                            stmt_type = get(ctx.ssa_types, j, Nothing)
                            if stmt_type !== Nothing  # Only skip if type is definitely Nothing
                                is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                                if !is_nothing_union && statement_produces_wasm_value(inner, j, ctx)
                                    if !haskey(ctx.ssa_locals, j) && !haskey(ctx.phi_locals, j)
                                        use_count = get(ssa_use_count, j, 0)
                                        if use_count == 0
                                            drop!(b)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end

                # Mark all statements up to else_end as compiled (not beyond)
                for j in i:else_end
                    push!(compiled, j)
                end

                end_block!(b)
                i = else_end + 1
            else
                # No else branch - just end the if block and continue from else_target
                # Mark only the then-branch as compiled, else_target onwards will be processed
                # by the main loop
                for j in i:(else_target-1)
                    push!(compiled, j)
                end

                end_block!(b)
                i = else_target
            end
            continue
        end

        # Regular statement
        emit_raw!(b, compile_statement(stmt, i, ctx))
        push!(compiled, i)

        # Check if this statement produces Union{} (never returns, e.g., throw)
        # If so, stop compiling - any code after is dead code
        stmt_type = get(ctx.ssa_types, i, Any)
        if stmt_type === Union{}
            # Don't add more code, just return what we have
            # The function ends with unreachable code path
            return builder_code(b)
        end

        # Drop unused values from statements that produce values
        if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
            stmt_type = get(ctx.ssa_types, i, Nothing)
            if stmt_type !== Nothing  # Only skip if type is definitely Nothing
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
        elseif stmt isa GlobalRef
            # GlobalRef statements (constants) may leave values on stack
            stmt_type = get(ctx.ssa_types, i, Nothing)
            if stmt_type !== Nothing  # Only skip if type is definitely Nothing
                if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                    use_count = get(ssa_use_count, i, 0)
                    if use_count == 0
                        drop!(b)
                    end
                end
            end
        end

        i += 1
    end

    # Final return (in case we didn't hit one)
    return_!(b)

    return builder_code(b)
end

"""
Compile a nested conditional in void context (e.g., from && operators).
This handles patterns like `a && b && c` which compile to nested GotoIfNot.

For `a && b`:
  %1 = a()
  GotoIfNot %1 → end
  %2 = b()
  GotoIfNot %2 → end
  # then code
  end:

Compiles to:
  a()
  if
    b()
    if
      ;; then code
    end
  end
"""
function compile_void_nested_conditional(ctx::AbstractCompilationContext, code, start_idx::Int, compiled::Set{Int}, ssa_use_count::Dict{Int,Int})::Vector{UInt8}
    b = InstrBuilder(; func_name="compile_void_nested_conditional", strict=false)

    goto_if_not = code[start_idx]::Core.GotoIfNot
    end_target = goto_if_not.dest

    # Push condition
    emit_raw!(b, compile_condition_to_i32(goto_if_not.cond, ctx); pushes=WasmValType[I32])
    push!(compiled, start_idx)

    # Start void if block
    if_!(b)  # void block type

    # Process statements in the then-branch (start_idx+1 to end_target-1)
    for j in (start_idx+1):(end_target-1)
        if j in compiled
            continue
        end

        inner = code[j]

        if inner === nothing
            push!(compiled, j)
        elseif inner isa Core.GotoNode
            # Skip unconditional jumps in && chain
            push!(compiled, j)
        elseif inner isa Core.ReturnNode
            # PURE-036ag: Early return inside conditional - compile value before return
            stmt_type = get(ctx.ssa_types, j, Any)
            if stmt_type !== Union{}
                if isdefined(inner, :val)
                    func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                    val_wasm = get_phi_edge_wasm_type(inner.val, ctx)
                    is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64

                    if func_ret_wasm === ExternRef && is_numeric_val
                        nb = UInt8[]; emit_numeric_to_externref!(nb, inner.val, val_wasm, ctx); emit_raw!(b, nb; pushes=WasmValType[ExternRef])
                    else
                        emit_raw!(b, compile_value(inner.val, ctx); pushes=WasmValType[val_wasm === nothing ? AnyRef : val_wasm])
                        if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                            extern_convert_any!(b)
                        end
                    end
                end
                return_!(b)
            end
            push!(compiled, j)
        elseif inner isa Core.GotoIfNot
            # Check if this GotoIfNot is a ternary pattern (has a phi node)
            inner_goto_if_not = inner::Core.GotoIfNot
            inner_else_target = inner_goto_if_not.dest

            phi_idx_for_ternary = nothing
            for k in inner_else_target:length(code)
                if code[k] isa Core.PhiNode
                    phi_idx_for_ternary = k
                    break
                end
                if code[k] isa Core.GotoIfNot || (code[k] isa Expr && code[k].head === :call)
                    break
                end
            end

            if phi_idx_for_ternary !== nothing && haskey(ctx.phi_locals, phi_idx_for_ternary)
                # This is a ternary pattern - use compile_ternary_for_phi
                emit_raw!(b, compile_ternary_for_phi(ctx, code, j, compiled))
            else
                # RECURSION: Another conditional (from && chain)
                emit_raw!(b, compile_void_nested_conditional(ctx, code, j, compiled, ssa_use_count))
            end
        elseif inner isa Core.PhiNode
            # Phi already handled by compile_ternary_for_phi if it was part of a ternary
            push!(compiled, j)
        else
            # Regular statement (including setter calls)
            emit_raw!(b, compile_statement(inner, j, ctx))
            push!(compiled, j)

            # Check if this statement produces Union{} (never returns, e.g., throw)
            # If so, stop compiling - any code after is dead code
            stmt_type = get(ctx.ssa_types, j, Any)
            if stmt_type === Union{}
                break
            end

            # Drop unused values in void context
            if inner isa Expr && (inner.head === :call || inner.head === :invoke)
                is_setter_call = false
                if inner.head === :invoke && length(inner.args) >= 2
                    func_ref = inner.args[2]
                    if func_ref isa Core.SSAValue
                        is_setter_call = haskey(ctx.signal_ssa_setters, func_ref.id)
                    end
                end

                if is_setter_call && !haskey(ctx.ssa_locals, j)
                    # THERAPY-2401: Skip DROP if compile_statement already stored
                    # the value to an ssa_local via LOCAL_SET (which consumed the stack value)
                    drop!(b)
                else
                    stmt_type = get(ctx.ssa_types, j, Nothing)
                    if stmt_type !== Nothing  # Only skip if type is definitely Nothing
                        is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                        if !is_nothing_union
                            if !haskey(ctx.ssa_locals, j) && !haskey(ctx.phi_locals, j)
                                use_count = get(ssa_use_count, j, 0)
                                if use_count == 0
                                    drop!(b)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    # End if block (no else for && pattern - false case just skips)
    end_block!(b)

    return builder_code(b)
end

"""
Compile a ternary expression (if-then-else with phi) that produces a value.
Returns bytecode that computes the ternary and stores to the phi local.
"""
function compile_ternary_for_phi(ctx::AbstractCompilationContext, code, cond_idx::Int, compiled::Set{Int})::Vector{UInt8}
    b = InstrBuilder(; func_name="compile_ternary_for_phi", strict=false)

    goto_if_not = code[cond_idx]::Core.GotoIfNot
    else_target = goto_if_not.dest

    # Find the phi node after the else branch
    phi_idx = nothing
    for j in else_target:length(code)
        if code[j] isa Core.PhiNode
            phi_idx = j
            break
        end
        if code[j] isa Core.GotoIfNot || (code[j] isa Core.Expr && code[j].head === :call)
            break  # Past the ternary
        end
    end

    if phi_idx === nothing
        # No phi - this might be a void conditional inside, just skip
        push!(compiled, cond_idx)
        return builder_code(b)
    end

    phi_node = code[phi_idx]::Core.PhiNode

    # Check if we have a local for this phi
    if !haskey(ctx.phi_locals, phi_idx)
        push!(compiled, cond_idx)
        push!(compiled, phi_idx)
        return builder_code(b)
    end

    local_idx = ctx.phi_locals[phi_idx]
    # PURE-048: Use ssavaluetypes fallback instead of Int64 default
    phi_type = get(ctx.ssa_types, phi_idx, nothing)
    if phi_type === nothing
        ssatypes = ctx.code_info.ssavaluetypes
        phi_type = (ssatypes isa Vector && phi_idx <= length(ssatypes)) ? ssatypes[phi_idx] : Int64
    end
    wasm_type = julia_to_wasm_type_concrete(phi_type, ctx)

    # Push condition
    emit_raw!(b, compile_condition_to_i32(goto_if_not.cond, ctx); pushes=WasmValType[I32])
    push!(compiled, cond_idx)

    # Start if block with result type
    if_!(b, wasm_type)

    # Get then-value from phi
    then_value = nothing
    else_value = nothing
    for (edge_idx, edge) in enumerate(phi_node.edges)
        if edge < else_target
            then_value = phi_node.values[edge_idx]
        else
            else_value = phi_node.values[edge_idx]
        end
    end

    # Then branch - push value
    if then_value !== nothing
        value_bytes = compile_value(then_value, ctx)
        # PURE-045: Check if compiled value's actual type matches expected block type
        # If value_bytes is local.get of a mismatched type, use type-safe default instead
        actual_type_mismatch = false
        if wasm_type isa ConcreteRef && length(value_bytes) >= 2 && value_bytes[1] == Opcode.LOCAL_GET
            # Decode local index
            src_idx = 0; shift = 0
            for bi in 2:length(value_bytes)
                byt = value_bytes[bi]
                src_idx |= (Int(byt & 0x7f) << shift)
                shift += 7
                (byt & 0x80) == 0 && break
            end
            src_arr_idx = src_idx - ctx.n_params + 1
            if src_arr_idx >= 1 && src_arr_idx <= length(ctx.locals)
                src_type = ctx.locals[src_arr_idx]
                if src_type isa ConcreteRef && src_type.type_idx != wasm_type.type_idx
                    actual_type_mismatch = true
                elseif !(src_type isa ConcreteRef) && src_type !== wasm_type
                    actual_type_mismatch = true
                end
            end
        end
        if actual_type_mismatch
            # Local type doesn't match expected - emit ref.null of expected type
            ref_null!(b, Int64(wasm_type.type_idx), ConcreteRef(UInt32(wasm_type.type_idx), true))
        else
            emit_raw!(b, value_bytes; pushes=(wasm_type === nothing ? WasmValType[] : WasmValType[wasm_type]))
            # Ensure value matches block type
            if wasm_type === I32 && !isempty(value_bytes) && value_bytes[1] == Opcode.I64_CONST
                num!(b, Opcode.I32_WRAP_I64)
            elseif wasm_type === I64 && !isempty(value_bytes) && value_bytes[1] == Opcode.I32_CONST
                num!(b, Opcode.I64_EXTEND_I32_S)
            end
        end
    else
        # Fallback: emit type-safe default matching the block type
        if wasm_type === I32
            i32_const!(b, 0)
        elseif wasm_type === F64
            f64_const!(b, 0.0)
        elseif wasm_type === F32
            f32_const!(b, 0.0f0)
        elseif wasm_type isa ConcreteRef
            ref_null!(b, Int64(wasm_type.type_idx), ConcreteRef(UInt32(wasm_type.type_idx), true))
        elseif wasm_type === StructRef || wasm_type === ArrayRef || wasm_type === ExternRef || wasm_type === AnyRef
            ref_null!(b, wasm_type)
        else
            i64_const!(b, 0)
        end
    end

    # Else branch
    else_!(b)

    # Else branch - push value
    if else_value !== nothing
        value_bytes = compile_value(else_value, ctx)
        # PURE-045: Check if compiled value's actual type matches expected block type
        # If value_bytes is local.get of a mismatched type, use type-safe default instead
        actual_type_mismatch = false
        if wasm_type isa ConcreteRef && length(value_bytes) >= 2 && value_bytes[1] == Opcode.LOCAL_GET
            # Decode local index
            src_idx = 0; shift = 0
            for bi in 2:length(value_bytes)
                byt = value_bytes[bi]
                src_idx |= (Int(byt & 0x7f) << shift)
                shift += 7
                (byt & 0x80) == 0 && break
            end
            src_arr_idx = src_idx - ctx.n_params + 1
            if src_arr_idx >= 1 && src_arr_idx <= length(ctx.locals)
                src_type = ctx.locals[src_arr_idx]
                if src_type isa ConcreteRef && src_type.type_idx != wasm_type.type_idx
                    actual_type_mismatch = true
                elseif !(src_type isa ConcreteRef) && src_type !== wasm_type
                    actual_type_mismatch = true
                end
            end
        end
        if actual_type_mismatch
            # Local type doesn't match expected - emit ref.null of expected type
            ref_null!(b, Int64(wasm_type.type_idx), ConcreteRef(UInt32(wasm_type.type_idx), true))
        else
            emit_raw!(b, value_bytes; pushes=(wasm_type === nothing ? WasmValType[] : WasmValType[wasm_type]))
            # Ensure value matches block type
            if wasm_type === I32 && !isempty(value_bytes) && value_bytes[1] == Opcode.I64_CONST
                num!(b, Opcode.I32_WRAP_I64)
            elseif wasm_type === I64 && !isempty(value_bytes) && value_bytes[1] == Opcode.I32_CONST
                num!(b, Opcode.I64_EXTEND_I32_S)
            end
        end
    else
        # Fallback: emit type-safe default matching the block type
        if wasm_type === I32
            i32_const!(b, 0)
        elseif wasm_type === F64
            f64_const!(b, 0.0)
        elseif wasm_type === F32
            f32_const!(b, 0.0f0)
        elseif wasm_type isa ConcreteRef
            ref_null!(b, Int64(wasm_type.type_idx), ConcreteRef(UInt32(wasm_type.type_idx), true))
        elseif wasm_type === StructRef || wasm_type === ArrayRef || wasm_type === ExternRef || wasm_type === AnyRef
            ref_null!(b, wasm_type)
        else
            i64_const!(b, 0)
        end
    end

    end_block!(b)

    # Store result to phi local
    local_set!(b, local_idx)

    # Mark the GotoNode, nothing, and phi as compiled
    for j in cond_idx+1:phi_idx
        push!(compiled, j)
    end

    return builder_code(b)
end

"""
Generate code for a single basic block.
"""
@inline function generate_block_code(ctx::AbstractCompilationContext, block::BasicBlock)::Vector{UInt8}
    b = InstrBuilder(; func_name="generate_block_code", strict=false)
    code = ctx.code_info.code

    for i in block.start_idx:block.end_idx
        stmt_bytes = compile_statement(code[i], i, ctx)
        emit_raw!(b, stmt_bytes)
    end

    return builder_code(b)
end

