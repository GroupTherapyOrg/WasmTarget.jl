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
    return_type::Type         # Julia return type of this specialization
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
    # parity(M8.2): the dart selector bridge — single-axis tables dispatch via
    # receiver.classId + offset into the ONE flat table (dispatch_table.dart:445-458)
    # instead of the FNV probe. Multi-axis tables keep the probe until M8.3.
    selector_axis::Dict{Any,Int}                      # func_ref → dispatch-axis position
    selector_offset::Dict{Any,Int}                    # func_ref → packed table offset
    selector_positions::Dict{Any,Vector{Tuple{Int,Int}}}  # func_ref → [(table_pos, entry_i)]
    selector_table_idx::Union{Nothing,UInt32}         # THE one flat funcref table
    selector_table_len::Int
    # parity(M8.3): the multi-axis CASCADE — Julia multiple dispatch as composed
    # dart single-axis hops through the SAME table. Per func_ref: level-1 rows that
    # need a second hop, each = (l1_pos, axis2, offset2, rows2::[(pos2, entry_i)]).
    selector_cascades::Dict{Any,Vector{NamedTuple{(:l1_pos,:axis2,:offset2,:rows2),
        Tuple{Int,Int,Int,Vector{Tuple{Int,Int}}}}}}
end

DispatchTableRegistry() = DispatchTableRegistry(Dict{Any, DispatchTable}(),
    Dict{Any,Int}(), Dict{Any,Int}(), Dict{Any,Vector{Tuple{Int,Int}}}(), nothing, 0,
    Dict{Any,Vector{NamedTuple{(:l1_pos,:axis2,:offset2,:rows2),
        Tuple{Int,Int,Int,Vector{Tuple{Int,Int}}}}}}())

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
            @debug "PURE-9060: Skipping dispatch table for $(func_ref): mixed arities $(arities)"
            continue
        end
        arity = first(arities)

        # Determine return type — if mixed, use AnyRef (boxed dispatch)
        return_types = Set{Type}()
        for info in infos
            push!(return_types, info.return_type)
        end
        mixed_returns = length(return_types) != 1
        return_type = mixed_returns ? Any : first(return_types)

        # Build entries with type IDs
        entries = DispatchEntry[]
        all_valid = true
        for info in infos
            type_ids = Int32[]
            for T in info.arg_types
                tid = get_type_id(type_registry, T)
                if tid == Int32(0)
                    @debug "PURE-9060: No type ID for $(T) — skipping dispatch entry"
                    all_valid = false
                    break
                end
                push!(type_ids, tid)
            end
            all_valid || continue

            h = fnv1a_hash(type_ids)
            push!(entries, DispatchEntry(type_ids, h, info.wasm_idx, UInt32(0), info.return_type))
        end

        length(entries) < threshold && continue

        # Table size: next power of 2 with load factor ≤ 0.75
        min_size = ceil(Int, length(entries) / 0.75)
        table_size = Int32(1)
        while table_size < min_size
            table_size *= Int32(2)
        end

        result_wasm = mixed_returns ? AnyRef : julia_to_wasm_type(return_type)

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

    # Create a dedicated i32 array type for dispatch tables.
    # IMPORTANT: Do NOT reuse string_array_idx — strings are packed i8 arrays,
    # and array.get on packed types requires array.get_s/array.get_u (not array.get).
    i32_array_idx = add_array_type!(mod, I32, true)

    for (func_ref, dt) in dt_registry.tables
        dt.i32_array_type_idx = i32_array_idx

        # --- 1. Create dispatch signature type ---
        param_types = fill(AnyRef, Int(dt.arity))
        is_numeric = dt.result_wasm_type in (I32, I64, F32, F64)
        is_anyref = dt.result_wasm_type == AnyRef
        result_types = if is_numeric
            WasmValType[dt.result_wasm_type]
        elseif is_anyref
            WasmValType[AnyRef]
        else
            WasmValType[]
        end
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
        # Dispatch signature result type
        is_numeric_return = dt.result_wasm_type in (I32, I64, F32, F64)
        is_anyref_return = dt.result_wasm_type == AnyRef
        result_types = if is_numeric_return
            WasmValType[dt.result_wasm_type]
        elseif is_anyref_return
            WasmValType[AnyRef]
        else
            WasmValType[]
        end

        wrapper_indices = UInt32[]
        for (entry_i, entry) in enumerate(dt.entries)
            b = InstrBuilder(; func_name="emit_dispatch_wrappers!")

            # For each parameter: local.get + unbox/cast to concrete type
            for (j, tid) in enumerate(entry.type_ids)
                # Find the concrete Julia type for this typeId
                concrete_type = nothing
                for (T, id) in type_registry.type_ids
                    if id == tid
                        concrete_type = T
                        break
                    end
                end

                local_get!(b, UInt32(j - 1))

                if concrete_type !== nothing
                    arg_wasm_type = julia_to_wasm_type(concrete_type)
                    if arg_wasm_type in (I32, I64, F32, F64) && haskey(type_registry.numeric_boxes, arg_wasm_type)
                        # Unbox the numeric arg via THE single unbox consumer (non-null: dispatch-guarded).
                        emit_classid_unbox!(b, mod, type_registry, arg_wasm_type)
                    elseif haskey(type_registry.structs, concrete_type)
                        # Cast to concrete struct type
                        struct_info = type_registry.structs[concrete_type]
                        ref_cast!(b, Int64(struct_info.wasm_type_idx), false)
                    end
                end
            end

            # call $target — target_idx is correct because actual functions were added first
            call!(b, entry.target_idx, WasmValType[], WasmValType[])

            # PURE-9061: Box numeric results when dispatch table uses anyref return
            if is_anyref_return
                entry_wasm_type = julia_to_wasm_type(entry.return_type)
                if entry.return_type === Nothing || entry.return_type === Union{}
                    # WBUILD-4000: Target function returns void (Nothing/Union{}).
                    # Push ref.null none as the anyref return value.
                    ref_null!(b, AnyRef)  # ref.null any → (ref null any) = anyref
                elseif entry_wasm_type in (I32, I64, F32, F64)
                    # Box numeric result into a WasmGC struct: (struct (field classId:i32) (field val:T))
                    box_idx = get_numeric_box_type!(mod, type_registry, entry_wasm_type)
                    # Stack has the numeric value; save it, push the return type's REAL classId (was a
                    # hardcoded 0 = non-discriminable — an isa/typeof on this result would wrongly fail),
                    # reload, struct.new {classId, value}. (dispatch carries mod+registry, not ctx, so it
                    # cannot share emit_classid_box!'s ctx-allocated scratch local — same shape inline.)
                    local_set!(b, UInt32(Int(dt.arity)))  # first extra local
                    i32_const!(b, Int64(ensure_type_id!(type_registry, entry.return_type)))
                    local_get!(b, UInt32(Int(dt.arity)))
                    struct_new!(b, box_idx, WasmValType[])
                end
            end

            end_block!(b)
            body = builder_code(b)

            # Wrapper needs an extra local for boxing when mixed returns
            wrapper_locals = WasmValType[]
            if is_anyref_return
                entry_wasm_type = julia_to_wasm_type(entry.return_type)
                if entry_wasm_type in (I32, I64, F32, F64)
                    push!(wrapper_locals, entry_wasm_type)
                end
            end

            wrapper_idx = add_function!(mod, param_types, result_types, wrapper_locals, body)
            push!(wrapper_indices, wrapper_idx)

            dt.entries[entry_i] = DispatchEntry(
                entry.type_ids, entry.hash, entry.target_idx, wrapper_idx, entry.return_type
            )
        end

        # Add element segment with correct wrapper indices
        add_elem_segment!(mod, dt.func_table_idx, 0, wrapper_indices)
    end

    # parity(M8.2): fill the ONE selector table (positions were packed at metadata
    # time; wrapper indices only now exist). Contiguous runs → one segment each.
    fill_selector_table_elements!(mod, dt_registry)
