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
# loops entered at two blocks: irreducible
function irreducible2(x::Int, y::Int)
    y > 0 && @goto c
    x > 0 && @goto b
    @label a
    x += 1
    @label b
    x -= 2
    @label c
    y -= 1
    x > 5 && @goto a
    y > 3 && @goto b
    return x + y
end
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

# the body's statements Julia's optimizer leaves, in NIR, and Julia's CFG of them (nir_code)
nir_of(f, types) = (ci = Base.code_typed(f, types; optimize = true)[1][1]; W.nir_code(ci.code, ci.ssaflags, "llvm_cfg_stackify"))

# the machine code of `f`, analyzed, sorted and stackified (addPreEmitPass's order)
function stackified(f, types)
    local stmts, jcfg, handlers = nir_of(f, types)
    local mf = W.machine_function(stmts, jcfg, handlers, "llvm_cfg_stackify")
    L.run_on_machine_function(L.WebAssemblyFixIrreducibleControlFlow(), mf)
    local li = L.LoopInfoBase()
    L.analyze(li, mf)
    local wei = L.WebAssemblyExceptionInfo()
    L.run_on_machine_function(wei, mf)
    L.sort_blocks(mf, li, wei)
    local pass = L.WebAssemblyCFGStackify()
    L.run_on_machine_function(pass, mf, li, wei, true)
    return stmts, jcfg, mf, pass
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

# the block whose code comes first from instruction j on, markers skipped; nothing past the end or at
# a branch
function next_body(prog, j)
    while j <= length(prog)
        local mi = prog[j][2]
        mi.opcode in (W.STMTS, W.CONST_I32, W.BR_TABLE) && return prog[j][1]
        mi.opcode in (W.BLOCK, W.LOOP, W.END_BLOCK, W.END_LOOP) || return nothing
        j += 1
    end
    return nothing
end

# the Julia block control reaches from block b on, FixIrreducibleControlFlow's blocks run by their
# label registers: a routing block's CONST_I32 sets its register and its BR or fallthrough goes on,
# a dispatch's BR_TABLE jumps to the register's target; nothing for a register read unset
function run_to_julia(prog, pass, b, regs = Dict{Int,Int}(), steps = 64)
    while steps > 0
        b === nothing && return nothing
        local ks = [k for k in eachindex(prog) if prog[k][1] == b]
        local first_ = prog[ks[findfirst(k -> prog[k][2].opcode in (W.STMTS, W.CONST_I32, W.BR_TABLE), ks)]][2]
        first_.opcode == W.STMTS && return b
        local next = nothing
        for k in ks
            local mi = prog[k][2]
            if mi.opcode == W.CONST_I32
                regs[(mi.operands[1]::W.MOImm).imm] = (mi.operands[2]::W.MOImm).imm
            elseif mi.opcode == W.BR
                next = branch_land(prog, pass, k, (mi.operands[1]::W.MOImm).imm)
                break
            elseif mi.opcode == W.BR_TABLE
                local r = get(regs, (mi.operands[1]::W.MOImm).imm, nothing)
                r === nothing && return nothing
                next = branch_land(prog, pass, k, (mi.operands[2 + r]::W.MOImm).imm)
                break
            end
        end
        # no branch: on to the next block in the layout (a BR to it CFGSort made a fallthrough)
        b = next === nothing ? next_body(prog, maximum(ks) + 1) : next
        steps -= 1
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
    local stmts, jcfg, mf, pass = stackified(f, types)
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
    @test run_to_julia(prog, pass, next_body(prog, 1)) == 2
    # every outcome of every Julia terminator: Julia's block k is machine block k + 1
    for b in mf.layout
        (b == 1 || b > length(jcfg.blocks) + 1) && continue
        local jterm = stmts[last(jcfg.blocks[b - 1].stmts)]
        # Julia's outcomes, each with the machine block it reaches; a return has none
        local blk(stmt) = Core.Compiler.block_for_inst(jcfg, stmt) + 1
        local outcomes = jterm isa W.NirGoto ? [(:always, blk(jterm.label))] :
            jterm isa W.NirGotoIfNot ? [(:false, blk(jterm.dest)), (:true, b + 1)] :
            jterm isa Union{W.NirReturn, W.NirUnreachable} ? Tuple{Symbol,Int}[] : [(:always, b + 1)]
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
                    # BranchTargetsEnclosingLabel and DepthCorrect: the label names the branch's
                    # target, the routing block FixIrreducibleControlFlow put on the way, if any
                    local open = open_at(prog, k)
                    @test d < length(open) && run_to_julia(prog, pass, label_block(pass, open[end - d])) == want
                    land = run_to_julia(prog, pass, branch_land(prog, pass, k, d))
                    done = true
                    break
                end
            end
            done || (land = run_to_julia(prog, pass, next_body(prog, lastk + 1)))
            @test land == want
        end
    end
    return mf
end

@testset "CFGStackify, placeMarkers and rewriteDepthImmediates" begin
    for (f, types) in [(StackifyCases.straight, (Int,)), (StackifyCases.branch, (Int,)), (StackifyCases.whileloop, (Int,)),
                       (StackifyCases.nested, (Int,)), (StackifyCases.breaks, (Int,)), (StackifyCases.forever, ()),
                       (StackifyCases.gotos, (Int,)), (StackifyCases.early, (Int, Int)), (StackifyCases.diamonds, (Int, Int)),
                       (StackifyCases.labeled, (Int,)), (StackifyCases.irreducible, (Int,)), (StackifyCases.irreducible2, (Int, Int))]
        @testset "$f" begin check_stackify(f, types) end
    end
end

@testset "addPreEmitPass's order; FixIrreducibleControlFlow" begin
    local mf = L.add_pre_emit_pass(nir_of(StackifyCases.whileloop, (Int,))..., "whileloop", true)
    @test count(i -> i.opcode == W.LOOP, (i for b in mf.layout for i in mf.blocks[b].instrs)) == 1
    @test !mf.implicit_defs
    # an @goto-made loop with two entries gets a dispatch block, a BR_TABLE over its entries
    local mfi = L.add_pre_emit_pass(nir_of(StackifyCases.irreducible, (Int,))..., "irreducible", true)
    @test mfi.implicit_defs && mfi.label_registers == 1
    @test count(i -> i.opcode == W.BR_TABLE, (i for b in mfi.layout for i in mfi.blocks[b].instrs)) == 1
    # a reducible CFG is left as it was
    local mfg = W.machine_function(nir_of(StackifyCases.gotos, (Int,))..., "gotos")
    @test !L.run_on_machine_function(L.WebAssemblyFixIrreducibleControlFlow(), mfg)
end
