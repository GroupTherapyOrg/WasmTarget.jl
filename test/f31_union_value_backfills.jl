# Parity Loop C — F31 + F-i31 backfills (dev/PARITY_LEDGER.md).
#
# F31  — heterogeneous-Union VALUE extraction. Before: a live numeric/ref arm flowing into a
#        tagged-union phi-local was dummied to `ref.null` (the value was lost → reading it
#        trapped on a null deref; only the `isa` tag survived via branch-folding). Now the
#        phi-store CONSTRUCTS the tagged-union struct (emit_wrap_union_value) so the value
#        round-trips. Surfaced by `a = x>0 ? 42 : "neg"; Int(a)`.
# F-i31 — tagged-union int box width. The tagged-union value field boxed ints via `ref.i31`
#        (31-bit) → SILENTLY TRUNCATED any int ≥ 2^30 (typemax(Int64) → -1). Now boxed
#        full-width into the {typeId,value} numeric box (the rep Loop B's numeric-Union path
#        already uses), preserving every bit. The #1 anti-goal is a silent miscompile, so
#        the full Int64 range is asserted here.
#
# Verified native-vs-wasm (the differential oracle). These are the permanent regression guard.

@testset "F31 heterogeneous-Union value extraction" begin
    # value extraction from a heterogeneous Union{Int64,String} (Int arm literal)
    hu_val(x::Int64) = (a = x > 0 ? 42 : "neg"; a isa Int ? Int(a) : length(a))
    @test compare_julia_wasm(hu_val, Int64(5)).pass    # Int arm  → 42
    @test compare_julia_wasm(hu_val, Int64(-5)).pass   # String arm → length("neg")=3

    # the tag must still be faithful (isa + per-branch constant)
    hu_isa(x::Int64) = (a = x > 0 ? 7 : "neg"; a isa Int ? 1 : 0)
    @test compare_julia_wasm(hu_isa, Int64(5)).pass
    @test compare_julia_wasm(hu_isa, Int64(-5)).pass

    # Int arm = a *parameter* (Core.Argument edge), full Int64 range — F-i31 anti-truncation.
    hu_param(x::Int64) = (a = x > 0 ? x : "neg"; a isa Int ? Int(a) : length(a))
    for v in (Int64(42), Int64(2)^30, Int64(2)^31, Int64(3_000_000_000),
              typemax(Int64), typemin(Int64))
        @test compare_julia_wasm(hu_param, v).pass
    end

    # large-int arm baked as a literal, too (compile_phi_value literal path)
    hu_big(x::Int64) = (a = x > 0 ? 9_000_000_000 : "negative"; a isa Int ? Int(a) : length(a))
    @test compare_julia_wasm(hu_big, Int64(5)).pass
    @test compare_julia_wasm(hu_big, Int64(-5)).pass
end

@testset "F-i31 numeric-Union box stays full-width (no regression)" begin
    # Loop B numeric Union{Int64,Float64} AnyRef box must remain full-width for large ints.
    nu(b::Bool) = (a = b ? Int64(3_000_000_000) : 2.5; a isa Int ? Int(a) : 0)
    @test compare_julia_wasm(nu, true).pass
    @test compare_julia_wasm(nu, false).pass
end
