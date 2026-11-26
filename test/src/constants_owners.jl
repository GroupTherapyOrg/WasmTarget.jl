# dart2wasm's constants.dart, ported (src/constants.jl): the constants whose memory their owners define, a Dict's and an
# Array's, and the constants' counter, each module run against native Julia (split from test/src/constants_objects.jl,
# every testset verbatim; its other parts are test/src/constants_module.jl and test/src/constants_large_arrays.jl).

module ConstantOwners
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild

# spec v15 W3: a Dict constant's unfilled slots hold no defined element, so its module is a function of its live pairs
# alone: one function over one Dict constant compiled, then the bytes in the Dict's unfilled `vals` slots changed (as a
# process's heap leaves them, addresses among them: v14/v7/dictvals2.out), then compiled again: byte-identical modules
const _DICT_CONST = Dict("a" => 1, "bb" => 2, "ccc" => 3)
_dict_const_bb() = _DICT_CONST["bb"]
@testset "a Dict constant's unfilled slots: its live elements alone (spec v15 W3)" begin
    local before = WasmTarget.compile(_dict_const_bb, ())
    local before_plain = WasmTarget.compile(_dict_const_bb, (); optimize = false)
    local dead = [i for i in eachindex(_DICT_CONST.vals) if !Base.isslotfilled(_DICT_CONST, i)]
    @test !isempty(dead)
    for i in dead
        _DICT_CONST.vals[i] = 4_650_992_688 + i   # heap bytes, an address among them
    end
    @test WasmTarget.compile(_dict_const_bb, ()) == before
    @test WasmTarget.compile(_dict_const_bb, (); optimize = false) == before_plain
    local results = Main.WTChild.run_cases([Main.WTChild.RunCase("dict_const_bb", before, (), _dict_const_bb())])
    @test all(r -> r.ok, results)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
end

# an isbits union's memory Julia always allocates zeroed (datatype.c:551 zi = 1, genericmemory.c:71 memset), so a Dict
# constant's unfilled slots of an isbits-union key type hold the value a zeroed allocation reads: its module is a
# function of its live pairs alone, the dead keys rewritten (as a delete! leaves the deleted key) byte-identical
const _DICT_UNION_CONST = Dict{Union{Int64,Float64},String}(1 => "a", 2 => "b", 3 => "c")
_dict_union_const(x::Int64) = Int64(_DICT_UNION_CONST == Dict{Union{Int64,Float64},String}(x => "a", 2 => "b", 3 => "c"))
@testset "a Dict constant of an isbits-union key: its unfilled slots are a zeroed allocation's" begin
    @test (Memory{Union{Int64,Float64}}.flags & 0x0010) == 0x0010   # julia.h:619 zeroinit
    local before = WasmTarget.compile(_dict_union_const, (Int64,))
    local dead = [i for i in eachindex(_DICT_UNION_CONST.keys) if !Base.isslotfilled(_DICT_UNION_CONST, i)]
    @test !isempty(dead)
    for i in dead
        _DICT_UNION_CONST.keys[i] = isodd(i) ? 7.5 : Int64(4_650_992_688 + i)
    end
    @test WasmTarget.compile(_dict_union_const, (Int64,)) == before
    local results = Main.WTChild.run_cases([Main.WTChild.RunCase("dict_union_const $x", before, (x,), _dict_union_const(x)) for x in (Int64(1), Int64(5))])
    @test all(r -> r.ok, results)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
end

# spec v16 X5: the constants' `C<id>` names are the compile's (a Translator field), so a module's bytes, its name section
# among them, are the same whatever the process compiled before it
_counter_g(x::Int64) = string(x) * "!"
@testset "a module's bytes are its own compile's: the constants' counter is the translator's" begin
    local first_ = WasmTarget.compile(_dict_const_bb, ())
    WasmTarget.compile(_counter_g, (Int64,))   # another program, its own constants named
    @test WasmTarget.compile(_dict_const_bb, ()) == first_
end

