# WT answers Julia's isgraphemebreak! with utf8proc's grapheme rule over utf8proc's classes
# (src/codegen/interpreter.jl, "Grapheme breaks"): Julia's own method passes its state to the
# C library through the Ref's address. This checks the port against the library it replaces:
# for every state the rule reaches and every pair of classes utf8proc gives, the same break and
# the same next state; and for every codepoint, the same breaks as its class's representative,
# before and after it — so the class table captures everything the rule reads.
using Test
using WasmTarget

const _GBW = WasmTarget

function _gb_c(c1::UInt32, c2::UInt32, st::Int32)::Tuple{Bool,Int32}
    r = Ref{Int32}(st)
    b = ccall(:utf8proc_grapheme_break_stateful, Bool, (UInt32, UInt32, Ref{Int32}), c1, c2, r)
    return (b, r[])
end

@testset "the grapheme overlay is utf8proc's rule over utf8proc's classes" begin
    reps = Dict{Int32,UInt32}()
    for (s, k) in zip(_GBW._WT_GRAPHEME_STARTS, _GBW._WT_GRAPHEME_CLASSES)
        get!(reps, k, s)
    end
    @test length(reps) >= 15
    # the states reachable from 0
    states = Set{Int32}([Int32(0)])
    frontier = Int32[0]
    while !isempty(frontier)
        st = pop!(frontier)
        for c1 in values(reps), c2 in values(reps)
            s2 = _gb_c(c1, c2, st)[2]
            s2 in states || (push!(states, s2); push!(frontier, s2))
        end
    end
    wrong_rule = 0
    for st in states, (k1, c1) in reps, (k2, c2) in reps
        _gb_c(c1, c2, st) == _GBW._wt_grapheme_break_extended(k1, k2, st) || (wrong_rule += 1)
    end
    @test wrong_rule == 0
    wrong_class = 0
    for cp in 0x00000000:0x00110000
        rep = reps[_GBW._wt_grapheme_class_of(cp)]
        for o in values(reps)
            _gb_c(o, cp, Int32(0)) == _gb_c(o, rep, Int32(0)) || (wrong_class += 1)
            _gb_c(cp, o, Int32(0)) == _gb_c(rep, o, Int32(0)) || (wrong_class += 1)
        end
    end
    @test wrong_class == 0
end
