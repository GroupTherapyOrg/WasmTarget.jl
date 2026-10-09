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

# The export boundary for every escape (dev/formal/ExceptionStack.tla): one instance, instantiated
# through the glue (host_glue_js), a host-declared import `cb` that calls an export back and `cbt`
# that throws a JS error. Each escape is told apart by `e instanceof WebAssembly.Exception` (a
# Julia exception) or the JS error's class, never by a bare catch.
_wt_eb_r(x::Int64) = (try; rethrow(); catch e; e isa ArgumentError ? 1 : e isa DomainError ? 3 : e isa DivideError ? 4 : e isa ErrorException ? 2 : 5; end) + x
@noinline _wt_eb_rec(n::Int64) = n == 0 ? 0 : 1 + _wt_eb_rec(n - 1)
_wt_eb_s(x::Int64) = try; throw(ArgumentError("a")); catch; _wt_eb_rec(x); end
# each native stack exhaustion runs on a task of its own, a fresh stack and guard page: repeated
# overflows on one Windows thread crashed the process (0xC0000005, Julia 1.13 on CI). Compiled in
# a closure, a direct call's try is elided (stack exhaustion is not an effect): invokelatest
_wt_own_task(f) = fetch(schedule(Task(f)))
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
# traps on (never run natively: it reads past the vector). No wasm construct catches a trap: the
# next top-level entry's reset clears the catch's entry; Julia's stack is empty once the call
# returns to the host either way
_wt_eb_tp(x::Int64) = try; throw(ArgumentError("q")); catch; (v = Int64[1]; @inbounds v[x + 10]); end
# a callback's tag escape into the caller's catch: the glue's finally lowers the count as the
# escape leaves the import (else the next call is taken as re-entrant)
_wt_eb_lc(x::Int64) = try; _wt_eb_cb(x); 1; catch; 0; end
# Julia's J2: a re-entrant callee reads its caller's stack. `cbr` calls the export `r` back from
# inside `o`'s catch, so r's `rethrow()` rethrows o's ArgumentError (native 1); counted as
# top-level, r's entry would reset the stack and answer 2 (dev/AUDIT.md A13E2)
@noinline _wt_eb_cbr(x::Int64) = _wt_eb_r(x)
_wt_eb_o(x::Int64) = try; throw(ArgumentError("a")); catch; _wt_eb_cbr(x); end
# a region entered inside a re-entrant call lands a nested callback's escape: the count after it
# is the glue's (1, `cb2` still open), so the `cbr` after `cb2` is re-entrant and `r` reads o2's
# ArgumentError (native 1); taken as top-level, r's entry would reset the stack and answer 2
# (A13E2). The stub keeps lc's call (donotdelete): lc catches everything, so Julia infers the
# stub effect-free and deletes its call
@noinline _wt_eb_cb2(x::Int64) = (Base.donotdelete(_wt_eb_lc(x)); nothing)
_wt_eb_o2(x::Int64) = try; throw(ArgumentError("o")); catch; _wt_eb_cb2(x); _wt_eb_cbr(0); end

