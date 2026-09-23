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
# Each entry is a lowering function `(b, fb, ctx, call, idx, args, callee) ->
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

# parity(intrinsics.dart:401 StaticIntrinsic._lookup): the table from a resolved callee to its
# lowering.
const BUILTIN_LOWERINGS = IdDict{Any,Function}()

"""Register one lowering under a callee's IDENTITY. Two names can be one object:
`Core.getproperty` IS `Core.getfield` and `Core.setproperty!` IS `Core.setfield!`
(measured), so a by-NAME reading of the retired ladder — which treated them as
four builtins — silently clobbers two entries when transcribed into an IdDict.
Registering the same object twice under DIFFERENT lowerings is that bug and is
rejected here at load time; aliases that map to the SAME lowering (Base./Core.
`sizeof`, `isvisible`/`_closed_world_isvisible`) are fine.
parity(intrinsics.dart:404 StaticIntrinsic._populateLookup)"""
function _register_builtin!(callee, lowering::Function)::Function
    prev = get(BUILTIN_LOWERINGS, callee, nothing)
    prev === nothing || prev === lowering ||
        error("BUILTIN_LOWERINGS already maps $(callee) to $(prev) — $(lowering) would clobber it")
    BUILTIN_LOWERINGS[callee] = lowering
    return lowering
end

"""The concrete Core/Base function OBJECT a call's callee names, mirroring dart's
`StaticIntrinsic.fromProcedure` lookup — the registry is keyed on that object's identity, never on the bare
name Symbol. The NIR boundary already resolved a bound global to its object; a callee the
IR embedded literally is unwrapped here. An unbound global (left a `GlobalRef` by the
boundary) and a runtime value (an SSA use, an argument) are explicit non-matches.
parity(intrinsics.dart:414 StaticIntrinsic.fromProcedure)"""
_resolve_builtin_callee(func) = nir_const(func)

"""THE funnel: resolve `func`'s callee identity once and, if it names a
registered Core/Base builtin, run its lowering. Returns the handled
`InstrBuilder` or `nothing` (generic/dynamic-call path continues) — dart's
nullable-return entry-funnel shape. Called ONCE from `compile_call!`, directly
after its ONE SSAValue→GlobalRef callee-resolution step, mirroring dart's
resolve-the-target-once dispatch (`StaticIntrinsic._lookup`, intrinsics.dart:401).
formal(dev/formal/ConsultChain.tla).
parity(intrinsics.dart:1194 generateStaticIntrinsic)"""
function _try_builtin_lowering!(b::InstrBuilder, fb::InstrBuilder, ctx::AbstractCompilationContext,
                                 call::NirCall, idx::Int, args, func)::Union{InstrBuilder,Nothing}
    callee = _resolve_builtin_callee(func)
    lowering = get(BUILTIN_LOWERINGS, callee, nothing)
    lowering === nothing && return nothing
    return lowering(b, fb, ctx, call, idx, args, callee)::Union{InstrBuilder,Nothing}
end

# ---- The entries -----------------------------------------------------------

# `Core.invoke_in_world(world, f, args...)` selects a method in Julia's
# mutable world-age model. A WT module is already one immutable collected
# world, so the exact lowering is the ordinary closed-world call to `f`;
# the captured world token has no runtime state to mutate.
# parity(quarantine: Julia's world-age builtin `Core.invoke_in_world`; dart has no world age,
# and a closed-world module has exactly one.)
function _lower_invoke_in_world!(b, fb, ctx, call, idx, args, callee)
    length(args) >= 2 || return nothing
    # The intrinsic's Julia SSA result is `Any`, but that is a consumer-side
    # widening, not the callee's return contract. Do not use it to reject the
    # concrete collected target; statement storage will box/widen afterward.
    had_result = haskey(ctx.ssa_types, idx)
    old_result = get(ctx.ssa_types, idx, Any)
    delete!(ctx.ssa_types, idx)
    try
        return compile_call!(b, nir_call(args[2], args[3:end]), idx, ctx)
    finally
        had_result && (ctx.ssa_types[idx] = old_result)
    end
end

# parity(quarantine: Julia's `isdefinedglobal` asks whether a module binding exists; dart has no
# runtime modules or bindings, so the closed world answers it from the TypeName constant.)
function _lower_isdefinedglobal!(b, fb, ctx, call, idx, args, callee)
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

# parity(quarantine: Julia's `Base.isvisible` walks module import/using visibility, which dart
# has no runtime counterpart for; the TypeName constant carries the closed-world answer.)
function _lower_isvisible!(b, fb, ctx, call, idx, args, callee)
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
# parity(quarantine: Julia's BindingPartition world bounds; dart has no world age.)
function _lower_check_world_bounded!(b, fb, ctx, call, idx, args, callee)
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
# parity(code_generator.dart:2183 visitStaticGet): the const-fold guard reads a module-level
# constant as dart reads a static field. The TypeName-trace guard is Julia-only: a `Module`
# and its binding names exist at runtime only as TypeName fields.
function _lower_getglobal!(b, fb, ctx, call, idx, args, callee)
    length(args) >= 2 || return nothing
    _gg_mod = args[1] isa NirGlobalRef ? (args[1].bound ? args[1].value : args[1]) :
              nir_const(args[1])
    _gg_name = nir_const(args[2])
    if _gg_mod isa Module && _gg_name isa Symbol && isdefined(_gg_mod, _gg_name) &&
       isconst(_gg_mod, _gg_name)
        _gg_val = getglobal(_gg_mod, _gg_name)
        emit_value!(fb, NirLiteral(_gg_val), ctx, static_wasm_type(NirLiteral(_gg_val), ctx))
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
function _lower_sizeof!(b, fb, ctx, call, idx, args, callee)
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
# parity(intrinsics.dart:626 WasmArrayRef.length): `array.len` then `i64.extend_i32_u`.
function _lower_ncodeunits!(b, fb, ctx, call, idx, args, callee)
    length(args) == 1 || return nothing
    arg = args[1]
    arg_type = infer_value_type(arg, ctx)
    if arg_type === String || arg_type <: AbstractString
        local _ncb = _ctx_builder(ctx, "compile_call")
        # ONE 4-arg wrap replaces the sniff+cast ladder
        emit_value!(_ncb, arg, ctx, ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))
        array_len!(_ncb)
        widen_length_to_i64!(_ncb)
        # parity(translator.dart:1597 Translator.convertType): the lowering's value is `Int`;
        # a statement Julia typed wider (`::Any` for an AbstractString receiver) receives
        # it boxed with Int's class
        get(ctx.ssa_types, idx, Any) === Int || coerce_stack_top!(_ncb, AnyRef, ctx; from_julia=Int)
        append_builder!(fb, _ncb)
        return append_builder!(b, fb)
    end
    return nothing
end

# Special case for length - returns character count for strings, element count for arrays
function _lower_length!(b, fb, ctx, call, idx, args, callee)
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
# parity(quarantine: a Julia Vararg tuple whose length is known only at runtime carries its arity
# in a size tuple; a dart record's arity is static.)
function _lower_nfields!(b, fb, ctx, call, idx, args, callee)
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

# ---- The MemoryRef pair channel --------------------------------------------
# A Julia MemoryRef is an inline immutable pair (its Memory, an element position in it).
# WT carries exactly that pair: the Memory is the raw wasm array and the position is an
# i32 count of elements from the array's start, off0 = memoryrefoffset - 1 — the pair
# dart's typed-data views hold as (_data, _offsetInElements). Where the pair lives:
#   * an indexed ref, `memoryrefnew(p, i, bc)`, is re-emitted from its operands where it
#     is read (memory = p's memory, off0 = p's off0 + i - 1) when every operand is a value
#     fixed at the definition (a local, an argument, a constant, or such a ref); its
#     statement emits only its bounds check. Julia's ref is a snapshot: re-emission may
#     never re-read a mutable field;
#   * a snapshot pair: an Array's :ref read, `getfield(a, :ref)`, or an indexed ref with
#     an operand that is not fixed at its definition — its statement stores its Memory in
#     its SSA local and its off0 in an i32 local (allocate_memoryref_offset_locals!);
#   * a MemoryRef phi with an incoming ref whose off0 is not provably 0 keeps off0 in an
#     i32 local beside its phi local (allocate_memoryref_offset_locals!);
#   * a MemoryRef constant carries its own offset;
#   * every other MemoryRef value (a fresh ref, a non-Array field read, an argument, a
#     call result) is at off0 = 0: a ref crosses a single-value boundary — a field, a
#     call, a return, an Any slot — as its memory alone, and only when its off0 is
#     provably 0 (emit_memoryref_single! rejects the rest at the crossing).

"""
    _memoryref_source(ctx, ref) -> (kind, node)

Where MemoryRef operand `ref` keeps its element offset, looking through PiNodes that have
no local: `(:pair, phi)` for a phi with an offset local, `(:snapshot, ssa)` for an Array's
`getfield(a, :ref)` or an indexed ref stored in its two locals, `(:indexed, call)` for an indexed
`memoryrefnew` re-emitted from its operands, `(:constant, value)` for a MemoryRef
constant, and `(:zero, ref)` for every other MemoryRef value, which is at offset 0.
parity(sdk/lib/_internal/wasm/common/typed_data.dart:2441 WasmI8ArrayBase): the view's
(_data, _offsetInElements) pair, found where the value was made.
"""
function _memoryref_source(ctx::AbstractCompilationContext, ref::NirNode)::Tuple{Symbol,Any}
    node = ref
    for _ in 1:(length(ctx.nir) + 1)
        literal = _nir_const_operand(node)
        literal isa Core.GenericMemoryRef && return (:constant, literal)
        node isa NirSSA && 1 <= node.id <= length(ctx.nir) || return (:zero, ref)
        haskey(ctx.memoryref_offset_locals, node.id) &&
            return (ctx.nir[node.id].node isa NirPhi ? :pair : :snapshot, node)
        haskey(ctx.ssa_locals, node.id) && return (:zero, ref)
        rec = ctx.nir[node.id]
        rec.slot == 0 || return (:zero, ref)
        def = rec.node
        if def isa NirPi
            node = def.value
        elseif def isa NirCall && _nir_callee_object(def.callee) === Core.memoryrefnew &&
               length(def.operands) >= 2
            return (:indexed, def)
        else
            return (:zero, ref)
        end
    end
    return (:zero, ref)