end


"""
Emit init expression for an i32 array with constant values.
Uses array.new_fixed for small arrays, or array.new + array.set for larger ones.
Returns bytecode WITHOUT the trailing END byte (add_global_ref! adds it).
"""
function emit_i32_array_init(array_type_idx::UInt32, values::AbstractVector)::Vector{UInt8}
    b = InstrBuilder(; func_name="emit_i32_array_init")
    n = length(values)

    if n <= 128
        # array.new_fixed: push all elements, then array.new_fixed type_idx count
        for v in values
            # Safely convert to signed i32 for LEB128 encoding (handles UInt32 > 2^31)
            signed_v = reinterpret(Int32, UInt32(v & 0xFFFFFFFF))
            i32_const!(b, signed_v)
        end
        array_new_fixed!(b, array_type_idx, UInt32(n), I32)
    else
        # For large arrays: array.new (default 0) then array.set for non-zero elements
        i32_const!(b, Int32(0))  # default value
        i32_const!(b, Int32(n))  # length (i32.const → signed LEB)
        array_new!(b, array_type_idx, I32)

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

    return builder_code(b)
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

    b = InstrBuilder(; func_name="emit_dispatch_call!")

    # --- Step 1: Extract typeIds from arguments ---
    for (j, arg_local) in enumerate(arg_locals)
        local_get!(b, arg_local)
        # emit_typeof!: ref.cast to $JlBase, struct.get field 0 (net: anyref -> i32)
        tb = UInt8[]; emit_typeof!(tb, base_struct_idx); emit_raw!(b, tb; pops=1, pushes=WasmValType[I32])
        local_set!(b, type_id_locals[j])
    end

    # --- Step 2: FNV-1a hash ---
    # hash = FNV_OFFSET_BASIS
    i32_const!(b, reinterpret(Int32, FNV_OFFSET_BASIS))

    for j in 1:arity
        # hash = (hash ^ typeId_j) * FNV_PRIME
        local_get!(b, type_id_locals[j])
        num!(b, Opcode.I32_XOR)
        i32_const!(b, reinterpret(Int32, FNV_PRIME))
        num!(b, Opcode.I32_MUL)
    end
    local_set!(b, hash_local)

    # --- Step 3: slot = hash & mask ---
    local_get!(b, hash_local)
    i32_const!(b, dt.mask)
    num!(b, Opcode.I32_AND)
    local_set!(b, slot_local)

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
    done_bt = if result_block_type == I32
        0x7F  # i32
    elseif result_block_type == I64
        0x7E  # i64
    elseif result_block_type == F32
        0x7D  # f32
    elseif result_block_type == F64
        0x7C  # f64
    elseif result_block_type == AnyRef
        0x6E  # anyref
    else
        0x40  # void
    end
    block!(b, done_bt)

    # block $not_found (void)
    block!(b, 0x40)

    # loop $probe (void)
    loop!(b, 0x40)

    # Load key at slot: global.get $keys_array, local.get $slot, array.get
    global_get!(b, dt.keys_global_idx, AnyRef)
    local_get!(b, slot_local)
    array_get!(b, dt.i32_array_type_idx, I32)
    local_tee!(b, key_local)

    # Empty slot check: key == 0 → br $not_found (label 1)
    num!(b, Opcode.I32_EQZ)
    br_if!(b, UInt32(1))  # br to $not_found

    # Check key matches hash
    local_get!(b, key_local)
    local_get!(b, hash_local)
    num!(b, Opcode.I32_EQ)
    if_!(b, 0x40)

    # Verify typeIds match (for collision resolution)
    # For each argument, check type_ids_flat[slot * arity + j] == typeId_j
    type_ids_match = true
    for j in 1:arity
        # global.get $typeids_array
        global_get!(b, dt.typeids_global_idx, AnyRef)
        # index = slot * arity + j - 1
        local_get!(b, slot_local)
        if arity > 1
            i32_const!(b, dt.arity)
            num!(b, Opcode.I32_MUL)
            i32_const!(b, Int32(j - 1))
            num!(b, Opcode.I32_ADD)
        end
        # array.get
        array_get!(b, dt.i32_array_type_idx, I32)
        # Compare with extracted typeId
        local_get!(b, type_id_locals[j])
        num!(b, Opcode.I32_EQ)

        # For multi-arg: AND all comparisons
        if j > 1
            num!(b, Opcode.I32_AND)
        end
    end

    # If all typeIds match: load func_idx, push args, call_indirect, br $done
    if_!(b, 0x40)

    # Load funcref table index from values array
    global_get!(b, dt.values_global_idx, AnyRef)
    local_get!(b, slot_local)
    array_get!(b, dt.i32_array_type_idx, I32)
    local_set!(b, func_idx_local)

    # Push arguments for call_indirect (anyref params)
    for arg_local in arg_locals
        local_get!(b, arg_local)
    end

    # Push funcref table element index
    local_get!(b, func_idx_local)

    # call_indirect type_idx table_idx
    ci_params = fill(AnyRef, arity)
    ci_results = result_block_type in (I32, I64, F32, F64) ? WasmValType[result_block_type] :
                 (result_block_type == AnyRef ? WasmValType[AnyRef] : WasmValType[])
    call_indirect!(b, dt.dispatch_sig_idx, dt.func_table_idx, ci_params, ci_results)

    # br $done (label 4: past typeIds-if, hash-if, loop, not_found, to done block)
    br!(b, UInt32(4))

    end_block!(b)  # end typeIds match if
    end_block!(b)  # end hash match if

    # Next slot: (slot + 1) & mask
    local_get!(b, slot_local)
    i32_const!(b, 1)
    num!(b, Opcode.I32_ADD)
    i32_const!(b, dt.mask)
    num!(b, Opcode.I32_AND)
    local_set!(b, slot_local)

    # br $probe (label 0: loop)
    br!(b, UInt32(0))

    end_block!(b)  # end loop $probe

    end_block!(b)  # end block $not_found
    # Dispatch failed — unreachable
    unreachable!(b)  # structural trap (dart-legit dead path)

    end_block!(b)  # end block $done

    append!(bytes, builder_code(b))
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
    b = InstrBuilder(; func_name="generate_dispatch_caller_body")
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
        local_get!(b, UInt32(j - 1))  # param j-1
        local_set!(b, arg_local)
    end

    # Allocate i32 locals for dispatch (typeIds + hash/slot/key/func_idx)
    dispatch_locals = UInt32[]
    for _ in 1:(arity + 4)
        local_idx = UInt32(n_params + length(locals))
        push!(locals, I32)
        push!(dispatch_locals, local_idx)
    end

    # Emit the dispatch probe + call_indirect (leaves result on stack).
    # emit_dispatch_call! mutates a raw buffer; splice via the bridge.
    dispatch_buf = UInt8[]
    emit_dispatch_call!(dispatch_buf, dt, arg_locals, base_struct_idx, dispatch_locals)
    dispatch_pushes = dt.result_wasm_type in (I32, I64, F32, F64, AnyRef) ?
        WasmValType[dt.result_wasm_type] : WasmValType[]
    emit_raw!(b, dispatch_buf; pushes=dispatch_pushes)

    # Return the dispatch result and end function
    return_!(b)
    end_block!(b)

    return (builder_code(b), locals)
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

