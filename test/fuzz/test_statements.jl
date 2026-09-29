# ============================================================================
# Statement-layer validation — run standalone:
#   julia --project=test/fuzz test/fuzz/test_statements.jl
# ============================================================================
# Asserts the GENERATOR's own health (well-typed natively, no gen errors) and runs the
# differential over a fixed draw of its programs (seeded: the same programs every run). A
# program WT rejects at compile time is reported (loud is correct); a program whose wasm
# answers differently from native — a wrong value, a trap, a divergent throw, an unsound
# optimization — fails the lane with its full source, input and both answers. Until
# 2026-09-29 the draw was unseeded and those were only reported: a wrong_value printed 100
# characters of its program and passed, and one draw stalled a Windows 1.13 job for 39 min.

using Test, Supposition, Random

include(joinpath(@__DIR__, "run.jl"))

const N = 40
const SEED = 0x5747_0001   # the fixed draw; a new seed is a new program set, reviewed as such

@testset "statement-layer generator health" begin
    for (ti, T0) in enumerate((Int64, Float64))
        Random.seed!(SEED + ti)   # Supposition.example draws from the default RNG
        gen = FuzzStatements.gen_program_stmts(T0; depth = 3)
        genfail = 0
        natfail = 0
        cats = Dict{Symbol,Int}()
        findings = String[]
        wrong = String[]
        drawn = String[]   # the programs drawn, for the draw's digest
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
            push!(drawn, src)
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
            if o.category === :compile_error
                length(findings) < 5 && push!(findings, "[compile_error] $(first(string(body), 100))")
            elseif o.category ∉ (:ok, :skip)
                push!(wrong, "[$(o.category)] program $k, input $(o.input): native $(o.native), " *
                             "wasm $(o.wasm)\n$(o.src)")
            end
        end
        println("$T0: ", sort(collect(cats)), "  genfail=$genfail natfail=$natfail  draw=",
                string(hash(join(drawn, '\0')); base=16))
        for f in findings
            println("    finding: ", f)
        end
        for w in wrong
            println("  WRONG OUTCOME [$T0] ", w)
        end
        @test isempty(wrong)
        @test genfail == 0
        @test natfail == 0
        @test get(cats, :ok, 0) + get(cats, :skip, 0) > 0   # the loop actually verified things
    end
end
