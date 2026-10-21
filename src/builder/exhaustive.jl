# The exhaustive match over a closed classification (dev/CHARTER.md C5, L199; MARCH 13.20).
#
# dart2wasm matches its closed sets with a switch Dart 3 checks for exhaustiveness at compile time:
# a sealed class (functions.dart:949 CallShape, matched at :836; constants.dart:30
# ConstantDefinition, matched at :109) or an enum (intrinsics.dart:22 MemberIntrinsic, matched at
# :1206). Julia checks no match, so WT checks its own when the match expands, which is when the
# package loads: a match that misses a member, names one twice, names a non-member or has a
# catch-all arm does not load. A classification is an `@enum`; this file depends on Base alone, so
# test/parity_ratchet.jl loads it by itself to plant the refusals (L199).

"""
    @exhaustive value begin
        Member => result
        (MemberA, MemberB) => result
    end

The match of `value`, an instance of an `@enum`, over that enum's members: each arm names one or
more members, every member is named exactly once, and no arm is a catch-all (`_`). The members
are resolved where the match is written, when it expands; an incomplete match is an error there,
so the function holding it does not load. The value is compared by identity, arm by arm, and
the first arm naming it answers.
parity(functions.dart:949 CallShape): dart's switch over a sealed class, exhaustive by its compiler.
precedent(rust: exhaustive match over a sealed enum, E0004; dart: switch over a sealed class, functions.dart:836)
"""
macro exhaustive(value, arms)
    (arms isa Expr && arms.head === :block) ||
        throw(ArgumentError("@exhaustive: the arms are a `begin … end` block of `Member => result`"))
    local named = Symbol[]
    local branches = Tuple{Vector{Symbol},Any}[]
    for a in arms.args
        a isa LineNumberNode && continue
        (a isa Expr && a.head === :call && length(a.args) == 3 && a.args[1] === :(=>)) ||
            throw(ArgumentError("@exhaustive: an arm is `Member => result` or `(A, B) => result`, not $(a)"))
        local lhs = a.args[2]
        local ms = (lhs isa Expr && lhs.head === :tuple) ? lhs.args : Any[lhs]
        local arm = Symbol[]
        for m in ms
            m isa Symbol || throw(ArgumentError("@exhaustive: an arm names members by their names, not $(m)"))
            m === :_ && throw(ArgumentError("@exhaustive: a catch-all arm `_` is refused; name every member"))
            m in named && throw(ArgumentError("@exhaustive: $(m) has two arms"))
            push!(named, m); push!(arm, m)
        end
        push!(branches, (arm, a.args[3]))
    end
    isempty(named) && throw(ArgumentError("@exhaustive: a match with no arm"))
    # the classification: the enum of the first member, resolved where the match is written
    isdefined(__module__, named[1]) ||
        throw(ArgumentError("@exhaustive: $(named[1]) is not defined in $(__module__)"))
    local E = typeof(getfield(__module__, named[1]))
    E <: Base.Enum || throw(ArgumentError("@exhaustive: $(named[1]) is a $(E), no @enum's member"))
    for m in named
        (isdefined(__module__, m) && getfield(__module__, m) isa E) ||
            throw(ArgumentError("@exhaustive over $(nameof(E)): $(m) is not one of its members"))
    end
    local missed = sort!([Symbol(x) for x in instances(E) if !(Symbol(x) in named)])
    isempty(missed) ||
        throw(ArgumentError("@exhaustive over $(nameof(E)): no arm for $(join(missed, ", "))"))
    local v = gensym("member")
    # an enum's value is always one of its members, which the arms all name: the last branch is
    # unreachable, and raises rather than answer for a value no arm names
    local ex = :(throw(ArgumentError(string("@exhaustive over ", $(string(nameof(E))), ": ", $v, " is no member"))))
    for (arm, body) in reverse(branches)
        local cond = foldr((m, acc) -> :($v === $(esc(m)) || $acc), arm[1:end-1]; init = :($v === $(esc(arm[end]))))
        ex = Expr(:if, cond, esc(body), ex)
    end
    return Expr(:let, Expr(:(=), v, esc(value)), Expr(:block, ex))
end
