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
       set_context!, append_builder!

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
    # the function's live local types (a codegen-supplied closure idx → WasmValType, or nothing
    # for a parameter): a fragment builder types the locals its function allocates after the
    # fragment was made
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
                      func_name::String="", mod::WasmModule)::InstrBuilder
    locals = WasmValType[p for p in param_types]
    # the module whose types, functions, globals and tags every emit is checked against (dart:
    # an InstructionsBuilder always has its module)
    v = WasmStackValidator(; func_name=func_name, mod=mod)
    # Seed the outermost label as a :block whose results are the function results,
    # so end-of-function balance is checked against the declared results.
    push!(v.labels, ValidatorLabel(:expression, 0, WasmValType[],
                                   WasmValType[r for r in result_types], true))
    trace = OPTIONS[].builder_trace ? String[] : nothing
    records = mod.source_map_url !== nothing
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
    records_source_maps(b) && push!(mapped, body_end_mapping(code))
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

# Register a local's type so local.get/set/tee can be typed. idx is 0-based.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:382 InstructionsBuilder.addLocal)
function builder_add_local!(b::InstrBuilder, typ::WasmValType)::Int
    typ isa ConcreteRef && _module_type(b.v.mod, typ.type_idx, :add_local)   # a type the module defines
    push!(b.locals, typ)
    return length(b.locals) - 1
end
# parity(quarantine: the context-free Int128 builders (int128.jl) name their locals by index and
# type them afterwards; dart's addLocal takes a local's type when it creates it. A local the
# function's live local types hold keeps its type there (a different one is refused); any other
# index past the builder's next one would leave a local untyped between, and is refused.)
function builder_set_local_type!(b::InstrBuilder, idx::Integer, typ::WasmValType)::WasmValType
    if b.locals_fn !== nothing
        local held = b.locals_fn(Int(idx))
        if held isa WasmValType
            held == typ || throw(ArgumentError("builder_set_local_type!($(b.func_name)): local $idx is a $held, not $typ"))
            return typ
        end
    end
    0 <= idx <= length(b.locals) ||
        throw(ArgumentError("builder_set_local_type!($(b.func_name)): local $idx is past the next one, $(length(b.locals))"))
    typ isa ConcreteRef && _module_type(b.v.mod, typ.type_idx, :add_local)   # a type the module defines
    idx == length(b.locals) ? push!(b.locals, typ) : (b.locals[idx + 1] = typ)
    return typ
end

# Reject the instruction being emitted, at its call, with the builder's context.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:452 InstructionsBuilder._reportError)
function _reject!(b::InstrBuilder, msg::String)::Union{}
    push!(b.v.errors, "$(b.func_name): $msg [ctx: $(b.context)]")
    _check!(b)
    error("unreachable: _check! throws on a recorded error")
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
# The no-immediate numeric, comparison and conversion instructions: validate_instruction! holds
# their operand types by opcode and refuses any other opcode (one with an immediate, a memory
# access, a reference instruction), each of which has its own method.
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
    validate_pop!(b.v, I32)  # condition
    validate_pop!(b.v, t)
    validate_pop!(b.v, t)
    validate_push!(b.v, t)
    _emit!(b, t isa NumType ? InstrIR.Select() : InstrIR.SelectWithType(t))
end

# ── Variable ────────────────────────────────────────────────────────────────────
# The type of local `idx`: the function's live local types (locals_fn) outrank the builder's own
# list; a local neither holds is not the function's, and the instruction naming it is rejected.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1018 InstructionsBuilder.local_get)
function _local_type(b::InstrBuilder, idx::Integer, op::String)::WasmValType
    if b.locals_fn !== nothing
        local t = b.locals_fn(Int(idx))
        t isa WasmValType && return t
    end
    0 <= idx < length(b.locals) && return b.locals[idx + 1]
    _reject!(b, "$op: local $idx is not defined (the function has $(length(b.locals)) locals)")
end

# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1018 InstructionsBuilder.local_get)
function local_get!(b::InstrBuilder, idx::Integer)::InstrBuilder
    validate_push!(b.v, _local_type(b, idx, "local.get"))
    _emit!(b, InstrIR.LocalGet(UInt32(idx)))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1035 InstructionsBuilder.local_set)
function local_set!(b::InstrBuilder, idx::Integer)::InstrBuilder
    validate_pop!(b.v, _local_type(b, idx, "local.set"))
    _emit!(b, InstrIR.LocalSet(UInt32(idx)))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1049 InstructionsBuilder.local_tee)
function local_tee!(b::InstrBuilder, idx::Integer)::InstrBuilder
    lt = _local_type(b, idx, "local.tee")
    validate_pop!(b.v, lt); validate_push!(b.v, lt)
    _emit!(b, InstrIR.LocalTee(UInt32(idx)))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1063 InstructionsBuilder.global_get)
function global_get!(b::InstrBuilder, idx::Integer)::InstrBuilder
    validate_push!(b.v, _module_global(b.v.mod, idx, :global_get).valtype)
    _emit!(b, InstrIR.GlobalGet(UInt32(idx)))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1072 InstructionsBuilder.global_set)
function global_set!(b::InstrBuilder, idx::Integer)::InstrBuilder
    local g = _module_global(b.v.mod, idx, :global_set)
    g.mutable_ || _module_invalid(:global_set, "global $idx is immutable")
    validate_pop!(b.v, g.valtype)
    _emit!(b, InstrIR.GlobalSet(UInt32(idx)))
end

# the global `idx`, imported or defined: one index space, the imported globals first
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1063 InstructionsBuilder.global_get)
function _module_global(m::WasmModule, idx::Integer, op::Symbol)::WasmModuleGlobal
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
                      results::Vector{WasmValType})::InstrIR.BlockTypeArg
    isempty(inputs) && isempty(results) && return InstrIR.VOID_BLOCK
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
           ins isa InstrIR.BeginTry
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

# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:947 InstructionsBuilder.call)
function call!(b::InstrBuilder, func_idx::Integer)::InstrBuilder
    local ft = _function_type(b.v.mod, func_idx)
    if b.v.reachable
        for p in reverse(ft.params); validate_pop!(b.v, p); end
        for r in ft.results; validate_push!(b.v, r); end
    end
    _emit!(b, InstrIR.Call(UInt32(func_idx)))
end

# call_indirect: pop the table index (i32), then the type's params; push its results
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:960 InstructionsBuilder.call_indirect)
function call_indirect!(b::InstrBuilder, type_idx::Integer, table_idx::Integer)::InstrBuilder
    local ft = _module_func_type(b.v.mod, type_idx, :call_indirect)
    0 <= table_idx < length(b.v.mod.tables) || _module_invalid(:call_indirect, "table $table_idx is not defined")
    if b.v.reachable
        validate_pop!(b.v, I32)  # the function index into the table
        for p in reverse(ft.params); validate_pop!(b.v, p); end
        for r in ft.results; validate_push!(b.v, r); end
    end
    _emit!(b, InstrIR.CallIndirect(UInt32(type_idx), UInt32(table_idx)))
end

# call_ref: pop the (ref null $type) callee, then the type's params; push its results
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:973 InstructionsBuilder.call_ref)
function call_ref!(b::InstrBuilder, type_idx::Integer)::InstrBuilder
    local ft = _module_func_type(b.v.mod, type_idx, :call_ref)
    if b.v.reachable
        validate_pop!(b.v, ConcreteRef(UInt32(type_idx), true))
        for p in reverse(ft.params); validate_pop!(b.v, p); end
        for r in ft.results; validate_push!(b.v, r); end
    end
    _emit!(b, InstrIR.CallRef(UInt32(type_idx)))
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
    return _wt_drop_nullable(t)
end

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

