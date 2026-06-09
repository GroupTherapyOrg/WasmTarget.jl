# ============================================================================
# FuzzBridgeArgs — argument-side of the bit-exact bridge (M2)
# ============================================================================
#
# Inverse of the read-side walker: Julia encodes each native argument as the
# same tagged exact-integer tree (`value_to_tree`); a generic JS `build`
# reconstructs the value INSIDE wasm via a compiled constructor closure
# (positional ctors for structs/tuples, new/set! pairs for vectors, Char from
# codepoint, String from a byte vector; float leaves cross as raw f64 bits via
# DataView — never decimal text).
#
# Mutation parity: arguments whose type is mutable (Vector, mutable struct) are
# RE-READ through the read-side walker after the call; the property layer
# compares them against native's post-call arguments. This is what makes
# `push!`/`sort!`-style ops honestly testable.
#
# `bridge_run_args` is the full-generality runner: arbitrary supported arg
# types AND return type. It supersedes both the scalar `_js_inputs` path and
# the hand-rolled `_bv_*` vector bridge.

module FuzzBridgeArgs

export bridge_run_args, arg_descriptor, value_to_tree, args_supported, ismutable_shape

using WasmTarget
using JSON
using ..FuzzHarness: NODE_OK, DEFAULT_TIMEOUT, run_driver_batch
using ..FuzzBridge
using ..FuzzBridge: _mangle, _acc!, _FN_CACHE, _INTS, _build!

# ── Argument descriptor: read-descriptor keys + constructor exports ──────────
# Cached per type. `accs` accumulates BOTH read-side accessors (for post-call
# re-reads) and constructor exports.
const _ARG_CACHE = Dict{Type,Union{Nothing,Tuple{Any,Vector{Any}}}}()

function arg_descriptor(T::Type)
    get!(_ARG_CACHE, T) do
        accs = Any[]
        names = Set{String}()
        d = _build_arg!(accs, names, T)
        d === nothing ? nothing : (d, accs)
    end
end

args_supported(T::Type) = arg_descriptor(T) !== nothing

function _build_arg!(accs, names, T::Type)
    if haskey(_INTS, T)
        w, s = _INTS[T]
        return Dict("k" => "int", "w" => w, "s" => s)
    elseif T === Float64
        return Dict("k" => "bits", "w" => 64)          # JS DataView decodes bits → f64 param
    elseif T === Float32
        return Dict("k" => "bits", "w" => 32)          # bits of the exact f64 widening; fround on pass
    elseif T === Char
        mk = _acc!(accs, names, "_mk_char", _mk_char, (Int64,))
        return Dict("k" => "char", "mk" => mk)
    elseif T === String
        m = "_mk_str"
        nf = _acc!(accs, names, "_mkv_new_u8", _make_vnew(Vector{UInt8}), (Int64,))
        sf = _acc!(accs, names, "_mkv_set_u8", _make_vset(Vector{UInt8}), (Vector{UInt8}, Int64, UInt8))
        mk = _acc!(accs, names, m, _mk_str, (Vector{UInt8},))
        return Dict("k" => "str", "mk" => mk, "new" => nf, "set" => sf)
    elseif T <: Vector && isconcretetype(T)
        E = eltype(T)
        el = _build_arg!(accs, names, E)
        el === nothing && return nothing
        m = _mangle(T)
        nf = _acc!(accs, names, "_mkv_new_$m", _make_vnew(T), (Int64,))
        sf = _acc!(accs, names, "_mkv_set_$m", _make_vset(T), (T, Int64, E))
        return Dict("k" => "vec", "new" => nf, "set" => sf, "el" => el)
    elseif (isstructtype(T) || T <: Tuple) && isconcretetype(T)
        n = fieldcount(T)
        fs = Any[]
        for i in 1:n
            fd = _build_arg!(accs, names, fieldtype(T, i))
            fd === nothing && return nothing
            push!(fs, Dict("d" => fd))
        end
        mk = _acc!(accs, names, "_mk_$(_mangle(T))", _make_ctor(T), Tuple(fieldtype(T, i) for i in 1:n))
        return Dict("k" => "fields", "mk" => mk, "fs" => fs)
    end
    return nothing
end

# ── Constructor leaf/factory functions ───────────────────────────────────────
_mk_char(x::Int64)::Char = Char(x)
_mk_str(b::Vector{UInt8})::String = String(copy(b))

function _make_vnew(::Type{T}) where {T<:Vector}
    get!(_FN_CACHE, (:vnew, T)) do
        f = Symbol("_vnewfn_", _mangle(T))
        @eval (function $f(n::Int64)::$T; $T(undef, Int(n)); end)
    end
end

function _make_vset(::Type{T}) where {T<:Vector}
    get!(_FN_CACHE, (:vset, T)) do
        f = Symbol("_vsetfn_", _mangle(T))
        E = eltype(T)
        @eval (function $f(v::$T, i::Int64, x::$E)::Int64; v[Int(i)] = x; Int64(0); end)
    end