@testset "the export boundary restores Julia's stack for every catchable escape" begin
    native = Dict("h5" => _wt_eb_h5(1), "p2" => _wt_eb_p2(1),
                  "s_then_r" => _wt_own_task(() -> (try; Base.invokelatest(_wt_eb_s, 10^8); catch; end; _wt_eb_r(0))),
                  "it_then_r" => (try; _wt_eb_it(1); catch; end; _wt_eb_r(0)),
                  "trap_then_r" => _wt_eb_r(0), "lc_trap_then_r" => (_wt_eb_lc(1); _wt_eb_r(0)),
                  "o" => _wt_eb_o(0), "o2" => _wt_eb_o2(1), "o2_trap_then_r" => (_wt_eb_o2(1); _wt_eb_r(0)))
    @test native == Dict("h5" => 1, "p2" => 1, "s_then_r" => 2, "it_then_r" => 2, "trap_then_r" => 2,
                         "lc_trap_then_r" => 2, "o" => 1, "o2" => 1, "o2_trap_then_r" => 2)
    mod = WasmTarget.WasmModule()
    sig = (WasmTarget.WasmValType[WasmTarget.I64], WasmTarget.WasmValType[])
    ids = [WasmTarget.add_import!(mod, "host", n, sig...) for n in ("cb", "cbd", "cbt", "cb2")]
    push!(ids, WasmTarget.add_import!(mod, "host", "cbr", WasmTarget.WasmValType[WasmTarget.I64],
                                      WasmTarget.WasmValType[WasmTarget.I64]))
    m = WasmTarget.compile_module(Any[(_wt_eb_r, (Int64,), "r"), (_wt_eb_s, (Int64,), "s"), (_wt_eb_b, (Int64,), "b"),
                                      (_wt_eb_d, (Int64,), "d"), (_wt_eb_h5, (Int64,), "h5"), (_wt_eb_p2, (Int64,), "p2"),
                                      (_wt_eb_it, (Int64,), "it"), (_wt_eb_tp, (Int64,), "tp"),
                                      (_wt_eb_lc, (Int64,), "lc"), (_wt_eb_o, (Int64,), "o"), (_wt_eb_o2, (Int64,), "o2")];
        existing_module=mod,
        import_stubs=Any[(_wt_eb_cb, "cb", (Int64,), ids[1], Nothing), (_wt_eb_cbd, "cbd", (Int64,), ids[2], Nothing),
                         (_wt_eb_cbt, "cbt", (Int64,), ids[3], Nothing), (_wt_eb_cb2, "cb2", (Int64,), ids[4], Nothing),
                         (_wt_eb_cbr, "cbr", (Int64,), ids[5], Int64)])
    # every call of a host-declared import saves the top at its slot before and restores it after
    # a normal return (L156; dev/formal/ExceptionStack.tla ImportCall and ImportReturn), and the
    # boundary is the host's: no wasm code writes the count, and no entry holds a try or a local
    # (L156): the premises of every answer below
    @test unsaved_host_import_calls(m) == 0
    @test wasm_boundary_sites(m) == 0
    bytes = WasmTarget.to_bytes(m)
    driver = """
    const importObject = $(WasmTarget.host_runtime_js());
    let inst;
    importObject.host = { cb: (x) => inst.exports.b(x), cbd: (x) => inst.exports.d(x), cbt: (x) => { throw new TypeError('dom'); },
                          cb2: (x) => inst.exports.lc(x), cbr: (x) => inst.exports.r(x) };
    const { instance } = await WebAssembly.instantiate(bytes, ($(WasmTarget.host_glue_js()))(importObject), { builtins: ['js-string'] });
    inst = instance; const ex = instance.exports;
    const call = (f, a) => { try { return String(ex[f](a)); } catch (e) { return (e instanceof WebAssembly.Exception) ? 'julia' : (e instanceof WebAssembly.RuntimeError) ? 'trap' : ('js:' + e.constructor.name); } };
    const s = call('s', 100000000n); const r1 = call('r', 0n);
    const it = call('it', 1n); const r2 = call('r', 0n);
    const tp = call('tp', 3n); const r3 = call('r', 0n);
    const lc = call('lc', 1n); const tp2 = call('tp', 3n); const r4 = call('r', 0n);
    const o = call('o', 0n);
    const o2 = call('o2', 1n); const tp3 = call('tp', 3n); const r5 = call('r', 0n);
    return [{ ok: [call('h5', 1n), call('p2', 1n), s, r1, it, r2, tp, r3, lc, tp2, r4, o, o2, tp3, r5] }];
    """
    status, results = WasmRunner.run_driver_batch(bytes, driver; ninputs=1, deadline=60.0)
    @test status === :ok
    # `s` slot: stack exhaustion escapes as the engine's RangeError, where Julia raises a
    # StackOverflowError a Julia `catch` catches (dev/MARCH.md 13.17 H8): WT's current answer,
    # asserted as such. The `r` after it answers 2 through the next top-level call's reset
    @test results[1]["ok"] == [string(native["h5"]), string(native["p2"]), "js:RangeError", string(native["s_then_r"]),
                               "js:TypeError", string(native["it_then_r"]), "trap", string(native["trap_then_r"]),
                               "0", "trap", string(native["lc_trap_then_r"]), string(native["o"]),
                               string(native["o2"]), "trap", string(native["o2_trap_then_r"])]
end

