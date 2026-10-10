# record_capture_contents: every captured variable's type, keyed by (closure type, field), is
# the least fixpoint of the writes into its Core.Box across the closed world's bodies — the
# creator's (an argument typed by its signature) and every body writing through the field;
# a field whose writes are not one concrete type, or whose box no body creates, records Any
# (dev/formal/CaptureType.tla).

# The box-capture analysis takes its closure bodies as a lookup (closure_ir): a compilation
# passes its collected world's; a test outside any compilation asks Julia's inference.
_f3_ir_prepass(mi) = (r = Base.code_typed_by_type(mi.specTypes; interp=WasmTarget.get_wasm_interpreter());
              isempty(r) ? nothing : (r[1][1], r[1][2]))

_rc_mki(x::Int64) = (c = x; () -> (c = c + 1; c))
_rc_mkf(x::Float64) = (c = x; () -> (c = c + 1; c))
_rc_mkmix(x::Int64) = (c = x; () -> (c = c + 0.5; c))
_rc_undef() = (local r; () -> (r = Int64[]; push!(r, 1); r))

# the (nir, slot types, #self# type) of `f(argtypes...)`
_rc_body(f, argtypes) = begin
    ci = code_typed(f, argtypes; optimize = true)[1].first
    st = WasmTarget.nir_slot_types(ci)
    (WasmTarget.build_nir(ci), st, st[1])
end
# a creator and the closure it returns, as the closed world holds them
_rc_world(mk, args...) = Any[_rc_body(mk, map(typeof, args)), _rc_body(mk(args...), ())]
_rc_values(world) = collect(values(WasmTarget.record_capture_contents(world; closure_ir=_f3_ir_prepass)))

@testset "record_capture_contents: captured variables' types from every write" begin
    # counter: `s` is a mutated capture → Core.Box; the foreach closure captures it.
    fcounter() = (s = 0; foreach(i -> (s += i), 1:5); s)
    @test length(WasmTarget.find_box_news(_rc_body(fcounter, ())[1])) == 1
    @test _rc_values(Any[_rc_body(fcounter, ())]) == [Int64]

    # an argument written in is typed by the creator's signature, and the closure's own
    # `c = c + 1` keeps it Int64
    @test _rc_values(_rc_world(_rc_mki, 1)) == [Int64]
    # a Float64 creator and an Int64 increment are Float64 (a body alone guessed Int64 from the
    # `+ 1` and the read unboxed a Float64 box as an Int64 one)
    @test _rc_values(_rc_world(_rc_mkf, 0.25)) == [Float64]
    # an Int64 creator and a Float64 increment disagree: erased
    @test _rc_values(_rc_world(_rc_mkmix, 1)) == [Any]
    # the closure alone, its creator outside the world: its base is unknown, never concrete
    @test all(==(Any), _rc_values(Any[_rc_body(_rc_mkf(0.25), ())]))
    # a box its creator never writes starts undefined: its type is the closures' writes'
    @test _rc_values(_rc_world(_rc_undef)) == [Vector{Int64}]
end
