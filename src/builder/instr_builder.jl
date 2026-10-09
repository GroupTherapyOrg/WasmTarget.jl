# InstrBuilder — dart2wasm `wasm_builder`'s InstructionsBuilder, 1:1.
#
# dart2wasm's three layers: builder/ (typed methods that validate + record) → ir/
# (the Instruction objects) → serialize/ (bytes). This is that:
#   - each typed method validates the operand stack (reusing WasmStackValidator's
#     per-opcode pop/push logic — composition, not duplication) and RECORDS an
#     InstrIR.WasmInstr into `b.instrs` (the ir/ layer);
#   - `builder_code` serializes `b.instrs` to bytes (the serialize/ layer) via the
#     per-class `encode!` methods in instr_ir.jl.
# One representation, no parallel byte path. Every imbalance THROWS at the emit site
# with Julia source context; validation is an invariant, not a mode.
#
# See dev/HISTORY.md#typed-builder-and-cleanup-campaigns.

export InstrBuilder, builder_code, builder_disasm, finish_function!, StackImbalanceError,
       set_context!, builder_diagnose, append_builder!

"""
    StackImbalanceError

Thrown by an `InstrBuilder` when an emit would unbalance/mistype the
operand stack — the build-time, source-located equivalent of `wasm-tools`'
"values remaining on stack", but caught AT THE EMIT SITE with the offending Julia
statement, the live operand-stack snapshot, and the byte offset. This is the
precision bug-finder for WasmTarget: where wasm-tools says "func 14 @ 0xcc18",
this says which Julia statement and what was on the stack.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:20 ValidationError)
"""
struct StackImbalanceError <: Exception
    func_name::String
    context::String        # the Julia statement / high-level op being emitted
    message::String        # the specific validator complaint(s)
    stack::Vector{String}  # operand-stack snapshot (types, bottom→top) at failure
    byte_offset::Int       # serialized byte length at failure
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:27 ValidationError.toString)
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
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:172 InstructionsBuilder)
"""
mutable struct InstrBuilder
    instrs::Vector{InstrIR.WasmInstr}   # the ir/ layer — serialized on demand
    v::WasmStackValidator
    locals::Vector{WasmValType}         # param + local types, indexed by local index
    func_name::String
    context::String                     # current Julia stmt/op being emitted (diagnostics)
    trace::Union{Nothing, Vector{String}}  # opt-in full emit log (WT_BUILDER_TRACE)
    # fullstrict: LIVE locals provider (a codegen-supplied closure idx→WasmValType) —
    # the static b.locals snapshot goes stale when locals are allocated AFTER builder
    # creation (the tracker then guessed AnyRef and every downstream op mismatched).
    locals_fn::Union{Nothing, Function}
    seeded::Vector{WasmValType}         # inputs recorded by seed_input! (typed merges)
    # (instruction index → source) as emitted, in order (start_source_mapping!), when the
    # module records source maps; a fragment's mappings move into the builder it is appended
    # to, shifted (append_builder!). `nothing` otherwise (dart: null, instructions.dart:239).
    source_mappings::Union{Nothing,Vector{SourceMapping}}
end

# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:233 InstructionsBuilder)
function InstrBuilder(param_types::Vector{<:Any}=WasmValType[],
                      result_types::Vector{<:Any}=WasmValType[];
                      func_name::String="", mod=nothing)::InstrBuilder
    locals = WasmValType[p for p in param_types]
    # `mod` (the WasmModule) lets the validator's `wasm_subtype` resolve ConcreteRef
    # supertype chains. Threaded from codegen sites that have `ctx.mod` in scope (the
    # ref-flowing builders); `nothing` for numeric-only emitters that never push a
    # ConcreteRef, where the heap-kind branch is never reached.
    v = WasmStackValidator(; func_name=func_name, mod=mod)
    # Seed the outermost label as a :block whose results are the function results,
    # so end-of-function balance is checked against the declared results.
    push!(v.labels, ValidatorLabel(:expression, 0, WasmValType[],
                                   WasmValType[r for r in result_types], true))
    trace = OPTIONS[].builder_trace ? String[] : nothing
    records = mod isa WasmModule && mod.source_map_url !== nothing
    InstrBuilder(InstrIR.WasmInstr[], v, locals, func_name, "", trace, nothing, WasmValType[],
                 records ? SourceMapping[] : nothing)
end

# does `b` record source mappings? (its module has a source map URL)
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:254 InstructionsBuilder.recordSourceMaps)
records_source_maps(b::InstrBuilder)::Bool = b.source_mappings !== nothing

# serialize/ layer: turn the recorded instruction stream into bytes.
# parity(pkg/wasm_builder/lib/src/ir/instructions.dart:47 Instructions.serialize)
builder_code(b::InstrBuilder)::Vector{UInt8} = first(builder_code_mapped(b))

"""
    builder_code_mapped(b) -> (code, mappings)

Serialize `b`'s instructions, and its source mappings with them: each mapping's instruction
index becomes the byte offset of that instruction in `code`, and the end of the code is
unmapped.
parity(pkg/wasm_builder/lib/src/ir/instructions.dart:47 Instructions.serialize)
"""
function builder_code_mapped(b::InstrBuilder)::Tuple{Vector{UInt8},Vector{SourceMapping}}
    code = UInt8[]
    local mapped = SourceMapping[]
    local ms = something(b.source_mappings, SourceMapping[])
    local k = 1
    for i in eachindex(b.instrs)
        # the mapping that covers instruction i (0-based index i - 1)
        while k < length(ms) && ms[k + 1].offset <= i - 1
            k += 1
        end
        if k <= length(ms) && ms[k].offset <= i - 1
            push!(mapped, SourceMapping(length(code), ms[k].info))
            k += 1
        end
        if !isassigned(b.instrs, i)
            around = [isassigned(b.instrs, j) ? string(nameof(typeof(b.instrs[j]))) : "#undef"
                      for j in max(1, i-3):min(length(b.instrs), i+3)]
            nundef = count(j -> !isassigned(b.instrs, j), eachindex(b.instrs))
            lastundef = findlast(j -> !isassigned(b.instrs, j), eachindex(b.instrs))
            error("builder_code($(b.func_name)): UNDEF instr slot $i of $(length(b.instrs)); n_undef=$nundef last_undef=$lastundef; window=$(join(around, ","))")
        end
        encode!(code, b.instrs[i])
    end
    records_source_maps(b) && push!(mapped, SourceMapping(length(code), nothing))
    return code, mapped
end

"""
    start_source_mapping!(b, info) -> b

