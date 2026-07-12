# ============================================================================
# Statement Compilation
# ============================================================================

"""
    extract_foreigncall_name(name_arg) -> Union{Symbol, Nothing}

Extract the symbol name from a :foreigncall expression's first argument.
Handles format differences between Julia versions:
- Julia 1.12: QuoteNode(:name) or bare :name
- Julia 1.13: QuoteNode((:name,)) — tuple wrapping the symbol
Also handles GlobalRef (e.g., Base.memhash).
"""
function extract_foreigncall_name(name_arg)::Union{Symbol, Nothing}
    val = if name_arg isa QuoteNode
        name_arg.value
    elseif name_arg isa Symbol
        name_arg
    elseif name_arg isa GlobalRef
        name_arg.name
    elseif name_arg isa Expr && name_arg.head === :tuple && length(name_arg.args) >= 1
        # Julia 1.13+: foreigncall names wrapped in tuple Expr: Expr(:tuple, QuoteNode(:name))
        inner = name_arg.args[1]
        inner isa QuoteNode ? inner.value : (inner isa Symbol ? inner : nothing)
    else
        nothing
    end
    # Handle case where value is a Tuple (shouldn't happen with Expr handling above, but defensive)
    if val isa Tuple && length(val) >= 1 && val[1] isa Symbol
        return val[1]
    end
    return val isa Symbol ? val : nothing
end

"""
    _trace_memmove_ptr(arg, ctx) -> (vector_value, [(is_add, offset_value)...]) | nothing

Walk a pointer SSA chain (bitcast/add_ptr/sub_ptr over
getfield(vec,:ref)→:ptr_or_offset) back to its backing Vector. Returns
nothing unless the base is a Vector with 1-byte elements (memmove counts
bytes; element index == byte offset only for elsize 1).
"""
# Emit the backing wasm ARRAY ref for a walk result: Vector{T} structs read
# field 1 (.ref); Memory{T} values ARE the array. Always cast to `arr_t`.
# MIGRATED to InstrBuilder: emits typed struct.get/ref.cast directly onto the
# caller's builder `b`; compile_value splices bridge via emit_raw!. Byte-identical
# (struct.get field 1 = 0xFB 0x02 leb_u(t) leb_u(1); ref.cast null = 0xFB REF_CAST_NULL leb_s(arr_t)).
function _emit_backing_array!(b::InstrBuilder, vec, ctx::AbstractCompilationContext, arr_t)
    vt = infer_value_type(vec, ctx)
    # parity(M9): a String/Symbol backing is the classed struct — the funnel reads .data
    if vt === String || vt === Symbol
        emit_value!(b, vec, ctx, ConcreteRef(UInt32(arr_t), true))
        return b
    end
    is_mem = vt isa DataType && (vt.name.name === :Memory || vt.name.name === :GenericMemory ||
                                 vt.name.name === :MemoryRef || vt.name.name === :GenericMemoryRef)
    if is_mem
        emit_value!(b, vec, ctx, ConcreteRef(UInt32(arr_t), true))
    else
        vinfo = ctx.type_registry.structs[vt]
        emit_value!(b, vec, ctx, ConcreteRef(UInt32(vinfo.wasm_type_idx), true))
        struct_get!(b, vinfo.wasm_type_idx, wasm_field_idx(vinfo, 1), ConcreteRef(UInt32(arr_t), true))
    end
    ref_cast!(b, Int64(arr_t), true)
    return b
end

function _pointer_node_refs(value, ssa_id::Int)::Bool
    value isa Core.SSAValue && return value.id == ssa_id
    value isa Expr && return any(arg -> _pointer_node_refs(arg, ssa_id), value.args)
    value isa Core.PiNode && return _pointer_node_refs(value.val, ssa_id)
    if value isa Core.PhiNode
        return any(eachindex(value.values)) do i
            isassigned(value.values, i) && _pointer_node_refs(value.values[i], ssa_id)
        end
    end
    value isa Core.ReturnNode && isdefined(value, :val) &&
        return _pointer_node_refs(value.val, ssa_id)
    return false
end

"""
Prove that a `jl_value_ptr` result never escapes WT's storage-relative pointer
algebra. In that algebra a storage object's base offset is exactly zero; the
backing object is carried by the recognized consumer and may never be observed as
a fabricated numeric address. Any return, aggregate store, comparison, or unknown
consumer rejects the compilation.
"""
function _storage_relative_pointer_is_closed(ctx::AbstractCompilationContext,
                                             root_ssa::Int)::Bool
    code = ctx.code_info.code
    pending = Int[root_ssa]
    seen = Set{Int}()
    while !isempty(pending)
        source = pop!(pending)
        source in seen && continue
        push!(seen, source)
        for (consumer_idx, consumer) in enumerate(code)
            consumer_idx == source && continue
            _pointer_node_refs(consumer, source) || continue
            if consumer isa Core.PiNode || consumer isa Core.PhiNode
                push!(pending, consumer_idx)
                continue
            end
            consumer isa Expr || return false
            if consumer.head === :call
                callee = consumer.args[1]
                name = callee isa GlobalRef ? callee.name : callee
                name in (:add_ptr, :sub_ptr, :bitcast, :pointerref, :pointerset) || return false
                result_type = get(ctx.ssa_types, consumer_idx, Any)
                result_type isa Type && result_type <: Ptr && push!(pending, consumer_idx)
            elseif consumer.head === :foreigncall
                name = extract_foreigncall_name(consumer.args[1])
                name in (:memcpy, :memmove, :memset) || return false
                result_type = get(ctx.ssa_types, consumer_idx, Any)
                result_type isa Type && result_type <: Ptr && push!(pending, consumer_idx)
            else
                return false
            end
        end
    end
    return true
end

function _trace_memmove_ptr(arg, ctx::AbstractCompilationContext;
                            eltypes = (UInt8, Int8), allow_ref::Bool = false,
                            _seen::Set{Int} = Set{Int}())
    # Walk through recognized storage-relative operations looking only for the
    # backing object's identity. Offsets remain runtime values and are compiled
    # by the consumer; no raw host address is ever synthesized.
    _mm_dbg = haskey(ENV, "WT_TRACE_MM")
    _fail = function (why, what)
        _mm_dbg && println(stderr, "  MMtrace FAIL [", why, "]: ", repr(what)[1:min(end, 110)])
        return nothing
    end
    cur = arg
    for _ in 1:48
        cur isa Core.SSAValue || return _fail("non-ssa", cur)
        cur.id in _seen && return _fail("pointer-cycle", cur)
        push!(_seen, cur.id)
        st = ctx.code_info.code[cur.id]
        _mm_dbg && println(stderr, "  MMtrace %", cur.id, " = ", repr(st)[1:min(end, 100)])
        if st isa Core.PiNode
            cur = st.val
        elseif st isa Expr && st.head === :foreigncall && length(st.args) >= 6 &&
               extract_foreigncall_name(st.args[1]) === :jl_value_ptr
            # `jl_value_ptr(obj)` contributes the backing identity; its exact
            # target address component is the storage-relative base offset.
            cur = st.args[6]
        elseif st isa Expr && st.head === :foreigncall &&
               extract_foreigncall_name(st.args[1]) === :jl_string_to_genericmemory
            # This foreigncall's Wasm representation is the source String's
            # byte array, so its SSA result is itself a valid backing identity.
            return cur
        elseif st isa Expr && st.head === :foreigncall && length(st.args) >= 6 &&
               extract_foreigncall_name(st.args[1]) in (:jl_string_ptr, :jl_symbol_name)
            # The pointed-to bytes belong to the classed String/Symbol operand.
            return st.args[6]
        elseif st isa Core.PhiNode
            terminals = Any[]
            for i in eachindex(st.values)
                isassigned(st.values, i) || continue
                value = st.values[i]
                value isa Core.SSAValue && value.id == cur.id && continue
                terminal = _trace_memmove_ptr(value, ctx; eltypes, allow_ref,
                                              _seen=copy(_seen))
                terminal === nothing && return _fail("phi-untraceable", st)
                any(t -> isequal(t, terminal), terminals) || push!(terminals, terminal)
            end
            length(terminals) == 1 || return _fail("phi-multiple-storage", st)
            return terminals[1]
        elseif allow_ref && st isa Expr && st.head === :new
            # P4-stdlib: pointer into a Base.RefValue{T} box (radix sort
            # counters use pointer_from_objref(Ref(...))) — the terminal IS
            # the box; the caller emits struct.get/set on it.
            local _nt = infer_value_type(cur, ctx)
            (_nt isa DataType && _nt <: Base.RefValue) || return _fail("new-non-refvalue: $_nt", st)
            return cur
        elseif st isa Expr && st.head === :call && length(st.args) >= 2
            cf = st.args[1]
            cfn = cf isa GlobalRef ? cf.name : cf
            if cfn === :bitcast
                cur = st.args[3]
            elseif cfn === :add_ptr || cfn === :sub_ptr
                cur = st.args[2]
            elseif cfn === :memorynew
                # P4-stdlib: pointer into a freshly-allocated Memory{T} —
                # Memory compiles DIRECTLY as a wasm array; valid terminal
                # (callers use _emit_backing_array! which skips the Vector
                # struct deref for Memory values).
                local _mn_t = infer_value_type(cur, ctx)
                local _mn_el = _mn_t isa DataType && length(_mn_t.parameters) >= 2 ? _mn_t.parameters[2] : nothing
                _mn_el in eltypes || return _fail("memorynew-elty: $_mn_t", st)
                return cur
            elseif cfn === :memoryrefnew
                # The MemoryRef value itself is the runtime owner. Keeping it as
                # the terminal preserves resize/copy phis that legitimately select
                # different allocations; following into one constructor arm would
                # invent a single backing identity.
                local _mr_t = get_ssa_type(ctx, cur)
                local _mr_el = _mr_t isa DataType && _mr_t.name.name === :GenericMemoryRef &&
                               length(_mr_t.parameters) >= 2 ? _mr_t.parameters[2] :
                               (_mr_t isa DataType && !isempty(_mr_t.parameters) ? _mr_t.parameters[1] : nothing)
                _mr_el in eltypes || return _fail("memoryrefnew-elty: $_mr_t", st)
                return cur
            elseif cfn === :getfield && length(st.args) >= 3
                fld = st.args[3] isa QuoteNode ? st.args[3].value : st.args[3]
                if fld === :ptr_or_offset || fld === :ptr
                    owner = st.args[2]
                    owner_type = get_ssa_type(ctx, owner)
                    if owner_type isa DataType &&
                       owner_type.name.name in (:MemoryRef, :GenericMemoryRef) &&
                       owner isa Core.SSAValue
                        # Normalize a MemoryRef pointer projection to its sibling
                        # `.mem` projection when present. Julia's layout branch forms
                        # both `mem.ptr + offset` and `ref.ptr_or_offset`; they denote
                        # the same dynamic allocation and must converge before a phi.
                        for (projection_idx, projection) in enumerate(ctx.code_info.code)
                            projection isa Expr && projection.head === :call &&
                                length(projection.args) >= 3 || continue
                            projection.args[1] isa GlobalRef &&
                                projection.args[1].name === :getfield || continue
                            projection.args[2] == owner || continue
                            projected_field = projection.args[3] isa QuoteNode ?
                                projection.args[3].value : projection.args[3]
                            projected_field === :mem || continue
                            return Core.SSAValue(projection_idx)
                        end
                        return owner
                    elseif owner_type isa DataType &&
                       owner_type.name.name in (:Memory, :GenericMemory)
                        if owner isa Core.SSAValue
                            cur = owner
                        else
                            return owner
                        end
                    else
                        cur = owner
                    end
                elseif fld === :mem
                    memory_type = get_ssa_type(ctx, cur)
                    if memory_type isa DataType &&
                       memory_type.name.name in (:Memory, :GenericMemory)
                        owner = st.args[2]
                        if owner isa Core.SSAValue
                            # Canonicalize repeated `.mem` projections of the same
                            # MemoryRef so pointer-layout phis compare by semantic
                            # owner, not by incidental SSA projection number.
                            for (projection_idx, projection) in enumerate(ctx.code_info.code)
                                projection isa Expr && projection.head === :call &&
                                    length(projection.args) >= 3 || continue
                                projection.args[1] isa GlobalRef &&
                                    projection.args[1].name === :getfield || continue
                                projection.args[2] == owner || continue
                                projected_field = projection.args[3] isa QuoteNode ?
                                    projection.args[3].value : projection.args[3]
                                projected_field === :mem || continue
                                return Core.SSAValue(projection_idx)
                            end
                        end
                        return cur
                    end
                    cur = st.args[2]
                elseif fld === :ref
                    vec = st.args[2]
                    vt = infer_value_type(vec, ctx)
                    (vt isa DataType && vt <: Vector &&
                     eltype(vt) in eltypes) || return _fail("elty-not-allowed: $vt", vec)
                    return vec
                else
                    # P4-stdlib (SHA update!): getfield(obj, fld) whose RESULT
                    # type is an allowed Vector/Memory is itself the backing-store
                    # identity.
                    local _gf_vt = infer_value_type(cur, ctx)
                    if _gf_vt isa DataType && _gf_vt <: Vector && eltype(_gf_vt) in eltypes
                        return cur
                    elseif _gf_vt isa DataType &&
                           _gf_vt.name.name in (:Memory, :GenericMemory) &&
                           eltype(_gf_vt) in eltypes
                        return cur
                    end
                    return _fail("getfield-fld=$fld", st)
                end
            else
                return _fail("call-fn=$cfn", st)
            end
        else
            return _fail("stmt-kind", st)
        end
    end
    return _fail("depth", arg)
end

