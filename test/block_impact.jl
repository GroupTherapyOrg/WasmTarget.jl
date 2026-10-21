# The blocking gate's selections, measured (dev/block.jl, test/block_groups.tsv; L194): which
# pieces of src/ each probe and each smoke group runs, and from that the probe core, the smoke
# core and each src file's smoke groups.
#
#   julia --code-coverage=@src --code-coverage="$TMPDIR/block_impact.info" --project=. test/block_impact.jl [<sets.tsv>]
#   julia --project=. test/block_impact.jl --from <sets.tsv>   # the selections from sets measured before
#
# (the second flag sends the process's own coverage, written at exit, to a tracefile instead of a
# .cov file beside every source file). Each probe of test/probe_corpus.jl is compiled as
# test/probe_bytes.jl compiles it and each smoke case run as test/smoke.jl runs it, with Julia's
# line coverage of src/ cleared before and written after (lcov): a probe's or a group's set is the
# pieces of src/ whose lines it ran, a piece being BLOCK_LINES lines of a top-level definition of a
# src/ file (inside a module, its definitions), `<file>:<name>#<k>`, the k-th from the definition's
# first line, so a long function is many pieces (calls.jl's compile_call! is thousands of lines) and
# a short one is one. It prints, as test/block_groups.tsv takes them:
#   probes   the greedy cover of every piece any probe runs (the probe running the most pieces not
#            yet run, then the next; a tie to the earlier probe)
#   core     the greedy cover by pieces per second of the pieces the smoke groups run, up to
#            CORE_SECONDS seconds (a group's cost is its recorded seconds, test/smoke_times.tsv's
#            1.12 column, the median for a group it lacks; a tie to the earlier group)
#   <file>   for each src file, the groups that cover, by the same rule up to FILE_SECONDS seconds,
#            pieces some group runs and the core does not (`-` when the core runs them all)
# With a path, the measured lines are also written there (a line per probe or group: its name, then
# the lines of src/ it ran), so `--from` recomputes the selections without measuring again.
# A changed piece of src/ is then run by a probe and, where any group reaches it, a group the gate
# runs, as of this recording; the full lanes run everything on every landed head. Without
# --code-coverage the script refuses: no line would count.

const FROM = length(ARGS) == 2 && ARGS[1] == "--from" ? ARGS[2] : ""
const SETS_OUT = isempty(FROM) && length(ARGS) == 1 ? ARGS[1] : ""

using WasmTarget

isempty(FROM) && Base.JLOptions().code_coverage == 0 && (println("block_impact: run with --code-coverage=@src"); exit(2))
# Coverage counts the lines WasmTarget's own code runs (codegen instruments them); Julia's optimizer
# would also mark coverage in the IR WasmTarget compiles, wherever an overlay from src/ is inlined
# into it, and that IR is the input the probes fingerprint and smoke runs (a `:code_coverage_effect`
# rejects): in this process the optimizer marks none, so each case compiles the IR it always does.
Core.eval(Core.Compiler, :(should_insert_coverage(mod::Module, debuginfo::Core.DebugInfo) = false))

const CORE_SECONDS = 30.0
const FILE_SECONDS = 25.0
const BLOCK_LINES = 40
const SRC = normpath(joinpath(@__DIR__, "..", "src"))

include(joinpath(@__DIR__, "probe_corpus.jl"))
include(joinpath(@__DIR__, "smoke.jl"))   # GROUPS; its main() runs only when it is the program

# the name a top-level definition gives, or nothing (a struct, a const, a using)
function defname(ex)
    ex isa Expr || return nothing
    ex.head === :macrocall && return defname(ex.args[end])
    if ex.head in (:function, :(=)) && !isempty(ex.args)
        sig = ex.args[1]
        while sig isa Expr && sig.head in (:where, :(::))
            sig = sig.args[1]
        end
        sig isa Expr && sig.head === :call || return nothing
        f = sig.args[1]
        f isa Expr && f.head === :curly && (f = f.args[1])
        return string(f)
    end
    return nothing
end

# line => piece key, for every line of every top-level definition of the file
function line_keys(path::String)::Dict{Int,String}
    rel = relpath(path, dirname(SRC))
    out = Dict{Int,String}()
    function walk(args, stop)
        items = [(args[i].line, args[i+1]) for i in 1:length(args)-1 if args[i] isa LineNumberNode]
        for (k, (l, ex)) in enumerate(items)
            last = k < length(items) ? items[k+1][1] - 1 : stop
            if ex isa Expr && ex.head === :module
                walk(ex.args[3].args, last)
                continue
            end
            n = defname(ex)
            n === nothing && continue
            for x in l:last
                out[x] = "$rel:$n#$((x - l) ÷ BLOCK_LINES)"
            end
        end
    end
    walk(Meta.parseall(read(path, String); filename = path).args, countlines(path))
    return out
end

const KEYS = Dict{String,Dict{Int,String}}()
for (d, _, fs) in walkdir(SRC), f in fs
    endswith(f, ".jl") && (KEYS[relpath(joinpath(d, f), dirname(SRC))] = line_keys(joinpath(d, f)))
end
const INFO = tempname() * ".info"

