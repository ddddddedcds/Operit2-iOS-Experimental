# Operit2 越狱 iOS 移植 —— 交接手册（HANDOVER）

> **项目定位**：**POC（概念验证）**——验证"越狱 iOS + AI 深度集成"这条路是否可行。结论：**可行，但 Operit2 的 Flutter+Rust 架构硬移植进越狱 iOS 不划算（bug 链式暴露 + 冷启动 60s），接手前应先评估架构重做**。本手册记录全部架构、运行原理、坑与遗留问题，供 operit 官方 / 越狱社区开发者接手。
>
> **仓库**：`github.com/ddddddedcds/Operit2-iOS-Experimental`（原 `Operit2-iOS-Jailbreak-POC`，2026-08-26 改名）。分支 **`feat/ios-jailbreak-preview4`**。当前版本 **0.3.86**。
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
│   │   ├── DEBIAN/control            #   版本/依赖（当前 Version 0.3.86）
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
│   ▲ Operit2 经 toolpkg（桥，独立仓库 1.1.1）把 dsh 面板放进侧边栏            │
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
- **toolpkg `com.operit.deepseek_harness.ios`**（独立仓库 [`dddddedcds/deepseek-harness-ios-toolpkg`](https://github.com/ddddddedcds/deepseek-harness-ios-toolpkg)，当前 1.1.1）：把 DSH Web UI 接进 Operit2 侧边栏的「连接层/桥」。自己不提供 node/dsh，运行时由上面的 deb 提供；没有这层桥，Operit2 调不到 dsh 后端。
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
  - 两个 deb：`nodejs_22.23.2-3`（V8 W^X 全 JIT + small-icu）+ `dsh-ios_0.1.1-rc.2-1`（dsh 整包 + node-pty addon + koffi stub + fetch-shim），先装 nodejs 再装 dsh-ios，`dsh-ios` 启动即起 web（:3080）。
- **dsh toolpkg（桥）**（独立仓库 [`dddddedcds/deepseek-harness-ios-toolpkg`](https://github.com/ddddddedcds/deepseek-harness-ios-toolpkg)，当前 1.1.1）：
  ```bash
  git clone git@github.com:dddddedcds/deepseek-harness-ios-toolpkg.git
  cd deepseek-harness-ios-toolpkg && ./build.sh   # 从 manifest 读版本，产出 <version>.toolpkg
  # 或直接用已发布的 com.operit.deepseek_harness.ios-1.1.1.toolpkg
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
- **dsh toolpkg 桥**：1.1.1 状态卡版已部署 Operit2（WebView 内嵌因 dsh 桌面 UI 在窄侧栏无响应式适配而降级为状态卡，完整 UI 走浏览器打开 3080）

### 🟡 已 push 未端到端验证
- 权限全家桶（TCCServer + system_io 9 工具 + HealthKit）
- 设置面板（PreferenceLoader operitPrefs.bundle）——**用户实测未显示**（见 §8.5）
- 控制中心模块（OperitCC）——**用户实测未显示**（见 §8.1）
- installed_apps 修复（responds 探测）

### ⏳ POC 暂时无法验证
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

## 14. 冷启动 60 秒性能专题（接手者必读）

### 14.1 现象
- 冷启动（进程被杀后重开）**60 秒**界面才出来；热启动秒开。微信同设备冷启动 5 秒。

### 14.2 根因（fs_usage 实锤）
- Runner 冷启动 dyld 处理 **726 个动态库**（Flutter 引擎 + 全量插件 framework）。
- **Dopamine rootless 的 dyld 对每个库做映射/验证** → 726 库从秒级放大到 60 秒级。

### 14.3 已排除项（避免重复踩坑）
Impeller shader / Metal 缓存 / 网络等待 / daemon 等待 / MCP 插件 / Rust 初始化 / Dart 初始化（30ms）/ dyld 自身（实测 FRONT→DART 22-34s）——全部排除。

### 14.4 终极归因
**60s = Dopamine 系 dyld hook（2.4+ 架构）的逐库处理 × Flutter 的 726 库。**
- Dopamine 2.4 changelog 自述 "introduced a dyld hook and redirects dyld to a different folder via symlink"，逐库路径重映射 × 726 = 60s。
- iOS 16.7 无解环境：Dopamine 3.x / Relaxin 都带 dyld hook（都 60s）；≤2.3 不支持 iOS 16.7；Hide Jailbreak 会禁用 dyld hook 但会隐藏整个越狱（operit2 自身失效）。
- **唯一解**：软移植（减库，见下）或接受 60s + 体验层绕过（Siri 卡片已实现）。

### 14.5 软移植（已验证可行）
- SwiftUI 壳 + Rust core C ABI 静态链接，`apps/ios-mini/OperitMini` 真机跑通（初始化 + 聊天链路）。
- 收益：726→~200 库，冷启动 5-10 秒；包/插件/技能/MCP/记忆全在 Rust core 保留。
- 成本：Flutter UI 层 228 文件/10.7 万行 Dart 需重写为 SwiftUI（3-6 周）。

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

## 附录 B：交接状态
- **接续方**：operit2 官方（有意愿、有能力；当前因非越狱版排期忙，越狱版**暂存待取**）。
- **本 POC 定位**：探明"越狱 iOS + AI 深度集成"可行性 + 交付完整交接手册；不是可产品化代码，是知识+代码封存。
- **官方可吸收**：功能清单（§6）+ 合规子集（TCCServer 公开 API 部分）+ 方法论（§9.5 / §11）。
- [x] 代码：feat/ios-jailbreak-preview4（当前 0.3.86）
- [x] 文档：本 HANDOVER.md
- [x] 两条交付线均 0.3.86 验证：越狱 deb（完整）/ nonjb ipa（聊天+iSH）
- [x] dsh 集成产物：运行时 deb（nodejs 22.23.2-3 + dsh-ios 0.1.1-rc.2-1，deepseek-harness-ios `ios-port`）+ toolpkg 桥 1.1.1（deepseek-harness-ios-toolpkg，独立仓库，见 §3.5）
- [ ] 遗留 bug：§8.1（CC 模块）/ §8.5（设置面板）
- [ ] 可探索：AI 回复通知（BBServer action 回调；AutoResponder 是 iOS 6-9 短信层先例）；软移植减 60s（§14.5）
