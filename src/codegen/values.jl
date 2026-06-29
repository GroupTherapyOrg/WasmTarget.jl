# ============================================================================
# Value Compilation
# ============================================================================

"""
Get the Wasm type that compile_value will push on the stack for a given value.
Used to detect type mismatches at return sites.
"""
function infer_value_wasm_type(val, ctx::AbstractCompilationContext)::WasmValType
    # PURE-036af: Handle nothing specially - compile_value(nothing) produces i32_const 0
    if val === nothing
        return I32
    end
    # PURE-043: Handle GlobalRef by resolving it and recursively determining type
    # GlobalRef to nothing emits i32.const 0; GlobalRef to Type emits i32.const 0;
    # GlobalRef to struct instance emits struct_new
    if val isa GlobalRef
        if val.name === :nothing
            return I32
        end
        # Resolve the GlobalRef to get the actual value
        try
            actual_val = getfield(val.mod, val.name)
            return infer_value_wasm_type(actual_val, ctx)
        catch
            # If we can't resolve, fall back to AnyRef (internal polymorphic type)
            return AnyRef
        end
    end
    if val isa Core.SSAValue
        if haskey(ctx.ssa_locals, val.id)
            local_idx = ctx.ssa_locals[val.id]
            local_array_idx = local_idx - ctx.n_params + 1
            if local_array_idx >= 1 && local_array_idx <= length(ctx.locals)
                return ctx.locals[local_array_idx]
            end
        elseif haskey(ctx.phi_locals, val.id)
            local_idx = ctx.phi_locals[val.id]
            local_array_idx = local_idx - ctx.n_params + 1
            if local_array_idx >= 1 && local_array_idx <= length(ctx.locals)
                return ctx.locals[local_array_idx]
            end
        end
        # Fall back to Julia type inference
        ssa_type = get(ctx.ssa_types, val.id, Any)
        return julia_to_wasm_type_concrete(ssa_type, ctx)
    elseif val isa Core.SlotNumber
        # PURE-6024: SlotNumber in unoptimized IR — check slot_locals first, then params
        if haskey(ctx.slot_locals, val.id)
            local_idx = ctx.slot_locals[val.id]
            local_array_idx = local_idx - ctx.n_params + 1
            if local_array_idx >= 1 && local_array_idx <= length(ctx.locals)
                return ctx.locals[local_array_idx]
            end
        end
        # Fall back to param mapping or slottypes
        if ctx.is_compiled_closure
            arg_idx = val.id
        else
            arg_idx = val.id - 1
        end
        if arg_idx >= 1 && arg_idx <= length(ctx.arg_types)
            return julia_to_wasm_type_concrete(ctx.arg_types[arg_idx], ctx)
        elseif val.id >= 1 && val.id <= length(ctx.code_info.slottypes)
            return julia_to_wasm_type_concrete(ctx.code_info.slottypes[val.id], ctx)
        end
        return AnyRef
    elseif val isa Core.Argument
        # PURE-325: Match compile_value's offset — for regular functions, _1 is the
        # function object, so actual args start at _2 → arg_types[1].
        if ctx.is_compiled_closure
            arg_idx = val.n
        else
            arg_idx = val.n - 1
        end
        if arg_idx >= 1 && arg_idx <= length(ctx.arg_types)
            return julia_to_wasm_type_concrete(ctx.arg_types[arg_idx], ctx)
        end
        return I32
    else
        # Literal value
        if val isa Int64 || val isa UInt64
            return I64
        elseif val isa Int32 || val isa UInt32 || val isa Bool ||
               val isa Int8 || val isa UInt8 || val isa Int16 || val isa UInt16
            # P2-batch11: narrow ints were MISSING here — a literal like 0x00
            # fell through to AnyRef, so `return 0x00` failed
            # return_type_compatible(AnyRef, I32) and compiled to `unreachable`
            # (gap 46fd6782e95c). compile_value already emits i32.const for these.
            return I32
        elseif val isa Float64
            return F64
        elseif val isa Float32
            return F32
        elseif val isa QuoteNode
            # PURE-043: QuoteNode wraps a value - recursively determine its type.
            # D-001: IR reference types inside QuoteNodes are literal structs, not IR refs.
            inner = val.value
            if inner isa Core.SSAValue || inner isa Core.Argument || inner isa Core.SlotNumber
                T = typeof(inner)
                info = register_struct_type!(ctx.mod, ctx.type_registry, T)
                return ConcreteRef(info.wasm_type_idx, false)
            end
            return infer_value_wasm_type(inner, ctx)
        elseif val isa Symbol || val isa String
            # PURE-043: Symbol/String compile to array_new_fixed (ConcreteRef)
            str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
            return ConcreteRef(str_type_idx, false)
        elseif val isa Type
            # PURE-4155: Type values (like Bool, Int64) compile to global.get (DataType struct ref).
            # Must check BEFORE isstructtype since typeof(Type) is DataType (a struct)
            # PURE-9063: Use $JlDataType when hierarchy is available
            dt_idx = get_datatype_type_idx(ctx.type_registry)
            return ConcreteRef(dt_idx, true)
        elseif val isa Core.TypeName
            # PURE-9064: TypeName constants compile to global.get ($JlTypeName struct ref)
            tn_idx = ctx.type_registry.jl_typename_idx
            if tn_idx !== nothing
                return ConcreteRef(tn_idx, true)
            end
            return StructRef
        elseif isstructtype(typeof(val))
            # PURE-043: Struct values compile to struct_new (ConcreteRef)
            return get_concrete_wasm_type(typeof(val), ctx.mod, ctx.type_registry)
        else
            return AnyRef
        end
    end
end

"""
Check if two wasm types are compatible for return (can be used interchangeably).
Numeric types (I32/I64/F32/F64) are only compatible with themselves.
Ref types are compatible with each other for polymorphic purposes.
"""
function return_type_compatible(value_type::WasmValType, return_type::WasmValType)::Bool
    if value_type == return_type
        return true
    end
    # ExternRef is compatible with any ref type (ConcreteRef, StructRef, ArrayRef, AnyRef)
    if return_type === ExternRef
        return value_type isa ConcreteRef || value_type === StructRef || value_type === ArrayRef || value_type === AnyRef || value_type === ExternRef
    end
    # AnyRef is compatible with concrete refs
    if return_type === AnyRef
        return value_type isa ConcreteRef || value_type === StructRef || value_type === ArrayRef
    end
    # PURE-207: I32 is compatible with I64 (needs i64_extend_i32_s at call site)
    # This handles Union{Nothing, Int64} returns where nothing compiles to i32.const 0
    if value_type === I32 && return_type === I64
        return true
    end
    # WBUILD-4000: EqRef/StructRef/AnyRef are compatible with ConcreteRef (needs ref.cast)
    # This handles Union{Nothing, T} phi locals typed as EqRef when function returns ConcreteRef.
    if return_type isa ConcreteRef
        if value_type === EqRef || value_type === StructRef || value_type === AnyRef || value_type isa ConcreteRef
            return true
        end
    end
    # StructRef is compatible with ConcreteRef supertypes
    if return_type === StructRef
        if value_type === EqRef || value_type === AnyRef || value_type isa ConcreteRef
            return true
        end
    end
    haskey(ENV, "WT_TRACE_RETCOMPAT") && println(stderr, "RETCOMPAT false: val=$value_type ret=$return_type")
    return false
