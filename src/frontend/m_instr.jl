# THROWAWAY (batch 116d-3 review measurement instrumentation; never landed)
const P0 = Dict{String,Int}()
const P0EX = Dict{String,Vector{String}}()
const P0MAX = Dict{String,Int}()
const P0_LABEL = Ref{String}("?")
const P0_STMT_FIRED = Ref{Any}(nothing)   # (objectid(ctx), idx) of the last statement-check firing
const P0_ISA_STATIC = Ref{Any}(nothing)   # the static type of the isa being lowered
function __init__()
    empty!(P0); empty!(P0EX); empty!(P0MAX)
    atexit(p0_dump)
end
function p0!(key::AbstractString, ex::AbstractString="")
    k = String(key)
    P0[k] = get(P0, k, 0) + 1
    if !isempty(ex)
        v = get!(() -> String[], P0EX, k)
        e = first(String(ex), 400)
        length(v) < 10 && !(e in v) && push!(v, e)
    end
    nothing
end
p0max!(key::AbstractString, n::Integer, ex::AbstractString="") =
    (n > get(P0MAX, String(key), -1) && (P0MAX[String(key)] = Int(n); p0!(key * " (new max)", "$n " * ex)); nothing)
function p0_dump()
    io = stderr
    println(io, "P0BEGIN")
    for k in sort!(collect(keys(P0)))
        println(io, "P0\t", k, "\t", P0[k])
        for e in get(P0EX, k, String[])
            println(io, "P0EX\t", k, "\t", replace(e, '\n' => ' ', '\t' => ' '))
        end
    end
    for k in sort!(collect(keys(P0MAX)))
        println(io, "P0MAX\t", k, "\t", P0MAX[k])
    end
    for k in sort!(collect(keys(P0SET)))
        local vs = sort!(collect(P0SET[k]))
        println(io, "P0SETN\t", k, "\t", length(vs))
        for v in vs
            println(io, "P0SETV\t", k, "\t", replace(v, '\n' => ' ', '\t' => ' '))
        end
    end
    println(io, "P0END")
end
const P0SET = Dict{String,Set{String}}()
p0set!(k::AbstractString, v::AbstractString) = (push!(get!(() -> Set{String}(), P0SET, String(k)), String(v)); nothing)
p0lbl(ctx) = try
    first(replace(string(something(ctx.func_ref, "?")), "\n" => " "), 120)
catch
    "?"
end
function m_old_loop_bounds(nir)
    local last_back_edge = Dict{Int,Int}()
    for (i, rec) in enumerate(nir)
        rec.node isa NirGoto && rec.node.target < i && (last_back_edge[rec.node.target] = i)
    end
    return sort!(Tuple{Int,Int}[(h, be) for (h, be) in last_back_edge])
end
