---------------------------- MODULE ExceptionStack ----------------------------
(***************************************************************************)
(* A TLA+ model of WT's lowering of Julia's exception stack (try regions,  *)
(* catch, the_exception, pop_exception, rethrow;                           *)
(* src/codegen/statements.jl, generate.jl, stackified.jl, compile.jl)      *)
(* against Julia's own (task.c throw_internal, jl_rethrow,                 *)
(* jl_rethrow_other; rtutils.c jl_excstack_state, jl_restore_excstack;     *)
(* codegen.cpp's enter and pop_exception; julia.h JL_TRY/JL_CATCH), within *)
(* a call and across the host's calls, including the re-entrant ones a     *)
(* host-declared import makes.                                             *)
(*                                                                         *)
(* JULIA. Each task has a stack of exceptions. A throw pushes its          *)
(* exception and jumps to the innermost handler; one object thrown twice   *)
(* is two entries (J3). An `enter` records the stack's depth;              *)
(* `pop_exception` restores that depth. `the_exception` reads the top,     *)
(* `nothing` when the stack is empty. `rethrow()` raises the top without   *)
(* pushing; `rethrow(e)` overwrites the top with `e` and raises it without *)
(* pushing; either at depth 0 throws ErrorException ("rethrow() not        *)
(* allowed outside a catch block", or "rethrow(exc) …"), which pushes as   *)
(* every throw does. Leaving a try body normally, and landing in a catch,  *)
(* leave the stack as it is. The stack belongs to the task, so it outlives *)
(* a call. The host is the catching frame of the call it makes: its JL_TRY *)
(* records jl_excstack_state at the call's entry and its JL_CATCH ends in  *)
(* jl_restore_excstack (julia.h:2548 and :2555, Julia 1.12.7). So a        *)
(* top-level call starts with an empty stack whatever the previous call    *)
(* did (J1). A re-entrant call (the host calls an export from inside a     *)
(* host import an open call made) starts with its caller's stack; if its   *)
(* exception propagates through the import into the caller's catch, that   *)
(* catch reads it, and if the host catches it, the stack is back to the    *)
(* callee's entry depth (J2). A call that returns normally has popped      *)
(* every region it entered.                                                *)
(*                                                                         *)
(* WT (Impl = "cells"). An entry of the stack is a cell (exn, stack): its  *)
(* exception and the stack trace its throw captured, with no link to the   *)
(* entry below; nothing reads below the top except through a top an enter  *)
(* saved (exc_cell_type!, generate.jl). The top is one global, `$exc_top`. *)
(* A throw pushes a cell and raises the tag with (exn, stack, cell): the   *)
(* entry travels with the unwind. A rethrow raises the top cell's payload  *)
(* without pushing; an enter saves the top pointer; a pop_exception        *)
(* restores it; the_exception reads the top cell; `rethrow(e)` writes the  *)
(* top cell's exn. A cell is an entry of Julia's stack and a pointer its   *)
(* depth. Every catch landing sets the top to the payload's cell. A region *)
(* is dart's legacy try, whose catch of the tag delivers the payload at    *)
(* the try's end (stackified.jl); no variable or action here depends on    *)
(* that form.                                                              *)
(*                                                                         *)
(* THE BOUNDARY. The host owns the count of open calls of host-declared    *)
(* imports: the glue a host instantiates with (host_glue_js, generate.jl)  *)
(* wraps every host-declared import in `open++; try { f() } finally {      *)
(* open-- }` and hands the module `open` as its imported global            *)
(* `wasmtarget.host_imports_open`, which no wasm code writes. Its finally  *)
(* runs on every exit of the import's frame, whatever the escape           *)
(* (GlueFinally), so the count is exact at every point. The glue hands     *)
(* each wrapped import and the count out once, to the instantiation that   *)
(* reads them, and a second read throws: one glued object serves one       *)
(* instance, and the host cannot call a glued import itself, so the count  *)
(* is this instance's open import calls (HostCallsGlued = FALSE). At the   *)
(* boundary WT touches the top at three points (emit_direct_call!,         *)
(* emit_export_entry!): a call of a host-declared import stores the top at *)
(* index count of `$import_tops` before it (ImportCall), and after a       *)
(* normal return, the glue's finally having brought the count back, sets   *)
(* the top from index count (ReturnRestores); and every export's entry is  *)
(* a prologue that sets the top (inside a call, a push, a landing and      *)
(* pop_exception write it too): at the count 0,                            *)
(* or in a module with no count (HasImport = FALSE), the call is top-level *)
(* and nulls the top (TopLevelReset); otherwise it is re-entrant and takes *)
(* the top at index count - 1, the top at the open import's call           *)
(* (EntryTakesSlot). A landing takes its top by identity. Nothing is       *)
(* restored when an escape leaves a call: a stale top lives only until the *)
(* next of those points, and no wasm code that reads it runs in between    *)
(* (the frames the escape skipped are gone, and JS does not touch it).     *)
(*                                                                         *)
(* ESCAPES. Four kinds: the tag (a Julia throw), a foreign exception (a JS *)
(* exception a host-declared import throws, ImportThrows), stack           *)
(* exhaustion ("exhaust": the engine's RangeError for a stack overflow,    *)
(* raised in wasm code or in an import that overflows the JS stack,        *)
(* ImportExhausts; in a re-entrant call's wasm code, ExhaustReentrant),    *)
(* and a trap. A Julia region catches only the tag (L101), so every other  *)
(* kind unwinds every Julia frame of the call; no wasm construct catches   *)
(* stack exhaustion or a trap, legacy catch_all, catch of the imported     *)
(* JSTag and catch_all_ref alike (measured on Node 22.23.3 and Node        *)
(* 26.11.0). The glue's finally sees every kind. When an escape leaves a   *)
(* re-entrant call, the host either catches it inside the import (the      *)
(* import then returns normally, or the host calls again; a trap,          *)
(* HostCatchesTrap) or lets it propagate through the import into the       *)
(* caller (a trap, PropagatesTrap), or, having caught it, throws the same  *)
(* exception again later inside the same import (HostReraise: a host       *)
(* `finally` that calls an export first): a Julia host's throw pushes it,  *)
(* and WT's landing takes the payload's cell, the one run in which the     *)
(* landing's identity is what makes the top right. An escape from a        *)
(* top-level call is caught by the host. The host contract discards an     *)
(* instance that trapped as policy, a trap not being Julia's error         *)
(* (host_glue_js states it); the claim holds on the runs where the host    *)
(* goes on.                                                                *)
(*                                                                         *)
(* THE CLAIM. On every run of host calls (nested at most MaxCalls deep),   *)
(* each a program of nested try, catch, rethrow and host-declared import   *)
(* calls (bounded by MaxFrames and MaxSteps), every `the_exception` read   *)
(* and every raised value is Julia's (Agrees, read in every state of the   *)
(* run, so over every call), for every kind of escape. Outside it are two  *)
(* rows of dev/MARCH.md 13.17. H8: Julia raises a StackOverflowError that  *)
(* a Julia catch catches, which WT's RangeError is not, so the model lets  *)
(* stack exhaustion unwind every region on Julia's side too and does not   *)
(* claim the catch. H11 (ReraiseShared), pinned as an instance that        *)
(* violates the claim: a host that re-raises an escape whose payload's     *)
(* cell existed when the call it left was entered, so the cell is an entry *)
(* of the caller's stack (the callee rethrew its caller's entry); Julia's  *)
(* host throw pushes a second entry, WT's landing takes the shared cell,   *)
(* so a later `rethrow(e)` overwrites both where Julia overwrites one. A   *)
(* re-raise of a cell the callee pushed, rethrown in it or not, is inside  *)
(* the claim.                                                              *)
(*                                                                         *)
(* The Broken instances, each a realistic mistake: the count lowered only  *)
(* on a normal return (GlueNormalOnly: an escape through the import        *)
(* strands it, and the next top-level call is taken as re-entrant); a      *)
(* re-entrant entry that keeps the top it finds (EntryKeepsTop: inside one *)
(* import the host catches a re-entrant escape and calls again); no        *)
(* restore after an import's normal return (NoReturnRestore: the host      *)
(* catches a re-entrant escape and the import returns); the payload        *)
(* dropped at the landing (Landing = "drop", NoLandingIdentity, H5); the   *)
(* landing finding its entry by ref.eq on the exception (Landing =         *)
(* "value", ValueIdentity, A12P2: the same object thrown twice is one      *)
(* cell); no reset at a top-level entry (NoTopLevelReset, A12B1); every    *)
(* entry nulling the top (ResetAtEntry); a glued import the host calls     *)
(* itself, or one glued object two instances share, so the count holds a   *)
(* call no call of this module made (HostCallsGlued, A14E1 = A14P1: the    *)
(* host calls a glued import after o(0n), native 2, wasm 1); an export     *)
(* with no entry (KeepsEntry); the value-save lowering (Impl =             *)
(* "values"); a rethrow at                                                 *)
(* depth 0 that throws the top (RethrowChecksDepth = FALSE); a push at the *)
(* catch's landing instead of at the throw (PushAtLanding). ReraiseShared  *)
(* pins H11 above.                                                         *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Two exception values. A cell's stack slot is *)
(* left out, and a cell is its exn alone: the claim is about exception     *)
(* values, not stack traces. A stack does not always travel with its       *)
(* value: `rethrow(e)` writes the top cell's exn while the cell keeps the  *)
(* stack its throw captured, as Julia's jl_rethrow_other keeps the         *)
(* backtrace, so whether `rethrow(e)` keeps its throw's stack is outside   *)
(* the claim (L145 and test/source_maps.jl "rethrow(e) keeps its throw's   *)
(* stack" pin it). `$import_tops` is a                                     *)
(* sequence indexed by the count from 0, grown to hold index count before  *)
(* the store, as the code grows its array; a slot past the count keeps its *)
(* last value, as the array does. Control flow is the frame stack the      *)
(* lowering sees: an open try body, an open catch body, an open call of a  *)
(* host-declared import; `return`/`break` out of a catch is its            *)
(* pop_exception (Julia's lowering emits one), a finally is a catch that   *)
(* ends in rethrow(). Julia's side, too, lets a foreign exception unwind   *)
(* every region to the host (the host's exception is not Julia's;          *)
(* dev/MARCH.md 13.17 A13E3), and lets stack exhaustion unwind every       *)
(* region to the host (H8 above). Calls inside the module are direct calls *)
(* of the inner functions, which share the frame stack and need no entry.  *)
(*                                                                         *)
(* formal(src/codegen/statements.jl compile_statement!): a try region's    *)
(* enter, catch, pop_exception, the_exception and rethrow answer as        *)
(* Julia's exception stack (emit_throw_value!, emit_rethrow!,              *)
(* emit_current_exception!, ensure_exception_top_global!, exc_saved_local! *)
(* in generate.jl; the region's enter and pop_exception in statements.jl;  *)
(* the catch landing in stackified.jl).                                    *)
(*                                                                         *)
(* formal(src/codegen/generate.jl emit_export_entry!, emit_direct_call!,   *)
(* host_glue_js; the one-time export in src/codegen/compile.jl): every     *)
(* escape leaves the stack as Julia's host leaves it, except dev/MARCH.md  *)
(* 13.17 H11 (pinned by MCExceptionStackReraiseSharedBroken); H8 is        *)
(* outside the model.                                                      *)
(*                                                                         *)
(* parity(quarantine: Julia's per-task exception stack outlives a call;    *)
(* the host is the catching frame that restores its depth,                 *)
(* jl_restore_excstack; Julia's stack entries have identity and outlive an *)
(* unwind; dart's catch state is lexical, code_generator.dart:2966         *)
(* visitRethrow, and its tag carries (exception, stackTrace),              *)
(* tags.dart:37.)                                                          *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Vals, MaxFrames, MaxSteps, MaxCalls,
          Impl,               \* "cells" (the port) or "values" (the value-save lowering)
          RethrowChecksDepth, \* FALSE = a rethrow at depth 0 throws the top
          PushAtLanding,      \* TRUE = a catch's landing pushes, not the throw
          KeepsEntry,         \* TRUE = an export has no entry: no reset, no slot taken
          ResetAtEntry,       \* TRUE = every entry nulls the top, a re-entrant one too
          Landing,            \* "identity" (top := payload cell), "drop" (the payload is
                              \* dropped), "value" (ref.eq on the exn, else push)
          TopLevelReset,      \* a top-level entry nulls the top
          GlueFinally,        \* the glue lowers the count in a finally (FALSE: only on a
                              \* normal return)
          ReturnRestores,     \* an import's normal return sets the top from its slot
          EntryTakesSlot,     \* a re-entrant entry takes the top from the open import's slot
          HasImport,          \* the module has a host-declared import (and the count)
          ImportThrows,       \* a host-declared import may throw a foreign exception
          HostCatchesTrap,    \* the host may catch a re-entrant trap inside the import
          PropagatesTrap,     \* the host may let a re-entrant trap propagate through it
          ImportExhausts,     \* a host-declared import may overflow the JS stack
          ExhaustReentrant,   \* a re-entrant call's wasm code may exhaust the stack
          ReraiseShared,      \* the host may re-raise an escape whose cell its caller's stack holds
          HostCallsGlued      \* the host may call a glued import outside every call of the module

Nothing == "nothing"
ErrR == "errR"   \* ErrorException("rethrow() not allowed outside a catch block")
ErrO == "errO"   \* ErrorException("rethrow(exc) not allowed outside a catch block")
AllVals == Vals \cup {Nothing, ErrR, ErrO}
Kinds == {"tag", "foreign", "exhaust", "trap"}

VARIABLES frames,   \* the open try, catch and import frames of every open call, innermost last
          calls,    \* the host's open calls, innermost last
          pending,  \* an escape that left a re-entrant call, at the host inside the import
          spec,     \* Julia's exception stack
          cells,    \* WT's cells: a sequence of [exn] (no link); a pointer is an index, 0 is null
          top,      \* WT's `$exc_top`
          cnt,      \* the glue's count, `wasmtarget.host_imports_open`
          slots,    \* WT's `$import_tops`: slots[i + 1] is index i, the top (and, Impl =
                    \* "values", `$current_exn`) at a call made with the count at i
          cur,      \* Impl = "values": the one `$current_exn`
          obsS, obsI,  \* the last observation, Julia's and WT's
          steps
vars == <<frames, calls, pending, spec, cells, top, cnt, slots, cur, obsS, obsI, steps>>

\* a host call: Julia's depth at its entry (the host's jl_excstack_state), and the frames below
\* it (its caller's, ending in the caller's import frame)
Call == [depth : Nat, base : Nat, ncells : Nat]
Slot == [ptr : Nat, val : AllVals]
\* an escape at the host: its kind, Julia's and WT's values, the payload's cell, the depth
\* the host's JL_CATCH restores, and whether the payload's cell is shared: it existed when the
\* call it left was entered, so it is an entry of the caller's stack (a rethrow of it)
Pending == [kind : Kinds \cup {"none"}, sv : AllVals, iv : AllVals, pc : Nat, depth : Nat,
            shared : BOOLEAN]
None == [kind |-> "none", sv |-> Nothing, iv |-> Nothing, pc |-> 0, depth |-> 0, shared |-> FALSE]
\* a try or catch body: Julia's depth at its enter, WT's top and `$current_exn` there; an
\* import's frame: the escape the host caught inside it and holds, if any
Frame == [kind : {"try", "catch", "import"}, depth : Nat, ptr : Nat, val : AllVals, held : Pending]
ImportFrame == [kind |-> "import", depth |-> 0, ptr |-> 0, val |-> Nothing, held |-> None]

TypeOK == /\ frames \in Seq(Frame) /\ calls \in Seq(Call) /\ pending \in Pending
          /\ spec \in Seq(AllVals) /\ cells \in Seq([exn : AllVals])
          /\ top \in Nat /\ cnt \in Nat /\ slots \in Seq(Slot) /\ cur \in AllVals
          /\ steps \in Nat

\* the run begins at the top level, with no call open
Init == /\ frames = <<>> /\ calls = <<>> /\ pending = None
        /\ spec = <<>> /\ cells = <<>> /\ top = 0 /\ cnt = 0 /\ slots = <<>> /\ cur = Nothing
        /\ obsS = <<"start">> /\ obsI = <<"start">> /\ steps = 0

JuliaTop == IF spec = <<>> THEN Nothing ELSE spec[Len(spec)]
WTTop == IF Impl = "values" THEN cur ELSE IF top = 0 THEN Nothing ELSE cells[top].exn

InCall == calls # <<>>
\* the frames below the innermost call belong to its caller
Base == IF calls = <<>> THEN 0 ELSE calls[Len(calls)].base
Last == frames[Len(frames)]
\* the innermost call runs: no escape at the host, no import of its own open
Running == /\ InCall /\ pending.kind = "none"
           /\ IF Len(frames) = Base THEN TRUE ELSE Last.kind # "import"
\* the innermost call is inside a host-declared import, with no call of the host's open
ImportOpen == /\ InCall /\ pending.kind = "none"
              /\ Len(frames) > Base /\ Last.kind = "import"

\* `$import_tops` index i, read (TLC refuses an index never stored: the code's array.get traps)
SlotAt(i) == slots[i + 1]

\* the innermost open try body of the innermost call in frame stack fr, 0 when there is none
HandlerIn(fr) == LET ks == {k \in (Base + 1)..Len(fr) : fr[k].kind = "try"} IN
                 IF ks = {} THEN 0 ELSE CHOOSE k \in ks : \A j \in ks : j <= k

\* Unwind an exception of kind `kind` through the innermost call's frames fr. Julia's stack
\* is already spec2, WT's cells, top and count c2, t2, n2; sv and iv are the values each
\* raises, pc the payload's cell. Only the tag lands (L101), and its landing takes the top by
\* identity and leaves the count as it is. With no handler, the escape leaves the call and
\* nothing is restored: at the top level the host catches it (Julia: jl_restore_excstack to
\* the call's entry depth), else it waits at the host (pending).
Unwind(kind, sv, iv, pc, fr, spec2, c2, t2, n2) ==
    LET k == IF kind = "tag" THEN HandlerIn(fr) ELSE 0 IN
    IF k # 0 THEN
        /\ obsS' = <<"land", sv>> /\ obsI' = <<"land", iv>>
        /\ calls' = calls /\ pending' = None /\ spec' = spec2 /\ cnt' = n2
        /\ frames' = [j \in 1..k |-> IF j = k THEN [fr[k] EXCEPT !.kind = "catch"] ELSE fr[j]]
        /\ IF Impl = "values"
           THEN /\ cur' = iv /\ cells' = c2 /\ top' = t2
           ELSE /\ cur' = cur
                /\ IF PushAtLanding
                   THEN cells' = Append(c2, [exn |-> iv]) /\ top' = Len(c2) + 1
                   ELSE IF Landing = "identity" THEN cells' = c2 /\ top' = pc
                   ELSE IF Landing = "drop" THEN cells' = c2 /\ top' = t2
                   ELSE IF t2 # 0 /\ c2[t2].exn = iv THEN cells' = c2 /\ top' = t2
                   ELSE cells' = Append(c2, [exn |-> iv]) /\ top' = Len(c2) + 1
    ELSE
        LET c == calls[Len(calls)] IN
        /\ obsS' = <<"escape", kind, sv>> /\ obsI' = <<"escape", kind, iv>>
        /\ frames' = SubSeq(fr, 1, c.base)
        /\ calls' = SubSeq(calls, 1, Len(calls) - 1)
        /\ cells' = c2 /\ top' = t2 /\ cur' = cur /\ cnt' = n2
        /\ IF Len(calls) = 1
           THEN spec' = SubSeq(spec2, 1, c.depth) /\ pending' = None
           ELSE spec' = spec2
                /\ pending' = [kind |-> kind, sv |-> sv, iv |-> iv, pc |-> pc, depth |-> c.depth,
                               shared |-> kind = "tag" /\ pc # 0 /\ pc <= c.ncells]

\* The host calls an export: from the top level, or re-entrantly from inside a host-declared
\* import an open call made. Julia records the depth. WT's entry is a prologue: at the count 0
\* (or in a module with no count) it is top-level and nulls the top; otherwise it takes the
\* top at index count - 1, the top at the open import's call. ResetAtEntry: every entry nulls
\* the top. KeepsEntry: no entry.
HostCall ==
    /\ Len(calls) < MaxCalls /\ pending.kind = "none"
    /\ calls = <<>> \/ ImportOpen
    /\ LET isTop == IF HasImport THEN cnt = 0 ELSE TRUE
           kept == [ptr |-> top, val |-> cur]
           null == [ptr |-> 0, val |-> Nothing]
           entry == IF KeepsEntry THEN kept
                    ELSE IF ResetAtEntry THEN null
                    ELSE IF isTop THEN (IF TopLevelReset THEN null ELSE kept)
                    ELSE IF EntryTakesSlot THEN SlotAt(cnt - 1)
                    ELSE kept
       IN top' = entry.ptr /\ cur' = entry.val
    /\ calls' = Append(calls, [depth |-> Len(spec), base |-> Len(frames), ncells |-> Len(cells)])
    /\ UNCHANGED <<frames, pending, spec, cells, cnt, slots>>
    /\ obsS' = <<"call">> /\ obsI' = <<"call">>

\* HostCallsGlued: the host calls a glued import itself, outside every call of the module (as a
\* second instance sharing the glued object does through its own import call): the glue counts it
\* as an open import no call of this module made, so an export the host calls from inside it is
\* taken as re-entrant and takes a slot its own calls saved for another call (here one that exists:
\* the stale top; with none, the code's array read traps). The design's glue hands each import
\* out once, to the instantiation that reads it, so the host never holds a glued import.
HostGluedCall == /\ HostCallsGlued /\ calls = <<>> /\ pending.kind = "none" /\ cnt < Len(slots)
                 /\ cnt' = cnt + 1
                 /\ UNCHANGED <<frames, calls, pending, spec, cells, top, slots, cur>>
                 /\ obsS' = <<"glued">> /\ obsI' = <<"glued">>

HostGluedReturn == /\ HostCallsGlued /\ calls = <<>> /\ pending.kind = "none" /\ cnt > 0
                   /\ cnt' = cnt - 1
                   /\ UNCHANGED <<frames, calls, pending, spec, cells, top, slots, cur>>
                   /\ obsS' = <<"glued return">> /\ obsI' = <<"glued return">>

\* The call returns normally once every region it entered is closed; the results leave on the
\* stack and the entry touches nothing.
Return == /\ Running /\ Len(frames) = Base
          /\ calls' = SubSeq(calls, 1, Len(calls) - 1)
          /\ UNCHANGED <<frames, pending, spec, cells, top, cnt, slots, cur>>
          /\ obsS' = <<"return">> /\ obsI' = <<"return">>

\* A call of a host-declared import: the call site stores the top at index count, growing the
\* array to hold it; the glue raises the count.
ImportCall == /\ Running /\ HasImport /\ Len(frames) < MaxFrames
              /\ frames' = Append(frames, ImportFrame) /\ cnt' = cnt + 1
              /\ slots' = IF cnt < Len(slots)
                          THEN [slots EXCEPT ![cnt + 1] = [ptr |-> top, val |-> cur]]
                          ELSE Append(slots, [ptr |-> top, val |-> cur])
              /\ UNCHANGED <<calls, pending, spec, cells, top, cur>>
              /\ obsS' = <<"import">> /\ obsI' = <<"import">>

\* Its normal return: the glue's finally lowers the count to its value at the call, and the call
\* site (ReturnRestores) sets the top from that index.
ImportReturn == /\ ImportOpen
                /\ frames' = SubSeq(frames, 1, Len(frames) - 1) /\ cnt' = cnt - 1
                /\ top' = IF ReturnRestores THEN SlotAt(cnt - 1).ptr ELSE top
                /\ cur' = IF ReturnRestores THEN SlotAt(cnt - 1).val ELSE cur
                /\ UNCHANGED <<calls, pending, spec, cells, slots>>
                /\ obsS' = <<"import return">> /\ obsI' = <<"import return">>

\* The count as an escape leaves an import's frame: the glue's finally lowers it, whatever the
\* kind; GlueFinally = FALSE lowers it only on a normal return.
GlueCnt == IF GlueFinally THEN cnt - 1 ELSE cnt

\* The import throws into its caller: a JS exception (ImportThrows), or the RangeError of
\* a JS stack it overflowed (ImportExhausts).
ImportThrow(kind) ==
    /\ ImportOpen
    /\ \/ kind = "foreign" /\ ImportThrows
       \/ kind = "exhaust" /\ ImportExhausts
    /\ UNCHANGED slots
    /\ Unwind(kind, Nothing, Nothing, 0, SubSeq(frames, 1, Len(frames) - 1),
              spec, cells, top, GlueCnt)

\* An escape at the host, from a re-entrant call. The host catches it inside the import:
\* Julia's JL_CATCH restores the callee's entry depth; WT's state is what the escape left,
\* corrected at the next point that reads the top (the import's return, or the next entry).
HostCatch == /\ pending.kind # "none"
             /\ pending.kind # "trap" \/ HostCatchesTrap
             /\ spec' = SubSeq(spec, 1, pending.depth) /\ pending' = None
             /\ frames' = [frames EXCEPT ![Len(frames)].held = pending]
             /\ UNCHANGED <<calls, cells, top, cnt, slots, cur>>
             /\ obsS' = <<"caught">> /\ obsI' = <<"caught">>

\* Or it propagates through the import into the caller, unwinding on from the import's frame.
HostPropagate == /\ pending.kind # "none"
                 /\ pending.kind # "trap" \/ PropagatesTrap
                 /\ UNCHANGED slots
                 /\ Unwind(pending.kind, pending.sv, pending.iv, pending.pc,
                           SubSeq(frames, 1, Len(frames) - 1), spec, cells, top, GlueCnt)

\* Or, having caught it, the host throws the same exception again later, inside the same
\* import (a host `finally` that calls an export first, say): a Julia host's throw pushes it,
\* and WT's landing takes the payload's cell. ReraiseShared: also one whose cell existed when
\* the call it left was entered, an entry of the caller's stack (dev/MARCH.md 13.17 H11).
HostReraise == /\ ImportOpen /\ Last.held.kind # "none"
               /\ ~Last.held.shared \/ ReraiseShared
               /\ UNCHANGED slots
               /\ LET h == Last.held IN
                  Unwind(h.kind, h.sv, h.iv, h.pc, SubSeq(frames, 1, Len(frames) - 1),
                         IF h.kind = "tag" THEN Append(spec, h.sv) ELSE spec, cells, top, GlueCnt)

Enter == /\ Running /\ Len(frames) < MaxFrames
         /\ frames' = Append(frames, [kind |-> "try", depth |-> Len(spec), ptr |-> top,
                                      val |-> cur, held |-> None])
         /\ UNCHANGED <<calls, pending, spec, cells, top, cnt, slots, cur>>
         /\ obsS' = <<"enter">> /\ obsI' = <<"enter">>

Leave == /\ Running /\ Len(frames) > Base /\ Last.kind = "try"
         /\ frames' = SubSeq(frames, 1, Len(frames) - 1)
         /\ UNCHANGED <<calls, pending, spec, cells, top, cnt, slots, cur>>
         /\ obsS' = <<"leave">> /\ obsI' = <<"leave">>

PopException ==
    /\ Running /\ Len(frames) > Base /\ Last.kind = "catch"
    /\ spec' = SubSeq(spec, 1, Last.depth) /\ top' = Last.ptr /\ cur' = Last.val
    /\ frames' = SubSeq(frames, 1, Len(frames) - 1)
    /\ UNCHANGED <<calls, pending, cells, cnt, slots>>
    /\ obsS' = <<"pop">> /\ obsI' = <<"pop">>

Read == /\ Running
        /\ obsS' = <<"read", JuliaTop>> /\ obsI' = <<"read", WTTop>>
        /\ UNCHANGED <<frames, calls, pending, spec, cells, top, cnt, slots, cur>>

\* a trap, or stack exhaustion in wasm code (the engine's RangeError, the only exception
\* wasm code raises by itself): in a top-level call, or (ExhaustReentrant) in a re-entrant one
Abort(kind) == /\ Running
               /\ kind = "exhaust" => Len(calls) = 1 \/ ExhaustReentrant
               /\ UNCHANGED slots
               /\ Unwind(kind, Nothing, Nothing, 0, frames, spec, cells, top, cnt)

\* a throw's push (Impl = "cells", unless the landing pushes), and the payload's cell
Pushed(v) == IF Impl = "cells" /\ ~PushAtLanding THEN Append(cells, [exn |-> v]) ELSE cells
PushedTop == IF Impl = "cells" /\ ~PushAtLanding THEN Len(cells) + 1 ELSE top

Throw(v) == /\ Running /\ UNCHANGED slots
            /\ Unwind("tag", v, v, PushedTop, frames, Append(spec, v), Pushed(v), PushedTop, cnt)

Rethrow ==
    LET sv == IF spec = <<>> THEN ErrR ELSE JuliaTop
        spec2 == IF spec = <<>> THEN Append(spec, ErrR) ELSE spec
        empty == IF Impl = "values" THEN cur = Nothing ELSE top = 0   \* the value-save at its best
        err == empty /\ RethrowChecksDepth   \* WT throws Julia's ErrorException, a throw
        iv == IF err THEN ErrR ELSE WTTop
        t2 == IF err THEN PushedTop ELSE top
    IN /\ Running /\ UNCHANGED slots
       /\ Unwind("tag", sv, iv, t2, frames, spec2, IF err THEN Pushed(ErrR) ELSE cells, t2, cnt)

RethrowOther(v) ==
    LET sv == IF spec = <<>> THEN ErrO ELSE v
        spec2 == IF spec = <<>> THEN Append(spec, ErrO) ELSE [spec EXCEPT ![Len(spec)] = v]
        empty == IF Impl = "values" THEN cur = Nothing ELSE top = 0   \* the value-save at its best
        err == empty /\ RethrowChecksDepth
        iv == IF err THEN ErrO ELSE v
        c2 == IF err THEN Pushed(ErrO)
              ELSE IF Impl = "values" \/ empty THEN cells ELSE [cells EXCEPT ![top].exn = v]
        t2 == IF err THEN PushedTop ELSE top
    IN /\ Running /\ UNCHANGED slots
       /\ Unwind("tag", sv, iv, t2, frames, spec2, c2, t2, cnt)

\* Rethrow is listed first: of the equally short counterexamples, TLC then reports a rethrow;
\* an import's exhaustion is listed before its foreign exception for the same reason
Step == /\ steps < MaxSteps /\ steps' = steps + 1
        /\ (Rethrow \/ Enter \/ Leave \/ PopException \/ Read \/ HostCall \/ Return
            \/ ImportCall \/ ImportReturn \/ ImportThrow("exhaust") \/ ImportThrow("foreign")
            \/ HostCatch \/ HostPropagate \/ HostReraise \/ Abort("trap") \/ Abort("exhaust")
            \/ HostGluedCall \/ HostGluedReturn
            \/ \E v \in Vals : Throw(v) \/ RethrowOther(v))

Stop == steps = MaxSteps /\ UNCHANGED vars   \* the bound, not a deadlock

Spec == Init /\ [][Step \/ Stop]_vars

Agrees == obsS = obsI
=============================================================================
