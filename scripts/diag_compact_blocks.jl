#!/usr/bin/env julia
# diag_compact_blocks.jl — Show block structure and open_blocks trace for compact!
# This diagnoses WHY br 0 is emitted (get_forward_label_depth returning 0)
#
# testCommand: julia +1.12 --project=. scripts/diag_compact_blocks.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
using JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)
@isdefined(IRCode) || (@eval const IRCode = Core.Compiler.IRCode)

println("=== diag_compact_blocks: Trace block structure for compact! ===")

f = Compiler.compact!
arg_types = (IRCode, Bool)

# Get optimized code_info
println("Getting code_info for compact!...")
ci = code_typed(f, arg_types; optimize=true)[1][1]
code = ci.code
println("  $(length(code)) statements")

# Call analyze_blocks (exported from WasmTarget.jl internals)
# Need to access it from the WasmTarget module
analyze_blocks_fn = @eval WasmTarget.analyze_blocks
blocks = analyze_blocks_fn(code)
println("  $(length(blocks)) basic blocks")
println()

# Show block boundaries
println("=== BLOCK STRUCTURE ===")
for (i, blk) in enumerate(blocks)
    term = blk.terminator
    term_type = if term === nothing
        "no-terminator"
    elseif term isa Core.GotoNode
        "GotoNode($(term.label))"
    elseif term isa Core.GotoIfNot
        "GotoIfNot(dest=$(term.dest))"
    elseif term isa Core.ReturnNode
        "ReturnNode"
    else
        string(typeof(term))
    end
    println("  Block $i: stmts [$(blk.start_idx)..$(blk.end_idx)], term=$term_type")
end
println()

# Replicate the back-edge analysis from generate_stackified_flow
println("=== CONTROL FLOW ANALYSIS ===")

# Map statement index -> block index
stmt_to_block = Dict{Int, Int}()
for (block_idx, block) in enumerate(blocks)
    for i in block.start_idx:block.end_idx
        stmt_to_block[i] = block_idx
    end
end

# Build successor/predecessor maps
successors = Dict{Int, Vector{Int}}()
predecessors = Dict{Int, Vector{Int}}()
for i in 1:length(blocks)
    successors[i] = Int[]
    predecessors[i] = Int[]
end

for (block_idx, block) in enumerate(blocks)
    term = block.terminator
    if term isa Core.GotoIfNot
        dest_block = get(stmt_to_block, term.dest, nothing)
        fall_through_block = block_idx < length(blocks) ? block_idx + 1 : nothing
        if fall_through_block !== nothing && fall_through_block <= length(blocks)
            push!(successors[block_idx], fall_through_block)
            push!(predecessors[fall_through_block], block_idx)
        end
        if dest_block !== nothing
            push!(successors[block_idx], dest_block)
            push!(predecessors[dest_block], block_idx)
        end
    elseif term isa Core.GotoNode
        dest_block = get(stmt_to_block, term.label, nothing)
        if dest_block !== nothing
            push!(successors[block_idx], dest_block)
            push!(predecessors[dest_block], block_idx)
        end
    elseif term isa Core.ReturnNode || term === nothing
        if block_idx < length(blocks)
            push!(successors[block_idx], block_idx + 1)
            push!(predecessors[block_idx + 1], block_idx)
        end
    end
end

# Identify back edges
back_edges = Set{Tuple{Int, Int}}()
forward_edges = Set{Tuple{Int, Int}}()
loop_headers = Set{Int}()

for (block_idx, succs) in successors
    for succ in succs
        if succ <= block_idx
            push!(back_edges, (block_idx, succ))
            push!(loop_headers, succ)
        else
            push!(forward_edges, (block_idx, succ))
        end
    end
end

println("Back edges: $(collect(back_edges))")
println("Loop headers: $(sort(collect(loop_headers)))")
println()

# Non-trivial targets
non_trivial_targets = Set{Int}()
for (block_idx, block) in enumerate(blocks)
    term = block.terminator
    if term isa Core.GotoIfNot
        dest_block = get(stmt_to_block, term.dest, nothing)
        if dest_block !== nothing && dest_block != block_idx + 1
            push!(non_trivial_targets, dest_block)
        end
    elseif term isa Core.GotoNode
        dest_block = get(stmt_to_block, term.label, nothing)
        if dest_block !== nothing && dest_block != block_idx + 1
            push!(non_trivial_targets, dest_block)
        end
    end
end

println("Non-trivial forward targets: $(sort(collect(non_trivial_targets)))")
println()

# Loop latch analysis
loop_latches = Dict{Int, Int}()
for (src, dst) in back_edges
    if !haskey(loop_latches, dst) || src > loop_latches[dst]
        loop_latches[dst] = src
    end
end

println("Loop latches (header => latch_block):")
for (h, l) in sort(collect(loop_latches))
    println("  header=$h, latch=$l")
end
println()

# Target classification
target_loop = Dict{Int, Int}()
for target in non_trivial_targets
    for (header, latch) in loop_latches
        if target > header && target <= latch
            if !haskey(target_loop, target) || header > target_loop[target]
                target_loop[target] = header
            end
        end
    end
