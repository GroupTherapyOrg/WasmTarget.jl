# thin_typeinf.jl — Lightweight browser-side type inference via return-type lookup
#
# Walks CodeInfo.code and annotates each SSA value with a TypeID by looking up
# callee return types in a pre-built hash table. No Dict, no Type objects —
# only Int32 TypeIDs and Vector{Int32}.
#
# For MVP: handles optimized IR from code_typed(f, types; optimize=true).
# Callees are intrinsics (GlobalRef(Base, :mul_int)) or user functions.
#
# Usage:
#   rt_table = build_return_type_table_with_intrinsics(table, registry)
#   ssa_typeids = thin_typeinf(ci.code, arg_typeids, rt_table, registry)

"""
    thin_typeinf(code, arg_typeids, return_type_table, registry) → Vector{Int32}

Walk CodeInfo statements and annotate each SSA value with a TypeID.

# Arguments
- `code::Vector{Any}`: CodeInfo.code statements (Expr, ReturnNode, GotoNode, etc.)
- `arg_typeids::Vector{Int32}`: TypeIDs for each slot. arg_typeids[1] = typeof(f),
  arg_typeids[2] = first user arg, etc. (matches CodeInfo slot numbering)
- `return_type_table::Vector{Int32}`: FNV-1a hash table mapping composite_sig_hash → return_typeid
- `registry::TypeIDRegistry`: For resolving GlobalRef → function value → TypeID

# Returns
- `Vector{Int32}`: TypeID for each SSA value (length = length(code)). -1 for non-value
  statements (GotoNode, GotoIfNot with no value).
"""
function thin_typeinf(
    code::Vector{Any},
    arg_typeids::Vector{Int32},
    return_type_table::Vector{Int32},
    registry::TypeIDRegistry
)::Vector{Int32}
    n = length(code)
    ssa_types = fill(Int32(-1), n)

    for i in 1:n
        stmt = code[i]

        if stmt isa Expr && stmt.head === :call
            # :call — stmt.args[1] = callee, stmt.args[2:end] = arguments
            callee_tid = _resolve_typeid(stmt.args[1], arg_typeids, ssa_types, registry)
            arg_tids = Int32[]
            for j in 2:length(stmt.args)
                push!(arg_tids, _resolve_typeid(stmt.args[j], arg_typeids, ssa_types, registry))
            end
            h = composite_hash(callee_tid, arg_tids)
            ssa_types[i] = lookup_return_type(return_type_table, h)

        elseif stmt isa Expr && stmt.head === :invoke
            # :invoke — stmt.args[1] = MethodInstance (ignored), args[2] = callee, args[3:end] = arguments
            callee_tid = _resolve_typeid(stmt.args[2], arg_typeids, ssa_types, registry)
            arg_tids = Int32[]
            for j in 3:length(stmt.args)
                push!(arg_tids, _resolve_typeid(stmt.args[j], arg_typeids, ssa_types, registry))
            end
            h = composite_hash(callee_tid, arg_tids)
            ssa_types[i] = lookup_return_type(return_type_table, h)

        elseif stmt isa Core.ReturnNode
            if isdefined(stmt, :val)
                ssa_types[i] = _resolve_typeid(stmt.val, arg_typeids, ssa_types, registry)
            end

        elseif stmt isa Core.GotoNode
            ssa_types[i] = Int32(-1)

        elseif stmt isa Core.GotoIfNot
            ssa_types[i] = Int32(-1)

        elseif stmt isa Core.PhiNode
            # Take type from first non-void incoming edge
            for val in stmt.values
                tid = _resolve_typeid(val, arg_typeids, ssa_types, registry)
                if tid != Int32(-1)
                    ssa_types[i] = tid
                    break
                end
            end

        elseif stmt isa GlobalRef
            # GlobalRef as a statement (loads a value into SSA)
            ssa_types[i] = _resolve_globalref_typeid(stmt, registry)

        else
            # Literal constants or other values
            ssa_types[i] = _resolve_typeid(stmt, arg_typeids, ssa_types, registry)
        end
    end

    return ssa_types
