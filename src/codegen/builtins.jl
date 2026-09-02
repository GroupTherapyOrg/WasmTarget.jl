# ============================================================================
# builtins.jl — identity-keyed Core/Base builtin registry for `compile_call!`.
#
# dart2wasm dispatches a `StaticInvocation`/`MemberInvocation` node through
# `MemberIntrinsic`/`StaticIntrinsic`, keyed on (library, class, name) resolved
# once through `KernelNodes` (intrinsics.dart `_lookup`). Julia's typed IR
# expresses the same "which kernel/Core operation is this" question as a
# `:call` whose callee resolves to a specific Core/Base BUILTIN FUNCTION
# OBJECT (`Core.getfield`, `Core.tuple`, `Core.typeof`, …) — so the analogous
# WT registry is keyed on THAT OBJECT's identity, resolved once, never on the
# bare name Symbol `is_func` compared against.
#
# Each entry is a lowering function `(b, fb, ctx, expr, idx, args, callee) ->
# Union{InstrBuilder,Nothing}`. Returning the (already `append_builder!(b,
# fb)`-ed) `InstrBuilder` means "handled"; returning `nothing` means "this
# callee's guard did not match — fall through" (dart's nullable-return-funnel
# shape: intrinsics.dart :607/:685/:995/:1007/:1018).
#
# Builtins with MORE THAN ONE call-site fragment in the historical ladder that
# are order-sensitive against OTHER, non-`is_func` identity checks for the
# SAME callee (`getfield`/`getproperty`, `setfield!`/`setproperty!`) are NOT
# migrated here — see the block comment above their remaining `compile_call!`
# arms for why relocating them is unsafe without a deeper restructuring.
# ============================================================================

const BUILTIN_LOWERINGS = IdDict{Any,Function}()

"""Resolve a call callee to the concrete Core/Base function OBJECT it names,
mirroring dart's `KernelNodes` lookup — the registry is keyed on that object's
identity, never on the bare name Symbol. A `GlobalRef` to an undefined binding
is left as-is (an explicit non-match, not a thrown error); every other shape
(a resolved function value, an `SSAValue`, …) passes through unchanged."""
_resolve_builtin_callee(func) =
    func isa GlobalRef ? (isdefined(func.mod, func.name) ? getfield(func.mod, func.name) : func) : func

"""THE funnel: resolve `func`'s callee identity once and, if it names a
registered Core/Base builtin, run its lowering. Returns the handled
`InstrBuilder` or `nothing` (generic/dynamic-call path continues) — dart's
nullable-return entry-funnel shape. Called twice from `compile_call!`: once on
the raw callee (the handful of arms that must run before the SSAValue→GlobalRef
callee-resolution step, matching their historical position exactly) and once
after (everything else). Disjoint keys make the double call a no-op for any
one `func`."""
function _try_builtin_lowering!(b::InstrBuilder, fb::InstrBuilder, ctx::AbstractCompilationContext,
                                 expr::Expr, idx::Int, args, func)::Union{InstrBuilder,Nothing}
    callee = _resolve_builtin_callee(func)
    lowering = get(BUILTIN_LOWERINGS, callee, nothing)
    lowering === nothing && return nothing
    return lowering(b, fb, ctx, expr, idx, args, callee)::Union{InstrBuilder,Nothing}
end

# ---- Early arms (run before the SSAValue→GlobalRef callee resolution) ------

# `Core.invoke_in_world(world, f, args...)` selects a method in Julia's
# mutable world-age model. A WT module is already one immutable collected
# world, so the exact lowering is the ordinary closed-world call to `f`;
# the captured world token has no runtime state to mutate.
function _lower_invoke_in_world!(b, fb, ctx, expr, idx, args, callee)
    length(args) >= 2 || return nothing
    # The intrinsic's Julia SSA result is `Any`, but that is a consumer-side
    # widening, not the callee's return contract. Do not use it to reject the
    # concrete collected target; statement storage will box/widen afterward.
    had_result = haskey(ctx.ssa_types, idx)
    old_result = get(ctx.ssa_types, idx, Any)
    delete!(ctx.ssa_types, idx)
    try
        return compile_call!(b, Expr(:call, args[2], args[3:end]...), idx, ctx)
    finally
        had_result && (ctx.ssa_types[idx] = old_result)
    end
end

function _lower_isdefinedglobal!(b, fb, ctx, expr, idx, args, callee)
    length(args) == 2 || return nothing
    module_owner = _trace_field_owner(args[1], :module, ctx)
    name_owner = _trace_field_owner(args[2], :singletonname, ctx)
    if module_owner !== nothing && isequal(module_owner, name_owner)
        tn_idx = ctx.type_registry.jl_typename_idx
        tn_idx === nothing && error("JlTypeName layout is unavailable")
        ib = _ctx_builder(ctx, "compile_call.isdefinedglobal_typename")
        emit_value!(ib, module_owner, ctx, ConcreteRef(UInt32(tn_idx), true))
        struct_get!(ib, tn_idx, UInt32(6), I32)
        append_builder!(b, ib)
        return b
    end
    return nothing
end

function _lower_isvisible!(b, fb, ctx, expr, idx, args, callee)
    length(args) == 3 || return nothing
    symbol_owner = _trace_typename_symbol_owner(args[1], ctx)
    parent_owner = _trace_field_owner(args[2], :module, ctx)
    if symbol_owner !== nothing && isequal(symbol_owner, parent_owner)
        vb = _ctx_builder(ctx, "compile_call.closed_world_isvisible")
        emit_closed_world_isvisible!(vb, args[1], args[2], args[3], symbol_owner, ctx)
        append_builder!(b, vb)
        return b
    end
    return nothing
