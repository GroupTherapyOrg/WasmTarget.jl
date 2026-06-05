# ============================================================================
# Fuzz execution harness — compile once, run many inputs in ONE Node process
# ============================================================================
#
# The per-test cost of the existing `run_wasm` (utils.jl) is one Node spawn PER
# call — fine for a fixed suite, fatal at fuzz scale. Here we compile a function
# once and evaluate ALL sample inputs in a single Node process, returning one
# result per input. That amortizes Node startup across the whole sample batch.
#
# Result per input is a tagged tuple:
#   (:ok,   value)   — function returned `value`
#   (:trap, message) — the wasm module trapped / threw at runtime

module FuzzHarness

export compile_and_run, compile_and_run_vec, NODE_OK

using WasmTarget
using JSON

# --- JS↔WasmGC bridge for Vector marshalling (reused from test/utils.jl) -----
# These compile to wasm alongside the target so JS can build/read Vector args.
_bv_i64_new(n::Int64)::Vector{Int64} = Vector{Int64}(undef, n)
_bv_i64_set!(v::Vector{Int64}, i::Int64, val::Int64)::Int64 = (v[i] = val; Int64(0))
_bv_i64_get(v::Vector{Int64}, i::Int64)::Int64 = v[i]
_bv_i64_len(v::Vector{Int64})::Int64 = Int64(length(v))
_bv_f64_new(n::Int64)::Vector{Float64} = Vector{Float64}(undef, n)
_bv_f64_set!(v::Vector{Float64}, i::Int64, val::Float64)::Int64 = (v[i] = val; Int64(0))
_bv_f64_get(v::Vector{Float64}, i::Int64)::Float64 = v[i]
_bv_f64_len(v::Vector{Float64})::Int64 = Int64(length(v))

const _BRIDGE_I64 = [(_bv_i64_new, (Int64,)), (_bv_i64_set!, (Vector{Int64}, Int64, Int64)),
                     (_bv_i64_get, (Vector{Int64}, Int64)), (_bv_i64_len, (Vector{Int64},))]
const _BRIDGE_F64 = [(_bv_f64_new, (Int64,)), (_bv_f64_set!, (Vector{Float64}, Int64, Float64)),
                     (_bv_f64_get, (Vector{Float64}, Int64)), (_bv_f64_len, (Vector{Float64},))]

# --- Node detection --------------------------------------------------------
function _detect_node()
    node = Sys.which("node")
    node === nothing && return (nothing, false)
    try
        v = read(`$node --version`, String)
        major = parse(Int, match(r"v(\d+)", v).captures[1])
        return (node, major < 22)  # older Node needs --experimental-wasm-gc
    catch
        return (node, false)
    end
end
const (NODE_CMD, NEEDS_FLAG) = _detect_node()
const NODE_OK = NODE_CMD !== nothing

# --- Argument / result marshalling (mirrors test/utils.jl) ------------------
function _js_arg(arg)
    if arg isa Int64 || arg isa Int
        return "BigInt(\"$(arg)\")"
    elseif arg isa UInt64
        return "BigInt(\"$(reinterpret(Int64, arg))\")"
    elseif arg isa Int32
        return string(arg)
    elseif arg isa UInt32
        return string(reinterpret(Int32, arg))
    elseif arg isa Bool
        return arg ? "1" : "0"
    elseif arg isa Float64 || arg isa Float32
        isnan(arg) && return "NaN"
        arg == Inf && return "Infinity"
        arg == -Inf && return "-Infinity"
        return repr(Float64(arg))
    else
        return repr(arg)
    end
end

# inputs is a Vector of arg-tuples; emit a JS array-of-arrays
function _js_inputs(inputs::Vector)
    rows = String[]
    for tup in inputs
        push!(rows, "[" * join((_js_arg(a) for a in tup), ", ") * "]")
    end
    return "[" * join(rows, ", ") * "]"
end

function _unmarshal(v)
    if v isa AbstractDict && haskey(v, "__bigint__")
        return parse(Int64, v["__bigint__"])
    elseif v isa AbstractString
        v == "__Inf__" && return Inf
        v == "__-Inf__" && return -Inf
        v == "__NaN__" && return NaN
        return v
    elseif v isa AbstractVector
        return [_unmarshal(x) for x in v]
    else
        return v
    end
end

