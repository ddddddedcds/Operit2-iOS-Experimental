# Operit Cli

Operit Cli 是面向终端的 AI 工作台。命令名为 `operit2`，提供交互式 TUI、命令式管理、聊天会话、模型配置、记忆、工作区、工具、市场、插件、MCP、远程连接和 Web 访问。

## 构建与运行

```powershell
cargo build --manifest-path apps/cli/Cargo.toml --bin operit2
cargo run --manifest-path apps/cli/Cargo.toml --bin operit2 -- --help
```

启动交互式 TUI：

```powershell
operit2
operit2 tui
```

进入命令式模式：

```powershell
operit2 cli version
operit2 cli host show
operit2 cli prefs show
```

## 聊天

```powershell
operit2 cli chat new
operit2 cli chat list
operit2 cli chat show <chat-id>
operit2 cli chat switch <chat-id>
operit2 cli chat send --chat <chat-id> "hello"
operit2 cli chat shell
```

TUI 支持指定会话、继续当前会话、绑定角色或群组：

```powershell
operit2 --chat <chat-id>
operit2 --resume
operit2 --character <character-card-name>
operit2 --group-card <character-group-id>
operit2 --group <group-name>
```

交互式 shell 内置命令：

```text
/help
/exit
/chat
/new
/switch <chat-id>
/resume
/show
/attach <path>
/attachments
/clear-attachments
/send <message>
```

## 模型与偏好

```powershell
operit2 cli model provider-type-list
operit2 cli model provider-list
operit2 cli model provider-create <name> <provider-type-id> <endpoint>
operit2 cli model provider-set-key <provider-id> <api-key>
operit2 cli model provider-model-add <provider-id> <provider-model-id>
operit2 cli model list
operit2 cli model use <provider-id> <model-id>
operit2 cli model params <provider-id> <model-id>
operit2 cli prefs thinking <on|off>
operit2 cli prefs stream <on|off>
operit2 cli prefs mcp-timeout <seconds>
```

## 工作区

```powershell
operit2 cli workspace default-path <chat-id>
operit2 cli workspace create-default <chat-id> [project-type]
operit2 cli workspace bind <chat-id> <workspace>
operit2 cli workspace list
operit2 cli workspace commands <chat-id>
operit2 cli workspace run <chat-id> <command-id>
```

## 记忆、角色与提示

```powershell
operit2 cli memory character <character-id> user show
operit2 cli memory character <character-id> item list
operit2 cli memory shared list
operit2 cli character list
operit2 cli character create <name> [character-setting]
operit2 cli group list
operit2 cli group create <name> [description]
operit2 cli active-prompt show
operit2 cli active-prompt set-card <id>
operit2 cli active-prompt set-group <id>
```

## 工具、包、插件与 MCP

```powershell
operit2 cli tool list all
operit2 cli tool show <tool-name>
operit2 cli tool exec <tool-name> <params-json>
operit2 cli package list
operit2 cli package import <js-ts-hjson-toolpkg-path>
operit2 cli package exec <package:tool> <params-json>
operit2 cli plugin list
operit2 cli plugin import <toolpkg-path>
operit2 cli mcp list
operit2 cli mcp import <json-or-@file>
operit2 cli mcp tools <id>
operit2 cli mcp local-set <id> [--disabled true|false] [--env KEY=VALUE] [--approve TOOL] -- <command> [args...]
```

## 市场与更新

发布版本、GitHub tag、更新通道和包文件名规范见 [docs/release-versioning.md](docs/release-versioning.md)。

```powershell
.\.venv\Scripts\python.exe tools\release\release_interactive.py
.\.venv\Scripts\python.exe tools\release\release.py
.\.venv\Scripts\python.exe tools\release\release.py --scope cli
.\.venv\Scripts\python.exe tools\release\release.py --scope app
```

```powershell
operit2 cli market stats <skill|mcp|package|script>
operit2 cli market rank <skill|mcp|package|script> [updated|downloads|likes] [page]
operit2 cli market search <skill|mcp|package|script> <query> [page]
operit2 cli market show <skill|mcp|package|script> <id-or-number>
operit2 cli market install <skill|mcp|package|script> <id-or-url> [node-id]
operit2 cli update check
operit2 cli update target
operit2 cli update
```

## 导入、导出与备份

```powershell
operit2 cli export memory <path> <owner-key>
operit2 cli export chat <path>
operit2 cli export snapshot <path>
operit2 cli import memory <path> <SKIP|UPDATE|CREATE_NEW> <owner-key>
operit2 cli import chat <path>
operit2 cli import snapshot <path>
operit2 cli backup create <snapshot-zip-path>
operit2 cli backup restore <snapshot-zip-path>
operit2 cli backup inspect <snapshot-zip-path>
```

## 远程连接与 Web 访问

```powershell
operit2 cli link serve [--bind <addr:port>] [--token <token>]
operit2 cli link discover [--timeout-ms <ms>]
operit2 cli link connect <url> --token <token> [--save <name>]
operit2 cli link sessions
operit2 cli link tui <session> [--chat <chat-id>]
operit2 cli link run <session> <version|chat>
operit2 cli --link <session> version
operit2 cli web open [--bind <addr:port>] [--token <token>] [--link <session>] [--web-root <path>] [--discoverable]
operit2 cli web status
operit2 cli web close
```

## 常用检查

```powershell
cargo check --manifest-path apps/cli/Cargo.toml
cargo run --manifest-path apps/cli/Cargo.toml --bin operit2 -- cli version
```

---

## iOS 越狱版说明（ddddddedcds fork）

> 本仓库根 README 为上游 Operit Cli 文档。以下为本 fork 的 iOS 越狱构建相关说明。

**项目与设备自动化（operit2 / ios-mcp）**
- 本项目（fork）：https://github.com/ddddddedcds/Operit2
- 分支：https://github.com/ddddddedcds/Operit2/tree/feat/ios-jailbreak-preview4
- 改编自原作 **Operit2**（by AAswordman）：https://github.com/AAswordman/Operit2
- 设备自动化（截图 / OCR / 触控输入）由设备上运行的 **ios-mcp** 后端提供（by witchan，localhost:8090）：https://github.com/witchan/ios-mcp

**关于本 fork 的改编代码**
本 fork 中**在原作基础上增加和修改的代码**（即 iOS 越狱适配相关的改动，而非整个 Operit2 项目）**全部由 AI 完成，没有一行是人类手写的**。

**免责声明（Disclaimer）**
本工具为 **实验性、不稳定** 产品，使用风险自负。作者不对因安装或使用本包导致的任何数据丢失、财产损失、系统损坏或其他损害负责。迄今为止尚未报告过此类事件，但安装和使用即表示你承担全部风险。
