# Atoll 安全说明

Atoll 是**纯本地**工具:监控本机 AI 编程 agent 的会话、在灵动岛里批准权限。无云端、无账号、无遥测。

## 数据流与信任边界

```
agent CLI hook → atoll-bridge（本机）→ 127.0.0.1:<随机端口> 网关（App 内）
```

- **网关只绑 `127.0.0.1`** 随机端口,不监听外网。
- **鉴权**:每次启动生成随机 128-bit Token,写入 `~/.atoll/run/endpoint`(权限 `0600`);所有请求需带 `X-Atoll-Token`,**常量时间比较**。
- **hook payload 不落盘**(会话历史仅内存)。
- **无出网**:App 不向任何外部服务发数据。SSH 远程是用户显式发起的反向隧道,只连用户自己的服务器。

## 已审计并加固的点

| 面 | 处理 |
|----|------|
| 网关鉴权 | 随机 Token + 0600 + 常量时间比较;仅 127.0.0.1 |
| 网关启动 | endpoint 目录/文件/权限任一写入失败均显式报错并终止 App，不留下“看似运行”的失效实例 |
| 审批状态同步 | Agent/终端端先完成后，通过后续工具事件、轮次结束或 TCP 关闭移除过期卡片 |
| 决策协议隔离 | Codex 使用其官方 `PermissionRequest` 响应结构；Claude 兼容工具使用独立编码器，避免字段串用 |
| Codex Desktop 通道 | app-server stderr 记录到本地系统日志；子进程异常退出后退避重启并在面板显示警告 |
| 终端跳转(AppleScript) | tty 插入脚本前校验格式(`/dev/…`,仅字母数字/),防脚本注入 |
| 声音包导入(zip/文件夹) | 包名 sanitize(禁 `/ \ ..` 与前导点)+ 目标必须直属 packs 目录 + unzip 隔离临时目录,防路径遍历/zip-slip |
| statusLine 桥接 | `eval` 的是用户**自己原有**的 statusLine 命令(安装时备份、卸载还原),非外部输入 |
| 调试日志 | `debug-unparsed.log` **默认关闭**(`defaults write Atoll debugUnparsed -bool true` 才开),截断 500 字、0600、仅本地;可能含 prompt 文本,故用户显式开启 |
| 配置写入 | 对各 CLI 配置**非破坏性 merge**(只加/删 atoll 指纹条目,不动他人);改前自动备份 |
| bridge 外部命令 | 仅 `ps -p <int>`(无 shell、参数数组、整数),无命令注入面 |

## 用户须知的固有风险

- **hook 会执行 bridge 二进制**:Atoll 的 hook 让各 agent 在事件时运行 `~/.atoll/bin/atoll-bridge`。这是设计使然(和同类工具一致)。卸载请用 `install-hooks.py --remove` 干净移除,或 App 内「移除所有自动配置」。
- **SSH 远程**:`atoll-ssh.sh` 会把 bridge 二进制 scp 到你指定的服务器并配置其 hooks。只对你自己拥有、信任的主机使用。
- **审批降级**:App 崩溃/退出时,挂起的权限请求会**回落到终端原生流程**(bridge 超时后 agent 自行处理),不会因 Atoll 缺席卡死或误放行。

## 报告漏洞

请通过 issue 或私信联系维护者。
