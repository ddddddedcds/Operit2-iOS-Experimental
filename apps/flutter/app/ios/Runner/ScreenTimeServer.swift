//
//  ScreenTimeServer.swift
//  Runner
//
//  屏幕使用时间（FamilyControls）本地服务，iOS 16+。
//  链路：主 AI 工具（screen_time.*）→ Tools.Net.screenTime*（Rust 桥）
//        → 127.0.0.1:8891 文本协议 → 本服务 → 苹果官方 FamilyControls / ManagedSettings。
//  协议（每连接一行）：screen_time authorize | pick | lock <bundleId>[|<title>|<subtitle>|<button>] | unlock | status
//  首次使用：authorize 弹系统授权；pick 弹系统选择器（用户全选 → 记住）。
//  之后：lock <bundleId> / unlock 由 AI 按 bundle id 自由控制，无需再弹窗。
//  lock 支持可选自定义文案（AI 生成，经 ShieldConfiguration 扩展渲染）：
//    lock com.tencent.xin|保持专注|休息一下再回来|好的
//  文案字段用 | 分隔；缺省时扩展用默认文案。
//

import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import Network
import SwiftUI
import UIKit

private let appGroupID = "group.com.ai.assistance.operit"
private let monitoringKey = "operit.screenTime.monitoring"

@available(iOS 16.0, *)
final class ScreenTimeServer: NSObject {
  static let shared = ScreenTimeServer()

  private var listener: NWListener?
  private let queue = DispatchQueue(label: "operit.screen-time.server", qos: .userInitiated)
  private var selection: FamilyActivitySelection?
  private let selectionKey = "operit.screenTime.savedSelection"
  private var pickConn: NWConnection?

  func start() {
    guard listener == nil else { return }
    // 恢复上次用户选择（全选结果）
    if let data = UserDefaults.standard.data(forKey: selectionKey),
      let saved = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    {
      selection = saved
    }
    do {
      let l = try NWListener(using: .tcp, on: 8891)
      l.newConnectionHandler = { [weak self] conn in
        self?.handle(conn)
      }
      l.start(queue: queue)
      listener = l
    } catch {
      print("[ScreenTimeServer] start failed: \(error)")
    }
  }

