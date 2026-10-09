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
function _smt_rethrow_other(x::Int64)
    try
        return _smt_boom(x) + 1
    catch
        rethrow(ArgumentError("another exception"))   # line 21: rethrow(e), not a new throw
    end
end

@testset "source maps: the builder records dart's mappings" begin
    m = _SMT.WasmModule(; source_map_url="t.map")
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
    # a fragment's mappings land shifted by where its instructions do, and the destination's own
    # mapping (here none: unmapped) resumes after them, so the fragment's last does not run on
    frag = _SMT.InstrBuilder(; mod=m, fragment=true)
    _SMT.start_source_mapping!(frag, s1)
    _SMT.i64_const!(frag, 3)
    _SMT.append_builder!(b, frag)
    @test b.source_mappings[end-1:end] == [_SMT.SourceMapping(2, s1), _SMT.SourceMapping(3, nothing)]
    # a source is its file's URI, as dart's Uri.file writes it: an absolute path a file:// URI (a
    # Windows drive path file:///C:/…), a relative one a relative reference, each character
    # outside the URI path set percent-encoded
    @test _SMT.source_file_uri("/home/u/a.jl") == "file:///home/u/a.jl"
    @test _SMT.source_file_uri("C:\\work\\a.jl") == "file:///C:/work/a.jl"
    @test _SMT.source_file_uri("./int.jl") == "./int.jl"
    @test _SMT.source_file_uri("none") == "none"
    @test _SMT.source_file_uri("/a b/c%d#e.jl") == "file:///a%20b/c%25d%23e.jl"
    @test _SMT.source_file_uri("/é.jl") == "file:///%C3%A9.jl"
    # serialized: instruction indices become the byte offsets of those instructions
    code, mapped = _SMT.builder_code_mapped(b)
    @test mapped[1] == _SMT.SourceMapping(0, s2)
    @test mapped[end].info === nothing && mapped[end].offset == length(code)
end

@testset "source maps: a body's mappings are where its bytes are in the module" begin
    mod = _SMT.compile_module([(_smt_entry, (Int64,), "_smt_entry")]; source_map_url="m.map")
    bytes, json = _SMT.to_bytes_with_source_map(mod)
    segs = WasmRunner._source_map_segments(WasmRunner.JSON.parse(json)["mappings"])
    offsets = Set(s[1] for s in segs)
    checked = 0
    for f in mod.functions
        # a body no statement emitted (a generated function) records only its end (dart's
        # serializer ends every body with `addMapping(s.offset, null)`, instructions.dart:78)
        all(m -> m.info === nothing, f.mappings) && continue
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
    # the map's sources are file URIs: this file's, and no bare absolute path
    @test _SMT.source_file_uri(@__FILE__) in sm["sources"]
    @test startswith(_SMT.source_file_uri(@__FILE__), "file:///")
    @test !any(src -> startswith(src, "/") || occursin('\\', src), sm["sources"])
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

@testset "source maps: rethrow(e) keeps its throw's stack" begin
    # Julia's rethrow(e) replaces the exception and keeps the backtrace (jl_rethrow_other), as
    # dart's rethrow throws its catch's stackTraceLocal (code_generator.dart:2966): the stack
    # the host reads from the escaped tag (getArg(tag, 1)) still names the first throw, and
    # not the rethrow's line (dev/AUDIT.md A4B9 = A4P5)
    @test try; _smt_rethrow_other(1); false; catch e; e isa ArgumentError; end
    bytes, json = _SMT.compile_with_sourcemap(_smt_rethrow_other, (Int64,))
    status, msg = WasmRunner.run_wasm_single(bytes, "_smt_rethrow_other", "1n"; source_map=json)
    @test status === :trap && startswith(msg, "uncaught Julia exception")
    @test occursin(r"_smt_boom @ .*source_maps\.jl:14", msg)
    @test !occursin(r"source_maps\.jl:21\b", msg)
