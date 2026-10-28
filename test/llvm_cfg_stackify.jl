# LLVM's CFGStackify, ported (src/llvm/cfg_stackify.jl; dev/LEDGER.md D42), over the machine code of
# Julia functions sorted by CFGSort: the claims dev/formal/CFGStackify.tla checks of the structured
# program. WellNested: every END closes the innermost open scope. BranchTargetsEnclosingLabel and
# DepthCorrect: the label at each branch's depth is open there and names the branch's target.
# PathsPreserved (Ramsey's statement): run by wasm's semantics, the program reaches Julia's entry
# block first, and every outcome of every Julia terminator (a goto, both arms of a goto-if-not, a
# fallthrough) reaches the block Julia's IR names for it.
using Test
using WasmTarget

const W = WasmTarget
const L = WasmTarget.LLVM

module StackifyCases
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
function labeled(n::Int)
    s = 0
    for i in 1:n
        for j in 1:n
            j > i && @goto next
            s += j
        end
        @label next
        s -= 1
    end
    s
end
# a loop entered at two blocks: irreducible
function irreducible(x::Int)
    x > 0 && @goto b
    @label a
    x += 1
    @label b
    x -= 2
    x > 5 && @goto a
    return x
end
end

stmts_of(f, types) = Base.code_typed(f, types; optimize = true)[1][1].code

# the machine code of `f`, analyzed, sorted and stackified (addPreEmitPass's order)
function stackified(f, types)
    local stmts = stmts_of(f, types)
    local mf = W.machine_function(stmts, "llvm_cfg_stackify")
    isempty(W.irreducible_entries(mf)) || error("irreducible")
    local li = L.LoopInfoBase()
    L.analyze(li, mf)
    L.sort_blocks(mf, li)
    local pass = L.WebAssemblyCFGStackify()
    L.run_on_machine_function(pass, mf, li, true)
    return stmts, mf, pass
end

# the program: each instruction with its block, in layout order
flat(mf) = [(b, mi) for b in mf.layout for mi in mf.blocks[b].instrs]

# the labels open before instruction k, innermost last, as their BLOCK or LOOP instruction
function open_at(prog, k)
    local stk = W.MachineInstr[]
    for j in 1:k-1
        local mi = prog[j][2]
        mi.opcode in (W.BLOCK, W.LOOP) && push!(stk, mi)
        mi.opcode in (W.END_BLOCK, W.END_LOOP) && !isempty(stk) && pop!(stk)
    end
    return stk
end

# the Julia block (its machine number) whose statements come first from instruction j on, markers
# skipped; nothing past the end or at a branch
function next_body(prog, j)
    while j <= length(prog)
        local mi = prog[j][2]
        mi.opcode == W.STMTS && return prog[j][1]
        mi.opcode in (W.BLOCK, W.LOOP, W.END_BLOCK, W.END_LOOP) || return nothing
        j += 1
    end
    return nothing
end

# where a branch at k with depth d resumes: after its BLOCK's END, at its LOOP
function branch_land(prog, pass, k, d)
    local stk = open_at(prog, k)
    d < length(stk) || return nothing
    local label = stk[end - d]
    local target = label.opcode == W.BLOCK ? pass.begin_to_end[label] : label
    local j = findfirst(x -> x[2] === target, prog)
    return next_body(prog, j + 1)
end

# the block a label names: a BLOCK's END block, a LOOP's header
label_block(pass, label) = label.opcode == W.BLOCK ? pass.begin_to_end[label].parent : label.parent

function check_stackify(f, types)
    local stmts, mf, pass = stackified(f, types)
    local prog = flat(mf)
    # WellNested
    local stk = W.MachineInstr[]
    local nested = true
    for (_, mi) in prog
        if mi.opcode in (W.BLOCK, W.LOOP)
            push!(stk, mi)
        elseif mi.opcode in (W.END_BLOCK, W.END_LOOP)
            nested &= !isempty(stk) && pass.begin_to_end[stk[end]] === mi
            isempty(stk) || pop!(stk)
        end
    end
    @test nested && isempty(stk)
    # the entry: Julia's first block's statements come first
    @test next_body(prog, 1) == 2
    # every outcome of every Julia terminator: Julia's block k is machine block k + 1
    local jcfg = Core.Compiler.compute_basic_blocks(stmts)
    for b in mf.layout
        (b == 1 || b > length(jcfg.blocks) + 1) && continue
        local jterm = stmts[last(jcfg.blocks[b - 1].stmts)]
        # Julia's outcomes, each with the machine block it reaches; a return has none
        local blk(stmt) = Core.Compiler.block_for_inst(jcfg, stmt) + 1
        local outcomes = jterm isa Core.GotoNode ? [(:always, blk(jterm.label))] :
            jterm isa Core.GotoIfNot ? [(:false, blk(jterm.dest)), (:true, b + 1)] :
            jterm isa Core.ReturnNode ? Tuple{Symbol,Int}[] : [(:always, b + 1)]
        local ks = [k for k in eachindex(prog) if prog[k][1] == b && W.is_terminator(prog[k][2])]
        local lastk = maximum(k for k in eachindex(prog) if prog[k][1] == b)
        for (o, want) in outcomes
            local land = nothing
            local done = false
            for k in ks
                local mi = prog[k][2]
                local d = (mi.operands[1]::W.MOImm).imm
                local taken = mi.opcode == W.BR || (mi.opcode == W.BR_IF && o == :true) || (mi.opcode == W.BR_UNLESS && o == :false)
                if taken
                    # BranchTargetsEnclosingLabel and DepthCorrect
                    local open = open_at(prog, k)
                    @test d < length(open) && label_block(pass, open[end - d]) == want
                    land = branch_land(prog, pass, k, d)
                    done = true
                    break
                end
            end
            done || (land = next_body(prog, lastk + 1))
            @test land == want
        end
    end
    return mf
end

@testset "CFGStackify, placeMarkers and rewriteDepthImmediates" begin
    for (f, types) in [(StackifyCases.straight, (Int,)), (StackifyCases.branch, (Int,)), (StackifyCases.whileloop, (Int,)),
                       (StackifyCases.nested, (Int,)), (StackifyCases.breaks, (Int,)), (StackifyCases.forever, ()),
                       (StackifyCases.gotos, (Int,)), (StackifyCases.early, (Int, Int)), (StackifyCases.diamonds, (Int, Int)),
                       (StackifyCases.labeled, (Int,))]
        @testset "$f" begin check_stackify(f, types) end
    end
end

@testset "addPreEmitPass's order; an irreducible loop rejects until FixIrreducibleControlFlow" begin
    local mf = L.add_pre_emit_pass(stmts_of(StackifyCases.whileloop, (Int,)), "whileloop", true)
    @test count(i -> i.opcode == W.LOOP, (i for b in mf.layout for i in mf.blocks[b].instrs)) == 1
    local err = try; L.add_pre_emit_pass(stmts_of(StackifyCases.irreducible, (Int,)), "irreducible", true); nothing; catch e; e; end
    @test err isa W.RejectionError && err.rejection isa W.Unported && occursin("FixIrreducibleControlFlow", err.rejection.anchor)
    @test isempty(W.irreducible_entries(W.machine_function(stmts_of(StackifyCases.gotos, (Int,)), "gotos")))
end
