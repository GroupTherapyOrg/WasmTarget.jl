# method_table_emit.jl — Emit DictMethodTable as WasmGC constant globals
#
# Converts DictMethodTable entries into WasmGC struct globals:
#   - Each MethodLookupResult → WasmGC struct: {matches_count, method_idx, ambig, world_min, world_max}
#   - TypeID → MethodLookupResult global index mapping via hash table
#
# Uses add_global_ref! from Builder/Instructions.jl for struct globals.
# Uses data segments for the hash table backing array.
#
# Phase 2A-002: Initial implementation for the method table emission layer.

using ..WasmTarget: WasmModule, add_struct_type!, add_global_ref!, add_array_type!,
                    I32, I64, ConcreteRef, Opcode, encode_leb128_unsigned, encode_leb128_signed,
                    FieldType

"""
    MethodTableEmitter

State for emitting method table data into a WasmModule.
"""
mutable struct MethodTableEmitter
    mod::WasmModule
    registry::TypeIDRegistry

    # WasmGC type indices for our structs
    result_type_idx::UInt32        # struct type for MethodLookupResult
    i32_array_type_idx::UInt32     # array type for i32 (method indices, hash table)

    # Global indices: TypeID → global index of the MethodLookupResult
    type_to_global::Dict{Int32, UInt32}

    # Hash table: maps TypeID (i32) → global index of MethodLookupResult
    hash_table_size::Int
    hash_table::Vector{Tuple{Int32, Int32}}  # (type_id, global_idx) pairs, -1 = empty
end

"""
    create_method_table_emitter(mod, registry) → MethodTableEmitter

Set up the WasmGC types needed for method table emission.

Creates:
- A struct type for MethodLookupResult: {matches_count: i32, first_method_idx: i32, ambig: i32, world_min: i64, world_max: i64}
- An array type for i32 (used for hash table and method index arrays)
"""
function create_method_table_emitter(mod::WasmModule, registry::TypeIDRegistry)
    # Define MethodLookupResult WasmGC struct type
    # Fields: matches_count (i32), first_method_idx (i32), ambig (i32), world_min (i64), world_max (i64)
    result_fields = FieldType[
        FieldType(I32, false),   # matches_count (immutable)
        FieldType(I32, false),   # first_method_idx (immutable)
        FieldType(I32, false),   # ambig (0 or 1, immutable)
        FieldType(I64, false),   # world_min (immutable)
        FieldType(I64, false),   # world_max (immutable)
    ]
    result_type_idx = add_struct_type!(mod, result_fields)

    # Define i32 array type for hash table backing
    i32_array_type_idx = add_array_type!(mod, I32, true)

    return MethodTableEmitter(
        mod, registry,
        result_type_idx, i32_array_type_idx,
        Dict{Int32, UInt32}(),
        0, Tuple{Int32, Int32}[]
    )
end

"""
    emit_method_table!(emitter, table::DictMethodTable)

Emit all method table entries as WasmGC struct globals.
Returns the emitter for chaining.
"""
function emit_method_table!(emitter::MethodTableEmitter, table)
    # For each method signature in the table, create a WasmGC global
    for (sig, result) in table.methods
        type_id = get_type_id(emitter.registry, sig)
        if type_id < 0
            continue  # Skip types not in the registry
        end

        # Extract MethodLookupResult fields
        matches_count = Int32(length(result.matches))
        first_method_idx = Int32(0)  # TODO: Phase 2A-004 will add method index mapping
        ambig = Int32(result.ambig ? 1 : 0)
        # WorldRange fields are UInt64 — reinterpret to Int64 for LEB128 encoding
        world_min = reinterpret(Int64, UInt64(result.valid_worlds.min_world))
        world_max = reinterpret(Int64, UInt64(result.valid_worlds.max_world))

        # Build struct.new init expression
        init_expr = UInt8[]

        # Push field values
        # matches_count: i32
        push!(init_expr, Opcode.I32_CONST)
        append!(init_expr, encode_leb128_signed(matches_count))

        # first_method_idx: i32
        push!(init_expr, Opcode.I32_CONST)
        append!(init_expr, encode_leb128_signed(first_method_idx))

        # ambig: i32
        push!(init_expr, Opcode.I32_CONST)
        append!(init_expr, encode_leb128_signed(ambig))

        # world_min: i64
        push!(init_expr, Opcode.I64_CONST)
        append!(init_expr, encode_leb128_signed(world_min))

        # world_max: i64
        push!(init_expr, Opcode.I64_CONST)
        append!(init_expr, encode_leb128_signed(world_max))

        # struct.new $result_type_idx
        push!(init_expr, Opcode.GC_PREFIX)
        push!(init_expr, Opcode.STRUCT_NEW)
        append!(init_expr, encode_leb128_unsigned(emitter.result_type_idx))

        # Add as global
        global_idx = add_global_ref!(emitter.mod, emitter.result_type_idx, false, init_expr; nullable=false)
        emitter.type_to_global[type_id] = global_idx
    end

    return emitter
