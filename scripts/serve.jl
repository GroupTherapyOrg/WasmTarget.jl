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

const PORT = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8080
const BASE_WASM = joinpath(dirname(@__DIR__), "base.wasm")

# Verify base.wasm exists
if !isfile(BASE_WASM)
    @error "base.wasm not found at $BASE_WASM. Run: julia --project=. scripts/build_base.jl"
    exit(1)
end

println("WasmTarget Compile Server")
println("  base.wasm: $BASE_WASM ($(filesize(BASE_WASM)) bytes)")
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
function compile_code(code::String)::Vector{UInt8}
    temp_mod = Module()

    if _has_function_defs(code)
        # Code defines functions — evaluate and discover them
        Base.eval(temp_mod, Meta.parse("begin\n$code\nend"))

        functions = []
        for name in names(temp_mod; all=false)
            name === nameof(temp_mod) && continue
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

        if isempty(functions)
            error("Code appears to define functions but none were found. Check syntax.")
        end

        return compile_with_base(functions; base_wasm_path=BASE_WASM)
    else
        # Bare expressions — wrap in main()
        wrapped = "function main()::Nothing\n$code\nreturn nothing\nend"
        Base.eval(temp_mod, Meta.parse(wrapped))
        main_fn = getfield(temp_mod, :main)
        return compile_with_base([(main_fn, (), "main")]; base_wasm_path=BASE_WASM)
    end
end

function handle_request(req::HTTP.Request)::HTTP.Response
    if req.method == "GET" && req.target == "/health"
        return HTTP.Response(200, ["Content-Type" => "application/json"],
                             body="""{"status":"ok","base_functions":108}""")
    end

    if req.method == "POST" && req.target == "/compile"
        try
            code = parse_code(req)
            t = @elapsed begin
                wasm_bytes = compile_code(code)
            end
            @info "Compiled $(length(wasm_bytes)) bytes in $(round(t, digits=2))s"
            return HTTP.Response(200, [
                "Content-Type" => "application/wasm",
                "X-Compile-Time" => string(round(t, digits=3)),
                "X-Wasm-Size" => string(length(wasm_bytes)),
                "Access-Control-Allow-Origin" => "*",
            ], body=wasm_bytes)
        catch e
            msg = sprint(showerror, e)
            @warn "Compile error: $msg"
            return HTTP.Response(400, [
                "Content-Type" => "application/json",
                "Access-Control-Allow-Origin" => "*",
            ], body="""{"error":$(repr(msg))}""")
        end
    end

    if req.method == "OPTIONS"
        return HTTP.Response(204, [
            "Access-Control-Allow-Origin" => "*",
            "Access-Control-Allow-Methods" => "POST, GET, OPTIONS",
            "Access-Control-Allow-Headers" => "Content-Type",
        ])
    end

    return HTTP.Response(404, body="Not found")
end

println("  Listening on http://localhost:$PORT")
println("  POST /compile — compile Julia code to Wasm")
println("  GET  /health  — health check")
println()

HTTP.serve(handle_request, "0.0.0.0", PORT)
