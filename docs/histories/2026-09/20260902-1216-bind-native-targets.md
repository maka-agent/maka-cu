## [2026-09-02 12:16] | Task: Bind native execution targets

### 🤖 Execution Context
* **Agent ID**: `OpenAI Codex`
* **Base Model**: `GPT-5`
* **Runtime**: `Codex Desktop`

### 📥 User Query
> Add the native target identity required for Maka's managed Computer Use Session Grants.

### 🛠 Changes Overview
**Scope:** macOS `maka.cu` host protocol and executor

**Key Actions:**
- **Resolve targets**: Added a side-effect-free resolver for installed applications and exact running windows.
- **Bind execution**: Added process-generation evidence and exact app, PID, and window validation around observations and effects.
- **Bind AX windows exactly**: Resolve direct windows and attached sheets through their exact `CGWindowID`, reject ambiguous/frame-only matches, and re-check the retained element immediately before effects.
- **Clarify menus**: Keep menu dispatch application-bound while window-tree dispatch remains bound to the frozen window.
- **Advance protocol**: Replaced `maka.cu/2` with the incompatible `maka.cu/3` contract and updated focused tests and documentation.
- **Remove stale harnesses**: Deleted the two hard-coded v2 proof scripts now superseded by the v3 tests and protocol tooling.

### 🧠 Design Intent (Why)
Maka must approve the same canonical application target that the native executor later reads or changes. A PID or display name alone cannot prove that binding because applications can restart and PIDs can be reused.

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/HostProtocolServer.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/HostProtocolServer+Observe.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/HostSnapshotRegistry.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/HostSystemEnvironment.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/HostProtocolTests.swift`
- `docs/HOST_PROTOCOL.md`
