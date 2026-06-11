# ============================================================================
# WasmTarget.Bridge — type-directed, BIT-EXACT value transport across the
# JS↔wasm boundary
# ============================================================================
#
# Promoted from the differential fuzzer's oracle bridge (test/fuzz/bridge.jl +
# bridge_args.jl), where it transports every supported Julia value into and
# out of compiled modules without ever becoming decimal text. Downstream
# consumers (PlutoIslands.jl islands, the fuzz oracle) share this one
# implementation.
#
# READ side (return values / post-call re-reads):
#   `descriptor(T)` → (desc, accessors): a JSON-able tree describing how to
#   take `T` apart + the minimal ACCESSOR CLOSURE — tiny getter functions
#   (`getfield` wrappers, vector len/get, float→bits reinterprets, string
#   codeunits) compiled INTO the module alongside the target via
#   `compile_multi((fn, args, name))`. The generic JS walker (`WALK_JS`)
#   drives those exports and returns a tagged tree whose every leaf is an
#   EXACT integer (stringified BigInt). `tree_matches(desc, native, tree)`
#   compares against the native value; all numeric policy (NaN classes equal,
#   ULP tolerance) lives in `_float_match`.
#
# ARG side (values INTO wasm):
#   `arg_descriptor(T)` → (desc, accessors): constructor exports (positional
#   ctors for structs/tuples/namedtuples, new/set! pairs for vectors, Char
#   from codepoint, String from a byte vector). Julia encodes native values
#   as the same tagged exact-integer trees (`value_to_tree`); the generic JS
#   builder (`BUILD_JS`) reconstructs them inside wasm. Float leaves cross as
#   raw f64 bits via DataView — never decimal text.
#
# Universe (both directions): Int8–64, UInt8–64, Bool, Float32/64, Char,
# String, Tuple, NamedTuple, plain/nested/parametric/mutable structs,
# Vector{T} (recursively). `descriptor`/`arg_descriptor` return `nothing`
# outside the universe — callers fall back / skip.
#
# The accessor closures are themselves WasmTarget output: a codegen bug there
# surfaces as a systematic, classified failure — not a hidden dependency.

module Bridge

export descriptor, arg_descriptor, bridge_supported, args_supported,
    value_to_tree, tree_matches, tree_decode, ismutable_shape,
    WALK_JS, BUILD_JS

# ── Export-name mangling ─────────────────────────────────────────────────────
_mangle(T::Type) = replace(string(T), r"[^A-Za-z0-9]" => "_")

const _INTS = Dict{Type,Tuple{Int,Bool}}(   # T => (bitwidth, signed)
    Int8 => (8, true),  Int16 => (16, true),  Int32 => (32, true),  Int64 => (64, true),
    UInt8 => (8, false), UInt16 => (16, false), UInt32 => (32, false), UInt64 => (64, false),
    Bool => (1, false),
)

# An accessor entry is `(fn, argtypes::Tuple, export_name::String)` — the
# 3-tuple form `compile_multi` accepts. The same concrete type always maps to
# the same export names, so entries dedupe across nesting via `names`.
function _acc!(accs, names, name::String, fn, argtypes::Tuple)
    if !(name in names)
        push!(names, name)
        push!(accs, (fn, argtypes, name))
    end
    return name
end

# ═════════════════════════════════════════════════════════════════════════════
# READ side
# ═════════════════════════════════════════════════════════════════════════════

const _DESC_CACHE = Dict{Type,Union{Nothing,Tuple{Any,Vector{Any}}}}()

"""
    descriptor(T) -> Union{Nothing, (desc, accessors)}

Read-side descriptor for `T` plus the accessor closure to compile alongside
the target. `nothing` when `T` is outside the bridge universe.
"""
function descriptor(T::Type)
    get!(_DESC_CACHE, T) do
        accs = Any[]
        names = Set{String}()
        d = _build!(accs, names, T)
        d === nothing ? nothing : (d, accs)
    end
end

bridge_supported(T::Type) = descriptor(T) !== nothing

function _build!(accs, names, T::Type)
    if haskey(_INTS, T)
        w, s = _INTS[T]
        return Dict("k" => "int", "w" => w, "s" => s)
    elseif T === Float64
        b = _acc!(accs, names, "_bits_f64", _bits_f64, (Float64,))
        return Dict("k" => "bits", "b" => b, "w" => 64)
    elseif T === Float32
        # reinterpret(Int32, ::Float32) miscompiles today (ledgered), so
        # transport the EXACTLY-widened Float64 bits — lossless.
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
        # all-int unions transport as the widest member — codegen widens the
        # wasm return to the largest int; String(v) handles number and BigInt.
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
        return Dict("k" => "fields", "fs" => fs, "names" => _field_names(T))
    end
    return nothing   # outside the universe (Dict/Set/ranges/abstract…)
