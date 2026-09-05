## [2026-09-03] | Task: 修复 Windows `maka.cu/2` 生命周期与响应边界

### Changes

- 为 snapshot 增加 live/spent/superseded/expired/evicted 状态、TTL、每 session 上限和统一清理。
- 让 observe、dispatch、cancel、session.end 共享同一份 snapshot/image 账本；图片按 session、快照和 256 MiB 预算回收。
- 将 observation 响应在 JSON-RPC 写出前限制到 1 MiB，优先线性截断树和文本，仍超限时返回固定最小 observation。
- 删除未使用的兼容输入授权子系统，新增生命周期、图片预算和大 observation 测试。
- 增加 Windows/Linux CI 的 fmt、clippy、test、release build 门禁及 Windows provenance 摘要；分发资格保持关闭。

### Verification

`cargo fmt -- --check`、`cargo test --locked --all-targets`（10 passed）、
`cargo clippy --locked --all-targets -- -D warnings` 和
`cargo build --locked --release` 均通过。未执行 clean-machine 或 packaged
conversation E2E；本地工作树未提交，故未宣称 artifact provenance。
