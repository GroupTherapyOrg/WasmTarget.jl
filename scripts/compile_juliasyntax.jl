using WasmTarget
using JuliaSyntax

# Wrapper to handle keyword arguments and types
function compile_entry(text::String)
    # create stream
    stream = JuliaSyntax.ParseStream(text)
    # parse as statement (returns GreenNode)
    # :statement is a Symbol, which might need special handling if passed as constant
    return JuliaSyntax.parse!(stream, rule=:statement)
end

function compile_test()
    println("Starting JuliaSyntax compilation...")

    funcs = [
        (compile_entry, (String,)),
    ]
    
    try
        # This will fail if PURE-019 didn't fix NamedTuple/Kwargs
        # It will also fail if other blockers exist (PURE-013, 014, etc.)
        bytes = compile_multi(funcs)
        println("SUCCESS: Compiled $(length(bytes)) bytes")
        
        open("juliasyntax.wasm", "w") do io
            write(io, bytes)
        end
    catch e
        showerror(stdout, e, catch_backtrace())
        println()
        exit(1)
    end
end

compile_test()