"""
Compile a single IR statement — dart's ONE code generator, ONE builder (march4
Phase C): THE visitor emits directly into the caller's builder; the byte era's
front seam and accumulator are gone.
"""
function compile_statement!(b::InstrBuilder, stmt, idx::Int, ctx::AbstractCompilationContext)

    # PURE-6027: Reset dead code guard at basic block boundaries.
    # The last_stmt_was_stub flag from a previous stub should NOT cascade across basic
    # block boundaries — the next block is reachable via a different control flow path.
    # Check: (a) previous stmt is a terminator, OR (b) this idx is a jump target.
    if ctx.last_stmt_was_stub && idx > 1
        _should_reset = false
        _prev_stmt = ctx.code_info.code[idx - 1]
        if _prev_stmt isa Core.GotoNode || _prev_stmt isa Core.GotoIfNot || _prev_stmt isa Core.ReturnNode
            _should_reset = true
        else
            # Check if this idx is a jump target of any GotoNode/GotoIfNot
            for _s in ctx.code_info.code
                if (_s isa Core.GotoIfNot && _s.dest == idx) || (_s isa Core.GotoNode && _s.label == idx)
                    _should_reset = true
                    break
                end
            end
        end
        if _should_reset
            ctx.last_stmt_was_stub = false
        end
    end

    # PURE-6022: If a previous statement in this function was a stub (emitted unreachable),
    # skip ALL further statement compilation within the SAME basic block. Bytes after
    # unreachable must be structurally valid WASM, and continuing to compile produces invalid
    # opcodes. Emit unreachable (not empty) so the validator stays in polymorphic stack mode.
    if ctx.last_stmt_was_stub
        unreachable!(b)   # structural trap (dead-block continuation; keeps stack polymorphic)
        return b
    end

    # PURE-6024: Handle slot assignments in unoptimized IR (may_optimize=false).
    # Unwrap Expr(:(=), SlotNumber(n), inner_expr) → compile inner_expr, store to slot local.
    _slot_assign_id = 0  # SlotNumber.id if this is a slot assignment, 0 otherwise
    if stmt isa Expr && stmt.head === :(=) && length(stmt.args) >= 2 && stmt.args[1] isa Core.SlotNumber
        _slot_assign_id = stmt.args[1].id
        stmt = stmt.args[2]  # Unwrap to inner expression
    end

    # PURE-6024b: When a slot assignment RHS is a bare value (SlotNumber, SSAValue, literal,
    # GlobalRef), it won't match any Expr/Return/Goto handler below. Compile it directly
    # as a value so the slot LOCAL_SET at the bottom of this function has something on the stack.
    if _slot_assign_id > 0 && !(stmt isa Expr) && !(stmt isa Core.ReturnNode) &&
       !(stmt isa Core.GotoNode) && !(stmt isa Core.GotoIfNot) && !(stmt isa Core.PhiNode) &&
       !(stmt isa Core.PhiCNode) && !(stmt isa Core.UpsilonNode) && !(stmt isa Core.NewvarNode)
        if haskey(ctx.slot_locals, _slot_assign_id)
            local slot_idx = ctx.slot_locals[_slot_assign_id]
            local slot_type = ctx.locals[slot_idx - ctx.n_params + 1]
            emit_value!(b, stmt, ctx, slot_type)   # THE typed value channel
            local_set!(b, slot_idx)
        end
        return b   # `bytes` untouched on this path
    end

    if stmt isa Core.ReturnNode
        if isdefined(stmt, :val)
            emit_return_coerced!(b, stmt.val, ctx)
        else
            return_!(b)
        end
    elseif stmt isa Core.GotoNode
        # Unconditional branch - handled by control flow analysis

    elseif stmt isa Core.GotoIfNot
        # Conditional branch - handled by control flow analysis

    elseif stmt isa Core.UpsilonNode
        # PURE-9033: UpsilonNode stores a value for later PhiCNode retrieval.
        # Semantics: local.set into the associated PhiCNode's local.
        # The association is: PhiCNode.values contains SSAValue(this_upsilon_idx).
        # Find which PhiCNode references this UpsilonNode.
        if isdefined(stmt, :val)
            for (phic_idx, phic_stmt) in enumerate(ctx.code_info.code)
                if phic_stmt isa Core.PhiCNode && haskey(ctx.phi_locals, phic_idx)
                    for v in phic_stmt.values
                        if v isa Core.SSAValue && v.id == idx
                            # march14: the upsilon store wraps to the PhiC local's declared type
                            emit_value!(b, stmt.val, ctx,
                                        ctx.locals[ctx.phi_locals[phic_idx] - ctx.n_params + 1])
                            local_set!(b, ctx.phi_locals[phic_idx])
                            @goto upsilon_done
                        end
                    end
                end
            end
        end
        @label upsilon_done
        # If no PhiCNode found, UpsilonNode is dead — no-op

    elseif stmt isa Core.PhiCNode
        # PURE-9033: PhiCNode is a no-op at the statement level.
        # The value was already stored into phi_locals[idx] by the associated UpsilonNode.
        # When other statements use SSAValue(idx), compile_value reads from phi_locals[idx].

    elseif stmt isa Core.PiNode
        # A PiNode narrows an existing value. Like dart's wrap/convertType path,
        # preserve that value and coerce its emitted physical type; never repair a
        # failed narrowing with zero or ref.null.
        pi_type = get(ctx.ssa_types, idx, Any)
        if pi_type !== Nothing && haskey(ctx.ssa_locals, idx)
            local_idx = ctx.ssa_locals[idx]
            local_array_idx = local_idx - ctx.n_params + 1
            if !(1 <= local_array_idx <= length(ctx.locals))
                record_unsupported!(ctx, :unsupported_type,
                    "PiNode local has no declared Wasm type"; idx=idx, detail=stmt)
                unreachable!(b)  # structural trap after recorded unsupported
                ctx.last_stmt_was_stub = true
                return b
            end
            expected = ctx.locals[local_array_idx]
            value_builder = _compile_value_b(stmt.val, ctx)
            if length(value_builder.v.stack) != 1
                record_unsupported!(ctx, :unsupported_type,
                    "PiNode source must emit exactly one value, emitted $(length(value_builder.v.stack))";
                    idx=idx, detail=stmt)
                unreachable!(b)  # structural trap after recorded unsupported
                ctx.last_stmt_was_stub = true
                return b
            end
            actual = only(value_builder.v.stack)
            append_builder!(b, value_builder)
            actual === expected || coerce_stack_top!(b, expected, ctx;
                from_julia=(pi_type isa DataType ? pi_type : nothing))
            local_set!(b, local_idx)
        end

    elseif stmt isa Core.NewvarNode
        # PURE-6024: Unoptimized IR slot initialization — no-op in WASM
        # (WASM locals are default-initialized to null/zero)

    elseif stmt isa Core.EnterNode
        # Deliberately emits no instruction here.  THE stackifier owns the
        # control boundary: after this block it opens the typed try_table and
        # catch landing for this EnterNode (stackified.jl: try_open_at).  Keeping
        # region structure out of the scalar statement visitor gives exceptions
        # one lowering route, mirroring dart2wasm's visitTryCatch ownership.

    elseif stmt isa GlobalRef
        # MIGRATED: straight-line global.get/local.set via typed methods on `b`; the
        # value_bytes safety-scan stays a local buffer (byte-inspecting) then bridges via
        # emit_raw!. `bytes` stays empty for this branch (trailing common code appends after).
        isdefined(stmt.mod, stmt.name) || throw(WasmCompileError(WasmDiagnostic(
            :unsupported_global, string(stmt), "GlobalRef is not defined in its source module",
            nothing, nothing)))
        val = getfield(stmt.mod, stmt.name)
        local _gv_b = _compile_value_b(val, ctx)
        append_builder!(b, _gv_b)
        if haskey(ctx.ssa_locals, idx) && !isempty(_gv_b.v.stack)
            local_idx = ctx.ssa_locals[idx]
            local_array_idx = local_idx - ctx.n_params + 1
            1 <= local_array_idx <= length(ctx.locals) || error(
                "GlobalRef SSA local has no declared Wasm type")
            coerce_stack_top!(b, ctx.locals[local_array_idx], ctx;
                              from_julia=get(ctx.ssa_types, idx, typeof(val)))
            local_set!(b, local_idx)
        end

    elseif stmt isa Expr
        # march4 Phase A: the dispatcher emits into a FRAGMENT (the god-fn VISITORS);
        # stmt_bytes = its serialization — byte-identical while the byte tail migrates
        # to _sf's tracked state cluster-by-cluster (dev/MARCH4_STATEMENT_PLAN.md).
        local _sf = _ctx_builder(ctx, "compile_statement.frag")
        set_context!(_sf, first(string(stmt), 80))   # march17: errors name the stmt
        # march17: statements legitimately consume values earlier statements left on
        # the wasm stack (the stackified model) — seed the fragment with the parent's
        # TRACKED stack so pops resolve; append_builder! settles the contract exactly.
        isempty(b.v.stack) || seed_input!(_sf, copy(b.v.stack))
        _seed_builder_locals!(_sf, ctx)
        stmt_bytes = UInt8[]
        ctx.last_stmt_was_stub = false  # PURE-908: reset before dispatch
        if stmt.head === :call
            compile_call!(_sf, stmt, idx, ctx)
            stmt_bytes = builder_code(_sf)
            if haskey(ENV, "WT_TRACE_MM") && !isempty(stmt_bytes) && stmt_bytes[1] == Opcode.UNREACHABLE
                println(stderr, "UNREACH idx=$idx stmt=", repr(stmt)[1:min(end,110)])
            end
        elseif stmt.head === :invoke
            compile_invoke!(_sf, stmt, idx, ctx)
            stmt_bytes = builder_code(_sf)
        elseif stmt.head === :new
            # Struct construction: %new(Type, args...)
            compile_new!(_sf, stmt, idx, ctx)
            stmt_bytes = builder_code(_sf)
        elseif stmt.head === :boundscheck
            # P2-batch6: compile to the expr's REAL value (true unless @inbounds).
            # We previously pushed false ("wasm has its own bounds checking"), but
            # wasm's array.get check is an UNCATCHABLE TRAP — skipping Julia's own
            # check branch meant getindex OOB could never reach the catchable
            # throw_boundserror path (gap 3ead683e6ff9 family / divergent_throw).
            i32_const!(_sf, (isempty(stmt.args) || stmt.args[1] !== false) ? 1 : 0)
            stmt_bytes = builder_code(_sf)
        elseif stmt.head === :foreigncall
            # Handle foreign calls - specifically for Vector allocation
            compile_foreigncall!(_sf, stmt, idx, ctx)
            stmt_bytes = builder_code(_sf)
        elseif stmt.head === :the_exception
            # PURE-9032: Retrieve the caught exception value from the $current_exn global.
            # Julia IR emits :the_exception in catch blocks to get the caught exception.
            # We stash exception values into a (mut anyref) global before throw,
            # and retrieve them here with global.get.
            # march15: read the ENCLOSING region's payload local (dart's named catch
            # local); the global remains the fallback for reads outside any known region.
            local _exn_src_local = nothing
            for (_enter, _loc) in ctx.exn_region_locals
                # the innermost region whose enter precedes this read wins
                if _enter < idx && (_exn_src_local === nothing || _enter > _exn_src_local[1])
                    _exn_src_local = (_enter, _loc)
                end
            end
            if _exn_src_local !== nothing
                local_get!(_sf, UInt32(_exn_src_local[2]))
            else
                exn_global = ensure_exception_global!(ctx.mod)
                global_get!(_sf, exn_global, AnyRef)
            end
            # The global is anyref but the SSA local may be structref (for Union{ErrorException, BoundsError}).
            # Downcast anyref → structref so the local.set is type-valid.
            local _exn_local_wasm = nothing
            if haskey(ctx.ssa_locals, idx)
                local _exn_local_idx = ctx.ssa_locals[idx]
                local _exn_arr_idx = _exn_local_idx - ctx.n_params + 1
                if _exn_arr_idx >= 1 && _exn_arr_idx <= length(ctx.locals)
                    _exn_local_wasm = ctx.locals[_exn_arr_idx]
                end
            end
            if _exn_local_wasm === StructRef
                # anyref → structref (the SSA local may be structref for exception unions)
                ref_cast!(_sf, StructRef, true)
            elseif _exn_local_wasm isa ConcreteRef
                ref_cast!(_sf, Int64(_exn_local_wasm.type_idx), true)
            end
            stmt_bytes = builder_code(_sf)
        elseif stmt.head === :leave
            # Exception handling: Leave try block — no-op in WASM
            # (try_table control flow handles this structurally)
        elseif stmt.head === :pop_exception
            # Exception handling: Pop exception from handler stack — no-op in WASM
        elseif stmt.head === :gc_preserve_begin
            # PURE-9066: GC preservation — no-op in WasmGC (browser GC handles this)
        elseif stmt.head === :gc_preserve_end
            # PURE-9066: GC preservation end — no-op in WasmGC
        elseif stmt.head === :loopinfo
            # PURE-9066: Loop optimization hint (e.g., @simd) — no-op in Wasm
        end

        # The fragment's tracked stack is the only store contract. Merge it
        # unchanged; the typed local.set below validates/coerces the real top.
        # Underflow or orphaned values remain builder errors—nothing is truncated,
        # dropped, or replaced by a zero/null.
        _stmt_ends_unreachable = ctx.last_stmt_was_stub
        # A definition that is only a tuple of local reads is a recomputable
        # stackified value. When it has no materialized SSA local, its consumer
        # emits those reads; emitting them here as well would leave duplicate
        # operands at the block boundary. This is DCE of a pure definition, not
        # a value repair.
        pure_recomputed_tuple = !haskey(ctx.ssa_locals, idx) &&
            length(_sf.instrs) >= 2 && all(i -> i isa InstrIR.LocalGet, _sf.instrs)
        # MemoryRef is a virtual two-operand value `(memory, offset)`. Its
        # definition has no runtime effect and its consumer re-emits both
        # operands, so materializing the definition would duplicate the pair.
        pure_virtual_memoryref = !haskey(ctx.ssa_locals, idx) && stmt.head === :call &&
            !isempty(stmt.args) && stmt.args[1] isa GlobalRef &&
            stmt.args[1].name === :memoryrefnew
        (pure_recomputed_tuple || pure_virtual_memoryref) || append_builder!(b, _sf)

        # If the statement type is Union{} (bottom/never returns), emit unreachable
        # This handles calls to error/throw functions that have void return type in wasm
        # The unreachable instruction is polymorphic and satisfies any type expectation
        stmt_type_check = get(ctx.ssa_types, idx, Any)
        if stmt_type_check === Union{} && !isempty(stmt_bytes) &&
           !(!isempty(_sf.instrs) && _sf.instrs[end] isa InstrIR.Unreachable)
            local _urb = _ctx_builder(ctx, "compile_statement")
            unreachable!(_urb)  # structural trap (dart-legit dead path)
            append_builder!(b, _urb)
        end

        # If this SSA value needs a local, store it (and remove from stack)
        if haskey(ctx.ssa_locals, idx)
            stmt_type = get(ctx.ssa_types, idx, Any)
            is_unreachable_type = stmt_type === Union{}
            # march4 Phase B: DROP+UNREACHABLE tail is two node-kind tests — the
            # PURE-6005 false-positive class (struct_get operand bytes 0x1a 0x00)
            # cannot exist at the ir/ layer, so its GC-in-tail guard is gone too.
            is_unreachable_bytecode = (length(_sf.instrs) >= 2 &&
                                       _sf.instrs[end] isa InstrIR.Unreachable &&
                                       _sf.instrs[end-1] isa InstrIR.Drop) ||
                                      _stmt_ends_unreachable  # PURE-908: catch stub UNREACHABLE
            is_unreachable = is_unreachable_type || is_unreachable_bytecode
            should_store = (!isempty(stmt_bytes) || is_passthrough_statement(stmt, ctx)) && !is_unreachable
            if should_store
                local_idx = ctx.ssa_locals[idx]
                local_array_idx = local_idx - ctx.n_params + 1
                local_type = local_array_idx >= 1 && local_array_idx <= length(ctx.locals) ? ctx.locals[local_array_idx] : nothing


                # The emitted type is authoritative. Dynamic calls deliberately use
                # erased signatures, so Julia's static SSA type can differ from the
                # physical value on the wasm stack. Route every store adjustment through
                # the single coercion funnel; never drop and fabricate a default.
                if local_type !== nothing && !isempty(b.v.stack)
                    coerce_stack_top!(b, local_type, ctx; from_julia=stmt_type)
                end

                # PURE-6024: If this is a slot assignment, TEE to slot local first
                # (leaves value on stack for the SSA local.set below).
                # march17: DIRECT — the fresh store wrapper pop_any'd an empty stack
                # on EVERY SSA store (the single largest harvest class).
                if _slot_assign_id > 0 && haskey(ctx.slot_locals, _slot_assign_id)
                    local_tee!(b, ctx.slot_locals[_slot_assign_id])
                end
                local_set!(b, local_idx)
            end
        end
    end

    # PURE-6024: If this is a slot assignment but there's NO SSA local to store to,
    # the value is still on the stack — store it to the slot local directly. Typed.
    if _slot_assign_id > 0 && haskey(ctx.slot_locals, _slot_assign_id) && !haskey(ctx.ssa_locals, idx)
        local_set!(b, ctx.slot_locals[_slot_assign_id])   # march17: direct
    end

    # TRACE: Find double-DROP in compiled output for func 8 (node count — no byte scan)
    if ctx.func_idx == 8
        local n_drops = count(i -> i isa InstrIR.Drop, b.instrs)
        if n_drops >= 2
            stmt_str = stmt isa Expr ? string(stmt)[1:min(80, length(string(stmt)))] : string(typeof(stmt))
            @debug "STMT $idx has $n_drops DROPs: $stmt_str"
        end
    end

    return b
