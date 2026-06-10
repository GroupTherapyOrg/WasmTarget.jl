# ============================================================================
# FuzzBridge — type-directed, BIT-EXACT value transport for the oracle
# ============================================================================
#
# Why this exists: the old path round-trips results through JSON decimal text,
# which inherits the serializer's numeric semantics (gap fa64c0d70add: JSON 0.21
# silently wrapped >typemax(Int64) literals — a fake divergence). Here a value
# never becomes decimal text:
#
#   1. From the STATIC return type `T`, `descriptor(T)` builds a JSON-able tree
#      describing how to take `T` apart, plus the minimal ACCESSOR CLOSURE —
#      tiny getter functions (`getfield` wrappers, vector len/get, float→bits
#      reinterprets, string codeunits) that are compiled INTO the module
#      alongside the target via `compile_multi((fn, args, name))`.
#   2. One generic JS walker (`_WALK_JS`) drives those exports and returns a
#      tagged tree whose every leaf is an EXACT integer (stringified BigInt).
#   3. `tree_matches(desc, native, tree)` walks the same descriptor against the
#      native value. All comparison POLICY (NaN classes equal, ULP tolerance
#      for libm divergence) lives in `_float_match` — decoupled from transport.
#
# The accessor closure is itself WasmTarget output: a codegen bug there surfaces
# as a systematic, classified failure (it's part of the compiler under test, not
# a hidden oracle dependency).
#
# v1 universe (M1, return values): Int8–128? no — Int8/16/32/64, UInt8–64, Bool,
# Float32/64, Char, String, Tuple, NamedTuple, plain/nested/parametric/mutable
# structs, Vector{T} (recursively, incl. vectors of structs/vectors).
# `descriptor` returns `nothing` for anything outside the universe — callers
# fall back / skip, and the round-trip test records the boundary.

module FuzzBridge

export bridge_run, descriptor, tree_matches, tree_decode, bridge_supported

using WasmTarget
using JSON
# FuzzHarness (included by the entrypoint before this file) owns Node detection,
# the scalar-arg encoder, and the persistent WasmRunner pool.
using ..FuzzHarness: NODE_OK, DEFAULT_TIMEOUT, _js_inputs, run_driver_batch

# ── Export-name mangling ─────────────────────────────────────────────────────
_mangle(T::Type) = replace(string(T), r"[^A-Za-z0-9]" => "_")

# ── Descriptor + accessor-closure construction (memoized per root type) ──────
# An accessor entry is `(fn, argtypes::Tuple, export_name::String)` — the
# 3-tuple form `compile_multi` accepts. The same concrete type always maps to
# the same export names, so entries dedupe across nesting via `names`.
const _DESC_CACHE = Dict{Type,Union{Nothing,Tuple{Any,Vector{Any}}}}()

const _INTS = Dict{Type,Tuple{Int,Bool}}(   # T => (bitwidth, signed)
    Int8 => (8, true),  Int16 => (16, true),  Int32 => (32, true),  Int64 => (64, true),
    UInt8 => (8, false), UInt16 => (16, false), UInt32 => (32, false), UInt64 => (64, false),
    Bool => (1, false),
)

function descriptor(T::Type)
    get!(_DESC_CACHE, T) do
        accs = Any[]
        names = Set{String}()
        d = _build!(accs, names, T)
        d === nothing ? nothing : (d, accs)
    end
end

bridge_supported(T::Type) = descriptor(T) !== nothing

function _acc!(accs, names, name::String, fn, argtypes::Tuple)
    if !(name in names)
        push!(names, name)
        push!(accs, (fn, argtypes, name))
    end
    return name
end