  // MARK: - 连接处理

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
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    let cmd = parts.first ?? ""
    let arg = parts.count > 1 ? parts[1] : ""
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      switch cmd {
      case "authorize":
        self.authorize(conn: conn)
      case "pick":
        self.pick(conn: conn)
      case "lock":
        self.lock(bundleId: arg, conn: conn)
      case "unlock":
        self.unlock(conn: conn)
      case "status":
        self.status(conn: conn)
      case "monitor_start":
        self.monitorStart(args: arg, conn: conn)
      case "monitor_stop":
        self.monitorStop(conn: conn)
      case "usage":
        self.usage(conn: conn)
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

  // MARK: - 命令实现

  private func authorize(conn: NWConnection) {
    Task {
      do {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        let status = AuthorizationCenter.shared.authorizationStatus
        let ok = (status == .approved)
        reply(
          conn: conn,
          text: ok ? "OK|authorized" : "ERR|not_authorized: \(status.rawValue)"
        )
      } catch {
        reply(conn: conn, text: "ERR|\(error.localizedDescription)")
      }
    }
  }

  private func pick(conn: NWConnection) {
    guard pickConn == nil else {
      reply(conn: conn, text: "ERR|picker already active")
      return
    }
    pickConn = conn
    let base = selection ?? FamilyActivitySelection()
    let hosting = UIHostingController(
      rootView: ScreenTimePickerView(server: self, selection: base)
    )
    hosting.modalPresentationStyle = .pageSheet
    Self.topViewController()?.present(hosting, animated: true)
  }

  /// 用户在选择器里点了「完成」后回调（保持连接直到此刻，一次 pick 等待一次）。
  func pickerDone(_ newSelection: FamilyActivitySelection) {
    selection = newSelection
    if let data = try? JSONEncoder().encode(newSelection) {
      UserDefaults.standard.set(data, forKey: selectionKey)
    }
    if let conn = pickConn {
      pickConn = nil
      reply(
        conn: conn,
        text: "OK|saved \(newSelection.applicationTokens.count) apps"
      )
    }
  }

  private func lock(bundleId: String, conn: NWConnection) {
    // 支持 `lock <bundleId>[|<title>|<subtitle>|<button>]`：| 分隔自定义文案。
    let fields = bundleId.split(separator: "|", maxSplits: 3).map(String.init)
    let appId = fields[0]
    guard !appId.isEmpty else {
      reply(conn: conn, text: "ERR|missing bundle id")
      return
    }
    // 把 AI 生成的自定义文案写入 App Group（ShieldConfiguration 扩展读取渲染）。
    // 文案含 | 时视为用户/AI 提供的自定义；只传 bundleId 时清除旧文案回默认。
    if fields.count > 1 {
      let title = fields.count > 1 ? fields[1] : ""
      let subtitle = fields.count > 2 ? fields[2] : ""
      let button = fields.count > 3 ? fields[3] : ""
      let defaults = UserDefaults(suiteName: appGroupID)
      defaults?.set(title, forKey: "operit.shield.title")
      defaults?.set(subtitle, forKey: "operit.shield.subtitle")
      defaults?.set(button, forKey: "operit.shield.button")
    }
    // ManagedSettings.Application 可从 bundle id 公开构造并携带 token（iOS 15+）。
    let app = Application(bundleIdentifier: appId)
    guard let token = app.token else {
      reply(
        conn: conn,
        text: "ERR|cannot resolve app token for \(appId)（未安装或未授权屏幕使用时间）"
      )
      return
    }
    let store = ManagedSettingsStore()
    store.shield.applications = [token]
    reply(conn: conn, text: "OK|locked \(appId)")
  }

  private func unlock(conn: NWConnection) {
    let store = ManagedSettingsStore()
    store.shield.applications = []
    // 清除自定义屏蔽文案，回默认。
    let defaults = UserDefaults(suiteName: appGroupID)
    defaults?.removeObject(forKey: "operit.shield.title")
    defaults?.removeObject(forKey: "operit.shield.subtitle")
    defaults?.removeObject(forKey: "operit.shield.button")
    reply(conn: conn, text: "OK|unlocked all")
  }

  private func status(conn: NWConnection) {
    let st = AuthorizationCenter.shared.authorizationStatus
    reply(
      conn: conn,
      text: st == .approved ? "OK|authorized" : "OK|not_authorized"
    )
  }

  // MARK: - 使用时长监控（DeviceActivityMonitor 扩展 + App Group）

  /// monitor_start <bundleId1,bundleId2,...> <minutes>
  /// 为每个应用注册"当日累计使用超过 minutes 分钟"的事件，扩展触发后写入 App Group。
  private func monitorStart(args: String, conn: NWConnection) {
    let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty,
      let minutes = Int(parts[1]), minutes > 0
    else {
      reply(conn: conn, text: "ERR|usage: monitor_start <bundleIds> <minutes>")
      return
    }
    let bundleIds = parts[0].split(separator: ",").map(String.init)
    var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
    var started: [String] = []
    var failed: [String] = []
    for bundleId in bundleIds {
      let app = Application(bundleIdentifier: bundleId)
      guard let token = app.token else {
        failed.append(bundleId)
        continue
      }
      events[DeviceActivityEvent.Name(bundleId)] = DeviceActivityEvent(
        applications: [token],
        threshold: DateComponents(minute: minutes)
      )
      started.append(bundleId)
    }
    guard !started.isEmpty else {
      reply(conn: conn, text: "ERR|cannot resolve app tokens for \(failed.joined(separator: ","))")
      return
    }
    let schedule = DeviceActivitySchedule(
      intervalStart: DateComponents(hour: 0, minute: 0),
      intervalEnd: DateComponents(hour: 23, minute: 59),
      repeats: true
    )
    for bundleId in started {
      do {
        try DeviceActivityCenter().startMonitoring(
          DeviceActivityName(bundleId),
          during: schedule,
          events: [DeviceActivityEvent.Name(bundleId): events[DeviceActivityEvent.Name(bundleId)]!]
        )
      } catch {
        failed.append("\(bundleId)(\(error.localizedDescription))")
      }
    }
    if let data = try? JSONEncoder().encode(started) {
      UserDefaults.standard.set(data, forKey: monitoringKey)
    }
    reply(
      conn: conn,
      text: "OK|monitoring \(started.count) apps (overuse > \(minutes) min/day): \(started.joined(separator: ","))\(failed.isEmpty ? "" : "; failed: \(failed.joined(separator: ","))")"
    )
  }

  private func monitorStop(conn: NWConnection) {
    var names: [DeviceActivityName] = []
    if let data = UserDefaults.standard.data(forKey: monitoringKey),
      let saved = try? JSONDecoder().decode([String].self, from: data)
    {
      names = saved.map { DeviceActivityName($0) }
    }
    if !names.isEmpty {
      DeviceActivityCenter().stopMonitoring(names)
    }
    UserDefaults.standard.removeObject(forKey: monitoringKey)
    reply(conn: conn, text: "OK|stopped monitoring \(names.count) apps")
  }

  /// 读 App Group 里扩展写入的"超时"记录，返回文本列表。
  private func usage(conn: NWConnection) {
    guard let defaults = UserDefaults(suiteName: appGroupID) else {
      reply(conn: conn, text: "ERR|app group unavailable")
      return
    }
    let now = Date().timeIntervalSince1970
    var lines: [String] = []
    if let last = defaults.object(forKey: "usage_last_updated") as? Double {
      lines.append("last_update=\(Self.fmtTime(last))")
    }
    let prefix = "usage_"
    for (key, value) in defaults.dictionaryRepresentation() {
      guard key.hasPrefix(prefix),
        let ts = value as? Double, ts > 0
      else { continue }
      let bundleId = String(key.dropFirst(prefix.count))
      let mins = Int((now - ts) / 60)
      lines.append("\(bundleId)=overuse_since \(Self.fmtTime(ts)) (\(mins) min ago)")
    }
    reply(
      conn: conn,
      text: lines.isEmpty ? "OK|no overuse events" : "OK|\n" + lines.joined(separator: "\n")
    )
  }

  private static func fmtTime(_ ts: TimeInterval) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: ts))
  }

  // MARK: - 工具

  private static func topViewController() -> UIViewController? {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
      let root = scene.windows.first?.rootViewController
    else {
      return nil
    }
    var top = root
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }
}

/// FamilyActivityPicker 的 SwiftUI 包装：用户全选后点「完成」→ 回调保存。
@available(iOS 16.0, *)
struct ScreenTimePickerView: View {
  let server: ScreenTimeServer
  @Environment(\.dismiss) private var dismiss
  @State private var selection: FamilyActivitySelection

  init(server: ScreenTimeServer, selection: FamilyActivitySelection) {
    self.server = server
    _selection = State(initialValue: selection)
  }

  var body: some View {
    NavigationView {
      FamilyActivityPicker(selection: $selection)
        .navigationTitle("选择要控制的应用")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("完成") {
              server.pickerDone(selection)
              dismiss()
            }
          }
          ToolbarItem(placement: .cancellationAction) {
            Button("取消") { dismiss() }
          }
        }
    }
  }
}
