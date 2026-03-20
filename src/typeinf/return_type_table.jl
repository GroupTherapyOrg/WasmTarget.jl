# return_type_table.jl — Build-time return type lookup table for thin_typeinf
#
# At build time, run Core.Compiler.return_type for each DictMethodTable signature.
# Store {composite_hash → return_typeid} in a flat i32 hash table with FNV-1a + linear probe.
# This table enables thin_typeinf to annotate SSA values without full typeinf machinery.
#
# Usage:
#   table = populate_transitive(sigs)
#   registry = build_typeid_registry(table)
#   rt_table = build_return_type_table(table, registry)
#   tid = lookup_return_type(rt_table, composite_hash(callee_tid, [arg_tid1, arg_tid2]))

"""
    composite_hash(callee_typeid::Int32, arg_typeids::Vector{Int32}) → UInt32

FNV-1a hash combining callee TypeID with all argument TypeIDs.
Same algorithm as fnv1a_hash in method_table_emit.jl, extended to multiple keys.
"""
function composite_hash(callee_typeid::Int32, arg_typeids::Vector{Int32})::UInt32
    h = UInt32(0x811c9dc5)  # FNV offset basis
    prime = UInt32(0x01000193)
    # Hash callee TypeID bytes
    for byte_idx in 0:3
        h = xor(h, UInt32((callee_typeid >> (byte_idx * 8)) & 0xFF))
        h *= prime
    end
    # Hash each argument TypeID
    for tid in arg_typeids
        for byte_idx in 0:3
            h = xor(h, UInt32((tid >> (byte_idx * 8)) & 0xFF))
            h *= prime
        end
    end
    return h
end

"""
    lookup_return_type(table::Vector{Int32}, hash::UInt32) → Int32

Look up return TypeID in hash table. Returns -1 if not found.
Table format: interleaved (key, value) pairs, key=-1 = empty slot.
"""
function lookup_return_type(table::Vector{Int32}, hash::UInt32)::Int32
    table_len = length(table)
    table_len == 0 && return Int32(-1)
    table_size = table_len ÷ 2  # Number of (key, value) slots
    table_size == 0 && return Int32(-1)
    slot = hash % UInt32(table_size)
    hash_key = reinterpret(Int32, hash)
    for _ in 1:table_size
        idx = Int(slot) * 2  # 0-based byte offset into pairs
        key = table[idx + 1]  # 1-indexed
        if key == Int32(-1)
            return Int32(-1)  # Empty slot → not found
        end
        if key == hash_key
            return table[idx + 2]  # Found → return TypeID
        end
        slot = (slot + UInt32(1)) % UInt32(table_size)  # Linear probe
    end
    return Int32(-1)  # Table full → not found
end

"""
    build_return_type_table(table::DictMethodTable, registry::TypeIDRegistry) → Vector{Int32}

Build a hash table mapping composite_hash(callee_typeid, arg_typeids...) → return_typeid.

For each method signature Tuple{typeof(f), Arg1, Arg2, ...} in the DictMethodTable:
1. Extract callee TypeID (typeof(f)) and argument TypeIDs
2. Compute return type via Core.Compiler.return_type
3. Compute composite hash and insert into hash table

The result is a flat Vector{Int32} with interleaved (key, value) pairs.
"""
function build_return_type_table(table, registry::TypeIDRegistry;
                                  world::UInt64=table.world)::Vector{Int32}
    entries = Pair{UInt32, Int32}[]

    for (sig, _result) in table.methods
        # Only process concrete call signatures: Tuple{typeof(f), Arg1, Arg2, ...}
        if !(sig isa DataType && sig <: Tuple)
            continue
        end
        params = sig.parameters
        length(params) < 1 && continue

        # Extract callee TypeID (typeof(f)) and arg TypeIDs
        callee_type = params[1]
        callee_tid = get_type_id(registry, callee_type)
        callee_tid < 0 && continue

        arg_tids = Int32[]
        all_known = true
        for i in 2:length(params)
            tid = get_type_id(registry, params[i])
            if tid < 0
                all_known = false
                break
            end
            push!(arg_tids, tid)
        end
        all_known || continue

        # Get return type via Core.Compiler.return_type(sig, world)
        ret_type = try
            Core.Compiler.return_type(sig, world)
        catch
            nothing
        end

        if ret_type === nothing || ret_type === Union{}
            continue
        end

        # Ensure return type has a TypeID (assign if needed)
        ret_tid = get_type_id(registry, ret_type)
        if ret_tid < 0
            ret_tid = assign_type!(registry, ret_type)
        end

        ch = composite_hash(callee_tid, arg_tids)
        push!(entries, ch => ret_tid)
    end

    # Build hash table with ~50% load factor
    n_entries = length(entries)
    table_size = max(16, nextpow(2, n_entries * 2))
    ht = fill(Int32(-1), table_size * 2)  # Interleaved (key, value) pairs

    for (hash, ret_tid) in entries
        hash_key = reinterpret(Int32, hash)
        slot = hash % UInt32(table_size)
        for _ in 1:table_size
            idx = Int(slot) * 2
            if ht[idx + 1] == Int32(-1)
                ht[idx + 1] = hash_key
                ht[idx + 2] = ret_tid
                break
            end
            slot = (slot + UInt32(1)) % UInt32(table_size)
        end
    end

    return ht
