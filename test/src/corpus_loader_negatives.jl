# The corpus loader's negatives (test/corpus_loader.jl), run in every landing check: one fresh process, the julia this
# file runs on, loads a stand-in judge, the loader, a stand-in snapshot, then a unit of every class the loader refuses,
# each refused by name with the marker its forbidden code would write absent and the judge's names intact, and three
# honest units whose answers it reads back. A fresh process because a unit's module and its methods are Main's for
# good: the suite's own process holds other files' definitions, and a broken loader running a unit's code there
# would reach them. The classes are spec v11's 108 probe units' (the stepper, R1; `@enum` and `@eval`, R2; another
# unit's names, R4), one unit each, and spec v13's (a load that reads its process: Main's other names, another unit's
# module, a const of a mutable value of Base's), each refused by name at its read. Then two more children, two
# processes that differ in Main's names, LOAD_PATH, DEPOT_PATH, cwd and the other units present, load the same honest
# units to byte-equal digests, and a planted unit, one slug whose two texts differ in one constant, one text to each
# child, loads to different ones, which the loader's one compare names.
using Test

module CorpusLoaderNegatives
const LOADER = normpath(joinpath(@__DIR__, "..", "corpus_loader.jl"))
const LIMIT = 60   # seconds; the run takes about 2 (1.12 and 1.13, on AC)

# the child: the judge's stand-in names (Main's `_started`, `_judged`, `_g`, `_xf`, as test/smoke.jl defines them
# before its world), the loader, judge!, a stand-in snapshot, then each unit alone in landing order; one line a unit
const CHILD = raw"""
_started(k, s) = "honest judge"
_judged(x) = "judge"
const SMOKE_JUDGE_LIKE = "judge"
const GROUPS = Pair{String,Vector{Any}}[]
_g(n, c) = push!(GROUPS, n => c)
_xf(n, c) = push!(GROUPS, n => c)
_register(k, n, c) = (k === :_g ? _g : _xf)(n, c)
include(ARGS[1])
CorpusLoader.judge!(Base.get_world_counter(), Module[CorpusLoader])
helper(x::Int64) = 1
_snapv(x, ys...) = 2   # a varargs function of the snapshot's, max_args 2 (spec v14 W1)
const _SmM3 = 3
_g("snap", Any[("a", (x::Int64) -> helper(x), Int64(1))])
labels = Set{String}(string(g, "/", c[1]) for (g, cs) in GROUPS for c in cs)
const WORLD = Dict{String,UInt}()   # each loaded label's world, its unit's (the judge's _WORLD)
for p in ARGS[2:end]
    local slug = replace(basename(p), r"\.jl$" => "")
    local verdict = try
        local us = CorpusLoader._load_units([p]; register = _register, labels)
        union!(labels, us[1].labels)
        foreach(l -> WORLD[l] = us[1].world, us[1].labels)
        if slug == "own_forms"   # spec v16 X6: at the unit's own world, no foreign value dispatches to one of its methods
            for v in Any[Int64[], Any[], Vector{Union{}}(), Ref(1), Ref{Any}(1), 1 => 2, Pair{Any,Int64}(1, 2), (1, 2), (nothing, 2),
                         Dict{Int64,Int64}(), Dict{Any,Int64}(), Int64, Union{}, nothing]
                local ms = Base._methods_by_ftype(Tuple{typeof(helper),Core.Typeof(v)}, -1, us[1].world)
                println("FOREIGN\t", Core.Typeof(v), "\t", ms isa AbstractVector ? join((string(parentmodule(m.method)) for m in ms), ",") : "none")
            end
        end
        "LOADED\t" * join(us[1].labels, ",")
    catch e
        e isa CorpusLoader.Refusal ? "REFUSED\t" * replace(e.why, r"\s+" => " ") : "ERROR\t" * replace(sprint(showerror, e), r"\s+" => " ")
    end
    local marks = sort([string(s) for s in names(Main; all = true) if startswith(string(s), "_wt_ran")])
    local judge = string(_started("k", "s") == "honest judge", _judged(1) == "judge", helper(1) == 1, _SmM3 == 3,
                         Main.Any === Core.Any)
    println("UNIT\t", slug, "\t", verdict, "\tMARKS=", join(marks, ","), "\tJUDGE=", judge)
end
# the honest units' answers, each case called at its own world as the judge calls a label's function (its unit's: a
# unit's foreign methods live there alone, retired once its world is taken)
for (g, cs) in GROUPS, c in cs
    g == "snap" && continue
    local l = string(g, "/", c[1])
    println("ANSWER\t", l, "\t", repr(Base.invoke_in_world(get(WORLD, l, Base.get_world_counter()), c[2], c[3:end]...)))
end
"""

