# ============================================================================
# Code Generation
# ============================================================================


"""
    _get_local_type(ctx, local_idx) -> Union{WasmValType, Nothing}

Get the Wasm type of a local variable by its index. Parameters come first,
then additional locals from ctx.locals.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1018 InstructionsBuilder.local_get)
"""
function _get_local_type(ctx::AbstractCompilationContext, local_idx::Int)::Union{WasmValType, Nothing}
    if local_idx < ctx.n_params
        # It's a parameter — get type from arg_types (skip WasmGlobal args)
        param_count = 0
        for (i, T) in enumerate(ctx.arg_types)
            if i in ctx.global_args
                continue
            end
            if param_count == local_idx
                return get_concrete_wasm_type(T, ctx.mod, ctx.type_registry)
            end
            param_count += 1
        end
        return nothing
    else
        # It's an additional local
        local_offset = local_idx - ctx.n_params
        if local_offset >= 0 && local_offset < length(ctx.locals)
            return ctx.locals[local_offset + 1]  # 1-indexed
        end
        return nothing
    end
end

"""
Generate Wasm bytecode from Julia CodeInfo.
Uses a block-based translation for control flow.

parity(code_generator.dart:38 CodeGenerator.generate)
"""
function generate_body(ctx::AbstractCompilationContext)::Tuple{Vector{UInt8},Vector{SourceMapping}}
    # Analyze control flow to find basic block structure
    blocks = analyze_blocks(ctx.nir)

    # The finalized typed instruction stream is authoritative. In particular,
    # post-return code is already stack-polymorphic in the builder; no serialized
    # opcode may be inspected or rewritten after this point.
    return generate_structured(ctx, blocks)
end






"""
Represents a basic block in the IR.
parity(quarantine: Julia's IR is a CFG of gotos; WT recovers its blocks and structure, where dart's kernel tree carries its structure (dev/formal/Stackifier.tla).)
"""
struct BasicBlock
    start_idx::Int
    end_idx::Int
    terminator::Union{NirGotoIfNot, NirGoto, NirReturn, Nothing}   # nothing: falls through
end

"""
Represents a try/catch region in the IR.

parity(quarantine: Julia's typed IR marks a try as a flat Core.EnterNode with a catch_dest and a later :leave, where Kernel has a structured TryCatch node; the region's three statement indices are what the stackifier nests into try_table)
"""
struct TryRegion
    enter_idx::Int      # SSA index of Core.EnterNode
    catch_dest::Int     # SSA index where catch block starts
    leave_idx::Int      # SSA index of :leave expression (end of try body)
end

"""
Find try/catch regions by scanning for try-region entries (`Core.EnterNode`).
Returns a list of TryRegion structs.

parity(quarantine: Julia's typed IR marks a try as a flat Core.EnterNode and a later :leave
naming it, where Kernel has a structured TryCatch node; this scan pairs them into the
TryRegion the stackifier nests into try_table.)
"""
function find_try_regions(nir::Vector{NirStmt})::Vector{TryRegion}
    regions = TryRegion[]

    for (i, rec) in enumerate(nir)
        if rec.node isa NirEnter
            catch_dest = rec.node.catch_target
            # Find the corresponding :leave that references this EnterNode
            leave_idx = something(findfirst(nir) do s
                s.node isa NirLeave && any(a -> a isa NirSSA && a.id == i, s.node.enters)
            end, 0)

            if leave_idx > 0
                push!(regions, TryRegion(i, catch_dest, leave_idx))
            elseif catch_dest > i
                # An always-throwing try body has NO :leave (Julia elides
                # it when the body can't exit normally — e.g. `try div(0,0) catch`).
                # Dropping the region here meant no try_table was emitted at all, so
                # the throw escaped uncaught. Synthesize leave_idx = catch_dest: the
                # try body becomes enter+1 .. catch_dest-1 and every consumer's
                # normal-exit range (leave_idx+1 .. catch_dest-1) is empty, which is
                # exactly right — there is no normal exit.
                push!(regions, TryRegion(i, catch_dest, catch_dest))
            end
        end
    end

    return regions
end

"""
Check if the IR contains try/catch regions.

parity(quarantine: Julia's typed IR marks a try as a flat Core.EnterNode statement, where Kernel has a structured TryCatch node)
"""
has_try_catch(nir::Vector{NirStmt})::Bool = any(rec -> rec.node isa NirEnter, nir)

