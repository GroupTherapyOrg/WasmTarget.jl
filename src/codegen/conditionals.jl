"""
Generate code for complex functions using a block-based approach.
Compiles each basic block exactly once using structured control flow.
This is a simpler approach than full Stackifier, suitable for moderate complexity.
"""
function generate_linear_flow(ctx::CompilationContext, blocks::Vector{BasicBlock}, code, conditionals)::Vector{UInt8}
    bytes = UInt8[]
    result_type = julia_to_wasm_type_concrete(ctx.return_type, ctx)

    # Count SSA uses for drop logic
    ssa_use_count = Dict{Int, Int}()
    for stmt in code
        count_ssa_uses!(stmt, ssa_use_count)
    end

    # Track which statements have been compiled
    compiled = Set{Int}()

    # Find all GotoIfNot destinations to create block structure
    # This helps with forward jumps
    jump_targets = Set{Int}()
    for (i, stmt) in enumerate(code)
        if stmt isa Core.GotoIfNot
            push!(jump_targets, stmt.dest)
        elseif stmt isa Core.GotoNode && stmt.label > i
            push!(jump_targets, stmt.label)
        end
    end

    # Helper to compile a range of statements
    function compile_range(start_idx::Int, end_idx::Int)::Vector{UInt8}
        range_bytes = UInt8[]

        for i in start_idx:min(end_idx, length(code))
            if i in compiled
                continue
            end

            stmt = code[i]

            if stmt isa Core.ReturnNode
                push!(compiled, i)
                if isdefined(stmt, :val)
                    val_wasm_type = infer_value_wasm_type(stmt.val, ctx)
                    ret_wasm_type = julia_to_wasm_type_concrete(ctx.return_type, ctx)
                    func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                    # PURE-315: Check numeric-to-ref BEFORE return_type_compatible
                    is_numeric_val = val_wasm_type === I32 || val_wasm_type === I64 || val_wasm_type === F32 || val_wasm_type === F64
                    is_ref_ret = func_ret_wasm isa ConcreteRef || func_ret_wasm === ExternRef || func_ret_wasm === StructRef || func_ret_wasm === ArrayRef || func_ret_wasm === AnyRef
                    if is_numeric_val && is_ref_ret
                        if func_ret_wasm === ExternRef
                            emit_numeric_to_externref!(range_bytes, stmt.val, val_wasm_type, ctx)
                        elseif func_ret_wasm isa ConcreteRef
                            push!(range_bytes, Opcode.REF_NULL)
                            append!(range_bytes, encode_leb128_signed(Int64(func_ret_wasm.type_idx)))
                        else
                            push!(range_bytes, Opcode.REF_NULL)
                            push!(range_bytes, UInt8(func_ret_wasm))
                        end
                        push!(range_bytes, Opcode.RETURN)
                    elseif !return_type_compatible(val_wasm_type, func_ret_wasm)
                        push!(range_bytes, Opcode.UNREACHABLE)
                    else
                        append!(range_bytes, compile_value(stmt.val, ctx))
                        if func_ret_wasm === ExternRef && val_wasm_type !== ExternRef
                            push!(range_bytes, Opcode.GC_PREFIX)
                            push!(range_bytes, Opcode.EXTERN_CONVERT_ANY)
                        elseif val_wasm_type === I32 && func_ret_wasm === I64
                            push!(range_bytes, Opcode.I64_EXTEND_I32_S)
                        elseif val_wasm_type === I64 && func_ret_wasm === F64
                            push!(range_bytes, Opcode.F64_CONVERT_I64_S)
                        elseif val_wasm_type === I32 && func_ret_wasm === F64
                            push!(range_bytes, Opcode.F64_CONVERT_I32_S)
                        elseif val_wasm_type === F32 && func_ret_wasm === F64
                            push!(range_bytes, Opcode.F64_PROMOTE_F32)
                        elseif val_wasm_type === I64 && func_ret_wasm === F32
                            push!(range_bytes, Opcode.F32_CONVERT_I64_S)
                        elseif val_wasm_type === I32 && func_ret_wasm === F32
                            push!(range_bytes, Opcode.F32_CONVERT_I32_S)
                        end
                        push!(range_bytes, Opcode.RETURN)
                    end
                else
                    push!(range_bytes, Opcode.RETURN)
                end
                return range_bytes  # Return immediately

            elseif stmt isa Core.GotoIfNot
                push!(compiled, i)
                # Compile condition
                append!(range_bytes, compile_condition_to_i32(stmt.cond, ctx))

                # Check if then branch has a return
                then_end = stmt.dest - 1
                then_has_return = any(code[j] isa Core.ReturnNode for j in (i+1):min(then_end, length(code)))

                # Create if/else for the branch
                push!(range_bytes, Opcode.IF)
                push!(range_bytes, 0x40)  # void

                # Then branch: condition true, continue to next line
                append!(range_bytes, compile_range(i + 1, then_end))

                push!(range_bytes, Opcode.ELSE)

                # Else branch: condition false, jump to dest
                # If then branch returns, else branch handles the rest
                # Otherwise, both branches should reach the merge point
                if then_has_return
                    # Else branch handles all remaining code
                    append!(range_bytes, compile_range(stmt.dest, end_idx))
                else
                    # Both branches continue to merge point
                    # Else is empty (code at dest will be compiled after END)
                end

                push!(range_bytes, Opcode.END)

                if then_has_return
                    return range_bytes  # Else already handled the rest
                end
                # Otherwise continue - code at merge point follows

            elseif stmt isa Core.GotoNode
                push!(compiled, i)
                # Skip forward gotos - the target will be compiled in the else branch
                # For now, just continue

            elseif stmt isa Core.PhiNode
                push!(compiled, i)
                # Phi values are handled via locals, nothing to do here

            elseif stmt === nothing
                push!(compiled, i)

            else
                push!(compiled, i)
                stmt_bytes = compile_statement(stmt, i, ctx)
                append!(range_bytes, stmt_bytes)

                # PURE-6024: Skip remaining statements after unreachable.
                stmt_type_nc = get(ctx.ssa_types, i, Any)
                if stmt_type_nc === Union{} || ctx.last_stmt_was_stub
                    return range_bytes
                end

                # Drop unused values
                if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                    stmt_type = get(ctx.ssa_types, i, Any)
                    if stmt_type !== Nothing
                        is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                        if !is_nothing_union
                            if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                                use_count = get(ssa_use_count, i, 0)
                                if use_count == 0
                                    push!(range_bytes, Opcode.DROP)
                                end
                            end
                        end
                    end
                end
            end
        end

        return range_bytes
    end

    # Compile all code starting from line 1
    append!(bytes, compile_range(1, length(code)))

    # The code should always end with a return, but add unreachable as safety
    push!(bytes, Opcode.UNREACHABLE)

    return bytes
end

"""
Generate code for void functions (no return value).
Compiles all statements sequentially, using structured control flow for conditionals.
"""
function generate_void_flow(ctx::CompilationContext, blocks::Vector{BasicBlock}, code)::Vector{UInt8}
    bytes = UInt8[]

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
                    end
                end
            end
            push!(bytes, Opcode.RETURN)
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
            append!(bytes, compile_condition_to_i32(goto_if_not.cond, ctx))
            push!(compiled, i)

            # Start void if block
            push!(bytes, Opcode.IF)
            push!(bytes, 0x40)

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
                            emit_numeric_to_externref!(bytes, inner.val, val_wasm, ctx)
                        else
                            append!(bytes, compile_value(inner.val, ctx))
                            if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                                push!(bytes, Opcode.GC_PREFIX)
                                push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                            end
                        end
                    end
                    # BUT: If the return type is Union{} (unreachable), don't emit RETURN
                    stmt_type = get(ctx.ssa_types, j, Any)
                    if stmt_type !== Union{}
                        push!(bytes, Opcode.RETURN)
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
                        append!(bytes, compile_ternary_for_phi(ctx, code, j, compiled))
                    else
                        # Regular nested conditional in void context (from && operator)
                        append!(bytes, compile_void_nested_conditional(ctx, code, j, compiled, ssa_use_count))
                    end
                elseif inner isa Core.PhiNode
                    # Phi already handled by compile_ternary_for_phi if it was part of a ternary
                    # If not handled, just skip it
                    push!(compiled, j)
                else
                    compiled_bytes = compile_statement(inner, j, ctx)
                    append!(bytes, compiled_bytes)
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
                            push!(bytes, Opcode.DROP)
                        elseif !already_has_drop
                            # For other calls, check if statement produces a value and use count
                            if statement_produces_wasm_value(inner, j, ctx)
                                if !haskey(ctx.ssa_locals, j) && !haskey(ctx.phi_locals, j)
                                    use_count = get(ssa_use_count, j, 0)
                                    if use_count == 0
                                        push!(bytes, Opcode.DROP)
                                    end
                                end
                            end
                        end
                    end
                end
            end

            if has_else_branch
                # Else branch - only emit when there's actual else code
                push!(bytes, Opcode.ELSE)

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
                                    emit_numeric_to_externref!(bytes, inner.val, val_wasm, ctx)
                                else
                                    append!(bytes, compile_value(inner.val, ctx))
                                    if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                                        push!(bytes, Opcode.GC_PREFIX)
                                        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                                    end
                                end
                            end
                            push!(bytes, Opcode.RETURN)
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
                            append!(bytes, compile_ternary_for_phi(ctx, code, j, compiled))
                        else
                            append!(bytes, compile_void_nested_conditional(ctx, code, j, compiled, ssa_use_count))
                        end
                    elseif inner isa Core.PhiNode
                        # Phi already handled by compile_ternary_for_phi
                        push!(compiled, j)
                    else
                        append!(bytes, compile_statement(inner, j, ctx))
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
                                if !is_nothing_union
                                    if !haskey(ctx.ssa_locals, j) && !haskey(ctx.phi_locals, j)
                                        use_count = get(ssa_use_count, j, 0)
                                        if use_count == 0
                                            push!(bytes, Opcode.DROP)
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

                push!(bytes, Opcode.END)
                i = else_end + 1
            else
                # No else branch - just end the if block and continue from else_target
                # Mark only the then-branch as compiled, else_target onwards will be processed
                # by the main loop
                for j in i:(else_target-1)
                    push!(compiled, j)
                end

                push!(bytes, Opcode.END)
                i = else_target
            end
            continue
        end

        # Regular statement
        append!(bytes, compile_statement(stmt, i, ctx))
        push!(compiled, i)

        # Check if this statement produces Union{} (never returns, e.g., throw)
        # If so, stop compiling - any code after is dead code
        stmt_type = get(ctx.ssa_types, i, Any)
        if stmt_type === Union{}
            # Don't add more code, just return what we have
            # The function ends with unreachable code path
            return bytes
        end

        # Drop unused values from statements that produce values
        if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
            stmt_type = get(ctx.ssa_types, i, Nothing)
            if stmt_type !== Nothing  # Only skip if type is definitely Nothing
                is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                if !is_nothing_union
                    if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                        use_count = get(ssa_use_count, i, 0)
                        if use_count == 0
                            push!(bytes, Opcode.DROP)
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
                        push!(bytes, Opcode.DROP)
                    end
                end
            end
        end

        i += 1
    end

    # Final return (in case we didn't hit one)
    push!(bytes, Opcode.RETURN)

    return bytes
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
function compile_void_nested_conditional(ctx::CompilationContext, code, start_idx::Int, compiled::Set{Int}, ssa_use_count::Dict{Int,Int})::Vector{UInt8}
    bytes = UInt8[]

    goto_if_not = code[start_idx]::Core.GotoIfNot
    end_target = goto_if_not.dest

    # Push condition
    append!(bytes, compile_condition_to_i32(goto_if_not.cond, ctx))
    push!(compiled, start_idx)

    # Start void if block
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)  # void block type

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
                        emit_numeric_to_externref!(bytes, inner.val, val_wasm, ctx)
                    else
                        append!(bytes, compile_value(inner.val, ctx))
                        if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                        end
                    end
                end
                push!(bytes, Opcode.RETURN)
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
                append!(bytes, compile_ternary_for_phi(ctx, code, j, compiled))
            else
                # RECURSION: Another conditional (from && chain)
                append!(bytes, compile_void_nested_conditional(ctx, code, j, compiled, ssa_use_count))
            end
        elseif inner isa Core.PhiNode
            # Phi already handled by compile_ternary_for_phi if it was part of a ternary
            push!(compiled, j)
        else
            # Regular statement (including setter calls)
            append!(bytes, compile_statement(inner, j, ctx))
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
                    push!(bytes, Opcode.DROP)
                else
                    stmt_type = get(ctx.ssa_types, j, Nothing)
                    if stmt_type !== Nothing  # Only skip if type is definitely Nothing
                        is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                        if !is_nothing_union
                            if !haskey(ctx.ssa_locals, j) && !haskey(ctx.phi_locals, j)
                                use_count = get(ssa_use_count, j, 0)
                                if use_count == 0
                                    push!(bytes, Opcode.DROP)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    # End if block (no else for && pattern - false case just skips)
    push!(bytes, Opcode.END)

    return bytes
