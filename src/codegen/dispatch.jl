# ============================================================================
# PURE-9060: Tier 2 Hash-Based Dispatch Tables (FNV-1a)
# ============================================================================
#
# Megamorphic dispatch via compile-time hash tables for functions with >8
# specializations. Uses FNV-1a hash on typeId tuples, linear probing,
# and call_indirect through a funcref table of anyref wrapper functions.
#
# Architecture:
#   1. At compile time: group specializations by generic function
#   2. For each with >8 targets: build FNV-1a hash table
#   3. Generate wrapper functions: (anyref...) -> result_type
#   4. Emit WasmGC arrays as globals for keys/values/typeIds
#   5. At call sites: extract typeIds → hash → probe → call_indirect

# ==================== FNV-1a Constants ====================

const FNV_OFFSET_BASIS = UInt32(0x811c9dc5)  # 2166136261
const FNV_PRIME = UInt32(0x01000193)          # 16777619

# ==================== Data Structures ====================

"""
Compute FNV-1a hash of a vector of Int32 type IDs.
"""
function fnv1a_hash(type_ids::Vector{Int32})::UInt32
    h = FNV_OFFSET_BASIS
    for tid in type_ids
        h = xor(h, reinterpret(UInt32, tid))
        h = h * FNV_PRIME
    end
    return h
end

"""
One entry in a dispatch hash table (compile-time).
"""
struct DispatchEntry
    type_ids::Vector{Int32}   # DFS type IDs per argument
    hash::UInt32              # FNV-1a hash of type_ids
    target_idx::UInt32        # Wasm func index of actual specialization
    wrapper_idx::UInt32       # Wasm func index of anyref wrapper (filled later)
end

"""
Hash-based dispatch table for a single generic function.
"""
mutable struct DispatchTable
    func_ref::Any              # Julia function being dispatched
    arity::Int32               # Number of dispatch arguments
    entries::Vector{DispatchEntry}
    table_size::Int32          # Power of 2
    mask::Int32                # table_size - 1
    # Filled during emit phase:
    dispatch_sig_idx::UInt32   # Type idx for uniform dispatch signature
    keys_global_idx::UInt32    # Global: i32 array of hash keys
    values_global_idx::UInt32  # Global: i32 array of funcref table indices
    typeids_global_idx::UInt32 # Global: i32 array of flat type IDs
    func_table_idx::UInt32     # funcref table index for call_indirect
    i32_array_type_idx::UInt32 # Type idx for (array (mut i32))
    result_wasm_type::WasmValType  # Return type of dispatch
end

"""
Registry of dispatch tables for a module.
"""
mutable struct DispatchTableRegistry
    tables::Dict{Any, DispatchTable}  # func_ref -> DispatchTable
end

DispatchTableRegistry() = DispatchTableRegistry(Dict{Any, DispatchTable}())

"""Check if a function has a hash dispatch table."""
has_dispatch_table(reg::DispatchTableRegistry, func_ref) = haskey(reg.tables, func_ref)

"""Get the dispatch table for a function."""
get_dispatch_table(reg::DispatchTableRegistry, func_ref) = get(reg.tables, func_ref, nothing)

# ==================== Table Building ====================

"""
Resolve hash table layout using linear probing.
Returns parallel arrays: (keys, values, type_ids_flat)
- keys[i] = hash key at slot i (0 = empty sentinel)
- values[i] = funcref table index at slot i
- type_ids_flat = flat array, arity entries per slot
"""
function resolve_table_layout(dt::DispatchTable)
    n = Int(dt.table_size)
    keys = zeros(UInt32, n)
    values = zeros(UInt32, n)
    type_ids_flat = zeros(Int32, n * Int(dt.arity))

    for (entry_i, entry) in enumerate(dt.entries)
        h = entry.hash
        # Avoid 0 as hash (sentinel for empty slot)
        if h == UInt32(0)
            h = UInt32(1)
        end
        slot = Int((h & UInt32(dt.mask))) + 1  # 1-indexed

        # Linear probing
        iterations = 0
        while keys[slot] != 0
            slot = slot % n + 1
            iterations += 1
            iterations >= n && error("Dispatch hash table full — this should not happen with load factor ≤ 0.75")
        end

        keys[slot] = h
        values[slot] = entry_i - 1  # 0-indexed funcref table element
        for (j, tid) in enumerate(entry.type_ids)
            type_ids_flat[(slot - 1) * Int(dt.arity) + j] = tid
        end
    end

    return (keys, values, type_ids_flat)
end

