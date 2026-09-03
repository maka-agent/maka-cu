# 质量评分

## 评分标准

- `A`：覆盖完整、行为稳定、文档清楚、运行风险低。
- `B`：整体可接受，但还有明确短板。
- `C`：能用，但需要针对性补强。
- `D`：脆弱、缺少规范，或很多行为尚未定义。

## 当前水位

| 区域 | 评分 | 原因 | 下一步 |
| --- | --- | --- | --- |
| 产品面 | B | macOS `maka.cu/3` 已具备 snapshot/token/digest、跨 revision stable ID 与 post-action AX diff、唯一 stale refetch、WebContent trusted click、数值 slider 和语义 scroll；旧 MCP/CLI 产品面仍保留 9 tools。 | 完成签名/notarization 与 Maka release 集成，并继续收敛复杂 AX 场景。 |
| Windows runtime | C | 已新增独立 Go `.exe`，通过 Windows UI Automation + Win32 window message 暴露同样 9 个 tools、MCP server 和 `call --calls`；默认不再自动启动 app、执行 `SetFocus`，或让 `type_text` 走可能抢前台的 UIA text fallback，并已接入 npm bundled artifact 分发，但仍是功能性第一版。 | 补交互式桌面 smoke、Windows fixture、installer/signing，以及更原生的 Go UIA 实现或更稳定的 bridge。 |
| Linux runtime | C | 已新增独立 Go binary，通过 Python GI / AT-SPI2 暴露同样 9 个 tools、MCP server 和 `call --calls`；Ubuntu GNOME VM 已跑通 `list_apps`、MCP tools list 和 Text Editor 8-tool sequence，并已接入 npm bundled artifact 分发，但截图在 GNOME Wayland 下仍只能 best-effort，coordinate input 也不是通用后台模型。 | 补 Linux fixture、可重复 smoke runner、portal/compositor screenshot 路径，以及更原生的 Go D-Bus/libatspi bridge。 |
| 架构文档 | B | 顶层结构、fixture bridge、app 模式和验证路径已经落文档。 | 后续补 release artifact、code signing / notarization 和 host 集成方式。 |
| 测试 | B | `swift test` 覆盖绑定/refetch/path/readback/doctor/stable revision diff；共享 CUA Lab 已验证 WebContent、slider、scroll、stale，以及 modal/secondary open-button-scroll-close 5 轮真机闭环且目标始终后台。 | 把共享矩阵收进可选 CI/live runner，并继续扩展跨应用 modal/window 样本。 |
| 可观测性 | B | `doctor --json` 已覆盖协议/版本、TCC、锁屏、SkyLight、actual-PID SPI、coalition、签名/hardened runtime 与 readiness；另有 snapshot、smoke 和对比样本。 | 补统一日志级别、notarization/staple 诊断与 release artifact 自检。 |
| 安全 | B | 已明确本地-only、权限边界和 fixture test bridge 的作用域，并将内置 denylist 收缩到密码管理器；v3 snapshot/effect 通过精确 `CGWindowID`、应用身份与进程代际绑定获批目标。 | 增加 session approval 和更清楚的敏感 app policy，避免策略长期硬编码在仓库里。 |
