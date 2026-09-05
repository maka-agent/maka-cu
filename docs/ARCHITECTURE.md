# 架构总览

这个仓库当前已经从模板收敛成一个本地 `computer-use` 项目。macOS 主线是 Swift 实现的 `maka.cu/2` executor：它只对 Maka Electron host 说话，不再自带任何面向模型的 tool 层。Windows 已有共享 `maka.cu/2` 的 Rust/direct-COM native executor 骨架和跨机器验证证据，但仍未达到可发布状态；旧 Go runtime 继续作为兼容/实验性实现保留。Linux 仍是实验性的 Go runtime，暴露原先那组 9 个 Computer Use tools，尚未迁到 host protocol。

## 当前目录结构

- `apps/OpenComputerUse`
  主入口，负责 `host`、`doctor`、`list-apps`、`snapshot`、`turn-ended` 等 CLI 命令，以及 `-h` / `--help` / `-v` / `--version` 这类全局参数；不带参数启动时会先检查权限，只有缺失时才进入无 Dock 图标的 app 模式权限引导窗口，`doctor` 也只会在检测到缺失权限时拉起这套 onboarding UI。
- `apps/OpenComputerUseFixture`
  本地 GUI fixture app，用来承载低风险、可预测的点击/输入/滚动/拖拽验证路径。
- `apps/OpenComputerUseWindows`
  Windows runtime 目录。现有 Go CLI/MCP 入口仍通过 PowerShell UI Automation bridge 提供旧的 9-tool 兼容面；`native/` 是共享 `maka.cu/2` 的 Rust/direct-COM executor，直接由 Maka host 按 stdio 协议托管。native 产品边界是不主动干扰焦点和输入的原生桌面语义操作，允许目标已经处于前台：当前只声明 `click` / `set_value`，拒绝 keyboard、point、generic launch 及未声明动作，不包含浏览器（浏览器由 Maka Browser Use/OpenCLI 负责）。Rust native executor 仍缺少签名、打包、clean-machine、并发前台用户和混合 DPI 的完整证据，因此暂不标记为 distribution-ready。
- `apps/OpenComputerUseLinux`
  实验性 Linux runtime。它不依赖 Swift 或 `.app` bundle，Go CLI/MCP 入口会嵌入 Python AT-SPI bridge，构建产物是 `open-computer-use`，并随已有 npm 包的 `dist/linux/<arch>/` bundled artifacts 分发。
- `packages/OpenComputerUseKit`
  核心库，包含：
  - `maka.cu/2` host protocol server（`HostProtocol/`）：line-framed JSON-RPC、session/snapshot 生命周期、element token 绑定、dispatch 路径裁决
  - app discovery
  - Accessibility / 窗口 snapshot
  - 键鼠输入模拟
  - software cursor overlay
  - fixture test bridge
- `experiments/CursorMotion`
  独立的 Swift cursor motion lab，用于试验 `Bezier + arc + spring` 参数模型、调参 UI 和独立渲染，不直接耦合主 runtime。
- `experiments/StandaloneCursor`
  新的独立 Swift cursor viewer，直接复用 `scripts/cursor-motion-re/official_cursor_motion.py` 里收敛出来的候选路径、score 与 raw spring timeline，用来观察更贴近 binary lift 的表现。
- `scripts/`
  仓库级自动化命令，包括 smoke test、`.app` 打包入口、Windows `.exe` / Linux binary 构建入口、npm 分发脚本，以及 `scripts/computer-use-cli/` 这个用于探测官方 bundled `computer-use` 的 Go helper。
- `skills/`
  面向 agent runtime 的可安装 skill。当前 `skills/open-computer-use/SKILL.md` 只作为轻量入口和目录，安装、MCP/CLI 使用、排障等细节拆到相邻 `references/` 文件里按需加载；`scripts/package-skill.sh` 负责校验并打包 `.zip` / `.skill` 制品。
- `docs/`
  逆向分析、执行计划、history 和项目约束。

## 运行分层

### 1. App Mode 层

