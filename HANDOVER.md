# Operit2 越狱 iOS 移植 —— 完整交接手册（HANDOVER）

> **项目定位**：**POC（概念验证）**——验证"越狱 iOS + AI 深度集成"这条路是否可行。结论：**可行，但 Operit2 的 Flutter+Rust 架构硬移植进越狱 iOS 不划算（bug 链式暴露），接手前应先评估架构重做**。本手册记录全部架构、运行原理、坑与遗留问题，供 operit 官方 / 越狱社区开发者接手。
>
> **目标平台**：Dopamine rootless（iOS 16.7，主测试机 iPhone13,4（iPhone 12 Pro Max）/ A14）+ roothide；非越狱（TrollStore/自签 IPA 降级支持）
> **主分支**：`feat/ios-jailbreak-preview4`（截至 2026-08-11 共 10 commit）

---

## 1. 仓库结构与文件目录

```
operit2-fork-src/
├── hosts/ios/                          # ★ iOS 越狱侧全部代码
│   ├── tweak/                          # SpringBoard tweak（Logos）
│   │   ├── operit-sb.x                 #   核心：通知拦截/记录、锁屏会话、应用锁、剪贴板、Siri 集成（大文件 ~2100 行）
│   │   ├── operit-app.x                #   app 进程注入（次要）
│   │   ├── operit-sb.plist / operit-app.plist  # TweakInject 注入配置（Bundles: com.apple.springboard）
│   │   ├── Makefile                    #   Theos 构建（arm64+arm64e）
│   │   └── entitlements.plist
│   ├── ccmodule/                       # 控制中心 AI 按钮（CCSupport 模块）
│   │   ├── operit_cc.m                 #   OperitCCModule : CCUIAppLauncherModule（AppLauncher 拉起 operit2）
│   │   ├── Info.plist                  #   NSPrincipalClass=OperitCCModule, _CCModuleSizePROTOTYPE 1x1
│   │   └── Makefile                    #   ⚠️ 必须 ldid -S 签名（OperitCC_CODESIGN_FLAGS 无效，打包时手动 ldid）
│   ├── src/
│   │   ├── bin/operit_agent_daemon.rs  #   设备自动化 daemon（VLM 循环，TCP 8890）
│   │   └── managed_runtime.rs          #   运行时托管（数据目录初始化等）
│   ├── deb/                            # 打包目录
│   │   ├── build_deb.sh                #   一键打包（换 app → 签名 → packdeb）
│   │   ├── packdeb.py                  #   ar 打包器（OPERIT_PACK_SCHEME 切 rootless/roothide）
│   │   ├── build_all_0.3.66.sh         #   三产物批量打包（rootless+roothide deb + nonjb IPA）
│   │   ├── DEBIAN/control              #   版本/依赖（Version 0.3.70 起；Depends: com.witchan.ios-mcp, preferenceloader, com.opa334.ccsupport）
│   │   ├── DEBIAN/postinst             #   装机后：ldid 重签 daemon + trustcache 注册 + 启动 LaunchDaemon
│   │   ├── Runner.entitlements         #   rootless 签名 entitlement（app-sandbox=false + iokit-user-client-class + healthkit）
│   │   ├── Runner.roothide.entitlements #  roothide 用（+platform-application 等 4 项）
│   │   ├── Runner-nonjb.entitlements   #   非越狱 IPA 用
│   │   └── files/                      #   deb 内容 staging（见下）
│   └── target/                         # Rust iOS 交叉编译产物（daemon 二进制源）
│
├── apps/flutter/app/
│   ├── lib/                            # Flutter 业务代码
│   │   └── ui/features/...             #   settings/appearance（背景选图崩溃在这）、manual_terminal（PATH 不全在这）等
│   └── ios/Runner/                     # ★ iOS 原生桥（Swift）
│       ├── AppDelegate.swift           #   启动所有本地服务（8890-8895 监听入口）
│       ├── OpenURLServer.swift         #   TCP 8894：open_url / installed_apps / tcc 转发
│       ├── TCCServer.swift             #   TCP 8895：权限全家桶（通讯录/日历/提醒/照片/健康/定位）
│       ├── ScreenTimeServer.swift      #   TCP 8891：屏幕使用时间锁应用（写 tweak 名单）+ 吃醋巡检监控
│       ├── NotifyServer.swift          #   TCP 8893：AI 主动联系用户（通知/灵动岛）
│       ├── ShortcutsServer.swift       #   TCP 8892：快捷指令运行
│       ├── AppleRuntimeChannel.swift   #   Flutter↔Rust 桥（核心通道）
│       ├── AppleLocalInferenceRunner.swift  # 本地模型推理（OCR 等）
│       ├── AppLockUI.swift             #   应用锁授权 UI 控制器
│       └── AppleSnapshotImportInputChannel.swift
│
├── plugins/packages/buildin/           # ★ AI 工具定义（TS，插件运行时加载）
│   ├── device_automation.ts            #   设备自动化（tap/swipe/type/screenshot 等，连 daemon）
│   ├── open_url.ts                     #   深链（⚠️ 手册大部分未实测）
│   ├── system_io.ts                    #   权限全家桶 9 工具（contacts/calendar/reminders/photos/health/location）
│   ├── screen_time.ts                  #   屏幕使用时间（authorize/lock/unlock/monitor/usage）
│   ├── shortcuts.ts                    #   快捷指令
│   ├── notify.ts                       #   主动通知/灵动岛
│   ├── super_admin.ts                  #   超级管理员（终端/文件/进程等，⚠️ 缺 sessionId 入口）
│   ├── browser.ts / operit_editor.ts / extended_chat.ts / extended_memory_tools.ts
│
├── core/crates/operit-tools/src/tools/ # Rust 工具注册层
│   └── ToolRegistration.rs             #   工具注册 + screen_time_socket_command 等转发
│
└── HANDOVER.md                         # 本文件
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
│   │  命令：stop / goal <目标> / config <key>|<provider>|<base>|<model>            │
│                                                                                  │
│  [Runner.app]  ← Flutter + Rust 内核 + Swift 本地服务                              │
│   ├─ TCP 8891 ScreenTimeServer（锁应用/监控）                                     │
│   ├─ TCP 8892 ShortcutsServer（快捷指令）                                         │
│   ├─ TCP 8893 NotifyServer（主动通知/灵动岛）                                     │
│   ├─ TCP 8894 OpenURLServer（深链/installed_apps/tcc 转发）                       │
│   └─ TCP 8895 TCCServer（通讯录/日历/提醒/照片/健康/定位）                          │
└──────────────────────────────────────────────────────────────────────────────────┘

AI 工具调用链路：
TS 工具（buildin/*.ts）→ Rust ToolRegistration → Tools.Net.* 桥
  ├─ 设备动作 → daemon(8890) → ios-mcp(8090) → 设备
  ├─ 深链/权限 → OpenURLServer(8894) → TCCServer(8895)
  └─ 屏幕时间 → ScreenTimeServer(8891)
```

