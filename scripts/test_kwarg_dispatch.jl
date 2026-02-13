using WasmTarget

# Simulate the kwarg wrapper pattern of parse!
# #parse!#73(rule::Symbol, ::typeof(parse!), stream::ParseStream)

struct FakeStream
    value::Int32
end

function fake_process(stream::FakeStream)
    stream
end

# Simulate the keyword wrapper pattern
function kwarg_wrapper(rule::Symbol, _func::typeof(fake_process), stream::FakeStream)::Int32
    if rule === :all
        return Int32(10)
    elseif rule === :statement
        return Int32(20)
    elseif rule === :atom
        return Int32(30)
    else
        return Int32(0)
    end
end

# The outer function that calls the kwarg wrapper (simulates _parse)
function outer_dispatch(s::FakeStream)::Int32
    # This is what _parse does: passes :statement as the rule
    return kwarg_wrapper(:statement, fake_process, s)
end

# Native Julia ground truth
println("=== Native Julia Ground Truth ===")
println("kwarg_wrapper(:all, fake_process, FakeStream(1)) = ", kwarg_wrapper(:all, fake_process, FakeStream(Int32(1))))
println("kwarg_wrapper(:statement, fake_process, FakeStream(1)) = ", kwarg_wrapper(:statement, fake_process, FakeStream(Int32(1))))
println("kwarg_wrapper(:atom, fake_process, FakeStream(1)) = ", kwarg_wrapper(:atom, fake_process, FakeStream(Int32(1))))
println("outer_dispatch(FakeStream(1)) = ", outer_dispatch(FakeStream(Int32(1))))

println("\n=== Compiling outer_dispatch ===")
try
    bytes = WasmTarget.compile(outer_dispatch, (FakeStream,))
    write("WasmTarget.jl/browser/test_kwarg_dispatch.wasm", bytes)
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
    val = read(`wasm-tools validate $tmpf`, String)
    println("$(length(bytes)) bytes, $nfuncs funcs, validates=$(isempty(val) ? "YES" : val)")

    # Print WAT to see what functions got compiled
    wat = read(`wasm-tools print $tmpf`, String)
    # Extract function signatures
    for line in split(wat, "\n")
        if occursin("(func ", line) && occursin("(param", line)
            println("  ", strip(line))
        end
    end
catch e
    println("ERROR: ", sprint(showerror, e)[1:min(300, end)])
end