end

"""
Compile a struct construction expression (%new).
"""
# P2-batch17: type-correct default for an exception field whose value can't be
# represented (see the Exception branch of compile_new).
function _references_argument(@nospecialize(x), n::Int)::Bool
    x == Core.Argument(n) && return true
    if x isa Expr
        return any(a -> _references_argument(a, n), x.args)
    elseif x isa Core.ReturnNode
        return isdefined(x, :val) && _references_argument(x.val, n)
    elseif x isa Core.GotoIfNot
        return _references_argument(x.cond, n)
    elseif x isa Core.PiNode
        return _references_argument(x.val, n)
    elseif x isa Core.PhiNode
        return any(v -> isassigned(x.values, v) && _references_argument(x.values[v], n),
                   eachindex(x.values))
    end
    return false
end

function _setfield_of_value(@nospecialize(stmt), @nospecialize(subject), T::DataType)
    stmt isa Expr && stmt.head in (:call, :invoke) || return nothing
    first_arg = stmt.head === :invoke ? 2 : 1
    length(stmt.args) >= first_arg + 3 || return nothing
    callee = stmt.args[first_arg]
    is_func(callee, :setfield!) || return nothing
    stmt.args[first_arg + 1] == subject || return nothing
    field = stmt.args[first_arg + 2]
    field isa QuoteNode && (field = field.value)
    field isa Symbol || return nothing
    return findfirst(==(field), fieldnames(T))
end

_references_subject(@nospecialize(stmt), subject::Core.SSAValue) = references_ssa(stmt, subject.id)
_references_subject(@nospecialize(stmt), subject::Core.Argument) =
    _references_argument(stmt, subject.n)

function _definitely_initializes_in_ir(code, start_pc::Int, subject,
                                       T::DataType, missing::Set{Int})::Bool
    1 <= start_pc <= length(code) || return false
    incoming = Dict{Int,Set{Int}}(start_pc => Set{Int}())
    queue = Int[start_pc]
    while !isempty(queue)
        pc = popfirst!(queue)
        assigned = copy(incoming[pc])
        stmt = code[pc]
        written = _setfield_of_value(stmt, subject, T)
        if written !== nothing && written in missing
            push!(assigned, written)
        elseif _references_subject(stmt, subject) && !issubset(missing, assigned)
            return false
        end

        successors = if stmt isa Core.ReturnNode ||
                        (stmt isa Expr && stmt.head === :unreachable)
            Int[]
        elseif stmt isa Core.GotoNode
            Int[stmt.label]
        elseif stmt isa Core.GotoIfNot
            pc < length(code) ? Int[pc + 1, stmt.dest] : Int[stmt.dest]
        elseif pc < length(code)
            Int[pc + 1]
        else
            Int[]
        end
        for dest in successors
            start_pc <= dest <= length(code) || return false
            next_state = haskey(incoming, dest) ? intersect(incoming[dest], assigned) : copy(assigned)
            if !haskey(incoming, dest) || next_state != incoming[dest]
                incoming[dest] = next_state
                push!(queue, dest)
            end
        end
    end
    return true
end

function _cached_invoke_ir(use::Expr)
    use.head === :invoke || return nothing
    length(use.args) >= 2 || return nothing
    mi = use.args[1]
    mi isa Core.CodeInstance && (mi = mi.def)
    mi isa Core.MethodInstance || return nothing
    fref = use.args[2]
    f = fref isa GlobalRef && isdefined(fref.mod, fref.name) ?
        getfield(fref.mod, fref.name) : fref
    f isa Function || return nothing
    sig = mi.specTypes
    sig isa DataType && sig <: Tuple || return nothing
    arg_types = Tuple(sig.parameters[2:end])
    cache = TRIM_IR_CACHE[]
    cache === nothing && return nothing
    for (key, value) in cache
        key isa Tuple && length(key) == 2 || continue
        key[1] === f && key[2] == arg_types && return value[1]
    end
    return nothing
end

"""Prove that every missing primitive field is assigned before the object is observed.

The proof is deliberately interprocedural but closed-world: the fresh allocation must
have exactly one caller use, as one argument of an explicit invoke whose collected IR
is available. A forward must-analysis follows every CFG edge. Reads, calls, returns,
or escapes of the object are accepted only after all missing fields are definitely set;
throwing/unreachable paths may terminate before initialization.
"""
function _partial_new_is_definitely_initialized(idx::Int, T::DataType,
                                                 missing::Set{Int},
                                                 ctx::AbstractCompilationContext)::Bool
    ismutabletype(T) || return false
    caller_code = ctx.code_info.code
    idx < length(caller_code) &&
        _definitely_initializes_in_ir(caller_code, idx + 1, Core.SSAValue(idx), T, missing) &&
        return true
    uses = Tuple{Expr,Int}[]
    for stmt in caller_code
        references_ssa(stmt, idx) || continue
        stmt isa Expr && stmt.head === :invoke || return false
        operands = stmt.args[3:end]
        positions = findall(==(Core.SSAValue(idx)), operands)
        length(positions) == 1 || return false
        push!(uses, (stmt, positions[1]))
    end
    length(uses) == 1 || return false
    use, explicit_pos = only(uses)
    callee_ir = _cached_invoke_ir(use)
    callee_ir isa Core.CodeInfo || return false
    arg_n = explicit_pos + 1 # Core.Argument(1) is the callable/self slot
    return _definitely_initializes_in_ir(
        callee_ir.code, 1, Core.Argument(arg_n), T, missing)
end

