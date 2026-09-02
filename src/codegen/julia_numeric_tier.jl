# parity(quarantine: Julia numeric semantics dart2wasm does not have — dart's `int` is one
# NumType.i64 (translator.dart:346): no Int128, no checked overflow, no first-class narrow
# ints in arithmetic; dart coerces only through convertType (translator.dart:1597) and the
# dart:_wasm shims (intrinsics.dart:710-929). Each registry here is consulted from ONE site
# in compile_call! with the intrinsifier's nullable-return contract (intrinsics.dart:1007):
# `nothing` means "not this tier's op", and the generic lowering continues.)

# ============================================================================
# Int128/UInt128 registry
# ============================================================================
#
# dart2wasm has no 128-bit integer type — the whole family is Julia-only quarantine, not
# a dart-anchored table (int128.jl's `emit_int128_*!` emitters carry their own per-op
# `parity(quarantine: ...)` headers). This registry is a pure move of the arms that used
# to live in `compile_call!`'s `is_func` ladder (each tagged `# table residue: Int128 →
# quarantine tier`, or reachable only when `is_128bit` since the non-128-bit case was
# already consumed by THE intrinsics table route in intrinsics_table.jl): op symbol →
# `(b, ctx, arg_type) -> WasmValType`, wrapping the existing `emit_int128_*!` call exactly
# as the arm invoked it, then reporting the result type it pushed (the struct type for
# arithmetic/bitwise/shift ops, `I32` for comparisons — mirrors `emit_intrinsic_binop!`'s
# contract).
const INT128_OPS = Dict{Symbol,Function}(
    :add_int   => (b, ctx, t) -> (emit_int128_add!(b, ctx, t);   _int128_structref(ctx, t)),
    :sub_int   => (b, ctx, t) -> (emit_int128_sub!(b, ctx, t);   _int128_structref(ctx, t)),
    :mul_int   => (b, ctx, t) -> (emit_int128_mul!(b, ctx, t);   _int128_structref(ctx, t)),
    :and_int   => (b, ctx, t) -> (emit_int128_and!(b, ctx, t);   _int128_structref(ctx, t)),
    :or_int    => (b, ctx, t) -> (emit_int128_or!(b, ctx, t);    _int128_structref(ctx, t)),
    :xor_int   => (b, ctx, t) -> (emit_int128_xor!(b, ctx, t);   _int128_structref(ctx, t)),
    :not_int   => (b, ctx, t) -> (emit_int128_not!(b, ctx, t);   _int128_structref(ctx, t)),
    :neg_int   => (b, ctx, t) -> (emit_int128_neg!(b, ctx, t);   _int128_structref(ctx, t)),
    :ctlz_int  => (b, ctx, t) -> (emit_int128_ctlz!(b, ctx, t);  _int128_structref(ctx, t)),
    :cttz_int  => (b, ctx, t) -> (emit_int128_cttz!(b, ctx, t);  _int128_structref(ctx, t)),
    :ctpop_int => (b, ctx, t) -> (emit_int128_ctpop!(b, ctx, t); _int128_structref(ctx, t)),
    :slt_int   => (b, ctx, t) -> (emit_int128_slt!(b, ctx, t);   I32),
    :sle_int   => (b, ctx, t) -> (emit_int128_sle!(b, ctx, t);   I32),
    :ult_int   => (b, ctx, t) -> (emit_int128_ult!(b, ctx, t);   I32),
    :ule_int   => (b, ctx, t) -> (emit_int128_ule!(b, ctx, t);   I32),
    :eq_int    => (b, ctx, t) -> (emit_int128_eq!(b, ctx, t);    I32),
    :ne_int    => (b, ctx, t) -> (emit_int128_ne!(b, ctx, t);    I32),
    :shl_int   => (b, ctx, t) -> (emit_int128_shl!(b, ctx, t);   _int128_structref(ctx, t)),
    :ashr_int  => (b, ctx, t) -> (emit_int128_ashr!(b, ctx, t);  _int128_structref(ctx, t)),
    :lshr_int  => (b, ctx, t) -> (emit_int128_lshr!(b, ctx, t);  _int128_structref(ctx, t)),
)

"""
    emit_int128_op!(b, ctx, op, arg_type, expr, idx) -> Union{WasmValType,Nothing}

THE Int128/UInt128 dispatch point, consulted from `compile_call!` right where the
`!is_128bit`-guarded intrinsics table routes leave off (mirrors `emit_intrinsic_binop!`
and `emit_intrinsic_unop!`'s nullable-return contract). Operands are already on `b`'s
stack (the same operand emission the residue arms relied on); `arg_type` is the
caller's already-inferred Int128/UInt128 source type (the same value the residue arms
were passed — recomputing it here would be a second `infer_value_type` call site, R3).
Returns `nothing` when `op` is not one of this tier's ops — the caller's legacy arm
(`bswap_int`'s loud reject) keeps handling it.

On a hit, finishes exactly like the intrinsics table routes: the SSA result gets the
same rebox check (a numeric result flowing into a ref-typed local boxes through
`emit_classid_box!`, keyed on the real Julia source type — dart's `convertType`).
"""
function emit_int128_op!(b::InstrBuilder, ctx, op::Symbol, arg_type, expr::Expr, idx::Int)::Union{WasmValType,Nothing}
    f = get(INT128_OPS, op, nothing)
    f === nothing && return nothing
    result = f(b, ctx, arg_type)::WasmValType

    # (The rebox link, mirroring the table binop/unop routes in intrinsics_table.jl.)
    local _rbx_li = get(ctx.ssa_locals, idx, nothing)
    if _rbx_li !== nothing
        local _rbx_off = _rbx_li - ctx.n_params
        if _rbx_off >= 0 && _rbx_off < length(ctx.locals) && _wt_is_ref(ctx.locals[_rbx_off + 1]) &&
           result in (I32, I64, F32, F64)
            (arg_type isa Type && isconcretetype(arg_type)) ||
                record_unsupported!(ctx, :unsupported_type,
                    "intrinsic result boxing lacks a concrete Julia source type";
                    idx=idx, detail=expr)
            emit_classid_box!(b, ctx, result, arg_type)
        end
    end
    return result
end
