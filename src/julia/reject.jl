# The rejections: every construct WasmTarget cannot compile ends here, located, never in a plausible
# value (dev/CHARTER.md C6). A closed sum of kinds; the compile's caller receives it as a
# RejectionError.
#
# parity(quarantine: dart throws at the site, an exception the driver reports (compile.dart:216
# compile); Julia has no checked exceptions, so the kinds are one closed sum carried by one exception
# type, Rust's Result<_, E> over a sealed E)

"""A path reached a dart definition not yet ported; `anchor` is `<file>.dart:<line> <Symbol>`."""
struct Unported
    anchor::String
end

"""A path reached a Julia-only definition (src/julia/) not yet written; `row` names it."""
struct Unquarantined
    row::String
end

"""Julia's trim verifier rejects the program; `reason` is Julia's own text."""
struct OutsideSubset
    reason::String
end

"""The module WasmTarget built is not valid wasm; `site` names where it was found."""
struct InvalidModule
    site::String
end

"""WasmTarget broke its own invariant; `site` names where."""
struct Internal
    site::String
end

"""
    Rejection

Why a compile stops: `Unported` and `Unquarantined` (a path that reaches a definition not yet
written: the dart definition it mirrors, or the Julia-only row it implements), `OutsideSubset`
(Julia's own trim verifier rejects the program), `InvalidModule` and `Internal` (a defect of
WasmTarget itself).

A closed sum by construction: a `Union` of five concrete structs that subtype nothing, so no other
module can add a kind; a sixth kind is an edit of this line, and its `_reason` is then owed at load
(`construction_check(::Val{:Rejection})`, below).

precedent(rust: enum + exhaustive match; dart: sealed class + exhaustive switch). Julia's differs:
a `Union` of concrete types where Rust declares an enum and dart a sealed hierarchy, and its
exhaustiveness checked when the package loads, since Julia checks no match at compile time.
"""
const Rejection = Union{Unported, Unquarantined, OutsideSubset, InvalidModule, Internal}

"""
    RejectionError(rejection, at)

The one exception a compile raises: its `Rejection` and `at`, the compile it stopped (the function
and argument types; the statement and its inline chain once code is generated, dev/MARCH.md 1.D).
"""
struct RejectionError <: Exception
    rejection::Rejection
    at::String
end

_reason(r::Unported)::String = "unported: the dart definition $(r.anchor)"
_reason(r::Unquarantined)::String = "unported: the Julia-only definition $(r.row)"
_reason(r::OutsideSubset)::String = "outside the strict subset: $(r.reason)"
_reason(r::InvalidModule)::String = "invalid module at $(r.site)"
_reason(r::Internal)::String = "internal error at $(r.site)"

Base.showerror(io::IO, e::RejectionError) = print(io, "WasmTarget rejects ", e.at, ": ", _reason(e.rejection))

"""
    reject!(rejection, at) -> Union{}

Stop the compile `at` names with `rejection`.
"""
reject!(r::Rejection, at::String)::Union{} = throw(RejectionError(r, at))

# The sum's load-time check: every kind concrete, subtyping nothing, handled by `_reason`, and
# `_reason` defined for the kinds alone. A violation refuses the package's load.
construction_check(::Val{:Rejection})::Int = check_closed_sum(Rejection, _reason)
construction_check(Val(:Rejection))