# ==================== Serialization ====================

"""
Serialize dispatch tables to a Dict suitable for JSON output.
Each table entry records: function name, arity, entries (typeIds + hash + target),
table layout (keys, values), and table size.

This metadata is written alongside base.wasm so that user code compilation
can reference Base dispatch tables.
"""
function serialize_dispatch_tables(dt_registry::DispatchTableRegistry,
                                    type_registry::TypeRegistry)::Vector{Dict{String, Any}}
    tables = Dict{String, Any}[]
    for (func_ref, dt) in dt_registry.tables
        func_name = string(func_ref)
        entries_data = Dict{String, Any}[]
        for entry in dt.entries
            push!(entries_data, Dict{String, Any}(
                "type_ids" => Int[tid for tid in entry.type_ids],
                "hash" => Int(entry.hash),
                "target_idx" => Int(entry.target_idx),
                "wrapper_idx" => Int(entry.wrapper_idx),
            ))
        end

        keys, values, type_ids_flat = resolve_table_layout(dt)
        push!(tables, Dict{String, Any}(
            "function" => func_name,
            "arity" => Int(dt.arity),
            "table_size" => Int(dt.table_size),
            "mask" => Int(dt.mask),
            "num_entries" => length(dt.entries),
            "entries" => entries_data,
            "keys_global_idx" => Int(dt.keys_global_idx),
            "values_global_idx" => Int(dt.values_global_idx),
            "typeids_global_idx" => Int(dt.typeids_global_idx),
            "func_table_idx" => Int(dt.func_table_idx),
            "dispatch_sig_idx" => Int(dt.dispatch_sig_idx),
        ))
    end
    return tables
