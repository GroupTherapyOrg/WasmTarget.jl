using Test
using WasmTarget

@noinline _wt_parent_is_main(m::Module)::Bool = parentmodule(m) === Main
_wt_base_parent_entry()::Bool = _wt_parent_is_main(Base)

@noinline _wt_name_is_base(m::Module)::Bool = nameof(m) === :Base
_wt_base_name_entry()::Bool = _wt_name_is_base(Base)

@noinline _wt_name_deprecated(tn::Core.TypeName)::Bool =
    Base.isdeprecated(tn.module, tn.name)
_wt_int_deprecated_entry()::Bool = _wt_name_deprecated(Int.name)

@noinline _wt_visible_from_main(tn::Core.TypeName)::Bool =
    WasmTarget._closed_world_isvisible(tn.name, tn.module, Main)
_wt_int_visible_entry()::Bool = _wt_visible_from_main(Int.name)

@testset "interned Module metadata" begin
    for (f, expected) in ((_wt_base_parent_entry, true),
                          (_wt_base_name_entry, true),
                          (_wt_int_deprecated_entry, Base.isdeprecated(Int.name.module, Int.name.name)),
                          (_wt_int_visible_entry, Base.isvisible(Int.name.name, Int.name.module, Main)))
        @test f() == expected
        bytes = WasmTarget.compile(f, (); validate=true)
        @test run_wasm(bytes, string(nameof(f))) == Int(expected)
    end
end