Map the instructions emitted from here on to `info`, until the next start or stop.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:603 InstructionsBuilder.startSourceMapping)
"""
start_source_mapping!(b::InstrBuilder, info::SourceInfo)::InstrBuilder =
    records_source_maps(b) ? _add_source_mapping!(b, SourceMapping(length(b.instrs), info)) : b

"""
    stop_source_mapping!(b) -> b

Leave the instructions emitted from here on unmapped.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:615 InstructionsBuilder.stopSourceMapping)
"""
stop_source_mapping!(b::InstrBuilder)::InstrBuilder =
    records_source_maps(b) ? _add_source_mapping!(b, SourceMapping(length(b.instrs), nothing)) : b

"""
    _add_source_mapping!(b, m) -> b

Record `m`: a mapping at the same instruction as the last replaces it (the last one covered
no instruction), and one naming the same source as the last adds nothing.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:619 InstructionsBuilder._addSourceMapping)
"""
function _add_source_mapping!(b::InstrBuilder, m::SourceMapping)::InstrBuilder
    local ms = b.source_mappings
    if !isempty(ms)
        local last = ms[end]
        if last.offset == m.offset
            ms[end] = m
            return b
        end
        last.info == m.info && return b
    end
    push!(ms, m)
    return b
end
# symbolic disassembly (dart2wasm printTo) — clarity for tracking codegen bugs.
# parity(pkg/wasm_builder/lib/src/ir/instructions.dart:97 Instructions.printTo)
builder_disasm(b::InstrBuilder)::Vector{String} = String[mnemonic(i) for i in b.instrs]
# parity(quarantine: the emitted length a StackImbalanceError and the stackifier's trace report;
# dart's _reportError (instructions.dart:452) reports its instruction trace.)
_byte_len(b::InstrBuilder)::Int = length(builder_code(b))

"""
Set the high-level context (Julia statement) the next emits belong to — surfaces in errors.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:650 InstructionsBuilder.comment)
"""
set_context!(b::InstrBuilder, ctx::AbstractString)::InstrBuilder = (b.context = String(ctx); b.v.context_hint = b.context; b)

# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:412 InstructionsBuilder._debugTrace)
_stack_snapshot(b::InstrBuilder)::Vector{String} = String[string(t) for t in b.v.stack]

# Record an instruction (ir/ layer) + trace, then enforce strictness. Validation has
# already run against the operand-stack model by the calling method.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:363 InstructionsBuilder._add)
@inline function _emit!(b::InstrBuilder, instr::InstrIR.WasmInstr)::InstrBuilder
    push!(b.instrs, instr)
    if b.trace !== nothing
        top = isempty(b.v.stack) ? "-" : string(b.v.stack[end])
        push!(b.trace, "[$(length(b.instrs))] $(mnemonic(instr))   h=$(length(b.v.stack)) top=$top | $(b.context)")
    end
    return _check!(b)
end

# Throw validator errors immediately with rich source context.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:452 InstructionsBuilder._reportError)
@inline function _check!(b::InstrBuilder)::InstrBuilder
    if has_errors(b.v)
        msg = join(b.v.errors, "\n  ")
        if b.trace !== nothing && !isempty(b.trace)
            msg *= "\n  trace tail:\n    " * join(b.trace[max(1, end-14):end], "\n    ")
        end
        empty!(b.v.errors)
        throw(StackImbalanceError(b.func_name, b.context, msg, _stack_snapshot(b), _byte_len(b)))
    end
    return b
end

"""
    builder_diagnose(b) -> String

Full human-readable post-mortem of a builder's state — the symbolic instruction tail,
the operand-stack snapshot, the open control-flow labels (with their base heights/result
types), reachability, the byte length, and any pending validator errors. Pins a
codegen bug to an exact statement + stack shape with no wasm-tools round-trip.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:412 InstructionsBuilder._debugTrace)
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
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:382 InstructionsBuilder.addLocal)
function builder_add_local!(b::InstrBuilder, typ::WasmValType)::Int
    push!(b.locals, typ)
    return length(b.locals) - 1
end
# parity(quarantine: the context-free Int128 builders (int128.jl) name their locals by index and
# type them afterwards; dart's addLocal takes a local's type when it creates it.)
function builder_set_local_type!(b::InstrBuilder, idx::Integer, typ::WasmValType)::WasmValType
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
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:2054 InstructionsBuilder.i32_const)
i32_const!(b::InstrBuilder, v::Integer)::InstrBuilder = (validate_push!(b.v, I32); _emit!(b, InstrIR.I32Const(Int64(v))))
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:2067 InstructionsBuilder.i64_const)
i64_const!(b::InstrBuilder, v::Integer)::InstrBuilder = (validate_push!(b.v, I64); _emit!(b, InstrIR.I64Const(Int64(v))))
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:2079 InstructionsBuilder.f32_const)
f32_const!(b::InstrBuilder, x::Real)::InstrBuilder = (validate_push!(b.v, F32); _emit!(b, InstrIR.F32Const(Float32(x))))
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:2091 InstructionsBuilder.f64_const)
f64_const!(b::InstrBuilder, x::Real)::InstrBuilder = (validate_push!(b.v, F64); _emit!(b, InstrIR.F64Const(Float64(x))))
# Generic numeric/comparison/conversion op (no immediates): reuse validate_instruction!.
# parity(quarantine: one emitter for the no-immediate numeric, comparison and conversion
# instructions, which dart emits through one method each (i32_add … f64_promote_f32, each
# `_verifyTypes` of its operands and `_add` of its SingleByteInstruction); validate_instruction!
# holds their operand types by opcode.)
num!(b::InstrBuilder, op::UInt8)::InstrBuilder = (validate_instruction!(b.v, op); _emit!(b, InstrIR.NumOp(op)))

# Saturating truncation (FC-prefixed, sub-op 0x00–0x07): pop a float, push an int. The
# sub-op encodes both: to = i32 (<0x04) or i64; from = f32 (0x00,0x01,0x04,0x05) or f64.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:3808 InstructionsBuilder.i32_trunc_sat_f32_s)
function trunc_sat!(b::InstrBuilder, sub_op::UInt8)::InstrBuilder
    to   = sub_op < 0x04 ? I32 : I64
    from = (sub_op == 0x00 || sub_op == 0x01 || sub_op == 0x04 || sub_op == 0x05) ? F32 : F64
    validate_pop!(b.v, from)
    validate_push!(b.v, to)
    _emit!(b, InstrIR.TruncSat(sub_op))
