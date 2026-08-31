# Operit 安卓版（Operit-main）架构研读

> 研读对象：`/Users/mac/Downloads/Operit-main`
> 目的：搞清楚 operit1 为什么"流畅好用"，提炼可迁移到 operit2 iOS 的工程范式
> 日期：2026-08-31
> 说明：全部结论基于本地源码实读（build.gradle.kts / 包结构 / 关键类），非推测

---

## 一、项目规模与技术栈

**身份**：`com.ai.assistance.operit`，versionName `1.12.1+3`（versionCode 46），minSdk 26 / targetSdk 34 / compileSdk 36，**仅 arm64-v8a**。

**Gradle 模块**（`settings.gradle.kts`）：

| 模块 | 路径 | 职责 |
|---|---|---|
| `:app` | app/ | 主应用 |
| `:terminal` | terminal/ | 终端引擎（= 之前看过的 OperitTerminalCore） |
| `:mnn` | llm/mnn | 端侧 LLM 推理 |
| `:llama` | llm/llama | llama.cpp 端侧推理 |
| `:quickjs` | quickjs/ | JS 引擎（工具包运行时） |
| `:dragonbones` | avator/dragonbones | 2D 骨骼动画形象 |
| `:mmd` / `:fbx` | avator/* | 3D 形象 |
| `:showerclient` | — | 屏幕投射/控制客户端 |

**关键依赖**（`app/build.gradle.kts`）：
- UI：Jetpack Compose + Material3 + Navigation Compose + Glance（桌面小部件）
- 持久化：**ObjectBox**（主）+ Room + DataStore
- 网络：OkHttp + **okhttp-sse**（流式）+ Retrofit/Moshi + Ktor
- 协议：**MCP SDK client**（Model Context Protocol）
- AI 本地：MNN / llama.cpp / ONNX Runtime / TFLite / MediaPipe
- 检索：**hnswlib**（向量）+ Jieba（中文分词）
- 权限：Shizuku API + libsu（root）
- 文档：Apache POI / iTextG / PDFBox / Zip4J
- 渲染：Filament（glTF 3D）+ JLatexMath（公式）+ Markwon 系
- 多媒体：ExoPlayer + Coil/Glide + **自建 FFmpegKit AAR**
- 原生：CMake（`src/main/cpp`）+ **Rust**（`tools/native_ripgrep`）+ 自带 `liboperit_ripgrep.so`
- 调度：WorkManager

---

## 二、分层结构

```
com.ai.assistance.operit
├── core/                      # 与 UI 无关的能力层
│   ├── tools/
│   │   ├── AIToolHandler          # 工具注册/调度中枢
│   │   ├── ToolExecutionLimits    # 输出限额
│   │   ├── ToolProgressBus        # 工具进度事件总线
│   │   ├── defaultTool/{standard,admin,root,accessbility,debugger}/   # 按权限分级的实现
│   │   ├── system/shell/          # ShellExecutor 家族 + Factory
│   │   ├── system/action/         # ActionListener 家族 + Factory
│   │   ├── javascript/            # QuickJS 集成（JsEngine/JsToolManager/JsTimeoutConfig）
│   │   ├── mcp/                   # MCP 客户端
│   │   ├── packTool/              # ToolPkg 工具包加载/解析
│   │   ├── skill/                 # Skill 包
│   │   ├── agent/                 # PhoneAgent（手机自动化/AutoGLM）+ Shower 投屏
│   │   └── websession/            # 内置浏览器 + userscript 引擎
│   ├── chat/                      # AIMessageManager + Prompt/Summary Hook 注册表
│   ├── config/                    # SystemPromptConfig / SystemToolPrompts
│   ├── workflow/                  # 工作流调度（WorkManager）
│   ├── avatar/                    # 6 种形象后端统一抽象
│   ├── application/               # Application / 生命周期 / 前台服务
│   └── subpack/                   # APK 逆向编辑（ApkEditor/ApkReverseEngineer）
├── data/                          # 数据模型 / 偏好 / 仓库
├── util/
│   ├── stream/                    # ★ 流式处理子系统
│   ├── streamnative/              # ★ native 流式切分器
│   └── AnrMonitor                 # ★ 主线程阻塞看门狗
├── ui/
│   ├── features/{chat,packages,toolbox,memory,workflow,settings,websession,tokenstats,...}
│   ├── floating/                  # 悬浮球/悬浮窗/全屏/屏幕 OCR
│   ├── permissions/               # ToolPermissionSystem
│   ├── common/{markdown,displays,composedsl,...}
│   └── main/                      # 导航 + Phone/Tablet 双布局
└── widget/                        # Glance 桌面小部件
```

---

## 三、五个决定"流畅度"的工程范式

### 1. 权限分级 + 优雅降级（最值得抄）

**证据** `core/tools/system/shell/ShellExecutorFactory.kt`：

```kotlin
fun getHighestAvailableExecutor(context): Pair<ShellExecutor, PermissionStatus> {
    val levels = listOf(ROOT, ADMIN, DEBUGGER, ACCESSIBILITY, STANDARD)
    for (level in levels) {
        val executor = getExecutor(context, level)
        if (executor.isAvailable() && executor.hasPermission().granted) return Pair(executor, ...)
    }
    // 全挂则回落 STANDARD：至少能执行基本命令
    return Pair(standardExecutor, standardExecutor.hasPermission())
}
```

同一接口 5 个实现：`RootShellExecutor` / `AdminShellExecutor` / `DebuggerShellExecutor` / `AccessibilityShellExecutor` / `StandardShellExecutor`。
`system/action/` 同样结构（`ActionListenerFactory` + 6 个 ActionListener）。
工具层同样按级分目录：`defaultTool/{standard,admin,root,accessbility,debugger}/`，每级各自实现 FileSystem/UI/SystemOperation/DeviceInfo。

**含义**：设备权限状态不是"有/无"二值，而是一个能力光谱。功能永远可用，只是能力随权限升降。
UI 侧配套 `ui/features/demo/wizards/`（Root/Shizuku/Accessibility/OperitTerminal 引导卡片）引导用户提权。

**对照 operit2 iOS**：硬依赖越狱，无越狱时大量能力直接硬桩（如 `getSystemSetting` 在 iOS 是写死的 stub），不是降级而是"瘫掉"。

---

### 2. 无全局锁的并发注册表

**证据** `core/tools/AIToolHandler.kt`：

```kotlin
private val availableTools = ConcurrentHashMap<String, ToolExecutor>()   // 工具注册表
private val toolHooks      = CopyOnWriteArrayList<AIToolHook>()          // 钩子表

private inline fun notifyHooks(eventName: String, action: (AIToolHook) -> Unit) {
    toolHooks.forEach { hook ->
        try { action(hook) }                    // 每个钩子独立 try/catch
        catch (e: Exception) { AppLogger.w(TAG, "AIToolHook callback failed at $eventName", e) }
    }
}
```

- 注册表用**并发容器**，读路径完全无锁
- 钩子逐个**异常隔离**：一个坏钩子不会拖垮整条链、不会中断工具执行
- 完整生命周期事件：`onToolCallRequested → onToolCallIntercept(Allow/Block) → onToolPermissionChecked → onToolExecutionStarted → onToolExecutionResult/Error → onToolExecutionFinished`

**对照 operit2 iOS**：全局 `getOrCreatePackageManager` Mutex；compose_dsl 渲染时 `notifyToolCallRequested` 同步回调进 `runtime.package_manager()` **同线程重入同一把锁** → 自死锁 60s。operit1 用并发容器 + 异常隔离从结构上消除了这类问题。

---

### 3. 取消与超时纪律

| 机制 | 证据位置 |
|---|---|
| 长循环设检查点 `currentCoroutineContext().ensureActive()` | `WorkflowExecutor.kt:645,852,1106,1272`；`BrowserDownloadSupport.kt:544,563,600` |
| 硬超时包住 JS 执行 `withTimeout(JsTimeoutConfig.SCRIPT_TIMEOUT_MS)` | `JsToolManager.kt:390` |
| 超时常量集中定义（SCRIPT 1800s / PRE_LEAD 5s） | `JsTimeoutConfig.kt` |
| 请求级超时 `withTimeoutOrNull(REQUEST_TIMEOUT_MS)` | `WebSessionPermissionRequestActivity.kt:57`、`UserscriptImportCoordinator.kt:39` |
| Job 登记进 registry，可全局取消且带 reason | `PhoneAgentJobRegistry.kt:48,66`（`cancel(CancellationException(reason))`） |
| 用户可中断长任务 | `PhoneAgent.kt:418,427,476,486,535,545`（"User cancelled UI automation"） |
| Flow 清理 `awaitClose { job.cancel() }` | `DebuggerShellExecutor.kt:644` |
| **输出限额**（防单次工具淹没上下文） | `ToolExecutionLimits.kt`：`MAX_FILE_READ_BYTES=32_000`、分段 200 行、`MAX_TEXT_RESULT_LENGTH=5_000` |

**对照 operit2 iOS**：同步 `FnToolExecutor` + 单 WASM worker，无超时纪律、无输出限额 —— 一个工具卡住 = 整条链卡住（60s 看门狗来砍）。

---

### 4. 可观测性是内建功能，不是事后补丁

**证据** `util/AnrMonitor.kt`（427 行）：

- 采样间隔 **100ms**，警告阈值 **500ms**，ANR 阈值 **1000ms**
- 机制：往主线程 `Handler.post` 打点 → 看门狗（专用 **MAX_PRIORITY 守护线程**）比对 `lastResponseTime`
- 超阈值 → 抓**全线程栈** → 按 `com.ai.assistance.operit` 包名**过滤**出自己的调用 → 与上次结果**去重** → 落盘 `anr_report_<ts>.txt`（含 ANR 次数/最长阻塞/内存信息/调用者信息）
- 支持 `addCallerInfo(key, info)` 主动埋点追踪调用来源
- 协程启动失败自动回落 `ScheduledExecutorService` 备选方案

配套：`util/AppLogger`、`StreamLogger`（可开关 + verbose 分级）。

**对照 operit2 iOS**：排查 60s 卡死靠读源码推理 + 临时埋 6221 探针。没有常态化监控 = 每次都在猜。

---

### 5. 流式处理是独立子系统（"打字机流畅"的技术底座）

**证据** `util/stream/`（20+ 文件）：

- 抽象：`Stream<T>` / `HotStream` / `RevisableTextStream` / `TextStreamRevisionTracker` / `StreamGroup` / `StreamBuilders`
- 插件化切分：`StreamXmlPlugin` / `StreamJsonPlugin` / `StreamPureJsonPlugin` / `StreamMarkdownPlugin`（`BaseJsonPlugin` 基类）
- **native 加速**：`util/streamnative/NativeXmlSplitter`、`NativeMarkdownSplitter`、`NativeMarkdownStreamOperators`
- 支持**文本修订**：`RevisableTextStream` + `TextStreamRevisionTracker` —— AI 可以修改已输出的内容（不只是追加）
- KMP 匹配加速：`StreamKmpGraph` / `StreamKmpMatchResult`
- UI 侧配套：`ui/common/markdown/StreamMarkdownRenderer`、`RenderBatchCoordinator`（渲染批处理）、`ui/features/chat/components/RevisableTextStreamRemember.kt`

**含义**：流式不是"拿到 chunk 直接 setState"，而是一整套带切分/修订/批处理/native 加速的管道。这是"看起来流畅"的直接原因。

---

## 四、性能工程专项投入

| 投入 | 位置 | 说明 |
|---|---|---|
| **自建整套 LazyColumn** | `ui/features/chat/components/lazy/`（~50 文件） | 复制并改造 Compose 的 LazyList：CacheWindow、PrefetchScheduler、ItemAnimator、StickyItems… 为聊天长列表专门优化 |
| Markdown 渲染批处理 | `ui/common/markdown/RenderBatchCoordinator.kt` | 合并渲染批次，避免逐 chunk 重排 |
| LaTeX 缓存 | `ui/common/displays/LatexCache.kt` | 公式渲染结果缓存 |
| 对象池 | `util/ImagePoolManager.kt`、`util/SkillRepoZipPoolManager.kt` | 复用大对象，降 GC 压力 |
| 图片/媒体限流 | `util/ImageBitmapLimiter.kt`、`util/MediaBase64Limiter.kt` | 防 OOM |
| 流式切分 native 化 | `util/streamnative/` + Rust `tools/native_ripgrep` | 热点路径下沉到 native |

---

## 五、功能广度（"级别差"的直观来源）

| 域 | 能力 |
|---|---|
| AI 对话 | 多种输入样式（classic/agent）、多种气泡样式（bubble/cursor）、thinking 质量滑杆、待发消息队列、附件（图/音/视/文件）、@提及、消息编辑、导出、token 统计与图表 |
| 端侧智能 | MNN / llama.cpp 本地推理、ONNX/TFLite 嵌入、hnswlib 向量检索、Jieba 分词、本地 STT（sherpa-mnn/ncnn，构建期下载并校验 SHA256）、TTS |
| 记忆 | `ui/features/memory/` 记忆库 + **知识图谱可视化**（GraphVisualizer）+ 文档管理 + 搜索模拟 |
| 工具生态 | ToolPkg（QuickJS 运行时）+ **MCP 客户端**（部署/配置/市场）+ Skill 包 + 统一市场（浏览/详情/作者/发布/评价）+ Artifact 发布 |
| 工具自定义 UI | **Compose DSL**：工具包用 DSL 声明 UI → 生成 `ToolPkgComposeDslGeneratedRenderers`；还有 XML Canvas 自定义渲染 |
| 虚拟形象 | `core/avatar/` 统一抽象 6 种后端：DragonBones(2D骨骼) / MMD / FBX / glTF(Filament) / WebP / MP4 |
| 多形态 | 手机/平板双布局（`PhoneLayout`/`TabletLayout`）、**悬浮球+悬浮窗+全屏模式+屏幕OCR**、桌面小部件（Glance） |
| 内置浏览器 | `websession/` 完整浏览器：多标签、书签、历史、下载、**userscript 引擎**、AI 可驱动的 BrowserTool |
| 自动化 | `PhoneAgent`（AutoGLM 式 UI 自动化）+ Shower 屏幕投射录制 + 可视化操作覆盖层 + 工作流可视化编排（节点画布）+ WorkManager 定时调度 |
| 工具箱 | 文件管理器（双栏）、Shell 执行器、Logcat 查看器、SQL 查看器、FFmpeg 工具箱、HTML 打包、语音转文字/文字转语音、UI 调试器、进程限制移除、应用权限查看、工具测试器 |
| 工程向 | **APK 逆向编辑**（ApkEditor/ApkReverseEngineer/KeyStoreHelper）、项目脚手架模板（`assets/templates/{android,flutter,java}`）、内置代码编辑器（Kotlin/Dart/JS/HTML 语法高亮+补全+格式化）、GitIgnore 过滤、工作区变更追踪 |

---

## 六、归因：为什么 operit2 iOS 差一个级别

**不是平台能力问题。** 前几轮已论证：越狱 iOS 坐在 Procursus 级 bootstrap 上，有原生 Darwin 环境（bash/python/node），速度与 proot 相当甚至更快；iSH 补"跑未改 Linux ELF"的洞。Darwin 侧能力对等等于甚至优于安卓 proot。

**是工程成熟度 + 产品完成度的差距：**

| 维度 | operit1（安卓） | operit2 iOS（我们） |
|---|---|---|
| 权限模型 | 5 级优雅降级，永不"用不了" | 硬依赖越狱，无越狱即硬桩 |
| 并发 | 并发容器 + 异常隔离 | 全局 Mutex，重入自死锁 60s |
| 超时/取消 | ensureActive 检查点 + withTimeout + Job registry + 输出限额 | 同步执行，无超时纪律 |
| 可观测性 | 内建 ANR 看门狗 + 结构化日志 | 靠读源码猜 + 临时探针 |
| 流式 | 独立子系统 + native 加速 + 修订支持 | 单 WASM worker 同步产出 |
| 性能专项 | 自建 LazyList、对象池、批处理、缓存 | — |
| 产品完成度 | 完整产品（端侧 LLM、记忆图谱、形象、工作流、市场、浏览器、自动化） | 21 天 POC：能聊 + 能跑命令 |

**结论**：差距的 80% 来自**工程范式**（并发/超时/可观测/流式/降级），20% 来自功能广度。平台不是借口。

---

## 七、若真要改进 operit2，优先级排序

1. **先做可观测性** —— 卡顿时自动抓栈 + 调用链日志。否则继续猜，永远修不完。
2. **拆全局 Mutex** → 并发注册表 + 钩子异常隔离。这是 60s 自死锁的结构性修复。
3. **工具执行加超时 + 取消 + 输出限额**（直接抄 `ToolExecutionLimits` 的量级）。
4. **权限分级降级**：jb / non-jb 两套工具实现 + 自动探测最高可用级，永不返回"不支持"。
5. **流式输出与 UI 线程解耦**（哪怕简化版：增量 + 批处理渲染，不做 native 切分）。
6. **功能做减法**：砍虚拟形象、端侧 LLM、市场生态；只留「对话 + 工具 + 终端 + 文件」核心闭环，做到不卡。

> 前 3 项是"止血"（解决卡死/锁/调度），后 3 项是"提升体验"。
> 在 1-3 没做完之前加功能 = 在流沙上盖楼。

---

## 八、AI 主循环与工作流引擎（深读补充，2026-08-31 第二轮）

> 第二轮实读：`EnhancedAIService.kt` / `AIService.kt` / `core/workflow/*`。
> 这一轮专门看"为什么它交互顺、且能跑复杂自动化"，证据在源码。

### 8.1 多模型路由（MultiServiceManager + FunctionType）

`EnhancedAIService` 不是"一个 AI 服务"，而是**按功能分发的路由层**：
- `getAIServiceForFunction(FunctionType)` → `MultiServiceManager` 按功能选不同 provider/model。
- `FunctionType` 区分 CHAT / TOOL / EMBEDDING / 等；`getModelExecutionSnapshot()` 取对应模型快照。
- 装饰器链：`TokenTrackingAIService`（token 计数/统计账本）+ `RateLimitedAIService`（限流）+ 真实 provider（DeepSeek/OpenAI/本地 MNN）。

**对照 operit2**：我们是"一个模型打全场"。路由层让"工具调用用强模型、闲聊用便宜模型、嵌入用专用模型"——这是它"显得聪明又省"的结构性原因，不是 prompt 写得好。

### 8.2 Agentic 主循环：流式 + XML 工具调用 + 多轮

`sendMessage(SendMessageOptions)` 是核心，结构（证据 `EnhancedAIService.kt:878` 起）：
1. `prepareConversationHistory()`：注入 system prompt + 记忆 + 角色卡 + workspace。
2. 流式调 `AIService.sendMessage()` 拿 `Stream<String>`。
3. **边流边检测工具调用**：`enhanceToolDetection` / `normalizeToolXml` / `detectAndRepairTruncatedToolRound` —— 工具调用是 **XML 块**而非 OpenAI function-calling，且做了**流式截断修复**（`completePartialOpenTag` / `completePartialClosingTag`）：因为工具 XML 是分块到达的，半截 tag 会被补全再执行。
4. 检测到工具 → `handleToolInvocation()`（`2050`）：在独立 `toolProcessingScope.launch` 里跑 `ToolExecutionManager.executeInvocations()`，结果登记进 `toolExecutionJobs` map（可取消）。
5. `processToolResults()` 把工具结果回灌历史 → 继续下一轮（ReAct 多轮），直到无工具调用。

**关键健壮性细节**（决定"流畅"）：
- `MessageExecutionContext` + `ConversationRoundManager`：每轮管理显示内容与修订。
- `InputProcessingState` 状态流驱动 UI：`Processing → Connecting → ExecutingTool(工具名)`，所以**永远不会是空白转圈**，用户始终知道在干啥。
- 工具执行在独立 scope，主流式不被阻塞；`toolExecutionJobs` 支持按 invocationId 取消。

**对照 operit2**：我们是"同步执行 + 单 WASM worker"，工具一卡全链卡，且工具调用格式/流式没有截断修复——长工具输出或网络抖动直接让回合崩。这一块的差距比"有没有功能"更致命。

### 8.3 工具执行与 AI 服务解耦

`ToolExecutionManager`（独立管理器）接收 `ToolInvocation` 列表，负责：按 `ToolExposureMode`（按 apiProviderType 解析）决定工具可见性、调用 `AIToolHandler`、回写 `StreamCollector`。AI 服务只管"对话+检测工具"，工具执行是另一个边界清晰的子系统。

### 8.4 可视化工作流引擎（WorkflowExecutor，生产级 DAG）

`core/workflow/WorkflowExecutor.kt`（1320 行）是完整的有向图执行引擎：
- **节点类型**：`TriggerNode`（入口，支持 manual/schedule）+ `ExecuteNode`（调一个工具）+ `ConditionNode`（比较：EQ/NE/GT/IN/CONTAINS…）+ `LogicNode`（AND/OR）+ `ExtractNode`（REGEX/JSON-PATH/SUBSTRING/CONCAT/随机数）。
- **依赖图**：`buildDependencyGraph` 用邻接表 + 入度；**显式连线 + 参数引用双向建边**（`buildReferenceDependencies`）。
- **环检测**：DFS 三色标记（`detectCycle`）。
- **执行**：`executeTopologicalOrder` 拓扑排序 + 入度队列；节点间通过 `ParameterValue.NodeReference` 传值（前节点结果喂后节点参数）。
- **逐节点隔离**：每个 `executeNode` 独立 `try/catch`，单节点失败 → `NodeExecutionState.Failed`，不拖垮整图；失败分支经 `error/failed` 条件边处理（`hasUnhandledFailure`）。
- **取消纪律**：`currentCoroutineContext().ensureActive()` 在 `executeWorkflow` / 拓扑循环 / 每个节点执行前都设检查点（共 4+ 处），取消即整图干净退出。
- **可观测**：`WorkflowRunLogger` 全程记 DEBUG/WARN/ERROR 日志 + 生成 `WorkflowExecutionRecord`（含 runId、起止时间、每节点状态、失败阶段）。
- **重试**：`RUNTIME_INITIALIZATION` 失败标 `shouldRetry=true`，交给 `WorkflowWorker` 重试而非报"工具缺失"。

### 8.5 后台调度（WorkflowScheduler，WorkManager）

`WorkflowScheduler.kt` 用 Android `WorkManager` 支撑三种触发：
- `interval`（周期，≥15min，WorkManager 限制）
- `specific_time`（一次性定时）
- `cron`（简化解析：日/每 N 小时/每 N 分钟）

特性：`ExistingPeriodicWorkPolicy.REPLACE`（去重）、`BackoffPolicy.EXPONENTIAL`（指数退避）、`enqueueUniqueWork`（同 id 不重复排）、`isWorkflowScheduled` 查状态。即"定时任务"是系统级可靠调度，不是 App 自己轮询。

### 8.6 这一轮的结论

operit1 的"流畅"不仅是 UI，更是**三层解耦 + 全链路取消/超时/日志**：
- AI 路由层（多模型）↔ 对话流层（XML 工具 + 截断修复）↔ 工具执行层（独立 scope + 管理器）↔ 自动化层（DAG 工作流 + WorkManager 调度）。
- 每层都有：取消检查点、`try/catch` 隔离、状态流/日志对外可见。

operit2 的对应物是**单线程同步 + 全局锁 + 无取消 + 监控缺失**——注意：operit2 **并非无日志**（AppLogger 具备分级/文件/内存/错误链能力，iOS 上文件已绑定到 `runtimeRoot/logs/operit.log`），但**ANR/卡死看门狗是空壳、无 panic hook、AppLogger 自身有全局锁/无上限内存/不抓堆栈三处自伤**（详见 §十二）。同一件事，operit1 是"分四层各管各的、每层可观测可取消"，operit2 是"全堵在一条主链上，一处卡全死"。这就是"1 比 2 高"的工程本质，不是平台、不是模型、不是功能数量。

---

## 九、终端引擎 + 工具层并发/取消纪律（源码实读对照，2026-08-31 第三轮）

本轮直接读两边源码，把"operit2 iOS 垃圾"从论断落到 file:line。重点三处：终端引擎本质、工具层全局锁、取消/超时文化。

### 9.1 终端引擎：operit2 = iSH 模拟器桥接，operit1 = 真原生 PTY 引擎

**operit2 iOS（`hosts/ios/src/terminal.rs`）**：整个 `IosTerminalHost` 是把终端操作通过 `callIshTerminal(...)` FFI 转发给 **iSH**（纯用户态 Linux 模拟器）。
- `primaryBackend()` 直接返回 `Ish`（terminal.rs:128-130）——默认终端就是 iSH Alpine，不是真 shell。
- 真 `/bin/sh`（`NativePtyTerminalHost`）虽存在，但 `probeSystemShell` 注释明说 **"the sandboxed app cannot spawn it"**（terminal.rs:124-127），只能当显式选项、非默认，且 `systemShellAvailable` 在沙盒 app 里通常为 false。
- 所有 `start/read/write/resize/execute/screen` 在 `Ish` 分支都走 `callIshTerminal("terminalXxx", ...)`（terminal.rs:210/258/298/370/386/403/471…），即把请求甩给 iSH 子进程，**operit2 自身没有任何转义序列解析/渲染/PTY 逻辑**。
- `IOS_SHELL_PATH`（terminal.rs:26-27）硬编码拼了一大串 `/var/jb/usr/bin` 等越狱路径——侧面印证它依赖越狱 bootstrap 才能跑命令，且 PATH 都得手工兜底（"inherited app PATH was missing /usr/bin"）。

> 结论：operit2 iOS 的"终端"是**模拟器桥接层**，不是引擎。iSH = 慢速用户态 Linux 模拟（与 8/30 日志结论一致：iOS 跑未改 Linux ELF 只能 iSH，慢不全）。这与"native Darwin 二进制（bash/python/node）在 Dopamine bootstrap 上原生速度"是两条路——operit2 选了慢的那条当默认。

**operit1 安卓（OperitTerminalCore）**：真·终端引擎。
- `src/main/jni/pty.c`：JNI 自研 `fork/exec` 起**真 PTY 子进程**（还专门处理 Node/Python REPL 的 ICANON 检测）。
- `CanvasTerminalView`：Canvas 自绘终端；`AnsiTerminalEmulator` / `AnsiScanner` / `AnsiSequence`：自研 ANSI 转义解析。
- `LocalTerminalProvider` 用 **proot + Ubuntu rootfs**（buildEnvironment 设 `PROOT_LOADER` / `TERM=xterm-256color`），跑的是真 Ubuntu 二进制，原生速度。

> 对照：operit1 终端 = 自己写引擎（PTY + 渲染 + 转义 + 会话），跑原生二进制；operit2 iOS 终端 = 把活外包给 iSH 模拟器，自己只做 JSON 转发。这是"级别差"的又一硬件证据——operit2 在最有价值的"终端"能力上连引擎都没自己写。

### 9.2 工具层仍卡在单一不可重入全局 Mutex（"修复"只治标）

operit2 工具注册表核心是 `getOrCreatePackageManager()`，返回一个 **`Mutex`（non-reentrant）**。
- `ChatServiceCore.rs:1475`：`let packageManager = toolHandler.getOrCreatePackageManager();`
- `ProviderRuntimeSupportService.rs:194-197`：`let package_manager = self.tool_handler.getOrCreatePackageManager(); let manager = package_manager.lock().expect("package manager mutex poisoned").clone();` —— **同步持锁**，且 `expect` 一旦 poison 直接 panic。
- 60s 死锁根因就写在该锁的调用链注释里（`ToolPkgToolLifecycleBridge.rs:272-280`）：同步 `deliver` 在 WASM worker 线程**重入同一把锁**（render 触发 tool call 时已持锁）→ 自死锁 60s，直到看门狗砍 render。

**修复的实际范围（commit `7b8d0677`）**：只把 6 个纯通知 `onTool*` 从同步 `deliver` 改成 `deliver_async`（fire-and-forget，ToolPkgToolLifecycleBridge.rs:59/138/142/160/167）。**但全局 package-manager Mutex 本身没动**——`ProviderRuntimeSupportService.rs:194` 仍是同步 `.lock().expect("package manager mutex poisoned").clone()`。

> 即"症状缓解、结构未改"：下一次任何同步路径（render / exec / 注册并发）重入这把不可重入锁，照样死锁。operit1 根本没这把锁——它用 `ConcurrentHashMap` + 钩子逐个 `try/catch` 隔离（见 §二.2），无全局锁、无 reentrant 陷阱。

### 9.3 取消/超时文化差：有 timeout ≠ 有取消纪律

- operit2：终端命令层确有 `timeoutMs` 透传（terminal.rs:288/303/512/514，`terminalExecute` 带 `timeoutMs`），但有"单命令超时"≠ 有"执行取消纪律"。**60s 死锁本身就是反面证据**：卡住的 render 跑了整 60s 才被看门狗砍，工具调用本身不可取消、无检查点、无输出限额——用户只能干等。
- operit1：取消/超时是第一等公民（源码实读，本轮 grep 坐实）：
  - `withTimeout` / `withTimeoutOrNull` 遍布：`ShowerController.kt:152`、`ChatHistoryDelegate.kt:586/843/880/1019/1031`、`MessageCoordinationDelegate.kt:1247`。
  - `ensureActive()` 取消检查点：`PatchUpdateInstaller.kt:17`。
  - `Job` 登记进 `PhoneAgentJobRegistry` 可带 reason 全局取消；`ToolExecutionLimits` 输出限额（读文件 32KB / 分段 200 行 / 文本 5K 字符）。
  - 并发状态全 `ConcurrentHashMap`：`chatRuntimes`(MessageProcessingDelegate:221)、`boundServicesByChatKey`(TokenStatisticsDelegate:42)、`downloadJobs`(MnnModelDownloadManager:133)、`stores`(ObjectBox:10)… 无一用全局 `Mutex`。

### 9.4 这一轮的结论（呼应 §六归因）

operit2 iOS 弱，**不在"iOS 不能跑终端"**（Dopamine bootstrap 上真 `/bin/sh` + bash/python/node 是有的，见 terminal.rs:85-106 探针），而在**实现层**：
1. 终端退化成 **iSH 桥接**（慢速模拟器），而非自研原生 PTY 引擎；
2. 工具层退化成 **单一不可重入全局 Mutex**（且"修复"只把通知异步化，锁原封未动）；
3. 缺少 **取消/超时/输出限额文化**，卡死只能等看门狗。

operit1 是"**原生引擎 + 无锁并发（ConcurrentHashMap）+ 取消文化（withTimeout/ensureActive/Job 取消）**"三件套。改 operit2 优先级不变（§七）：**1 可观测性 → 2 拆全局 Mutex → 3 超时+取消+输出限额 → 4 权限分级降级 → 5 流式解耦**。前 3 项没完别加功能——加功能 = 在流沙上盖楼，下次死锁只是时间问题。

---

## 十、越狱 / 特权执行方向深挖（并修正 §9.4 第 1 点的过度表述）

> 上一章第 1 点写"终端退化成 iSH 桥接，而非自研原生 PTY 引擎"——**这句话把 operit2 说得比实际更废，要修正**。本轮顺着 jailbreak 方向实读源码，结论分两层：operit2 iOS **真有**硬核越狱集成（不垃圾）；但它的"AI 执行路径默认把真 shell 丢了、改用模拟器" + "注释自相矛盾"才是越狱方向的真垃圾点。

### 10.1 这一轮发现：operit2 iOS 真有越狱集成（不是全垃圾）

源码坐实 4 处真越狱 plumbing，且都是 jailbreak 的难活：

1. **rootless `/var/jb` 环境感知 + jailbreak 探测**——`core/crates/operit-ios-env/src/lib.rs:1-18` 明确"Rootless-only: targets Dopamine / ElleKit rootless, everything under a fixed `/var/jb` symlink"；`detect_jailbreak()` 做类型探测；`data_root()`/`binary_root()` 运行时解析。这是把"iOS 越狱路径模型"当一等公民，不是事后补丁。
2. **daemon 做 AMFI trustcache 签名（最难的一段）**——`hosts/ios/src/bin/operit_agent_daemon.rs:253-348`：`tool.trustCacheAdd <path>` 先 `/var/jb/usr/bin/ldid -H` 算 cdhash，再 `/var/jb/usr/bin/jbctl trustcache add` 把重签二进制注册进 AMFI trustcache（免重启生效）；另有 `jbctl proc_set_debugged <pid>`（daemon.rs:262-360）。**这是越狱 app 落地最难的部分（让重签/新二进制被 kernel 信任），operit2 真做了**。
3. **UI 自动化走真 jailbreak tweak**——`hosts/ios/src/device_automation.rs:1-29`：主通道 `ios-mcp` jailbreak tweak over HTTP `127.0.0.1:8090/mcp`（JSON-RPC 2.0，screenshot/tap/OCR/app 控制）；兜底 `operit-sb` SpringBoard 注入 socket（`data_root()/operit.sock`）。即设备自动化依赖**真 tweak 注入 SpringBoard**，不是无障碍模拟点击。
4. **真 shell 探测且可用**——`hosts/ios/src/terminal.rs:85-106` `probeSystemShell()` 依次试 `/bin/sh`、`/var/jb/bin/sh`，probe 成功即 `systemShellAvailable=true`；`hosts/common/operit-host-native-terminal/src/lib.rs:96/119` 的 `nativeBash()`/`systemShell()` 也都优先选 `/var/jb/bin/bash`、`/var/jb/bin/sh`。**真 procursus shell 在命令执行层是首选，不是摆设**。

### 10.2 operit1 的特权 / 用户空间模型（对照）

operit1（Android，root 即"越狱"等价物）的特权模型更**刻意、有身份边界**：

- **Root→shell 身份降级（SELinux 感知）**——`tools/shell_identity_launcher/native-lib.cpp:138-144`：从 Shizuku 源码简化移植的 SELinux helper，以 `root(0)` 运行、init SELinux helper、打印当前上下文，**再降级到 shell uid(2000) + FakeContext(PACKAGE_NAME=com.android.shell)`**。即"我要系统级权限，但用完降回 shell 身份"，身份边界是设计出来的。
- **真 Linux 用户空间（PRoot Ubuntu 24.04 ARM64）**——`README.md:96` "内置 Ubuntu 24.04 ARM64 用户空间，默认通过 PRoot 运行，支持时可用 chroot"；`examples/super_admin.js:163-164` 工具描述"在 Ubuntu 环境中执行终端命令，运行环境：完整的 Ubuntu 系统"。DSH 工具包更在 Ubuntu 内 `apt install build-essential`、原生编译 `pty.node`（`examples/sidebar_deepseek_harness/README.md:25`）——**真 Linux、真 PTY、真包管理**。
- **UI 自动化三通道**——`README.md:81` Accessibility + Shizuku(ADB 级) + Root。

### 10.3 越狱方向的真"垃圾"点（精准、带证据）

operit2 iOS 的垃圾不在"没接越狱"，而在 **AI 执行路径把真 shell 白白丢了 + 代码自相矛盾**：

**A. AI 工具/插件命令默认跑在 iSH 模拟器，真 `/var/jb/bin/sh` 被弃用（决定性证据）**
- `hosts/ios/src/terminal.rs:502-505`：`createOrGetSession`（插件/工具执行器的 Host 入口）调用 `createOrGetBackendSession(self.primaryBackend(), …)`。
- `primaryBackend()`（terminal.rs:128-130）**硬编码返回 `Ish`**，注释明说"jailbroken system /bin/sh probe succeeds on this device **but the sandboxed app cannot spawn it**, so it must never be the auto-selected default"。
- 后果：**越狱设备上，AI 的 shell 工具仍跑在 iSH（用户态 Alpine 重实现）里**，而不是 probe 已证明可用的真 `/var/jb/bin/sh`。iSH 不是真 Linux——无真 daemon、syscall 子集、慢；而 operit1 的 AI 工具跑在**真 Ubuntu PRoot**（apt/build-essential/原生 pty.node）。这是越狱方向最实的功能落差。

**B. 注释自相矛盾 = 代码腐烂实锤（同文件两处打架）**
- terminal.rs:124-127 说"app **cannot spawn** the system shell"（所以不能用）。
- 但 terminal.rs:233-235（SystemShell 分支的报错 dump）说"**The jailbroken system shell (/var/jb/bin/sh) is confirmed runnable on device**"。
- 两处关于"app 能不能起系统 shell"的断言直接矛盾；且 `probeSystemShell()`（85-106）实测能起、`systemShellAvailable=true`。**代码自己都不信自己**——典型的"分支多、没人统一维护、注释过期"的垃圾特征。

**C. 两套终端后端无统一特权执行模型**
- Ish 与 SystemShell 并存（terminal.rs:45-49），但 SystemShell 仅"显式选 `SYSTEM_SHELL_TERMINAL` 且 `systemShellAvailable`"才走（140-142）；默认 + AI 执行全走 Ish。等于**一个能用、更真的后端被设计成二等公民**，没有任何"在越狱设备上优先真 shell"的策略。对比 operit1 把"Root/真 Ubuntu"当唯一主路径，operit2 是"模拟器默认、真 shell 备选"——方向反了。

### 10.4 越狱 / 特权执行对照表

| 维度 | operit1（Android root） | operit2 iOS（jailbreak） |
|---|---|---|
| 特权获取模型 | Shizuku binder handoff：`root(0)`→init SELinux→降级 shell(2000)+FakeContext（`shell_identity_launcher/native-lib.cpp:138-144`） | 直接 spawn `/var/jb/bin/sh`；无显式身份/SELinux 模型；AMFI 信任靠 daemon 的 ldid+jbctl（daemon.rs:253-348） |
| 用户空间 | **真** Ubuntu 24.04 ARM64 via PRoot（apt/build-essential/原生 pty.node） | AI 工具默认 **iSH Alpine 模拟器**；真 `/var/jb/bin/sh` 仅显式可选（terminal.rs:503-505→Ish） |
| 签名/信任 | 无 AMFI，N/A | ldid -H 算 cdhash + `jbctl trustcache add`（daemon.rs:313-348）——**真做了，且是难活** |
| UI 自动化 | Accessibility / Shizuku / Root | ios-mcp tweak（HTTP）主 + operit-sb socket 兜底（device_automation.rs:1-29）——**真 tweak 注入** |
| env 探测 | `android.shizuku_available` 能力探针 | `operit_ios_env::detect_jailbreak()` rootless /var/jb（lib.rs:1-18） |

### 10.5 修正 §9.4 第 1 点

原句"终端退化成 iSH 桥接，而非自研原生 PTY 引擎"应改为：

> operit2 iOS **有**自研原生 PTY 引擎（`NativePtyTerminalHost`，lib.rs:82-133），且真 `/var/jb/bin/sh` 在命令执行层是首选；但其 **AI 工具/插件执行器的默认后端被硬编码为 iSH 模拟器**（terminal.rs:128/503-505），真 shell 退为显式可选。垃圾点是"**越狱设备上默认用模拟器而非真 shell**"+"**两套后端无统一特权模型**"+"**注释自相矛盾**"，不是"没有原生引擎"。

### 10.6 越狱方向"垃圾"本质（一句话）

operit2 iOS 的越狱集成**骨架是对的**（trustcache 签名、ios-mcp tweak、/var/jb 感知都到位），但**执行模型是反的**：把更难、更真、probe 已证明可用的系统 shell 默认丢掉，让 AI 跑在模拟器里，还用自相矛盾的注释掩盖这个选择。这是"**能力有了，工程判断歪了**"——比"纯没做"更该骂，因为修起来只需把 `primaryBackend()` 在 `systemShellAvailable` 时返回 `SystemShell`，却没人动。

---

## 十一、插件生态方向：Android 原生市场 vs iOS 路径重写 shim（越狱方向最实的结构性垃圾）

> 这一轮挖的是 plugin 生态——对越狱方向最关键，因为"能不能在 iPhone 上跑起工具"直接决定 operit2 jailbreak 版有没有用。结论：operit2 **没有 iOS 原生插件层**，直接继承了 operit1 的 Android 插件市场，再用**字符串级路径重写**去糊平台差；而路径重写**结构上补不了 Android 框架/命令调用**。README 与 HANDOVER 自己都承认这是"装得上却跑不动"的根因。

### 11.1 operit2 iOS 的插件兼容层（源码 + 文档自证）

- `operit2-src/README.md:49`：**"市场插件（`.toolpkg`）绝大多数按 Android 编写。本 fork 提供两层路径兼容与一个只读分析器，但能力边界必须清楚"**。
- `README.md:51-55` 三机制表里，**路径兼容层只做"字符串替换"**；转换器是"与上一层同一个函数的两个时机，非两套机制"；转换分析"不转换任何东西，只做预判"。
- `README.md:57`（核心限制，原文）：**"兼容层只治路径，治不了 API 调用。安卓专属 API（AndroidUtils 5类26方法、OkHttp、Java桥、adb）依赖 `pm`/`getprop`/`settings`/`screencap`/`svc`/`input`/`reboot` 等命令，这些在 iOS 上不存在——路径改得再对，一调用就崩。"**
- `HANDOVER.md:579-587`：兼容层（运行时 `AndroidPathRewriter.rs: rewrite_android_paths()`）+ 转换器（安装期 `AndroidToolPkgPathRewriter.rs`，**只遍历 ZIP 条目、调用同一个 `rewrite_android_paths()`**）是同一份实现两个时机；转换器对加密条目直接跳过（靠运行时兜底）。
- `HANDOVER.md:591`：运行时层改内存副本、不动磁盘；且 **shell 命令不走 VFS**（`Tools.System.shell("find /sdcard/...")` 直接碰真实文件系统），需 `rewrite_vfs_mount_paths` 单独映射。接线共 4 处（市场安装/本地导入/运行时 JS 加载 `JsEngine.rs:2728`/shell 执行 `terminal.rs:295`）。
- `HANDOVER.md:595-599`：标题"⚠️ 兼容层只治路径，治不了 API 调用——这是'装得上却跑不动'的根因"，并点名 `AndroidUtils.script.js` 文件头自写"requires Shizuku service…底层全是 shell 命令"。

### 11.2 operit1 的插件系统（对照：平台原生，不靠重写）

- **原生 QuickJS 引擎**：`quickjs/` 是独立 JNI 模块（`quickjs/README.md:3-7`、`quickjs_jni.cpp`、`CMakeLists.txt` 取上游 QuickJS C 源码编译）；Kotlin 封装 `QuickJsNativeRuntime.kt:56`（`require(handle != 0L) { "Failed to create QuickJS runtime" }`）+ `OperitQuickJsEngine.kt:15`（Closeable，eval/call/timer 全有）。
- **Java Bridge 接口契约**：`docs/doc-src/dev-core/JAVA_BRIDGE_INTERFACE.md:3` 是"QuickJS + Java Bridge 的接口契约"——插件可经桥直接调 Android API。
- **插件是 Android 原生内容**：`AndroidUtils.script.js`（5类26方法）底层全 shell 命令，依赖 `pm`/`getprop`/`screencap`/`svc`/`input`/`reboot`/`settings`——**这些命令在 Android 上真实存在**，Shizuku 提供 ADB 级权限（`shell_identity_launcher` root→shell 降级）。所以 operit1 的 `.toolpkg` 在原生平台上**直接跑**，无需任何路径重写。
- 工具包体系：`TOOLPKG_FORMAT_GUIDE.md` 描述 `.toolpkg`=ZIP 格式，`registerToolPkg`/`resource`/`ui`/`hook` 完整生命周期；`tools/toolpkg/debug_toolpkg.py` 是调试器。整个生态围绕 Android 构建。

### 11.3 这一轮的真"垃圾"点（结构性）

| 维度 | operit1（Android 原生） | operit2 iOS（jailbreak） |
|---|---|---|
| 插件引擎 | 原生 QuickJS JNI + Java Bridge | 同样有 JS 引擎（`JsEngine.rs`），**引擎本身没问题** |
| 插件内容来源 | 为 Android 编写、Android 上原生跑 | 继承同一格式，但内容**仍是 Android 原生**，调 iOS 不存在的命令/API |
| 跨平台桥 | 无需要（同平台） | `AndroidPathRewriter` 只做**路径字符串替换**（`/sdcard`→`/mnt/android/sdcard`）+ 安装期 ZIP 遍历壳 |
| 能跑的插件 | 全部（命令/API 都真实存在） | 仅**纯路径字面量**插件可跑；凡调 `pm`/`getprop`/`screencap`/`AndroidUtils`/`Shizuku`/`OkHttp` 的**装得上、一调用就崩** |
| 项目自知 | — | README/HANDOVER **白纸黑字承认**"装得上却跑不动是根因"，仍照发 |

**结构性结论**：
1. **operit2 从没建 iOS 原生插件 substrate**——没有 iOS 版 `AndroidUtils`（iOS 对应物应是 `ios-mcp` tweak / `jbctl` / `operit-sb` 的能力封装），没有把 `pm`/`screencap`/`input` 映射到 iOS 等价物（如 `uiopen`/`screencapture`/`activated`）。它把 Android 市场**原样搬来 + 路径糊缝**，让越狱 iPhone 背一个跑不动的 Android 插件库。
2. **路径重写是错误抽象层**：补平台差的正确位置是"能力映射"（命令/API 翻译），operit2 却选了"文本替换"——后者对字面路径有效，对运行时 API/命令调用完全失效。等于给柴油车灌汽油还只改了油枪标签。
3. **已知不可用仍发布**：README 列了"朋友圈打不开""60s 卡死""AndroidUtils 零实现误报"等已知问题，仍把 Android 市场当卖点上架。这是"**垃圾文化**"——文档诚实地写了限制，工程却不修，用户拿到手发现大部分插件是死的。

### 11.4 越狱方向插件层的正确修法（若真要做）

不是"改路径重写器"，而是**建 iOS 原生能力层**：
- 把 `AndroidUtils` 的 26 方法映射到 iOS 等价（截图→`screencapture`/ios-mcp、输入→`ios-mcp` tap、设置→`defaults`/`cfgutil`、包管理→`uicache`/`appinst`）；
- `pm`/`am` 这类 Android 命令用 `ios-mcp` + `operit-sb` tweak 的 MCP 工具替代，而非 shell 字面量；
- 引擎层已有（`JsEngine`），只需把 JS bridge 从"Android Java Bridge"换成"iOS host bridge"（已有 `hosts/ios/src/tools/*` 雏形，但没接到插件 SDK）。
- 短期止血：市场前端**按平台过滤**，iOS 只展示"纯路径/已验证"插件，别把 Android-only 插件列给越狱用户（避免"装得上跑不动"的观感崩塌）。

### 11.5 本章一句话

operit2 jailbreak 版的插件生态是**借来的 Android 衣服穿在越狱 iPhone 上**——引擎有、格式同、但内容和能力层全是 Android 的；一道字符串路径重写补不了平台鸿沟，结果是市场里大部分插件"装得上、一调用就崩"。项目自己写了限制说明却照发，这才是越狱方向最该骂的"垃圾"：不是不会做，是**用错的方法 + 明知不可用仍发布**。

---

## 十二、可观测性 / 日志方向：先纠错，再定位真垃圾

> 先纠正 §三.4 / §八.6 旧结论：**operit2 不是"无日志"**。它有一套相当完整的 `AppLogger`（`core/crates/operit-util/src/AppLogger.rs`），且 iOS 上文件日志**真的绑定了**（`OperitApplication::newWithContext` → `AppLogger::configure_log_files`，日志落到 `runtimeRoot/logs/operit.log` + `logs/toolpkg.log`）。所以"无日志"这句要删。但可观测性的**真垃圾**在三个地方：**(a) ANR/卡死看门狗是空壳**——而 operit2 的招牌 bug 正是 60s 卡死，正属它该抓的类；**(b) 无 panic hook**，Rust panic 在 iOS 上崩但不进任何日志文件；**(c) AppLogger 自身三处自伤**（全局锁 / 无上限内存 / 不抓堆栈）。这三点叠起来，解释了为什么之前的 60s 卡死是"靠读源码猜 + 临时探针"而非"靠 app 遥测"修的。

### 12.1 operit2 的日志框架（实际能力，源码实读）

`AppLogger.rs` 其实不弱：
- **分级齐全**：`v/d/i/w/e/wtf` 对应 Android 优先级（VERBOSE=2…ASSERT=7，9-20 行）。
- **三种落点**：控制台（`print!`/`eprint!`，按级别）、文件（`writeFile` append，经 `FileSystemHost` 抽象）、内存（`entries: Vec<LogEntry>`，可被 `entries_json()` 取走给前端展示）。
- **错误链**：`println_with_error` 把 `error.source()` 一路链出来（`error_chain`，435-444 行）。
- **ToolPkg 结构化 tag**：`format_package_log_line`（350-389 行）从消息里抽 `toolPkgId`/`script`/`plugin`，打成 `[PKG:][SCRIPT:][PLUGIN:]`——这点是真不错，比纯 tag 强。
- **文件日志 iOS 上确实活**：`OperitApplication.rs:93-95` 把 `runtimeRoot/logs/operit.log` 绑进 `configure_log_files`，正常越狱设备上文件落盘。

**所以"日志有没有"不是问题，"日志能不能在出事时帮你定位"才是。**

### 12.2 真垃圾 1：ANR 看门狗是空壳（最该骂）

- operit2：`core/crates/operit-util/src/AnrMonitor.rs` 全文就 **2 行**——
  ```rust
  #[derive(Debug, Clone, Default)]
  pub struct AnrMonitor;
  ```
  **零实现**。名字从 operit1 搬来，身子没搬。
- operit1：`app/.../util/AnrMonitor.kt` 是 **400 行真看门狗**：
  - 100ms 采样主线程（`SAMPLING_INTERVAL_MS`）；
  - 500ms 警告 / 1000ms ANR 阈值（`WARNING_THRESHOLD_MS` / `ANR_THRESHOLD_MS`）；
  - 超阈值 `captureFullThreadDump()` 抓**全线程栈** + `analyzeStackTrace()` 聚焦自身包调用；
  - 落盘 `anr_report_<时间戳>.txt`，含设备/内存/`stackTraces` 历史/调用者信息（380-426 行）。
- **讽刺点**：operit2 的招牌 bug 是"插件 60s 卡死"（worker 线程自死锁），这**正属 ANR 看门狗该抓的那一类**。如果 operit2 的 AnrMonitor 不是空壳，60s 卡死当场就能抓到主线程/worker 栈，而不是让人读源码猜了 20h。空壳 AnrMonitor = 把最能缩短 MTTR 的工具直接删了。

### 12.3 真垃圾 2：无 panic hook（崩溃对 app 日志不可见）

- 全树 **零 `std::panic::set_hook`**（grep 仅命中：`quickjs-wasm-rs` 的 `panic!("...")` 宏调用、`RuntimeStorageHost` 的 `None => panic!`、`AndroidJni.rs` 的 `catch_unwind`——后者是 JNI 边界、Android-only）。
- 后果：iOS 上任何核心 Rust panic = 进程崩，panic 信息只走 **stderr**。在发布 app 里 stderr 不进 `operit.log`、不进用户可见面板。等于**崩溃不留结构化记录**，只能去抓系统崩溃报告 / 设备 console。
- 这正是上一轮 60s 卡死的取证路径：不是从 app 日志看到"哪里死锁"，而是 `kill` 后看系统看门狗砍了 render、再读源码反推。**有日志框架，但崩的那一刻它接不住**。
- 对照：operit1 在 Android 上享有平台级 `Thread.setDefaultUncaughtExceptionHandler` + tombstone + `reportNonFatalError`（`MessageProcessingDelegate.kt:180`），崩溃有去处。operit2 iOS 连个 `set_hook` 都没装。

### 12.4 真垃圾 3：AppLogger 自身三处自伤（出事时反而添乱）

1. **每次写日志都抢全局 Mutex**：`write_entry`（247 行）及所有访问器都 `state().lock().expect("AppLogger mutex poisoned")`（43 行 `OnceLock<Mutex<LoggerState>>`）。
   - 与 §九/§十 指出的 terminal Mutex、`getOrCreatePackageManager` Mutex **同一个反模式**：全进程日志串行化；且 `expect("poisoned")` 意味着**一旦某次日志在持锁时 panic，之后所有日志调用全 panic**——日志系统能自我级联崩。
   - 在高并发（AI 流式 + 插件 + 终端同时打日志）下这是 contention 点，不是无锁环形缓冲。
2. **内存 `entries` 无上限**：`LoggerState.entries: Vec<LogEntry>`（40 行），`write_entry` 每行列 `guard.entries.push(entry)`（259 行），**没有 ring buffer、没有 cap**。`entries()`（160 行）/ `entries_json()`（169 行）还 `clone()` 整个 Vec。长会话 = 内存只增不减的泄漏；且 JSON 快照越拉越重。
3. **错误不抓堆栈**：`println_with_error` 只用 `error_chain` 链 `.source()` 的**错误消息文本**（435-444 行），**不抓调用栈**。`get_stack_trace_string`（237-239 行，用 `Backtrace::capture()`）存在但**从没被日志路径调用**。结果：error 日志只告诉你"什么错了"，不告诉你"在哪错的"——对定位死锁/崩溃几乎没用。要堆栈得手动调 `get_stack_trace_string`，而没人调。

附带小问题：**无级别过滤**（`is_loggable` 242-244 行恒 `true`）→ 生产环境无法压低 verbose/debug；**每次日志同步 `writeFile` append 一行**（292-294 行，持锁内、无批量、无异步 channel）→ 磁盘慢时阻塞调用线程。

### 12.5 对照表（可观测性）

| 维度 | operit1（Android） | operit2 iOS |
|---|---|---|
| 日志分级 | `Log.d/w/e` + `ShowerLog`(带 throwable 变体) | `AppLogger` v/d/i/w/e/wtf（更全） |
| 日志落盘 | logcat 系统环形缓冲 + 文件 | `runtimeRoot/logs/operit.log`（iOS 上已绑）✅ |
| ANR/卡死看门狗 | **400 行真看门狗**，抓全线程 dump 落盘 | **2 行空壳 → 已填（Fix C，心跳看门狗 + 锁-free 落盘 operit.log）** ✅ |
| panic/崩溃捕获 | 平台 `UncaughtExceptionHandler` + tombstone + `reportNonFatalError` | **零 `set_hook`**，崩溃只走 stderr ❌ |
| 错误是否带堆栈 | Java 异常自带栈 | `println_with_error` 只链 `.source()` 消息，不抓栈 ❌ |
| 日志并发模型 | Android logcat 无锁缓冲 | 全局 `Mutex` 每次写都抢 + `.expect("poisoned")` ❌ |
| 内存占用 | logcat 环形缓冲有界 | `entries` Vec 无上限泄漏 ❌ |

### 12.6 可观测性方向"垃圾"本质（一句话）

operit2 iOS **有日志框架、且 iOS 上文件日志是活的**——这点比"无日志"强，先纠正。但它在"出事时帮你定位"这件事上**几乎全废**：卡死看门狗是空壳（而 60s 卡死正是它该抓的）、崩溃不进日志（无 panic hook）、错误不抓堆栈、日志自身还背着全局锁 + 无上限内存。**等于装了监控摄像头但没通电**：平时能写文件，真出事时既抓不到现场、崩了也不留记录。修这三处（填 AnrMonitor + 装 panic hook + 给 AppLogger 去全局锁/加 ring buffer/错误自动抓栈）是 §七 优先级 #1"先做可观测性"的真正落点——不是再加日志，是把现有日志在失败时接住。

---

## 十三、流式子系统对比：operit1 的统一 Flow vs operit2 的"三套互不连通的流"（越狱方向最实的可取消性缺口）

### 13.1 先说"流"在这个 app 里管什么

"流式"指**数据一边产生一边往 UI 送**，而不是等全部算完再一次性返回。对越狱 app 最要命的两种流：

1. **AI 回复 token 流**——大模型一个字一个字吐，UI 要边收边显示（打字机效果）。
2. **工具执行输出流**——AI 调 shell / 跑文件 / 做 UI 自动化，命令可能跑几秒到几十秒，输出（日志、进度、报错）要边跑边回传，否则用户看不到进度、也不能中途取消。

第二种在越狱设备上尤其重：长 shell 编译、大文件传输、多步 UI 自动化，都是"慢且长"的活。这一章重点就在第二种——operit2 在这块是断的。

### 13.2 operit1 的流式子系统：全栈一套 Kotlin Flow 贯穿

operit1（Android/Kotlin）用的是语言原生的 **Kotlin Flow**，从配置到聊天到工具事件，是**同一套抽象**：

- **配置/状态流**：`ApiConfigDelegate.kt` 里**几十处** `MutableStateFlow`（是否启用工具、模型名、上下文长度、feat toggle 全响应式）；`ChatHistoryDelegate.kt` 的 `_chatHistory` / `_currentChatId`、`CurrentChatWindowController.kt` 的多个 `MutableStateFlow`——UI 自动跟着状态变。
- **AI 文本流**：`ChatServiceCore.kt:302` `getResponseStream(chatId): SharedStream<String>?`，本质是 `SharedFlow<String>`（**热流**：多个 UI 同时订阅同一段回复，新订阅者能 replay 已发部分，不会漏字）。
- **消息/分段流**：`WaifuMessageProcessor.kt` 大量 `stream { emit(...) }`——用 Flow 的 builder 把 TTS/角色分段一行行吐出来，中间还能插"打字中"队列。
- **流操作符**：`ModelConfigAutoSaveSupport.kt:178` `.debounce(...)`——节流/背压原语直接可用（Flow 自带 `map`/`filter`/`buffer`/`debounce`/`flatMap`）。
- **取消**：配合 `withTimeout`（第九章 `ShowerController:152` 等）+ `ChatServiceCore.kt:287/292` 的 `cancelMessage` / `cancelMessageForDestructiveMutation`——**流是协程原生，取消是一等公民**：取消一个 chat，它底下所有流（AI token、工具、历史）一起停。
- **事件总线**：`AttachmentDelegate.kt` 用 `MutableSharedFlow` 的 `_toastEvent.emit(...)` 发 toast 事件，跨模块解耦。

一句话：operit1 把"流"当**一等公民基础设施**——任何异步数据（状态、文本、工具事件、UI 信号）都过同一套 Flow，所以加背压、加取消、加多播，是"调一个操作符"的事。

### 13.3 operit2 的流式子系统：三套互不连通的模型

operit2（Rust core + Flutter/Dart UI）的"流"不是一套，是**三个来源、三种风格、彼此不连通**：

1. **状态流（自研）**：`core/crates/operit-store/src/PreferencesDataStore.rs` 自己实现了一套 `Flow` / `StateFlow`——有 `collectWithCancellation` / `FlowCancellation` / upstream 订阅 / `Mutex` 保护。认真，但**缺标准操作符**（`map`/`filter`/`debounce`/`flatMap` 全得自己写），且又踩全局 `Mutex`（和 §九/§十/§十二 同一个反模式）。这套只管配置/偏好状态。
2. **字节流（FFI C 风格回调）**：`core/crates/operit-host-api/src/lib.rs:1375` 的 `HttpStreamChunkCallback`，到 Windows host 是 `openHttpByteStream(onOpened, onChunk, onClosed)`（`hosts/windows/src/tools/http/mod.rs:13-31`）。这是**C 风格的函数指针回调**——数据到了调你给的函数。**不是可组合的 async stream**，没有背压、没有 map/flatMap，取消得各自手工管。
3. **零星 async stream**：`operit-link-access/src/lib.rs:30` 用了 `futures_util::StreamExt`——证明 Rust 侧**有**真正的 async Stream 能力，但只在这一个模块零星出现，**没贯穿到核心的聊天/工具层**。

**关键缺口——工具执行输出流：没有。** 第九章已实锤：`ProviderRuntimeSupportService.rs:194` 的 `executeTool` 是同步 `getOrCreatePackageManager().lock().expect("...poisoned")`，AI 调工具时**整段执行完才把结果一次性返回**。60s 卡死那次，就是工具在 worker 线程阻塞、UI 拿不到任何中途输出、也取消不了——直到系统看门狗砍 render。

### 13.4 对照表（流式子系统）

| 维度 | operit1（Android/Kotlin） | operit2 iOS（Rust+Flutter） |
|---|---|---|
| 流抽象 | **单一 Kotlin Flow 贯穿全栈** | **三套分裂**：自研 Flow(状态) + C 回调(传输) + 零星 futures Stream |
| AI token 流 | `getResponseStream` SharedFlow（热流、replay、多播） | 有（Rust 侧疑似 FFI 回调 / Flutter Stream，本次未深挖 Dart 边界） |
| 工具执行流 | Flow + `withTimeout` + Job 取消兜底 | **无**：executeTool 同步阻塞，整段返回 ❌ |
| 背压/节流 | Flow 原生 `debounce`/`buffer` | C 回调无背压；自研 Flow 无操作符 ❌ |
| 取消模型 | 协程 `cancel` 一等公民，流随 chat 一起停 | 仅自研 Flow 有 `FlowCancellation` token；host 回调流取消断档 ❌ |
| 多播/replay | SharedFlow 多订阅者 replay | 配置流自研 StateFlow 有 replay；回调流无 |

### 13.5 越狱方向"垃圾"本质（一句话）

operit2 的 streaming **只覆盖了两头轻的（AI 文本、HTTP 字节），漏掉了越狱设备上最重的（工具执行输出）**。而工具执行不流式的后果，正好就是前面几章反复撞到的病根：**用户看不到进度、不能中途取消、没有输出限额 → 直接触发 60s 卡死 / 无输出限额**。更深的问题是**抽象分裂**——状态用自研 Flow、传输用 C 回调、零星 futures Stream 各管各的，没有一套统一流贯穿 app，所以"给工具加流式 + 取消 + 背压"不是加个操作符，而是得在三套模型里各改一遍、再把它们接起来。operit1 是"全栈一套 Flow，取消/背压调一个操作符"；operit2 是"想给工具加流式，先得把三套流打通"。这才是越狱 app 难维护、难加可取消性的根——**不是不能做，是架构没给做的基础**。

> 诚实标注：operit2 的 AI token 流到底怎么接回 Dart UI（FFI 回调还是 Flutter Stream），本次未深挖到边界；但"工具执行输出流缺失"已由 60s 死锁实锤，这是越狱方向最相关的一块，结论不受影响。operit1 的工具执行也未必 100% 流式，但它有 `withTimeout`+Job 取消+全响应式兜底，而 operit2 的兜底在 FFI 回调模型里是断的。

### 13.6 下一步可挖

- operit2 的**屏幕时间 / 自动化那 7 件原子工具**在越狱 iOS 上怎么落地的（除 `device_automation.rs` 的 ios-mcp 通道外还有哪些），它们是否也踩同步阻塞 + 无流式；
- 或回 operit1 看 `MessageProcessingDelegate` 的工具执行到底是不是真 Flow 流式（验证 §13.5 标注的"operit1 也未必全流式"假设）。

你说方向。

---

## 十四、地基架构总收口：四大裂缝（前面散点上升到骨架层）

前面九章到十三章散点挖了终端、工具并发、越狱集成、插件、可观测性、流式子系统。这一章把它们**归到地基层**——这些"垃圾"不是孤立 bug，是同一个骨架裂缝在不同功能上的表现。先看四个裂缝的源码实据，再标注 operit2 地基里**哪些其实不差**（避免一棍子打死），最后给修复优先级。

### 14.1 裂缝一：依赖注入 / 启动模型 —— 全局单例替代 DI

operit2 的核心应用 `OperitApplication`（`operit-runtime/src/core/application/OperitApplication.rs`）的 bootstrap：

- **构造时硬 `new` 全部依赖**：L1–46 全是 `use`，`newWithContext` 里直接 `HostManager::new()` + `setDefaultHostRuntimeTaskSchedulerHost` / `setDefaultHttpHost` / `setDefaultRuntimeStorageHost` / `setDefaultRuntimeStoreRootConfig` ——**所有 host 依赖通过全局 `setDefault*` 注册成进程级可变单例**。
- **进程级全局可变单例**：L53 `static HOST_MANAGER: OnceLock<Mutex<Option<HostManager>>> = OnceLock::new();` —— host runtime 是**全进程唯一、可变、靠 Mutex 保护**的全局。

后果（地基级）：
1. **不可测**：没法在单测里注入假 host；任何依赖 host 的代码都得真跑在 iOS/Android 环境里。
2. **不可换**：host 行为硬编码进全局，多 host（ios/android/web）只能靠 feature flag 编译期切，运行期无法替换/隔离。
3. **并发靠全局锁**：`setDefault*` 写全局 + 各处 `.lock()` 读全局 → 又把并发问题推给全局 Mutex（和 §九/§十/§十二 同款反模式，只是从"工具层"升到"启动层"）。

operit1（Android/Kotlin）虽也是单体 App，但**没有这种进程级可变全局 host 单例**——它的平台能力靠 `Context`/`Service` 传参 + `CoroutineScope` 把生命周期结构化（见 14.3）。关键差异不在"有没有单例"，在**operit2 把核心 host 依赖做成了可变的全局可变状态**，而 operit1 的平台依赖是显式传入、随 scope 消亡。

### 14.2 裂缝二：错误处理范式 —— 碎片化 + panic 文化

- **无跨 crate 统一错误类型**：全树 grep `enum OperitError` / `OperitResult` / `OperitError::` **零命中**。`thiserror::Error` 散落在各 crate 各自定义（operit-store 7 处、operit-local-models 多处、operit-providers 的 `AIService.rs` 等）——**错误类型碎片化、不贯穿**，跨 crate 调用时错误要么 `anyhow` 装箱、要么 `.expect()` 直接 panic。
- **panic 文化**：`hosts/ios` 里 `operit_agent_daemon.rs` / `ios_mcp.rs` / `lib.rs` / `device_agent.rs` 全部直接 `.expect()` / `.unwrap()`（同步 Mutex 那句 `"...poisoned"` 就是典型）。核心执行路径靠 panic 而非 `Result` 贯彻 —— 一旦出错就是崩，且崩不进日志（呼应 §12 无 panic hook）。
- 对照 operit1：`FloatingChatService.kt:215` `Thread.setDefaultUncaughtExceptionHandler(customExceptionHandler)` —— **进程级未捕获异常兜底**，崩溃有 handler 落盘；全代码 `try/catch (e: Exception)` 且**显式区分 `CancellationException`**（取消 vs 业务异常，§13.2 的 `cancelMessage` 依赖这个区分）。

一句话：operit1 把"错"当一等公民（顶层兜底 + 区分取消/业务）；operit2 把"错"当意外（panic 了事，碎片化错误类型接不住跨层传播）。

### 14.3 裂缝三：并发范式 —— 手搓 Mutex + 同步/异步混用，无统一 runtime

- **手搓 `Arc<Mutex<...>>` 为主流**：`ios_mcp.rs:33/34` `Arc<Mutex<bool>>` / `Arc<Mutex<Option<(f64,f64)>>>`；`PreferencesDataStore.rs` 全文 `Arc<Mutex<dyn FnMut(T)>>` 存回调；windows bluetooth `Arc<Mutex<HashMap<...>>>`。无锁并发（`RwLock` / `dashmap` / `ConcurrentHashMap` 等价物）几乎不用。
- **同步 / 异步 Mutex 混用**：`OperitApplication.rs:47` `use std::sync::{Arc, Mutex, OnceLock}` + L48 `use tokio::sync::Mutex as AsyncMutex` + L59 `chatRuntimeHolder: Arc<AsyncMutex<ChatRuntimeHolder>>`——**同步世界和异步世界在同一个 struct 里并存**，没有统一调度器把它们串起来。
- **`OperitApplication` 是同步构造**：`newWithContext` 非 async，tokio 只在底层 crate 局部用（command-core/runtime/tools/workflow-core/providers/link 等带 `rt` feature），**没有全局 tokio runtime 把 app 生命周期管起来** → 同步世界（全局 Mutex、构造时 new）与异步世界（底层 crate 的 async）**割裂**，取消信号没法跨边界传播（直接连到 §13.3 的"C 回调流取消断档"）。

对照 operit1：**结构化并发一等公民**。`TermuxCommandResultService.kt:44` / `FloatingChatService.kt:95` / `ToolboxPlugin.kt:139` 全是 `private val xxxScope = CoroutineScope(SupervisorJob() + Dispatchers.Main/Default)` —— 每个 Service 自带 scope、`SupervisorJob` 保证子任务失败不拖垮父、**取消沿 scope 树自动传播**。这是"取消/生命周期"的骨架，operit2 在 Rust 侧没有等价物（`FlowCancellation` 只是 token，没有 scope 树，§13）。

### 14.4 裂缝四：取消 / 生命周期树 —— 缺结构化取消骨架

这是前三裂缝的汇合点：
- 错误靠 panic（14.2）→ 取消等于"等系统看门狗砍"（§九 60s 死锁）；
- 并发靠全局锁 + sync/async 混用（14.3）→ 取消信号跨不了 sync/async 边界（§13.3）；
- host 全局单例（14.1）→ 依赖的生命周期绑定进程，无法随 scope 取消。

operit1 用 `SupervisorJob` 取消树把这三条一次性解决：chat 取消 → 底下所有 Flow/工具/网络请求随 scope 一起停（§13.2）。operit2 的 `FlowCancellation` token 只是一个布尔/句柄，**没有 scope 树**，所以"取消一个工具执行"在 sync/async 割裂 + 全局锁的骨架里根本传不下去。

### 14.5 诚实标注：operit2 的地基里哪些其实不差（别一棍子打死）

前面几章容易给人"operit2 全垃圾"的错觉，地基层必须还它公道：

1. **crate 分层清晰**：19 个 core crate（command-core / runtime / store / tools / providers / js-bridge / host-api …）边界分明，比 operit1 平铺 11 个 java package **更模块化**。
2. **host-api 抽象层是好设计**：`operit-host-api` crate 把平台能力抽象成 trait（HostManager / HttpHost / RuntimeStorageHost …），方向**比 operit1 直接调 Android API 更对**——问题不在抽象本身，在 14.1 的"接线方式"（全局单例毁了可替换性）。
3. **有 thiserror**：错误至少用类型承载，比裸 `Result<String>` 强（只是没统一成跨 crate 类型，见 14.2）。
4. **有 tokio + futures**：现代异步能力**是有的**，只是没被提升为"应用级 runtime"（14.3），属于"有能力没用好"。
5. **有代码生成调度层**：`operit-core-proxy` + `generated_core_dispatch.rs` 用代码生成做核心 dispatch，减少手写胶水——这是 operit1 没有的工程化投入。

结论：operit2 的**抽象方向不差，差在"抽象怎么落地"**——好的 host-api 被全局单例接线毁了可替换性；好的 tokio 没提升为应用 runtime；好的 thiserror 没统一成跨层错误类型。是"设计 7 分、落地 3 分"。

### 14.6 地基修复优先级（§七 的骨架升级版）

按"先地基后功能"，且每条都是前面裂缝的落点：

| 优先级 | 地基裂缝 | 具体动作 | 解决的现象 |
|---|---|---|---|
| 1 | 错误（14.2） | 定义跨 crate `OperitError` + 顶层 `std::panic::set_hook` 接 AppLogger（接 §12） | 崩溃留痕、跨层错误可传播 |
| 2 | 并发（14.3） | `OperitApplication` 改 async，统一到 tokio runtime 管生命周期，取消 sync/async Mutex 混用 | 取消信号能跨边界 |
| 3 | DI（14.1） | host 依赖从全局 `OnceLock<Mutex>` + `setDefault*` 改显式传入（至少 host 可替换/可测） | 可单测、多 host 隔离 |
| 4 | 取消（14.4） | 把 `FlowCancellation` 接成真正 scope 树，串起工具/聊天/网络 | 一处取消全链路停 |

这四条没完，**别加任何新功能**（屏幕时间/自动化那 7 件工具、新市场插件都先压住）——在裂缝地基上加功能 = 在流沙上盖楼，下一个 60s 死锁只是时间问题。

### 14.7 下一步可挖（仅地基，不碰功能）

- `operit-core-proxy` 代码生成的 `generated_core_dispatch.rs` 到底生成了什么、是否也依赖全局单例（14.1 的接线问题是否蔓延到调度层）；
- async 迁移代价评估：把 `OperitApplication` 改 async 会波及哪些 host 边界（Dart FFI / ios_mcp / daemon）；
- 或回 operit1 看它有没有真正的 DI（Hilt / 手动 scope 注入），对照 14.1 坐实"operit1 的 host 依赖是否也全局"——避免我把 operit2 的单例问题说成独有。

你说方向。

---

## 十五、地基广挖续：线程模型 + 测试地基 + 依赖中心度 + 对 §14.1 的诚实修正

第八轮「深挖广挖」展开后，拿到四个 §14 没覆盖或需修正的地基事实。全部源码实据。

### 15.1 线程 / 任务模型裂缝（§14 漏掉的新维度）

operit2 的并发不是「统一调度器管线程」，而是**裸 `std::thread::spawn` + 手动 Mutex/通道 + 零星 tokio** 的混搭。全树 spawn 点统计：

- **工具执行在裸线程跑、无超时无取消**：`operit-tools/src/tools/AIToolHandler.rs:1712` `std::thread::spawn(move || { authorized_on_worker, isolated_on_worker })`——鉴权+隔离在裸 OS 线程，外层没法 abort（正是 §九 60s 死锁的 worker 线程）。
- **daemon 是裸死循环 server**：`hosts/ios/src/bin/operit_agent_daemon.rs:452` `thread::spawn(|| loop {...})`、`:558` `thread::spawn(move || handle_client(stream))`——裸 accept 循环，**无优雅关闭、无取消句柄**，只能自己退出 loop。
- **各 host 的 runtime/terminal/PTY 全裸线程**：`hosts/ios/managed_runtime.rs:170/181`、`hosts/common/operit-host-native-terminal/src/lib.rs:696`、`hosts/common/operit-host-native-http/src/lib.rs` 多处 `thread::spawn` / `thread::Builder::new()`。
- **tokio 只在网络层零星**：`operit-link/src/http.rs:84/379` 两处 `tokio::spawn`，`operit-util/GithubReleaseUtil.rs` 的 `spawn_blocking`——**核心业务逻辑（工具/daemon/PTY）几乎不用 tokio**。
- 注：`operit-workflow-core/WorkflowExecutor.rs:486` 注释 "no std::thread, so Wasm boundary guards pass"——说明作者知道裸线程和 WASM 边界冲突，却仍大面积用裸线程而非统一 async。

后果（地基级）：**裸 `std::thread` 无法被取消**（没有 tokio 的 `JoinHandle::abort` / `CancellationToken`），生命周期只能靠线程自己退出 loop。这正是 60s 死锁「外层看门狗砍 render 才解」的根——worker 阻塞时，**没有任何结构化机制能从中途取消它**。对照 operit1 的 `CoroutineScope(SupervisorJob())`：取消沿 scope 树自动传播到所有子任务（§14.3）。

### 15.2 依赖中心度：runtime + core-proxy 是「上帝 crate」

遍历 `core/crates/*/Cargo.toml` 统计各自依赖几个内部 `operit-` crate：

| crate | 内部依赖数 |
|---|---|
| operit-core-proxy | 14 |
| operit-runtime | 12 |
| operit-command-core | 9 |
| operit-tools | 8 |
| operit-providers | 8 |
| operit-store | 6 |
| … | ≤5 |

关注点没均匀分散——`operit-runtime`（12）把所有东西 `new` 在一起（呼应 §14.1 的 `OperitApplication`），`operit-core-proxy`（14）是代码生成调度层、依赖一切做 dispatch。这俩是**中心枢纽**，任何重构都要动它们——中心化本身就是地基腐烂信号（牵一发动全身）。

### 15.3 全局单例蔓延到 codegen 调度层（坐实 §14.7 假设）

§14.7 担心的「调度层是否也踩单例」**被坐实**：
- `operit-core-proxy/src/RuntimeRemoteLinkService.rs:22` `static AUTO_SYNC_TASK_STARTED: OnceLock<Mutex<bool>> = OnceLock::new();`——核心远程链接服务也用进程级可变全局单例。
- `operit-core-proxy/tests/shared_concurrency_test.rs:210` 并发测试自身调用 `setDefaultRuntimeStoreRootConfig(...)`——连测并发的代码都依赖全局 `setDefault`。

结论：全局单例不是偶发坏味道，已从 `OperitApplication` 渗透进**代码生成的核心调度层**。§14.1 的「全局单例替代 DI」是系统性地基病，不是边缘。

### 15.4 测试地基：数量不差，差在「测不测裂缝区」（重要诚实标注）

- **operit2 有 312 个测试函数**（`#[test]`/`#[tokio::test]`/`fn test_` 全树统计，排除 target/vendor）——**不算少，不能一棍打死「operit2 没测试」**。
- 但 operit1 的测试**覆盖的是裂缝区**：`app/src/test` + `app/src/androidTest` 共 150+ 测试文件，且专门测并发/取消/执行流——`ClaudeProviderCancellationTest`、`ProviderUsageCancellationTest`、`ColdStreamCancellationTest`、`WorkflowExecutorAndroidTest`、`ToolExecutionManagerTest`、`HotStreamTest`、`StreamXmlPluginTest`、`StreamAndroidTest`…
- operit2 的 312 测试**偏无状态纯逻辑**：calculator 表达式解析、markdown 渲染、ChatMarkup 正则、stream JSON/XML converter、serializer round-trip——**裂缝区（工具执行并发/取消、daemon 生命周期、terminal 死锁、60s 卡死）反而没测试覆盖**。
- 所以测试地基的真实差距**不是「有没有」**，是「**测不测最脆的地方**」：operit1 用测试把并发/取消/工作流这些最易碎的链路钉死；operit2 的测试避开了最脆的链路。这直接解释为什么 60s 死锁、daemon 重启循环能悄悄上线——**没有测试拦在裂缝区前面**。