"""dart visitConstructorInvocation shape (march4): emits the struct construction
INTO the caller's builder and returns it — THE implementation."""
function compile_new!(b::InstrBuilder, expr::Expr, idx::Int, ctx::AbstractCompilationContext)

    # expr.args[1] is the type, rest are field values
    struct_type_ref = expr.args[1]
    field_values = expr.args[2:end]




    # Resolve the struct type if it's a GlobalRef, DataType, or SSAValue
    struct_type = if struct_type_ref isa GlobalRef
        getfield(struct_type_ref.mod, struct_type_ref.name)
    elseif struct_type_ref isa DataType
        struct_type_ref
    elseif struct_type_ref isa Core.SSAValue
        # PURE-801: Handle Core.apply_type results (e.g., NamedTuple from keyword args)
        # ssavaluetypes[ssa.id] gives Type{ConcreteType} — extract the parameter
        ssa_type = ctx.code_info.ssavaluetypes[struct_type_ref.id]
        if ssa_type isa DataType && ssa_type <: Type && length(ssa_type.parameters) >= 1
            ssa_type.parameters[1]
        else
            # :new of a struct whose type isn't statically known (dynamic SSAValue type) —
            # type instability. Loud reject (constructs an object natively).
            emit_unsupported_stub!(ctx, b, :unsupported_type,
                "struct construction (:new) with a non-constant type — type instability"; idx=idx,
                detail=ssa_type)
            return b
        end
    elseif struct_type_ref isa Core.Argument
        # Constructor bodies reference the constructed type as Core.Argument(1)
        # (#self# = Type{T}): TickLabel(...)'s IR is `%new(_1, fields...)`.
        # The :new statement's own inferred SSA type IS the constructed type
        # (E-003: TickLabel and SubString constructor deps failed here).
        local new_ssa_type = ctx.code_info.ssavaluetypes[idx]
        if new_ssa_type isa DataType && isconcretetype(new_ssa_type) && isstructtype(new_ssa_type)
            new_ssa_type
        else
            # :new where the constructed type (Core.Argument #self#) can't be resolved to a
            # concrete struct — type instability. Loud reject.
            emit_unsupported_stub!(ctx, b, :unsupported_type,
                "struct construction (:new) with an unresolvable type — type instability"; idx=idx,
                detail=new_ssa_type)
            return b
        end
    else
        error("Unknown struct type reference: $struct_type_ref")
    end

    # P6-trim: CodeUnits{UInt8,String} is an identity wrapper over the byte
    # array (same representation contract as Memory) — %new(CodeUnits, s)
    # compiles to s itself. Trim-collected string internals construct these.
    if struct_type isa DataType && struct_type.name.name === :CodeUnits &&
       length(struct_type.parameters) >= 1 && struct_type.parameters[1] === UInt8 &&
       length(field_values) >= 1
        emit_value!(b, field_values[1], ctx,
                    ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))
        return b
    end

    # Special case: Dict{K,V} construction
    # Dict starts with empty Memory arrays (length 0), but our inline setindex!/getindex
    # use linear scan and need initial capacity. Replace empty arrays with capacity-16 arrays.
    # NOTE: Only match concrete Dict types, not AbstractDict (Base.Pairs <: AbstractDict but has 2 fields)
    if struct_type <: Dict
        K = keytype(struct_type)
        V = valtype(struct_type)

        if !haskey(ctx.type_registry.structs, struct_type)
            register_struct_type!(ctx.mod, ctx.type_registry, struct_type)
        end
        dict_info = ctx.type_registry.structs[struct_type]

        slots_arr_type = get_array_type!(ctx.mod, ctx.type_registry, UInt8)
        keys_arr_type = get_array_type!(ctx.mod, ctx.type_registry, K)
        vals_arr_type = get_array_type!(ctx.mod, ctx.type_registry, V)

        # Initial capacity of 16
        initial_cap = Int32(16)

        emit_struct_prefix!(b, ctx.type_registry, struct_type, dict_info)

        # field 1: slots - array of UInt8, initialized to 0 (empty)
        i32_const!(b, initial_cap)
        array_new_default!(b, slots_arr_type)

        # field 2: keys - array of K, default initialized
        i32_const!(b, initial_cap)
        array_new_default!(b, keys_arr_type)

        # field 3: vals - array of V, default initialized
        i32_const!(b, initial_cap)
        array_new_default!(b, vals_arr_type)

        # field 4: ndel = 0 (i64)
        i64_const!(b, 0)

        # field 5: count = 0 (i64)
        i64_const!(b, 0)

        # field 6: age = 0 (u64, stored as i64)
        i64_const!(b, 0)

        # field 7: idxfloor = 1 (i64)
        i64_const!(b, 1)

        # field 8: maxprobe = 0 (i64)
        i64_const!(b, 0)

        # struct.new
        struct_new!(b, dict_info.wasm_type_idx)   # mod-resolved fields (march3)

        return b
    end

    # Special case: Vector{T} construction
    # Vector is now a struct with (ref, size) fields to support setfield!(v, :size, ...)
    # The %new(Vector{T}, memref, size_tuple) creates a struct with both fields
    if struct_type <: Array && length(field_values) >= 1
        # field_values[1] is the MemoryRef (which is actually our array)
        # field_values[2] is the size tuple (Tuple{Int64})
        # Register the vector type if not already done
        if !haskey(ctx.type_registry.structs, struct_type)
            register_vector_type!(ctx.mod, ctx.type_registry, struct_type)
        end
        vec_info = ctx.type_registry.structs[struct_type]

        emit_struct_prefix!(b, ctx.type_registry, struct_type, vec_info)

        # Compile field 1: the array reference (from MemoryRef)
        # Safety: if the SSA local is numeric (i64/i32) but the Vector struct expects a ref,
        # emit ref.null of the correct array type instead of the wrong-typed local.get.
        # This happens with non-Array AbstractVector types (UnitRange, StepRange) whose
        # fields are i64 but get registered with Vector's ref-based layout.
        # PURE-325: Check if field0 is a multi-arg memoryrefnew that produces [array_ref, i32_index].
        # Vector only needs the array_ref — drop the extra i32 index.
        is_multi_arg_memref = false
        if field_values[1] isa Core.SSAValue
            src_stmt = ctx.code_info.code[field_values[1].id]
            if src_stmt isa Expr && src_stmt.head === :call
                src_func = src_stmt.args[1]
                is_multi_arg_memref = (src_func isa GlobalRef &&
                                      (src_func.mod === Core || src_func.mod === Base) &&
                                      src_func.name === :memoryrefnew &&
                                      length(src_stmt.args) >= 4)
            end
        end
        # march3 (typed): the LOCAL_GET LEB decode is gone — the tracked type
        # answers "is the source numeric where field 0 needs an array ref".
        local _f0_b = _compile_value_b(field_values[1], ctx)
        if is_multi_arg_memref
            # Multi-arg memoryrefnew pushed [array_ref, i32_index] — drop the i32 index
            drop!(_f0_b)
        end
        local _f0_ty = isempty(_f0_b.v.stack) ? nothing : _f0_b.v.stack[end]
        if _f0_ty === I64 || _f0_ty === I32
            # PURE-325: numeric source but Vector field 0 needs an array ref.
            # Before falling back to ref.null, check if the source SSA is a memoryrefnew
            # or memorynew result — if so, recompile the source to get the actual array ref.
            recompiled = false
            if field_values[1] isa Core.SSAValue
                src_stmt_f0 = ctx.code_info.code[field_values[1].id]
                if src_stmt_f0 isa Expr && src_stmt_f0.head === :call
                    sf0 = src_stmt_f0.args[1]
                    is_memref = sf0 isa GlobalRef &&
                                (sf0.mod === Core || sf0.mod === Base) &&
                                sf0.name in (:memoryrefnew, :memoryref, :memorynew)
                    if is_memref
                        # Recompile the source statement to get the actual array ref
                        compile_call!(b, src_stmt_f0, field_values[1].id, ctx)   # dart visitor
                        recompiled = true
                    end
                end
                # Also check if source is a PiNode wrapping a memoryrefnew
                if !recompiled && src_stmt_f0 isa Core.PiNode
                    emit_value!(b, src_stmt_f0.val, ctx,
                                static_wasm_type(src_stmt_f0.val, ctx))
                    recompiled = true
                end
            end
            if !recompiled
                emit_unsupported_stub!(ctx, b, :unsupported_type,
                    "vector construction requires a concrete backing array; refusing to substitute null";
                    idx=idx, detail=field_values[1])
                return b
            end
        else
            append_builder!(b, _f0_b)   # typed merge
        end

        # Compile field 2: the size tuple (field 0=typeId, field 1=array_ref, field 2=size_tuple)
        if length(field_values) >= 2
            # Julia's Vector lowering may expose its scalar length where the Wasm
            # representation stores Tuple{Int64}. Build that exact tuple; never
            # discard the length and substitute a nullable reference.
            local _f1_b = _compile_value_b(field_values[2], ctx)
            local _f1_ty = isempty(_f1_b.v.stack) ? nothing : _f1_b.v.stack[end]
            if _f1_ty === I64 || _f1_ty === I32
                size_tuple_type_inner = Tuple{Int64}
                if !haskey(ctx.type_registry.structs, size_tuple_type_inner)
                    register_tuple_type!(ctx.mod, ctx.type_registry, size_tuple_type_inner)
                end
                size_info_inner = ctx.type_registry.structs[size_tuple_type_inner]
                emit_struct_prefix!(b, ctx.type_registry, size_tuple_type_inner, size_info_inner)
                append_builder!(b, _f1_b)
                coerce_stack_top!(b, I64, ctx;
                    from_julia=_value_julia_type(field_values[2], ctx))
                struct_new!(b, size_info_inner.wasm_type_idx)
            else
                append_builder!(b, _f1_b)   # typed merge
            end
        else
            # No size provided - get array length and create tuple
            # Create Tuple{Int64} struct (typeId + i64 value)
            size_tuple_type = Tuple{Int64}
            if !haskey(ctx.type_registry.structs, size_tuple_type)
                register_tuple_type!(ctx.mod, ctx.type_registry, size_tuple_type)
            end
            size_info = ctx.type_registry.structs[size_tuple_type]
            # M3: real classId for the size tuple header
            emit_struct_prefix!(b, ctx.type_registry, size_tuple_type, size_info)
            # Push array ref again for array.len
            emit_value!(b, field_values[1], ctx,
                        static_wasm_type(field_values[1], ctx))
            array_len!(b)
            num!(b, Opcode.I64_EXTEND_I32_S)
            struct_new!(b, size_info.wasm_type_idx)   # mod-resolved fields (march3)
        end

        # Create the Vector struct (already has typeId from above)
        struct_new!(b, vec_info.wasm_type_idx)   # mod-resolved fields (march3)
        return b
    end

    # PURE-049: MemoryRef/Memory construction — in WasmGC these are array refs, not structs.
    # :new(MemoryRef{T}, mem, ptr_or_offset) → just pass through the mem (array ref).
    # :new(Memory{T}, ...) → emit ref.null of the array type (Memory is backing storage).
    if struct_type isa DataType && struct_type.name.name in (:MemoryRef, :GenericMemoryRef)
        # MemoryRef{T} — field_values[1] is the Memory (= our array ref), field_values[2] is offset
        if length(field_values) >= 1
            emit_value!(b, field_values[1], ctx,
                        static_wasm_type(field_values[1], ctx))
        else
            elem_type = struct_type.name.name === :GenericMemoryRef ? struct_type.parameters[2] : struct_type.parameters[1]
            array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
            ref_null!(b, Int64(array_type_idx), ConcreteRef(UInt32(array_type_idx), true))
        end
        return b
    end
    if struct_type isa DataType && struct_type.name.name in (:Memory, :GenericMemory)
        # Memory{T} — emit ref.null of the array type (we can't construct raw memory in Wasm)
        elem_type = eltype(struct_type)
        array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
        ref_null!(b, Int64(array_type_idx), ConcreteRef(UInt32(array_type_idx), true))
        return b
    end

    # Get the registered struct info
    if !haskey(ctx.type_registry.structs, struct_type)
        # Register it now - use appropriate registration for closures vs regular structs
        if is_closure_type(struct_type)
            register_closure_type!(ctx.mod, ctx.type_registry, struct_type)
        else
            register_struct_type!(ctx.mod, ctx.type_registry, struct_type)
        end
    end

    info = ctx.type_registry.structs[struct_type]

    # PURE-9024/9025: Push typeId (i32) as field 0 before Julia field values
    emit_struct_prefix!(b, ctx.type_registry, struct_type, info)

    # Push field values in order, handling Union field types
    for (i, val) in enumerate(field_values)
        field_type = info.field_types[i]

        # (M3: the tagged-union wrapper arm is DELETED — needs_tagged_union was ≡ false;
        # a union field is AnyRef holding the classId box / struct ref directly.)
        if field_type isa Union
            # Simple nullable union (Union{Nothing, T})
            inner_type = get_nullable_inner_type(field_type)

            # Get the value's actual type
            val_type = if val isa Core.SSAValue
                get(ctx.ssa_types, val.id, Any)
            elseif val isa GlobalRef
                actual_val = try getfield(val.mod, val.name) catch; nothing end
                typeof(actual_val)
            else
                typeof(val)
            end

            # Check if this value is nothing - either literally or via an SSA with Nothing type
            # SSA values with Nothing type (e.g., from GlobalRef to nothing) produce no bytecode,
            # so we need to emit ref.null directly instead of trying to load a non-existent value
            is_literal_nothing = val === nothing || (val isa GlobalRef && val.name === :nothing)
            is_nothing_type_ssa = val isa Core.SSAValue && val_type === Nothing
            should_emit_null = is_literal_nothing || is_nothing_type_ssa

            if should_emit_null
                # PURE-6024: Check actual Wasm field type first. For nullable
                # primitives (Union{Nothing, Bool/Int32/etc}), the Wasm field
                # is i32/i64 — emit zero constant, NOT ref.null.
                _null_field_wasm = nothing
                _null_struct_def = ctx.mod.types[info.wasm_type_idx + 1]
                local _wasm_fi = i + Int(info.field_offset)  # PURE-9024: skip typeId
                if _null_struct_def isa StructType && _wasm_fi <= length(_null_struct_def.fields)
                    _null_field_wasm = _null_struct_def.fields[_wasm_fi].valtype
                end
                if _null_field_wasm !== nothing && (_null_field_wasm === I32 || _null_field_wasm === I64 || _null_field_wasm === F32 || _null_field_wasm === F64)
                    # Numeric field — emit zero constant for nothing
                    if _null_field_wasm === I32
                        i32_const!(b, 0)
                    elseif _null_field_wasm === I64
                        i64_const!(b, 0)
                    elseif _null_field_wasm === F32
                        f32_const!(b, 0.0f0)
                    elseif _null_field_wasm === F64
                        f64_const!(b, 0.0)
                    end
                # Nothing value (literal or SSA with Nothing type) - emit ref.null
                elseif inner_type !== nothing && (inner_type === String || inner_type === Symbol)
                    # Nullable string/symbol — use string array type
                    str_type_idx = get_string_struct_type!(ctx.mod, ctx.type_registry)
                    ref_null!(b, Int64(str_type_idx), ConcreteRef(UInt32(str_type_idx), true))
                elseif inner_type !== nothing && isconcretetype(inner_type) && isstructtype(inner_type)
                    # Nullable struct ref - emit null reference
                    if haskey(ctx.type_registry.structs, inner_type)
                        inner_info = ctx.type_registry.structs[inner_type]
                        ref_null!(b, Int64(inner_info.wasm_type_idx), ConcreteRef(UInt32(inner_info.wasm_type_idx), true))
                    else
                        # Use generic null
                        ref_null!(b, StructRef)
                    end
                elseif inner_type !== nothing && inner_type <: AbstractVector
                    # Nullable array ref
                    elem_type = eltype(inner_type)
                    arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
                    ref_null!(b, Int64(arr_type_idx), ConcreteRef(UInt32(arr_type_idx), true))
                else
                    # Generic nullable - use structref null
                    ref_null!(b, StructRef)
                end
            else
                # The registered physical field is the sole sink contract. Route
                # every non-null value through the same exact conversion funnel as
                # calls, returns, tuple fields, and SSA stores. Numeric union members
                # are boxed with their proven Julia class ID; an unprovable conversion
                # rejects instead of fabricating a validating null.
                local _cn_struct_def = ctx.mod.types[info.wasm_type_idx + 1]
                local _cn_wasm_fi = i + Int(info.field_offset)
                (_cn_struct_def isa StructType &&
                 _cn_wasm_fi <= length(_cn_struct_def.fields)) ||
                    error("registered union field $i has no physical Wasm type")
                local _cn_expected = _cn_struct_def.fields[_cn_wasm_fi].valtype
                local _cn_julia = _value_julia_type(val, ctx)
                emit_value!(b, val, ctx, _cn_expected;
                    from_julia=(_cn_julia isa Type ? _cn_julia : nothing))
            end
        elseif field_type === Any
            # PURE-9064: Determine actual Wasm field type (AnyRef when JlType hierarchy active,
            # ExternRef otherwise). Look it up from the module type definition.
            local _cn_wasm_fi = i + Int(info.field_offset)  # i is 1-based, +offset for typeId
            local _cn_struct_def = ctx.mod.types[info.wasm_type_idx + 1]
            local _cn_field_is_anyref = _cn_struct_def isa StructType &&
                _cn_wasm_fi <= length(_cn_struct_def.fields) &&
                _cn_struct_def.fields[_cn_wasm_fi].valtype === AnyRef

            # PURE-044: Check for nothing values FIRST before compile_value
            # compile_value(nothing) returns i32.const 0, which can't be converted
            is_nothing_val = val === nothing ||
                            (val isa GlobalRef && val.name === :nothing) ||
                            (val isa Core.SSAValue && 1 <= val.id <= length(ctx.code_info.code) && begin
                                ssa_stmt_check = ctx.code_info.code[val.id]
                                (ssa_stmt_check isa GlobalRef && ssa_stmt_check.name === :nothing) ||
                                (ssa_stmt_check isa Core.PiNode && ssa_stmt_check.typ === Nothing)
                            end)
            if is_nothing_val
                if _cn_field_is_anyref
                    ref_null!(b, AnyRef)  # any heap type
                else
                    ref_null!(b, ExternRef)
                end
                continue  # Skip to next field
            end

            if _cn_field_is_anyref
                # Field is anyref — concrete/struct refs are subtypes of anyref.
                # No extern.convert_any needed. Numerics need boxing.
                val_julia_type = if val isa Core.SSAValue
                    get(ctx.ssa_types, val.id, Any)
                elseif val isa Core.Argument
                    local _arg_i = ctx.is_compiled_closure ? val.n : val.n - 1
                    (_arg_i >= 1 && _arg_i <= length(ctx.arg_types)) ? ctx.arg_types[_arg_i] : Any
                else
                    typeof(val)
                end
                val_wasm_type = julia_to_wasm_type(val_julia_type)
                if val_wasm_type === I32 || val_wasm_type === I64 || val_wasm_type === F32 || val_wasm_type === F64
                    emit_numeric_to_anyref!(b, val, val_wasm_type, ctx)
                else
                    emit_value!(b, val, ctx, AnyRef;
                                from_julia=(val_julia_type isa Type && isconcretetype(val_julia_type)) ? val_julia_type : nothing)
                    if val_wasm_type === ExternRef
                        any_convert_extern!(b)
                    end
                end
            else
                # Legacy ExternRef path — THE wrap chokepoint: emit typed, coerce to externref
                # through the ONE funnel (numeric → classId box → extern_convert_any; GC ref →
                # extern_convert_any; already-externref → no-op). Replaces 50 lines of
                # first-byte scans (0x41/0x42 const, 0x20 local.get + LEB decode) + 3
                # infer_value_wasm_type re-guesses + a ref.null-extern SILENT VALUE DROP for
                # numerics (now boxed properly — dart convertType) + a latent double
                # extern-convert on compound externref expressions.
                emit_value!(b, val, ctx, ExternRef)
            end
        else
            # The registered physical field type is the sole sink contract.
            # Emit the real value and pass through the same wrap/convertType
            # chokepoint used by calls and SSA stores; no null/zero repairs.
            struct_type_def = ctx.mod.types[info.wasm_type_idx + 1]
            wasm_field = i + Int(info.field_offset)
            (struct_type_def isa StructType && wasm_field <= length(struct_type_def.fields)) ||
                error("registered struct field $i has no physical Wasm type")
            expected = struct_type_def.fields[wasm_field].valtype
            julia_field = struct_type isa DataType && i <= fieldcount(struct_type) ?
                fieldtype(struct_type, i) : nothing
            emit_value!(b, val, ctx, expected;
                        from_julia=(julia_field isa Type ? julia_field : nothing))
        end
    end

    # WasmGC fields are always physically initialized, while Julia `%new` may leave
    # fields undefined. Primitive defaults are legal only under a closed-world
    # definite-initialization proof that makes the physical bits unobservable.
    struct_type_def = ctx.mod.types[info.wasm_type_idx + 1]
    if struct_type_def isa StructType
        n_provided = length(field_values)
        n_required = length(struct_type_def.fields)
        n_wasm_provided = n_provided + Int(info.field_offset)
        missing_julia = Set((n_provided + 1):fieldcount(struct_type))
        primitive_init_proven = isempty(missing_julia) ||
            _partial_new_is_definitely_initialized(idx, struct_type, missing_julia, ctx)
        for fi in (n_wasm_provided + 1):n_required
            missing_type = struct_type_def.fields[fi].valtype
            if missing_type isa ConcreteRef
                ref_null!(b, Int64(missing_type.type_idx), missing_type)
            elseif missing_type === StructRef || missing_type === ArrayRef ||
                   missing_type === ExternRef || missing_type === AnyRef || missing_type === EqRef
                # Null is the explicit Wasm representation of Julia's undefined
                # reference slot; isdefined/getfield already interpret that sentinel.
                ref_null!(b, missing_type)
            elseif primitive_init_proven && missing_type === I32
                i32_const!(b, 0)
            elseif primitive_init_proven && missing_type === I64
                i64_const!(b, 0)
            elseif primitive_init_proven && missing_type === F32
                f32_const!(b, 0.0)
            elseif primitive_init_proven && missing_type === F64
                f64_const!(b, 0.0)
            else
                record_unsupported!(ctx, :value_stub,
                    "struct construction leaves a non-reference Julia field undefined " *
                    "($struct_type: field=$fi, physical=$missing_type)";
                    idx=idx, detail=expr)
                unreachable!(b)  # structural trap after recorded unsupported
                ctx.last_stmt_was_stub = true
                return b
            end
        end
    end

    # struct.new type_idx
    struct_new!(b, info.wasm_type_idx)   # mod-resolved fields (march3)

    return b
end

