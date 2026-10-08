using Test

_wt_bottom_throw(x::Int64) = throw(ArgumentError("bottom-$x"))
_wt_interpolation_length(x::Int64)::Int64 = length("value=$x")
function _wt_bottom_catch(x::Int64)::Int64
    try
        _wt_bottom_throw(x)
        return 0
    catch err
        return err isa ArgumentError ? 1 : 2
    end
end

function _wt_typeassert_payload(x::Int64)::Int64
    try
        typeassert(x, String)
        return 0
    catch err
        return err isa TypeError && err.expected === String && err.got isa Int64 ? 1 : 2
    end
end

_wt_bottom_invoke_catch(x::Int32)::Int32 = try
    div(Int32(0), Int32(typemax(Int64)))
catch
    x
end

_wt_bounds_helper_catch(x::Int64)::Int64 = try
    [x][0]
    0
catch err
    err isa BoundsError ? 1 : 2
end

_wt_inexact_helper_catch(x::Int64)::Int64 = try
    Int32(typemax(Int64))
    0
catch err
    err isa InexactError ? 1 : 2
end

_wt_domain_helper_catch(x::Int64)::Int64 = try
    sin(Inf)
    0
catch err
    err isa DomainError ? 1 : 2
end

_wt_overflow_helper_catch(x::Int64)::Int64 = try
    Base.checked_add(typemax(Int64), x)
    0
catch err
    err isa OverflowError ? 1 : 2
end

@testset "Union{} bodies preserve their real exception" begin
    @test compare_julia_wasm(_wt_bottom_catch, Int64(7)).pass
    @test compare_julia_wasm(_wt_typeassert_payload, Int64(7)).pass
    @test compare_julia_wasm(_wt_bottom_invoke_catch, Int32(7)).pass
    @test compare_julia_wasm(_wt_bounds_helper_catch, Int64(1)).pass
    @test compare_julia_wasm(_wt_inexact_helper_catch, Int64(1)).pass
    @test compare_julia_wasm(_wt_domain_helper_catch, Int64(1)).pass
    @test compare_julia_wasm(_wt_overflow_helper_catch, Int64(1)).pass
    @test compare_julia_wasm(_wt_interpolation_length, typemax(Int64)).pass
    @test compare_julia_wasm(_wt_interpolation_length, typemin(Int64)).pass
end

# An exception that escapes an export to the host leaves Julia's exception stack as the call
# found it: the host is the catching frame (jl_restore_excstack). The next call's `rethrow()`
# outside a catch raises Julia's ErrorException, never the escaped exception (it did: 1, not 2).
_wt_export_escape(x::Int64) = x > 0 ? throw(ArgumentError("escaped")) : x
_wt_export_rethrow(x::Int64) = try; rethrow(); catch e; e isa ArgumentError ? 1 : (e isa ErrorException ? 2 : 3); end + x
_wt_export_nested(x::Int64) = try; throw(DomainError(1)); catch; try; rethrow(); catch e2; e2 isa DomainError ? 1 : (e2 isa ArgumentError ? 2 : 3); end; end + x

@testset "an exception escaping an export leaves the stack as the call found it" begin
    native_rethrow = (try; _wt_export_escape(1); catch; end; _wt_export_rethrow(0))
    native_nested = (try; _wt_export_escape(1); catch; end; _wt_export_nested(0))
    @test (native_rethrow, native_nested) == (2, 1)
    bytes = WasmTarget.compile_multi([(_wt_export_escape, (Int64,)), (_wt_export_rethrow, (Int64,)),
                                      (_wt_export_nested, (Int64,))])
    driver = """
    const importObject = {};
    $(WasmRunner.HOST_RUNTIME_MERGE_JS)
    const { instance } = await WebAssembly.instantiate(bytes, importObject, { builtins: ['js-string'] });
    const ex = instance.exports;
    const call = (f, a) => { try { return Number(f(a)); } catch (e) { return (e instanceof WebAssembly.Exception) ? -1 : -2; } };
    const out = [call(ex['_wt_export_escape'], 1n), call(ex['_wt_export_rethrow'], 0n),
                 call(ex['_wt_export_escape'], 1n), call(ex['_wt_export_nested'], 0n)];
    return [{ ok: out }];
    """
    status, results = WasmRunner.run_driver_batch(bytes, driver; ninputs=1)
    @test status === :ok
    @test results[1]["ok"] == [-1, native_rethrow, -1, native_nested]
