# Operit2 越狱 iOS 移植 —— 交接者说明（HANDOVER）

> **这是什么**：本项目把 Operit2（Flutter+Rust 跨平台 AI 助手）移植到越狱 iOS，并验证了"越狱 iOS + AI 深度集成"这条路的可行性（Siri 语音入口、系统能力调用、设备自动化、会话同步）。原开发者已完成探路，现将全部成果、架构、坑交接给后续维护者。
>
> **目标平台**：Dopamine rootless（iOS 16.7，主测试机 iPhone13,4） + roothide；非越狱（TrollStore/自签 IPA 降级支持）
> **主分支**：`feat/ios-jailbreak-preview4`

---

## 1. 代码结构速览

```
hosts/ios/
├── tweak/operit-sb.x        # 核心 tweak（SpringBoard 注入）：通知拦截/记录、锁屏会话、应用锁、剪贴板、Siri 集成
├── tweak/operit-siri 段      # Siri 集成（同文件内）：AFConnection hook + 卡片显示 + 会话同步
├── ccmodule/                # 控制中心 AI 按钮（CCSupport 模块 OperitCC）
├── deb/                     # 打包目录（build_deb.sh / packdeb.py / entitlements / PreferenceLoader bundle）
└── src/bin/operit_agent_daemon.rs  # 设备自动化 daemon（VLM 循环，TCP 8890）

apps/flutter/app/ios/Runner/
├── AppDelegate.swift        # 启动所有本地服务
├── OpenURLServer.swift      # TCP 8894：open_url / installed_apps / tcc 转发
├── TCCServer.swift          # TCP 8895：通讯录/日历/提醒/照片/健康/定位（权限全家桶）
├── NotifyServer.swift / ScreenTimeServer.swift / ShortcutsServer.swift / AppLockUI.swift

plugins/packages/buildin/
├── open_url.ts              # 深链工具（⚠️ 手册大部分未实测，AI 用前先验证）
├── system_io.ts             # 权限全家桶 9 工具（contacts/calendar/reminders/photos/health/location）
```

## 2. 进程与端口架构

| 组件 | 端口/通道 | 职责 |
|---|---|---|
| ios-mcp（独立） | 127.0.0.1:8090 JSON-RPC | 设备手：tap/swipe/type/screenshot/open_url/launch_app（**首选通道，独立于 app**）|
| operit_agent_daemon | TCP 127.0.0.1:8890 | AI 脑袋：VLM 循环，LaunchDaemon ai.operit.agent 拉起 |
| OpenURLServer | TCP 8894 | 深链 + installed_apps + tcc 转发（app 内）|
| TCCServer | TCP 8895 | 权限全家桶数据源（app 内）|
| tweak unix socket | operit.sock | 兜底（ios-mcp 是主力，别依赖 socket 的 launch 命令——会崩 SpringBoard）|

链路：`device_automation.ts` → `ToolRegistration` → daemon → ios-mcp → 设备。

## 3. 已实现功能清单（按稳定度）

### ✅ 真机验证过（稳定）
- **Siri 集成 v14**：Siri 语音 → 识别（AFConnection `_tellSpeechDelegateSpeechRecognized:`）→ 写入 operit2 会话 → 角色+记忆+历史一致回答 → 写回 → 底部卡片显示（占位"思考中…"→更新）
- **通知拦截 + 内容记录**：BBObserver `_queue_updateBulletin:`/`updateBulletin:`，拦截（锁定/黑名单 app）+ 记录到 `/var/mobile/.operit/notifications.json`（bid/title/body/ts，50 条，AI 可读）
- **锁屏会话**：Darwin 通知 `com.apple.springboard.lockstate`（notify_get_state）→ usage.json sessions
- **应用锁 / 剪贴板监听 / 前台感知**（文件 + NSUserDefaults 双开关）
- **深链唤起**：微信裸 scheme、支付宝全系（alipay://platformapi/startapp?appId=10000007/20000056/200011235）
- **屏幕使用时间 / 吃醋巡检 / 快捷指令接入**（iOS 16 FamilyControls/DeviceActivityMonitor）—— **锁应用主路径 = tweak 前台拦截（写 /var/mobile/.operit/app_lock.plist），任意 bundleId 直接可锁，无需 FamilyControls 授权/选应用**。`screen_time_pick`（选应用）已删除（2026-08-11 用户反馈 picker 流程卡"未锁定"；SSH 无崩溃证据，根因是 Swift lock 的 managedApps 名单检查 + picker 取消语义）；**若后续开发者要恢复"仅限用户 pick 过的 app"，在 ScreenTimeServer.swift lock() 恢复 managedApps() 检查 + 重新加回 screen_time_pick 工具即可**

