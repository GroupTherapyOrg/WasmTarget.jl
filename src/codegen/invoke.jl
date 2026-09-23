"""Prove that a concrete vararg constructor is only `%new(T, fixed..., varargs)`.

This is deliberately shape-based, not name-based: the optimized Julia body must
contain exactly one allocation and a return, and its fields must be the method's
fixed slots followed by its one vararg-tuple slot.
"""
function _is_direct_vararg_struct_constructor(@nospecialize(target), mi::Core.MethodInstance,
                                               arg_types::Tuple)::Bool
    target isa DataType && isconcretetype(target) && isstructtype(target) || return false
    mi.def isa Method && mi.def.isva || return false
    fixed_count = mi.def.nargs - 2  # exclude #self# and the vararg tuple slot
    fieldcount(target) == fixed_count + 1 || return false
    typed = try
        [get_typed_ir(target, arg_types)]
    catch
        return false
    end
    length(typed) == 1 || return false
    body = typed[1][1]
    body isa Core.CodeInfo || return false
    nir = build_nir(body)
    news = NirNew[s.node for s in nir if s.slot == 0 && s.node isa NirNew]
    length(news) == 1 || return false
    all(s -> s.slot == 0 && ((s.node isa NirLiteral && s.node.value === nothing) ||
                             s.node isa NirReturn || s.node isa NirNew ||
                             (s.node isa NirUnsupported && s.node.kind === :meta)), nir) || return false
    alloc = only(news)
    length(alloc.operands) == fieldcount(target) || return false
    (alloc.type_kind === :literal && alloc.T === target) || return false
    _is_arg(x, n) = x isa NirArgument && x.n == n
    for i in 1:fixed_count
        _is_arg(alloc.operands[i], i + 1) || return false
    end
    return _is_arg(alloc.operands[end], fixed_count + 2)
end

_invoke_arg_static_type(arg, ctx::AbstractCompilationContext) =
    nir_const(arg) isa Type ? Core.Typeof(nir_const(arg)) : infer_value_type(arg, ctx)

"""Return the unique singleton represented by `T`, or `nothing` when none exists."""
_invoke_singleton_instance(@nospecialize(T)) =
    T isa DataType && Base.issingletontype(T) ? getfield(T, :instance) : nothing

"""The function object a MethodInstance specializes — its signature's first parameter's
singleton instance — or `nothing` for a closure, a constructor or an unspecialized
signature.
parity(pkg/kernel/lib/src/ast/expressions.dart:2820 StaticInvocation): the invocation's
target member, read as an identity."""
function _invoke_callee_object(mi::Core.MethodInstance)::Any
    st = mi.specTypes
    (st isa DataType && st <: Tuple && length(st.parameters) >= 1) || return nothing
    return _invoke_singleton_instance(st.parameters[1])
end

# The function an invoked value names through a global binding: the invoke's own callee
# when the IR wrote a global there (the NIR boundary resolved it to its object; an unbound
# one stays a `GlobalRef`), or an SSA alias of a global (optionally through one π) — else
# `nothing` (a literal, a parameter, a runtime value).
# parity(pkg/kernel/lib/src/ast/expressions.dart:2820 StaticInvocation): a call's target.
function _invoke_named_callee(callee, ctx::AbstractCompilationContext; through_pi::Bool)::Any
    callee isa NirNode || return callee
    def = _ssa_def(callee, ctx)
    through_pi && def isa NirPi && def.value isa NirSSA && (def = _ssa_def(def.value, ctx))
    def isa NirGlobalRef || return nothing
    return def.bound ? def.value : GlobalRef(def.mod, def.name)
end

