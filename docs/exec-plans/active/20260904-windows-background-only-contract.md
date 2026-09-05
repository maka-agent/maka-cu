# Windows strict background-only executor

## Goal

Make the Windows native executor operate supported native desktop applications without taking the user's foreground window, global keyboard, physical pointer, or clipboard. Browser workflows remain owned by Maka Browser Use/OpenCLI and are not reimplemented here.

## Scope

- Phase 1: advertise only semantic `click` and `set_value`; refuse keyboard, point, launch, scrolling, selection, and secondary actions before dispatch.
- Phase 2: establish Per-Monitor-V2 DPI awareness and report measured per-window/per-monitor scale factors.
- Phase 3: add a foreground/pointer/clipboard sentinel around semantic mutation and return a non-success result when the desktop changes during dispatch.
- Phase 4: provide packaged clean-machine and concurrent foreground-user E2E evidence before the artifact is marked distribution-ready by Maka.

Browser automation is excluded because Browser Use/OpenCLI can use browser-native page, DOM/accessibility, tab, navigation, and command state. Duplicating that work here would expand permissions and tests and would pressure the desktop executor to add coordinate/global-input fallbacks that violate the non-interference invariant.

## Safety invariants

- No `SetForegroundWindow`, `SetFocus`, global `SendInput`, physical-pointer movement, clipboard substitution, `PostMessage`, process-launch, or automatic foreground fallback exists in the native production path.
- The target must already be running; it may already be the foreground HWND/process when mutation starts because semantic UIA patterns do not require activation. The sentinel still rejects any foreground, pointer, or clipboard change during the operation.
- A semantic operation is successful only when its UIA effect is verified and the foreground HWND/PID, pointer position, and clipboard sequence remain unchanged.
- Unknown mutations are never retried automatically.
- Unsupported application/toolkit behavior fails closed.

## Risks and mitigations

- UIA providers can activate themselves asynchronously. The in-process sentinel samples the full action window; packaged E2E must additionally prove that transient activation is detected on supported Windows builds.
- Per-monitor coordinates can mix UIA physical pixels with protocol logical values. The process opts into Per-Monitor-V2 before worker creation and reports explicit scale; mixed-DPI E2E remains required.
- Reducing capabilities can expose host assumptions. Handshake and refusal tests pin the restricted surface, and the Maka PR must be tested with empty keyboard/point capabilities.

## Milestones

- [x] Create isolated branches from `maka-agent/maka-cu#8` and `apache/maka#4668` heads.
- [x] Remove foreground/global keyboard and process-launch implementations from the native executor.
- [x] Restrict the advertised and accepted action surface to semantic `click`/`set_value`.
- [x] Add Per-Monitor-V2 initialization and measured capture/display scale factors.
- [x] Add the foreground/pointer/clipboard mutation guard and protocol-level regression tests.
- [x] Build the Windows artifact with an explicit target and static MSVC CRT.
- [x] Update native documentation, architecture, and quality score.
- [x] Add the completed-task history after final verification.
- [x] Harden Maka packaging/readiness gates and tests.
- [x] Run Rust, TypeScript/Node, packaged, and static forbidden-path verification.
- [ ] Run the interactive concurrent-user/mixed-DPI E2E, or record the exact remaining external fixture blocker.

## Ablation checkpoint

The shared host protocol, supervised native helper, snapshot registry, UIA semantic actions, WGC capture, and the action-window sentinel are necessary. Removing the sentinel loses detection of transient focus/pointer/clipboard interference, so it remains. Keyboard synthesis, point dispatch, generic launch, browser control, scrolling, text selection, their fixtures/readback abstraction, and compatibility foreground modes are not necessary for the stated product goal and are removed or made unconditional typed refusals.