end

"""
    memoryref_offset_is_zero(ctx, ref) -> Bool

Whether MemoryRef operand `ref` is provably at element offset 0 (memoryrefoffset 1).
parity(sdk/lib/_internal/wasm/common/typed_data.dart:2446 WasmI8ArrayBase): a view made
from a fresh array starts at `_offsetInElements = 0`.
"""
function memoryref_offset_is_zero(ctx::AbstractCompilationContext, ref::NirNode)::Bool
    kind, src = _memoryref_source(ctx, ref)
    kind === :zero && return true
    kind === :constant && return Base.memoryrefoffset(src) == 1
    kind === :indexed && return _nir_const_operand(src.operands[2]) === 1 &&
                                memoryref_offset_is_zero(ctx, src.operands[1])
    return false
end

"""
    emit_memoryref_mem!(b, ctx, ref[, expected; from_julia]) -> b

Push the Memory (the raw wasm array) of MemoryRef operand `ref`, coerced to `expected`
when one is given. `temp_map` substitutes a phi's saved local on a phi edge.
parity(sdk/lib/_internal/wasm/common/typed_data.dart:2442 WasmI8ArrayBase._data)
"""
function emit_memoryref_mem!(b::InstrBuilder, ctx::AbstractCompilationContext, ref::NirNode,
                             expected::Union{WasmValType,Nothing}=nothing;
                             from_julia::Union{Type,Nothing}=nothing,
                             temp_map::Dict{Int,Int}=Dict{Int,Int}())::InstrBuilder
    kind, src = _memoryref_source(ctx, ref)
    if kind === :zero
        expected === nothing ?
            emit_value!(b, ref, ctx) :  # R17-floor: a MemoryRef at offset 0 is its memory, at the emitted array type
            emit_value!(b, ref, ctx, expected; from_julia=from_julia)
        return b
    elseif kind === :indexed
        emit_memoryref_mem!(b, ctx, src.operands[1]; temp_map=temp_map)
    elseif kind === :pair || kind === :snapshot
        mem_local = ctx.ssa_locals[src.id]
        local_get!(b, get(temp_map, mem_local, mem_local))
    else
        emit_value!(b, NirLiteral(getfield(src, :mem)), ctx)  # R17-floor: a constant's Memory is its array
    end
    expected === nothing || coerce_stack_top!(b, expected, ctx; from_julia=from_julia)
    return b
end

"""
    emit_memoryref_offset!(b, ctx, ref) -> b

Push the i32 element offset off0 = memoryrefoffset - 1 of MemoryRef operand `ref`. An
indexed ref adds its index to its base's off0 in i32: after the bounds check the sum is
exact, and it equals the wrapped i64 sum either way.
parity(sdk/lib/_internal/wasm/common/typed_data.dart:2786 I8List.[]):
`_offsetInElements + index`, wrapped to i32 by the array access (intrinsics.dart:1232).
"""
function emit_memoryref_offset!(b::InstrBuilder, ctx::AbstractCompilationContext, ref::NirNode)::InstrBuilder
    kind, src = _memoryref_source(ctx, ref)
    if kind === :zero
        i32_const!(b, 0)
    elseif kind === :constant
        i32_const!(b, Int64(Base.memoryrefoffset(src) - 1))
    elseif kind === :pair || kind === :snapshot
        local_get!(b, ctx.memoryref_offset_locals[src.id])
    else
        _emit_indexed_offset!(b, ctx, src)
    end
    return b
end

"""
    _emit_indexed_offset!(b, ctx, call) -> b

Push the i32 off0 of the indexed ref `call` = `memoryrefnew(p, i, bc)` computed from its
operands: p's off0 + i - 1.
parity(sdk/lib/_internal/wasm/common/typed_data.dart:2786 I8List.[]): `_offsetInElements + index`.
"""
function _emit_indexed_offset!(b::InstrBuilder, ctx::AbstractCompilationContext, call::NirCall)::InstrBuilder
    base, index = call.operands[1], call.operands[2]
    if memoryref_offset_is_zero(ctx, base)
        emit_value!(b, index, ctx, I32)   # Julia's Int index, wrapped to the wasm array index
    else
        emit_memoryref_offset!(b, ctx, base)
        emit_value!(b, index, ctx, I32)
        num!(b, Opcode.I32_ADD)
    end
    i32_const!(b, 1)
    num!(b, Opcode.I32_SUB)
    return b
end

"""
    emit_memoryref!(b, ctx, ref) -> b

Push MemoryRef operand `ref` as the pair an element access consumes: its array, then its
i32 element offset.
parity(pkg/dart2wasm/lib/intrinsics.dart:1223 wasmArrayIndex): the array, then the index.
"""
function emit_memoryref!(b::InstrBuilder, ctx::AbstractCompilationContext, ref::NirNode)::InstrBuilder
    emit_memoryref_mem!(b, ctx, ref)
    emit_memoryref_offset!(b, ctx, ref)
    return b
end

"""
    emit_memoryref_position!(b, ctx, ref) -> b

Push Julia's `memoryrefoffset(ref)`, the 1-based i64 position of MemoryRef operand `ref`
in its Memory.
parity(quarantine: Julia's `Core.memoryrefoffset` answers a 1-based position; dart reads
`_offsetInElements` as a 0-based count.)
"""
function emit_memoryref_position!(b::InstrBuilder, ctx::AbstractCompilationContext, ref::NirNode)::InstrBuilder
    kind, src = _memoryref_source(ctx, ref)
    if kind === :zero
        i64_const!(b, 1)
    elseif kind === :constant
        i64_const!(b, Int64(Base.memoryrefoffset(src)))
    elseif kind === :pair || kind === :snapshot
        local_get!(b, ctx.memoryref_offset_locals[src.id])
        widen_length_to_i64!(b)
        i64_const!(b, 1)
        num!(b, Opcode.I64_ADD)
    else
        base, index = src.operands[1], src.operands[2]
        if memoryref_offset_is_zero(ctx, base)
            emit_value!(b, index, ctx, I64)   # the position is Julia's Int
        else
            emit_memoryref_position!(b, ctx, base)
            emit_value!(b, index, ctx, I64)
            num!(b, Opcode.I64_ADD)
            i64_const!(b, 1)
            num!(b, Opcode.I64_SUB)
        end
    end
    return b
end

"""
    emit_memoryref_single!(b, ctx, ref) -> b

A MemoryRef crossing a boundary typed MemoryRef that holds one wasm value — a call
argument or result, a Memory{MemoryRef{T}} element — is its Memory; that carries the ref
only at offset 0. Any other ref rejects at the crossing, located: its offset is never
dropped. (A slot that holds any value, and a struct, closure or tuple field, holds the ref's
single-value struct instead: emit_value!'s MemoryRef arm, register_memoryref_box!.)
parity(quarantine: Julia's MemoryRef is an inline immutable (allocatedinline); dart has no
class it must unbox.)
"""
function emit_memoryref_single!(b::InstrBuilder, ctx::AbstractCompilationContext, ref::NirNode)::InstrBuilder
    if memoryref_offset_is_zero(ctx, ref)
        return emit_memoryref_mem!(b, ctx, ref)
    end
    emit_unsupported_stub!(ctx, b, :unsupported_type,
        "a MemoryRef whose element offset is not provably 0 crosses a MemoryRef-typed call, return or Memory element, which carries only its Memory";
        idx=ctx.current_stmt_idx, detail=ref)
    return b
end