# each refused class: its unit's text and a fragment of the loader's reason that names the class
const REFUSED = [
    ("trycatch", "try\n    Core.getfield((), 1)\ncatch\n    Core.eval(Main, :(const _wt_ran_try = 1))\nend\n", "Core.EnterNode"),
    ("letcatch", "let\n    try\n        Core.getfield((), 1)\n    catch\n        Core.eval(Main, :(const _wt_ran_let = 1))\n    end\nend\n", "Core.EnterNode"),
    ("struct_twice", "struct _NgS; a::Int64; end\nstruct _NgS; a::Float64; end\n", "_NgS"),
    ("const_twice", "const _NG_K = 1\nconst _NG_K = 2\n", "binds _NG_K, which the unit binds already"),
    ("toplevel_call", "println(\"top-level code\")\n", "it calls println at load"),
    ("computed_const", "struct _NgP; x::Int64; y::Int64; end\nconst _NG_P0 = _NgP(0, 0)\n", "it calls Main.U_computed_const._NgP at load"),
    ("convert_global", "struct _NgC end\nBase.convert(::Type{_NgC}, x::Int64) = (Core.eval(Main, :(const _wt_ran_conv = 1)); _NgC())\nglobal _ng_g::_NgC\n_ng_g = 1\n", "convert"),
    ("enum", "@enum _NgColor _ng_red _ng_green\n", "@enum"),
    ("eval", "@eval _ng_ev() = (Core.eval(Main, :(const _wt_ran_eval = 1)); 1)\n", "@eval"),
    ("another_unit", "struct _NgB4 end\nU_honest_a.ha(x::_NgB4) = (Core.eval(Main, :(const _wt_ran_other = 1)); 2)\n", "U_honest_a"),
    ("snapshot_function", "Main.helper(x::Int64) = (Core.eval(Main, :(const _wt_ran_snap = 1)); 3)\n", "helper"),
    ("union_piracy", "struct _NgT end\nBase.getindex(::Type{Any}, ::Union{Tuple,_NgT}, xs...) = (Core.eval(Main, :(const _wt_ran_union = 1)); 1)\n", "piracy"),
    # spec v16 X6: the forms a foreign value reaches stay refused: a Union with a foreign type, a Vararg alone (empty), a
    # Type of a variable (Type{Union{}}), a parameter that is a variable (Vector{Union{}})
    ("own_union", "struct _OuT end\nMain.helper(x::Union{_OuT,Int32}) = 3\n", "piracy"),
    ("own_vararg", "struct _OvT end\nMain._snapv(x::Int64, ys::Vararg{_OvT}) = 4\n", "piracy"),
    ("own_typevar", "struct _OyT end\nMain.helper(x::Type{<:_OyT}) = 5\n", "piracy"),
    ("own_param_var", "struct _OpT end\nMain.helper(x::Vector{<:_OpT}) = 6\n", "piracy"),
    ("typeof_method", "_ng_f(x) = 1\nCore.Typeof(::typeof(_ng_f)) = (Core.eval(Main, :(const _wt_ran_typeof = 1)); Int)\n_ng_f(x::Int64) = 2\n", "Typeof"),
    ("typevar_method", "abstract type _NgA end\n(::Type{TypeVar})(::Symbol, ::Type{_NgA}) = (Core.eval(Main, :(const _wt_ran_tv = 1)); 1)\nstruct _NgV{T<:_NgA} end\n", "TypeVar"),
    ("foreigncall", "const _NG_PID = ccall(:getpid, Cint, ())\n", "foreigncall"),
    ("docstring", "\"a docstring\"\n_ng_doc(x) = x\n", "@doc"),
    ("loop", "while true\nend\n", "lowered statements at load (a loop)"),
    # a label outside [A-Za-z0-9_./-] (spec v17 Y4, red 8c): refused at its registration, located, never far downstream
    ("label_tab", "_g(\"lt\", Any[(\"a\\tb\", (x::Int64) -> x, Int64(1))])\n", "holds a character outside [A-Za-z0-9_./-]"),
    ("label_group", "_g(\"l t\", Any[(\"one\", (x::Int64) -> x, Int64(1))])\n", "a registration whose group is refused"),
    # spec v13 R1: a load that reads its process (round11-red's fz, fz2, fz4, rb with ra; round11-architect's bb with
    # aa, cc, dd, procdep, lp), refused at its read, by what it reads
    ("fz", "if Core.isdefinedglobal(Main, :WasmTarget)\n    _fz(x::Int64) = x * 3\nelse\n    _fz(x::Int64) = x + 1\nend\n_g(\"fz\", Any[(\"one\", (x::Int64) -> _fz(x), Int64(2))])\n", "it reads Main.WasmTarget at load"),
    ("fz2", "_fzf(x::Int64) = x + 1\n_fzw(x::Int64) = x * 3\nif isdefinedglobal(Main, :WasmTarget)\n    const _fzpick = _fzw\nelse\n    const _fzpick = _fzf\nend\n_g(\"fz2\", Any[(\"one\", (x::Int64) -> _fzpick(x), Int64(2))])\n", "it reads Main.WasmTarget at load"),
    ("fz4", "const _fz4n = Core.getfield(Core.getfield(Base.DEPOT_PATH, :size), 1)\n_fz4(x::Int64) = x + _fz4n\n_g(\"fz4\", Any[(\"one\", (x::Int64) -> _fz4(x), Int64(2))])\n", "it reads Base.DEPOT_PATH at load"),
    ("rb", "_rb_own(x::Int64) = x + 1\nif Core.isdefinedglobal(Main, :U_ra)\n    const _rb_pick = Core.getglobal(Core.getglobal(Main, :U_ra), :_ra_f)\nelse\n    const _rb_pick = _rb_own\nend\n_g(\"rb\", Any[(\"one\", (x::Int64) -> _rb_pick(x), Int64(2))])\n", "it reads Main.U_ra at load"),
    ("bb", "_bb_own(x::Int64) = x + 1\nconst _bb_f = Core.isdefinedglobal(Main, :U_aa) ? Core.getglobal(Core.getglobal(Main, :U_aa), :_aa_easy) : _bb_own\n_g(\"bb\", Any[(\"one\", _bb_f, 1)])\n", "it reads Main.U_aa at load"),
    ("cc", "if Core.isdefinedglobal(Main, :WasmTarget)\n    _cc_f(x::Int64) = x * 7\nelse\n    _cc_f(x::Int64) = x + 1\nend\n_g(\"cc\", Any[(\"one\", _cc_f, 1)])\n", "it reads Main.WasmTarget at load"),
    ("dd", "const _dd_n = Core.sizeof(Core.getglobal(Main, :SMOKE_JUDGE_LIKE))\n_dd_f(x::Int64) = x + _dd_n\n_g(\"dd\", Any[(\"one\", _dd_f, 1)])\n", "it reads Main.SMOKE_JUDGE_LIKE at load"),
    ("procdep", "_pd_honest(x::Int64) = x + 1\n_pd_other(x::Int64) = x * 7\nconst _pd_f = Core.isdefinedglobal(Main, :WasmTarget) ? _pd_other : _pd_honest\n_g(\"procdep\", Any[(\"one\", _pd_f, 1)])\n", "it reads Main.WasmTarget at load"),
    # spec v13 R2: a constant is stepped as Julia lowers it; a call of its arithmetic that throws is a located refusal,
    # and a constant aliasing Base's mutable LOAD_PATH is refused at its read (round11-architect p10's alias)
    # spec v13 R3: the heads Julia's lowering gives no thunk for, each refused by its own name (1.12 and 1.13 alike)
    ("module_form", "module _NgM\nend\n", "a `module`"),
    ("export_form", "_ng_ex(x) = x\nexport _ng_ex\n", "an `export`"),
    ("public_form", "_ng_pu(x) = x\npublic _ng_pu\n", "a `public`"),
    ("using_form", "using Base: sin\n", "using"),
    ("const_throws", "const _NG_D = div(1, 0)\n", "which throws a DivideError"),
    ("alias", "const _AL_K = LOAD_PATH\n_al_f(x::Int64) = length(_AL_K) + x\n_g(\"al\", Any[(\"one\", _al_f, 1)])\n", "it reads Base.LOAD_PATH at load"),
    ("lp", "_lp_a(x::Int64) = x + 1\n_lp_b(x::Int64) = x * 7\nconst _lp_f = Core.getfield(Core.getfield(Base.LOAD_PATH, :size), 1) === 1 ? _lp_a : _lp_b\n_g(\"lp\", Any[(\"one\", _lp_f, 1)])\n", "it reads Base.LOAD_PATH at load"),
    # spec v14 V1: a method on a function the unit does not own takes, at some argument, only the unit's own values;
    # a Union with a foreign type, Any and a supertype-bounded variable are refused by name before the method exists
    ("foreign_union", "struct _NgFu end\nMain.helper(x::Union{_NgFu,Int32}) = (Core.eval(Main, :(const _wt_ran_fu = 1)); 2)\n", "a call passing none of the unit's own values"),
    ("foreign_any", "struct _NgFa end\nMain.helper(x::_NgFa) = 2\nMain.helper(x::Any) = (Core.eval(Main, :(const _wt_ran_fa = 1)); 2)\n", "a call passing none of the unit's own values"),
    ("foreign_super", "struct _NgFs end\nMain.helper(x::T) where {T>:_NgFs} = (Core.eval(Main, :(const _wt_ran_fs = 1)); 2)\n", "a call passing none of the unit's own values"),
    # spec v14 W1: a method wider than its foreign function's max_args (which Julia never lowers) is refused by name
    ("foreign_wide", "struct _NgW end\nMain._snapv(a::_NgW, b, c, d, e, f, g, h, i) = (Core.eval(Main, :(const _wt_ran_wide = 1)); 9)\n", "Julia keeps the width a method raises (max_args)"),
    # spec v14 V3: what the digest cannot state is refused, never written lossy (round12-red p1's bf.jl and bi.jl, verbatim:
    # `big"…"` is off the macro table, its value behind a pointer and its expansion reading MPFR's precision); a BigInt
    # made by a call is off the table; Main is never a value of a load
    ("bf", "const _bf_k = big\"0.1\"\nconst _bf_q = big\"1\" / 3\n_g(\"bf\", Any[(\"one\", (x::Int64) -> x + 1, Int64(2))])\n", "a macro off the loader's table (@big_str)"),
    ("bi", "const _bi_k = big\"123456789012345678901234567890\"\n_bi_f(x::Int64) = x + 1\n_g(\"bi\", Any[(\"one\", (x::Int64) -> _bi_f(x), Int64(2))])\n", "a macro off the loader's table (@big_str)"),
    ("bigint_call", "const _NG_BI = BigInt(5)\n", "which the loader's table does not hold: a value computed by a call"),
    ("main_value", "const _NG_M = Base.Main\n_ng_mv(x::Int64) = x\n", "Main as a value: Main is a read target for a snapshot name alone"),
    ("main_bare", "const _NG_M2 = Main\n", "Main as a value: Main is a read target for a snapshot name alone"),
]

