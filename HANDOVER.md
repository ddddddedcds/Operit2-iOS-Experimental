# Operit2 越狱 iOS 移植 —— 交接手册（HANDOVER）

> **项目状态**：**活跃开发中（2026-08-28 恢复）**。实验性分支，bug 链式暴露，风险自负。
>
> **历史定位（已过期，保留说明）**：本分支最初是 **POC（概念验证）**，用于验证"越狱 iOS + AI 深度集成"这条路是否可行——结论**可行**。2026-08-26 曾一度决定长期停开发、只作知识封存；**该决定已于 2026-08-28 推翻**，项目恢复 active 开发，新功能（含热更新 / 实时补丁）不再以"停开发"为阻塞。
>
> **仍在的架构局限**（客观事实，与是否活跃开发无关）：Operit2 的 Flutter+Rust 架构硬移植进越狱 iOS 代价高——**bug 链式暴露**（§8.7 等）+ 冷启动 60s（**已解决**，见 §14）。架构重做（软移植减库，§14.5）仍是长期选项，但**不是当前阻塞项**。
>
> **本手册的作用**：记录全部架构、运行原理、坑与遗留问题，既供维护者续做，也供 operit 官方 / 越狱社区开发者接手。
>
> **仓库**：`github.com/ddddddedcds/Operit2-iOS-Experimental`（原 `Operit2-iOS-Jailbreak-POC`，2026-08-26 改名）。分支 **`feat/ios-jailbreak-preview4`**。当前版本 **0.3.87**。
> **目标平台**：Dopamine rootless（iOS 16.7，主测试机 iPhone13,4（A14））。**roothide 已停止支持、不再维护**（见附录 A，仅作历史参考）。
>
> **两条交付线**：
> 1. **越狱完整版**（rootless deb）：tweak + daemon + iOS-mcp + 全部 AI 能力。
> 2. **非越狱最小版**（nonjb ipa）：仅 AI 聊天 + 内置 iSH 终端（标准沙盒，Sideloadly 自签）。
> **可选集成**：dsh（DeepSeek Harness）通过「运行时 deb（独立）+ toolpkg（桥）」接进 Operit2（见 §3.5 / §5.3）。

---

## 1. 仓库结构与关键路径

```
operit2-src/                          # ★ 仓库根（注意：不是 operit2-fork-src）
├── hosts/ios/                        # ★ iOS 越狱侧全部代码
│   ├── tweak/                        #   SpringBoard tweak（Logos）
│   │   ├── operit-sb.x               #     核心：通知拦截/记录、锁屏会话、应用锁、剪贴板、Siri 集成（~2100 行）
│   │   ├── operit-app.x              #     app 进程注入（次要）
│   │   ├── operit-sb.plist / operit-app.plist   # TweakInject 注入配置
│   │   ├── Makefile                  #     Theos 构建（arm64+arm64e）
│   │   └── entitlements.plist
│   ├── ccmodule/                     #   控制中心 AI 按钮（CCSupport 模块）
│   │   ├── operit_cc.m               #     OperitCCModule : CCUIAppLauncherModule
│   │   ├── Info.plist                #     NSPrincipalClass=OperitCCModule
│   │   └── Makefile                  #     ⚠️ 必须 ldid -S 手动签名（Makefile CODESIGN 无效）
│   ├── src/                          #   Rust：daemon + 运行时托管
│   │   ├── bin/operit_agent_daemon.rs#     设备自动化 daemon（VLM 循环，TCP 8890）
│   │   └── managed_runtime.rs        #     运行时托管（数据目录初始化等）
│   ├── deb/                          #   打包目录
│   │   ├── build_deb.sh              #   ★ 一键打包 rootless deb（staging+签名+ar）
│   │   ├── build_nonjb_ipa.sh        #   ★ 非越狱 ipa 打包（Runner-nonjb.entitlements）
│   │   ├── package_0.3.37.sh         #   历史脚本，已废弃
│   │   ├── DEBIAN/control            #   版本/依赖（当前 Version 0.3.87，build_deb.sh 从此处取版本号生成文件名）
│   │   ├── DEBIAN/postinst           #   装机：ldid 重签 daemon + 启动 LaunchDaemon
│   │   ├── Runner.entitlements       #   rootless 签名（app-sandbox=false + iokit-user-client-class）
│   │   ├── Runner-nonjb.entitlements #   非越狱 IPA 用（标准沙盒，无 no-sandbox）
│   │   └── files/                    #   deb 内容 staging
│   ├── Cargo.toml / Cargo.lock       #   Rust 交叉编译配置
│   └── target/                       #   cargo 交叉编译产物（daemon 二进制源）
│
├── apps/flutter/app/                 # Flutter 业务代码 + iOS 原生桥
│   ├── lib/ui/features/...           #   settings/appearance、chat/components/workspace/terminal 等
│   └── ios/Runner/                   #   ★ Swift 本地服务（8891 dispatcher 及各 Server）
│
├── plugins/packages/buildin/         # ★ AI 工具定义（TS，插件运行时加载）
│   ├── device_automation.ts          #   设备自动化（tap/swipe/type/screenshot，连 daemon）
│   ├── system_io.ts                  #   权限全家桶 9 工具（contacts/calendar/reminders/photos/health/location）
│   ├── screen_time.ts                #   屏幕使用时间（authorize/lock/unlock/monitor/usage）
│   ├── shortcuts.ts / notify.ts / open_url.ts / super_admin.ts
│   └── browser.ts / operit_editor.ts / extended_chat.ts / extended_memory_tools.ts
│
├── core/crates/operit-tools/src/tools/   # Rust 工具注册层（ToolRegistration.rs 等）
│
├── toolpkg-work/                     # ★ dsh 集成遗留产物（已迁移独立仓库，见 §3.5）
│   ├── com.operit.deepseek-harness-runtime_1.0.0_iphoneos-arm64.deb  # 旧 companion 运行时（历史）
│   └── com.operit.deepseek_harness.ios/                #   toolpkg 源码（v1，历史版本）
│
├── tools/                            #   辅助（含 iSH rootfs 烘焙脚本 tools/ios-runtime/ish/）
└── HANDOVER.md                       #   本文件
```

### deb/files/ 内容布局（rootless）
```
files/
├── Applications/Runner.app/            # Flutter app（CI 产物，本地重签）
├── Library/
│   ├── MobileSubstrate/DynamicLibraries/  operit-sb.dylib + operit-app.dylib（TweakInject）
│   ├── PreferenceLoader/Preferences/operitPrefs.bundle/  （设置面板）
│   ├── CCSupport/OperitCC.bundle/      # 控制中心模块
│   └── LaunchDaemons/ai.operit.agent.plist  # daemon 守护
└── usr/bin/operit_agent_daemon         # daemon 二进制（预签）
```

---

## 2. 系统架构（进程 / 端口 / 数据流）

```
┌─────────────────────── 设备（iOS 16.7 Dopamine rootless）───────────────────────┐
│                                                                                  │
│  [ios-mcp 进程] ←← 127.0.0.1:8090 JSON-RPC ←← 主机/MCP 客户端                     │
│   ▲ 设备"手"：tap/swipe/type/screenshot/open_url/launch_app/list_apps             │
│   │  独立进程，不受 app 挂起影响——设备操作首选通道                                  │
│                                                                                  │
│  [SpringBoard 进程]  ← operit-sb.dylib（tweak 注入）                              │
│   ├─ 通知拦截/记录（BBObserver hook）→ notifications.json                        │
│   ├─ 锁屏会话（Darwin notify）→ usage.json                                       │
│   ├─ 应用锁（前台检测 → app_lock.plist 名单）                                     │
│   ├─ Siri 集成（AFConnection hook → 卡片显示 + 会话同步）                          │
│   └─ unix socket operit.sock（兜底命令通道）                                      │
│                                                                                  │
│  [operit_agent_daemon]  ← LaunchDaemon ai.operit.agent 拉起                       │
│   ▲ TCP 127.0.0.1:8890（AI 脑袋：VLM 循环）                                       │
│                                                                                  │
│  [Runner.app]  ← Flutter + Rust 内核 + Swift 本地服务                              │
│   └─ TCP 8891 OperitLocalServer（单端口 dispatcher，按首 token 路由）              │
│        ├─ screen_time        → ScreenTimeServer                                   │
│        ├─ shortcuts         → ShortcutsServer                                     │
│        ├─ notify/live_*/notif_* → NotifyServer                                    │
│        ├─ open_url/installed_apps → OpenURLServer                                 │
│        └─ tcc → OpenURLServer 内部直调 TCCServer（权限全家桶）                      │
│                                                                                  │
│  [dsh 运行时]  ← 独立 CLI deb：nodejs + dsh-ios（可选）                       │
│   ▲ node 22.23.2（V8 W^X 全 JIT）+ dsh 0.1.1-rc.2，Web GUI 127.0.0.1:3080；**独立可跑，不依赖 Operit2**│
│   ▲ Operit2 经 toolpkg（桥，独立仓库 1.1.2）把 dsh 面板放进侧边栏            │
└──────────────────────────────────────────────────────────────────────────────────┘
```