"""
    allocate_memoryref_offset_locals!(ctx)

Give every snapshot pair — an Array :ref read (`getfield(a, :ref)`), an indexed ref with
an operand not fixed at its definition, a `memoryrefset!` storing a MemoryRef (its result),
or a PiNode unpacking a MemoryRef's single-value
struct out of a slot that holds any value (emit_memoryref_unbox!) — a local for its Memory and an i32 local for the
off0 its statement stores, and every MemoryRef phi with an incoming ref whose offset is not provably 0 an
i32 local for its off0, beside the phi local that holds its Memory — to a fixpoint, since a
phi carrying an offset makes the phis it feeds carry one.
parity(quarantine: Julia's MemoryRef is an inline immutable (allocatedinline); its two
words live in two locals, as dart keeps a typed-data view's fields in its struct.)
"""
function allocate_memoryref_offset_locals!(ctx::AbstractCompilationContext)::Nothing
    # in statement order, so an indexed ref sees whether its base was snapshotted
    for (i, rec) in enumerate(ctx.nir)
        if _is_array_ref_read(ctx, rec) ||
           (_is_indexed_memoryrefnew(rec) &&
            !(_memoryref_operand_is_fixed(ctx, rec.node.operands[1]) &&
              _memoryref_operand_is_fixed(ctx, rec.node.operands[2]))) ||
           (rec.node isa NirPi && _is_memoryref_unbox(ctx, rec)) ||
           _is_memoryref_store_result(ctx, rec)
            haskey(ctx.ssa_locals, i) || (ctx.ssa_locals[i] = allocate_local!(ctx,
                ConcreteRef(get_array_type!(ctx.mod, ctx.type_registry, eltype(rec.julia_type)), true)))
            ctx.memoryref_offset_locals[i] = allocate_local!(ctx, I32)
        elseif _is_memoryref_field_read(ctx, rec)
            record_unsupported!(ctx, :unsupported_type,
                "a MemoryRef read from a struct, closure or tuple field: the field holds the ref's single-value struct, which is not unpacked into the pair channel yet";
                idx=i, detail=rec.node)
        elseif _is_memoryref_unbox(ctx, rec)
            record_unsupported!(ctx, :unsupported_type,
                "typeassert of a value that holds any value to a MemoryRef: its single-value struct is unpacked only by a PiNode yet";
                idx=i, detail=rec.node)
        end
    end
    phis = Int[i for (i, rec) in enumerate(ctx.nir)
               if rec.slot == 0 && rec.node isa NirPhi && haskey(ctx.ssa_locals, i) &&
                  (T = get(ctx.ssa_types, i, Any); T isa Type && T !== Union{} &&
                   T <: Core.GenericMemoryRef)]
    changed = true
    while changed
        changed = false
        for i in phis
            haskey(ctx.memoryref_offset_locals, i) && continue
            any(v -> v !== nothing && !memoryref_offset_is_zero(ctx, v), ctx.nir[i].node.values) ||
                continue
            ctx.memoryref_offset_locals[i] = allocate_local!(ctx, I32)
            changed = true
        end
    end
    return nothing
end

"""
    _is_array_ref_read(ctx, rec) -> Bool

Whether NIR statement `rec` reads an Array's :ref — `getfield(a, :ref)` (or field 1) on an
`Array{T,N}` — the one read that yields a MemoryRef with an offset.
parity(quarantine: Julia's Array keeps its :ref MemoryRef inline; the read is the pair of
its data and off0 fields.)
"""
function _is_array_ref_read(ctx::AbstractCompilationContext, rec::NirStmt)::Bool
    rec.slot == 0 || return false
    node = rec.node
    node isa NirCall && length(node.operands) >= 2 || return false
    callee = _nir_callee_object(node.callee)
    callee === Core.getfield || callee === Base.getproperty || return false
    field = _nir_field_name(node.operands[2])
    field === :ref || field === 1 || return false
    T = get_ssa_type(ctx, node.operands[1])
    return T isa DataType && T <: Array
end

"""
    _is_indexed_memoryrefnew(rec) -> Bool

Whether NIR statement `rec` defines an indexed ref, `memoryrefnew(p, i, bc)`.
parity(quarantine: Julia's `Core.memoryrefnew` makes a GenericMemoryRef at an index; dart has
no interior array reference.)
"""
_is_indexed_memoryrefnew(rec::NirStmt)::Bool =
    rec.slot == 0 && rec.node isa NirCall && length(rec.node.operands) >= 3 &&
    _nir_callee_object(rec.node.callee) === Core.memoryrefnew

"""
    _memoryref_operand_is_fixed(ctx, x) -> Bool

Whether operand `x` of an indexed ref re-emits to the value it had at the ref's
definition: an argument, a constant, an SSA value held in its local (written once, at its
definition), a PiNode of one, a fresh ref of one, or an indexed ref whose operands are
fixed. Anything else — an SSA value WT recomputes from its definition, which may read a
field a later `setfield!` or growth call changes — is not.
parity(quarantine: Julia's MemoryRef is an immutable snapshot of (Memory, offset); WT
re-emits a ref from its operands only where that preserves the snapshot.)
"""
function _memoryref_operand_is_fixed(ctx::AbstractCompilationContext, x::NirNode)::Bool
    x isa NirArgument && return true
    x isa NirLiteral && return true
    _nir_const_operand(x) !== nothing && return true
    x isa NirSSA && 1 <= x.id <= length(ctx.nir) || return false
    haskey(ctx.ssa_locals, x.id) && return true
    rec = ctx.nir[x.id]
    rec.slot == 0 || return false
    def = rec.node
    def isa NirPi && return _memoryref_operand_is_fixed(ctx, def.value)
    def isa NirCall || return false
    callee = _nir_callee_object(def.callee)
    if callee === Core.memoryrefnew && length(def.operands) >= 3
        return _memoryref_operand_is_fixed(ctx, def.operands[1]) &&
               _memoryref_operand_is_fixed(ctx, def.operands[2])
    end
    (callee === Core.memoryrefnew || callee === Core.memoryref) && length(def.operands) == 1 &&
        return _memoryref_operand_is_fixed(ctx, def.operands[1])
    return false
end

"""
    _is_memoryref_store_result(ctx, rec) -> Bool

Whether NIR statement `rec` is a `memoryrefset!` whose result — the value it stored — is a
MemoryRef with a local: the result is that ref's snapshot pair.
parity(quarantine: Julia's `Core.memoryrefset!` returns the stored value; a MemoryRef value
is its (Memory, offset) pair.)
"""
function _is_memoryref_store_result(ctx::AbstractCompilationContext, rec::NirStmt)::Bool
    rec.slot == 0 && rec.node isa NirCall && length(rec.node.operands) >= 2 || return false
    _nir_callee_object(rec.node.callee) === Core.memoryrefset! || return false
    T = get_ssa_type(ctx, rec.node.operands[2])
    return T isa DataType && T <: Core.GenericMemoryRef && isconcretetype(T)
end

"""
    _is_memoryref_unbox(ctx, rec) -> Bool

Whether NIR statement `rec` narrows a value that is not statically a MemoryRef — read from a
slot that holds any value — to a MemoryRef (a PiNode or `typeassert`).
parity(quarantine: Julia's MemoryRef is an inline immutable; out of an Any slot it is its
single-value struct.)
"""
function _is_memoryref_unbox(ctx::AbstractCompilationContext, rec::NirStmt)::Bool
    rec.slot == 0 || return false
    T = rec.julia_type
    T isa Type && T !== Union{} && T <: Core.GenericMemoryRef || return false
    node = rec.node
    src = if node isa NirPi
        node.value
    elseif node isa NirCall && _nir_callee_object(node.callee) === Core.typeassert && !isempty(node.operands)
        node.operands[1]
    else
        return false
    end
    S = get_ssa_type(ctx, src)
    return !(S isa Type && S !== Union{} && S <: Core.GenericMemoryRef)
end

"""
    emit_memoryref_unbox!(b, ctx, idx, T)

Unpack the single-value struct of MemoryRef type `T` on the stack (a value from a slot that
holds any value) into snapshot pair `idx`: its off0 into the pair's offset local, its Memory
into the SSA's local. A value that is not that struct traps at the cast, as the PiNode's
proof guarantees it never is.
parity(code_generator.dart:6076 loadClassId): the struct is read through its concrete type.
"""
function emit_memoryref_unbox!(b::InstrBuilder, ctx::AbstractCompilationContext, idx::Int,
                               @nospecialize(T))::InstrBuilder
    box_idx = register_memoryref_box!(ctx.mod, ctx.type_registry, T)
    tmp = allocate_local!(ctx, ConcreteRef(box_idx, false))
    ref_cast!(b, Int64(box_idx), false)
    local_tee!(b, tmp)
    struct_get!(b, box_idx, UInt32(3), I32)   # off0
    local_set!(b, ctx.memoryref_offset_locals[idx])
    local_get!(b, tmp)
    struct_get!(b, box_idx, UInt32(2), ConcreteRef(get_array_type!(ctx.mod, ctx.type_registry, eltype(T)), true))
    local_set!(b, ctx.ssa_locals[idx])
    return b
end

"""
    _is_memoryref_field_read(ctx, rec) -> Bool

Whether NIR statement `rec` reads a MemoryRef out of a field of anything but an Array — a
struct, closure or tuple field, which holds the ref's single-value struct
(memoryref_field_type!).
parity(quarantine: Julia's MemoryRef is an inline immutable; a field of MemoryRef type holds
its pair.)
"""
function _is_memoryref_field_read(ctx::AbstractCompilationContext, rec::NirStmt)::Bool
    node = rec.node
    node isa NirCall && length(node.operands) >= 2 || return false
    callee = _nir_callee_object(node.callee)
    callee === Core.getfield || callee === Base.getproperty || return false
    T = rec.julia_type
    T isa Type && T !== Union{} && T <: Core.GenericMemoryRef || return false
    O = get_ssa_type(ctx, node.operands[1])
    return !(O isa Type && (O <: Array || O <: Core.GenericMemoryRef || O <: GenericMemory))
end

"""
    emit_memoryref_box!(b, ctx, ref, T) -> b

Push MemoryRef operand `ref` of concrete type `T` as its single-value struct
{classId, identityHash, mem, off0} (register_memoryref_box!).
parity(code_generator.dart:6070 pushObjectHeaderFields): the Object header, then the fields.
"""
function emit_memoryref_box!(b::InstrBuilder, ctx::AbstractCompilationContext, ref::NirNode,
                             @nospecialize(T))::InstrBuilder
    box_idx = register_memoryref_box!(ctx.mod, ctx.type_registry, T)
    emit_object_prefix!(b, ctx.type_registry, T)
    emit_memoryref!(b, ctx, ref)
    struct_new!(b, box_idx)
    return b
end

