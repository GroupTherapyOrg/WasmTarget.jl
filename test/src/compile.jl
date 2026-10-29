# dart2wasm's compile.dart, ported (src/compile.jl, dev/MARCH.md 1.D): the compile's phases over a
# program Julia's trim verifier accepted, the result its modules' bytes.
using Test
using WasmTarget

const DCm = WasmTarget.Dart2Wasm

module CompileCases
f(x::Int32) = x + Int32(1)
end

@testset "compile.dart: the phases, end to end" begin
    local W = WasmTarget
    local world = W.check_subset(CompileCases.f, (Int32,), "compile")
    local opts() = (o = DCm.WasmCompilerOptions(; main_uri = "", output_file = "out/prog.wasm"); o.translator_options.standalone = true; o.translator_options.generate_source_maps = false; o)
    # dart's library default phases: cfe, tfa, codegen
    local o = opts()
    @test o.phases == [DCm.CompilerPhase_cfe, DCm.CompilerPhase_tfa, DCm.CompilerPhase_codegen]
    local r = DCm.compile(o, world)
    @test r isa DCm.CodegenResult && r.main_wasm_file == "out/prog.wasm" && r.module_ids == Set([0])
    local bytes = r.wasm_files["prog.wasm"]
    @test bytes[1:8] == UInt8[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
    # the earlier phases alone: the world as given, then the module strategy
    local o1 = opts(); o1.phases = [DCm.CompilerPhase_cfe]
    @test DCm.compile(o1, world) isa DCm.CfeResult
    local o2 = opts(); o2.phases = [DCm.CompilerPhase_cfe, DCm.CompilerPhase_tfa]
    local tfa = DCm.compile(o2, world)
    @test tfa isa DCm.TfaResult && tfa.component isa W.NirWorld && tfa.component.entry === world.entry && tfa.module_strategy isa DCm.DefaultModuleStrategy
    # a dry run is the verifier's judgement, already made: it succeeds; a Kernel dump rejects
    local dr = opts(); dr.dry_run = true
    @test DCm.compile(dr, world) isa DCm.CompilationDryRunSuccess
    local dk = opts(); dk.dump_kernel_after_cfe = "k.txt"
    local ek = try; DCm.compile(dk, world); nothing; catch x; x; end
    @test ek isa W.RejectionError && ek.rejection isa W.Unquarantined
    # source maps wait for a caller that names their file: a located rejection
    local sm = opts(); sm.translator_options.generate_source_maps = true
    local e2 = try; DCm.compile(sm, world); nothing; catch x; x; end
    @test e2 isa W.RejectionError && e2.rejection isa W.Unquarantined
    @test DCm.WasmCompilerOptions_id_for_module_name("prog.wasm", "prog_module3.wasm") == 3
    @test DCm.WasmCompilerOptions_id_for_module_name("prog.wasm", "other.wasm") === nothing
    # the opt phase: wasm-opt over the module with dart's flags, the optimized module smaller
    local oo = opts(); push!(oo.phases, DCm.CompilerPhase_opt)
    local opt = DCm.compile(oo, world)
    @test opt isa DCm.OptResult && opt.num_modules == 1 && opt.main_wasm_file == "out/prog.wasm"
    local ob = opt.wasm_files["prog.wasm"]
    @test ob[1:8] == bytes[1:8] && length(ob) < length(bytes)
    # opt without codegen before it has no module to read: a located rejection
    local o3 = opts(); o3.phases = [DCm.CompilerPhase_opt]
    local e3 = try; DCm.compile(o3, world); nothing; catch x; x; end
    @test e3 isa W.RejectionError && e3.rejection isa W.Unquarantined
    # the user-facing entry optimizes by default, dartdev's phases; optimize = false stops at codegen
    @test W.compile(CompileCases.f, (Int32,)) == ob && W.compile(CompileCases.f, (Int32,); optimize = false) == bytes
    # dart's flags, verbatim: read from compile.dart at the pin where its checkout exists
    local dart = joinpath(homedir(), ".cache", "wasmtarget", "dart-sdk", "pkg", "dart2wasm", "lib", "compile.dart")
    if isfile(dart)
        local text = read(dart, String)
        local list(name) = [m[1] for m in eachmatch(r"'([^']*)'", match(Regex("const List<String> $name = \\[(.*?)\\];", "s"), text)[1])]
        @test DCm._binaryen_flags() == list("_binaryenFlags")
        @test DCm._binaryen_flags_multi_module() == list("_binaryenFlagsMultiModule")
    end
    # a module wasm-opt refuses rejects, located, never passes
    local e4 = try; W.run_wasm_opt(UInt8[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0xff], DCm._binaryen_flags(), "compile"); nothing; catch x; x; end
    @test e4 isa W.RejectionError && e4.rejection isa W.InvalidModule
end

isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "..", "runner.jl"))

@testset "compile.dart: the support JS tests the engine's features; the crash and the repository" begin
    # node, an engine with WasmGC and full SIMD, answers the feature test true
    local node = Main.WTRunner.node_binary()
    @test node !== nothing
    local support = DCm._generate_support_js(DCm.TranslatorOptions())
    @test readchomp(`perl -e 'alarm 30; exec @ARGV' $node -e "console.log($support)"`) == "true"
    @test count("WebAssembly.validate", DCm._generate_support_js(DCm.TranslatorOptions(; require_js_string_builtin = true))) == 3
    # a compile that is not standalone writes the JS runtime and the support JS beside the module, by
    # dart's file names; node parses the runtime as an ES module
    local ns = DCm.WasmCompilerOptions(; main_uri = "", output_file = "out/prog.wasm"); ns.translator_options.generate_source_maps = false
    local r = DCm.compile(ns, WasmTarget.check_subset(CompileCases.f, (Int32,), "compile"))
    @test r isa DCm.CodegenResult && collect(keys(r.js_files)) == ["out/prog.mjs", "out/prog.support.js"]
    @test r.js_files["out/prog.support.js"] == support
    mktempdir() do dir
        local path = joinpath(dir, "prog.mjs")
        write(path, r.js_files["out/prog.mjs"])
        @test success(pipeline(`perl -e 'alarm 30; exec @ARGV' $node --check $path`; stderr = devnull))
    end
    # a front end's crash prints dart's header, then its stack trace
    local crash = DCm.CFECrashError(ErrorException("boom"), stacktrace())
    @test startswith(sprint(show, crash), "CFECrashError(boom):\n")
    @test DCm.tag(DCm._RecordClassesRepository()) == "dart2wasm.recordClasses"
end
