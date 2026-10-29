# A host import (dev/MARCH.md 1.F): a method whose whole body is a foreign call to a module the host
# supplies is dart's `@pragma("wasm:import", "<module>.<name>")` (src/julia/runtime/rtutils.jl
# nir_host_import), and getFunction imports it; a foreign call to any other library stays a statement
# the code generator rejects, located.

module HostImportTest

using Test
using WasmTarget

const W = WasmTarget
const D = WasmTarget.Dart2Wasm

module Cases
# a call of JS's Math.sin, one of the host's modules, and of a C library's sin, none of them
@noinline host_sin(x::Float64) = ccall((:sin, "Math"), Float64, (Float64,), x)
@noinline libm_sin(x::Float64) = ccall((:sin, "libm"), Float64, (Float64,), x)
host(x::Float64) = host_sin(x) + 1.0
libm(x::Float64) = libm_sin(x) + 1.0
# a host module's function taking a value with no wasm boundary type
struct Pair2; a::Int; b::Int; end
@noinline host_pair(p::Pair2) = ccall((:max, "Math"), Float64, (Pair2,), p)
pair(x::Int) = host_pair(Pair2(x, x))
end

world_of(f, at) = W.build_nir(W.check_subset(f, at, "host_import"), "host_import")
mi_named(world, name) = only(b.ci.def for b in world if b.ci.def.def.name === name)
rejection(f) = try; f(); nothing; catch e; e isa W.RejectionError ? e : rethrow(); end

@testset "host import: a foreign call to a host module is dart's wasm:import" begin
    # the host's modules are the JS runtime's baseImports keys
    @test issubset(["Math", "Date", "Object", "Array", "Reflect", "WebAssembly"], W.host_modules())
    @test !("JSTag" in W.host_modules())
    local hw = world_of(Cases.host, (Float64,))
    @test W.nir_host_import(hw, mi_named(hw, :host_sin)) == ("Math", "sin")
    @test W.nir_host_import(hw, mi_named(hw, :host)) === nothing
    local import_name = D.Util.get_wasm_import_pragma(mi_named(hw, :host_sin); component = hw)
    @test import_name.module_name == "Math" && import_name.item_name == "sin"
    # the compiled module imports Math.sin, (f64) -> f64, and calls it in place of a body
    local bytes = W.compile(Cases.host, (Float64,))
    local path = tempname() * ".wasm"
    write(path, bytes)
    local imports = readchomp(`node -e "const m = new WebAssembly.Module(require('fs').readFileSync(process.argv[1])); console.log(WebAssembly.Module.imports(m).map(i => i.module + '.' + i.name + ':' + i.kind).join(','))" $path`)
    rm(path)
    @test imports == "Math.sin:function"
end

@testset "host import: a foreign call to any other library rejects, located" begin
    # libm is no host module: the method is no import, and its foreign call rejects where it stands
    local lw = world_of(Cases.libm, (Float64,))
    @test W.nir_host_import(lw, mi_named(lw, :libm_sin)) === nothing
    local e = rejection(() -> W.compile(Cases.libm, (Float64,)))
    @test e !== nothing && e.rejection isa W.Unquarantined && occursin("foreign call", sprint(showerror, e))
    # a host module's function taking a struct, which no wasm boundary type carries
    local p = rejection(() -> W.compile(Cases.pair, (Int,)))
    @test p !== nothing && p.rejection isa W.Unquarantined && occursin("no wasm boundary type", sprint(showerror, p))
end

end
