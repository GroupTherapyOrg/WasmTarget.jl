# march 3 backfills: the try/catch driver battery that surfaced the
# throw-arm-past-the-leave silent miscompile.
#
# Shape: `y = try; x > 5 ? x : throw(...); catch; 0; end; y + 1` — Julia lowers
# the try body with the normal exit (leave + goto merge) FIRST and the throw arm
# LAST, between leave_idx and catch_dest. The linear PURE-9031 walker's range is
# bounded by leave_idx, so the throw arm compiled to an EMPTY if/else and the
# try-exit phi store ran unconditionally: the catch never fired and the wrong
# value flowed out (f_phi(2) returned 3, not 1) — validated, silent, wrong.
# Fix: the shape dispatches to the stackified try driver (ONE lowering).

_m3_try_basic(x::Int64)::Int64 = try; x == 0 ? throw(DivideError()) : 100 ÷ x; catch; -1; end
_m3_try_nested(x::Int64)::Int64 = try; try; x < 0 ? error("neg") : x * 2; catch; -10; end; catch; -20; end
_m3_try_guard(x::Int64)::Int64 = Int64(try; gcd(Int32(0), Int32(x)); catch; Int32(0); end)
_m3_try_phi(x::Int64)::Int64 = (y = try; x > 5 ? x : throw(ArgumentError("small")); catch; 0; end; y + 1)
_m3_try_rethrow(x::Int64)::Int64 = try; x == 3 ? error("boom") : x; catch e; x + 100; end

@testset "march3: try/catch driver battery (throw-arm-past-leave)" begin
    @test compare_julia_wasm(_m3_try_basic, Int64(5)).pass
    @test compare_julia_wasm(_m3_try_basic, Int64(0)).pass
    @test compare_julia_wasm(_m3_try_nested, Int64(4)).pass
    @test compare_julia_wasm(_m3_try_nested, Int64(-2)).pass
    @test compare_julia_wasm(_m3_try_guard, Int64(12)).pass
    @test compare_julia_wasm(_m3_try_phi, Int64(9)).pass
    @test compare_julia_wasm(_m3_try_phi, Int64(2)).pass    # was: silent 3 (≠ 1)
    @test compare_julia_wasm(_m3_try_rethrow, Int64(3)).pass
    @test compare_julia_wasm(_m3_try_rethrow, Int64(7)).pass
end

# march3 FINDING → FIXED by march5's census-F2 closed-world numbering (the
# _register_reachable_ir_types! pre-pass): Main-defined hierarchies now enter the
# one whole-world DFS before codegen, so `isa` gets a real [low, high] range.
# HARD-LOCKED (was @test_broken while the classId universe was open).
abstract type _M3AZ end
struct _M3B1 <: _M3AZ; x::Int64; end
struct _M3B2 <: _M3AZ; y::Float64; end
_m3_isa_local_hier(x::Int64)::Int64 =
    (v = Any[_M3B1(x), _M3B2(2.5), "s"]; c = 0; for e in v; c += e isa _M3AZ ? 10 : 1; end; c)

@testset "march5: isa over Any[] w/ local abstract hierarchy (FIXED — closed-world DFS)" begin
    r = try compare_julia_wasm(_m3_isa_local_hier, Int64(1)) catch; (pass=false,) end
    @test r.pass
end

# march5 (census F2+F4): the closed-world classId universe + the checked cast.
# Multi-level Main-defined hierarchies (mid-abstract ranges), typeassert throw-parity
# over structs and boxed numerics — all through the ONE whole-world DFS.
abstract type _M5Z end
abstract type _M5Mid <: _M5Z end
struct _M5A <: _M5Mid; a::Int64; end
struct _M5B <: _M5Mid; b::Float64; end
struct _M5C <: _M5Z; c::Int64; end
_m5_hier(x::Int64)::Int64 = (v = Any[_M5A(x), _M5B(1.5), _M5C(x), 7]; c = 0;
    for e in v; c += (e isa _M5Mid ? 100 : 0) + (e isa _M5Z ? 10 : 0) + (e isa Integer ? 1 : 0); end; c)
_m5_cast_struct(b::Bool)::Int64 = (x = b ? Any[_M5A(3)] : Any[_M5C(4)];
    try; (x[1]::_M5A).a; catch; -5; end)
_m5_cast_box(b::Bool)::Int64 = (x = b ? Any[Int64(9)] : Any["s"];
    try; x[1]::Int64 + 1; catch; -7; end)

@testset "march5: closed-world isa + checked casts" begin
    @test compare_julia_wasm(_m5_hier, Int64(2)).pass
    @test compare_julia_wasm(_m5_cast_struct, true).pass
    @test compare_julia_wasm(_m5_cast_struct, false).pass
    @test compare_julia_wasm(_m5_cast_box, true).pass
    @test compare_julia_wasm(_m5_cast_box, false).pass
end

# march5 (census D9.4): the try/finally differential battery — Julia inlines the
# finalizer on each exit path; each shape verified native-vs-wasm. f_fin4's shape
# (nested finally inside catch, non-throwing arm) caught a REAL wrong-value bug:
# the normal path fell through the outer landing end INTO the handler, whose
# fall-through phi-edge store overwrote the merge value with the catch edge's
# (51→57). Fixed with the outer-merge skip machinery in generate_nested_try_catch_2.
_m5_fin1(x::Int64)::Int64 = (acc = 0; try; try; x > 5 && error("big"); acc += 1
    finally; acc += 100; end; catch; acc += 7; end; acc)
_m5_fin2(x::Int64)::Int64 = (acc = 0; try; x > 5 && return acc + 1000; acc += 1
    finally; acc += 100; end; acc)
_m5_fin3(n::Int64)::Int64 = (t = 0; for i in 1:n; try; i > 3 && break; t += i
    finally; t += 10; end; end; t)
_m5_fin4(x::Int64)::Int64 = (r = 0; try; try; x > 2 && error("inner"); r += 1
    finally; r += 50; end; catch; r += 7; end; r)

@testset "march5: try/finally battery (D9.4)" begin
    for (f, xs) in ((_m5_fin1, (3, 9)), (_m5_fin2, (3, 9)), (_m5_fin3, (2, 8)), (_m5_fin4, (1, 5)))
        for x in xs
            @test compare_julia_wasm(f, Int64(x)).pass
        end
    end
end

# march5 (census D10.1): async is OUT-OF-SCOPE BY DESIGN — this locks the
# "sound loud-reject" guarantee (a Task/@async entry must REJECT at compile,
# never silently miscompile).
_m5_task(x::Int64)::Int64 = fetch(Threads.@spawn x + 1)
@testset "march5: async loud-reject conformance (D10.1)" begin
    rejected = try
        WasmTarget.compile_multi(Any[(_m5_task, (Int64,), "m5_task")]; strict=true, validate=true)
        false
    catch
        true
    end
    @test rejected
end
