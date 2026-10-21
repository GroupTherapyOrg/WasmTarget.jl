# parity(M11.1): the dart-shaped intrinsics table (intrinsics.dart:28-71) — ONE
# declarative (lhsT, rhsT, op) → emission map; the dispatch point returns the
# result type or nothing (caller keeps its legacy arm until its family migrates).
@testset "M11.1 intrinsics table (dart intrinsics.dart shape)" begin
    b = WasmTarget.InstrBuilder(; func_name="t", mod=WasmTarget.WasmModule())
    WasmTarget.seed_input!(b, WasmTarget.WasmValType[WasmTarget.I64, WasmTarget.I64])
    rt = WasmTarget.emit_intrinsic_binop!(b, WasmTarget.I64, WasmTarget.I64, :add_int, nothing, 64)
    @test rt === WasmTarget.I64
    b2 = WasmTarget.InstrBuilder(; func_name="t2", mod=WasmTarget.WasmModule())
    WasmTarget.seed_input!(b2, WasmTarget.WasmValType[WasmTarget.F64, WasmTarget.F64])
    rt2 = WasmTarget.emit_intrinsic_binop!(b2, WasmTarget.F64, WasmTarget.F64, :lt_float, nothing, 64)
    @test rt2 === WasmTarget.I32                       # comparisons yield i32
    # no entry → nothing
    b3 = WasmTarget.InstrBuilder(; func_name="t3", mod=WasmTarget.WasmModule())
    @test WasmTarget.emit_intrinsic_binop!(b3, WasmTarget.I64, WasmTarget.F64, :add_int, nothing, 64) === nothing
    # coverage: the table carries the full i64/i32 integer core + f64/f32 float core
    @test length(WasmTarget.INTRINSIC_BINOPS) >= 51   # shifts excluded (mixed-width amounts)
end

# operator_intrinsic is Julia's answer (L180): for every surface operator and type it admits, the
# one intrinsic Julia's own typed body of `f(::T, ::T)` runs; an intrinsic callee is accepted for
# its own kind only (`add_int` over a Float64 adds bits: no float opcode, so `nothing`, a rejection)
@testset "operator_intrinsic is the intrinsic Julia's method runs" begin
    for f in (+, -, *), T in (Int32, UInt32, Int64, UInt64, Float32, Float64)
        local ci = Base.code_typed(f, (T, T); optimize=true)[1][1]
        local calls = [s.args[1] for s in ci.code if s isa Expr && s.head === :call]
        local intr = [c isa GlobalRef ? getglobal(c.mod, c.name) : c for c in calls]
        filter!(c -> c isa Core.IntrinsicFunction, intr)
        @test length(intr) == 1
        @test WasmTarget.operator_intrinsic(f, T) === nameof(only(intr))
        @test WasmTarget.operator_intrinsic(only(intr), T) === nameof(only(intr))
    end
    for T in (Int8, UInt16, Bool, Char, Float16, Int128)
        @test WasmTarget.operator_intrinsic(+, T) === nothing
    end
    @test WasmTarget.operator_intrinsic(Core.Intrinsics.add_int, Float64) === nothing
    @test WasmTarget.operator_intrinsic(Core.Intrinsics.mul_float, Int64) === nothing
    @test WasmTarget.operator_intrinsic(Core.Intrinsics.sub_int, Float32) === nothing
end
