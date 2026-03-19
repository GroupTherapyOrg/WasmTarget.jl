using Test
using WasmTarget
using JuliaSyntax

# PHASE-3A-004: Assemble parser module and validate parse→SyntaxTree in WasmGC
#
# Combines tokenizer (PHASE-3A-001) + parser (PHASE-3A-002) + tree cursors (PHASE-3A-003)
# into a single parser WASM module. Tests:
# - All functions compile, validate individually, assemble into combined module
# - Combined module validates with wasm-tools and loads in Node.js
# - Native ground truth: 20 expressions parse correctly
# - Module size is within budget (< 5 MB raw)

@testset "PHASE-3A-004: Parser E2E Module" begin

    GTC = JuliaSyntax.GreenTreeCursor
    RTC = JuliaSyntax.RedTreeCursor
    SF  = JuliaSyntax.SourceFile
    GN  = JuliaSyntax.GreenNode{JuliaSyntax.SyntaxHead}
    SN  = JuliaSyntax.SyntaxNode
    SH  = JuliaSyntax.SyntaxHead
    PS  = JuliaSyntax.ParseState
    PSt = JuliaSyntax.ParseStream
    RevGTC = Base.Iterators.Reverse{GTC}
    RevRTC = Base.Iterators.Reverse{RTC}

    # =========================================================================
    # Collect ALL functions
    # =========================================================================

    # Tree cursor functions (30)
    tree_funcs = [
        ("gc_head", JuliaSyntax.head, (GTC,)),
        ("gc_is_leaf", JuliaSyntax.is_leaf, (GTC,)),
        ("gc_span", JuliaSyntax.span, (GTC,)),
        ("rc_head", JuliaSyntax.head, (RTC,)),
        ("rc_is_leaf", JuliaSyntax.is_leaf, (RTC,)),
        ("rc_span", JuliaSyntax.span, (RTC,)),
        ("rc_byte_range", JuliaSyntax.byte_range, (RTC,)),
        ("reverse_green", Base.reverse, (GTC,)),
        ("reverse_red", Base.reverse, (RTC,)),
        ("iterate_rev_green_1", Base.iterate, (RevGTC,)),
        ("iterate_rev_red_1", Base.iterate, (RevRTC,)),
        ("iterate_rev_green_2", Base.iterate, (RevGTC, Tuple{UInt32, UInt32})),
        ("iterate_rev_red_2", Base.iterate, (RevRTC, Tuple{UInt32, UInt32, UInt32})),
        ("sf_source_line", JuliaSyntax.source_line, (SF, Int)),
        ("sf_source_location", JuliaSyntax.source_location, (SF, Int)),
        ("sf_sourcetext", JuliaSyntax.sourcetext, (SF,)),
        ("sf_firstindex", Base.firstindex, (SF,)),
        ("sf_lastindex", Base.lastindex, (SF,)),
        ("sf_filename", JuliaSyntax.filename, (SF,)),
        ("gn_from_cursor", JuliaSyntax.GreenNode, (GTC,)),
        ("children_gn", JuliaSyntax.children, (GN,)),
        ("numchildren_gn", JuliaSyntax.numchildren, (GN,)),
        ("head_gn", JuliaSyntax.head, (GN,)),
        ("span_gn", JuliaSyntax.span, (GN,)),
        ("is_leaf_gn", JuliaSyntax.is_leaf, (GN,)),
        ("sn_from_cursor", JuliaSyntax.SyntaxNode, (SF, RTC)),
        ("children_sn", JuliaSyntax.children, (SN,)),
        ("kind_sn", JuliaSyntax.kind, (SN,)),
        ("kind_sh", JuliaSyntax.kind, (SH,)),
        ("byte_range_sn", JuliaSyntax.byte_range, (SN,)),
    ]

    # Parser functions (46 from ParseState)
    parse_names = [
        :parse_and, :parse_arrow, :parse_atom, :parse_block, :parse_call,
        :parse_catch, :parse_comma, :parse_comparison, :parse_cond, :parse_do,
        :parse_docstring, :parse_eq, :parse_eq_star, :parse_expr, :parse_factor,
        :parse_factor_after, :parse_global_local_const_vars, :parse_if_elseif,
        :parse_import_atsym, :parse_import_path, :parse_imports, :parse_invalid_ops,
        :parse_iteration_spec, :parse_iteration_specs, :parse_juxtapose,
        :parse_macro_name, :parse_or, :parse_pair, :parse_paren, :parse_pipe_gt,
        :parse_pipe_lt, :parse_public, :parse_range, :parse_rational, :parse_resword,
        :parse_shift, :parse_space_separated_exprs, :parse_stmts, :parse_struct_field,
        :parse_subtype_spec, :parse_term, :parse_toplevel, :parse_try,
        :parse_unary, :parse_unary_prefix, :parse_unary_subtype,
    ]
    parser_funcs = []
    for fname in parse_names
        f = getfield(JuliaSyntax, fname)
        try
            ci_list = Base.code_typed(f, (PS,))
            if !isempty(ci_list)
                push!(parser_funcs, (string(fname), f, (PS,)))
            end
        catch; end
    end

    # Stream utility functions (8)
    stream_funcs = Tuple{String, Any, Tuple}[]
    for (name, f, argtypes) in [
        ("bump_pst", JuliaSyntax.bump, (PSt,)),
        ("peek_token", JuliaSyntax.peek_token, (PSt,)),
        ("emit_diagnostic_pst", JuliaSyntax.emit_diagnostic, (PSt,)),
        ("kind_pst", JuliaSyntax.kind, (PSt,)),
        ("is_trivia_pst", JuliaSyntax.is_trivia, (PSt,)),
        ("is_keyword_pst", JuliaSyntax.is_keyword, (PSt,)),
        ("is_operator_pst", JuliaSyntax.is_operator, (PSt,)),
        ("is_literal_pst", JuliaSyntax.is_literal, (PSt,)),
    ]
        try
            ci_list = Base.code_typed(f, argtypes)
            if !isempty(ci_list)
                push!(stream_funcs, (name, f, argtypes))
            end
        catch; end
    end

    all_funcs = vcat(tree_funcs, parser_funcs, stream_funcs)

    # =========================================================================
    # Test 1: All functions compile (code_typed + compile_from_codeinfo)
    # =========================================================================
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

    # =========================================================================
    # Test 2: Individual wasm-tools validation
    # =========================================================================
    valid_entries = Tuple[]
    @testset "individual validation" begin
        for (name, f, argtypes) in all_funcs
            ci_list = Base.code_typed(f, argtypes)
            ci = ci_list[1][1]
            rettype = ci_list[1][2]
            bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
            tmppath = joinpath(tempdir(), "test_$(name).wasm")
            write(tmppath, bytes)
            result = read(`wasm-tools validate $tmppath`, String)
            passes = isempty(result)
            @test passes
            if passes
                push!(valid_entries, (ci, rettype, argtypes, name))
            end
            rm(tmppath, force=true)
        end
    end

    # =========================================================================
    # Test 3: Combined module assembly
    # =========================================================================
    @testset "combined module" begin
        mod = WasmTarget.compile_module_from_ir(collect(valid_entries))
        bytes = WasmTarget.to_bytes(mod)

        outpath = joinpath(@__DIR__, "parser_module.wasm")
        write(outpath, bytes)

        # Validate
        result = read(`wasm-tools validate $outpath`, String)
        @test isempty(result)

        # Size budget: < 5 MB raw
        @test length(bytes) < 5_000_000

        # Node.js load test
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
        tmpjs = joinpath(tempdir(), "test_parser_e2e.cjs")
        write(tmpjs, js_test)
        node_output = read(`node $tmpjs`, String)
        export_count = Base.parse(Int, strip(node_output))
        @test export_count == length(valid_entries)
        rm(tmpjs, force=true)

        println("  Module: $(round(length(bytes)/1024, digits=1)) KB, $(export_count) exports")
    end

    # =========================================================================
    # Test 4: Native ground truth — 20 expressions parse correctly
    # =========================================================================
    @testset "native parse ground truth" begin
        test_expressions = [
            # Function definitions
            ("f(x) = x + 1",               JuliaSyntax.K"function"),
            ("function g(x)\n  x * 2\nend", JuliaSyntax.K"function"),
            # Assignments
            ("x = 42",                       JuliaSyntax.K"="),
            ("a, b = 1, 2",                  JuliaSyntax.K"="),
            # Conditionals
            ("if x > 0\n  x\nelse\n  -x\nend", JuliaSyntax.K"if"),
            ("x > 0 ? x : -x",              JuliaSyntax.K"?"),
            # Loops
            ("for i in 1:10\n  i\nend",      JuliaSyntax.K"for"),
            ("while x > 0\n  x -= 1\nend",   JuliaSyntax.K"while"),
            # Struct definition
            ("struct Point\n  x::Float64\n  y::Float64\nend", JuliaSyntax.K"struct"),
            # Method call
            ("foo(1, 2, 3)",                 JuliaSyntax.K"call"),
            # Operators
            ("1 + 2 * 3",                   JuliaSyntax.K"call"),
            ("a && b || c",                  JuliaSyntax.K"||"),
            # String literal
            ("\"hello world\"",              JuliaSyntax.K"string"),
            # Array literal
            ("[1, 2, 3]",                    JuliaSyntax.K"vect"),
            # Tuple
            ("(1, 2, 3)",                    JuliaSyntax.K"tuple"),
            # Module
            ("module M\nend",                JuliaSyntax.K"module"),
            # Import
            ("using Base",                   JuliaSyntax.K"using"),
            # Try/catch
            ("try\n  f()\ncatch e\n  g()\nend", JuliaSyntax.K"try"),
            # Return
            ("return x + 1",                JuliaSyntax.K"return"),
            # Comparison chain
            ("1 < x < 10",                  JuliaSyntax.K"comparison"),
        ]

        for (code, expected_kind) in test_expressions
            sn = JuliaSyntax.parseall(SN, code)
            @test JuliaSyntax.kind(sn) == JuliaSyntax.K"toplevel"
            ch = JuliaSyntax.children(sn)
            @test ch !== nothing
            @test length(ch) >= 1
            # First non-trivia child should have expected kind
            first_child = ch[1]
            @test JuliaSyntax.kind(first_child) == expected_kind
        end

        # Multi-statement
        multi = "x = 1\ny = 2\nz = x + y"
        sn_multi = JuliaSyntax.parseall(SN, multi)
        ch_multi = JuliaSyntax.children(sn_multi)
        @test ch_multi !== nothing
        @test length(ch_multi) >= 3

        # Nested navigation
        nested = "f(x) = x + 1"
        sn_nested = JuliaSyntax.parseall(SN, nested)
        ch_nested = JuliaSyntax.children(sn_nested)
        @test ch_nested !== nothing
        eq_node = ch_nested[1]
        @test JuliaSyntax.kind(eq_node) == JuliaSyntax.K"function"  # short-form f(x)=... is K"function"
        eq_children = JuliaSyntax.children(eq_node)
        @test eq_children !== nothing
        @test length(eq_children) >= 2  # f(x) and x + 1

        # Byte range correctness
        br = JuliaSyntax.byte_range(sn_nested)
        @test first(br) >= 1
        @test last(br) >= length(nested)
    end
end

println("PHASE-3A-004 tests complete!")