end

"""
    _resolve_typeid(val, arg_typeids, ssa_types, registry) → Int32

Resolve a value reference to its TypeID.
"""
function _resolve_typeid(@nospecialize(val), arg_typeids::Vector{Int32},
                         ssa_types::Vector{Int32}, registry::TypeIDRegistry)::Int32
    if val isa Core.SSAValue
        return ssa_types[val.id]
    elseif val isa Core.Argument
        idx = val.n
        if idx >= 1 && idx <= length(arg_typeids)
            return arg_typeids[idx]
        end
        return Int32(-1)
    elseif val isa Core.SlotNumber
        # SlotNumber in unoptimized IR — same as Argument indexing
        idx = val.id
        if idx >= 1 && idx <= length(arg_typeids)
            return arg_typeids[idx]
        end
        return Int32(-1)
    elseif val isa GlobalRef
        return _resolve_globalref_typeid(val, registry)
    elseif val isa Int64
        return get_type_id(registry, Int64)
    elseif val isa Int32
        return get_type_id(registry, Int32)
    elseif val isa Float64
        return get_type_id(registry, Float64)
    elseif val isa Float32
        return get_type_id(registry, Float32)
    elseif val isa Bool
        return get_type_id(registry, Bool)
    elseif val isa Nothing
        return get_type_id(registry, Nothing)
    elseif val isa QuoteNode
        # QuoteNode wraps a literal value
        return _resolve_typeid(val.value, arg_typeids, ssa_types, registry)
    elseif val isa Type
        # Type literal (e.g., Int64 as a value) — look up Type{T}
        tid = get_type_id(registry, Type{val})
        if tid >= 0
            return tid
        end
        return get_type_id(registry, DataType)
    else
        return Int32(-1)
    end
end

"""
    _resolve_globalref_typeid(gr::GlobalRef, registry) → Int32

Resolve a GlobalRef to its TypeID by looking up the actual function value.
Intrinsic functions get unique TypeIDs (registered by register_intrinsic_return_types!).
"""
function _resolve_globalref_typeid(gr::GlobalRef, registry::TypeIDRegistry)::Int32
    val = try
        getfield(gr.mod, gr.name)
    catch
        return Int32(-1)
    end

    # Try looking up the function value directly (works for intrinsics)
    tid = get_type_id(registry, val)
    if tid >= 0
        return tid
    end

    # Fall back to typeof(val) (works for regular functions like +, *)
    tid = get_type_id(registry, typeof(val))
    if tid >= 0
        return tid
    end

    return Int32(-1)
end

# ═══════════════════════════════════════════════════════════════════════════════
# WASM-compilable thin_typeinf — no Dict, no Module.getfield, no TypeIDRegistry
# ═══════════════════════════════════════════════════════════════════════════════

"""
    wasm_resolve_val_typeid(val, arg_typeids, ssa_types, typeid_i64, typeid_i32, typeid_f64, typeid_bool) → Int32

WASM-compilable value TypeID resolver. Uses Int32 constants instead of TypeIDRegistry.
"""
function wasm_resolve_val_typeid(
    @nospecialize(val),
    arg_typeids::Vector{Int32},
    ssa_types::Vector{Int32},
    typeid_i64::Int32, typeid_i32::Int32, typeid_f64::Int32, typeid_bool::Int32
)::Int32
    if val isa Core.SSAValue
        return ssa_types[val.id]
    elseif val isa Core.Argument
        n = Int32(val.n)
        if n >= Int32(1) && n <= Int32(length(arg_typeids))
            return arg_typeids[n]
        end
        return Int32(-1)
    elseif val isa Int64
        return typeid_i64
    elseif val isa Int32
        return typeid_i32
    elseif val isa Float64
        return typeid_f64
    elseif val isa Bool
        return typeid_bool
    else
        return Int32(-1)
    end
