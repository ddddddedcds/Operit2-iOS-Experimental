# Operit2-iOS-Jailbreak-POC

> **Operit2 越狱 iOS 移植 —— 概念验证（POC）**
> 探明"越狱 iOS + AI 深度集成"这条路的可行性。
> 非官方分支，不代表官方立场！！！此POC使用风险后果自负！！！改编自 [AAswordman/Operit2](https://github.com/AAswordman/Operit2)。

---

## ⚠️ 重要声明（安装/使用前必读）

- **这是 POC，不是产品。使用vibe coding进行改编。**：实验性、不稳定、整体设计存在先天问题，**bug 链式暴露**（已知遗留问题见 HANDOVER.md 第 8/10 节）。
- **仅 Dopamine rootless（iOS 16.7）真机验证过**；非越狱（IPA）版**未验证，不可用**。（roothide 版已停止支持）
- **包含 root 权限与锁应用能力**：安装/使用有风险，可能导致数据丢失或系统异常。
- **只建议有越狱经验的开发者安装测试**；请勿作为日常工具使用。
目前环境测试：Dopamine ios16.7 a14 正常
                    ios15.7 a12 正常
            （roothide 版已停止支持、不再维护；Relaxin/Dopamine rootless 系适配见 HANDOVER）
            (rootful越狱和trollstore均未做专门适配）
---

## 这个 POC 探明了什么

| 结论 | 详情 |
|---|---|
| **可行性** | 越狱 iOS + AI 深度集成（Siri 语音入口 / 通知拦截 / 权限调用 / 设备自动化）可行 |
| **hook 点地图** | Siri（AFConnection）、通知（BBObserver）、锁屏（Darwin notify）、权限（公开 API）——全部 iOS 16.7 实测 |
| **方法论** | 参考已有实现优先、连接层 > UI 层、真机 probe 先行 |
| **反面结论** | **接手前应评估架构重做** |

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
- **内置 iSH 终端（本 fork 集成，非自研）**：
  - iSH 用户态 Linux 模拟器（kernel=ish + asbestos JIT）：[ish-app/ish](https://github.com/ish-app/ish)
  - arm64 guest 支持分支（A2 集成所用源码，pin commit 54ca185b）：[OpenMinis/ish-arm64](https://github.com/OpenMinis/ish-arm64)
  - guest 根文件系统：Alpine Linux aarch64（v3.19 minirootfs，[alpinelinux.org](https://alpinelinux.org)）
  - guest `/bin/sh`：busybox（静态链接，[busybox.net](https://busybox.net)）
  - 文件系统层：iSH 的 fakefs（fs/fakefs，含 meta.db + data/ 布局）
- 免责声明见 deb 包 control（实验性软件，使用风险自负）

## 部分使用截图（部分功能并不完全正常，因为每个ios版本的私有API可能会发生变动，而且仅做概念验证，可能会有潜在的使用风险！！！）
<img width="1284" height="2778" alt="IMG_4290" src="https://github.com/user-attachments/assets/e6817a6c-f73e-4b43-ad67-17675622b01e" />
<img width="1284" height="2778" alt="IMG_4289" src="https://github.com/user-attachments/assets/db0296a8-cf94-4f88-a331-4af7e83956cc" />
<img width="1284" height="2778" alt="IMG_4288" src="https://github.com/user-attachments/assets/b5ac3ddb-4732-4e14-a5f5-0298b19a9e10" />
<img width="1284" height="2778" alt="IMG_4286" src="https://github.com/user-attachments/assets/081daae9-ad0d-49ee-8882-3ada1e28c425" />
<img width="1284" height="2778" alt="IMG_4283" src="https://github.com/user-attachments/assets/3de87155-c4d0-4027-bfa0-28cbb7db1a8e" />
<img width="1284" height="2778" alt="IMG_4271 2" src="https://github.com/user-attachments/assets/f40a12e5-55f0-4f69-83a2-e7d301f17a8e" />
<img width="1284" height="1614" alt="IMG_4264 2" src="https://github.com/user-attachments/assets/7d0670a0-ceb0-420a-890d-e76465fe2499" />
<img width="1284" height="2778" alt="IMG_4215" src="https://github.com/user-attachments/assets/50d6183a-baa0-4fd8-a5db-1f1dbca9c255" />
<img width="1279" height="2769" alt="910" src="https://github.com/user-attachments/assets/5eef5348-0c48-456c-8d89-34500bc536fc" />

