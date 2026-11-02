# dev/tree_instructions.jl — the instructions retired by a command's whole process tree, for D14's band
#
#   julia dev/tree_instructions.jl <out> <command...>   runs the command, writes the tree's instructions (G) to <out>,
#                                                       exits with the command's status
#   julia dev/tree_instructions.jl --plant              a tree whose grandchild does fixed work, at default and at
#                                                       background QoS: the grandchild counted, and both inside the band;
#                                                       exits 1 otherwise
#
# The load stage precompiles WasmTarget in a child process of `julia -e 'using WasmTarget'` (Base.compilecache), and
# rusage reports a process's own instructions alone, never its children's (A54E1), so its CPU seconds were judged,
# which an efficiency core doubles (13 and 28 CPU-s for the same precompile, 2026-11-01). Each process of the tree
# now reports its own counter as it exits: a library inserted into every process the command starts
# (DYLD_INSERT_LIBRARIES, inherited by each child, the precompile among them) reads proc_pid_rusage's
# ri_instructions (rusage_info_v4, the counter /usr/bin/time -l reports as "instructions retired") in its
# destructor, which exit() runs after everything else the process does, Julia's writing of the package image
# included (jl_atexit_hook writes it, then exit), and writes it to a file named by its pid. The tree's count is
# their sum, exact for every process that exits by exit(); one killed by a signal writes none, and the command fails.
# A protected system binary (taskpolicy, git) has the loader strip DYLD_ variables, so it and what it starts are not
# counted, a few milliseconds in the load. A process reports only when its binary admits inserted libraries: julia's hardened runtime carries
# com.apple.security.cs.allow-dyld-environment-variables, and the plant fails if a julia grandchild goes uncounted.
#
# precedent(gnu: LD_PRELOAD interposition, the dynamic loader's own way to run code in every process of a tree, as
# libfaketime and the sanitizers' runtimes use it; macOS's DYLD_INSERT_LIBRARIES is its counterpart). Julia's
# differs: none; this reads the kernel's counter at each process's exit.
#
# Its limit: Apple's counters retire fewer instructions for the same work on an efficiency core (a fixed loop, alone:
# 9.7 to 10.2 G at default QoS, 8.2 G at background, 2026-11-01), so a stage read on efficiency cores reads up to about
# a third low, the shards' and the ratchet's as the load's; the plant's band states it.

const COUNTER_C = """
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <unistd.h>
__attribute__((destructor)) static void wt_tree_count(void) {
    const char *dir = getenv("WT_TREE_COUNT_DIR");
    if (dir == NULL) return;
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return;
    char path[2048];
    snprintf(path, sizeof path, "%s/%d", dir, getpid());
    FILE *f = fopen(path, "w");
    if (f == NULL) return;
    fprintf(f, "%llu\\n", (unsigned long long)ri.ri_instructions);
    fclose(f);
}
"""

# the inserted library, built once per source into the tree's .wtd
function counter_library()::String
    local dir = joinpath(dirname(@__DIR__), ".wtd")
    mkpath(dir)
    local lib = joinpath(dir, "tree_count_$(string(hash(COUNTER_C); base = 16)).dylib")
    isfile(lib) && return lib
    local src = lib * ".c"
    write(src, COUNTER_C)
    run(`clang -O2 -dynamiclib -o $lib $src`)
    return lib
end

# run `cmd` with every process of its tree reporting its instructions at exit; their sum in G and the process
function tree_instructions(cmd::Cmd)::Tuple{Float64,Base.Process}
    local lib = counter_library()
    local counts = mktempdir()
    local p = run(ignorestatus(addenv(cmd, "DYLD_INSERT_LIBRARIES" => lib, "WT_TREE_COUNT_DIR" => counts)))
    local total = UInt64(0)
    for f in readdir(counts; join = true)
        total += parse(UInt64, strip(read(f, String)))
    end
    rm(counts; recursive = true)
    return total / 1e9, p
end

# a child that spawns a grandchild doing fixed work: counted whole, and inside the band on either core type
function plant()::Vector{String}
    local work = `$(Base.julia_cmd()) --startup-file=no -e 'f(n) = (s = UInt(0); for i in UInt(1):n; s = hash(i, s); end; s); f(UInt(10^8)) == 0 && println(0)'`
    local tree = `$(Base.julia_cmd()) --startup-file=no -e "run($(repr(work)))"`
    local normal = first(tree_instructions(tree))
    # taskpolicy is a protected system binary, so the loader strips DYLD_ variables from it and from what it starts: the
    # counter itself runs under it, and inserts its library below it
    local out = tempname()
    run(`taskpolicy -b $(Base.julia_cmd()) --startup-file=no $(@__FILE__) $out $tree`)
    local background = parse(Float64, strip(read(out, String)))
    rm(out)
    local alone = first(tree_instructions(`$(Base.julia_cmd()) --startup-file=no -e 0`))
    local faults = String[]
    # the grandchild's loop is G beyond a bare julia's start: a tree read without it reads no more than that
    normal > alone + 1 || push!(faults, "the grandchild's work is not counted ($(round(normal; digits = 2)) G against a bare start's $(round(alone; digits = 2)))")
    # band: half the default reading. Apple's counters read fewer instructions on an efficiency core, and a default-QoS
    # process lands on one when the performance cores are busy: four runs of this tree read 7.38 to 10.51 G at default
    # and 7.46 to 9.53 at background, the widest pair 29% apart, 2026-11-02; CPU seconds read two to three times
    abs(background - normal) <= BAND * normal || push!(faults, "the tree at background QoS read $(round(background; digits = 2)) G, at default $(round(normal; digits = 2))")
    isempty(faults) && println("tree_instructions: the plant reads $(round(normal; digits = 2)) G at default QoS and $(round(background; digits = 2)) at background, a bare start $(round(alone; digits = 2))")
    return faults
end
const BAND = 0.5

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