"""
Build dispatch tables for all functions with ≥ threshold specializations.
Called after assign_type_ids! and function registration.

Returns a DispatchTableRegistry containing tables for megamorphic functions.
"""
function build_dispatch_tables(func_registry::FunctionRegistry,
                                type_registry::TypeRegistry;
                                threshold::Int=9)::DispatchTableRegistry
    dt_registry = DispatchTableRegistry()

    for (func_ref, infos) in func_registry.by_ref
        length(infos) < threshold && continue

        # Determine arity (skip the function type itself if present in arg_types)
        # In func_registry, arg_types includes the function type for closures
        arities = Set{Int}()
        for info in infos
            push!(arities, length(info.arg_types))
        end
        if length(arities) != 1
            @warn "PURE-9060: Skipping dispatch table for $(func_ref): mixed arities $(arities)"
            continue
        end
        arity = first(arities)

        # All specializations must return the same Wasm type
        return_types = Set{Type}()
        for info in infos
            push!(return_types, info.return_type)
        end
        if length(return_types) != 1
            @warn "PURE-9060: Skipping dispatch table for $(func_ref): mixed return types $(return_types)"
            continue
        end
        return_type = first(return_types)

        # Build entries with type IDs
        entries = DispatchEntry[]
        all_valid = true
        for info in infos
            type_ids = Int32[]
            for T in info.arg_types
                tid = get_type_id(type_registry, T)
                if tid == Int32(0)
                    @warn "PURE-9060: No type ID for $(T) — skipping dispatch entry"
                    all_valid = false
                    break
                end
                push!(type_ids, tid)
            end
            all_valid || continue

            h = fnv1a_hash(type_ids)
            push!(entries, DispatchEntry(type_ids, h, info.wasm_idx, UInt32(0)))
        end

        length(entries) < threshold && continue

        # Table size: next power of 2 with load factor ≤ 0.75
        min_size = ceil(Int, length(entries) / 0.75)
        table_size = Int32(1)
        while table_size < min_size
            table_size *= Int32(2)
        end

        result_wasm = julia_to_wasm_type(return_type)

        dt = DispatchTable(
            func_ref, Int32(arity), entries,
            table_size, table_size - Int32(1),
            UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0),
            result_wasm
        )
        dt_registry.tables[func_ref] = dt
    end

    return dt_registry
end

# ==================== Wasm Codegen ====================

"""
Phase 1: Emit dispatch metadata (signatures, globals, funcref table placeholder).
Called BEFORE body compilation so that emit_dispatch_call! can reference global indices.
Does NOT add wrapper functions — those are deferred to emit_dispatch_wrappers!.
"""
function emit_dispatch_metadata!(mod::WasmModule,
                                  type_registry::TypeRegistry,
                                  dt_registry::DispatchTableRegistry)
    isempty(dt_registry.tables) && return

    # Get or create i32 array type (reuse string array if available)
    i32_array_idx = if type_registry.string_array_idx !== nothing
        type_registry.string_array_idx
    else
        add_array_type!(mod, I32, true)
    end

    for (func_ref, dt) in dt_registry.tables
        dt.i32_array_type_idx = i32_array_idx

        # --- 1. Create dispatch signature type ---
        param_types = fill(AnyRef, Int(dt.arity))
        result_types = dt.result_wasm_type == I32 || dt.result_wasm_type == I64 ||
                       dt.result_wasm_type == F32 || dt.result_wasm_type == F64 ?
                       WasmValType[dt.result_wasm_type] : WasmValType[]
        dispatch_sig_idx = add_type!(mod, FuncType(param_types, result_types))
        dt.dispatch_sig_idx = dispatch_sig_idx

        # --- 2. Create funcref table (element segment added later with correct wrapper indices) ---
        table_idx = add_table!(mod, FuncRef, UInt32(length(dt.entries)))
        dt.func_table_idx = table_idx

        # --- 3. Build hash table and emit as globals ---
        keys, values, type_ids_flat = resolve_table_layout(dt)

        keys_init = emit_i32_array_init(i32_array_idx, keys)
        dt.keys_global_idx = add_global_ref!(mod, i32_array_idx, false, keys_init; nullable=false)

        values_init = emit_i32_array_init(i32_array_idx, values)
        dt.values_global_idx = add_global_ref!(mod, i32_array_idx, false, values_init; nullable=false)

        typeids_init = emit_i32_array_init(i32_array_idx, type_ids_flat)
        dt.typeids_global_idx = add_global_ref!(mod, i32_array_idx, false, typeids_init; nullable=false)
    end
end

