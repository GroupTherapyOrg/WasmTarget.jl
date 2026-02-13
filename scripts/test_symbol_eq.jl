using WasmTarget

# Test 1: Simple Symbol === comparison
test_sym_eq1(s::Symbol) = s === :hello ? Int32(1) : Int32(0)

# Test 2: Multiple Symbol === comparisons (similar to parse! dispatch)
function test_sym_dispatch(s::Symbol)::Int32
    if s === :all
        return Int32(1)
    elseif s === :statement
        return Int32(2)
    elseif s === :atom
        return Int32(3)
    else
        return Int32(0)
    end
end

# Test 3: Symbol phi + === (closer to parse! pattern)
function test_sym_phi(s::Symbol)::Int32
    # Create a phi: if s is :toplevel, remap to :all
    rule = s === :toplevel ? :all : s
    if rule === :all
        return Int32(10)
    elseif rule === :statement
        return Int32(20)
    else
        return Int32(0)
    end
end

println("=== Test 1: Symbol === comparison ===")
try
    bytes1 = WasmTarget.compile(test_sym_eq1, (Symbol,))
    println("Compiled test_sym_eq1: $(length(bytes1)) bytes")
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes1)
    val = read(`wasm-tools validate $tmpf`, String)
    println("Validates: ", isempty(val) ? "YES" : val)

    # Copy for Node.js testing
    cp(tmpf, "WasmTarget.jl/browser/test_sym_eq1.wasm"; force=true)
    println("Written to browser/test_sym_eq1.wasm")
catch e
    println("ERROR: ", e)
    if e isa Exception
        for line in split(sprint(showerror, e, catch_backtrace()), "\n")[1:min(5, end)]
            println("  ", line)
        end
    end
end

println("\n=== Test 2: Symbol dispatch ===")
try
    bytes2 = WasmTarget.compile(test_sym_dispatch, (Symbol,))
    println("Compiled test_sym_dispatch: $(length(bytes2)) bytes")
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes2)
    val = read(`wasm-tools validate $tmpf`, String)
    println("Validates: ", isempty(val) ? "YES" : val)

    cp(tmpf, "WasmTarget.jl/browser/test_sym_dispatch.wasm"; force=true)
    println("Written to browser/test_sym_dispatch.wasm")
catch e
    println("ERROR: ", e)
    if e isa Exception
        for line in split(sprint(showerror, e, catch_backtrace()), "\n")[1:min(5, end)]
            println("  ", line)
        end
    end
end

println("\n=== Test 3: Symbol phi + dispatch ===")
try
    bytes3 = WasmTarget.compile(test_sym_phi, (Symbol,))
    println("Compiled test_sym_phi: $(length(bytes3)) bytes")
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes3)
    val = read(`wasm-tools validate $tmpf`, String)
    println("Validates: ", isempty(val) ? "YES" : val)

    cp(tmpf, "WasmTarget.jl/browser/test_sym_phi.wasm"; force=true)
    println("Written to browser/test_sym_phi.wasm")
catch e
    println("ERROR: ", e)
    if e isa Exception
        for line in split(sprint(showerror, e, catch_backtrace()), "\n")[1:min(5, end)]
            println("  ", line)
        end
    end
end

# Native Julia ground truth
println("\n=== Native Julia Ground Truth ===")
println("test_sym_eq1(:hello) = ", test_sym_eq1(:hello))
println("test_sym_eq1(:world) = ", test_sym_eq1(:world))
println("test_sym_dispatch(:all) = ", test_sym_dispatch(:all))
println("test_sym_dispatch(:statement) = ", test_sym_dispatch(:statement))
println("test_sym_dispatch(:atom) = ", test_sym_dispatch(:atom))
println("test_sym_dispatch(:other) = ", test_sym_dispatch(:other))
println("test_sym_phi(:all) = ", test_sym_phi(:all))
println("test_sym_phi(:statement) = ", test_sym_phi(:statement))
println("test_sym_phi(:toplevel) = ", test_sym_phi(:toplevel))
println("test_sym_phi(:other) = ", test_sym_phi(:other))
