# ============================================================================
# Value Compilation
# ============================================================================

"""
    static_wasm_type(val, ctx) -> WasmValType

THE single PRE-EMISSION static-type query (dart2wasm's `translateType(node.getStaticType())`,
intrinsics.dart:333): what wasm type WOULD `val` push, derived from locals/ssa_types/literals.
CONTRACT: use ONLY to make decisions BEFORE emitting (opcode/width selection, path choice) —
NEVER to describe a value that has already been emitted; the emission's own returned type
(`_compile_value_b`/`emit_value!`) is the truth there. The old name `infer_value_wasm_type`
(the post-emission re-guess anti-pattern, once ~265 callers) is retired and LOCKED at zero by
test/parity_ratchet.jl; every remaining caller of this function is a pre-emit decider.
"""
function static_wasm_type(val, ctx::AbstractCompilationContext)::WasmValType
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
            return static_wasm_type(actual_val, ctx)
        catch
            # If we can't resolve, fall back to AnyRef (internal polymorphic type)
            return AnyRef
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
        return AnyRef
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
        elseif val isa Int32 || val isa UInt32 || val isa Bool ||
               val isa Int8 || val isa UInt8 || val isa Int16 || val isa UInt16
            # P2-batch11: narrow ints were MISSING here — a literal like 0x00
            # fell through to AnyRef, so `return 0x00` failed
            # return_type_compatible(AnyRef, I32) and compiled to `unreachable`
            # (gap 46fd6782e95c). compile_value already emits i32.const for these.
            return I32
        elseif val isa Float64
            return F64
        elseif val isa Float32
            return F32
        elseif val isa QuoteNode
            # PURE-043: QuoteNode wraps a value - recursively determine its type.
            # D-001: IR reference types inside QuoteNodes are literal structs, not IR refs.
            inner = val.value
            if inner isa Core.SSAValue || inner isa Core.Argument || inner isa Core.SlotNumber
                T = typeof(inner)
                info = register_struct_type!(ctx.mod, ctx.type_registry, T)
                return ConcreteRef(info.wasm_type_idx, false)
            end
            return static_wasm_type(inner, ctx)
        elseif val isa Symbol || val isa String
            # parity(M9): String/Symbol constants are the CLASSED string struct
            str_type_idx = get_string_struct_type!(ctx.mod, ctx.type_registry)
            return ConcreteRef(str_type_idx, false)
        elseif val isa Type
            # PURE-4155: Type values (like Bool, Int64) compile to global.get (DataType struct ref).
            # Must check BEFORE isstructtype since typeof(Type) is DataType (a struct)
            # PURE-9063: Use $JlDataType when hierarchy is available
            dt_idx = get_datatype_type_idx(ctx.type_registry)
            return ConcreteRef(dt_idx, true)
        elseif val isa Core.TypeName
            # PURE-9064: TypeName constants compile to global.get ($JlTypeName struct ref)
            tn_idx = ctx.type_registry.jl_typename_idx
            if tn_idx !== nothing
                return ConcreteRef(tn_idx, true)
            end
            return StructRef
        elseif isstructtype(typeof(val))
            # PURE-043: Struct values compile to struct_new (ConcreteRef)
            return get_concrete_wasm_type(typeof(val), ctx.mod, ctx.type_registry)
        else
            return AnyRef
        end
    end
end

# ---------------------------------------------------------------------------
# WasmGC HeapType subtype lattice (mirrors dart2wasm pkg/wasm_builder type.dart
# `isSubtypeOf`). Three disjoint hierarchies:
#   extern  : its own top (only <: itself)
#   func    : its own top (only <: itself)
#   any  >  eq  >  {struct, array, i31}   ;  a CONCRETE struct/array <: its
#           abstract super (struct|array) <: eq <: any   ;  none is bottom.
# Numerics/packed are invariant (no subtyping). We model nullability as covariant
# only via dart2wasm's later coercion logic; this predicate is on the heap-type
# lattice (a===b is the nullable-equal base case), so we are conservative and
# return false for any numeric/packed involvement that isn't `===`.
# ---------------------------------------------------------------------------

# Classify the heap-type hierarchy of a ref-ish WasmValType into one of:
#   :any (the GC hierarchy: any/eq/struct/array/i31/none + concrete struct/array),
#   :extern, :func, or :other (NonNullAbstractRef whose byte we resolve, ExnRef, …).
_wt_is_ref(t::WasmValType)::Bool =
    t isa RefType || t isa ConcreteRef || t isa NonNullAbstractRef

# Is `t` an abstract GC-hierarchy RefType (rooted at `any`)?
_wt_gc_refkind(t::RefType)::Bool =
    t === AnyRef || t === EqRef || t === StructRef || t === ArrayRef || t === I31Ref

# --- nullability (P2) ---------------------------------------------------------
# Mirrors dart2wasm RefType.nullable. In WT only ConcreteRef carries a real bit;
# the RefType @enum values are nullable-shorthand (always nullable) and
# NonNullAbstractRef is the explicit non-null abstract variant. Numerics/packed
# are not refs (caller gates on _wt_is_ref first).
_wt_ref_nullable(t::ConcreteRef)::Bool = t.nullable
_wt_ref_nullable(::NonNullAbstractRef)::Bool = false
_wt_ref_nullable(::RefType)::Bool = true  # enum refs are nullable shorthand

# dart2wasm RefType.withNullability(false): the non-null variant of a ref type.
# ConcreteRef flips its bit; a nullable-shorthand RefType becomes the matching
# NonNullAbstractRef (same heap byte, non-null). Numerics/packed pass through.
_wt_drop_nullable(t::ConcreteRef)::WasmValType = ConcreteRef(t.type_idx, false)
_wt_drop_nullable(t::RefType)::WasmValType = NonNullAbstractRef(UInt8(t))
_wt_drop_nullable(t::NonNullAbstractRef)::WasmValType = t
_wt_drop_nullable(t::WasmValType)::WasmValType = t  # NumType / packed UInt8

# --- heap-type resolution (B6) ------------------------------------------------
# Resolve any ref-ish WasmValType to its abstract heap kind in
#   {:any,:eq,:struct,:array,:i31,:none, :extern,:noextern, :func,:nofunc, :exn,
#    :concrete_struct,:concrete_array, :unknown}.
# NonNullAbstractRef resolves via its heaptype_byte (which equals the RefType enum
# byte) so it participates by heap type rather than hitting a conservative-false.
function _wt_heap_kind(t, mod)::Symbol
    if t isa ConcreteRef
        idx = Int(t.type_idx)
        # `mod === nothing` only happens for the numeric-only builders (int128 etc.) whose
        # validators never see a ConcreteRef — but guard it anyway so a stray concrete ref
        # degrades to the default struct kind instead of crashing on `length(nothing.types)`.
        if mod !== nothing && idx + 1 >= 1 && idx + 1 <= length(mod.types)
            local ct = mod.types[idx + 1]
            ct isa ArrayType && return :concrete_array
            # fullstrict: a ConcreteRef to a FUNC type lives in the func hierarchy
            # (the closure vtable's `ref.cast (ref $sig)` on a funcref entry — valid
            # wasm the validator previously mis-hierarchied).
            ct isa FuncType && return :func
            return :concrete_struct
        else
            return :concrete_struct  # default concrete kind (struct; also for out-of-range / no-mod)
        end
    elseif t isa NonNullAbstractRef
        # Resolve the byte to its abstract heap kind (same bytes as the RefType enum).
        return _wt_heap_kind_of_byte(t.heaptype_byte)
    elseif t isa RefType
        return _wt_heap_kind_of_byte(UInt8(t))
    elseif t isa UInt8
        # fullstrict: RAW BYTE valtypes (the vtable's funcref fields etc.) resolve
        # through the same byte table
        return _wt_heap_kind_of_byte(t)
    else
        return :unknown
    end
end

function _wt_heap_kind_of_byte(byte::UInt8)::Symbol
    byte == UInt8(AnyRef)    ? :any    :
    byte == UInt8(EqRef)     ? :eq     :
    byte == UInt8(StructRef) ? :struct :
    byte == UInt8(ArrayRef)  ? :array  :
    byte == UInt8(I31Ref)    ? :i31    :
    byte == UInt8(ExternRef) ? :extern :
    byte == UInt8(FuncRef)   ? :func   :
    byte == UInt8(ExnRef)    ? :exn    : :unknown
end

# The disjoint top of a heap kind's hierarchy. WasmGC has four independent reference
# hierarchies — `any` (eq/struct/array/i31 + all concrete structs/arrays), `func`,
# `extern`, `exn` — that share no common supertype. Used by `_wt_same_hierarchy` for
# `ref.cast` plausibility (P13).
function _wt_hierarchy_top(kind::Symbol)::Symbol
    kind === :func   ? :func   :
    kind === :extern ? :extern :
    kind === :exn    ? :exn    :
    (kind === :any || kind === :eq || kind === :struct || kind === :array ||
     kind === :i31 || kind === :concrete_struct || kind === :concrete_array) ? :any :
    :unknown
end

"""
    _wt_same_hierarchy(a, b, mod) -> Bool

Whether two ref types live in the SAME WasmGC reference hierarchy (share a top:
any / func / extern / exn). This is the validity condition for `ref.cast` (P13): a
cross-hierarchy cast (e.g. funcref → structref, or externref → a GC struct without an
`extern.convert_any` first) can never be expressed and is a validation error. NOTE this
is deliberately NOT a subtype check — a within-`any` cast between two unrelated concrete
structs is VALID wasm (it just always traps at runtime), so `wasm_subtype` either-way
would wrongly reject it. dart2wasm verifies cast plausibility the same way (one
hierarchy), leaving always-trapping casts to the runtime.
"""
function _wt_same_hierarchy(a, b, mod)::Bool
    ta = _wt_hierarchy_top(_wt_heap_kind(a, mod))
    ta !== :unknown && ta === _wt_hierarchy_top(_wt_heap_kind(b, mod))
end

# The declared supertype index of a ConcreteRef's type, or `nothing`. Only
# StructType carries a supertype_idx in WT (set by set_struct_supertypes! /
# create_jl_type_hierarchy!); arrays never declare one.
function _wt_concrete_supertype_idx(idx::Integer, mod)
    mod === nothing && return nothing
    i = Int(idx) + 1
    (i >= 1 && i <= length(mod.types)) || return nothing
    ct = mod.types[i]
    ct isa StructType ? ct.supertype_idx : nothing
end

