# llvm/lib/Target/WebAssembly/WebAssemblySortRegion.{h,cpp} at the llvm pin (dev/LEDGER.md D42): the
# regions CFGSort keeps contiguous and CFGStackify bounds, a loop or an exception. Exceptions come
# with WebAssemblyExceptionInfo, ported with try_table's placement; until then a region is a loop,
# and machine_function rejects every try region before a pass runs (src/julia/machine.jl).

"""
    ConcreteSortRegion(unit)

A region over a loop, `unit` (LLVM's ConcreteSortRegion<MachineLoop>): its header, blocks and
membership the loop's.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.h:43 ConcreteSortRegion" struct ConcreteSortRegion
    unit::LoopBase
    ConcreteSortRegion(unit::LoopBase) = new(unit)
end

"""    get_header(r) -> Int"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.h:48 ConcreteSortRegion::getHeader" get_header(r::ConcreteSortRegion)::Int = get_header(r.unit)

"""    contains(r, bb) -> Bool"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.h:49 ConcreteSortRegion::contains" contains(r::ConcreteSortRegion, bb::Int)::Bool = contains(r.unit, bb)

"""    get_num_blocks(r) -> Int"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.h:52 ConcreteSortRegion::getNumBlocks" get_num_blocks(r::ConcreteSortRegion)::Int = get_num_blocks(r.unit)

"""    blocks(r) -> Vector{Int}"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.h:53 ConcreteSortRegion::blocks" blocks(r::ConcreteSortRegion)::Vector{Int} = blocks(r.unit)

"""    is_loop(r) -> Bool

True: a region over a loop (the specialization ConcreteSortRegion<MachineLoop>::isLoop)."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.cpp:11 ConcreteSortRegion::isLoop" is_loop(r::ConcreteSortRegion)::Bool = true

"""
    SortRegionInfo(mli)

The regions of a function, each made once per loop (`loop_map`), over its loop tree `mli`.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.h:61 SortRegionInfo" struct SortRegionInfo
    mli::LoopInfoBase
    loop_map::Dict{LoopBase,ConcreteSortRegion}
    SortRegionInfo(mli::LoopInfoBase) = new(mli, Dict{LoopBase,ConcreteSortRegion}())
end

"""    get_region_for(sri, mbb) -> Union{ConcreteSortRegion,Nothing}

The smallest region holding `mbb`, nothing for a block in none."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.cpp:17 SortRegionInfo::getRegionFor" function get_region_for(sri::SortRegionInfo, mbb::Int)::Union{ConcreteSortRegion,Nothing}
    local ml = get_loop_for(sri.mli, mbb)
    ml === nothing && return nothing
    return get!(() -> ConcreteSortRegion(ml), sri.loop_map, ml)
end

"""    get_bottom(sri, mf, r) -> Int

The region's bottom block, the last in the layout of the blocks its header dominates."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.cpp:45 SortRegionInfo::getBottom" get_bottom(sri::SortRegionInfo, mf::MachineFunction, r::ConcreteSortRegion)::Int =
    get_bottom(sri, mf, r.unit)

"""
    get_bottom(sri, mf, ml) -> Int

The loop's bottom block, its block numbered last; an EH pad in the loop would extend it to its
exception's bottom, which arrives with WebAssemblyExceptionInfo.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.cpp:52 SortRegionInfo::getBottom" function get_bottom(sri::SortRegionInfo, mf::MachineFunction, ml::LoopBase)::Int
    local bottom = get_header(ml)
    for mbb in blocks(ml)
        mf.blocks[mbb].number > mf.blocks[bottom].number && (bottom = mbb)
        mf.blocks[mbb].ehpad && reject!(Unported("llvm/lib/Target/WebAssembly/WebAssemblySortRegion.cpp:72 SortRegionInfo::getBottom"), "SortRegionInfo.getBottom")
    end
    return bottom
end