"""
    compile_and_run(fn, argtypes::Tuple, inputs::Vector; strict=true) -> Union{Vector,Symbol}

Compile `fn` for `argtypes` and evaluate it over every arg-tuple in `inputs` in a
single Node process. Returns a vector of `(:ok, value)` / `(:trap, msg)`, one per
input — or `:compile_error => err` / `:no_node` for whole-batch failures.
"""
function compile_and_run(fn, argtypes::Tuple, inputs::Vector; strict::Bool=true, timeout::Real=8)
    NODE_OK || return :no_node
    fname = string(nameof(fn))
    bytes = try
        WasmTarget.compile(fn, argtypes; strict=strict, validate=true)
    catch e
        return (:compile_error => e)
    end

    dir = mktempdir()
    wpath = joinpath(dir, "m.wasm")
    jpath = joinpath(dir, "run.mjs")
    write(wpath, bytes)
    loader = """
    import fs from 'fs';
    const bytes = fs.readFileSync('$(escape_string(wpath))');
    const inputs = $(_js_inputs(inputs));
    const enc = (k,v) => {
        if (typeof v === 'bigint') return { __bigint__: v.toString() };
        if (typeof v === 'number') { if (v===Infinity) return "__Inf__"; if (v===-Infinity) return "__-Inf__"; if (Number.isNaN(v)) return "__NaN__"; }
        return v;
    };
    const importObject = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(bytes, importObject);
    const f = instance.exports['$fname'];
    const out = inputs.map(args => {
        try { return { ok: JSON.parse(JSON.stringify(f(...args), enc)) }; }
        catch (e) { return { trap: String(e && e.message || e) }; }
    });
    console.log(JSON.stringify(out));
    """
    write(jpath, loader)
    cmd = NEEDS_FLAG ? `$NODE_CMD --experimental-wasm-gc $jpath` : `$NODE_CMD $jpath`
    # Deadline-protected execution: a generated module can compile to a wasm that
    # infinite-loops (native terminates, wasm doesn't — a real divergence). Without
    # a timeout that would hang the whole fuzzer, so a hang becomes a per-input
    # `:trap "timeout"` finding instead. `time()` is wall-clock seconds.
    opath = joinpath(dir, "out.json")
    proc = try
        run(pipeline(cmd; stdout=opath, stderr=devnull); wait=false)
    catch e
        return (:exec_error => e)
    end
    deadline = time() + timeout
    while process_running(proc)
        if time() > deadline
            try; kill(proc, Base.SIGKILL); catch; end
            return Tuple{Symbol,Any}[(:trap, "timeout") for _ in inputs]
        end
        sleep(0.03)
    end
    out = isfile(opath) ? read(opath, String) : ""
    isempty(strip(out)) && return Tuple{Symbol,Any}[(:trap, "no-output") for _ in inputs]
    parsed = JSON.parse(strip(out))
    results = Vector{Tuple{Symbol,Any}}(undef, length(parsed))
    for (i, r) in enumerate(parsed)
        if r isa AbstractDict && haskey(r, "ok")
            results[i] = (:ok, _unmarshal(r["ok"]))
        else
            results[i] = (:trap, get(r, "trap", "unknown"))
        end
    end
    return results
end

# --- Natural-signature harness: Vector args AND returns (via the bridge) -----
_jsf(x) = isnan(x) ? "NaN" : x == Inf ? "Infinity" : x == -Inf ? "-Infinity" : repr(Float64(x))

function _enc_arg(a)
    if a isa Vector{Int64}
        return "{vi:[" * join(("\"$(x)\"" for x in a), ",") * "]}"
    elseif a isa Vector{Float64}
        return "{vf:[" * join((_jsf(x) for x in a), ",") * "]}"
    elseif a isa Int64 || a isa Int
        return "{i:\"$(a)\"}"
    elseif a isa Float64 || a isa Float32
        return "{f:$(_jsf(a))}"
    else
        return "{s:$(repr(string(a)))}"
    end
end

function _ret_vec_eltype(fn, argtypes)
    try
        _, rt = only(Base.code_typed(fn, argtypes; optimize=true))
        rt <: Vector{Int64} && return Int64
        rt <: Vector{Float64} && return Float64
    catch
    end
    return nothing
end

