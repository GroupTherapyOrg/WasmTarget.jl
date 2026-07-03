# parity(M11.1): the dart-shaped intrinsics table (intrinsics.dart:28-71) — ONE
# declarative (lhsT, rhsT, op) → emission map; the dispatch point returns the
# result type or nothing (caller keeps its legacy arm until its family migrates).
@testset "M11.1 intrinsics table (dart intrinsics.dart shape)" begin
    b = WasmTarget.InstrBuilder(; func_name="t")
    WasmTarget.seed_input!(b, WasmTarget.WasmValType[WasmTarget.I64, WasmTarget.I64])
    rt = WasmTarget.emit_intrinsic_binop!(b, WasmTarget.I64, WasmTarget.I64, :add_int)
    @test rt === WasmTarget.I64
    b2 = WasmTarget.InstrBuilder(; func_name="t2")
    WasmTarget.seed_input!(b2, WasmTarget.WasmValType[WasmTarget.F64, WasmTarget.F64])
    rt2 = WasmTarget.emit_intrinsic_binop!(b2, WasmTarget.F64, WasmTarget.F64, :lt_float)
    @test rt2 === WasmTarget.I32                       # comparisons yield i32
    # no entry → nothing (legacy arm keeps working)
    b3 = WasmTarget.InstrBuilder(; func_name="t3")
    @test WasmTarget.emit_intrinsic_binop!(b3, WasmTarget.I64, WasmTarget.F64, :add_int) === nothing
    # coverage: the table carries the full i64/i32 integer core + f64/f32 float core
    @test length(WasmTarget.INTRINSIC_BINOPS) >= 51   # shifts excluded (mixed-width amounts)
end
