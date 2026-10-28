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
    @test tfa isa DCm.TfaResult && tfa.component === world && tfa.module_strategy isa DCm.DefaultModuleStrategy
    # a compile that is not standalone needs the JS runtime, not yet ported: a located rejection
    local ns = DCm.WasmCompilerOptions(; main_uri = "", output_file = "p.wasm"); ns.translator_options.generate_source_maps = false
    local e = try; DCm.compile(ns, world); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Unported && occursin("RuntimeFinalizer", e.rejection.anchor)
    # the user-facing entry: WasmTarget.compile returns the main module's bytes
    local b2 = W.compile(CompileCases.f, (Int32,))
    @test b2[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d] && length(b2) == length(bytes)
    # source maps wait for a caller that names their file: a located rejection
    local sm = opts(); sm.translator_options.generate_source_maps = true
    local e2 = try; DCm.compile(sm, world); nothing; catch x; x; end
    @test e2 isa W.RejectionError && e2.rejection isa W.Unquarantined
    @test DCm.WasmCompilerOptions_id_for_module_name("prog.wasm", "prog_module3.wasm") == 3
    @test DCm.WasmCompilerOptions_id_for_module_name("prog.wasm", "other.wasm") === nothing
end
