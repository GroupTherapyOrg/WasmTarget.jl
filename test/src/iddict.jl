# Base's IdDict over Julia's identity table (julia/src/iddict.c), its C ported (src/julia/runtime/iddict.jl) and
# called by Base's own IdDict bodies by overlay (src/patch/iddict.jl): an image constant keyed by an identity, read
# by jl_eqtable_get (get, getindex, haskey, a missing key's KeyError). Each case's answer is native Julia's,
# compared in both modules. A write of a concrete V is outside the strict subset at Base's own setindex! (a convert of a
# value it leaves Any); one of V = Any folds that convert away: test/src/iddict_writes.jl writes, pops and walks.
# formal(dev/formal/IdTable.tla): LookupAgrees, CountAgrees
module IdDictTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module IdDictCases
# an image constant keyed by identities and contents: its table laid out by the compiling process's ids, read by
# jl_eqtable_get (get, getindex, haskey) and its count read (length)
const KR = Base.RefValue{Int64}(5)
const CR = IdDict{Base.RefValue{Int64},Int64}(KR => 9)
image_identity(x::Int64)::Int64 = get(CR, KR, -1) * 10 + get(CR, Base.RefValue{Int64}(x), -1)
image_reads(x::Int64)::Int64 = get(CR, KR, -1) + (haskey(CR, KR) ? 100 : 0) + length(CR) * 1000 +
    (try; CR[Base.RefValue{Int64}(x)]; catch e; e isa KeyError ? -10000 : -20000; end)
# a write: Base's setindex!(d, @nospecialize(val), key) converts a value it left Any (julia/base/iddict.jl:77
# `convert(V, val)::V`), a call Julia's verifier leaves unresolved: outside the strict subset
function string_key(x::Int64)::Int64
    local d = IdDict{String,Int64}()
    d["ab"] = 7
    return get(d, string('a', Char(x)), -1)
end
end

const IC = IdDictCases

@testset "IdDict over Julia's identity table, iddict.c ported" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((IC.image_identity, (5,)), (IC.image_reads, (5, 6)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("iddict/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
    # a write is outside the strict subset at Base's own convert, Julia's verifier's answer, located
    local e = try; WasmTarget.compile(IC.string_key, (Int64,)); nothing; catch x; x; end
    @test (e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.OutsideSubset &&
           occursin("convert(Int64, val::Any)", sprint(showerror, e))) || (@info "string_key" e === nothing ? "compiled" : sprint(showerror, e); false)
end

end # module
