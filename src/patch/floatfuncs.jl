# Base's fma and muladd by overlay. Core wasm has no fused multiply-add: LLVM's WebAssembly backend
# lowers llvm.fma to the C library's fma and keeps muladd's fmul and fadd apart, rounding twice. The
# differential oracle, native Julia on an FMA host, computes fma in one rounding and fuses muladd
# (LLVM contracts its fmul and fadd there), and Julia's math kernels' last bits follow it. So both are
# Base's own software fma, fma_emulated (base/floatfuncs.jl, the emulation Base uses where the hardware
# has none), one rounding as natively, and have_fma answers true (src/intrinsics.jl). fma's overlay is
# consistent: natively it is correctly rounded either way. muladd's is not: native LLVM contracts its
# fmul and fadd per site, so native Julia rounds a muladd once or twice by where it stands (1.13 leaves
# pow_body's muladds unfused, where 1.12 fuses them: test/smoke_corpus.jl's bit_exact_math), and
# WasmTarget's inference never evaluates the call by Base's native method in its place.
# precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; gpucompiler: a device's
# overlays of Base in its method table).

@quarantine "julia/base/floatfuncs.jl:357 fma takes the hardware's fma where have_fma holds, else fma_emulated; the wasm target has no fused multiply-add, so Base's emulation" Base.fma @consistent_overlay METHOD_TABLE Base.fma(x::T, y::T, z::T) where {T<:Base.IEEEFloat} =
    Base.fma_emulated(x, y, z)

@quarantine "julia/base/float.jl:500 muladd is muladd_float, which Julia's compiler marks not interprocedurally consistent (julia/Compiler/src/tfuncs.jl:2472 _INCONSISTENT_INTRINSICS, its muladd_float entry), whose native fold is julia/src/runtime_intrinsics.c:1517 muladd's a * b + c, and which native LLVM contracts per site on an FMA host, once or twice by where it stands; the wasm target has no fused multiply-add, so Base's emulated fma at every muladd, one rounding, an overlay native's answer is not at every site" Base.muladd @overlay METHOD_TABLE Base.muladd(x::T, y::T, z::T) where {T<:Base.IEEEFloat} =
    Base.fma_emulated(x, y, z)