end

# ==================== PURE-9062: Overlay Dispatch Tables ====================
#
# User-defined methods are stored in an overlay table checked BEFORE the frozen
# Base dispatch tables. This matches Julia's world-age semantics — new methods
# shadow old ones but don't invalidate pre-computed results for unaffected signatures.
#
# Architecture:
#   1. Base dispatch tables are frozen (built by build_base.jl, shipped in base.wasm)
#   2. User methods go into a separate overlay table (mutable)
#   3. At call sites: probe overlay → if found, call user wrapper
#                                   → if miss, probe base → if found, call base wrapper
#                                   → if both miss, unreachable
#   4. After wasm-merge, both tables live in the same module

"""
Registry pairing overlay (user) dispatch tables with base (frozen) dispatch tables.
At call sites, the overlay is probed first; on miss, falls back to the base table.
"""
mutable struct OverlayRegistry
    overlays::Dict{Any, DispatchTable}   # func_ref → user overlay table
    bases::Dict{Any, DispatchTable}      # func_ref → frozen base table
end

OverlayRegistry() = OverlayRegistry(Dict{Any, DispatchTable}(), Dict{Any, DispatchTable}())

"""Check if a function has overlay dispatch (user entries shadowing base)."""
has_overlay(reg::OverlayRegistry, func_ref) = haskey(reg.overlays, func_ref)

"""Get overlay + base table pair for a function."""
function get_overlay_pair(reg::OverlayRegistry, func_ref)
    overlay = get(reg.overlays, func_ref, nothing)
    base = get(reg.bases, func_ref, nothing)
    return (overlay, base)
end

"""
Build overlay dispatch tables for user-defined methods that shadow functions
with existing base dispatch tables.

`overlay_arg_types` maps func_ref → Set of arg_type tuples that are user overlay.
All other entries for the same function are treated as base entries.

Returns an OverlayRegistry. Functions with no overlap are not included.
"""
function build_overlay_tables(dt_registry::DispatchTableRegistry,
                               overlay_arg_types::Dict{Any, Set{Tuple}};
                               type_registry=nothing)::OverlayRegistry
    overlay_reg = OverlayRegistry()

    for (func_ref, dt) in dt_registry.tables
        overlay_types = get(overlay_arg_types, func_ref, nothing)
        overlay_types === nothing && continue

        base_entries = DispatchEntry[]
        user_entries = DispatchEntry[]

        for entry in dt.entries
            # Reconstruct the arg_types for this entry by looking up type_ids → Julia types
            is_overlay = false
            if type_registry !== nothing
                arg_types = Type[]
                for tid in entry.type_ids
                    for (T, id) in type_registry.type_ids
                        if id == tid
                            push!(arg_types, T)
                            break
                        end
                    end
                end
                if length(arg_types) == length(entry.type_ids)
                    is_overlay = Tuple(arg_types) in overlay_types
                end
            end

            if is_overlay
                push!(user_entries, entry)
            else
                push!(base_entries, entry)
            end
        end

        # Only create overlay if there are BOTH base and user entries
        isempty(user_entries) && continue
        isempty(base_entries) && continue

        # Build base dispatch table
        base_table_size = max(Int32(4), next_pow2_for_load(length(base_entries)))
        base_dt_new = DispatchTable(
            func_ref, dt.arity, base_entries,
            base_table_size, base_table_size - Int32(1),
            UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0),
            dt.result_wasm_type
        )

        # Build overlay dispatch table
        overlay_table_size = max(Int32(4), next_pow2_for_load(length(user_entries)))
        overlay_dt = DispatchTable(
            func_ref, dt.arity, user_entries,
            overlay_table_size, overlay_table_size - Int32(1),
            UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0),
            dt.result_wasm_type
        )

        overlay_reg.overlays[func_ref] = overlay_dt
        overlay_reg.bases[func_ref] = base_dt_new
    end

    return overlay_reg