### 15.5 对 §14.1 的诚实修正：operit1 也没真 DI（避免把单例说成 operit2 独有）

回 operit1 grep `@Module|@Provides|@Inject|@Singleton|dagger.hilt|HiltAndroidApp|@Component` —— **零命中**。operit1 **也没有 Hilt / 真 DI 框架**，两边都是手动依赖管理。

修正 §14.1 的表述：operit2 **不是「比 operit1 差在有无 DI」**，而是差在**承载 host 依赖的具体方式**——
- operit2：Rust 进程级**可变**全局单例 `OnceLock<Mutex<Option<HostManager>>>` + 45 处 `setDefault*` 注册（§14.1 / 15.3）；
- operit1：Android 单体常见写法，**显式传参**（Service 构造 / 函数参数 / `Context`），没用「进程级可变全局」这种 Rust 特有的危险模式。

所以「DI 裂缝」应**降级为「全局可变状态裂缝」**：operit2 的地基臭味是 Rust 特有的 `OnceLock<Mutex<Option>>` + `setDefault` 全局注册，不是「缺 DI 框架」本身。operit1 没 DI 但也没踩这种全局可变雷。§14.6 修复表第 3 行「DI」应改为「消除进程级可变全局单例（改显式传参 / 注入），而非引入 DI 框架」。