end

# Base normally answers this by walking Julia's mutable BindingPartition
# history. A WT module has one immutable collection world, so TypeName
# constants carry the already-resolved answer. This is the single runtime
# route; no Binding object or partial partition chain exists in Wasm.
function _lower_check_world_bounded!(b, fb, ctx, expr, idx, args, callee)
    (length(args) == 1 && get_ssa_type(ctx, args[1]) === Core.TypeName) || return nothing
    wb = _ctx_builder(ctx, "compile_call.check_world_bounded")
    emit_closed_world_type_bounds!(wb, args[1], ctx)
    append_builder!(b, wb)
    return b
end

# ---- Late arms (run after the SSAValue→GlobalRef callee resolution) -------

# P3 gap 450889a9cb7e: `getglobal(mod, :name)` builtin (how typed IR reads
# const module globals like Base.Ryu.DIGIT_TABLE16) had NO handler and fell
# through to the unknown-call stub → every Ryu string(::Float64) trapped.
# With constant module + symbol args, resolve at compile time and compile
# the VALUE — compile_value materializes vector/struct/scalar constants.
#
# This is `getglobal`'s SECOND historical fragment only — the closed-world
# TypeName-tracing fragment (`compile_call!`'s `getglobal_typename` arm) runs
# BEFORE the SSAValue→GlobalRef resolution step and stays there unmigrated;
# folding it in here would let it start matching SSA-indirect `getglobal`
# calls it historically never saw.
function _lower_getglobal_constfold!(b, fb, ctx, expr, idx, args, callee)
    length(args) >= 2 || return nothing
    _gg_mod = args[1] isa QuoteNode ? args[1].value :
              args[1] isa GlobalRef ? (isdefined(args[1].mod, args[1].name) ?
                                       getfield(args[1].mod, args[1].name) : args[1]) :
              args[1]
    _gg_name = args[2] isa QuoteNode ? args[2].value : args[2]
    if _gg_mod isa Module && _gg_name isa Symbol && isdefined(_gg_mod, _gg_name) &&
       isconst(_gg_mod, _gg_name)
        _gg_val = getglobal(_gg_mod, _gg_name)
        emit_value!(fb, _gg_val, ctx, static_wasm_type(_gg_val, ctx))
        return append_builder!(b, fb)
    end
    return nothing
end

# `ifelse` is NOT registered here: its two `record_unsupported!` message
# strings ("ifelse condition did not lower to i32" / "ifelse operand emitted
# no runtime value") are pinned VERBATIM in `calls.jl` by ratchet lock
# L38_no_known_value_substitutions, which reads `calls.jl`'s own text — not
# this file's. It stays as an ordinary in-place arm in `compile_call!`.

# Special case for Core.sizeof - returns byte size
# For strings/arrays, this is the array length
function _lower_sizeof!(b, fb, ctx, expr, idx, args, callee)
    length(args) == 1 || return nothing
    arg = args[1]
    arg_type = infer_value_type(arg, ctx)

    if arg_type === String || arg_type <: AbstractVector || arg_type === Any
        # For strings and arrays, sizeof is the array length
        local _szb = _ctx_builder(ctx, "compile_call")
        # ONE 4-arg wrap replaces the sniff+cast ladder
        emit_value!(_szb, arg, ctx, ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))
        array_len!(_szb)
        # array.len returns i32, extend to i64 for Julia's Int
        num!(_szb, Opcode.I64_EXTEND_I32_S)
        append_builder!(fb, _szb)
        return append_builder!(b, fb)
    end
    # For other types, fall through to error
    return nothing
end

# ncodeunits(s) → array.len for string byte arrays
# Handles AbstractString fields from exception structs (e.g., e.msg)
function _lower_ncodeunits!(b, fb, ctx, expr, idx, args, callee)
    length(args) == 1 || return nothing
    arg = args[1]
    arg_type = infer_value_type(arg, ctx)
    if arg_type === String || arg_type <: AbstractString
        local _ncb = _ctx_builder(ctx, "compile_call")
        # ONE 4-arg wrap replaces the sniff+cast ladder
        emit_value!(_ncb, arg, ctx, ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))
        array_len!(_ncb)
        # Return as Int (i64) to match Julia's ncodeunits return type
        num!(_ncb, Opcode.I64_EXTEND_I32_S)
        append_builder!(fb, _ncb)
        return append_builder!(b, fb)
    end
    return nothing
end

# Special case for length - returns character count for strings, element count for arrays
function _lower_length!(b, fb, ctx, expr, idx, args, callee)
    length(args) == 1 || return nothing
    arg = args[1]
    arg_type = infer_value_type(arg, ctx)

    if arg_type === String
        # For strings, length is the array length (each char is one element)
        local _lnb = _ctx_builder(ctx, "compile_call")
        # (Wrap tail): ONE 4-arg wrap — the tracked type replaces the
        # ssa-local externref sniff; the funnel's string arm lands the DATA array
        emit_value!(_lnb, arg, ctx, ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))
        array_len!(_lnb)
        # array.len returns i32, extend to i64 for Julia's Int
        num!(_lnb, Opcode.I64_EXTEND_I32_S)
        append_builder!(fb, _lnb)
        return append_builder!(b, fb)
    elseif arg_type <: Array
        # For Vector/Array, length is v.size[1] (logical size from struct field 2)
        # Vector is now a struct with (typeId, ref, size) where size is Tuple{Int64}
        # NOTE: Only matches Array{T,N} (Vector, Matrix), NOT other AbstractVector
        # subtypes like StepRange, SubArray, ReinterpretArray — those fall through
        # to cross-function call handling so their specific length() methods compile.
        if haskey(ctx.type_registry.structs, arg_type)
            info = ctx.type_registry.structs[arg_type]
            local _lnb2 = _ctx_builder(ctx, "compile_call")

            # Get the vector struct
            emit_value!(_lnb2, arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))

            # Get field 2 (size tuple; field 0 = typeId, field 1 = ref)
            struct_get!(_lnb2, info.wasm_type_idx, wasm_field_idx(info, 2), AnyRef)

            # Get field 1 of the size tuple (the Int64 value; field 0 = typeId)
            # Size tuple is Tuple{Int64}
            size_tuple_type = Tuple{Int64}
            if haskey(ctx.type_registry.structs, size_tuple_type)
                size_info = ctx.type_registry.structs[size_tuple_type]
                struct_get!(_lnb2, size_info.wasm_type_idx, wasm_field_idx(size_info, 1), I64)
            end
            append_builder!(fb, _lnb2)
            return append_builder!(b, fb)
        end
    end
    # For other types, fall through to error
    return nothing