end

"""
    _insert_hash_entry!(ht, table_size, hash, value)

Insert a (hash_key, value) pair into the hash table using linear probing.
"""
function _insert_hash_entry!(ht::Vector{Int32}, table_size::Int, hash::UInt32, value::Int32)
    hash_key = reinterpret(Int32, hash)
    slot = hash % UInt32(table_size)
    for _ in 1:table_size
        idx = Int(slot) * 2
        if ht[idx + 1] == Int32(-1)
            ht[idx + 1] = hash_key
            ht[idx + 2] = value
            return
        end
        slot = (slot + UInt32(1)) % UInt32(table_size)
    end
end

# ─── Intrinsic return type registration ──────────────────────────────────────

# Intrinsics in optimized IR: GlobalRef(Base, :mul_int) etc.
# Each intrinsic function value gets its own TypeID since typeof(mul_int) == typeof(add_int).
# Return types are known at build time: arithmetic → same type, comparison → Bool.

# (intrinsic_function, [(arg_types..., return_type), ...])
const _INTRINSIC_RETURN_TYPES = [
    # Arithmetic: T × T → T (for Int64, Int32, Float64, Float32)
    (:mul_int,  [(Int64, Int64, Int64), (Int32, Int32, Int32)]),
    (:add_int,  [(Int64, Int64, Int64), (Int32, Int32, Int32)]),
    (:sub_int,  [(Int64, Int64, Int64), (Int32, Int32, Int32)]),
    (:neg_int,  [(Int64, Int64), (Int32, Int32)]),
    (:and_int,  [(Int64, Int64, Int64), (Int32, Int32, Int32)]),
    (:or_int,   [(Int64, Int64, Int64), (Int32, Int32, Int32)]),
    (:xor_int,  [(Int64, Int64, Int64), (Int32, Int32, Int32)]),
    (:shl_int,  [(Int64, Int64, Int64), (Int32, Int32, Int32)]),
    (:lshr_int, [(Int64, Int64, Int64), (Int32, Int32, Int32)]),
    (:ashr_int, [(Int64, Int64, Int64), (Int32, Int32, Int32)]),
    (:sdiv_int, [(Int64, Int64, Int64), (Int32, Int32, Int32)]),
    (:srem_int, [(Int64, Int64, Int64), (Int32, Int32, Int32)]),
    (:udiv_int, [(Int64, Int64, Int64), (Int32, Int32, Int32)]),
    (:urem_int, [(Int64, Int64, Int64), (Int32, Int32, Int32)]),
    # Float arithmetic
    (:mul_float, [(Float64, Float64, Float64), (Float32, Float32, Float32)]),
    (:add_float, [(Float64, Float64, Float64), (Float32, Float32, Float32)]),
    (:sub_float, [(Float64, Float64, Float64), (Float32, Float32, Float32)]),
    (:div_float, [(Float64, Float64, Float64), (Float32, Float32, Float32)]),
    (:neg_float, [(Float64, Float64), (Float32, Float32)]),
    # Comparisons → Bool
    (:slt_int,  [(Int64, Int64, Bool), (Int32, Int32, Bool)]),
    (:sle_int,  [(Int64, Int64, Bool), (Int32, Int32, Bool)]),
    (:ult_int,  [(Int64, Int64, Bool), (Int32, Int32, Bool)]),
    (:eq_int,   [(Int64, Int64, Bool), (Int32, Int32, Bool)]),
    (:ne_int,   [(Int64, Int64, Bool), (Int32, Int32, Bool)]),
    (:eq_float, [(Float64, Float64, Bool), (Float32, Float32, Bool)]),
    (:lt_float, [(Float64, Float64, Bool), (Float32, Float32, Bool)]),
    (:le_float, [(Float64, Float64, Bool), (Float32, Float32, Bool)]),
    # Conversions
    (:sitofp,   [(Type{Float64}, Int64, Float64), (Type{Float32}, Int32, Float32)]),
    (:fptosi,   [(Type{Int64}, Float64, Int64), (Type{Int32}, Float32, Int32)]),
    (:sext_int, [(Type{Int64}, Int32, Int64)]),
    (:trunc_int,[(Type{Int32}, Int64, Int32), (Type{Bool}, Int64, Bool)]),
    (:zext_int, [(Type{Int64}, Int32, Int64), (Type{Int64}, Bool, Int64)]),
    # Not
    (:not_int,  [(Int64, Int64), (Int32, Int32), (Bool, Bool)]),
]