"""
    _emit_memoryrefnew_boundscheck!(b, ctx, call) -> b

The bounds check of `memoryrefnew(p, i, bc)`: unless `bc` is false, the new element offset
off0(p) + i - 1, computed in i64, must lie in [0, length(mem)) read unsigned, or Julia's
`BoundsError(p, i)` is thrown, a MemoryRef `p` in its single-value struct
(register_memoryref_box!). On Julia 1.13 `p` may be a Memory, the ref at its offset 0.
parity(sdk/lib/_internal/wasm/common/error_utils.dart:22 IndexErrorUtils.checkIndexBCE):
`length.leU(index)` then the throw; `checkBounds` off is Julia's `bc == false`.
"""
function _emit_memoryrefnew_boundscheck!(b::InstrBuilder, ctx::AbstractCompilationContext,
                                         call::NirCall)::InstrBuilder
    length(call.operands) >= 3 || return b
    base, index, bc = call.operands[1], call.operands[2], call.operands[3]
    bc_def = bc isa NirSSA && 1 <= bc.id <= length(ctx.nir) && ctx.nir[bc.id].slot == 0 ?
        ctx.nir[bc.id].node : bc
    bc_static = bc_def isa NirBoundscheck ? bc_def.flag !== false : _nir_const_operand(bc)
    bc_static === false && return b
    if bc_static !== true
        emit_value!(b, bc, ctx, I32)
        if_!(b)
    end
    if memoryref_offset_is_zero(ctx, base)
        emit_value!(b, index, ctx, I64)
    else
        emit_memoryref_offset!(b, ctx, base)
        widen_length_to_i64!(b)
        emit_value!(b, index, ctx, I64)
        num!(b, Opcode.I64_ADD)
    end
    i64_const!(b, 1)
    num!(b, Opcode.I64_SUB)
    emit_memoryref_mem!(b, ctx, base)
    array_len!(b)
    widen_length_to_i64!(b)
    num!(b, Opcode.I64_GE_U)
    if_!(b)
    ensure_exception_tag!(ctx.mod)
    exn_global = ensure_exception_global!(ctx.mod)
    error_info = register_struct_type!(ctx.mod, ctx.type_registry, BoundsError)
    error_info === nothing && error("BoundsError layout is unavailable")
    emit_struct_prefix!(b, ctx.type_registry, BoundsError, error_info)
    # BoundsError's `a` holds any value: the base as Julia passes it — a Memory base (Julia
    # 1.13 indexes a Memory directly) as itself, a MemoryRef base in its single-value struct,
    # with its offset.
    base_type = get_ssa_type(ctx, base)
    if base_type isa DataType && base_type <: GenericMemory
        emit_value!(b, base, ctx, AnyRef; from_julia=base_type)
    else
        base_type isa DataType && base_type <: Core.GenericMemoryRef && isconcretetype(base_type) ||
            error("memoryrefnew's base is neither a Memory nor a concrete MemoryRef: $base_type")
        emit_memoryref_box!(b, ctx, base, base_type)
    end
    emit_value!(b, index, ctx, AnyRef; from_julia=Int64)
    struct_new!(b, error_info.wasm_type_idx)
    global_set!(b, exn_global)
    global_get!(b, exn_global, AnyRef)
    ref_null!(b, ExternRef)
    throw_!(b, 0; inputs=WasmValType[AnyRef, ExternRef])
    end_block!(b)
    bc_static !== true && end_block!(b)
    return b
end

# `memoryref_isassigned(ref, ordering, boundscheck)`: inline/packed element
# arrays have no undefined representation and are always assigned. Reference
# arrays encode Julia's undefined slot as null and require an actual load.
# parity(quarantine: Julia's `Core.memoryref_isassigned` on a GenericMemoryRef — an undefined
# reference slot is null; dart's WasmArray has no undefined-slot query.)
function _lower_memoryref_isassigned!(b, fb, ctx, call, idx, args, callee)
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
    emit_memoryref!(mib, ctx, ref_arg)
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
# parity(quarantine: Julia's GenericMemoryRef is an (array, index) pair read by `Core.memoryrefget`;
# the load itself is the `array.get` of intrinsics.dart:1223 wasmArrayIndex.)
function _lower_memoryrefget!(b, fb, ctx, call, idx, args, callee)
    length(args) >= 1 || return nothing
    ref_arg = args[1]
    ref_type = infer_value_type(ref_arg, ctx)

    # Nothing-typed memory — always returns nothing (i32.const 0).
    # Consume the [array_ref, i32_index] stack pair from memoryrefnew, then push 0.
    if ref_type isa DataType && (
        (ref_type.name.name === :MemoryRef && length(ref_type.parameters) >= 1 && ref_type.parameters[1] === Nothing) ||
        (ref_type.name.name === :GenericMemoryRef && length(ref_type.parameters) >= 2 && ref_type.parameters[2] === Nothing))
        emit_memoryref!(fb, ctx, ref_arg)
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

    local _mrgb = _ctx_builder(ctx, "compile_call")
    emit_memoryref!(_mrgb, ctx, ref_arg)

    array_get!(_mrgb, array_type_idx, AnyRef; signed=packed_array_signedness(elem_type))

    # Note: if elem_type is Any, array.get returns externref and the SSA local
    # is also typed as externref (fixed in analyze_ssa_types!). No cast needed here.
    append_builder!(fb, _mrgb)
    return append_builder!(b, fb)
end

# `memoryrefoffset(ref)`: the 1-based position the pair channel carries (emit_memoryref_position!).
# parity(quarantine: Julia's `Core.memoryrefoffset`, the 1-based position of a GenericMemoryRef
# in its Memory; dart has no interior array reference.)
function _lower_memoryrefoffset!(b, fb, ctx, call, idx, args, callee)
    length(args) >= 1 || return nothing
    local _mrob = _ctx_builder(ctx, "compile_call")
    emit_memoryref_position!(_mrob, ctx, args[1])
    append_builder!(fb, _mrob)
    return append_builder!(b, fb)
end

# Special case for memoryrefset! - array element assignment
# memoryrefset!(ref, value, ordering, boundscheck) -> stores value in array
# In Julia, setindex! returns the stored value, so we need to return it too
# parity(quarantine: Julia's GenericMemoryRef store `Core.memoryrefset!`; the store itself is the
# `array.set` of intrinsics.dart:1239 wasmArrayIndexSet.)
function _lower_memoryrefset!(b, fb, ctx, call, idx, args, callee)
    length(args) >= 2 || return nothing
    ref_arg = args[1]
    value_arg = args[2]
    ref_type = infer_value_type(ref_arg, ctx)

    # Nothing-typed memory — storing nothing is a no-op.
    # Don't push a result — Nothing has no Wasm representation to keep on the stack.
    if ref_type isa DataType && (
        (ref_type.name.name === :MemoryRef && length(ref_type.parameters) >= 1 && ref_type.parameters[1] === Nothing) ||
        (ref_type.name.name === :GenericMemoryRef && length(ref_type.parameters) >= 2 && ref_type.parameters[2] === Nothing))
        emit_memoryref!(fb, ctx, ref_arg)
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

    local _msb = _ctx_builder(ctx, "compile_call")
    emit_memoryref!(_msb, ctx, ref_arg)

    # Compile the value to store - we need it twice (for array.set and return)
    # First compile gets the value on stack for array.set
    local mset_val_T = get_ssa_type(ctx, value_arg)
    local mset_val_is_mr = mset_val_T isa DataType && mset_val_T <: Core.GenericMemoryRef &&
                           isconcretetype(mset_val_T)
    # a MemoryRef is emitted by the sink's own funnel below, never as a bare value here
    local _mv_b = mset_val_is_mr ? _ctx_builder(ctx, "compile_call") : _compile_value_b(value_arg, ctx)
    local mset_val_ty = isempty(_mv_b.v.stack) ? nothing : _mv_b.v.stack[end]
    # If array element type is anyref/externref (elem_type is Any OR abstract type), box numeric values
    # Check the actual wasm element type, not just elem_type === Any
    # Abstract types like CallInfo also map to ExternRef
    # PHASE-1-004: AnyRef arrays (Memory{Any}) need numeric→anyref boxing via struct.new
    local wasm_elem_type = get_concrete_wasm_type(elem_type, ctx.mod, ctx.type_registry)
    if mset_val_is_mr
        # a MemoryRef stored in a slot that holds any value is its single-value struct
        # (emit_value!'s MemoryRef arm); in a Memory{MemoryRef{T}} slot it is its Memory,
        # at offset 0 only (emit_memoryref_single! rejects the rest)
        emit_value!(_msb, value_arg, ctx, wasm_elem_type)
    elseif wasm_elem_type === AnyRef
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
        # Array of concrete ref types (struct/array refs, or a nullable numeric's box):
        # `nothing` is the element type's null; a numeric value is boxed with its Julia
        # classId by the value wrap (never replaced by a null).
        if is_nothing_value(value_arg, ctx)
            ref_null!(_msb, Int64(wasm_elem_type.type_idx), wasm_elem_type)
        elseif mset_val_ty === I64 || mset_val_ty === I32 || mset_val_ty === F64 || mset_val_ty === F32
            emit_value!(_msb, value_arg, ctx, wasm_elem_type)   # the wrap boxes it
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
        append_builder!(_msb, _mv_b)
    end

    # array.set consumes [array_ref, i32_index, value] and returns nothing
    array_set!(_msb, array_type_idx, AnyRef)

    # Julia's memoryrefset! returns the stored value, so push it again
    # This is needed because compile_statement may add LOCAL_SET after this
    # Only emit return value if SSA has a local to store it in.
    # Without this guard, the return value (e.g., i32.const 0 for nothing)
    # is left on the stack when the SSA has no allocated local, causing
    # "values remaining on stack at end of block" validation errors.
    if haskey(ctx.memoryref_offset_locals, idx)
        # the stored MemoryRef is this call's result: a snapshot pair of the value stored
        emit_memoryref_offset!(_msb, ctx, value_arg)
        local_set!(_msb, ctx.memoryref_offset_locals[idx])
        emit_memoryref_mem!(_msb, ctx, value_arg)
    elseif haskey(ctx.ssa_locals, idx)
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
# parity(quarantine: Julia's `Core.memorynew` allocates a GenericMemory; the allocation is the
# `array.new_default` of intrinsics.dart:1959 wasmArrayNew.)
function _lower_memorynew!(b, fb, ctx, call, idx, args, callee)
    length(args) >= 2 || return nothing
    mem_type = nir_const(args[1])  # Memory{T} type (compile-time constant)
    size_arg = args[2]  # size (may be literal or SSA)

    # The element type is the literal Memory{T}'s own; any other operand is not lowered here.
    mem_type isa DataType && mem_type <: Memory && isconcretetype(mem_type) || return nothing
    elem_type = eltype(mem_type)

    arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

    # The array holds exactly the requested length: Julia's growth paths read
    # `length(ref.mem)` as the capacity, so any padding here is observable.
    local _mnb = _ctx_builder(ctx, "compile_call")
    emit_memory_length!(_mnb, ctx, size_arg, mem_type)
    array_new_default!(_mnb, arr_type_idx)
    append_builder!(fb, _mnb)
    return append_builder!(b, fb)
