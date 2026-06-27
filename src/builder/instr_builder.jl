# InstrBuilder — a dart2wasm-`wasm_builder`-style typed instruction emitter.
#
# THE one emission layer (replacing raw `push!(bytes, Opcode.X)` + the emergent
# stack-balance heuristics). Each emit method BOTH appends bytes to `.code` AND
# updates an explicit operand-stack model (reusing `WasmStackValidator`'s per-opcode
# pop/push logic — composition, not duplication). When `strict`, a stack imbalance
# THROWS at the emit site with Julia source context; during migration it collects so
# partially-migrated functions still build, with the model staying live.
#
# Mirrors dart2wasm's InstructionsBuilder: typed methods, type-directed GC stack
# effects (struct_new reads the field types), `end_block!` enforces
# height == base + outputs. See dev/WASM_BUILDER_MIGRATION.md.

export InstrBuilder, builder_code, set_strict!, StackImbalanceError,
       set_context!, builder_diagnose

"""
    StackImbalanceError

Thrown by an `InstrBuilder` in strict mode when an emit would unbalance/mistype the
operand stack — the build-time, source-located equivalent of `wasm-tools`'
"values remaining on stack", but caught AT THE EMIT SITE with the offending Julia
statement, the live operand-stack snapshot, and the byte offset. This is the
precision bug-finder for WasmTarget: where wasm-tools says "func 14 @ 0xcc18",
this says which Julia statement and what was on the stack.
"""
struct StackImbalanceError <: Exception
    func_name::String
    context::String        # the Julia statement / high-level op being emitted
    message::String        # the specific validator complaint(s)
    stack::Vector{String}  # operand-stack snapshot (types, bottom→top) at failure
    byte_offset::Int       # length(code) at failure
end
function Base.showerror(io::IO, e::StackImbalanceError)
    print(io, "StackImbalanceError in `$(e.func_name)`")
    isempty(e.context) || print(io, "\n  while emitting: ", e.context)
    print(io, "\n  ", replace(e.message, "\n  " => "\n  "))
    print(io, "\n  operand stack (bottom→top): [", join(e.stack, ", "), "]")
    print(io, "\n  at byte offset 0x", string(e.byte_offset, base=16))
end

"""
    InstrBuilder

Live, self-validating WebAssembly instruction emitter. `.code` is the function body
bytes; `.v` is the operand-stack model (`WasmStackValidator`); `.locals` types
`local.get/set/tee`; GC ops take their field/element types directly (caller has them,
exactly as it does today when emitting).
"""
mutable struct InstrBuilder
    code::Vector{UInt8}
    v::WasmStackValidator
    locals::Vector{WasmValType}   # param + local types, indexed by local index
    strict::Bool                  # throw on stack imbalance (migrated funcs) vs collect
    func_name::String
    context::String               # current Julia stmt/op being emitted (for diagnostics)
    trace::Union{Nothing, Vector{String}}  # opt-in full emit log (WT_BUILDER_TRACE)
end

function InstrBuilder(param_types::Vector{<:Any}=WasmValType[],
                      result_types::Vector{<:Any}=WasmValType[];
                      func_name::String="", strict::Bool=false)
    locals = WasmValType[p for p in param_types]
    v = WasmStackValidator(; enabled=true, func_name=func_name)
    # Seed the outermost label as a :block whose results are the function results,
    # so end-of-function balance is checked against the declared results.
    push!(v.labels, ValidatorLabel(:block, 0, WasmValType[r for r in result_types], true))
    trace = haskey(ENV, "WT_BUILDER_TRACE") ? String[] : nothing
    InstrBuilder(UInt8[], v, locals, strict, func_name, "", trace)
end

builder_code(b::InstrBuilder) = b.code
set_strict!(b::InstrBuilder, s::Bool) = (b.strict = s; b)

