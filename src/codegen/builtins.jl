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
# A builtin with SEVERAL fragments in the retired ladder holds them as its own
# guards, tried in their original relative order behind one key (`getglobal`'s
# const-fold then TypeName trace; `getfield`'s layout fold, signal read,
# closure self-capture skip, `:signal` skip and general field read;
# `===`'s string/typeof/nothing special cases then the width-keyed
# comparison). Every entry emits its OWN operands — dart's intrinsics wrap
# `node.arguments.positional[i]` themselves and nothing is pre-pushed for them
# — so no entry depends on where in `compile_call!` the funnel is consulted.
# That single consult, and the absence of any name-keyed arm after it, is
# locked (L113, L124) and modelled (dev/formal/ConsultChain.tla).
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
nullable-return entry-funnel shape. Called ONCE from `compile_call!`, directly
after its ONE SSAValue→GlobalRef callee-resolution step, mirroring dart's
resolve-the-target-once dispatch (`KernelNodes._lookup`, intrinsics.dart:401).
formal(dev/formal/ConsultChain.tla)."""
function _try_builtin_lowering!(b::InstrBuilder, fb::InstrBuilder, ctx::AbstractCompilationContext,
                                 expr::Expr, idx::Int, args, func)::Union{InstrBuilder,Nothing}
    callee = _resolve_builtin_callee(func)
    lowering = get(BUILTIN_LOWERINGS, callee, nothing)
    lowering === nothing && return nothing
    return lowering(b, fb, ctx, expr, idx, args, callee)::Union{InstrBuilder,Nothing}
end

# ---- The entries -----------------------------------------------------------

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

# P3 gap 450889a9cb7e: `getglobal(mod, :name)` builtin (how typed IR reads
# const module globals like Base.Ryu.DIGIT_TABLE16) had NO handler and fell
# through to the unknown-call stub → every Ryu string(::Float64) trapped.
# With constant module + symbol args, resolve at compile time and compile
# the VALUE — compile_value materializes vector/struct/scalar constants.
#
# `getglobal` has TWO guards, tried in their historical order: the const-fold
# above, then the closed-world TypeName trace below (formerly `compile_call!`'s
# `is_func(func, :getglobal)` arm, which sat immediately after this entry and
# could only run because this entry had declined). They are independently
# discriminating and disjoint, so one entry holding both is dart's shape: ONE
# identity, its own guards in order (intrinsics.dart's per-intrinsic shape
# tests). formal(dev/formal/ConsultChain.tla).
function _lower_getglobal!(b, fb, ctx, expr, idx, args, callee)
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
    module_owner = _trace_field_owner(args[1], :module, ctx)
    name_owner = _trace_field_owner(args[2], :singletonname, ctx)
    if module_owner !== nothing && isequal(module_owner, name_owner)
        tn_idx = ctx.type_registry.jl_typename_idx
        jl_type_idx = ctx.type_registry.jl_type_idx
        ib = _ctx_builder(ctx, "compile_call.getglobal_typename")
        emit_value!(ib, module_owner, ctx, ConcreteRef(UInt32(tn_idx), true))
        struct_get!(ib, tn_idx, UInt32(4), ConcreteRef(UInt32(jl_type_idx), true))
        append_builder!(b, ib)
        return b
    end
    return nothing
end

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
        widen_length_to_i64!(_szb)
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
        widen_length_to_i64!(_ncb)
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
        widen_length_to_i64!(_lnb)
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
        emit_value!(_mrob, index_val, ctx, I64)   # the offset is Julia's Int; a narrower index widens through the funnel
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
        emit_value!(_mnb, size_arg, ctx, I32)   # a Julia Int size narrows through the funnel
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

        # the index narrows to i32 through the funnel (Julia is 1-based Int; wasm is 0-based i32)
        emit_value!(_mrnb, index, ctx, I32)
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

# `Core._expr(:head, arg1, arg2, ...)` — materializes an `Expr(head::Symbol,
# args::Vector{Any})`. Julia-only (dart has no `Expr` node); the WasmGC
# representation is a classed Expr struct wrapping a head Symbol (a classed
# string) and a Vector{Any} of the remaining args. Self-contained: emits its
# own operands directly onto `fb` (R19 — this identity match used to gate a
# `_skip_arg_prepush` carve-out in `compile_call!`'s generic arg-push loop;
# consulted from THE identity-keyed funnel instead, this call never reaches
# that loop at all, so no carve-out is needed there any more).
function _lower_expr!(b, fb, ctx, expr, idx, args, callee)
    # Register Expr type if not already registered
    if !haskey(ctx.type_registry.structs, Expr)
        register_struct_type!(ctx.mod, ctx.type_registry, Expr)
    end
    haskey(ctx.type_registry.structs, Expr) || return append_builder!(b, fb)
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
    # parity(class_info.dart:18 FieldIndex): the head Symbol is a CLASSED string value
    head_local = allocate_local!(ctx, ConcreteRef(get_string_struct_type!(ctx.mod, ctx.type_registry), true))
        emit_value!(fb, head_arg, ctx, static_wasm_type(head_arg, ctx))
        local_set!(fb, head_local)

    # Step 2: Create data array (array<anyref>) → local
    # Any maps to the registered array element type. Every element flows
    # through the typed boxing/conversion chokepoint.
    wasm_elem_type = get_concrete_wasm_type(Any, ctx.mod, ctx.type_registry)
    if n_expr_args == 0
            i32_const!(fb, 0)
            array_new_default!(fb, any_array_type_idx)
    else
        # Push each arg, then array_new_fixed
        for ea in expr_args
            emit_value!(fb, ea, ctx, wasm_elem_type)
        end
            array_new_fixed!(fb, any_array_type_idx, n_expr_args, wasm_elem_type)
    end
    data_arr_local = allocate_local!(ctx, ConcreteRef(any_array_type_idx, true))
        local_set!(fb, data_arr_local)

        # Step 3: Create Tuple{Int64} for size → local (typeId, then value)
        emit_struct_prefix!(fb, ctx.type_registry, Tuple{Int64}, size_tuple_info)
        i64_const!(fb, Int64(n_expr_args))
        struct_new!(fb, size_tuple_info.wasm_type_idx)   # mod-resolved fields
    size_local = allocate_local!(ctx, ConcreteRef(size_tuple_info.wasm_type_idx, true))
    let ib = _sub_builder(fb, ctx, "compile_call", 1)   # the size tuple
        local_set!(ib, size_local)

        # Step 4: Assemble Expr struct
        emit_struct_prefix!(ib, ctx.type_registry, Expr, expr_info)
        # Push head (Expr field 1)
        local_get!(ib, head_local)
        # Create Vector{Any} inline (Expr field 2): push typeId, data_array, size_tuple, struct.new
        emit_struct_prefix!(ib, ctx.type_registry, Vector{Any}, vec_any_info)
        local_get!(ib, data_arr_local)
        local_get!(ib, size_local)
        struct_new!(ib, vec_any_info.wasm_type_idx)   # mod-resolved fields
        # struct.new Expr with (typeId, head, vector)
        struct_new!(ib, expr_info.wasm_type_idx)   # mod-resolved fields
        append_builder!(fb, ib)
    end

    return append_builder!(b, fb)
end

# `Symbol(x)` — in WasmGC, Symbol IS String (both are byte arrays); the
# argument is already a string array and compiles straight through.
# Self-contained: emits its own operand directly onto `fb`.
function _lower_symbol!(b, fb, ctx, expr, idx, args, callee)
    length(args) == 1 || return nothing
    append_builder!(fb, _compile_value_b(args[1], ctx))
    return append_builder!(b, fb)
end

# `ifelse(cond, a, b)` — dart lowers a ConditionalExpression through its own
# operand wraps (intrinsics.dart:607 the same nullable-return funnel); WT emits
# `select`/`select_t`. Self-contained: compiles all three operands itself, so it
# never depended on the generic arg-push loop. `Base.ifelse` (the generic
# function) and `Core.ifelse` (the builtin) are DIFFERENT objects — the retired
# `is_func(func, :ifelse)` matched either by bare name, so both are keys here.
# L38_no_known_value_substitutions pins this body's two reject messages.
function _lower_ifelse!(b, fb, ctx, expr, idx, args, callee)::Union{InstrBuilder,Nothing}
    length(args) == 3 || return nothing
    # Wasm select expects: [val_if_true, val_if_false, cond] (cond on top)
    # Julia ifelse(cond, true_val, false_val)
    # Compile each value separately to check for empty results. Loop C: capture the
    # pushed type (emission byproduct) for the true/false EMIT pushes (was a re-guess).
    # The cond keeps infer_value_wasm_type — that's a pure pre-emit type QUERY (drives the
    # cond_is_ref SELECT-vs-fallback decision below), legitimate dart-style type knowledge,
    # NOT the redundant re-guess-at-emit the typed channel deletes.
    local _tv_b = _compile_value_b(args[2], ctx)   # true_val
    local _fv_b = _compile_value_b(args[3], ctx)   # false_val
    local _cv_b = _compile_value_b(args[1], ctx)   # cond

    # the condition must push an i32, not a ref.
    # The old detection BYTE-SCANNED cond_bytes for 0xfb 0x00/0x01 (GC_PREFIX +
    # STRUCT_NEW) — but LEB128 operands collide with that pattern: `local.get 251`
    # encodes as [0x20, 0xfb, 0x01], so any condition living in local 251 (or any
    # constant containing those bytes) was misclassified as a ref and the SELECT
    # was silently dropped, leaving only the true-branch value. In a gcd loop
    # phi-update this froze the loop-carried value → infinite loop (gap
    # 6830e0e173d4/c8566ce342f8 family). Classify by the VALUE'S TYPE instead.
    cond_wasm_type = static_wasm_type(args[1], ctx)
    cond_is_ref = cond_wasm_type isa ConcreteRef || cond_wasm_type === StructRef ||
                  cond_wasm_type === ArrayRef || cond_wasm_type === ExternRef ||
                  cond_wasm_type === AnyRef || cond_wasm_type === EqRef

    # A non-i32 condition is invalid Julia lowering for `ifelse`; never choose
    # one arm and fabricate a result.
    if cond_is_ref
        record_unsupported!(ctx, :value_stub,
            "ifelse condition did not lower to i32"; idx=idx, detail=expr,
            soundness_fatal=true)
    end

    local _ieb = _ctx_builder(ctx, "compile_call")
    # Empty value emission is a compiler error, never permission to select an
    # arbitrary arm or synthesize a zero/null value.
    if isempty(_tv_b.instrs) || isempty(_fv_b.instrs) || isempty(_cv_b.instrs)
        record_unsupported!(ctx, :value_stub,
            "ifelse operand emitted no runtime value"; idx=idx, detail=expr,
            soundness_fatal=true)
    end

    # All three values are non-empty, emit proper select — typed merges
    append_builder!(_ieb, _tv_b)
    append_builder!(_ieb, _fv_b)
    append_builder!(_ieb, _cv_b)

    # Determine the type of the values for select
    val_type = infer_value_type(args[2], ctx)

    # For reference types (like Int128/UInt128 structs), need typed select.
    # The result-type operand after `0x63` (ref null heaptype) is a
    # SIGNED LEB128 — heaptype is either a negative abstract-type code
    # (anyref = -18, etc.) or a non-negative type index, and WASM uses
    # signed encoding for both so a parser can tell them apart. Using
    # `encode_leb128_unsigned` for a type index whose low 7 bits have
    # bit 6 set (e.g. 84) emits a single byte `0x54` that the browser
    # then interprets as the signed value -44: "Unknown heap type -44".
    if val_type === Int128 || val_type === UInt128
        # Use select_t with the struct type
        type_idx = get_int128_type!(ctx.mod, ctx.type_registry, val_type)
        # Encode (ref null type_idx) for nullable struct ref
        select_t!(_ieb, UInt8[0x63, encode_leb128_signed(Int64(type_idx))...])
    elseif is_struct_type(val_type) || val_type <: AbstractArray || val_type === String
        # Other reference types need typed select too
        wasm_type = get_concrete_wasm_type(val_type, ctx.mod, ctx.type_registry; for_local=true)
        if wasm_type isa ConcreteRef
            select_t!(_ieb, UInt8[0x63, encode_leb128_signed(Int64(wasm_type.type_idx))...])
        else
            # Fall back to untyped select for value types
            select!(_ieb)
        end
    else
        # Value types (i32, i64, f32, f64) use untyped select
        select!(_ieb)
    end
    append_builder!(fb, _ieb)
    return append_builder!(b, fb)
end

# Core.typeassert(x, T) — dart's CHECKED cast (census F4; emitAsCheck,
# types.dart:437-481: is-check, throw on mismatch). Statically-proven casts stay
# pass-through (the common case — inference already narrowed). A runtime check
# emits when the value is a GC ref and the target has a DFS classId range:
# typeId ∈ [low, high] or throw TypeError. Values the discriminator can't see
# (non-$JlBase refs) pass through UNCHECKED (under-check, never wrong-throw).
# Self-contained: emits its own operand through `emit_value!`.
# L57_exact_typeassert_exception pins this body's `_emit_typeerror_throw!` call.
function _lower_typeassert!(b, fb, ctx, expr, idx, args, callee)::Union{InstrBuilder,Nothing}
    if length(args) >= 1
        local _ta_target = length(args) >= 2 ? (args[2] isa Type ? args[2] :
            args[2] isa GlobalRef ? Core.eval(args[2].mod, args[2].name) : nothing) : nothing
        local _ta_static = get_ssa_type(ctx, args[1])
        if _ta_target isa Type && isconcretetype(_ta_target) &&
           _ta_static isa Type && isconcretetype(_ta_static)
            if _ta_static <: _ta_target
                emit_value!(fb, args[1], ctx,
                            get_concrete_wasm_type(_ta_target, ctx.mod, ctx.type_registry))
            else
                _emit_typeerror_throw!(fb, args[1], _ta_target, idx, ctx)
            end
            return append_builder!(b, fb)
        end
        local _ta_ty = emit_value!(fb, args[1], ctx)  # R17-floor: dynamic typeassert selects its class-range check from the actual reference representation
        if _ta_target isa Type && isconcretetype(_ta_target) &&
           (_ta_ty === AnyRef || _ta_ty isa ConcreteRef || _ta_ty === StructRef) &&
           ctx.type_registry.base_struct_idx !== nothing
            local _ta_range = get_type_range(ctx.type_registry, _ta_target)
            if _ta_range !== nothing
                local _ta_low, _ta_high = _ta_range
                local _ta_base = ctx.type_registry.base_struct_idx
                local _ta_tmp = allocate_local!(ctx, AnyRef)
                local_tee!(fb, _ta_tmp)
                ref_test!(fb, Int64(_ta_base), false)
                if_!(fb)                                   # discriminable ($JlBase struct)
                local_get!(fb, UInt32(_ta_tmp))
                emit_typeof!(fb, _ta_base)
                emit_classid_range_check!(fb, _ta_low, _ta_high)
                num!(fb, Opcode.I32_EQZ)
                if_!(fb)                                   # out of range → THROW
                ensure_exception_tag!(ctx.mod)
                local _te_info = register_struct_type!(ctx.mod, ctx.type_registry, TypeError)
                local _te_def = ctx.mod.types[Int(_te_info.wasm_type_idx) + 1]
                _te_def isa StructType || error("TypeError did not register as a Wasm struct")
                emit_struct_prefix!(fb, ctx.type_registry, TypeError, _te_info)
                local _te_values = Any[:typeassert, "", _ta_target]
                for _te_i in 1:3
                    local _te_w = _te_def.fields[wasm_field_idx(_te_info, _te_i) + 1].valtype
                    emit_value!(fb, _te_values[_te_i], ctx, _te_w;
                                from_julia=fieldtype(TypeError, _te_i))
                end
                local_get!(fb, UInt32(_ta_tmp))
                local _te_got_w = _te_def.fields[wasm_field_idx(_te_info, 4) + 1].valtype
                coerce_stack_top!(fb, _te_got_w, ctx;
                                  from_julia=(_ta_static isa Type ? _ta_static : nothing))
                struct_new!(fb, _te_info.wasm_type_idx)
                global_set!(fb, ensure_exception_global!(ctx.mod))
                global_get!(fb, ensure_exception_global!(ctx.mod), AnyRef); ref_null!(fb, ExternRef); throw_!(fb, 0; inputs=WasmValType[AnyRef, ExternRef])   # typed (exn, trace) tag
                end_block!(fb)
                end_block!(fb)
                local_get!(fb, UInt32(_ta_tmp))            # the value survives the check
            end
        end
    end
    return append_builder!(b, fb)
end

# ---- getfield / getproperty / setfield! / setproperty! ----------------------
# parity(intrinsics.dart:685 MemberIntrinsic.generate): dart resolves an
# instance-member access to ONE intrinsic keyed on the resolved member and
# runs THAT intrinsic's own shape guards in order. WT's four field-access
# builtins have several such guards each, and the retired `is_func(func, :sym)`
# ladder interleaved them with RAW identity checks on the same callee
# (`func.mod === Core && func.name === :getfield`: the closure self-capture
# skip and the `:signal` skip) that only `Core.getfield`/`Base.getfield` — one
# object, measured — ever satisfied, never `Base.getproperty`. Those raw checks
# are guards of the SAME builtin, so they are folded in here, in their original
# relative order, and appear only in the `getfield` entry.
#
# The two ladder arms that sat BETWEEN these guards (the `func isa
# Core.SSAValue` signal getter/setter and the `is_runtime_ir_value(func)`
# dynamic closure call, calls.jl) are unreachable for any of these callees:
# both require `func` to still be an SSAValue/Argument/SlotNumber/PiNode, and
# an unresolved SSAValue is not a registry key. So consulting the funnel once,
# up front, preserves each guard's relative order exactly.

function _lower_getfield_layout!(b, fb, ctx, expr, idx, args)::Union{InstrBuilder,Nothing}
    # P3 gap 450889a9cb7e: getfield(::DataType-literal, :layout) — the layout
    # pointer is compile-time host metadata; its loads are folded in
    # _try_fold_layout_pointerref. Represent the opaque, non-null layout handle
    # by the registered type id + 1 (zero remains C_NULL), never by a fabricated
    # universal pointer value.
    if length(args) >= 2
        local _gf_dt = args[1] isa QuoteNode ? args[1].value : args[1]
        local _gf_fld = args[2] isa QuoteNode ? args[2].value : args[2]
        if _gf_dt isa DataType && _gf_fld === :layout
            i64_const!(fb, Int64(ensure_type_id!(ctx.type_registry, _gf_dt)) + 1)
            return append_builder!(b, fb)
        end
    end
    return nothing
end


function _lower_getfield_signal_read!(b, fb, ctx, expr, idx, args)::Union{InstrBuilder,Nothing}
    # Special case for signal read: getfield(Signal, :value) -> global.get
    # This is detected by analyze_signal_captures! and stored in signal_ssa_getters
    # ONLY applies to actual getfield/getproperty(Signal, :value) calls (WasmGlobal pattern)
    # For Therapy.jl closures, signal_ssa_getters maps closure field SSAs - handled in compile_invoke
    is_getfield_value = length(args) >= 2
    if is_getfield_value && haskey(ctx.signal_ssa_getters, idx)
        # Check that this is accessing :value field (WasmGlobal pattern)
        field_ref = args[2]
        field_name = field_ref isa QuoteNode ? field_ref.value : field_ref
        if field_name === :value
            global_idx = ctx.signal_ssa_getters[idx]
            global_get!(fb, global_idx, ctx.mod.globals[global_idx + 1].valtype)
            return append_builder!(b, fb)
        end
    end
    return nothing
end


function _lower_setfield_signal_write!(b, fb, ctx, expr, idx, args)::Union{InstrBuilder,Nothing}
    # Special case for signal write: setfield!(Signal, :value, x) -> global.set
    # This is detected by analyze_signal_captures! and stored in signal_ssa_setters
    # ONLY applies to actual setfield!/setproperty! calls (WasmGlobal pattern), NOT closure field access
    is_setfield_call = length(args) >= 3
    if is_setfield_call && haskey(ctx.signal_ssa_setters, idx)
        # The value to write is the 3rd argument (args = [target, field, value])
        global_idx = ctx.signal_ssa_setters[idx]
        value_arg = args[3]
        local _setb = _ctx_builder(ctx, "compile_call")
        # The signal cell's declared type IS the expected
        emit_value!(_setb, value_arg, ctx, ctx.mod.globals[Int(global_idx) + 1].valtype)
        global_set!(_setb, global_idx)

        # Inject DOM update calls for this signal (Therapy.jl reactive updates)
        if haskey(ctx.dom_bindings, global_idx)
            # Get global's type for conversion
            global_type = ctx.mod.globals[global_idx + 1].valtype

            for (import_idx, const_args) in ctx.dom_bindings[global_idx]
                # Push constant arguments (e.g., hydration key)
                for arg in const_args
                    i32_const!(_setb, Int(arg))
                end
                # Push the signal value (re-read from global)
                global_get!(_setb, global_idx, global_type)
                # Convert to f64 for DOM imports (all DOM imports expect f64)
                emit_convert_to_f64!(_setb, global_type)
                # Call the DOM import function
                call!(_setb, import_idx, WasmValType[], WasmValType[])
            end
        end

        # setfield! returns the value written, so re-read it
        global_get!(_setb, global_idx, ctx.mod.globals[global_idx + 1].valtype)
        append_builder!(fb, _setb)
        return append_builder!(b, fb)
    end
    return nothing
end


function _lower_getfield_closure_capture!(b, fb, ctx, expr, idx, args)::Union{InstrBuilder,Nothing}
    # Special case for getfield on closure (_1) accessing captured signal fields
    # These produce intermediate SSA values (getter/setter functions)
    # Skip them - the actual read/write happens when the function is invoked
    if length(args) >= 2
        target = args[1]
        field_ref = args[2]
        # Target can be Core.SlotNumber(1) or Core.Argument(1)
        is_closure_self = (target isa Core.SlotNumber && target.id == 1) ||
                          (target isa Core.Argument && target.n == 1)
        if is_closure_self
            # This is accessing a field of the closure
            field_name = field_ref isa QuoteNode ? field_ref.value : field_ref
            if field_name isa Symbol && haskey(ctx.captured_constant_fields, field_name)
                local _captured_value = ctx.captured_constant_fields[field_name]
                # The canonical pre-emission type query owns Julia→Wasm mapping;
                # root substitutions do not introduce another conversion site.
                local _captured_wasm = static_wasm_type(_captured_value, ctx)
                emit_value!(fb, _captured_value, ctx, _captured_wasm;
                            from_julia=typeof(_captured_value))
                return append_builder!(b, fb)
            end
            if field_name isa Symbol && haskey(ctx.captured_signal_fields, field_name)
                # Skip - this produces a getter/setter function reference
                return append_builder!(b, fb)
            end
        end
    end
    return nothing
end


function _lower_getfield_signal_skip!(b, fb, ctx, expr, idx, args)::Union{InstrBuilder,Nothing}
    # Skip getfield(CompilableSignal/Setter, :signal) - intermediate step
    # We track this in analyze_signal_captures! but don't need to emit anything
    # IMPORTANT: Only skip for actual CompilableSignal/Setter types, not any struct with a :signal field
    if length(args) >= 2
        field_ref = args[2]
        field_name = field_ref isa QuoteNode ? field_ref.value : field_ref
        if field_name === :signal
            # Only skip for CompilableSignal/Setter types (WasmGlobal pattern)
            target_type = infer_value_type(args[1], ctx)
            if target_type isa DataType && target_type.name.name in (:CompilableSignal, :CompilableSetter)
                # Skip - this is getting Signal from CompilableSignal/Setter
                return append_builder!(b, fb)
            end
        end
    end
    return nothing
end


function _lower_getfield_general!(b, fb, ctx, expr, idx, args)::Union{InstrBuilder,Nothing}
    # Special case for getfield/getproperty - struct/tuple field access
    # In newer Julia, obj.field compiles to Base.getproperty(obj, :field)
    # rather than Core.getfield(obj, :field)
    if length(args) >= 2
        obj_arg = args[1]
        field_ref = args[2]
        obj_type = infer_value_type(obj_arg, ctx)   # pre-existing query (the mega-arm relies on it)
        if is_runtime_vararg_tuple_type(obj_type) && !(field_ref isa QuoteNode)
            local info = register_vararg_tuple_type!(ctx.mod, ctx.type_registry, obj_type)
            local E = vararg_tuple_eltype(obj_type)
            local arr_idx = get_array_type!(ctx.mod, ctx.type_registry, E)
            local tb = _ctx_builder(ctx, "compile_call")
            emit_value!(tb, obj_arg, ctx, ConcreteRef(info.wasm_type_idx, true))
            struct_get!(tb, info.wasm_type_idx, wasm_field_idx(info, 1),
                        ConcreteRef(arr_idx, true))
            emit_value!(tb, field_ref, ctx, I64)
            i64_const!(tb, 1)
            num!(tb, Opcode.I64_SUB)
            narrow_length_to_i32!(tb)
            local ew = julia_to_wasm_type(E)
            array_get!(tb, arr_idx, ew; signed=packed_array_signedness(E))
            return append_builder!(b, tb)
        end
        # parity(closures.dart:1365 Context): getfield(%box::Core.Box, :contents) — read the SHARED cell
        # (dart Context variable read) through the box's REAL struct type.
        local _mb_fld = field_ref isa QuoteNode ? field_ref.value : field_ref
        if obj_type === Core.Box && _mb_fld === :contents
            local _mb_ib = _ctx_builder(ctx, "compile_call")
            local _mb_ty = emit_value!(_mb_ib, obj_arg, ctx)  # R17-floor: actual box family selects projection
            local _mb_idx = _mb_ty isa ConcreteRef ? _mb_ty.type_idx :
                            UInt32(get_box_type!(ctx.mod, ctx.type_registry, AnyRef))
            !(_mb_ty isa ConcreteRef) && ref_cast!(_mb_ib, Int64(_mb_idx), false)
            local _mb_ft = ctx.mod.types[_mb_idx + 1].fields[2].valtype
            struct_get!(_mb_ib, _mb_idx, UInt32(1), _mb_ft)
            # Emit at the SSA's REFINED type (the numeric join = dart's variable type):
            # unbox through the ONE funnel so declared and actual agree at the store.
            local _mb_jt = get(ctx.ssa_types, idx, Any)
            local _mb_want = _mb_jt in (Int64, Int32, UInt64, UInt32, Float64, Float32, Bool) ?
                             julia_to_wasm_type(_mb_jt) : nothing
            local _mb_out = _mb_ft
            if _mb_want !== nothing && _mb_want !== _mb_ft && _wt_is_ref(_mb_ft)
                coerce_stack_top!(_mb_ib, _mb_want, ctx)
                _mb_out = _mb_want
            end
            # Land in a typed scratch + end with local.get (unambiguous tail for the
            # store heuristics — same workaround as the het-tuple arm above).
            local _mb_res = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, _mb_out)
            builder_set_local_type!(_mb_ib, _mb_res, _mb_out)
            local_set!(_mb_ib, _mb_res)
            local_get!(_mb_ib, _mb_res)
            append_builder!(fb, _mb_ib)
            return append_builder!(b, fb)
        end

        # Handle Memory{T}.instance pattern (Julia 1.11+ Vector allocation)
        # This pattern appears as Core.getproperty(Memory{T}, :instance)
        # where Memory{T} is passed directly as a DataType
        # Memory{T}.instance is a singleton empty Memory (length 0)
        # We compile it to create an empty WasmGC array
        field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref

        # Handle getfield(DataType_constant, :flags) — compile-time constant folding.
        # Broadcasting IR uses DataType.flags to check type properties (e.g., isprimitivetype).
        # The DataType is a compile-time constant, so we can emit the flags value directly.
        if field_sym === :flags && obj_arg isa DataType && isdefined(obj_arg, :flags)
            flags_val = obj_arg.flags
            i32_const!(fb, Int64(flags_val))
            return append_builder!(b, fb)
        end

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
            i32_const!(fb, 0)  # length = 0
            array_new_default!(fb, arr_type_idx)
            return append_builder!(b, fb)
        end

        # Handle Task.rngState0..3 field access → Wasm global.get
        # Julia's rand() accesses task-local Xoshiro state via getfield(task, :rngStateN)
        if obj_type === Task && field_sym in (:rngState0, :rngState1, :rngState2, :rngState3)
            rng_global = get_rng_global_idx(field_sym)
            if rng_global !== nothing
                global_get!(fb, rng_global, ctx.mod.globals[rng_global + 1].valtype)
                return append_builder!(b, fb)
            end
        end

        # Handle WasmGlobal field access (:value -> global.get)
        if obj_type <: WasmGlobal
            field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
            if field_sym === :value
                # Extract global index from type parameter
                global_idx = get_wasm_global_idx(obj_arg, ctx)
                if global_idx !== nothing
                    global_get!(fb, global_idx, ctx.mod.globals[global_idx + 1].valtype)
                    return append_builder!(b, fb)
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
            # parity(class_info.dart:666 ClassInfoCollector.collect): dart's struct for a
            # class exists before any field read; WT registers lazily, so the read
            # itself registers through the one type chain (a constant Vector read only
            # through .size never reached any other registrar).
            if obj_type isa DataType && isconcretetype(obj_type) && obj_type <: Array
                register_reachable_type!(ctx.mod, ctx.type_registry, obj_type)
            end

            if field_sym === :ref
                # :ref returns the underlying array reference (field 1 of struct; field 0 = typeId)
                local _refb = _ctx_builder(ctx, "compile_call")
                if haskey(ctx.type_registry.structs, obj_type)
                    info = ctx.type_registry.structs[obj_type]
                    # Typed arrival when the struct is registered
                    emit_value!(_refb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
                    struct_get!(_refb, info.wasm_type_idx, wasm_field_idx(info, 1), AnyRef)
                else
                    # parity(class_info.dart:666 ClassInfoCollector.collect): an unregistered struct previously emitted an INCOMPLETE
                    # struct.get (prefix+opcode, no immediates — invalid wasm). Loud reject.
                    # dart's closed-world fixpoint registers every reachable class's struct
                    # BEFORE codegen begins, so this situation cannot arise there; WT's
                    # late/dynamic frontend lacks that guarantee, so it rejects instead.
                    record_unsupported!(ctx, :unsupported_type, "field access on an unregistered struct type"; idx=idx)
                    unreachable!(_refb)
                end
                append_builder!(fb, _refb)
                return append_builder!(b, fb)
            elseif field_sym === :size
                # :size returns a Tuple containing the dimensions (field 2 of struct; field 0 = typeId)
                # For Vector: Tuple{Int64}, for Matrix: Tuple{Int64, Int64}, etc.
                local _szfb = _ctx_builder(ctx, "compile_call")
                if haskey(ctx.type_registry.structs, obj_type)
                    info = ctx.type_registry.structs[obj_type]
                    # Typed arrival when the struct is registered
                    emit_value!(_szfb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
                    struct_get!(_szfb, info.wasm_type_idx, wasm_field_idx(info, 2), AnyRef)
                else
                    record_unsupported!(ctx, :unsupported_type, "size access on an unregistered struct type"; idx=idx)
                    unreachable!(_szfb)
                end
                append_builder!(fb, _szfb)
                return append_builder!(b, fb)
            end

            # P6-trim: CodeUnits{UInt8,String} is an identity wrapper over the
            # byte array — getfield(cu, :s) is the array itself. Must run BEFORE
            # the generic struct_get path (CodeUnits is no longer a struct).
            if obj_type isa DataType && obj_type.name.name === :CodeUnits &&
               length(obj_type.parameters) >= 1 && obj_type.parameters[1] === UInt8
                local _cu_field0 = field_ref isa QuoteNode ? field_ref.value : field_ref
                if _cu_field0 === :s
                    emit_value!(fb, obj_arg, ctx, static_wasm_type(obj_arg, ctx))
                    return append_builder!(b, fb)
                end
            end

            # AbstractArray subtypes that are pure structs (e.g., UnitRange)
            # have named fields like :start, :stop — handle via struct_get
            if isconcretetype(obj_type) && isstructtype(obj_type)
                if !haskey(ctx.type_registry.structs, obj_type)
                    register_struct_type!(ctx.mod, ctx.type_registry, obj_type)
                end
                if haskey(ctx.type_registry.structs, obj_type)
                    info = ctx.type_registry.structs[obj_type]
                    field_idx = findfirst(==(field_sym), info.field_names)
                    if field_idx !== nothing
                        local _sfb = _ctx_builder(ctx, "compile_call")
                        # The object arrives AS the registered struct
                        emit_value!(_sfb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
                        struct_get!(_sfb, info.wasm_type_idx, wasm_field_idx(info, field_idx), AnyRef)
                        append_builder!(fb, _sfb)
                        return append_builder!(b, fb)
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
                # A virtual MemoryRef may emit `(memory, offset)`; getfield(:mem)
                # projects the memory operand and discards only the offset.
                local _mrb = _compile_value_b(obj_arg, ctx)
                append_builder!(fb, _mrb)
                length(_mrb.v.stack) == 2 && drop!(fb)
                return append_builder!(b, fb)
            elseif field_sym === :ptr_or_offset
                # P4-stdlib (SHA update!): the target pointer value is a
                # storage-relative byte offset. Base refs → 0; refs from memoryrefnew(ref, i, bc)
                # carry (i-1)*elsize (ctx.memoryref_offsets records i), so
                # pointer arithmetic over indexed refs stays faithful.
                local _poo_idx = obj_arg isa Core.SSAValue ?
                    get(ctx.memoryref_offsets, obj_arg.id, nothing) : nothing
                local _poo_el = obj_type isa DataType && length(obj_type.parameters) >= 1 ?
                    (obj_type.name.name === :GenericMemoryRef && length(obj_type.parameters) >= 2 ?
                     obj_type.parameters[2] : obj_type.parameters[1]) : nothing
                local _poob = _ctx_builder(ctx, "compile_call")
                if _poo_idx !== nothing && _poo_el isa Type
                    # Julia's element stride: sizeof for an isbits element, 8 (a boxed
                    # slot, Base.aligned_sizeof(Any)) for a reference element — the same
                    # rule jl_genericmemory_copyto's lowering divides by
                    local _poo_sz = memory_element_stride(_poo_el)
                    local _poo_it = infer_value_type(_poo_idx, ctx)
                    emit_value!(_poob, _poo_idx, ctx,
                                (_poo_it === Int64 || _poo_it === Int || _poo_it === UInt64) ? I64 : I32)
                    (_poo_it === Int64 || _poo_it === Int || _poo_it === UInt64) ||
                        num!(_poob, Opcode.I64_EXTEND_I32_S)
                    i64_const!(_poob, Int64(1))
                    num!(_poob, Opcode.I64_SUB)
                    if _poo_sz != 1
                        i64_const!(_poob, Int64(_poo_sz))
                        num!(_poob, Opcode.I64_MUL)
                    end
                else
                    i64_const!(_poob, 0)
                end
                append_builder!(fb, _poob)
                return append_builder!(b, fb)
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
                local _mem_arr = get_array_type!(ctx.mod, ctx.type_registry, eltype(obj_type))
                emit_value!(fb, obj_arg, ctx, ConcreteRef(UInt32(_mem_arr), true))
                array_len!(fb)
                num!(fb, Opcode.I64_EXTEND_I32_S)
                return append_builder!(b, fb)
            elseif field_sym === :ptr
                # Not meaningful in WasmGC - return 0
                i64_const!(fb, 0)
                return append_builder!(b, fb)
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

                # Positional getfield(x, i::Integer) — see struct branch
                field_idx = field_sym isa Integer ?
                    (1 <= field_sym <= length(info.field_names) ? Int(field_sym) : nothing) :
                    findfirst(==(field_sym), info.field_names)
                if field_idx !== nothing
                    emit_value!(fb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))   # typed arrival
                    struct_get!(fb, info.wasm_type_idx, wasm_field_idx(info, field_idx), AnyRef)
                    return append_builder!(b, fb)
                end
            end
        end

        # Handle Type{T} constants for DataType field access.
        # When a DataType constant (e.g., Vector{Int64}) appears in IR, infer_value_type
        # returns Type{Vector{Int64}}. Unwrap to DataType for struct field access, since
        # DataType is registered in the JlType hierarchy with fields like :name, :parameters.
        effective_obj_type = obj_type
        if obj_type isa DataType && obj_type <: Type && obj_type !== DataType
            # Type{X} where X is a DataType — unwrap to DataType
            if haskey(ctx.type_registry.structs, DataType)
                effective_obj_type = DataType
            end
        end

        # Handle struct field access by name
        if is_struct_type(effective_obj_type) || haskey(ctx.type_registry.structs, effective_obj_type)
            # Register the struct type on-demand if not already registered
            if !haskey(ctx.type_registry.structs, effective_obj_type)
                register_struct_type!(ctx.mod, ctx.type_registry, effective_obj_type)
            end
            info = ctx.type_registry.structs[effective_obj_type]

            field_sym = if field_ref isa QuoteNode
                field_ref.value
            else
                field_ref
            end

            # getfield(x, i::Integer) — positional access (gap
            # 8f5c0002bb71). Julia field order == info.field_names order.
            field_idx = field_sym isa Integer ?
                (1 <= field_sym <= length(info.field_names) ? Int(field_sym) : nothing) :
                findfirst(==(field_sym), info.field_names)
            if field_idx !== nothing
                local _sfgb = _ctx_builder(ctx, "compile_call")
                set_context!(_sfgb, first(string(expr), 120))
                # The typed wrap subsumes the structref-narrow helper
                emit_value!(_sfgb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
                local _sfg_wfi = wasm_field_idx(info, field_idx)
                local _sfg_layout = ctx.mod.types[Int(info.wasm_type_idx) + 1]
                _sfg_layout isa StructType || error("registered getfield owner has no struct layout")
                local _sfg_fields = _sfg_layout.fields
                local _sfg_ft = _sfg_fields[Int(_sfg_wfi) + 1].valtype
                struct_get!(_sfgb, info.wasm_type_idx, _sfg_wfi, _sfg_ft)
                append_builder!(fb, _sfgb)
                return append_builder!(b, fb)
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
                elseif field_ref isa Core.SSAValue || field_ref isa Core.Argument
                    # Dynamic index - will be handled below for homogeneous tuples.
                    # `Core.Argument`: the index is a bare function parameter, e.g.
                    # `f(x) = (31,28,…)[x]` → `getfield(tuple, _2, boundscheck)` (gap
                    # d4409a896f5b — daysinmonth's DAYSINMONTH[m] lookup table). Without
                    # this the arg-indexed case fell to `nothing` → unreachable stub.
                    :dynamic
                else
                    nothing
                end

                if field_idx === :dynamic
                    # Dynamic tuple indexing - only supported for homogeneous tuples (NTuple)
                    # Check if all elements have the same type
                    # Guard against types without definite field count (e.g., Vararg tuples)
                    elem_types = obj_type isa DataType && isconcretetype(obj_type) ?
                        fieldtypes(obj_type) : ()
                    if length(elem_types) > 0 && all(t -> t === elem_types[1], elem_types)
                        # Homogeneous tuple - we can treat it as an array
                        elem_type = elem_types[1]

                        # For constant tuple (GlobalRef), create a WasmGC array and access it
                        # The tuple value needs to be compiled as an array first

                        # Get or create array type for this element type.
                        # The array element type MUST equal the tuple's actual field
                        # wasm type (what the struct.get below yields), else
                        # array.new_fixed mismatches. For String, get_string_ref_array_type!'s
                        # arrays[Vector{String}] cache can be polluted (array-of-Vector{String}-
                        # struct) by other registrations → build an array of the REAL field
                        # valtype instead. (Surfaced by Markdown plain over String tuples and
                        # STRESS string-transform funcs once dynamic-dispatch discovery compiles
                        # those specializations.)
                        array_type_idx = if elem_type === String
                            local _tst = ctx.mod.types[Int(info.wasm_type_idx) + 1]
                            local _fvt = _tst.fields[Int(info.field_offset) + 1].valtype
                            add_array_type!(ctx.mod, _fvt, true)
                        else
                            get_array_type!(ctx.mod, ctx.type_registry, elem_type)
                        end

                        # Compile the tuple as an array
                        # First compile the tuple value
                        local _htb = _ctx_builder(ctx, "compile_call")
                        emit_value!(_htb, obj_arg, ctx,
                                    ConcreteRef(UInt32(info.wasm_type_idx), true))

                        # The struct is on the stack, we need to convert struct fields to array
                        # Store in local, then create array from fields
                        tuple_local = length(ctx.locals) + ctx.n_params
                        push!(ctx.locals, get_concrete_wasm_type(obj_type, ctx.mod, ctx.type_registry; for_local=true))
                        local_set!(_htb, tuple_local)

                        # Push all fields onto stack (account for typeId at field 0)
                        for i in 0:(length(elem_types)-1)
                            local_get!(_htb, tuple_local)
                            struct_get!(_htb, info.wasm_type_idx, i + Int(info.field_offset), AnyRef)  # skip typeId
                        end

                        # Create array from fields
                        array_new_fixed!(_htb, array_type_idx, length(elem_types), AnyRef)

                        # Store array in local - use concrete ref to specific array type
                        array_local = length(ctx.locals) + ctx.n_params
                        push!(ctx.locals, ConcreteRef(array_type_idx, true))
                        local_set!(_htb, array_local)

                        # Now compile the index and access the array
                        # Julia uses 1-based indexing, Wasm uses 0-based
                        emit_value!(_htb, field_ref, ctx, I64)

                        # Subtract 1 for 0-based indexing
                        i64_const!(_htb, 1)
                        num!(_htb, Opcode.I64_SUB)
                        # Wrap to i32 for array index
                        num!(_htb, Opcode.I32_WRAP_I64)

                        # Store index in local
                        idx_local = length(ctx.locals) + ctx.n_params
                        push!(ctx.locals, I32)
                        local_set!(_htb, idx_local)

                        # Access array: array.get (use ARRAY_GET_U for packed i8 arrays)
                        local_get!(_htb, array_local)
                        local_get!(_htb, idx_local)
                        array_get!(_htb, array_type_idx, AnyRef; signed=packed_array_signedness(elem_type))

                        # If array element type is ExternRef (e.g., elem_type=Any),
                        # array_get returns externref. Downstream code may ref_cast to a struct
                        # type, which requires anyref input. Add any_convert_extern.
                        wasm_elem_type = get_concrete_wasm_type(elem_type, ctx.mod, ctx.type_registry)
                        if wasm_elem_type === ExternRef
                            any_convert_extern!(_htb)
                        end

                        append_builder!(fb, _htb)
                        return append_builder!(b, fb)
                    end
                    # Heterogeneous tuple + dynamic index → produce a tagged-union
                    # value `Union{fieldtypes...}` via a runtime switch on the index.
                    # `getfield(::Tuple{A,B,...}, i::Int)` infers to exactly this union,
                    # and the consumers (`isa`, π-narrowing, memoryrefset!) already
                    # speak the tagged-union ABI — so wrapping each field into the union
                    # makes them work unchanged. Surfaced by `Any[a,"x",a]` /
                    # `md"...$x...$y..."` interpolation (Pluto featured corpus): these
                    # lower to `Base.getindex(T, vals...)` which loops `vals[i]` over a
                    # heterogeneous tuple — previously emitted `unreachable`.
                    if length(elem_types) >= 2
                        U = Union{elem_types...}
                        if U isa Union
                            # Produce the value in the CANONICAL representation of the
                            # getfield's INFERRED SSA result type — that is exactly what
                            # the SSA local was allocated as (get_concrete_wasm_type),
                            # so the if-block result matches the local and there's no store
                            # mismatch. (Anchoring on Union{fieldtypes…} instead diverges
                            # from inference — e.g. Dates date-format parsing, where the
                            # inferred result is a tagged union but fieldtypes look
                            # all-struct.) For a tagged-union rep, tag-wrap each field; for
                            # StructRef (all-struct union, e.g. Union{Dog,Cat}) push the raw
                            # struct ref (subtype of structref) — tag-wrapping it would make
                            # the consumer's isa/π cast trap "illegal cast".
                            _ssa_t = get(ctx.ssa_types, idx, nothing)
                            local Ueff
                            if _ssa_t isa Type && _ssa_t !== Union{}
                                union_wasm = get_concrete_wasm_type(_ssa_t, ctx.mod, ctx.type_registry; for_local=true)
                                Ueff = _ssa_t isa Union ? _ssa_t : U
                            else
                                union_wasm = get_concrete_wasm_type(U, ctx.mod, ctx.type_registry)
                                Ueff = U
                            end
                            # B4/U2: the tagged-union wrapper is retired — a het-tuple field's
                            # union value is an AnyRef classId box (the `else` branch below), never
                            # the {typeId,tag,value} wrapper.

                            local _hetb = _ctx_builder(ctx, "compile_call")
                            # tuple value → tuple_local
                            emit_value!(_hetb, obj_arg, ctx,
                                        ConcreteRef(UInt32(info.wasm_type_idx), true))
                            tuple_local = length(ctx.locals) + ctx.n_params
                            push!(ctx.locals, get_concrete_wasm_type(obj_type, ctx.mod, ctx.type_registry; for_local=true))
                            local_set!(_hetb, tuple_local)

                            # index (1-based i64) → 0-based i32 → idx_local
                            emit_value!(_hetb, field_ref, ctx, I64)
                            i64_const!(_hetb, 1)
                            num!(_hetb, Opcode.I64_SUB)
                            num!(_hetb, Opcode.I32_WRAP_I64)
                            idx_local = length(ctx.locals) + ctx.n_params
                            push!(ctx.locals, I32)
                            local_set!(_hetb, idx_local)

                            n_fields = length(elem_types)
                            emit_field_wrap = i -> begin
                                local_get!(_hetb, tuple_local)
                                struct_get!(_hetb, info.wasm_type_idx, i + Int(info.field_offset), AnyRef)
                                # M3: dead tagged-union wrapper arm DELETED (needs_tagged_union ≡ false).
                                # Coerce the raw field value to U's canonical wasm rep.
                                fw = get_concrete_wasm_type(elem_types[i + 1], ctx.mod, ctx.type_registry; for_local=true)
                                if union_wasm === AnyRef
                                    if fw === I64 || fw === I32 || fw === F32 || fw === F64
                                        # THE single-source box producer with the field's REAL classId
                                        # (same-wasm-rep members Bool/Int8/Int32 stay isa-distinguishable).
                                        emit_classid_box!(_hetb, ctx, fw, elem_types[i + 1])
                                    elseif fw === ExternRef
                                        any_convert_extern!(_hetb)
                                    end
                                    # ConcreteRef/StructRef field is already anyref-compatible
                                end
                                # union_wasm === StructRef / numeric: push as-is.
                            end
                            # nested if-chain: idx==0 ? wrap(f0) : idx==1 ? wrap(f1) : … : wrap(fN-1)
                            for i in 0:(n_fields - 2)
                                local_get!(_hetb, idx_local)
                                i32_const!(_hetb, Int64(i))
                                num!(_hetb, Opcode.I32_EQ)
                                if_!(_hetb, union_wasm; results=WasmValType[union_wasm])
                                emit_field_wrap(i)
                                else_!(_hetb)
                            end
                            emit_field_wrap(n_fields - 1)  # last field = else-default
                            for _ in 1:(n_fields - 1)
                                end_block!(_hetb)
                            end
                            # Land the union result in a scratch local and end with a
                            # clean `local.get`. The if/else block ends in END, which the
                            # statement-assignment heuristics (which peek at the tail
                            # instruction to infer the produced type) mis-parse — they'd
                            # drop the value and substitute ref.null. A trailing local.get
                            # of the correctly-typed scratch is unambiguous.
                            result_local = length(ctx.locals) + ctx.n_params
                            push!(ctx.locals, union_wasm)
                            local_set!(_hetb, result_local)
                            local_get!(_hetb, result_local)
                            append_builder!(fb, _hetb)
                            return append_builder!(b, fb)
                        end
                    end
                elseif field_idx !== nothing && field_idx >= 1 && field_idx <= length(info.field_names)
                    emit_value!(fb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))   # typed arrival
                    struct_get!(fb, info.wasm_type_idx, wasm_field_idx(info, field_idx), AnyRef)
                    return append_builder!(b, fb)
                end
            end
        end
    end
    return nothing
end


function _lower_setfield_general!(b, fb, ctx, expr, idx, args)::Union{InstrBuilder,Nothing}
    # Special case for setfield!/setproperty! - mutable struct field assignment
    # Also handles WasmGlobal (:value -> global.set)
    # In newer Julia, obj.field = val compiles to Base.setproperty!(obj, :field, val)
    if length(args) >= 3
        obj_arg = args[1]
        field_ref = args[2]
        value_arg = args[3]
        obj_type = infer_value_type(obj_arg, ctx)

        field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref

        # Handle Task.rngState0..3 field assignment → Wasm global.set
        if obj_type === Task && field_sym in (:rngState0, :rngState1, :rngState2, :rngState3)
            rng_global = get_rng_global_idx(field_sym)
            if rng_global !== nothing
                emit_value!(fb, value_arg, ctx, ctx.mod.globals[Int(rng_global) + 1].valtype)
                global_set!(fb, rng_global)
                return append_builder!(b, fb)
            end
        end

        # Handle WasmGlobal field assignment (:value -> global.set)
        if obj_type <: WasmGlobal
            if field_sym === :value
                # Extract global index from type parameter
                global_idx = get_wasm_global_idx(obj_arg, ctx)
                if global_idx !== nothing
                    local _wgsb = _ctx_builder(ctx, "compile_call")
                    local _wg_expected = ctx.mod.globals[Int(global_idx) + 1].valtype
                    # Push the value to set
                    emit_value!(_wgsb, value_arg, ctx, _wg_expected)
                    # Emit global.set
                    global_set!(_wgsb, global_idx)
                    # setfield! returns the value, so push it again
                    emit_value!(_wgsb, value_arg, ctx, _wg_expected)
                    append_builder!(fb, _wgsb)
                    return append_builder!(b, fb)
                end
            end
        end

        # Handle Vector/Array field assignment (:ref and :size are mutable)
        # Vector{T} is now a struct with (ref, size) where both fields are mutable
        if obj_type <: AbstractArray
            field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
            if field_sym === :ref && haskey(ctx.type_registry.structs, obj_type)
                # setfield!(vector, :ref, new_memref) — update data array
                # :ref is field index 1 in the Vector struct (field 0 = typeId)
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
                    local _vr_def = ctx.mod.types[info.wasm_type_idx + 1]
                    local _vr_expected = _vr_def.fields[wasm_field_idx(info, 1) + 1].valtype
                    temp_local = allocate_local!(ctx, _vr_expected)
                    local _vrb = _ctx_builder(ctx, "compile_call")
                    emit_value!(_vrb, value_arg, ctx, _vr_expected;
                                from_julia=(value_type isa Type && isconcretetype(value_type)) ? value_type : nothing)
                    local_set!(_vrb, temp_local)
                    emit_value!(_vrb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
                    # If obj_arg's local is structref, insert ref.cast null before struct_set
                                        emit_ref_cast_if_structref!(_vrb, obj_arg, info.wasm_type_idx, ctx)
                    local_get!(_vrb, temp_local)
                    struct_set!(_vrb, info.wasm_type_idx, wasm_field_idx(info, 1), AnyRef)
                    local_get!(_vrb, temp_local)
                    append_builder!(fb, _vrb)
                    return append_builder!(b, fb)
                end
                # Fall through to generic handling for multi-arg memoryrefnew values
            elseif field_sym === :size && haskey(ctx.type_registry.structs, obj_type)
                info = ctx.type_registry.structs[obj_type]
                # :size is field index 2 (0=typeId, 1=ref, 2=size)
                # struct.set expects: [ref, value]

                # IMPORTANT: The value_arg might be an SSA that was just computed and
                # is on top of the stack. If we compile obj_arg first, we'd push it
                # AFTER the value, giving wrong order [value, ref] instead of [ref, value].
                # Solution: compile value first, store in temp local, then compile ref.
                value_type = infer_value_type(value_arg, ctx)
                local _vs_def = ctx.mod.types[info.wasm_type_idx + 1]
                local _vs_expected = _vs_def.fields[wasm_field_idx(info, 2) + 1].valtype
                temp_local = allocate_local!(ctx, _vs_expected)
                local _vsb = _ctx_builder(ctx, "compile_call")

                # Compile value and store in local (value may already be on stack from prev stmt)
                emit_value!(_vsb, value_arg, ctx, _vs_expected;
                            from_julia=(value_type isa Type && isconcretetype(value_type)) ? value_type : nothing)
                local_set!(_vsb, temp_local)

                # Now compile obj (struct ref)
                emit_value!(_vsb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
                # If obj_arg's local is structref, insert ref.cast null before struct_set
                                emit_ref_cast_if_structref!(_vsb, obj_arg, info.wasm_type_idx, ctx)

                # Load value from local
                local_get!(_vsb, temp_local)

                # struct.set
                struct_set!(_vsb, info.wasm_type_idx, wasm_field_idx(info, 2), AnyRef)

                # setfield! returns the value, so push it again
                local_get!(_vsb, temp_local)
                append_builder!(fb, _vsb)
                return append_builder!(b, fb)
            end
        end

        # Handle mutable struct field assignment
        if is_struct_type(obj_type) && ismutabletype(obj_type)
            if haskey(ctx.type_registry.structs, obj_type)
                info = ctx.type_registry.structs[obj_type]
                field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref

                field_idx = findfirst(==(field_sym), info.field_names)
                if field_idx !== nothing
                    # Check if field is Any type (maps to externref in Wasm)
                    field_type = field_idx <= length(info.field_types) ? info.field_types[field_idx] : Any

                    # struct.set expects: [ref, value]
                    local _sfsb = _ctx_builder(ctx, "compile_call")
                    emit_value!(_sfsb, obj_arg, ctx,
                                ConcreteRef(UInt32(info.wasm_type_idx), true))
                    # If obj_arg's local is structref, insert ref.cast null before struct_set
                                        emit_ref_cast_if_structref!(_sfsb, obj_arg, info.wasm_type_idx, ctx)

                    # Use the registered physical field type as the sole sink
                    # contract. Type objects are real interned DataType globals;
                    # they are never replaced by null.
                    local _sf_wasm_fi = wasm_field_idx(info, field_idx)
                    local _sf_ct = ctx.mod.types[info.wasm_type_idx + 1]
                    local _sf_expected = (_sf_ct isa StructType &&
                        _sf_wasm_fi + 1 <= length(_sf_ct.fields)) ?
                        _sf_ct.fields[_sf_wasm_fi + 1].valtype : nothing
                    _sf_expected === nothing && error("setfield! target has no physical Wasm field type")
                    # Route the value through the ONE coercion funnel (emit_value!'s own
                    # val===nothing early exit, values.jl:905-912) instead of hand-rolling
                    # scalar-vs-ref / nothing-vs-not branches here. `is_nothing_value`
                    # recognizes GlobalRef aliases (e.g. `Mod.nothing`) and SSA/PiNode-proven
                    # null edges that a bare `val === nothing` check misses; substituting the
                    # literal lets emit_value! null a ref-typed field with its EXACT physical
                    # type (ConcreteRef → typed `ref.null $T`) instead of falling through to a
                    # numeric zero that then gets classId-boxed and ref.cast into the field's
                    # unrelated concrete struct type — invalid at runtime. (Previously this site
                    # used `ref_null_none!`, whose bottom-type null is tracked as AnyRef — sound
                    # only when the field's physical type IS exactly AnyRef; a narrower
                    # ConcreteRef field, e.g. MOI.Utilities.Model{Float64}()'s
                    # `single_variable::Union{Nothing,VariableIndex}`, then rejected it.)
                    local _sf_val = is_nothing_value(value_arg, ctx) ? nothing : value_arg
                    local _sf_from_julia = (field_type isa Type && isconcretetype(field_type)) ? field_type : nothing
                    emit_value!(_sfsb, _sf_val, ctx, _sf_expected; from_julia=_sf_from_julia)
                    struct_set!(_sfsb, info.wasm_type_idx, wasm_field_idx(info, field_idx), _sf_expected)
                    # setfield! returns the value — use compile_value to match SSA return type
                    emit_value!(_sfsb, _sf_val, ctx, _sf_expected; from_julia=_sf_from_julia)
                    append_builder!(fb, _sfsb)
                    return append_builder!(b, fb)
                end
            end
        end

        # Handle setfield! on Base.RefValue (used for optimization sinks)
        # These are no-ops in Wasm since we don't need the sink pattern
        if obj_type <: Base.RefValue
            # Just push the value (setfield! returns the value)
            emit_value!(fb, value_arg, ctx, static_wasm_type(value_arg, ctx))
            return append_builder!(b, fb)
        end
        # Fall through for other struct types - will hit error
    end
    return nothing
end


"""Run `guards` in order on one callee, dart's nullable-return funnel one level
down: the first guard that returns a builder owns the call; `nothing` from all
of them falls through to `compile_call!`'s remaining ladder."""
function _run_guards!(guards, b, fb, ctx, expr, idx, args)::Union{InstrBuilder,Nothing}
    for g in guards
        r = g(b, fb, ctx, expr, idx, args)
        r === nothing || return r
    end
    return nothing