end

"""
Compile a ternary expression (if-then-else with phi) that produces a value.
Returns bytecode that computes the ternary and stores to the phi local.
"""
function compile_ternary_for_phi(ctx::CompilationContext, code, cond_idx::Int, compiled::Set{Int})::Vector{UInt8}
    bytes = UInt8[]

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
        return bytes
    end

    phi_node = code[phi_idx]::Core.PhiNode

    # Check if we have a local for this phi
    if !haskey(ctx.phi_locals, phi_idx)
        push!(compiled, cond_idx)
        push!(compiled, phi_idx)
        return bytes
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
    append!(bytes, compile_condition_to_i32(goto_if_not.cond, ctx))
    push!(compiled, cond_idx)

    # Start if block with result type
    push!(bytes, Opcode.IF)
    append!(bytes, encode_block_type(wasm_type))

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
                b = value_bytes[bi]
                src_idx |= (Int(b & 0x7f) << shift)
                shift += 7
                (b & 0x80) == 0 && break
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
            push!(bytes, Opcode.REF_NULL)
            append!(bytes, encode_leb128_signed(Int64(wasm_type.type_idx)))
        else
            append!(bytes, value_bytes)
            # Ensure value matches block type
            if wasm_type === I32 && !isempty(value_bytes) && value_bytes[1] == Opcode.I64_CONST
                push!(bytes, Opcode.I32_WRAP_I64)
            elseif wasm_type === I64 && !isempty(value_bytes) && value_bytes[1] == Opcode.I32_CONST
                push!(bytes, Opcode.I64_EXTEND_I32_S)
            end
        end
    else
        # Fallback: emit type-safe default matching the block type
        if wasm_type === I32
            push!(bytes, Opcode.I32_CONST)
            push!(bytes, 0x00)
        elseif wasm_type === F64
            push!(bytes, Opcode.F64_CONST)
            append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        elseif wasm_type === F32
            push!(bytes, Opcode.F32_CONST)
            append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00])
        elseif wasm_type isa ConcreteRef
            push!(bytes, Opcode.REF_NULL)
            append!(bytes, encode_leb128_signed(Int64(wasm_type.type_idx)))
        elseif wasm_type === StructRef || wasm_type === ArrayRef || wasm_type === ExternRef || wasm_type === AnyRef
            push!(bytes, Opcode.REF_NULL)
            push!(bytes, UInt8(wasm_type))
        else
            push!(bytes, Opcode.I64_CONST)
            push!(bytes, 0x00)
        end
    end

    # Else branch
    push!(bytes, Opcode.ELSE)

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
                b = value_bytes[bi]
                src_idx |= (Int(b & 0x7f) << shift)
                shift += 7
                (b & 0x80) == 0 && break
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
            push!(bytes, Opcode.REF_NULL)
            append!(bytes, encode_leb128_signed(Int64(wasm_type.type_idx)))
        else
            append!(bytes, value_bytes)
            # Ensure value matches block type
            if wasm_type === I32 && !isempty(value_bytes) && value_bytes[1] == Opcode.I64_CONST
                push!(bytes, Opcode.I32_WRAP_I64)
            elseif wasm_type === I64 && !isempty(value_bytes) && value_bytes[1] == Opcode.I32_CONST
                push!(bytes, Opcode.I64_EXTEND_I32_S)
            end
        end
    else
        # Fallback: emit type-safe default matching the block type
        if wasm_type === I32
            push!(bytes, Opcode.I32_CONST)
            push!(bytes, 0x00)
        elseif wasm_type === F64
            push!(bytes, Opcode.F64_CONST)
            append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        elseif wasm_type === F32
            push!(bytes, Opcode.F32_CONST)
            append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00])
        elseif wasm_type isa ConcreteRef
            push!(bytes, Opcode.REF_NULL)
            append!(bytes, encode_leb128_signed(Int64(wasm_type.type_idx)))
        elseif wasm_type === StructRef || wasm_type === ArrayRef || wasm_type === ExternRef || wasm_type === AnyRef
            push!(bytes, Opcode.REF_NULL)
            push!(bytes, UInt8(wasm_type))
        else
            push!(bytes, Opcode.I64_CONST)
            push!(bytes, 0x00)
        end
    end

    push!(bytes, Opcode.END)

    # Store result to phi local
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(local_idx))

    # Mark the GotoNode, nothing, and phi as compiled
    for j in cond_idx+1:phi_idx
        push!(compiled, j)
    end

    return bytes
end

"""
Generate code for && pattern: multiple conditionals all jumping to the same else target.
Uses block/br_if structure:
  block \$outer [result_type]
    block \$else_target []
      cond1; i32.eqz; br_if 0   ;; if false, jump to else
      cond2; i32.eqz; br_if 0   ;; if false, jump to else
      <then_code>; br 1         ;; jump past else
    end
    <else_code>
  end
"""
function generate_and_pattern(ctx::CompilationContext, blocks, code, conditionals, result_type, else_target, ssa_use_count)::Vector{UInt8}
    bytes = UInt8[]

    # Outer block for result
    push!(bytes, Opcode.BLOCK)
    append!(bytes, encode_block_type(result_type))

    # Inner block for else jump target (void result)
    push!(bytes, Opcode.BLOCK)
    push!(bytes, 0x40)  # void result type

    # Generate each condition with br_if to else
    for (i, (block_idx, block)) in enumerate(conditionals)
        goto_if_not = block.terminator::Core.GotoIfNot

        # Generate statements before condition
        for j in block.start_idx:block.end_idx-1
            append!(bytes, compile_statement(code[j], j, ctx))

            # Drop unused values
            stmt = code[j]
            if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                stmt_type = get(ctx.ssa_types, j, Any)
                if stmt_type !== Nothing
                    is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                    if !is_nothing_union
                        if !haskey(ctx.ssa_locals, j) && !haskey(ctx.phi_locals, j)
                            use_count = get(ssa_use_count, j, 0)
                            if use_count == 0
                                push!(bytes, Opcode.DROP)
                            end
                        end
                    end
                end
            end
        end

        # Push condition and test for false (invert condition)
        append!(bytes, compile_condition_to_i32(goto_if_not.cond, ctx))
        push!(bytes, Opcode.I32_EQZ)  # invert: GotoIfNot jumps when false, so we br when !cond
        push!(bytes, Opcode.BR_IF)
        append!(bytes, encode_leb128_unsigned(0))  # br to inner block (else)
    end

    # All conditions passed - generate then code
    last_cond = conditionals[end]
    then_start = last_cond[2].end_idx + 1
    for i in then_start:else_target-1
        stmt = code[i]
        if stmt isa Core.ReturnNode
            # PURE-036ag: Handle valued ReturnNodes with externref conversion
            if isdefined(stmt, :val)
                func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64

                if func_ret_wasm === ExternRef && is_numeric_val
                    emit_numeric_to_externref!(bytes, stmt.val, val_wasm, ctx)
                else
                    append!(bytes, compile_value(stmt.val, ctx))
                    if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                    end
                end
            end
            break
        elseif stmt !== nothing && !(stmt isa Core.GotoIfNot) && !(stmt isa Core.GotoNode)
            append!(bytes, compile_statement(stmt, i, ctx))

            # Drop unused values
            if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                stmt_type = get(ctx.ssa_types, i, Any)
                if stmt_type !== Nothing
                    is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                    if !is_nothing_union
                        if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                            use_count = get(ssa_use_count, i, 0)
                            if use_count == 0
                                push!(bytes, Opcode.DROP)
                            end
                        end
                    end
                end
            end
        end
    end

    # Check if there's a phi node at or after else_target that we need to provide a value for
    phi_idx = nothing
    phi_node = nothing
    for i in else_target:length(code)
        if code[i] isa Core.PhiNode
            phi_idx = i
            phi_node = code[i]
            break
        end
    end

    # If there's a phi, push the then-value before branching
    if phi_node !== nothing
        # Find the phi value from the then-branch (before else_target)
        for (edge_idx, edge) in enumerate(phi_node.edges)
            if edge < else_target && edge > 0
                val = phi_node.values[edge_idx]
                # PURE-036ak: Check for externref conversion
                func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                val_wasm = get_phi_edge_wasm_type(val, ctx)
                is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                if func_ret_wasm === ExternRef && is_numeric_val
                    emit_numeric_to_externref!(bytes, val, val_wasm, ctx)
                else
                    append!(bytes, compile_value(val, ctx))
                    if func_ret_wasm === ExternRef && val_wasm !== ExternRef && val_wasm !== nothing
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                    end
                end
                break
            end
        end
    end

    # br past else to outer block end
    push!(bytes, Opcode.BR)
    append!(bytes, encode_leb128_unsigned(1))  # br to outer block (depth 1)

    # End inner block (else target)
    push!(bytes, Opcode.END)

    # Generate else code - if there's a phi, push its else-value directly
    if phi_node !== nothing
        # PURE-036ak: Get function return type for externref check
        func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
        # Find the phi value from an else-branch (at or after else_target)
        else_value_pushed = false
        for (edge_idx, edge) in enumerate(phi_node.edges)
            # Else edges come from conditionals that jump to else_target
            # These are the GotoIfNot statements - their line numbers are stored in edges
            edge_stmt = edge <= length(code) ? code[edge] : nothing
            if edge_stmt isa Core.GotoIfNot
                # This is an else-edge from a conditional
                val = phi_node.values[edge_idx]
                # PURE-036ak: Check for externref conversion
                val_wasm = get_phi_edge_wasm_type(val, ctx)
                is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                if func_ret_wasm === ExternRef && is_numeric_val
                    emit_numeric_to_externref!(bytes, val, val_wasm, ctx)
                else
                    append!(bytes, compile_value(val, ctx))
                    if func_ret_wasm === ExternRef && val_wasm !== ExternRef && val_wasm !== nothing
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                    end
                end
                else_value_pushed = true
                break
            end
        end
        if !else_value_pushed
            # Fallback: look for else-value (edge from else_target or later)
            for (edge_idx, edge) in enumerate(phi_node.edges)
                if edge >= else_target
                    val = phi_node.values[edge_idx]
                    # PURE-036ak: Check for externref conversion
                    val_wasm = get_phi_edge_wasm_type(val, ctx)
                    is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                    if func_ret_wasm === ExternRef && is_numeric_val
                        emit_numeric_to_externref!(bytes, val, val_wasm, ctx)
                    else
                        append!(bytes, compile_value(val, ctx))
                        if func_ret_wasm === ExternRef && val_wasm !== ExternRef && val_wasm !== nothing
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                        end
                    end
                    break
                end
            end
        end
    else
        # No phi - iterate through else code looking for return
        for i in else_target:length(code)
            stmt = code[i]
            if stmt isa Core.ReturnNode
                # PURE-036ag: Handle valued ReturnNodes with externref conversion
                if isdefined(stmt, :val)
                    func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                    val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                    is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64

                    if func_ret_wasm === ExternRef && is_numeric_val
                        emit_numeric_to_externref!(bytes, stmt.val, val_wasm, ctx)
                    else
                        append!(bytes, compile_value(stmt.val, ctx))
                        if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                        end
                    end
                end
                break
            elseif stmt !== nothing && !(stmt isa Core.GotoIfNot) && !(stmt isa Core.GotoNode)
                append!(bytes, compile_statement(stmt, i, ctx))

                # Drop unused values
                if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                    stmt_type = get(ctx.ssa_types, i, Any)
                    if stmt_type !== Nothing
                        is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                        if !is_nothing_union
                            if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                                use_count = get(ssa_use_count, i, 0)
                                if use_count == 0
                                    push!(bytes, Opcode.DROP)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    # End outer block
    push!(bytes, Opcode.END)

    # Add RETURN after the block
    push!(bytes, Opcode.RETURN)

    return bytes
end

