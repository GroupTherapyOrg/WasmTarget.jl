# Minimal repro — WT codegen bug: mutating a MUTABLE-STRUCT field across
# RECURSIVE calls traps `unreachable` at runtime (with a push!-ed Vector field),
# or fails wasm validation (`func N failed to validate: type mismatch`) without
# one. The SAME struct ops in a LINEAR loop compile + run correctly, so the
# trigger is recursion-specific, NOT the struct/NTuple/Vector ops themselves.
#
# Discovered reframing the Snapshot.jl "turtles-art" L-system fractal
# (`lindenmayer`, a binary recursion that save/restores the turtle's pos+heading).
# The notebook was reframed to an iterative explicit-stack version (which compiles
# — see `run_linear` below); this repro keeps the recursive form for the WT loop.
#
# Run:  julia --project=. test/fuzz/repro_recursion_mutstruct.jl
# Expect: RECURSION -> "trap: unreachable" (pass=false); LINEAR -> pass=true.

using WasmTarget
include(joinpath(@__DIR__, "..", "utils.jl"))

mutable struct Tt
    pos::NTuple{2,Float64}
    heading::Float64
    xs::Vector{Vector{Float64}}
end

# BUG: self-recursive fn that reads a struct field into a local, mutates the
# field, recurses (twice), then RESTORES the field from the local.
function lind!(t::Tt, depth)
    if depth < 8
        op = t.pos
        oh = t.heading
        push!(t.xs, [t.pos[1], t.pos[1] + 1.0])
        t.pos = (t.pos[1] + 1.0, t.pos[2])
        t.heading += 18.0
        lind!(t, depth + 1)
        t.heading -= 49.0
        lind!(t, depth + 1)
        t.pos = op          # <-- restore-across-recursion is the trigger
        t.heading = oh
    end
end
run_recur(s::Int) = (t = Tt((0.0, 0.0), Float64(s), Vector{Float64}[]); lind!(t, 0); length(t.xs))

# CONTROL: identical struct mutation, expressed ITERATIVELY (explicit work-stack)
# instead of recursion — compiles + runs (proves the ops are fine; recursion is
# the differentiator).
function run_linear(s::Int)
    t = Tt((0.0, 0.0), Float64(s), Vector{Float64}[])
    stack = NTuple{3,Float64}[(0.0, 0.0, 0.0)]
    while !isempty(stack)
        st = pop!(stack)
        x = st[1]; y = st[2]; d = st[3]
        d >= 8.0 && continue
        push!(t.xs, [x, x + 1.0])
        t.pos = (x + 1.0, y)
        push!(stack, (x + 1.0, y, d + 1.0))
        push!(stack, (x + 1.0, y, d + 1.0))
    end
    length(t.xs)
end

for (f, nm) in ((run_recur, "RECURSION (bug)"), (run_linear, "LINEAR (control)"))
    print(rpad(nm, 20), " : ")
    try
        println(compare_julia_wasm_bridge_args(f, 0; name = replace(nm, " " => "_")))
    catch e
        println("ERR ", first(sprint(showerror, e), 200))
    end
end