end

# `Core.getfield` (=== `Base.getfield`, measured): the two raw-identity guards
# are its own, so they run here and nowhere else.
_lower_getfield!(b, fb, ctx, expr, idx, args, callee)::Union{InstrBuilder,Nothing} =
    _run_guards!((_lower_getfield_layout!, _lower_getfield_signal_read!,
                  _lower_getfield_closure_capture!, _lower_getfield_signal_skip!,
                  _lower_getfield_general!), b, fb, ctx, expr, idx, args)

# `Base.getproperty` / `Core.getproperty` (DIFFERENT objects, measured): the
# raw-identity guards never matched `getproperty`, so they are absent here.
_lower_getproperty!(b, fb, ctx, expr, idx, args, callee)::Union{InstrBuilder,Nothing} =
    _run_guards!((_lower_getfield_layout!, _lower_getfield_signal_read!,
                  _lower_getfield_general!), b, fb, ctx, expr, idx, args)

_lower_setfield!(b, fb, ctx, expr, idx, args, callee)::Union{InstrBuilder,Nothing} =
    _run_guards!((_lower_setfield_signal_write!, _lower_setfield_general!),
                 b, fb, ctx, expr, idx, args)

# ---- The self-contained operator entries -----------------------------------
# parity(intrinsics.dart:995 `_binaryOperatorMap` / :1018 the direct-call
# funnel): each of these emits its OWN operands through `emit_call_operand!`
# before choosing an opcode, exactly as a dart intrinsic wraps
# `node.arguments.positional[i]` itself. They were the last arms that read
# operands someone else had pushed (`compile_call!`'s generic pre-push loop),
# which is why they could not be identity-keyed until now.