### 15.6 地基裂缝全景图（§14 + §15 汇总）

| # | 裂缝 | 实证 | 越狱方向后果 |
|---|---|---|---|
| 1 | 全局可变状态 | 111 处 static 可变 + 45 处 setDefault；core-proxy 也踩（§15.3） | 依赖生命周期绑进程，无法随 scope 取消 |
| 2 | 错误碎片化 + panic | 无统一 `OperitError`；hosts/ios 全 `.expect()/.unwrap()` | 崩溃不进日志、跨层错误传不动 |
| 3 | 并发：裸线程 + sync/async 混用 | `AIToolHandler.rs:1712` 裸线程工具；daemon 裸 loop；OperitApplication 同步构造（§15.1/§14.3） | 裸线程不可取消 → 60s 死锁外层救不了 |
| 4 | 取消/生命周期树缺失 | `FlowCancellation` 仅 token 无 scope 树 | 一处取消传不下去 |
| 5 | 依赖中心化 | runtime(12)+core-proxy(14) 上帝 crate | 重构牵一发动全身 |
| 6 | 测试覆盖偏纯逻辑 | 312 测试偏 calculator/markdown/regex；裂缝区 0 覆盖 | 死锁/重启循环能悄悄上线 |

### 15.7 下一步可挖（仅地基）

