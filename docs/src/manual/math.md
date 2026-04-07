# Math Functions

All 43 tested math functions compile and produce correct results, verified with both Float32 and Float64 (except `exp(Float32)` — one known codegen issue).

Julia 1.12 implements math functions in pure Julia (no `foreigncall` to libm), so they compile directly to WASM without runtime dependencies.

## Supported Functions

| Category | Functions | Path |
|:---------|:---------|:-----|
| Trigonometric | `sin`, `cos`, `tan`, `asin`, `acos`, `atan` | Native |
| Hyperbolic | `sinh`, `cosh`, `tanh` | Native |
| Exponential | `exp`, `exp2`, `expm1` | Native |
| Logarithmic | `log`, `log2`, `log10`, `log1p` | Native |
| Rounding | `floor`, `ceil`, `round`, `trunc` | Native |
| Roots/Powers | `sqrt`, `cbrt`, `hypot`, `fourthroot` | Native |
| Special | `sincos`, `sinpi`, `cospi`, `tanpi`, `sinc`, `cosc`, `modf` | Native |
| Utility | `copysign`, `deg2rad`, `rad2deg`, `ldexp`, `mod2pi` | Native |
| Power | `Float64^Float64`, `Float64^Int` | Native |
| Float mod/rem | `mod(Float64)`, `rem(Float64)` | Overlay |

## Example

```julia
using WasmTarget
bytes = compile(sin, (Float64,))
write("sin.wasm", bytes)
```

## Optimization

Math functions benefit significantly from `wasm-opt`:

```julia
raw = compile(sin, (Float64,))
opt = compile(sin, (Float64,); optimize=true)
# Typical: ~80-90% size reduction
```
