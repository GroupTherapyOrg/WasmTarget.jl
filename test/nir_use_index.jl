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
    @test WasmTarget.loop_bounds(WasmTarget.nir_cfg(synth)) == [(3, 6)]
    # a loop whose only back edge is a goto-if-not: 1: entry; 2: header; 3: goto 2 if not (back); 4: return
    synth2 = [S(WasmTarget.NirLiteral(0)), S(WasmTarget.NirLiteral(1)), S(WasmTarget.NirGotoIfNot(lit, 2)),
              S(WasmTarget.NirReturn(nothing))]
    @test WasmTarget.loop_bounds(WasmTarget.nir_cfg(synth2)) == [(2, 3)]
end

# The one CFG is Julia's own (L181): nir_cfg's blocks and edges equal Compiler's
# compute_basic_blocks over the same statements, for bodies with loops, phis, a try/catch (an
# Enter's catch edge, a :leave ending its block), invokes and foreigncalls
@testset "nir_cfg is Julia's compute_basic_blocks" begin
    bodies = Any[(sum, (Vector{Float64},)), (sort!, (Vector{Int},)), (string, (Int,)),
                 (_nui_catching, (Int,)), (_nui_union, (Vector{Any},)), (_nui_upsilon, (Int,)),
                 (Base.Math.exp_impl, (Float64, Float64, Val{:ℯ}))]
    local tries = 0
    for (f, argtypes) in bodies
        ci, _ = WasmTarget.get_typed_ir(f, argtypes)
        nir = WasmTarget.nir_body(ci).stmts
        any(rec -> rec.node isa WasmTarget.NirEnter, nir) && (tries += 1)
        cfg = WasmTarget.nir_cfg(nir)
        jc = Core.Compiler.compute_basic_blocks(ci.code)
        @test [b.start_idx for b in cfg.blocks] == [first(b.stmts) for b in jc.blocks]
        @test [b.end_idx for b in cfg.blocks] == [last(b.stmts) for b in jc.blocks]
        @test [Set(s) for s in cfg.succs] == [Set(b.succs) for b in jc.blocks]
        @test [Set(p) for p in cfg.preds] == [Set(filter(!=(0), b.preds)) for b in jc.blocks]
    end
    @test tries >= 2
    # trailing `nothing` statements lie in no block (ir.jl:84): the last block ends at the last
    # statement that is not `nothing`
    S(n) = WasmTarget.NirStmt(n, Any, 0)
    code = Any[Core.GotoIfNot(Core.Argument(2), 3), Core.ReturnNode(1), Core.ReturnNode(2), nothing, nothing]
    nir = [S(WasmTarget.NirGotoIfNot(WasmTarget.NirArgument(2), 3)), S(WasmTarget.NirReturn(WasmTarget.NirLiteral(1))),
           S(WasmTarget.NirReturn(WasmTarget.NirLiteral(2))), S(WasmTarget.NirLiteral(nothing)), S(WasmTarget.NirLiteral(nothing))]
    cfg = WasmTarget.nir_cfg(nir)
    jc = Core.Compiler.compute_basic_blocks(code)
    @test [(b.start_idx, b.end_idx) for b in cfg.blocks] == [(first(b.stmts), last(b.stmts)) for b in jc.blocks] == [(1, 1), (2, 2), (3, 3)]
    @test cfg.block_of == [1, 2, 3, 0, 0]
end