"""
    _call_operand_shape(args, ctx) -> (arg_type, is_32bit, is_128bit)

THE operand-width classification for a call, read from the FIRST argument's
Julia type BEFORE any operand is emitted (dart's `node.getStaticType`, the
pre-emit query that picks which `_binaryOperatorMap` row applies). One
definition, shared by `compile_call!`'s own ladder and by the self-contained
operator entries here, so the two can never disagree about a call's width.
"""
function _call_operand_shape(args, ctx)::Tuple{Any,Bool,Bool}
    arg_type = length(args) > 0 ? infer_value_type(args[1], ctx) : Int64
    is_32bit = arg_type === Int32 || arg_type === UInt32 || arg_type === Bool || arg_type === Char ||
               arg_type === Int16 || arg_type === UInt16 || arg_type === Int8 || arg_type === UInt8 ||
               (isprimitivetype(arg_type) && sizeof(arg_type) <= 4)
    is_128bit = arg_type === Int128 || arg_type === UInt128
    return arg_type, is_32bit, is_128bit
end

# `===` / `!==`. Guard 1 is the string/typeof/nothing special-casing
# (`_lower_egal_early!`); guard 2 is the general width-keyed comparison, which
# needs both operands on the stack — INCLUDING Type-valued ones, since for
# these two callees a Type IS the runtime value being compared.
function _lower_egal!(b, fb, ctx, expr, idx, args, callee)::Union{InstrBuilder,Nothing}
    local early = _lower_egal_early!(b, fb, ctx, expr, idx, args, callee)
    early === nothing || return early
    local arg_type, is_32bit, is_128bit = _call_operand_shape(args, ctx)
    emit_call_operands!(fb, ctx, args; include_types=true)
    if callee === Core.:(!==)
        if is_128bit
            emit_int128_ne!(fb, ctx, arg_type)
        elseif arg_type === Float64
            num!(fb, Opcode.F64_NE)
        elseif arg_type === Float32
            num!(fb, Opcode.F32_NE)
        else
            local arg2_type_ne = length(args) >= 2 ? infer_value_type(args[2], ctx) : Int64
            local arg1_is_ref_ne = is_ref_type_or_union(arg_type) && arg_type !== Nothing
            local arg2_is_ref_ne = is_ref_type_or_union(arg2_type_ne) && arg2_type_ne !== Nothing

            # Quick check: if one arg is ref-typed and other is Nothing (compiles to i32),
            # they can't be equal, so !== is always true. Drop both and return true.
            if (arg1_is_ref_ne && arg2_type_ne === Nothing) || (arg2_is_ref_ne && arg_type === Nothing)
                drop!(fb); drop!(fb); i32_const!(fb, 1)
                return append_builder!(b, fb)
            end

            # Special case: both args are Nothing-typed. Need to check actual Wasm representation.
            if arg_type === Nothing && arg2_type_ne === Nothing
                # typed channel: the emissions' own types (was first-byte checks + LEB decodes).
                local _a1ne_ty = length(fb.v.stack) >= 2 ? fb.v.stack[end - 1] : nothing
                local _a2ne_ty = isempty(fb.v.stack) ? nothing : fb.v.stack[end]
                local a1_ref_ne = _a1ne_ty !== nothing && _wt_is_ref(_a1ne_ty)
                local a2_ref_ne = _a2ne_ty !== nothing && _wt_is_ref(_a2ne_ty)
                # If Wasm types mismatch (one ref, one not), drop both and return true (not equal)
                if a1_ref_ne != a2_ref_ne
                    drop!(fb); drop!(fb); i32_const!(fb, 1)
                    return append_builder!(b, fb)
                elseif a1_ref_ne && a2_ref_ne
                    # Both refs - use ref.eq then negate
                    num!(fb, Opcode.REF_EQ)
                    num!(fb, Opcode.I32_EQZ)
                    return append_builder!(b, fb)
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
                # For Nothing-typed args, determine ref-ness from the inferred value type
                # (dart2wasm carries the type with the value rather than scanning bytes).
                # `nothing` is treated as a ref here (it may be ref.null when compared
                # against a ref-typed Nothing local).
                if length(args) >= 1 && arg_type === Nothing
                    arg1_wasm_is_ref_ne = is_nothing_value(args[1], ctx) ||
                                          _wt_is_ref(static_wasm_type(args[1], ctx))
                end
                if length(args) >= 2 && arg2_type_ne === Nothing
                    arg2_wasm_is_ref_ne = is_nothing_value(args[2], ctx) ||
                                          _wt_is_ref(static_wasm_type(args[2], ctx))
                end
            end
            # BOTH args must be ref types to use ref.eq
            if arg1_wasm_is_ref_ne && arg2_wasm_is_ref_ne
                # Convert externref → eqref before ref.eq (same pattern as === handler)
                local _neb = _ctx_builder(ctx, "compile_call")
                if arg1_is_externref_ne && arg2_is_externref_ne
                    local tmp_ne = allocate_local!(ctx, EqRef)
                    any_convert_extern!(_neb)
                    ref_cast!(_neb, EqRef, true)
                    local_set!(_neb, tmp_ne)
                    any_convert_extern!(_neb)
                    ref_cast!(_neb, EqRef, true)
                    local_get!(_neb, tmp_ne)
                elseif arg1_is_externref_ne
                    local tmp_ne2 = allocate_local!(ctx, EqRef)
                    local_set!(_neb, tmp_ne2)
                    any_convert_extern!(_neb)
                    ref_cast!(_neb, EqRef, true)
                    local_get!(_neb, tmp_ne2)
                elseif arg2_is_externref_ne
                    any_convert_extern!(_neb)
                    ref_cast!(_neb, EqRef, true)
                end
                num!(_neb, Opcode.REF_EQ)
                num!(_neb, Opcode.I32_EQZ)  # Negate for !==
                append_builder!(fb, _neb)
            elseif arg1_wasm_is_ref_ne && !arg2_wasm_is_ref_ne
                # Comparing ref with non-ref: type mismatch, always not-equal
                drop!(fb); drop!(fb); i32_const!(fb, 1)
            elseif !arg1_wasm_is_ref_ne && arg2_wasm_is_ref_ne
                # Comparing non-ref with ref: type mismatch, always not-equal
                drop!(fb); drop!(fb); i32_const!(fb, 1)
            elseif !is_32bit && arg2_type_ne === Nothing
                # arg1 is 64-bit, arg2 is Nothing (i32). Extend i32 to i64 before comparing.
                num!(fb, Opcode.I64_EXTEND_I32_S)
                num!(fb, Opcode.I64_NE)
            elseif is_32bit && arg_type === Nothing && !is_ref_type_or_union(arg2_type_ne)
                # arg1 is Nothing (i32), arg2 is 64-bit - mismatched types, always not-equal
                drop!(fb); drop!(fb); i32_const!(fb, 1)
            else
                num!(fb, is_32bit ? Opcode.I32_NE : Opcode.I64_NE)
            end
        end
    else
        _compile_call_egaleq(args, fb, ctx, is_128bit, is_32bit, arg_type)
    end
    return append_builder!(b, fb)
