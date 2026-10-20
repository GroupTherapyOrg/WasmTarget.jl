include(joinpath(@__DIR__, "prof_classify.jl"))
ENV["WT_SMOKE_PART"] = replace(ARGS[1], "smoke " => "")
const T0 = time()
include(joinpath(pwd(), "test", "smoke.jl"))
println("load ", round(time() - T0; digits=1), " s")
Profile.init(n = 10^8, delay = 0.005)
t1 = time()
Profile.@profile for (group, cases) in _smoke_part(GROUPS)
    for case in cases
        name = case[1]; f = case[2]; args = case[3:end]; tag = "$group/$name"
        try
            haskey(CASE_INPUTS, tag) ? compare_julia_wasm_inputs(f, CASE_INPUTS[tag]; admit=_rc_admit) :
                isempty(args) ? compare_julia_wasm(f) : compare_julia_wasm(f, args...)
        catch e
            println("ERR $tag")
        end
    end
end
println("cases ", round(time() - t1; digits=1), " s")
report_profile("smoke part " * replace(ARGS[1], "smoke " => ""))
