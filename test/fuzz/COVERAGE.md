# Catalogue Coverage Matrix

Regenerate: `julia --project=test/fuzz test/fuzz/run.jl coverage`

Status per entry: `pass` seen in ≥1 verified-passing program · `gap` implicated
in an open ledger gap · `seen` exercised without a passing witness yet ·
`unseen` not sampled this run (sampling is stochastic — rerun with a higher
budget before treating `unseen` as a coverage hole).

## arith

| op | args | ret | status |
|---|---|---|---|
| `+` | `Int8, Int8` | `Int8` | gap |
| `-` | `Int8, Int8` | `Int8` | pass |
| `*` | `Int8, Int8` | `Int8` | pass |
| `min` | `Int8, Int8` | `Int8` | gap |
| `max` | `Int8, Int8` | `Int8` | pass |
| `abs` | `Int8` | `Int8` | gap |
| `sign` | `Int8` | `Int8` | pass |
| `+` | `Int16, Int16` | `Int16` | gap |
| `-` | `Int16, Int16` | `Int16` | pass |
| `*` | `Int16, Int16` | `Int16` | pass |
| `min` | `Int16, Int16` | `Int16` | gap |
| `max` | `Int16, Int16` | `Int16` | pass |
| `abs` | `Int16` | `Int16` | gap |
| `sign` | `Int16` | `Int16` | pass |
| `+` | `Int32, Int32` | `Int32` | gap |
| `-` | `Int32, Int32` | `Int32` | pass |
| `*` | `Int32, Int32` | `Int32` | pass |
| `min` | `Int32, Int32` | `Int32` | gap |
| `max` | `Int32, Int32` | `Int32` | pass |
| `abs` | `Int32` | `Int32` | gap |
| `sign` | `Int32` | `Int32` | pass |
| `+` | `Int64, Int64` | `Int64` | gap |
| `-` | `Int64, Int64` | `Int64` | pass |
| `*` | `Int64, Int64` | `Int64` | pass |
| `min` | `Int64, Int64` | `Int64` | gap |
| `max` | `Int64, Int64` | `Int64` | pass |
| `abs` | `Int64` | `Int64` | gap |
| `sign` | `Int64` | `Int64` | pass |
| `+` | `UInt8, UInt8` | `UInt8` | gap |
| `-` | `UInt8, UInt8` | `UInt8` | pass |
| `*` | `UInt8, UInt8` | `UInt8` | pass |
| `min` | `UInt8, UInt8` | `UInt8` | gap |
| `max` | `UInt8, UInt8` | `UInt8` | pass |
| `abs` | `UInt8` | `UInt8` | gap |
| `sign` | `UInt8` | `UInt8` | pass |
| `+` | `UInt16, UInt16` | `UInt16` | gap |
| `-` | `UInt16, UInt16` | `UInt16` | pass |
| `*` | `UInt16, UInt16` | `UInt16` | pass |
| `min` | `UInt16, UInt16` | `UInt16` | gap |
| `max` | `UInt16, UInt16` | `UInt16` | pass |
| `abs` | `UInt16` | `UInt16` | gap |
| `sign` | `UInt16` | `UInt16` | pass |
| `+` | `UInt32, UInt32` | `UInt32` | gap |
| `-` | `UInt32, UInt32` | `UInt32` | pass |
| `*` | `UInt32, UInt32` | `UInt32` | pass |
| `min` | `UInt32, UInt32` | `UInt32` | gap |
| `max` | `UInt32, UInt32` | `UInt32` | pass |
| `abs` | `UInt32` | `UInt32` | gap |
| `sign` | `UInt32` | `UInt32` | pass |
| `+` | `UInt64, UInt64` | `UInt64` | gap |
| `-` | `UInt64, UInt64` | `UInt64` | pass |
| `*` | `UInt64, UInt64` | `UInt64` | pass |
| `min` | `UInt64, UInt64` | `UInt64` | gap |
| `max` | `UInt64, UInt64` | `UInt64` | pass |
| `abs` | `UInt64` | `UInt64` | gap |
| `sign` | `UInt64` | `UInt64` | pass |
| `+` | `Float32, Float32` | `Float32` | gap |
| `-` | `Float32, Float32` | `Float32` | pass |
| `*` | `Float32, Float32` | `Float32` | pass |
| `min` | `Float32, Float32` | `Float32` | gap |
| `max` | `Float32, Float32` | `Float32` | pass |
| `abs` | `Float32` | `Float32` | gap |
| `sign` | `Float32` | `Float32` | pass |
| `+` | `Float64, Float64` | `Float64` | gap |
| `-` | `Float64, Float64` | `Float64` | pass |
| `*` | `Float64, Float64` | `Float64` | pass |
| `min` | `Float64, Float64` | `Float64` | gap |
| `max` | `Float64, Float64` | `Float64` | pass |
| `abs` | `Float64` | `Float64` | gap |
| `sign` | `Float64` | `Float64` | pass |
| `-` | `Int8` | `Int8` | pass |
| `-` | `Int16` | `Int16` | pass |
| `-` | `Int32` | `Int32` | pass |
| `-` | `Int64` | `Int64` | pass |
| `-` | `Float32` | `Float32` | pass |
| `-` | `Float64` | `Float64` | pass |
| `div` | `Int8, Int8` | `Int8` | gap |
| `rem` | `Int8, Int8` | `Int8` | pass |
| `mod` | `Int8, Int8` | `Int8` | pass |
| `div` | `Int16, Int16` | `Int16` | gap |
| `rem` | `Int16, Int16` | `Int16` | pass |
| `mod` | `Int16, Int16` | `Int16` | pass |
| `div` | `Int32, Int32` | `Int32` | gap |
| `rem` | `Int32, Int32` | `Int32` | pass |
| `mod` | `Int32, Int32` | `Int32` | pass |
| `div` | `Int64, Int64` | `Int64` | gap |
| `rem` | `Int64, Int64` | `Int64` | pass |
| `mod` | `Int64, Int64` | `Int64` | pass |
| `div` | `UInt8, UInt8` | `UInt8` | gap |
| `rem` | `UInt8, UInt8` | `UInt8` | pass |
| `mod` | `UInt8, UInt8` | `UInt8` | pass |
| `div` | `UInt16, UInt16` | `UInt16` | gap |
| `rem` | `UInt16, UInt16` | `UInt16` | pass |
| `mod` | `UInt16, UInt16` | `UInt16` | pass |
| `div` | `UInt32, UInt32` | `UInt32` | gap |
| `rem` | `UInt32, UInt32` | `UInt32` | pass |
| `mod` | `UInt32, UInt32` | `UInt32` | pass |
| `div` | `UInt64, UInt64` | `UInt64` | gap |
| `rem` | `UInt64, UInt64` | `UInt64` | pass |
| `mod` | `UInt64, UInt64` | `UInt64` | pass |
| `gcd` | `Int8, Int8` | `Int8` | gap |
| `lcm` | `Int8, Int8` | `Int8` | gap |
| `gcd` | `Int16, Int16` | `Int16` | gap |
| `lcm` | `Int16, Int16` | `Int16` | gap |
| `gcd` | `Int32, Int32` | `Int32` | gap |
| `lcm` | `Int32, Int32` | `Int32` | gap |
| `gcd` | `Int64, Int64` | `Int64` | gap |
| `lcm` | `Int64, Int64` | `Int64` | gap |
| `/` | `Float32, Float32` | `Float32` | pass |
| `copysign` | `Float32, Float32` | `Float32` | pass |
| `mod` | `Float32, Float32` | `Float32` | pass |
| `rem` | `Float32, Float32` | `Float32` | pass |
| `/` | `Float64, Float64` | `Float64` | pass |
| `copysign` | `Float64, Float64` | `Float64` | pass |
| `mod` | `Float64, Float64` | `Float64` | pass |
| `rem` | `Float64, Float64` | `Float64` | pass |

