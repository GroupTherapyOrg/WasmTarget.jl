# Control Flow

WasmTarget.jl handles all Julia control flow patterns by translating the
compiler's IR (GotoNode, GotoIfNot, PhiNode) into WASM structured
control flow (block, loop, br, br\_if).

## If / Else

```julia
function clamp_positive(x::Int32)::Int32
    if x > Int32(0)
        return x
    else
        return Int32(0)
    end
end

bytes = compile(clamp_positive, (Int32,))
```

## While Loops

```julia
function sum_to(n::Int32)::Int32
    total = Int32(0)
    i = Int32(1)
    while i <= n
        total += i
        i += Int32(1)
    end
    return total
end

bytes = compile(sum_to, (Int32,))
```

Julia while loops compile to WASM `loop` / `br` instructions with a
backward branch.

## For Loops

For loops over ranges are lowered by Julia to while loops before
reaching the IR, so they compile identically:

```julia
function sum_range(n::Int32)::Int32
    total = Int32(0)
    for i in Int32(1):n
        total += i
    end
    return total
end
```

## Short-Circuit Operators

`&&` and `||` compile correctly, including complex chains:

```julia
function check(a::Int32, b::Int32, c::Int32)::Bool
    return a > Int32(0) && b > Int32(0) && c > Int32(0)
end

function any_positive(a::Int32, b::Int32)::Bool
    return a > Int32(0) || b > Int32(0)
end
```

These use WASM `block` / `br_if` patterns for short-circuit evaluation.

## Try / Catch / Throw

Exception handling uses WASM's `try_table` and `throw` instructions:

```julia
function safe_div(a::Int32, b::Int32)::Int32
    try
        if b == Int32(0)
            throw(DivideError())
        end
        return div(a, b)
    catch
        return Int32(-1)
    end
end

bytes = compile(safe_div, (Int32, Int32))
```

## Recursion

Self-recursive functions compile with the function calling itself
by index:

```julia
function factorial(n::Int32)::Int32
    if n <= Int32(1)
        return Int32(1)
    end
    return n * factorial(n - Int32(1))
end

bytes = compile(factorial, (Int32,))
```

## Complex Control Flow (Stackifier)

Functions with many conditional branches (e.g., Julia's `sin` implementation
with 15+ GotoIfNots) use a stackifier algorithm that converts arbitrary
CFG patterns to WASM structured control flow using nested `block` / `loop` /
`br` instructions.