# the honest units: each loads and its labels answer as Julia does
const HONEST = [
    ("honest_a", "ha(x) = 1\n_g(\"ng_a\", Any[(\"one\", (x::Int64) -> ha(x) + x, Int64(4))])\n", "ng_a/one" => "5"),
    # the units rb and bb would reach (loaded before them, so a loader that let them read Main would find them)
    ("ra", "_ra_f(x::Int64) = x * 100\n_g(\"ra\", Any[(\"one\", (x::Int64) -> _ra_f(x), Int64(1))])\n", "ra/one" => "100"),
    ("aa", "_aa_easy(x::Int64) = 2\n_g(\"aa\", Any[(\"one\", _aa_easy, 1)])\n", "aa/one" => "2"),
    ("honest_b", "struct _HbP; x::Int64; y::Int64; end\n_hb_sum(p::_HbP) = p.x + p.y\nconst _HB_K = (1, 2, 3)\n_g(\"ng_b\", Any[(\"one\", (n::Int64) -> _hb_sum(_HbP(n, _HB_K[n])), Int64(2))])\n", "ng_b/one" => "4"),
    # spec v13 R2: `2^-1` lowers to Base.literal_pow(^, 2, Val{-1}()), which the stepper runs: 0.5, as a plain include
    ("honest_pow", "const _HP = 2^-1\nconst _HQ = Int32[1, 2]\nconst _HR = -1 * 65536\n_g(\"ng_pow\", Any[(\"one\", (x::Int64) -> _HP * (x + _HQ[2] + _HR), Int64(65534))])\n", "ng_pow/one" => "0.0"),
    # spec v13 R3: a bare `global x` loads on 1.12 as on 1.13 (round11-architect p7's c2): one verdict
    ("honest_global", "global _ng_gx\n_ng_gf(n::Int64) = n\n_g(\"ng_global\", Any[(\"one\", _ng_gf, 3)])\n", "ng_global/one" => "3"),
    ("honest_c", "begin\n    _hc_f(x::Int64) = x * 3\nend\nif true\n    _hc_g(x::Int64) = _hc_f(x) - 1\nend\n_g(\"ng_c\", Any[(\"one\", _hc_g, Int64(5))])\n", "ng_c/one" => "14"),
    # spec v16 X6: a foreign method whose argument is the unit's own by structure loads (OWN_ONLY_FORMS), each form one
    # method, and the case reaches every one: 10 + 20 + 30 + 40 + 50
    ("own_forms", "struct _OwT end\nMain.helper(x::Vector{_OwT}) = 10\nMain.helper(x::Ref{_OwT}) = 20\n" *
                  "Main.helper(x::Pair{_OwT,Int64}) = 30\nMain.helper(x::Tuple{_OwT,Int64}) = 40\n" *
                  "Main.helper(x::S) where {S<:Dict{_OwT,Int64}} = 50\n" *
                  "_g(\"own_forms\", Any[(\"one\", (n::Int64) -> helper(_OwT[]) + helper(Ref(_OwT())) + helper(_OwT() => n) + " *
                  "helper((_OwT(), n)) + helper(Dict{_OwT,Int64}()), Int64(1))])\n", "own_forms/one" => "150"),
    # spec v14 V3: UnionAll's constructor and the keyword slurp's `pairs(NamedTuple)` are a definition's machinery, so
    # `<:` sugar in a signature, a field and a constant, an explicit `where`, and `kw...` load (round12-architect p5's
    # s01, s02, s14, s15, s20): 4 + 1 + 1 + 1 + 4
    ("honest_sugar", "_hs1(x::Vector{<:Integer}) = sum(x)\nstruct _HsS; v::Vector{<:Real}; end\nconst _HS14 = Vector{<:Real}\n" *
                     "const _HS15 = Vector{T} where T<:Real\n_hs20(pos; kw...) = pos + length(kw)\n" *
                     "_g(\"ng_sugar\", Any[(\"one\", (n::Int64) -> _hs1(Int64[n, 1]) + length(_HsS(Float64[n]).v) + (Float64[n] isa _HS14) + (Float64[n] isa _HS15) + _hs20(n; a = 1), Int64(3))])\n",
     "ng_sugar/one" => "11"),
]

