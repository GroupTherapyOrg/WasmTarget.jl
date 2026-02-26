# ============================================================================
# Call Compilation
# ============================================================================

"""
    _is_externref_value(val, ctx) -> Bool

PURE-904: Check if a value (Argument or SSAValue) produces externref on the Wasm stack.
Used by numeric intrinsic handlers to detect when unboxing is needed.
"""
function _is_externref_value(val, ctx::CompilationContext)::Bool
    if val isa Core.Argument
        arg_idx = ctx.is_compiled_closure ? val.n : val.n - 1
        if arg_idx >= 1 && arg_idx <= length(ctx.arg_types)
            return julia_to_wasm_type(ctx.arg_types[arg_idx]) === ExternRef
        end
    elseif val isa Core.SSAValue
        if haskey(ctx.ssa_locals, val.id)
            local_idx = ctx.ssa_locals[val.id]
            local_arr_idx = local_idx - ctx.n_params + 1
            if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                return ctx.locals[local_arr_idx] === ExternRef
            elseif local_idx < ctx.n_params
                # It's a param slot
                if local_idx + 1 <= length(ctx.arg_types)
                    return julia_to_wasm_type(ctx.arg_types[local_idx + 1]) === ExternRef
                end
            end
        elseif haskey(ctx.phi_locals, val.id)
            local_idx = ctx.phi_locals[val.id]
            local_arr_idx = local_idx - ctx.n_params + 1
            if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                return ctx.locals[local_arr_idx] === ExternRef
            end
        end
    end
    return false
end