- `OpenComputerUse` 默认 app 模式会拉起 `PermissionOnboardingApp`。
- `doctor` 默认输出人类可读的协议、权限、锁屏、native capability、签名与 readiness；`doctor --json` 输出 side-effect-free 结构化报告，`--no-onboarding` 可禁止 text mode 拉起 UI。
- app bundle 以 `LSUIElement` agent-style 形态运行，默认不在 Dock 暴露常驻图标，但仍可按需显示权限窗口。
- 终端 CLI 不再通过 LaunchServices 把自己重新拉起成 app agent。macOS 通过 responsibility chain 归属 TCC 授权，被 LaunchServices 重新拉起的 helper 会拿到自己的归属和自己的弹窗；embedded executor 需要的恰恰相反，必须继承 host 的 Accessibility 授权，所以 host 直接把它当子进程 spawn。
- 主窗口负责渲染 `Accessibility` / `Screen & System Audio Recording` 两类权限卡片、`Allow` / `Done` 状态和 relaunch 后的状态收敛；当两项权限都已完成时会自动关闭，不再要求用户手动退出。
- 辅助 drag panel 会跳转到对应的 `System Settings` 页面；点击 `Allow` 后，panel 会从主窗口里的按钮位置做一段 spring + curved frame 的入场，再落到 `System Settings` 内容区下沿。panel 默认保持在窗口右侧内容区下方居中并固定贴近窗口底边，不再依赖实时扫描权限页内部 `+ / -` 控件行；窗口层级上会显式排在当前 `System Settings` 窗口之上，避免被权限列表内容盖住，同时尽量减少对系统设置自身滚动区域的干扰。panel 内也补了显式返回按钮，允许用户中断当前 guidance、回到 onboarding 主窗口重新选择权限步骤。
- 权限状态会合并 TCC 持久授权记录与当前 app 进程的 runtime preflight：TCC 中任一匹配 client 已授权即可视为 granted，避免 CLI 子进程与 GUI app 对授权状态看到不一致的结果；如果当前 `.app` 进程已经通过 `AXIsProcessTrusted()` / `CGPreflightScreenCaptureAccess()`，也会立即视为 granted，避免 stale 或不匹配的 TCC path 记录让 onboarding 浮层继续停留。正式 release 仍以 CI 打出来的 `Open Computer Use.app` 为准，而本地 debug/dev 打包现在显式命名为 `Open Computer Use (Dev).app`，并在 dev bundle 运行时优先认当前 dev 副本，避免系统设置里出现两个完全同名的条目。

### 2. Host Protocol 层（`maka.cu/2`）

- transport 是 stdio 上的 line-framed JSON-RPC 2.0：一行一个 JSON value，UTF-8，`\n` 结尾，没有 `Content-Length`。stdout 只承载 JSON-RPC，诊断一律走 stderr。
- 两层错误刻意分开：JSON-RPC `error` 只表示请求本身不可用（`-32000` 版本不匹配、`-32001` 未握手、`-32002` 未知 session、`-32003` 正在退出）；世界的状态一律是 `result` 里的 `{ ok: false, error: { code, message, detail } }`，`code` 是闭集，`message` 由 `code` 决定，`detail` 只有枚举和数字。
- 当前 method：`host.hello`、`session.begin` / `session.end`、`observe`、`window.list`、`apps.list`、`permissions.check`、`apps.launch`、`dispatch.element` / `dispatch.key`、`screen.capture`，以及 `$/cancel` notification。`dispatch.point` 仅作为旧 host 的兼容拒绝端点保留，固定返回 `unsupported_action`，不会解析 snapshot、读取目标或发送输入。`capture.start` / `capture.next` / `capture.stop` 已预留，v1 一律返回 domain 结果 `not_implemented`，而不是 `-32601`——这样 feature detection 是一次稳定的字段读取，方法名也不会被别的东西占掉。
- 握手带回 executor 版本、capabilities 和全部 limits。host 不允许硬编码 executor 负责执行的边界，因为过去两侧各写一份、谁都发现不了漂移。
- 并发按 lane 组织：`control`、`target:<pid>:<windowId>`、`misc`、`capture:<streamId>`。同 lane 严格 FIFO，跨 lane 并发；所以同一窗口的 dispatch 永远不会超过产出它 snapshot 的 observe，而未来的 capture 长轮询也不会挡住 dispatch。
- 每个 snapshot id 都带一个 128-bit 的 per-process nonce。executor 重启后，上一代的 id 一定 `snapshot_unknown`，不会静默命中新状态。
- 每个窗口 observation 还维护一条 executor 内部 revision：首轮按 DFS 分配非负 `stableId`，后续 sibling-scoped 结构匹配继承旧 id，新元素从历史最大值之后继续分配。`stableId` 只用于模型展示与差分，真实 dispatch 仍映射回当前 snapshot 的 opaque token。
- 同一 session/window 的后续 snapshot 可带 `difference`：空变化标为 `no-change`，有效变化按 path 与 remove/insert/update 顺序输出，删除 id 压缩为 range；差分行数大于完整树时标为 `full`。完整 `elements` 始终随 snapshot 返回，runtime 只在动作后的 observation 渲染差分，显式 observe 继续显示完整树。

### 3. Service 层

