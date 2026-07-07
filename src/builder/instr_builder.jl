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
       set_context!, builder_diagnose, append_builder!

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
    # fullstrict: LIVE locals provider (a codegen-supplied closure idx→WasmValType) —
    # the static b.locals snapshot goes stale when locals are allocated AFTER builder
    # creation (the tracker then guessed AnyRef and every downstream op mismatched).
    locals_fn::Union{Nothing, Function}
    seeded::Vector{WasmValType}         # inputs recorded by seed_input! (typed merges)
end

function InstrBuilder(param_types::Vector{<:Any}=WasmValType[],
                      result_types::Vector{<:Any}=WasmValType[];
                      func_name::String="", strict::Bool=_wt_builder_strict(), mod=nothing)
    locals = WasmValType[p for p in param_types]
    # `mod` (the WasmModule) lets the validator's `wasm_subtype` resolve ConcreteRef
    # supertype chains. Threaded from codegen sites that have `ctx.mod` in scope (the
    # ref-flowing builders); `nothing` for numeric-only emitters that never push a
    # ConcreteRef, where the heap-kind branch is never reached.
    v = WasmStackValidator(; enabled=true, func_name=func_name, mod=mod)
    # Seed the outermost label as a :block whose results are the function results,
    # so end-of-function balance is checked against the declared results.
    push!(v.labels, ValidatorLabel(:block, 0, WasmValType[r for r in result_types], true))
    trace = haskey(ENV, "WT_BUILDER_TRACE") ? String[] : nothing
    InstrBuilder(InstrIR.WasmInstr[], v, locals, strict, func_name, "", trace, nothing, WasmValType[])
end

# serialize/ layer: turn the recorded instruction stream into bytes.
function builder_code(b::InstrBuilder)::Vector{UInt8}
    # march17 harvest: surface every collect-mode violation WITHOUT throwing —
    # the burn-down list generator (strip after the flip).
    if haskey(ENV, "WT_STRICT_HARVEST") && has_errors(b.v)
        for e in b.v.errors
            println(stderr, "HARVEST| ", b.func_name, " | ", first(e, 160))
        end
    end
    code = UInt8[]
    for i in eachindex(b.instrs)
        if !isassigned(b.instrs, i)
            around = [isassigned(b.instrs, j) ? string(nameof(typeof(b.instrs[j]))) : "#undef"
                      for j in max(1, i-3):min(length(b.instrs), i+3)]
            nundef = count(j -> !isassigned(b.instrs, j), eachindex(b.instrs))
            lastundef = findlast(j -> !isassigned(b.instrs, j), eachindex(b.instrs))
            error("builder_code($(b.func_name)): UNDEF instr slot $i of $(length(b.instrs)); n_undef=$nundef last_undef=$lastundef; window=$(join(around, ","))")
        end
        encode!(code, b.instrs[i])
    end
    code
end
# symbolic disassembly (dart2wasm printTo) — clarity for tracking codegen bugs.
builder_disasm(b::InstrBuilder)::Vector{String} = String[mnemonic(i) for i in b.instrs]
_byte_len(b::InstrBuilder)::Int = length(builder_code(b))

set_strict!(b::InstrBuilder, s::Bool) = (b.strict = s; b)