"""
Compile a foreign call expression — dart visitor shape (march4): emits INTO the
caller's builder. Handles patterns like jl_alloc_genericmemory for Vector allocation.
"""
function compile_foreigncall!(b::InstrBuilder, expr::Expr, idx::Int, ctx::AbstractCompilationContext)

    # foreigncall format: Expr(:foreigncall, name, return_type, arg_types, nreq, calling_conv, args...)
    # For jl_alloc_genericmemory:
    #   args[1] = :(:jl_alloc_genericmemory)
    #   args[2] = return type (e.g., Ref{Memory{Int32}})
    #   args[7] = element type (e.g., Memory{Int32})
    #   args[8] = length

    if length(expr.args) >= 1
        name = extract_foreigncall_name(expr.args[1])

        if name === :jl_alloc_genericmemory
            # Extract element type from return type
            # args[2] is like Ref{Memory{Int32}}
            # args[7] is Memory{Int32}
            ret_type = length(expr.args) >= 2 ? expr.args[2] : nothing

            # Get the element type from Memory{T}
            # Memory{T} is actually GenericMemory{:not_atomic, T, ...}
            # The memory type is at args[6] (not args[7])
            elem_type = Int32  # default
            if length(expr.args) >= 6
                mem_type = expr.args[6]
                if mem_type isa DataType && mem_type.name.name === :GenericMemory && length(mem_type.parameters) >= 2
                    # GenericMemory parameters: (atomicity, element_type, addrspace)
                    elem_type = mem_type.parameters[2]
                elseif mem_type isa DataType && mem_type.name.name === :Memory && length(mem_type.parameters) >= 1
                    elem_type = mem_type.parameters[1]
                elseif mem_type isa GlobalRef
                    resolved = try getfield(mem_type.mod, mem_type.name) catch; nothing end
                    if resolved isa DataType && resolved.name.name === :GenericMemory && length(resolved.parameters) >= 2
                        elem_type = resolved.parameters[2]
                    elseif resolved isa DataType && resolved.name.name === :Memory && length(resolved.parameters) >= 1
                        elem_type = resolved.parameters[1]
                    end
                end
            end

            # Get the length argument (at args[7] or args[8])
            len_arg = length(expr.args) >= 7 ? expr.args[7] : nothing

            # Get or create array type for this element type
            arr_type_idx = if elem_type <: AbstractVector || (elem_type isa DataType && isstructtype(elem_type))
                # For struct element types, register the element struct first
                if isconcretetype(elem_type) && isstructtype(elem_type) && !haskey(ctx.type_registry.structs, elem_type)
                    register_struct_type!(ctx.mod, ctx.type_registry, elem_type)
                end
                get_array_type!(ctx.mod, ctx.type_registry, elem_type)
            elseif elem_type === String
                get_string_struct_type!(ctx.mod, ctx.type_registry)
            else
                get_array_type!(ctx.mod, ctx.type_registry, elem_type)
            end

            # Compile length argument
            if len_arg !== nothing
                len_type = infer_value_type(len_arg, ctx)
                emit_value!(b, len_arg, ctx, (len_type === Int64 || len_type === Int) ? I64 : I32)   # step4
                if len_type === Int64 || len_type === Int
                    num!(b, Opcode.I32_WRAP_I64)
                end
            else
                # Default length of 0
                i32_const!(b, 0)
            end

            # array.new_default creates array filled with default value (0 for primitives, null for refs)
            array_new_default!(b, arr_type_idx)

            return b
        elseif name === :memset
            # WBUILD-5501: memset(ptr, value, size) — fill memory with a byte value.
            # CORRECT BY DESIGN for zero-fill: WasmGC arrays are zero-initialized by
            # array.new_default, so memset(ptr, 0, size) is a no-op. All current callers
            # (Dict/Set constructor, rehash!) use value=0 (a literal 0x00).
            # SOUNDNESS: a *literal* non-zero fill would silently produce wrong results,
            # so we refuse it (foreigncall args: [name,rt,argtypes,nreq,cc, ptr, value, size]).
            if length(expr.args) >= 7 && (expr.args[7] isa Number) && !iszero(expr.args[7])
                record_unsupported!(ctx, :value_stub, "memset with a non-zero constant fill value"; idx=idx, detail=expr)
                unreachable!(b)  # structural trap after recorded unsupported
                ctx.last_stmt_was_stub = true
                return b
            end
            # Zero-fill no-op. memset returns the ptr, but only materialise it when
            # the result is actually stored (ssa_local exists). Unconditionally
            # pushing it orphaned a stub value on the stack: callers (Dict ctor,
            # rehash!) discard the result, and the builder stack delta remains zero.
            # Latent until a
            # reachable block `end` closed over the orphan (P2-batch23, gaps
            # 4be58371947f / 203da15d789c).
            if length(expr.args) >= 6 && haskey(ctx.ssa_locals, idx)
                emit_value!(b, expr.args[6], ctx,
                            static_wasm_type(expr.args[6], ctx))
            end
            return b
        elseif name === :jl_types_equal
            # jl_types_equal(T1, T2) → Int32. Base.Math's pow uses `T === Float16`
            # style checks that lower to this foreigncall. When both args are
            # compile-time type literals, fold to a constant (gap 01c21040d51f:
            # the unknown-foreigncall stub made every Float32^Float32 trap).
            _resolve_type_lit(a) = a isa GlobalRef ? (try getfield(a.mod, a.name) catch; nothing end) :
                                   a isa QuoteNode ? a.value : a
            if length(expr.args) >= 7
                t1 = _resolve_type_lit(expr.args[6])
                t2 = _resolve_type_lit(expr.args[7])
                if t1 isa Type && t2 isa Type
                    i32_const!(b, t1 === t2 ? 1 : 0)
                    return b
                end
            end
            # Non-literal args: fall through to the unknown-foreigncall stub below
        elseif name === :jl_object_id
            # dart2wasm Object identity: read the mutable identityHash slot and lazily
            # assign a non-zero module-local identity on first observation.
            local object_arg = length(expr.args) >= 6 ? expr.args[6] : nothing
            local object_type = object_arg === nothing ? nothing : get_ssa_type(ctx, object_arg)
            local object_idx = (object_type === String || object_type === Symbol) ?
                               get_string_struct_type!(ctx.mod, ctx.type_registry) :
                               object_type === Core.TypeName ? ctx.type_registry.jl_typename_idx :
                               (object_type !== nothing && haskey(ctx.type_registry.structs, object_type) &&
                                ctx.type_registry.structs[object_type].field_offset == 2 ?
                                ctx.type_registry.structs[object_type].wasm_type_idx : nothing)
            if object_idx !== nothing
                local object_ref = ConcreteRef(object_idx, false)
                local object_local = allocate_local!(ctx, object_ref)
                local hash_local = allocate_local!(ctx, I32)
                local counter = get_identity_counter_global!(ctx.mod, ctx.type_registry)

                emit_value!(b, object_arg, ctx, object_ref)
                local_set!(b, object_local)
                local_get!(b, object_local)
                struct_get!(b, object_idx, UInt32(1), I32)
                local_tee!(b, hash_local)
                num!(b, Opcode.I32_EQZ)
                if_!(b, I32)
                    # next = counter + 1; persist it globally and on the object.
                    global_get!(b, counter, I32)
                    i32_const!(b, 1)
                    num!(b, Opcode.I32_ADD)
                    local_tee!(b, hash_local)
                    global_set!(b, counter)
                    local_get!(b, object_local)
                    local_get!(b, hash_local)
                    struct_set!(b, object_idx, UInt32(1), I32)
                    local_get!(b, hash_local)
                else_!(b)
                    local_get!(b, hash_local)
                end_block!(b)
                extend_identity_hash_to_u64!(b)
                return b
            end
            record_unsupported!(ctx, :value_stub, "objectid / identity-hash (jl_object_id)"; idx=idx, detail=expr)
            unreachable!(b)  # structural trap after recorded unsupported
            ctx.last_stmt_was_stub = true
            return b
        elseif name === :jl_string_to_genericmemory
            # Convert String to Memory{UInt8}
            # In WasmGC, String and Memory{UInt8} both use the same byte array representation
            # So this is essentially just passing through the underlying array

            # The string argument is at args[6]
            if length(expr.args) >= 6
                str_arg = expr.args[6]
                # parity(M9): the classed string → its DATA array (the funnel adjusts)
                emit_value!(b, str_arg, ctx,
                            ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))
            end

            return b
        elseif name === :jl_alloc_string
            # PURE-317: jl_alloc_string(n::UInt64) -> String
            # Allocates a new String of n bytes. In WasmGC, String is array<i32>.
            # Create a zero-filled array of the requested size.
            str_arr_type = get_string_array_type!(ctx.mod, ctx.type_registry)
            if length(expr.args) >= 6
                size_arg = expr.args[6]
                size_type = infer_value_type(size_arg, ctx)
                emit_value!(b, size_arg, ctx, (size_type === Int64 || size_type === Int || size_type === UInt64) ? I64 : I32)   # step4
                if size_type === Int64 || size_type === Int || size_type === UInt64
                    num!(b, Opcode.I32_WRAP_I64)
                end
            else
                record_unsupported!(ctx, :value_stub,
                    "jl_alloc_string without its required length operand";
                    idx=idx, detail=expr, soundness_fatal=true)
            end
            array_new_default!(b, str_arr_type)
            emit_string_wrap!(b, ctx)   # parity(M9): a String is classed from birth
            return b
        elseif name === :jl_string_ptr || name === :jl_symbol_name
            # jl_string_ptr(s) -> Ptr{UInt8}: get pointer to string bytes
            # In WasmGC, String is array<i32>. We emit i64.const 1 as base pointer.
            # Base=1 avoids ambiguity with memchr returning 0 for "not found" vs
            # finding at position 0. The pointerref handler traces back to find the
            # original string arg, so the base value doesn't affect it.
            # The memchr handler uses base=1 arithmetic: array_index = ptr - 1.
            i64_const!(b, 1)
            return b
        elseif name === :strlen && length(expr.args) >= 6
            traced = _trace_string_ptr(expr.args[6], ctx.code_info.code)
            if traced !== nothing
                source, _ = traced
                str_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
                emit_value!(b, source, ctx, ConcreteRef(UInt32(str_idx), true))
                array_len!(b)
                julia_to_wasm_type(expr.args[2]) === I64 && widen_length_to_i64!(b)
                return b
            end
        elseif name in (:jl_is_operator, :jl_is_syntactic_operator) && length(expr.args) >= 6
            traced = _trace_string_ptr(expr.args[6], ctx.code_info.code)
            if traced !== nothing
                source, _ = traced
                bit = name === :jl_is_operator ? Int32(0x01) : Int32(0x02)
                literal = source isa QuoteNode ? source.value : source
                if literal isa Symbol || literal isa AbstractString
                    i32_const!(b, (symbol_syntax_flags(literal) & bit) == bit ? 1 : 0)
                    return b
                end
                if get_ssa_type(ctx, source) === Symbol
                    string_idx = get_string_struct_type!(ctx.mod, ctx.type_registry)
                    emit_value!(b, source, ctx, ConcreteRef(UInt32(string_idx), true))
                    struct_get!(b, string_idx, UInt32(3), I32)
                    local status_local = allocate_local!(ctx, I32)
                    local_tee!(b, status_local)
                    i32_const!(b, -1); num!(b, Opcode.I32_EQ)
                    if_!(b, I32)
                    unreachable!(b)  # structural trap: dynamically-created Symbol lacks operator metadata
                    else_!(b)
                    local_get!(b, status_local)
                    i32_const!(b, bit); num!(b, Opcode.I32_AND)
                    i32_const!(b, bit); num!(b, Opcode.I32_EQ)
                    end_block!(b)
                    return b
                end
            end
        elseif name === :jl_id_start_char
            length(expr.args) >= 6 || record_unsupported!(ctx, :value_stub,
                "jl_id_start_char missing codepoint"; idx=idx, detail=expr)
            emit_value!(b, expr.args[6], ctx, I32)
            prop_idx = get_or_create_unicode_property_func!(ctx.mod, ctx.type_registry)
            call!(b, prop_idx, WasmValType[I32], WasmValType[I32])
            i32_const!(b, 7); num!(b, Opcode.I32_SHR_U)
            i32_const!(b, 1); num!(b, Opcode.I32_AND)
            return b
        elseif name === :jl_id_char
            length(expr.args) >= 6 || record_unsupported!(ctx, :value_stub,
                "jl_id_char missing codepoint"; idx=idx, detail=expr)
            emit_value!(b, expr.args[6], ctx, I32)
            prop_idx = get_or_create_unicode_property_func!(ctx.mod, ctx.type_registry)
            call!(b, prop_idx, WasmValType[I32], WasmValType[I32])
            i32_const!(b, 8); num!(b, Opcode.I32_SHR_U)
            i32_const!(b, 1); num!(b, Opcode.I32_AND)
            return b
        elseif name === :jl_string_to_genericmemory
            # PURE-316: jl_string_to_genericmemory(s::String) -> Memory{UInt8}
            # Converts a String's underlying bytes to a Memory{UInt8}.
            # In WasmGC, both String and Memory{UInt8} are represented as array<i32>,
            # so this is a no-op: just return the string argument itself.
            # For ASCII/UTF-8 source code, the codepoint values equal the byte values.
            if length(expr.args) >= 6
                str_arg = expr.args[6]
                # parity(M9): the classed string → its DATA array (the funnel adjusts)
                emit_value!(b, str_arg, ctx,
                            ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))
            end
            return b
        elseif name === :jl_genericmemory_to_string
            # PURE-325: jl_genericmemory_to_string(memory, n) -> String
            # Creates a String of exactly n bytes from a Memory{UInt8}.
            # The underlying WasmGC array may have more capacity than n
            # (Julia allocates Memory with minimum size 16), so we must
            # create a new array of exactly n elements and copy.
            if length(expr.args) >= 7
                mem_arg = expr.args[6]
                len_arg = expr.args[7]
                str_arr_type = get_string_array_type!(ctx.mod, ctx.type_registry)

                # Allocate locals for dest array and length
                dest_local = length(ctx.locals) + ctx.n_params
                push!(ctx.locals, ConcreteRef(str_arr_type))
                len_local = length(ctx.locals) + ctx.n_params
                push!(ctx.locals, I32)

                # Compile n and convert to i32
                len_type = infer_value_type(len_arg, ctx)
                emit_value!(b, len_arg, ctx, (len_type === Int64 || len_type === Int || len_type === UInt64) ? I64 : I32)   # step4
                if len_type === Int64 || len_type === Int || len_type === UInt64
                    num!(b, Opcode.I32_WRAP_I64)
                end
                local_tee!(b, len_local)

                # Create new array of exactly n elements
                array_new_default!(b, str_arr_type)
                local_tee!(b, dest_local)

                # array.copy: dest, dest_offset=0, src, src_offset=0, count=n
                i32_const!(b, 0)  # dest offset
                emit_value!(b, mem_arg, ctx, ConcreteRef(UInt32(str_arr_type), true))  # src array
                i32_const!(b, 0)  # src offset
                local_get!(b, len_local)  # count
                array_copy!(b, str_arr_type, str_arr_type)  # dest type, src type

                # parity(M9): publish as the CLASSED string
                local_get!(b, dest_local)
                emit_string_wrap!(b, ctx)
            elseif length(expr.args) >= 6
                # Fallback: no length arg — wrap the passed-through memory as a string
                mem_arg = expr.args[6]
                emit_value!(b, mem_arg, ctx, ConcreteRef(UInt32(str_arr_type), true))
                emit_string_wrap!(b, ctx)
            end
            return b
        elseif name === :jl_cstr_to_string && length(expr.args) >= 6
            traced = _trace_string_ptr(expr.args[6], ctx.code_info.code)
            if traced !== nothing
                source, _ = traced
                str_idx = get_string_struct_type!(ctx.mod, ctx.type_registry)
                emit_value!(b, source, ctx, ConcreteRef(UInt32(str_idx), true))
                return b
            end
            record_unsupported!(ctx, :unsupported_method,
                "jl_cstr_to_string pointer cannot be traced to a String/Symbol";
                idx=idx, detail=expr)
            unreachable!(b)  # structural trap after recorded unsupported
            ctx.last_stmt_was_stub = true
            return b
        elseif name === :jl_pchar_to_string
            # PURE-325: jl_pchar_to_string(ptr, n) -> String
            # Creates a String from a char pointer and length. In WasmGC, we trace
            # the pointer back to the underlying array, then copy exactly n bytes.
            if length(expr.args) >= 7
                ptr_arg = expr.args[6]
                len_arg = expr.args[7]
                # Julia passes the GC owner as the final preserve argument. Prefer
                # that runtime value over reconstructing identity from pointer phis:
                # resize! legitimately switches an IOBuffer from its empty allocation
                # to a grown allocation, so the owner phi is the exact dynamic storage.
                owner_arg = length(expr.args) >= 9 ? expr.args[end] : nothing
                owner_type = owner_arg === nothing ? nothing : get_ssa_type(ctx, owner_arg)
                owner_is_memory = owner_type isa DataType &&
                    owner_type.name.name in (:Memory, :GenericMemory, :MemoryRef, :GenericMemoryRef)
                data_owner = owner_is_memory ? owner_arg :
                    _trace_memmove_ptr(ptr_arg, ctx; eltypes=(UInt8, Int8))
                if data_owner !== nothing
                    str_arr_type = get_string_array_type!(ctx.mod, ctx.type_registry)

                    # Allocate locals for dest array and length
                    dest_local = length(ctx.locals) + ctx.n_params
                    push!(ctx.locals, ConcreteRef(str_arr_type))
                    len_local = length(ctx.locals) + ctx.n_params
                    push!(ctx.locals, I32)

                    # Compile n and convert to i32
                    len_type = infer_value_type(len_arg, ctx)
                    emit_value!(b, len_arg, ctx, (len_type === Int64 || len_type === Int || len_type === UInt64) ? I64 : I32)   # step4
                    if len_type === Int64 || len_type === Int || len_type === UInt64
                        num!(b, Opcode.I32_WRAP_I64)
                    end
                    local_tee!(b, len_local)

                    # Create new array of exactly n elements
                    array_new_default!(b, str_arr_type)
                    local_tee!(b, dest_local)

                    # array.copy: dest, dest_offset=0, src, src_offset=0, count=n
                    i32_const!(b, 0)  # dest offset
                    # The pointer representation carries its byte offset while the
                    # traced owner carries the GC array identity. For UInt8/Int8,
                    # byte offset and array index are identical.
                    _emit_backing_array!(b, data_owner, ctx, str_arr_type)
                    emit_value!(b, ptr_arg, ctx, I64)
                    coerce_stack_top!(b, I32, ctx; from_julia=Ptr{UInt8})
                    local_get!(b, len_local)  # count
                    array_copy!(b, str_arr_type, str_arr_type)  # dest type, src type

                    # parity(M9): publish as the CLASSED string
                    local_get!(b, dest_local)
                    emit_string_wrap!(b, ctx)
                    return b
                end
                record_unsupported!(ctx, :unsupported_method,
                    "jl_pchar_to_string pointer cannot be traced to owned WasmGC storage"; idx=idx, detail=expr)
                unreachable!(b)  # structural trap after recorded unsupported
                ctx.last_stmt_was_stub = true
            elseif length(expr.args) >= 6
                record_unsupported!(ctx, :unsupported_method,
                    "jl_pchar_to_string lacks a traceable pointer/length pair"; idx=idx, detail=expr)
                unreachable!(b)  # structural trap after recorded unsupported
                ctx.last_stmt_was_stub = true
            end
            return b
        elseif name === :utf8proc_grapheme_break_stateful
            # PURE-316: utf8proc_grapheme_break_stateful(c1::UInt32, c2::UInt32, state::Ref{Int32}) -> Bool
            # Returns true if there's a grapheme cluster break between c1 and c2.
            # WT has no utf8proc runtime yet.  Returning a constant here silently
            # corrupted grapheme boundaries, so this remains explicitly unsupported
            # until the real Unicode state machine is available.
            record_unsupported!(ctx, :value_stub,
                "utf8proc_grapheme_break_stateful requires the Unicode grapheme runtime";
                idx=idx, detail=expr, soundness_fatal=true)
            return b
        elseif name === :jl_ptr_to_array_1d
            # PURE-324: jl_ptr_to_array_1d(type, ptr, len, own) -> Vector{T}
            # Creates a Vector from a raw pointer. In WasmGC, raw pointers don't exist.
            # The pointer arg traces back through bitcast/getfield(:ptr) to a Memory
            # (= array in WasmGC). We trace the IR to find the original data array,
            # then wrap it in a Vector struct (data_array_ref, size_tuple).
            ret_type = length(expr.args) >= 2 ? expr.args[2] : nothing
            ptr_arg = length(expr.args) >= 7 ? expr.args[7] : nothing
            len_arg = length(expr.args) >= 8 ? expr.args[8] : nothing

            if ret_type !== nothing && ret_type <: AbstractVector
                # Trace ptr back through bitcast/getfield(:ptr) to find the data source
                data_source = _trace_ptr_to_data(ptr_arg, ctx)
                if data_source !== nothing
                    # Get or register Vector type
                    vec_info = register_vector_type!(ctx.mod, ctx.type_registry, ret_type)
                    vec_type_idx = vec_info.wasm_type_idx
                    # Get size tuple type
                    size_tuple_type = Tuple{Int64}
                    if !haskey(ctx.type_registry.structs, size_tuple_type)
                        register_tuple_type!(ctx.mod, ctx.type_registry, size_tuple_type)
                    end
                    size_info = ctx.type_registry.structs[size_tuple_type]

                    # Stack: [typeId, data_array_ref, size_tuple_ref] for struct.new Vector
                    # M3: real classId for the Vector struct header
                    emit_struct_prefix!(b, ctx.type_registry, ret_type, vec_info)
                    # 1. Push data array ref
                    local _pta_arr = get_array_type!(ctx.mod, ctx.type_registry, eltype(ret_type))
                    emit_value!(b, data_source, ctx, ConcreteRef(UInt32(_pta_arr), true))
                    # 2. Push typeId + length as i64 for size tuple, then struct.new Tuple{Int64}
                    # M3: real classId for the Tuple{Int64} size header
                    emit_struct_prefix!(b, ctx.type_registry, size_tuple_type, size_info)
                    if len_arg !== nothing
                        len_type = infer_value_type(len_arg, ctx)
                        emit_value!(b, len_arg, ctx,
                                    (len_type === Int32 || len_type === UInt32) ? I32 : I64)
                        if len_type === UInt64
                            # UInt64 → i64 is already i64, but need signed interpretation
                            # For Wasm purposes, UInt64 and Int64 are both i64
                        elseif len_type === Int32 || len_type === UInt32
                            num!(b, Opcode.I64_EXTEND_I32_S)
                        end
                    else
                        i64_const!(b, 0)
                    end
                    struct_new!(b, size_info.wasm_type_idx)   # mod-resolved fields (march3)
                    # 3. struct.new Vector(typeId, data_ref, size_tuple_ref)
                    struct_new!(b, vec_type_idx)   # mod-resolved fields (march3)
                    return b
                end
            end
        end
    end

    # PURE-325: memchr(ptr, byte, count) — scan string array for a byte value.
    # Used by Base._search for findnext/findfirst on strings.
    # In WasmGC, we scan the array<i32> representation directly.
    # With jl_string_ptr base=1: ptr = 1+i-1 = i (1-based start position).
    # memchr returns the 1-based "pointer" (base + array_index) if found, or 0 (C_NULL) if not.
    if name === :memchr && length(expr.args) >= 8
        ptr_arg = expr.args[6]   # Ptr{UInt8} — traces back to string + offset
        byte_arg = expr.args[7]  # Int32 — the byte to search for
        count_arg = expr.args[8] # UInt64 — number of bytes to search

        # Trace the pointer back to find the string array ref
        str_info = ptr_arg isa Core.SSAValue ? _trace_string_ptr(ptr_arg, ctx.code_info.code) : nothing
        if str_info !== nothing
            str_ssa, _idx_ssa = str_info
            str_arr_type = get_string_array_type!(ctx.mod, ctx.type_registry)

            # Allocate locals for the loop (same pattern as scratch_local allocation)
            str_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, ConcreteRef(str_arr_type))
            current_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, I64)
            end_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, I64)
            result_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, I64)
            byte_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, I32)

            # Store string ref
            emit_value!(b, str_ssa, ctx, ConcreteRef(UInt32(str_arr_type), true))   # parity(M9): funnel → DATA array
            local_set!(b, str_local)

            # Store start_ptr (the ptr argument to memchr = 1-based position)
            emit_value!(b, ptr_arg, ctx, I64)
            local_set!(b, current_local)

            # Store byte
            emit_value!(b, byte_arg, ctx, I32)
            local_set!(b, byte_local)

            # Compute end = start + count
            local_get!(b, current_local)
            emit_value!(b, count_arg, ctx, I64)
            num!(b, Opcode.I64_ADD)
            local_set!(b, end_local)

            # result = 0 (not found)
            i64_const!(b, 0)
            local_set!(b, result_local)

            # block $done
            done_label = block!(b)  # void

            #   loop $scan
            scan_label = loop!(b)  # void

            #     if current >= end, break
            local_get!(b, current_local)
            local_get!(b, end_local)
            num!(b, Opcode.I64_GE_U)
            br_if!(b, done_label)

            #     array_index = current - 1 (base=1, so ptr=1 means index=0)
            local_get!(b, str_local)
            local_get!(b, current_local)
            num!(b, Opcode.I32_WRAP_I64)
            i32_const!(b, 1)
            num!(b, Opcode.I32_SUB)  # 0-based index
            array_get!(b, str_arr_type, I32; signed=false)

            #     if array[idx] == byte, found!
            local_get!(b, byte_local)
            num!(b, Opcode.I32_EQ)
            if_!(b)  # void
            #       result = current
            local_get!(b, current_local)
            local_set!(b, result_local)
            br!(b, done_label)
            end_block!(b)  # end if

            #     current += 1
            local_get!(b, current_local)
            i64_const!(b, 1)
            num!(b, Opcode.I64_ADD)
            local_set!(b, current_local)

            #     br $scan (continue loop)
            br!(b, scan_label)

            #   end loop
            end_block!(b)
            # end block
            end_block!(b)

            # Push result (the "pointer" or 0)
            local_get!(b, result_local)
            return b
        end
    end

    # PURE-325: memmove(dest_ptr, src_ptr, n_bytes) — copy between Memory arrays.
    # Used by take!(IOBuffer) to copy data from IOBuffer's backing Memory to a new String.
    # In WasmGC, we emit array.copy between the underlying array<i32> representations.
    # Trace: memmove args come from getfield(memoryref, :ptr_or_offset) which is i64.const 0.
    # The real arrays are found by tracing back through memoryrefnew to the backing Memory.
    if (name === :memmove || name === :memcpy) && length(expr.args) >= 8
        dest_ptr_arg = expr.args[6]   # Ptr{Nothing} — traces to dest MemoryRef
        src_ptr_arg = expr.args[7]    # Ptr{Nothing} — traces to src MemoryRef
        nbytes_arg = expr.args[8]     # UInt64 — byte count

        # P4-stdlib (Statistics median): memmove between TYPED vectors
        # (copy(::Vector{Float64}) inlines to memmove of f64 storage). Trace
        # both pointers to their backing vectors; same primitive eltype of
        # width 4/8 → array.copy with byte offsets/count scaled to elements.
        # (Byte vectors keep the established paths below; array.copy is
        # overlap-safe per the WasmGC spec, matching memmove semantics.)
        local _MMV_PRIMS = (Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64, Float32, Float64)
        local _mmv_d = _trace_memmove_ptr(dest_ptr_arg, ctx; eltypes = _MMV_PRIMS)
        local _mmv_s = _mmv_d !== nothing ? _trace_memmove_ptr(src_ptr_arg, ctx; eltypes = _MMV_PRIMS) : nothing
        if _mmv_d !== nothing && _mmv_s !== nothing
            local _mmv_eltype = value -> begin
                local T = infer_value_type(value, ctx)
                T === String || T === Symbol ? UInt8 : eltype(T)
            end
            local _mmv_te = _mmv_eltype(_mmv_d)
            if _mmv_te === _mmv_eltype(_mmv_s) && sizeof(_mmv_te) in (1, 4, 8)
                local _mmv_arr = get_array_type!(ctx.mod, ctx.type_registry, _mmv_te)
                local _mmv_sh = trailing_zeros(sizeof(_mmv_te))
                local _mmv_emit_arr = vec -> begin
                    _emit_backing_array!(b, vec, ctx, _mmv_arr)
                end
                local _mmv_emit_off = (a, backing) -> begin
                    emit_value!(b, a, ctx, I64)
                    local backing_type = infer_value_type(backing, ctx)
                    if backing_type === String || backing_type === Symbol
                        i64_const!(b, 1)
                        num!(b, Opcode.I64_SUB)
                    end
                    num!(b, Opcode.I32_WRAP_I64)
                    i32_const!(b, Int64(_mmv_sh))
                    num!(b, Opcode.I32_SHR_U)
                end
                _mmv_emit_arr(_mmv_d)
                _mmv_emit_off(dest_ptr_arg, _mmv_d)
                _mmv_emit_arr(_mmv_s)
                _mmv_emit_off(src_ptr_arg, _mmv_s)
                _mmv_emit_off(nbytes_arg, nothing)
                array_copy!(b, _mmv_arr, _mmv_arr)
                # C memmove returns its destination pointer.
                emit_value!(b, dest_ptr_arg, ctx, I64)
                return b
            end
        end

        code = ctx.code_info.code
        dest_info = _trace_memmove_array(dest_ptr_arg, code, ctx)
        src_info = _trace_memmove_array(src_ptr_arg, code, ctx)

        # WBUILD-5401: Fallback for Ryu pattern where pointers come from
        # bitcast(Ptr{Nothing}, add_ptr(getfield(:mem), offset)) instead of
        # getfield(:ptr_or_offset). In WasmGC, the pointer value IS the offset
        # (base is always 0), so we trace to find the array and use pointer
        # values directly as offsets.
        if dest_info === nothing || src_info === nothing
            arr_ssa = _trace_ptr_to_memory_array(dest_ptr_arg, code)
            if arr_ssa === nothing
                arr_ssa = _trace_ptr_to_memory_array(src_ptr_arg, code)
            end
            if arr_ssa !== nothing
                # Found the array — use pointer values as offsets directly
                # In WasmGC, ptr_or_offset = 0, so add_ptr(mem, off) = 0+off = off
                # The compiled pointer SSA value is the offset.
                arr_copy_type = get_array_type!(ctx.mod, ctx.type_registry, UInt8)
                # Dest array
                emit_value!(b, arr_ssa, ctx, ConcreteRef(UInt32(arr_copy_type), true))
                # Dest offset: compile pointer value as i64, wrap to i32
                emit_value!(b, dest_ptr_arg, ctx, I64)
                _dest_type = infer_value_type(dest_ptr_arg, ctx)
                if _dest_type === Int64 || _dest_type === Int || _dest_type === UInt64 || _dest_type <: Ptr
                    num!(b, Opcode.I32_WRAP_I64)
                end
                # Src array (same array)
                emit_value!(b, arr_ssa, ctx, ConcreteRef(UInt32(arr_copy_type), true))
                # Src offset: compile pointer value as i64, wrap to i32
                emit_value!(b, src_ptr_arg, ctx, I64)
                _src_type = infer_value_type(src_ptr_arg, ctx)
                if _src_type === Int64 || _src_type === Int || _src_type === UInt64 || _src_type <: Ptr
                    num!(b, Opcode.I32_WRAP_I64)
                end
                # Length
                _nbytes_type = infer_value_type(nbytes_arg, ctx)
                emit_value!(b, nbytes_arg, ctx, (_nbytes_type === Int64 || _nbytes_type === Int || _nbytes_type === UInt64) ? I64 : I32)   # step4
                if _nbytes_type === Int64 || _nbytes_type === Int || _nbytes_type === UInt64
                    num!(b, Opcode.I32_WRAP_I64)
                end
                # Emit array.copy
                array_copy!(b, arr_copy_type, arr_copy_type)
                # C memmove returns the exact destination pointer. In WT's
                # storage-relative algebra that is the already-computed offset,
                # not a fabricated base value.
                emit_value!(b, dest_ptr_arg, ctx, I64)
                return b
            end
        end

        if dest_info !== nothing && src_info !== nothing
            dest_arr_ssa, dest_offset_ssa = dest_info
            src_arr_ssa, src_offset_ssa = src_info
            # Determine actual array type from the SSA's wasm local type
            # Default to string array (i32[]) but use correct type if SSA local is a ConcreteRef
            arr_copy_type = get_string_array_type!(ctx.mod, ctx.type_registry)
            if dest_arr_ssa isa Core.SSAValue && haskey(ctx.ssa_locals, dest_arr_ssa.id)
                local_idx = ctx.ssa_locals[dest_arr_ssa.id]
                local_type = _get_local_type(ctx, local_idx)
                if local_type isa ConcreteRef
                    arr_copy_type = local_type.type_idx
                end
            end

            # array.copy: dest_arr, dest_offset, src_arr, src_offset, count
            # dest array
            emit_value!(b, dest_arr_ssa, ctx, ConcreteRef(UInt32(arr_copy_type), true))
            # dest offset (0-based: memoryrefnew offset is 1-based, subtract 1)
            if dest_offset_ssa === nothing
                i32_const!(b, 0)
            else
                dest_offset_type = infer_value_type(dest_offset_ssa, ctx)
                emit_value!(b, dest_offset_ssa, ctx, (dest_offset_type === Int64 || dest_offset_type === Int) ? I64 : I32)   # step4
                if dest_offset_type === Int64 || dest_offset_type === Int
                    num!(b, Opcode.I32_WRAP_I64)
                end
                i32_const!(b, 1)
                num!(b, Opcode.I32_SUB)
            end
            # src array
            emit_value!(b, src_arr_ssa, ctx, ConcreteRef(UInt32(arr_copy_type), true))
            # src offset (0-based)
            if src_offset_ssa === nothing
                i32_const!(b, 0)
            else
                src_offset_type = infer_value_type(src_offset_ssa, ctx)
                emit_value!(b, src_offset_ssa, ctx, (src_offset_type === Int64 || src_offset_type === Int) ? I64 : I32)   # step4
                if src_offset_type === Int64 || src_offset_type === Int
                    num!(b, Opcode.I32_WRAP_I64)
                end
                i32_const!(b, 1)
                num!(b, Opcode.I32_SUB)
            end
            # count (convert from bytes to elements)
            # PURE-9066: memmove passes byte count, but array.copy needs element count.
            # Determine element size from the Memory/MemoryRef type parameter.
            _elem_size = 1  # default for UInt8/i8 arrays
            if dest_arr_ssa isa Core.SSAValue
                _mem_type = get(ctx.ssa_types, dest_arr_ssa.id, Any)
                _el_type = nothing
                if _mem_type isa DataType
                    _tname = _mem_type.name.name
                    if (_tname === :GenericMemoryRef || _tname === :GenericMemory) && length(_mem_type.parameters) >= 2
                        # Julia 1.12: MemoryRef{T}/Memory{T} are GenericMemoryRef/GenericMemory
                        # Parameters: (:not_atomic, T, AddrSpace)
                        _el_type = _mem_type.parameters[2]
                    elseif (_tname === :MemoryRef || _tname === :Memory) && !isempty(_mem_type.parameters)
                        _el_type = _mem_type.parameters[1]
                    end
                end
                if _el_type !== nothing && _el_type isa DataType
                    try; _elem_size = sizeof(_el_type); catch; end
                end
            end
            nbytes_type = infer_value_type(nbytes_arg, ctx)
            emit_value!(b, nbytes_arg, ctx, (nbytes_type === Int64 || nbytes_type === Int || nbytes_type === UInt64) ? I64 : I32)   # step4
            if nbytes_type === Int64 || nbytes_type === Int || nbytes_type === UInt64
                num!(b, Opcode.I32_WRAP_I64)
            end
            if _elem_size > 1
                i32_const!(b, Int64(_elem_size))
                num!(b, Opcode.I32_DIV_U)
            end
            # emit array.copy
            array_copy!(b, arr_copy_type, arr_copy_type)  # dest type, src type
            # C memmove returns its exact destination pointer.
            emit_value!(b, dest_ptr_arg, ctx, I64)
            return b
        end
    end

    if name === :jl_symbol_n
        # jl_symbol_n(ptr::Ptr{UInt8}, len::Int64) -> Ref{Symbol}
        # In WasmGC, Symbol is represented as a string byte array (same as String).
        # The GC root argument (expr.args[8]) is the original String — just return it.
        if length(expr.args) >= 8
            gc_root = expr.args[8]
            emit_value!(b, gc_root, ctx, static_wasm_type(gc_root, ctx))
            return b
        end
    end

    # PURE-9043: jl_get_current_task → phantom value (no bytecode)
    # Task SSA is used by getfield/setfield for rngState0..3 (Xoshiro256++ RNG)
    # We handle those field accesses as Wasm global reads/writes in compile_call.
    if name === :jl_get_current_task
        # No bytecode needed — the Task value is phantom.
        # Mark this SSA so it doesn't get stored to a local.
        return b
    end

    # PURE-9042: jl_hrtime → performance.now() * 1e6 (nanoseconds as UInt64)
    # Used by @elapsed and @time for timing.
    if name === :jl_hrtime
        perf_now_idx = ensure_perf_now_import!(ctx.mod)
        call!(b, perf_now_idx, WasmValType[], WasmValType[F64])
        # performance.now() returns f64 milliseconds → multiply by 1e6 for nanoseconds
        f64_const!(b, 1.0e6)
        num!(b, Opcode.F64_MUL)
        # Convert f64 → i64 (unsigned — trunc_sat to handle large values).
        # Typed builder emitter (was a raw 0xFC 0x07 splice — F17 retired it).
        trunc_sat!(b, Opcode.I64_TRUNC_SAT_F64_U)
        return b
    end

    # PURE-9065: Base.memhash(ptr, len, seed) → UInt64 string hash
    # Used by Dict{String,...} for key hashing. In WasmGC, we hash the byte array
    # directly using FNV-1a instead of going through C memhash.
    if name === :memhash
        # Trace the pointer argument back to jl_string_ptr to find the original string
        str_arg = nothing
        if length(expr.args) >= 6
            ptr_arg = expr.args[6]
            if ptr_arg isa Core.SSAValue
                ptr_stmt = ctx.code_info.code[ptr_arg.id]
                if ptr_stmt isa Expr && ptr_stmt.head === :foreigncall
                    ptr_name = length(ptr_stmt.args) >= 1 ? extract_foreigncall_name(ptr_stmt.args[1]) : nothing
                    if ptr_name === :jl_string_ptr && length(ptr_stmt.args) >= 6
                        str_arg = ptr_stmt.args[6]  # The original string argument
                    end
                end
            end
        end

        if str_arg !== nothing
            # Get or create the string hash helper function
            hash_func_idx = get_or_create_string_hash_func!(ctx.mod, ctx.type_registry)
            # Push args: string array ref, length (i64), seed (i32)
            emit_value!(b, str_arg, ctx,
                        ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))  # parity(M9): funnel → DATA
            if length(expr.args) >= 7
                len_arg = expr.args[7]
                emit_value!(b, len_arg, ctx, I64)  # length as i64
            else
                i64_const!(b, 0)
            end
            if length(expr.args) >= 8
                seed_arg = expr.args[8]
                # seed may be i64 from SSA — wrap to i32
                seed_type = infer_value_type(seed_arg, ctx)
                emit_value!(b, seed_arg, ctx,
                            (seed_type === UInt64 || seed_type === Int64 || seed_type === Int) ? I64 : I32)
                if seed_type === UInt64 || seed_type === Int64 || seed_type === Int
                    num!(b, Opcode.I32_WRAP_I64)
                end
            else
                i32_const!(b, 0)
            end
            call!(b, hash_func_idx, WasmValType[], WasmValType[I64])
            return b
        end
        # If we can't trace the string, fall through to unreachable
    end

    # P4-stdlib (Statistics median): jl_genericmemory_copyto(dest_mem,
    # dest_off_ptr, src_mem, src_off_ptr, n_elements) — Memory{T} compiles
    # directly as a wasm array, so this is a plain array.copy; the ptr args
    # are byte offsets (fake-base model) scaled to element indices.
    local _gmc_sym = extract_foreigncall_name(expr.args[1])
    if _gmc_sym === :jl_genericmemory_copyto && length(expr.args) >= 10
        local _gmc_mt = infer_value_type(expr.args[6], ctx)
        local _gmc_te = _gmc_mt isa DataType && length(_gmc_mt.parameters) >= 2 ? _gmc_mt.parameters[2] : nothing
        if _gmc_te isa DataType && isprimitivetype(_gmc_te) && sizeof(_gmc_te) in (1, 2, 4, 8) &&
           infer_value_type(expr.args[8], ctx) === _gmc_mt
            local _gmc_arr = get_array_type!(ctx.mod, ctx.type_registry, _gmc_te)
            local _gmc_sh = trailing_zeros(sizeof(_gmc_te))
            local _gmc_off = a -> begin
                emit_value!(b, a, ctx, I64)
                num!(b, Opcode.I32_WRAP_I64)
                if _gmc_sh > 0
                    i32_const!(b, Int64(_gmc_sh))
                    num!(b, Opcode.I32_SHR_U)
                end
            end
            emit_value!(b, expr.args[6], ctx, ConcreteRef(UInt32(_gmc_arr), true))
            _gmc_off(expr.args[7])
            emit_value!(b, expr.args[8], ctx, ConcreteRef(UInt32(_gmc_arr), true))
            _gmc_off(expr.args[9])
            local _gmc_nt = infer_value_type(expr.args[10], ctx)
            emit_value!(b, expr.args[10], ctx,
                        _gmc_nt in (Int64, UInt64, Int) ? I64 : I32)
            if _gmc_nt in (Int64, UInt64, Int)
                num!(b, Opcode.I32_WRAP_I64)
            end
            array_copy!(b, _gmc_arr, _gmc_arr)
            return b   # Cvoid — no value
        end
    end

    # P4-stdlib (Statistics median/quantile): two HOT-PATH foreigncalls that
    # must NOT set the stub flag — range compilers treat a stubbed statement
    # as dead code and abort the rest of the block, poisoning later
    # conditions into `unreachable`.
    local _fc_sym = extract_foreigncall_name(expr.args[1])
    if _fc_sym === :jl_type_intersection && length(expr.args) >= 7
        # P4-stdlib (Random hash_seed): dispatch guards compare
        # typeintersect(T1, T2) === Union{} with CONSTANT type args — fold on
        # the host and emit the resulting type constant (NOT a stub: the
        # stub flag dead-coded the live loop-exit condition that follows).
        local _ti_a = expr.args[6]
        local _ti_b = expr.args[7]
        _ti_a isa QuoteNode && (_ti_a = _ti_a.value)
        _ti_b isa QuoteNode && (_ti_b = _ti_b.value)
        if _ti_a isa GlobalRef
            _ti_a = try getfield(_ti_a.mod, _ti_a.name) catch; _ti_a end
        end
        if _ti_b isa GlobalRef
            _ti_b = try getfield(_ti_b.mod, _ti_b.name) catch; _ti_b end
        end
        if _ti_a isa Type && _ti_b isa Type
            local _ti_r = try typeintersect(_ti_a, _ti_b) catch; nothing end
            if _ti_r !== nothing
                emit_value!(b, _ti_r, ctx, AnyRef; from_julia=Type{_ti_r})
                return b
            end
        end
    end
    if _fc_sym === :jl_value_ptr
        # Internal pointer_from_objref is representable only when its entire use
        # graph stays inside the storage-relative pointer algebra proved above.
        # The backing storage is recovered by the consuming array operation, and
        # zero is then the exact relative offset of the object's first byte.
        _storage_relative_pointer_is_closed(ctx, idx) || begin
            record_unsupported!(ctx, :unsupported_method,
                "jl_value_ptr escapes storage-relative WasmGC operations";
                idx=idx, detail=expr, soundness_fatal=true)
            ctx.last_stmt_was_stub = true
            return b
        end
        i64_const!(b, 0)
        return b
    elseif _fc_sym === :jl_get_tls_world_age
        # A Wasm module is one immutable closed-world snapshot. Its TLS world
        # age is therefore the exact collection world captured at compilation.
        i64_const!(b, reinterpret(Int64, UInt64(Base.get_world_counter())))
        return b
    elseif _fc_sym === :jl_is_const && length(expr.args) >= 7
        module_owner = _trace_field_owner(expr.args[6], :module, ctx)
        name_owner = _trace_field_owner(expr.args[7], :singletonname, ctx)
        if module_owner !== nothing && isequal(module_owner, name_owner)
            tn_idx = ctx.type_registry.jl_typename_idx
            emit_value!(b, module_owner, ctx, ConcreteRef(UInt32(tn_idx), true))
            struct_get!(b, tn_idx, UInt32(7), I32)
            return b
        end
    elseif _fc_sym === :jl_is_binding_deprecated && length(expr.args) >= 7
        module_owner = _trace_field_owner(expr.args[6], :module, ctx)
        symbol_owner = _trace_typename_symbol_owner(expr.args[7], ctx)
        if module_owner !== nothing && isequal(module_owner, symbol_owner)
            emit_typename_symbol_metadata!(b, expr.args[7], module_owner,
                                           UInt32(11), UInt32(12), ctx)
            return b
        end
    elseif _fc_sym === :jl_module_parent && length(expr.args) >= 6
        module_info = ctx.type_registry.structs[Module]
        emit_value!(b, expr.args[6], ctx, ConcreteRef(module_info.wasm_type_idx, false))
        struct_get!(b, module_info.wasm_type_idx, UInt32(3), AnyRef)
        ref_cast!(b, Int64(module_info.wasm_type_idx), false)
        return b
    elseif _fc_sym === :jl_module_name && length(expr.args) >= 6
        module_info = ctx.type_registry.structs[Module]
        string_idx = get_string_struct_type!(ctx.mod, ctx.type_registry)
        emit_value!(b, expr.args[6], ctx, ConcreteRef(module_info.wasm_type_idx, false))
        struct_get!(b, module_info.wasm_type_idx, UInt32(2),
                    ConcreteRef(UInt32(string_idx), true))
        return b
    elseif _fc_sym === :jl_genericmemory_owner && length(expr.args) >= 6
        # Julia's GenericMemory owner is the memory allocation itself. Memory is
        # represented directly by its non-null WasmGC array, so ownership is an
        # identity operation widened to the foreigncall's `Any` result.
        emit_value!(b, expr.args[6], ctx, AnyRef)
        return b
    elseif _fc_sym === :utf8proc_charwidth && length(expr.args) >= 6
        emit_value!(b, expr.args[6], ctx, I32)
        prop_idx = get_or_create_unicode_property_func!(ctx.mod, ctx.type_registry)
        call!(b, prop_idx, WasmValType[I32], WasmValType[I32])
        i32_const!(b, 5); num!(b, Opcode.I32_SHR_U)
        i32_const!(b, 0x03); num!(b, Opcode.I32_AND)
        return b
    elseif _fc_sym === :utf8proc_category && length(expr.args) >= 6
        emit_value!(b, expr.args[6], ctx, I32)
        prop_idx = get_or_create_unicode_property_func!(ctx.mod, ctx.type_registry)
        call!(b, prop_idx, WasmValType[I32], WasmValType[I32])
        i32_const!(b, 0x1f); num!(b, Opcode.I32_AND)
        return b
    elseif _fc_sym === :jl_stored_inline && length(expr.args) >= 6
        # datatype_storedinline(T) — pure layout predicate; fold when the
        # type argument is a compile-time constant.
        local _fc_t = expr.args[6]
        _fc_t isa QuoteNode && (_fc_t = _fc_t.value)
        if _fc_t isa GlobalRef
            _fc_t = try getfield(_fc_t.mod, _fc_t.name) catch; _fc_t end
        end
        if _fc_t isa Type
            i32_const!(b, (try Base.allocatedinline(_fc_t) catch; false end) ? 1 : 0)
            return b
        end
    end

    # Unknown foreigncall: dart-style loud unsupported path. It is never valid to
    # synthesize a type-default and continue; that silently turns effectful calls
    # (memmove was the historical example) into wrong computations.
    record_unsupported!(ctx, :unsupported_method, "foreigncall `$(name)` (no lowering)"; idx=idx, detail=expr)
    unreachable!(b)  # loud unsupported trap
    ctx.last_stmt_was_stub = true
    return b
