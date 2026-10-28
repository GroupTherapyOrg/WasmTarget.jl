# The stackifier end to end (src/llvm/, dev/LEDGER.md D42): Julia functions with branches, loops and
# phis compiled through the code generator's visitBlock over LLVM's structured control flow, each
# module run by node and its answers compared with native Julia's on the same inputs.
using Test
using WasmTarget

const W = WasmTarget
const D = WasmTarget.Dart2Wasm
const B = WasmTarget.WasmBuilder
const IR = WasmTarget.WasmBuilder.IR

module ControlFlowCases
function sum_to(n::Int64)
    s = Int64(0)
    i = Int64(1)
    while i <= n
        s += i
        i += Int64(1)
    end
    s
end
function fib(n::Int64)
    a, b = Int64(0), Int64(1)
    while n > Int64(0)
        a, b = b, a + b
        n -= Int64(1)
    end
    a
end
function floats(x::Float64, y::Float64)
    if x > 0.0
        y > x ? x * y : x - y
    elseif y < 0.0
        x + y
    else
        -1.5
    end
end
diamond(x::Int64) = (x > Int64(10) ? x * Int64(2) : x + Int64(7)) - Int64(1)
function early(x::Int64, y::Int64)
    x < Int64(0) && return Int64(0)
    i = Int64(0)
    while i < y
        i > x && return i
        i += Int64(1)
    end
    y
end
function nested(n::Int64)
    s = Int64(0)
    i = Int64(0)
    while i < n
        j = Int64(0)
        while j < i
            j > Int64(3) && @goto next
            s += j
            j += Int64(1)
        end
        @label next
        s -= Int64(1)
        i += Int64(1)
    end
    s
end
end

# the module of one function, `f` exported (as test/code_generator.jl's compile_one)
function compile_one(f, argtypes)
    local t = D.Translator(W.check_subset(f, argtypes, "llvm_control_flow"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    t.constants[] = D.Constants(t)
    local mb = D.main_module(t)
    local nb = only(t.component)
    local sig = B.define_function(mb.types[], IR.ValueType[D.translate_type(t, T) for T in argtypes], IR.ValueType[D.translate_return_type(t, nb.ci.rettype)])
    local fb = B.define(mb.functions[], sig, "f")
    D.generate(D.get_member_code_generator(t, fb, nb.ci.def), B.body(fb), B.locals(fb), nothing)
    B.var"export"(mb.exports, "f", fb)
    local s = B.Serializer(); B.serialize(s, B.build(mb))
    return B.data(s)
end

# node's answers for each argument tuple, as strings Julia's `string` writes: an Int64 is a BigInt
# in JS, a Float64 a number
function node_answers(bytes, argsets, argtypes)
    local dir = mktempdir()
    local wasm = joinpath(dir, "m.wasm")
    write(wasm, bytes)
    local js(x) = x isa Int64 ? "$(x)n" : x isa Float64 ? (isnan(x) ? "NaN" : string(x)) : string(x)
    local calls = join(["console.log(String(f($(join(map(js, a), ", ")))));" for a in argsets], "\n")
    local script = """
        const fs = require('fs');
        const { instance } = await WebAssembly.instantiate(fs.readFileSync('$(wasm)'));
        const f = instance.exports.f;
        $(calls)
        """
    local path = joinpath(dir, "run.mjs")
    write(path, replace(script, "require('fs')" => "(await import('fs')).default"))
    local out = readlines(`node $path`)
    rm(dir; recursive = true)
    return out
end

native_string(x::Float64) = x == trunc(x) && isfinite(x) && abs(x) < 1e21 ? string(Int64(x)) : string(x)
native_string(x) = string(x)

@testset "control flow end to end, against native" begin
    local C = ControlFlowCases
    for (f, argtypes, argsets) in [
            (C.sum_to, (Int64,), [(Int64(0),), (Int64(1),), (Int64(10),), (Int64(1000),)]),
            (C.fib, (Int64,), [(Int64(0),), (Int64(1),), (Int64(2),), (Int64(47),), (Int64(90),)]),
            (C.floats, (Float64, Float64), [(1.0, 2.0), (2.0, 1.0), (-1.0, -2.0), (-1.0, 3.0), (0.0, 0.0)]),
            (C.diamond, (Int64,), [(Int64(3),), (Int64(10),), (Int64(11),), (typemin(Int64),)]),
            (C.early, (Int64, Int64), [(Int64(-1), Int64(5)), (Int64(2), Int64(9)), (Int64(9), Int64(3))]),
            (C.nested, (Int64,), [(Int64(0),), (Int64(3),), (Int64(8),)])]
        @testset "$f" begin
            local bytes = compile_one(f, argtypes)
            @test bytes[1:8] == UInt8[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
            @test node_answers(bytes, argsets, argtypes) == [native_string(f(a...)) for a in argsets]
        end
    end
end