"""
    _wt_builder_strict() -> Bool

Default strict-mode for emitters (parity M4 — dart wasm_builder instructions.dart:98:
the builder is a type-checking abstract interpreter that THROWS on an ill-typed emit).
**ON by default since 2026-07-01**, certified by a full capped `Pkg.test` + fuzz run under
`WT_BUILDER_STRICT=1` (10 shards 2,681 + fuzz 293, zero failures). An ill-typed emission
now fails AT THE EMIT SITE with the offending Julia statement + stack snapshot — valid by
construction, beyond dart (whose checks are assert-gated). Escape hatch for debugging only:
`WT_BUILDER_STRICT=0`. Builders constructed with an explicit per-builder
opt-out (the remaining M4 burn-down list, ratchet R6) stay in collect mode until converted.
"""
_wt_builder_strict() = get(ENV, "WT_BUILDER_STRICT", "") != "0"
"Set the high-level context (Julia statement) the next emits belong to — surfaces in errors."
set_context!(b::InstrBuilder, ctx::AbstractString) = (b.context = String(ctx); b.v.context_hint = b.context; b)

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
        # march17 STAGED ENFORCEMENT: UNDERFLOWS (structural stack integrity) THROW;
        # type mismatches COLLECT until the typed-value-channel campaign zeroes them
        # (they're tracked-type disagreements, some tracker-conservative). dart throws
        # on both; WT gets there in two steps. Harvest stays visible for both.
        local _uf = any(startswith(e, "UNDERFLOW") for e in b.v.errors)
        if _uf
            msg = join(b.v.errors, "\n  ")
            # march17: under WT_BUILDER_TRACE the throw carries the emit log's tail
            if b.trace !== nothing && !isempty(b.trace)
                msg *= "\n  trace tail:\n    " * join(b.trace[max(1, end-14):end], "\n    ")
            end
            empty!(b.v.errors)
            throw(StackImbalanceError(b.func_name, b.context, msg, _stack_snapshot(b), _byte_len(b)))
        end
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

# Saturating truncation (FC-prefixed, sub-op 0x00–0x07): pop a float, push an int. The
# sub-op encodes both: to = i32 (<0x04) or i64; from = f32 (0x00,0x01,0x04,0x05) or f64.
function trunc_sat!(b::InstrBuilder, sub_op::UInt8)
    to   = sub_op < 0x04 ? I32 : I64
    from = (sub_op == 0x00 || sub_op == 0x01 || sub_op == 0x04 || sub_op == 0x05) ? F32 : F64
    validate_pop!(b.v, from)
    validate_push!(b.v, to)
    _emit!(b, InstrIR.TruncSat(sub_op))
end

# ── Parametric ──────────────────────────────────────────────────────────────────
drop!(b::InstrBuilder) = (validate_pop_any!(b.v); _emit!(b, InstrIR.Drop()))
select!(b::InstrBuilder) = (validate_instruction!(b.v, Opcode.SELECT); _emit!(b, InstrIR.Select()))

# ── Variable ────────────────────────────────────────────────────────────────────
# fullstrict: the LIVE type for a local — the provider (fresh truth) outranks the
# static snapshot; AnyRef only when neither knows.
@inline _local_type(b::InstrBuilder, idx::Integer)::WasmValType = begin
    if b.locals_fn !== nothing
        local t = b.locals_fn(Int(idx))
        t isa WasmValType && return t
    end
    (idx + 1) <= length(b.locals) ? b.locals[idx + 1] : AnyRef
end

function local_get!(b::InstrBuilder, idx::Integer)
    validate_push!(b.v, _local_type(b, idx))
    _emit!(b, InstrIR.LocalGet(UInt32(idx)))
end
function local_set!(b::InstrBuilder, idx::Integer)
    # dart parity: local.set validates the value against the LOCAL's type when known
    # (a store is [local.type] → []; pop_any hid ill-typed stores until instantiation).
    if b.locals_fn !== nothing || (idx + 1) <= length(b.locals)
        validate_pop!(b.v, _local_type(b, idx))
    else
        validate_pop_any!(b.v)
    end
    _emit!(b, InstrIR.LocalSet(UInt32(idx)))
end
function local_tee!(b::InstrBuilder, idx::Integer)
    # dart2wasm: local_tee(l) is [l.type] → [l.type]
    lt = _local_type(b, idx)   # fullstrict: the live provider
    validate_pop!(b.v, lt); validate_push!(b.v, lt)
    _emit!(b, InstrIR.LocalTee(UInt32(idx)))
