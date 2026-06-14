# ExplicitImports — every `using Foo` in src/ must either spell out the
# names it pulls in (`using Foo: a, b`) or access them qualified
# (`Foo.a`). Catches what Aqua doesn't — import hygiene.
using ExplicitImports
using Test
using WasmTarget

@testset "ExplicitImports" begin
    test_explicit_imports(WasmTarget)
end
