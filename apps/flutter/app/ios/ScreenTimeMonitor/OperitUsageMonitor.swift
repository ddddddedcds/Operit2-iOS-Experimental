//
//  OperitUsageMonitor.swift
//  ScreenTimeMonitor
//
//  DeviceActivityMonitor App Extension（iOS 16+）。
//  主 app（operit2）为每个被监控应用注册独立监控（DeviceActivityName = bundle id）
//  与超时事件（DeviceActivityEvent, threshold = 当日累计使用分钟数）。
//  本扩展在事件阈值达成时，把「bundle id → 触发时间」写入 App Group 共享区，
//  主 app 的 ScreenTimeServer 读取后报告给 AI（吃醋巡检）。
//

import DeviceActivity
import Foundation

private let appGroupID = "group.com.ai.assistance.operit"

final class OperitUsageMonitor: DeviceActivityMonitor {
    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventDidReachThreshold(event, activity: activity)
        // 事件名 = bundle id（主 app 注册时约定），把它记进 App Group。
        let bundleId = event.rawValue
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(Date().timeIntervalSince1970, forKey: "usage_\(bundleId)")
        defaults?.set(Date().timeIntervalSince1970, forKey: "usage_last_updated")
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
    }
}
