# record_capture_contents: every captured variable's type, keyed by (closure type, field), is
# the least fixpoint of the writes into its Core.Box across the closed world's bodies — the
# creator's (an argument typed by its signature) and every body writing through the field;
# a field whose writes are not one concrete type, or whose box no body creates, records Any
# (dev/formal/CaptureType.tla).

# The box-capture analysis takes every closure body of a callable type (closure_bodies) and asks
# each call's return type of `rettype`: a compilation passes its collected world's bodies and the
# collector's inference entry; a test outside any compilation takes every specialization Julia
# holds of the type's call methods, inferred by the WasmInterpreter, and that same entry.
_f3_bodies_prepass(@nospecialize(T)) = Tuple{Core.MethodInstance,Core.CodeInfo}[
    (mi, r[1][1]) for m in Base._methods_by_ftype(Tuple{T, Vararg{Any}}, -1, Base.get_world_counter())
    for mi in Base.specializations(m.method)
    if mi isa Core.MethodInstance && mi.specTypes isa DataType && mi.specTypes.parameters[1] === T
    for r in (Base.code_typed_by_type(mi.specTypes; interp=WasmTarget.get_wasm_interpreter()),) if !isempty(r)]

_rc_mki(x::Int64) = (c = x; () -> (c = c + 1; c))
_rc_mkf(x::Float64) = (c = x; () -> (c = c + 1; c))
_rc_mkmix(x::Int64) = (c = x; () -> (c = c + 0.5; c))
_rc_undef() = (local r; () -> (r = Int64[]; push!(r, 1); r))

# the (nir, slot types) of `f(argtypes...)`
_rc_body(f, argtypes) = begin
    ci = code_typed(f, argtypes; optimize = true)[1].first
    (WasmTarget.build_nir(ci), WasmTarget.nir_slot_types(ci))
end
# a creator and the closure it returns, as the closed world holds them
_rc_world(mk, args...) = Any[_rc_body(mk, map(typeof, args)), _rc_body(mk(args...), ())]
_rc_values(world) = collect(values(WasmTarget.record_capture_contents(world; closure_bodies=_f3_bodies_prepass, rettype=WasmTarget.infer_return_type)))

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

# Two closures capture one box, each through its own field: the writer stores a Float64 and the
# reader is returned with it. Every field holding the box shares one join, so the reader's field
# is not the creator's Int64 alone (it unboxed the writer's 2.5 as an Int64 box: illegal cast,
# Julia answers 2.5; dev/formal/CaptureType.tla, MCCaptureTypePerFieldRecordBroken.cfg).
_rc_pair(n::Int64) = (x = n; w = @noinline(() -> (x = 2.5; nothing)); (w, @noinline(() -> x)))
@testset "record_capture_contents: every field holding one box shares its join" begin
    local p = _rc_pair(1)
    local world = Any[_rc_body(_rc_pair, (Int64,)), _rc_body(p[1], ()), _rc_body(p[2], ())]
    local rec = WasmTarget.record_capture_contents(world; closure_bodies=_f3_bodies_prepass,
                                                   rettype=WasmTarget.infer_return_type)
    @test length(rec) == 2
    @test all(==(Any), values(rec))
end

# A function taking a closure as an argument, the closure's body inlined into it, writes through
# the argument (`setfield!(getfield(_2, :c), :contents, 2.5)`): that write joins the box like any
# other, so the creator's read is not the creator's Int64 alone (dev/formal/CaptureType.tla's
# argument carrier; it was keyed only through `#self#` or an SSA value, and the creator's read
# unboxed a Float64 box as an Int64 one: illegal cast, Julia answers 1)
@noinline _rc_callit(g) = (g(); nothing)
_rc_inlined(n::Int64) = (c = n; w = () -> (c = 2.5; nothing); _rc_callit(w); c isa Float64 ? 1 : 2)
@testset "record_capture_contents: a write through an argument joins the box" begin
    local creator = _rc_body(_rc_inlined, (Int64,))
    # the closure type the creator builds, and the callee taking it
    local W = only(unique(n.node.T for n in creator[1] if n.node isa WasmTarget.NirNew &&
                          n.node.type_kind === :literal && n.node.T !== Core.Box))
    local callee = _rc_body(_rc_callit, (W,))
    # the callee writes through its argument: its body inlined the closure's
    @test any(s -> (w = WasmTarget._f3_contents_write(s.node); w !== nothing &&
                    WasmTarget._captured_box_field(w[1], callee[1], callee[2]) !== nothing), callee[1])
    local rec = WasmTarget.record_capture_contents(Any[creator, callee]; closure_bodies=_f3_bodies_prepass,
                                                   rettype=WasmTarget.infer_return_type)
    @test rec[(W, :c)] === Any
end
