# ============================================================================
# FuzzBridge — fuzz-harness runner over WasmTarget.Bridge
# ============================================================================
#
# The type-directed, bit-exact transport core (descriptors, accessor/ctor
# closures, JS walker, comparators) was PROMOTED into the package as
# `WasmTarget.Bridge` so downstream consumers (PlutoIslands.jl) share the one
# implementation. This module keeps the fuzz-specific part: `bridge_run`,
# which executes a compiled target + accessor closure over the harness's
# persistent Node runner pool.

module FuzzBridge

export bridge_run, descriptor, tree_matches, tree_decode, bridge_supported

using WasmTarget
using WasmTarget.Bridge
using WasmTarget.Bridge: WALK_JS, _mangle, _acc!, _FN_CACHE, _INTS, _build!
using JSON
using ..FuzzHarness: NODE_OK, DEFAULT_TIMEOUT, _js_inputs, run_driver_batch

# back-compat alias for fuzz files that referenced the old internal name
const _WALK_JS = WALK_JS

# ── Execution: compile target + accessor closure, run, return walked trees ───
"""
    bridge_run(fn, argtypes, inputs; rettype, strict=true, timeout, opt=false)

Compile `fn` together with the accessor closure for `rettype` and evaluate it
over every arg-tuple in `inputs` (scalar args) in one Node round-trip.
Returns a vector of `(:ok, tree)` / `(:trap, msg)` per input, `:unsupported`
if `rettype` is outside the bridge universe, or `(:compile_error => e)` /
`:no_node` for whole-batch failures.
"""
function bridge_run(fn, argtypes::Tuple, inputs::Vector; rettype::Type,
                    strict::Bool = true, timeout::Real = DEFAULT_TIMEOUT, opt = false,
                    discovery::Symbol = :legacy)
    NODE_OK || return :no_node
    dp = descriptor(rettype)
    dp === nothing && return :unsupported
    desc, accs = dp
    fname = string(nameof(fn))
    funcs = Any[(fn, argtypes, fname)]
    append!(funcs, accs)
    bytes = try
        WasmTarget.compile_multi(funcs; strict = strict, validate = true, optimize = opt,
                                 discovery = discovery)
    catch e
        return (:compile_error => e)
    end
    driver = """
    const inputs = $(_js_inputs(inputs));
    const _io = { write_string(){}, write_int(){}, write_float(){}, write_bool(){}, write_newline(){}, write_nothing(){} };
    const importObject = { Math: { pow: Math.pow }, io: _io };
    const { instance } = await WebAssembly.instantiate(bytes, importObject, { builtins: ['js-string'] });
    const ex = instance.exports;
    const f = ex['$fname'];
    const desc = $(JSON.json(desc));
    $WALK_JS
    return inputs.map(args => {
        try { return { ok: walk(desc, f(...args)) }; }
        catch (e) { return { trap: String(e && e.message || e) }; }
    });
    """
    status, results = run_driver_batch(bytes, driver; deadline = timeout, ninputs = length(inputs))
    status === :nonode && return :no_node
    status === :error && return (:exec_error => results)
    out = Vector{Tuple{Symbol,Any}}(undef, length(results))
    for (i, r) in enumerate(results)
        if r isa AbstractDict && haskey(r, "ok")
            out[i] = (:ok, r["ok"])
        else
            out[i] = (:trap, String(get(r, "trap", "unknown")))
        end
    end
    return out
end

end # module FuzzBridge
