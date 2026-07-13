using Test

_escaped_object_pointer(v::Vector{UInt8}) = pointer_from_objref(v)

@testset "storage-relative pointers cannot escape" begin
    rejected = false
    try
        WasmTarget.compile(_escaped_object_pointer, (Vector{UInt8},))
    catch err
        rejected = err isa WasmTarget.WasmCompileError &&
            occursin("jl_value_ptr escapes storage-relative WasmGC operations",
                     sprint(showerror, err))
    end
    @test rejected

    statements = read(joinpath(@__DIR__, "..", "src", "codegen", "statements.jl"), String)
    calls = read(joinpath(@__DIR__, "..", "src", "codegen", "calls.jl"), String)
    @test occursin("_storage_relative_pointer_is_closed(ctx, idx)", statements)
    @test occursin("phi-multiple-storage", statements)
    @test !occursin("fake-pointer", statements * calls)
end
