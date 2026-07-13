using Test
using WasmTarget

function _wt_memmove_copy_entry()::Int64
    source = UInt8[1, 2, 3]
    copied = copy(source)
    return Int64(copied[2])
end

@testset "single memmove array-copy path" begin
    @test _wt_memmove_copy_entry() == 2
    bytes = WasmTarget.compile(_wt_memmove_copy_entry, (); validate=true)
    @test run_wasm(bytes, "_wt_memmove_copy_entry") == 2
end
