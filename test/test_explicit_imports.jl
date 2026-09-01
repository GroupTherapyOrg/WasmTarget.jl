# ExplicitImports — every `using Foo` in src/ must either spell out the
# names it pulls in (`using Foo: a, b`) or access them qualified
# (`Foo.a`). Catches what Aqua doesn't — import hygiene.
using ExplicitImports
using Logging
using Test
using WasmTarget

# ExplicitImports' parser warns (with megabyte-sized state dumps) when it hits
# its recursion limit on very large files like codegen/calls.jl — harmless for
# the analysis, ruinous for CI logs. Only Error-and-above passes through.
@testset "ExplicitImports" begin
    with_logger(SimpleLogger(stderr, Logging.Error)) do
    test_explicit_imports(WasmTarget;
        # Dual/Tag/partials are the ForwardDiff internals the Dual-seed
        # overlay is built on; @overlay is the method-table mechanism itself.
        all_explicit_imports_are_public=(ignore=(Symbol("@overlay"), :Dual, :Tag, :partials),),
        no_stale_explicit_imports=(ignore=(:wasmopt,),),  # Used in command interpolation in optimize()
        all_qualified_accesses_via_owners=(ignore=(
            # Compiler.* refers to Core.Compiler/Base.Compiler internals
            :Const, :findall, :specialize_method, :getdebugidx,
        ),),
        # A wasm compiler reaches Core.Compiler / Base internals (CodeInfo,
        # IRShow, Ryu, the generic LinearAlgebra kernels, …) by design —
        # nearly every "non-public qualified access" in this package is
        # deliberate, so the check carries no signal here and its allowlist
        # would only grow with each new lowering. The six enabled checks
        # carry the actual import hygiene.
        all_qualified_accesses_are_public=false,
    )
    end
end
