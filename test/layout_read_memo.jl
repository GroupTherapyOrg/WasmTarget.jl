using Test
using WasmTarget
using SHA

# The host-layout-read memo lives for one compilation (it is each interpreter's, R40). A
# process-wide memo kept the answer
# an earlier compilation computed for a specialization; after the method was redefined in
# the same session, a type-level call that now reads the host layout (datatype_alignment)
# was still folded, and the module differed from the one a fresh session builds.
Base.@assume_effects :total _wt_lrm_g(::Type{T}, x::Int) where {T} = x + 1
_wt_lrm_f() = _wt_lrm_g(UInt8, 3)

@testset "host-layout-read memo is per compilation" begin
    before = bytes2hex(sha256(WasmTarget.compile(_wt_lrm_f, ())))
    @eval Base.@assume_effects :total _wt_lrm_g(::Type{T}, x::Int) where {T} =
        x + Int(Base.datatype_alignment(T))
    after = bytes2hex(sha256(WasmTarget.compile(_wt_lrm_f, ())))
    # the redefined body reads the host layout, so its call is not folded: the module
    # changes (a stale memo reproduced `before` exactly)
    @test after != before
end
