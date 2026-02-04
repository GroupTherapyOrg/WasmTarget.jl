using WasmTarget

function push1_read(n::Int64)::Int64
    v = Int64[]
    push!(v, Int64(42))
    return v[1]
end

function push2_read(n::Int64)::Int64
    v = Int64[]
    push!(v, Int64(10))
    push!(v, Int64(20))
    return v[1]
end

function push3_read(n::Int64)::Int64
    v = Int64[]
    push!(v, Int64(10))
    push!(v, Int64(20))
    push!(v, Int64(30))
    return v[1]
end

function push3_len(n::Int64)::Int64
    v = Int64[]
    push!(v, Int64(10))
    push!(v, Int64(20))
    push!(v, Int64(30))
    return Int64(length(v))
end

for (name, f) in [("push1_read", push1_read), ("push2_read", push2_read),
                   ("push3_read", push3_read), ("push3_len", push3_len)]
    println("=== $name ===")
    bytes = compile(f, (Int64,))
    write("/tmp/test_$(name).wasm", bytes)
    try
        run(`wasm-tools validate --features=gc /tmp/test_$(name).wasm`)
        println("VALIDATES: $(length(bytes)) bytes")
    catch
        println("VALIDATION FAILED")
    end
end
