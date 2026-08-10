## [2026-08-10 17:45] | Task: Add a renderer text replacement candidate

### Context

The best-of-three follow-up compared Maka's merged WebContent click path with
Kimi CU 0.5.4's dedicated Electron/Web text replacement symbols and tool
contract.

### Root Cause

Maka routed every `set_value` through `AXUIElementSetAttributeValue(AXValue)`.
For Web text controls that can update Accessibility readback without proving a
trusted page input event or application callback. The existing implementation
had no renderer-specific text path despite already binding renderer PID and
process generation.

### Changes

- Restrict the candidate path to renderer-owned text roles.
- Require prior-value readback, exact focus, full selection, PID-targeted text,
  and bounded value readback.
- Treat uncertainty after accepted focus as `outcome_unknown`.
- Add deterministic success, clear, missing-readback, renderer-PID, and
  accepted-focus uncertainty tests.

### Evidence Boundary

The source tests pass, but live qualification is still pending because the
machine was locked and the executor correctly returned `screen_locked`. No live
success claim is made in this history entry.
