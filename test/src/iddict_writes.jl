# Base's IdDict written, popped, rehashed and walked over iddict.c's port (src/julia/runtime/iddict.jl), called
# by Base's own bodies by overlay (src/patch/iddict.jl): setindex! (jl_eqtable_put, jl_table_assign_bp and the
# growth's jl_idtable_rehash), pop! and delete! (jl_eqtable_pop), the ndel rehash! of setindex!, get! (both) and
# the Callable get, and iterate's _oidd_nextind (jl_eqtable_nextind). Each table's values are Any: Base's
# setindex!(d, @nospecialize(val), @nospecialize(key)) converts a value that is not a V (julia/base/iddict.jl:78
# `convert(V, val)::V`), a call Julia's verifier leaves unresolved where V is concrete (test/src/iddict.jl); with
# V = Any `val isa V` is true and inference folds the convert away. Each key is an Int64 or `nothing`, whose id is a
# function of its content (julia/src/builtins.c:412 immut_id_), so the module lays a table out as native Julia
# does: an answer folding the walk order (iterate) or a slot index (_oidd_nextind) is native's only where every
# put, pop, rehash and probe chose native's slot. Each case's answer is native Julia's, compared in both modules.
# formal(dev/formal/IdTable.tla): LookupAgrees, OneSlotPerKey, NextindVisitsMap, CountAgrees
module IdDictWritesTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module IdDictWritesCases
# 40 puts into a table of 16 pairs grow it (jl_table_assign_bp's full arm, jl_idtable_rehash); every other key
# popped (pop!'s found arm, its value returned), a missing key's pop! with a default and without (KeyError), a
# live key's value overwritten (inserted 0), and each key read past the deleted slots its probe meets
function puts_pops(x::Int64)::Int64
    local d = IdDict{Int64,Any}()
    for k in 1:40
        d[k] = k * x
    end
    local s = 0
    for k in 1:2:40
        s += pop!(d, k)::Int64
    end
    s += pop!(d, 1, -7)::Int64
    s += (try; pop!(d, 3)::Int64; catch e; e isa KeyError ? -100 : -200; end)
    d[2] = -5
    for k in 1:40
        s += get(d, k, -1)::Int64 * k
    end
    return s + length(d) * 1_000_000 + length(d.ht) * 100_000_000
end

# a walk past deleted slots: iterate's _oidd_nextind skips each slot delete! left (key `nothing`, value never
# assigned); the walk order folded, so the answer is native's only where the module's table is native's slot by slot
function walk(x::Int64)::Int64
    local d = IdDict{Int64,Any}()
    for k in 1:x
        d[k * 7] = k
    end
    for k in 2:3:x
        delete!(d, k * 7)
    end
    local acc = 0
    for (k, v) in d
        acc = acc * 31 + k * (v::Int64)
    end
    # an odd index starts the walk at the next pair (iddict.c:186)
    return acc + Base._oidd_nextind(d.ht, 1) - Base._oidd_nextind(d.ht, 0)
end

# setindex!'s rehash!: puts and pops of distinct keys until ndel reaches 3/4 of the table's slots, so the next put
# rehashes it at half its size, at least 32 (julia/base/iddict.jl:81), and resets ndel
function churn(x::Int64)::Int64
    local d = IdDict{Int64,Any}()
    for r in 1:3
        for k in 1:10
            d[r * 100 + k] = k
        end
        for k in 1:10
            pop!(d, r * 100 + k)
        end
    end
    local before = d.ndel
    d[x] = x
    return before * 1_000_000 + d.ndel * 10_000 + length(d.ht) * 100 + length(d) + get(d, x, -1)::Int64
end

