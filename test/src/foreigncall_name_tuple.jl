# Julia 1.13 writes a foreigncall's name as tuple syntax (julia-syntax.scm): ccall(:memmove, ...) as
# Expr(:tuple, QuoteNode(:memmove)) and ccall((:sin, L), ...) as Expr(:tuple, QuoteNode(:sin), GlobalRef(M, :L)), and
# its codegen reads each element by static_eval (julia v1.13.1 src/ccall.cpp:682 interpret_ccall_symbol_arg), as 1.12
# reads the whole Core.tuple call (julia/src/ccall.cpp:571 interpret_symbol_arg). The gate runs Julia 1.12, whose
# lowering never writes the tuple syntax, so the forms are the ones 1.13.1's code_typed prints, built here: each reads
# to the value 1.12's form of the same call reads to, and an element static_eval does not know rejects, located.
module ForeigncallNameTupleTest
using Test, WasmTarget
const W = WasmTarget

module Cases
# a constant binding naming a host module, and the same library and a name held by non-constant bindings
const FC_HOST = "Math"
fc_lib_var = "Math"
fc_name_var = :sin
end

rejection(f) = try; f(); nothing; catch e; e isa W.RejectionError ? e : rethrow(); end
shown(e) = e === nothing ? "no rejection" : sprint(showerror, e)
rejects_with(f, text) = (local e = rejection(f);
    (e isa W.RejectionError && e.rejection isa W.Unquarantined && occursin(text, e.rejection.row)) || (@info text shown(e); false))

@testset "a 1.13 name tuple's elements are read by static_eval" begin
    local bindings = W.NirBindings(Base.get_world_counter())
    local read(x) = W._nir_ccall_name(x, bindings, "foreigncall_name_tuple")
    # (:memmove,): the name alone
    local one = read(Expr(:tuple, QuoteNode(:memmove)))
    @test one isa W.NirConst && one.c.val === (:memmove,)
    # (:sin, FC_HOST): the library a constant binding, its value, as 1.12's Core.tuple call of the same reads
    local two = read(Expr(:tuple, QuoteNode(:sin), GlobalRef(Cases, :FC_HOST)))
    local twelve = read(Expr(:call, GlobalRef(Core, :tuple), QuoteNode(:sin), GlobalRef(Cases, :FC_HOST)))
    @test two isa W.NirConst && two.c.val === (:sin, "Math")
    @test twelve isa W.NirConst && twelve.c.val === two.c.val
end

@testset "a 1.13 name tuple's element static_eval does not know rejects, located" begin
    local bindings = W.NirBindings(Base.get_world_counter())
    local read(x) = () -> W._nir_ccall_name(x, bindings, "foreigncall_name_tuple")
    # a library a non-constant binding holds: codegen loads it when first called (f_lib_expr)
    @test rejects_with(read(Expr(:tuple, QuoteNode(:sin), GlobalRef(Cases, :fc_lib_var))), "the foreigncall sin of a library computed at run time")
    # a name a non-constant binding holds: computed at run time
    @test rejects_with(read(Expr(:tuple, GlobalRef(Cases, :fc_name_var), QuoteNode("Math"))), "a foreigncall whose name is computed at run time")
    # a builtin static_eval applies that throws is no value (codegen.cpp:3009-3013 JL_CATCH): the name unknown
    @test rejects_with(read(Expr(:tuple, Expr(:call, GlobalRef(Core, :apply_type), Int64, 1))), "a foreigncall whose name is computed at run time")
    # no element, or three: 1.13's codegen reads no name from the tuple
    @test rejects_with(read(Expr(:tuple)), "a foreigncall name tuple of 0 elements")
    @test rejects_with(read(Expr(:tuple, QuoteNode(:sin), QuoteNode("Math"), QuoteNode(:x))), "a foreigncall name tuple of 3 elements")
end
end
