# findall_wasm.jl — WasmGC findall function using TypeID hash table
#
# Generates a WasmGC module with:
#   - Hash table as i32 array global (initialized from data segment)
#   - MethodLookupResult struct globals
#   - MinimalMethod struct globals
#   - findall_by_typeid(i32) → i32 exported function
#
# The function does: FNV-1a hash → linear probe → return global index.
#
# Phase 2A-005: Compile DictMethodTable.findall to WasmGC with TypeID-based lookup.

using ..WasmTarget: WasmModule, add_function!, add_export!, add_global!,
                    add_struct_type!, add_global_ref!, add_array_type!,
                    I32, I64, ConcreteRef, Opcode, encode_leb128_unsigned,
                    encode_leb128_signed, FieldType, to_bytes, WasmValType,
                    add_passive_data_segment!

"""
    build_findall_module(table, registry::TypeIDRegistry) → (bytes, emitter, extraction)

Build a complete WasmGC module with hash table and findall_by_typeid function.
Returns the WASM bytes and the emitter/extraction for verification.
"""
function build_findall_module(table, registry)
    mod = WasmModule()

    # Step 1: Create emitter and emit method table
    emitter = create_method_table_emitter(mod, registry)
    emit_method_table!(emitter, table)
    build_hash_table!(emitter)

    # Step 2: Extract and emit MinimalMethod globals
    extraction = extract_all_methods(table, registry)
    method_result = emit_minimal_methods!(emitter, extraction)

    # Step 3: Create i32 array type for hash table
    # The emitter already has i32_array_type_idx from create_method_table_emitter
    ht_array_type = emitter.i32_array_type_idx

    # Step 4: Emit hash table as data segment
    seg_idx, seg_bytes = emit_hash_table_data_segment!(emitter)

    # Step 5: Create the hash table array global (mutable, initialized in start func)
    # First create a default-initialized mutable array global
    ht_size = emitter.hash_table_size
    ht_global_idx = _add_ht_array_global!(mod, ht_array_type, ht_size * 2)

    # Step 6: Create start function that copies data segment into array global
    start_func_idx = _add_start_function!(mod, ht_global_idx, ht_array_type, seg_idx, ht_size * 2)

    # Step 7: Create findall_by_typeid function
    findall_func_idx = _add_findall_function!(mod, ht_global_idx, ht_array_type, ht_size)

    # Step 8: Export findall_by_typeid
    add_export!(mod, "findall_by_typeid", 0, findall_func_idx)

    # Step 9: Export start function for initialization
    add_export!(mod, "_initialize", 0, start_func_idx)

    return (bytes=to_bytes(mod), emitter=emitter, extraction=extraction)
end

"""
Add a mutable i32 array global initialized with zeros.
"""
function _add_ht_array_global!(mod::WasmModule, array_type_idx::UInt32, n_elements::Int)
    # Global init expression: i32.const 0 (fill value), i32.const N, array.new $type
    init_expr = UInt8[]
    push!(init_expr, Opcode.I32_CONST)
    append!(init_expr, encode_leb128_signed(Int32(0)))
    push!(init_expr, Opcode.I32_CONST)
    append!(init_expr, encode_leb128_signed(Int32(n_elements)))
    push!(init_expr, Opcode.GC_PREFIX)
    push!(init_expr, Opcode.ARRAY_NEW)
    append!(init_expr, encode_leb128_unsigned(array_type_idx))

    return add_global_ref!(mod, array_type_idx, true, init_expr; nullable=false)
end

"""
Add a start function that initializes the hash table array from the data segment.
Copies data segment values into the array global element by element.
"""
function _add_start_function!(mod::WasmModule, ht_global_idx::UInt32,
                               array_type_idx::UInt32, seg_idx::UInt32,
                               n_elements::Int)
    body = UInt8[]

    # Strategy: read from data segment by creating a temporary i32 array
    # via array.new_data, then copy element by element into the global.
    # Actually, simpler: use array.new_data to create a new array, then
    # store it as the global value.

    # global.get $ht_global_idx — not needed, we'll replace the global entirely

    # Create new array from data segment: array.new_data $type $seg
    # Stack: [offset: i32, length: i32] → [(ref $array_type)]
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(0)))  # offset = 0
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(n_elements)))  # length = N elements
    push!(body, Opcode.GC_PREFIX)
    push!(body, Opcode.ARRAY_NEW_DATA)
    append!(body, encode_leb128_unsigned(array_type_idx))
    append!(body, encode_leb128_unsigned(seg_idx))

    # global.set $ht_global_idx — store the new array
    push!(body, Opcode.GLOBAL_SET)
    append!(body, encode_leb128_unsigned(ht_global_idx))

    push!(body, Opcode.END)

    return add_function!(mod, WasmValType[], WasmValType[], WasmValType[], body)
end

