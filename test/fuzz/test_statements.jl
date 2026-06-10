# ============================================================================
# Statement-layer validation — run standalone:
#   julia --project=test/fuzz test/fuzz/test_statements.jl
# ============================================================================
# Asserts the GENERATOR's own health (well-typed natively, no gen errors) and
# runs the differential over a batch — compiler findings are REPORTED (that's
# discovery working), generator/native failures FAIL (those are our bugs).

using Test, Supposition, Random

include(joinpath(@__DIR__, "run.jl"))

const N = 40

@testset "statement-layer generator health" begin
    for T0 in (Int64, Float64)
        gen = FuzzStatements.gen_program_stmts(T0; depth = 3)
        genfail = 0
        natfail = 0
        cats = Dict{Symbol,Int}()
        findings = String[]
        for k in 1:N
            body = try
                Supposition.example(gen)
            catch e
                genfail += 1
                continue
            end
            # native well-typedness: f(x) must run (or throw a DOMAIN error —
            # ÷0 etc. is fine) without UndefVarError/MethodError (gen bugs)
            fn, _, src = FuzzGen.make_function(body, T0)
            for tup in FuzzGen.sample_inputs(T0)[1:3]
                try
                    Base.invokelatest(fn, tup...)
                catch e
                    if e isa UndefVarError || e isa MethodError
                        natfail += 1
                        natfail <= 3 && println("  NATIVE-INVALID [$T0] $(typeof(e)): $(first(src, 120))")
                    end
                end
            end
            o = try
                FuzzProperty.differential(body, T0)
            catch e
                println("  DIFF ERROR: $(first(sprint(showerror, e), 100))")
                continue
            end
            cats[o.category] = get(cats, o.category, 0) + 1
            if o.category ∉ (:ok, :skip) && length(findings) < 5
                push!(findings, "[$(o.category)] $(first(string(body), 100))")
            end
        end
        println("$T0: ", sort(collect(cats)), "  genfail=$genfail natfail=$natfail")
        for f in findings
            println("    finding: ", f)
        end
        @test genfail == 0
        @test natfail == 0
        @test get(cats, :ok, 0) + get(cats, :skip, 0) > 0   # the loop actually verified things
    end
end
