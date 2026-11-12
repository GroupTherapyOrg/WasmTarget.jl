# test/oracle_read.jl, the store's decoder, against test/oracle.jl, the capture's writer (spec v14 V2): an answer
# written as records and read back holds the same facts; a type path is found by lookups alone. A judge's test file:
# no move's rule admits it (dev/climb/core.py MOVE_RULES), as no move's rule admits the two files it tests.
using Test
isdefined(Main, :WTOracle) || Base.include(Main, joinpath(@__DIR__, "..", "oracle.jl"))
isdefined(Main, :WTOracleRead) || Base.include(Main, joinpath(@__DIR__, "..", "oracle_read.jl"))
const WO = Main.WTOracle
const WR = Main.WTOracleRead

# test/oracle.jl's capture, the store's one format: an answer written as records and read back holds the same facts,
# its values the stand-ins the comparing process reads; a type named by its structure is found again by lookups alone
struct _OracleSingleton end
struct _OracleShown end
Base.show(io::IO, ::Type{_OracleShown}) = print(io, "Int64")   # a corpus show of its own type: no path reads it
module _OracleM
struct A end
const B = Int64
end
@testset "an answer round-trips through the store's records; a type path is found by lookups alone" begin
    # a value read back: itself (its capture the same), or, for a value the store holds by its type alone (a tuple, an
    # Int16 inside a struct), the opaque stand-in of that type's name
    local same(w, v) = WO._capture(w) == WO._capture(v) ||
        (v isa WR.Opaque{typeof(w).name.name} && !isprimitivetype(typeof(w)) && !Base.issingletontype(typeof(w)))
    local trip(a) = WR.read_answers(WO.answer_lines("g/c", a))["g/c"]
    for (f, args) in (((x::Int64) -> "ab" * string(x), (Int64(3),)),               # a String
                      ((x::Int64) -> Int64[x, 2x, 3x], (Int64(2),)),              # a Vector
                      ((x::Int64) -> ((x, 1.5), (true, 'c', 0x07)), (Int64(1),)), # a nested tuple
                      ((x::Int64) -> (x, _OracleSingleton()), (Int64(4),)),       # a corpus singleton
                      ((x::Int64) -> error("no"), (Int64(1),)),                    # Throws
                      ((x::Int64) -> (x, Int16(3)), (Int64(5),)),                 # a leaf no wire carries yet: its bytes
                      ((x::Int64) -> (x, Int64[x]), (Int64(5),)),                 # a vector inside a tuple
                      ((s::String, x::Int64) -> (s, x), ("hé", Int64(6))))         # a String argument bound
        local a = WO.answer_of("", f, args)
        local b = trip(a)
        @test b isa WO.Answer
        @test (b.label, b.P, b.S, b.key, b.rkey, b.aggregate) == (a.label, a.P, a.S, a.key, a.rkey, a.aggregate)
        @test same(a.native, b.native) && length(b.args) == length(a.args) && all(same.(a.args, b.args))
        @test [(g.tpath, g.on_string, g.paths) for g in b.groups] == [(g.tpath, g.on_string, g.paths) for g in a.groups]
        @test all(all(same.(ga.leaves, gb.leaves)) for (gb, ga) in zip(b.groups, a.groups))
        # a leaf of a primitive type or a singleton this process holds reads back as itself (===): a marshaling a keeper
        # adds to the runner reads stored answers as they are
        @test all(v === w for (gb, ga) in zip(b.groups, a.groups) for (v, w) in zip(gb.leaves, ga.leaves)
                  if isprimitivetype(typeof(w)) || Base.issingletontype(typeof(w)))
    end
    @test WO.answer_of("", (x::Int64) -> error("no"), (Int64(1),)).native isa WO.Throws
    @test trip(WO.answer_of("", (x::Int64) -> error("no"), (Int64(1),))).native.type === ErrorException
    # a type no process holds by its path (the corpus's, read where no corpus is loaded) reads as a stand-in
    local gone = "void," * WO._b64("T " * WO._b64("Main") * " " * WO._b64("_NotHere") * " 0") * ",-"
    @test WR._restore(gone) === WR.Named{:_NotHere}() && WR._restore(replace(gone, "void" => "opaque")) isa WR.Opaque{:_NotHere}
    @test trip(WO.answer_of("", (s::String, x::Int64) -> (s, x), ("hé", Int64(6)))).label == "(String argument 1 bound)"
    # a record cut short, or one naming another case inside a block, is that case's located refusal, never an answer
    local ls = WO.answer_lines("g/c", WO.answer_of("", (x::Int64) -> (x, 2x), (Int64(1),)))
    @test WR.read_answers(ls[1:end-1])["g/c"] isa String
    @test WR.read_answers([ls[1]; replace(ls[2], "g/c" => "g/d"); ls[3:end]])["g/c"] isa String
    @test WR.read_answers([ls; ls])["g/c"] == "the answers name it more than once"
    @test WR.read_answers(["noanswer\tg/c\t" * WO._b64("boom")])["g/c"] == "no native answer: boom"
    # a type path: field access out, lookups in, the type found checked to be the one named
    for T in (Int64, Nothing, _OracleSingleton, Val{3}, Val{:a}, Val{true}, Tuple{Int64,Float64}, _OracleM.A, Vector{Int64})
        @test WR.resolve_type_path(WO.type_path(T)) === T
    end
    # a corpus show of its own type names nothing: the path reads its structure (a parse of what show prints finds Int64)
    @test WR.resolve_type_path(WO.type_path(_OracleShown)) === _OracleShown && sprint(show, _OracleShown) == "Int64"
    # a name bound to another type than the one the path names is refused: _OracleM.B is Int64, not a type named B
    local m = join(WO._b64.(String.(fullname(_OracleM))), '.')
    @test WR.resolve_type_path("T $m $(WO._b64("A")) 0") === _OracleM.A
    @test_throws WR.TypePathError WR.resolve_type_path("T $m $(WO._b64("B")) 0")
    @test_throws WR.TypePathError WR.resolve_type_path("T $m $(WO._b64("_NoSuchType")) 0")