- **量化裂缝区 0 测试**：列 terminal.rs / ToolPkgToolLifecycleBridge.rs / operit_agent_daemon.rs / managed_runtime.rs 的测试覆盖（确认 15.4 假设）；
- 或回 operit1 看它的 host 依赖到底怎么传（Service 构造 vs Application 级单例）——坐实 15.5「operit1 显式传参」假设，避免又夸大；
- 或评估消除全局单例的最小改动面：把 `setDefault*` 的 45 处改成 `OperitApplication` 持有 + 显式传入，波及哪些 host 边界。

---

## 十六、地基广挖·续二：FFI 边界 / 全局内部可变性 / codegen 上帝模块

继续在地基层广挖，这一轮再开三个 §14/§15 没覆盖的维度，并用一个诚实正项收口。

### 16.1 FFI / panic 边界：19 个 extern "C" 入口只有 3 个守护（最危险裂缝）

Rust↔Dart 的桥在 `apps/flutter/native/operit-flutter-bridge/src/BridgeExports.rs`：

- 全文件 **19 个 `extern "C"` 函数**，跨 FFI 边界回 Dart；
- 但只有 **3 处 `catch_unwind`**（`BridgeExports.rs:6/68/184`，仅构造 + 2 个入口）。

剩下的 **16 个 FFI 入口没有任何 panic 守护**。这比 §12「无 panic hook」更糟一个量级：普通 panic 只是崩进程，而**跨 `extern "C"` 的 panic 是未定义行为（UB）——直接 abort，连 §12 的 AppLogger 都接不到**，进程当场死，设备上表现为「点一下就闪退、日志全无」。

