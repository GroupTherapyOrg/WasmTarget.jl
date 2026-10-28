# dart2wasm's translator.dart, ported (src/translator.jl, dev/MARCH.md 1.A9 and 1.C): each filled
# definition answers as dart's does on fixed inputs.
using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm

@testset "translator.dart: TranslatorOptions" begin
    local O = D.TranslatorOptions
    local o = O()
    # dart's field initializers
    @test o.optimization_level == 1 && o.generate_source_maps && o.unique_constant_names && !o.enable_asserts
    @test o.enable_unique_types === nothing && o.shared_memory_max_pages === nothing && o.watch_points == Int[]
    # each construction its own list, as dart's `= []` initializer
    push!(o.watch_points, 3)
    @test O().watch_points == Int[]
    # the getters: the override where set, else the optimization level's threshold
    @test D.inlining(o) && !D.minify(o) && !D.unique_types(o) && !D.omit_error_details(o)
    @test !D.omit_implicit_type_checks(o) && !D.omit_bounds_checks(o)
    local o4 = O(optimization_level = 4, minify_override = false)
    @test !D.minify(o4) && D.omit_bounds_checks(o4) && D.omit_error_details(o4) && D.unique_types(o4)
    @test !D.inlining(O(inlining_override = false))
end

module TranslatorCases
f_add(a::Int, b::Int) = a + b
end

@testset "translator.dart: the Translator, its queue and writeULEB128" begin
    local W = WasmTarget
    local t = D.Translator(W.check_subset(TranslatorCases.f_add, (Int, Int), "translator"), D.TranslatorOptions(standalone = true))
    # the program is the closed world's NIR, the entry's body among it
    @test t.component isa Vector{W.NirBody} && !isempty(t.component)
    @test D.is_standalone(t) && !D.is_standalone(D.Translator(t.component, D.TranslatorOptions()))
    # the constructor's body builds the queue over the translator; drained empty, it does nothing
    local q = t.compilation_queue[]
    @test q.translator === t && D.is_empty(q)
    @test D.drain_completion_queue(t) === nothing && D.is_empty(q)
    local e = try; D.pop(q); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
    # ULEB128, decoded by Julia's arithmetic: seven bits a byte, low first, the high bit continuing
    local uleb(v) = (io = IOBuffer(); D.write_uleb128(io, v); take!(io))
    local decode(bs) = sum(Int(b & 0x7f) << (7 * (k - 1)) for (k, b) in enumerate(bs))
    for v in Int64[0, 1, 127, 128, 255, 300, 16383, 16384, 2^35 + 11, typemax(Int64)]
        local bs = uleb(v)
        @test decode(bs) == v && all(b -> b & 0x80 != 0, bs[1:end-1]) && bs[end] & 0x80 == 0
        @test length(bs) == max(1, cld(64 - leading_zeros(v), 7))
    end
    @test uleb(624485) == UInt8[0xe5, 0x8e, 0x26]   # the LEB128 article's worked example
    local e2 = try; uleb(-1); nothing; catch x; x; end
    @test e2 isa W.RejectionError && e2.rejection isa W.Internal
end

@testset "translator.dart: translateStorageType's located rejections" begin
    local W = WasmTarget
    local t = D.Translator(W.check_subset(TranslatorCases.f_add, (Int, Int), "translator"), D.TranslatorOptions())
    # a UnionAll and a type as a value of a type Julia left open are no class: located rejections,
    # before any wasm type is made
    for ty in (Vector, Type{T} where T, AbstractVector{<:Integer})
        local e = try; D.translate_storage_type(t, ty); nothing; catch x; x; end
        @test e isa W.RejectionError && e.rejection isa W.Unquarantined
    end
    local e = try; D.translate_type(t, Base.unwrap_unionall(Type{T} where T)); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Unquarantined && occursin("type as a value", e.rejection.row)
    # the late top type and builtin types, read before collect, the classes unassigned
    local e2 = try; t.top_type[]; nothing; catch x; x; end
    @test e2 isa W.RejectionError && e2.rejection isa W.Unported && occursin("Translator.classes", e2.rejection.anchor)
end
