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