end

"""
PURE-908: Compile a GotoIfNot condition to i32.
When the condition SSA value has an anyref/externref local (because Julia typed it as Any),
the raw compile_value would push anyref, but i32.eqz needs i32. This helper unboxes via
ref.cast + struct.get when needed.
"""
# MIGRATED to InstrBuilder (Phase 1, dart2wasm-style typed emission). The shared
# builder is threaded once the callers migrate; for now a fragment builder validates
# this emitter's stack in isolation (compile_value bridged via its known pushed type).
function compile_condition_to_i32(cond, ctx::AbstractCompilationContext)::Vector{UInt8}
    if haskey(ENV, "WT_TRACE_CONDSTUB") && ctx.last_stmt_was_stub
        println(stderr, "CONDSTUB cond=", first(repr(cond), 30))
        for fr in stacktrace()[2:9]
            println(stderr, "   ", fr)
        end
    end
    b = InstrBuilder(; func_name="compile_condition_to_i32", strict=_wt_builder_strict())
    set_context!(b, "GotoIfNot cond → i32")
    # bridge the (still-raw) compile_value with its known pushed type
    emit_raw!(b, compile_value(cond, ctx); pushes=WasmValType[infer_value_wasm_type(cond, ctx)])
    # Check if the condition value is in a non-i32 local
    if cond isa Core.SSAValue
        local_idx = get(ctx.ssa_locals, cond.id, nothing)
        if local_idx === nothing
            local_idx = get(ctx.phi_locals, cond.id, nothing)
        end
        if local_idx !== nothing
            local_offset = local_idx - ctx.n_params
            if local_offset >= 0 && local_offset < length(ctx.locals)
                local_type = ctx.locals[local_offset + 1]
                if local_type === AnyRef || local_type === ExternRef
                    # Value is anyref/externref but should be i32 (Bool). Unbox.
                    local_type === ExternRef && any_convert_extern!(b)
                    box_type_idx = get_numeric_box_type!(ctx.mod, ctx.type_registry, I32)
                    ref_cast!(b, box_type_idx, true)
                    struct_get!(b, box_type_idx, 1, I32)  # field 1 (0=typeId, 1=value)
                elseif local_type isa ConcreteRef
                    # PURE-6025: tagged-union concrete ref → extract i32 tag from field 1.
                    type_idx = local_type.type_idx
                    if type_idx + 1 <= length(ctx.mod.types)
                        mod_type = ctx.mod.types[type_idx + 1]
                        if mod_type isa StructType && length(mod_type.fields) >= 3 && mod_type.fields[2].valtype === I32
                            struct_get!(b, type_idx, 1, I32)  # field 1 (tag, after typeId at 0)
                        else
                            drop!(b); i32_const!(b, 0)        # not a tagged union — default
                        end
                    else
                        drop!(b); i32_const!(b, 0)            # unknown type — default
                    end
                elseif local_type === StructRef || local_type === ArrayRef
                    drop!(b); i32_const!(b, 0)                # abstract ref — default
                end
            end
        end
    end
    return builder_code(b)
end

"""
Compile a value reference (SSA, Argument, or Literal).
"""
# object-identity stack for struct-constant compilation (cycle/depth guard)
const _VALUE_COMPILE_STACK = Vector{Any}()