### 🟡 已 push 未装机验证（等 CI 出包后验证）
- **权限全家桶**：TCCServer 8895（通讯录/日历/提醒/照片/健康/定位）+ system_io.ts 9 工具 + HealthKit entitlement
- **设置控制台**：PreferenceLoader 面板（operitPrefs.bundle，4 总开关：applock/notifBlock/clipboard/usage + siriEnabled）
- **控制中心 AI 按钮**：CCSupport OperitCC（AppLauncher 拉起 operit2）
- **installed_apps 修复**：responds 前置探测（iOS 16 裸 KVC 会 SIGABRT 崩 app）

### ❌ 探明不可行/放弃（别重复造轮子）
- Siri 气泡文本替换：`SAUIAssistantUtteranceView.text` 可改但 UI 跨进程（SiriViewService）不刷新 → 卡片方案已替代
- Siri TTS 朗读：`AFUISiriSession speechSynthesis` getter 在 iOS 16.7 不存在
- 手动 method_setImplementation + 延迟原调：野指针崩 SpringBoard（进安全模式）——**禁止用**，改 Logos %hook + 强引用
- weixin://dl/* 全部无效（微信 iOS 不响应 path）；open_url.ts 手册大部分未验证

## 4. 关键 hook 点地图（Siri/通知/权限，iOS 16.7 实测）

```
Siri 识别/回答  → AFConnection（AssistantServices 连接层，SpringBoard 进程）：
                 - _tellSpeechDelegateSpeechRecognized:（识别，SASSpeechRecognized.af_bestTextInterpretation 取文本）
                 - _handleCommand:reply:（SAUIAddViews = Siri 回答命令）
Siri 视图宿主   → AFUISiriViewController（viewDidAppear 存实例 → addSubview 自绘卡片）
通知记录/拦截   → BBObserver._queue_updateBulletin:withReply: / updateBulletin:withReply:
                 （iOS 16 参数是 BBBulletinUpdateTransaction 三层：txn.bulletinUpdate.bulletin，sectionID 从 bulletin 取）
通知 UI 层     → NCNotificationListViewController* / SBDashBoard*（分组/美化用）
锁屏检测       → notify Darwin 通知 com.apple.springboard.lockstate（不要用 SBLockScreenManager KVC，iOS 16 失效）
权限数据       → 系统公开 API（EventKit/Contacts/Photos/HealthKit/CoreLocation），TCC 授权弹窗
```

## 5. 构建与打包（维护者必读）

- **CI**：`ios-flutter-build` workflow **无 on: push**，只能手动 dispatch，**分支必须手动选 `feat/ios-jailbreak-preview4`**（默认编 main）
- CI 产 **UNSIGNED Runner.app**（artifact `operit2-app-ios-arm64.zip`）
- **本地打包**：换 `deb/files/Applications/Runner.app` → `codesign --force --deep --sign - --entitlements`（rootless 用 Runner.entitlements，roothide 用 Runner.roothide.entitlements）→ `OPERIT_PACK_SCHEME=rootless|roothide python3 packdeb.py`
  - rootless：deb 带 var/jb/ 前缀，Architecture: iphoneos-arm64
  - roothide：裸布局，Architecture **必须 iphoneos-arm64e**（Sileo 识别唯一判据）
  - 依赖：ellekit + com.witchan.ios-mcp + preferenceloader + com.omnitas.ccsupport
