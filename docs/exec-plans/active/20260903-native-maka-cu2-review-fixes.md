# maka.cu/2 Windows native executor 审查修复

## 目标

让 Windows native executor 严格满足 `maka.cu/2` 的 snapshot/image 生命周期和 1 MiB response 限制，并把可重复的验证接入 CI，使 #8 能产出可被 Maka 按 commit、digest 和 provenance 消费的 artifact。

## 范围

- 包含：snapshot TTL、消费/替换/过期/驱逐/session.end 清理，image 文件和 256 MiB 预算，1 MiB response 限制，协议测试，CI 门禁，文档和 history。
- 不包含：Maka 侧集成重建、签名发布链路本身、clean-machine 验证；这些依赖本 PR 产出的 exact artifact，在 Maka replacement PR 中完成。

## 背景

- 相关文档：`docs/HOST_PROTOCOL.md`、`docs/ARCHITECTURE.md`、`docs/REPO_COLLAB_GUIDE.md`、`docs/SUPPLY_CHAIN_SECURITY.md`。
- 相关代码路径：`apps/OpenComputerUseWindows/native/src/main.rs`、`apps/OpenComputerUseWindows/native/Cargo.toml`、`.github/workflows/`。
- 已知约束：生产 executor 只实现共享 host protocol，不复制 model-facing schema；`snapshotsPerSession=8`、`snapshotTtlMs=120000`、`maxResponseBytes=1048576`、`imageDirBudgetBytes=268435456` 必须与协议一致。

## 风险

- 风险：生命周期清理若分散在多个 dispatch 路径，可能遗漏图片或改变 stale snapshot 错误语义。
- 缓解方式：使用统一 snapshot release/cleanup 函数，测试每种终止状态，并在 session.end 断言释放计数和文件不存在。
- 风险：超大 observation 若简单返回错误，会破坏声明的 response 上限。
- 缓解方式：在序列化前使用确定性的降级/截断策略，并加入接近及超过 1 MiB 的 conformance test。

## 里程碑

1. 建立本计划和隔离分支，确认协议常量与现有状态模型。
2. 实现 snapshot/image 资源账本和统一清理路径。
3. 实现 response 上限 conformance，并清理历史兼容测试代码。
4. 接入 fmt、clippy、test、release build 的 GitHub CI 门禁。
5. 运行本地验证，记录 artifact commit/digest，更新 history 并准备推送。

## 验证方式

- 命令：`cargo fmt --check`、`cargo clippy --all-targets -- -D warnings`、`cargo test --all-targets`、release build。
- 测试：snapshot TTL、spent/superseded/expired/evicted、session.end、image 删除/预算、64 次 observe、1 MiB response。
- 手工检查：CI job 使用本次 commit，报告不引用旧 artifact；保留 `pass`、`blocked`、`unknown` 原始状态。

## 进度记录

- [x] 确认审查范围并创建隔离 worktree。
- [x] 读取协议、架构、质量、CI/CD 和供应链约束。
- [x] 完成 snapshot/image 生命周期修复。
- [x] 完成 response limit 和测试清理。
- [x] 完成 CI 门禁和本地验证。
- [x] 更新 history，检查 diff 并准备交付。

## 决策记录

- 2026-09-03：先修独立 `maka-cu#8`，再重建 Maka replacement PR；避免继续扩大原 PR 的实验产物和历史提交范围。
- 2026-09-03：`distributionReady` 不在本仓库直接被提升为 true；本仓库只提供可验证的 executor artifact，发布资格由上层 provenance/qualification pipeline 计算。

## 本次验证结果

- `cargo fmt -- --check`：通过。
- `cargo test --locked --all-targets`：10 passed。
- `cargo clippy --locked --all-targets -- -D warnings`：通过。
- `cargo build --locked --release`：通过。
- 未提交/推送：工作树包含本次修复，artifact 尚未绑定到新的 immutable commit，因此没有把本地 digest 当作发布 provenance。
