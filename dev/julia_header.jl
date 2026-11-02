# dev/julia_header.jl — the julia's header in a cached verdict's key (dev/cache_key.sh), one definition: its
# commit, its build's tagged commit, its machine and its cache flags, the header Base checks in an image
# (julia/base/loading.jl:4049 stale_cachefile). dev/cache_key.sh prints it from the julia on PATH; the ratchet,
# whose verdicts its own process computes, includes it and passes its own header as the script's argument.
julia_header()::String = string(Base.GIT_VERSION_INFO.commit, " ", Base.GIT_VERSION_INFO.tagged_commit, " ",
                                Sys.MACHINE, " ", ccall(:jl_cache_flags, UInt8, ()))
if abspath(PROGRAM_FILE) == @__FILE__
    print(julia_header())
end
