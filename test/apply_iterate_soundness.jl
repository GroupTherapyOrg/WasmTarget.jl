function _wt_runtime_tuple_empty(v::Vector{Int64})::Int32
    t = (v...,)
    return t isa Tuple{} ? Int32(1) : Int32(0)
end

@testset "_apply_iterate never fabricates Tuple{}" begin
    err = try
        WasmTarget.compile(_wt_runtime_tuple_empty, (Vector{Int64},))
        nothing
    catch e
        e
    end
    @test err isa WasmTarget.WasmCompileError
    @test occursin("variable-tuple representation", sprint(showerror, err))
end
