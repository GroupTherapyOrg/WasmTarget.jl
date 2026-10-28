# dart2wasm's records.dart, ported (src/records.jl, dev/MARCH.md 1.C): RecordShape on fixed inputs.
using Test
using WasmTarget

const DR = WasmTarget.Dart2Wasm

@testset "records.dart: RecordShape" begin
    local s = DR.RecordShape(2, ["b", "a"])
    # names sorted, each indexed after the positionals in the order given
    @test names(s) == ["a", "b"] && DR.num_fields(s) == 4
    @test DR.get_name_index(s, "b") == DR.FieldIndex_record_field_base() + 2
    @test DR.get_name_index(s, "a") == DR.FieldIndex_record_field_base() + 3
    @test DR.get_positional_index(s, 1) == DR.FieldIndex_record_field_base() + 1
    @test sprint(show, s) == "Record(positionals: 2, names: {a: 3, b: 2})"
    # equal by positionals and names, whatever the names' given order; hashed alike
    @test s == DR.RecordShape(2, ["a", "b"]) && hash(s) == hash(DR.RecordShape(2, ["a", "b"]))
    @test s != DR.RecordShape(1, ["a", "b"]) && s != DR.RecordShape(2, ["a"]) && s != DR.RecordShape(2, ["a", "c"])
    @test s != 2
    @test DR.num_fields(DR.RecordShape(3, String[])) == 3 && isempty(names(DR.RecordShape(3, String[])))
    local e = try; DR.get_name_index(s, "z"); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Internal && occursin("name z not in record", e.rejection.site)
end
