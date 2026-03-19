using Test
using WasmTarget
using JuliaLowering
using JuliaSyntax

# PHASE-3B-001: Compile JuliaLowering.jl data structures to WasmGC
#
# SyntaxGraph, SyntaxTree, SyntaxList, BindingInfo, Bindings, LambdaBindings
# Plus AST predicates and JuliaSyntax accessor functions on SyntaxTree

@testset "PHASE-3B-001: JuliaLowering Data Structures WasmGC" begin

    SG = JuliaLowering.SyntaxGraph{Dict{Symbol, Any}}
    ST = JuliaLowering.SyntaxTree{SG}
    SLC = JuliaLowering.SyntaxList{SG}
    B = JuliaLowering.Bindings
    BI = JuliaLowering.BindingInfo
    LB = JuliaLowering.LambdaBindings

    all_functions = [
        # ast.jl predicates (4)
        ("is_quoted", JuliaLowering.is_quoted, (ST,)),
        ("is_sym_decl", JuliaLowering.is_sym_decl, (ST,)),
        ("is_eventually_call", JuliaLowering.is_eventually_call, (ST,)),
        ("assigned_function_name", JuliaLowering.assigned_function_name, (ST,)),
        # SyntaxGraph/SyntaxTree operations (7)
        ("numchildren_st", JuliaLowering.numchildren, (ST,)),
        ("kind_st", JuliaLowering.kind, (ST,)),
        ("head_st", JuliaLowering.head, (ST,)),
        ("children_st", JuliaLowering.children, (ST,)),
        ("child", JuliaLowering.child, (SG, Int64, Int)),
        ("SyntaxGraph_ctor", JuliaLowering.SyntaxGraph, ()),
        # JuliaSyntax accessors on SyntaxTree (15)
        ("flags_st", JuliaSyntax.flags, (ST,)),
        ("is_trivia_st", JuliaSyntax.is_trivia, (ST,)),
        ("is_error_st", JuliaSyntax.is_error, (ST,)),
        ("is_operator_st", JuliaSyntax.is_operator, (ST,)),
        ("is_keyword_st", JuliaSyntax.is_keyword, (ST,)),
        ("is_literal_st", JuliaSyntax.is_literal, (ST,)),
        ("is_prefix_call_st", JuliaSyntax.is_prefix_call, (ST,)),
        ("is_infix_op_call_st", JuliaSyntax.is_infix_op_call, (ST,)),
        ("is_postfix_op_call_st", JuliaSyntax.is_postfix_op_call, (ST,)),
        ("is_leaf_st", JuliaSyntax.is_leaf, (ST,)),
        ("first_byte_st", JuliaSyntax.first_byte, (ST,)),
        ("last_byte_st", JuliaSyntax.last_byte, (ST,)),
        ("byte_range_st", JuliaSyntax.byte_range, (ST,)),
        ("sourcetext_st", JuliaSyntax.sourcetext, (ST,)),
        ("source_location_st", JuliaSyntax.source_location, (ST,)),
        # Bindings (1)
        ("add_binding", JuliaLowering.add_binding, (B, BI)),
        # SyntaxList (1)
        ("length_sl", Base.length, (SLC,)),
        # LambdaBindings (1)
        ("init_lambda_binding", JuliaLowering.init_lambda_binding, (LB, Int64)),
    ]

    # =========================================================================
    # Test 1: code_typed + compile_from_codeinfo for all functions
    # =========================================================================
    @testset "compile all $(length(all_functions)) functions" begin
        for (name, f, argtypes) in all_functions
            ci_list = Base.code_typed(f, argtypes)
            @test !isempty(ci_list)
            ci = ci_list[1][1]
            rettype = ci_list[1][2]
            bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
            @test length(bytes) > 0
        end
    end

    # =========================================================================
    # Test 2: Individual wasm-tools validation
    # =========================================================================
    valid_entries = Tuple[]
    @testset "individual validation" begin
        for (name, f, argtypes) in all_functions
            ci_list = Base.code_typed(f, argtypes)
            ci = ci_list[1][1]
            rettype = ci_list[1][2]
            bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
            tmppath = joinpath(tempdir(), "test_$(name).wasm")
            write(tmppath, bytes)
            result = read(`wasm-tools validate $tmppath`, String)
            @test isempty(result)
            if isempty(result)
                push!(valid_entries, (ci, rettype, argtypes, name))
            end
            rm(tmppath, force=true)
        end
    end

    # =========================================================================
    # Test 3: Combined module
    # =========================================================================
    @testset "combined module" begin
        mod = WasmTarget.compile_module_from_ir(collect(valid_entries))
        bytes = WasmTarget.to_bytes(mod)
        outpath = joinpath(@__DIR__, "lowering_data_module.wasm")
        write(outpath, bytes)

        # Validate
        result = read(`wasm-tools validate $outpath`, String)
        @test isempty(result)

        # Size check
        @test length(bytes) < 100_000  # should be well under 100 KB

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
        tmpjs = joinpath(tempdir(), "test_lowering_data.cjs")
        write(tmpjs, js_test)
        node_output = read(`node $tmpjs`, String)
        export_count = Base.parse(Int, strip(node_output))
        @test export_count == length(valid_entries)
        rm(tmpjs, force=true)

        println("  Module: $(round(length(bytes)/1024, digits=1)) KB, $(export_count) exports")
    end

    # =========================================================================
    # Test 4: Native ground truth — data structure operations
    # =========================================================================
    @testset "native ground truth" begin
        # Create a SyntaxGraph
        g = JuliaLowering.SyntaxGraph()
        @test g isa JuliaLowering.SyntaxGraph{Dict{Symbol, Any}}
        @test length(g.edge_ranges) == 0
        @test length(g.edges) == 0

        # Use JuliaLowering to lower something and inspect the tree
        # JuliaLowering.include_string runs the full pipeline
        result = JuliaLowering.include_string(Main, "1 + 2")
        @test result == 3

        # BindingInfo construction
        bi = JuliaLowering.BindingInfo(
            1, "x", :local, 0, nothing, nothing,
            Int32(0), false, false, false, false, false, false, false
        )
        @test bi.id == 1
        @test bi.name == "x"
        @test bi.kind == :local

        # Bindings
        bindings = JuliaLowering.Bindings(JuliaLowering.BindingInfo[])
        @test length(bindings.info) == 0
        new_bindings = JuliaLowering.add_binding(bindings, bi)
        @test length(new_bindings) == 1

        # LambdaBindings
        lb = JuliaLowering.LambdaBindings(0, Dict{Int64, JuliaLowering.LambdaBindingInfo}())
        @test lb.self == 0
        lbi = JuliaLowering.init_lambda_binding(lb, 1)
        @test lbi isa JuliaLowering.LambdaBindingInfo
    end
end

println("PHASE-3B-001 tests complete!")
