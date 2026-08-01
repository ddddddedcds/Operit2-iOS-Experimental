# AutoGLM + ios-mcp iOS Agent（原型）

把 Open-AutoGLM 的"大脑"（AutoGLM-Phone 视觉语言模型）接到越狱 iPhone 的
"手"（ios-mcp），中间层就是本脚本。它跑在 Mac 上，通过局域网驱动真机，
完整复刻 Open-AutoGLM 的 agent loop，但把 WebDriverAgent 换成了 ios-mcp——
对越狱机更轻（无需 Xcode 签名 / Apple 账号 / 构建 WDA）。

## 架构
```
AutoGLM-Phone (云端 VLM)
      ↑ 截图(base64 JPEG) + 指令      ↓ do(...) 动作
operit2-ios 中控 (本脚本 = 原型)  ←→  ios-mcp (http://192.168.1.21:8090/mcp)
                                          ↓ tap/swipe/type/launch/screenshot
                                     越狱 iPhone (真机)
```

## 文件
- `prompt_zh.py` — 复制 Open-AutoGLM 的系统提示词（动作定义 + 18 条规则），**勿改**
- `mcp_client.py` — ios-mcp JSON-RPC 客户端（无第三方依赖）
- `planner.py` — AutoGLM OpenAI 兼容客户端
- `parser.py` — 解析 `do(...)` 动作（ast 安全求值，0–1000 归一化坐标）
- `executor.py` — 把动作映射到 ios-mcp 工具（坐标换算、name→bundle_id）
- `agent.py` — loop：截图→模型→解析→执行→循环；锁屏护栏；历史删图省 token
- `run.py` — CLI 入口

## 运行
```bash
export AUTOGLM_API_KEY="你的智谱/BigModel key"
cd tools/autoglm_ios_agent
python3 run.py "打开抖音搜索猫咪视频"
# 可选
python3 run.py "打开微信发消息给文件传输助手：测试" --max-steps 40
```
依赖：Python 3.10+，仅标准库（urllib/ast/json/re）。无需 pip install。

## 已确认的事实（来自 Open-AutoGLM 源码精读）
- 模型原始输出：`<think>推理</think>\n<answer>do(action="Tap", element=[500,100])</answer>`
- 坐标 **0–1000 归一化**，executor 按 `get_screen_info` 屏尺寸换算成 screen points
- `double_tap` / `long_press` / `swipe_screen` / `tap_screen` / `launch_app(bundle_id)` 等均在真机 ios-mcp（v1.2.3）实测存在
- `Back` 无专用工具 → 用左缘 `swipe_screen` 兜底
- `list_apps` 可列已装 App → 启动时建 name→bundle_id 动态表（比 Open-AutoGLM 的 Android 包名表更准）

## 待真机实测的 3 件事（本原型就是为验证它们）
1. **iOS 截图喂 Android 训练的模型精度**：AutoGLM 在 Android 截图训练，iOS UI 精度可能掉
2. **Back 手势效果**：左缘 swipe 是否真能返回（iOS 无通用返回键）
3. **name→bundle_id 覆盖度**：常用 App 是否都能从 `list_apps` 解析到

## 已知限制
- 敏感操作（Tap 带 message）原型里自动放行，未做真阻塞确认
- `Take_over`（登录/验证码）会 `input()` 暂停等你手动操作
- 坐标换算/Back 兜底等逻辑，验证通后原样搬进 operit2-ios 的 Rust/Dart 中控层

## 后续：搬进 operit2-ios
本脚本的逻辑 1:1 对应未来 operit2-ios 中控层：
- `planner` + `prompt_zh` → operit2-ios 内调 AutoGLM API（entitlements 已放开出网）
- `parser` → 同样的 ast 解析
- `executor` + `mcp_client` → 复用已有的 `ios_mcp.rs` MCP 客户端（0.3.47 已写）
- `agent` loop → operit2-ios 主循环，锁屏护栏由 middle layer 强制
