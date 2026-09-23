# ============================================================================
# Code Generation
# ============================================================================


"""
    _get_local_type(ctx, local_idx) -> Union{WasmValType, Nothing}

Get the Wasm type of a local variable by its index. Parameters come first,
then additional locals from ctx.locals.
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
function generate_body(ctx::AbstractCompilationContext)::Vector{UInt8}
    # Analyze control flow to find basic block structure
    blocks = analyze_blocks(ctx.nir)

    # The finalized typed instruction stream is authoritative. In particular,
    # post-return code is already stack-polymorphic in the builder; no serialized
    # opcode may be inspected or rewritten after this point.
    return generate_structured(ctx, blocks)
end






"""
Represents a basic block in the IR.
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
    # Payload: (anyref exn, externref stackTrace — null until traces wire).
    if isempty(mod.tags)
        tag_ft = FuncType(WasmValType[AnyRef, ExternRef], WasmValType[])
        add_tag!(mod, add_type!(mod, tag_ft))
    end
end

"""
Ensure module has the \$current_exn global for exception value stashing.
This is a (mut anyref) global initialized to ref.null any.
Returns the global index. Idempotent — scans existing globals to avoid duplicates.
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

"""
Generate try/catch code using generate_stackified_flow for the try body.
Used when the try body has complex control flow (phi nodes, nested conditionals).
The simple linear approach in generate_try_catch can't handle phi locals or nested
GotoIfNot, causing null pointer dereferences from uninitialized phi locals.

Structure:
  block \$catch_landing (void)          ; catch_all jumps here
    try_table (catch \$exceptionTag)   ; catch clause retains its landing label
      ; generate_stackified_flow for all blocks before catch handler
      ; (handles phi nodes, nested control flow, all returns)
    end
  end
  ; catch handler code (pop_exception skipped, returns -1 or similar)
"""
# Compile a catch-handler region [from..to] honouring GotoIfNot
# (conditional catch arms / exception isa dispatch). The linear per-statement
# loops no-op'd GotoIfNot, so `catch; if x; a; else; b; end` always produced the
# then arm (gap f80bce91645e). Mirrors the handling from the simple
# no-merge generator.
"""builder-native (THE implementation): compile a catch-region [from..to] into `b`."""

# `if cond; try A catch X end else try B catch
# Y end end` — two INDEPENDENT try/catches, one per branch arm, every arm
# returning. Neither the chain nor the sequential generator fits (chain glues
# the else arm into the then arm's catch; sequential leaves the branch
# condition stranded on the stack). Layout:
#   <pre-branch code>
#   block $else
#     cond eqz br_if 0                ;; !cond → else arm
#     <then arm: try_table A / catch X>   ;; all paths return
#   end
#   <else arm: try_table B / catch Y>     ;; all paths return
"""builder-native front for the branch-split try generator."""
