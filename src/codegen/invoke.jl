"""
Compile an invoke expression (method invocation).
"""
function compile_invoke(expr::Expr, idx::Int, ctx::CompilationContext)::Vector{UInt8}
    bytes = UInt8[]
    args = expr.args[3:end]


    # Check for signal substitution (Therapy.jl closures)
    # When calling through a captured signal getter/setter, emit global.get/set directly
    func_ref = expr.args[2]
    if func_ref isa Core.SSAValue
        ssa_id = func_ref.id
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

    # Get MethodInstance to check parameter types for nothing arguments
    mi_or_ci = expr.args[1]
    mi = if mi_or_ci isa Core.MethodInstance
        mi_or_ci
    elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
        mi_or_ci.def
    else
        nothing
    end

    # Early self-call detection: check if this is a recursive call to ourselves
    func_ref_early = expr.args[2]
    actual_func_ref_early = func_ref_early
    if func_ref_early isa Core.SSAValue
        ssa_stmt = ctx.code_info.code[func_ref_early.id]
        if ssa_stmt isa GlobalRef
            actual_func_ref_early = ssa_stmt
        elseif ssa_stmt isa Core.PiNode && ssa_stmt.val isa Core.SSAValue
            # Follow PiNode chain
            pi_ssa_stmt = ctx.code_info.code[ssa_stmt.val.id]
            if pi_ssa_stmt isa GlobalRef
                actual_func_ref_early = pi_ssa_stmt
            end
        elseif ssa_stmt isa Expr && ssa_stmt.head === :invoke
            # Nested invoke — try to get the function from the method instance
            nested_mi = ssa_stmt.args[1]
            if nested_mi isa Core.MethodInstance
                # Can't easily get GlobalRef from MI, but we can try to use the function name
                if hasfield(typeof(nested_mi.def), :name) && nested_mi.def isa Method
                    # Create a synthetic GlobalRef for lookup
                    # This is a workaround; the proper way would be to use mi directly
                end
            end
        end
    elseif func_ref_early isa Core.PiNode && func_ref_early.val isa GlobalRef
        actual_func_ref_early = func_ref_early.val
    elseif func_ref_early isa Core.PiNode && func_ref_early.val isa Core.SSAValue
        pi_ssa_stmt = ctx.code_info.code[func_ref_early.val.id]
        if pi_ssa_stmt isa GlobalRef
            actual_func_ref_early = pi_ssa_stmt
        end
    elseif func_ref_early isa Core.Argument
        # PURE-220: Higher-order function calls — extract function from mi.specTypes
        if mi isa Core.MethodInstance
            spec = mi.specTypes
            if spec isa DataType && spec <: Tuple && length(spec.parameters) >= 1
                func_type = spec.parameters[1]
                if func_type isa DataType
                    try
                        actual_func_ref_early = func_type.instance
                    catch; end
                end
            end
        end
    end
    is_self_call_early = false
    if ctx.func_ref !== nothing && actual_func_ref_early isa GlobalRef
        try
            called_func = getfield(actual_func_ref_early.mod, actual_func_ref_early.name)
            if called_func === ctx.func_ref
                # PURE-220: Also check arity — overloaded methods share the same function
                # object but have different specTypes. A call to a different overload is NOT
                # a self-call (e.g., parse_comma(ps) calling parse_comma(ps, true)).
                if mi isa Core.MethodInstance
                    spec = mi.specTypes
                    if spec isa DataType && spec <: Tuple
                        call_nargs = length(spec.parameters) - 1  # subtract typeof(func)
                        # PURE-047: Check both arity AND parameter types — same-arity overloads
                        # (e.g., validate_code!(errors, mi, c) vs validate_code!(errors, c, bool))
                        # share the function object and arity but have different specTypes.
                        if call_nargs == length(ctx.arg_types)
                            call_arg_types = spec.parameters[2:end]
                            is_self_call_early = all(call_arg_types[i] <: ctx.arg_types[i] for i in 1:call_nargs)
                        else
                            is_self_call_early = false
                        end
                    else
                        is_self_call_early = true
                    end
                else
                    is_self_call_early = true
                end
            end
        catch
            is_self_call_early = false
        end
    end

    # Get parameter types - for self-calls, use ctx.arg_types (the function's compiled signature)
    # For other calls, use mi.specTypes (the call site's specialized types)
    param_types = nothing
    if is_self_call_early
        # Self-call: use the function's actual compiled parameter types
        param_types = ctx.arg_types
    elseif mi isa Core.MethodInstance
        spec = mi.specTypes
        if spec isa DataType && spec <: Tuple
            # specTypes is Tuple{typeof(func), arg1_type, arg2_type, ...}
            # We want arg types starting from index 2
            param_types = spec.parameters[2:end]
        end
    end

    # PURE-036z: Compute target_info EARLY so we can use its arg_types for proper type checking
    # during argument compilation. This helps when param_types (from mi.specTypes) differ from
    # the actual compiled function's parameter types.
    target_info_early = nothing
    if ctx.func_registry !== nothing && !is_self_call_early
        called_func_early = nothing
        if actual_func_ref_early isa GlobalRef
            called_func_early = try
                getfield(actual_func_ref_early.mod, actual_func_ref_early.name)
            catch
                nothing
            end
        elseif actual_func_ref_early isa Function
            # PURE-209a: func_ref can be a Function object directly (default-arg methods)
            called_func_early = actual_func_ref_early
        elseif mi isa Core.MethodInstance && mi.def isa Method
            # Fallback: get function from MethodInstance
            # The function is typically the first arg in specTypes
            spec = mi.specTypes
            if spec isa DataType && spec <: Tuple && length(spec.parameters) >= 1
                func_type = spec.parameters[1]
                if func_type isa DataType && func_type.name.name === :typeof
                    # typeof(f) — extract f
                    # The instance of typeof(f) is the function itself
                    try
                        called_func_early = func_type.instance
                    catch
                        # Couldn't get instance
                    end
                end
            end
        end
        if called_func_early !== nothing
            call_arg_types_early = tuple([infer_value_type(arg, ctx) for arg in args]...)
            target_info_early = get_function(ctx.func_registry, called_func_early, call_arg_types_early)
            # PURE-320: Closure/kwarg functions are registered with self-type prepended
            if target_info_early === nothing && typeof(called_func_early) <: Function && isconcretetype(typeof(called_func_early))
                closure_arg_types_early = (typeof(called_func_early), call_arg_types_early...)
                target_info_early = get_function(ctx.func_registry, called_func_early, closure_arg_types_early)
            end
        end
    end

    # Push arguments (for non-signal calls)
    # PURE-044: Track which args had extern.convert_any emitted to avoid double conversion
    extern_convert_emitted_args = falses(length(args))
    for (arg_idx, arg) in enumerate(args)
        # PURE-036z: Track if extern.convert_any was already emitted for this arg
        # to avoid double conversion (externref → externref fails because externref not subtype of anyref)
        extern_convert_emitted = false

        # Check if this is a nothing argument that needs ref.null
        # PURE-044: Also check PiNode with typ === Nothing (Union dispatch pattern)
        is_nothing_arg = arg === nothing ||
                        (arg isa GlobalRef && arg.name === :nothing) ||
                        (arg isa Core.SSAValue && begin
                            ssa_stmt = ctx.code_info.code[arg.id]
                            (ssa_stmt isa GlobalRef && ssa_stmt.name === :nothing) ||
                            (ssa_stmt isa Core.PiNode && ssa_stmt.typ === Nothing)
                        end)

        # PURE-044: Also check if param_types expects Nothing (Union dispatch to different signatures)
        # This handles the case where the arg is a phi value but param expects Nothing (i32)
        if !is_nothing_arg && param_types !== nothing && arg_idx <= length(param_types)
            param_type = param_types[arg_idx]
            if param_type === Nothing
                is_nothing_arg = true
            end
        end

        if is_nothing_arg && param_types !== nothing && arg_idx <= length(param_types)
            # Get the parameter type from the method signature
            param_type = param_types[arg_idx]
            wasm_type = julia_to_wasm_type_concrete(param_type, ctx)
            # Emit the appropriate null/zero value based on the wasm type
            if wasm_type isa ConcreteRef
                push!(bytes, Opcode.REF_NULL)
                append!(bytes, encode_leb128_signed(Int64(wasm_type.type_idx)))
            elseif wasm_type === ExternRef
                push!(bytes, Opcode.REF_NULL)
                push!(bytes, UInt8(ExternRef))
            elseif wasm_type === AnyRef
                push!(bytes, Opcode.REF_NULL)
                push!(bytes, UInt8(AnyRef))
            elseif wasm_type === StructRef
                push!(bytes, Opcode.REF_NULL)
                push!(bytes, UInt8(StructRef))
            elseif wasm_type === ArrayRef
                push!(bytes, Opcode.REF_NULL)
                push!(bytes, UInt8(ArrayRef))
            elseif wasm_type === I64
                push!(bytes, Opcode.I64_CONST)
                push!(bytes, 0x00)
            elseif wasm_type === F32
                push!(bytes, Opcode.F32_CONST)
                append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00])
            elseif wasm_type === F64
                push!(bytes, Opcode.F64_CONST)
                append!(bytes, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            else
                # I32 or other — push i32(0)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
            end
        elseif is_nothing_arg
            # Nothing arg without param_types — emit ref.null externref as safe default
            push!(bytes, Opcode.REF_NULL)
            push!(bytes, UInt8(ExternRef))
        else
            arg_bytes = compile_value(arg, ctx)
            append!(bytes, arg_bytes)
            # Check if argument's actual Wasm type matches expected param type
            # If both are ConcreteRef but with different type indices, insert ref.cast
            if param_types !== nothing && arg_idx <= length(param_types)
                expected_julia_type = param_types[arg_idx]
                # Skip non-Type values (e.g., Vararg markers)
                if expected_julia_type isa Type
                    expected_wasm = get_concrete_wasm_type(expected_julia_type, ctx.mod, ctx.type_registry)
                    actual_julia_type = infer_value_type(arg, ctx)
                    actual_wasm = get_concrete_wasm_type(actual_julia_type, ctx.mod, ctx.type_registry)

                    # PURE-3111/4155: Handle Nothing→ref conversion.
                    # compile_value emits i32_const 0 for Nothing,
                    # but ref-typed params need ref.null. Must fix BEFORE bridging runs,
                    # otherwise bridging tries conversions on an i32 value.
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
                    elseif expected_wasm === I32 && actual_wasm === I64
                        # i64 to i32 — insert i32.wrap_i64
                        push!(bytes, Opcode.I32_WRAP_I64)
                    elseif expected_wasm === I64 && actual_wasm === I32
                        # i32 to i64 — insert i64.extend_i32_s
                        push!(bytes, Opcode.I64_EXTEND_I32_S)
                    elseif expected_wasm === F32 && actual_wasm === F64
                        # f64 to f32 — insert f32.demote_f64
                        push!(bytes, Opcode.F32_DEMOTE_F64)
                    elseif expected_wasm === F64 && actual_wasm === F32
                        # f32 to f64 — insert f64.promote_f32
                        push!(bytes, Opcode.F64_PROMOTE_F32)
                    elseif expected_wasm === I32 && (actual_wasm isa ConcreteRef || actual_wasm === StructRef || actual_wasm === ArrayRef || actual_wasm === ExternRef || actual_wasm === AnyRef)
                        # ref to i32 — drop and push 0 (type mismatch, likely dead code)
                        push!(bytes, Opcode.DROP)
                        push!(bytes, Opcode.I32_CONST)
                        push!(bytes, 0x00)
                    elseif expected_wasm === I64 && (actual_wasm isa ConcreteRef || actual_wasm === StructRef || actual_wasm === ArrayRef || actual_wasm === ExternRef || actual_wasm === AnyRef)
                        # ref to i64 — drop and push 0 (type mismatch, likely dead code)
                        push!(bytes, Opcode.DROP)
                        push!(bytes, Opcode.I64_CONST)
                        push!(bytes, 0x00)
                    elseif expected_wasm === ExternRef && (actual_wasm isa ConcreteRef || actual_wasm === StructRef || actual_wasm === ArrayRef || actual_wasm === AnyRef)
                        # Concrete or abstract ref to externref — insert extern.convert_any
                        # extern.convert_any converts anyref → externref (concrete refs are subtypes of anyref)
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                        extern_convert_emitted = true
                    elseif expected_wasm === ExternRef && (actual_wasm === I32 || actual_wasm === I64 || actual_wasm === F32 || actual_wasm === F64)
                        # PURE-6025: Numeric value to externref — box via struct_new then extern.convert_any.
                        local box_type_idx_inv = get_numeric_box_type!(ctx.mod, ctx.type_registry, actual_wasm)
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.STRUCT_NEW)
                        append!(bytes, encode_leb128_unsigned(box_type_idx_inv))
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                        extern_convert_emitted = true
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
                                    extern_convert_emitted = true
                                end
                            elseif local_idx < ctx.n_params
                                # It's a param — check arg_types
                                if local_idx + 1 <= length(ctx.arg_types)
                                    param_julia_type = ctx.arg_types[local_idx + 1]
                                    param_wasm = get_concrete_wasm_type(param_julia_type, ctx.mod, ctx.type_registry)
                                    if param_wasm isa ConcreteRef || param_wasm === StructRef || param_wasm === ArrayRef || param_wasm === AnyRef
                                        push!(bytes, Opcode.GC_PREFIX)
                                        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                                        extern_convert_emitted = true
                                    end
                                end
                            end
                        end
                    end
                end
            end

            # PURE-036z: Also check against target_info_early if available
            # This catches cases where param_types says ConcreteRef but the actual target function
            # expects ExternRef (because it was registered with different type mapping)
            if target_info_early !== nothing && arg_idx <= length(target_info_early.arg_types)
                target_expected_julia = target_info_early.arg_types[arg_idx]
                target_expected_wasm = get_concrete_wasm_type(target_expected_julia, ctx.mod, ctx.type_registry)
                if target_expected_wasm === ExternRef && !extern_convert_emitted
                    # Target function expects externref for this arg
                    # Check if we pushed a non-externref value that needs conversion
                    # PURE-036z: Skip if extern.convert_any was already emitted to avoid double conversion
                    if length(arg_bytes) >= 2 && arg_bytes[1] == 0x20  # LOCAL_GET
                        local_idx = 0; shift = 0
                        for bi in 2:length(arg_bytes)
                            b = arg_bytes[bi]
                            local_idx |= (Int(b & 0x7f) << shift)
                            shift += 7
                            if (b & 0x80) == 0; break; end
                        end
                        local_arr_idx = local_idx - ctx.n_params + 1
                        if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                            actual_local_wasm = ctx.locals[local_arr_idx]
                            if actual_local_wasm isa ConcreteRef || actual_local_wasm === StructRef || actual_local_wasm === ArrayRef || actual_local_wasm === AnyRef
                                push!(bytes, Opcode.GC_PREFIX)
                                push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                                extern_convert_emitted = true
                            end
                        elseif local_idx < ctx.n_params && local_idx + 1 <= length(ctx.arg_types)
                            param_wasm = get_concrete_wasm_type(ctx.arg_types[local_idx + 1], ctx.mod, ctx.type_registry)
                            if param_wasm isa ConcreteRef || param_wasm === StructRef || param_wasm === ArrayRef || param_wasm === AnyRef
                                push!(bytes, Opcode.GC_PREFIX)
                                push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                                extern_convert_emitted = true
                            end
                        end
                    elseif length(arg_bytes) >= 3 && arg_bytes[1] == 0xfb && (arg_bytes[2] == 0x00 || arg_bytes[2] == 0x01)
                        # struct_new or struct_new_default — produces a ConcreteRef, needs conversion
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                        extern_convert_emitted = true
                    end
                end
            end
        end
        # PURE-044: Record if extern.convert_any was emitted for this arg
        extern_convert_emitted_args[arg_idx] = extern_convert_emitted
    end

    arg_type = length(args) > 0 ? infer_value_type(args[1], ctx) : Int64
    is_32bit = arg_type === Int32 || arg_type === UInt32 || arg_type === Bool || arg_type === Char ||
               arg_type === Int16 || arg_type === UInt16 || arg_type === Int8 || arg_type === UInt8 ||
               (isprimitivetype(arg_type) && sizeof(arg_type) <= 4)

    # mi was already extracted above for parameter type checking
    if mi isa Core.MethodInstance
        meth = mi.def
        if meth isa Method
            name = meth.name

            # Check if this is a self-recursive call
            # The second argument of invoke is the function reference
            # It can be a GlobalRef directly, or an SSA value that points to a GlobalRef
            func_ref = expr.args[2]

            # If func_ref is an SSA value, try to resolve it to the underlying GlobalRef
            actual_func_ref = func_ref
            if func_ref isa Core.SSAValue
                ssa_stmt = ctx.code_info.code[func_ref.id]
                if ssa_stmt isa GlobalRef
                    actual_func_ref = ssa_stmt
                end
            elseif func_ref isa Core.Argument
                # PURE-220: Higher-order function calls (e.g., parse_Nary's `down(ps)`)
                # func_ref is a function parameter. Extract actual function from mi.specTypes.
                if mi isa Core.MethodInstance
                    spec = mi.specTypes
                    if spec isa DataType && spec <: Tuple && length(spec.parameters) >= 1
                        func_type = spec.parameters[1]
                        if func_type isa DataType
                            try
                                actual_func_ref = func_type.instance
                            catch; end
                        end
                    end
                end
            end

            is_self_call = false
            if ctx.func_ref !== nothing && actual_func_ref isa GlobalRef
                # Check if this GlobalRef refers to the same function
                try
                    called_func = getfield(actual_func_ref.mod, actual_func_ref.name)
                    if called_func === ctx.func_ref
                        # PURE-220/047: Check arity AND types for overloaded methods
                        if mi isa Core.MethodInstance
                            spec = mi.specTypes
                            if spec isa DataType && spec <: Tuple
                                call_nargs = length(spec.parameters) - 1
                                if call_nargs == length(ctx.arg_types)
                                    call_arg_types = spec.parameters[2:end]
                                    is_self_call = all(call_arg_types[i] <: ctx.arg_types[i] for i in 1:call_nargs)
                                end
                            else
                                is_self_call = true
                            end
                        else
                            is_self_call = true
                        end
                    end
                catch
                    is_self_call = false
                end
            elseif ctx.func_ref !== nothing && actual_func_ref isa Function
                # PURE-209a: Function object direct comparison
                if actual_func_ref === ctx.func_ref
                    # PURE-220/047: Check arity AND types for overloaded methods
                    if mi isa Core.MethodInstance
                        spec = mi.specTypes
                        if spec isa DataType && spec <: Tuple
                            call_nargs = length(spec.parameters) - 1
                            if call_nargs == length(ctx.arg_types)
                                call_arg_types = spec.parameters[2:end]
                                is_self_call = all(call_arg_types[i] <: ctx.arg_types[i] for i in 1:call_nargs)
                            end
                        else
                            is_self_call = true
                        end
                    else
                        is_self_call = true
                    end
                end
            end

            # Check for cross-function call within the module first
            cross_call_handled = false
            # PURE-913: Skip cross-call for runtime intrinsics with proper inline handlers.
            # str_substr's generate_intrinsic_body is a stub (returns source string unchanged).
            # str_trim calls str_substr internally, so also broken when compiled standalone.
            # The inline handlers below (str_substr at line ~22446, str_trim at ~23572)
            # properly implement these using WasmGC array operations with caller scratch locals.
            _skip_cross_call = name in (:str_substr, :str_trim)
            if ctx.func_registry !== nothing && !is_self_call && !_skip_cross_call
                # Try to find this function in our registry
                called_func = nothing
                if actual_func_ref isa GlobalRef
                    called_func = try
                        getfield(actual_func_ref.mod, actual_func_ref.name)
                    catch
                        nothing
                    end
                elseif actual_func_ref isa DataType || actual_func_ref isa UnionAll
                    # For constructor calls, the func_ref might be the type directly
                    called_func = actual_func_ref
                elseif actual_func_ref isa Function
                    # PURE-209a: For default-arg methods, func_ref can be a Function object
                    # (e.g., typeof(next_token) for next_token(lexer, true))
                    called_func = actual_func_ref
                elseif actual_func_ref isa Core.Argument && mi isa Core.MethodInstance
                    # PURE-220: Fallback for Core.Argument — extract from mi.specTypes
                    spec = mi.specTypes
                    if spec isa DataType && spec <: Tuple && length(spec.parameters) >= 1
                        func_type = spec.parameters[1]
                        if func_type isa DataType
                            try
                                called_func = func_type.instance
                            catch; end
                        end
                    end
                end

                if called_func !== nothing
                    # Infer argument types for dispatch
                    call_arg_types = tuple([infer_value_type(arg, ctx) for arg in args]...)
                    target_info = get_function(ctx.func_registry, called_func, call_arg_types)

                    # PURE-320: Closure/kwarg functions are registered with self-type prepended
                    # (e.g., typeof(#SourceFile#40) prepended to arg_types). Retry with self-type.
                    if target_info === nothing && typeof(called_func) <: Function && isconcretetype(typeof(called_func))
                        closure_arg_types = (typeof(called_func), call_arg_types...)
                        target_info = get_function(ctx.func_registry, called_func, closure_arg_types)
                    end

                    if target_info !== nothing
                        # PURE-036z: Check if any arg needs extern.convert_any insertion
                        # The args were already pushed, but we need to convert concrete refs to externref
                        # where the target function expects externref but we pushed a concrete ref.
                        # Since args are pushed in order and we can only add conversions at the end,
                        # we need to use a different strategy: after ALL args are pushed, we can
                        # re-order/convert them using locals. But this is complex.
                        #
                        # Simpler approach: check each arg and add extern.convert_any if the LAST
                        # arg needs it (since that's what's on top of the stack). For earlier args,
                        # this won't work with pure stack manipulation.
                        #
                        # Even simpler: only handle the case where the LAST arg needs conversion
                        # (most common case for the current error).
                        n_args = length(args)
                        if n_args > 0
                            last_arg_idx = n_args
                            # PURE-044: Skip if extern.convert_any was already emitted in argument loop
                            if last_arg_idx <= length(target_info.arg_types) && !extern_convert_emitted_args[last_arg_idx]
                                last_target_julia = target_info.arg_types[last_arg_idx]
                                last_target_wasm = get_concrete_wasm_type(last_target_julia, ctx.mod, ctx.type_registry)
                                last_actual_julia = call_arg_types[last_arg_idx]
                                last_actual_wasm = get_concrete_wasm_type(last_actual_julia, ctx.mod, ctx.type_registry)
                                last_arg = args[n_args]

                                if last_target_wasm === ExternRef && (last_actual_wasm isa ConcreteRef || last_actual_wasm === StructRef || last_actual_wasm === ArrayRef || last_actual_wasm === AnyRef)
                                    push!(bytes, Opcode.GC_PREFIX)
                                    push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                                elseif last_target_wasm === ExternRef && last_actual_wasm === ExternRef && last_arg isa Core.SSAValue
                                    # Check actual local type for the last arg
                                    if haskey(ctx.ssa_locals, last_arg.id)
                                        local_idx = ctx.ssa_locals[last_arg.id]
                                        local_arr_idx = local_idx - ctx.n_params + 1
                                        if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                                            actual_local_wasm = ctx.locals[local_arr_idx]
                                            if actual_local_wasm isa ConcreteRef || actual_local_wasm === StructRef || actual_local_wasm === ArrayRef || actual_local_wasm === AnyRef
                                                push!(bytes, Opcode.GC_PREFIX)
                                                push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                                            end
                                        end
                                    end
                                end
                            end
                        end

                        # Also handle middle args if needed (use locals to reorder)
                        # For now, check if the SECOND arg (index 2) needs conversion when there are 3+ args
                        # This handles the func 126 case: (ref null 36), externref, (ref null 14)
                        # where the middle arg (externref) is getting a concrete ref
                        if n_args >= 2
                            for mid_arg_idx in n_args-1:-1:1  # Check from second-to-last to first
                                # PURE-044: Skip if extern.convert_any was already emitted in argument loop
                                if mid_arg_idx <= length(target_info.arg_types) && !extern_convert_emitted_args[mid_arg_idx]
                                    mid_target_julia = target_info.arg_types[mid_arg_idx]
                                    mid_target_wasm = get_concrete_wasm_type(mid_target_julia, ctx.mod, ctx.type_registry)
                                    mid_actual_julia = call_arg_types[mid_arg_idx]
                                    mid_actual_wasm = get_concrete_wasm_type(mid_actual_julia, ctx.mod, ctx.type_registry)
                                    mid_arg = args[mid_arg_idx]

                                    needs_convert = false
                                    if mid_target_wasm === ExternRef && (mid_actual_wasm isa ConcreteRef || mid_actual_wasm === StructRef || mid_actual_wasm === ArrayRef || mid_actual_wasm === AnyRef)
                                        needs_convert = true
                                    elseif mid_target_wasm === ExternRef && mid_actual_wasm === ExternRef && mid_arg isa Core.SSAValue
                                        if haskey(ctx.ssa_locals, mid_arg.id)
                                            local_idx = ctx.ssa_locals[mid_arg.id]
                                            local_arr_idx = local_idx - ctx.n_params + 1
                                            if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                                                actual_local_wasm = ctx.locals[local_arr_idx]
                                                if actual_local_wasm isa ConcreteRef || actual_local_wasm === StructRef || actual_local_wasm === ArrayRef || actual_local_wasm === AnyRef
                                                    needs_convert = true
                                                end
                                            end
                                        end
                                    end

                                    if needs_convert
                                        # Stack currently: [arg1, arg2, ..., argN]
                                        # Need to convert arg at mid_arg_idx
                                        # This is complex with pure stack ops; skip for now and
                                        # rely on the initial arg loop to handle most cases.
                                        # The error at func 126 is for arg index 2 (0-based: 1)
                                        # which is the second param. If there are only 2 args on
                                        # stack but 3 params needed, there's a different bug.
                                    end
                                end
                            end
                        end

                        # Cross-function call - emit call instruction with target index
                        push!(bytes, Opcode.CALL)
                        append!(bytes, encode_leb128_unsigned(target_info.wasm_idx))
                        cross_call_handled = true
                        # PURE-6024: If callee returns Union{} (Bottom), it always throws/traps.
                        # The Wasm func type has no result, so code after is unreachable.
                        # Emit unreachable to make stack polymorphic — prevents DROP from
                        # causing "nothing on stack" when the void call has no return value.
                        # NOTE: Do NOT set ctx.last_stmt_was_stub here. The SSA type may not
                        # be Union{} (e.g., Any in unoptimized IR), so setting the flag would
                        # incorrectly trigger dead code detection and skip block structures.
                        if target_info.return_type === Union{}
                            push!(bytes, Opcode.UNREACHABLE)
                        end
                        # PURE-220: For higher-order calls (Core.Argument func_ref), if SSA has
                        # no local and target returns non-void, drop the unused return value.
                        # Previously these emitted unreachable (making the code dead), but now
                        # with actual calls, the return value stays on the stack.
                        if func_ref isa Core.Argument && !haskey(ctx.ssa_locals, idx) && target_info.return_type !== Nothing
                            push!(bytes, Opcode.DROP)
                        end
                        # Check: if function returns externref but caller expects concrete ref,
                        # insert any_convert_extern + ref.cast null to bridge the type gap.
                        # This happens when the function's wasm return type is externref (mapped
                        # from Any/Union via julia_to_wasm_type) but the caller's SSA local uses
                        # a tagged union struct (mapped via julia_to_wasm_type_concrete).
                        if haskey(ctx.ssa_locals, idx)
                            local_idx_val = ctx.ssa_locals[idx]
                            local_arr_idx = local_idx_val - ctx.n_params + 1
                            if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                                target_local_type = ctx.locals[local_arr_idx]
                                if target_local_type isa ConcreteRef
                                    ret_wasm = julia_to_wasm_type(target_info.return_type)
                                    if ret_wasm === ExternRef
                                        # Function returns externref, local expects concrete ref
                                        append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN])
                                        append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.REF_CAST_NULL])
                                        append!(bytes, encode_leb128_signed(Int64(target_local_type.type_idx)))
                                    end
                                elseif target_local_type === AnyRef
                                    ret_wasm = julia_to_wasm_type(target_info.return_type)
                                    if ret_wasm === ExternRef
                                        # PURE-908: Function returns externref, local expects anyref
                                        append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN])
                                    end
                                elseif target_local_type === ExternRef && func_ref isa Core.Argument
                                    # PURE-220: Higher-order call returns concrete ref but local expects externref
                                    # (SSA type is Any because the function parameter is generic)
                                    # PURE-6022: But if the callee already returns externref, skip —
                                    # extern_convert_any expects anyref input, not externref.
                                    callee_ret_wasm = julia_to_wasm_type(target_info.return_type)
                                    if callee_ret_wasm !== ExternRef
                                        append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.EXTERN_CONVERT_ANY])
                                    end
                                end
                            end
                        end
                    end
                end
            end

            if is_self_call
                # Self-recursive call - emit call instruction
                push!(bytes, Opcode.CALL)
                append!(bytes, encode_leb128_unsigned(ctx.func_idx))
                # PURE-908: Bridge return type for self-calls (externref→anyref)
                if haskey(ctx.ssa_locals, idx)
                    local_idx_val = ctx.ssa_locals[idx]
                    local_arr_idx = local_idx_val - ctx.n_params + 1
                    if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                        target_local_type = ctx.locals[local_arr_idx]
                        if target_local_type === AnyRef && ctx.return_type !== nothing
                            ret_wasm = julia_to_wasm_type(ctx.return_type)
                            if ret_wasm === ExternRef
                                append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN])
                            end
                        elseif target_local_type isa ConcreteRef && ctx.return_type !== nothing
                            ret_wasm = julia_to_wasm_type(ctx.return_type)
                            if ret_wasm === ExternRef
                                append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.ANY_CONVERT_EXTERN])
                                append!(bytes, UInt8[Opcode.GC_PREFIX, Opcode.REF_CAST_NULL])
                                append!(bytes, encode_leb128_signed(Int64(target_local_type.type_idx)))
                            end
                        end
                    end
                end
            elseif cross_call_handled
                # Already handled above

            elseif name === :+ || name === :add_int
                push!(bytes, is_32bit ? Opcode.I32_ADD : Opcode.I64_ADD)
            elseif name === :- || name === :sub_int
                push!(bytes, is_32bit ? Opcode.I32_SUB : Opcode.I64_SUB)
            elseif name === :* || name === :mul_int
                push!(bytes, is_32bit ? Opcode.I32_MUL : Opcode.I64_MUL)
            elseif name === :throw_boundserror || name === :throw || name === :throw_inexacterror
                # PURE-1102: Error throwing functions - emit throw (catchable) instead of unreachable (trap)
                # Clear the stack first (arguments were pushed but not needed)
                bytes = UInt8[]  # Reset - don't need the pushed args
                ensure_exception_tag!(ctx.mod)
                push!(bytes, Opcode.THROW)
                append!(bytes, encode_leb128_unsigned(0))  # tag index 0
                ctx.last_stmt_was_stub = true  # PURE-908

            # Power operator: x ^ y for floats
            # WASM doesn't have a native pow instruction, so we need to handle this
            # For now, we require the pow import to be available
            elseif name === :^ && length(args) == 2
                arg1_type = infer_value_type(args[1], ctx)
                arg2_type = infer_value_type(args[2], ctx)

                if (arg1_type === Float64 || arg1_type === Float32) &&
                   (arg2_type === Float64 || arg2_type === Float32)
                    # Float power - need Math.pow import
                    # Check if we have a pow import
                    pow_import_idx = nothing
                    for (i, imp) in enumerate(ctx.mod.imports)
                        if imp.kind == 0x00 && imp.field_name == "pow"  # function import
                            pow_import_idx = UInt32(i - 1)
                            break
                        end
                    end

                    if pow_import_idx !== nothing
                        # Args already compiled, call pow import
                        # Convert to f64 if needed (Math.pow expects f64, f64 -> f64)
                        if arg1_type === Float32
                            # First arg is f32, need to insert promotion before second arg
                            # This is tricky with stack order. For now, just promote both
                            bytes = UInt8[]  # Reset
                            append!(bytes, compile_value(args[1], ctx))
                            push!(bytes, 0xBB)  # f64.promote_f32
                            append!(bytes, compile_value(args[2], ctx))
                            if arg2_type === Float32
                                push!(bytes, 0xBB)  # f64.promote_f32
                            end
                        end
                        push!(bytes, Opcode.CALL)
                        append!(bytes, encode_leb128_unsigned(pow_import_idx))
                        # Convert back to f32 if needed
                        if arg1_type === Float32
                            push!(bytes, 0xB6)  # f32.demote_f64
                        end
                    else
                        # No pow import - emit approximation using exp(y * log(x))
                        # This is hacky but works for basic cases
                        # For now, error out requesting the import
                        error("Float power (^) requires 'pow' import from Math module. " *
                              "Add (\"Math\", \"pow\", [F64, F64], [F64]) to imports.")
                    end
                elseif (arg1_type === Int32 || arg1_type === Int64) &&
                       (arg2_type === Int32 || arg2_type === Int64)
                    # Integer power - can implement with loop
                    # For simplicity, error out for now
                    error("Integer power (^) not yet implemented. Use float power instead.")
                else
                    error("Unsupported power types: $(arg1_type) ^ $(arg2_type)")
                end

            elseif name === :length && (arg_type === String || arg_type <: AbstractVector || arg_type === Any || arg_type === Union{})
                # String/array length - argument already pushed, emit array.len
                # Only for types that are actually arrays in WasmGC (String, Vector, Any)
                # SubString and other struct types must go through cross-function call
                if arg_type === Any || arg_type === Union{}
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

            # String concatenation: string * string -> string
            # Julia compiles string concatenation to Base._string
            # Also handle String, Symbol for error message construction
            elseif (name === :* || name === :_string) && length(args) >= 2 &&
                   (infer_value_type(args[1], ctx) === String || infer_value_type(args[1], ctx) === Symbol) &&
                   (infer_value_type(args[2], ctx) === String || infer_value_type(args[2], ctx) === Symbol)
                # String concatenation using WasmGC array operations
                # For now, handle 2-string concat (most common case)
                if length(args) == 2
                    bytes = compile_string_concat(args[1], args[2], ctx)
                else
                    # Multi-string concat: concat pairwise
                    bytes = compile_string_concat(args[1], args[2], ctx)
                    for i in 3:length(args)
                        # Store intermediate result and concat next string
                        # This is simplified - for full support we'd need proper temp locals
                        # For now, just do first two
                    end
                end

            # PURE-325: isascii(s) — check all bytes < 0x80
            # Called from normalize_identifier via isascii(codeunits(s)).
            # The argument is CodeUnits{UInt8,String} (a struct wrapping String).
            # Extract the String (field 0) from the struct, then iterate bytes.
            elseif name === :isascii && length(args) == 1
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
                arg_type = infer_value_type(args[1], ctx)

                # If the argument is a CodeUnits struct, extract the String field.
                if arg_type !== String && arg_type !== Symbol
                    if haskey(ctx.type_registry.structs, arg_type)
                        cu_info = ctx.type_registry.structs[arg_type]
                        push!(bytes, Opcode.GC_PREFIX)
                        push!(bytes, Opcode.STRUCT_GET)
                        append!(bytes, encode_leb128_unsigned(cu_info.wasm_type_idx))
                        append!(bytes, encode_leb128_unsigned(0))  # field 0 = :s (String)
                    end
                end

                # Allocate locals: str, len, accum, i
                str_arr_type = ConcreteRef(str_type_idx, true)
                str_local = allocate_local!(ctx, str_arr_type)
                len_local = allocate_local!(ctx, I32)
                accum_local = allocate_local!(ctx, I32)
                i_local = allocate_local!(ctx, I32)

                # Store string
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(str_local))

                # len = array.len(str)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(str_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_LEN)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(len_local))

                # accum = 0
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(accum_local))

                # i = 0
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(i_local))

                # block $exit
                push!(bytes, Opcode.BLOCK)
                push!(bytes, 0x40)  # void
                #   loop $loop
                push!(bytes, Opcode.LOOP)
                push!(bytes, 0x40)  # void

                #     br_if $exit (i >= len)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(len_local))
                push!(bytes, Opcode.I32_GE_S)
                push!(bytes, Opcode.BR_IF)
                push!(bytes, 0x01)  # break to outer block

                #     accum |= array.get(str, i)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(accum_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(str_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))
                push!(bytes, Opcode.I32_OR)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(accum_local))

                #     i++
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(i_local))

                #     br $loop
                push!(bytes, Opcode.BR)
                push!(bytes, 0x00)  # continue loop

                #   end loop
                push!(bytes, Opcode.END)
                # end block
                push!(bytes, Opcode.END)

                # result = (accum < 0x80) ? 1 : 0
                # accum < 128 means all bytes are ASCII
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(accum_local))
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(0x80))
                push!(bytes, Opcode.I32_LT_U)  # unsigned comparison: accum < 0x80

            # String equality comparison
            elseif name === :(==) && length(args) == 2 &&
                   infer_value_type(args[1], ctx) === String &&
                   infer_value_type(args[2], ctx) === String
                bytes = compile_string_equal(args[1], args[2], ctx)

            # WasmTarget string operations - str_char(s, i) -> Int32
            elseif name === :str_char && length(args) == 2
                # Get character at index: array.get on string array
                # Args: string, index (1-based)
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

                # Compile string arg (already pushed by args loop)
                # Compile index arg and convert to 0-based
                idx_type = infer_value_type(args[2], ctx)
                if idx_type === Int64 || idx_type === Int
                    # Convert Int64 to Int32 and subtract 1
                    push!(bytes, Opcode.I32_WRAP_I64)
                end
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)  # 1
                push!(bytes, Opcode.I32_SUB)  # index - 1 for 0-based

                # array.get
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))

            # WasmTarget string operations - str_setchar!(s, i, c) -> Nothing
            elseif name === :str_setchar! && length(args) == 3
                # Set character at index: array.set on string array
                # Args: string, index (1-based), char (Int32)
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

                # Stack has: string, index, char
                # Need to reorder to: string, index-1, char for array.set
                # Actually array.set expects: array, index, value
                # So we need: compile string, compile index-1, compile char

                # Clear the bytes from the args loop - we'll recompile in correct order
                bytes = UInt8[]

                # Compile string
                append!(bytes, compile_value(args[1], ctx))

                # Compile index and convert to 0-based
                append!(bytes, compile_value(args[2], ctx))
                idx_type = infer_value_type(args[2], ctx)
                if idx_type === Int64 || idx_type === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_SUB)

                # Compile char value
                append!(bytes, compile_value(args[3], ctx))
                char_type = infer_value_type(args[3], ctx)
                if char_type === Int64 || char_type === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end

                # array.set
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_SET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))

            # WasmTarget string operations - str_len(s) -> Int32
            elseif name === :str_len && length(args) == 1
                # Get string length as Int32
                # Arg already compiled, just emit array.len
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_LEN)

            # WasmTarget string operations - str_new(len) -> String
            elseif name === :str_new && length(args) == 1
                # Create new string of given length, filled with zeros
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

                # Length arg already compiled
                len_type = infer_value_type(args[1], ctx)
                if len_type === Int64 || len_type === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end

                # array.new_default creates array filled with default value (0 for i32)
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
                append!(bytes, encode_leb128_unsigned(str_type_idx))

            # WasmTarget string operations - str_copy(src, src_pos, dst, dst_pos, len) -> Nothing
            elseif name === :str_copy && length(args) == 5
                # Copy characters from src to dst using array.copy
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

                # Clear bytes - recompile in correct order for array.copy
                # array.copy expects: dst, dst_offset, src, src_offset, len
                bytes = UInt8[]

                # dst array
                append!(bytes, compile_value(args[3], ctx))
                # dst offset (0-based)
                append!(bytes, compile_value(args[4], ctx))
                dst_idx_type = infer_value_type(args[4], ctx)
                if dst_idx_type === Int64 || dst_idx_type === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_SUB)

                # src array
                append!(bytes, compile_value(args[1], ctx))
                # src offset (0-based)
                append!(bytes, compile_value(args[2], ctx))
                src_idx_type = infer_value_type(args[2], ctx)
                if src_idx_type === Int64 || src_idx_type === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_SUB)

                # length
                append!(bytes, compile_value(args[5], ctx))
                len_type = infer_value_type(args[5], ctx)
                if len_type === Int64 || len_type === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end

                # array.copy
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_COPY)
                append!(bytes, encode_leb128_unsigned(str_type_idx))
                append!(bytes, encode_leb128_unsigned(str_type_idx))

            # WasmTarget string operations - str_substr(s, start, len) -> String
            elseif name === :str_substr && length(args) == 3
                # Extract substring: create new string and copy characters
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

                # Use scratch locals stored in context
                if ctx.scratch_locals === nothing
                    error("String operations require scratch locals but none were allocated")
                end
                result_local, src_local, _, _, _ = ctx.scratch_locals

                # Clear bytes - recompile in correct order
                bytes = UInt8[]

                # Store source string
                append!(bytes, compile_value(args[1], ctx))
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(src_local))

                # Create new string of specified length
                append!(bytes, compile_value(args[3], ctx))  # len
                len_type = infer_value_type(args[3], ctx)
                if len_type === Int64 || len_type === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
                append!(bytes, encode_leb128_unsigned(str_type_idx))
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(result_local))

                # Copy characters: array.copy [dst, dst_off, src, src_off, len]
                # dst = result, dst_off = 0, src = source, src_off = start-1, len = len
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(result_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)  # dst_off = 0

                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(src_local))

                # src_off = start - 1 (convert to 0-based)
                append!(bytes, compile_value(args[2], ctx))
                start_type = infer_value_type(args[2], ctx)
                if start_type === Int64 || start_type === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_SUB)

                # len
                append!(bytes, compile_value(args[3], ctx))
                len_type2 = infer_value_type(args[3], ctx)
                if len_type2 === Int64 || len_type2 === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end

                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_COPY)
                append!(bytes, encode_leb128_unsigned(str_type_idx))
                append!(bytes, encode_leb128_unsigned(str_type_idx))

                # Return result
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(result_local))

            # WasmTarget string operations - str_hash(s) -> Int32
            elseif name === :str_hash && length(args) == 1
                # Compute string hash using Java-style: h = 31 * h + char[i]
                # Uses a loop over the string characters
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

                bytes = UInt8[]

                # Allocate locals for this operation
                str_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, ConcreteRef(str_type_idx))  # string reference

                len_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)  # string length

                hash_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)  # running hash

                i_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)  # loop index

                # Store string reference
                append!(bytes, compile_value(args[1], ctx))
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(str_local))

                # Get length
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_LEN)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(len_local))

                # Initialize hash = 0
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(hash_local))

                # Initialize i = 0
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(i_local))

                # Loop over characters
                push!(bytes, Opcode.BLOCK)  # outer block for exit
                push!(bytes, 0x40)  # void
                push!(bytes, Opcode.LOOP)  # loop
                push!(bytes, 0x40)  # void

                # Check i < len
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(len_local))
                push!(bytes, Opcode.I32_GE_S)
                push!(bytes, Opcode.BR_IF)
                push!(bytes, 0x01)  # break to outer block if done

                # hash = 31 * hash + char[i]
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(hash_local))
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(31))
                push!(bytes, Opcode.I32_MUL)

                # Get char at index i (0-based)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(str_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))

                push!(bytes, Opcode.I32_ADD)

                # Mask to positive: & 0x7FFFFFFF
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(0x7FFFFFFF))
                push!(bytes, Opcode.I32_AND)

                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(hash_local))

                # i++
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(i_local))

                # Continue loop
                push!(bytes, Opcode.BR)
                push!(bytes, 0x00)

                push!(bytes, Opcode.END)  # end loop
                push!(bytes, Opcode.END)  # end block

                # Return hash
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(hash_local))

            # ================================================================
            # BROWSER-010: New String Operations
            # str_find, str_contains, str_startswith, str_endswith
            # str_uppercase, str_lowercase, str_trim
            # ================================================================

            # str_find(haystack, needle) -> Int32
            # Returns 1-based position or 0 if not found
            elseif name === :str_find && length(args) == 2
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
                bytes = UInt8[]

                # Allocate locals
                haystack_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, ConcreteRef(str_type_idx))
                needle_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, ConcreteRef(str_type_idx))
                haystack_len_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                needle_len_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                i_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                j_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                found_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                result_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                last_start_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)

                # Store haystack
                append!(bytes, compile_value(args[1], ctx))
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(haystack_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_LEN)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(haystack_len_local))

                # Store needle
                append!(bytes, compile_value(args[2], ctx))
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(needle_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_LEN)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(needle_len_local))

                # Initialize result = 0
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(result_local))

                # If needle_len == 0, return 1
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(needle_len_local))
                push!(bytes, Opcode.I32_EQZ)
                push!(bytes, Opcode.IF)
                push!(bytes, 0x40)  # void
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(result_local))
                push!(bytes, Opcode.ELSE)

                # Check if needle_len > haystack_len - skip search if so
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(needle_len_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(haystack_len_local))
                push!(bytes, Opcode.I32_GT_S)
                push!(bytes, Opcode.IF)
                push!(bytes, 0x40)  # void
                # result stays 0
                push!(bytes, Opcode.ELSE)

                # Calculate last_start = haystack_len - needle_len + 1 (1-based)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(haystack_len_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(needle_len_local))
                push!(bytes, Opcode.I32_SUB)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(last_start_local))

                # Initialize i = 1 (1-based)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(i_local))

                # Outer loop over haystack positions
                push!(bytes, Opcode.BLOCK)  # outer block for exit
                push!(bytes, 0x40)
                push!(bytes, Opcode.LOOP)  # outer loop
                push!(bytes, 0x40)

                # Check i <= last_start
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(last_start_local))
                push!(bytes, Opcode.I32_GT_S)
                push!(bytes, Opcode.BR_IF)
                push!(bytes, 0x01)  # break outer block if done

                # found = 1
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(found_local))

                # j = 0 (0-based index into needle)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(j_local))

                # Inner loop - compare needle chars
                push!(bytes, Opcode.BLOCK)  # inner block for break
                push!(bytes, 0x40)
                push!(bytes, Opcode.LOOP)  # inner loop
                push!(bytes, 0x40)

                # Check j < needle_len
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(j_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(needle_len_local))
                push!(bytes, Opcode.I32_GE_S)
                push!(bytes, Opcode.BR_IF)
                push!(bytes, 0x01)  # break inner block if done

                # Compare haystack[i + j - 1] with needle[j] (0-based array access)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(haystack_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(j_local))
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_SUB)  # i + j - 1 for 0-based
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))

                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(needle_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(j_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))

                push!(bytes, Opcode.I32_NE)
                push!(bytes, Opcode.IF)
                push!(bytes, 0x40)
                # Characters don't match - set found = 0 and break
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(found_local))
                push!(bytes, Opcode.BR)
                push!(bytes, 0x02)  # break inner block
                push!(bytes, Opcode.END)  # end if

                # j++
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(j_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(j_local))

                # Continue inner loop
                push!(bytes, Opcode.BR)
                push!(bytes, 0x00)

                push!(bytes, Opcode.END)  # end inner loop
                push!(bytes, Opcode.END)  # end inner block

                # If found, set result = i and break outer
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(found_local))
                push!(bytes, Opcode.IF)
                push!(bytes, 0x40)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(result_local))
                push!(bytes, Opcode.BR)
                push!(bytes, 0x01)  # break outer block
                push!(bytes, Opcode.END)

                # i++
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(i_local))

                # Continue outer loop
                push!(bytes, Opcode.BR)
                push!(bytes, 0x00)

                push!(bytes, Opcode.END)  # end outer loop
                push!(bytes, Opcode.END)  # end outer block

                push!(bytes, Opcode.END)  # end else (needle not too long)
                push!(bytes, Opcode.END)  # end else (needle not empty)

                # Return result
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(result_local))

            # str_contains(haystack, needle) -> Bool
            # Returns true if needle is found in haystack
            elseif name === :str_contains && length(args) == 2
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
                bytes = UInt8[]

                # Reuse str_find implementation by comparing result > 0
                # Allocate locals
                haystack_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, ConcreteRef(str_type_idx))
                needle_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, ConcreteRef(str_type_idx))
                haystack_len_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                needle_len_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                i_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                j_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                found_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                result_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                last_start_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)

                # Store haystack
                append!(bytes, compile_value(args[1], ctx))
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(haystack_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_LEN)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(haystack_len_local))

                # Store needle
                append!(bytes, compile_value(args[2], ctx))
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(needle_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_LEN)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(needle_len_local))

                # Initialize result = 0 (false)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(result_local))

                # If needle_len == 0, return true (1)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(needle_len_local))
                push!(bytes, Opcode.I32_EQZ)
                push!(bytes, Opcode.IF)
                push!(bytes, 0x40)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(result_local))
                push!(bytes, Opcode.ELSE)

                # Check if needle_len > haystack_len - return false if so
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(needle_len_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(haystack_len_local))
                push!(bytes, Opcode.I32_GT_S)
                push!(bytes, Opcode.I32_EQZ)  # NOT greater
                push!(bytes, Opcode.IF)
                push!(bytes, 0x40)

                # Calculate last_start = haystack_len - needle_len
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(haystack_len_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(needle_len_local))
                push!(bytes, Opcode.I32_SUB)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(last_start_local))

                # Initialize i = 0 (0-based)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(i_local))

                # Outer loop
                push!(bytes, Opcode.BLOCK)
                push!(bytes, 0x40)
                push!(bytes, Opcode.LOOP)
                push!(bytes, 0x40)

                # Check i <= last_start
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(last_start_local))
                push!(bytes, Opcode.I32_GT_S)
                push!(bytes, Opcode.BR_IF)
                push!(bytes, 0x01)

                # found = 1
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(found_local))

                # j = 0
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(j_local))

                # Inner loop
                push!(bytes, Opcode.BLOCK)
                push!(bytes, 0x40)
                push!(bytes, Opcode.LOOP)
                push!(bytes, 0x40)

                # Check j < needle_len
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(j_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(needle_len_local))
                push!(bytes, Opcode.I32_GE_S)
                push!(bytes, Opcode.BR_IF)
                push!(bytes, 0x01)

                # Compare haystack[i + j] with needle[j]
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(haystack_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(j_local))
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))

                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(needle_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(j_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))

                push!(bytes, Opcode.I32_NE)
                push!(bytes, Opcode.IF)
                push!(bytes, 0x40)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(found_local))
                push!(bytes, Opcode.BR)
                push!(bytes, 0x02)
                push!(bytes, Opcode.END)

                # j++
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(j_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(j_local))

                push!(bytes, Opcode.BR)
                push!(bytes, 0x00)

                push!(bytes, Opcode.END)  # end inner loop
                push!(bytes, Opcode.END)  # end inner block

                # If found, set result = 1 and break
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(found_local))
                push!(bytes, Opcode.IF)
                push!(bytes, 0x40)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(result_local))
                push!(bytes, Opcode.BR)
                push!(bytes, 0x01)
                push!(bytes, Opcode.END)

                # i++
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(i_local))

                push!(bytes, Opcode.BR)
                push!(bytes, 0x00)

                push!(bytes, Opcode.END)  # end outer loop
                push!(bytes, Opcode.END)  # end outer block

                push!(bytes, Opcode.END)  # end if (needle not too long)
                push!(bytes, Opcode.END)  # end else (needle not empty)

                # Return result (0 or 1 as i32, which is Bool in wasm)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(result_local))

            # str_startswith(s, prefix) -> Bool
            elseif name === :str_startswith && length(args) == 2
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
                bytes = UInt8[]

                # Allocate locals
                s_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, ConcreteRef(str_type_idx))
                prefix_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, ConcreteRef(str_type_idx))
                s_len_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                prefix_len_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                i_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                result_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)

                # Store s
                append!(bytes, compile_value(args[1], ctx))
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(s_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_LEN)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(s_len_local))

                # Store prefix
                append!(bytes, compile_value(args[2], ctx))
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(prefix_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_LEN)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(prefix_len_local))

                # Default result = 1 (true)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(result_local))

                # If prefix_len > s_len, return false
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(prefix_len_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(s_len_local))
                push!(bytes, Opcode.I32_GT_S)
                push!(bytes, Opcode.IF)
                push!(bytes, 0x40)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(result_local))
                push!(bytes, Opcode.ELSE)

                # i = 0
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(i_local))

                # Loop
                push!(bytes, Opcode.BLOCK)
                push!(bytes, 0x40)
                push!(bytes, Opcode.LOOP)
                push!(bytes, 0x40)

                # Check i < prefix_len
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(prefix_len_local))
                push!(bytes, Opcode.I32_GE_S)
                push!(bytes, Opcode.BR_IF)
                push!(bytes, 0x01)

                # Compare s[i] with prefix[i]
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(s_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))

                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(prefix_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))

                push!(bytes, Opcode.I32_NE)
                push!(bytes, Opcode.IF)
                push!(bytes, 0x40)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(result_local))
                push!(bytes, Opcode.BR)
                push!(bytes, 0x02)  # break out of loop
                push!(bytes, Opcode.END)

                # i++
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(i_local))

                push!(bytes, Opcode.BR)
                push!(bytes, 0x00)

                push!(bytes, Opcode.END)  # end loop
                push!(bytes, Opcode.END)  # end block
                push!(bytes, Opcode.END)  # end else

                # Return result
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(result_local))

            # str_endswith(s, suffix) -> Bool
            elseif name === :str_endswith && length(args) == 2
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
                bytes = UInt8[]

                # Allocate locals
                s_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, ConcreteRef(str_type_idx))
                suffix_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, ConcreteRef(str_type_idx))
                s_len_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                suffix_len_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                start_pos_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                i_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                result_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)

                # Store s
                append!(bytes, compile_value(args[1], ctx))
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(s_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_LEN)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(s_len_local))

                # Store suffix
                append!(bytes, compile_value(args[2], ctx))
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(suffix_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_LEN)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(suffix_len_local))

                # Default result = 1 (true)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(result_local))

                # If suffix_len > s_len, return false
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(suffix_len_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(s_len_local))
                push!(bytes, Opcode.I32_GT_S)
                push!(bytes, Opcode.IF)
                push!(bytes, 0x40)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(result_local))
                push!(bytes, Opcode.ELSE)

                # Calculate start_pos = s_len - suffix_len (0-based start in s)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(s_len_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(suffix_len_local))
                push!(bytes, Opcode.I32_SUB)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(start_pos_local))

                # i = 0
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(i_local))

                # Loop
                push!(bytes, Opcode.BLOCK)
                push!(bytes, 0x40)
                push!(bytes, Opcode.LOOP)
                push!(bytes, 0x40)

                # Check i < suffix_len
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(suffix_len_local))
                push!(bytes, Opcode.I32_GE_S)
                push!(bytes, Opcode.BR_IF)
                push!(bytes, 0x01)

                # Compare s[start_pos + i] with suffix[i]
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(s_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(start_pos_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))

                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(suffix_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))

                push!(bytes, Opcode.I32_NE)
                push!(bytes, Opcode.IF)
                push!(bytes, 0x40)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(result_local))
                push!(bytes, Opcode.BR)
                push!(bytes, 0x02)
                push!(bytes, Opcode.END)

                # i++
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(i_local))

                push!(bytes, Opcode.BR)
                push!(bytes, 0x00)

                push!(bytes, Opcode.END)  # end loop
                push!(bytes, Opcode.END)  # end block
                push!(bytes, Opcode.END)  # end else

                # Return result
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(result_local))

            # str_uppercase(s) -> String
            # Convert lowercase ASCII letters to uppercase
            elseif name === :str_uppercase && length(args) == 1
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
                bytes = UInt8[]

                # Allocate locals
                s_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, ConcreteRef(str_type_idx))
                len_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                result_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, ConcreteRef(str_type_idx))
                i_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                c_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)

                # Store s and get length
                append!(bytes, compile_value(args[1], ctx))
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(s_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_LEN)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(len_local))

                # Create result string: array.new_default with same length
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(len_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
                append!(bytes, encode_leb128_unsigned(str_type_idx))
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(result_local))

                # i = 0 (0-based for WASM)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(i_local))

                # Loop: while i < len
                push!(bytes, Opcode.BLOCK)  # block for break
                push!(bytes, 0x40)  # void
                push!(bytes, Opcode.LOOP)   # loop
                push!(bytes, 0x40)  # void

                # Check i < len
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(len_local))
                push!(bytes, Opcode.I32_GE_S)
                push!(bytes, Opcode.BR_IF)
                push!(bytes, 0x01)  # break if i >= len

                # c = s[i]
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(s_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(c_local))

                # Check if c is lowercase (97 <= c <= 122)
                # If so, convert to uppercase (c - 32)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(c_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x61)  # 97 = 'a'
                push!(bytes, Opcode.I32_GE_S)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(c_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x7a)  # 122 = 'z'
                push!(bytes, Opcode.I32_LE_S)
                push!(bytes, Opcode.I32_AND)
                push!(bytes, Opcode.IF)
                push!(bytes, 0x40)  # void

                # Convert to uppercase: c = c - 32
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(c_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x20)  # 32
                push!(bytes, Opcode.I32_SUB)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(c_local))

                push!(bytes, Opcode.END)  # end if

                # result[i] = c
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(result_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(c_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_SET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))

                # i++
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(i_local))

                push!(bytes, Opcode.BR)
                push!(bytes, 0x00)  # continue loop

                push!(bytes, Opcode.END)  # end loop
                push!(bytes, Opcode.END)  # end block

                # Return result
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(result_local))

            # str_lowercase(s) -> String
            # Convert uppercase ASCII letters to lowercase
            elseif name === :str_lowercase && length(args) == 1
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
                bytes = UInt8[]

                # Allocate locals
                s_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, ConcreteRef(str_type_idx))
                len_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                result_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, ConcreteRef(str_type_idx))
                i_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                c_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)

                # Store s and get length
                append!(bytes, compile_value(args[1], ctx))
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(s_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_LEN)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(len_local))

                # Create result string: array.new_default with same length
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(len_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
                append!(bytes, encode_leb128_unsigned(str_type_idx))
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(result_local))

                # i = 0 (0-based for WASM)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(i_local))

                # Loop: while i < len
                push!(bytes, Opcode.BLOCK)  # block for break
                push!(bytes, 0x40)  # void
                push!(bytes, Opcode.LOOP)   # loop
                push!(bytes, 0x40)  # void

                # Check i < len
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(len_local))
                push!(bytes, Opcode.I32_GE_S)
                push!(bytes, Opcode.BR_IF)
                push!(bytes, 0x01)  # break if i >= len

                # c = s[i]
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(s_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(c_local))

                # Check if c is uppercase (65 <= c <= 90)
                # If so, convert to lowercase (c + 32)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(c_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x41)  # 65 = 'A'
                push!(bytes, Opcode.I32_GE_S)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(c_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x5a)  # 90 = 'Z'
                push!(bytes, Opcode.I32_LE_S)
                push!(bytes, Opcode.I32_AND)
                push!(bytes, Opcode.IF)
                push!(bytes, 0x40)  # void

                # Convert to lowercase: c = c + 32
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(c_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x20)  # 32
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(c_local))

                push!(bytes, Opcode.END)  # end if

                # result[i] = c
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(result_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(c_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_SET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))

                # i++
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(i_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(i_local))

                push!(bytes, Opcode.BR)
                push!(bytes, 0x00)  # continue loop

                push!(bytes, Opcode.END)  # end loop
                push!(bytes, Opcode.END)  # end block

                # Return result
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(result_local))

            # str_trim(s) -> String
            # Remove leading and trailing ASCII whitespace
            elseif name === :str_trim && length(args) == 1
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
                bytes = UInt8[]

                # Allocate locals
                s_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, ConcreteRef(str_type_idx))
                len_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                start_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                end_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                new_len_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                result_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, ConcreteRef(str_type_idx))
                c_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)

                # Store s and get length
                append!(bytes, compile_value(args[1], ctx))
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(s_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_LEN)
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(len_local))

                # Check for empty string
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.I32_EQ)
                push!(bytes, Opcode.IF)
                append!(bytes, encode_block_type(ConcreteRef(str_type_idx)))

                # Return empty string (the original s)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(s_local))

                push!(bytes, Opcode.ELSE)

                # start = 0 (0-based)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(start_local))

                # end = len - 1 (0-based, last valid index)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(len_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_SUB)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(end_local))

                # Find start: skip leading whitespace
                # while start < len && is_whitespace(s[start])
                push!(bytes, Opcode.BLOCK)
                push!(bytes, 0x40)
                push!(bytes, Opcode.LOOP)
                push!(bytes, 0x40)

                # Check start < len
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(start_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(len_local))
                push!(bytes, Opcode.I32_GE_S)
                push!(bytes, Opcode.BR_IF)
                push!(bytes, 0x01)  # break if start >= len

                # c = s[start]
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(s_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(start_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(c_local))

                # Check if whitespace: c == 32 || c == 9 || c == 10 || c == 13
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(c_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x20)  # space
                push!(bytes, Opcode.I32_EQ)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(c_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x09)  # tab
                push!(bytes, Opcode.I32_EQ)
                push!(bytes, Opcode.I32_OR)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(c_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x0a)  # newline
                push!(bytes, Opcode.I32_EQ)
                push!(bytes, Opcode.I32_OR)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(c_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x0d)  # carriage return
                push!(bytes, Opcode.I32_EQ)
                push!(bytes, Opcode.I32_OR)

                # If not whitespace, break
                push!(bytes, Opcode.I32_EQZ)
                push!(bytes, Opcode.BR_IF)
                push!(bytes, 0x01)

                # start++
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(start_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(start_local))

                push!(bytes, Opcode.BR)
                push!(bytes, 0x00)  # continue

                push!(bytes, Opcode.END)  # end loop
                push!(bytes, Opcode.END)  # end block

                # Check if all whitespace (start >= len)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(start_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(len_local))
                push!(bytes, Opcode.I32_GE_S)
                push!(bytes, Opcode.IF)
                append!(bytes, encode_block_type(ConcreteRef(str_type_idx)))

                # Return empty string
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
                append!(bytes, encode_leb128_unsigned(str_type_idx))

                push!(bytes, Opcode.ELSE)

                # Find end: skip trailing whitespace
                # while end >= start && is_whitespace(s[end])
                push!(bytes, Opcode.BLOCK)
                push!(bytes, 0x40)
                push!(bytes, Opcode.LOOP)
                push!(bytes, 0x40)

                # Check end >= start
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(end_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(start_local))
                push!(bytes, Opcode.I32_LT_S)
                push!(bytes, Opcode.BR_IF)
                push!(bytes, 0x01)  # break if end < start

                # c = s[end]
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(s_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(end_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(str_type_idx))
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(c_local))

                # Check if whitespace
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(c_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x20)
                push!(bytes, Opcode.I32_EQ)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(c_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x09)
                push!(bytes, Opcode.I32_EQ)
                push!(bytes, Opcode.I32_OR)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(c_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x0a)
                push!(bytes, Opcode.I32_EQ)
                push!(bytes, Opcode.I32_OR)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(c_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x0d)
                push!(bytes, Opcode.I32_EQ)
                push!(bytes, Opcode.I32_OR)

                # If not whitespace, break
                push!(bytes, Opcode.I32_EQZ)
                push!(bytes, Opcode.BR_IF)
                push!(bytes, 0x01)

                # end--
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(end_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_SUB)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(end_local))

                push!(bytes, Opcode.BR)
                push!(bytes, 0x00)

                push!(bytes, Opcode.END)  # end loop
                push!(bytes, Opcode.END)  # end block

                # new_len = end - start + 1
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(end_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(start_local))
                push!(bytes, Opcode.I32_SUB)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_ADD)
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(new_len_local))

                # Create result array
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(new_len_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
                append!(bytes, encode_leb128_unsigned(str_type_idx))
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(result_local))

                # array.copy: result[0..new_len] = s[start..start+new_len]
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(result_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)  # dst_offset = 0
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(s_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(start_local))  # src_offset = start
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(new_len_local))  # length
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_COPY)
                append!(bytes, encode_leb128_unsigned(str_type_idx))
                append!(bytes, encode_leb128_unsigned(str_type_idx))

                # Return result
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(result_local))

                push!(bytes, Opcode.END)  # end else (not all whitespace)
                push!(bytes, Opcode.END)  # end else (not empty)

            # ================================================================
            # WasmTarget array operations - arr_new, arr_get, arr_set!, arr_len
            # ================================================================

            # arr_new(Type, len) -> Vector{Type}
            elseif name === :arr_new && length(args) == 2
                # First arg is the type (compile-time constant)
                # Second arg is the length
                type_arg = args[1]
                elem_type = if type_arg isa Core.SSAValue
                    ctx.ssa_types[type_arg.id]
                elseif type_arg isa GlobalRef
                    getfield(type_arg.mod, type_arg.name)
                elseif type_arg isa Type
                    type_arg
                else
                    Int32  # Default
                end

                # Get or create array type
                arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

                # Clear previous arg compilation - we only need length
                bytes = UInt8[]

                # Compile length arg
                append!(bytes, compile_value(args[2], ctx))
                len_type = infer_value_type(args[2], ctx)
                if len_type === Int64 || len_type === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end

                # array.new_default creates array filled with default value (0)
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
                append!(bytes, encode_leb128_unsigned(arr_type_idx))

            # arr_get(arr, i) -> T
            elseif name === :arr_get && length(args) == 2
                # Args already compiled: arr, index
                # Need to adjust index to 0-based and emit array.get
                arr_type = infer_value_type(args[1], ctx)
                elem_type = eltype(arr_type)
                arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

                # Convert index to 0-based
                idx_type = infer_value_type(args[2], ctx)
                if idx_type === Int64 || idx_type === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_SUB)  # index - 1

                # array.get
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(arr_type_idx))

            # arr_set!(arr, i, val) -> Nothing
            elseif name === :arr_set! && length(args) == 3
                arr_type = infer_value_type(args[1], ctx)
                elem_type = eltype(arr_type)
                arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

                # Recompile in correct order for array.set: arr, index-1, val
                bytes = UInt8[]

                # Array ref
                append!(bytes, compile_value(args[1], ctx))

                # Index (convert to 0-based)
                append!(bytes, compile_value(args[2], ctx))
                idx_type = infer_value_type(args[2], ctx)
                if idx_type === Int64 || idx_type === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_SUB)

                # Value
                local val_bytes = compile_value(args[3], ctx)
                # PURE-045: If elem_type is Any (externref array), convert ref→externref
                if elem_type === Any
                    # Determine source value's wasm type to decide conversion
                    local arrset_src_wasm = nothing
                    if length(val_bytes) >= 2 && val_bytes[1] == Opcode.LOCAL_GET
                        local src_idx_v = 0
                        local shift_v = 0
                        local pos_v = 2
                        while pos_v <= length(val_bytes)
                            b = val_bytes[pos_v]
                            src_idx_v |= (Int(b & 0x7f) << shift_v)
                            shift_v += 7
                            pos_v += 1
                            (b & 0x80) == 0 && break
                        end
                        if pos_v - 1 == length(val_bytes)
                            # PURE-048: Use correct n_params offset for ctx.locals lookup
                            if src_idx_v >= ctx.n_params
                                local arr_idx_v = src_idx_v - ctx.n_params + 1
                                if arr_idx_v >= 1 && arr_idx_v <= length(ctx.locals)
                                    arrset_src_wasm = ctx.locals[arr_idx_v]
                                end
                            elseif src_idx_v < ctx.n_params && src_idx_v + 1 <= length(ctx.arg_types)
                                arrset_src_wasm = get_concrete_wasm_type(ctx.arg_types[src_idx_v + 1], ctx.mod, ctx.type_registry)
                            end
                        end
                    elseif length(val_bytes) >= 1 && (val_bytes[1] == Opcode.I32_CONST || val_bytes[1] == Opcode.I64_CONST || val_bytes[1] == Opcode.F32_CONST || val_bytes[1] == Opcode.F64_CONST)
                        # PURE-318: Check for GC_PREFIX — struct/array constants produce refs, not numerics
                        # PURE-325: LEB128-safe GC detection
                        if !has_ref_producing_gc_op(val_bytes)
                            arrset_src_wasm = I32  # treat constants as numeric
                        end
                    end
                    local is_numeric_val = arrset_src_wasm === I64 || arrset_src_wasm === I32 || arrset_src_wasm === F64 || arrset_src_wasm === F32
                    local is_already_externref_val = arrset_src_wasm === ExternRef
                    if is_numeric_val
                        emit_numeric_to_externref!(bytes, stmt.val, val_wasm, ctx)
                    else
                        append!(bytes, val_bytes)
                        # PURE-048: Skip extern_convert_any if value is already externref
                        if !is_already_externref_val
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                        end
                    end
                else
                    append!(bytes, val_bytes)
                end

                # array.set
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_SET)
                append!(bytes, encode_leb128_unsigned(arr_type_idx))

            # arr_len(arr) -> Int32
            elseif name === :arr_len && length(args) == 1
                # Arg already compiled, just emit array.len
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_LEN)

            # ================================================================
            # SimpleDict operations - hash table for Int32 keys/values
            # ================================================================

            # sd_new(capacity::Int32) -> SimpleDict
            elseif name === :sd_new && length(args) == 1
                bytes = UInt8[]

                # Register SimpleDict struct type
                register_struct_type!(ctx.mod, ctx.type_registry, SimpleDict)
                dict_info = ctx.type_registry.structs[SimpleDict]
                dict_type_idx = dict_info.wasm_type_idx

                # Get array type for Int32 arrays
                arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, Int32)

                # Compile capacity argument
                append!(bytes, compile_value(args[1], ctx))
                cap_type = infer_value_type(args[1], ctx)
                if cap_type === Int64 || cap_type === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end

                # Store capacity in a local so we can use it multiple times
                cap_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(cap_local))

                # Create keys array: array.new_default arr_type_idx
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
                append!(bytes, encode_leb128_unsigned(arr_type_idx))

                # Create values array
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(cap_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
                append!(bytes, encode_leb128_unsigned(arr_type_idx))

                # Create slots array
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(cap_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
                append!(bytes, encode_leb128_unsigned(arr_type_idx))

                # Push count = 0
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)

                # Push capacity
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(cap_local))

                # struct.new SimpleDict (fields: keys, values, slots, count, capacity)
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.STRUCT_NEW)
                append!(bytes, encode_leb128_unsigned(dict_type_idx))

            # sd_length(d::SimpleDict) -> Int32
            elseif name === :sd_length && length(args) == 1
                # Args already compiled (d is on stack)
                # Get the count field (index 3)
                register_struct_type!(ctx.mod, ctx.type_registry, SimpleDict)
                dict_info = ctx.type_registry.structs[SimpleDict]
                dict_type_idx = dict_info.wasm_type_idx

                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.STRUCT_GET)
                append!(bytes, encode_leb128_unsigned(dict_type_idx))
                append!(bytes, encode_leb128_unsigned(3))  # count is field 3 (0-indexed)

            # sd_haskey(d::SimpleDict, key::Int32) -> Bool
            elseif name === :sd_haskey && length(args) == 2
                # Implement linear probing to find key
                bytes = compile_sd_find_slot(args, ctx)
                # Result is slot index (positive if found, negative if not found, 0 if full)
                # Convert to bool: slot > 0
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.I32_GT_S)

            # sd_get(d::SimpleDict, key::Int32) -> Int32
            elseif name === :sd_get && length(args) == 2
                # Find slot, then get value
                bytes = compile_sd_find_slot(args, ctx)

                # Store slot in local
                slot_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(slot_local))

                # Check if found (slot > 0)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.I32_GT_S)

                # if found: get value, else: return 0
                push!(bytes, Opcode.IF)
                push!(bytes, 0x7F)  # result type i32

                # Get dict reference again for struct.get
                append!(bytes, compile_value(args[1], ctx))
                register_struct_type!(ctx.mod, ctx.type_registry, SimpleDict)
                dict_info = ctx.type_registry.structs[SimpleDict]
                dict_type_idx = dict_info.wasm_type_idx
                arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, Int32)

                # Get values array (field 1)
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.STRUCT_GET)
                append!(bytes, encode_leb128_unsigned(dict_type_idx))
                append!(bytes, encode_leb128_unsigned(1))  # values field

                # Get index (slot - 1 for 0-based)
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(slot_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_SUB)

                # array.get
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(arr_type_idx))

                push!(bytes, Opcode.ELSE)
                # Not found - return 0
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.END)

            # sd_set!(d::SimpleDict, key::Int32, value::Int32) -> Nothing
            elseif name === :sd_set! && length(args) == 3
                bytes = compile_sd_set(args, ctx)

            # ================================================================
            # StringDict operations - hash table for String keys, Int32 values
            # ================================================================

            # sdict_new(capacity::Int32) -> StringDict
            elseif name === :sdict_new && length(args) == 1
                bytes = UInt8[]

                # Register StringDict struct type
                register_struct_type!(ctx.mod, ctx.type_registry, StringDict)
                dict_info = ctx.type_registry.structs[StringDict]
                dict_type_idx = dict_info.wasm_type_idx

                # Get array types
                str_ref_arr_type_idx = get_string_ref_array_type!(ctx.mod, ctx.type_registry)
                i32_arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, Int32)
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

                # Compile capacity argument
                append!(bytes, compile_value(args[1], ctx))
                cap_type = infer_value_type(args[1], ctx)
                if cap_type === Int64 || cap_type === Int
                    push!(bytes, Opcode.I32_WRAP_I64)
                end

                # Store capacity in local
                cap_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(cap_local))

                # Create keys array (array of string refs, initialized with empty strings)
                # First create empty string to use as default
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)  # empty string length = 0
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
                append!(bytes, encode_leb128_unsigned(str_type_idx))

                # Store empty string for array.new_fixed
                empty_str_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, ConcreteRef(str_type_idx))
                push!(bytes, Opcode.LOCAL_SET)
                append!(bytes, encode_leb128_unsigned(empty_str_local))

                # Create keys array with capacity elements, filled with empty string ref
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(empty_str_local))
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(cap_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW)
                append!(bytes, encode_leb128_unsigned(str_ref_arr_type_idx))

                # Create values array
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(cap_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
                append!(bytes, encode_leb128_unsigned(i32_arr_type_idx))

                # Create slots array
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(cap_local))
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
                append!(bytes, encode_leb128_unsigned(i32_arr_type_idx))

                # Push count = 0
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)

                # Push capacity
                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(cap_local))

                # struct.new StringDict (fields: keys, values, slots, count, capacity)
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.STRUCT_NEW)
                append!(bytes, encode_leb128_unsigned(dict_type_idx))

            # sdict_length(d::StringDict) -> Int32
            elseif name === :sdict_length && length(args) == 1
                register_struct_type!(ctx.mod, ctx.type_registry, StringDict)
                dict_info = ctx.type_registry.structs[StringDict]
                dict_type_idx = dict_info.wasm_type_idx

                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.STRUCT_GET)
                append!(bytes, encode_leb128_unsigned(dict_type_idx))
                append!(bytes, encode_leb128_unsigned(3))  # count is field 3

            # sdict_haskey(d::StringDict, key::String) -> Bool
            elseif name === :sdict_haskey && length(args) == 2
                bytes = compile_sdict_find_slot(args, ctx)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.I32_GT_S)

            # sdict_get(d::StringDict, key::String) -> Int32
            elseif name === :sdict_get && length(args) == 2
                bytes = compile_sdict_find_slot(args, ctx)

                slot_local = ctx.n_params + length(ctx.locals)
                push!(ctx.locals, I32)
                push!(bytes, Opcode.LOCAL_TEE)
                append!(bytes, encode_leb128_unsigned(slot_local))

                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.I32_GT_S)

                push!(bytes, Opcode.IF)
                push!(bytes, 0x7F)  # i32 result

                # Get dict again and get values[slot-1]
                append!(bytes, compile_value(args[1], ctx))
                register_struct_type!(ctx.mod, ctx.type_registry, StringDict)
                dict_info = ctx.type_registry.structs[StringDict]
                dict_type_idx = dict_info.wasm_type_idx
                i32_arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, Int32)

                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.STRUCT_GET)
                append!(bytes, encode_leb128_unsigned(dict_type_idx))
                append!(bytes, encode_leb128_unsigned(1))  # values field

                push!(bytes, Opcode.LOCAL_GET)
                append!(bytes, encode_leb128_unsigned(slot_local))
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x01)
                push!(bytes, Opcode.I32_SUB)

                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_GET)
                append!(bytes, encode_leb128_unsigned(i32_arr_type_idx))

                push!(bytes, Opcode.ELSE)
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)
                push!(bytes, Opcode.END)

            # sdict_set!(d::StringDict, key::String, value::Int32) -> Nothing
            elseif name === :sdict_set! && length(args) == 3
                bytes = compile_sdict_set(args, ctx)

            # Math domain error functions - these would normally throw, but in WASM we return NaN
            elseif name === :sin_domain_error || name === :cos_domain_error ||
                   name === :tan_domain_error || name === :asin_domain_error ||
                   name === :acos_domain_error || name === :log_domain_error ||
                   name === :sqrt_domain_error
                # These functions throw in Julia but we return NaN for graceful degradation
                # Return type is Union{} (never returns) but we need to produce a value
                # Push NaN for float domain errors
                push!(bytes, Opcode.F64_CONST)
                nan_bytes = reinterpret(UInt8, [NaN])
                append!(bytes, nan_bytes)

            # ================================================================
            # WASM-055: Base.string dispatch to int_to_string
            # Base.string(n::Int) internally calls Base.#string#530(base, pad, string, n)
            # We intercept this and redirect to WasmTarget.int_to_string
            # ================================================================
            elseif name === Symbol("#string#530") && length(args) >= 4
                # #string#530(base::Int64, pad::Int64, ::typeof(string), value)
                # The actual value to convert is the last argument (args[4])
                value_arg = args[4]
                value_type = infer_value_type(value_arg, ctx)

                # Check if we're converting an integer type
                if value_type === Int32 || value_type === Int64 ||
                   value_type === UInt32 || value_type === UInt64 ||
                   value_type === Int16 || value_type === UInt16 ||
                   value_type === Int8 || value_type === UInt8

                    # Clear the bytes (args were already pushed)
                    bytes = UInt8[]

                    # Check if int_to_string is in the function registry
                    int_to_string_info = nothing
                    if ctx.func_registry !== nothing
                        # Try to find int_to_string with Int32 signature
                        try
                            int_to_string_func = getfield(WasmTarget, :int_to_string)
                            int_to_string_info = get_function(ctx.func_registry, int_to_string_func, (Int32,))
                        catch
                            # Function not found
                        end
                    end

                    if int_to_string_info !== nothing
                        # int_to_string is in registry - call it
                        # Compile the value argument, converting to Int32 if needed
                        append!(bytes, compile_value(value_arg, ctx))

                        # Convert to Int32 if needed
                        if value_type === Int64
                            push!(bytes, Opcode.I32_WRAP_I64)
                        elseif value_type === UInt32 || value_type === UInt64
                            # Treat as signed for string conversion
                            if value_type === UInt64
                                push!(bytes, Opcode.I32_WRAP_I64)
                            end
                        elseif value_type !== Int32
                            # Smaller types - extend to i32
                            # Already handled by compile_value which produces correct type
                        end

                        # Call int_to_string
                        push!(bytes, Opcode.CALL)
                        append!(bytes, encode_leb128_unsigned(int_to_string_info.wasm_idx))
                    else
                        # int_to_string not in registry - provide helpful error
                        error("Base.string(::$(value_type)) requires int_to_string in compile_multi. " *
                              "Add WasmTarget.int_to_string and WasmTarget.digit_to_str to your function list.")
                    end
                else
                    # Non-integer type - not yet supported
                    error("Base.string(::$(value_type)) not yet supported. " *
                          "Supported types: Int32, Int64, UInt32, UInt64, Int16, UInt16, Int8, UInt8")
                end

            # ================================================================
            # Julia 1.11+ Memory API: Core.memoryref
            # Creates MemoryRef from Memory - in WasmGC this is a no-op
            # ================================================================
            elseif name === :memoryref && length(args) == 1
                # Core.memoryref(memory::Memory{T}) -> MemoryRef{T}
                # In WasmGC, Memory and MemoryRef are both the array reference
                # Clear args bytes (already pushed) and re-compile just the memory arg
                bytes = UInt8[]
                append!(bytes, compile_value(args[1], ctx))

            # ================================================================
            # Error constructors - these are typically followed by throw
            # In WASM we just emit unreachable
            # ================================================================
            elseif name === :BoundsError || name === :ArgumentError || name === :TypeError ||
                   name === :DomainError || name === :OverflowError || name === :DivideError ||
                   name === :InexactError
                # Error constructors - emit unreachable
                bytes = UInt8[]  # Clear any pushed args
                push!(bytes, Opcode.UNREACHABLE)
                ctx.last_stmt_was_stub = true  # PURE-908

            # ================================================================
            # PURE-322: SubString — create proper SubString struct
            # SubString(str, start, stop) does UTF-8 thisind validation that
            # uses jl_string_ptr/pointerref (unsupported in WasmGC). Since
            # WasmGC strings are array<i32> (char arrays, not byte arrays),
            # every index is valid. Create struct: {string, offset, ncodeunits}
            # ================================================================
            elseif name === :SubString
                bytes = UInt8[]  # Clear accumulated arg bytes
                if length(args) >= 3
                    str_arg = args[1]
                    start_arg = args[2]
                    stop_arg = args[3]
                    # Field 0: string (ref null array<i32>)
                    append!(bytes, compile_value(str_arg, ctx))
                    # Field 1: offset = start - 1
                    append!(bytes, compile_value(start_arg, ctx))
                    push!(bytes, Opcode.I64_CONST, 0x01)
                    push!(bytes, Opcode.I64_SUB)
                    # Field 2: ncodeunits = stop - start + 1
                    append!(bytes, compile_value(stop_arg, ctx))
                    append!(bytes, compile_value(start_arg, ctx))
                    push!(bytes, Opcode.I64_SUB)
                    push!(bytes, Opcode.I64_CONST, 0x01)
                    push!(bytes, Opcode.I64_ADD)
                    # Emit struct.new for SubString type
                    substr_wasm = get_concrete_wasm_type(SubString{String}, ctx.mod, ctx.type_registry)
                    if substr_wasm isa ConcreteRef
                        push!(bytes, Opcode.GC_PREFIX, Opcode.STRUCT_NEW)
                        append!(bytes, encode_leb128_unsigned(substr_wasm.type_idx))
                    end
                elseif length(args) >= 1
                    # SubString(str) — view of entire string
                    str_arg = args[1]
                    append!(bytes, compile_value(str_arg, ctx))
                    push!(bytes, Opcode.I64_CONST, 0x00)  # offset = 0
                    # ncodeunits = array.len(str)
                    append!(bytes, compile_value(str_arg, ctx))
                    push!(bytes, Opcode.GC_PREFIX, Opcode.ARRAY_LEN)
                    push!(bytes, Opcode.I64_EXTEND_I32_S)
                    # Emit struct.new
                    substr_wasm = get_concrete_wasm_type(SubString{String}, ctx.mod, ctx.type_registry)
                    if substr_wasm isa ConcreteRef
                        push!(bytes, Opcode.GC_PREFIX, Opcode.STRUCT_NEW)
                        append!(bytes, encode_leb128_unsigned(substr_wasm.type_idx))
                    end
                end

            # ================================================================
            # PURE-322: _thisind_continued / _nextind_continued — identity
            # In WasmGC, strings are array<i32> (char codes), so every
            # character index is valid (no multi-byte encoding).
            # ================================================================
            elseif (name === :_thisind_continued || name === Symbol("#_thisind_continued#_thisind_str##0")) && length(args) >= 2
                bytes = UInt8[]
                # Closure form: (closure, string, index, len) → return index
                if length(args) >= 3
                    append!(bytes, compile_value(args[2], ctx))
                else
                    append!(bytes, compile_value(args[1], ctx))
                end

            elseif (name === :_nextind_continued || name === Symbol("#_nextind_continued#_nextind_str##0")) && length(args) >= 2
                bytes = UInt8[]
                # nextind(s, i) = i + 1 in WasmGC
                if length(args) >= 3
                    append!(bytes, compile_value(args[2], ctx))
                else
                    append!(bytes, compile_value(args[1], ctx))
                end
                push!(bytes, Opcode.I64_CONST, 0x01)
                push!(bytes, Opcode.I64_ADD)

            # ================================================================
            # PURE-004: Base.string dispatch for Float32/Float64
            # When Julia compiles string(x::Float32), it invokes the Ryu method
            # We intercept and redirect to our simpler float_to_string
            # ================================================================
            elseif name === :string && length(args) == 1
                value_arg = args[1]
                value_type = infer_value_type(value_arg, ctx)

                if value_type === Float32 || value_type === Float64
                    # Clear bytes - recompile the argument
                    bytes = UInt8[]

                    # Look up float_to_string in the function registry
                    float_to_string_info = nothing
                    if ctx.func_registry !== nothing
                        try
                            float_to_string_func = getfield(WasmTarget, :float_to_string)
                            float_to_string_info = get_function(ctx.func_registry, float_to_string_func, (Float32,))
                        catch
                            # Function not found
                        end
                    end

                    if float_to_string_info !== nothing
                        # Compile the value argument
                        append!(bytes, compile_value(value_arg, ctx))

                        # Convert Float64 to Float32 if needed (our float_to_string takes Float32)
                        if value_type === Float64
                            push!(bytes, 0xB6)  # f32.demote_f64
                        end

                        # Call float_to_string
                        push!(bytes, Opcode.CALL)
                        append!(bytes, encode_leb128_unsigned(float_to_string_info.wasm_idx))
                    else
                        error("Base.string(::$(value_type)) requires float_to_string in compile_multi. " *
                              "Add WasmTarget.float_to_string, WasmTarget.int_to_string, and WasmTarget.digit_to_str to your function list.")
                    end
                elseif value_type === Int32 || value_type === Int64 ||
                       value_type === UInt32 || value_type === UInt64 ||
                       value_type === Int16 || value_type === UInt16 ||
                       value_type === Int8 || value_type === UInt8
                    # Integer types - redirect to int_to_string
                    bytes = UInt8[]

                    int_to_string_info = nothing
                    if ctx.func_registry !== nothing
                        try
                            int_to_string_func = getfield(WasmTarget, :int_to_string)
                            int_to_string_info = get_function(ctx.func_registry, int_to_string_func, (Int32,))
                        catch
                            # Function not found
                        end
                    end

                    if int_to_string_info !== nothing
                        append!(bytes, compile_value(value_arg, ctx))

                        # Convert to Int32 if needed
                        if value_type === Int64
                            push!(bytes, Opcode.I32_WRAP_I64)
                        elseif value_type === UInt64
                            push!(bytes, Opcode.I32_WRAP_I64)
                        end

                        push!(bytes, Opcode.CALL)
                        append!(bytes, encode_leb128_unsigned(int_to_string_info.wasm_idx))
                    else
                        error("Base.string(::$(value_type)) requires int_to_string in compile_multi. " *
                              "Add WasmTarget.int_to_string and WasmTarget.digit_to_str to your function list.")
                    end
                else
                    error("Base.string(::$(value_type)) not yet supported. " *
                          "Supported types: Float32, Float64, Int32, Int64, UInt32, UInt64, Int16, UInt16, Int8, UInt8")
                end

            # PURE-1102: Error-throwing functions from Base (used by pop!, resize!, etc.)
            # Emit throw (catchable) instead of unreachable (trap)
            elseif name === :_throw_argerror || name === :throw_boundserror ||
                   name === :throw || name === :rethrow ||
                   name === :_throw_not_readable || name === :_throw_not_writable
                ensure_exception_tag!(ctx.mod)
                push!(bytes, Opcode.THROW)
                append!(bytes, encode_leb128_unsigned(0))  # tag index 0
                ctx.last_stmt_was_stub = true  # PURE-908

            # Handle truncate (IOBuffer resize) — no-op in WasmGC
            # Returns the IOBuffer itself
            elseif name === :truncate
                # First arg is the IOBuffer — just leave it on stack
                # (already compiled by the args loop above)
                # No-op: WasmGC arrays don't need explicit truncation

            # Handle getindex_continued (multi-byte string char access)
            # In WasmGC, strings are array<i32> so indexing is direct
            # getindex_continued(s, i, u) returns Char from byte continuation
            # We just return the character value as i32
            elseif name === :getindex_continued
                # Args: (string, index::Int64, partial_char::UInt32)
                # Just return the partial char (u) as the character — simplified
                # Drop string and index, keep u
                bytes = UInt8[]
                append!(bytes, compile_value(args[3], ctx))  # u::UInt32 is the char

            # Handle print_to_string (used in string interpolation / error messages)
            # Returns an empty string since this is typically used for error message construction
            elseif name === :print_to_string
                # Discard all compiled argument bytes (including literal strings on stack)
                # The argument loop compiled all args (Strings, SSAValues, etc.) into bytes.
                # We must discard ALL of them, not just SSAValues without locals.
                bytes = UInt8[]
                # Return empty string (empty byte array)
                type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_FIXED)
                append!(bytes, encode_leb128_unsigned(type_idx))
                append!(bytes, encode_leb128_unsigned(0))  # 0 elements

            # PURE-1102: Error/throw functions — emit throw (catchable) instead of unreachable (trap)
            elseif name === :error || name === :throw || name === :throw_boundserror ||
                   name === :ArgumentError || name === :AssertionError ||
                   name === :KeyError || name === :ErrorException ||
                   name === :BoundsError || name === :MethodError
                ensure_exception_tag!(ctx.mod)
                push!(bytes, Opcode.THROW)
                append!(bytes, encode_leb128_unsigned(0))  # tag index 0
                ctx.last_stmt_was_stub = true  # PURE-908

            # Handle JuliaSyntax internal functions that have complex implementations
            # These are intercepted and compiled as simplified stubs
            elseif name === :parse_float_literal
                # PURE-5002: Float literal parsing returns Tuple{Float64, Symbol}.
                # The original uses ccall(:jl_strtod_c) which can't compile to Wasm.
                # Return (0.0, :ok) as a proper Tuple struct — AST structure is correct,
                # float VALUES will be 0.0 (acceptable for Stage 1 parse verification).
                bytes = UInt8[]
                ret_type = Tuple{Float64, Symbol}
                if !haskey(ctx.type_registry.structs, ret_type)
                    register_tuple_type!(ctx.mod, ctx.type_registry, ret_type)
                end
                tuple_info = ctx.type_registry.structs[ret_type]
                # Field 1: Float64 = 0.0 (f64.const 0.0)
                push!(bytes, Opcode.F64_CONST)
                append!(bytes, reinterpret(UInt8, [Float64(0.0)]))
                # Field 2: Symbol = :ok (empty string array as placeholder)
                str_arr_type = get_string_array_type!(ctx.mod, ctx.type_registry)
                # Push ":ok" as byte array [0x6f, 0x6b]
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(0x6f)))  # 'o'
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int64(0x6b)))  # 'k'
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.ARRAY_NEW_FIXED)
                append!(bytes, encode_leb128_unsigned(str_arr_type))
                append!(bytes, encode_leb128_unsigned(2))  # 2 chars
                # struct.new Tuple{Float64, Symbol}
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.STRUCT_NEW)
                append!(bytes, encode_leb128_unsigned(tuple_info.wasm_type_idx))

            elseif name === :parse_int_literal ||
                   name === :parse_uint_literal
                # Int/uint literal parsing — return a default value
                # These parse strings to numeric values; simplified to return 0
                push!(bytes, Opcode.I32_CONST)
                push!(bytes, 0x00)

            # Handle unalias — identity in WasmGC (arrays never alias)
            # unalias(dest, src) checks if dest and src share backing memory
            # and copies src if they do. In WasmGC, every array.new creates a
            # distinct GC object, so aliasing is impossible. Just return src.
            elseif name === :unalias
                # Discard accumulated argument bytes and re-compile just src (arg 2)
                bytes = UInt8[]
                src_arg = expr.args[4]  # args: [mi, func_ref, dest, src]
                append!(bytes, compile_value(src_arg, ctx))

            # Handle push!/pop! growth closures from Base (_growend!)
            # These are generated when Julia inlines push! and need to resize the array
            # The closure name starts with # (e.g., #_growend!##0)
            # For WasmGC, we implement array growth inline:
            # 1. Allocate new array with 2x capacity
            # 2. Copy elements from old array using array.copy
            # 3. Update the vector's ref field
            elseif meth.module === Base && startswith(string(name), "#")
                # Clear any accumulated bytes from argument compilation
                bytes = UInt8[]

                # Drop the closure object from the stack if it's there
                func_ref = expr.args[2]
                if func_ref isa Core.SSAValue
                    if !haskey(ctx.ssa_locals, func_ref.id) && !haskey(ctx.phi_locals, func_ref.id)
                        push!(bytes, Opcode.DROP)
                    end
                end

                # Find the vector being grown from the :new expression
                # The closure's first captured field is the vector
                vec_arg = nothing
                vec_julia_type = nothing
                if func_ref isa Core.SSAValue
                    new_stmt = ctx.code_info.code[func_ref.id]
                    if new_stmt isa Expr && new_stmt.head === :new && length(new_stmt.args) >= 2
                        vec_arg = new_stmt.args[2]  # First captured field = vector
                    end
                end

                # Get the vector Julia type from the closure type's first field
                closure_type = mi.specTypes.parameters[1]
                if length(fieldnames(closure_type)) >= 1
                    vec_julia_type = fieldtype(closure_type, 1)
                end

                # Emit array growth code if we can determine the vector type
                ssa_type_here = get(ctx.ssa_types, idx, Any)
                has_local_here = haskey(ctx.ssa_locals, idx)
                vec_in_registry = vec_julia_type !== nothing && haskey(ctx.type_registry.structs, vec_julia_type)
                if vec_arg !== nothing && vec_julia_type !== nothing &&
                   vec_julia_type <: AbstractVector && haskey(ctx.type_registry.structs, vec_julia_type)

                    vec_info = ctx.type_registry.structs[vec_julia_type]
                    vec_type_idx = vec_info.wasm_type_idx
                    elem_type = eltype(vec_julia_type)
                    arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

                    # Allocate scratch locals for array growth
                    old_arr_local = allocate_local!(ctx, ConcreteRef(arr_type_idx, true))
                    new_arr_local = allocate_local!(ctx, ConcreteRef(arr_type_idx, true))
                    old_cap_local = allocate_local!(ctx, I32)
                    vec_scratch_local = allocate_local!(ctx, ConcreteRef(vec_type_idx, true))

                    # 1. Get the vector and store in local
                    append!(bytes, compile_value(vec_arg, ctx))
                    push!(bytes, Opcode.GC_PREFIX, Opcode.REF_CAST_NULL)
                    # PURE-045: heap type for ref.cast must use signed LEB128
                    append!(bytes, encode_leb128_signed(Int64(vec_type_idx)))
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(vec_scratch_local))

                    # 2. Get old backing array and store
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(vec_scratch_local))
                    push!(bytes, Opcode.GC_PREFIX, Opcode.STRUCT_GET)
                    append!(bytes, encode_leb128_unsigned(vec_type_idx))
                    append!(bytes, encode_leb128_unsigned(0))  # field 0 = array ref
                    push!(bytes, Opcode.GC_PREFIX, Opcode.REF_CAST_NULL)
                    # PURE-045: heap type for ref.cast must use signed LEB128
                    append!(bytes, encode_leb128_signed(Int64(arr_type_idx)))
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(old_arr_local))

                    # 3. Get old capacity
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(old_arr_local))
                    push!(bytes, Opcode.GC_PREFIX, Opcode.ARRAY_LEN)
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(old_cap_local))

                    # 4. New capacity = max(old_cap * 2, old_cap + 4)
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(old_cap_local))
                    push!(bytes, Opcode.I32_CONST)
                    append!(bytes, encode_leb128_signed(Int64(2)))
                    push!(bytes, Opcode.I32_MUL)
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(old_cap_local))
                    push!(bytes, Opcode.I32_CONST)
                    append!(bytes, encode_leb128_signed(Int64(4)))
                    push!(bytes, Opcode.I32_ADD)
                    # select: [val_true, val_false, cond] -> val_true if cond!=0
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(old_cap_local))
                    push!(bytes, Opcode.I32_CONST)
                    append!(bytes, encode_leb128_signed(Int64(2)))
                    push!(bytes, Opcode.I32_MUL)
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(old_cap_local))
                    push!(bytes, Opcode.I32_CONST)
                    append!(bytes, encode_leb128_signed(Int64(4)))
                    push!(bytes, Opcode.I32_ADD)
                    push!(bytes, Opcode.I32_GE_S)
                    push!(bytes, Opcode.SELECT)

                    # 5. Create new array with new capacity
                    push!(bytes, Opcode.GC_PREFIX, Opcode.ARRAY_NEW_DEFAULT)
                    append!(bytes, encode_leb128_unsigned(arr_type_idx))
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(new_arr_local))

                    # 6. Copy old elements: array.copy [dst, dst_off, src, src_off, len]
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(new_arr_local))
                    push!(bytes, Opcode.I32_CONST, 0x00)  # dst_off = 0
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(old_arr_local))
                    push!(bytes, Opcode.I32_CONST, 0x00)  # src_off = 0
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(old_cap_local))
                    push!(bytes, Opcode.GC_PREFIX, Opcode.ARRAY_COPY)
                    append!(bytes, encode_leb128_unsigned(arr_type_idx))
                    append!(bytes, encode_leb128_unsigned(arr_type_idx))

                    # 7. Update vector's backing array field
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(vec_scratch_local))
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(new_arr_local))
                    push!(bytes, Opcode.GC_PREFIX, Opcode.STRUCT_SET)
                    append!(bytes, encode_leb128_unsigned(vec_type_idx))
                    append!(bytes, encode_leb128_unsigned(0))  # field 0 = array ref

                    # 8. Growth code is side-effect only — no wasm value produced.
                    #    Mark the SSA type as Nothing so statement_produces_wasm_value
                    #    returns false and flow generators don't emit DROP.
                    ctx.ssa_types[idx] = Nothing
                    # Also remove the SSA local to prevent compile_statement's
                    # safety check from replacing the growth code with ref.null.
                    # The growth code starts with local.get of the vector, which
                    # has a different type than the MemoryRef SSA local — without
                    # this delete, the safety check sees a type mismatch and
                    # replaces all growth code with a type-safe default.
                    delete!(ctx.ssa_locals, idx)

                else
                    # Fallback: can't determine vector type — emit unreachable
                    push!(bytes, Opcode.UNREACHABLE)
                    ctx.last_stmt_was_stub = true  # PURE-908
                end

            elseif name === :Symbol && length(args) == 1
                # Symbol(s::String) — in WasmGC, Symbol IS String (both are byte arrays).
                # The argument String is already on the stack from arg compilation above.
                # Just pass it through — no conversion needed.
                # (args were already compiled and pushed to `bytes` above)

            # PURE-6024: typeintersect(T1, T2) — C runtime function used in tuple convert.
            # With unoptimized IR (may_optimize=false), the convert inlines typeintersect.
            # Evaluate at compile time when both args are constant Type values.
            elseif name === :typeintersect && length(args) >= 2 && args[1] isa Type && args[2] isa Type
                # Evaluate at compile time — pure function with constant args
                result_type = typeintersect(args[1], args[2])
                bytes = UInt8[]  # Clear pre-pushed args
                global_idx = get_type_constant_global!(ctx.mod, ctx.type_registry, result_type)
                push!(bytes, Opcode.GLOBAL_GET)
                append!(bytes, encode_leb128_unsigned(global_idx))
                # Convert concrete ref to externref (Type values are externref in general context)
                push!(bytes, Opcode.GC_PREFIX)
                push!(bytes, Opcode.EXTERN_CONVERT_ANY)

            # PURE-6024: _tuple_error — error function in tuple convert dead code path.
            # Emit throw (catchable) instead of unreachable (trap).
            elseif name === :_tuple_error
                bytes = UInt8[]  # Clear pre-pushed args
                ensure_exception_tag!(ctx.mod)
                push!(bytes, Opcode.THROW)
                append!(bytes, encode_leb128_unsigned(0))
                ctx.last_stmt_was_stub = true  # PURE-908

            else
                # Unknown method — emit unreachable (will trap at runtime)
                # This allows compilation to succeed for code paths that
                # don't actually reach these methods.
                @warn "Stubbing unsupported method: $name (will trap at runtime) (in func_$(ctx.func_idx))" expr=expr idx=idx mi_info=(mi !== nothing ? string(mi.specTypes) : "nothing")
                push!(bytes, Opcode.UNREACHABLE)
                ctx.last_stmt_was_stub = true  # PURE-908
            end
        end
    end

    return bytes
end

