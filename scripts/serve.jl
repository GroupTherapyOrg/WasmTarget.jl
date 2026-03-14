#!/usr/bin/env julia
# WasmTarget.jl — Compile server + docs site
#
# Serves the docs site (static files) and compile API from the same origin.
#
# Usage:
#   julia +1.12 --project=. scripts/serve.jl [port]
#
# Endpoints:
#   GET  /             — Docs site (from docs/dist/)
#   POST /compile      — Compile Julia code to Wasm (merged with base.wasm)
#   GET  /base.wasm    — Pre-compiled base runtime
#   GET  /health       — Health check

using WasmTarget
using HTTP
using JSON
using SHA

const PORT = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8080
const BASE_WASM = joinpath(dirname(@__DIR__), "base.wasm")
const DOCS_DIR = joinpath(dirname(@__DIR__), "docs", "dist")

# Verify base.wasm exists
if !isfile(BASE_WASM)
    @error "base.wasm not found at $BASE_WASM. Run: julia --project=. scripts/build_base.jl"
    exit(1)
end

if !isdir(DOCS_DIR)
    @warn "docs/dist/ not found — static site serving disabled. Build with: julia --project=../Therapy.jl docs/app.jl build"
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
const COMPILE_TIMEOUT = 120.0   # seconds (first compile needs JIT warmup)
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
println("  docs dir:  $DOCS_DIR $(isdir(DOCS_DIR) ? "(ready)" : "(not built)")")
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
Compile Julia code to Wasm bytes.
Always wraps in main()::Nothing so bare expressions just work.
"""
function compile_code(code::String)::Vector{UInt8}
    temp_mod = Module()
    wrapped = "function main()::Nothing\n$code\nreturn nothing\nend"
    Base.eval(temp_mod, Meta.parse(wrapped))
    return Base.invokelatest() do
        main_fn = getfield(temp_mod, :main)
        compile(main_fn, ())
    end
end

# MIME types for static file serving
const MIME_TYPES = Dict(
    ".html" => "text/html; charset=utf-8",
    ".css"  => "text/css; charset=utf-8",
    ".js"   => "application/javascript; charset=utf-8",
    ".json" => "application/json",
    ".wasm" => "application/wasm",
    ".svg"  => "image/svg+xml",
    ".png"  => "image/png",
    ".jpg"  => "image/jpeg",
    ".ico"  => "image/x-icon",
    ".woff" => "font/woff",
    ".woff2" => "font/woff2",
    ".ttf"  => "font/ttf",
    ".txt"  => "text/plain",
)

function get_mime(path::String)::String
    ext = lowercase(splitext(path)[2])
    return get(MIME_TYPES, ext, "application/octet-stream")
end

function handle_request(req::HTTP.Request)::HTTP.Response
    # Redirect bare root to base_path
    if req.method == "GET" && req.target == "/"
        return HTTP.Response(302, ["Location" => "/WasmTarget.jl/"])
    end

    # --- API endpoints ---

    if req.method == "GET" && req.target == "/health"
        return HTTP.Response(200, ["Content-Type" => "application/json"],
                             body="""{"status":"ok","base_functions":108}""")
    end

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

    # --- Static file serving (docs/dist/) ---

    if req.method == "GET" && isdir(DOCS_DIR)
        # Parse path, strip query string
        path = split(req.target, "?")[1]
        path = HTTP.URIs.unescapeuri(path)

        # Strip base_path prefix (/WasmTarget.jl) so GitHub Pages builds work locally
        base_prefix = "/WasmTarget.jl"
        if startswith(path, base_prefix)
            path = path[length(base_prefix)+1:end]
            isempty(path) && (path = "/")
        end

        # Try exact file, then path/index.html for directory-style routes
        candidates = [
            joinpath(DOCS_DIR, lstrip(path, '/')),
            joinpath(DOCS_DIR, lstrip(path, '/'), "index.html"),
        ]

        for filepath in candidates
            isfile(filepath) || continue
            # Path traversal protection
            real = realpath(filepath)
            startswith(real, realpath(DOCS_DIR)) || continue
            return HTTP.Response(200, [
                "Content-Type" => get_mime(real),
                "Cache-Control" => endswith(real, ".html") ? "no-cache" : "public, max-age=3600",
            ], body=read(filepath))
        end
    end

    return HTTP.Response(404, ["Content-Type" => "text/html"],
                         body="<h1>404 Not Found</h1><p>$(req.target)</p>")
end

println()
println("  Listening on http://localhost:$PORT")
println()
println("  Endpoints:")
println("    GET  /           — docs site ($(DOCS_DIR))")
println("    POST /compile    — compile Julia → Wasm")
println("    GET  /base.wasm  — pre-compiled base runtime")
println("    GET  /health     — health check")
println()
if isdir(DOCS_DIR)
    println("  Playground: http://localhost:$PORT/WasmTarget.jl/playground/")
else
    println("  ⚠  Build docs first: julia --project=../Therapy.jl docs/app.jl build")
end
println()

# Warmup compile — JIT-compile WasmTarget.jl so first browser request is fast
print("  Warming up compiler...")
try
    warmup_t = @elapsed compile_code("_warmup(x::Int32)::Int32 = x + Int32(1)")
    println(" done ($(round(warmup_t, digits=1))s)")
catch e
    println(" failed: $(sprint(showerror, e))")
end
println()

HTTP.serve(handle_request, "0.0.0.0", PORT)
