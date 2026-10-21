using Test
using WasmTarget
using Random: Xoshiro
isdefined(@__MODULE__, :WasmReader) || include(joinpath(@__DIR__, "wasm_reader.jl"))

# A foreigncall whose lowering calls the host takes its import before any function is defined:
# an import is numbered ahead of every defined function, so one added later renumbers them
# under the calls already emitted to them.

@noinline _hi_inc(x::Int64)::Int64 = x + 1
@noinline _hi_mul(x::Int64)::Int64 = x * 100
_hi_clock(x::Int64)::Int64 = _hi_mul(x) + (time_ns() > 0 ? _hi_inc(x) : Int64(0))

@noinline function _hi_global_beside_rand(g::WasmGlobal{Int64,0})::Int64
    g[] = g[] + Int64(1)
    return rand() < 2.0 ? g[] : Int64(-1)
end

_hi_rand()::Float64 = rand()
_hi_rand_pair()::UInt64 = rand(UInt64) ⊻ rand(UInt64)

# `env.random_i64` answering the given words in order, as a JS closure
_hi_entropy(words) = "(() => { const s = [" *
    join(string.(reinterpret(Int64, collect(UInt64, words))) .* "n", ", ") *
    "]; let i = 0; return () => s[i++]; })()"

@testset "host imports precede every defined function" begin
    # time_ns() reads the host clock. Its import was once added while bodies compiled, and the
    # export `_hi_clock` then called the import: the module returned the clock's 1234.5.
    @test _hi_clock(Int64(3)) == 304
    bytes = WasmTarget.compile(_hi_clock, (Int64,); validate=true)
    clock = Dict{String,Any}("env" => Dict{String,Any}("perf_now" => "() => 1234.5"))
    @test run_wasm_with_imports(bytes, "_hi_clock", clock, Int64(3)) == 304

    # rand()'s state words are their own globals beside a WasmGlobal's: created first, they
    # took indices 0-3, and `WasmGlobal{Int64,0}` read and wrote the RNG's first state word.
    @test _hi_global_beside_rand(WasmGlobal{Int64,0}(0)) == 1
    bytes = WasmTarget.compile(_hi_global_beside_rand, (WasmGlobal{Int64,0},); validate=true)
    entropy = Dict{String,Any}("env" => Dict{String,Any}("random_i64" => _hi_entropy((1, 2, 3, 4))))
    @test run_wasm_with_imports(bytes, "_hi_global_beside_rand", entropy) == 1

    # The host seeds the RNG at startup, as Random.__init__ seeds the default RNG with four
    # draws from RandomDevice: given the same four words, the stream is Julia's own.
    words = (0x0123456789abcdef, 0xfedcba9876543210, 0x1111111122222222, 0x8000000000000001)
    entropy = Dict{String,Any}("env" => Dict{String,Any}("random_i64" => _hi_entropy(words)))
    bytes = WasmTarget.compile(_hi_rand, (); validate=true)
    @test run_wasm_with_imports(bytes, "_hi_rand", entropy) == rand(Xoshiro(words...))
    bytes = WasmTarget.compile(_hi_rand_pair, (); validate=true)
    native = let r = Xoshiro(words...); rand(r, UInt64) ⊻ rand(r, UInt64) end
    @test run_wasm_with_imports(bytes, "_hi_rand_pair", entropy) % UInt64 == native

    # the builder refuses an import after a definition
    mod = WasmTarget.WasmModule()
    let b = WasmTarget.InstrBuilder(; mod=mod)
        WasmTarget.finish_function!(b)
        WasmTarget.add_function!(mod, b; name="f")
    end
    @test_throws WasmTarget.ModuleValidationError WasmTarget.add_import!(mod, "env", "late",
        WasmTarget.WasmValType[], WasmTarget.WasmValType[])
end

# A declared import called only from a body the dynamic step enrolls in a later round: that
# round's compile! of the candidate infers the import's native fallback body with it, and
# every compile! output is cut by the declared imports before it merges, as the first
# collection is (collect_new_pairs!, dev/formal/ClosedWorld.tla LeavesNeverCollected). Merged
# uncut, the import's native body and its callee would enter the plan, and the callee's ccall,
# which WT does not lower, would reject the module. The native body is never run.
# Measured at batch 111: over smoke, the probes and the suite's other import tests, no later
# round reaches an import's body (0); this case is the first that does.
@noinline function _hi_late_native_only(x::Int64)::Int64
    native_offset = ccall(:jl_get_field_offset, Csize_t, (Any, Cint), Int, 0)
    Base.donotdelete(native_offset)
    return x * 1000 + 7