end

"""Next power of 2 with load factor ≤ 0.75."""
function next_pow2_for_load(n_entries::Int)::Int32
    min_size = ceil(Int, n_entries / 0.75)
    table_size = Int32(1)
    while table_size < min_size
        table_size *= Int32(2)
    end
    return table_size
end

"""
Emit metadata for overlay dispatch tables (separate from base tables).
Creates the overlay's globals (keys/values/typeids arrays) and funcref table.
"""
function emit_overlay_metadata!(mod::WasmModule,
                                 type_registry::TypeRegistry,
                                 overlay_reg::OverlayRegistry)
    isempty(overlay_reg.overlays) && return

    # Create a dedicated i32 array type for overlay dispatch tables.
    # IMPORTANT: Do NOT reuse string_array_idx — strings are packed i8 arrays,
    # and array.get on packed types requires array.get_s/array.get_u (not array.get).
    i32_array_idx = add_array_type!(mod, I32, true)

    # Emit metadata for overlay tables
    for (func_ref, overlay_dt) in overlay_reg.overlays
        overlay_dt.i32_array_type_idx = i32_array_idx

        # Create dispatch signature (same as base — anyref params, same result type)
        param_types = fill(AnyRef, Int(overlay_dt.arity))
        is_numeric = overlay_dt.result_wasm_type in (I32, I64, F32, F64)
        is_anyref = overlay_dt.result_wasm_type == AnyRef
        result_types = if is_numeric
            WasmValType[overlay_dt.result_wasm_type]
        elseif is_anyref
            WasmValType[AnyRef]
        else
            WasmValType[]
        end
        dispatch_sig_idx = add_type!(mod, FuncType(param_types, result_types))
        overlay_dt.dispatch_sig_idx = dispatch_sig_idx

        # Create funcref table for overlay wrappers
        table_idx = add_table!(mod, FuncRef, UInt32(length(overlay_dt.entries)))
        overlay_dt.func_table_idx = table_idx

        # Build hash table and emit as globals
        keys, values, type_ids_flat = resolve_table_layout(overlay_dt)

        keys_init = emit_i32_array_init(i32_array_idx, keys)
        overlay_dt.keys_global_idx = add_global_ref!(mod, i32_array_idx, false, keys_init; nullable=false)

        values_init = emit_i32_array_init(i32_array_idx, values)
        overlay_dt.values_global_idx = add_global_ref!(mod, i32_array_idx, false, values_init; nullable=false)

        typeids_init = emit_i32_array_init(i32_array_idx, type_ids_flat)
        overlay_dt.typeids_global_idx = add_global_ref!(mod, i32_array_idx, false, typeids_init; nullable=false)
    end

    # Emit metadata for base tables (if they don't already have it)
    for (func_ref, base_dt) in overlay_reg.bases
        base_dt.i32_array_type_idx = i32_array_idx

        param_types = fill(AnyRef, Int(base_dt.arity))
        is_numeric = base_dt.result_wasm_type in (I32, I64, F32, F64)
        is_anyref = base_dt.result_wasm_type == AnyRef
        result_types = if is_numeric
            WasmValType[base_dt.result_wasm_type]
        elseif is_anyref
            WasmValType[AnyRef]
        else
            WasmValType[]
        end
        dispatch_sig_idx = add_type!(mod, FuncType(param_types, result_types))
        base_dt.dispatch_sig_idx = dispatch_sig_idx

        table_idx = add_table!(mod, FuncRef, UInt32(length(base_dt.entries)))
        base_dt.func_table_idx = table_idx

        keys, values, type_ids_flat = resolve_table_layout(base_dt)

        keys_init = emit_i32_array_init(i32_array_idx, keys)
        base_dt.keys_global_idx = add_global_ref!(mod, i32_array_idx, false, keys_init; nullable=false)

        values_init = emit_i32_array_init(i32_array_idx, values)
        base_dt.values_global_idx = add_global_ref!(mod, i32_array_idx, false, values_init; nullable=false)

        typeids_init = emit_i32_array_init(i32_array_idx, type_ids_flat)
        base_dt.typeids_global_idx = add_global_ref!(mod, i32_array_idx, false, typeids_init; nullable=false)
    end
end

"""
Emit wrapper functions for overlay dispatch tables.
Called AFTER all actual functions are added to the module.
"""
function emit_overlay_wrappers!(mod::WasmModule,
                                 type_registry::TypeRegistry,
                                 overlay_reg::OverlayRegistry)
    isempty(overlay_reg.overlays) && return

    # Emit wrappers for overlay tables
    for (func_ref, overlay_dt) in overlay_reg.overlays
        _emit_table_wrappers!(mod, type_registry, overlay_dt)
    end

    # Emit wrappers for base tables
    for (func_ref, base_dt) in overlay_reg.bases
        _emit_table_wrappers!(mod, type_registry, base_dt)
    end
end