end

"""
    wasm_thin_typeinf(code, callee_typeids, arg_typeids, rt_table,
                      typeid_i64, typeid_i32, typeid_f64, typeid_bool) → Vector{Int32}

WASM-compilable type inference. No Dict, no GlobalRef resolution, no TypeIDRegistry.

# Arguments
- `code::Vector{Any}`: CodeInfo.code statements
- `callee_typeids::Vector{Int32}`: Pre-resolved callee TypeID for each statement.
  For call/invoke stmts, the TypeID of the callee function. -1 for non-call stmts.
  Built by JS deserializer from intrinsic names or function TypeIDs.
- `arg_typeids::Vector{Int32}`: TypeIDs for each slot (1-based, slot 1 = #self#)
- `rt_table::Vector{Int32}`: Return type hash table
- `typeid_i64`, `typeid_i32`, `typeid_f64`, `typeid_bool`: TypeID constants for literal dispatch
"""
function wasm_thin_typeinf(
    code::Vector{Any},
    callee_typeids::Vector{Int32},
    arg_typeids::Vector{Int32},
    rt_table::Vector{Int32},
    typeid_i64::Int32, typeid_i32::Int32, typeid_f64::Int32, typeid_bool::Int32
)::Vector{Int32}
    n = Int32(length(code))
    ssa_types = Vector{Int32}(undef, Int(n))
    i = Int32(1)
    while i <= n
        ssa_types[i] = Int32(-1)
        i = i + Int32(1)
    end

    i = Int32(1)
    while i <= n
        stmt = code[i]

        if stmt isa Expr && stmt.head === :call
            # callee TypeID is pre-resolved in callee_typeids[i]
            callee_tid = callee_typeids[i]
            args = stmt.args
            nargs = Int32(length(args))
            arg_tids = Vector{Int32}(undef, Int(nargs - Int32(1)))
            j = Int32(2)
            while j <= nargs
                arg_tids[j - Int32(1)] = wasm_resolve_val_typeid(
                    args[j], arg_typeids, ssa_types,
                    typeid_i64, typeid_i32, typeid_f64, typeid_bool)
                j = j + Int32(1)
            end
            h = composite_hash(callee_tid, arg_tids)
            ssa_types[i] = lookup_return_type(rt_table, h)

        elseif stmt isa Expr && stmt.head === :invoke
            callee_tid = callee_typeids[i]
            args = stmt.args
            nargs = Int32(length(args))
            arg_tids = Vector{Int32}(undef, Int(nargs - Int32(2)))
            j = Int32(3)
            while j <= nargs
                arg_tids[j - Int32(2)] = wasm_resolve_val_typeid(
                    args[j], arg_typeids, ssa_types,
                    typeid_i64, typeid_i32, typeid_f64, typeid_bool)
                j = j + Int32(1)
            end
            h = composite_hash(callee_tid, arg_tids)
            ssa_types[i] = lookup_return_type(rt_table, h)

        elseif stmt isa Core.ReturnNode
            # ReturnNode.val — use SSAValue resolution
            # Note: ReturnNode without val (unreachable return) stays -1
            ret_val = stmt.val
            ssa_types[i] = wasm_resolve_val_typeid(
                ret_val, arg_typeids, ssa_types,
                typeid_i64, typeid_i32, typeid_f64, typeid_bool)

        elseif stmt isa Core.GotoNode || stmt isa Core.GotoIfNot
            ssa_types[i] = Int32(-1)

        else
            # Literals and other values
            ssa_types[i] = wasm_resolve_val_typeid(
                stmt, arg_typeids, ssa_types,
                typeid_i64, typeid_i32, typeid_f64, typeid_bool)
        end

        i = i + Int32(1)
    end

    return ssa_types
end