end

outer_targets = sort([t for t in non_trivial_targets if !haskey(target_loop, t)]; rev=true)
loop_inner_targets = Dict{Int, Vector{Int}}()
for (target, header) in target_loop
    if !haskey(loop_inner_targets, header)
        loop_inner_targets[header] = Int[]
    end
    push!(loop_inner_targets[header], target)
end
for header in keys(loop_inner_targets)
    sort!(loop_inner_targets[header]; rev=true)
end

println("Target classification:")
println("  outer_targets (outside all loops): $outer_targets")
for (target, header) in sort(collect(target_loop))
    println("  inner_target=$target → inside loop (header=$header, latch=$(loop_latches[header]))")
    println("    Condition: target($target) > header($header) && target($target) <= latch($(loop_latches[header]))")
    println("    → $(target > header) && $(target <= loop_latches[header])")
end
println()

# Trace open_blocks during block processing
println("=== OPEN_BLOCKS TRACE ===")
open_blocks = copy(outer_targets)
open_loops = Int[]

for target in outer_targets
    println("  Open outer BLOCK for target=$target")
end
println("  Initial open_blocks = $open_blocks")
println()

for (block_idx, block) in enumerate(blocks)
    # Close any blocks whose target is this block
    closed = Int[]
    while !isempty(open_blocks) && last(open_blocks) == block_idx
        t = pop!(open_blocks)
        push!(closed, t)
    end
    if !isempty(closed)
        for t in closed
            println("  Block $block_idx: CLOSE outer BLOCK for target=$t")
        end
    end

    # Check if loop header
    if block_idx in loop_headers
        println("  Block $block_idx: OPEN LOOP (header=$block_idx)")
        push!(open_loops, block_idx)

        if haskey(loop_inner_targets, block_idx)
            for t in loop_inner_targets[block_idx]
                println("  Block $block_idx: OPEN inner BLOCK for target=$t (inside loop $block_idx)")
                push!(open_blocks, t)
            end
        end
    end

    println("  Block $block_idx: open_blocks=$open_blocks, open_loops=$open_loops")

    # Show what br depth would be emitted for terminators
    term = block.terminator
    if term isa Core.GotoIfNot
        dest_block = get(stmt_to_block, term.dest, nothing)
        if dest_block !== nothing && dest_block > block_idx && dest_block in non_trivial_targets
            # Compute depth
            depth = 0
            for (i, t) in enumerate(reverse(open_blocks))
                if t == dest_block
                    if haskey(target_loop, dest_block)
                        parent_header = target_loop[dest_block]
                        inner_loop_count = count(lh -> lh > parent_header, open_loops)
                        depth = i - 1 + inner_loop_count
                    else
                        depth = i - 1 + length(open_loops)
                    end
                    break
                end
            end
            if !any(t == dest_block for t in open_blocks)
                println("  *** GotoIfNot to $dest_block: TARGET NOT IN open_blocks! br 0 fallback")
            else
                println("  GotoIfNot to $dest_block: br depth=$depth (from inside open_loops=$(open_loops))")
            end
        end
    elseif term isa Core.GotoNode
        dest_block = get(stmt_to_block, term.label, nothing)
        if dest_block !== nothing && dest_block > block_idx && dest_block in non_trivial_targets
            if !any(t == dest_block for t in open_blocks)
                println("  *** GotoNode to $dest_block: TARGET NOT IN open_blocks! br 0 fallback")
            else
                depth = 0
                for (i, t) in enumerate(reverse(open_blocks))
                    if t == dest_block
                        if haskey(target_loop, dest_block)
                            parent_header = target_loop[dest_block]
                            inner_loop_count = count(lh -> lh > parent_header, open_loops)
                            depth = i - 1 + inner_loop_count
                        else
                            depth = i - 1 + length(open_loops)
                        end
                        break
                    end
                end
                println("  GotoNode to $dest_block: br depth=$depth")
            end
        elseif dest_block !== nothing && dest_block <= block_idx && dest_block in loop_headers
            depth = 0
            for (i, h) in enumerate(reverse(open_loops))
                if h == dest_block
                    depth = i - 1
                    break
                end
            end
            println("  GotoNode back-edge to $dest_block: br depth=$depth (loop)")
        end
    end

    # Close loop if this is the back-edge source
    for (src, dst) in back_edges
        if src == block_idx
            if haskey(loop_inner_targets, dst)
                for target in loop_inner_targets[dst]
                    if target in open_blocks
                        filter!(t -> t != target, open_blocks)
                        println("  Block $block_idx: CLOSE inner BLOCK for target=$target (loop $dst ends)")
                    end
                end
            end
            println("  Block $block_idx: CLOSE LOOP (header=$dst)")
            filter!(h -> h != dst, open_loops)
        end
    end
end

println()
println("Final open_blocks: $open_blocks")
println("Final open_loops: $open_loops")
println()
println("=== SUMMARY ===")
println("If any 'TARGET NOT IN open_blocks' appears above, that's the br=0 bug.")
println("The fix: ensure target block is in open_blocks when its br is emitted.")