end

function _make_ctor(::Type{T}) where {T}
    get!(_FN_CACHE, (:ctor, T)) do
        f = Symbol("_ctorfn_", _mangle(T))
        n = fieldcount(T)
        params = [Symbol("a", i) for i in 1:n]
        sig = [:( $(params[i])::$(fieldtype(T, i)) ) for i in 1:n]
        body = if T <: Tuple
            :( tuple($(params...)) )
        elseif T <: NamedTuple
            :( NamedTuple{$(fieldnames(T))}(tuple($(params...))) )
        else
            :( $T($(params...)) )
        end
        @eval (function $f($(sig...))::$T; $body; end)
    end
end

# ── Julia-side encoder: native value → tagged exact tree ─────────────────────
function value_to_tree(d, v)
    k = d["k"]
    if k == "int"
        # Natural decimal of the value: signed stay negative; unsigned stay in
        # [0, 2^w) (wasm params ZERO-extend unsigned — sign-extending UInt8(255)
        # to -1 produced 0xFFFFFFFF on the other side). JS ToInt32/i64-BigInt
        # wrap modulo 2^w, so UInt32/UInt64 top-bit values pass exactly.
        return Dict("x" => v isa Bool ? (v ? "1" : "0") : string(v))
    elseif k == "bits"
        b = d["w"] == 64 ? reinterpret(Int64, v::Float64) : reinterpret(Int64, Float64(v::Float32))
        return Dict("x" => string(b))
    elseif k == "char"
        return Dict("x" => string(Int64(codepoint(v::Char))))
    elseif k == "str"
        return Dict("s" => Int.(codeunits(v::String)))
    elseif k == "fields"
        return Dict("f" => Any[value_to_tree(d["fs"][i]["d"], getfield(v, i)) for i in eachindex(d["fs"])])
    elseif k == "vec"
        return Dict("a" => Any[value_to_tree(d["el"], x) for x in v])
    end
    error("value_to_tree: bad kind $k")
end

# ── JS builder (inverse walker) ──────────────────────────────────────────────
const _BUILD_JS = """
const _dv = new DataView(new ArrayBuffer(8));
const f64bits = s => { _dv.setBigUint64(0, BigInt.asUintN(64, BigInt(s))); return _dv.getFloat64(0); };
const build = (d, t) => {
  switch (d.k) {
    case 'int':  return d.w === 64 ? BigInt(t.x) : Number(t.x);
    case 'bits': return f64bits(t.x);                       // f32 params fround on pass — exact
    case 'char': return ex[d.mk](BigInt(t.x));
    case 'str': {
      const b = ex[d.new](BigInt(t.s.length));
      for (let i = 0; i < t.s.length; i++) ex[d.set](b, BigInt(i + 1), t.s[i]);
      return ex[d.mk](b);
    }
    case 'fields': return ex[d.mk](...d.fs.map((fd, i) => build(fd.d, t.f[i])));
    case 'vec': {
      const v = ex[d.new](BigInt(t.a.length));
      for (let i = 0; i < t.a.length; i++) ex[d.set](v, BigInt(i + 1), build(d.el, t.a[i]));
      return v;
    }
    default: throw new Error('bad-arg-desc-kind ' + d.k);
  }
};
"""

# ── Mutability: which arg types need post-call re-reads ──────────────────────
ismutable_shape(T::Type) = T <: Vector || (isstructtype(T) && ismutabletype(T))

"""
    bridge_run_args(fn, argtypes, inputs; rettype, strict, timeout, opt)

Full-generality runner: every arg AND the return value cross via the bit-exact
bridge. Returns per-input `(:ok, ret_tree, post_trees)` / `(:trap, msg)`, where
`post_trees[j]` is the post-call re-read of the j-th MUTABLE arg (`nothing` for
immutable args) — or `:unsupported` / `(:compile_error => e)` / `:no_node`.
"""
function bridge_run_args(fn, argtypes::Tuple, inputs::Vector; rettype::Type,
                         strict::Bool = true, timeout::Real = DEFAULT_TIMEOUT, opt = false)
    NODE_OK || return :no_node
    rp = FuzzBridge.descriptor(rettype)
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
        mut = T <: Vector || (isstructtype(T) && ismutabletype(T))
        push!(mutable_flags, mut)
        if mut
            # post-call re-read uses the READ-side descriptor (+ its accessors)
            rp2 = FuzzBridge.descriptor(T)
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
        WasmTarget.compile_multi(funcs; strict = strict, validate = true, optimize = opt)
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
    $(FuzzBridge._WALK_JS)
    $_BUILD_JS
    return inputs.map(trees => {
        try {
            const args = trees.map((t, j) => build(adescs[j], t));
            const r = f(...args);
            const post = args.map((a, j) => pdescs[j] ? walk(pdescs[j], a) : null);
            return { ok: walk(rdesc, r), post: post };
        } catch (e) { return { trap: String(e && e.message || e) }; }
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