# the units in landing order: honest_a, ra and aa first, as another_unit, rb and bb name them
function run_child()
    local dir = mktempdir()
    local paths = String[]
    for (slug, text) in [[(s, t) for (s, t, _) in HONEST[1:3]]; [(s, t) for (s, t, _) in REFUSED]; [(s, t) for (s, t, _) in HONEST[4:end]]]
        local p = joinpath(dir, slug * ".jl")
        write(p, text)
        push!(paths, p)
    end
    local child = joinpath(dir, "child.jl")
    write(child, CHILD)
    return _child(`$(Base.julia_cmd()) --startup-file=no $child $LOADER $paths`, dir)
end
# a child process, its output, under the hard limit
function _child(cmd::Cmd, dir::AbstractString)
    local log = joinpath(dir, "child.out")
    local proc = run(pipeline(Cmd(cmd; dir), stdout = log, stderr = log); wait = false)
    # a hard limit, never a hang (a loader that runs a unit's loop at load would never return): LIMIT seconds against
    # the ~2 s the run takes; past it the child is killed and the file is red, naming it
    local done = timedwait(() -> process_exited(proc), LIMIT) === :ok
    done || (kill(proc); wait(proc))
    local out = read(log, String)
    return done && success(proc), done ? out : out * "\nthe child passed its $(LIMIT) s limit and was killed (a unit ran at load)"
