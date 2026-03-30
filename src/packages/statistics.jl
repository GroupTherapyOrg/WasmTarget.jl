# ============================================================================
# Statistics Package — Pure Julia implementations for Wasm compilation
# ============================================================================
# These avoid Base._mapreduce closure dispatch which isn't supported yet.

function _stats_mean(v::Vector{Float64})::Float64
    s = 0.0
    for i in Int32(1):Int32(length(v))
        s += v[i]
    end
    return s / Float64(length(v))
end

function _stats_mean_i64(v::Vector{Int64})::Float64
    s = Int64(0)
    for i in Int32(1):Int32(length(v))
        s += v[i]
    end
    return Float64(s) / Float64(length(v))
end

function _stats_var(v::Vector{Float64})::Float64
    n = length(v)
    m = _stats_mean(v)
    s = 0.0
    for i in Int32(1):Int32(n)
        d = v[i] - m
        s += d * d
    end
    return s / Float64(n - 1)
end

function _stats_std(v::Vector{Float64})::Float64
    # Use manual Newton-Raphson sqrt to avoid autodiscovery issue with Base.sqrt
    x = _stats_var(v)
    x <= 0.0 && return 0.0
    guess = x / 2.0
    for _ in Int32(1):Int32(20)
        guess = (guess + x / guess) / 2.0
    end
    return guess
end

function _stats_sum(v::Vector{Float64})::Float64
    s = 0.0
    for i in Int32(1):Int32(length(v))
        s += v[i]
    end
    return s
end

function _stats_minimum(v::Vector{Float64})::Float64
    m = v[1]
    for i in Int32(2):Int32(length(v))
        if v[i] < m
            m = v[i]
        end
    end
    return m
end

function _stats_maximum(v::Vector{Float64})::Float64
    m = v[1]
    for i in Int32(2):Int32(length(v))
        if v[i] > m
            m = v[i]
        end
    end
    return m
end

"""
    register_statistics_package!()

Register Statistics package functions for playground compilation.
Uses pure Julia implementations that compile cleanly to WasmGC.
"""
function register_statistics_package!()
    funcs = Tuple{Any, Tuple}[
        (_stats_mean, (Vector{Float64},)),
        (_stats_mean_i64, (Vector{Int64},)),
        (_stats_var, (Vector{Float64},)),
        (_stats_std, (Vector{Float64},)),
        (_stats_sum, (Vector{Float64},)),
        (_stats_minimum, (Vector{Float64},)),
        (_stats_maximum, (Vector{Float64},)),
    ]
    register_package!(:Statistics, funcs)
    return true
end
