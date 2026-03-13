#!/usr/bin/env julia
# Compile server: POST /compile → compiled Wasm bytes
# Run: julia +1.12 --project=. scripts/serve.jl [port]
#
# Endpoints:
#   POST /compile  — Compile Julia code to Wasm, merge with base.wasm
#                    Body: Julia source code (text/plain or application/json with "code" field)
#                    Returns: application/wasm bytes
#   GET  /health   — Health check

using WasmTarget
using HTTP
using JSON
using SHA

const PORT = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8080
const BASE_WASM = joinpath(dirname(@__DIR__), "base.wasm")

# Verify base.wasm exists
if !isfile(BASE_WASM)
    @error "base.wasm not found at $BASE_WASM. Run: julia --project=. scripts/build_base.jl"
    exit(1)
end

const BASE_WASM_BYTES = read(BASE_WASM)
const BASE_WASM_HASH = bytes2hex(sha256(BASE_WASM_BYTES))

# Compile cache: SHA-256(code || base_hash) → wasm bytes
const CACHE_MAX_ENTRIES = 256
const compile_cache = Dict{String, Vector{UInt8}}()
const cache_access_order = Vector{String}()  # LRU tracking
const cache_lock = ReentrantLock()

function cache_key(code::String)::String
    return bytes2hex(sha256(code * BASE_WASM_HASH))
end

function cache_get(key::String)::Union{Nothing, Vector{UInt8}}
    lock(cache_lock) do
        if haskey(compile_cache, key)
            # Move to end (most recently used)
            filter!(k -> k != key, cache_access_order)
            push!(cache_access_order, key)
            return compile_cache[key]
        end
        return nothing
    end
end

function cache_put!(key::String, bytes::Vector{UInt8})
    lock(cache_lock) do
        # Evict LRU if at capacity
        while length(compile_cache) >= CACHE_MAX_ENTRIES && !isempty(cache_access_order)
            evict_key = popfirst!(cache_access_order)
            delete!(compile_cache, evict_key)
        end
        compile_cache[key] = bytes
        push!(cache_access_order, key)
    end
end

# Rate limiting: per-IP request tracking
const RATE_LIMIT_WINDOW = 60  # seconds
const RATE_LIMIT_MAX = 10     # requests per window
const CODE_SIZE_LIMIT = 10_000  # bytes
const COMPILE_TIMEOUT = 30.0    # seconds
const rate_limits = Dict{String, Vector{Float64}}()  # IP → timestamps
const rate_lock = ReentrantLock()

function check_rate_limit(ip::String)::Bool
    now = time()
    lock(rate_lock) do
        timestamps = get!(rate_limits, ip, Float64[])
        filter!(t -> now - t < RATE_LIMIT_WINDOW, timestamps)
        rate_limits[ip] = timestamps
        if length(timestamps) >= RATE_LIMIT_MAX
            return false
        end
        push!(timestamps, now)
        return true
    end
end

println("WasmTarget Compile Server")
println("  base.wasm: $BASE_WASM ($(length(BASE_WASM_BYTES)) bytes)")
println("  Port: $PORT")

"""
Parse Julia code from request body.
Supports text/plain (raw code) or JSON with "code" field.
"""
function parse_code(req::HTTP.Request)::String
    body = String(req.body)
    content_type = HTTP.header(req, "Content-Type", "text/plain")
    if startswith(content_type, "application/json")
        data = JSON.parse(body)
        code = get(data, "code", nothing)
        code === nothing && error("JSON body must have a \"code\" field")
        return String(code)
    end
    return body
end

"""
Check if code defines any functions (heuristic: contains `function` keyword or `f(args) =` pattern).
"""
function _has_function_defs(code::String)::Bool
    return occursin(r"^\s*(function\s|[a-zA-Z_]\w*\s*\([^)]*\)\s*=)"m, code)
end

"""
Compile Julia code string to Wasm bytes.
If code defines functions, compiles them directly.
If code is bare expressions (e.g. `println(1+1)`), wraps in a `main()` function.
Merges result with base.wasm.
"""
function _discover_and_compile(temp_mod::Module, has_funcs::Bool)::Vector{UInt8}
    if has_funcs
        functions = []
        skip_names = Set([:eval, :include, nameof(temp_mod)])
        for name in names(temp_mod; all=true)
            name in skip_names && continue
            startswith(string(name), '#') && continue
            isdefined(temp_mod, name) || continue
            f = getfield(temp_mod, name)
            if f isa Function
                for m in methods(f)
                    sig = m.sig
                    if sig isa DataType && sig <: Tuple
                        arg_types = Tuple(sig.parameters[2:end])
                        push!(functions, (f, arg_types, string(name)))
                    end
                end
            end
        end
        isempty(functions) && error("Code appears to define functions but none were found. Check syntax.")
        return compile_with_base(functions; base_wasm_path=BASE_WASM)
    else
        main_fn = getfield(temp_mod, :main)
        return compile_with_base([(main_fn, (), "main")]; base_wasm_path=BASE_WASM)
    end
end

function compile_code(code::String)::Vector{UInt8}
    temp_mod = Module()
    has_funcs = _has_function_defs(code)

    # Step 1: eval creates bindings (bumps world age)
    if has_funcs
        Base.eval(temp_mod, Meta.parse("begin\n$code\nend"))
    else
        wrapped = "function main()::Nothing\n$code\nreturn nothing\nend"
        Base.eval(temp_mod, Meta.parse(wrapped))
    end

    # Step 2: invokelatest accesses bindings in latest world age
    return Base.invokelatest(_discover_and_compile, temp_mod, has_funcs)