end

# ── Parametric ──────────────────────────────────────────────────────────────────
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:998 InstructionsBuilder.drop)
drop!(b::InstrBuilder)::InstrBuilder = (validate_pop_any!(b.v); _emit!(b, InstrIR.Drop()))
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1004 InstructionsBuilder.select)
# select t: [t, t, i32] → [t]; a numeric t encodes the untyped select, any other the typed one
# (dart: `type is ir.NumType ? ir.Select() : ir.SelectWithType(type)`)
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1004 InstructionsBuilder.select)
function select!(b::InstrBuilder, t::WasmValType)::InstrBuilder
    validate_instruction!(b.v, Opcode.SELECT, t)
    _emit!(b, t isa NumType ? InstrIR.Select() : InstrIR.SelectWithType(t))
end

# ── Variable ────────────────────────────────────────────────────────────────────
# fullstrict: the LIVE type for a local — the provider (fresh truth) outranks the
# static snapshot; AnyRef only when neither knows.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1018 InstructionsBuilder.local_get)
@inline _local_type(b::InstrBuilder, idx::Integer)::WasmValType = begin
    if b.locals_fn !== nothing
        local t = b.locals_fn(Int(idx))
        t isa WasmValType && return t
    end
    (idx + 1) <= length(b.locals) ? b.locals[idx + 1] : AnyRef
end

# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1018 InstructionsBuilder.local_get)
function local_get!(b::InstrBuilder, idx::Integer)::InstrBuilder
    validate_push!(b.v, _local_type(b, idx))
    _emit!(b, InstrIR.LocalGet(UInt32(idx)))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1035 InstructionsBuilder.local_set)
function local_set!(b::InstrBuilder, idx::Integer)::InstrBuilder
    # dart parity: local.set validates the value against the LOCAL's type when known
    # (a store is [local.type] → []; pop_any hid ill-typed stores until instantiation).
    if b.locals_fn !== nothing || (idx + 1) <= length(b.locals)
        validate_pop!(b.v, _local_type(b, idx))
    else
        validate_pop_any!(b.v)
    end
    _emit!(b, InstrIR.LocalSet(UInt32(idx)))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1049 InstructionsBuilder.local_tee)
function local_tee!(b::InstrBuilder, idx::Integer)::InstrBuilder
    # dart2wasm: local_tee(l) is [l.type] → [l.type]
    lt = _local_type(b, idx)   # fullstrict: the live provider
    validate_pop!(b.v, lt); validate_push!(b.v, lt)
    _emit!(b, InstrIR.LocalTee(UInt32(idx)))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1063 InstructionsBuilder.global_get)
function global_get!(b::InstrBuilder, idx::Integer, typ::WasmValType)::InstrBuilder
    # the module's global, whose type is its definition's (dart global_get: [] → [global.type]);
    # a builder with no module (a unit test) has only the caller's type
    local m = b.v.mod
    local t = m === nothing ? typ : _defined_global(m, idx, :global_get).valtype
    validate_push!(b.v, t)
    _emit!(b, InstrIR.GlobalGet(UInt32(idx)))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1072 InstructionsBuilder.global_set)
function global_set!(b::InstrBuilder, idx::Integer)::InstrBuilder
    # dart global_set: the global is mutable and its type is popped
    local m = b.v.mod
    if m === nothing
        validate_pop_any!(b.v)   # a builder with no module (a unit test) has no global to check
    else
        local g = _defined_global(m, idx, :global_set)
        g.mutable_ || _module_invalid(:global_set, "global $idx is immutable")
        validate_pop!(b.v, g.valtype)
    end
    _emit!(b, InstrIR.GlobalSet(UInt32(idx)))
end

# the defined global `idx` (WT imports functions only, so a global's index is its definition's)
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1063 InstructionsBuilder.global_get)
function _defined_global(m::WasmModule, idx::Integer, op::Symbol)::WasmGlobalDef
    0 <= idx < length(m.globals) || _module_invalid(op, "global $idx is not defined")
    return m.globals[idx + 1]
end

# ── Control flow ────────────────────────────────────────────────────────────────
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:676 InstructionsBuilder.unreachable)
unreachable!(b::InstrBuilder)::InstrBuilder = (b.v.reachable = false; _emit!(b, InstrIR.Unreachable()))
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:690 InstructionsBuilder.nop)
nop!(b::InstrBuilder)::InstrBuilder = _emit!(b, InstrIR.Nop())

"""
    _block_type!(b, inputs, results) -> blocktype

A frame's encoded block type, derived from its signature as dart's `_beginBlock` derives it:
void with no inputs and no results, the one result's value type with no inputs and one result,
else a function type of the inputs and results, defined in the module. A caller names only the
frame's inputs and results, so the encoding and the tracked frame are one fact.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:707 InstructionsBuilder._beginBlock)
"""
function _block_type!(b::InstrBuilder, inputs::Vector{WasmValType},
                      results::Vector{WasmValType})::Union{UInt8,WasmValType,Int}
    # a frame's inputs and results are value types: a raw byte (the void marker 0x40, a packed
    # i8/i16 storage type) is not one, and would encode a frame the tracker does not hold
    any(t -> t isa UInt8, inputs) || any(t -> t isa UInt8, results) ||
        return _block_type_derived!(b, inputs, results)
    throw(ArgumentError("a block's inputs $(inputs) and results $(results) must be value types, not raw bytes"))
end

# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:707 InstructionsBuilder._beginBlock)
function _block_type_derived!(b::InstrBuilder, inputs::Vector{WasmValType},
                              results::Vector{WasmValType})::Union{UInt8,WasmValType,Int}
    isempty(inputs) && isempty(results) && return 0x40
    isempty(inputs) && length(results) == 1 && return results[1]
    return Int(add_type!(b.v.mod, FuncType(inputs, results)))
end

# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:729 InstructionsBuilder.block)
function block!(b::InstrBuilder; inputs::Vector{<:Any}=WasmValType[],
                results::Vector{<:Any}=WasmValType[])::ControlLabel
    local ins, outs = WasmValType[t for t in inputs], WasmValType[t for t in results]
    local blocktype = _block_type!(b, ins, outs)
    label = validate_block_start!(b.v, :block, ins, outs)
    _emit!(b, InstrIR.Block(blocktype)); return label
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:741 InstructionsBuilder.loop)
function loop!(b::InstrBuilder; inputs::Vector{<:Any}=WasmValType[],
               results::Vector{<:Any}=WasmValType[])::ControlLabel
    local ins, outs = WasmValType[t for t in inputs], WasmValType[t for t in results]
    local blocktype = _block_type!(b, ins, outs)
    label = validate_block_start!(b.v, :loop, ins, outs)
    _emit!(b, InstrIR.Loop(blocktype)); return label
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:753 InstructionsBuilder.if_)
function if_!(b::InstrBuilder; inputs::Vector{<:Any}=WasmValType[],
              results::Vector{<:Any}=WasmValType[])::ControlLabel
    local ins, outs = WasmValType[t for t in inputs], WasmValType[t for t in results]
    local blocktype = _block_type!(b, ins, outs)
    label = validate_if_start!(b.v, ins, outs)
    _emit!(b, InstrIR.If(blocktype)); return label
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:767 InstructionsBuilder.else_)
else_!(b::InstrBuilder)::InstrBuilder = (validate_else!(b.v); _emit!(b, InstrIR.Else()))
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:842 InstructionsBuilder.end)
end_block!(b::InstrBuilder)::InstrBuilder = (validate_block_end!(b.v); _emit!(b, InstrIR.End()))

"""
Close the function label, rejecting any unclosed structured-control frames.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:276 InstructionsBuilder.forceBuild)
"""
function finish_function!(b::InstrBuilder)::InstrBuilder
    if length(b.v.labels) != 1
        local frames = join((string(lbl.kind) for lbl in b.v.labels), " → ")
        throw(StackImbalanceError(b.func_name, b.context,
              "function finalization found $(length(b.v.labels) - 1) unclosed control frame(s): $frames",
              _stack_snapshot(b), _byte_len(b)))
    end
    end_block!(b)
    isempty(b.v.labels) || error("builder function label did not close")
    # Independently audit the recorded IR structure. Fragment merges transfer
    # already-validated instructions; this catches any validator/IR divergence
    # before serialization (the final End closes the implicit function frame).
    local depth = 0
    for (i, ins) in enumerate(b.instrs)
        if ins isa InstrIR.Block || ins isa InstrIR.Loop || ins isa InstrIR.If ||
           ins isa InstrIR.TryTable
            depth += 1
        elseif ins isa InstrIR.End
            depth -= 1
            if depth < 0 && i != length(b.instrs)
                throw(StackImbalanceError(b.func_name, b.context,
                      "structured IR closes the function before instruction $i",
                      _stack_snapshot(b), _byte_len(b)))
            end
        end
    end
    depth == -1 || throw(StackImbalanceError(b.func_name, b.context,
          "structured IR has $(depth + 1) unclosed control frame(s) at function end",
          _stack_snapshot(b), _byte_len(b)))
    return b
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:863 InstructionsBuilder.br)
_br_depth!(b::InstrBuilder, depth::Int)::InstrBuilder =
    (validate_br!(b.v, depth); _emit!(b, InstrIR.Br(UInt32(depth))))
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:878 InstructionsBuilder.br_if)
_br_if_depth!(b::InstrBuilder, depth::Int)::InstrBuilder =
    (validate_br_if!(b.v, depth); _emit!(b, InstrIR.BrIf(UInt32(depth))))
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:856 InstructionsBuilder._labelIndex)
function _label_depth(b::InstrBuilder, target::ControlLabel)::Int
    i = findlast(l -> l.handle === target, b.v.labels)
    if i === nothing
        open_kinds = Symbol[l.handle.kind for l in b.v.labels]
        throw(ArgumentError("branch target is not an open label: $(target.kind) " *
                            "in $(b.func_name); open labels: $open_kinds"))
    end
    return length(b.v.labels) - i
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:863 InstructionsBuilder.br)
br!(b::InstrBuilder, target::ControlLabel)::InstrBuilder = _br_depth!(b, _label_depth(b, target))
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:878 InstructionsBuilder.br_if)
br_if!(b::InstrBuilder, target::ControlLabel)::InstrBuilder = _br_if_depth!(b, _label_depth(b, target))
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:933 InstructionsBuilder.return_)
function return_!(b::InstrBuilder)::InstrBuilder
    # the function's results, popped from above the innermost block's base, then nothing
    # after is reachable (dart return_: _verifyTypes(_labelStack[0].outputs, [], reachableAfter: false))
    if b.v.reachable
        for t in reverse(b.v.labels[1].result_types); validate_pop!(b.v, t); end
    end
    b.v.reachable = false
    _emit!(b, InstrIR.Return())
end

# fullstrict: the module KNOWS every function's signature — derive it there; the
# caller's claim is only a fallback for a genuinely unresolved index.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:947 InstructionsBuilder.call)
@inline function _true_call_sig(b::InstrBuilder, func_idx::Integer, params, results)::Tuple{Any, Any}
    local m = b.v.mod
    m === nothing && return (params, results)
    local function_imports = WasmImport[]
    for imp in m.imports
        imp.kind == 0x00 && push!(function_imports, imp)
    end
    local n_imp = length(function_imports)
    if 0 <= func_idx < n_imp
        local imp = function_imports[Int(func_idx) + 1]
        local ft = m.types[Int(imp.type_idx) + 1]
        ft isa FuncType || return (params, results)
        return (ft.params, ft.results)
    end
    local fi = Int(func_idx) - n_imp
    (fi >= 0 && fi < length(m.functions)) || return (params, results)
    local ft = m.types[Int(m.functions[fi + 1].type_idx) + 1]
    ft isa FuncType || return (params, results)
    return (ft.params, ft.results)
end

# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:947 InstructionsBuilder.call)
function call!(b::InstrBuilder, func_idx::Integer, params::Vector{<:Any}, results::Vector{<:Any})::InstrBuilder
    local tp, tr = _true_call_sig(b, func_idx, params, results)
    if b.v.reachable
        for p in reverse(tp); validate_pop!(b.v, p); end
        for r in tr; validate_push!(b.v, r); end
    end
    _emit!(b, InstrIR.Call(UInt32(func_idx)))