end

# One module shape: recording a source map maps the code and changes none of it. The mapped
# build is the plain build with the `sourceMappingURL` section after it, so the differential
# lanes, which run the mapped build to locate a failure, run the module a user gets
# (dev/AUDIT.md H2; dart's source map option only adds mappings).
@testset "source maps: the mapped build is the plain build plus its URL section" begin
    # unoptimized and through wasm-opt, which strips or keeps names for both builds alike
    for (f, T) in ((_smt_entry, (Int64,)), (_smt_mid, (Int64,))), optimize in (false, true)
        plain = WasmTarget.compile(f, T; optimize)
        mapped, _ = WasmTarget.compile_with_sourcemap(f, T; sourcemap_url="m.map", optimize)
        @test length(mapped) > length(plain)
        @test mapped[1:length(plain)] == plain
        @test mapped[length(plain) + 1] == 0x00          # a custom section
        @test occursin("sourceMappingURL", String(mapped[length(plain) + 1:end]))
    end
end

# One compile entry (src/WasmTarget.jl `_compile`, dart's compile.dart:216): the source-map and
# trace entries take the caller's diagnostics ledger, and the source-map entries the framework
# keywords compile_multi takes, because each is one call of the same entry.
_smt_reject(x::Any) = Int64(x) + 1          # an unresolved dynamic call: rejected at its statement
@noinline _smt_host_stub(x::Int64)::Int64 = x + 1
_smt_host_entry(x::Int64)::Int64 = _smt_host_stub(x) * 2

@testset "source maps: every entry takes the caller's diagnostics ledger" begin
    for entry in ((f, T; kw...) -> _SMT.compile_with_sourcemap(f, T; kw...),
                  (f, T; kw...) -> _SMT.compile_with_statement_trace(f, T; kw...))
        sink = _SMT.WasmDiagnostic[]
        err = try; entry(_smt_reject, (Any,); diagnostics_sink=sink); nothing; catch e; e; end
        @test err isa _SMT.WasmCompileError
        @test !isempty(sink) && err.diag in sink
        @test _SMT.DIAGNOSTICS_SINK[] === nothing
    end
    # an unknown keyword raises, never dropped
    @test_throws MethodError _SMT.compile_with_sourcemap(_smt_entry, (Int64,); no_such_keyword=1)
end

@testset "source maps: a host's module, mapped, is compile_multi's module plus its URL section" begin
    # the host's module records source maps from its construction (dart ModuleBuilder.sourceMapUrl)
    host(url=nothing) = (m = _SMT.WasmModule(; source_map_url=url);
              (m, _SMT.add_import!(m, "host", "stub", _SMT.WasmValType[_SMT.I64], _SMT.WasmValType[_SMT.I64])))
    m1, i1 = host()
    plain = _SMT.compile_multi([(_smt_host_entry, (Int64,), "host_entry")]; existing_module=m1,
                               import_stubs=Any[(_smt_host_stub, "stub", (Int64,), i1, Int64)])
    m2, i2 = host("m.map")
    mapped, json = _SMT.compile_multi_with_sourcemap([(_smt_host_entry, (Int64,), "host_entry")];
                       sourcemap_url="m.map", existing_module=m2,
                       import_stubs=Any[(_smt_host_stub, "stub", (Int64,), i2, Int64)])
    @test length(mapped) > length(plain)
    @test mapped[1:length(plain)] == plain
    @test mapped[length(plain) + 1] == 0x00          # a custom section
    @test occursin("sourceMappingURL", String(mapped[length(plain) + 1:end]))
    @test !isempty(WasmRunner.JSON.parse(json)["mappings"])
end

# Every byte of a function compiled from Julia IR maps to its statement or, outside its
# statements, to its definition (dart sets the member's offset before the body,
# code_generator.dart:3625, and restores it after each statement, :721); only a statement Julia
# gives no location is unmapped (:196). Each body's mappings end at its end
# (instructions.dart:78), so no function borrows another's segment.
_smt_line(x::Int64) = (x * 3 + 1) ÷ 2
function _smt_loop(n::Int64)
    s = 0
    for i in 1:n
        s += i * i
    end
    return s
