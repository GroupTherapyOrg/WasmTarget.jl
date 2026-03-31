# Math Functions

WasmTarget.jl compiles **72 out of 72** Base.Math functions correctly.
Julia 1.12 implements math functions in pure Julia (no `foreigncall` / `ccall`
to libm), which means they compile directly to WASM without any runtime
dependencies.

## Supported Functions

All standard math functions compile with `compile(f, (Float64,))`:

| Category | Functions |
|:---------|:---------|
| Trigonometric | `sin`, `cos`, `tan`, `asin`, `acos`, `atan` |
| Hyperbolic | `sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh` |
| Exponential | `exp`, `exp2`, `exp10`, `expm1` |
| Logarithmic | `log`, `log2`, `log10`, `log1p` |
| Rounding | `floor`, `ceil`, `round`, `trunc` |
| Roots/Powers | `sqrt`, `cbrt`, `hypot` (2-arg) |
| Special | `abs`, `sign`, `copysign`, `flipsign`, `clamp` |
| Bit-level | `ldexp`, `significand`, `exponent` |

## Example: Compiling sin

```julia
using WasmTarget

bytes = compile(sin, (Float64,))
println("sin.wasm: $(length(bytes)) bytes")

# Write and test
write("sin.wasm", bytes)
```

```bash
node -e '
  const fs = require("fs");
  WebAssembly.instantiate(fs.readFileSync("sin.wasm"))
    .then(m => {
      const sin = m.instance.exports.sin;
      console.log(sin(0));           // 0
      console.log(sin(Math.PI / 2)); // 1
      console.log(sin(Math.PI));     // ~0 (≈1.2e-16)
    });
'
```

## Live Demo: sin()

```@raw html
<div data-wasm-demo="sin" data-wasm-func="sin" data-wasm-args="1.5708">
  <p><strong>Compute <code>sin(1.5708)</code> in WASM:</strong></p>
  <button style="padding:6px 16px;cursor:pointer;border-radius:4px;border:1px solid #888;">
    Run in Browser
  </button>
  <pre class="wasm-output" style="margin-top:8px;padding:8px;background:#f5f5f5;border-radius:4px;min-height:1.5em;">
    Click "Run in Browser" above
  </pre>
</div>
```

## Why It Works

Julia 1.12 rewrote the math library in pure Julia.  Functions like `sin`
are implemented with polynomial approximations and bit manipulation --
no calls to C's `libm`.  Since `Base.code_typed(sin, (Float64,))` returns
IR that uses only arithmetic, comparisons, and bitwise operations,
WasmTarget.jl translates it directly.

This is a key advantage over approaches that depend on a C runtime:
the compiled WASM has **zero external dependencies**.

## Optimization

Math functions benefit significantly from `wasm-opt`:

```julia
raw   = compile(sin, (Float64,))
opt   = compile(sin, (Float64,); optimize=true)
println("Raw: $(length(raw)) bytes, Optimized: $(length(opt)) bytes")
```

Typical size reduction is 50-80% with dart2wasm production flags.

## Multi-Argument Functions

Some math functions take two arguments:

```julia
bytes = compile(atan, (Float64, Float64))  # atan2
bytes = compile(hypot, (Float64, Float64))
bytes = compile(copysign, (Float64, Float64))
```

## Integer Math

Integer arithmetic compiles directly to WASM integer instructions:

```julia
abs_i(x::Int32)::Int32 = abs(x)
bytes = compile(abs_i, (Int32,))
```