"""
Detect switch pattern: sequential conditionals testing the same SSA value against different constants.
Pattern (switch on n):
  %cond1 = (n === 0)
  goto %else1 if not %cond1
  ... case 0 code with return ...
  %cond2 = (n === 1)
  goto %else2 if not %cond2
  ... case 1 code with return ...
  ...
Returns (switch_value_ssa, cases) where cases = [(cond_idx, const_val, case_start, case_end), ...]
"""
function detect_switch_pattern(code, conditionals)
    if length(conditionals) < 2
        return nothing
    end

    # Group conditionals by which SSA value they compare
    # Then find the best switch pattern (most cases with returns)
    switch_candidates = Dict{Int, Vector{Tuple{Int, Any, Int, Int}}}()  # ssa_id => cases

    for (i, (block_idx, block)) in enumerate(conditionals)
        gin = block.terminator::Core.GotoIfNot
        cond = gin.cond

        if !(cond isa Core.SSAValue)
            continue
        end
        # PURE-6021: Guard against out-of-bounds SSAValue IDs
        if cond.id < 1 || cond.id > length(code)
            continue
        end

        cond_stmt = code[cond.id]
        if !(cond_stmt isa Expr && cond_stmt.head === :call)
            continue
        end

        args = cond_stmt.args
        if length(args) < 3
            continue
        end

        # Check if it's an equality comparison
        func = args[1]
        is_eq = func isa GlobalRef && (func.name === :(===) || func.name === :(==))
        if !is_eq
            continue
        end

        lhs = args[2]
        rhs = args[3]

        # One side should be an SSA value (the switch value), other is a constant
        ssa_val = nothing
        const_val = nothing

        if lhs isa Core.SSAValue && !(rhs isa Core.SSAValue) && !(rhs isa Core.Argument)
            ssa_val = lhs
            const_val = rhs
        elseif rhs isa Core.SSAValue && !(lhs isa Core.SSAValue) && !(lhs isa Core.Argument)
            ssa_val = rhs
            const_val = lhs
        else
            continue
        end

        # Find the case code range (from gin line + 1 to gin.dest - 1)
        case_start = block.end_idx + 1
        case_end = gin.dest - 1

        # Check if this case has a return
        has_return = false
        for j in case_start:min(case_end, length(code))
            if code[j] isa Core.ReturnNode
                has_return = true
                break
            end
        end

        # Only consider cases with returns for the switch pattern
        if has_return
            ssa_id = ssa_val.id
            if !haskey(switch_candidates, ssa_id)
                switch_candidates[ssa_id] = []
            end
            push!(switch_candidates[ssa_id], (i, const_val, case_start, case_end))
        end
    end

    # Find the best switch pattern (most cases)
    best_switch = nothing
    best_cases = nothing

    for (ssa_id, cases) in switch_candidates
        if length(cases) >= 2
            if best_cases === nothing || length(cases) > length(best_cases)
                best_switch = ssa_id
                best_cases = cases
            end
        end
    end

    if best_switch !== nothing && best_cases !== nothing
        return (best_switch, best_cases)
    end

    return nothing
end

"""
Generate code for switch pattern using nested if-else with proper stack handling.
Each case returns independently, so we don't need phi handling for the switch itself.
"""
function generate_switch_pattern(ctx::CompilationContext, blocks, code, conditionals, result_type, switch_pattern, ssa_use_count)::Vector{UInt8}
    bytes = UInt8[]
    switch_value_ssa, cases = switch_pattern

    # First, compile any statements before the switch (up to the first case condition)
    first_case_idx = cases[1][1]
    first_block_idx, first_block = conditionals[first_case_idx]

    # Find the actual first conditional
    first_cond_idx = conditionals[1][2].start_idx
    for i in 1:first_cond_idx-1
        stmt = code[i]
        if stmt !== nothing && !(stmt isa Core.GotoIfNot) && !(stmt isa Core.GotoNode) && !(stmt isa Core.PhiNode)
            append!(bytes, compile_statement(stmt, i, ctx))

            # Handle SSA storage and drops
            if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                stmt_type = get(ctx.ssa_types, i, Any)
                if stmt_type !== Nothing
                    is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                    if !is_nothing_union
                        if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                            use_count = get(ssa_use_count, i, 0)
                            if use_count == 0
                                push!(bytes, Opcode.DROP)
                            end
                        end
                    end
                end
            end
        end
    end

    # Generate switch as nested if-else, but with each case having its own return
    # This ensures no code duplication - each case is visited exactly once
    function gen_case(case_idx::Int)::Vector{UInt8}
        inner_bytes = UInt8[]

        if case_idx > length(cases)
            # Default case: code after all switch cases
            # Find where the default case starts (after the last case's else target)
            last_case = cases[end]
            last_cond_idx = last_case[1]
            _, last_block = conditionals[last_cond_idx]
            default_start = last_block.terminator.dest

            for i in default_start:length(code)
                stmt = code[i]
                if stmt isa Core.ReturnNode
                    if isdefined(stmt, :val)
                        # PURE-036ai: Handle numeric-to-externref case
                        func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                        val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                        is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                        if func_ret_wasm === ExternRef && is_numeric_val
                            emit_numeric_to_externref!(inner_bytes, stmt.val, val_wasm, ctx)
                        else
                            append!(inner_bytes, compile_value(stmt.val, ctx))
                            if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                                push!(inner_bytes, Opcode.GC_PREFIX)
                                push!(inner_bytes, Opcode.EXTERN_CONVERT_ANY)
                            end
                        end
                    end
                    break
                elseif stmt === nothing || stmt isa Core.PhiNode || stmt isa Core.GotoIfNot || stmt isa Core.GotoNode
                    continue
                else
                    append!(inner_bytes, compile_statement(stmt, i, ctx))

                    if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                        stmt_type = get(ctx.ssa_types, i, Any)
                        if stmt_type !== Nothing
                            is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                            if !is_nothing_union
                                if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                                    use_count = get(ssa_use_count, i, 0)
                                    if use_count == 0
                                        push!(inner_bytes, Opcode.DROP)
                                    end
                                end
                            end
                        end
                    end
                end
            end

            return inner_bytes
        end

        cond_idx, const_val, case_start, case_end = cases[case_idx]
        block_idx, block = conditionals[cond_idx]
        gin = block.terminator::Core.GotoIfNot

        # Compile statements in this block (before condition check)
        for i in block.start_idx:block.end_idx-1
            stmt = code[i]
            if stmt !== nothing && !(stmt isa Core.GotoIfNot) && !(stmt isa Core.GotoNode) && !(stmt isa Core.PhiNode)
                append!(inner_bytes, compile_statement(stmt, i, ctx))

                if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                    stmt_type = get(ctx.ssa_types, i, Any)
                    if stmt_type !== Nothing
                        is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                        if !is_nothing_union
                            if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                                use_count = get(ssa_use_count, i, 0)
                                if use_count == 0
                                    push!(inner_bytes, Opcode.DROP)
                                end
                            end
                        end
                    end
                end
            end
        end

        # Compile the condition
        append!(inner_bytes, compile_condition_to_i32(gin.cond, ctx))

        # IF with result type (since each case returns a value)
        push!(inner_bytes, Opcode.IF)
        append!(inner_bytes, encode_block_type(result_type))

        # Then branch: this case's code (should end with return value on stack)
        for i in case_start:min(case_end, length(code))
            stmt = code[i]
            if stmt isa Core.ReturnNode
                if isdefined(stmt, :val)
                    # PURE-036ai: Handle numeric-to-externref case
                    func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                    val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                    is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                    if func_ret_wasm === ExternRef && is_numeric_val
                        emit_numeric_to_externref!(inner_bytes, stmt.val, val_wasm, ctx)
                    else
                        append!(inner_bytes, compile_value(stmt.val, ctx))
                        if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                            push!(inner_bytes, Opcode.GC_PREFIX)
                            push!(inner_bytes, Opcode.EXTERN_CONVERT_ANY)
                        end
                    end
                end
                break
            elseif stmt === nothing || stmt isa Core.PhiNode || stmt isa Core.GotoIfNot || stmt isa Core.GotoNode
                continue
            else
                append!(inner_bytes, compile_statement(stmt, i, ctx))

                if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                    stmt_type = get(ctx.ssa_types, i, Any)
                    if stmt_type !== Nothing
                        is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                        if !is_nothing_union
                            if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                                use_count = get(ssa_use_count, i, 0)
                                if use_count == 0
                                    push!(inner_bytes, Opcode.DROP)
                                end
                            end
                        end
                    end
                end
            end
        end

        # Else branch: recurse to next case
        push!(inner_bytes, Opcode.ELSE)
        append!(inner_bytes, gen_case(case_idx + 1))

        push!(inner_bytes, Opcode.END)

        return inner_bytes
    end

    append!(bytes, gen_case(1))
    push!(bytes, Opcode.RETURN)

    return bytes
end

"""
Detect OR pattern: multiple conditionals where each then-branch jumps to the same phi node.
Returns (phi_idx, or_conditions, next_conditional_idx) or nothing.

OR pattern IR example (a || b || c):
  1: a
  2: goto %4 if not %1
  3: goto %9  (then-branch)
  4: b
  5: goto %7 if not %4
  6: goto %9  (then-branch)
  7: c
  8: goto %9
  9: φ (%3 => %1, %6 => %4, %8 => %7)
  10: goto %N if not %9  (uses the phi)
"""
function detect_or_pattern(code, conditionals, ssa_types)
    if length(conditionals) < 1
        return nothing
    end

    # For each conditional, check if the then-branch (fall-through) has a GotoNode
    # that jumps to a phi node
    phi_targets = Dict{Int, Vector{Tuple{Int, Int}}}()  # phi_idx => [(cond_idx, goto_idx), ...]

    for (cond_idx, (block_idx, block)) in enumerate(conditionals)
        goto_if_not = block.terminator::Core.GotoIfNot
        then_start = block.end_idx + 1
        else_target = goto_if_not.dest
        then_end = else_target - 1

        # Look for GotoNode in then-branch
        for i in then_start:min(then_end, length(code))
            stmt = code[i]
            if stmt isa Core.GotoNode && stmt.label > i
                target = stmt.label
                if target <= length(code) && code[target] isa Core.PhiNode
                    # Found a then-branch GotoNode to a phi
                    if !haskey(phi_targets, target)
                        phi_targets[target] = []
                    end
                    push!(phi_targets[target], (cond_idx, i))
                end
                break
            end
        end
    end

    # Check if we have a phi with multiple incoming OR conditions
    # Return the FIRST one (lowest phi_idx) to process patterns in code order
    best_phi_idx = nothing
    best_cond_infos = nothing
    best_next_cond_idx = nothing

    for (phi_idx, cond_infos) in phi_targets
        if length(cond_infos) >= 2
            # Only consider if this is earlier than our current best
            if best_phi_idx === nothing || phi_idx < best_phi_idx
                # Found an OR pattern - verify all edges are from these conditions
                phi_stmt = code[phi_idx]::Core.PhiNode

                # CRITICAL: Only treat as OR pattern if the phi type is Bool
                # Non-boolean phi nodes with multiple edges should not be handled as OR patterns
                phi_type = get(ssa_types, phi_idx, nothing)
                if phi_type !== Bool
                    continue  # Skip non-boolean phi nodes
                end

                # Find the conditional that USES this phi (tests the OR result)
                next_cond_idx = nothing
                for (j, (_, b)) in enumerate(conditionals)
                    goto_if_not = b.terminator::Core.GotoIfNot
                    if goto_if_not.cond isa Core.SSAValue && goto_if_not.cond.id == phi_idx
                        next_cond_idx = j
                        break
                    end
                end

                best_phi_idx = phi_idx
                best_cond_infos = cond_infos
                best_next_cond_idx = next_cond_idx
            end
        end
    end

    if best_phi_idx !== nothing
        return (best_phi_idx, best_cond_infos, best_next_cond_idx)
    end

    return nothing
end

"""
Generate code for OR pattern (a || b || c producing boolean phi).
Creates nested if-else structure that evaluates each condition.
"""
function generate_or_pattern(ctx::CompilationContext, blocks, code, conditionals, result_type, or_pattern, ssa_use_count)::Vector{UInt8}
    bytes = UInt8[]
    phi_idx, cond_infos, next_cond_idx = or_pattern
    phi_stmt = code[phi_idx]::Core.PhiNode

    # Sort conditions by their index (they should be in order)
    sorted_conds = sort(cond_infos, by=x -> x[1])

    # Helper to generate code for OR condition at index i
    function gen_or_cond(idx::Int)::Vector{UInt8}
        inner_bytes = UInt8[]

        if idx > length(sorted_conds)
            # Last condition (the one without a GotoNode in then-branch)
            # Find the last edge in the phi - this is the final condition value
            last_edge = nothing
            last_val = nothing
            for (edge_idx, edge) in enumerate(phi_stmt.edges)
                # Find edge that's not from one of the GotoNode lines
                is_goto_edge = any(ci -> ci[2] == edge, sorted_conds)
                if !is_goto_edge
                    last_edge = edge
                    last_val = phi_stmt.values[edge_idx]
                    break
                end
            end

            if last_val !== nothing
                # For SSAValue with no local, we need to compile the statement
                if last_val isa Core.SSAValue && !haskey(ctx.ssa_locals, last_val.id) && !haskey(ctx.phi_locals, last_val.id)
                    # Compile the statement for this SSA value
                    stmt = code[last_val.id]
                    if stmt !== nothing
                        append!(inner_bytes, compile_statement(stmt, last_val.id, ctx))
                    end
                else
                    # Has a local or is not SSAValue - use compile_value
                    append!(inner_bytes, compile_value(last_val, ctx))
                end
            else
                # Fallback - push false
                push!(inner_bytes, Opcode.I32_CONST)
                append!(inner_bytes, encode_leb128_signed(0))
            end

            return inner_bytes
        end

        cond_idx, goto_line = sorted_conds[idx]
        block_idx, block = conditionals[cond_idx]
        goto_if_not = block.terminator::Core.GotoIfNot

        # Generate all statements in the block (including the condition)
        # compile_statement will store to local if needed, then compile_value will load
        for j in block.start_idx:block.end_idx-1
            stmt = code[j]
            if stmt !== nothing && !(stmt isa Core.GotoIfNot) && !(stmt isa Core.GotoNode) && !(stmt isa Core.PhiNode)
                append!(inner_bytes, compile_statement(stmt, j, ctx))
            end
        end

        # Push condition (will load from local if multi-use, or assume on stack if single-use)
        append!(inner_bytes, compile_condition_to_i32(goto_if_not.cond, ctx))

        # IF with i32 result (for the phi value)
        push!(inner_bytes, Opcode.IF)
        push!(inner_bytes, 0x7f)  # i32 result type

        # Then-branch: condition was true
        # For || pattern, phi value = condition = true = 1
        # We push constant 1 instead of trying to re-compile the condition
        push!(inner_bytes, Opcode.I32_CONST)
        append!(inner_bytes, encode_leb128_signed(1))

        # Else-branch: condition was false, evaluate next condition
        push!(inner_bytes, Opcode.ELSE)
        append!(inner_bytes, gen_or_cond(idx + 1))

        push!(inner_bytes, Opcode.END)

        return inner_bytes
    end

    # Generate the nested OR conditions
    append!(bytes, gen_or_cond(1))

    # Store result in phi local
    if haskey(ctx.phi_locals, phi_idx)
        local_idx = ctx.phi_locals[phi_idx]
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(local_idx))
    end

    # Now continue with the conditional that uses the phi
    if next_cond_idx !== nothing
        # Generate the rest of the conditionals starting from next_cond_idx
        remaining_conds = [(i, conditionals[i]) for i in next_cond_idx:length(conditionals)]
        if !isempty(remaining_conds)
            # Generate remaining conditionals recursively
            append!(bytes, generate_remaining_conditionals(ctx, blocks, code, remaining_conds, result_type, ssa_use_count))
        end
    end

    return bytes
