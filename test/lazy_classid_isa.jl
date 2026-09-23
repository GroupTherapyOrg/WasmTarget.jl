# formal(dev/formal/ClassIdDispatch.tla): RangeIsa over the WHOLE closed world — every
# concrete kind that can carry a classId (structs, closures, `Core.Box`, primitives incl.
# `Char`/`Int128`, a user `primitive type`) is numbered by ONE DFS (`assign_type_ids!`),
# never by a second, order-dependent path. Phase 12B (dev/MARCH.md) deleted that second
# path: `_collect_reachable_ir_types` now admits every such kind before the DFS runs, and
# `ensure_type_id!` on an unnumbered type is a loud collector bug (error), never an
# allocation. Pre-fix, a PRIMITIVE type outside assign_type_ids!'s explicit list (Char,
# Int128, UInt128, any user `primitive type`) was numbered lazily when first boxed, and
# `isa(x, AbstractChar)` / `isa(x, L1)` against a range-less ancestor compiled to the
# constant 0 (native: true) — the TLC counterexample this file's first testset guards.

module LazyClassIdIsa
abstract type L1 end; abstract type L2 <: L1 end; abstract type L3 <: L2 end; abstract type L4 <: L3 end
primitive type P64 <: L4 64 end
count_chars(n::Int64) = (v = Any['a', Int32(1), 'b', n]; c = 0; for e in v; e isa AbstractChar && (c += 1); end; c)
count_l1(n::Int64) = (v = Any[Core.bitcast(P64, n), Int32(1), Core.bitcast(P64, n + 1)]; c = 0; for e in v; e isa L1 && (c += 1); end; c)
count_l4(n::Int64) = (v = Any[Core.bitcast(P64, n), 'x', Core.bitcast(P64, n + 1)]; c = 0; for e in v; e isa L4 && (c += 1); end; c)
count_l3_none(n::Int64) = (v = Any['x', Int32(1), n]; c = 0; for e in v; e isa L3 && (c += 1); end; c)
count_int128(n::Int64) = (v = Any[Int128(n), 'x', Int32(2)]; c = 0; for e in v; e isa Integer && (c += 1); end; c)
# corpus: closures with captures (Core.Box), exceptions, strings, arrays, dispatch
struct Sq s::Float64 end; struct Rect w::Float64; h::Float64 end
area(s::Sq) = s.s * s.s; area(r::Rect) = r.w * r.h
function counter(n::Int64)
    c = 0
    f = () -> (c += 1; c)
    for _ in 1:n; f(); end
    c
end
safe_div(a::Int64, b::Int64) = try; div(a, b); catch e; e isa DivideError ? -1 : -2; end
strlen(s::String) = length(s) + (s isa AbstractString ? 1 : 0)
sum_areas(n::Int64) = (v = Any[Sq(1.0), Rect(2.0, Float64(n))]; t = 0.0; for e in v; t += e isa Sq ? area(e::Sq) : area(e::Rect); end; t)
end

@testset "isa: primitives outside the hardcoded baseline (Char, Int128, a user primitive type)" begin
    M = LazyClassIdIsa
    if WasmRunner.runner_available()
        for (f, a) in ((M.count_chars, 7), (M.count_l1, 7), (M.count_l4, 7),
                       (M.count_l3_none, 7), (M.count_int128, 7))
            r = compare_julia_wasm(f, Int64(a))
            @test r.pass
            r.pass || println("  isa: ", nameof(f), " native=", r.expected, " wasm=", r.actual)
        end
    end
    # the structural shape of the old counterexample no longer exists: P64 and Char are
    # numbered by the SAME DFS as everything else, so every ancestor on the chain has a
    # real range — there is no more range-less abstract ancestor to fall back on.
    _, treg, _, _ = WasmTarget.compile_multi([(M.count_l1, (Int64,)), (M.count_chars, (Int64,))];
                                             return_registries=true)
    for T in (M.L1, M.L2, M.L3, M.L4, AbstractChar)
        @test WasmTarget.get_type_range(treg, T) !== nothing
    end
end

@testset "lock: the lazy numbering path does not exist" begin
    M = LazyClassIdIsa
    # every concrete kind that can carry a classId — closures with captures (Core.Box),
    # try/catch (exception structs), strings, arrays, multi-method dispatch, Char, Int128,
    # and a user `primitive type` under a 4-deep abstract chain — is admitted by
    # `_collect_reachable_ir_types` and numbered by `assign_type_ids!`'s DFS BEFORE any
    # body compiles. No type the registry ends up knowing about can have an id past the
    # DFS's own maximum: that would mean something reached `ensure_type_id!` unnumbered,
    # which is now a collector bug, not a fallback.
    corpus = [(M.count_chars, (Int64,)), (M.count_l1, (Int64,)), (M.count_int128, (Int64,)),
              (M.counter, (Int64,)), (M.safe_div, (Int64, Int64)), (M.strlen, (String,)),
              (M.sum_areas, (Int64,)), (M.area, (M.Sq,)), (M.area, (M.Rect,))]
    _, treg, _, _ = WasmTarget.compile_multi(corpus; return_registries=true)
    dfs_max = treg.type_ranges[Any][2]
    for (T, id) in treg.type_ids
        @test id <= dfs_max
        id <= dfs_max || println("  NUMBERED PAST THE DFS (lazy path resurfaced): ", T, " => ", id)
    end
end

@testset "lock (negative): ensure_type_id! on an unnumbered type is a loud error, never an allocation" begin
    fresh = WasmTarget.TypeRegistry()
    WasmTarget.assign_type_ids!(fresh)
    @test_throws ErrorException WasmTarget.ensure_type_id!(fresh, LazyClassIdIsa.L1)
    @test WasmTarget.get_type_id(fresh, LazyClassIdIsa.L1) == 0   # confirms no id was allocated
end