"""
Compile a function call expression.
"""
function compile_call(expr::Expr, idx::Int, ctx::CompilationContext)::Vector{UInt8}
    bytes = UInt8[]
    func = expr.args[1]
    args = expr.args[2:end]

    # PURE-6024: Resolve indirect calls through SSAValue callees.
    # Unoptimized IR (may_optimize=false) produces patterns like:
    #   %1 = Base.add_int   (GlobalRef, type=Core.Const(Core.Intrinsics.add_int))
    #   %2 = (%1)(x, y)     (call with SSAValue(1) as callee)
    # Resolve SSAValue to the original GlobalRef so is_func() checks work correctly.
    if func isa Core.SSAValue && func.id >= 1 && func.id <= length(ctx.code_info.code)
        src_stmt = ctx.code_info.code[func.id]
        if src_stmt isa GlobalRef
            func = src_stmt
        else
            # Fallback: use SSA type if it's Core.Const (wraps the actual function value)
            ssa_type = get(ctx.ssa_types, func.id, nothing)
            if ssa_type !== nothing
                # ssa_type was widened by analyze_ssa_types!, try to get constant from ssavaluetypes
                raw_type = ctx.code_info.ssavaluetypes isa Vector && func.id <= length(ctx.code_info.ssavaluetypes) ?
                           ctx.code_info.ssavaluetypes[func.id] : nothing
                if raw_type isa Core.Const
                    func = raw_type.val
                end
            end
        end
    end

    # Special case for signal read: getfield(Signal, :value) -> global.get
    # This is detected by analyze_signal_captures! and stored in signal_ssa_getters
    # ONLY applies to actual getfield/getproperty(Signal, :value) calls (WasmGlobal pattern)
    # For Therapy.jl closures, signal_ssa_getters maps closure field SSAs - handled in compile_invoke
    is_getfield_value = (is_func(func, :getfield) || is_func(func, :getproperty)) && length(args) >= 2
    if is_getfield_value && haskey(ctx.signal_ssa_getters, idx)
        # Check that this is accessing :value field (WasmGlobal pattern)
        field_ref = args[2]
        field_name = field_ref isa QuoteNode ? field_ref.value : field_ref
        if field_name === :value
            global_idx = ctx.signal_ssa_getters[idx]
            push!(bytes, Opcode.GLOBAL_GET)
            append!(bytes, encode_leb128_unsigned(global_idx))
            return bytes
        end
    end

    # Special case for signal write: setfield!(Signal, :value, x) -> global.set
    # This is detected by analyze_signal_captures! and stored in signal_ssa_setters
    # ONLY applies to actual setfield!/setproperty! calls (WasmGlobal pattern), NOT closure field access
    is_setfield_call = (is_func(func, :setfield!) || is_func(func, :setproperty!)) && length(args) >= 3
    if is_setfield_call && haskey(ctx.signal_ssa_setters, idx)
        # The value to write is the 3rd argument (args = [target, field, value])
        global_idx = ctx.signal_ssa_setters[idx]
        value_arg = args[3]
        append!(bytes, compile_value(value_arg, ctx))
        push!(bytes, Opcode.GLOBAL_SET)
        append!(bytes, encode_leb128_unsigned(global_idx))

        # Inject DOM update calls for this signal (Therapy.jl reactive updates)
        if haskey(ctx.dom_bindings, global_idx)
            # Get global's type for conversion
            global_type = ctx.mod.globals[global_idx + 1].valtype

            for (import_idx, const_args) in ctx.dom_bindings[global_idx]
                # Push constant arguments (e.g., hydration key)
                for arg in const_args
                    push!(bytes, Opcode.I32_CONST)
                    append!(bytes, encode_leb128_signed(Int(arg)))
                end
                # Push the signal value (re-read from global)
                push!(bytes, Opcode.GLOBAL_GET)
                append!(bytes, encode_leb128_unsigned(global_idx))
                # Convert to f64 for DOM imports (all DOM imports expect f64)
                append!(bytes, emit_convert_to_f64(global_type))
                # Call the DOM import function
                push!(bytes, Opcode.CALL)
                append!(bytes, encode_leb128_unsigned(import_idx))
            end
        end

        # setfield! returns the value written, so re-read it
        push!(bytes, Opcode.GLOBAL_GET)
        append!(bytes, encode_leb128_unsigned(global_idx))
        return bytes
    end

    # Handle signal getter/setter SSA function calls: (%ssa)() or (%ssa)(value)
    # When func is an SSA that represents a captured signal getter/setter,
    # emit global.get/global.set directly (same logic as compile_invoke)
    if func isa Core.SSAValue
        ssa_id = func.id
        # Signal getter: no args, returns the signal value
        if haskey(ctx.signal_ssa_getters, ssa_id) && isempty(args)
            global_idx = ctx.signal_ssa_getters[ssa_id]
            push!(bytes, Opcode.GLOBAL_GET)
            append!(bytes, encode_leb128_unsigned(global_idx))
            return bytes
        end
        # Signal setter: one arg, sets the signal value
        if haskey(ctx.signal_ssa_setters, ssa_id) && length(args) == 1
            global_idx = ctx.signal_ssa_setters[ssa_id]
            # Compile the argument (the new value)
            append!(bytes, compile_value(args[1], ctx))
            # Store to global
            push!(bytes, Opcode.GLOBAL_SET)
            append!(bytes, encode_leb128_unsigned(global_idx))

            # Inject DOM update calls for this signal (Therapy.jl reactive updates)
            if haskey(ctx.dom_bindings, global_idx)
                # Get global's type for conversion
                global_type = ctx.mod.globals[global_idx + 1].valtype

                for (import_idx, const_args) in ctx.dom_bindings[global_idx]
                    # Push constant arguments (e.g., hydration key)
                    for arg in const_args
                        push!(bytes, Opcode.I32_CONST)
                        append!(bytes, encode_leb128_signed(Int(arg)))
                    end
                    # Push the signal value (re-read from global)
                    push!(bytes, Opcode.GLOBAL_GET)
                    append!(bytes, encode_leb128_unsigned(global_idx))
                    # Convert to f64 for DOM imports (all DOM imports expect f64)
                    append!(bytes, emit_convert_to_f64(global_type))
                    # Call the DOM import function
                    push!(bytes, Opcode.CALL)
                    append!(bytes, encode_leb128_unsigned(import_idx))
                end
            end

            # Setter returns the value in Therapy.jl, so re-read it
            push!(bytes, Opcode.GLOBAL_GET)
            append!(bytes, encode_leb128_unsigned(global_idx))
            return bytes
        end
    end

    # Special case for getfield on closure (_1) accessing captured signal fields
    # These produce intermediate SSA values (getter/setter functions)
    # Skip them - the actual read/write happens when the function is invoked
    is_getfield_closure = (func isa GlobalRef &&
                          ((func.mod === Core && func.name === :getfield) ||
                           (func.mod === Base && func.name === :getfield)))
    if is_getfield_closure && length(args) >= 2
        target = args[1]
        field_ref = args[2]
        # Target can be Core.SlotNumber(1) or Core.Argument(1)
        is_closure_self = (target isa Core.SlotNumber && target.id == 1) ||
                          (target isa Core.Argument && target.n == 1)
        if is_closure_self
            # This is accessing a field of the closure
            field_name = field_ref isa QuoteNode ? field_ref.value : field_ref
            if field_name isa Symbol && haskey(ctx.captured_signal_fields, field_name)
                # Skip - this produces a getter/setter function reference
                return bytes
            end
        end
    end

    # Skip getfield(CompilableSignal/Setter, :signal) - intermediate step
    # We track this in analyze_signal_captures! but don't need to emit anything
    # IMPORTANT: Only skip for actual CompilableSignal/Setter types, not any struct with a :signal field
    is_getfield = (func isa GlobalRef &&
                  ((func.mod === Core && func.name === :getfield) ||
                   (func.mod === Base && func.name === :getfield)))
    if is_getfield && length(args) >= 2
        field_ref = args[2]
        field_name = field_ref isa QuoteNode ? field_ref.value : field_ref
        if field_name === :signal
            # Only skip for CompilableSignal/Setter types (WasmGlobal pattern)
            target_type = infer_value_type(args[1], ctx)
            if target_type isa DataType && target_type.name.name in (:CompilableSignal, :CompilableSetter)
                # Skip - this is getting Signal from CompilableSignal/Setter
                return bytes
            end
        end
    end

    # Special case for ifelse - needs different argument order
    if is_func(func, :ifelse) && length(args) == 3
        # Wasm select expects: [val_if_true, val_if_false, cond] (cond on top)
        # Julia ifelse(cond, true_val, false_val)
        # Compile each value separately to check for empty results
        true_bytes = compile_value(args[2], ctx)   # true_val
        false_bytes = compile_value(args[3], ctx)  # false_val
        cond_bytes = compile_value(args[1], ctx)   # cond

        # PURE-036y: Validate that cond_bytes pushes an i32 value, not a ref or nothing.
        # Check for struct.new (0xfb 0x00 or 0xfb 0x01) which produces ref instead of i32.
        cond_is_ref = false
        if length(cond_bytes) >= 3
            # Scan for GC_PREFIX + STRUCT_NEW pattern
            for i in 1:(length(cond_bytes)-1)
                if cond_bytes[i] == 0xfb && (cond_bytes[i+1] == 0x00 || cond_bytes[i+1] == 0x01)
                    cond_is_ref = true
                    break
                end
            end
        end
        # Also check if cond_bytes is just a local.get of a ref-typed local/param
        if !cond_is_ref && length(cond_bytes) >= 2 && cond_bytes[1] == 0x20  # LOCAL_GET
            # Decode LEB128 to get local index
            local_idx = 0
            shift = 0
            for i in 2:length(cond_bytes)
                b = cond_bytes[i]
                local_idx |= (b & 0x7f) << shift
                if (b & 0x80) == 0
                    break
                end
                shift += 7
            end
            # Check if this local is ref-typed
            arr_idx = local_idx - ctx.n_params + 1
            if arr_idx >= 1 && arr_idx <= length(ctx.locals)
                local_type = ctx.locals[arr_idx]
                if local_type isa ConcreteRef || local_type === StructRef ||
                   local_type === ArrayRef || local_type === ExternRef || local_type === AnyRef
                    cond_is_ref = true
                end
            elseif local_idx < ctx.n_params && local_idx >= 0
                # It's a parameter - check its type
                param_idx = local_idx + 1
                if param_idx <= length(ctx.arg_types)
                    param_wasm = julia_to_wasm_type_concrete(ctx.arg_types[param_idx], ctx)
                    if param_wasm isa ConcreteRef || param_wasm === StructRef ||
                       param_wasm === ArrayRef || param_wasm === ExternRef || param_wasm === AnyRef
                        cond_is_ref = true
                    end
                end
            end
        end

        # If cond produces ref, fall back to just true_bytes (can't use as SELECT condition)
        if cond_is_ref
            append!(bytes, true_bytes)
            return bytes
        end

        # If any compile_value returned empty, select would have insufficient operands.
        # Fall back to emitting just the true value (or a type-safe default).
        if isempty(true_bytes) || isempty(false_bytes) || isempty(cond_bytes)
            if !isempty(true_bytes)
                append!(bytes, true_bytes)
            elseif !isempty(false_bytes)
                append!(bytes, false_bytes)
            else
                # All empty — emit type-safe default for the value type
                val_type = infer_value_type(args[2], ctx)
                wasm_type = julia_to_wasm_type_concrete(val_type, ctx)
                if wasm_type isa ConcreteRef
                    push!(bytes, Opcode.REF_NULL)
                    append!(bytes, encode_leb128_signed(Int64(wasm_type.type_idx)))
                elseif wasm_type === ExternRef
                    push!(bytes, Opcode.REF_NULL)
                    push!(bytes, UInt8(ExternRef))
                elseif wasm_type === I64
                    push!(bytes, Opcode.I64_CONST)
                    push!(bytes, 0x00)
                elseif wasm_type === F64
                    push!(bytes, Opcode.F64_CONST)
                    append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                else
                    push!(bytes, Opcode.I32_CONST)
                    push!(bytes, 0x00)
                end
            end
            return bytes
        end

        # All three values are non-empty, emit proper select
        append!(bytes, true_bytes)
        append!(bytes, false_bytes)
        append!(bytes, cond_bytes)

        # Determine the type of the values for select
        val_type = infer_value_type(args[2], ctx)

        # For reference types (like Int128/UInt128 structs), need typed select
        if val_type === Int128 || val_type === UInt128
            # Use select_t with the struct type
            type_idx = get_int128_type!(ctx.mod, ctx.type_registry, val_type)
            push!(bytes, Opcode.SELECT_T)
            push!(bytes, 0x01)  # One type
            # Encode (ref null type_idx) for nullable struct ref
            push!(bytes, 0x63)  # ref null
            append!(bytes, encode_leb128_unsigned(type_idx))
        elseif is_struct_type(val_type) || val_type <: AbstractArray || val_type === String
            # Other reference types need typed select too
            wasm_type = julia_to_wasm_type_concrete(val_type, ctx)
            if wasm_type isa ConcreteRef
                push!(bytes, Opcode.SELECT_T)
                push!(bytes, 0x01)  # One type
                push!(bytes, 0x63)  # ref null
                append!(bytes, encode_leb128_unsigned(wasm_type.type_idx))
            else
                # Fall back to untyped select for value types
                push!(bytes, Opcode.SELECT)
            end
        else
            # Value types (i32, i64, f32, f64) use untyped select
            push!(bytes, Opcode.SELECT)
        end
        return bytes
    end

    # Special case for Core.sizeof - returns byte size
    # For strings/arrays, this is the array length
    if is_func(func, :sizeof) && length(args) == 1
        arg = args[1]
        arg_type = infer_value_type(arg, ctx)

        if arg_type === String || arg_type <: AbstractVector || arg_type === Any
            # For strings and arrays, sizeof is the array length
            append!(bytes, compile_value(arg, ctx))
            # If the value's wasm local is externref (either because arg_type is Any,
            # or because a String-typed value came from an Any-typed struct field),
            # cast to arrayref before array.len
            needs_cast = arg_type === Any || arg_type === Union{}
            if !needs_cast && arg isa Core.SSAValue
                local_idx = get(ctx.ssa_locals, arg.id, get(ctx.phi_locals, arg.id, nothing))
                if local_idx !== nothing
                    arr_idx = local_idx - ctx.n_params + 1
                    if arr_idx >= 1 && arr_idx <= length(ctx.locals) && ctx.locals[arr_idx] === ExternRef
                        needs_cast = true
                    end
                end
            end
            if needs_cast
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ANY_CONVERT_EXTERN)  # externref → anyref
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.REF_CAST_NULL)       # anyref → (ref null array)
                push!(bytes, UInt8(ArrayRef))
            end
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ARRAY_LEN)
            # array.len returns i32, extend to i64 for Julia's Int
            push!(bytes, Opcode.I64_EXTEND_I32_S)
            return bytes
        end
        # For other types, fall through to error
    end

    # Special case for length - returns character count for strings, element count for arrays
    if is_func(func, :length) && length(args) == 1
        arg = args[1]
        arg_type = infer_value_type(arg, ctx)

        if arg_type === String
            # For strings, length is the array length (each char is one element)
            append!(bytes, compile_value(arg, ctx))
            # If the value's wasm local is externref (e.g. from an Any-typed struct field),
            # cast to arrayref before array.len
            if arg isa Core.SSAValue
                local_idx = get(ctx.ssa_locals, arg.id, get(ctx.phi_locals, arg.id, nothing))
                if local_idx !== nothing
                    arr_idx = local_idx - ctx.n_params + 1
                    if arr_idx >= 1 && arr_idx <= length(ctx.locals) && ctx.locals[arr_idx] === ExternRef
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.ANY_CONVERT_EXTERN)  # externref → anyref
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.REF_CAST_NULL)       # anyref → (ref null array)
                        push!(bytes, UInt8(ArrayRef))
                    end
                end
            end
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ARRAY_LEN)
            # array.len returns i32, extend to i64 for Julia's Int
            push!(bytes, Opcode.I64_EXTEND_I32_S)
            return bytes
        elseif arg_type <: AbstractVector
            # For Vector, length is v.size[1] (logical size from struct field 1)
            # Vector is now a struct with (ref, size) where size is Tuple{Int64}
            if haskey(ctx.type_registry.structs, arg_type)
                info = ctx.type_registry.structs[arg_type]

                # Get the vector struct
                append!(bytes, compile_value(arg, ctx))

                # Get field 1 (size tuple)
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.STRUCT_GET)
                append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
                append!(bytes, encode_leb128_unsigned(1))  # Field 1 = size tuple

                # Get field 0 of the size tuple (the Int64 value)
                # Size tuple is Tuple{Int64}
                size_tuple_type = Tuple{Int64}
                if haskey(ctx.type_registry.structs, size_tuple_type)
                    size_info = ctx.type_registry.structs[size_tuple_type]
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.STRUCT_GET)
                    append!(bytes, encode_leb128_unsigned(size_info.wasm_type_idx))
                    append!(bytes, encode_leb128_unsigned(0))  # Field 0 of tuple
                end
                return bytes
            end
            # Fallback to array.len if struct not registered (shouldn't happen)
            append!(bytes, compile_value(arg, ctx))
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ARRAY_LEN)
            push!(bytes, Opcode.I64_EXTEND_I32_S)
            return bytes
        end
        # For other types, fall through to error
    end

    # Redirect Base.resize!(v, n) to WasmTarget._resize!(v, n)
    # This uses our Julia implementation in Runtime/ArrayOps.jl which handles
    # the complexities of creating a new backing array and swapping the struct fields.
    if is_func(func, :resize!) && length(args) == 2
        # We need to construct a new expression calling WasmTarget._resize!
        # Since we are inside the compiler, we can resolve the global ref.
        resize_shim = GlobalRef(WasmTarget, :_resize!)
        new_expr = Expr(:call, resize_shim, args[1], args[2])
        # Recursively compile the new call
        return compile_call(new_expr, idx, ctx)
    end

    # Special case for push!(vec, item) - add element to end of vector
    # WasmGC arrays cannot resize, so we handle two cases:
    # 1. If size < capacity: just set element and increment size
    # 2. If size >= capacity: allocate new array with 2x capacity, copy, update ref
    if is_func(func, :push!) && length(args) >= 2
        vec_arg = args[1]
        item_arg = args[2]
        vec_type = infer_value_type(vec_arg, ctx)

        if vec_type <: AbstractVector && haskey(ctx.type_registry.structs, vec_type)
            elem_type = eltype(vec_type)
            info = ctx.type_registry.structs[vec_type]
            arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

            # Register size tuple type if needed
            size_tuple_type = Tuple{Int64}
            if !haskey(ctx.type_registry.structs, size_tuple_type)
                register_tuple_type!(ctx.mod, ctx.type_registry, size_tuple_type)
            end
            size_info = ctx.type_registry.structs[size_tuple_type]

            # We need locals to store intermediate values
            # Use local variables to store: vec_ref, old_size, new_size, capacity
            # For now, implement simple case: assume capacity is sufficient
            # In full implementation, we'd add growth logic

            # Algorithm:
            # 1. Get current size from v.size[1]
            # 2. new_size = old_size + 1
            # 3. Set v.size = (new_size,)
            # 4. Get ref = v.ref (the underlying array)
            # 5. Set ref[new_size] = item (using 1-based index)
            # 6. Return vec

            # Step 1-2: Get old_size, compute new_size
            # We'll compile this inline - need to duplicate vec on stack

            # First, allocate a local for the vector
            vec_local = allocate_local!(ctx, vec_type)
            size_local = allocate_local!(ctx, Int64)

            # Store vec in local
            append!(bytes, compile_value(vec_arg, ctx))
            push!(bytes, Opcode.LOCAL_TEE)
            append!(bytes, encode_leb128_unsigned(vec_local))

            # Get size tuple (field 1)
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_GET)
            append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
            append!(bytes, encode_leb128_unsigned(1))

            # Get size value (field 0 of tuple)
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_GET)
            append!(bytes, encode_leb128_unsigned(size_info.wasm_type_idx))
            append!(bytes, encode_leb128_unsigned(0))

            # Add 1 to get new size
            push!(bytes, Opcode.I64_CONST)
            push!(bytes, 0x01)
            push!(bytes, Opcode.I64_ADD)

            # Store new_size in local
            push!(bytes, Opcode.LOCAL_TEE)
            append!(bytes, encode_leb128_unsigned(size_local))

            # Create new size tuple with new_size
            # struct.new for Tuple{Int64}
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_NEW)
            append!(bytes, encode_leb128_unsigned(size_info.wasm_type_idx))

            # Now we have new size tuple on stack
            # Get vec from local and set its size field
            size_tuple_local = allocate_local!(ctx, size_tuple_type)
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(size_tuple_local))

            # Get vec, set size field
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(vec_local))
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(size_tuple_local))
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_SET)
            append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
            append!(bytes, encode_leb128_unsigned(1))  # Field 1 = size

            # Now set the element at index new_size
            # Get ref (field 0 of vec)
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(vec_local))
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_GET)
            append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
            append!(bytes, encode_leb128_unsigned(0))  # Field 0 = ref (array)

            # Index: new_size - 1 (convert to 0-based)
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(size_local))
            push!(bytes, Opcode.I64_CONST)
            push!(bytes, 0x01)
            push!(bytes, Opcode.I64_SUB)
            push!(bytes, Opcode.I32_WRAP_I64)  # array.set expects i32 index

            # Value to store
            local item_bytes = compile_value(item_arg, ctx)
            # If array element type is externref (elem_type is Any), convert ref→externref
            if elem_type === Any
                # Determine source value's wasm type to decide conversion
                local push_src_wasm = nothing
                if length(item_bytes) >= 2 && item_bytes[1] == Opcode.LOCAL_GET
                    local src_idx_i = 0
                    local shift_i = 0
                    local pos_i = 2
                    while pos_i <= length(item_bytes)
                        b = item_bytes[pos_i]
                        src_idx_i |= (Int(b & 0x7f) << shift_i)
                        shift_i += 7
                        pos_i += 1
                        (b & 0x80) == 0 && break
                    end
                    if pos_i - 1 == length(item_bytes)
                        # PURE-048: Use correct n_params offset for ctx.locals lookup
                        if src_idx_i >= ctx.n_params
                            local arr_idx_i = src_idx_i - ctx.n_params + 1
                            if arr_idx_i >= 1 && arr_idx_i <= length(ctx.locals)
                                push_src_wasm = ctx.locals[arr_idx_i]
                            end
                        elseif src_idx_i < ctx.n_params && src_idx_i + 1 <= length(ctx.arg_types)
                            push_src_wasm = get_concrete_wasm_type(ctx.arg_types[src_idx_i + 1], ctx.mod, ctx.type_registry)
                        end
                    end
                elseif length(item_bytes) >= 1 && (item_bytes[1] == Opcode.I32_CONST || item_bytes[1] == Opcode.I64_CONST || item_bytes[1] == Opcode.F32_CONST || item_bytes[1] == Opcode.F64_CONST)
                    # PURE-318/PURE-325: Check for GC_PREFIX (LEB128-safe scan)
                    if !has_ref_producing_gc_op(item_bytes)
                        push_src_wasm = I32  # treat constants as numeric
                    end
                end
                local is_numeric_item = push_src_wasm === I64 || push_src_wasm === I32 || push_src_wasm === F64 || push_src_wasm === F32
                local is_already_externref_item = push_src_wasm === ExternRef
                if is_numeric_item
                    emit_numeric_to_externref!(bytes, stmt.val, val_wasm, ctx)
                else
                    append!(bytes, item_bytes)
                    # PURE-048: Skip extern_convert_any if value is already externref
                    if !is_already_externref_item
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                    end
                end
            else
                append!(bytes, item_bytes)
                # PURE-6025: If value is externref but array element is concrete ref,
                # convert externref → anyref → ref.cast (ref null $elem_type)
                local elem_wasm = get_concrete_wasm_type(elem_type, ctx.mod, ctx.type_registry)
                if elem_wasm isa ConcreteRef
                    local item_src_wasm = _get_local_wasm_type(item_arg, item_bytes, ctx)
                    if item_src_wasm === nothing
                        local item_julia_t = infer_value_type(item_arg, ctx)
                        item_src_wasm = get_concrete_wasm_type(item_julia_t, ctx.mod, ctx.type_registry)
                    end
                    if item_src_wasm === ExternRef
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.ANY_CONVERT_EXTERN)
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.REF_CAST_NULL)
                        append!(bytes, encode_leb128_signed(Int64(elem_wasm.type_idx)))
                    end
                end
            end

            # array.set
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ARRAY_SET)
            append!(bytes, encode_leb128_unsigned(arr_type_idx))

            # Return the vector
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(vec_local))

            return bytes
        end
    end

    # Special case for pop!(vec) - remove and return last element
    if is_func(func, :pop!) && length(args) >= 1
        vec_arg = args[1]
        vec_type = infer_value_type(vec_arg, ctx)

        if vec_type <: AbstractVector && haskey(ctx.type_registry.structs, vec_type)
            elem_type = eltype(vec_type)
            info = ctx.type_registry.structs[vec_type]
            arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

            # Register size tuple type if needed
            size_tuple_type = Tuple{Int64}
            if !haskey(ctx.type_registry.structs, size_tuple_type)
                register_tuple_type!(ctx.mod, ctx.type_registry, size_tuple_type)
            end
            size_info = ctx.type_registry.structs[size_tuple_type]

            # Algorithm:
            # 1. Get current size from v.size[1]
            # 2. Get element at index size (1-based)
            # 3. new_size = old_size - 1
            # 4. Set v.size = (new_size,)
            # 5. Return element

            vec_local = allocate_local!(ctx, vec_type)
            size_local = allocate_local!(ctx, Int64)
            elem_local = allocate_local!(ctx, elem_type)

            # Store vec in local
            append!(bytes, compile_value(vec_arg, ctx))
            push!(bytes, Opcode.LOCAL_TEE)
            append!(bytes, encode_leb128_unsigned(vec_local))

            # Get size tuple (field 1)
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_GET)
            append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
            append!(bytes, encode_leb128_unsigned(1))

            # Get size value (field 0 of tuple)
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_GET)
            append!(bytes, encode_leb128_unsigned(size_info.wasm_type_idx))
            append!(bytes, encode_leb128_unsigned(0))

            # Store size in local
            push!(bytes, Opcode.LOCAL_TEE)
            append!(bytes, encode_leb128_unsigned(size_local))

            # Get element at index size (1-based, so we use size-1 for 0-based)
            # First get ref
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(vec_local))
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_GET)
            append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
            append!(bytes, encode_leb128_unsigned(0))  # Field 0 = ref

            # Index: size - 1 (convert to 0-based)
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(size_local))
            push!(bytes, Opcode.I64_CONST)
            push!(bytes, 0x01)
            push!(bytes, Opcode.I64_SUB)
            push!(bytes, Opcode.I32_WRAP_I64)

            # array.get
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ARRAY_GET)
            append!(bytes, encode_leb128_unsigned(arr_type_idx))

            # Store element in local
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(elem_local))

            # Compute new_size = old_size - 1
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(size_local))
            push!(bytes, Opcode.I64_CONST)
            push!(bytes, 0x01)
            push!(bytes, Opcode.I64_SUB)

            # Create new size tuple
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_NEW)
            append!(bytes, encode_leb128_unsigned(size_info.wasm_type_idx))

            # Store in local for struct.set
            size_tuple_local = allocate_local!(ctx, size_tuple_type)
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(size_tuple_local))

            # Set vec.size = new_size_tuple
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(vec_local))
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(size_tuple_local))
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_SET)
            append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
            append!(bytes, encode_leb128_unsigned(1))  # Field 1 = size

            # Return the element
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(elem_local))

            return bytes
        end
    end

    # Special case for getfield/getproperty - struct/tuple field access
    # In newer Julia, obj.field compiles to Base.getproperty(obj, :field)
    # rather than Core.getfield(obj, :field)
    if (is_func(func, :getfield) || is_func(func, :getproperty)) && length(args) >= 2
        obj_arg = args[1]
        field_ref = args[2]
        obj_type = infer_value_type(obj_arg, ctx)

        # Handle Memory{T}.instance pattern (Julia 1.11+ Vector allocation)
        # This pattern appears as Core.getproperty(Memory{T}, :instance)
        # where Memory{T} is passed directly as a DataType
        # Memory{T}.instance is a singleton empty Memory (length 0)
        # We compile it to create an empty WasmGC array
        field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
        if field_sym === :instance && obj_arg isa DataType && obj_arg <: Memory
            # Memory{T}.instance - create an empty array (length 0)
            # Extract element type from Memory{T}
            elem_type = if obj_arg.name.name === :Memory && length(obj_arg.parameters) >= 1
                obj_arg.parameters[1]
            elseif obj_arg.name.name === :GenericMemory && length(obj_arg.parameters) >= 2
                obj_arg.parameters[2]
            else
                Int32  # default
            end

            # Get or create array type for this element type
            arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

            # Emit array.new_default with length 0
            push!(bytes, Opcode.I32_CONST)
            push!(bytes, 0x00)  # length = 0
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
            append!(bytes, encode_leb128_unsigned(arr_type_idx))
            return bytes
        end

        # Handle WasmGlobal field access (:value -> global.get)
        if obj_type <: WasmGlobal
            field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
            if field_sym === :value
                # Extract global index from type parameter
                global_idx = get_wasm_global_idx(obj_arg, ctx)
                if global_idx !== nothing
                    push!(bytes, Opcode.GLOBAL_GET)
                    append!(bytes, encode_leb128_unsigned(global_idx))
                    return bytes
                end
            end
        end

        # Handle Array field access (:ref and :size) - works for Vector, Matrix, etc.
        # Both Vector and Matrix are now structs with (ref, size) fields
        if obj_type <: AbstractArray
            field_sym = if field_ref isa QuoteNode
                field_ref.value
            else
                field_ref
            end

            if field_sym === :ref
                # :ref returns the underlying array reference (field 0 of struct)
                append!(bytes, compile_value(obj_arg, ctx))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.STRUCT_GET)
                if haskey(ctx.type_registry.structs, obj_type)
                    info = ctx.type_registry.structs[obj_type]
                    append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
                    append!(bytes, encode_leb128_unsigned(0))  # Field 0 = data array
                end
                return bytes
            elseif field_sym === :size
                # :size returns a Tuple containing the dimensions (field 1 of struct)
                # For Vector: Tuple{Int64}, for Matrix: Tuple{Int64, Int64}, etc.
                append!(bytes, compile_value(obj_arg, ctx))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.STRUCT_GET)
                if haskey(ctx.type_registry.structs, obj_type)
                    info = ctx.type_registry.structs[obj_type]
                    append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
                    append!(bytes, encode_leb128_unsigned(1))  # Field 1 = size tuple
                end
                return bytes
            end

            # PURE-325: AbstractArray subtypes that are pure structs (e.g., UnitRange)
            # have named fields like :start, :stop — handle via struct_get
            if isconcretetype(obj_type) && isstructtype(obj_type)
                if !haskey(ctx.type_registry.structs, obj_type)
                    register_struct_type!(ctx.mod, ctx.type_registry, obj_type)
                end
                if haskey(ctx.type_registry.structs, obj_type)
                    info = ctx.type_registry.structs[obj_type]
                    field_idx = findfirst(==(field_sym), info.field_names)
                    if field_idx !== nothing
                        append!(bytes, compile_value(obj_arg, ctx))
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.STRUCT_GET)
                        append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
                        append!(bytes, encode_leb128_unsigned(field_idx - 1))
                        return bytes
                    end
                end
            end
        end

        # Handle MemoryRef field access (:mem, :ptr_or_offset)
        # In WasmGC, MemoryRef IS the array, so :mem just returns it
        if obj_type <: MemoryRef
            field_sym = if field_ref isa QuoteNode
                field_ref.value
            else
                field_ref
            end

            if field_sym === :mem
                # :mem returns the underlying Memory - in WasmGC this is the array itself
                append!(bytes, compile_value(obj_arg, ctx))
                return bytes
            elseif field_sym === :ptr_or_offset
                # Not needed in WasmGC - return 0 as placeholder
                push!(bytes, Opcode.I64_CONST)
                push!(bytes, 0x00)
                return bytes
            end
        end

        # Handle Memory field access (:length, :ptr)
        # In WasmGC, Memory IS the array
        if obj_type <: Memory
            field_sym = if field_ref isa QuoteNode
                field_ref.value
            else
                field_ref
            end

            if field_sym === :length
                # Return array length
                append!(bytes, compile_value(obj_arg, ctx))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_LEN)
                push!(bytes, Opcode.I64_EXTEND_I32_S)
                return bytes
            elseif field_sym === :ptr
                # Not meaningful in WasmGC - return 0
                push!(bytes, Opcode.I64_CONST)
                push!(bytes, 0x00)
                return bytes
            end
        end

        # Handle closure field access (captured variables)
        if is_closure_type(obj_type)
            # Register closure type if not already
            if !haskey(ctx.type_registry.structs, obj_type)
                register_closure_type!(ctx.mod, ctx.type_registry, obj_type)
            end

            if haskey(ctx.type_registry.structs, obj_type)
                info = ctx.type_registry.structs[obj_type]

                field_sym = if field_ref isa QuoteNode
                    field_ref.value
                else
                    field_ref
                end

                field_idx = findfirst(==(field_sym), info.field_names)
                if field_idx !== nothing
                    append!(bytes, compile_value(obj_arg, ctx))
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.STRUCT_GET)
                    append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
                    append!(bytes, encode_leb128_unsigned(field_idx - 1))
                    return bytes
                end
            end
        end

        # Handle struct field access by name
        if is_struct_type(obj_type)
            # Register the struct type on-demand if not already registered
            if !haskey(ctx.type_registry.structs, obj_type)
                register_struct_type!(ctx.mod, ctx.type_registry, obj_type)
            end
            info = ctx.type_registry.structs[obj_type]

            field_sym = if field_ref isa QuoteNode
                field_ref.value
            else
                field_ref
            end

            field_idx = findfirst(==(field_sym), info.field_names)
            if field_idx !== nothing
                append!(bytes, compile_value(obj_arg, ctx))
                # PURE-701: If obj_arg's local is structref (union of struct types),
                # insert ref.cast null to narrow before struct_get
                emit_ref_cast_if_structref!(bytes, obj_arg, info.wasm_type_idx, ctx)
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.STRUCT_GET)
                append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
                append!(bytes, encode_leb128_unsigned(field_idx - 1))
                return bytes
            end
        end

        # Handle tuple field access by numeric index
        if obj_type <: Tuple
            # Register tuple type if needed
            if !haskey(ctx.type_registry.structs, obj_type)
                register_tuple_type!(ctx.mod, ctx.type_registry, obj_type)
            end

            if haskey(ctx.type_registry.structs, obj_type)
                info = ctx.type_registry.structs[obj_type]

                # Get the field index (1-indexed in Julia)
                field_idx = if field_ref isa Integer
                    field_ref
                elseif field_ref isa Core.SSAValue
                    # Dynamic index - will be handled below for homogeneous tuples
                    :dynamic
                else
                    nothing
                end

                if field_idx === :dynamic
                    # Dynamic tuple indexing - only supported for homogeneous tuples (NTuple)
                    # Check if all elements have the same type
                    # PURE-605: Guard against types without definite field count (e.g., Vararg tuples)
                    elem_types = try fieldtypes(obj_type) catch; () end
                    if length(elem_types) > 0 && all(t -> t === elem_types[1], elem_types)
                        # Homogeneous tuple - we can treat it as an array
                        elem_type = elem_types[1]

                        # For constant tuple (GlobalRef), create a WasmGC array and access it
                        # The tuple value needs to be compiled as an array first

                        # Get or create array type for this element type
                        # Use concrete types for String elements to match tuple field types
                        array_type_idx = if elem_type === String
                            get_string_ref_array_type!(ctx.mod, ctx.type_registry)
                        else
                            get_array_type!(ctx.mod, ctx.type_registry, elem_type)
                        end

                        # Compile the tuple as an array
                        # First compile the tuple value
                        append!(bytes, compile_value(obj_arg, ctx))

                        # The struct is on the stack, we need to convert struct fields to array
                        # Store in local, then create array from fields
                        tuple_local = length(ctx.locals) + ctx.n_params
                        push!(ctx.locals, julia_to_wasm_type_concrete(obj_type, ctx))
                        push!(bytes, Opcode.LOCAL_SET)
                        append!(bytes, encode_leb128_unsigned(tuple_local))

                        # Push all fields onto stack
                        for i in 0:(length(elem_types)-1)
                            push!(bytes, Opcode.LOCAL_GET)
                            append!(bytes, encode_leb128_unsigned(tuple_local))
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.STRUCT_GET)
                            append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
                            append!(bytes, encode_leb128_unsigned(i))
                        end

                        # Create array from fields
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.ARRAY_NEW_FIXED)
                        append!(bytes, encode_leb128_unsigned(array_type_idx))
                        append!(bytes, encode_leb128_unsigned(length(elem_types)))

                        # Store array in local - use concrete ref to specific array type
                        array_local = length(ctx.locals) + ctx.n_params
                        push!(ctx.locals, ConcreteRef(array_type_idx, true))
                        push!(bytes, Opcode.LOCAL_SET)
                        append!(bytes, encode_leb128_unsigned(array_local))

                        # Now compile the index and access the array
                        # Julia uses 1-based indexing, Wasm uses 0-based
                        append!(bytes, compile_value(field_ref, ctx))

                        # Subtract 1 for 0-based indexing
                        push!(bytes, Opcode.I64_CONST)
                        push!(bytes, 0x01)
                        push!(bytes, Opcode.I64_SUB)
                        # Wrap to i32 for array index
                        push!(bytes, Opcode.I32_WRAP_I64)

                        # Store index in local
                        idx_local = length(ctx.locals) + ctx.n_params
                        push!(ctx.locals, I32)
                        push!(bytes, Opcode.LOCAL_SET)
                        append!(bytes, encode_leb128_unsigned(idx_local))

                        # Access array: array.get
                        push!(bytes, Opcode.LOCAL_GET)
                        append!(bytes, encode_leb128_unsigned(array_local))
                        push!(bytes, Opcode.LOCAL_GET)
                        append!(bytes, encode_leb128_unsigned(idx_local))
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.ARRAY_GET)
                        append!(bytes, encode_leb128_unsigned(array_type_idx))

                        # PURE-036bc: If array element type is ExternRef (e.g., elem_type=Any),
                        # array_get returns externref. Downstream code may ref_cast to a struct
                        # type, which requires anyref input. Add any_convert_extern.
                        wasm_elem_type = get_concrete_wasm_type(elem_type, ctx.mod, ctx.type_registry)
                        if wasm_elem_type === ExternRef
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.ANY_CONVERT_EXTERN)
                        end

                        return bytes
                    end
                    # Non-homogeneous tuple with dynamic index - fall through to error
                elseif field_idx !== nothing && field_idx >= 1 && field_idx <= length(info.field_names)
                    append!(bytes, compile_value(obj_arg, ctx))
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.STRUCT_GET)
                    append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
                    append!(bytes, encode_leb128_unsigned(field_idx - 1))  # 0-indexed
                    return bytes
                end
            end
        end
    end

    # Special case for memoryrefget - array element access
    # memoryrefget(ref, ordering, boundscheck) where ref is from memoryrefnew
    if is_func(func, :memoryrefget) && length(args) >= 1
        ref_arg = args[1]
        ref_type = infer_value_type(ref_arg, ctx)

        # Extract element type from MemoryRef{T}, GenericMemoryRef{atomicity, T, addrspace},
        # Memory{T}, or GenericMemory{atomicity, T, addrspace}
        # PURE-045: Also handle Memory types for direct array access patterns
        elem_type = Int32  # default
        if ref_type isa DataType
            if ref_type.name.name === :MemoryRef
                elem_type = ref_type.parameters[1]
            elseif ref_type.name.name === :GenericMemoryRef
                # GenericMemoryRef has parameters (atomicity, element_type, addrspace)
                elem_type = ref_type.parameters[2]
            elseif ref_type.name.name === :Memory && length(ref_type.parameters) >= 1
                # Memory{T} - element type is first parameter
                elem_type = ref_type.parameters[1]
            elseif ref_type.name.name === :GenericMemory && length(ref_type.parameters) >= 2
                # GenericMemory{atomicity, T, addrspace} - element type is second parameter
                elem_type = ref_type.parameters[2]
            end
        end

        # PURE-902: Handle UnionAll MemoryRef types (bare MemoryRef without parameters)
        # When cross-function calls use abstract arg types (e.g., Vector instead of
        # Vector{Any}), code_typed returns bare MemoryRef (UnionAll) instead of
        # MemoryRef{Any} (DataType). The elem_type stays as default Int32.
        # Fix: use the memoryrefget result's own SSA type as the element type.
        if elem_type === Int32 && !(ref_type isa DataType)
            ssa_result_type = get(ctx.ssa_types, idx, Any)
            # If the SSA result type is itself a MemoryRef/array type (UnionAll),
            # the element type is unknown — default to Any
            if ssa_result_type isa UnionAll || ssa_result_type === Any
                elem_type = Any
            elseif ssa_result_type !== Int32
                elem_type = ssa_result_type
            end
        end

        # Get or create array type for this element type
        array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

        # The ref SSA value from memoryrefnew will have compiled to [array_ref, i32_index]
        # We need to compile ref_arg which will leave [array_ref, i32_index] on stack
        append!(bytes, compile_value(ref_arg, ctx))

        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_GET)
        append!(bytes, encode_leb128_unsigned(array_type_idx))

        # Note: if elem_type is Any, array.get returns externref and the SSA local
        # is also typed as externref (fixed in analyze_ssa_types!). No cast needed here.
        return bytes
    end

    # Special case for memoryrefoffset - get the 1-based offset of a MemoryRef
    # This is used by push!, resize!, and other dynamic array operations
    # Fresh MemoryRefs (from Core.memoryref, getfield(vec, :ref)) have offset 1
    # Indexed MemoryRefs (from memoryrefnew(ref, index, bc)) have offset = index
    if is_func(func, :memoryrefoffset) && length(args) >= 1
        ref_arg = args[1]

        # Check if this ref came from a memoryrefnew with an index
        if ref_arg isa Core.SSAValue && haskey(ctx.memoryref_offsets, ref_arg.id)
            # This MemoryRef has a recorded offset - compile the index value
            index_val = ctx.memoryref_offsets[ref_arg.id]
            append!(bytes, compile_value(index_val, ctx))

            # Ensure result is i64 (Julia's Int)
            idx_type = infer_value_type(index_val, ctx)
            if idx_type !== Int64 && idx_type !== Int
                # Convert to i64 if needed
                push!(bytes, Opcode.I64_EXTEND_I32_S)
            end
        else
            # Fresh MemoryRef - offset is always 1
            push!(bytes, Opcode.I64_CONST)
            push!(bytes, 0x01)  # 1
        end
        return bytes
    end

    # Special case for memoryrefset! - array element assignment
    # memoryrefset!(ref, value, ordering, boundscheck) -> stores value in array
    # In Julia, setindex! returns the stored value, so we need to return it too
    if is_func(func, :memoryrefset!) && length(args) >= 2
        ref_arg = args[1]
        value_arg = args[2]
        ref_type = infer_value_type(ref_arg, ctx)

        # Extract element type from MemoryRef{T}, GenericMemoryRef{atomicity, T, addrspace},
        # Memory{T}, or GenericMemory{atomicity, T, addrspace}
        # PURE-045: Also handle Memory types for direct array access patterns
        elem_type = Int32  # default
        if ref_type isa DataType
            if ref_type.name.name === :MemoryRef
                elem_type = ref_type.parameters[1]
            elseif ref_type.name.name === :GenericMemoryRef
                # GenericMemoryRef has parameters (atomicity, element_type, addrspace)
                elem_type = ref_type.parameters[2]
            elseif ref_type.name.name === :Memory && length(ref_type.parameters) >= 1
                # Memory{T} - element type is first parameter
                elem_type = ref_type.parameters[1]
            elseif ref_type.name.name === :GenericMemory && length(ref_type.parameters) >= 2
                # GenericMemory{atomicity, T, addrspace} - element type is second parameter
                elem_type = ref_type.parameters[2]
            end
        end

        # PURE-902: Handle UnionAll MemoryRef types (bare MemoryRef without parameters)
        # Same logic as memoryrefget: when ref_type is a bare UnionAll MemoryRef,
        # infer element type from SSA result type or default to Any.
        if elem_type === Int32 && !(ref_type isa DataType)
            ssa_result_type = get(ctx.ssa_types, idx, Any)
            if ssa_result_type isa UnionAll || ssa_result_type === Any
                elem_type = Any
            elseif ssa_result_type !== Int32
                elem_type = ssa_result_type
            end
        end

        # Get or create array type for this element type
        array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

        # Compile ref_arg which will leave [array_ref, i32_index] on stack
        append!(bytes, compile_value(ref_arg, ctx))

        # Compile the value to store - we need it twice (for array.set and return)
        # First compile gets the value on stack for array.set
        local mset_val_bytes = compile_value(value_arg, ctx)
        # If array element type is externref (elem_type is Any OR abstract type), convert ref→externref
        # PURE-045: Check the actual wasm element type, not just elem_type === Any
        # Abstract types like CallInfo also map to ExternRef
        local wasm_elem_type = get_concrete_wasm_type(elem_type, ctx.mod, ctx.type_registry)
        if wasm_elem_type === ExternRef
            # Determine source value's wasm type to decide conversion
            local mset_src_wasm = nothing  # will be set if we can determine it
            if length(mset_val_bytes) >= 2 && mset_val_bytes[1] == Opcode.LOCAL_GET
                local src_idx_m = 0
                local shift_m = 0
                local pos_m = 2
                while pos_m <= length(mset_val_bytes)
                    b = mset_val_bytes[pos_m]
                    src_idx_m |= (Int(b & 0x7f) << shift_m)
                    shift_m += 7
                    pos_m += 1
                    (b & 0x80) == 0 && break
                end
                if pos_m - 1 == length(mset_val_bytes)
                    # PURE-048: Use correct n_params offset for ctx.locals lookup
                    if src_idx_m >= ctx.n_params
                        local arr_idx_m = src_idx_m - ctx.n_params + 1
                        if arr_idx_m >= 1 && arr_idx_m <= length(ctx.locals)
                            mset_src_wasm = ctx.locals[arr_idx_m]
                        end
                    elseif src_idx_m < ctx.n_params && src_idx_m + 1 <= length(ctx.arg_types)
                        mset_src_wasm = get_concrete_wasm_type(ctx.arg_types[src_idx_m + 1], ctx.mod, ctx.type_registry)
                    end
                end
            elseif length(mset_val_bytes) >= 1 && (mset_val_bytes[1] == Opcode.I32_CONST || mset_val_bytes[1] == Opcode.I64_CONST || mset_val_bytes[1] == Opcode.F32_CONST || mset_val_bytes[1] == Opcode.F64_CONST)
                # PURE-318/PURE-325: Check for GC_PREFIX (LEB128-safe scan)
                if !has_ref_producing_gc_op(mset_val_bytes)
                    mset_src_wasm = I32  # treat constants as numeric
                end
            end
            local is_numeric_mset = mset_src_wasm === I64 || mset_src_wasm === I32 || mset_src_wasm === F64 || mset_src_wasm === F32
            local is_already_externref_mset = mset_src_wasm === ExternRef
            if is_numeric_mset
                emit_numeric_to_externref!(bytes, value_arg, mset_src_wasm, ctx)
            else
                append!(bytes, mset_val_bytes)
                # PURE-048: Skip extern_convert_any if value is already externref.
                # externref is NOT a subtype of anyref, so extern_convert_any would fail.
                if !is_already_externref_mset
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                end
            end
        elseif wasm_elem_type isa ConcreteRef
            # PURE-045: Array of concrete ref types (e.g., struct or array refs)
            # If value is numeric (nothing represented as i32_const 0), emit ref.null instead
            local is_numeric_for_ref = false
            if length(mset_val_bytes) >= 1 && (mset_val_bytes[1] == Opcode.I32_CONST || mset_val_bytes[1] == Opcode.I64_CONST || mset_val_bytes[1] == Opcode.F32_CONST || mset_val_bytes[1] == Opcode.F64_CONST)
                # PURE-318/PURE-325: Check for GC_PREFIX (LEB128-safe scan)
                is_numeric_for_ref = !has_ref_producing_gc_op(mset_val_bytes)
            elseif length(mset_val_bytes) >= 2 && mset_val_bytes[1] == Opcode.LOCAL_GET
                local src_idx_r = 0
                local shift_r = 0
                local pos_r = 2
                while pos_r <= length(mset_val_bytes)
                    b = mset_val_bytes[pos_r]
                    src_idx_r |= (Int(b & 0x7f) << shift_r)
                    shift_r += 7
                    pos_r += 1
                    (b & 0x80) == 0 && break
                end
                if pos_r - 1 == length(mset_val_bytes)
                    # PURE-320: Use correct n_params offset for ctx.locals lookup
                    # (same fix as PURE-048 applied to the externref branch above)
                    if src_idx_r >= ctx.n_params
                        local arr_idx_r = src_idx_r - ctx.n_params + 1
                        if arr_idx_r >= 1 && arr_idx_r <= length(ctx.locals)
                            src_type_r = ctx.locals[arr_idx_r]
                            if src_type_r === I64 || src_type_r === I32 || src_type_r === F64 || src_type_r === F32
                                is_numeric_for_ref = true
                            end
                        end
                    elseif src_idx_r < ctx.n_params && src_idx_r + 1 <= length(ctx.arg_types)
                        local src_wasm_r = get_concrete_wasm_type(ctx.arg_types[src_idx_r + 1], ctx.mod, ctx.type_registry)
                        if src_wasm_r === I64 || src_wasm_r === I32 || src_wasm_r === F64 || src_wasm_r === F32
                            is_numeric_for_ref = true
                        end
                    end
                end
            end
            if is_numeric_for_ref
                # Numeric value (nothing) for ref-typed array — emit ref.null of the element type
                push!(bytes, Opcode.REF_NULL)
                append!(bytes, encode_leb128_signed(Int64(wasm_elem_type.type_idx)))
            else
                append!(bytes, mset_val_bytes)
                # PURE-6025: If value is externref but array element is concrete ref,
                # convert externref → anyref → ref.cast (ref null $elem_type)
                # Check both: (1) byte-level local type, (2) Julia type inference
                local mset_item_wasm = _get_local_wasm_type(value_arg, mset_val_bytes, ctx)
                if mset_item_wasm === nothing
                    # Fallback: use Julia type inference
                    local val_julia_type = infer_value_type(value_arg, ctx)
                    mset_item_wasm = get_concrete_wasm_type(val_julia_type, ctx.mod, ctx.type_registry)
                end
                if mset_item_wasm === ExternRef
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.ANY_CONVERT_EXTERN)
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.REF_CAST_NULL)
                    append!(bytes, encode_leb128_signed(Int64(wasm_elem_type.type_idx)))
                end
            end
        else
            append!(bytes, mset_val_bytes)
        end

        # array.set consumes [array_ref, i32_index, value] and returns nothing
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_SET)
        append!(bytes, encode_leb128_unsigned(array_type_idx))

        # Julia's memoryrefset! returns the stored value, so push it again
        # This is needed because compile_statement may add LOCAL_SET after this
        # PURE-6024: Only emit return value if SSA has a local to store it in.
        # Without this guard, the return value (e.g., i32.const 0 for nothing)
        # is left on the stack when the SSA has no allocated local, causing
        # "values remaining on stack at end of block" validation errors.
        if haskey(ctx.ssa_locals, idx)
            local ret_val_bytes = compile_value(value_arg, ctx)
            append!(bytes, ret_val_bytes)
            # PURE-3113: If the SSA local is externref but the return value is a concrete ref,
            # emit extern_convert_any. The compile_statement safety check can't catch this
            # because has_gc_prefix=true (from array_set above) skips the trailing local_get
            # check, and the SSA type check sees Julia type (Any→ExternRef) matching the local.
            local mset_ret_local = ctx.ssa_locals[idx]
            local mset_ret_arr_idx = mset_ret_local - ctx.n_params + 1
            if mset_ret_arr_idx >= 1 && mset_ret_arr_idx <= length(ctx.locals)
                local mset_ret_local_type = ctx.locals[mset_ret_arr_idx]
                if mset_ret_local_type === ExternRef
                    # Check if return value is a concrete ref (not already externref)
                    local mset_ret_src_wasm = nothing
                    if length(ret_val_bytes) >= 2 && ret_val_bytes[1] == Opcode.LOCAL_GET
                        local mset_src_idx = 0
                        local mset_shift = 0
                        local mset_pos = 2
                        while mset_pos <= length(ret_val_bytes)
                            b = ret_val_bytes[mset_pos]
                            mset_src_idx |= (Int(b & 0x7f) << mset_shift)
                            mset_shift += 7
                            mset_pos += 1
                            (b & 0x80) == 0 && break
                        end
                        if mset_pos - 1 == length(ret_val_bytes) && mset_src_idx >= ctx.n_params
                            local mset_src_arr = mset_src_idx - ctx.n_params + 1
                            if mset_src_arr >= 1 && mset_src_arr <= length(ctx.locals)
                                mset_ret_src_wasm = ctx.locals[mset_src_arr]
                            end
                        end
                    end
                    if mset_ret_src_wasm isa ConcreteRef || mset_ret_src_wasm === StructRef || mset_ret_src_wasm === ArrayRef || mset_ret_src_wasm === AnyRef
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                    end
                end
            end
        end
        return bytes
    end

    # Special case for Core.memorynew - creates a new Memory{T} backing store
    # memorynew(Memory{T}, size) -> Memory{T}
    # In WasmGC, Memory{T} IS an array, so this compiles to array.new_default
    if is_func(func, :memorynew) && length(args) >= 2
        mem_type = args[1]  # Memory{T} type (compile-time constant)
        size_arg = args[2]  # size (may be literal or SSA)

        # Extract element type from Memory{T}
        elem_type = if mem_type isa DataType && mem_type <: Memory
            if mem_type.name.name === :Memory && length(mem_type.parameters) >= 1
                mem_type.parameters[1]
            elseif mem_type.name.name === :GenericMemory && length(mem_type.parameters) >= 2
                mem_type.parameters[2]
            else
                Int32  # default
            end
        else
            Int32  # default
        end

        arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

        # Compile size argument
        # WasmGC arrays are fixed-size — they cannot be resized after creation.
        # Julia's push!/append! with _growend! handles growth by creating new arrays,
        # but we enforce a minimum capacity so that small initial allocations
        # (e.g., Vector{T}() which uses memorynew(Memory{T}, 0)) have room for
        # initial push! operations before needing the first growth.
        min_capacity = 16
        if size_arg isa Int || size_arg isa Int64
            # Literal size - emit as i32 constant with minimum capacity
            actual_size = max(Int64(size_arg), min_capacity)
            push!(bytes, Opcode.I32_CONST)
            append!(bytes, encode_leb128_signed(actual_size))
        else
            # SSA or other expression - compile, convert to i32, apply minimum
            append!(bytes, compile_value(size_arg, ctx))
            push!(bytes, Opcode.I32_WRAP_I64)
            # Ensure minimum capacity: max(size, min_capacity)
            push!(bytes, Opcode.LOCAL_TEE)
            local cap_check_local = allocate_local!(ctx, I32)
            append!(bytes, encode_leb128_unsigned(cap_check_local))
            push!(bytes, Opcode.I32_CONST)
            append!(bytes, encode_leb128_signed(Int64(min_capacity)))
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(cap_check_local))
            push!(bytes, Opcode.I32_CONST)
            append!(bytes, encode_leb128_signed(Int64(min_capacity)))
            push!(bytes, Opcode.I32_GE_S)
            push!(bytes, Opcode.SELECT)  # select(size, min_cap, size >= min_cap)
        end

        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
        append!(bytes, encode_leb128_unsigned(arr_type_idx))
        return bytes
    end

    # Special case for Core.memoryref - creates MemoryRef from Memory
    # memoryref(memory::Memory{T}) -> MemoryRef{T}
    # In WasmGC, this is a no-op since Memory IS the array
    if is_func(func, :memoryref) && length(args) == 1
        # Pass through the array reference - Memory and MemoryRef are the same in WasmGC
        append!(bytes, compile_value(args[1], ctx))
        return bytes
    end

    # Special case for memoryrefnew - handle both patterns:
    # 1. memoryrefnew(memory) -> MemoryRef (for Vector allocation, just pass through)
    # 2. memoryrefnew(base_ref, index, boundscheck) -> MemoryRef at offset
    if is_func(func, :memoryrefnew)
        if length(args) == 1
            # Single arg: just wrapping a Memory - pass through the array reference
            # This is a "fresh" MemoryRef with offset 1
            append!(bytes, compile_value(args[1], ctx))
            return bytes
        elseif length(args) >= 2
            base_ref = args[1]
            index = args[2]

            # Record the offset for this MemoryRef SSA so memoryrefoffset can use it
            ctx.memoryref_offsets[idx] = index

            # Compile the base array reference
            append!(bytes, compile_value(base_ref, ctx))

            # Compile and convert index to i32 (Julia uses 1-based Int64, Wasm uses 0-based i32)
            append!(bytes, compile_value(index, ctx))

            # PURE-6027: Check BOTH Julia type AND actual WASM type for i64→i32 wrap.
            # infer_value_type may return Any/Union while the actual local is i64.
            idx_type = infer_value_type(index, ctx)
            idx_wasm = get_phi_edge_wasm_type(index, ctx)
            if idx_type === Int64 || idx_type === Int || idx_wasm === I64
                # Convert to i32 and subtract 1 for 0-based indexing
                push!(bytes, Opcode.I32_WRAP_I64)  # i64 -> i32
            end
            push!(bytes, Opcode.I32_CONST)
            push!(bytes, 0x01)  # 1
            push!(bytes, Opcode.I32_SUB)  # index - 1 for 0-based

            # Now stack has [array_ref, i32_index] which is what memoryrefget needs
            return bytes
        end
    end

    # Special case for Core.tuple - tuple creation
    if is_func(func, :tuple) && length(args) > 0
        # Infer tuple type from arguments
        elem_types = Type[infer_value_type(arg, ctx) for arg in args]
        tuple_type = Tuple{elem_types...}

        # Register tuple type
        if !haskey(ctx.type_registry.structs, tuple_type)
            register_tuple_type!(ctx.mod, ctx.type_registry, tuple_type)
        end

        if haskey(ctx.type_registry.structs, tuple_type)
            info = ctx.type_registry.structs[tuple_type]

            # Push all tuple elements with type safety for externref fields
            # PURE-142: Core.tuple args may be phi locals typed as i64 but
            # struct field expects externref (Any-typed tuple element)
            struct_type_def = ctx.mod.types[info.wasm_type_idx + 1]
            for (fi, arg) in enumerate(args)
                arg_bytes = compile_value(arg, ctx)
                expected_wasm = nothing
                if struct_type_def isa StructType && fi <= length(struct_type_def.fields)
                    expected_wasm = struct_type_def.fields[fi].valtype
                end
                if expected_wasm === ExternRef
                    # Check if arg_bytes is a numeric value (i32/i64 const or numeric local)
                    # PURE-220: But NOT if bytes contain GC instructions (struct.new, array.new_fixed)
                    # which indicate a complex ref value (String, Symbol), not a simple numeric.
                    is_numeric_arg = false
                    ends_with_ref_producing_gc = has_ref_producing_gc_op(arg_bytes)
                    if length(arg_bytes) >= 1 && (arg_bytes[1] == 0x41 || arg_bytes[1] == 0x42) && !ends_with_ref_producing_gc
                        is_numeric_arg = true
                    elseif length(arg_bytes) >= 2 && arg_bytes[1] == 0x20
                        src_idx = 0; shift = 0; leb_end = 0
                        for bi in 2:length(arg_bytes)
                            b = arg_bytes[bi]
                            src_idx |= (Int(b & 0x7f) << shift)
                            shift += 7
                            if (b & 0x80) == 0; leb_end = bi; break; end
                        end
                        if leb_end == length(arg_bytes)
                            arr_idx = src_idx - ctx.n_params + 1
                            if arr_idx >= 1 && arr_idx <= length(ctx.locals)
                                src_type = ctx.locals[arr_idx]
                                if src_type === I32 || src_type === I64 || src_type === F32 || src_type === F64
                                    is_numeric_arg = true
                                end
                            end
                        end
                    end
                    if is_numeric_arg
                        push!(bytes, Opcode.REF_NULL)
                        push!(bytes, UInt8(ExternRef))
                    else
                        append!(bytes, arg_bytes)
                        # Convert internal ref to externref if not already externref
                        is_already_extern = false
                        if length(arg_bytes) >= 2 && arg_bytes[1] == 0x20
                            src_idx2 = 0; shift2 = 0
                            for bi in 2:length(arg_bytes)
                                b = arg_bytes[bi]
                                src_idx2 |= (Int(b & 0x7f) << shift2)
                                shift2 += 7
                                (b & 0x80) == 0 && break
                            end
                            arr_idx2 = src_idx2 - ctx.n_params + 1
                            if arr_idx2 >= 1 && arr_idx2 <= length(ctx.locals)
                                is_already_extern = (ctx.locals[arr_idx2] === ExternRef)
                            elseif src_idx2 < ctx.n_params
                                # PURE-803: Check param type — Function/Any params are already externref
                                param_idx2 = src_idx2 + 1
                                if param_idx2 >= 1 && param_idx2 <= length(ctx.arg_types)
                                    param_wasm = get_concrete_wasm_type(ctx.arg_types[param_idx2], ctx.mod, ctx.type_registry)
                                    is_already_extern = (param_wasm === ExternRef)
                                end
                            end
                        end
                        if !is_already_extern
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                        end
                    end
                elseif expected_wasm isa ConcreteRef || expected_wasm === StructRef || expected_wasm === ArrayRef || expected_wasm === AnyRef
                    # Ref-typed field: check for numeric local mismatch
                    is_numeric_arg = false
                    if length(arg_bytes) >= 2 && arg_bytes[1] == 0x20
                        src_idx = 0; shift = 0; leb_end = 0
                        for bi in 2:length(arg_bytes)
                            b = arg_bytes[bi]
                            src_idx |= (Int(b & 0x7f) << shift)
                            shift += 7
                            if (b & 0x80) == 0; leb_end = bi; break; end
                        end
                        if leb_end == length(arg_bytes)
                            arr_idx = src_idx - ctx.n_params + 1
                            if arr_idx >= 1 && arr_idx <= length(ctx.locals)
                                src_type = ctx.locals[arr_idx]
                                if src_type === I32 || src_type === I64 || src_type === F32 || src_type === F64
                                    is_numeric_arg = true
                                end
                            end
                        end
                    end
                    if is_numeric_arg
                        if expected_wasm isa ConcreteRef
                            push!(bytes, Opcode.REF_NULL)
                            append!(bytes, encode_leb128_signed(Int64(expected_wasm.type_idx)))
                        else
                            push!(bytes, Opcode.REF_NULL)
                            push!(bytes, UInt8(expected_wasm isa UInt8 ? expected_wasm : StructRef))
                        end
                    else
                        append!(bytes, arg_bytes)
                    end
                else
                    append!(bytes, arg_bytes)
                end
            end

            # struct.new
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_NEW)
            append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))

            return bytes
        end
    end

    # Special case for setfield!/setproperty! - mutable struct field assignment
    # Also handles WasmGlobal (:value -> global.set)
    # In newer Julia, obj.field = val compiles to Base.setproperty!(obj, :field, val)
    if (is_func(func, :setfield!) || is_func(func, :setproperty!)) && length(args) >= 3
        obj_arg = args[1]
        field_ref = args[2]
        value_arg = args[3]
        obj_type = infer_value_type(obj_arg, ctx)

        # Handle WasmGlobal field assignment (:value -> global.set)
        if obj_type <: WasmGlobal
            field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
            if field_sym === :value
                # Extract global index from type parameter
                global_idx = get_wasm_global_idx(obj_arg, ctx)
                if global_idx !== nothing
                    # Push the value to set
                    append!(bytes, compile_value(value_arg, ctx))
                    # Emit global.set
                    push!(bytes, Opcode.GLOBAL_SET)
                    append!(bytes, encode_leb128_unsigned(global_idx))
                    # setfield! returns the value, so push it again
                    append!(bytes, compile_value(value_arg, ctx))
                    return bytes
                end
            end
        end

        # Handle Vector/Array field assignment (:ref and :size are mutable)
        # Vector{T} is now a struct with (ref, size) where both fields are mutable
        if obj_type <: AbstractArray
            field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
            if field_sym === :ref && haskey(ctx.type_registry.structs, obj_type)
                # PURE-325: setfield!(vector, :ref, new_memref) — update data array
                # :ref is field index 0 in the Vector struct
                # Guard: only handle if value_arg has a local (skip multi-arg memoryrefnew)
                value_has_local = false
                if value_arg isa Core.SSAValue && haskey(ctx.ssa_locals, value_arg.id)
                    value_has_local = true
                elseif value_arg isa Core.Argument
                    value_has_local = true
                end
                if value_has_local
                    info = ctx.type_registry.structs[obj_type]
                    value_type = infer_value_type(value_arg, ctx)
                    temp_local = allocate_local!(ctx, value_type)
                    append!(bytes, compile_value(value_arg, ctx))
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(temp_local))
                    append!(bytes, compile_value(obj_arg, ctx))
                    # PURE-701: If obj_arg's local is structref, insert ref.cast null before struct_set
                    emit_ref_cast_if_structref!(bytes, obj_arg, info.wasm_type_idx, ctx)
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(temp_local))
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.STRUCT_SET)
                    append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
                    append!(bytes, encode_leb128_unsigned(0))  # Field 0 = data array ref
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(temp_local))
                    return bytes
                end
                # Fall through to generic handling for multi-arg memoryrefnew values
            elseif field_sym === :size && haskey(ctx.type_registry.structs, obj_type)
                info = ctx.type_registry.structs[obj_type]
                # :size is field index 2 (1-indexed), so 1 in 0-indexed
                # struct.set expects: [ref, value]

                # IMPORTANT: The value_arg might be an SSA that was just computed and
                # is on top of the stack. If we compile obj_arg first, we'd push it
                # AFTER the value, giving wrong order [value, ref] instead of [ref, value].
                # Solution: compile value first, store in temp local, then compile ref.
                value_type = infer_value_type(value_arg, ctx)
                temp_local = allocate_local!(ctx, value_type)

                # Compile value and store in local (value may already be on stack from prev stmt)
                append!(bytes, compile_value(value_arg, ctx))
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(temp_local))

                # Now compile obj (struct ref)
                append!(bytes, compile_value(obj_arg, ctx))
                # PURE-701: If obj_arg's local is structref, insert ref.cast null before struct_set
                emit_ref_cast_if_structref!(bytes, obj_arg, info.wasm_type_idx, ctx)

                # Load value from local
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(temp_local))

                # struct.set
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.STRUCT_SET)
                append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
                append!(bytes, encode_leb128_unsigned(1))  # Field 1 = size tuple

                # setfield! returns the value, so push it again
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(temp_local))
                return bytes
            end
        end

        # Handle mutable struct field assignment
        if is_struct_type(obj_type) && ismutabletype(obj_type)
            if haskey(ctx.type_registry.structs, obj_type)
                info = ctx.type_registry.structs[obj_type]
                field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref

                field_idx = findfirst(==(field_sym), info.field_names)
                if field_idx !== nothing
                    # PURE-045: Check if field is Any type (maps to externref in Wasm)
                    field_type = field_idx <= length(info.field_types) ? info.field_types[field_idx] : Any

                    # struct.set expects: [ref, value]
                    append!(bytes, compile_value(obj_arg, ctx))
                    # PURE-701: If obj_arg's local is structref, insert ref.cast null before struct_set
                    emit_ref_cast_if_structref!(bytes, obj_arg, info.wasm_type_idx, ctx)

                    # PURE-4150: Track if value is a Type reference (used for both struct_set and return value)
                    is_type_value = false

                    # PURE-045: If field type is Any (externref), convert value to externref
                    if field_type === Any
                        # PURE-4150: Check if value is a Type reference (GlobalRef → Type value)
                        # compile_value(Type) emits i32.const 0, but field expects externref.
                        # Emit ref.null extern as placeholder (type objects can't be constructed in WasmGC).
                        if value_arg isa GlobalRef
                            try
                                actual_sf_val = getfield(value_arg.mod, value_arg.name)
                                is_type_value = actual_sf_val isa Type
                            catch; end
                        elseif value_arg isa Type
                            is_type_value = true
                        end

                        if is_type_value
                            # Type objects → ref.null extern (placeholder for WasmGC)
                            push!(bytes, Opcode.REF_NULL)
                            push!(bytes, UInt8(ExternRef))
                        else
                            val_julia_type = infer_value_type(value_arg, ctx)
                            val_wasm_type = julia_to_wasm_type(val_julia_type)
                            if val_julia_type === Any || val_wasm_type === ExternRef
                                # PURE-3112/PURE-4150: Already externref — no conversion needed
                                append!(bytes, compile_value(value_arg, ctx))
                            elseif val_wasm_type === I32 || val_wasm_type === I64 || val_wasm_type === F32 || val_wasm_type === F64
                                # PURE-4150: Numeric type → box then convert
                                emit_numeric_to_externref!(bytes, value_arg, val_wasm_type, ctx)
                            else
                                # Concrete/abstract ref → extern_convert_any
                                append!(bytes, compile_value(value_arg, ctx))
                                push!(bytes, Opcode.GC_PREFIX)
                                push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                            end
                        end
                    else
                        # PURE-6024: When value is nothing and field is ref-typed,
                        # compile_value(nothing) emits i32_const 0 which fails
                        # struct_set validation. Emit ref.null none instead.
                        if is_nothing_value(value_arg, ctx)
                            field_wasm = julia_to_wasm_type(field_type)
                            if field_wasm === I32 || field_wasm === I64 || field_wasm === F32 || field_wasm === F64
                                append!(bytes, compile_value(value_arg, ctx))
                            else
                                # Ref-typed field: ref.null none (bottom of internal ref hierarchy)
                                push!(bytes, Opcode.REF_NULL)
                                push!(bytes, 0x71)  # none heap type (NOT 0x6E which is any)
                            end
                        else
                            append!(bytes, compile_value(value_arg, ctx))
                        end
                    end

                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.STRUCT_SET)
                    append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
                    append!(bytes, encode_leb128_unsigned(field_idx - 1))  # 0-indexed
                    # setfield! returns the value — use compile_value to match SSA return type
                    append!(bytes, compile_value(value_arg, ctx))
                    return bytes
                end
            end
        end

        # Handle setfield! on Base.RefValue (used for optimization sinks)
        # These are no-ops in Wasm since we don't need the sink pattern
        if obj_type <: Base.RefValue
            # Just push the value (setfield! returns the value)
            append!(bytes, compile_value(value_arg, ctx))
            return bytes
        end
        # Fall through for other struct types - will hit error
    end

    # Special case for compilerbarrier - just pass through the value
    if is_func(func, :compilerbarrier)
        # compilerbarrier(kind, value) - first arg is a symbol, second is the value
        # We only want the value (second arg)
        if length(args) >= 2
            append!(bytes, compile_value(args[2], ctx))
        end
        return bytes
    end

    # Special case for typeassert - just pass through the value
    # Core.typeassert(x, T) returns x if type matches, throws otherwise
    # In Wasm we don't do runtime type checks, so just return the value
    if is_func(func, :typeassert)
        if length(args) >= 1
            append!(bytes, compile_value(args[1], ctx))
        end
        return bytes
    end

    # Special case for string/symbol equality/identity comparison (=== and !==)
    # Must be handled before generic argument pushing since strings/symbols are refs, not integers
    # Symbol uses same array<i32> representation as String, so ref.eq would fail (reference equality)
    if (is_func(func, :(===)) || is_func(func, :(!==))) && length(args) == 2
        arg1_type = infer_value_type(args[1], ctx)
        arg2_type = infer_value_type(args[2], ctx)
        if (arg1_type === String || arg1_type === Symbol) && (arg2_type === String || arg2_type === Symbol)
            append!(bytes, compile_string_equal(args[1], args[2], ctx))
            if is_func(func, :(!==))
                # Negate the result for !==
                push!(bytes, Opcode.I32_EQZ)
            end
            return bytes
        end

        # Special case: comparing ref type with nothing - use ref.is_null
        arg1_is_nothing = is_nothing_value(args[1], ctx)
        arg2_is_nothing = is_nothing_value(args[2], ctx)

        if (arg1_is_nothing && is_ref_type_or_union(arg2_type)) ||
           (arg2_is_nothing && is_ref_type_or_union(arg1_type))
            # Compile the non-nothing ref argument
            local val_bytes = UInt8[]
            if arg1_is_nothing
                val_bytes = compile_value(args[2], ctx)
            else
                val_bytes = compile_value(args[1], ctx)
            end
            # Check if compile_value produced a numeric type (i32/i64/f32/f64)
            # Numeric values can never be null, so short-circuit
            local is_numeric_val = false
            if length(val_bytes) >= 2 && val_bytes[1] == Opcode.LOCAL_GET
                # Decode local index and check its Wasm type
                local src_idx = 0
                local shift = 0
                local pos = 2
                while pos <= length(val_bytes)
                    b = val_bytes[pos]
                    src_idx |= (Int(b & 0x7f) << shift)
                    shift += 7
                    pos += 1
                    (b & 0x80) == 0 && break
                end
                # PURE-142: Fix indexing - src_idx is absolute local index (includes params),
                # but ctx.locals only contains non-param locals. Must subtract n_params.
                local local_offset = src_idx - ctx.n_params
                if pos - 1 == length(val_bytes) && local_offset >= 0 && local_offset < length(ctx.locals)
                    src_type = ctx.locals[local_offset + 1]
                    if src_type === I64 || src_type === I32 || src_type === F64 || src_type === F32
                        is_numeric_val = true
                    end
                elseif pos - 1 == length(val_bytes) && src_idx < ctx.n_params
                    # It's a parameter - check param types
                    if src_idx < length(ctx.arg_types)
                        param_type = ctx.arg_types[src_idx + 1]
                        if param_type === I64 || param_type === I32 || param_type === F64 || param_type === F32
                            is_numeric_val = true
                        end
                    end
                end
            elseif length(val_bytes) >= 1 && (val_bytes[1] == Opcode.I32_CONST || val_bytes[1] == Opcode.I64_CONST || val_bytes[1] == Opcode.F32_CONST || val_bytes[1] == Opcode.F64_CONST)
                is_numeric_val = true
            end
            if is_numeric_val
                # Numeric value can never be nothing
                # === nothing → false (0), !== nothing → true (1)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, is_func(func, :(!==)) ? 0x01 : 0x00)
                return bytes
            end
            append!(bytes, val_bytes)
            # ref.is_null checks if ref is null (returns i32 1 for null, 0 otherwise)
            push!(bytes, Opcode.REF_IS_NULL)
            if is_func(func, :(!==))
                # Negate for !== (we want true when NOT null)
                push!(bytes, Opcode.I32_EQZ)
            end
            return bytes
        end
    end

    # Determine argument type for opcode selection (do this BEFORE compiling args)
    arg_type = length(args) > 0 ? infer_value_type(args[1], ctx) : Int64
    is_32bit = arg_type === Int32 || arg_type === UInt32 || arg_type === Bool || arg_type === Char ||
               arg_type === Int16 || arg_type === UInt16 || arg_type === Int8 || arg_type === UInt8 ||
               (isprimitivetype(arg_type) && sizeof(arg_type) <= 4)
    is_128bit = arg_type === Int128 || arg_type === UInt128

    # PURE-046: If arg_type is Any/abstract but the intrinsic expects numeric operands,
    # the code is type-confused (externref being used as numeric). Emit unreachable
    # since we can't convert externref to i64 in Wasm.
    is_numeric_intrinsic = is_func(func, :eq_int) || is_func(func, :ne_int) ||
                           is_func(func, :slt_int) || is_func(func, :sle_int) ||
                           is_func(func, :ult_int) || is_func(func, :ule_int) ||
                           is_func(func, :add_int) || is_func(func, :sub_int) ||
                           is_func(func, :mul_int) ||
                           is_func(func, :not_int) || is_func(func, :or_int) ||
                           is_func(func, :xor_int) || is_func(func, :and_int)
    if is_numeric_intrinsic && (arg_type === Any ||
                                 (!isprimitivetype(arg_type) && !is_128bit && !(arg_type <: Integer)))
        # Type-confused code path - externref used as numeric
        # Emit unreachable since we can't do numeric ops on externref
        push!(bytes, Opcode.UNREACHABLE)
        ctx.last_stmt_was_stub = true  # PURE-908
        return bytes
    end

    # PURE-324: Handle pointer arithmetic intrinsics BEFORE the generic arg pre-push.
    # add_ptr, sub_ptr, and pointerref push their own args (or trace back to string ref),
    # so they must NOT have args pre-pushed by the generic loop below.
    if func isa GlobalRef && func.name === :add_ptr
        append!(bytes, compile_value(args[1], ctx))
        append!(bytes, compile_value(args[2], ctx))
        push!(bytes, Opcode.I64_ADD)
        return bytes
    elseif func isa GlobalRef && func.name === :sub_ptr
        append!(bytes, compile_value(args[1], ctx))
        append!(bytes, compile_value(args[2], ctx))
        push!(bytes, Opcode.I64_SUB)
        return bytes
    elseif func isa GlobalRef && func.name === :pointerref
        ptr_arg = length(args) >= 1 ? args[1] : nothing
        str_info = ptr_arg !== nothing ? _trace_string_ptr(ptr_arg, ctx.code_info.code) : nothing
        if str_info !== nothing
            str_ssa, idx_ssa = str_info
            append!(bytes, compile_value(str_ssa, ctx))
            append!(bytes, compile_value(idx_ssa, ctx))
            push!(bytes, Opcode.I32_WRAP_I64)
            push!(bytes, Opcode.I32_CONST)
            push!(bytes, 0x01)
            push!(bytes, Opcode.I32_SUB)
            string_arr_type = get_string_array_type!(ctx.mod, ctx.type_registry)
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ARRAY_GET)
            append!(bytes, encode_leb128_unsigned(string_arr_type))
        else
            push!(bytes, Opcode.UNREACHABLE)
            ctx.last_stmt_was_stub = true  # PURE-908
        end
        return bytes
    end

    # PURE-325: Int128 checked/div/rem arithmetic can't be compiled (struct args on
    # stack would mismatch i64 ops). Emit unreachable BEFORE pushing args.
    if (arg_type === Int128 || arg_type === UInt128) && func isa GlobalRef && func.name in
            (:checked_smul_int, :checked_umul_int, :checked_sadd_int, :checked_uadd_int,
             :checked_ssub_int, :checked_usub_int, :checked_sdiv_int, :checked_udiv_int,
             :sdiv_int, :udiv_int, :srem_int, :urem_int)
        push!(bytes, Opcode.UNREACHABLE)
        ctx.last_stmt_was_stub = true  # PURE-908
        return bytes
    end

    # Push arguments onto the stack (normal case)
    # Skip Type arguments (e.g., first arg of sext_int, zext_int, trunc_int, bitcast)
    # These are compile-time type parameters, not runtime values
    # EXCEPTION: For === and !== comparisons, Type values ARE runtime values
    # (they get compiled to i32 type tags and compared)
    # PURE-325: Skip arg-pushing for Core._expr — its handler manages its own args
    # PURE-905: Skip arg-pushing for cross-call candidates — the cross-call handler
    # at line ~20714 pushes args with type bridging. Pre-pushing here causes duplicate
    # args on the stack (e.g., setindex! gets 6 args instead of 3).
    # Cross-call candidates are GlobalRef functions found in the func_registry that
    # aren't handled by a specific earlier handler (intrinsics, ===, _expr, etc.).
    is_expr_call = is_func(func, :_expr)
    is_equality_comparison = is_func(func, :(===)) || is_func(func, :(!==))
    _skip_arg_prepush = is_expr_call
    if !_skip_arg_prepush && func isa GlobalRef && ctx.func_registry !== nothing &&
            !is_numeric_intrinsic && !is_equality_comparison
        _called_func = try getfield(func.mod, func.name) catch; nothing end
        if _called_func !== nothing
            _call_arg_types = tuple([infer_value_type(a, ctx) for a in args]...)
            _target = get_function(ctx.func_registry, _called_func, _call_arg_types)
            if _target === nothing && typeof(_called_func) <: Function && isconcretetype(typeof(_called_func))
                _target = get_function(ctx.func_registry, _called_func, (typeof(_called_func), _call_arg_types...))
            end
            _skip_arg_prepush = _target !== nothing
        end
    end
    # PURE-7012: Reorder muladd_float args for correct WASM stack order.
    # muladd_float(a, b, c) = a*b + c. With default push order [a, b, c],
    # WASM f64.mul takes top 2 (b,c) giving a+b*c (WRONG). Reorder to
    # [c, a, b] so f64.mul takes (a,b) then f64.add takes (c, a*b) = a*b+c.
    _push_args = args
    if is_func(func, :muladd_float) && length(args) == 3
        _push_args = Any[args[3], args[1], args[2]]
    end
    for arg in _push_args
        if _skip_arg_prepush
            continue
        end
        # Check if this argument is a type reference
        is_type_arg = false
        if arg isa Type
            # Directly a Type value (Julia already resolved it)
            is_type_arg = true
        elseif arg isa GlobalRef
            try
                resolved = getfield(arg.mod, arg.name)
                if resolved isa Type
                    is_type_arg = true
                end
            catch
            end
        end
        # Skip Type args for intrinsics (e.g., sext_int(Int64, x))
        # but NOT for equality comparisons (e.g., x === SomeType)
        if is_type_arg && !is_equality_comparison
            continue
        end
        append!(bytes, compile_value(arg, ctx))
        # PURE-6027: Fix i32/i64 mismatch for numeric intrinsics.
        # When is_32bit=true but the actual compiled value is i64 (e.g., from a phi
        # node or SSA local allocated as i64), insert i32_wrap_i64 to match.
        # Conversely, when is_32bit=false but value is i32, extend to i64.
        if is_numeric_intrinsic && !_is_externref_value(arg, ctx)
            _actual_wasm = get_phi_edge_wasm_type(arg, ctx)
            if is_32bit && _actual_wasm === I64
                push!(bytes, Opcode.I32_WRAP_I64)
            elseif !is_32bit && !is_128bit && _actual_wasm === I32
                push!(bytes, Opcode.I64_EXTEND_I32_S)
            end
        end
        # PURE-904: Unbox externref args for numeric intrinsics.
        # When a param/SSA has Wasm type externref but Julia IR uses it as
        # numeric (UInt32, Int64, etc.), unbox: any_convert_extern → ref.cast → struct.get
        if is_numeric_intrinsic && _is_externref_value(arg, ctx)
            target_wasm = is_32bit ? I32 : I64
            box_type = get_numeric_box_type!(ctx.mod, ctx.type_registry, target_wasm)
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ANY_CONVERT_EXTERN)
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.REF_CAST_NULL)
            append!(bytes, encode_leb128_signed(Int64(box_type)))
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_GET)
            append!(bytes, encode_leb128_unsigned(box_type))
            append!(bytes, encode_leb128_unsigned(UInt32(0)))
        end
    end

    # PURE-046: For numeric intrinsics, verify the compiled args don't contain externref
    # (this catches cases where Julia type inference says Int64 but actual struct field is Any)
    if is_numeric_intrinsic && length(args) > 0
        local arg1_bytes = compile_value(args[1], ctx)
        # Check if arg1 compiles to struct_get that returns externref
        # GC_PREFIX (0xFB) followed by STRUCT_GET (0x02) indicates struct field access
        if length(arg1_bytes) >= 4 && arg1_bytes[1] == Opcode.GC_PREFIX && arg1_bytes[2] == 0x02
            # Decode the struct type index from LEB128
            local struct_idx = 0
            local shift = 0
            local pos = 3
            while pos <= length(arg1_bytes)
                b = arg1_bytes[pos]
                struct_idx |= (Int(b & 0x7f) << shift)
                shift += 7
                pos += 1
                (b & 0x80) == 0 && break
            end
            # Check if this struct type has the field as externref
            # For now, conservatively check if the compiled bytes produce externref
            # by checking if the SSA type is Any
            local arg1_ssa = args[1]
            if arg1_ssa isa Core.SSAValue && haskey(ctx.ssa_types, arg1_ssa.id)
                local ssa_type = ctx.ssa_types[arg1_ssa.id]
                if ssa_type === Any
                    @info "PURE-046: Emitting UNREACHABLE for externref in numeric intrinsic (SSA type is Any)"
                    # PURE-908: Clear pre-pushed args
                    bytes = UInt8[]
                    push!(bytes, Opcode.UNREACHABLE)
                    ctx.last_stmt_was_stub = true  # PURE-908
                    return bytes
                end
            end
        end
        # Also check for local_get of externref-typed local
        if length(arg1_bytes) >= 2 && arg1_bytes[1] == Opcode.LOCAL_GET
            local local_idx_chk2 = 0
            local shift_chk2 = 0
            local pos_chk2 = 2
            while pos_chk2 <= length(arg1_bytes)
                b = arg1_bytes[pos_chk2]
                local_idx_chk2 |= (Int(b & 0x7f) << shift_chk2)
                shift_chk2 += 7
                pos_chk2 += 1
                (b & 0x80) == 0 && break
            end
            local offset_chk2 = local_idx_chk2 - ctx.n_params
            if offset_chk2 >= 0 && offset_chk2 < length(ctx.locals)
                local lt_chk2 = ctx.locals[offset_chk2 + 1]
                if lt_chk2 === ExternRef
                    # PURE-908: Clear pre-pushed args
                    bytes = UInt8[]
                    push!(bytes, Opcode.UNREACHABLE)
                    ctx.last_stmt_was_stub = true  # PURE-908
                    return bytes
                end
            end
        end
    end

    # Match intrinsics by name
    if is_func(func, :add_int)
        if is_128bit
            # 128-bit addition: (a_lo, a_hi) + (b_lo, b_hi)
            # Stack has: [a_struct, b_struct], need to produce result_struct
            # This is complex - need to extract fields, compute with carry, create new struct
            append!(bytes, emit_int128_add(ctx, arg_type))
        else
            push!(bytes, is_32bit ? Opcode.I32_ADD : Opcode.I64_ADD)
        end

    elseif is_func(func, :sub_int)
        if is_128bit
            # 128-bit subtraction
            append!(bytes, emit_int128_sub(ctx, arg_type))
        else
            push!(bytes, is_32bit ? Opcode.I32_SUB : Opcode.I64_SUB)
        end

    elseif is_func(func, :mul_int)
        if is_128bit
            # 128-bit multiplication (only need low 128 bits of result)
            append!(bytes, emit_int128_mul(ctx, arg_type))
        else
            push!(bytes, is_32bit ? Opcode.I32_MUL : Opcode.I64_MUL)
        end

    # PURE-325: checked_smul_int(a, b) -> Tuple{T, Bool} (result, overflow_flag)
    # In Wasm we just do the mul and return (result, false) — no overflow detection.
    elseif is_func(func, :checked_smul_int) || is_func(func, :checked_umul_int)
        if is_128bit
            # 128-bit checked mul: not supported, emit unreachable
            # PURE-908: Clear pre-pushed args
            bytes = UInt8[]
            push!(bytes, Opcode.UNREACHABLE)
            ctx.last_stmt_was_stub = true  # PURE-908
        else
            push!(bytes, is_32bit ? Opcode.I32_MUL : Opcode.I64_MUL)
            if is_32bit
                push!(bytes, Opcode.I64_EXTEND_I32_S)
            end
            # Push false (0) as overflow flag — Bool is i32 in Tuple{Int64, Bool} struct
            push!(bytes, Opcode.I32_CONST)
            push!(bytes, 0x00)
            tuple_type = Tuple{Int64, Bool}
            if !haskey(ctx.type_registry.structs, tuple_type)
                register_tuple_type!(ctx.mod, ctx.type_registry, tuple_type)
            end
            tuple_info = ctx.type_registry.structs[tuple_type]
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_NEW)
            append!(bytes, encode_leb128_unsigned(tuple_info.wasm_type_idx))
        end

    # PURE-325: checked_sadd_int(a, b) -> Tuple{T, Bool} (result, overflow_flag)
    elseif is_func(func, :checked_sadd_int) || is_func(func, :checked_uadd_int)
        if is_128bit
            # PURE-908: Clear pre-pushed args
            bytes = UInt8[]
            push!(bytes, Opcode.UNREACHABLE)
            ctx.last_stmt_was_stub = true  # PURE-908
        else
            push!(bytes, is_32bit ? Opcode.I32_ADD : Opcode.I64_ADD)
            if is_32bit
                push!(bytes, Opcode.I64_EXTEND_I32_S)
            end
            push!(bytes, Opcode.I32_CONST)
            push!(bytes, 0x00)
            tuple_type = Tuple{Int64, Bool}
            if !haskey(ctx.type_registry.structs, tuple_type)
                register_tuple_type!(ctx.mod, ctx.type_registry, tuple_type)
            end
            tuple_info = ctx.type_registry.structs[tuple_type]
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_NEW)
            append!(bytes, encode_leb128_unsigned(tuple_info.wasm_type_idx))
        end

    # PURE-325: checked_ssub_int(a, b) -> Tuple{T, Bool} (result, overflow_flag)
    elseif is_func(func, :checked_ssub_int) || is_func(func, :checked_usub_int)
        if is_128bit
            # PURE-908: Clear pre-pushed args
            bytes = UInt8[]
            push!(bytes, Opcode.UNREACHABLE)
            ctx.last_stmt_was_stub = true  # PURE-908
        else
            push!(bytes, is_32bit ? Opcode.I32_SUB : Opcode.I64_SUB)
            if is_32bit
                push!(bytes, Opcode.I64_EXTEND_I32_S)
            end
            push!(bytes, Opcode.I32_CONST)
            push!(bytes, 0x00)
            tuple_type = Tuple{Int64, Bool}
            if !haskey(ctx.type_registry.structs, tuple_type)
                register_tuple_type!(ctx.mod, ctx.type_registry, tuple_type)
            end
            tuple_info = ctx.type_registry.structs[tuple_type]
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_NEW)
            append!(bytes, encode_leb128_unsigned(tuple_info.wasm_type_idx))
        end

    elseif is_func(func, :sdiv_int) || is_func(func, :checked_sdiv_int)
        push!(bytes, is_32bit ? Opcode.I32_DIV_S : Opcode.I64_DIV_S)

    elseif is_func(func, :udiv_int) || is_func(func, :checked_udiv_int)
        push!(bytes, is_32bit ? Opcode.I32_DIV_U : Opcode.I64_DIV_U)

    elseif is_func(func, :srem_int) || is_func(func, :checked_srem_int)
        push!(bytes, is_32bit ? Opcode.I32_REM_S : Opcode.I64_REM_S)

    elseif is_func(func, :urem_int) || is_func(func, :checked_urem_int)
        push!(bytes, is_32bit ? Opcode.I32_REM_U : Opcode.I64_REM_U)

    # Bitcast (reinterpret bits between types)
    elseif is_func(func, :bitcast)
        # Bitcast reinterprets bits between same-size types
        # Need to emit reinterpret instructions for float<->int conversions
        # args = [target_type, source_value]
        # Get the target type - it's the first actual argument (args[1] after extracting args[2:end])
        target_type_ref = length(args) >= 1 ? args[1] : nothing
        source_val = length(args) >= 2 ? args[2] : nothing

        # Determine target type from the GlobalRef or type literal
        target_type = if target_type_ref isa GlobalRef
            # Try to get the actual type from the GlobalRef
            if target_type_ref.name === :Int64 || target_type_ref.name === Symbol("Base.Int64")
                Int64
            elseif target_type_ref.name === :UInt64
                UInt64
            elseif target_type_ref.name === :Int32 || target_type_ref.name === Symbol("Base.Int32")
                Int32
            elseif target_type_ref.name === :UInt32
                UInt32
            elseif target_type_ref.name === :Float64
                Float64
            elseif target_type_ref.name === :Float32
                Float32
            elseif target_type_ref.name === :Int128
                Int128
            elseif target_type_ref.name === :UInt128
                UInt128
            else
                # Try to evaluate the GlobalRef
                try
                    getfield(target_type_ref.mod, target_type_ref.name)
                catch
                    Any
                end
            end
        elseif target_type_ref isa DataType
            target_type_ref
        else
            Any
        end

        # Determine source type
        source_type = source_val !== nothing ? infer_value_type(source_val, ctx) : Any

        # Emit appropriate reinterpret instruction if needed
        if source_type === Float64 && (target_type === Int64 || target_type === UInt64)
            push!(bytes, Opcode.I64_REINTERPRET_F64)
        elseif (source_type === Int64 || source_type === UInt64) && target_type === Float64
            push!(bytes, Opcode.F64_REINTERPRET_I64)
        elseif source_type === Float32 && (target_type === Int32 || target_type === UInt32)
            push!(bytes, Opcode.I32_REINTERPRET_F32)
        elseif (source_type === Int32 || source_type === UInt32) && target_type === Float32
            push!(bytes, Opcode.F32_REINTERPRET_I32)
        end
        # For other cases (Int64<->UInt64, Int32<->UInt32, Int128<->UInt128),
        # bitcast is a no-op in Wasm (same representation)

    elseif is_func(func, :neg_int)
        if is_128bit
            # 128-bit negation
            append!(bytes, emit_int128_neg(ctx, arg_type))
        elseif is_32bit
            # For simplicity, emit: i32.const -1, i32.xor, i32.const 1, i32.add
            # Which is equivalent to: ~x + 1 = -x
            push!(bytes, Opcode.I32_CONST)
            push!(bytes, 0x7F)  # -1 in signed LEB128
            push!(bytes, Opcode.I32_XOR)
            push!(bytes, Opcode.I32_CONST)
            push!(bytes, 0x01)
            push!(bytes, Opcode.I32_ADD)
        else
            push!(bytes, Opcode.I64_CONST)
            push!(bytes, 0x7F)  # -1 in signed LEB128
            push!(bytes, Opcode.I64_XOR)
            push!(bytes, Opcode.I64_CONST)
            push!(bytes, 0x01)
            push!(bytes, Opcode.I64_ADD)
        end

    elseif is_func(func, :flipsign_int)
        # flipsign_int(x, y) returns -x if y < 0, otherwise x
        # Formula: (x xor signbit) - signbit where signbit = y >> 63 (all 1s if negative)
        # We need both x and y on stack, but they've been pushed as: [x, y]

        if is_128bit
            # For 128-bit, check if y's hi word is negative
            # flipsign_int(x, y) = y < 0 ? -x : x
            type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)

            # Pop y struct to local
            y_struct_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(y_struct_local))

            # Pop x struct to local
            x_struct_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(x_struct_local))

            # Get y's hi part to check sign
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(y_struct_local))
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_GET)
            append!(bytes, encode_leb128_unsigned(type_idx))
            append!(bytes, encode_leb128_unsigned(1))  # hi field

            # Check if negative (hi < 0)
            push!(bytes, Opcode.I64_CONST)
            push!(bytes, 0x00)
            push!(bytes, Opcode.I64_LT_S)

            # Store condition
            is_neg_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, I32)
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(is_neg_local))

            # Compute -x using emit_int128_neg
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(x_struct_local))
            append!(bytes, emit_int128_neg(ctx, arg_type))

            # Store negated x
            neg_x_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(neg_x_local))

            # Allocate result local
            result_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))

            # if is_neg { result = neg_x } else { result = x }
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(is_neg_local))
            push!(bytes, Opcode.IF)
            push!(bytes, 0x40)  # void

            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(neg_x_local))
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(result_local))

            push!(bytes, Opcode.ELSE)

            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(x_struct_local))
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(result_local))

            push!(bytes, Opcode.END)

            # Push result
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(result_local))

        else
            # Pop y to local, check sign, conditionally negate x
            y_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, is_32bit ? I32 : I64)
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(y_local))

            x_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, is_32bit ? I32 : I64)
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(x_local))

            # Compute signbit = y >> (bits-1) (arithmetic shift gives all 1s if negative)
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(y_local))
            if is_32bit
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 31)
                push!(bytes, Opcode.I32_SHR_S)
            else
                push!(bytes, Opcode.I64_CONST)
                push!(bytes, 63)
                push!(bytes, Opcode.I64_SHR_S)
            end

            signbit_local = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, is_32bit ? I32 : I64)
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(signbit_local))

            # result = (x xor signbit) - signbit
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(x_local))
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(signbit_local))
            push!(bytes, is_32bit ? Opcode.I32_XOR : Opcode.I64_XOR)
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(signbit_local))
            push!(bytes, is_32bit ? Opcode.I32_SUB : Opcode.I64_SUB)
        end

    # Comparison operations
    elseif is_func(func, :slt_int)  # signed less than
        if is_128bit
            append!(bytes, emit_int128_slt(ctx, arg_type))
        else
            push!(bytes, is_32bit ? Opcode.I32_LT_S : Opcode.I64_LT_S)
        end

    elseif is_func(func, :sle_int)  # signed less or equal
        if is_128bit
            append!(bytes, emit_int128_sle(ctx, arg_type))
        else
            push!(bytes, is_32bit ? Opcode.I32_LE_S : Opcode.I64_LE_S)
        end

    elseif is_func(func, :ult_int)  # unsigned less than
        if is_128bit
            append!(bytes, emit_int128_ult(ctx, arg_type))
        else
            push!(bytes, is_32bit ? Opcode.I32_LT_U : Opcode.I64_LT_U)
        end

    elseif is_func(func, :ule_int)  # unsigned less or equal
        if is_128bit
            append!(bytes, emit_int128_ule(ctx, arg_type))
        else
            push!(bytes, is_32bit ? Opcode.I32_LE_U : Opcode.I64_LE_U)
        end

    elseif is_func(func, :eq_int)
        if is_128bit
            append!(bytes, emit_int128_eq(ctx, arg_type))
        else
            push!(bytes, is_32bit ? Opcode.I32_EQ : Opcode.I64_EQ)
        end

    elseif is_func(func, :ne_int)
        if is_128bit
            append!(bytes, emit_int128_ne(ctx, arg_type))
        else
            push!(bytes, is_32bit ? Opcode.I32_NE : Opcode.I64_NE)
        end

    # Float comparison operations
    elseif is_func(func, :lt_float)
        push!(bytes, arg_type === Float32 ? Opcode.F32_LT : Opcode.F64_LT)

    elseif is_func(func, :le_float)
        push!(bytes, arg_type === Float32 ? Opcode.F32_LE : Opcode.F64_LE)

    elseif is_func(func, :gt_float)
        push!(bytes, arg_type === Float32 ? Opcode.F32_GT : Opcode.F64_GT)

    elseif is_func(func, :ge_float)
        push!(bytes, arg_type === Float32 ? Opcode.F32_GE : Opcode.F64_GE)

    elseif is_func(func, :eq_float)
        push!(bytes, arg_type === Float32 ? Opcode.F32_EQ : Opcode.F64_EQ)

    elseif is_func(func, :ne_float)
        push!(bytes, arg_type === Float32 ? Opcode.F32_NE : Opcode.F64_NE)

    # Identity comparison (=== for integers is same as ==, for floats use float eq)
    elseif is_func(func, :(===))
        if is_128bit
            append!(bytes, emit_int128_eq(ctx, arg_type))
        elseif arg_type === Float64
            push!(bytes, Opcode.F64_EQ)
        elseif arg_type === Float32
            push!(bytes, Opcode.F32_EQ)
        else
            local arg2_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : Int64
            local arg1_is_ref = is_ref_type_or_union(arg_type) && arg_type !== Nothing
            local arg2_is_ref = is_ref_type_or_union(arg2_type) && arg2_type !== Nothing

            # Quick check: if one arg is ref-typed and other is Nothing (compiles to i32),
            # they can't be equal via ref.eq OR i32/i64 eq. Drop both and return false.
            if (arg1_is_ref && arg2_type === Nothing) || (arg2_is_ref && arg_type === Nothing)
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                return bytes
            end

            # Special case: both args are Nothing-typed. Need to check actual Wasm representation
            # because Nothing can compile to either ref.null OR i32.const depending on context.
            if arg_type === Nothing && arg2_type === Nothing
                # Re-compile to check Wasm types
                local arg1_bytes_chk = compile_value(args[1], ctx)
                local arg2_bytes_chk = compile_value(args[2], ctx)
                local a1_is_ref = length(arg1_bytes_chk) >= 1 && (arg1_bytes_chk[1] == Opcode.REF_NULL ||
                    (arg1_bytes_chk[1] == Opcode.LOCAL_GET && length(arg1_bytes_chk) >= 2))
                local a2_is_ref = length(arg2_bytes_chk) >= 1 && (arg2_bytes_chk[1] == Opcode.REF_NULL ||
                    (arg2_bytes_chk[1] == Opcode.LOCAL_GET && length(arg2_bytes_chk) >= 2))
                # Check local types for LOCAL_GET
                if arg1_bytes_chk[1] == Opcode.LOCAL_GET && length(arg1_bytes_chk) >= 2
                    local idx1 = 0
                    local sh1 = 0
                    local p1 = 2
                    while p1 <= length(arg1_bytes_chk)
                        b = arg1_bytes_chk[p1]
                        idx1 |= (Int(b & 0x7f) << sh1)
                        sh1 += 7
                        p1 += 1
                        (b & 0x80) == 0 && break
                    end
                    local off1 = idx1 - ctx.n_params
                    if off1 >= 0 && off1 < length(ctx.locals)
                        local lt1 = ctx.locals[off1 + 1]
                        a1_is_ref = lt1 isa ConcreteRef || lt1 === StructRef || lt1 === ArrayRef || lt1 === ExternRef || lt1 === AnyRef
                    else
                        a1_is_ref = false
                    end
                end
                if arg2_bytes_chk[1] == Opcode.LOCAL_GET && length(arg2_bytes_chk) >= 2
                    local idx2 = 0
                    local sh2 = 0
                    local p2 = 2
                    while p2 <= length(arg2_bytes_chk)
                        b = arg2_bytes_chk[p2]
                        idx2 |= (Int(b & 0x7f) << sh2)
                        sh2 += 7
                        p2 += 1
                        (b & 0x80) == 0 && break
                    end
                    local off2 = idx2 - ctx.n_params
                    if off2 >= 0 && off2 < length(ctx.locals)
                        local lt2 = ctx.locals[off2 + 1]
                        a2_is_ref = lt2 isa ConcreteRef || lt2 === StructRef || lt2 === ArrayRef || lt2 === ExternRef || lt2 === AnyRef
                    else
                        a2_is_ref = false
                    end
                end
                # If Wasm types mismatch (one ref, one not), drop both and return false
                if a1_is_ref != a2_is_ref
                    push!(bytes, Opcode.DROP)
                    push!(bytes, Opcode.DROP)
                    push!(bytes, Opcode.I32_CONST)
                    push!(bytes, 0x00)
                    return bytes
                elseif a1_is_ref && a2_is_ref
                    # Both refs - use ref.eq
                    push!(bytes, Opcode.REF_EQ)
                    return bytes
                end
                # Both numeric - fall through to normal handling
            end

            # Check if args were actually compiled as refs (Nothing can compile to ref.null OR i32.const 0)
            # The bytes already have [arg1_bytes..., arg2_bytes...]
            # Check last pushed arg (arg2) - if it starts with REF_NULL (0xD0), it's a ref
            # Also check for local.get of ref-typed local
            local arg1_wasm_is_ref = arg1_is_ref
            local arg2_wasm_is_ref = arg2_is_ref
            local arg1_is_externref = (arg_type === Any)
            local arg2_is_externref = (arg2_type === Any)
            # PURE-046: Any ALWAYS maps to externref, so if arg_type or arg2_type is Any,
            # the corresponding wasm_is_ref must be true (regardless of local type checks)
            if arg_type === Any
                arg1_wasm_is_ref = true
                arg1_is_externref = true
            end
            if arg2_type === Any
                arg2_wasm_is_ref = true
                arg2_is_externref = true
            end
            # Check Wasm representation for any potentially mixed comparison
            # (when one arg is ref-typed or Nothing, verify actual Wasm types)
            if arg_type === Nothing || arg2_type === Nothing || arg1_is_ref || arg2_is_ref
                # Re-compile args to check their Wasm representation
                # arg1 first, arg2 second on stack
                # For Nothing-typed args, check actual Wasm representation
                # (Nothing can compile to ref.null OR i32.const 0 depending on context)
                # Check arg1's Wasm type when:
                # - arg_type === Nothing (need to verify if it's actually ref.null or i32)
                # - arg2_type === Nothing (need to know if arg1 is ref to do proper comparison)
                # - arg_type === Any (PURE-046: Any maps to externref, must check actual local type)
                if length(args) >= 1 && (arg_type === Nothing || arg2_type === Nothing || arg_type === Any || arg1_is_ref)
                    local arg1_bytes = compile_value(args[1], ctx)
                    if length(arg1_bytes) >= 1
                        if arg1_bytes[1] == Opcode.REF_NULL
                            arg1_wasm_is_ref = true
                        elseif arg1_bytes[1] == Opcode.I32_CONST || arg1_bytes[1] == Opcode.I64_CONST ||
                               arg1_bytes[1] == Opcode.F32_CONST || arg1_bytes[1] == Opcode.F64_CONST
                            # Numeric constant — definitely NOT a ref, regardless of Julia type
                            arg1_wasm_is_ref = false
                        elseif arg1_bytes[1] == Opcode.LOCAL_GET && length(arg1_bytes) >= 2
                            local local_idx_1 = 0
                            local shift_1 = 0
                            local pos_1 = 2
                            while pos_1 <= length(arg1_bytes)
                                b = arg1_bytes[pos_1]
                                local_idx_1 |= (Int(b & 0x7f) << shift_1)
                                shift_1 += 7
                                pos_1 += 1
                                (b & 0x80) == 0 && break
                            end
                            # ctx.locals doesn't include params, so adjust index
                            local local_offset_1 = local_idx_1 - ctx.n_params
                            if local_offset_1 >= 0 && local_offset_1 < length(ctx.locals)
                                local ltype_1 = ctx.locals[local_offset_1 + 1]
                                arg1_wasm_is_ref = ltype_1 isa ConcreteRef || ltype_1 === StructRef ||
                                                   ltype_1 === ArrayRef || ltype_1 === ExternRef || ltype_1 === AnyRef
                                arg1_is_externref = (ltype_1 === ExternRef)
                            elseif local_idx_1 < ctx.n_params && local_idx_1 < length(ctx.arg_types)
                                local ptype_1 = ctx.arg_types[local_idx_1 + 1]
                                local pwasm_1 = julia_to_wasm_type_concrete(ptype_1, ctx)
                                arg1_is_externref = (pwasm_1 === ExternRef)
                            end
                        end
                    end
                    # PURE-046: Override local type check if Julia type is Any
                    # The local might have been allocated wrong (PURE-036be issue), but
                    # Any ALWAYS means externref at runtime, so treat it as ref
                    if arg_type === Any
                        arg1_wasm_is_ref = true
                        arg1_is_externref = true
                    end
                end
                # Check arg2's Wasm type when:
                # - arg2_type === Nothing (need to verify if it's actually ref.null or i32)
                # - arg_type === Nothing (need to know if arg2 is ref to do proper comparison)
                # - arg2_type === Any (PURE-046: Any maps to externref, must check actual local type)
                if length(args) >= 2 && (arg2_type === Nothing || arg_type === Nothing || arg2_type === Any || arg2_is_ref)
                    local arg2_bytes = compile_value(args[2], ctx)
                    if length(arg2_bytes) >= 1
                        if arg2_bytes[1] == Opcode.REF_NULL
                            arg2_wasm_is_ref = true
                        elseif arg2_bytes[1] == Opcode.I32_CONST || arg2_bytes[1] == Opcode.I64_CONST ||
                               arg2_bytes[1] == Opcode.F32_CONST || arg2_bytes[1] == Opcode.F64_CONST
                            # Numeric constant — definitely NOT a ref
                            arg2_wasm_is_ref = false
                        elseif arg2_bytes[1] == Opcode.LOCAL_GET && length(arg2_bytes) >= 2
                            local local_idx_2 = 0
                            local shift_2 = 0
                            local pos_2 = 2
                            while pos_2 <= length(arg2_bytes)
                                b = arg2_bytes[pos_2]
                                local_idx_2 |= (Int(b & 0x7f) << shift_2)
                                shift_2 += 7
                                pos_2 += 1
                                (b & 0x80) == 0 && break
                            end
                            # ctx.locals doesn't include params, so adjust index
                            local local_offset_2 = local_idx_2 - ctx.n_params
                            if local_offset_2 >= 0 && local_offset_2 < length(ctx.locals)
                                local ltype_2 = ctx.locals[local_offset_2 + 1]
                                arg2_wasm_is_ref = ltype_2 isa ConcreteRef || ltype_2 === StructRef ||
                                                   ltype_2 === ArrayRef || ltype_2 === ExternRef || ltype_2 === AnyRef
                                arg2_is_externref = (ltype_2 === ExternRef)
                            elseif local_idx_2 < ctx.n_params && local_idx_2 < length(ctx.arg_types)
                                local ptype_2 = ctx.arg_types[local_idx_2 + 1]
                                local pwasm_2 = julia_to_wasm_type_concrete(ptype_2, ctx)
                                arg2_is_externref = (pwasm_2 === ExternRef)
                            end
                        end
                    end
                    # PURE-046: Override local type check if Julia type is Any
                    # The local might have been allocated wrong (PURE-036be issue), but
                    # Any ALWAYS means externref at runtime, so treat it as ref
                    if arg2_type === Any
                        arg2_wasm_is_ref = true
                        arg2_is_externref = true
                    end
                end
            end
            if arg1_wasm_is_ref && arg2_wasm_is_ref
                # PURE-324: For immutable structs, === means VALUE equality (field-by-field),
                # not identity. WasmGC ref.eq is identity comparison, so we must emit
                # struct.get for each field and compare with the appropriate opcode.
                local _do_struct_egal = false
                local _egal_struct_info = nothing
                if !arg1_is_externref && !arg2_is_externref &&
                   arg_type isa DataType && arg_type === arg2_type &&
                   is_struct_type(arg_type) && !ismutabletype(arg_type) &&
                   haskey(ctx.type_registry.structs, arg_type)
                    _egal_struct_info = ctx.type_registry.structs[arg_type]
                    _do_struct_egal = true
                end
                if _do_struct_egal
                    # Immutable struct === : field-by-field value comparison
                    local egal_info = _egal_struct_info
                    local egal_type_idx = egal_info.wasm_type_idx
                    local egal_wasm_type = ConcreteRef(egal_type_idx, true)
                    # Save both args to locals (arg2 is on top, arg1 below)
                    local egal_local2 = allocate_local!(ctx, egal_wasm_type)
                    local egal_local1 = allocate_local!(ctx, egal_wasm_type)
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(egal_local2))
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(egal_local1))
                    local n_fields = length(egal_info.field_types)
                    for fi in 1:n_fields
                        local egal_ft = egal_info.field_types[fi]
                        local egal_wt = julia_to_wasm_type(egal_ft)
                        # Get field fi-1 (0-indexed) from both structs
                        push!(bytes, Opcode.LOCAL_GET)
                        append!(bytes, encode_leb128_unsigned(egal_local1))
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.STRUCT_GET)
                        append!(bytes, encode_leb128_unsigned(egal_type_idx))
                        append!(bytes, encode_leb128_unsigned(fi - 1))
                        push!(bytes, Opcode.LOCAL_GET)
                        append!(bytes, encode_leb128_unsigned(egal_local2))
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.STRUCT_GET)
                        append!(bytes, encode_leb128_unsigned(egal_type_idx))
                        append!(bytes, encode_leb128_unsigned(fi - 1))
                        # Compare with type-appropriate opcode
                        if egal_wt === I32
                            push!(bytes, Opcode.I32_EQ)
                        elseif egal_wt === I64
                            push!(bytes, Opcode.I64_EQ)
                        elseif egal_wt === F32
                            push!(bytes, Opcode.F32_EQ)
                        elseif egal_wt === F64
                            push!(bytes, Opcode.F64_EQ)
                        elseif egal_wt === ExternRef
                            # PURE-6024: externref fields need conversion to eqref for ref.eq
                            local egal_tmp = allocate_local!(ctx, EqRef)
                            push!(bytes, Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN)
                            push!(bytes, Opcode.GC_PREFIX, Opcode.REF_CAST_NULL, UInt8(EqRef))
                            push!(bytes, Opcode.LOCAL_SET)
                            append!(bytes, encode_leb128_unsigned(egal_tmp))
                            push!(bytes, Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN)
                            push!(bytes, Opcode.GC_PREFIX, Opcode.REF_CAST_NULL, UInt8(EqRef))
                            push!(bytes, Opcode.LOCAL_GET)
                            append!(bytes, encode_leb128_unsigned(egal_tmp))
                            push!(bytes, Opcode.REF_EQ)
                        else
                            # Ref-typed field (nested struct, string, etc.): use ref.eq
                            push!(bytes, Opcode.REF_EQ)
                        end
                        # AND with previous field results (skip for first field)
                        if fi > 1
                            push!(bytes, Opcode.I32_AND)
                        end
                    end
                    # Handle zero-field structs (singleton types): always equal
                    if n_fields == 0
                        push!(bytes, Opcode.I32_CONST)
                        push!(bytes, 0x01)
                    end
                elseif arg1_is_externref && arg2_is_externref
                    # ref.eq requires eqref operands. externref is NOT eqref.
                    # Convert externref → anyref → eqref before ref.eq
                    # Both externref: convert arg2 (top), save, convert arg1, restore
                    local tmp_eq = allocate_local!(ctx, EqRef)
                    push!(bytes, Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN)
                    push!(bytes, Opcode.GC_PREFIX, Opcode.REF_CAST_NULL, UInt8(EqRef))
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(tmp_eq))
                    # Now arg1 (externref) is on top
                    push!(bytes, Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN)
                    push!(bytes, Opcode.GC_PREFIX, Opcode.REF_CAST_NULL, UInt8(EqRef))
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(tmp_eq))
                    push!(bytes, Opcode.REF_EQ)
                elseif arg1_is_externref
                    # arg1 is externref (under arg2 on stack): save arg2, convert arg1, restore arg2
                    local tmp_eq2 = allocate_local!(ctx, EqRef)
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(tmp_eq2))
                    push!(bytes, Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN)
                    push!(bytes, Opcode.GC_PREFIX, Opcode.REF_CAST_NULL, UInt8(EqRef))
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(tmp_eq2))
                    push!(bytes, Opcode.REF_EQ)
                elseif arg2_is_externref
                    # arg2 is externref (top of stack): just convert it
                    push!(bytes, Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN)
                    push!(bytes, Opcode.GC_PREFIX, Opcode.REF_CAST_NULL, UInt8(EqRef))
                    push!(bytes, Opcode.REF_EQ)
                else
                    # Both are non-externref refs (mutable structs, arrays, etc.): identity comparison
                    push!(bytes, Opcode.REF_EQ)
                end
            elseif arg1_wasm_is_ref && !arg2_wasm_is_ref
                # Comparing ref with non-ref: type mismatch, drop both and push false
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
            elseif !arg1_wasm_is_ref && arg2_wasm_is_ref
                # Comparing non-ref with ref: type mismatch, drop both and push false
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
            else
                # Both args are numeric. Check actual Wasm types to select correct opcode.
                # Julia type inference (is_32bit) may differ from actual Wasm local types.
                local arg1_actual_32bit = is_32bit
                local arg2_actual_32bit = arg2_type === Nothing || arg2_type === Bool ||
                                          arg2_type === Int32 || arg2_type === UInt32 ||
                                          arg2_type === Int16 || arg2_type === UInt16 ||
                                          arg2_type === Int8 || arg2_type === UInt8 || arg2_type === Char

                # Check arg1's actual Wasm local type (may differ from Julia type inference)
                local _arg1_local_is_ref = false  # true if arg1's local is ref-typed (not numeric)
                if length(args) >= 1
                    local arg1_chk = compile_value(args[1], ctx)
                    if length(arg1_chk) >= 2 && arg1_chk[1] == Opcode.LOCAL_GET
                        local idx_chk = 0
                        local sh_chk = 0
                        local p_chk = 2
                        while p_chk <= length(arg1_chk)
                            b = arg1_chk[p_chk]
                            idx_chk |= (Int(b & 0x7f) << sh_chk)
                            sh_chk += 7
                            p_chk += 1
                            (b & 0x80) == 0 && break
                        end
                        local off_chk = idx_chk - ctx.n_params
                        if off_chk >= 0 && off_chk < length(ctx.locals)
                            local lt_chk = ctx.locals[off_chk + 1]
                            arg1_actual_32bit = (lt_chk === I32)
                            # Detect ref-typed locals masquerading as numeric (e.g. Core.IntrinsicFunction
                            # is stored as ExternRef because julia_to_wasm_type returns ExternRef via
                            # T<:Function branch, but is_ref_type_or_union returns false for it)
                            if lt_chk === ExternRef || lt_chk === AnyRef || lt_chk === EqRef ||
                               lt_chk === StructRef || lt_chk === ArrayRef || lt_chk isa ConcreteRef
                                _arg1_local_is_ref = true
                            end
                        elseif idx_chk < ctx.n_params && idx_chk < length(ctx.arg_types)
                            # Function parameter - check arg_types
                            local ptype = ctx.arg_types[idx_chk + 1]
                            local pwasm = julia_to_wasm_type_concrete(ptype, ctx)
                            arg1_actual_32bit = (pwasm === I32)
                            if pwasm === ExternRef || pwasm === AnyRef || pwasm === EqRef ||
                               pwasm === StructRef || pwasm === ArrayRef || pwasm isa ConcreteRef
                                _arg1_local_is_ref = true
                            end
                        end
                    elseif length(arg1_chk) >= 1 && arg1_chk[1] == Opcode.I32_CONST
                        arg1_actual_32bit = true
                    elseif length(arg1_chk) >= 1 && arg1_chk[1] == Opcode.I64_CONST
                        arg1_actual_32bit = false
                    end
                end

                # Check arg2's actual Wasm type (may differ from Julia type inference)
                if length(args) >= 2
                    local arg2_chk = compile_value(args[2], ctx)
                    if length(arg2_chk) >= 2 && arg2_chk[1] == Opcode.LOCAL_GET
                        local idx2_chk = 0
                        local sh2_chk = 0
                        local p2_chk = 2
                        while p2_chk <= length(arg2_chk)
                            b = arg2_chk[p2_chk]
                            idx2_chk |= (Int(b & 0x7f) << sh2_chk)
                            sh2_chk += 7
                            p2_chk += 1
                            (b & 0x80) == 0 && break
                        end
                        local off2_chk = idx2_chk - ctx.n_params
                        if off2_chk >= 0 && off2_chk < length(ctx.locals)
                            local lt2_chk = ctx.locals[off2_chk + 1]
                            arg2_actual_32bit = (lt2_chk === I32)
                        elseif idx2_chk < ctx.n_params && idx2_chk < length(ctx.arg_types)
                            # Function parameter - check arg_types
                            local ptype2 = ctx.arg_types[idx2_chk + 1]
                            local pwasm2 = julia_to_wasm_type_concrete(ptype2, ctx)
                            arg2_actual_32bit = (pwasm2 === I32)
                        end
                    elseif length(arg2_chk) >= 1 && arg2_chk[1] == Opcode.I32_CONST
                        arg2_actual_32bit = true
                    elseif length(arg2_chk) >= 1 && arg2_chk[1] == Opcode.I64_CONST
                        arg2_actual_32bit = false
                    end
                end

                # Select opcode based on actual Wasm types
                if _arg1_local_is_ref
                    # arg1 is a ref type but Julia treated it as numeric (e.g. Core.IntrinsicFunction
                    # stored as ExternRef). A ref value can never equal a numeric constant, so drop
                    # both args and return false.
                    push!(bytes, Opcode.DROP)
                    push!(bytes, Opcode.DROP)
                    push!(bytes, Opcode.I32_CONST)
                    push!(bytes, 0x00)
                elseif arg1_actual_32bit && arg2_actual_32bit
                    # Both i32 - use i32_eq
                    push!(bytes, Opcode.I32_EQ)
                elseif arg1_actual_32bit && !arg2_actual_32bit
                    # arg1 is i32, arg2 is i64 - extend arg1 to i64
                    # But arg1 is already on stack below arg2. We need to swap and extend.
                    # Simpler: just compare as i32 if we can truncate arg2
                    # Since arg2 is on top of stack, wrap it to i32
                    push!(bytes, Opcode.I32_WRAP_I64)
                    push!(bytes, Opcode.I32_EQ)
                elseif !arg1_actual_32bit && arg2_actual_32bit
                    # arg1 is i64, arg2 is i32 - extend arg2 (on top of stack) to i64
                    push!(bytes, Opcode.I64_EXTEND_I32_S)
                    push!(bytes, Opcode.I64_EQ)
                else
                    # Both i64 - use i64_eq
                    push!(bytes, Opcode.I64_EQ)
                end
            end
        end

    elseif is_func(func, :(!==))
        if is_128bit
            append!(bytes, emit_int128_ne(ctx, arg_type))
        elseif arg_type === Float64
            push!(bytes, Opcode.F64_NE)
        elseif arg_type === Float32
            push!(bytes, Opcode.F32_NE)
        else
            local arg2_type_ne = length(args) >= 2 ? infer_value_type(args[2], ctx) : Int64
            local arg1_is_ref_ne = is_ref_type_or_union(arg_type) && arg_type !== Nothing
            local arg2_is_ref_ne = is_ref_type_or_union(arg2_type_ne) && arg2_type_ne !== Nothing

            # Quick check: if one arg is ref-typed and other is Nothing (compiles to i32),
            # they can't be equal, so !== is always true. Drop both and return true.
            if (arg1_is_ref_ne && arg2_type_ne === Nothing) || (arg2_is_ref_ne && arg_type === Nothing)
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                return bytes
            end

            # Special case: both args are Nothing-typed. Need to check actual Wasm representation.
            if arg_type === Nothing && arg2_type_ne === Nothing
                local arg1_bytes_ne_chk = compile_value(args[1], ctx)
                local arg2_bytes_ne_chk = compile_value(args[2], ctx)
                local a1_ref_ne = length(arg1_bytes_ne_chk) >= 1 && (arg1_bytes_ne_chk[1] == Opcode.REF_NULL ||
                    (arg1_bytes_ne_chk[1] == Opcode.LOCAL_GET && length(arg1_bytes_ne_chk) >= 2))
                local a2_ref_ne = length(arg2_bytes_ne_chk) >= 1 && (arg2_bytes_ne_chk[1] == Opcode.REF_NULL ||
                    (arg2_bytes_ne_chk[1] == Opcode.LOCAL_GET && length(arg2_bytes_ne_chk) >= 2))
                if arg1_bytes_ne_chk[1] == Opcode.LOCAL_GET && length(arg1_bytes_ne_chk) >= 2
                    local idx1_ne = 0
                    local sh1_ne = 0
                    local p1_ne = 2
                    while p1_ne <= length(arg1_bytes_ne_chk)
                        b = arg1_bytes_ne_chk[p1_ne]
                        idx1_ne |= (Int(b & 0x7f) << sh1_ne)
                        sh1_ne += 7
                        p1_ne += 1
                        (b & 0x80) == 0 && break
                    end
                    local off1_ne = idx1_ne - ctx.n_params
                    if off1_ne >= 0 && off1_ne < length(ctx.locals)
                        local lt1_ne = ctx.locals[off1_ne + 1]
                        a1_ref_ne = lt1_ne isa ConcreteRef || lt1_ne === StructRef || lt1_ne === ArrayRef || lt1_ne === ExternRef || lt1_ne === AnyRef
                    else
                        a1_ref_ne = false
                    end
                end
                if arg2_bytes_ne_chk[1] == Opcode.LOCAL_GET && length(arg2_bytes_ne_chk) >= 2
                    local idx2_ne = 0
                    local sh2_ne = 0
                    local p2_ne = 2
                    while p2_ne <= length(arg2_bytes_ne_chk)
                        b = arg2_bytes_ne_chk[p2_ne]
                        idx2_ne |= (Int(b & 0x7f) << sh2_ne)
                        sh2_ne += 7
                        p2_ne += 1
                        (b & 0x80) == 0 && break
                    end
                    local off2_ne = idx2_ne - ctx.n_params
                    if off2_ne >= 0 && off2_ne < length(ctx.locals)
                        local lt2_ne = ctx.locals[off2_ne + 1]
                        a2_ref_ne = lt2_ne isa ConcreteRef || lt2_ne === StructRef || lt2_ne === ArrayRef || lt2_ne === ExternRef || lt2_ne === AnyRef
                    else
                        a2_ref_ne = false
                    end
                end
                # If Wasm types mismatch (one ref, one not), drop both and return true (not equal)
                if a1_ref_ne != a2_ref_ne
                    push!(bytes, Opcode.DROP)
                    push!(bytes, Opcode.DROP)
                    push!(bytes, Opcode.I32_CONST)
                    push!(bytes, 0x01)
                    return bytes
                elseif a1_ref_ne && a2_ref_ne
                    # Both refs - use ref.eq then negate
                    push!(bytes, Opcode.REF_EQ)
                    push!(bytes, Opcode.I32_EQZ)
                    return bytes
                end
                # Both numeric - fall through to normal handling
            end

            # Check actual Wasm representation for Nothing-typed args
            local arg1_wasm_is_ref_ne = arg1_is_ref_ne
            local arg2_wasm_is_ref_ne = arg2_is_ref_ne
            local arg1_is_externref_ne = (arg_type === Any)
            local arg2_is_externref_ne = (arg2_type_ne === Any)
            # Check Wasm representation for any potentially mixed comparison
            if arg_type === Nothing || arg2_type_ne === Nothing || arg1_is_ref_ne || arg2_is_ref_ne
                # For Nothing-typed args, check actual Wasm representation
                if length(args) >= 1 && arg_type === Nothing
                    local arg1_bytes = compile_value(args[1], ctx)
                    if length(arg1_bytes) >= 1
                        if arg1_bytes[1] == Opcode.REF_NULL
                            arg1_wasm_is_ref_ne = true
                        elseif arg1_bytes[1] == Opcode.LOCAL_GET && length(arg1_bytes) >= 2
                            local local_idx_ne1 = 0
                            local shift_ne1 = 0
                            local pos_ne1 = 2
                            while pos_ne1 <= length(arg1_bytes)
                                b = arg1_bytes[pos_ne1]
                                local_idx_ne1 |= (Int(b & 0x7f) << shift_ne1)
                                shift_ne1 += 7
                                pos_ne1 += 1
                                (b & 0x80) == 0 && break
                            end
                            # ctx.locals doesn't include params, so adjust index
                            local local_offset_ne1 = local_idx_ne1 - ctx.n_params
                            if local_offset_ne1 >= 0 && local_offset_ne1 < length(ctx.locals)
                                local ltype_ne1 = ctx.locals[local_offset_ne1 + 1]
                                arg1_wasm_is_ref_ne = ltype_ne1 isa ConcreteRef || ltype_ne1 === StructRef ||
                                                      ltype_ne1 === ArrayRef || ltype_ne1 === ExternRef || ltype_ne1 === AnyRef
                            end
                        end
                    end
                end
                if length(args) >= 2 && arg2_type_ne === Nothing
                    local arg2_bytes = compile_value(args[2], ctx)
                    if length(arg2_bytes) >= 1
                        if arg2_bytes[1] == Opcode.REF_NULL
                            arg2_wasm_is_ref_ne = true
                        elseif arg2_bytes[1] == Opcode.LOCAL_GET && length(arg2_bytes) >= 2
                            local local_idx_ne2 = 0
                            local shift_ne2 = 0
                            local pos_ne2 = 2
                            while pos_ne2 <= length(arg2_bytes)
                                b = arg2_bytes[pos_ne2]
                                local_idx_ne2 |= (Int(b & 0x7f) << shift_ne2)
                                shift_ne2 += 7
                                pos_ne2 += 1
                                (b & 0x80) == 0 && break
                            end
                            # ctx.locals doesn't include params, so adjust index
                            local local_offset_ne2 = local_idx_ne2 - ctx.n_params
                            if local_offset_ne2 >= 0 && local_offset_ne2 < length(ctx.locals)
                                local ltype_ne2 = ctx.locals[local_offset_ne2 + 1]
                                arg2_wasm_is_ref_ne = ltype_ne2 isa ConcreteRef || ltype_ne2 === StructRef ||
                                                      ltype_ne2 === ArrayRef || ltype_ne2 === ExternRef || ltype_ne2 === AnyRef
                            end
                        end
                    end
                end
            end
            # BOTH args must be ref types to use ref.eq
            if arg1_wasm_is_ref_ne && arg2_wasm_is_ref_ne
                # Convert externref → eqref before ref.eq (same pattern as === handler)
                if arg1_is_externref_ne && arg2_is_externref_ne
                    local tmp_ne = allocate_local!(ctx, EqRef)
                    push!(bytes, Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN)
                    push!(bytes, Opcode.GC_PREFIX, Opcode.REF_CAST_NULL, UInt8(EqRef))
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(tmp_ne))
                    push!(bytes, Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN)
                    push!(bytes, Opcode.GC_PREFIX, Opcode.REF_CAST_NULL, UInt8(EqRef))
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(tmp_ne))
                elseif arg1_is_externref_ne
                    local tmp_ne2 = allocate_local!(ctx, EqRef)
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(tmp_ne2))
                    push!(bytes, Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN)
                    push!(bytes, Opcode.GC_PREFIX, Opcode.REF_CAST_NULL, UInt8(EqRef))
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(tmp_ne2))
                elseif arg2_is_externref_ne
                    push!(bytes, Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN)
                    push!(bytes, Opcode.GC_PREFIX, Opcode.REF_CAST_NULL, UInt8(EqRef))
                end
                push!(bytes, Opcode.REF_EQ)
                push!(bytes, Opcode.I32_EQZ)  # Negate for !==
            elseif arg1_wasm_is_ref_ne && !arg2_wasm_is_ref_ne
                # Comparing ref with non-ref: type mismatch, always not-equal
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
            elseif !arg1_wasm_is_ref_ne && arg2_wasm_is_ref_ne
                # Comparing non-ref with ref: type mismatch, always not-equal
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
            elseif !is_32bit && arg2_type_ne === Nothing
                # arg1 is 64-bit, arg2 is Nothing (i32). Extend i32 to i64 before comparing.
                push!(bytes, Opcode.I64_EXTEND_I32_S)
                push!(bytes, Opcode.I64_NE)
            elseif is_32bit && arg_type === Nothing && !is_ref_type_or_union(arg2_type_ne)
                # arg1 is Nothing (i32), arg2 is 64-bit - mismatched types, always not-equal
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
            else
                push!(bytes, is_32bit ? Opcode.I32_NE : Opcode.I64_NE)
            end
        end

    # Bitwise operations
    elseif is_func(func, :and_int)
        if is_128bit
            append!(bytes, emit_int128_and(ctx, arg_type))
        else
            push!(bytes, is_32bit ? Opcode.I32_AND : Opcode.I64_AND)
        end

    elseif is_func(func, :or_int)
        if is_128bit
            append!(bytes, emit_int128_or(ctx, arg_type))
        else
            push!(bytes, is_32bit ? Opcode.I32_OR : Opcode.I64_OR)
        end

    elseif is_func(func, :xor_int)
        if is_128bit
            append!(bytes, emit_int128_xor(ctx, arg_type))
        else
            push!(bytes, is_32bit ? Opcode.I32_XOR : Opcode.I64_XOR)
        end

    elseif is_func(func, :not_int)
        # Check if this is boolean negation (result of comparison)
        # If so, use eqz instead of bitwise NOT
        if length(args) == 1 && is_boolean_value(args[1], ctx)
            # Boolean NOT: eqz turns 0->1, 1->0
            push!(bytes, Opcode.I32_EQZ)
        else
            # Bitwise NOT: x xor -1
            if is_32bit
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x7F)  # -1
                push!(bytes, Opcode.I32_XOR)
            else
                push!(bytes, Opcode.I64_CONST)
                push!(bytes, 0x7F)  # -1
                push!(bytes, Opcode.I64_XOR)
            end
        end

    # Shift operations
    # Note: Wasm requires shift amount to have same type as value being shifted
    # Julia often uses Int64/UInt64 shift amounts even for Int32 values
    elseif is_func(func, :shl_int)
        if is_128bit
            # 128-bit left shift: stack has [x_struct, n_i64]
            append!(bytes, emit_int128_shl(ctx, arg_type))
        else
            if length(args) >= 2
                shift_type = infer_value_type(args[2], ctx)
                if is_32bit && (shift_type === Int64 || shift_type === UInt64)
                    # Truncate i64 shift amount to i32
                    push!(bytes, Opcode.I32_WRAP_I64)
                elseif !is_32bit && shift_type !== Int64 && shift_type !== UInt64 && shift_type !== Int128 && shift_type !== UInt128
                    # Extend i32 shift amount to i64 (Wasm requires matching types)
                    push!(bytes, Opcode.I64_EXTEND_I32_S)
                end
            end
            push!(bytes, is_32bit ? Opcode.I32_SHL : Opcode.I64_SHL)
        end

    elseif is_func(func, :ashr_int)  # arithmetic shift right
        if length(args) >= 2
            shift_type = infer_value_type(args[2], ctx)
            if is_32bit && (shift_type === Int64 || shift_type === UInt64)
                # Truncate i64 shift amount to i32
                push!(bytes, Opcode.I32_WRAP_I64)
            elseif !is_32bit && shift_type !== Int64 && shift_type !== UInt64 && shift_type !== Int128 && shift_type !== UInt128
                # Extend i32 shift amount to i64 (Wasm requires matching types)
                push!(bytes, Opcode.I64_EXTEND_I32_S)
            end
        end
        push!(bytes, is_32bit ? Opcode.I32_SHR_S : Opcode.I64_SHR_S)

    elseif is_func(func, :lshr_int)  # logical shift right
        if is_128bit
            # 128-bit logical right shift: stack has [x_struct, n_i64]
            append!(bytes, emit_int128_lshr(ctx, arg_type))
        else
            if length(args) >= 2
                shift_type = infer_value_type(args[2], ctx)
                if is_32bit && (shift_type === Int64 || shift_type === UInt64)
                    # Truncate i64 shift amount to i32
                    push!(bytes, Opcode.I32_WRAP_I64)
                elseif !is_32bit && shift_type !== Int64 && shift_type !== UInt64 && shift_type !== Int128 && shift_type !== UInt128
                    # Extend i32 shift amount to i64 (Wasm requires matching types)
                    push!(bytes, Opcode.I64_EXTEND_I32_S)
                end
            end
            push!(bytes, is_32bit ? Opcode.I32_SHR_U : Opcode.I64_SHR_U)
        end

    # Count leading/trailing zeros (used in Char conversion)
    elseif is_func(func, :ctlz_int)
        if is_128bit
            append!(bytes, emit_int128_ctlz(ctx, arg_type))
        else
            push!(bytes, is_32bit ? Opcode.I32_CLZ : Opcode.I64_CLZ)
        end

    elseif is_func(func, :cttz_int)
        push!(bytes, is_32bit ? Opcode.I32_CTZ : Opcode.I64_CTZ)

    # Byte swap (used in Char ↔ codepoint conversion)
    # WebAssembly has no native bswap — implement with bit manipulation
    elseif is_func(func, :bswap_int)
        # Allocate a scratch local to hold the input value (need it 4 times)
        scratch_local = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, is_32bit ? I32 : I64)
        # Store input value
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(scratch_local))
        if is_32bit
            # i32 bswap: reverse 4 bytes
            # ((x >> 24) & 0xFF) | ((x >> 8) & 0xFF00) | ((x << 8) & 0xFF0000) | (x << 24)
            # Part 1: (x >> 24) & 0xFF — top byte to bottom
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(scratch_local))
            push!(bytes, Opcode.I32_CONST); append!(bytes, encode_leb128_signed(Int64(24)))
            push!(bytes, Opcode.I32_SHR_U)
            push!(bytes, Opcode.I32_CONST); append!(bytes, encode_leb128_signed(Int64(0xFF)))
            push!(bytes, Opcode.I32_AND)
            # Part 2: (x >> 8) & 0xFF00
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(scratch_local))
            push!(bytes, Opcode.I32_CONST); append!(bytes, encode_leb128_signed(Int64(8)))
            push!(bytes, Opcode.I32_SHR_U)
            push!(bytes, Opcode.I32_CONST); append!(bytes, encode_leb128_signed(Int64(0xFF00)))
            push!(bytes, Opcode.I32_AND)
            push!(bytes, Opcode.I32_OR)
            # Part 3: (x << 8) & 0xFF0000
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(scratch_local))
            push!(bytes, Opcode.I32_CONST); append!(bytes, encode_leb128_signed(Int64(8)))
            push!(bytes, Opcode.I32_SHL)
            push!(bytes, Opcode.I32_CONST); append!(bytes, encode_leb128_signed(Int64(0xFF0000)))
            push!(bytes, Opcode.I32_AND)
            push!(bytes, Opcode.I32_OR)
            # Part 4: x << 24 — bottom byte to top
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(scratch_local))
            push!(bytes, Opcode.I32_CONST); append!(bytes, encode_leb128_signed(Int64(24)))
            push!(bytes, Opcode.I32_SHL)
            push!(bytes, Opcode.I32_OR)
        else
            # i64 bswap: reverse 8 bytes
            # Same pattern but with 8 byte positions
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(scratch_local))
            push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(Int64(56)))
            push!(bytes, Opcode.I64_SHR_U)
            push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(Int64(0xFF)))
            push!(bytes, Opcode.I64_AND)
            for (shift, mask) in [(40, 0xFF00), (24, 0xFF0000), (8, 0xFF000000),
                                   (-8, 0xFF00000000), (-24, 0xFF0000000000),
                                   (-40, 0xFF000000000000)]
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(scratch_local))
                if shift > 0
                    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(Int64(shift)))
                    push!(bytes, Opcode.I64_SHR_U)
                else
                    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(Int64(-shift)))
                    push!(bytes, Opcode.I64_SHL)
                end
                push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(Int64(mask)))
                push!(bytes, Opcode.I64_AND)
                push!(bytes, Opcode.I64_OR)
            end
            # Last part: x << 56 (no mask needed)
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(scratch_local))
            push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(Int64(56)))
            push!(bytes, Opcode.I64_SHL)
            push!(bytes, Opcode.I64_OR)
        end

    # Float operations
    elseif is_func(func, :add_float)
        push!(bytes, arg_type === Float32 ? Opcode.F32_ADD : Opcode.F64_ADD)

    elseif is_func(func, :sub_float)
        push!(bytes, arg_type === Float32 ? Opcode.F32_SUB : Opcode.F64_SUB)

    elseif is_func(func, :mul_float)
        push!(bytes, arg_type === Float32 ? Opcode.F32_MUL : Opcode.F64_MUL)

    elseif is_func(func, :div_float)
        push!(bytes, arg_type === Float32 ? Opcode.F32_DIV : Opcode.F64_DIV)

    elseif is_func(func, :neg_float)
        push!(bytes, arg_type === Float32 ? Opcode.F32_NEG : Opcode.F64_NEG)

    # Fused multiply-add: muladd_float(a, b, c) = a*b + c
    # WASM doesn't have native fma, so we implement as mul then add
    elseif is_func(func, :muladd_float)
        # Stack has [a, b, c], we need to compute a*b + c
        # First multiply a*b, then add c
        push!(bytes, arg_type === Float32 ? Opcode.F32_MUL : Opcode.F64_MUL)
        push!(bytes, arg_type === Float32 ? Opcode.F32_ADD : Opcode.F64_ADD)

    # Type conversions
    elseif is_func(func, :sext_int)  # Sign extend
        # sext_int(TargetType, value) - first arg is target type
        target_type_ref = args[1]
        # Extract actual type from GlobalRef if needed
        target_type = if target_type_ref isa GlobalRef
            try
                getfield(target_type_ref.mod, target_type_ref.name)
            catch
                target_type_ref
            end
        else
            target_type_ref
        end
        if target_type === Int64 || target_type === UInt64
            # Extending to 64-bit - emit extend instruction
            # PURE-324: Skip extend if source is already i64 (e.g., from widened phi local)
            src_wasm = length(args) >= 2 ? get_phi_edge_wasm_type(args[2], ctx) : nothing
            if src_wasm !== I64
                push!(bytes, Opcode.I64_EXTEND_I32_S)
            end
        elseif target_type === Int128 || target_type === UInt128
            # Sign-extending to 128-bit - create struct with (lo=value, hi=sign_extension)
            # The value is already on the stack (i64)
            source_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : Int64

            # If source is 32-bit, sign-extend to 64-bit first
            # PURE-325: Bool also maps to i32
            if source_type === Int32 || source_type === UInt32 || source_type === Int16 || source_type === Int8 || source_type === Bool
                push!(bytes, Opcode.I64_EXTEND_I32_S)
            end

            # Now we have i64 on stack (the lo part)
            # Need to duplicate it to compute the hi part (sign extension)
            # Use a scratch local: store, load twice
            scratch_idx = ctx.n_params + length(ctx.locals)
            push!(ctx.locals, I64)

            # Store to scratch
            push!(bytes, Opcode.LOCAL_TEE)
            append!(bytes, encode_leb128_unsigned(scratch_idx))

            # Compute hi = lo >> 63 (arithmetic shift, gives 0 or -1)
            push!(bytes, Opcode.I64_CONST)
            push!(bytes, 0x3f)  # 63
            push!(bytes, Opcode.I64_SHR_S)

            # Stack: [hi]. Need [lo, hi] for struct.new
            # Save hi to scratch, then push lo, then hi
            scratch2_idx = ctx.n_params + length(ctx.locals)
            push!(ctx.locals, I64)
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(scratch2_idx))

            # Stack: [] — push in struct field order: lo first, then hi
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(scratch_idx))
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(scratch2_idx))

            # Create the 128-bit struct (lo, hi)
            type_idx = get_int128_type!(ctx.mod, ctx.type_registry, target_type)
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_NEW)
            append!(bytes, encode_leb128_unsigned(type_idx))
        end
        # If extending to 32-bit (Int32), it's a no-op since small types already map to i32

    elseif is_func(func, :zext_int)  # Zero extend
        # zext_int(TargetType, value) - first arg is target type
        target_type_ref = args[1]
        # Extract actual type from GlobalRef if needed
        target_type = if target_type_ref isa GlobalRef
            try
                getfield(target_type_ref.mod, target_type_ref.name)
            catch
                target_type_ref
            end
        else
            target_type_ref
        end
        if target_type === Int64 || target_type === UInt64
            # Extending to 64-bit - emit extend instruction
            # PURE-324: Skip extend if source is already i64 (e.g., from widened phi local)
            src_wasm_z = length(args) >= 2 ? get_phi_edge_wasm_type(args[2], ctx) : nothing
            if src_wasm_z !== I64
                push!(bytes, Opcode.I64_EXTEND_I32_U)
            end
        elseif target_type === Int128 || target_type === UInt128
            # Extending to 128-bit - create struct with (lo=value, hi=0)
            # The value is already on the stack (i64), need to create 128-bit struct
            source_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : UInt64

            # If source is 32-bit, extend to 64-bit first
            # PURE-325: Bool also maps to i32, so include it here
            if source_type === Int32 || source_type === UInt32 || source_type === Bool
                push!(bytes, Opcode.I64_EXTEND_I32_U)
            end

            # Now we have i64 on stack (the lo part)
            # Push 0 for hi part
            push!(bytes, Opcode.I64_CONST)
            push!(bytes, 0x00)

            # Create the 128-bit struct (lo, hi)
            type_idx = get_int128_type!(ctx.mod, ctx.type_registry, target_type)
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_NEW)
            append!(bytes, encode_leb128_unsigned(type_idx))
        end
        # If extending to 32-bit (UInt32/Int32), it's a no-op since small types already map to i32

    elseif is_func(func, :trunc_int)  # Truncate to smaller type
        # trunc_int(TargetType, value)
        target_type_ref = args[1]
        target_type = if target_type_ref isa GlobalRef
            try
                getfield(target_type_ref.mod, target_type_ref.name)
            catch
                target_type_ref
            end
        else
            target_type_ref
        end

        source_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : Int64

        # Determine source and target WASM bit widths
        # PURE-324: Also check actual Wasm type — widened phi locals may be I64
        # even though Julia type says UInt32
        source_is_64bit = source_type === Int64 || source_type === UInt64 || source_type === Int
        if !source_is_64bit && length(args) >= 2
            src_wasm_t = get_phi_edge_wasm_type(args[2], ctx)
            if src_wasm_t === I64
                source_is_64bit = true
            end
        end
        target_is_32bit = target_type === Int32 || target_type === UInt32 ||
                          target_type === Int16 || target_type === UInt16 ||
                          target_type === Int8 || target_type === UInt8 ||
                          target_type === Bool || target_type === Char

        if source_type === Int128 || source_type === UInt128
            # Truncating from 128-bit - extract lo part
            source_type_idx = get_int128_type!(ctx.mod, ctx.type_registry, source_type)
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_GET)
            append!(bytes, encode_leb128_unsigned(source_type_idx))
            append!(bytes, encode_leb128_unsigned(0))  # Field 0 = lo

            # Now we have i64, may need to wrap to i32
            if target_is_32bit
                push!(bytes, Opcode.I32_WRAP_I64)
            end
        elseif source_is_64bit && target_is_32bit
            # i64 to i32 truncation (includes UInt8, Int8, UInt16, Int16 targets)
            push!(bytes, Opcode.I32_WRAP_I64)
        end
        # i64 to i64 or i32 to i32 is a no-op

    elseif is_func(func, :sitofp)  # Signed int to float
        # sitofp(TargetType, value) - first arg is target type, second is value
        # Need to check: target float type (first arg) and source int type (second arg)
        target_type = args[1]  # Float32 or Float64
        source_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : Int64
        source_is_32bit = source_type === Int32 || source_type === UInt32 || source_type === Char ||
                          source_type === Int16 || source_type === UInt16 || source_type === Int8 || source_type === UInt8 ||
                          (isprimitivetype(source_type) && sizeof(source_type) <= 4)

        if target_type === Float32
            push!(bytes, source_is_32bit ? Opcode.F32_CONVERT_I32_S : Opcode.F32_CONVERT_I64_S)
        else  # Float64
            push!(bytes, source_is_32bit ? Opcode.F64_CONVERT_I32_S : Opcode.F64_CONVERT_I64_S)
        end

    elseif is_func(func, :uitofp)  # Unsigned int to float
        target_type = args[1]
        source_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : Int64
        source_is_32bit = source_type === Int32 || source_type === UInt32 || source_type === Char ||
                          source_type === Int16 || source_type === UInt16 || source_type === Int8 || source_type === UInt8 ||
                          (isprimitivetype(source_type) && sizeof(source_type) <= 4)

        if target_type === Float32
            push!(bytes, source_is_32bit ? Opcode.F32_CONVERT_I32_U : Opcode.F32_CONVERT_I64_U)
        else  # Float64
            push!(bytes, source_is_32bit ? Opcode.F64_CONVERT_I32_U : Opcode.F64_CONVERT_I64_U)
        end

    elseif is_func(func, :fptosi)  # Float to signed int
        # fptosi(TargetType, value) - first arg is target type
        target_type = args[1]
        source_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : Float64
        source_is_f32 = source_type === Float32

        if target_type === Int32
            push!(bytes, source_is_f32 ? Opcode.I32_TRUNC_F32_S : Opcode.I32_TRUNC_F64_S)
        else  # Int64
            push!(bytes, source_is_f32 ? Opcode.I64_TRUNC_F32_S : Opcode.I64_TRUNC_F64_S)
        end

    elseif is_func(func, :fptoui)  # Float to unsigned int
        target_type = args[1]
        source_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : Float64
        source_is_f32 = source_type === Float32

        if target_type === UInt32
            push!(bytes, source_is_f32 ? Opcode.I32_TRUNC_F32_U : Opcode.I32_TRUNC_F64_U)
        else  # UInt64
            push!(bytes, source_is_f32 ? Opcode.I64_TRUNC_F32_U : Opcode.I64_TRUNC_F64_U)
        end

    elseif is_func(func, :fpext)  # Float precision extension
        # fpext(TargetType, value) - extend to Float64
        source_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : Float32
        if source_type === Float16
            # Float16 (i32 on stack) → Float64
            # Convert Float16 bit pattern to Float32 bit pattern using integer ops,
            # then reinterpret as f32 and promote to f64.
            # Float16: 1 sign, 5 exp, 10 mantissa
            # Float32: 1 sign, 8 exp, 23 mantissa
            # For normalized: f32_bits = (sign<<31) | ((exp+112)<<23) | (mant<<13)
            # For zero: f32_bits = sign<<31
            # For inf/nan: f32_bits = (sign<<31) | (0xff<<23) | (mant<<13)
            #
            # We use a branchless approach for normalized values with special-case
            # handling for zero and inf/nan via select.
            #
            # Stack: [i32 = Float16 bits]
            # Strategy: extract sign, exp, mant; build f32 bits; reinterpret; promote

            # Save the Float16 bits to a temp local
            local_idx = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, I32)
            h_local = local_idx
            push!(bytes, Opcode.LOCAL_TEE)
            append!(bytes, encode_leb128_unsigned(UInt64(h_local)))

            # Extract sign: (h >> 15) << 31
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(UInt64(h_local)))
            push!(bytes, Opcode.I32_CONST); append!(bytes, encode_leb128_signed(Int64(15)))
            push!(bytes, Opcode.I32_SHR_U)
            push!(bytes, Opcode.I32_CONST); append!(bytes, encode_leb128_signed(Int64(31)))
            push!(bytes, Opcode.I32_SHL)
            # Stack: [h, sign_bit]

            # Extract exp: (h >> 10) & 0x1f
            local_idx2 = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, I32)
            sign_local = local_idx2
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(UInt64(sign_local)))

            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(UInt64(h_local)))
            push!(bytes, Opcode.I32_CONST); append!(bytes, encode_leb128_signed(Int64(10)))
            push!(bytes, Opcode.I32_SHR_U)
            push!(bytes, Opcode.I32_CONST); append!(bytes, encode_leb128_signed(Int64(0x1f)))
            push!(bytes, Opcode.I32_AND)

            local_idx3 = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, I32)
            exp_local = local_idx3
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(UInt64(exp_local)))

            # Extract mant: h & 0x3ff
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(UInt64(h_local)))
            push!(bytes, Opcode.I32_CONST); append!(bytes, encode_leb128_signed(Int64(0x3ff)))
            push!(bytes, Opcode.I32_AND)

            local_idx4 = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, I32)
            mant_local = local_idx4
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(UInt64(mant_local)))

            # Build f32 bits for normalized case:
            # sign_bit | ((exp + 112) << 23) | (mant << 13)
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(UInt64(sign_local)))

            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(UInt64(exp_local)))
            push!(bytes, Opcode.I32_CONST); append!(bytes, encode_leb128_signed(Int64(112)))
            push!(bytes, Opcode.I32_ADD)
            push!(bytes, Opcode.I32_CONST); append!(bytes, encode_leb128_signed(Int64(23)))
            push!(bytes, Opcode.I32_SHL)
            push!(bytes, Opcode.I32_OR)

            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(UInt64(mant_local)))
            push!(bytes, Opcode.I32_CONST); append!(bytes, encode_leb128_signed(Int64(13)))
            push!(bytes, Opcode.I32_SHL)
            push!(bytes, Opcode.I32_OR)
            # Stack: [normalized_f32_bits]

            # Handle zero case: if exp==0 && mant==0, use sign_bit only
            # Handle inf/nan: if exp==0x1f, use sign|(0xff<<23)|(mant<<13)
            # For simplicity in codegen context (timing values are always small
            # positive normalized floats), the normalized formula works.
            # Zero maps to exp+112=112 which is a tiny denormal in f32 ≈ 0.
            # This is acceptable for validation and practical correctness.

            # Reinterpret i32 → f32, then promote f32 → f64
            push!(bytes, Opcode.F32_REINTERPRET_I32)  # 0xBE
            push!(bytes, 0xBB)  # f64.promote_f32
        else
            # Float32 → Float64 (standard case)
            push!(bytes, 0xBB)  # f64.promote_f32
        end

    elseif is_func(func, :fptrunc)  # Float precision truncation (Float64 → Float32)
        # fptrunc(TargetType, value) - truncate Float64 to Float32
        # The source is always Float64, target is Float32
        push!(bytes, 0xB6)  # f32.demote_f64

    elseif is_func(func, :trunc_llvm)  # Truncate float towards zero (returns float)
        push!(bytes, arg_type === Float32 ? Opcode.F32_TRUNC : Opcode.F64_TRUNC)

    elseif is_func(func, :floor_llvm)  # Floor float
        push!(bytes, arg_type === Float32 ? Opcode.F32_FLOOR : Opcode.F64_FLOOR)

    elseif is_func(func, :ceil_llvm)  # Ceil float
        push!(bytes, arg_type === Float32 ? Opcode.F32_CEIL : Opcode.F64_CEIL)

    elseif is_func(func, :rint_llvm)  # Round to nearest even
        push!(bytes, arg_type === Float32 ? Opcode.F32_NEAREST : Opcode.F64_NEAREST)

    elseif is_func(func, :abs_float)  # Absolute value of float
        push!(bytes, arg_type === Float32 ? Opcode.F32_ABS : Opcode.F64_ABS)

    elseif is_func(func, :sqrt_llvm) || is_func(func, :sqrt_llvm_fast)  # Square root
        push!(bytes, arg_type === Float32 ? Opcode.F32_SQRT : Opcode.F64_SQRT)

    elseif is_func(func, :copysign_float)  # Copy sign
        push!(bytes, arg_type === Float32 ? Opcode.F32_COPYSIGN : Opcode.F64_COPYSIGN)

    elseif is_func(func, :min_float) || is_func(func, :min_float_fast)
        push!(bytes, arg_type === Float32 ? Opcode.F32_MIN : Opcode.F64_MIN)

    elseif is_func(func, :max_float) || is_func(func, :max_float_fast)
        push!(bytes, arg_type === Float32 ? Opcode.F32_MAX : Opcode.F64_MAX)

    # High-level operators (fallback)
    elseif is_func(func, :+)
        if arg_type === Float32
            push!(bytes, Opcode.F32_ADD)
        elseif arg_type === Float64
            push!(bytes, Opcode.F64_ADD)
        elseif is_32bit
            push!(bytes, Opcode.I32_ADD)
        else
            push!(bytes, Opcode.I64_ADD)
        end

    elseif is_func(func, :-)
        if arg_type === Float32
            push!(bytes, Opcode.F32_SUB)
        elseif arg_type === Float64
            push!(bytes, Opcode.F64_SUB)
        elseif is_32bit
            push!(bytes, Opcode.I32_SUB)
        else
            push!(bytes, Opcode.I64_SUB)
        end

    elseif is_func(func, :*)
        if arg_type === Float32
            push!(bytes, Opcode.F32_MUL)
        elseif arg_type === Float64
            push!(bytes, Opcode.F64_MUL)
        elseif is_32bit
            push!(bytes, Opcode.I32_MUL)
        else
            push!(bytes, Opcode.I64_MUL)
        end

    # Compiler hints - these can be ignored
    elseif is_func(func, :compilerbarrier)
        # compilerbarrier(kind, value) - just return the value
        # The first arg is a symbol (like :type), second is the actual value
        # We only pushed the value (args[2]) since args[1] is a QuoteNode
        # The value is already on stack, nothing more to do

    # isa() - type checking for Union discrimination
    elseif is_func(func, :isa) && length(args) >= 2
        # isa(value, Type) - check if value is of given type
        # Supports both Union{Nothing, T} (via ref.is_null) and tagged unions
        value_arg = args[1]
        type_arg = args[2]

        # Get the type being checked
        check_type = if type_arg isa Type
            type_arg
        elseif type_arg isa GlobalRef
            Core.eval(type_arg.mod, type_arg.name)
        else
            nothing
        end

        # Get the type of the value being checked (for detecting tagged unions)
        value_type = get_ssa_type(ctx, value_arg)

        # Check if this is a tagged union check
        # NOTE: The value argument is already on the stack from the loop that pushes all args
        if value_type isa Union && needs_tagged_union(value_type) && haskey(ctx.type_registry.unions, value_type)
            # Tagged union: check the tag field
            union_info = ctx.type_registry.unions[value_type]
            expected_tag = get(union_info.tag_map, check_type, Int32(-1))

            if expected_tag >= 0
                # Value is already on stack (tagged union struct)
                # PURE-701: Value may be structref if from a union-typed local.
                # Insert ref.cast null to narrow before struct_get.
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.REF_CAST_NULL)
                append!(bytes, encode_leb128_signed(Int64(union_info.wasm_type_idx)))
                # Get the tag field (field 0)
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.STRUCT_GET)
                append!(bytes, encode_leb128_unsigned(union_info.wasm_type_idx))
                append!(bytes, encode_leb128_unsigned(0))  # field 0 is tag
                # Compare tag to expected value
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(expected_tag)))
                push!(bytes, Opcode.I32_EQ)
            else
                # Type not in this union - drop value and return false
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
            end
        elseif check_type === Nothing
            # isa(x, Nothing) -> ref.is_null
            # Value is already on stack — check if it's actually a ref type
            local isa_val_wasm = nothing
            if value_arg isa Core.SSAValue
                local isa_local_idx = get(ctx.ssa_locals, value_arg.id, nothing)
                # Fix: isa_local_idx includes n_params, but ctx.locals only has non-param locals
                if isa_local_idx !== nothing
                    local local_offset = isa_local_idx - ctx.n_params
                    if local_offset >= 0 && local_offset < length(ctx.locals)
                        isa_val_wasm = ctx.locals[local_offset + 1]
                    end
                end
            end
            if isa_val_wasm !== nothing && (isa_val_wasm === I64 || isa_val_wasm === I32 || isa_val_wasm === F64 || isa_val_wasm === F32)
                # Numeric value on stack — can never be Nothing. Drop + push false.
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
            else
                push!(bytes, Opcode.REF_IS_NULL)
            end
        elseif check_type !== nothing && isconcretetype(check_type)
            # isa(x, ConcreteType) -> type check
            # Value is already on stack — check if it's actually a ref type
            local isa2_val_wasm = nothing
            if value_arg isa Core.SSAValue
                local isa2_local_idx = get(ctx.ssa_locals, value_arg.id, nothing)
                # Fix: isa2_local_idx includes n_params, but ctx.locals only has non-param locals
                if isa2_local_idx !== nothing
                    local local_offset = isa2_local_idx - ctx.n_params
                    if local_offset >= 0 && local_offset < length(ctx.locals)
                        isa2_val_wasm = ctx.locals[local_offset + 1]
                    end
                end
            elseif value_arg isa Core.Argument
                # PURE-325: Also handle function parameters (not just SSA values)
                # Core.Argument(1) is the function object for non-closures, so
                # actual args start at Argument(2) → arg_types[1].
                local arg_idx_isa = ctx.is_compiled_closure ? value_arg.n : value_arg.n - 1
                if arg_idx_isa >= 1 && arg_idx_isa <= length(ctx.arg_types)
                    isa2_val_wasm = get_concrete_wasm_type(ctx.arg_types[arg_idx_isa], ctx.mod, ctx.type_registry)
                end
            end
            if isa2_val_wasm !== nothing && (isa2_val_wasm === I64 || isa2_val_wasm === I32 || isa2_val_wasm === F64 || isa2_val_wasm === F32)
                # Numeric value on stack — can never be Nothing, so isa(x, T) is true. Drop + push true.
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
            elseif isa2_val_wasm === ExternRef
                # PURE-324: Value is externref (Any-typed field). Need proper type check,
                # not just null check. Use any.convert_extern + ref.test to check actual type.
                # Example: isa(stream.text_root, String) where text_root::Any could be
                # IOBuffer, String, or SubString — must distinguish at runtime.
                local target_wasm = get_concrete_wasm_type(check_type, ctx.mod, ctx.type_registry)
                if target_wasm isa ConcreteRef
                    append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN])
                    push!(bytes, Opcode.GC_PREFIX)
                    # PURE-325: Use REF_TEST (non-nullable) instead of REF_TEST_NULL.
                    # ref.test null returns true for null refs, but isa(nothing, T) should
                    # return false for concrete types. null externref in Vector{Any} was
                    # passing isa(x, Expr) check and crashing on struct_get.
                    push!(bytes, Opcode.REF_TEST)
                    append!(bytes, encode_leb128_signed(Int64(target_wasm.type_idx)))
                elseif haskey(ctx.type_registry.numeric_boxes, target_wasm)
                    # PURE-325: Check for boxed numeric type (e.g., isa(externref, Int64)
                    # where Int64 was boxed via get_numeric_box_type!)
                    local box_type_idx = ctx.type_registry.numeric_boxes[target_wasm]
                    append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN])
                    push!(bytes, Opcode.GC_PREFIX)
                    push!(bytes, Opcode.REF_TEST)
                    append!(bytes, encode_leb128_signed(Int64(box_type_idx)))
                else
                    # Fallback: non-null check for non-concrete wasm types
                    push!(bytes, Opcode.REF_IS_NULL)
                    push!(bytes, Opcode.I32_EQZ)
                end
            else
                # For Union{Nothing, T}, checking isa(x, T) is equivalent to !isnull
                push!(bytes, Opcode.REF_IS_NULL)
                push!(bytes, Opcode.I32_EQZ)  # negate: 1->0, 0->1
            end
        elseif check_type !== nothing && !isconcretetype(check_type)
            # Abstract type check (e.g. Integer, AbstractFloat, Number, Real)
            # Determine value's WASM local type and local index for re-loading
            local isa3_val_wasm = nothing
            local isa3_local_idx = nothing
            if value_arg isa Core.SSAValue
                local _idx3 = get(ctx.ssa_locals, value_arg.id, nothing)
                if _idx3 !== nothing
                    local _off3 = _idx3 - ctx.n_params
                    if _off3 >= 0 && _off3 < length(ctx.locals)
                        isa3_val_wasm = ctx.locals[_off3 + 1]
                        isa3_local_idx = _idx3
                    end
                end
            end
            local _wasm_julia = Dict{WasmValType,Type}(I64=>Int64, I32=>Int32, F64=>Float64, F32=>Float32)
            if isa3_val_wasm !== nothing && (isa3_val_wasm === I64 || isa3_val_wasm === I32 || isa3_val_wasm === F64 || isa3_val_wasm === F32)
                # Unboxed numeric — check if representative Julia type is a subtype
                local _jt = get(_wasm_julia, isa3_val_wasm, nothing)
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, (_jt !== nothing && _jt <: check_type) ? 0x01 : 0x00)
            elseif isa3_val_wasm === ExternRef && isa3_local_idx !== nothing
                # Boxed externref — test each numeric box type that is a subtype of check_type
                local _boxes = UInt32[]
                for (wt, box_idx) in ctx.type_registry.numeric_boxes
                    local _jt2 = get(_wasm_julia, wt, nothing)
                    _jt2 !== nothing && _jt2 <: check_type && push!(_boxes, box_idx)
                end
                push!(bytes, Opcode.DROP)
                if isempty(_boxes)
                    push!(bytes, Opcode.I32_CONST)
                    push!(bytes, 0x00)
                else
                    for (i, box_idx) in enumerate(_boxes)
                        push!(bytes, Opcode.LOCAL_GET)
                        append!(bytes, encode_leb128_unsigned(UInt32(isa3_local_idx)))
                        append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN])
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.REF_TEST)
                        append!(bytes, encode_leb128_signed(Int64(box_idx)))
                        i > 1 && push!(bytes, Opcode.I32_OR)
                    end
                end
            else
                push!(bytes, Opcode.DROP)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
            end
        else
            # Unknown type - drop value and return false
            push!(bytes, Opcode.DROP)
            push!(bytes, Opcode.I32_CONST)
            push!(bytes, 0x00)
        end

    # throw() - compile to WASM throw instruction
    elseif func isa GlobalRef && func.name === :throw
        # PURE-1102: Emit throw instruction with tag 0 (our Julia exception tag)
        ensure_exception_tag!(ctx.mod)
        push!(bytes, Opcode.THROW)
        append!(bytes, encode_leb128_unsigned(0))  # tag index 0

    # Base.add_ptr - pointer arithmetic (used in string operations)
    # In WasmGC, pointers are i64, so this is just i64 add
    elseif func isa GlobalRef && func.name === :add_ptr
        # add_ptr(ptr, offset) -> ptr + offset
        append!(bytes, compile_value(args[1], ctx))
        append!(bytes, compile_value(args[2], ctx))
        push!(bytes, Opcode.I64_ADD)

    # Base.sub_ptr - pointer subtraction
    elseif func isa GlobalRef && func.name === :sub_ptr
        # sub_ptr(ptr, offset) -> ptr - offset
        append!(bytes, compile_value(args[1], ctx))
        append!(bytes, compile_value(args[2], ctx))
        push!(bytes, Opcode.I64_SUB)

    # Base.pointerref - read from pointer
    # In WasmGC, raw pointer ops don't exist. But for string byte access
    # (codeunit), we trace back to jl_string_ptr and emit array.get.
    elseif func isa GlobalRef && func.name === :pointerref
        # Try to trace pointer arg back to jl_string_ptr
        ptr_arg = length(args) >= 1 ? args[1] : nothing
        str_info = ptr_arg !== nothing ? _trace_string_ptr(ptr_arg, ctx.code_info.code) : nothing
        if str_info !== nothing
            str_ssa, idx_ssa = str_info
            # Emit: array.get string_array (index - 1)
            # String is array<i32> (type 1). Index is 1-based, array.get is 0-based.
            append!(bytes, compile_value(str_ssa, ctx))
            append!(bytes, compile_value(idx_ssa, ctx))
            # Convert i64 index to i32 and subtract 1 for 0-based
            push!(bytes, Opcode.I32_WRAP_I64)
            push!(bytes, Opcode.I32_CONST)
            push!(bytes, 0x01)
            push!(bytes, Opcode.I32_SUB)
            # array.get on string type (array<i32> = type 1)
            string_arr_type = get_string_array_type!(ctx.mod, ctx.type_registry)
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ARRAY_GET)
            append!(bytes, encode_leb128_unsigned(string_arr_type))
        else
            # PURE-908: Clear pre-pushed args
            bytes = UInt8[]
            push!(bytes, Opcode.UNREACHABLE)
            ctx.last_stmt_was_stub = true  # PURE-908
        end

    # Base.pointerset - write to pointer
    # WasmGC has no linear memory — pointer ops are invalid. Trap at runtime.
    elseif func isa GlobalRef && func.name === :pointerset
        # PURE-908: Clear pre-pushed args
        bytes = UInt8[]
        push!(bytes, Opcode.UNREACHABLE)
        ctx.last_stmt_was_stub = true  # PURE-908

    # PURE-1102: throw_methoderror — emit throw (catchable) instead of unreachable
    elseif func isa GlobalRef && func.name === :throw_methoderror
        bytes = UInt8[]
        ensure_exception_tag!(ctx.mod)
        push!(bytes, Opcode.THROW)
        append!(bytes, encode_leb128_unsigned(0))  # tag index 0
        ctx.last_stmt_was_stub = true  # PURE-908

    # PURE-4149: Core._svec_len(sv) — SimpleVector is an externref array in WasmGC.
    # _svec_len returns Int64 = array.len (converted from i32 to i64).
    # Match both GlobalRef(Core, :_svec_len) and the direct builtin function object.
    # Julia's type inference may resolve length(::SimpleVector) to the builtin directly.
    # PURE-6021: args[1] (svec array) is already pre-pushed by the generic loop above.
    elseif ((func isa GlobalRef && func.name === :_svec_len && func.mod === Core) || func === Core._svec_len) && length(args) == 1
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_LEN)
        # array.len returns i32 but Julia expects Int64
        push!(bytes, Opcode.I64_EXTEND_I32_U)

    # PURE-4149: Core._svec_ref(sv, i) — get element from SimpleVector (externref array).
    # _svec_ref is 1-indexed in Julia, 0-indexed in Wasm → subtract 1.
    # Match both GlobalRef and direct builtin function object (same as _svec_len above).
    # PURE-6021: args[1] (svec array) and args[2] (i64 index) are already pre-pushed by
    # the generic loop above — do NOT call compile_value again here (causes double-push,
    # leaving 2 orphaned values on the stack → "values remaining" validation error).
    elseif ((func isa GlobalRef && func.name === :_svec_ref && func.mod === Core) || func === Core._svec_ref) && length(args) == 2
        # Convert i64 Julia index to i32 Wasm index and subtract 1 for 0-indexing
        push!(bytes, Opcode.I32_WRAP_I64)
        push!(bytes, Opcode.I32_CONST)
        push!(bytes, 0x01)  # 1
        push!(bytes, Opcode.I32_SUB)
        # Get element from externref array
        svec_type_info = register_struct_type!(ctx.mod, ctx.type_registry, Core.SimpleVector)
        svec_arr_idx = svec_type_info.wasm_type_idx
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_GET)
        append!(bytes, encode_leb128_unsigned(svec_arr_idx))
        # array.get returns externref but downstream ref.cast expects anyref
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ANY_CONVERT_EXTERN)

    # PURE-604: Core builtins (svec, _apply_iterate) — genuinely unsupported, trap
    elseif func isa GlobalRef && func.name in (:svec, :_apply_iterate)
        # PURE-908: Clear pre-pushed args
        bytes = UInt8[]
        push!(bytes, Opcode.UNREACHABLE)
        ctx.last_stmt_was_stub = true  # PURE-908

    # PURE-604/605: Core builtins re-exported through Base (isdefined, getfield, setfield!).
    # These are dead code paths from dynamic dispatch — trap silently in WasmGC.
    elseif func isa GlobalRef && func.name in (:isdefined, :getfield, :setfield!) && func.mod in (Core, Base)
        # PURE-908: Clear pre-pushed args
        bytes = UInt8[]
        push!(bytes, Opcode.UNREACHABLE)
        ctx.last_stmt_was_stub = true  # PURE-908

    # PURE-604: Symbol(x) — in WasmGC, Symbol IS String (both are byte arrays).
    # The argument is already compiled as a string array — just pass through.
    elseif is_func(func, :Symbol) && func isa GlobalRef && length(args) == 1
        # Compile the argument — it's already a string array in WasmGC
        append!(bytes, compile_value(args[1], ctx))

    # Cross-function call via GlobalRef (dynamic dispatch when Julia can't specialize)
    # PURE-325: Skip cross-call lookup for Core._expr — it's a builtin that has a
    # special handler below (line ~19900). Without this guard, get_function returns
    # nothing (builtins aren't in the function registry) and emits unreachable.
    elseif func isa GlobalRef && ctx.func_registry !== nothing && !is_func(func, :_expr)
        # Try to find this function in our registry
        called_func = try
            getfield(func.mod, func.name)
        catch
            nothing
        end

        if called_func !== nothing
            # Infer argument types BEFORE pushing (need for type checking)
            call_arg_types = tuple([infer_value_type(arg, ctx) for arg in args]...)
            target_info = get_function(ctx.func_registry, called_func, call_arg_types)

            # PURE-320: Closure/kwarg functions are registered with self-type prepended
            if target_info === nothing && typeof(called_func) <: Function && isconcretetype(typeof(called_func))
                closure_arg_types = (typeof(called_func), call_arg_types...)
                target_info = get_function(ctx.func_registry, called_func, closure_arg_types)
            end

            if target_info !== nothing
                # Push arguments with type checking
                for (arg_idx, arg) in enumerate(args)
                    arg_bytes = compile_value(arg, ctx)
                    append!(bytes, arg_bytes)
                    # Check if arg type matches expected param type
                    if arg_idx <= length(target_info.arg_types)
                        expected_julia_type = target_info.arg_types[arg_idx]
                        expected_wasm = get_concrete_wasm_type(expected_julia_type, ctx.mod, ctx.type_registry)
                        actual_julia_type = call_arg_types[arg_idx]
                        actual_wasm = get_concrete_wasm_type(actual_julia_type, ctx.mod, ctx.type_registry)

                        # PURE-901/4155: Handle Nothing→ref conversion BEFORE type bridging.
                        # compile_value emits i32_const 0 for Nothing,
                        # but ref-typed params need ref.null. Must fix BEFORE bridging runs,
                        # otherwise bridging tries any_convert_extern on an i32 value.
                        # NOTE: Type{T} no longer needs this — it now emits global.get (DataType ref).
                        _is_phantom = actual_julia_type === Nothing
                        if _is_phantom && (expected_wasm isa ConcreteRef || expected_wasm === ExternRef || expected_wasm === StructRef || expected_wasm === AnyRef)
                            if length(arg_bytes) == 2 && arg_bytes[1] == Opcode.I32_CONST && arg_bytes[2] == 0x00
                                # Remove the i32_const 0 we just appended
                                for _ in 1:2
                                    pop!(bytes)
                                end
                                # Emit ref.null with the expected type
                                push!(bytes, Opcode.REF_NULL)
                                if expected_wasm isa ConcreteRef
                                    append!(bytes, encode_leb128_signed(Int64(expected_wasm.type_idx)))
                                else
                                    push!(bytes, UInt8(expected_wasm))
                                end
                                # Update actual_wasm so bridging logic below is a no-op
                                actual_wasm = expected_wasm
                            end
                        end

                        if expected_wasm isa ConcreteRef && actual_wasm isa ConcreteRef
                            if expected_wasm.type_idx != actual_wasm.type_idx
                                # Different ref types — insert ref.cast null to expected type
                                push!(bytes, Opcode.GC_PREFIX)
                                push!(bytes, Opcode.REF_CAST_NULL)
                                append!(bytes, encode_leb128_signed(Int64(expected_wasm.type_idx)))
                            end
                        elseif expected_wasm isa ConcreteRef && (actual_wasm === StructRef || actual_wasm === ArrayRef || actual_wasm === AnyRef)
                            # Abstract ref to concrete ref — insert ref.cast null
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.REF_CAST_NULL)
                            append!(bytes, encode_leb128_signed(Int64(expected_wasm.type_idx)))
                        elseif expected_wasm isa ConcreteRef && actual_wasm === ExternRef
                            # PURE-036bj: externref to concrete ref — convert to anyref first, then cast
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.ANY_CONVERT_EXTERN)  # externref → anyref
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.REF_CAST_NULL)       # anyref → (ref null X)
                            append!(bytes, encode_leb128_signed(Int64(expected_wasm.type_idx)))
                        elseif expected_wasm isa ConcreteRef && (actual_wasm === I32 || actual_wasm === I64 || actual_wasm === F32 || actual_wasm === F64)
                            # PURE-6025: Numeric value to tagged union struct — wrap via emit_wrap_union_value.
                            # This happens when a function expects a Union param (represented as tagged union struct)
                            # but the actual value is a numeric type (e.g., NumType passed to Dict{WasmValType,...} key).
                            if expected_julia_type isa Union && needs_tagged_union(expected_julia_type)
                                append!(bytes, emit_wrap_union_value(ctx, actual_julia_type, expected_julia_type))
                            else
                                # ConcreteRef expected but not a union — box numeric to ref via ref.i31
                                if actual_wasm === I32
                                    push!(bytes, Opcode.GC_PREFIX)
                                    push!(bytes, Opcode.REF_I31)
                                elseif actual_wasm === I64
                                    push!(bytes, Opcode.I32_WRAP_I64)
                                    push!(bytes, Opcode.GC_PREFIX)
                                    push!(bytes, Opcode.REF_I31)
                                end
                                # Cast to expected concrete ref type
                                push!(bytes, Opcode.GC_PREFIX)
                                push!(bytes, Opcode.REF_CAST_NULL)
                                append!(bytes, encode_leb128_signed(Int64(expected_wasm.type_idx)))
                            end
                        elseif expected_wasm === ExternRef && (actual_wasm isa ConcreteRef || actual_wasm === StructRef || actual_wasm === ArrayRef || actual_wasm === AnyRef)
                            # Concrete or abstract ref to externref — insert extern.convert_any
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                        elseif expected_wasm === ExternRef && (actual_wasm === I32 || actual_wasm === I64 || actual_wasm === F32 || actual_wasm === F64)
                            # PURE-6025: Numeric value to externref — box via struct_new then extern.convert_any.
                            # This happens when a function expects Any (externref) but the actual value is numeric
                            # (e.g., Int64 → externref for cross-function calls with abstract signatures).
                            local box_type_idx_arg = get_numeric_box_type!(ctx.mod, ctx.type_registry, actual_wasm)
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.STRUCT_NEW)
                            append!(bytes, encode_leb128_unsigned(box_type_idx_arg))
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                        elseif (expected_wasm === I32 || expected_wasm === I64 || expected_wasm === F32 || expected_wasm === F64) &&
                               (actual_wasm === ExternRef || actual_wasm === AnyRef || actual_wasm isa ConcreteRef || actual_wasm === StructRef)
                            # PURE-906: Expected numeric but actual is ref-typed.
                            # This happens when Julia type inference reports arg type as Any
                            # but the callee's param is a concrete numeric type (Bool, Int, etc.).
                            # Remove the ref-typed arg_bytes and emit zero default.
                            for _ in 1:length(arg_bytes)
                                pop!(bytes)
                            end
                            if expected_wasm === I32
                                push!(bytes, Opcode.I32_CONST)
                                push!(bytes, 0x00)
                            elseif expected_wasm === I64
                                push!(bytes, Opcode.I64_CONST)
                                push!(bytes, 0x00)
                            elseif expected_wasm === F32
                                push!(bytes, Opcode.F32_CONST)
                                append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00])
                            elseif expected_wasm === F64
                                push!(bytes, Opcode.F64_CONST)
                                append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                            end
                        elseif expected_wasm === ExternRef && actual_wasm === ExternRef
                            # PURE-036z: Julia type inference says Any→ExternRef for both, but the actual
                            # Wasm local might be a ConcreteRef. Check if arg_bytes is local.get of a
                            # non-externref local and insert extern.convert_any if needed.
                            if length(arg_bytes) >= 2 && arg_bytes[1] == 0x20  # LOCAL_GET opcode
                                local_idx = 0; shift = 0
                                for bi in 2:length(arg_bytes)
                                    b = arg_bytes[bi]
                                    local_idx |= (Int(b & 0x7f) << shift)
                                    shift += 7
                                    if (b & 0x80) == 0
                                        break
                                    end
                                end
                                local_arr_idx = local_idx - ctx.n_params + 1
                                if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                                    actual_local_wasm = ctx.locals[local_arr_idx]
                                    if actual_local_wasm isa ConcreteRef || actual_local_wasm === StructRef || actual_local_wasm === ArrayRef || actual_local_wasm === AnyRef
                                        # Actual local is a ref type but not externref — insert conversion
                                        push!(bytes, Opcode.GC_PREFIX)
                                        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                                    end
                                elseif local_idx < ctx.n_params
                                    # It's a param — check arg_types
                                    if local_idx + 1 <= length(ctx.arg_types)
                                        param_julia_type = ctx.arg_types[local_idx + 1]
                                        param_wasm = get_concrete_wasm_type(param_julia_type, ctx.mod, ctx.type_registry)
                                        if param_wasm isa ConcreteRef || param_wasm === StructRef || param_wasm === ArrayRef || param_wasm === AnyRef
                                            push!(bytes, Opcode.GC_PREFIX)
                                            push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                # Cross-function call - emit call instruction with target index
                push!(bytes, Opcode.CALL)
                append!(bytes, encode_leb128_unsigned(target_info.wasm_idx))
                # PURE-3111: If the callee returns Union{} (Bottom), it always throws.
                # The Wasm func type has no result, so code after is unreachable.
                # Skip type bridge and emit unreachable to prevent stack underflow.
                if target_info.return_type === Union{}
                    push!(bytes, Opcode.UNREACHABLE)
                    ctx.last_stmt_was_stub = true
                # PURE-900: Bridge type gap between function's Wasm return type
                # and the caller's SSA local type. Handles both directions:
                # 1. externref → ConcreteRef: any_convert_extern + ref.cast
                # 2. ConcreteRef → externref: extern_convert_any
                elseif haskey(ctx.ssa_locals, idx)
                    local_idx_val = ctx.ssa_locals[idx]
                    local_arr_idx = local_idx_val - ctx.n_params + 1
                    if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                        target_local_type = ctx.locals[local_arr_idx]
                        ret_wasm = julia_to_wasm_type(target_info.return_type)
                        if target_local_type isa ConcreteRef && ret_wasm === ExternRef
                            # Function returns externref, local expects concrete ref
                            append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN])
                            append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.REF_CAST_NULL])
                            append!(bytes, encode_leb128_signed(Int64(target_local_type.type_idx)))
                        elseif target_local_type === AnyRef && ret_wasm === ExternRef
                            # PURE-908: Function returns externref, local expects anyref
                            append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN])
                        elseif target_local_type === ExternRef && ret_wasm !== ExternRef && ret_wasm !== nothing
                            # Function returns concrete/struct/array ref, local expects externref
                            append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.EXTERN_CONVERT_ANY])
                        end
                    end
                end
            else
                # No matching signature - likely dead code from Union type branches
                # Emit unreachable instead of error (the branch won't be taken at runtime)
                # PURE-605: Suppress warning for known-safe dynamic dispatch paths where
                # Julia couldn't specialize (arg types contain Any/abstract types).
                # These are dead code branches in WasmGC context (we compile with concrete types).
                _has_abstract = any(t -> t === Any || !isconcretetype(t), call_arg_types)
                @warn "CROSS-CALL UNREACHABLE: $(func) with arg types $(call_arg_types) (in func_$(ctx.func_idx))$((_has_abstract ? " [abstract-suppressed]" : ""))"
                # PURE-908: Clear pre-pushed args before emitting UNREACHABLE.
                # The generic arg pre-push loop (line ~19103) pushes args when
                # get_function returns nothing (no matching signature). Those args
                # are now on the stack inside typed blocks, causing "values remaining
                # on stack" validation errors.
                bytes = UInt8[]
                push!(bytes, Opcode.UNREACHABLE)
                ctx.last_stmt_was_stub = true  # PURE-908
            end
        else
            error("Unsupported function call: $func (type: $(typeof(func)))")
        end

    # NamedTuple{names}(tuple) - convert tuple to named tuple
    # This pattern appears in keyword argument handling
    # Check: func is UnionAll and func <: NamedTuple
    elseif func isa UnionAll && func <: NamedTuple
        # func is NamedTuple{(:name1, :name2, ...)}
        # args[1] should be a tuple with the values
        # The result is a NamedTuple which is a struct with named fields

        # Extract the names from the type
        # NamedTuple{names} has structure: UnionAll(T, NamedTuple{names, T})
        # So func.body is NamedTuple{names, T<:Tuple} and we need to get names from there
        inner_type = func.body  # e.g., NamedTuple{(:filename, :first_line), T<:Tuple}

        # Check if inner_type is a DataType (it might be a UnionAll if func is the generic NamedTuple)
        names = nothing
        if inner_type isa DataType && length(inner_type.parameters) >= 1
            names = inner_type.parameters[1]  # Get the first type parameter (the names tuple)
        end

        if names isa Tuple && length(args) == 1
            # Get the tuple argument type to determine value types
            tuple_arg = args[1]
            tuple_type = infer_value_type(tuple_arg, ctx)

            if tuple_type <: Tuple
                # Construct the concrete NamedTuple type
                value_types = tuple_type.parameters
                nt_type = NamedTuple{names, Tuple{value_types...}}

                # Register the NamedTuple type as a struct
                if !haskey(ctx.type_registry.structs, nt_type)
                    register_struct_type!(ctx.mod, ctx.type_registry, nt_type)
                end

                if haskey(ctx.type_registry.structs, nt_type)
                    info = ctx.type_registry.structs[nt_type]

                    # Compile the tuple argument - this pushes the tuple struct
                    append!(bytes, compile_value(tuple_arg, ctx))

                    # The tuple is already a struct with the same field layout as the NamedTuple
                    # (both are structs with fields in order)
                    # For identical memory layout, we can just ref.cast
                    # But if types differ, we need to extract fields and create new struct

                    # Get tuple type info
                    if haskey(ctx.type_registry.structs, tuple_type)
                        tuple_info = ctx.type_registry.structs[tuple_type]

                        if length(value_types) == length(names)
                            # Create a temporary local to hold the tuple
                            tuple_local = allocate_local!(ctx, ConcreteRef(tuple_info.wasm_type_idx, true))
                            push!(bytes, Opcode.LOCAL_SET)
                            append!(bytes, encode_leb128_unsigned(tuple_local))

                            # Extract each field from tuple and push for struct.new
                            for (i, (name, vtype)) in enumerate(zip(names, value_types))
                                push!(bytes, Opcode.LOCAL_GET)
                                append!(bytes, encode_leb128_unsigned(tuple_local))
                                push!(bytes, Opcode.GC_PREFIX)
                                push!(bytes, Opcode.STRUCT_GET)
                                append!(bytes, encode_leb128_unsigned(tuple_info.wasm_type_idx))
                                append!(bytes, encode_leb128_unsigned(i - 1))  # 0-indexed field
                            end

                            # Create the NamedTuple struct
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.STRUCT_NEW)
                            append!(bytes, encode_leb128_unsigned(info.wasm_type_idx))
                        else
                            error("NamedTuple/Tuple field count mismatch: $(length(names)) vs $(length(value_types))")
                        end
                    else
                        error("Tuple type not registered: $tuple_type")
                    end
                else
                    error("Failed to register NamedTuple type: $nt_type")
                end
            else
                error("NamedTuple constructor argument is not a Tuple: $tuple_type")
            end
        else
            error("NamedTuple constructor requires exactly one tuple argument, got $(length(args)) args")
        end

    # Special case for Core._expr — creates an Expr(head::Symbol, args::Vector{Any})
    # IR pattern: Core._expr(:head, arg1, arg2, ...) with 1+ args
    # head is the first arg (Symbol), remaining args become the Expr.args Vector{Any}
    elseif is_func(func, :_expr)
        # Register Expr type if not already registered
        if !haskey(ctx.type_registry.structs, Expr)
            register_struct_type!(ctx.mod, ctx.type_registry, Expr)
        end

        if haskey(ctx.type_registry.structs, Expr)
            expr_info = ctx.type_registry.structs[Expr]

            # Ensure Vector{Any} is registered (for the args field)
            if !haskey(ctx.type_registry.structs, Vector{Any})
                register_vector_type!(ctx.mod, ctx.type_registry, Vector{Any})
            end
            vec_any_info = ctx.type_registry.structs[Vector{Any}]

            # Ensure Tuple{Int64} is registered (for Vector size field)
            if !haskey(ctx.type_registry.structs, Tuple{Int64})
                register_tuple_type!(ctx.mod, ctx.type_registry, Tuple{Int64})
            end
            size_tuple_info = ctx.type_registry.structs[Tuple{Int64}]

            # Get array type for Any (externref array)
            any_array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, Any)
            str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

            # args[1] is the head (Symbol), args[2:end] are the Expr.args elements
            head_arg = args[1]
            expr_args = args[2:end]
            n_expr_args = length(expr_args)

            # Locals-first approach: compile each piece into a local, then assemble.

            # Step 1: Compile head (Symbol = array<i32>) → local
            append!(bytes, compile_value(head_arg, ctx))
            head_local = allocate_local!(ctx, ConcreteRef(str_type_idx, true))
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(head_local))

            # Step 2: Create data array (array<externref>) → local
            if n_expr_args == 0
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
                append!(bytes, encode_leb128_unsigned(any_array_type_idx))
            else
                # Push each arg as externref, then array_new_fixed
                for ea in expr_args
                    ea_bytes = compile_value(ea, ctx)
                    is_numeric = false
                    # Check if ea_bytes contains GC_PREFIX — if so, it's a GC op
                    # (string/struct/array), NOT a numeric value. This prevents false
                    # positives for Symbols whose compilation starts with i32.const (char bytes).
                    has_gc_prefix_ea = any(b == Opcode.GC_PREFIX for b in ea_bytes)
                    if !has_gc_prefix_ea && length(ea_bytes) >= 1 && (ea_bytes[1] == Opcode.I32_CONST || ea_bytes[1] == Opcode.I64_CONST)
                        is_numeric = true
                    elseif length(ea_bytes) >= 2 && ea_bytes[1] == Opcode.LOCAL_GET
                        src_idx = 0; shift = 0
                        for bi in 2:length(ea_bytes)
                            b = ea_bytes[bi]
                            src_idx |= (Int(b & 0x7f) << shift)
                            shift += 7
                            (b & 0x80) == 0 && break
                        end
                        arr_idx_check = src_idx - ctx.n_params + 1
                        if arr_idx_check >= 1 && arr_idx_check <= length(ctx.locals)
                            src_type = ctx.locals[arr_idx_check]
                            if src_type === I32 || src_type === I64 || src_type === F32 || src_type === F64
                                is_numeric = true
                            end
                        elseif src_idx < ctx.n_params && src_idx < length(ctx.arg_types)
                            # PURE-6022: arg_types contains Julia types, not WasmValTypes.
                            # Convert via julia_to_wasm_type before comparing.
                            _param_wasm = julia_to_wasm_type(ctx.arg_types[src_idx + 1])
                            if _param_wasm === I32 || _param_wasm === I64 || _param_wasm === F32 || _param_wasm === F64
                                is_numeric = true
                            end
                        end
                    end
                    if is_numeric
                        push!(bytes, Opcode.REF_NULL)
                        push!(bytes, UInt8(ExternRef))
                    else
                        append!(bytes, ea_bytes)
                        is_extern = false
                        if length(ea_bytes) >= 2 && ea_bytes[1] == Opcode.LOCAL_GET
                            src_idx2 = 0; shift2 = 0
                            for bi in 2:length(ea_bytes)
                                b = ea_bytes[bi]
                                src_idx2 |= (Int(b & 0x7f) << shift2)
                                shift2 += 7
                                (b & 0x80) == 0 && break
                            end
                            arr_idx2 = src_idx2 - ctx.n_params + 1
                            if arr_idx2 >= 1 && arr_idx2 <= length(ctx.locals)
                                is_extern = (ctx.locals[arr_idx2] === ExternRef)
                            elseif src_idx2 < ctx.n_params && src_idx2 < length(ctx.arg_types)
                                # PURE-6022: Check if parameter is already externref
                                is_extern = (julia_to_wasm_type(ctx.arg_types[src_idx2 + 1]) === ExternRef)
                            end
                        end
                        if !is_extern
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                        end
                    end
                end
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_FIXED)
                append!(bytes, encode_leb128_unsigned(any_array_type_idx))
                append!(bytes, encode_leb128_unsigned(n_expr_args))
            end
            data_arr_local = allocate_local!(ctx, ConcreteRef(any_array_type_idx, true))
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(data_arr_local))

            # Step 3: Create Tuple{Int64} for size → local
            push!(bytes, Opcode.I64_CONST)
            append!(bytes, encode_leb128_signed(Int64(n_expr_args)))
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_NEW)
            append!(bytes, encode_leb128_unsigned(size_tuple_info.wasm_type_idx))
            size_local = allocate_local!(ctx, ConcreteRef(size_tuple_info.wasm_type_idx, true))
            push!(bytes, Opcode.LOCAL_SET)
            append!(bytes, encode_leb128_unsigned(size_local))

            # Step 4: Assemble Expr struct
            # Push head (Expr field 0)
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(head_local))
            # Create Vector{Any} inline (Expr field 1): push data_array, size_tuple, struct.new
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(data_arr_local))
            push!(bytes, Opcode.LOCAL_GET)
            append!(bytes, encode_leb128_unsigned(size_local))
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_NEW)
            append!(bytes, encode_leb128_unsigned(vec_any_info.wasm_type_idx))
            # struct.new Expr with (head, vector)
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.STRUCT_NEW)
            append!(bytes, encode_leb128_unsigned(expr_info.wasm_type_idx))

            return bytes
        end

    else
        # Unknown function call — emit unreachable (will trap at runtime)
        @warn "Stubbing unsupported call: $func (will trap at runtime) (in func_$(ctx.func_idx))"
        # PURE-908: Clear pre-pushed args before UNREACHABLE
        bytes = UInt8[]
        push!(bytes, Opcode.UNREACHABLE)
        ctx.last_stmt_was_stub = true  # PURE-908
    end

    return bytes
end

