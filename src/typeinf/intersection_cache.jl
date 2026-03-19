# intersection_cache.jl — Pre-computed type intersection cache for WasmGC
#
# Emits DictMethodTable.intersections as a WasmGC hash table.
# Key: hash(TypeID_a, TypeID_b), Value: TypeID_result.
#
# Phase 2A-010: Compile type intersection cache to WasmGC (or eliminate it).
# Decision: Pre-compute for Phase 2a (Option 1). Phase 2b compiles wasm_type_intersection.
#
# Usage:
#   cache = build_intersection_cache(table, registry)
#   result_id = lookup_intersection(cache, type_id_a, type_id_b)

using ..WasmTarget: WasmModule, add_function!, add_export!, add_global!,
                    add_struct_type!, add_global_ref!, add_array_type!,
                    I32, I64, ConcreteRef, Opcode, encode_leb128_unsigned,
                    encode_leb128_signed, FieldType, to_bytes, WasmValType,
                    add_passive_data_segment!

# ─── IntersectionCache ────────────────────────────────────────────────────────

struct IntersectionCache
    # Hash table: composite key (type_id_a, type_id_b) → type_id_result
    # Stored as flat (key_a: i32, key_b: i32, result: i32) triples
    table_size::Int
    entries::Vector{Tuple{Int32, Int32, Int32}}  # (key_a, key_b, result), sentinel: key_a == -1
    n_stored::Int
end

"""
    fnv1a_pair_hash(a::Int32, b::Int32) → UInt32

FNV-1a hash for a pair of Int32 keys.
"""
function fnv1a_pair_hash(a::Int32, b::Int32)::UInt32
    h = UInt32(0x811c9dc5)
    # Hash bytes of a
    for shift in (0, 8, 16, 24)
        h = xor(h, UInt32((a >> shift) & 0xFF))
        h *= UInt32(0x01000193)
    end
    # Hash bytes of b
    for shift in (0, 8, 16, 24)
        h = xor(h, UInt32((b >> shift) & 0xFF))
        h *= UInt32(0x01000193)
    end
    return h
end

"""
    build_intersection_cache(table, registry) → IntersectionCache

Build a pre-computed intersection cache from a DictMethodTable.
"""
function build_intersection_cache(table, registry)
    n = length(table.intersections)
    if n == 0
        return IntersectionCache(16, fill((Int32(-1), Int32(-1), Int32(-1)), 16), 0)
    end

    table_size = max(16, nextpow(2, n * 2))  # ~50% load factor
    entries = fill((Int32(-1), Int32(-1), Int32(-1)), table_size)
    n_stored = 0

    for ((a, b), result) in table.intersections
        id_a = get_type_id(registry, a)
        id_b = get_type_id(registry, b)
        id_r = safe_get_type_id(registry, result)

        if id_a < 0 || id_b < 0
            continue  # Skip types not in registry
        end

        h = fnv1a_pair_hash(id_a, id_b) % UInt32(table_size)
        while entries[h + 1][1] != Int32(-1)
            h = (h + 1) % UInt32(table_size)
        end
        entries[h + 1] = (id_a, id_b, id_r)
        n_stored += 1
    end

    return IntersectionCache(table_size, entries, n_stored)
end

"""
    lookup_intersection(cache, type_id_a, type_id_b) → Int32

Look up a pre-computed intersection. Returns TypeID of result, or -1 if not found.
"""
function lookup_intersection(cache::IntersectionCache, type_id_a::Int32, type_id_b::Int32)::Int32
    if cache.table_size == 0
        return Int32(-1)
    end
    h = fnv1a_pair_hash(type_id_a, type_id_b) % UInt32(cache.table_size)
    for _ in 1:cache.table_size
        ka, kb, kr = cache.entries[h + 1]
        if ka == Int32(-1)
            return Int32(-1)  # Empty slot = not found
        end
        if ka == type_id_a && kb == type_id_b
            return kr
        end
        h = (h + 1) % UInt32(cache.table_size)
    end
    return Int32(-1)
end

# ─── Data Segment Emission ────────────────────────────────────────────────────

"""
    emit_intersection_data_segment!(mod, cache) → (seg_idx, data_size)

Serialize the intersection cache as a passive data segment.
Format: alternating i32 triples (key_a, key_b, result) in little-endian, 12 bytes/slot.
"""
function emit_intersection_data_segment!(mod::WasmModule, cache::IntersectionCache)
    n_bytes = cache.table_size * 12  # 3 × 4 bytes per slot
    data = Vector{UInt8}(undef, n_bytes)

    for (i, (ka, kb, kr)) in enumerate(cache.entries)
        offset = (i - 1) * 12
        for (j, val) in enumerate([ka, kb, kr])
            bo = offset + (j - 1) * 4
            data[bo + 1] = UInt8(val & 0xFF)
            data[bo + 2] = UInt8((val >> 8) & 0xFF)
            data[bo + 3] = UInt8((val >> 16) & 0xFF)
            data[bo + 4] = UInt8((val >> 24) & 0xFF)
        end
    end

    seg_idx = add_passive_data_segment!(mod, data)
    return (seg_idx, n_bytes)
