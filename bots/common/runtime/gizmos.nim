## Public diagnostics are observational. Every build compiles them in, and they
## run only when our inspection harness starts the bot with a LOONG_INSPECT line
## (gizmos.h); in play each block costs one flag check. A block's points are
## kept out of the clock the bot reads (entry.c), so it budgets the same either
## way.
when defined(loongDiagnostics):
  var diagnosticsEnabled {.importc: "loong_diagnostics_enabled", header: "gizmos.h".}: cint
  var diagnosticPoints {.importc: "loong_diagnostic_points", header: "gizmos.h".}: uint64
  proc rawPoints(): uint64 {.importc: "loong_raw_points", header: "gizmos.h".}
  proc emitDiagnosticJson(value: cstring)
    {.importc: "LOONG_GIZMO_JSON", header: "gizmos.h".}
  ## Blocks open, so only the outermost one is timed.
  var diagnosticDepth = 0

template diagnosticBlock*(body: untyped) =
  when defined(loongDiagnostics):
    if diagnosticsEnabled != 0:
      if diagnosticDepth == 0:
        let started = rawPoints()
        inc diagnosticDepth
        try:
          body
        finally:
          dec diagnosticDepth
          diagnosticPoints += rawPoints() - started
      else:
        body

template emitGizmoJson*(value: untyped) =
  diagnosticBlock:
    emitDiagnosticJson(cstring(value))