"""
    _wt_builder_strict() -> Bool

Default strict-mode for migrated emitters. OFF by default (collect mode → the live
operand-stack model tracks every op for diagnostics but never throws, so migration is
regression-free), ON when `WT_BUILDER_STRICT` is set in the environment (turns the model
into a hard gate that pinpoints the offending Julia statement + stack snapshot — the
"tons of clarity" bug finder).
"""
_wt_builder_strict() = get(ENV, "WT_BUILDER_STRICT", "") != ""
"Set the high-level context (Julia statement) the next emits belong to — surfaces in errors."
set_context!(b::InstrBuilder, ctx::AbstractString) = (b.context = String(ctx); b)

_stack_snapshot(b::InstrBuilder) = String[string(t) for t in b.v.stack]

# Throw the collected validator errors (if strict) with rich source context, else collect.
@inline function _check!(b::InstrBuilder)
    if b.trace !== nothing
        top = isempty(b.v.stack) ? "-" : string(b.v.stack[end])
        push!(b.trace, "off=0x$(string(length(b.code), base=16)) h=$(length(b.v.stack)) top=$top | $(b.context)")
    end
    if b.strict && has_errors(b.v)
        msg = join(b.v.errors, "\n  ")
        empty!(b.v.errors)
        throw(StackImbalanceError(b.func_name, b.context, msg, _stack_snapshot(b), length(b.code)))
    end
    return b
end

"""
    builder_diagnose(b) -> String

Full human-readable post-mortem of a builder's state — the operand-stack snapshot,
the open control-flow labels (with their base heights/result types), reachability,
the byte length, and any collected (non-strict) errors. Use this to pin a codegen
bug to an exact statement + stack shape with no wasm-tools round-trip.
"""
function builder_diagnose(b::InstrBuilder)::String
    io = IOBuffer()
    println(io, "InstrBuilder `$(b.func_name)` — $(length(b.code)) bytes, reachable=$(b.v.reachable)")
    isempty(b.context) || println(io, "  context: ", b.context)
    println(io, "  operand stack (bottom→top): [", join(_stack_snapshot(b), ", "), "]")
    if !isempty(b.v.labels)
        println(io, "  open blocks (outer→inner):")
        for (i, l) in enumerate(b.v.labels)
            println(io, "    [$i] $(l.kind) base=$(l.stack_height_at_entry) results=$(l.result_types) reachable=$(l.reachable_at_entry)")
        end
    end
    if has_errors(b.v)
        println(io, "  collected errors:")
        for e in b.v.errors; println(io, "    - ", e); end
    end
    if b.trace !== nothing && !isempty(b.trace)
        println(io, "  emit trace (last 40):")
        for s in last(b.trace, 40); println(io, "    ", s); end
    end
    String(take!(io))
end

# Register a local's type so local.get/set/tee can be typed. idx is 0-based.
function builder_add_local!(b::InstrBuilder, typ::WasmValType)::Int
    push!(b.locals, typ)
    return length(b.locals) - 1
end
function builder_set_local_type!(b::InstrBuilder, idx::Integer, typ::WasmValType)
    while length(b.locals) <= idx
        push!(b.locals, AnyRef)
    end
    b.locals[idx + 1] = typ
end

# ── raw opcode appenders (internal) ────────────────────────────────────────────
@inline _op!(b::InstrBuilder, op::UInt8) = push!(b.code, op)
@inline _leb_u!(b::InstrBuilder, n::Integer) = append!(b.code, encode_leb128_unsigned(n))
@inline _leb_s!(b::InstrBuilder, n::Integer) = append!(b.code, encode_leb128_signed(n))

# ════════════════════════════════════════════════════════════════════════════════
# Numeric
# ════════════════════════════════════════════════════════════════════════════════
i32_const!(b::InstrBuilder, v::Integer) = (_op!(b, Opcode.I32_CONST); _leb_s!(b, Int64(v)); validate_push!(b.v, I32); _check!(b))
i64_const!(b::InstrBuilder, v::Integer) = (_op!(b, Opcode.I64_CONST); _leb_s!(b, Int64(v)); validate_push!(b.v, I64); _check!(b))
function f32_const!(b::InstrBuilder, x::Real)
    _op!(b, Opcode.F32_CONST); append!(b.code, reinterpret(UInt8, [Float32(x)])); validate_push!(b.v, F32); _check!(b)