**关键设计原则**：
- **ios-mcp 是"手"**（逐动作 HTTP），**daemon 是"脑"**（VLM 决策循环），二者分离
- **所有跨进程通信用 TCP loopback（127.0.0.1）**——roothide 双文件系统视图下 unix socket 会"永不相遇"（daemon=真实根、app=jbroot 视图）
- **Siri 集成在 SpringBoard 进程**（tweak 内），app 进程的 Swift 服务不参与

---

## 3. 组件运行原理

### 3.1 tweak（operit-sb.x，SpringBoard 进程）
- **注入**：TweakInject 按 operit-sb.plist 的 Bundles=com.apple.springboard 注入
- **通知拦截 + 记录**：hook `BBObserver._queue_updateBulletin:withReply:`（拦截：命中 app_lock/notif_block 名单 → return 丢弃）+ `updateBulletin:withReply:`（记录：取 bulletin.title/message/body + sectionID → notifications.json，去重，50 条）
  - iOS 16 参数结构：`txn.bulletinUpdate.bulletin`（三层），sectionID 从 bulletin 取
- **锁屏会话**：`notify_register_dispatch("com.apple.springboard.lockstate")` → `notify_get_state` → usage.json 的 sessions 数组
- **应用锁**：前台检测 + `app_lock.plist` 名单（`{bid: {title,subtitle,button}}`）→ 命中弹自定义屏蔽页
- **剪贴板监听**：`clipboard_enabled` 文件开关（默认关，隐私）
- **Siri 集成（v14）**：hook `AFConnection._tellSpeechDelegateSpeechRecognized:`（识别文本，`SASSpeechRecognized.af_bestTextInterpretation`）→ 写 operit2 会话 → 拼 system prompt（角色卡+USER.md+历史）→ DeepSeek → 写回会话 → `AFUISiriViewController.viewDidAppear` 存实例 → **addSubview 自绘卡片**（占位"思考中…"→更新，底部圆角，关闭按钮）
- **socket 命令**（unix socket operit.sock，行协议）：`ping` / `front` / `home` / `tap <x> <y>` / `swipe` / `type <text>` / `longpress` / `launch <bid>`（⚠️ 崩 SpringBoard，禁用）/ `screenshot` / `applock <bid>|<title>|<subtitle>|<button>` / `appunlock` / `applock_list` / `notif_clear <bid>` / `ai` / `user` / `sender` / `assistant`
- **配置**：`operit_cfg_bool(key, default)` 读 NSUserDefaults 域 com.operit（设置面板总开关），与文件机制并存

### 3.2 daemon（operit_agent_daemon.rs，root 由 LaunchDaemon 拉起）
- 端口 TCP 127.0.0.1:8890，行协议
- 命令：`stop`（停）、`goal <文本>`（设定 AI 目标，启动 VLM 循环）、`config <key>|<provider>|<base>|<model>`（缓存 AI 凭证，优先于 config.plist）
- 由 LaunchDaemon `ai.operit.agent` 管理（RunAtLoad + KeepAlive，mobile 用户）
- **签名要求**：daemon 二进制必须 ldid 签名且 cdhash 注册进 Dopamine trustcache（否则 SIGKILL -9 / launchd ExitCode 9）——postinst 负责装机时重签+注册

### 3.3 Swift 本地服务（Runner.app 进程，AppDelegate 启动）
| 服务 | 端口 | 协议 | 能力 |
|---|---|---|---|
| ScreenTimeServer | 8891 | 行文本 | `lock <bid>[|<title>|<subtitle>|<button>]`（写 tweak 名单，**任意 app 可锁**，无需 picker）/ `unlock` / `status` / monitor start-stop / usage |
| ShortcutsServer | 8892 | 行文本 | `run <名称>`（shortcuts://run-shortcut URL scheme）|
| NotifyServer | 8893 | 行文本 | AI 主动发通知/灵动岛给用户 |
| OpenURLServer | 8894 | 行文本 | `open_url <url>` / `installed_apps` / `tcc <cmd>`（转发 8895）|
| TCCServer | 8895 | 行文本 JSON | `contacts list/search` / `calendar list/create` / `reminders list/create` / `photos recent/save` / `health steps/hrt` / `location get` |
- 全部走系统公开 API（EventKit/Contacts/Photos/HealthKit/CoreLocation），TCC 授权弹窗，失败降级不崩（responds 前置探测，**禁用裸 value(forKey:)**——iOS 16 不存在的 key 抛 NSException → SIGABRT）