"""
    compile_and_run_vec(fn, argtypes, inputs; strict=true, timeout=8)

Natural-signature harness: handles `Vector{Int64}`/`Vector{Float64}` (and scalar)
arguments AND returns by compiling the target together with the wasm marshalling
bridge. `inputs` is a Vector of arg-tuples (args may be Vectors). Returns per-input
`(:ok, value)` / `(:trap, msg)` — a Vector result comes back as a Julia Vector.
"""
function compile_and_run_vec(fn, argtypes::Tuple, inputs::Vector; strict::Bool=true, timeout::Real=8)
    NODE_OK || return :no_node
    fname = string(nameof(fn))
    needs_i64 = any(==(Vector{Int64}), argtypes)
    needs_f64 = any(==(Vector{Float64}), argtypes)
    retvec = _ret_vec_eltype(fn, argtypes)
    needs_i64 |= (retvec === Int64)
    needs_f64 |= (retvec === Float64)
    funcs = Any[(fn, argtypes, fname)]
    needs_i64 && append!(funcs, _BRIDGE_I64)
    needs_f64 && append!(funcs, _BRIDGE_F64)
    bytes = try
        WasmTarget.compile_multi(funcs; strict=strict, validate=true)
    catch e
        return (:compile_error => e)
    end
    dir = mktempdir()
    wpath = joinpath(dir, "m.wasm"); jpath = joinpath(dir, "run.mjs"); opath = joinpath(dir, "out.json")
    write(wpath, bytes)
    inarr = "[" * join((("[" * join((_enc_arg(a) for a in tup), ",") * "]") for tup in inputs), ",") * "]"
    retmode = retvec === Int64 ? "vi" : retvec === Float64 ? "vf" : "scalar"
    loader = """
    import fs from 'fs';
    const bytes = fs.readFileSync('$(escape_string(wpath))');
    const { instance } = await WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } });
    const e = instance.exports; const f = e['$fname'];
    const bvi = a => { const v=e._bv_i64_new(BigInt(a.length)); for(let i=0;i<a.length;i++) e['_bv_i64_set!'](v,BigInt(i+1),BigInt(a[i])); return v; };
    const bvf = a => { const v=e._bv_f64_new(BigInt(a.length)); for(let i=0;i<a.length;i++) e['_bv_f64_set!'](v,BigInt(i+1),a[i]); return v; };
    const marsh = o => o.vi!==undefined ? bvi(o.vi) : o.vf!==undefined ? bvf(o.vf) : o.i!==undefined ? BigInt(o.i) : o.f!==undefined ? o.f : o.s;
    const rdi = v => { const n=Number(e._bv_i64_len(v)); const o=[]; for(let i=0;i<n;i++) o.push({__bigint__: e._bv_i64_get(v,BigInt(i+1)).toString()}); return o; };
    const rdf = v => { const n=Number(e._bv_f64_len(v)); const o=[]; for(let i=0;i<n;i++){const x=e._bv_f64_get(v,BigInt(i+1)); o.push(Number.isNaN(x)?"__NaN__":x===Infinity?"__Inf__":x===-Infinity?"__-Inf__":x);} return o; };
    const enc = (k,val)=>{ if(typeof val==='bigint') return {__bigint__:val.toString()}; if(typeof val==='number'){if(val===Infinity)return"__Inf__";if(val===-Infinity)return"__-Inf__";if(Number.isNaN(val))return"__NaN__";} return val; };
    const inputs = $(inarr);
    const out = inputs.map(args => { try {
        const r = f(...args.map(marsh));
        const v = "$(retmode)"==="vi" ? rdi(r) : "$(retmode)"==="vf" ? rdf(r) : JSON.parse(JSON.stringify(r, enc));
        return { ok: v };
    } catch(err){ return { trap: String(err && err.message || err) }; } });
    console.log(JSON.stringify(out));
    """
    write(jpath, loader)
    cmd = NEEDS_FLAG ? `$NODE_CMD --experimental-wasm-gc $jpath` : `$NODE_CMD $jpath`
    proc = try
        run(pipeline(cmd; stdout=opath, stderr=devnull); wait=false)
    catch e
        return (:exec_error => e)
    end
    deadline = time() + timeout
    while process_running(proc)
        if time() > deadline
            try; kill(proc, Base.SIGKILL); catch; end
            return Tuple{Symbol,Any}[(:trap, "timeout") for _ in inputs]
        end
        sleep(0.03)
    end
    out = isfile(opath) ? read(opath, String) : ""
    isempty(strip(out)) && return Tuple{Symbol,Any}[(:trap, "no-output") for _ in inputs]
    parsed = JSON.parse(strip(out))
    results = Vector{Tuple{Symbol,Any}}(undef, length(parsed))
    for (i, r) in enumerate(parsed)
        if r isa AbstractDict && haskey(r, "ok")
            results[i] = (:ok, _unmarshal(r["ok"]))
        else
            results[i] = (:trap, get(r, "trap", "unknown"))
        end
    end
    return results
end

end # module FuzzHarness
