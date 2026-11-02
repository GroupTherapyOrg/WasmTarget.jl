# Base's fma by overlay: Base's fma chooses the hardware's fused multiply-add where Julia's have_fma
# says the target has one, else its software emulation (base/floatfuncs.jl:355, "use a software
# emulated fma" where LLVM would fall back onto the C library). The wasm target has none: core wasm
# has no fused multiply-add, and LLVM's WebAssembly backend lowers llvm.fma to the C library's fma, so
# the overlay is Base's own other branch, fma_emulated (have_fma false, as src/intrinsics.jl's have_fma
# arm answers). The overlay is consistent: natively it computes Base's answer, both correctly rounded.
# precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; gpucompiler: a device's
# overlays of Base in its method table).

@quarantine "julia/base/floatfuncs.jl:357 fma takes the hardware's fma where have_fma holds, else fma_emulated; the wasm target has no fused multiply-add, so Base's emulation" Base.fma @consistent_overlay METHOD_TABLE Base.fma(x::T, y::T, z::T) where {T<:Base.IEEEFloat} =
    Base.fma_emulated(x, y, z)