end
function f64_const!(b::InstrBuilder, x::Real)
    _op!(b, Opcode.F64_CONST); append!(b.code, reinterpret(UInt8, [Float64(x)])); validate_push!(b.v, F64); _check!(b)
end

# Generic numeric/comparison/conversion op (no immediates): reuse validate_instruction!.
function num!(b::InstrBuilder, op::UInt8)
    _op!(b, op); validate_instruction!(b.v, op); _check!(b)
end

# ════════════════════════════════════════════════════════════════════════════════
# Parametric
# ════════════════════════════════════════════════════════════════════════════════
drop!(b::InstrBuilder) = (_op!(b, Opcode.DROP); validate_pop_any!(b.v); _check!(b))

# ════════════════════════════════════════════════════════════════════════════════
# Variable
# ════════════════════════════════════════════════════════════════════════════════
function local_get!(b::InstrBuilder, idx::Integer)
    _op!(b, Opcode.LOCAL_GET); _leb_u!(b, idx)
    validate_push!(b.v, (idx + 1) <= length(b.locals) ? b.locals[idx + 1] : AnyRef)
    _check!(b)
end
local_set!(b::InstrBuilder, idx::Integer) = (_op!(b, Opcode.LOCAL_SET); _leb_u!(b, idx); validate_pop_any!(b.v); _check!(b))
function local_tee!(b::InstrBuilder, idx::Integer)
    _op!(b, Opcode.LOCAL_TEE); _leb_u!(b, idx)
    # dart2wasm: local_tee(l) is [l.type] → [l.type]
    lt = (idx + 1) <= length(b.locals) ? b.locals[idx + 1] : AnyRef
    validate_pop!(b.v, lt); validate_push!(b.v, lt)
    _check!(b)
end
global_get!(b::InstrBuilder, idx::Integer, typ::WasmValType) = (_op!(b, Opcode.GLOBAL_GET); _leb_u!(b, idx); validate_push!(b.v, typ); _check!(b))
global_set!(b::InstrBuilder, idx::Integer) = (_op!(b, Opcode.GLOBAL_SET); _leb_u!(b, idx); validate_pop_any!(b.v); _check!(b))

# ════════════════════════════════════════════════════════════════════════════════
# Control flow
# ════════════════════════════════════════════════════════════════════════════════
unreachable!(b::InstrBuilder) = (_op!(b, Opcode.UNREACHABLE); b.v.reachable = false; _check!(b))
nop!(b::InstrBuilder) = (_op!(b, Opcode.NOP); _check!(b))

# block/loop with an (immediate) blocktype byte already chosen by the caller (most WT
# blocks are void → 0x40). result_types feeds the validator's end-balance check.
function block!(b::InstrBuilder, blocktype::Integer=0x40; results::Vector{<:Any}=WasmValType[])
    _op!(b, Opcode.BLOCK); _leb_s!(b, blocktype)
    validate_block_start!(b.v, :block, WasmValType[r for r in results]); _check!(b)
end
function loop!(b::InstrBuilder, blocktype::Integer=0x40; results::Vector{<:Any}=WasmValType[])
    _op!(b, Opcode.LOOP); _leb_s!(b, blocktype)
    validate_block_start!(b.v, :loop, WasmValType[r for r in results]); _check!(b)
end
function if_!(b::InstrBuilder, blocktype::Integer=0x40; results::Vector{<:Any}=WasmValType[])
    _op!(b, Opcode.IF); _leb_s!(b, blocktype)
    validate_if_start!(b.v, WasmValType[r for r in results]); _check!(b)
