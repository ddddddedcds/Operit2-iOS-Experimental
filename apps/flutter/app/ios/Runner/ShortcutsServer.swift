//
//  ShortcutsServer.swift
//  Runner
//
//  快捷指令运行服务：AI 工具 → Tools.Net.runShortcut（Rust）
//        → 127.0.0.1:8892 文本协议 → 本服务 → shortcuts://run-shortcut（官方 URL scheme）
//  协议（每连接一行）：shortcuts run <名称>
//  效果：运行用户在「快捷指令」App 里已建好的快捷指令（非越狱/越狱均可用）。
//

import Foundation
import Network
import UIKit

final class ShortcutsServer: NSObject {
  static let shared = ShortcutsServer()

  private var listener: NWListener?
  private let queue = DispatchQueue(label: "operit.shortcuts.server", qos: .userInitiated)

  func start() {
    guard listener == nil else { return }
    do {
      let l = try NWListener(using: .tcp, on: 8892)
      l.newConnectionHandler = { [weak self] conn in
        self?.handle(conn)
      }
      l.start(queue: queue)
      listener = l
    } catch {
      print("[ShortcutsServer] start failed: \(error)")
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
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    let cmd = parts.first ?? ""
    let arg = parts.count > 1 ? parts[1] : ""
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      switch cmd {
      case "run":
        self.run(name: arg, conn: conn)
      default:
        self.reply(conn: conn, text: "ERR|unknown command: \(cmd)")
      }
    }
  }

  private func run(name: String, conn: NWConnection) {
    guard !name.isEmpty,
      let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
      let url = URL(string: "shortcuts://run-shortcut?name=\(escaped)")
    else {
      reply(conn: conn, text: "ERR|invalid shortcut name")
      return
    }
    UIApplication.shared.open(url) { ok in
      self.reply(
        conn: conn,
        text: ok
          ? "OK|running shortcut \(name)"
          : "ERR|failed to open shortcuts (shortcut may not exist)"
      )
    }
  }

  private func reply(conn: NWConnection, text: String) {
    conn.send(
      content: Data((text + "\n").utf8),
      completion: .contentProcessed { _ in conn.cancel() }
    )
  }
}
