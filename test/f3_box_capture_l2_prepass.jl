# F3 sub-loop L2a (dev/F3_LOOP.md) — cross-function pre-pass that maps a capturing closure type
# to the WASM contents type of the Core.Box it captures (registry.box_contents_types).
#
# populate_box_field_types!(mod, reg, code, ssa_types) scans an enclosing fn's typed IR: for each
# %new(Core.Box) with a CONCRETE contents type (box_contents_type), it maps every closure type
# capturing it → the contents wasm type. register_closure_type! (L2 wiring) will consult this to
# type the captured-box field as a typed Box{contents}. DORMANT: nothing reads the side-table yet
# (byte-identical). Dynamic-contents boxes get NO entry → anyref fallback.

@testset "F3 L2a: populate_box_field_types! pre-pass (dormant)" begin
    # counter: `s` is a mutated capture → Core.Box{Int64}; the foreach closure captures it.
    fcounter() = (s = 0; foreach(i -> (s += i), 1:5); s)
    ci = code_typed(fcounter, (); optimize = true)[1].first
    mod = WasmTarget.WasmModule()
    reg = WasmTarget.TypeRegistry()
    WasmTarget.populate_box_field_types!(mod, reg, ci.code, ci.ssavaluetypes)

    @test length(WasmTarget.find_box_news(ci.code)) == 1            # one Core.Box
    @test !isempty(reg.box_contents_types)                          # captor mapped
    @test all(==(WasmTarget.I64), values(reg.box_contents_types))   # contents = Int64 → I64

    # dynamic contents (heterogeneous writes) → no concrete type → no entry (anyref fallback).
    fdyn(b::Bool) = (c = 0; foreach(i -> (c = b ? i : "x"), 1:3); c)
    cid = code_typed(fdyn, (Bool,); optimize = true)[1].first
    reg2 = WasmTarget.TypeRegistry()
    WasmTarget.populate_box_field_types!(WasmTarget.WasmModule(), reg2, cid.code, cid.ssavaluetypes)
    @test isempty(reg2.box_contents_types)                          # dynamic ⇒ anyref, no typed entry

    # box_contents_types === nothing (e.g. the minimal self-host registry) is a no-op, never errors.
    reg3 = WasmTarget.TypeRegistry()
    reg3.box_contents_types = nothing
    @test WasmTarget.populate_box_field_types!(WasmTarget.WasmModule(), reg3, ci.code, ci.ssavaluetypes) === nothing
end