end

# Runtime-length tuple arity comes from its immutable size tuple.
function _lower_nfields!(b, fb, ctx, expr, idx, args, callee)
    length(args) == 1 || return nothing
    local tuple_type = get_ssa_type(ctx, args[1])
    if is_runtime_vararg_tuple_type(tuple_type)
        local info = register_vararg_tuple_type!(ctx.mod, ctx.type_registry, tuple_type)
        local size_info = ctx.type_registry.structs[Tuple{Int64}]
        local nb = _ctx_builder(ctx, "compile_call")
        emit_value!(nb, args[1], ctx, ConcreteRef(info.wasm_type_idx, true))
        struct_get!(nb, info.wasm_type_idx, wasm_field_idx(info, 2),
                    ConcreteRef(size_info.wasm_type_idx, true))
        struct_get!(nb, size_info.wasm_type_idx, wasm_field_idx(size_info, 1), I64)
        return append_builder!(b, nb)
    end
    return nothing
end

# `memoryref_isassigned(ref, ordering, boundscheck)`: inline/packed element
# arrays have no undefined representation and are always assigned. Reference
# arrays encode Julia's undefined slot as null and require an actual load.
function _lower_memoryref_isassigned!(b, fb, ctx, expr, idx, args, callee)
    isempty(args) && return nothing
    ref_arg = args[1]
    ref_type = get_ssa_type(ctx, ref_arg)
    elem_type = if ref_type isa DataType && ref_type.name.name === :GenericMemoryRef
        ref_type.parameters[2]
    elseif ref_type isa DataType && ref_type.name.name === :MemoryRef
        ref_type.parameters[1]
    else
        Any
    end
    array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
    arr_def = ctx.mod.types[array_type_idx + 1]
    elem_wasm = arr_def isa ArrayType ? arr_def.elem.valtype : AnyRef
    mib = _ctx_builder(ctx, "compile_call.memoryref_isassigned")
    emit_value!(mib, ref_arg, ctx)  # R17-floor: consumes MemoryRef's tracked (array,index) multi-value representation
    if _wt_is_ref(elem_wasm)
        array_get!(mib, array_type_idx, elem_wasm;
                   signed=packed_array_signedness(elem_type))
        ref_is_null!(mib); num!(mib, Opcode.I32_EQZ)
    else
        drop!(mib) # index
        drop!(mib) # array
        i32_const!(mib, 1)
    end
    append_builder!(fb, mib)
    return append_builder!(b, fb)
end

# Special case for memoryrefget - array element access
# memoryrefget(ref, ordering, boundscheck) where ref is from memoryrefnew
function _lower_memoryrefget!(b, fb, ctx, expr, idx, args, callee)
    length(args) >= 1 || return nothing
    ref_arg = args[1]
    ref_type = infer_value_type(ref_arg, ctx)

    # Nothing-typed memory — always returns nothing (i32.const 0).
    # Consume the [array_ref, i32_index] stack pair from memoryrefnew, then push 0.
    if ref_type isa DataType && (
        (ref_type.name.name === :MemoryRef && length(ref_type.parameters) >= 1 && ref_type.parameters[1] === Nothing) ||
        (ref_type.name.name === :GenericMemoryRef && length(ref_type.parameters) >= 2 && ref_type.parameters[2] === Nothing))
        # Compile ref_arg to push [array_ref, i32_index], then drop both
        emit_value!(fb, ref_arg, ctx)  # R17-floor: MemoryRef{Nothing} is a deliberate two-value emission
        drop!(fb)  # drop i32_index
        drop!(fb)  # drop array_ref
        i32_const!(fb, 0)
        return append_builder!(b, fb)
    end

    # Extract element type from MemoryRef{T}, GenericMemoryRef{atomicity, T, addrspace},
    # Memory{T}, or GenericMemory{atomicity, T, addrspace}
    # Also handle Memory types for direct array access patterns
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

    # Handle UnionAll MemoryRef types (bare MemoryRef without parameters)
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
    local _mrgb = _ctx_builder(ctx, "compile_call")
    emit_value!(_mrgb, ref_arg, ctx)  # R17-floor: memoryrefget consumes the emitted (array,index) pair

    array_get!(_mrgb, array_type_idx, AnyRef; signed=packed_array_signedness(elem_type))

    # Note: if elem_type is Any, array.get returns externref and the SSA local
    # is also typed as externref (fixed in analyze_ssa_types!). No cast needed here.
    append_builder!(fb, _mrgb)
    return append_builder!(b, fb)
end