end
else_!(b::InstrBuilder) = (_op!(b, Opcode.ELSE); validate_else!(b.v); _check!(b))
end_block!(b::InstrBuilder) = (_op!(b, Opcode.END); validate_block_end!(b.v); _check!(b))
br!(b::InstrBuilder, depth::Integer) = (_op!(b, Opcode.BR); _leb_u!(b, depth); validate_br!(b.v, Int(depth)); _check!(b))
br_if!(b::InstrBuilder, depth::Integer) = (_op!(b, Opcode.BR_IF); _leb_u!(b, depth); validate_br_if!(b.v, Int(depth)); _check!(b))
function br_table!(b::InstrBuilder, targets::Vector{<:Integer}, default::Integer)
    _op!(b, Opcode.BR_TABLE); _leb_u!(b, length(targets))
    for t in targets; _leb_u!(b, t); end
    _leb_u!(b, default)
    if b.v.reachable; validate_pop!(b.v, I32); b.v.reachable = false; end
    _check!(b)
end
function return_!(b::InstrBuilder)
    _op!(b, Opcode.RETURN); b.v.reachable = false; _check!(b)
end

# call: pop params, push results (caller supplies the signature it already knows).
function call!(b::InstrBuilder, func_idx::Integer, params::Vector{<:Any}, results::Vector{<:Any})
    _op!(b, Opcode.CALL); _leb_u!(b, func_idx)
    if b.v.reachable
        for p in reverse(params); validate_pop!(b.v, p); end
        for r in results; validate_push!(b.v, r); end
    end
    _check!(b)
end

# ════════════════════════════════════════════════════════════════════════════════
# Reference
# ════════════════════════════════════════════════════════════════════════════════
ref_null!(b::InstrBuilder, heaptype::Integer, reftype::WasmValType) =
    (_op!(b, Opcode.REF_NULL); _leb_s!(b, heaptype); validate_push!(b.v, reftype); _check!(b))
# Abstract-heaptype ref.null (any/struct/array/i31/...): the RefType enum value IS the
# single on-wire heaptype byte (dart2wasm encodes HeapType directly), so push it raw —
# NOT LEB-encoded (LEB of 0x6E would be two bytes). Mirrors push!(bytes, UInt8(rt)).
ref_null!(b::InstrBuilder, rt::RefType) =
    (_op!(b, Opcode.REF_NULL); _op!(b, UInt8(rt)); validate_push!(b.v, rt); _check!(b))
ref_func!(b::InstrBuilder, func_idx::Integer, reftype::WasmValType) =
    (_op!(b, Opcode.REF_FUNC); _leb_u!(b, func_idx); validate_push!(b.v, reftype); _check!(b))
ref_is_null!(b::InstrBuilder) = (_op!(b, Opcode.REF_IS_NULL); validate_pop_any!(b.v); validate_push!(b.v, I32); _check!(b))
# dart2wasm: ref_as_non_null output = actual top-of-stack with nullability=false.
function ref_as_non_null!(b::InstrBuilder)
    _op!(b, Opcode.REF_AS_NON_NULL)
    t = validate_pop_any!(b.v)
    nn = t isa ConcreteRef ? ConcreteRef(t.type_idx, false) : (t === nothing ? AnyRef : t)
    validate_push!(b.v, nn)
    _check!(b)
end

# ════════════════════════════════════════════════════════════════════════════════
# WasmGC (type-directed; caller passes the resolved field/element types it already has)
# ════════════════════════════════════════════════════════════════════════════════
function struct_new!(b::InstrBuilder, type_idx::Integer, field_types::Vector{<:Any})
    _op!(b, Opcode.GC_PREFIX); _op!(b, Opcode.STRUCT_NEW); _leb_u!(b, type_idx)
    validate_gc_instruction!(b.v, Opcode.STRUCT_NEW, (type_idx, WasmValType[f for f in field_types])); _check!(b)
end
function struct_new_default!(b::InstrBuilder, type_idx::Integer)
    _op!(b, Opcode.GC_PREFIX); _op!(b, Opcode.STRUCT_NEW_DEFAULT); _leb_u!(b, type_idx)
    validate_gc_instruction!(b.v, Opcode.STRUCT_NEW_DEFAULT, type_idx); _check!(b)
