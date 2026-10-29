# llvm/lib/Target/WebAssembly/WebAssemblySortRegion.{h,cpp} at the llvm pin (dev/LEDGER.md D42): the
# regions CFGSort keeps contiguous and CFGStackify bounds, a loop or an exception
# (WebAssemblyExceptionInfo, src/llvm/exception_info.jl).

"""
    ConcreteSortRegion(unit)

A region over a loop or an exception, `unit` (LLVM's ConcreteSortRegion<MachineLoop> and
ConcreteSortRegion<WebAssemblyException>): its header, blocks and membership the unit's.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.h:43 ConcreteSortRegion" struct ConcreteSortRegion
    unit::Union{LoopBase,WebAssemblyException}
    ConcreteSortRegion(unit::Union{LoopBase,WebAssemblyException}) = new(unit)
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

False for a region over an exception (ConcreteSortRegion's isLoop), true for one over a loop (the
specialization ConcreteSortRegion<MachineLoop>::isLoop, WebAssemblySortRegion.cpp:11)."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.h:56 ConcreteSortRegion::isLoop" is_loop(r::ConcreteSortRegion)::Bool = r.unit isa LoopBase

"""
    SortRegionInfo(mli, wei)

The regions of a function, each made once per loop (`loop_map`) or exception (`exception_map`),
over its loop tree `mli` and its exception tree `wei`.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.h:61 SortRegionInfo" struct SortRegionInfo
    mli::LoopInfoBase
    wei::WebAssemblyExceptionInfo
    loop_map::Dict{LoopBase,ConcreteSortRegion}
    exception_map::IdDict{WebAssemblyException,ConcreteSortRegion}
    SortRegionInfo(mli::LoopInfoBase, wei::WebAssemblyExceptionInfo) =
        new(mli, wei, Dict{LoopBase,ConcreteSortRegion}(), IdDict{WebAssemblyException,ConcreteSortRegion}())
end

"""    get_region_for(sri, mbb) -> Union{ConcreteSortRegion,Nothing}

The smallest region holding `mbb`, a loop or an exception, nothing for a block in none. An
exception holds the blocks of all its subregions, a loop not always (a block with no path back to
the header is outside it though its header dominates it), so the loop is the smaller when the
exception holds the loop's header."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.cpp:17 SortRegionInfo::getRegionFor" function get_region_for(sri::SortRegionInfo, mbb::Int)::Union{ConcreteSortRegion,Nothing}
    local ml = get_loop_for(sri.mli, mbb)
    local we = get_exception_for(sri.wei, mbb)
    ml === nothing && we === nothing && return nothing
    if (ml !== nothing && we === nothing) || (ml !== nothing && we !== nothing && contains(we, get_header(ml)))
        # If the smallest region containing MBB is a loop
        return get!(() -> ConcreteSortRegion(ml), sri.loop_map, ml)
    else
        # If the smallest region containing MBB is an exception
        return get!(() -> ConcreteSortRegion(we), sri.exception_map, we)
    end
end

"""    get_bottom(sri, mf, r) -> Int

The region's bottom block, the last in the layout of the blocks its header dominates."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.cpp:45 SortRegionInfo::getBottom" get_bottom(sri::SortRegionInfo, mf::MachineFunction, r::ConcreteSortRegion)::Int =
    is_loop(r) ? get_bottom(sri, mf, get_loop_for(sri.mli, get_header(r))::LoopBase) :
                 get_bottom(sri, mf, get_exception_for(sri.wei, get_header(r))::WebAssemblyException)

"""
    get_bottom(sri, mf, ml) -> Int

The loop's bottom block, its block numbered last; an EH pad in the loop extends it to its
exception's bottom, a loop not holding every block its header dominates.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.cpp:52 SortRegionInfo::getBottom" function get_bottom(sri::SortRegionInfo, mf::MachineFunction, ml::LoopBase)::Int
    local bottom = get_header(ml)
    for mbb in blocks(ml)
        mf.blocks[mbb].number > mf.blocks[bottom].number && (bottom = mbb)
        if mf.blocks[mbb].ehpad
            local ex_bottom = get_bottom(sri, mf, get_exception_for(sri.wei, mbb)::WebAssemblyException)
            mf.blocks[ex_bottom].number > mf.blocks[bottom].number && (bottom = ex_bottom)
        end
    end
    return bottom
end

"""    get_bottom(sri, mf, we) -> Int

The exception's bottom block, its block numbered last."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblySortRegion.cpp:72 SortRegionInfo::getBottom" function get_bottom(sri::SortRegionInfo, mf::MachineFunction, we::WebAssemblyException)::Int
    local bottom = get_header(we)
    for mbb in blocks(we)
        mf.blocks[mbb].number > mf.blocks[bottom].number && (bottom = mbb)
    end
    return bottom
end