end
function global_get!(b::InstrBuilder, idx::Integer, typ::WasmValType)
    # fullstrict: the module's declared global valtype outranks the caller's claim
    local m = b.v.mod
    local t = (m !== nothing && (idx + 1) <= length(m.globals)) ? m.globals[idx + 1].valtype : typ
    validate_push!(b.v, t isa WasmValType ? t : typ)
    _emit!(b, InstrIR.GlobalGet(UInt32(idx)))
end
global_set!(b::InstrBuilder, idx::Integer) = (validate_pop_any!(b.v); _emit!(b, InstrIR.GlobalSet(UInt32(idx))))

# ── Control flow ────────────────────────────────────────────────────────────────
unreachable!(b::InstrBuilder) = (b.v.reachable = false; _emit!(b, InstrIR.Unreachable()))
nop!(b::InstrBuilder) = _emit!(b, InstrIR.Nop())

# block/loop/if: blocktype is a void byte 0x40 or a WasmValType (I32, ConcreteRef(...));
# encode_block_type (in serialize) handles the single-byte vs multi-byte distinction.
# `results` feeds the validator's end-balance check.
# march17 THE CHOKEPOINT FIX: a positional VALUE-TYPE blocktype reached the BYTES but
# never the TRACKER (results came only from the kwarg) — every `if_!(b, I32)` was
# tracker-void, its value silently discarded at end, and everything downstream
# under-counted (the .block strict family). Derive the tracked results from the
# positional blocktype when the kwarg is empty. (An Int blocktype = an s33 type-index
# multi-value frame — callers pass `results` explicitly there.)
@inline _blocktype_results(blocktype, results)::Vector{WasmValType} =
    !isempty(results) ? WasmValType[r for r in results] :
    (blocktype === 0x40 || blocktype isa Int) ? WasmValType[] :
    blocktype isa WasmValType ? WasmValType[blocktype] : WasmValType[]

function block!(b::InstrBuilder, blocktype=0x40; results::Vector{<:Any}=WasmValType[])
    validate_block_start!(b.v, :block, _blocktype_results(blocktype, results)); _emit!(b, InstrIR.Block(blocktype))
end
function loop!(b::InstrBuilder, blocktype=0x40; results::Vector{<:Any}=WasmValType[])
    validate_block_start!(b.v, :loop, _blocktype_results(blocktype, results)); _emit!(b, InstrIR.Loop(blocktype))
end
function if_!(b::InstrBuilder, blocktype=0x40; results::Vector{<:Any}=WasmValType[])
    validate_if_start!(b.v, _blocktype_results(blocktype, results)); _emit!(b, InstrIR.If(blocktype))
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

# call_indirect: pop table-index (i32) then params, push results. Caller supplies the
# signature it already knows (same as call!).
function call_indirect!(b::InstrBuilder, type_idx::Integer, table_idx::Integer, params::Vector{<:Any}, results::Vector{<:Any})
    if b.v.reachable
        validate_pop!(b.v, I32)  # the function index into the table
        for p in reverse(params); validate_pop!(b.v, p); end
        for r in results; validate_push!(b.v, r); end
    end
    _emit!(b, InstrIR.CallIndirect(UInt32(type_idx), UInt32(table_idx)))
end

# call_ref: pop the (ref $type) callee, then params, push results. The caller supplies the
# signature it already knows (same contract as call!/call_indirect!), and `type_idx` is the
# function-type index (dart2wasm CallRef writes the type index after 0x14).
function call_ref!(b::InstrBuilder, type_idx::Integer, params::Vector{<:Any}, results::Vector{<:Any})
    if b.v.reachable
        validate_pop_any!(b.v)  # the (ref $type) function reference on top
        for p in reverse(params); validate_pop!(b.v, p); end
        for r in results; validate_push!(b.v, r); end
    end
    _emit!(b, InstrIR.CallRef(UInt32(type_idx)))
end

