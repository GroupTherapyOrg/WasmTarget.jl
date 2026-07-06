# Changelog

## [0.4.9](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.4.8...v0.4.9) (2026-07-06)


### Bug Fixes

* **march11:** the slot_types FIELD actually lands (the edit had searched without saving) ([cba4ae4](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/cba4ae49eed1afcab0ba884031fd22e7757edcda))

## [0.4.8](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.4.7...v0.4.8) (2026-07-06)


### Bug Fixes

* **march7:** interned Char fields use Julia's LEFT-PACKED bits, not the codepoint (gate-caught) ([98126bd](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/98126bdd6d8adfa5aa1dadeea1629aea46295267))
* **march8:** the Nothing decide-before-emit keeps the SEMANTIC SPLIT — null for concrete refs, the BoxedNothing singleton for generic refs ([b4f2bbf](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/b4f2bbf1fccd68cbaaec679f3465b2783000d034))

## [0.4.7](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.4.6...v0.4.7) (2026-07-06)


### Bug Fixes

* **ratchet:** R15 scoped to values.jl (the lazy creator's segment site is dart-shaped); two marker citations de-jargoned (R11 monotone holds) ([712c7dd](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/712c7ddd2307dfee25b5e978f640f4e720bfbeb4))

## [0.4.6](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.4.5...v0.4.6) (2026-07-06)


### Bug Fixes

* **dev:** gate watchdog threshold 12→25 min — cold precompile false-positive ([87cc686](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/87cc6864cb08651e7fcfb3efa00389295f64e853))
* **dev:** the gate runs in an ISOLATED WORKTREE — dev continues on the main tree (the pipeline mechanics) ([5721b8c](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/5721b8c2ba89d67a0acee8a7684b241c1fadcfcc))

## [0.4.5](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.4.4...v0.4.5) (2026-07-05)


### Bug Fixes

* **march5, F2:** exclude Memory/MemoryRef from the closed-world collector — the _la_sub regression ([3862ba9](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/3862ba9ae07379813734768b284ee04ccc61f8ec))
* **march5, F2:** the closed world COLLECTS, never registers — and the isa bug's SECOND root falls ([9af563c](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/9af563c5e9818da3470fab82c7a417af588d182f))

## [0.4.4](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.4.3...v0.4.4) (2026-07-05)


### Features

* **parity:** the 2026-07-04 certification census — 15 dims scored, ~55% structural parity (was ~25-30%) ([dd98983](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/dd98983e01ced4be3e83057f71823179ea245b56))


### Bug Fixes

* **1.13-rc1:** element-wise builder transfer — works around a Julia 1.13.0-rc1 append! UNDEF-tail bug ([cf0898c](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/cf0898c85c4da037f6ebdf5f13f976b8f75c7837))
* **march4:** emit_int128_sle!/ule! builder forms — the sweep's latent UndefVar (fuzz-caught) ([d78a1b2](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/d78a1b2b3fe5be2905c58e6cf748fe66cc67f1f9))
* **stackifier:** a loop closes at its LAST back-edge source — multi-continue loops miscompiled ([0018e90](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/0018e90c3934bdd0480c9d2b6645cd6a5ee17436))
* **try:** route throw-arm-past-the-leave shapes to THE stackified try driver (silent wrong value) ([1debe19](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/1debe19a4a268a253249a2fc5da10c8d67f5edb7))

## [0.4.3](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.4.2...v0.4.3) (2026-07-03)


### Bug Fixes

* **1.13:** route every io/print + N-way string-concat consumer through the M9 funnel ([39a4537](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/39a45372fb2e1b0269852cec110e3a9fb67ed040))

## [0.4.2](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.4.1...v0.4.2) (2026-07-02)


### Features

* caller-facing diagnostics ledger — compile(...; diagnostics_sink=...) + WasmCompileError.all ([399ad9c](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/399ad9cfc63961f5df55a54e9a023b9ca547f35e))
* caller-facing diagnostics ledger (diagnostics_sink + WasmCompileError.all) ([0b40aaa](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/0b40aaa92e3862c9c44d32d3c92525a88f76d1b0))


### Bug Fixes

* **ci:** docs build — update the cached General registry ([119f77d](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/119f77d85a29596550a4f6f0230d73ffc4bc1784))
* **ci:** docs build — update the cached General registry, not just add it ([7983c26](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/7983c26e33ae2981223c6e88c86a229ab7019b53))

## [0.4.1](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.4.0...v0.4.1) (2026-07-02)


### Bug Fixes

* **1.13-rc1 + windows:** actual-type egal guards · array-rep union join · path-safe ratchet ([10977c2](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/10977c2c1461a2597347bd78dac0f58d33374bb7))

## [0.3.20](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.19...v0.3.20) (2026-06-26)


### Bug Fixes

* skip js() interop intrinsic in closure dep auto-discovery (0.3.19 regression) ([#66](https://github.com/GroupTherapyOrg/WasmTarget.jl/issues/66)) ([6510a24](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/6510a24917241798f186f3003c9b17b840a38732))

## [0.3.19](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.18...v0.3.19) (2026-06-26)


### Features

* interactive in-browser examples + memo dep auto-discovery + faster CI ([#64](https://github.com/GroupTherapyOrg/WasmTarget.jl/issues/64)) ([bfc9c8e](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/bfc9c8e8c7b9fff149fa028709165a18ac75abae))

## [0.3.18](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.17...v0.3.18) (2026-06-26)


### Features

* **sciml:** ForwardDiff integration - first SciML library, 100% in-scope ([#62](https://github.com/GroupTherapyOrg/WasmTarget.jl/issues/62)) ([800e7e6](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/800e7e63cb07a0340fddad89363d726999782b57))

## [0.3.17](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.16...v0.3.17) (2026-06-26)


### Miscellaneous Chores

* re-cut release 0.3.17 (SparseArrays) ([#60](https://github.com/GroupTherapyOrg/WasmTarget.jl/issues/60)) ([68bcf25](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/68bcf25847450740458b83fef36347bfb7e65d12))

## [0.3.16](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.15...v0.3.16) (2026-06-25)


### Features

* **stdlib:** LinearAlgebra integration + ≥95% coverage for LinearAlgebra/Statistics/Dates/Random ([#57](https://github.com/GroupTherapyOrg/WasmTarget.jl/issues/57)) ([aa3258d](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/aa3258d78a9739c34c40e8294acd5386b65fcbab))

## [0.3.15](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.14...v0.3.15) (2026-06-22)


### Miscellaneous Chores

* release WasmTarget 0.3.15 ([da0f8d1](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/da0f8d155f99f35eac055b5f987144f764bd0b51))

## [0.3.14](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.13...v0.3.14) (2026-06-22)


### Miscellaneous Chores

* record sweep gaps + release 0.3.14 ([cf2d431](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/cf2d431f3e5520fc4287f81592e0bb0e61144265))

## [0.3.13](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.12...v0.3.13) (2026-06-22)


### Features

* **codegen:** string(::Vector{Float64}) array-show overlay ([#40](https://github.com/GroupTherapyOrg/WasmTarget.jl/issues/40)) ([95c6a4d](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/95c6a4ddc40bfbef2506fb60f007256fefc4d700))


### Bug Fixes

* **codegen:** reset module-level io/type caches at start of each fresh compile ([#41](https://github.com/GroupTherapyOrg/WasmTarget.jl/issues/41)) ([f677465](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/f6774659fb35151f93b7da5300b64bab8887f8f1))

## [0.3.12](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.11...v0.3.12) (2026-06-20)


### Features

* **codegen:** [v...] splat-collect + array-show overlays (PI 30→33) ([c489c22](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/c489c2202760b8d97287e47f1577778a1665bc6b))
* **codegen:** [v...] splat-collect for Vector + string(::Vector{String}) ([677b1ae](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/677b1ae2cda9679ae6284a7eac07156df6e098ba))
* **codegen:** collect + range-slice for ref-element (String) vectors ([b5fe8e3](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/b5fe8e3de1efcb5d7cfd2dd4897d8e1efe9135c5))
* **codegen:** string(::Vector{Int64}) + string(::Nothing) overlays ([4a09462](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/4a09462fd57f92de48d21313b740920210d9cb81))


### Bug Fixes

* **codegen:** repeat(::Char, n) corrupts multibyte chars (soundness) ([2fc8292](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/2fc82927bff6d1c2a78f50e8fa92c33fdff5f758))

## [0.3.11](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.10...v0.3.11) (2026-06-20)


### Features

* **codegen:** string(::Complex) overlay + PlutoIslands island-fixtures testbed ([ed84425](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/ed844259c475fcc144b8b7188a9f7aa781028c48))
* **codegen:** string(::Complex) via byte-assembly overlay (closes cfd419793b0d) ([a9736ef](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/a9736ef56503c3b8be6b6592aacc450d44972e01))

## [0.3.10](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.9...v0.3.10) (2026-06-18)


### Features

* soundness loop — guardrails, dynamic dispatch on by default, ledger/verify hygiene, PlutoIslands integration ([9e12dc1](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/9e12dc11a2c5bd11857c1d7ddc3bb6298e2bb35a))

## [0.3.9](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.8...v0.3.9) (2026-06-16)


### Bug Fixes

* don't corrupt select_t / if ref-type operands in the wrap fixer ([9a5bf8b](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/9a5bf8b2746d7fa8a4bf6f53326ee9c67a77f8bf))
* don't corrupt select_t / if ref-type operands in the wrap fixer ([5ea46b2](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/5ea46b2f8d36c3f57221f666c890eee3e4a9f7de))

## [0.3.8](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.7...v0.3.8) (2026-06-13)


### Features

* make trim collection the default discovery ([be7ecd4](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/be7ecd41986f7db0fba67e2f714621af6bb50346))

## [0.3.7](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.6...v0.3.7) (2026-06-12)


### Features

* closed-world collection via upstream trim machinery (JuliaLang/julia[#62087](https://github.com/GroupTherapyOrg/WasmTarget.jl/issues/62087) alignment) ([4df8660](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/4df866047a2a2fc2709c6c73221017bb0fa3d686))
* discovery=:trim pipeline — compile_multi via closed-world collection ([b930bdd](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/b930bdda53ffb5c3c4097be006a5fe60cd648304))
* trim pipeline — per-collection cache partitions, entry-scoped strictness, width-matched stub defaults ([1581951](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/158195168cd185d9a3f650b996452bff3c30d390))


### Bug Fixes

* void wrapper blocks for Nothing-return try/catch + trim harness support ([51d3476](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/51d3476139db493c004f5c044d1b25420d538184))

## [0.3.6](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.5...v0.3.6) (2026-06-12)


### Features

* Random groundwork batch 2 — generic-arith anyref unbox, byte-reinterpret overlays, svec/type-intersection folds ([19935b5](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/19935b54ff879a46a521547617d4975db7be1094))
* Random groundwork batch 3 — hash_seed overlay, dynamic eq unbox, cross-width pointerset, dead-flag fix ([0efd531](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/0efd531b86f8a5f8139c124ebcca44e10568bd55))
* Random groundwork batch 4 — cross-width reads, Memory walk terminals, backing-array consolidation ([83ee1f1](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/83ee1f1f987ccc22a54968548d847b3ff3c54365))
* Random stdlib integration — seeded Xoshiro bit-exact on 1.12 (wide-from-narrow reads, offset-faithful pointers) ([e5faa29](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/e5faa2950f7bce9aea78205e710fecfcd483ca2b))


### Bug Fixes

* extend packed array.get_u/get_s results stored to i64 locals (Random seed! path) ([e42d7c8](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/e42d7c8fae9686175cf422b32fd012e6ae7ee931))
* ground-truth local types for boxed-union adapters (Random groundwork) ([9b732ae](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/9b732ae563aaae4db80452cd8582dbedeada4593))

## [0.3.5](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.4...v0.3.5) (2026-06-12)


### Features

* Dates stdlib integration — value layer + WasmTargetDatesExt rendering overlays ([eef47a7](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/eef47a72543f854bcdad5ed421ca3c89784a4457))

## [0.3.4](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.3...v0.3.4) (2026-06-12)


### Features

* fuzz-catalogue Statistics slice + first harvest (7 ledgered Int64-median gaps) ([15b164a](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/15b164a949f28f67a5210def7bd52a6728f3a00a))
* Statistics stdlib pilot — typed pointer machinery, copy handlers, layout folds (7/7 on 1.12, 5/7 on 1.13) ([1e7a7a1](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/1e7a7a1579c8c794d17cad966bbf52dde67bf60a))
* WasmTargetStatisticsExt weakdep extension — Statistics 7/7 on both versions ([e3cbab6](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/e3cbab6ab25efc069c1f9f02b9bbf30acc1881ba))


### Bug Fixes

* catch-arm split with GotoNode skip + merging arms (gap 10cc64efe535) ([9bf8241](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/9bf82417bdef368ef81e60528c74c78bfdc885d0))

## [0.3.3](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.2...v0.3.3) (2026-06-12)


### Bug Fixes

* closure-path compilation of WasmMakie islands — eight codegen fixes (WASMMAKIE-E-003) ([c98db5f](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/c98db5f99d67f6786ff7ad514e8cf2fc91c2ae71))
* closure-path compilation of WasmMakie islands (WASMMAKIE-E-003) ([73c2d01](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/73c2d0182dfeaa3ec6e3f89d19b7e346a1cad64e))

## [0.3.2](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.1...v0.3.2) (2026-06-12)


### Features

* getglobal handler + memmove array.copy (Ryu string(Float64) partial) ([0b44304](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/0b44304a75b4861fdb955d8281b66c04a9bab610))
* pointerref/pointerset over Vector{UInt8} storage pointers ([4026792](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/4026792dabbdde52fb2dea90fa608a322e7edd38))
* String comprehensions via collect-family whitelist ([342df71](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/342df7197f9769782925e5bc46df428f38eb8442))
* string concatenation overlays (_string varargs + String(::SubString)) ([3b577e0](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/3b577e0ccbe29f000be1ed8eff846210e749a202))
* string(::Float64) fully working — DataType layout-metadata folding ([e818f2b](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/e818f2bb9bcb71c06f7f1944c04095993bba0564))
* String*SubString / string-with-Char concat via concrete overlays ([0b24b23](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/0b24b23986fbe40db294daaaaa03c4d68d24bdc6))


### Bug Fixes

* branch-split dispatch picks the outermost spanning branch ([75e0560](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/75e0560024de928697253e5c3fcf1ef465983326))
* dead-return peephole misparsed LEB immediate as END opcode (gap 4c8236022172) ([3fd53cf](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/3fd53cf555cb515554f6b99aca8e230b48371ebd))
* if/else split inside outer try body (nested generator $else wrap) ([4757cfa](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/4757cfab70d3b0e2a3e24aedbffc6bd4c584bf06))
* Matrix types no longer registered with the Vector layout ([0556e48](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/0556e482dda889cdc514f6513e2bc63ec1f84247))
* merge-phi catch-try chains routed to new generator (gap ff6dc9760825) ([1fa9ad8](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/1fa9ad8959e5fe20267b34308dc9c1fa27f99231))
* narrow-int canonicalization in zext_int and signed shift results (gap da22976c7cd6) ([2a6915b](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/2a6915b2884317937117660f1a4da1636e83edc1))
* nested-try merge phis — skip branch lands at the merge ([1db16e7](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/1db16e730a26d0a8317bfd77a317a65ab10b5c42))
* recursive merge-phi catch-try chains (gap 73a575f2d651) ([bbff623](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/bbff6230fa62e7098848bdc0b199d25a42a88db0))
* reset stub flag before compiling the exit-branch condition ([533dffa](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/533dffab31efa4c69fe0645d02391f6ff1bb7cc5))
* shrinking resize! via _deleteend! overlay ([7be8ed9](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/7be8ed96b30f42906044100d5a219830c92ec805))
* sinh/cosh large-x precision — half-exponent squaring above H_LARGE_X ([0eb612c](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/0eb612c270223608c666edfdb668f99134065e70))
* struct_get type-check scan misread local.get 379 as struct.get ([f255a91](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/f255a9168bd1d4af190e0224a48e0eeabc818ab0))

## [0.3.1](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.3.0...v0.3.1) (2026-06-11)


### Features

* catch-arm branch-split generator (if/else with inner try inside catch) ([13e88b0](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/13e88b0cd9cbb903bd59f449be58ea2d3835c2c9))
* Float64 ranges, round(digits=), range broadcasts (WASMMAKIE W-002) ([78b1586](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/78b158663f3b7b420e31b44c14a0a27359e26450))
* Julia 1.13 support alongside 1.12 — CI matrix + docs ([dc36264](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/dc3626471ce443ac644a5655c08b37061aa93df9))
* Ryu writefixed/writeexp scalar overlays (WASMMAKIE W-004) ([5aeb98d](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/5aeb98d9b9727a17c3bdcc84c7844ef370053de4))


### Bug Fixes

* byte-vector in() memchr overlay + version-aware mod(x, Inf) semantics ([9b3ea5b](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/9b3ea5bcf59ff02de7d903c8fff4d5becff11525))
* catch-arm control flow + trunc_int width normalisation ([8a34688](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/8a34688ee5c7cb968e8c0dae451c19a7168bc244))
* forward-parse instruction boundaries in trailing type-safety checks ([0d5c88c](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/0d5c88cce2fd83137f082d285c3a432dff3b0948))
* Julia 1.13 String hashing, sinc/cosc evaluator, version-tolerant kwarg-body whitelist ([adbe30d](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/adbe30dee0263cfd88ef74065c4b44404104a7a3))
* nested-try generator fully stackified + normal-path skip block ([365a14e](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/365a14e9acb0f3c0fc6224d6fe0d54d3e3320bfc))
* sitofp narrow sign-extension + catchable Union{}-rettype invokes ([4166d8e](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/4166d8e0338c328843a0695f85e9584d7e75f7e7))
* stackify nested-try pre-outer and between-enter segments ([ff6eccc](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/ff6eccc7277b14101ee66cf24fe3d5024e924ce5))

## [0.3.0](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.2.1...v0.3.0) (2026-06-11)


### ⚠ BREAKING CHANGES

* ledger at 0 open. Full Pkg.test green.
* 4 closed, 0 still open. Full Pkg.test green.
* 7 closed, 0 still open. Full Pkg.test green.
* 2 closed, 0 still open. Full Pkg.test green.
* 4 closed across the batch, 0 still open. Full Pkg.test green.

### verify_gaps

* 2 closed, 0 still open. Full Pkg.test green. ([12976a2](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/12976a24aa9cb3da464a3a9e5d124de4293850c9))
* 4 closed across the batch, 0 still open. Full Pkg.test green. ([3c1caf4](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/3c1caf4f0e75cb349c4d189acc1aab7b029e98bf))
* 4 closed, 0 still open. Full Pkg.test green. ([7a1d4d1](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/7a1d4d149d54f24d061657d4b4a95f2e248abb68))
* 7 closed, 0 still open. Full Pkg.test green. ([2737229](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/2737229d73d4651f545b6852852fda75482601c4))
* ledger at 0 open. Full Pkg.test green. ([4cf486b](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/4cf486b2794ebf4b7818fda61da69aa4720863d6))


### Bug Fixes

* branches leaving a compiled block subset now route to an exit block ([12976a2](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/12976a24aa9cb3da464a3a9e5d124de4293850c9))
* byte-level wrap-stripping pass no longer desyncs on GC instructions; ([2737229](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/2737229d73d4651f545b6852852fda75482601c4))
* closures defined in Main now compile when invoked un-inlined; two new ([3c1caf4](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/3c1caf4f0e75cb349c4d189acc1aab7b029e98bf))
* lcm overflow throws catchably; Union{}-containing rettypes recognised ([4cf486b](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/4cf486b2794ebf4b7818fda61da69aa4720863d6))
* Phase 2 complete — try/catch soundness overhaul, 0 open divergences (batches 21-26) ([ecda643](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/ecda643b8adb250569db2dd72f130feab775d64f))
* try/catch machinery soundness overhaul + zero-divergence coverage matrix ([f8d1054](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/f8d1054fdf7ec2cfe8b934078787a01c8cc17f6c))
* un-inlined always-throwing invokes compile as catchable throws; if/else ([7a1d4d1](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/7a1d4d149d54f24d061657d4b4a95f2e248abb68))

## [0.2.1](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.2.0...v0.2.1) (2026-06-11)


### Features

* promote the fuzz oracle bridge to WasmTarget.Bridge ([27ed4a3](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/27ed4a35a2b0d23067192ea31016b2724b4d1080))
* promote the fuzz oracle bridge to WasmTarget.Bridge ([dca789a](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/dca789a4df78ab54ece25db007916315af9f1142))

## [0.2.0](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.1.1...v0.2.0) (2026-06-10)


### ⚠ BREAKING CHANGES

* strict-by-default soundness + differential combinatorial fuzzer (0.2.0)

### Features

* **fuzz:** add Dict/Set/Char/reduce categories + natural-sig sweep (inventory grows) ([a6ce229](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/a6ce229e8fcc8055c5ff92d731d6ff9dab51b738))
* **fuzz:** coverage metric + collect op ([f9123a4](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/f9123a43ecd3f1241ee42255b18d8a5c1b56c92f))
* **fuzz:** expand generator to ~146 ops + lazy construction for depth ≥4 ([8c86cb7](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/8c86cb79f7399382d88e5c356bfc956abb615ae2))
* **fuzz:** expand generator to vectors/strings/mixed-types + higher-order ops ([53f9d71](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/53f9d71c74a1073e1f6acc8a7dbf5c6e1425d9f0))
* **fuzz:** make generator TYPE-PARAMETRIC over the full lattice (168 → 538 ops) ([115c730](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/115c730a4329f354e17824a0d497864e2efb6cb0))
* **fuzz:** natural-signature fuzzing (Vector args) + depth-4 sweep inventory ([cb1670f](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/cb1670fabecc54d3ea4abb7cd6c12914bfde937e))
* **fuzz:** preserve hand-authored gap analysis across re-records ([3116117](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/311611731839ae94ca48bf5425f63274da13bee7))
* **fuzz:** vector marshalling — test functions in NATURAL signatures ([56c5a89](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/56c5a89c73f9da08ee194bd8298af705f7147223))
* strict-by-default soundness + differential combinatorial fuzzer (0.2.0) ([b2ee465](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/b2ee4654bb219b45a941f7ecd4687a1b32ce7060))


### Bug Fixes

* **codegen:** Julia-semantics integer shift (over-shift guard) ([3faf657](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/3faf6570da081f2e48c5b714346ef930eb4c1f84))
* **fuzz:** harden apparatus — eliminate false positives (mutation aliasing + NaN-vector compare) ([455218b](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/455218b66655f30dfd36f4bfeee843ebe16612aa))
* **overlay:** argmax/argmin NaN poisoning (return first NaN index) ([a25dc94](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/a25dc947058949250bbdc5e3982e893d7e79d852))
* **overlay:** argmax/argmin signed-zero tiebreak ([d363a81](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/d363a8193817740401256c92adeae819fd7fee97))
* **overlay:** Dict literal constructor (closes all 18 Dict gaps) ([1f33cc6](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/1f33cc6657ad9edc524c989b5aea979f30bc45ce))
* **overlay:** exact fmod for rem/mod(Float64) + Float32 exp/exp2/exp10 redirect ([5d1f028](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/5d1f0282de7bd08c27df8243f67f178b73beeff1))
* **overlay:** first/last(Vector) bounds-check on empty ([ad48bb9](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/ad48bb94d67866784fa0aed51815e4515a61b002))
* **overlay:** float mod/rem fmod-faithful at Inf/zero divisors ([35018fa](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/35018fa0e3632c57a1654ebb642d3dd9e11f5660))
* **overlay:** maximum/minimum signed comparison + NaN (closes maximum∘sort class) ([4b5e29b](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/4b5e29bd4ac58f4ca422a231c55c643169337894))
* **overlay:** startswith/endswith accept SubString (AbstractString) operands ([a3cfc97](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/a3cfc975d4dcca49f120ebc3e766dffb336842f3))
* **overlay:** string(Int64) typemin (negation overflow) ([968bebe](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/968bebeeef577eab2bb9e7d9cff8c0a57cd94349))
* **overlay:** unique dedups NaN (NaN-aware equality) ([fff920a](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/fff920a9f079626d8625f7c13ac11a9d93a63787))
* **overlay:** unique(Vector{Float}) keeps ±0.0 distinctly (isequal semantics) ([70b4cd6](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/70b4cd6bd869cb70680e16476bf79a46c87e4250))

## [0.2.0] - 2026-06-05

### ⚠ BREAKING CHANGES

* **`strict=true` is now the default** for `compile`/`compile_multi`. Constructs that
  would compile to a *wrong value* (`objectid`/`jl_object_id`, non-zero `memset`) now
  raise `WasmCompileError` (with the offending construct + source location) instead of
  emitting a silently-incorrect stub. Sound traps on dead error-branches still compile.
  Pass `strict=false` to restore the previous permissive behavior.

### Features

* Source-attributed diagnostics: `WasmDiagnostic`, `WasmCompileError`, and a single
  `record_unsupported!` choke point for every "give up" site (`src/codegen/diagnostics.jl`).
* **`validate=true` default**: every compiled module is checked with `wasm-tools validate`
  and a reject raises `WasmValidationError` (was previously unvalidated / `@warn` only).
* Type-directed differential fuzzer under `test/fuzz/` (Supposition.jl): generates
  well-typed compositions, checks native-vs-wasm, auto-shrinks counterexamples, persists
  a `DirectoryDB` corpus, and documents each finding as a self-reproducing, auto-closing
  "gap" in `test/fuzz/failures/`. A bounded pass runs in CI.

### Bug Fixes

* `jl_object_id` no longer returns a constant `42` / array length (a silently-wrong
  identity hash); non-zero `memset` no longer silently mis-fills.

## [0.1.1](https://github.com/GroupTherapyOrg/WasmTarget.jl/compare/v0.1.0...v0.1.1) (2026-04-20)


### Bug Fixes

* ship codegen + JSON 1.x migration fixes ([1f0ed5e](https://github.com/GroupTherapyOrg/WasmTarget.jl/commit/1f0ed5e35d7bf254a8e8ede9e057731813cdff8c))
