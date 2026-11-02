# Base's fma and muladd by overlay. Core wasm has no fused multiply-add: LLVM's WebAssembly backend
# lowers llvm.fma to the C library's fma and keeps muladd's fmul and fadd apart, rounding twice. The
# differential oracle, native Julia on an FMA host, computes fma in one rounding and fuses muladd
# (LLVM contracts its fmul and fadd there), and Julia's math kernels' last bits follow it. So both are
# Base's own software fma, fma_emulated (base/floatfuncs.jl, the emulation Base uses where the hardware
# has none), one rounding as natively, and have_fma answers true (src/intrinsics.jl). Each overlay is
# consistent: natively on the FMA host it computes Base's answer, fma correctly rounded either way and
# muladd fused there.
# precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; gpucompiler: a device's
# overlays of Base in its method table).

@quarantine "julia/base/floatfuncs.jl:357 fma takes the hardware's fma where have_fma holds, else fma_emulated; the wasm target has no fused multiply-add, so Base's emulation" Base.fma @consistent_overlay METHOD_TABLE Base.fma(x::T, y::T, z::T) where {T<:Base.IEEEFloat} =
    Base.fma_emulated(x, y, z)

@quarantine "julia/base/float.jl:500 muladd is muladd_float, which LLVM fuses on an FMA host; the wasm target has no fused multiply-add, so Base's emulated fma, one rounding as natively" Base.muladd @consistent_overlay METHOD_TABLE Base.muladd(x::T, y::T, z::T) where {T<:Base.IEEEFloat} =
    Base.fma_emulated(x, y, z)
