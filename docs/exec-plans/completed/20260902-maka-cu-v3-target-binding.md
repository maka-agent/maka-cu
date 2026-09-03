# maka.cu/3 trusted target binding

## Goal

Provide Maka with a side-effect-free target resolver and process-generation evidence so managed Computer Use admission and native execution use the same application target.

## Scope

- Bump the host protocol directly from `maka.cu/2` to `maka.cu/3`.
- Add a read-only target-resolution method for running apps, exact windows, and installed launch targets.
- Carry canonical app identity and process generation in running targets and snapshots.
- Validate the snapshot root before and after evidence reads and before every real effect; discard evidence when the process generation changes.
- Preserve a known successful effect when only the post-action observation loses its root.
- Keep launch, TCC prompts, Accessibility reads, and application content out of target resolution.
- Update protocol documentation, focused tests, and history.

## Non-goals

- No compatibility fallback for v2.
- No Session Grant or user-approval UI in this repository.
- No Windows or Linux protocol changes.
- No new action-result causal semantics.

## Steps

1. Define the v3 wire types and side-effect-free resolver.
2. Bind snapshots and evidence to canonical root identity and process generation.
3. Add deterministic protocol, replacement, per-effect binding, and post-observation tests.
4. Update docs/history and run `swift test` plus focused host protocol tests.

## Status

Completed, including the per-effect binding and post-observation follow-up. Source parsing succeeds locally; the full Swift build and test suite
must run on the repository's matching macOS CI toolchain because this machine's
Swift compiler and SDK versions differ.
