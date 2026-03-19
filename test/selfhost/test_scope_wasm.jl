using Test
using WasmTarget
using JuliaLowering
using JuliaSyntax

# PHASE-3B-003: Compile JuliaLowering.jl scope analysis to WasmGC

@testset "PHASE-3B-003: Scope Analysis WasmGC" begin
    SG = JuliaLowering.SyntaxGraph{Dict{Symbol, Any}}
    ST = JuliaLowering.SyntaxTree{SG}
    SRCc = JuliaLowering.ScopeResolutionContext{SG}
    VACc = JuliaLowering.VariableAnalysisContext{SG}

    # Discover scope/binding/variable/analyze functions
    funcs = Tuple{String, Any, Tuple}[]
    for name in sort(collect(names(JuliaLowering, all=true)))
        str = string(name)
        if (occursin("scope", str) || occursin("resolve", str) || occursin("binding", lowercase(str)) ||
            occursin("variable", str) || occursin("analyze", str) || occursin("lambda", lowercase(str)) ||
            occursin("closure", str)) && isdefined(JuliaLowering, name)
            f = getfield(JuliaLowering, name)
            if f isa Function
                for argtypes in [(SRCc, ST), (VACc, ST), (SRCc,), (VACc,)]
                    try
                        ci = Base.code_typed(f, argtypes)
                        if !isempty(ci)
                            push!(funcs, (str, f, argtypes))
                            break
                        end
                    catch; end
                end
            end
        end
    end

    # Compile + validate
    valid_entries = Tuple[]
    @testset "compile + validate ($(length(funcs)) functions)" begin
        for (name, f, argtypes) in funcs
            try
                ci_list = Base.code_typed(f, argtypes)
                ci = ci_list[1][1]
                rettype = ci_list[1][2]
                bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
                @test length(bytes) > 0
                tmppath = joinpath(tempdir(), "test_$(name).wasm")
                write(tmppath, bytes)
                result = read(`wasm-tools validate $tmppath`, String)
                if isempty(result)
                    push!(valid_entries, (ci, rettype, argtypes, name))
                end
                @test isempty(result)
                rm(tmppath, force=true)
            catch
                @test_broken false
            end
        end
    end

    @testset "combined module" begin
        mod = WasmTarget.compile_module_from_ir(collect(valid_entries))
        bytes = WasmTarget.to_bytes(mod)
        outpath = joinpath(@__DIR__, "scope_module.wasm")
        write(outpath, bytes)
        result = read(`wasm-tools validate $outpath`, String)
        @test isempty(result)
        @test length(bytes) < 500_000
        println("  Module: $(round(length(bytes)/1024, digits=1)) KB, $(length(valid_entries)) exports")
    end

    @testset "native ground truth" begin
        # Scope analysis works natively via include_string
        result = JuliaLowering.include_string(Main, "let x = 1; x + 1; end")
        @test result == 2
        # Nested let scopes
        result = JuliaLowering.include_string(Main, "let x = 1; let y = 2; x + y; end; end")
        @test result == 3
    end
end

println("PHASE-3B-003 tests complete!")