# Escapes no wasm construct catches, at the boundary the host owns (dev/formal/ExceptionStack.tla):
# stack exhaustion inside a host-declared import or a re-entrant call, and a re-entrant trap the
# host catches or lets propagate. The glue's finally lowers the count on every exit of an import,
# a call site restores the top from its slot after a normal return, and a re-entrant entry takes
# the top from the open import's slot. A stub that calls an export back natively does so through
# invokelatest: Julia infers the callee nothrow (stack exhaustion is not an effect) and would elide
# a direct call's try. A trapping callee runs natively as one that raises an error the host
# catches (Julia's J2), as trap_then_r does above.
@noinline _wt_hb_rec(n::Int64) = n == 0 ? 0 : 1 + _wt_hb_rec(n - 1)
# the import variant: the import overflows the JS stack (natively its stub raises)
@noinline _wt_hb_cbo(x::Int64) = (error("dom"); nothing)
_wt_hb_a(x::Int64) = try; throw(ArgumentError("o")); catch; _wt_hb_cbo(x); 0; end
# the re-entrant variant: the host's cb calls s2 and catches its exhaustion
_wt_hb_s2(x::Int64) = try; throw(DomainError(x)); catch; _wt_hb_rec(10^8); end
@noinline _wt_hb_cb(x::Int64) = (try; Base.invokelatest(_wt_hb_s2, x); catch; end; nothing)
_wt_hb_o(x::Int64) = try; throw(ArgumentError("a")); catch; _wt_hb_cb(x); try; rethrow(); catch e; e isa ArgumentError ? 1 : 2; end; end
# o_again: then, inside the same import, cb calls r, which reads o's ArgumentError
@noinline _wt_hb_cbg(x::Int64) = (try; Base.invokelatest(_wt_hb_s2, x); catch; end; Base.invokelatest(_wt_eb_r, 0)::Int64)
_wt_hb_og(x::Int64) = try; throw(ArgumentError("a")); catch; _wt_hb_cbg(x); end
# h6: cb calls t6, which throws DomainError and traps in its catch; cb catches the trap
_wt_hb_t6(x::Int64) = try; throw(DomainError(x)); catch; (v = Int64[1]; @inbounds v[x + 10]); end
_wt_hb_t6n(x::Int64) = try; throw(DomainError(x)); catch; error("trap"); end
@noinline _wt_hb_cb6(x::Int64) = (try; Base.invokelatest(_wt_hb_t6n, x); catch; end; nothing)
_wt_hb_o6(x::Int64) = try; throw(ArgumentError("a")); catch; _wt_hb_cb6(x); try; rethrow(); catch e; e isa ArgumentError ? 1 : 2; end; end
# h7: cb7 lets t6's trap propagate through the import and out of o7
@noinline _wt_hb_cb7(x::Int64) = (Base.invokelatest(_wt_hb_t6n, x); nothing)
_wt_hb_o7(x::Int64) = try; throw(ArgumentError("a")); catch; _wt_hb_cb7(x); 0; end

