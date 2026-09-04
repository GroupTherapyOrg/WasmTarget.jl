# Only receiver-free display calls belong to WT's host-console bridge.  Julia's
# `print(io, ...)` / `show(io, ...)` methods are formatting machinery and must be
# resolved and compiled like ordinary calls.
function _invoke_has_explicit_io(param_types)::Bool
    (param_types === nothing || isempty(param_types)) && return false
    first_type = try
        Core.Compiler.widenconst(first(param_types))
    catch
        Any
    end
    return first_type isa Type && first_type <: IO
end

# parity(translator.dart:1597 Translator.convertType): emit a string-op ARG through the funnel — classed strings adjust to
# their DATA array (op contract: these positions are strings; no type re-query).
function _emit_str_arg!(b::InstrBuilder, arg, ctx::AbstractCompilationContext, str_type_idx)
    tracing(:strarg) && println(stderr, "STRARG ", repr(arg), " :: ", typeof(arg))
    emit_value!(b, arg, ctx, ConcreteRef(UInt32(str_type_idx), true))
    return b
end
# ============================================================================
# INVOKE_INTRINSICS — Method-keyed intrinsic registry.
#
# parity(intrinsics.dart:26-64,:103+ MemberIntrinsic/StaticIntrinsic; `_lookup`
# :75-100/:401-428): dart resolves each intrinsic callee ONCE to a stable
# Kernel Reference identity and keys an enum on it — unknown ⇒ `throw
# 'Unhandled …'`. WT's analogue is the `Method` already sitting in `mi.def`
# (compile_invoke!'s `meth`, resolved at the top of the big `if mi isa
# Core.MethodInstance` block): a `Method` object is Julia's own interned,
# stable identity for "this exact overload" — the same role dart's
# KernelNodes reference plays. It is stable for the life of this Julia
# session (recompiling the SAME top-level method definition preserves object
# identity via the method table), which is the only stability this registry
# needs — one compiler invocation never crosses a world-age boundary mid-run.
# `(module, name, signature)` was considered and rejected: it is strictly
# weaker information than the Method object it would be reconstructed from,
# with no compensating benefit here.
#
# Populated ONCE, lazily, on first use (`_build_invoke_intrinsics!`) from a
# static list of `methods(f)` calls — never rescanned per invoke.
#
# `str_hash`/`str_len`/`repeat`/`lpad`/`rpad` are deliberately ABSENT: they are
# ordinary Julia functions (or, for `repeat(::String,::Int)`, an
# `@overlay WASM_METHOD_TABLE` body) that the generic cross-call/devirtualized
# path already compiles correctly — adding a redundant registry entry would be
# a second producer for the same op, exactly what L105-style locks forbid.
# ============================================================================

"""
    InvokeIntrinsicEntry

`mode` is `:append` — the builder is a CONTINUATION that assumes its inputs
are already on `fb`'s stack from the ordinary argument pre-push loop (the
only entry using this today, `isascii`, is verified to compile correctly this
way) — or `:standalone` — the builder pushes every input itself via
`emit_value!`/`_emit_str_arg!` and is a complete, self-contained replacement
for `fb`.

A builder may DECLINE a call it is registered for by returning `nothing` —
used when one Method covers call shapes only SOME of which this entry
handles (an arity/literal-value guard the Method's static signature alone
cannot express, e.g. `Base.kwerr`'s `length(args) == 2`). On decline,
`compile_invoke!`'s consult falls through to the terminal unsupported-method
reject, exactly as a pre-migration bare-Symbol name-guard miss did.
"""
struct InvokeIntrinsicEntry
    fn::Function     # :append → (args, ctx) -> InstrBuilder (fragment); :standalone → (args, ctx, idx, expr) -> InstrBuilder (whole result)
    mode::Symbol      # :append | :standalone
end

const INVOKE_INTRINSICS = Dict{Method,InvokeIntrinsicEntry}()

"""Register every `methods(f)` (optionally narrowed to `argtypes`) under `entry` — the
Method IS the identity dart's `_lookup` resolves to, so an overload set collapses to
one registry lookup exactly like dart's enum keys on one Reference each."""
function _register_invoke_intrinsic!(f, entry::InvokeIntrinsicEntry; argtypes=nothing)
    ms = argtypes === nothing ? methods(f) : methods(f, argtypes)
    for m in ms
        INVOKE_INTRINSICS[m] = entry
    end
    return nothing
end

# ---- :standalone builders (self-contained; push every input themselves) ----

"""str_char(s,i) -> Int32. REWRITTEN standalone (the pre-migration inline arm
assumed its string+index were already on `fb`'s stack via the continuation
convention; that convention is unsound for a freshly-built, unseeded
`InstrBuilder` — confirmed by the SAME crash `arr_get`/`arr_len` hit before
this migration, `test/probe_bytes.jl`'s wt_arr_get discovery). Push both
operands explicitly through the funnel, then the original post-push logic."""
function _invoke_str_char_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    bchr = _ctx_builder(ctx, "compile_invoke")
    _emit_str_arg!(bchr, args[1], ctx, str_type_idx)
    emit_value!(bchr, args[2], ctx, I32)   # funnel: I64 args narrow via convert_type!'s numeric ladder
    i32_const!(bchr, 1)
    num!(bchr, Opcode.I32_SUB)  # index - 1 for 0-based
    array_get!(bchr, str_type_idx, I32; signed=false)
    return bchr
end

"""str_setchar!(s,i,c) -> Nothing. Moved verbatim (already self-contained)."""
function _invoke_str_setchar_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    bsc = _ctx_builder(ctx, "compile_invoke")
    emit_value!(bsc, args[1], ctx, ConcreteRef(UInt32(str_type_idx), true))
    emit_value!(bsc, args[2], ctx, I32)
    i32_const!(bsc, 1)
    num!(bsc, Opcode.I32_SUB)
    emit_value!(bsc, args[3], ctx, I32)
    array_set!(bsc, str_type_idx, I32)
    return bsc
end

"""str_new(len) -> String. REWRITTEN standalone (same continuation-soundness
issue as str_char — see its docstring)."""
function _invoke_str_new_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    bnew = _ctx_builder(ctx, "compile_invoke")
    emit_value!(bnew, args[1], ctx, I32)
    array_new_default!(bnew, str_type_idx)
    return bnew
end

"""str_copy(src,src_pos,dst,dst_pos,len) -> Nothing. Moved verbatim (already
self-contained)."""
function _invoke_str_copy_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    bcp = _ctx_builder(ctx, "compile_invoke")
    emit_value!(bcp, args[3], ctx, ConcreteRef(UInt32(str_type_idx), true))
    emit_value!(bcp, args[4], ctx, I32)
    i32_const!(bcp, 1)
    num!(bcp, Opcode.I32_SUB)
    emit_value!(bcp, args[1], ctx, ConcreteRef(UInt32(str_type_idx), true))
    emit_value!(bcp, args[2], ctx, I32)
    i32_const!(bcp, 1)
    num!(bcp, Opcode.I32_SUB)
    emit_value!(bcp, args[5], ctx, I32)
    array_copy!(bcp, str_type_idx, str_type_idx)
    return bcp
end

"""str_substr(s,start,len) -> String. Moved verbatim (already self-contained;
uses caller scratch locals, unchanged from the pre-migration arm)."""
function _invoke_str_substr_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    ctx.scratch_locals === nothing &&
        error("String operations require scratch locals but none were allocated")
    result_local, src_local, _, _, _ = ctx.scratch_locals
    bss = _ctx_builder(ctx, "compile_invoke")
    emit_value!(bss, args[1], ctx, ConcreteRef(UInt32(str_type_idx), true))
    local_set!(bss, src_local)
    emit_value!(bss, args[3], ctx, I32)
    array_new_default!(bss, str_type_idx)
    local_set!(bss, result_local)
    local_get!(bss, result_local)
    i32_const!(bss, 0)
    local_get!(bss, src_local)
    emit_value!(bss, args[2], ctx, I32)
    i32_const!(bss, 1)
    num!(bss, Opcode.I32_SUB)
    emit_value!(bss, args[3], ctx, I32)
    array_copy!(bss, str_type_idx, str_type_idx)
    local_get!(bss, result_local)
    emit_string_wrap!(bss, ctx)
    return bss
end

"""arr_new(Type, len) -> Vector{Type}. Moved verbatim (already self-contained)."""
function _invoke_arr_new_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    type_arg = args[1]
    elem_type = if type_arg isa Core.SSAValue
        ctx.ssa_types[type_arg.id]
    elseif type_arg isa GlobalRef
        getfield(type_arg.mod, type_arg.name)
    elseif type_arg isa Type
        type_arg
    else
        Int32
    end
    arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
    ban = _ctx_builder(ctx, "compile_invoke")
    emit_value!(ban, args[2], ctx, I32)
    array_new_default!(ban, arr_type_idx)
    return ban
end

"""arr_get(arr,i) -> T. REWRITTEN standalone (same continuation-soundness
issue as str_char — confirmed broken pre-migration: StackImbalanceError
underflow, never previously exercised by any test)."""
function _invoke_arr_get_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    arr_type = infer_value_type(args[1], ctx)
    elem_type = eltype(arr_type)
    arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
    bget = _ctx_builder(ctx, "compile_invoke")
    emit_value!(bget, args[1], ctx, ConcreteRef(UInt32(arr_type_idx), true))
    emit_value!(bget, args[2], ctx, I32)
    i32_const!(bget, 1)
    num!(bget, Opcode.I32_SUB)
    array_get!(bget, arr_type_idx, I32; signed=packed_array_signedness(elem_type))
    return bget
end

"""arr_set!(arr,i,val) -> Nothing. Moved verbatim (already self-contained)."""
function _invoke_arr_set_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    arr_type = infer_value_type(args[1], ctx)
    elem_type = eltype(arr_type)
    arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
    bas = _ctx_builder(ctx, "compile_invoke")
    local _arrset_elem_w = get_concrete_wasm_type(elem_type, ctx.mod, ctx.type_registry)
    local _arrset_elem_w2 = _arrset_elem_w isa WasmValType ? _arrset_elem_w : AnyRef
    emit_value!(bas, args[1], ctx, ConcreteRef(UInt32(arr_type_idx), true))
    emit_value!(bas, args[2], ctx, I32)
    i32_const!(bas, 1)
    num!(bas, Opcode.I32_SUB)
    local _as_b = _compile_value_b(args[3], ctx)
    local val_ty = isempty(_as_b.v.stack) ? nothing : _as_b.v.stack[end]
    if elem_type === Any
        if val_ty === I64 || val_ty === I32 || val_ty === F64 || val_ty === F32
            emit_numeric_to_externref!(bas, args[3], val_ty, ctx)
        else
            append_builder!(bas, _as_b)
            val_ty === ExternRef || maybe_wrap_closure!(bas, ctx, infer_value_type(args[3], ctx))
            val_ty === ExternRef || extern_convert_any!(bas)
        end
    else
        append_builder!(bas, _as_b)
    end
    array_set!(bas, arr_type_idx, _arrset_elem_w2)
    return bas
