# The interpreter the closed world is inferred with (src/julia/interpreter.jl): Julia's trim inference
# over WasmTarget's overlay method table, each CodeInstance under WasmTarget's own cache owner, so the
# native cache never holds an overlaid body nor the closed world a native one.
module InterpreterTest

using Test
using WasmTarget

const W = WasmTarget

f_sum(n::Int64) = (s = 0; for i in 1:n; s += i * i; end; s)

@testset "interpreter.jl" begin
    @test W.METHOD_TABLE isa Core.MethodTable
    local interp = W.WasmInterpreter(Base.get_world_counter(); inf_params = Core.Compiler.InferenceParams())
    @test Core.Compiler.cache_owner(interp) === W.WasmCacheOwner() && !Core.Compiler.isoverlayed(Core.Compiler.method_table(interp).table)
    # every body of a closed world is WasmTarget's, inferred over the overlay table
    local world = W.check_subset(f_sum, (Int64,), "interpreter")
    local cis = [x for x in world.codeinfos if x isa Core.CodeInstance]
    @test !isempty(cis) && all(ci -> ci.owner === W.WasmCacheOwner(), cis)
end

end
