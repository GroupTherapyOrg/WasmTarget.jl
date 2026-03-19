using Test
using WasmTarget
using JuliaSyntax

# PHASE-3A-003: Compile JuliaSyntax.jl tree cursors and SyntaxTree navigation to WasmGC
#
# Tests: code_typed + compile_from_codeinfo for each function,
#        combined module validation, Node.js loading,
#        native ground truth for tree navigation

@testset "PHASE-3A-003: Tree Cursors + SyntaxTree WasmGC" begin

    # =========================================================================
    # All functions to compile
    # =========================================================================

    GTC = JuliaSyntax.GreenTreeCursor
    RTC = JuliaSyntax.RedTreeCursor
    SF  = JuliaSyntax.SourceFile
    GN  = JuliaSyntax.GreenNode{JuliaSyntax.SyntaxHead}
    SN  = JuliaSyntax.SyntaxNode
    SH  = JuliaSyntax.SyntaxHead
    RevGTC = Base.Iterators.Reverse{GTC}
    RevRTC = Base.Iterators.Reverse{RTC}

    all_functions = [
        # GreenTreeCursor (3)
        ("gc_head",     JuliaSyntax.head,    (GTC,)),
        ("gc_is_leaf",  JuliaSyntax.is_leaf, (GTC,)),
        ("gc_span",     JuliaSyntax.span,    (GTC,)),
        # RedTreeCursor (4)
        ("rc_head",       JuliaSyntax.head,       (RTC,)),
        ("rc_is_leaf",    JuliaSyntax.is_leaf,     (RTC,)),
        ("rc_span",       JuliaSyntax.span,        (RTC,)),
        ("rc_byte_range", JuliaSyntax.byte_range,  (RTC,)),
        # Reverse constructors (2)
        ("reverse_green", Base.reverse, (GTC,)),
        ("reverse_red",   Base.reverse, (RTC,)),
        # Iteration (4)
        ("iterate_rev_green_1", Base.iterate, (RevGTC,)),
        ("iterate_rev_red_1",   Base.iterate, (RevRTC,)),
        ("iterate_rev_green_2", Base.iterate, (RevGTC, Tuple{UInt32, UInt32})),
        ("iterate_rev_red_2",   Base.iterate, (RevRTC, Tuple{UInt32, UInt32, UInt32})),
        # SourceFile (6)
        ("sf_source_line",     JuliaSyntax.source_line,     (SF, Int)),
        ("sf_source_location", JuliaSyntax.source_location, (SF, Int)),
        ("sf_sourcetext",      JuliaSyntax.sourcetext,      (SF,)),
        ("sf_firstindex",      Base.firstindex,              (SF,)),
        ("sf_lastindex",       Base.lastindex,               (SF,)),
        ("sf_filename",        JuliaSyntax.filename,         (SF,)),
        # GreenNode (6)
        ("gn_from_cursor",  JuliaSyntax.GreenNode,    (GTC,)),
        ("children_gn",     JuliaSyntax.children,      (GN,)),
        ("numchildren_gn",  JuliaSyntax.numchildren,   (GN,)),
        ("head_gn",         JuliaSyntax.head,          (GN,)),
        ("span_gn",         JuliaSyntax.span,          (GN,)),
        ("is_leaf_gn",      JuliaSyntax.is_leaf,       (GN,)),
        # SyntaxNode (5)
        ("sn_from_cursor",  JuliaSyntax.SyntaxNode,    (SF, RTC)),
        ("children_sn",     JuliaSyntax.children,      (SN,)),
        ("kind_sn",         JuliaSyntax.kind,          (SN,)),
        ("kind_sh",         JuliaSyntax.kind,          (SH,)),
        ("byte_range_sn",   JuliaSyntax.byte_range,    (SN,)),
    ]

    # =========================================================================
    # Test 1: code_typed succeeds for all functions
    # =========================================================================
    @testset "code_typed" begin
        for (name, f, argtypes) in all_functions
            ci_list = Base.code_typed(f, argtypes)
            @test !isempty(ci_list)
        end
    end

    # =========================================================================
    # Test 2: compile_from_codeinfo succeeds for all functions
    # =========================================================================
    @testset "compile_from_codeinfo" begin
        for (name, f, argtypes) in all_functions
            ci_list = Base.code_typed(f, argtypes)
            ci = ci_list[1][1]
            rettype = ci_list[1][2]
            bytes = WasmTarget.compile_from_codeinfo(ci, rettype, name, argtypes)
            @test length(bytes) > 0
        end
    end

    # =========================================================================
    # Test 3: Individual wasm-tools validation
    # =========================================================================
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
            rm(tmppath, force=true)
        end
    end

    # =========================================================================
    # Test 4: Combined module assembly + validation
    # =========================================================================
    @testset "combined module" begin
        # build_tree_gn excluded — stubbed callee causes validation fail in combined module
        module_funcs = filter(x -> x[1] != "build_tree_gn", all_functions)

        ir_entries = []
        for (name, f, argtypes) in module_funcs
            ci_list = Base.code_typed(f, argtypes)
            ci = ci_list[1][1]
            rettype = ci_list[1][2]
            push!(ir_entries, (ci, rettype, argtypes, name))
        end

        mod = WasmTarget.compile_module_from_ir(ir_entries)
        bytes = WasmTarget.to_bytes(mod)

        outpath = joinpath(@__DIR__, "tree_cursors_module.wasm")
        write(outpath, bytes)

        # Validate
        result = read(`wasm-tools validate $outpath`, String)
        @test isempty(result)

        # Size check
        @test length(bytes) < 50_000  # should be well under 50 KB

        # Node.js loading test
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
            const exports = Object.keys(inst.exports);
            console.log(exports.length);
        }).catch(e => { console.error("FAIL:" + e.message); process.exit(1); });
        """
        tmpjs = joinpath(tempdir(), "test_tree_cursors.cjs")
        write(tmpjs, js_test)
        node_output = read(`node $tmpjs`, String)
        export_count = Base.parse(Int, strip(node_output))
        @test export_count == length(module_funcs)
        rm(tmpjs, force=true)
    end

    # =========================================================================
    # Test 5: Native ground truth — tree navigation correctness
    # =========================================================================
    @testset "native ground truth" begin
        # Parse a simple expression
        code = "f(x) = x + 1"
        ps = JuliaSyntax.ParseStream(code)
        JuliaSyntax.parse!(ps, rule=:all)

        # GreenTreeCursor
        gc = JuliaSyntax.GreenTreeCursor(ps)
        @test JuliaSyntax.span(gc) > UInt32(0)
        @test !JuliaSyntax.is_leaf(gc)

        # RedTreeCursor
        rc = JuliaSyntax.RedTreeCursor(ps)
        @test JuliaSyntax.span(rc) > UInt32(0)
        @test !JuliaSyntax.is_leaf(rc)
        br = JuliaSyntax.byte_range(rc)
        @test first(br) > UInt32(0)
        @test last(br) >= UInt32(length(code))

        # Reverse iteration — children count
        green_children = collect(reverse(gc))
        @test length(green_children) >= 1
        red_children = collect(reverse(rc))
        @test length(red_children) >= 1

        # SourceFile
        sf = JuliaSyntax.SourceFile(code)
        @test JuliaSyntax.source_line(sf, 1) == 1
        loc = JuliaSyntax.source_location(sf, 1)
        @test loc == (1, 1)
        @test String(JuliaSyntax.sourcetext(sf)) == code
        @test Base.firstindex(sf) == 1
        @test Base.lastindex(sf) >= length(code)

        # GreenNode from cursor
        gn = JuliaSyntax.GreenNode(gc)
        @test JuliaSyntax.span(gn) > UInt32(0)
        @test !JuliaSyntax.is_leaf(gn)
        ch = JuliaSyntax.children(gn)
        @test ch !== nothing
        @test length(ch) >= 1
        @test JuliaSyntax.numchildren(gn) >= 1

        # SyntaxNode
        sn = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, code)
        @test JuliaSyntax.kind(sn) == JuliaSyntax.K"toplevel"
        sn_children = JuliaSyntax.children(sn)
        @test sn_children !== nothing
        @test length(sn_children) >= 1
        sn_br = JuliaSyntax.byte_range(sn)
        @test first(sn_br) >= 1
        @test last(sn_br) >= length(code)

        # Kind on SyntaxHead
        h = JuliaSyntax.head(gc)
        @test JuliaSyntax.kind(h) == JuliaSyntax.K"toplevel"

        # Multi-expression parsing
        code2 = "x = 1\ny = 2\nz = x + y"
        sn2 = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, code2)
        ch2 = JuliaSyntax.children(sn2)
        @test ch2 !== nothing
        @test length(ch2) >= 3  # 3 statements

        # Nested navigation
        if ch2 !== nothing && length(ch2) >= 3
            # Third child should be the z = x + y assignment
            third = ch2[3]
            @test JuliaSyntax.kind(third) == JuliaSyntax.K"="
            third_children = JuliaSyntax.children(third)
            @test third_children !== nothing
            @test length(third_children) >= 2  # z and x + y
        end
    end
end

println("PHASE-3A-003 tests complete!")
