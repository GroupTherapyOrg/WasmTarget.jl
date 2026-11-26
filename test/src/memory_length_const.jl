# A Memory's `length` is const in Julia (julia/src/jltypes.c:3334 memory_constfields, `isconst(Memory{UInt8},
# :length)`), and Julia's runtime alone writes a byte memory's, to 0, when a String takes it
# (julia/src/genericmemory.c:200 jl_genericmemory_to_string). ClassField keeps the two apart (audit A117E1):
# `mutable` is Julia's answer, which a setter reads, and `runtime_written` makes the wasm struct field mutable for
# the take (class_info.jl's FieldType). A program's setfield! of the field raises Julia's own const-field
# ErrorException (codegen.cpp's arm, src/code_generator.jl visitInstanceSet), compared with native in both modules;
# the take itself is test/src/memory_take.jl's.
module MemoryLengthConstTest

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "codegen_helpers.jl"))

module LengthCases
# the write and Julia's raise: the message read back where the exception is caught, compared by ===, Julia's egal
# of the Strings' contents; natively -3
function set_length(n::Int64)::Int64
    local m = Memory{UInt8}(undef, n + 2)
    try
        setfield!(m, :length, 0)
        return Int64(length(m))
    catch e
        return e isa ErrorException ? (e.msg === "setfield!: const field .length of type GenericMemory cannot be changed" ? Int64(-3) : Int64(-30)) : Int64(-300)
    end
end
end

@testset "classes.jl: a byte Memory's length is Julia's const field, its wasm field mutable for the runtime's take" begin
    local f = only(x for x in W.class_instance_fields(Memory{UInt8}, "test") if x.name == "length")
    @test isconst(Memory{UInt8}, :length)
    @test !f.mutable && f.runtime_written
    local g = only(x for x in W.class_instance_fields(Memory{Int64}, "test") if x.name == "length")
    @test !g.mutable && !g.runtime_written
end

@testset "code_generator.dart visitInstanceSet: a program's setfield! of a Memory's length raises Julia's const-field ErrorException, both modules, against native" begin
    @test LengthCases.set_length(Int64(1)) == -3
    for x in (1, 4)
        push!(NATIVE_RUNS, WTChild.compiled_case("set_length($x)", W.compile, LengthCases.set_length, (Int64(x),)))
    end
end

@testset "the third oracle: every module queued above answers as native Julia" begin
    for r in WTChild.run_cases(NATIVE_RUNS)
        r.ok || println(r.label, ": ", r.why)
        @test r.ok
    end
end

end
