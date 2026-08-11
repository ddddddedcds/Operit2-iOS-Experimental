//
//  OpenURLServer.swift
//  Runner
//
//  第三方 App 深链服务：AI 工具（open_url.*）→ Tools.Net.openUrl（Rust）
//        → 127.0.0.1:8894 文本协议 → 本服务 → UIApplication.open（系统级唤起）
//  协议（每连接一行）：open_url <url>
//  支持：URL scheme（weixin://）、Universal Links（https:// 官方链接自动唤起 App）、
//        tel://、mailto: 等系统链接。
//  安全：canOpenURL 先探测（Info.plist LSApplicationQueriesSchemes 白名单），
//        失败返回「未安装/不支持」，让 AI 换 https 链接或网页版兜底。
//

import Foundation
import Network
import UIKit

final class OpenURLServer: NSObject {
  static let shared = OpenURLServer()

  private var listener: NWListener?
  private let queue = DispatchQueue(label: "operit.open-url.server", qos: .userInitiated)

  func start() {
    guard listener == nil else { return }
    do {
      let l = try NWListener(using: .tcp, on: 8894)
      l.newConnectionHandler = { [weak self] conn in
        self?.handle(conn)
      }
      l.start(queue: queue)
      listener = l
    } catch {
      print("[OpenURLServer] start failed: \(error)")
    }
  }

  private func handle(_ conn: NWConnection) {
    conn.start(queue: queue)
    conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
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
    // 协议：Rust 端发 "open_url <url>" / "installed_apps"，剥掉前缀后整行就是 URL。
    if line.hasPrefix("installed_apps") {
      print("[OpenURLServer] received: installed_apps")
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.installedApps(conn: conn)
      }
      return
    }
    let url = line.hasPrefix("open_url ") ? String(line.dropFirst("open_url ".count)) : line
    print("[OpenURLServer] received: \(line) → url=\(url)")
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.open(rawURL: url, conn: conn)
    }
  }

  /// installed_apps —— 枚举已安装 app 的 bundle id + 可打开的自定义 URL scheme。
  /// 用公开 API LSApplicationWorkspace（非越狱可用）。AI 可据此判断某 scheme 是否可用。
  /// 注意：iOS 16 的 KVC key 未必全部存在（曾因 value(forKey:"schemes") 崩 app：SIGABRT，
  /// valueForUndefinedKey —— Swift do-catch 抓不住 NSException）。全部先 responds(to:) 探测
  /// 再取值；任何一步失败只降级返回 ERR，绝不崩。
  private func installedApps(conn: NWConnection) {
    var lines: [String] = []
    guard let wsCls = NSClassFromString("LSApplicationWorkspace"),
      (wsCls as AnyObject).responds(to: NSSelectorFromString("defaultWorkspace"))
    else {
      reply(conn: conn, text: "ERR|LSApplicationWorkspace unavailable")
      return
    }
    guard let workspace = (wsCls as AnyObject).perform(NSSelectorFromString("defaultWorkspace"))?
      .takeUnretainedValue() as? NSObject,
      workspace.responds(to: NSSelectorFromString("allApplications"))
    else {
      reply(conn: conn, text: "ERR|workspace unavailable")
      return
    }
    guard let apps = workspace.perform(NSSelectorFromString("allApplications"))?
      .takeUnretainedValue() as? [Any] else {
      reply(conn: conn, text: "ERR|allApplications failed")
      return
    }
    // iOS 16 上 scheme 属性的 KVC key 可能改名，逐候选探测，取第一个存在的。
    let schemeKeys = ["schemes", "URLSchemes", "urlSchemes"]
    for app in apps {
      let obj = app as AnyObject
      guard obj.responds(to: NSSelectorFromString("bundleIdentifier")),
        let bid = obj.perform(NSSelectorFromString("bundleIdentifier"))?
          .takeUnretainedValue() as? String,
        !bid.isEmpty
      else { continue }
      var schemes: [String] = []
      for key in schemeKeys where obj.responds(to: NSSelectorFromString(key)) {
        if let s = obj.perform(NSSelectorFromString(key))?.takeUnretainedValue() as? [String] {
          schemes = s
          break
        }
      }
      if schemes.isEmpty { continue } // 只列有 URL scheme 的（深链相关）
      let joined = schemes.prefix(5).joined(separator: ",")
      lines.append("\(bid) [\(joined)]")
    }
    reply(conn: conn, text: lines.isEmpty ? "OK|(none with URL schemes)" : "OK|\n" + lines.joined(separator: "\n"))
  }

  private func reply(conn: NWConnection, text: String) {
    print("[OpenURLServer] reply: \(text)")
    conn.send(
      content: Data((text + "\n").utf8),
      completion: .contentProcessed { _ in conn.cancel() }
    )
  }

  private func open(rawURL: String, conn: NWConnection) {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      reply(conn: conn, text: "ERR|missing url")
      return
    }
    // 1) 白名单 scheme / 系统链接：先 canOpenURL 探测（iOS 9+ 强制白名单）。
    // 2) https Universal Link：直接 open（系统自动唤起对应 App，未装则开网页）。
    guard let url = URL(string: trimmed) else {
      reply(conn: conn, text: "ERR|invalid url: \(trimmed)")
      return
    }
    let isHttp = url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
    if !isHttp && !UIApplication.shared.canOpenURL(url) {
      reply(
        conn: conn,
        text: "ERR|cannot open \(trimmed)：目标 App 未安装，或该 scheme 未在白名单（LSApplicationQueriesSchemes），或已失效。AI 可换 https 官方链接（Universal Link 免白名单）或网页版兜底。"
      )
      return
    }
    UIApplication.shared.open(url, options: [:]) { success in
      if success {
        self.reply(conn: conn, text: "OK|opened \(trimmed)")
      } else {
        self.reply(conn: conn, text: "ERR|open failed: \(trimmed)")
      }
    }
  }
}
