# LLVM's CFGSort, ported (src/llvm/cfg_sort.jl; dev/LEDGER.md D42), over the machine code of Julia
# functions: the claims dev/formal/CFGStackify.tla checks of the sort, EveryBlockOnce, Topological
# and LoopsContiguous, and each block's branches (maybeUpdateTerminator) reaching exactly its CFG
# successors, one by the fallthrough to the next block in the layout.
using Test
using WasmTarget

const W = WasmTarget
const L = WasmTarget.LLVM

module SortCases
straight(x::Int) = x + 1
branch(x::Int) = x > 0 ? x : -x
whileloop(x::Int) = (while x > 0; x -= 3; end; x)
function nested(n::Int)
    s = 0
    for i in 1:n, j in 1:i
        s += i * j
    end
    s
end
function breaks(n::Int)
    s = 0
    i = 0
    while true
        i += 1
        i > n && break
        isodd(i) && continue
        s += i
    end
    s
end
forever() = while true end
function gotos(x::Int)
    @label top
    x -= 1
    x > 10 && @goto top
    x > 0 && @goto top
    return x
end
function early(x::Int, y::Int)
    x < 0 && return 0
    for i in 1:y
        i > x && return i
    end
    y
end
function diamonds(a::Int, b::Int)
    r = a > b ? a - b : b - a
    r += a > 0 ? 1 : 2
    r > 5 ? r : -r
end
end

# the body's statements Julia's optimizer leaves, in NIR, and Julia's CFG of them (nir_code)
nir_of(f, types) = W.nir_code(Base.code_typed(f, types; optimize = true)[1][1].code, "llvm_cfg_sort")

# the block every outcome of b's branches reaches: its BR, BR_IF and BR_UNLESS targets, and the next
# block in the layout when its last instruction is no BR
function reached(mf, b)
    local out = Set{Int}()
    local barrier = false
    for mi in mf.blocks[b].instrs
        W.is_terminator(mi) || continue
        push!(out, (mi.operands[1]::W.MOBlock).mbb)
        barrier = mi.opcode == W.BR
    end
    local i = findfirst(==(b), mf.layout)
    if !barrier && !isempty(mf.blocks[b].succs)
        i < length(mf.layout) && push!(out, mf.layout[i + 1])
    end
    return out
end

function check_sort(f, types)
    local mf = W.machine_function(nir_of(f, types)..., "llvm_cfg_sort")
    local reachable = sort(copy(mf.layout))
    local li = L.LoopInfoBase()
    L.analyze(li, mf)
    L.sort_blocks(mf, li, L.WebAssemblyExceptionInfo())
    local num(b) = mf.blocks[b].number
    # EveryBlockOnce: the layout is a permutation of the reachable blocks, the entry first
    @test sort(copy(mf.layout)) == reachable && mf.layout[1] == 1
    @test [num(b) for b in mf.layout] == collect(1:length(mf.layout))
    local loops = L.LoopBase[]
    local walk(l) = (push!(loops, l); foreach(walk, l.sub_loops))
    foreach(walk, li.top_level_loops)
    # Topological: every predecessor above its block, a loop header's back edges aside
    for b in mf.layout, p in mf.blocks[b].preds
        local l = L.get_loop_for(li, b)
        (l !== nothing && L.get_header(l) == b && L.contains(l, p)) || @test num(p) < num(b)
    end
    # LoopsContiguous: every block between a loop's header and its bottom is dominated by the header
    for l in loops
        local h = L.get_header(l)
        local bottom = maximum(num, L.blocks(l))
        for i in num(h):bottom
            @test Core.Compiler.dominates(mf.domtree, h, mf.layout[i])
        end
    end
    # the branches reach exactly the successors
    for b in mf.layout
        @test reached(mf, b) == Set(mf.blocks[b].succs)
    end
    return mf
end

@testset "CFGSort, sortBlocks" begin
    for (f, types) in [(SortCases.straight, (Int,)), (SortCases.branch, (Int,)), (SortCases.whileloop, (Int,)),
                       (SortCases.nested, (Int,)), (SortCases.breaks, (Int,)), (SortCases.forever, ()),
                       (SortCases.gotos, (Int,)), (SortCases.early, (Int, Int)), (SortCases.diamonds, (Int, Int))]
        @testset "$f" begin check_sort(f, types) end
    end
end

@testset "updateTerminator, WebAssemblyInstrInfo's branch analysis" begin
    local mf = W.machine_function(nir_of(SortCases.branch, (Int,))..., "branch")
    local b = only(b for b in mf.layout if any(i -> i.opcode == W.BR_UNLESS, mf.blocks[b].instrs))
    local failed, tbb, fbb, cond = L.analyze_branch(mf, b)
    @test !failed && tbb !== nothing && fbb === nothing && (cond[1]::W.MOImm).imm == 0
    # the jump's target made the layout successor: the condition reverses, the branch goes to the other
    local other = only(s for s in mf.blocks[b].succs if s != tbb)
    L.move_after(mf, tbb, b)
    L.update_terminator(mf, b, other)
    local t = only(i for i in mf.blocks[b].instrs if W.is_terminator(i))
    @test t.opcode == W.BR_IF && (t.operands[1]::W.MOBlock).mbb == other
    @test L.reverse_branch_condition(W.MachineOperand[W.MOImm(1), W.MOImm(7)]) == false
end