end

"""
Generate code for remaining conditionals after OR pattern.
"""
function generate_remaining_conditionals(ctx::CompilationContext, blocks, code, remaining_conds, result_type, ssa_use_count)::Vector{UInt8}
    bytes = UInt8[]

    if isempty(remaining_conds)
        return bytes
    end

    _, (block_idx, block) = remaining_conds[1]
    goto_if_not = block.terminator::Core.GotoIfNot

    # Push condition (which might be a phi local)
    append!(bytes, compile_condition_to_i32(goto_if_not.cond, ctx))

    # Generate IF
    push!(bytes, Opcode.IF)
    append!(bytes, encode_block_type(result_type))

    # Then-branch: generate code from block.end_idx + 1 to goto_if_not.dest - 1
    then_start = block.end_idx + 1
    then_end = goto_if_not.dest - 1

    for i in then_start:min(then_end, length(code))
        stmt = code[i]
        if stmt isa Core.ReturnNode
            if isdefined(stmt, :val)
                # PURE-036ag: Handle numeric-to-externref case
                func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                if func_ret_wasm === ExternRef && is_numeric_val
                    emit_numeric_to_externref!(bytes, stmt.val, val_wasm, ctx)
                else
                    append!(bytes, compile_value(stmt.val, ctx))
                    if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                    end
                end
            end
            break
        elseif stmt === nothing
            # Skip
        elseif !(stmt isa Core.GotoIfNot) && !(stmt isa Core.GotoNode) && !(stmt isa Core.PhiNode)
            append!(bytes, compile_statement(stmt, i, ctx))
        end
    end

    # Else-branch
    push!(bytes, Opcode.ELSE)

    # Check for more conditionals in else branch
    rest_conds = remaining_conds[2:end]
    if !isempty(rest_conds)
        # Recurse for remaining conditionals
        append!(bytes, generate_remaining_conditionals(ctx, blocks, code, rest_conds, result_type, ssa_use_count))
    else
        # Generate code from goto_if_not.dest to end (else branch)
        for i in goto_if_not.dest:length(code)
            stmt = code[i]
            if stmt isa Core.ReturnNode
                if isdefined(stmt, :val)
                    # PURE-036ag: Handle numeric-to-externref case
                    func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                    val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                    is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                    if func_ret_wasm === ExternRef && is_numeric_val
                        emit_numeric_to_externref!(bytes, stmt.val, val_wasm, ctx)
                    else
                        append!(bytes, compile_value(stmt.val, ctx))
                        if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                        end
                    end
                end
                break
            elseif stmt === nothing
                # Skip
            elseif !(stmt isa Core.GotoIfNot) && !(stmt isa Core.GotoNode) && !(stmt isa Core.PhiNode)
                append!(bytes, compile_statement(stmt, i, ctx))
            end
        end
    end

    push!(bytes, Opcode.END)

    return bytes
end

