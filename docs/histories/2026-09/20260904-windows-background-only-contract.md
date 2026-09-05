## [2026-09-04] | Task: Enforce the Windows background-only contract

### Changes

- Restricted the Windows executor to semantic UIA `click` and `set_value` actions and made keyboard, pointer, launch, scroll, text-selection, secondary, and browser-shaped operations fail closed.
- Removed foreground/global input implementations and the now-unused scroll readback code and fixtures.
- Added Per-Monitor-V2 process initialization, measured monitor/window DPI scale, and a full-action-window sentinel for foreground HWND/PID, physical pointer, and clipboard changes.
- Built the Windows release artifact for explicit `x86_64-pc-windows-msvc` with static CRT linkage.
- Hardened the Maka-side packaging contract so readiness cannot be enabled by local caller-authored provenance, packaged contents must exactly match a hashed file manifest, and a distribution-ready Windows executable must have a valid Authenticode signature.
- Kept browser automation out of this executor because Browser Use/OpenCLI already owns DOM/accessibility, navigation, tab, and browser command state without requiring desktop-global fallbacks.

### Verification

- `cargo test --locked --all-targets` passed (14 tests).
- `cargo clippy --locked --all-targets -- -D warnings` passed.
- `cargo build --locked --release --target x86_64-pc-windows-msvc` passed.
- The release executable imported no dynamic Visual C++ or Universal CRT runtime DLL.
- A real stdio handshake advertised only `click,set_value`; application launch returned typed `unsupported_action`.
- Maka targeted Node tests passed for the new readiness and exact-manifest gates. Three broader-suite failures remained attributable to the existing Windows/WSL path and missing generated workspace outputs, not these changes.
- Interactive concurrent-user and mixed-DPI packaged E2E remains blocked on an external test fixture and signed release artifact, so distribution readiness remains false.

### Ablation

The sentinel was retained because before/after-only sampling misses transient interference. Scroll and text-selection implementation, fixtures, and readback logic were removed because those capabilities are outside the strict background-only v1 contract and were unreachable from the advertised API.
