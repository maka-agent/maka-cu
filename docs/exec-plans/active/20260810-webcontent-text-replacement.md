# WebContent text replacement

## Goal

Add a verified background `set_value` path for renderer-owned Web text controls
without weakening Maka's snapshot, identity, process-generation, or unknown-
outcome rules.

## Motivation

Kimi CU carries a dedicated Electron/Web replacement route because an AXValue
write may change Accessibility readback without delivering the page's input
behavior. Maka already binds the real renderer generation and can use that
stronger identity instead of Kimi's cached integer index.

## Boundary

- Only direct renderer-owned `AXTextField` and `AXTextArea` bindings.
- Require a readable prior value and exact focus on the retained AX object.
- Select the complete existing UTF-16 range before replacement.
- Post Unicode text or Backspace only to the bound renderer PID.
- Never activate, raise, use global input, inject JavaScript, or accept
  screenshot-only verification.
- Return `outcome_unknown` after any accepted focus write whose later result is
  uncertain.

## Verification

- Deterministic dispatch tests cover replacement, clearing, renderer PID,
  readback confirmation, missing readback, and accepted-focus uncertainty.
- The shared CUA Lab adds an offline WKWebView text field with DOM input/change
  counters, trusted-event flags, and a business-state oracle.
- Live qualification requires exact value, at least one DOM input event, no
  unintended foreground sample, and no global input path.

## Status

- [x] Add the offline Web text oracle to the shared CUA Lab worktree.
- [x] Add renderer-only text replacement and deterministic tests.
- [ ] Run the pre-change baseline against the unlocked fixture.
- [ ] Run the candidate release binary against the unlocked fixture.
- [ ] Repeat the exact-binary gate and review before opening a source PR.