"""
Add the findall_by_typeid(type_id: i32) → i32 function.

Algorithm:
  1. Compute h = fnv1a(type_id) % table_size
  2. slot = h * 2 (key at slot, value at slot+1)
  3. Loop: if ht[slot] == type_id → return ht[slot+1]
          if ht[slot] == -1 → return -1 (not found)
          slot = ((slot/2 + 1) % table_size) * 2
"""
function _add_findall_function!(mod::WasmModule, ht_global_idx::UInt32,
                                 array_type_idx::UInt32, table_size::Int)
    body = UInt8[]
    # Locals: 0=type_id (param), 1=h (i32), 2=slot (i32), 3=key (i32), 4=counter (i32)
    locals = WasmValType[I32, I32, I32, I32]

    # === FNV-1a hash ===
    # h = 0x811c9dc5
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(reinterpret(Int32, UInt32(0x811c9dc5))))
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(1)))  # h

    # Process 4 bytes of type_id
    for byte_idx in 0:3
        # h = h ^ ((type_id >> (byte_idx * 8)) & 0xFF)
        push!(body, Opcode.LOCAL_GET)
        append!(body, encode_leb128_unsigned(UInt32(1)))  # h
        push!(body, Opcode.LOCAL_GET)
        append!(body, encode_leb128_unsigned(UInt32(0)))  # type_id
        if byte_idx > 0
            push!(body, Opcode.I32_CONST)
            append!(body, encode_leb128_signed(Int32(byte_idx * 8)))
            push!(body, Opcode.I32_SHR_U)
        end
        push!(body, Opcode.I32_CONST)
        append!(body, encode_leb128_signed(Int32(0xFF)))
        push!(body, Opcode.I32_AND)
        push!(body, Opcode.I32_XOR)
        # h = h * 0x01000193
        push!(body, Opcode.I32_CONST)
        append!(body, encode_leb128_signed(reinterpret(Int32, UInt32(0x01000193))))
        push!(body, Opcode.I32_MUL)
        push!(body, Opcode.LOCAL_SET)
        append!(body, encode_leb128_unsigned(UInt32(1)))  # h
    end

    # slot = (h % table_size) * 2
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(1)))  # h
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(table_size)))
    push!(body, Opcode.I32_REM_U)
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(2)))
    push!(body, Opcode.I32_MUL)
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(2)))  # slot

    # counter = 0
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(0)))
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(4)))  # counter

    # === Linear probe loop ===
    # block $break
    push!(body, Opcode.BLOCK)
    push!(body, 0x40)  # void block type

    # loop $probe
    push!(body, Opcode.LOOP)
    push!(body, 0x40)  # void loop type

    # If counter >= table_size, break (not found)
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(4)))  # counter
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(table_size)))
    push!(body, Opcode.I32_GE_U)
    push!(body, Opcode.BR_IF)
    append!(body, encode_leb128_unsigned(UInt32(1)))  # br $break

    # key = ht[slot]
    push!(body, Opcode.GLOBAL_GET)
    append!(body, encode_leb128_unsigned(ht_global_idx))
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(2)))  # slot
    push!(body, Opcode.GC_PREFIX)
    push!(body, Opcode.ARRAY_GET)
    append!(body, encode_leb128_unsigned(array_type_idx))
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(3)))  # key

    # If key == -1, break (empty slot = not found)
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(3)))  # key
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(-1)))
    push!(body, Opcode.I32_EQ)
    push!(body, Opcode.BR_IF)
    append!(body, encode_leb128_unsigned(UInt32(1)))  # br $break

    # If key == type_id, return ht[slot+1]
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(3)))  # key
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(0)))  # type_id
    push!(body, Opcode.I32_EQ)
    push!(body, Opcode.IF)
    push!(body, 0x40)  # void

    # Return ht[slot+1] (the global index)
    push!(body, Opcode.GLOBAL_GET)
    append!(body, encode_leb128_unsigned(ht_global_idx))
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(2)))  # slot
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(1)))
    push!(body, Opcode.I32_ADD)
    push!(body, Opcode.GC_PREFIX)
    push!(body, Opcode.ARRAY_GET)
    append!(body, encode_leb128_unsigned(array_type_idx))
    push!(body, Opcode.RETURN)

    push!(body, Opcode.END)  # end if

    # Advance: slot = ((slot/2 + 1) % table_size) * 2
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(2)))  # slot
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(2)))
    push!(body, Opcode.I32_DIV_U)
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(1)))
    push!(body, Opcode.I32_ADD)
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(table_size)))
    push!(body, Opcode.I32_REM_U)
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(2)))
    push!(body, Opcode.I32_MUL)
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(2)))  # slot

    # counter++
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(4)))  # counter
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(1)))
    push!(body, Opcode.I32_ADD)
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(4)))  # counter

    # br $probe (continue loop)
    push!(body, Opcode.BR)
    append!(body, encode_leb128_unsigned(UInt32(0)))  # br $loop

    push!(body, Opcode.END)  # end loop
    push!(body, Opcode.END)  # end block

    # Return -1 (not found)
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(-1)))

    push!(body, Opcode.END)  # end function

    return add_function!(mod, WasmValType[I32], WasmValType[I32], locals, body)
end