end

"""
    memory_length_limit(mem_type) -> UInt64

The smallest element count Julia's allocator rejects for `mem_type`: `_new_genericmemory_`
(src/genericmemory.c) throws ArgumentError once the count, or its byte size (element size, plus
one selector byte per element for an isbits-union element), reaches `typemax(Int)`. A negative
count, read as unsigned, lies above every limit.
parity(quarantine: Julia's GenericMemory size rule; dart's array length check is typed_data.dart:38 _newArrayLengthCheck.)
"""
function memory_length_limit(@nospecialize(mem_type))::UInt64
    per_element = UInt64(Base.elsize(mem_type)) + (Base.isbitsunion(eltype(mem_type)) ? UInt64(1) : UInt64(0))
    max_int = UInt64(typemax(Int))
    return per_element == 0 ? max_int : min(max_int, cld(max_int, per_element))
end

# parity(quarantine: the exception Julia's `_new_genericmemory_` throws, message verbatim.)
const _MEMORY_SIZE_ERROR = ArgumentError("invalid GenericMemory size: the number of elements is either negative or too large for system address width")
# parity(sdk/lib/_internal/wasm/common/typed_data.dart:36 _maxWasmArrayLength)
const _MAX_WASM_ARRAY_LENGTH = Int64(typemax(Int32))
# parity(sdk/lib/_internal/wasm/common/typed_data.dart:38 _newArrayLengthCheck): dart checks
# a requested length against [0, max i32] before `i32.wrap_i64; array.new_default`
# (intrinsics.dart:1981). The rejection is Julia's own: ArgumentError past
# `memory_length_limit` (Base's exact message), and an in-range length no wasm array can
# hold is an allocation failure, OutOfMemoryError. Leaves the i32 length on the stack.
function emit_memory_length!(b::InstrBuilder, ctx::AbstractCompilationContext, size_arg,
                             @nospecialize(mem_type))::InstrBuilder
    limit = memory_length_limit(mem_type)
    literal = size_arg isa NirNode ? _nir_const_operand(size_arg) : size_arg
    if literal isa Integer
        n = Int64(literal)
        if reinterpret(UInt64, n) >= limit
            _emit_throw_value!(b, ctx, _MEMORY_SIZE_ERROR)
        elseif n > _MAX_WASM_ARRAY_LENGTH
            _emit_throw_error_struct!(b, ctx, OutOfMemoryError)
        end
        i32_const!(b, n % Int32)
        return b
    end
    n_local = allocate_local!(ctx, I64)
    emit_value!(b, size_arg, ctx, I64)
    local_tee!(b, n_local)
    i64_const!(b, reinterpret(Int64, limit))
    num!(b, Opcode.I64_GE_U)
    if_!(b)
    _emit_throw_value!(b, ctx, _MEMORY_SIZE_ERROR)
    end_block!(b)
    local_get!(b, n_local)
    i64_const!(b, _MAX_WASM_ARRAY_LENGTH)
    num!(b, Opcode.I64_GT_U)
    if_!(b)
    _emit_throw_error_struct!(b, ctx, OutOfMemoryError)
    end_block!(b)
    local_get!(b, n_local)
    narrow_length_to_i32!(b)
    return b
end

# parity(code_generator.dart:2955 visitThrow): the exception value is translated, then
# thrown through the one (exn, trace) tag, stashed in the exception global as every
# WT throw site does.
function _emit_throw_value!(b::InstrBuilder, ctx::AbstractCompilationContext, exn::Exception)::InstrBuilder
    ensure_exception_tag!(ctx.mod)
    exn_global = ensure_exception_global!(ctx.mod)
    emit_value!(b, NirLiteral(exn), ctx, AnyRef; from_julia=typeof(exn))   # a host exception value: the explicit literal node
    global_set!(b, exn_global)
    global_get!(b, exn_global, AnyRef)
    ref_null!(b, ExternRef)
    throw_!(b, 0; inputs=WasmValType[AnyRef, ExternRef])
    return b
end

# Special case for Core.memoryref - creates MemoryRef from Memory
# memoryref(memory::Memory{T}) -> MemoryRef{T}
# In WasmGC, this is a no-op since Memory IS the array
# parity(quarantine: Julia's `Core.memoryref` makes a GenericMemoryRef from a Memory; dart has no
# interior array reference.)
function _lower_memoryref!(b, fb, ctx, call, idx, args, callee)
    length(args) == 1 || return nothing
    # Pass through the array reference - Memory and MemoryRef are the same in WasmGC
    emit_value!(fb, args[1], ctx)  # R17-floor: memoryref identity preserves its array representation
    return append_builder!(b, fb)
end

# `memoryrefnew(mem)` is the fresh ref at offset 0: its Memory. `memoryrefnew(p, i, bc)` is an
# indexed ref, re-emitted from its operands wherever it is read (the pair channel above);
# its statement runs only the bounds check, which is its one effect.
# parity(quarantine: Julia's `Core.memoryrefnew` makes a GenericMemoryRef at an index; dart has
# no interior array reference.)
function _lower_memoryrefnew!(b, fb, ctx, call, idx, args, callee)
    if length(args) == 1
        emit_value!(fb, args[1], ctx)  # R17-floor: a fresh ref is its Memory, at the Memory's array type
        return append_builder!(b, fb)
    elseif length(args) >= 2
        local _mrnb = _ctx_builder(ctx, "compile_call")
        _emit_memoryrefnew_boundscheck!(_mrnb, ctx, call)
        if haskey(ctx.memoryref_offset_locals, idx)
            # a snapshot pair: off0 into its local, then the Memory, which the statement
            # stores into this SSA's local
            _emit_indexed_offset!(_mrnb, ctx, call)
            local_set!(_mrnb, ctx.memoryref_offset_locals[idx])
            emit_memoryref_mem!(_mrnb, ctx, call.operands[1])
        else
            haskey(ctx.ssa_locals, idx) &&
                error("an indexed MemoryRef re-emitted from its operands has no local of its own")
        end
        append_builder!(fb, _mrnb)
        return append_builder!(b, fb)
    end
    return nothing
end

# Special case for Core.tuple - tuple creation
# parity(code_generator.dart:3239 visitRecordLiteral)
function _lower_tuple!(b, fb, ctx, call, idx, args, callee)
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
            # A MemoryRef element: its field holds the ref's single-value struct
            # (memoryref_field_type!), built by the sink's funnel.
            local _mr_jt = _value_julia_type(arg, ctx)
            if _mr_jt isa DataType && _mr_jt <: Core.GenericMemoryRef
                local _mr_fi = fi + Int(info.field_offset)
                (struct_type_def isa StructType && _mr_fi <= length(struct_type_def.fields)) ||
                    error("tuple field $fi has no physical Wasm type")
                emit_value!(_tupb, arg, ctx, struct_type_def.fields[_mr_fi].valtype)
                continue
            end
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
# parity(quarantine: Julia's `Core.donotdelete` optimizer fence; dart has no such builtin.)
function _lower_donotdelete!(b, fb, ctx, call, idx, args, callee)
    return append_builder!(b, fb)
end

# Special case for compilerbarrier - just pass through the value
# parity(quarantine: Julia's `Core.compilerbarrier` inference barrier; dart has no such builtin.)
function _lower_compilerbarrier!(b, fb, ctx, call, idx, args, callee)
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
# parity(quarantine: Julia builds a `Union` at runtime through `Core.apply_type`; dart has no
# runtime union-type construction.)
function _lower_apply_type!(b, fb, ctx, call, idx, args, callee)
    length(args) == 3 || return nothing
    union_ctor = nir_const(args[1]) === Union ||
        (args[1] isa NirGlobalRef && args[1].bound && args[1].value === Union)
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
# parity(quarantine: Julia's `typeof` returns a first-class DataType whose identity (`===`) and
# fields Julia code reads; dart's `runtimeType` (intrinsics.dart:2963 objectRuntimeType) returns
# a masqueraded `Type` with no such contract.)
function _lower_typeof!(b, fb, ctx, call, idx, args, callee)
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