end
@noinline _hi_late_import(x::Int64)::Int64 = _hi_late_native_only(x)
abstract type _HiLateShape end
struct _HiLateA <: _HiLateShape; v::Int64; end
struct _HiLateB <: _HiLateShape; v::Int64; end
# six methods, so Julia leaves the call dynamic rather than splitting it over its classes
for (i, S) in enumerate((:_HiLateC, :_HiLateD, :_HiLateE, :_HiLateF))
    @eval struct $S <: _HiLateShape; v::Int64; end
    @eval @noinline _hi_late_area(s::$S)::Int64 = s.v + $(i + 1)
end
@noinline _hi_late_area(s::_HiLateA)::Int64 = _hi_late_import(s.v)
@noinline _hi_late_area(s::_HiLateB)::Int64 = s.v + 1
@noinline _hi_late_shapes(n::Int64) = _HiLateShape[_HiLateA(n), _HiLateB(n), _HiLateC(n), _HiLateD(n), _HiLateE(n), _HiLateF(n)]
function _hi_late_entry(n::Int64)::Int64
    xs = _hi_late_shapes(n)
    s = Int64(0)
    for x in xs
        s += _hi_late_area(x)::Int64
    end
    return s
end

@testset "an import reached in a later collection round is cut, as the first round's are" begin
    entry = WasmTarget.entry_method_instance(_hi_late_entry, (Int64,))
    leaf = WasmTarget.entry_method_instance(_hi_late_import, (Int64,))
    world = WasmTarget.collect_closed_world(Any[entry]; external_leaves=Set{Any}([leaf]))
    collected = [ci.def isa Core.MethodInstance ? ci.def : ci.def.def
                 for ci in world.codeinfos[1:2:end] if ci isa Core.CodeInstance]
    late_caller = which(_hi_late_area, (_HiLateA,))
    # the import's caller entered in a later round, as a dispatch candidate
    @test any(mi -> mi.def === late_caller, collected)
    @test any(mi -> mi.def === late_caller, world.dynamic_roots)
    # neither the import's native body nor its callee is in the closed world
    @test !any(mi -> mi.def === which(_hi_late_import, (Int64,)), collected)
    @test !any(mi -> mi.def === which(_hi_late_native_only, (Int64,)), collected)

    # end to end: the module compiles, and the call answers the host's import
    mod = WasmTarget.WasmModule()
    idx = WasmTarget.add_import!(mod, "host", "late", WasmTarget.WasmValType[WasmTarget.I64],
                                 WasmTarget.WasmValType[WasmTarget.I64])
    m = WasmTarget.compile_module(Any[(_hi_late_entry, (Int64,), "late_entry")];
        existing_module=mod, import_stubs=Any[(_hi_late_import, "late", (Int64,), idx, Int64)], options=WasmTarget.options_from_env())
    # the import is called from a dispatch candidate's body, enrolled in a later round: every
    # call of it saves the top at its slot and restores it, as the export boundary's claim needs
    # (L156)
    @test unsaved_host_import_calls(m) == 0
    bytes = WasmTarget.to_bytes(m)
    driver = """
    const importObject = $(WasmTarget.host_runtime_js(WasmTarget.function_import_names(m)));
    importObject.host = { late: (x) => x * 2n };
    const { instance } = await WebAssembly.instantiate(bytes, ($(WasmTarget.host_glue_js()))(importObject), { builtins: ['js-string'] });
    return [{ ok: String(instance.exports.late_entry(3n)) }];
    """
    status, results = WasmRunner.run_driver_batch(bytes, driver; ninputs=1)
    @test status === :ok
    @test results[1]["ok"] == "36"   # the import's 3 * 2, plus 3 + 1, 3 + 2, 3 + 3, 3 + 4, 3 + 5
end