"""
Generate nested if-else for multiple conditionals.
"""
function generate_nested_conditionals(ctx::CompilationContext, blocks, code, conditionals)::Vector{UInt8}
    bytes = UInt8[]
    result_type = julia_to_wasm_type_concrete(ctx.return_type, ctx)

    # Count SSA uses for drop logic
    ssa_use_count = Dict{Int, Int}()
    for stmt in code
        count_ssa_uses!(stmt, ssa_use_count)
    end

    # ========================================================================
    # BOUNDSCHECK PATTERN DETECTION
    # ========================================================================
    # We emit i32.const 0 for boundscheck, so GotoIfNot following boundscheck
    # ALWAYS jumps (since NOT 0 = TRUE). We need to:
    # 1. Filter out these fake conditionals (they're always-jump, not real conditionals)
    # 2. Track dead code regions (fall-through path that's never taken)
    # 3. Generate code that goes directly to the jump target

    boundscheck_jumps = Set{Int}()  # Statement indices of GotoIfNot that always jump
    dead_regions = Set{Int}()       # Statement indices that are dead code

    for i in 1:length(code)
        stmt = code[i]
        if stmt isa Expr && stmt.head === :boundscheck && length(stmt.args) >= 1
            # Check if next statement is a GotoIfNot using this boundscheck result
            if i + 1 <= length(code) && code[i + 1] isa Core.GotoIfNot
                goto_stmt = code[i + 1]::Core.GotoIfNot
                if goto_stmt.cond isa Core.SSAValue && goto_stmt.cond.id == i
                    # This is a boundscheck+GotoIfNot pattern - the GotoIfNot always jumps
                    push!(boundscheck_jumps, i + 1)
                    # Mark the boundscheck as dead (we don't need to emit i32.const 0)
                    push!(dead_regions, i)
                    # Mark the fall-through path as dead (from GotoIfNot+1 to target-1)
                    target = goto_stmt.dest
                    for j in (i + 2):(target - 1)
                        push!(dead_regions, j)
                    end
                end
            end
        end
    end

    # Filter out boundscheck-based conditionals - they're not real conditionals
    # Also filter out conditionals that are entirely within dead regions
    real_conditionals = filter(conditionals) do (block_idx, block)
        term_idx = block.end_idx
        if term_idx in boundscheck_jumps
            return false  # This is an always-jump, not a real conditional
        end
        if term_idx in dead_regions
            return false  # This conditional is inside dead code
        end
        return true
    end

    # If we filtered out all conditionals, we just need to emit the code
    # that the boundscheck jumps to
    if isempty(real_conditionals)
        # Find the first non-dead statement after any boundscheck jumps
        # This is the actual code that should run
        first_live = 1
        for i in 1:length(code)
            if !(i in dead_regions)
                first_live = i
                break
            end
        end

        # Generate code starting from first_live, skipping any remaining dead regions
        for i in first_live:length(code)
            if i in dead_regions
                continue
            end
            if i in boundscheck_jumps
                continue  # Skip the always-jump GotoIfNot
            end
            stmt = code[i]
            if stmt isa Core.ReturnNode
                if isdefined(stmt, :val)
                    # PURE-036af/PURE-045: Handle numeric-to-ref case
                    func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                    val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                    is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                    if func_ret_wasm === ExternRef && is_numeric_val
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
                        # If function returns externref but value is concrete ref, convert
                        if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                        end
                    end
                end
                push!(bytes, Opcode.RETURN)
            elseif stmt === nothing
                # Skip
            elseif stmt isa Core.GotoNode
                # Skip forward gotos that were part of the dead structure
            elseif stmt isa Core.GotoIfNot
                # Skip conditionals that are part of dead structure
            else
                append!(bytes, compile_statement(stmt, i, ctx))

                # Drop unused values
                if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                    stmt_type = get(ctx.ssa_types, i, Any)
                    if stmt_type !== Nothing && stmt_type !== Union{}
                        is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                        if !is_nothing_union
                            if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                                use_count = get(ssa_use_count, i, 0)
                                if use_count == 0
                                    push!(bytes, Opcode.DROP)
                                end
                            end
                        end
                    end
                end
            end
        end

        return bytes
    end

    # Use real_conditionals for the rest of the function
    conditionals = real_conditionals

    # Check for && pattern: all conditionals jump to the same destination
    # This pattern needs special handling with block/br_if instead of nested if/else
    if length(conditionals) >= 2
        first_dest = conditionals[1][2].terminator.dest
        all_same_dest = all(c -> c[2].terminator.dest == first_dest, conditionals)

        if all_same_dest
            # && pattern: use block/br_if approach
            return generate_and_pattern(ctx, blocks, code, conditionals, result_type, first_dest, ssa_use_count)
        end
    end

    # Check for || pattern: conditionals where then-branch (fall-through) jumps to a phi
    # Pattern: cond1 || cond2 || cond3 generates:
    #   1: cond1
    #   2: goto %4 if not %1
    #   3: goto %phi  (then-branch when cond1 is true)
    #   4: cond2
    #   5: goto %7 if not %4
    #   6: goto %phi  (then-branch when cond2 is true)
    #   ...
    #   phi: φ (%3 => %1, %6 => %4, ...)
    or_pattern = detect_or_pattern(code, conditionals, ctx.ssa_types)
    if or_pattern !== nothing
        return generate_or_pattern(ctx, blocks, code, conditionals, result_type, or_pattern, ssa_use_count)
    end

    # Check for switch pattern: sequential conditionals testing same value against constants
    # Each case returns independently (no phi merge for the switch itself)
    # NOTE: Switch pattern disabled for now - it replaces entire code generation incorrectly
    # TODO: Integrate switch pattern into the main code flow properly
    # switch_pattern = detect_switch_pattern(code, conditionals)
    # if switch_pattern !== nothing
    #     return generate_switch_pattern(ctx, blocks, code, conditionals, result_type, switch_pattern, ssa_use_count)
    # end

    # Track which statements have been compiled to avoid duplicating code
    compiled_stmts = Set{Int}()

    # PURE-506: Track whether gen_conditional used a typed IF block (vs void 0x40).
    # When typed, the IF block leaves a value on the stack; when void, branches use
    # explicit RETURN and the post-IF code is unreachable.
    used_typed_if = Ref(false)

    # Build a recursive if-else structure
    # target_idx tracks where to generate code when no more conditionals
    function gen_conditional(cond_idx::Int; target_idx::Int=0)::Vector{UInt8}
        inner_bytes = UInt8[]

        if cond_idx > length(conditionals)
            # No more conditionals - generate code starting from target_idx
            # This should generate the "else" path for the control flow
            if target_idx > 0
                # PURE-220: Generate ALL statements from target_idx through the return,
                # spanning across block boundaries. Previous code only looked at individual
                # blocks which missed intermediate statements (e.g. size update + element
                # write between a _growend! conditional and the return block).
                for i in target_idx:length(code)
                    stmt = code[i]
                    if stmt isa Core.ReturnNode
                        if isdefined(stmt, :val)
                            # PURE-036af/PURE-045: Handle numeric-to-ref case
                            func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                            val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                            is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                            if func_ret_wasm === ExternRef && is_numeric_val
                                emit_numeric_to_externref!(inner_bytes, stmt.val, val_wasm, ctx)
                            elseif func_ret_wasm isa ConcreteRef && is_numeric_val
                                # PURE-045: Numeric (nothing) to concrete ref - return ref.null of the type
                                push!(inner_bytes, Opcode.REF_NULL)
                                append!(inner_bytes, encode_leb128_signed(Int64(func_ret_wasm.type_idx)))
                            elseif (func_ret_wasm === StructRef || func_ret_wasm === ArrayRef || func_ret_wasm === AnyRef) && is_numeric_val
                                # PURE-045: Numeric to abstract ref - return ref.null of the abstract type
                                push!(inner_bytes, Opcode.REF_NULL)
                                push!(inner_bytes, UInt8(func_ret_wasm))
                            else
                                append!(inner_bytes, compile_value(stmt.val, ctx))
                                if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                                    push!(inner_bytes, Opcode.GC_PREFIX)
                                    push!(inner_bytes, Opcode.EXTERN_CONVERT_ANY)
                                end
                            end
                        else
                            push!(inner_bytes, Opcode.UNREACHABLE)
                        end
                        push!(inner_bytes, Opcode.RETURN)
                        break
                    elseif stmt === nothing || stmt isa Core.GotoNode || stmt isa Core.GotoIfNot
                        # Skip control flow (already handled by structure)
                    else
                        append!(inner_bytes, compile_statement(stmt, i, ctx))

                        # Drop unused values (but NOT for Union{} which never returns)
                        if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                            stmt_type = get(ctx.ssa_types, i, Any)
                            if stmt_type !== Nothing && stmt_type !== Union{}
                                is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                                if !is_nothing_union
                                    if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                                        use_count = get(ssa_use_count, i, 0)
                                        if use_count == 0
                                            push!(inner_bytes, Opcode.DROP)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                return inner_bytes
            end

            for block in blocks
                if target_idx == 0 && block.terminator isa Core.ReturnNode
                    # Fallback: find first return block
                    for i in block.start_idx:block.end_idx
                        stmt = code[i]
                        if stmt isa Core.ReturnNode
                            if isdefined(stmt, :val)
                                # PURE-036af/PURE-045: Handle numeric-to-ref case
                                func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                                val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                                is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                                if func_ret_wasm === ExternRef && is_numeric_val
                                    emit_numeric_to_externref!(inner_bytes, stmt.val, val_wasm, ctx)
                                elseif func_ret_wasm isa ConcreteRef && is_numeric_val
                                    # PURE-045: Numeric (nothing) to concrete ref - return ref.null of the type
                                    push!(inner_bytes, Opcode.REF_NULL)
                                    append!(inner_bytes, encode_leb128_signed(Int64(func_ret_wasm.type_idx)))
                                elseif (func_ret_wasm === StructRef || func_ret_wasm === ArrayRef || func_ret_wasm === AnyRef) && is_numeric_val
                                    # PURE-045: Numeric to abstract ref - return ref.null of the abstract type
                                    push!(inner_bytes, Opcode.REF_NULL)
                                    push!(inner_bytes, UInt8(func_ret_wasm))
                                else
                                    append!(inner_bytes, compile_value(stmt.val, ctx))
                                    if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                                        push!(inner_bytes, Opcode.GC_PREFIX)
                                        push!(inner_bytes, Opcode.EXTERN_CONVERT_ANY)
                                    end
                                end
                            end
                            push!(inner_bytes, Opcode.RETURN)
                        elseif !(stmt isa Core.GotoIfNot)
                            append!(inner_bytes, compile_statement(stmt, i, ctx))
                        end
                    end
                    break
                end
            end
            return inner_bytes
        end

        block_idx, block = conditionals[cond_idx]
        goto_if_not = block.terminator::Core.GotoIfNot

        # PURE-316: Generate intermediate statements between target_idx and this
        # conditional's block. When the else-branch of a prior conditional falls through
        # to code before this conditional (e.g., add_int computations between an
        # if-throw and the next GotoIfNot), those statements must be compiled here.
        if target_idx > 0 && target_idx < block.start_idx
            for i in target_idx:(block.start_idx - 1)
                stmt = code[i]
                if stmt === nothing || stmt isa Core.GotoNode || stmt isa Core.GotoIfNot || stmt isa Core.PhiNode
                    # Skip control flow (already handled by structure)
                else
                    append!(inner_bytes, compile_statement(stmt, i, ctx))

                    # Drop unused values
                    if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                        stmt_type = get(ctx.ssa_types, i, Any)
                        if stmt_type !== Nothing && stmt_type !== Union{}
                            is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                            if !is_nothing_union
                                if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                                    use_count = get(ssa_use_count, i, 0)
                                    if use_count == 0
                                        push!(inner_bytes, Opcode.DROP)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        # Generate statements before condition
        for i in block.start_idx:block.end_idx-1
            append!(inner_bytes, compile_statement(code[i], i, ctx))

            # Drop unused values
            stmt = code[i]
            if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                stmt_type = get(ctx.ssa_types, i, Any)
                if stmt_type !== Nothing
                    is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                    if !is_nothing_union
                        if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                            use_count = get(ssa_use_count, i, 0)
                            if use_count == 0
                                push!(inner_bytes, Opcode.DROP)
                            end
                        end
                    end
                end
            end
        end

        # Then branch - analyze what's in the then range BEFORE generating IF
        then_start = block.end_idx + 1
        then_end = goto_if_not.dest - 1
        found_return = false
        found_nested_cond = false
        found_forward_goto = nothing  # Target of unconditional forward GotoNode
        found_phi_pattern = nothing  # For && producing boolean to phi
        found_base_closure_invoke = false  # Base closure that will emit unreachable

        # First, analyze what's in the then range
        for i in then_start:min(then_end, length(code))
            stmt = code[i]
            if stmt isa Core.GotoIfNot
                found_nested_cond = true
                break
            elseif stmt isa Core.GotoNode && stmt.label > i
                # Unconditional forward jump - check if it's an || merge pattern
                # Only treat as || if target is NOT a PhiNode (phi indicates && boolean result)
                target_idx = stmt.label
                if target_idx <= length(code) && code[target_idx] isa Core.PhiNode
                    # Forward goto to phi - this is && producing a boolean value
                    # Need to generate ternary: if cond1 then cond2 else false
                    found_phi_pattern = (target_idx, i)  # (phi_idx, goto_idx)
                elseif target_idx <= length(code)
                    found_forward_goto = target_idx
                end
                break
            elseif stmt isa Expr && stmt.head === :invoke
                # Check if this is a Base closure invoke (which will emit unreachable)
                mi_or_ci = stmt.args[1]
                mi = if mi_or_ci isa Core.MethodInstance
                    mi_or_ci
                elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
                    mi_or_ci.def
                else
                    nothing
                end
                if mi isa Core.MethodInstance && mi.def isa Method
                    meth = mi.def
                    name = meth.name
                    if meth.module === Base && startswith(string(name), "#")
                        found_base_closure_invoke = true
                    end
                end
            end
        end

        # Handle phi pattern specially
        if found_phi_pattern !== nothing
            phi_idx, goto_idx = found_phi_pattern
            phi_node = code[phi_idx]::Core.PhiNode
            # PURE-303: Use ssavaluetypes fallback instead of Bool default.
            # analyze_ssa_types! may skip Any-typed SSAs, so ctx.ssa_types may not
            # have this phi. Defaulting to Bool incorrectly treats Any-typed phis
            # as boolean && patterns, generating if (result i32) instead of externref.
            phi_type = get(ctx.ssa_types, phi_idx, nothing)
            if phi_type === nothing
                ssatypes = ctx.code_info.ssavaluetypes
                phi_type = (ssatypes isa Vector && phi_idx <= length(ssatypes)) ? ssatypes[phi_idx] : Bool
            end

            # Check if this is a boolean && pattern or a ternary with computed values
            is_boolean_phi = phi_type === Bool

            if is_boolean_phi
                # Boolean && pattern: generates IF with i32 result, else = 0
                append!(inner_bytes, compile_condition_to_i32(goto_if_not.cond, ctx))
                push!(inner_bytes, Opcode.IF)
                push!(inner_bytes, 0x7f)  # i32 result type

                # Then-branch: compute cond2 (the expression before the goto)
                for i in then_start:goto_idx-1
                    stmt = code[i]
                    if stmt !== nothing && !(stmt isa Core.GotoIfNot) && !(stmt isa Core.GotoNode)
                        append!(inner_bytes, compile_statement(stmt, i, ctx))
                    end
                end

                # Push the phi's then-value onto the stack (PURE-505)
                # The if (result i32) block needs a value at the end of each branch.
                # Find which phi edge corresponds to goto_idx and compile that value.
                for (edge_idx, edge) in enumerate(phi_node.edges)
                    if edge == goto_idx
                        append!(inner_bytes, compile_value(phi_node.values[edge_idx], ctx))
                        break
                    end
                end

                # Else-branch: compute else-path value (PURE-505)
                # For &&: else is short-circuit false (no stmts, value=false)
                # For ||: else computes second condition (stmts from dest to phi, value=%6)
                push!(inner_bytes, Opcode.ELSE)

                # Find the else phi edge (the one NOT matching goto_idx)
                else_edge_val = nothing
                for (edge_idx, edge) in enumerate(phi_node.edges)
                    if edge != goto_idx
                        else_edge_val = phi_node.values[edge_idx]
                        break
                    end
                end

                # Compile else-path statements (from goto dest to phi_idx-1)
                else_start = goto_if_not.dest
                for i in else_start:(phi_idx - 1)
                    stmt = code[i]
                    if stmt !== nothing && !(stmt isa Core.PhiNode) && !(stmt isa Core.GotoIfNot) && !(stmt isa Core.GotoNode)
                        append!(inner_bytes, compile_statement(stmt, i, ctx))
                    end
                end

                # Push the else phi value
                if else_edge_val === false
                    push!(inner_bytes, Opcode.I32_CONST)
                    append!(inner_bytes, encode_leb128_signed(0))
                elseif else_edge_val === true
                    push!(inner_bytes, Opcode.I32_CONST)
                    append!(inner_bytes, encode_leb128_signed(1))
                elseif else_edge_val !== nothing
                    append!(inner_bytes, compile_value(else_edge_val, ctx))
                else
                    push!(inner_bytes, Opcode.I32_CONST)
                    append!(inner_bytes, encode_leb128_signed(0))
                end

                push!(inner_bytes, Opcode.END)

                # Store to phi local if we have one
                if haskey(ctx.phi_locals, phi_idx)
                    local_idx = ctx.phi_locals[phi_idx]
                    push!(inner_bytes, Opcode.LOCAL_SET)
                    append!(inner_bytes, encode_leb128_unsigned(local_idx))
                end

                # Continue with conditionals after the phi, or compile tail statements
                found_next_cond = false
                for (j, (_, b)) in enumerate(conditionals)
                    goto_if_not = b.terminator::Core.GotoIfNot
                    if goto_if_not.cond isa Core.SSAValue && goto_if_not.cond.id == phi_idx
                        append!(inner_bytes, gen_conditional(j; target_idx=0))
                        found_next_cond = true
                        break
                    end
                end

                # PURE-505: Compile tail statements after the phi (e.g., zext_int, and_int, return)
                if !found_next_cond
                    for i in (phi_idx + 1):length(code)
                        stmt = code[i]
                        if stmt isa Core.ReturnNode
                            if isdefined(stmt, :val)
                                append!(inner_bytes, compile_value(stmt.val, ctx))
                            end
                            push!(inner_bytes, Opcode.RETURN)
                        elseif stmt !== nothing
                            append!(inner_bytes, compile_statement(stmt, i, ctx))
                        end
                    end
                end

                return inner_bytes
            else
                # Multi-edge phi pattern - need to handle each branch separately
                # For phis with >2 edges, we can't use simple if/else result type
                # Instead, store each branch's value to the phi local

                if length(phi_node.edges) > 2
                    # Multi-edge phi - use local storage approach
                    # This pattern occurs with chained if-elseif-else
                    # We need to recurse and let each branch store to the phi local

                    # Compile then-branch statements and store value to phi local
                    append!(inner_bytes, compile_condition_to_i32(goto_if_not.cond, ctx))
                    push!(inner_bytes, Opcode.IF)
                    push!(inner_bytes, 0x40)  # void - we'll use locals

                    # Then-branch: compile statements and store to phi local
                    for i in then_start:goto_idx-1
                        stmt = code[i]
                        if stmt !== nothing && !(stmt isa Core.GotoIfNot) && !(stmt isa Core.GotoNode) && !(stmt isa Core.PhiNode)
                            append!(inner_bytes, compile_statement(stmt, i, ctx))
                        end
                    end

                    # Find the phi value for this edge (goto_idx is the edge)
                    for (edge_idx, edge) in enumerate(phi_node.edges)
                        if edge == goto_idx
                            val = phi_node.values[edge_idx]
                            val_bytes = compile_value(val, ctx)
                            if haskey(ctx.phi_locals, phi_idx)
                                local_idx = ctx.phi_locals[phi_idx]
                                phi_local_array_idx = local_idx - ctx.n_params + 1
                                phi_local_type = phi_local_array_idx >= 1 && phi_local_array_idx <= length(ctx.locals) ? ctx.locals[phi_local_array_idx] : nothing
                                # PURE-036ab: Check if val_bytes is local.get of a param with incompatible type
                                type_mismatch_handled = false
                                if phi_local_type !== nothing && length(val_bytes) >= 2 && val_bytes[1] == 0x20  # LOCAL_GET
                                    got_local_idx = 0
                                    shift = 0
                                    for bi in 2:length(val_bytes)
                                        b = val_bytes[bi]
                                        got_local_idx |= (Int(b & 0x7f) << shift)
                                        shift += 7
                                        if (b & 0x80) == 0
                                            break
                                        end
                                    end
                                    if got_local_idx < ctx.n_params
                                        param_julia_type = ctx.arg_types[got_local_idx + 1]
                                        actual_val_type = get_concrete_wasm_type(param_julia_type, ctx.mod, ctx.type_registry)
                                        if !wasm_types_compatible(phi_local_type, actual_val_type)
                                            append!(inner_bytes, emit_phi_type_default(phi_local_type))
                                            type_mismatch_handled = true
                                        end
                                    end
                                end
                                # PURE-3111: Check if val_bytes is a numeric constant stored into a ref-typed local
                                if !type_mismatch_handled && phi_local_type !== nothing &&
                                   (phi_local_type isa ConcreteRef || phi_local_type === StructRef || phi_local_type === ArrayRef || phi_local_type === ExternRef || phi_local_type === AnyRef) &&
                                   length(val_bytes) >= 1 &&
                                   (val_bytes[1] == Opcode.I32_CONST || val_bytes[1] == Opcode.I64_CONST || val_bytes[1] == Opcode.F32_CONST || val_bytes[1] == Opcode.F64_CONST) &&
                                   !has_ref_producing_gc_op(val_bytes)
                                    append!(inner_bytes, emit_phi_type_default(phi_local_type))
                                    type_mismatch_handled = true
                                end
                                if !type_mismatch_handled
                                    append!(inner_bytes, val_bytes)
                                end
                                push!(inner_bytes, Opcode.LOCAL_SET)
                                append!(inner_bytes, encode_leb128_unsigned(local_idx))
                            else
                                append!(inner_bytes, val_bytes)
                            end
                            break
                        end
                    end

                    # Handle other phi nodes at this merge point
                    for other_phi_idx in (phi_idx+1):length(code)
                        other_stmt = code[other_phi_idx]
                        if other_stmt isa Core.PhiNode
                            for (edge_idx, edge) in enumerate(other_stmt.edges)
                                if edge == goto_idx
                                    val = other_stmt.values[edge_idx]
                                    val_bytes = compile_value(val, ctx)
                                    if haskey(ctx.phi_locals, other_phi_idx)
                                        local_idx = ctx.phi_locals[other_phi_idx]
                                        phi_local_array_idx = local_idx - ctx.n_params + 1
                                        phi_local_type = phi_local_array_idx >= 1 && phi_local_array_idx <= length(ctx.locals) ? ctx.locals[phi_local_array_idx] : nothing
                                        # PURE-036ab: Check if val_bytes is local.get of a param with incompatible type
                                        type_mismatch_handled = false
                                        if phi_local_type !== nothing && length(val_bytes) >= 2 && val_bytes[1] == 0x20  # LOCAL_GET
                                            got_local_idx = 0
                                            shift = 0
                                            for bi in 2:length(val_bytes)
                                                b = val_bytes[bi]
                                                got_local_idx |= (Int(b & 0x7f) << shift)
                                                shift += 7
                                                if (b & 0x80) == 0
                                                    break
                                                end
                                            end
                                            if got_local_idx < ctx.n_params
                                                param_julia_type = ctx.arg_types[got_local_idx + 1]
                                                actual_val_type = get_concrete_wasm_type(param_julia_type, ctx.mod, ctx.type_registry)
                                                if !wasm_types_compatible(phi_local_type, actual_val_type)
                                                    append!(inner_bytes, emit_phi_type_default(phi_local_type))
                                                    type_mismatch_handled = true
                                                end
                                            end
                                        end
                                        # PURE-3111: Check if val_bytes is a numeric constant stored into a ref-typed local
                                        if !type_mismatch_handled && phi_local_type !== nothing &&
                                           (phi_local_type isa ConcreteRef || phi_local_type === StructRef || phi_local_type === ArrayRef || phi_local_type === ExternRef || phi_local_type === AnyRef) &&
                                           length(val_bytes) >= 1 &&
                                           (val_bytes[1] == Opcode.I32_CONST || val_bytes[1] == Opcode.I64_CONST || val_bytes[1] == Opcode.F32_CONST || val_bytes[1] == Opcode.F64_CONST) &&
                                           !has_ref_producing_gc_op(val_bytes)
                                            append!(inner_bytes, emit_phi_type_default(phi_local_type))
                                            type_mismatch_handled = true
                                        end
                                        if !type_mismatch_handled
                                            append!(inner_bytes, val_bytes)
                                        end
                                        push!(inner_bytes, Opcode.LOCAL_SET)
                                        append!(inner_bytes, encode_leb128_unsigned(local_idx))
                                    else
                                        append!(inner_bytes, val_bytes)
                                    end
                                    break
                                end
                            end
                        else
                            break  # Phi nodes are consecutive
                        end
                    end

                    # Else-branch: recurse for remaining conditionals
                    push!(inner_bytes, Opcode.ELSE)

                    # Find next conditional in the else branch
                    next_cond_idx = cond_idx + 1
                    if next_cond_idx <= length(conditionals)
                        append!(inner_bytes, gen_conditional(next_cond_idx; target_idx=phi_idx))
                    else
                        # No more conditionals - this is the final else branch
                        # Find the edge that corresponds to this fallthrough path
                        for i in goto_if_not.dest:phi_idx-1
                            stmt = code[i]
                            if stmt === nothing || stmt isa Core.GotoNode || stmt isa Core.PhiNode
                                continue
                            elseif stmt isa Core.GotoIfNot
                                # There's another conditional - this shouldn't happen if we're at the end
                                continue
                            else
                                append!(inner_bytes, compile_statement(stmt, i, ctx))
                            end
                        end

                        # Store the final else value to phi locals
                        # The fallthrough edge is the last statement index before phi
                        last_stmt_idx = phi_idx - 1
                        for (edge_idx, edge) in enumerate(phi_node.edges)
                            if edge == last_stmt_idx
                                val = phi_node.values[edge_idx]
                                val_bytes = compile_value(val, ctx)
                                if haskey(ctx.phi_locals, phi_idx)
                                    local_idx = ctx.phi_locals[phi_idx]
                                    phi_local_array_idx = local_idx - ctx.n_params + 1
                                    phi_local_type = phi_local_array_idx >= 1 && phi_local_array_idx <= length(ctx.locals) ? ctx.locals[phi_local_array_idx] : nothing
                                    # PURE-036ab: Check if val_bytes is local.get of a param with incompatible type
                                    type_mismatch_handled = false
                                    if phi_local_type !== nothing && length(val_bytes) >= 2 && val_bytes[1] == 0x20  # LOCAL_GET
                                        got_local_idx = 0
                                        shift = 0
                                        for bi in 2:length(val_bytes)
                                            b = val_bytes[bi]
                                            got_local_idx |= (Int(b & 0x7f) << shift)
                                            shift += 7
                                            if (b & 0x80) == 0
                                                break
                                            end
                                        end
                                        if got_local_idx < ctx.n_params
                                            param_julia_type = ctx.arg_types[got_local_idx + 1]
                                            actual_val_type = get_concrete_wasm_type(param_julia_type, ctx.mod, ctx.type_registry)
                                            if !wasm_types_compatible(phi_local_type, actual_val_type)
                                                append!(inner_bytes, emit_phi_type_default(phi_local_type))
                                                type_mismatch_handled = true
                                            end
                                        end
                                    end
                                    # PURE-3111: Check if val_bytes is a numeric constant stored into a ref-typed local
                                    if !type_mismatch_handled && phi_local_type !== nothing &&
                                       (phi_local_type isa ConcreteRef || phi_local_type === StructRef || phi_local_type === ArrayRef || phi_local_type === ExternRef || phi_local_type === AnyRef) &&
                                       length(val_bytes) >= 1 &&
                                       (val_bytes[1] == Opcode.I32_CONST || val_bytes[1] == Opcode.I64_CONST || val_bytes[1] == Opcode.F32_CONST || val_bytes[1] == Opcode.F64_CONST) &&
                                       !has_ref_producing_gc_op(val_bytes)
                                        append!(inner_bytes, emit_phi_type_default(phi_local_type))
                                        type_mismatch_handled = true
                                    end
                                    if !type_mismatch_handled
                                        append!(inner_bytes, val_bytes)
                                    end
                                    push!(inner_bytes, Opcode.LOCAL_SET)
                                    append!(inner_bytes, encode_leb128_unsigned(local_idx))
                                else
                                    append!(inner_bytes, val_bytes)
                                end
                                break
                            end
                        end

                        # Handle other phi nodes
                        for other_phi_idx in (phi_idx+1):length(code)
                            other_stmt = code[other_phi_idx]
                            if other_stmt isa Core.PhiNode
                                for (edge_idx, edge) in enumerate(other_stmt.edges)
                                    if edge == last_stmt_idx
                                        val = other_stmt.values[edge_idx]
                                        val_bytes = compile_value(val, ctx)
                                        if haskey(ctx.phi_locals, other_phi_idx)
                                            local_idx = ctx.phi_locals[other_phi_idx]
                                            phi_local_array_idx = local_idx - ctx.n_params + 1
                                            phi_local_type = phi_local_array_idx >= 1 && phi_local_array_idx <= length(ctx.locals) ? ctx.locals[phi_local_array_idx] : nothing
                                            # PURE-036ab: Check if val_bytes is local.get of a param with incompatible type
                                            type_mismatch_handled = false
                                            if phi_local_type !== nothing && length(val_bytes) >= 2 && val_bytes[1] == 0x20  # LOCAL_GET
                                                got_local_idx = 0
                                                shift = 0
                                                for bi in 2:length(val_bytes)
                                                    b = val_bytes[bi]
                                                    got_local_idx |= (Int(b & 0x7f) << shift)
                                                    shift += 7
                                                    if (b & 0x80) == 0
                                                        break
                                                    end
                                                end
                                                if got_local_idx < ctx.n_params
                                                    param_julia_type = ctx.arg_types[got_local_idx + 1]
                                                    actual_val_type = get_concrete_wasm_type(param_julia_type, ctx.mod, ctx.type_registry)
                                                    if !wasm_types_compatible(phi_local_type, actual_val_type)
                                                        append!(inner_bytes, emit_phi_type_default(phi_local_type))
                                                        type_mismatch_handled = true
                                                    end
                                                end
                                            end
                                            # PURE-3111: Check if val_bytes is a numeric constant stored into a ref-typed local
                                            if !type_mismatch_handled && phi_local_type !== nothing &&
                                               (phi_local_type isa ConcreteRef || phi_local_type === StructRef || phi_local_type === ArrayRef || phi_local_type === ExternRef || phi_local_type === AnyRef) &&
                                               length(val_bytes) >= 1 &&
                                               (val_bytes[1] == Opcode.I32_CONST || val_bytes[1] == Opcode.I64_CONST || val_bytes[1] == Opcode.F32_CONST || val_bytes[1] == Opcode.F64_CONST) &&
                                               !has_ref_producing_gc_op(val_bytes)
                                                append!(inner_bytes, emit_phi_type_default(phi_local_type))
                                                type_mismatch_handled = true
                                            end
                                            if !type_mismatch_handled
                                                append!(inner_bytes, val_bytes)
                                            end
                                            push!(inner_bytes, Opcode.LOCAL_SET)
                                            append!(inner_bytes, encode_leb128_unsigned(local_idx))
                                        else
                                            append!(inner_bytes, val_bytes)
                                        end
                                        break
                                    end
                                end
                            else
                                break
                            end
                        end
                    end

                    push!(inner_bytes, Opcode.END)

                    # Only generate code after the phi nodes at the outermost level
                    # (when target_idx == 0, meaning this is not a recursive call)
                    if target_idx == 0
                        # Now generate code after the phi nodes
                        # Find first non-phi statement after phi_idx
                        first_non_phi = phi_idx
                        for i in phi_idx:length(code)
                            if !(code[i] isa Core.PhiNode)
                                first_non_phi = i
                                break
                            end
                        end

                        for i in first_non_phi:length(code)
                            stmt = code[i]
                            if stmt isa Core.ReturnNode
                                if isdefined(stmt, :val)
                                    # PURE-036af/PURE-045: Handle numeric-to-ref case
                                    func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                                    val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                                    is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                                    if func_ret_wasm === ExternRef && is_numeric_val
                                        emit_numeric_to_externref!(inner_bytes, stmt.val, val_wasm, ctx)
                                    elseif func_ret_wasm isa ConcreteRef && is_numeric_val
                                        # PURE-045: Numeric (nothing) to concrete ref - return ref.null of the type
                                        push!(inner_bytes, Opcode.REF_NULL)
                                        append!(inner_bytes, encode_leb128_signed(Int64(func_ret_wasm.type_idx)))
                                    elseif (func_ret_wasm === StructRef || func_ret_wasm === ArrayRef || func_ret_wasm === AnyRef) && is_numeric_val
                                        # PURE-045: Numeric to abstract ref - return ref.null of the abstract type
                                        push!(inner_bytes, Opcode.REF_NULL)
                                        push!(inner_bytes, UInt8(func_ret_wasm))
                                    else
                                        append!(inner_bytes, compile_value(stmt.val, ctx))
                                        if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                                            push!(inner_bytes, Opcode.GC_PREFIX)
                                            push!(inner_bytes, Opcode.EXTERN_CONVERT_ANY)
                                        end
                                    end
                                end
                                push!(inner_bytes, Opcode.RETURN)
                                break
                            elseif stmt === nothing || stmt isa Core.PhiNode
                                continue
                            else
                                append!(inner_bytes, compile_statement(stmt, i, ctx))
                            end
                        end
                    end

                    return inner_bytes
                end

                # Simple 2-edge ternary pattern
                phi_wasm_type = julia_to_wasm_type_concrete(phi_type, ctx)

                then_value = nothing
                else_value = nothing
                else_edge = nothing
                for (edge_idx, edge) in enumerate(phi_node.edges)
                    if edge < goto_if_not.dest
                        # Edge from then-branch (before else target)
                        then_value = phi_node.values[edge_idx]
                    else
                        # Edge from else-branch
                        else_value = phi_node.values[edge_idx]
                        else_edge = edge
                    end
                end

                # Push condition
                append!(inner_bytes, compile_condition_to_i32(goto_if_not.cond, ctx))

                # IF block with phi's result type
                push!(inner_bytes, Opcode.IF)
                append!(inner_bytes, encode_block_type(phi_wasm_type))

                # Then-branch: compile any statements, then push the value
                then_hit_unreachable = false
                for i in then_start:goto_idx-1
                    stmt = code[i]
                    if stmt !== nothing && !(stmt isa Core.GotoIfNot) && !(stmt isa Core.GotoNode) && !(stmt isa Core.PhiNode)
                        _then_stmt_bytes = compile_statement(stmt, i, ctx)
                        append!(inner_bytes, _then_stmt_bytes)
                        # PURE-908: If statement emitted unreachable, skip phi value
                        if !isempty(_then_stmt_bytes) && _then_stmt_bytes[end] == Opcode.UNREACHABLE
                            then_hit_unreachable = true
                            break
                        end
                    end
                end
                # Push then-branch result value
                # Handle cases:
                # 1. then_value is nothing (Julia's nothing) - need ref.null if ref type expected
                # 2. then_value compiles to nothing (SSA with Nothing type) - need ref.null
                # 3. then_value compiles to actual value - use that
                # PURE-908: Skip if we hit unreachable — stack is polymorphic
                if then_hit_unreachable
                    # unreachable makes stack polymorphic — no phi value needed
                elseif then_value === nothing
                    # Phi value is Julia's nothing - emit ref.null if ref type expected
                    if phi_wasm_type isa ConcreteRef
                        push!(inner_bytes, Opcode.REF_NULL)
                        append!(inner_bytes, encode_leb128_signed(Int64(phi_wasm_type.type_idx)))
                    elseif phi_wasm_type === ExternRef
                        push!(inner_bytes, Opcode.REF_NULL)
                        push!(inner_bytes, UInt8(ExternRef))
                    end
                    # For non-ref types, nothing produces no value (shouldn't happen for valid code)
                elseif then_value !== nothing
                    value_bytes = compile_value(then_value, ctx)
                    if isempty(value_bytes) && (phi_wasm_type isa ConcreteRef || phi_wasm_type === StructRef || phi_wasm_type === ArrayRef || phi_wasm_type === AnyRef || phi_wasm_type === ExternRef)
                        # Value compiled to nothing but we need a ref type - emit ref.null
                        if phi_wasm_type isa ConcreteRef
                            push!(inner_bytes, Opcode.REF_NULL)
                            append!(inner_bytes, encode_leb128_signed(Int64(phi_wasm_type.type_idx)))
                        else
                            push!(inner_bytes, Opcode.REF_NULL)
                            push!(inner_bytes, UInt8(phi_wasm_type))
                        end
                    elseif !isempty(value_bytes) && (phi_wasm_type isa ConcreteRef || phi_wasm_type === StructRef || phi_wasm_type === ArrayRef || phi_wasm_type === AnyRef) &&
                           (value_bytes[1] == Opcode.I32_CONST || value_bytes[1] == Opcode.I64_CONST || value_bytes[1] == Opcode.F32_CONST || value_bytes[1] == Opcode.F64_CONST)
                        # PURE-6025: Numeric constant but phi expects ref type — emit ref.null
                        if phi_wasm_type isa ConcreteRef
                            push!(inner_bytes, Opcode.REF_NULL)
                            append!(inner_bytes, encode_leb128_signed(Int64(phi_wasm_type.type_idx)))
                        else
                            push!(inner_bytes, Opcode.REF_NULL)
                            push!(inner_bytes, UInt8(phi_wasm_type))
                        end
                    else
                        append!(inner_bytes, value_bytes)
                        # PURE-303: Convert concrete/any ref to externref when phi expects externref
                        if phi_wasm_type === ExternRef
                            val_wasm = infer_value_wasm_type(then_value, ctx)
                            if val_wasm !== ExternRef && (val_wasm isa ConcreteRef || val_wasm === StructRef || val_wasm === ArrayRef || val_wasm === AnyRef)
                                push!(inner_bytes, Opcode.GC_PREFIX)
                                push!(inner_bytes, Opcode.EXTERN_CONVERT_ANY)
                            end
                        end
                    end
                end

                # Else-branch: compile statements from dest to else_edge, then push the value
                push!(inner_bytes, Opcode.ELSE)

                # Check if the GotoIfNot's type is Union{} (bottom type) - this means the else branch is dead code
                # The type of the GotoIfNot is stored at block.end_idx (the line with the conditional)
                goto_if_not_type = get(ctx.ssa_types, block.end_idx, Any)
                is_else_unreachable = goto_if_not_type === Union{}

                if is_else_unreachable
                    # Else branch is dead code - just emit unreachable
                    push!(inner_bytes, Opcode.UNREACHABLE)
                elseif else_edge !== nothing
                    for i in goto_if_not.dest:else_edge
                        stmt = code[i]
                        if stmt === nothing
                            continue
                        elseif stmt isa Core.GotoNode || stmt isa Core.PhiNode
                            continue
                        elseif stmt isa Core.ReturnNode
                            continue
                        else
                            _else_stmt_bytes = compile_statement(stmt, i, ctx)
                            append!(inner_bytes, _else_stmt_bytes)
                            # PURE-908: If statement emitted unreachable (stub call),
                            # mark else as unreachable and stop emitting dead code.
                            if !isempty(_else_stmt_bytes) && _else_stmt_bytes[end] == Opcode.UNREACHABLE
                                is_else_unreachable = true
                                break
                            end
                        end
                    end
                end

                # Push else-branch result value (same logic as then-branch)
                # But skip if else branch is unreachable (code after unreachable is dead)
                if !is_else_unreachable
                    if else_value === nothing
                        # Phi value is Julia's nothing - emit ref.null if ref type expected
                        if phi_wasm_type isa ConcreteRef
                            push!(inner_bytes, Opcode.REF_NULL)
                            append!(inner_bytes, encode_leb128_signed(Int64(phi_wasm_type.type_idx)))
                        elseif phi_wasm_type === ExternRef
                            push!(inner_bytes, Opcode.REF_NULL)
                            push!(inner_bytes, UInt8(ExternRef))
                        end
                    elseif else_value !== nothing
                        value_bytes = compile_value(else_value, ctx)
                        if isempty(value_bytes) && (phi_wasm_type isa ConcreteRef || phi_wasm_type === StructRef || phi_wasm_type === ArrayRef || phi_wasm_type === AnyRef || phi_wasm_type === ExternRef)
                            # Value compiled to nothing but we need a ref type - emit ref.null
                            if phi_wasm_type isa ConcreteRef
                                push!(inner_bytes, Opcode.REF_NULL)
                                append!(inner_bytes, encode_leb128_signed(Int64(phi_wasm_type.type_idx)))
                            else
                                push!(inner_bytes, Opcode.REF_NULL)
                                push!(inner_bytes, UInt8(phi_wasm_type))
                            end
                        elseif !isempty(value_bytes) && (phi_wasm_type isa ConcreteRef || phi_wasm_type === StructRef || phi_wasm_type === ArrayRef || phi_wasm_type === AnyRef) &&
                               (value_bytes[1] == Opcode.I32_CONST || value_bytes[1] == Opcode.I64_CONST || value_bytes[1] == Opcode.F32_CONST || value_bytes[1] == Opcode.F64_CONST)
                            # PURE-6025: Numeric constant in else-branch but phi expects ref type.
                            # This happens when a Union{ConcreteRef, UInt8} phi has a UInt8 constant
                            # (like ExternRef=0x6f=111) compiled as i32_const. Replace with ref.null.
                            if phi_wasm_type isa ConcreteRef
                                push!(inner_bytes, Opcode.REF_NULL)
                                append!(inner_bytes, encode_leb128_signed(Int64(phi_wasm_type.type_idx)))
                            else
                                push!(inner_bytes, Opcode.REF_NULL)
                                push!(inner_bytes, UInt8(phi_wasm_type))
                            end
                        else
                            append!(inner_bytes, value_bytes)
                            # PURE-303: Convert concrete/any ref to externref when phi expects externref
                            if phi_wasm_type === ExternRef
                                val_wasm = infer_value_wasm_type(else_value, ctx)
                                if val_wasm !== ExternRef && (val_wasm isa ConcreteRef || val_wasm === StructRef || val_wasm === ArrayRef || val_wasm === AnyRef)
                                    push!(inner_bytes, Opcode.GC_PREFIX)
                                    push!(inner_bytes, Opcode.EXTERN_CONVERT_ANY)
                                end
                            end
                        end
                    end
                end

                push!(inner_bytes, Opcode.END)

                # Store to phi local if we have one
                if haskey(ctx.phi_locals, phi_idx)
                    local_idx = ctx.phi_locals[phi_idx]
                    push!(inner_bytes, Opcode.LOCAL_SET)
                    append!(inner_bytes, encode_leb128_unsigned(local_idx))
                end

                # After the phi, continue generating code from phi_idx+1 to the return
                for i in phi_idx+1:length(code)
                    stmt = code[i]
                    if stmt isa Core.ReturnNode
                        if isdefined(stmt, :val)
                            # PURE-036ag: Handle numeric-to-externref case
                            func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                            val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                            is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                            if func_ret_wasm === ExternRef && is_numeric_val
                                emit_numeric_to_externref!(inner_bytes, stmt.val, val_wasm, ctx)
                            else
                                append!(inner_bytes, compile_value(stmt.val, ctx))
                                if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                                    push!(inner_bytes, Opcode.GC_PREFIX)
                                    push!(inner_bytes, Opcode.EXTERN_CONVERT_ANY)
                                end
                            end
                        end
                        break
                    elseif stmt === nothing || stmt isa Core.GotoNode || stmt isa Core.PhiNode
                        continue
                    else
                        append!(inner_bytes, compile_statement(stmt, i, ctx))
                    end
                end

                return inner_bytes
            end
        end

        # Push condition for normal pattern
        append!(inner_bytes, compile_condition_to_i32(goto_if_not.cond, ctx))

        # Check if both branches terminate (then: return, else: unreachable or return)
        # If so, use void result type for IF block
        # PURE-3111: Enhanced check — also detects nested conditionals where all paths return,
        # including paths via GotoNode jumps to return blocks.
        else_terminates = false
        _visited = Set{Int}()
        function _all_paths_return(from_idx::Int)::Bool
            from_idx in _visited && return false  # avoid infinite loops
            push!(_visited, from_idx)
            for i in from_idx:length(code)
                s = code[i]
                if s isa Core.ReturnNode
                    return true
                elseif s isa Core.GotoNode
                    return _all_paths_return(s.label)
                elseif s isa Core.GotoIfNot
                    return _all_paths_return(i + 1) && _all_paths_return(s.dest)
                end
            end
            return false
        end
        else_terminates = _all_paths_return(goto_if_not.dest)

        # Check if then-branch ends with unreachable (Union{} typed call/invoke)
        # This happens with Base closures that we emit UNREACHABLE for
        then_ends_unreachable = false
        for i in then_start:min(then_end, length(code))
            stmt = code[i]
            if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                stmt_type = get(ctx.ssa_types, i, Any)
                if stmt_type === Union{}
                    then_ends_unreachable = true
                end
            end
        end

        # PURE-220: Check if then-branch has a return statement
        # If the then-branch has a Base closure invoke (like _growend!) but NO return,
        # the closure handler produces side-effect code without a stack result.
        # In this case we need a void block type, not a typed result block.
        then_has_return_stmt = false
        for i in then_start:min(then_end, length(code))
            if code[i] isa Core.ReturnNode
                then_has_return_stmt = true
                break
            end
        end

        # if block
        push!(inner_bytes, Opcode.IF)
        if found_forward_goto !== nothing && else_terminates
            # Both branches terminate - use void result type
            push!(inner_bytes, 0x40)  # void block type
        elseif found_base_closure_invoke && !then_has_return_stmt
            # PURE-220: Base closure invoke (e.g. _growend!) with no return in then-branch.
            # The closure handler emits side-effect code (array growth) that does NOT
            # produce a wasm value. Use void block type and emit continuation after END.
            push!(inner_bytes, 0x40)  # void block type
        elseif then_ends_unreachable
            # PURE-317: Then-branch throws (unreachable). Use void block type.
            # The then-branch never produces a value (unreachable is polymorphic),
            # and the else-branch may contain nested conditionals with returns that
            # don't leave a value on the stack for the outer IF block. Using void
            # avoids "expected type but nothing on stack" validation errors.
            push!(inner_bytes, 0x40)  # void block type
        elseif then_has_return_stmt
            # PURE-325: Then-branch has explicit return. Use void block type so the
            # then-branch can emit RETURN directly. The else-branch (which recurses
            # into gen_conditional) will also use RETURN in its branches. With all
            # branches using RETURN, the IF block is void and code after END is
            # unreachable (UNREACHABLE at function end is correct).
            push!(inner_bytes, 0x40)  # void block type
        else
            append!(inner_bytes, encode_block_type(result_type))
            used_typed_if[] = true  # PURE-506: mark that IF block has typed result
        end

        if found_forward_goto !== nothing
            # The then-branch is a forward goto to a merge point
            # Generate the code at the merge point target
            #
            # PURE-220: Build set of error-path indices to skip.
            # When the merge range contains GotoIfNot statements (e.g., boundscheck
            # patterns: GotoIfNot → GotoNode → error_code → unreachable → merge),
            # we skip the GotoIfNot but must also skip the error-path code it guards.
            # Pattern: GotoIfNot(dest=d) at j, GotoNode(label=t) at j+1 → skip d..t-1
            error_path_indices = Set{Int}()
            for j in found_forward_goto:length(code)
                if code[j] isa Core.GotoIfNot
                    d = code[j].dest
                    # Find the GotoNode right after (the success skip)
                    if j + 1 <= length(code) && code[j + 1] isa Core.GotoNode
                        t = code[j + 1].label
                        for k in d:(t - 1)
                            push!(error_path_indices, k)
                        end
                    end
                end
            end

            for i in found_forward_goto:length(code)
                if i in error_path_indices
                    continue  # Skip error-path code guarded by skipped GotoIfNot
                end
                stmt = code[i]
                if stmt isa Core.ReturnNode
                    if isdefined(stmt, :val)
                        # PURE-036af/PURE-045: Handle numeric-to-ref case
                        func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                        val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                        is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                        if func_ret_wasm === ExternRef && is_numeric_val
                            emit_numeric_to_externref!(inner_bytes, stmt.val, val_wasm, ctx)
                        elseif func_ret_wasm isa ConcreteRef && is_numeric_val
                            # PURE-045: Numeric (nothing) to concrete ref - return ref.null of the type
                            push!(inner_bytes, Opcode.REF_NULL)
                            append!(inner_bytes, encode_leb128_signed(Int64(func_ret_wasm.type_idx)))
                        elseif (func_ret_wasm === StructRef || func_ret_wasm === ArrayRef || func_ret_wasm === AnyRef) && is_numeric_val
                            # PURE-045: Numeric to abstract ref - return ref.null of the abstract type
                            push!(inner_bytes, Opcode.REF_NULL)
                            push!(inner_bytes, UInt8(func_ret_wasm))
                        else
                            append!(inner_bytes, compile_value(stmt.val, ctx))
                            if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                                push!(inner_bytes, Opcode.GC_PREFIX)
                                push!(inner_bytes, Opcode.EXTERN_CONVERT_ANY)
                            end
                        end
                    end
                    # Emit RETURN since we're in a void IF block
                    if else_terminates
                        push!(inner_bytes, Opcode.RETURN)
                    end
                    break
                elseif stmt === nothing
                    # Skip nothing statements
                elseif !(stmt isa Core.GotoIfNot) && !(stmt isa Core.GotoNode)
                    append!(inner_bytes, compile_statement(stmt, i, ctx))

                    # Drop unused values (only if not going to return)
                    if !else_terminates
                        if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                            stmt_type = get(ctx.ssa_types, i, Any)
                            if stmt_type !== Nothing
                                is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                                if !is_nothing_union
                                    if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                                        use_count = get(ssa_use_count, i, 0)
                                        if use_count == 0
                                            push!(inner_bytes, Opcode.DROP)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        elseif !found_nested_cond
            # No nested conditional and no forward goto - compile statements normally
            for i in then_start:min(then_end, length(code))
                stmt = code[i]
                if stmt isa Core.ReturnNode
                    if isdefined(stmt, :val)
                        # PURE-036ag: Handle numeric-to-externref case
                        func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                        val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                        is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                        if func_ret_wasm === ExternRef && is_numeric_val
                            emit_numeric_to_externref!(inner_bytes, stmt.val, val_wasm, ctx)
                        else
                            append!(inner_bytes, compile_value(stmt.val, ctx))
                            if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                                push!(inner_bytes, Opcode.GC_PREFIX)
                                push!(inner_bytes, Opcode.EXTERN_CONVERT_ANY)
                            end
                        end
                    end
                    # PURE-325: Emit explicit RETURN so the then-branch is self-contained.
                    # The IF block is void (0x40) when then_has_return_stmt is true.
                    push!(inner_bytes, Opcode.RETURN)
                    found_return = true
                    break
                elseif stmt === nothing
                    # Skip nothing statements
                else
                    stmt_bytes = compile_statement(stmt, i, ctx)
                    append!(inner_bytes, stmt_bytes)

                    # Drop unused values (but NOT if statement emitted UNREACHABLE)
                    # Check if the last opcode is UNREACHABLE (0x00) - if so, no value to drop
                    ends_with_unreachable = !isempty(stmt_bytes) && stmt_bytes[end] == Opcode.UNREACHABLE
                    if !ends_with_unreachable && stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                        stmt_type = get(ctx.ssa_types, i, Any)
                        if stmt_type !== Nothing
                            is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                            if !is_nothing_union
                                if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                                    use_count = get(ssa_use_count, i, 0)
                                    if use_count == 0
                                        push!(inner_bytes, Opcode.DROP)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        # Handle based on what we found in the then branch
        # NOTE: found_phi_pattern is handled earlier and returns, so won't reach here
        if found_forward_goto !== nothing
            # Already generated merge point code above - nothing more to do for then branch
        elseif found_nested_cond
            # Then branch has a nested conditional - recurse to handle it
            # This handles short-circuit && patterns
            append!(inner_bytes, gen_conditional(cond_idx + 1))
        elseif !found_return
            # PURE-220: If the then-branch is a side-effect-only closure (like _growend!),
            # the IF block is void. Close it with END and emit continuation AFTER the block.
            if found_base_closure_invoke && !then_has_return_stmt
                push!(inner_bytes, Opcode.END)  # Close void IF block

                # Find the conditional at dest (if any)
                dest_cond_idx = nothing
                for (j, (_, b)) in enumerate(conditionals)
                    if b.start_idx >= goto_if_not.dest
                        dest_cond_idx = j
                        break
                    end
                end

                # PURE-220: Generate intermediate statements between the goto dest
                # and the next conditional's block. These are the continuation statements
                # (size update, element write) that run after both branches of the if.
                if dest_cond_idx !== nothing
                    next_block_start = conditionals[dest_cond_idx][2].start_idx
                    for i in goto_if_not.dest:next_block_start-1
                        stmt = code[i]
                        if stmt === nothing || stmt isa Core.GotoNode || stmt isa Core.GotoIfNot
                            # Skip control flow (gotos handled by structure)
                        else
                            stmt_bytes = compile_statement(stmt, i, ctx)
                            append!(inner_bytes, stmt_bytes)

                            # Drop unused call results
                            if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                                stmt_type = get(ctx.ssa_types, i, Any)
                                if stmt_type !== Nothing
                                    is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                                    if !is_nothing_union
                                        if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                                            use_count = get(ssa_use_count, i, 0)
                                            if use_count == 0
                                                push!(inner_bytes, Opcode.DROP)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    # Now generate the next conditional
                    append!(inner_bytes, gen_conditional(dest_cond_idx; target_idx=goto_if_not.dest))
                else
                    append!(inner_bytes, gen_conditional(length(conditionals) + 1; target_idx=goto_if_not.dest))
                end

                return inner_bytes
            end

            # Then branch doesn't return and has no nested conditionals
            # Generate code from goto dest to the first return/conditional
            # IMPORTANT: Stop at the first return or when entering another conditional's block
            for i in goto_if_not.dest:length(code)
                stmt = code[i]
                if stmt isa Core.ReturnNode
                    if isdefined(stmt, :val)
                        # PURE-036ag: Handle numeric-to-externref case
                        func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                        val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
                        is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64
                        if func_ret_wasm === ExternRef && is_numeric_val
                            emit_numeric_to_externref!(inner_bytes, stmt.val, val_wasm, ctx)
                        else
                            append!(inner_bytes, compile_value(stmt.val, ctx))
                            if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                                push!(inner_bytes, Opcode.GC_PREFIX)
                                push!(inner_bytes, Opcode.EXTERN_CONVERT_ANY)
                            end
                        end
                    end
                    break
                elseif stmt isa Core.GotoIfNot || stmt isa Core.GotoNode
                    # Hit another control flow statement - stop here
                    # The recursive structure will handle this
                    break
                elseif stmt isa Core.PhiNode
                    # Hit a phi node - stop (this is a merge point)
                    break
                elseif stmt === nothing
                    # Skip nothing statements
                else
                    append!(inner_bytes, compile_statement(stmt, i, ctx))

                    # Drop unused values
                    if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                        stmt_type = get(ctx.ssa_types, i, Any)
                        if stmt_type !== Nothing
                            is_nothing_union = stmt_type isa Union && Nothing in Base.uniontypes(stmt_type)
                            if !is_nothing_union
                                if !haskey(ctx.ssa_locals, i) && !haskey(ctx.phi_locals, i)
                                    use_count = get(ssa_use_count, i, 0)
                                    if use_count == 0
                                        push!(inner_bytes, Opcode.DROP)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        # Else branch
        push!(inner_bytes, Opcode.ELSE)

        # Find the conditional at dest (if any)
        # This handles the case where multiple conditionals jump to the same target
        dest_cond_idx = nothing
        for (j, (_, b)) in enumerate(conditionals)
            if b.start_idx >= goto_if_not.dest
                dest_cond_idx = j
                break
            end
        end

        # Recurse to the conditional at dest, or generate final block
        if dest_cond_idx !== nothing
            append!(inner_bytes, gen_conditional(dest_cond_idx; target_idx=goto_if_not.dest))
        else
            # No conditional at dest - generate the code at dest directly
            append!(inner_bytes, gen_conditional(length(conditionals) + 1; target_idx=goto_if_not.dest))
        end

        # PURE-3111: If the outer IF has a typed result but the else branch only
        # returns (all paths have explicit RETURN), the else branch doesn't produce
        # a value for the IF block. Emit unreachable to satisfy the typed result —
        # unreachable is polymorphic and satisfies any expected type.
        if used_typed_if[] && else_terminates
            push!(inner_bytes, Opcode.UNREACHABLE)
        end

        push!(inner_bytes, Opcode.END)

        return inner_bytes
    end

    append!(bytes, gen_conditional(1))

    # Check if all code paths terminate inside the conditionals
    # This is the case when:
    # 1. All blocks that are return blocks (have ReturnNode terminator)
    # 2. The function uses void IF blocks because both branches terminate
    #
    # For typed IF blocks (with result type), each branch produces a value,
    # and the IF itself returns a value. If the function returns this value,
    # we don't need RETURN or UNREACHABLE - just fall through with value on stack.
    #
    # For void IF blocks where branches use RETURN, code after IF is unreachable.
    #
    # Count actual return blocks vs total blocks
    return_blocks = count(b -> b.terminator isa Core.ReturnNode, blocks)
    total_blocks = length(blocks)

    # Check if we're using typed IF blocks (branches produce values)
    # If so, the value is on the stack and we just fall through
    # The gen_conditional function uses typed blocks when there's a phi merge
    # or when branches don't use explicit RETURN
    #
    # PURE-506: Use `used_typed_if[]` to determine whether gen_conditional
    # created a typed IF block (value on stack) or void IF block (branches RETURN).
    # The function's result_type alone is insufficient — both clamp_i64 (typed IF)
    # and or_bool (void IF) have I64 result_type, but only clamp leaves a value.
    if used_typed_if[]
        # Typed IF block: value is on the stack from the IF block result.
        # The function's END will implicitly return it — no RETURN/UNREACHABLE needed.
    elseif return_blocks >= 2
        # Void IF blocks: all code paths return inside the conditionals via explicit RETURN,
        # so this point is truly unreachable
        push!(bytes, Opcode.UNREACHABLE)
    elseif result_type isa ConcreteRef || result_type === I32 || result_type === I64 ||
       result_type === F32 || result_type === F64
        # Typed result but void IF blocks — fall through needs a value
        # This shouldn't normally happen, but as a safety net:
        push!(bytes, Opcode.RETURN)
    elseif result_type === ExternRef
        # ExternRef result - IF produces void, need ref.null extern before RETURN
        push!(bytes, Opcode.REF_NULL, UInt8(ExternRef))
        push!(bytes, Opcode.RETURN)
    else
        push!(bytes, Opcode.RETURN)
    end

    return bytes
end

"""
Generate code for a single basic block.
"""
function generate_block_code(ctx::CompilationContext, block::BasicBlock)::Vector{UInt8}
    bytes = UInt8[]
    code = ctx.code_info.code

    for i in block.start_idx:block.end_idx
        stmt_bytes = compile_statement(code[i], i, ctx)
        # PURE-414: Validate emitted bytes for stack type tracking
        validate_emitted_bytes!(ctx, stmt_bytes, i)
        append!(bytes, stmt_bytes)
    end

    return bytes
end