end
function struct_get!(b::InstrBuilder, type_idx::Integer, field_idx::Integer, field_type::WasmValType; signed::Union{Nothing,Bool}=nothing)
    op = signed === nothing ? Opcode.STRUCT_GET : (signed ? Opcode.STRUCT_GET_S : Opcode.STRUCT_GET_U)
    _op!(b, Opcode.GC_PREFIX); _op!(b, op); _leb_u!(b, type_idx); _leb_u!(b, field_idx)
    validate_gc_instruction!(b.v, op, (type_idx, field_type)); _check!(b)
end
function struct_set!(b::InstrBuilder, type_idx::Integer, field_idx::Integer, field_type::WasmValType)
    _op!(b, Opcode.GC_PREFIX); _op!(b, Opcode.STRUCT_SET); _leb_u!(b, type_idx); _leb_u!(b, field_idx)
    validate_gc_instruction!(b.v, Opcode.STRUCT_SET, (type_idx, field_type)); _check!(b)
end
function array_new!(b::InstrBuilder, type_idx::Integer, elem_type::WasmValType)
    _op!(b, Opcode.GC_PREFIX); _op!(b, Opcode.ARRAY_NEW); _leb_u!(b, type_idx)
    validate_gc_instruction!(b.v, Opcode.ARRAY_NEW, (type_idx, elem_type)); _check!(b)
end
function array_new_default!(b::InstrBuilder, type_idx::Integer)
    _op!(b, Opcode.GC_PREFIX); _op!(b, Opcode.ARRAY_NEW_DEFAULT); _leb_u!(b, type_idx)
    validate_gc_instruction!(b.v, Opcode.ARRAY_NEW_DEFAULT, type_idx); _check!(b)
end
function array_new_fixed!(b::InstrBuilder, type_idx::Integer, n::Integer, elem_type::WasmValType)
    _op!(b, Opcode.GC_PREFIX); _op!(b, Opcode.ARRAY_NEW_FIXED); _leb_u!(b, type_idx); _leb_u!(b, n)
    validate_gc_instruction!(b.v, Opcode.ARRAY_NEW_FIXED, (type_idx, elem_type, n)); _check!(b)
end
function array_get!(b::InstrBuilder, type_idx::Integer, elem_type::WasmValType; signed::Union{Nothing,Bool}=nothing)
    op = signed === nothing ? Opcode.ARRAY_GET : (signed ? Opcode.ARRAY_GET_S : Opcode.ARRAY_GET_U)
    _op!(b, Opcode.GC_PREFIX); _op!(b, op); _leb_u!(b, type_idx)
    validate_gc_instruction!(b.v, op, (type_idx, elem_type)); _check!(b)
end
function array_set!(b::InstrBuilder, type_idx::Integer, elem_type::WasmValType)
    _op!(b, Opcode.GC_PREFIX); _op!(b, Opcode.ARRAY_SET); _leb_u!(b, type_idx)
    validate_gc_instruction!(b.v, Opcode.ARRAY_SET, (type_idx, elem_type)); _check!(b)
end
array_len!(b::InstrBuilder) = (_op!(b, Opcode.GC_PREFIX); _op!(b, Opcode.ARRAY_LEN); validate_gc_instruction!(b.v, Opcode.ARRAY_LEN); _check!(b))
function ref_cast!(b::InstrBuilder, type_idx::Integer, nullable::Bool)
    op = nullable ? Opcode.REF_CAST_NULL : Opcode.REF_CAST
    _op!(b, Opcode.GC_PREFIX); _op!(b, op); _leb_s!(b, type_idx)
    validate_gc_instruction!(b.v, op, ConcreteRef(UInt32(type_idx), nullable)); _check!(b)