end

"""arr_len(arr) -> Int32. REWRITTEN standalone — the pre-migration arm did not
even compute the array's wasm type (it relied purely on continuation), which
is the same unsound assumption `arr_get` made; confirmed broken pre-migration
the same way."""
function _invoke_arr_len_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    arr_type = infer_value_type(args[1], ctx)
    elem_type = eltype(arr_type)
    arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
    blen3 = _ctx_builder(ctx, "compile_invoke")
    emit_value!(blen3, args[1], ctx, ConcreteRef(UInt32(arr_type_idx), true))
    array_len!(blen3)
    return blen3
end

"""isascii(s::String) / isascii(cu::AbstractVector{<:Integer}) — the CodeUnits
case from `isascii(codeunits(s))`. Moved verbatim; this is the one entry using
`:append` mode — confirmed (probe `wt_isascii_codeunits`) to compile correctly
as a continuation of `fb`'s pre-pushed argument."""
function _invoke_isascii_b(args, ctx::AbstractCompilationContext)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    arg_type = infer_value_type(args[1], ctx)
    basc = _ctx_builder(ctx, "compile_invoke")
    if arg_type !== String && arg_type !== Symbol
        if haskey(ctx.type_registry.structs, arg_type)
            cu_info = ctx.type_registry.structs[arg_type]
            struct_get!(basc, cu_info.wasm_type_idx, wasm_field_idx(cu_info, 1), I32)
        end
    end
    str_arr_type = ConcreteRef(str_type_idx, true)
    str_local = allocate_local!(ctx, str_arr_type)
    len_local = allocate_local!(ctx, I32)
    accum_local = allocate_local!(ctx, I32)
    i_local = allocate_local!(ctx, I32)
    local_set!(basc, str_local)
    local_get!(basc, str_local)
    array_len!(basc)
    local_set!(basc, len_local)
    i32_const!(basc, 0)
    local_set!(basc, accum_local)
    i32_const!(basc, 0)
    local_set!(basc, i_local)
    done_label = block!(basc, 0x40)
    loop_label = loop!(basc, 0x40)
    local_get!(basc, i_local)
    local_get!(basc, len_local)
    num!(basc, Opcode.I32_GE_S)
    br_if!(basc, done_label)
    local_get!(basc, accum_local)
    local_get!(basc, str_local)
    local_get!(basc, i_local)
    array_get!(basc, str_type_idx, I32; signed=false)
    num!(basc, Opcode.I32_OR)
    local_set!(basc, accum_local)
    local_get!(basc, i_local)
    i32_const!(basc, 1)
    num!(basc, Opcode.I32_ADD)
    local_set!(basc, i_local)
    br!(basc, loop_label)
    end_block!(basc)
    end_block!(basc)
    local_get!(basc, accum_local)
    i32_const!(basc, 0x80)
    num!(basc, Opcode.I32_LT_U)
    return basc
end

"""==(a::String,b::String). Moved verbatim (already self-contained; delegates
to the shared compile_string_equal_b core, unchanged)."""
_invoke_string_eq_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder =
    compile_string_equal_b(args[1], args[2], ctx)

"""SubString(s) / SubString(s,start,stop). Moved verbatim (already
self-contained; all 7 real `SubString` constructor methods share this one
body, matching the pre-migration arm's unconditional name-based dispatch)."""
function _invoke_substring_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    bsub2 = _ctx_builder(ctx, "compile_invoke")
    if length(args) >= 3
        str_arg = args[1]
        start_arg = args[2]
        stop_arg = args[3]
        local _substr_info = register_struct_type!(ctx.mod, ctx.type_registry, SubString{String})
        local _substr_def = ctx.mod.types[_substr_info.wasm_type_idx + 1]
        local _substr_string_w = _substr_def.fields[wasm_field_idx(_substr_info, 1) + 1].valtype
        emit_struct_prefix!(bsub2, ctx.type_registry, SubString{String}, _substr_info)
        emit_value!(bsub2, str_arg, ctx, _substr_string_w; from_julia=String)
        emit_value!(bsub2, start_arg, ctx, I64)
        i64_const!(bsub2, 1)
        num!(bsub2, Opcode.I64_SUB)
        emit_value!(bsub2, stop_arg, ctx, I64)
        emit_value!(bsub2, start_arg, ctx, I64)
        num!(bsub2, Opcode.I64_SUB)
        i64_const!(bsub2, 1)
        num!(bsub2, Opcode.I64_ADD)
        substr_wasm = get_concrete_wasm_type(SubString{String}, ctx.mod, ctx.type_registry)
        if substr_wasm isa ConcreteRef
            struct_new!(bsub2, substr_wasm.type_idx)
        end
    elseif length(args) >= 1
        str_arg = args[1]
        local _substr_info = register_struct_type!(ctx.mod, ctx.type_registry, SubString{String})
        local _substr_def = ctx.mod.types[_substr_info.wasm_type_idx + 1]
        local _substr_string_w = _substr_def.fields[wasm_field_idx(_substr_info, 1) + 1].valtype
        emit_struct_prefix!(bsub2, ctx.type_registry, SubString{String}, _substr_info)
        emit_value!(bsub2, str_arg, ctx, _substr_string_w; from_julia=String)
        i64_const!(bsub2, 0)
        emit_value!(bsub2, str_arg, ctx,
                    ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))
        array_len!(bsub2)
        coerce_stack_top!(bsub2, I64, ctx)   # funnel: array.len's i32 → the field's i64
        substr_wasm = get_concrete_wasm_type(SubString{String}, ctx.mod, ctx.type_registry)
        if substr_wasm isa ConcreteRef
            struct_new!(bsub2, substr_wasm.type_idx)
        end
    end
    return bsub2
end

"""Base.array_subpadding(T1,T2) — compile-time SimpleVector/Bool constant when
both args are literal `Type`s in the IR (P4-stdlib radix sort guard). Moved
verbatim; the constant-ness guard is per-callsite, not per-Method, so it is
preserved as an internal check with the SAME terminal-unsupported fallback the
old ladder's final `else` arm used when the guard failed."""
function _invoke_array_subpadding_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    bsub = _ctx_builder(ctx, "compile_invoke")
    if length(args) == 2 && args[1] isa Type && args[2] isa Type
        i32_const!(bsub, Base.array_subpadding(args[1], args[2]) ? 1 : 0)
    else
        record_unsupported!(ctx, :unsupported_method, "unknown invoke target (no handler arm)"; idx=idx, detail=expr)
        unreachable!(bsub)
        ctx.last_stmt_was_stub = true
    end
    return bsub
end

"""Base.unalias(dest,src) — identity in WasmGC (every array.new is a distinct
GC object; aliasing is impossible). Moved verbatim (all 3 real `unalias`
methods share this one body, matching the pre-migration arm's unconditional
name-based dispatch); `args[2]` replaces the original `expr.args[4]` — the
SAME value (`args = expr.args[3:end]`, so `args[2] === expr.args[4]`)."""
function _invoke_unalias_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    bua = _ctx_builder(ctx, "compile_invoke")
    src_arg = args[2]
    emit_value!(bua, src_arg, ctx, static_wasm_type(src_arg, ctx))
    return bua
end


# ---- :standalone builders migrated off the name === :sym ladder (R20) ----
# Each docstring says whether the body is a verbatim move, a verbatim move with a
# widened/narrowed registration (Method identity now does work the old runtime name
# check did), or a genuine rewrite (and why). "DECLINES" means the builder returns
# `nothing` for a call shape this Method covers but this entry does not handle;
# the ladder then falls through to the terminal unsupported-method reject.

_invoke_is_32bit_arith(@nospecialize(arg_type))::Bool =
    arg_type === Int32 || arg_type === UInt32 || arg_type === Bool || arg_type === Char ||
    arg_type === Int16 || arg_type === UInt16 || arg_type === Int8 || arg_type === UInt8 ||
    (arg_type isa Type && isprimitivetype(arg_type) && sizeof(arg_type) <= 4)

"""The five arithmetic/length invoke intrinsics below (_invoke_add_b/_invoke_sub_b/
_invoke_neg_b/_invoke_mul_b/_invoke_length_str_b) all key off `args[1]`'s inferred
Julia type — ONE shared read, same as the pre-migration ladder's single top-of-
function `arg_type = infer_value_type(args[1], ctx)` these Methods all used to reuse
via closure capture (R3: infer_value_type callers are counted per call SITE, not per
invocation — a shared helper keeps this at one site instead of five)."""
_invoke_operand1_type(args, ctx::AbstractCompilationContext) = infer_value_type(args[1], ctx)

"""parity(translator.dart:1621 Translator.convertType): numeric arith result → ref-typed
SSA local ⇒ box through THE one producer (emit_classid_box!). Shared by the +/-/*
invoke intrinsics below — each was compile_invoke!'s local `_f3_result_box!` closure
before this migration; unchanged logic, just parameterized instead of captured."""
function _invoke_box_arith_result!(b::InstrBuilder, ctx::AbstractCompilationContext, idx::Int, expr::Expr,
                                   @nospecialize(arg_type), is_32bit::Bool)
    dl = get(ctx.ssa_locals, idx, nothing)
    dl === nothing && return nothing
    doff = dl - ctx.n_params
    (doff >= 0 && doff < length(ctx.locals) && ctx.locals[doff + 1] === AnyRef) || return nothing
    rbx = _ctx_builder(ctx, "compile_invoke")
    boxed_result_jt = get(ctx.ssa_types, idx, arg_type)
    (boxed_result_jt isa Type && isconcretetype(boxed_result_jt)) ||
        record_unsupported!(ctx, :unsupported_type,
            "boxed invoke result lacks a concrete Julia source type"; idx=idx, detail=expr)
    emit_classid_box!(rbx, ctx, is_32bit ? I32 : I64, boxed_result_jt)
    append_builder!(b, rbx)
    return nothing
end

