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
- 本 fork 使用的 **ios-mcp 适配版**（含上述 iOS 越狱加固补丁）：https://github.com/ddddddedcds/ios-mcp

**关于本 fork 的改编代码**
本 fork 中**在原作基础上增加和修改的代码**（即 iOS 越狱适配相关的改动，而非整个 Operit2 项目）**全部由 AI 完成，没有一行是人类手写的**。

**免责声明（Disclaimer）**
本工具为 **实验性、不稳定** 产品，使用风险自负。作者不对因安装或使用本包导致的任何数据丢失、财产损失、系统损坏或其他损害负责。迄今为止尚未报告过此类事件，但安装和使用即表示你承担全部风险。

---

## iOS 设备自动化使用教程

### 它能做什么
在越狱 iOS 设备上，Operit2 可以「看着屏幕」自动操控手机，完成你用自然语言描述的任务（例如「打开设置 App 并截一张图」「在微博搜索某话题并点赞」）。核心是一个**视觉代理循环**：

```
截图 → 云端 VLM（AutoGLM-Phone 风格）看屏决策 → ios-mcp 在设备上执行动作
→ 重新截图观察 → ……循环，直到任务完成或被人工接管。
```

### 架构（一图看懂）
```
Operit2 App（聊天 / 界面）
      │  Unix socket: agent.sock
      ▼
operit_agent_daemon（Rust，常驻 LaunchDaemon，监听 127.0.0.1:8890）
      │  ① 用 App 推送来的 LLM 凭证调用云端 VLM 决策
      │  ② 通过 ios-mcp（localhost:8090）下达系统级动作
      ▼
ios-mcp tweak（设备上的「手」）：screenshot / tap / swipe / type / launch / home / back
```

- App 与 daemon 之间走 `agent.sock`（rootless 物理路径
  `/var/jb/var/mobile/.operit/agent.sock`，roothide 为 `/var/mobile/.operit/agent.sock`）。
- daemon 跑在后台（独立 LaunchDaemon），所以即使 App 被挂起或锁屏，自动化仍能继续。
- LLM 凭证：在 App「设置 → 模型」里配置（详见下方「安装前提 → 配置 LLM 凭证」），App 通过 TCP `127.0.0.1:8890` 推给 daemon
  并缓存（roothide 双视图下文件不可见，TCP 是唯一跨视图通道）。

### 安装前提

#### 1. 越狱环境与依赖包
- **iOS 15+ 已越狱设备**，二选一：rootless（如 Dopamine）或 roothide。
- **ios-mcp 适配版 deb（必装，本体 deb 已声明 `Depends: com.witchan.ios-mcp`）**：
  - rootless 装 `com.witchan.ios-mcp_1.2.3-patched_iphoneos-arm64.deb`；
  - roothide 装 `com.witchan.ios-mcp-roothide_1.2.3-patched_iphoneos-arm64e.deb`。
  - 即本仓库 `hosts/ios/deb/third_party/ios-mcp/` 下随附的那两个包，或你的 apt 源里同名包。
- **Operit2 本体 deb**（含 daemon + SpringBoard tweak，与上面 ios-mcp 一起由包管理器解析依赖安装）。
- （可选）**AppSync Unified** —— 仅当你侧载 / 重签 App 缺 entitlements 或 ldid 时用它兜底签名（见 `postinst` 注释），正常 Dopamine/roothide 环境不需要手动装。

> 一句话依赖链：越狱(rootless 或 roothide) → ios-mcp 适配版 deb → Operit2 本体 deb → Operit2 App。

#### 2. 在 App 里配置 LLM 凭证（自动化「大脑」的 Key）
自动化的「看屏决策」由**云端 VLM** 完成，它需要一个 API Key。配置位置与规则如下：

- **在哪配**：Operit2 App → **设置 → 模型**。在这里「新建 / 编辑一个服务商（Provider）档案」并保存，App 会把该档案的
  `apiKey / provider 类型 / endpoint / 首个模型 id` **自动推送**给后台 daemon（TCP `127.0.0.1:8890`）。
  **注意：daemon 用的是「你最近一次保存的那个服务商档案」的凭证**，不是某个独立开关。

- **配谁的 / 用哪个模型 / 写谁的 Key**（daemon 侧实测逻辑，见 `operit_agent_daemon.rs`）：
  - **provider 类型 = `custom`（自定义）**：用你填的 `endpoint` + `模型 id` + **你自己的 Key**，
    可接任意 OpenAI 兼容服务（如自建或第三方大模型网关）。
  - **provider 类型 ≠ custom（默认 / 智谱等）**：daemon **强制走智谱 BigModel（Zhipu）AutoGLM 端点**
    `https://open.bigmodel.cn/api/paas/v4/chat/completions`，endpoint 字段此时被忽略。
    - **模型**：默认 `autoglm-phone`（智谱的手机端视觉操作模型）；如果你在模型档案里填了具体模型 id，则用你填的。
    - **Key**：写**你自己的智谱 BigModel API Key**（在 https://open.bigmodel.cn 注册后获取）。
  - 简言之，想跑默认自动化：**在「设置 → 模型」里加一个智谱(BigModel)服务商，填上你的 BigModel Key，模型留空（或填 `autoglm-phone`）即可**；想换别的云服务就选 `custom` 并填自己的 endpoint/key/model。