# parity(intrinsics.dart:1409 identical): two storage pointers (Base.dataids' `UInt(m.ptr)`,
# `pointer(A) == pointer(B)`) are equal exactly when their backing objects are identical —
# `ref.eq`, as dart compares references — or, per Julia, both are the one empty Memory of
# their element type, and their storage-relative offsets (the compiled pointer values)
# are equal.
function _emit_storage_pointer_egal!(fb::InstrBuilder, ctx::AbstractCompilationContext,
                                     ptr_a, backing_a::NirNode, ptr_b, backing_b::NirNode)::InstrBuilder
    elem_a = _storage_element_type(backing_a, ctx)
    same_type = elem_a === _storage_element_type(backing_b, ctx)
    locals = map(((backing_a, elem_a), (backing_b, _storage_element_type(backing_b, ctx)))) do (backing, elem)
        arr = get_array_type!(ctx.mod, ctx.type_registry, elem)
        _emit_backing_array!(fb, backing, ctx, arr)
        l = allocate_local!(ctx, ConcreteRef(UInt32(arr), true))
        local_tee!(fb, l)
        return l
    end
    num!(fb, Opcode.REF_EQ)
    if same_type
        for l in locals
            local_get!(fb, l)
            array_len!(fb)
            num!(fb, Opcode.I32_EQZ)
        end
        num!(fb, Opcode.I32_AND)
        num!(fb, Opcode.I32_OR)
    end
    emit_value!(fb, ptr_a, ctx, I64)
    emit_value!(fb, ptr_b, ctx, I64)
    num!(fb, Opcode.I64_EQ)
    num!(fb, Opcode.I32_AND)
    return fb
end

# `Core._expr(:head, arg1, arg2, ...)` — materializes an `Expr(head::Symbol,
# args::Vector{Any})`. Julia-only (dart has no `Expr` node); the WasmGC
# representation is a classed Expr struct wrapping a head Symbol (a classed
# string) and a Vector{Any} of the remaining args. Self-contained: emits its
# own operands directly onto `fb` (R19 — this identity match used to gate a
# `_skip_arg_prepush` carve-out in `compile_call!`'s generic arg-push loop;
# consulted from THE identity-keyed funnel instead, this call never reaches
# that loop at all, so no carve-out is needed there any more).
# parity(quarantine: Julia's `Core._expr` builds an `Expr`, a runtime syntax object dart has no
# counterpart for.)
function _lower_expr!(b, fb, ctx, call, idx, args, callee)
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
        i32_const!(ib, 0)   # off0: the fresh data array starts at element 0
        struct_new!(ib, vec_any_info.wasm_type_idx)   # mod-resolved fields
        # struct.new Expr with (typeId, head, vector)
        struct_new!(ib, expr_info.wasm_type_idx)   # mod-resolved fields
        append_builder!(fb, ib)
    end

    return append_builder!(b, fb)
end

# `Symbol(x)` — the Symbol named by `x`: a Symbol is itself; a String (or an Any holding a
# String or Symbol) has its byte array wrapped under Symbol's own class, and any other
# runtime class traps at the cast to the classed string. A static type that holds neither
# (Julia's `Symbol(string(x...))` fallback) rejects at the statement.
# parity(constants.dart:1556 ConstantCreator.visitSymbolConstant): a Symbol is its own class.
function _lower_symbol!(b, fb, ctx, call, idx, args, callee)
    length(args) == 1 || return nothing
    local T = get_ssa_type(ctx, args[1])
    if T === Symbol
        append_builder!(fb, _compile_value_b(args[1], ctx))
    elseif T isa Type && typeintersect(T, Union{String,Symbol}) === Union{}
        emit_unsupported_stub!(ctx, fb, :unsupported_method,
            "Symbol(::$(T)) is Symbol(string(x)), which this builtin does not lower";
            idx=idx, detail=call)
    else
        emit_value!(fb, args[1], ctx,
                    ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))
        emit_string_wrap!(fb, ctx, Symbol)
    end
    return append_builder!(b, fb)
end

