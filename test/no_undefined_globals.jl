# Every global a method of WasmTarget names is defined. A call to a deleted function is an
# UndefVarError only on the path that reaches it, so no lane that misses that path sees it:
# compile.jl called `generate_dispatch_caller_body` for a year after aa809d94 deleted it
# (dev/AUDIT.md A3S4). Read from Julia's own lowered code of every method the package's
# modules define, so a name spelled any way is checked, and a local, an argument or a quoted
# name is not one.
using Test
using WasmTarget

function _wt_modules(root::Module)::Vector{Module}
    local mods = Module[root]
    local i = 1
    while i <= length(mods)
        local m = mods[i]
        for n in names(m; all=true)
            isdefined(m, n) || continue
            local v = getfield(m, n)
            v isa Module && v !== m && parentmodule(v) === m && !(v in mods) && push!(mods, v)
        end
        i += 1
    end
    return mods
end

function _wt_global_refs!(out::Vector{GlobalRef}, @nospecialize(x))
    if x isa GlobalRef
        push!(out, x)
    elseif x isa Expr
        x.head === :quote && return out
        foreach(a -> _wt_global_refs!(out, a), x.args)
    elseif x isa Core.CodeInfo
        foreach(s -> _wt_global_refs!(out, s), x.code)
    end
    return out
end

function undefined_global_refs(root::Module)::Vector{String}
    local mods = _wt_modules(root)
    local bad = String[]
    local seen = Set{Method}()
    for mod in mods, n in names(mod; all=true)
        isdefined(mod, n) || continue
        local v = getfield(mod, n)
        (v isa Function || v isa DataType || v isa UnionAll) || continue
        for m in methods(v)
            (m.module in mods && !(m in seen) && isdefined(m, :source) && m.source !== nothing) || continue
            push!(seen, m)
            for g in _wt_global_refs!(GlobalRef[], Base.uncompressed_ast(m))
                (g.mod in mods && !isdefined(g.mod, g.name)) &&
                    push!(bad, "$(g.mod).$(g.name) in $(m.name) at $(m.file):$(m.line)")
            end
        end
    end
    return unique!(sort!(bad))
end

@testset "every global a WasmTarget method names is defined" begin
    local bad = undefined_global_refs(WasmTarget)
    isempty(bad) || foreach(b -> println(stderr, "  undefined: ", b), bad)
    @test isempty(bad)
end
