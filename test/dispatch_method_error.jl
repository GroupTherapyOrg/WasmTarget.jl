# formal(dev/formal/ClassIdDispatch.tla): MissingMethodTraps — a receiver tuple with no
# matching Julia method TRAPS through the ONE selector table (the MethodError analog), and
# every tuple with one still resolves to exactly it (DispatchExact).
#
# The two counterexamples TLC found against the pre-fix table, both reproduced here:
#   (i)  the second axis never varies, so it was never read: f2(::A,::A)/f2(::B,::A)/…
#        called on (A, B) ran f2(::A,::A);
#   (ii) a class with no row read whatever first-fit packing put at offset+classId — another
#        selector's same-signature row (k(::E) with no method ran f(::A): E shares A's
#        layout, so ref.cast passed; add_type! dedupes equal FuncTypes, so call_indirect
#        accepted it).
# dart never guards its virtual call (static typing guarantees the member exists,
# code_generator.dart:2028); WT's three Julia-only guards are: whole-span reservation with
# null holes (`_fit!`), the classId span guard in the caller and every trampoline, and the
# per-entry wrapper check of every non-level-1-axis classed slot.
#
# Every generic needs >= 4 methods: below Julia's max_methods the forwarder is union-split
# by inference into an inline isa chain and never reaches the table.

module DispatchMethodErrorE2E
struct A x::Int32 end; struct B x::Int32 end; struct C x::Int32 end; struct D x::Int32 end
struct E x::Int32 end; struct F x::Int32 end; struct G x::Int32 end; struct H x::Int32 end
f(::A) = Int32(1);  f(::C) = Int32(3);  f(::E) = Int32(5);  f(::G) = Int32(7)
h(::B) = Int32(20); h(::D) = Int32(40); h(::F) = Int32(60); h(::H) = Int32(80)
k(::A) = Int32(101); k(::B) = Int32(102); k(::C) = Int32(103); k(::D) = Int32(104)
f2(::A, ::A) = Int32(11); f2(::B, ::A) = Int32(21); f2(::C, ::A) = Int32(31); f2(::D, ::A) = Int32(41)
gf(x::Any)::Int32 = f(x)
gh(x::Any)::Int32 = h(x)
gk(x::Any)::Int32 = k(x)
gf2(x::Any, y::Any)::Int32 = f2(x, y)
mkA(v::Int32) = A(v); mkB(v::Int32) = B(v); mkC(v::Int32) = C(v); mkD(v::Int32) = D(v)
mkE(v::Int32) = E(v); mkF(v::Int32) = F(v); mkG(v::Int32) = G(v); mkH(v::Int32) = H(v)
end

@testset "dispatch: MethodError receivers trap through the ONE table" begin
    M = DispatchMethodErrorE2E
    fns = [(M.f,(M.A,)),(M.f,(M.C,)),(M.f,(M.E,)),(M.f,(M.G,)),
           (M.h,(M.B,)),(M.h,(M.D,)),(M.h,(M.F,)),(M.h,(M.H,)),
           (M.k,(M.A,)),(M.k,(M.B,)),(M.k,(M.C,)),(M.k,(M.D,)),
           (M.f2,(M.A,M.A)),(M.f2,(M.B,M.A)),(M.f2,(M.C,M.A)),(M.f2,(M.D,M.A)),
           (M.gf,(Any,)),(M.gh,(Any,)),(M.gk,(Any,)),(M.gf2,(Any,Any)),
           (M.mkA,(Int32,)),(M.mkB,(Int32,)),(M.mkC,(Int32,)),(M.mkD,(Int32,)),
           (M.mkE,(Int32,)),(M.mkF,(Int32,)),(M.mkG,(Int32,)),(M.mkH,(Int32,))]
    bytes, treg, freg, dreg = WasmTarget.compile_multi(fns; return_registries=true)
    for g in (M.f, M.h, M.k, M.f2)
        @test haskey(dreg.selector_offset, g)   # every generic routed through the table
    end

    # Structural: a selector's span [min row, max row] holds ONLY its own cells — no other
    # selector's row may sit in a hole (the pre-fix interleaving that produced (ii)).
    owner = Dict{Int,Any}()
    spans = Dict{Any,Tuple{Int,Int}}()
    for (g, positions) in dreg.selector_positions
        poss = Int[p for (p, _) in positions]
        for c in get(dreg.selector_cascades, g, [])
            push!(poss, c.l1_pos)
            for (p2, _) in c.rows2
                push!(poss, p2)
            end
        end
        for p in poss
            @test !haskey(owner, p)   # SlotUnique
            owner[p] = g
        end
        spans[g] = (minimum(poss), maximum(poss))
    end
    for (g, (lo, hi)) in spans, p in lo:hi
        @test get(owner, p, g) === g
    end

    WasmRunner.runner_available() || return
    native(fn, args...) = try; (:ok, fn(args...)); catch e; (:err, typeof(e)); end
    wasm(name, js) = WasmRunner.run_wasm_single(bytes, name, js)
    v = Int32(0)
    # every tuple WITH a method resolves to exactly it (DispatchExact)
    legit = [("gf",  "instance.exports.mkA(0)", M.gf,  (M.A(v),)),
             ("gf",  "instance.exports.mkG(0)", M.gf,  (M.G(v),)),
             ("gh",  "instance.exports.mkD(0)", M.gh,  (M.D(v),)),
             ("gk",  "instance.exports.mkC(0)", M.gk,  (M.C(v),)),
             ("gf2", "instance.exports.mkA(0), instance.exports.mkA(0)", M.gf2, (M.A(v), M.A(v))),
             ("gf2", "instance.exports.mkD(0), instance.exports.mkA(0)", M.gf2, (M.D(v), M.A(v)))]
    for (name, js, fn, args) in legit
        n = native(fn, args...)
        w = wasm(name, js)
        @test n[1] === :ok && w[1] === :ok && w[2] == n[2]
    end
    # every tuple WITHOUT one: native MethodError, wasm trap — never another row's result
    missing = [("gf",  "instance.exports.mkB(0)", M.gf,  (M.B(v),)),   # null hole inside f's span
               ("gf",  "instance.exports.mkH(0)", M.gf,  (M.H(v),)),   # outside f's span: guard
               ("gh",  "instance.exports.mkA(0)", M.gh,  (M.A(v),)),
               ("gk",  "instance.exports.mkE(0)", M.gk,  (M.E(v),)),   # (ii) ran f(::A) before
               ("gk",  "instance.exports.mkH(0)", M.gk,  (M.H(v),)),
               ("gf2", "instance.exports.mkA(0), instance.exports.mkB(0)", M.gf2, (M.A(v), M.B(v))),   # (i) ran f2(::A,::A) before
               ("gf2", "instance.exports.mkA(0), instance.exports.mkH(0)", M.gf2, (M.A(v), M.H(v))),
               ("gf2", "instance.exports.mkE(0), instance.exports.mkA(0)", M.gf2, (M.E(v), M.A(v)))]
    for (name, js, fn, args) in missing
        n = native(fn, args...)
        w = wasm(name, js)
        @test n == (:err, MethodError)
        @test w[1] === :trap
    end
end