@testset "the export boundary is the host's: stack exhaustion and traps leave Julia's stack" begin
    native = Dict("a_then_r" => (try; _wt_hb_a(1); catch; end; _wt_eb_r(0)), "o" => _wt_own_task(() -> _wt_hb_o(1)),
                  "o_again" => _wt_own_task(() -> _wt_hb_og(1)), "h6" => _wt_hb_o6(1), "h7_then_r" => (try; _wt_hb_o7(1); catch; end; _wt_eb_r(0)))
    @test native == Dict("a_then_r" => 2, "o" => 1, "o_again" => 1, "h6" => 1, "h7_then_r" => 2)
    mod = WasmTarget.WasmModule()
    v = (WasmTarget.WasmValType[WasmTarget.I64], WasmTarget.WasmValType[])
    ids = Dict(n => WasmTarget.add_import!(mod, "host", n, v...) for n in ("cbo", "cb", "cb6", "cb7"))
    ids["cbg"] = WasmTarget.add_import!(mod, "host", "cbg", WasmTarget.WasmValType[WasmTarget.I64],
                                        WasmTarget.WasmValType[WasmTarget.I64])
    m = WasmTarget.compile_module(Any[(_wt_eb_r, (Int64,), "r"), (_wt_hb_a, (Int64,), "a"), (_wt_hb_s2, (Int64,), "s2"),
                                      (_wt_hb_o, (Int64,), "o"), (_wt_hb_og, (Int64,), "og"), (_wt_hb_t6, (Int64,), "t6"),
                                      (_wt_hb_o6, (Int64,), "o6"), (_wt_hb_o7, (Int64,), "o7")];
        existing_module=mod,
        import_stubs=Any[(_wt_hb_cbo, "cbo", (Int64,), ids["cbo"], Nothing), (_wt_hb_cb, "cb", (Int64,), ids["cb"], Nothing),
                         (_wt_hb_cbg, "cbg", (Int64,), ids["cbg"], Int64), (_wt_hb_cb6, "cb6", (Int64,), ids["cb6"], Nothing),
                         (_wt_hb_cb7, "cb7", (Int64,), ids["cb7"], Nothing)])
    bytes = WasmTarget.to_bytes(m)
    host = """
    importObject.host = { cbo: (x) => { const f = (n) => f(n + 1) + 1; return f(0); },
                          cb: (x) => { try { inst.exports.s2(x); } catch (e) {} },
                          cbg: (x) => { try { inst.exports.s2(x); } catch (e) {} return inst.exports.r(0n); },
                          cb6: (x) => { try { inst.exports.t6(x); } catch (e) {} },
                          cb7: (x) => { inst.exports.t6(x); } };
    """
    driver = """
    const importObject = $(WasmTarget.host_runtime_js());
    let inst;
    $host
    const { instance } = await WebAssembly.instantiate(bytes, ($(WasmTarget.host_glue_js()))(importObject), { builtins: ['js-string'] });
    inst = instance; const ex = instance.exports;
    const call = (f, a) => { try { return String(ex[f](a)); } catch (e) { return (e instanceof WebAssembly.Exception) ? 'julia' : (e instanceof WebAssembly.RuntimeError) ? 'trap' : ('js:' + e.constructor.name); } };
    const a = call('a', 1n); const r1 = call('r', 0n);
    const o = call('o', 1n); const og = call('og', 1n); const o6 = call('o6', 1n);
    const o7 = call('o7', 1n); const r2 = call('r', 0n);
    return [{ ok: [a, r1, o, og, o6, o7, r2] }];
    """
    status, results = WasmRunner.run_driver_batch(bytes, driver; ninputs=1, deadline=60.0)
    @test status === :ok
    # `a` and `s2` escape as the engine's RangeError (H8, as the `s` slot above); t6's trap as a trap
    @test results[1]["ok"] == ["js:RangeError", string(native["a_then_r"]), string(native["o"]), string(native["o_again"]),
                               string(native["h6"]), "trap", string(native["h7_then_r"])]

    # the glue is the module's runtime too: a module with a host-declared import imports its count,
    # so a host that instantiates without the glue is refused, by name
    refused = """
    const importObject = $(WasmTarget.host_runtime_js());
    let inst;
    $host
    try { await WebAssembly.instantiate(bytes, importObject, { builtins: ['js-string'] }); return [{ ok: 'instantiated' }]; }
    catch (e) { return [{ ok: e.constructor.name + ': ' + e.message }]; }
    """
    status, results = WasmRunner.run_driver_batch(bytes, refused; ninputs=1)
    @test status === :ok
    @test startswith(results[1]["ok"], "LinkError: ") && occursin("wasmtarget", results[1]["ok"]) &&
          occursin("host_imports_open", results[1]["ok"])
    # the glue wraps exactly the module's host-declared imports (_is_host_declared_import), and the
    # module imports the count as a global
    declared = sort!([imp.module_name * "." * imp.field_name for imp in m.imports if WasmTarget._is_host_declared_import(imp)])
    @test declared == ["host.cb", "host.cb6", "host.cb7", "host.cbg", "host.cbo"]
    wrapped = """
    const importObject = $(WasmTarget.host_runtime_js());
    let inst;
    $host
    const glued = ($(WasmTarget.host_glue_js()))(importObject);
    const imports = WebAssembly.Module.imports(new WebAssembly.Module(bytes, { builtins: ['js-string'] }));
    const fns = imports.filter(i => i.kind === 'function').map(i => i.module + '.' + i.name);
    const changed = fns.filter(n => { const [m, f] = n.split('.'); return glued[m][f] !== importObject[m][f]; });
    const globals = imports.filter(i => i.kind === 'global').map(i => i.module + '.' + i.name);
    return [{ ok: [changed.sort(), globals, glued.wasmtarget.host_imports_open instanceof WebAssembly.Global] }];
    """
    status, results = WasmRunner.run_driver_batch(bytes, wrapped; ninputs=1)
    @test status === :ok
    @test results[1]["ok"] == Any[declared, ["wasmtarget.host_imports_open"], true]