# br_on_null: [(ref null ht)] -> [(ref ht)] on fallthrough; branches to `depth` with the
# null stripped (dart2wasm br_on_null). On fallthrough the top becomes non-null; reachability
# stays true (conditional). Validate the branch target like br_if! (without popping the value).
function br_on_null!(b::InstrBuilder, depth::Integer)
    if b.v.reachable
        t = validate_pop_any!(b.v)
        nn = t isa ConcreteRef ? ConcreteRef(t.type_idx, false) : (t === nothing ? AnyRef : t)
        validate_push!(b.v, nn)
    end
    _emit!(b, InstrIR.BrOnNull(UInt32(depth)))
end

# br_on_non_null: [(ref null ht)] -> [] on fallthrough; branches to `depth` carrying the
# non-null ref (dart2wasm br_on_non_null). On fallthrough the ref is consumed; reachable stays.
function br_on_non_null!(b::InstrBuilder, depth::Integer)
    b.v.reachable && validate_pop_any!(b.v)
    _emit!(b, InstrIR.BrOnNonNull(UInt32(depth)))
end

# ── Parametric: typed select ──────────────────────────────────────────────────────
# select (typed, 0x1C): pop i32 condition, pop T, pop T, push T — same operand-stack
# effect as untyped select (the validator's SELECT/SELECT_T path is shared). `type_bytes`
# are the EXACT on-wire result-valtype bytes the caller already has (e.g.
# `[0x63, encode_leb128_signed(type_idx)...]` for a nullable concrete ref), serialized
# verbatim after the 0x1C + vec-len-1 prefix (dart2wasm SelectWithType).
function select_t!(b::InstrBuilder, type_bytes::Vector{UInt8})
    validate_instruction!(b.v, Opcode.SELECT_T)
    _emit!(b, InstrIR.SelectWithType(copy(type_bytes)))
end

# ── Exception handling (Wasm 3.0) ─────────────────────────────────────────────────
# Catch-clause constructors a caller hands to `try_table!`. Label is the branch target
# depth at the point of the try_table (dart2wasm passes a Label; here the caller resolves
# it to a depth, exactly as it already does for br!/br_if!).
catch_clause(tag::Integer, label::Integer)      = InstrIR.TryCatch(Opcode.CATCH,         UInt32(tag), UInt32(label))
catch_ref_clause(tag::Integer, label::Integer)  = InstrIR.TryCatch(Opcode.CATCH_REF,     UInt32(tag), UInt32(label))
catch_all_clause(label::Integer)                = InstrIR.TryCatch(Opcode.CATCH_ALL,     typemax(UInt32), UInt32(label))
catch_all_ref_clause(label::Integer)            = InstrIR.TryCatch(Opcode.CATCH_ALL_REF, typemax(UInt32), UInt32(label))

# try_table: a block opener carrying catch clauses (dart2wasm `try_table`). Blocktype is a
# void byte 0x40 or a WasmValType; `results` feeds the validator's end-balance check. The
# catch handlers branch OUT of the try_table to their target labels (validated at br time),
# so here we only start the block label — matching how block!/loop! work.
function try_table!(b::InstrBuilder, catches::Vector{InstrIR.TryCatch}, blocktype=0x40; results::Vector{<:Any}=WasmValType[])
    validate_block_start!(b.v, :block, WasmValType[r for r in results])
    _emit!(b, InstrIR.TryTable(blocktype, catches))
end
# throw tag: pop the tag's inputs (caller declares them), then unreachable (dart2wasm throw_).
function throw_!(b::InstrBuilder, tag::Integer; inputs::Vector{<:Any}=WasmValType[])
    if b.v.reachable
        for t in reverse(inputs); validate_pop!(b.v, t); end
    end
    b.v.reachable = false
    _emit!(b, InstrIR.Throw(UInt32(tag)))
