# The compile entry a Julia caller uses: a callable and its argument types. A Julia program reaches
# the compiler as a callable and the types of its arguments, where dart's driver reaches
# dart2wasm/lib/compile.dart:216 compile with a Kernel component; the entry runs dart's compile,
# not ported yet.

"""
    compile(f, argtypes::Tuple) -> Vector{UInt8}

Compile `f` called with arguments of `argtypes` to a wasm module. The program is first inferred
once and judged by Julia's own trim verifier (`check_subset`): one outside the strict subset rejects
with `OutsideSubset`, Julia's text; one Julia accepts that cannot be built as written (two exports of
one name) rejects with `ProgramError`, the user's to fix. Every path that reaches a definition not yet ported rejects with
a `RejectionError` naming it; nothing returns a module that was not built (dev/CHARTER.md C6).
"""
@quarantine "a Julia program is a callable and its argument types, where dart's is a Kernel component" Core.Tuple function compile(@nospecialize(f), argtypes::Tuple; optimize::Bool = true)::Vector{UInt8}
    local at = string(f, argtypes)
    return compile_world(check_subset(f, argtypes, at), at; optimize = optimize)
end

# the stages after the subset check take the ClosedWorld check_subset alone makes: dart's compile
# (dart2wasm/lib/compile.dart:216) runs them, standalone, and the main module's bytes are the result:
# a module that imports the JS runtime needs that runtime file beside it (compile's RuntimeFinalizer),
# which this entry, returning bytes alone, does not hand its caller. The phases are the user-facing default,
# dartdev's `dart compile wasm` (pkg/dartdev/lib/src/commands/compile.dart:874-875): cfe, tfa,
# codegen and opt; `optimize = false` leaves opt out, as dartdev's optimization level 0 does
# (:1002-1010), the library's default phases (compiler_options.dart:64)
@quarantine "the compile's stages take the ClosedWorld Julia's verifier accepted, a typestate dart's driver has no need of" Core.String function compile_world(world::ClosedWorld, at::String; optimize::Bool = true)::Vector{UInt8}
    local options = Dart2Wasm.WasmCompilerOptions(; main_uri = "", output_file = "main.wasm")
    options.translator_options.standalone = true
    options.translator_options.generate_source_maps = false
    optimize && push!(options.phases, Dart2Wasm.CompilerPhase_opt)
    local result = Dart2Wasm.compile(options, world)
    result isa Union{Dart2Wasm.CodegenResult,Dart2Wasm.OptResult} ||
        reject!(Internal("src/julia/entry.jl: the compile ended at $(typeof(result)), not its code"), at)
    return result.wasm_files[basename(result.main_wasm_file)]
end
