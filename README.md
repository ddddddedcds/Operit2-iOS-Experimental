# Operit2-iOS-Experimental

> **Operit2 的 iOS 实验性移植**（非官方分支，改编自 [AAswordman/Operit2](https://github.com/AAswordman/Operit2)）。
> 两条线：**越狱完整版**（rootless deb）+ **非越狱最小可用版**（AI 聊天 + 内置 iSH 终端）。
> 实验性软件，不稳定，风险自负。

---

## 两条线（0.3.86 实机验证）

| 线 | 形态 | 能力 | 验证状态 |
|---|---|---|---|
| **越狱完整版** | rootless deb（Dopamine） | Siri 集成 / 通知拦截 / 锁屏会话 / 应用锁 / 屏幕使用时间 / 设备自动化 / iSH 终端 | ✅ iOS 16.7 (A14) + iOS 15.7 (A12) |
| **非越狱最小版** | ipa（Sideloadly 自签） | **AI 聊天 + 内置 iSH 终端** | ✅ 标准沙盒实机验证（0.3.86） |

---

## ⚠️ 重要声明

- **实验性、不稳定**，bug 链式暴露（已知遗留问题见 [HANDOVER.md](./HANDOVER.md) 第 8 节）。
- **越狱版**：包含 root 权限与锁应用能力，安装/使用有风险；**只建议有越狱经验的开发者测试**。
- **nonjb 版**：仅聊天 + iSH 终端；自动化/通知/权限等能力依赖越狱环境，**不要有功能预期**。
- roothide 版**已停止支持**；rootful 越狱 / TrollStore 未专门适配。
- 本仓库使用 vibe coding 改编，代码质量按实验标准对待，**接手前建议评估架构重做**。

---

## 内置 iSH 终端

- **kernel=ish**（iSH 纯用户态模拟器 + asbestos JIT）+ **aarch64 Alpine 3.19** guest（arm64 分支：[OpenMinis/ish-arm64](https://github.com/OpenMinis/ish-arm64)）。
- rootfs 自带**国内镜像源（清华）+ resolv.conf（DNS）**，`apk add git neofetch` 开箱可用。
- 越狱版与非越狱版均内置；详情见 [HANDOVER.md](./HANDOVER.md) 8.9。

---

## 功能概览（验证状态）

- ✅ **越狱版真机验证**：Siri 集成（识别→会话同步→角色一致回答→卡片显示）、通知拦截+记录、锁屏会话、应用锁、深链唤起、屏幕使用时间锁应用、**iSH 终端**
- 🟡 **越狱版未端到端验证**：权限全家桶（TCCServer）、设置面板、控制中心模块
- ✅ **nonjb 版实机验证**：AI 聊天 + iSH 终端（0.3.86，标准沙盒）

---

## 快速开始

完整步骤见 [HANDOVER.md](./HANDOVER.md)（第 5 节打包、第 9 节 AI 接手指南）：

```bash
# 越狱完整版（rootless deb）
# 1. CI 出 UNSIGNED Runner.app（手动 dispatch ios-flutter-build，分支 feat/ios-jailbreak-preview4）
# 2. 编译 tweak（FAT arm64+arm64e）+ daemon（cargo build --target aarch64-apple-ios --release）
# 3. OPERIT_PACK_SCHEME=rootless APP_SRC=<CI包> bash hosts/ios/deb/build_deb.sh
# 4. sudo dpkg -i + respring

# 非越狱最小版（聊天 + iSH 终端）
# 1. bash hosts/ios/deb/build_nonjb_ipa.sh   # 产出 operit2-ios_<ver>_nonjb_iphoneos-arm64.ipa
# 2. Sideloadly / AltStore 用个人 Apple ID 重签安装
```

**最低系统要求**：
- **nonjb 版：iOS 16.2+**（Runner MinimumOSVersion，自签安装工具会检查）
- **越狱版**：需 Dopamine rootless；dpkg 安装不卡版本，实测 iOS 16.7（A14）与 iOS 15.7（A12），但私有 API 按 16.7 开发，低版本功能可能有差异

**已测试环境**：Mac（Theos + Xcode iOS SDK + Rust iOS target）+ Dopamine rootless iOS 16.7（iPhone13,4 / A14）、iOS 15.7（A12）；nonjb 版任意非越狱 iPhone（≥16.2）。

---

## 依赖

- **越狱版**：com.witchan.ios-mcp（自动化后端）、preferenceloader、com.opa334.ccsupport、ellekit、AppSync Unified、ldid（详见 HANDOVER）
- **nonjb 版**：无越狱依赖，仅需自签安装（Sideloadly/AltStore）

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

## 部分使用截图

> iOS 16.7 实测界面。不同 iOS 版本的私有 API 可能有变动，且本项目仅做实验验证，实际表现请以真机为准。

<table align="center">
  <tr>
    <td align="center"><img width="250" alt="截图 1" src="https://github.com/user-attachments/assets/e6817a6c-f73e-4b43-ad67-17675622b01e" /><br/><sub>截图 1</sub></td>
    <td align="center"><img width="250" alt="截图 2" src="https://github.com/user-attachments/assets/db0296a8-cf94-4f88-a331-4af7e83956cc" /><br/><sub>截图 2</sub></td>
    <td align="center"><img width="250" alt="截图 3" src="https://github.com/user-attachments/assets/b5ac3ddb-4732-4e14-a5f5-0298b19a9e10" /><br/><sub>截图 3</sub></td>
  </tr>
  <tr>
    <td align="center"><img width="250" alt="截图 4" src="https://github.com/user-attachments/assets/081daae9-ad0d-49ee-8882-3ada1e28c425" /><br/><sub>截图 4</sub></td>
    <td align="center"><img width="250" alt="截图 5" src="https://github.com/user-attachments/assets/3de87155-c4d0-4027-bfa0-28cbb7db1a8e" /><br/><sub>截图 5</sub></td>
    <td align="center"><img width="250" alt="截图 6" src="https://github.com/user-attachments/assets/f40a12e5-55f0-4f69-83a2-e7d301f17a8e" /><br/><sub>截图 6</sub></td>
  </tr>
  <tr>
    <td align="center"><img width="250" alt="截图 7" src="https://github.com/user-attachments/assets/7d0670a0-ceb0-420a-890d-e76465fe2499" /><br/><sub>截图 7</sub></td>
    <td align="center"><img width="250" alt="截图 8" src="https://github.com/user-attachments/assets/50d6183a-baa0-4fd8-a5db-1f1dbca9c255" /><br/><sub>截图 8</sub></td>
    <td align="center"><img width="250" alt="截图 9" src="https://github.com/user-attachments/assets/5eef5348-0c48-456c-8d89-34500bc536fc" /><br/><sub>截图 9</sub></td>
  </tr>
</table>