### 3.4 TS 工具（buildin/*.ts，AI 可用工具）
- **device_automation.ts**：设备自动化主工具（连 daemon → ios-mcp）
- **system_io.ts**：9 工具（contacts_read / calendar_list / calendar_create / reminders_list / reminders_create / photos_recent / photos_save / health_read / location_get）→ 走 Tools.Net.openUrl 通道（`tcc ` 前缀 → 8894 → 8895）
- **screen_time.ts**：screen_time_authorize / screen_time_lock / screen_time_unlock / screen_time_monitor_start / screen_time_monitor_stop / screen_time_usage（**已删 screen_time_pick**——AI 直接锁任意 app）
- **super_admin.ts**：终端/文件/进程（⚠️ terminal 工具缺 sessionId 入口，见 9.4）
- **open_url.ts**：深链手册（⚠️ 大部分未实测，weixin://dl/* 全无效）
- **notify.ts / shortcuts.ts / browser.ts / operit_editor.ts / extended_chat.ts / extended_memory_tools.ts**

### 3.5 启动链路（开机 → 可用）
1. LaunchDaemon 拉起 daemon（8890 监听）
2. SpringBoard 启动，TweakInject 注入 operit-sb.dylib（通知/锁屏/应用锁/Siri 就位）
3. 用户打开 Runner.app → AppDelegate 启动 5 个 Swift 服务（8891-8895）
4. 主机侧 MCP 连 ios-mcp（8090）→ AI 可用全部能力

---

## 4. 数据文件（/var/mobile/.operit/ 下，真实根）
| 文件 | 用途 | 读写方 |
|---|---|---|
| config.plist | AI 凭证（apiKey/apiBaseUrl/apiModel）| app 写，daemon 缓存优先 |
| app_lock.plist | 应用锁名单 `{bid:{title,subtitle,button}}` | Swift ScreenTimeServer 写，tweak 读 |
| notif_block.plist | 通知拦截名单 `{bid:{ts}}` | Swift NotifyServer 写，tweak 读 |
| notifications.json | 通知记录（bid/title/body/ts，50 条，新在前）| tweak 写，AI 读 |
| usage.json | 前台/锁屏会话统计（history/sessions/active）| tweak 写 |
| logs/tweak.log | tweak 运行日志 | tweak 写，SSH 排查 |
| operit2/runtime/data/ | operit2 app 数据（database/operit2.sqlite 会话库、memory/characters/<id>/USER.md、preferences/character_cards.preferences.json）| app + Siri 集成 |
| operit2/runtime/state/current_chat_id.preferences.json | 当前会话 id | Siri 集成读 |

**⚠️ 目录属主必须是 mobile:mobile**（root:mobile 曾导致 app 白屏）。

---

## 5. 构建与打包（维护者必读）

### 5.1 CI（GitHub Actions）
- workflow：`.github/workflows/ios-flutter-build.yml`
- **无 on: push**，只能手动 dispatch，**分支必须手动选 `feat/ios-jailbreak-preview4`**（默认编 main）
- 产物：UNSIGNED Runner.app（artifact `operit2-app-ios-arm64.zip`）
- **新增 iOS .swift 文件必须注册进 project.pbxproj 4 处**（PBXBuildFile/PBXFileReference/group children/Sources phase），否则 CI 报 `Cannot find XXX in scope`（本机 swiftc typecheck 单文件通过不代表进工程！）

### 5.2 本地打包（Mac）——**必须用 build_deb.sh，不要单独跑 packdeb.py**

```bash
# 0. 前置①：daemon 必须先编译（build_deb.sh 找不到 release 产物直接报错退出）
cd hosts/ios && cargo build --target aarch64-apple-ios --release
# 1. 前置②：tweak 必须先编译（build_deb.sh 从 .theos 复制 dylib）
cd hosts/ios/tweak && make clean && make   # 产出必须是 FAT（arm64+arm64e）——A12+ 设备是 arm64e，arm64-only 注入会崩
# 2. 前置③：CC 模块签名（build_deb.sh 不处理 ccmodule）
cd hosts/ios/ccmodule && make clean && make && ldid -S .theos/obj/debug/OperitCC.bundle/OperitCC
cp .theos/obj/debug/OperitCC.bundle/OperitCC ../deb/files/Library/CCSupport/OperitCC.bundle/
# 3. 升版本（build_deb.sh 从 control 的 Version 自动生成 deb/ipa 文件名）
sed -i '' 's/^Version: .*/Version: 0.3.71/' deb/DEBIAN/control
# 4. 打包（build_deb.sh 自动完成全部 staging：daemon 预签 + entitlements + 两个 dylib/plist +
#    app 重签 + 3 个 app extension 嵌入签名 + IPA 生成 + ar 打包）
cd hosts/ios/deb && OPERIT_PACK_SCHEME=rootless APP_SRC="/Users/mac/Downloads/<CI新包>.app" bash build_deb.sh
```