end

# Every refusal the host's count brings names both the items it is between: the count import
# after a defined global, a host-declared import added after setup, and a global index that names
# the imported count, at each of the four entries that take one. A framework that defines its own
# globals before compiling imports the count itself (ensure_host_imports_open!).
@noinline function _wt_hb_gw(g::WasmGlobal{Int32,0})::Int32
    g[] = g[] + Int32(1)
    return g[]
end
_wt_hb_err(f) = (try; f(); nothing; catch err; err; end)

# The count is the instance's: the glued object hands each wrapped import and the count out once,
# to the instantiation that reads them. A host that called a glued import itself (after o(0n), the
# host calls the glued cbr, whose r answered 1 where Julia's top-level call answers 2), or two
# instances of one glued object (A's import calling B's r: B took a slot its own calls saved for
# another call, answering 1, or trapped on its null array), counted a call no call of the instance
# made (dev/AUDIT.md A14E1 = A14P1; ExceptionStack.tla HostCallsGlued). Both are refused, loudly.
_wt_gl_p(x::Int64) = x + 100
@testset "a glued import object serves one instance, and the host never calls a glued import" begin
    @test _wt_eb_o(0) == 1 && _wt_eb_r(0) == 2
    mod = WasmTarget.WasmModule()
    idx = WasmTarget.add_import!(mod, "host", "cbr", WasmTarget.WasmValType[WasmTarget.I64], WasmTarget.WasmValType[WasmTarget.I64])
    m = WasmTarget.compile_module(Any[(_wt_eb_r, (Int64,), "r"), (_wt_eb_o, (Int64,), "o"), (_wt_gl_p, (Int64,), "p")];
                                  existing_module=mod, import_stubs=Any[(_wt_eb_cbr, "cbr", (Int64,), idx, Int64)])
    bytes = WasmTarget.to_bytes(m)
    glue = WasmTarget.host_glue_js()
    status, results = WasmRunner.run_driver_batch(bytes, """
    const importObject = $(WasmTarget.host_runtime_js());
    let inst; importObject.host = { cbr: (x) => inst.exports.r(x) };
    const io = ($glue)(importObject);
    const { instance } = await WebAssembly.instantiate(bytes, io, { builtins: ['js-string'] });
    inst = instance;
    const out = [String(instance.exports.o(0n))];
    try { out.push(String(io.host.cbr(0n))); } catch (e) { out.push(String(e && e.message || e)); }
    try { await WebAssembly.instantiate(bytes, io, { builtins: ['js-string'] }); out.push('instantiated twice'); }
    catch (e) { out.push(String(e && e.message || e)); }
    out.push(String(instance.exports.r(0n)));
    return [{ ok: out }];
    """; ninputs=1)
    @test status === :ok
    out = results[1]["ok"]
    @test out[1] == "1"                                                        # o(0n), re-entrant: Julia's 1
    @test startswith(out[2], "the glued import host.cbr was read twice")       # the host's own call refused
    @test startswith(out[3], "the glued import host.cbr was read twice") ||
          startswith(out[3], "the glued import wasmtarget.host_imports_open was read twice")   # a second instance refused
    @test out[4] == "2"                                                        # a top-level r: Julia's 2
end