end

# call_indirect: pop table-index (i32) then params, push results. Caller supplies the
# signature it already knows (same as call!).
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:960 InstructionsBuilder.call_indirect)
function call_indirect!(b::InstrBuilder, type_idx::Integer, table_idx::Integer, params::Vector{<:Any}, results::Vector{<:Any})::InstrBuilder
    params, results = _function_type_sig(b, type_idx, params, results, :call_indirect)
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
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:973 InstructionsBuilder.call_ref)
function call_ref!(b::InstrBuilder, type_idx::Integer, params::Vector{<:Any}, results::Vector{<:Any})::InstrBuilder
    params, results = _function_type_sig(b, type_idx, params, results, :call_ref)
    if b.v.reachable
        validate_pop!(b.v, ConcreteRef(UInt32(type_idx), true))  # the callee, a (ref null $type)
        for p in reverse(params); validate_pop!(b.v, p); end
        for r in results; validate_push!(b.v, r); end
    end
    _emit!(b, InstrIR.CallRef(UInt32(type_idx)))
end

# The signature function type `type_idx` names in the module; a caller's differing claim is a
# codegen bug, raised at the emitting line (dart call_ref and call_indirect take the type itself)
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:973 InstructionsBuilder.call_ref)
function _function_type_sig(b::InstrBuilder, type_idx::Integer, params::Vector{<:Any},
                            results::Vector{<:Any}, op::Symbol)::Tuple{Vector{WasmValType},Vector{WasmValType}}
    local m = b.v.mod
    m === nothing && return (WasmValType[p for p in params], WasmValType[r for r in results])
    0 <= type_idx < length(m.types) || _module_invalid(op, "type $type_idx is not defined")
    local ft = m.types[type_idx + 1]
    ft isa FuncType || _module_invalid(op, "type $type_idx is not a function type")
    (length(params) == length(ft.params) && all(p -> p[1] == p[2], zip(params, ft.params)) &&
     length(results) == length(ft.results) && all(r -> r[1] == r[2], zip(results, ft.results))) ||
        _module_invalid(op, "the caller's signature $(params) -> $(results) is not type $type_idx's $(ft.params) -> $(ft.results)")
    return (ft.params, ft.results)
end

# The reference operand of br_on_null / br_on_non_null, and the type it has once not null: a
# concrete ref loses its null; an abstract one keeps WT's nullable spelling (a supertype of
# dart's `withNullability(false)`, so the model can only reject, never accept, wrongly).
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1622 RefType.common)
function _branch_ref_operand(b::InstrBuilder, op::String)::WasmValType
    if isempty(b.v.stack)
        push!(b.v.errors, "$(b.func_name): $op needs a reference operand, the stack is empty")
        return AnyRef
    end
    t = b.v.stack[end]
    if !(t isa RefType || t isa ConcreteRef || t isa NonNullAbstractRef)
        push!(b.v.errors, "$(b.func_name): $op needs a reference operand, found $t")
        return AnyRef
    end
    return _non_null(t)
end

# A reference type made non-null (dart RefType.withNullability(false)): a concrete one loses
# its null, a nullable abstract one becomes its non-null form.
# parity(pkg/wasm_builder/lib/src/ir/type.dart:229 RefType.withNullability)
_non_null(t::WasmValType)::WasmValType =
    t isa ConcreteRef ? ConcreteRef(t.type_idx, false) : t isa RefType ? NonNullAbstractRef(UInt8(t)) : t

# br_on_null: [(ref null ht)] -> [(ref ht)] on fallthrough; branches to `depth` carrying what
# lies under the operand. On fallthrough the top becomes non-null; reachability stays true.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1619 InstructionsBuilder.br_on_null)
function _br_on_null_depth!(b::InstrBuilder, depth::Int)::InstrBuilder
    if b.v.reachable
        nn = _branch_ref_operand(b, "br_on_null")
        validate_branch_types!(b.v, depth, 1)
        validate_pop_any!(b.v)
        validate_push!(b.v, nn)
    end
    _emit!(b, InstrIR.BrOnNull(UInt32(depth)))
end

# br_on_non_null: [(ref null ht)] -> [] on fallthrough; branches to `depth` carrying the
# non-null ref. On fallthrough the ref is consumed; reachability stays true.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1644 InstructionsBuilder.br_on_non_null)
function _br_on_non_null_depth!(b::InstrBuilder, depth::Int)::InstrBuilder
    if b.v.reachable
        nn = _branch_ref_operand(b, "br_on_non_null")
        validate_branch_types!(b.v, depth, 1, WasmValType[nn])
        validate_pop_any!(b.v)
    end
    _emit!(b, InstrIR.BrOnNonNull(UInt32(depth)))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1619 InstructionsBuilder.br_on_null)
br_on_null!(b::InstrBuilder, target::ControlLabel)::InstrBuilder =
    _br_on_null_depth!(b, _label_depth(b, target))
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1644 InstructionsBuilder.br_on_non_null)
br_on_non_null!(b::InstrBuilder, target::ControlLabel)::InstrBuilder =
    _br_on_non_null_depth!(b, _label_depth(b, target))

# ── Exception handling (Wasm 3.0) ─────────────────────────────────────────────────
# Catch-clause constructors a caller hands to `try_table!`. Label is the branch target
# depth at the point of the try_table (dart2wasm passes a Label; here the caller resolves
# it to a depth, exactly as it already does for br!/br_if!).
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:105 TryTableCatch)
struct SymbolicTryCatch
    opcode::UInt8
    tag_idx::UInt32
    target::ControlLabel
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:116 Catch)
catch_clause(tag::Integer, label::ControlLabel)::SymbolicTryCatch =
    SymbolicTryCatch(Opcode.CATCH, UInt32(tag), label)
# catch_all_ref: every exception, Julia's or foreign, delivered as its exnref (no tag)
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:153 CatchAllRef)
catch_all_ref_clause(label::ControlLabel)::SymbolicTryCatch =
    SymbolicTryCatch(Opcode.CATCH_ALL_REF, 0xffffffff, label)