end
_smt_try(x::Int64) = try; x > 0 ? error("e") : x; catch; -1; end
@noinline _smt_apply(f, y::Int64) = f(y)
_smt_clo(x::Int64) = _smt_apply(y -> y * x, 3)
_smt_fin(x::Int64) = (r = 0; try; try; x > 0 && error("a"); finally; r += 1; end; catch; r += 10; end; r)
_smt_tu(x::Int64) = x > 0 ? x * 2 : throw(DomainError(x))   # its body ends in a structural unreachable
# a closure that writes its captured cell: code follows a statement inside its block, which maps
# to the definition only through compile_statement!'s `finally`
@noinline _smt_cap(x::Int64) = (c = x; () -> (c = c + 1; c))
_smt_counter(x::Int64) = (f = _smt_cap(x); f(); f())
module _SMSel
struct A x::Int32 end; struct B x::Int32 end; struct C x::Int32 end; struct D x::Int32 end
f2(::A, ::A) = Int32(11); f2(::B, ::A) = Int32(21); f2(::C, ::A) = Int32(31); f2(::D, ::A) = Int32(41)
gf2(x::Any, y::Any)::Int32 = f2(x, y)
mkA(v::Int32) = A(v); mkB(v::Int32) = B(v); mkC(v::Int32) = C(v); mkD(v::Int32) = D(v)
end
const _SMT_SEL = [(_SMSel.f2, (_SMSel.A, _SMSel.A)), (_SMSel.f2, (_SMSel.B, _SMSel.A)),
                  (_SMSel.f2, (_SMSel.C, _SMSel.A)), (_SMSel.f2, (_SMSel.D, _SMSel.A)),
                  (_SMSel.gf2, (Any, Any)), (_SMSel.mkA, (Int32,)), (_SMSel.mkB, (Int32,)),
                  (_SMSel.mkC, (Int32,)), (_SMSel.mkD, (Int32,))]

# each defined function's instruction bytes in the module, [start, stop) 0-based, read from the
# code section; and the module's mappings as the writer produced them
function _smt_layout(mod)
    bytes, mms = _SMT.to_bytes_mapped(mod)
    leb(p) = (v = 0; s = 0; while true; b = bytes[p]; p += 1; v |= Int(b & 0x7f) << s; s += 7; b & 0x80 == 0 && break; end; (v, p))
    funcs = NamedTuple{(:name, :start, :stop),Tuple{String,Int,Int}}[]
    p = 9
    while p <= length(bytes)
        id = bytes[p]; size, q = leb(p + 1)
        if id == 0x0a
            n, r = leb(q)
            for k in 1:n
                esz, r = leb(r)
                push!(funcs, (name=mod.functions[k].name, start=r + esz - 1 - length(mod.functions[k].body), stop=r + esz - 1))
                r += esz
            end
        end
        p = q + size
    end
    return bytes, mms, funcs
end

# a statement Julia gives no location: its own line index is 0, or its line-info nodes are
# empty (Base's decoding of the DebugInfo, read here independently of WT's)
_smt_noloc(di, i) = (t = Base.IRShow.getdebugidx(di, i); Int(t[1]) <= 0 || isempty(Base.IRShow.buildLineInfoNode(di, di.def, i)))