# dart2wasm DefType.isSubtypeOf: walk the DECLARED supertype chain of a concrete
# ConcreteRef `a` and return true iff a concrete `b` (same type_idx) is reached.
# Pure nominal walk — does NOT consult the abstract super (that's handled by the
# heap-kind lattice in wasm_subtype). Depth-guarded against malformed cycles.
function _wt_concrete_chain_reaches(a_idx::Integer, b_idx::Integer, mod)::Bool
    a_idx == b_idx && return true
    cur = _wt_concrete_supertype_idx(a_idx, mod)
    depth = 0
    while cur !== nothing && depth < 256
        cur == UInt32(b_idx) && return true
        cur = _wt_concrete_supertype_idx(cur, mod)
        depth += 1
    end
    return false
end

"""
    wasm_subtype(a, b, mod) -> Bool

Whether a value of WasmGC type `a` may be used where `b` is expected (an UPCAST,
which is free / requires no instruction). Mirrors dart2wasm's
`RefType.isSubtypeOf` + `DefType.isSubtypeOf` + `HeapType.isSubtypeOf` exactly:

  * **Nullability (P2):** a nullable ref is NOT a subtype of a non-null target —
    `nullable(a) && !nullable(b) ⇒ false` (dart2wasm RefType.isSubtypeOf L202).
  * **Supertype chain (F4):** a concrete `a` walks its DECLARED `supertype_idx`
    chain (StructType) and is `<:` any concrete `b` on that chain
    (dart2wasm DefType.isSubtypeOf L621-624). When the nominal chain runs out it
    falls to the abstract super (struct/array) ⇒ eq ⇒ any.
  * **Abstract lattice:** any > eq > {struct, array, i31}; extern/func own tops;
    exn is its own thing.
  * **B6:** NonNullAbstractRef participates by its resolved heap byte (no longer a
    conservative-false / MethodError path).

`mod.types[idx+1] isa ArrayType` distinguishes a ConcreteRef's struct-vs-array
kind. Any numeric/packed involvement (unless `a === b`) ⇒ false.
"""
function wasm_subtype(a::WasmValType, b::WasmValType, mod)::Bool
    a === b && return true
    # Numerics/packed are invariant: anything not caught by === above is not a subtype.
    (!_wt_is_ref(a) || !_wt_is_ref(b)) && return false

    # --- nullability (P2): dart2wasm RefType.isSubtypeOf — a nullable source is
    # never a subtype of a non-null target (the null value could not inhabit it). ---
    (_wt_ref_nullable(a) && !_wt_ref_nullable(b)) && return false

    # --- heap-type comparison (the rest of dart2wasm's RefType.isSubtypeOf is
    # heapType.isSubtypeOf, nullability already handled). ---
    ka = _wt_heap_kind(a, mod)
    kb = _wt_heap_kind(b, mod)
    (ka === :unknown || kb === :unknown) && return false

    # --- extern hierarchy (its own top: only extern <: extern) ---
    (ka === :extern || kb === :extern) && return ka === :extern && kb === :extern
    # --- func hierarchy (its own top) ---
    (ka === :func || kb === :func) && return ka === :func && kb === :func
    # --- exn: its own thing (only the === case, already handled) ---
    (ka === :exn || kb === :exn) && return false

    # --- the `any` GC hierarchy ---
    # Concrete b: a must be a concrete on b's declared supertype chain (F4).
    if kb === :concrete_struct || kb === :concrete_array
        (ka === :concrete_struct || ka === :concrete_array) || return false
        return _wt_concrete_chain_reaches(Int(a.type_idx), Int(b.type_idx), mod)
    end
    # Map a concrete a to its abstract kind for the abstract-target comparison.
    ka_abs = ka === :concrete_struct ? :struct :
             ka === :concrete_array  ? :array  : ka
    # b === any  : everything in this hierarchy is <: any.
    kb === :any && return true
    # b === eq   : eq's subtypes are eq, struct, array, i31 (and concretes) — all but `any`.
    kb === :eq  && return ka_abs !== :any
    # b is struct: only struct (abstract or concrete-struct) is <: struct.
    kb === :struct && return ka_abs === :struct
    # b is array : only array (abstract or concrete-array) is <: array.
    kb === :array  && return ka_abs === :array
    # b is i31   : only i31 is <: i31 (concretes are struct/array, never i31).
    kb === :i31    && return ka_abs === :i31
    return false
end

"""
Check if a value type can satisfy a function's return type — the principled
dart2wasm stance (replacing the old special-case pile). Compatible iff:
  * `value === return`; OR
  * both are reference types (any ref↔ref is convertible — upcast free, downcast
    via ref.cast, extern↔any via the convert ops — emit_return_coerced! picks); OR
  * a WT numeric WIDENING pair (Julia mixed int/float widths; dart2wasm itself
    throws on numeric→numeric, but WT needs the widening ladder); OR
  * a numeric value flowing into a ref return (boxed for externref / dummied for
    a dead Union arm — matches dart2wasm's instantiateDummyValue).
Otherwise false.
"""
function return_type_compatible(value_type::WasmValType, return_type::WasmValType)::Bool
    value_type === return_type && return true
    val_is_ref = _wt_is_ref(value_type)
    ret_is_ref = _wt_is_ref(return_type)
    # Both refs: any ref↔ref conversion is expressible (upcast/downcast/extern↔any).
    if val_is_ref && ret_is_ref
        return true
    end
    # WT numeric widening ladder (value narrower → return wider).
    if (value_type === I32 && return_type === I64) ||
       (value_type === I64 && return_type === F64) ||
       (value_type === I32 && return_type === F64) ||
       (value_type === F32 && return_type === F64) ||
       (value_type === I64 && return_type === F32) ||
       (value_type === I32 && return_type === F32)
        return true
    end
    # Numeric value into a ref return: boxed (externref) or dummied (dead Union arm).
    if !val_is_ref && ret_is_ref
        return true
    end
    haskey(ENV, "WT_TRACE_RETCOMPAT") && println(stderr, "RETCOMPAT false: val=$value_type ret=$return_type")
    return false
end

"""
    convert_type!(b, from, to, ctx)

The single coercion funnel (dart2wasm `translator.dart convertType`). Given a value of wasm
type `from` already on the stack, emit the ops to coerce it to `to`. Byte-identical extraction
of the coercion body that was copy-pasted across ~21 sites (PARITY_LEDGER B1):

  * `from === to` OR `wasm_subtype(from,to)` (upcast) ⇒ emit NOTHING.
  * ref→ref: extern↔any bridge / `ref.as_non_null` (nullability-only narrowing, P9) /
    `ref.cast` (downcast). Mirrors `emit_return_coerced!`'s ref→ref branch (Loop A).
  * numeric→numeric: WT's 6-branch widening ladder (dart2wasm throws here; Julia widens).

Does NOT handle numeric→ref boxing nor ref→numeric unboxing — those stay at their sites
(they need a value/typeId, not just a stack coercion). Returns `b`.
"""
function convert_type!(b::InstrBuilder, from::WasmValType, to::WasmValType,
                       ctx::AbstractCompilationContext; from_julia::Union{Type,Nothing}=nothing)
    if !_wt_is_ref(from) && _wt_is_ref(to)
        # numeric→ref: BOX (F-ii). dart2wasm convertType boxing arm — box the value into the
        # canonical {classId,value} struct (real classId when from_julia is known), then upcast
        # the box ref to `to` (the box subtypes $JlBase, so any/eq/struct targets are free).
        box_idx = emit_classid_box!(b, ctx, from, from_julia)
        convert_type!(b, ConcreteRef(UInt32(box_idx), false), to, ctx)
        return b
    elseif _wt_is_ref(from) && !_wt_is_ref(to)
        # ref→numeric: UNBOX (F-ii). Narrow to the `to` numeric box, read its value field.
        # march5 F8: an externref source crosses the boundary first (the box lives
        # under anyref; ref.cast from externref is not wasm-valid).
        from === ExternRef && any_convert_extern!(b)
        emit_classid_unbox!(b, ctx, to)
        return b
    elseif _wt_is_ref(from) && _wt_is_ref(to)
        # march16 (dart convertType, closure meets a top type): a KNOWN closure's
        # captured struct erasing to any/eq/struct becomes the closure OBJECT
        # {classId, context, vtable} — the value stays dynamically callable.
        if (to === AnyRef || to === EqRef || to === StructRef) && from isa ConcreteRef &&
           maybe_wrap_closure!(b, ctx, from_julia)
            return b
        end
        # parity(M9): the STRING arms — the classed string {classId,data} vs its byte
        # array. Ops consume/produce the array; values carry the class (dart: methods
        # read the class's array field; convertType adjusts at every boundary).
        local _ssi = ctx.type_registry.string_struct_idx
        local _sai = ctx.type_registry.string_array_idx
        if _ssi !== nothing && _sai !== nothing
            local _to_is_sarr = to isa ConcreteRef && to.type_idx == _sai
            local _to_is_sstr = to isa ConcreteRef && to.type_idx == _ssi
            local _from_is_sarr = from isa ConcreteRef && from.type_idx == _sai
            local _from_is_sstr = from isa ConcreteRef && from.type_idx == _ssi
            if _to_is_sarr && !_from_is_sarr
                # any string-ish ref → its data array: narrow to $JlString, read data
                # (march12: an externref source crosses the boundary first)
                from === ExternRef && any_convert_extern!(b)
                _from_is_sstr || ref_cast!(b, Int64(_ssi), false)
                struct_get!(b, UInt32(_ssi), UInt32(2), ConcreteRef(UInt32(_sai), true))
                return b
            elseif _from_is_sarr && !_to_is_sarr
                # a bare data array flowing to a value position: WRAP (the one producer),
                # then adjust the struct ref to `to` normally
                emit_string_wrap!(b, ctx)
                _to_is_sstr && return b
                convert_type!(b, ConcreteRef(UInt32(_ssi), false), to, ctx)
                return b
            end
        end
        # dart2wasm convertType for ref→ref (with WT's extern↔any boundary ops).
        if to === ExternRef && from !== ExternRef
            # march16: a KNOWN closure crossing to extern wraps first (the seam)
            from isa ConcreteRef && maybe_wrap_closure!(b, ctx, from_julia)
            # any→extern at the JS boundary.
            extern_convert_any!(b)
        elseif from === ExternRef && to !== ExternRef
            # extern→any boundary, then narrow if the GC target is below `any`.
            any_convert_extern!(b)
            if !wasm_subtype(AnyRef, to, ctx.mod)
                if to isa ConcreteRef
                    ref_cast!(b, Int64(to.type_idx), to.nullable)
                elseif to isa RefType && _wt_gc_refkind(to)
                    ref_cast!(b, to, true)
                end
                # FuncRef/NonNullAbstractRef target after extern→any: nothing principled to emit.
            end
        elseif wasm_subtype(from, to, ctx.mod)
            # Upcast is free — emit nothing.
        elseif wasm_subtype(_wt_drop_nullable(from), to, ctx.mod)
            # dart2wasm convertType L847-849: the ONLY thing blocking the upcast is
            # nullability (heap types compatible, source nullable → non-null target).
            # A null-check (ref.as_non_null) suffices — cheaper than a full ref.cast (P9).
            ref_as_non_null!(b)
        else
            # Downcast.
            if to isa ConcreteRef
                # march16: a downcast to a CLOSURE's captured struct may receive the
                # closure OBJECT (the erasure seam wrapped it) — unwrap via .context
                # when the runtime value is the object; direct cast otherwise.
                local _cbase = ctx.type_registry.closure_base_idx
                # unwrap exists ONLY where wrapping exists: no vtable globals in this
                # module → no closure objects can flow → the plain downcast (the arm
                # changed emission for Base-internal closure structs otherwise)
                local _cvg = ctx.type_registry.closure_vtable_globals
                local _to_closure = _cbase !== nothing && _cvg !== nothing && !isempty(_cvg) && begin
                    local _tcj = nothing
                    for (T, info) in ctx.type_registry.structs
                        if info.wasm_type_idx == to.type_idx && is_closure_type(T)
                            _tcj = T; break
                        end
                    end
                    _tcj !== nothing
                end
                if _to_closure
                    # if (ref.test base) → base.context → cast; else → cast direct
                    local _uw = allocate_local!(ctx, AnyRef)
                    local_tee!(b, UInt32(_uw))
                    ref_test!(b, Int64(_cbase), false)
                    if_!(b, to)
                    local_get!(b, UInt32(_uw))
                    ref_cast!(b, Int64(_cbase), false)
                    struct_get!(b, _cbase, UInt32(2), AnyRef)   # .context
                    ref_cast!(b, Int64(to.type_idx), to.nullable)
                    else_!(b)
                    local_get!(b, UInt32(_uw))
                    ref_cast!(b, Int64(to.type_idx), to.nullable)
                    end_block!(b)
                else
                    ref_cast!(b, Int64(to.type_idx), to.nullable)
                end
            elseif to isa RefType && _wt_gc_refkind(to)
                ref_cast!(b, to, true)
            end
            # FuncRef / NonNullAbstractRef target: no ref.cast emitted.
        end
    else
        # numeric→numeric: WT's widening ladder (dart2wasm throws here; Julia widens).
        if from === I32 && to === I64
            num!(b, Opcode.I64_EXTEND_I32_S)
        elseif from === I64 && to === F64
            num!(b, Opcode.F64_CONVERT_I64_S)
        elseif from === I32 && to === F64
            num!(b, Opcode.F64_CONVERT_I32_S)
        elseif from === F32 && to === F64
            num!(b, Opcode.F64_PROMOTE_F32)
        elseif from === I64 && to === F32
            num!(b, Opcode.F32_CONVERT_I64_S)
        elseif from === I32 && to === F32
            num!(b, Opcode.F32_CONVERT_I32_S)
        # march5 F8: the NARROWING arms (dart throws here; Julia call boundaries
        # genuinely narrow — e.g. an Int64 value meeting an Int32 param)
        elseif from === I64 && to === I32
            num!(b, Opcode.I32_WRAP_I64)
        elseif from === F64 && to === F32
            num!(b, Opcode.F32_DEMOTE_F64)
        end
    end
    return b
