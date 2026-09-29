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

export get_pool, run_driver, run_wasm_single, run_driver_batch, shutdown_pool!, enc_wasm, NODE

const RUNNER_MJS = joinpath(@__DIR__, "runner.mjs")

# ── Node detection ──────────────────────────────────────────────────────────
# Node is the wasm runtime every differential lane executes on (the soundness oracle), so a
# missing or too-old Node is an error at load: a lane that skipped without it would report a
# pass it never measured. Node ≥ 22 runs wasm-gc with no flag; 20–21 needs
# --experimental-wasm-gc.
function _node_invocation()::Cmd
    for exe in ("node", "nodejs")
        path = Sys.which(exe)
        path === nothing && continue
        v = strip(read(`$path --version`, String))   # "v25.2.0"
        major = parse(Int, split(strip(v, 'v'), '.')[1])
        major >= 20 || error("the wasm runtime is Node.js ≥ 20 (wasm-gc); $path is $v")
        return major < 22 ? `$path --experimental-wasm-gc` : `$path`
    end
    error("the wasm runtime is Node.js ≥ 20 (wasm-gc), and neither `node` nor `nodejs` is on PATH: every differential lane runs its wasm there")
end

const NODE = _node_invocation()

enc_wasm(bytes::Vector{UInt8}) = bytes2hex(bytes)

# ── Worker ──────────────────────────────────────────────────────────────────
mutable struct Worker
    proc::Base.Process
    alive::Bool
end

function _start_worker()::Worker
    # `open(cmd, "r+")` returns a Process usable as IO: write = stdin, read = stdout.
    proc = open(pipeline(`$NODE $RUNNER_MJS`; stderr = devnull), "r+")
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
function get_pool(; k::Int = default_k())::RunnerPool
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
  if (typeof value === 'number') { if (value===Infinity) return "__Inf__"; if (value===-Infinity) return "__-Inf__"; if (Number.isNaN(value)) return "__NaN__"; if (Object.is(value, -0)) return "__-0__"; }
  return value;
};
"""

"""
    run_wasm_single(bytes, fname, js_args; import_js, source_map) -> (:ok,val) | (:trap,msg) | (:error,msg)

