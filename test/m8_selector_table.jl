# parity(M8.1): the dart-shaped selector registry (dispatch_table.dart:380-458).
# Locks: axis detection · monomorphic classification · needsDispatch gating ·
# first-fit offset packing with gap reuse across selectors.
module M8SelectorShapes
struct B1 end; struct B2 end; struct B3 end; struct B4 end; struct B5 end
struct B6 end; struct B7 end; struct B8 end; struct B9 end; struct B10 end
end
@testset "M8.1 selector registry (dart dispatch_table shape)" begin
    using .M8SelectorShapes: B1,B2,B3,B4,B5,B6,B7,B8,B9,B10
    kinds = (B1,B2,B3,B4,B5,B6,B7,B8,B9,B10)
    poly(x) = 0
    duo(x) = 1
    mono(x) = 2
    freg = WasmTarget.FunctionRegistry()
    treg = WasmTarget.TypeRegistry()
    for (i, T) in enumerate(kinds)
        WasmTarget.register_function!(freg, "poly_$i", poly, (T,), UInt32(100 + i), Int64)
    end
    WasmTarget.register_function!(freg, "duo_1", duo, (B1,), UInt32(300), Int64)
    WasmTarget.register_function!(freg, "duo_2", duo, (B2,), UInt32(301), Int64)
    WasmTarget.register_function!(freg, "mono_1", mono, (B1,), UInt32(400), Int64)

    reg = WasmTarget.build_selectors(freg, treg)
    @test haskey(reg.selectors, (poly, 1))
    @test haskey(reg.selectors, (duo, 1))
    @test !haskey(reg.selectors, (mono, 1))          # 1 registration ⇒ no selector
    s = reg.selectors[(poly, 1)]
    d = reg.selectors[(duo, 1)]
    @test s.axis == 1 && !s.multi_axis
    @test WasmTarget.target_count(s) == 10
    @test !WasmTarget.needs_dispatch(s)              # dart: callCount==0 ⇒ no table entry
    s.call_count = 5; d.call_count = 1
    @test WasmTarget.needs_dispatch(s) && WasmTarget.needs_dispatch(d)

    n = WasmTarget.pack_selector_offsets!(reg)
    @test n >= 10
    # every row resolves for BOTH selectors (no collisions in the one table)
    for sel in (s, d), (cid, fidx) in sel.targets
        @test reg.table[sel.offset + Int(cid) + 1] == fidx
    end
    # dart sort weight: poly (10 targets) packs before duo (2 targets)
    @test s.offset == 0
end

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