end

"""
    coerce_stack_top!(b, expected, ctx; from_julia=nothing)

Adjust the value most recently emitted into `b` to a storage/call boundary type. The
builder's tracked stack is the sole source of the actual type; callers never re-derive it
from Julia IR. This is the post-emission half of dart's `wrap` chokepoint for producers
whose emission and sink are structurally separated.
"""
function coerce_stack_top!(b::InstrBuilder, expected::WasmValType,
                           ctx::AbstractCompilationContext;
                           from_julia::Union{Type,Nothing}=nothing)::WasmValType
    isempty(b.v.stack) && throw(ArgumentError("cannot coerce an empty emitted-value stack"))
    actual = b.v.stack[end]
    actual === expected || convert_type!(b, actual, expected, ctx; from_julia=from_julia)
    return expected
end

# Unknown source/target type (e.g. get_phi_edge_wasm_type returned `nothing`): the
# inline ladders this funnel replaces all emit nothing in that case (no `=== I64` etc.
# branch matches), so a no-op preserves byte-identity.
convert_type!(b::InstrBuilder, ::Nothing, ::Any, ::AbstractCompilationContext) = b
convert_type!(b::InstrBuilder, ::WasmValType, ::Nothing, ::AbstractCompilationContext) = b

# ============================================================================
# Single-source classId box/unbox/discriminate (Loop B funnel — dev/LOOP_B_DESIGN.md).
# dart2wasm's convertType boxing: a dynamic value is a {classId:i32@0, value@1} struct
# subtyping the Top struct ($JlBase); type-tests read classId off the box. These are the
# ONE producer + ONE consumer that ALL boxing/discrimination routes through. The former ~41
# scattered emit_box_type_id!+struct_new ladders (flow/conditionals/statements return boxes,
# stackified phi-edge boxes, calls/invoke arg+ret boxes, tuple-field boxes) have ALL been
# collapsed onto this producer; the old emit_box_type_id! helper is DELETED (census F5) — its
# wasm-rep classId fallback (values.jl below). Added DORMANT in F-i (byte-identical); wired via
# convert_type!'s box/unbox arms + the isa sites in F-ii; the site sweep finished in Loop C.
# ============================================================================

"""
    emit_classid_box!(b, ctx, wasm_type, julia_type) -> box_type_idx

Box the numeric value on the stack into a `{classId:i32, value:wasm_type}` struct (the
canonical numeric box, which subtypes `\$JlBase`). Stores the REAL Julia-type classId when
`julia_type` is given; otherwise the inline wasm-rep-id fallback (width-default type) for sites
that don't yet carry the Julia type — those distinguish only by width until they migrate.
Pushes the box ref. This is THE single boxing producer (dart `convertType` box arm).
"""
function emit_classid_box!(b::InstrBuilder, ctx::AbstractCompilationContext,
                           wasm_type::WasmValType, julia_type::Union{Type,Nothing})
    box_idx = get_numeric_box_type!(ctx.mod, ctx.type_registry, wasm_type)
    sc = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, wasm_type)
    builder_set_local_type!(b, sc, wasm_type)
    local_set!(b, sc)                       # save the value
    if julia_type === nothing
        # fallback: wasm-rep id (the width's default Julia type)
        emit_type_id!(b, ctx.type_registry,
                      wasm_type === I32 ? Int32 : wasm_type === I64 ? Int64 :
                      wasm_type === F32 ? Float32 : wasm_type === F64 ? Float64 : Any)
    else
        emit_type_id!(b, ctx.type_registry, julia_type)            # REAL classId
    end
    local_get!(b, sc)                       # reload the value (field 1)
    # Declare the REAL stack effect ([classId:i32, value] → box ref) — an empty field list
    # left the operands undeclared, so typed callers saw a phantom 3-value stack and the
    # wrap templates mis-fired their multi-value guard (any_push_mixed_dyn → ref.null).
    struct_new!(b, box_idx, WasmValType[I32, wasm_type])
    return box_idx
end

"""
    emit_classid_unbox!(b, ctx, to_wasm)

Unbox: the boxed ref is on the stack; narrow to the `to_wasm` numeric box and read its
value field (field 1). THE single unboxing consumer (dart `convertType` unbox arm). `nullable`
selects the ref.cast form: `false` (default) traps on a null ref — correct inside an isa/ref.test
guard; `true` permits null (the permissive external/dynamic call boundary). An extern→any prefix
(`any_convert_extern!`), when the source is externref, stays in the caller (a distinct coercion).
"""
function emit_classid_unbox!(b::InstrBuilder, ctx::AbstractCompilationContext, to_wasm::WasmValType;
                             nullable::Bool=false)
    return emit_classid_unbox!(b, ctx.mod, ctx.type_registry, to_wasm; nullable=nullable)
end
# Core (mod, registry) method — the unbox needs no scratch local, so it works outside the main
# codegen context too (e.g. the dispatch-wrapper subsystem, which carries mod + registry, not ctx).
function emit_classid_unbox!(b::InstrBuilder, mod::WasmModule, registry::TypeRegistry,
                             to_wasm::WasmValType; nullable::Bool=false)
    box_idx = get_numeric_box_type!(mod, registry, to_wasm)
    ref_cast!(b, Int64(box_idx), nullable)
    struct_get!(b, UInt32(box_idx), UInt32(1), to_wasm)
    return b
end

"""
    emit_string_wrap!(b, mod, registry)

parity(M9) — the classed string PRODUCER (dart: String IS a class): with the UTF-8
byte array on the stack, wrap it as `\$JlString{classId(String), 0, data}`. The ONE
place a string value is born; every string producer routes here.
"""
function emit_string_wrap!(b::InstrBuilder, mod::WasmModule, registry::TypeRegistry,
                           scratch::Integer)
    struct_idx = get_string_struct_type!(mod, registry)
    arr_idx = get_string_array_type!(mod, registry)
    builder_set_local_type!(b, Int(scratch), ConcreteRef(arr_idx, true))
    local_set!(b, scratch)
    i32_const!(b, Int64(ensure_type_id!(registry, String)))
    i32_const!(b, 0) # identityHash: lazily assigned by objectid
    local_get!(b, scratch)
    struct_new!(b, struct_idx, WasmValType[I32, I32, ConcreteRef(arr_idx, true)])
    return b
end

"""ctx convenience: allocates the scratch local itself."""
function emit_string_wrap!(b::InstrBuilder, ctx::AbstractCompilationContext)
    arr_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    sc = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, ConcreteRef(arr_idx, true))
    return emit_string_wrap!(b, ctx.mod, ctx.type_registry, sc)
end