- **为什么这么设计**：daemon 是独立后台进程、只读固定 `config.plist`；App 把 Key 推过去并缓存，
  roothide 下 App 与 daemon 的文件视图不同，TCP 推送是唯一跨视图通道（详见本文档「通道架构」注释）。

### 怎么用
**方式 A：在聊天里让主 AI 调用（推荐）**
- `device_automation` 是一个子代理工具包（默认未启用，需在插件 / 工具里开启）。
- 直接在对话里说你的目标，例如：
  > 帮我在设备上打开「设置」，进入「通用」，截一张图回来。
- 主 AI 会调用 `run_subagent_main`，把自然语言目标交给自动化循环。也可显式调用三个动作：
  - `run_subagent_main`（`goal` 参数）：启动自动化，给任务描述；
  - `stop`：停止正在运行的循环；
  - `status`：查询 daemon 当前状态（running / idle）。

**方式 B：直接调用 native 桥（开发者）**
```ts
await Tools.Net.deviceAgentStart({ goal: "打开设置并截一张图" });
await Tools.Net.deviceAgentStatus({});   // 查状态
await Tools.Net.deviceAgentStop({});     // 停止
```
这三个方法由 App 的 native 桥实现，内部连 `agent.sock` 驱动 daemon。

### 预期行为 / 排查
- 启动后你会看到设备被自动操作（自动点按、滑动、输入）。任务完成或想接管时调用 `stop`。
- 报「设备自动化暂未就绪 / native 桥未注册」：daemon 没起来或 sock 不通。SSH 确认：
  `launchctl list | grep ai.operit` 或 `ps aux | grep operit_agent_daemon` 应有进程。
- 动作不动：确认 ios-mcp 已安装并在 `127.0.0.1:8090` 监听。SSH：
  `curl -s 127.0.0.1:8090/mcp` 应返回 JSON-RPC 端点。
- daemon 起不来的常见原因：reload/重启后 `launchctl` 未刷新 job；重装 deb 后需 root
  重新 `launchctl load`（mobile 无权管 system domain LaunchDaemon），或设备重启。

---

## 构建脚本（.sh）用法（简要）

iOS 产物（deb / ipa）由本机脚本从 **CI 产出的未签名 Runner.app** 打包而来
（本机无法跑 `flutter build ios`，缺 Python xcframework）。前置：macOS +
Python3（`packdeb.py`）、Xcode `codesign`、可选 `ldid`；Rust `aarch64-apple-ios`
目标用于编译 daemon；rootless theos 用于编译 tweak。

### `build_deb.sh` —— 构建单个方案
一次产出「一个方案的 deb + 配套 ipa」。默认 rootless，可用 `OPERIT_PACK_SCHEME`
切到 roothide。前置：tweak 已 `make` 出 dylib、daemon 已
`cargo build --target aarch64-apple-ios --bin operit_agent_daemon`、Runner.app 已就绪。
```sh
# rootless（默认）
APP_SRC=/path/to/Runner.app bash hosts/ios/deb/build_deb.sh

# roothide
OPERIT_PACK_SCHEME=roothide APP_SRC=/path/to/Runner.app bash hosts/ios/deb/build_deb.sh
```
产物：`operit2-ios_<ver>_iphoneos-arm64.deb` + `.ipa`（rootless），或
`..._iphoneos-arm64e.deb` + `.ipa`（roothide），版本号取自 `DEBIAN/control`。

### `build_all_0.3.66.sh` —— 一次出全部三种产物
从同一个 Runner.app 一次性构建 rootless deb+ipa、roothide deb+ipa、以及
nonjb（非越狱）重签 ipa，最后做存在性校验。
```sh
APP_SRC=/path/to/Runner.app bash hosts/ios/deb/build_all_0.3.66.sh
# 等价： bash hosts/ios/deb/build_all_0.3.66.sh /path/to/Runner.app
```
产物：`operit2-ios_0.3.66_iphoneos-arm64.deb/.ipa`、
`operit2-ios_0.3.66_iphoneos-arm64e.deb/.ipa`、`operit2-ios_0.3.66_nonjb.ipa`。

> 注：daemon 二进制用的是已验证的 0.3.65 release 构建（脚本不重编，规避风险）；
> 脚本仅做打包 / 重签。若改了 Rust 源码，需先
> `cargo build --target aarch64-apple-ios --release --bin operit_agent_daemon`
> 再跑打包脚本。