**AI 工具调用链路**：
`TS 工具（buildin/*.ts）→ Rust ToolRegistration → Tools.Net.* 桥`
- 设备动作 → daemon(8890) → ios-mcp(8090) → 设备
- 深链/权限/屏幕时间/快捷指令/通知 → OperitLocalServer(8891) 按首 token 路由

**关键设计原则**：
- **ios-mcp 是"手"**（逐动作），**daemon 是"脑"**（VLM 决策循环），二者分离
- **所有跨进程通信用 TCP loopback（127.0.0.1）**（roothide 双视图下 unix socket 会"永不相遇"——虽已停更，仍保留此约束说明）
- **Siri 集成在 SpringBoard 进程**（tweak 内），app 进程的 Swift 服务不参与

---

## 3. 组件运行原理

### 3.1 tweak（operit-sb.x，SpringBoard 进程）
- **注入**：TweakInject 按 operit-sb.plist 的 Bundles=com.apple.springboard 注入
- **通知拦截 + 记录**：hook `BBObserver._queue_updateBulletin:withReply:`（拦截：命中 app_lock/notif_block 名单 → return 丢弃）+ `updateBulletin:withReply:`（记录 → notifications.json，去重，50 条）
- **锁屏会话**：`notify_register_dispatch("com.apple.springboard.lockstate")` → `notify_get_state` → usage.json
- **应用锁**：前台检测 + `app_lock.plist` 名单 → 命中弹自定义屏蔽页
- **剪贴板监听**：`clipboard_enabled` 文件开关（默认关）
- **Siri 集成**：hook `AFConnection._tellSpeechDelegateSpeechRecognized:`（识别文本）→ 写 operit2 会话 → DeepSeek → 写回 → `AFUISiriViewController.viewDidAppear` 存实例 → addSubview 自绘卡片
- **socket 命令**（unix socket operit.sock，行协议）：`ping`/`front`/`home`/`tap`/`swipe`/`type`/`longpress`/`launch <bid>`（⚠️ 崩 SpringBoard，禁用）/`screenshot`/`applock`/`appunlock`/`applock_list`/`notif_clear`/`ai`/`user`/`sender`/`assistant`
- **配置**：`operit_cfg_bool(key, default)` 读 NSUserDefaults 域 com.operit

### 3.2 daemon（operit_agent_daemon.rs，root 由 LaunchDaemon 拉起）
- 端口 TCP 127.0.0.1:8890，行协议
- 命令：`stop` / `goal <文本>`（启动 VLM 循环）/ `config <key>|<provider>|<base>|<model>`
- LaunchDaemon `ai.operit.agent`（RunAtLoad + KeepAlive，mobile 用户）
- **签名要求**：daemon 二进制必须 ldid 签名且 cdhash 注册进 Dopamine trustcache（否则 SIGKILL -9）——postinst 负责装机时重签

### 3.3 Swift 本地服务（Runner.app，AppDelegate 启动）
> 单端口 **8891 dispatcher**（OperitLocalServer，按首 token 路由）：
| 服务 | 首 token | 能力 |
|---|---|---|
| ScreenTimeServer | `screen_time` | `lock <bid>[|...]`（任意 app 可锁，无需 picker）/ `unlock` / `status` / monitor / usage |
| ShortcutsServer | `shortcuts` | `run <名称>`（shortcuts:// URL scheme）|
| NotifyServer | `notify`/`live_*`/`notif_*` | AI 主动发通知/灵动岛 |
| OpenURLServer | `open_url`/`installed_apps`/`tcc` | 深链 / 枚举 app / `tcc <cmd>` 内部直调 TCCServer |
| TCCServer | （经 OpenURLServer 直调）| contacts/calendar/reminders/photos/health/location |
- 全部走系统公开 API（EventKit/Contacts/Photos/HealthKit/CoreLocation），TCC 授权弹窗，失败降级不崩（`responds` 前置探测，**禁用裸 value(forKey:)** —— iOS 16 不存在的 key 抛 NSException）

### 3.4 TS 工具（plugins/packages/buildin/*.ts）
- **device_automation.ts**：设备自动化主工具（连 daemon → ios-mcp）
- **system_io.ts**：9 工具 → 走 `tcc ` 前缀 → OperitLocalServer 8891 → TCCServer
- **screen_time.ts**：已删 `screen_time_pick`（AI 直接锁任意 app）
- **super_admin.ts**：终端/文件/进程（✅ 已修复 sessionId 入口，见 §8.3）
- **open_url.ts**：深链（⚠️ 大部分未实测，weixin://dl/* 全无效）
- **notify.ts / shortcuts.ts / browser.ts / operit_editor.ts / extended_chat.ts / extended_memory_tools.ts**