## bits

| op | args | ret | status |
|---|---|---|---|
| `&` | `Int8, Int8` | `Int8` | gap |
| `|` | `Int8, Int8` | `Int8` | gap |
| `xor` | `Int8, Int8` | `Int8` | pass |
| `~` | `Int8` | `Int8` | pass |
| `<<` | `Int8, Int64` | `Int8` | gap |
| `>>` | `Int8, Int64` | `Int8` | pass |
| `&` | `Int16, Int16` | `Int16` | gap |
| `|` | `Int16, Int16` | `Int16` | gap |
| `xor` | `Int16, Int16` | `Int16` | pass |
| `~` | `Int16` | `Int16` | pass |
| `<<` | `Int16, Int64` | `Int16` | gap |
| `>>` | `Int16, Int64` | `Int16` | pass |
| `&` | `Int32, Int32` | `Int32` | gap |
| `|` | `Int32, Int32` | `Int32` | gap |
| `xor` | `Int32, Int32` | `Int32` | pass |
| `~` | `Int32` | `Int32` | pass |
| `<<` | `Int32, Int64` | `Int32` | gap |
| `>>` | `Int32, Int64` | `Int32` | pass |
| `&` | `Int64, Int64` | `Int64` | gap |
| `|` | `Int64, Int64` | `Int64` | gap |
| `xor` | `Int64, Int64` | `Int64` | pass |
| `~` | `Int64` | `Int64` | pass |
| `<<` | `Int64, Int64` | `Int64` | gap |
| `>>` | `Int64, Int64` | `Int64` | pass |
| `&` | `UInt8, UInt8` | `UInt8` | gap |
| `|` | `UInt8, UInt8` | `UInt8` | gap |
| `xor` | `UInt8, UInt8` | `UInt8` | pass |
| `~` | `UInt8` | `UInt8` | pass |
| `<<` | `UInt8, Int64` | `UInt8` | gap |
| `>>` | `UInt8, Int64` | `UInt8` | pass |
| `&` | `UInt16, UInt16` | `UInt16` | gap |
| `|` | `UInt16, UInt16` | `UInt16` | gap |
| `xor` | `UInt16, UInt16` | `UInt16` | pass |
| `~` | `UInt16` | `UInt16` | pass |
| `<<` | `UInt16, Int64` | `UInt16` | gap |
| `>>` | `UInt16, Int64` | `UInt16` | pass |
| `&` | `UInt32, UInt32` | `UInt32` | gap |
| `|` | `UInt32, UInt32` | `UInt32` | gap |
| `xor` | `UInt32, UInt32` | `UInt32` | pass |
| `~` | `UInt32` | `UInt32` | pass |
| `<<` | `UInt32, Int64` | `UInt32` | gap |
| `>>` | `UInt32, Int64` | `UInt32` | pass |
| `&` | `UInt64, UInt64` | `UInt64` | gap |
| `|` | `UInt64, UInt64` | `UInt64` | gap |
| `xor` | `UInt64, UInt64` | `UInt64` | pass |
| `~` | `UInt64` | `UInt64` | pass |
| `<<` | `UInt64, Int64` | `UInt64` | gap |
| `>>` | `UInt64, Int64` | `UInt64` | pass |