end
# throw_ref: pop the exnref operand, then unreachable (dart2wasm throw_ref).
throw_ref!(b::InstrBuilder) = (b.v.reachable && validate_pop_any!(b.v); b.v.reachable = false; _emit!(b, InstrIR.ThrowRef()))
# rethrow label: no stack change, then unreachable (dart2wasm rethrow_).
rethrow_!(b::InstrBuilder, depth::Integer) = (b.v.reachable = false; _emit!(b, InstrIR.Rethrow(UInt32(depth))))

# ── Reference ───────────────────────────────────────────────────────────────────
ref_null!(b::InstrBuilder, heaptype::Integer, reftype::WasmValType) =
    (validate_push!(b.v, reftype); _emit!(b, InstrIR.RefNullConcrete(Int64(heaptype))))
# Abstract-heaptype ref.null (any/struct/array/i31/...): the RefType enum value IS the
# single on-wire heaptype byte (dart2wasm encodes HeapType directly).
ref_null!(b::InstrBuilder, rt::RefType) =
    (validate_push!(b.v, rt); _emit!(b, InstrIR.RefNullAbstract(UInt8(rt))))
# ref.null none (heaptype 0x71, the bottom of the any hierarchy — not a RefType enum
# value; tracked as anyref, which every none ref is a subtype of).
ref_null_none!(b::InstrBuilder) =
    (validate_push!(b.v, AnyRef); _emit!(b, InstrIR.RefNullAbstract(0x71)))
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
# march3: mod-resolving form (dart wasm_builder — the instruction knows its type).
# Pops the REAL declared field list from the module; the empty-list fudge (which
# left every operand phantom-tracked — the value-channel liar class) has no home here.
function struct_new!(b::InstrBuilder, type_idx::Integer)
    local _mod = b.v.mod
    local _ft = if _mod !== nothing && type_idx + 1 >= 1 && type_idx + 1 <= length(_mod.types) &&
                   _mod.types[type_idx + 1] isa StructType
        WasmValType[f.valtype for f in _mod.types[type_idx + 1].fields]
    else
        error("struct_new!(b, $type_idx): module type definition unavailable — pass the field list explicitly")
    end
    struct_new!(b, type_idx, _ft)
end
function struct_new_default!(b::InstrBuilder, type_idx::Integer)
    validate_gc_instruction!(b.v, Opcode.STRUCT_NEW_DEFAULT, type_idx)
    _emit!(b, InstrIR.StructNewDefault(UInt32(type_idx)))
end
# fullstrict (valid-by-construction): the MODULE knows every struct's field types —
# DERIVE the truth there instead of trusting the caller's declaration (dozens of sites
# declared AnyRef over typed fields, silently poisoning the tracker downstream). The
# declared param stays as the fallback when the module/type is unavailable.
@inline function _true_field_type(b::InstrBuilder, type_idx::Integer, field_idx::Integer, declared::WasmValType)::WasmValType
    m = b.v.mod
    m === nothing && return declared
    (type_idx + 1) <= length(m.types) || return declared
    local ct = m.types[type_idx + 1]
    ct isa StructType || return declared
    (field_idx + 1) <= length(ct.fields) || return declared
    local ft = ct.fields[field_idx + 1].valtype
    # packed i8/i16 storage reads as i32
    ft isa UInt8 && ft in (0x78, 0x77) && return I32
    return ft isa WasmValType ? ft : declared
end

function struct_get!(b::InstrBuilder, type_idx::Integer, field_idx::Integer, field_type::WasmValType; signed::Union{Nothing,Bool}=nothing)
    op = signed === nothing ? Opcode.STRUCT_GET : (signed ? Opcode.STRUCT_GET_S : Opcode.STRUCT_GET_U)
    validate_gc_instruction!(b.v, op, (type_idx, _true_field_type(b, type_idx, field_idx, field_type)))
    _emit!(b, InstrIR.StructGet(UInt32(type_idx), UInt32(field_idx), op))