end

# The high-level operator fallback: a `+`/`-`/`*` call that reached codegen
# unspecialised (a closure-compiled body presents `Base.:+` as a plain call,
# not an invoke). ONE (callee → per-width opcode) table replaces three copies
# of the same ladder; `*` additionally routes String/Symbol operands to
# concatenation. parity(intrinsics.dart:995 `_binaryOperatorMap`, which is
# likewise a table from (receiver type, operator) to one opcode.)
const _OPERATOR_OPCODES = IdDict{Any,NamedTuple{(:f32, :f64, :i32, :i64),NTuple{4,UInt8}}}(
    (+) => (f32=Opcode.F32_ADD, f64=Opcode.F64_ADD, i32=Opcode.I32_ADD, i64=Opcode.I64_ADD),
    (-) => (f32=Opcode.F32_SUB, f64=Opcode.F64_SUB, i32=Opcode.I32_SUB, i64=Opcode.I64_SUB),
    (*) => (f32=Opcode.F32_MUL, f64=Opcode.F64_MUL, i32=Opcode.I32_MUL, i64=Opcode.I64_MUL),
)

function _lower_operator!(b, fb, ctx, expr, idx, args, callee)::Union{InstrBuilder,Nothing}
    local ops = _OPERATOR_OPCODES[callee]
    local arg_type, is_32bit, is_128bit = _call_operand_shape(args, ctx)

    # The operands, plus the anyref unbox the retired pre-push loop applied to
    # the generic arithmetic operators: dynamic call sites with everything
    # typed Any (e.g. `4 - %foldl` in Random.hash_seed) default to the i64
    # opcodes but would consume raw anyref.
    local boxed_operand_unboxed = false
    for arg in args
        _is_type_operand(arg) && continue
        emit_call_operand!(fb, ctx, arg)
        if _is_boxed_numeric_operand(arg, ctx)
            emit_classid_unbox!(fb, ctx, is_32bit ? I32 : I64; nullable=true)
            boxed_operand_unboxed = true
        end
    end

    # String/Symbol `*` is CONCATENATION, not arithmetic: the plain-call path
    # (closure-compiled bodies present concat as `call *`, not invoke) fell
    # into the numeric branch and emitted i64.mul on two string refs — the
    # E-003 island's fn#107 validation failure. Route to the same
    # compile_string_concat the invoke path uses; the operands are on `fb`, so
    # rebuild the fragment (pattern).
    local _conc1 = length(args) >= 1 ? infer_value_type(args[1], ctx) : Nothing
    local _conc2 = length(args) >= 2 ? infer_value_type(args[2], ctx) : Nothing
    if callee === (*) && length(args) == 2 &&
       (_conc1 === String || _conc1 === Symbol) && (_conc2 === String || _conc2 === Symbol)
        fb = _ctx_builder(ctx, "compile_call.frag"); _seed_builder_locals!(fb, ctx)
        append_builder!(fb, compile_string_concat_many_b([args[1], args[2]], ctx))
    elseif arg_type === Float32
        num!(fb, ops.f32)
    elseif arg_type === Float64
        num!(fb, ops.f64)
    elseif is_32bit
        num!(fb, ops.i32)
    else
        num!(fb, ops.i64)
    end

    # parity(translator.dart:1621 Translator.convertType): the symmetric RESULT
    # side of the anyref-OPERAND unbox above — a numeric arith result flowing
    # into a ref-typed SSA local boxes through THE one producer (the
    # scalar-replaced Core.Box accumulator cycle: unbox → op → BOX → store).
    if boxed_operand_unboxed && !ctx.last_stmt_was_stub
        local _dl = get(ctx.ssa_locals, idx, nothing)
        if _dl !== nothing
            local _doff = _dl - ctx.n_params
            if _doff >= 0 && _doff < length(ctx.locals) && ctx.locals[_doff + 1] === AnyRef
                local _boxed_result_jt = get(ctx.ssa_types, idx, arg_type)
                (_boxed_result_jt isa Type && isconcretetype(_boxed_result_jt)) ||
                    record_unsupported!(ctx, :unsupported_type,
                        "boxed arithmetic result lacks a concrete Julia source type";
                        idx=idx, detail=expr)
                emit_classid_box!(fb, ctx, is_32bit ? I32 : I64, _boxed_result_jt)
            end
        end
    end
    return append_builder!(b, fb)