## bool

| op | args | ret | status |
|---|---|---|---|
| `&` | `Bool, Bool` | `Bool` | gap |
| `|` | `Bool, Bool` | `Bool` | gap |
| `!` | `Bool` | `Bool` | pass |
| `xor` | `Bool, Bool` | `Bool` | pass |
| `==` | `Bool, Bool` | `Bool` | gap |
| `ifelse` | `Bool, Int64, Int64` | `Int64` | pass |
| `ifelse` | `Bool, Float64, Float64` | `Float64` | pass |

## char

| op | args | ret | status |
|---|---|---|---|
| `isdigit` | `Char` | `Bool` | gap |
| `isspace` | `Char` | `Bool` | gap |
| `isletter` | `Char` | `Bool` | unseen |
| `isuppercase` | `Char` | `Bool` | pass |
| `islowercase` | `Char` | `Bool` | pass |
| `isascii` | `Char` | `Bool` | pass |
| `uppercase` | `Char` | `Char` | gap |
| `lowercase` | `Char` | `Char` | pass |
| `Int` | `Char` | `Int64` | gap |
| `<` | `Char, Char` | `Bool` | pass |
| `==` | `Char, Char` | `Bool` | gap |

## cmp

| op | args | ret | status |
|---|---|---|---|
| `==` | `Int8, Int8` | `Bool` | gap |
| `!=` | `Int8, Int8` | `Bool` | pass |
| `<` | `Int8, Int8` | `Bool` | pass |
| `<=` | `Int8, Int8` | `Bool` | pass |
| `>` | `Int8, Int8` | `Bool` | pass |
| `iszero` | `Int8` | `Bool` | pass |
| `==` | `Int16, Int16` | `Bool` | gap |
| `!=` | `Int16, Int16` | `Bool` | pass |
| `<` | `Int16, Int16` | `Bool` | pass |
| `<=` | `Int16, Int16` | `Bool` | pass |
| `>` | `Int16, Int16` | `Bool` | pass |
| `iszero` | `Int16` | `Bool` | pass |
| `==` | `Int32, Int32` | `Bool` | gap |
| `!=` | `Int32, Int32` | `Bool` | pass |
| `<` | `Int32, Int32` | `Bool` | pass |
| `<=` | `Int32, Int32` | `Bool` | pass |
| `>` | `Int32, Int32` | `Bool` | pass |
| `iszero` | `Int32` | `Bool` | pass |
| `==` | `Int64, Int64` | `Bool` | gap |
| `!=` | `Int64, Int64` | `Bool` | pass |
| `<` | `Int64, Int64` | `Bool` | pass |
| `<=` | `Int64, Int64` | `Bool` | pass |
| `>` | `Int64, Int64` | `Bool` | pass |
| `iszero` | `Int64` | `Bool` | pass |
| `==` | `UInt8, UInt8` | `Bool` | gap |
| `!=` | `UInt8, UInt8` | `Bool` | pass |
| `<` | `UInt8, UInt8` | `Bool` | pass |
| `<=` | `UInt8, UInt8` | `Bool` | pass |
| `>` | `UInt8, UInt8` | `Bool` | pass |
| `iszero` | `UInt8` | `Bool` | pass |
| `==` | `UInt16, UInt16` | `Bool` | gap |
| `!=` | `UInt16, UInt16` | `Bool` | pass |
| `<` | `UInt16, UInt16` | `Bool` | pass |
| `<=` | `UInt16, UInt16` | `Bool` | pass |
| `>` | `UInt16, UInt16` | `Bool` | pass |
| `iszero` | `UInt16` | `Bool` | pass |
| `==` | `UInt32, UInt32` | `Bool` | gap |
| `!=` | `UInt32, UInt32` | `Bool` | pass |
| `<` | `UInt32, UInt32` | `Bool` | pass |
| `<=` | `UInt32, UInt32` | `Bool` | pass |
| `>` | `UInt32, UInt32` | `Bool` | pass |
| `iszero` | `UInt32` | `Bool` | pass |
| `==` | `UInt64, UInt64` | `Bool` | gap |
| `!=` | `UInt64, UInt64` | `Bool` | pass |
| `<` | `UInt64, UInt64` | `Bool` | pass |
| `<=` | `UInt64, UInt64` | `Bool` | pass |
| `>` | `UInt64, UInt64` | `Bool` | pass |
| `iszero` | `UInt64` | `Bool` | pass |
| `==` | `Float32, Float32` | `Bool` | gap |
| `!=` | `Float32, Float32` | `Bool` | pass |
| `<` | `Float32, Float32` | `Bool` | pass |
| `<=` | `Float32, Float32` | `Bool` | pass |
| `>` | `Float32, Float32` | `Bool` | pass |
| `iszero` | `Float32` | `Bool` | pass |
| `==` | `Float64, Float64` | `Bool` | gap |
| `!=` | `Float64, Float64` | `Bool` | pass |
| `<` | `Float64, Float64` | `Bool` | pass |
| `<=` | `Float64, Float64` | `Bool` | pass |
| `>` | `Float64, Float64` | `Bool` | pass |
| `iszero` | `Float64` | `Bool` | pass |
| `isodd` | `Int8` | `Bool` | pass |
| `iseven` | `Int8` | `Bool` | pass |
| `isodd` | `Int16` | `Bool` | pass |
| `iseven` | `Int16` | `Bool` | pass |
| `isodd` | `Int32` | `Bool` | pass |
| `iseven` | `Int32` | `Bool` | pass |
| `isodd` | `Int64` | `Bool` | pass |
| `iseven` | `Int64` | `Bool` | pass |
| `isodd` | `UInt8` | `Bool` | pass |
| `iseven` | `UInt8` | `Bool` | pass |
| `isodd` | `UInt16` | `Bool` | pass |
| `iseven` | `UInt16` | `Bool` | pass |
| `isodd` | `UInt32` | `Bool` | pass |
| `iseven` | `UInt32` | `Bool` | pass |
| `isodd` | `UInt64` | `Bool` | pass |
| `iseven` | `UInt64` | `Bool` | pass |
| `isnan` | `Float32` | `Bool` | pass |
| `isinf` | `Float32` | `Bool` | pass |
| `isfinite` | `Float32` | `Bool` | pass |
| `signbit` | `Float32` | `Bool` | pass |
| `isnan` | `Float64` | `Bool` | pass |
| `isinf` | `Float64` | `Bool` | pass |
| `isfinite` | `Float64` | `Bool` | pass |
| `signbit` | `Float64` | `Bool` | pass |