end

"""
Trace a pointerref argument back through add_ptr/sub_ptr to find a jl_string_ptr foreigncall.
Returns (string_ssa, index_ssa) if found, or nothing if not a string pointer pattern.
The index_ssa is the offset argument to add_ptr (the 1-based codeunit index).
"""
function _trace_string_ptr(ptr_ssa, code)
    # ptr_ssa should be SSAValue pointing to sub_ptr or add_ptr or jl_string_ptr
    if !(ptr_ssa isa Core.SSAValue)
        return nothing
    end
    stmt = code[ptr_ssa.id]
    if stmt isa Expr && stmt.head === :foreigncall &&
       extract_foreigncall_name(stmt.args[1]) in (:jl_string_ptr, :jl_symbol_name) &&
       length(stmt.args) >= 6
        return (stmt.args[6], nothing)
    end
    if !(stmt isa Expr && stmt.head === :call)
        return nothing
    end
    func = stmt.args[1]
    if !(func isa GlobalRef)
        return nothing
    end
    args = stmt.args[2:end]

    if func.name === :sub_ptr && length(args) >= 2
        # sub_ptr(ptr, offset) — recurse on ptr
        return _trace_string_ptr(args[1], code)
    elseif func.name === :add_ptr && length(args) >= 2
        # add_ptr(ptr, index) — ptr should be jl_string_ptr, index is codeunit index
        inner = args[1]
        if inner isa Core.SSAValue
            inner_stmt = code[inner.id]
            if inner_stmt isa Expr && inner_stmt.head === :foreigncall
                fname_val = extract_foreigncall_name(inner_stmt.args[1])
                if fname_val === :jl_string_ptr && length(inner_stmt.args) >= 6
                    # Found it! Return (string_arg, index_arg)
                    return (inner_stmt.args[6], args[2])
                end
            end
        end
        return nothing
    elseif func.name === :bitcast && length(args) >= 2
        return _trace_string_ptr(args[end], code)
    else
        return nothing
    end