end

# The export boundary for every escape (batch 110; dev/formal/ExceptionStack.tla): one instance,
# a host-declared import `cb` that calls an export back and `cbt` that throws a JS error. Each
# escape is told apart by `e instanceof WebAssembly.Exception` (a Julia exception) or the JS
# error's class, never by a bare catch.
_wt_eb_r(x::Int64) = (try; rethrow(); catch e; e isa ArgumentError ? 1 : e isa DomainError ? 3 : e isa DivideError ? 4 : e isa ErrorException ? 2 : 5; end) + x
@noinline _wt_eb_rec(n::Int64) = n == 0 ? 0 : 1 + _wt_eb_rec(n - 1)
_wt_eb_s(x::Int64) = try; throw(ArgumentError("a")); catch; _wt_eb_rec(x); end
_wt_eb_b(x::Int64) = x > 0 ? throw(DomainError(x)) : x
_wt_eb_d(x::Int64) = x > 0 ? throw(DivideError()) : x
@noinline _wt_eb_cb(x::Int64) = (_wt_eb_b(x); nothing)
@noinline _wt_eb_cbd(x::Int64) = (_wt_eb_d(x); nothing)
@noinline _wt_eb_cbt(x::Int64) = (error("dom"); nothing)
# H5: the callee's escape unwinds through the import into the caller's catch, which reads it
_wt_eb_h5(x::Int64) = try; _wt_eb_cb(x); 0; catch; try; rethrow(); catch e2; e2 isa DomainError ? 1 : 2; end; end
# A12P2: one object thrown twice is two entries
_wt_eb_p2(x::Int64) = try; throw(DivideError()); catch; try; _wt_eb_cbd(x); catch; try; rethrow(ArgumentError("f")); catch; end; end; try; rethrow(); catch e; e isa DivideError ? 1 : 2; end; end
# an import that throws a JS error inside an open catch
_wt_eb_it(x::Int64) = try; throw(ArgumentError("o")); catch; _wt_eb_cbt(x); 0; end
# a deliberate trap inside an open catch: an @inbounds read past a one-element vector, which wasm
# traps on (never run natively: it reads past the vector). No wasm construct catches a trap, so only
# the next top-level entry's reset clears the catch's entry; Julia's stack is empty once the call
# returns to the host either way
_wt_eb_tp(x::Int64) = try; throw(ArgumentError("q")); catch; (v = Int64[1]; @inbounds v[x + 10]); end
# a callback's tag escape into the caller's catch: the import's decrement never runs, so the
# landing restores the count the region's enter saved (else the next call is taken as re-entrant)
_wt_eb_lc(x::Int64) = try; _wt_eb_cb(x); 1; catch; 0; end

