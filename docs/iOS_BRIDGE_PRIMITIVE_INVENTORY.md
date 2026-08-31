# iOS 桥层原语清单（M 个）—— AI 插件翻译目标词汇 + 桥层建设规格

> 状态：设计文档（纯调研，未改码、未 push）。所有可用性结论均来自对 `operit2-src/core/crates/operit-plugin-sdk/src/js_sdk/` 与 `runtime_bindings.rs` 的**代码核实**（2026-08-31），非记忆推断。
>
> 用途：
> 1. **AI 翻译目标词汇**——安卓插件里的 N 个 Android API 调用，统一映射到这 M 个 iOS 原语；
> 2. **桥层建设规格**——标 🔴 的原语当前 Rust core 未暴露，是"把安卓插件搬上 iOS"必须补的桥。
>
> 符号：✅ 已暴露（可直接用）｜🟡 部分暴露（语义收窄/仅覆盖子集）｜🔴 缺失（需新增桥）

---

## 一、原语总表

| # | 原语 | iOS 状态 | iOS 原生调用（Tools.* 绑定） | 备注 |
|---|------|----------|------------------------------|------|
| 1 | 打开 URL / scheme（intent 等价） | ✅ | `Net.openUrl({url})` → `BuiltinToolName::OpenUrl` | Android `Tools.System.intent(VIEW)` 的 iOS 对应；**仅 URL/scheme 打开**，不覆盖广播/activity 任意 intent（语义收窄） |
| 2 | 本地通知 | ✅ | `Net.notify({title,body,delay_seconds})`；另 `System.sendNotification(msg,title)` | 两条路径并存 |
| 3 | 设备信息（型号/品牌/SDK 等） | ✅ | `System.getDeviceInfo()` → `DeviceInfo` | 含 model/brand/version 等；Android `Build.MODEL` 映射到此处 |
| 4 | 地理位置 | ✅ | `System.getLocation({highAccuracy,timeout,includeAddress})` → `LocationData` | 反向地理编码可选 |
| 5 | 媒体音量 | 🟡 | `System.music.setVolume({volume 0..1})` | **仅媒体播放音量**；Android `AudioManager` 各 stream（ring/alarm/notification）未覆盖 |
| 6 | App 用量 / 前台应用 | ✅ | `Net.appUsageReport({limit})`；另 `System.getAppUsageTime({...})` | tweak 捕获的 usage.json |
| 7 | 读取系统通知 | ✅ | `Net.notificationsList({limit})` / `Block` / `Unblock` / `Blocked` | tweak 捕获的 notifications.json |
| 8 | 屏蔽/锁定 App（Screen Time） | ✅ | `Net.screenTimeAuthorize/Pick/Lock/Unlock/MonitorStart/MonitorStop/Usage` | iOS 16+ FamilyControls，越狱增强 |
| 9 | 运行快捷指令 | ✅ | `Net.runShortcut({name})` | iOS Shortcuts 自动化 |
| 10 | 文件读写（VFS） | ✅ | `Tools.Files.{read,write,list,exists,mkdir,move,copy,find,grep,zip,unzip,info,...}`（23 方法） | 虚拟文件系统，路径无关 |
| 11 | 插件配置目录（文件根） | ✅ | `ToolPkg.getConfigDir(pluginId?)` | 替代 Android `/sdcard/Download/Operit/...` 硬编码 |
| 12 | 读取打包资源 | ✅ | `ToolPkg.readResource(key, outputFileName?, internal?)` | 对应 Android `assets/` 读取 |
| 13 | HTTP 请求 | ✅ | `Net.http/httpGet/httpPost/visit/uploadFile` | 平台无关 |
| 14 | Cookie 管理 | ✅ | `Net.cookies.{get,set,clear}` | |
| 15 | 浏览器自动化 | ✅ | `Net.browser{Navigate,Click,Snapshot,Type,...,TakeScreenshot}` | 浮层 WebView |
| 16 | 设备自动化 Agent（AutoGLM） | ✅ | `Net.deviceAgentStart/Stop/Status` | 自然语言驱动 |
| 17 | Live Activity | ✅ | `Net.liveActivity{Start,Update,End}` | iOS 16.1+ 灵动岛 |
| 18 | Toast | ✅ | `System.toast(msg)` | |
| 19 | 系统设置读写 | 🟡 | `System.getSetting/setSetting(setting,value,namespace?)` | Android 命名空间（system/secure/global）在 iOS 未必有对应键 |
| 20 | App 安装/启动/停止/列举 | 🟡 | `System.{installApp,startApp,stopApp,listApps,uninstallApp}` | iOS 受沙盒/越狱限制，实际能力取决于 entitlements |
| 21 | 终端执行 | ✅ | `System.terminal.{create,exec,hiddenExec,info,screen,input,close}` | 真 PTY（已落地） |
| 22 | 蓝牙 | ✅ | `System.bluetooth.*` / `System.bluetooth.ble.*` | 平台无关封装 |
| 23 | 音乐播放控制 | ✅ | `System.music.{play,pause,resume,stop,seek,status}` | |
| 24 | 睡眠/延时 | ✅ | `System.sleep(ms)` | |
| 25 | 内存 / 聊天控制 | ✅ | `Tools.Memory.*` / `Tools.Chat.*` | 平台无关 |