"""
Phase 2: Emit wrapper functions and element segments.
Called AFTER all actual functions are added to the module, so entry.target_idx
values (set from func_registry during build_dispatch_tables) are correct.
"""
function emit_dispatch_wrappers!(mod::WasmModule,
                                  type_registry::TypeRegistry,
                                  dt_registry::DispatchTableRegistry)
    isempty(dt_registry.tables) && return

    for (func_ref, dt) in dt_registry.tables
        param_types = fill(AnyRef, Int(dt.arity))
        result_types = dt.result_wasm_type == I32 || dt.result_wasm_type == I64 ||
                       dt.result_wasm_type == F32 || dt.result_wasm_type == F64 ?
                       WasmValType[dt.result_wasm_type] : WasmValType[]

        wrapper_indices = UInt32[]
        for (entry_i, entry) in enumerate(dt.entries)
            body = UInt8[]

            # For each parameter: local.get + ref.cast to concrete type
            for (j, tid) in enumerate(entry.type_ids)
                push!(body, Opcode.LOCAL_GET)
                append!(body, encode_leb128_unsigned(UInt32(j - 1)))

                # Find the concrete Julia type for this typeId
                concrete_type = nothing
                for (T, id) in type_registry.type_ids
                    if id == tid
                        concrete_type = T
                        break
                    end
                end

                if concrete_type !== nothing && haskey(type_registry.structs, concrete_type)
                    struct_info = type_registry.structs[concrete_type]
                    push!(body, Opcode.GC_PREFIX)
                    push!(body, Opcode.REF_CAST)
                    append!(body, encode_leb128_signed(Int64(struct_info.wasm_type_idx)))
                end
            end

            # call $target — target_idx is correct because actual functions were added first
            push!(body, Opcode.CALL)
            append!(body, encode_leb128_unsigned(entry.target_idx))

            push!(body, Opcode.END)

            wrapper_idx = add_function!(mod, param_types, result_types, WasmValType[], body)
            push!(wrapper_indices, wrapper_idx)

            dt.entries[entry_i] = DispatchEntry(
                entry.type_ids, entry.hash, entry.target_idx, wrapper_idx
            )
        end

        # Add element segment with correct wrapper indices
        add_elem_segment!(mod, dt.func_table_idx, 0, wrapper_indices)
    end
end


"""
Emit init expression for an i32 array with constant values.
Uses array.new_fixed for small arrays, or array.new + array.set for larger ones.
Returns bytecode WITHOUT the trailing END byte (add_global_ref! adds it).
"""
function emit_i32_array_init(array_type_idx::UInt32, values::AbstractVector)::Vector{UInt8}
    bytes = UInt8[]
    n = length(values)

    if n <= 128
        # array.new_fixed: push all elements, then array.new_fixed type_idx count
        for v in values
            push!(bytes, Opcode.I32_CONST)
            # Safely convert to signed i32 for LEB128 encoding (handles UInt32 > 2^31)
            signed_v = reinterpret(Int32, UInt32(v & 0xFFFFFFFF))
            append!(bytes, encode_leb128_signed(signed_v))
        end
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_NEW_FIXED)
        append!(bytes, encode_leb128_unsigned(array_type_idx))
        append!(bytes, encode_leb128_unsigned(UInt32(n)))
    else
        # For large arrays: array.new (default 0) then array.set for non-zero elements
        push!(bytes, Opcode.I32_CONST)
        append!(bytes, encode_leb128_signed(Int32(0)))  # default value
        push!(bytes, Opcode.I32_CONST)
        append!(bytes, encode_leb128_unsigned(UInt32(n)))  # length
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_NEW)
        append!(bytes, encode_leb128_unsigned(array_type_idx))

        # Set non-zero elements
        for (i, v) in enumerate(values)
            v == 0 && continue
            # array.set: [arrayref, index, value] -> []
            # But we need the array ref... this is tricky in init expressions.
            # Actually, init expressions are limited — we can only use array.new_fixed
            # or array.new. For >128 elements, use array.new_fixed in chunks or accept the limit.
            # For now, just use array.new_fixed (dispatch tables should be < 128 entries).
            break
        end
    end

    return bytes
end

# ==================== Dispatch Call Emission ====================