@testset "the export boundary restores Julia's stack for every catchable escape" begin
    native = Dict("h5" => _wt_eb_h5(1), "p2" => _wt_eb_p2(1),
                  "s_then_r" => (try; _wt_eb_s(10^8); catch; end; _wt_eb_r(0)),
                  "it_then_r" => (try; _wt_eb_it(1); catch; end; _wt_eb_r(0)),
                  "trap_then_r" => _wt_eb_r(0), "lc_trap_then_r" => (_wt_eb_lc(1); _wt_eb_r(0)))
    @test native == Dict("h5" => 1, "p2" => 1, "s_then_r" => 2, "it_then_r" => 2, "trap_then_r" => 2,
                         "lc_trap_then_r" => 2)
    mod = WasmTarget.WasmModule()
    sig = (WasmTarget.WasmValType[WasmTarget.I64], WasmTarget.WasmValType[])
    ids = [WasmTarget.add_import!(mod, "host", n, sig...) for n in ("cb", "cbd", "cbt")]
    bytes = WasmTarget.compile_multi(Any[(_wt_eb_r, (Int64,), "r"), (_wt_eb_s, (Int64,), "s"), (_wt_eb_b, (Int64,), "b"),
                                         (_wt_eb_d, (Int64,), "d"), (_wt_eb_h5, (Int64,), "h5"), (_wt_eb_p2, (Int64,), "p2"),
                                         (_wt_eb_it, (Int64,), "it"), (_wt_eb_tp, (Int64,), "tp"),
                                         (_wt_eb_lc, (Int64,), "lc")];
        existing_module=mod,
        import_stubs=Any[(_wt_eb_cb, "cb", (Int64,), ids[1], Nothing), (_wt_eb_cbd, "cbd", (Int64,), ids[2], Nothing),
                         (_wt_eb_cbt, "cbt", (Int64,), ids[3], Nothing)])
    driver = """
    const importObject = $(WasmTarget.host_runtime_js());
    let inst;
    importObject.host = { cb: (x) => inst.exports.b(x), cbd: (x) => inst.exports.d(x), cbt: (x) => { throw new TypeError('dom'); } };
    const { instance } = await WebAssembly.instantiate(bytes, importObject, { builtins: ['js-string'] });
    inst = instance; const ex = instance.exports;
    const call = (f, a) => { try { return String(ex[f](a)); } catch (e) { return (e instanceof WebAssembly.Exception) ? 'julia' : (e instanceof WebAssembly.RuntimeError) ? 'trap' : ('js:' + e.constructor.name); } };
    const s = call('s', 100000000n); const r1 = call('r', 0n);
    const it = call('it', 1n); const r2 = call('r', 0n);
    const tp = call('tp', 3n); const r3 = call('r', 0n);
    const lc = call('lc', 1n); const tp2 = call('tp', 3n); const r4 = call('r', 0n);
    return [{ ok: [call('h5', 1n), call('p2', 1n), s, r1, it, r2, tp, r3, lc, tp2, r4] }];
    """
    status, results = WasmRunner.run_driver_batch(bytes, driver; ninputs=1, deadline=60.0)
    @test status === :ok
    @test results[1]["ok"] == [string(native["h5"]), string(native["p2"]), "js:RangeError", string(native["s_then_r"]),
                               "js:TypeError", string(native["it_then_r"]), "trap", string(native["trap_then_r"]),
                               "0", "trap", string(native["lc_trap_then_r"])]
end

# Each function this compile defines is exported once, by its entry when the module has the
# exception stack; a function export the compile's link_roots hook adds takes its entry too; an
# export the module held before the compile is left as it was (A12B3 = A12E4 = A12C5); a host
# import is named "<module.field> (import)" (dart functions.dart:141)
@testset "each export is made once: the compile's and its hook's by their entries, a prior one left alone" begin
    mod = WasmTarget.WasmModule()
    WasmTarget.ensure_provenance_imports!(mod)
    pre = WasmTarget.add_function!(mod, WasmTarget.WasmValType[], WasmTarget.WasmValType[],
                                   WasmTarget.WasmValType[], UInt8[0x0b]; name="pre")
    WasmTarget.add_export!(mod, "pre", 0, pre)
    m = WasmTarget.compile_module(Any[(_wt_export_escape, (Int64,), "esc")]; existing_module=mod,
        link_roots=(lm, roots, _) -> WasmTarget.add_export!(lm, "esc_hook", 0, roots["esc"]))
    exported(n) = only(e for e in m.exports if e.name == n).idx
    fname(i) = m.functions[Int(i) - WasmTarget.num_imported_funcs(m) + 1].name
    @test exported("pre") == pre && fname(pre) == "pre"
    @test fname(exported("esc")) == "esc (export)"
    @test fname(exported("esc_hook")) == "esc_hook (export)"
    @test count(e -> e.kind == 0x00 && fname(e.idx) == "esc (export)", m.exports) == 1
    @test any(imp -> imp.function_name == "wasmtarget.stack_trace (import)", m.imports)
end
