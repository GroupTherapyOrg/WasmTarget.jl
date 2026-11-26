# cglobal's name read as a foreigncall's, by Julia's static_eval (julia/src/ccall.cpp:690 emit_cglobal calls
# interpret_symbol_arg): a `(name, library)` whose library is a constant binding is that tuple, so the cglobal reaches
# the intrinsifier, where WasmTarget has no host global to answer it and rejects, located; a library only run time
# knows rejects at the name with Julia's own reading (a library its codegen loads when first called). BigInt's
# finalizer, cglobal((:__gmpz_clear, libgmp)), is one: libgmp is a const binding (julia/base/gmp.jl).
module CglobalNameTest
using Test, WasmTarget
const CG_LIB = "libcglobal_probe"
cg_lib_var = "libcglobal_probe"
cg_const(x::Int64) = Int64(cglobal((:cg_probe_sym, CG_LIB)) == C_NULL) + x
cg_runtime(x::Int64) = Int64(cglobal((:cg_probe_sym, cg_lib_var)) == C_NULL) + x
rejection(f) = try; WasmTarget.compile(f, (Int64,)); nothing; catch e; e; end
@testset "cglobal's name is read by static_eval, as a foreigncall's" begin
    local e1 = rejection(cg_const)
    @test (e1 isa WasmTarget.RejectionError && occursin("Julia's cglobal on Tuple{Symbol, String}", sprint(showerror, e1)) &&
           !occursin("outside NirValue", sprint(showerror, e1))) || (@info "cg_const" e1 === nothing ? "compiled" : sprint(showerror, e1); false)
    local e2 = rejection(cg_runtime)
    @test (e2 isa WasmTarget.RejectionError && e2.rejection isa WasmTarget.Unquarantined &&
           occursin("cg_probe_sym of a library computed at run time", e2.rejection.row)) || (@info "cg_runtime" e2 === nothing ? "compiled" : sprint(showerror, e2); false)
end
end
