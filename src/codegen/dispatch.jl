# ============================================================================
# parity(M8): THE DISPATCH TABLE registry — dart dispatch_table.dart
# ============================================================================
#
# Megamorphic dispatch (≥9 specializations of one generic function) routes through
# the ONE flat selector table: receiver.classId + selector.offset → call_indirect
# (see selector_table.jl). The FNV-1a hash apparatus that predated it (per-function
# hash tables, probe loops, i32-array globals) was DELETED in M8.4.

"""
One entry in a dispatch table (compile-time): the typeId tuple of a registered
specialization and its target/wrapper function indices. (`hash` is a dead field
kept through M8.4 for ctor stability; removed with the M11 registry cleanup.)
"""
struct DispatchEntry
    type_ids::Vector{Int32}   # DFS type IDs per argument
    hash::UInt32              # DEAD (M8.4) — always 0
    target_idx::UInt32        # Wasm func index of actual specialization
    wrapper_idx::UInt32       # Wasm func index of anyref wrapper (filled later)
    return_type::Type         # Julia return type of this specialization
end

"""
A generic function's dispatchable specialization set (the selector's target map).
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

            h = UInt32(0)   # parity(M8.4): hashing DELETED — the selector table keys on classId
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
    # parity(M8.4): the FNV hash-table apparatus (i32-array globals, per-table funcref
    # tables) is DELETED — the selector table is the only dispatch structure. All this
    # phase does now is create each selector's uniform call_indirect signature.
    for (func_ref, dt) in dt_registry.tables
        param_types = fill(AnyRef, Int(dt.arity))
        result_types = dt.result_wasm_type in (I32, I64, F32, F64, AnyRef) ?
            WasmValType[dt.result_wasm_type] : WasmValType[]
        dt.dispatch_sig_idx = add_type!(mod, FuncType(param_types, result_types))
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
                    struct_new!(b, box_idx)   # mod-resolved fields (march3)
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

    end

    # parity(M8.2): fill the ONE selector table (positions were packed at metadata
    # time; wrapper indices only now exist). Contiguous runs → one segment each.
    fill_selector_table_elements!(mod, dt_registry)
end


"""
Check if a CodeInfo body calls a function with a (selector-routed) dispatch table.
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