# For each function the module defines: its unmapped instruction bytes (a function compiled from
# Julia IR), the bytes one function's segment covers in another, and, where the traced compile
# gives the function's CodeInfo, the count of its statements Julia gives no location.
function _smt_coverage(mod, codes::Dict{UInt32,Core.CodeInfo})
    _, mms, funcs = _smt_layout(mod)
    offs = [m.offset for m in mms]
    owner(o) = findfirst(r -> r.start <= o <= r.stop, funcs)
    nimp = _SMT.num_imported_funcs(mod)
    rows = NamedTuple[]
    for (k, fn) in enumerate(funcs)
        julia = _SMT.generated_function_construct(fn.name) === nothing
        unmapped = 0; borrowed = 0
        for b in fn.start:fn.stop - 1
            j = searchsortedlast(offs, b)
            mapped = j > 0 && mms[j].info !== nothing
            if mapped && owner(offs[j]) != k
                borrowed += 1
            elseif !mapped && julia
                unmapped += 1
            end
        end
        ci = get(codes, UInt32(nimp + k - 1), nothing)
        noloc = ci === nothing ? 0 : count(i -> _smt_noloc(ci.debuginfo, i), eachindex(ci.code))
        push!(rows, (name=fn.name, julia=julia, unmapped=unmapped, borrowed=borrowed, noloc=noloc))
    end
    return rows
end

# measured on Julia 1.12.7: each Julia-compiled function's unmapped bytes, all of them inside a
# statement whose line-info nodes are empty
const _SMT_UNMAPPED_112 = Dict(
    "straight-line" => Dict("_smt_line" => 3),
    "loop with phis" => Dict("_smt_loop" => 10),
    "try/catch" => Dict("_smt_try" => 7),
    "closure" => Dict("_smt_clo" => 3, "_smt_apply" => 3),
    "selector caller" => Dict(n => 3 for n in ("mkA", "mkB", "mkC", "mkD", "f2", "f2_1", "f2_2", "f2_3", "convert")),
    "standalone rethrow body" => Dict("_smt_fin" => 3),
    "code after a statement in its block" => Dict("_smt_counter" => 24, "_smt_cap" => 3, "+" => 3))

@testset "source maps: every byte of a function compiled from Julia IR is mapped" begin
    for (label, fns, entry) in (("straight-line", [(_smt_line, (Int64,))], "_smt_line"),
                                ("loop with phis", [(_smt_loop, (Int64,))], "_smt_loop"),
                                ("try/catch", [(_smt_try, (Int64,))], "_smt_try"),
                                ("closure", [(_smt_clo, (Int64,))], "_smt_clo"),
                                ("selector caller", _SMT_SEL, "gf2"),
                                ("standalone rethrow body", [(_smt_fin, (Int64,))], "_smt_fin"),
                                ("code after a statement in its block", [(_smt_counter, (Int64,))], "_smt_counter"))
        # compiled with its source map and traced, so each function's CodeInfo is known
        trace = _SMT.StatementTrace(entry)
        mod = _SMT.compile_module(fns; source_map_url="m.map", trace)
        codes = Dict{UInt32,Core.CodeInfo}(idx => trace.codes[id] for (idx, id) in trace.ids)
        rows = _smt_coverage(mod, codes)
        @test count(r -> r.julia, rows) >= 1
        # no function borrows another's segment
        @test sum(r -> r.borrowed, rows) == 0
        # a function compiled from Julia IR has unmapped bytes only if Julia gives one of its
        # statements no location (a selector caller and a standalone body are mapped whole)
        @test isempty([(r.name, r.unmapped) for r in rows if r.julia && r.unmapped > 0 && r.noloc == 0])
        # on 1.12, whose typed IR the probe baseline records too, the unmapped bytes are exactly
        # the measured ones: each the code of a statement Julia gives no location (an implicit
        # `return`'s local.get and return, a `goto` whose inlined frame has no line)
        if VERSION < v"1.13-"
            @test Dict(r.name => r.unmapped for r in rows if r.julia && r.unmapped > 0) == _SMT_UNMAPPED_112[label]
        end
    end
    # the whole-body arms are present in the programs above
    sel = _SMT.compile_module(_SMT_SEL; source_map_url="m.map")
    whole(f, needle) = length(f.mappings) == 2 && f.mappings[1].offset == 0 &&
                       occursin(needle, something(f.mappings[1].info).name) &&
                       f.mappings[2] == _SMT.SourceMapping(length(f.body), nothing)
    @test any(f -> f.name == "gf2" && whole(f, "gf2 @ "), sel.functions)
    fin = _SMT.compile_module([(_smt_fin, (Int64,))]; source_map_url="m.map")
    @test any(f -> startswith(f.name, "rethrow") && whole(f, "rethrow @ "), fin.functions)
