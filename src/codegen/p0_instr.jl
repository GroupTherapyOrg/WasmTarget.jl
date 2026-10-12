# THROWAWAY (batch 116d-3 Part 0 instrumentation; never landed)
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
p0_bucket(n::Integer) = n <= 1 ? "1" : n <= 4 ? "2-4" : n <= 16 ? "5-16" : n <= 64 ? "17-64" :
    n <= 256 ? "65-256" : n <= 4096 ? "257-4096" : ">4096"
function p0_kindof(@nospecialize(T))::String
    T isa DataType || return "other"
    T <: Tuple && return "tuple"
    T <: Exception && return "exception"
    T <: Function && return "function"
    isprimitivetype(T) && return "primitive"
    T.name.module === Core && return "core-struct"
    T.name.module === Base && return "base-struct"
    return "struct"
end
p0add!(k::AbstractString, n::Integer) = (P0[String(k)] = get(P0, String(k), 0) + Int(n); nothing)
const P0SET = Dict{String,Set{String}}()
p0set!(k::AbstractString, v::AbstractString) = (push!(get!(() -> Set{String}(), P0SET, String(k)), String(v)); nothing)
p0_short(@nospecialize(x)) = first(replace(sprint(show, x), "MethodInstance for " => ""), 160)
p0lbl(ctx) = try
    first(replace(string(something(ctx.func_ref, "?")), "\n" => " "), 120)
catch
    "?"
end
# a port of Julia's basic_blocks_starts + compute_basic_blocks (Compiler/src/ssair/ir.jl:46, :93)
# over the NIR: block starts, blocks (first, last), succs and preds (catch edges included)
function p0_nir_cfg(nir)
    local n = length(nir)
    local starts = BitSet([1])
    for (idx, rec) in enumerate(nir)
        local s = rec.node
        if s isa NirGotoIfNot
            push!(starts, idx + 1); push!(starts, s.target)
        elseif s isa NirReturn
            idx < n && push!(starts, idx + 1)
        elseif s isa NirGoto
            idx < n && push!(starts, idx + 1); push!(starts, s.target)
        elseif s isa NirEnter
            push!(starts, idx); push!(starts, idx + 1)
            s.catch_target != 0 && push!(starts, s.catch_target)
        elseif s isa NirLeave
            push!(starts, idx + 1)
        end
        s isa NirPhi && any(==(idx - 1), s.edges) && push!(starts, idx)
    end
    push!(starts, n + 1)
    local st = sort!(collect(starts)); filter!(i -> i <= n + 1, st)
    local blocks = [(st[k], st[k + 1] - 1) for k in 1:length(st) - 1]
    local bof = Dict{Int,Int}(); for (k, (a, z)) in enumerate(blocks), i in a:z; bof[i] = k; end
    local succs = [Int[] for _ in blocks]
    for (k, (a, z)) in enumerate(blocks)
        local t = nir[z].node
        t isa NirReturn && continue
        if t isa NirGoto
            push!(succs[k], bof[t.target]); continue
        end
        if t isa NirGotoIfNot
            local d = bof[t.target]
            d == k + 1 || push!(succs[k], d)
        elseif t isa NirEnter && t.catch_target != 0
            push!(succs[k], bof[t.catch_target])
        end
        k + 1 <= length(blocks) && push!(succs[k], k + 1)
    end
    return (starts=Set(first.(blocks)), blocks=blocks, bof=bof, succs=succs)
end
# statement successors from a block CFG
function p0_stmt_succs(cfg, pc)
    local k = cfg.bof[pc]; local (a, z) = cfg.blocks[k]
    pc < z && return Int[pc + 1]
    return Int[cfg.blocks[s][1] for s in cfg.succs[k]]
end