"""+(x::T,y::T) where T<:BitInteger — Base arithmetic invoked directly (inference did
not intrinsify it down to a raw add_int :call). REWRITTEN standalone: pushes both
operands fresh (the old body assumed they were already on `fb` from the pre-push
loop) and routes the opcode choice THROUGH intrinsics_table.jl's emit_intrinsic_binop!
— the SAME table's (I32/I64,:add_int) entries — instead of re-deriving it, so there is
one producer per op (dev/PARITY_MASTER L104's spirit). The bare `:add_int`/`:sub_int`/
`:mul_int` disjuncts the pre-migration guard also checked are DROPPED: an intrinsic's
own Method object always has `.name === :IntrinsicFunction` (confirmed on Julia 1.12
and 1.13 — `which(Core.Intrinsics.add_int, (Int,Int))`), never `:add_int`, so those
disjuncts could never fire via `mi.def isa Method`; direct intrinsic calls are `:call`
expressions handled in calls.jl, not `:invoke` reaching this file at all."""
function _invoke_add_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    arg_type = _invoke_operand1_type(args, ctx)
    is_32bit = _invoke_is_32bit_arith(arg_type)
    wt = is_32bit ? I32 : I64
    badd = _ctx_builder(ctx, "compile_invoke")
    emit_value!(badd, args[1], ctx, wt)
    emit_value!(badd, args[2], ctx, wt)
    emit_intrinsic_binop!(badd, wt, wt, :add_int)
    _invoke_box_arith_result!(badd, ctx, idx, expr, arg_type, is_32bit)
    return badd
end

"""-(x::T,y::T) where T<:BitInteger — binary subtraction. REWRITTEN standalone, same
shape and rationale as _invoke_add_b (routes through emit_intrinsic_binop!)."""
function _invoke_sub_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    arg_type = _invoke_operand1_type(args, ctx)
    is_32bit = _invoke_is_32bit_arith(arg_type)
    wt = is_32bit ? I32 : I64
    bsub3 = _ctx_builder(ctx, "compile_invoke")
    emit_value!(bsub3, args[1], ctx, wt)
    emit_value!(bsub3, args[2], ctx, wt)
    emit_intrinsic_binop!(bsub3, wt, wt, :sub_int)
    _invoke_box_arith_result!(bsub3, ctx, idx, expr, arg_type, is_32bit)
    return bsub3
end

"""-(x::T) where T<:BitInteger — unary negation, lowered as `0 - x` (unchanged from
the pre-migration arm; the unary entry in intrinsics_table.jl's INTRINSIC_UNOPS uses
`-1 * x` instead — a DIFFERENT Method's shape, not this one, so it is not reused here).
REWRITTEN standalone: a distinct Method from the 2-arg `-` above (different arity ⇒
different Method object), registered separately."""
function _invoke_neg_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    arg_type = _invoke_operand1_type(args, ctx)
    is_32bit = _invoke_is_32bit_arith(arg_type)
    wt = is_32bit ? I32 : I64
    bneg = _ctx_builder(ctx, "compile_invoke")
    is_32bit ? i32_const!(bneg, 0) : i64_const!(bneg, 0)
    emit_value!(bneg, args[1], ctx, wt)
    emit_intrinsic_binop!(bneg, wt, wt, :sub_int)
    _invoke_box_arith_result!(bneg, ctx, idx, expr, arg_type, is_32bit)
    return bneg
end

"""*(x::T,y::T) where T<:BitInteger — numeric multiply. REWRITTEN standalone, same
shape as _invoke_add_b. The pre-migration arm never boxed this result (no
`_f3_result_box!()` call in the numeric-mul arm) — preserved exactly: no boxing here
either."""
function _invoke_mul_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    arg_type = _invoke_operand1_type(args, ctx)
    is_32bit = _invoke_is_32bit_arith(arg_type)
    wt = is_32bit ? I32 : I64
    bmul = _ctx_builder(ctx, "compile_invoke")
    emit_value!(bmul, args[1], ctx, wt)
    emit_value!(bmul, args[2], ctx, wt)
    emit_intrinsic_binop!(bmul, wt, wt, :mul_int)
    return bmul
end

"""*(s1::Union{AbstractChar,AbstractString}, ss::Union{AbstractChar,AbstractString}...)
— string/char concatenation. A DIFFERENT Method than the BitInteger `*` above (Method
identity now disambiguates concat from multiply — the pre-migration ladder needed a
runtime `infer_value_type` guard here purely because it only had the bare Symbol
`:*` to dispatch on; a guard MISS fell through to the numeric-mul arm and silently
multiplied string-array refs as integers, e.g. for a Char argument the guard didn't
cover). DECLINES (→ terminal unsupported-method reject) unless proven all-String/
Symbol by `_all_string_args` — narrower than the Method's own Char/AbstractString
domain, preserved exactly as the pre-migration guard's scope; loud rejection now
replaces what used to be a silent wrong-value fallthrough for anything outside that
scope, never the reverse."""
function _invoke_star_concat_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::Union{InstrBuilder,Nothing}
    (length(args) >= 2 && _all_string_args(args, ctx)) || return nothing
    return compile_string_concat_many_b(args, ctx)
end

"""length(s::String) → array.len. Moved verbatim (including the any→array cast for
when WT's OWN type tracking (infer_value_type) still reports Any/Union{} even though
this Method's declared parameter is String — the same imprecision the pre-migration
arm's `arg_type === Any || arg_type === Union{}` branch compensated for)."""
function _invoke_length_str_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    arg_type = _invoke_operand1_type(args, ctx)
    blen = _ctx_builder(ctx, "compile_invoke")
    str_wasm = ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true)
    emit_value!(blen, args[1], ctx, str_wasm;
                from_julia=(arg_type isa Type && isconcretetype(arg_type)) ? arg_type : nothing)
    if arg_type === Any || arg_type === Union{}
        any_convert_extern!(blen)        # externref → anyref
        ref_cast!(blen, ArrayRef, true)  # anyref → (ref null array)
    end
    array_len!(blen)
    coerce_stack_top!(blen, I64, ctx)   # funnel: array.len's i32 → Julia's Int
    return blen
end

"""_thisind_continued closure (Base's local helper inside `_thisind_str`) — WasmGC
strings are array<i32> (one codepoint per element), so every index is already a valid
`thisind`: identity. Moved verbatim. Both name spellings in the pre-migration guard
(`:_thisind_continued` and `Symbol("#_thisind_continued#_thisind_str##0")`) resolved
to the SAME Method — a closure's `Method.name` is its declared short name, stripped
of the enclosing-scope mangling that only appears in the closure's TYPE name — so one
Method-keyed entry replaces both disjuncts."""
function _invoke_thisind_continued_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::Union{InstrBuilder,Nothing}
    length(args) >= 2 || return nothing
    bti = _ctx_builder(ctx, "compile_invoke")
    emit_value!(bti, length(args) >= 3 ? args[2] : args[1], ctx, I64)
    return bti
end

"""_nextind_continued closure — `nextind(s,i) = i + 1` in WasmGC. Moved verbatim; same
single-Method rationale as _invoke_thisind_continued_b."""
function _invoke_nextind_continued_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::Union{InstrBuilder,Nothing}
    length(args) >= 2 || return nothing
    bni = _ctx_builder(ctx, "compile_invoke")
    emit_value!(bni, length(args) >= 3 ? args[2] : args[1], ctx, I64)
    i64_const!(bni, 1)
    num!(bni, Opcode.I64_ADD)
    return bni
end

"""_string(a::Union{Char,SubString{String},String,Symbol}...) / string(a::Union{Char,
String,Symbol}...) / string(a::Union{Char,SubString{String},String,Symbol}...) — N-way
concatenation. Three distinct vararg Methods (one on `Base._string`, two on
`Base.string` depending on whether a SubString could appear), all registered to this
ONE builder. Moved verbatim: only String/Symbol arguments are PROVEN concatenable by
`_all_string_args` — narrower than what each Method's own signature actually allows
(Char and SubString are structurally valid too); not widened here, matching the
pre-migration guard's exact scope. DECLINES when there are fewer than 2 arguments —
the terminal `else` then rejects loudly, same as the pre-migration fallthrough."""
function _invoke_string_concat_or_reject_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::Union{InstrBuilder,Nothing}
    length(args) > 1 || return nothing
    _all_string_args(args, ctx) && return compile_string_concat_many_b(args, ctx)
    arg_types = [infer_value_type(a, ctx) for a in args]
    record_unsupported!(ctx, :unsupported_method,
        "specialized multi-argument string lowering requires every argument to be String or Symbol";
        idx=idx, detail=arg_types)
    bms = _ctx_builder(ctx, "compile_invoke")
    unreachable!(bms)  # polymorphic bottom; no fabricated String value
    ctx.last_stmt_was_stub = true
    return bms
end

"""string(n::Integer) — the dedicated positional Integer method (its kwarg body is
`#string#403`, handled separately for the interpolation fast path near the top of
compile_invoke!; THIS Method is what a plain `string(x)` call for any Int8..UInt64
resolves to). Moved verbatim: redirects to int_to_string."""
function _invoke_string_int_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    value_arg = args[1]
    bis1 = _ctx_builder(ctx, "compile_invoke")
    int_to_string_info = nothing
    if ctx.func_registry !== nothing && isdefined(WasmTarget, :int_to_string)
        int_to_string_func = getfield(WasmTarget, :int_to_string)
        int_to_string_info = get_function(ctx.func_registry, int_to_string_func, (Int32,))
    end
    if int_to_string_info !== nothing
        emit_value!(bis1, value_arg, ctx, I32)   # funnel: I64/UInt64 narrow via convert_type!
        call!(bis1, int_to_string_info.wasm_idx, WasmValType[], WasmValType[])
        return bis1
    else
        error("Base.string(::Integer) requires int_to_string in compile_multi. " *
              "Add WasmTarget.int_to_string and WasmTarget.digit_to_str to your function list.")
    end
end

"""string(a::String) / string(a::Symbol) — identity (WasmGC represents Symbol using
String's array shape). Moved verbatim, two distinct Methods sharing one builder."""
function _invoke_string_identity_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    bid = _ctx_builder(ctx, "compile_invoke")
    emit_value!(bid, args[1], ctx, ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))
    return bid
end

"""string(xs...) — the fully generic Vararg{Any} fallback Method (Base strings/io.jl).
Reached only when no more specific `string` method applies: Integer/String/Symbol all
have their own dedicated Methods registered separately above, and Float16/32/64 are
deliberately left UNREGISTERED (cross-call/auto-discovery owns Ryu.writeshortest, same
as before this migration — registering the float Method here would be a second
producer for the same op). Moved verbatim: length>1 defers to the same
concat-or-reject builder the Char/String/Symbol vararg Methods use; length==1
redirects Integer / passes String,Symbol through / hard-errors otherwise, matching the
pre-migration arm's native `error()` exactly (this Method, for a length==1 call, is a
Base-internal seam that was never proven reachable either before or after this
migration — verbatim preservation, not a claim of coverage)."""
function _invoke_string_generic_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::Union{InstrBuilder,Nothing}
    length(args) > 1 && return _invoke_string_concat_or_reject_b(args, ctx, idx, expr)
    length(args) == 1 || return nothing
    value_type = infer_value_type(args[1], ctx)
    (value_type === Float32 || value_type === Float64) && return nothing
    if value_type === Int32 || value_type === Int64 ||
       value_type === UInt32 || value_type === UInt64 ||
       value_type === Int16 || value_type === UInt16 ||
       value_type === Int8 || value_type === UInt8
        return _invoke_string_int_b(args, ctx, idx, expr)
    elseif value_type === String || value_type === Symbol
        return _invoke_string_identity_b(args, ctx, idx, expr)
    else
        error("Base.string(::$(value_type)) not yet supported. " *
              "Supported types: String, Symbol, Float32, Float64, Int32, Int64, UInt32, UInt64, Int16, UInt16, Int8, UInt8")
    end
