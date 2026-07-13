# Loop C value channel (dart2wasm node.accept1 → ValueType) — propagate_numeric_value_types.
#
# Julia leaves a mutated capture typed `Any` even after the WT interpreter inlines foreach + scalar-
# replaces the Core.Box away (so the "F3 box" case is, in WT's real IR, a plain Any-typed numeric
# phi-accumulator computing i64). This recovers the concrete numeric type so those SSAs get i64
# locals, not anyref. Pure analysis (dormant until wired into the SSA-local typing). SAFETY is the
# property under test: it must type a same-category numeric cycle but NEVER a heterogeneous or
# mixed-int/float phi (those stay boxed, matching dart's top-type + the union resolver).

@testset "Loop C: propagate_numeric_value_types value channel" begin
    # SAFETY (default interp gives reliable IRs): no false positives.
    ghet(b::Bool) = (x = b ? 1 : "two"; x === 1)            # Int|String → must NOT be typed numeric
    fmix(b::Bool) = (x = b ? 1 : 2.5; x + 1)                # Int|Float (mixed category) → stays boxed
    fplain(x::Int64)::Int64 = x * 2 + 1                     # no Any SSAs
    for (f, ts) in Any[(ghet, (Bool,)), (fmix, (Bool,)), (fplain, (Int64,))]
        ci = code_typed(f, ts; optimize = true)[1].first
        @test isempty(WasmTarget.propagate_numeric_value_types(ci.code, ci.ssavaluetypes))
    end

    # POSITIVE (the real case): WT interp scalar-replaces counter's box → an Any-typed Int64 cycle.
    # Every captured-via-WT-interp Any-numeric accumulator SSA must recover a concrete numeric type.
    counter(n::Int64)::Int64 = (s = 0; foreach(i -> (s += i), 1:n); s)
    interp = WasmTarget.get_wasm_interpreter()
    res = Base.code_typed(counter, (Int64,); interp = interp)
    if !isempty(res)                                        # guard: WT-interp IR available
        ci = res[1].first
        vt = WasmTarget.propagate_numeric_value_types(ci.code, ci.ssavaluetypes)
        @test !isempty(vt)
        @test all(t -> t isa DataType && isconcretetype(t) && (t <: Integer || t <: AbstractFloat), values(vt))
        # the Any-typed accumulator phi + its `+` are among them
        @test any(i -> ci.code[i] isa Core.PhiNode, keys(vt))
    end
end
