# 🪸 Atoll

**为你的 AI 编程 Agent 打造的 macOS 灵动岛。** 在屏幕顶部的浮动面板里，实时监控 Claude Code、Codex、Gemini 等多个 agent 的会话，直接批准权限请求、回答问题、审阅计划——不用切回终端。

纯本地运行：无云端、无账号、无遥测。

*[English](README.en.md)*

<p align="center">
  <img src="assets/panel.svg" width="620" alt="Atoll 灵动岛面板">
  <br>
  <img src="assets/settings.svg" width="620" alt="Atoll 设置 · 集成">
  <br>
  <sub>示意图，使用占位数据。</sub>
</p>

---

## 功能

- **多 Agent 监控**：多个 agent 的会话统一显示——状态（思考/执行工具/压缩/等待审批/完成…）、工具调用流水（含结果摘要 `└ 3 passed`）、任务清单进度、子 Agent 聚合、项目名/模型/耗时。按 agent 配色区分（Claude 橙 / Codex 蓝 / Gemini 青 / Qoder 紫 / Cursor 绿）。
- **灵动岛内批准**：权限请求卡（允许一次 / 始终允许 / 拒绝，带 diff 与文件预览）、AskUserQuestion 单选/多选/多题向导、Plan 审阅（Markdown + 反馈）。**App 崩溃或退出时自动降级回终端原生流程**，绝不卡死 agent。
- **终端精确跳转**：点击会话卡跳回它所在的 iTerm2 / Terminal 标签。
- **零配置 + Hook 守护**：一键安装/卸载各 CLI 的 hooks（非破坏性 merge，与其他工具共存）；hooks 被外部移除时自动恢复。
- **用量额度**：面板顶部显示 Claude 5 小时 / 7 天 rate-limit 用量与重置倒计时（statusLine 桥接，不改你原有 statusLine）。
- **会话智能标题**：复用 Claude Code 内置的 AI 会话命名。
- **通知与降噪**：审批 / 回答 / 子 Agent 完成 / 任务完成 / 错误可独立开关，支持系统横幅、事件音、自定义声音包、完成通知合并、前台 Agent 抑制、静默时段、锁屏/唤醒及屏幕镜像静默。
- **显示与交互**：可选显示器、紧凑/详细收起样式、悬停延迟、全屏隐藏、点击跳转和完成弹窗抑制。
- **SSH 远程**：远端服务器跑 agent、本地监控与审批（反向隧道）。
- **全局快捷键**：⌥⇧A 批准 / ⌥⇧D 拒绝 / ⌥⇧P 展开收起面板。

## 支持的 Agent

| Agent | 监控 | 审批 | 说明 |
|-------|:----:|:----:|------|
| Claude Code (CLI) | ✅ | ✅ | 完整支持 |
| Codex (CLI) | ✅ | ✅ | 桌面版需在应用内信任 hooks |
| Gemini CLI | ✅ | — | 原生 Hook，仅监控 |
| Qoder / Qwen Code | ✅ | ✅ | Claude 兼容 Hook，各自独立标识 |
| Factory / CodeBuddy | ✅ | ✅ | Claude 兼容 Hook，各自独立标识 |
| Kimi CLI | ✅ | — | 原生 TOML Hook 配置 |
| Cursor | ✅ | — | 原生扁平 Hook 格式 |
| OpenCode | ✅ | ✅ | 原生插件事件与审批回复 |

> **注意**：Codex Desktop / QoderWork 等**沙箱化桌面应用**按 hook 身份做信任门控，需要在应用内信任 Atoll 的 hooks（详见设置 → 集成的提示）。CLI 版无此限制。

## 环境要求

- macOS 14+
- 构建：Xcode / Swift 5.10+、Go 1.22+

## 安装

```sh
git clone <repo-url> ~/atoll && cd ~/atoll

# 构建并安装到 /Applications
scripts/build-app.sh --install

# 为各 CLI 安装 hooks（非破坏性，自动备份）
python3 scripts/install-hooks.py

# 打开 App（屏幕顶部中央出现灵动岛）
open -a Atoll
```

卸载 hooks：`python3 scripts/install-hooks.py --remove`

## 使用

- 悬停屏幕顶部中央的浮动条 → 展开面板；鼠标移开自动收起。
- Agent 需要审批时，面板自动弹出审批卡，点按钮或用快捷键决策。
- Atoll 或 Agent 任一侧完成审批后，另一侧的同一请求同步结束；优先按 `tool_use_id` 精确关联。
- 设置 → 集成可为每个支持审批的 Agent 选择“跟随焦点 / Atoll / 原生”。默认跟随焦点：Agent 桌面应用或其终端在前台时交给原生审批，否则由 Atoll 承接，避免两个审批界面依次弹出。
- 会话卡右键可“从 Atoll 移除”，顶栏垃圾桶可批量清理已完成会话；只清理本地展示，不终止或删除 Agent 原始任务。待处理请求不可移除。
- 面板顶栏 **⚙ 齿轮**打开设置（通用 / 集成 / 显示 / 行为 / 通知 / 过滤）。
- agent 工作时，面板里的珊瑚 🪸 图标会轻微跳动。

## 架构

```
agent CLI hook → atoll-bridge（Go 二进制）→ 127.0.0.1:<随机端口> 网关（Swift App 内）→ 灵动岛面板
                                                    ↑ Token 鉴权，仅本机
```

- `bridge/` — Go hook shim：读 stdin payload，转发给本地网关；批准类事件挂起等决策；网关不可用时静默退出（不阻断 agent）。
- `app/` — Swift macOS App（SPM）：NWListener HTTP 网关 + 会话状态机 + SwiftUI 灵动岛面板；不占用 Dock 或菜单栏图标。
- `scripts/` — `install-hooks.py`（hooks 安装/卸载）、`build-app.sh`（打包 .app）、`atoll-ssh.sh`（SSH 远程）。

## 安全

纯本地、仅绑 `127.0.0.1`、随机 Token 鉴权、无出网、无遥测。详见 [SECURITY.md](SECURITY.md)。

## 开发

```sh
(cd app && swift build && .build/debug/Atoll)   # 运行调试版
(cd app && swift test)                          # Swift 单元/回归测试
(cd bridge && go test ./...)                    # Go bridge 单元测试
scripts/self-test.sh                            # 本机端到端自测
```

## 已知限制

- **桌面应用信任门控**：Codex Desktop / QoderWork 等沙箱应用需在应用内信任 hooks，Atoll 无法程序化自我授权（见上文）。
- **ExitPlanMode**：计划的最终批准需在终端确认（当前 Claude Code 版本对 hook 的 allow 不采纳）。
- 精确终端跳转目前覆盖 iTerm2 / Terminal.app。

## License

[MIT](LICENSE) © 2026 mk
