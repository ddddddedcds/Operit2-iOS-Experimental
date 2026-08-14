//
//  ShortcutsServer.swift
//  Runner
//
//  快捷指令运行服务：AI 工具 → Tools.Net.runShortcut（Rust）
//        → 127.0.0.1:8891（OperitLocalServer）文本协议 → 本服务 → shortcuts://run-shortcut（官方 URL scheme）
//  协议（每连接一行）：shortcuts run <名称>
//  效果：运行用户在「快捷指令」App 里已建好的快捷指令（非越狱/越狱均可用）。
//

import Foundation
import Network
import UIKit

final class ShortcutsServer: NSObject {
  static let shared = ShortcutsServer()

  /// 由 OperitLocalServer（单端口 8891）按首 token "shortcuts" 路由至此。
  func dispatch(_ line: String, conn: NWConnection) {
    // 协议兼容：Rust 端发 "shortcuts <cmd> [args]"，剥掉命名空间前缀。
    let stripped = line.hasPrefix("shortcuts ") ? String(line.dropFirst("shortcuts ".count)) : line
    let parts = stripped.split(separator: " ", maxSplits: 1).map(String.init)
    let cmd = parts.first ?? ""
    let arg = parts.count > 1 ? parts[1] : ""
    print("[ShortcutsServer] received: \(line) → cmd=\(cmd) arg=\(arg)")
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
    print("[ShortcutsServer] reply: \(text)")
    conn.send(
      content: Data((text + "\n").utf8),
      completion: .contentProcessed { _ in conn.cancel() }
    )
  }
}
