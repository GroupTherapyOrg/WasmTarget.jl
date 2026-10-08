---------------------------- MODULE ExceptionStack ----------------------------
(***************************************************************************)
(* A TLA+ model of WT's lowering of Julia's exception stack (try regions,  *)
(* catch, the_exception, pop_exception, rethrow; src/codegen/statements.jl, *)
(* generate.jl, compile.jl) against Julia's own (task.c throw_internal,    *)
(* jl_rethrow, jl_rethrow_other; rtutils.c jl_excstack_state,              *)
(* jl_restore_excstack; codegen.cpp's enter and pop_exception; julia.h     *)
(* JL_TRY/JL_CATCH), within a call and across the host's calls.            *)
(*                                                                         *)
(* JULIA. Each task has a stack of exceptions. A throw pushes its          *)
(* exception and jumps to the innermost handler. An `enter` records the    *)
(* stack's depth; `pop_exception` restores that depth. `the_exception`     *)
(* reads the top, `nothing` when the stack is empty. `rethrow()` raises    *)
(* the top without pushing; `rethrow(e)` overwrites the top with `e` and    *)
(* raises it without pushing; either at depth 0 throws ErrorException      *)
(* ("rethrow() not allowed outside a catch block", or "rethrow(exc) …"),   *)
(* which pushes as every throw does. Leaving a try body normally, and       *)
(* landing in a catch, leave the stack as it is. The stack belongs to the   *)
(* task, so it outlives a call: a callee reads its caller's entries (a      *)
(* `rethrow()` in a function called from a catch raises the caller's        *)
(* exception). The host is the catching frame of the call it makes: its     *)
(* JL_TRY records jl_excstack_state at the call's entry and its JL_CATCH    *)
(* ends in jl_restore_excstack (julia.h:2532, :2541), so after an escape    *)
(* the stack is what it was when the call began: empty from the top        *)
(* level, the caller's entries in a re-entrant callback (the host calls an  *)
(* export while an outer export's call is open, in a catch or not). A call  *)
(* that returns normally has popped every region it entered.                *)
(*                                                                         *)
(* WT (Impl = "cells"). The stack is a linked list of cells {exn, prev}    *)
(* whose top is one global, `$exc_top`: a throw pushes a cell and raises    *)
(* the tag with (exn, stack); a rethrow raises the top cell's without       *)
(* pushing; an enter saves the top pointer; a pop_exception restores it;    *)
(* the_exception reads the top cell; `rethrow(e)` writes the top cell's     *)
(* exn. A cell is an entry of Julia's stack and a pointer its depth. In a  *)
(* module that has `$exc_top`, every export calls its function through an   *)
(* entry: the entry saves `$exc_top` to a local, calls the inner inside     *)
(* a try_table that catches the tag and returns its result; at the        *)
(* handler it restores the saved top and throws the tag's payload again.  *)
(*                                                                         *)
(* THE CLAIM. On every run of host calls (nested at most MaxCalls deep),   *)
(* each a program of nested try, catch and rethrow (bounded by MaxFrames   *)
(* and MaxSteps), every `the_exception` read and every raised value is      *)
(* Julia's (Agrees, read in every state of the run, so over every call).    *)
(* The Broken instances: the value-save lowering (Impl = "values": an       *)
(* enter saves `$current_exn`, a catch sets it, a pop restores it, a        *)
(* rethrow throws it: `rethrow(e)` inside a region nested in a catch is     *)
(* undone by that region's pop); a rethrow at depth 0 that throws the top   *)
(* instead of Julia's ErrorException; a push at the catch's landing instead *)
(* of at the throw (TLC's counterexample to the first design: a rethrow's   *)
(* landing pushes a second cell, which a later `rethrow(e)` overwrites      *)
(* instead of the entry Julia overwrites, visible after the enclosing pop); *)
(* an export with no entry (KeepsEntry, the code before the entry: an       *)
(* escape leaves its cell, and the next call's `rethrow()` raises it where  *)
(* Julia raises ErrorException); an entry that also nulls `$exc_top` after  *)
(* saving it (ResetAtEntry, the naive fix: a re-entrant call no longer sees *)
(* its caller's entry, so its rethrow() raises ErrorException where Julia   *)
(* raises the caller's exception; with no re-entrant call it agrees).       *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Two exception values; a stack trace is the   *)
(* value's companion and is carried wherever the value is, so it is left   *)
(* out. Control flow is the frame stack the lowering sees: an open try      *)
(* body, an open catch body; `return`/`break` out of a catch is its        *)
(* pop_exception (Julia's lowering emits one), a finally is a catch that   *)
(* ends in rethrow(). The host is a catching frame: an escape from a call   *)
(* returns to the host, which resumes its caller (or the top level); a      *)
(* host that lets an escape unwind on into the calling export's handler is  *)
(* outside the claim until H5 (dev/MARCH.md 13.17), a regression the entry *)
(* introduced, modeled and fixed next. Calls inside the module are direct  *)
(* calls of the inner functions, which share the frame stack and need no *)
(* entry.                                                                  *)
(*                                                                         *)
(* formal(src/codegen/statements.jl compile_statement!): a try region's    *)
(* enter, catch, pop_exception, the_exception and rethrow answer as        *)
(* Julia's exception stack (emit_throw_value!, emit_rethrow!,              *)
(* emit_current_exception!, ensure_exception_top_global!, exc_saved_local! *)
(* in generate.jl; the region's enter and pop_exception in statements.jl). *)
(* formal(src/codegen/generate.jl emit_export_entry!; the export repoint   *)
(* in src/codegen/compile.jl after fill_egal_function!): an escape from an *)
(* export leaves `$exc_top` as the call found it.                          *)
(*                                                                         *)
(* parity(quarantine: Julia's per-task exception stack outlives a call;    *)
(* the host is the catching frame that restores its depth,                 *)
(* jl_restore_excstack; dart's catch state is lexical,                     *)
(* code_generator.dart:2966 visitRethrow.)                                 *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Vals, MaxFrames, MaxSteps, MaxCalls,
          Impl,             \* "cells" (the port) or "values" (the value-save lowering)
          RethrowChecksDepth,  \* FALSE = a rethrow at depth 0 throws the top
          PushAtLanding,    \* TRUE = a catch's landing pushes, not the throw
          KeepsEntry,       \* TRUE = an export has no entry: an escape leaves its top
          ResetAtEntry      \* TRUE = an export's entry saves the top, then nulls it

Nothing == "nothing"
ErrR == "errR"   \* ErrorException("rethrow() not allowed outside a catch block")
ErrO == "errO"   \* ErrorException("rethrow(exc) not allowed outside a catch block")
AllVals == Vals \cup {Nothing, ErrR, ErrO}

VARIABLES frames,   \* the open try and catch bodies of every open call, innermost last
          calls,    \* the host's open calls, innermost last
          spec,     \* Julia's exception stack
          cells,    \* WT's cells: a sequence of [exn, prev]; a pointer is an index, 0 is null
          top,      \* WT's top pointer
          cur,      \* Impl = "values": the one `$current_exn`
          obsS, obsI,  \* the last observation, Julia's and WT's
          steps
vars == <<frames, calls, spec, cells, top, cur, obsS, obsI, steps>>

Frame == [kind : {"try", "catch"}, depth : Nat, ptr : Nat, val : AllVals]
\* a host call: Julia's depth at its entry (the host's jl_excstack_state), the top the
\* entry saved (WT), and the frames below it (its caller's)
Call == [depth : Nat, ptr : Nat, val : AllVals, base : Nat]

TypeOK == /\ frames \in Seq(Frame) /\ calls \in Seq(Call) /\ spec \in Seq(AllVals)
          /\ cells \in Seq([exn : AllVals, prev : Nat]) /\ top \in Nat /\ cur \in AllVals
          /\ steps \in Nat

\* the run begins inside the host's first call
Init == /\ frames = <<>> /\ calls = <<[depth |-> 0, ptr |-> 0, val |-> Nothing, base |-> 0]>>
        /\ spec = <<>> /\ cells = <<>> /\ top = 0 /\ cur = Nothing
        /\ obsS = <<"start">> /\ obsI = <<"start">> /\ steps = 0

JuliaTop == IF spec = <<>> THEN Nothing ELSE spec[Len(spec)]
WTTop == IF Impl = "values" THEN cur ELSE IF top = 0 THEN Nothing ELSE cells[top].exn

InCall == calls # <<>>
\* the frames below the innermost call belong to its caller
Base == IF calls = <<>> THEN 0 ELSE calls[Len(calls)].base

\* the innermost open try body of the innermost call, 0 when there is none
Handler == LET ks == {k \in (Base + 1)..Len(frames) : frames[k].kind = "try"} IN
           IF ks = {} THEN 0 ELSE CHOOSE k \in ks : \A j \in ks : j <= k

\* the export's entry restores the top it saved (emit_export_entry!)
Restores == ~KeepsEntry

\* Raise: Julia's stack is already spec2, WT's cells and top are c2, t2 (before the landing);
\* sv and iv are the values each raises. It unwinds to the call's handler, whose try body
\* becomes its catch body; WT's landing pushes a cell (or sets `$current_exn`). With no
\* handler in the call, the escape returns to the host, which catches it: Julia's stack
\* returns to the call's entry depth (JL_CATCH's jl_restore_excstack); WT's entry restores
\* the top it saved and rethrows to the host.
Raise(sv, iv, spec2, c2, t2) ==
    LET k == Handler IN
    IF k = 0 THEN
        LET c == calls[Len(calls)] IN
        /\ obsS' = <<"escape", sv>> /\ obsI' = <<"escape", iv>>
        /\ frames' = SubSeq(frames, 1, c.base)
        /\ calls' = SubSeq(calls, 1, Len(calls) - 1)
        /\ spec' = SubSeq(spec2, 1, c.depth)
        /\ cells' = c2
        /\ top' = IF Restores THEN c.ptr ELSE t2
        /\ cur' = IF Restores THEN c.val ELSE cur
    ELSE
        /\ obsS' = <<"land", sv>> /\ obsI' = <<"land", iv>>
        /\ calls' = calls
        /\ frames' = [j \in 1..k |-> IF j = k THEN [frames[k] EXCEPT !.kind = "catch"] ELSE frames[j]]
        /\ spec' = spec2
        /\ IF Impl = "values"
           THEN /\ cur' = iv /\ cells' = c2 /\ top' = t2
           ELSE IF PushAtLanding
           THEN /\ cells' = Append(c2, [exn |-> iv, prev |-> t2]) /\ top' = Len(c2) + 1
                /\ cur' = cur
           ELSE /\ cells' = c2 /\ top' = t2 /\ cur' = cur

\* The host calls an export: from the top level, or re-entrantly from inside an open call
\* (a callback, possibly while that call is in a catch body). Julia records the depth; WT's
\* entry saves the top (ResetAtEntry: then nulls it; KeepsEntry: there is no entry).
HostCall ==
    /\ Len(calls) < MaxCalls
    /\ calls' = Append(calls, [depth |-> Len(spec), ptr |-> top, val |-> cur, base |-> Len(frames)])
    /\ IF ResetAtEntry THEN top' = 0 /\ cur' = Nothing ELSE UNCHANGED <<top, cur>>
    /\ UNCHANGED <<frames, spec, cells>>
    /\ obsS' = <<"call">> /\ obsI' = <<"call">>

\* The call returns normally once every region it entered is closed; the entry returns the
\* inner's result and touches nothing.
Return == /\ InCall /\ Len(frames) = Base
          /\ calls' = SubSeq(calls, 1, Len(calls) - 1)
          /\ UNCHANGED <<frames, spec, cells, top, cur>>
          /\ obsS' = <<"return">> /\ obsI' = <<"return">>

Enter == /\ InCall /\ Len(frames) < MaxFrames
         /\ frames' = Append(frames, [kind |-> "try", depth |-> Len(spec), ptr |-> top, val |-> cur])
         /\ UNCHANGED <<calls, spec, cells, top, cur>> /\ obsS' = <<"enter">> /\ obsI' = <<"enter">>

Leave == /\ Len(frames) > Base /\ frames[Len(frames)].kind = "try"
         /\ frames' = SubSeq(frames, 1, Len(frames) - 1)
         /\ UNCHANGED <<calls, spec, cells, top, cur>> /\ obsS' = <<"leave">> /\ obsI' = <<"leave">>

PopException ==
    /\ Len(frames) > Base /\ frames[Len(frames)].kind = "catch"
    /\ LET f == frames[Len(frames)] IN
       /\ spec' = SubSeq(spec, 1, f.depth)
       /\ top' = f.ptr
       /\ cur' = f.val
    /\ frames' = SubSeq(frames, 1, Len(frames) - 1)
    /\ UNCHANGED <<calls, cells>> /\ obsS' = <<"pop">> /\ obsI' = <<"pop">>

Read == /\ InCall
        /\ obsS' = <<"read", JuliaTop>> /\ obsI' = <<"read", WTTop>>
        /\ UNCHANGED <<frames, calls, spec, cells, top, cur>>

\* a throw's push (Impl = "cells", unless the landing pushes)
Pushed(v) == IF Impl = "cells" /\ ~PushAtLanding THEN Append(cells, [exn |-> v, prev |-> top]) ELSE cells
PushedTop == IF Impl = "cells" /\ ~PushAtLanding THEN Len(cells) + 1 ELSE top

Throw(v) == InCall /\ Raise(v, v, Append(spec, v), Pushed(v), PushedTop)

Rethrow ==
    LET sv == IF spec = <<>> THEN ErrR ELSE JuliaTop
        spec2 == IF spec = <<>> THEN Append(spec, ErrR) ELSE spec
        empty == IF Impl = "values" THEN cur = Nothing ELSE top = 0   \* the value-save at its best
        err == empty /\ RethrowChecksDepth   \* WT throws Julia's ErrorException, a throw
        iv == IF err THEN ErrR ELSE WTTop
    IN InCall /\ Raise(sv, iv, spec2, IF err THEN Pushed(ErrR) ELSE cells, IF err THEN PushedTop ELSE top)

RethrowOther(v) ==
    LET sv == IF spec = <<>> THEN ErrO ELSE v
        spec2 == IF spec = <<>> THEN Append(spec, ErrO) ELSE [spec EXCEPT ![Len(spec)] = v]
        empty == IF Impl = "values" THEN cur = Nothing ELSE top = 0   \* the value-save at its best
        err == empty /\ RethrowChecksDepth
        iv == IF err THEN ErrO ELSE v
        c2 == IF err THEN Pushed(ErrO)
              ELSE IF Impl = "values" \/ empty THEN cells ELSE [cells EXCEPT ![top].exn = v]
    IN InCall /\ Raise(sv, iv, spec2, c2, IF err THEN PushedTop ELSE top)

\* Rethrow is listed first: of the equally short counterexamples, TLC then reports a rethrow
Step == /\ steps < MaxSteps /\ steps' = steps + 1
        /\ (Rethrow \/ Enter \/ Leave \/ PopException \/ Read \/ HostCall \/ Return
            \/ \E v \in Vals : Throw(v) \/ RethrowOther(v))

Stop == steps = MaxSteps /\ UNCHANGED vars   \* the bound, not a deadlock

Spec == Init /\ [][Step \/ Stop]_vars

Agrees == obsS = obsI
=============================================================================
