# Operit2 越狱 iOS 移植 —— 完整交接手册（HANDOVER）

> **项目定位**：**POC（概念验证）**——验证"越狱 iOS + AI 深度集成"这条路是否可行。结论：**可行，但 Operit2 的 Flutter+Rust 架构硬移植进越狱 iOS 不划算（bug 链式暴露），接手前应先评估架构重做**。本手册记录全部架构、运行原理、坑与遗留问题，供 operit 官方 / 越狱社区开发者接手。
>
> **目标平台**：Dopamine rootless（iOS 16.7，主测试机 iPhone13,4 / A15）+ roothide；非越狱（TrollStore/自签 IPA 降级支持）
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

### 5.2 本地打包（Mac）
```bash
cd hosts/ios/deb
# 1. 替换 app（CI 新包）
# 2. 确保 dylib 最新：cp ../tweak/.theos/obj/debug/operit-sb.dylib files/Library/MobileSubstrate/DynamicLibraries/
# 3. 确保 OperitCC 已签名：ldid -S files/Library/CCSupport/OperitCC.bundle/OperitCC
# 4. 升版本：sed -i '' 's/^Version: X/Y/' DEBIAN/control
# 5. 打包：
OPERIT_PACK_SCHEME=rootless bash build_deb.sh   # 或直接 python3 packdeb.py
```
- **rootless**：data 带 var/jb/ 前缀，Architecture `iphoneos-arm64`；**roothide**：裸布局，Architecture **必须 `iphoneos-arm64e`**（Sileo 识别唯一判据）
- **绝不用 `dpkg --root=/var/jb`**（会双前缀），用 `sudo dpkg -i` / Sileo
- 依赖：com.witchan.ios-mcp, preferenceloader, com.opa334.ccsupport（rootless 还建议 AppSync Unified）
- daemon 预签 + postinst 装机时 ldid 重签 + trustcache 注册（关键，否则 -9）
- 本机**无法** `flutter build ios`（缺 Python xcframework），全量编译只能靠 CI

### 5.3 装机（SSH）
```bash
scp operit2-ios_X_iphoneos-arm64.deb mobile@<ip>:/tmp/
echo '1111' | sudo -S dpkg -i /tmp/operit2-ios_X_iphoneos-arm64.deb
echo '1111' | sudo -S killall -9 SpringBoard   # respring
```
设备 SSH：mobile@192.168.1.24 密码 1111（IP 可能因 DHCP 变动）

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

### ❌ 探明不可行 / 放弃
- Siri 气泡文本替换（SAUIAssistantUtteranceView.text 可改但跨进程不刷新）
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
- **研究方向**：对照 SiriPlus CC bundle / M4cs EzCC-Modules 的 Info.plist 键 + 类实现；确认 `_CCModuleSizePROTOTYPE` 是否为 1.3.13 认可键（可能需 `_CCModuleSize`）；或 dump CCSupport 扫描逻辑（参考实现逆向方法论）；备选：tweak 直接注入 ControlCenter 模块

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

1. **参考实现逆向优先**：目标功能有同类插件 → 逆向它是最高效路径（SiriPlus/Axon/Senri 三连验证）。strings 扫 Swift dylib（strip 后 selector 仍在 __cstring 段）、otool -ov 看 ObjC 类
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