# try_table: a block opener carrying catch clauses (dart2wasm `try_table`), its block type
# derived from its inputs and results (_block_type!). Each catch branches out to its target
# label with the values it catches, checked as every branch is (validate_branch_types!).
# A try_table with inputs or results is refused: CI's wasm engine, V8 12.4 (Node 22), traps
# entering a try_table whose result is a concrete reference, and its inputs are unmeasured, so a
# body's values leave through locals (L155). dart2wasm emits no try_table, only legacy try
# (code_generator.dart:945); WT's try_table lowering is dev/MARCH.md 13.17 A13E7.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:907 InstructionsBuilder.try_table)
function try_table!(b::InstrBuilder, catches::Vector; inputs::Vector{<:Any}=WasmValType[],
                    results::Vector{<:Any}=WasmValType[])::ControlLabel
    (isempty(inputs) && isempty(results)) || throw(ArgumentError(
        "a try_table takes no inputs or results (V8 12.4 traps entering one with a concrete-reference result): its body's values leave through locals"))
    local ins, outs = WasmValType[t for t in inputs], WasmValType[t for t in results]
    for c in catches
        c isa SymbolicTryCatch || throw(ArgumentError(
            "try_table catches must retain symbolic ControlLabel targets"))
        i = findlast(l -> l.handle === c.target, b.v.labels)
        i === nothing && throw(ArgumentError("catch target is not an open label"))
        caught = WasmValType[]
        if c.opcode === Opcode.CATCH || c.opcode === Opcode.CATCH_REF
            Int(c.tag_idx) < length(b.v.mod.tags) ||
                throw(ArgumentError("catch references unknown tag $(c.tag_idx)"))
            tag = b.v.mod.tags[Int(c.tag_idx) + 1]
            ft = b.v.mod.types[Int(tag.type_idx) + 1]
            ft isa FuncType || throw(ArgumentError("catch tag type is not a function type"))
            append!(caught, ft.params)
        end
        (c.opcode === Opcode.CATCH_REF || c.opcode === Opcode.CATCH_ALL_REF) &&
            push!(caught, ExnRef)
        # the spec types the target as exactly the caught values; dart's _verifyBranchTypes
        # checks only their suffix, so a target of another arity is rejected here
        local targets = b.v.labels[i].kind === :loop ? b.v.labels[i].input_types : b.v.labels[i].result_types
        length(targets) == length(caught) ||
            push!(b.v.errors, "a catch delivers $(caught) to a target that takes $(targets)")
        # the catch carries exactly what it caught to its target (dart: _verifyBranchTypes(
        # catch_.label, 0, catch_.caughtValues()))
        validate_branch_types!(b.v, length(b.v.labels) - i, 0, caught)
        _check!(b)
    end
    encoded_catches = InstrIR.TryCatch[c isa SymbolicTryCatch ?
        InstrIR.TryCatch(c.opcode, c.tag_idx, UInt32(_label_depth(b, c.target))) : c
        for c in catches]
    local blocktype = _block_type!(b, ins, outs)
    label = validate_block_start!(b.v, :try_table, ins, outs)
    _emit!(b, InstrIR.TryTable(blocktype, encoded_catches)); return label
end
# throw tag: pop the tag's inputs (caller declares them), then unreachable (dart2wasm throw_).
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:820 InstructionsBuilder.throw_)
function throw_!(b::InstrBuilder, tag::Integer)::InstrBuilder
    # the tag's own inputs (dart throw_: _verifyTypes(tag.type.inputs, []))
    local m = b.v.mod
    m === nothing && throw(ArgumentError("throw needs the module that defines tag $tag"))
    0 <= tag < length(m.tags) || _module_invalid(:throw, "tag $tag is not defined")
    local ft = m.types[Int(m.tags[tag + 1].type_idx) + 1]
    ft isa FuncType || _module_invalid(:throw, "tag $tag's type is not a function type")
    if b.v.reachable
        for t in reverse(ft.params); validate_pop!(b.v, t); end
    end
    b.v.reachable = false
    _emit!(b, InstrIR.Throw(UInt32(tag)))
end
# throw_ref: pop an exnref and throw the exception it holds, payload and all; what follows
# is unreachable. dart's throw_ref checks no operand; the spec's is exnref.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:836 InstructionsBuilder.throw_ref)
function throw_ref!(b::InstrBuilder)::InstrBuilder
    validate_pop!(b.v, ExnRef)
    b.v.reachable = false
    _emit!(b, InstrIR.ThrowRef())
end

# ── Reference ───────────────────────────────────────────────────────────────────
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1570 InstructionsBuilder.ref_null)
ref_null!(b::InstrBuilder, heaptype::Integer, reftype::WasmValType)::InstrBuilder =
    (validate_push!(b.v, reftype); _emit!(b, InstrIR.RefNullConcrete(Int64(heaptype))))
# Abstract-heaptype ref.null (any/struct/array/i31/...): the RefType enum value IS the
# single on-wire heaptype byte (dart2wasm encodes HeapType directly).
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1570 InstructionsBuilder.ref_null)
ref_null!(b::InstrBuilder, rt::RefType)::InstrBuilder =
    (validate_push!(b.v, rt); _emit!(b, InstrIR.RefNullAbstract(UInt8(rt))))
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1582 InstructionsBuilder.ref_is_null)
ref_is_null!(b::InstrBuilder)::InstrBuilder = (validate_instruction!(b.v, Opcode.REF_IS_NULL); _emit!(b, InstrIR.RefIsNull()))
# dart2wasm: ref_as_non_null output = actual top-of-stack with nullability=false.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1607 InstructionsBuilder.ref_as_non_null)
function ref_as_non_null!(b::InstrBuilder)::InstrBuilder
    t = validate_pop_ref!(b.v)
    validate_push!(b.v, t === nothing ? AnyRef : _non_null(t))
    _emit!(b, InstrIR.RefAsNonNull())
end

# ── WasmGC (type-directed; caller passes the resolved field/element types it has) ──
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1711 InstructionsBuilder.struct_new)
function struct_new!(b::InstrBuilder, type_idx::Integer, field_types::Vector{<:Any})::InstrBuilder
    validate_gc_instruction!(b.v, Opcode.STRUCT_NEW, (type_idx, WasmValType[f for f in field_types]))
    _emit!(b, InstrIR.StructNew(UInt32(type_idx)))
