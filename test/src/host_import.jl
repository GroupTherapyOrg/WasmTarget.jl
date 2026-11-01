# A host import (dev/MARCH.md 1.F): each foreign call to a library the host supplies is lowered as
# Julia's ccall lowering lowers it (ccall.cpp emit_ccall), its callee the wasm import
# `<library>.<symbol>`, dart's `@pragma("wasm:import", ...)` procedure (src/julia/runtime/rtutils.jl
# nir_foreign_import); a foreign call to any other library rejects where it stands, located.

module HostImportTest

using Test
using WasmTarget

const W = WasmTarget
const D = WasmTarget.Dart2Wasm

module Cases
import WasmTarget as W
# a call of JS's Math.sin, one of the host's modules, and of a C library's sin, none of them
@noinline host_sin(x::Float64) = ccall((:sin, "Math"), Float64, (Float64,), x)
@noinline libm_sin(x::Float64) = ccall((:sin, "libm"), Float64, (Float64,), x)
host(x::Float64) = host_sin(x) + 1.0
# two host calls inlined in one body beside other code, no method of its own: each call site imports
hosts(x::Float64) = 2.0 * ccall((:sin, "Math"), Float64, (Float64,), x) + ccall((:cos, "Math"), Float64, (Float64,), x)
libm(x::Float64) = libm_sin(x) + 1.0
# a host reference made by one host import and passed to another: JS's Array.of() and Array.isArray
@noinline js_array_of() = ccall((:of, "Array"), W.WasmExternRef, ())
@noinline js_is_array(a::W.WasmExternRef) = ccall((:isArray, "Array"), Int32, (W.WasmExternRef,), a)
is_array() = Int64(js_is_array(js_array_of()))
# a host module's function taking a value with no wasm boundary type
struct Pair2; a::Int; b::Int; end
@noinline host_pair(p::Pair2) = ccall((:max, "Math"), Float64, (Pair2,), p)
pair(x::Int) = host_pair(Pair2(x, x))
end

world_of(f, at) = W.build_nir(W.check_subset(f, at, "host_import"), "host_import")
body_named(world, name) = only(b for b in world if b.ci.def.def.name === name)
foreign_calls(body) = [st for st in body.stmts if st isa W.NirForeignCall]
# the module run in node with JS's globals as the host's modules: its imports, sorted (their order is
# the order the code generator meets the call sites), and the entry's answer
function run_in_node(bytes, entry, args...)
    local path = tempname() * ".wasm"
    write(path, bytes)
    local script = "const m = new WebAssembly.Module(require('fs').readFileSync(process.argv[1])); " *
        "const i = new WebAssembly.Instance(m, {Math: Math, Array: Array}); " *
        "console.log(WebAssembly.Module.imports(m).map(x => x.module + '.' + x.name).sort().join(',') + ' ' + i.exports.$entry($(join(args, ", "))))"
    local out = readchomp(`node -e $script $path`)
    rm(path)
    return out
end
rejection(f) = try; f(); nothing; catch e; e isa W.RejectionError ? e : rethrow(); end

@testset "host import: a foreign call to a host module is dart's wasm:import" begin
    # the host's modules are the JS runtime's baseImports keys
    @test issubset(["Math", "Date", "Object", "Array", "Reflect", "WebAssembly"], W.host_modules())
    @test !("JSTag" in W.host_modules())
    local hw = world_of(Cases.host, (Float64,))
    local sb = body_named(hw, :host_sin)
    local imp = W.nir_foreign_import(sb, only(foreign_calls(sb)))
    @test (imp.lib, imp.name, imp.params, imp.rt) == ("Math", "sin", Type[Float64], Float64)
    # no Julia method is a wasm:import: the call site is
    @test D.Util.get_wasm_import_pragma(body_named(hw, :host_sin).ci.def; component = hw) === nothing
    # the compiled module imports Math.sin, (f64) -> f64, and calls it in place of a body
    local bytes = W.compile(Cases.host, (Float64,))
    local path = tempname() * ".wasm"
    write(path, bytes)
    local imports = readchomp(`node -e "const m = new WebAssembly.Module(require('fs').readFileSync(process.argv[1])); console.log(WebAssembly.Module.imports(m).map(i => i.module + '.' + i.name + ':' + i.kind).join(','))" $path`)
    rm(path)
    @test imports == "Math.sin:function"
    # run with JS's Math, it answers as Julia's sin does natively
    @test run_in_node(bytes, "host", 0.5) == "Math.sin $(sin(0.5) + 1.0)"
    # each call site in one body imports its own callee, one import per symbol and signature
    @test run_in_node(W.compile(Cases.hosts, (Float64,)), "hosts", 0.5) == "Math.cos,Math.sin $(2.0 * sin(0.5) + cos(0.5))"
end

@testset "host import: a host reference crosses as wasm's externref" begin
    # Array.of() makes a JS array the module holds as an externref and passes to Array.isArray: the
    # module, given JS's Array as the host's, answers JS's true, 1
    @test run_in_node(W.compile(Cases.is_array, ()), "is_array") == "Array.isArray,Array.of 1"
end

@testset "host import: a foreign call to any other library rejects, located" begin
    # libm is no host module: the method is no import, and its foreign call rejects where it stands
    local lw = world_of(Cases.libm, (Float64,))
    local lb = body_named(lw, :libm_sin)
    @test W.nir_foreign_import(lb, only(foreign_calls(lb))) === nothing
    local e = rejection(() -> W.compile(Cases.libm, (Float64,)))
    @test e !== nothing && e.rejection isa W.Unquarantined && occursin("foreign call", sprint(showerror, e))
    # a host module's function taking a struct, which no wasm boundary type carries
    local p = rejection(() -> W.compile(Cases.pair, (Int,)))
    @test p !== nothing && p.rejection isa W.Unquarantined && occursin("no wasm boundary type", sprint(showerror, p))
end

end
