# F3 sub-loop L1 (dev/F3_LOOP.md) — specialized mutable Box{contents} struct registry.
#
# get_box_type!(mod, reg, contents_wasm_type) returns a cached struct
# `(struct (field $typeId i32) (field $contents (mut T)))` keyed by the contents wasm type — the
# dart2wasm-aligned TYPED context cell (contents MUTABLE, unlike the immutable numeric box). DORMANT:
# no codegen call sites yet (byte-identical); L2 threads it through %new / setfield! / getfield /
# the closure captured-box field.

@testset "F3 L1: get_box_type! specialized mutable Box struct" begin
    mod = WasmTarget.WasmModule()
    reg = WasmTarget.TypeRegistry()

    i1 = WasmTarget.get_box_type!(mod, reg, WasmTarget.I64)
    @test WasmTarget.get_box_type!(mod, reg, WasmTarget.I64) == i1   # cached (one struct per contents type)
    f1 = WasmTarget.get_box_type!(mod, reg, WasmTarget.F64)
    @test f1 != i1                                                    # distinct per contents type

    st = mod.types[i1 + 1]
    @test st isa WasmTarget.StructType
    @test length(st.fields) == 2
    @test st.fields[1].valtype === WasmTarget.I32 && st.fields[1].mutable_ == false  # typeId, immutable
    @test st.fields[2].valtype === WasmTarget.I64 && st.fields[2].mutable_ == true   # contents, MUTABLE
end
