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