@testset "the host's count: each refusal names both its items" begin
    sig = (WasmTarget.WasmValType[WasmTarget.I64], WasmTarget.WasmValType[])
    roots = Any[(_wt_eb_r, (Int64,), "r")]
    # a global defined before setup: the count cannot precede it
    m1 = WasmTarget.WasmModule()
    WasmTarget.add_import!(m1, "host", "cb", sig...)
    WasmTarget.add_global!(m1, WasmTarget.I64, true, 0; name="\$mine")
    e1 = _wt_hb_err(() -> WasmTarget.compile_module(roots; existing_module=m1))
    @test e1 isa ArgumentError && occursin("host.cb", e1.msg) && occursin("\$mine", e1.msg) &&
          occursin("ensure_host_imports_open!", e1.msg)
    # the framework's path: the count imported after its host imports, before its own global
    m2 = WasmTarget.WasmModule()
    WasmTarget.add_import!(m2, "host", "cb", sig...)
    WasmTarget.ensure_host_imports_open!(m2)
    mine = WasmTarget.add_global!(m2, WasmTarget.I64, true, 0; name="\$mine")
    @test WasmTarget.global_named(m2, "\$host_imports_open") == 0 && mine == 1
    compiled = WasmTarget.compile_module(roots; existing_module=m2)
    @test success(pipeline(`wasm-tools validate --features=gc`; stdin=IOBuffer(WasmTarget.to_bytes(compiled))))
    # a host-declared import with no count (added after setup) is refused where the count is read
    m3 = WasmTarget.WasmModule()
    WasmTarget.add_import!(m3, "host", "late", sig...)
    e3 = _wt_hb_err(() -> WasmTarget.host_imports_open_global(m3))
    @test e3 isa ArgumentError && occursin("host.late", e3.msg) && occursin("wasmtarget.host_imports_open", e3.msg)
    # a global index naming the imported count, at each entry that takes one
    counted() = (m = WasmTarget.WasmModule(); WasmTarget.add_import!(m, "host", "cb", sig...);
                 WasmTarget.ensure_host_imports_open!(m); m)
    names_both(e, what) = e isa ArgumentError && occursin(what, e.msg) && occursin(" 0 ", e.msg) &&
                          occursin("wasmtarget.host_imports_open", e.msg)
    @test names_both(_wt_hb_err(() -> WasmTarget.compile_module(Any[(_wt_hb_gw, (WasmGlobal{Int32,0},), "gw")];
                                                                 existing_module=counted())), "WasmGlobal index")
    @test names_both(_wt_hb_err(() -> WasmTarget.add_root_global_initializer!(counted(), WasmTarget.TypeRegistry(), 0, 0)),
                     "framework global index")
    @test names_both(_wt_hb_err(() -> WasmTarget.compile_module(roots; existing_module=counted(),
                         root_bindings=Dict("r" => WasmTarget.RootBindings(captured_globals=Dict(:x => (true, UInt32(0))))))),
                     "captured global index")
    @test names_both(_wt_hb_err(() -> WasmTarget.compile_module(roots; existing_module=counted(),
                         root_bindings=Dict("r" => WasmTarget.RootBindings(dom_bindings=Dict(UInt32(0) => [(UInt32(0), Int32[])]))))),
                     "DOM binding global index")
    # a global the host imports for itself is not the count: a WasmGlobal names it, and the
    # program reads and writes the host's global
    hg = WasmTarget.WasmModule()
    @test WasmTarget.add_global_import!(hg, "host", "g", WasmTarget.I32, true) == 0
    hbytes = WasmTarget.to_bytes(WasmTarget.compile_module(Any[(_wt_hb_gw, (WasmGlobal{Int32,0},), "gw")]; existing_module=hg))
    status, results = WasmRunner.run_driver_batch(hbytes, """
    const importObject = $(WasmTarget.host_runtime_js());
    const g = new WebAssembly.Global({ value: 'i32', mutable: true }, 5);
    importObject.host = { g };
    const { instance } = await WebAssembly.instantiate(bytes, importObject, { builtins: ['js-string'] });
    const r = instance.exports.gw();
    return [{ ok: [r, g.value] }];
    """; ninputs=1)
    @test status === :ok && results[1]["ok"] == [6, 6]
end