end

@testset "source maps: a frame outside every statement names the function's definition" begin
    mod = _SMT.compile_module([(_smt_tu, (Int64,))]; source_map_url="m.map")
    bytes, mms, funcs = _smt_layout(mod)
    k = findfirst(f -> f.name == "_smt_tu", funcs)
    body = mod.functions[k].body
    @test body[end - 1] == _SMT.Opcode.UNREACHABLE   # the trailing structural unreachable
    json = _SMT.source_map_json(mms)
    idx = _SMT.num_imported_funcs(mod) + k - 1
    frame(o) = "Error\n    at _smt_tu (wasm://wasm/0123abcd:wasm-function[$idx]:0x$(string(o; base=16)))"
    # the trailing unreachable: unmapped before, it printed "no statement" (then E9's line)
    located = WasmRunner.located_frames(frame(funcs[k].stop - 2), json, bytes)
    @test length(located) == 1
    @test occursin(r"\._smt_tu @ .*source_maps\.jl:\d+$", located[1])
end

@testset "source maps: a statement with no location of its own is unmapped, never its predecessor's" begin
    # _smt_line's `return %3` carries a line index whose line-info nodes are empty: Julia gives
    # it no location, and its code (the return's local.get) is unmapped, as dart stops mapping
    # at a node with no offset (code_generator.dart:196)
    ci, _ = _SMT.get_typed_ir(_smt_line, (Int64,))
    @test _smt_noloc(ci.debuginfo, length(ci.code)) && ci.code[end] isa Core.ReturnNode
    @test _SMT.stmt_source_info((; debuginfo=ci.debuginfo), length(ci.code)) === nothing
    mod = _SMT.compile_module([(_smt_line, (Int64,))]; source_map_url="m.map")
    bytes, mms, funcs = _smt_layout(mod)
    k = findfirst(f -> f.name == "_smt_line", funcs)
    offs = [m.offset for m in mms]
    un = [b for b in funcs[k].start:funcs[k].stop - 1 if (j = searchsortedlast(offs, b); j == 0 || mms[j].info === nothing)]
    @test !isempty(un)
    frame = "Error\n    at _smt_line (wasm://wasm/0123abcd:wasm-function[$(_SMT.num_imported_funcs(mod) + k - 1)]:0x$(string(first(un); base=16)))"
    @test WasmRunner.located_frames(frame, _SMT.source_map_json(mms), bytes) ==
          ["`_smt_line`: a statement with no source location in Julia's IR"]
    # a rejection there names the definition and says the statement has none of its own
    fr = _SMT.stmt_frames(ci.debuginfo, length(ci.code))
    @test length(fr) == 1 && occursin("_smt_line", fr[1]) && occursin("no source location in Julia's IR", fr[1])
end

# An escaped exception names its type. The host reads the escaped value's class through the
# module's one exported reader (`wasmtarget.class_id`, emit_class_id!'s rule over `Any`) from
# the tag's payload, after any rethrow(e) replaced it, and prints it as dart's minified build
# does, `minified:Class<id>` (type.dart:344); the source map carries the class names
# (dart's addMinifiedClassNames, source_map_utils.dart:15), so the runner names the type, and
# wasm-opt's map gets them back (io_util.dart:162-171, :206-211).
struct _SmtEscErr <: Exception; x::Int; end
_smt_esc_arg(x::Int64) = x > 0 ? throw(ArgumentError("a")) : x
_smt_esc_dom(x::Int64) = x > 0 ? throw(DomainError(x)) : x
_smt_esc_user(x::Int64) = x > 0 ? throw(_SmtEscErr(x)) : x
_smt_esc_nothing(x::Int64) = x > 0 ? throw(nothing) : x
function _smt_esc_rethrow(x::Int64)
    try
        x > 0 && throw(ArgumentError("first"))                           # the first throw
        return x
    catch
        rethrow(DomainError(1))
    end