"""
    stmt_is_proven_unreachable(nir, idx) -> Bool

Return `true` only when the ordinary Julia CFG proves that `idx` cannot be reached
from entry.  This is the sole condition under which an unsupported lowering may be
kept as a diagnosed validating trap instead of rejecting compilation.  Uncertainty
(including exception-bearing CFGs) is reachable for soundness purposes.

parity(quarantine: Julia's typed IR is a goto CFG that can keep blocks no edge reaches, and a
trap is sound only in such a block; dart's TFA removes unreachable members before codegen
(code_generator.dart:5084 UnreachableCodeGenerator), so Kernel code never needs a statement
reachability proof.)
formal(dev/formal/ProvenDead.tla): a statement proven dead has no control-flow path from entry
"""
function stmt_is_proven_unreachable(nir::Vector{NirStmt}, idx::Int)::Bool
    1 <= idx <= length(nir) || return false
    has_try_catch(nir) && return false
    blocks = analyze_blocks(nir)
    isempty(blocks) && return false
    bidx = findfirst(b -> b.start_idx <= idx <= b.end_idx, blocks)
    bidx === nothing && return false
    start2id = Dict{Int,Int}(blocks[i].start_idx => i for i in eachindex(blocks))
    reachable = falses(length(blocks))
    reachable[1] = true
    work = Int[1]
    while !isempty(work)
        bi = pop!(work)
        term = blocks[bi].terminator
        successors = Int[]
        if term isa NirGoto
            haskey(start2id, term.target) && push!(successors, start2id[term.target])
        elseif term isa NirGotoIfNot
            haskey(start2id, term.target) && push!(successors, start2id[term.target])
            bi < length(blocks) && push!(successors, bi + 1)
        elseif !(term isa NirReturn)
            bi < length(blocks) && push!(successors, bi + 1)
        end
        for si in successors
            reachable[si] || (reachable[si] = true; push!(work, si))
        end
    end
    return !reachable[bidx]
end

"""
Analyze the IR to find basic block boundaries.
A new block starts after each terminator AND at each jump target.
parity(quarantine: Julia's IR is a CFG of gotos; WT recovers its blocks and structure, where dart's kernel tree carries its structure (dev/formal/Stackifier.tla).)
"""
function analyze_blocks(nir::Vector{NirStmt})::Vector{BasicBlock}
    # First, collect all jump targets
    jump_targets = Set{Int}()
    for rec in nir
        if rec.node isa NirGoto || rec.node isa NirGotoIfNot
            push!(jump_targets, rec.node.target)
        end
    end

    blocks = BasicBlock[]
    block_start = 1

    for i in 1:length(nir)
        node = nir[i].node

        # Check if NEXT statement is a jump target (start new block after this one)
        next_is_jump_target = (i + 1) in jump_targets

        if node isa NirGotoIfNot || node isa NirGoto || node isa NirReturn
            push!(blocks, BasicBlock(block_start, i, node))
            block_start = i + 1
        elseif next_is_jump_target && i >= block_start
            # Current statement is NOT a terminator but next statement IS a jump target
            # Close current block with no terminator (fallthrough)
            push!(blocks, BasicBlock(block_start, i, nothing))
            block_start = i + 1
        end
    end

    # Handle trailing code without explicit terminator
    if block_start <= length(nir)
        push!(blocks, BasicBlock(block_start, length(nir), nothing))
    end

    return blocks
end


"""
Generate code for try/catch blocks using WASM exception handling (try_table).

Following dart2wasm's approach:
- Use a single exception tag for all Julia exceptions
- try_table with catch_all to handle any exception
- Catch handler gets exception value (if any)

WASM structure:
  (block \$after_try          ; exit point for try success
    (block \$catch_handler    ; catch handler block
      (try_table (catch_all 0) ; branch to \$catch_handler on exception
        ;; try body code
        (br 1)                 ; normal exit (skip catch)
      )
    )
    ;; catch handler code
  )
  ;; code after try/catch
Ensure module has exception tag 0 for Julia exceptions (idempotent)
Also ensures the \$current_exn global exists for exception value stashing.
parity(tags.dart:37 ExceptionTags._defineDartExceptionTag)
"""
function ensure_exception_tag!(mod::WasmModule)::Union{Nothing, UInt32}
    # THE TYPED TAG — dart's _defineDartExceptionTag carries
    # (exception, stackTrace) as the tag payload (tags.dart:37);
    # the value travels WITH the unwind, not via a pre-set global (re-entrancy).
    # Payload: (anyref exn, externref stackTrace — the throw's JS stack in a module that
    # records source maps, emit_throw_current!; null otherwise).
    if isempty(mod.tags)
        tag_ft = FuncType(WasmValType[AnyRef, ExternRef], WasmValType[])
        add_tag!(mod, add_type!(mod, tag_ft))
    end