end

"""
Trace a pointer SSA back through bitcast/getfield(:ptr) to find the original data source.
Used by jl_ptr_to_array_1d to find the underlying Memory/array reference.
Returns the SSA value that produces the data array, or nothing if trace fails.

The typical IR pattern is:
  %data = getfield(%iobuf, :data)      -> Memory{T} (= array in WasmGC)
  %ptr  = getfield(%data, :ptr)        -> Ptr{Nothing} (= i64 0 in WasmGC)
  %ptr2 = bitcast(Ptr{UInt8}, %ptr)    -> Ptr{UInt8} (= i64 0)
  ...
  %vec  = jl_ptr_to_array_1d(Vector{T}, %ptr2, %len, ...)

We trace from %ptr2 back to %data (the Memory reference).
"""
function _trace_ptr_to_data(ptr_val, ctx::AbstractCompilationContext)
    code = ctx.code_info.code
    # Walk backwards through SSA values
    current = ptr_val
    for _ in 1:10  # max depth to prevent infinite loops
        if !(current isa Core.SSAValue)
            return nothing
        end
        stmt = code[current.id]
        if stmt isa Expr
            if stmt.head === :call
                func = stmt.args[1]
                if func isa GlobalRef
                    fname = func.name
                    if fname === :bitcast && length(stmt.args) >= 3
                        # bitcast(TargetType, source) — continue tracing source
                        current = stmt.args[3]
                        continue
                    elseif fname === :getfield && length(stmt.args) >= 3
                        field_ref = stmt.args[3]
                        field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
                        if field_sym === :ptr
                            # getfield(memory, :ptr) — the source is the memory obj
                            # The memory IS the data array in WasmGC
                            obj = stmt.args[2]
                            return obj
                        elseif field_sym === :data
                            # getfield(iobuf, :data) — this IS the data array
                            return current
                        else
                            return nothing
                        end
                    end
                end
            elseif stmt.head === :foreigncall
                # May be jl_string_ptr or similar — check
                fname = extract_foreigncall_name(stmt.args[1])
                if fname === :jl_string_ptr && length(stmt.args) >= 6
                    # jl_string_ptr(s) — the string IS the data in WasmGC
                    return stmt.args[6]
                end
                return nothing
            end
        end
        return nothing
    end
    return nothing