- **daemon 二进制也要重签**（否则 AMFI 拒载，launchd ExitCode 9，sock 永不建）
- **新增 iOS .swift 源文件必须注册进 project.pbxproj 4 处**（PBXBuildFile/PBXFileReference/group/Sources phase），否则 CI 报 Cannot find XXX in scope
- 本机无法 `flutter build ios`（缺 Python xcframework），全量编译只能靠 CI

## 6. 关键坑速查（全是真金白银踩出来的）

1. **越狱环境判定**：roothide 也存在 `/var/jb`（软链），**"裸 /var/jb 存在"不能判定 rootless**。权威信号：自身路径含 `/.jbroot-`（roothide）或 `/var/jb/usr/lib` 真实子树（rootless）。roothide 双文件系统视图：daemon=真实根、app=jbroot 视图，同一路径指向不同物理目录——**跨视图通信用 TCP loopback（127.0.0.1:8890），别用 unix socket**
2. **roothide 无 UUID 容器**：path_provider 的 getApplicationSupportDirectory 物理不可创建 → 启动抛异常白屏。data root 固定 `/var/mobile/.operit`，且**目录属主必须是 mobile:mobile**（root:mobile 曾导致白屏）
3. **daemon -9 根因**：cdhash 不在 Dopamine trustcache → 用最小 entitlements 重签
4. **tweak 的 launch 命令崩 SpringBoard（iOS 16.7）**：拉 app 回前台用 ios-mcp launch_app
5. **installed_apps/任何 KVC**：裸 value(forKey:) 对 iOS 16 不存在的 key 抛 NSException（do-catch 抓不住）→ SIGABRT。一律 responds(to:) 前置 + perform
6. **多次快速写 operit2.sqlite → Flutter ChatArea 崩溃**：写会话必须限频（≤3s/同 chat）
7. **Siri 集成改动用 Logos %hook 同步 %orig**，禁手动 swizzle + 延迟原调（野指针）
8. **iOS 16.7 私有 API 头文件**：社区 nst 头文件只到 iOS 14，方法名/参数对不上时以真机 probe 为准（加日志 hook 候选方法验证触发）

## 7. 交接状态

- [x] 代码已 push（feat/ios-jailbreak-preview4，6+ commit）
- [ ] **待办**：触发 CI（手动 dispatch 选分支）→ 出包 → 装机验证 🟡 三功能 + installed_apps + Siri 回归
- [ ] 可选：AI 回复通知（无公开先例，probe BBObserver action 回调摸底；AutoResponder 是 iOS 6-9 短信层先例）

## 8. 方法论（沉淀于开发者技能）

- **参考实现逆向优先**：目标功能有同类插件 → 逆向它是最高效路径（strings 扫 Swift dylib 的 selector、otool -ov 看 ObjC 类）
- **hook 层选择**：连接层 > UI 层（AFConnection > AFUISiriSession）
- **证据 > 推理**：真机日志/SSH 取证是第一手事实，别先读源码猜

## 9. 已知遗留问题（2026-08-11 用户实测，交接者必读）