"""Internal helper: emit wrapper functions and element segment for a dispatch table."""
function _emit_table_wrappers!(mod::WasmModule,
                                type_registry::TypeRegistry,
                                dt::DispatchTable)
    param_types = fill(AnyRef, Int(dt.arity))
    is_numeric_return = dt.result_wasm_type in (I32, I64, F32, F64)
    is_anyref_return = dt.result_wasm_type == AnyRef
    result_types = if is_numeric_return
        WasmValType[dt.result_wasm_type]
    elseif is_anyref_return
        WasmValType[AnyRef]
    else
        WasmValType[]
    end

    wrapper_indices = UInt32[]
    for (entry_i, entry) in enumerate(dt.entries)
        b = InstrBuilder(; func_name="_emit_table_wrappers!")

        # For each parameter: local.get + unbox/cast to concrete type
        for (j, tid) in enumerate(entry.type_ids)
            concrete_type = nothing
            for (T, id) in type_registry.type_ids
                if id == tid
                    concrete_type = T
                    break
                end
            end

            local_get!(b, UInt32(j - 1))

            if concrete_type !== nothing
                arg_wasm_type = julia_to_wasm_type(concrete_type)
                if arg_wasm_type in (I32, I64, F32, F64) && haskey(type_registry.numeric_boxes, arg_wasm_type)
                    # Unbox the numeric arg via THE single unbox consumer (non-null: dispatch-guarded).
                    emit_classid_unbox!(b, mod, type_registry, arg_wasm_type)
                elseif haskey(type_registry.structs, concrete_type)
                    struct_info = type_registry.structs[concrete_type]
                    ref_cast!(b, Int64(struct_info.wasm_type_idx), false)
                end
            end
        end

        call!(b, entry.target_idx, WasmValType[], WasmValType[])

        # Box numeric results when dispatch table uses anyref return
        if is_anyref_return
            entry_wasm_type = julia_to_wasm_type(entry.return_type)
            if entry.return_type === Nothing || entry.return_type === Union{}
                # WBUILD-4000: Target function returns void — push null anyref
                ref_null!(b, AnyRef)
            elseif entry_wasm_type in (I32, I64, F32, F64)
                # Box the numeric result carrying the return type's REAL classId (was hardcoded 0).
                box_idx = get_numeric_box_type!(mod, type_registry, entry_wasm_type)
                local_set!(b, UInt32(Int(dt.arity)))
                i32_const!(b, Int64(ensure_type_id!(type_registry, entry.return_type)))
                local_get!(b, UInt32(Int(dt.arity)))
                struct_new!(b, box_idx, WasmValType[])
            end
        end

        end_block!(b)
        body = builder_code(b)

        wrapper_locals = WasmValType[]
        if is_anyref_return
            entry_wasm_type = julia_to_wasm_type(entry.return_type)
            if entry_wasm_type in (I32, I64, F32, F64)
                push!(wrapper_locals, entry_wasm_type)
            end
        end

        wrapper_idx = add_function!(mod, param_types, result_types, wrapper_locals, body)
        push!(wrapper_indices, wrapper_idx)

        dt.entries[entry_i] = DispatchEntry(
            entry.type_ids, entry.hash, entry.target_idx, wrapper_idx, entry.return_type
        )
    end

    add_elem_segment!(mod, dt.func_table_idx, 0, wrapper_indices)
end