# The proven-dead proof reads the one CFG (L181): a handler is reached through its Enter's catch
# edge, and a body with a try is no longer excluded, so a statement after an `unreachable` inside
# the try body is proven dead
@testset "the proven-dead proof sees a try body through the one CFG" begin
    S(n) = WasmTarget.NirStmt(n, Any, 0)
    # 1: enter, catch at 5; 2: the try body; 3: unreachable; 4: after it, in the try body;
    # 5: the handler's first statement; 6: return
    nir = [S(WasmTarget.NirEnter(5)), S(WasmTarget.NirLiteral(0)), S(WasmTarget.NirReturn(nothing)),
           S(WasmTarget.NirLiteral(1)), S(WasmTarget.NirLiteral(2)), S(WasmTarget.NirReturn(WasmTarget.NirLiteral(0)))]
    cfg = WasmTarget.nir_cfg(nir)
    @test !WasmTarget.stmt_is_proven_unreachable(cfg, 5)
    @test WasmTarget.stmt_is_proven_unreachable(cfg, 4)
    @test !WasmTarget.stmt_is_proven_unreachable(cfg, 2)
    # a compiled body's handler
    ci, _ = WasmTarget.get_typed_ir(_nui_catching, (Int,))
    body = WasmTarget.nir_body(ci).stmts
    enters = [rec.node for rec in body if rec.node isa WasmTarget.NirEnter]
    @test !isempty(enters)
    @test !any(e -> WasmTarget.stmt_is_proven_unreachable(WasmTarget.nir_cfg(body), e.catch_target), enters)
end

# A call's constant callee has one representation, its object (L182): an intrinsic the IR embeds
# as the object, a type object an :invoke embeds, a function a singleton-typed argument names; a
# constant holding captures carries its self; a NirLiteral callee is refused at construction
@noinline _nui_apply(f, x) = f(x)
@noinline _nui_neg(x::Int64) = -x
@noinline _nui_tsin(x::Float64) = sin(x) + 1
_nui_tupcall(t::Tuple{typeof(_nui_tsin)}, x::Float64) = t[1](x)
struct _NuiP; a::Int64; @noinline _NuiP(a::Int64) = new(a + 1); end
_nui_mkp(x::Int64) = _NuiP(x)
const _NUI_CLO = let a = 3; @noinline (x::Int64) -> x * a; end
_nui_clo(x::Int64) = _NUI_CLO(x)
@testset "a call's constant callee has one representation" begin
    callees(f, argtypes) = [rec.node for rec in WasmTarget.nir_body(first(WasmTarget.get_typed_ir(f, argtypes))).stmts
                            if rec.node isa Union{WasmTarget.NirCall,WasmTarget.NirInvoke}]
    all_callees = Any[]
    for (f, argtypes) in ((expm1, (Float64,)), (Dict{Int64,Int64}, ()), (_nui_apply, (typeof(_nui_neg), Int64)), (_nui_clo, (Int64,)))
        append!(all_callees, callees(f, argtypes))
    end
    @test !any(n -> n.callee isa WasmTarget.NirLiteral, all_callees)
    @test any(n -> n.callee === Core.Intrinsics.have_fma, callees(expm1, (Float64,)))
    @test any(n -> n isa WasmTarget.NirInvoke && n.callee === _nui_neg, callees(_nui_apply, (typeof(_nui_neg), Int64)))
    clo = [n for n in callees(_nui_clo, (Int64,)) if n isa WasmTarget.NirInvoke && n.callee === _NUI_CLO]
    @test length(clo) == 1 && clo[1].self isa WasmTarget.NirLiteral && clo[1].self.value === _NUI_CLO
    @test all(n -> n.self === nothing, callees(expm1, (Float64,)))
    # a type object (a constructor's callee) carries no self
    ctor = [n for n in callees(_nui_mkp, (Int64,)) if n isa WasmTarget.NirInvoke && n.callee === _NuiP]
    @test length(ctor) == 1 && ctor[1].self === nothing
    @test_throws ArgumentError WasmTarget.NirCall(WasmTarget.NirLiteral(Core.Intrinsics.add_int), WasmTarget.NirNode[])
    # an SSA callee whose widened type is a singleton function type (no Core.Const) is that
    # function, by the one operand rule: Julia's unoptimized `%1 = getindex(t, 1); (%1)(x)`, its
    # %1 typed `typeof(_nui_tsin)` rather than the Const inference gave it
    uci = copy(first(code_typed(_nui_tupcall, (Tuple{typeof(_nui_tsin)}, Float64); optimize=false))[1])
    uci.ssavaluetypes = Any[uci.ssavaluetypes...]; uci.ssavaluetypes[1] = typeof(_nui_tsin)
    calls = [rec.node for rec in WasmTarget.build_nir(uci) if rec.node isa WasmTarget.NirCall]
    @test any(n -> n.callee === _nui_tsin, calls)
end