# ── Exception handling (legacy, the form dart2wasm emits) ──────────────────────────
# A legacy try: a label of kind :try whose block type is derived from its inputs and outputs as
# every block's is (_block_type!); its `end` checks the outputs as every block's end does.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:788 InstructionsBuilder.try_legacy)
function try_legacy!(b::InstrBuilder; inputs::Vector{<:Any}=WasmValType[],
                     results::Vector{<:Any}=WasmValType[])::ControlLabel
    local ins, outs = WasmValType[t for t in inputs], WasmValType[t for t in results]
    local blocktype = _block_type!(b, ins, outs)
    label = validate_block_start!(b.v, :try, ins, outs)
    _emit!(b, InstrIR.BeginTry(blocktype)); return label
end
# A legacy catch of tag `tag`: the innermost label is a try, the try body's stack is checked
# against the try's outputs, the catch body starts with the tag's inputs, and the tag is one
# the module defines (dart: `assert(tag.enclosingModule == module)`).
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:799 InstructionsBuilder.catch_legacy)
function catch_legacy!(b::InstrBuilder, tag::Integer)::InstrBuilder
    local m = b.v.mod
    0 <= tag < length(m.tags) || _module_invalid(:catch, "tag $tag is not defined")
    local ft = m.types[Int(m.tags[tag + 1].type_idx) + 1]
    ft isa FuncType || _module_invalid(:catch, "tag $tag's type is not a function type")
    validate_catch_legacy!(b.v, WasmValType[t for t in ft.params])
    _emit!(b, InstrIR.CatchLegacy(UInt32(tag)))
end
# throw tag: pop the tag's inputs (caller declares them), then unreachable (dart2wasm throw_).
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:820 InstructionsBuilder.throw_)
function throw_!(b::InstrBuilder, tag::Integer)::InstrBuilder
    # the tag's own inputs (dart throw_: _verifyTypes(tag.type.inputs, []))
    local m = b.v.mod
    0 <= tag < length(m.tags) || _module_invalid(:throw, "tag $tag is not defined")
    local ft = m.types[Int(m.tags[tag + 1].type_idx) + 1]
    ft isa FuncType || _module_invalid(:throw, "tag $tag's type is not a function type")
    if b.v.reachable
        for t in reverse(ft.params); validate_pop!(b.v, t); end
    end
    b.v.reachable = false
    _emit!(b, InstrIR.Throw(UInt32(tag)))
end

# ── Reference ───────────────────────────────────────────────────────────────────
# ref.null of a defined type: the caller names the heap type, and the pushed type is its nullable
# reference (dart ref_null(heapType) pushes `RefType(heapType, nullable: true)`)
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1570 InstructionsBuilder.ref_null)
function ref_null!(b::InstrBuilder, heaptype::Integer)::InstrBuilder
    _module_type(b.v.mod, heaptype, :ref_null)
    validate_push!(b.v, ConcreteRef(UInt32(heaptype), true))
    _emit!(b, InstrIR.RefNullConcrete(Int64(heaptype)))
end
# ref.null of an abstract heap type (any/struct/array/i31/…): the RefType enum value is both the
# nullable reference pushed and the heap type's one on-wire byte
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1570 InstructionsBuilder.ref_null)
ref_null!(b::InstrBuilder, rt::RefType)::InstrBuilder =
    (validate_push!(b.v, rt); _emit!(b, InstrIR.RefNullAbstract(UInt8(rt))))
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1582 InstructionsBuilder.ref_is_null)
ref_is_null!(b::InstrBuilder)::InstrBuilder =
    (validate_pop_ref!(b.v); validate_push!(b.v, I32); _emit!(b, InstrIR.RefIsNull()))
# ref.as_non_null: the operand with its null removed (dart: `_topOfStack.withNullability(false)`)
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1607 InstructionsBuilder.ref_as_non_null)
function ref_as_non_null!(b::InstrBuilder)::InstrBuilder
    t = validate_pop_ref!(b.v)
    validate_push!(b.v, t === nothing ? AnyRef : _wt_drop_nullable(t))
    _emit!(b, InstrIR.RefAsNonNull())