### 3.5 dsh 集成（可选）—— 运行时 + 桥
dsh 不是 Operit2 内置功能，而是通过两个独立产物接进来的：
- **运行时**（nodejs deb + dsh-ios deb，独立仓库 [`dddddedcds/deepseek-harness-ios`](https://github.com/ddddddedcds/deepseek-harness-ios) 的 `ios-port` 分支构建）：交叉编译 Node 22.23.2（iOS arm64，**V8 W^X 全 JIT + small-icu**）+ `@deepseek-ai/dsh` 0.1.1-rc.2 整包 + node-pty 真模块，Web GUI 在 `127.0.0.1:3080`。**可独立使用，不依赖 Operit2**——越狱机装上 deb 就能直接跑 dsh。
  - 设备侧已解决的运行时垫片：`fetch-shim.cjs`（undici 的 wasm llhttp 在 A14 不可用，fetch 走 node:http + 补 User-Agent 头）；`dsh-sandbox-local`/`dsh-subprocess-local` 插件 stub（koffi FFI 无 iOS prebuilt，extends 基类后 dsh web 可启动）；launcher 需 `--predictable --single-threaded`（W^X race）+ wasm 内存上限 + `--require fetch-shim.cjs`。**dsh web 已实测 HTTP 200、LLM 直连正常。**
- **toolpkg `com.operit.deepseek_harness.ios`**（独立仓库 [`dddddedcds/deepseek-harness-ios-toolpkg`](https://github.com/ddddddedcds/deepseek-harness-ios-toolpkg)，当前 1.1.2）：把 DSH Web UI 接进 Operit2 侧边栏的「连接层/桥」。自己不提供 node/dsh，运行时由上面的 deb 提供；没有这层桥，Operit2 调不到 dsh 后端。
- 关系：`deb（独立运行时）` ← `toolpkg（Operit2 侧桥）` 连 → dsh 后端。

### 3.6 启动链路（开机 → 可用）
1. LaunchDaemon 拉起 daemon（8890 监听）
2. SpringBoard 启动，TweakInject 注入 operit-sb.dylib
3. 用户打开 Runner.app → AppDelegate 启动 OperitLocalServer（单端口 8891）
4. （可选）装了 dsh-ios deb（`/var/jb/usr/local/bin/dsh-ios`，独立 CLI）后可直接起 dsh web（127.0.0.1:3080）；装了 toolpkg 则 Operit2 侧边栏出现 dsh UI
5. 主机侧 MCP 连 ios-mcp（8090）→ AI 可用全部能力

---

## 4. 数据文件（/var/mobile/.operit/ 下，真实根）
| 文件 | 用途 | 读写方 |
|---|---|---|
| config.plist | AI 凭证（apiKey/apiBaseUrl/apiModel）| app 写，daemon 缓存优先 |
| app_lock.plist | 应用锁名单 | Swift ScreenTimeServer 写，tweak 读 |
| notif_block.plist | 通知拦截名单 | Swift NotifyServer 写，tweak 读 |
| notifications.json | 通知记录（50 条，新在前）| tweak 写，AI 读 |
| usage.json | 前台/锁屏会话统计 | tweak 写 |
| logs/tweak.log | tweak 运行日志 | tweak 写，SSH 排查 |
| operit2/runtime/data/ | app 数据（sqlite 会话库、memory/characters/\<id\>/USER.md 等）| app + Siri 集成 |

**⚠️ 目录属主必须是 mobile:mobile**（root:mobile 曾导致 app 白屏）。

---

## 5. 构建与打包（维护者必读）

### 5.1 CI（GitHub Actions）
- workflow：`.github/workflows/ios-flutter-build.yml`
- **无 on: push**，只能手动 dispatch，**分支必须手动选 `feat/ios-jailbreak-preview4`**
- 产物：UNSIGNED Runner.app（artifact `operit2-ios-<sha>`；zip 为 `tools/release/dist/operit2-app-ios-arm64.zip`，保留 14 天）
- **新增 iOS .swift 文件必须注册进 project.pbxproj 4 处**（PBXBuildFile/FileReference/group/Sources），否则 CI 报 `Cannot find XXX in scope`
- 本机**无法** `flutter build ios`（缺 Python xcframework），全量编译只能靠 CI

### 5.2 本地打包（Mac）—— 必须用 build_deb.sh
```bash
# 0. 前置①：daemon 编译（build_deb.sh 找不到 release 产物直接退出）
cd hosts/ios && cargo build --target aarch64-apple-ios --release
# 1. 前置②：tweak 编译（必须 FAT arm64+arm64e，否则 A12+ 注入崩）
cd hosts/ios/tweak && make clean && make
# 2. 前置③：CC 模块签名（build_deb.sh 不处理 ccmodule）
cd hosts/ios/ccmodule && make clean && make && ldid -S .theos/obj/debug/OperitCC.bundle/OperitCC
cp .theos/obj/debug/OperitCC.bundle/OperitCC ../deb/files/Library/CCSupport/OperitCC.bundle/
# 3. 升版本（build_deb.sh 从 control 的 Version 自动生成文件名）
sed -i '' 's/^Version: .*/Version: 0.3.87/' deb/DEBIAN/control
# 4. 打包
cd hosts/ios/deb && OPERIT_PACK_SCHEME=rootless APP_SRC="/Users/mac/Downloads/<CI新包>.app" bash build_deb.sh
```
- **⚠️ 不要单独跑 `python3 packdeb.py`**：它只做最后的 ar 打包，不做 staging（daemon 复制+预签、app 重签、extension 嵌入签名、IPA 生成全在 build_deb.sh）。只有 files/ 已被完整 staging 且仅改了 files/ 内文件时才能跳过。
- **rootless-only**：数据落真实 `/var/mobile/.operit`，mach-o 在 `/var/jb`，Architecture `iphoneos-arm64`。**绝不用 `dpkg --root=/var/jb`**，用 `sudo dpkg -i` / Sileo。
- 依赖：com.witchan.ios-mcp, preferenceloader, com.opa334.ccsupport（rootless 还建议 AppSync Unified）
- daemon 预签 + postinst 装机时 ldid 重签（关键，否则 -9）

### 5.3 非越狱最小版 + dsh 打包
- **nonjb ipa**（聊天 + iSH 终端）：
  ```bash
  cd hosts/ios/deb && APP_SRC="/Users/mac/Downloads/<新包>.app" bash build_nonjb_ipa.sh
  # 产出 operit2-ios_<ver>_nonjb_iphoneos-arm64.ipa（ad-hoc，标准沙盒；不含 daemon/tweak/appex）
  # 安装：Sideloadly/AltStore 用个人 Apple ID 重签
  ```
- **dsh 运行时 deb**（独立，构建源在 [`dddddedcds/deepseek-harness-ios`](https://github.com/ddddddedcds/deepseek-harness-ios) `ios-port` 分支）：
  - 两个 deb：`nodejs_22.23.2-3`（V8 W^X 全 JIT + small-icu）+ `dsh-ios_0.1.1-rc.2-2`（dsh 整包 + node-pty addon + koffi stub + fetch-shim），先装 nodejs 再装 dsh-ios，`dsh-ios` 启动即起 web（:3080）。
- **dsh toolpkg（桥）**（独立仓库 [`dddddedcds/deepseek-harness-ios-toolpkg`](https://github.com/ddddddedcds/deepseek-harness-ios-toolpkg)，当前 1.1.2）：
  ```bash
  git clone git@github.com:dddddedcds/deepseek-harness-ios-toolpkg.git
  cd deepseek-harness-ios-toolpkg && ./build.sh   # 从 manifest 读版本，产出 <version>.toolpkg
  # 或直接用已发布的 com.operit.deepseek_harness.ios-1.1.2.toolpkg
  ```

### 5.4 装机（SSH）
```bash
scp operit2-ios_X_iphoneos-arm64.deb mobile@<ip>:/tmp/
echo '<PASSWORD>' | sudo -S dpkg -i /tmp/operit2-ios_X_iphoneos-arm64.deb
echo '<PASSWORD>' | sudo -S killall -9 SpringBoard   # respring
```
设备 SSH：mobile@192.168.1.xx（IP 可能因 DHCP 变动，向设备所有者询问密码）。

---

## 6. 功能清单（按稳定度）

### ✅ 真机验证过（稳定）
- Siri 集成（识别 → 会话同步 → 角色记忆一致回答 → 底部卡片）
- 通知拦截 + 内容记录
- 锁屏会话、应用锁（任意 app，自定义屏蔽页）
- 深链唤起（微信裸 scheme、支付宝全系；weixin://dl/* 全废）
- 屏幕使用时间授权 + 锁应用（0.3.70 起无需选应用）
- 吃醋巡检（DeviceActivityMonitor）+ 快捷指令接入
- iSH 终端（kernel=ish + aarch64 Alpine 3.19，0.3.86 起可打开、shell 交互正常；网络已解决见 §8.6）
- **nonjb 最小版**（0.3.86）：AI 聊天 + 内置 iSH 终端，标准沙盒实机验证
- **dsh 运行时 deb**：独立安装即可跑 dsh（Web :3080），实测可用（LLM 直连正常）
- **dsh toolpkg 桥**：1.1.2 状态卡版已部署 Operit2（WebView 内嵌因 dsh 桌面 UI 在窄侧栏无响应式适配而降级为状态卡，完整 UI 走浏览器打开 3080）

### 🟡 已 push 未端到端验证
- 权限全家桶（TCCServer + system_io 9 工具 + HealthKit）
- 设置面板（PreferenceLoader operitPrefs.bundle）——**用户实测未显示**（见 §8.5）
- 控制中心模块（OperitCC）——**用户实测未显示**（见 §8.1）
- installed_apps 修复（responds 探测）

### ⏳ 暂未验证（待端到端补齐）
- Siri 气泡文本替换（跨进程不刷新）
- Siri TTS 朗读（iOS 16.7 不存在）
- 手动 method_setImplementation + 延迟原调（野指针崩 SpringBoard）——**禁止**
- weixin://dl/*（微信 iOS 不响应 path）
- TrollStore 专门支持（不能跑 LaunchDaemon）
- libSandy（回退，靠 no-sandbox 全局关沙盒）

---

## 7. 关键 hook 点地图（iOS 16.7 实测）
```
Siri 识别/回答  → AFConnection（AssistantServices 连接层，SpringBoard 进程）
                 _tellSpeechDelegateSpeechRecognized:（识别，af_bestTextInterpretation 取文本）
                 _handleCommand:reply:（SAUIAddViews = Siri 回答命令）
Siri 视图宿主   → AFUISiriViewController（viewDidAppear 存实例 → addSubview 自绘卡片）
通知记录/拦截   → BBObserver._queue_updateBulletin:withReply: / updateBulletin:withReply:
                 （BBBulletinUpdateTransaction 三层：txn.bulletinUpdate.bulletin，sectionID 从 bulletin 取）
通知 UI 层     → NCNotificationListViewController* / SBDashBoard*（分组/美化用）
锁屏检测       → Darwin 通知 com.apple.springboard.lockstate（notify_get_state）
                （SBLockScreenManager isLocked KVC iOS 16 失效）
权限数据       → 系统公开 API（EventKit/Contacts/Photos/HealthKit/CoreLocation）+ TCC 授权
```

---

## 8. 已知遗留问题

### 8.1 控制中心模块（OperitCC）不显示 🔴
- bundle 正确安装 + com.opa334.ccsupport 已装 + respring + ldid 签名，但控制中心"更多控件"没有 OperitCC。
- 疑似 CCSupport 模块验证逻辑不符；CCSupport 闭源。研究方向：对照 SiriPlus CC bundle 的 Info.plist 键 + 类实现；或 tweak 直接注入 ControlCenter 模块。

### 8.2 背景选图崩溃 ✅ 已修复
- `Invalid argument(s): XTypeGroup ... should either allow all files, or have a non-empty 'uniformTypeIdentifiers'`（file_selector_ios.dart:69）
- 真实位置：`apps/flutter/app/lib/ui/features/settings/appearance/AppearanceSettingsPanel.dart`；5 处 XTypeGroup 已补 UTI：`public.movie` / `public.image` / `public.font`。

### 8.3 super_admin 终端工具缺 sessionId 入口 ✅ 已修复
- 修法：super_admin.ts 增加基座工具 `create_terminal_session`（无参数、全平台）——调 `System.terminal.create()` 复用宿主主终端会话并返回 sessionId。
- 结构勘误：原文档写的 `core/crates/operit-tools/src/tools/defaultTool/standard/super_admin.rs` 不存在。真实：TS 插件 `plugins/packages/buildin/super_admin.ts` + Rust 侧 `StandardTerminalTools.rs`（`createOrGetSession`/`getTerminalInfo` 原本就有）。
- 注意：`plugins/packages/buildin/*.ts` 的编译产物 `core/crates/operit-runtime/assets/plugins/buildin/*.js` 是 gitignore 的构建产物，由 Flutter 构建 hook 自动同步，勿手改/勿提交。

### 8.4 手动终端 PATH 不全 ✅ 已修复
- `uname: not found`（/var/jb/usr/bin/sh: 8）。根因：Rust `hosts/ios/src/terminal.rs` 的 `probeSystemShell` 里 `environment: Vec::new()`，已改为显式注入完整 PATH（系统目录 + /var/jb 全系）。
- 结构勘误：原文档写的 `apps/flutter/app/lib/ui/features/manual_terminal/` 不存在；shell spawn 在 Rust：`hosts/ios/src/terminal.rs` → `hosts/common/operit-host-native-terminal/src/lib.rs`（`posixPtyCommand`）。

### 8.5 设置面板未显示 🟡
- operitPrefs.bundle 结构/依赖/路径均验证正确，但设置 App 无 Operit2 条目；需查 preferenceloader 加载（对照其他第三方面板是否显示）。

### 8.6 iSH 终端网络问题 ✅ 已解决（根因 resolv.conf 空，非代码 bug）
- 现象：iSH 可打开、shell 交互正常；但 `apk update` 报 `temporary error`，`51 distinct packages available`。
- 真根因：**rootfs `/etc/resolv.conf` 为空（无 nameserver）** → musl `getaddrinfo` 返回 `EAIAGAIN` → 域名解析立即失败。IP 直连下载全通、域名失败，定位为 DNS 而非传输层。
- 修复：`echo "nameserver 223.5.5.5" > /etc/resolv.conf` 即通（`apk update` 拉到 22906 个包）。已在烘焙脚本 `tools/ios-runtime/ish/build_alpine_rootfs_linux.sh` 的 `write_rootfs_config()` 固化（223.5.5.5 / 119.29.29.29 / 8.8.8.8）+ 清华镜像源。
- 排查顺序（别重蹈）：先 `cat /etc/resolv.conf` / guest 内 `getaddrinfo`，再谈内核传输层。
- 相关修复：`8d15d09a`（桥注册前置 + 无条件 exit dump）、`5d02ccad`（Rust listSessions 补列 iSH 会话）。

### 8.7 插件 UI 卡死 60 秒（compose_dsl 渲染 / 点击）🟡 部分缓解（60s 渲染已消失，朋友圈逻辑仍断裂）
- **现象**：市场插件（实测 `com.operit.qingpei_moments` 朋友圈）打开后卡住不渲染，最终弹 `COMMAND_ERROR: Script execution timed out after 60000 milliseconds`；即使渲染出来，点按钮也无响应。**所有 compose_dsl 插件通病，非单个插件问题。**
- **实测时序（设备 operit.log，多次复现一致）**：

  | 时间 | 事件 |
  |---|---|
  | `05:42:20.084` | `compose-render-start`（Dart） |
  | `05:42:20.124` | `tool.execute.request tool=get_system_setting`（0.04s，**立刻**） |
  | — | **59.99 秒空白** |
  | `05:43:55.361` | `compose-render-finish elapsedMs=60016 success=false`（Dart 60s 看门狗关通道） |
  | `05:43:55.393` | `tool.execute.start`（看门狗触发后 32ms 才排到） |
  | `05:43:55.402` | `tool.execute.error` **工具本身仅 15ms** |
  | `05:43:55.415` | `compose-request-finish success=true` + `worker-send-error: sending on a closed channel` |

- **关键判读**：`tool.execute.request` 与 `tool.execute.start` **同在 `AIToolHandler::executeTool` 内**（`AIToolHandler.rs:1136` / `:1212`），所以 60s 是**函数内部耗时，不是"排队等执行器"**。工具本身 15ms，卡的是中间那 60 秒。JS 最终渲染成功（`success=true`）但回传通道已被关 → UI 永远出不来。
- **影响范围（已验证渲染与点击同源）**：两条路径最终汇合到同一个 `AIToolHandler::execute_tool_call`——
  - 渲染：`Tools.System.getSetting` / `Tools.Files.read` → `runtime_bindings.rs:125` → `execute_tool_call`
  - 点击：`ctx.callTool` → `ToolPkgComposeDslBridge.rs:607` → `toolCall()` → `JsExecutionRuntimeBridge.script.js:156` `callNative('callToolAsync')` → `JsLibraries.rs:249` `__operitNativeCallTool` → `JsEngine.rs:2367` `nativeCallToolStrings` → `JsNativeInterfaceDelegates.rs:417` `execute_tool_call`
- **已尝试的修复（commit `e59750f4`，上机验证【失败】）**：在 `execute_tool_call` 的 `executeTool` 之前加 `AsyncToolExecutionScope::enter()`，意图让嵌套工具调用回到"已授权栈"、`executeAccessPreflight`（`:765`）短路、跳过 `:735 getAiPermissionMode()`。**装了新包实测 60s 卡死一点没变**（修复前后均为 59.99s）。该改动语义本身合理，暂留作防御，但**别指望它治病**。
- **已排除（两个走过弯路的错误方向，别重蹈）**：
  1. ❌ "`getAiPermissionMode()` → `dataStore.data()` 等锁 60s"——`e59750f4` 专治此点，实测无效。
  2. ❌ "权限审批拦截"——`asyncPermissionRequiredResult`（`:895`）报的 `Interactive tool permission requires asynchronous tool execution.` 是**通知类工具**（`send_notification`）的报错；朋友圈的 `get_system_setting` 报的是 `Namespace must be one of: system, secure, global`，说明**它的权限检查是通过的**，没卡在权限。
  3. 已排除的快速项：`notifyToolCallRequested`（`:1142`）只跑钩子、日志 `hookCount=0`；`getToolExecutorOrActivate`（`:1150`）对内置无 `:` 工具是短路径。
- **原 60s 真凶（已证实并缓解，2026-08-29）**：插桩上机后确认不是"静态猜的 inner 互斥锁等待"，而是 **PM 锁争用 / 重入**导致渲染与工具互等。`bd09d094` 把工具生命周期通知/拦截改非阻塞 `try_lock` 后，mini5 实测 `compose-render-finish elapsedMs=52` —— **60s 渲染卡死消失**。⚠️ 治标：持锁真凶（frb 生成桥 / Dart 侧持锁点）未根治，换触发路径仍可能复现。
- **插桩已上机验证（2026-08-29，`157a4eb2`+`6221dabe`）**：7 条 `tool.stage.*` + 逐 hook 时间戳 + inv 贯通已推送并在 mini5 跑过，正是它一次钉死 60s 卡点（PM 锁争用）。**验证通过后应单独 commit 移除，避免日志噪音。**
- **排查顺序（别重蹈）**：先看设备日志 `tool.execute.request` → `tool.execute.start` 的时间差定位"是不是卡在 executeTool 内部" → 再读 `tool.stage.*` 定位具体步 → 最后才动代码。**静态排除法在这个问题上已经错过两次，优先信插桩。**
- **关联影响**：这 60 秒期间，走同一条链路的 gRPC 调用（包管理列表、转换分析）会一并被拖住转圈（`MethodChannelCoreProxy` 无超时，会一直 loading）。已加 120s 超时兜底（见 §16.4），但那是"报错可重试"不是"修好"。
- **2026-08-29 更正与补充（接手必读，覆盖上面的过时判断）**：
  - **朋友圈仍打不开 ≠ 60s 渲染问题**，真因两条（设备日志 + 源码核对 `hosts/apple/src/tools/system/mod.rs:160-167`，非猜）：
    1. **iOS `getSystemSetting` 是写死 stub**：把 `namespace`/`setting` 直接 `let _=` 丢弃，永远 `Err("iOS system settings are not readable by this host")`。因此 **`17d7ab08`（放开 iOS getSetting namespace 硬校验）是错误归因、无效修复**——iOS 上无论 namespace 是什么都取不到 setting。朋友圈 `loadConfig` 调 `getSetting(moments_data,...)` 永远 error，Android sdcard fallback 在 iOS 也不存在（android-compat 为空）→ 朋友圈拿不到 config。
    2. **`moments_tools:refresh_ui` JS 端死锁**：render 52ms 成功后该工具入栈 `tool.exec.enter inv=4` → `notify_requested` → `Z2_pre_intercept` → `intercept.skip`（PM 锁 busy，正常）→ 之后**无 `tool.execute.start`/exit**，JS 函数永远不返回。第三次触发虽跑到 `activate`/`validated`/`preflight_enter`/`preflight_done`/`execute.start`，但**仍无 `tool.ffi.exit`**，20s+ 后 `host interaction timed out`、runtime 重启。挂点在 JS 内部 await/调用（环境曾报缺 `setTimeout` 全局，QuickJS worker 运行环境不完整），**非 PM 锁**。
  - **同类 bug 已修（不同根因，别混淆）**：
    - `47c2579f`：包工具经同步闭包调同步 `executeTool` → 同步 preflight 拒含 `:` 包工具（`Interactive tool permission requires asynchronous tool execution.`）。新增 `executeToolViaPackageProxy` 进嵌套授权作用域让 preflight `:804` 短路放行；task_done_notifier 等包内工具已可在 AI 聊天执行。
    - `84bb2e31`（Dart UI）：① `MarketEntryDetailScreen._install` 的 `setState` 加 `mounted` 守卫，修"点安装崩溃"（setState on unmounted → Null check 崩溃）；② `conversion_analysis_sheet.fetchConversionReport` 给 `http.get` 加 30s、FFI `analyzeToolPkgConversion` 加 60s timeout，修"转化分析无限转圈"。
  - **接手待办**：① 朋友圈真上 iOS——让插件 `loadConfig` 改读 `ToolPkg.getConfigDir()/moments_config.json`（SDK 已有此 API）或在 iOS host 实现真 KV 存盘（风险大，推荐前者）；② `refresh_ui` 死锁打 JS 探针钉死具体 await；③ 清理 `157a4eb2`/`6221dabe` 插桩（单独 commit）；④ com.clean.tv 等插件资源路径残缺（webview 404，设备日志 `File or directory does not exist: .../runtime/cache/toolpkg/com.clean.tv-5f860614`），属插件发布侧资源清单问题，非本端可改。

---

## 9. 接手快速启动指南

> 以下命令全部可直接复制执行，假设接手方是 AI 开发者。

### 9.1 环境准备
```bash
git clone git@github.com:ddddddedcds/Operit2-iOS-Experimental.git -b feat/ios-jailbreak-preview4
# 本机 Theos（编 tweak/CC）；Xcode + iOS 16 SDK（swiftc typecheck）
# 设备：Dopamine rootless iOS 16.7，SSH mobile@192.168.1.xx（IP 可能变）
```

### 9.2 本机验证（不碰设备）
```bash
cd hosts/ios/tweak && make clean && make                       # 验证 C/ObjC 改动
cd hosts/ios/ccmodule && make clean && make && ldid -S .theos/obj/debug/OperitCC.bundle/OperitCC
cd apps/flutter/app/ios/Runner && \
  xcrun swiftc -typecheck -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" -target arm64-apple-ios16.0 <改动文件>.swift AppLockUI.swift
cd plugins/packages/buildin && NODE_PATH=/Users/mac/.workbuddy/binaries/node/workspace/node_modules \
  /Users/mac/.workbuddy/binaries/node/workspace/node_modules/.bin/tsc -p tsconfig.json --noEmit
cd hosts/ios && cargo build --target aarch64-apple-ios --release 2>&1 | tail -5
```

### 9.3 打包 + 装机（改完 → 验证闭环）
```bash
cd hosts/ios
ldid -S ccmodule/.theos/obj/debug/OperitCC.bundle/OperitCC
cp ccmodule/.theos/obj/debug/OperitCC.bundle/OperitCC deb/files/Library/CCSupport/OperitCC.bundle/
sed -i '' 's/^Version: .*/Version: 0.3.87/' deb/DEBIAN/control
cd deb && OPERIT_PACK_SCHEME=rootless APP_SRC="/Users/mac/Downloads/<CI新包>.app" bash build_deb.sh
scp operit2-ios_0.3.87_iphoneos-arm64.deb mobile@192.168.1.xx:/tmp/
ssh mobile@192.168.1.xx 'echo <PASSWORD> | sudo -S dpkg -i /tmp/operit2-ios_0.3.87_iphoneos-arm64.deb'
ssh mobile@192.168.1.xx 'echo <PASSWORD> | sudo -S killall -9 SpringBoard'
```

### 9.4 设备调试（SSH，不改代码）
```bash
ssh mobile@192.168.1.xx 'tail -50 /var/jb/var/mobile/.operit/logs/tweak.log'     # tweak 日志（头号证据）
ssh mobile@192.168.1.xx 'cat /var/mobile/.operit_panic.log 2>/dev/null | tail -20' # app 崩
ssh mobile@192.168.1.xx 'ps aux | grep operit_agent'                              # daemon 状态
# ⚠️ ios-mcp 监听设备 127.0.0.1:8090，必须包在 ssh 里执行（Mac 上裸跑 curl 打不到设备）
ssh mobile@192.168.1.xx 'curl -s http://127.0.0.1:8090/mcp -H "Content-Type: application/json" -H "MCP-Protocol-Version: 2025-11-25" -d '"'"'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"open_url","arguments":{"url":"weixin://"}}}'"'"''
```

### 9.5 探路方法论（新功能怎么下手）
1. **有同类插件 → 研究其实现**：拉 dylib → `strings` + `otool -ov` → 提取 hook 目标 → 查头文件 → 真机 probe
2. **hook 层选连接层**：UI 层方法"存在但不触发"时，找连接层（Siri：AFUISiriSession → AFConnection）
3. **probe 先行**：先加无副作用日志 hook 确认触发和参数结构，再实现

---

## 10. 已知 bug 的可执行修法（给接手 AI）

### 10.1 CCSupport 模块不显示（§8.1）
- 对照 SiriPlus 的 CC bundle（`/var/jb/Library/CCSupport/*.bundle/Info.plist`）逐键 diff → 改 `hosts/ios/ccmodule/Info.plist` + `operit_cc.m` → `ldid -S` 重签 → 重打包 → 装机 → respring 看"更多控件"。

### 10.2 背景选图崩溃（§8.2）✅ 已修复
- 文件：`apps/flutter/app/lib/ui/features/settings/appearance/AppearanceSettingsPanel.dart`；5 处 XTypeGroup 已补 UTI。待验证：编译→装机→选图不崩。

### 10.3 super_admin 终端缺 sessionId（§8.3）✅ 已修复
- 文件：`plugins/packages/buildin/super_admin.ts`（增加 `create_terminal_session`）。待验证：真机 AI 调 create_terminal_session → 拿 sessionId 全链路。

### 10.4 手动终端 PATH 不全（§8.4）✅ 已修复
- 文件：`hosts/ios/src/terminal.rs`（`probeSystemShell` 注入显式 PATH）。待验证：装机后 `uname` 不报 not found。

### 10.5 设置面板未显示（§8.5）
- 对照设备上正常工作的第三方面板 Info.plist 键集合 diff；确认 preferenceloader 是否整体工作。

---

## 11. 私有 API 专题（方法论核心）

### 11.1 用到的私有 API 全景（实测，iOS 16.7）
| 领域 | 框架/类 | 方法/API | 用途 | 可靠性 |
|---|---|---|---|---|
| Siri 识别 | AssistantServices `AFConnection` | `_tellSpeechDelegateSpeechRecognized:` | 拿 Siri 识别文本 | ✅ |
| Siri 回答 | AssistantServices `AFConnection` | `_handleCommand:reply:` | 拦截 Siri 回答（SAUIAddViews）| ✅ |
| Siri 视图宿主 | AssistantUI `AFUISiriViewController` | `viewDidAppear:` | 挂自绘卡片 | ✅ |
| 通知拦截/记录 | BulletinBoard `BBObserver` | `_queue_updateBulletin:withReply:` | 通知源头拦截 + 读取 | ✅ |
| 通知参数 | BulletinBoard `BBBulletinUpdateTransaction` | `.bulletinUpdate.bulletin`（三层）| iOS 16 取 sectionID | ✅ |
| 锁屏检测 | Darwin notify | `com.apple.springboard.lockstate` | 锁屏/解锁 | ✅ 官方 |
| 应用锁 | SpringBoard 前台检测 + 自绘页 | tweak 内 | 拦截前台 | ✅ |
| installed_apps | LSApplicationWorkspace | `defaultWorkspace`/`allApplications` | 枚举 app | ⚠️ `schemes` key 崩 |
| 截图 | CARenderServer / SB | ios-mcp 内部 | 截图 | ⚠️ 版本差异大 |

### 11.2 私有 API 发现方法（效率排序）
1. **参考实现优先**（最快）：`strings` + `otool -ov` 拉同类插件 dylib
2. **社区公开头文件**：nst/iOS-Runtime-Headers（只到 iOS 14，方法名可能过时）
3. **运行时类清单**（objc_getClassList）：设备活清单
4. **真机 probe**（最终裁决）：hook 候选方法 + 日志验证触发 + 参数结构

### 11.3 使用准则（防崩溃，血泪教训）
1. **KVC 安全**：裸 `value(forKey:)` 对不存在 key 抛 NSException → SIGABRT，一律 `responds(to:)` 前置
2. **@try 保护**所有私有 API 调用
3. **hook 层选择**：连接层 > UI 层
4. **禁用手动 swizzle**：`method_setImplementation` + 延迟原调 → 野指针崩 SpringBoard
5. **probe 先行**
6. **参数结构以真机实测为准**

### 11.4 iOS 16.7 私有 API 差异（实测 vs 社区头文件）
| 差异 | 社区头文件（iOS 14）| iOS 16.7 实测 |
|---|---|---|
| Siri 回答 hook | AFUISiriSession（UI 层）| **AFConnection（连接层）才触发** |
| Siri TTS | `speechSynthesis` getter | **不存在** |
| Siri 气泡 | 改 `SAUIAssistantUtteranceView.text` | 可改但**跨进程不刷新** |
| 锁屏 KVC | SBLockScreenManager.isLocked | **失效** → 用 Darwin notify |
| 通知参数 | 传 BBBulletin | **BBBulletinUpdateTransaction（三层）** |
| installed_apps | `schemes` key | **key 不存在 → 裸 KVC 崩** |
| 截图 | SBScreenshotManager 多方法 | 实测仅 `saveScreenshotsWithCompletion:` |

### 11.5 稳定性风险
- 每个 iOS 小版本都可能变；非越狱无私有 API（App Store 会被拒）；越狱分发（Sileo/自签）无此限制。
- 合规：本项目为学习研究用途；产品化需自行评估法律/政策风险。

---

## 12. 依赖插件清单（2026-08-11 实测版本）

### 12.1 control 声明依赖（Sileo 自动安装）
| 包 | 实测版本 | 用途 | 缺失后果 |
|---|---|---|---|
| **com.witchan.ios-mcp** | 1.2.3 | 设备自动化后端（:8090）| 设备自动化全失效 |
| **preferenceloader** | 2.2.8 | 设置面板加载 | 设置里无 Operit2 条目 |
| **com.opa334.ccsupport** | 1.3.13-2 | 控制中心模块加载 | 控制中心无 AI 模块 |

### 12.2 实际运行需要（control 未声明）
| 包 | 用途 | 缺失后果 |
|---|---|---|
| **ellekit** | tweak 注入运行时（TweakInject 必需）| tweak 不加载 |
| **AppSync Unified** | 安装 adhoc 签名 app | app 可能无法安装/启动 |
| **ldid**（工具）| postinst 重签 daemon + trustcache | daemon 被 AMFI 拒载（-9）|

### 12.3 第三方原作出处（control Description 已声明）
- Operit2 原作：github.com/AAswordman/Operit2（改编，非官方分支）
- ios-mcp：github.com/witchan/ios-mcp（本 fork 用适配版：github.com/ddddddedcds/ios-mcp）
- dsh 运行时：deepseek-harness（独立仓库 `ios-port` 分支），Node22 + @deepseek-ai/dsh

---

## 13. Debug / Release 构建切换

| 组件 | 当前模式 |
|---|---|
| Flutter app（CI）| **release** |
| tweak dylib | debug（`make FINALPACKAGE=1` 出 release）|
| CC 模块 | debug（同上）|
| daemon（Rust）| **release** |

- Theos 没有 `make release`，用 `make FINALPACKAGE=1`；产物在 `.theos/obj/`（根，非 obj/release）。
- 切换模式前先 `make clean`（增量缓存混旧产物）。
- debug/release 只影响 tweak/CC；Flutter 始终 release，daemon 始终 release。

---

## 14. 冷启动性能专题（✅ 已解决：用户 2026-08-29 实测设备冷启动秒开）

### 14.1 现象（历史 + 当前状态）
- **历史（本专题撰写时）**：冷启动（进程被杀后重开）**60 秒**界面才出来；热启动秒开。微信同设备冷启动 5 秒。
- **当前状态（2026-08-29 用户设备实测）**：冷启动已 **秒开**，60s 不再复现。本专题保留作「为何曾 60s」的根因档案，但「待解决」结论已过时。

### 14.2 根因（fs_usage 实锤）
- Runner 冷启动 dyld 处理 **726 个动态库**（Flutter 引擎 + 全量插件 framework）。
- **Dopamine rootless 的 dyld 对每个库做映射/验证** → 726 库从秒级放大到 60 秒级。

### 14.3 已排除项（避免重复踩坑）
Impeller shader / Metal 缓存 / 网络等待 / daemon 等待 / MCP 插件 / Rust 初始化 / Dart 初始化（30ms）/ dyld 自身（实测 FRONT→DART 22-34s）——全部排除。

### 14.4 终极归因
**60s = Dopamine 系 dyld hook（2.4+ 架构）的逐库处理 × Flutter 的 726 库。**（此为「曾 60s」的根因分析，仍成立）
- Dopamine 2.4 changelog 自述 "introduced a dyld hook and redirects dyld to a different folder via symlink"，逐库路径重映射 × 726 = 60s。
- iOS 16.7 无解环境：Dopamine 3.x / Relaxin 都带 dyld hook（都 60s）；≤2.3 不支持 iOS 16.7；Hide Jailbreak 会禁用 dyld hook 但会隐藏整个越狱（operit2 自身失效）。
- **唯一解（旧结论）**：软移植（减库，见下）或接受 60s + 体验层绕过（Siri 卡片已实现）。
- **状态更新（2026-08-29）**：用户设备实测冷启动已秒开，60s 不再出现。说明上述「唯一解」中某一项已被实际落地（候选：`0fde20d3` 的 Rust core 首帧前并行预构造 / §14.5 软移植减库已应用 / 动态库数量已下降），但具体是哪次改动消除 60s 尚未逐 commit 考证。**根因档案保留，「待解决」结论作废。**

### 14.5 软移植（已验证可行）
- SwiftUI 壳 + Rust core C ABI 静态链接，`apps/ios-mini/OperitMini` 真机跑通（初始化 + 聊天链路）。
- 收益：726→~200 库，冷启动 5-10 秒；包/插件/技能/MCP/记忆全在 Rust core 保留。
- 成本：Flutter UI 层 228 文件/10.7 万行 Dart 需重写为 SwiftUI（3-6 周）。

---

## 15. 相对上游（AAswordman/Operit2）的改动与可回馈清单

> 给上游/接手方快速定位：**改了哪些、哪些能吸收回上游**。

### A. iOS 越狱专属（不可回馈，仅本 fork 有效）
| 改动 | 位置 | 依赖 |
|---|---|---|
| SpringBoard tweak（Siri 集成 / 通知拦截 / 锁屏会话 / 应用锁 / 剪贴板） | `hosts/ios/tweak/operit-sb.x`（~2100 行） | 私有 API hook（见 §7/§11），仅越狱 |
| 设备自动化 daemon（VLM 循环 TCP 8890） | `hosts/ios/src/bin/operit_agent_daemon.rs` | root LaunchDaemon + ios-mcp |
| 控制中心 AI 模块 | `hosts/ios/ccmodule/OperitCC` | CCSupport（闭源） |
| 越狱打包链（rootless deb / ldid / trustcache） | `hosts/ios/deb/build_deb.sh` | Dopamine/ellekit |

### B. 通用可吸收（公开 API，建议合并回上游）
| 功能 | 位置 | 说明 |
|---|---|---|
| **TCC 权限全家桶** | `apps/flutter/app/ios/Runner/TCCServer.swift` + `plugins/packages/buildin/system_io.ts` | contacts/calendar/reminders/photos/health/location，全走系统公开 API + TCC 授权弹窗；`responds(to:)` 前置防崩（iOS 16 不存在的 key 抛 NSException） |
| **屏幕使用时间 7 工具** | `apps/flutter/app/ios/Runner/ScreenTimeServer.swift` + `plugins/packages/buildin/screen_time.ts` | DeviceActivity 官方 API，任意 app 可锁（无需 picker） |
| **快捷指令接入** | `apps/flutter/app/ios/Runner/ShortcutsServer.swift` | shortcuts:// URL scheme 跑任意快捷指令 |
| **AI 主动通知/灵动岛** | `apps/flutter/app/ios/Runner/NotifyServer.swift` | 本地通知 + 灵动岛 |
| **深链/已装应用枚举** | `apps/flutter/app/ios/Runner/OpenURLServer.swift` | responds 探测（`schemes` key 在 iOS 16 不存在，裸 KVC 会崩） |
| **内置 iSH 终端** | `tools/ios-runtime/ish/`（构建）+ `hosts/ios/src/terminal.rs`（桥）+ Flutter 终端 UI | kernel=ish + arm64 Alpine 3.19，可独立成插件/子项目复用 |
| **设备自动化子代理模式** | `plugins/packages/buildin/device_automation.ts` + ios-mcp | AutoGLM 云端看屏决策 + ios-mcp 执行，非越狱可替换执行端 |

### C. 结构判断（接手方必读）
- 越狱侧（tweak/daemon/私有 API）与通用侧（TCC/屏幕时间/Shortcuts/通知）**边界清晰**：通用侧全部不依赖越狱，可整体移植。
- 冷启动 60s 曾为 Dopamine dyld hook × Flutter 726 库的固有开销（§14，**已解决**：2026-08-29 用户实测秒开）；软移植减库方向已验证（§14.5）。

---

## 16. Android 插件兼容层专题（接手者必读）

> 目标：说清"兼容层 / 转换器 / 转换分析"三者是什么关系，以及**为什么大量市场插件在 iOS 上装得上却跑不动**。

### 16.1 常见误解：兼容层和转换器是两套机制？
**不是。它们是同一个函数在两个时机各跑一次。**

| 名称 | 位置 | 做什么 | 时机 |
|---|---|---|---|
| **兼容层（运行时）** | `core/crates/operit-util/src/AndroidPathRewriter.rs` | `rewrite_android_paths()`：`/sdcard`、`/storage/emulated/0` → `/mnt/android/sdcard`；`rewrite_vfs_mount_paths()`：shell 命令里的挂载路径 → 物理路径 | JS 加载时在内存改写 + shell 执行前映射 |
| **转换器（安装期）** | `core/crates/operit-tools/src/tools/packTool/AndroidToolPkgPathRewriter.rs` | 把 ZIP 内每个 `.js` 条目取出、调用**同一个** `rewrite_android_paths()`、写回封存 | 安装时一次性改磁盘上的包 |

`AndroidToolPkgPathRewriter.rs:15` 直接 `use operit_util::AndroidPathRewriter::rewrite_android_paths;` —— **唯一实现只有一份**，转换器只是个"遍历 ZIP 条目"的壳。

### 16.2 为什么要查两次（各有盲区，不是冗余）
- **安装期覆盖不到**：**加密条目直接跳过**（源码注释明写"运行时 JsEngine 兜底"），这类只能靠运行时层。
- **运行时覆盖不到**：它改的是内存副本、不动磁盘上的包；且 **shell 命令不走 VFS**（`Tools.System.shell("find /sdcard/...")` 直接碰真实文件系统），必须靠 `rewrite_vfs_mount_paths` 单独映射到物理路径。
- 物理落点：`<runtimeRoot>/android-compat/sdcard/...`，iOS 上即 `/var/mobile/.operit/runtime/android-compat/...`。
- 接线共 4 处：市场安装 `addMarketToolPkgFileFromExternalStorage`、本地导入 `importToolPkgFromFile`、运行时 JS 加载 `JsEngine.rs:2728`、shell 执行 `hosts/ios/src/terminal.rs:295`。

### 16.3 ⚠️ 兼容层只治路径，治不了 API 调用
**这是"装得上却跑不动"的根因。** 路径重写做的是字符串替换，对下面的**安卓专属 API** 完全无能为力——插件装的时候路径改得再对，一调用就崩。

**A. `core/crates/operit-js-bridge/src/javascript/AndroidUtils.script.js`（5 类 / 26 方法）**
> 文件头明写：`This library requires Shizuku service to be running with proper permissions`，底层全是 shell 命令。

| 类 | 方法 | 底层命令 |
|---|---|---|
| `Android`（入口） | `packageManager` / `systemManager` / `deviceController`（属性）、`createContentProvider(uri)` | — |
| `PackageManager` | `install` `uninstall` `getInfo` `getList` `clearData` `isInstalled` | `pm` |
| `ContentProvider` | `uri`（属性）`setUri` `query` `insert` `update` `delete` | `content` |
| `SystemManager` | `getProperty` `setProperty` `getAllProperties` | `getprop` / `setprop` |
| | `getSetting` `setSetting` `listSettings` | `settings get/put/list` |
| | `getScreenInfo` | `wm size; wm density` |
| `DeviceController` | `systemManager`（属性）`takeScreenshot` `recordScreen` | `screencap` / `screenrecord` |
| | `setWiFi` `setBluetooth` | `svc wifi` / `svc bluetooth` |
| | `lock` `unlock` | `input keyevent 26/82` |
| | `setBrightness` `setVolume` `reboot` | `settings put` / `media volume` / `reboot` |

类型定义 `plugins/types/android.d.ts`（301 行）与上述 5 个类**一一对应**。这些命令 **`pm` / `getprop` / `settings` / `screencap` / `svc` / `input` / `reboot` 在 iOS 上根本不存在**。

**B. `core/crates/operit-js-bridge/src/javascript/OkHttp3.script.js`**
- `OkHttp.newClient()` / `OkHttp.newBuilder()`、`OkHttpClientBuilder`、`OkHttpClient`（Java 库，iOS 无对应）。

**C. 调用机制**
- `Java.` / `Java.android`（Java 桥）、`adb `（adb 命令）。

### 16.4 转换分析面板（只读检测器，不是转换器）
- 后端：`RuntimePackageManager::analyzeToolPkgConversion(toolpkgPath)`（JSON：`androidApiTokens` / `pathLiteralCount` / `needsPathRewrite` / `hasFrameworkApis` / `verdict[direct|path_rewrite|android_framework]`），靠 `operit-core-proxy` build.rs 自动 codegen 出 Dart（**无需手改 schema**）。
- 前端：`apps/flutter/app/lib/ui/features/packages/dialogs/conversion_analysis_sheet.dart`（Dart 文件名为 lower_case_with_underscores），`MarketEntryDetailScreen` 加「转换分析」按钮 + 安装前拦截（有框架依赖时弹确认框）。
- **它的价值恰恰是兼容层做不到的事**：区分"改完路径就能跑"和"依赖安卓 API、改了路径照样崩"。兼容层只会闷头改路径，改完插件该崩还是崩，它自己分不出来。
- **附件兜底**：`MethodChannelCoreProxy.call()` 已加 `.timeout(callTimeout)`（默认 **120s**，故意宽松以免误伤下载/安装/AI 流式等合法长操作）。作用是把"底层不回包 → UI 无限转圈"变成 `CoreLinkError(code:'TIMEOUT')` 可报错重试——**是体验兜底，不是修好**。

### 16.5 已知问题（检测精度）
- `scanAndroidApiDependencies`（`RuntimePackageManager.rs:2621`）用 **14 个硬编码 token** 做子串匹配：
  `Java.android` `Java.` `OkHttpClient` `OkHttp.` `RequestBuilder` `SystemManager` `DeviceController` `ContentProvider` `PackageManager` `ClipboardManager` `ClipData` `Shizuku` `Android.` `adb `
- **其中 `ClipboardManager` / `ClipData` / `Shizuku` 是"幽灵 token"**：全代码库搜索**零实现**（只存在于这张 token 表里）。它们是启发式检测词，会**误报**（注释里写一句"用了剪贴板"也会被判成依赖安卓）。
- 该清理建议已提出，**用户明确决定保留**（2026-08-29），后续非用户要求不要动。
- 其他精度限制：只扫 `.js` / `.ts` 条目；非 JS 字面量靠运行时 JsEngine 兜底；子串匹配无法区分"字符串常量"与"真实调用"。

---

## 附录 A：roothide（已停更，历史参考，不再维护）
> **状态**：roothide 版自 2026-08 起**停止支持、不再维护**，本仓库不再产出 roothide deb，无相关构建脚本。以下内容仅为历史记录，供有 roothide 设备的研究者参考，**不保证可用**。

- 历史背景：0.3.54 之后的版本只在 Dopamine rootless 主测试机实测，roothide deb 从未真机验证。
- 历史修复（commit 00fe35c4，0.3.75，仅供参考）：
  1. 双视图数据目录：`roothide_compat.h` 的 `operit_env_path` 把 `/var/jb/var/mobile/.operit` 与裸 `/var/mobile/.operit` 统一映射到 `<jbroot>/var/mobile/.operit` 物理目录，解决 SpringBoard（real-root 视图）与 app/daemon（jbroot 视图）数据分离导致的通知/锁屏/应用锁/Siri 数据全断。
  2. detect_jailbreak 修正：`/var/jb` 指向 `/` ⇒ roothide，指向 procursus ⇒ rootless（原逻辑误判）。
  3. postinst 信任链：删除 `jbctl trustcache add <路径>`（Dopamine jbctl 收 cdhash 而非路径）。
- 历史架构备注：Relaxin 是 Dopamine 系 roothide，冷启动同样 60s（dyld hook 固有开销，非 Flutter 单独问题）；dlopen 的 app 内嵌 framework 需 trustcache 注册（Dopamine 主版收 cdhash，Relaxin 收路径，jbctl 语法分叉）。

---

## 附录 B：项目状态与交接

- **当前状态**：**活跃开发中**（2026-08-28 恢复，详见文首「项目状态」）。维护者为本 fork 所有者；本手册同时供 operit 官方 / 越狱社区开发者接手参考。
- **决策沿革**（避免误读旧文档，重要）：
  - 2026-08-26：曾决定**长期停开发**、定位 POC、只作知识封存。
  - 2026-08-28：**推翻上述决定**，恢复 active 开发；新功能（含热更新 / 实时补丁）不再以"停开发"为阻塞。
  - ⚠️ 因此本手册中任何残留的「POC / 封存 / 停开发 / 暂存待取」措辞均属**过期表述**，**以本节为准**。
- **官方可吸收**：**§15.B 通用可回馈清单**（TCC 权限全家桶 / 屏幕时间 / Shortcuts / 通知 / iSH 终端，全部公开 API 不依赖越狱）+ 方法论（§9.5 / §11）+ 越狱专属 hook 地图（§7）。
- **2026-08-29 收尾状态（重要，接手请先看）**：
  - ✅ 已完成并推送：插件 60s 渲染卡死**已缓解**（§8.7，`bd09d094` try_lock + `157a4eb2`/`6221dabe` 插桩，mini5 上机实测 render 52ms）；`47c2579f`（包工具异步权限）、`84bb2e31`（Dart 安装崩溃 + 转化卡死）均已推送；安卓兼容层架构梳理（§16）、`MethodChannelCoreProxy` 120s 超时兜底。
  - 🟡 **朋友圈仍打不开（不同根因）**：iOS `getSystemSetting` 是写死 stub（`hosts/apple/src/tools/system/mod.rs:160-167`）→ `17d7ab08`（放宽 namespace 校验）是**错误归因、无效修复**；另 `moments_tools:refresh_ui` JS 端死锁（§8.7）。两条均待接手处理，非 60s 渲染问题。
  - 🟡 **插桩已上机、待清理**：`157a4eb2`/`6221dabe` 的 `tool.stage.*` 全链路插桩已推送并在 mini5 跑过，验证通过后应单独 commit 移除，避免日志噪音。
  - 打包/装机流程见 §5.2 / §5.4；**注意**：`Runner.app` 是预编译产物，源码改动必须等 CI 重新出包才生效，验包可用"grep 新增文案"的方式确认（§9.3 有记）。
  - 工作区遗留（**未提交，勿误 add**）：`apps/flutter/app/pubspec.lock`（analyze 时顺带升了 intl / matcher）、`hosts/ios/deb/files/usr/share/operit/operit.entitlements`（打包脚本改的 bundle id）。
- [x] 代码：feat/ios-jailbreak-preview4（当前 **0.3.87**；`157a4eb2`/`6221dabe` 插桩已推送，待验证后清理）
- [x] 文档：本 HANDOVER.md
- [x] 两条交付线：越狱 deb（完整）/ nonjb ipa（聊天+iSH）—— **0.3.86 已验证**；**0.3.87 已打包，插件 UI 卡死问题上机验证失败**（§8.7），其余功能待回归。
- [x] dsh 集成产物：运行时 deb（nodejs 22.23.2-3 + dsh-ios 0.1.1-rc.2-2，deepseek-harness-ios `ios-port`）+ toolpkg 桥 1.1.2（deepseek-harness-ios-toolpkg，独立仓库，见 §3.5）
- [ ] 遗留 bug：§8.1（CC 模块）/ §8.5（设置面板）
- [ ] 可探索：AI 回复通知（BBServer action 回调；AutoResponder 是 iOS 6-9 短信层先例）；软移植减 60s（§14.5）