end

function handle_request(req::HTTP.Request)::HTTP.Response
    if req.method == "GET" && req.target == "/health"
        return HTTP.Response(200, ["Content-Type" => "application/json"],
                             body="""{"status":"ok","base_functions":108}""")
    end

    # Serve base.wasm with long cache (V8 code caching requires stable GET URL + Cache-Control)
    if req.method == "GET" && req.target == "/base.wasm"
        return HTTP.Response(200, [
            "Content-Type" => "application/wasm",
            "Cache-Control" => "public, max-age=31536000, immutable",
            "Access-Control-Allow-Origin" => "*",
        ], body=BASE_WASM_BYTES)
    end

    if req.method == "POST" && req.target == "/compile"
        # Rate limiting
        ip = HTTP.header(req, "X-Forwarded-For", "127.0.0.1")
        if !check_rate_limit(ip)
            return HTTP.Response(429, [
                "Content-Type" => "application/json",
                "Access-Control-Allow-Origin" => "*",
                "Retry-After" => string(RATE_LIMIT_WINDOW),
            ], body="""{"error":"Rate limit exceeded. Max $(RATE_LIMIT_MAX) requests per $(RATE_LIMIT_WINDOW)s."}""")
        end

        try
            code = parse_code(req)

            # Code size limit
            if sizeof(code) > CODE_SIZE_LIMIT
                return HTTP.Response(413, [
                    "Content-Type" => "application/json",
                    "Access-Control-Allow-Origin" => "*",
                ], body="""{"error":"Code too large ($(sizeof(code)) bytes > $(CODE_SIZE_LIMIT) limit)"}""")
            end

            # Check cache
            key = cache_key(code)
            cached = cache_get(key)
            if cached !== nothing
                @info "Cache hit: $(length(cached)) bytes"
                return HTTP.Response(200, [
                    "Content-Type" => "application/wasm",
                    "X-Compile-Time" => "0",
                    "X-Cache" => "hit",
                    "X-Wasm-Size" => string(length(cached)),
                    "Access-Control-Allow-Origin" => "*",
                ], body=cached)
            end

            # Compile with timeout
            wasm_bytes = nothing
            compile_task = @async compile_code(code)
            timer = Timer(COMPILE_TIMEOUT)
            while !istaskdone(compile_task) && isopen(timer)
                sleep(0.1)
            end
            close(timer)

            if !istaskdone(compile_task)
                @warn "Compile timeout after $(COMPILE_TIMEOUT)s"
                return HTTP.Response(504, [
                    "Content-Type" => "application/json",
                    "Access-Control-Allow-Origin" => "*",
                ], body="""{"error":"Compilation timed out after $(Int(COMPILE_TIMEOUT))s"}""")
            end

            wasm_bytes = fetch(compile_task)
            t = 0.0  # timing not easily available from async; use X-Cache: miss
            @info "Compiled $(length(wasm_bytes)) bytes"

            # Store in cache
            cache_put!(key, wasm_bytes)

            return HTTP.Response(200, [
                "Content-Type" => "application/wasm",
                "X-Cache" => "miss",
                "X-Wasm-Size" => string(length(wasm_bytes)),
                "Access-Control-Allow-Origin" => "*",
            ], body=wasm_bytes)
        catch e
            msg = sprint(showerror, e)
            @warn "Compile error: $msg"
            # Try to extract line number from error message
            err_obj = Dict{String,Any}("error" => msg)
            m = match(r"@ (?:none|Main\.anonymous):(\d+)", msg)
            if m !== nothing
                err_obj["line"] = parse(Int, m.captures[1])
            end
            m2 = match(r"Error @ none:(\d+):(\d+)", msg)
            if m2 !== nothing
                err_obj["line"] = parse(Int, m2.captures[1])
                err_obj["column"] = parse(Int, m2.captures[2])
            end
            return HTTP.Response(400, [
                "Content-Type" => "application/json",
                "Access-Control-Allow-Origin" => "*",
            ], body=JSON.json(err_obj))
        end
    end

    if req.method == "OPTIONS"
        return HTTP.Response(204, [
            "Access-Control-Allow-Origin" => "*",
            "Access-Control-Allow-Methods" => "POST, GET, OPTIONS",
            "Access-Control-Allow-Headers" => "Content-Type",
        ])
    end

    # Serve playground static files
    if req.method == "GET"
        playground_dir = joinpath(dirname(@__DIR__), "playground")
        path = req.target == "/" ? "/index.html" : req.target
        filepath = joinpath(playground_dir, lstrip(path, '/'))
        filepath = realpath(filepath)  # resolve symlinks
        if startswith(filepath, playground_dir) && isfile(filepath)
            content_type = endswith(filepath, ".html") ? "text/html" :
                           endswith(filepath, ".js") ? "application/javascript" :
                           endswith(filepath, ".css") ? "text/css" :
                           "application/octet-stream"
            return HTTP.Response(200, ["Content-Type" => content_type], body=read(filepath))
        end
    end

    return HTTP.Response(404, body="Not found")
end

const PLAYGROUND_DIR = joinpath(dirname(@__DIR__), "playground")
println("  Listening on http://localhost:$PORT")
println("  GET  /         — playground UI ($(PLAYGROUND_DIR))")
println("  POST /compile  — compile Julia code to Wasm")
println("  GET  /health   — health check")
println()

HTTP.serve(handle_request, "0.0.0.0", PORT)
