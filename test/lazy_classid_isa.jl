# formal(dev/formal/ClassIdDispatch.tla): RangeIsa over the LAZILY numbered classes — a type
# that reaches ensure_type_id! after the closed-world DFS (max(type_ids)+1, recorded on every
# abstract ancestor's type_extra_ids) is recognized by `isa` against an ancestor that has NO DFS
# range (no descendant was in the closed world), not only against one that has.
#
# The TLC counterexample (MCClassIdDispatchIsaBroken: one late leaf under a 4-deep abstract
# chain with no early descendant) is a real Julia program: _collect_reachable_ir_types admits
# only `isstructtype` concretes, so a PRIMITIVE type outside assign_type_ids!'s explicit list
# (Char, Int128, UInt128, any user `primitive type`) is numbered lazily when first boxed, and
# its abstract ancestors have a range only if some struct sibling was collected. Pre-fix,
# `isa(x, AbstractChar)` / `isa(x, L1)` compiled to the constant 0 (native: true).
#
# The lock at the end confines the lazy path to exactly the kinds the collector excludes —
# a new lazily numbered kind is a discovery-regime change and must be reviewed here.

module LazyClassIdIsa
abstract type L1 end; abstract type L2 <: L1 end; abstract type L3 <: L2 end; abstract type L4 <: L3 end
primitive type P64 <: L4 64 end
count_chars(n::Int64) = (v = Any['a', Int32(1), 'b', n]; c = 0; for e in v; e isa AbstractChar && (c += 1); end; c)
count_l1(n::Int64) = (v = Any[Core.bitcast(P64, n), Int32(1), Core.bitcast(P64, n + 1)]; c = 0; for e in v; e isa L1 && (c += 1); end; c)
count_l4(n::Int64) = (v = Any[Core.bitcast(P64, n), 'x', Core.bitcast(P64, n + 1)]; c = 0; for e in v; e isa L4 && (c += 1); end; c)
count_l3_none(n::Int64) = (v = Any['x', Int32(1), n]; c = 0; for e in v; e isa L3 && (c += 1); end; c)
count_int128(n::Int64) = (v = Any[Int128(n), 'x', Int32(2)]; c = 0; for e in v; e isa Integer && (c += 1); end; c)
# lock corpus: closures with captures (Core.Box), exceptions, strings, arrays, dispatch
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

@testset "isa: lazily numbered types under range-less abstract ancestors" begin
    M = LazyClassIdIsa
    if WasmRunner.runner_available()
        for (f, a) in ((M.count_chars, 7), (M.count_l1, 7), (M.count_l4, 7),
                       (M.count_l3_none, 7), (M.count_int128, 7))
            r = compare_julia_wasm(f, Int64(a))
            @test r.pass
            r.pass || println("  isa lazy: ", nameof(f), " native=", r.expected, " wasm=", r.actual)
        end
    end
    # the structural shape of the counterexample: P64 and Char numbered past the DFS, every
    # ancestor on the chain range-less, and the lazy id recorded on each of them
    _, treg, _, _ = WasmTarget.compile_multi([(M.count_l1, (Int64,)), (M.count_chars, (Int64,))];
                                             return_registries=true)
    dfs_max = treg.type_ranges[Any][2]
    lazy = Set(T for (T, id) in treg.type_ids if id > dfs_max)
    @test lazy == Set([Char, M.P64])
    for T in (M.L1, M.L2, M.L3, M.L4, AbstractChar)
        @test WasmTarget.get_type_range(treg, T) === nothing
    end
    for T in (M.L1, M.L2, M.L3, M.L4)
        @test treg.type_extra_ids[T] == [treg.type_ids[M.P64]]
    end
    @test treg.type_extra_ids[AbstractChar] == [treg.type_ids[Char]]
end

@testset "lock: the lazy numbering path is confined to the collector's exclusions" begin
    M = LazyClassIdIsa
    # _collect_reachable_ir_types (compile.jl) admits every IR-visible concrete struct type
    # except non-enrolled callables, Core.Box and GenericMemory/GenericMemoryRef; everything
    # else that can carry a classId is numbered by the DFS. So a lazily numbered type is one
    # of: a primitive (not isstructtype), a callable, Core.Box, or a Memory.
    confined(T) = isprimitivetype(T) || T <: Function || T === Core.Box ||
                  T <: GenericMemory || T <: Core.GenericMemoryRef
    corpus = [(M.count_chars, (Int64,)), (M.count_l1, (Int64,)), (M.count_int128, (Int64,)),
              (M.counter, (Int64,)), (M.safe_div, (Int64, Int64)), (M.strlen, (String,)),
              (M.sum_areas, (Int64,)), (M.area, (M.Sq,)), (M.area, (M.Rect,))]
    _, treg, _, _ = WasmTarget.compile_multi(corpus; return_registries=true)
    dfs_max = treg.type_ranges[Any][2]
    lazy = [T for (T, id) in treg.type_ids if id > dfs_max]
    for T in lazy
        @test confined(T)
        confined(T) || println("  UNCONFINED lazily numbered type: ", T)
    end
end
