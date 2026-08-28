//
//  NotifyServer.swift
//  Runner
//
//  AI 主动联系用户服务（经 OperitLocalServer 单端口 8891 路由）：
//    notify <delaySec> <标题>|<内容>   本地通知（delay=0 立即；>0 定时提醒）
//    live_start  <标题>|<内容>         启动实时活动（灵动岛 / 锁屏，iOS 16.1+）
//    live_update <标题>|<内容>         更新实时活动
//    live_end                          结束实时活动
//  链路：AI 工具 → Tools.Net.notify*/liveActivity*（Rust）→ 127.0.0.1:8891（OperitLocalServer）→ 本服务
//  → UNUserNotificationCenter / ActivityKit（灵动岛由 LiveActivityWidget 扩展渲染）。
//

import ActivityKit
import Foundation
import Network
import UIKit
import UserNotifications

/// 灵动岛实时活动的内容模型（主 app 与 LiveActivityWidget 扩展各编译一份相同定义）。
/// ActivityAttributes / ActivityKit 实时活动 API 实际需 iOS 16.2+（request(attributes:content:pushType:) / ActivityContent / update），故整体守卫 16.2。
@available(iOS 16.2, *)
struct OperitLiveActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var title: String
    var body: String
  }
  var name: String
}

final class NotifyServer: NSObject {
  static let shared = NotifyServer()

  private var liveActivity: Any?

