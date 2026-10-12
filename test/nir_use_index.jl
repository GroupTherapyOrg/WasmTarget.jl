# The SSA use index (nir_ssa_users, the context's `ssa_users`) answers the use query it
# replaces: statement j is listed under SSA id exactly when nir_uses(nir[j].node, NirSSA(id))
# says j uses id, and each list is ascending. Checked over every (statement, id) pair of bodies
# whose IR has loops and phis, a try/catch (upsilon and phic nodes), pi nodes, invokes and
# foreigncalls (dev/CHARTER.md C10).
using Test
using WasmTarget

function _nui_catching(x::Int)
    y = 0
    try
        y = x > 0 ? x : error("negative")
    catch
        y = -1
    end
    return y
end

_nui_union(v::Vector{Any}) = (s = 0; for x in v; x isa Int && (s += x); end; s)

@testset "the SSA use index answers nir_uses" begin
    bodies = Any[(sum, (Vector{Float64},)), (sort!, (Vector{Int},)), (string, (Int,)),
                 (_nui_catching, (Int,)), (_nui_union, (Vector{Any},)),
                 (Base.Math.exp_impl, (Float64, Float64, Val{:ℯ}))]
    for (f, argtypes) in bodies
        ci, _ = WasmTarget.get_typed_ir(f, argtypes)
        nir = WasmTarget.nir_body(ci).stmts
        users = WasmTarget.nir_ssa_users(nir)
        n = length(nir)
        mismatches = 0
        for id in 1:n
            listed = get(users, id, Int[])
            issorted(listed) && allunique(listed) || (mismatches += 1)
            for j in 1:n
                (j in listed) == WasmTarget.nir_uses(nir[j].node, WasmTarget.NirSSA(id, Any)) ||
                    (mismatches += 1)
            end
        end
        # ids outside the body are never used
        @test all(id -> 1 <= id <= n, keys(users))
        @test mismatches == 0
        @test n > 10
    end
end

# The use count and the loop bounds read one table each (dev/AUDIT.md, the first audit's side
# notes; L180): count_ssa_uses! counts every operand the one operand table names, an upsilon's
# value included, once per position; and a loop is its header and its LAST back edge, whatever
# gotos jump to the header from before it (a forward one gave an empty range, losing the loop).
function _nui_upsilon(x::Int)
    y = x
    try
        y = x * 3
        x > 5 && error("big")
    catch
        return y
    end
    return y + 1
end
@testset "the use count and the loop bounds read one table each" begin
    ci, _ = WasmTarget.get_typed_ir(_nui_upsilon, (Int,))
    nir = WasmTarget.nir_body(ci).stmts
    uses = Dict{Int,Int}()
    foreach(rec -> WasmTarget.count_ssa_uses!(rec, uses), nir)
    walker = Dict{Int,Int}()
    for rec in nir
        rec.node isa WasmTarget.NirSSA && (walker[rec.node.id] = get(walker, rec.node.id, 0) + 1)
        WasmTarget._nir_any_operand(x -> (x isa WasmTarget.NirSSA && (walker[x.id] = get(walker, x.id, 0) + 1); false), rec.node)
    end
    @test uses == walker
    ups = [rec.node.value.id for rec in nir if rec.node isa WasmTarget.NirUpsilon && rec.node.value isa WasmTarget.NirSSA]
    @test !isempty(ups) && all(id -> get(uses, id, 0) >= 1, ups)
    # 1: goto 3 (forward, to the header); 2: an exit test; 3: header; 4: goto 3 (back); 5: a
    # branch inside; 6: goto 3 (the last back edge); 7: return
    S(n) = WasmTarget.NirStmt(n, Any, 0)
    lit = WasmTarget.NirLiteral(true)
    synth = [S(WasmTarget.NirGoto(3)), S(WasmTarget.NirGotoIfNot(lit, 7)), S(WasmTarget.NirLiteral(0)),
             S(WasmTarget.NirGoto(3)), S(WasmTarget.NirGotoIfNot(lit, 3)), S(WasmTarget.NirGoto(3)),
             S(WasmTarget.NirReturn(nothing))]
    @test WasmTarget.loop_bounds(synth) == [(3, 6)]
end