# An import_stubs entry stands for a host import: an index that is not a host-declared function
# import is refused, naming the stub. Unchecked, the stub's calls ran whatever function held the
# index: `_hi_c2_f(1)` answered `_hi_c2_h`'s 0 where native is 4, and the module validated
# (dev/AUDIT.md A14C2).
@noinline _hi_c2_g(x::Int64)::Int64 = x + 1
_hi_c2_f(x::Int64)::Int64 = 2 * _hi_c2_g(x)
@noinline _hi_c2_h(x::Int64)::Int64 = x - 1
@testset "an import stub's index names a host import" begin
    @test _hi_c2_f(1) == 4
    for idx in (1, 2, 0)   # two defined functions, and WT's own `wasmtarget.stack_trace` import
        err = try
            WasmTarget.compile_multi(Any[(_hi_c2_f, (Int64,)), (_hi_c2_h, (Int64,))];
                                     import_stubs=Any[(_hi_c2_g, "g", (Int64,), idx, Int64)])
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && occursin("import stub \"g\"", err.msg) &&
              occursin("not a host-declared function import", err.msg)
    end
end

# A declared import's result is a value the host makes, which no collected body builds: its class
# is in the one class set by the statement rule (a statement concretely typed Int32), so the
# union-split MethodError for it is built (without it the call trapped where native answers -1)
@noinline _hi_int32_stub()::Int32 = Base.inferencebarrier(Int32(5))::Int32
_hi_int64_only(x::Int64) = 1
_hi_import_no_method(n::Int64) = (y = n > 0 ? n : _hi_int32_stub();
                                   try; _hi_int64_only(y)::Int64; catch e; e isa MethodError ? -1 : -2; end)
@testset "an import's result is a class of the one class set" begin
    @test _hi_import_no_method(Int64(-1)) == -1
    mod = WasmTarget.WasmModule()
    idx = WasmTarget.add_import!(mod, "host", "int32_stub", WasmTarget.WasmValType[], WasmTarget.WasmValType[WasmTarget.I32])
    m = WasmTarget.compile_module(Any[(_hi_import_no_method, (Int64,), "_hi_import_no_method")];
                                  existing_module=mod,
                                  import_stubs=Any[(_hi_int32_stub, "int32_stub", (), idx, Int32)], options=WasmTarget.options_from_env())
    @test unsaved_host_import_calls(m) == 0   # every call of the import saved and restored (L156)
    bytes = WasmTarget.to_bytes(m)
    imports = Dict{String,Any}("host" => Dict{String,Any}("int32_stub" => "() => 5"))
    @test run_wasm_with_imports(bytes, "_hi_import_no_method", imports, Int64(-1)) == -1
end

# The host runtime is generated per module, by the compile, from its own record of the imports it
# added (A2E4; dart's RuntimeFinalizer.generate over the translator's record,
# runtime_generator.dart:128, written beside the module, compile.dart:648-669): exactly the WT
# imports the module declares, answered. A module that reads the clock gets env.perf_now and no
# env.random_i64, one that draws random words the reverse; the runtime the compile hands back
# equals the one built from what the bytes declare (read back by test/wasm_reader.jl, an oracle),
# its fields equal the engine's own reading of the imports (WebAssembly.Module.imports), and the
# module instantiates with it and not with one field taken out of it
_hi_runtime_fields(bytes, rt) = WasmRunner.run_driver_batch(bytes, """
    const rt = $(rt);
    const given = Object.entries(rt).flatMap(([m, fs]) => Object.keys(fs).map(f => m + '.' + f)).sort();
    const declared = WebAssembly.Module.imports(await WebAssembly.compile(bytes, { builtins: ['js-string'] }))
        .filter(i => i.kind === 'function').map(i => i.module + '.' + i.name).sort();
    await WebAssembly.instantiate(bytes, rt, { builtins: ['js-string'] });
    const missing = [];
    for (const f of given) {
        const [m, n] = f.split('.');
        const cut = Object.fromEntries(Object.entries(rt).map(([k, fs]) => [k, Object.assign({}, fs)]));
        delete cut[m][n];
        try { await WebAssembly.instantiate(bytes, cut, { builtins: ['js-string'] }); missing.push(f + ' instantiated'); }
        catch (e) { missing.push(f + ' ' + e.constructor.name); }
    }
    return [{ ok: JSON.stringify({ given, declared, missing }) }];
    """; ninputs=1)
