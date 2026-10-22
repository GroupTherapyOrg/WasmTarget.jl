# The compile entry a Julia caller uses: a callable and its argument types. A Julia program reaches
# the compiler as a callable and the types of its arguments, where dart's driver reaches
# dart2wasm/lib/compile.dart:216 compile with a Kernel component; the entry runs dart's compile,
# not ported yet.

"""
    compile(f, argtypes::Tuple) -> Vector{UInt8}

Compile `f` called with arguments of `argtypes` to a wasm module. Every path that reaches a
definition not yet ported rejects with a `RejectionError` naming it; nothing returns a module that
was not built (dev/CHARTER.md C6).
"""
@quarantine "a Julia program is a callable and its argument types, where dart's is a Kernel component" Core.Typeof function compile(@nospecialize(f), argtypes::Tuple)::Vector{UInt8}
    local at = string(f, argtypes)
    reject!(Unported("dart2wasm/lib/compile.dart:216 compile"), at)
end
