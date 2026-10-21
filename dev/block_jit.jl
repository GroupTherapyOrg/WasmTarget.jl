# dev/block_jit.jl — loaded by dev/block.jl's smoke stages before the test (`julia -L`): the code
# WasmTarget and Julia's compiler compile at run time is optimized at LLVM's level 0, everything
# else at Julia's default. A fresh smoke process spends most of its first minute compiling the
# compiler (measured on five groups, 47 cases: 66 s at the default, 48 s with this), and LLVM's
# level changes no answer either module gives: the bytes a compile emits are the same (all 225
# probes byte-identical at -O0) and Base and the test's own functions, whose answers smoke compares
# against, stay at the default (a whole-process -O0 changes three bit-exact answers: muladd and
# two Float32 functions round otherwise). Outside src/: a dev-only speedup, never the package's.
# (in a `let`: Main gains no binding but the `WasmTarget` the test's own `using` gives it)
using WasmTarget
let
    for m in (WasmTarget, Core.Compiler)
        ccall(:jl_set_module_optlevel, Cvoid, (Any, Cint), m, 0)
    end
end