end

# ---- spec v13 R1: a unit's load is the same program in every process. Two children that differ in what a load could
# read of its process (process B: a `WasmTarget` module and other names in Main before the judge's world, other
# lowerings first (so lowering's process-global TypeVar counter differs: `#s2` against `#s7`), the default LOAD_PATH
# against A's `@stdlib`, a two-entry DEPOT_PATH against A's one, its own cwd, and two other units loaded first and the
# honest ones in reverse order) load the same honest units, each printing its unit's digest fields; B also reads A's
# digests and prints the loader's one compare of each with its own load. The planted unit is two texts of one slug
# that differ in one constant (spec v14 V3: no seam in the judge), one to each child: its digests differ and the
# compare names the write that differs.
const DIGEST_CHILD = raw"""
get(ENV, "WT_NEG_EXTRA", "") == "1" && (Core.eval(Main, :(module WasmTarget end)); Core.eval(Main, :(const _neg_extra = 1));
                                         Base.include_string(Main, "_neg_h(a::Ref{<:Real}, b::Vector{<:Integer}) = 1\nstruct _NegS{T<:Real}; v::Vector{<:T}; end\n"))
const GROUPS = Pair{String,Vector{Any}}[]
_g(n, c) = push!(GROUPS, n => c)
_xf(n, c) = push!(GROUPS, n => c)
_register(k, n, c) = (k === :_g ? _g : _xf)(n, c)
include(ARGS[1])
CorpusLoader.judge!(Base.get_world_counter(), Module[CorpusLoader])
helper(x::Int64) = 1
_g("snap", Any[("a", (x::Int64) -> helper(x), Int64(1))])
labels = Set{String}(string(g, "/", c[1]) for (g, cs) in GROUPS for c in cs)
theirs = Dict{String,Vector{String}}()
for l in (isempty(get(ENV, "WT_NEG_THEIRS", "")) ? String[] : readlines(ENV["WT_NEG_THEIRS"]))
    f = split(l, '\t'); f[1] == "DIGEST" && (theirs[f[2]] = String.(f[3:5]))
end
for p in ARGS[2:end]
    u = CorpusLoader._load_units([p]; register = _register, labels)[1]
    union!(labels, u.labels)
    slug = replace(basename(p), r"\.jl$" => "")
    println("DIGEST\t", slug, "\t", join(CorpusLoader.digest_fields(u), '\t'))
    haskey(theirs, slug) && println("COMPARE\t", slug, "\t", something(CorpusLoader.digest_mismatch(theirs[slug], u), "same"))
end
"""
const DIGEST_UNITS = [
    ("two_a", HONEST[1][2]), ("two_b", HONEST[end-1][2]), ("two_c", HONEST[end][2]),
    ("two_param", "abstract type _TwA{T} end\nstruct _TwB{T} <: _TwA{T}; v::T; end\n_tw_get(b::_TwA) = b.v\n_g(\"two_param\", Any[(\"a\", (n::Int64) -> _tw_get(_TwB{Int64}(n)), Int64(3))])\n"),
    ("two_kw", "function _tw_kw(x::Int64; k::Int64 = 2)\n    return x * k\nend\n_g(\"two_kw\", Any[(\"a\", (n::Int64) -> _tw_kw(n; k = 5), Int64(3))])\n"),
    ("two_closure", "_tw_mk(k::Int64) = x -> x + k\nconst _TW_V = Int64[1, 2]\nconst _TW_T = (1, 2.5, \"s\", :sym)\n_g(\"two_closure\", Any[(\"a\", (n::Int64) -> _tw_mk(2)(n) + _TW_V[2], Int64(3))])\n"),
    ("two_where", "struct _TwW{T<:Real}; v::T; end\n_tw_f(w::_TwW{T}) where {T<:Integer} = w.v * 2\nMain.helper(x::_TwW) = 3\n_g(\"two_where\", Any[(\"a\", (n::Int64) -> _tw_f(_TwW(n)) + helper(_TwW(n)), Int64(3))])\n"),
    ("two_sugar", "_tw_s(x::Vector{<:Integer}) = length(x)\nconst _TW_S = Vector{<:Real}\n_tw_k(pos; kw...) = pos + length(kw)\n_g(\"two_sugar\", Any[(\"a\", (n::Int64) -> _tw_s(Int64[n]) + _tw_k(n; a = 1), Int64(3))])\n"),
    ("planted", "const _PL_N = 1\n_pl_f(x::Int64) = x + _PL_N\n_g(\"planted\", Any[(\"one\", _pl_f, Int64(1))])\n"),
]
# the planted unit as process B loads it: the same slug, one constant other
const PLANTED_B = "const _PL_N = 7\n_pl_f(x::Int64) = x + _PL_N\n_g(\"planted\", Any[(\"one\", _pl_f, Int64(1))])\n"
# the two children: A as the answering process is (no WasmTarget, `JULIA_LOAD_PATH=@stdlib`, one depot entry, its own
# units alone), B unlike it in each; returns ((ok, output) of A, of B)
function run_digest_children()
    local dir = mktempdir()
    local paths = Dict{String,String}()
    for (slug, text) in vcat(DIGEST_UNITS, [(s, t) for (s, t, _) in HONEST[1:3] if s in ("ra", "aa")])
        paths[slug] = joinpath(dir, slug * ".jl"); write(paths[slug], text)
    end
    local child = joinpath(dir, "digest_child.jl"); write(child, DIGEST_CHILD)
    local mine = [paths[s] for (s, _) in DIGEST_UNITS]
    local planted_b = joinpath(mkpath(joinpath(dir, "bunits")), "planted.jl"); write(planted_b, PLANTED_B)
    local mine_b = [s == "planted" ? planted_b : paths[s] for (s, _) in DIGEST_UNITS]
    local da, db = mkpath(joinpath(dir, "a")), mkpath(joinpath(dir, "b"))
    local depot = first(DEPOT_PATH)
    local a = _child(addenv(`$(Base.julia_cmd()) --startup-file=no $child $LOADER $mine`,
                            "JULIA_LOAD_PATH" => "@stdlib", "JULIA_DEPOT_PATH" => joinpath(da, "depot") * ":"), da)
    write(joinpath(dir, "theirs.tsv"), a[2])
    local b = _child(addenv(`$(Base.julia_cmd()) --startup-file=no $child $LOADER $(paths["ra"]) $(paths["aa"]) $(reverse(mine_b))`,
                            "JULIA_LOAD_PATH" => "@:@stdlib", "JULIA_DEPOT_PATH" => joinpath(db, "depot") * ":" * depot * ":",
                            "WT_NEG_EXTRA" => "1", "WT_NEG_THEIRS" => joinpath(dir, "theirs.tsv")), db)
    return a, b
