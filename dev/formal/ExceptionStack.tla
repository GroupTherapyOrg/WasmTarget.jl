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
(* A throw pushes a cell and raises the tag with (exn, stack, cell) (D1:   *)
(* the entry travels with the unwind); a rethrow raises the top cell's     *)
(* payload without pushing; an enter saves the top pointer and the count   *)
(* of open host-declared imports; a pop_exception restores the top;        *)
(* the_exception reads the top cell; `rethrow(e)` writes the top cell's    *)
(* exn. A cell is an entry of Julia's stack and a pointer its depth. Every *)
(* catch landing sets the top to the payload's cell and restores the count *)
(* its enter saved (D2). `$host_imports_open` counts the open calls of     *)
(* host-declared imports (each call increments it before and decrements it *)
(* after; WT's own runtime imports never call back and count nothing); an  *)
(* entry with the count at 0 is top-level and sets the top to null (D3).   *)
(* Every export calls its function through an entry that saves the top and *)
(* the count (after a top-level entry's reset), calls the inner inside a   *)
(* result-less try_table (catch_all_ref $h), and at $h restores both and   *)
(* throw_refs the exnref (D4, contract batch 110 Amendment 1): the one     *)
(* catch_all of the module (L101's one-site allowlist). catch_all_ref      *)
(* observes the tag, a JS exception and any other module's tag, but not a  *)
(* trap or stack exhaustion. dart observes a JS unwind by catching the     *)
(* imported WebAssembly.JSTag beside its own tag (tags.dart:45             *)
(* _importJsExceptionTag; code_generator.dart:1030 visitTryCatch,          *)
(* :1156-1162 visitTryFinally), which WT does not import yet (dev/MARCH.md *)
(* 13.17, C2). Between a host-import call site and its export's entry      *)
(* every wasm frame is a Julia frame, which catches only the tag, so the   *)
(* entry is the one wasm frame that observes a catchable foreign escape. A *)
(* module with no host-declared import has no count and every entry is     *)
(* top-level (HasImport = FALSE).                                          *)
(*                                                                         *)
(* ESCAPES. Four kinds: the tag (a Julia throw), a foreign exception (a JS *)
(* exception a host-declared import throws, ImportThrows), stack           *)
(* exhaustion ("exhaust": the engine's RangeError for a stack overflow,    *)
(* raised in wasm code, or in an import that overflows the JS stack,       *)
(* ImportExhausts), and a trap. A Julia region catches only the tag        *)
(* (L101), so every other kind unwinds every Julia frame of the call. The  *)
(* entry's catch_all_ref catches the tag and a foreign exception. No wasm  *)
(* construct catches a trap or stack exhaustion: V8 marks a stack-overflow *)
(* RangeError uncatchable by wasm, as a trap is (dev/MARCH.md 13.17 A13E1: *)
(* measured on Node 22.23.3, the import variant answers 1 where Julia      *)
(* answers 2 and the re-entrant one 2 where Julia answers 1, the entry     *)
(* restoring nothing), also when it comes back into wasm through an        *)
(* import. So neither has a landing, the entry restores nothing, and an   *)
(* import's decrement                                                      *)
(* does not run (also under ImportSiteCatch): the call is left as the      *)
(* escape found it. The two differ at the host: an instance that trapped   *)
(* is discarded, WT's host-contract quarantine since no wasm construct     *)
(* catches a trap (13.17 H7; where WT traps Julia often raises a catchable *)
(* error and its task lives on); Discard ends the run,                     *)
(* while after an exhaustion the host keeps the instance (Julia's          *)
(* StackOverflowError leaves the task alive), so the runs after an         *)
(* exhaustion are inside the claim. When an escape leaves a re-entrant     *)
(* call, the host either catches it (inside the import; the import then    *)
(* returns normally or the host calls again) or lets it propagate through  *)
(* the import into the caller, where the import's decrement never runs. An *)
(* escape from a top-level call is caught by the host.                     *)
(*                                                                         *)
(* THE CLAIM. On every run of host calls (nested at most MaxCalls deep),   *)
(* each a program of nested try, catch, rethrow and host-declared import   *)
(* calls (bounded by MaxFrames and MaxSteps), every `the_exception` read   *)
(* and every raised value is Julia's (Agrees, read in every state of the   *)
(* run, so over every call). Stack exhaustion in a top-level call's own    *)
(* wasm code is covered: it leaves a stale top and the count it found (0), *)
(* and the next top-level call resets. The claim covers every escape       *)
(* except the named residuals of dev/MARCH.md 13.17, each pinned as an     *)
(* instance that violates it (the design, the open finding). Two are       *)
(* re-entrant traps, outside the host contract: WT's host-contract         *)
(* quarantine (13.17 H7) discards an instance that trapped, since no wasm  *)
(* construct catches a trap, so neither is a run the host makes; a trap in a *)
(* top-level call is covered (the next call resets).                       *)
(*   H6 (HostCatchesTrap): a re-entrant trap that the host catches leaves  *)
(*      the callee's entries for the rest of the outer call.               *)
(*   H7 (PropagatesTrap): a re-entrant trap that unwinds through the       *)
(*      import and out of the outer export leaves the count stuck, so the  *)
(*      next top-level call is taken as re-entrant.                        *)
(*                                                                         *)
(* The third is stack exhaustion inside a host-declared import or a        *)
(* re-entrant call, A13E1 (the residual of A12B1), inside the host         *)
(* contract, since the host keeps the instance:                            *)
(*   A13E1 (ImportExhausts): an import that overflows the JS stack strands *)
(*      the count its call raised, so the next top-level call is taken as  *)
(*      re-entrant, is not reset, and reads the previous call's top.       *)
(*   A13E1 (ExhaustReentrant): an exhaustion in a re-entrant call that the *)
(*      host catches leaves the callee's entries for the rest of the outer *)
(*      call; one the host propagates through the import strands the       *)
(*      count, as ImportExhausts does.                                     *)
(*                                                                         *)
(* The Broken instances, each a realistic mistake: the payload dropped at  *)
(* the landing (Landing = "drop", NoLandingIdentity, H5); the landing      *)
(* finding its entry by ref.eq on the exception (Landing = "value",        *)
(* ValueIdentity, A12P2: the same object thrown twice is one cell); no     *)
(* reset at a top-level entry (NoTopLevelReset, A12B1); a landing that     *)
(* does not restore the count (NoCountRestore); an entry's handler that    *)
(* does not restore the count (NoEntryCountRestore); an entry that catches *)
(* only the tag (EntryTagOnly: the stuck count after an import throws,     *)
(* batch 110's refutation of D3); a catch_all_ref at every host-import     *)
(* call site that decrements the count and rethrows, with an entry that    *)
(* catches only the tag (ImportSiteOnly); every entry nulling the top it   *)
(* saved (ResetAtEntry); an export with no entry (KeepsEntry); the         *)
(* value-save lowering (Impl = "values"); a rethrow at depth 0 that throws *)
(* the top (RethrowChecksDepth = FALSE); a push at the catch's landing     *)
(* instead of at the throw (PushAtLanding). H6, H7, ExhaustImport and      *)
(* ExhaustReentrant pin the residuals above.                               *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Two exception values. A cell's stack slot is *)
(* left out, and a cell is its exn alone: the claim is about exception     *)
(* values, not stack traces. A stack does not always travel with its       *)
(* value: `rethrow(e)` writes the top cell's exn while the cell keeps the  *)
(* stack its throw captured, as Julia's jl_rethrow_other keeps the         *)
(* backtrace, so whether `rethrow(e)` keeps its throw's stack is outside   *)
(* the claim (dev/MARCH.md 13.17 A4B9 = A4P5). An exnref is its payload,   *)
(* so throw_ref raises the same (exn, stack, cell). Control flow is the    *)
(* frame stack the lowering sees: an open try body, an open catch body, an *)
(* open call of a host-declared import; `return`/`break` out of a catch is *)
(* its pop_exception (Julia's lowering emits one), a finally is a catch    *)
(* that ends in rethrow(). Julia's side, too, lets a foreign exception     *)
(* unwind every region to the host (the host's exception is not Julia's),  *)
(* and lets stack exhaustion unwind every region to the host: Julia raises *)
(* a StackOverflowError that a Julia catch catches, which WT's RangeError  *)
(* is not, and the model does not claim that (dev/MARCH.md 13.17 H8, its   *)
(* own row). Calls inside the module are direct calls of the inner         *)
(* functions, which share the frame stack and need no entry.               *)
(*                                                                         *)
(* formal(src/codegen/statements.jl compile_statement!): a try region's    *)
(* enter, catch, pop_exception, the_exception and rethrow answer as        *)
(* Julia's exception stack (emit_throw_value!, emit_rethrow!,              *)
(* emit_current_exception!, ensure_exception_top_global!, exc_saved_local! *)
(* in generate.jl; the region's enter and pop_exception in statements.jl;  *)
(* the catch landing in stackified.jl).                                    *)
(*                                                                         *)
(* formal(src/codegen/generate.jl emit_export_entry!; the one-time export  *)
(* in src/codegen/compile.jl): every escape leaves the stack as Julia's    *)
(* host leaves it, except H6, H7 and A13E1.                                *)
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
          KeepsEntry,         \* TRUE = an export has no entry: no save, no restore, no reset
          ResetAtEntry,       \* TRUE = every entry saves the top, then nulls it
          Landing,            \* D2: "identity" (top := payload cell), "drop" (the payload
                              \* is dropped), "value" (ref.eq on the exn, else push)
          TopLevelReset,      \* D3: a top-level entry nulls the top
          LandingRestoresCount, \* D3: a landing restores the count its enter saved
          EntryRestoresCount, \* D4: an entry's handler restores the count it saved
          EntryCatchesAll,    \* D4: the entry's handler is catch_all_ref (FALSE: the tag only)
          ImportSiteCatch,    \* TRUE = a catch_all_ref at every host-import call site
                              \* decrements the count and rethrows
          HasImport,          \* the module has a host-declared import (and the count)
          ImportThrows,       \* a host-declared import may throw a foreign exception
          HostCatchesTrap,    \* H6: the host catches a re-entrant trap
          PropagatesTrap,     \* H7: the host lets a re-entrant trap propagate
          ImportExhausts,     \* A13E1: a host-declared import may overflow the JS stack
          ExhaustReentrant    \* A13E1: a re-entrant call's wasm code may exhaust the stack

Nothing == "nothing"
ErrR == "errR"   \* ErrorException("rethrow() not allowed outside a catch block")
ErrO == "errO"   \* ErrorException("rethrow(exc) not allowed outside a catch block")
AllVals == Vals \cup {Nothing, ErrR, ErrO}
Kinds == {"tag", "foreign", "exhaust", "trap"}
\* the kinds catch_all_ref catches; no wasm construct catches a trap or stack exhaustion
Catchable == {"tag", "foreign"}

VARIABLES frames,   \* the open try, catch and import frames of every open call, innermost last
          calls,    \* the host's open calls, innermost last
          pending,  \* an escape that left a re-entrant call, at the host inside the import
          spec,     \* Julia's exception stack
          cells,    \* WT's cells: a sequence of [exn] (no link); a pointer is an index, 0 is null
          top,      \* WT's `$exc_top`
          cnt,      \* WT's `$host_imports_open`
          cur,      \* Impl = "values": the one `$current_exn`
          obsS, obsI,  \* the last observation, Julia's and WT's
          steps
vars == <<frames, calls, pending, spec, cells, top, cnt, cur, obsS, obsI, steps>>

\* a try or catch body: Julia's depth at its enter, WT's top, `$current_exn` and count there
Frame == [kind : {"try", "catch", "import"}, depth : Nat, ptr : Nat, val : AllVals, cnt : Nat]
ImportFrame == [kind |-> "import", depth |-> 0, ptr |-> 0, val |-> Nothing, cnt |-> 0]
\* a host call: Julia's depth at its entry (the host's jl_excstack_state), what WT's entry
\* saved, and the frames below it (its caller's, ending in the caller's import frame)
Call == [depth : Nat, ptr : Nat, val : AllVals, cnt : Nat, base : Nat]
\* an escape at the host: its kind, Julia's and WT's values, the payload's cell, and the
\* depth the host's JL_CATCH restores
Pending == [kind : Kinds \cup {"none"}, sv : AllVals, iv : AllVals, pc : Nat, depth : Nat]
None == [kind |-> "none", sv |-> Nothing, iv |-> Nothing, pc |-> 0, depth |-> 0]

TypeOK == /\ frames \in Seq(Frame) /\ calls \in Seq(Call) /\ pending \in Pending
          /\ spec \in Seq(AllVals) /\ cells \in Seq([exn : AllVals])
          /\ top \in Nat /\ cnt \in Nat /\ cur \in AllVals /\ steps \in Nat

\* the run begins at the top level, with no call open
Init == /\ frames = <<>> /\ calls = <<>> /\ pending = None
        /\ spec = <<>> /\ cells = <<>> /\ top = 0 /\ cnt = 0 /\ cur = Nothing
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

\* the innermost open try body of the innermost call in frame stack fr, 0 when there is none
HandlerIn(fr) == LET ks == {k \in (Base + 1)..Len(fr) : fr[k].kind = "try"} IN
                 IF ks = {} THEN 0 ELSE CHOOSE k \in ks : \A j \in ks : j <= k

\* Unwind an exception of kind `kind` through the innermost call's frames fr. Julia's stack
\* is already spec2, WT's cells, top and count c2, t2, n2; sv and iv are the values each
\* raises, pc the payload's cell. Only the tag lands (L101). With no handler, the escape
\* leaves the call: the entry's catch_all_ref (D4) catches a tag or a foreign escape, never
\* a trap or stack exhaustion, restores what the entry saved and throw_refs it; at the top
\* level the host catches it (Julia: jl_restore_excstack to the call's entry depth), else
\* it waits at the host (pending).
Unwind(kind, sv, iv, pc, fr, spec2, c2, t2, n2) ==
    LET k == IF kind = "tag" THEN HandlerIn(fr) ELSE 0 IN
    IF k # 0 THEN
        /\ obsS' = <<"land", sv>> /\ obsI' = <<"land", iv>>
        /\ calls' = calls /\ pending' = None /\ spec' = spec2
        /\ frames' = [j \in 1..k |-> IF j = k THEN [fr[k] EXCEPT !.kind = "catch"] ELSE fr[j]]
        /\ cnt' = IF LandingRestoresCount THEN fr[k].cnt ELSE n2
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
        LET c == calls[Len(calls)]
            restores == /\ ~KeepsEntry
                        /\ kind = "tag" \/ (kind = "foreign" /\ EntryCatchesAll)
        IN
        /\ obsS' = <<"escape", kind, sv>> /\ obsI' = <<"escape", kind, iv>>
        /\ frames' = SubSeq(fr, 1, c.base)
        /\ calls' = SubSeq(calls, 1, Len(calls) - 1)
        /\ cells' = c2
        /\ top' = IF restores THEN c.ptr ELSE t2
        /\ cur' = IF restores THEN c.val ELSE cur
        /\ cnt' = IF restores /\ EntryRestoresCount THEN c.cnt ELSE n2
        /\ IF Len(calls) = 1
           THEN spec' = SubSeq(spec2, 1, c.depth) /\ pending' = None
           ELSE spec' = spec2
                /\ pending' = [kind |-> kind, sv |-> sv, iv |-> iv, pc |-> pc, depth |-> c.depth]

\* The host calls an export: from the top level, or re-entrantly from inside a host-declared
\* import an open call made. Julia records the depth. WT's entry: at the count 0 (or in a
\* module with no count) it is top-level and nulls the top (D3); it saves the top and the
\* count. ResetAtEntry: every entry saves the top, then nulls it. KeepsEntry: no entry.
HostCall ==
    /\ Len(calls) < MaxCalls /\ pending.kind = "none"
    /\ calls = <<>> \/ ImportOpen
    /\ LET isTop == IF HasImport THEN cnt = 0 ELSE TRUE
           reset == ~KeepsEntry /\ TopLevelReset /\ isTop
       IN /\ top' = IF reset \/ (ResetAtEntry /\ ~KeepsEntry) THEN 0 ELSE top
          /\ cur' = IF reset \/ (ResetAtEntry /\ ~KeepsEntry) THEN Nothing ELSE cur
          /\ cnt' = IF reset THEN 0 ELSE cnt
          /\ calls' = Append(calls, [depth |-> Len(spec),
                                     ptr |-> IF reset THEN 0 ELSE top,
                                     val |-> IF reset THEN Nothing ELSE cur,
                                     cnt |-> IF reset THEN 0 ELSE cnt,
                                     base |-> Len(frames)])
    /\ UNCHANGED <<frames, pending, spec, cells>>
    /\ obsS' = <<"call">> /\ obsI' = <<"call">>

\* The call returns normally once every region it entered is closed; the entry returns the
\* inner's result and touches nothing.
Return == /\ Running /\ Len(frames) = Base
          /\ calls' = SubSeq(calls, 1, Len(calls) - 1)
          /\ UNCHANGED <<frames, pending, spec, cells, top, cnt, cur>>
          /\ obsS' = <<"return">> /\ obsI' = <<"return">>

\* A call of a host-declared import: the count goes up before it and down after it returns.
ImportCall == /\ Running /\ HasImport /\ Len(frames) < MaxFrames
              /\ frames' = Append(frames, ImportFrame) /\ cnt' = cnt + 1
              /\ UNCHANGED <<calls, pending, spec, cells, top, cur>>
              /\ obsS' = <<"import">> /\ obsI' = <<"import">>

ImportReturn == /\ ImportOpen
                /\ frames' = SubSeq(frames, 1, Len(frames) - 1) /\ cnt' = cnt - 1
                /\ UNCHANGED <<calls, pending, spec, cells, top, cur>>
                /\ obsS' = <<"import return">> /\ obsI' = <<"import return">>

\* The count as an escape leaves an import's call site: the decrement never runs, unless
\* (ImportSiteCatch) a catch_all_ref at the call site decrements it; a trap or stack
\* exhaustion passes it.
SiteCnt(kind) == IF ImportSiteCatch /\ kind \in Catchable THEN cnt - 1 ELSE cnt

\* The import throws into its caller: a JS exception (ImportThrows), or the RangeError of
\* a JS stack it overflowed (ImportExhausts, A13E1).
ImportThrow(kind) ==
    /\ ImportOpen
    /\ \/ kind = "foreign" /\ ImportThrows
       \/ kind = "exhaust" /\ ImportExhausts
    /\ Unwind(kind, Nothing, Nothing, 0, SubSeq(frames, 1, Len(frames) - 1),
              spec, cells, top, SiteCnt(kind))

\* An escape at the host, from a re-entrant call. The host catches it: Julia's JL_CATCH
\* restores the callee's entry depth; WT's state is what the escape left (H6 for a trap,
\* A13E1 for stack exhaustion).
HostCatch == /\ pending.kind # "none"
             /\ pending.kind # "trap" \/ HostCatchesTrap
             /\ spec' = SubSeq(spec, 1, pending.depth) /\ pending' = None
             /\ UNCHANGED <<frames, calls, cells, top, cnt, cur>>
             /\ obsS' = <<"caught">> /\ obsI' = <<"caught">>

\* Or it propagates through the import into the caller, unwinding on from the import's
\* frame (H7 for a trap, A13E1 for stack exhaustion: nothing restores the count the import
\* raised).
HostPropagate == /\ pending.kind # "none"
                 /\ pending.kind # "trap" \/ PropagatesTrap
                 /\ Unwind(pending.kind, pending.sv, pending.iv, pending.pc,
                           SubSeq(frames, 1, Len(frames) - 1), spec, cells, top,
                           SiteCnt(pending.kind))

Enter == /\ Running /\ Len(frames) < MaxFrames
         /\ frames' = Append(frames, [kind |-> "try", depth |-> Len(spec), ptr |-> top,
                                      val |-> cur, cnt |-> cnt])
         /\ UNCHANGED <<calls, pending, spec, cells, top, cnt, cur>>
         /\ obsS' = <<"enter">> /\ obsI' = <<"enter">>

Leave == /\ Running /\ Len(frames) > Base /\ Last.kind = "try"
         /\ frames' = SubSeq(frames, 1, Len(frames) - 1)
         /\ UNCHANGED <<calls, pending, spec, cells, top, cnt, cur>>
         /\ obsS' = <<"leave">> /\ obsI' = <<"leave">>

PopException ==
    /\ Running /\ Len(frames) > Base /\ Last.kind = "catch"
    /\ spec' = SubSeq(spec, 1, Last.depth) /\ top' = Last.ptr /\ cur' = Last.val
    /\ frames' = SubSeq(frames, 1, Len(frames) - 1)
    /\ UNCHANGED <<calls, pending, cells, cnt>>
    /\ obsS' = <<"pop">> /\ obsI' = <<"pop">>

Read == /\ Running
        /\ obsS' = <<"read", JuliaTop>> /\ obsI' = <<"read", WTTop>>
        /\ UNCHANGED <<frames, calls, pending, spec, cells, top, cnt, cur>>

\* a trap, or stack exhaustion in wasm code (the engine's RangeError, the only exception
\* wasm code raises by itself): in a top-level call, or (ExhaustReentrant, A13E1) in a
\* re-entrant one
Abort(kind) == /\ Running
               /\ kind = "exhaust" => Len(calls) = 1 \/ ExhaustReentrant
               /\ Unwind(kind, Nothing, Nothing, 0, frames, spec, cells, top, cnt)

\* a throw's push (Impl = "cells", unless the landing pushes), and the payload's cell
Pushed(v) == IF Impl = "cells" /\ ~PushAtLanding THEN Append(cells, [exn |-> v]) ELSE cells
PushedTop == IF Impl = "cells" /\ ~PushAtLanding THEN Len(cells) + 1 ELSE top

Throw(v) == Running /\ Unwind("tag", v, v, PushedTop, frames, Append(spec, v), Pushed(v), PushedTop, cnt)

Rethrow ==
    LET sv == IF spec = <<>> THEN ErrR ELSE JuliaTop
        spec2 == IF spec = <<>> THEN Append(spec, ErrR) ELSE spec
        empty == IF Impl = "values" THEN cur = Nothing ELSE top = 0   \* the value-save at its best
        err == empty /\ RethrowChecksDepth   \* WT throws Julia's ErrorException, a throw
        iv == IF err THEN ErrR ELSE WTTop
        t2 == IF err THEN PushedTop ELSE top
    IN Running /\ Unwind("tag", sv, iv, t2, frames, spec2, IF err THEN Pushed(ErrR) ELSE cells, t2, cnt)

RethrowOther(v) ==
    LET sv == IF spec = <<>> THEN ErrO ELSE v
        spec2 == IF spec = <<>> THEN Append(spec, ErrO) ELSE [spec EXCEPT ![Len(spec)] = v]
        empty == IF Impl = "values" THEN cur = Nothing ELSE top = 0   \* the value-save at its best
        err == empty /\ RethrowChecksDepth
        iv == IF err THEN ErrO ELSE v
        c2 == IF err THEN Pushed(ErrO)
              ELSE IF Impl = "values" \/ empty THEN cells ELSE [cells EXCEPT ![top].exn = v]
        t2 == IF err THEN PushedTop ELSE top
    IN Running /\ Unwind("tag", sv, iv, t2, frames, spec2, c2, t2, cnt)

\* Rethrow is listed first: of the equally short counterexamples, TLC then reports a rethrow
Step == /\ steps < MaxSteps /\ steps' = steps + 1
        /\ (Rethrow \/ Enter \/ Leave \/ PopException \/ Read \/ HostCall \/ Return
            \/ ImportCall \/ ImportReturn \/ ImportThrow("foreign") \/ ImportThrow("exhaust")
            \/ HostCatch \/ HostPropagate \/ Abort("trap") \/ Abort("exhaust")
            \/ \E v \in Vals : Throw(v) \/ RethrowOther(v))

Stop == steps = MaxSteps /\ UNCHANGED vars   \* the bound, not a deadlock
\* A trap that left a re-entrant call: the host discards the instance (WT's host-contract
\* quarantine, 13.17 H7: no wasm construct catches a trap) and the run ends there, unless H6 or
\* H7 lets the host go on with it.
Discard == pending.kind = "trap" /\ UNCHANGED vars

Spec == Init /\ [][Step \/ Stop \/ Discard]_vars

Agrees == obsS = obsI
=============================================================================