function compile_value(val, ctx::AbstractCompilationContext)::Vector{UInt8}
    # MIGRATED to InstrBuilder. The main accumulator is the typed builder `b`; the
    # byte-INSPECTING branches (struct/Dict/Vector/Memory constants) keep building
    # local UInt8[] buffers (they LEB-decode + scan recursive results) and splice them
    # into `b` via emit_raw! / RawBytes. Byte-identical to the prior raw emission.
    b = InstrBuilder(; func_name="compile_value", strict=false)
    # Bridge external byte-emitting helpers (their intermediate buffers stay bytes):
    _emit_tid!(T) = (tb = UInt8[]; emit_type_id!(tb, ctx.type_registry, T); emit_raw!(b, tb; pushes=WasmValType[I32]))
    _narrow!(li, sid) = (nb = UInt8[]; _narrow_generic_local!(nb, li, sid, ctx); isempty(nb) || emit_raw!(b, nb))

    # PURE-6022: If we're in dead code (previous sub-call was a stub), don't compile
    # more values. Emitting data after unreachable creates invalid WASM byte sequences
    # (e.g., array element i32_const values decode as block/loop instructions).
    if ctx.last_stmt_was_stub
        haskey(ENV, "WT_TRACE_DEADVAL") && println(stderr, "DEADVAL val=", first(repr(val), 60))
        unreachable!(b)  # 0x00
        return builder_code(b)
    end

    # Handle nothing explicitly - it's the Julia singleton
    if val === nothing
        # Nothing maps to i32 in WasmGC — push i32(0) as placeholder
        i32_const!(b, 0)
        return builder_code(b)
    end

    if val isa Core.SSAValue
        # Check if this SSA has a local allocated (either regular or phi)
        if haskey(ctx.ssa_locals, val.id)
            local_idx = ctx.ssa_locals[val.id]
            local_get!(b, local_idx)
            # PURE-901: Narrow generic locals (anyref/structref) to concrete type.
            # When SSA type is concrete but local was allocated as generic (due to Union/Any),
            # ref.cast ensures downstream struct_get/array_get see the correct type.
            _narrow!(local_idx, val.id)
        elseif haskey(ctx.phi_locals, val.id)
            # Phi node - load from phi local
            local_idx = ctx.phi_locals[val.id]
            local_get!(b, local_idx)
        else
            # No local - check if this is a PiNode
            # PURE-6021: Guard against out-of-bounds SSAValue IDs (e.g. sentinel Core.SSAValue(-2)
            # that appear as constant literals in IR of compiler functions like construct_ssa!)
            if val.id < 1 || val.id > length(ctx.code_info.code)
                return builder_code(b)  # Dead code - sentinel SSAValue with invalid id
            end
            stmt = ctx.code_info.code[val.id]
            if stmt isa Core.PiNode
                pi_type = get(ctx.ssa_types, val.id, Any)
                if pi_type === Nothing
                    # PiNode narrowed to Nothing - emit appropriate null/zero value
                    # Nothing maps to I32 in Wasm, so emit i32.const 0 as default.
                    # For Union{Nothing, T} where T is a ref type, emit ref.null instead.
                    emitted_nothing = false
                    if stmt.val isa Core.SSAValue
                        underlying_type = get(ctx.ssa_types, stmt.val.id, Any)
                        # For Union{Nothing, T}, emit ref.null $T
                        if underlying_type !== Nothing && underlying_type !== Any
                            wasm_type = julia_to_wasm_type_concrete(underlying_type, ctx)
                            if wasm_type isa ConcreteRef
                                ref_null!(b, Int64(wasm_type.type_idx), ConcreteRef(UInt32(wasm_type.type_idx), true))
                                emitted_nothing = true
                            end
                        end
                    end
                    if !emitted_nothing
                        # Nothing is i32(0) as placeholder — this is what the callee expects
                        i32_const!(b, 0)
                    end
                else
                    # Non-Nothing PiNode without local: re-emit the underlying value.
                    # Can't assume it's on the stack since block boundaries clear the stack.
                    emit_raw!(b, compile_value(stmt.val, ctx); pushes=WasmValType[infer_value_wasm_type(stmt.val, ctx)])
                    # PURE-9030: Unbox from anyref to numeric type when PiNode narrows
                    # a Union-typed anyref value to a concrete numeric type.
                    # e.g., π(x::Union{Int32,Float64}, Int32) → ref.cast $BoxedInt32 + struct.get 1
                    local _pi_target_wasm = julia_to_wasm_type(pi_type)
                    if (_pi_target_wasm === I32 || _pi_target_wasm === I64 || _pi_target_wasm === F32 || _pi_target_wasm === F64)
                        # Check if the underlying value is anyref (boxed).
                        # P4-stdlib (Random hash_seed): read the ACTUAL local type
                        # when one exists — get_concrete_wasm_type guesses I64 for
                        # Union{Nothing, UInt64}, but such unions are allocated as
                        # AnyRef locals (an i64 cannot encode `nothing`), so the
                        # guess skipped the unbox and raw anyref reached i64.sub.
                        local _pi_src_wasm = nothing
                        if stmt.val isa Core.SSAValue
                            local _pi_li = get(ctx.ssa_locals, stmt.val.id, nothing)
                            _pi_li === nothing && (_pi_li = get(ctx.phi_locals, stmt.val.id, nothing))
                            if _pi_li !== nothing
                                local _pi_off = _pi_li - ctx.n_params
                                if _pi_off >= 0 && _pi_off < length(ctx.locals)
                                    _pi_src_wasm = ctx.locals[_pi_off + 1]
                                end
                            end
                            if _pi_src_wasm === nothing
                                local _pi_src_type = get(ctx.ssa_types, stmt.val.id, Any)
                                _pi_src_wasm = get_concrete_wasm_type(_pi_src_type, ctx.mod, ctx.type_registry)
                            end
                        elseif stmt.val isa Core.Argument
                            local _pi_arg_idx = ctx.is_compiled_closure ? stmt.val.n : stmt.val.n - 1
                            if _pi_arg_idx >= 1 && _pi_arg_idx <= length(ctx.arg_types)
                                _pi_src_wasm = get_concrete_wasm_type(ctx.arg_types[_pi_arg_idx], ctx.mod, ctx.type_registry)
                            end
                        end
                        if _pi_src_wasm === AnyRef || _pi_src_wasm === StructRef || _pi_src_wasm isa ConcreteRef
                            # Value is boxed in anyref — unbox via ref.cast + struct.get
                            local _box_idx = get_numeric_box_type!(ctx.mod, ctx.type_registry, _pi_target_wasm)
                            ref_cast!(b, Int64(_box_idx), false)  # non-null cast (inside isa-guarded branch)
                            struct_get!(b, _box_idx, 1, _pi_target_wasm)  # field 1 = value (field 0 = typeId)
                        end
                    else
                        # CG-003d: PiNode narrows to a struct/ref type (not numeric).
                        # Source value may be EqRef/StructRef/AnyRef (from Union{Nothing, T} local).
                        # Add ref.cast_null to narrow to the concrete type so struct.get works.
                        local _pi_concrete = julia_to_wasm_type_concrete(pi_type, ctx)
                        if _pi_concrete isa ConcreteRef
                            # Check if the source is a generic ref type that needs casting
                            local _pi_src_wasm2 = nothing
                            if stmt.val isa Core.SSAValue
                                local _pi_src_type2 = get(ctx.ssa_types, stmt.val.id, Any)
                                _pi_src_wasm2 = julia_to_wasm_type_concrete(_pi_src_type2, ctx)
                            elseif stmt.val isa Core.Argument
                                local _pi_arg_idx2 = ctx.is_compiled_closure ? stmt.val.n : stmt.val.n - 1
                                if _pi_arg_idx2 >= 1 && _pi_arg_idx2 <= length(ctx.arg_types)
                                    _pi_src_wasm2 = julia_to_wasm_type_concrete(ctx.arg_types[_pi_arg_idx2], ctx)
                                end
                            end
                            if _pi_src_wasm2 === EqRef || _pi_src_wasm2 === StructRef || _pi_src_wasm2 === AnyRef || _pi_src_wasm2 === ExternRef
                                _pi_src_wasm2 === ExternRef && any_convert_extern!(b)
                                ref_cast!(b, Int64(_pi_concrete.type_idx), true)
                            end
                        end
                    end
                end
            else
                # Non-PiNode SSA without local: re-compile the statement to reproduce its value.
                if stmt isa Expr && stmt.head === :boundscheck
                    # P2-batch6: real value (true unless @inbounds) — see statements.jl
                    i32_const!(b, (isempty(stmt.args) || stmt.args[1] !== false) ? 1 : 0)
                elseif stmt isa Expr && (stmt.head === :call || stmt.head === :invoke || stmt.head === :new || stmt.head === :foreigncall)
                    # Re-compile the expression to produce its value on the stack.
                    # Call the specific compiler directly to avoid compile_statement's
                    # orphan-prevention skip for multi-arg memoryrefnew.
                    local _ssa_t = WasmValType[infer_value_wasm_type(val, ctx)]
                    if stmt.head === :call
                        emit_raw!(b, compile_call(stmt, val.id, ctx); pushes=_ssa_t)
                    elseif stmt.head === :invoke
                        emit_raw!(b, compile_invoke(stmt, val.id, ctx); pushes=_ssa_t)
                    elseif stmt.head === :new
                        emit_raw!(b, compile_new(stmt, val.id, ctx); pushes=_ssa_t)
                    elseif stmt.head === :foreigncall
                        emit_raw!(b, compile_foreigncall(stmt, val.id, ctx); pushes=_ssa_t)
                    end
                end
            end
            # For non-PiNode SSAs without locals, assume on stack (single-use in sequence)
        end

    elseif val isa Core.Argument
        # For closures being compiled, _1 is the closure object (arg_types[1])
        # For regular functions, arguments start at _2 (arg_types[1])
        # Use is_compiled_closure flag (not the type of first arg)
        if ctx.is_compiled_closure
            # Closure: direct mapping (_1 = closure, _2 = first arg)
            arg_idx = val.n
        else
            # Regular function: skip _1 (function type in IR)
            arg_idx = val.n - 1
        end

        # WasmGlobal arguments don't have locals - they're accessed via global.get/set
        # in the getfield/setfield handlers, so we skip emitting anything here
        if arg_idx in ctx.global_args
            # WasmGlobal arg - no local.get needed (handled by getfield/setfield)
            # Return empty bytes
        elseif arg_idx >= 1 && arg_idx <= length(ctx.arg_types)
            # Calculate local index: count non-WasmGlobal args before this one
            local_idx = count(i -> !(i in ctx.global_args), 1:arg_idx-1)
            local_get!(b, local_idx)
        end

    elseif val isa Core.SlotNumber
        # PURE-6024: Check slot_locals first (for local variables in unoptimized IR),
        # then fall back to param mapping (slot 2 = param 0, slot 3 = param 1, etc.)
        if haskey(ctx.slot_locals, val.id)
            local_get!(b, ctx.slot_locals[val.id])
        else
            local_idx = val.id - 2
            if local_idx >= 0
                local_get!(b, local_idx)
            end
        end

    elseif val isa Bool
        i32_const!(b, val ? 1 : 0)

    elseif val isa Char
        # STACK-003: Char stored as Julia's internal representation (UTF-8 encoding
        # left-packed in UInt32). This matches Julia IR semantics where
        # bitcast(UInt32, c::Char) is a no-op reinterpret of the raw bytes.
        # '+' (U+002B) → 0x2b000000, 'é' (U+00E9) → 0xc3a90000
        # JS callers must convert codepoints to Julia encoding before passing.
        raw = reinterpret(Int32, reinterpret(UInt32, val))
        i32_const!(b, raw)

    elseif val isa Int8 || val isa UInt8 || val isa Int16 || val isa UInt16
        # Small integers - stored as i32 in WASM
        i32_const!(b, Int32(val))

    elseif val isa Int32
        i32_const!(b, val)

    elseif val isa UInt32
        i32_const!(b, reinterpret(Int32, val))

    elseif val isa Int64 || val isa Int
        i64_const!(b, Int64(val))

    elseif val isa UInt64
        i64_const!(b, reinterpret(Int64, val))

    elseif val isa Int128 || val isa UInt128
        # 128-bit integers are represented as WasmGC structs with (lo, hi) fields
        result_type = typeof(val)
        type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)

        # Extract lo (low 64 bits) and hi (high 64 bits)
        lo = UInt64(val & 0xFFFFFFFFFFFFFFFF)
        hi = UInt64((val >> 64) & 0xFFFFFFFFFFFFFFFF)

        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID
        _emit_tid!(result_type)
        i64_const!(b, reinterpret(Int64, lo))   # lo
        i64_const!(b, reinterpret(Int64, hi))   # hi
        struct_new!(b, type_idx, WasmValType[I32, I64, I64])

    elseif val isa Float32
        f32_const!(b, val)

    elseif val isa Float64
        f64_const!(b, val)

    elseif val isa String
        # PURE-9013: String constant via passive data segment + array.new_data
        # Much more compact than N × i32.const + array.new_fixed
        type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
        n_bytes = ncodeunits(val)

        if n_bytes == 0
            # Empty string: use array.new_fixed with 0 elements (no data segment needed)
            array_new_fixed!(b, type_idx, 0, I32)
        else
            # Create a passive data segment with UTF-8 bytes
            utf8_bytes = Vector{UInt8}(codeunits(val))
            seg_idx = add_passive_data_segment!(ctx.mod, utf8_bytes)

            # array.new_data $type_idx $seg_idx : [offset, length] -> [(ref $type)]
            i32_const!(b, 0)              # offset 0 (start of segment)
            # i32.const operands are SIGNED LEB128 — unsigned-encoding a length in
            # [64,127] (and other bands) decodes negative → array.new_data with a
            # huge unsigned length → "array too large" trap (medium-length string
            # literals, e.g. admonition HTML).
            i32_const!(b, Int32(n_bytes))  # length
            array_new_data!(b, type_idx, seg_idx)
        end

    elseif val isa GlobalRef
        # Check if this GlobalRef is a module-level global (mutable struct instance)
        key = (val.mod, val.name)
        global_idx = _lookup_module_global(ctx.module_globals, key)
        if global_idx !== nothing
            global_get!(b, global_idx, AnyRef)
        else
            # GlobalRef to a constant - evaluate and compile the value
            try
                actual_val = getfield(val.mod, val.name)
                emit_raw!(b, compile_value(actual_val, ctx); pushes=WasmValType[AnyRef])
            catch
                # If we can't evaluate, might be a type reference (no runtime value)
            end
        end

    elseif val isa QuoteNode
        # QuoteNode wraps a constant value - unwrap and compile.
        # D-001: Core IR reference types (SSAValue, Argument, SlotNumber) inside QuoteNodes
        # are LITERAL struct values, not IR references. compile_value would misinterpret them
        # as SSA slot lookups / argument loads. Compile them as struct constants instead.
        inner = val.value
        if inner isa Core.SSAValue || inner isa Core.Argument || inner isa Core.SlotNumber
            T = typeof(inner)
            info = register_struct_type!(ctx.mod, ctx.type_registry, T)
            type_idx = info.wasm_type_idx
            _emit_tid!(T)
            for field_name in fieldnames(T)
                field_val = getfield(inner, field_name)
                if field_val isa Int
                    i64_const!(b, Int64(field_val))
                else
                    emit_raw!(b, compile_value(field_val, ctx); pushes=WasmValType[AnyRef])
                end
            end
            struct_new!(b, type_idx, WasmValType[])
        else
            emit_raw!(b, compile_value(inner, ctx); pushes=WasmValType[AnyRef])
        end

    elseif isprimitivetype(typeof(val)) && !isa(val, Bool) && !isa(val, Char) &&
           !isa(val, Int8) && !isa(val, Int16) && !isa(val, Int32) && !isa(val, Int64) &&
           !isa(val, UInt8) && !isa(val, UInt16) && !isa(val, UInt32) && !isa(val, UInt64) &&
           !isa(val, Float32) && !isa(val, Float64)
        # Custom primitive type (e.g., JuliaSyntax.Kind) - bitcast to integer
        T = typeof(val)
        sz = sizeof(T)
        if sz == 1
            int_val = Core.Intrinsics.bitcast(UInt8, val)
            i32_const!(b, Int32(int_val))
        elseif sz == 2
            int_val = Core.Intrinsics.bitcast(UInt16, val)
            i32_const!(b, Int32(int_val))
        elseif sz == 4
            int_val = Core.Intrinsics.bitcast(UInt32, val)
            i32_const!(b, Int32(int_val))
        elseif sz == 8
            int_val = Core.Intrinsics.bitcast(UInt64, val)
            i64_const!(b, Int64(int_val))
        else
            error("Primitive type with unsupported size for Wasm: $T ($sz bytes)")
        end

    elseif val isa Symbol
        # Symbol constant - represent as string via passive data segment
        type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
        name_str = String(val)
        n_bytes = ncodeunits(name_str)

        if n_bytes == 0
            array_new_fixed!(b, type_idx, 0, I32)
        else
            utf8_bytes = Vector{UInt8}(codeunits(name_str))
            seg_idx = add_passive_data_segment!(ctx.mod, utf8_bytes)

            i32_const!(b, 0)
            # i32.const operands are SIGNED LEB128 (see String path above).
            i32_const!(b, Int32(n_bytes))
            array_new_data!(b, type_idx, seg_idx)
        end

    elseif typeof(val) <: Tuple
        # Tuple constant - create it with struct.new
        T = typeof(val)

        # Ensure tuple type is registered using register_tuple_type!
        info = register_tuple_type!(ctx.mod, ctx.type_registry, T)
        type_idx = info.wasm_type_idx

        # Get the struct type definition to check expected field types
        struct_type_def = ctx.mod.types[type_idx + 1]

        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID
        _emit_tid!(T)

        # Push field values (tuples use 1-based indexing)
        for i in 1:length(val)
            field_val = val[i]
            # PURE-141: When field value is a Type constant and field expects a ref type,
            # emit ref.null instead of i32.const 0 (compile_value(Type) returns i32)
            expected_wasm = nothing
            local _wasm_fi = i + Int(info.field_offset)  # PURE-9024: skip typeId
            if struct_type_def isa StructType && _wasm_fi <= length(struct_type_def.fields)
                expected_wasm = struct_type_def.fields[_wasm_fi].valtype
            end
            if field_val isa Type && expected_wasm !== nothing &&
               (expected_wasm isa ConcreteRef || expected_wasm === StructRef ||
                expected_wasm === ArrayRef || expected_wasm === AnyRef || expected_wasm === ExternRef)
                # Type value needs ref type - emit ref.null of expected type
                if expected_wasm isa ConcreteRef
                    ref_null!(b, Int64(expected_wasm.type_idx), ConcreteRef(UInt32(expected_wasm.type_idx), true))
                elseif expected_wasm === ArrayRef
                    ref_null!(b, ArrayRef)
                elseif expected_wasm === ExternRef
                    ref_null!(b, ExternRef)
                elseif expected_wasm === AnyRef
                    ref_null!(b, AnyRef)
                else
                    ref_null!(b, StructRef)
                end
            else
                emit_raw!(b, compile_value(field_val, ctx); pushes=WasmValType[AnyRef])
            end
        end

        # Create the struct
        struct_new!(b, type_idx, WasmValType[])

    elseif val isa Type
        # PURE-4151: Type constant — each unique Type gets a unique Wasm global
        # so that ref.eq can distinguish different Type objects at runtime.
        # Previous behavior (i32.const 0) made all Types indistinguishable.
        global_idx = get_type_constant_global!(ctx.mod, ctx.type_registry, val)
        global_get!(b, global_idx, AnyRef)

    elseif val isa Core.TypeName
        # PURE-9064: TypeName constant — look up or create the TypeName global.
        # TypeName objects have many undefined fields so the general struct constant
        # path would emit ref.null. Instead, use the dedicated TypeName global registry.
        tn_global_idx = get_typename_constant_global!(ctx.mod, ctx.type_registry, val)
        global_get!(b, tn_global_idx, AnyRef)

    elseif val isa Module
        # Module constant — empty struct (fieldcount=0), like Function singletons.
        # Used for === identity checks (ref.eq). Each struct.new creates a unique ref.
        info = register_struct_type!(ctx.mod, ctx.type_registry, Module)
        type_idx = info.wasm_type_idx
        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID
        _emit_tid!(Module)
        struct_new!(b, type_idx, WasmValType[])

    elseif val isa Function && isstructtype(typeof(val)) && fieldcount(typeof(val)) == 0
        # Function singleton (e.g., typeof(some_function)) — empty struct with no fields
        T = typeof(val)
        info = register_struct_type!(ctx.mod, ctx.type_registry, T)
        type_idx = info.wasm_type_idx
        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID
        _emit_tid!(T)
        struct_new!(b, type_idx, WasmValType[])

    elseif val isa Function && isstructtype(typeof(val)) && fieldcount(typeof(val)) > 0
        # PURE-325: Function closure with captured fields (e.g., Fix2{typeof(isequal), Char})
        # These are structs that happen to be Functions — compile like regular structs
        T = typeof(val)
        info = register_struct_type!(ctx.mod, ctx.type_registry, T)
        type_idx = info.wasm_type_idx

        has_undefined = any(!isdefined(val, fn) for fn in fieldnames(T))
        if has_undefined
            ref_null!(b, Int64(type_idx), ConcreteRef(UInt32(type_idx), true))
            return builder_code(b)
        end

        struct_type_def = ctx.mod.types[type_idx + 1]
        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID
        _emit_tid!(T)
        for (fi, field_name) in enumerate(fieldnames(T))
            field_val = getfield(val, field_name)
            emit_raw!(b, compile_value(field_val, ctx); pushes=WasmValType[AnyRef])
        end

        struct_new!(b, type_idx, WasmValType[])

    elseif typeof(val) <: Dict
        # Dict constant with pre-populated data — materialize Memory fields as arrays
        T = typeof(val)
        K = keytype(val)
        V = valtype(val)

        if !haskey(ctx.type_registry.structs, T)
            register_struct_type!(ctx.mod, ctx.type_registry, T)
        end
        dict_info = ctx.type_registry.structs[T]

        slots_arr_type = get_array_type!(ctx.mod, ctx.type_registry, UInt8)
        keys_arr_type = get_array_type!(ctx.mod, ctx.type_registry, K)
        vals_arr_type = get_array_type!(ctx.mod, ctx.type_registry, V)

        # Get the raw internal arrays from the Dict
        # Dict internals: slots, keys, vals are Memory{UInt8}, Memory{K}, Memory{V}
        dict_slots = getfield(val, :slots)
        dict_keys = getfield(val, :keys)
        dict_vals = getfield(val, :vals)

        # Helper: emit default value for an array element type (captures `b`, `ctx`)
        emit_array_default! = function(arr_type_idx, elem_type)
            wasm_et = julia_to_wasm_type(elem_type)
            if wasm_et === I32
                i32_const!(b, 0)
            elseif wasm_et === I64
                i64_const!(b, 0)
            elseif wasm_et === F32
                f32_const!(b, Float32(0))
            elseif wasm_et === F64
                f64_const!(b, Float64(0))
            else
                # Ref type (String, struct, etc.) — look up concrete array element type
                arr_type_def = ctx.mod.types[arr_type_idx + 1]
                if arr_type_def isa ArrayType
                    evtype = arr_type_def.elem.valtype
                    if evtype isa ConcreteRef
                        ref_null!(b, Int64(evtype.type_idx), ConcreteRef(UInt32(evtype.type_idx), true))
                    else
                        ref_null!(b, StructRef)
                    end
                else
                    ref_null!(b, StructRef)
                end
            end
        end

        # Helper: compile Memory elements, handling UndefRefError for ref-typed slots
        compile_memory_elements! = function(mem, arr_type_idx, elem_type)
            for i in 1:length(mem)
                # PURE-6022: Stop emitting elements after stub/unreachable
                if ctx.last_stmt_was_stub
                    break
                end
                try
                    v = mem[i]
                    emit_raw!(b, compile_value(v, ctx); pushes=WasmValType[AnyRef])
                catch e
                    if e isa UndefRefError
                        emit_array_default!(arr_type_idx, elem_type)
                    else
                        rethrow()
                    end
                end
            end
        end

        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID
        _emit_tid!(T)

        # field 1: slots — array of UInt8 (always defined, never throws)
        for i in 1:length(dict_slots)
            i32_const!(b, Int32(dict_slots[i]))
        end
        array_new_fixed!(b, slots_arr_type, length(dict_slots), I32)

        # field 2: keys — array of K (may have undef for ref-typed keys)
        compile_memory_elements!(dict_keys, keys_arr_type, K)
        array_new_fixed!(b, keys_arr_type, length(dict_keys), AnyRef)

        # field 3: vals — array of V (may have undef for ref-typed vals)
        compile_memory_elements!(dict_vals, vals_arr_type, V)
        array_new_fixed!(b, vals_arr_type, length(dict_vals), AnyRef)

        # fields 4-8: ndel, count, age, idxfloor, maxprobe (i64)
        i64_const!(b, Int64(getfield(val, :ndel)))
        i64_const!(b, Int64(getfield(val, :count)))
        i64_const!(b, Int64(getfield(val, :age)))
        i64_const!(b, Int64(getfield(val, :idxfloor)))
        i64_const!(b, Int64(getfield(val, :maxprobe)))

        # struct.new
        struct_new!(b, dict_info.wasm_type_idx, WasmValType[])

    elseif typeof(val) <: AbstractVector && typeof(val) <: Vector
        # PURE-325: Constant Vector{T} — emit as struct{data_array, size_tuple}
        # This handles global constant vectors like ascii_is_identifier_char :: Vector{Bool}
        # The data array must contain the actual values, not ref.null.
        T = typeof(val)
        elem_type = eltype(T)

        # Register the Vector struct type
        if !haskey(ctx.type_registry.structs, T)
            register_vector_type!(ctx.mod, ctx.type_registry, T)
        end
        vec_info = ctx.type_registry.structs[T]

        # Get the array type for elements
        array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID for Vector struct
        _emit_tid!(T)

        # Field 1: data array — emit array.new_fixed with actual element values
        # Check if the array element type is externref — if so, each element needs
        # extern_convert_any because compile_value produces concrete refs for structs/strings
        wasm_elem_type = get_concrete_wasm_type(elem_type, ctx.mod, ctx.type_registry)
        needs_extern_convert = (wasm_elem_type === ExternRef)
        for i in 1:length(val)
            # PURE-6022: Stop emitting array elements after unreachable (stub).
            # Dead code after unreachable contains raw data bytes that decode as
            # invalid WASM instructions (e.g., block with invalid type byte).
            if ctx.last_stmt_was_stub
                break
            end
            if needs_extern_convert
                elem_val = val[i]
                elem_bytes = compile_value(elem_val, ctx)
                # Check if elem_bytes is a plain numeric value (no GC_PREFIX = not a struct/array).
                # IntrinsicFunction and other primitives compile to i32_const/i64_const.
                # These cannot be passed to extern_convert_any (which expects anyref),
                # so we must box them via struct_new first using emit_numeric_to_externref!.
                has_gc_prefix = any(byt == Opcode.GC_PREFIX for byt in elem_bytes)
                is_numeric_elem = !has_gc_prefix && length(elem_bytes) >= 1 &&
                                  (elem_bytes[1] == Opcode.I32_CONST || elem_bytes[1] == Opcode.I64_CONST ||
                                   elem_bytes[1] == Opcode.F32_CONST || elem_bytes[1] == Opcode.F64_CONST)
                if is_numeric_elem
                    # Box numeric value into a struct then convert to externref
                    val_wasm_elem = elem_bytes[1] == Opcode.I32_CONST ? I32 :
                                    elem_bytes[1] == Opcode.I64_CONST ? I64 :
                                    elem_bytes[1] == Opcode.F32_CONST ? F32 : F64
                    nb = UInt8[]; emit_numeric_to_externref!(nb, elem_val, val_wasm_elem, ctx)
                    emit_raw!(b, nb; pushes=WasmValType[ExternRef])
                elseif !isempty(elem_bytes) && elem_bytes[end] == UInt8(ExternRef) &&
                       length(elem_bytes) >= 2 && elem_bytes[end-1] == Opcode.REF_NULL
                    # Already externref (ref.null extern) — no conversion needed
                    emit_raw!(b, elem_bytes; pushes=WasmValType[ExternRef])
                else
                    emit_raw!(b, elem_bytes; pushes=WasmValType[AnyRef])
                    extern_convert_any!(b)
                end
            else
                elem_bytes_plain = compile_value(val[i], ctx)
                if isempty(elem_bytes_plain)
                    # TRUE-INT-002-impl2-impl: compile_value returned empty bytes.
                    # Push ref.null as placeholder to maintain array_new_fixed stack balance.
                    ref_null!(b, AnyRef)  # 0x6E any heap type
                else
                    emit_raw!(b, elem_bytes_plain; pushes=WasmValType[AnyRef])
                end
            end
            # PURE-6022: Check after each element in case compile_value hit a stub
            if ctx.last_stmt_was_stub
                break
            end
        end
        # PURE-6022: Skip array_new_fixed if we're in dead code (stub was hit)
        if !ctx.last_stmt_was_stub
            array_new_fixed!(b, array_type_idx, length(val), AnyRef)
        end

        # Field 2: size tuple — Tuple{Int64} with the length
        size_tuple_type = Tuple{Int64}
        if !haskey(ctx.type_registry.structs, size_tuple_type)
            register_tuple_type!(ctx.mod, ctx.type_registry, size_tuple_type)
        end
        size_info = ctx.type_registry.structs[size_tuple_type]
        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID for size tuple
        _emit_tid!(Tuple{Int64})
        i64_const!(b, Int64(length(val)))
        struct_new!(b, size_info.wasm_type_idx, WasmValType[])

        # struct.new for Vector{T}
        struct_new!(b, vec_info.wasm_type_idx, WasmValType[])

    elseif typeof(val) isa DataType && typeof(val).name.name in (:MemoryRef, :GenericMemoryRef, :Memory, :GenericMemory)
        # PURE-049: MemoryRef/Memory constants map to array types, not struct types.
        # P6-ioprint: materialize the contents (the old ref.null emission silently
        # dropped them — Base's constant IdSet/show tables arrived empty). Large
        # memories fall back to null to avoid bytecode blowup.
        T = typeof(val)
        elem_type = T.name.name in (:GenericMemoryRef, :GenericMemory) ? T.parameters[2] : T.parameters[1]
        array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
        mem = T.name.name in (:MemoryRef, :GenericMemoryRef) ? getfield(val, :mem) : val
        n_mem = length(mem)
        if n_mem == 0 || n_mem > 4096
            n_mem > 4096 && @debug "Memory constant too large to materialize ($n_mem elements) — emitting null" T
            ref_null!(b, Int64(array_type_idx), ConcreteRef(UInt32(array_type_idx), true))
        else
            arr_type_def = ctx.mod.types[array_type_idx + 1]
            for i in 1:n_mem
                # el_bytes holds the recursive compile_value result and is INSPECTED
                # via isempty below — keep it as a local buffer (byte-inspecting branch).
                el_bytes = UInt8[]
                defined = isassigned(mem, i)
                if defined
                    el_bytes = compile_value(mem[i], ctx)
                end
                if !defined || isempty(el_bytes)
                    # undef slot (or uncompilable element) — type-correct default.
                    # Straight-line emission: emit the typed default directly on `b`.
                    evt = arr_type_def isa ArrayType ? arr_type_def.elem.valtype : nothing
                    if evt === I32
                        i32_const!(b, 0)
                    elseif evt === I64
                        i64_const!(b, 0)
                    elseif evt === F32
                        f32_const!(b, Float32(0))
                    elseif evt === F64
                        f64_const!(b, Float64(0))
                    elseif evt isa ConcreteRef
                        ref_null!(b, Int64(evt.type_idx), ConcreteRef(UInt32(evt.type_idx), true))
                    else
                        ref_null!(b, AnyRef)  # 0x6E any
                    end
                else
                    emit_raw!(b, el_bytes; pushes=WasmValType[AnyRef])
                end
            end
            array_new_fixed!(b, array_type_idx, n_mem, AnyRef)
        end

    elseif isstructtype(typeof(val)) && !isa(val, Function) && !isa(val, Module)
        # Struct constant - create it with struct.new
        T = typeof(val)

        # 1f6e77980994 family: struct CONSTANTS with cyclic/unboundedly deep
        # object graphs (Luxor/Karnak/Graphs values captured in Makie figures)
        # recursed compile_value to a StackOverflow. Guard by object identity
        # AND depth; refuse with a NAMED error so pipelines degrade honestly.
        if any(x -> x === val, _VALUE_COMPILE_STACK)
            throw(WasmCompileError(WasmDiagnostic(:unsupported_type, string(nameof(T)),
                "cyclic struct constant of type $(T) (object graph references itself)",
                nothing, nothing)))
        end
        if length(_VALUE_COMPILE_STACK) > 200
            _tail = join((string(nameof(typeof(x))) for x in _VALUE_COMPILE_STACK[end-7:end]), " → ")
            throw(WasmCompileError(WasmDiagnostic(:unsupported_type, string(nameof(T)),
                "struct constant nesting exceeded depth 200 (… → $(_tail) → $(T))",
                nothing, nothing)))
        end
        push!(_VALUE_COMPILE_STACK, val)
        try

        # Ensure struct type is registered and get its type index
        info = register_struct_type!(ctx.mod, ctx.type_registry, T)
        type_idx = info.wasm_type_idx

        # Check for undefined fields — if ALL fields are undefined, emit ref.null.
        # If only SOME fields are undefined, emit default values for those and still
        # construct the struct (TRUE-TI-001: enables Method objects with optional fields).
        n_undefined = count(!isdefined(val, fn) for fn in fieldnames(T))
        if n_undefined == length(fieldnames(T))
            # Fully undefined struct - emit ref.null
            ref_null!(b, Int64(type_idx), ConcreteRef(UInt32(type_idx), true))
            return builder_code(b)
        end

        # Push field values with type safety checks
        struct_type_def = ctx.mod.types[type_idx + 1]
        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID
        _emit_tid!(T)
        for (fi, field_name) in enumerate(fieldnames(T))
            # TRUE-TI-001: Handle undefined fields with type-correct defaults
            if !isdefined(val, field_name)
                local _undef_wasm_fi = fi + Int(info.field_offset)
                if struct_type_def isa StructType && _undef_wasm_fi <= length(struct_type_def.fields)
                    undef_field_type = struct_type_def.fields[_undef_wasm_fi].valtype
                    if undef_field_type isa ConcreteRef
                        ref_null!(b, Int64(undef_field_type.type_idx), ConcreteRef(UInt32(undef_field_type.type_idx), true))
                    elseif undef_field_type === AnyRef
                        ref_null!(b, AnyRef)
                    elseif undef_field_type === EqRef
                        ref_null!(b, EqRef)
                    elseif undef_field_type === ExternRef
                        ref_null!(b, ExternRef)
                    elseif undef_field_type === StructRef
                        ref_null!(b, StructRef)
                    elseif undef_field_type === ArrayRef
                        ref_null!(b, ArrayRef)
                    elseif undef_field_type === I32
                        i32_const!(b, 0)
                    elseif undef_field_type === I64
                        i64_const!(b, 0)
                    elseif undef_field_type === F32
                        f32_const!(b, Float32(0.0))
                    elseif undef_field_type === F64
                        f64_const!(b, Float64(0.0))
                    else
                        # Fallback: try ref.null with the generic type
                        ref_null!(b, AnyRef)
                    end
                else
                    ref_null!(b, AnyRef)
                end
                continue
            end
            field_val = getfield(val, field_name)
            field_val_bytes = compile_value(field_val, ctx)
            # P6-ioprint: Union-typed field (no Nothing variant) registered as a
            # tagged-union box (typeId, tag, anyref) — wrap the concrete value.
            # The constant's runtime type gives the exact tag.
            local _cub_ft = fieldtype(T, fi)
            if _cub_ft isa Union && !isempty(field_val_bytes)
                local _cub_info = get(ctx.type_registry.unions, _cub_ft, nothing)
                local _cub_wfi = fi + Int(info.field_offset)
                if _cub_info !== nothing && struct_type_def isa StructType &&
                   _cub_wfi <= length(struct_type_def.fields) &&
                   (struct_type_def.fields[_cub_wfi].valtype isa ConcreteRef) &&
                   Int(struct_type_def.fields[_cub_wfi].valtype.type_idx) == Int(_cub_info.wasm_type_idx) &&
                   (has_ref_producing_gc_op(field_val_bytes) || field_val_bytes[1] == Opcode.REF_NULL)
                    _cub_boxed = UInt8[]
                    push!(_cub_boxed, Opcode.I32_CONST)
                    append!(_cub_boxed, encode_leb128_signed(Int64(0)))   # typeId
                    push!(_cub_boxed, Opcode.I32_CONST)
                    append!(_cub_boxed, encode_leb128_signed(Int64(get(_cub_info.tag_map, typeof(field_val), Int32(0)))))
                    append!(_cub_boxed, field_val_bytes)                   # value (ref ⊑ anyref)
                    push!(_cub_boxed, Opcode.GC_PREFIX)
                    push!(_cub_boxed, Opcode.STRUCT_NEW)
                    append!(_cub_boxed, encode_leb128_unsigned(_cub_info.wasm_type_idx))
                    field_val_bytes = _cub_boxed
                end
            end
            # TRUE-TI-001: If compile_value produced no bytes (e.g., Module, Function),
            # emit ref.null for the field's expected type
            if isempty(field_val_bytes)
                local _empty_fi = fi + Int(info.field_offset)
                if struct_type_def isa StructType && _empty_fi <= length(struct_type_def.fields)
                    empty_field_type = struct_type_def.fields[_empty_fi].valtype
                    if empty_field_type isa ConcreteRef
                        ref_null!(b, Int64(empty_field_type.type_idx), ConcreteRef(UInt32(empty_field_type.type_idx), true))
                    elseif empty_field_type === AnyRef
                        ref_null!(b, AnyRef)
                    elseif empty_field_type === ExternRef
                        ref_null!(b, ExternRef)
                    elseif empty_field_type === I32
                        i32_const!(b, 0)
                    elseif empty_field_type === I64
                        i64_const!(b, 0)
                    else
                        ref_null!(b, AnyRef)
                    end
                    continue
                end
            end
            # Check field type compatibility
            replaced = false
            local _wasm_fi = fi + Int(info.field_offset)  # PURE-9024: skip typeId
            if struct_type_def isa StructType && _wasm_fi <= length(struct_type_def.fields)
                expected_wasm = struct_type_def.fields[_wasm_fi].valtype
                if expected_wasm isa ConcreteRef || expected_wasm === StructRef || expected_wasm === ArrayRef || expected_wasm === AnyRef || expected_wasm === ExternRef
                    # Field expects a ref type — check if field_val_bytes produces something incompatible
                    need_replace = false
                    if length(field_val_bytes) >= 3
                        # Check if ends with struct_new of incompatible type
                        for scan_pos in (length(field_val_bytes)-2):-1:1
                            if field_val_bytes[scan_pos] == 0xFB && field_val_bytes[scan_pos+1] == 0x00
                                sn_type_idx = 0; sn_shift = 0
                                for bi in (scan_pos+2):length(field_val_bytes)
                                    byt = field_val_bytes[bi]
                                    sn_type_idx |= (Int(byt & 0x7f) << sn_shift)
                                    sn_shift += 7
                                    if (byt & 0x80) == 0
                                        if bi == length(field_val_bytes)
                                            if expected_wasm isa ConcreteRef && sn_type_idx != expected_wasm.type_idx
                                                need_replace = true
                                            elseif expected_wasm === ArrayRef || expected_wasm === ExternRef
                                                # ArrayRef: struct is not an array
                                                # ExternRef: struct ref needs extern.convert_any
                                                # AnyRef/StructRef: struct refs are valid subtypes, no replace needed
                                                need_replace = true
                                            end
                                        end
                                        break
                                    end
                                end
                                break
                            end
                        end
                    end
                    if !need_replace && length(field_val_bytes) >= 1
                        # Check if field produces a numeric value (i32/i64 const or local.get of numeric)
                        # BUT NOT if the bytes end with struct.new or array.new_fixed (GC_PREFIX + opcode)
                        # which indicates a complex ref value (String, Symbol, struct), not a simple numeric.
                        # String constants start with i32.const (char 1) but end with array.new_fixed.
                        first_byte = field_val_bytes[1]
                        ends_with_ref_producing_gc = has_ref_producing_gc_op(field_val_bytes)
                        if (first_byte == 0x41 || first_byte == 0x42) && !ends_with_ref_producing_gc  # I32_CONST or I64_CONST
                            need_replace = true
                        elseif first_byte == 0x20  # LOCAL_GET
                            src_idx = 0; shift = 0
                            for bi in 2:length(field_val_bytes)
                                byt = field_val_bytes[bi]
                                src_idx |= (Int(byt & 0x7f) << shift)
                                shift += 7
                                (byt & 0x80) == 0 && break
                            end
                            arr_idx = src_idx - ctx.n_params + 1
                            if arr_idx >= 1 && arr_idx <= length(ctx.locals)
                                src_type = ctx.locals[arr_idx]
                                if src_type === I64 || src_type === I32
                                    need_replace = true
                                end
                            end
                        end
                    end
                    if need_replace
                        if expected_wasm isa ConcreteRef
                            ref_null!(b, Int64(expected_wasm.type_idx), ConcreteRef(UInt32(expected_wasm.type_idx), true))
                        elseif expected_wasm === ArrayRef
                            ref_null!(b, ArrayRef)
                        elseif expected_wasm === ExternRef
                            ref_null!(b, ExternRef)
                        else
                            ref_null!(b, StructRef)
                        end
                        field_val_bytes = UInt8[]
                        replaced = true
                    end
                end
            end
            emit_raw!(b, field_val_bytes; pushes=WasmValType[AnyRef])
            # If field expects externref but we produced a GC-managed ref (anyref subtype, e.g.
            # string/symbol array or struct), emit extern.convert_any to bridge the two worlds.
            # (Strings/Symbols compile as ConcreteRef to char array; externref slots need conversion.)
            local _wasm_fi2 = fi + Int(info.field_offset)  # PURE-9024: skip typeId
            if !replaced && struct_type_def isa StructType && _wasm_fi2 <= length(struct_type_def.fields)
                local _ef = struct_type_def.fields[_wasm_fi2].valtype
                if _ef === ExternRef
                    # Check not already externref (ends with 0xFB 0x1B = EXTERN_CONVERT_ANY)
                    already_extern = length(field_val_bytes) >= 2 &&
                                     field_val_bytes[end-1] == 0xFB &&
                                     field_val_bytes[end] == Opcode.EXTERN_CONVERT_ANY
                    if !already_extern && has_ref_producing_gc_op(field_val_bytes)
                        extern_convert_any!(b)
                    elseif !already_extern && length(field_val_bytes) >= 2 && field_val_bytes[1] == 0x23
                        # PURE-6025: global.get produces a concrete ref (e.g., Type constant)
                        # but field expects externref — need extern.convert_any.
                        # global.get has no GC prefix, so has_ref_producing_gc_op misses it.
                        _g_idx = 0; _g_shift = 0
                        for _gbi in 2:length(field_val_bytes)
                            _gb = field_val_bytes[_gbi]
                            _g_idx |= (Int(_gb & 0x7f) << _g_shift)
                            _g_shift += 7
                            (_gb & 0x80) == 0 && break
                        end
                        if _g_idx + 1 <= length(ctx.mod.globals)
                            _g_type = ctx.mod.globals[_g_idx + 1].valtype
                            if _g_type !== ExternRef
                                extern_convert_any!(b)
                            end
                        else
                            # Unknown global — conservatively emit conversion
                            extern_convert_any!(b)
                        end
                    end
                end
            end
        end

        # Create the struct
        struct_new!(b, type_idx, WasmValType[])
        finally
            pop!(_VALUE_COMPILE_STACK)
        end
    end

    return builder_code(b)
end