---

## 二、真缺的原语（🔴，必须补桥才能覆盖对应安卓插件）

| 原语 | 安卓来源 | 为什么 iOS 缺 | 建议桥（原生调用） |
|------|----------|---------------|--------------------|
| **电量/充电状态** | `Java.type("android.os.BatteryManager")`、`BatteryManager` | 全仓 grep `battery` 在 js-bridge 零命中；`SystemHost` trait 无 `getBattery` | 新增 `System.getBattery()` → `UIDevice.batteryLevel` + `batteryState`（越狱可直接读，非越狱需 NotificationCenter 观察） |
| **剪贴板** | `ClipboardManager` / `getPrimaryClip` / `setPrimaryClip` | 全仓 grep `clipboard/UIPasteboard` 仅 terser bundle 的 Web DOM API 与 Android `ClipboardManager` 反射，无插件桥 | 新增 `System.getClipboard()/setClipboard(text)` → `UIPasteboard.general` |
| **屏幕信息（分辨率/密度/DPI）** | `wm size; wm density`（AndroidUtils 专属 shell） | `SystemHost` 无 `getScreenInfo`；iOS 无 `wm` 命令 | 新增 `System.getScreenInfo()` → `UIScreen.mainScreen.bounds/nativeScale`（或 `getDeviceInfo` 里附带） |
| **网络状态** | `ConnectivityManager` / `getActiveNetworkInfo` | 无 `getNetworkState` 原语 | 新增 `System.getNetworkState()` → `Network`/`NWPathMonitor`（或 AI 用 `Net.http` 探活间接判断） |

> 这 4 个缺口里，**电量**是 6 个审计插件中 `environment-context-injector` 唯一的硬阻塞（它的 `Java.type("android.os.BatteryManager")` 在 iOS 无对应物）；剪贴板/屏幕信息/网络状态是常见但当前未覆盖，补上后能显著提升"框架依赖型"安卓插件的翻译成功率。

---

## 三、Android 专属、iOS 暂无桥的原语（越狱自动化候选，非当前 SDK）

这些在 `AndroidUtils.script.js` 里走 `Tools.System.terminal.hiddenExec(...)` 调 Android shell（`Shizuku` 权限），iOS 没有等价：

- `setBrightness`（亮度）→ iOS 需 `Brightness` 私有 API 或越狱 daemon
- `setWiFi` / `setBluetooth`（开关）→ iOS 受限
- `lock` / `unlock`（锁屏/解锁）→ iOS 需 `SBSOpenSensitiveURL` 类私有 API
- `reboot` → iOS 需 `reboot()` 系统调用（越狱）
- `takeScreenshot` / `recordScreen` → iOS 需 `ScreenCapture`/`Backlight` 私有 API 或越狱截图服务
- `install/uninstall` APK → iOS 是 `.deb`/重签，语义不同