### 9.1 控制中心模块（OperitCC）不显示——CCSupport 兼容性未解决 🔴
- 现象：OperitCC.bundle 已正确安装（/var/jb/Library/CCSupport/OperitCC.bundle）+ 依赖 com.opa334.ccsupport 1.3.13-2 已装 + respring 已做，但控制中心"更多控件"列表里**没有 OperitCC**（同期 SiriPlus 的 CC 模块正常显示）
- 已排除：bundle 路径/结构、依赖、respring、**二进制签名**（0.3.69 起已用 ldid -S 签名，`Identifier=OperitCC` 非 .unsigned）
- 未定位根因：疑似 CCSupport 1.3.13 对模块的**验证逻辑**（NSPrincipalClass 解析 / Info.plist 特定键 / 类方法签名）与我们实现不符；CCSupport 闭源无法直接确认
- **交接研究方向**：
  1. 对照已知正常工作的 CCSupport 模块（如 SiriPlus 的 CC bundle、M4cs/EzCC-Modules）的 Info.plist 键集合 + 类实现逐项对比
  2. 确认 `_CCModuleSizePROTOTYPE` 是否为 1.3.13 认可键（可能需 `_CCModuleSize`）
  3. 考虑 hook 或 dump CCSupport 的模块扫描逻辑（参考实现逆向优先方法论）
  4. 备选：放弃 CCSupport，用 tweak 直接注入 ControlCenter 模块（自研 CC 模块，不依赖 ccsupport）

### 9.2 设置-背景选择图片崩溃——file_selector XTypeGroup 缺 uniformTypeIdentifiers 🔴
- 现象：设置 → 外观与交互 → 背景 → 选择图片（选择视频）崩溃
- 错误：`Invalid argument(s): The provided type group instance of 'XTypeGroup' should either allow all files, or have a non-empty 'uniformTypeIdentifiers'`（FileSelectoriOS._allowedUtilListFromTypeGroups，file_selector_ios.dart:69）
- 位置：AppearanceSettingsPanel._pickBackgroundImage（apps/flutter/app/lib/features/settings/appearance/AppearanceSettingsPanel.dart 约 613 行）调 file_selector.openFile 时 XTypeGroup 未带 uniformTypeIdentifiers
- **修法**：给 XTypeGroup 加 `uniformTypeIdentifiers: ['public.image']`（图片）或 `['public.movie']`（视频），或 allowAll=true；iOS 备选路径用 ios_path_picker.dart 的 `promptPathInput()` 兜底
- 注意：这是 iOS 端 file_selector 行为变更（非越狱 app 也有此 bug），Flutter 包升级后需复核

### 9.3 其他实测反馈（历史，已修或已记录）
- screen_time picker 取消语义误判（0.3.68 → 已删选应用步骤，见第 3 节）
- installed_apps KVC 崩溃（已修，responds 前置探测）
- tweak launch 命令崩 SpringBoard（禁用，用 ios-mcp launch_app）

### 9.4 super_admin 终端工具缺 sessionId 入口
- 现象：AI 测试终端时反馈"input/get_screen/terminal_wait 都需要 sessionId，但我没有列出会话的入口"
- 根因：super_admin 工具包只有"对已知 sessionId 操作"的工具（input/get_screen/terminal_wait），**缺 list_sessions / create_session 类入口**；AI 无法自助获得一个可用 sessionId
- 修法方向：super_admin 工具层增加 list_terminal_sessions（读 daemon 持有的活跃会话列表）或 create_terminal_session（自动建一个空会话并返回 ID）
- 排查位置：core/crates/operit-tools/src/tools/defaultTool/standard/super_admin.rs（terminal 相关 register）

### 9.5 app 内"手动拨蜜"终端 PATH 不全（rootless）
- 现象：app 内 WebView 终端能开（sh$ 提示符），输入 `uname` 报错 `/var/jb/usr/bin/sh: 8: uname: not found`
- 根因：手动拨蜜终端启的 shell 环境 PATH 未包含 /usr/bin、/var/jb/usr/bin 等基础目录（与 0.3.66 修的 super_admin 终端是不同链路）
- 修法方向：手动拨蜜终端启动前显式 `export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/usr/local/bin:$PATH`，或写入 shell rc
- 排查位置：apps/flutter/app/lib/ui/features/manual_terminal/（手动拨蜜终端实现）
