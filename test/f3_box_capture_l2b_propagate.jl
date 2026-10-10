# F3 sub-loop L2b (dev/HISTORY.md#closures-and-dynamic-dispatch) — value-type propagation past Julia's Box{Any} erasure.
#
# f3_box_value_types(nir) forward-propagates concrete types from each %new(Core.Box)
# with concrete contents: box-reads (getfield(box,:contents), inferred Any) → the contents type;
# ops that CONSUME a box-derived value → their computed result type. The typed-box wiring consumes
# this so the getfield→… chain lands i64 values in i64 locals (not anyref-from-erasure). DORMANT:
# nothing reads it yet (byte-identical). Only box-DERIVED SSAs are typed — no false positives on
# unrelated concrete-result calls.

# The box-capture analysis takes its closure bodies as a lookup (closure_ir): a compilation
# passes its collected world's; a test outside any compilation asks Julia's inference.
_f3_ir_propagate(mi) = (r = Base.code_typed_by_type(mi.specTypes; interp=WasmTarget.get_wasm_interpreter());
              isempty(r) ? nothing : (r[1][1], r[1][2]))

@testset "F3 L2b: f3_box_value_types value-type propagation" begin
    @test isempty(WasmTarget.capture_read_types(WasmTarget.NirStmt[], Any[],
                                                Dict{Tuple{Type,Symbol},Type}(), Tuple{Vararg{Int64}}; closure_ir=_f3_ir_propagate))
    # counter: `s` mutated capture → Core.Box{Int64}; getfield(box,:contents)::Any must propagate Int64.
    fcounter(n::Int64) = (s = 0; foreach(i -> (s += i), 1:n); s)
    ci = code_typed(fcounter, (Int64,); optimize = true)[1].first
    nir = WasmTarget.build_nir(ci)
    vt = WasmTarget.f3_box_value_types(nir; closure_ir=_f3_ir_propagate)

    @test !isempty(vt)
    @test all(==(Int64), values(vt))                       # box contents is Int64
    # every typed SSA is a box-read (getfield(_, :contents)) — no unrelated calls captured
    for (i, _) in vt
        node = nir[i].node
        @test node isa WasmTarget.NirCall && node.callee === getfield &&
              length(node.operands) >= 2 &&
              node.operands[2] isa WasmTarget.NirLiteral && node.operands[2].value === :contents
    end

    # float accumulator → Float64 contents
    faccum(n::Int64) = (s = 0.0; foreach(i -> (s += i), 1:n); s)
    cif = code_typed(faccum, (Int64,); optimize = true)[1].first
    vtf = WasmTarget.f3_box_value_types(WasmTarget.build_nir(cif); closure_ir=_f3_ir_propagate)
    @test !isempty(vtf) && all(==(Float64), values(vtf))

    # no Core.Box → empty (no false positives on an ordinary numeric fn)
    fplain(x::Int64) = (a = x + 1; b = a * 2; b - 3)
    cip = code_typed(fplain, (Int64,); optimize = true)[1].first
    @test isempty(WasmTarget.f3_box_value_types(WasmTarget.build_nir(cip); closure_ir=_f3_ir_propagate))

    # A concrete dominating write also proves non-numeric captured contents.
    # Julia boxes this local because its surrounding scope owns the name.
    function vector_capture()
        local result
        return () -> begin
            result = Int64[]
            push!(result, Int64(1))
            result
        end
    end
    vf = vector_capture()
    vci = only(code_typed(vf, ())).first
    vnir = WasmTarget.build_nir(vci)
    # the creator records the box's type (its only write is the closure's, so the box starts
    # undefined and holds Vector{Int64}); the closure's reads are typed from that record
    cci = only(code_typed(vector_capture, ())).first
    vst, cst = WasmTarget.nir_slot_types(vci), WasmTarget.nir_slot_types(cci)
    vrec = WasmTarget.record_capture_contents(Any[(WasmTarget.build_nir(cci), cst, cst[1]),
                                                  (vnir, vst, vst[1])]; closure_ir=_f3_ir_propagate)
    @test vrec[(typeof(vf), :result)] === Vector{Int64}
    vjoins = WasmTarget.capture_read_types(vnir, vnir, vrec, typeof(vf);
                                           spectypes=WasmTarget.nir_slot_types(vci), closure_ir=_f3_ir_propagate)
    @test Vector{Int64} in values(vjoins)

    # The recovered contents type must reach codegen, not merely the analysis
    # table. `push!` was enrolled as a dispatch-only closed-world candidate
    # while inference still called the box read `Any`; the concrete proof above
    # must devirtualize its exact signature without exposing candidates to
    # ordinary or fuzzy lookup.
    vmod = WasmTarget.compile_multi([
        (vf, (), "boxed_vector_capture"),
    ]; root_bindings=Dict(
        "boxed_vector_capture" => WasmTarget.RootBindings(
            captured_constants=Dict(:result => getfield(vf, :result)),
            elide_closure_context=true,
        ),
    ))
    # `compile_multi` validates serialized bytes by default; serialization here
    # also locks that the successfully built module is materializable.
    @test vmod isa Vector{UInt8} && !isempty(vmod)

    # CLOSURE-BODY seeding (dart Capture.type): foreach compiles `i->(s+=i)` as a separate body
    # where the box arrives via getfield(#self#, boxfield) — seed from those, then the body's
    # getfield(box,:contents) read AND the `s+i` add (over the closure arg, resolved via spectypes)
    # must both propagate the contents type. Without the closure seed the body sees no box at all.
    fcl(n::Int64) = (s = 0; foreach(i -> (s += i), 1:n); s)
    cic = code_typed(fcl, (Int64,); optimize = true)[1].first
    cnir = WasmTarget.build_nir(cic)
    bid = WasmTarget.find_box_news(cnir)[1]
    bodies = WasmTarget._f3_capturing_closure_bodies(cnir, bid; closure_ir=_f3_ir_propagate)
    @test !isempty(bodies)
    for (bnir, bspec) in bodies
        local boxf = only(fieldname(bspec[1], k) for k in 1:fieldcount(bspec[1])
                          if fieldtype(bspec[1], k) === Core.Box)
        vt = WasmTarget.capture_read_types(bnir, bnir,
                                           Dict{Tuple{Type,Symbol},Type}((bspec[1], boxf) => Int64),
                                           bspec[1]; spectypes = bspec, closure_ir=_f3_ir_propagate)
        # both the contents read AND the s+i add (resolved Int64 via spectypes) propagate;
        # the box reads themselves are never retyped
        @test count(==(Int64), values(vt)) >= 2
    end
end