Instantiate `bytes`, call `fname(js_args)` once, and return the JSON-decoded
result. `js_args` is a JS argument string (e.g. `BigInt("5"), 3`). `import_js`
is a JS statement defining `const importObject = {…}`. With the module's
`source_map` (WasmTarget.compile_with_sourcemap), a trap's message names the Julia
statement of each wasm frame it unwound through (`located_frames`).
"""
function run_wasm_single(bytes::Vector{UInt8}, fname::AbstractString, js_args::AbstractString;
        import_js::AbstractString = "const importObject = {};",
        source_map::Union{Nothing,AbstractString} = nothing)
    pool = get_pool()
    src = """
    $_ENC_JS
    $import_js
    Error.stackTraceLimit = 64;   // a trap's frames, beyond V8's default 10 (located_frames)
    // a module compiled with a source map captures each throw's JS stack through this import
    // (WasmTarget.ensure_provenance_imports!); modules without one ignore it
    importObject.wasmtarget = Object.assign({ stack_trace: () => new Error() }, importObject.wasmtarget || {});
    const { instance } = await WebAssembly.instantiate(bytes, importObject, { builtins: ['js-string'] });
    const f = instance.exports['$fname'];
    if (typeof f !== 'function') return [{ trap: 'export not a function: $fname' }];
    let v;
    try { v = f($js_args); }
    catch (e) {
      const tag = instance.exports['wasmtarget.exception'];
      if (e instanceof WebAssembly.Exception && tag && e.is(tag)) {
        // an escaped Julia exception: its stack is the one captured at its throw
        const st = e.getArg(tag, 1);
        return [{ trap: 'uncaught Julia exception', stack: String(st && st.stack || '') }];
      }
      return [{ trap: String(e && e.message || e), stack: String(e && e.stack || '') }];
    }
    // an export with no result answers `undefined`, which is Julia's `nothing`
    if (v === undefined) return [{ ok: null }];
    try { return [{ ok: JSON.parse(JSON.stringify(v, enc)) }]; }
    catch (e) { return [{ trap: 'unserializable result (a GC reference; compare it through the bridge): ' + String(e && e.message || e) }]; }
    """
    status, results = run_driver(pool, enc_wasm(bytes), src; ninputs = 1)
    status === :error && return (:error, results)
    r = results[1]
    if haskey(r, "trap")
        local msg = String(r["trap"])
        if source_map !== nothing && haskey(r, "stack")
            local frames = located_frames(String(r["stack"]), source_map)
            isempty(frames) || (msg *= "\n" * join(("  at " * f for f in frames), "\n"))
        end
        return (:trap, msg)
    end
    return (:ok, r["ok"])
end

# ---- A trap's frames, located through the module's source map ---------------------------
# V8 prints a wasm frame as `wasm://wasm/<id>:wasm-function[<i>]:0x<byte offset in the module>`;
# the source map (Source Map v3, one generated line whose columns are module byte offsets)
# names the statement whose instructions cover that offset.

# the Source Map v3 segments of `mappings`: [offset, source, line, column(, name)] absolute
function _source_map_segments(mappings::AbstractString)::Vector{Vector{Int}}
    local digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local acc = zeros(Int, 5)
    local out = Vector{Int}[]
    for seg in split(mappings, ',')
        isempty(seg) && continue
        local fields = Int[]
        local value, shift = 0, 0
        for c in seg
            local d = findfirst(==(c), digits) - 1
            value |= (d & 31) << shift
            if d & 32 != 0
                shift += 5
            else
                push!(fields, (value & 1) == 1 ? -(value >> 1) : (value >> 1))
                value, shift = 0, 0
            end
        end
        for (i, f) in enumerate(fields)
            acc[i] += f
        end
        push!(out, length(fields) == 1 ? Int[acc[1]] : acc[1:length(fields)])
    end
    return out
end

"""
    located_frames(stack, source_map) -> Vector{String}

Each wasm frame of a JS `stack`, innermost first, as the Julia statement its offset maps to —
the statement's inline chain — or `wasm-function[i] +0x… (compiler-generated)` for unmapped
code; a frame repeated in a row (recursion) prints once with its count.
"""
function located_frames(stack::AbstractString, source_map::AbstractString)::Vector{String}
    local sm = JSON.parse(source_map)
    local segs = _source_map_segments(sm["mappings"])
    local names = sm["names"]
    local sources = sm["sources"]
    local out = String[]
    local counts = Int[]
    for m in eachmatch(r"at (?:(\S+) \()?wasm://wasm/[0-9a-f]+:wasm-function\[(\d+)\]:0x([0-9a-f]+)", stack)
        local offset = parse(Int, m.captures[3]; base=16)
        local k = findlast(s -> s[1] <= offset, segs)
        local text = if k === nothing || length(segs[k]) < 4
            local fn = m.captures[1] === nothing ? "wasm-function[$(m.captures[2])]" : "`$(m.captures[1])`"
            "$fn at 0x$(m.captures[3]): no statement (the function's entry, or code the compiler generated)"
        elseif length(segs[k]) >= 5
            names[segs[k][5] + 1]
        else
            "$(sources[segs[k][2] + 1]):$(segs[k][3] + 1)"
        end
        if !isempty(out) && out[end] == text
            counts[end] += 1
        else
            push!(out, text); push!(counts, 1)
        end
    end
    return String[c == 1 ? t : "$t (× $c)" for (t, c) in zip(out, counts)]
end

"""
    run_driver_batch(bytes, fname, src; deadline, ninputs)

Lower-level: run a custom driver `src` (must `return` a results array) with
`bytes` in scope. Thin wrapper over `run_driver` for harnesses that already
build their own JS (the differential fuzzer's scalar/vector bridges).
"""
function run_driver_batch(bytes::Vector{UInt8}, src::AbstractString; deadline::Real = 8.0, ninputs::Int = 1)
    pool = get_pool()
    return run_driver(pool, enc_wasm(bytes), src; deadline = deadline, ninputs = ninputs)
end

end # module