end
function struct_set!(b::InstrBuilder, type_idx::Integer, field_idx::Integer, field_type::WasmValType)
    validate_gc_instruction!(b.v, Opcode.STRUCT_SET, (type_idx, _true_field_type(b, type_idx, field_idx, field_type)))
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
# fullstrict: the module's array elem truth (packed i8/i16 read as i32)
@inline function _true_elem_type(b::InstrBuilder, type_idx::Integer, declared::WasmValType)::WasmValType
    m = b.v.mod
    m === nothing && return declared
    (type_idx + 1) <= length(m.types) || return declared
    local ct = m.types[type_idx + 1]
    ct isa ArrayType || return declared
    local ft = ct.elem.valtype
    ft isa UInt8 && ft in (0x78, 0x77) && return I32
    return ft isa WasmValType ? ft : declared
end

function array_get!(b::InstrBuilder, type_idx::Integer, elem_type::WasmValType; signed::Union{Nothing,Bool}=nothing)
    op = signed === nothing ? Opcode.ARRAY_GET : (signed ? Opcode.ARRAY_GET_S : Opcode.ARRAY_GET_U)
    validate_gc_instruction!(b.v, op, (type_idx, _true_elem_type(b, type_idx, elem_type)))
    _emit!(b, InstrIR.ArrayGet(UInt32(type_idx), op))
end
function array_set!(b::InstrBuilder, type_idx::Integer, elem_type::WasmValType)
    validate_gc_instruction!(b.v, Opcode.ARRAY_SET, (type_idx, _true_elem_type(b, type_idx, elem_type)))
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
# array.new_elem $type $seg : [offset:i32 length:i32] -> [(ref $type)] (sibling of array.new_data).
function array_new_elem!(b::InstrBuilder, type_idx::Integer, seg_idx::Integer)
    if b.v.reachable
        validate_pop!(b.v, I32); validate_pop!(b.v, I32)
        validate_push!(b.v, ConcreteRef(UInt32(type_idx), false))
    end
    _emit!(b, InstrIR.ArrayNewElem(UInt32(type_idx), UInt32(seg_idx)))
end

# br_on_cast / br_on_cast_fail: a cast that branches on success/failure (dart2wasm br_on_cast).
# `src_heap`/`dst_heap` are the EXACT on-wire source/target heaptype bytes the caller already
# has (a single byte for an abstract heaptype, or `encode_leb128_signed(type_idx)` for a
# concrete type index). `src_nullable`/`dst_nullable` build the flags byte (bit0 src, bit1 dst).
# Stack model (fallthrough): the top ref takes the *fallthrough* result type; the branch edge's
# arity is checked at the target label exactly as br!/br_if! do. Reachability stays true.
function _br_on_cast_flags(src_nullable::Bool, dst_nullable::Bool)::UInt8
    UInt8((src_nullable ? 0x01 : 0x00) | (dst_nullable ? 0x02 : 0x00))
end
function br_on_cast!(b::InstrBuilder, depth::Integer, src_heap::Vector{UInt8}, dst_heap::Vector{UInt8},
                     dst_reftype::WasmValType; src_nullable::Bool=true, dst_nullable::Bool=false)
    # br_on_cast: branches when the cast SUCCEEDS; on fallthrough the value FAILED the cast, so
    # the top keeps the source ref type (we leave it untouched). dart2wasm verifies the branch
    # carries dst_reftype; here we model fallthrough (no net stack change) + record the op.
    flags = _br_on_cast_flags(src_nullable, dst_nullable)
    _emit!(b, InstrIR.BrOnCast(flags, UInt32(depth), copy(src_heap), copy(dst_heap)))
end
function br_on_cast_fail!(b::InstrBuilder, depth::Integer, src_heap::Vector{UInt8}, dst_heap::Vector{UInt8},
                          dst_reftype::WasmValType; src_nullable::Bool=true, dst_nullable::Bool=false)
    # br_on_cast_fail: branches when the cast FAILS; on fallthrough the value SUCCEEDED, so the
    # top is refined to dst_reftype.
    if b.v.reachable
        validate_pop_any!(b.v); validate_push!(b.v, dst_reftype)
    end
    flags = _br_on_cast_flags(src_nullable, dst_nullable)
    _emit!(b, InstrIR.BrOnCastFail(flags, UInt32(depth), copy(src_heap), copy(dst_heap)))
