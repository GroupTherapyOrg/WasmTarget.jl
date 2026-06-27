# InstrBuilder — dart2wasm `wasm_builder`'s InstructionsBuilder, 1:1.
#
# dart2wasm's three layers: builder/ (typed methods that validate + record) → ir/
# (the Instruction objects) → serialize/ (bytes). This is that:
#   - each typed method validates the operand stack (reusing WasmStackValidator's
#     per-opcode pop/push logic — composition, not duplication) and RECORDS an
#     InstrIR.WasmInstr into `b.instrs` (the ir/ layer);
#   - `builder_code` serializes `b.instrs` to bytes (the serialize/ layer) via the
#     per-class `encode!` methods in instr_ir.jl.
# One representation, no parallel byte path. When `strict`, a stack imbalance THROWS at
# the emit site with Julia source context; during migration it collects so
# partially-migrated functions still build, with the model staying live.
#
# See dev/WASM_BUILDER_MIGRATION.md.

export InstrBuilder, builder_code, builder_disasm, set_strict!, StackImbalanceError,
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
    byte_offset::Int       # serialized byte length at failure
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

Live, self-validating WebAssembly instruction emitter. `.instrs` is the ir/ instruction
stream (serialized to bytes by `builder_code`); `.v` is the operand-stack model
(`WasmStackValidator`); `.locals` types `local.get/set/tee`; GC ops take their
field/element types directly (caller has them, exactly as it does when emitting).
"""
mutable struct InstrBuilder
    instrs::Vector{InstrIR.WasmInstr}   # the ir/ layer — serialized on demand
    v::WasmStackValidator
    locals::Vector{WasmValType}         # param + local types, indexed by local index
    strict::Bool                        # throw on stack imbalance (migrated funcs) vs collect
    func_name::String
    context::String                     # current Julia stmt/op being emitted (diagnostics)
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
    InstrBuilder(InstrIR.WasmInstr[], v, locals, strict, func_name, "", trace)
end

# serialize/ layer: turn the recorded instruction stream into bytes.
function builder_code(b::InstrBuilder)::Vector{UInt8}
    code = UInt8[]
    for instr in b.instrs
        encode!(code, instr)
    end
    code
end
# symbolic disassembly (dart2wasm printTo) — clarity for tracking codegen bugs.
builder_disasm(b::InstrBuilder)::Vector{String} = String[mnemonic(i) for i in b.instrs]
_byte_len(b::InstrBuilder)::Int = length(builder_code(b))

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

# Record an instruction (ir/ layer) + trace, then enforce strictness. Validation has
# already run against the operand-stack model by the calling method.
@inline function _emit!(b::InstrBuilder, instr::InstrIR.WasmInstr)
    push!(b.instrs, instr)
    if b.trace !== nothing
        top = isempty(b.v.stack) ? "-" : string(b.v.stack[end])
        push!(b.trace, "[$(length(b.instrs))] $(mnemonic(instr))   h=$(length(b.v.stack)) top=$top | $(b.context)")
    end
    return _check!(b)
end

# Throw the collected validator errors (if strict) with rich source context, else collect.
@inline function _check!(b::InstrBuilder)
    if b.strict && has_errors(b.v)
        msg = join(b.v.errors, "\n  ")
        empty!(b.v.errors)
        throw(StackImbalanceError(b.func_name, b.context, msg, _stack_snapshot(b), _byte_len(b)))
    end
    return b
end

"""
    builder_diagnose(b) -> String