- host protocol 自己实现 observe 与 dispatch：`observe` 产出结构化的 AX 树 + element token，可执行 mutation 通过 `dispatch.element` 或绑定已验证焦点的 `dispatch.key` 完成。生产动作面不接受坐标输入，也不把 semantic action 降级成 point event。它不复用 `ComputerUseService` 的 index 定址入口——把协议接到 index 上就等于把协议存在的理由接回来了。
- mutation 消费 snapshot 的 dispatch authority，但 spent snapshot 的 revision 仍可作为下一次 post-action observation 的差分基线；expired/evicted snapshot 不参与。这样动作后的模型输入可以只写有效变化，又不放宽 single-use snapshot 合同。
- `{kind: "app"}` 按 window inventory 的前到后顺序选择当前 sheet/窗口；`{kind: "window"}` 严格按 PID + window ID。AppKit sheet 在 CGWindow 侧是独立窗口、在 AX 侧是主窗口的 `AXSheet` / `AXDrawer` child，匹配顺序固定为 direct AXWindow 后 child sheet。
- CGWindow 已出现但对应 AXWindow/AXSheet 尚未发布时，会对同一 PID/window/frame 最多重读 250ms；window inventory 本身不存在目标时仍立即 `window_gone`，不会回退到别的窗口。
- host protocol 会同时绑定宿主 app 与真实 input-owner 的 PID/start time。WKWebView/WebContent 通过动态解析 `_AXUIElementGetActualPid` 识别；冷启动时用 XNU resource + jetsam coalition 的唯一 WebContent 关系做 readiness gate，首轮没有 `AXWebArea` 时等待 250ms 后重读一次。
- observation 会删除被唯一真实 WebContent 元素遮蔽的叶子 accessibility mirror；歧义或非叶子 mirror 保留。WebContent 左键点击使用 host window 的精确 `CGWindowID` 和单通道 private SkyLight 事件，WindowServer 完成 renderer hop，不再走会产生 `isTrusted=false` 的 AX/JavaScript mirror。
- retained AX 引用失效时允许同一进程世代内的唯一 identity-preserving refetch；只有 renderer-owned live 引用可在仅发生 `frame` reflow 时进入同一恢复路径。原生 AX 的 frame 变化和其它 digest 字段变化仍立即 fail closed，missing 与 ambiguous 分别拒绝为原始 stale code / `element_changed`。
- `ComputerUseService` 现在只服务 `list-apps` / `snapshot` 这两个人类调试命令。它的 action 方法与点击启发式暂时保留在库产品面上，等 host protocol 的 dispatch 在真机上验完再决定去留。
- `list_apps` 通过 Spotlight metadata query 拉取标准 application 目录里的 app bundle，并读取 `kMDItemUseCount` / `kMDItemLastUsedDate_Ranking` 这类系统元数据；再与 `NSWorkspace` 的运行态 app 合并，输出“当前运行中 + 近 14 天用过”的视图。
- `get_app_state` 优先走真实 AX / 窗口截图；真实 app 必须同时有未最小化的 `AXWindow` 和可匹配的 on-screen `CGWindow`。如果目标 app 只是隐藏或暂时没有 on-screen window，会先 best-effort unhide / activate / `open -b` / `AXRaise` 并短暂重试，以贴近官方 `computer-use` 会把 Lark / Electron 窗口拉回再采集的行为；恢复后仍无法匹配时返回官方风格的 `Apple event error -10005: cgWindowNotFound`，不再把 application 根节点或无截图窗口伪装成可操作状态。当目标是仓库内 fixture app 时，回退到 fixture 导出的合成状态。真实 AX tree 默认在 macOS、Linux、Windows 上最多渲染 1200 个节点、64 层深度；显式 `get_app_state` / `snapshot` 可通过 `max_tree_nodes` / `max_tree_depth` 覆盖预算，action tools 的刷新结果仍使用默认预算。snapshot 文本默认截断到 500 字符；显式 `get_app_state` / `snapshot` 可通过 `text_limit` 正整数或 `"max"` 覆盖，action tools 的刷新结果仍使用 500 字符默认值。对 Electron/WebView 这类深层 UI 会压缩空 `AXGroup` / `AXUnknown` wrapper、过滤 `AXScrollToVisible` 噪音和空字符串属性，避免 action-critical 的输入框被无语义容器挤出节点预算；但如果匿名通用节点暴露 `AXPress` / `AXConfirm` / `AXOpen` 且 frame 有效、尺寸紧凑，会保留为带窗口相对 `Frame` 的 `button`，让 icon-only Web 控件仍能获得可区分的 `element_index`，同时继续过滤零尺寸或覆盖大面积页面的匿名点击容器。对原生 open panel / Finder column view 这类把内容放在 `AXContents` / `AXVisibleChildren` 里的控件，也会把可见文件项纳入元素树。
- host protocol 的 `observe` 不输出任何渲染文本：没有 tab 缩进的树，没有 `list_apps` catalogue。模型看到的每个字都由 Maka runtime 负责，executor 里再放一份就是第二份会漂移的副本。
- `dispatch.*` 的每个结果都带齐 `outcome` / `tier` / `path` / `effect` 四个闭集字段，外加 `verification`。`path` 与 `tier` 的配对是固定表；host 收到表外的组合应当按协议违规处理，而不是二选一。
- 单次 left press / `press` / `cancel` 如果在创建或关闭 sheet/window 的同时收到 AX `cannotComplete`，只允许在低于 host request deadline 的 5 秒内连续两次确认目标 PID 的 on-screen window ID 集合已变化后恢复为成功；关闭目标时 post-observation 仍携带 `window_gone`。其他 unknown outcome 不使用这条恢复。
- macOS element action 前后会读取真实 WindowServer 前台 PID；只有目标 app 自己抢到前台时才请求恢复动作前的精确 PID，用户切到第三个 app 时不干预。activation 与 z-order 传播是异步信号，不改写业务 outcome；是否保持后台由独立 live foreground sentinel 验证。Windows 的不干扰边界另见下文，不改变此 macOS 行为。
- 对真实 app 的 `get_app_state` / action tool 入口，当前只保留一层密码管理器 bundle denylist：bundle-id 直传时直接返回 safety denial；名称匹配时默认不解析到这些 app。终端、Chrome / Atlas 和系统组件不再属于内置阻止目标。
- 普通 app 的 element frame 当前按“窗口左上角为原点”的 window-relative 坐标输出，便于后续把 `element_index` 和截图坐标统一到同一套参考系。
- `click` / `set_value` 在执行真实动作前后，会额外驱动一层透明 `SoftwareCursorOverlay` window：两者的移动阶段现在共用一条 heading-driven 的官方风格 motion 内核，显式把“当前 cursor 朝向”和“最终 resting pose”一起喂给选路器，优先生成需要时先掉头、再沿车头方向推进的 C 形/单侧大弧轨迹；首次显示时按官方 binary 的 fresh state 从 AppKit 全局 `(0,0)` window origin 生成起点，后续动作继续复用上一帧 visible tip。真正显示出来的 cursor 不再直接等于 path sample，而是经过一层独立的 visual dynamics 状态，把 visible tip、velocity、angle 和 fog/offset 持续推进。`click` 结尾会衔接 click pulse 和更明显但仍然很小的 rotate wobble，`set_value` 则只做 settle / idle，不给 pulse；两者收尾后会在目标点继续保持 idle 状态，等待下一次动作时 tip 保持 anchored、只保留可感知的小角度摆动；只有连续 30 秒没有新动作时才做 cleanup，这样连续 tool call 不会反复从 fresh `(0,0)` 起步；如果宿主在任务 / turn 结束时发出 `turn-ended`，cursor 会立即消失并清掉本轮位置状态。
- overlay 的 visual style 不再自己从官方 app bundle 裁 `SoftwareCursor` 小图；主 runtime 现在和 `CursorMotion` 一样优先渲染仓库里沉淀的 `official-software-cursor-window-252.png` baseline，只有资源缺失时才退回 `OpenComputerUseKit` 内部的程序化 pointer/fog fallback。命中点 anchor 仍固定在 `126x126` 画布里的同一组 tip-offset 上；glyph 自身的 neutral heading 继续沿用 `CursorMotion` / 官方 baseline 的 `-3π/4`。主 runtime overlay window 按 AppKit 全局坐标移动，因此在把 AX / `CGWindowList` 产出的 y-down screen-space 点击目标喂给 overlay 之前，会先转换成对应屏幕的 AppKit 全局坐标；路径选路用屏幕上实际可见的 AppKit forward heading，进入 visual dynamics / render state 前则把 velocity 的 y 轴翻回 CursorMotion 的 y-down screen state，再交给 AppKit 绘制层做角度和 `dy` 翻转。程序化 fallback 保留 neutral artwork correction，把它的天然轮廓轴对齐到 `CursorMotion` / 官方 baseline 的 `-3π/4` forward 方向，但不让实验线依赖 runtime 代码。
- overlay 的层级不再固定 `.floating`；现在会跟随 snapshot 命中的目标 window id / layer，把自己排到该目标 window 之上，而不是粗暴压到所有前台 app 最上层。
- overlay 的曲线路径不再只按固定 Bezier 模板生成；当前主线采用 reverse-engineering 约束下的 heading-driven candidate 族，候选只保留 `direct` / `turn` / `brake` / `orbit` 这些能稳定产出单侧主弧的 family，并继续保留 target-window 命中策略作为同类候选间的 tie-break。原始 binary lift 恢复出来的 `20` 条路径和 score 仍然保留在独立的 `StandaloneCursor` viewer / Python 重建脚本里，用于对照分析，不再直接作为 runtime 默认 chooser。
- overlay 的 progress 曲线也不再是固定 `easeInOut`；主线现在复用官方 `response=1.4`、`dampingFraction=0.9`、`dt=1/240` 的 spring/`VelocityVerlet` 形状，默认 move 时长对齐已恢复出的 close-enough endpoint-lock 时间 `343 / 240 = 1.4291667s`，不再按路径距离额外压缩。
- overlay 不再依赖临时 `terminal settle` 补丁来修尾；主线现在统一改成“路径层给目标点，visual dynamics 层给可见姿态”的双层模型，所以 move 末段、pulse 和 idle 共用同一套状态，不会再出现 endpoint 锁住后只剩原地翻角的收尾。
- overlay 的渲染输入也从单一 `rotation` 扩展成 `rotation + cursorBodyOffset + fogOffset + fogScale`，让速度滞后能真正体现在画面上，而不是只存在于主循环内部状态；其中 `rotation` 现在按二进制里 `SoftwareCursorStyle.angle + CursorView._animatedAngleOffsetDegrees` 的分层去近似，不再把“跟随运动方向的主朝向”和“小幅 wiggle offset”压成同一个受限小角度。
- 动作型 tools 对普通 app 采用“非侵入优先，物理指针路径显式 opt-in”策略：
  - `perform_secondary_action` 只执行目标元素已经暴露出来的 AX action；无效 action 返回官方风格的 `... is not a valid secondary action for ...`，fixture 的 `Raise` 路径也不再为了测试去准备全局物理指针输入
  - `set_value` 会先用 `AXUIElementIsAttributeSettable(kAXValueAttribute)` 判断目标是否真的是可设置值元素；字符串/布尔/数值按 live AX 类型写入。带 increment/decrement 的数值控件优先走可回滚步进动作，让应用业务回调与 readback 同时到达请求值。
  - `click.click_method` 是开源版的可选扩展，支持 `auto`（默认）、`accessibility`、`app_post`、`sky_click` 和 `global`。未传参数时继续使用原有自动路由；显式模式不会静默 fallback 到其他实现。`accessibility` 只接受 `element_index`；其余 mouse 路径可以使用 `element_index` 的计算落点或原始 `x/y` 坐标。
  - element-targeted `click` 的 `auto` 左键路径会先试原生列表的 `AXSelectedChildren` 选择，再试 `AXPress` / `AXConfirm` / `AXOpen` 这类真正语义化的激活动作；如果目标本身不可点，还会继续尝试其子孙 AX 元素（例如 Finder sidebar row 下面暴露 `AXOpen` 的 cell）和命中点附近的 AX hit-test 结果，最后进入现有 non-AX 分支：未开启全局指针环境变量时使用 `postToPid` 定向鼠标事件，开启时直接使用全局 HID 事件。`AXRaise` / `kAXMainAttribute` / `kAXFocusedAttribute` 这类 activation-only fallback 只允许窗口级元素使用，避免普通静态文本或容器把“获得焦点”误报成“点击已处理”；`click_count > 1` 也会优先重复可用的 AX action。
  - 显式 `click_method=accessibility` 只执行上述 AX 语义动作；显式 `click_method=app_post` 绕过 AX 候选和后代扫描，直接通过 `CGEvent.postToPid` 向目标进程发送 `mouseMoved` / down / up；显式 `click_method=sky_click` 只在 macOS 接受左键单击/双击，它验证当前 snapshot 的 `CGWindowID` 仍为同一 PID 所有且 on-screen，仅通过 `SLPSPostEventRecordTo` 让目标应用短暂进入 synthetic-active 状态，绝不向真实前台应用发送 defocus record，再按 Chromium-compatible recipe 发送 target move、`(-1,-1)` primer 和真实 down/up。每个鼠标事件同时经动态解析的 `SLEventPostToPid` 与公开 `postToPid` 投递，并带 window-local location、PID/window 和 click-group 字段；renderer settle 后只撤销目标的 synthetic-active 状态。`sky_click` 的 action-result snapshot 刷新也禁止 activate / `AXRaise` 恢复，目标状态瞬时不可读时直接失败。它不改变 `auto`，任一步失败也不 fallback。显式 `click_method=global` 同样绕过 AX，但通过 `.cghidEventTap` 发送系统级指针事件。`global` 还必须设置 `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1`，否则在移动 visual cursor 或发送输入前拒绝请求。
  - 对 renderer 合成的 summary `text` 行，`click` 不再默认点击父容器中心；这类元素使用左侧安全锚点。对普通 row/container/text 的后代候选，也会过滤右侧紧凑 hover action（例如 Lark / Electron 会话列表里的“完成”勾），避免把主行点击误操作成 side action；Electron/Lark 这类 app 的 WebArea 合成文本会优先寻找紧邻的行级 `AXPress` 祖先并静默执行，避免用物理鼠标点行。浏览器 WebArea（例如 Chrome/GitHub）不走这条 Electron-scoped 行级祖先点击优化，仍保留通用 link/container 点击路径。命中点如果只反查到覆盖整页的 Electron/WebArea 级 AX 元素，不再继续扫描整个大容器的子孙候选，避免一次行点击被远处的可点击元素截走。
  - `AXUIElementCopyElementAtPosition` 做坐标命中，尽量把 coordinate click 反解成可操作 AX 元素
  - `CGEvent.postToPid` 定向发送键盘事件，避免为了 `type_text` / `press_key` 抢前台；`type_text` 会把文本按 Unicode extended grapheme cluster 聚合成小批量 `keyboardSetUnicodeString` 事件，避免中文标点、emoji / 代理对和组合字符被逐个 UTF-16 code unit 拆开后在 Electron 富文本输入框里乱序或变形。如果当前 focused element 的 `AXValue` 可设置，`type_text` 会优先按可编辑内容追加并写回 `AXValue`，这覆盖 Feishu / Electron 富文本输入框不可靠接收后台键盘事件的场景，并会过滤已知占位提示，避免把 placeholder 拼进草稿；如果当前 focused element 不是可编辑文本目标，`type_text` 会报错要求先 click 文本输入区或使用 `set_value`，不再把无效果的后台键盘投递当成成功；`press_key` 的 xdotool parser 覆盖官方 binary key table 里常见的 `BackSpace`、`Page_Up`、`Prior` / `Next`、`F1...F12` 和 `KP_*` alias
  - `scroll.pages` 对齐官方 `1.0.755` 的 `number` schema，支持小数页数；整数页优先走 `AXScroll*ByPage`，其无副作用拒绝后再按 `AXIncrementPage` / `AXDecrementPage` 子元素翻页，最后才使用 PID-bound wheel event。
  - `drag` 仍是 coordinate-only API，但默认不再使用全局 `.cghidEventTap` mouse event；默认改为 `CGEvent.postToPid` 定向发送 mouse move / down / dragged / up 事件，避免移动用户真实硬件光标；这些 coordinate tool 的 `x/y` 先按 screenshot pixel 坐标解释，再依据截图像素尺寸与目标 window bounds 的比例映射回 window point / Quartz global 坐标，避免 Retina 窗口上把 2x 像素误当成 1x point 导致点击落到错误位置
  - `click` / `scroll` / `drag` 在环境变量未开启的默认配置下不会走全局 `.cghidEventTap`，因此不会移动或抢占用户真实鼠标；`OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` 是全局指针能力的进程级安全门，显式 `click_method=global` 仍必须通过这层授权。默认路径不再为了 fallback 调用 `NSRunningApplication.activate`