# Special case for memoryrefoffset - get the 1-based offset of a MemoryRef
# This is used by push!, resize!, and other dynamic array operations
# Fresh MemoryRefs (from Core.memoryref, getfield(vec, :ref)) have offset 1
# Indexed MemoryRefs (from memoryrefnew(ref, index, bc)) have offset = index
function _lower_memoryrefoffset!(b, fb, ctx, expr, idx, args, callee)
    length(args) >= 1 || return nothing
    ref_arg = args[1]

    # Check if this ref came from a memoryrefnew with an index
    local _mrob = _ctx_builder(ctx, "compile_call")
    if ref_arg isa Core.SSAValue && haskey(ctx.memoryref_offsets, ref_arg.id)
        # This MemoryRef has a recorded offset - compile the index value
        index_val = ctx.memoryref_offsets[ref_arg.id]
        idx_type = infer_value_type(index_val, ctx)
        emit_value!(_mrob, index_val, ctx,
                    (idx_type === Int64 || idx_type === Int) ? I64 : I32)

        # Ensure result is i64 (Julia's Int)
        if idx_type !== Int64 && idx_type !== Int
            # Convert to i64 if needed
            num!(_mrob, Opcode.I64_EXTEND_I32_S)
        end
    else
        # Fresh MemoryRef - offset is always 1
        i64_const!(_mrob, 1)  # 1
    end
    append_builder!(fb, _mrob)
    return append_builder!(b, fb)
end

# Special case for memoryrefset! - array element assignment
# memoryrefset!(ref, value, ordering, boundscheck) -> stores value in array
# In Julia, setindex! returns the stored value, so we need to return it too
function _lower_memoryrefset!(b, fb, ctx, expr, idx, args, callee)
    length(args) >= 2 || return nothing
    ref_arg = args[1]
    value_arg = args[2]
    ref_type = infer_value_type(ref_arg, ctx)

    # Nothing-typed memory — storing nothing is a no-op.
    # Consume the [array_ref, i32_index] stack pair from memoryrefnew, then done.
    # Don't push a result — Nothing has no Wasm representation to keep on the stack.
    if ref_type isa DataType && (
        (ref_type.name.name === :MemoryRef && length(ref_type.parameters) >= 1 && ref_type.parameters[1] === Nothing) ||
        (ref_type.name.name === :GenericMemoryRef && length(ref_type.parameters) >= 2 && ref_type.parameters[2] === Nothing))
        emit_value!(fb, ref_arg, ctx)  # R17-floor: MemoryRef{Nothing} pair is consumed without a scalar sink
        drop!(fb)  # drop i32_index
        drop!(fb)  # drop array_ref
        return append_builder!(b, fb)
    end

    # Extract element type from MemoryRef{T}, GenericMemoryRef{atomicity, T, addrspace},
    # Memory{T}, or GenericMemory{atomicity, T, addrspace}
    # Also handle Memory types for direct array access patterns
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

    # Handle UnionAll MemoryRef types (bare MemoryRef without parameters)
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
    local _msb = _ctx_builder(ctx, "compile_call")
    emit_value!(_msb, ref_arg, ctx)  # R17-floor: memoryrefset consumes the emitted (array,index) pair

    # Compile the value to store - we need it twice (for array.set and return)
    # First compile gets the value on stack for array.set
    local _mv_b = _compile_value_b(value_arg, ctx)
    local mset_val_ty = isempty(_mv_b.v.stack) ? nothing : _mv_b.v.stack[end]
    # If array element type is anyref/externref (elem_type is Any OR abstract type), box numeric values
    # Check the actual wasm element type, not just elem_type === Any
    # Abstract types like CallInfo also map to ExternRef
    # PHASE-1-004: AnyRef arrays (Memory{Any}) need numeric→anyref boxing via struct.new
    local wasm_elem_type = get_concrete_wasm_type(elem_type, ctx.mod, ctx.type_registry)
    if wasm_elem_type === AnyRef
        # AnyRef array element — box numeric values to anyref via struct.new.
        # dart2wasm carries the type with the value rather than scanning bytes.
        local mset_src_wasm_any = mset_val_ty
        local is_numeric_mset_any = mset_src_wasm_any === I64 || mset_src_wasm_any === I32 || mset_src_wasm_any === F64 || mset_src_wasm_any === F32
        local is_already_anyref = mset_src_wasm_any === AnyRef || mset_src_wasm_any === StructRef || mset_src_wasm_any isa ConcreteRef
        if is_numeric_mset_any
            emit_numeric_to_anyref!(_msb, value_arg, mset_src_wasm_any, ctx)
        else
            append_builder!(_msb, _mv_b)
            # A KNOWN closure erasing into a Memory{Any} slot wraps into
            # the closure OBJECT (dart convertType at the erasure seam)
            maybe_wrap_closure!(_msb, ctx, infer_value_type(value_arg, ctx))
            if !is_already_anyref && mset_src_wasm_any === ExternRef
                any_convert_extern!(_msb)
            end
        end
    elseif wasm_elem_type === ExternRef
        # Determine source value's wasm type to decide conversion.
        # dart2wasm carries the type with the value rather than scanning bytes.
        local mset_src_wasm = mset_val_ty
        local is_numeric_mset = mset_src_wasm === I64 || mset_src_wasm === I32 || mset_src_wasm === F64 || mset_src_wasm === F32
        local is_already_externref_mset = mset_src_wasm === ExternRef
        if is_numeric_mset
            emit_numeric_to_externref!(_msb, value_arg, mset_src_wasm, ctx)
        else
            append_builder!(_msb, _mv_b)
            # Skip extern_convert_any if value is already externref.
            # externref is NOT a subtype of anyref, so extern_convert_any would fail.
            if !is_already_externref_mset
                extern_convert_any!(_msb)
            end
        end
    elseif wasm_elem_type isa ConcreteRef
        # Array of concrete ref types (e.g., struct or array refs)
        # If value is numeric (nothing represented as i32_const 0), emit ref.null instead
        # (Typed): numeric-typed value into a ref-typed array slot → ref.null
        # (the const first-byte gate + LOCAL_GET LEB walk are the tracked type now)
        if mset_val_ty === I64 || mset_val_ty === I32 || mset_val_ty === F64 || mset_val_ty === F32
            ref_null!(_msb, Int64(wasm_elem_type.type_idx), ConcreteRef(UInt32(wasm_elem_type.type_idx), true))
        else
            append_builder!(_msb, _mv_b)
            # If value is externref but array element is concrete ref,
            # convert externref → anyref → ref.cast (ref null $elem_type)
            if mset_val_ty === ExternRef
                any_convert_extern!(_msb)
                ref_cast!(_msb, Int64(wasm_elem_type.type_idx), true)
            end
        end
    else
        # TRUE-INT-002-impl2: When storing nothing (i32_const 0) into an i64 array
        # (e.g., Union{Nothing, Int64} element type), emit i64_const 0 instead.
        # compile_value(nothing) always produces i32_const 0, but array_set expects
        # the element type — i64 for Union{Nothing, Int64} arrays.
        if wasm_elem_type === I64 && mset_val_ty === I32
            i64_const!(_msb, 0)  # i64 value 0
        elseif wasm_elem_type === F64 && mset_val_ty === I32
            f64_const!(_msb, 0.0)
        else
            append_builder!(_msb, _mv_b)
        end
    end

    # array.set consumes [array_ref, i32_index, value] and returns nothing
    array_set!(_msb, array_type_idx, AnyRef)

    # Julia's memoryrefset! returns the stored value, so push it again
    # This is needed because compile_statement may add LOCAL_SET after this
    # Only emit return value if SSA has a local to store it in.
    # Without this guard, the return value (e.g., i32.const 0 for nothing)
    # is left on the stack when the SSA has no allocated local, causing
    # "values remaining on stack at end of block" validation errors.
    if haskey(ctx.ssa_locals, idx)
        local _rv2_b = _compile_value_b(value_arg, ctx)
        local ret_val_ty = isempty(_rv2_b.v.stack) ? nothing : _rv2_b.v.stack[end]
        append_builder!(_msb, _rv2_b)
        # An externref-typed result local needs the GC value converted; the
        # typed channel says what the pushed value is.
        local mset_ret_local = ctx.ssa_locals[idx]
        local mset_ret_arr_idx = mset_ret_local - ctx.n_params + 1
        if mset_ret_arr_idx >= 1 && mset_ret_arr_idx <= length(ctx.locals) &&
           ctx.locals[mset_ret_arr_idx] === ExternRef &&
           (ret_val_ty isa ConcreteRef || ret_val_ty === StructRef || ret_val_ty === ArrayRef || ret_val_ty === AnyRef)
            extern_convert_any!(_msb)
        end
    end
    append_builder!(fb, _msb)
    return append_builder!(b, fb)