- **⚠️ 为什么不能单独跑 `python3 packdeb.py`**：packdeb.py 只做最后的 ar 打包，**不做 staging**——daemon 复制+预签、entitlements 复制、operit-sb/operit-app 两个 dylib+plist 复制、app 重签、3 个 app extension（ScreenTimeMonitor/LiveActivityWidget/OperitShieldConfig）嵌入签名、IPA 生成，全在 build_deb.sh 里。单独跑会打出**缺 daemon/缺 app/缺 extension 的残废包**。只有 files/ 已被 build_deb.sh 完整 staging 过、且只改了 files/ 里的文件时，才可跳过 build_deb.sh 直接 packdeb.py
- **rootless**：data 带 var/jb/ 前缀，Architecture `iphoneos-arm64`；**roothide**：裸布局，Architecture **必须 `iphoneos-arm64e`**（Sileo 识别唯一判据）；roothide 走 build_deb.sh 自动换 Runner.roothide.entitlements（platform-application 等 4 项）
- **绝不用 `dpkg --root=/var/jb`**（会双前缀），用 `sudo dpkg -i` / Sileo
- 依赖：com.witchan.ios-mcp, preferenceloader, com.opa334.ccsupport（rootless 还建议 AppSync Unified）
- daemon 预签 + postinst 装机时 ldid 重签 + trustcache 注册（关键，否则 -9）
- 本机**无法** `flutter build ios`（缺 Python xcframework），全量编译只能靠 CI：先手动 dispatch ios-flutter-build 选分支 → 下载 UNSIGNED Runner.app 到 Downloads → 打包时用 APP_SRC 指向它

### 5.3 装机（SSH）
```bash
scp operit2-ios_X_iphoneos-arm64.deb mobile@<ip>:/tmp/
echo '<PASSWORD>' | sudo -S dpkg -i /tmp/operit2-ios_X_iphoneos-arm64.deb
echo '<PASSWORD>' | sudo -S killall -9 SpringBoard   # respring
```
设备 SSH：mobile@192.168.1.xx <密码，安装时向设备所有者询问>（IP 可能因 DHCP 变动）

---

## 6. 功能清单（按稳定度）

### ✅ 真机验证过（稳定）
- Siri 集成 v14（识别 → 会话同步 → 角色记忆一致回答 → 底部卡片显示）
- 通知拦截 + 内容记录（BBObserver → notifications.json）
- 锁屏会话（Darwin notify → usage.json sessions）
- 应用锁（tweak 前台拦截，任意 app，自定义屏蔽页）
- 深链唤起（微信裸 scheme、支付宝全系；weixin://dl/* 全废）
- 屏幕使用时间授权 + 锁应用（0.3.70 起无需选应用）
- 吃醋巡检（DeviceActivityMonitor）+ 快捷指令接入

### 🟡 已 push 未端到端验证
- 权限全家桶（TCCServer 8895 + system_io 9 工具 + HealthKit）
- 设置面板（PreferenceLoader operitPrefs.bundle）——**用户实测未显示**（见 9.6）
- 控制中心模块（OperitCC）——**用户实测未显示**（见 9.1）
- installed_apps 修复（responds 探测）

### ⏳ POC 暂时无法验证（欢迎大佬挑战）
- Siri 气泡文本替换（SAUIAssistantUtteranceView.text 可改但跨进程不刷新）——POC 阶段未找到刷新方法，不代表无解
- Siri TTS 朗读（AFUISiriSession.speechSynthesis getter iOS 16.7 不存在）
- 手动 method_setImplementation + 延迟原调（野指针崩 SpringBoard 进安全模式）——**禁止**
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
                 （参数 BBBulletinUpdateTransaction 三层：txn.bulletinUpdate.bulletin，sectionID 从 bulletin 取）
通知 UI 层     → NCNotificationListViewController* / SBDashBoard*（分组/美化用）
锁屏检测       → Darwin 通知 com.apple.springboard.lockstate（notify_get_state）
                （SBLockScreenManager isLocked KVC iOS 16 失效）