end

# `isa(value, T)` — type checking for Union discrimination. `T` is a
# compile-time Type parameter (skipped by the shared operand rule), so exactly
# one operand reaches `_compile_call_isa`, which is what its `_sub_builder(fb,
# ctx, "_compile_call_isa", 1)` seeds.
function _lower_isa!(b, fb, ctx, expr, idx, args, callee)::Union{InstrBuilder,Nothing}
    length(args) >= 2 || return nothing
    emit_call_operands!(fb, ctx, args)
    _compile_call_isa(args, fb, ctx)
    return append_builder!(b, fb)
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

BUILTIN_LOWERINGS[Core.getglobal] = _lower_getglobal!
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
BUILTIN_LOWERINGS[Core._expr] = _lower_expr!
BUILTIN_LOWERINGS[Symbol] = _lower_symbol!
BUILTIN_LOWERINGS[Core.donotdelete] = _lower_donotdelete!
BUILTIN_LOWERINGS[Core.compilerbarrier] = _lower_compilerbarrier!
BUILTIN_LOWERINGS[Core.apply_type] = _lower_apply_type!
BUILTIN_LOWERINGS[Core.typeof] = _lower_typeof!
BUILTIN_LOWERINGS[Core.:(===)] = _lower_egal!
BUILTIN_LOWERINGS[Core.:(!==)] = _lower_egal!
BUILTIN_LOWERINGS[Core.isa] = _lower_isa!                  # === Base.isa
BUILTIN_LOWERINGS[+] = _lower_operator!
BUILTIN_LOWERINGS[-] = _lower_operator!
BUILTIN_LOWERINGS[*] = _lower_operator!
BUILTIN_LOWERINGS[Core.ifelse] = _lower_ifelse!
BUILTIN_LOWERINGS[Base.ifelse] = _lower_ifelse!
BUILTIN_LOWERINGS[Core.typeassert] = _lower_typeassert!
BUILTIN_LOWERINGS[Core.getfield] = _lower_getfield!        # === Base.getfield
BUILTIN_LOWERINGS[Base.getproperty] = _lower_getproperty!
BUILTIN_LOWERINGS[Core.getproperty] = _lower_getproperty!
BUILTIN_LOWERINGS[Core.setfield!] = _lower_setfield!       # === Base.setfield!
BUILTIN_LOWERINGS[Base.setproperty!] = _lower_setfield!
BUILTIN_LOWERINGS[Core.setproperty!] = _lower_setfield!