end

# ---- spec v14 V1: one program per label. The architect's pair (round12-architect p6): ua adds a method on the
# snapshot's `helper` for its own type; ub calls `helper` on a Vector{Any}'s element. ub's label is typed at its world
# alone (only ub loaded) and beside ua (ua first, as the score loads it): the same typed code, the same answer, since
# ua's method is deleted once ua's world is taken; ua's label still infers and answers at its own world after it
const PAIR_CHILD = raw"""
const GROUPS = Pair{String,Vector{Any}}[]
_g(n, c) = push!(GROUPS, n => c)
_xf(n, c) = push!(GROUPS, n => c)
_register(k, n, c) = (k === :_g ? _g : _xf)(n, c)
include(ARGS[1])
CorpusLoader.judge!(Base.get_world_counter(), Module[CorpusLoader])
helper(x::Int64) = 1
helper(x::Int64, y::Int64) = x + y   # the widest helper: ua's keyword method raises no max_args (spec v14 W1)
_g("snap", Any[("a", (x::Int64) -> helper(x), Int64(1))])
labels = Set{String}(string(g, "/", c[1]) for (g, cs) in GROUPS for c in cs)
strip_(ci) = replace(sprint(show, ci), r"#=[^=]*=#" => "", r"\s+" => " ")
for u in CorpusLoader.load_units(ARGS[2:end]; register = _register, labels), l in u.labels
    local c = only(c for (g, cs) in GROUPS for c in cs if string(g, "/", c[1]) == l)
    local ci, rt = only(Base.code_typed(c[2], Tuple(map(typeof, c[3:end])); world = u.world))
    local sub = Core.getglobal(u.mod, Symbol("_", u.name === :U_ub ? "ub" : "ua_h"))
    local ci2, _ = only(Base.code_typed(sub, (Vector{Any},); world = u.world))
    println("TYPED\t", l, "\t", rt, "\t", bytes2hex(CorpusLoader.SHA.sha256(strip_(ci) * strip_(ci2))), "\t",
            repr(Base.invoke_in_world(u.world, c[2], c[3:end]...)), "\t", hasfield(typeof(u), :foreign) ? length(u.foreign) : -1)
end
# a process loads its units once (spec v16 X3): a second call is refused, before it loads anything
println("SECOND\t", try; CorpusLoader.load_units(ARGS[2:end]; register = _register, labels); "LOADED"; catch e; replace(sprint(showerror, e), r"\s+" => " "); end)
"""
const PAIR = [("ua", "struct _UaT; end\nMain.helper(x::_UaT) = 2.5\n_ua_h(v::Vector{Any}) = helper(v[1])\n" *
                     "Base.length(x::_UaT) = 7\n_ua_kw(x::Int64; k::Int64 = 1) = x + k\nMain.helper(x::_UaT, y::Int64; k::Int64 = 2) = y + k\n" *
                     "_g(\"ua\", Any[(\"one\", (n::Int64) -> helper(_UaT()) + n + _ua_h(Any[_UaT()]) + length(_UaT()) + helper(_UaT(), n; k = 3), Int64(1))])\n"),
              ("ub", "_ub(v::Vector{Any}) = helper(v[1])\n_g(\"ub\", Any[(\"one\", (n::Int64) -> _ub(Any[n]), Int64(1))])\n")]
