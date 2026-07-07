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

# census F5 (march5): the M8.1 SelectorInfo/SelectorRegistry transcription
# (a faithful dispatch_table.dart:27-77 port) was DEAD CODE — zero callers; the
# LIVE packer is pack_dispatch_selectors! below, keyed on DispatchTableRegistry.
# Deleted rather than kept as reference: the dart source IS the reference.

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
[`fill_selector_table_elements!`](@ref). Multi-axis tables dispatch via the
M8.3 CASCADE (composed single-axis hops through the SAME table; FNV is deleted).
"""
const _ST_BASE_IDX = Base.RefValue{UInt32}(0)
_st_base_idx(_) = _ST_BASE_IDX[]

function pack_dispatch_selectors!(mod::WasmModule, dt_registry, type_registry)
    isempty(dt_registry.tables) && return
    type_registry.base_struct_idx !== nothing && (_ST_BASE_IDX[] = type_registry.base_struct_idx)
    # collect single-axis selectors: (func_ref, rows::Vector{(classId, entry_i)}, weight)
    packable = Tuple{Any,Vector{Tuple{Int,Int}},Int,Dict{Int,Vector{Int}},Int}[]
    for (func_ref, dt) in dt_registry.tables
        arity = Int(dt.arity)
        varying = Int[]
        for pos in 1:arity
            tids = Set{Int32}(e.type_ids[pos] for e in dt.entries)
            length(tids) > 1 && push!(varying, pos)
        end
        1 <= length(varying) <= 2 || continue   # 3+-axis stays FNV (unseen in practice)
        axis = varying[1]
        groups = Dict{Int,Vector{Int}}()          # classId(axis1) → entry indices
        for (i, e) in enumerate(dt.entries)
            push!(get!(Vector{Int}, groups, Int(e.type_ids[axis])), i)
        end
        if length(varying) == 1
            any(length(g) > 1 for g in values(groups)) && continue   # axis tie
        else
            # parity(M8.3): 2-axis cascade — each tied level-1 group must be
            # cleanly dispatchable on axis2
            axis2 = varying[2]
            ok2 = all(values(groups)) do g
                length(g) == 1 && return true
                cids2 = [Int(dt.entries[i].type_ids[axis2]) for i in g]
                length(unique(cids2)) == length(cids2)
            end
            ok2 || continue
        end
        rows = Tuple{Int,Int}[(cid, g[1]) for (cid, g) in groups]   # entry_i; -1 marks cascade below
        for (cid, g) in groups
            length(g) > 1 && (rows[findfirst(r -> r[1] == cid, rows)] = (cid, -1))
        end
        dt_registry.selector_axis[func_ref] = axis
        push!(packable, (func_ref, rows, length(rows) * 10, groups, length(varying) == 2 ? varying[2] : 0))
    end
    isempty(packable) && return
    # dart's first-fit packing (sort weight desc; callCount folded into weight when known)
    sort!(packable; by=t -> -t[3])
    # helper: first-fit one row-set into the shared layout, returns its offset
    function _fit!(table, cids, first_available, is_first)
        offset = is_first ? 0 : first_available - cids[1]
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
        for cid in cids
            pos = offset + cid
            while length(table) <= pos
                push!(table, nothing)
            end
            table[pos + 1] = 0   # occupied
        end
        return offset
    end
    table = Union{Nothing,Int}[]   # occupied marker (entry refs resolved later)
    first_available = 0
    is_first = true
    for (func_ref, rows, _, groups, axis2) in packable
        sort!(rows; by=r -> r[1])
        offset = _fit!(table, [r[1] for r in rows], first_available, is_first)
        is_first = false
        positions = Tuple{Int,Int}[]
        cascades = eltype(valtype(dt_registry.selector_cascades))[]
        for (cid, entry_i) in rows
            pos = offset + cid
            if entry_i >= 0
                push!(positions, (pos, entry_i))
            else
                # cascade slot: pack the level-2 rows for this group into the SAME table
                g = groups[cid]
                rows2 = sort!(Tuple{Int,Int}[(Int(dt_registry.tables[func_ref].entries[i].type_ids[axis2]), i) for i in g]; by=r -> r[1])
                while first_available < length(table) && table[first_available + 1] !== nothing
                    first_available += 1
                end
                off2 = _fit!(table, [r[1] for r in rows2], first_available, false)
                push!(cascades, (l1_pos=pos, axis2=axis2, offset2=off2,
                                 rows2=Tuple{Int,Int}[(off2 + c, i) for (c, i) in rows2]))
            end
        end
        dt_registry.selector_offset[func_ref] = offset
        dt_registry.selector_positions[func_ref] = positions
        isempty(cascades) || (dt_registry.selector_cascades[func_ref] = cascades)
        while first_available < length(table) && table[first_available + 1] !== nothing
            first_available += 1
        end
    end
    dt_registry.selector_table_len = length(table)
    dt_registry.selector_table_idx = add_table!(mod, FuncRef, UInt32(length(table)))
    # parity(M8.4): a table that can't route (3+-axis / axis-tied — unseen in practice)
    # is DROPPED: its callers compile their normal bodies, and an unresolvable dynamic
    # call surfaces through the loud record_unsupported! posture instead of a probe.
    for func_ref in collect(keys(dt_registry.tables))
        if !haskey(dt_registry.selector_offset, func_ref)
            @debug "parity(M8.4): dispatch table for $(func_ref) is not selector-routable — dropped"
            delete!(dt_registry.tables, func_ref)
        end
    end
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
        # parity(M8.3): cascade trampolines — dart's virtual-call shape applied to
        # axis2, emitted as tiny uniform-sig functions living in the SAME table.
        for c in get(dt_registry.selector_cascades, func_ref, [])
            arity = Int(dt.arity)
            local _tr_res = dt.result_wasm_type in (I32, I64, F32, F64, AnyRef) ?
                            WasmValType[dt.result_wasm_type] : WasmValType[]
            tb = InstrBuilder(copy(dt.slot_types), _tr_res; func_name="selector_trampoline", mod=mod)
            for j in 1:arity
                local_get!(tb, UInt32(j - 1))
            end
            local_get!(tb, UInt32(c.axis2 - 1))
            ref_cast!(tb, Int64(_st_base_idx(dt_registry)), false)
            struct_get!(tb, UInt32(_st_base_idx(dt_registry)), UInt32(0), I32)
            if c.offset2 != 0
                i32_const!(tb, Int64(c.offset2))
                num!(tb, Opcode.I32_ADD)
            end
            res = dt.result_wasm_type in (I32, I64, F32, F64, AnyRef) ?
                WasmValType[dt.result_wasm_type] : WasmValType[]
            call_indirect!(tb, dt.dispatch_sig_idx, dt_registry.selector_table_idx,
                           copy(dt.slot_types), res)
            end_block!(tb)
            tramp_idx = add_function!(mod, copy(dt.slot_types), res, WasmValType[], builder_code(tb))
            push!(entries, (c.l1_pos, tramp_idx))
            for (pos2, entry_i) in c.rows2
                push!(entries, (pos2, dt.entries[entry_i].wrapper_idx))
            end
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
    arity = Int(dt.arity)
    # fullstrict: the builder carries its TRUE signature (params + the dispatch result)
    # so the function frame's end validates against the real contract, and mod for
    # the derived-truth chokepoints.
    local _sc_res = dt.result_wasm_type in (I32, I64, F32, F64, AnyRef) ?
                    WasmValType[dt.result_wasm_type] : WasmValType[]
    b = InstrBuilder(copy(dt.slot_types), _sc_res; func_name="selector_caller", mod=mod)
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
    sig = FuncType(copy(dt.slot_types),   # march11: the per-slot LUB (was fill(AnyRef))
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