# the lines of src/ (`<file>` => lines) `f()` runs
function covered(f)::Dict{String,Set{Int}}
    ccall(:jl_clear_coverage_data, Cvoid, ())
    f()
    ccall(:jl_write_coverage_data, Cvoid, (Cstring,), INFO)
    out = Dict{String,Set{Int}}(); file = ""
    for l in eachline(INFO)
        if startswith(l, "SF:")
            file = relpath(normpath(l[4:end]), dirname(SRC))
        elseif startswith(l, "DA:") && haskey(KEYS, file)
            ln, c = parse.(Int, split(l[4:end], ',')[1:2])
            c > 0 && push!(get!(out, file, Set{Int}()), ln)
        end
    end
    return out
end
merge_lines!(a, b) = (for (f, ls) in b; union!(get!(a, f, Set{Int}()), ls); end; a)
pieces(lines) = Set{String}(KEYS[f][l] for (f, ls) in lines for l in ls if haskey(KEYS[f], l))

# greedy: the entry gaining the most of `left` per unit of cost, ties to the earlier, while the
# budget allows
function cover(sets::Vector{Pair{String,Set{String}}}, cost::Vector{<:Real}, left::Set{String}, budget)
    left = copy(left); out = String[]; spent = 0
    while !isempty(left)
        gains = [length(intersect(last(sets[i]), left)) for i in eachindex(sets)]
        ok = [i for i in eachindex(sets) if gains[i] > 0 && spent + cost[i] <= budget]
        isempty(ok) && break
        i = argmax(j -> (gains[j] / cost[j], -j), ok)
        push!(out, first(sets[i])); spent += cost[i]; setdiff!(left, last(sets[i]))
    end
    return out, left
end

function measure()
    probes = [name => covered(() -> WasmTarget.to_bytes(WasmTarget.compile_module([(f, argtypes, name)])))
              for (name, (f, argtypes)) in CASES]
    groups = Pair{String,Dict{String,Set{Int}}}[]
    for (g, cases) in GROUPS
        lines = Dict{String,Set{Int}}()
        for c in cases
            merge_lines!(lines, covered(() -> (length(c) > 2 ? compare_julia_wasm(c[2], c[3:end]...) : compare_julia_wasm(c[2]))))
        end
        push!(groups, g => lines)
    end
    rm(INFO; force = true)
    if !isempty(SETS_OUT)
        open(SETS_OUT, "w") do io
            for (kind, sets) in (("probe", probes), ("group", groups)), (n, lines) in sets
                println(io, kind, '\t', n, '\t', join([f * ":" * join(sort(collect(ls)), ',') for (f, ls) in sort(collect(lines); by = first)], ' '))
            end
        end
    end
    return probes, groups
end

function load_sets(path)
    probes = Pair{String,Dict{String,Set{Int}}}[]; groups = Pair{String,Dict{String,Set{Int}}}[]
    for l in eachline(path)
        f = split(l, '\t')
        lines = Dict{String,Set{Int}}()
        for part in split(f[3])
            file, ls = split(part, ':')
            lines[String(file)] = Set(parse.(Int, split(ls, ',')))
        end
        push!(f[1] == "probe" ? probes : groups, String(f[2]) => lines)
    end
    return probes, groups
end

function main()
    plines, glines = isempty(FROM) ? measure() : load_sets(FROM)
    probes = [n => pieces(l) for (n, l) in plines]
    groups = [n => pieces(l) for (n, l) in glines]
    pu = reduce(union, last.(probes); init = Set{String}())
    pcore, _ = cover(probes, ones(Int, length(probes)), pu, typemax(Int))
    # a group's cost: its recorded seconds (test/smoke_times.tsv, 1.12), the median for one it lacks
    rec = Dict{String,Float64}()
    for l in eachline(joinpath(@__DIR__, "smoke_times.tsv"))
        f = split(l, '\t'); (startswith(l, '#') || length(f) != 3) && continue
        t = tryparse(Float64, f[1]); t === nothing || (rec[String(f[3])] = t)
    end
    med = sort(collect(values(rec)))[(length(rec) + 1) ÷ 2]
    secs = [get(rec, first(g), med) for g in groups]
    su = reduce(union, last.(groups); init = Set{String}())
    core, uncovered = cover(groups, secs, su, CORE_SECONDS)
    pick(c) = findfirst(g -> first(g) == c, groups)
    println("block_impact: $(length(probes)) probes run $(length(pu)) pieces of src/, $(length(pcore)) cover them; ",
            "$(length(groups)) smoke groups run $(length(su)), the core's $(length(core)) groups ",
            "($(sum(length(GROUPS[pick(c)][2]) for c in core; init = 0)) cases, $(round(sum(secs[pick(c)] for c in core; init = 0.0); digits = 1)) s recorded) run $(length(su) - length(uncovered))")
    println("probes\t", join(pcore, ' '))
    println("core\t", join(core, ' '))
    for file in sort(unique(first.(split.(collect(uncovered), ':'))))
        left = Set(k for k in uncovered if startswith(k, file * ":"))
        gs, rest = cover(groups, secs, left, FILE_SECONDS)
        println(file, "\t", isempty(gs) ? "-" : join(gs, ' '), isempty(rest) ? "" : "\t# $(length(rest)) of its pieces past $FILE_SECONDS s")
    end
    return 0
end

exit(main())