@testset "the host runtime is the module's own imports" begin
    for (f, has, lacks) in ((_hi_clock, "env.perf_now", "env.random_i64"), (_hi_rand, "env.random_i64", "env.perf_now"))
        local bytes, rt = WasmTarget.compile_with_runtime(f, f === _hi_clock ? (Int64,) : (); validate=true)
        @test rt == WasmReader.module_runtime_js(bytes)   # the compile's record is what the bytes declare
        local status, results = _hi_runtime_fields(bytes, rt)
        @test status === :ok
        local r = WasmRunner.JSON.parse(results[1]["ok"])
        @test r["given"] == r["declared"] == sort(["wasmtarget.stack_trace", has])   # exactly its imports
        @test !(lacks in r["given"])
        @test r["missing"] == [x * " LinkError" for x in r["given"]]   # each field it needs
    end
    # one method, over the record of a module's imports: the compile's own, handed back beside the bytes
    @test only(methods(WasmTarget.host_runtime_js)).sig == Tuple{typeof(WasmTarget.host_runtime_js),Vector{Tuple{String,String}}}
end

# One query reads an import by its function index (imported_function, wasm_builder's
# FunctionsBuilder._importedFunctions): the k-th function import, or nothing at a defined function's
# index; the import's call is a host-declared import's (saved and restored) by that answer alone
@testset "one query for the import at a function index" begin
    mod = WasmTarget.WasmModule()
    WasmTarget.ensure_provenance_imports!(mod)
    h = WasmTarget.add_import!(mod, "host", "late", WasmTarget.WasmValType[WasmTarget.I64], WasmTarget.WasmValType[WasmTarget.I64])
    n = WasmTarget.num_imported_funcs(mod)
    @test [(i.module_name, i.field_name) for i in (WasmTarget.imported_function(mod, k) for k in 0:n - 1)] ==
          [("wasmtarget", "stack_trace"), ("host", "late")]
    @test WasmTarget.imported_function(mod, n) === nothing
    @test WasmTarget._is_host_declared_import(WasmTarget.imported_function(mod, h))
    @test !WasmTarget._is_host_declared_import(WasmTarget.imported_function(mod, 0))
    m = WasmTarget.compile_module(Any[(_hi_late_entry, (Int64,), "late_entry")]; existing_module=mod,
        import_stubs=Any[(_hi_late_import, "late", (Int64,), h, Int64)], options=WasmTarget.options_from_env())
    @test unsaved_host_import_calls(m) == 0
    # the import section the bytes declare reads back as the module's imports
    @test WasmReader.module_function_imports(WasmTarget.to_bytes(m)) == [("wasmtarget", "stack_trace"), ("host", "late")]
end

