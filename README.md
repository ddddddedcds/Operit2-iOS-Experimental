# Operit2-iOS-Jailbreak-POC

> **Operit2 越狱 iOS 移植 —— 概念验证（POC）**
> 探明"越狱 iOS + AI 深度集成"这条路的可行性。
> 非官方分支，改编自 [AAswordman/Operit2](https://github.com/AAswordman/Operit2)。

---

## ⚠️ 重要声明（安装/使用前必读）

- **这是 POC，不是产品**：实验性、不稳定、整体设计存在先天问题，**bug 链式暴露**（已知遗留问题见 HANDOVER.md 第 8/10 节）。
- **仅 Dopamine rootless（iOS 16.7）真机验证过**；roothide 版与非越狱（IPA）版**未验证，不可用**。
- **包含 root 权限与锁应用能力**：安装/使用有风险，可能导致数据丢失或系统异常。
- **只建议有越狱经验的开发者安装测试**；请勿作为日常工具使用。
- **接续方已明确**：operit2 官方有意愿接手，当前因非越狱版排期忙不过来，本 POC **暂存待取**。

---

## 这个 POC 探明了什么

| 结论 | 详情 |
|---|---|
| **可行性** | 越狱 iOS + AI 深度集成（Siri 语音入口 / 通知拦截 / 权限调用 / 设备自动化）可行 |
| **hook 点地图** | Siri（AFConnection）、通知（BBObserver）、锁屏（Darwin notify）、权限（公开 API）——全部 iOS 16.7 实测 |
| **方法论** | 参考已有实现优先、连接层 > UI 层、真机 probe 先行 |
| **反面结论** | Operit2 的 Flutter+Rust 架构硬移植进越狱 iOS 不划算——**接手前应评估架构重做** |

完整细节见 **[HANDOVER.md](./HANDOVER.md)**（13 节工程手册：架构 / 运行原理 / 协议 / 打包流程 / 遗留问题 / 私有 API 专题 / 依赖清单 / AI 接手指南）。

---

## 功能概览（验证状态）

- ✅ **真机验证**：Siri 集成（识别→会话同步→角色一致回答→卡片显示）、通知拦截+记录、锁屏会话、应用锁、深链唤起、屏幕使用时间锁应用
- 🟡 **未端到端验证**：权限全家桶（TCCServer）、设置面板、控制中心模块、installed_apps
- ⏳ **POC 暂未解决**：Siri 气泡替换、Siri TTS 朗读（详见 HANDOVER）

---

## 快速开始（构建 → 装机）

完整步骤见 HANDOVER.md **第 9 节（AI 接手快速启动指南）**，要点：

```bash
# 1. CI 出 UNSIGNED Runner.app（手动 dispatch ios-flutter-build，分支选 feat/ios-jailbreak-preview4）
# 2. 编译 tweak（FAT arm64+arm64e）+ daemon（cargo build --target aarch64-apple-ios --release）
# 3. ldid 签名 CC 模块 + 升版本号
# 4. OPERIT_PACK_SCHEME=rootless APP_SRC=<CI包> bash build_deb.sh   # ⚠️ 必须用 build_deb.sh，不要单独跑 packdeb.py
# 5. sudo dpkg -i + respring
```

**已经过测试的环境要求**（其他环境请自行尝试）：

- Mac（Theos + Xcode iOS SDK + Rust iOS target）
- Dopamine rootless iOS 16.7 设备（iPhone13,4 / A14）

---

## 依赖插件

- **com.witchan.ios-mcp**（设备自动化后端，必需）
- **preferenceloader**（设置面板）
- **com.opa334.ccsupport**（控制中心模块）
- ellekit / AppSync Unified / ldid（运行必需，详见 HANDOVER 第 13 节）

---

## 来源与许可

- 改编自 [AAswordman/Operit2](https://github.com/AAswordman/Operit2)（非官方分支）
- 设备自动化后端：[witchan/ios-mcp](https://github.com/witchan/ios-mcp)（本 fork 用适配版）
- 免责声明见 deb 包 control（实验性软件，使用风险自负）
