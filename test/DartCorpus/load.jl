# test/DartCorpus loaded: its precompiled image, one per corpus content for every lane. The package and
# test/smoke_corpus.jl are copied once per content into the repository's common dir, under their content's hash, and
# the cache is written to a depot there, so a landing that does not touch the corpus loads it in about a second and
# one that does builds it once for every lane, Julia's pidfile holding the others. dev/check.sh runs this file
# before the judged load when the change leaves the corpus and the package untouched, so a lane's check never
# builds an image it did not change; test/src/dart_tests.jl includes it. Found through LOAD_PATH, never
# WasmTarget's own Project.
const _DART_CORPUS_HOME = let common = readchomp(`git -C $(@__DIR__) rev-parse --path-format=absolute --git-common-dir`),
                              test = joinpath(@__DIR__, ".."),
                              files = ("smoke_corpus.jl", joinpath("DartCorpus", "Project.toml"), joinpath("DartCorpus", "src", "DartCorpus.jl")),
                              key = string(hash(map(f -> read(joinpath(test, f), String), files)); base = 16),
                              home = joinpath(common, "wt-dart-corpus", key)
    if !isdir(home)
        local tmp = mktempdir(mkpath(joinpath(common, "wt-dart-corpus")); cleanup = false)
        for f in files
            mkpath(dirname(joinpath(tmp, f))); cp(joinpath(test, f), joinpath(tmp, f))
        end
        try mv(tmp, home) catch; rm(tmp; recursive = true, force = true) end   # another lane copied it first
        # the five newest contents kept
        local olds = sort!(filter(d -> d != "depot" && isdir(joinpath(common, "wt-dart-corpus", d)), readdir(joinpath(common, "wt-dart-corpus")));
                           by = d -> -mtime(joinpath(common, "wt-dart-corpus", d)))
        foreach(d -> rm(joinpath(common, "wt-dart-corpus", d); recursive = true, force = true), olds[6:end])
    end
    home
end
const _DART_CORPUS_DEPOT = joinpath(dirname(_DART_CORPUS_HOME), "depot")
isdefined(Main, :wt_progress) && Main.wt_progress("dart_tests.jl: loading DartCorpus from $(_DART_CORPUS_HOME)")
pushfirst!(LOAD_PATH, joinpath(_DART_CORPUS_HOME, "DartCorpus")); pushfirst!(DEPOT_PATH, _DART_CORPUS_DEPOT)
using DartCorpus
popfirst!(DEPOT_PATH); popfirst!(LOAD_PATH)