## conv

| op | args | ret | status |
|---|---|---|---|
| `Int64` | `Int8` | `Int64` | gap |
| `Int64` | `Int16` | `Int64` | gap |
| `Int64` | `Int32` | `Int64` | gap |
| `Int64` | `UInt8` | `Int64` | gap |
| `Int64` | `UInt16` | `Int64` | gap |
| `Int64` | `UInt32` | `Int64` | gap |
| `signed` | `UInt64` | `Int64` | pass |
| `Float64` | `Int8` | `Float64` | gap |
| `Float32` | `Int8` | `Float32` | pass |
| `Float64` | `Int16` | `Float64` | gap |
| `Float32` | `Int16` | `Float32` | pass |
| `Float64` | `Int32` | `Float64` | gap |
| `Float32` | `Int32` | `Float32` | pass |
| `Float64` | `Int64` | `Float64` | gap |
| `Float32` | `Int64` | `Float32` | pass |
| `Float64` | `UInt8` | `Float64` | gap |
| `Float32` | `UInt8` | `Float32` | pass |
| `Float64` | `UInt16` | `Float64` | gap |
| `Float32` | `UInt16` | `Float32` | pass |
| `Float64` | `UInt32` | `Float64` | gap |
| `Float32` | `UInt32` | `Float32` | pass |
| `Float64` | `UInt64` | `Float64` | gap |
| `Float32` | `UInt64` | `Float32` | pass |
| `Float64` | `Float32` | `Float64` | gap |
| `Float32` | `Float64` | `Float32` | pass |
| `Int8` | `Int64` | `Int8` | pass |
| `Int16` | `Int64` | `Int16` | pass |
| `Int32` | `Int64` | `Int32` | pass |
| `Int64` | `Float64` | `Int64` | gap |

## dict

| op | args | ret | status |
|---|---|---|---|
| `length` | `Dict{Int64, Int64}` | `Int64` | gap |
| `isempty` | `Dict{Int64, Int64}` | `Bool` | gap |
| `haskey` | `Dict{Int64, Int64}, Int64` | `Bool` | pass |
| `get` | `Dict{Int64, Int64}, Int64, Int64` | `Int64` | pass |
| `getindex` | `Dict{Int64, Int64}, Int64` | `Int64` | pass |
| `length` | `Dict{Int32, Int64}` | `Int64` | gap |
| `isempty` | `Dict{Int32, Int64}` | `Bool` | gap |
| `haskey` | `Dict{Int32, Int64}, Int32` | `Bool` | pass |
| `get` | `Dict{Int32, Int64}, Int32, Int64` | `Int64` | pass |
| `getindex` | `Dict{Int32, Int64}, Int32` | `Int64` | pass |
| `length` | `Dict{Int64, Float64}` | `Int64` | gap |
| `isempty` | `Dict{Int64, Float64}` | `Bool` | gap |
| `haskey` | `Dict{Int64, Float64}, Int64` | `Bool` | pass |
| `get` | `Dict{Int64, Float64}, Int64, Float64` | `Float64` | pass |
| `getindex` | `Dict{Int64, Float64}, Int64` | `Float64` | pass |
| `length` | `Dict{String, Int64}` | `Int64` | gap |
| `isempty` | `Dict{String, Int64}` | `Bool` | gap |
| `haskey` | `Dict{String, Int64}, String` | `Bool` | pass |
| `get` | `Dict{String, Int64}, String, Int64` | `Int64` | pass |
| `getindex` | `Dict{String, Int64}, String` | `Int64` | pass |
| `length` | `Dict{Int64, String}` | `Int64` | gap |
| `isempty` | `Dict{Int64, String}` | `Bool` | gap |
| `haskey` | `Dict{Int64, String}, Int64` | `Bool` | pass |
| `get` | `Dict{Int64, String}, Int64, String` | `String` | pass |
| `getindex` | `Dict{Int64, String}, Int64` | `String` | pass |
| `length` | `Dict{String, String}` | `Int64` | gap |
| `isempty` | `Dict{String, String}` | `Bool` | gap |
| `haskey` | `Dict{String, String}, String` | `Bool` | pass |
| `get` | `Dict{String, String}, String, String` | `String` | pass |
| `getindex` | `Dict{String, String}, String` | `String` | pass |

