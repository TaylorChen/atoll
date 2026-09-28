# 参与贡献 / Contributing

感谢你愿意改进 Atoll！项目约定以 [AGENTS.md](AGENTS.md) 为准，这里是动手前的最短路径。
*English speakers: issues and PRs in English are equally welcome.*

## 本地开发

需要 macOS 14+、Xcode 16+（Swift 6）、Go 1.26+、Python 3、Node（仅用于语法检查）。

```sh
(cd app && swift build && .build/debug/Atoll)   # 运行调试版（先退出已安装的 Atoll，单实例锁）
scripts/build-app.sh --install                   # Release 构建并安装到 /Applications
```

## 提交前请跑

```sh
(cd app && swift test)
(cd bridge && go test ./...)
python3 -m unittest scripts/test_install_hooks.py
node --check scripts/atoll-opencode.js
node --experimental-strip-types --check scripts/atoll-pi.ts   # Node 22.6+
scripts/self-test.sh        # 需要 Atoll 正在运行：端到端事件与审批闭环
```

CI 会跑前四项。改动界面时请用 `scripts/render-screenshots.sh` 重新生成 README 截图并一并提交。

## 约定

- **Hook stdout 是协议通道**：诊断信息一律不写 stdout。
- **Hook 安装必须非破坏性、幂等、可卸载**，保留其他工具的配置。
- **不同 Agent 的协议不能混用**：例如 Codex 审批必须使用其官方 `PermissionRequest` 决策结构。
- **新增 Agent** 需同时更新：安装器、Normalizer、`AgentCatalog`、README 支持矩阵和测试；没有官方协议和本机真实事件证据的工具不写入支持矩阵。
- **不新增依赖**，除非标准库和现有实现确实无法满足，并在 PR 中说明原因。
- **不复制 GPL 项目代码**；可以学习公开协议与行为后独立实现。

## 报告问题

提 Issue 时请附上 macOS 版本、Atoll 版本（设置 → 通用 → 关于）、涉及的 Agent 与版本，以及复现步骤。
设置 → 集成 → 诊断可导出本地报告（不含 prompt、命令、文件内容、Token），导出前可预览。安全相关问题见 [SECURITY.md](SECURITY.md)。
