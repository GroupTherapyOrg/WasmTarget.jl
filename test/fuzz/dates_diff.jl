# ============================================================================
# Differential fuzz of the Dates stdlib VALUE layer.
# ============================================================================
# The catalogue generator produces scalars/vectors but not Date/DateTime values,
# so the Dates value surface is verified HERE by direct `bridge_run_args`
# differential sweeps (same bit-exact oracle as the catalogue fuzzer, over
# deterministic random Date/DateTime inputs). Mirrors linalg_diff.jl.
#
# Loaded by fuzz_suite.jl AFTER fuzz/run.jl. Entry: run_dates_tests().
# Exports DATES_VERIFIED (the tested-name set) for stdlib_coverage.jl.

using Dates
using Random
using Test

const _DT_B = WasmTarget.Bridge

function _dt_diff(fn, argTs::Tuple, inputs::Vector, rettype)
    res = bridge_run_args(fn, argTs, inputs; rettype = rettype)
    res isa Vector || return false
    rdesc = _DT_B.descriptor(rettype)[1]
    for (i, r) in enumerate(res)
        a = inputs[i]
        nat = try (true, fn(a...)) catch; (false, nothing) end
        ok = r[1] === :ok ? (nat[1] && _DT_B.tree_matches(rdesc, nat[2], r[2])) : !nat[1]
        ok || return false
    end
    return true
end

_rdate(rng) = Date(rand(rng, 1850:2200), rand(rng, 1:12), rand(rng, 1:28))
_rdt(rng)   = DateTime(rand(rng, 1850:2200), rand(rng, 1:12), rand(rng, 1:28),
                       rand(rng, 0:23), rand(rng, 0:59), rand(rng, 0:59), rand(rng, 0:999))

# Date/DateTime → Int64 accessors
const _DT_INT = [year, month, day, dayofweek, dayofmonth, dayofyear, dayofquarter,
                 dayofweekofmonth, daysofweekinmonth, week, daysinmonth, daysinyear,
                 quarterofyear]
# Date → Date adjusters
const _DT_DATE = [firstdayofmonth, lastdayofmonth, firstdayofweek, lastdayofweek,
                  firstdayofquarter, lastdayofquarter, firstdayofyear, lastdayofyear]
# DateTime → Int64 (time accessors + the date ones)
const _DT_TIME = [hour, minute, second, millisecond, year, month, day, dayofweek, dayofyear]

# Every Dates name this file verifies (for stdlib_coverage.jl — keep in sync).
const DATES_VERIFIED = Set{Symbol}([
    :year, :month, :day, :dayofweek, :dayofmonth, :dayofyear, :dayofquarter,
    :dayofweekofmonth, :daysofweekinmonth, :week, :daysinmonth, :daysinyear,
    :quarterofyear, :firstdayofmonth, :lastdayofmonth, :firstdayofweek,
    :lastdayofweek, :firstdayofquarter, :lastdayofquarter, :firstdayofyear,
    :lastdayofyear, :isleapyear, :hour, :minute, :second, :millisecond,
    :Date, :DateTime, :Day, :Month, :Year, :Week, :Hour, :Minute, :Second,
])

# named wrappers (callee context) for arithmetic + construction
_dt_pDay(d)   = d + Day(5)
_dt_mDay(d)   = d - Day(9)
_dt_pMonth(d) = d + Month(7)
_dt_pYear(d)  = d + Year(3)
_dt_pWeek(d)  = d + Week(2)
_dt_isleap(d) = isleapyear(d)
_dt_mkdate(y, m, d)         = Date(y, m, d)
_dt_mkdt(y, m, d, h, mi, s) = DateTime(y, m, d, h, mi, s)
_dt_datesub(a, b)           = Dates.value(a - b)   # day count (Int64)

function run_dates_tests(; reps::Int = 40)
    FuzzHarness.NODE_OK || (@test_skip true; return)
    rng = MersenneTwister(0xDA7E)
    dates = [ (_rdate(rng),) for _ in 1:reps ]
    dts   = [ (_rdt(rng),)   for _ in 1:reps ]

    @testset "Date → Int accessors" begin
        for f in _DT_INT
            @test _dt_diff(f, (Date,), dates, Int64)
        end
    end
    @testset "Date → Date adjusters" begin
        for f in _DT_DATE
            @test _dt_diff(f, (Date,), dates, Date)
        end
    end
    @testset "DateTime → Int accessors" begin
        for f in _DT_TIME
            @test _dt_diff(f, (DateTime,), dts, Int64)
        end
    end
    @testset "Date arithmetic + predicates" begin
        @test _dt_diff(_dt_pDay,   (Date,), dates, Date)
        @test _dt_diff(_dt_mDay,   (Date,), dates, Date)
        @test _dt_diff(_dt_pMonth, (Date,), dates, Date)
        @test _dt_diff(_dt_pYear,  (Date,), dates, Date)
        @test _dt_diff(_dt_pWeek,  (Date,), dates, Date)
        @test _dt_diff(_dt_isleap, (Date,), dates, Bool)
        @test _dt_diff(_dt_datesub, (Date, Date),
                       [ (_rdate(rng), _rdate(rng)) for _ in 1:reps ], Int64)
    end
    @testset "construction" begin
        @test _dt_diff(_dt_mkdate, (Int64, Int64, Int64),
                       [ (rand(rng, 1850:2200), rand(rng, 1:12), rand(rng, 1:28)) for _ in 1:reps ], Date)
        @test _dt_diff(_dt_mkdt, (Int64, Int64, Int64, Int64, Int64, Int64),
                       [ (rand(rng, 1850:2200), rand(rng, 1:12), rand(rng, 1:28),
                          rand(rng, 0:23), rand(rng, 0:59), rand(rng, 0:59)) for _ in 1:reps ], DateTime)
    end
end
