# dart2wasm's class_info.dart, ported (src/class_info.jl, dev/MARCH.md 1.C): each filled definition
# answers as dart's does on fixed inputs.
using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm

@testset "class_info.dart: Range and normalize" begin
    local R = D.Range
    # the factory: a range whose end precedes its start is the empty one
    @test D.is_empty(R(3, 1)) && R(3, 1) == D.Range_empty() && length(R(3, 1)) == 0
    @test length(R(2, 5)) == 4 && contains(R(2, 5), 5) && !contains(R(2, 5), 6)
    @test D.contains_range(R(1, 9), R(2, 5)) && !D.contains_range(R(2, 5), R(1, 9))
    @test D.shift_by(R(2, 5), 3) == R(5, 8) && D.is_empty(D.shift_by(R(3, 1), 3))
    @test R(1, 2) == R(1, 2) && R(1, 2) != R(1, 3) && hash(R(1, 2)) == hash(R(1, 2))
    @test sprint(show, R(1, 2)) == "[1, 2]" && sprint(show, R(3, 1)) == "[]"
    # the private constructor asserts start <= end: a located rejection, never a wrong range
    local e = try; D.Range__(3, 1); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Internal
    # normalize: sorted by start, overlapping and adjacent runs merged, empty ranges dropped
    local norm(v) = (D.normalize(v); v)
    @test norm(D.Range[]) == D.Range[]
    @test norm([R(5, 7), R(1, 2), R(3, 4), R(10, 9), R(12, 14), R(13, 13)]) == [R(1, 7), R(12, 14)]
    @test norm([R(1, 3), R(2, 5), R(7, 8), R(9, 9)]) == [R(1, 5), R(7, 9)]
    @test norm([R(4, 6), R(1, 2)]) == [R(1, 2), R(4, 6)]
    @test norm([R(3, 1), R(2, 2)]) == [R(2, 2)]
end