> 归类：属于"越狱自动化能力层"，与"把普通安卓插件搬上 iOS"是两个不同优先级。当前 AI 翻译架构**不要求**覆盖这些；若插件用到，标记为"越狱专有，需人工桥"而非自动翻译。

---

## 四、对 6 个审计插件的覆盖解释（回扣先前结论）

| 插件 | 用到的安卓 API | 命中 iOS 原语 | 结论 |
|------|----------------|---------------|------|
| dual-phone | 无 Android 信号 | — | 🟢 直接跑 |
| toolpkg-market | 仅缓存目录常量 | `ToolPkg.getConfigDir` + `Net.http` | 🟢 直接跑 |
| qingpei-moments | `/sdcard/...` 仅兜底 | 主路径 `ToolPkg.getConfigDir` ✅ | 🟢 直接跑 |
| deepseek-harness | `java.loadDex`（死资源） | `Net.http` + 本地 web 服务 | 🟡 主体跑（前置：设备有该 web 服务；`.dex` 死资源无害） |
| netease-listen | `Tools.System.intent(VIEW)`、`Android.setVolume('music')`、Linux 路径+node | `Net.openUrl` + `System.music.setVolume` | 🟡 桥够用；但本地 node SSE server 硬编码 Linux home + 需 node，非桥问题 |
| environment-context-injector | `BatteryManager`、`Build.MODEL`、`getSharedPreferences`、`SimpleDateFormat` | `getDeviceInfo`✅ / `getConfigDir`🟡 / **`BatteryManager`🔴** | 🔴 唯一硬阻塞=电量原语缺失；补 `System.getBattery` 后即全绿 |

> 结论一致性：先前静态审计判 3/6 🟢、2/6 🟡、1/6 🔴；本清单从"桥层暴露度"角度给出同一结论的**机制解释**——那 1 个 🔴 的根因就是"电量原语缺失"，不是插件逻辑问题。

---

## 五、AI 翻译架构落点（简述，呼应"行，试试"方案）

- **M 原语 = 本表 ✅/🟡 项 + 待补的 🔴 4 项**。AI 翻译器的"目标词汇表"就是这 M 个 `Tools.*` 调用。
- **确定性路径重写**（已有 `AndroidToolPkgPathRewriter`/`AndroidPathRewriter`）继续承担 `/sdcard/...`→`getConfigDir` 的廉价 45% 转换，不进 LLM。
- **AI 映射层**处理框架依赖型调用：`Java.type("android.os.BatteryManager")`→`System.getBattery`（待补）、`intent(VIEW, url)`→`Net.openUrl`、`ClipboardManager`→`System.setClipboard`（待补）、`ConnectivityManager`→`System.getNetworkState`（待补）等。
- **安全闸**必保留：静态白名单（只允许本表 M 原语）+ 人工 review，因为越狱+root 执行；`.dex`/原生 so 无法 AI 翻译，标记人工。
- **transform-once + 缓存**：翻译产物是规范化的 iOS `.toolpkg`，不是每次安装都跑 LLM。

## 六、下一步建议（待你拍板）

1. 补 4 个 🔴 桥（`getBattery`/`getClipboard`/`getScreenInfo`/`getNetworkState`）——这是"框架依赖型安卓插件"翻译成功率的关键杠杆；
2. 把本清单并入 `operit1_architecture_study.md` 作为新 §22（AI 翻译 + 桥层规格）；
3. 顺手修正 §19  stale 的模块列表、§11/§20.3 的 ~45%/~22% 旧数（应改为 top100 实测 29.1% 可用）。

> 以上均未执行，等你确认是否动手（尤其第 1 项改 Rust core 属写码，需你授权）。