# Each function this compile defines is exported once, by its entry when the module has the
# exception stack; a function export the compile's link_roots hook adds is retargeted to its entry
# after codegen (dev/MARCH.md 13.17 A13C2); an export the module held before the compile is left
# as it was (A12B3 = A12E4 = A12C5); a host import is named "<module.field> (import)" (dart
# functions.dart:141)
@noinline _wt_c1_x(n::Int64) = n + 1
@noinline _wt_c1_x_d2(n::Int64) = 10n
@noinline _wt_c1_inner(n::Int64) = n * 3
_wt_c1_outer(n::Int64) = _wt_c1_inner(n) + 1
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

    # a requested name the module already exports is refused, never renamed: a rename could hand
    # the host another entry's name. With the module exporting "x", the compile's "x" became
    # "x_d2", and the entry requested as "x_d2" became "x_d2_d2": exports.x_d2(2) answered x(2),
    # 3, where native x_d2(2) is 20 (dev/AUDIT.md A14C1)
    mod2 = WasmTarget.WasmModule()
    WasmTarget.ensure_provenance_imports!(mod2)
    pre2 = WasmTarget.add_function!(mod2, WasmTarget.WasmValType[], WasmTarget.WasmValType[],
                                    WasmTarget.WasmValType[], UInt8[0x0b]; name="pre")
    WasmTarget.add_export!(mod2, "x", 0, pre2)
    @test _wt_c1_x_d2(2) == 20
    err = try
        WasmTarget.compile_module(Any[(_wt_c1_x_d2, (Int64,), "x_d2"), (_wt_c1_x, (Int64,), "x")]; existing_module=mod2)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError && occursin("already exports \"x\"", err.msg)
    # two entries asking for one name, and one entry asked under two names, are refused
    err = try; WasmTarget.compile_module(Any[(_wt_c1_x, (Int64,), "f"), (_wt_c1_x_d2, (Int64,), "f")]); nothing; catch e; e; end
    @test err isa ArgumentError && occursin("two entries request the export name \"f\"", err.msg)
    err = try; WasmTarget.compile_module(Any[(_wt_c1_x, (Int64,), "f"), (_wt_c1_x, (Int64,), "g")]); nothing; catch e; e; end
    @test err isa ArgumentError && occursin("requested under two names", err.msg)
    # a name nobody requested that the module exports is still disambiguated: the module's
    # "_wt_c1_inner" export stays, the compile's discovered callee takes the next free name
    mod4 = WasmTarget.WasmModule()
    WasmTarget.ensure_provenance_imports!(mod4)
    pre4 = WasmTarget.add_function!(mod4, WasmTarget.WasmValType[], WasmTarget.WasmValType[],
                                    WasmTarget.WasmValType[], UInt8[0x0b]; name="pre")
    WasmTarget.add_export!(mod4, "_wt_c1_inner", 0, pre4)
    m4 = WasmTarget.compile_module(Any[(_wt_c1_outer, (Int64,), "outer")]; existing_module=mod4)
    @test count(e -> e.name == "_wt_c1_inner", m4.exports) == 1
    @test any(e -> e.name == "_wt_c1_inner_d2", m4.exports)

    # an export entry is a prologue with no local and no try, so a result that is not defaultable
    # (a hook's export of a function returning `(ref $t)`) leaves on the stack: the module
    # compiles, validates and runs (A13B1 = A13B6: the entry kept its results in locals across a
    # try_table and rejected such a result)
    mod3 = WasmTarget.WasmModule()
    WasmTarget.ensure_provenance_imports!(mod3)
    t3 = WasmTarget.add_type!(mod3, WasmTarget.StructType([WasmTarget.FieldType(WasmTarget.I64, false)]))
    mk = WasmTarget.add_function!(mod3, WasmTarget.WasmValType[], WasmTarget.WasmValType[WasmTarget.ConcreteRef(t3, false)],
                                  WasmTarget.WasmValType[], UInt8[0x42, 0x00, 0xfb, 0x00, UInt8(t3), 0x0b]; name="mk")
    m3 = WasmTarget.compile_module(Any[(_wt_export_escape, (Int64,), "esc")]; existing_module=mod3,
        link_roots=(lm, roots, _) -> WasmTarget.add_export!(lm, "mk", 0, mk))
    fname3(i) = m3.functions[Int(i) - WasmTarget.num_imported_funcs(m3) + 1].name
    @test fname3(only(e for e in m3.exports if e.name == "mk").idx) == "mk (export)"
    bytes3 = WasmTarget.to_bytes(m3)
    @test success(pipeline(`wasm-tools validate --features=gc`; stdin=IOBuffer(bytes3)))
    status, results = WasmRunner.run_driver_batch(bytes3, """
    const importObject = $(WasmTarget.host_runtime_js());
    const { instance } = await WebAssembly.instantiate(bytes, ($(WasmTarget.host_glue_js()))(importObject), { builtins: ['js-string'] });
    return [{ ok: typeof instance.exports.mk() }];
    """; ninputs=1)
    @test status === :ok && results[1]["ok"] == "object"
end
