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
  private var pickConn: NWConnection?
  private var authorizeConn: NWConnection?

  func start() {
    guard listener == nil else { return }
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
    // 协议兼容：Rust 端发 "screen_time <cmd> [args]"，剥掉 "screen_time " 命名空间前缀。
    let stripped = line.hasPrefix("screen_time ") ? String(line.dropFirst("screen_time ".count)) : line
    let parts = stripped.split(separator: " ", maxSplits: 1).map(String.init)
    let cmd = parts.first ?? ""
    let arg = parts.count > 1 ? parts[1] : ""
    print("[ScreenTimeServer] received: \(line) → cmd=\(cmd) arg=\(arg)")
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
    print("[ScreenTimeServer] reply: \(text)")
    conn.send(
      content: Data((text + "\n").utf8),
      completion: .contentProcessed { _ in conn.cancel() }
    )
  }

  // MARK: - 命令实现

  private func authorize(conn: NWConnection) {
    // 越狱实现：不需要 FamilyControls 系统授权（ad-hoc 签名下必失败）。
    // 弹仿官方确认页，用户点"允许"即标记，返回 OK。
    guard authorizeConn == nil else {
      reply(conn: conn, text: "ERR|authorize already active")
      return
    }
    authorizeConn = conn
    let vc = AppLockAuthorizeViewController(appName: "Operit") { [weak self] allowed in
      guard let self else { return }
      if allowed {
        UserDefaults.standard.set(true, forKey: "operit.applock.authorized")
        self.reply(conn: conn, text: "OK|authorized")
      } else {
        self.reply(conn: conn, text: "ERR|denied by user")
      }
      self.authorizeConn = nil
    }
    vc.modalPresentationStyle = .pageSheet
    Self.topViewController()?.present(vc, animated: true)
    print("[ScreenTimeServer] authorize UI presented")
  }

  private func pick(conn: NWConnection) {
    guard pickConn == nil else {
      reply(conn: conn, text: "ERR|picker already active")
      return
    }
    pickConn = conn
    let nav = UINavigationController(
      rootViewController: AppLockPickerViewController(
        onDone: { [weak self] bids in
          guard let self else { return }
          if bids.isEmpty {
            self.reply(conn: conn, text: "OK|no apps selected")
          } else {
            // 写入"AI 可管理名单"（不锁定——AI 之后可自由 lock/unlock 这些 app）
            let ok = (bids as NSArray).write(toFile: Self.appManagedPath, atomically: true)
            self.reply(
              conn: conn,
              text: ok
                ? "OK|managed \(bids.count) apps，AI 现可自由锁定/解锁：\(bids.joined(separator: ","))"
                : "ERR|写可管理名单失败"
            )
          }
          self.pickConn = nil
        },
        onCancel: { [weak self] in
          guard let self else { return }
          self.reply(conn: conn, text: "OK|cancelled")
          self.pickConn = nil
          Self.topViewController()?.dismiss(animated: true)
        }
      )
    )
    nav.modalPresentationStyle = .pageSheet
    Self.topViewController()?.present(nav, animated: true)
    print("[ScreenTimeServer] pick UI presented")
  }

  /// 锁应用名单文件：tweak（operit-sb.x）启动拦截读取的真实根路径。
  /// rootless 下 app 无沙箱，直接写真实根；SpringBoard（mobile）同路径可读。
  /// roothide 双视图下 app 的 /var/mobile 落到 jbroot 视图，与 SpringBoard 不共享——
  /// 该场景需走 daemon(8890) 中转（TODO，当前设备为 rootless）。
  private static let appLockPath = "/var/mobile/.operit/app_lock.plist"
  private static let appManagedPath = "/var/mobile/.operit/app_managed.plist"

  /// 用户通过 pick 一次性授权的"AI 可自由管理"的应用集合。
  /// AI 的 lock/unlock 只能作用于这个集合内的 app（unlock 不受限，防止锁死）。
  private static func managedApps() -> Set<String> {
    Set(NSArray(contentsOfFile: appManagedPath) as? [String] ?? [])
  }

  private func lock(bundleId: String, conn: NWConnection) {
    // 支持 `lock <bundleId>[|<title>|<subtitle>|<button>]`：| 分隔自定义文案。
    let fields = bundleId.split(separator: "|", maxSplits: 3).map(String.init)
    let appId = fields[0]
    guard !appId.isEmpty else {
      reply(conn: conn, text: "ERR|missing bundle id")
      return
    }
    // 只能锁用户授权过的 app（pick 选过的）。不在名单 → 提示 AI 先 pick。
    if !Self.managedApps().contains(appId) {
      reply(
        conn: conn,
        text: "ERR|\(appId) 不在 AI 可管理名单——先让用户 screen_time_pick 添加"
      )
      return
    }
    // 解析 AI 生成的自定义屏蔽页文案（可选）。
    let title = fields.count > 1 ? fields[1] : "休息一下"
    let subtitle = fields.count > 2 ? fields[2] : "这个应用已被 Operit 锁定"
    let button = fields.count > 3 ? fields[3] : "好的"
    // 同时写入 App Group（ShieldConfiguration 扩展渲染用；FamilyControls 授权
    // 可用时系统屏蔽页也显示相同文案）。
    let defaults = UserDefaults(suiteName: appGroupID)
    defaults?.set(title, forKey: "operit.shield.title")
    defaults?.set(subtitle, forKey: "operit.shield.subtitle")
    defaults?.set(button, forKey: "operit.shield.button")
    // 主路径：写 tweak 启动拦截名单（无需 FamilyControls 授权，越狱 100% 可用）。
    var dict = (NSDictionary(contentsOfFile: Self.appLockPath) as? [String: Any]) ?? [:]
    dict[appId] = ["title": title, "subtitle": subtitle, "button": button]
    let ok = (dict as NSDictionary).write(toFile: Self.appLockPath, atomically: true)
    print("[ScreenTimeServer] lock \(appId) title=\(title) write=\(ok) total=\(dict.count)")
    reply(conn: conn, text: ok ? "OK|locked \(appId)" : "ERR|写锁名单失败 \(appId)")
  }

  private func unlock(conn: NWConnection) {
    // 清空整个锁名单（tweak 拦截解除）。
    let ok = ([:] as NSDictionary).write(toFile: Self.appLockPath, atomically: true)
    // 清除自定义屏蔽文案，回默认。
    let defaults = UserDefaults(suiteName: appGroupID)
    defaults?.removeObject(forKey: "operit.shield.title")
    defaults?.removeObject(forKey: "operit.shield.subtitle")
    defaults?.removeObject(forKey: "operit.shield.button")
    print("[ScreenTimeServer] unlock all write=\(ok)")
    reply(conn: conn, text: "OK|unlocked all")
  }

  private func status(conn: NWConnection) {
    let locked = (NSDictionary(contentsOfFile: Self.appLockPath) as? [String: Any])?.count ?? 0
    let managed = Self.managedApps().count
    reply(
      conn: conn,
      text: "OK|locked=\(locked) managed=\(managed)"
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
