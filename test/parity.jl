# The registry (src/julia/parity.jl): a marked definition evaluated again, as Revise does when a live
# session reloads its file (D39), replaces its own entry, so the registry keeps one entry per
# definition and anchor_of still finds one.
using Test
using WasmTarget

const W = WasmTarget
# a registry entry's own definition, parsed from its first line in its file and evaluated again in
# its module, as Revise evaluates a changed definition
function _reevaluate(e)
    local lines = readlines(string(e.file))
    local text = repeat("\n", e.first - 1) * join(lines[e.first:end], '\n')
    local ex, _ = Meta.parse(text, e.first; filename = string(e.file))
    Core.eval(e.mod, ex)
end

@testset "the registry: a definition evaluated again replaces its entry" begin
    local n = length(W.REGISTRY)
    local compile = W.Dart2Wasm.compile
    local p = only(x for x in W.REGISTRY if x isa W.ParityEntry &&
                   any(s -> isdefined(x.mod, s) && getglobal(x.mod, s) === compile, x.names))
    local q = only(x for x in W.REGISTRY if x isa W.QuarantineEntry && :check_subset in x.names)
    local a = W.anchor_of(compile)
    _reevaluate(p)
    _reevaluate(q)
    @test length(W.REGISTRY) == n
    @test W.anchor_of(compile) == a   # one entry binds it, not the old and the new
    @test count(x -> x isa W.QuarantineEntry && :check_subset in x.names, W.REGISTRY) == 1
    # the entry left is the new evaluation's: this process's, with the worlds it spanned
    local p2 = only(x for x in W.REGISTRY if x isa W.ParityEntry && x.anchor == p.anchor)
    @test p2.pid == getpid() && p2.worlds != p.worlds
end
