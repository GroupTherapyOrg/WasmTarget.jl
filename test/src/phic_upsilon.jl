# An Upsilon's store into its PhiC (src/code_generator.jl visit_block, through emit_phi_incoming!,
# src/julia/runtime/rtutils.jl): Julia's emit_upsilonnode (julia/src/codegen.cpp) assigns the Upsilon's value to
# the PhiC's variable (emit_varinfo_assign), boxed where the PhiC is of a Union type and stored as it is where the
# PhiC is of the value's own type. A variable assigned in a try body and read in its catch is such a PhiC; each
# program's IR is checked to hold the shape it is named for, and each answer is native Julia's, compared in both
# modules.
module PhiCUpsilonTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module UpsilonCases
@noinline boom(n::Int64) = n > 3 ? error("boom") : n
# a PhiC of Union{Nothing,Int64} fed by an Upsilon of nothing and one of an Int64 (an i64 register): the catch
# reads the box, nothing where the loop never reached i == 6
function union_i64(n::Int64)
    r = nothing
    try
        for i in 1:n
            i == 6 && (r = i * 7)
        end
        boom(n)
    catch
        return r === nothing ? Int64(-1) : r
    end
    return Int64(-3)
end
# the same with a Float64 (an f64 register)
function union_f64(n::Int64)
    r = nothing
    try
        for i in 1:n
            i == 6 && (r = i / 4)
        end
        boom(n)
    catch
        return r === nothing ? -1.0 : r
    end
    return -3.0
end
# a PhiC of Int64 fed by Upsilons of Int64 values: the value stored as it is, the last one before the throw
function only_i64(n::Int64)
    r = 0
    try
        r = n * 3
        boom(n)
        r = n * 5
        boom(n + 1)
    catch
        return r
    end
    return Int64(-3)
end
end

const UC = UpsilonCases

# each PhiC of f's IR, its type and its Upsilons' value types (Julia's own IR, the shape a case is named for)
function phic_shapes(f)
    local ir = first(only(Base.code_ircode(f, (Int64,))))
    local shapes = Tuple{Type,Vector{Type}}[]
    for (i, st) in enumerate(ir.stmts.stmt)
        st isa Core.PhiCNode || continue
        local vals = Type[]
        for v in st.values
            local u = ir.stmts.stmt[v.id]::Core.UpsilonNode
            push!(vals, u.val isa Core.SSAValue ? Core.Compiler.widenconst(ir.stmts.type[u.val.id]) : Core.Typeof(u.val))
        end
        push!(shapes, (Core.Compiler.widenconst(ir.stmts.type[i]), vals))
    end
    return shapes
end

@testset "an Upsilon's value stored into its PhiC" begin
    @test any(((t, vs),) -> t == Union{Nothing,Int64} && Int64 in vs, phic_shapes(UC.union_i64))
    @test any(((t, vs),) -> t == Union{Nothing,Float64} && Float64 in vs, phic_shapes(UC.union_f64))
    @test any(((t, vs),) -> t === Int64 && all(==(Int64), vs) && length(vs) >= 2, phic_shapes(UC.only_i64))
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((UC.union_i64, (1, 4, 7)), (UC.union_f64, (1, 5, 6)), (UC.only_i64, (1, 3, 4)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("phic_upsilon/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: no throw, a throw with nothing held, a throw with the value held
    @test [c.native for c in cases] == [-3, -1, 42, -3.0, -1.0, 1.5, -3, 15, 12]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