# spec v17 Y6: a constant's memory is its owner's to define (src/julia/classes.jl MEMORY_OWNERS: an Array's size, a Dict's
# filled slots); an isbits memory reached through no owner (a bare Memory, IOBuffer's data) is refused, located, never
# emitted with every element's bytes; an empty one, and a boxed one (#undef the null), are held whole
const _BARE_BITS = let m = Memory{Int64}(undef, 3); m[1] = 1; m[3] = 3; m end   # its second element: whatever bytes
_bare_bits(i::Int64) = _BARE_BITS[i]
const _BUFFER = IOBuffer(UInt8[0x61, 0x62])
_buffer(i::Int64) = Int64(_BUFFER.data[i])
const _BARE_EMPTY = Memory{Int64}(undef, 0)
_bare_empty(i::Int64) = Int64(length(_BARE_EMPTY)) + i
@testset "a constant's isbits memory is its owner's to define, else refused, located (spec v17 Y6)" begin
    local refusal(f) = try; WasmTarget.compile(f, (Int64,)); nothing; catch x; x isa WasmTarget.RejectionError ? x.rejection : rethrow(); end
    for f in (_bare_bits, _buffer)
        local r = refusal(f)
        @test r isa WasmTarget.ProgramError && occursin("reached through no owner MEMORY_OWNERS lists", r.text)
    end
    @test refusal(_bare_empty) === nothing
    @test WasmTarget.MEMORY_OWNERS isa Tuple && all(o -> o[1] isa Type && o[2] isa String, WasmTarget.MEMORY_OWNERS)
end

# spec v16 X5: an Array constant's memory past its size (a capacity tail sizehint! reserved, the bytes pop! left for an
# isbits element) holds no defined element: the module carries its size's elements alone, whatever the tail holds
const _VEC_TAIL = let v = UInt64[11, 22, 33]; sizehint!(v, 16); push!(v, 0x0123456789abcdef); pop!(v); v end
_vec_tail(i::Int64) = _VEC_TAIL[i] + UInt64(length(_VEC_TAIL))
const _VEC_SHARED = UInt64[1, 2, 3, 4]
const _VEC_PART = Base.wrap(Array, getfield(_VEC_SHARED, :ref).mem, (2,))   # its first two elements, the same memory
_vec_shared(i::Int64) = _VEC_SHARED[i] + _VEC_PART[1]
const _VEC_TAIL2 = let v = UInt64[5, 6]; sizehint!(v, 8); v end
const _VEC_ALIAS = Base.wrap(Array, getfield(_VEC_TAIL2, :ref).mem, (2,))   # the same memory, the same size
_vec_alias(i::Int64) = (_VEC_ALIAS[1] = UInt64(i); _VEC_TAIL2[1])
@testset "an Array constant's memory past its size: its size's elements alone (spec v16 X5)" begin
    local mem = getfield(_VEC_TAIL, :ref).mem
    @test length(mem) >= 16 && mem[4] == 0x0123456789abcdef   # the popped element's bytes, in the tail
    local before = WasmTarget.compile(_vec_tail, (Int64,))
    for k in 4:length(mem)
        mem[k] = 0x5a5a5a5a00000000 + UInt64(k)   # the tail as another process's heap leaves it
    end
    @test WasmTarget.compile(_vec_tail, (Int64,)) == before
    @test all(r -> r.ok, Main.WTChild.run_cases([Main.WTChild.RunCase("vec_tail$i", before, (Int64(i),), _vec_tail(Int64(i))) for i in 1:3]))
    # two Arrays of one Memory and different sizes: one constant cannot hold each one's elements, refused, located
    local refused = try; WasmTarget.compile(_vec_shared, (Int64,)); nothing; catch x; x isa WasmTarget.RejectionError ? x.rejection : rethrow(); end
    @test refused isa WasmTarget.ProgramError && occursin("one constant cannot hold", refused.text)
    # two of one Memory and one size share its one copy: a write through one is read through the other, as natively
    local alias = WasmTarget.compile(_vec_alias, (Int64,))
    @test all(r -> r.ok, Main.WTChild.run_cases([Main.WTChild.RunCase("vec_alias", alias, (Int64(9),), Int64(9))]))
end
end
