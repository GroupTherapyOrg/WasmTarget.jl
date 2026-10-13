using Test
using WasmTarget
using Random: Xoshiro

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
        existing_module=mod, import_stubs=Any[(_hi_late_import, "late", (Int64,), idx, Int64)])
    # the import is called from a dispatch candidate's body, enrolled in a later round: every
    # call of it saves the top at its slot and restores it, as the export boundary's claim needs
    # (L156)
    @test unsaved_host_import_calls(m) == 0
    bytes = WasmTarget.to_bytes(m)
    driver = """
    const importObject = $(WasmTarget.host_runtime_js(bytes));
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
                                  import_stubs=Any[(_hi_int32_stub, "int32_stub", (), idx, Int32)])
    @test unsaved_host_import_calls(m) == 0   # every call of the import saved and restored (L156)
    bytes = WasmTarget.to_bytes(m)
    imports = Dict{String,Any}("host" => Dict{String,Any}("int32_stub" => "() => 5"))
    @test run_wasm_with_imports(bytes, "_hi_import_no_method", imports, Int64(-1)) == -1
end

# The host runtime is generated per module (A2E4, dart's RuntimeFinalizer.generate,
# runtime_generator.dart:128): exactly the WT imports the module declares, answered. A module that
# reads the clock gets env.perf_now and no env.random_i64, one that draws random words the reverse;
# each instantiates with its own runtime, and not with one field taken out of it
_hi_runtime_fields(bytes) = WasmRunner.run_driver_batch(bytes, """
    const rt = $(WasmTarget.host_runtime_js(bytes));
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
        local bytes = WasmTarget.compile(f, f === _hi_clock ? (Int64,) : (); validate=true)
        local status, results = _hi_runtime_fields(bytes)
        @test status === :ok
        local r = WasmRunner.JSON.parse(results[1]["ok"])
        @test r["given"] == r["declared"] == sort(["wasmtarget.stack_trace", has])   # exactly its imports
        @test !(lacks in r["given"])
        @test r["missing"] == [x * " LinkError" for x in r["given"]]   # each field it needs
    end
    # one method, over the bytes a host instantiates: no runtime without its module
    @test only(methods(WasmTarget.host_runtime_js)).sig == Tuple{typeof(WasmTarget.host_runtime_js),Vector{UInt8}}
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
        import_stubs=Any[(_hi_late_import, "late", (Int64,), h, Int64)])
    @test unsaved_host_import_calls(m) == 0
    # the import section the bytes declare reads back as the module's imports
    @test WasmTarget.module_function_imports(WasmTarget.to_bytes(m)) == [("wasmtarget", "stack_trace"), ("host", "late")]
end
