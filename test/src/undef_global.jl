# A global declared with no value (`global x::T`, a binding Julia holds as PARTITION_KIND_GLOBAL with no value): its
# read before any write raises UndefVarError(name, module) (julia/src/codegen.cpp:3294 emit_globalref, :5587
# emit_checked_var), as dart's late static field with no initializer throws LateError.fieldNI until it is written
# (pkg/front_end/lib/src/kernel/late_lowering.dart:271); a write sets it, and every later read is the value written.
# src/code_generator.jl's StaticFieldInitializerCodeGenerator raises it from the field's lazy initializer. Each case's
# answer is native Julia's, compared in both modules.
module UndefGlobalTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module UndefGlobalCases
# each case its own binding, none given a value before its case writes it: native's run of one case writes only its own
global _ug_read::Int64
global _ug_int::Int64
global _ug_io::IOBuffer
global _ug_io_read::IOBuffer
# the error a read before any write raises, by its fields: its variable's name and the module it was looked up in
_ug_error(e, name::Symbol)::Int64 =
    e isa UndefVarError ? (e.var === name ? Int64(-10) : Int64(-20)) - (e.scope === UndefGlobalCases ? Int64(1) : Int64(2)) : Int64(-100)
# an Int64 binding (dart's explicit initialized flag) read before any write
function read_before_write(x::Int64)::Int64
    try
        return _ug_read + x
    catch e
        return _ug_error(e, :_ug_read)
    end
end
# an Int64 binding written, read, written again and read
function write_then_read(x::Int64)::Int64
    global _ug_int = x
    global _ug_int = _ug_int * 3 + 1
    return _ug_int
end
# an IOBuffer binding (a non-nullable reference, null signals uninitialized) written, then printed to and taken
function iobuffer_written(x::Int64)::Int64
    global _ug_io = IOBuffer()
    print(_ug_io, x, '.')
    print(_ug_io, x + 1)
    local s = String(take!(_ug_io))
    return ncodeunits(s) * 1000 + Int64(codeunit(s, 1))
end
# an IOBuffer binding read before any write
function iobuffer_read_before_write(x::Int64)::Int64
    try
        print(_ug_io_read, x)
        return Int64(position(_ug_io_read))
    catch e
        return _ug_error(e, :_ug_io_read)
    end
end
end

const UC = UndefGlobalCases

@testset "a global declared with no value: UndefVarError before its first write" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((UC.read_before_write, (1, 2)), (UC.write_then_read, (1, 2)), (UC.iobuffer_written, (1, 2)),
                    (UC.iobuffer_read_before_write, (1,)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("undef_global/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: UndefVarError of the binding's name in its module before a write, the value after one
    @test [c.native for c in cases] == [-11, -11, 4, 7, 3049, 3050, -11]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
