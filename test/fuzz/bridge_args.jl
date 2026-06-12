# ============================================================================
# FuzzBridgeArgs — argument-side fuzz runner over WasmTarget.Bridge
# ============================================================================
#
# The constructor-closure marshalling core lives in `WasmTarget.Bridge`
# (promoted from here). This module keeps `bridge_run_args`, the
# full-generality fuzz runner: arbitrary supported arg types AND return type,
# with post-call re-reads of mutable args (mutation parity).

module FuzzBridgeArgs

export bridge_run_args, arg_descriptor, value_to_tree, args_supported, ismutable_shape

using WasmTarget
using WasmTarget.Bridge
using WasmTarget.Bridge: WALK_JS, BUILD_JS, _acc!
using JSON
using ..FuzzHarness: NODE_OK, DEFAULT_TIMEOUT, run_driver_batch
using ..FuzzBridge

# back-compat alias
const _BUILD_JS = BUILD_JS

"""
    bridge_run_args(fn, argtypes, inputs; rettype, strict, timeout, opt)

Full-generality runner: every arg AND the return value cross via the bit-exact
bridge. Returns per-input `(:ok, ret_tree, post_trees)` / `(:trap, msg)`, where
`post_trees[j]` is the post-call re-read of the j-th MUTABLE arg (`nothing` for
immutable args) — or `:unsupported` / `(:compile_error => e)` / `:no_node`.
"""
function bridge_run_args(fn, argtypes::Tuple, inputs::Vector; rettype::Type,
                         strict::Bool = true, timeout::Real = DEFAULT_TIMEOUT, opt = false,
                         discovery::Symbol = :legacy)
    NODE_OK || return :no_node
    rp = Bridge.descriptor(rettype)
    rp === nothing && return :unsupported
    rdesc, raccs = rp
    adescs = Any[]
    accs = Any[]
    names = Set{String}()
    for (fn_, at_, nm_) in raccs   # seed names so arg accs dedupe against ret accs
        push!(names, nm_); push!(accs, (fn_, at_, nm_))
    end
    mutable_flags = Bool[]
    postdescs = Any[]
    for T in argtypes
        ap = arg_descriptor(T)
        ap === nothing && return :unsupported
        ad, aaccs = ap
        for (fn_, at_, nm_) in aaccs
            _acc!(accs, names, nm_, fn_, at_)
        end
        push!(adescs, ad)
        mut = ismutable_shape(T)
        push!(mutable_flags, mut)
        if mut
            # post-call re-read uses the READ-side descriptor (+ its accessors)
            rp2 = Bridge.descriptor(T)
            rp2 === nothing && return :unsupported
            pd, paccs = rp2
            for (fn_, at_, nm_) in paccs
                _acc!(accs, names, nm_, fn_, at_)
            end
            push!(postdescs, pd)
        else
            push!(postdescs, nothing)
        end
    end
    fname = string(nameof(fn))
    funcs = Any[(fn, argtypes, fname)]
    append!(funcs, accs)
    bytes = try
        WasmTarget.compile_multi(funcs; strict = strict, validate = true, optimize = opt,
                                 discovery = discovery)
    catch e
        return (:compile_error => e)
    end
    enc_inputs = [Any[value_to_tree(adescs[j], tup[j]) for j in eachindex(adescs)] for tup in inputs]
    driver = """
    const importObject = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(bytes, importObject);
    const ex = instance.exports;
    const f = ex['$fname'];
    const adescs = $(JSON.json(adescs));
    const rdesc = $(JSON.json(rdesc));
    const pdescs = $(JSON.json(postdescs));
    const inputs = $(JSON.json(enc_inputs));
    $WALK_JS
    $BUILD_JS
    return inputs.map(trees => {
        try {
            const args = trees.map((t, j) => build(adescs[j], t));
            const r = f(...args);
            const post = args.map((a, j) => pdescs[j] ? walk(pdescs[j], a) : null);
            return { ok: walk(rdesc, r), post: post };
        } catch (e) { return { trap: String(e && e.message || e) + (process.env.WT_TRAP_STACK && e && e.stack ? " | " + String(e.stack).split("\\n").slice(0,3).join(" ; ") : "") }; }
    });
    """
    status, results = run_driver_batch(bytes, driver; deadline = timeout, ninputs = length(inputs))
    status === :nonode && return :no_node
    status === :error && return (:exec_error => results)
    out = Vector{Any}(undef, length(results))
    for (i, r) in enumerate(results)
        if r isa AbstractDict && haskey(r, "ok")
            out[i] = (:ok, r["ok"], get(r, "post", nothing))
        else
            out[i] = (:trap, String(get(r, "trap", "unknown")), nothing)
        end
    end
    return out
end

end # module FuzzBridgeArgs
