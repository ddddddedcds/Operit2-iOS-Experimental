//
//  OperitShieldConfig.swift
//  ShieldConfig
//
//  ShieldConfiguration App Extension（iOS 16+）。
//  主 app（operit2）的 ScreenTimeServer.lock 支持携带 AI 生成的自定义文案
//  （主标题/副标题/按钮），写入 App Group 共享区；本扩展在应用被屏蔽时
//  读取该文案并渲染成系统屏蔽页（就是你截图里"保持活力和激情"那种效果）。
//
//  数据约定（App Group: group.com.ai.assistance.operit，UserDefaults）：
//    operit.shield.title      String  主标题（可含换行）
//    operit.shield.subtitle   String  副标题
//    operit.shield.button     String  主按钮文字（默认"好的"）
//  主 app 每次 lock 都会覆盖写入；unlock 时清除。
//

import ManagedSettings
import ManagedSettingsUI
import UIKit

private let appGroupID = "group.com.ai.assistance.operit"
private let shieldTitleKey = "operit.shield.title"
private let shieldSubtitleKey = "operit.shield.subtitle"
private let shieldButtonKey = "operit.shield.button"

final class OperitShieldConfig: ShieldConfigurationDataSource {
    override func configuration(
        shielding application: Application
    ) -> ShieldConfiguration {
        let defaults = UserDefaults(suiteName: appGroupID)
        let title = defaults?.string(forKey: shieldTitleKey) ?? "专注时间"
        let subtitle = defaults?.string(forKey: shieldSubtitleKey) ?? "休息一下，稍后再回来"
        let button = defaults?.string(forKey: shieldButtonKey) ?? "好的"
        return ShieldConfiguration(
            backgroundColor: .systemIndigo,
            title: ShieldConfiguration.Label(text: title, color: .white),
            subtitle: ShieldConfiguration.Label(text: subtitle, color: .white.withAlphaComponent(0.85)),
            primaryButtonLabel: ShieldConfiguration.Label(text: button, color: .white)
        )
    }

    override func configuration(
        shielding application: Application,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        configuration(shielding: application)
    }

    override func configuration(
        shielding webDomain: WebDomain
    ) -> ShieldConfiguration {
        configuration(shielding: Application(bundleIdentifier: "com.apple.mobilesafari"))
    }

    override func configuration(
        shielding webDomain: WebDomain,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        configuration(shielding: Application(bundleIdentifier: "com.apple.mobilesafari"))
    }
}