end

# Special case for Core.memorynew - creates a new Memory{T} backing store
# memorynew(Memory{T}, size) -> Memory{T}
# In WasmGC, Memory{T} IS an array, so this compiles to array.new_default
function _lower_memorynew!(b, fb, ctx, expr, idx, args, callee)
    length(args) >= 2 || return nothing
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
    local _mnb = _ctx_builder(ctx, "compile_call")
    if size_arg isa Int || size_arg isa Int64
        # Literal size - emit as i32 constant with minimum capacity
        actual_size = max(Int64(size_arg), min_capacity)
        i32_const!(_mnb, actual_size)
    else
        # SSA or other expression - compile, convert to i32, apply minimum
        emit_value!(_mnb, size_arg, ctx, I64)   # the wrap-to-i32 follows — the value is an I64 index
        num!(_mnb, Opcode.I32_WRAP_I64)
        # Ensure minimum capacity: max(size, min_capacity)
        local cap_check_local = allocate_local!(ctx, I32)
        local_tee!(_mnb, cap_check_local)
        i32_const!(_mnb, Int64(min_capacity))
        local_get!(_mnb, cap_check_local)
        i32_const!(_mnb, Int64(min_capacity))
        num!(_mnb, Opcode.I32_GE_S)
        select!(_mnb)  # select(size, min_cap, size >= min_cap)
    end

    array_new_default!(_mnb, arr_type_idx)
    append_builder!(fb, _mnb)
    return append_builder!(b, fb)
end

# Special case for Core.memoryref - creates MemoryRef from Memory
# memoryref(memory::Memory{T}) -> MemoryRef{T}
# In WasmGC, this is a no-op since Memory IS the array
function _lower_memoryref!(b, fb, ctx, expr, idx, args, callee)
    length(args) == 1 || return nothing
    # Pass through the array reference - Memory and MemoryRef are the same in WasmGC
    emit_value!(fb, args[1], ctx)  # R17-floor: memoryref identity preserves its array representation
    return append_builder!(b, fb)
end

