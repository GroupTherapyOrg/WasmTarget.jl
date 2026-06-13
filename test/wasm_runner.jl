# ============================================================================
# WasmRunner — a pool of persistent Node workers for executing compiled wasm.
# ============================================================================
# Shared by the unit suite (test/utils.jl) and the differential fuzzer
# (test/fuzz/harness.jl). Both used to `mktempdir()` + spawn a fresh `node` per
# wasm run; with ~150–300ms Node startup × thousands of runs that dominated both
# `runtests` and the fuzz loop. This pool starts K long-lived `node runner.mjs`
# workers ONCE and streams driver scripts to them over stdio (NDJSON).
#
# A worker that misses its deadline (an infinite-looping wasm — a real
# divergence, since native terminates) is killed and replaced; callers get a
# `:trap "timeout"` for that request. The pool is therefore self-healing.
#
# API:
#   pool = get_pool()                       # lazily-started process-global pool
#   run_driver(pool, wasmB64, src; deadline, ninputs) -> (:ok, results) | (:error, msg)
#       results :: Vector of Dicts, each {"ok"=>jsonvalue} or {"trap"=>"msg"}
#   shutdown_pool!()                        # kill all workers (atexit)
module WasmRunner

using JSON   # Base64 stdlib isn't on the Pkg.test path; `bytes2hex` is in Base.

export get_pool, run_driver, run_wasm_single, run_driver_batch, shutdown_pool!, runner_available, enc_wasm

const RUNNER_MJS = joinpath(@__DIR__, "runner.mjs")

# ── Node detection ──────────────────────────────────────────────────────────
# Node ≥ 22 runs wasm-gc with no flag; older needs --experimental-wasm-gc.
function _node_invocation()
    for exe in ("node", "nodejs")
        try
            v = strip(read(`$exe --version`, String))   # "v25.2.0"
            major = parse(Int, split(strip(v, 'v'), '.')[1])
            flag = major < 22 ? `--experimental-wasm-gc` : ``
            return `$exe $flag`
        catch
        end
    end
    return nothing
end

const _NODE = _node_invocation()
runner_available() = _NODE !== nothing

enc_wasm(bytes::Vector{UInt8}) = bytes2hex(bytes)

# ── Worker ──────────────────────────────────────────────────────────────────
mutable struct Worker
    proc::Base.Process
    alive::Bool
end

function _start_worker()::Worker
    # `open(cmd, "r+")` returns a Process usable as IO: write = stdin, read = stdout.
    proc = open(pipeline(`$_NODE $RUNNER_MJS`; stderr = devnull), "r+")
    w = Worker(proc, true)
    ready = readline(proc)                       # readiness handshake ({"ready":true})
    occursin("ready", ready) || error("runner worker failed to start: $ready")
    return w
end

function _kill_worker(w::Worker)
    w.alive = false
    try; kill(w.proc); catch; end
    try; close(w.proc); catch; end
end

# ── Pool ────────────────────────────────────────────────────────────────────
mutable struct RunnerPool
    workers::Vector{Worker}
    free::Channel{Worker}
    k::Int
    lock::ReentrantLock
end

function RunnerPool(k::Int)
    workers = Worker[_start_worker() for _ in 1:k]
    free = Channel{Worker}(k)
    for w in workers; put!(free, w); end
    RunnerPool(workers, free, k, ReentrantLock())
end

const _POOL = Ref{Union{RunnerPool,Nothing}}(nothing)

"""True logical CPU count. `Sys.CPU_THREADS` reports only PERFORMANCE cores on
Apple Silicon (e.g. 4 of 10 on an M-series), so read `hw.ncpu` via sysctl there."""
function logical_cpu_count()
    if Sys.isapple()
        try; return parse(Int, strip(read(`sysctl -n hw.ncpu`, String))); catch; end
    end
    return Sys.CPU_THREADS
end

"""Default Node-worker count. One persistent worker per Julia thread suffices
(requests are issued one-per-thread); the suite shards across PROCESSES, each
single-threaded, so this is 1–2 per process rather than one-per-core."""
default_k() = max(1, min(8, Threads.nthreads() + 1))

const _POOL_INIT_LOCK = ReentrantLock()
function get_pool(; k::Int = default_k())::Union{RunnerPool,Nothing}
    runner_available() || return nothing
    _POOL[] !== nothing && return _POOL[]   # fast path
    lock(_POOL_INIT_LOCK) do                 # double-checked: only one thread builds the pool
        if _POOL[] === nothing
            _POOL[] = RunnerPool(k)
            atexit(shutdown_pool!)
        end
    end
    return _POOL[]
end

function shutdown_pool!()
    p = _POOL[]
    p === nothing && return
    for w in p.workers; _kill_worker(w); end
    _POOL[] = nothing
    return
end

# Replace a dead worker `w` in the pool with a fresh one (does NOT touch `free`).
function _replace_worker!(pool::RunnerPool, w::Worker)::Worker
    _kill_worker(w)
    fresh = try _start_worker() catch; nothing end
    lock(pool.lock) do
        # P2-batch10: `===(w)` is a CORE BUILTIN call with one arg — it THROWS
        # ("===: too few arguments"); there is no curried Base method for ===.
        # This only ran on the worker-crash path, so every worker death
        # poisoned the whole pool (gap 6830e0e173d4's "context-sensitive
        # compile error + IOError session poisoning" was THIS, not codegen).
        idx = findfirst(x -> x === w, pool.workers)
        if idx !== nothing && fresh !== nothing
            pool.workers[idx] = fresh
        end
    end
    return fresh === nothing ? w : fresh