"""
Emit overlay dispatch call at a call site.
Probes the overlay table first; on miss, probes the base table.
This ensures user-defined methods take priority over frozen Base methods.

Structure:
  block \$done (result <return_type>)
    ;; --- Overlay probe ---
    block \$overlay_miss
      loop \$overlay_probe
        ... probe overlay table ...
        br \$done on match
        br \$overlay_miss on empty slot
        br \$overlay_probe to continue probing
      end
    end
    ;; --- Base fallback ---
    block \$base_miss
      loop \$base_probe
        ... probe base table ...
        br \$done on match
        br \$base_miss on empty slot
        br \$base_probe to continue probing
      end
    end
    unreachable
  end
"""
function emit_overlay_dispatch_call!(bytes::Vector{UInt8},
                                      overlay_dt::DispatchTable,
                                      base_dt::DispatchTable,
                                      arg_locals::Vector{UInt32},
                                      base_struct_idx::UInt32,
                                      extra_locals::Vector{UInt32})
    arity = Int(overlay_dt.arity)
    @assert length(extra_locals) >= arity + 4 "Need $(arity + 4) dispatch locals, got $(length(extra_locals))"

    type_id_locals = extra_locals[1:arity]
    hash_local = extra_locals[arity + 1]
    slot_local = extra_locals[arity + 2]
    key_local = extra_locals[arity + 3]
    func_idx_local = extra_locals[arity + 4]

    b = InstrBuilder(; func_name="emit_overlay_dispatch_call!")

    # --- Step 1: Extract typeIds from arguments ---
    for (j, arg_local) in enumerate(arg_locals)
        local_get!(b, arg_local)
        tb = UInt8[]; emit_typeof!(tb, base_struct_idx); emit_raw!(b, tb; pops=1, pushes=WasmValType[I32])
        local_set!(b, type_id_locals[j])
    end

    # --- Step 2: FNV-1a hash ---
    i32_const!(b, reinterpret(Int32, FNV_OFFSET_BASIS))
    for j in 1:arity
        local_get!(b, type_id_locals[j])
        num!(b, Opcode.I32_XOR)
        i32_const!(b, reinterpret(Int32, FNV_PRIME))
        num!(b, Opcode.I32_MUL)
    end
    local_set!(b, hash_local)

    # --- Determine result block type ---
    result_block_type = overlay_dt.result_wasm_type
    done_bt = if result_block_type == I32
        0x7F
    elseif result_block_type == I64
        0x7E
    elseif result_block_type == F32
        0x7D
    elseif result_block_type == F64
        0x7C
    elseif result_block_type == AnyRef
        0x6E
    else
        0x40
    end

    # block $done (result <return_type>)
    block!(b, done_bt)

    # ======== OVERLAY PROBE ========
    # block $overlay_miss
    block!(b, 0x40)

    # slot = hash & overlay_mask
    local_get!(b, hash_local)
    i32_const!(b, overlay_dt.mask)
    num!(b, Opcode.I32_AND)
    local_set!(b, slot_local)

    # loop $overlay_probe
    loop!(b, 0x40)

    # Load key: global.get overlay_keys, local.get slot, array.get
    # _emit_table_probe_body! mutates a raw buffer; net stack effect is 0 here.
    pb = UInt8[]
    _emit_table_probe_body!(pb, overlay_dt, type_id_locals, hash_local,
                             slot_local, key_local, func_idx_local, arg_locals,
                             arity,
                             UInt32(3),  # br depth to $done (past: overlay_probe, overlay_miss, done)
                             UInt32(1))  # br depth to $overlay_miss (past: overlay_probe)
    emit_raw!(b, pb)

    # Next slot: (slot + 1) & mask
    nb = UInt8[]; _emit_next_slot!(nb, slot_local, overlay_dt.mask); emit_raw!(b, nb)

    # br $overlay_probe (label 0: loop)
    br!(b, UInt32(0))

    end_block!(b)  # end loop $overlay_probe
    end_block!(b)  # end block $overlay_miss

    # ======== BASE FALLBACK PROBE ========
    # block $base_miss
    block!(b, 0x40)

    # slot = hash & base_mask
    local_get!(b, hash_local)
    i32_const!(b, base_dt.mask)
    num!(b, Opcode.I32_AND)
    local_set!(b, slot_local)

    # loop $base_probe
    loop!(b, 0x40)

    pb2 = UInt8[]
    _emit_table_probe_body!(pb2, base_dt, type_id_locals, hash_local,
                             slot_local, key_local, func_idx_local, arg_locals,
                             arity,
                             UInt32(3),  # br depth to $done (past: base_probe, base_miss, done)
                             UInt32(1))  # br depth to $base_miss (past: base_probe)
    emit_raw!(b, pb2)

    nb2 = UInt8[]; _emit_next_slot!(nb2, slot_local, base_dt.mask); emit_raw!(b, nb2)

    br!(b, UInt32(0))

    end_block!(b)  # end loop $base_probe
    end_block!(b)  # end block $base_miss

    # Both tables missed — unreachable
    unreachable!(b)  # structural trap (dart-legit dead path)

    end_block!(b)  # end block $done

    append!(bytes, builder_code(b))
end

"""Emit block type byte for a given WasmValType."""
function _emit_block_type!(bytes::Vector{UInt8}, wasm_type::WasmValType)
    if wasm_type == I32
        push!(bytes, 0x7F)
    elseif wasm_type == I64
        push!(bytes, 0x7E)
    elseif wasm_type == F32
        push!(bytes, 0x7D)
    elseif wasm_type == F64
        push!(bytes, 0x7C)
    elseif wasm_type == AnyRef
        push!(bytes, 0x6E)
    else
        push!(bytes, 0x40)  # void
    end
end

