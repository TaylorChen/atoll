# Atoll 开发约定

## 产品边界

Atoll 是 macOS 顶部浮动面板，用于统一监控 AI 编程 Agent，并在 Agent 支持时处理审批。当前支持：Claude Code、Codex、Cursor、Gemini CLI、Qoder、Qwen Code、Factory、CodeBuddy、Kimi CLI、OpenCode。

## 集成架构

所有来源先转换为 `NormalizedEvent`，但不得假设所有 Agent 的 Hook 协议相同：

- Claude Code、Qoder、Qwen Code、Factory、CodeBuddy：Claude 兼容 JSON Hook。
- Codex：输入事件可复用 Claude 兼容解析；审批输出必须使用 Codex 官方 `PermissionRequest` 决策结构，不得输出 `updatedPermissions`。
- Cursor、Gemini CLI：各自原生 Hook 事件。
- Kimi CLI：Claude 兼容事件，安装配置为 `~/.kimi/config.toml`。
- OpenCode：使用 `scripts/atoll-opencode.js` 原生插件桥接事件和审批回复。

审批状态以 Agent 请求为唯一事实来源。Atoll 决策后响应原始挂起连接；Agent 侧先完成时，由匹配的工具事件、轮次结束或连接关闭清理卡片。存在 `tool_use_id` 时必须优先精确匹配，不能只按工具名清理并发请求。

## 修改规则

- 先阅读目标文件、附近实现与测试，再做最小修改。
- 不新增依赖，除非现有实现和标准库无法满足需求并已说明原因。
- Hook 安装必须非破坏性、可重复执行、可卸载，并保留其他工具的配置。
- HookWatcher 只能按 `enabled-integrations.json` 恢复已启用项，不得自动启用新集成。
- Hook stdout 是协议通道，诊断信息不得写入 stdout。
- 新增 Agent 时应同时更新：安装器、Normalizer、设置页、颜色标识、README 支持矩阵和测试。
- 不复制 GPL 项目代码；可以学习公开协议、行为和架构后独立实现。

## 验证命令

```bash
cd app && swift test
cd bridge && go test ./...
python3 -m unittest scripts/test_install_hooks.py
node --check scripts/atoll-opencode.js
scripts/self-test.sh
```

发布前还需执行 `scripts/build-app.sh --install`，重启 Atoll，并完成一次真实 Agent 人工审批验收。