end
# Cast to an abstract heaptype (i31/array/struct/...): the RefType enum value is the
# single on-wire heaptype byte. Pops a ref, pushes the abstract target type.
function ref_cast!(b::InstrBuilder, rt::RefType, nullable::Bool)
    op = nullable ? Opcode.REF_CAST_NULL : Opcode.REF_CAST
    _op!(b, Opcode.GC_PREFIX); _op!(b, op); _op!(b, UInt8(rt))
    if b.v.reachable; validate_pop_any!(b.v); validate_push!(b.v, rt); end
    _check!(b)
end
any_convert_extern!(b::InstrBuilder) = (_op!(b, Opcode.GC_PREFIX); _op!(b, Opcode.ANY_CONVERT_EXTERN); validate_gc_instruction!(b.v, Opcode.ANY_CONVERT_EXTERN); _check!(b))
extern_convert_any!(b::InstrBuilder) = (_op!(b, Opcode.GC_PREFIX); _op!(b, Opcode.EXTERN_CONVERT_ANY); validate_gc_instruction!(b.v, Opcode.EXTERN_CONVERT_ANY); _check!(b))
select!(b::InstrBuilder) = (_op!(b, Opcode.SELECT); validate_instruction!(b.v, Opcode.SELECT); _check!(b))
function ref_test!(b::InstrBuilder, type_idx::Integer, nullable::Bool)
    op = nullable ? Opcode.REF_TEST_NULL : Opcode.REF_TEST
    _op!(b, Opcode.GC_PREFIX); _op!(b, op); _leb_s!(b, type_idx)
    validate_gc_instruction!(b.v, op); _check!(b)
end
ref_i31!(b::InstrBuilder) = (_op!(b, Opcode.GC_PREFIX); _op!(b, Opcode.REF_I31); validate_gc_instruction!(b.v, Opcode.REF_I31); _check!(b))
i31_get_s!(b::InstrBuilder) = (_op!(b, Opcode.GC_PREFIX); _op!(b, Opcode.I31_GET_S); validate_gc_instruction!(b.v, Opcode.I31_GET_S); _check!(b))
i31_get_u!(b::InstrBuilder) = (_op!(b, Opcode.GC_PREFIX); _op!(b, Opcode.I31_GET_U); validate_gc_instruction!(b.v, Opcode.I31_GET_U); _check!(b))
function array_copy!(b::InstrBuilder, dst_type_idx::Integer, src_type_idx::Integer)
    _op!(b, Opcode.GC_PREFIX); _op!(b, Opcode.ARRAY_COPY); _leb_u!(b, dst_type_idx); _leb_u!(b, src_type_idx)
    validate_gc_instruction!(b.v, Opcode.ARRAY_COPY, (dst_type_idx, src_type_idx)); _check!(b)
end
function array_fill!(b::InstrBuilder, type_idx::Integer, elem_type::WasmValType)
    _op!(b, Opcode.GC_PREFIX); _op!(b, Opcode.ARRAY_FILL); _leb_u!(b, type_idx)
    validate_gc_instruction!(b.v, Opcode.ARRAY_FILL, (type_idx, elem_type)); _check!(b)
end

# ════════════════════════════════════════════════════════════════════════════════
# Transitional bridge: splice already-built raw bytes from an un-migrated callee,
# advancing the stack model by an explicit (pops, pushes) effect the caller supplies.
# Deleted once every emitter is migrated (Phase 6).
# ════════════════════════════════════════════════════════════════════════════════
function emit_raw!(b::InstrBuilder, raw::Vector{UInt8}; pops::Integer=0, pushes::Vector{<:Any}=WasmValType[])
    append!(b.code, raw)
    for _ in 1:pops; validate_pop_any!(b.v); end
    for p in pushes; validate_push!(b.v, p); end
    _check!(b)
end

# Seed the model with stack values produced UPSTREAM (no bytes emitted). For fragment
# emitters that consume a value the (not-yet-migrated) caller already left on the stack,
# so the model starts from the true incoming stack rather than empty.
function seed_input!(b::InstrBuilder, types::Vector{<:Any})
    for t in types; validate_push!(b.v, t); end
    b
end
