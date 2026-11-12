# String's operations against native Julia (the String ruling, src/julia/classes.jl
# _string_instance_fields; its operations by overlay over dart:_wasm's array operations,
# src/julia/wasm_array.jl): code unit reads, length against ncodeunits on non-ASCII text, == and
# concatenation. Every case compiles and answers as native Julia, both modules: a case that rejects
# or answers wrong fails, named.
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module StringOpCases
cu(i::Int64) = UInt32(codeunit("héllo", i))                          # the code unit at a byte index
lens(b::Bool) = (s = b ? "héllo" : "日本"; Int64(length(s)) * 100 + ncodeunits(s))   # characters against bytes
eq(b::Bool) = (b ? "abc" : "abd") == "abc"                            # ==, Julia's egal on two Strings
cat3(b::Bool) = UInt32(codeunit((b ? "hé" : "x") * "llo", 4))       # a code unit of a concatenation
# string(::Int): Base.dec's StringMemory over a fresh String (jl_string_to_genericmemory), its digits
# written, then taken as the String (jl_genericmemory_to_string); its length and its first and last bytes
dec(n::Int64) = (s = string(n); Int64(ncodeunits(s)) * 1_000_000 + Int64(codeunit(s, 1)) * 1000 + Int64(codeunit(s, ncodeunits(s))))
# string of a String, a SubString of one and an Int (Base.print_to_string): each String written into
# the IOBuffer (src/patch/io.jl), its length and a byte of each part
pts(n::Int64) = (s = string("hé", SubString("xyzw", 2, 3), n); Int64(ncodeunits(s)) * 1_000_000 + Int64(codeunit(s, 2)) * 1000 + Int64(codeunit(s, 5)))
# cmp and == of Strings and SubStrings of them (Base._memcmp over the data arrays, src/patch/string.jl),
# each sign and a prefix's, and the search of a byte (Base._search), found and missed
cmps(n::Int64) = cmp(n > 0 ? "abc" : "x", "abd") * 1000 + cmp("abd", SubString(n > 0 ? "zabc" : "zx", 2)) * 100 +
    cmp(n > 0 ? "ab" : "abc", "abc") * 10 + Int64(SubString("xabé", 2) == (n > 0 ? "abé" : "abe"))
fnd(n::Int64) = something(findfirst(==('l'), n > 0 ? "héllo" : "xyz"), 0) * 100 + something(findnext(==(','), SubString(n > 0 ? "a,b,c" : "abc", 2), 2), 0)
# Base._memcmp's own value, the first differing bytes' difference as memcmp's on this host, a SubString operand and a byte past ASCII
mc(n::Int64) = Base._memcmp(n > 0 ? "abc" : "abd", SubString("xaxc", 2), 3) * 1000 + Base._memcmp("a\xff", n > 0 ? "a\x01" : "a\xff", 2)
# a String and a SubString{String} written into an IOBuffer (src/patch/io.jl), at its end and over a seeked
# position: each write's count, the buffer's size and position and a byte of its data
iow(n::Int64) = (io = IOBuffer(); w1 = write(io, n > 0 ? "hé" : "x"); w2 = write(io, SubString("xyzw", 2, 3)); seek(io, 1);
    w3 = write(io, "Q"); Int64(w1) * 10^7 + Int64(w2) * 10^6 + Int64(w3) * 10^5 + Int64(io.size) * 10^4 + Int64(position(io)) * 10^3 + Int64(io.data[2]))
# an append buffer over existing bytes: the write lands after them, its position unmoved
ioa(n::Int64) = (io = IOBuffer(UInt8[0x61, 0x62]; read = true, write = true, append = true); w = write(io, n > 0 ? SubString("xcd", 2) : "c");
    Int64(w) * 10^6 + Int64(io.size) * 10^4 + Int64(position(io)) * 10^3 + Int64(io.data[3]))
# String(::Vector{UInt8}): a Vector at its memory's start taken as the String (jl_genericmemory_to_string),
# one past it after popfirst! copied (jl_pchar_to_string); its length, its first byte, and the Vector left empty
vstr(n::Int64) = (v = UInt8[0x61, 0x62, 0x63, 0x64]; n > 1 && popfirst!(v); s = String(v); Int64(ncodeunits(s)) * 1000 + Int64(codeunit(s, 1)) * 10 + length(v))
# getindex of a String at a UnitRange (first, last, an empty range): the range's bytes copied into a fresh
# String (src/patch/string.jl); each length, the last byte of the first, and its equality with a literal
rng(n::Int64) = (s = n > 3 ? "héllo" : "abc"; a = first(s, n); b = last(s, n); c = s[2:1];
    Int64(ncodeunits(a)) * 10^5 + Int64(ncodeunits(b)) * 10^4 + ncodeunits(c) * 1000 + Int64(codeunit(a, ncodeunits(a))) + Int64(a == "hé") * 10^6)