end
function _smt_esc_memory(x::Int64)
    u = Memory{UInt64}(undef, 1); u[1] = UInt64(x)
    m = Memory{Int64}(undef, 1); m[1] = x
    x > 5 && throw(u)
    x > 0 && throw(m)
    return x
end

@testset "source maps: an escaped exception names its type" begin
    # (i) each named through the map; with no map, dart's minified text, whose id the map names
    for (f, name) in ((_smt_esc_arg, "ArgumentError"), (_smt_esc_dom, "DomainError"),
                      (_smt_esc_user, string(_SmtEscErr)), (_smt_esc_nothing, "Nothing"))
        @test try; f(1); false; catch e; string(typeof(e)) == name; end
        bytes, json = _SMT.compile_with_sourcemap(f, (Int64,))
        status, msg = WasmRunner.run_wasm_single(bytes, string(nameof(f)), "1n"; source_map=json)
        @test status === :trap && startswith(msg, "uncaught Julia exception $name\n")
        status, msg = WasmRunner.run_wasm_single(_SMT.compile(f, (Int64,)), string(nameof(f)), "1n")
        m = match(r"^uncaught Julia exception (minified:Class\d+)$", msg)
        @test status === :trap && m !== nothing
        m === nothing || @test WasmRunner.escaped_class_name(m.captures[1], json) == name
    end
    # (ii) rethrow(e) replaces the exception, so the escape is DomainError's, while its stack is
    # still the first throw's (L145)
    @test try; _smt_esc_rethrow(1); false; catch e; e isa DomainError; end
    bytes, json = _SMT.compile_with_sourcemap(_smt_esc_rethrow, (Int64,))
    status, msg = WasmRunner.run_wasm_single(bytes, "_smt_esc_rethrow", "1n"; source_map=json)
    @test status === :trap && startswith(msg, "uncaught Julia exception DomainError\n")
    first_throw = findfirst(l -> occursin("throw(ArgumentError(\"first\"))", l), readlines(@__FILE__))
    @test occursin(Regex("source_maps\\.jl:$(first_throw)\\b"), msg)
    # (iii) through wasm-opt: the optimized map carries the class names again
    bytes, json = _SMT.compile_with_sourcemap(_smt_esc_rethrow, (Int64,); optimize=true)
    @test _SMT.minified_class_names(json) !== nothing
    status, msg = WasmRunner.run_wasm_single(bytes, "_smt_esc_rethrow", "1n"; source_map=json)
    @test status === :trap && startswith(msg, "uncaught Julia exception DomainError\n")
    # (iv) a bare array whose wasm type two classes share has no class to read: the reader
    # traps at its cast, and the host says the class could not be read, in the reader's frame
    bytes, json = _SMT.compile_with_sourcemap(_smt_esc_memory, (Int64,))
    status, msg = WasmRunner.run_wasm_single(bytes, "_smt_esc_memory", "1n"; source_map=json)
    @test status === :trap && startswith(msg, "the escaped exception's class could not be read: ")
    @test occursin("`wasmtarget.class_id`: class id of an escaped exception", msg)
    @test !occursin("Memory", msg)
end

# (v) a class the closed world numbers only through a later collection round (a dispatch
# candidate's body, in a module with a host import): the reader reads the final numbering
abstract type _SmtLateShape end
struct _SmtLateErr <: Exception; v::Int64; end
for (i, S) in enumerate((:_SmtLateA, :_SmtLateB, :_SmtLateC, :_SmtLateD, :_SmtLateE, :_SmtLateF))
    @eval struct $S <: _SmtLateShape; v::Int64; end
    i > 1 && @eval @noinline _smt_late_area(s::$S)::Int64 = s.v + $i
