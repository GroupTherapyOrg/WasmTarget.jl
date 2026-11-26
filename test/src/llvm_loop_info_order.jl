# The order of LLVM's LoopInfoBase::analyze, ported (src/llvm/generic_loop_info_impl.jl): at the llvm
# pin (llvm/include/llvm/Support/GenericLoopInfoImpl.h:578) it visits the dominator tree in reverse
# preorder (updateDFSNumbers' DFSNumIn) and fills each loop's vectors in one forward postorder of the
# CFG (PopulateLoopsDFS, :532-:563), as the port does; the order of a node's children is Julia's
# construct_domtree's, and a block's predecessors Julia's CFG's, not LLVM's SemiNCA's or
# MachineBasicBlock's. Over a family of CFGs (nested, sibling, self, multiple latches, irreducible
# before and after FixIrreducibleControlFlow, and seeded random ones) the tree equals the one LLVM's
# definitions specify (each loop the natural loop of its back edges, each block in its innermost
# loop, a loop's blocks its header then the rest in reverse postorder, its subloops in reverse
# postorder of their headers, the top-level loops in postorder), and every order of each node's
# children and each block's predecessors gives that same tree.
using Test
using Random
using WasmTarget

const W = WasmTarget
const L = WasmTarget.LLVM

module LoopOrderCases
function nested(n::Int)
    s = 0
    for i in 1:n, j in 1:i, k in 1:j
        s += i * j - k
    end
    s
end
function siblings(n::Int)
    s = 0
    for i in 1:n
        s += i
    end
    for j in 1:n
        s -= 2j
    end
    i = n
    while i > 0
        i -= 3
        s += i
    end
    s
end
function latches(n::Int)
    s = 0
    i = 0
    while true
        i += 1
        i > n && break
        isodd(i) && continue
        i % 3 == 0 && continue
        s += i
    end
    s
end
# two entries into one cycle, a and b: irreducible until FixIrreducibleControlFlow
function irreducible(x::Int, y::Bool)
    y && @goto b
    @label a
    x -= 1
    x > 7 && return x
    @label b
    x -= 2
    x > 0 && @goto a
    return x
end
end

# a machine function of the bare CFG `succs` (block 1 the entry, no edge into it), as analyze reads
# one: blocks' edges and Julia's dominator tree of them
function mf_of(succs::Vector{Vector{Int}}, preds::Vector{Vector{Int}})
    local n = length(succs)
    local bbs = [Core.Compiler.BasicBlock(Core.Compiler.StmtRange(0, -1), copy(preds[b]), copy(succs[b])) for b in 1:n]
    local blocks = [W.MachineBasicBlock(b, copy(preds[b]), copy(succs[b]), W.MachineInstr[], false) for b in 1:n]
    return W.MachineFunction(Core.Compiler.construct_domtree(bbs), W.NirStmt[], blocks, collect(1:n), 0,
                             W.NirHandlers(Int[], Int[], falses(0)))
end
function preds_of(succs::Vector{Vector{Int}})
    local preds = [Int[] for _ in succs]
    for b in eachindex(succs), s in succs[b]
        push!(preds[s], b)
    end
    return preds
end

# the tree as a consumer can read it: each block's innermost loop (by header, 0 for none), each loop's
# blocks and subloops in order and its parent, the top-level loops in order
function tree_of(li::L.LoopInfoBase, n::Int)
    local hdr(l) = l === nothing ? 0 : L.get_header(l)
    local loops = Any[]
    local walk(l) = (push!(loops, (L.get_header(l), copy(L.blocks(l)), map(hdr, l.sub_loops), hdr(L.get_parent_loop(l)))); foreach(walk, l.sub_loops))
    foreach(walk, li.top_level_loops)
    return (inner = [hdr(L.get_loop_for(li, b)) for b in 1:n], loops = sort(loops), top = map(hdr, li.top_level_loops))
end
function analyzed(mf)
    local li = L.LoopInfoBase()
    L.analyze(li, mf)
    return tree_of(li, length(mf.blocks))
end

