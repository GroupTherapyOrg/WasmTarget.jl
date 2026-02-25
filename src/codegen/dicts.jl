# ============================================================================
# SimpleDict Operations - Hash Table Bytecode Generation
# ============================================================================

"""
Find slot for a key in SimpleDict.
Returns: positive if found, negative if insert location, 0 if full.

Algorithm: Linear probing with hash = (key * 31) & 0x7FFFFFFF % capacity + 1
Slot states: 0=empty, 1=occupied, 2=deleted
"""
function compile_sd_find_slot(args, ctx::CompilationContext)::Vector{UInt8}
    bytes = UInt8[]

    # Register SimpleDict type
    register_struct_type!(ctx.mod, ctx.type_registry, SimpleDict)
    dict_info = ctx.type_registry.structs[SimpleDict]
    dict_type_idx = dict_info.wasm_type_idx
    arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, Int32)

    # Allocate locals for this operation
    d_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(dict_type_idx))  # d reference

    key_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)  # key

    capacity_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)  # capacity

    start_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)  # start hash

    iter_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)  # iteration counter

    slot_idx_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)  # current slot index

    slot_state_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)  # current slot state

    result_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)  # result to return

    # Store d in local
    append!(bytes, compile_value(args[1], ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(d_local))

    # Store key in local (ensure i32)
    append!(bytes, compile_value(args[2], ctx))
    key_type = infer_value_type(args[2], ctx)
    if key_type === Int64 || key_type === Int
        push!(bytes, Opcode.I32_WRAP_I64)
    end
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(key_local))

    # Get capacity from dict struct (field 4)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(4))  # capacity is field 4
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(capacity_local))

    # Compute hash: (key * 31) & 0x7FFFFFFF % capacity + 1
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(key_local))
    push!(bytes, Opcode.I32_CONST)
    append!(bytes, encode_leb128_signed(31))
    push!(bytes, Opcode.I32_MUL)
    push!(bytes, Opcode.I32_CONST)
    append!(bytes, encode_leb128_signed(0x7FFFFFFF))
    push!(bytes, Opcode.I32_AND)
    # % capacity
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(capacity_local))
    push!(bytes, Opcode.I32_REM_S)
    # + 1 (1-based index)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(start_local))

    # Initialize iter = 0
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(iter_local))

    # Initialize result = 0 (will be set in loop)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))

    # Outer block for breaking out with result
    push!(bytes, Opcode.BLOCK)  # block $done
    push!(bytes, 0x40)  # void

    # Loop for probing
    push!(bytes, Opcode.LOOP)  # loop $probe
    push!(bytes, 0x40)  # void

    # Check if iter >= capacity (table full)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(capacity_local))
    push!(bytes, Opcode.I32_GE_S)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)  # void
    # result = 0 (full), break
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x02)  # break to $done (past loop and if)
    push!(bytes, Opcode.END)  # end if

    # Calculate slot index: ((start + iter - 1) % capacity) + 1
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(start_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(capacity_local))
    push!(bytes, Opcode.I32_REM_S)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))

    # Get slot state from slots array
    # slots = d.slots (field 2)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(2))  # slots is field 2
    # array.get with slot_idx - 1 (0-based)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET)
    append!(bytes, encode_leb128_unsigned(arr_type_idx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(slot_state_local))

    # Check slot state
    # If empty (0): return -slot_idx (insert here)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_state_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)  # SLOT_EMPTY
    push!(bytes, Opcode.I32_EQ)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)  # void
    # result = -slot_idx
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.I32_SUB)  # 0 - slot_idx = -slot_idx
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x02)  # break to $done
    push!(bytes, Opcode.END)  # end if (empty check)

    # If occupied (1): check if key matches
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_state_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)  # SLOT_OCCUPIED
    push!(bytes, Opcode.I32_EQ)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)  # void

    # Get key from keys array and compare
    # keys = d.keys (field 0)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(0))  # keys is field 0
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET)
    append!(bytes, encode_leb128_unsigned(arr_type_idx))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(key_local))
    push!(bytes, Opcode.I32_EQ)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)  # void
    # Key matches! result = slot_idx
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x03)  # break to $done: 0=this if, 1=occupied if, 2=loop, 3=block
    push!(bytes, Opcode.END)  # end if (key match)

    push!(bytes, Opcode.END)  # end if (occupied check)

    # Continue probing: iter++
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(iter_local))

    # Loop back
    push!(bytes, Opcode.BR)
    push!(bytes, 0x00)  # continue loop

    push!(bytes, Opcode.END)  # end loop
    push!(bytes, Opcode.END)  # end block $done

    # Return result
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_local))

    return bytes
