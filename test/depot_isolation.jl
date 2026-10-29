# Two worktrees loading WasmTarget alternately each keep their compiled image (dev/depot.sh, audit 37:
# with one shared depot every tree's image evicted another's, and every gate ran cold). Two scratch
# checkouts of this commit, their sources made different by a comment so each needs its own image,
# each with its private depot: after one load each, loading them alternately precompiles nothing.
using Test

const _DI_ROOT = normpath(joinpath(@__DIR__, ".."))

@testset "a private depot per worktree: two trees loading alternately stay precompiled" begin
    local base = mktempdir()
    local head = readchomp(`git -C $_DI_ROOT rev-parse HEAD`)
    local trees = String[]
    for k in 1:2
        local t = joinpath(base, "tree$k")
        run(`git clone -q --shared --no-checkout $_DI_ROOT $t`)
        run(`git -C $t checkout -q --detach $head`)
        for f in ("Manifest.toml", "LocalPreferences.toml")
            isfile(joinpath(_DI_ROOT, f)) && cp(joinpath(_DI_ROOT, f), joinpath(t, f))
        end
        k == 2 && open(io -> println(io, "# tree 2"), joinpath(t, "src", "WasmTarget.jl"), "a")
        push!(trees, t)
    end
    # a fresh julia loading WasmTarget in tree t with t's private depot: its stderr
    function load(t)
        local depot = readchomp(`bash $(joinpath(_DI_ROOT, "dev", "depot.sh")) path $t`)
        local env = merge(Dict(k => v for (k, v) in ENV if !startswith(k, "WT_")), Dict("JULIA_DEPOT_PATH" => depot))
        local err = IOBuffer()
        run(pipeline(setenv(`$(Base.julia_cmd()) --startup-file=no --project=$t -e "using WasmTarget"`, env); stderr = err))
        return String(take!(err))
    end
    load(trees[1]); load(trees[2])
    @test !occursin("Precompiling", load(trees[1]))
    @test !occursin("Precompiling", load(trees[2]))
    # each tree's image is in its own depot
    @test all(t -> isdir(joinpath(t, ".wtd", "depot", "compiled")), trees)
    rm(base; recursive = true, force = true)
end
