# ExplicitImports — import hygiene checks that complement Aqua.
#
# Use the one-shot `test_explicit_imports(pkg; ...)` wrapper so the
# expensive file analysis (AST walk over every src/ file) runs ONCE
# and is shared across all sub-checks. Calling the individual
# `check_*`/`test_*` functions separately re-walked ~30 KB of codegen
# source per check and OOM'd CI runners.
#
# Two checks are disabled for WasmTarget:
#   - `all_explicit_imports_are_public`
#   - `all_qualified_accesses_are_public`
# A Julia→Wasm compiler *has* to reach into Base / Core / Compiler
# internals (uncompressed_ir, memoryref, method_table, pow_body, …) —
# those accesses are "not public" per ExplicitImports but flagging
# them just adds noise without surfacing real bugs.
#
# `:optimize` is exempted from the self-qualified check because it's
# both an exported function AND a public kwarg on several `compile_*`
# methods (`optimize=false|true|:size|:speed`). Inside those methods
# the kwarg shadows the function name, so `WasmTarget.optimize(...)`
# is the only way to reach the function. Renaming either side would
# be a breaking API change.
using ExplicitImports
using Test
using WasmTarget

@testset "ExplicitImports" begin
    test_explicit_imports(WasmTarget;
        all_explicit_imports_are_public = false,
        all_qualified_accesses_are_public = false,
        no_self_qualified_accesses = (; ignore = (:optimize,)),
    )
end