end

"""
Set key=value in SimpleDict.
Uses find_slot logic then updates or inserts.
"""
function compile_sd_set(args, ctx::CompilationContext)::Vector{UInt8}
    bytes = UInt8[]

    # Register SimpleDict type
    register_struct_type!(ctx.mod, ctx.type_registry, SimpleDict)
    dict_info = ctx.type_registry.structs[SimpleDict]
    dict_type_idx = dict_info.wasm_type_idx
    arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, Int32)

    # Store d, key, value in locals
    d_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(dict_type_idx))

    key_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    value_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    # Store d
    append!(bytes, compile_value(args[1], ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(d_local))

    # Store key
    append!(bytes, compile_value(args[2], ctx))
    key_type = infer_value_type(args[2], ctx)
    if key_type === Int64 || key_type === Int
        push!(bytes, Opcode.I32_WRAP_I64)
    end
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(key_local))

    # Store value
    append!(bytes, compile_value(args[3], ctx))
    val_type = infer_value_type(args[3], ctx)
    if val_type === Int64 || val_type === Int
        push!(bytes, Opcode.I32_WRAP_I64)
    end
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(value_local))

    # Find slot using inline find_slot logic
    # Create args array for find_slot call
    find_args = [Core.SlotNumber(0), Core.SlotNumber(0)]  # placeholder - we'll use locals directly

    # Actually, we need to call find_slot with (d, key) - build temporary SSA refs
    # Instead, let's inline a simpler version that just returns slot

    # For sd_set!, we need to:
    # 1. Find the slot (same probing logic)
    # 2. If slot > 0: update value
    # 3. If slot < 0: insert at -slot and increment count

    # Allocate more locals for probing
    capacity_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    start_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    iter_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    slot_idx_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    slot_state_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    result_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    # Get capacity
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(4))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(capacity_local))

    # Compute hash
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(key_local))
    push!(bytes, Opcode.I32_CONST)
    append!(bytes, encode_leb128_signed(31))
    push!(bytes, Opcode.I32_MUL)
    push!(bytes, Opcode.I32_CONST)
    append!(bytes, encode_leb128_signed(0x7FFFFFFF))
    push!(bytes, Opcode.I32_AND)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(capacity_local))
    push!(bytes, Opcode.I32_REM_S)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(start_local))

    # Initialize iter = 0, result = 0
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))

    # Probe loop (same as find_slot)
    push!(bytes, Opcode.BLOCK)  # $done
    push!(bytes, 0x40)
    push!(bytes, Opcode.LOOP)  # $probe
    push!(bytes, 0x40)

    # Check iter >= capacity
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(capacity_local))
    push!(bytes, Opcode.I32_GE_S)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x02)
    push!(bytes, Opcode.END)

    # Calculate slot index
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(start_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(capacity_local))
    push!(bytes, Opcode.I32_REM_S)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))

    # Get slot state
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(2))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET)
    append!(bytes, encode_leb128_unsigned(arr_type_idx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(slot_state_local))

    # Check empty
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_state_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.I32_EQ)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x02)
    push!(bytes, Opcode.END)

    # Check occupied
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_state_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_EQ)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)
    # Check key match
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(0))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET)
    append!(bytes, encode_leb128_unsigned(arr_type_idx))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(key_local))
    push!(bytes, Opcode.I32_EQ)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x03)  # break to $done: 0=this if, 1=occupied if, 2=loop, 3=block
    push!(bytes, Opcode.END)
    push!(bytes, Opcode.END)

    # Continue probing
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x00)
    push!(bytes, Opcode.END)  # loop
    push!(bytes, Opcode.END)  # block

    # Now result has slot: positive = update, negative = insert, 0 = full
    # Check if slot > 0 (update existing)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.I32_GT_S)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)  # void

    # Update: values[slot-1] = value
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(1))  # values
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(value_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_SET)
    append!(bytes, encode_leb128_unsigned(arr_type_idx))

    push!(bytes, Opcode.ELSE)

    # Check if slot < 0 (insert new)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.I32_LT_S)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)

    # Calculate insert index: -result - 1
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.I32_SUB)  # -result = positive slot
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_SUB)  # -1 for 0-based index
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))  # reuse as insert index

    # keys[idx] = key
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(0))  # keys
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(key_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_SET)
    append!(bytes, encode_leb128_unsigned(arr_type_idx))

    # values[idx] = value
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(1))  # values
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(value_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_SET)
    append!(bytes, encode_leb128_unsigned(arr_type_idx))

    # slots[idx] = 1 (occupied)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(2))  # slots
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)  # SLOT_OCCUPIED
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_SET)
    append!(bytes, encode_leb128_unsigned(arr_type_idx))

    # count++ (struct.set for field 3)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(3))  # count
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_SET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(3))

    push!(bytes, Opcode.END)  # if slot < 0
    push!(bytes, Opcode.END)  # else

    # Result is void - nothing left on stack
    return bytes