"""
    register_intrinsic_return_types!(registry::TypeIDRegistry) → Vector{Pair{UInt32, Int32}}

Register intrinsic function values in the TypeID registry and return
hash table entries for their return types. Each intrinsic gets a unique TypeID.
"""
function register_intrinsic_return_types!(registry::TypeIDRegistry)::Vector{Pair{UInt32, Int32}}
    entries = Pair{UInt32, Int32}[]

    for (name, signatures) in _INTRINSIC_RETURN_TYPES
        # Resolve intrinsic function value
        func = try
            getfield(Base, name)
        catch
            try
                getfield(Core.Intrinsics, name)
            catch
                continue
            end
        end

        # Register the function value (not its type) to get a unique TypeID
        callee_tid = assign_type!(registry, func)

        for sig in signatures
            # Last element is return type, rest are arg types
            ret_type = sig[end]
            arg_types = sig[1:end-1]

            arg_tids = Int32[]
            all_known = true
            for at in arg_types
                tid = get_type_id(registry, at)
                if tid < 0
                    tid = assign_type!(registry, at)
                end
                push!(arg_tids, tid)
            end

            ret_tid = get_type_id(registry, ret_type)
            if ret_tid < 0
                ret_tid = assign_type!(registry, ret_type)
            end

            ch = composite_hash(callee_tid, arg_tids)
            push!(entries, ch => ret_tid)
        end
    end

    return entries
end

"""
    build_return_type_table_with_intrinsics(table, registry; world) → Vector{Int32}

Like build_return_type_table but also includes intrinsic return type entries.
This is the table thin_typeinf needs for optimized IR where callees are
intrinsics (Base.mul_int etc.) rather than user-visible functions (Base.*).
"""
function build_return_type_table_with_intrinsics(table, registry::TypeIDRegistry;
                                                   world::UInt64=table.world)::Vector{Int32}
    entries = Pair{UInt32, Int32}[]

    # 1. Add intrinsic entries (registers function values as TypeIDs)
    intrinsic_entries = register_intrinsic_return_types!(registry)
    append!(entries, intrinsic_entries)

    # 2. Add DictMethodTable entries (user functions + Base methods)
    for (sig, _result) in table.methods
        if !(sig isa DataType && sig <: Tuple)
            continue
        end
        params = sig.parameters
        length(params) < 1 && continue

        callee_type = params[1]
        callee_tid = get_type_id(registry, callee_type)
        callee_tid < 0 && continue

        arg_tids = Int32[]
        all_known = true
        for i in 2:length(params)
            tid = get_type_id(registry, params[i])
            if tid < 0
                all_known = false
                break
            end
            push!(arg_tids, tid)
        end
        all_known || continue

        ret_type = try
            Core.Compiler.return_type(sig, world)
        catch
            nothing
        end
        if ret_type === nothing || ret_type === Union{}
            continue
        end

        ret_tid = get_type_id(registry, ret_type)
        if ret_tid < 0
            ret_tid = assign_type!(registry, ret_type)
        end

        ch = composite_hash(callee_tid, arg_tids)
        push!(entries, ch => ret_tid)
    end

    # Build hash table
    n_entries = length(entries)
    table_size = max(16, nextpow(2, n_entries * 2))
    ht = fill(Int32(-1), table_size * 2)

    for (hash, ret_tid) in entries
        _insert_hash_entry!(ht, table_size, hash, ret_tid)
    end

    return ht
end

"""
    return_type_table_stats(table::Vector{Int32}) → NamedTuple

Return statistics about a return type hash table.
"""
function return_type_table_stats(table::Vector{Int32})
    table_size = length(table) ÷ 2
    n_entries = count(i -> table[i * 2 - 1] != Int32(-1), 1:table_size)
    return (
        table_size = table_size,
        n_entries = n_entries,
        load_factor = n_entries / max(1, table_size),
        bytes = length(table) * 4,
    )
end