end

"""
Trace a memmove pointer argument back through getfield(:ptr_or_offset) → memoryrefnew
to find the underlying array SSA and offset SSA.
Returns (array_ssa, offset_ssa) or nothing if trace fails.
offset_ssa may be nothing if the memoryrefnew has no offset (starts at beginning).

IR pattern:
  %142 = getfield(%69, :ref)          — Vector's ref field (a MemoryRef = array in WasmGC)
  %144 = memoryrefnew(%142, 1, ...)   — MemoryRef at offset 1
  %159 = getfield(%144, :ptr_or_offset)  — i64.const 0 in WasmGC
  memmove(%159, ...)
"""
function _trace_memmove_array(ptr_ssa, code, ctx::AbstractCompilationContext)
    if !(ptr_ssa isa Core.SSAValue)
        return nothing
    end
    stmt = code[ptr_ssa.id]
    # Should be getfield(memoryref, :ptr_or_offset)
    if !(stmt isa Expr && stmt.head === :call)
        return nothing
    end
    func = stmt.args[1]
    if !(func isa GlobalRef && func.name === :getfield && length(stmt.args) >= 3)
        return nothing
    end
    field_ref = stmt.args[3]
    field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
    if field_sym !== :ptr_or_offset
        return nothing
    end
    # The object is a MemoryRef SSA
    memref_ssa = stmt.args[2]
    if !(memref_ssa isa Core.SSAValue)
        return nothing
    end
    memref_stmt = code[memref_ssa.id]

    # Should be memoryrefnew(base) or memoryrefnew(base, offset, boundscheck)
    # or getfield(vector, :ref) — broadcast pattern
    # or PhiNode (sizehint! pattern where dest ref is selected via phi)
    if memref_stmt isa Expr && memref_stmt.head === :call
        fn = memref_stmt.args[1]
        if fn isa GlobalRef && fn.name === :memoryrefnew
            if length(memref_stmt.args) >= 4
                # memoryrefnew(base, offset, boundscheck)
                base_ssa = memref_stmt.args[2]
                offset_ssa = memref_stmt.args[3]
                # base could be another memoryrefnew or a Memory/array directly
                arr_ssa = _resolve_memref_to_array(base_ssa, code)
                return (arr_ssa !== nothing ? arr_ssa : base_ssa, offset_ssa)
            elseif length(memref_stmt.args) >= 2
                # memoryrefnew(memory) — no offset
                base_ssa = memref_stmt.args[2]
                arr_ssa = _resolve_memref_to_array(base_ssa, code)
                return (arr_ssa !== nothing ? arr_ssa : base_ssa, nothing)
            end
        elseif fn isa GlobalRef && fn.name === :getfield && length(memref_stmt.args) >= 3
            # PURE-9066: getfield(vector, :ref) — MemoryRef obtained directly from Vector
            # instead of via memoryrefnew. Common in broadcasting copy paths.
            field_ref = memref_stmt.args[3]
            field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
            if field_sym === :ref
                # The MemoryRef IS the result of getfield(vector, :ref).
                # In WasmGC, this is the array data field of the Vector struct.
                # Use _resolve_memref_to_array which handles getfield(..., :ref).
                arr_ssa = _resolve_memref_to_array(memref_ssa, code)
                return (arr_ssa !== nothing ? arr_ssa : memref_ssa, nothing)
            end
        end
    elseif memref_stmt isa Core.PhiNode
        # WBUILD-3001: PhiNode selecting between MemoryRef branches.
        # Common in sizehint! where dest ref depends on shrink=true/false path.
        # All phi branches typically reference the same underlying Memory.
        # Trace each branch to find the base Memory (via _resolve_memref_to_array).
        for val in memref_stmt.values
            if val isa Core.SSAValue
                branch_stmt = code[val.id]
                if branch_stmt isa Expr && branch_stmt.head === :call
                    fn2 = branch_stmt.args[1]
                    if fn2 isa GlobalRef && fn2.name === :memoryrefnew
                        # Trace memoryrefnew → base Memory
                        base = length(branch_stmt.args) >= 2 ? branch_stmt.args[2] : nothing
                        if base !== nothing
                            arr_ssa = _resolve_memref_to_array(base, code)
                            if arr_ssa !== nothing
                                return (arr_ssa, nothing)
                            end
                            # Base is a Memory directly (from memorynew)
                            return (base, nothing)
                        end
                    end
                end
            end
        end
    end
    return nothing
end

"""
Resolve a MemoryRef base SSA to the actual array.
For memmove, we need the WasmGC array reference that backs the data.
In WasmGC:
  - Vector field :ref → struct_get field 0 → array ref (use the SSA of getfield)
  - IOBuffer field :data → the Memory which IS the array (use the SSA of getfield)
  - jl_string_to_genericmemory → returns the String which IS the array
  - memoryrefnew(base) → the base IS the array
Returns the SSA whose compile_value produces the array ref, or nothing.
"""
function _resolve_memref_to_array(ssa, code)
    if !(ssa isa Core.SSAValue)
        return nothing
    end
    stmt = code[ssa.id]
    if !(stmt isa Expr)
        return nothing
    end
    if stmt.head === :call
        func = stmt.args[1]
        if func isa GlobalRef
            if func.name === :memoryrefnew && length(stmt.args) >= 2
                # Another memoryrefnew — recurse on its base
                return _resolve_memref_to_array(stmt.args[2], code)
            elseif func.name === :getfield && length(stmt.args) >= 3
                field_ref = stmt.args[3]
                field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
                if field_sym === :ref || field_sym === :data
                    # getfield(vector, :ref) or getfield(iobuf, :data)
                    # The RESULT of this getfield is the array in WasmGC
                    # So return the SSA of the getfield itself
                    return ssa
                end
            end
        end
    elseif stmt.head === :foreigncall
        fname = extract_foreigncall_name(stmt.args[1])
        if fname === :jl_string_to_genericmemory && length(stmt.args) >= 6
            # In WasmGC, jl_string_to_genericmemory returns the String which IS the array
            return stmt.args[6]
        end
    end
    return nothing
end

"""
    _trace_ptr_to_memory_array(ptr_ssa, code)

WBUILD-5401: Trace a pointer SSA back through bitcast/add_ptr/sub_ptr/getfield(:mem)
to find the underlying Memory array SSA. Used as fallback for memmove when the pointer
doesn't come from getfield(:ptr_or_offset) but from add_ptr on a Memory reference.

Ryu pattern:
  %mem = getfield(%memref, :mem)           → Memory{UInt8}
  %off = bitcast(UInt64, %some_int)
  %ptr = add_ptr(%mem, %off)               → Ptr at offset
  %raw = bitcast(Ptr{Nothing}, %ptr)       → passed to memmove

Returns the SSA that produces the Memory/array ref, or nothing.
"""
function _trace_ptr_to_memory_array(ptr_ssa, code)
    if !(ptr_ssa isa Core.SSAValue)
        return nothing
    end
    current = ptr_ssa
    for _ in 1:15  # max depth
        if !(current isa Core.SSAValue)
            return nothing
        end
        stmt = code[current.id]
        if !(stmt isa Expr && stmt.head === :call)
            return nothing
        end
        func = stmt.args[1]
        if !(func isa GlobalRef)
            return nothing
        end
        fname = func.name
        if fname === :bitcast && length(stmt.args) >= 3
            current = stmt.args[3]
        elseif fname === :add_ptr && length(stmt.args) >= 3
            current = stmt.args[2]
        elseif fname === :sub_ptr && length(stmt.args) >= 3
            current = stmt.args[2]
        elseif fname === :getfield && length(stmt.args) >= 3
            field_ref = stmt.args[3]
            field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
            if field_sym === :mem
                # getfield(memoryref, :mem) → Memory{T}
                # In WasmGC, the MemoryRef IS the array. Return the memoryref.
                return stmt.args[2]
            elseif field_sym === :ref
                return current
            elseif field_sym === :ptr_or_offset || field_sym === :ptr
                memref_ssa = stmt.args[2]
                return _resolve_memref_to_array(memref_ssa, code)
            else
                return nothing
            end
        else
            return nothing
        end
    end
    return nothing
end