# The test tool that reads a module's imports back (test/wasm_reader.jl, wasm_builder's
# Deserializer, which dart's tools and tests use): it checks the 8-byte preamble, reads each
# section within its size, reads the one import section to its exact end, refuses invalid UTF-8,
# reads each integer at the width its field has (a u32 at most 5 bytes, a heap type an s33) and a
# global import's type and mutability as dart's deserializers accept them: every malformed module
# refused by name, at the module's own byte offset, never read past or answered with a default
@testset "the module reader refuses a malformed module" begin
    pre = UInt8[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
    imp(contents...) = UInt8[0x02, length(contents), contents...]
    # one import "a"."b" of a function of type 0: count 1, name a, name b, kind 0, type 0
    one = (0x01, 0x01, UInt8('a'), 0x01, UInt8('b'), 0x00, 0x00)
    read(bytes) = WasmReader.module_function_imports(bytes)
    @test read(vcat(pre, imp(one...))) == [("a", "b")]
    @test read(pre) == Tuple{String,String}[]
    refused(bytes, needle) = (e = try; read(bytes); nothing; catch x; x; end;
                              e isa ArgumentError && occursin(needle, e.msg))
    @test refused(pre[1:7], "invalid Wasm preamble")                                      # too short
    @test refused(vcat(pre[1:4], UInt8[0x02, 0x00, 0x00, 0x00]), "invalid Wasm preamble") # version 2
    @test refused(vcat(UInt8[0x00, 0x61, 0x73, 0x6e], pre[5:8]), "invalid Wasm preamble") # magic
    @test refused(vcat(pre, UInt8[0x01, 0x10, 0x00]), "where 16 are read")                # a section past the end
    @test refused(vcat(pre, imp(one..., 0x00)), "1 byte(s) after its last import")         # a byte left over
    # the section ends inside an import: named at the module's byte 16, its end, not the section's 6
    @test refused(vcat(pre, imp(one[1:end-1]...)), "the section ends at byte 16, where a byte is read")
    @test refused(vcat(pre, imp(0x00), imp(0x00)), "2 import sections")                    # a second import section
    @test refused(vcat(pre, imp(0x01, 0x01, 0xff, 0x01, UInt8('b'), 0x00, 0x00)), "not valid UTF-8")
    @test refused(vcat(pre, imp(0x01, 0x01, UInt8('a'), 0x01, UInt8('b'), 0x01, 0x70, 0x00, 0x00)), "of kind 1")
    @test refused(vcat(pre, UInt8[0x00, 0x02, 0x01, 0xff]), "not valid UTF-8")             # a custom section's name
    # a u32 (a count, a length, an index) is at most 5 bytes, its 5th holding bits 28-31 alone:
    # ten bytes, six bytes, and five whose last holds bit 32 (the count 2^32) are refused
    @test refused(vcat(pre, UInt8[0x02, 0x0b], fill(0xff, 10), [0x01]), "past 32 bits")
    @test refused(vcat(pre, imp(0x81, fill(0x80, 8)..., 0x02, one[2:end]...)), "past 32 bits")
    @test refused(vcat(pre, imp(0x81, 0x80, 0x80, 0x80, 0x80, 0x00, one[2:end]...)), "past 32 bits")
    @test refused(vcat(pre, imp(0x80, 0x80, 0x80, 0x80, 0x10, one[2:end]...)), "past 32 bits")
    # five bytes are a u32 when the 5th holds bits 28-31 alone: the count 1, spelled long
    @test read(vcat(pre, imp(0x81, 0x80, 0x80, 0x80, 0x00, one[2:end]...))) == [("a", "b")]
    # a global import's heap type is an s33: at most 5 bytes, the 5th's two high bits its sign's
    # extension, so a ten-byte one is refused whatever its last byte (no ten-byte heap type is wasm)
    gref(ht...) = imp(0x01, 0x01, UInt8('a'), 0x01, UInt8('g'), 0x03, 0x64, ht..., 0x00)
    @test refused(vcat(pre, gref(fill(0x80, 9)..., 0x01)), "past 33 bits")
    @test refused(vcat(pre, gref(fill(0x80, 9)..., 0x7f)), "past 33 bits")
    @test refused(vcat(pre, gref(0xef, 0xff, 0xff, 0xff, 0x5f)), "past 33 bits")          # its high bits not the sign's
    # extern (-0x11) spelled in five bytes, and a type index, are heap types: read past, no function import
    @test read(vcat(pre, gref(0xef, 0xff, 0xff, 0xff, 0x7f))) == Tuple{String,String}[]
    @test read(vcat(pre, gref(0x00))) == Tuple{String,String}[]
    # a global import's value type is a number type, a reference type's prefix and its heap type,
    # or an abstract heap type's shorthand, as ValueType/RefType/HeapType.deserialize accept them;
    # its mutability is 0 or 1
    glob(vt...) = imp(0x01, 0x01, UInt8('a'), 0x01, UInt8('g'), 0x03, vt...)
    @test read(vcat(pre, glob(0x7f, 0x01))) == Tuple{String,String}[]                       # i32, mutable
    @test read(vcat(pre, glob(0x6f, 0x00))) == Tuple{String,String}[]                       # externref
    @test refused(vcat(pre, glob(0x40, 0x00)), "invalid heap type code -64")               # no such type
    @test refused(vcat(pre, glob(0x64, 0x40, 0x00)), "invalid heap type code -64")         # no such heap type
    @test refused(vcat(pre, glob(0x00, 0x05)), "a type index at byte")                     # an index, no prefix
    @test refused(vcat(pre, glob(0x7f, 0x05)), "neither 0 nor 1")                          # mutability 5
end
