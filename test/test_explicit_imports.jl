# ExplicitImports — import hygiene checks that complement Aqua.
#
# We invoke the individual `test_*` variants instead of the one-shot
# `test_explicit_imports(...)` so we can SKIP two checks that don't
# apply to a compiler package:
#   - `test_all_explicit_imports_are_public`
#   - `test_all_qualified_accesses_are_public`
#
# WasmTarget intentionally reaches into Base / Core / Compiler internals
# (`Base.uncompressed_ir`, `Core.memoryref`, `Compiler.method_table`,
# `Base.Math.pow_body`, etc.) — that's what compiling Julia to Wasm
# requires. Those accesses are "not public" per ExplicitImports, but
# flagging them on every CI run adds noise without surfacing real bugs.
#
# The remaining five checks still pull their weight:
#   - no_implicit_imports       : enforce `using Foo: a, b` over `using Foo`
#   - no_stale_explicit_imports : catch imports we stopped using
#   - explicit_imports_via_owners  : import names from the module that owns them
#   - qualified_accesses_via_owners: same, for `Foo.bar`-style access
#   - no_self_qualified_accesses   : no `WasmTarget.x` inside WasmTarget
using ExplicitImports
using Test
using WasmTarget

@testset "ExplicitImports" begin
    @test check_no_implicit_imports(WasmTarget) === nothing
    @test check_no_stale_explicit_imports(WasmTarget) === nothing
    @test check_all_explicit_imports_via_owners(WasmTarget) === nothing
    @test check_all_qualified_accesses_via_owners(WasmTarget) === nothing
    # `optimize` is both an exported function AND a public kwarg on
    # several compile_* methods (`optimize=false|true|:size|:speed`).
    # Inside those methods `WasmTarget.optimize(...)` is the only way
    # to reach the function — the local kwarg shadows the binding.
    # Renaming either side would be a breaking API change, so ignore.
    @test check_no_self_qualified_accesses(WasmTarget; ignore=(:optimize,)) === nothing
end