# Special case for memoryrefnew - handle both patterns:
# 1. memoryrefnew(memory) -> MemoryRef (for Vector allocation, just pass through)
# 2. memoryrefnew(base_ref, index, boundscheck) -> MemoryRef at offset
function _lower_memoryrefnew!(b, fb, ctx, expr, idx, args, callee)
    if length(args) == 1
        # Single arg: just wrapping a Memory - pass through the array reference
        # This is a "fresh" MemoryRef with offset 1
        emit_value!(fb, args[1], ctx)  # R17-floor: one-arg memoryrefnew preserves representation
        return append_builder!(b, fb)
    elseif length(args) >= 2
        base_ref = args[1]
        index = args[2]

        # Record the offset for this MemoryRef SSA so memoryrefoffset can use it
        ctx.memoryref_offsets[idx] = index

        # For Nothing-typed MemoryRef, check if result is used.
        # If the SSA has no local and no subsequent statement references it,
        # skip bytecode to avoid orphaning [array_ref, i32_index] on the stack.
        ssa_type_mr = get(ctx.ssa_types, idx, Any)
        is_nothing_ref_mr = ssa_type_mr isa DataType && (
            (ssa_type_mr.name.name === :MemoryRef && length(ssa_type_mr.parameters) >= 1 && ssa_type_mr.parameters[1] === Nothing) ||
            (ssa_type_mr.name.name === :GenericMemoryRef && length(ssa_type_mr.parameters) >= 2 && ssa_type_mr.parameters[2] === Nothing))
        if is_nothing_ref_mr && !haskey(ctx.ssa_locals, idx)
            # Check if any subsequent statement uses this SSA
            ssa_used = false
            for j in (idx+1):length(ctx.code_info.code)
                s = ctx.code_info.code[j]
                if s isa Expr
                    for a in s.args
                        if a isa Core.SSAValue && a.id == idx
                            ssa_used = true
                            break
                        end
                    end
                end
                ssa_used && break
            end
            if !ssa_used
                return append_builder!(b, fb)  # Skip — orphaned MemoryRef{Nothing}
            end
        end

        # Compile the base array reference
        local _mrnb = _ctx_builder(ctx, "compile_call")
        emit_value!(_mrnb, base_ref, ctx)  # R17-floor: base may itself be a virtual MemoryRef pair

        # Compile and convert index to i32 (Julia uses 1-based Int64, Wasm uses 0-based)
        emit_value!(_mrnb, index, ctx)  # R17-floor: actual index width selects the explicit wrap below

        # Check BOTH Julia type AND actual WASM type for i64→i32 wrap.
        # infer_value_type may return Any/Union while the actual local is i64.
        idx_type = infer_value_type(index, ctx)
        idx_wasm = get_phi_edge_wasm_type(index, ctx)
        if idx_type === Int64 || idx_type === Int || idx_wasm === I64
            # Convert to i32 and subtract 1 for 0-based indexing
            num!(_mrnb, Opcode.I32_WRAP_I64)  # i64 -> i32
        end
        i32_const!(_mrnb, 1)  # 1
        num!(_mrnb, Opcode.I32_SUB)  # index - 1 for 0-based

        # Now stack has [array_ref, i32_index] which is what memoryrefget needs
        append_builder!(fb, _mrnb)
        return append_builder!(b, fb)
    end
    return nothing
end

# Special case for Core.tuple - tuple creation
function _lower_tuple!(b, fb, ctx, expr, idx, args, callee)
    length(args) > 0 || return nothing
    # Infer tuple type from arguments
    elem_types = Type[infer_value_type(arg, ctx) for arg in args]
    tuple_type = Tuple{elem_types...}

    # Register tuple type
    if !haskey(ctx.type_registry.structs, tuple_type)
        register_tuple_type!(ctx.mod, ctx.type_registry, tuple_type)
    end

    if haskey(ctx.type_registry.structs, tuple_type)
        info = ctx.type_registry.structs[tuple_type]

        local _tupb = _ctx_builder(ctx, "compile_call")
        emit_struct_prefix!(_tupb, ctx.type_registry, tuple_type, info)

        # Push all tuple elements with type safety for externref fields
        # Core.tuple args may be phi locals typed as i64 but
        # struct field expects externref (Any-typed tuple element)
        struct_type_def = ctx.mod.types[info.wasm_type_idx + 1]
        for (fi, arg) in enumerate(args)
            # (Typed): the first-byte const scans + LOCAL_GET LEB decodes are
            # gone — arg_ty (the tracked emission type) decides; const-vs-local is an
            # ir/-level kind test (dart looks at node kinds, never at bytes).
            local _ab = _compile_value_b(arg, ctx)
            local arg_ty = isempty(_ab.v.stack) ? nothing : _ab.v.stack[end]
            expected_wasm = nothing
            # Account for typeId at field 0: struct_type_def.fields is 1-indexed,
            # wasm field for Julia field fi is at position fi + field_offset
            local wasm_fi = fi + Int(info.field_offset)
            if struct_type_def isa StructType && wasm_fi <= length(struct_type_def.fields)
                expected_wasm = struct_type_def.fields[wasm_fi].valtype
            end
            expected_wasm isa WasmValType || error("tuple field $fi has no physical Wasm type")
            append_builder!(_tupb, _ab)
            if arg_ty !== nothing && arg_ty !== expected_wasm
                local _tuple_jt = _value_julia_type(arg, ctx)
                coerce_stack_top!(_tupb, expected_wasm, ctx;
                                  from_julia=(_tuple_jt isa Type && isconcretetype(_tuple_jt)) ? _tuple_jt : nothing)
            end
        end

        # struct.new
        struct_new!(_tupb, info.wasm_type_idx)   # mod-resolved fields

        append_builder!(fb, _tupb)
        return append_builder!(b, fb)
    end
    return nothing
end

# Core.donotdelete — compiler fence preventing DCE. No WASM output needed.
# Arguments were already evaluated by the caller's IR; we just skip emitting.
# Used by WASM import stubs (Canvas2D, etc.) to keep calls alive in optimized IR.
function _lower_donotdelete!(b, fb, ctx, expr, idx, args, callee)
    return append_builder!(b, fb)