FFI 边界还散在另外 4 个文件：`hosts/ios/src/bridge.rs`、`hosts/android/src/terminal.rs`、`hosts/ohos/src/local_inference.rs`、`apps/flutter/native/operit-flutter-bridge/src/lib.rs`——这 5 个文件的 extern "C" 合计 40 个入口，守护只集中在 BridgeExports 的 3 处。

**对照 operit1（Kotlin/Java，JNI 边界天然结构化）**：所有外部调用都是 `try { … } catch (e: Exception)`（仅 `AttachmentDelegate.kt` 一处就有 10+ 处），且 `FloatingChatService.kt:215` 装了进程级 `setDefaultUncaughtExceptionHandler`。即**任何崩溃在 JNI 边界都被兜成受检异常、进日志、可恢复**；operit2 在 FFI 边界则是「panic 直接 UB」。这是越狱 app 最致命的地基差——用户一次误触就可能整段崩没，且无日志可查。

### 16.2 工具死锁路径压着 `static RefCell` 全局可变单例（把 §9/§12/§14 串成一条链）

`core/crates/operit-tools/src/ToolExecutionManager.rs:1` `use std::cell::RefCell;` + `:26 static TOOL_RUNTIME_CONTEXT: RefCell<Option<ToolRuntimeContext>> = RefCell::new(None);`

这把前面几章的裂缝在**同一条工具执行链**上汇合：

- **§9 60s 死锁**的根 `getOrCreatePackageManager()` 不可重入 Mutex，就在 `ToolExecutionManager` 同一模块族；
- **§14 全局可变单例**的 `OnceLock<Mutex<…>>` 模式，这里换成 `static RefCell<…>`——同样是进程级可变全局，且 `RefCell::borrow_mut()` 在已借出时会 **panic**（内部可变性 Panic 面）；
- **§12 无 panic hook** 的代价在此放大：一旦这个 RefCell 重入 panic，跨不到任何日志，且 FFI 边界（§16.1）还没守护 → 直接 UB 闪退。

一句话：工具执行是越狱设备最重的负载（长 shell 编译、大文件传输、多步 UI 自动化），而它的运行时上下文、包管理器、并发锁**全是全局可变 + 不可取消 + 无 panic 守护**的三重叠加。60s 死锁不是偶然，是这条地基链的设计必然。

全树 `Rc< / RefCell<` 共 **93 处**（`ToolExecutionManager.rs`、`JsEngine.rs`、`JsJavaBridgeDelegates.rs` 等），都是内部可变性 Panic 面，只是多数不在最热路径上。

### 16.3 codegen 上帝模块：generated_core_dispatch.rs 12,385 行（耦合信号）

`operit-core-proxy` 是代码生成调度层（依赖 14 个内部 crate，§15.2 上帝 crate 之一）。它生成的 `generated_core_dispatch.rs` **12,385 行**，位于 `core/target/.../out/`。

含义（诚实标注，避免误读）：

- 这是 **build 产物不是手写的**，所以「12k 行」本身不是 rot，而是**核心 API 表面积巨大且扁平**的证据——core 把上百个方法全部平铺进一个 dispatch 单例，任何一处改动都会触发全量 regen；
- 生成的 dispatch 天然依赖 `operit-core-proxy` 那套全局单例接线（§15.3 的 `static AUTO_SYNC_TASK_STARTED`），所以「调度层」和「全局可变」是绑定的——codegen 把全局单例固化进了生成的代码里，进一步锁死可替换性；
- 对照：operit1 的等价调度是 Kotlin 手写/APT 生成的 `Service` + `ViewModel`，模块边界靠 `Context` 显式传，没这种 12k 行平铺上帝文件。

这是「抽象方向对（codegen dispatch 省手写）、落地差（固化全局单例 + 平铺上帝模块）」的又一例——和 §14.6 给 operit2 的「抽象 7 分、落地 3 分」判词一致。

### 16.4 诚实正项：关键 crate 之间没查到依赖环（粗粒度分层是健康的）

抽样 7 组关键 crate 交叉依赖（`operit-core ↔ operit-runtime ↔ operit-host-api ↔ operit-store ↔ operit-local-models`）——**全部 NONE，无环**。

这点和 §15.2 的「中心化」不矛盾：中心化说的是 `runtime`/`core-proxy` 依赖多（扇出大），分层说的是**没反向依赖回去（无环）**。所以 operit2 的 crate 图在粗粒度上是**有向无环、分层清晰**的——这要还它公道，不能因「中心化」就推断「乱成一团」。真正的问题是「扇出过大 + 中心用全局单例接线」，不是「循环依赖」。

### 16.5 operit1 对照小结（JNI 边界结构化 vs FFI 边界 UB）

| 维度 | operit1（Kotlin/JNI） | operit2（Rust/FFI） |
|---|---|---|
| 跨语言边界崩溃 | `try/catch` + `setDefaultUncaughtExceptionHandler`，变受检异常、可恢复、进日志 | `extern "C"` panic 跨边界 = UB、abort、无日志 |
| 守护覆盖 | 边界级全局守护（进程级 handler） | 40 入口仅 3 处 `catch_unwind` |
| 全局可变 | 显式传参，无进程级可变全局 | `OnceLock<Mutex<Option>>`/`static RefCell` 共 111+ 处 |
| 调度层 | 手写/APT 生成、靠 `Context` 传参 | codegen 12k 行平铺 + 固化全局单例 |
| crate 图 | 平铺 package（§14 指其模块度低） | 19 crate、抽样无环、但 2 个上帝 crate |

### 16.6 地基裂缝总评分卡（§9–§16 全收口）

把前面所有「垃圾」按地基严重度排，并标注越狱方向后果：

| 严重度 | 裂缝 | 实证 | 越狱后果 |
|---|---|---|---|
| 🔴 致命 | FFI 边界无 panic 守护 | 19 extern C 仅 3 catch_unwind（§16.1） | 误触即 UB 闪退、零日志 |
| 🔴 致命 | 工具链三重叠加（全局可变+不可取消+无守护） | ToolExecutionManager:26 static RefCell + §9 Mutex + §16.1 | 60s 死锁是设计必然 |
| 🟠 高 | 全局可变状态 111+45 处 | §14.1/§15.3/§16.2 | 生命周期绑进程、无法随 scope 取消 |
| 🟠 高 | 错误碎片化 + 无统一类型 + 无 panic hook | §12/§14.2 | 崩溃不进日志、跨层传不动 |
| 🟠 高 | 裸线程 + sync/async 混用 | §15.1（AIToolHandler:1712 裸线程） | 裸线程不可取消 → 死锁外层救不了 |
| 🟡 中 | 取消/生命周期 scope 树缺失 | §14.4 | 一处取消传不下去 |
| 🟡 中 | 依赖中心化（runtime12+core-proxy14） | §15.2 | 重构牵一发动全身 |
| 🟡 中 | 测试避开裂缝区 | §15.4（312 测偏纯逻辑） | 死锁/重启循环悄悄上线 |
| 🟡 中 | codegen 平铺上帝模块 + 固化单例 | §16.3 | 改动触发全量 regen、锁死可替换 |
| 🟢 正 | crate 图无环、分层清晰 | §16.4 | 粗粒度健康 |
| 🟢 正 | 19 crate 分层 / host-api trait 抽象方向对 / 有 thiserror+tokio+312 测试 | §14.6 | 抽象地基不差，差在落地 |

