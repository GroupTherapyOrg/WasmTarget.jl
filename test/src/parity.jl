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

# an entry's lines are its definition's whole text: parsed alone, lines first to last are one
# complete statement, its closing `end` the last line (a line short, the statement is incomplete)
@testset "the registry: an entry's lines span its definition's text" begin
    local text(e, a, b) = join(readlines(string(e.file))[a:b], '\n')
    local complete(s) = (ex = Meta.parse(s; raise = false); !(Meta.isexpr(ex, :incomplete) || Meta.isexpr(ex, :error)))
    local q = only(x for x in W.REGISTRY if x isa W.QuarantineEntry && :check_subset in x.names)
    @test strip(readlines(string(q.file))[q.last]) == "end"
    @test complete(text(q, q.first, q.last)) && !complete(text(q, q.first, q.last - 1))
    local bad = [e for e in W.REGISTRY if isfile(string(e.file)) && !complete(text(e, e.first, e.last))]
    @test isempty(bad)
end

# a dart field whose type dart-format breaks from its name (code_generator.dart:5207 SwitchInfo's
# dynamicTypeGuard): the name alone on its line, nullable by the type ending the line above
@testset "check_typed_fields: a dart field split across lines reads its nullability from the line above" begin
    mktempdir() do sdk
        local file = joinpath(sdk, "pkg", "dart2wasm", "lib", "code_generator.dart")
        mkpath(dirname(file))
        write(file, """
            class Planted {
              void Function(int a, int b)?
              splitNullable;
              void Function(int a, int b)
              splitPlain;
              int? oneLine;
            }
            """)
        local anchor = "dart2wasm/lib/code_generator.dart:1 Planted"
        @test W._dart_nullable(sdk, anchor, :split_nullable) === nothing
        @test occursin("not nullable", something(W._dart_nullable(sdk, anchor, :split_plain), ""))
        @test W._dart_nullable(sdk, anchor, :one_line) === nothing
    end
end
