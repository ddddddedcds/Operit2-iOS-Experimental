//
//  NotifyServer.swift
//  Runner
//
//  AI 主动联系用户服务（TCP 8893）：
//    notify <delaySec> <标题>|<内容>   本地通知（delay=0 立即；>0 定时提醒）
//    live_start  <标题>|<内容>         启动实时活动（灵动岛 / 锁屏，iOS 16.1+）
//    live_update <标题>|<内容>         更新实时活动
//    live_end                          结束实时活动
//  链路：AI 工具 → Tools.Net.notify*/liveActivity*（Rust）→ 127.0.0.1:8893 → 本服务
//  → UNUserNotificationCenter / ActivityKit（灵动岛由 LiveActivityWidget 扩展渲染）。
//

import ActivityKit
import Foundation
import Network
import UIKit
import UserNotifications

/// 灵动岛实时活动的内容模型（主 app 与 LiveActivityWidget 扩展各编译一份相同定义）。
struct OperitLiveActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var title: String
    var body: String
  }
  var name: String
}

final class NotifyServer: NSObject {
  static let shared = NotifyServer()

  private var listener: NWListener?
  private let queue = DispatchQueue(label: "operit.notify.server", qos: .userInitiated)
  private var liveActivity: Activity<OperitLiveActivityAttributes>?

  func start() {
    guard listener == nil else { return }
    do {
      let l = try NWListener(using: .tcp, on: 8893)
      l.newConnectionHandler = { [weak self] conn in
        self?.handle(conn)
      }
      l.start(queue: queue)
      listener = l
    } catch {
      print("[NotifyServer] start failed: \(error)")
    }
  }

  private func handle(_ conn: NWConnection) {
    conn.start(queue: queue)
    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
      [weak self] data, _, _, _ in
      guard let self,
        let data,
        let line = String(data: data, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !line.isEmpty
      else {
        conn.cancel()
        return
      }
      self.dispatch(line, conn: conn)
    }
  }

  private func dispatch(_ line: String, conn: NWConnection) {
    let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
    let cmd = parts.first ?? ""
    let rest = parts.count > 1 ? parts[1...].joined(separator: " ") : ""
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      switch cmd {
      case "notify":
        self.notify(args: rest, conn: conn)
      case "live_start":
        self.liveStart(args: rest, conn: conn)
      case "live_update":
        self.liveUpdate(args: rest, conn: conn)
      case "live_end":
        self.liveEnd(conn: conn)
      default:
        self.reply(conn: conn, text: "ERR|unknown command: \(cmd)")
      }
    }
  }

  private func reply(conn: NWConnection, text: String) {
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
        content: ActivityContent(state: state),
        pushType: nil
      )
      liveActivity = activity
      reply(conn: conn, text: "OK|live activity started")
    } catch {
      reply(conn: conn, text: "ERR|\(error.localizedDescription)")
    }
  }

  /// live_update <标题>|<内容>
  private func liveUpdate(args: String, conn: NWConnection) {
    guard let liveActivity else {
      reply(conn: conn, text: "ERR|no active live activity")
      return
    }
    let (title, body) = splitTitleBody(args)
    let state = OperitLiveActivityAttributes.ContentState(
      title: title.isEmpty ? " " : title,
      body: body
    )
    Task {
      await liveActivity.update(using: state)
      reply(conn: conn, text: "OK|live activity updated")
    }
  }

  private func liveEnd(conn: NWConnection) {
    guard let liveActivity else {
      reply(conn: conn, text: "OK|no active live activity")
      return
    }
    self.liveActivity = nil
    Task {
      await liveActivity.end()
      reply(conn: conn, text: "OK|live activity ended")
    }
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