### 16.7 下一步可挖（仅地基）

- **量化裂缝区 0 测试**：列 terminal.rs / ToolPkgToolLifecycleBridge.rs / operit_agent_daemon.rs / ToolExecutionManager.rs 的测试覆盖（确认 §15.4 + §16.2 假设）；
- 或回 operit1 看它的 host 依赖到底怎么传（Service 构造 vs Application 级单例）——坐实 §15.5「operit1 显式传参」假设；
- 或评估消除全局单例的最小改动面：把 `setDefault*` 45 处 + `static RefCell` 改 `OperitApplication` 持有 + 显式传入，波及哪些 host 边界；
- 或给 FFI 入口统一加 `catch_unwind` 包裹宏（最低成本止血 §16.1，一行宏覆盖 40 入口）。

你说方向。

---

## 十七、地基广挖·续三：平台 cfg 泄漏 / 持久化无迁移 / unsafe 面

继续在地基层广挖。这一轮三个维度，**其中一个戳破了 §14.6 给 operit2 的「trait 抽象干净」正项**。

### 17.1 平台 cfg 散落核心业务层（戳破 §14.6 正项：trait 抽象是「漏」的）

§14.6 给了 operit2 一个正项：「`operit-host-api` trait 抽象方向对（比 operit1 直调 Android API 强）」。但量化后这个陈述**要降级**——

全树 **314 处 `#[cfg(target_os=…)]` 平台分支**，其中 **36 处直接渗进 `core/crates/` 核心业务层**，并非只在 hosts 边界隔离：

| 核心层文件 | 平台逻辑泄漏点 |
|---|---|
| `operit-tools/src/tools/mcp_runtime/plugins/MCPBridge.rs` | MCP 桥（核心工具）带平台分支 |
| `operit-tools/src/tools/packTool/AndroidToolPkgPathRewriter.rs` | Android 路径重写器（§11）直接进 core |
| `operit-tools/src/tools/packTool/RuntimePackageManager.rs` | 包管理器带平台分支 |
| `operit-tools/src/tools/ToolRegistration.rs` | 工具注册带平台分支 |
| `operit-tools/src/files/PathMapper.rs` | 路径映射（平台相关）进 core |
| `operit-js-bridge/src/javascript/JsEngine.rs` | JS 引擎（核心引擎）带平台分支 |
| `operit-local-models/src/LocalEngineManifest.rs` | 本地引擎清单带平台分支 |
| `operit-host-api/src/lib.rs` | **trait 边界自身**就含 cfg |

含义（地基级）：`operit-host-api` 这个 trait 层**名义上存在、但实际漏**——平台差异没被关在 host 实现里，而是用 `#[cfg]` 直接渗进工具注册、包管理、路径映射、JS 引擎这些**最该平台无关的核心逻辑**。

这恰恰解释了 §11「Android 插件穿在越狱 iPhone 上」的**根**：`AndroidToolPkgPathRewriter` 之所以能进 core 并影响全平台行为，正是因为平台逻辑在核心层就没被真正隔离。operit2 的 trait 抽象是「画了边界线、但平台代码从线底下钻进来了」。对照 operit1：单一 Android 平台、无多端 cfg 爆炸问题，所有平台能力都收敛在 `Context`/Jetpack 适配层，不存在「核心层夹带平台分支」。

修正 §14.6：operit2 的 host-api trait **方向对、但没封住**——漏 cfg 是比「缺 trait」更隐蔽的地基病（有抽象错觉、无隔离实效）。

### 17.2 持久化无迁移框架（接记忆「持久化配置崩首要嫌疑」）

全树 `serde` 相关 **2842 处**，但 `migrate`/`MigrationManager`/`schema_version`/`run_migrations` 仅 **33 处**（且多为单条字段变更、无统一迁移层）。即：

- **持久化结构几乎全靠 `serde` 直接反序列化，没有 schema 版本 + 迁移路径**；
- 任何结构字段增删 / 重命名 → 旧 `*.json` 读回来要么静默错位、要么 `serde` 报错 panic（配合 §12 无 panic hook → 直接崩、零日志）；
- 这正是工作记忆标记的「**持久化配置是新版崩首要嫌疑**」的结构性来源——「新版二进制仍老行为 / 启动即崩」在缺迁移层的代码里是设计必然，不是偶发。

对照 operit1：持久化主用 **ObjectBox（自带 schema 版本 + 迁移回调）+ Room（`autoMigrations`/`Migration` 接口）**——每次 schema 变更强制写迁移，旧数据不会静默错位。operit2 的 `serde` 直读模式在「跨版本升级」这个越狱 app 高频场景（deb 升级、热更新推新二进制）下尤其脆。

`local_runtime_storage.json` 这类 bootstrap 配置在 Rust 源码里**未搜到字面引用**（0 命中，可能经路径拼接常量），但「无统一迁移层」这一结构事实足以坐实记忆里的崩风险假设——无需具体文件名即可判定：凡是裸 `serde::from_str` 读持久化的点，都是静默破坏面。

### 17.3 unsafe 面：188 处，集中在「FFI 裸指针 + 插件包解析」两处高危区

全树 **188 处 `unsafe`**。Rust 项目这个量级不算离谱（FFI 边界本就需要），但**分布位置危险**，且与前面裂缝叠加：

- **FFI 裸指针解引用**（`hosts/ios/src/bridge.rs:19/23`）：`unsafe { operit_ios_ish_terminal_call(command.as_ptr(), request_json.as_ptr()) }` 直接跨 FFI 传裸指针。结合 §16.1「19 个 extern C 仅 3 个 catch_unwind」——**若 `operit_ios_ish_terminal_call` 内部 panic，就是跨 FFI 的 UB**，unsafe 与无 panic 守护双裂缝叠加。
- **插件包解析 unsafe**（`operit-plugin-sdk/src/toolpkg/ToolPkgParser.rs` + `ToolPkgProtection.rs`）：解析**不可信的外部 `.toolpkg`** 用了 unsafe——这是安全敏感路径（攻击者可控输入），unsafe 在此不是性能必要、而是解析实现选择，扩大攻击面。对照 §11 插件生态本就「装得上跑不动」，unsafe 解析器再叠加 = 不可信输入 + 不安全解析的双重风险。

其余 unsafe 多在 `hosts/web/*`（wasm/JS 互操作，合理）与 `hosts/{android,ohos,windows,linux}/*`（平台 FFI，合理）。**真正的地基风险是前两处**：FFI 边界的 unsafe+无守护、插件解析的 unsafe+不可信输入。

### 17.4 诚实正项（本轮）

- §17.1 不是「operit2 没抽象」，是「抽象漏了」——`operit-host-api` trait 仍是个好骨架，问题在 36 处 cfg 越过边界；修起来比「从零建抽象」便宜得多（把 36 处 cfg 收进 host 实现 + 核心层去平台化）。
- §17.3 的 188 unsafe 绝大多数位置合理（平台 FFI / wasm），不能一棍打死「unsafe 多=不安全」；危险面是 2 个聚集点，不是总量。

### 17.5 operit1 对照小结（本轮三维度）

| 维度 | operit1（Android 单平台） | operit2（多端 Rust） |
|---|---|---|
| 平台隔离 | 单一平台，无 cfg 爆炸；能力收敛在 `Context`/Jetpack | trait 层存在但漏：314 cfg、36 渗进 core |
| 持久化迁移 | ObjectBox/Room 自带 schema 版本 + 迁移 | serde 直读 2842 处、迁移层仅 33 处 |
| unsafe 面 | Kotlin/Java 内存安全默认（无裸指针面） | 188 处，高危聚在 FFI 裸指针 + 不可信插件解析 |

### 17.6 更新地基裂缝总评分卡（§16.6 增补）

| 严重度 | 裂缝 | 实证 | 越狱后果 |
|---|---|---|---|
| 🔴 致命 | FFI 边界无 panic 守护 + unsafe 裸指针 | §16.1（19/3）+ §17.3 bridge.rs:19/23 | 误触即 UB 闪退、零日志 |
| 🔴 致命 | 工具链三重叠加 | §16.2（static RefCell + §9 Mutex + §16.1） | 60s 死锁设计必然 |
| 🟠 高 | 全局可变状态 111+45 | §14.1/§15.3/§16.2 | 生命周期绑进程 |
| 🟠 高 | 错误碎片化 + 无统一类型/无 panic hook | §12/§14.2 | 崩溃不进日志 |
| 🟠 高 | 裸线程 + sync/async 混用 | §15.1 | 不可取消 → 死锁救不了 |
| 🟡 中 | 取消 scope 树缺失 | §14.4 | 取消传不下去 |
| 🟡 中 | 依赖中心化 | §15.2 | 重构牵一发动全身 |
| 🟡 中 | 测试避开裂缝区 | §15.4 | 死锁/重启循环悄悄上线 |
| 🟡 中 | codegen 平铺上帝模块 | §16.3 | 改动全量 regen |
| 🟡 中 | **平台 cfg 漏进 core（trait 漏隔离）** | §17.1（314 cfg / 36 渗 core） | 平台逻辑污染核心、Android 插件穿 iOS 根 |
| 🟡 中 | **持久化无迁移层** | §17.2（serde 2842 / migrate 33） | 跨版本升级静默崩/老行为 |
| 🟡 中 | **unsafe 高危聚点（FFI+不可信插件解析）** | §17.3（188 总 / bridge+ToolPkg 聚集） | 不可信输入+不安全解析 |
| 🟢 正 | crate 图无环、分层清晰 | §16.4 | 粗粒度健康 |
| 🟢 正 | 19 crate + trait 抽象骨架（虽漏）+ thiserror + tokio + 312 测试 | §14.6/§17.1/§17.4 | 抽象地基不差，差在落地 |

### 17.7 下一步可挖（仅地基）

- **量化裂缝区 0 测试**：列 terminal.rs / ToolPkgToolLifecycleBridge.rs / daemon / ToolExecutionManager 覆盖率（确认 §15.4+§16.2）；
- 或回 operit1 看 host 依赖怎么传（坐实 §15.5「显式传参」）；
- 或评估消除 45 setDefault + 36 漏 cfg 的最小改动面（两者同源：全局可变状态 + 平台逻辑越界）；
- 或给 FFI 入口统一加 `catch_unwind` 宏 + 把 `operit_ios_ish_terminal_call` 的裸指针调用包成安全封装（最低成本止血 §16.1+§17.3）。

---

## 十八、地基研究收口（剩余维度 + 裂缝区测试铁证 + operit1 对照修正）

本轮把 §17.7 列的四项一次性扫完，并回 operit1 坐实对照——结果**推翻了我之前两个夸大判断**。

### 18.1 资源 / 句柄管理：operit2 的 RAII 远弱于 operit1

- operit2 全树 `impl Drop` 仅 **23 处**，却对应 **58 处裸资源创建**（UnixListener/TcpListener/File::open/`into_raw`/`forget`），且 **8 处 `into_raw`/`forget`** 是裸指针泄漏面（与 §16.1/§17.3 FFI 裸指针同源）。
- **最该有的 `Drop` 没有**：`operit_agent_daemon.rs`（长驻进程，持 Unix socket + TCP listener）的状态全是进程级可变全局（`static STATE: Mutex<State>`、`static STOP`、`static CACHED_CONFIG`、`static SCHEDULED_WORKFLOWS`，:33/37/50/56），`thread::spawn` 在 :452/:558 **不保留 JoinHandle、无优雅关闭**——进程退出时 socket/listener 不保证释放。
- Drop 分布也偏：23 处散在 apps/cli、hosts/{linux,windows}、core 各 1–3 处，**iOS daemon 这个真·长驻进程几乎零 Drop 守护**。
- **对照 operit1**：`Closeable`/`use{}`/`AutoCloseable` 共 **244 处**——Kotlin 的 `use{}`（≈ Rust 的 `Drop`）是 pervasive 习惯用法，资源生命周期被 RAII 钉死。这是 operit2 与 operit1 在「资源纪律」上**最实的差**：不是不能做、是没养成习惯。

### 18.2 初始化竞态（§14.1 全局单例的自然延伸）

daemon 的 `static STATE/CACHED_CONFIG/SCHEDULED_WORKFLOWS` 都是 `LazyLock<Mutex<…>>`，且 `:195/:452/:558` 多线程 `thread::spawn` 在 LazyLock 完成前就可能读写 —— `LazyLock` 虽线程安全初始化，但**多个 Lazy 全局之间无初始化顺序保证**，若 A 全局初始化依赖 B 全局已就绪，竞态即存在。配合 §14.1 的 `OnceLock<Mutex<Option<HostManager>>>` 在 `OperitApplication` 构造时批量 `setDefault`，本质是「**进程级可变单例 + 多线程启动**」的竞态温床。operit1 的等价物是 Android `Application.onCreate()` 单线程初始化 + `Context` 作用域，无此竞态。

### 18.3 可见性 / 封装（诚实降级：pub 数不能直接当证据）

`pub` 全树 **12933**、其中 `pub(crate)/pub(super)` 仅 **789**——初看似「封装崩坏」。但 **pub 在 Rust 库 crate 里是正常 API 暴露**（19 个 crate 互为依赖、pub 是接口），不能直接等同「垃圾」。真实信号是 §18.1 的「daemon 全局可变 + 零 Drop」与 §14.1 的「进程级可变单例」，不是 pub 计数。因此 §14.6 的「封装」维度**不单列**——避免用错指标夸大。

### 18.4 网络层超时 / 重试（诚实修正：两边都有，operit2 缺的是「trait 契约」）

- operit2 `reqwest/hyper/ureq` 使用 **172 处**、`timeout/retry/backoff` 字面 **701 处**——网络层**有超时词汇**，此前「operit2 无超时」的说法不准确（§13 也说过终端命令层有 `timeoutMs`）。
- 但 `operit-host-api/src`（抽象层）grep `timeout/retry/connect_timeout` **零命中**——即 **host-api trait 不在接口层面强制超时**，实现层各自为政。这是真 gap：能力存在、但抽象层没把「超时是必填契约」钉死。
- **对照 operit1**：OkHttp `Interceptor`/`retryOnConnectionFailure`/`connectTimeout`/`readTimeout` 共 **11 处**——operit1 也用超时/重试，且通常在 OkHttp 全局 `Interceptor` 里统一配。结论：**超时是两边都有**，operit2 独有的是「抽象层不强制」，不是「没有超时」。

### 18.5 能力探测模型（存在但严重不足用 → 印证 §10）

全树 `detect_/is_available/capability/probe/systemShellAvailable/jailbreak` **97 处**；`terminal.rs:85-104` 真有 `probeSystemShell()` 探测真 `/var/jb/bin/sh` 并把结果存进 `systemShellAvailable`。但 §10 已坐实：`primaryBackend()` 在 `systemShellAvailable == true` 时**仍返回 Ish**——探测结果被丢弃。即 operit2 **有探测能力、无探测驱动决策**：能力探测沦为装饰，默认路径硬编码。这正是 §10「执行模型反了」的同一根。

### 18.6 裂缝区 0 测试覆盖（铁证，坐实 §15.4）

具体文件实测（grep `#[test]/#[tokio::test]/fn test_`）：

| 文件 | 测试数 | 备注 |
|---|---|---|
| `hosts/ios/src/terminal.rs` | **0** | 终端双后端 + 死锁旁支 |
| `hosts/ios/src/bin/operit_agent_daemon.rs` | **0** | 重启循环（0.3.87）事发地 |
| `core/crates/operit-tools/src/ToolExecutionManager.rs` | **0** | 工具执行同步锁 + static RefCell（§16.2） |
| `core/crates/operit-runtime/src/plugins/toolpkg/ToolPkgToolLifecycleBridge.rs` | **0** | 60s 死锁真凶（§9） |
| `core/.../OperitApplication.rs` | **1** | 全局单例装配点 |
| **整个 `hosts/ios`** | **0** | iOS 宿主层全零覆盖 |
| `core/crates/operit-tools` | 17 | 偏纯逻辑，不在死锁文件 |

**结论**：所有「裂缝区」（并发/取消/daemon 生命周期/死锁）所在文件**测试数为 0**。§15.4 的假设被精确证实——312 个测试偏纯逻辑（calculator/markdown/regex），最脆的链路零覆盖。这直接解释 60s 死锁、daemon 重启循环为何能悄悄上线：没有测试拦、没有监控抓（§12）、崩了不进日志（§12/§16）。

### 18.7 operit1 对照修正（推翻两个夸大判断）

回 operit1 实读后，两点必须纠正：

1. **operit1 并非「无全局状态」**：`object`（Kotlin 单例）**849 处**、`by lazy` **147**、`lateinit var` **63**。即 **operit1 也重度用单例**。所以 §14.1/§15.5「operit2 全局单例 vs operit1 显式传参」要改判：
   - 两边都是单例文化；**差异在可变性 + 生命周期绑定**——operit2 的 45 处 `setDefault` 是**运行时可写的进程级 `Mutex<Option>`**（可变、难测、跨线程），operit1 的 `object` 多为 `val` 不可变 + 绑定 `Context`/scope（生命周期随 Android 组件）。operit2 不是「有全局」，是「全局是可变且脱离作用域的」。
2. **operit1 也有超时/重试、也用 lateinit 可变**——见 §18.4、§18.7.1。所以「operit2 在某些维度全无」的说法不成立；operit2 的差是**系统性的一档偏低**，不是「operit1 有 operit2 无」的二元对立。

**真实对照总表（修正版）**：