end
# ref.eq: two eqrefs, an i32
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1632 InstructionsBuilder.ref_eq)
ref_eq!(b::InstrBuilder)::InstrBuilder =
    (validate_pop!(b.v, EqRef); validate_pop!(b.v, EqRef); validate_push!(b.v, I32); _emit!(b, InstrIR.RefEq()))

# ── The module's types ──────────────────────────────────────────────────────────
# The type the module defines at `idx`, of the kind the instruction takes (a struct, an array or a
# function type): the module's type is the only type an instruction is checked against, and an
# undefined index or another kind is invalid (dart's instructions take the type object itself).
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1657 InstructionsBuilder.struct_get)
function _module_type(m::WasmModule, idx::Integer, op::Symbol)::CompositeType
    0 <= idx < length(m.types) || _module_invalid(op, "type $idx is not defined")
    return m.types[Int(idx) + 1]
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1711 InstructionsBuilder.struct_new)
function _module_struct(m::WasmModule, idx::Integer, op::Symbol)::StructType
    local ct = _module_type(m, idx, op)
    ct isa StructType || _module_invalid(op, "type $idx is not a struct type")
    return ct
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1735 InstructionsBuilder.array_get)
function _module_array(m::WasmModule, idx::Integer, op::Symbol)::ArrayType
    local ct = _module_type(m, idx, op)
    ct isa ArrayType || _module_invalid(op, "type $idx is not an array type")
    return ct
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:973 InstructionsBuilder.call_ref)
function _module_func_type(m::WasmModule, idx::Integer, op::Symbol)::FuncType
    local ct = _module_type(m, idx, op)
    ct isa FuncType || _module_invalid(op, "type $idx is not a function type")
    return ct
end
# a struct type's field
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1657 InstructionsBuilder.struct_get)
function _module_field(m::WasmModule, idx::Integer, field::Integer, op::Symbol)::FieldType
    local st = _module_struct(m, idx, op)
    0 <= field < length(st.fields) || _module_invalid(op, "struct type $idx has no field $field")
    return st.fields[Int(field) + 1]
end
# Does a storage type have a default value (a struct.new_default or array.new_default field)? A
# number and a packed type do; a reference only when nullable.
# parity(pkg/wasm_builder/lib/src/ir/type.dart:233 RefType.defaultable)
_defaultable(t::StorageType)::Bool = t isa PackedType || t isa NumType || _wt_ref_nullable(t)

# ── WasmGC (each instruction typed by the module's type) ────────────────────────
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1711 InstructionsBuilder.struct_new)
function struct_new!(b::InstrBuilder, type_idx::Integer)::InstrBuilder
    local st = _module_struct(b.v.mod, type_idx, :struct_new)
    validate_gc_instruction!(b.v, Opcode.STRUCT_NEW, (type_idx, WasmValType[unpacked(f.valtype) for f in st.fields]))
    _emit!(b, InstrIR.StructNew(UInt32(type_idx)))
end
# Every field must have a default: the spec's rule, which dart leaves to the engine (checked as the
# else-less if is).
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1723 InstructionsBuilder.struct_new_default)
function struct_new_default!(b::InstrBuilder, type_idx::Integer)::InstrBuilder
    local st = _module_struct(b.v.mod, type_idx, :struct_new_default)
    for (i, f) in enumerate(st.fields)
        _defaultable(f.valtype) || _module_invalid(:struct_new_default,
            "field $(i - 1) of struct type $type_idx, a $(f.valtype), has no default value")
    end
    validate_gc_instruction!(b.v, Opcode.STRUCT_NEW_DEFAULT, type_idx)
    _emit!(b, InstrIR.StructNewDefault(UInt32(type_idx)))