### 4. Fixture Bridge

- `OpenComputerUseFixture` 会把自己的窗口与元素状态写到临时 JSON 文件。
- 对 fixture 的 `get_app_state` 和少量测试专用动作，会通过 `FixtureBridge` 走显式 command 通道。
- 这个 bridge 只服务于仓库内 deterministic smoke path，不是面向真实第三方 app 的能力边界。
- 因为 SwiftPM 裸 executable 形式启动的 fixture 没有稳定的 bundle identifier，`list_apps` 会仅对 `OpenComputerUseFixture` 注入一个内部 synthetic identifier，保证 smoke suite 仍能覆盖 `list_apps`，普通第三方 app 仍按真实 bundle id 输出。

### 5. Cursor Lab

- `StandaloneCursor` 是一个新的独立 SwiftUI/AppKit demo target，可通过 `swift run StandaloneCursor` 本地启动。
- 这条线优先验证 Python 重建脚本已经收敛出来的核心：`20` 条候选路径、`measure + score`、`prefer in-bounds then lowest-score` 选路，以及 `response=1.4` / `dampingFraction=0.9` / `dt=1/240` 的 raw spring timeline。
- 当前它刻意不引入 speculative 的 wall-clock duration 映射，也不复用 `CursorMotion` 里更偏视觉手感试验的 pose dynamics。
- `CursorMotion` 是一个单独的 SwiftUI demo target，可通过 `swift run CursorMotion` 本地启动。
- 这条线优先验证 motion model 本身：当前主线是 heading-driven 的 turn / brake / orbit / direct candidate 族、spring progress、独立 visual dynamics 和 debug UI；moving 阶段真正画出来的箭头角度会持续跟随 visual dynamics 的主 heading，接近停住后再平滑回到默认 resting pose，并在 idle 阶段保留原地小摆角。
- lab 的 cursor 视觉继续以 `scripts/render-synthesized-software-cursor.swift` 为参考：优先使用仓库里保存的官方 `252x252` runtime baseline 图，缺失时再退回脚本里的 procedural pointer/fog 近似；settle 态也改成中心固定的小幅摆角，而不是继续沿 XY 轻微漂移。
- 当前它不接真实 tool call，也不回写主 `SoftwareCursorOverlay`，目的是把实验噪音与产品行为边界隔离开。

