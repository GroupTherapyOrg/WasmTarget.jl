# dart's `late final` field (src/julia/late.jl): assigned once, or initialized on its first read; an
# unassigned read rejects as Unported with the field's dart anchor, every other misuse as Internal.
using Test
using WasmTarget

const Late = WasmTarget.Late
import WasmTarget: @late_str
_rejection(f) = try; f(); nothing; catch e; e isa WasmTarget.RejectionError ? e.rejection : rethrow(); end

@testset "Late: dart's late final field" begin
    local a = late"dart2wasm/lib/translator.dart:147 Translator.closureLayouter"
    # `late final T x;`: assigned once, read after
    local c = Late{Int}(a)
    @test _rejection(() -> c[]) == WasmTarget.Unported(a.anchor)   # read unassigned: the field's anchor
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

# a late field's anchor resolves at the pin when the package loads (check_late_anchors, L213): each
# late"…" is recorded where it expands, with its module and line, and one that names no declaration of
# its field refuses, located; a plant module's anchors are read against a planted checkout
module LatePlantGood
    import WasmTarget
    import WasmTarget: @late_str
    cell() = WasmTarget.Late{Int}(late"dart2wasm/lib/closures.dart:3 ClosureLayouter.closureBaseStruct")
end
module LatePlantMoved
    import WasmTarget
    import WasmTarget: @late_str
    # one line above the declaration, at its doc comment (closures.dart:345 against :365 at the pin, A121E2)
    cell() = WasmTarget.Late{Int}(late"dart2wasm/lib/closures.dart:2 ClosureLayouter.closureBaseStruct")
end
module LatePlantOther
    import WasmTarget
    import WasmTarget: @late_str
    cell() = WasmTarget.Late{Int}(late"dart2wasm/lib/closures.dart:4 ClosureLayouter.closureBaseStruct")
end
module LatePlantPin
    import WasmTarget
    import WasmTarget: @late_str
    # the anchor efaf2935 wrote for closureBaseStruct, read against the real pin below
    cell() = WasmTarget.Late{Int}(late"dart2wasm/lib/closures.dart:345 ClosureLayouter.closureBaseStruct")
end

@testset "Late: every late field's anchor resolves at the pin" begin
    local sdk = mktempdir()
    mkpath(joinpath(sdk, "pkg", "dart2wasm", "lib"))
    write(joinpath(sdk, "pkg", "dart2wasm", "lib", "closures.dart"), """
        class ClosureLayouter {
          /// Base struct for closures.
          late final int closureBaseStruct = 1;
          late final int functionTypeType = 2;
        }
        """)
    local refused(m) = try
        WasmTarget.check_late_anchors(m, sdk); nothing
    catch e
        e isa WasmTarget.ConstructionViolation ? e.what : rethrow()
    end
    # the anchor at its declaration passes; its cell is made from the recorded anchor
    @test WasmTarget.check_late_anchors(LatePlantGood, sdk) == 0
    @test LatePlantGood.cell().anchor == "dart2wasm/lib/closures.dart:3 ClosureLayouter.closureBaseStruct"
    # a moved line and another field's line each refused, naming the file and line the anchor is written at
    local moved = refused(LatePlantMoved)
    @test moved !== nothing && occursin("late.jl:", moved) && occursin("closures.dart:2 ClosureLayouter.closureBaseStruct", moved) &&
          occursin("line 2 is a comment", moved)
    local other = refused(LatePlantOther)
    @test other !== nothing && occursin("does not declare ClosureLayouter.closureBaseStruct", other)
    # each is recorded with its module and the line it is written at
    @test any(e -> e[2] === LatePlantMoved && e[1] == "dart2wasm/lib/closures.dart:2 ClosureLayouter.closureBaseStruct" &&
                   endswith(string(e[3]), "late.jl") && e[4] > 0, WasmTarget.LATE_ANCHORS)
    # a cell takes no bare string: only late"…" makes its anchor
    @test_throws MethodError WasmTarget.Late{Int}("dart2wasm/lib/closures.dart:3 ClosureLayouter.closureBaseStruct")
    # an anchor of no dart file is refused where it is written
    local expand(ex) = try
        macroexpand(@__MODULE__, ex); nothing
    catch e
        e = e isa LoadError ? e.error : e
        e isa WasmTarget.ConstructionViolation ? e.what : rethrow()
    end
    @test occursin("reads as no dart anchor", something(expand(:(WasmTarget.@late_str "src/julia/runtime/rtutils.jl HOST_MODULES")), ""))
    @test occursin("reads as no dart anchor", something(expand(:(WasmTarget.@late_str "julia/src/gf.c:3910 jl_add_entrypoint")), ""))
    # at the real pin, where its checkout exists: WasmTarget's anchors pass, and closures.dart:345, the
    # anchor efaf2935 wrote for closureBaseStruct (its declaration is at :365), is refused
    local pin = WasmTarget._pin_sdk()
    if pin !== nothing
        @test WasmTarget.check_late_anchors(WasmTarget, pin) == 0
        @test any(e -> e[1] == "dart2wasm/lib/closures.dart:365 ClosureLayouter.closureBaseStruct" && e[2] === WasmTarget.Dart2Wasm,
                  WasmTarget.LATE_ANCHORS)
        local w = try WasmTarget.check_late_anchors(LatePlantPin, pin); nothing catch e; e.what end
        @test w !== nothing && occursin("line 345 is at column 6", w)
    end
end