end

# ── Table ─────────────────────────────────────────────────────────────────────────
# table.get $t : [i32] -> [elemtype]; the caller supplies the table's element type.
function table_get!(b::InstrBuilder, table_idx::Integer, elem_type::WasmValType)
    if b.v.reachable; validate_pop!(b.v, I32); validate_push!(b.v, elem_type); end
    _emit!(b, InstrIR.TableGet(UInt32(table_idx)))
end
# table.set $t : [i32 elemtype] -> []
function table_set!(b::InstrBuilder, table_idx::Integer)
    if b.v.reachable; validate_pop_any!(b.v); validate_pop!(b.v, I32); end
    _emit!(b, InstrIR.TableSet(UInt32(table_idx)))
end
# table.size $t : [] -> [i32]
table_size!(b::InstrBuilder, table_idx::Integer) = (validate_push!(b.v, I32); _emit!(b, InstrIR.TableSize(UInt32(table_idx))))
# table.grow $t : [elemtype i32] -> [i32]
function table_grow!(b::InstrBuilder, table_idx::Integer)
    if b.v.reachable; validate_pop!(b.v, I32); validate_pop_any!(b.v); validate_push!(b.v, I32); end
    _emit!(b, InstrIR.TableGrow(UInt32(table_idx)))
end
# table.fill $t : [i32 elemtype i32] -> []
function table_fill!(b::InstrBuilder, table_idx::Integer)
    if b.v.reachable; validate_pop!(b.v, I32); validate_pop_any!(b.v); validate_pop!(b.v, I32); end
    _emit!(b, InstrIR.TableFill(UInt32(table_idx)))
end

# ── Bulk memory ───────────────────────────────────────────────────────────────────
# memory.init $seg $mem : [dst:i32 src_off:i32 len:i32] -> []
function memory_init!(b::InstrBuilder, seg_idx::Integer, mem_idx::Integer=0)
    if b.v.reachable; validate_pop!(b.v, I32); validate_pop!(b.v, I32); validate_pop!(b.v, I32); end
    _emit!(b, InstrIR.MemoryInit(UInt32(seg_idx), UInt32(mem_idx)))
end
# data.drop $seg : [] -> []
data_drop!(b::InstrBuilder, seg_idx::Integer) = _emit!(b, InstrIR.DataDrop(UInt32(seg_idx)))
# memory.copy $dst $src : [dst:i32 src:i32 len:i32] -> []
function memory_copy!(b::InstrBuilder, dst_mem::Integer=0, src_mem::Integer=0)
    if b.v.reachable; validate_pop!(b.v, I32); validate_pop!(b.v, I32); validate_pop!(b.v, I32); end
    _emit!(b, InstrIR.MemoryCopy(UInt32(dst_mem), UInt32(src_mem)))
end
# memory.fill $mem : [dst:i32 val:i32 len:i32] -> []
function memory_fill!(b::InstrBuilder, mem_idx::Integer=0)
    if b.v.reachable; validate_pop!(b.v, I32); validate_pop!(b.v, I32); validate_pop!(b.v, I32); end
    _emit!(b, InstrIR.MemoryFill(UInt32(mem_idx)))
end

# ════════════════════════════════════════════════════════════════════════════════
# Transitional bridge: splice already-built raw bytes from an un-migrated callee as a
# RawBytes instruction, advancing the stack model by an explicit (pops, pushes) effect.
# Deleted once every emitter is migrated (Phase 6).
# ════════════════════════════════════════════════════════════════════════════════
function emit_raw!(b::InstrBuilder, raw::Vector{UInt8}; pops::Integer=0, pushes::Vector{<:Any}=WasmValType[])
    for _ in 1:pops; validate_pop_any!(b.v); end
    for p in pushes; validate_push!(b.v, p); end
    # A zero-byte splice records NO instruction (the declared effects above still
    # apply to the model) — `isempty(b.instrs)` keeps meaning "emits nothing",
    # exactly like the byte-era `isempty(bytes)` tests it replaced.
    isempty(raw) && return _check!(b)
    _emit!(b, InstrIR.RawBytes(raw))