end

"""
Find slot for a String key in StringDict.
Returns: positive if found, negative if insert location, 0 if full.

Uses str_hash for hashing and string comparison for key matching.
"""
function compile_sdict_find_slot(args, ctx::CompilationContext)::Vector{UInt8}
    bytes = UInt8[]

    # Register StringDict type and get indices
    register_struct_type!(ctx.mod, ctx.type_registry, StringDict)
    dict_info = ctx.type_registry.structs[StringDict]
    dict_type_idx = dict_info.wasm_type_idx
    str_ref_arr_type_idx = get_string_ref_array_type!(ctx.mod, ctx.type_registry)
    i32_arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, Int32)
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

    # Allocate locals
    d_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(dict_type_idx))

    key_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))  # string ref

    capacity_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    start_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    iter_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    slot_idx_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    slot_state_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    result_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    stored_key_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))  # for key comparison

    # Store d in local
    append!(bytes, compile_value(args[1], ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(d_local))

    # Store key in local
    append!(bytes, compile_value(args[2], ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(key_local))

    # Get capacity
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(4))  # capacity is field 4
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(capacity_local))

    # Compute hash using str_hash inlined
    # h = 0; for each char: h = (31 * h + char) & 0x7FFFFFFF
    hash_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    i_hash_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    # Get string length
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(key_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_LEN)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(len_local))

    # Initialize hash = 0, i = 0
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(hash_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(i_hash_local))

    # Hash loop
    push!(bytes, Opcode.BLOCK)
    push!(bytes, 0x40)
    push!(bytes, Opcode.LOOP)
    push!(bytes, 0x40)

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(i_hash_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(len_local))
    push!(bytes, Opcode.I32_GE_S)
    push!(bytes, Opcode.BR_IF)
    push!(bytes, 0x01)

    # hash = (31 * hash + char) & 0x7FFFFFFF
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(hash_local))
    push!(bytes, Opcode.I32_CONST)
    append!(bytes, encode_leb128_signed(31))
    push!(bytes, Opcode.I32_MUL)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(key_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(i_hash_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET)
    append!(bytes, encode_leb128_unsigned(str_type_idx))
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.I32_CONST)
    append!(bytes, encode_leb128_signed(0x7FFFFFFF))
    push!(bytes, Opcode.I32_AND)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(hash_local))

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(i_hash_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(i_hash_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x00)
    push!(bytes, Opcode.END)
    push!(bytes, Opcode.END)

    # start = (hash % capacity) + 1
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(hash_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(capacity_local))
    push!(bytes, Opcode.I32_REM_S)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(start_local))

    # Initialize iter = 0, result = 0
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))

    # Probe loop
    push!(bytes, Opcode.BLOCK)  # $done
    push!(bytes, 0x40)
    push!(bytes, Opcode.LOOP)  # $probe
    push!(bytes, 0x40)

    # Check iter >= capacity
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(capacity_local))
    push!(bytes, Opcode.I32_GE_S)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x02)
    push!(bytes, Opcode.END)

    # slot_idx = ((start + iter - 1) % capacity) + 1
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(start_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(capacity_local))
    push!(bytes, Opcode.I32_REM_S)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))

    # Get slot state
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(2))  # slots field
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET)
    append!(bytes, encode_leb128_unsigned(i32_arr_type_idx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(slot_state_local))

    # Check empty
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_state_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.I32_EQ)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x02)
    push!(bytes, Opcode.END)

    # Check occupied
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_state_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_EQ)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)

    # Get stored key at this slot
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(0))  # keys field
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET)
    append!(bytes, encode_leb128_unsigned(str_ref_arr_type_idx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(stored_key_local))

    # Compare strings using inlined string equality
    # First compare lengths, then compare characters
    append!(bytes, compile_string_eq_inline(key_local, stored_key_local, str_type_idx, ctx))

    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x03)  # break to $done: 0=this if, 1=occupied if, 2=loop, 3=block
    push!(bytes, Opcode.END)

    push!(bytes, Opcode.END)  # occupied

    # Continue probing
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x00)
    push!(bytes, Opcode.END)  # loop
    push!(bytes, Opcode.END)  # block

    # Return result
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_local))

    return bytes