end

"""_throw_argerror(s) / throw_boundserror(A,I) / throw(...) (the Core builtin) /
_throw_not_readable() — emit throw (catchable) using args[1] as the exception payload
(absent for the 0-arg `_throw_not_readable`, which always hits the reject branch below
— unchanged from the pre-migration arm). Moved verbatim.

`_throw_not_writable`, named in the pre-migration guard alongside these, does not
exist as a Base binding on Julia 1.12 or 1.13 (`isdefined(Base, :_throw_not_writable)`
is false on both — confirmed directly) — dead, dropped rather than registered."""
function _invoke_throw_payload_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    ensure_exception_tag!(ctx.mod)
    bthr2 = _ctx_builder(ctx, "compile_invoke")
    exn_global = ensure_exception_global!(ctx.mod)
    if isempty(args)
        record_unsupported!(ctx, :unsupported_method,
            "throw helper has no exception payload"; idx=idx, detail=expr)
        unreachable!(bthr2)  # structural trap after recorded unsupported
        ctx.last_stmt_was_stub = true
        return bthr2
    end
    emit_value!(bthr2, args[1], ctx, AnyRef)
    global_set!(bthr2, exn_global)
    global_get!(bthr2, ensure_exception_global!(ctx.mod), AnyRef); ref_null!(bthr2, ExternRef); throw_!(bthr2, 0; inputs=WasmValType[AnyRef, ExternRef])   # typed (exn, trace) tag
    ctx.last_stmt_was_stub = true
    return bthr2
end

"""rethrow() / rethrow(e) — re-throw the currently-caught exception, already stashed
in \$current_exn; any argument is disregarded (native `rethrow`'s optional `e` is
likewise informational — WT's exception global always holds the live exception
object). Moved verbatim; registered separately from _invoke_throw_payload_b (a
DIFFERENT builder replaces the old bare-Symbol `rethrow` runtime branch)."""
function _invoke_rethrow_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    ensure_exception_tag!(ctx.mod)
    brt = _ctx_builder(ctx, "compile_invoke")
    global_get!(brt, ensure_exception_global!(ctx.mod), AnyRef); ref_null!(brt, ExternRef); throw_!(brt, 0; inputs=WasmValType[AnyRef, ExternRef])   # typed (exn, trace) tag
    ctx.last_stmt_was_stub = true
    return brt
end

"""True when Method `m`'s first explicit parameter is not `<: IO` — the SAME test
`_invoke_has_explicit_io` applies per-callsite (L96), applied ONCE per Method here at
registry-construction time instead: println/print/show each have a handful of
receiver-free overloads (`println(xs...)`, `println(x)`, `println(x,y)`, ...) plus
hundreds of ordinary `f(io::IO, x::SomeType)` formatting methods; only the
receiver-free ones belong to the host-console bridge (L96), so only those get
registered — the IO-explicit ones are ordinary Julia methods compiled through
cross-call, exactly as before this migration."""
function _invoke_receiver_free_method(m::Method)::Bool
    sig = m.sig
    (sig isa DataType && sig <: Tuple && length(sig.parameters) >= 2) || return true
    param_types = sig.parameters[2:end]
    return !_invoke_has_explicit_io(param_types)
end

"""println(xs...) — receiver-free Methods only (see _invoke_receiver_free_method).
Moved verbatim; the `if haskey(ctx.ssa_locals, idx)` nothing-placeholder push (used
downstream by trim-collected show machinery) that used to run AFTER this arm's body
mutated `fb` now runs inside the standalone builder itself."""
function _invoke_println_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    fbp = _compile_invoke_print_b(true, args, ctx)
    if haskey(ctx.ssa_locals, idx)
        bpn = _ctx_builder(ctx, "compile_invoke")
        ref_null!(bpn, AnyRef)  # ref.null any (0xD0 0x6E)
        append_builder!(fbp, bpn)
    end
    return fbp
end

"""print(xs...) — receiver-free Methods only. Moved verbatim, same shape as
_invoke_println_b (is_println=false: no trailing newline write)."""
function _invoke_print_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    fbp = _compile_invoke_print_b(false, args, ctx)
    if haskey(ctx.ssa_locals, idx)
        bpn = _ctx_builder(ctx, "compile_invoke")
        ref_null!(bpn, AnyRef)
        append_builder!(fbp, bpn)
    end
    return fbp
end

"""show(x) — the ONE receiver-free `show` Method (`Tuple{typeof(show),Any}`). Moved
verbatim, including the pre-migration behavior of silently emitting nothing when no
IO bridge is configured (unlike print/println, which reject via record_unsupported!
— an existing asymmetry, not something this migration changes)."""
function _invoke_show_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    io = get_io_imports()
    if io !== nothing
        bsh2 = _ctx_builder(ctx, "compile_invoke")
        for arg in args
            arg_type = nothing
            if arg isa Core.SSAValue
                arg_type = ctx.code_info.ssavaluetypes[arg.id]
            elseif arg isa Core.Argument
                slot_id = arg.n
                arg_type = ctx.code_info.slottypes[slot_id]
            elseif arg isa String || arg isa Symbol
                arg_type = String
            elseif arg isa Int64 || arg isa Int32 || arg isa Int
                arg_type = typeof(arg)
            elseif arg isa Float64 || arg isa Float32
                arg_type = typeof(arg)
            elseif arg isa Bool
                arg_type = Bool
            elseif arg isa Nothing || arg === nothing
                arg_type = Nothing
            elseif arg isa GlobalRef && arg.name === :nothing
                arg_type = Nothing
            end

            if arg_type === Nothing
                call!(bsh2, io.write_nothing_idx, WasmValType[], WasmValType[])
            elseif arg_type === String || arg_type === Symbol
                emit_value!(bsh2, arg, ctx, ConcreteRef(get_string_array_type!(ctx.mod, ctx.type_registry), true))   # parity(translator.dart:1597 Translator.convertType): funnel → DATA array
                emit_jl_string_to_js!(bsh2, io.decode_idx)
                call!(bsh2, io.write_string_idx, WasmValType[], WasmValType[])
            elseif arg_type === Int64 || arg_type === Int || arg_type === UInt64
                emit_value!(bsh2, arg, ctx, I64)
                call!(bsh2, io.write_int_idx, WasmValType[], WasmValType[])
            elseif arg_type === Int32
                emit_value!(bsh2, arg, ctx, I64)   # funnel: I32 source widens via convert_type!
                call!(bsh2, io.write_int_idx, WasmValType[], WasmValType[])
            elseif arg_type === Float64
                emit_value!(bsh2, arg, ctx, F64)
                call!(bsh2, io.write_float_idx, WasmValType[], WasmValType[])
            elseif arg_type === Float32
                emit_value!(bsh2, arg, ctx, F64)   # funnel: F32 source promotes via convert_type!
                call!(bsh2, io.write_float_idx, WasmValType[], WasmValType[])
            elseif arg_type === Bool
                emit_value!(bsh2, arg, ctx, I32)
                call!(bsh2, io.write_bool_idx, WasmValType[], WasmValType[])
            else
                record_unsupported!(ctx, :unsupported_method,
                    "show has no IO bridge representation for argument type $arg_type";
                    idx=idx, detail=arg)
                unreachable!(bsh2) # recorded unsupported; polymorphic bottom
                ctx.last_stmt_was_stub = true
                break
            end
        end
        if haskey(ctx.ssa_locals, idx)
            ref_null!(bsh2, AnyRef)
        end
        return bsh2
    else
        fb2 = _ctx_builder(ctx, "compile_invoke.frag"); _seed_builder_locals!(fb2, ctx)
        return fb2
    end
end

"""truncate(io::GenericIOBuffer, n) — IOBuffer resize is a no-op in WasmGC; return the
IOBuffer argument unchanged (Julia's `truncate` returns its io argument). REWRITTEN
standalone: the pre-migration arm's body was empty, relying on the io argument (and,
ambiguously, the length argument) being left over from the ordinary pre-push loop —
that leftover-stack shape cannot be replicated by a self-contained builder. This
pushes exactly the io argument and nothing else, matching the arm's documented intent
("just leave it on stack... Returns the IOBuffer itself") unambiguously."""
function _invoke_truncate_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    btr = _ctx_builder(ctx, "compile_invoke")
    emit_value!(btr, args[1], ctx, static_wasm_type(args[1], ctx))
    return btr
end

"""getindex_continued(s,i,u) — UTF-8 byte-level multibyte continuation; not
implemented (WasmGC strings are array<i32>, one codepoint per element — genuinely
unreachable for valid indices). Moved verbatim."""
function _invoke_getindex_continued_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    bgic = _ctx_builder(ctx, "compile_invoke")
    record_unsupported!(ctx, :unsupported_method, "string getindex_continued (byte-level multibyte access)"; idx=idx)
    unreachable!(bgic)
    ctx.last_stmt_was_stub = true
    return bgic
end

"""error() / error(s::AbstractString) / error(s::Vararg{Any,N}) — Base.error's 3
Methods all funnel through ONE ErrorException construction (message-only payload);
`error` called with more than one argument native-errors at WT-compile time exactly
like the pre-migration arm (`length(args) <= 1 || error(...)`), since the payload
this builds has no room for extra values. Moved verbatim."""
function _invoke_error_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    berr = _ctx_builder(ctx, "compile_invoke")  # Clear pre-pushed args
    ensure_exception_tag!(ctx.mod)
    exn_global = ensure_exception_global!(ctx.mod)
    _ee_info = register_struct_type!(ctx.mod, ctx.type_registry, ErrorException)
    _ee_info === nothing && error("ErrorException layout is unavailable")
    length(args) <= 1 || error("unexpected error() lowering arity: $(length(args))")
    emit_struct_prefix!(berr, ctx.type_registry, ErrorException, _ee_info)
    _ee_def = ctx.mod.types[_ee_info.wasm_type_idx + 1]
    _ee_msg_w = _ee_def.fields[wasm_field_idx(_ee_info, 1) + 1].valtype
    emit_value!(berr, isempty(args) ? "" : args[1], ctx, _ee_msg_w; from_julia=String)
    struct_new!(berr, _ee_info.wasm_type_idx)   # mod-resolved fields
    global_set!(berr, exn_global)
    global_get!(berr, ensure_exception_global!(ctx.mod), AnyRef); ref_null!(berr, ExternRef); throw_!(berr, 0; inputs=WasmValType[AnyRef, ExternRef])   # typed (exn, trace) tag
    ctx.last_stmt_was_stub = true
    return berr
