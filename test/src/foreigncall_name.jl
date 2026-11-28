# A foreigncall's name read as Julia's codegen reads it: interpret_symbol_arg (julia/src/ccall.cpp:571) asks
# static_eval (julia/src/codegen.cpp:2924), so a `(name, library)` whose library is a constant binding, base/gmp.jl's
# ccall((:__gmpz_*, libgmp), ...) shape, is that tuple, and the call goes on as one written with literals. A name
# static_eval does not know rejects, located, with Julia's reading: a library computed at run time, which codegen
# loads when first called (ccall.cpp:589, lib_expr), or else a function pointer (ccall.cpp:596 emit_expr). A builtin
# static_eval applies that throws answers not static (codegen.cpp:3009-3013 JL_CATCH), never a value.
module ForeigncallNameTest
using Test, WasmTarget
const W = WasmTarget

module Cases
# a constant binding naming a host module (Math, JS's), so the known tuple compiles to the import Math.sin
const FC_HOST = "Math"
# the same library, and a name, held by non-constant bindings: values only run time knows
fc_lib_var = "Math"
fc_name_var = :sin
@noinline fc_sin(x::Float64) = ccall((:sin, FC_HOST), Float64, (Float64,), x)
fc_const(x::Float64) = fc_sin(x) + 1.0
fc_runtime(x::Float64) = ccall((:sin, fc_lib_var), Float64, (Float64,), x)
fc_name(x::Float64) = ccall((fc_name_var, FC_HOST), Float64, (Float64,), x)
end

world_of(f, at) = W.build_nir(W.check_subset(f, at, "foreigncall_name", Base.get_world_counter()), "foreigncall_name")
body_named(world, name) = only(b for b in world if b.ci.def.def.name === name)
rejection(f) = try; f(); nothing; catch e; e isa W.RejectionError ? e : rethrow(); end
shown(e) = e === nothing ? "no rejection" : sprint(showerror, e)

@testset "a foreigncall's (name, library) whose library is a constant binding is that tuple" begin
    # optimized IR holds the call Core.tuple(:sin, Cases.FC_HOST); the NIR reads it as the constant tuple
    local ci = Base.code_typed(Cases.fc_sin, (Float64,))[1][1]
    local fc = only(st for st in ci.code if st isa Expr && st.head === :foreigncall)
    @test fc.args[1] == Expr(:call, GlobalRef(Core, :tuple), QuoteNode(:sin), GlobalRef(Cases, :FC_HOST))
    local sb = body_named(world_of(Cases.fc_const, (Float64,)), :fc_sin)
    local call = only(st for st in sb.stmts if st isa W.NirForeignCall)
    @test call.args[1] isa W.NirConst && call.args[1].c.val === (:sin, "Math")
    local imp = W.nir_foreign_import(sb, call)
    @test (imp.lib, imp.name, imp.params, imp.rt) == ("Math", "sin", Type[Float64], Float64)
    # the compiled module imports Math.sin and, run with JS's Math, answers as Julia's sin does natively
    local path = tempname() * ".wasm"
    write(path, W.compile(Cases.fc_const, (Float64,)))
    local script = "const m = new WebAssembly.Module(require('fs').readFileSync(process.argv[1])); " *
        "const i = new WebAssembly.Instance(m, {Math: Math}); " *
        "console.log(WebAssembly.Module.imports(m).map(x => x.module + '.' + x.name).join(',') + ' ' + i.exports.fc_const(0.5))"
    local out = readchomp(`node -e $script $path`)
    rm(path)
    @test out == "Math.sin $(sin(0.5) + 1.0)"
end

@testset "a foreigncall's name static_eval does not know rejects, located, with Julia's reading" begin
    # a library a non-constant binding holds: codegen loads it when first called; WasmTarget rejects at the name
    local e1 = rejection(() -> W.compile(Cases.fc_runtime, (Float64,)))
    @test (e1 isa W.RejectionError && e1.rejection isa W.Unquarantined &&
           occursin("the foreigncall sin of a library computed at run time, ", e1.rejection.row) &&
           occursin("fc_lib_var", e1.rejection.row) && occursin("ccall.cpp:589", e1.rejection.row)) || (@info "fc_runtime" shown(e1); false)
    # a name a non-constant binding holds: no (name, library) static_eval knows, so codegen reads a pointer
    local e2 = rejection(() -> W.compile(Cases.fc_name, (Float64,)))
    @test (e2 isa W.RejectionError && e2.rejection isa W.Unquarantined &&
           occursin("a foreigncall through a function pointer computed at run time", e2.rejection.row) &&
           occursin("fc_name_var", e2.rejection.row)) || (@info "fc_name" shown(e2); false)
end

@testset "a builtin static_eval applies that throws is not static (JL_CATCH), and its name rejects, located" begin
    local bindings = W.NirBindings(Base.get_world_counter())
    # tuple and apply_type of known values are applied; a constant binding is its value
    @test W._nir_static_eval(Expr(:call, GlobalRef(Core, :tuple), QuoteNode(:sin), GlobalRef(Cases, :FC_HOST)), bindings) == Some{Any}((:sin, "Math"))
    @test W._nir_static_eval(Expr(:call, GlobalRef(Core, :apply_type), Vector, Int64), bindings) == Some{Any}(Vector{Int64})
    @test W._nir_static_eval(GlobalRef(Cases, :fc_lib_var), bindings) === nothing
    # apply_type(Int64, 1) throws natively; static_eval's answer is not static, never a value
    @test_throws TypeError Core.apply_type(Int64, 1)
    local thrown = Expr(:call, GlobalRef(Core, :apply_type), Int64, 1)
    @test W._nir_static_eval(thrown, bindings) === nothing
    # and that name, unknown, rejects as a function pointer at the name, located
    local e = rejection(() -> W._nir_ccall_name(thrown, bindings, "foreigncall_name"))
    @test (e isa W.RejectionError && e.rejection isa W.Unquarantined &&
           occursin("a foreigncall through a function pointer computed at run time", e.rejection.row)) || (@info "thrown" shown(e); false)
end
end