# `ifelse(cond, a, b)` — dart lowers a ConditionalExpression lazily, as an
# if/else (code_generator.dart:2810 visitConditionalExpression); Julia's
# `ifelse` evaluates both operands, so WT emits `select`/`select_t`. Self-contained: compiles all three operands itself, so it
# never depended on the generic arg-push loop. `Base.ifelse` (the generic
# function) and `Core.ifelse` (the builtin) are DIFFERENT objects — the retired
# `is_func(func, :ifelse)` matched either by bare name, so both are keys here.
# L38_no_known_value_substitutions pins this body's two reject messages.
# parity(quarantine: Julia's `ifelse` is a function whose operands are both evaluated — a wasm
# `select`, not dart's lazy ConditionalExpression.)
function _lower_ifelse!(b, fb, ctx, call, idx, args, callee)::Union{InstrBuilder,Nothing}
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
            "ifelse condition did not lower to i32"; idx=idx, detail=call,
            soundness_fatal=true)
    end

    local _ieb = _ctx_builder(ctx, "compile_call")
    # Empty value emission is a compiler error, never permission to select an
    # arbitrary arm or synthesize a zero/null value.
    if isempty(_tv_b.instrs) || isempty(_fv_b.instrs) || isempty(_cv_b.instrs)
        record_unsupported!(ctx, :value_stub,
            "ifelse operand emitted no runtime value"; idx=idx, detail=call,
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
# types.dart:527: is-check, throw on mismatch). Statically-proven casts stay
# pass-through (the common case — inference already narrowed). A runtime check
# emits when the value is a GC ref and the target has a DFS classId range:
# typeId ∈ [low, high] or throw TypeError. Values the discriminator can't see
# (non-$JlBase refs) pass through UNCHECKED (under-check, never wrong-throw).
# Self-contained: emits its own operand through `emit_value!`.
# L57_exact_typeassert_exception pins this body's `_emit_typeerror_throw!` call.
# parity(types.dart:527 emitAsCheck)
function _lower_typeassert!(b, fb, ctx, call, idx, args, callee)::Union{InstrBuilder,Nothing}
    if length(args) >= 1
        local _ta_target = length(args) >= 2 ? (nir_const(args[2]) isa Type ? nir_const(args[2]) :
            args[2] isa NirGlobalRef ? Core.eval(args[2].mod, args[2].name) : nothing) : nothing
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
                    emit_value!(fb, NirLiteral(_te_values[_te_i]), ctx, _te_w;
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
# parity(code_generator.dart:2258 visitInstanceGet): dart resolves an
# instance-member access to ONE target and first tries THAT member's intrinsic
# (intrinsics.dart:607 generateInstanceGetterIntrinsic), whose shape tests run
# in order. WT's four field-access
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

# parity(quarantine: Julia's `DataType.layout` is a host pointer to compile-time layout metadata;
# dart types carry no layout object.)
function _lower_getfield_layout!(b, fb, ctx, call, idx, args)::Union{InstrBuilder,Nothing}
    # P3 gap 450889a9cb7e: getfield(::DataType-literal, :layout) — the layout
    # pointer is compile-time host metadata; its loads are folded in
    # _try_fold_layout_pointerref. Represent the opaque, non-null layout handle
    # by the registered type id + 1 (zero remains C_NULL), never by a fabricated
    # universal pointer value.
    if length(args) >= 2
        local _gf_dt = nir_const(args[1])
        local _gf_fld = nir_const(args[2])
        if _gf_dt isa DataType && _gf_fld === :layout
            i64_const!(fb, Int64(ensure_type_id!(ctx.type_registry, _gf_dt)) + 1)
            return append_builder!(b, fb)
        end
    end
    return nothing
end


function _lower_getfield_signal_read!(b, fb, ctx, call, idx, args)::Union{InstrBuilder,Nothing}
    # Special case for signal read: getfield(Signal, :value) -> global.get
    # This is detected by analyze_signal_captures! and stored in signal_ssa_getters
    # ONLY applies to actual getfield/getproperty(Signal, :value) calls (WasmGlobal pattern)
    # For Therapy.jl closures, signal_ssa_getters maps closure field SSAs - handled in compile_invoke
    is_getfield_value = length(args) >= 2
    if is_getfield_value && haskey(ctx.signal_ssa_getters, idx)
        # Check that this is accessing :value field (WasmGlobal pattern)
        field_ref = args[2]
        field_name = nir_const(field_ref)
        if field_name === :value
            global_idx = ctx.signal_ssa_getters[idx]
            global_get!(fb, global_idx, ctx.mod.globals[global_idx + 1].valtype)
            return append_builder!(b, fb)
        end
    end
    return nothing
end


function _lower_setfield_signal_write!(b, fb, ctx, call, idx, args)::Union{InstrBuilder,Nothing}
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


function _lower_getfield_closure_capture!(b, fb, ctx, call, idx, args)::Union{InstrBuilder,Nothing}
    # Special case for getfield on closure (_1) accessing captured signal fields
    # These produce intermediate SSA values (getter/setter functions)
    # Skip them - the actual read/write happens when the function is invoked
    if length(args) >= 2
        target = args[1]
        field_ref = args[2]
        # Target can be Core.SlotNumber(1) or Core.Argument(1)
        is_closure_self = (target isa NirSlot && target.id == 1) ||
                          (target isa NirArgument && target.n == 1)
        if is_closure_self
            # This is accessing a field of the closure
            field_name = nir_const(field_ref)
            if field_name isa Symbol && haskey(ctx.captured_constant_fields, field_name)
                local _captured_value = ctx.captured_constant_fields[field_name]
                # The canonical pre-emission type query owns Julia→Wasm mapping;
                # root substitutions do not introduce another conversion site.
                local _captured_wasm = static_wasm_type(NirLiteral(_captured_value), ctx)
                emit_value!(fb, NirLiteral(_captured_value), ctx, _captured_wasm;
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


function _lower_getfield_signal_skip!(b, fb, ctx, call, idx, args)::Union{InstrBuilder,Nothing}
    # Skip getfield(CompilableSignal/Setter, :signal) - intermediate step
    # We track this in analyze_signal_captures! but don't need to emit anything
    # IMPORTANT: Only skip for actual CompilableSignal/Setter types, not any struct with a :signal field
    if length(args) >= 2
        field_ref = args[2]
        field_name = nir_const(field_ref)
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


# parity(code_generator.dart:2258 visitInstanceGet)
function _lower_getfield_general!(b, fb, ctx, call, idx, args)::Union{InstrBuilder,Nothing}
    # Special case for getfield/getproperty - struct/tuple field access
    # In newer Julia, obj.field compiles to Base.getproperty(obj, :field)
    # rather than Core.getfield(obj, :field)
    if length(args) >= 2
        obj_arg = args[1]
        field_ref = args[2]
        obj_type = infer_value_type(obj_arg, ctx)   # pre-existing query (the mega-arm relies on it)
        if is_runtime_vararg_tuple_type(obj_type) && !nir_quoted(field_ref)
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
        local _mb_fld = nir_const(field_ref)
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
        field_sym = nir_const(field_ref)

        # Handle getfield(DataType_constant, :flags) — compile-time constant folding.
        # Broadcasting IR uses DataType.flags to check type properties (e.g., isprimitivetype).
        # The DataType is a compile-time constant, so we can emit the flags value directly.
        if field_sym === :flags && nir_const(obj_arg) isa DataType && isdefined(nir_const(obj_arg), :flags)
            flags_val = nir_const(obj_arg).flags
            i32_const!(fb, Int64(flags_val))
            return append_builder!(b, fb)
        end

        if field_sym === :instance && nir_const(obj_arg) isa DataType && nir_const(obj_arg) <: Memory
            # Memory{T}.instance - create an empty array (length 0)
            # Extract element type from Memory{T}
            local mem_T = nir_const(obj_arg)
            elem_type = if mem_T.name.name === :Memory && length(mem_T.parameters) >= 1
                mem_T.parameters[1]
            elseif mem_T.name.name === :GenericMemory && length(mem_T.parameters) >= 2
                mem_T.parameters[2]
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
            field_sym = nir_const(field_ref)
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
            field_sym = nir_const(field_ref)
            # parity(class_info.dart:666 ClassInfoCollector.collect): dart's struct for a
            # class exists before any field read; WT registers lazily, so the read
            # itself registers through the one type chain (a constant Vector read only
            # through .size never reached any other registrar).
            if obj_type isa DataType && isconcretetype(obj_type) && obj_type <: Array
                register_reachable_type!(ctx.mod, ctx.type_registry, obj_type)
            end

            if field_sym === :ref || field_sym === 1
                # :ref is the pair (data, off0): off0 is snapshotted into this read's offset
                # local (allocate_memoryref_offset_locals!), then the data array is pushed.
                local _refb = _ctx_builder(ctx, "compile_call")
                if haskey(ctx.type_registry.structs, obj_type)
                    info = ctx.type_registry.structs[obj_type]
                    if obj_type <: Array
                        haskey(ctx.memoryref_offset_locals, idx) || begin
                            emit_unsupported_stub!(ctx, fb, :unsupported_type,
                                "an Array's :ref read that is not an SSA statement has no local for its element offset";
                                idx=idx, detail=call)
                            return append_builder!(b, fb)
                        end
                        # the Array is read once: its off0, then its data
                        local _ref_arr = allocate_local!(ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
                        emit_value!(_refb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
                        local_tee!(_refb, _ref_arr)
                        struct_get!(_refb, info.wasm_type_idx, array_offset_field_idx(info), I32)
                        local_set!(_refb, ctx.memoryref_offset_locals[idx])
                        local_get!(_refb, _ref_arr)
                    else
                        # Typed arrival when the struct is registered
                        emit_value!(_refb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
                    end
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
               length(obj_type.parameters) >= 2 && obj_type.parameters[1] === UInt8 &&
               obj_type.parameters[2] === String
                local _cu_field0 = nir_const(field_ref)
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
            field_sym = nir_const(field_ref)

            if field_sym === :mem
                emit_memoryref_mem!(fb, ctx, obj_arg)
                return append_builder!(b, fb)
            elseif field_sym === :ptr_or_offset
                _storage_relative_pointer_is_closed(ctx, idx; storage_pointer=true) || begin
                    record_unsupported!(ctx, :unsupported_method,
                        "a MemoryRef's ptr_or_offset escapes storage-relative WasmGC operations";
                        idx=idx, soundness_fatal=true)
                    ctx.last_stmt_was_stub = true
                    return append_builder!(b, fb)
                end
                # P4-stdlib (SHA update!): the target pointer value is a
                # storage-relative byte offset from the start of the ref's Memory:
                # off0 * elsize, off0 read from the pair channel.
                local _poo_el = obj_type isa DataType && length(obj_type.parameters) >= 1 ?
                    (obj_type.name.name === :GenericMemoryRef && length(obj_type.parameters) >= 2 ?
                     obj_type.parameters[2] : obj_type.parameters[1]) : nothing
                local _poob = _ctx_builder(ctx, "compile_call")
                if first(_memoryref_source(ctx, obj_arg)) !== :zero
                    _poo_el isa Type || error("a MemoryRef's ptr_or_offset needs the ref's element type; $obj_type has none")
                    # Julia's element stride: sizeof for an isbits element, 8 (a boxed
                    # slot, Base.aligned_sizeof(Any)) for a reference element — the same
                    # rule jl_genericmemory_copyto's lowering divides by
                    local _poo_sz = memory_element_stride(_poo_el)
                    emit_memoryref_position!(_poob, ctx, obj_arg)
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
            field_sym = nir_const(field_ref)

            if field_sym === :length
                # Return array length
                local _mem_arr = get_array_type!(ctx.mod, ctx.type_registry, eltype(obj_type))
                emit_value!(fb, obj_arg, ctx, ConcreteRef(UInt32(_mem_arr), true))
                array_len!(fb)
                num!(fb, Opcode.I64_EXTEND_I32_S)
                return append_builder!(b, fb)
            elseif field_sym === :ptr
                # The storage-relative base offset (zero), sound only while the
                # pointer stays inside that algebra or is compared for identity.
                _storage_relative_pointer_is_closed(ctx, idx; storage_pointer=true) || begin
                    record_unsupported!(ctx, :unsupported_method,
                        "a Memory's ptr escapes storage-relative WasmGC operations";
                        idx=idx, soundness_fatal=true)
                    ctx.last_stmt_was_stub = true
                    return append_builder!(b, fb)
                end
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

                field_sym = nir_const(field_ref)

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

            field_sym = nir_const(field_ref)

            # getfield(x, i::Integer) — positional access (gap
            # 8f5c0002bb71). Julia field order == info.field_names order.
            field_idx = field_sym isa Integer ?
                (1 <= field_sym <= length(info.field_names) ? Int(field_sym) : nothing) :
                findfirst(==(field_sym), info.field_names)
            if field_idx !== nothing
                local _sfgb = _ctx_builder(ctx, "compile_call")
                set_context!(_sfgb, first(string(call), 120))
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
                field_idx = if nir_const(field_ref) isa Integer
                    nir_const(field_ref)
                elseif field_ref isa NirSSA || field_ref isa NirArgument
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


# parity(code_generator.dart:2434 visitInstanceSet)
function _lower_setfield_general!(b, fb, ctx, call, idx, args)::Union{InstrBuilder,Nothing}
    # Special case for setfield!/setproperty! - mutable struct field assignment
    # Also handles WasmGlobal (:value -> global.set)
    # In newer Julia, obj.field = val compiles to Base.setproperty!(obj, :field, val)
    if length(args) >= 3
        obj_arg = args[1]
        field_ref = args[2]
        value_arg = args[3]
        obj_type = infer_value_type(obj_arg, ctx)

        field_sym = nir_const(field_ref)

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
            field_sym = nir_const(field_ref)
            if field_sym === :ref && haskey(ctx.type_registry.structs, obj_type)
                # setfield!(vector, :ref, new_memref) — the ref's Memory into the data field
                # (field 1 after the Object header) and its off0 into the offset field.
                value_has_local = false
                if value_arg isa NirSSA && haskey(ctx.ssa_locals, value_arg.id)
                    value_has_local = true
                elseif value_arg isa NirArgument
                    value_has_local = true
                end
                if value_has_local || first(_memoryref_source(ctx, value_arg)) === :indexed
                    info = ctx.type_registry.structs[obj_type]
                    value_type = infer_value_type(value_arg, ctx)
                    local _vr_def = ctx.mod.types[info.wasm_type_idx + 1]
                    local _vr_expected = _vr_def.fields[wasm_field_idx(info, 1) + 1].valtype
                    temp_local = allocate_local!(ctx, _vr_expected)
                    local _vrb = _ctx_builder(ctx, "compile_call")
                    emit_memoryref_mem!(_vrb, ctx, value_arg, _vr_expected;
                                from_julia=(value_type isa Type && isconcretetype(value_type)) ? value_type : nothing)
                    local_set!(_vrb, temp_local)
                    emit_value!(_vrb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
                    # If obj_arg's local is structref, insert ref.cast null before struct_set
                                        emit_ref_cast_if_structref!(_vrb, obj_arg, info.wasm_type_idx, ctx)
                    local_get!(_vrb, temp_local)
                    struct_set!(_vrb, info.wasm_type_idx, wasm_field_idx(info, 1), AnyRef)
                    emit_value!(_vrb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
                    emit_ref_cast_if_structref!(_vrb, obj_arg, info.wasm_type_idx, ctx)
                    emit_memoryref_offset!(_vrb, ctx, value_arg)
                    struct_set!(_vrb, info.wasm_type_idx, array_offset_field_idx(info), I32)
                    # setfield! returns the ref it stored: as one value, its Memory, and only
                    # when nothing reads a ref whose offset is not provably 0
                    if !memoryref_offset_is_zero(ctx, value_arg) &&
                       any(j -> j != idx && nir_refs_ssa(ctx.nir[j].node, idx), eachindex(ctx.nir))
                        emit_unsupported_stub!(ctx, _vrb, :unsupported_type,
                            "the result of setfield!(::Array, :ref, ref) is read, and the ref's element offset is not provably 0";
                            idx=idx, detail=value_arg)
                    else
                        local_get!(_vrb, temp_local)
                    end
                    append_builder!(fb, _vrb)
                    return append_builder!(b, fb)
                end
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
                field_sym = nir_const(field_ref)

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
                    local _sf_val = is_nothing_value(value_arg, ctx) ? NirLiteral(nothing) : value_arg
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
function _run_guards!(guards, b, fb, ctx, call, idx, args)::Union{InstrBuilder,Nothing}
    for g in guards
        r = g(b, fb, ctx, call, idx, args)
        r === nothing || return r
    end
    return nothing
end

# `Core.getfield` (=== `Base.getfield`, measured): the two raw-identity guards
# are its own, so they run here and nowhere else.
# parity(code_generator.dart:2258 visitInstanceGet)
_lower_getfield!(b, fb, ctx, call, idx, args, callee)::Union{InstrBuilder,Nothing} =
    _run_guards!((_lower_getfield_layout!, _lower_getfield_signal_read!,
                  _lower_getfield_closure_capture!, _lower_getfield_signal_skip!,
                  _lower_getfield_general!), b, fb, ctx, call, idx, args)

# `Base.getproperty` / `Core.getproperty` (DIFFERENT objects, measured): the
# raw-identity guards never matched `getproperty`, so they are absent here.
_lower_getproperty!(b, fb, ctx, call, idx, args, callee)::Union{InstrBuilder,Nothing} =
    _run_guards!((_lower_getfield_layout!, _lower_getfield_signal_read!,
                  _lower_getfield_general!), b, fb, ctx, call, idx, args)

# parity(code_generator.dart:2434 visitInstanceSet)
_lower_setfield!(b, fb, ctx, call, idx, args, callee)::Union{InstrBuilder,Nothing} =
    _run_guards!((_lower_setfield_signal_write!, _lower_setfield_general!),
                 b, fb, ctx, call, idx, args)

# ---- The self-contained operator entries -----------------------------------
# parity(intrinsics.dart:995 `_binaryOperatorMap` / :1194 generateStaticIntrinsic,
# whose intrinsics translate their own arguments): each of these emits its OWN operands through `emit_call_operand!`
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

# `===` / `!==`: THE egal lowering, `emit_egal!` (calls.jl); `!==` is its negation.
# parity(intrinsics.dart:1409 StaticIntrinsic.identical)
function _lower_egal!(b, fb, ctx, call, idx, args, callee)::Union{InstrBuilder,Nothing}
    length(args) == 2 || return nothing
    # Storage pointers first (Base.dataids' `UInt(m.ptr)`, `pointer(A) == pointer(B)`):
    # WasmGC has no addresses, so two are equal exactly when they share a backing object
    # and offset; against NULL or an objectid Julia never makes them equal.
    local backing_a = _storage_pointer_backing(ctx, args[1])
    local backing_b = _storage_pointer_backing(ctx, args[2])
    if backing_a !== nothing && backing_b !== nothing
        _emit_storage_pointer_egal!(fb, ctx, args[1], backing_a, args[2], backing_b)
    elseif (backing_a !== nothing && _is_never_a_storage_pointer(ctx, args[2])) ||
           (backing_b !== nothing && _is_never_a_storage_pointer(ctx, args[1]))
        i32_const!(fb, 0)
    else
        emit_egal!(fb, ctx, args[1], args[2])
    end
    callee === Core.:(!==) && num!(fb, Opcode.I32_EQZ)
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

function _lower_operator!(b, fb, ctx, call, idx, args, callee)::Union{InstrBuilder,Nothing}
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

    # String/Symbol `*` is CONCATENATION, not arithmetic: a `call *` of two proven
    # String/Symbol operands would otherwise fall into the numeric branch and emit
    # i64.mul on two string refs (the E-003 island's fn#107 validation failure).
    # It lowers through compile_string_concat_many_b, the one N-way concatenation
    # builder; the operands already pushed on `fb` are discarded by starting a
    # fresh fragment, which the builder fills from the operands themselves.
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

    # parity(translator.dart:1597 Translator.convertType): the symmetric RESULT
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
                        idx=idx, detail=call)
                emit_classid_box!(fb, ctx, is_32bit ? I32 : I64, _boxed_result_jt)
            end
        end
    end
    return append_builder!(b, fb)
end

# `isa(value, T)` — type checking for Union discrimination. A constant `T` (a
# Type literal or a bound global naming one) is skipped by emit_call_operands!'s
# type-operand rule, so only the value is pushed, and `_compile_call_isa`'s
# `_sub_builder(fb, ctx, "_compile_call_isa", 1)` seeds that one operand. A runtime
# `T` is pushed as a second operand and reaches `_compile_call_isa` with
# `check_type === nothing`.
# parity(code_generator.dart:3159 visitIsExpression)
function _lower_isa!(b, fb, ctx, call, idx, args, callee)::Union{InstrBuilder,Nothing}
    length(args) >= 2 || return nothing
    emit_call_operands!(fb, ctx, args)
    _compile_call_isa(args, fb, ctx)
    return append_builder!(b, fb)
end

# ---- Registry population ---------------------------------------------------
# One entry per builtin identity. Aliases (e.g. isvisible/_closed_world_isvisible)
# map to the SAME lowering function, matching dart's KernelNodes resolving
# multiple call shapes to one intrinsic.

_register_builtin!(Core.invoke_in_world, _lower_invoke_in_world!)
_register_builtin!(Base.isdefinedglobal, _lower_isdefinedglobal!)
_register_builtin!(Base.isvisible, _lower_isvisible!)
_register_builtin!(_closed_world_isvisible, _lower_isvisible!)
_register_builtin!(Base.check_world_bounded, _lower_check_world_bounded!)
_register_builtin!(_closed_world_type_bounds, _lower_check_world_bounded!)

_register_builtin!(Core.getglobal, _lower_getglobal!)
# `Core.sizeof` (the builtin `code_typed` actually resolves calls to) and
# `Base.sizeof` (the generic function) are DIFFERENT objects — `is_func`
# matched either by bare name, so both keys route to the same lowering.
_register_builtin!(Core.sizeof, _lower_sizeof!)
_register_builtin!(Base.sizeof, _lower_sizeof!)
_register_builtin!(Base.ncodeunits, _lower_ncodeunits!)
_register_builtin!(Base.length, _lower_length!)
_register_builtin!(Core.nfields, _lower_nfields!)
_register_builtin!(Core.memoryref_isassigned, _lower_memoryref_isassigned!)
_register_builtin!(Core.memoryrefget, _lower_memoryrefget!)
_register_builtin!(Core.memoryrefoffset, _lower_memoryrefoffset!)
_register_builtin!(Core.memoryrefset!, _lower_memoryrefset!)
_register_builtin!(Core.memorynew, _lower_memorynew!)
_register_builtin!(Core.memoryref, _lower_memoryref!)
_register_builtin!(Core.memoryrefnew, _lower_memoryrefnew!)
_register_builtin!(Core.tuple, _lower_tuple!)
_register_builtin!(Core._expr, _lower_expr!)
_register_builtin!(Symbol, _lower_symbol!)
_register_builtin!(Core.donotdelete, _lower_donotdelete!)
_register_builtin!(Core.compilerbarrier, _lower_compilerbarrier!)
_register_builtin!(Core.apply_type, _lower_apply_type!)
_register_builtin!(Core.typeof, _lower_typeof!)
_register_builtin!(Core.:(===), _lower_egal!)
_register_builtin!(Core.:(!==), _lower_egal!)
_register_builtin!(Core.isa, _lower_isa!)                  # === Base.isa
_register_builtin!(+, _lower_operator!)
_register_builtin!(-, _lower_operator!)
_register_builtin!(*, _lower_operator!)
_register_builtin!(Core.ifelse, _lower_ifelse!)
_register_builtin!(Base.ifelse, _lower_ifelse!)
_register_builtin!(Core.typeassert, _lower_typeassert!)
_register_builtin!(Core.getfield, _lower_getfield!)        # === Base.getfield
# `Core.getproperty` is NOT a key: it IS `Core.getfield` (measured), and
# registering it would clobber that entry's two raw-identity guards. Same for
# `Core.setproperty!` === `Core.setfield!`. `Base.getproperty` /
# `Base.setproperty!` are genuinely distinct objects.
_register_builtin!(Base.getproperty, _lower_getproperty!)
_register_builtin!(Core.setfield!, _lower_setfield!)       # === Base.setfield!
_register_builtin!(Base.setproperty!, _lower_setfield!)