end

# Seed the model with stack values produced UPSTREAM (no instruction emitted). For
# fragment emitters that consume a value the (not-yet-migrated) caller already left on
# the stack, so the model starts from the true incoming stack rather than empty.
# Seeds are RECORDED so append_builder! can replay the fragment's true stack effect.
function seed_input!(b::InstrBuilder, types::Vector{<:Any})
    for t in types
        validate_push!(b.v, t)
        push!(b.seeded, t)
    end
    b
end

"""
    append_builder!(dst, src)

Typed builder merge — the machine-tracked replacement for
`emit_raw!(dst, builder_code(src); pops=…, pushes=…)`. `dst` pops exactly what
`src` was seeded with (`src.seeded`, in reverse) and pushes `src`'s tracked final
stack; the instruction stream transfers at the ir/ layer. No byte round-trip and
NO human-declared effects — the fragment's real, validator-tracked stack shape
transfers, so a mis-declared splice is impossible at these seams.
"""
function append_builder!(dst::InstrBuilder, src::InstrBuilder)
    if length(src.v.labels) != 1
        # locate the underflow: depth trace over the instr kinds
        local _d = 1
        local _report = ""
        for (_ix, _ins) in enumerate(src.instrs)
            if _ins isa InstrIR.Block || _ins isa InstrIR.Loop || _ins isa InstrIR.If || _ins isa InstrIR.TryTable
                _d += 1
            elseif _ins isa InstrIR.End
                _d -= 1
                if _d <= 0 && isempty(_report)
                    local _w = [string(nameof(typeof(src.instrs[j]))) for j in max(1,_ix-6):min(length(src.instrs),_ix+4)]
                    _report = "UNDERFLOW at instr $_ix/$(length(src.instrs)); window=$(join(_w, ","))"
                end
            end
        end
        error("append_builder!($(dst.func_name) ← $(src.func_name)) [$(get(ENV, "WT_CUR_FN", "?"))]: source has open control labels: " *
              "$(length(src.v.labels)) labels; $_report")
    end
    # march17: fragment violations PROPAGATE — they were silently dropped here,
    # which is why per-emit strict threw while the top-level harvest saw nothing.
    if has_errors(src.v)
        local _mctx = isempty(dst.context) ? "" : " ⟨$(first(dst.context, 60))⟩"
        append!(dst.v.errors, ("[via $(src.func_name)$(_mctx)] " * e for e in src.v.errors))
        empty!(src.v.errors)
    end
    for t in Iterators.reverse(src.seeded)
        validate_pop!(dst.v, t)
    end
    # Transfer the tracked stack ALWAYS — downstream emission decisions read
    # dst.v.stack (the wrap chokepoint's actual-type). An unreachable tail
    # additionally poisons reachability (polymorphic stack, wasm-spec style).
    for t in src.v.stack
        validate_push!(dst.v, t)
    end
    src.v.reachable || (dst.v.reachable = false)
    # JULIA-113-RC1 WORKAROUND: bulk `append!` on these abstract-eltype Memory-backed
    # vectors nondeterministically leaves an UNDEF TAIL in the copied region under
    # 1.13.0-rc1 (clean source verified immediately before; holes end exactly at the
    # append boundary; GC-timing dependent; not reproducible in isolation). Element-wise
    # push! writes each slot at transfer time and is immune. Semantically identical.
    sizehint!(dst.instrs, length(dst.instrs) + length(src.instrs))
    for ins in src.instrs
        push!(dst.instrs, ins)
    end
    return _check!(dst)
end