### 6. Windows Runtime

- Windows 有两条明确隔离的实现路径：旧 Go runtime 维护 CLI、`call --calls` sequence、MCP JSON-RPC、tool schema 和进程内 snapshot cache；`apps/OpenComputerUseWindows/native` 的 Rust executor 只实现共享 `maka.cu/2` host protocol，不复制面向模型的 tool schema 或第二套生产 supervisor。
- Rust native executor 使用 Windows UI Automation 的 direct-COM 路径、Win32/WGC 窗口枚举与截图，并在 dispatch 时重新校验 PID、进程启动时间、window generation、RuntimeId 和 snapshot/token 绑定。坐标 dispatch 在协议边界保持 typed refusal；语义动作的执行结果不能仅凭 helper 调用成功宣称 verified，缺少应用层 readback 时保持 `unknown`。
- Rust native executor 的跨机器验证入口与结果位于 `experiments/maka-cu-windows-rust` 和 `experiments/maka-cu-windows`；正式源代码位于 `apps/OpenComputerUseWindows/native`。当前验证已覆盖 fixture 生命周期/协议、WPF、Chromium、.NET 10 WPF 和隔离临时 profile 的 LibreOffice Writer probe，但旧 comparison harness 仍发送已废弃的私有协议，不能作为 Rust native 的有效回归入口。
- 构建入口是 `scripts/build-open-computer-use-windows.sh --arch arm64|amd64`，默认输出到 `dist/windows/<arch>/open-computer-use.exe`；npm release package 会把两个 Windows artifact 内置到已有 root/alias packages，Node launcher 按 `process.platform/process.arch` 自动选择。
- Go runtime 通过 `go:embed` 带上 `runtime.ps1`，执行 tool call 时临时落盘并调用 Windows PowerShell。PowerShell bridge 使用 `System.Windows.Automation` 做 app/window/element discovery、tree rendering、UIA pattern action、ValuePattern set value 和 ScrollPattern scroll；当目标 app 不暴露对应 pattern 时，fallback 到 `PostMessage` / `SendMessage` 形式的 Win32 window message。
- Windows runtime 默认只连接已经运行的 app，不会在 `get_app_state` 找不到进程时自动 `Start-Process`，也不会默认允许 `SetFocus` secondary action；这两条前台抢占路径分别需要 `OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH=1` 和 `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1` 显式打开。`type_text` 默认优先对可写文本控件的 child HWND 发送 `EM_SETSEL` / `EM_REPLACESEL`，不再默认走可能触发前台激活的 UIA `ValuePattern.SetValue` fallback；需要旧行为时必须设置 `OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK=1`。UIA pattern 和 Win32 message fallback 本身仍是 best-effort：很多控件可以在后台响应，但 Windows 没有一套对所有 GUI toolkit 都等价于 macOS AX 的后台键鼠输入模型。
- 这 9 个 tool 的协议面与 macOS 主线保持一致：`list_apps`、`get_app_state`、`click`、`perform_secondary_action`、`scroll`、`drag`、`type_text`、`press_key`、`set_value`。其中 element-targeted action 会优先复用上一轮 `get_app_state` 的 runtime id / automation metadata，coordinate action 使用 screenshot/window-relative 坐标。
- Windows `click_method=accessibility` 映射到 UI Automation pattern，`app_post` 映射到 HWND `PostMessage`；macOS-only 的 `sky_click` 和没有实现的 `global` 都会在 snapshot lookup 前明确返回 unsupported。`auto` 仍保持 UIA 优先、window message fallback 的现有行为。
- Windows UI Automation 需要运行在已登录用户的桌面 session 里。通过 SSH 作为脱离桌面的后台进程运行时，PowerShell 可以启动并返回 JSON，但系统可能不给它暴露顶层窗口；这种情况下 `list_apps` 会是空，`get_app_state` 可能返回 `appNotFound(...)`。
- 旧 Go runtime 仍是功能性第一版；Rust native executor 也不是生产发布物：当前 Windows 打包会受 MSVC Spectre-mitigated library 安装状态影响，尚未完成 code signing、installer/servicing、clean-machine 验证、打包后 Maka conversation E2E 和足够宽的真实应用矩阵。`bundled-tools.json` 的 `distributionReady` 必须保持 `false`，直到这些条件都有证据。

