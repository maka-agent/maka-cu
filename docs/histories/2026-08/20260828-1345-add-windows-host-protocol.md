## [2026-08-28 13:45] | Task: Connect Windows Computer Use to Maka

### Execution Context
* Agent ID: Codex
* Base Model: GPT-5
* Runtime: Codex Desktop

### User Query
> Inspect Maka Computer Use and connect the existing Windows executor so Maka can use it.

### Changes Overview
Scope: `apps/OpenComputerUseWindows`, architecture and Windows execution plan.

Key Actions:
- Added a line-framed JSON-RPC `maka.cu/2` host entry beside the existing Windows CLI/MCP interface.
- Reused the embedded PowerShell UI Automation bridge for app/window inventory, observations, and semantic element actions.
- Added session and snapshot lifecycle handling, opaque element tokens, digest checks, action-time UIA revalidation, and structured stale-element failures.
- Normalized missing UIA string properties before action-time comparison so JSON `null` and PowerShell empty strings do not create false `element_changed` failures.
- Bound every host observation and semantic action to the exact `(pid, HWND)` pair instead of re-resolving `Process.MainWindowHandle`.
- Made Windows app IDs window-specific and used the UIA window name for `ApplicationFrameHost` entries so UWP windows are distinct and user-readable.
- Preserved concrete PowerShell/UIA dispatch errors in host refusal messages.
- Replaced the fabricated fixed settle result with real repeated window-digest sampling and action-specific verification (`value_readback`, `action_result`, or `tree_delta`).
- Required element tokens to carry the exact snapshot namespace before their element index is accepted.
- Kept point, key, screenshot, launch, and capture-stream capabilities explicitly disabled until they have equivalent protocol and live validation.

### Design Intent (Why)
Maka already owns the model-facing Computer Use tools and host supervision. The Windows runtime therefore implements the existing executor protocol directly instead of adding another MCP adapter or duplicating tool semantics.

### Files Modified
- `apps/OpenComputerUseWindows/main.go`
- `apps/OpenComputerUseWindows/host_protocol.go`
- `apps/OpenComputerUseWindows/runtime.ps1`
- `apps/OpenComputerUseWindows/main_test.go`
- `docs/ARCHITECTURE.md`
- `docs/QUALITY_SCORE.md`
- `docs/exec-plans/active/20260422-windows-computer-use-runtime.md`

### Validation
- `go test ./...`
- `go vet ./...`
- `GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath`
- On 2026-08-28, ran the built x64 PE in an autologged-in Windows 11 Enterprise evaluation VM on `cpu001`, using an interactive scheduled task in desktop session 1.
- The live smoke completed `host.hello`, `session.begin`, `permissions.check`, `apps.list`, `window.list`, `observe`, `dispatch.element`, spent-snapshot rejection, unsupported-key rejection, and `session.end`.
- The Notepad observation returned 249 UIA elements without truncation. `dispatch.element` used `ValuePattern.SetValue`, and the returned post-action snapshot contained `Maka Windows host smoke`.
- Maka's compiled protocol readers accepted the captured live responses as 4 apps, 4 windows, 249 elements, and an `ok` dispatch result.
- A broader live matrix then exercised two Calculator windows sharing one `ApplicationFrameHost` PID, Paint, and Notepad. It verified:
  - Calculator `Clear -> One -> Plus -> Two -> Equals` produced `Display is 3`.
  - The second Calculator window remained at `Display is 0`, proving exact HWND routing.
  - Paint selected `Color 2: White` through `SelectionItemPattern`.
  - External Notepad mutation returned `element_changed` with `changed: ["value"]`.
  - Moving the observed Notepad window returned `window_changed`.
  - A superseded snapshot returned `snapshot_superseded`.
  - A mismatched PID/HWND pair and a closed Calculator HWND both returned `window_gone`.
- Maka's compiled protocol readers accepted all 25 captured final-matrix envelopes: 14 apps, 14 windows, 15 snapshots, and 10 dispatch results.
- The passing final-matrix result SHA-256 is `de3f4d19d3b1562a7254c4bb96e801d37c0ed178cbbc7dbd48e170fd680aac9e`; the captured response SHA-256 is `ddc9c5c326ff35cd516ff0b8d88ebb7047c561e5f960421d411897fed8b6b712`.
- A second live matrix used isolated Edge and Explorer fixtures plus Windows Settings:
  - Edge round-tripped `真实 Windows ✓ 42` through `ValuePattern.SetValue`, toggled a checkbox, invoked two buttons, moved a scroll container by 207 logical pixels, and exposed the opened combo option `Beta`.
  - Explorer selected `alpha.txt`, then selected `beta.txt` while clearing `alpha.txt`, and exposed all expected View menu choices after `ExpandCollapsePattern.Expand`.
  - Settings selected `Bluetooth & devices`, returned to `System`, and scrolled the native content pane.
  - The original fixed settle response was falsified by a real Settings transition that moved the `System` item after the returned snapshot. With digest-based settling enabled, the same no-extra-observe sequence completed successfully.
- The final Edge result SHA-256 is `65b3b4d2765c9deb02216ec0dffb409e96cd75b8e83ef4f5ab3d2b5071f09a73`; its response transcript SHA-256 is `1e97fd3c5da322a4d5b20a2dad475762e50b67d6d40d69a6c4959980285d713e`.
- The Explorer/Settings result SHA-256 is `353924abc1d73225d07349d1344e61885b82088213d5b86720a10f0551164a84`; its response transcript SHA-256 is `cbb4e578bc2879db481e99213582c031495f729e78a09652d1b947b0dc37677c`.
- The live-tested Windows x64 binary SHA-256 is `76734ce69b6a59ad589880cd9465758647177a72b33ab7af6c6e7220cbc2b81e`.
- After that live matrix, a snapshot-token namespace guard was added and covered by `TestWindowsHostProtocolRejectsTokenOutsideSnapshotNamespace`; the resulting Windows x64 cross-build SHA-256 is `c5ab7e01d30f9b1b9d970524876f9979cf539553aa697e11f605105cd0e81f93`.
- The scheduled task, Notepad process, and host process were absent after cleanup.
