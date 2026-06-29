# F3 sub-loop L0 (dev/F3_LOOP.md) — unit tests for the Core.Box contents-type INFERENCE.
#
# Pure analysis, not yet wired into codegen (this loop is byte-identical). `box_contents_type`'s
# contract: infer the concrete type the box holds from the `setfield!(box,:contents,v)` writes
# VISIBLE in the given IR. For an enclosing function that's the init + any direct writes; the
# closure body's writes live in a separate IR, so the caller (L2 specialization) is responsible
# for verifying cross-IR consistency before specializing. These tests pin the primitive's behavior.

@testset "F3 L0: box_contents_type inference (dart2wasm-aligned, dormant)" begin
    counter(n::Int64) = (c = 0;   f = () -> (c += 1);   for _ in 1:n; f(); end; c)
    faccum(n::Int64)  = (s = 0.0; f = x -> (s += x);    for i in 1:n; f(1.5); end; s)

    cic = code_typed(counter, (Int64,); optimize=true)[1].first
    cboxes = WasmTarget.find_box_news(cic.code)
    @test length(cboxes) == 1
    @test WasmTarget.box_contents_type(cic.code, cic.ssavaluetypes, cboxes[1]) === Int64

    cif = code_typed(faccum, (Int64,); optimize=true)[1].first
    fboxes = WasmTarget.find_box_news(cif.code)
    @test length(fboxes) == 1
    @test WasmTarget.box_contents_type(cif.code, cif.ssavaluetypes, fboxes[1]) === Float64

    # A box with no resolvable write in this IR → nothing (no false concrete type).
    @test WasmTarget.box_contents_type(Any[], Any[], 1) === nothing

    # value-type helper: concrete literals pin, Unions / abstract / Type don't.
    @test WasmTarget._f3_value_type(0, Any[]) === Int64
    @test WasmTarget._f3_value_type(1.5, Any[]) === Float64
    @test WasmTarget._f3_value_type(Int64, Any[]) === nothing      # a Type value, not a value
    @test WasmTarget._f3_value_type(Core.SSAValue(1), Any[Union{Int,String}]) === nothing  # Union → dynamic
end