权限数据       → 系统公开 API（EventKit/Contacts/Photos/HealthKit/CoreLocation）+ TCC 授权
```

---

## 8. 已知遗留问题（2026-08-11 用户实测）

### 8.1 控制中心模块（OperitCC）不显示 🔴
- OperitCC.bundle 正确安装 + com.opa334.ccsupport 1.3.13-2 已装 + respring + **ldid 签名**（0.3.69 起），但控制中心"更多控件"没有 OperitCC（SiriPlus CC 模块正常）
- 疑似 CCSupport 1.3.13 模块验证逻辑（NSPrincipalClass/Info.plist 键/方法签名）不符；CCSupport 闭源
- **研究方向**：对照 SiriPlus CC bundle / M4cs EzCC-Modules 的 Info.plist 键 + 类实现；确认 `_CCModuleSizePROTOTYPE` 是否为 1.3.13 认可键（可能需 `_CCModuleSize`）；或 分析 CCSupport 加载机制（参考已有实现）；备选：tweak 直接注入 ControlCenter 模块

### 8.2 设置-背景选图崩溃 🔴
- `Invalid argument(s): XTypeGroup ... should either allow all files, or have a non-empty 'uniformTypeIdentifiers'`（file_selector_ios.dart:69）
- 位置：AppearanceSettingsPanel._pickBackgroundImage（apps/flutter/app/lib/features/settings/appearance/AppearanceSettingsPanel.dart ~613）
- **修法**：XTypeGroup 加 `uniformTypeIdentifiers: ['public.image']` / `['public.movie']`，或 allowAll=true；iOS 备选 ios_path_picker.dart 的 promptPathInput() 兜底

### 8.3 super_admin 终端工具缺 sessionId 入口 🔴
- input/get_screen/terminal_wait 都要 sessionId，但 AI 无"列出会话"入口
- **修法**：super_admin 增加 list_terminal_sessions / create_terminal_session（core/crates/operit-tools/src/tools/defaultTool/standard/super_admin.rs）

### 8.4 app 手动拨蜜终端 PATH 不全 🔴
- `uname: not found`（/var/jb/usr/bin/sh: 8）
- **修法**：启动前 export 完整 PATH（含 /usr/bin、/var/jb/usr/bin 等）；位置 apps/flutter/app/lib/ui/features/manual_terminal/

### 8.5 screen_time picker 取消语义误判（已删选应用步骤，见 6）
### 8.6 设置面板未显示 🟡
- operitPrefs.bundle 结构/依赖/路径均验证正确，但设置 App 无 Operit2 条目；需查 preferenceloader 2.2.8 加载（对照其他第三方面板是否显示）；参考 8.1 的对照研究方法

---

## 9. 方法论（沉淀于技能 jailbreak-ios-dev / roothide-ios-dev）

1. **参考实现优先**：目标功能有同类插件 → 研究已有实现是最高效路径（SiriPlus/Axon/Senri 三连验证）。strings 查字符串（strip 后 selector 仍在 __cstring 段）、otool -ov 看 ObjC 类
2. **hook 层选择**：连接层 > UI 层（AFConnection > AFUISiriSession）
3. **证据 > 推理**：真机日志/SSH 取证是第一手事实，别先读源码猜
4. **roothide 双视图**：/var/jb 污染不可信；跨视图通信用 TCP loopback
5. **iOS 16.7 私有 API**：社区头文件（nst）只到 iOS 14，方法名/参数以真机 probe 为准
6. **KVC 安全**：裸 value(forKey:) 对不存在的 key 抛 NSException（do-catch 抓不住）→ SIGABRT；一律 responds(to:) 前置 + perform

---

## 10. 交接状态
- [x] 代码已 push（feat/ios-jailbreak-preview4，10 commit，含 Siri 集成/权限全家桶/设置面板/控制中心/通知/锁屏/CI 修复/签名修复/文档）
- [x] 交接文档（本文件）
- [ ] 遗留 8.1-8.6 待后续开发者
- [ ] 可选探索：AI 回复通知（BBServer action 回调 probe；AutoResponder 是 iOS 6-9 短信层先例）

### 8.7 roothide 版整体未验证 🔴🔴（最高优先级）
- **0.3.54 之后的所有版本（含 0.3.70）只在 Dopamine rootless 主测试机实测过，roothide deb 从未真机验证**
- 具体风险（均为历史坑 + 未在最新版复核）：
  1. postinst 重签/信任链（roothide 的 jbroot 签名机制 vs rootless 的 Dopamine trustcache；历史 ldid 路径坑 /usr/local/bin vs /usr/bin）
  2. 双视图数据目录（app=jbroot 视图、daemon=真实根视图；.operit 属主、Siri 写 operit2.sqlite 的物理一致性）
  3. detect_jailbreak 最新版在 roothide 实测
  4. 设置面板/CC 模块在 roothide 的 jbroot 布局加载路径（无 /var/jb 前缀）
  5. Siri AFConnection hook 在 roothide SpringBoard 是否触发
- **交接者若有 roothide 设备，第一件事就是装最新 roothide deb 全量回归**（Siri/通知/锁屏/权限/设置面板/CC）

### 8.8 IPA 阉割版（nonjb / TrollStore / 自签）整体不可用 🔴
- **本质**：nonjb 打包用 Runner-nonjb.entitlements（剥离 no-sandbox + container-required=false）→ app 落标准沙盒（data_root=$HOME/Documents/.operit），无 AppSync/amfid patch
- **缺失的深度能力**（全部依赖越狱环境，nonjb 全无）：
  1. tweak（operit-sb.dylib）不注入 → 通知拦截/记录、锁屏会话、应用锁、**Siri 集成全失效**
  2. LaunchDaemon 不生效 → daemon 起不来 → 设备自动化（AI 操作手机）全失效
  3. ios-mcp（com.witchan.ios-mcp）不装 → 设备操作无通道
  4. 无完整权限（沙盒内）→ 部分 TCC 公开 API 可用但受容器限制
- **nonjb 只剩**：AI 聊天 + app 手动打开时 Swift 服务（8891-8895）的部分能力（且 app 挂起即断）
- **验证状态**：仅历史打包过（从未装机功能验证）；**不要对 nonjb 版有任何功能预期**

---

## 9. AI 接手快速启动指南（30 分钟上手）

> 以下命令全部可直接复制执行。假设接手方是 AI 开发者。

### 9.1 环境准备
```bash
# 仓库
git clone git@github.com:ddddddedcds/Operit2.git -b feat/ios-jailbreak-preview4
# 本机 Theos（编 tweak/CC 模块）已就绪；Xcode + iOS 16 SDK（swiftc typecheck 用）
# 设备：Dopamine rootless iOS 16.7，SSH mobile@192.168.1.xx <密码，安装时向设备所有者询问>（IP 可能变）
```

### 9.2 本机验证（不碰设备）
```bash
# tweak 编译（10 秒，验证 C/ObjC 改动）
cd hosts/ios/tweak && make clean && make   # 产物 .theos/obj/debug/operit-sb.dylib

# CC 模块编译 + 签名（⚠️ 必须手动 ldid，Makefile 的 CODESIGN_FLAGS 无效）
cd hosts/ios/ccmodule && make clean && make && ldid -S .theos/obj/debug/OperitCC.bundle/OperitCC

# Swift typecheck（改 Runner/*.swift 后必跑）
cd apps/flutter/app/ios/Runner && \
  xcrun swiftc -typecheck -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" -target arm64-apple-ios16.0 <改动的文件>.swift AppLockUI.swift