function _build!(accs, names, T::Type)
    if haskey(_INTS, T)
        w, s = _INTS[T]
        return Dict("k" => "int", "w" => w, "s" => s)
    elseif T === Float64
        b = _acc!(accs, names, "_bits_f64", _bits_f64, (Float64,))
        return Dict("k" => "bits", "b" => b, "w" => 64)
    elseif T === Float32
        # reinterpret(Int32, ::Float32) miscompiles today (invalid wasm — ledgered),
        # so transport the EXACTLY-widened Float64 bits instead; Float32↔Float64
        # widening/narrowing of a widened value is lossless.
        b = _acc!(accs, names, "_bits_f32w", _bits_f32w, (Float32,))
        return Dict("k" => "bits", "b" => b, "w" => 32)
    elseif T === Char
        b = _acc!(accs, names, "_bits_char", _bits_char, (Char,))
        return Dict("k" => "char", "b" => b)
    elseif T === String
        l = _acc!(accs, names, "_str_len", _str_len, (String,))
        c = _acc!(accs, names, "_str_cu", _str_cu, (String, Int64))
        return Dict("k" => "str", "len" => l, "cu" => c)
    elseif T <: Vector && isconcretetype(T)
        E = eltype(T)
        m = _mangle(T)
        el = _build!(accs, names, E)
        el === nothing && return nothing
        lf = _make_vlen(T);  l = _acc!(accs, names, "_vlen_$m", lf, (T,))
        gf = _make_vget(T);  g = _acc!(accs, names, "_vget_$m", gf, (T, Int64))
        return Dict("k" => "vec", "len" => l, "get" => g, "el" => el)
    elseif T isa Union
        # P2-batch18: all-int unions (e.g. Union{Int32,Int64} from
        # `try div(0,x)::Int64 catch x::Int32 end`) transport as the widest
        # member — codegen widens the wasm return to the largest int, and the
        # JS walker's String(v) handles number and BigInt alike. tree_matches
        # compares with ==, which is value-based across Int widths.
        ms = Base.uniontypes(T)
        if all(m -> haskey(_INTS, m) && m !== Bool, ms)
            ws = [_INTS[m] for m in ms]
            if all(t -> t[2], ws) || all(t -> !t[2], ws)   # uniform signedness
                return Dict("k" => "int", "w" => maximum(first.(ws)), "s" => ws[1][2])
            end
        end
        return nothing
    elseif (isstructtype(T) || T <: Tuple) && isconcretetype(T)
        # Tuples, NamedTuples, and (im)mutable structs all decompose by field.
        n = fieldcount(T)
        m = _mangle(T)
        fs = Any[]
        for i in 1:n
            FT = fieldtype(T, i)
            fd = _build!(accs, names, FT)
            fd === nothing && return nothing
            ff = _make_fget(T, i)
            a = _acc!(accs, names, "_fget_$(m)_$i", ff, (T,))
            push!(fs, Dict("a" => a, "d" => fd))
        end
        return Dict("k" => "fields", "fs" => fs)
    end
    return nothing   # outside the v1 universe (Dict/Set/ranges/Union/abstract…)
end

# ── Leaf accessors (shared) ──────────────────────────────────────────────────
_bits_f64(x::Float64)::Int64 = reinterpret(Int64, x)
_bits_f32w(x::Float32)::Int64 = reinterpret(Int64, Float64(x))
# reinterpret(UInt32, ::Char) miscompiles today (ledgered with the f32 case);
# codepoint() compiles fine and is exact for the valid Chars the generator emits.
_bits_char(c::Char)::Int64 = Int64(codepoint(c))
_str_len(s::String)::Int64 = Int64(ncodeunits(s))
_str_cu(s::String, i::Int64)::Int32 = Int32(codeunit(s, Int(i)))

# ── Per-type accessor factories (memoized via @eval; named fns compile best) ──
const _FN_CACHE = Dict{Any,Function}()

function _make_vlen(::Type{T}) where {T<:Vector}
    get!(_FN_CACHE, (:vlen, T)) do
        f = Symbol("_vlenfn_", _mangle(T))
        @eval (function $f(v::$T)::Int64; Int64(length(v)); end)
    end
end

function _make_vget(::Type{T}) where {T<:Vector}
    get!(_FN_CACHE, (:vget, T)) do
        f = Symbol("_vgetfn_", _mangle(T))
        E = eltype(T)
        @eval (function $f(v::$T, i::Int64)::$E; v[Int(i)]; end)
    end
end

function _make_fget(::Type{T}, i::Int) where {T}
    get!(_FN_CACHE, (:fget, T, i)) do
        f = Symbol("_fgetfn_", _mangle(T), "_", i)
        FT = fieldtype(T, i)
        # Integer-index getfield traps when the receiver ref crossed the JS
        # boundary (works in-module — a WasmTarget quirk, ledgered); the
        # symbol/getindex forms are solid. Tuples have no field names.
        if T <: Tuple
            @eval (function $f(x::$T)::$FT; x[$i]; end)
        else
            fname = fieldname(T, i)
            @eval (function $f(x::$T)::$FT; x.$fname; end)
        end
    end
end

# ── The generic JS walker ────────────────────────────────────────────────────
# Every numeric leaf leaves the module as an exact integer string. `ex` is the
# instance's exports; `v` may be a JS Number, BigInt, or an opaque wasm-GC ref.
const _WALK_JS = """
const walk = (d, v) => {
  switch (d.k) {
    case 'int':  return { x: String(v) };
    case 'bits': return { x: String(ex[d.b](v)) };
    case 'char': return { x: String(ex[d.b](v)) };
    case 'str': {
      const n = Number(ex[d.len](v)); const a = [];
      for (let i = 1; i <= n; i++) a.push(Number(ex[d.cu](v, BigInt(i))));
      return { s: a };
    }
    case 'fields': return { f: d.fs.map(fd => walk(fd.d, ex[fd.a](v))) };
    case 'vec': {
      const n = Number(ex[d.len](v)); const a = [];
      for (let i = 1; i <= n; i++) a.push(walk(d.el, ex[d.get](v, BigInt(i))));
      return { a: a };
    }
    default: return { err: 'bad-desc-kind ' + d.k };
  }
};
"""