| 维度 | operit1 | operit2 | 谁强 |
|---|---|---|---|
| 全局状态 | 849 object 单例（多不可变、绑 scope） | 111 static 可变 + 45 setDefault（运行时可变、脱 scope） | operit1（可变面小） |
| 依赖传递 | 81 constructor 注入 + 63 lateinit + 147 by lazy | 全局 OnceLock 单例 + setDefault | 持平（两边都有可变单例） |
| 资源生命周期 | 244 use{}/Closeable/AutoCloseable | 23 Drop / 58 裸资源 | **operit1 明显强** |
| 网络超时 | OkHttp Interceptor 统一配（11） | 实现层有（701）、trait 不强制 | 持平（operit2 缺契约） |
| 能力探测 | 单平台无需 | 97 处探测但默认路径硬编码 | operit2 有壳无驱动 |
| 测试 | 150+ 测试文件，**裂缝区有专测**（CancellationTest 等） | 312 测试，**裂缝区 0 覆盖** | **operit1 明显强** |
| 取消/并发 | SupervisorJob 结构化取消树 | 裸线程不可取消 + 无 scope 树 | **operit1 明显强** |
| panic/ANR | setDefaultUncaughtExceptionHandler + 400 行 AnrMonitor | 空壳 AnrMonitor + 无 panic hook | **operit1 明显强** |
| 平台隔离 | 单平台无 cfg 爆炸 | 314 cfg / 36 漏 core | operit1（无多端负担） |

### 18.8 最终地基总评分卡（16 项，含诚实正项）

| 严重度 | 裂缝 | 实证章 |
|---|---|---|
| 🔴 致命 | FFI 无 panic 守护 + unsafe 裸指针 | §16.1 + §17.3（bridge.rs:19/23） |
| 🔴 致命 | 工具链三重叠加（static RefCell + Mutex + FFI-UB） | §9 + §16.2 |
| 🟠 高 | 进程级可变全局（111 static + 45 setDefault） | §14.1 + §15.3 |
| 🟠 高 | 错误碎片化 + 无统一类型 + 无 panic hook | §12 + §14.2 |
| 🟠 高 | 裸线程不可取消 + sync/async 混用 | §15.1 |
| 🟠 高 | 资源生命周期弱（23 Drop / 58 裸资源 / daemon 无优雅关闭） | §18.1 |
| 🟠 高 | 裂缝区 0 测试覆盖（terminal/daemon/ToolExecutionManager/Bridge 全 0） | §18.6 |
| 🟡 中 | 取消 scope 树缺失 | §14.4 |
| 🟡 中 | 依赖中心化（runtime 12 / core-proxy 14 内部依赖） | §15.2 |
| 🟡 中 | codegen 平铺上帝模块（generated_core_dispatch 12385 行） | §16.3 |
| 🟡 中 | 平台 cfg 漏进 core（314 / 36 渗 core） | §17.1 |
| 🟡 中 | 持久化无迁移层（serde 2842 / migrate 33） | §17.2 |
| 🟡 中 | unsafe 高危聚点（FFI + 不可信插件解析） | §17.3 |
| 🟡 中 | host-api trait 不强制超时契约 | §18.4 |
| 🟡 中 | 能力探测有壳无驱动（probe 结果被默认路径丢弃） | §18.5（印证 §10） |
| 🟢 正 | crate 图无环、分层清晰 | §16.4 |
| 🟢 正 | 19 crate + trait 抽象骨架（虽漏）+ thiserror + tokio + 312 测试 | §14.6 + §17.1 |
| 🟢 正 | operit1 也用单例（849 object）—— operit2 非「独有全局病」，是可变面更大 | §18.7（修正） |

### 18.9 最低成本止血（按 ROI 排序，不碰功能）

1. **FFI 统一 `catch_unwind` 宏**（一行宏覆盖 40 入口）+ 把 `operit_ios_ish_terminal_call` 裸指针调用包安全封装 → 直接消除最致命 UB 闪退（§16.1+§17.3），零逻辑改动。
2. **装 `std::panic::set_hook` 接 AppLogger**（§12）→ 崩了进日志，取代「系统看门狗砍 + 读源码猜」。
3. **填 `AnrMonitor`**（operit1 400 行可借鉴）→ 60s 死锁当场抓栈，不必反推 20h。
4. **daemon 资源加 `Drop` + 保留 JoinHandle 做优雅关闭**（§18.1）→ 重启循环可诊断、可干净退出。
5. **裂缝区补测试**：terminal/daemon/ToolExecutionManager/ToolPkgToolLifecycleBridge 各加并发/取消/生命周期用例（§18.6）→ 把最脆链路钉死，防回归。

### 18.10 收口结论

地基研究自 §九 至 §十八 共 10 章，维度已穷尽（终端/工具并发/越狱集成/插件生态/可观测性/流式/四大地基裂缝/广挖线程·依赖·单例·测试/FFI·cfg·持久化·unsafe/资源·竞态·封装·超时·探测·裂缝测试）。结论定性：

**operit2 相比 operit1，不是「全垃圾」，是「抽象方向不差（7 分）、落地全面弱一档（3 分）」**——好 crate 分层被全局可变单例毁了可替换性、好 tokio 没提升成应用 runtime、好 thiserror 没统一成跨层类型、有探测能力却硬编码默认路径、有 312 测试却避开最脆链路。越狱方向最实的三刀：FFI-UB 闪退（致命）、60s 死锁（设计必然）、重启循环（缺优雅关闭+无监控）。修这三类只需上面 5 步止血，不必重写——前提是 §七 优先级「前 4 项没完别加功能」被遵守。

（地基研究到此收口；后续若要做的是「挑一个裂缝真动手修」或「换主题」，另行指示。）

---

## 十九、UI 设计对比（Flutter 跨平台 vs Compose 原生）

用户要求补 UI 设计维度。先声明基线（接 §18.10 校准）：operit2 是 Flutter 跨平台、operit1 是 Android 原生 Compose——**框架选择本身是跨平台合理代价，不是垃圾**。但「UI 质量」要分「框架代价」与「真实投入」两层看。

### 19.1 operit2（Flutter）UI 实貌：比预期厚，非薄壳

- **规模**：`apps/flutter/app` 共 **678 个 dart 文件**；`lib/` 分 `common/core/data/l10n/ui/util`。
- **UI 模块**：chat(19) / markdown(11) / settings(20) / packages(market 6 + screens 16 + dialogs 7) / workspace(browser 8 + userscripts 13 + file_preview 8 + html_preview 4) / window(4) / theme(5) / characters(5) / terminal(2，在 workspace 内)。
- **真实自研投入（推翻「UI 薄」假设）**：
  - `lib/ui/common/markdown/` 有 **`CanvasMarkdownNodeRenderer` + `StreamMarkdownRenderer` + `StreamMarkdownRendererState`**（与 operit1 同名 `StreamMarkdownRenderer` 对应——两边都在做**流式 markdown 渲染**）、`EnhancedCodeBlock`、`MarkdownLatexBlock`（KaTeX，经 `flutter_math_fork`）、`XmlRenderPluginRegistry`。= 自研 canvas markdown 引擎，非套 `flutter_markdown`。
  - `lib/ui/window/`：**`DetachedChatWindowApp/Launcher/Arguments/Platform`** 4 文件 = **真实分体/悬浮聊天窗口**系统（对应 operit1 的 50 个 Floating 文件）。
  - `lib/ui/features/settings/characters/`：**`CharacterCardEditorDialog` + `CharacterGroupDialogs` + `CharacterSettingsPanel` + `MemoryGraphScreen`** = 形象卡编辑 + 记忆图谱屏（对应 operit1 的 35 Avatar + 记忆模块）。
  - `workspace/browser/`：**完整内置浏览器**（tabs/bookmarks/history/downloads/permissions/automation）+ **userscript 引擎**（`WorkspaceUserscriptRuntime/Matcher/MetadataParser/Store`，13 文件）= 对应 operit1 的 38 browser/userscript kt。

### 19.2 operit1（Compose 原生）UI 实貌：更深的自研渲染引擎

- **规模**：`ui/` 下 **521 kt** + **20 个 feature 模块**（about/agreement/announcement/assistant/chat/codex/demo/github/help/memory/packages/permission/settings/startup/token/tokenstats/toolbox/update/websession/workflow）。
- **深度自研渲染**（性能工程，operit2 没对等投入）：**88 个自定义 `LazyColumn`**（`ui/features/chat/components/lazy/`，约 50 文件）+ `RenderBatchCoordinator` + 对象池（`ImagePoolManager`/`SkillRepoZipPoolManager`）+ `LatexCache` + `ImageBitmapLimiter`/`MediaBase64Limiter`（防 OOM）。Markdown 34 / Render 38 / Avatar 37 / Floating 50 / Setting 98 / Chat 90。
- 含义：operit1 把「聊天列表滚动 + 大图 + 流式 markdown」这种高负载路径**手搓性能层**；operit2 用 Flutter 内置列表 + 自研 markdown canvas，渲染策略更「借框架」。

### 19.3 UI 设计诚实判定

| 维度 | operit2 (Flutter) | operit1 (Compose) | 谁强 |
|---|---|---|---|
| 框架 | 跨平台一套代码 | Android 原生 | 各有所长（operit2 省、operit1 贴） |
| markdown 流式 | 自研 canvas StreamMarkdownRenderer | 自研 StreamMarkdownRenderer + RenderBatchCoordinator | 持平（都自研流式） |
| 悬浮/分体窗口 | DetachedChatWindow（4 文件） | 50 Floating 文件 | operit1 更深 |
| 浏览器+userscript | 有（13 userscript 文件） | 有（38 kt） | 持平 |
| 形象/记忆 | CharacterCard + MemoryGraphScreen | 35 Avatar + 记忆模块 + 6 后端 | operit1 后端更多 |
| 性能工程 | Flutter 内置 + 自研 markdown | 手搓 LazyColumn/池/限流 | **operit1 明显强** |
| iOS 越狱原生集成 | **Flutter 短板**：ScreenTime/原生浮窗/tweak 注入需原生，Flutter 不给 | （Android 无此负担） | operit1 无对标项 |

**结论**：「operit2 UI 垃圾」这顶帽子**比地基那顶更扣不稳**——它的 Flutter 壳是** competent 的跨平台产品**（真实自研 markdown 流式、真实分体窗口、真实浏览器+userscript、形象+记忆图谱都在）。真差距在两点：
1. **性能工程深度**不如 operit1（没手搓列表/池/限流，靠 Flutter 内置）；
2. **在越狱 iOS 上，Flutter 的跨平台成了真负债**：ScreenTime 自动化、SpringBoard 上浮窗、tweak 注入这些越狱价值点，**正好是 Flutter 给不了的原生集成**。operit1 在 Android 上用原生 Compose 能深度接 Shizuku/Accessibility，operit2 在 iOS 上被 Flutter 框死——这是 §10「执行模型反了」在 UI 层的延伸：底层把真 shell 丢给 iSH，UI 层把原生集成丢给框架。

---

## 二十、功能广度对比（成熟全产品 vs 聚焦越狱窄壳）

### 20.1 operit1 功能广度（源码实核，文件计数）

- **工作流**：`ui/features/workflow` 8 kt + core `WorkflowExecutor.kt` 1320 行（触发/条件/环检测/拓扑执行/逐节点 try-catch）。
- **工具箱**：`ui/features/toolbox` **47 kt**（文件管理/Shell/Logcat/SQL/FFmpeg/HTML 打包/UI 调试器/APK 逆向编辑 28 kt）。
- **记忆+知识图谱**：`ui/features/memory` 12 kt + `MemoryGraphScreen`（图谱可视化）。
- **形象**：Avatar **35 kt** + 6 后端（DragonBones/MMD/FBX/glTF/WebP/MP4）。
- **投屏**：Shower **13 kt**。
- **内置浏览器+userscript**：38 kt。
- **PhoneAgent+AutoGLM**：服务层 1 kt 匹配 + 原生 `.so`（手机自主 Agent）。
- **其他（§功能广度）**：Compose DSL 让工具包自定义 UI、ToolPkg(QuickJS)+MCP+Skill+统一市场、悬浮球/窗/全屏、屏幕 OCR、内置代码编辑器（Kotlin/Dart/JS/HTML 高亮+补全）。
- **端侧 LLM**：README 列 MNN/llama 模块，但本 Operit-main checkout 的 `app/src/main/java` 下 `ls mnn llama` 为空——可能在 `native/CMake` 或独立 module，**未深究、不夸大其有无**。

### 20.2 operit2 iOS 功能实貌（Flutter UI + Rust core + 越狱能力）

- **Flutter UI 层**：chat + 自研 markdown + 分体窗口 + 形象卡 + 记忆图谱 + 浏览器 + userscript + 包市场 + 终端 workspace + 设置 + 主题。
- **Rust core + 越狱能力**（来自前面章节 + 记忆）：terminal/iSH、ios-mcp 设备自动化、屏幕时间 7 件原子工具、Shortcut `run_shortcut`、operit:// URL scheme、本地通知、VLM daemon、TCP 8890、daemon（trustcache 签名）。

### 20.3 功能诚实判定

| 类 | operit1 有 | operit2 iOS 有 | 备注 |
|---|---|---|---|
| 聊天+流式 markdown | ✅ | ✅（自研 canvas） | 持平 |
| 内置浏览器+userscript | ✅ | ✅ | 持平 |
| 形象/记忆图谱 | ✅（6 后端） | ✅（卡编辑+图谱屏） | operit1 后端多 |
| 分体/浮窗 | ✅（50 Floating） | ✅（DetachedChatWindow） | 持平 |
| 工作流可视化编排 | ✅（1320 行） | ❌ | **operit2 缺** |
| 工具箱（APK逆向/代码编辑/SQL/FFmpeg） | ✅（47kt） | ❌（iOS 无对等） | **operit2 缺** |
| PhoneAgent+投屏 | ✅ | ❌（iOS 机制不同） | 缺，但非「垃圾」是平台差 |
| 端侧 LLM | 列了（待核验） | ❌ | 缺 |
| 越狱自动化（ScreenTime/ios-mcp/tweak） | 不适用（Android 用 Shizuku） | ✅（独特价值） | **operit2 独有** |
| 包市场（.toolpkg） | ✅（Android 插件跑得通） | ⚠️ 市场有、但 §11 证明 Android 插件在 iOS **装得上跑不动** | **iOS 上市场是空心** |

**结论**：
1. **operit1 = 成熟全产品**（20 模块、工具箱、工作流、形象、PhoneAgent、Shower）；operit2 iOS = **聚焦的越狱自动化窄壳**。这是真实功能差，但**部分是 scope/成熟度，不是「垃圾」**——operit2 是跨平台 + iOS 越狱窄场景，operit1 是通用安卓助手产品。
2. **operit2 的「广度」在越狱 iOS 上塌缩**：§11 已证 Android 插件在 iOS 跑不动，所以「包市场」这个看似最大的广度优势，在 iOS 上是**空心**的——UI 里有市场、有浏览器、有形象，但底层 Android 能力层不工作，用户拿到手大部分功能死。这比「功能少」更糟：**功能看起来多、实际能用少**。
3. **operit2 有 operit1 无法对标的独特价值**：ScreenTime 自动化、ios-mcp tweak 注入、trustcache 签名 daemon——这些是越狱 iOS 专属，operit1 在 Android 上用 Shizuku/Accessibility 走另一条路。所以「operit2 功能少」要加一句「在越狱维度它反而有 operit1 没有的东西」。

### 20.4 总收口（UI + 功能）

- **UI**：operit2 不垃圾（competent 跨平台壳 + 真实自研 markdown 流式/分体窗/浏览器）；弱在性能工程深度 + **iOS 越狱原生集成被 Flutter 框死**（这是跨平台在本题的真实负债，非借口）。
- **功能**：operit2 比 operit1 全产品**窄**，但窄 partly 是 scope；最该骂的是「**市场/插件广度在 iOS 上空心**」（§11）+「**UI 看着全、底层 Android 能力不工作**」——即「广度幻觉」。越狱专属能力（ScreenTime/ios-mcp/daemon）是 operit2 真护城河，应做厚而非追 operit1 的安卓功能数。

（UI + 功能维度补完；与 §九~§十八 地基研究共同构成 operit2 vs operit1 全维度对比。后续若要做「挑裂缝真修」或「换主题」，另行指示。）

---

## 第二十一章 修复记录（从最简单裂缝动手）

### 21.1 已修：全局 panic hook（修 §12.2「崩溃不进日志」）

**改动文件**：`core/crates/operit-util/src/AppLogger.rs`
**内容**（纯新增，零逻辑改动、`cargo check -p operit-util` 通过）：
- 新增 `static PANIC_LOG_PATH: OnceLock<String>`，在 `configure_log_files()` 里用 `let _ = PANIC_LOG_PATH.set(log_file.clone())` 记录运行时日志路径；
- 新增 `pub fn install_panic_hook()`：用 `std::panic::set_hook` 装进程级 hook，hook 内 `take_hook()` 保留默认 stderr 输出，再把 `PANIC at <loc>: <msg>\n<backtrace>` **追加写进 `operit.log`**（best-effort，`OpenOptions::append`，不碰 AppLogger 的 STATE Mutex，避免 panic 源自身在锁内时连环崩）；
- 在 `install_host_log_sink_once()`（首次日志初始化即触发，早于任何 core dispatch）里调用 `install_panic_hook()`。

**修前**：Rust panic 只走 stderr、不进 `operit.log`，设备上一崩就无日志（§12.2 根因，也是 60s 死锁只能靠读源码反推的帮凶）。
**修后**：任何 Rust panic 都会被写进 `runtimeRoot/logs/operit.log`，带文件:行号 + backtrace，设备侧调试可直接 `grep PANIC operit.log` 拿现场。

**诚实边界**：本改动只在**进程已跑起来、logging 已 configure** 后生效；bootstrap 阶段（logging 配置前）的 panic 仍只走默认 stderr。但 `OperitApplication::newWithContext` 在 core dispatch 前就调 `configure_log_files`，所以绝大多数运行期崩溃已覆盖。

