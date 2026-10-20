# shared: classify profile samples of the current process into compile / node / wasm-tools / other
using Profile
function _classify(st)
    s = join(st, ";")
    occursin("run_driver", s) && return "node(run_driver)"
    occursin("validate_wasm_bytes", s) && return "wasm-tools validate"
    occursin("_compile@", s) && return "wt-compile"
    occursin("compile_with_sourcemap", s) && return "wt-compile"
    occursin("compile_multi", s) && return "wt-compile"
    occursin("first_divergence", s) && return "locate"
    occursin("typeinf", s) && return "inference(other)"
    return "other"
end
function report_profile(title)
    data, ldict = Profile.retrieve()
    names = Dict{UInt64,String}()
    for (ip, frames) in ldict
        names[ip] = join((string(fr.func, "@", basename(string(fr.file))) for fr in frames), ";")
    end
    counts = Dict{String,Int}(); cur = String[]; total = 0
    for x in data
        if x == 0
            if !isempty(cur)
                k = _classify(cur); counts[k] = get(counts, k, 0) + 1; total += 1
            end
            empty!(cur)
        else
            push!(cur, get(names, x, ""))
        end
    end
    println("== profile split: ", title, " (", total, " samples)")
    for (k, v) in sort(collect(counts); by = last, rev = true)
        println("   ", rpad(k, 24), lpad(v, 7), "  ", round(100v / max(total, 1); digits = 1), "%")
    end
end
