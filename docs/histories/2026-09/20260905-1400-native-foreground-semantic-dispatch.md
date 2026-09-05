## [2026-09-05 14:00] | Task: Allow safe semantic dispatch on a visible foreground target

### 🤖 Execution Context
* **Agent ID**: `Codex`
* **Base Model**: `gpt-5.6-luna`
* **Runtime**: `Rust native executor`

### 📥 User Query
> 允许已在前台的可见窗口继续执行 UIA semantic action，同时保持不激活、不抢焦点、不移动指针和身份验证边界；修复 unknown/refused 结果的 AX path、快照消费标记和原因保留。

### 🛠 Changes Overview
**Scope:** Windows native executor and its protocol documentation.

**Key Actions:**
- **Foreground safety:** removed the over-broad refusal for a target that is already foreground; the live desktop sentinel still rejects any state change during dispatch.
- **Outcome reporting:** preserved `ax_action`/`ax_attribute`, retained `outcome: "unknown"` for uncertain COM actions, and emitted numeric `error.detail.snapshotSpent` plus the enum reason.
- **Regression coverage:** added focused tests for unchanged foreground state, unknown AX dispatch, and spent-snapshot refused results.

### 🧠 Design Intent (Why)
UIA semantic patterns do not require activation, so an already visible foreground target is actionable without taking focus or synthesizing input. Snapshot spending happens before COM dispatch; the wire result must therefore distinguish pre-dispatch refusal from an action whose outcome is uncertain or refused after consumption.

The previous strict-background policy rejected a target merely because the user brought it forward to watch the result. The product contract now prohibits actively disturbing focus and input instead of requiring the target to remain in the background. This is a product behavior change, not a temporary test bypass. Process/window/element identity checks, the desktop-state sentinel, and the refusal of global keyboard/pointer fallback remain in force.

<details>
<summary>中文翻译</summary>

旧版严格后台策略会因为用户将目标窗口置前查看操作效果，就拒绝原本可执行的点击和输入。本次将产品约束从“目标必须保持后台”调整为“执行器不得主动干扰焦点与输入”，不是为了测试临时绕过保护。进程、窗口和元素身份校验、桌面状态监测以及禁止全局键盘鼠标回退的限制仍然保留。

</details>

### Validation and release boundary

- Windows MSVC unit tests: 17 passed; static-CRT release build completed.
- Local Maka conversation: created a SunCode conversation, entered and sent the requested greeting, and read the reply while the target was foreground and visible.
- Individual helper actions remained `unknown`; subsequent observations confirmed the application-level result. This does not promote helper verification to `verified`.
- The conversation used the existing full-permission task. Automatic permission admission, packaged/clean-machine E2E, concurrent user activity and broad application compatibility are not qualified by this run.
- Local binaries, hashes and test profiles are not release artifacts. `distributionReady` remains `false`.

### 📁 Files Modified
- `apps/OpenComputerUseWindows/native/src/main.rs`
- `apps/OpenComputerUseWindows/native/README.md`
- `docs/ARCHITECTURE.md`
- `docs/HOST_PROTOCOL.md`
- `docs/exec-plans/active/20260904-windows-background-only-contract.md`