end

# ─── WasmGC Function Emission ─────────────────────────────────────────────────

"""
    add_intersection_lookup_function!(mod, array_type_idx, global_idx, table_size) → func_idx

Add intersection_lookup(type_id_a: i32, type_id_b: i32) → i32 function.
Same FNV-1a pair hash + linear probe pattern as findall_by_typeid.
"""
function add_intersection_lookup_function!(mod::WasmModule, array_type_idx::UInt32,
                                            global_idx::UInt32, table_size::Int)
    body = UInt8[]
    # Params: 0=type_id_a, 1=type_id_b
    # Locals: 2=h, 3=slot, 4=key_a, 5=key_b, 6=counter
    locals = WasmValType[I32, I32, I32, I32, I32]

    # === FNV-1a pair hash ===
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(reinterpret(Int32, UInt32(0x811c9dc5))))
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(2)))  # h

    # Hash type_id_a (4 bytes)
    for byte_idx in 0:3
        push!(body, Opcode.LOCAL_GET)
        append!(body, encode_leb128_unsigned(UInt32(2)))  # h
        push!(body, Opcode.LOCAL_GET)
        append!(body, encode_leb128_unsigned(UInt32(0)))  # type_id_a
        if byte_idx > 0
            push!(body, Opcode.I32_CONST)
            append!(body, encode_leb128_signed(Int32(byte_idx * 8)))
            push!(body, Opcode.I32_SHR_U)
        end
        push!(body, Opcode.I32_CONST)
        append!(body, encode_leb128_signed(Int32(0xFF)))
        push!(body, Opcode.I32_AND)
        push!(body, Opcode.I32_XOR)
        push!(body, Opcode.I32_CONST)
        append!(body, encode_leb128_signed(reinterpret(Int32, UInt32(0x01000193))))
        push!(body, Opcode.I32_MUL)
        push!(body, Opcode.LOCAL_SET)
        append!(body, encode_leb128_unsigned(UInt32(2)))
    end

    # Hash type_id_b (4 bytes)
    for byte_idx in 0:3
        push!(body, Opcode.LOCAL_GET)
        append!(body, encode_leb128_unsigned(UInt32(2)))
        push!(body, Opcode.LOCAL_GET)
        append!(body, encode_leb128_unsigned(UInt32(1)))  # type_id_b
        if byte_idx > 0
            push!(body, Opcode.I32_CONST)
            append!(body, encode_leb128_signed(Int32(byte_idx * 8)))
            push!(body, Opcode.I32_SHR_U)
        end
        push!(body, Opcode.I32_CONST)
        append!(body, encode_leb128_signed(Int32(0xFF)))
        push!(body, Opcode.I32_AND)
        push!(body, Opcode.I32_XOR)
        push!(body, Opcode.I32_CONST)
        append!(body, encode_leb128_signed(reinterpret(Int32, UInt32(0x01000193))))
        push!(body, Opcode.I32_MUL)
        push!(body, Opcode.LOCAL_SET)
        append!(body, encode_leb128_unsigned(UInt32(2)))
    end

    # slot = (h % table_size) * 3
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(2)))
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(table_size)))
    push!(body, Opcode.I32_REM_U)
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(3)))
    push!(body, Opcode.I32_MUL)
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(3)))  # slot

    # counter = 0
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(0)))
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(6)))

    # === Linear probe loop ===
    push!(body, Opcode.BLOCK)
    push!(body, 0x40)
    push!(body, Opcode.LOOP)
    push!(body, 0x40)

    # If counter >= table_size, break
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(6)))
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(table_size)))
    push!(body, Opcode.I32_GE_U)
    push!(body, Opcode.BR_IF)
    append!(body, encode_leb128_unsigned(UInt32(1)))

    # key_a = array[slot]
    push!(body, Opcode.GLOBAL_GET)
    append!(body, encode_leb128_unsigned(global_idx))
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(3)))  # slot
    push!(body, Opcode.GC_PREFIX)
    push!(body, Opcode.ARRAY_GET)
    append!(body, encode_leb128_unsigned(array_type_idx))
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(4)))  # key_a

    # If key_a == -1, break (empty)
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(4)))
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(-1)))
    push!(body, Opcode.I32_EQ)
    push!(body, Opcode.BR_IF)
    append!(body, encode_leb128_unsigned(UInt32(1)))

    # key_b = array[slot+1]
    push!(body, Opcode.GLOBAL_GET)
    append!(body, encode_leb128_unsigned(global_idx))
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(3)))
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(1)))
    push!(body, Opcode.I32_ADD)
    push!(body, Opcode.GC_PREFIX)
    push!(body, Opcode.ARRAY_GET)
    append!(body, encode_leb128_unsigned(array_type_idx))
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(5)))  # key_b

    # If key_a == type_id_a && key_b == type_id_b, return array[slot+2]
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(4)))  # key_a
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(0)))  # type_id_a
    push!(body, Opcode.I32_EQ)
    push!(body, Opcode.IF)
    push!(body, 0x40)

    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(5)))  # key_b
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(1)))  # type_id_b
    push!(body, Opcode.I32_EQ)
    push!(body, Opcode.IF)
    push!(body, 0x40)

    # Return array[slot+2]
    push!(body, Opcode.GLOBAL_GET)
    append!(body, encode_leb128_unsigned(global_idx))
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(3)))
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(2)))
    push!(body, Opcode.I32_ADD)
    push!(body, Opcode.GC_PREFIX)
    push!(body, Opcode.ARRAY_GET)
    append!(body, encode_leb128_unsigned(array_type_idx))
    push!(body, Opcode.RETURN)

    push!(body, Opcode.END)  # end inner if
    push!(body, Opcode.END)  # end outer if

    # Advance: slot = ((slot/3 + 1) % table_size) * 3
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(3)))
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(3)))
    push!(body, Opcode.I32_DIV_U)
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(1)))
    push!(body, Opcode.I32_ADD)
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(table_size)))
    push!(body, Opcode.I32_REM_U)
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(3)))
    push!(body, Opcode.I32_MUL)
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(3)))

    # counter++
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(6)))
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(1)))
    push!(body, Opcode.I32_ADD)
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(6)))

    push!(body, Opcode.BR)
    append!(body, encode_leb128_unsigned(UInt32(0)))

    push!(body, Opcode.END)  # end loop
    push!(body, Opcode.END)  # end block

    # Return -1
    push!(body, Opcode.I32_CONST)
    append!(body, encode_leb128_signed(Int32(-1)))
    push!(body, Opcode.END)

    return add_function!(mod, WasmValType[I32, I32], WasmValType[I32], locals, body)
