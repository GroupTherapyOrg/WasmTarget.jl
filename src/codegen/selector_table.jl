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

# ============================================================================
# M8.2 — route single-axis dispatch through the ONE dart table
# ============================================================================

"""
    pack_dispatch_selectors!(mod, dt_registry, type_registry)

At metadata time (entries known, wrappers not yet): detect each DispatchTable's
dispatch axis; SINGLE-AXIS tables (exactly one varying typeId position — keying
on that axis alone is provably equivalent to the full-tuple key) get first-fit
packed into ONE flat funcref table (dart dispatch_table.dart:405-458). Offsets +
positions land on `dt_registry`; elements are filled after wrapper emission by
[`fill_selector_table_elements!`](@ref). Multi-axis tables keep the FNV probe
(the M8.3 cascade replaces it).
"""
function pack_dispatch_selectors!(mod::WasmModule, dt_registry, type_registry)
    isempty(dt_registry.tables) && return
    # collect single-axis selectors: (func_ref, rows::Vector{(classId, entry_i)}, weight)
    packable = Tuple{Any,Vector{Tuple{Int,Int}},Int}[]
    for (func_ref, dt) in dt_registry.tables
        arity = Int(dt.arity)
        varying = Int[]
        for pos in 1:arity
            tids = Set{Int32}(e.type_ids[pos] for e in dt.entries)
            length(tids) > 1 && push!(varying, pos)
        end
        length(varying) == 1 || continue
        axis = varying[1]
        rows = Tuple{Int,Int}[]
        seen = Set{Int}()
        unique_axis = true
        for (i, e) in enumerate(dt.entries)
            cid = Int(e.type_ids[axis])
            cid in seen && (unique_axis = false; break)   # axis tie ⇒ not single-axis
            push!(seen, cid)
            push!(rows, (cid, i))
        end
        unique_axis || continue
        dt_registry.selector_axis[func_ref] = axis
        push!(packable, (func_ref, rows, length(rows) * 10))
    end
    isempty(packable) && return
    # dart's first-fit packing (sort weight desc; callCount folded into weight when known)
    sort!(packable; by=t -> -t[3])
    table = Union{Nothing,Int}[]   # occupied marker (entry refs resolved later)
    first_available = 0
    is_first = true
    for (func_ref, rows, _) in packable
        sort!(rows; by=r -> r[1])
        cids = [r[1] for r in rows]
        offset = is_first ? 0 : first_available - cids[1]
        is_first = false
        while true
            fits = true
            for cid in cids
                entry = offset + cid
                entry < 0 && (fits = false; break)
                entry >= length(table) && break
                table[entry + 1] !== nothing && (fits = false; break)
            end
            fits && break
            offset += 1
        end
        positions = Tuple{Int,Int}[]
        for (cid, entry_i) in rows
            pos = offset + cid
            while length(table) <= pos
                push!(table, nothing)
            end
            @assert table[pos + 1] === nothing
            table[pos + 1] = entry_i
            push!(positions, (pos, entry_i))
        end
        dt_registry.selector_offset[func_ref] = offset
        dt_registry.selector_positions[func_ref] = positions
        while first_available < length(table) && table[first_available + 1] !== nothing
            first_available += 1
        end
    end
    dt_registry.selector_table_len = length(table)
    dt_registry.selector_table_idx = add_table!(mod, FuncRef, UInt32(length(table)))
    return
end

"""
    fill_selector_table_elements!(mod, dt_registry)

After wrapper emission (dispatch.jl): write the packed positions' wrapper indices
into the ONE table as element segments (contiguous runs, dart output(),
dispatch_table.dart:461-470).
"""
function fill_selector_table_elements!(mod::WasmModule, dt_registry)
    dt_registry.selector_table_idx === nothing && return
    entries = Tuple{Int,UInt32}[]   # (position, wrapper_idx)
    for (func_ref, positions) in dt_registry.selector_positions
        dt = dt_registry.tables[func_ref]
        for (pos, entry_i) in positions
            push!(entries, (pos, dt.entries[entry_i].wrapper_idx))
        end
    end
    sort!(entries; by=first)
    i = 1
    while i <= length(entries)
        j = i
        while j < length(entries) && entries[j + 1][1] == entries[j][1] + 1
            j += 1
        end
        add_elem_segment!(mod, dt_registry.selector_table_idx, entries[i][1],
                          UInt32[e[2] for e in entries[i:j]])
        i = j + 1
    end
    return
end

"""
    generate_selector_caller_body(dt, dt_registry, n_params, base_struct_idx) -> (body, locals)

dart's virtual call site (code_generator.dart:2110-2122), as the dispatcher body:

    push args · receiver.classId · [+ offset] · call_indirect(sig, THE table)

A classId with no row hits a null funcref → trap: the honest MethodError analog
(loud, dart-legit) — same posture the FNV probe's miss already had.
"""
function generate_selector_caller_body(dt::DispatchTable, dt_registry,
                                       n_params::Int, base_struct_idx::UInt32;
                                       caller_return_type::Type=Any, mod=nothing, type_registry=nothing)
    axis = dt_registry.selector_axis[dt.func_ref]
    offset = dt_registry.selector_offset[dt.func_ref]
    b = InstrBuilder(; func_name="selector_caller")
    arity = Int(dt.arity)
    # dispatch signature params are AnyRef: push params in order
    for j in 1:arity
        local_get!(b, UInt32(j - 1))
    end
    # receiver.classId (dart: struct.get topInfo.classId)
    local_get!(b, UInt32(axis - 1))
    ref_cast!(b, Int64(base_struct_idx), false)
    struct_get!(b, UInt32(base_struct_idx), UInt32(0), I32)
    if offset != 0
        i32_const!(b, Int64(offset))
        num!(b, Opcode.I32_ADD)
    end
    sig = FuncType(fill(AnyRef, arity),
                   dt.result_wasm_type in (I32, I64, F32, F64, AnyRef) ?
                       WasmValType[dt.result_wasm_type] : WasmValType[])
    call_indirect!(b, dt.dispatch_sig_idx, dt_registry.selector_table_idx,
                   sig.params, sig.results)
    # Result seam: the caller's DECLARED result may be anyref (dynamic-call inference)
    # while the selector signature is typed — box through the ONE producer.
    locals = WasmValType[]
    declared = julia_to_wasm_type(caller_return_type)
    if _wt_is_ref(declared) && dt.result_wasm_type in (I32, I64, F32, F64) &&
       mod !== nothing && type_registry !== nothing
        rts = Set{Type}(e.return_type for e in dt.entries)
        jt = length(rts) == 1 ? first(rts) : nothing
        if jt !== nothing
            # the ONE box shape (emit_classid_box!): save value · classId · value · struct.new
            box_idx = get_numeric_box_type!(mod, type_registry, dt.result_wasm_type)
            tid = ensure_type_id!(type_registry, jt)
            scratch = UInt32(n_params)   # first extra local
            push!(locals, dt.result_wasm_type)
            builder_set_local_type!(b, Int(scratch), dt.result_wasm_type)
            local_set!(b, scratch)
            i32_const!(b, Int64(tid))
            local_get!(b, scratch)
            struct_new!(b, box_idx, WasmValType[I32, dt.result_wasm_type])
        end
    end
    end_block!(b)
    return builder_code(b), locals
end
