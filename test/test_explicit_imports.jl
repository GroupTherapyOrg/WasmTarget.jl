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
using Logging
using Test
using WasmTarget

# ExplicitImports emits a `default_param_context reached recursion limit`
# @warn per deeply-nested type parameter it can't fully walk. For a
# compiler package like WasmTarget this fires thousands of times and
# each warning dumps the whole unresolved `ImplicitCursor{...}` type,
# producing multi-MB blobs that swamp CI logs (GitHub truncates them,
# making real failures unreadable). Filter just that one message —
# everything else still flows through to the user.
struct _FilteredLogger <: AbstractLogger
    inner::AbstractLogger
end
Logging.min_enabled_level(l::_FilteredLogger) = Logging.min_enabled_level(l.inner)
Logging.shouldlog(l::_FilteredLogger, level, _mod, group, id) =
    Logging.shouldlog(l.inner, level, _mod, group, id)
Logging.catch_exceptions(l::_FilteredLogger) = Logging.catch_exceptions(l.inner)
function Logging.handle_message(l::_FilteredLogger, level, msg, _mod, group, id,
                                file, line; kwargs...)
    if level == Logging.Warn &&
       occursin("default_param_context reached recursion limit", string(msg))
        return
    end
    Logging.handle_message(l.inner, level, msg, _mod, group, id, file, line; kwargs...)
end

@testset "ExplicitImports" begin
    with_logger(_FilteredLogger(current_logger())) do
        test_explicit_imports(WasmTarget;
            all_explicit_imports_are_public = false,
            all_qualified_accesses_are_public = false,
            no_self_qualified_accesses = (; ignore = (:optimize,)),
        )
    end
end