"""
Emit hash-based dispatch call at a call site.
Emits: typeId extraction → FNV-1a hash → linear probe → call_indirect.

Arguments:
- bytes: output bytecode vector
- dt: the dispatch table for this function
- arg_locals: Wasm local indices holding the arguments (as anyref)
- base_struct_idx: type index of \$JlBase struct (for typeId extraction)
- extra_locals_start: index where we can allocate temporary locals

Returns: number of extra locals needed (for type_id, hash, slot, key, func_idx)
"""
function emit_dispatch_call!(bytes::Vector{UInt8},
                              dt::DispatchTable,
                              arg_locals::Vector{UInt32},
                              base_struct_idx::UInt32,
                              extra_locals::Vector{UInt32})
    # We need locals for: typeId per arg, hash, slot, key, func_idx
    # extra_locals should have at least (arity + 4) i32 locals
    arity = Int(dt.arity)
    @assert length(extra_locals) >= arity + 4 "Need $(arity + 4) dispatch locals, got $(length(extra_locals))"

    type_id_locals = extra_locals[1:arity]
    hash_local = extra_locals[arity + 1]
    slot_local = extra_locals[arity + 2]
    key_local = extra_locals[arity + 3]
    func_idx_local = extra_locals[arity + 4]

    # --- Step 1: Extract typeIds from arguments ---
    for (j, arg_local) in enumerate(arg_locals)
        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(arg_local))
        # emit_typeof!: ref.cast to $JlBase, struct.get field 0
        emit_typeof!(bytes, base_struct_idx)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(type_id_locals[j]))
    end

    # --- Step 2: FNV-1a hash ---
    # hash = FNV_OFFSET_BASIS
    push!(bytes, Opcode.I32_CONST)
    append!(bytes, encode_leb128_signed(reinterpret(Int32, FNV_OFFSET_BASIS)))

    for j in 1:arity
        # hash = (hash ^ typeId_j) * FNV_PRIME
        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(type_id_locals[j]))
        push!(bytes, Opcode.I32_XOR)
        push!(bytes, Opcode.I32_CONST)
        append!(bytes, encode_leb128_signed(reinterpret(Int32, FNV_PRIME)))
        push!(bytes, Opcode.I32_MUL)
    end
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(hash_local))

    # --- Step 3: slot = hash & mask ---
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(hash_local))
    push!(bytes, Opcode.I32_CONST)
    append!(bytes, encode_leb128_signed(dt.mask))
    push!(bytes, Opcode.I32_AND)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(slot_local))

    # --- Step 4: Linear probe loop ---
    # block $found
    #   block $not_found
    #     loop $probe
    #       ... probe logic ...
    #     end
    #   end ;; $not_found
    #   unreachable
    # end ;; $found
    # ... call_indirect with func_idx_local ...

    # Determine result type for the block
    result_block_type = dt.result_wasm_type

    # block $done (result <return_type>)
    push!(bytes, Opcode.BLOCK)
    if result_block_type == I32
        push!(bytes, 0x7F)  # i32
    elseif result_block_type == I64
        push!(bytes, 0x7E)  # i64
    elseif result_block_type == F32
        push!(bytes, 0x7D)  # f32
    elseif result_block_type == F64
        push!(bytes, 0x7C)  # f64
    else
        push!(bytes, 0x40)  # void
    end

    # block $not_found (void)
    push!(bytes, Opcode.BLOCK)
    push!(bytes, 0x40)  # void

    # loop $probe (void)
    push!(bytes, Opcode.LOOP)
    push!(bytes, 0x40)  # void

    # Load key at slot: global.get $keys_array, local.get $slot, array.get
    push!(bytes, Opcode.GLOBAL_GET)
    append!(bytes, encode_leb128_unsigned(dt.keys_global_idx))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET)
    append!(bytes, encode_leb128_unsigned(dt.i32_array_type_idx))
    push!(bytes, Opcode.LOCAL_TEE)
    append!(bytes, encode_leb128_unsigned(key_local))

    # Empty slot check: key == 0 → br $not_found (label 1)
    push!(bytes, Opcode.I32_EQZ)
    push!(bytes, Opcode.BR_IF)
    append!(bytes, encode_leb128_unsigned(UInt32(1)))  # br to $not_found

    # Check key matches hash
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(key_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(hash_local))
    push!(bytes, Opcode.I32_EQ)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)  # void

    # Verify typeIds match (for collision resolution)
    # For each argument, check type_ids_flat[slot * arity + j] == typeId_j
    type_ids_match = true
    for j in 1:arity
        # global.get $typeids_array
        push!(bytes, Opcode.GLOBAL_GET)
        append!(bytes, encode_leb128_unsigned(dt.typeids_global_idx))
        # index = slot * arity + j - 1
        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(slot_local))
        if arity > 1
            push!(bytes, Opcode.I32_CONST)
            append!(bytes, encode_leb128_signed(dt.arity))
            push!(bytes, Opcode.I32_MUL)
            push!(bytes, Opcode.I32_CONST)
            append!(bytes, encode_leb128_signed(Int32(j - 1)))
            push!(bytes, Opcode.I32_ADD)
        end
        # array.get
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_GET)
        append!(bytes, encode_leb128_unsigned(dt.i32_array_type_idx))
        # Compare with extracted typeId
        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(type_id_locals[j]))
        push!(bytes, Opcode.I32_EQ)

        # For multi-arg: AND all comparisons
        if j > 1
            push!(bytes, Opcode.I32_AND)
        end
    end

    # If all typeIds match: load func_idx, push args, call_indirect, br $done
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)  # void

    # Load funcref table index from values array
    push!(bytes, Opcode.GLOBAL_GET)
    append!(bytes, encode_leb128_unsigned(dt.values_global_idx))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET)
    append!(bytes, encode_leb128_unsigned(dt.i32_array_type_idx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(func_idx_local))

    # Push arguments for call_indirect (anyref params)
    for arg_local in arg_locals
        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(arg_local))
    end

    # Push funcref table element index
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(func_idx_local))

    # call_indirect type_idx table_idx
    push!(bytes, Opcode.CALL_INDIRECT)
    append!(bytes, encode_leb128_unsigned(dt.dispatch_sig_idx))
    append!(bytes, encode_leb128_unsigned(dt.func_table_idx))

    # br $done (label 4: past typeIds-if, hash-if, loop, not_found, to done block)
    push!(bytes, Opcode.BR)
    append!(bytes, encode_leb128_unsigned(UInt32(4)))

    push!(bytes, Opcode.END)  # end typeIds match if
    push!(bytes, Opcode.END)  # end hash match if

    # Next slot: (slot + 1) & mask
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(slot_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.I32_CONST)
    append!(bytes, encode_leb128_signed(dt.mask))
    push!(bytes, Opcode.I32_AND)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(slot_local))

    # br $probe (label 0: loop)
    push!(bytes, Opcode.BR)
    append!(bytes, encode_leb128_unsigned(UInt32(0)))

    push!(bytes, Opcode.END)  # end loop $probe

    push!(bytes, Opcode.END)  # end block $not_found
    # Dispatch failed — unreachable
    push!(bytes, Opcode.UNREACHABLE)

    push!(bytes, Opcode.END)  # end block $done
