# The compile entry a Julia caller uses: a callable and its argument types. A Julia program reaches
# the compiler as a callable and the types of its arguments, where dart's driver reaches
# dart2wasm/lib/compile.dart:216 compile with a Kernel component; the entry runs dart's compile,
# not ported yet.

"""
    compile(f, argtypes::Tuple; optimize = true, world = Base.get_world_counter()) -> Vector{UInt8}

Compile `f` called with arguments of `argtypes` to a wasm module. The program is first inferred
once, at `world`, and judged by Julia's own trim verifier (`check_subset`): one outside the strict subset rejects
with `OutsideSubset`, Julia's text; one Julia accepts that cannot be built as written (two exports of
one name) rejects with `ProgramError`, the user's to fix. Every path that reaches a definition not yet ported rejects with
a `RejectionError` naming it; nothing returns a module that was not built (dev/CHARTER.md C6).

`world` is the one world age the program is inferred, verified and compiled in, read here once and passed down
(check_subset, its verifier, and the ClosedWorld every later stage reads, at whose world build_nir reads each binding
the program names, once, into its node: src/julia/nir.jl NirBinding), never read again by a later stage: the
program is the methods visible in that world, whatever the caller defines after it. precedent(GPUCompiler:
CompilerJob.world, the world a job's code is inferred and compiled in, its interpreter Core.Compiler.NativeInterpreter(world);
Julia: code_typed(f, types; world)). dart2wasm has no counterpart: its compiler never shares a method table with the
program it compiles, so a compile there has no world to name; Julia differs in that the compiler and the program are
methods of one table, so a caller holding code defined later (a test's corpus loaded after its judge) names the
program's world itself.
"""
@quarantine pin"precedent(dart: pkg/dart2wasm/lib/compile.dart:216 compile)" "a Julia program is a callable, its argument types and the world its methods are read in, where dart's is a Kernel component" Core.Tuple function compile(@nospecialize(f), argtypes::Tuple; optimize::Bool = true, world::UInt = Base.get_world_counter())::Vector{UInt8}
    local at = string(f, argtypes)
    return compile_world(check_subset(f, argtypes, at, world), at; optimize = optimize)
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