## math

| op | args | ret | status |
|---|---|---|---|
| `hypot` | `Float32, Float32` | `Float32` | pass |
| `^` | `Float32, Float32` | `Float32` | gap |
| `sqrt` | `Float32` | `Float32` | gap |
| `cbrt` | `Float32` | `Float32` | pass |
| `sin` | `Float32` | `Float32` | gap |
| `cos` | `Float32` | `Float32` | gap |
| `tan` | `Float32` | `Float32` | pass |
| `asin` | `Float32` | `Float32` | gap |
| `acos` | `Float32` | `Float32` | pass |
| `atan` | `Float32` | `Float32` | pass |
| `sinh` | `Float32` | `Float32` | pass |
| `cosh` | `Float32` | `Float32` | pass |
| `tanh` | `Float32` | `Float32` | pass |
| `exp` | `Float32` | `Float32` | pass |
| `exp2` | `Float32` | `Float32` | pass |
| `expm1` | `Float32` | `Float32` | pass |
| `log` | `Float32` | `Float32` | pass |
| `log2` | `Float32` | `Float32` | pass |
| `log10` | `Float32` | `Float32` | pass |
| `log1p` | `Float32` | `Float32` | pass |
| `floor` | `Float32` | `Float32` | pass |
| `ceil` | `Float32` | `Float32` | pass |
| `round` | `Float32` | `Float32` | pass |
| `trunc` | `Float32` | `Float32` | pass |
| `inv` | `Float32` | `Float32` | pass |
| `sinpi` | `Float32` | `Float32` | pass |
| `cospi` | `Float32` | `Float32` | pass |
| `deg2rad` | `Float32` | `Float32` | pass |
| `rad2deg` | `Float32` | `Float32` | pass |
| `hypot` | `Float64, Float64` | `Float64` | pass |
| `^` | `Float64, Float64` | `Float64` | gap |
| `sqrt` | `Float64` | `Float64` | gap |
| `cbrt` | `Float64` | `Float64` | pass |
| `sin` | `Float64` | `Float64` | gap |
| `cos` | `Float64` | `Float64` | gap |
| `tan` | `Float64` | `Float64` | pass |
| `asin` | `Float64` | `Float64` | gap |
| `acos` | `Float64` | `Float64` | pass |
| `atan` | `Float64` | `Float64` | pass |
| `sinh` | `Float64` | `Float64` | pass |
| `cosh` | `Float64` | `Float64` | pass |
| `tanh` | `Float64` | `Float64` | pass |
| `exp` | `Float64` | `Float64` | pass |
| `exp2` | `Float64` | `Float64` | pass |
| `expm1` | `Float64` | `Float64` | pass |
| `log` | `Float64` | `Float64` | pass |
| `log2` | `Float64` | `Float64` | pass |
| `log10` | `Float64` | `Float64` | pass |
| `log1p` | `Float64` | `Float64` | pass |
| `floor` | `Float64` | `Float64` | pass |
| `ceil` | `Float64` | `Float64` | pass |
| `round` | `Float64` | `Float64` | pass |
| `trunc` | `Float64` | `Float64` | pass |
| `inv` | `Float64` | `Float64` | pass |
| `sinpi` | `Float64` | `Float64` | pass |
| `cospi` | `Float64` | `Float64` | pass |
| `deg2rad` | `Float64` | `Float64` | pass |
| `rad2deg` | `Float64` | `Float64` | pass |

## set

| op | args | ret | status |
|---|---|---|---|
| `length` | `Set{Int64}` | `Int64` | gap |
| `isempty` | `Set{Int64}` | `Bool` | gap |
| `in` | `Int64, Set{Int64}` | `Bool` | pass |
| `length` | `Set{Int32}` | `Int64` | gap |
| `isempty` | `Set{Int32}` | `Bool` | gap |
| `in` | `Int32, Set{Int32}` | `Bool` | pass |
| `length` | `Set{String}` | `Int64` | gap |
| `isempty` | `Set{String}` | `Bool` | gap |
| `in` | `String, Set{String}` | `Bool` | pass |

## string

