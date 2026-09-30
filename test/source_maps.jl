# A module compiled with a source map names, for every wasm byte offset a statement emitted,
# the Julia source it came from (its innermost frame, named by its inline chain), so a trap an
# engine reports as a byte offset is located the way a compile-time rejection is
# (dart2wasm's source maps, pkg/wasm_builder/lib/source_map.dart; dev/CHARTER.md C10).
using Test
using WasmTarget
isdefined(@__MODULE__, :WasmRunner) || include(joinpath(@__DIR__, "wasm_runner.jl"))
using .WasmRunner

const _SMT = WasmTarget

_smt_down(x::Int64) = _smt_down(x + 1) + 1          # line 12: the recursive call
_smt_entry(x::Int64) = x > 0 ? _smt_down(x) : 0
_smt_boom(x::Int64) = x > 0 ? error("boom") : x      # line 14: the throw
_smt_mid(x::Int64) = _smt_boom(x) + 1
_smt_rethrow(x::Int64) = try; _smt_boom(x) + 1; catch; rethrow(); end

@testset "source maps: the builder records dart's mappings" begin
    m = _SMT.WasmModule()
    m.source_map_url = "t.map"
    b = _SMT.InstrBuilder(; mod=m)
    @test _SMT.records_source_maps(b)
    @test !_SMT.records_source_maps(_SMT.InstrBuilder(; mod=_SMT.WasmModule()))  # no URL: no recording
    s1 = _SMT.SourceInfo("a.jl", 0, 0, "f")
    s2 = _SMT.SourceInfo("a.jl", 4, 0, "g")
    _SMT.start_source_mapping!(b, s1)
    _SMT.start_source_mapping!(b, s2)          # same instruction: replaces the last
    _SMT.i64_const!(b, 1)
    _SMT.start_source_mapping!(b, s2)          # same source as the last: adds nothing
    _SMT.i64_const!(b, 2)
    _SMT.stop_source_mapping!(b)
    @test b.source_mappings == [_SMT.SourceMapping(0, s2), _SMT.SourceMapping(2, nothing)]
    # a fragment's mappings land shifted by where its instructions do
    frag = _SMT.InstrBuilder(; mod=m)
    _SMT.start_source_mapping!(frag, s1)
    _SMT.i64_const!(frag, 3)
    _SMT.append_builder!(b, frag)
    @test b.source_mappings[end] == _SMT.SourceMapping(2, s1)
    # serialized: instruction indices become the byte offsets of those instructions
    code, mapped = _SMT.builder_code_mapped(b)
    @test mapped[1] == _SMT.SourceMapping(0, s2)
    @test mapped[end].info === nothing && mapped[end].offset == length(code)
end

@testset "source maps: a body's mappings are where its bytes are in the module" begin
    mod = _SMT.compile_function(_smt_entry, (Int64,), "_smt_entry"; source_map_url="m.map")
    bytes, json = _SMT.to_bytes_with_source_map(mod)
    segs = WasmRunner._source_map_segments(WasmRunner.JSON.parse(json)["mappings"])
    offsets = Set(s[1] for s in segs)
    checked = 0
    for f in mod.functions
        isempty(f.mappings) && continue
        # the body's start in the module, from its first mapping; every mapping must then be a
        # module offset the map lists, and the module must hold the body's bytes there
        local start = nothing
        for s in segs, m in f.mappings
            m.info === nothing && continue
            cand = s[1] - m.offset
            if cand >= 0 && cand + length(f.body) <= length(bytes) &&
               bytes[cand + 1:cand + length(f.body)] == f.body
                start = cand
                break
            end
        end
        @test start !== nothing
        start === nothing && continue
        @test all(m -> m.info === nothing || (start + m.offset) in offsets, f.mappings)
        checked += 1
    end
    @test checked >= 2
    # the recursive call's own line is mapped, named by its inline chain
    sm = WasmRunner.JSON.parse(json)
    @test any(n -> occursin("_smt_down @ ", n) && occursin("source_maps.jl:12", n), sm["names"])
    @test occursin("sourceMappingURL", String(copy(bytes)))
end

@testset "source maps: a trap names the Julia statement of each frame" begin
    for optimize in (false, true)
        bytes, json = _SMT.compile_with_sourcemap(_smt_entry, (Int64,); optimize=optimize)
        status, msg = WasmRunner.run_wasm_single(bytes, "_smt_entry", "1n"; source_map=json)
        @test status === :trap
        @test occursin("Maximum call stack size exceeded", msg)
        # the frames resolve to the recursive call at line 12 of this file
        @test occursin(r"_smt_down @ .*source_maps\.jl:12", msg)
    end
    # a module compiled without a map carries no sourceMappingURL section
    plain = _SMT.compile(_smt_entry, (Int64,))
    @test !occursin("sourceMappingURL", String(copy(plain)))
end

@testset "source maps: an uncaught Julia exception names its throw site" begin
    # the tag's stack slot carries the JS stack captured at the throw (emit_throw_current!),
    # which the runner reads from the exported tag and names through the map
    bytes, json = _SMT.compile_with_sourcemap(_smt_mid, (Int64,))
    status, msg = WasmRunner.run_wasm_single(bytes, "_smt_mid", "1n"; source_map=json)
    @test status === :trap && startswith(msg, "uncaught Julia exception")
    @test occursin(r"_smt_boom @ .*source_maps\.jl:14", msg)
    @test occursin("Base.error @ ", msg)
    # every module has the import and the tag export, source map or not (one module shape)
    plain = _SMT.compile(_smt_mid, (Int64,))
    @test occursin("stack_trace", String(copy(plain))) && occursin("wasmtarget.exception", String(copy(plain)))
    # a rethrow throws the stack its catch received, so the escaped exception still names its
    # first throw (dart's rethrow throws stackTraceLocal; Julia's rethrow keeps the backtrace)
    rbytes, rjson = _SMT.compile_with_sourcemap(_smt_rethrow, (Int64,))
    status, msg = WasmRunner.run_wasm_single(rbytes, "_smt_rethrow", "1n"; source_map=rjson)
    @test status === :trap && startswith(msg, "uncaught Julia exception")
    @test occursin(r"_smt_boom @ .*source_maps\.jl:14", msg)
end

# One module shape: recording a source map maps the code and changes none of it. The mapped
# build is the plain build with the `sourceMappingURL` section after it, so the differential
# lanes, which run the mapped build to locate a failure, run the module a user gets
# (dev/AUDIT.md H2; dart's source map option only adds mappings).
@testset "source maps: the mapped build is the plain build plus its URL section" begin
    for (f, T) in ((_smt_entry, (Int64,)), (_smt_mid, (Int64,)))
        plain = WasmTarget.compile(f, T)
        mapped, _ = WasmTarget.compile_with_sourcemap(f, T; sourcemap_url="m.map")
        @test length(mapped) > length(plain)
        @test mapped[1:length(plain)] == plain
        @test mapped[length(plain) + 1] == 0x00          # a custom section
        @test occursin("sourceMappingURL", String(mapped[length(plain) + 1:end]))
    end
end