end
# struct.get reads a value-type field; a packed one is read by struct.get_s or struct.get_u (dart
# asserts `fields[fieldIndex].type is ir.ValueType`)
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1657 InstructionsBuilder.struct_get)
function struct_get!(b::InstrBuilder, type_idx::Integer, field_idx::Integer)::InstrBuilder
    local f = _module_field(b.v.mod, type_idx, field_idx, :struct_get)
    f.valtype isa PackedType &&
        _module_invalid(:struct_get, "field $field_idx of struct type $type_idx is packed: struct.get_s or struct.get_u reads it")
    validate_gc_instruction!(b.v, Opcode.STRUCT_GET, (type_idx, unpacked(f.valtype)))
    _emit!(b, InstrIR.StructGet(UInt32(type_idx), UInt32(field_idx), Opcode.STRUCT_GET))
end
# struct.set writes a mutable field (the spec's rule, which dart leaves to the engine), its value
# the field's unpacked type
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1696 InstructionsBuilder.struct_set)
function struct_set!(b::InstrBuilder, type_idx::Integer, field_idx::Integer)::InstrBuilder
    local f = _module_field(b.v.mod, type_idx, field_idx, :struct_set)
    f.mutable_ || _module_invalid(:struct_set, "field $field_idx of struct type $type_idx is immutable")
    validate_gc_instruction!(b.v, Opcode.STRUCT_SET, (type_idx, unpacked(f.valtype)))
    _emit!(b, InstrIR.StructSet(UInt32(type_idx), UInt32(field_idx)))
end
# array.new_default: an array type whose element has a default (the spec's rule)
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1827 InstructionsBuilder.array_new_default)
function array_new_default!(b::InstrBuilder, type_idx::Integer)::InstrBuilder
    local at = _module_array(b.v.mod, type_idx, :array_new_default)
    _defaultable(at.elem.valtype) || _module_invalid(:array_new_default,
        "array type $type_idx's element, a $(at.elem.valtype), has no default value")
    validate_gc_instruction!(b.v, Opcode.ARRAY_NEW_DEFAULT, type_idx)
    _emit!(b, InstrIR.ArrayNewDefault(UInt32(type_idx)))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1802 InstructionsBuilder.array_new_fixed)
function array_new_fixed!(b::InstrBuilder, type_idx::Integer, n::Integer)::InstrBuilder
    local at = _module_array(b.v.mod, type_idx, :array_new_fixed)
    validate_gc_instruction!(b.v, Opcode.ARRAY_NEW_FIXED, (type_idx, unpacked(at.elem.valtype), n))
    _emit!(b, InstrIR.ArrayNewFixed(UInt32(type_idx), UInt32(n)))
end
# array.new_data $type $seg : [offset:i32, length:i32] -> [(ref $type)]; the element is primitive
# (dart asserts `elementType.type.isPrimitive`) and the segment is the module's
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1839 InstructionsBuilder.array_new_data)
function array_new_data!(b::InstrBuilder, type_idx::Integer, seg_idx::Integer)::InstrBuilder
    local at = _module_array(b.v.mod, type_idx, :array_new_data)
    (at.elem.valtype isa PackedType || at.elem.valtype isa NumType) || _module_invalid(:array_new_data,
        "array type $type_idx's element, a $(at.elem.valtype), is not primitive")
    0 <= seg_idx < length(b.v.mod.data_segments) || _module_invalid(:array_new_data, "data segment $seg_idx is not defined")
    if b.v.reachable
        validate_pop!(b.v, I32); validate_pop!(b.v, I32)
        validate_push!(b.v, ConcreteRef(UInt32(type_idx), false))
    end
    _emit!(b, InstrIR.ArrayNewData(UInt32(type_idx), UInt32(seg_idx)))