"""
Compile an invoke expression (method invocation) — dart visitor shape:
emits the invoke INTO the caller's builder.
The interior accumulates into a FRAGMENT builder `fb` (≡ the old `bytes` buffer,
same discard semantics: arms that replace it re-init; exits merge typed).
"""
function compile_invoke!(b::InstrBuilder, node::NirInvoke, idx::Int, ctx::AbstractCompilationContext)
    fb = _ctx_builder(ctx, "compile_invoke.frag")
    _seed_builder_locals!(fb, ctx)
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
        params, _ = _true_call_sig(bii, target_idx, WasmValType[], WasmValType[])
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
        call!(bii, target_idx, WasmValType[], WasmValType[])
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
            global_get!(bsg, global_idx, AnyRef)
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
                    global_get!(bss2, global_idx, AnyRef)
                    # Convert to f64 for DOM imports (all DOM imports expect f64)
                    emit_convert_to_f64!(bss2, global_type)
                    # Call the DOM import function
                    call!(bss2, import_idx, WasmValType[], WasmValType[])
                end
            end

            # Setter returns the value in Therapy.jl, so re-read it
            global_get!(bss2, global_idx, AnyRef)
            return append_builder!(b, bss2)
        end
    end

    # Get MethodInstance to check parameter types for nothing arguments
    mi = node.mi

    # The closed-world metadata operations trim_compile_plan leaves out of the function
    # list (check_world_bounded, isvisible and their overlays) lower at an :invoke
    # through the same identity-keyed BUILTIN_LOWERINGS entry as at a :call — the
    # invoked Method's function OBJECT selects it, never its name.
    local _cw_f = mi isa Core.MethodInstance ? _invoke_callee_object(mi) : nothing
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

    # Early self-call detection: check if this is a recursive call to ourselves.
    # The invoked function is the one the callee names through a global (directly, or an
    # SSA alias of one through a π), else the callee's own constant, else — for a
    # function parameter — the singleton instance its specialized type names.
    named_early = _invoke_named_callee(node.callee, ctx; through_pi=true)
    actual_func_ref_early = named_early !== nothing ? named_early : nir_const(node.callee)
    if named_early === nothing && node.callee isa NirArgument
        # Higher-order function calls — extract function from mi.specTypes
        if mi isa Core.MethodInstance
            spec = mi.specTypes
            if spec isa DataType && spec <: Tuple && length(spec.parameters) >= 1
                func_type = spec.parameters[1]
                singleton = _invoke_singleton_instance(func_type)
                singleton === nothing || (actual_func_ref_early = singleton)
            end
        end
    end
    # the invoked function as an operand the value channel emits: the callee's own node, or
    # the constant it names
    early_operand = actual_func_ref_early isa NirNode ? actual_func_ref_early :
                    NirLiteral(actual_func_ref_early)
    is_self_call_early = false
    if ctx.func_ref !== nothing && named_early !== nothing && !(named_early isa GlobalRef)
            called_func = named_early
            if called_func === ctx.func_ref
                # Also check arity — overloaded methods share the same function
                # object but have different specTypes. A call to a different overload is NOT
                # a self-call (e.g., parse_comma(ps) calling parse_comma(ps, true)).
                if mi isa Core.MethodInstance
                    spec = mi.specTypes
                    if spec isa DataType && spec <: Tuple
                        call_nargs = length(spec.parameters) - 1  # subtract typeof(func)
                        # Check both arity AND parameter types — same-arity overloads
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

    # Compute target_info EARLY so we can use its arg_types for proper type checking
    # during argument compilation. This helps when param_types (from mi.specTypes) differ from
    # the actual compiled function's parameter types.
    target_info_early = nothing
    closure_self_to_push = nothing   # 453393ca4ba4: see below
    if ctx.func_registry !== nothing && !is_self_call_early
        called_func_early = nothing
        if named_early !== nothing
            called_func_early = named_early isa GlobalRef ? nothing : named_early   # unbound: nothing
        elseif actual_func_ref_early isa Function
            # func_ref can be a Function object directly (default-arg methods)
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
                    isdefined(func_type, :instance) &&
                        (called_func_early = func_type.instance)
                end
            end
        end
        if called_func_early !== nothing
            call_arg_types_early = tuple([infer_value_type(arg, ctx) for arg in args]...)
            _exp_ret = get(ctx.ssa_types, idx, nothing)
            target_info_early = get_function(ctx.func_registry, called_func_early, call_arg_types_early;
                                             expected_return=_exp_ret isa Type ? _exp_ret : nothing)
            # Closure/kwarg functions are registered with self-type prepended
            if target_info_early === nothing && typeof(called_func_early) <: Function && isconcretetype(typeof(called_func_early))
                closure_arg_types_early = (typeof(called_func_early), call_arg_types_early...)
                target_info_early = get_function(ctx.func_registry, called_func_early, closure_arg_types_early)
                # 453393ca4ba4: a CAPTURING closure entry takes the closure object as
                # wasm param 1 — the call site must push it (Snapshot.jl newton C-W3:
                # 6 values for a 7-param functype → "nothing on stack")
                if target_info_early !== nothing && is_closure_type(typeof(called_func_early))
                    closure_self_to_push = early_operand
                end
            end
        end
    end

    # 453393ca4ba4: capturing-closure callees — the function position is a VALUE
    # (SSA/argument/local); identity-keyed registry lookup can never match the
    # runtime-constructed instance, so the invoke silently fell through to an
    # `unreachable` (Snapshot.jl newton C-W3). Resolve by TYPE against the
    # self-prepended signature and push the closure object as wasm param 1.
    tracing(:closure) &&
        println(stderr, "CLOSDBG ref=", repr(actual_func_ref_early), " :: ", typeof(actual_func_ref_early),
                " ti_early=", target_info_early !== nothing)
    if target_info_early === nothing && ctx.func_registry !== nothing && !is_self_call_early &&
       actual_func_ref_early !== nothing && named_early === nothing
        ft_early = infer_value_type(early_operand, ctx)
        if ft_early isa DataType && is_closure_type(ft_early)
            cat_early = tuple([infer_value_type(arg, ctx) for arg in args]...)
            ti = get_function_by_argtypes(ctx.func_registry, (ft_early, cat_early...))
            tracing(:closure) &&
                println(stderr, "CLOSDBG bytype ft=", ft_early, " cat=", cat_early, " hit=", ti !== nothing)
            if ti !== nothing
                target_info_early = ti
                closure_self_to_push = early_operand
            end
        end
    end
    # self-prepended entries: arg_types are shifted +1 relative to `args`
    early_argtypes_offset = closure_self_to_push === nothing ? 0 : 1
    if target_info_early !== nothing
        first_explicit = 1 + early_argtypes_offset
        param_types = first_explicit <= length(target_info_early.arg_types) ?
            target_info_early.arg_types[first_explicit:end] : ()
    end

    # ================================================================
    # Early dispatch: Julia Base string operations → str_* intrinsics
    # These must run BEFORE the pre-push loop to avoid side effects
    # from compiling unwanted arguments (e.g., function singleton structs).
    # ================================================================
    if mi isa Core.MethodInstance
        meth_early = mi.def
        if meth_early isa Method
            _name_early = meth_early.name
            _spec_early = mi.specTypes

            # BF-4000: #string#403(base, pad, typeof(string), x) → inline dec call
            # String interpolation "$x" and string(x::Integer) go through this kwarg method.
            # The typeof(string) arg is phantom (never used in body). Redirect to dec().
            if _name_early === Symbol("#string#403") && length(args) == 4 &&
               ctx.func_registry !== nothing
                _dec_info = get_function(ctx.func_registry, Base.dec, (UInt64, Int64, Bool))
                if _dec_info !== nothing
                    bd = _ctx_builder(ctx, "compile_invoke")
                    _x = args[4]  # the integer value

                    # Push abs(x) as I64 (same bits as UInt64): select(x, -x, x >= 0)
                    emit_value!(bd, _x, ctx, I64)  # x (true branch)
                    i64_const!(bd, 0)                                   # 0
                    emit_value!(bd, _x, ctx, I64)  # x
                    num!(bd, Opcode.I64_SUB)                            # -x (false branch)
                    emit_value!(bd, _x, ctx, I64)  # x
                    i64_const!(bd, 0)                                   # 0
                    num!(bd, Opcode.I64_GE_S)                           # x >= 0 (i32 condition)
                    select!(bd)                                         # abs(x)

                    # Push pad (arg 2)
                    emit_value!(bd, args[2], ctx, I64)

                    # Push x < 0 as i32 Bool
                    emit_value!(bd, _x, ctx, I64)
                    i64_const!(bd, 0)
                    num!(bd, Opcode.I64_LT_S)

                    # Call dec
                    call!(bd, _dec_info.wasm_idx, WasmValType[], WasmValType[])
                    return append_builder!(b, bd)
                end
            end

            # repeat/lpad/rpad: deleted (spike, dev/MARCH.md Phase 5.2 item A).
            # These used to intercept by bare Symbol name BEFORE cross-call/overlay
            # resolution ever got a chance — for repeat(::Char,::Int) that unconditional
            # interception was shadowing a REAL bug fix: the
            # `@overlay WASM_METHOD_TABLE Base.repeat(c::Char,n::Int)` in interpreter.jl
            # (assembles the char's full UTF-8 bytes) was dead code, permanently shadowed
            # by this arm's single-byte `char >> 24` fill — confirmed via the spike
            # (repeat('💊',3) now correct; it silently truncated to one byte before).
            # repeat(::String,::Int) has its own overlay; lpad/rpad have no overlay — Base's
            # real bodies (strings/util.jl) compile correctly through the generic path
            # (verified: the exact `lpad`/`rpad` source, copied under a fresh name so this
            # interception could not shadow it, differential-passed including the
            # `utf8proc_charwidth` foreigncall and the `p^q` dynamic-dispatch repeat call —
            # WT already has table-driven foreigncall lowerings for `utf8proc_charwidth`/
            # `utf8proc_category`, statements.jl/types.jl).
        end
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
                ref_null!(_nb, Int64(wasm_type.type_idx), ConcreteRef(UInt32(wasm_type.type_idx), true))
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
                local _sp_jt = infer_value_type(arg, ctx)
                if _sp_jt isa DataType && Base.issingletontype(_sp_jt)
                    local _sp_pt = param_types[arg_idx]
                    local _sp_w = get_concrete_wasm_type(_sp_pt isa Type ? _sp_pt : _sp_jt,
                                                         ctx.mod, ctx.type_registry)
                    local _spb = _ctx_builder(ctx, "compile_invoke")
                    if _sp_w isa ConcreteRef
                        ref_null!(_spb, Int64(_sp_w.type_idx), ConcreteRef(UInt32(_sp_w.type_idx), true))
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
                    actual_julia_type = infer_value_type(arg, ctx)
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
                                ref_null!(fb, Int64(expected_wasm.type_idx), ConcreteRef(UInt32(expected_wasm.type_idx), true))
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

    # mi was already extracted above for parameter type checking
    if mi isa Core.MethodInstance
        meth = mi.def
        if meth isa Method
            name = meth.name

            # Check if this is a self-recursive call: the invoked function is the one
            # the callee names through a global (directly or through an SSA alias), else
            # the callee's own constant, else a parameter's singleton instance.
            func_ref = node.callee
            named = _invoke_named_callee(func_ref, ctx; through_pi=false)
            actual_func_ref = named !== nothing ? named : nir_const(func_ref)
            if named === nothing && func_ref isa NirArgument
                # Higher-order function calls (e.g., parse_Nary's `down(ps)`)
                # func_ref is a function parameter. Extract actual function from mi.specTypes.
                if mi isa Core.MethodInstance
                    spec = mi.specTypes
                    if spec isa DataType && spec <: Tuple && length(spec.parameters) >= 1
                        func_type = spec.parameters[1]
                        singleton = _invoke_singleton_instance(func_type)
                        singleton === nothing || (actual_func_ref = singleton)
                    end
                end
            end

            is_self_call = false
            if ctx.func_ref !== nothing && named !== nothing && !(named isa GlobalRef)
                # Check if this global refers to the same function
                    called_func = named
                    if called_func === ctx.func_ref
                        # Check arity AND types for overloaded methods
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
            elseif ctx.func_ref !== nothing && named === nothing && actual_func_ref isa Function
                # Function object direct comparison
                if actual_func_ref === ctx.func_ref
                    # Check arity AND types for overloaded methods
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
            if ctx.func_registry !== nothing && !is_self_call
                # Try to find this function in our registry
                called_func = nothing
                if named !== nothing
                    called_func = named isa GlobalRef ? nothing : named   # unbound: nothing
                elseif actual_func_ref isa DataType || actual_func_ref isa UnionAll
                    # For constructor calls, the func_ref might be the type directly
                    called_func = actual_func_ref
                elseif actual_func_ref isa Function
                    # For default-arg methods, func_ref can be a Function object
                    # (e.g., typeof(next_token) for next_token(lexer, true))
                    called_func = actual_func_ref
                elseif actual_func_ref isa NirArgument && mi isa Core.MethodInstance
                    # Fallback for Core.Argument — extract from mi.specTypes
                    spec = mi.specTypes
                    if spec isa DataType && spec <: Tuple && length(spec.parameters) >= 1
                        func_type = spec.parameters[1]
                        called_func = _invoke_singleton_instance(func_type)
                    end
                end

                if called_func === nothing && closure_self_to_push !== nothing && target_info_early !== nothing
                    # 453393ca4ba4: closure callee resolved by TYPE in the early
                    # block; the closure object is already on the stack under the args
                    called_func = closure_self_to_push
                end
                if called_func !== nothing
                    # Infer argument types for dispatch
                    call_arg_types = tuple([infer_value_type(arg, ctx) for arg in args]...)
                    _exp_ret_l = get(ctx.ssa_types, idx, nothing)
                    target_info = get_function(ctx.func_registry, called_func, call_arg_types;
                                               expected_return=_exp_ret_l isa Type ? _exp_ret_l : nothing)
                    if target_info === nothing && closure_self_to_push !== nothing
                        target_info = target_info_early
                    end

                    # Closure/kwarg functions are registered with self-type prepended
                    # (e.g., typeof(#SourceFile#40) prepended to arg_types). Retry with self-type.
                    if target_info === nothing && typeof(called_func) <: Function && isconcretetype(typeof(called_func))
                        closure_arg_types = (typeof(called_func), call_arg_types...)
                        target_info = get_function(ctx.func_registry, called_func, closure_arg_types)
                    end

                    if target_info !== nothing
                        @debug "Cross-call resolved" name=name idx=idx return_type=target_info.return_type has_ssa_local=haskey(ctx.ssa_locals, idx)
                        # Cross-function call - emit call instruction with target index
                        # fullstrict: the args sit on the PARENT builder — seed the real
                        # param count (readable from the pre-declared placeholder).
                        # The module is authoritative for both imported and local
                        # function signatures. Reuse the builder's sole resolver;
                        # reconstructing only the local-function half here left
                        # imported calls with an unseeded operand stack.
                        local _cc_params, _ = _true_call_sig(
                            fb, target_info.wasm_idx, WasmValType[], WasmValType[])
                        tracing(:cc) && println(stderr, "CC target=", target_info.name, " idx=", target_info.wasm_idx, " params=", _cc_params, " fbh=", length(fb.v.stack))
                        bcc = _sub_builder(fb, ctx, "compile_invoke", length(_cc_params);
                                           seed_types=_cc_params)   # the placeholder truth IS the contract
                        call!(bcc, target_info.wasm_idx, WasmValType[], WasmValType[])
                        cross_call_handled = true
                        # If callee returns Union{} (Bottom), it always throws/traps.
                        # The Wasm func type has no result, so code after is unreachable.
                        # Emit unreachable to make stack polymorphic — prevents DROP from
                        # causing "nothing on stack" when the void call has no return value.
                        # NOTE: Do NOT set ctx.last_stmt_was_stub here. The SSA type may not
                        # be Union{} (e.g., Any in unoptimized IR), so setting the flag would
                        # incorrectly trigger dead code detection and skip block structures.
                        if target_info.return_type === Union{}
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
                                if target_local_type isa ConcreteRef
                                    ret_wasm = julia_to_wasm_type(target_info.return_type)
                                    if ret_wasm === ExternRef
                                        # Function returns externref, local expects concrete ref
                                        any_convert_extern!(bcc)
                                        ref_cast!(bcc, Int64(target_local_type.type_idx), true)
                                    end
                                elseif target_local_type === AnyRef
                                    ret_wasm = julia_to_wasm_type(target_info.return_type)
                                    if ret_wasm === ExternRef
                                        # Function returns externref, local expects anyref
                                        any_convert_extern!(bcc)
                                    end
                                elseif target_local_type === ExternRef && func_ref isa NirArgument
                                    # Higher-order call returns concrete ref but local expects externref
                                    # (SSA type is Any because the function parameter is generic)
                                    # But if the callee already returns externref, skip —
                                    # extern_convert_any expects anyref input, not externref.
                                    callee_ret_wasm = julia_to_wasm_type(target_info.return_type)
                                    if callee_ret_wasm !== ExternRef
                                        extern_convert_any!(bcc)
                                    end
                                end
                            end
                        end
                        append_builder!(fb, bcc)
                    end
                end
            end

            if is_self_call
                # Self-recursive call - emit call instruction
                # fullstrict: the args live on fb; the OWN placeholder sig is the contract
                local _sc_params = begin
                    local _m = ctx.mod
                    local _ni = count(imp -> imp.kind == 0x00, _m.imports)
                    local _fi = Int(ctx.func_idx) - _ni
                    local _ps = WasmValType[]
                    if _fi >= 0 && _fi < length(_m.functions)
                        local _ft = _m.types[Int(_m.functions[_fi + 1].type_idx) + 1]
                        _ft isa FuncType && (_ps = WasmValType[q for q in _ft.params])
                    end
                    _ps
                end
                bsc2 = _sub_builder(fb, ctx, "compile_invoke", length(_sc_params); seed_types=_sc_params)
                call!(bsc2, ctx.func_idx, WasmValType[], WasmValType[])
                # Bridge return type for self-calls (externref→anyref)
                if haskey(ctx.ssa_locals, idx)
                    local_idx_val = ctx.ssa_locals[idx]
                    local_arr_idx = local_idx_val - ctx.n_params + 1
                    if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                        target_local_type = ctx.locals[local_arr_idx]
                        if target_local_type === AnyRef && ctx.return_type !== nothing
                            ret_wasm = julia_to_wasm_type(ctx.return_type)
                            if ret_wasm === ExternRef
                                any_convert_extern!(bsc2)
                            end
                        elseif target_local_type isa ConcreteRef && ctx.return_type !== nothing
                            ret_wasm = julia_to_wasm_type(ctx.return_type)
                            if ret_wasm === ExternRef
                                any_convert_extern!(bsc2)
                                ref_cast!(bsc2, Int64(target_local_type.type_idx), true)
                            end
                        end
                    end
                end
                append_builder!(fb, bsc2)
            elseif cross_call_handled
                # Already handled above

            # Name-keyed; R37 counts it. Julia's own _growend!/_growbeg!/_growat! closure
            # body stores `a.ref = memoryref(newmem, offset)`, and WT's Vector {data, size}
            # carries no MemoryRef offset, so compiling that body rejects at array.jl:1156
            # (measured 2026-09-22). The arm goes with the structural item "Vector/MemoryRef
            # carries its offset", which also admits the invoked Base closures to the closed
            # world and retires the reallocating Vector overlays.
            elseif meth.module === Base &&
                   occursin(r"^#_(?:growend|growbeg|growat)!", string(name))
                # Clear any accumulated bytes from argument compilation
                fb = _ctx_builder(ctx, "compile_invoke.frag"); _seed_builder_locals!(fb, ctx)

                # Drop the closure object from the stack if it's there
                func_ref = node.callee
                if func_ref isa NirSSA
                    if !haskey(ctx.ssa_locals, func_ref.id) && !haskey(ctx.phi_locals, func_ref.id)
                        bgrd = _ctx_builder(ctx, "compile_invoke")
                        drop!(bgrd)
                        append_builder!(fb, bgrd)
                    end
                end

                # Find the vector being grown from the :new expression
                # The closure's first captured field is the vector
                vec_arg = nothing
                vec_julia_type = nothing
                local new_def = _ssa_def(func_ref, ctx)
                if new_def isa NirNew && !isempty(new_def.operands)
                    vec_arg = new_def.operands[1]  # First captured field = vector
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

                    bgr = _ctx_builder(ctx, "compile_invoke")

                    # 1. Get the vector and store in local
                    emit_value!(bgr, vec_arg, ctx, ConcreteRef(UInt32(vec_type_idx), true))
                    # heap type for ref.cast must use signed LEB128
                    ref_cast!(bgr, Int64(vec_type_idx), true)
                    local_set!(bgr, vec_scratch_local)

                    # 2. Get old backing array and store
                    local_get!(bgr, vec_scratch_local)
                    struct_get!(bgr, vec_type_idx, wasm_field_idx(vec_info, 1), ConcreteRef(UInt32(arr_type_idx), true))
                    # heap type for ref.cast must use signed LEB128
                    ref_cast!(bgr, Int64(arr_type_idx), true)
                    local_set!(bgr, old_arr_local)

                    # 3. Get old capacity
                    local_get!(bgr, old_arr_local)
                    array_len!(bgr)
                    local_set!(bgr, old_cap_local)

                    # 4. New capacity = max(old_cap * 2, old_cap + 4)
                    local_get!(bgr, old_cap_local)
                    i32_const!(bgr, 2)
                    num!(bgr, Opcode.I32_MUL)
                    local_get!(bgr, old_cap_local)
                    i32_const!(bgr, 4)
                    num!(bgr, Opcode.I32_ADD)
                    # select: [val_true, val_false, cond] -> val_true if cond!=0
                    local_get!(bgr, old_cap_local)
                    i32_const!(bgr, 2)
                    num!(bgr, Opcode.I32_MUL)
                    local_get!(bgr, old_cap_local)
                    i32_const!(bgr, 4)
                    num!(bgr, Opcode.I32_ADD)
                    num!(bgr, Opcode.I32_GE_S)
                    select!(bgr)

                    # 5. Create new array with new capacity
                    array_new_default!(bgr, arr_type_idx)
                    local_set!(bgr, new_arr_local)

                    # 6. Copy old elements: array.copy [dst, dst_off, src, src_off, len]
                    local_get!(bgr, new_arr_local)
                    i32_const!(bgr, 0)  # dst_off = 0
                    local_get!(bgr, old_arr_local)
                    i32_const!(bgr, 0)  # src_off = 0
                    local_get!(bgr, old_cap_local)
                    array_copy!(bgr, arr_type_idx, arr_type_idx)

                    # 7. Update vector's backing array field
                    local_get!(bgr, vec_scratch_local)
                    local_get!(bgr, new_arr_local)
                    struct_set!(bgr, vec_type_idx, wasm_field_idx(vec_info, 1), ConcreteRef(UInt32(arr_type_idx), true))

                    append_builder!(fb, bgr)

                    # 8. Growth code is side-effect only — no wasm value produced.
                    #    Its builder stack delta is zero, so the stackifier emits no DROP.
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
                    bgrf = _ctx_builder(ctx, "compile_invoke")
                    record_unsupported!(ctx, :unsupported_method,
                                        "vector op: element type undeterminable";
                                        idx=idx, detail=node)
                    unreachable!(bgrf)  # structural trap after recorded unsupported
                    append_builder!(fb, bgrf)
                    ctx.last_stmt_was_stub = true
                end

            # ================================================================
            # Struct constructor via :invoke — immutable structs with only
            # reference-type fields (e.g., all-String) use :invoke instead
            # of :new.  Detect Type{T} as first specTypes parameter and
            # emit struct.new with the pre-compiled field values.
            # ================================================================
            elseif mi !== nothing && begin
                    local _sc_sig = mi.specTypes
                    local _sc_ok = false
                    if _sc_sig isa DataType && _sc_sig <: Tuple && length(_sc_sig.parameters) >= 1
                        local _sc_fp = _sc_sig.parameters[1]
                        if _sc_fp isa DataType && _sc_fp <: Type && length(_sc_fp.parameters) >= 1
                            local _sc_tt = _sc_fp.parameters[1]
                            # Only a FIELD-WISE constructor (one arg per struct field) can be
                            # lowered to a bare struct.new: it needs exactly `fieldcount` operands.
                            # A non-field-wise constructor reached via :invoke (e.g.
                            # `Dict{K,V}(ps::Pair...)`, which allocates keys/vals Memory + hashes)
                            # has a DIFFERENT arg count, so mapping its args straight onto the
                            # struct fields emits silently-invalid wasm (`struct.new $Dict` fed 3
                            # Pairs into 8 fields → "expected i64, found (ref …)"). Guard on
                            # arg-count == field-count so this branch fires ONLY when it can emit
                            # valid wasm; the rest loud-reject via the terminal :unsupported_method.
                            if _sc_tt isa DataType && is_struct_type(_sc_tt) &&
                               (haskey(ctx.type_registry.structs, _sc_tt) ||
                                (isconcretetype(_sc_tt) && isstructtype(_sc_tt))) &&
                               isconcretetype(_sc_tt)
                                local _sc_argtypes = tuple((_invoke_arg_static_type(arg, ctx)
                                    for arg in args)...)
                                _sc_ok = fieldcount(_sc_tt) == length(args) ||
                                    _is_direct_vararg_struct_constructor(_sc_tt, mi, _sc_argtypes)
                            end
                        end
                    end
                    _sc_ok
                end
                # Extract target type from Type{T}
                local _ctor_target = mi.specTypes.parameters[1].parameters[1]::DataType
                # Clear pre-compiled args — we re-emit in correct order with typeId
                fb = _ctx_builder(ctx, "compile_invoke.frag"); _seed_builder_locals!(fb, ctx)
                # Register struct type if not already registered
                if !haskey(ctx.type_registry.structs, _ctor_target)
                    register_struct_type!(ctx.mod, ctx.type_registry, _ctor_target)
                end
                local _ctor_sinfo = ctx.type_registry.structs[_ctor_target]
                if _ctor_sinfo !== nothing
                    emit_struct_prefix!(fb, ctx.type_registry, _ctor_target, _ctor_sinfo)
                    local _ctor_argtypes = tuple((_invoke_arg_static_type(arg, ctx)
                        for arg in args)...)
                    local _vararg_direct = _is_direct_vararg_struct_constructor(
                        _ctor_target, mi, _ctor_argtypes)
                    local _fixed_count = _vararg_direct ? mi.def.nargs - 2 : length(args)
                    # Compile fixed constructor arguments as their exact struct fields.
                    for _fi in 1:_fixed_count
                        local _ftype = _fi <= length(_ctor_sinfo.field_types) ? _ctor_sinfo.field_types[_fi] : Any
                        local _ctor_def = ctx.mod.types[_ctor_sinfo.wasm_type_idx + 1]
                        local _field_idx = _fi + Int(_ctor_sinfo.field_offset)
                        local _expected = (_ctor_def isa StructType && _field_idx <= length(_ctor_def.fields)) ?
                            _ctor_def.fields[_field_idx].valtype : nothing
                        _expected === nothing && error(
                            "constructor field lacks a physical Wasm type: target=$_ctor_target field=$_fi " *
                            "offset=$(_ctor_sinfo.field_offset) registered_fields=$(length(_ctor_sinfo.field_types)) " *
                            "physical_fields=$(_ctor_def isa StructType ? length(_ctor_def.fields) : -1)")
                        emit_value!(fb, args[_fi], ctx, _expected; from_julia=_ftype)
                    end
                    if _vararg_direct
                        local _varargs = args[(_fixed_count + 1):end]
                        local _vararg_types = tuple((_invoke_arg_static_type(arg, ctx)
                            for arg in _varargs)...)
                        local _tuple_type = Tuple{_vararg_types...}
                        local _tuple_info = register_tuple_type!(ctx.mod, ctx.type_registry, _tuple_type)
                        _tuple_info === nothing && error("vararg tuple layout is unavailable")
                        emit_struct_prefix!(fb, ctx.type_registry, _tuple_type, _tuple_info)
                        local _tuple_def = ctx.mod.types[_tuple_info.wasm_type_idx + 1]
                        for (_vi, _arg) in enumerate(_varargs)
                            local _wf = _vi + Int(_tuple_info.field_offset)
                            local _expected = (_tuple_def isa StructType && _wf <= length(_tuple_def.fields)) ?
                                _tuple_def.fields[_wf].valtype : nothing
                            _expected === nothing && error("vararg tuple field lacks a physical Wasm type")
                            emit_value!(fb, _arg, ctx, _expected; from_julia=_vararg_types[_vi])
                        end
                        struct_new!(fb, _tuple_info.wasm_type_idx)
                    end
                    # Allocation consumes the fields on this same authoritative stack.
                    struct_new!(fb, _ctor_sinfo.wasm_type_idx)
                else
                    # Registration failed — codegen cannot lay out this struct type.
                    record_unsupported!(ctx, :unsupported_type,
                        "struct constructor for `$(_ctor_target)` (type registration failed)"; idx=idx, detail=node)
                    bscnf = _ctx_builder(ctx, "compile_invoke")
                    record_unsupported!(ctx, :unsupported_method, "struct type registration failed (cannot lay out)"; idx=idx)
                    unreachable!(bscnf)
                    append_builder!(fb, bscnf)
                    ctx.last_stmt_was_stub = true
                end

            else
                # Unknown method — codegen has no translation for this invoke target.
                # This records a source-attributed diagnostic and emits dart's validating
                # unsupported-path trap; no permissive mode exists.
                # which lets compilation succeed for paths that never reach this method.
                tracing(:stubargs) && println(stderr, "STUBARGS ", name, " args=", repr(args))
                record_unsupported!(ctx, :unsupported_method,
                    "method `$name`" * (mi !== nothing ? " for $(mi.specTypes)" : "");
                    idx=idx, detail=node)
                bunk = _ctx_builder(ctx, "compile_invoke")
                record_unsupported!(ctx, :unsupported_method, "unknown invoke target (no handler arm)"; idx=idx)
                unreachable!(bunk)
                append_builder!(fb, bunk)
                ctx.last_stmt_was_stub = true
            end
        end
    end

    return append_builder!(b, fb)
end