### 21.2 校正 §16.1（FFI catch_unwind 实际覆盖）

读 `BridgeExports.rs` 全文后校正：19 个 `extern "C"` 中，**最致命的 3 个已护住**——`operit_flutter_bridge_create`(L6)、`operit_flutter_bridge_create_with_storage_roots`(L68)、`operit_flutter_bridge_native_call`(L184，Dart↔Core 主通道) 都已 `catch_unwind` 包好。

**真正未护的是 16 个次通道**：`push_open`/`push_item`/`push_close`/`watch_snapshot`/`watch_stream`/`next_watch_channel_event`/`close_watch_channel`/`close_watch_stream`/`start_web_access_server`/`stop_web_access_server`/`emit_runtime_event`/`create_error`/`destroy`/`free_string`/`free_bytes` 以及 ohos `create_with_storage_roots_and_system_language`。它们内部直接调 `bridge_*` 帮助函数或 `handle.*` 方法，panic 会裸跨 FFI = UB。

### 21.3 ✅ 已修：16 个 FFI 入口统一 `catch_unwind`（Fix B，修 §16.1）

**改动文件**：`apps/flutter/native/operit-flutter-bridge/src/BridgeExports.rs`
**改动面**：新增 3 个宏 + 给 16 个未护 `extern "C"` 套壳，零业务逻辑改动、`cargo check` 通过（仅预存命名 warning，无新增 error）。

**新增统一宏**（文件顶部 `use super::*;` 之后）：
- `catch_ffi_buffer!($body)`：包返回 `OperitByteBuffer` 的入口，panic → `bytes_to_buffer(native_core_panic_result(...))`（即 `FATAL_CORE_PANIC` 错误 buffer，带 backtrace）；
- `catch_ffi_string!($body)`：包返回 `*mut c_char` 的入口，panic → 返回 `{"ok":false,"error":"FATAL_CORE_PANIC: ..."}` JSON 错误串；
- `catch_ffi_void!($body)`：包返回 `()` 的入口（`destroy`/`free_*`/`close_watch_channel`），panic 吞掉（防 UB，代价是少数泄漏，可接受）。

**套壳的 16 个入口**：`create_error`/`destroy`/`free_string`/`free_bytes`/`push_open`/`push_item`/`push_close`/`watch_snapshot`/`watch_stream`/`next_watch_channel_event`/`close_watch_channel`/`close_watch_stream`/`start_web_access_server`/`stop_web_access_server`/`emit_runtime_event`/ohos `create_with_storage_roots_and_system_language`（ohos 那个是单平台 `catch_unwind` 直写，结构同主通道 create）。

**修前**：这 16 个次通道内部直接调 `bridge_*` 帮助函数或 `handle.*` 方法，任一 panic 都裸跨 `extern "C"` = **未定义行为 → 直接 abort、零日志**（比普通崩更糟一个量级）。
**修后**：panic 不再跨 FFI abort——buffer 类变 `FATAL_CORE_PANIC` 错误响应、string 类变 JSON 错误串、void 类被吞掉；且配合 Fix A 的 panic hook，panic 现场也会落 `operit.log`。设备上表现为"某次调用失败可恢复 + 有日志"，不再是"点一下就闪退什么都没留"。

**诚实边界**：
- `cargo check` 在 host target 通过，**iOS 真机行为未验证**（跨 FFI 的 catch_unwind 行为需上机 confirm，但这是 Rust 标准语义，确定性高）；
- `wasm32` 分支（async 版 `bridge_*_async`）未动——那些走 `console_error_panic_hook`，与 iOS 无关；
- 宏用 `AssertUnwindSafe` 包闭包，意味着若 panic 源于 `RefCell`/全局可变状态（§16.2 那类），catch 后状态可能处在不一致中间态——但至少不再 abort，符合"先止血、再根治锁"的 ROI 排序。

### 21.3.1 ✅ 已修：AnrMonitor 空壳填实（Fix C，修 §12.1）

**改动文件**：`core/crates/operit-util/src/AnrMonitor.rs`（实现）、`core/crates/operit-util/src/AppLogger.rs`（`PANIC_LOG_PATH` 改 `pub(crate)`，供 ANR 同文件 lock-free 落盘）、`apps/flutter/native/operit-flutter-bridge/src/BridgeExports.rs`（接入点）
**改动面**：把 2 行 `pub struct AnrMonitor;` 空壳换成真·心跳看门狗；在 Flutter↔Rust 派发线程（三个 `create*` 入口起看门狗 + `operit_flutter_bridge_native_call` 每次 beat）接上。`cargo check` host target 通过；operit-util `wasm32` 编译通过（看门狗在该 target 为 no-op）。

**机制**：
- 被监控线程在热路径调 `AnrMonitor::AnrMonitor::beat()`（operit-util 里模块与结构体同名，故需 `模块::结构体::函数` 双名路径）——只写 `AtomicI64` 时间戳，每 2s 才 `force_capture` 一次自身 backtrace 存 `Mutex<String>`，热路径零锁；
- 单后台 `anr-watchdog` 线程每 1s 醒来，若超过阈值（派发线程 10s）未 beat，写 ANR 报告：线程名 + 失响应时长 + **最后采样到的栈**（线程最后活着时的位置）；
- 报告走 stderr + 直接 append 到 `operit.log`（复用 Fix A 的 `PANIC_LOG_PATH`，lock-free，不碰 AppLogger 的 STATE 锁，避免死锁时也被卡住）+ 尽力写 AppLogger 内存环（包 `catch_unwind` 防 STATE 中毒杀看门狗）。

**修前**：§12.1 的 2 行空壳，招牌 bug "插件 60s 卡死" 发生时毫无现场——只能读源码反推 20h。
**修后**：若未来再发生"Rust core 不响应 UI"类死锁，看门狗当场把失响应线程的最后栈落 `operit.log`，MTTR 从"反推几天"降到"看一行日志"。派发线程 beat 抓的是 Flutter↔Rust 边界卡死（含历史 60s worker 自死锁拖住派发的情形）。

**诚实边界**：
- 监控单一 Rust 线程（派发线程），非 Dart UI 线程；纯 Dart 层冻屏需 Dart 侧 guard（超出 Fix C 范围）；
- 抓的是"被监控线程最后活着时的栈"，不是死锁发生瞬间的全线程快照（后者需 Mach `task_threads`/`/proc`，跨平台代价大，刻意未做）；
- 仅本机 `cargo check` 通过，**iOS 真机未验证**：需上机确认 ① 正常时看门狗不误报 ② 真死锁时 `operit.log` 确有 ANR 行 + 栈；
- `operit-flutter-bridge` 完整 `wasm32` 构建在本地环境因 `operit-core-proxy` 的 build script 失败（预存、与本次改动无关），但 operit-util 自身 wasm 编译已验证通过，且 `start_monitoring`/`beat` 在 wasm 为 no-op，Flutter web 路径安全。

### 21.4 优先级重排（按 ROI，不动功能）

1. ✅ panic hook（Fix A，本机编译过）
2. ✅ 16 个 FFI 入口 catch_unwind 宏（Fix B，本机编译过）
3. ✅ 填 `AnrMonitor`（Fix C，本机编译过）
4. ✅ daemon 优雅关闭：SIGTERM handler + `AtomicBool` stop 旗 + accept 非阻塞 + scheduler `JoinHandle` join（Fix D，iOS target `aarch64-apple-ios` 编译过）
5. ✅ 裂缝区补测试：`ToolPkgToolLifecycleBridge::onToolCallIntercept` 抽出纯函数 `decide_intercept_action` + 4 个 `#[cfg(test)]`（Fix E，`cargo test -p operit-runtime` 4 passed）
6. ✅ flutter-bridge 残留导出 FFI `operit_flutter_bridge_sync_daemon_config` 包 `catch_unwind`（Fix F，本机编译过；其余 ohos/android/ios-bridge `extern "C"` 为 import/type-alias，非 export，无需包）
7. ✅ `AppLogger` 三处自伤：ring buffer 上限 1000、`ERROR` 强制 `Backtrace::force_capture()`、`MIN_LOG_LEVEL` 节流 + `is_loggable` 真正生效（Fix G，本机编译过）
8. ✅ 裂缝测试扩面（Fix H）：`ConversationMarkupManager::truncate_payload_caps_output_and_appends_suffix`（输出限额裂缝区，2000B→cap 50 + `已截断` 后缀断言）；`AIToolHandler` 新增 `run_with_timeout` 基础工具 + 3 测试（按时返回 / 超时返回 None / 0 超时内联）。覆盖 §18.6 中"超时纪律"与"输出限额"两块裂缝区（`cargo test -p operit-tools --lib` 4 passed）。**残余未覆盖**：`terminal.rs`、`managed_runtime.rs` 直测仍 0 覆盖（概念裂缝区，本次未补）。
9. ✅ 拆工具层全局 Mutex（Fix I，②-1，60s 自死锁结构性根因）：`ToolPkgHookBridgeSupport::package_manager()` 由阻塞 `.lock().expect()` 改为非阻塞 `try_lock()` 返回 `Option`（持锁时返回 `None` 而非卡死）；12 个 bridge 文件 19 处调用点包 `if let Some(manager) = ...package_manager()`（`ToolPkgToolLifecycleBridge` 本用 `try_package_manager` 不动）。`cargo check -p operit-runtime` 0 error。注：整体换 `ReentrantMutex` 不可行（`parking_lot::ReentrantMutexGuard` 是 `!Send`，会炸 ~15 个跨线程调用点），故走 try_lock 路径。
10. ✅ 工具执行超时+取消+限额（Fix J，②-2）：限额**已存在**（`ConversationMarkupManager::MAX_FINAL_TOOL_RESULT_MESSAGE_CHARS = 64*1024` + `truncatePayload`/`buildBoundedToolResultMessage`，单工具 payload 封 64KB，≈ operit1 量级），不重复造。超时纪律**已接入 `executeTool`**：`AIToolHandlerState` 新增 `toolExecutionTimeoutMs`（**默认 0 = 不启用**，行为与改动前完全一致，零回归），`set/getToolExecutionTimeoutMs` 可配；`executeTool` 用 `run_with_timeout` 包 `invokeAndStream`，超时返回 `success:false` + `tool.execute.timeout` ChainLogger error。`cargo check -p operit-tools` Finished 0 error，`cargo test` 18 passed / 0 failed。
    - 🔴 **纠正上一轮误判（重要）**：此前断言「`Box<dyn ToolExecutor>` 是 `!Send`，接入需 `ToolExecutor: Send` 波及 14 impl 或迁 tokio」——**错的**。实读 `ToolExecutionManager.rs:768` 是 `pub trait ToolExecutor: Send`，即 `Send` 早就是 supertrait，trait object 天然 `Send`，**零 impl 改动即可接入**。该错误结论是靠内部推理得出、未查 trait 定义，已同步修正 `run_with_timeout` 的 doc comment。真正仍需 tokio 迁移（③-2）的只是**真取消**（drop future），不是"限住等待"。
    - **超时后的语义（必须知道）**：executor 被 move 进看门狗线程，超时时**拿不回**，该工具暂从 `availableTools` 缺席，直到下次调用 `getToolExecutorOrActivate` → `registerDefaultTools()` 重建（内置工具可恢复）。超时线程**不会被中止**（Rust std 无线程取消），会继续跑到自己结束。
    - **未单测覆盖**：`executeTool` 超时执行路径无集成单测（构造 `AIToolHandler` 需 `HostManager`+`ToolRuntimeDependencies`，成本高）；`run_with_timeout` 本身有 3 个单测。实际超时行为待上机验证。

> 注：Fix A + Fix B + Fix C 是 §18.9 里 ROI 最高的三刀，均已落（Fix C 见 §21.3.1）。Fix C 直接补 §12.1 的"60s 死锁该抓却没抓"缺口——代价比 A/B 大（起后台线程 + 跨平台 cfg 闸门），但已按"本机编译过、iOS 真机待验证"交付。
> Fix D/E/F/G/H/I/J 同属甲档小刀，2026-08-31 收尾全部落本地、均未 push。daemon（D）、AppLogger（G）、拆 Mutex（I）依赖设备运行时行为的部分（SIGTERM 真优雅关闭、panic/ANR 真写入 operit.log、WASM worker 线程不再 60s 自死锁）仍须上机证据，本机只能验编译/单测。
> 上机验证前，对"修好了"一律不打包票——以设备日志为准。

11. ✅ 统一 `OperitError`（Fix K，§14.2 错误碎片化）：**类型级地基已落，全量迁移是后续增量任务**。在最低层、且 5 个目标 crate 已共同依赖的 `operit-util` 新增 `error.rs`，定义跨 crate 统一错误类型 `OperitError`（thiserror 枚举）+ `OperitResult<T>` 别名。内置 `From`：`std::io::Error`→`Io`、`serde_json::Error`→`Json`、`std::str::Utf8Error`/`FromUtf8Error`→utf8 变体、`reqwest::Error`→`Http`、`operit_host_api::HostError`→`Host`（FFI/host 边界，operit-util 已依赖 host-api、无环）、`String`/`&str`→`Message`；外加 `Timeout{ms}`/`Cancelled`/`NotFound`/`InvalidArgument`/`External(Box<dyn Error+Send+Sync>)` 与 `OperitError::other()`/`timeout()`/`cancelled()` 构造器。`lib.rs` 导出 `pub use error::{OperitError, OperitResult}`。`cargo check -p operit-util` Finished 0 error。
    - **为什么放 operit-util + 为什么不能反向依赖**：全树 grep `enum OperitError`/`OperitResult`/`type OperitResult` **零命中**，错误类型碎片化（operit-store 7 处、operit-runtime 2、operit-local-models 6、operit-providers 1 各定义 thiserror 枚举）。`operit-util` 已被上述 5 crate 全部依赖，是天然落点；但它**依赖** `operit-host-api`、而 host-api **不依赖回** util，故无环。关键约束：`operit-util` **不能**反向 `use` store/runtime 等 crate 的错误类型（否则 crate 图成环、编译失败），所以"各 crate 专属错误 → `OperitError`"的 `From` **必须放在各 crate 自己内部**（orphan rule：本地错误类型 + 外来 `OperitError` 合法）。已在 `operit-store/src/SqliteStore.rs` 落**一个示范** `impl From<SqliteStoreError> for OperitError`（按内层变体分流到 `Io`/`Host`/`Message`），`cargo check -p operit-store` Finished 0 error，证明该桥接模式可编译、`?` 可跨 crate 传播。
    - **范围与诚实边界**：本次只交付"统一类型 + 通用 `From` + 1 个示范桥接"。**未**删除任何现有 crate 错误枚举、未把各 crate 的 `?` 返回值批量改投 `OperitResult`——那是逐 crate 的机械迁移（每个 crate 加一个 `From` 即可，模式见 `SqliteStoreError`）。`cargo check` 仅验了 util + store；operit-runtime / operit-local-models / operit-providers 仅依赖 util 且未被改，纯新增公共模块无破坏，未单独重编（编译可证明、无需设备）。全量迁移建议后续按 crate 逐个加 `From` + 把对外边界函数返回类型换 `OperitResult`，不一次性大改以免回归面过大。
    - 关联：Fix J 的超时/取消语义（`Timeout`/`Cancelled` 变体）与此错误类型对齐，看门狗超时可直接 `return OperitError::timeout(ms)`（当前 `executeTool` 走 `ToolResult` 路径，未接 `OperitError`，属后续桥接）。
    - **全量迁移已完成（用户 "全量迁移" 指令，本回合）**：给剩余 3 crate 的全部错误枚举补 `impl From<LocalError> for operit_util::OperitError`（orphan rule，用全限定路径免 import、零命名冲突）。共 **9 枚举桥接**：operit-store `SqliteStoreError`(示范) + operit-runtime `FunctionalConfigError`/`ModelConfigError`(2) + operit-local-models `LocalInferenceError`/`LocalModelRegistryStoreError`/`LocalModelProviderError`/`LocalModelDownloadError`/`LocalEngineDownloadError`/`LocalModelStorageError`(6) + operit-providers `AiServiceError`(1)。映射规则：typed 变体 `Json(serde_json::Error)`→`OperitError::Json`、源含 `Host`→`Host` 走 `.into()`；其余 String/struct 变体→`OperitError::Message`（格式化还原原 message）；`AiServiceError::RequestCancelled`→`OperitError::Cancelled`（与 Fix J 取消语义对齐）；wrap 他 crate 错误的 `Store(PreferencesDataStoreError)` 变体→`Message(e.to_string())`（不递归、避免成环）。**效果**：任意 crate 内 `foo()?`（返回本地错误）在调用方返回 `OperitResult` 时自动 `?` 转统一类型，**跨 crate 错误可传播落地**（§14.2 真修）。**未做**：逐函数签名 `Result<T,LocalError>`→`OperitResult<T>` 改写——`From` 桥已让 `?` 在跨 crate 边界自动转换，改签名是纯 churn 且扩大回归面，故刻意不做；如需更显式契约可后续按需局部改边界函数。`cargo check -p operit-util -p operit-store -p operit-runtime -p operit-local-models -p operit-providers` Finished 0 error（仅预存命名 warning）。
> **预存在红灯（已顺手修）**：`operit-tools` 单测模块原有 1 个红——`files::PathMapper::hiddenAliasesResolveButDoNotAppearInRootList`（line 714）。根因：commit `1db0484e`（Android 路径兼容）让非 Android 上 `/sdcard`、`/data` 经 android-compat 映射到沙盒目录（resolve 成功），而该测试 `#[cfg(not(target_os="android"))]` 分支仍断言旧契约（应 `.is_err()`）。属过期测试期望，非 bug（用户确认顺手修）。已改 line 712-716 期望为沙盒路径（`D:/operit/android-compat/sdcard/Download/Operit` 等），`cargo test -p operit-tools --lib` 现 **18 passed / 0 failed** 全绿。此修超出原 Fix H/I/J 批次（不同模块 `files/`），但正确且低风险，已落本地未 push。
