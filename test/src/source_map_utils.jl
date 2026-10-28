# dart2wasm's source_map_utils.dart, ported (src/source_map_utils.jl): the minified class names written
# into a source map and read back, the indices dart's (from 0), each expected value built by hand.
using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm

@testset "source_map_utils.dart" begin
    local sm = Dict{String,Any}("version" => 3, "names" => ["String", "f"])
    local classes = Union{String,Nothing}["Object", nothing, "String", nothing, "List", nothing]
    D.add_minified_class_names(sm, classes)
    # "String" reused at index 0; "Object" and "List" appended at 2 and 3
    @test sm["names"] == ["String", "f", "Object", "List"]
    local ext = sm["x_org_dartlang_dart2js"]["minified_names"]
    @test ext["global"] == "Class0,2,Class2,0,Class4,3" && ext["instance"] == ""
    @test collect(keys(ext)) == ["global", "instance"]   # dart's map literal order
    # read back: the original list but its trailing nothings
    @test D.get_minified_class_names(sm) == Union{String,Nothing}["Object", nothing, "String", nothing, "List"]
    @test D.get_minified_class_names(Dict{String,Any}("names" => String[])) === nothing
    local bad = Dict{String,Any}("names" => ["a"], "x_org_dartlang_dart2js" => Dict{String,Any}("minified_names" => Dict{String,Any}("global" => "Class0,7")))
    local e = try; D.get_minified_class_names(bad); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Internal
end