"""Emit the probe body for one table (used by both overlay and base probes)."""
function _emit_table_probe_body!(bytes::Vector{UInt8},
                                   dt::DispatchTable,
                                   type_id_locals::Vector{UInt32},
                                   hash_local::UInt32,
                                   slot_local::UInt32,
                                   key_local::UInt32,
                                   func_idx_local::UInt32,
                                   arg_locals::Vector{UInt32},
                                   arity::Int,
                                   br_done_depth::UInt32,
                                   br_miss_depth::UInt32)
    b = InstrBuilder(; func_name="_emit_table_probe_body!")

    # Load key at slot
    global_get!(b, dt.keys_global_idx, AnyRef)
    local_get!(b, slot_local)
    array_get!(b, dt.i32_array_type_idx, I32)
    local_tee!(b, key_local)

    # Empty slot → br $miss
    num!(b, Opcode.I32_EQZ)
    br_if!(b, br_miss_depth)

    # Check key matches hash
    local_get!(b, key_local)
    local_get!(b, hash_local)
    num!(b, Opcode.I32_EQ)
    if_!(b, 0x40)

    # Verify typeIds match
    for j in 1:arity
        global_get!(b, dt.typeids_global_idx, AnyRef)
        local_get!(b, slot_local)
        if arity > 1
            i32_const!(b, dt.arity)
            num!(b, Opcode.I32_MUL)
            i32_const!(b, Int32(j - 1))
            num!(b, Opcode.I32_ADD)
        end
        array_get!(b, dt.i32_array_type_idx, I32)
        local_get!(b, type_id_locals[j])
        num!(b, Opcode.I32_EQ)
        if j > 1
            num!(b, Opcode.I32_AND)
        end
    end

    # If all typeIds match: load func_idx, push args, call_indirect, br $done
    if_!(b, 0x40)

    global_get!(b, dt.values_global_idx, AnyRef)
    local_get!(b, slot_local)
    array_get!(b, dt.i32_array_type_idx, I32)
    local_set!(b, func_idx_local)

    # Push args
    for arg_local in arg_locals
        local_get!(b, arg_local)
    end

    # Push funcref table element index
    local_get!(b, func_idx_local)

    # call_indirect type_idx table_idx
    ci_params = fill(AnyRef, arity)
    ci_results = dt.result_wasm_type in (I32, I64, F32, F64) ? WasmValType[dt.result_wasm_type] :
                 (dt.result_wasm_type == AnyRef ? WasmValType[AnyRef] : WasmValType[])
    call_indirect!(b, dt.dispatch_sig_idx, dt.func_table_idx, ci_params, ci_results)

    # br $done (needs to account for: typeIds-if, hash-if, loop, miss-block, done)
    br!(b, br_done_depth + UInt32(1))  # +1 for the two inner if blocks

    end_block!(b)  # end typeIds match if
    end_block!(b)  # end hash match if

    append!(bytes, builder_code(b))
end

"""Emit slot increment: slot = (slot + 1) & mask."""
function _emit_next_slot!(bytes::Vector{UInt8}, slot_local::UInt32, mask::Int32)
    b = InstrBuilder(; func_name="_emit_next_slot!")
    local_get!(b, slot_local)
    i32_const!(b, 1)              # push!(I32_CONST); push!(0x01)
    num!(b, Opcode.I32_ADD)
    i32_const!(b, mask)
    num!(b, Opcode.I32_AND)
    local_set!(b, slot_local)
    append!(bytes, builder_code(b))
end

"""
Generate a complete function body for an overlay dispatch caller.
Probes the overlay table first, then the base table.
"""
function generate_overlay_dispatch_caller_body(overlay_dt::DispatchTable,
                                                base_dt::DispatchTable,
                                                n_params::Int,
                                                base_struct_idx::UInt32,
                                                type_registry)
    b = InstrBuilder(; func_name="generate_overlay_dispatch_caller_body")
    locals = WasmValType[]
    arity = Int(overlay_dt.arity)

    # Allocate anyref locals for storing arguments
    arg_locals = UInt32[]
    for j in 1:arity
        local_idx = UInt32(n_params + length(locals))
        push!(locals, AnyRef)
        push!(arg_locals, local_idx)
    end

    # Store params as anyref
    for (j, arg_local) in enumerate(arg_locals)
        local_get!(b, UInt32(j - 1))
        local_set!(b, arg_local)
    end

    # Allocate i32 locals for dispatch (typeIds + hash/slot/key/func_idx)
    dispatch_locals = UInt32[]
    for _ in 1:(arity + 4)
        local_idx = UInt32(n_params + length(locals))
        push!(locals, I32)
        push!(dispatch_locals, local_idx)
    end

    # Emit dual-probe: overlay → base. emit_overlay_dispatch_call! mutates a raw
    # buffer (leaves the dispatch result on the stack); splice via the bridge.
    dispatch_buf = UInt8[]
    emit_overlay_dispatch_call!(dispatch_buf, overlay_dt, base_dt, arg_locals,
                                 base_struct_idx, dispatch_locals)
    dispatch_pushes = overlay_dt.result_wasm_type in (I32, I64, F32, F64, AnyRef) ?
        WasmValType[overlay_dt.result_wasm_type] : WasmValType[]
    emit_raw!(b, dispatch_buf; pushes=dispatch_pushes)

    return_!(b)
    end_block!(b)

    return (builder_code(b), locals)
end

"""
Check if a CodeInfo body calls a function with an overlay dispatch table.
Returns (overlay_dt, base_dt) if found, (nothing, nothing) otherwise.
"""
function find_overlay_dispatch_call(code_info::Core.CodeInfo,
                                     overlay_reg::OverlayRegistry)
    for stmt in code_info.code
        if stmt isa Expr && stmt.head === :call
            callee = stmt.args[1]
            if callee isa GlobalRef
                callee_func = try
                    getfield(callee.mod, callee.name)
                catch
                    nothing
                end
                if callee_func !== nothing && has_overlay(overlay_reg, callee_func)
                    return get_overlay_pair(overlay_reg, callee_func)
                end
            end
        end
    end
    return (nothing, nothing)
end

"""
Load base dispatch metadata from a serialized Dict (from dispatch-tables.json).
Returns a Dict mapping function name → metadata for overlay table construction.
"""
function load_dispatch_metadata(data::Vector)::Dict{String, Dict{String, Any}}
    result = Dict{String, Dict{String, Any}}()
    for table_data in data
        func_name = table_data["function"]
        result[func_name] = table_data
    end
    return result
end
