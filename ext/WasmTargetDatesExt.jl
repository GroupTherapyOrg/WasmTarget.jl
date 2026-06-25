# WasmTargetDatesExt — Dates stdlib integration.
#
# The VALUE layer (Date/DateTime construction, period arithmetic, accessors,
# date subtraction, parsing with a DateFormat, period conversions,
# daysinmonth/isleapyear) compiles from the real Dates implementations with
# no stdlib-specific code. This extension carries only the rendering
# overlays: native string(::Date) goes through IOBuffer growth internals
# (ensureroom machinery) that WasmGC does not support yet, so render via the
# compileable string(::Int64) + concatenation machinery instead —
# semantically identical output.
#
# now()/today() are NOT overlaid here: they need a host-time import wired by
# the embedding pipeline (compile_multi's import_stubs, e.g. "Date"/"now" →
# JS Date.now), and wall-clock reads are host-dependent by nature.
module WasmTargetDatesExt

using WasmTarget
using Dates
using Base.Experimental: @overlay

function _wt_zpad(n::Int64, w::Int64)
    s = string(n)
    while sizeof(s) < w   # ASCII digits: byte length == digit count
        s = "0" * s
    end
    return s
end

@overlay WasmTarget.WASM_METHOD_TABLE function Base.string(d::Dates.Date)
    y = Int64(Dates.year(d))
    m = Int64(Dates.month(d))
    dd = Int64(Dates.day(d))
    sign = y < 0 ? "-" : ""
    ya = y < 0 ? -y : y
    return sign * _wt_zpad(ya, 4) * "-" * _wt_zpad(m, 2) * "-" * _wt_zpad(dd, 2)
end

@overlay WasmTarget.WASM_METHOD_TABLE function Base.string(dt::Dates.DateTime)
    y = Int64(Dates.year(dt))
    m = Int64(Dates.month(dt))
    dd = Int64(Dates.day(dt))
    h = Int64(Dates.hour(dt))
    mi = Int64(Dates.minute(dt))
    se = Int64(Dates.second(dt))
    ms = Int64(Dates.millisecond(dt))
    sign = y < 0 ? "-" : ""
    ya = y < 0 ? -y : y
    base = sign * _wt_zpad(ya, 4) * "-" * _wt_zpad(m, 2) * "-" * _wt_zpad(dd, 2) *
           "T" * _wt_zpad(h, 2) * ":" * _wt_zpad(mi, 2) * ":" * _wt_zpad(se, 2)
    return ms == 0 ? base : base * "." * _wt_zpad(ms, 3)
end

# ── Locale names (dayname/dayabbr/monthname/monthabbr) ──────────────────────
# Native routes these through `LOCALES[locale]` (a Dict{String,DateLocale}
# global) + the DateLocale struct fields — a Dict-of-structs lookup behind a
# kwarg that lowers to `unreachable`. The DEFAULT locale is ENGLISH and its
# tables are fixed; index the hard-coded ENGLISH vectors by dayofweek/month.
# Bit-identical to native `dayname(d)` / etc. (default locale="english").
const _WT_MONTHS = ["January", "February", "March", "April", "May", "June",
                    "July", "August", "September", "October", "November", "December"]
const _WT_MONTHS_ABBR = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                         "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const _WT_DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
const _WT_DAYS_ABBR = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

@overlay WasmTarget.WASM_METHOD_TABLE Dates.dayname(dt::Dates.TimeType; locale = "english") =
    _WT_DAYS[Dates.dayofweek(dt)]
@overlay WasmTarget.WASM_METHOD_TABLE Dates.dayabbr(dt::Dates.TimeType; locale = "english") =
    _WT_DAYS_ABBR[Dates.dayofweek(dt)]
@overlay WasmTarget.WASM_METHOD_TABLE Dates.monthname(dt::Dates.TimeType; locale = "english") =
    _WT_MONTHS[Dates.month(dt)]
@overlay WasmTarget.WASM_METHOD_TABLE Dates.monthabbr(dt::Dates.TimeType; locale = "english") =
    _WT_MONTHS_ABBR[Dates.month(dt)]

# ── Day-of-week adjusters (tonext/toprev/tofirst/tolast) ────────────────────
# Native uses `adjust(ISDAYOFWEEK[dow], dt, step, n)` — a DateFunction predicate
# loop (a Method-as-value the generator can't compile, "cannot compile Method").
# The dow-Int forms are pure modular arithmetic on the weekday cycle; the
# explicit form is bit-identical to native (the predicate scans the same day
# window and stops at the first weekday match, which is exactly `start ±
# mod(Δweekday, 7)` days away — the firstday/lastday anchor guarantees the
# match lies within the month/year).
@overlay WasmTarget.WASM_METHOD_TABLE function Dates.tonext(dt::Dates.TimeType, dow::Int; same::Bool = false)
    start = same ? dt : dt + Dates.Day(1)
    start + Dates.Day(mod(dow - Dates.dayofweek(start), 7))
end
@overlay WasmTarget.WASM_METHOD_TABLE function Dates.toprev(dt::Dates.TimeType, dow::Int; same::Bool = false)
    start = same ? dt : dt - Dates.Day(1)
    start - Dates.Day(mod(Dates.dayofweek(start) - dow, 7))
end
@overlay WasmTarget.WASM_METHOD_TABLE function Dates.tofirst(dt::Dates.TimeType, dow::Int;
                                                             of::Union{Type{Year}, Type{Month}} = Month)
    base = of === Dates.Month ? Dates.firstdayofmonth(dt) : Dates.firstdayofyear(dt)
    base + Dates.Day(mod(dow - Dates.dayofweek(base), 7))
end
@overlay WasmTarget.WASM_METHOD_TABLE function Dates.tolast(dt::Dates.TimeType, dow::Int;
                                                            of::Union{Type{Year}, Type{Month}} = Month)
    base = of === Dates.Month ? Dates.lastdayofmonth(dt) : Dates.lastdayofyear(dt)
    base - Dates.Day(mod(Dates.dayofweek(base) - dow, 7))
end

end # module
