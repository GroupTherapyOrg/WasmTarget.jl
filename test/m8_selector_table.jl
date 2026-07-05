# census F5 (march5): the M8.1 SelectorInfo-transcription unit test is DELETED with
# its subject — the transcription was dead production code (zero callers; the live
# packer is pack_dispatch_selectors!, covered end-to-end by the M8.2 testset below).

# M8.2: the dart virtual call end-to-end — classId + offset + call_indirect through
# the ONE flat table, replacing the FNV probe for single-axis selectors.
module M8DispatchE2E
struct E1 x::Int32 end; struct E2 x::Int32 end; struct E3 x::Int32 end
struct E4 x::Int32 end; struct E5 x::Int32 end; struct E6 x::Int32 end
struct E7 x::Int32 end; struct E8 x::Int32 end; struct E9 x::Int32 end
struct E10 x::Int32 end
dv(s::E1) = Int32(1); dv(s::E2) = Int32(2); dv(s::E3) = Int32(3)
dv(s::E4) = Int32(4); dv(s::E5) = Int32(5); dv(s::E6) = Int32(6)
dv(s::E7) = Int32(7); dv(s::E8) = Int32(8); dv(s::E9) = Int32(9)
dv(s::E10) = Int32(10)
caller(x::Any)::Int32 = dv(x)
mk1(v::Int32) = E1(v); mk3(v::Int32) = E3(v); mk10(v::Int32) = E10(v)
end
@testset "M8.2 dart virtual call (classId+offset through the ONE table)" begin
    M = M8DispatchE2E
    fns = [(M.dv,(M.E1,)),(M.dv,(M.E2,)),(M.dv,(M.E3,)),(M.dv,(M.E4,)),(M.dv,(M.E5,)),
           (M.dv,(M.E6,)),(M.dv,(M.E7,)),(M.dv,(M.E8,)),(M.dv,(M.E9,)),(M.dv,(M.E10,)),
           (M.caller,(Any,)),(M.mk1,(Int32,)),(M.mk3,(Int32,)),(M.mk10,(Int32,))]
    bytes = WasmTarget.compile_multi(fns)
    @test !isempty(bytes)
    # the routing PROOF: the selector bridge engaged for dv (single-axis, 10 targets)
    bytes2, treg, freg, dreg = WasmTarget.compile_multi(fns; return_registries=true)
    @test haskey(dreg.selector_offset, M.dv)
    @test dreg.selector_table_idx !== nothing
    @test dreg.selector_table_len >= 10
    if success(`which node`)
        p = joinpath(mktempdir(), "m82.wasm"); write(p, bytes)
        js = """
        import fs from 'fs';
        const b = fs.readFileSync('$(escape_string(p))');
        const m = await WebAssembly.instantiate(b, { Math: { pow: Math.pow } });
        const e = m.instance.exports;
        console.log(JSON.stringify([e.caller(e.mk1(0)), e.caller(e.mk3(0)), e.caller(e.mk10(0))]));
        """
        jp = joinpath(dirname(p), "m82.mjs"); write(jp, js)
        out = strip(read(`node $jp`, String))
        @test out == "[1,3,10]"
    end
end

# M8.3: the multi-axis CASCADE — Julia 2-axis dispatch as composed dart hops
# (axis-1 classId → trampoline → axis-2 classId), all in the SAME one table.
module M8Cascade
struct P1 x::Int32 end; struct P2 x::Int32 end; struct P3 x::Int32 end
struct P4 x::Int32 end; struct P5 x::Int32 end
struct Qa x::Int32 end; struct Qb x::Int32 end
combo(p::P1,q::Qa)=Int32(11); combo(p::P1,q::Qb)=Int32(12)
combo(p::P2,q::Qa)=Int32(21); combo(p::P2,q::Qb)=Int32(22)
combo(p::P3,q::Qa)=Int32(31); combo(p::P3,q::Qb)=Int32(32)
combo(p::P4,q::Qa)=Int32(41); combo(p::P4,q::Qb)=Int32(42)
combo(p::P5,q::Qa)=Int32(51); combo(p::P5,q::Qb)=Int32(52)
caller2(x::Any, y::Any)::Int32 = combo(x, y)
mkp2(v::Int32)=P2(v); mkp5(v::Int32)=P5(v); mka(v::Int32)=Qa(v); mkb(v::Int32)=Qb(v)
end
@testset "M8.3 multi-axis cascade (composed dart hops, one table)" begin
    M = M8Cascade
    fns = [(M.combo,(M.P1,M.Qa)),(M.combo,(M.P1,M.Qb)),(M.combo,(M.P2,M.Qa)),
           (M.combo,(M.P2,M.Qb)),(M.combo,(M.P3,M.Qa)),(M.combo,(M.P3,M.Qb)),
           (M.combo,(M.P4,M.Qa)),(M.combo,(M.P4,M.Qb)),(M.combo,(M.P5,M.Qa)),
           (M.combo,(M.P5,M.Qb)),(M.caller2,(Any,Any)),
           (M.mkp2,(Int32,)),(M.mkp5,(Int32,)),(M.mka,(Int32,)),(M.mkb,(Int32,))]
    bytes, treg, freg, dreg = WasmTarget.compile_multi(fns; return_registries=true)
    @test haskey(dreg.selector_offset, M.combo)
    @test length(get(dreg.selector_cascades, M.combo, [])) == 5   # one per P-class
    if success(`which node`)
        p = joinpath(mktempdir(), "m83.wasm"); write(p, bytes)
        js = """
        import fs from 'fs';
        const b = fs.readFileSync('$(escape_string(p))');
        const m = await WebAssembly.instantiate(b, { Math: { pow: Math.pow } });
        const e = m.instance.exports;
        console.log(JSON.stringify([
          e.caller2(e.mkp2(0), e.mka(0)), e.caller2(e.mkp2(0), e.mkb(0)),
          e.caller2(e.mkp5(0), e.mka(0)), e.caller2(e.mkp5(0), e.mkb(0))]));
        """
        jp = joinpath(dirname(p), "m83.mjs"); write(jp, js)
        @test strip(read(`node $jp`, String)) == "[21,22,51,52]"
    end
end