Full human-readable post-mortem of a builder's state — the symbolic instruction tail,
the operand-stack snapshot, the open control-flow labels (with their base heights/result
types), reachability, the byte length, and any collected (non-strict) errors. Pins a
codegen bug to an exact statement + stack shape with no wasm-tools round-trip.
"""
function builder_diagnose(b::InstrBuilder)::String
    io = IOBuffer()
    println(io, "InstrBuilder `$(b.func_name)` — $(length(b.instrs)) instrs / $(_byte_len(b)) bytes, reachable=$(b.v.reachable)")
    isempty(b.context) || println(io, "  context: ", b.context)
    println(io, "  operand stack (bottom→top): [", join(_stack_snapshot(b), ", "), "]")
    if !isempty(b.v.labels)
        println(io, "  open blocks (outer→inner):")
        for (i, l) in enumerate(b.v.labels)
            println(io, "    [$i] $(l.kind) base=$(l.stack_height_at_entry) results=$(l.result_types) reachable=$(l.reachable_at_entry)")
        end
    end
    dis = builder_disasm(b)
    if !isempty(dis)
        println(io, "  instruction tail (last 40, symbolic):")
        for s in last(dis, 40); println(io, "    ", s); end
    end
    if has_errors(b.v)
        println(io, "  collected errors:")
        for e in b.v.errors; println(io, "    - ", e); end
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

# ════════════════════════════════════════════════════════════════════════════════
# Typed emit methods — validate the operand stack, then record the ir/ instruction.
# (dart2wasm InstructionsBuilder: same names, same type-directed GC stack effects.)
# ════════════════════════════════════════════════════════════════════════════════

# ── Numeric ─────────────────────────────────────────────────────────────────────
i32_const!(b::InstrBuilder, v::Integer) = (validate_push!(b.v, I32); _emit!(b, InstrIR.I32Const(Int64(v))))
i64_const!(b::InstrBuilder, v::Integer) = (validate_push!(b.v, I64); _emit!(b, InstrIR.I64Const(Int64(v))))
f32_const!(b::InstrBuilder, x::Real) = (validate_push!(b.v, F32); _emit!(b, InstrIR.F32Const(Float32(x))))
f64_const!(b::InstrBuilder, x::Real) = (validate_push!(b.v, F64); _emit!(b, InstrIR.F64Const(Float64(x))))
# Generic numeric/comparison/conversion op (no immediates): reuse validate_instruction!.
num!(b::InstrBuilder, op::UInt8) = (validate_instruction!(b.v, op); _emit!(b, InstrIR.NumOp(op)))

# ── Parametric ──────────────────────────────────────────────────────────────────
drop!(b::InstrBuilder) = (validate_pop_any!(b.v); _emit!(b, InstrIR.Drop()))
select!(b::InstrBuilder) = (validate_instruction!(b.v, Opcode.SELECT); _emit!(b, InstrIR.Select()))

# ── Variable ────────────────────────────────────────────────────────────────────
function local_get!(b::InstrBuilder, idx::Integer)
    validate_push!(b.v, (idx + 1) <= length(b.locals) ? b.locals[idx + 1] : AnyRef)
    _emit!(b, InstrIR.LocalGet(UInt32(idx)))
end
local_set!(b::InstrBuilder, idx::Integer) = (validate_pop_any!(b.v); _emit!(b, InstrIR.LocalSet(UInt32(idx))))
function local_tee!(b::InstrBuilder, idx::Integer)
    # dart2wasm: local_tee(l) is [l.type] → [l.type]
    lt = (idx + 1) <= length(b.locals) ? b.locals[idx + 1] : AnyRef
    validate_pop!(b.v, lt); validate_push!(b.v, lt)
    _emit!(b, InstrIR.LocalTee(UInt32(idx)))
end
global_get!(b::InstrBuilder, idx::Integer, typ::WasmValType) = (validate_push!(b.v, typ); _emit!(b, InstrIR.GlobalGet(UInt32(idx))))
global_set!(b::InstrBuilder, idx::Integer) = (validate_pop_any!(b.v); _emit!(b, InstrIR.GlobalSet(UInt32(idx))))

# ── Control flow ────────────────────────────────────────────────────────────────
unreachable!(b::InstrBuilder) = (b.v.reachable = false; _emit!(b, InstrIR.Unreachable()))
nop!(b::InstrBuilder) = _emit!(b, InstrIR.Nop())

# block/loop/if: blocktype is a void byte 0x40 or a WasmValType (I32, ConcreteRef(...));
# encode_block_type (in serialize) handles the single-byte vs multi-byte distinction.
# `results` feeds the validator's end-balance check.
function block!(b::InstrBuilder, blocktype=0x40; results::Vector{<:Any}=WasmValType[])
    validate_block_start!(b.v, :block, WasmValType[r for r in results]); _emit!(b, InstrIR.Block(blocktype))
end
function loop!(b::InstrBuilder, blocktype=0x40; results::Vector{<:Any}=WasmValType[])
    validate_block_start!(b.v, :loop, WasmValType[r for r in results]); _emit!(b, InstrIR.Loop(blocktype))
end
function if_!(b::InstrBuilder, blocktype=0x40; results::Vector{<:Any}=WasmValType[])
    validate_if_start!(b.v, WasmValType[r for r in results]); _emit!(b, InstrIR.If(blocktype))
end
else_!(b::InstrBuilder) = (validate_else!(b.v); _emit!(b, InstrIR.Else()))
end_block!(b::InstrBuilder) = (validate_block_end!(b.v); _emit!(b, InstrIR.End()))
br!(b::InstrBuilder, depth::Integer) = (validate_br!(b.v, Int(depth)); _emit!(b, InstrIR.Br(UInt32(depth))))
br_if!(b::InstrBuilder, depth::Integer) = (validate_br_if!(b.v, Int(depth)); _emit!(b, InstrIR.BrIf(UInt32(depth))))
function br_table!(b::InstrBuilder, targets::Vector{<:Integer}, default::Integer)
    if b.v.reachable; validate_pop!(b.v, I32); b.v.reachable = false; end
    _emit!(b, InstrIR.BrTable(UInt32[UInt32(t) for t in targets], UInt32(default)))
end
return_!(b::InstrBuilder) = (b.v.reachable = false; _emit!(b, InstrIR.Return()))

# call: pop params, push results (caller supplies the signature it already knows).
function call!(b::InstrBuilder, func_idx::Integer, params::Vector{<:Any}, results::Vector{<:Any})
    if b.v.reachable
        for p in reverse(params); validate_pop!(b.v, p); end
        for r in results; validate_push!(b.v, r); end
    end
    _emit!(b, InstrIR.Call(UInt32(func_idx)))
end

# ── Reference ───────────────────────────────────────────────────────────────────
ref_null!(b::InstrBuilder, heaptype::Integer, reftype::WasmValType) =
    (validate_push!(b.v, reftype); _emit!(b, InstrIR.RefNullConcrete(Int64(heaptype))))
# Abstract-heaptype ref.null (any/struct/array/i31/...): the RefType enum value IS the
# single on-wire heaptype byte (dart2wasm encodes HeapType directly).
ref_null!(b::InstrBuilder, rt::RefType) =
    (validate_push!(b.v, rt); _emit!(b, InstrIR.RefNullAbstract(UInt8(rt))))
ref_func!(b::InstrBuilder, func_idx::Integer, reftype::WasmValType) =
    (validate_push!(b.v, reftype); _emit!(b, InstrIR.RefFunc(UInt32(func_idx))))
ref_is_null!(b::InstrBuilder) = (validate_pop_any!(b.v); validate_push!(b.v, I32); _emit!(b, InstrIR.RefIsNull()))
# dart2wasm: ref_as_non_null output = actual top-of-stack with nullability=false.
function ref_as_non_null!(b::InstrBuilder)
    t = validate_pop_any!(b.v)
    nn = t isa ConcreteRef ? ConcreteRef(t.type_idx, false) : (t === nothing ? AnyRef : t)
    validate_push!(b.v, nn)
    _emit!(b, InstrIR.RefAsNonNull())
end

# ── WasmGC (type-directed; caller passes the resolved field/element types it has) ──
function struct_new!(b::InstrBuilder, type_idx::Integer, field_types::Vector{<:Any})
    validate_gc_instruction!(b.v, Opcode.STRUCT_NEW, (type_idx, WasmValType[f for f in field_types]))
    _emit!(b, InstrIR.StructNew(UInt32(type_idx)))
end
function struct_new_default!(b::InstrBuilder, type_idx::Integer)
    validate_gc_instruction!(b.v, Opcode.STRUCT_NEW_DEFAULT, type_idx)
    _emit!(b, InstrIR.StructNewDefault(UInt32(type_idx)))
end
function struct_get!(b::InstrBuilder, type_idx::Integer, field_idx::Integer, field_type::WasmValType; signed::Union{Nothing,Bool}=nothing)
    op = signed === nothing ? Opcode.STRUCT_GET : (signed ? Opcode.STRUCT_GET_S : Opcode.STRUCT_GET_U)
    validate_gc_instruction!(b.v, op, (type_idx, field_type))
    _emit!(b, InstrIR.StructGet(UInt32(type_idx), UInt32(field_idx), op))
end
function struct_set!(b::InstrBuilder, type_idx::Integer, field_idx::Integer, field_type::WasmValType)
    validate_gc_instruction!(b.v, Opcode.STRUCT_SET, (type_idx, field_type))
    _emit!(b, InstrIR.StructSet(UInt32(type_idx), UInt32(field_idx)))
end
function array_new!(b::InstrBuilder, type_idx::Integer, elem_type::WasmValType)
    validate_gc_instruction!(b.v, Opcode.ARRAY_NEW, (type_idx, elem_type))
    _emit!(b, InstrIR.ArrayNew(UInt32(type_idx)))
end
function array_new_default!(b::InstrBuilder, type_idx::Integer)
    validate_gc_instruction!(b.v, Opcode.ARRAY_NEW_DEFAULT, type_idx)
    _emit!(b, InstrIR.ArrayNewDefault(UInt32(type_idx)))
end
function array_new_fixed!(b::InstrBuilder, type_idx::Integer, n::Integer, elem_type::WasmValType)
    validate_gc_instruction!(b.v, Opcode.ARRAY_NEW_FIXED, (type_idx, elem_type, n))
    _emit!(b, InstrIR.ArrayNewFixed(UInt32(type_idx), UInt32(n)))
end
# array.new_data $type $seg : [offset:i32, length:i32] -> [(ref $type)]
function array_new_data!(b::InstrBuilder, type_idx::Integer, seg_idx::Integer)
    if b.v.reachable
        validate_pop!(b.v, I32); validate_pop!(b.v, I32)
        validate_push!(b.v, ConcreteRef(UInt32(type_idx), false))
    end
    _emit!(b, InstrIR.ArrayNewData(UInt32(type_idx), UInt32(seg_idx)))
end
function array_get!(b::InstrBuilder, type_idx::Integer, elem_type::WasmValType; signed::Union{Nothing,Bool}=nothing)
    op = signed === nothing ? Opcode.ARRAY_GET : (signed ? Opcode.ARRAY_GET_S : Opcode.ARRAY_GET_U)
    validate_gc_instruction!(b.v, op, (type_idx, elem_type))
    _emit!(b, InstrIR.ArrayGet(UInt32(type_idx), op))
end
function array_set!(b::InstrBuilder, type_idx::Integer, elem_type::WasmValType)
    validate_gc_instruction!(b.v, Opcode.ARRAY_SET, (type_idx, elem_type))
    _emit!(b, InstrIR.ArraySet(UInt32(type_idx)))
end
array_len!(b::InstrBuilder) = (validate_gc_instruction!(b.v, Opcode.ARRAY_LEN); _emit!(b, InstrIR.ArrayLen()))
function ref_cast!(b::InstrBuilder, type_idx::Integer, nullable::Bool)
    op = nullable ? Opcode.REF_CAST_NULL : Opcode.REF_CAST
    validate_gc_instruction!(b.v, op, ConcreteRef(UInt32(type_idx), nullable))
    _emit!(b, InstrIR.RefCastConcrete(Int64(type_idx), nullable))
end
# Cast to an abstract heaptype (i31/array/struct/...): single on-wire heaptype byte.
function ref_cast!(b::InstrBuilder, rt::RefType, nullable::Bool)
    if b.v.reachable; validate_pop_any!(b.v); validate_push!(b.v, rt); end
    _emit!(b, InstrIR.RefCastAbstract(UInt8(rt), nullable))
end
function ref_test!(b::InstrBuilder, type_idx::Integer, nullable::Bool)
    op = nullable ? Opcode.REF_TEST_NULL : Opcode.REF_TEST
    validate_gc_instruction!(b.v, op)
    _emit!(b, InstrIR.RefTest(Int64(type_idx), nullable))
end
any_convert_extern!(b::InstrBuilder) = (validate_gc_instruction!(b.v, Opcode.ANY_CONVERT_EXTERN); _emit!(b, InstrIR.AnyConvertExtern()))
extern_convert_any!(b::InstrBuilder) = (validate_gc_instruction!(b.v, Opcode.EXTERN_CONVERT_ANY); _emit!(b, InstrIR.ExternConvertAny()))
ref_i31!(b::InstrBuilder) = (validate_gc_instruction!(b.v, Opcode.REF_I31); _emit!(b, InstrIR.RefI31()))
i31_get_s!(b::InstrBuilder) = (validate_gc_instruction!(b.v, Opcode.I31_GET_S); _emit!(b, InstrIR.I31GetS()))
i31_get_u!(b::InstrBuilder) = (validate_gc_instruction!(b.v, Opcode.I31_GET_U); _emit!(b, InstrIR.I31GetU()))
function array_copy!(b::InstrBuilder, dst_type_idx::Integer, src_type_idx::Integer)
    validate_gc_instruction!(b.v, Opcode.ARRAY_COPY, (dst_type_idx, src_type_idx))
    _emit!(b, InstrIR.ArrayCopy(UInt32(dst_type_idx), UInt32(src_type_idx)))
end
function array_fill!(b::InstrBuilder, type_idx::Integer, elem_type::WasmValType)
    validate_gc_instruction!(b.v, Opcode.ARRAY_FILL, (type_idx, elem_type))
    _emit!(b, InstrIR.ArrayFill(UInt32(type_idx)))
end

# ════════════════════════════════════════════════════════════════════════════════
# Transitional bridge: splice already-built raw bytes from an un-migrated callee as a
# RawBytes instruction, advancing the stack model by an explicit (pops, pushes) effect.
# Deleted once every emitter is migrated (Phase 6).
# ════════════════════════════════════════════════════════════════════════════════
function emit_raw!(b::InstrBuilder, raw::Vector{UInt8}; pops::Integer=0, pushes::Vector{<:Any}=WasmValType[])
    for _ in 1:pops; validate_pop_any!(b.v); end
    for p in pushes; validate_push!(b.v, p); end
    _emit!(b, InstrIR.RawBytes(raw))
end

# Seed the model with stack values produced UPSTREAM (no instruction emitted). For
# fragment emitters that consume a value the (not-yet-migrated) caller already left on
# the stack, so the model starts from the true incoming stack rather than empty.
function seed_input!(b::InstrBuilder, types::Vector{<:Any})
    for t in types; validate_push!(b.v, t); end
    b
end
