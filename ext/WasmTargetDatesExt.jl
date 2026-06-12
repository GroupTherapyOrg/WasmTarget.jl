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

end # module
