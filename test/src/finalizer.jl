# Julia's finalizer registration, ported (src/intrinsics.jl, the finalizer arm; src/julia/runtime/rtutils.jl
# jl_gc_add_finalizer_): Base.finalizer(f, o) calls the builtin Core.finalizer (julia/src/builtins.c:2078
# jl_f_finalizer), which appends the object and its function to the thread's finalizer list
# (julia/src/gc-common.c:423 jl_gc_add_finalizer_) and returns nothing, Base.finalizer then returning the
# object. Each registration, one object registered twice, against native; a finalizer that runs now,
# finalize(o) (base/gcutils.jl:102, its foreign calls jl_get_current_task and julia/src/gc-common.c:479 jl_finalize_th,
# whose library no host supplies), rejects, located.
module FinalizerTest

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "codegen_helpers.jl"))

module FinalizerCases
mutable struct Cell; v::Int64; end
const SINK = Ref{Any}(nothing)
const LOG = Int64[]
@noinline note(o::Cell) = (push!(LOG, o.v); nothing)
@noinline note_twice(o::Cell) = (push!(LOG, 2 * o.v); nothing)
# the object escapes and the finalizer has an effect, so Julia's inlining keeps the registration
function register(n::Int64)
    local o = Cell(n)
    local same = finalizer(note, o) === o
    finalizer(note_twice, o)
    SINK[] = o
    return n * 10 + Int64(same)
end
run_now(n::Int64) = (o = Cell(n); finalizer(note, o); SINK[] = o; finalize(o); n)
end

@testset "builtins.c: jl_f_finalizer registers an object's finalizer and gives nothing, Base.finalizer the object, against native" begin
    local bytes = W.compile(FinalizerCases.register, (Int64,); optimize = false)
    queue_native!("register", bytes, FinalizerCases.register, [(n,) for n in Int64[0, 3, -7]])
end

@testset "gcutils.jl: finalize(o), a finalizer run now through foreign calls no host supplies, rejects, located" begin
    local e = rejection(() -> W.compile(FinalizerCases.run_now, (Int64,); optimize = false))
    @test e !== nothing && e.rejection isa W.Unquarantined && occursin("whose library no host supplies", sprint(showerror, e))
end

@testset "the third oracle: every module queued above answers as native Julia" begin
    for r in WTChild.run_cases(NATIVE_RUNS)
        r.ok || println(r.label, ": ", r.why)
        @test r.ok
    end
end

end