end
# array.get reads an unpacked element, array.get_s/_u a packed one (dart's array_get asserts a value
# type, array_get_s/_u a packed one)
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1735 InstructionsBuilder.array_get)
function array_get!(b::InstrBuilder, type_idx::Integer; signed::Union{Nothing,Bool}=nothing)::InstrBuilder
    local at = _module_array(b.v.mod, type_idx, :array_get)
    local packed = at.elem.valtype isa PackedType
    packed && signed === nothing &&
        _module_invalid(:array_get, "array type $type_idx has packed elements: array.get_s or array.get_u reads them")
    !packed && signed !== nothing &&
        _module_invalid(:array_get, "array type $type_idx has unpacked elements: array.get reads them")
    op = signed === nothing ? Opcode.ARRAY_GET : (signed ? Opcode.ARRAY_GET_S : Opcode.ARRAY_GET_U)
    validate_gc_instruction!(b.v, op, (type_idx, unpacked(at.elem.valtype)))
    _emit!(b, InstrIR.ArrayGet(UInt32(type_idx), op))
end
# array.set writes a mutable array (the spec's rule, which dart leaves to the engine)
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1774 InstructionsBuilder.array_set)
function array_set!(b::InstrBuilder, type_idx::Integer)::InstrBuilder
    local at = _module_array(b.v.mod, type_idx, :array_set)
    at.elem.mutable_ || _module_invalid(:array_set, "array type $type_idx is immutable")
    validate_gc_instruction!(b.v, Opcode.ARRAY_SET, (type_idx, unpacked(at.elem.valtype)))
    _emit!(b, InstrIR.ArraySet(UInt32(type_idx)))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1790 InstructionsBuilder.array_len)
array_len!(b::InstrBuilder)::InstrBuilder = (validate_gc_instruction!(b.v, Opcode.ARRAY_LEN); _emit!(b, InstrIR.ArrayLen()))

"""
    _verify_cast!(b, target, output) -> b

The one check of a cast or a test: the operand is a reference under the target's top type (dart's
input `RefType(targetType.heapType.topType, nullable: true)`), the target a subtype of that input;
then `output` is pushed (the target for a cast, i32 for a test).
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1927 InstructionsBuilder._verifyCast)
"""
function _verify_cast!(b::InstrBuilder, target::WasmValType, output::WasmValType)::InstrBuilder
    local types = b.v.mod.types
    local input = _wt_top_ref(target, types)
    input === nothing && _reject!(b, "the cast target $target has no top type WT models")
    validate_pop!(b.v, input)
    wasm_subtype(target, input, types) ||
        push!(b.v.errors, "$(b.func_name): the cast target $target is not a subtype of its input $input")
    validate_push!(b.v, output)
    return b
end

# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1961 InstructionsBuilder.ref_cast)
function ref_cast!(b::InstrBuilder, type_idx::Integer, nullable::Bool)::InstrBuilder
    _module_type(b.v.mod, type_idx, :ref_cast)
    local target = ConcreteRef(UInt32(type_idx), nullable)
    _verify_cast!(b, target, target)
    _emit!(b, InstrIR.RefCastConcrete(Int64(type_idx), nullable))
end
# Cast to an abstract heap type (i31/array/struct/...), its one on-wire byte: `ref.cast null`
# pushes the nullable shorthand, `ref.cast` its non-null form.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1961 InstructionsBuilder.ref_cast)
function ref_cast!(b::InstrBuilder, rt::RefType, nullable::Bool)::InstrBuilder
    if b.v.reachable
        local target = nullable ? rt : NonNullAbstractRef(UInt8(rt))
        _verify_cast!(b, target, target)
    end
    _emit!(b, InstrIR.RefCastAbstract(UInt8(rt), nullable))
end
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1944 InstructionsBuilder.ref_test)
function ref_test!(b::InstrBuilder, type_idx::Integer, nullable::Bool)::InstrBuilder
    _module_type(b.v.mod, type_idx, :ref_test)
    _verify_cast!(b, ConcreteRef(UInt32(type_idx), nullable), I32)
    _emit!(b, InstrIR.RefTest(Int64(type_idx), nullable))