# TS 工具 typecheck（改 buildin/*.ts 后）
cd plugins/packages/buildin && \
  NODE_PATH=/Users/mac/.workbuddy/binaries/node/workspace/node_modules \
  /Users/mac/.workbuddy/binaries/node/workspace/node_modules/.bin/tsc --noEmit --skipLibCheck --lib es2015 <文件>.ts

# Rust daemon 编译（改 hosts/ios/src 后）
cd hosts/ios && cargo build --target aarch64-apple-ios --release 2>&1 | tail -5
```

### 9.3 打包 + 装机（改完 → 验证闭环）
```bash
# 0. 前置①：CI 出 UNSIGNED Runner.app（手动 dispatch ios-flutter-build 选分支 → 下载到 Downloads）
# 0. 前置②：daemon 已编译（cargo build --target aarch64-apple-ios --release，见 9.2）
# 0. 前置③：tweak 已编译（make，见 9.2）

# 1. 签名 CC 模块 + 放入 deb（build_deb.sh 不处理 ccmodule）
cd hosts/ios
ldid -S ccmodule/.theos/obj/debug/OperitCC.bundle/OperitCC
cp ccmodule/.theos/obj/debug/OperitCC.bundle/OperitCC deb/files/Library/CCSupport/OperitCC.bundle/

# 2. 升版本号（Sileo 同版本不重装）
sed -i '' 's/^Version: .*/Version: 0.3.71/' deb/DEBIAN/control

# 3. 打包 rootless deb —— ⚠️ 必须 build_deb.sh（自动 staging daemon/app/extension/签名），
#    不要单独跑 packdeb.py（那只会 ar 打包，会打出缺 daemon/缺 app 的残废包）
cd deb && OPERIT_PACK_SCHEME=rootless APP_SRC="/Users/mac/Downloads/<CI新包>.app" bash build_deb.sh