function run_pair_children()
    local dir = mktempdir()
    local paths = Dict(s => joinpath(dir, s * ".jl") for (s, _) in PAIR)
    foreach(((s, t),) -> write(paths[s], t), PAIR)
    local child = joinpath(dir, "pair_child.jl"); write(child, PAIR_CHILD)
    local alone = _child(`$(Base.julia_cmd()) --startup-file=no $child $LOADER $(paths["ub"])`, mkpath(joinpath(dir, "alone")))
    local beside = _child(`$(Base.julia_cmd()) --startup-file=no $child $LOADER $(paths["ua"]) $(paths["ub"])`, mkpath(joinpath(dir, "beside")))
    return alone, beside
end
end

@testset "the corpus loader's negatives, one fresh process" begin
    local ok, out = CorpusLoaderNegatives.run_child()
    ok || println(out)
    @test ok
    local units = Dict{String,Vector{String}}()
    local answers = Dict{String,String}()
    for l in eachline(IOBuffer(out))
        local a = split(l, '\t')
        a[1] == "UNIT" && (units[a[2]] = a[3:end])
        a[1] == "ANSWER" && (answers[a[2]] = a[3])
    end
    for (slug, _, why) in CorpusLoaderNegatives.REFUSED
        local u = get(units, slug, nothing)
        @test u !== nothing
        u === nothing && continue
        @test u[1] == "REFUSED"
        occursin(why, u[2]) || println("corpus_loader_negatives: ", slug, " refused, but not by its name (", why, "): ", u[2])
        @test occursin(why, u[2])
        @test u[end-1] == "MARKS="          # the unit's forbidden code wrote nothing
        @test u[end] == "JUDGE=truetruetruetruetrue"
    end
    for (slug, _, (label, answer)) in CorpusLoaderNegatives.HONEST
        local u = get(units, slug, nothing)
        @test u !== nothing && u[1] == "LOADED" && u[2] == label
        @test get(answers, label, nothing) == answer
    end
    # spec v16 X6: every foreign value offered to helper at own_forms' world reaches the snapshot's methods alone
    local foreign = [split(l, '\t') for l in eachline(IOBuffer(out)) if startswith(l, "FOREIGN\t")]
    @test length(foreign) == 14 && all(f -> !occursin("U_own_forms", f[3]), foreign)
end

@testset "a unit's load is the same program in every process: its digest (spec v13 R1)" begin
    local (oka, outa), (okb, outb) = CorpusLoaderNegatives.run_digest_children()
    oka || println(outa)
    okb || println(outb)
    @test oka && okb
    local rows(out, k) = Dict(String(f[2]) => f[3:end] for f in (split(l, '\t') for l in eachline(IOBuffer(out))) if f[1] == k)
    local da, db, cmp = rows(outa, "DIGEST"), rows(outb, "DIGEST"), rows(outb, "COMPARE")
    for (slug, _) in CorpusLoaderNegatives.DIGEST_UNITS
        @test haskey(da, slug) && haskey(db, slug)
        (haskey(da, slug) && haskey(db, slug)) || continue
        if slug == "planted"   # one constant differs: the two programs differ, and the compare names that write
            @test da[slug][1] != db[slug][1]
            @test occursin("the program loaded here is not the program answered: planted.jl's write", get(cmp, slug, [""])[1])
            @test occursin("_PL_N", get(cmp, slug, [""])[1])
        else                   # the same text, Julia's build and snapshot: byte-equal digests, the compare silent
            @test da[slug] == db[slug]
            @test get(cmp, slug, [""])[1] == "same"
        end
    end
end

@testset "one program per label: a unit's typed code alone and beside another unit (spec v14 V1)" begin
    local (oka, outa), (okb, outb) = CorpusLoaderNegatives.run_pair_children()
    oka || println(outa)
    okb || println(outb)
    @test oka && okb
    local rows(out) = Dict(String(f[2]) => f[3:end] for f in (split(l, '\t') for l in eachline(IOBuffer(out))) if f[1] == "TYPED")
    local a, b = rows(outa), rows(outb)
    @test haskey(a, "ub/one") && haskey(b, "ub/one") && haskey(b, "ua/one")
    # ub's label: the same return type, typed code and answer alone and beside ua
    @test get(a, "ub/one", nothing) == get(b, "ub/one", nothing)
    @test get(a, "ub/one", [""])[1] == "Int64"
    # ua's label at its own world after its methods were deleted: its own methods serve it (2.5 + 1 + 2.5 + 7 + 4)
    @test get(b, "ua/one", ["", "", "", ""])[3] == "17.0"
    # ua's methods on helper (two, and the keyword method's Core.kwcall) and Base.length: deleted, recorded
    @test get(b, "ua/one", ["", "", "", "", ""])[4] == "4"
    # a second load_units in a process is refused (spec v16 X3: every deletion precedes every compile and answer)
    @test all(occursin("SECOND\tthe corpus loader: load_units was called a second time in this process", o) for o in (outa, outb))
