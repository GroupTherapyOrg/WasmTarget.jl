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
    emit_value!(b, vec, ctx)
    is_mem = vt isa DataType && (vt.name.name === :Memory || vt.name.name === :GenericMemory ||
                                 vt.name.name === :MemoryRef || vt.name.name === :GenericMemoryRef)
    if !is_mem
        vinfo = ctx.type_registry.structs[vt]
        struct_get!(b, vinfo.wasm_type_idx, UInt32(1), ConcreteRef(UInt32(arr_t), true))
    end
    ref_cast!(b, Int64(arr_t), true)
    return b
end

function _trace_memmove_ptr(arg, ctx::AbstractCompilationContext;
                            eltypes = (UInt8, Int8), allow_ref::Bool = false)
    # Walk permissively (through bitcast/add_ptr/sub_ptr/PiNode and any phi
    # edge) looking ONLY for the backing vector's identity. Offsets are NOT
    # collected: in WasmGC the fake base pointer (getfield :ptr_or_offset)
    # compiles to 0, so the POINTER VALUE ITSELF is the byte offset — callers
    # compile the original pointer arg as the array.copy offset.
    _mm_dbg = haskey(ENV, "WT_TRACE_MM")
    _fail = function (why, what)
        _mm_dbg && println(stderr, "  MMtrace FAIL [", why, "]: ", repr(what)[1:min(end, 110)])
        return nothing
    end
    cur = arg
    for _ in 1:48
        cur isa Core.SSAValue || return _fail("non-ssa", cur)
        st = ctx.code_info.code[cur.id]
        _mm_dbg && println(stderr, "  MMtrace %", cur.id, " = ", repr(st)[1:min(end, 100)])
        if st isa Core.PiNode
            cur = st.val
        elseif st isa Expr && st.head === :foreigncall && length(st.args) >= 6 &&
               extract_foreigncall_name(st.args[1]) === :jl_value_ptr
            # P4-stdlib: pointer_from_objref-style base pointers
            # (jl_value_ptr(obj)) — in the fake-pointer model the base is 0,
            # so just hop to the object and keep walking toward the vector.
            cur = st.args[6]
        elseif st isa Core.PhiNode
            (length(st.values) >= 1 && isassigned(st.values, 1)) || return _fail("phi-unassigned", st)
            cur = st.values[1]
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
                # P4-stdlib: identity hop through memoryrefnew — base refs are
                # offset 0, and INDEXED refs now encode (i-1)*elsize in the
                # pointer VALUE (getfield(:ptr_or_offset) reads
                # ctx.memoryref_offsets), so the walk only needs the identity.
                cur = st.args[2]
            elseif cfn === :getfield && length(st.args) >= 3
                fld = st.args[3] isa QuoteNode ? st.args[3].value : st.args[3]
                if fld === :ptr_or_offset || fld === :ptr || fld === :mem
                    # memoryref.ptr_or_offset, memory.ptr, memoryref.mem — all
                    # hops toward the backing vector; all compile to offset-0
                    # bases in WasmGC.
                    cur = st.args[2]
                elseif fld === :ref
                    vec = st.args[2]
                    vt = infer_value_type(vec, ctx)
                    (vt isa DataType && vt <: Vector &&
                     eltype(vt) in eltypes) || return _fail("elty-not-allowed: $vt", vec)
                    return vec
                else
                    # P4-stdlib (SHA update!): getfield(obj, fld) whose RESULT
                    # type is an allowed Vector (ctx.buffer::Vector{UInt8}) is
                    # itself the backing-store identity.
                    local _gf_vt = infer_value_type(cur, ctx)
                    if _gf_vt isa DataType && _gf_vt <: Vector && eltype(_gf_vt) in eltypes
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
Compile a single IR statement to Wasm bytecode.
"""
function compile_statement(stmt, idx::Int, ctx::AbstractCompilationContext)::Vector{UInt8}
    # MIGRATED to InstrBuilder (byte-INSPECTING fn): `bytes` stays a local UInt8[]
    # accumulator — every branch LEB-decodes / scans it (e.g. the n_drops debug loop,
    # the trailing-local.get type checks, the DROP+UNREACHABLE bytecode probe) and
    # external emit_*! helpers mutate it. Only the FINAL splice goes through the typed
    # builder via emit_raw!, so the output is byte-identical. Stays strict=false.
    b = InstrBuilder(; func_name="compile_statement", strict=false, mod=ctx.mod)
    bytes = UInt8[]

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
        push!(bytes, 0x00)  # unreachable — keeps stack polymorphic
        emit_raw!(b, bytes)
        return builder_code(b)
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
            # MIGRATED: compile_value bridges via emit_raw!; slot local.set typed on `b`.
            emit_value!(b, stmt, ctx)
            local_set!(b, ctx.slot_locals[_slot_assign_id])
        end
        emit_raw!(b, bytes)
        return builder_code(b)
    end

    if stmt isa Core.ReturnNode
        # MIGRATED: ReturnNode emits straight-line via typed methods on `b`. External
        # emit_*! helpers (emit_numeric_to_externref!, emit_box_type_id!) and compile_value
        # bridge through a local temp buffer + emit_raw!. `bytes` stays empty for this branch
        # (the trailing slot-assign/n_drops common code below appends after, order-preserved).
        if isdefined(stmt, :val)
            # Check function return type
            func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
            val_wasm = get_phi_edge_wasm_type(stmt.val, ctx)
            is_numeric_val = val_wasm === I32 || val_wasm === I64 || val_wasm === F32 || val_wasm === F64

            if func_ret_wasm === ExternRef && is_numeric_val
                # PURE-325: Box numeric value for ExternRef return (handles nothing too)
                _rb = UInt8[]; emit_numeric_to_externref!(_rb, stmt.val, val_wasm, ctx)
                emit_raw!(b, _rb; pushes=WasmValType[ExternRef])
            elseif func_ret_wasm isa ConcreteRef && is_numeric_val
                # PURE-045: Numeric (nothing) to concrete ref - return ref.null of the type
                ref_null!(b, Int64(func_ret_wasm.type_idx), func_ret_wasm)
            elseif func_ret_wasm === AnyRef && is_numeric_val
                # PURE-9030: Box numeric value for AnyRef return (Union{Int,Float}) via THE single
                # box emitter (was a copy-pasted return box, same as flow.jl/conditionals.jl).
                emit_value!(b, stmt.val, ctx)
                emit_classid_box!(b, ctx, val_wasm, nothing)
            elseif (func_ret_wasm === StructRef || func_ret_wasm === ArrayRef) && is_numeric_val
                # PURE-045: Numeric to abstract ref - return ref.null of the abstract type
                ref_null!(b, func_ret_wasm)
            else
                val_bytes = compile_value(stmt.val, ctx)
                if isempty(val_bytes)
                    # TRUE-INT-002: compile_value produced empty bytes (stubbed SSA value on dead path).
                    # Push a type-correct default so `return` has a value on the stack.
                    if func_ret_wasm isa ConcreteRef
                        ref_null!(b, Int64(func_ret_wasm.type_idx), func_ret_wasm)
                    elseif func_ret_wasm === AnyRef || func_ret_wasm === EqRef || func_ret_wasm === StructRef || func_ret_wasm === ArrayRef
                        ref_null!(b, func_ret_wasm)
                    elseif func_ret_wasm === ExternRef
                        ref_null!(b, ExternRef)  # externref (0x6F)
                    elseif func_ret_wasm === I32
                        i32_const!(b, 0)
                    elseif func_ret_wasm === I64
                        i64_const!(b, 0)
                    elseif func_ret_wasm === F32
                        f32_const!(b, 0.0f0)
                    elseif func_ret_wasm === F64
                        f64_const!(b, 0.0)
                    end
                else
                    emit_raw!(b, val_bytes; pushes=(val_wasm === nothing ? WasmValType[] : WasmValType[val_wasm]))
                end
                # If function returns externref but value is a concrete ref, convert
                if func_ret_wasm === ExternRef && val_wasm !== ExternRef
                    extern_convert_any!(b)
                # PURE-207: If value is I32 but return is I64, extend
                elseif val_wasm === I32 && func_ret_wasm === I64
                    num!(b, Opcode.I64_EXTEND_I32_S)
                # PARSE-001: If function returns ConcreteRef but value is eqref/structref/anyref,
                # cast to match the declared return type. This happens when Union{Nothing, T}
                # phi nodes produce eqref but the return type is (ref null T_idx).
                elseif func_ret_wasm isa ConcreteRef && !(val_wasm isa ConcreteRef)
                    if val_wasm === EqRef || val_wasm === StructRef || val_wasm === AnyRef || val_wasm === ArrayRef
                        ref_cast!(b, Int64(func_ret_wasm.type_idx), true)
                    end
                end
            end
        end
        return_!(b)

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
                            # MIGRATED: compile_value bridges via emit_raw!; local.set typed.
                            emit_value!(b, stmt.val, ctx)
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
        # PiNode is a type assertion - just pass through the value
        pi_type = get(ctx.ssa_types, idx, Any)
        if pi_type !== Nothing
            # Check type compatibility before storing PiNode value
            if haskey(ctx.ssa_locals, idx)
                local_idx = ctx.ssa_locals[idx]
                local_array_idx = local_idx - ctx.n_params + 1
                pi_local_type = local_array_idx >= 1 && local_array_idx <= length(ctx.locals) ? ctx.locals[local_array_idx] : nothing
                # Determine the value's wasm type
                val_wasm_type = get_phi_edge_wasm_type(stmt.val, ctx)
                # P4-stdlib (Random hash_seed): prefer the ACTUAL local type of
                # the source when one exists — the type-derived guess says I64
                # for Union{Nothing, UInt64}, but such unions live in AnyRef
                # locals (boxed; an i64 cannot encode `nothing`), so the
                # AnyRef→numeric unbox below never fired and raw anyref reached
                # i64 arithmetic.
                if stmt.val isa Core.SSAValue
                    local _pv_li = get(ctx.ssa_locals, stmt.val.id, nothing)
                    _pv_li === nothing && (_pv_li = get(ctx.phi_locals, stmt.val.id, nothing))
                    if _pv_li !== nothing
                        local _pv_off = _pv_li - ctx.n_params
                        if _pv_off >= 0 && _pv_off < length(ctx.locals)
                            val_wasm_type = ctx.locals[_pv_off + 1]
                        end
                    end
                end
                # Check if source is a multi-value expression (e.g., multi-arg memoryrefnew)
                # that would push >1 value on the stack — local_set only consumes 1.
                is_multi_value_src = false
                if stmt.val isa Core.SSAValue && !haskey(ctx.ssa_locals, stmt.val.id) && !haskey(ctx.phi_locals, stmt.val.id)
                    src_stmt = ctx.code_info.code[stmt.val.id]
                    if src_stmt isa Expr && src_stmt.head === :call
                        src_func = src_stmt.args[1]
                        is_multi_value_src = (src_func isa GlobalRef &&
                                             (src_func.mod === Core || src_func.mod === Base) &&
                                             src_func.name === :memoryrefnew &&
                                             length(src_stmt.args) >= 4)
                    end
                end
                if is_multi_value_src || (pi_local_type !== nothing && val_wasm_type !== nothing && !wasm_types_compatible(pi_local_type, val_wasm_type))
                    # MIGRATED: PiNode narrowing branches emit straight-line via typed methods
                    # on `b`; compile_value / emit_unwrap_union_value bridge through emit_raw!.
                    # PURE-324: I64→I32 narrowing — PiNode narrows a widened phi (I64) to a
                    # smaller numeric type (I32). Emit the actual value with i32_wrap_i64.
                    if !is_multi_value_src && val_wasm_type === I64 && pi_local_type === I32
                        emit_value!(b, stmt.val, ctx)
                        num!(b, Opcode.I32_WRAP_I64)
                    # PURE-9030: F64→I32 narrowing — PiNode narrows a widened phi (F64) to I32.
                    # Occurs in Union{Int32, Float64} dispatch where phi is F64 (widened).
                    elseif !is_multi_value_src && val_wasm_type === F64 && pi_local_type === I32
                        emit_value!(b, stmt.val, ctx)
                        num!(b, Opcode.I32_TRUNC_F64_S)
                    # PURE-9030: F64→I64 narrowing — PiNode narrows a widened phi (F64) to I64.
                    elseif !is_multi_value_src && val_wasm_type === F64 && pi_local_type === I64
                        emit_value!(b, stmt.val, ctx)
                        num!(b, Opcode.I64_TRUNC_F64_S)
                    # PURE-9030: F32→I32 narrowing — PiNode narrows a widened phi (F32) to I32.
                    elseif !is_multi_value_src && val_wasm_type === F32 && pi_local_type === I32
                        emit_value!(b, stmt.val, ctx)
                        num!(b, Opcode.I32_TRUNC_F32_S)
                    # PURE-325: PiNode narrowing from ExternRef → numeric (I64/I32/F64/F32).
                    # The externref holds a boxed numeric value. Unbox via any_convert_extern +
                    # ref_cast to box type + struct_get field 0.
                    elseif !is_multi_value_src && val_wasm_type === ExternRef && (pi_local_type === I64 || pi_local_type === I32 || pi_local_type === F64 || pi_local_type === F32)
                        emit_value!(b, stmt.val, ctx)
                        # externref holds a boxed numeric — extern→any, then unbox via the one consumer.
                        any_convert_extern!(b)
                        emit_classid_unbox!(b, ctx, pi_local_type; nullable=true)
                    # PURE-9030: PiNode narrowing from AnyRef → numeric (I64/I32/F64/F32).
                    # The anyref holds a boxed numeric value (WasmGC struct with typeId + value).
                    # Unbox via ref.cast to box type + struct_get field 1.
                    # This handles Union{Int32, Float64} dispatch where the param is anyref.
                    elseif !is_multi_value_src && val_wasm_type === AnyRef && (pi_local_type === I64 || pi_local_type === I32 || pi_local_type === F64 || pi_local_type === F32)
                        emit_value!(b, stmt.val, ctx)
                        # anyref holds a boxed numeric — unbox via THE single consumer (non-null: isa-guarded).
                        emit_classid_unbox!(b, ctx, pi_local_type)
                    # PURE-9030: PiNode narrowing from AnyRef → ConcreteRef.
                    # Example: anyref → String, anyref → MyStruct
                    elseif !is_multi_value_src && val_wasm_type === AnyRef && pi_local_type isa ConcreteRef
                        emit_value!(b, stmt.val, ctx)
                        ref_cast!(b, Int64(pi_local_type.type_idx), true)
                    # PURE-321: PiNode narrowing from ExternRef → ConcreteRef means the value
                    # IS available as externref and just needs conversion (not ref.null).
                    # Example: PiNode(%198, String) narrows Any (externref) → String (array<i32>).
                    elseif !is_multi_value_src && val_wasm_type === ExternRef && pi_local_type isa ConcreteRef
                        emit_value!(b, stmt.val, ctx)
                        any_convert_extern!(b)
                        ref_cast!(b, Int64(pi_local_type.type_idx), true)
                    # PURE-9032: PiNode narrowing from ArrayRef → ConcreteRef.
                    # Example: arrayref (from struct field typed AbstractString) → (ref null $str_array)
                    # This occurs when getfield returns an abstract ref type but PiNode narrows it.
                    elseif !is_multi_value_src && val_wasm_type === ArrayRef && pi_local_type isa ConcreteRef
                        emit_value!(b, stmt.val, ctx)
                        ref_cast!(b, Int64(pi_local_type.type_idx), true)
                    # PURE-9032: PiNode narrowing from StructRef → ConcreteRef.
                    # Example: structref (from :the_exception with Union type) → concrete exception struct
                    elseif !is_multi_value_src && val_wasm_type === StructRef && pi_local_type isa ConcreteRef
                        emit_value!(b, stmt.val, ctx)
                        ref_cast!(b, Int64(pi_local_type.type_idx), true)
                    # CG-003d: PiNode narrowing from EqRef → ConcreteRef.
                    # Example: Union{Nothing, TestNode} (eqref local) → TestNode after null check.
                    # This occurs because Union{Nothing, T} locals use EqRef (RC1 fix).
                    elseif !is_multi_value_src && val_wasm_type === EqRef && pi_local_type isa ConcreteRef
                        emit_value!(b, stmt.val, ctx)
                        ref_cast!(b, Int64(pi_local_type.type_idx), true)
                    # PURE-6024: Tagged union unwrapping — PiNode narrows Union{A,B} to variant.
                    # Source is a ConcreteRef (tagged union struct), target is the extracted variant.
                    # Example: π(%53::Union{AbstractString,Symbol}, Symbol) needs struct.get + cast.
                    elseif !is_multi_value_src && val_wasm_type isa ConcreteRef
                        src_julia_type = nothing
                        if stmt.val isa Core.SSAValue
                            src_julia_type = get(ctx.ssa_types, stmt.val.id, nothing)
                        elseif stmt.val isa Core.Argument
                            arg_idx = stmt.val.n - 1
                            if arg_idx >= 1 && arg_idx <= length(ctx.arg_types)
                                src_julia_type = ctx.arg_types[arg_idx]
                            end
                        end
                        if src_julia_type isa Union && needs_tagged_union(src_julia_type)
                            emit_value!(b, stmt.val, ctx)
                            emit_raw!(b, emit_unwrap_union_value(ctx, src_julia_type, stmt.typ);
                                      pops=1, pushes=(pi_local_type === nothing ? WasmValType[] : WasmValType[pi_local_type]))
                        elseif pi_local_type isa ConcreteRef
                            ref_null!(b, Int64(pi_local_type.type_idx), pi_local_type)
                        elseif pi_local_type === ArrayRef
                            ref_null!(b, ArrayRef)
                        elseif pi_local_type === StructRef
                            ref_null!(b, StructRef)
                        else
                            ref_null!(b, ExternRef)
                        end
                    elseif pi_local_type === ExternRef
                        ref_null!(b, ExternRef)
                    elseif pi_local_type === AnyRef
                        ref_null!(b, AnyRef)
                    elseif pi_local_type === I64
                        i64_const!(b, 0)
                    elseif pi_local_type === I32
                        i32_const!(b, 0)
                    elseif pi_local_type === F64
                        f64_const!(b, 0.0)
                    elseif pi_local_type === F32
                        f32_const!(b, 0.0f0)
                    else
                        i32_const!(b, 0)
                    end
                else
                    val_bytes, val_ty = compile_value_typed(stmt.val, ctx)
                    # Safety: check if val_bytes pushes multiple values (all local_gets, N>=2).
                    # local_set only consumes 1, so N-1 would be orphaned.
                    is_multi_value_bytes = false
                    if length(val_bytes) >= 4
                        _all_gets = true
                        _n_gets = 0
                        _pos = 1
                        while _pos <= length(val_bytes)
                            if val_bytes[_pos] != 0x20
                                _all_gets = false
                                break
                            end
                            _n_gets += 1
                            _pos += 1
                            while _pos <= length(val_bytes) && (val_bytes[_pos] & 0x80) != 0
                                _pos += 1
                            end
                            _pos += 1
                        end
                        if _all_gets && _pos > length(val_bytes) && _n_gets >= 2
                            is_multi_value_bytes = true
                        end
                    end
                    if is_multi_value_bytes
                        # Multi-value source: emit type-safe default for the local's type
                        if pi_local_type isa ConcreteRef
                            ref_null!(b, Int64(pi_local_type.type_idx), pi_local_type)
                        elseif pi_local_type === StructRef
                            ref_null!(b, StructRef)
                        elseif pi_local_type === ArrayRef
                            ref_null!(b, ArrayRef)
                        elseif pi_local_type === ExternRef
                            ref_null!(b, ExternRef)
                        elseif pi_local_type === AnyRef
                            ref_null!(b, AnyRef)
                        elseif pi_local_type === I64
                            i64_const!(b, 0)
                        elseif pi_local_type === I32
                            i32_const!(b, 0)
                        elseif pi_local_type === F64
                            f64_const!(b, 0.0)
                        elseif pi_local_type === F32
                            f32_const!(b, 0.0f0)
                        else
                            i32_const!(b, 0)
                        end
                    # Safety: if compile_value produced a numeric value (i32_const, i64_const,
                    # or local.get of numeric local) but pi_local_type is a ref type,
                    # emit ref.null instead. This happens when val_wasm_type is nothing
                    # (can't determine source type) but the PiNode's target local is ref-typed.
                    elseif pi_local_type !== nothing && (pi_local_type isa ConcreteRef || pi_local_type === StructRef || pi_local_type === ArrayRef || pi_local_type === ExternRef || pi_local_type === AnyRef || pi_local_type === EqRef)
                        # dart2wasm carries the type with the value: the source is numeric
                        # iff its inferred wasm type is not a ref (covers const and local.get).
                        is_numeric_val = !isempty(val_bytes) && !_wt_is_ref(infer_value_wasm_type(stmt.val, ctx))
                        if is_numeric_val
                            # Replace with ref.null of the correct type
                            if pi_local_type isa ConcreteRef
                                ref_null!(b, Int64(pi_local_type.type_idx), pi_local_type)
                            elseif pi_local_type === ArrayRef
                                ref_null!(b, ArrayRef)
                            elseif pi_local_type === ExternRef
                                _ne = UInt8[]; emit_numeric_to_externref!(_ne, stmt.val, val_wasm, ctx)
                                emit_raw!(b, _ne; pushes=WasmValType[ExternRef])
                            elseif pi_local_type === AnyRef
                                ref_null!(b, AnyRef)
                            elseif pi_local_type === EqRef
                                ref_null!(b, EqRef)
                            else
                                ref_null!(b, StructRef)
                            end
                        else
                            emit_raw!(b, val_bytes; pushes=(val_ty===nothing ? WasmValType[] : WasmValType[val_ty]))
                        end
                    else
                        emit_raw!(b, val_bytes; pushes=(val_ty===nothing ? WasmValType[] : WasmValType[val_ty]))
                    end
                end
            end
            # else: no ssa_local — compile_value will re-emit the value on demand
        end
        # else: Nothing-typed PiNode without ssa_local — no-op

        # If this SSA value needs a local, store it (and remove from stack)
        if haskey(ctx.ssa_locals, idx)
            local_idx = ctx.ssa_locals[idx]
            local_set!(b, local_idx)  # Use SET not TEE to not leave on stack
        end

    elseif stmt isa Core.NewvarNode
        # PURE-6024: Unoptimized IR slot initialization — no-op in WASM
        # (WASM locals are default-initialized to null/zero)

    elseif stmt isa Core.EnterNode
        # Exception handling: Enter try block
        # For now, we just skip this - full implementation requires try_table
        # The catch destination is in stmt.catch_dest
        # TODO: Implement full try/catch with try_table instruction

    elseif stmt isa GlobalRef
        # MIGRATED: straight-line global.get/local.set via typed methods on `b`; the
        # value_bytes safety-scan stays a local buffer (byte-inspecting) then bridges via
        # emit_raw!. `bytes` stays empty for this branch (trailing common code appends after).
        # GlobalRef statement - check if it's a module-level global first
        key = (stmt.mod, stmt.name)
        global_idx = _lookup_module_global(ctx.module_globals, key)
        if global_idx !== nothing
            global_get!(b, global_idx, AnyRef)

            # If this SSA value needs a local, store it
            if haskey(ctx.ssa_locals, idx)
                local_idx = ctx.ssa_locals[idx]
                local_set!(b, local_idx)
            end
        else
            # Regular GlobalRef - evaluate the constant and push it
            # This handles things like Main.SLOT_EMPTY that are module-level constants
            try
                val = getfield(stmt.mod, stmt.name)
                value_bytes, value_ty = compile_value_typed(val, ctx)

                # CG-003d: Safety check for Nothing/numeric values stored to ref-typed locals.
                # compile_value(nothing) → i32_const 0, which is incompatible with ref locals
                # (EqRef, ConcreteRef, StructRef, etc.). Replace with ref.null of correct type.
                if !isempty(value_bytes) && haskey(ctx.ssa_locals, idx)
                    local_idx = ctx.ssa_locals[idx]
                    local_array_idx = local_idx - ctx.n_params + 1
                    if local_array_idx >= 1 && local_array_idx <= length(ctx.locals)
                        local_wasm_type = ctx.locals[local_array_idx]
                        first_byte = value_bytes[1]
                        is_numeric_value = (first_byte == Opcode.I32_CONST || first_byte == Opcode.I64_CONST ||
                                           first_byte == Opcode.F32_CONST || first_byte == Opcode.F64_CONST)
                        local_is_ref = (local_wasm_type isa ConcreteRef || local_wasm_type === StructRef ||
                                       local_wasm_type === ArrayRef || local_wasm_type === ExternRef ||
                                       local_wasm_type === AnyRef || local_wasm_type === EqRef)
                        if is_numeric_value && local_is_ref
                            # Replace numeric value with ref.null of the correct type
                            # (typed via _append_default!; byte-identical; local_is_ref
                            # guarantees a ref type, so the numeric/else arms are unreachable).
                            empty!(value_bytes)
                            _append_default!(value_bytes, local_wasm_type)
                        end
                    end
                end

                emit_raw!(b, value_bytes; pushes=(value_ty===nothing ? WasmValType[] : WasmValType[value_ty]))

                # If this SSA value needs a local, store it (only if we actually pushed a value)
                # compile_value returns empty bytes for Functions, Types, etc.
                if !isempty(value_bytes) && haskey(ctx.ssa_locals, idx)
                    local_idx = ctx.ssa_locals[idx]
                    local_set!(b, local_idx)
                end
            catch
                # If we can't evaluate, it might be a type reference which has no runtime value
            end
        end

    elseif stmt isa Expr
        stmt_bytes = UInt8[]
        ctx.last_stmt_was_stub = false  # PURE-908: reset before dispatch
        if stmt.head === :call
            stmt_bytes = compile_call(stmt, idx, ctx)
            if haskey(ENV, "WT_TRACE_MM") && !isempty(stmt_bytes) && stmt_bytes[1] == Opcode.UNREACHABLE
                println(stderr, "UNREACH idx=$idx stmt=", repr(stmt)[1:min(end,110)])
            end
        elseif stmt.head === :invoke
            stmt_bytes = compile_invoke(stmt, idx, ctx)
        elseif stmt.head === :new
            # Struct construction: %new(Type, args...)
            stmt_bytes = compile_new(stmt, idx, ctx)
        elseif stmt.head === :boundscheck
            # P2-batch6: compile to the expr's REAL value (true unless @inbounds).
            # We previously pushed false ("wasm has its own bounds checking"), but
            # wasm's array.get check is an UNCATCHABLE TRAP — skipping Julia's own
            # check branch meant getindex OOB could never reach the catchable
            # throw_boundserror path (gap 3ead683e6ff9 family / divergent_throw).
            local _bcb = InstrBuilder(; func_name="compile_statement", strict=false)
            i32_const!(_bcb, (isempty(stmt.args) || stmt.args[1] !== false) ? 1 : 0)
            append!(stmt_bytes, builder_code(_bcb))
        elseif stmt.head === :foreigncall
            # Handle foreign calls - specifically for Vector allocation
            stmt_bytes = compile_foreigncall(stmt, idx, ctx)
        elseif stmt.head === :the_exception
            # PURE-9032: Retrieve the caught exception value from the $current_exn global.
            # Julia IR emits :the_exception in catch blocks to get the caught exception.
            # We stash exception values into a (mut anyref) global before throw,
            # and retrieve them here with global.get.
            exn_global = ensure_exception_global!(ctx.mod)
            local _exb = InstrBuilder(; func_name="compile_statement", strict=false)
            global_get!(_exb, exn_global, AnyRef)
            append!(stmt_bytes, builder_code(_exb))
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
                # anyref → structref via ref.cast null struct (typed; byte-identical)
                local _ecb = InstrBuilder(; func_name="compile_statement", strict=false)
                ref_cast!(_ecb, StructRef, true)
                append!(stmt_bytes, builder_code(_ecb))
            elseif _exn_local_wasm isa ConcreteRef
                # anyref → concrete ref via ref.cast null $type (typed; byte-identical)
                local _ecb = InstrBuilder(; func_name="compile_statement", strict=false)
                ref_cast!(_ecb, Int64(_exn_local_wasm.type_idx), true)
                append!(stmt_bytes, builder_code(_ecb))
            end
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

        # PURE-908: Check if compile_call/compile_invoke emitted a stub UNREACHABLE.
        # Byte-level detection of 0x00 is unreliable (LEB128 zeros are common).
        # Instead, compile_call/compile_invoke set ctx.last_stmt_was_stub = true.
        _stmt_ends_unreachable = ctx.last_stmt_was_stub
        # PURE-6024: Don't reset here — let callers (generate_stackified_flow etc.)
        # detect unreachable and skip dead code. Reset happens at start of next
        # compile_statement call (line ~15011).

        # Safety check: if stmt_bytes produces a value incompatible with the SSA local type,
        # replace with type-safe default. Catches:
        # (1) Pure local.get of incompatible type
        # (2) Numeric constants (i32_const, i64_const, f32_const, f64_const) stored into ref-typed locals
        # (3) struct_get producing abstract ref (structref/arrayref) where concrete ref expected → ref.cast
        ssa_type_mismatch = false
        needs_ref_cast_local = nothing  # Set to ConcreteRef target type when ref.cast is needed
        needs_any_convert_extern = false  # PURE-036bj: externref→anyref before ref.cast
        needs_extern_convert_any = false  # PURE-913: ref→externref for Any-typed locals
        # PURE-908: Skip safety checks for stub stmts — no value on stack to check
        if !_stmt_ends_unreachable && haskey(ctx.ssa_locals, idx) && length(stmt_bytes) >= 2
            local_idx = ctx.ssa_locals[idx]
            local_array_idx = local_idx - ctx.n_params + 1
            local_wasm_type = local_array_idx >= 1 && local_array_idx <= length(ctx.locals) ? ctx.locals[local_array_idx] : nothing
            if local_wasm_type !== nothing
                needs_type_safe_default = false
                struct_get_type_ok = false  # PURE-904: Track when struct_get already produces compatible type

                if stmt_bytes[1] == 0x20  # LOCAL_GET
                    # Decode the source local.get index and verify it consumes ALL bytes
                    src_local_idx = 0
                    shift = 0
                    leb_end = 0
                    for bi in 2:length(stmt_bytes)
                        byt = stmt_bytes[bi]
                        src_local_idx |= (Int(byt & 0x7f) << shift)
                        shift += 7
                        if (byt & 0x80) == 0
                            leb_end = bi
                            break
                        end
                    end
                    # Only apply safety check if stmt_bytes is EXACTLY local.get <idx>
                    is_pure_local_get = (leb_end == length(stmt_bytes))
                    src_array_idx = src_local_idx - ctx.n_params + 1
                    if is_pure_local_get && src_array_idx >= 1 && src_array_idx <= length(ctx.locals)
                        src_wasm_type = ctx.locals[src_array_idx]
                        if !wasm_types_compatible(local_wasm_type, src_wasm_type)
                            # Check if this is abstract ref → concrete ref (can be cast, not replaced)
                            if (src_wasm_type === StructRef || src_wasm_type === ArrayRef || src_wasm_type === AnyRef || src_wasm_type === EqRef) && local_wasm_type isa ConcreteRef
                                # Abstract ref (including anyref/eqref) can be downcast to concrete ref with ref.cast
                                needs_ref_cast_local = local_wasm_type
                            elseif src_wasm_type === ExternRef && local_wasm_type isa ConcreteRef
                                # PURE-036bj: externref local → concrete ref requires any_convert_extern first
                                needs_any_convert_extern = true
                                needs_ref_cast_local = local_wasm_type
                            elseif (src_wasm_type isa ConcreteRef || src_wasm_type === StructRef || src_wasm_type === ArrayRef || src_wasm_type === AnyRef || src_wasm_type === EqRef) && local_wasm_type === ExternRef
                                # PURE-913: concrete/abstract ref → externref requires extern_convert_any
                                needs_extern_convert_any = true
                            else
                                needs_type_safe_default = true
                            end
                        end
                    elseif is_pure_local_get && src_local_idx < ctx.n_params
                        # Source is a function parameter - get its Wasm type from arg_types
                        param_julia_type = ctx.arg_types[src_local_idx + 1]  # Julia is 1-indexed
                        src_wasm_type = get_concrete_wasm_type(param_julia_type, ctx.mod, ctx.type_registry)
                        if src_wasm_type !== nothing && !wasm_types_compatible(local_wasm_type, src_wasm_type)
                            # Check if this is abstract ref → concrete ref (can be cast, not replaced)
                            if (src_wasm_type === StructRef || src_wasm_type === ArrayRef || src_wasm_type === AnyRef || src_wasm_type === EqRef) && local_wasm_type isa ConcreteRef
                                # Abstract ref (including anyref/eqref) can be downcast to concrete ref with ref.cast
                                needs_ref_cast_local = local_wasm_type
                            elseif src_wasm_type === ExternRef && local_wasm_type isa ConcreteRef
                                # PURE-036bj: externref param → concrete ref requires any_convert_extern first
                                needs_any_convert_extern = true
                                needs_ref_cast_local = local_wasm_type
                            elseif (src_wasm_type isa ConcreteRef || src_wasm_type === StructRef || src_wasm_type === ArrayRef || src_wasm_type === AnyRef || src_wasm_type === EqRef) && local_wasm_type === ExternRef
                                # PURE-913: concrete/abstract ref param → externref requires extern_convert_any
                                needs_extern_convert_any = true
                            else
                                needs_type_safe_default = true
                            end
                        end
                    end
                elseif (stmt_bytes[1] == Opcode.I32_CONST || stmt_bytes[1] == Opcode.I64_CONST ||
                        stmt_bytes[1] == Opcode.F32_CONST || stmt_bytes[1] == Opcode.F64_CONST)
                    # Numeric constant being stored into a ref-typed local
                    # PURE-204: Skip for invoke/call results — their stmt_bytes start with
                    # i32.const for the first argument but contain a CALL that returns a ref type.
                    # PURE-317: Also skip for :new (struct construction) — first field may be
                    # numeric but the result is always a struct ref (via struct_new at the end).
                    is_call_result = stmt isa Expr && (stmt.head === :invoke || stmt.head === :call || stmt.head === :new || stmt.head === :foreigncall)
                    if !is_call_result &&
                       (local_wasm_type isa ConcreteRef || local_wasm_type === StructRef ||
                        local_wasm_type === ArrayRef || local_wasm_type === ExternRef || local_wasm_type === AnyRef ||
                        local_wasm_type === EqRef)
                        needs_type_safe_default = true
                    end
                end

                # Check if stmt_bytes is a compound numeric expression stored into a
                # ref-typed local. Pattern: starts with local.get (0x20) and ends with
                # a pure stack numeric opcode (no immediate args). This catches cases
                # like: local.get + i32_wrap_i64 + i32_const + i32_sub → stored in ref local.
                # We require stmt_bytes[1] == LOCAL_GET to avoid false positives with
                # constants whose LEB128 values happen to match opcode bytes.
                # PURE-206: Skip for Int128/UInt128 SSAs — their intrinsic code
                # (sext_int, add_int, etc.) ends with struct_new whose LEB128 type
                # index byte can be misidentified as a numeric opcode.
                # PURE-307: Skip for struct construction (:new), Core.tuple, and getfield
                # on ref-producing statements. These emit GC-prefix instructions
                # (struct_new, struct_get, array_new) whose LEB128 type index bytes
                # can match numeric opcode ranges (0x46-0xC4). For example,
                # struct_new type 74 → bytes [0xFB, 0x00, 0x4A], and 0x4A = i32.ge_s.
                ssa_is_128bit = false
                if local_wasm_type isa ConcreteRef
                    ssa_jt_128 = get(ctx.ssa_types, idx, nothing)
                    ssa_is_128bit = (ssa_jt_128 === Int128 || ssa_jt_128 === UInt128)
                end
                # PURE-307: Skip for statements that produce ref values (struct/array ops)
                # Check if stmt_bytes contains GC_PREFIX (0xFB) — all WasmGC struct/array
                # operations use this prefix, and their LEB128 operands cause false positives.
                has_gc_prefix = false
                if !ssa_is_128bit
                    for bi in 1:length(stmt_bytes)
                        if stmt_bytes[bi] == Opcode.GC_PREFIX
                            has_gc_prefix = true
                            break
                        end
                    end
                end
                if !needs_type_safe_default && !ssa_is_128bit && !has_gc_prefix && length(stmt_bytes) >= 3 &&
                   stmt_bytes[1] == 0x20 &&  # starts with local.get
                   (local_wasm_type isa ConcreteRef || local_wasm_type === StructRef ||
                    local_wasm_type === ArrayRef || local_wasm_type === ExternRef || local_wasm_type === AnyRef ||
                    local_wasm_type === EqRef)
                    last_byte = stmt_bytes[end]
                    # PURE-220 / P3-titlecase: the last byte must be a single-byte
                    # numeric opcode that IS the final instruction — not an immediate
                    # byte of a trailing call/local.get/const. Forward-parse to the
                    # true last instruction boundary instead of guessing backward
                    # (e.g. call 80 → [0x10, 0x50] where 0x50 reads as i64.eqz).
                    local _cn_li = _last_instr_start(stmt_bytes)
                    ends_with_leb_operand = !(_cn_li == length(stmt_bytes))
                    if !ends_with_leb_operand
                        # Pure stack ops: single-byte opcodes with NO immediate arguments
                        is_numeric_stack_op = (
                            last_byte == 0x45 ||  # i32.eqz
                            last_byte == 0x50 ||  # i64.eqz
                            (last_byte >= 0x46 && last_byte <= 0x66) ||  # i32/i64/f32/f64 comparisons
                            (last_byte >= 0x67 && last_byte <= 0x78) ||  # i32 unary/binary arithmetic
                            (last_byte >= 0x79 && last_byte <= 0x8a) ||  # i64 unary/binary arithmetic
                            (last_byte >= 0x8b && last_byte <= 0xa6) ||  # f32/f64 arithmetic
                            (last_byte >= 0xa7 && last_byte <= 0xc4)     # numeric conversions
                        )
                        if is_numeric_stack_op
                            needs_type_safe_default = true
                        end
                    end
                end

                # Check if stmt_bytes ENDS with a local.get of incompatible type
                # (handles non-pure cases like memoryrefset! which returns value after array_set)
                # PURE-323: Skip when has_gc_prefix — WasmGC struct.get/array.get LEB128
                # operands (type index, field index) can have byte 0x20 which matches
                # LOCAL_GET opcode. E.g. struct.get type_32 field_0 = [0xFB, 0x02, 0x20, 0x00]
                # where 0x20 is LEB128(32), not LOCAL_GET.
                # PURE-913: Skip trailing check when the pure local.get check already
                # handled the conversion (any flag was set: ref_cast, any_convert, extern_convert)
                pure_check_handled = needs_ref_cast_local !== nothing || needs_any_convert_extern || needs_extern_convert_any
                if !needs_type_safe_default && !has_gc_prefix && !pure_check_handled && length(stmt_bytes) >= 2
                    # PURE-306 / P3-titlecase: locate the trailing local.get by FORWARD
                    # parse from a known instruction boundary. The previous backward scan
                    # misread immediate bytes as the LOCAL_GET opcode — `i32.const 32`
                    # is [0x41, 0x20], so any `x ± 32` (ASCII case distance!) had its
                    # 0x20 immediate matched, the following arithmetic opcode decoded as
                    # a bogus local index, and a random local's type then decided whether
                    # the whole computation was replaced with a zero default.
                    local si = _last_instr_start(stmt_bytes)
                    if si > 0 && stmt_bytes[si] == 0x20 && si < length(stmt_bytes)
                        # Decode the trailing local.get's LEB128 index
                        local tlg_idx = 0
                        local tlg_shift = 0
                        local tlg_end = 0
                        for bi in (si + 1):length(stmt_bytes)
                            byt = stmt_bytes[bi]
                            tlg_idx |= (Int(byt & 0x7f) << tlg_shift)
                            tlg_shift += 7
                            if (byt & 0x80) == 0
                                tlg_end = bi
                                break
                            end
                        end
                        if tlg_end == length(stmt_bytes)
                            # This local.get is at the very end of stmt_bytes
                            tlg_arr_idx = tlg_idx - ctx.n_params + 1
                            if tlg_arr_idx >= 1 && tlg_arr_idx <= length(ctx.locals)
                                tlg_type = ctx.locals[tlg_arr_idx]
                                if !wasm_types_compatible(local_wasm_type, tlg_type)
                                    # Trailing local.get of incompatible type — truncate and emit default
                                    resize!(stmt_bytes, si - 1)
                                    needs_type_safe_default = true
                                end
                            elseif tlg_idx < ctx.n_params
                                # PURE-036bl: Trailing local.get of a PARAM - check param type
                                param_julia_type = ctx.arg_types[tlg_idx + 1]  # Julia is 1-indexed
                                tlg_type = get_concrete_wasm_type(param_julia_type, ctx.mod, ctx.type_registry)
                                if tlg_type !== nothing && !wasm_types_compatible(local_wasm_type, tlg_type)
                                    if tlg_type === ExternRef && local_wasm_type isa ConcreteRef
                                        # externref param → concrete ref requires any_convert_extern + ref.cast
                                        needs_any_convert_extern = true
                                        needs_ref_cast_local = local_wasm_type
                                    elseif (tlg_type === StructRef || tlg_type === ArrayRef || tlg_type === AnyRef) && local_wasm_type isa ConcreteRef
                                        needs_ref_cast_local = local_wasm_type
                                    else
                                        resize!(stmt_bytes, si - 1)
                                        needs_type_safe_default = true
                                    end
                                end
                            end
                        end
                    end
                end

                # P4-stdlib (Random seed!): stmt ends with array.get_u/get_s on a
                # packed array — those ALWAYS produce i32 — while the SSA local
                # is i64 (seed bytes combined into UInt64 words). Append the
                # signedness-matching extend. Forward-parsed like the struct_get
                # check below (backward scans misfire on LEB collisions).
                if !needs_type_safe_default && local_wasm_type === I64 && length(stmt_bytes) >= 3
                    local _ag_li = _last_instr_start(stmt_bytes)
                    if _ag_li > 0 && _ag_li + 1 <= length(stmt_bytes) &&
                       stmt_bytes[_ag_li] == Opcode.GC_PREFIX &&
                       (stmt_bytes[_ag_li + 1] == Opcode.ARRAY_GET_U ||
                        stmt_bytes[_ag_li + 1] == Opcode.ARRAY_GET_S)
                        push!(stmt_bytes, stmt_bytes[_ag_li + 1] == Opcode.ARRAY_GET_U ?
                              Opcode.I64_EXTEND_I32_U : Opcode.I64_EXTEND_I32_S)
                    end
                end

                # Check if stmt_bytes ends with struct_get whose result type is incompatible
                # with the target local. struct_get = [0xFB, 0x02, type_leb, field_leb]
                # P3 gap a6c6091b2a80: FORWARD-parse to the last instruction — the
                # backward 0xFB 0x02 scan misread `local.get 379` (LEB 0xFB 0x02!)
                # as a struct_get, decoded garbage type/field, and nulled the value
                # of an ht_keyindex2_shorthash! invoke (composition-only null deref:
                # only modules with enough locals reach index 379). Same misparse
                # class as the i32.const-32 byte-scan bug (gap a1b2c32const).
                if !needs_type_safe_default && length(stmt_bytes) >= 4 && local_wasm_type isa ConcreteRef
                    sg_pos = 0
                    local _sg_li = _last_instr_start(stmt_bytes)
                    if _sg_li > 0 && _sg_li + 1 <= length(stmt_bytes) &&
                       stmt_bytes[_sg_li] == Opcode.GC_PREFIX && stmt_bytes[_sg_li + 1] == Opcode.STRUCT_GET
                        sg_pos = _sg_li
                    end
                    if sg_pos > 0 && sg_pos + 2 <= length(stmt_bytes)
                        # Decode type_idx LEB128
                        sg_type_idx = 0
                        sg_shift = 0
                        sg_bi = sg_pos + 2
                        while sg_bi <= length(stmt_bytes)
                            byt = stmt_bytes[sg_bi]
                            sg_type_idx |= (Int(byt & 0x7f) << sg_shift)
                            sg_shift += 7
                            sg_bi += 1
                            (byt & 0x80) == 0 && break
                        end
                        # Decode field_idx LEB128
                        sg_field_idx = 0
                        sg_shift = 0
                        while sg_bi <= length(stmt_bytes)
                            byt = stmt_bytes[sg_bi]
                            sg_field_idx |= (Int(byt & 0x7f) << sg_shift)
                            sg_shift += 7
                            sg_bi += 1
                            (byt & 0x80) == 0 && break
                        end
                        # Check: is the struct_get the LAST instruction? (sg_bi - 1 == length)
                        if sg_bi - 1 == length(stmt_bytes) && sg_type_idx + 1 <= length(ctx.mod.types)
                            mod_type = ctx.mod.types[sg_type_idx + 1]
                            if mod_type isa StructType && sg_field_idx + 1 <= length(mod_type.fields)
                                field_result_type = mod_type.fields[sg_field_idx + 1].valtype
                                if field_result_type isa ConcreteRef && wasm_types_compatible(local_wasm_type, field_result_type)
                                    # PURE-904: struct_get already produces compatible concrete type.
                                    # Skip SSA type check — it would see Julia Any→ExternRef and
                                    # incorrectly emit any_convert_extern.
                                    struct_get_type_ok = true
                                elseif field_result_type isa ConcreteRef && local_wasm_type isa ConcreteRef
                                    # PURE-9064: Different concrete ref types. The field may return a
                                    # supertype ref (e.g., $JlType from DataType.super) that needs
                                    # downcasting to the target local type (e.g., $JlDataType).
                                    # Use ref.cast instead of type-safe default (ref.null).
                                    needs_ref_cast_local = local_wasm_type
                                elseif (field_result_type === I32 || field_result_type === I64 ||
                                        field_result_type === F32 || field_result_type === F64)
                                    # struct_get produces a numeric value but target local is ref-typed
                                    needs_type_safe_default = true
                                elseif (field_result_type === StructRef || field_result_type === ArrayRef) && local_wasm_type isa ConcreteRef
                                    # struct_get produces abstract ref (structref/arrayref) due to forward-reference
                                    # in struct registration, but the target local expects a concrete ref type.
                                    # Insert ref.cast null to downcast.
                                    needs_ref_cast_local = local_wasm_type
                                elseif field_result_type === ExternRef && local_wasm_type isa ConcreteRef
                                    # struct_get produces externref (Any-typed field) but target local is concrete ref.
                                    # Need any_convert_extern + ref.cast to downcast.
                                    needs_any_convert_extern = true
                                    needs_ref_cast_local = local_wasm_type
                                end
                            end
                        end
                    end
                end

                # Check if the SSA type of this statement maps to a type incompatible
                # with the local. This catches calls, invokes, and compound expressions
                # that produce numeric/externref/abstract ref but get stored in a ref-typed local.
                local_is_ref = local_wasm_type isa ConcreteRef || local_wasm_type === StructRef ||
                               local_wasm_type === ArrayRef || local_wasm_type === ExternRef || local_wasm_type === AnyRef ||
                               local_wasm_type === EqRef
                if !needs_type_safe_default && needs_ref_cast_local === nothing && !struct_get_type_ok && local_is_ref
                    ssa_julia_type = get(ctx.ssa_types, idx, nothing)
                    if ssa_julia_type !== nothing
                        ssa_wasm_type = julia_to_wasm_type_concrete(ssa_julia_type, ctx)
                        if (ssa_wasm_type === I32 || ssa_wasm_type === I64 ||
                            ssa_wasm_type === F32 || ssa_wasm_type === F64)
                            # SSA produces numeric value but local expects ref type
                            # (compound numeric expressions like i32_wrap + i32_sub)
                            needs_type_safe_default = true
                        elseif ssa_wasm_type === ExternRef && local_wasm_type isa ConcreteRef
                            # SSA produces externref but local expects concrete ref.
                            # PURE-325: For memoryrefset! calls, the return value is the
                            # stored element (Any/externref), NOT the array. Casting it to
                            # the local's ConcreteRef type would crash at runtime. Use
                            # type-safe default instead (drop value, push ref.null).
                            local is_memrefset_call = (stmt isa Expr && stmt.head === :call &&
                                length(stmt.args) >= 1 &&
                                stmt.args[1] isa GlobalRef &&
                                (stmt.args[1].mod === Base || stmt.args[1].mod === Core) &&
                                stmt.args[1].name === :memoryrefset!)
                            if is_memrefset_call
                                needs_type_safe_default = true
                            else
                                # Insert: any_convert_extern (externref→anyref) + ref.cast null <type>
                                needs_ref_cast_local = local_wasm_type
                                local _aceb = InstrBuilder(; func_name="compile_statement", strict=false)
                                any_convert_extern!(_aceb)
                                append!(stmt_bytes, builder_code(_aceb))
                            end
                        elseif (ssa_wasm_type === StructRef || ssa_wasm_type === ArrayRef) && local_wasm_type isa ConcreteRef
                            # SSA produces abstract structref/arrayref, local expects concrete ref
                            needs_ref_cast_local = local_wasm_type
                        elseif (ssa_wasm_type isa ConcreteRef || ssa_wasm_type === StructRef || ssa_wasm_type === ArrayRef || ssa_wasm_type === AnyRef) && local_wasm_type === ExternRef
                            # PURE-3113: SSA produces concrete/abstract ref, local expects externref.
                            # This happens with memoryrefset! return values when has_gc_prefix
                            # skips the trailing local.get check. Convert via extern_convert_any.
                            # PURE-6022: But if the callee's actual WASM return type is already
                            # externref, skip the conversion — extern_convert_any expects anyref.
                            callee_already_externref = false
                            if stmt isa Expr && stmt.head === :invoke && length(stmt.args) >= 1
                                mi_or_ci = stmt.args[1]
                                _callee_ret = nothing
                                if isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
                                    _callee_ret = mi_or_ci.rettype
                                elseif mi_or_ci isa Core.MethodInstance && isdefined(mi_or_ci, :rettype)
                                    _callee_ret = mi_or_ci.rettype
                                end
                                if _callee_ret !== nothing
                                    callee_ret_wt = julia_to_wasm_type(_callee_ret)
                                    if callee_ret_wt === ExternRef
                                        callee_already_externref = true
                                    end
                                end
                            elseif stmt isa Expr && stmt.head === :call && length(stmt.args) >= 1
                                callee_func = stmt.args[1]
                                if callee_func isa GlobalRef
                                    sig_ret = julia_to_wasm_type(ssa_julia_type)
                                    if sig_ret === ExternRef
                                        callee_already_externref = true
                                    end
                                end
                            end
                            if !callee_already_externref
                                needs_extern_convert_any = true
                            end
                        end
                        # PURE-036ae: Also check signature-level type mapping.
                        # When a cross-function call returns a struct type, the function's Wasm
                        # signature uses julia_to_wasm_type (returns StructRef) but the local
                        # was allocated using julia_to_wasm_type_concrete (returns ConcreteRef).
                        # Check if the signature-level type is StructRef/ArrayRef.
                        if needs_ref_cast_local === nothing && !needs_type_safe_default && local_wasm_type isa ConcreteRef
                            sig_wasm_type = julia_to_wasm_type(ssa_julia_type)
                            if (sig_wasm_type === StructRef || sig_wasm_type === ArrayRef)
                                # Function signature returns abstract ref, local expects concrete
                                needs_ref_cast_local = local_wasm_type
                                # PURE-900: For invoke/call stmts, the callee's ACTUAL Wasm return
                                # type may be externref (e.g. getindex returning Any). In that case,
                                # we need any_convert_extern before ref_cast.
                                if stmt isa Expr && stmt.head === :invoke && length(stmt.args) >= 1
                                    mi_or_ci2 = stmt.args[1]
                                    _callee_ret2 = nothing
                                    if isdefined(Core, :CodeInstance) && mi_or_ci2 isa Core.CodeInstance
                                        _callee_ret2 = mi_or_ci2.rettype
                                    elseif mi_or_ci2 isa Core.MethodInstance && isdefined(mi_or_ci2, :rettype)
                                        _callee_ret2 = mi_or_ci2.rettype
                                    end
                                    if _callee_ret2 !== nothing
                                        callee_ret_wt = julia_to_wasm_type(_callee_ret2)
                                        if callee_ret_wt === ExternRef
                                            needs_any_convert_extern = true
                                        end
                                    end
                                end
                            end
                        end
                    end
                end

                # PURE-6025: Catch numeric opcodes at end of stmt_bytes that produce numeric
                # values into ref-typed locals. The existing compound-numeric check (line ~15789)
                # is skipped when has_gc_prefix=true, and the SSA type check above misses cases
                # where the Julia type is Any/Union (maps to ExternRef, matching the local) but
                # the actual compiled code produces i64 (e.g., array_len + i64_extend_i32_s).
                # Bytes >= 0x80 at the end of stmt_bytes can't be LEB128 terminal bytes (bit 7
                # clear required), so they're guaranteed to be opcodes. Range 0x80-0xC4 covers
                # i64 arithmetic (0x79-0x8A) and numeric conversions (0xA7-0xC4).
                if !needs_type_safe_default && needs_ref_cast_local === nothing && local_is_ref && length(stmt_bytes) >= 1
                    last_byte = stmt_bytes[end]
                    if last_byte >= 0x80 && last_byte <= 0xC4
                        needs_type_safe_default = true
                    end
                end

                if needs_ref_cast_local !== nothing
                    # PURE-204/6025: Check if stmt_bytes end with a numeric constant (i32.const, i64.const, etc.)
                    # This happens when SSA type is Union{Nothing, T} — ssa_wasm_type maps to T's ConcreteRef,
                    # but the actual value is nothing/integer (e.g., i32.const 0, i64.const 1).
                    # ref.cast requires anyref, not i32/i64. Switch to type_safe_default instead.
                    ends_with_numeric = false
                    if length(stmt_bytes) >= 2
                        # Check for i32.const VALUE or i64.const VALUE where VALUE is a single-byte
                        # LEB128 (high bit clear = terminal byte, values 0-127).
                        # PURE-6025: Previous check only caught value==0x00; now catches any small constant.
                        if (stmt_bytes[end-1] == Opcode.I32_CONST || stmt_bytes[end-1] == Opcode.I64_CONST) && (stmt_bytes[end] & 0x80) == 0
                            ends_with_numeric = true
                        end
                    end
                    if !ends_with_numeric && length(stmt_bytes) >= 3
                        # Check for 2-byte LEB128 values (128-16383): opcode + continuation + terminal
                        if (stmt_bytes[end-2] == Opcode.I32_CONST || stmt_bytes[end-2] == Opcode.I64_CONST) && (stmt_bytes[end-1] & 0x80) != 0 && (stmt_bytes[end] & 0x80) == 0
                            ends_with_numeric = true
                        end
                    end
                    if ends_with_numeric
                        # Numeric constant can't be ref_cast'd — use type_safe_default
                        needs_type_safe_default = true
                        needs_ref_cast_local = nothing
                    else
                        # struct_get produced abstract ref or call returned externref,
                        # need to downcast to concrete type.
                        # PURE-036bj: if source is externref, first convert to anyref
                        # PURE-323: Also check if stmt_bytes ends with local.get of an
                        # externref local. The SSA type check may have set needs_ref_cast_local
                        # based on Julia type (e.g. ArrayRef) without detecting that the actual
                        # wasm local is externref. This happens when has_gc_prefix=true skips
                        # the trailing local.get check at line 13299.
                        if !needs_any_convert_extern && length(stmt_bytes) >= 2
                            for si in length(stmt_bytes):-1:max(1, length(stmt_bytes) - 5)
                                if stmt_bytes[si] == 0x20 && si < length(stmt_bytes)  # LOCAL_GET
                                    tlg_idx_rc = 0
                                    tlg_shift_rc = 0
                                    tlg_end_rc = 0
                                    for bi in (si + 1):length(stmt_bytes)
                                        byt = stmt_bytes[bi]
                                        tlg_idx_rc |= (Int(byt & 0x7f) << tlg_shift_rc)
                                        tlg_shift_rc += 7
                                        if (byt & 0x80) == 0
                                            tlg_end_rc = bi
                                            break
                                        end
                                    end
                                    if tlg_end_rc == length(stmt_bytes)
                                        tlg_arr_rc = tlg_idx_rc - ctx.n_params + 1
                                        if tlg_arr_rc >= 1 && tlg_arr_rc <= length(ctx.locals) && ctx.locals[tlg_arr_rc] === ExternRef
                                            needs_any_convert_extern = true
                                        elseif tlg_idx_rc < ctx.n_params
                                            # Parameter — check its wasm type
                                            param_jt = ctx.arg_types[tlg_idx_rc + 1]
                                            param_wt = get_concrete_wasm_type(param_jt, ctx.mod, ctx.type_registry)
                                            if param_wt === ExternRef
                                                needs_any_convert_extern = true
                                            end
                                        end
                                    end
                                    break
                                elseif stmt_bytes[si] == 0x10 && si < length(stmt_bytes)  # CALL
                                    # PURE-900: Check if call returns externref
                                    # Functions might not be in mod.functions yet during compilation,
                                    # so use func_registry which was pre-populated.
                                    call_idx_rc = 0
                                    call_shift_rc = 0
                                    call_end_rc = 0
                                    for bi in (si + 1):length(stmt_bytes)
                                        byt = stmt_bytes[bi]
                                        call_idx_rc |= (Int(byt & 0x7f) << call_shift_rc)
                                        call_shift_rc += 7
                                        if (byt & 0x80) == 0
                                            call_end_rc = bi
                                            break
                                        end
                                    end
                                    if call_end_rc == length(stmt_bytes)
                                        n_imports = length(ctx.mod.imports)
                                        if call_idx_rc < n_imports
                                            # Imported function — check import's type
                                            imp = ctx.mod.imports[call_idx_rc + 1]
                                            imp_type = ctx.mod.types[imp.type_idx + 1]
                                            if imp_type isa FuncType && !isempty(imp_type.results) && imp_type.results[1] === ExternRef
                                                needs_any_convert_extern = true
                                            end
                                        elseif ctx.func_registry !== nothing
                                            # Look up via func_registry (pre-populated before compilation)
                                            for (_, finfo) in ctx.func_registry.functions
                                                if finfo.wasm_idx == UInt32(call_idx_rc)
                                                    ret_wt = get_concrete_wasm_type(finfo.return_type, ctx.mod, ctx.type_registry)
                                                    if ret_wt === ExternRef
                                                        needs_any_convert_extern = true
                                                    end
                                                    break
                                                end
                                            end
                                        end
                                    end
                                    break
                                end
                            end
                        end
                        # any.convert_extern (optional) + ref.cast null <type_idx>, typed; byte-identical.
                        local _rcb = InstrBuilder(; func_name="compile_statement", strict=false)
                        if needs_any_convert_extern
                            any_convert_extern!(_rcb)
                        end
                        ref_cast!(_rcb, Int64(needs_ref_cast_local.type_idx), true)
                        append!(stmt_bytes, builder_code(_rcb))
                    end
                end

                # PURE-913: ref → externref conversion (e.g., compilerbarrier returning struct into Any local)
                if needs_extern_convert_any
                    local _ecab = InstrBuilder(; func_name="compile_statement", strict=false)
                    extern_convert_any!(_ecab)
                    append!(stmt_bytes, builder_code(_ecab))
                end

                # PURE-3111: Final catch-all for phantom type returns (Nothing/Type{T}).
                # compile_value emits i32_const 0 for these, but SSA type detection may
                # think the value is a ref (e.g., memoryrefset! returns the stored value,
                # which could be Type → SSA type is DataType → ConcreteRef). If stmt_bytes
                # ends with i32_const 0 and the local is ref-typed, override to type_safe_default.
                # PURE-6015: Guard with !has_gc_prefix to avoid false positive on struct.get/array.get
                # whose LEB128 type index bytes can match i32.const (0x41). For example,
                # struct.get 65 0 = [0xFB, 0x02, 0x41, 0x00] where 0x41 = i32.const opcode.
                # The earlier check at line 15046 already uses !has_gc_prefix for the same reason.
                if !needs_type_safe_default && needs_ref_cast_local === nothing && local_is_ref && !has_gc_prefix && length(stmt_bytes) >= 2
                    # PURE-6025: Expanded to catch any small numeric constant, not just i32.const 0.
                    # An i64.const 1 stored into a ref-typed local also needs type_safe_default.
                    # Check 1-byte LEB128 (values 0-63 signed / 0-127 unsigned)
                    if (stmt_bytes[end-1] == Opcode.I32_CONST || stmt_bytes[end-1] == Opcode.I64_CONST) && (stmt_bytes[end] & 0x80) == 0
                        needs_type_safe_default = true
                    end
                    # Check 2-byte LEB128 (values 64-8191): opcode + continuation + terminal
                    # e.g., i32.const 111 = [0x41, 0xEF, 0x00]
                    if !needs_type_safe_default && length(stmt_bytes) >= 3
                        if (stmt_bytes[end-2] == Opcode.I32_CONST || stmt_bytes[end-2] == Opcode.I64_CONST) && (stmt_bytes[end-1] & 0x80) != 0 && (stmt_bytes[end] & 0x80) == 0
                            needs_type_safe_default = true
                        end
                    end
                end

                if needs_type_safe_default
                    haskey(ENV, "WT_TRACE_NULLDEF") && println(stderr,
                        "NULLDEF idx=$idx local_type=$local_wasm_type stmt=", repr(stmt)[1:min(end,120)])
                    ssa_type_mismatch = true
                    # Emit type-safe default instead of the incompatible value (typed via
                    # _append_default!; byte-identical), then local.set via a temp builder.
                    _append_default!(bytes, local_wasm_type)
                    local _tsb = InstrBuilder(; func_name="compile_statement", strict=false)
                    local_set!(_tsb, local_idx)
                    append!(bytes, builder_code(_tsb))
                end
            end
        end

        # Detect statements that push multiple values on the stack.
        # This includes multi-arg memoryrefnew (2 values: arrayref + i32_index)
        # and other array access patterns (base + index local_get pairs).
        # When no SSA local: skip appending (values re-computed on-demand).
        # When SSA local exists: emit type-safe default instead (local_set
        # only consumes 1 value, leaving N-1 orphaned).
        is_orphaned_multi_value = false
        if !isempty(stmt_bytes) && !ssa_type_mismatch
            if !haskey(ctx.ssa_locals, idx) && stmt isa Expr && stmt.head === :call
                func_ref = stmt.args[1]
                is_orphaned_multi_value = (func_ref isa GlobalRef &&
                                           (func_ref.mod === Core || func_ref.mod === Base) &&
                                           func_ref.name === :memoryrefnew &&
                                           length(stmt.args) >= 4)
            end
            # General orphan detection: if stmt_bytes consists entirely of
            # local_get instructions (opcode 0x20 + LEB128 index) pushing 2+ values,
            # it's pure stack-pushing with no side effects. Without proper consumption
            # these values will be orphaned on the stack.
            # This catches base+index pairs from array access patterns.
            if !is_orphaned_multi_value && length(stmt_bytes) >= 4
                all_local_gets = true
                n_gets = 0
                pos = 1
                while pos <= length(stmt_bytes)
                    if stmt_bytes[pos] != 0x20  # LOCAL_GET opcode
                        all_local_gets = false
                        break
                    end
                    n_gets += 1
                    pos += 1
                    # Skip LEB128 local index
                    while pos <= length(stmt_bytes) && (stmt_bytes[pos] & 0x80) != 0
                        pos += 1
                    end
                    pos += 1  # final byte of LEB128
                end
                if all_local_gets && pos > length(stmt_bytes) && n_gets >= 2
                    if haskey(ctx.ssa_locals, idx)
                        # Statement pushes multiple values but has an SSA local.
                        # local_set would only consume 1, leaving N-1 orphaned.
                        # Emit type-safe default for the SSA local instead.
                        local_idx = ctx.ssa_locals[idx]
                        local_array_idx = local_idx - ctx.n_params + 1
                        local_wasm_type = local_array_idx >= 1 && local_array_idx <= length(ctx.locals) ? ctx.locals[local_array_idx] : nothing
                        if local_wasm_type !== nothing
                            # Type-safe default + local.set (typed; byte-identical).
                            _append_default!(bytes, local_wasm_type)
                            local _msb = InstrBuilder(; func_name="compile_statement", strict=false)
                            local_set!(_msb, local_idx)
                            append!(bytes, builder_code(_msb))
                        end
                        ssa_type_mismatch = true  # Prevent double local_set
                    end
                    is_orphaned_multi_value = true
                end
            end
        end

        # Fix for statements with SSA locals that produce multi-value bytecode.
        # When stmt_bytes starts with a "memoryref pair" (local_get X, local_get Y)
        # followed by the SAME pair + an operation, the leading pair is orphaned.
        # Strip the leading orphaned local_gets.
        if !ssa_type_mismatch && !is_orphaned_multi_value && haskey(ctx.ssa_locals, idx) && length(stmt_bytes) >= 8
            # Check if bytes start with local_get X, local_get Y pattern
            if stmt_bytes[1] == 0x20
                # Parse first local_get
                _fg_idx1 = 0; _fg_shift = 0; _fg_end1 = 0
                for _bi in 2:length(stmt_bytes)
                    byt = stmt_bytes[_bi]
                    _fg_idx1 |= (Int(byt & 0x7f) << _fg_shift)
                    _fg_shift += 7
                    if (byt & 0x80) == 0; _fg_end1 = _bi; break; end
                end
                if _fg_end1 > 0 && _fg_end1 < length(stmt_bytes) && stmt_bytes[_fg_end1 + 1] == 0x20
                    # Parse second local_get
                    _fg_idx2 = 0; _fg_shift = 0; _fg_end2 = 0
                    for _bi in (_fg_end1 + 2):length(stmt_bytes)
                        byt = stmt_bytes[_bi]
                        _fg_idx2 |= (Int(byt & 0x7f) << _fg_shift)
                        _fg_shift += 7
                        if (byt & 0x80) == 0; _fg_end2 = _bi; break; end
                    end
                    pair_len = _fg_end2  # Length of the leading pair [get X, get Y]
                    if _fg_end2 > 0 && pair_len < length(stmt_bytes)
                        # Check if the SAME pair appears again after the first pair
                        remaining = @view stmt_bytes[pair_len+1:end]
                        if length(remaining) > pair_len
                            prefix = @view stmt_bytes[1:pair_len]
                            next_prefix = @view remaining[1:pair_len]
                            if prefix == next_prefix
                                # Leading pair is duplicated — strip it (it would be orphaned)
                                stmt_bytes = stmt_bytes[pair_len+1:end]
                            end
                        end
                    end
                end
            end
        end

        if !ssa_type_mismatch && !is_orphaned_multi_value
            append!(bytes, stmt_bytes)
        end

        # PURE-9065: Drop orphaned multi-arg memoryrefnew values for Nothing-typed memory.
        # When MemoryRef{Nothing} is created but never consumed (e.g., rehash! reads keys
        # but skips vals), the [array_ref, i32_index] pair stays on the stack.
        if !is_orphaned_multi_value && !haskey(ctx.ssa_locals, idx) && !isempty(stmt_bytes) &&
           stmt isa Expr && stmt.head === :call && length(stmt.args) >= 3
            call_func = stmt.args[1]
            if (call_func isa GlobalRef && call_func.name === :memoryrefnew) ||
               (call_func === :(Base.memoryrefnew))
                # Multi-arg memoryrefnew with no SSA local — check if result is unused
                ssa_type = get(ctx.ssa_types, idx, Any)
                is_nothing_ref = ssa_type isa DataType && (
                    (ssa_type.name.name === :MemoryRef && length(ssa_type.parameters) >= 1 && ssa_type.parameters[1] === Nothing) ||
                    (ssa_type.name.name === :GenericMemoryRef && length(ssa_type.parameters) >= 2 && ssa_type.parameters[2] === Nothing))
                if is_nothing_ref
                    local _drb = InstrBuilder(; func_name="compile_statement", strict=false)
                    drop!(_drb)  # drop i32_index
                    drop!(_drb)  # drop array_ref
                    append!(bytes, builder_code(_drb))
                end
            end
        end

        # If the statement type is Union{} (bottom/never returns), emit unreachable
        # This handles calls to error/throw functions that have void return type in wasm
        # The unreachable instruction is polymorphic and satisfies any type expectation
        stmt_type_check = get(ctx.ssa_types, idx, Any)
        if stmt_type_check === Union{} && !isempty(stmt_bytes) &&
           !(length(stmt_bytes) >= 1 && stmt_bytes[end] == Opcode.UNREACHABLE)
            local _urb = InstrBuilder(; func_name="compile_statement", strict=false)
            unreachable!(_urb)
            append!(bytes, builder_code(_urb))
        end

        # If this SSA value needs a local, store it (and remove from stack)
        if haskey(ctx.ssa_locals, idx) && !ssa_type_mismatch
            stmt_type = get(ctx.ssa_types, idx, Any)
            is_unreachable_type = stmt_type === Union{}
            # PURE-6005: The bytecode check for DROP+UNREACHABLE (0x1a 0x00) can false-positive
            # on struct_get operands: struct_get type_26 field_0 = [0xfb 0x02 0x1a 0x00]
            # where type_idx=26 (0x1a=DROP) and field_idx=0 (0x00=UNREACHABLE).
            # Guard: also require that no GC_PREFIX (0xfb) appears in the last 4 bytes,
            # since real DROP+UNREACHABLE never follows a GC instruction's operands.
            _has_gc_in_tail = false
            if length(stmt_bytes) >= 3
                for _tbi in max(1, length(stmt_bytes)-3):(length(stmt_bytes)-2)
                    if stmt_bytes[_tbi] == Opcode.GC_PREFIX
                        _has_gc_in_tail = true
                        break
                    end
                end
            end
            is_unreachable_bytecode = (length(stmt_bytes) >= 2 &&
                                       stmt_bytes[end] == Opcode.UNREACHABLE &&
                                       stmt_bytes[end-1] == Opcode.DROP &&
                                       !_has_gc_in_tail) ||
                                      _stmt_ends_unreachable  # PURE-908: catch stub UNREACHABLE
            is_unreachable = is_unreachable_type || is_unreachable_bytecode
            should_store = (!isempty(stmt_bytes) || is_passthrough_statement(stmt, ctx)) && !is_unreachable
            if should_store
                local_idx = ctx.ssa_locals[idx]
                local_array_idx = local_idx - ctx.n_params + 1
                local_type = local_array_idx >= 1 && local_array_idx <= length(ctx.locals) ? ctx.locals[local_array_idx] : nothing


                # PURE-036bg: Check if value type matches local type
                # When multiple SSAs share a local but have incompatible types (e.g., in dead code),
                # DROP the value and emit a type-safe default instead of causing validation error.
                # PURE-4151: If extern_convert_any was already appended above (line ~15272),
                # the stack type is now ExternRef regardless of the original value_wasm_type.
                value_wasm_type = needs_extern_convert_any ? ExternRef : get_concrete_wasm_type(stmt_type, ctx.mod, ctx.type_registry)
                if local_type !== nothing && !wasm_types_compatible(local_type, value_wasm_type)
                    # PURE-908: externref↔anyref conversion instead of drop+default
                    if value_wasm_type === ExternRef && local_type === AnyRef
                        local _cvb = InstrBuilder(; func_name="compile_statement", strict=false)
                        any_convert_extern!(_cvb)
                        append!(bytes, builder_code(_cvb))
                    elseif value_wasm_type === AnyRef && local_type === ExternRef
                        local _cvb = InstrBuilder(; func_name="compile_statement", strict=false)
                        extern_convert_any!(_cvb)
                        append!(bytes, builder_code(_cvb))
                    else
                    # Type mismatch: drop the value and emit type-safe default (typed;
                    # byte-identical; this site has no EqRef arm → eqref=false).
                    local _dvb = InstrBuilder(; func_name="compile_statement", strict=false)
                    drop!(_dvb)
                    append!(bytes, builder_code(_dvb))
                    _append_default!(bytes, local_type; eqref=false)
                    end  # close else from PURE-908 externref↔anyref check
                end
                # CS-004: Cross-function calls may return anyref/structref even when
                # Julia's SSA type says ConcreteRef. Resolve the function reference
                # (which may be an SSAValue pointing to a GlobalRef) and check
                # the callee's wasm return type in the func_registry.
                if (local_type isa ConcreteRef || local_type === StructRef) && ctx.func_registry !== nothing &&
                   stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                    _cs4_func_ref = stmt.head === :invoke ? (length(stmt.args) >= 2 ? stmt.args[2] : nothing) : (length(stmt.args) >= 1 ? stmt.args[1] : nothing)
                    # Dereference SSAValue to find the underlying GlobalRef
                    if _cs4_func_ref isa Core.SSAValue
                        _cs4_src = ctx.code_info.code[_cs4_func_ref.id]
                        if _cs4_src isa GlobalRef
                            _cs4_func_ref = _cs4_src
                        end
                    end
                    if _cs4_func_ref isa GlobalRef
                        try
                            _cs4_func_val = getfield(_cs4_func_ref.mod, _cs4_func_ref.name)
                            if haskey(ctx.func_registry.by_ref, _cs4_func_val)
                                for _fi in ctx.func_registry.by_ref[_cs4_func_val]
                                    _cs4_ret = julia_to_wasm_type(_fi.return_type)
                                    # Cross-function return-type fixups, typed; byte-identical
                                    # (0x6B = UInt8(StructRef) → ref.cast null struct).
                                    local _csb = InstrBuilder(; func_name="compile_statement", strict=false)
                                    if local_type isa ConcreteRef
                                        if _cs4_ret === AnyRef || _cs4_ret === StructRef || _cs4_ret === ArrayRef
                                            ref_cast!(_csb, Int64(local_type.type_idx), true)
                                        elseif _cs4_ret === ExternRef
                                            any_convert_extern!(_csb)
                                            ref_cast!(_csb, Int64(local_type.type_idx), true)
                                        end
                                    elseif local_type === StructRef && _cs4_ret === AnyRef
                                        ref_cast!(_csb, StructRef, true)  # structref heap type
                                    end
                                    append!(bytes, builder_code(_csb))
                                    break  # Use first matching overload
                                end
                            end
                        catch
                        end
                    end
                end

                # PURE-6024: If this is a slot assignment, TEE to slot local first
                # (leaves value on stack for the SSA local.set below). Typed; byte-identical.
                local _slb = InstrBuilder(; func_name="compile_statement", strict=false)
                if _slot_assign_id > 0 && haskey(ctx.slot_locals, _slot_assign_id)
                    local_tee!(_slb, ctx.slot_locals[_slot_assign_id])
                end
                local_set!(_slb, local_idx)
                append!(bytes, builder_code(_slb))
            end
        end
    end

    # PURE-6024: If this is a slot assignment but there's NO SSA local to store to,
    # the value is still on the stack — store it to the slot local directly. Typed.
    if _slot_assign_id > 0 && haskey(ctx.slot_locals, _slot_assign_id) && !haskey(ctx.ssa_locals, idx)
        local _slb2 = InstrBuilder(; func_name="compile_statement", strict=false)
        local_set!(_slb2, ctx.slot_locals[_slot_assign_id])
        append!(bytes, builder_code(_slb2))
    end

    # TRACE: Find double-DROP in compiled output for func 8
    if ctx.func_idx == 8
        n_drops = 0
        for bi in 1:length(bytes)
            if bytes[bi] == 0x1a
                # Check it's really a DROP (not an operand of struct.get etc.)
                # Only count if not preceded by fb 02 (GC struct.get)
                is_struct_get_operand = bi >= 3 && bytes[bi-2] == 0xfb && bytes[bi-1] == 0x02
                if !is_struct_get_operand
                    n_drops += 1
                end
            end
        end
        if n_drops >= 2
            stmt_str = stmt isa Expr ? string(stmt)[1:min(80, length(string(stmt)))] : string(typeof(stmt))
            @debug "STMT $idx has $n_drops DROPs in $(length(bytes)) bytes: $stmt_str"
        end
    end

    emit_raw!(b, bytes)
    return builder_code(b)
end

"""
Compile a struct construction expression (%new).
"""
# P2-batch17: type-correct default for an exception field whose value can't be
# represented (see the Exception branch of compile_new).
# MIGRATED to InstrBuilder: emits the typed zero-const / ref.null directly onto the
# caller's builder `b`. Byte-identical: i32.const 0 = 41 00, f32/f64.const 0 = const op
# + 4/8 zero bytes, ref.null concrete = D0 leb_s(idx), ref.null abstract = D0 heaptype-byte.
function _exn_field_null_or_zero!(b::InstrBuilder, fwasm)
    if fwasm === I32
        i32_const!(b, 0)
    elseif fwasm === I64
        i64_const!(b, 0)
    elseif fwasm === F32
        f32_const!(b, 0.0f0)
    elseif fwasm === F64
        f64_const!(b, 0.0)
    elseif fwasm isa ConcreteRef
        ref_null!(b, Int64(fwasm.type_idx), fwasm)
    elseif fwasm === ExternRef || fwasm === StructRef || fwasm === ArrayRef || fwasm === AnyRef || fwasm === EqRef
        ref_null!(b, fwasm)
    else
        ref_null!(b, StructRef)
    end
    return b
end

# MIGRATED helper: emit the type-safe default (ref.null / zero-const) for `wasm_type`
# into the byte-INSPECTING accumulator `buf` via a throwaway typed InstrBuilder, then
# splice. Byte-identical to the old hand-rolled ref.null/const accumulator blocks:
#   ConcreteRef → D0 leb_s(idx) · abstract ref → D0 heaptype-byte ·
#   i32/i64.const 0 → 41/42 00 · f32/f64.const 0 → const-op + 4/8 zero bytes.
# `eqref` toggles whether EqRef gets an explicit ref.null (some sites had no EqRef arm and
# fell through to the i32.const-0 else — pass eqref=false to reproduce that exactly).
function _append_default!(buf::Vector{UInt8}, wasm_type; eqref::Bool=true)
    tb = InstrBuilder(; func_name="_append_default", strict=false)
    if wasm_type isa ConcreteRef
        ref_null!(tb, Int64(wasm_type.type_idx), wasm_type)
    elseif wasm_type === ExternRef
        ref_null!(tb, ExternRef)
    elseif wasm_type === StructRef
        ref_null!(tb, StructRef)
    elseif wasm_type === ArrayRef
        ref_null!(tb, ArrayRef)
    elseif wasm_type === AnyRef
        ref_null!(tb, AnyRef)
    elseif eqref && wasm_type === EqRef
        ref_null!(tb, EqRef)
    elseif wasm_type === I64
        i64_const!(tb, 0)
    elseif wasm_type === I32
        i32_const!(tb, 0)
    elseif wasm_type === F64
        f64_const!(tb, 0.0)
    elseif wasm_type === F32
        f32_const!(tb, 0.0f0)
    else
        i32_const!(tb, 0)
    end
    append!(buf, builder_code(tb))
    return buf
end

function compile_new(expr::Expr, idx::Int, ctx::AbstractCompilationContext)::Vector{UInt8}
    # MIGRATED to InstrBuilder: straight-line emission goes through typed methods on `b`
    # in source order; field-value branches build local `_bytes` buffers and LEB-decode
    # them (the LOCAL_GET source-type checks) then splice via emit_raw!; external emit_*!
    # helpers (emit_unsupported_stub!, emit_type_id!, _exn_field_null_or_zero!) build into
    # a local temp buffer then bridge via emit_raw!. Stays strict=false (byte-inspecting).
    b = InstrBuilder(; func_name="compile_new", strict=false)

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
            _stub = UInt8[]
            emit_unsupported_stub!(ctx, _stub, :unsupported_type,
                "struct construction (:new) with a non-constant type — type instability"; idx=idx,
                detail=ssa_type)
            emit_raw!(b, _stub)
            return builder_code(b)
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
            _stub = UInt8[]
            emit_unsupported_stub!(ctx, _stub, :unsupported_type,
                "struct construction (:new) with an unresolvable type — type instability"; idx=idx,
                detail=new_ssa_type)
            emit_raw!(b, _stub)
            return builder_code(b)
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
        emit_value!(b, field_values[1], ctx)
        return builder_code(b)
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

        # field 0: typeId (i32) - PURE-9024
        i32_const!(b, 0)

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
        struct_new!(b, dict_info.wasm_type_idx, WasmValType[])

        return builder_code(b)
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

        # field 0: typeId (i32) - PURE-9024
        i32_const!(b, 0)

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
        field0_bytes = compile_value(field_values[1], ctx)
        if is_multi_arg_memref
            # Multi-arg memoryrefnew pushed [array_ref, i32_index] — drop the i32 index
            push!(field0_bytes, Opcode.DROP)
        end
        if length(field0_bytes) >= 2 && field0_bytes[1] == 0x20  # LOCAL_GET = 0x20
            src_idx = 0; shift = 0
            for bi in 2:length(field0_bytes)
                byt = field0_bytes[bi]
                src_idx |= (Int(byt & 0x7f) << shift)
                shift += 7
                (byt & 0x80) == 0 && break
            end
            arr_idx = src_idx - ctx.n_params + 1
            if arr_idx >= 1 && arr_idx <= length(ctx.locals)
                src_type = ctx.locals[arr_idx]
                if src_type === I64 || src_type === I32
                    # PURE-325: The local has numeric type but Vector field 0 needs an array ref.
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
                                field0_bytes = compile_call(src_stmt_f0, field_values[1].id, ctx)
                                recompiled = true
                            end
                        end
                        # Also check if source is a PiNode wrapping a memoryrefnew
                        if !recompiled && src_stmt_f0 isa Core.PiNode
                            field0_bytes = compile_value(src_stmt_f0.val, ctx)
                            recompiled = true
                        end
                    end
                    if !recompiled
                        # Non-Array AbstractVector (UnitRange, StepRange) — use ref.null
                        data_array_idx = get_array_type!(ctx.mod, ctx.type_registry, eltype(struct_type))
                        field0_bytes = UInt8[]
                        push!(field0_bytes, Opcode.REF_NULL)
                        append!(field0_bytes, encode_leb128_signed(Int64(data_array_idx)))
                    end
                end
            end
        end
        emit_raw!(b, field0_bytes)

        # Compile field 2: the size tuple (field 0=typeId, field 1=array_ref, field 2=size_tuple)
        if length(field_values) >= 2
            field1_bytes = compile_value(field_values[2], ctx)
            if length(field1_bytes) >= 2 && field1_bytes[1] == Opcode.LOCAL_GET
                src_idx = 0; shift = 0
                for bi in 2:length(field1_bytes)
                    byt = field1_bytes[bi]
                    src_idx |= (Int(byt & 0x7f) << shift)
                    shift += 7
                    (byt & 0x80) == 0 && break
                end
                arr_idx = src_idx - ctx.n_params + 1
                if arr_idx >= 1 && arr_idx <= length(ctx.locals)
                    src_type = ctx.locals[arr_idx]
                    if src_type === I64 || src_type === I32
                        # Emit ref.null for the size tuple type instead
                        size_tuple_type_inner = Tuple{Int64}
                        if !haskey(ctx.type_registry.structs, size_tuple_type_inner)
                            register_tuple_type!(ctx.mod, ctx.type_registry, size_tuple_type_inner)
                        end
                        size_info_inner = ctx.type_registry.structs[size_tuple_type_inner]
                        field1_bytes = UInt8[]
                        push!(field1_bytes, Opcode.REF_NULL)
                        append!(field1_bytes, encode_leb128_signed(Int64(size_info_inner.wasm_type_idx)))
                    end
                end
            end
            emit_raw!(b, field1_bytes)
        else
            # No size provided - get array length and create tuple
            # Create Tuple{Int64} struct (typeId + i64 value)
            size_tuple_type = Tuple{Int64}
            if !haskey(ctx.type_registry.structs, size_tuple_type)
                register_tuple_type!(ctx.mod, ctx.type_registry, size_tuple_type)
            end
            size_info = ctx.type_registry.structs[size_tuple_type]
            # PURE-9024: Push typeId first, then compute i64 value
            i32_const!(b, 0)  # typeId = 0
            # Push array ref again for array.len
            emit_value!(b, field_values[1], ctx)
            array_len!(b)
            num!(b, Opcode.I64_EXTEND_I32_S)
            struct_new!(b, size_info.wasm_type_idx, WasmValType[])
        end

        # Create the Vector struct (already has typeId from above)
        struct_new!(b, vec_info.wasm_type_idx, WasmValType[])
        return builder_code(b)
    end

    # PURE-049: MemoryRef/Memory construction — in WasmGC these are array refs, not structs.
    # :new(MemoryRef{T}, mem, ptr_or_offset) → just pass through the mem (array ref).
    # :new(Memory{T}, ...) → emit ref.null of the array type (Memory is backing storage).
    if struct_type isa DataType && struct_type.name.name in (:MemoryRef, :GenericMemoryRef)
        # MemoryRef{T} — field_values[1] is the Memory (= our array ref), field_values[2] is offset
        if length(field_values) >= 1
            emit_value!(b, field_values[1], ctx)
        else
            elem_type = struct_type.name.name === :GenericMemoryRef ? struct_type.parameters[2] : struct_type.parameters[1]
            array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
            ref_null!(b, Int64(array_type_idx), ConcreteRef(UInt32(array_type_idx), true))
        end
        return builder_code(b)
    end
    if struct_type isa DataType && struct_type.name.name in (:Memory, :GenericMemory)
        # Memory{T} — emit ref.null of the array type (we can't construct raw memory in Wasm)
        elem_type = eltype(struct_type)
        array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
        ref_null!(b, Int64(array_type_idx), ConcreteRef(UInt32(array_type_idx), true))
        return builder_code(b)
    end

    # PURE-325 / P2-batch17: Error constructors used to compile to a bare
    # `unreachable` on the theory that they're always followed by throw(). With
    # CATCHABLE throws that arm is live: `try checked_abs(typemin) catch` must
    # reach the tag-0 throw, and an unreachable before it is an uncatchable trap
    # (gap 6d3a1788a329 layer 3). Construct the struct for real; any field whose
    # wasm type can't accept the value (AbstractString field ← LazyString value,
    # the original PURE-325 mismatch) gets ref.null instead — the exception's
    # typeid survives for `e isa T`, only the lazy message payload is dropped.
    if struct_type <: Exception
        if !haskey(ctx.type_registry.structs, struct_type)
            try
                register_struct_type!(ctx.mod, ctx.type_registry, struct_type)
            catch
            end
        end
        _exn_info = get(ctx.type_registry.structs, struct_type, nothing)
        _exn_def = _exn_info === nothing ? nothing : ctx.mod.types[_exn_info.wasm_type_idx + 1]
        if _exn_info === nothing || !(_exn_def isa StructType)
            unreachable!(b)
            return builder_code(b)
        end
        if _exn_info.field_offset > 0
            _tid = UInt8[]
            emit_type_id!(_tid, ctx.type_registry, struct_type)
            emit_raw!(b, _tid)
        end
        for (fi, val) in enumerate(field_values)
            _wfi = fi + Int(_exn_info.field_offset)
            _fwasm = _wfi <= length(_exn_def.fields) ? _exn_def.fields[_wfi].valtype : nothing
            _vwasm = try infer_value_wasm_type(val, ctx) catch; nothing end
            _emitted = false
            if _fwasm !== nothing && _vwasm !== nothing
                if _fwasm === _vwasm
                    emit_value!(b, val, ctx)
                    _emitted = true
                elseif _fwasm isa ConcreteRef && (_vwasm === StructRef || _vwasm === AnyRef || _vwasm === EqRef)
                    emit_value!(b, val, ctx)
                    ref_cast!(b, Int64(_fwasm.type_idx), true)
                    _emitted = true
                elseif (_fwasm === AnyRef || _fwasm === EqRef) && (_vwasm isa ConcreteRef || _vwasm === StructRef || _vwasm === ArrayRef)
                    emit_value!(b, val, ctx)
                    _emitted = true
                elseif _fwasm === StructRef && _vwasm isa ConcreteRef
                    # Only struct-typed concrete refs subsume into structref (arrays don't)
                    _vdef = ctx.mod.types[_vwasm.type_idx + 1]
                    if _vdef isa StructType
                        emit_value!(b, val, ctx)
                        _emitted = true
                    end
                elseif _fwasm === ExternRef && (_vwasm isa ConcreteRef || _vwasm === StructRef || _vwasm === ArrayRef || _vwasm === AnyRef || _vwasm === EqRef)
                    emit_value!(b, val, ctx)
                    extern_convert_any!(b)
                    _emitted = true
                end
            end
            if !_emitted
                _exn_field_null_or_zero!(b, _fwasm)
            end
        end
        # :new may carry FEWER args than fields (trailing fields undef) — pad
        # them, or struct.new pops the typeid as a field value and fails to
        # validate ("expected anyref, found i32").
        _n_wasm_fields = length(_exn_def.fields)
        for _pad_fi in (length(field_values) + Int(_exn_info.field_offset) + 1):_n_wasm_fields
            _exn_field_null_or_zero!(b, _exn_def.fields[_pad_fi].valtype)
        end
        struct_new!(b, _exn_info.wasm_type_idx, WasmValType[])
        return builder_code(b)
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
    if info.field_offset > 0
        _tid = UInt8[]
        emit_type_id!(_tid, ctx.type_registry, struct_type)
        emit_raw!(b, _tid)
    end

    # Push field values in order, handling Union field types
    for (i, val) in enumerate(field_values)
        field_type = info.field_types[i]

        # Check if this field is a Union type that needs wrapping
        if field_type isa Union && needs_tagged_union(field_type)
            # Get the value's actual type
            val_type = if val isa Core.SSAValue
                get(ctx.ssa_types, val.id, Any)
            elseif val isa Core.Argument
                # Core.Argument(n) is an IR node for the nth argument; look up its declared type.
                # PURE-6025: For non-closures, Core.Argument(1) is #self#, so subtract 1.
                local arg_idx_fix = ctx.is_compiled_closure ? val.n : val.n - 1
                (arg_idx_fix >= 1 && arg_idx_fix <= length(ctx.arg_types)) ? ctx.arg_types[arg_idx_fix] : Any
            elseif val isa GlobalRef
                actual_val = try getfield(val.mod, val.name) catch; nothing end
                typeof(actual_val)
            else
                typeof(val)
            end

            # Compile the value first
            emit_value!(b, val, ctx)

            # If val_type is already a union (tagged union struct on stack), don't re-wrap
            if !(val_type isa Union && val_type <: field_type)
                emit_raw!(b, emit_wrap_union_value(ctx, val_type, field_type))
            end
        elseif field_type isa Union
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
                    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
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
                # Non-null value — typed channel: the emission's own type replaces the pure-
                # local.get LEB scan + infer_value_wasm_type re-guess. A NUMERIC value into a
                # ref-typed Union field is an ill-typed store (bad upstream inference); keep
                # the type-correct null so the module validates (M5 turns this loud).
                val_bytes, _cn_vty = compile_value_typed(val, ctx)
                if inner_type !== nothing &&
                   (_cn_vty === I32 || _cn_vty === I64 || _cn_vty === F32 || _cn_vty === F64)
                    if inner_type === String || inner_type === Symbol
                        str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
                        ref_null!(b, Int64(str_type_idx), ConcreteRef(UInt32(str_type_idx), true))
                    elseif inner_type <: AbstractVector
                        elem_type = eltype(inner_type)
                        arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
                        ref_null!(b, Int64(arr_type_idx), ConcreteRef(UInt32(arr_type_idx), true))
                    elseif haskey(ctx.type_registry.structs, inner_type)
                        inner_info = ctx.type_registry.structs[inner_type]
                        ref_null!(b, Int64(inner_info.wasm_type_idx), ConcreteRef(UInt32(inner_info.wasm_type_idx), true))
                    else
                        ref_null!(b, StructRef)
                    end
                else
                    emit_raw!(b, val_bytes; pushes=(_cn_vty === nothing ? WasmValType[] : WasmValType[_cn_vty]))
                end
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
                    _n2a = UInt8[]
                    emit_numeric_to_anyref!(_n2a, val, val_wasm_type, ctx)
                    emit_raw!(b, _n2a)
                else
                    emit_value!(b, val, ctx)
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
            # Regular field - compile value directly
            # Safety: if compile_value produces a local.get of a numeric local (i64/i32)
            # but the field expects a ref type, emit ref.null instead.
            # This happens when phi/PiNode locals are allocated as i64 (due to Union/Any
            # type inference) but the struct field requires a concrete ref.

            # Look up the actual Wasm field type from the module's type definition
            actual_field_wasm = nothing
            struct_type_def = ctx.mod.types[info.wasm_type_idx + 1]
            local _wasm_fi2 = i + Int(info.field_offset)  # PURE-9024: skip typeId
            if struct_type_def isa StructType && _wasm_fi2 <= length(struct_type_def.fields)
                actual_field_wasm = struct_type_def.fields[_wasm_fi2].valtype
            end

            # TRUE-INT-002: Handle `nothing` literal for ref-typed struct fields.
            # compile_value(nothing) always emits i32_const 0, but ref-typed fields
            # (AnyRef, EqRef, StructRef, etc.) need ref.null instead.
            # This occurs for Nothing-typed fields (e.g., InplaceCompilationContext.signal_ssa_getters::Nothing)
            # when register_struct_type! maps Nothing to AnyRef/EqRef.
            # The `nothing` can appear as: literal, GlobalRef(:nothing), or SSAValue with Nothing type
            # (from inlined kwarg constructor defaults).
            is_literal_nothing_reg = val === nothing ||
                (val isa GlobalRef && val.name === :nothing) ||
                (val isa GlobalRef && (try getfield(val.mod, val.name) === nothing catch; false end)) ||
                (val isa Core.SSAValue && 1 <= val.id <= length(ctx.code_info.ssavaluetypes) &&
                    ctx.code_info.ssavaluetypes[val.id] === Nothing) ||
                (val isa Core.SSAValue && 1 <= val.id <= length(ctx.code_info.code) && begin
                    _ssa_stmt = ctx.code_info.code[val.id]
                    _ssa_stmt === nothing ||
                    (_ssa_stmt isa GlobalRef && _ssa_stmt.name === :nothing) ||
                    (_ssa_stmt isa GlobalRef && (try getfield(_ssa_stmt.mod, _ssa_stmt.name) === nothing catch; false end))
                end)
            if is_literal_nothing_reg && actual_field_wasm !== nothing &&
               (actual_field_wasm isa ConcreteRef || actual_field_wasm === StructRef ||
                actual_field_wasm === ArrayRef || actual_field_wasm === AnyRef ||
                actual_field_wasm === ExternRef || actual_field_wasm === EqRef)
                if actual_field_wasm isa ConcreteRef
                    ref_null!(b, Int64(actual_field_wasm.type_idx), ConcreteRef(UInt32(actual_field_wasm.type_idx), true))
                elseif actual_field_wasm === AnyRef
                    ref_null!(b, AnyRef)  # any heap type
                elseif actual_field_wasm === EqRef
                    ref_null!(b, EqRef)  # eq heap type
                elseif actual_field_wasm === ArrayRef
                    ref_null!(b, ArrayRef)
                elseif actual_field_wasm === ExternRef
                    ref_null!(b, ExternRef)
                else
                    ref_null!(b, StructRef)
                end
                continue  # Skip to next field — ref.null already emitted
            end

            field_bytes = compile_value(val, ctx)
            # Safety: if field_bytes is empty (SSA without local, not re-compilable)
            # and the field expects a ref type, emit ref.null of the correct type.
            if isempty(field_bytes) && actual_field_wasm !== nothing &&
               (actual_field_wasm isa ConcreteRef || actual_field_wasm === StructRef ||
                actual_field_wasm === ArrayRef || actual_field_wasm === AnyRef || actual_field_wasm === ExternRef)
                if actual_field_wasm isa ConcreteRef
                    ref_null!(b, Int64(actual_field_wasm.type_idx), ConcreteRef(UInt32(actual_field_wasm.type_idx), true))
                elseif actual_field_wasm === ArrayRef
                    ref_null!(b, ArrayRef)
                elseif actual_field_wasm === ExternRef
                    ref_null!(b, ExternRef)
                else
                    ref_null!(b, StructRef)
                end
                field_bytes = UInt8[]
            elseif isempty(field_bytes) && actual_field_wasm !== nothing &&
                   (actual_field_wasm === I32 || actual_field_wasm === I64 ||
                    actual_field_wasm === F32 || actual_field_wasm === F64)
                # Empty bytes for numeric field — emit zero constant
                if actual_field_wasm === I32
                    i32_const!(b, 0)
                elseif actual_field_wasm === I64
                    i64_const!(b, 0)
                elseif actual_field_wasm === F32
                    f32_const!(b, 0.0f0)
                elseif actual_field_wasm === F64
                    f64_const!(b, 0.0)
                end
                field_bytes = UInt8[]
            end
            # Union-typed field (no Nothing variant) registered as a tagged-union
            # B4/U2: the union-field tagged-union-wrapper box-coercion is RETIRED — a union
            # field is AnyRef (the classId box / struct ref), never the {typeId,tag,value}
            # wrapper ConcreteRef, so the value flows in as an anyref subtype directly.
            if actual_field_wasm !== nothing && (actual_field_wasm isa ConcreteRef || actual_field_wasm === StructRef || actual_field_wasm === ArrayRef || actual_field_wasm === AnyRef || actual_field_wasm === ExternRef) && length(field_bytes) >= 2 && field_bytes[1] == 0x20
                # dart2wasm carries the type with the value: derive the source's wasm type
                # from the inferred value type rather than decoding the local index out of bytes.
                src_type = infer_value_wasm_type(val, ctx)
                if src_type !== nothing && (src_type === I64 || src_type === I32 || src_type === F32 || src_type === F64)
                    # Source local is numeric but field expects ref — box or emit ref.null
                    # Use the ACTUAL field type from the struct definition
                    if actual_field_wasm isa ConcreteRef
                        ref_null!(b, Int64(actual_field_wasm.type_idx), ConcreteRef(UInt32(actual_field_wasm.type_idx), true))
                    elseif actual_field_wasm === ArrayRef
                        ref_null!(b, ArrayRef)
                    elseif actual_field_wasm === AnyRef
                        # Box numeric local for anyref field via THE single box emitter.
                        emit_raw!(b, field_bytes; pushes=WasmValType[src_type])
                        emit_classid_box!(b, ctx, src_type, nothing)
                    elseif actual_field_wasm === ExternRef
                        # PURE-6024: Box numeric local → box struct → extern_convert_any via the one emitter.
                        emit_raw!(b, field_bytes; pushes=WasmValType[src_type])
                        emit_classid_box!(b, ctx, src_type, nothing)
                        extern_convert_any!(b)
                    else
                        ref_null!(b, StructRef)
                    end
                    field_bytes = UInt8[]  # Don't append original
                elseif actual_field_wasm === ExternRef && src_type !== nothing && src_type !== ExternRef
                    # PURE-046: Source is a concrete ref but field expects externref
                    # (e.g., abstract type field like AbstractInterpreter registered as externref)
                    # Need to convert concrete ref to externref using extern.convert_any
                    emit_raw!(b, field_bytes)
                    extern_convert_any!(b)
                    field_bytes = UInt8[]  # Already appended
                elseif actual_field_wasm === ExternRef && src_type !== nothing && src_type === ExternRef
                    # PURE-6025: Source IS already externref, field expects externref — no conversion needed.
                    # Must explicitly handle to prevent the catch-all below from emitting EXTERN_CONVERT_ANY
                    # which expects anyref input and would fail on externref.
                    emit_raw!(b, field_bytes)
                    field_bytes = UInt8[]  # Already appended — prevent catch-all
                elseif actual_field_wasm isa ConcreteRef && src_type !== nothing &&
                       (src_type === StructRef || src_type === AnyRef || src_type === EqRef)
                    # PURE-701b: field expects a CONCRETE struct ref but the source
                    # local/param is abstract (structref/anyref/eqref). This hits
                    # "numeric struct" types like RGB{N0f8}/Complex/Rational whose
                    # params are typed `structref` by get_concrete_wasm_type (they are
                    # `<: Number`, so is_struct_type returns false) while the struct
                    # field is registered with the concrete type. Without a cast,
                    # struct.new fails:
                    #   struct.new[k] expected (ref null T), found local.get of type structref
                    # ref.cast null $T narrows it (no-op when already T, traps otherwise),
                    # mirroring emit_ref_cast_if_structref! on the struct.get side.
                    emit_raw!(b, field_bytes)
                    ref_cast!(b, Int64(actual_field_wasm.type_idx), true)
                    field_bytes = UInt8[]  # Already appended
                end
            end
            # PURE-6025: Handle global.get sources (0x23) for externref field conversion.
            # Same pattern as local.get above but looks up source type from module globals.
            if actual_field_wasm === ExternRef && !isempty(field_bytes) && field_bytes[1] == 0x23
                # Decode global index from LEB128
                g_idx = 0; g_shift = 0
                for bi in 2:length(field_bytes)
                    byt = field_bytes[bi]
                    g_idx |= (Int(byt & 0x7f) << g_shift)
                    g_shift += 7
                    (byt & 0x80) == 0 && break
                end
                if g_idx + 1 <= length(ctx.mod.globals)
                    g_type = ctx.mod.globals[g_idx + 1].valtype
                    if g_type !== ExternRef
                        # Source global is concrete ref but field expects externref
                        emit_raw!(b, field_bytes)
                        extern_convert_any!(b)
                        field_bytes = UInt8[]
                    end
                end
            end
            # WASMMAKIE E-003: inline-expression sources (e.g. a nested
            # struct.new result) aren't covered by the local.get/global.get
            # byte-pattern checks above — bridge by the value's INFERRED wasm
            # type instead (wilkinson's kwarg structs pushed (ref $t) into
            # externref fields and failed validation).
            if actual_field_wasm === ExternRef && !isempty(field_bytes) &&
               field_bytes[1] != 0x20 && field_bytes[1] != 0x23 && field_bytes[1] != 0xD0
                _inline_vw = try infer_value_wasm_type(val, ctx) catch; nothing end
                if _inline_vw !== nothing && (_inline_vw isa ConcreteRef || _inline_vw === StructRef ||
                                              _inline_vw === ArrayRef || _inline_vw === AnyRef || _inline_vw === EqRef)
                    emit_raw!(b, field_bytes)
                    extern_convert_any!(b)
                    field_bytes = UInt8[]
                end
            end
            # PURE-906: Check if field expects numeric but source is ref-typed (externref/anyref).
            # This happens when Julia's convert(Bool, x)::Any SSA is typed ExternRef
            # but the struct field is Bool (i32). Emit zero default for the numeric field.
            # PURE-6024: Also catch ref.null (0xD0) values for numeric fields.
            if actual_field_wasm !== nothing && (actual_field_wasm === I32 || actual_field_wasm === I64 || actual_field_wasm === F32 || actual_field_wasm === F64) && !isempty(field_bytes) && field_bytes[1] == 0xD0
                # ref.null used for numeric field — emit zero constant instead
                if actual_field_wasm === I32
                    i32_const!(b, 0)
                elseif actual_field_wasm === I64
                    i64_const!(b, 0)
                elseif actual_field_wasm === F32
                    f32_const!(b, 0.0f0)
                elseif actual_field_wasm === F64
                    f64_const!(b, 0.0)
                end
                field_bytes = UInt8[]  # Don't append original ref.null
            elseif actual_field_wasm !== nothing && (actual_field_wasm === I32 || actual_field_wasm === I64 || actual_field_wasm === F32 || actual_field_wasm === F64) && !isempty(field_bytes) && length(field_bytes) >= 2 && field_bytes[1] == 0x20
                # Decode source local index
                src_idx_906 = 0; shift_906 = 0; leb_end_906 = 0
                for bi in 2:length(field_bytes)
                    byt = field_bytes[bi]
                    src_idx_906 |= (Int(byt & 0x7f) << shift_906)
                    shift_906 += 7
                    if (byt & 0x80) == 0
                        leb_end_906 = bi
                        break
                    end
                end
                if leb_end_906 == length(field_bytes)  # Pure local.get
                    # dart2wasm carries the type with the value: derive the source's wasm type
                    # from the inferred value type rather than decoding the local index.
                    src_type_906 = infer_value_wasm_type(val, ctx)
                    if src_type_906 !== nothing && (src_type_906 === ExternRef || src_type_906 === AnyRef || src_type_906 isa ConcreteRef || src_type_906 === StructRef)
                        # Source is ref-typed but field expects numeric — emit zero default
                        if actual_field_wasm === I32
                            i32_const!(b, 0)
                        elseif actual_field_wasm === I64
                            i64_const!(b, 0)
                        elseif actual_field_wasm === F32
                            f32_const!(b, 0.0f0)
                        elseif actual_field_wasm === F64
                            f64_const!(b, 0.0)
                        end
                        field_bytes = UInt8[]  # Don't append original
                    end
                end
            end
            # PURE-6024: If the field expects externref but field_bytes is non-empty and
            # hasn't been handled above (not local.get, not ref.null), the compiled value
            # is likely a concrete ref (from struct_new, struct_get, call, etc.) that needs
            # extern_convert_any. This complements the local.get check at line ~16464.
            if actual_field_wasm === ExternRef && !isempty(field_bytes)
                last_is_extern_convert = length(field_bytes) >= 2 &&
                                         field_bytes[end-1] == Opcode.GC_PREFIX &&
                                         field_bytes[end] == Opcode.EXTERN_CONVERT_ANY
                first_is_ref_null_extern = length(field_bytes) >= 2 &&
                                           field_bytes[1] == Opcode.REF_NULL &&
                                           field_bytes[2] == UInt8(ExternRef)
                first_is_numeric = !isempty(field_bytes) &&
                                   (field_bytes[1] == Opcode.I32_CONST || field_bytes[1] == Opcode.I64_CONST ||
                                    field_bytes[1] == Opcode.F32_CONST || field_bytes[1] == Opcode.F64_CONST) &&
                                   !_wt_is_ref(infer_value_wasm_type(val, ctx))
                if !last_is_extern_convert && !first_is_ref_null_extern && !first_is_numeric
                    emit_raw!(b, field_bytes)
                    extern_convert_any!(b)
                    field_bytes = UInt8[]  # Already appended
                elseif first_is_numeric
                    # Numeric value for externref field — emit ref.null extern
                    ref_null!(b, ExternRef)
                    field_bytes = UInt8[]  # Don't append original
                end
            end
            emit_raw!(b, field_bytes)
        end
    end

    # If field_values provides fewer values than the struct's actual Wasm field count,
    # emit default values for the missing fields. This happens when Julia's :new expression
    # constructs a struct with uninitialized fields (e.g., RefValue{NTuple{50, UInt8}}).
    struct_type_def = ctx.mod.types[info.wasm_type_idx + 1]
    if struct_type_def isa StructType
        n_provided = length(field_values)
        n_required = length(struct_type_def.fields)
        # PURE-9024: n_provided counts Julia fields. typeId (field 0) was already pushed above.
        # Missing Wasm fields start after typeId offset + provided Julia fields.
        n_wasm_provided = n_provided + Int(info.field_offset)
        for fi in (n_wasm_provided + 1):n_required
            missing_field_type = struct_type_def.fields[fi].valtype
            if missing_field_type isa ConcreteRef
                ref_null!(b, Int64(missing_field_type.type_idx), ConcreteRef(UInt32(missing_field_type.type_idx), true))
            elseif missing_field_type === StructRef
                ref_null!(b, StructRef)
            elseif missing_field_type === ArrayRef
                ref_null!(b, ArrayRef)
            elseif missing_field_type === ExternRef
                ref_null!(b, ExternRef)
            elseif missing_field_type === AnyRef
                ref_null!(b, AnyRef)
            elseif missing_field_type === I64
                i64_const!(b, 0)
            elseif missing_field_type === I32
                i32_const!(b, 0)
            elseif missing_field_type === F64
                f64_const!(b, 0.0)
            elseif missing_field_type === F32
                f32_const!(b, 0.0f0)
            else
                i32_const!(b, 0)
            end
        end
    end

    # struct.new type_idx
    struct_new!(b, info.wasm_type_idx, WasmValType[])

    return builder_code(b)
end

"""
Compile a foreign call expression.
Handles specific patterns like jl_alloc_genericmemory for Vector allocation.
"""
function compile_foreigncall(expr::Expr, idx::Int, ctx::AbstractCompilationContext)::Vector{UInt8}
    # MIGRATED to InstrBuilder: straight-line emission goes through typed methods on `b`
    # in source order; compile_value splices bridge via emit_raw!; external emit_*! helpers
    # and recursive emitter results bridge via emit_raw! too. Stays strict=false.
    b = InstrBuilder(; func_name="compile_foreigncall", strict=false)

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
                get_string_array_type!(ctx.mod, ctx.type_registry)
            else
                get_array_type!(ctx.mod, ctx.type_registry, elem_type)
            end

            # Compile length argument
            if len_arg !== nothing
                emit_value!(b, len_arg, ctx)
                len_type = infer_value_type(len_arg, ctx)
                if len_type === Int64 || len_type === Int
                    num!(b, Opcode.I32_WRAP_I64)
                end
            else
                # Default length of 0
                i32_const!(b, 0)
            end

            # array.new_default creates array filled with default value (0 for primitives, null for refs)
            array_new_default!(b, arr_type_idx)

            return builder_code(b)
        elseif name === :memset
            # WBUILD-5501: memset(ptr, value, size) — fill memory with a byte value.
            # CORRECT BY DESIGN for zero-fill: WasmGC arrays are zero-initialized by
            # array.new_default, so memset(ptr, 0, size) is a no-op. All current callers
            # (Dict/Set constructor, rehash!) use value=0 (a literal 0x00).
            # SOUNDNESS: a *literal* non-zero fill would silently produce wrong results,
            # so we refuse it (foreigncall args: [name,rt,argtypes,nreq,cc, ptr, value, size]).
            if length(expr.args) >= 7 && (expr.args[7] isa Number) && !iszero(expr.args[7])
                record_unsupported!(ctx, :value_stub, "memset with a non-zero constant fill value"; idx=idx, detail=expr)
                unreachable!(b)  # non-strict path: trap rather than mis-fill
                ctx.last_stmt_was_stub = true
                return builder_code(b)
            end
            # Zero-fill no-op. memset returns the ptr, but only materialise it when
            # the result is actually stored (ssa_local exists). Unconditionally
            # pushing it orphaned a stub value on the stack: callers (Dict ctor,
            # rehash!) discard the result, and statement_produces_wasm_value treats
            # the Ptr-typed foreigncall as void so no DROP follows. Latent until a
            # reachable block `end` closed over the orphan (P2-batch23, gaps
            # 4be58371947f / 203da15d789c).
            if length(expr.args) >= 6 && haskey(ctx.ssa_locals, idx)
                emit_value!(b, expr.args[6], ctx)
            end
            return builder_code(b)
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
                    return builder_code(b)
                end
            end
            # Non-literal args: fall through to the unknown-foreigncall stub below
        elseif name === :jl_object_id
            # jl_object_id(x) → UInt64: identity hash. There is no correct WasmGC
            # implementation yet (no stable per-object identity). The previous stub
            # returned array.len for strings and a constant 42 otherwise — both silently
            # wrong (constant 42 collides every object to one hash bucket). Refuse instead.
            # Dict/Set hashing does NOT route through here (it uses Base.hash, pure Julia),
            # so this should be unreachable in practice; if it fires, it's a real gap.
            record_unsupported!(ctx, :value_stub, "objectid / identity-hash (jl_object_id)"; idx=idx, detail=expr)
            unreachable!(b)  # non-strict path: trap rather than return a fake hash
            ctx.last_stmt_was_stub = true
            return builder_code(b)
        elseif name === :jl_string_to_genericmemory
            # Convert String to Memory{UInt8}
            # In WasmGC, String and Memory{UInt8} both use the same byte array representation
            # So this is essentially just passing through the underlying array

            # The string argument is at args[6]
            if length(expr.args) >= 6
                str_arg = expr.args[6]
                emit_value!(b, str_arg, ctx)
            end

            return builder_code(b)
        elseif name === :jl_alloc_string
            # PURE-317: jl_alloc_string(n::UInt64) -> String
            # Allocates a new String of n bytes. In WasmGC, String is array<i32>.
            # Create a zero-filled array of the requested size.
            str_arr_type = get_string_array_type!(ctx.mod, ctx.type_registry)
            if length(expr.args) >= 6
                size_arg = expr.args[6]
                emit_value!(b, size_arg, ctx)
                size_type = infer_value_type(size_arg, ctx)
                if size_type === Int64 || size_type === Int || size_type === UInt64
                    num!(b, Opcode.I32_WRAP_I64)
                end
            else
                i32_const!(b, 0)
            end
            array_new_default!(b, str_arr_type)
            return builder_code(b)
        elseif name === :jl_string_ptr
            # jl_string_ptr(s) -> Ptr{UInt8}: get pointer to string bytes
            # In WasmGC, String is array<i32>. We emit i64.const 1 as base pointer.
            # Base=1 avoids ambiguity with memchr returning 0 for "not found" vs
            # finding at position 0. The pointerref handler traces back to find the
            # original string arg, so the base value doesn't affect it.
            # The memchr handler uses base=1 arithmetic: array_index = ptr - 1.
            i64_const!(b, 1)
            return builder_code(b)
        elseif name === :jl_id_start_char
            # PURE-316: jl_id_start_char(c::UInt32) -> Int32
            # Checks if a Unicode codepoint is a valid identifier start character.
            # For ASCII: letters (A-Z, a-z) and underscore (_).
            # For non-ASCII (>= 128): return 1 (assume valid, conservative).
            if length(expr.args) >= 6
                cp_arg = expr.args[6]  # UInt32 codepoint

                # Stack: [c]
                # Result: (c - 65) < 26 || (c - 97) < 26 || c == 95
                #         [A-Z]           [a-z]             [_]
                # For non-ASCII (c >= 128): return 1

                # Check ASCII vs non-ASCII
                # NOTE: i32.const takes SIGNED LEB128, so use encode_leb128_signed
                emit_value!(b, cp_arg, ctx)  # [c]
                i32_const!(b, 128)
                num!(b, Opcode.I32_LT_U)  # c < 128?

                if_!(b, 0x7F; results=WasmValType[I32])  # result type: i32

                # ASCII path: (c - 65) < 26 || (c - 97) < 26 || c == 95
                emit_value!(b, cp_arg, ctx)  # [c]
                i32_const!(b, 65)
                num!(b, Opcode.I32_SUB)
                i32_const!(b, 26)
                num!(b, Opcode.I32_LT_U)  # (c - 65) < 26  [A-Z]

                emit_value!(b, cp_arg, ctx)  # [c]
                i32_const!(b, 97)
                num!(b, Opcode.I32_SUB)
                i32_const!(b, 26)
                num!(b, Opcode.I32_LT_U)  # (c - 97) < 26  [a-z]

                num!(b, Opcode.I32_OR)

                emit_value!(b, cp_arg, ctx)  # [c]
                i32_const!(b, 95)
                num!(b, Opcode.I32_EQ)  # c == 95  [_]

                num!(b, Opcode.I32_OR)

                else_!(b)
                # Non-ASCII path: return 1 (assume valid identifier char)
                i32_const!(b, 1)
                end_block!(b)
            else
                # No argument — return 0
                i32_const!(b, 0)
            end
            return builder_code(b)
        elseif name === :jl_id_char
            # PURE-316: jl_id_char(c::UInt32) -> Int32
            # Checks if a Unicode codepoint is a valid identifier continuation character.
            # For ASCII: letters (A-Z, a-z), digits (0-9), underscore (_), and bang (!).
            # For non-ASCII (>= 128): return 1 (assume valid, conservative).
            if length(expr.args) >= 6
                cp_arg = expr.args[6]  # UInt32 codepoint

                # Check ASCII vs non-ASCII
                # NOTE: i32.const takes SIGNED LEB128, so use encode_leb128_signed
                emit_value!(b, cp_arg, ctx)  # [c]
                i32_const!(b, 128)
                num!(b, Opcode.I32_LT_U)  # c < 128?

                if_!(b, 0x7F; results=WasmValType[I32])  # result type: i32

                # ASCII path: letter || digit || _ || !
                # (c - 65) < 26 || (c - 97) < 26 || (c - 48) < 10 || c == 95 || c == 33
                emit_value!(b, cp_arg, ctx)
                i32_const!(b, 65)
                num!(b, Opcode.I32_SUB)
                i32_const!(b, 26)
                num!(b, Opcode.I32_LT_U)  # [A-Z]

                emit_value!(b, cp_arg, ctx)
                i32_const!(b, 97)
                num!(b, Opcode.I32_SUB)
                i32_const!(b, 26)
                num!(b, Opcode.I32_LT_U)  # [a-z]

                num!(b, Opcode.I32_OR)

                emit_value!(b, cp_arg, ctx)
                i32_const!(b, 48)
                num!(b, Opcode.I32_SUB)
                i32_const!(b, 10)
                num!(b, Opcode.I32_LT_U)  # [0-9]

                num!(b, Opcode.I32_OR)

                emit_value!(b, cp_arg, ctx)
                i32_const!(b, 95)
                num!(b, Opcode.I32_EQ)  # _

                num!(b, Opcode.I32_OR)

                emit_value!(b, cp_arg, ctx)
                i32_const!(b, 33)
                num!(b, Opcode.I32_EQ)  # !

                num!(b, Opcode.I32_OR)

                else_!(b)
                # Non-ASCII path: return 1 (assume valid)
                i32_const!(b, 1)
                end_block!(b)
            else
                i32_const!(b, 0)
            end
            return builder_code(b)
        elseif name === :jl_string_to_genericmemory
            # PURE-316: jl_string_to_genericmemory(s::String) -> Memory{UInt8}
            # Converts a String's underlying bytes to a Memory{UInt8}.
            # In WasmGC, both String and Memory{UInt8} are represented as array<i32>,
            # so this is a no-op: just return the string argument itself.
            # For ASCII/UTF-8 source code, the codepoint values equal the byte values.
            if length(expr.args) >= 6
                str_arg = expr.args[6]
                emit_value!(b, str_arg, ctx)
            end
            return builder_code(b)
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
                emit_value!(b, len_arg, ctx)
                len_type = infer_value_type(len_arg, ctx)
                if len_type === Int64 || len_type === Int || len_type === UInt64
                    num!(b, Opcode.I32_WRAP_I64)
                end
                local_tee!(b, len_local)

                # Create new array of exactly n elements
                array_new_default!(b, str_arr_type)
                local_tee!(b, dest_local)

                # array.copy: dest, dest_offset=0, src, src_offset=0, count=n
                i32_const!(b, 0)  # dest offset
                emit_value!(b, mem_arg, ctx)  # src array
                i32_const!(b, 0)  # src offset
                local_get!(b, len_local)  # count
                array_copy!(b, str_arr_type, str_arr_type)  # dest type, src type

                # Return the new array
                local_get!(b, dest_local)
            elseif length(expr.args) >= 6
                # Fallback: no length arg, just pass through
                mem_arg = expr.args[6]
                emit_value!(b, mem_arg, ctx)
            end
            return builder_code(b)
        elseif name === :jl_pchar_to_string
            # PURE-325: jl_pchar_to_string(ptr, n) -> String
            # Creates a String from a char pointer and length. In WasmGC, we trace
            # the pointer back to the underlying array, then copy exactly n bytes.
            if length(expr.args) >= 7
                ptr_arg = expr.args[6]
                len_arg = expr.args[7]
                data_ssa = _trace_ptr_to_data(ptr_arg, ctx)
                if data_ssa !== nothing
                    str_arr_type = get_string_array_type!(ctx.mod, ctx.type_registry)

                    # Allocate locals for dest array and length
                    dest_local = length(ctx.locals) + ctx.n_params
                    push!(ctx.locals, ConcreteRef(str_arr_type))
                    len_local = length(ctx.locals) + ctx.n_params
                    push!(ctx.locals, I32)

                    # Compile n and convert to i32
                    emit_value!(b, len_arg, ctx)
                    len_type = infer_value_type(len_arg, ctx)
                    if len_type === Int64 || len_type === Int || len_type === UInt64
                        num!(b, Opcode.I32_WRAP_I64)
                    end
                    local_tee!(b, len_local)

                    # Create new array of exactly n elements
                    array_new_default!(b, str_arr_type)
                    local_tee!(b, dest_local)

                    # array.copy: dest, dest_offset=0, src, src_offset=0, count=n
                    i32_const!(b, 0)  # dest offset
                    emit_value!(b, data_ssa, ctx)  # src array
                    i32_const!(b, 0)  # src offset
                    local_get!(b, len_local)  # count
                    array_copy!(b, str_arr_type, str_arr_type)  # dest type, src type

                    # Return the new array
                    local_get!(b, dest_local)
                    return builder_code(b)
                end
                # Fallback: the pointer might be directly compilable as a ref
                emit_value!(b, ptr_arg, ctx)
            elseif length(expr.args) >= 6
                ptr_arg = expr.args[6]
                emit_value!(b, ptr_arg, ctx)
            end
            return builder_code(b)
        elseif name === :utf8proc_grapheme_break_stateful
            # PURE-316: utf8proc_grapheme_break_stateful(c1::UInt32, c2::UInt32, state::Ref{Int32}) -> Bool
            # Returns true if there's a grapheme cluster break between c1 and c2.
            # In WasmGC, we don't have the utf8proc C library. Return true (break)
            # for all character pairs. This is conservative: it treats every codepoint
            # as its own grapheme cluster, which is correct for ASCII/BMP parsing.
            i32_const!(b, 1)  # true = always a grapheme break
            return builder_code(b)
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
                    # PURE-9024: Push typeId for Vector struct
                    i32_const!(b, 0)  # typeId = 0
                    # 1. Push data array ref
                    emit_value!(b, data_source, ctx)
                    # 2. Push typeId + length as i64 for size tuple, then struct.new Tuple{Int64}
                    # PURE-9024: Push typeId for Tuple{Int64} struct
                    i32_const!(b, 0)  # typeId = 0
                    if len_arg !== nothing
                        emit_value!(b, len_arg, ctx)
                        len_type = infer_value_type(len_arg, ctx)
                        if len_type === UInt64
                            # UInt64 → i64 is already i64, but need signed interpretation
                            # For Wasm purposes, UInt64 and Int64 are both i64
                        elseif len_type === Int32 || len_type === UInt32
                            num!(b, Opcode.I64_EXTEND_I32_S)
                        end
                    else
                        i64_const!(b, 0)
                    end
                    struct_new!(b, size_info.wasm_type_idx, WasmValType[])
                    # 3. struct.new Vector(typeId, data_ref, size_tuple_ref)
                    struct_new!(b, vec_type_idx, WasmValType[])
                    return builder_code(b)
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
            emit_value!(b, str_ssa, ctx)
            local_set!(b, str_local)

            # Store start_ptr (the ptr argument to memchr = 1-based position)
            emit_value!(b, ptr_arg, ctx)
            local_set!(b, current_local)

            # Store byte
            emit_value!(b, byte_arg, ctx)
            local_set!(b, byte_local)

            # Compute end = start + count
            local_get!(b, current_local)
            emit_value!(b, count_arg, ctx)
            num!(b, Opcode.I64_ADD)
            local_set!(b, end_local)

            # result = 0 (not found)
            i64_const!(b, 0)
            local_set!(b, result_local)

            # block $done
            block!(b)  # void

            #   loop $scan
            loop!(b)  # void

            #     if current >= end, break
            local_get!(b, current_local)
            local_get!(b, end_local)
            num!(b, Opcode.I64_GE_U)
            br_if!(b, 1)  # br to block (depth 1 = $done)

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
            br!(b, 2)  # br to block (depth 2 = $done)
            end_block!(b)  # end if

            #     current += 1
            local_get!(b, current_local)
            i64_const!(b, 1)
            num!(b, Opcode.I64_ADD)
            local_set!(b, current_local)

            #     br $scan (continue loop)
            br!(b, 0)  # br to loop (depth 0 = $scan)

            #   end loop
            end_block!(b)
            # end block
            end_block!(b)

            # Push result (the "pointer" or 0)
            local_get!(b, result_local)
            return builder_code(b)
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
            local _mmv_te = eltype(infer_value_type(_mmv_d, ctx))
            if _mmv_te === eltype(infer_value_type(_mmv_s, ctx)) && sizeof(_mmv_te) in (1, 4, 8)
                local _mmv_arr = get_array_type!(ctx.mod, ctx.type_registry, _mmv_te)
                local _mmv_sh = trailing_zeros(sizeof(_mmv_te))
                local _mmv_emit_arr = vec -> begin
                    _emit_backing_array!(b, vec, ctx, _mmv_arr)
                end
                local _mmv_emit_off = a -> begin
                    emit_value!(b, a, ctx)
                    num!(b, Opcode.I32_WRAP_I64)
                    i32_const!(b, Int64(_mmv_sh))
                    num!(b, Opcode.I32_SHR_U)
                end
                _mmv_emit_arr(_mmv_d)
                _mmv_emit_off(dest_ptr_arg)
                _mmv_emit_arr(_mmv_s)
                _mmv_emit_off(src_ptr_arg)
                _mmv_emit_off(nbytes_arg)
                array_copy!(b, _mmv_arr, _mmv_arr)
                # memmove returns dest ptr — fake i64 0
                i64_const!(b, 0)
                return builder_code(b)
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
                emit_value!(b, arr_ssa, ctx)
                # Dest offset: compile pointer value as i64, wrap to i32
                emit_value!(b, dest_ptr_arg, ctx)
                _dest_type = infer_value_type(dest_ptr_arg, ctx)
                if _dest_type === Int64 || _dest_type === Int || _dest_type === UInt64 || _dest_type <: Ptr
                    num!(b, Opcode.I32_WRAP_I64)
                end
                # Src array (same array)
                emit_value!(b, arr_ssa, ctx)
                # Src offset: compile pointer value as i64, wrap to i32
                emit_value!(b, src_ptr_arg, ctx)
                _src_type = infer_value_type(src_ptr_arg, ctx)
                if _src_type === Int64 || _src_type === Int || _src_type === UInt64 || _src_type <: Ptr
                    num!(b, Opcode.I32_WRAP_I64)
                end
                # Length
                emit_value!(b, nbytes_arg, ctx)
                _nbytes_type = infer_value_type(nbytes_arg, ctx)
                if _nbytes_type === Int64 || _nbytes_type === Int || _nbytes_type === UInt64
                    num!(b, Opcode.I32_WRAP_I64)
                end
                # Emit array.copy
                array_copy!(b, arr_copy_type, arr_copy_type)
                # memmove returns dest ptr — push i64.const 0
                i64_const!(b, 0)
                return builder_code(b)
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
            emit_value!(b, dest_arr_ssa, ctx)
            # dest offset (0-based: memoryrefnew offset is 1-based, subtract 1)
            if dest_offset_ssa === nothing
                i32_const!(b, 0)
            else
                emit_value!(b, dest_offset_ssa, ctx)
                dest_offset_type = infer_value_type(dest_offset_ssa, ctx)
                if dest_offset_type === Int64 || dest_offset_type === Int
                    num!(b, Opcode.I32_WRAP_I64)
                end
                i32_const!(b, 1)
                num!(b, Opcode.I32_SUB)
            end
            # src array
            emit_value!(b, src_arr_ssa, ctx)
            # src offset (0-based)
            if src_offset_ssa === nothing
                i32_const!(b, 0)
            else
                emit_value!(b, src_offset_ssa, ctx)
                src_offset_type = infer_value_type(src_offset_ssa, ctx)
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
            emit_value!(b, nbytes_arg, ctx)
            nbytes_type = infer_value_type(nbytes_arg, ctx)
            if nbytes_type === Int64 || nbytes_type === Int || nbytes_type === UInt64
                num!(b, Opcode.I32_WRAP_I64)
            end
            if _elem_size > 1
                i32_const!(b, Int64(_elem_size))
                num!(b, Opcode.I32_DIV_U)
            end
            # emit array.copy
            array_copy!(b, arr_copy_type, arr_copy_type)  # dest type, src type
            # memmove returns dest ptr — push i64.const 0 as the result
            i64_const!(b, 0)
            return builder_code(b)
        end
    end

    if name === :jl_symbol_n
        # jl_symbol_n(ptr::Ptr{UInt8}, len::Int64) -> Ref{Symbol}
        # In WasmGC, Symbol is represented as a string byte array (same as String).
        # The GC root argument (expr.args[8]) is the original String — just return it.
        if length(expr.args) >= 8
            gc_root = expr.args[8]
            emit_value!(b, gc_root, ctx)
            return builder_code(b)
        end
    end

    # PURE-9043: jl_get_current_task → phantom value (no bytecode)
    # Task SSA is used by getfield/setfield for rngState0..3 (Xoshiro256++ RNG)
    # We handle those field accesses as Wasm global reads/writes in compile_call.
    if name === :jl_get_current_task
        # No bytecode needed — the Task value is phantom.
        # Mark this SSA so it doesn't get stored to a local.
        return builder_code(b)
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
        return builder_code(b)
    end

    # P3 gap 450889a9cb7e: memmove(dest, src, n) over Vector{UInt8} storage —
    # Ryu's writeshortest shifts digit bytes in-buffer (decimal point
    # insertion). Trace both pointers through add_ptr/sub_ptr chains to the
    # backing vector and emit array.copy (overlap-safe per the wasm spec).
    if (name === :memmove || name === :memcpy) && length(expr.args) >= 8
        _mm_d = _trace_memmove_ptr(expr.args[6], ctx)
        _mm_s = _trace_memmove_ptr(expr.args[7], ctx)
        if _mm_d !== nothing && _mm_s !== nothing
            _arr_t = get_array_type!(ctx.mod, ctx.type_registry, UInt8)
            _mm_emit_arr! = function (vec)
                _emit_backing_array!(b, vec, ctx, _arr_t)
            end
            _mm_emit_ptr_off! = function (ptr_arg)
                # fake base pointer compiles to 0 → pointer value == byte offset
                emit_value!(b, ptr_arg, ctx)
                num!(b, Opcode.I32_WRAP_I64)
            end
            _mm_emit_arr!(_mm_d); _mm_emit_ptr_off!(expr.args[6])
            _mm_emit_arr!(_mm_s); _mm_emit_ptr_off!(expr.args[7])
            emit_value!(b, expr.args[8], ctx)
            local _mm_nt = infer_value_type(expr.args[8], ctx)
            (_mm_nt === UInt64 || _mm_nt === Int64 || _mm_nt === Int) &&
                num!(b, Opcode.I32_WRAP_I64)
            array_copy!(b, _arr_t, _arr_t)
            # memmove returns the dest pointer — fake i64 0 (consumers ignore it)
            i64_const!(b, 0)
            return builder_code(b)
        end
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
            emit_value!(b, str_arg, ctx)  # string array ref
            if length(expr.args) >= 7
                len_arg = expr.args[7]
                emit_value!(b, len_arg, ctx)  # length as i64
            else
                i64_const!(b, 0)
            end
            if length(expr.args) >= 8
                seed_arg = expr.args[8]
                emit_value!(b, seed_arg, ctx)  # seed as i32
                # seed may be i64 from SSA — wrap to i32
                seed_type = infer_value_type(seed_arg, ctx)
                if seed_type === UInt64 || seed_type === Int64 || seed_type === Int
                    num!(b, Opcode.I32_WRAP_I64)
                end
            else
                i32_const!(b, 0)
            end
            call!(b, hash_func_idx, WasmValType[], WasmValType[I64])
            return builder_code(b)
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
                emit_value!(b, a, ctx)
                num!(b, Opcode.I32_WRAP_I64)
                if _gmc_sh > 0
                    i32_const!(b, Int64(_gmc_sh))
                    num!(b, Opcode.I32_SHR_U)
                end
            end
            emit_value!(b, expr.args[6], ctx)
            ref_cast!(b, Int64(_gmc_arr), true)
            _gmc_off(expr.args[7])
            emit_value!(b, expr.args[8], ctx)
            ref_cast!(b, Int64(_gmc_arr), true)
            _gmc_off(expr.args[9])
            emit_value!(b, expr.args[10], ctx)
            if infer_value_type(expr.args[10], ctx) in (Int64, UInt64, Int)
                num!(b, Opcode.I32_WRAP_I64)
            end
            array_copy!(b, _gmc_arr, _gmc_arr)
            return builder_code(b)   # Cvoid — no value
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
                emit_value!(b, _ti_r, ctx)
                return builder_code(b)
            end
        end
    end
    if _fc_sym === :jl_value_ptr
        # pointer_from_objref-style base pointer — in the fake-pointer model
        # every base is byte offset 0. A benign value, NOT a stub: typed
        # pointerref/pointerset trace the object identity separately.
        i64_const!(b, 0)
        return builder_code(b)
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
            return builder_code(b)
        end
    end

    # Unknown foreigncall — emit a default return value instead of unreachable.
    # These stubs are dead code at runtime (WasmTarget handles them via intrinsics
    # at a higher level), but emitting unreachable causes wasm-opt's
    # --traps-never-happen to eliminate surrounding live code.
    # Returning a type-appropriate default keeps the optimizer safe.
    fc_return_type = length(expr.args) >= 2 ? expr.args[2] : Nothing
    # P5-trim: emit the default in the width of the ACTUAL SSA LOCAL when one
    # exists — the declared foreigncall return type can disagree with the
    # local the pipeline allocated (i64 default into an i32 local failed
    # validation in freshly-collected show machinery).
    local _fcd_lt = nothing
    local _fcd_li = get(ctx.ssa_locals, idx, nothing)
    if _fcd_li !== nothing
        local _fcd_off = _fcd_li - ctx.n_params
        if _fcd_off >= 0 && _fcd_off < length(ctx.locals)
            _fcd_lt = ctx.locals[_fcd_off + 1]
        end
    end
    if _fcd_lt === I32
        i32_const!(b, 0)
    elseif _fcd_lt === I64
        i64_const!(b, 0)
    elseif _fcd_lt === F64
        f64_const!(b, 0.0)
    elseif _fcd_lt === F32
        f32_const!(b, 0.0f0)
    elseif _fcd_lt isa ConcreteRef
        ref_null!(b, Int64(_fcd_lt.type_idx), ConcreteRef(UInt32(_fcd_lt.type_idx), true))
    elseif _fcd_lt === AnyRef || _fcd_lt === ExternRef || _fcd_lt === StructRef || _fcd_lt === ArrayRef || _fcd_lt === EqRef
        ref_null!(b, _fcd_lt)
    elseif fc_return_type === Int32 || fc_return_type === UInt32
        i32_const!(b, 0)
    elseif fc_return_type === Int64 || fc_return_type === UInt64 || fc_return_type === Int
        i64_const!(b, 0)
    elseif fc_return_type === Float64
        f64_const!(b, 0.0)
    elseif fc_return_type === Float32
        f32_const!(b, 0.0f0)
    elseif fc_return_type === Nothing || fc_return_type === Cvoid
        # void return — no value needed
    else
        # For pointer types (Ptr{...}) and other unknowns, use i64 as a safe default
        i64_const!(b, 0)
    end
    # P4-stdlib (Random digest!, the CONDSTUB class root): this path EMITS A
    # VALUE — execution continues past it — so it must NOT set
    # last_stmt_was_stub: the flag dead-codes the rest of the block,
    # poisoning live conditions into `unreachable` (the value-vs-dead
    # contradiction behind the FINDINGS P4 family). It must still be LOUD:
    # record the unsupported foreigncall so strict mode surfaces it instead
    # of silently no-opping effectful calls (a missed memmove made SHA
    # digest its own zeros — input-independent output).
    record_unsupported!(ctx, :unsupported_method,
        "foreigncall `$(name)` (no handler; emitted type-default value)"; idx=idx, detail=expr)
    return builder_code(b)
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

