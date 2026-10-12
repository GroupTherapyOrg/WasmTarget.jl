# THROWAWAY (batch 116e-2 Part 0 instrumentation; never landed)
const P0 = Dict{String,Int}()
const P0EX = Dict{String,Vector{String}}()
const P0MAX = Dict{String,Int}()
const P0_LABEL = Ref{String}("?")
const P0_STMT_FIRED = Ref{Any}(nothing)   # (objectid(ctx), idx) of the last statement-check firing
const P0_ISA_STATIC = Ref{Any}(nothing)   # the static type of the isa being lowered
function __init__()
    empty!(P0); empty!(P0EX); empty!(P0MAX); empty!(P0SET)
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
p0_short(@nospecialize(x)) = first(replace(sprint(show, x), "MethodInstance for " => ""), 160)
p0lbl(ctx) = try
    first(replace(string(something(ctx.func_ref, "?")), "\n" => " "), 120)
catch
    "?"
end
function p0_obj_kind(@nospecialize(o))::String
    o isa Core.IntrinsicFunction && return "IntrinsicFunction"
    o isa Core.Builtin && return "Builtin"
    o isa Type && return "type object"
    o isa Function && Base.issingletontype(typeof(o)) && return "singleton function"
    o isa Function && return "capture-holding function"
    Base.issingletontype(typeof(o)) && return "singleton non-function"
    return "other value"
end
function p0_callee_kind(@nospecialize(c))::String
    c === nothing && return "nothing"
    c isa GlobalRef && return "unbound GlobalRef"
    c isa NirLiteral && return "NirLiteral(" * p0_obj_kind(c.value) * ")"
    c isa NirNode && return "node " * string(nameof(typeof(c)))
    return "raw " * p0_obj_kind(c)
end
p0_plain(k::String) = startswith(k, "raw singleton function") || startswith(k, "raw Builtin") || startswith(k, "node ") ||
    startswith(k, "raw IntrinsicFunction") || k == "nothing"
function p0_arm(@nospecialize(x), code_info, slot_types)::String
    if x isa Core.SSAValue && 1 <= x.id <= length(code_info.code)
        def = code_info.code[x.id]
        def isa GlobalRef && return "SSA of a global"
        ssatypes = code_info.ssavaluetypes
        T = (ssatypes isa Vector && x.id <= length(ssatypes)) ? ssatypes[x.id] : nothing
        T isa Core.Const && return "SSA Core.Const"
        def isa Core.PiNode && def.val isa Core.SSAValue && 1 <= def.val.id <= length(code_info.code) &&
            code_info.code[def.val.id] isa GlobalRef && return "SSA pi of a global (unresolved)"
        return "SSA"
    elseif x isa Core.Argument && 1 <= x.n <= length(slot_types)
        T = slot_types[x.n]
        (T isa DataType && Base.issingletontype(T) && T <: Function) && return "argument of a singleton type"
        return "argument"
    end
    x isa GlobalRef && return "GlobalRef"
    x isa QuoteNode && return "QuoteNode"
    x isa Function && Base.issingletontype(typeof(x)) && return "embedded singleton function"
    return "embedded " * p0_obj_kind(x)
end
p0add!(k::AbstractString, n::Integer) = (P0[String(k)] = get(P0, String(k), 0) + Int(n); nothing)
