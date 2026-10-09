# ============================================================================
# FuzzBridge — fuzz-harness runner over WasmTarget.Bridge
# ============================================================================
#
# The type-directed, bit-exact transport core (descriptors, accessor/ctor
# closures, JS walker, comparators) was PROMOTED into the package as
# `WasmTarget.Bridge` so downstream consumers (Snapshot.jl) share the one
# implementation. This module keeps the fuzz-specific part: `bridge_run`,
# which executes a compiled target + accessor closure over the harness's
# persistent Node runner pool.

module FuzzBridge

export bridge_run, descriptor, tree_matches, tree_decode, bridge_supported

using WasmTarget
using WasmTarget.Bridge
using WasmTarget.Bridge: WALK_JS, _mangle, _acc!, _FN_CACHE, _INTS, _build!
using JSON
using ..FuzzHarness: DEFAULT_TIMEOUT, _js_inputs, run_driver_batch
using ..FuzzHarness.WasmRunner: escaped_class_name

# back-compat alias for fuzz files that referenced the old internal name
const _WALK_JS = WALK_JS

# ── Execution: compile target + accessor closure, run, return walked trees ───
"""
    bridge_run(fn, argtypes, inputs; rettype, timeout, opt=false)

Compile `fn` together with the accessor closure for `rettype` and evaluate it
over every arg-tuple in `inputs` (scalar args) in one Node round-trip.
Returns a vector of `(:ok, tree)` / `(:throw, type)` (an escaped Julia exception, its type
named through the source map) / `(:trap, msg)` per input, `:unsupported`
if `rettype` is outside the bridge universe, or `(:compile_error => e)` for a
whole-batch failure.
"""
function bridge_run(fn, argtypes::Tuple, inputs::Vector; rettype::Type,
                    timeout::Real = DEFAULT_TIMEOUT, opt = false)
    dp = descriptor(rettype)
    dp === nothing && return :unsupported
    desc, accs = dp
    fname = string(nameof(fn))
    funcs = Any[(fn, argtypes, fname)]
    append!(funcs, accs)
    bytes, source_map = try
        WasmTarget.compile_multi_with_sourcemap(funcs; validate = true, optimize = opt)
    catch e
        return (:compile_error => e)
    end
    driver = """
    const inputs = $(_js_inputs(inputs));
    const importObject = $(WasmTarget.host_runtime_js());
    const { instance } = await WebAssembly.instantiate(bytes, importObject, { builtins: ['js-string'] });
    const ex = instance.exports;
    const f = ex['$fname'];
    const desc = $(JSON.json(desc));
    $WALK_JS
    const escape = $(WasmTarget.host_escape_js());
    return inputs.map(args => {
        try { return { ok: walk(desc, f(...args)) }; }
        catch (e) { const o = escape(ex, e); return o.throw !== undefined ? { throw: o.throw } : { trap: o.trap }; }
    });
    """
    status, results = run_driver_batch(bytes, driver; deadline = timeout, ninputs = length(inputs))
    status === :error && return (:exec_error => results)
    out = Vector{Tuple{Symbol,Any}}(undef, length(results))
    for (i, r) in enumerate(results)
        if r isa AbstractDict && haskey(r, "ok")
            out[i] = (:ok, r["ok"])
        elseif r isa AbstractDict && haskey(r, "throw")
            out[i] = (:throw, escaped_class_name(String(r["throw"]), source_map))
        else
            out[i] = (:trap, String(get(r, "trap", "unknown")))
        end
    end
    return out
end

end # module FuzzBridge
