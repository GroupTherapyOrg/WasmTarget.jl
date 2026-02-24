using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
const Compiler = Core.Compiler

bl = Compiler.PartialsLattice{Compiler.ConstsLattice}
bytes = compile(Compiler.builtin_effects, (bl, Core.Builtin, Vector{Any}, Any))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

errbuf = IOBuffer()
ok = false
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    ok = true
catch; end

if ok
    println("VALIDATES!")
else
    err = String(take!(errbuf))
    println(err)
end