end

const STRING_OP_CASES = (
    ("cu", StringOpCases.cu, (Int64(3),)), ("cu", StringOpCases.cu, (Int64(1),)),
    ("lens", StringOpCases.lens, (true,)), ("lens", StringOpCases.lens, (false,)),
    ("eq", StringOpCases.eq, (true,)), ("eq", StringOpCases.eq, (false,)),
    ("cat3", StringOpCases.cat3, (true,)), ("cat3", StringOpCases.cat3, (false,)),
    ("pts", StringOpCases.pts, (Int64(7),)), ("pts", StringOpCases.pts, (Int64(-12345),)),
    ("cmps", StringOpCases.cmps, (Int64(1),)), ("cmps", StringOpCases.cmps, (Int64(0),)),
    ("fnd", StringOpCases.fnd, (Int64(1),)), ("fnd", StringOpCases.fnd, (Int64(0),)),
    ("mc", StringOpCases.mc, (Int64(1),)), ("mc", StringOpCases.mc, (Int64(0),)),
    ("iow", StringOpCases.iow, (Int64(1),)), ("iow", StringOpCases.iow, (Int64(0),)),
    ("ioa", StringOpCases.ioa, (Int64(1),)), ("ioa", StringOpCases.ioa, (Int64(0),)),
    ("vstr", StringOpCases.vstr, (Int64(1),)), ("vstr", StringOpCases.vstr, (Int64(2),)),
    ("rng", StringOpCases.rng, (Int64(2),)), ("rng", StringOpCases.rng, (Int64(4),)), ("rng", StringOpCases.rng, (Int64(10),)))

@testset "String's operations against native Julia" begin
    local runs = Main.WTChild.RunCase[]
    for (name, f, args) in STRING_OP_CASES
        local label = "string_ops/$name$args"
        # every case compiles, both modules: a rejection is this case's located error, never a pass
        @testset "$label compiles" begin
            append!(runs, first(Main.WTChild.answer_cases(label, WasmTarget.compile, f, args)))
        end
    end
    for r in Main.WTChild.run_cases(runs)
        @test (r.label => r.why) == (r.label => "")
    end
end

# each String operation reaches dart:_wasm's array operations through src/patch/string.jl's overlays,
# never Base's pointer forms: its closed world calls the operation on the String's data
@testset "String's operations reach its data through the overlays" begin
    local reached(f, T) = Set{Symbol}(Core.Compiler.get_ci_mi(x).def.name for x in WasmTarget.check_subset(f, T, "string_ops", Base.get_world_counter()).codeinfos
                                      if x isa Core.CodeInstance)
    @test :wasm_string_codeunit in reached(StringOpCases.cu, (Int64,))
    @test :wasm_string_length in reached(StringOpCases.lens, (Bool,))
    @test [:wasm_string_alloc, :wasm_string_copy!] ⊆ reached(StringOpCases.cat3, (Bool,))
    @test [:wasm_string_memory, :wasm_memory_string] ⊆ reached(StringOpCases.dec, (Int64,))
    @test :wasm_string_memory in reached(StringOpCases.pts, (Int64,))
    @test :wasm_string_codeunit in reached(StringOpCases.cmps, (Int64,))
    @test :wasm_string_codeunit in reached(StringOpCases.fnd, (Int64,))
    @test [:wasm_memory_string, :wasm_string_alloc, :wasm_string_memory, :wasm_memory_copy!] ⊆ reached(StringOpCases.vstr, (Int64,))
    @test [:wasm_string_alloc, :wasm_string_copy!] ⊆ reached(StringOpCases.rng, (Int64,))
end

# string(::Int) answers as native Julia, every sign and width: Base's own dec over the overlays of
# unsafe_wrap(Memory{UInt8}, ::String) and unsafe_takestring, its DomainError path's throw_methoderror
# raised through the runtime
@testset "string(::Int) against native Julia" begin
    local bytes = WasmTarget.compile(StringOpCases.dec, (Int64,))
    local args = Int64[0, 7, -42, 1000, typemax(Int64), typemin(Int64)]
    local results = Main.WTChild.run_cases([Main.WTChild.RunCase("dec($n)", bytes, (n,), Main.WTChild.native_answer(StringOpCases.dec, (n,))) for n in args])
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == length(args) && all(r -> r.ok, results)
end