end

"""JuliaSyntax.parse_float_literal(::Type,str,firstind,endind) — not implemented
(orig uses ccall(:jl_strtod_c)). Moved verbatim: Strict Approach A loud reject."""
function _invoke_parse_float_literal_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    fb2 = _ctx_builder(ctx, "compile_invoke.frag"); _seed_builder_locals!(fb2, ctx)
    emit_unsupported_stub!(ctx, fb2, :unsupported_method,
        "parse_float_literal (JuliaSyntax float parsing — needs jl_strtod_c)"; idx=idx)
    return fb2
end

"""JuliaSyntax.parse_int_literal(str) / parse_uint_literal(str,k) — not implemented.
Moved verbatim: both Methods share the SAME stub message the pre-migration arm's
combined `parse_int_literal`/`parse_uint_literal` name guard used."""
function _invoke_parse_int_literal_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    fb2 = _ctx_builder(ctx, "compile_invoke.frag"); _seed_builder_locals!(fb2, ctx)
    emit_unsupported_stub!(ctx, fb2, :unsupported_method,
        "parse_int/uint_literal (JuliaSyntax integer parsing)"; idx=idx)
    return fb2
end

"""Symbol(s::String) — identity (WasmGC represents Symbol using String's array
shape). Moved verbatim."""
function _invoke_symbol_from_string_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    bsym = _ctx_builder(ctx, "compile_invoke")
    emit_value!(bsym, args[1], ctx, ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))
    return bsym
end

"""typeintersect(a,b) — a C runtime function used in tuple convert; with unoptimized
IR the convert inlines typeintersect. Evaluated at compile time when both args are
constant Type values. DECLINES otherwise — the terminal unsupported-method reject
then applies, the same end state the pre-migration guard miss fell through to."""
function _invoke_typeintersect_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::Union{InstrBuilder,Nothing}
    (length(args) >= 2 && args[1] isa Type && args[2] isa Type) || return nothing
    result_type = typeintersect(args[1], args[2])
    bti2 = _ctx_builder(ctx, "compile_invoke")  # Clear pre-pushed args
    global_idx = get_type_constant_global!(ctx.mod, ctx.type_registry, result_type)
    global_get!(bti2, global_idx, AnyRef)
    extern_convert_any!(bti2)   # concrete ref → externref (Type values are externref in general context)
    return bti2
end

"""_tuple_error(T,x) — error function in the tuple-convert dead-code path. Emit throw
(catchable) instead of unreachable (trap). Moved verbatim."""
function _invoke_tuple_error_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    bte = _ctx_builder(ctx, "compile_invoke")  # Clear pre-pushed args
    ensure_exception_tag!(ctx.mod)
    global_get!(bte, ensure_exception_global!(ctx.mod), AnyRef); ref_null!(bte, ExternRef); throw_!(bte, 0; inputs=WasmValType[AnyRef, ExternRef])   # typed (exn, trace) tag
    ctx.last_stmt_was_stub = true
    return bte
end


"""Base.padding(T,baseoffset) — a compile-time SimpleVector constant (P4-stdlib radix
sort guard). DECLINES unless both args are literal `Type`/`Integer` values in the IR —
matches the pre-migration guard exactly; falls through to the terminal reject
otherwise, same as before."""
function _invoke_padding_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::Union{InstrBuilder,Nothing}
    (length(args) == 2 && args[1] isa Type && args[2] isa Integer) || return nothing
    bpad = _ctx_builder(ctx, "compile_invoke")
    _padding = Base.padding(args[1], Int(args[2]))
    _emit_svec_values!(bpad, collect(_padding), ctx)
    return bpad
end

"""Base.sizehint!(collection,n) — a memory optimization hint; WasmGC arrays have no
capacity concept, so it's a no-op returning the collection unchanged. Registered for
EVERY sizehint! Method (Vector/Set/Dict/BitSet/IdSet/WeakKeyDict/...) — the
pre-migration arm applied uniformly by name, not by collection type. Moved verbatim."""
function _invoke_sizehint_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    bsh = _ctx_builder(ctx, "compile_invoke")
    if !isempty(args)
        emit_value!(bsh, args[1], ctx, static_wasm_type(args[1], ctx))
    else
        record_unsupported!(ctx, :unsupported_method, "vector op: argument vector unavailable"; idx=idx)
        unreachable!(bsh)
    end
    return bsh
end

"""#sizehint!#81(first,shrink,::typeof(sizehint!),a,sz) — the keyword-body entry
`sizehint!(v,n)` desugars to. Moved verbatim: the vector argument is the 4th
positional arg (matching the pre-migration arm's `args[4]`, which is the SAME
position — `args` is the same expression-argument slice here as there)."""
function _invoke_sizehint_kwbody_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::InstrBuilder
    bsh = _ctx_builder(ctx, "compile_invoke")
    if length(args) >= 4
        emit_value!(bsh, args[4], ctx, static_wasm_type(args[4], ctx))
    else
        record_unsupported!(ctx, :unsupported_method, "vector op: argument vector unavailable"; idx=idx)
        unreachable!(bsh)
    end
    return bsh
end

"""Base.kwerr(kw,args...) always throws the exact closed-world
MethodError(Core.kwcall, (kw,args...), world). This is a real Julia exception
payload, not a generic trap: catch-side isa/field inspection must observe the same
object shape as native Julia. Moved verbatim (lock L81_kwerr_throws_exact_methoderror).
DECLINES unless exactly 2 arguments (kw,f) — matches the pre-migration guard's
`length(args) == 2`."""
function _invoke_kwerr_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::Union{InstrBuilder,Nothing}
    length(args) == 2 || return nothing
    bkw = _ctx_builder(ctx, "compile_invoke.kwerr")
    ensure_exception_tag!(ctx.mod)
    exn_global = ensure_exception_global!(ctx.mod)
    error_info = register_struct_type!(ctx.mod, ctx.type_registry, MethodError)
    arg_julia_types = tuple((_invoke_arg_static_type(a, ctx) for a in args)...)
    all(T -> T isa Type, arg_julia_types) ||
        record_unsupported!(ctx, :unsupported_type,
            "kwerr arguments have no Julia type in the closed world"; idx=idx, detail=expr)
    args_tuple_type = Tuple{arg_julia_types...}
    args_info = register_tuple_type!(ctx.mod, ctx.type_registry, args_tuple_type)
    error_info === nothing && error("MethodError layout is unavailable")
    args_info === nothing && error("kwerr argument tuple layout is unavailable")

    emit_struct_prefix!(bkw, ctx.type_registry, MethodError, error_info)
    emit_value!(bkw, Core.kwcall, ctx, AnyRef; from_julia=typeof(Core.kwcall))
    emit_struct_prefix!(bkw, ctx.type_registry, args_tuple_type, args_info)
    args_layout = ctx.mod.types[args_info.wasm_type_idx + 1]
    args_layout isa StructType || error("kwerr argument tuple has no struct layout")
    for (i, arg) in enumerate(args)
        ft = args_layout.fields[Int(wasm_field_idx(args_info, i)) + 1].valtype
        jt = arg_julia_types[i]
        emit_value!(bkw, arg, ctx, ft;
                    from_julia=isconcretetype(jt) ? jt : nothing)
    end
    struct_new!(bkw, args_info.wasm_type_idx)
    i64_const!(bkw, Int64(WASM_WORLD_AGE))
    struct_new!(bkw, error_info.wasm_type_idx)
    global_set!(bkw, exn_global)
    global_get!(bkw, exn_global, AnyRef)
    ref_null!(bkw, ExternRef)
    throw_!(bkw, 0; inputs=WasmValType[AnyRef, ExternRef])
    return bkw
end

"""Core.throw_inexacterror(func,to,val) is precisely throw(InexactError(func,
(to,val))). Preserve both fields so catch-side inspection agrees with Julia. Moved
verbatim (lock L82_inexact_helper_throws_exact_payload)."""
function _invoke_throw_inexacterror_b(args, ctx::AbstractCompilationContext, idx::Int, expr::Expr)::Union{InstrBuilder,Nothing}
    length(args) >= 3 || return nothing
    bie = _ctx_builder(ctx, "compile_invoke.throw_inexacterror")
    ensure_exception_tag!(ctx.mod)
    exn_global = ensure_exception_global!(ctx.mod)
    error_info = register_struct_type!(ctx.mod, ctx.type_registry, InexactError)
    payload = args[2:end]
    payload_types = tuple((_invoke_arg_static_type(a, ctx) for a in payload)...)
    all(T -> T isa Type, payload_types) ||
        record_unsupported!(ctx, :unsupported_type,
            "throw_inexacterror payload has no Julia type"; idx=idx, detail=expr)
    payload_type = Tuple{payload_types...}
    payload_info = register_tuple_type!(ctx.mod, ctx.type_registry, payload_type)
    error_info === nothing && error("InexactError layout is unavailable")
    payload_info === nothing && error("InexactError argument tuple layout is unavailable")

    emit_struct_prefix!(bie, ctx.type_registry, InexactError, error_info)
    emit_value!(bie, args[1], ctx,
                ctx.mod.types[error_info.wasm_type_idx + 1].fields[
                    Int(wasm_field_idx(error_info, 1)) + 1].valtype;
                from_julia=Symbol)
    emit_struct_prefix!(bie, ctx.type_registry, payload_type, payload_info)
    payload_layout = ctx.mod.types[payload_info.wasm_type_idx + 1]
    payload_layout isa StructType || error("InexactError payload has no struct layout")
    for (i, value) in enumerate(payload)
        ft = payload_layout.fields[Int(wasm_field_idx(payload_info, i)) + 1].valtype
        jt = payload_types[i]
        emit_value!(bie, value, ctx, ft;
                    from_julia=isconcretetype(jt) ? jt : nothing)
    end
    struct_new!(bie, payload_info.wasm_type_idx)
    struct_new!(bie, error_info.wasm_type_idx)
    global_set!(bie, exn_global)
    global_get!(bie, exn_global, AnyRef)
    ref_null!(bie, ExternRef)
    throw_!(bie, 0; inputs=WasmValType[AnyRef, ExternRef])
    return bie
end

