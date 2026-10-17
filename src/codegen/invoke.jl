# parity(pkg/dart2wasm/lib/code_generator.dart:1668 CodeGenerator.visitStaticInvocation)
_invoke_arg_static_type(arg, ctx::AbstractCompilationContext)::Union{Type, Core.TypeofVararg} =
    nir_const(arg) isa Type ? Core.Typeof(nir_const(arg)) : value_type(ctx, arg)


"""
Compile an invoke expression (method invocation) — dart visitor shape:
emits the invoke INTO the caller's builder. Its callee is the function the plan compiles its
MethodInstance to (`get_function_by_mi`), as dart's static invocation calls its target's one
function; the only other lowerings are the identity-keyed ones before it (a host binding, a
signal, a closed-world metadata operation, `Core.eval`'s rejection). A MethodInstance with no
function rejects at the statement.
The interior accumulates into a FRAGMENT builder `fb`; exits merge typed.
formal(dev/formal/README.md): the `:invoke` callee is one lookup by MethodInstance, no algorithm.
parity(pkg/dart2wasm/lib/code_generator.dart:1668 CodeGenerator.visitStaticInvocation)
"""
function compile_invoke!(b::InstrBuilder, node::NirInvoke, idx::Int, ctx::AbstractCompilationContext)::InstrBuilder
    fb = _ctx_builder(ctx, "compile_invoke.frag")
    args = node.operands

    # Early skip check — before compiling arguments.
    # Skipped statements emit nothing (NOP). This prevents argument values
    # (e.g., string constants for js() calls) from being compiled to WASM.
    if idx in ctx.skip_stmts
        return append_builder!(b, fb)
    end

    # Declaratively bound invoke — target may be an import or another root.
    # Its already-declared module signature is authoritative, and arguments go
    # through the same typed emission/coercion channel as ordinary invokes.
    if haskey(ctx.invoke_imports, idx)
        target_idx = ctx.invoke_imports[idx]
        bii = _ctx_builder(ctx, "compile_invoke")
        params = _function_type(ctx.mod, target_idx).params
        selected = get(ctx.invoke_arguments, idx, collect(eachindex(args)))
        all(i -> 1 <= i <= length(args), selected) || throw(ArgumentError(
            "bound invoke $idx has an out-of-range argument projection"))
        projected_args = Any[args[i] for i in selected]
        length(projected_args) == length(params) || throw(ArgumentError(
            "bound invoke $idx supplies $(length(projected_args)) arguments to a $(length(params))-parameter target"))
        for (arg, expected) in zip(projected_args, params)
            jt = _invoke_arg_static_type(arg, ctx)
            emit_value!(bii, arg, ctx, expected;
                        from_julia=(jt isa Type && isconcretetype(jt)) ? jt : nothing)
        end
        emit_direct_call!(bii, ctx.mod, ctx.type_registry, target_idx)
        return append_builder!(b, bii)
    end


    # Check for signal substitution (Therapy.jl closures)
    # When calling through a captured signal getter/setter, emit global.get/set directly
    func_ref = node.callee
    if func_ref isa NirSSA
        ssa_id = func_ref.id
        # Signal getter: no args, returns the signal value
        if haskey(ctx.signal_ssa_getters, ssa_id) && isempty(args)
            global_idx = ctx.signal_ssa_getters[ssa_id]
            bsg = _ctx_builder(ctx, "compile_invoke")
            global_get!(bsg, global_idx)
            return append_builder!(b, bsg)
        end
        # Signal setter: one arg, sets the signal value
        if haskey(ctx.signal_ssa_setters, ssa_id) && length(args) == 1
            global_idx = ctx.signal_ssa_setters[ssa_id]
            bss2 = _ctx_builder(ctx, "compile_invoke")
            # Compile the argument (the new value)
            emit_value!(bss2, args[1], ctx, ctx.mod.globals[Int(global_idx) + 1].valtype)   # step4
            # Store to global
            global_set!(bss2, global_idx)

            # Inject DOM update calls for this signal (Therapy.jl reactive updates)
            if haskey(ctx.dom_bindings, global_idx)
                # Get global's type for conversion
                global_type = ctx.mod.globals[global_idx + 1].valtype

                for (import_idx, const_args) in ctx.dom_bindings[global_idx]
                    # Push constant arguments (e.g., hydration key)
                    for arg in const_args
                        i32_const!(bss2, Int(arg))
                    end
                    # Push the signal value (re-read from global)
                    global_get!(bss2, global_idx)
                    # Convert to f64 for DOM imports (all DOM imports expect f64)
                    emit_convert_to_f64!(bss2, global_type)
                    # Call the DOM import function
                    emit_direct_call!(bss2, ctx.mod, ctx.type_registry, import_idx)
                end
            end

            # Setter returns the value in Therapy.jl, so re-read it
            global_get!(bss2, global_idx)
            return append_builder!(b, bss2)
        end
    end

    # The MethodInstance the :invoke names; its function is the callee
    mi = node.mi

    # The closed-world metadata operations trim_compile_plan leaves out of the function
    # list (check_world_bounded, isvisible and their overlays) lower at an :invoke
    # through the same identity-keyed BUILTIN_LOWERINGS entry as at a :call — the
    # callee OBJECT the boundary resolved selects it, never its name.
    local _cw_f = _nir_callee_object(node.callee)
    if _cw_f === Base.check_world_bounded || _cw_f === _closed_world_type_bounds ||
       _cw_f === Base.isvisible || _cw_f === _closed_world_isvisible
        local _cw_r = BUILTIN_LOWERINGS[_cw_f](b, fb, ctx, node, idx, args, _cw_f)
        _cw_r !== nothing && return _cw_r
    end

    # Host-capability / dynamic-reflection reject — caught HERE, at MethodInstance
    # identity, before any recursion into the callee's body (dart2wasm has no
    # equivalent: `Core.eval` is outside a closed-world compilation target).
    # `Core.eval`'s body is runtime reflection (world-age bump + toplevel eval) that
    # WT tries to recurse into and partially compile, surfacing as an internal
    # StackImbalanceError on the OUTER call's result type instead of a classified
    # diagnostic (Phase 6.2). Reject at the call site instead, before the invariant
    # gets a chance to trip.
    if _cw_f === Core.eval
        record_unsupported!(ctx, :unsupported_method,
            "eval (dynamic world-age reflection is outside WT's closed-world compilation target)";
            idx=idx, detail=node, soundness_fatal=true)
        ctx.last_stmt_was_stub = true
        return append_builder!(b, fb)
    end

    # an :invoke always names its MethodInstance and its Method; one that does not is a
    # boundary defect, rejected at its statement
    if !(mi isa Core.MethodInstance && mi.def isa Method)
        record_unsupported!(ctx, :unsupported_method,
            "an :invoke whose callee is not a MethodInstance of a Method ($(repr(mi)))"; idx=idx, detail=node)
        bnm = _ctx_builder(ctx, "compile_invoke")
        unreachable!(bnm)
        ctx.last_stmt_was_stub = true
        return append_builder!(b, append_builder!(fb, bnm))
    end
    local name = (mi.def::Method).name

    # THE callee: the function the invoke's MethodInstance compiles to, one per
    # MethodInstance (dart's getFunction(Reference)). Nothing else names it: a lookup by the
    # callee's object and argument types bound a call to another method's function when two
    # methods share a specialization's argument types (`invoke(f, Tuple{Super}, x)`).
    # parity(functions.dart:90 FunctionCollector.getFunction): one function per Reference.
    local target = get_function_by_mi(ctx.func_registry, mi)
    # a capturing closure's or a functor's function takes its object first (its signature's
    # first parameter is the receiver type, compile.jl prepends it): the call pushes the
    # callee's value there
    local takes_closure = target !== nothing && length(target.arg_types) == length(args) + 1 &&
                          first(target.arg_types) isa DataType &&
                          (is_closure_type(first(target.arg_types)) ||
                           first(target.arg_types) === callable_receiver_type(mi))
    # the parameter types the arguments are pushed as: the callee's own signature, else the
    # MethodInstance's (a call rejected below, its arguments emitted before its trap)
    local param_types = if target !== nothing
        target.arg_types[(takes_closure ? 2 : 1):end]
    else
        local spec = mi.specTypes
        (spec isa DataType && spec <: Tuple) ? spec.parameters[2:end] : nothing
    end

    # the callee's value, pushed as the closure object: the value the boundary carries (a
    # runtime callee's node, a constant's self, nir_callee_value), else the constant the
    # callee names, whose type determines it
    local closure_self_to_push = nothing
    if takes_closure
        closure_self_to_push = something(nir_callee_value(node), NirLiteral(node.callee))
    end

    # 453393ca4ba4: closure callee — the compiled function takes the closure
    # object as wasm param 1; push it before the explicit args
    if closure_self_to_push !== nothing
        emit_value!(fb, closure_self_to_push, ctx,
                    static_wasm_type(closure_self_to_push, ctx))   # THE typed value channel
    end

    # Push arguments through the resolved target signature. Each value is converted
    # while it is still on top of the stack; no post-push positional repairs exist.
    for (arg_idx, arg) in enumerate(args)
        # a MemoryRef argument crosses as its single-value struct, offset included
        # (boundary_wasm_type), never as its bare Memory
        local _mr_pt = (param_types !== nothing && arg_idx <= length(param_types)) ?
            param_types[arg_idx] : nothing
        if _mr_pt isa DataType && _mr_pt <: Core.GenericMemoryRef && isconcretetype(_mr_pt)
            emit_value!(fb, arg, ctx, boundary_wasm_type(_mr_pt, ctx.mod, ctx.type_registry))
            continue
        end

        # Check if this is a nothing argument that needs ref.null
        # Also check PiNode with typ === Nothing (Union dispatch pattern)
        is_nothing_arg = nir_const(arg) === nothing ||
                        (arg isa NirGlobalRef && arg.name === :nothing) ||
                        (arg isa NirSSA && begin
                            local def = _ssa_def(arg, ctx)
                            (def isa NirGlobalRef && def.name === :nothing) ||
                            (def isa NirPi && def.typ === Nothing)
                        end)

        # Also check if param_types expects Nothing (Union dispatch to different signatures)
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
            wasm_type = get_concrete_wasm_type(param_type, ctx.mod, ctx.type_registry; for_local=true)
            # Emit the appropriate null/zero value based on the wasm type
            _nb = _ctx_builder(ctx, "compile_invoke")
            if wasm_type isa ConcreteRef
                ref_null!(_nb, Int64(wasm_type.type_idx))
            elseif wasm_type === ExternRef
                ref_null!(_nb, ExternRef)
            elseif wasm_type === AnyRef
                ref_null!(_nb, AnyRef)
            elseif wasm_type === StructRef
                ref_null!(_nb, StructRef)
            elseif wasm_type === ArrayRef
                ref_null!(_nb, ArrayRef)
            elseif wasm_type === I64
                i64_const!(_nb, 0)
            elseif wasm_type === F32
                f32_const!(_nb, 0.0)
            elseif wasm_type === F64
                f64_const!(_nb, 0.0)
            else
                # I32 or other — push i32(0)
                i32_const!(_nb, 0)
            end
            append_builder!(fb, _nb)
        elseif is_nothing_arg
            # Nothing arg without param_types — emit ref.null anyref as safe default
            # Use anyref (not externref) for internal polymorphic positions
            _nb2 = _ctx_builder(ctx, "compile_invoke")
            ref_null!(_nb2, AnyRef)
            append_builder!(fb, _nb2)
        else
            local _ab = _compile_value_b(arg, ctx)
            local arg_ty = isempty(_ab.v.stack) ? nothing : _ab.v.stack[end]
            local _ab_merged = false
            # P6-ioprint: function/type singleton args compile to EMPTY emissions, but
            # trim-collected callees keep the param in their wasm signature (legacy
            # discovery skipped such functions entirely, so this never fired before).
            # Push ref.null of the param's wasm type to keep the call aligned.
            if isempty(_ab.instrs) && param_types !== nothing && arg_idx <= length(param_types)
                local _sp_jt = value_type(ctx, arg)
                if _sp_jt isa DataType && Base.issingletontype(_sp_jt)
                    local _sp_pt = param_types[arg_idx]
                    local _sp_w = get_concrete_wasm_type(_sp_pt isa Type ? _sp_pt : _sp_jt,
                                                         ctx.mod, ctx.type_registry)
                    local _spb = _ctx_builder(ctx, "compile_invoke")
                    if _sp_w isa ConcreteRef
                        ref_null!(_spb, Int64(_sp_w.type_idx))
                        append_builder!(fb, _spb)
                    elseif _sp_w === AnyRef || _sp_w === StructRef || _sp_w === ExternRef || _sp_w === EqRef
                        ref_null!(_spb, _sp_w)
                        append_builder!(fb, _spb)
                    end
                end
            end
            # (the arg merges below — AFTER the Nothing-phantom decision, which
            # previously popped the just-appended bytes back off)
            if param_types !== nothing && arg_idx <= length(param_types)
                expected_julia_type = param_types[arg_idx]
                # Skip non-Type values (e.g., Vararg markers)
                if expected_julia_type isa Type
                    expected_wasm = get_concrete_wasm_type(expected_julia_type, ctx.mod, ctx.type_registry)
                    actual_julia_type = value_type(ctx, arg)
                    # F8 (census: dart wrap = 100% of expressions through convertType,
                    # code_generator.dart:879): the whole inline coercion ladder — 14 arms
                    # re-implementing convertType — is ONE funnel call. The emission's own
                    # tracked type (dart carries the type with the value) refines `actual`;
                    # the old ssa_locals re-lookup died with the ladder.

                    # Handle Nothing→ref conversion.
                    # compile_value emits i32_const 0 for Nothing,
                    # but ref-typed params need ref.null. Must fix BEFORE bridging runs,
                    # otherwise bridging tries conversions on an i32 value.
                    # NOTE: Type{T} no longer needs this — it now emits global.get (DataType ref).
                    _is_phantom = actual_julia_type === Nothing
                    if _is_phantom && (expected_wasm isa ConcreteRef || expected_wasm === ExternRef || expected_wasm === StructRef || expected_wasm === AnyRef)
                        # the Nothing emission is exactly one i32.const 0 (ir/-kind test —
                        # the pop-two-bytes surgery is gone; we just don't merge the arg)
                        if length(_ab.instrs) == 1 && _ab.instrs[1] isa InstrIR.I32Const
                            if expected_wasm isa ConcreteRef
                                ref_null!(fb, Int64(expected_wasm.type_idx))
                            else
                                ref_null!(fb, expected_wasm)
                            end
                            _ab_merged = true   # the phantom replaced the arg emission
                        end
                    end
                    # merge the arg (unless the phantom replaced it) BEFORE the coercion
                    _ab_merged || (append_builder!(fb, _ab); _ab_merged = true)

                    coerce_stack_top!(fb, expected_wasm, ctx;
                                      from_julia=(actual_julia_type isa Type && isconcretetype(actual_julia_type)) ? actual_julia_type : nothing)
                end
            end

            # merge fallback: paths without param_types (or non-Type entries) never
            # reached the typed merge above — the arg still lands exactly once
            _ab_merged || (append_builder!(fb, _ab); _ab_merged = true)
        end
    end

    if target !== nothing
        # one call arm, self-recursion included (dart's static invocation has no recursion case)
        @debug "Cross-call resolved" name=name idx=idx return_type=target.return_type has_ssa_local=haskey(ctx.ssa_locals, idx)
        # Cross-function call - emit call instruction with target index
        # fullstrict: the args sit on the PARENT builder — seed the real
        # param count (readable from the pre-declared placeholder).
        # The module is authoritative for both imported and local
        # function signatures. Reuse the builder's sole resolver;
        # reconstructing only the local-function half here left
        # imported calls with an unseeded operand stack.
        local _cc_params = _function_type(ctx.mod, target.wasm_idx).params
        tracing(ctx, :cc) && println(stderr, "CC target=", target.name, " idx=", target.wasm_idx, " params=", _cc_params, " fbh=", length(fb.v.stack))
        bcc = _sub_builder(fb, ctx, "compile_invoke", length(_cc_params);
                           seed_types=_cc_params)   # the placeholder truth IS the contract
        emit_direct_call!(bcc, ctx.mod, ctx.type_registry, target.wasm_idx)
        # If callee returns Union{} (Bottom), it always throws/traps.
        # The Wasm func type has no result, so code after is unreachable.
        # Emit unreachable to make stack polymorphic — prevents DROP from
        # causing "nothing on stack" when the void call has no return value.
        # NOTE: Do NOT set ctx.last_stmt_was_stub here. The SSA type may not
        # be Union{} (e.g., Any in unoptimized IR), so setting the flag would
        # incorrectly trigger dead code detection and skip block structures.
        if target.return_type === Union{}
            unreachable!(bcc)  # structural trap (dart-legit dead path)
        end
        # Unused cross-call return values are dropped by
        # the stackifier (builder stack delta + use_count==0).
        # Do NOT emit DROP here — the stackifier's already_dropped heuristic
        # has false positives when the LEB128 function index byte coincides
        # with Opcode.CALL (0x10), causing double DROP and stack underflow.
        # Check: if function returns externref but caller expects concrete ref,
        # insert any_convert_extern + ref.cast null to bridge the type gap.
        # This happens when the function's wasm return type is externref (mapped
        # from Any/Union via julia_to_wasm_type) but the caller's SSA local uses
        # a tagged union struct (mapped via get_concrete_wasm_type).
        if haskey(ctx.ssa_locals, idx)
            local_idx_val = ctx.ssa_locals[idx]
            local_arr_idx = local_idx_val - ctx.n_params + 1
            if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                target_local_type = ctx.locals[local_arr_idx]
                local _cc_result = isempty(bcc.v.stack) ? nothing : bcc.v.stack[end]
                if _cc_result !== nothing && !_wt_is_ref(_cc_result) &&
                   _wt_is_ref(target_local_type) && isconcretetype(target.return_type)
                    # parity(code_generator.dart:677 convertType): the call's
                    # result converts from the CALLEE's output type. A
                    # union-split call is typed by the whole call's union
                    # (Union{Nothing,Int64}) while the invoked branch returns
                    # its own concrete type, which stamps the box's classId.
                    coerce_stack_top!(bcc, target_local_type, ctx;
                                      from_julia=target.return_type)
                elseif target_local_type isa ConcreteRef
                    ret_wasm = julia_to_wasm_type(target.return_type)
                    if ret_wasm === ExternRef
                        # Function returns externref, local expects concrete ref
                        any_convert_extern!(bcc)
                        ref_cast!(bcc, Int64(target_local_type.type_idx), true)
                    end
                elseif target_local_type === AnyRef
                    ret_wasm = julia_to_wasm_type(target.return_type)
                    if ret_wasm === ExternRef
                        # Function returns externref, local expects anyref
                        any_convert_extern!(bcc)
                    end
                elseif target_local_type === ExternRef && node.callee isa NirArgument
                    # Higher-order call returns concrete ref but local expects externref
                    # (SSA type is Any because the function parameter is generic)
                    # But if the callee already returns externref, skip —
                    # extern_convert_any expects anyref input, not externref.
                    callee_ret_wasm = julia_to_wasm_type(target.return_type)
                    if callee_ret_wasm !== ExternRef
                        extern_convert_any!(bcc)
                    end
                end
            end
        end
        append_builder!(fb, bcc)
    else
        # The closed world holds no function for this MethodInstance: every :invoke's target is
        # an edge the collector enrolls (_closed_world_edge), so this is a collector defect, loud at
        # the statement, never a call to another function or a plausible value.
        record_unsupported!(ctx, :unsupported_method,
            "the closed world holds no function for this MethodInstance: method `$name` for $(mi.specTypes)";
            idx=idx, detail=node)
        bunk = _ctx_builder(ctx, "compile_invoke")
        unreachable!(bunk)
        append_builder!(fb, bunk)
        ctx.last_stmt_was_stub = true
    end

    return append_builder!(b, fb)
end