  /// 由 OperitLocalServer（单端口 8891）按首 token（notify/live_*/notif_*/usage_report）路由至此。
  func dispatch(_ line: String, conn: NWConnection) {
    let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
    let cmd = parts.first ?? ""
    let rest = parts.count > 1 ? parts[1...].joined(separator: " ") : ""
    print("[NotifyServer] received: \(line) → cmd=\(cmd) rest=\(rest)")
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      switch cmd {
      case "notify":
        self.notify(args: rest, conn: conn)
      case "live_start":
        if #available(iOS 16.2, *) {
          self.liveStart(args: rest, conn: conn)
        } else {
          self.reply(conn: conn, text: "ERR|live activities require iOS 16.2+")
        }
      case "live_update":
        if #available(iOS 16.2, *) {
          self.liveUpdate(args: rest, conn: conn)
        } else {
          self.reply(conn: conn, text: "ERR|live activities require iOS 16.2+")
        }
      case "live_end":
        if #available(iOS 16.2, *) {
          self.liveEnd(conn: conn)
        } else {
          self.reply(conn: conn, text: "ERR|live activities require iOS 16.2+")
        }
      case "notif_list":
        self.notifList(args: rest, conn: conn)
      case "notif_block":
        self.notifBlock(args: rest, conn: conn, block: true)
      case "notif_unblock":
        self.notifBlock(args: rest, conn: conn, block: false)
      case "notif_blocked":
        self.notifBlocked(conn: conn)
      case "usage_report":
        self.usageReport(args: rest, conn: conn)
      default:
        self.reply(conn: conn, text: "ERR|unknown command: \(cmd)")
      }
    }
  }

  private func reply(conn: NWConnection, text: String) {
    print("[NotifyServer] reply: \(text)")
    conn.send(
      content: Data((text + "\n").utf8),
      completion: .contentProcessed { _ in conn.cancel() }
    )
  }

  /// notify <delaySec> <标题>|<内容>
  private func notify(args: String, conn: NWConnection) {
    let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
    let delay = Double(parts.first ?? "0") ?? 0
    let text = parts.count > 1 ? parts[1] : ""
    let (title, body) = splitTitleBody(text)
    guard !title.isEmpty else {
      reply(conn: conn, text: "ERR|usage: notify <delaySec> <标题>|<内容>")
      return
    }
    requestAuthorization { [weak self] granted in
      guard let self else { return }
      guard granted else {
        self.reply(conn: conn, text: "ERR|notification permission denied")
        return
      }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body.isEmpty ? "" : body
      content.sound = .default
      let trigger: UNNotificationTrigger? =
        delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false) : nil
      let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: trigger
      )
      UNUserNotificationCenter.current().add(request) { error in
        self.reply(
          conn: conn,
          text: error == nil
            ? "OK|notification scheduled\(delay > 0 ? " in \(Int(delay))s" : "")"
            : "ERR|\(error!.localizedDescription)"
        )
      }
    }
  }

  /// live_start <标题>|<内容>
  @available(iOS 16.2, *)
  private func liveStart(args: String, conn: NWConnection) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      reply(conn: conn, text: "ERR|live activities not enabled")
      return
    }
    let (title, body) = splitTitleBody(args)
    guard !title.isEmpty else {
      reply(conn: conn, text: "ERR|usage: live_start <标题>|<内容>")
      return
    }
    let state = OperitLiveActivityAttributes.ContentState(title: title, body: body)
    do {
      let activity = try Activity<OperitLiveActivityAttributes>.request(
        attributes: OperitLiveActivityAttributes(name: "ai"),
        content: ActivityContent(state: state, staleDate: nil),
        pushType: nil
      )
      liveActivity = activity
      reply(conn: conn, text: "OK|live activity started")
    } catch {
      reply(conn: conn, text: "ERR|\(error.localizedDescription)")
    }
  }

  /// live_update <标题>|<内容>
  @available(iOS 16.2, *)
  private func liveUpdate(args: String, conn: NWConnection) {
    guard let liveActivity = liveActivity as? Activity<OperitLiveActivityAttributes> else {
      reply(conn: conn, text: "ERR|no active live activity")
      return
    }
    let (title, body) = splitTitleBody(args)
    let state = OperitLiveActivityAttributes.ContentState(
      title: title.isEmpty ? " " : title,
      body: body
    )
    Task {
      await liveActivity.update(ActivityContent(state: state, staleDate: nil))
      reply(conn: conn, text: "OK|live activity updated")
    }
  }

  @available(iOS 16.2, *)
  private func liveEnd(conn: NWConnection) {
    guard let liveActivity = liveActivity as? Activity<OperitLiveActivityAttributes> else {
      reply(conn: conn, text: "OK|no active live activity")
      return
    }
    self.liveActivity = nil
    Task {
      await liveActivity.end()
      reply(conn: conn, text: "OK|live activity ended")
    }
  }

  // MARK: - 通知读取 / 拦截（tweak 采集 + 名单）

  /// 通知采集文件：SpringBoard tweak 把每条通知（bid/title/body/ts）写到这里。
  private var notificationsPath: String {
    "/var/mobile/.operit/notifications.json"
  }
  /// 通知拦截名单（独立于 app 锁定；tweak 读它决定拦谁的横幅/锁屏/声音）。
  private var notifBlockPath: String {
    "/var/mobile/.operit/notif_block.plist"
  }

  /// notif_list [limit] —— 读 tweak 采集的通知，返回最近 limit 条（默认 20）。
  private func notifList(args: String, conn: NWConnection) {
    let limit = Int(args.trimmingCharacters(in: .whitespaces)) ?? 20
    guard let data = FileManager.default.contents(atPath: notificationsPath) else {
      reply(conn: conn, text: "ERR|no notifications captured yet")
      return
    }
    guard
      let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      reply(conn: conn, text: "ERR|bad notifications.json")
      return
    }
    let items = Array(arr.prefix(max(1, min(limit, 100))))
    var lines: [String] = []
    for it in items {
      let bid = it["bid"] as? String ?? "?"
      let title = it["title"] as? String ?? ""
      let body = it["body"] as? String ?? ""
      let ts = it["ts"] as? Int64 ?? 0
      let date = ts > 0
        ? DateFormatter.localizedString(from: Date(timeIntervalSince1970: TimeInterval(ts)), dateStyle: .short, timeStyle: .short)
        : "?"
      lines.append("[\(date)] \(bid): \(title) — \(body)")
    }
    reply(conn: conn, text: lines.isEmpty ? "OK|(empty)" : "OK|\n" + lines.joined(separator: "\n"))
  }

  /// notif_block <bundleId> / notif_unblock <bundleId> —— 增删通知拦截名单。
  private func notifBlock(args: String, conn: NWConnection, block: Bool) {
    let bid = args.trimmingCharacters(in: .whitespaces)
    guard !bid.isEmpty else {
      reply(conn: conn, text: "ERR|usage: notif_\(block ? "block" : "unblock") <bundleId>")
      return
    }
    var dict = (NSDictionary(contentsOfFile: notifBlockPath) as? [String: Any]) ?? [:]
    if block {
      dict[bid] = ["ts": Int64(Date().timeIntervalSince1970)]
    } else {
      dict.removeValue(forKey: bid)
    }
    let ok = (dict as NSDictionary).write(toFile: notifBlockPath, atomically: true)
    reply(conn: conn, text: ok ? "OK|\(block ? "blocked" : "unblocked") \(bid)" : "ERR|write failed")
  }

  /// notif_blocked —— 列出当前通知拦截名单。
  private func notifBlocked(conn: NWConnection) {
    guard let dict = NSDictionary(contentsOfFile: notifBlockPath) as? [String: Any], !dict.isEmpty else {
      reply(conn: conn, text: "OK|(none)")
      return
    }
    let ids = dict.keys.sorted()
    reply(conn: conn, text: "OK|" + ids.joined(separator: ", "))
  }

  /// usage_report [limit] —— 读 tweak 采集的前台使用记录（usage.json）：
  /// 当前前台 app + 最近使用历史（时间倒序）+ 各 app 累计时长（秒）。
  /// 数据源：SpringBoard tweak 的 usage_tick 每 150ms/1s/5s（锁屏）写一次。
  private func usageReport(args: String, conn: NWConnection) {
    let limit = Int(args.trimmingCharacters(in: .whitespaces)) ?? 20
    guard let data = FileManager.default.contents(atPath: usagePath) else {
      reply(conn: conn, text: "ERR|no usage data yet")
      return
    }
    guard
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      reply(conn: conn, text: "ERR|bad usage.json")
      return
    }
    var lines: [String] = []
    // 当前前台
    if let active = root["active"] as? [String: Any],
      let bid = active["bid"] as? String, !bid.isEmpty
    {
      let since = (active["since"] as? Int64) ?? 0
      let dur = since > 0 ? max(0, Int64(Date().timeIntervalSince1970) - since) : 0
      lines.append("当前前台: \(bid)（已用 \(dur)s）")
    }
    // 历史（时间倒序）
    if let hist = root["history"] as? [[String: Any]], !hist.isEmpty {
      var agg: [String: Int64] = [:]  // 各 app 累计秒
      let items = Array(hist.prefix(max(1, min(limit, 100))))
      lines.append("最近使用:")
      for it in items {
        let bid = it["bid"] as? String ?? "?"
        let start = it["start"] as? Int64 ?? 0
        let end = it["end"] as? Int64 ?? 0
        let dur = max(0, end - start)
        let date = start > 0
          ? DateFormatter.localizedString(from: Date(timeIntervalSince1970: TimeInterval(start)), dateStyle: .none, timeStyle: .short)
          : "?"
        lines.append("  \(date) \(bid) \(dur)s")
        agg[bid, default: 0] += dur
      }
      lines.append("累计:")
      for (bid, dur) in agg.sorted(by: { $0.value > $1.value }) {
        lines.append("  \(bid) \(dur)s")
      }
    } else {
      lines.append("(无使用记录)")
    }
    // 锁屏/解锁会话（手机使用时段）
    if let sessions = root["sessions"] as? [[String: Any]], !sessions.isEmpty {
      lines.append("使用时段(锁屏/解锁):")
      let items = Array(sessions.prefix(min(max(1, limit), 30)))
      let fmt = DateFormatter()
      fmt.dateFormat = "HH:mm"
      for s in items {
        let lock = (s["lock"] as? Int64) ?? 0
        let unlock = (s["unlock"] as? Int64) ?? 0
        let dur = max(0, unlock - lock)
        let lockStr = lock > 0 ? fmt.string(from: Date(timeIntervalSince1970: TimeInterval(lock))) : "?"
        let unlockStr = unlock > 0 ? fmt.string(from: Date(timeIntervalSince1970: TimeInterval(unlock))) : "?"
        let durStr = dur >= 3600 ? String(format: "%dh%dm", dur / 3600, (dur % 3600) / 60) : "\(dur / 60)m\(dur % 60)s"
        lines.append("  \(lockStr) 锁屏 → \(unlockStr) 解锁（锁了 \(durStr)）")
      }
    }
    reply(conn: conn, text: "OK|\n" + lines.joined(separator: "\n"))
  }

  /// usage.json 路径（tweak 采集）。
  private var usagePath: String {
    "/var/mobile/.operit/usage.json"
  }

  // MARK: - 工具

  private func requestAuthorization(_ done: @escaping (Bool) -> Void) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
      granted, _ in
      DispatchQueue.main.async { done(granted) }
    }
  }

  private func splitTitleBody(_ text: String) -> (String, String) {
    let parts = text.split(separator: "|", maxSplits: 1).map(String.init)
    return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
  }
}
