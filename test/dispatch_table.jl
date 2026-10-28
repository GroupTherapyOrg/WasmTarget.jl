# dart2wasm's dispatch_table.dart, ported (src/dispatch_table.jl, dev/MARCH.md 1.E): the
# row-displacement table on fixed rows, its invariants those of dev/formal/ClassIdDispatch.tla.
using Test
using WasmTarget

const DD = WasmTarget.Dart2Wasm

module DispatchCases
f(x::Int) = x + 1
g(x::Float64) = x * 2
h(x::Int32) = x - Int32(1)
end

# a member: Julia's MethodInstance of `f` at `T`, as Julia's own dispatch answers it
_mi(f, T) = Core.Compiler.specialize_method(Base._which(Base.signature_type(f, T)))

@testset "dispatch_table.dart: Row and buildRowDisplacementTable" begin
    local MI = Core.MethodInstance
    local a, b, c = _mi(DispatchCases.f, (Int,)), _mi(DispatchCases.g, (Float64,)), _mi(DispatchCases.h, (Int32,))
    @test a.def === which(DispatchCases.f, (Int,)) && b.def === which(DispatchCases.g, (Float64,))
    local row(pairs) = DD.Row([(index = i, value = v) for (i, v) in pairs])
    local r1 = row([(1, a), (2, a), (5, a)])
    @test DD.width(r1) == 5 && DD.holes(r1) == 2 && DD.density(r1) == 60 && DD.sparsity(r1) == 40
    local rows = [r1, row([(2, b), (3, b)]), row([(1, c), (4, c)]), row([(3, a)])]
    local table = DD.build_row_displacement_table(rows)
    # every value lands at its row's offset plus its index; no slot holds two values (the model's
    # SlotUnique); every taken slot is some row's value
    local placed = Dict{Int,Tuple{Int,MI}}()
    for (k, r) in enumerate(rows), (i, v) in r.values
        local slot = r.offset[] + i
        @test !haskey(placed, slot)
        placed[slot] = (k, v)
        @test table[slot + 1] === v
    end
    @test count(!isnothing, table) == length(placed) == sum(length(r.values) for r in rows)
    # the first row fits from the first free slot, 0
    @test r1.offset[] == -1
    # unique offsets: no two rows share an offset
    local urows = [row([(1, a)]), row([(2, b)]), row([(3, c)])]
    DD.build_row_displacement_table(urows; unique_offsets = true)
    @test allunique([r.offset[] for r in urows])
    # a stride: the entries from `start` the predicate accepts, the first included
    local t2 = Union{MI,Nothing}[a, a, nothing, a, b]
    @test DD.calculate_stride_with(0, a, t2, x -> x === a) == 2
    @test DD.calculate_stride_with(0, a, t2, x -> x === a || x === nothing) == 4
    @test DD.calculate_stride_with(4, b, t2, x -> true) == 1
    @test DD.stride_element_table_limit() == 100
    # a row asserts its values are present and sorted: located rejections
    for bad in (NamedTuple{(:index, :value),Tuple{Int,MI}}[], [(index = 2, value = a), (index = 1, value = a)])
        local e = try; DD.Row(bad); nothing; catch x; x; end
        @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Internal
    end
end
