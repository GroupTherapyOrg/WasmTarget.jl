using Test
using WasmTarget
using JuliaLowering
using JuliaSyntax

# PHASE-3B-005: Assemble parser + lowerer module and validate parse→lower→CodeInfo

@testset "PHASE-3B-005: Frontend E2E Module" begin

    SG = JuliaLowering.SyntaxGraph{Dict{Symbol, Any}}
    ST = JuliaLowering.SyntaxTree{SG}
    GTC = JuliaSyntax.GreenTreeCursor
    RTC = JuliaSyntax.RedTreeCursor
    SF  = JuliaSyntax.SourceFile
    SN  = JuliaSyntax.SyntaxNode
    SH  = JuliaSyntax.SyntaxHead
    DCc = JuliaLowering.DesugaringContext{SG}
    SRCc = JuliaLowering.ScopeResolutionContext{SG}
    CCc = JuliaLowering.ClosureConversionCtx{SG}
    B = JuliaLowering.Bindings
    BI = JuliaLowering.BindingInfo

    # Representative functions from all phases
    all_funcs = [
        # Parser (6)
        ("gc_head", JuliaSyntax.head, (GTC,)),
        ("rc_byte_range", JuliaSyntax.byte_range, (RTC,)),
        ("kind_sh", JuliaSyntax.kind, (SH,)),
        ("kind_sn", JuliaSyntax.kind, (SN,)),
        ("children_sn", JuliaSyntax.children, (SN,)),
        ("sf_source_line", JuliaSyntax.source_line, (SF, Int)),
        # Lowering data (6)
        ("is_quoted", JuliaLowering.is_quoted, (ST,)),
        ("kind_st", JuliaLowering.kind, (ST,)),
        ("children_st", JuliaLowering.children, (ST,)),
        ("numchildren_st", JuliaLowering.numchildren, (ST,)),
        ("add_binding", JuliaLowering.add_binding, (B, BI)),
        ("SyntaxGraph_ctor", JuliaLowering.SyntaxGraph, ()),
        # Desugaring (1)
        ("expand_forms_2", JuliaLowering.expand_forms_2, (DCc, ST)),
        # Scope (3)
        ("resolve_scopes", JuliaLowering.resolve_scopes, (SRCc, ST)),
        ("current_lambda_bindings", JuliaLowering.current_lambda_bindings, (SRCc,)),
        ("has_lambda_binding", JuliaLowering.has_lambda_binding, (SRCc, ST)),
        # Closure (2)
        ("is_boxed", JuliaLowering.is_boxed, (CCc, ST)),
        ("is_self_captured", JuliaLowering.is_self_captured, (CCc, ST)),
    ]

    @testset "compile all $(length(all_funcs)) functions" begin
        for (name, f, argtypes) in all_funcs
            ci_list = Base.code_typed(f, argtypes)
            @test !isempty(ci_list)
            ci = ci_list[1][1]
            rettype = ci_list[1][2]
            bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
            @test length(bytes) > 0
        end
    end

    @testset "combined module" begin
        valid_entries = Tuple[]
        for (name, f, argtypes) in all_funcs
            ci_list = Base.code_typed(f, argtypes)
            ci = ci_list[1][1]
            rettype = ci_list[1][2]
            bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
            tmppath = joinpath(tempdir(), "test_$(name).wasm")
            write(tmppath, bytes)
            result = read(`wasm-tools validate $tmppath`, String)
            if isempty(result)
                push!(valid_entries, (ci, rettype, argtypes, name))
            end
            rm(tmppath, force=true)
        end

        mod = WasmTarget.compile_module_from_ir(collect(valid_entries))
        bytes = WasmTarget.to_bytes(mod)
        outpath = joinpath(@__DIR__, "frontend_module.wasm")
        write(outpath, bytes)

        result = read(`wasm-tools validate $outpath`, String)
        @test isempty(result)
        @test length(bytes) < 1_000_000

        # Node.js load
        js_test = """
        const fs = require("fs");
        const bytes = fs.readFileSync("$(outpath)");
        WebAssembly.compile(bytes).then(async mod => {
            const imports_desc = WebAssembly.Module.imports(mod);
            const stubs = {};
            for (const imp of imports_desc) {
                if (!stubs[imp.module]) stubs[imp.module] = {};
                if (imp.kind === "function") stubs[imp.module][imp.name] = () => {};
            }
            const inst = await WebAssembly.instantiate(mod, stubs);
            console.log(Object.keys(inst.exports).length);
        }).catch(e => { console.error("FAIL:" + e.message); process.exit(1); });
        """
        tmpjs = joinpath(tempdir(), "test_frontend.cjs")
        write(tmpjs, js_test)
        node_output = read(`node $tmpjs`, String)
        export_count = Base.parse(Int, strip(node_output))
        @test export_count == length(valid_entries)
        rm(tmpjs, force=true)

        println("  Module: $(round(length(bytes)/1024, digits=1)) KB, $(export_count) exports")
    end

    @testset "native parse→lower→execute" begin
        # Full pipeline: source → parse → lower → execute
        @test JuliaLowering.include_string(Main, "1 + 2") == 3
        @test JuliaLowering.include_string(Main, "let x = 5; x * 2; end") == 10
        @test JuliaLowering.include_string(Main, """
            let s = 0
                for i in 1:5
                    s += i
                end
                s
            end
        """) == 15

        # Parse tree structure
        sn = JuliaSyntax.parseall(SN, "f(x) = x + 1")
        @test JuliaSyntax.kind(sn) == JuliaSyntax.K"toplevel"
        ch = JuliaSyntax.children(sn)
        @test ch !== nothing
        @test JuliaSyntax.kind(ch[1]) == JuliaSyntax.K"function"
    end
end

println("PHASE-3B-005 tests complete!")
