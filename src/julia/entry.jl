# The compile entry a Julia caller uses: a callable and its argument types. A Julia program reaches
# the compiler as a callable and the types of its arguments, where dart's driver reaches
# dart2wasm/lib/compile.dart:216 compile with a Kernel component; the entry runs dart's compile,
# not ported yet.

"""
    compile(f, argtypes::Tuple) -> Vector{UInt8}

Compile `f` called with arguments of `argtypes` to a wasm module. The program is first inferred
once and judged by Julia's own trim verifier (`check_subset`): one outside the strict subset rejects
with `OutsideSubset`, Julia's text. Every path that reaches a definition not yet ported rejects with
a `RejectionError` naming it; nothing returns a module that was not built (dev/CHARTER.md C6).
"""
@quarantine "a Julia program is a callable and its argument types, where dart's is a Kernel component" Core.Typeof function compile(@nospecialize(f), argtypes::Tuple)::Vector{UInt8}
    local at = string(f, argtypes)
    return compile_world(check_subset(f, argtypes, at), at)
end

# the stages after the subset check take the ClosedWorld check_subset alone makes; dart's compile,
# which runs them, is not ported yet
@quarantine "the compile's stages take the ClosedWorld Julia's verifier accepted, a typestate dart's driver has no need of" Core.Compiler.typeinf_ext_toplevel function compile_world(world::ClosedWorld, at::String)::Vector{UInt8}
    reject!(Unported("dart2wasm/lib/compile.dart:216 compile"), at)
end