"""Populate INVOKE_INTRINSICS once, lazily, on first `compile_invoke!` call."""
function _build_invoke_intrinsics!()
    isempty(INVOKE_INTRINSICS) || return nothing
    _register_invoke_intrinsic!(str_char, InvokeIntrinsicEntry(_invoke_str_char_b, :standalone))
    _register_invoke_intrinsic!(str_setchar!, InvokeIntrinsicEntry(_invoke_str_setchar_b, :standalone))
    _register_invoke_intrinsic!(str_new, InvokeIntrinsicEntry(_invoke_str_new_b, :standalone))
    _register_invoke_intrinsic!(str_copy, InvokeIntrinsicEntry(_invoke_str_copy_b, :standalone))
    _register_invoke_intrinsic!(str_substr, InvokeIntrinsicEntry(_invoke_str_substr_b, :standalone))
    _register_invoke_intrinsic!(arr_new, InvokeIntrinsicEntry(_invoke_arr_new_b, :standalone))
    _register_invoke_intrinsic!(arr_get, InvokeIntrinsicEntry(_invoke_arr_get_b, :standalone))
    _register_invoke_intrinsic!(arr_set!, InvokeIntrinsicEntry(_invoke_arr_set_b, :standalone))
    _register_invoke_intrinsic!(arr_len, InvokeIntrinsicEntry(_invoke_arr_len_b, :standalone))
    _register_invoke_intrinsic!(isascii, InvokeIntrinsicEntry(_invoke_isascii_b, :append))
    _register_invoke_intrinsic!(Base.:(==), InvokeIntrinsicEntry(_invoke_string_eq_b, :standalone); argtypes=(String, String))
    _register_invoke_intrinsic!(SubString, InvokeIntrinsicEntry(_invoke_substring_b, :standalone))
    _register_invoke_intrinsic!(Base.array_subpadding, InvokeIntrinsicEntry(_invoke_array_subpadding_b, :standalone))
    _register_invoke_intrinsic!(Base.unalias, InvokeIntrinsicEntry(_invoke_unalias_b, :standalone))

    # ---- R20 migration (phase 5): the former name === :sym ladder arms -------
    # Arithmetic: Base's BitInteger fallback Methods (the raw intrinsics never reach
    # here as :invoke — see _invoke_add_b's docstring).
    _register_invoke_intrinsic!(Base.:+, InvokeIntrinsicEntry(_invoke_add_b, :standalone); argtypes=(Int64, Int64))
    _register_invoke_intrinsic!(Base.:-, InvokeIntrinsicEntry(_invoke_sub_b, :standalone); argtypes=(Int64, Int64))
    _register_invoke_intrinsic!(Base.:-, InvokeIntrinsicEntry(_invoke_neg_b, :standalone); argtypes=(Int64,))
    _register_invoke_intrinsic!(Base.:*, InvokeIntrinsicEntry(_invoke_mul_b, :standalone); argtypes=(Int64, Int64))
    _register_invoke_intrinsic!(Base.:*, InvokeIntrinsicEntry(_invoke_star_concat_b, :standalone); argtypes=(String, String))
    _register_invoke_intrinsic!(Base.length, InvokeIntrinsicEntry(_invoke_length_str_b, :standalone); argtypes=(String,))

    # _thisind_continued / _nextind_continued: singleton closures — `getfield` returns
    # the closure TYPE (mangled `#<name>#<enclosing>##<n>` naming); `.instance` is the
    # one callable value `methods()` can resolve.
    _register_invoke_intrinsic!(getfield(Base, Symbol("#_thisind_continued#_thisind_str##0")).instance,
                                InvokeIntrinsicEntry(_invoke_thisind_continued_b, :standalone))
    _register_invoke_intrinsic!(getfield(Base, Symbol("#_nextind_continued#_nextind_str##0")).instance,
                                InvokeIntrinsicEntry(_invoke_nextind_continued_b, :standalone))

    # string()/_string(): every vararg concat Method shares one builder; the dedicated
    # Integer/String/Symbol Methods and the generic Vararg{Any} fallback each get their
    # own (Float16/32/64 deliberately unregistered — see _invoke_string_generic_b).
    _register_invoke_intrinsic!(Base._string, InvokeIntrinsicEntry(_invoke_string_concat_or_reject_b, :standalone))
    _register_invoke_intrinsic!(Base.string, InvokeIntrinsicEntry(_invoke_string_concat_or_reject_b, :standalone); argtypes=(String, String))
    _register_invoke_intrinsic!(Base.string, InvokeIntrinsicEntry(_invoke_string_concat_or_reject_b, :standalone); argtypes=(SubString{String}, String))
    _register_invoke_intrinsic!(Base.string, InvokeIntrinsicEntry(_invoke_string_int_b, :standalone); argtypes=(Int64,))
    _register_invoke_intrinsic!(Base.string, InvokeIntrinsicEntry(_invoke_string_identity_b, :standalone); argtypes=(String,))
    _register_invoke_intrinsic!(Base.string, InvokeIntrinsicEntry(_invoke_string_identity_b, :standalone); argtypes=(Symbol,))
    _register_invoke_intrinsic!(Base.string, InvokeIntrinsicEntry(_invoke_string_generic_b, :standalone); argtypes=(Int64, Int64))

    # throw/rethrow family.
    _register_invoke_intrinsic!(Base._throw_argerror, InvokeIntrinsicEntry(_invoke_throw_payload_b, :standalone))
    _register_invoke_intrinsic!(Base.throw_boundserror, InvokeIntrinsicEntry(_invoke_throw_payload_b, :standalone))
    _register_invoke_intrinsic!(Core.throw, InvokeIntrinsicEntry(_invoke_throw_payload_b, :standalone))
    _register_invoke_intrinsic!(Base._throw_not_readable, InvokeIntrinsicEntry(_invoke_throw_payload_b, :standalone))
    _register_invoke_intrinsic!(Base.rethrow, InvokeIntrinsicEntry(_invoke_rethrow_b, :standalone))

    # println/print/show: the host-console bridge — receiver-free Methods only.
    for m in methods(println)
        _invoke_receiver_free_method(m) &&
            (INVOKE_INTRINSICS[m] = InvokeIntrinsicEntry(_invoke_println_b, :standalone))
    end
    for m in methods(print)
        _invoke_receiver_free_method(m) &&
            (INVOKE_INTRINSICS[m] = InvokeIntrinsicEntry(_invoke_print_b, :standalone))
    end
    for m in methods(show)
        _invoke_receiver_free_method(m) &&
            (INVOKE_INTRINSICS[m] = InvokeIntrinsicEntry(_invoke_show_b, :standalone))
    end

    _register_invoke_intrinsic!(Base.truncate, InvokeIntrinsicEntry(_invoke_truncate_b, :standalone);
                                argtypes=(Base.GenericIOBuffer, Integer))
    _register_invoke_intrinsic!(Base.getindex_continued, InvokeIntrinsicEntry(_invoke_getindex_continued_b, :standalone))
    _register_invoke_intrinsic!(Base.error, InvokeIntrinsicEntry(_invoke_error_b, :standalone))
    _register_invoke_intrinsic!(Base.JuliaSyntax.parse_float_literal, InvokeIntrinsicEntry(_invoke_parse_float_literal_b, :standalone))
    _register_invoke_intrinsic!(Base.JuliaSyntax.parse_int_literal, InvokeIntrinsicEntry(_invoke_parse_int_literal_b, :standalone))
    _register_invoke_intrinsic!(Base.JuliaSyntax.parse_uint_literal, InvokeIntrinsicEntry(_invoke_parse_int_literal_b, :standalone))
    _register_invoke_intrinsic!(Base.Symbol, InvokeIntrinsicEntry(_invoke_symbol_from_string_b, :standalone); argtypes=(String,))
    _register_invoke_intrinsic!(Base.typeintersect, InvokeIntrinsicEntry(_invoke_typeintersect_b, :standalone))
    _register_invoke_intrinsic!(Base._tuple_error, InvokeIntrinsicEntry(_invoke_tuple_error_b, :standalone))
    _register_invoke_intrinsic!(Base.padding, InvokeIntrinsicEntry(_invoke_padding_b, :standalone); argtypes=(DataType, Int64))
    _register_invoke_intrinsic!(Base.sizehint!, InvokeIntrinsicEntry(_invoke_sizehint_b, :standalone))
    _register_invoke_intrinsic!(getfield(Base, Symbol("#sizehint!#81")), InvokeIntrinsicEntry(_invoke_sizehint_kwbody_b, :standalone))
    _register_invoke_intrinsic!(Base.kwerr, InvokeIntrinsicEntry(_invoke_kwerr_b, :standalone))
    _register_invoke_intrinsic!(Core.throw_inexacterror, InvokeIntrinsicEntry(_invoke_throw_inexacterror_b, :standalone))
    return nothing
end

"""
Extract: println/print handler. Emits JS IO bridge imports.
"""
_compile_invoke_print(name::Symbol, args, ctx::AbstractCompilationContext)::Vector{UInt8} =
    builder_code(_compile_invoke_print_b(name, args, ctx))

