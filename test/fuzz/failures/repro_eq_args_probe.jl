const ROOT = ARGS[1]
using WasmTarget
include(joinpath(ROOT, "test", "fuzz", "harness.jl")); using .FuzzHarness
probes = [
    ("len Dict{I,F} + len vec", (x::Int64) -> gcd(length(Dict(0 => 0.0, x => 0.0)), length([0, 0, x]))),
    ("len Dict{I,F}",           (x::Int64) -> length(Dict(0 => 0.0, x => 0.0))),
    ("len Dict{I,I}",           (x::Int64) -> length(Dict(0 => 0, x => 0))),
    ("gcd plain",               (x::Int64) -> gcd(2, length([0, 0, x]))),
    ("Int(uppercase é)",        (x::Int64) -> Int(uppercase('é'))),
    ("minimum unique cumsum",   (x::Int64) -> minimum(unique(cumsum([0, x, x])))),
]
for (nm, fn) in probes
    r = try; FuzzHarness.compile_and_run(fn, (Int64,), [(1,)])[1]; catch e; (:compile_error, first(sprint(showerror, e), 80)); end
    nat = try; string(Base.invokelatest(fn, 1)); catch; "throws"; end
    status = r[1] === :ok ? (string(r[2]) == nat ? "✓" : "✗ wrong: $(r[2]) vs $nat") : (nat == "throws" && r[1] === :trap ? "✓ both-throw" : "✗ $(r[1]): $(first(string(r[2]), 80))")
    println(rpad(nm, 26), status)
end