| op | args | ret | status |
|---|---|---|---|
| `uppercase` | `String` | `String` | gap |
| `lowercase` | `String` | `String` | pass |
| `reverse` | `String` | `String` | pass |
| `strip` | `String` | `String` | pass |
| `lstrip` | `String` | `String` | pass |
| `rstrip` | `String` | `String` | pass |
| `chomp` | `String` | `String` | seen |
| `titlecase` | `String` | `String` | pass |
| `uppercasefirst` | `String` | `String` | pass |
| `lowercasefirst` | `String` | `String` | pass |
| `*` | `String, String` | `String` | pass |
| `string` | `Int64` | `String` | gap |
| `string` | `Float64` | `String` | gap |
| `length` | `String` | `Int64` | gap |
| `ncodeunits` | `String` | `Int64` | pass |
| `isempty` | `String` | `Bool` | gap |
| `isascii` | `String` | `Bool` | pass |
| `startswith` | `String, String` | `Bool` | pass |
| `endswith` | `String, String` | `Bool` | seen |
| `contains` | `String, String` | `Bool` | pass |
| `occursin` | `String, String` | `Bool` | pass |
| `cmp` | `String, String` | `Int64` | pass |

## tuple

| op | args | ret | status |
|---|---|---|---|
| `getindex` | `Tuple{Int64, Int64}, Val{1}` | `Int64` | pass |
| `getindex` | `Tuple{Int64, Int64}, Val{2}` | `Int64` | pass |
| `length` | `Tuple{Int64, Int64}` | `Int64` | gap |
| `reverse` | `Tuple{Int64, Int64}` | `Tuple{Int64, Int64}` | pass |
| `getindex` | `Tuple{Int64, Float64}, Val{1}` | `Int64` | pass |
| `getindex` | `Tuple{Int64, Float64}, Val{2}` | `Float64` | pass |
| `length` | `Tuple{Int64, Float64}` | `Int64` | gap |
| `getindex` | `Tuple{Float64, Bool}, Val{1}` | `Float64` | pass |
| `getindex` | `Tuple{Float64, Bool}, Val{2}` | `Bool` | pass |
| `length` | `Tuple{Float64, Bool}` | `Int64` | gap |
| `getindex` | `Tuple{Int64, Int64, Int64}, Val{1}` | `Int64` | pass |
| `getindex` | `Tuple{Int64, Int64, Int64}, Val{2}` | `Int64` | pass |
| `getindex` | `Tuple{Int64, Int64, Int64}, Val{3}` | `Int64` | pass |
| `length` | `Tuple{Int64, Int64, Int64}` | `Int64` | gap |
| `getindex` | `Tuple{Float64, Float64}, Val{1}` | `Float64` | pass |
| `getindex` | `Tuple{Float64, Float64}, Val{2}` | `Float64` | pass |
| `length` | `Tuple{Float64, Float64}` | `Int64` | gap |
| `reverse` | `Tuple{Float64, Float64}` | `Tuple{Float64, Float64}` | pass |
| `.a` | `@NamedTuple{a::Int64, b::Float64}` | `Int64` | pass |
| `.b` | `@NamedTuple{a::Int64, b::Float64}` | `Float64` | pass |
| `.n` | `@NamedTuple{n::Int64, flag::Bool}` | `Int64` | pass |
| `.flag` | `@NamedTuple{n::Int64, flag::Bool}` | `Bool` | seen |

## vector