# ── Decode + compare (Julia side) ────────────────────────────────────────────
# Walks the descriptor against the NATIVE value and the wasm tree TOGETHER —
# no reconstruction. Numeric policy is centralized here.
function _float_match(a::AbstractFloat, b::AbstractFloat)
    (isnan(a) && isnan(b)) && return true            # NaN payloads may differ (JS canonicalization)
    a === b && return true                           # bit-identical (covers ±0.0 distinction)
    (isinf(a) || isinf(b)) && return a == b
    # wasm libm ≠ openlibm for transcendentals: tolerate tiny ULP drift, same as vals_match.
    return isapprox(Float64(a), Float64(b); rtol = 1e-9, atol = 1e-12)
end

_dec_bits(::Val{64}, s::AbstractString) = reinterpret(Float64, parse(Int64, s))
# Float32 travels as its exactly-widened Float64 bits (see _bits_f32w).
_dec_bits(::Val{32}, s::AbstractString) = Float32(reinterpret(Float64, parse(Int64, s)))

# Exact integer decode: the wire value is the (possibly sign-mangled) machine
# integer; normalize through the same-width signed type then reinterpret.
function _dec_int(w::Int, signed::Bool, s::AbstractString)
    v = parse(Int128, s)
    w == 1 && return v != 0                              # Bool
    ST = w == 8 ? Int8 : w == 16 ? Int16 : w == 32 ? Int32 : Int64
    sv = ST(mod(v, Int128(2)^w) - (mod(v, Int128(2)^w) >= Int128(2)^(w - 1) ? Int128(2)^w : 0))
    return signed ? sv : reinterpret(unsigned(ST), sv)
end

function tree_matches(d, native, tree)::Bool
    tree isa AbstractDict || return false
    haskey(tree, "err") && return false
    k = d["k"]
    if k == "int"
        w = d["w"]; s = d["s"]
        dec = _dec_int(w, s, tree["x"])
        return w == 1 ? (native == dec) : (native == dec)
    elseif k == "bits"
        dec = _dec_bits(Val(d["w"]), tree["x"])
        return _float_match(native, dec)
    elseif k == "char"
        return codepoint(native::Char) == UInt32(parse(Int64, tree["x"]))
    elseif k == "str"
        bytes = tree["s"]
        return codeunits(native::String) == UInt8.(bytes)
    elseif k == "fields"
        fs = d["fs"]
        tf = tree["f"]
        length(tf) == length(fs) || return false
        return all(tree_matches(fs[i]["d"], getfield(native, i), tf[i]) for i in eachindex(fs))
    elseif k == "vec"
        ta = tree["a"]
        length(native) == length(ta) || return false
        return all(tree_matches(d["el"], native[i], ta[i]) for i in eachindex(ta))
    end
    return false
end

# Best-effort reconstruction of a walked tree into a displayable Julia value —
# for ledger DIAGNOSTICS only (composites decode to tuples/vectors; comparison
# never goes through this, it uses tree_matches).
function tree_decode(d, tree)
    tree isa AbstractDict || return tree
    haskey(tree, "err") && return Symbol(tree["err"])
    k = d["k"]
    k == "int" && return _dec_int(d["w"], d["s"], tree["x"])
    k == "bits" && return _dec_bits(Val(d["w"]), tree["x"])
    k == "char" && return Char(parse(Int64, tree["x"]))
    k == "str" && return String(UInt8.(tree["s"]))
    k == "fields" && return Tuple(tree_decode(d["fs"][i]["d"], tree["f"][i]) for i in eachindex(d["fs"]))
    k == "vec" && return Any[tree_decode(d["el"], t) for t in tree["a"]]
    return tree
end

# ── Execution: compile target + accessor closure, run, return walked trees ───
"""
    bridge_run(fn, argtypes, inputs; rettype, strict=true, timeout, opt=false)

Compile `fn` together with the accessor closure for `rettype` and evaluate it
over every arg-tuple in `inputs` (scalar args, as in `compile_and_run`) in one
Node round-trip. Returns a vector of `(:ok, tree)` / `(:trap, msg)` per input,
`:unsupported` if `rettype` is outside the bridge universe, or
`(:compile_error => e)` / `:no_node` for whole-batch failures.

Compare each `(:ok, tree)` against the native value via
`tree_matches(descriptor(rettype)[1], native, tree)`.
"""
function bridge_run(fn, argtypes::Tuple, inputs::Vector; rettype::Type,
                    strict::Bool = true, timeout::Real = DEFAULT_TIMEOUT, opt = false)
    NODE_OK || return :no_node
    dp = descriptor(rettype)
    dp === nothing && return :unsupported
    desc, accs = dp
    fname = string(nameof(fn))
    funcs = Any[(fn, argtypes, fname)]
    append!(funcs, accs)
    bytes = try
        WasmTarget.compile_multi(funcs; strict = strict, validate = true, optimize = opt)
    catch e
        return (:compile_error => e)
    end
    driver = """
    const inputs = $(_js_inputs(inputs));
    const importObject = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(bytes, importObject);
    const ex = instance.exports;
    const f = ex['$fname'];
    const desc = $(JSON.json(desc));
    $_WALK_JS
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