"""
    emit_string_data!(b, mod, registry; from_anyref=false)

parity(M9) — the classed string CONSUMER: with a string value on the stack
(`\$JlString` or anyref), read its `data` byte array. String OPS call this once at
entry and work on the array — dart's methods read the class's array field the same way.
"""
function emit_string_data!(b::InstrBuilder, mod::WasmModule, registry::TypeRegistry;
                           from_anyref::Bool=false)
    struct_idx = get_string_struct_type!(mod, registry)
    arr_idx = get_string_array_type!(mod, registry)
    from_anyref && ref_cast!(b, Int64(struct_idx), false)
    struct_get!(b, UInt32(struct_idx), UInt32(2), ConcreteRef(arr_idx, true))
    return b
end

"""
    emit_classid_range_check!(b, low, high)

dart's `emitClassIdRangeCheck` (code_generator.dart:3847-3884), THE single abstract-type
discriminator: with the classId (i32) on the stack, a single id lowers to `i32.const id;
i32.eq`; a dense DFS range lowers to the 3-instruction unsigned window
`i32.const low; i32.sub; i32.const (high-low); i32.le_u` (an id below `low` wraps to a huge
unsigned value, so one comparison covers both bounds — no temp local, no i32.and).
"""
function emit_classid_range_check!(b::InstrBuilder, low::Integer, high::Integer)
    if low == high
        i32_const!(b, Int64(low))
        num!(b, Opcode.I32_EQ)
    else
        i32_const!(b, Int64(low))
        num!(b, Opcode.I32_SUB)
        i32_const!(b, Int64(high - low))
        num!(b, Opcode.I32_LE_U)
    end
    return b
end

"""march9 — dart's MULTI-range check (code_generator.dart:3862-3883): the DFS range
plus the post-DFS drift ids. typeId is on the stack; result i32. Uses a scratch local
when extras exist."""
function emit_classid_ranges!(b::InstrBuilder, ctx::AbstractCompilationContext,
                              low::Integer, high::Integer, extras::Vector{Int32})
    isempty(extras) && return emit_classid_range_check!(b, low, high)
    sc = allocate_local!(ctx, I32)
    local_tee!(b, sc)
    emit_classid_range_check!(b, low, high)
    for x in extras
        (low <= x <= high) && continue
        local_get!(b, UInt32(sc))
        i32_const!(b, Int64(x))
        num!(b, Opcode.I32_EQ)
        num!(b, Opcode.I32_OR)
    end
    return b
end

"""
    emit_isa_classid!(b, ctx, box_idx, check_type)

`isa`/`typeof`/`===` discriminator for a boxed numeric: is the value the box AND is its
classId (field 0) == `check_type`'s DFS id? Guarded by `ref.test` so a non-box value yields
0 (no trap). Same-wasm-rep types SHARE `box_idx`, so this classId read — NOT `ref.test` of
the struct — is what distinguishes Bool/Int8/Int16/Int32/Char. THE single discriminator.
"""
function emit_isa_classid!(b::InstrBuilder, ctx::AbstractCompilationContext,
                           box_idx::Integer, check_type::Type)
    tid = ensure_type_id!(ctx.type_registry, check_type)
    tmp = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, AnyRef)
    builder_set_local_type!(b, tmp, AnyRef)
    local_tee!(b, tmp)
    ref_test!(b, Int64(box_idx), false)
    if_!(b, I32)
    local_get!(b, tmp)
    ref_cast!(b, Int64(box_idx), false)
    struct_get!(b, UInt32(box_idx), UInt32(0), I32)   # field 0 = classId
    i32_const!(b, Int64(tid))
    num!(b, Opcode.I32_EQ)
    else_!(b)
    i32_const!(b, 0)
    end_block!(b)
    return b
end

"""
    emit_return_coerced!(b, val, ctx)

Emit a ReturnNode value `val` coerced to the function's wasm return type. Extracted from ~9
identical copies (cleanup Loop 4). PURE-315: a numeric value into a ref return → synthesize
ref.null / extern-box. Else if the value type cannot satisfy the return type → `unreachable`
(trap). Else compile the value + the numeric-widening / extern-convert coercion ladder, then
`return`. Byte-identical to the inlined blocks it replaces.
"""
function emit_return_coerced!(b::InstrBuilder, val, ctx::AbstractCompilationContext)
    # parity(M2): THE wrap for returns — emit typed, coerce the ACTUAL type through the ONE
    # convert_type! funnel, return. Deletes the infer_value_wasm_type pre-guess and the
    # numeric→ConcreteRef ref.null VALUE DROP (the funnel boxes value-preservingly; an
    # ill-typed non-box concrete target now traps loudly instead of silently nulling).
    func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
    # `nothing` into a ref return → typed null (dart returns null, never a boxed zero).
    if _wt_is_ref(func_ret_wasm) && is_nothing_value(val, ctx)
        if func_ret_wasm isa ConcreteRef
            ref_null!(b, Int64(func_ret_wasm.type_idx), func_ret_wasm)
        else
            ref_null!(b, func_ret_wasm)
        end
        return_!(b)
        return b
    end
    ty = emit_value!(b, val, ctx)
    # numeric→ref precedence (boxing) is checked before compatibility, as before.
    needs_box = ty !== nothing && !_wt_is_ref(ty) && _wt_is_ref(func_ret_wasm)
    if ty === nothing || (!needs_box && !return_type_compatible(ty, func_ret_wasm))
        # dead/unsatisfiable path (unresolvable value or dead Union arm) — trap.
        unreachable!(b)  # structural trap (dart-legit dead path)
    else
        ty === func_ret_wasm || convert_type!(b, ty, func_ret_wasm, ctx)
        return_!(b)
    end
    return b
end

"""
PURE-908: Compile a GotoIfNot condition to i32.
When the condition SSA value has an anyref/externref local (because Julia typed it as Any),
the raw compile_value would push anyref, but i32.eqz needs i32. This helper unboxes via
ref.cast + struct.get when needed.
"""
# MIGRATED to InstrBuilder (Phase 1, dart2wasm-style typed emission). The shared
# builder is threaded once the callers migrate; for now a fragment builder validates
# this emitter's stack in isolation (compile_value bridged via its known pushed type).
"""THE condition visitor (march4): emit the i32 condition directly into the target builder."""
function compile_condition_to_i32!(b::InstrBuilder, cond, ctx::AbstractCompilationContext)
    if haskey(ENV, "WT_TRACE_CONDSTUB") && ctx.last_stmt_was_stub
        println(stderr, "CONDSTUB cond=", first(repr(cond), 30))
        for fr in stacktrace()[2:9]
            println(stderr, "   ", fr)
        end
    end
    set_context!(b, "GotoIfNot cond → i32")
    emit_value!(b, cond, ctx)
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
                    # Value is anyref/externref but should be i32 (Bool). Unbox via the one consumer.
                    local_type === ExternRef && any_convert_extern!(b)
                    emit_classid_unbox!(b, ctx, I32; nullable=true)
                elseif local_type isa ConcreteRef
                    # PURE-6025: tagged-union concrete ref → extract i32 tag from field 1.
                    type_idx = local_type.type_idx
                    if type_idx + 1 <= length(ctx.mod.types)
                        mod_type = ctx.mod.types[type_idx + 1]
                        if mod_type isa StructType && length(mod_type.fields) >= 3 && mod_type.fields[2].valtype === I32
                            struct_get!(b, type_idx, 1, I32)  # field 1 (tag, after typeId at 0)
                        else
                            drop!(b); i32_const!(b, 0)        # not a tagged union — default
                        end
                    else
                        drop!(b); i32_const!(b, 0)            # unknown type — default
                    end
                elseif local_type === StructRef || local_type === ArrayRef
                    drop!(b); i32_const!(b, 0)                # abstract ref — default
                end
            end
        end
    end
    return b
end

"""
Compile a value reference (SSA, Argument, or Literal).
"""
# object-identity stack for struct-constant compilation (cycle/depth guard)
const _VALUE_COMPILE_STACK = Vector{Any}()

# B4/Loop C — the typed value channel (dart2wasm `wrap`/`node.accept1 -> w.ValueType`,
# code_generator.dart:879): the body builds into the typed InstrBuilder `b`, so the type it
# pushes IS a byproduct of emission = `b.v.stack[end]`. `_compile_value_b` returns that
# builder, and `emit_value!` is the sole merge/coercion channel.

"""
    emit_value!(b, val, ctx) -> Union{WasmValType,Nothing}

Compile `val` and splice it into builder `b`, declaring the stack effect with the type the
emission ACTUALLY pushed (`_compile_value_b`'s tracked result) — NOT a re-guess via
`infer_value_wasm_type`. The single replacement for the `emit_raw!(b, compile_value;
pushes=WasmValType[static_wasm_type(v,ctx)])` anti-pattern (Loop C — the typed channel).
Returns the pushed type. Output is byte-identical (the value bytes are the same; only the
validator's stack type is now the truth instead of a re-derivation).
"""
function emit_value!(b::InstrBuilder, val, ctx::AbstractCompilationContext)::Union{WasmValType,Nothing}
    # march3: THE typed merge — valid because the WT_AUDIT_VALUE_STACK sweep
    # proved _compile_value_b's tracked stack honest (zero liars across smoke +
    # the heaviest shards after the struct_new! mod-resolving fix).
    vb = _compile_value_b(val, ctx)
    ty = isempty(vb.v.stack) ? nothing : vb.v.stack[end]
    append_builder!(b, vb)
    return ty
end

"""
    emit_value!(b, val, ctx, expected; from_julia=nothing) -> WasmValType

THE wrap chokepoint (dart `CodeGenerator.wrap`, code_generator.dart:879-888): emit `val`, take
the type it ACTUALLY pushed (the emission byproduct), coerce actual→`expected` through the ONE
`convert_type!` funnel (dart `convertType`), and return `expected`. This is the M2 primitive
that replaces the `emit_raw!(b, compile_value; pushes=[re-guess])` + hand-rolled
coercion-ladder anti-pattern — the type is never re-derived after emission.

`from_julia` (when the caller knows the value's Julia type) lets the boxing arm stamp the REAL
classId. A `nothing` actual type means the emit produced no single result (dead/unreachable
path — the `unreachable` is already emitted); `expected` is returned so the declared stack
shape stays consistent, matching dart's posture that unreachable code still validates.
"""
function emit_value!(b::InstrBuilder, val, ctx::AbstractCompilationContext,
                     expected::WasmValType; from_julia::Union{Type,Nothing}=nothing)::WasmValType
    # march8 note: a decide-before-emit Nothing arm lived here briefly and was
    # REVERTED (gate-caught, Dates corpus): its SSA-shape detection misfired across
    # contexts, swallowing live values. Rebuild it WITH the weave folds it serves,
    # keyed on ctx.ssa_types (the typed slot), not statement sniffing.
    ty = emit_value!(b, val, ctx)
    ty === nothing && return expected
    if ty !== expected
        # Like dart's wrap(node, expectedType), the single wrap funnel owns both
        # the emitted Wasm type and the node's static source type. Callers must
        # not independently rediscover source types just to request a coercion.
        from_julia === nothing && (from_julia = infer_value_type(val, ctx))
        convert_type!(b, ty, expected, ctx; from_julia=from_julia)
    end
    return expected
