# ============================================================================
# Value Compilation
# ============================================================================

"""
Get the Wasm type that compile_value will push on the stack for a given value.
Used to detect type mismatches at return sites.
"""
function infer_value_wasm_type(val, ctx::CompilationContext)::WasmValType
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
            # If we can't resolve, fall back to ExternRef
            return ExternRef
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
        return ExternRef
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
        elseif val isa Int32 || val isa UInt32 || val isa Bool
            return I32
        elseif val isa Float64
            return F64
        elseif val isa Float32
            return F32
        elseif val isa QuoteNode
            # PURE-043: QuoteNode wraps a value - recursively determine its type
            return infer_value_wasm_type(val.value, ctx)
        elseif val isa Symbol || val isa String
            # PURE-043: Symbol/String compile to array_new_fixed (ConcreteRef)
            str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
            return ConcreteRef(str_type_idx, false)
        elseif val isa Type
            # PURE-4155: Type values (like Bool, Int64) compile to global.get (DataType struct ref).
            # Must check BEFORE isstructtype since typeof(Type) is DataType (a struct)
            info = register_struct_type!(ctx.mod, ctx.type_registry, DataType)
            return ConcreteRef(info.wasm_type_idx, true)
        elseif isstructtype(typeof(val))
            # PURE-043: Struct values compile to struct_new (ConcreteRef)
            return get_concrete_wasm_type(typeof(val), ctx.mod, ctx.type_registry)
        else
            return ExternRef
        end
    end
end