end

# Special case for compilerbarrier - just pass through the value
function _lower_compilerbarrier!(b, fb, ctx, expr, idx, args, callee)
    # compilerbarrier(kind, value) - first arg is a symbol, second is the value
    # We only want the value (second arg)
    if length(args) >= 2
        emit_value!(fb, args[2], ctx, static_wasm_type(args[2], ctx))
    end
    return append_builder!(b, fb)
end

# Runtime Union construction is Dart's RTI union node: a real $JlUnion
# containing the two runtime type operands. This is the dynamic counterpart
# of get_type_constant_global!(Union{A,B}); no host type fabrication occurs.
function _lower_apply_type!(b, fb, ctx, expr, idx, args, callee)
    length(args) == 3 || return nothing
    union_ctor = args[1] === Union ||
        (args[1] isa GlobalRef && isdefined(args[1].mod, args[1].name) &&
         getfield(args[1].mod, args[1].name) === Union)
    if union_ctor
        union_idx = ctx.type_registry.jl_union_idx
        jl_type_idx = ctx.type_registry.jl_type_idx
        (union_idx === nothing || jl_type_idx === nothing) &&
            error("runtime Union construction requires the JlType hierarchy")
        ub = _ctx_builder(ctx, "compile_apply_type_union")
        i32_const!(ub, 1) # TYPE_UNION
        expected_type = ConcreteRef(jl_type_idx, true)
        emit_value!(ub, args[2], ctx, expected_type)
        emit_value!(ub, args[3], ctx, expected_type)
        struct_new!(ub, union_idx,
                    WasmValType[I32, expected_type, expected_type])
        append_builder!(fb, ub)
        return append_builder!(b, fb)
    end
    return nothing
end

# typeof(x) returns the one $JlDataType representation.  The closed-world
# planner materializes both the lookup table and every reachable static type
# global before function bodies are emitted.
function _lower_typeof!(b, fb, ctx, expr, idx, args, callee)
    length(args) >= 1 || return nothing
    arg = args[1]
    arg_type = infer_value_type(arg, ctx)
    ctx.type_registry.type_lookup_global === nothing &&
        error("typeof lowering requires the canonical type lookup table")
    base_idx = ctx.type_registry.base_struct_idx
    base_idx === nothing && error("typeof lowering requires the canonical object base")

    local _tofb = _ctx_builder(ctx, "compile_call")
    if arg_type !== nothing && isconcretetype(arg_type)
        haskey(ctx.type_registry.type_constant_globals, arg_type) ||
            error("closed-world typeof is missing the static type global for $arg_type")
        dt_global = ctx.type_registry.type_constant_globals[arg_type]
        global_get!(_tofb, dt_global, ctx.mod.globals[dt_global + 1].valtype)
    else
        actual_type = emit_value!(_tofb, arg, ctx)  # R17-floor: typeof inspects the value's actual heap representation
        actual_type === ExternRef && any_convert_extern!(_tofb)
        temp_local = _ensure_typeof_scratch_local!(ctx)
        emit_typeof_struct_with_local!(_tofb, base_idx, ctx.type_registry, temp_local)
    end
    append_builder!(fb, _tofb)
    return append_builder!(b, fb)
end

# `typeassert` is NOT registered here: `_emit_typeerror_throw!(fb, args[1],
# _ta_target, idx, ctx)` — its runtime-check call site — is pinned VERBATIM in
# `calls.jl` by ratchet lock L57_exact_typeassert_exception, which reads only
# `calls.jl` (+ the real_bottom_exceptions.jl test). It stays an in-place arm.

