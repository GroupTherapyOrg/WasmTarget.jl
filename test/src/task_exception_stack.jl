# Julia's exception stack belongs to the task (julia/src/task.c:756 throw_internal pushes on every throw; :801
# jl_rethrow and :810 jl_rethrow_other raise its top, or ErrorException where it is empty; rtutils.c:364
# jl_excstack_state at an enter, :370 jl_restore_excstack at its pop_exception), ported in
# src/julia/runtime/rtutils.jl and read by src/code_generator.jl: a rethrow in a function its caller calls from
# inside a catch rethrows the caller's exception, one at depth 0 raises Julia's ErrorException, and a host call after one that escaped starts
# from the empty stack (src/functions.jl's export entry). dev/formal/TaskExcStack.tla models the design. Each
# case's answer is native Julia's, compared in both modules.
module TaskExceptionStackTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module XsCases
msg(m::String)::Int64 = m == "rethrow() not allowed outside a catch block" ? 4 :
    m == "rethrow(exc) not allowed outside a catch block" ? 5 : 6
kind(e)::Int64 = e isa ArgumentError ? 1 : e isa DomainError ? 2 : e isa ErrorException ? msg((e::ErrorException).msg::String) : 3
# rethrow() and rethrow(e) in a try body with the task's stack empty: Julia's ErrorException
outside(x::Int64)::Int64 = try; x > 0 && rethrow(); 0; catch e; kind(e); end
outside_other(x::Int64)::Int64 = try; x > 0 && rethrow(ArgumentError("a")); 0; catch e; kind(e); end
# a handled exception's pop_exception empties the stack again
@noinline handled(x::Int64)::Int64 = (try; throw(DomainError(x)); catch; end; x > 0 && rethrow(); 0)
after_handled(x::Int64)::Int64 = try; handled(x); catch e; kind(e); end
# a rethrow in a function its caller calls from inside a catch: the caller's exception, or e written over it
@noinline callee(x::Int64)::Int64 = (x > 0 && rethrow(); 0)
@noinline callee_other(x::Int64)::Int64 = (x > 0 && rethrow(DomainError(x)); 0)
caller(x::Int64)::Int64 = try; throw(ArgumentError("a")); catch; try; x == 1 ? callee(x) : callee_other(x); catch e; kind(e); end; end
# one call escapes, the next rethrows with nothing caught: its stack is empty again
escaped(x::Int64)::Int64 = x > 0 ? throw(DomainError(x)) : (try; rethrow(); catch e; kind(e); end)
end

const XC = XsCases

# the module run in node, one instance for two calls, as a host that catches the first call's escape and calls
# again: whether the first threw, and the second's answer
function two_calls(bytes::Vector{UInt8}, first::Int64, second::Int64)::String
    local path = tempname() * ".wasm"
    write(path, bytes)
    local script = "const m = new WebAssembly.Module(require('fs').readFileSync(process.argv[1])); " *
        "const dart = {stackTraceGetCurrent: () => new Error().stack, print: (s) => {}}; " *
        "for (const i of WebAssembly.Module.imports(m)) if (!(i.module === 'dart' && i.name in dart)) throw new Error('import ' + i.module + '.' + i.name); " *
        "const f = new WebAssembly.Instance(m, {dart}).exports[WebAssembly.Module.exports(m).find(e => e.kind === 'function').name]; " *
        "let a; try { f($(first)n); a = 'returned'; } catch (e) { a = 'threw'; } " *
        "console.log(a + ' ' + f($(second)n));"
    local node = something(Main.WTChild.node_binary(), "node")
    local out = readchomp(`$node -e $script $path`)
    rm(path)
    return out
end

@testset "Julia's exception stack is the task's" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((XC.outside, (1, 0)), (XC.outside_other, (1,)), (XC.after_handled, (1, 0)), (XC.caller, (1, 2, 0)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("task_exception_stack/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: ErrorException at depth 0 (rethrow() 4, rethrow(e) 5), none raised, the caller's ArgumentError
    # rethrown and overwritten by the callee (a lexical reading would answer 4 and 5)
    @test [c.native for c in cases] == [4, 0, 5, 4, 0, 1, 2, 0]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
    # a call after one that escaped: Julia's host restores the stack after its catch (julia.h:2555), so the second
    # call's rethrow() raises ErrorException, never the first call's DomainError (2)
    @test (try; XC.escaped(Int64(1)); "returned"; catch; "threw"; end) == "threw" && XC.escaped(Int64(0)) == 4
    local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, XC.escaped, (Int64(1),))
    for bytes in (p, o)
        isempty(bytes) && continue
        @test two_calls(bytes, Int64(1), Int64(0)) == "threw 4"
    end
end

end # module
