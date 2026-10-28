# dart's `late final` field (src/julia/late.jl): assigned once, or initialized on its first read; an
# unassigned read rejects as Unported with the field's dart anchor, every other misuse as Internal.
using Test
using WasmTarget

const Late = WasmTarget.Late
_rejection(f) = try; f(); nothing; catch e; e isa WasmTarget.RejectionError ? e.rejection : rethrow(); end

@testset "Late: dart's late final field" begin
    local a = "dart2wasm/lib/translator.dart:140 Translator.closureLayouter"
    # `late final T x;`: assigned once, read after
    local c = Late{Int}(a)
    @test _rejection(() -> c[]) == WasmTarget.Unported(a)          # read unassigned: the field's anchor
    c[] = 3
    @test c[] == 3
    @test _rejection(() -> (c[] = 4)) isa WasmTarget.Internal        # assigned twice
    @test c[] == 3
    # `late final T x = init;`: the initializer runs on the first read, once, never before
    local runs = Ref(0)
    local l = Late{Int}(a, () -> (runs[] += 1; 7))
    @test runs[] == 0
    @test l[] == 7 && l[] == 7 && runs[] == 1
    @test _rejection(() -> (l[] = 8)) isa WasmTarget.Internal        # a field with an initializer assigned
    # an initializer that reads its own field: dart's cyclic initialization
    local self = Ref{Any}(nothing)
    local cyc = Late{Int}(a, () -> self[][] + 1)
    self[] = cyc
    @test _rejection(() -> cyc[]) isa WasmTarget.Internal
    # an initializer that throws leaves the field unassigned, and the next read runs it again
    local fails = Ref(true)
    local t = Late{Int}(a, () -> fails[] ? error("first") : 9)
    @test_throws ErrorException t[]
    fails[] = false
    @test t[] == 9
    # the value is converted to the field's type, as dart's field type holds it
    local f = Late{Float64}(a); f[] = 2
    @test f[] === 2.0
end