end

# ---- spec v14 V4: one wholeness rule, two readers. test/src/oracle_edge_blocks.tsv's cases (written by test/oracle.jl's
# own writer: whole, short, foreign, a record after the digest or the noanswer, two digests, a digest before the leaves,
# a case named twice, an oversized count, an append cut short) are each read alone by read_answers here and by
# dev/climb/measure.py's unit_blocks in climb.py door-probe's reader rows; both must give the case's verdict for e/a
function _edge_cases(path::AbstractString)
    local out, cur = Tuple{String,String,Vector{String}}[], nothing
    for l in eachline(path)
        startswith(l, '#') && continue
        local f = split(l, '\t')
        if f[1] == "case"
            cur = (String(f[2]), String(f[3]), String[]); push!(out, cur)
        else
            push!(cur[3], l)
        end
    end
    return out
end
@testset "the store's edge blocks read by read_answers: unit_blocks' verdict on each (spec v14 V4)" begin
    local cases = _edge_cases(joinpath(@__DIR__, "oracle_edge_blocks.tsv"))
    @test length(cases) == 13
    for (name, verdict, lines) in cases
        local data = join(lines, '\n') * (name == "cut" ? "" : "\n")
        local r = get(WR.read_answers(eachline(IOBuffer(data))), "e/a", nothing)
        local got = r isa WO.Answer || r isa String && startswith(r, "no native answer") ? "whole" :
                    r isa String && occursin("more than once", r) ? "refused" : "dropped"
        got == verdict || println("oracle_edge_blocks: ", name, " read as ", got, " (", r, "), not ", verdict)
        @test got == verdict
    end
end