# 4. 装机 + respring
scp operit2-ios_0.3.71_iphoneos-arm64.deb mobile@192.168.1.xx:/tmp/
ssh mobile@192.168.1.xx 'echo <PASSWORD> | sudo -S dpkg -i /tmp/operit2-ios_0.3.71_iphoneos-arm64.deb'
ssh mobile@192.168.1.xx 'echo <PASSWORD> | sudo -S killall -9 SpringBoard'
```

### 9.4 设备调试（SSH，不改代码）
```bash
# 看 tweak 日志（一切运行时行为的头号证据）
ssh mobile@192.168.1.xx 'tail -50 /var/jb/var/mobile/.operit/logs/tweak.log'
# panic 日志（app 崩）
ssh mobile@192.168.1.xx 'cat /var/mobile/.operit_panic.log 2>/dev/null | tail -20'
# daemon 状态
ssh mobile@192.168.1.xx 'ps aux | grep operit_agent; ls -la /var/jb/var/mobile/.operit/agent.log'
# 设备操作（深链/前台/拉起 app，首选通道——不崩 SpringBoard）
curl -s http://127.0.0.1:8090/mcp -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"open_url","arguments":{"url":"weixin://"}}}'
```

### 9.5 探路方法论（新功能怎么下手）
1. **有同类插件 → 研究其实现**：拉 dylib → `strings`（strip 后 selector 仍在）+ `otool -ov`（ObjC 类）→ 提取 hook 目标 → 查头文件 → 真机 probe（加日志 hook 候选方法验证触发）
2. **hook 层选连接层**：UI 层方法"存在但不触发"时，找连接层（如 Siri：AFUISiriSession → AFConnection）
3. **probe 先行**：不写死功能，先加无副作用日志 hook 确认触发和参数结构，再实现

---

## 10. 已知 bug 的可执行修法（代码级，给接手 AI）

### 10.1 CCSupport 模块不显示（8.1）
- 第一步（5 分钟）：对照 SiriPlus 的 CC bundle（设备上 `/var/jb/Library/CCSupport/*.bundle/Info.plist`）逐键 diff 我们的 Info.plist
- 第二步：若键差异 → 改 hosts/ios/ccmodule/Info.plist + operit_cc.m 对齐
- 第三步：若键相同 → CCSupport 可能拒绝非其签名模块；分析 CCSupport 的模块加载机制（对照已有实现）
- 验证：`ldid -S` 重签 → 重打包 → 装机 → respring → 控制中心编辑看"更多控件"

### 10.2 背景选图崩溃（8.2）
- 文件：apps/flutter/app/lib/features/settings/appearance/AppearanceSettingsPanel.dart（约 613 行 `_pickBackgroundImage`）
- 改法：openFile 的 `XTypeGroup(label: ..., extensions: ...)` 改为带 uti：
  ```dart
  XTypeGroup(label: 'image', uniformTypeIdentifiers: ['public.image'], extensions: ['jpg','jpeg','png','heic'])
  ```
  （视频同理用 ['public.movie']）
- 验证：编译（CI）→ 装机 → 设置→外观→背景→选图不崩

### 10.3 super_admin 终端缺 sessionId（8.3）
- 文件：core/crates/operit-tools/src/tools/defaultTool/standard/super_admin.rs
- 改法：terminal 工具组加 `list_terminal_sessions`（读 daemon 会话列表，daemon 在 hosts/ios/src/bin/operit_agent_daemon.rs 维护 session map）或 `create_terminal_session`（自动建会话返回 id）
- 验证：本地 cargo 编译 + 真机 AI 调 terminal 不再要用户手填 sessionId

### 10.4 手动拨蜜终端 PATH 不全（8.4）
- 文件：apps/flutter/app/lib/ui/features/manual_terminal/（终端实现）
- 改法：spawn shell 前注入环境：
  ```dart
  environment: {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/usr/local/bin'}
  ```
- 验证：装机后终端输入 `uname` 不报 not found

### 10.5 设置面板未显示（8.6）
- 与 10.1 同法：先对照设备上正常工作的第三方面板（如 SiriPlus 的 Prefs bundle）的 Info.plist 键集合 diff
- 确认 preferenceloader 是否整体工作：设置里有无其他第三方面板；无 → 查 preferenceloader 本身；有 → 查我们的 bundle

### 10.6 roothide 全量回归（8.7）
- 打包 roothide deb：`OPERIT_PACK_SCHEME=roothide bash build_deb.sh`（Architecture 自动 iphoneos-arm64e；不要单独跑 packdeb.py）
- 装 roothide 设备 → 逐项回归：daemon 起（ps）、通知拦截、锁屏 sessions、Siri（说一句看卡片）、权限（contacts list）、设置面板、CC 模块
- 任何一步挂 → 按 8.7 的 5 个风险点逐个排查

---

## 11. 交接状态（最终）

- **接续方已明确**：operit2 官方（有意愿、有能力接续越狱版；当前因非越狱版排期忙不过来，越狱版**暂存待取**——官方有余力时，按本手册可直接续上）
- **本 POC 定位**：探明"越狱 iOS + AI 深度集成"可行性 + 交付完整交接手册；不是可产品化代码，是"暂存待取"的知识+代码封存
- **官方可吸收**：功能清单（第 6 节）+ 合规子集（TCCServer 的公开 API 部分可直接复用）+ 方法论（第 9/12 节）
- [x] 代码：feat/ios-jailbreak-preview4（11 commit）——Siri v14 / 权限全家桶 / 设置面板 / CC 模块 / 通知拦截记录 / 锁屏 / 应用锁 / screen_time 简化 / CI 修复 / 签名修复 / 文档
- [x] 文档：本 HANDOVER.md（10 节工程手册 + 本 AI 指南）
- [x] 方法论：jailbreak-ios-dev / roothide-ios-dev 技能
- [ ] 遗留 bug：10.1-10.6（CC 模块 / 选图崩溃 / sessionId / PATH / 设置面板 / roothide 回归）
- [ ] 可探索：AI 回复通知（BBServer action 回调；AutoResponder 是 iOS 6-9 短信层先例）

---

## 12. 私有 API 专题（本项目方法论核心，官方/越狱开发者/AI 通用）

### 12.1 本项目用到的私有 API 全景（实测，iOS 16.7）

| 领域 | 框架/类 | 方法/API | 用途 | 可靠性 |
|---|---|---|---|---|
| Siri 识别 | AssistantServices `AFConnection` | `_tellSpeechDelegateSpeechRecognized:` | 拿 Siri 语音识别文本（arg 为 SASSpeechRecognized）| ✅ 稳定触发 |
| Siri 回答 | AssistantServices `AFConnection` | `_handleCommand:reply:` | 拦截 Siri 回答命令（SAUIAddViews）| ✅ 稳定触发 |
| Siri 文本提取 | SAObjects `SASSpeechRecognized` | `af_bestTextInterpretation` | 识别文本最佳结果 | ✅ |
| Siri 视图宿主 | AssistantUI `AFUISiriViewController` | `viewDidAppear:` / viewWillDisappear: | 挂自绘回答卡片 | ✅ |
| 通知拦截/记录 | BulletinBoard `BBObserver` | `_queue_updateBulletin:withReply:` / `updateBulletin:withReply:` | 通知源头拦截 + 内容读取 | ✅ |
| 通知参数结构 | BulletinBoard `BBBulletinUpdateTransaction` | `.bulletinUpdate.bulletin`（三层）| iOS 16 取 sectionID/title/message | ✅ 实测 |
| 通知历史清除 | BulletinBoard `BBObserver` | `clearSection:` | 锁定 app 时清历史通知 | ✅ |
| 锁屏检测 | Darwin notify（非私有）| `com.apple.springboard.lockstate` + notify_get_state | 锁屏/解锁状态 | ✅ 官方通知 |
| 应用锁 | SpringBoard 前台检测 + 自绘屏蔽页 | tweak 内实现 | 拦截 app 前台 | ✅ |
| installed_apps | LSApplicationWorkspace（公开但部分 key 私有）| `defaultWorkspace` / `allApplications` | 枚举 app | ⚠️ `schemes` key iOS 16 不存在会崩 |
| 截图 | CARenderServer / SB 截图管理 | ios-mcp 内部 | 设备截图 | ⚠️ iOS 版本差异大 |

### 12.2 私有 API 发现方法（效率排序，均经本项目验证）

1. **参考实现优先**（最快）：目标功能有同类插件 → 拉 dylib → `strings`（Swift strip 后 selector 字符串仍在 __cstring 段）+ `otool -ov`（ObjC 类/方法）→ 直接得到"已验证的 hook 目标"
2. **社区公开头文件**：nst/iOS-Runtime-Headers（只到 iOS 14，方法名可能过时）、Theos SDK 自带 iPhoneOS*.sdk（有 .tbd 但头文件不全）
3. **运行时类清单**（objc_getClassList + class_copyMethodList）：设备 iOS 16.7 的活清单，含 Swift 类暴露的 ObjC 部分
4. **真机 probe**（最终裁决）：hook 候选方法 + 日志，验证"是否触发 + 参数实际结构"——**方法存在 ≠ 可靠 hook 点**（本项目最大教训）

### 12.3 私有 API 使用准则（防崩溃，全部血泪教训）

1. **KVC 安全**：裸 `value(forKey:)` 对不存在的 key 抛 NSException（Swift do-catch 抓不住）→ SIGABRT。一律 `responds(to:)` 前置 + `perform` 取值
2. **@try 保护**：所有私有 API 调用包 @try/@catch（NSException）
3. **hook 层选择**：连接层 > UI 层。UI 层方法"存在但不触发"时换连接层（Siri：AFUISiriSession → AFConnection 一次成功）
4. **禁用手动 swizzle**：`method_setImplementation` + `imp_implementationWithBlock` + 延迟原调 → 野指针崩 SpringBoard（进安全模式）。用 Logos `%hook` 同步 `%orig`
5. **probe 先行**：不写死功能，先加无副作用日志 hook 确认触发 + 参数结构，再实现
6. **强引用 + 主线程**：异步 block 里捕获的对象要 strong；UI 操作回主线程
7. **参数结构以真机实测为准**：社区头文件过时（iOS 16 的 BBBulletinUpdateTransaction 三层就是 probe 发现的）

### 12.4 iOS 16.7 私有 API 差异（实测清单，对比社区头文件）

| 差异 | 社区头文件（iOS 14）| iOS 16.7 实测 |
|---|---|---|
| Siri 回答 hook | 用 AFUISiriSession（UI 层）| **AFConnection（连接层）才触发** |
| Siri TTS | `speechSynthesis` getter | **不存在**（unrecognized selector）|
| Siri 气泡 | 改 `SAUIAssistantUtteranceView.text` | 可改但**跨进程（SiriViewService）不刷新** |
| 锁屏 KVC | SBLockScreenManager.isLocked | **失效** → 用 Darwin notify |
| 通知参数 | 传 BBBulletin | **BBBulletinUpdateTransaction（三层）** |
| installed_apps | `schemes` key 可用 | **key 不存在 → 裸 KVC 崩** |
| 截图 | SBScreenshotManager 多方法 | iOS 15.7 实测只有 `saveScreenshotsWithCompletion:` |

### 12.5 稳定性风险（给官方/维护者的评估）

- **每个 iOS 小版本都可能变**：本项目 21 天里至少 5 处被 iOS 16.7 打脸（上表全是）
- **iOS 16 vs 17 差异更大**：私有框架改名/重构频繁，17 的 Siri/通知层可能与 16 完全不同
- **参考实现是"版本适配活教材"**：SiriPlus（Siri）/ Axon+Senri（通知）的每个版本更新都在教你该版本的私有 API 正确用法
- **非越狱无私有 API**：App Store 分发不能用（会被拒）；越狱分发（Sileo/自签）无此限制
- **合规**：本项目为学习研究用途；如产品化需自行评估法律/政策风险

### 12.6 私有 API 知识来源汇总（速查）
| 来源 | 用途 | 时效 |
|---|---|---|
| 设备上的同类插件 dylib | strings/otool 分析 | 当前版本 |
| nst/iOS-Runtime-Headers（GitHub）| 公开头文件 | iOS 14 左右，过时 |
| Theos SDK iPhoneOS*.sdk | .tbd + 部分头 | 本机 16.5 |
| theapplewiki | 固件/文件系统结构 | 持续更新（类方法仍需提取）|
| 设备运行时类枚举 | 活类清单 | 设备当前系统 |
| 真机 probe（自己加日志）| 最终裁决 | 永远有效 |

---

## 13. 依赖插件清单（operit2 deb 完整依赖，2026-08-11 实测版本）

### 13.1 control 声明依赖（Sileo 自动安装）
| 包 | 实测版本 | 用途 | 缺失后果 |
|---|---|---|---|
| **com.witchan.ios-mcp** | 1.2.3 | 设备自动化后端（127.0.0.1:8090），AI 操作手机的核心通道 | 设备自动化全失效 |
| **preferenceloader** | 2.2.8 | 设置面板（operitPrefs.bundle）加载框架 | 设置里无 Operit2 条目 |
| **com.opa334.ccsupport** | 1.3.13-2 | 控制中心模块（OperitCC）加载框架 | 控制中心无 AI 模块 |

### 13.2 实际运行需要（control 未声明，Dopamine/Procursus 通常自带，装机时确认）
| 包 | 用途 | 缺失后果 |
|---|---|---|
| **ellekit** | tweak 注入运行时（TweakInject 加载 operit-sb.dylib 必需）| tweak 不加载，所有越狱功能失效 |
| **AppSync Unified** | 安装 adhoc 签名 app（rootless 打包的 Runner.app 是 `codesign --sign -` 签名）| app 可能无法安装/启动 |
| **ldid**（工具，非插件）| postinst 装机时重签 daemon + 注册 trustcache | daemon 被 AMFI 拒载（-9 / ExitCode 9）|

### 13.3 roothide 差异
- 不需要 AppSync Unified（roothide 用 ldid 签名机制，无 AppSync/amfid patch）
- ellekit 同样需要（roothide 也用 TweakInject 体系）
- ldid 路径：Procursus 装 /usr/bin/ldid，部分工具链装 /usr/local/bin/ldid（postinst 已做双路径探测）

### 13.4 第三方原作出处（control Description 已声明）
- Operit2 原作：github.com/AAswordman/Operit2（改编，非官方分支）
- ios-mcp：github.com/witchan/ios-mcp（本 fork 用适配版：github.com/ddddddedcds/ios-mcp）