end

"""Widen the stored unsigned i32 Object identity field to Julia's UInt64 objectid result."""
extend_identity_hash_to_u64!(b::InstrBuilder) = num!(b, Opcode.I64_EXTEND_I32_U)

# Physical collection lengths are i32 in WasmGC and Int64 in Julia. Keep these
# representation conversions beside the central value/conversion machinery so
# collection lowerers do not grow independent coercion ladders.
narrow_length_to_i32!(b::InstrBuilder) = num!(b, Opcode.I32_WRAP_I64)
widen_length_to_i64!(b::InstrBuilder) = num!(b, Opcode.I64_EXTEND_I32_U)

"""
    _ctx_builder(ctx, name) -> InstrBuilder

fullstrict: THE codegen builder constructor — mod + seeded params + the LIVE locals
provider, so the tracker always reads ctx truth (bare builders guessed AnyRef for
locals allocated after creation — the largest residual mismatch class).
"""
function _ctx_builder(ctx::AbstractCompilationContext, name::String)::InstrBuilder
    local b = InstrBuilder(; func_name=name, mod=ctx.mod)
    _seed_builder_locals!(b, ctx)
    return b
end

"""
    _seed_builder_locals!(b, ctx)

Teach a fresh value-builder the function's REAL local types (params via the same julia→wasm
mapping the function header used, then ctx.locals), so `local_get!` pushes the TRUE type
instead of the AnyRef unknown-local fallback. This makes the typed channel's returned type
(`b.v.stack[end]`) truthful for the most common emission — `local.get` — and therefore safe
to DRIVE `convert_type!` coercions from (dart: `local.type` is authoritative because dart's
builder always knows its locals).
"""
function _seed_builder_locals!(b::InstrBuilder, ctx::AbstractCompilationContext)
    for i in 1:ctx.n_params
        i <= length(ctx.arg_types) || break
        builder_set_local_type!(b, i - 1,
            get_concrete_wasm_type(ctx.arg_types[i], ctx.mod, ctx.type_registry))
    end
    for (k, t) in enumerate(ctx.locals)
        builder_set_local_type!(b, ctx.n_params + k - 1, t)
    end
    # fullstrict: the LIVE provider — locals allocated AFTER this builder's creation
    # resolve to their true types (the stale-snapshot AnyRef guesses poisoned the
    # tracker downstream of every mid-emission allocate_local!).
    b.locals_fn = function(idx::Int)
        idx < ctx.n_params && return nothing   # params: the static seed rules
        local off = idx - ctx.n_params + 1
        (off >= 1 && off <= length(ctx.locals)) ? ctx.locals[off] : nothing
    end
    return b
end