end

"""
Generate a complete function body for a dispatch caller.
Used when a function's IR is just a dynamic call to a dispatch-table function.
Returns (body_bytes, locals) that can be used directly as the function body.
"""
function generate_dispatch_caller_body(dt::DispatchTable,
                                        n_params::Int,
                                        base_struct_idx::UInt32,
                                        type_registry)
    body = UInt8[]
    locals = WasmValType[]
    arity = Int(dt.arity)

    # Allocate anyref locals for storing arguments
    arg_locals = UInt32[]
    for j in 1:arity
        local_idx = UInt32(n_params + length(locals))
        push!(locals, AnyRef)
        push!(arg_locals, local_idx)
    end

    # Store params as anyref in arg_locals
    for (j, arg_local) in enumerate(arg_locals)
        push!(body, Opcode.LOCAL_GET)
        append!(body, encode_leb128_unsigned(UInt32(j - 1)))  # param j-1
        push!(body, Opcode.LOCAL_SET)
        append!(body, encode_leb128_unsigned(arg_local))
    end

    # Allocate i32 locals for dispatch (typeIds + hash/slot/key/func_idx)
    dispatch_locals = UInt32[]
    for _ in 1:(arity + 4)
        local_idx = UInt32(n_params + length(locals))
        push!(locals, I32)
        push!(dispatch_locals, local_idx)
    end

    # Emit the dispatch probe + call_indirect (leaves result on stack)
    emit_dispatch_call!(body, dt, arg_locals, base_struct_idx, dispatch_locals)

    # Return the dispatch result and end function
    push!(body, Opcode.RETURN)
    push!(body, Opcode.END)

    return (body, locals)
end

"""
Check if a CodeInfo body is a simple dispatch caller (calls a function with a dispatch table).
Returns the dispatch table if found, nothing otherwise.
"""
function find_dispatch_call(code_info::Core.CodeInfo,
                             dt_registry::DispatchTableRegistry)
    for stmt in code_info.code
        if stmt isa Expr && stmt.head === :call
            callee = stmt.args[1]
            if callee isa GlobalRef
                callee_func = try
                    getfield(callee.mod, callee.name)
                catch
                    nothing
                end
                if callee_func !== nothing
                    dt = get_dispatch_table(dt_registry, callee_func)
                    dt !== nothing && return dt
                end
            end
        end
    end
    return nothing
end