end

# Blocking read of one response line with a deadline. On timeout the worker is
# killed (unblocking the read via EOF); returns `nothing` to signal restart.
function _read_deadline(w::Worker, deadline::Real)::Union{String,Nothing}
    timedout = Ref(false)
    timer = Timer(deadline) do _
        timedout[] = true
        try; kill(w.proc); catch; end
    end
    line = ""
    try
        line = readline(w.proc)
    catch
        line = ""
    finally
        close(timer)
    end
    (timedout[] || isempty(line)) && return nothing
    return line
end

"""
    run_driver(pool, wasmB64, src; deadline=8.0, ninputs=1) -> (:ok, results) | (:error, msg)

Send a driver script (async-fn body returning a results array, with `bytes` in
scope) to a free worker and collect its response. Self-heals on timeout/crash.
"""
function run_driver(pool::RunnerPool, wasmHex::AbstractString, src::AbstractString;
                    deadline::Real = 8.0, ninputs::Int = 1, retries::Int = 2)
    w = take!(pool.free)                          # acquire (blocks if all busy)
    try
        req = JSON.json(Dict("id" => 1, "wasmHex" => wasmHex, "src" => src))
        for attempt in 0:retries
            println(w.proc, req)
            flush(w.proc)
            line = _read_deadline(w, deadline)
            if line === nothing                    # timeout or worker crash
                # A timeout is ambiguous: a genuinely hung wasm (a REAL divergence —
                # native terminates) OR a CPU-starved worker under load (infrastructure
                # artifact). Retry on a fresh worker; a real hang times out every attempt,
                # a load blip clears. Only after exhausting retries do we report the trap.
                w = _replace_worker!(pool, w)
                attempt < retries && continue
                return (:ok, Any[Dict("trap" => "timeout") for _ in 1:ninputs])
            end
            resp = try
                JSON.parse(line)
            catch e
                w = _replace_worker!(pool, w)
                return (:error, "bad-response: $(e)")
            end
            haskey(resp, "error") && return (:error, String(resp["error"]))
            return (:ok, resp["results"]::AbstractVector)
        end
        return (:ok, Any[Dict("trap" => "timeout") for _ in 1:ninputs])
    finally
        put!(pool.free, w)                          # `w` is always the current (live) worker
    end
end

# ── Convenience: single-call execution (the unit-suite shape) ────────────────
const _ENC_JS = """
const enc = (key,value) => {
  if (typeof value === 'bigint') return { __bigint__: value.toString() };
  if (typeof value === 'number') { if (value===Infinity) return "__Inf__"; if (value===-Infinity) return "__-Inf__"; if (Number.isNaN(value)) return "__NaN__"; }
  return value;
};
"""

"""
    run_wasm_single(bytes, fname, js_args; import_js) -> (:ok,val) | (:trap,msg) | (:error,msg) | (:nonode,nothing)

Instantiate `bytes`, call `fname(js_args)` once, and return the JSON-decoded
result. `js_args` is a JS argument string (e.g. `BigInt("5"), 3`). `import_js`
is a JS statement defining `const importObject = {…}`.
"""
function run_wasm_single(bytes::Vector{UInt8}, fname::AbstractString, js_args::AbstractString;
        import_js::AbstractString = "const importObject = { Math: { pow: Math.pow } };")
    pool = get_pool()
    pool === nothing && return (:nonode, nothing)
    src = """
    $_ENC_JS
    $import_js
    if (!importObject.io) importObject.io = { write_string(){}, write_int(){}, write_float(){}, write_bool(){}, write_newline(){}, write_nothing(){} };
    const { instance } = await WebAssembly.instantiate(bytes, importObject, { builtins: ['js-string'] });
    const f = instance.exports['$fname'];
    if (typeof f !== 'function') return [{ trap: 'export not a function: $fname' }];
    try { return [{ ok: JSON.parse(JSON.stringify(f($js_args), enc)) }]; }
    catch (e) { return [{ trap: String(e && e.message || e) }]; }
    """
    status, results = run_driver(pool, enc_wasm(bytes), src; ninputs = 1)
    status === :error && return (:error, results)
    r = results[1]
    haskey(r, "trap") && return (:trap, String(r["trap"]))
    return (:ok, r["ok"])
end

"""
    run_driver_batch(bytes, fname, src; deadline, ninputs)

Lower-level: run a custom driver `src` (must `return` a results array) with
`bytes` in scope. Thin wrapper over `run_driver` for harnesses that already
build their own JS (the differential fuzzer's scalar/vector bridges).
"""
function run_driver_batch(bytes::Vector{UInt8}, src::AbstractString; deadline::Real = 8.0, ninputs::Int = 1)
    pool = get_pool()
    pool === nothing && return (:nonode, nothing)
    return run_driver(pool, enc_wasm(bytes), src; deadline = deadline, ninputs = ninputs)
end

end # module