end
@noinline _smt_late_stub(x::Int64)::Int64 = x + 1
@noinline _smt_late_area(s::_SmtLateA)::Int64 = s.v > 2 ? throw(_SmtLateErr(_smt_late_stub(s.v))) : s.v
@noinline _smt_late_shapes(n::Int64) =
    _SmtLateShape[_SmtLateB(n), _SmtLateC(n), _SmtLateD(n), _SmtLateE(n), _SmtLateF(n), _SmtLateA(n)]
_smt_late_entry(n::Int64)::Int64 = (s = Int64(0); for x in _smt_late_shapes(n); s += _smt_late_area(x)::Int64; end; s)

@testset "source maps: the class reader reads the last round's classes" begin
    m = _SMT.WasmModule(; source_map_url="m.map")
    idx = _SMT.add_import!(m, "host", "stub", _SMT.WasmValType[_SMT.I64], _SMT.WasmValType[_SMT.I64])
    bytes, json = _SMT.compile_multi_with_sourcemap([(_smt_late_entry, (Int64,), "late_entry")];
                      sourcemap_url="m.map", existing_module=m,
                      import_stubs=Any[(_smt_late_stub, "stub", (Int64,), idx, Int64)])
    @test try; _smt_late_entry(3); false; catch e; e isa _SmtLateErr; end
    status, msg = WasmRunner.run_wasm_single(bytes, "late_entry", "3n";
                      import_js="const importObject = { host: { stub: (x) => x + 1n } };", source_map=json)
    @test status === :trap && startswith(msg, "uncaught Julia exception $(string(_SmtLateErr))\n")
    # every call of the import, in the later round's body too, is saved and restored (L156)
    m2 = _SMT.WasmModule()
    idx2 = _SMT.add_import!(m2, "host", "stub", _SMT.WasmValType[_SMT.I64], _SMT.WasmValType[_SMT.I64])
    @test unsaved_host_import_calls(_SMT.compile_module([(_smt_late_entry, (Int64,), "late_entry")]; existing_module=m2,
              import_stubs=Any[(_smt_late_stub, "stub", (Int64,), idx2, Int64)])) == 0
end

# The source map's JSON reader (src has no JSON dependency) reads JSON's grammar and nothing else:
# an escape outside `"\/bfnrtu`, a number token JSON does not allow, a surrogate without its
# other half, a raw control character in a string and a duplicate key are refused, never read as
# something else.
@testset "source maps: the map's JSON reader refuses what JSON does not allow" begin
    rd(t) = _SMT._json_read(t)
    @test rd("""{"names":["a\\/b","\\ud83d\\ude00","\\u00e9\\n"],"v":3,"x":-1.5e2}""") ==
          Pair{String,Any}["names" => Any["a/b", "😀", "é\n"], "v" => 3, "x" => -150.0]
    refused(t) = try; rd(t); false; catch e; e isa ErrorException && startswith(e.msg, "source map: "); end
    @test refused("""["\\x41"]""")          # an escape JSON does not have
    @test refused("""["\\'"]""")
    @test refused("""[+1]""")               # numbers JSON does not allow
    @test refused("""[Inf]""")
    @test refused("""[NaN]""")
    @test refused("""[01]""")
    @test refused("""[1.]""")
    @test refused("""["\\ud800"]""")        # a high surrogate with no low one
    @test refused("""["\\ud800\\u0041"]""")
    @test refused("""["\\udc00"]""")        # a low surrogate with no high one
    @test refused("""["\\u12"]""")          # fewer than four hex digits
    @test refused("[\"a\tb\"]")             # a raw control character inside a string
    @test refused("""{"k":1,"k":2}""")       # a duplicate key
end
