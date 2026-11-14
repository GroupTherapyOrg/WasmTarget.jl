# wasm-opt on a module's bytes (dev/MARCH.md 1.D; the lead's ruling, 2026-10-28): the substance of
# dart's runWasmOpt (dart2wasm/lib/io_util.dart:161-197, out of scope as the command-line driver's
# file manager), as a library call on bytes. wasm-opt comes from Binaryen_jll, its version pinned in
# dev/PARITY_MASTER.md beside dart's own binaryen rev.

# Binaryen_jll's package id, loaded on the first run: the jll is WasmTarget's dependency, its
# artifact the wasm-opt executable
@quarantine "wasm-opt is Binaryen's executable, which Binaryen_jll ships as an artifact" Base.PkgId const _BINARYEN_JLL = Base.PkgId(Base.UUID("a54ac8ab-712d-5a0e-8e11-9296c0d3c20e"), "Binaryen_jll")

"""
    run_wasm_opt(bytes, flags, at) -> Vector{UInt8}

Run wasm-opt over the module `bytes` with `flags` and return the module it writes: dart's
runWasmOpt, its input and output files a temporary directory's, since a library compile has no
file manager. wasm-opt validates its input and its output; a failure (any nonzero exit) rejects,
located, with its stdout and stderr: the module WasmTarget built, or wasm-opt's rewrite of it, is
not one wasm-opt accepts. dart reads the minified class names from the source map before and adds
them back after; a library compile emits no source map (src/compile.jl), so there are none.

wasm-opt's output is not built by WasmTarget's builder, so the builder's refusals do not cover it:
the differential runner checks the optimized module against native Julia beside the unoptimized
one.
"""
@quarantine "dart runs wasm-opt as a process over files; Julia's run of Binaryen_jll's executable over temporary files is that call" Base.pipeline function run_wasm_opt(bytes::Vector{UInt8}, flags::Vector{String}, at::String)::Vector{UInt8}
    local jll = Base.require(_BINARYEN_JLL)
    local wasm_opt = Base.invokelatest(getfield(jll, :wasmopt))::Cmd
    return mktempdir() do dir
        local wasm_in = joinpath(dir, "in.wasm"); local wasm_out = joinpath(dir, "out.wasm")
        write(wasm_in, bytes)
        local out = IOBuffer(); local err = IOBuffer()
        local proc = run(pipeline(ignorestatus(`$wasm_opt $flags $wasm_in -o $wasm_out`); stdout = out, stderr = err))
        proc.exitcode == 0 ||
            reject!(InvalidModule("src/julia/wasm_opt.jl: wasm-opt failed with exit code $(proc.exitcode):\n$(String(take!(out)))\n$(String(take!(err)))"), at)
        read(wasm_out)
    end
end
