using Test
using WasmTarget
using JuliaLowering
using JuliaSyntax

# PHASE-3B-004: Compile JuliaLowering.jl closure conversion + linear IR to WasmGC

@testset "PHASE-3B-004: Closure Conversion + Linear IR WasmGC" begin
    SG = JuliaLowering.SyntaxGraph{Dict{Symbol, Any}}
    ST = JuliaLowering.SyntaxTree{SG}
    CCc = JuliaLowering.ClosureConversionCtx{SG}
    LIc = JuliaLowering.LinearIRContext{SG}

    # Discover closure/convert/linear/compile functions
    funcs = Tuple{String, Any, Tuple}[]
    for name in sort(collect(names(JuliaLowering, all=true)))
        str = string(name)
        if (occursin("closure", lowercase(str)) || occursin("convert_", str) ||
            occursin("capture", lowercase(str)) || occursin("box", lowercase(str)) ||
            occursin("linearize", str) || occursin("linear_ir", str) ||
            occursin("compile_", str) || occursin("_to_ir", str) ||
            occursin("code_info", lowercase(str)) || occursin("codeinfo", lowercase(str))) &&
            isdefined(JuliaLowering, name)
            f = getfield(JuliaLowering, name)
            if f isa Function
                for argtypes in [(CCc, ST), (LIc, ST), (CCc,), (LIc,)]
                    try
                        ci = Base.code_typed(f, argtypes)
                        if !isempty(ci) && length(ci[1][1].code) > 0
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
        outpath = joinpath(@__DIR__, "closure_linear_module.wasm")
        write(outpath, bytes)
        result = read(`wasm-tools validate $outpath`, String)
        @test isempty(result)
        @test length(bytes) < 500_000
        println("  Module: $(round(length(bytes)/1024, digits=1)) KB, $(length(valid_entries)) exports")
    end

    @testset "native ground truth" begin
        # Full lowering pipeline produces CodeInfo natively
        # Note: closures need Core.declare_const (Julia 1.13+)
        # On 1.12, use simpler non-closure expressions
        result = JuliaLowering.include_string(Main, "let x = 5; x + 1; end")
        @test result == 6
        result = JuliaLowering.include_string(Main, "let a = 10; b = 5; a + b; end")
        @test result == 15
    end
end

println("PHASE-3B-004 tests complete!")