function _compile_value_b(val, ctx::AbstractCompilationContext)::InstrBuilder
    # MIGRATED to InstrBuilder. The main accumulator is the typed builder `b`; the
    # byte-INSPECTING branches (struct/Dict/Vector/Memory constants) keep building
    # local UInt8[] buffers (they LEB-decode + scan recursive results) and splice them
    # into `b` via emit_raw! / RawBytes. Byte-identical to the prior raw emission.
    b = _ctx_builder(ctx, "compile_value")
    _seed_builder_locals!(b, ctx)
    # Bridge external byte-emitting helpers (their intermediate buffers stay bytes):
    _emit_tid!(T) = emit_type_id!(b, ctx.type_registry, T)
    # parity(M10): the narrow DECLARES its stack effect so the typed channel sees the
    # refined type (it was emitted invisibly — vty stayed anyref and stores skipped the
    # funnel box for join-refined numerics).
    # march4: THE narrow channel emits direct — the cast/unbox is tracked (the
    # declared pops/pushes contract died with the bytes buffer).
    _narrow!(li, sid) = _narrow_generic_local!(b, li, sid, ctx)

    # PURE-6022: If we're in dead code (previous sub-call was a stub), don't compile
    # more values. Emitting data after unreachable creates invalid WASM byte sequences
    # (e.g., array element i32_const values decode as block/loop instructions).
    if ctx.last_stmt_was_stub
        haskey(ENV, "WT_TRACE_DEADVAL") && println(stderr, "DEADVAL val=", first(repr(val), 60))
        unreachable!(b)  # 0x00  # structural trap (dart-legit dead path)
        return b
    end

    # Handle nothing explicitly - it's the Julia singleton
    if val === nothing
        # Nothing maps to i32 in WasmGC — push i32(0) as placeholder
        i32_const!(b, 0)
        return b
    end

    if val isa Core.SSAValue
        # Check if this SSA has a local allocated (either regular or phi)
        if haskey(ctx.ssa_locals, val.id)
            local_idx = ctx.ssa_locals[val.id]
            local_get!(b, local_idx)
            # PURE-901: Narrow generic locals (anyref/structref) to concrete type.
            # When SSA type is concrete but local was allocated as generic (due to Union/Any),
            # ref.cast ensures downstream struct_get/array_get see the correct type.
            _narrow!(local_idx, val.id)
        elseif haskey(ctx.phi_locals, val.id)
            # Phi node - load from phi local
            local_idx = ctx.phi_locals[val.id]
            local_get!(b, local_idx)
        else
            # No local - check if this is a PiNode
            # PURE-6021: Guard against out-of-bounds SSAValue IDs (e.g. sentinel Core.SSAValue(-2)
            # that appear as constant literals in IR of compiler functions like construct_ssa!)
            if val.id < 1 || val.id > length(ctx.code_info.code)
                return b  # Dead code - sentinel SSAValue with invalid id
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
                                ref_null!(b, Int64(wasm_type.type_idx), ConcreteRef(UInt32(wasm_type.type_idx), true))
                                emitted_nothing = true
                            end
                        end
                    end
                    if !emitted_nothing
                        # Nothing is i32(0) as placeholder — this is what the callee expects
                        i32_const!(b, 0)
                    end
                else
                    # Non-Nothing PiNode without local: re-emit the underlying value.
                    # Can't assume it's on the stack since block boundaries clear the stack.
                    emit_value!(b, stmt.val, ctx)
                    # PURE-9030: Unbox from anyref to numeric type when PiNode narrows
                    # a Union-typed anyref value to a concrete numeric type.
                    # e.g., π(x::Union{Int32,Float64}, Int32) → ref.cast $BoxedInt32 + struct.get 1
                    local _pi_target_wasm = julia_to_wasm_type(pi_type)
                    if (_pi_target_wasm === I32 || _pi_target_wasm === I64 || _pi_target_wasm === F32 || _pi_target_wasm === F64)
                        # Check if the underlying value is anyref (boxed).
                        # P4-stdlib (Random hash_seed): read the ACTUAL local type
                        # when one exists — get_concrete_wasm_type guesses I64 for
                        # Union{Nothing, UInt64}, but such unions are allocated as
                        # AnyRef locals (an i64 cannot encode `nothing`), so the
                        # guess skipped the unbox and raw anyref reached i64.sub.
                        local _pi_src_wasm = nothing
                        if stmt.val isa Core.SSAValue
                            local _pi_li = get(ctx.ssa_locals, stmt.val.id, nothing)
                            _pi_li === nothing && (_pi_li = get(ctx.phi_locals, stmt.val.id, nothing))
                            if _pi_li !== nothing
                                local _pi_off = _pi_li - ctx.n_params
                                if _pi_off >= 0 && _pi_off < length(ctx.locals)
                                    _pi_src_wasm = ctx.locals[_pi_off + 1]
                                end
                            end
                            if _pi_src_wasm === nothing
                                local _pi_src_type = get(ctx.ssa_types, stmt.val.id, Any)
                                _pi_src_wasm = get_concrete_wasm_type(_pi_src_type, ctx.mod, ctx.type_registry)
                            end
                        elseif stmt.val isa Core.Argument
                            local _pi_arg_idx = ctx.is_compiled_closure ? stmt.val.n : stmt.val.n - 1
                            if _pi_arg_idx >= 1 && _pi_arg_idx <= length(ctx.arg_types)
                                _pi_src_wasm = get_concrete_wasm_type(ctx.arg_types[_pi_arg_idx], ctx.mod, ctx.type_registry)
                            end
                        end
                        if _pi_src_wasm === AnyRef || _pi_src_wasm === StructRef || _pi_src_wasm isa ConcreteRef
                            # Value is boxed in anyref — unbox via THE single consumer (non-null: isa-guarded).
                            emit_classid_unbox!(b, ctx, _pi_target_wasm)
                        end
                    else
                        # CG-003d: PiNode narrows to a struct/ref type (not numeric).
                        # Source value may be EqRef/StructRef/AnyRef (from Union{Nothing, T} local).
                        # Add ref.cast_null to narrow to the concrete type so struct.get works.
                        local _pi_concrete = julia_to_wasm_type_concrete(pi_type, ctx)
                        if _pi_concrete isa ConcreteRef
                            # Check if the source is a generic ref type that needs casting
                            local _pi_src_wasm2 = nothing
                            if stmt.val isa Core.SSAValue
                                local _pi_src_type2 = get(ctx.ssa_types, stmt.val.id, Any)
                                _pi_src_wasm2 = julia_to_wasm_type_concrete(_pi_src_type2, ctx)
                            elseif stmt.val isa Core.Argument
                                local _pi_arg_idx2 = ctx.is_compiled_closure ? stmt.val.n : stmt.val.n - 1
                                if _pi_arg_idx2 >= 1 && _pi_arg_idx2 <= length(ctx.arg_types)
                                    _pi_src_wasm2 = julia_to_wasm_type_concrete(ctx.arg_types[_pi_arg_idx2], ctx)
                                end
                            end
                            if _pi_src_wasm2 === EqRef || _pi_src_wasm2 === StructRef || _pi_src_wasm2 === AnyRef || _pi_src_wasm2 === ExternRef
                                _pi_src_wasm2 === ExternRef && any_convert_extern!(b)
                                ref_cast!(b, Int64(_pi_concrete.type_idx), true)
                            end
                        end
                    end
                end
            else
                # Non-PiNode SSA without local: re-compile the statement to reproduce its value.
                if stmt isa Expr && stmt.head === :boundscheck
                    # P2-batch6: real value (true unless @inbounds) — see statements.jl
                    i32_const!(b, (isempty(stmt.args) || stmt.args[1] !== false) ? 1 : 0)
                elseif stmt isa Expr && (stmt.head === :call || stmt.head === :invoke || stmt.head === :new || stmt.head === :foreigncall)
                    # Re-compile the expression to produce its value on the stack.
                    # Call the specific compiler directly to avoid compile_statement's
                    # orphan-prevention skip for multi-arg memoryrefnew.
                    local _ssa_t = WasmValType[static_wasm_type(val, ctx)]
                    if stmt.head === :call
                        compile_call!(b, stmt, val.id, ctx)   # dart visitor: emits direct, tracked
                    elseif stmt.head === :invoke
                        compile_invoke!(b, stmt, val.id, ctx)   # dart visitor: emits direct, tracked
                    elseif stmt.head === :new
                        compile_new!(b, stmt, val.id, ctx)   # dart visitor: emits direct, tracked
                    elseif stmt.head === :foreigncall
                        compile_foreigncall!(b, stmt, val.id, ctx)   # dart visitor: emits direct, tracked
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
            local_get!(b, local_idx)
        end

    elseif val isa Core.SlotNumber
        # PURE-6024: Check slot_locals first (for local variables in unoptimized IR),
        # then fall back to param mapping (slot 2 = param 0, slot 3 = param 1, etc.)
        if haskey(ctx.slot_locals, val.id)
            local_get!(b, ctx.slot_locals[val.id])
        else
            local_idx = val.id - 2
            if local_idx >= 0
                local_get!(b, local_idx)
            end
        end

    elseif val isa Bool
        i32_const!(b, val ? 1 : 0)

    elseif val isa Char
        # STACK-003: Char stored as Julia's internal representation (UTF-8 encoding
        # left-packed in UInt32). This matches Julia IR semantics where
        # bitcast(UInt32, c::Char) is a no-op reinterpret of the raw bytes.
        # '+' (U+002B) → 0x2b000000, 'é' (U+00E9) → 0xc3a90000
        # JS callers must convert codepoints to Julia encoding before passing.
        raw = reinterpret(Int32, reinterpret(UInt32, val))
        i32_const!(b, raw)

    elseif val isa Int8 || val isa UInt8 || val isa Int16 || val isa UInt16
        # Small integers - stored as i32 in WASM
        i32_const!(b, Int32(val))

    elseif val isa Int32
        i32_const!(b, val)

    elseif val isa UInt32
        i32_const!(b, reinterpret(Int32, val))

    elseif val isa Int64 || val isa Int
        i64_const!(b, Int64(val))

    elseif val isa UInt64
        i64_const!(b, reinterpret(Int64, val))

    elseif val isa Int128 || val isa UInt128
        # march7: funnel-first (int128)
        local _cgint128 = ensure_constant_global!(ctx.mod, ctx.type_registry, val)
        if _cgint128 !== nothing
            local _ciint128 = register_struct_type!(ctx.mod, ctx.type_registry, typeof(val))
            _ciint128 !== nothing && (global_get!(b, _cgint128, ConcreteRef(_ciint128.wasm_type_idx, false)); return b)
        end
        # 128-bit integers are represented as WasmGC structs with (lo, hi) fields
        result_type = typeof(val)
        type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)

        # Extract lo (low 64 bits) and hi (high 64 bits)
        lo = UInt64(val & 0xFFFFFFFFFFFFFFFF)
        hi = UInt64((val >> 64) & 0xFFFFFFFFFFFFFFFF)

        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID
        _emit_tid!(result_type)
        i64_const!(b, reinterpret(Int64, lo))   # lo
        i64_const!(b, reinterpret(Int64, hi))   # hi
        struct_new!(b, type_idx, WasmValType[I32, I64, I64])

    elseif val isa Float32
        f32_const!(b, val)

    elseif val isa Float64
        f64_const!(b, val)

    elseif val isa String
        # census F3 (march5): short literals read the ONE interned global (dart
        # constants.dart dedup — code size + `===` identity); the inline
        # data-segment path remains for long strings (dart lazies those).
        local _sg = get_string_constant_global!(ctx.mod, ctx.type_registry, val)
        if _sg !== nothing
            global_get!(b, _sg, ConcreteRef(get_string_struct_type!(ctx.mod, ctx.type_registry), false))
            return b
        end
        # march7 LAZY: a pre-passed long literal reads its global, initializing on
        # first use (dart constants.dart:322-339: global.get + br_on_non_null + call init)
        local _lz = ctx.type_registry.lazy_string_globals === nothing ? nothing :
                    get(ctx.type_registry.lazy_string_globals, val, nothing)
        if _lz !== nothing
            local _lzs = get_string_struct_type!(ctx.mod, ctx.type_registry)
            local _lzt = add_type!(ctx.mod, FuncType(WasmValType[], WasmValType[ConcreteRef(_lzs, true)]))
            block!(b, Int(_lzt); results=WasmValType[ConcreteRef(_lzs, true)])
            global_get!(b, _lz[1], ConcreteRef(_lzs, true))
            br_on_non_null!(b, 0)
            call!(b, _lz[2], WasmValType[], WasmValType[ConcreteRef(_lzs, true)])
            end_block!(b)
            return b
        end
        # PURE-9013: String constant via passive data segment + array.new_data
        # parity(M9): then WRAPPED as the classed string {classId, data} (the ONE producer).
        type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
        n_bytes = ncodeunits(val)

        if n_bytes == 0
            array_new_fixed!(b, type_idx, 0, I32)
        else
            utf8_bytes = Vector{UInt8}(codeunits(val))
            seg_idx = add_passive_data_segment!(ctx.mod, utf8_bytes)
            i32_const!(b, 0)              # offset 0 (start of segment)
            # (signed-LEB length note preserved: see git history PURE-9013)
            i32_const!(b, Int32(n_bytes))  # length
            array_new_data!(b, type_idx, seg_idx)
        end
        emit_string_wrap!(b, ctx)

    elseif val isa GlobalRef
        # Check if this GlobalRef is a module-level global (mutable struct instance)
        key = (val.mod, val.name)
        global_idx = _lookup_module_global(ctx.module_globals, key)
        if global_idx !== nothing
            global_get!(b, global_idx, AnyRef)
        else
            # GlobalRef to a constant - evaluate and compile the value
            try
                actual_val = getfield(val.mod, val.name)
                emit_value!(b, actual_val, ctx)
            catch
                # If we can't evaluate, might be a type reference (no runtime value)
            end
        end

    elseif val isa QuoteNode
        # QuoteNode wraps a constant value - unwrap and compile.
        # D-001: Core IR reference types (SSAValue, Argument, SlotNumber) inside QuoteNodes
        # are LITERAL struct values, not IR references. compile_value would misinterpret them
        # as SSA slot lookups / argument loads. Compile them as struct constants instead.
        inner = val.value
        if inner isa Core.SSAValue || inner isa Core.Argument || inner isa Core.SlotNumber
            T = typeof(inner)
            info = register_struct_type!(ctx.mod, ctx.type_registry, T)
            type_idx = info.wasm_type_idx
            _emit_tid!(T)
            for field_name in fieldnames(T)
                field_val = getfield(inner, field_name)
                if field_val isa Int
                    i64_const!(b, Int64(field_val))
                else
                    emit_value!(b, field_val, ctx)
                end
            end
            struct_new!(b, type_idx)   # mod-resolved fields (march3: the empty-list fudge is dead)
        else
            emit_value!(b, inner, ctx)
        end

    elseif isprimitivetype(typeof(val)) && !isa(val, Bool) && !isa(val, Char) &&
           !isa(val, Int8) && !isa(val, Int16) && !isa(val, Int32) && !isa(val, Int64) &&
           !isa(val, UInt8) && !isa(val, UInt16) && !isa(val, UInt32) && !isa(val, UInt64) &&
           !isa(val, Float32) && !isa(val, Float64)
        # Custom primitive type (e.g., JuliaSyntax.Kind) - bitcast to integer
        T = typeof(val)
        sz = sizeof(T)
        if sz == 1
            int_val = Core.Intrinsics.bitcast(UInt8, val)
            i32_const!(b, Int32(int_val))
        elseif sz == 2
            int_val = Core.Intrinsics.bitcast(UInt16, val)
            i32_const!(b, Int32(int_val))
        elseif sz == 4
            int_val = Core.Intrinsics.bitcast(UInt32, val)
            i32_const!(b, Int32(int_val))
        elseif sz == 8
            int_val = Core.Intrinsics.bitcast(UInt64, val)
            i64_const!(b, Int64(int_val))
        else
            error("Primitive type with unsupported size for Wasm: $T ($sz bytes)")
        end

    elseif val isa Symbol
        # march7 M7-c: Symbols share the classed string rep AND its intern registry —
        # equal symbol literals read the ONE deduplicated global (dart: one constantInfo
        # map for all kinds). Long names keep the inline data-segment path.
        name_str = String(val)
        local _syg = get_string_constant_global!(ctx.mod, ctx.type_registry, name_str)
        if _syg !== nothing
            global_get!(b, _syg, ConcreteRef(get_string_struct_type!(ctx.mod, ctx.type_registry), false))
            return b
        end
        type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
        n_bytes = ncodeunits(name_str)
        utf8_bytes = Vector{UInt8}(codeunits(name_str))
        seg_idx = add_passive_data_segment!(ctx.mod, utf8_bytes)
        i32_const!(b, 0)
        # i32.const operands are SIGNED LEB128 (see String path above).
        i32_const!(b, Int32(n_bytes))
        array_new_data!(b, type_idx, seg_idx)
        emit_string_wrap!(b, ctx)   # parity(M9): Symbols share the classed string rep

    elseif typeof(val) <: Tuple
        # march7: funnel-first (tuple) — tuples of constant-expressible fields intern
        local _cgtp = ensure_constant_global!(ctx.mod, ctx.type_registry, val)
        if _cgtp !== nothing
            local _citp = get(ctx.type_registry.structs, typeof(val), nothing)
            _citp !== nothing && (global_get!(b, _cgtp, ConcreteRef(_citp.wasm_type_idx, false)); return b)
        end
        # Tuple constant - create it with struct.new
        T = typeof(val)

        # Ensure tuple type is registered using register_tuple_type!
        info = register_tuple_type!(ctx.mod, ctx.type_registry, T)
        type_idx = info.wasm_type_idx

        # Get the struct type definition to check expected field types
        struct_type_def = ctx.mod.types[type_idx + 1]

        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID
        _emit_tid!(T)

        # Push field values (tuples use 1-based indexing)
        for i in 1:length(val)
            field_val = val[i]
            # PURE-141: When field value is a Type constant and field expects a ref type,
            # emit ref.null instead of i32.const 0 (compile_value(Type) returns i32)
            expected_wasm = nothing
            local _wasm_fi = i + Int(info.field_offset)  # PURE-9024: skip typeId
            if struct_type_def isa StructType && _wasm_fi <= length(struct_type_def.fields)
                expected_wasm = struct_type_def.fields[_wasm_fi].valtype
            end
            if field_val isa Type && expected_wasm !== nothing &&
               (expected_wasm isa ConcreteRef || expected_wasm === StructRef ||
                expected_wasm === ArrayRef || expected_wasm === AnyRef || expected_wasm === ExternRef)
                # Type value needs ref type - emit ref.null of expected type
                if expected_wasm isa ConcreteRef
                    ref_null!(b, Int64(expected_wasm.type_idx), ConcreteRef(UInt32(expected_wasm.type_idx), true))
                elseif expected_wasm === ArrayRef
                    ref_null!(b, ArrayRef)
                elseif expected_wasm === ExternRef
                    ref_null!(b, ExternRef)
                elseif expected_wasm === AnyRef
                    ref_null!(b, AnyRef)
                else
                    ref_null!(b, StructRef)
                end
            else
                emit_value!(b, field_val, ctx)
            end
        end

        # Create the struct
        struct_new!(b, type_idx)   # mod-resolved fields (march3: the empty-list fudge is dead)

    elseif val isa Type
        # PURE-4151: Type constant — each unique Type gets a unique Wasm global
        # so that ref.eq can distinguish different Type objects at runtime.
        # Previous behavior (i32.const 0) made all Types indistinguishable.
        global_idx = get_type_constant_global!(ctx.mod, ctx.type_registry, val)
        global_get!(b, global_idx, AnyRef)

    elseif val isa Core.TypeName
        # PURE-9064: TypeName constant — look up or create the TypeName global.
        # TypeName objects have many undefined fields so the general struct constant
        # path would emit ref.null. Instead, use the dedicated TypeName global registry.
        tn_global_idx = get_typename_constant_global!(ctx.mod, ctx.type_registry, val)
        global_get!(b, tn_global_idx, AnyRef)

    elseif val isa Module
        # march7: funnel-first (module) — interned when eager-able
        local _cg_2 = ensure_constant_global!(ctx.mod, ctx.type_registry, val)
        if _cg_2 !== nothing
            local _ci_2 = register_struct_type!(ctx.mod, ctx.type_registry, typeof(val))
            global_get!(b, _cg_2, ConcreteRef(_ci_2.wasm_type_idx, false))
            return b
        end
        # Module constant — empty struct (fieldcount=0), like Function singletons.
        # Used for === identity checks (ref.eq). Each struct.new creates a unique ref.
        info = register_struct_type!(ctx.mod, ctx.type_registry, Module)
        type_idx = info.wasm_type_idx
        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID
        _emit_tid!(Module)
        struct_new!(b, type_idx)   # mod-resolved fields (march3: the empty-list fudge is dead)

    elseif val isa Function && isstructtype(typeof(val)) && fieldcount(typeof(val)) == 0
        # march7: funnel-first (fn-singleton) — interned when eager-able
        local _cg_0 = ensure_constant_global!(ctx.mod, ctx.type_registry, val)
        if _cg_0 !== nothing
            local _ci_0 = register_struct_type!(ctx.mod, ctx.type_registry, typeof(val))
            global_get!(b, _cg_0, ConcreteRef(_ci_0.wasm_type_idx, false))
            return b
        end
        # Function singleton (e.g., typeof(some_function)) — empty struct with no fields
        T = typeof(val)
        info = register_struct_type!(ctx.mod, ctx.type_registry, T)
        type_idx = info.wasm_type_idx
        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID
        _emit_tid!(T)
        struct_new!(b, type_idx)   # mod-resolved fields (march3: the empty-list fudge is dead)

    elseif val isa Function && isstructtype(typeof(val)) && fieldcount(typeof(val)) > 0
        # march7: funnel-first (closure-const) — interned when eager-able
        local _cg_1 = ensure_constant_global!(ctx.mod, ctx.type_registry, val)
        if _cg_1 !== nothing
            local _ci_1 = register_struct_type!(ctx.mod, ctx.type_registry, typeof(val))
            global_get!(b, _cg_1, ConcreteRef(_ci_1.wasm_type_idx, false))
            return b
        end
        # PURE-325: Function closure with captured fields (e.g., Fix2{typeof(isequal), Char})
        # These are structs that happen to be Functions — compile like regular structs
        T = typeof(val)
        info = register_struct_type!(ctx.mod, ctx.type_registry, T)
        type_idx = info.wasm_type_idx

        has_undefined = any(!isdefined(val, fn) for fn in fieldnames(T))
        if has_undefined
            ref_null!(b, Int64(type_idx), ConcreteRef(UInt32(type_idx), true))
            return b
        end

        struct_type_def = ctx.mod.types[type_idx + 1]
        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID
        _emit_tid!(T)
        for (fi, field_name) in enumerate(fieldnames(T))
            field_val = getfield(val, field_name)
            emit_value!(b, field_val, ctx)
        end

        struct_new!(b, type_idx)   # mod-resolved fields (march3: the empty-list fudge is dead)

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

        # Helper: emit default value for an array element type (captures `b`, `ctx`)
        emit_array_default! = function(arr_type_idx, elem_type)
            wasm_et = julia_to_wasm_type(elem_type)
            if wasm_et === I32
                i32_const!(b, 0)
            elseif wasm_et === I64
                i64_const!(b, 0)
            elseif wasm_et === F32
                f32_const!(b, Float32(0))
            elseif wasm_et === F64
                f64_const!(b, Float64(0))
            else
                # Ref type (String, struct, etc.) — look up concrete array element type
                arr_type_def = ctx.mod.types[arr_type_idx + 1]
                if arr_type_def isa ArrayType
                    evtype = arr_type_def.elem.valtype
                    if evtype isa ConcreteRef
                        ref_null!(b, Int64(evtype.type_idx), ConcreteRef(UInt32(evtype.type_idx), true))
                    else
                        ref_null!(b, StructRef)
                    end
                else
                    ref_null!(b, StructRef)
                end
            end
        end

        # Helper: compile Memory elements, handling UndefRefError for ref-typed slots
        compile_memory_elements! = function(mem, arr_type_idx, elem_type)
            for i in 1:length(mem)
                # PURE-6022: Stop emitting elements after stub/unreachable
                if ctx.last_stmt_was_stub
                    break
                end
                try
                    v = mem[i]
                    emit_value!(b, v, ctx)
                catch e
                    if e isa UndefRefError
                        emit_array_default!(arr_type_idx, elem_type)
                    else
                        rethrow()
                    end
                end
            end
        end

        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID
        _emit_tid!(T)

        # field 1: slots — array of UInt8 (always defined, never throws)
        for i in 1:length(dict_slots)
            i32_const!(b, Int32(dict_slots[i]))
        end
        array_new_fixed!(b, slots_arr_type, length(dict_slots), I32)

        # field 2: keys — array of K (may have undef for ref-typed keys)
        compile_memory_elements!(dict_keys, keys_arr_type, K)
        array_new_fixed!(b, keys_arr_type, length(dict_keys), AnyRef)

        # field 3: vals — array of V (may have undef for ref-typed vals)
        compile_memory_elements!(dict_vals, vals_arr_type, V)
        array_new_fixed!(b, vals_arr_type, length(dict_vals), AnyRef)

        # fields 4-8: ndel, count, age, idxfloor, maxprobe (i64)
        i64_const!(b, Int64(getfield(val, :ndel)))
        i64_const!(b, Int64(getfield(val, :count)))
        i64_const!(b, Int64(getfield(val, :age)))
        i64_const!(b, Int64(getfield(val, :idxfloor)))
        i64_const!(b, Int64(getfield(val, :maxprobe)))

        # struct.new
        struct_new!(b, dict_info.wasm_type_idx)   # mod-resolved fields (march3)

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

        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID for Vector struct
        _emit_tid!(T)

        # Field 1: data array — emit array.new_fixed with actual element values
        wasm_elem_type = get_concrete_wasm_type(elem_type, ctx.mod, ctx.type_registry)
        for i in 1:length(val)
            # PURE-6022: Stop emitting array elements after unreachable (stub).
            # Dead code after unreachable contains raw data bytes that decode as
            # invalid WASM instructions (e.g., block with invalid type byte).
            if ctx.last_stmt_was_stub
                break
            end
            emit_value!(b, val[i], ctx, wasm_elem_type; from_julia=typeof(val[i]))
            # PURE-6022: Check after each element in case compile_value hit a stub
            if ctx.last_stmt_was_stub
                break
            end
        end
        # PURE-6022: Skip array_new_fixed if we're in dead code (stub was hit)
        if !ctx.last_stmt_was_stub
            array_new_fixed!(b, array_type_idx, length(val), wasm_elem_type)
        end

        # Field 2: size tuple — Tuple{Int64} with the length
        size_tuple_type = Tuple{Int64}
        if !haskey(ctx.type_registry.structs, size_tuple_type)
            register_tuple_type!(ctx.mod, ctx.type_registry, size_tuple_type)
        end
        size_info = ctx.type_registry.structs[size_tuple_type]
        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID for size tuple
        _emit_tid!(Tuple{Int64})
        i64_const!(b, Int64(length(val)))
        struct_new!(b, size_info.wasm_type_idx)   # mod-resolved fields (march3)

        # struct.new for Vector{T}
        struct_new!(b, vec_info.wasm_type_idx)   # mod-resolved fields (march3)

    elseif typeof(val) isa DataType && typeof(val).name.name in (:MemoryRef, :GenericMemoryRef, :Memory, :GenericMemory)
        # PURE-049: MemoryRef/Memory constants map to array types, not struct types.
        # P6-ioprint: materialize the contents (the old ref.null emission silently
        # dropped them — Base's constant IdSet/show tables arrived empty). Large
        # memories fall back to null to avoid bytecode blowup.
        T = typeof(val)
        elem_type = T.name.name in (:GenericMemoryRef, :GenericMemory) ? T.parameters[2] : T.parameters[1]
        array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
        mem = T.name.name in (:MemoryRef, :GenericMemoryRef) ? getfield(val, :mem) : val
        n_mem = length(mem)
        if n_mem == 0 || n_mem > 4096
            n_mem > 4096 && @debug "Memory constant too large to materialize ($n_mem elements) — emitting null" T
            ref_null!(b, Int64(array_type_idx), ConcreteRef(UInt32(array_type_idx), true))
        else
            arr_type_def = ctx.mod.types[array_type_idx + 1]
            for i in 1:n_mem
                local _el_vb = nothing
                defined = isassigned(mem, i)
                if defined
                    _el_vb = _compile_value_b(mem[i], ctx)
                end
                if !defined || isempty(_el_vb.instrs)
                    # undef slot (or uncompilable element) — type-correct default.
                    # Straight-line emission: emit the typed default directly on `b`.
                    evt = arr_type_def isa ArrayType ? arr_type_def.elem.valtype : nothing
                    if evt === I32
                        i32_const!(b, 0)
                    elseif evt === I64
                        i64_const!(b, 0)
                    elseif evt === F32
                        f32_const!(b, Float32(0))
                    elseif evt === F64
                        f64_const!(b, Float64(0))
                    elseif evt isa ConcreteRef
                        ref_null!(b, Int64(evt.type_idx), ConcreteRef(UInt32(evt.type_idx), true))
                    else
                        ref_null!(b, AnyRef)  # 0x6E any
                    end
                else
                    append_builder!(b, _el_vb)   # typed merge
                end
            end
            array_new_fixed!(b, array_type_idx, n_mem, AnyRef)
        end

    elseif isstructtype(typeof(val)) && !isa(val, Function) && !isa(val, Module)
        # march7: THE ensureConstant funnel first — an eager-internable immutable
        # constant reads its ONE deduplicated global (dart constants.dart:427-443);
        # mutable / non-constant-field values fall through to the inline path.
        local _cg = ensure_constant_global!(ctx.mod, ctx.type_registry, val)
        if _cg !== nothing
            local _cgi = register_struct_type!(ctx.mod, ctx.type_registry, typeof(val))
            global_get!(b, _cg, ConcreteRef(_cgi.wasm_type_idx, false))
            return b
        end
        # Struct constant - create it with struct.new
        T = typeof(val)

        # 1f6e77980994 family: struct CONSTANTS with cyclic/unboundedly deep
        # object graphs (Luxor/Karnak/Graphs values captured in Makie figures)
        # recursed compile_value to a StackOverflow. Guard by object identity
        # AND depth; refuse with a NAMED error so pipelines degrade honestly.
        if any(x -> x === val, _VALUE_COMPILE_STACK)
            throw(WasmCompileError(WasmDiagnostic(:unsupported_type, string(nameof(T)),
                "cyclic struct constant of type $(T) (object graph references itself)",
                nothing, nothing)))
        end
        if length(_VALUE_COMPILE_STACK) > 200
            _tail = join((string(nameof(typeof(x))) for x in _VALUE_COMPILE_STACK[end-7:end]), " → ")
            throw(WasmCompileError(WasmDiagnostic(:unsupported_type, string(nameof(T)),
                "struct constant nesting exceeded depth 200 (… → $(_tail) → $(T))",
                nothing, nothing)))
        end
        push!(_VALUE_COMPILE_STACK, val)
        try

        # Ensure struct type is registered and get its type index
        info = register_struct_type!(ctx.mod, ctx.type_registry, T)
        type_idx = info.wasm_type_idx

        # Check for undefined fields — if ALL fields are undefined, emit ref.null.
        # If only SOME fields are undefined, emit default values for those and still
        # construct the struct (TRUE-TI-001: enables Method objects with optional fields).
        n_undefined = count(!isdefined(val, fn) for fn in fieldnames(T))
        if n_undefined == length(fieldnames(T))
            # Fully undefined struct - emit ref.null
            ref_null!(b, Int64(type_idx), ConcreteRef(UInt32(type_idx), true))
            return b
        end

        # Push field values with type safety checks
        struct_type_def = ctx.mod.types[type_idx + 1]
        # PURE-9024/9025: Push typeId (field 0) with DFS-assigned ID
        _emit_tid!(T)
        for (fi, field_name) in enumerate(fieldnames(T))
            # TRUE-TI-001: Handle undefined fields with type-correct defaults
            if !isdefined(val, field_name)
                local _undef_wasm_fi = fi + Int(info.field_offset)
                if struct_type_def isa StructType && _undef_wasm_fi <= length(struct_type_def.fields)
                    undef_field_type = struct_type_def.fields[_undef_wasm_fi].valtype
                    if undef_field_type isa ConcreteRef
                        ref_null!(b, Int64(undef_field_type.type_idx), ConcreteRef(UInt32(undef_field_type.type_idx), true))
                    elseif undef_field_type === AnyRef
                        ref_null!(b, AnyRef)
                    elseif undef_field_type === EqRef
                        ref_null!(b, EqRef)
                    elseif undef_field_type === ExternRef
                        ref_null!(b, ExternRef)
                    elseif undef_field_type === StructRef
                        ref_null!(b, StructRef)
                    elseif undef_field_type === ArrayRef
                        ref_null!(b, ArrayRef)
                    elseif undef_field_type === I32
                        i32_const!(b, 0)
                    elseif undef_field_type === I64
                        i64_const!(b, 0)
                    elseif undef_field_type === F32
                        f32_const!(b, Float32(0.0))
                    elseif undef_field_type === F64
                        f64_const!(b, Float64(0.0))
                    else
                        # Fallback: try ref.null with the generic type
                        ref_null!(b, AnyRef)
                    end
                else
                    ref_null!(b, AnyRef)
                end
                continue
            end
            field_val = getfield(val, field_name)
            local _fvc_b = _compile_value_b(field_val, ctx)
            local _fv_ty = isempty(_fvc_b.v.stack) ? nothing : _fvc_b.v.stack[end]
            local _fvc_done = false
            # B4/U2: the union-typed-field tagged-union-wrapper box-coercion is RETIRED — a
            # union field is AnyRef (the classId box / struct ref), never the {typeId,tag,value}
            # wrapper, so the constant's field value (a ref) is already anyref-compatible.
            # TRUE-TI-001: If compile_value produced no bytes (e.g., Module, Function),
            # emit ref.null for the field's expected type
            if isempty(_fvc_b.instrs)
                local _empty_fi = fi + Int(info.field_offset)
                if struct_type_def isa StructType && _empty_fi <= length(struct_type_def.fields)
                    empty_field_type = struct_type_def.fields[_empty_fi].valtype
                    if empty_field_type isa ConcreteRef
                        ref_null!(b, Int64(empty_field_type.type_idx), ConcreteRef(UInt32(empty_field_type.type_idx), true))
                    elseif empty_field_type === AnyRef
                        ref_null!(b, AnyRef)
                    elseif empty_field_type === ExternRef
                        ref_null!(b, ExternRef)
                    elseif empty_field_type === I32
                        i32_const!(b, 0)
                    elseif empty_field_type === I64
                        i64_const!(b, 0)
                    else
                        ref_null!(b, AnyRef)
                    end
                    continue
                end
            end
            # Check field type compatibility — decided by the emission's TRACKED type
            # (march3: the struct.new LEB re-decode and the 0x41/0x42/0x20 first-byte
            # scans are DELETED; _fv_ty is the byproduct dart carries with every value).
            replaced = false
            local _wasm_fi = fi + Int(info.field_offset)  # PURE-9024: skip typeId
            if struct_type_def isa StructType && _wasm_fi <= length(struct_type_def.fields)
                expected_wasm = struct_type_def.fields[_wasm_fi].valtype
                if expected_wasm isa ConcreteRef || expected_wasm === StructRef || expected_wasm === ArrayRef || expected_wasm === AnyRef || expected_wasm === ExternRef
                    need_replace = false
                    if _fv_ty isa ConcreteRef && _wt_heap_kind(_fv_ty, ctx.mod) === :concrete_struct
                        # behavior-preserving: the old scan fired only on values ENDING in
                        # struct.new — struct-kind refs, never the array-kind (string data)
                        if expected_wasm isa ConcreteRef && _fv_ty.type_idx != expected_wasm.type_idx
                            # mismatched concrete struct ref (exact-idx test, as before)
                            need_replace = true
                        elseif expected_wasm === ArrayRef || expected_wasm === ExternRef
                            # a GC struct ref where an array/extern slot is expected
                            need_replace = true
                        end
                    elseif _fv_ty === I32 || _fv_ty === I64
                        # numeric value meeting a ref-typed field slot
                        need_replace = true
                    end
                    if need_replace
                        if expected_wasm isa ConcreteRef
                            ref_null!(b, Int64(expected_wasm.type_idx), ConcreteRef(UInt32(expected_wasm.type_idx), true))
                        elseif expected_wasm === ArrayRef
                            ref_null!(b, ArrayRef)
                        elseif expected_wasm === ExternRef
                            ref_null!(b, ExternRef)
                        else
                            ref_null!(b, StructRef)
                        end
                        _fvc_done = true
                        replaced = true
                    end
                end
            end
            _fvc_done || isempty(_fvc_b.instrs) || append_builder!(b, _fvc_b)   # typed merge
            # If field expects externref but we produced a GC-managed ref (anyref subtype, e.g.
            # string/symbol array or struct), emit extern.convert_any to bridge the two worlds.
            # (Strings/Symbols compile as ConcreteRef to char array; externref slots need conversion.)
            local _wasm_fi2 = fi + Int(info.field_offset)  # PURE-9024: skip typeId
            if !replaced && struct_type_def isa StructType && _wasm_fi2 <= length(struct_type_def.fields)
                local _ef = struct_type_def.fields[_wasm_fi2].valtype
                if _ef === ExternRef
                    # march3: decided by the TRACKED type — an internal (anyref-family)
                    # ref bridges via extern.convert_any; an ExternRef value is already
                    # there (this also covers global.get of Type constants, whose tracked
                    # type is the global's declared valtype — the LEB re-decode is gone).
                    if _fv_ty !== nothing && _fv_ty !== ExternRef && _wt_is_ref(_fv_ty)
                        extern_convert_any!(b)
                    end
                end
            end
        end

        # Create the struct
        struct_new!(b, type_idx)   # mod-resolved fields (march3: the empty-list fudge is dead)
        finally
            pop!(_VALUE_COMPILE_STACK)
        end
    end

    return b
end