end

"""
    emit_throw_current!(b, mod) -> b

Throw the current exception (the `\$current_exn` global) through the typed tag with its stack
trace: in a module that records source maps, the JS stack at the throw — the imported
`wasmtarget.stack_trace` answers `new Error()` (ensure_provenance_imports!) — else null. The
one throw every raise and rethrow ends in, as dart's throws all capture
`StackTrace.current` into the tag's stack slot.
parity(pkg/dart2wasm/lib/code_generator.dart:2955 CodeGenerator.visitThrow)
"""
function emit_throw_current!(b::InstrBuilder, mod::WasmModule)::InstrBuilder
    ensure_exception_tag!(mod)
    global_get!(b, ensure_exception_global!(mod), AnyRef)
    local st = _stack_trace_func_idx(mod)
    st === nothing ? ref_null!(b, ExternRef) : call!(b, st, WasmValType[], WasmValType[ExternRef])
    throw_!(b, 0; inputs=WasmValType[AnyRef, ExternRef])
    return b
end

"""
    ensure_provenance_imports!(mod)

What a module that records source maps adds when it is created, before any definition: the
import `wasmtarget.stack_trace: () -> externref`, which the host answers with `new Error()`
(the JS stack at the call: dart2wasm's JavaScriptStack.current), and the export of the
exception tag as `wasmtarget.exception`, so a host that catches an escaped Julia exception
can read the stack of its throw from the tag's payload.
parity(sdk/lib/_internal/wasm/js_common/js_helper.dart:857 JavaScriptStack.current)
"""
function ensure_provenance_imports!(mod::WasmModule)::Nothing
    _stack_trace_func_idx(mod) === nothing &&
        add_import!(mod, "wasmtarget", "stack_trace", WasmValType[], WasmValType[ExternRef])
    ensure_exception_tag!(mod)
    any(e -> e.name == "wasmtarget.exception", mod.exports) ||
        add_export!(mod, "wasmtarget.exception", 4, 0)
    return nothing
end

# The Julia types whose statements a traced compile reports, and the wasm local each lives in:
# exactly Julia's bits, so a traced value compares bit for bit with the native one.
# parity(quarantine: a traced compile reports each statement's value to the host so a wrong value is located at its first divergent statement; dart has no statement-value trace.)
const TRACED_STATEMENT_TYPES = Dict{Type,WasmValType}(Int64 => I64, UInt64 => I64, Int32 => I32,
                                                      Bool => I32, Float32 => F32, Float64 => F64)

"""
    ensure_trace_imports!(mod)

The imports a traced compile's probes call: `wasmtarget.trace_enter(function::i32)` on entry
to a traced function, and one per traced wasm type,
`wasmtarget.trace_i32/i64/f32/f64(function::i32, statement::i32, value)`. Added when the
module is created, before any definition.
parity(quarantine: a traced compile reports each statement's value to the host so a wrong value is located at its first divergent statement; dart has no statement-value trace.)
"""
function ensure_trace_imports!(mod::WasmModule)::Nothing
    _import_func_idx(mod, "wasmtarget", "trace_enter") === nothing &&
        add_import!(mod, "wasmtarget", "trace_enter", WasmValType[I32], WasmValType[])
    for (name, T) in (("trace_i32", I32), ("trace_i64", I64), ("trace_f32", F32), ("trace_f64", F64))
        _import_func_idx(mod, "wasmtarget", name) === nothing &&
            add_import!(mod, "wasmtarget", name, WasmValType[I32, I32, T], WasmValType[])
    end
    return nothing
end

# a traced function's trace id, or nothing
# parity(quarantine: a traced compile reports each statement's value to the host so a wrong value is located at its first divergent statement; dart has no statement-value trace.)
_trace_id(ctx::AbstractCompilationContext)::Union{Nothing,Int} =
    ctx.translator.trace === nothing ? nothing : get(ctx.translator.trace.ids, ctx.func_idx, nothing)