# Special case for string/symbol equality/identity comparison (=== and !==)
# Must be handled before generic argument pushing since strings/symbols are refs, not integers
# Symbol uses same array<i32> representation as String, so ref.eq would fail (reference equality)
#
# ONE lowering for both `Core.:(===)` and `Core.:(!==)` (registered under both
# keys) — negation is decided from `callee`'s identity, never a name test.
function _lower_egal_early!(b, fb, ctx, expr, idx, args, callee)
    length(args) == 2 || return nothing
    is_ne = callee === Core.:(!==)
    arg1_type = infer_value_type(args[1], ctx)
    arg2_type = infer_value_type(args[2], ctx)
    if (arg1_type === String || arg1_type === Symbol) && (arg2_type === String || arg2_type === Symbol)
        local _seqb = _ctx_builder(ctx, "compile_call")
        append_builder!(_seqb, compile_string_equal_b(args[1], args[2], ctx))
        if is_ne
            # Negate the result for !==
            num!(_seqb, Opcode.I32_EQZ)
        end
        append_builder!(fb, _seqb)
        return append_builder!(b, fb)
    end

    # typeof(x) === Type — compare DataType struct refs with ref.eq
    # Detect when one arg comes from typeof() and the other is a Type constant
    arg1_is_typeof = _is_typeof_ssa(args[1], ctx)
    arg2_is_typeof = _is_typeof_ssa(args[2], ctx)
    arg1_is_type_const = _resolve_type_const(args[1], ctx)
    arg2_is_type_const = _resolve_type_const(args[2], ctx)
    if (arg1_is_typeof && arg2_is_type_const !== nothing) ||
       (arg2_is_typeof && arg1_is_type_const !== nothing)
        ctx.type_registry.type_lookup_global === nothing &&
            error("typeof identity comparison requires the canonical type lookup table")
        local _toeqb = _ctx_builder(ctx, "compile_call")
        if arg1_is_typeof
            emit_value!(_toeqb, args[1], ctx)  # R17-floor: dynamic egal classifies the actual operand
            haskey(ctx.type_registry.type_constant_globals, arg2_is_type_const) ||
                error("closed-world typeof identity is missing the type global for $arg2_is_type_const")
            dt_global = ctx.type_registry.type_constant_globals[arg2_is_type_const]
            global_get!(_toeqb, dt_global, ctx.mod.globals[dt_global + 1].valtype)
        else
            emit_value!(_toeqb, args[2], ctx)  # R17-floor: dynamic egal classifies the actual operand
            haskey(ctx.type_registry.type_constant_globals, arg1_is_type_const) ||
                error("closed-world typeof identity is missing the type global for $arg1_is_type_const")
            dt_global = ctx.type_registry.type_constant_globals[arg1_is_type_const]
            global_get!(_toeqb, dt_global, ctx.mod.globals[dt_global + 1].valtype)
        end
        num!(_toeqb, Opcode.REF_EQ)
        if is_ne
            num!(_toeqb, Opcode.I32_EQZ)
        end
        append_builder!(fb, _toeqb)
        return append_builder!(b, fb)
    end

    # Special case: comparing ref type with nothing - use ref.is_null
    arg1_is_nothing = is_nothing_value(args[1], ctx)
    arg2_is_nothing = is_nothing_value(args[2], ctx)

    if (arg1_is_nothing && is_ref_type_or_union(arg2_type)) ||
       (arg2_is_nothing && is_ref_type_or_union(arg1_type))
        # Compile the non-nothing ref argument (typed channel)
        local _nv_b = _compile_value_b(arg1_is_nothing ? args[2] : args[1], ctx)
        local _nv_ty = isempty(_nv_b.v.stack) ? nothing : _nv_b.v.stack[end]
        # typed channel: numeric values can never be null — the emission's own type
        # answers (was a LOCAL_GET LEB decode + const first-byte scan + static re-guess).
        local is_numeric_val = _nv_ty === I32 || _nv_ty === I64 || _nv_ty === F32 || _nv_ty === F64
        local _neqb = _ctx_builder(ctx, "compile_call")
        if is_numeric_val
            # Numeric value can never be nothing
            # === nothing → false (0), !== nothing → true (1)
            i32_const!(_neqb, is_ne ? 1 : 0)
            append_builder!(fb, _neqb)
            return append_builder!(b, fb)
        end
        append_builder!(_neqb, _nv_b)   # typed merge
        # ref.is_null checks if ref is null (returns i32 1 for null, 0 otherwise)
        ref_is_null!(_neqb)
        if is_ne
            # Negate for !== (we want true when NOT null)
            num!(_neqb, Opcode.I32_EQZ)
        end
        append_builder!(fb, _neqb)
        return append_builder!(b, fb)
    end
    return nothing
end

# ---- Registry population ---------------------------------------------------
# One entry per builtin identity. Aliases (e.g. isvisible/_closed_world_isvisible)
# map to the SAME lowering function, matching dart's KernelNodes resolving
# multiple call shapes to one intrinsic.

BUILTIN_LOWERINGS[Core.invoke_in_world] = _lower_invoke_in_world!
BUILTIN_LOWERINGS[Base.isdefinedglobal] = _lower_isdefinedglobal!
BUILTIN_LOWERINGS[Base.isvisible] = _lower_isvisible!
BUILTIN_LOWERINGS[_closed_world_isvisible] = _lower_isvisible!
BUILTIN_LOWERINGS[Base.check_world_bounded] = _lower_check_world_bounded!
BUILTIN_LOWERINGS[_closed_world_type_bounds] = _lower_check_world_bounded!

BUILTIN_LOWERINGS[Core.getglobal] = _lower_getglobal_constfold!
# `Core.sizeof` (the builtin `code_typed` actually resolves calls to) and
# `Base.sizeof` (the generic function) are DIFFERENT objects — `is_func`
# matched either by bare name, so both keys route to the same lowering.
BUILTIN_LOWERINGS[Core.sizeof] = _lower_sizeof!
BUILTIN_LOWERINGS[Base.sizeof] = _lower_sizeof!
BUILTIN_LOWERINGS[Base.ncodeunits] = _lower_ncodeunits!
BUILTIN_LOWERINGS[Base.length] = _lower_length!
BUILTIN_LOWERINGS[Core.nfields] = _lower_nfields!
BUILTIN_LOWERINGS[Core.memoryref_isassigned] = _lower_memoryref_isassigned!
BUILTIN_LOWERINGS[Core.memoryrefget] = _lower_memoryrefget!
BUILTIN_LOWERINGS[Core.memoryrefoffset] = _lower_memoryrefoffset!
BUILTIN_LOWERINGS[Core.memoryrefset!] = _lower_memoryrefset!
BUILTIN_LOWERINGS[Core.memorynew] = _lower_memorynew!
BUILTIN_LOWERINGS[Core.memoryref] = _lower_memoryref!
BUILTIN_LOWERINGS[Core.memoryrefnew] = _lower_memoryrefnew!
BUILTIN_LOWERINGS[Core.tuple] = _lower_tuple!
BUILTIN_LOWERINGS[Core.donotdelete] = _lower_donotdelete!
BUILTIN_LOWERINGS[Core.compilerbarrier] = _lower_compilerbarrier!
BUILTIN_LOWERINGS[Core.apply_type] = _lower_apply_type!
BUILTIN_LOWERINGS[Core.typeof] = _lower_typeof!
BUILTIN_LOWERINGS[Core.:(===)] = _lower_egal_early!
BUILTIN_LOWERINGS[Core.:(!==)] = _lower_egal_early!
