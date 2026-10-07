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
# below max_methods, inference splits the call and Julia's IR ends it in
# Core.throw_methoderror(u, v), with `v` erased: its args tuple has v's runtime type
u(x::Int64) = Int32(1); u(x::String) = Int32(2)
# a dynamic call whose candidates take a Memory{Int64} and a Memory{UInt64}, one wasm array type
@noinline lenany(@nospecialize(x)) = length(x)
gm(x::Int64) = (v = Any[Memory{Int64}(undef, x), Memory{UInt64}(undef, 2), "abcd"]; lenany(v[1]))
# a closure's one body, called with a struct of another class and one deduplicated layout
struct SA; x::Int64; end
struct SB; x::Int64; end
@noinline hide(@nospecialize(x)) = Ref{Any}(x)
gq(n::Int64) = (k = n; f = hide(s -> (s isa SA ? 10 : 20) + k)[]; f(SA(n)); f(hide(SB(n))[])::Int64)
gu(x::Int64)::Int32 = (v = Any[x, "s", 1.5]; try; u(v[x]); catch e; e isa MethodError ? Int32(7) : Int32(8); end)
# a closure whose two methods are ambiguous over an Int64, called with an erased Int64
gam(n::Int64) = (k = n; h(x::Union{Int64,String}) = 1 + 0k; h(x::Union{Int64,Float64}) = 2 + 0k;
                 g = hide(h)[]; try; g(hide(n)[])::Int64; catch; -1; end)
# a closure called with an AbstractVector{Int64} while a Memory{Int64} class is numbered
struct WV; v::AbstractVector{Int64}; end
# a closure row taking a Type{X} whose values are not one pointer (type equality, jl_isa)
gte(n::Int64) = (k = n; h(::Type{Tuple{Int64,Integer}}) = 1 + 0k; h(x) = 2 + 0k; f = hide(h)[];
                 f(hide(Tuple{Int64,T} where T<:Integer)[])::Int64)
gab(n::Int64) = (k = n; g = hide(x -> length(x) + k)[]; w = hide(WV([1, 2]))[]::WV;
                 m = Memory{Int64}(undef, 2); g([1, 2, 3])::Int64 + g(w.v)::Int64 + length(m))
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
    # a split call's throw_methoderror over an erased value: WT cannot build the args tuple
    # of its runtime type (MARCH 13.10), so it traps, never throwing an exception that is not
    # Julia's MethodError, which Julia's catch answers (dev/AUDIT.md A3S1)
    @test M.gu(3) == Int32(7)
    let r = WasmRunner.run_wasm_single(WasmTarget.compile(M.gu, (Int64,)), "gu", "3n")
        @test r[1] === :trap
    end
    # a candidate whose class shares its wasm array type has no row: the call rejects at
    # compile time, never a switch that traps on it (dev/AUDIT.md A3S2)
    @test M.gm(3) == 3
    @test_throws WasmTarget.WasmCompileError WasmTarget.compile(M.gm, (Int64,))
    # a vtable entry tests its argument's class: the SA body never runs for an SB (it cast
    # and answered 13; dev/AUDIT.md A4C3), and the erased call enrolls the closure's body for
    # every class that may reach it, so the SB call answers as Julia does (A4S2)
    @test M.gq(3) == 23
    let r = WasmRunner.run_wasm_single(WasmTarget.compile(M.gq, (Int64,)), "gq", "3n")
        @test r[1] === :ok && unmarshal_result(r[2]) == 23
    end
    # a call Julia rejects as ambiguous rejects at compile time, never a row order that runs one
    # method (dev/AUDIT.md A6C3, Enrollment.tla RejectOnlyWhenAmbiguous)
    @test M.gam(3) == -1
    let e = try; WasmTarget.compile(M.gam, (Int64,)); nothing; catch err; err; end
        @test e isa WasmTarget.WasmCompileError && occursin("which are ambiguous for (Int64)", sprint(showerror, e))
    end
    # an abstract parameter admitting a bare array has no entry row: a WasmCompileError naming
    # the callable, never a WasmInternalError (dev/AUDIT.md A5C4, A6E8)
    @test M.gab(3) == 13
    let e = try; WasmTarget.compile(M.gab, (Int64,)); nothing; catch err; err; end
        @test e isa WasmTarget.WasmCompileError && occursin("admits a type object or a bare array", sprint(showerror, e))
    end
    # a Type{X} parameter jl_isa tests by type equality has no entry row: a WasmCompileError
    # naming the callable (A6B4 = A6C6: it raised a WasmInternalError)
    @test M.gte(3) == 1
    let e = try; WasmTarget.compile(M.gte, (Int64,)); nothing; catch err; err; end
        @test e isa WasmTarget.WasmCompileError && occursin("admits a type object or a bare array", sprint(showerror, e))
    end
end
