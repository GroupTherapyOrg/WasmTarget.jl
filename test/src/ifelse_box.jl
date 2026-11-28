# Julia's ifelse of two values of different types (src/intrinsics.jl generate_static_intrinsic's :ifelse arm): Julia's
# emit_ifelse (julia/src/intrinsics.cpp:1154) selects unboxed only where both values are of one type, else between
# their boxes, each value boxed by its own type. Two classes of one wasm type (Int64 and UInt64, both i64) or of two
# (Int64 and Float64, a value and nothing) each keep their own class; each program's IR is checked to hold the
# builtin call it is named for, each answer native Julia's in both modules, the class read back by isa.
module IfelseBoxTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module IfelseCases
code(r) = r === nothing ? Int64(-1) : r isa Int64 ? Int64(10) + r : r isa UInt64 ? Int64(20) + Int64(r % Int64) :
    r isa Bool ? Int64(30) + Int64(r) : r isa Int32 ? Int64(50) + Int64(r) : r isa Float64 ? Int64(40) + Int64(floor(r * 4)) : Int64(-2)
sel_i64_u64(x::Int64) = code(ifelse(x > 0, x, reinterpret(UInt64, x) >> 1))
sel_bool_i32(x::Int64) = code(ifelse(x > 0, iseven(x), x % Int32))
sel_i64_f64(x::Int64) = code(ifelse(x > 0, x, x / 4))
sel_i64_nothing(x::Int64) = code(ifelse(x > 0, x, nothing))
sel_same(x::Int64) = code(ifelse(x > 0, x, -x))
end

const SC = IfelseCases

# Core.ifelse in f's IR, typed by T
function ifelse_of(f, T)
    local ir = first(only(Base.code_ircode(f, (Int64,))))
    return any(enumerate(ir.stmts.stmt)) do (i, st)
        Meta.isexpr(st, :call) && (st.args[1] === Core.ifelse || st.args[1] == GlobalRef(Core, :ifelse)) &&
            Core.Compiler.widenconst(ir.stmts.type[i]) == T
    end
end

@testset "ifelse between values of two types, each boxed by its own" begin
    @test ifelse_of(SC.sel_i64_u64, Union{Int64,UInt64})
    @test ifelse_of(SC.sel_bool_i32, Union{Bool,Int32})
    @test ifelse_of(SC.sel_i64_f64, Union{Int64,Float64})
    @test ifelse_of(SC.sel_i64_nothing, Union{Nothing,Int64})
    @test ifelse_of(SC.sel_same, Int64)
    local cases = Main.WTChild.RunCase[]
    for f in (SC.sel_i64_u64, SC.sel_bool_i32, SC.sel_i64_f64, SC.sel_i64_nothing, SC.sel_same)
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in (3, 4, -6)
            push!(cases, Main.WTChild.RunCase("ifelse_box/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: each class read back by isa
    @test [c.native for c in cases][1:6] == [13, 14, 20 + ((reinterpret(UInt64, -6) >> 1) % Int64), 30, 31, 44]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