# `nothing` is the deletion sentinel (iddict.c:122): a live `nothing` key placed past another key at its own home
# index stays found once that key is popped, its slot then deleted with key `nothing` (the probe goes on past it,
# where a probe for any other key ends); NOTHING_MATE is an Int64 whose home in a table of 16 pairs is nothing's
const NOTHING_MATE = first(a for a in Int64(1):Int64(10_000) if objectid(a) & 15 == objectid(nothing) & 15)
function nothing_past_deleted(x::Int64)::Int64
    local d = IdDict{Union{Nothing,Int64},Any}()
    d[NOTHING_MATE] = 1
    d[nothing] = x
    pop!(d, NOTHING_MATE)
    local found = get(d, nothing, -1)::Int64
    local at = Base._oidd_nextind(d.ht, 0)
    local popped = pop!(d, nothing, -2)::Int64
    local gone = get(d, nothing, -3)::Int64
    d[nothing] = x + 1
    return found * 1_000_000 + at * 10_000 + popped * 100 + gone + get(d, nothing, -4)::Int64 * 10_000_000 +
        Base._oidd_nextind(d.ht, 0) * 1_000_000_000
end

# the growth arms (iddict.c:94): a table of up to 2^8 slots doubles, one past it quadruples, and past 1024 pairs
# the probe bound is size >> 6 (max_probe); a rehash! to no slots re-puts each live pair into an empty table,
# which jl_table_assign_bp makes HT_N_INLINE slots (iddict.c:42), and sizehint! rehashes to _tablesz of twice its
# argument (julia/base/iddict.jl:66)
function grow(x::Int64)::Int64
    local d = IdDict{Int64,Any}()
    for k in 1:x
        d[k] = k
    end
    local s = length(d.ht) + length(d) * 100_000
    for k in 1:x
        s += get(d, k, 0)::Int64
    end
    local e = IdDict{Int64,Any}()
    e[x] = 1
    e[x + 1] = 2
    Base.rehash!(e, 0)
    s += length(e.ht) * 10_000_000 + get(e, x, 0)::Int64 * 100_000_000 + get(e, x + 1, 0)::Int64 * 1_000_000_000
    sizehint!(e, 100)
    return s + length(e.ht) * 10_000_000_000 + get(e, x + 1, 0)::Int64 * 10_000_000_000_000
end

# get! of a value and of a Callable: the absent key's default stored by setindex!, the present key's value read;
# the Callable get's absent key
function get_bang(x::Int64)::Int64
    local d = IdDict{Int64,Any}()
    local a = get!(d, 1, x)::Int64
    local b = get!(d, 1, 0)::Int64
    local c = get!(() -> x * 2, d, 2)::Int64
    local e = get!(() -> 0, d, 2)::Int64
    local f = get(() -> -5, d, 3)::Int64
    # a key that is not a K: Base's setindex! throws KeyTypeError's TypeError before any put
    local g = try; setindex!(d, 1, "k"); 0; catch err; err isa TypeError ? 7 : 8; end
    return a + 10 * b + 100 * c + 1000 * e + 10_000 * f + length(d) * 100_000 + g * 1_000_000
end
end

const IC = IdDictWritesCases

@testset "IdDict writes, pops, rehashes and walks over iddict.c's port" begin
    # the layout each case is named for, natively: nothing's slot follows NOTHING_MATE's deleted one, churn's last
    # put rehashed, and grow's table quadrupled
    let d = IdDict{Union{Nothing,Int64},Any}()
        d[IC.NOTHING_MATE] = 1
        d[nothing] = 5
        pop!(d, IC.NOTHING_MATE)
        local h = Int(objectid(nothing) & 15) * 2
        @test d.ht[h + 1] === nothing && !isassigned(d.ht, h + 2) && d.ht[h + 3] === nothing && d.ht[h + 4] === 5
    end
    @test IC.churn(Int64(5)) ÷ 1_000_000 >= 24 && (IC.churn(Int64(5)) ÷ 10_000) % 100 == 0
    # 1500 puts double the table to 512 slots, quadruple it to 2048 (never 1024), and again past 1024 pairs
    let d = IdDict{Int64,Any}(), seen = Int[]
        for k in 1:1500
            d[k] = k
            length(d.ht) in seen || push!(seen, length(d.ht))
        end
        @test 512 in seen && 2048 in seen && !(1024 in seen) && length(d.ht) > 2048
    end
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((IC.puts_pops, (3,)), (IC.walk, (12, 30)), (IC.churn, (5,)), (IC.nothing_past_deleted, (9,)),
                    (IC.get_bang, (4,)), (IC.grow, (600, 1500)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("iddict_writes/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