end

"""
Inline string equality comparison.
Compares two string locals and leaves 0 or 1 on stack.
"""
function compile_string_eq_inline(str1_local::Int, str2_local::Int, str_type_idx::UInt32, ctx::CompilationContext)::Vector{UInt8}
    bytes = UInt8[]

    # Allocate locals for comparison
    len1_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    len2_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    cmp_i_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    # Get lengths
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(str1_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_LEN)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(len1_local))

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(str2_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_LEN)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(len2_local))

    # Compare lengths first
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(len1_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(len2_local))
    push!(bytes, Opcode.I32_NE)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x7F)  # i32 result
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)  # not equal
    push!(bytes, Opcode.ELSE)

    # Lengths equal - compare characters
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(cmp_i_local))

    # Result block
    push!(bytes, Opcode.BLOCK)
    push!(bytes, 0x7F)  # i32 result

    # Loop
    push!(bytes, Opcode.LOOP)
    push!(bytes, 0x40)

    # Check i >= len
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(cmp_i_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(len1_local))
    push!(bytes, Opcode.I32_GE_S)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)  # all matched
    push!(bytes, Opcode.BR)
    push!(bytes, 0x02)  # to result block
    push!(bytes, Opcode.END)

    # Compare chars at i
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(str1_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(cmp_i_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET)
    append!(bytes, encode_leb128_unsigned(str_type_idx))

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(str2_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(cmp_i_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET)
    append!(bytes, encode_leb128_unsigned(str_type_idx))

    push!(bytes, Opcode.I32_NE)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)  # mismatch
    push!(bytes, Opcode.BR)
    push!(bytes, 0x02)  # to result block
    push!(bytes, Opcode.END)

    # i++
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(cmp_i_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(cmp_i_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x00)

    push!(bytes, Opcode.END)  # loop

    # Unreachable - loop always exits via br
    push!(bytes, Opcode.UNREACHABLE)

    push!(bytes, Opcode.END)  # result block

    push!(bytes, Opcode.END)  # else of length comparison

    return bytes
end

"""
Set key=value in StringDict.
"""
function compile_sdict_set(args, ctx::CompilationContext)::Vector{UInt8}
    bytes = UInt8[]

    # Register types
    register_struct_type!(ctx.mod, ctx.type_registry, StringDict)
    dict_info = ctx.type_registry.structs[StringDict]
    dict_type_idx = dict_info.wasm_type_idx
    str_ref_arr_type_idx = get_string_ref_array_type!(ctx.mod, ctx.type_registry)
    i32_arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, Int32)
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

    # Store d, key, value in locals
    d_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(dict_type_idx))

    key_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))

    value_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    append!(bytes, compile_value(args[1], ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(d_local))

    append!(bytes, compile_value(args[2], ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(key_local))

    append!(bytes, compile_value(args[3], ctx))
    val_type = infer_value_type(args[3], ctx)
    if val_type === Int64 || val_type === Int
        push!(bytes, Opcode.I32_WRAP_I64)
    end
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(value_local))

    # Call find_slot inline (reuse most of the code from sdict_find_slot)
    # For simplicity, we'll duplicate the probing logic here

    capacity_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    start_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    iter_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    slot_idx_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    slot_state_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    result_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    hash_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    i_hash_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    stored_key_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))

    # Get capacity
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(4))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(capacity_local))

    # Compute hash (same as find_slot)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(key_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_LEN)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(len_local))

    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(hash_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(i_hash_local))

    push!(bytes, Opcode.BLOCK)
    push!(bytes, 0x40)
    push!(bytes, Opcode.LOOP)
    push!(bytes, 0x40)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(i_hash_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(len_local))
    push!(bytes, Opcode.I32_GE_S)
    push!(bytes, Opcode.BR_IF)
    push!(bytes, 0x01)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(hash_local))
    push!(bytes, Opcode.I32_CONST)
    append!(bytes, encode_leb128_signed(31))
    push!(bytes, Opcode.I32_MUL)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(key_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(i_hash_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET)
    append!(bytes, encode_leb128_unsigned(str_type_idx))
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.I32_CONST)
    append!(bytes, encode_leb128_signed(0x7FFFFFFF))
    push!(bytes, Opcode.I32_AND)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(hash_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(i_hash_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(i_hash_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x00)
    push!(bytes, Opcode.END)
    push!(bytes, Opcode.END)

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(hash_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(capacity_local))
    push!(bytes, Opcode.I32_REM_S)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(start_local))

    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))

    # Probe loop
    push!(bytes, Opcode.BLOCK)
    push!(bytes, 0x40)
    push!(bytes, Opcode.LOOP)
    push!(bytes, 0x40)

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(capacity_local))
    push!(bytes, Opcode.I32_GE_S)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x02)
    push!(bytes, Opcode.END)

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(start_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(capacity_local))
    push!(bytes, Opcode.I32_REM_S)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(2))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET)
    append!(bytes, encode_leb128_unsigned(i32_arr_type_idx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(slot_state_local))

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_state_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.I32_EQ)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x02)
    push!(bytes, Opcode.END)

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_state_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_EQ)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(0))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET)
    append!(bytes, encode_leb128_unsigned(str_ref_arr_type_idx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(stored_key_local))

    append!(bytes, compile_string_eq_inline(key_local, stored_key_local, str_type_idx, ctx))

    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x03)  # break to $done: 0=this if, 1=occupied if, 2=loop, 3=block
    push!(bytes, Opcode.END)
    push!(bytes, Opcode.END)

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(iter_local))
    push!(bytes, Opcode.BR)
    push!(bytes, 0x00)
    push!(bytes, Opcode.END)
    push!(bytes, Opcode.END)

    # Now handle update or insert based on result
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.I32_GT_S)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)

    # Update: values[result-1] = value
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(1))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(value_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_SET)
    append!(bytes, encode_leb128_unsigned(i32_arr_type_idx))

    push!(bytes, Opcode.ELSE)

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.I32_LT_S)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)

    # Insert: calculate index = -result - 1
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_SUB)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))

    # keys[idx] = key
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(0))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(key_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_SET)
    append!(bytes, encode_leb128_unsigned(str_ref_arr_type_idx))

    # values[idx] = value
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(1))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(value_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_SET)
    append!(bytes, encode_leb128_unsigned(i32_arr_type_idx))

    # slots[idx] = 1
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(2))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_idx_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_SET)
    append!(bytes, encode_leb128_unsigned(i32_arr_type_idx))

    # count++
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(d_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(3))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_SET)
    append!(bytes, encode_leb128_unsigned(dict_type_idx))
    append!(bytes, encode_leb128_unsigned(3))

    push!(bytes, Opcode.END)  # if slot < 0
    push!(bytes, Opcode.END)  # else

    return bytes
end