### 7. Linux Runtime

- Linux runtime 位于 `apps/OpenComputerUseLinux`，以 Go 维护 CLI、`call --calls` sequence、MCP JSON-RPC、tool schema 和进程内 snapshot cache。
- 构建入口是 `scripts/build-open-computer-use-linux.sh --arch arm64|amd64`，默认输出到 `dist/linux/<arch>/open-computer-use`；npm release package 会把两个 Linux artifact 内置到已有 root/alias packages，Node launcher 按 `process.platform/process.arch` 自动选择。
- Go runtime 通过 `go:embed` 带上 `runtime.py`，执行 tool call 时临时落盘并调用 `python3`。Python bridge 使用 GNOME/GObject Introspection 暴露的 AT-SPI2 接口做 app/window discovery、accessibility tree rendering、semantic action、editable text、value set，以及 best-effort 的 key/mouse fallback。
- Linux 上最接近 macOS AX 的是 AT-SPI2/D-Bus accessibility，而不是一套统一的后台键鼠输入模型。第一版优先使用元素暴露的 AT-SPI action、EditableText 和 Value 接口；coordinate `click` / `drag` 与 `press_key` 使用 AT-SPI event synthesis fallback，在 Wayland 下只能按 best-effort 处理。
- Linux runtime 需要运行在已登录桌面用户 session 里。缺少 `XDG_RUNTIME_DIR`、`DBUS_SESSION_BUS_ADDRESS` 或 display 环境时，Go runtime 会在启动 Python AT-SPI bridge 前尝试从 `/run/user/<uid>` 和常见桌面进程自动发现当前用户的 session bus、display / Wayland 值；纯 SSH tty 如果找不到已登录桌面 session，可以启动二进制，但不能直接 inspect 或操作 GUI session。
- `get_app_state` 的 accessibility tree 在 GTK/GNOME app 上可能很深，Linux bridge 使用与 macOS / Windows 一致的 1200 节点、64 层默认 tree budget，并支持显式提高 `max_tree_nodes` / `max_tree_depth`。截图通过 GDK root window best-effort capture；GNOME Wayland 可能返回黑图，bridge 会检测全黑采样并省略 image block。
- 这 9 个 tool 的协议面与 macOS / Windows 保持一致：`list_apps`、`get_app_state`、`click`、`perform_secondary_action`、`scroll`、`drag`、`type_text`、`press_key`、`set_value`。其中 element-targeted action 会优先复用上一轮 `get_app_state` 的 runtime path metadata，coordinate action 使用 screenshot/window-relative 坐标。
- Linux `click_method=accessibility` 映射到 AT-SPI action，`global` 映射到 AT-SPI mouse synthesis 并要求全局指针环境变量；AT-SPI 没有等价的进程定向 mouse dispatch，因此 `app_post` 和 macOS-only 的 `sky_click` 会在 snapshot lookup 前明确返回 unsupported。`auto` 仍保持 AT-SPI action 优先、mouse synthesis fallback 的现有行为。
- 当前 Linux 侧仍是功能性第一版：没有 visual cursor overlay、没有 installer/desktop entry，也没有独立 Linux fixture。后续 TODO 记录在 `docs/exec-plans/active/20260422-linux-computer-use-runtime.md`。