"""
Check if two wasm types are compatible for return (can be used interchangeably).
Numeric types (I32/I64/F32/F64) are only compatible with themselves.
Ref types are compatible with each other for externref purposes.
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
    return false
end

"""
PURE-908: Compile a GotoIfNot condition to i32.
When the condition SSA value has an anyref/externref local (because Julia typed it as Any),
the raw compile_value would push anyref, but i32.eqz needs i32. This helper unboxes via
ref.cast + struct.get when needed.
"""
function compile_condition_to_i32(cond, ctx::CompilationContext)::Vector{UInt8}
    bytes = compile_value(cond, ctx)
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
                    # Value is anyref/externref but should be i32 (Bool).
                    # Unbox: ref.cast (ref null $i32_box) → struct.get $i32_box 0
                    if local_type === ExternRef
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.ANY_CONVERT_EXTERN)
                    end
                    box_type_idx = get_numeric_box_type!(ctx.mod, ctx.type_registry, I32)
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.REF_CAST_NULL)
                    append!(bytes, encode_leb128_signed(Int64(box_type_idx)))
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.STRUCT_GET)
                    append!(bytes, encode_leb128_unsigned(box_type_idx))
                    append!(bytes, encode_leb128_unsigned(0))  # field 0
                elseif local_type isa ConcreteRef
                    # PURE-6025: Value is a concrete ref (tagged union struct) but should
                    # be i32 (Bool). This happens when a stubbed call's result local was
                    # allocated as a tagged union (e.g., Union{Bool, Nothing} → struct{i32, anyref})
                    # but the GotoIfNot condition expects i32. Extract i32 tag from field 0.
                    # Check that the struct type's field 0 is actually i32 before extracting.
                    type_idx = local_type.type_idx
                    if type_idx + 1 <= length(ctx.mod.types)
                        mod_type = ctx.mod.types[type_idx + 1]
                        if mod_type isa StructType && !isempty(mod_type.fields) && mod_type.fields[1].valtype === I32
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.STRUCT_GET)
                            append!(bytes, encode_leb128_unsigned(type_idx))
                            append!(bytes, encode_leb128_unsigned(0))  # field 0 (i32 tag)
                        else
                            # Not a tagged union — drop the ref and push i32 default
                            push!(bytes, Opcode.DROP)
                            push!(bytes, Opcode.I32_CONST, 0x00)
                        end
                    else
                        # Unknown type — drop and push i32 default
                        push!(bytes, Opcode.DROP)
                        push!(bytes, Opcode.I32_CONST, 0x00)
                    end
                elseif local_type === StructRef || local_type === ArrayRef
                    # PURE-6025: Abstract ref in condition — drop and push i32 default
                    push!(bytes, Opcode.DROP)
                    push!(bytes, Opcode.I32_CONST, 0x00)
                end
            end
        end
    end
    return bytes
end

"""
Compile a value reference (SSA, Argument, or Literal).
"""
function compile_value(val, ctx::CompilationContext)::Vector{UInt8}
    bytes = UInt8[]

    # PURE-6022: If we're in dead code (previous sub-call was a stub), don't compile
    # more values. Emitting data after unreachable creates invalid WASM byte sequences
    # (e.g., array element i32_const values decode as block/loop instructions).
    if ctx.last_stmt_was_stub
        push!(bytes, 0x00)  # unreachable
        return bytes
    end

    # Handle nothing explicitly - it's the Julia singleton
    if val === nothing
        # Nothing maps to i32 in WasmGC — push i32(0) as placeholder
        push!(bytes, Opcode.I32_CONST)
        push!(bytes, 0x00)
        return bytes
    end

    if val isa Core.SSAValue
        # Check if this SSA has a local allocated (either regular or phi)
        if haskey(ctx.ssa_locals, val.id)
            local_idx = ctx.ssa_locals[val.id]
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(local_idx))
            # PURE-901: Narrow generic locals (anyref/structref) to concrete type.
            # When SSA type is concrete but local was allocated as generic (due to Union/Any),
            # ref.cast ensures downstream struct_get/array_get see the correct type.
            _narrow_generic_local!(bytes, local_idx, val.id, ctx)
        elseif haskey(ctx.phi_locals, val.id)
            # Phi node - load from phi local
            local_idx = ctx.phi_locals[val.id]
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(local_idx))
        else
            # No local - check if this is a PiNode
            # PURE-6021: Guard against out-of-bounds SSAValue IDs (e.g. sentinel Core.SSAValue(-2)
            # that appear as constant literals in IR of compiler functions like construct_ssa!)
            if val.id < 1 || val.id > length(ctx.code_info.code)
                return bytes  # Dead code - sentinel SSAValue with invalid id
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
                                push!(bytes, Opcode.REF_NULL)
                                append!(bytes, encode_leb128_signed(Int64(wasm_type.type_idx)))
                                emitted_nothing = true
                            end
                        end
                    end
                    if !emitted_nothing
                        # Nothing is i32(0) as placeholder — this is what the callee expects
                        push!(bytes, Opcode.I32_CONST)
                        push!(bytes, 0x00)
                    end
                else
                    # Non-Nothing PiNode without local: re-emit the underlying value.
                    # Can't assume it's on the stack since block boundaries clear the stack.
                    append!(bytes, compile_value(stmt.val, ctx))
                end
            else
                # Non-PiNode SSA without local: re-compile the statement to reproduce its value.
                if stmt isa Expr && stmt.head === :boundscheck
                    push!(bytes, Opcode.I32_CONST)
                    push!(bytes, 0x00)
                elseif stmt isa Expr && (stmt.head === :call || stmt.head === :invoke || stmt.head === :new || stmt.head === :foreigncall)
                    # Re-compile the expression to produce its value on the stack.
                    # Call the specific compiler directly to avoid compile_statement's
                    # orphan-prevention skip for multi-arg memoryrefnew.
                    if stmt.head === :call
                        append!(bytes, compile_call(stmt, val.id, ctx))
                    elseif stmt.head === :invoke
                        append!(bytes, compile_invoke(stmt, val.id, ctx))
                    elseif stmt.head === :new
                        append!(bytes, compile_new(stmt, val.id, ctx))
                    elseif stmt.head === :foreigncall
                        append!(bytes, compile_foreigncall(stmt, val.id, ctx))
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
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(local_idx))
        end

    elseif val isa Core.SlotNumber
        # PURE-6024: Check slot_locals first (for local variables in unoptimized IR),
        # then fall back to param mapping (slot 2 = param 0, slot 3 = param 1, etc.)
        if haskey(ctx.slot_locals, val.id)
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(ctx.slot_locals[val.id]))
        else
            local_idx = val.id - 2
            if local_idx >= 0
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(local_idx))
            end
        end

    elseif val isa Bool
        push!(bytes, Opcode.I32_CONST)
        push!(bytes, val ? 0x01 : 0x00)

    elseif val isa Char
        # Char is represented as i32 (raw UInt32 bits, not Unicode codepoint)
        # Use reinterpret to avoid InvalidCharError for invalid chars like EOF_CHAR (0xFFFFFFFF)
        push!(bytes, Opcode.I32_CONST)
        append!(bytes, encode_leb128_signed(reinterpret(Int32, reinterpret(UInt32, val))))

    elseif val isa Int8 || val isa UInt8 || val isa Int16 || val isa UInt16
        # Small integers - stored as i32 in WASM
        push!(bytes, Opcode.I32_CONST)
        append!(bytes, encode_leb128_signed(Int32(val)))

    elseif val isa Int32
        push!(bytes, Opcode.I32_CONST)
        append!(bytes, encode_leb128_signed(val))

    elseif val isa UInt32
        push!(bytes, Opcode.I32_CONST)
        append!(bytes, encode_leb128_signed(reinterpret(Int32, val)))

    elseif val isa Int64 || val isa Int
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(Int64(val)))

    elseif val isa UInt64
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(reinterpret(Int64, val)))

    elseif val isa Int128 || val isa UInt128
        # 128-bit integers are represented as WasmGC structs with (lo, hi) fields
        result_type = typeof(val)
        type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)

        # Extract lo (low 64 bits) and hi (high 64 bits)
        lo = UInt64(val & 0xFFFFFFFFFFFFFFFF)
        hi = UInt64((val >> 64) & 0xFFFFFFFFFFFFFFFF)

        # Push lo value
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(reinterpret(Int64, lo)))

        # Push hi value
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(reinterpret(Int64, hi)))

        # Create struct
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_NEW)
        append!(bytes, encode_leb128_unsigned(type_idx))

    elseif val isa Float32
        push!(bytes, Opcode.F32_CONST)
        append!(bytes, reinterpret(UInt8, [val]))

    elseif val isa Float64
        push!(bytes, Opcode.F64_CONST)
        append!(bytes, reinterpret(UInt8, [val]))

    elseif val isa String
        # String constant - create a WasmGC array with the characters
        # Get the string array type
        type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

        # Push each character as an i32
        for c in val
            push!(bytes, Opcode.I32_CONST)
            append!(bytes, encode_leb128_signed(Int32(c)))
        end

        # array.new_fixed $type_idx $length
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_NEW_FIXED)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(length(val)))

    elseif val isa GlobalRef
        # Check if this GlobalRef is a module-level global (mutable struct instance)
        key = (val.mod, val.name)
        if haskey(ctx.module_globals, key)
            # Emit global.get instead of creating a new struct instance
            global_idx = ctx.module_globals[key]
            push!(bytes, Opcode.GLOBAL_GET)
            append!(bytes, encode_leb128_unsigned(global_idx))
        else
            # GlobalRef to a constant - evaluate and compile the value
            try
                actual_val = getfield(val.mod, val.name)
                append!(bytes, compile_value(actual_val, ctx))
            catch
                # If we can't evaluate, might be a type reference (no runtime value)
            end
        end

    elseif val isa QuoteNode
        # QuoteNode wraps a constant value - unwrap and compile
        append!(bytes, compile_value(val.value, ctx))

    elseif isprimitivetype(typeof(val)) && !isa(val, Bool) && !isa(val, Char) &&
           !isa(val, Int8) && !isa(val, Int16) && !isa(val, Int32) && !isa(val, Int64) &&
           !isa(val, UInt8) && !isa(val, UInt16) && !isa(val, UInt32) && !isa(val, UInt64) &&
           !isa(val, Float32) && !isa(val, Float64)
        # Custom primitive type (e.g., JuliaSyntax.Kind) - bitcast to integer
        T = typeof(val)
        sz = sizeof(T)
        if sz == 1
            int_val = Core.Intrinsics.bitcast(UInt8, val)
            push!(bytes, Opcode.I32_CONST)
            append!(bytes, encode_leb128_signed(Int32(int_val)))
        elseif sz == 2
            int_val = Core.Intrinsics.bitcast(UInt16, val)
            push!(bytes, Opcode.I32_CONST)
            append!(bytes, encode_leb128_signed(Int32(int_val)))
        elseif sz == 4
            int_val = Core.Intrinsics.bitcast(UInt32, val)
            push!(bytes, Opcode.I32_CONST)
            append!(bytes, encode_leb128_signed(Int32(int_val)))
        elseif sz == 8
            int_val = Core.Intrinsics.bitcast(UInt64, val)
            push!(bytes, Opcode.I64_CONST)
            append!(bytes, encode_leb128_signed(Int64(int_val)))
        else
            error("Primitive type with unsupported size for Wasm: $T ($sz bytes)")
        end

    elseif val isa Symbol
        # Symbol constant - represent as string (byte array of its name)
        # Uses same representation as String constants
        type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
        name_str = String(val)

        # Push each character as an i32 (same as String compilation)
        for c in name_str
            push!(bytes, Opcode.I32_CONST)
            append!(bytes, encode_leb128_signed(Int32(c)))
        end

        # array.new_fixed $type_idx $length
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_NEW_FIXED)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(length(name_str)))

    elseif typeof(val) <: Tuple
        # Tuple constant - create it with struct.new
        T = typeof(val)

        # Ensure tuple type is registered using register_tuple_type!
        info = register_tuple_type!(ctx.mod, ctx.type_registry, T)
        type_idx = info.wasm_type_idx

        # Get the struct type definition to check expected field types
        struct_type_def = ctx.mod.types[type_idx + 1]

        # Push field values (tuples use 1-based indexing)
        for i in 1:length(val)
            field_val = val[i]
            # PURE-141: When field value is a Type constant and field expects a ref type,
            # emit ref.null instead of i32.const 0 (compile_value(Type) returns i32)
            expected_wasm = nothing
            if struct_type_def isa StructType && i <= length(struct_type_def.fields)
                expected_wasm = struct_type_def.fields[i].valtype
            end
            if field_val isa Type && expected_wasm !== nothing &&
               (expected_wasm isa ConcreteRef || expected_wasm === StructRef ||
                expected_wasm === ArrayRef || expected_wasm === AnyRef || expected_wasm === ExternRef)
                # Type value needs ref type - emit ref.null of expected type
                if expected_wasm isa ConcreteRef
                    push!(bytes, Opcode.REF_NULL)
                    append!(bytes, encode_leb128_signed(Int64(expected_wasm.type_idx)))
                elseif expected_wasm === ArrayRef
                    push!(bytes, Opcode.REF_NULL)
                    push!(bytes, UInt8(ArrayRef))
                elseif expected_wasm === ExternRef
                    push!(bytes, Opcode.REF_NULL)
                    push!(bytes, UInt8(ExternRef))
                elseif expected_wasm === AnyRef
                    push!(bytes, Opcode.REF_NULL)
                    push!(bytes, UInt8(AnyRef))
                else
                    push!(bytes, Opcode.REF_NULL)
                    push!(bytes, UInt8(StructRef))
                end
            else
                append!(bytes, compile_value(field_val, ctx))
            end
        end

        # Create the struct
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_NEW)
        append!(bytes, encode_leb128_unsigned(type_idx))

    elseif val isa Type
        # PURE-4151: Type constant — each unique Type gets a unique Wasm global
        # so that ref.eq can distinguish different Type objects at runtime.
        # Previous behavior (i32.const 0) made all Types indistinguishable.
        global_idx = get_type_constant_global!(ctx.mod, ctx.type_registry, val)
        push!(bytes, Opcode.GLOBAL_GET)
        append!(bytes, encode_leb128_unsigned(global_idx))

    elseif val isa Module
        # Module constant — empty struct (fieldcount=0), like Function singletons.
        # Used for === identity checks (ref.eq). Each struct.new creates a unique ref.
        info = register_struct_type!(ctx.mod, ctx.type_registry, Module)
        type_idx = info.wasm_type_idx
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_NEW)
        append!(bytes, encode_leb128_unsigned(type_idx))

    elseif val isa Function && isstructtype(typeof(val)) && fieldcount(typeof(val)) == 0
        # Function singleton (e.g., typeof(some_function)) — empty struct with no fields
        T = typeof(val)
        info = register_struct_type!(ctx.mod, ctx.type_registry, T)
        type_idx = info.wasm_type_idx
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_NEW)
        append!(bytes, encode_leb128_unsigned(type_idx))

    elseif val isa Function && isstructtype(typeof(val)) && fieldcount(typeof(val)) > 0
        # PURE-325: Function closure with captured fields (e.g., Fix2{typeof(isequal), Char})
        # These are structs that happen to be Functions — compile like regular structs
        T = typeof(val)
        info = register_struct_type!(ctx.mod, ctx.type_registry, T)
        type_idx = info.wasm_type_idx

        has_undefined = any(!isdefined(val, fn) for fn in fieldnames(T))
        if has_undefined
            push!(bytes, Opcode.REF_NULL)
            append!(bytes, encode_leb128_signed(Int64(type_idx)))
            return bytes
        end

        struct_type_def = ctx.mod.types[type_idx + 1]
        for (fi, field_name) in enumerate(fieldnames(T))
            field_val = getfield(val, field_name)
            append!(bytes, compile_value(field_val, ctx))
        end

        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_NEW)
        append!(bytes, encode_leb128_unsigned(type_idx))

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

        # Helper: emit default value for an array element type
        function emit_array_default!(bytes, arr_type_idx, elem_type, ctx)
            wasm_et = julia_to_wasm_type(elem_type)
            if wasm_et === I32
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
            elseif wasm_et === I64
                push!(bytes, Opcode.I64_CONST)
                push!(bytes, 0x00)
            elseif wasm_et === F32
                push!(bytes, Opcode.F32_CONST)
                append!(bytes, reinterpret(UInt8, [Float32(0)]))
            elseif wasm_et === F64
                push!(bytes, Opcode.F64_CONST)
                append!(bytes, reinterpret(UInt8, [Float64(0)]))
            else
                # Ref type (String, struct, etc.) — look up concrete array element type
                arr_type_def = ctx.mod.types[arr_type_idx + 1]
                if arr_type_def isa ArrayType
                    evtype = arr_type_def.elem.valtype
                    if evtype isa ConcreteRef
                        push!(bytes, Opcode.REF_NULL)
                        append!(bytes, encode_leb128_signed(Int64(evtype.type_idx)))
                    else
                        push!(bytes, Opcode.REF_NULL)
                        push!(bytes, UInt8(StructRef))
                    end
                else
                    push!(bytes, Opcode.REF_NULL)
                    push!(bytes, UInt8(StructRef))
                end
            end
        end

        # Helper: compile Memory elements, handling UndefRefError for ref-typed slots
        function compile_memory_elements!(bytes, mem, arr_type_idx, elem_type, ctx)
            for i in 1:length(mem)
                # PURE-6022: Stop emitting elements after stub/unreachable
                if ctx.last_stmt_was_stub
                    break
                end
                try
                    v = mem[i]
                    append!(bytes, compile_value(v, ctx))
                catch e
                    if e isa UndefRefError
                        emit_array_default!(bytes, arr_type_idx, elem_type, ctx)
                    else
                        rethrow()
                    end
                end
            end
        end

        # field 0: slots — array of UInt8 (always defined, never throws)
        for i in 1:length(dict_slots)
            push!(bytes, Opcode.I32_CONST)
            append!(bytes, encode_leb128_signed(Int32(dict_slots[i])))
        end
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_NEW_FIXED)
        append!(bytes, encode_leb128_unsigned(slots_arr_type))
        append!(bytes, encode_leb128_unsigned(length(dict_slots)))

        # field 1: keys — array of K (may have undef for ref-typed keys)
        compile_memory_elements!(bytes, dict_keys, keys_arr_type, K, ctx)
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_NEW_FIXED)
        append!(bytes, encode_leb128_unsigned(keys_arr_type))
        append!(bytes, encode_leb128_unsigned(length(dict_keys)))

        # field 2: vals — array of V (may have undef for ref-typed vals)
        compile_memory_elements!(bytes, dict_vals, vals_arr_type, V, ctx)
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_NEW_FIXED)
        append!(bytes, encode_leb128_unsigned(vals_arr_type))
        append!(bytes, encode_leb128_unsigned(length(dict_vals)))

        # field 3: ndel (i64)
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(Int64(getfield(val, :ndel))))

        # field 4: count (i64)
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(Int64(getfield(val, :count))))

        # field 5: age (u64, stored as i64)
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(Int64(getfield(val, :age))))

        # field 6: idxfloor (i64)
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(Int64(getfield(val, :idxfloor))))

        # field 7: maxprobe (i64)
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(Int64(getfield(val, :maxprobe))))

        # struct.new
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_NEW)
        append!(bytes, encode_leb128_unsigned(dict_info.wasm_type_idx))

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

        # Field 0: data array — emit array.new_fixed with actual element values
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
                has_gc_prefix = any(b == Opcode.GC_PREFIX for b in elem_bytes)
                is_numeric_elem = !has_gc_prefix && length(elem_bytes) >= 1 &&
                                  (elem_bytes[1] == Opcode.I32_CONST || elem_bytes[1] == Opcode.I64_CONST ||
                                   elem_bytes[1] == Opcode.F32_CONST || elem_bytes[1] == Opcode.F64_CONST)
                if is_numeric_elem
                    # Box numeric value into a struct then convert to externref
                    val_wasm_elem = elem_bytes[1] == Opcode.I32_CONST ? I32 :
                                    elem_bytes[1] == Opcode.I64_CONST ? I64 :
                                    elem_bytes[1] == Opcode.F32_CONST ? F32 : F64
                    emit_numeric_to_externref!(bytes, elem_val, val_wasm_elem, ctx)
                elseif !isempty(elem_bytes) && elem_bytes[end] == UInt8(ExternRef) &&
                       length(elem_bytes) >= 2 && elem_bytes[end-1] == Opcode.REF_NULL
                    # Already externref (ref.null extern) — no conversion needed
                    append!(bytes, elem_bytes)
                else
                    append!(bytes, elem_bytes)
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                end
            else
                append!(bytes, compile_value(val[i], ctx))
            end
            # PURE-6022: Check after each element in case compile_value hit a stub
            if ctx.last_stmt_was_stub
                break
            end
        end
        # PURE-6022: Skip array_new_fixed if we're in dead code (stub was hit)
        if !ctx.last_stmt_was_stub
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ARRAY_NEW_FIXED)
            append!(bytes, encode_leb128_unsigned(array_type_idx))
            append!(bytes, encode_leb128_unsigned(length(val)))
        end

        # Field 1: size tuple — Tuple{Int64} with the length
        size_tuple_type = Tuple{Int64}
        if !haskey(ctx.type_registry.structs, size_tuple_type)
            register_tuple_type!(ctx.mod, ctx.type_registry, size_tuple_type)
        end
        size_info = ctx.type_registry.structs[size_tuple_type]
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(Int64(length(val))))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_NEW)
        append!(bytes, encode_leb128_unsigned(size_info.wasm_type_idx))

        # struct.new for Vector{T}
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_NEW)
        append!(bytes, encode_leb128_unsigned(vec_info.wasm_type_idx))

    elseif typeof(val) isa DataType && typeof(val).name.name in (:MemoryRef, :GenericMemoryRef, :Memory, :GenericMemory)
        # PURE-049: MemoryRef/Memory constants map to array types, not struct types.
        # These appear as captured closure fields. Emit ref.null of the array type.
        T = typeof(val)
        elem_type = T.name.name in (:GenericMemoryRef, :GenericMemory) ? T.parameters[2] : T.parameters[1]
        array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
        push!(bytes, Opcode.REF_NULL)
        append!(bytes, encode_leb128_signed(Int64(array_type_idx)))

    elseif isstructtype(typeof(val)) && !isa(val, Function) && !isa(val, Module)
        # Struct constant - create it with struct.new
        T = typeof(val)

        # Ensure struct type is registered and get its type index
        info = register_struct_type!(ctx.mod, ctx.type_registry, T)
        type_idx = info.wasm_type_idx

        # Check for undefined fields before attempting to compile struct constant
        # Core types like TypeName often have undefined fields (e.g., partial)
        has_undefined = any(!isdefined(val, fn) for fn in fieldnames(T))
        if has_undefined
            # Struct has undefined fields - emit ref.null for the struct type
            push!(bytes, Opcode.REF_NULL)
            append!(bytes, encode_leb128_signed(Int64(type_idx)))
            return bytes
        end

        # Push field values with type safety checks
        struct_type_def = ctx.mod.types[type_idx + 1]
        for (fi, field_name) in enumerate(fieldnames(T))
            field_val = getfield(val, field_name)
            field_val_bytes = compile_value(field_val, ctx)
            # Check field type compatibility
            replaced = false
            if struct_type_def isa StructType && fi <= length(struct_type_def.fields)
                expected_wasm = struct_type_def.fields[fi].valtype
                if expected_wasm isa ConcreteRef || expected_wasm === StructRef || expected_wasm === ArrayRef || expected_wasm === AnyRef || expected_wasm === ExternRef
                    # Field expects a ref type — check if field_val_bytes produces something incompatible
                    need_replace = false
                    if length(field_val_bytes) >= 3
                        # Check if ends with struct_new of incompatible type
                        for scan_pos in (length(field_val_bytes)-2):-1:1
                            if field_val_bytes[scan_pos] == 0xFB && field_val_bytes[scan_pos+1] == 0x00
                                sn_type_idx = 0; sn_shift = 0
                                for bi in (scan_pos+2):length(field_val_bytes)
                                    b = field_val_bytes[bi]
                                    sn_type_idx |= (Int(b & 0x7f) << sn_shift)
                                    sn_shift += 7
                                    if (b & 0x80) == 0
                                        if bi == length(field_val_bytes)
                                            if expected_wasm isa ConcreteRef && sn_type_idx != expected_wasm.type_idx
                                                need_replace = true
                                            elseif expected_wasm === ArrayRef || expected_wasm === ExternRef || expected_wasm === AnyRef
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
                                b = field_val_bytes[bi]
                                src_idx |= (Int(b & 0x7f) << shift)
                                shift += 7
                                (b & 0x80) == 0 && break
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
                            push!(bytes, Opcode.REF_NULL)
                            append!(bytes, encode_leb128_signed(Int64(expected_wasm.type_idx)))
                        elseif expected_wasm === ArrayRef
                            push!(bytes, Opcode.REF_NULL)
                            push!(bytes, UInt8(ArrayRef))
                        elseif expected_wasm === ExternRef
                            push!(bytes, Opcode.REF_NULL)
                            push!(bytes, UInt8(ExternRef))
                        else
                            push!(bytes, Opcode.REF_NULL)
                            push!(bytes, UInt8(StructRef))
                        end
                        field_val_bytes = UInt8[]
                        replaced = true
                    end
                end
            end
            append!(bytes, field_val_bytes)
            # If field expects externref but we produced a GC-managed ref (anyref subtype, e.g.
            # string/symbol array or struct), emit extern.convert_any to bridge the two worlds.
            # (Strings/Symbols compile as ConcreteRef to char array; externref slots need conversion.)
            if !replaced && struct_type_def isa StructType && fi <= length(struct_type_def.fields)
                local _ef = struct_type_def.fields[fi].valtype
                if _ef === ExternRef
                    # Check not already externref (ends with 0xFB 0x1B = EXTERN_CONVERT_ANY)
                    already_extern = length(field_val_bytes) >= 2 &&
                                     field_val_bytes[end-1] == 0xFB &&
                                     field_val_bytes[end] == Opcode.EXTERN_CONVERT_ANY
                    if !already_extern && has_ref_producing_gc_op(field_val_bytes)
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
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
                                push!(bytes, Opcode.GC_PREFIX)
                                push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                            end
                        else
                            # Unknown global — conservatively emit conversion
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                        end
                    end
                end
            end
        end

        # Create the struct
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_NEW)
        append!(bytes, encode_leb128_unsigned(type_idx))
    end

    return bytes
end

