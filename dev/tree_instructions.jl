# dev/tree_instructions.jl — the instructions retired by a command's whole process tree, for D14's band
#
#   julia dev/tree_instructions.jl <out> <command...>   runs the command, writes the tree's instructions (G) to <out>,
#                                                       exits with the command's status
#   julia dev/tree_instructions.jl --plant              the same small tree at default and at background QoS reads the
#                                                       same G, and its grandchild's work is counted; exits 1 otherwise
#
# The load stage precompiles WasmTarget in a child process of `julia -e 'using WasmTarget'` (Base.compilecache),
# and rusage reports a process's own instructions alone, never its children's (A54E1), so dev/check.sh judged the
# load by CPU seconds, which an efficiency core doubles: the same precompile read 13 CPU-s on a performance core
# and 28 on efficiency cores, 2026-11-01, its own instructions unchanged (61.4 and 61.8 CPU-s at background QoS
# for 582e6e0a and the head, back to back). Here every process of the tree is read while it runs: macOS's
# proc_pid_rusage (rusage_info_v4's ri_instructions, the counter /usr/bin/time -l reports as "instructions
# retired"), each descendant found by proc_listchildpids, every POLL seconds; a process's count is its last
# reading, so the count misses at most the POLL seconds before each process exits (at most a few hundredths of a
# G on a performance core). An efficiency core reads up to about a fifth fewer instructions for the same work
# (Apple's counters, measured in the plant's band), never the doubling its CPU seconds show.
const POLL = 0.002   # seconds between readings; band: a reading costs microseconds, the loss per process ~0.01 G

# a process's instructions retired, or nothing once it is gone (rusage_info_v4: ri_instructions is the 30th 64-bit
# field after the 16-byte ri_uuid)
function instructions(pid::Integer)::Union{UInt64,Nothing}
    local info = zeros(UInt64, 40)
    ccall(:proc_pid_rusage, Cint, (Cint, Cint, Ptr{UInt64}), pid, 4, info) == 0 || return nothing
    return info[2 + 29 + 1]
end

# the process's children (libproc's proc_listchildpids answers a count of pids)
function children(pid::Integer)::Vector{Cint}
    local buf = zeros(Cint, 256)
    local n = ccall(:proc_listchildpids, Cint, (Cint, Ptr{Cint}, Cint), pid, buf, sizeof(buf))
    return n <= 0 ? Cint[] : buf[1:min(n, length(buf))]
end

# run `cmd`, reading its whole tree every POLL seconds; the tree's instructions in G and the command's process
function tree_instructions(cmd::Cmd)::Tuple{Float64,Base.Process}
    local last = Dict{Cint,UInt64}()
    local p = run(cmd; wait = false)
    local root = Cint(getpid(p))
    local read_tree() = begin
        local todo = Cint[root]
        while !isempty(todo)
            local q = pop!(todo)
            local i = instructions(q)
            i === nothing && continue
            last[q] = max(i, get(last, q, UInt64(0)))
            append!(todo, children(q))
        end
    end
    local t = Timer(_ -> read_tree(), 0; interval = POLL)
    wait(p)
    close(t)
    return sum(values(last); init = UInt64(0)) / 1e9, p
end

# a child that spawns a grandchild doing fixed work: counted whole, and alike on any core
function plant()::Vector{String}
    local work = `$(Base.julia_cmd()) --startup-file=no -e 'f(n) = (s = UInt(0); for i in UInt(1):n; s = hash(i, s); end; s); f(UInt(10^8)) == 0 && println(0)'`
    local tree = `$(Base.julia_cmd()) --startup-file=no -e "run($(repr(work)))"`
    local normal = first(tree_instructions(tree))
    local background = first(tree_instructions(`taskpolicy -b $tree`))
    local alone = first(tree_instructions(`$(Base.julia_cmd()) --startup-file=no -e 0`))
    local faults = String[]
    # the grandchild's loop is G beyond a bare julia's start: a tree read without it reads no more than that
    normal > alone + 1 || push!(faults, "the grandchild's work is not counted ($(round(normal; digits = 2)) G against a bare start's $(round(alone; digits = 2)))")
    # band: 30%. Apple's counters retire fewer instructions for the same loop on an efficiency core (this loop, alone:
    # 9.7 to 10.2 G at default QoS, 8.2 G at background, 2026-11-01), and a julia's threads vary; CPU seconds double
    abs(background - normal) <= 0.30 * normal || push!(faults, "the tree at background QoS read $(round(background; digits = 2)) G, at default $(round(normal; digits = 2))")
    isempty(faults) && println("tree_instructions: the plant reads $(round(normal; digits = 2)) G at default QoS and $(round(background; digits = 2)) at background, a bare start $(round(alone; digits = 2))")
    return faults
end

function main(args::Vector{String})::Int
    if args == ["--plant"]
        local faults = plant()
        isempty(faults) || println(join(faults, "; "))
        return isempty(faults) ? 0 : 1
    end
    length(args) >= 2 || (println(stderr, "usage: julia dev/tree_instructions.jl <out> <command...> | --plant"); return 2)
    local g, p = tree_instructions(Cmd(args[2:end]))
    write(args[1], string(round(g; digits = 2), "\n"))
    return p.exitcode
end

exit(main(ARGS))