## 关键边界

- 开源版当前不复刻官方闭源实现里的 caller signing、私有 IPC、完整 overlay choreography 和 plugin 自安装逻辑。
- 因为官方 `SkyComputerUseClient` 带有宿主侧 launch constraints，普通 stdio MCP client 在本机上可能被系统直接杀掉；如果要探测官方 bundled `computer-use`，`scripts/computer-use-cli` 的 app-server 模式现在只适合做工具清单和协议面观察。官方 `1.0.755` 的真实 tool call 还会经过 service-side sender authorization / active IPC client 追踪，外部 raw helper 即使走已签名 Codex binary，也可能返回 `Sender process is not authenticated`；需要真实使用官方工具时应走正常 Codex agent/tool 调用链，本仓库这条线现在只对 Maka host 说 `maka.cu/2`，不再提供可直连的 MCP server。
- 当前权限引导已经具备可运行 app、深链、拖拽辅助，以及一版更接近官方的 accessory panel 入场动画和返回 affordance；点击链路也已经补上独立 visual cursor、官方 asset fallback 和相对目标 window 的排序逻辑，并且在 overlay 可见期间会持续重申“排在目标 window 之上”，避免用户手动激活目标 app 后 cursor 被目标窗口重新盖住；但整体还没有完全复刻官方那套嵌入式 choreography / host 集成 / session approval 体验。
- host protocol 的截图一律以文件路径返回，写在握手声明的 `imageDir` 里，生命周期与 snapshot 绑定；line-framed 通道上内联 base64 是 4/3 膨胀，而且一条 8 MB 的行会把其它待回的响应全部堵住。调试命令仍走 `ScreenCaptureKit` 捕获目标窗口，不再把普通 app 截图落盘到仓库或临时目录；编码前会按最大尺寸和目标字节数自适应缩小，避免复杂页面的大 PNG 触发 host 侧 MCP result 降级，同时 coordinate tools 继续按实际返回的 screenshot pixel 尺寸映射坐标；单次 ScreenCaptureKit capture 会设置超时，超时后省略 image block 而不是卡住整个 `get_app_state`。
- host protocol 的会话状态是进程内内存态：每个 session 持有自己的 snapshot 集合、element token 字典和保留的 `AXUIElement` 引用；Windows native executor 同样按 120 秒 TTL、同窗 supersession 和每 session 八张 live snapshot 维护状态，并把图片账本绑定到 snapshot 或 session。`session.end` 会一次性释放 snapshot、删除本会话写出的图片，并把释放计数报回去，好让这类回归有断言可写。
- Windows native executor 在建立任何 UIA/WGC worker 前启用 Per-Monitor-V2 DPI awareness，并分别报告 window/monitor 的实际 scale factor。每次语义 mutation 前后读取前台 HWND/PID、物理鼠标位置和 clipboard sequence；目标已经处于前台时仍允许 UIA semantic pattern，动作期间这些状态发生变化时不得报告成功。实现中不存在 `SetForegroundWindow`、`SetFocus`、全局 `SendInput` 或 generic process launch 路径。
- 本仓库旧 MCP/CLI 产品面仍有历史坐标 API；它和 Maka 的 `maka.cu/2` host protocol 是不同边界。Windows、macOS 和后续平台接入 Maka 时必须共享 semantic-only host contract，不能从旧 MCP/CLI schema 派生第二套 model action space 或 fallback ladder。

