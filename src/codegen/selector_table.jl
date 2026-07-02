# ============================================================================
# parity(M8): THE DISPATCH TABLE — dart dispatch_table.dart:391-458
# ============================================================================
#
# dart's model, faithfully: a SELECTOR (there: method name; here: generic function
# + arity) owns a map {classId → target}. Selectors that need dispatch (callCount>0
# && targetCount>1) get an OFFSET into ONE flat module-level funcref table via
# first-fit packing; a virtual call is
#     receiver.classId + selector.offset → call_indirect(selector signature)
# Monomorphic selectors (targetCount==1) NEVER enter the table — direct call
# (code_generator.dart:2085-2088).
#
# Julia adaptation (multiple dispatch, honestly): the DISPATCH AXIS is the first
# argument position whose registered specializations actually vary. Multi-axis
# selectors cascade: an axis-1 row target is a per-class trampoline dispatching
# axis-2 through the SAME mechanism — still the one table (M8.3).
#
# This file replaces the FNV-1a hash apparatus of dispatch.jl (per-function hash
# tables + probe loops + whole-body replacement), which M8.4 DELETES.

"""
    SelectorInfo

One dispatchable (generic function, arity) — dart's `SelectorInfo`
(dispatch_table.dart:60). `targets` maps the DFS classId of the dispatch-axis
argument to the wasm func index of the specialization compiled for it.
"""
mutable struct SelectorInfo
    func_ref::Any                       # the generic function
    arity::Int
    axis::Int                           # 1-based dispatch-axis arg position
    targets::Dict{Int32,UInt32}         # classId(axis arg) → wasm func idx
    target_return_types::Dict{Int32,Type}
    call_count::Int                     # call sites naming this selector
    offset::Union{Nothing,Int}          # assigned by pack_selector_offsets! (M8.2)
    multi_axis::Bool                    # >1 varying arg position (cascade, M8.3)
end

target_count(s::SelectorInfo) = length(s.targets)
is_monomorphic(s::SelectorInfo) = target_count(s) == 1

"""dart `needsDispatch` (dispatch_table.dart:401-403): used AND polymorphic."""
needs_dispatch(s::SelectorInfo) = s.call_count > 0 && target_count(s) > 1

"""
    SelectorRegistry

All selectors of a module compile + (M8.2) the one flat table layout.
"""
mutable struct SelectorRegistry
    selectors::Dict{Tuple{Any,Int},SelectorInfo}   # (func_ref, arity) → info
    table::Vector{Union{Nothing,UInt32}}           # the ONE flat table (M8.2)
    wasm_table_idx::Union{Nothing,UInt32}
end
SelectorRegistry() = SelectorRegistry(Dict{Tuple{Any,Int},SelectorInfo}(), Union{Nothing,UInt32}[], nothing)

"""
    build_selectors(func_registry, type_registry) -> SelectorRegistry

Group the module's registered specializations into selectors (dart
dispatch_table.dart:380-399). For each (generic function, arity):

- the DISPATCH AXIS = the first arg position whose specialization types vary
  (Julia's dispatch column). Positions whose type is identical across all
  specializations are not dispatch-relevant for this selector.
- `targets[classId(axis type)] = func idx`. An axis type without a classId
  (e.g. String until M9 — the documented exception) drops the specialization
  from table dispatch; the selector records it via `multi_axis`-style honesty
  only if it varies elsewhere.
"""
function build_selectors(func_registry, type_registry)::SelectorRegistry
    reg = SelectorRegistry()
    for (func_ref, infos) in func_registry.by_ref
        length(infos) < 2 && continue   # monomorphic groups devirtualize trivially
        by_arity = Dict{Int,Vector{Any}}()
        for info in infos
            push!(get!(Vector{Any}, by_arity, length(info.arg_types)), info)
        end
        for (arity, ainfos) in by_arity
            length(ainfos) < 2 && continue
            # varying positions
            varying = Int[]
            for pos in 1:arity
                ts = Set{Any}(i.arg_types[pos] for i in ainfos)
                length(ts) > 1 && push!(varying, pos)
            end
            isempty(varying) && continue          # duplicate registrations, not dispatch
            axis = varying[1]
            targets = Dict{Int32,UInt32}()
            rets = Dict{Int32,Type}()
            for i in ainfos
                T = i.arg_types[axis]
                (T isa DataType && isconcretetype(T)) || continue
                cid = Int32(ensure_type_id!(type_registry, T))
                # Julia specificity: last registration wins only if unseen — the
                # func_registry registers most-specific methods once per tuple, so
                # collisions here mean an axis tie (multi-axis case); keep the first.
                haskey(targets, cid) || (targets[cid] = i.wasm_idx; rets[cid] = i.return_type)
            end
            isempty(targets) && continue
            reg.selectors[(func_ref, arity)] = SelectorInfo(
                func_ref, arity, axis, targets, rets, 0, nothing, length(varying) > 1)
        end
    end
    return reg
end

"""
    count_selector_calls!(reg, code_infos)

dart's `callCount` (dispatch_table.dart:70): scan every compiled body's `:call`
statements and count uses per selector. Selectors never called stay out of the
table (needsDispatch).
"""
function count_selector_calls!(reg::SelectorRegistry, code_infos)
    isempty(reg.selectors) && return reg
    for ci in code_infos
        ci isa Core.CodeInfo || continue
        for stmt in ci.code
            (stmt isa Expr && stmt.head === :call) || continue
            callee = stmt.args[1]
            callee isa GlobalRef || continue
            f = try getfield(callee.mod, callee.name) catch; nothing end
            f === nothing && continue
            arity = length(stmt.args) - 1
            s = get(reg.selectors, (f, arity), nothing)
            s !== nothing && (s.call_count += 1)
        end
    end
    return reg
end

"""
    pack_selector_offsets!(reg) -> Int

dart's first-fit offset packing (dispatch_table.dart:405-458): sort selectors by
`classIds*10 + callCount` descending, then scan each from `firstAvailable -
minClassId` until its row pattern fits the gaps. Returns the table length.
"""
function pack_selector_offsets!(reg::SelectorRegistry)::Int
    sels = [s for s in values(reg.selectors) if needs_dispatch(s)]
    sort!(sels; by=s -> -(target_count(s) * 10 + s.call_count))
    table = reg.table
    empty!(table)
    first_available = 0
    first = true
    for s in sels
        cids = sort!(collect(keys(s.targets)))
        offset = first ? 0 : first_available - Int(cids[1])
        first = false
        while true
            fits = true
            for cid in cids
                entry = offset + Int(cid)
                entry < 0 && (fits = false; break)
                entry >= length(table) && break          # extends the table — fits
                table[entry + 1] !== nothing && (fits = false; break)
            end
            fits && break
            offset += 1
        end
        s.offset = offset
        for cid in cids
            entry = offset + Int(cid)
            while length(table) <= entry
                push!(table, nothing)
            end
            @assert table[entry + 1] === nothing
            table[entry + 1] = s.targets[cid]
        end
        while first_available < length(table) && table[first_available + 1] !== nothing
            first_available += 1
        end
    end
    return length(table)
end