end
# ref.test of an abstract heap type (eq/struct/array/i31/…): its immediate is the heap type's code,
# the RefType enum's byte read as a signed 7-bit value (0x6D, eq, is -19)
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1944 InstructionsBuilder.ref_test)
function ref_test!(b::InstrBuilder, rt::RefType, nullable::Bool)::InstrBuilder
    _verify_cast!(b, nullable ? rt : NonNullAbstractRef(UInt8(rt)), I32)
    _emit!(b, InstrIR.RefTest(Int64(UInt8(rt)) - 128, nullable))
end
# any.convert_extern: an externref, an anyref of its nullability
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:2028 InstructionsBuilder.any_convert_extern)
function any_convert_extern!(b::InstrBuilder)::InstrBuilder
    local t = validate_pop!(b.v, ExternRef)
    validate_push!(b.v, _wt_is_ref(t) && !_wt_ref_nullable(t) ? NonNullAbstractRef(UInt8(AnyRef)) : AnyRef)
    _emit!(b, InstrIR.AnyConvertExtern())
end
# extern.convert_any: an anyref, an externref of its nullability
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:2040 InstructionsBuilder.extern_convert_any)
function extern_convert_any!(b::InstrBuilder)::InstrBuilder
    local t = validate_pop!(b.v, AnyRef)
    validate_push!(b.v, _wt_is_ref(t) && !_wt_ref_nullable(t) ? NonNullExternRef : ExternRef)
    _emit!(b, InstrIR.ExternConvertAny())
end
# array.copy: the destination mutable and the source's element a subtype of the destination's (the
# spec's rules, which dart leaves to the engine)
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1852 InstructionsBuilder.array_copy)
function array_copy!(b::InstrBuilder, dst_type_idx::Integer, src_type_idx::Integer)::InstrBuilder
    local m = b.v.mod
    local dst = _module_array(m, dst_type_idx, :array_copy).elem
    local src = _module_array(m, src_type_idx, :array_copy).elem
    dst.mutable_ || _module_invalid(:array_copy, "the destination array type $dst_type_idx is immutable")
    ((dst.valtype isa PackedType || src.valtype isa PackedType) ? src.valtype === dst.valtype :
        wasm_subtype(src.valtype, dst.valtype, m.types)) || _module_invalid(:array_copy,
        "array type $src_type_idx's element $(src.valtype) is not a subtype of array type $dst_type_idx's $(dst.valtype)")
    validate_gc_instruction!(b.v, Opcode.ARRAY_COPY, (dst_type_idx, src_type_idx))
    _emit!(b, InstrIR.ArrayCopy(UInt32(dst_type_idx), UInt32(src_type_idx)))
end
# array.fill writes a mutable array (the spec's rule)
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1875 InstructionsBuilder.array_fill)
function array_fill!(b::InstrBuilder, type_idx::Integer)::InstrBuilder
    local at = _module_array(b.v.mod, type_idx, :array_fill)
    at.elem.mutable_ || _module_invalid(:array_fill, "array type $type_idx is immutable")
    validate_gc_instruction!(b.v, Opcode.ARRAY_FILL, (type_idx, unpacked(at.elem.valtype)))
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
            if _ins isa InstrIR.Block || _ins isa InstrIR.Loop || _ins isa InstrIR.If || _ins isa InstrIR.BeginTry
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
    # the fragment's source mappings, shifted to where its instructions land (dart has one
    # builder per function; WT merges fragments, as dart's serializer merges a body's
    # mappings into the module's, function.dart:123 copyMappings)
    if records_source_maps(dst) && records_source_maps(src)
        local shift = length(dst.instrs)
        for m in src.source_mappings
            _add_source_mapping!(dst, shift_by(m, shift))
        end
    end
    # element by element: a bulk `append!` of this abstract-eltype vector left #undef slots in
    # the copied region under Julia 1.13.0-rc1 (GC-timing dependent), which builder_code
    # refuses; a push! writes each slot as it transfers
    sizehint!(dst.instrs, length(dst.instrs) + length(src.instrs))
    for ins in src.instrs
        push!(dst.instrs, ins)
    end
    return _check!(dst)
end