## 主要验证路径

- 单元测试：`swift test`
- standalone cursor 构建：`swift build --product StandaloneCursor`
- cursor lab 构建：`swift build --product CursorMotion`
- host protocol 一致性向量：`swift test --filter HostProtocolTests`
- app 打包：`./scripts/build-open-computer-use-app.sh debug`
- 权限 onboarding 端到端回归：`./scripts/run-permission-onboarding-e2e.sh`（需要当前 macOS 对被测 `open-computer-use` 已授予 Accessibility 与 Screen Recording；默认禁用 app-agent proxy 来测试当前 CLI 运行态，可用 `OPEN_COMPUTER_USE_E2E_CLI=/path/to/open-computer-use` 指定被测 CLI，或用 `OPEN_COMPUTER_USE_E2E_DISABLE_APP_AGENT_PROXY=0` 显式覆盖默认代理行为）
- npm staging：`node ./scripts/npm/build-packages.mjs`
- release tgz：`./scripts/release-package.sh`
- skill 打包：`npm run package:skill`
- Windows runtime 单测：`(cd apps/OpenComputerUseWindows && go test ./...)`
- Windows exe 构建：`./scripts/build-open-computer-use-windows.sh --arch arm64`
- Linux runtime 单测：`(cd apps/OpenComputerUseLinux && go test ./...)`
- Linux binary 构建：`./scripts/build-open-computer-use-linux.sh --arch arm64`
- 对比样本：`artifacts/tool-comparisons/20260417-focus-behavior/`
- 手工诊断：
  - `open-computer-use doctor`
  - `open-computer-use doctor --json`
  - `open-computer-use snapshot <app>`
  - `open-computer-use list-apps`
  - `open-computer-use host`（读 stdin 的 `maka.cu/2` host protocol server）