"""builder-returning core."""
function _compile_invoke_print_b(is_println::Bool, args, ctx::AbstractCompilationContext)::InstrBuilder
    io = get_io_imports()
    if io !== nothing
        b = _ctx_builder(ctx, "_compile_invoke_print")
        # parity(translator.dart:1597 Translator.convertType): the io bridge consumes the DATA array — every string value
        # funnels through the expected-type channel so classed strings unwrap here.
        _pr_str_arr = ConcreteRef(get_string_array_type!(ctx.mod, ctx.type_registry), true)
        for arg in args
            # Determine argument type
            arg_type = nothing
            if arg isa Core.SSAValue
                arg_type = ctx.code_info.ssavaluetypes[arg.id]
            elseif arg isa Core.Argument
                slot_id = arg.n
                arg_type = ctx.code_info.slottypes[slot_id]
            elseif arg isa String || arg isa Symbol
                arg_type = String
            elseif arg isa Int64 || arg isa Int32 || arg isa Int
                arg_type = typeof(arg)
            elseif arg isa Float64 || arg isa Float32
                arg_type = typeof(arg)
            elseif arg isa Bool
                arg_type = Bool
            elseif arg isa Nothing || arg === nothing || (arg isa GlobalRef && arg.name === :nothing)
                arg_type = Nothing
            elseif arg isa Tuple
                arg_type = typeof(arg)
            elseif arg isa Vector
                arg_type = typeof(arg)
            end

            if arg_type === String || arg_type === Symbol
                # String: compile value, convert to JS string via decoder, call write_string
                emit_value!(b, arg, ctx, _pr_str_arr)
                # Need a temp local for tee
                tmp_local = UInt32(allocate_local!(ctx, ConcreteRef(get_string_array_type!(ctx.mod, ctx.type_registry), true)))
                emit_jl_string_to_js!(b, io.decode_idx)
                # (ref extern) is subtype of externref — no conversion needed
                call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
            elseif arg_type === Int64 || arg_type === Int || arg_type === UInt64
                emit_value!(b, arg, ctx, I64)
                call!(b, io.write_int_idx, WasmValType[I64], WasmValType[])
            elseif arg_type === Int32
                emit_value!(b, arg, ctx, I64)   # funnel: I32_from source widens via convert_type!
                call!(b, io.write_int_idx, WasmValType[I64], WasmValType[])
            elseif arg_type === Float64
                emit_value!(b, arg, ctx, F64)
                call!(b, io.write_float_idx, WasmValType[F64], WasmValType[])
            elseif arg_type === Float32
                emit_value!(b, arg, ctx, F64)   # funnel: F32 source promotes via convert_type!
                call!(b, io.write_float_idx, WasmValType[F64], WasmValType[])
            elseif arg_type === Bool
                emit_value!(b, arg, ctx, I32)   # step4
                call!(b, io.write_bool_idx, WasmValType[I32], WasmValType[])
            elseif arg_type === Nothing
                # println(nothing) → write "nothing"
                call!(b, io.write_nothing_idx, WasmValType[], WasmValType[])
            elseif arg_type !== nothing && arg_type <: Vector
                # Vector display — emit "[e1, e2, ...]"
                elem_type = eltype(arg_type)

                # Register vector type to get struct info
                vec_info = register_vector_type!(ctx.mod, ctx.type_registry, arg_type)
                vec_type_idx = vec_info.wasm_type_idx
                data_array_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

                # Compile the vector value onto stack
                emit_value!(b, arg, ctx, ConcreteRef(UInt32(vec_type_idx), true))   # step4

                # Allocate locals: vec_ref, data_arr, len, i, tmp_str
                vec_local = UInt32(allocate_local!(ctx, ConcreteRef(vec_type_idx, true)))
                data_local = UInt32(allocate_local!(ctx, ConcreteRef(data_array_idx, true)))
                len_local = UInt32(allocate_local!(ctx, I32))
                i_local = UInt32(allocate_local!(ctx, I32))
                str_tmp_local = UInt32(allocate_local!(ctx, ConcreteRef(get_string_array_type!(ctx.mod, ctx.type_registry), true)))

                # Store vec ref
                local_set!(b, vec_local)

                # Get data array: struct.get field 1 (after typeId at field 0)
                local_get!(b, vec_local)
                struct_get!(b, vec_type_idx, wasm_field_idx(vec_info, 1), ConcreteRef(UInt32(data_array_idx), true))
                local_set!(b, data_local)

                # Get length: array.len
                local_get!(b, data_local)
                array_len!(b)
                local_set!(b, len_local)

                # Write "["
                emit_value!(b, "[", ctx, _pr_str_arr)
                emit_jl_string_to_js!(b, io.decode_idx)
                call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])

                # Initialize i = 0
                i32_const!(b, 0)
                local_set!(b, i_local)

                # Loop: block { loop { ... } }
                done_label = block!(b, 0x40)
                loop_label = loop!(b, 0x40)

                # if i >= len, break
                local_get!(b, i_local)
                local_get!(b, len_local)
                num!(b, Opcode.I32_GE_S)
                br_if!(b, done_label)

                # if i > 0, write ", "
                local_get!(b, i_local)
                i32_const!(b, 0)
                num!(b, Opcode.I32_NE)
                if_!(b, 0x40)  # void
                emit_value!(b, ", ", ctx, _pr_str_arr)
                emit_jl_string_to_js!(b, io.decode_idx)
                call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
                end_block!(b)  # end if

                # Get element: data_arr[i]
                local_get!(b, data_local)
                local_get!(b, i_local)
                _elem_wt = (elem_type === Float64) ? F64 : (elem_type === Float32) ? F32 :
                           (elem_type === Int64 || elem_type === Int || elem_type === UInt64) ? I64 : I32
                array_get!(b, data_array_idx, _elem_wt; signed=packed_array_signedness(elem_type))

                # Display element based on element type
                if elem_type === Int32
                    coerce_stack_top!(b, I64, ctx)   # funnel: array.get's i32 → the IO bridge's i64
                    call!(b, io.write_int_idx, WasmValType[I64], WasmValType[])
                elseif elem_type === Int64 || elem_type === Int || elem_type === UInt64
                    call!(b, io.write_int_idx, WasmValType[I64], WasmValType[])
                elseif elem_type === Float64
                    call!(b, io.write_float_idx, WasmValType[F64], WasmValType[])
                elseif elem_type === Float32
                    coerce_stack_top!(b, F64, ctx)   # funnel: array.get's f32 → the IO bridge's f64
                    call!(b, io.write_float_idx, WasmValType[F64], WasmValType[])
                elseif elem_type === Bool
                    call!(b, io.write_bool_idx, WasmValType[I32], WasmValType[])
                else
                    record_unsupported!(ctx, :unsupported_type,
                        "println/print has no IO bridge representation for Vector{$elem_type}")
                end

                # i += 1
                local_get!(b, i_local)
                i32_const!(b, 1)
                num!(b, Opcode.I32_ADD)
                local_set!(b, i_local)

                # Branch back to loop
                br!(b, loop_label)

                end_block!(b)  # end loop
                end_block!(b)  # end block

                # Write "]"
                emit_value!(b, "]", ctx, _pr_str_arr)
                emit_jl_string_to_js!(b, io.decode_idx)
                call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
            elseif arg_type !== nothing && arg_type <: Tuple && arg_type isa DataType
                # Tuple display — emit "(e1, e2, ...)"
                tuple_info = register_tuple_type!(ctx.mod, ctx.type_registry, arg_type)
                if tuple_info !== nothing
                    tuple_type_idx = tuple_info.wasm_type_idx
                    elem_types = arg_type.parameters

                    # Compile tuple value and store in local
                    emit_value!(b, arg, ctx, ConcreteRef(UInt32(tuple_type_idx), true))   # step4
                    tup_local = UInt32(allocate_local!(ctx, ConcreteRef(tuple_type_idx, true)))
                    str_tmp_local2 = UInt32(allocate_local!(ctx, ConcreteRef(get_string_array_type!(ctx.mod, ctx.type_registry), true)))
                    local_set!(b, tup_local)

                    # Write "("
                    emit_value!(b, "(", ctx, _pr_str_arr)
                    emit_jl_string_to_js!(b, io.decode_idx)
                    call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])

                    for (fi, et) in enumerate(elem_types)
                        # Write ", " separator (after first element)
                        if fi > 1
                            emit_value!(b, ", ", ctx, _pr_str_arr)
                            emit_jl_string_to_js!(b, io.decode_idx)
                            call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
                        end

                        # Get field: struct.get (field index = fi because of typeId at 0)
                        local_get!(b, tup_local)
                        _et_wt = (et === Float64) ? F64 : (et === Float32) ? F32 :
                                 (et === Int64 || et === Int || et === UInt64) ? I64 : I32
                        struct_get!(b, tuple_type_idx, wasm_field_idx(tuple_info, fi), _et_wt)

                        # Write element based on type
                        if et === Int32
                            coerce_stack_top!(b, I64, ctx)   # funnel: struct.get's i32 → the IO bridge's i64
                            call!(b, io.write_int_idx, WasmValType[I64], WasmValType[])
                        elseif et === Int64 || et === Int || et === UInt64
                            call!(b, io.write_int_idx, WasmValType[I64], WasmValType[])
                        elseif et === Float64
                            call!(b, io.write_float_idx, WasmValType[F64], WasmValType[])
                        elseif et === Float32
                            coerce_stack_top!(b, F64, ctx)   # funnel: struct.get's f32 → the IO bridge's f64
                            call!(b, io.write_float_idx, WasmValType[F64], WasmValType[])
                        elseif et === Bool
                            call!(b, io.write_bool_idx, WasmValType[I32], WasmValType[])
                        else
                            record_unsupported!(ctx, :unsupported_type,
                                "println/print has no IO bridge representation for tuple field $et")
                        end
                    end

                    # Single-element tuple gets trailing comma: (1,)
                    if length(elem_types) == 1
                        emit_value!(b, ",", ctx, _pr_str_arr)
                        emit_jl_string_to_js!(b, io.decode_idx)
                        call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
                    end

                    # Write ")"
                    emit_value!(b, ")", ctx, _pr_str_arr)
                    emit_jl_string_to_js!(b, io.decode_idx)
                    call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
                else
                    record_unsupported!(ctx, :unsupported_type,
                        "println/print cannot register tuple representation $arg_type")
                end
            else
                record_unsupported!(ctx, :unsupported_type,
                    "println/print has no IO bridge representation for argument type $arg_type")
            end
        end
        if is_println
            call!(b, io.write_newline_idx, WasmValType[], WasmValType[])
        end
        return b
    else
        record_unsupported!(ctx, :unsupported_method,
            "println/print requires an explicitly configured IO bridge")
    end
end

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
        Base.code_typed(target, arg_types; optimize=true)
    catch
        return false
    end
    length(typed) == 1 || return false
    ci = first(typed).first
    ci isa Core.CodeInfo || return false
    news = Expr[s for s in ci.code if s isa Expr && s.head === :new]
    length(news) == 1 || return false
    all(s -> s === nothing || s isa Core.ReturnNode ||
             (s isa Expr && (s.head === :new || s.head === :meta)), ci.code) || return false
    alloc = only(news)
    length(alloc.args) == fieldcount(target) + 1 || return false
    tref = alloc.args[1]
    resolved = tref isa GlobalRef && isdefined(tref.mod, tref.name) ? getfield(tref.mod, tref.name) : tref
    resolved === target || return false
    for i in 1:fixed_count
        alloc.args[i + 1] == Core.Argument(i + 1) || return false
    end
    return alloc.args[end] == Core.Argument(fixed_count + 2)
end

_invoke_arg_static_type(arg, ctx::AbstractCompilationContext) =
    arg isa Type ? Core.Typeof(arg) : infer_value_type(arg, ctx)

"""Return the unique singleton represented by `T`, or `nothing` when none exists."""
_invoke_singleton_instance(@nospecialize(T)) =
    T isa DataType && Base.issingletontype(T) ? getfield(T, :instance) : nothing

