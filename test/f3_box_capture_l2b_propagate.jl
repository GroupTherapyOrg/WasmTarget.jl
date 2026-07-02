# F3 sub-loop L2b (dev/F3_LOOP.md) — value-type propagation past Julia's Box{Any} erasure.
#
# f3_box_value_types(code, ssa_types) forward-propagates concrete types from each %new(Core.Box)
# with concrete contents: box-reads (getfield(box,:contents), inferred Any) → the contents type;
# ops that CONSUME a box-derived value → their computed result type. The typed-box wiring consumes
# this so the getfield→… chain lands i64 values in i64 locals (not anyref-from-erasure). DORMANT:
# nothing reads it yet (byte-identical). Only box-DERIVED SSAs are typed — no false positives on
# unrelated concrete-result calls.

@testset "F3 L2b: f3_box_value_types value-type propagation (dormant)" begin
    # counter: `s` mutated capture → Core.Box{Int64}; getfield(box,:contents)::Any must propagate Int64.
    fcounter(n::Int64) = (s = 0; foreach(i -> (s += i), 1:n); s)
    ci = code_typed(fcounter, (Int64,); optimize = true)[1].first
    vt = WasmTarget.f3_box_value_types(ci.code, ci.ssavaluetypes)

    @test !isempty(vt)
    @test all(==(Int64), values(vt))                       # box contents is Int64
    # every typed SSA is a box-read (getfield(_, :contents)) — no unrelated calls captured
    for (i, _) in vt
        s = ci.code[i]
        @test s isa Expr && s.head === :call && s.args[1] isa GlobalRef &&
              s.args[1].name === :getfield &&
              length(s.args) >= 3 && s.args[3] isa QuoteNode && s.args[3].value === :contents
    end

    # float accumulator → Float64 contents
    faccum(n::Int64) = (s = 0.0; foreach(i -> (s += i), 1:n); s)
    cif = code_typed(faccum, (Int64,); optimize = true)[1].first
    vtf = WasmTarget.f3_box_value_types(cif.code, cif.ssavaluetypes)
    @test !isempty(vtf) && all(==(Float64), values(vtf))

    # no Core.Box → empty (no false positives on an ordinary numeric fn)
    fplain(x::Int64) = (a = x + 1; b = a * 2; b - 3)
    cip = code_typed(fplain, (Int64,); optimize = true)[1].first
    @test isempty(WasmTarget.f3_box_value_types(cip.code, cip.ssavaluetypes))

    # CLOSURE-BODY seeding (dart Capture.type): foreach compiles `i->(s+=i)` as a separate body
    # where the box arrives via getfield(#self#, boxfield) — seed from those, then the body's
    # getfield(box,:contents) read AND the `s+i` add (over the closure arg, resolved via spectypes)
    # must both propagate the contents type. Without the closure seed the body sees no box at all.
    fcl(n::Int64) = (s = 0; foreach(i -> (s += i), 1:n); s)
    cic = code_typed(fcl, (Int64,); optimize = true)[1].first
    bid = WasmTarget.find_box_news(cic.code)[1]
    bodies = WasmTarget._f3_capturing_closure_bodies(cic.code, bid)
    @test !isempty(bodies)
    for (bcode, bsst, bspec) in bodies
        seeds = WasmTarget.f3_closure_box_seeds(bcode, bspec[1], Int64)
        @test !isempty(seeds) && all(==(Int64), values(seeds))          # captured-box field reads
        vt = WasmTarget.f3_box_value_types(bcode, bsst; extra_box_seeds = seeds, spectypes = bspec)
        # both the getfield read AND the s+i add (resolved Int64 via spectypes) propagate
        @test count(==(Int64), values(vt)) >= 2
    end
end