end

"""
    build_intersection_module(table, registry) → (bytes, cache)

Build a WasmGC module with intersection cache and lookup function.
"""
function build_intersection_module(table, registry)
    mod = WasmModule()

    cache = build_intersection_cache(table, registry)

    # Array type for i32
    array_type_idx = add_array_type!(mod, I32, true)

    # Emit data segment
    seg_idx, seg_bytes = emit_intersection_data_segment!(mod, cache)

    # Array global (initialized from data segment)
    n_elements = cache.table_size * 3
    init_expr = UInt8[]
    push!(init_expr, Opcode.I32_CONST)
    append!(init_expr, encode_leb128_signed(Int32(0)))
    push!(init_expr, Opcode.I32_CONST)
    append!(init_expr, encode_leb128_signed(Int32(n_elements)))
    push!(init_expr, Opcode.GC_PREFIX)
    push!(init_expr, Opcode.ARRAY_NEW)
    append!(init_expr, encode_leb128_unsigned(array_type_idx))
    global_idx = add_global_ref!(mod, array_type_idx, true, init_expr; nullable=false)

    # Start function to initialize from data segment
    start_body = UInt8[]
    push!(start_body, Opcode.I32_CONST)
    append!(start_body, encode_leb128_signed(Int32(0)))
    push!(start_body, Opcode.I32_CONST)
    append!(start_body, encode_leb128_signed(Int32(n_elements)))
    push!(start_body, Opcode.GC_PREFIX)
    push!(start_body, Opcode.ARRAY_NEW_DATA)
    append!(start_body, encode_leb128_unsigned(array_type_idx))
    append!(start_body, encode_leb128_unsigned(seg_idx))
    push!(start_body, Opcode.GLOBAL_SET)
    append!(start_body, encode_leb128_unsigned(global_idx))
    push!(start_body, Opcode.END)
    start_idx = add_function!(mod, WasmValType[], WasmValType[], WasmValType[], start_body)

    # Lookup function
    lookup_idx = add_intersection_lookup_function!(mod, array_type_idx, global_idx, cache.table_size)

    add_export!(mod, "_initialize", 0, start_idx)
    add_export!(mod, "intersection_lookup", 0, lookup_idx)

    return (bytes=to_bytes(mod), cache=cache)
end