end

"""
    build_hash_table!(emitter)

Build the TypeID → global index hash table using open addressing with linear probing.
The hash table is a flat array of (key, value) pairs stored as i32 alternating entries.
"""
function build_hash_table!(emitter::MethodTableEmitter)
    n_entries = length(emitter.type_to_global)
    # Size = 2x entries for ~50% load factor
    table_size = max(16, nextpow(2, n_entries * 2))
    emitter.hash_table_size = table_size

    # Initialize with sentinel: key=-1 means empty
    emitter.hash_table = fill((Int32(-1), Int32(-1)), table_size)

    # Insert using linear probing
    for (type_id, global_idx) in emitter.type_to_global
        h = fnv1a_hash(type_id) % table_size
        while emitter.hash_table[h + 1][1] != Int32(-1)
            h = (h + 1) % table_size
        end
        emitter.hash_table[h + 1] = (type_id, Int32(global_idx))
    end

    return emitter
end

"""
    fnv1a_hash(id::Int32) → UInt32

FNV-1a hash for a single Int32 key.
"""
function fnv1a_hash(id::Int32)::UInt32
    h = UInt32(0x811c9dc5)  # FNV offset basis
    bytes = reinterpret(UInt8, [id])
    for b in bytes
        h = xor(h, UInt32(b))
        h *= UInt32(0x01000193)  # FNV prime
    end
    return h
end

"""
    emit_hash_table_data_segment!(emitter) → (segment_idx, data_size)

Serialize the hash table as a passive data segment for use with array.new_data.
The data segment contains alternating (key: i32, value: i32) pairs in little-endian.
Empty slots have key = -1.

Returns the data segment index and the byte size.
"""
function emit_hash_table_data_segment!(emitter::MethodTableEmitter)
    # Serialize as flat byte array: [key0_le, val0_le, key1_le, val1_le, ...]
    n_bytes = emitter.hash_table_size * 8  # 4 bytes key + 4 bytes value per slot
    data = Vector{UInt8}(undef, n_bytes)

    for (i, (key, val)) in enumerate(emitter.hash_table)
        offset = (i - 1) * 8
        # Little-endian i32 for key
        data[offset + 1] = UInt8(key & 0xFF)
        data[offset + 2] = UInt8((key >> 8) & 0xFF)
        data[offset + 3] = UInt8((key >> 16) & 0xFF)
        data[offset + 4] = UInt8((key >> 24) & 0xFF)
        # Little-endian i32 for value
        data[offset + 5] = UInt8(val & 0xFF)
        data[offset + 6] = UInt8((val >> 8) & 0xFF)
        data[offset + 7] = UInt8((val >> 16) & 0xFF)
        data[offset + 8] = UInt8((val >> 24) & 0xFF)
    end

    using_mod = emitter.mod
    seg_idx = WasmTarget.add_passive_data_segment!(using_mod, data)
    return (seg_idx, n_bytes)
end

"""
    lookup_hash_table(emitter, type_id) → Int32

Look up a TypeID in the hash table. Returns the global index, or -1 if not found.
This is the Julia-side equivalent of the WasmGC lookup function.
"""
function lookup_hash_table(emitter::MethodTableEmitter, type_id::Int32)::Int32
    if emitter.hash_table_size == 0
        return Int32(-1)
    end
    h = fnv1a_hash(type_id) % emitter.hash_table_size
    for _ in 1:emitter.hash_table_size
        key, val = emitter.hash_table[h + 1]
        if key == type_id
            return val
        elseif key == Int32(-1)
            return Int32(-1)  # Empty slot = not found
        end
        h = (h + 1) % emitter.hash_table_size
    end
    return Int32(-1)
end

"""
    get_emit_stats(emitter) → NamedTuple

Return statistics about the emitted method table.
"""
function get_emit_stats(emitter::MethodTableEmitter)
    return (
        n_globals = length(emitter.type_to_global),
        hash_table_size = emitter.hash_table_size,
        hash_table_entries = count(x -> x[1] != Int32(-1), emitter.hash_table),
        load_factor = length(emitter.type_to_global) / max(1, emitter.hash_table_size),
    )
end