end

# field names for name-keyed sources (e.g. msgpack objects); tuples have none
_field_names(T::Type) = T <: Tuple && !(T <: NamedTuple) ? nothing :
    [string(n) for n in fieldnames(T)]

# ── Leaf accessors (shared) ──────────────────────────────────────────────────
_bits_f64(x::Float64)::Int64 = reinterpret(Int64, x)
_bits_f32w(x::Float32)::Int64 = reinterpret(Int64, Float64(x))
# reinterpret(UInt32, ::Char) miscompiles today (ledgered); codepoint() is
# exact for valid Chars.
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
        # boundary (ledgered); symbol/getindex forms are solid.
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
const WALK_JS = """
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

# ═════════════════════════════════════════════════════════════════════════════
# ARG side
# ═════════════════════════════════════════════════════════════════════════════

const _ARG_CACHE = Dict{Type,Union{Nothing,Tuple{Any,Vector{Any}}}}()

"""
    arg_descriptor(T) -> Union{Nothing, (desc, accessors)}

Argument-side descriptor for `T` plus the constructor closure (ctor exports,
vector new/set! pairs) to compile alongside the target. `nothing` when `T`
is outside the universe.
"""
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
        return Dict("k" => "bits", "w" => 32)          # bits of the exact f64 widening
    elseif T === Char
        mk = _acc!(accs, names, "_mk_char", _mk_char, (Int64,))
        return Dict("k" => "char", "mk" => mk)
    elseif T === String
        nf = _acc!(accs, names, "_mkv_new_u8", _make_vnew(Vector{UInt8}), (Int64,))
        sf = _acc!(accs, names, "_mkv_set_u8", _make_vset(Vector{UInt8}), (Vector{UInt8}, Int64, UInt8))
        mk = _acc!(accs, names, "_mk_str", _mk_str, (Vector{UInt8},))
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
        return Dict("k" => "fields", "mk" => mk, "fs" => fs, "names" => _field_names(T))
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
        body = if T <: NamedTuple
            :( NamedTuple{$(fieldnames(T))}(tuple($(params...))) )
        elseif T <: Tuple
            :( tuple($(params...)) )
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
        # Signed stay negative; unsigned stay in [0, 2^w). JS wraps modulo 2^w.
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
const BUILD_JS = """
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

# ═════════════════════════════════════════════════════════════════════════════
# Decode + compare (Julia side)
# ═════════════════════════════════════════════════════════════════════════════

function _float_match(a::AbstractFloat, b::AbstractFloat)
    (isnan(a) && isnan(b)) && return true            # NaN payloads may differ
    a === b && return true                           # bit-identical (covers ±0.0)
    (isinf(a) || isinf(b)) && return a == b
    # wasm libm ≠ openlibm for transcendentals: tolerate tiny ULP drift.
    return isapprox(Float64(a), Float64(b); rtol = 1e-9, atol = 1e-12)
end

_dec_bits(::Val{64}, s::AbstractString) = reinterpret(Float64, parse(Int64, s))
_dec_bits(::Val{32}, s::AbstractString) = Float32(reinterpret(Float64, parse(Int64, s)))

function _dec_int(w::Int, signed::Bool, s::AbstractString)
    v = parse(Int128, s)
    w == 1 && return v != 0                              # Bool
    ST = w == 8 ? Int8 : w == 16 ? Int16 : w == 32 ? Int32 : Int64
    sv = ST(mod(v, Int128(2)^w) - (mod(v, Int128(2)^w) >= Int128(2)^(w - 1) ? Int128(2)^w : 0))
    return signed ? sv : reinterpret(unsigned(ST), sv)
end

"Compare a walked wasm tree against the native value (policy lives here)."
function tree_matches(d, native, tree)::Bool
    tree isa AbstractDict || return false
    haskey(tree, "err") && return false
    k = d["k"]
    if k == "int"
        return native == _dec_int(d["w"], d["s"], tree["x"])
    elseif k == "bits"
        return _float_match(native, _dec_bits(Val(d["w"]), tree["x"]))
    elseif k == "char"
        return codepoint(native::Char) == UInt32(parse(Int64, tree["x"]))
    elseif k == "str"
        return codeunits(native::String) == UInt8.(tree["s"])
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

"Best-effort tree → displayable Julia value (diagnostics only)."
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

end # module Bridge
