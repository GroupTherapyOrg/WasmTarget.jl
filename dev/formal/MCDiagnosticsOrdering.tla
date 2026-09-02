------------------------- MODULE MCDiagnosticsOrdering -------------------------
(* Same five-statement instance as MCDiagnostics, checked instead against the  *)
(* emission-ordering claim (ClassifyAfterEmit / InternalNeverTerminal) — a     *)
(* separate MC<Name>.tla so run_tlc.sh's MC<Name>Broken.cfg -> MC<Name>.tla    *)
(* naming convention gives this claim its own correct/broken .cfg pair        *)
(* without re-deriving the fatal-formula claim MCDiagnostics.cfg already      *)
(* covers.                                                                    *)
EXTENDS MCDiagnostics

=============================================================================