"""
Compile an invoke expression (method invocation) — dart visitor shape:
emits the invoke INTO the caller's builder.
The interior accumulates into a FRAGMENT builder `fb` (≡ the old `bytes` buffer,
same discard semantics: arms that replace it re-init; exits merge typed).
"""
function compile_invoke!(b::InstrBuilder, expr::Expr, idx::Int, ctx::AbstractCompilationContext)
    _build_invoke_intrinsics!()   # lazy, once per process — see INVOKE_INTRINSICS above
    fb = _ctx_builder(ctx, "compile_invoke.frag")
    _seed_builder_locals!(fb, ctx)
    args = expr.args[3:end]

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
    func_ref = expr.args[2]
    if func_ref isa Core.SSAValue
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
    mi_or_ci = expr.args[1]
    mi = if mi_or_ci isa Core.MethodInstance
        mi_or_ci
    elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
        mi_or_ci.def
    else
        nothing
    end

    if mi isa Core.MethodInstance && mi.def isa Method &&
       mi.def.name in (:_closed_world_type_bounds, :check_world_bounded) && length(args) == 1
        wb = _ctx_builder(ctx, "compile_invoke.closed_world_type_bounds")
        emit_closed_world_type_bounds!(wb, args[1], ctx)
        return append_builder!(b, wb)
    end

    # Host-capability / dynamic-reflection reject — caught HERE, at MethodInstance
    # identity, before any recursion into the callee's body (dart2wasm has no
    # equivalent: `Core.eval` is outside a closed-world compilation target).
    # `Core.eval`'s body is runtime reflection (world-age bump + toplevel eval) that
    # WT tries to recurse into and partially compile, surfacing as an internal
    # StackImbalanceError on the OUTER call's result type instead of a classified
    # diagnostic (Phase 6.2). Reject at the call site instead, before the invariant
    # gets a chance to trip.
    if mi isa Core.MethodInstance && mi.def isa Method
        local _iv_m = mi.def
        if _iv_m.module === Core && _iv_m.name === :eval
            record_unsupported!(ctx, :unsupported_method,
                "eval (dynamic world-age reflection is outside WT's closed-world compilation target)";
                idx=idx, detail=expr, soundness_fatal=true)
            ctx.last_stmt_was_stub = true
            return append_builder!(b, fb)
        end
    end

    if mi isa Core.MethodInstance && mi.def isa Method &&
       mi.def.name in (:_closed_world_isvisible, :isvisible) && length(args) == 3
        symbol_owner = _trace_typename_symbol_owner(args[1], ctx)
        parent_owner = _trace_field_owner(args[2], :module, ctx)
        if symbol_owner !== nothing && isequal(symbol_owner, parent_owner)
            vb = _ctx_builder(ctx, "compile_invoke.closed_world_isvisible")
            emit_closed_world_isvisible!(vb, args[1], args[2], args[3], symbol_owner, ctx)
            return append_builder!(b, vb)
        end
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
        end
    elseif func_ref_early isa Core.PiNode && func_ref_early.val isa GlobalRef
        actual_func_ref_early = func_ref_early.val
    elseif func_ref_early isa Core.PiNode && func_ref_early.val isa Core.SSAValue
        pi_ssa_stmt = ctx.code_info.code[func_ref_early.val.id]
        if pi_ssa_stmt isa GlobalRef
            actual_func_ref_early = pi_ssa_stmt
        end
    elseif func_ref_early isa Core.Argument
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
    is_self_call_early = false
    if ctx.func_ref !== nothing && actual_func_ref_early isa GlobalRef &&
       isdefined(actual_func_ref_early.mod, actual_func_ref_early.name)
            called_func = getfield(actual_func_ref_early.mod, actual_func_ref_early.name)
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
        if actual_func_ref_early isa GlobalRef
            called_func_early = isdefined(actual_func_ref_early.mod, actual_func_ref_early.name) ?
                getfield(actual_func_ref_early.mod, actual_func_ref_early.name) : nothing
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
                    closure_self_to_push = actual_func_ref_early
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
       actual_func_ref_early !== nothing && !(actual_func_ref_early isa GlobalRef)
        ft_early = infer_value_type(actual_func_ref_early, ctx)
        if ft_early isa DataType && is_closure_type(ft_early)
            cat_early = tuple([infer_value_type(arg, ctx) for arg in args]...)
            ti = get_function_by_argtypes(ctx.func_registry, (ft_early, cat_early...))
            tracing(:closure) &&
                println(stderr, "CLOSDBG bytype ft=", ft_early, " cat=", cat_early, " hit=", ti !== nothing)
            if ti !== nothing
                target_info_early = ti
                closure_self_to_push = actual_func_ref_early
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
        is_nothing_arg = arg === nothing ||
                        (arg isa GlobalRef && arg.name === :nothing) ||
                        (arg isa Core.SSAValue && begin
                            ssa_stmt = ctx.code_info.code[arg.id]
                            (ssa_stmt isa GlobalRef && ssa_stmt.name === :nothing) ||
                            (ssa_stmt isa Core.PiNode && ssa_stmt.typ === Nothing)
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
            if ctx.func_ref !== nothing && actual_func_ref isa GlobalRef &&
               isdefined(actual_func_ref.mod, actual_func_ref.name)
                # Check if this GlobalRef refers to the same function
                    called_func = getfield(actual_func_ref.mod, actual_func_ref.name)
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
            elseif ctx.func_ref !== nothing && actual_func_ref isa Function
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
            # Skip cross-call for runtime intrinsics with proper inline handlers.
            # str_substr's generate_intrinsic_body is a stub (returns source string unchanged);
            # the inline handler below implements it using WasmGC array operations with caller
            # scratch locals. str_trim used to be skipped for the same reason (it calls
            # str_substr internally) but Phase 5 deleted str_trim's bespoke builder — it now
            # compiles standalone through ordinary cross-call resolution like any Julia
            # function, and its internal str_substr call still hits this same skip+inline path.
            # str_char/str_setchar!/str_new were ADDED here in Phase 5.2: their
            # `generate_intrinsic_body` (compile.jl) hardcodes an i32 index/length local
            # regardless of the ACTUAL argument types, so cross-call previously routed
            # str_char(::String,::Int)/str_setchar!(::String,::Int,::Int32)/
            # str_new(::Int) — the Int64, not Int32, overloads — into a StackImbalanceError
            # ("expected I32, found I64") that predates this migration (confirmed against
            # the unmodified tree). str_copy was ADDED because cross-call was routing it to
            # its native-Julia no-op fallback (strings are immutable in native Julia; the
            # real WasmGC array.copy only existed in the shadowed inline arm) — a silent
            # correctness bug, not merely a crash. All four now route through
            # INVOKE_INTRINSICS instead, which is correct for every overload.
            _skip_cross_call = name in (:str_substr, :sizehint!, Symbol("#sizehint!#81"),
                                     :arr_new, :arr_get, :arr_set!, :arr_len, :arr_fill!,
                                     :str_char, :str_setchar!, :str_new, :str_copy)
            if ctx.func_registry !== nothing && !is_self_call && !_skip_cross_call
                # Try to find this function in our registry
                called_func = nothing
                if actual_func_ref isa GlobalRef
                    called_func = isdefined(actual_func_ref.mod, actual_func_ref.name) ?
                        getfield(actual_func_ref.mod, actual_func_ref.name) : nothing
                elseif actual_func_ref isa DataType || actual_func_ref isa UnionAll
                    # For constructor calls, the func_ref might be the type directly
                    called_func = actual_func_ref
                elseif actual_func_ref isa Function
                    # For default-arg methods, func_ref can be a Function object
                    # (e.g., typeof(next_token) for next_token(lexer, true))
                    called_func = actual_func_ref
                elseif actual_func_ref isa Core.Argument && mi isa Core.MethodInstance
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
                                elseif target_local_type === ExternRef && func_ref isa Core.Argument
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

            # parity(translator.dart:1621 Translator.convertType): numeric arith result → ref-typed SSA local ⇒ box through THE
            # one producer, dart's boxing branch (the scalar-replaced Core.Box cycle: unbox → op → box → store).
            # (moved to _invoke_box_arith_result! — the +/-/* invoke intrinsics' shared
            # helper, R20 migration; this used to be a local closure capturing `fb`/
            # `arg_type`/`is_32bit`, both of which are now computed inside each of
            # those Method-keyed builders instead of once here.)
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

            # parity(intrinsics.dart:26-64 MemberIntrinsic/StaticIntrinsic; `_lookup`
            # :75-100/:401-428): ONE Method-keyed lookup replaces the R20 arm-by-Symbol
            # ladder for every op below that has a registry entry. `:append` continues
            # the SAME fb the args loop already pushed to (isascii — verified to compile
            # correctly this way); `:standalone` pushes its own inputs and IS the result.
            elseif (local _invoke_reg_entry = get(INVOKE_INTRINSICS, meth, nothing)) !== nothing &&
                   (local _invoke_reg_result = (_invoke_reg_entry.mode === :append ?
                        _invoke_reg_entry.fn(args, ctx) : _invoke_reg_entry.fn(args, ctx, idx, expr))) !== nothing
                if _invoke_reg_entry.mode === :append
                    append_builder!(fb, _invoke_reg_result)
                else
                    return append_builder!(b, _invoke_reg_result)
                end

            # Base arithmetic (+/-/*), length(::String), _thisind_continued,
            # _nextind_continued, string()/_string(), throw/rethrow,
            # println/print/show: INVOKE_INTRINSICS registry (R20 migration).
            elseif meth.module === Base &&
                   occursin(r"^#_(?:growend|growbeg|growat)!", string(name))
                # Clear any accumulated bytes from argument compilation
                fb = _ctx_builder(ctx, "compile_invoke.frag"); _seed_builder_locals!(fb, ctx)

                # Drop the closure object from the stack if it's there
                func_ref = expr.args[2]
                if func_ref isa Core.SSAValue
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
                                        idx=idx, detail=expr)
                    unreachable!(bgrf)  # structural trap after recorded unsupported
                    append_builder!(fb, bgrf)
                    ctx.last_stmt_was_stub = true
                end

            # Symbol(::String), typeintersect, _tuple_error: INVOKE_INTRINSICS registry.

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
                        "struct constructor for `$(_ctor_target)` (type registration failed)"; idx=idx, detail=expr)
                    bscnf = _ctx_builder(ctx, "compile_invoke")
                    record_unsupported!(ctx, :unsupported_method, "struct type registration failed (cannot lay out)"; idx=idx)
                    unreachable!(bscnf)
                    append_builder!(fb, bscnf)
                    ctx.last_stmt_was_stub = true
                end

            # padding, kwerr, throw_inexacterror: INVOKE_INTRINSICS registry
            # (R20 migration). array_subpadding/unalias already registered above.
            else
                # Unknown method — codegen has no translation for this invoke target.
                # This records a source-attributed diagnostic and emits dart's validating
                # unsupported-path trap; no permissive mode exists.
                # which lets compilation succeed for paths that never reach this method.
                tracing(:stubargs) && println(stderr, "STUBARGS ", name, " args=", repr(args))
                record_unsupported!(ctx, :unsupported_method,
                    "method `$name`" * (mi !== nothing ? " for $(mi.specTypes)" : "");
                    idx=idx, detail=expr)
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