| op | args | ret | status |
|---|---|---|---|
| `sort` | `Vector{Int64}` | `Vector{Int64}` | gap |
| `reverse` | `Vector{Int64}` | `Vector{Int64}` | pass |
| `unique` | `Vector{Int64}` | `Vector{Int64}` | gap |
| `length` | `Vector{Int64}` | `Int64` | gap |
| `isempty` | `Vector{Int64}` | `Bool` | gap |
| `map` | `Fn(Int64, Int64), Vector{Int64}` | `Vector{Int64}` | gap |
| `filter` | `Fn(Int64, Bool), Vector{Int64}` | `Vector{Int64}` | gap |
| `first` | `Vector{Int64}` | `Int64` | pass |
| `last` | `Vector{Int64}` | `Int64` | pass |
| `getindex` | `Vector{Int64}, Int64` | `Int64` | pass |
| `in` | `Int64, Vector{Int64}` | `Bool` | pass |
| `count` | `Fn(Int64, Bool), Vector{Int64}` | `Int64` | pass |
| `any` | `Fn(Int64, Bool), Vector{Int64}` | `Bool` | pass |
| `all` | `Fn(Int64, Bool), Vector{Int64}` | `Bool` | pass |
| `push!` | `Vector{Int64}, Int64` | `Vector{Int64}` | pass |
| `pushfirst!` | `Vector{Int64}, Int64` | `Vector{Int64}` | pass |
| `sort!` | `Vector{Int64}` | `Vector{Int64}` | pass |
| `reverse!` | `Vector{Int64}` | `Vector{Int64}` | pass |
| `sort` | `Vector{Int32}` | `Vector{Int32}` | gap |
| `reverse` | `Vector{Int32}` | `Vector{Int32}` | pass |
| `unique` | `Vector{Int32}` | `Vector{Int32}` | gap |
| `length` | `Vector{Int32}` | `Int64` | gap |
| `isempty` | `Vector{Int32}` | `Bool` | gap |
| `map` | `Fn(Int32, Int32), Vector{Int32}` | `Vector{Int32}` | gap |
| `filter` | `Fn(Int32, Bool), Vector{Int32}` | `Vector{Int32}` | gap |
| `first` | `Vector{Int32}` | `Int32` | pass |
| `last` | `Vector{Int32}` | `Int32` | pass |
| `getindex` | `Vector{Int32}, Int64` | `Int32` | pass |
| `in` | `Int32, Vector{Int32}` | `Bool` | pass |
| `count` | `Fn(Int32, Bool), Vector{Int32}` | `Int64` | pass |
| `any` | `Fn(Int32, Bool), Vector{Int32}` | `Bool` | pass |
| `all` | `Fn(Int32, Bool), Vector{Int32}` | `Bool` | pass |
| `push!` | `Vector{Int32}, Int32` | `Vector{Int32}` | pass |
| `pushfirst!` | `Vector{Int32}, Int32` | `Vector{Int32}` | pass |
| `sort!` | `Vector{Int32}` | `Vector{Int32}` | pass |
| `reverse!` | `Vector{Int32}` | `Vector{Int32}` | pass |
| `sort` | `Vector{Int8}` | `Vector{Int8}` | gap |
| `reverse` | `Vector{Int8}` | `Vector{Int8}` | pass |
| `unique` | `Vector{Int8}` | `Vector{Int8}` | gap |
| `length` | `Vector{Int8}` | `Int64` | gap |
| `isempty` | `Vector{Int8}` | `Bool` | gap |
| `map` | `Fn(Int8, Int8), Vector{Int8}` | `Vector{Int8}` | gap |
| `filter` | `Fn(Int8, Bool), Vector{Int8}` | `Vector{Int8}` | gap |
| `first` | `Vector{Int8}` | `Int8` | pass |
| `last` | `Vector{Int8}` | `Int8` | pass |
| `getindex` | `Vector{Int8}, Int64` | `Int8` | pass |
| `in` | `Int8, Vector{Int8}` | `Bool` | pass |
| `count` | `Fn(Int8, Bool), Vector{Int8}` | `Int64` | pass |
| `any` | `Fn(Int8, Bool), Vector{Int8}` | `Bool` | pass |
| `all` | `Fn(Int8, Bool), Vector{Int8}` | `Bool` | pass |
| `push!` | `Vector{Int8}, Int8` | `Vector{Int8}` | pass |
| `pushfirst!` | `Vector{Int8}, Int8` | `Vector{Int8}` | pass |
| `sort!` | `Vector{Int8}` | `Vector{Int8}` | pass |
| `reverse!` | `Vector{Int8}` | `Vector{Int8}` | pass |
| `sort` | `Vector{Float64}` | `Vector{Float64}` | gap |
| `reverse` | `Vector{Float64}` | `Vector{Float64}` | pass |
| `unique` | `Vector{Float64}` | `Vector{Float64}` | gap |
| `length` | `Vector{Float64}` | `Int64` | gap |
| `isempty` | `Vector{Float64}` | `Bool` | gap |
| `map` | `Fn(Float64, Float64), Vector{Float64}` | `Vector{Float64}` | gap |
| `filter` | `Fn(Float64, Bool), Vector{Float64}` | `Vector{Float64}` | gap |
| `first` | `Vector{Float64}` | `Float64` | pass |
| `last` | `Vector{Float64}` | `Float64` | pass |
| `getindex` | `Vector{Float64}, Int64` | `Float64` | pass |
| `in` | `Float64, Vector{Float64}` | `Bool` | pass |
| `count` | `Fn(Float64, Bool), Vector{Float64}` | `Int64` | pass |
| `any` | `Fn(Float64, Bool), Vector{Float64}` | `Bool` | pass |
| `all` | `Fn(Float64, Bool), Vector{Float64}` | `Bool` | pass |
| `push!` | `Vector{Float64}, Float64` | `Vector{Float64}` | pass |
| `pushfirst!` | `Vector{Float64}, Float64` | `Vector{Float64}` | pass |
| `sort!` | `Vector{Float64}` | `Vector{Float64}` | pass |
| `reverse!` | `Vector{Float64}` | `Vector{Float64}` | pass |
| `sort` | `Vector{Float32}` | `Vector{Float32}` | gap |
| `reverse` | `Vector{Float32}` | `Vector{Float32}` | pass |
| `unique` | `Vector{Float32}` | `Vector{Float32}` | gap |
| `length` | `Vector{Float32}` | `Int64` | gap |
| `isempty` | `Vector{Float32}` | `Bool` | gap |
| `map` | `Fn(Float32, Float32), Vector{Float32}` | `Vector{Float32}` | gap |
| `filter` | `Fn(Float32, Bool), Vector{Float32}` | `Vector{Float32}` | gap |
| `first` | `Vector{Float32}` | `Float32` | pass |
| `last` | `Vector{Float32}` | `Float32` | pass |
| `getindex` | `Vector{Float32}, Int64` | `Float32` | pass |
| `in` | `Float32, Vector{Float32}` | `Bool` | pass |
| `count` | `Fn(Float32, Bool), Vector{Float32}` | `Int64` | pass |
| `any` | `Fn(Float32, Bool), Vector{Float32}` | `Bool` | pass |
| `all` | `Fn(Float32, Bool), Vector{Float32}` | `Bool` | pass |
| `push!` | `Vector{Float32}, Float32` | `Vector{Float32}` | pass |
| `pushfirst!` | `Vector{Float32}, Float32` | `Vector{Float32}` | pass |
| `sort!` | `Vector{Float32}` | `Vector{Float32}` | pass |
| `reverse!` | `Vector{Float32}` | `Vector{Float32}` | pass |
| `sort` | `Vector{Bool}` | `Vector{Bool}` | gap |
| `reverse` | `Vector{Bool}` | `Vector{Bool}` | pass |
| `unique` | `Vector{Bool}` | `Vector{Bool}` | gap |
| `length` | `Vector{Bool}` | `Int64` | gap |
| `isempty` | `Vector{Bool}` | `Bool` | gap |
| `map` | `Fn(Bool, Bool), Vector{Bool}` | `Vector{Bool}` | gap |
| `filter` | `Fn(Bool, Bool), Vector{Bool}` | `Vector{Bool}` | gap |
| `first` | `Vector{Bool}` | `Bool` | pass |
| `last` | `Vector{Bool}` | `Bool` | pass |
| `getindex` | `Vector{Bool}, Int64` | `Bool` | pass |
| `in` | `Bool, Vector{Bool}` | `Bool` | pass |
| `count` | `Fn(Bool, Bool), Vector{Bool}` | `Int64` | pass |
| `any` | `Fn(Bool, Bool), Vector{Bool}` | `Bool` | pass |
| `all` | `Fn(Bool, Bool), Vector{Bool}` | `Bool` | pass |
| `push!` | `Vector{Bool}, Bool` | `Vector{Bool}` | pass |
| `pushfirst!` | `Vector{Bool}, Bool` | `Vector{Bool}` | pass |
| `sort!` | `Vector{Bool}` | `Vector{Bool}` | pass |
| `reverse!` | `Vector{Bool}` | `Vector{Bool}` | pass |
| `sum` | `Vector{Int64}` | `Int64` | pass |
| `prod` | `Vector{Int64}` | `Int64` | pass |
| `maximum` | `Vector{Int64}` | `Int64` | pass |
| `minimum` | `Vector{Int64}` | `Int64` | gap |
| `reduce` | `BinOp(), Vector{Int64}` | `Int64` | pass |
| `foldl` | `BinOp(), Vector{Int64}` | `Int64` | gap |
| `argmax` | `Vector{Int64}` | `Int64` | gap |
| `argmin` | `Vector{Int64}` | `Int64` | pass |
| `cumsum` | `Vector{Int64}` | `Vector{Int64}` | gap |
| `sum` | `Vector{Int32}` | `Int32` | pass |
| `prod` | `Vector{Int32}` | `Int32` | pass |
| `maximum` | `Vector{Int32}` | `Int32` | pass |
| `minimum` | `Vector{Int32}` | `Int32` | gap |
| `reduce` | `BinOp(), Vector{Int32}` | `Int32` | pass |
| `foldl` | `BinOp(), Vector{Int32}` | `Int32` | gap |
| `argmax` | `Vector{Int32}` | `Int64` | gap |
| `argmin` | `Vector{Int32}` | `Int64` | pass |
| `cumsum` | `Vector{Int32}` | `Vector{Int32}` | gap |
| `sum` | `Vector{Int8}` | `Int8` | pass |
| `prod` | `Vector{Int8}` | `Int8` | pass |
| `maximum` | `Vector{Int8}` | `Int8` | pass |
| `minimum` | `Vector{Int8}` | `Int8` | gap |
| `reduce` | `BinOp(), Vector{Int8}` | `Int8` | pass |
| `foldl` | `BinOp(), Vector{Int8}` | `Int8` | gap |
| `argmax` | `Vector{Int8}` | `Int64` | gap |
| `argmin` | `Vector{Int8}` | `Int64` | pass |
| `cumsum` | `Vector{Int8}` | `Vector{Int8}` | gap |
| `sum` | `Vector{Float64}` | `Float64` | pass |
| `prod` | `Vector{Float64}` | `Float64` | pass |
| `maximum` | `Vector{Float64}` | `Float64` | pass |
| `minimum` | `Vector{Float64}` | `Float64` | gap |
| `reduce` | `BinOp(), Vector{Float64}` | `Float64` | pass |
| `foldl` | `BinOp(), Vector{Float64}` | `Float64` | gap |
| `argmax` | `Vector{Float64}` | `Int64` | gap |
| `argmin` | `Vector{Float64}` | `Int64` | pass |
| `cumsum` | `Vector{Float64}` | `Vector{Float64}` | gap |
| `sum` | `Vector{Float32}` | `Float32` | pass |
| `prod` | `Vector{Float32}` | `Float32` | pass |
| `maximum` | `Vector{Float32}` | `Float32` | pass |
| `minimum` | `Vector{Float32}` | `Float32` | gap |
| `reduce` | `BinOp(), Vector{Float32}` | `Float32` | pass |
| `foldl` | `BinOp(), Vector{Float32}` | `Float32` | gap |
| `argmax` | `Vector{Float32}` | `Int64` | gap |
| `argmin` | `Vector{Float32}` | `Int64` | pass |
| `cumsum` | `Vector{Float32}` | `Vector{Float32}` | gap |

**Totals:** 198 gap · 387 pass · 3 seen · 1 unseen