end

# ---- spec v14 V3: climber.md lists what loads and what does not from the loader's one callee table: its block between
# the markers is the table's own text (CorpusLoader.table_markdown), never a second list
@testset "climber.md's list of what a unit may call is the loader's table (spec v14 V3)" begin
    local md = read(normpath(joinpath(@__DIR__, "..", "..", "dev", "climb", "climber.md")), String)
    local m = match(r"<!-- the loader's callee table: test/corpus_loader.jl table_markdown\(\) -->\n(.*?)<!-- end of the table -->"s, md)
    @test m !== nothing
    local gen = read(`$(Base.julia_cmd()) --startup-file=no -e "include(ARGS[1]); print(CorpusLoader.table_markdown())" $(CorpusLoaderNegatives.LOADER)`, String)
    @test m !== nothing && m[1] == gen
end

# ---- spec v14 W1: a deletion restores what Julia keeps of the methods a unit added to functions it does not own. One
# child: the state v14/v1/visit.jl read of each touched function (Main.helper, Base.length, Core.kwcall, for a keyword
# method) taken before the unit loads and after it is loaded and retired: each type name's fields of a bits value
# (max_args among them) and the methods the latest world sees; the method table's entries (Base.visit) are printed apart:
# a deleted method stays an entry with its world range closed, seen by no later world
const RETIRE_CHILD = raw"""
const GROUPS = Pair{String,Vector{Any}}[]
_g(n, c) = push!(GROUPS, n => c)
_xf(n, c) = push!(GROUPS, n => c)
_register(k, n, c) = (k === :_g ? _g : _xf)(n, c)
include(ARGS[1])
CorpusLoader.judge!(Base.get_world_counter(), Module[CorpusLoader])
helper(x::Int64) = 1
helper(x::Int64, y::Int64) = x + y
fs = Any[helper, Base.length, Core.kwcall]
function state()
    local out = Dict{String,Any}()
    for f in fs
        local tn = typeof(f).name
        for n in fieldnames(Core.TypeName)
            isdefined(tn, n) || continue
            local v = getfield(tn, n)
            isbits(v) && (out["$(nameof(f)).$n"] = v)
        end
        # the methods the latest world sees (Core.kwcall's: those of helper, the part a keyword method touches; its
        # whole table, thousands of methods, costs half a minute to enumerate the first time)
        local ft = f === Core.kwcall ? Tuple{typeof(Core.kwcall), NamedTuple, typeof(helper), Vararg{Any}} : Tuple{typeof(f), Vararg{Any}}
        out["$(nameof(f)).methods"] = Set{Any}(Any[x.method.sig for x in Base._methods_by_ftype(ft, -1, Base.get_world_counter())])
    end
    return out
end
entries() = (n = Ref(0); Base.visit(m -> n[] += 1, Core.methodtable); n[])
before, e0 = state(), entries()
p = joinpath(mktempdir(), "rt.jl")
write(p, "struct _RtT; v::Float64; end\nMain.helper(x::_RtT) = 2.5\nMain.helper(x::_RtT, y::Int64; k::Int64 = 2) = y + k\n" *
         "Base.length(x::_RtT) = 7\n_g(\\\"rt\\\", Any[(\\\"one\\\", (n::Int64) -> helper(_RtT(1.0)) + helper(_RtT(1.0), n; k = 3) + length(_RtT(1.0)), Int64(1))])\n")
u = CorpusLoader.load_units([p]; register = _register, labels = Set{String}())[1]
after = state()
println("RETIRED\t", length(u.foreign))
for k in sort(collect(keys(before)))
    println(before[k] == get(after, k, nothing) ? "SAME\t" : "DIFFERS\t", k, "\t", repr(before[k]), "\t", repr(get(after, k, nothing)))
end
println("ENTRIES\t", e0, "\t", entries())
println("ANSWER\t", Base.invoke_in_world(u.world, GROUPS[end][2][1][2], 1))
"""
function run_retire_child()
    local dir = mktempdir()
    local child = joinpath(dir, "retire_child.jl"); write(child, RETIRE_CHILD)
    return CorpusLoaderNegatives._child(`$(Base.julia_cmd()) --startup-file=no $child $(CorpusLoaderNegatives.LOADER)`, dir)
end
@testset "a deletion restores what Julia keeps of a unit's foreign methods (spec v14 W1)" begin
    local ok, out = run_retire_child()
    ok || println(out)
    @test ok
    local rows = [split(l, '\t') for l in eachline(IOBuffer(out)) if startswith(l, r"SAME|DIFFERS|RETIRED|ENTRIES|ANSWER")]
    for r in rows
        r[1] == "DIFFERS" && println("corpus_loader_negatives: retire: ", join(r, " "))
    end
    @test any(r -> r[1] == "RETIRED" && parse(Int, r[2]) == 4, rows)   # helper twice, kwcall, length
    @test !isempty(filter(r -> r[1] == "SAME", rows))
    @test isempty(filter(r -> r[1] == "DIFFERS", rows))
    @test any(r -> r[1] == "ANSWER" && r[2] == "13.5", rows)            # 2.5 + (1 + 3) + 7 at the unit's own world
end
