# LLVM's LoopInfo, ported (src/llvm/generic_loop_info.jl, generic_loop_info_impl.jl; dev/LEDGER.md
# D42), over the machine code of Julia functions (src/julia/machine.jl): each loop is the natural loop
# dev/formal/CFGStackify.tla's BodyOf states, its header and every block reaching a back edge's
# source without passing the header, and a block's innermost loop is the smallest holding it.
using Test
using WasmTarget

const W = WasmTarget
const L = WasmTarget.LLVM

module LoopCases
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
end

# the body's statements Julia's optimizer leaves, in NIR, and Julia's CFG of them (nir_code), the
# input machine_function reads
nir_of(f, types) = (ci = Base.code_typed(f, types; optimize = true)[1][1]; W.nir_code(ci.code, ci.ssaflags, "llvm_loop_info"))

# the natural loop of `h` (CFGStackify.tla's BodyOf): h and the blocks reaching a predecessor h
# dominates without passing h
function natural_loop(mf, h)
    local latches = [p for p in mf.blocks[h].preds if Core.Compiler.dominates(mf.domtree, h, p)]
    isempty(latches) && return Set{Int}()
    local body = Set{Int}([h])
    local work = [p for p in latches if p != h]
    while !isempty(work)
        local b = pop!(work)
        b in body && continue
        push!(body, b)
        append!(work, mf.blocks[b].preds)
    end
    return body
end

function check_loops(f, types)
    local mf = W.machine_function(nir_of(f, types)..., "llvm_loop_info")
    local li = L.LoopInfoBase()
    L.analyze(li, mf)
    local all_loops = L.LoopBase[]
    local walk(l) = (push!(all_loops, l); foreach(walk, l.sub_loops))
    foreach(walk, li.top_level_loops)
    local headers = [b for b in mf.layout if !isempty(natural_loop(mf, b))]
    @test sort([L.get_header(l) for l in all_loops]) == sort(headers)
    for l in all_loops
        local h = L.get_header(l)
        @test l.dense_block_set == natural_loop(mf, h)
        @test Set(L.blocks(l)) == l.dense_block_set && L.get_num_blocks(l) == length(l.dense_block_set)
        local p = L.get_parent_loop(l)
        p === nothing || @test issubset(l.dense_block_set, p.dense_block_set) && l in p.sub_loops
    end
    for b in mf.layout
        local holding = [l for l in all_loops if L.contains(l, b)]
        local inner = L.get_loop_for(li, b)
        if isempty(holding)
            @test inner === nothing
        else
            @test inner !== nothing && all(l -> issubset(inner.dense_block_set, l.dense_block_set), holding)
        end
    end
    return length(all_loops)
end

@testset "machine code over Julia's CFG" begin
    local mf = W.machine_function(nir_of(LoopCases.forever, ())..., "forever")
    # codegen's top block before Julia's first, which has a predecessor here
    @test mf.blocks[1].succs == [2] && 1 in mf.blocks[2].preds && length(mf.blocks[2].preds) == 2
    @test mf.layout[1] == 1
    local mfb = W.machine_function(nir_of(LoopCases.branch, (Int,))..., "branch")
    local brs = [i for b in mfb.layout for i in mfb.blocks[b].instrs if i.opcode == W.BR_UNLESS]
    @test length(brs) == 1
    # a try region: the call %2, under %1's handler, may throw (no flag proves otherwise here), so the
    # catch block %5 is an EH pad its block unwinds to; the stackifier places its try_table, with no
    # unwind mismatch
    local enter = Any[Core.EnterNode(5), Expr(:call, GlobalRef(Base, :identity), 1), Expr(:leave, Core.SSAValue(1)),
                      Core.ReturnNode(1), Core.ReturnNode(2)]
    local mft = W.machine_function(W.nir_code(enter, zeros(UInt32, length(enter)), "try")..., "try")
    @test mft.blocks[5].ehpad && mft.blocks[5].preds == [3] && !mft.blocks[2].ehpad && mft.blocks[5].instrs[1].opcode == W.CATCH
    local mfe = L.add_pre_emit_pass(W.nir_code(enter, zeros(UInt32, length(enter)), "try")..., "try", true)
    @test count(mi -> mi.opcode == W.TRY_TABLE, [mi for b in mfe.layout for mi in mfe.blocks[b].instrs]) == 1
end

@testset "natural loops, LoopInfoBase::analyze" begin
    @test check_loops(LoopCases.straight, (Int,)) == 0
    @test check_loops(LoopCases.branch, (Int,)) == 0
    @test check_loops(LoopCases.whileloop, (Int,)) == 1
    @test check_loops(LoopCases.nested, (Int,)) >= 2
    @test check_loops(LoopCases.breaks, (Int,)) == 1
    @test check_loops(LoopCases.forever, ()) == 1
    @test check_loops(LoopCases.gotos, (Int,)) >= 1
end