end
# Mod-resolving form (dart wasm_builder — the instruction knows its type).
# Pops the REAL declared field list from the module; the empty-list fudge (which
# left every operand phantom-tracked — the value-channel liar class) has no home here.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1711 InstructionsBuilder.struct_new)
function struct_new!(b::InstrBuilder, type_idx::Integer)::InstrBuilder
    local _mod = b.v.mod
    local _ft = if _mod !== nothing && type_idx + 1 >= 1 && type_idx + 1 <= length(_mod.types) &&
                   _mod.types[type_idx + 1] isa StructType
        WasmValType[f.valtype for f in _mod.types[type_idx + 1].fields]
    else
        error("struct_new!(b, $type_idx): module type definition unavailable — pass the field list explicitly")
    end
    struct_new!(b, type_idx, _ft)
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1723 InstructionsBuilder.struct_new_default)
function struct_new_default!(b::InstrBuilder, type_idx::Integer)::InstrBuilder
    validate_gc_instruction!(b.v, Opcode.STRUCT_NEW_DEFAULT, type_idx)
    _emit!(b, InstrIR.StructNewDefault(UInt32(type_idx)))
end
# fullstrict (valid-by-construction): the MODULE knows every struct's field types —
# DERIVE the truth there instead of trusting the caller's declaration (dozens of sites
# declared AnyRef over typed fields, silently poisoning the tracker downstream). The
# declared param stays as the fallback when the module/type is unavailable.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1657 InstructionsBuilder.struct_get)
@inline function _true_field_type(b::InstrBuilder, type_idx::Integer, field_idx::Integer, declared::WasmValType)::WasmValType
    m = b.v.mod
    m === nothing && return declared   # a builder with no module (a unit test)
    0 <= type_idx < length(m.types) || _module_invalid(:struct_field, "type $type_idx is not defined")
    local ct = m.types[type_idx + 1]
    ct isa StructType || _module_invalid(:struct_field, "type $type_idx is not a struct type")
    0 <= field_idx < length(ct.fields) || _module_invalid(:struct_field, "struct type $type_idx has no field $field_idx")
    local ft = ct.fields[field_idx + 1].valtype
    # packed i8/i16 storage reads as i32
    ft isa UInt8 && ft in (0x78, 0x77) && return I32
    return ft isa WasmValType ? ft : declared
end

# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1657 InstructionsBuilder.struct_get)
function struct_get!(b::InstrBuilder, type_idx::Integer, field_idx::Integer, field_type::WasmValType)::InstrBuilder
    # WT declares no packed struct field, so struct.get_s/_u (dart's struct_get_s/_u, asserted
    # packed, instructions.dart:1675) have no caller (dev/AUDIT.md A10B9); dart's struct_get
    # asserts a value-type field, and a packed one rejects here (A11B9)
    local m = b.v.mod
    if m !== nothing && 0 <= type_idx < length(m.types) && m.types[type_idx + 1] isa StructType
        local fs = m.types[type_idx + 1].fields
        if 0 <= field_idx < length(fs)
            local ft = fs[field_idx + 1].valtype
            ft isa UInt8 && ft in (0x78, 0x77) &&
                _module_invalid(:struct_get, "field $field_idx of struct type $type_idx is packed: struct.get_s or struct.get_u reads it")
        end
    end
    validate_gc_instruction!(b.v, Opcode.STRUCT_GET, (type_idx, _true_field_type(b, type_idx, field_idx, field_type)))
    _emit!(b, InstrIR.StructGet(UInt32(type_idx), UInt32(field_idx), Opcode.STRUCT_GET))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1696 InstructionsBuilder.struct_set)
function struct_set!(b::InstrBuilder, type_idx::Integer, field_idx::Integer, field_type::WasmValType)::InstrBuilder
    validate_gc_instruction!(b.v, Opcode.STRUCT_SET, (type_idx, _true_field_type(b, type_idx, field_idx, field_type)))
    _emit!(b, InstrIR.StructSet(UInt32(type_idx), UInt32(field_idx)))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1827 InstructionsBuilder.array_new_default)
function array_new_default!(b::InstrBuilder, type_idx::Integer)::InstrBuilder
    validate_gc_instruction!(b.v, Opcode.ARRAY_NEW_DEFAULT, type_idx)
    _emit!(b, InstrIR.ArrayNewDefault(UInt32(type_idx)))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1802 InstructionsBuilder.array_new_fixed)
function array_new_fixed!(b::InstrBuilder, type_idx::Integer, n::Integer, elem_type::WasmValType)::InstrBuilder
    validate_gc_instruction!(b.v, Opcode.ARRAY_NEW_FIXED, (type_idx, _true_elem_type(b, type_idx, elem_type), n))
    _emit!(b, InstrIR.ArrayNewFixed(UInt32(type_idx), UInt32(n)))
end
# array.new_data $type $seg : [offset:i32, length:i32] -> [(ref $type)]
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1839 InstructionsBuilder.array_new_data)
function array_new_data!(b::InstrBuilder, type_idx::Integer, seg_idx::Integer)::InstrBuilder
    if b.v.reachable
        validate_pop!(b.v, I32); validate_pop!(b.v, I32)
        validate_push!(b.v, ConcreteRef(UInt32(type_idx), false))
    end
    _emit!(b, InstrIR.ArrayNewData(UInt32(type_idx), UInt32(seg_idx)))
end
# fullstrict: the module's array elem truth (packed i8/i16 read as i32)
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1735 InstructionsBuilder.array_get)
@inline function _true_elem_type(b::InstrBuilder, type_idx::Integer, declared::WasmValType)::WasmValType
    m = b.v.mod
    m === nothing && return declared   # a builder with no module (a unit test)
    0 <= type_idx < length(m.types) || _module_invalid(:array_elem, "type $type_idx is not defined")
    local ct = m.types[type_idx + 1]
    ct isa ArrayType || _module_invalid(:array_elem, "type $type_idx is not an array type")
    local ft = ct.elem.valtype
    ft isa UInt8 && ft in (0x78, 0x77) && return I32
    return ft isa WasmValType ? ft : declared
end

# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1735 InstructionsBuilder.array_get)
function array_get!(b::InstrBuilder, type_idx::Integer, elem_type::WasmValType; signed::Union{Nothing,Bool}=nothing)::InstrBuilder
    # a packed i8/i16 element is read signed or unsigned (array.get_s/_u), any other plainly
    # (dart's array_get asserts a value type, array_get_s/_u a packed one; dev/AUDIT.md A9B3)
    local m = b.v.mod
    if m !== nothing && 0 <= type_idx < length(m.types) && m.types[type_idx + 1] isa ArrayType
        local ft = m.types[type_idx + 1].elem.valtype
        local packed = ft isa UInt8 && ft in (0x78, 0x77)
        packed && signed === nothing &&
            _module_invalid(:array_get, "array type $type_idx has packed elements: array.get_s or array.get_u reads them")
        !packed && signed !== nothing &&
            _module_invalid(:array_get, "array type $type_idx has unpacked elements: array.get reads them")
    end
    op = signed === nothing ? Opcode.ARRAY_GET : (signed ? Opcode.ARRAY_GET_S : Opcode.ARRAY_GET_U)
    validate_gc_instruction!(b.v, op, (type_idx, _true_elem_type(b, type_idx, elem_type)))
    _emit!(b, InstrIR.ArrayGet(UInt32(type_idx), op))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1774 InstructionsBuilder.array_set)
function array_set!(b::InstrBuilder, type_idx::Integer, elem_type::WasmValType)::InstrBuilder
    validate_gc_instruction!(b.v, Opcode.ARRAY_SET, (type_idx, _true_elem_type(b, type_idx, elem_type)))
    _emit!(b, InstrIR.ArraySet(UInt32(type_idx)))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1790 InstructionsBuilder.array_len)
array_len!(b::InstrBuilder)::InstrBuilder = (validate_gc_instruction!(b.v, Opcode.ARRAY_LEN); _emit!(b, InstrIR.ArrayLen()))
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1961 InstructionsBuilder.ref_cast)
function ref_cast!(b::InstrBuilder, type_idx::Integer, nullable::Bool)::InstrBuilder
    op = nullable ? Opcode.REF_CAST_NULL : Opcode.REF_CAST
    validate_gc_instruction!(b.v, op, ConcreteRef(UInt32(type_idx), nullable))
    _emit!(b, InstrIR.RefCastConcrete(Int64(type_idx), nullable))
end
# Cast to an abstract heaptype (i31/array/struct/...): single on-wire heaptype byte.
# The tracked result is the non-null variant for `ref.cast` (the RefType enum is the
# nullable shorthand; `ref.cast null` keeps it).
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1961 InstructionsBuilder.ref_cast)
function ref_cast!(b::InstrBuilder, rt::RefType, nullable::Bool)::InstrBuilder
    if b.v.reachable; validate_pop_any!(b.v); validate_push!(b.v, nullable ? rt : NonNullAbstractRef(UInt8(rt))); end
    _emit!(b, InstrIR.RefCastAbstract(UInt8(rt), nullable))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1944 InstructionsBuilder.ref_test)
function ref_test!(b::InstrBuilder, type_idx::Integer, nullable::Bool)::InstrBuilder
    op = nullable ? Opcode.REF_TEST_NULL : Opcode.REF_TEST
    validate_gc_instruction!(b.v, op)
    _emit!(b, InstrIR.RefTest(Int64(type_idx), nullable))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:2028 InstructionsBuilder.any_convert_extern)
any_convert_extern!(b::InstrBuilder)::InstrBuilder = (validate_gc_instruction!(b.v, Opcode.ANY_CONVERT_EXTERN); _emit!(b, InstrIR.AnyConvertExtern()))
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:2040 InstructionsBuilder.extern_convert_any)
extern_convert_any!(b::InstrBuilder)::InstrBuilder = (validate_gc_instruction!(b.v, Opcode.EXTERN_CONVERT_ANY); _emit!(b, InstrIR.ExternConvertAny()))
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1852 InstructionsBuilder.array_copy)
function array_copy!(b::InstrBuilder, dst_type_idx::Integer, src_type_idx::Integer)::InstrBuilder
    validate_gc_instruction!(b.v, Opcode.ARRAY_COPY, (dst_type_idx, src_type_idx))
    _emit!(b, InstrIR.ArrayCopy(UInt32(dst_type_idx), UInt32(src_type_idx)))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1875 InstructionsBuilder.array_fill)
function array_fill!(b::InstrBuilder, type_idx::Integer, elem_type::WasmValType)::InstrBuilder
    validate_gc_instruction!(b.v, Opcode.ARRAY_FILL, (type_idx, _true_elem_type(b, type_idx, elem_type)))
    _emit!(b, InstrIR.ArrayFill(UInt32(type_idx)))
end


# Seed the model with stack values produced UPSTREAM (no instruction emitted). For
# fragment emitters that consume a value the (not-yet-migrated) caller already left on
# the stack, so the model starts from the true incoming stack rather than empty.
# Seeds are RECORDED so append_builder! can replay the fragment's true stack effect.
# parity(quarantine: WT emits a function through fragment builders merged by append_builder!, a
# fragment starting from the stack its caller left; dart emits a function into one builder.)
function seed_input!(b::InstrBuilder, types::Vector{<:Any})::InstrBuilder
    for t in types
        validate_push!(b.v, t)
        push!(b.seeded, t)
    end
    b
end

"""
    append_builder!(dst, src)

Typed builder merge: `dst` pops exactly what
`src` was seeded with (`src.seeded`, in reverse) and pushes `src`'s tracked final
stack; the instruction stream transfers at the ir/ layer. No byte round-trip and
NO human-declared effects — the fragment's real, validator-tracked stack shape
transfers, so a mis-declared splice is impossible at these seams.
parity(quarantine: the merge of a fragment builder into its caller; dart emits a function into
one builder, so it has none.)
"""
function append_builder!(dst::InstrBuilder, src::InstrBuilder)::InstrBuilder
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
        error("append_builder!($(dst.func_name) ← $(src.func_name)): source has open control labels: " *
              "$(length(src.v.labels)) labels; $_report")
    end
    # Fragment violations PROPAGATE — they were silently dropped here,
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
    # the fragment's source mappings, shifted to where its instructions land (dart has one
    # builder per function; WT merges fragments, as dart's serializer merges a body's
    # mappings into the module's, function.dart:123 copyMappings)
    if records_source_maps(dst) && records_source_maps(src)
        local shift = length(dst.instrs)
        for m in src.source_mappings
            _add_source_mapping!(dst, shift_by(m, shift))
        end
    end
    sizehint!(dst.instrs, length(dst.instrs) + length(src.instrs))
    for ins in src.instrs
        push!(dst.instrs, ins)
    end
    return _check!(dst)
end