# the tree LLVM's definitions specify, computed without the port: the natural loop of each header
# (a predecessor it dominates closes it), a postorder of the CFG (po_iterator: successors in order)
function reference(mf)
    local n = length(mf.blocks)
    local dt = mf.domtree
    local reach(b) = !Core.Compiler.bb_unreachable(dt, b)
    local body = Dict{Int,Set{Int}}()
    for h in 1:n
        reach(h) || continue
        local latches = [p for p in mf.blocks[h].preds if reach(p) && Core.Compiler.dominates(dt, h, p)]
        isempty(latches) && continue
        local s = Set{Int}([h])
        local work = [p for p in latches if p != h]
        while !isempty(work)
            local b = pop!(work)
            (b in s || !reach(b)) && continue
            push!(s, b)
            append!(work, mf.blocks[b].preds)
        end
        body[h] = s
    end
    local po = Int[]
    local seen = Set{Int}()
    local dfs(b) = (push!(seen, b); foreach(s -> s in seen || dfs(s), mf.blocks[b].succs); push!(po, b))
    dfs(1)
    local rpo = reverse(po)
    # the smallest loop holding b, other than `but`
    local smallest(b, but) = begin
        local best = 0
        for (h, s) in body
            h != but && b in s && (best == 0 || length(s) < length(body[best])) && (best = h)
        end
        best
    end
    local parent = Dict(h => smallest(h, h) for h in keys(body))
    local loops = Any[(h, [h; [b for b in rpo if b in body[h] && b != h]],
                       [s for s in rpo if haskey(parent, s) && parent[s] == h], parent[h]) for h in keys(body)]
    return (inner = [smallest(b, 0) for b in 1:n], loops = sort(loops), top = [h for h in po if haskey(body, h) && parent[h] == 0])
end

# every check on one CFG: the port equals the specification, and stays equal when each dominator-tree
# node's children and each block's predecessors are put in other orders
function check_order(mf, rng::AbstractRNG; shuffles::Int = 6)
    local want = reference(mf)
    @test analyzed(mf) == want
    local succs = [copy(b.succs) for b in mf.blocks]
    local preds = [copy(b.preds) for b in mf.blocks]
    for k in 1:shuffles
        local p = k == 1 ? map(reverse, preds) : map(v -> shuffle(rng, v), preds)
        local m = mf_of(succs, p)
        for node in m.domtree.nodes
            k == 1 ? reverse!(node.children) : shuffle!(rng, node.children)
        end
        @test analyzed(m) == want
    end
    return length(want.loops)
end
check_order(succs::Vector{Vector{Int}}, rng::AbstractRNG) = check_order(mf_of(succs, preds_of(succs)), rng)

nir_of(f, types) = (ci = Base.code_typed(f, types; optimize = true)[1][1]; W.nir_code(ci.code, ci.ssaflags, W.NirBindings(Base.get_world_counter()), "llvm_loop_info_order"))

@testset "LoopInfoBase::analyze's order" begin
    local rng = Xoshiro(0x6c6f6f70)
    # hand CFGs: two siblings in one outer loop (2 heads 3 and 5), a self loop, a header with
    # three latches, two loops sharing an exit, an irreducible cycle (no natural loop of it)
    @test check_order([[2], [3, 7], [4, 3], [5], [6, 5], [2], Int[]], rng) == 3
    @test check_order([[2], [2, 3], Int[]], rng) == 1
    @test check_order([[2], [3, 4], [2, 5], [2, 5], [2, 6], Int[]], rng) == 1
    @test check_order([[2], [3, 6], [2, 4], [5, 6], [4, 6], Int[]], rng) == 2
    @test check_order([[2, 3], [3], [2, 4], Int[]], rng) == 0
    # nested three deep, siblings in sequence, a loop with several latches, from Julia's CFG
    for (f, types, nloops) in ((LoopOrderCases.nested, (Int,), 3), (LoopOrderCases.siblings, (Int,), 3),
                               (LoopOrderCases.latches, (Int,), 1))
        local mf = W.machine_function(nir_of(f, types)..., "llvm_loop_info_order")
        @test check_order(mf, rng) >= nloops
    end
    # irreducible: no loop before FixIrreducibleControlFlow, one dispatch loop after it (its blocks
    # the pass's, added past Julia's)
    local stmts, jcfg, handlers = nir_of(LoopOrderCases.irreducible, (Int, Bool))
    local mf = W.machine_function(stmts, jcfg, handlers, "irreducible")
    local before = length(mf.blocks)
    L.eliminate_phi_nodes(mf, jcfg)
    @test check_order(mf, rng) == 0
    L.run_on_machine_function(L.WebAssemblyFixIrreducibleControlFlow(), mf)
    @test length(mf.blocks) > before
    @test check_order(mf, rng) >= 1
    # seeded random CFGs: 2 to 10 blocks, up to 3 distinct successors each, none to the entry
    local nloops = 0
    for _ in 1:400
        local n = rand(rng, 2:10)
        local succs = [unique([rand(rng, 2:n) for _ in 1:rand(rng, 0:3)]) for _ in 1:n]
        nloops += check_order(succs, rng)
    end
    @test nloops > 100
end