"""
    emit_trace_enter!(b, ctx) -> b

At the start of a traced function's body, report entering it: `wasmtarget.trace_enter(id)`, so
the host sees every function's probes in the order the calls ran.
parity(quarantine: a traced compile reports each statement's value to the host so a wrong value is located at its first divergent statement; dart has no statement-value trace.)
"""
function emit_trace_enter!(b::InstrBuilder, ctx::AbstractCompilationContext)::InstrBuilder
    local id = _trace_id(ctx)
    id === nothing && return b
    i32_const!(b, id)
    call!(b, something(_import_func_idx(ctx.mod, "wasmtarget", "trace_enter")), WasmValType[I32], WasmValType[])
    return b
end

"""
    emit_statement_trace!(b, ctx, idx, local_idx, local_type) -> b

In a traced function of a traced compile, report statement `idx`'s value (just stored in
`local_idx`) to the host: `wasmtarget.trace_<type>(id, idx, value)`, for a statement of a
traced type. Nothing otherwise.
parity(quarantine: a traced compile reports each statement's value to the host so a wrong value is located at its first divergent statement; dart has no statement-value trace.)
"""
function emit_statement_trace!(b::InstrBuilder, ctx::AbstractCompilationContext, idx::Int,
                               local_idx::Integer, local_type)::InstrBuilder
    local id = _trace_id(ctx)
    id === nothing && return b
    local T = get(ctx.ssa_types, idx, Any)
    get(TRACED_STATEMENT_TYPES, T, nothing) === local_type || return b
    local name = local_type === I64 ? "trace_i64" : local_type === I32 ? "trace_i32" :
                 local_type === F32 ? "trace_f32" : "trace_f64"
    i32_const!(b, id)
    i32_const!(b, idx)
    local_get!(b, local_idx)
    call!(b, something(_import_func_idx(ctx.mod, "wasmtarget", name)), WasmValType[I32, I32, local_type], WasmValType[])
    push!(ctx.translator.trace.probed[id], idx)
    return b
end

# the function index of an imported function, or nothing
# parity(pkg/wasm_builder/lib/src/builder/functions.dart:43 FunctionsBuilder.import)
function _import_func_idx(mod::WasmModule, module_name::String, field_name::String)::Union{Nothing,UInt32}
    local n = 0
    for imp in mod.imports
        imp.kind == 0x00 || continue
        (imp.module_name == module_name && imp.field_name == field_name) && return UInt32(n)
        n += 1
    end
    return nothing
end

# the function index of the imported `wasmtarget.stack_trace`, or nothing
# parity(sdk/lib/_internal/wasm/js_common/js_helper.dart:857 JavaScriptStack.current)
_stack_trace_func_idx(mod::WasmModule)::Union{Nothing,UInt32} = _import_func_idx(mod, "wasmtarget", "stack_trace")

"""
Ensure module has the \$current_exn global for exception value stashing.
This is a (mut anyref) global initialized to ref.null any.
Returns the global index. Idempotent — scans existing globals to avoid duplicates.
parity(quarantine: WT stashes the thrown Julia value in a global beside the tag's payload, where `catch` and jl_current_exception read it; dart's tag carries its exception and stack trace.)
"""
function ensure_exception_global!(mod::WasmModule)::UInt32
    # Check if we already have an anyref mutable global (our exception stash)
    for (i, g) in enumerate(mod.globals)
        if g.valtype === AnyRef && g.mutable_
            return UInt32(i - 1)
        end
    end
    # Create (global (mut anyref) (ref.null any))
    init = UInt8[0xD0, 0x6E, Opcode.END]  # ref.null any + end
    push!(mod.globals, WasmGlobalDef(AnyRef, true, init))
    return UInt32(length(mod.globals) - 1)
end

# census F7: the dormant stack-trace cluster (ensure_stack_trace_support!/
# emit_capture_stack!) is DELETED — zero callers since introduction .
# The dart-shaped rebuild carries (exception, stackTrace) as the TYPED TAG PAYLOAD
# (tags.dart:37 ExceptionTags._defineDartExceptionTag) — census queue item D9.1; the dart
# source is the reference, not dead scaffolding.

