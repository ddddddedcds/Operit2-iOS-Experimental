import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  // 诊断：roothide 下 Dart 不跑且设备无系统日志。把启动检查点【追加】写入 trace.log
  // （与 OperitTrace.m 的 native tracer 同一文件），SSH 可读。/tmp 兜底保证可写。
  /// Candidates are tried in order and we STOP at the first success.
  ///
  /// Two rules, both learned the hard way on a roothide device:
  ///  * never write to every candidate — the old loop created the parent dir of
  ///    each one, which is how a bogus `/var/jb/var/mobile/.operit` tree got
  ///    created on roothide and poisoned every `/var/jb`-based detection.
  ///  * only offer a `/var/jb/...` path when this really is a rootless install
  ///    (`/var/jb/usr/lib` present), never on the strength of `/var/jb` alone.
  private func bootLog(_ msg: String) {
    let stamp = "\(Date()) [operit-boot] \(msg)\n"
    var paths = ["/var/mobile/trace.log", "/var/mobile/.operit/trace.log"]
    if FileManager.default.fileExists(atPath: "/var/jb/usr/lib") {
      paths.append("/var/jb/var/mobile/.operit/trace.log")
    }
    paths.append("/tmp/trace.log")
    let data = stamp.data(using: .utf8)!
    for p in paths {
      let dir = (p as NSString).deletingLastPathComponent
      // Only create the parent when its own parent already exists, so a failed
      // candidate never materialises a whole new tree.
      if !FileManager.default.fileExists(atPath: dir) {
        let parent = (dir as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: parent) else { continue }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
      }
      if let fh = FileHandle(forWritingAtPath: p) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
        return
      }
      if (try? stamp.write(toFile: p, atomically: true, encoding: .utf8)) != nil {
        return
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    bootLog("BOOT_START")
    var ret = false
    do {
      GeneratedPluginRegistrant.register(with: self)
      bootLog("AFTER_PLUGIN_REG")
      if let controller = window?.rootViewController as? FlutterViewController {
        AppleRuntimeChannel.register(binaryMessenger: controller.binaryMessenger)
        AppleSnapshotImportInputChannel.register(
          binaryMessenger: controller.binaryMessenger,
          presenter: controller
        )
        bootLog("AFTER_CHANNEL_REG")
        if #available(iOS 16.0, *) {
          ScreenTimeServer.shared.start()
          bootLog("AFTER_SCREEN_TIME_SERVER")
        }
        ShortcutsServer.shared.start()
        bootLog("AFTER_SHORTCUTS_SERVER")
        NotifyServer.shared.start()
        bootLog("AFTER_NOTIFY_SERVER")
      } else {
        bootLog("NO_FLUTTER_VIEWCONTROLLER")
      }
      UNUserNotificationCenter.current().delegate = self
      bootLog("BEFORE_SUPER")
      ret = super.application(application, didFinishLaunchingWithOptions: launchOptions)
      bootLog("AFTER_SUPER ret=\(ret)")
    } catch {
      bootLog("BOOT_EXCEPTION \(error)")
    }
    return ret
  }
  override func applicationDidBecomeActive(_ application: UIApplication) {
    bootLog("APP_BECAME_ACTIVE")
  }

  // ---- 外部 AI 任务入口（iOS 快捷指令 → operit://ask?text=...&x-success=...） ----
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    bootLog("OPEN_URL \(url.absoluteString)")
    guard url.scheme == "operit" else { return false }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let queryItems = components.queryItems
    else {
      return false
    }
    let text = queryItems.first { $0.name == "text" }?.value ?? ""
    let xSuccess = queryItems.first { $0.name == "x-success" }?.value
    if !text.isEmpty, let messenger = (window?.rootViewController as? FlutterViewController)?.binaryMessenger {
      let channel = FlutterMethodChannel(
        name: "operit/ai",
        binaryMessenger: messenger
      )
      channel.invokeMethod("ask", arguments: ["text": text]) { result in
        if let xSuccess, let url = URL(string: xSuccess) {
          UIApplication.shared.open(url)
        }
        self.bootLog("OPEN_URL_ASK_DONE result=\(String(describing: result))")
      }
      return true
    }
    return false
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    bootLog("APP_WILL_RESIGN_ACTIVE")
  }
  override func applicationDidEnterBackground(_ application: UIApplication) {
    bootLog("APP_DID_ENTER_BACKGROUND")
  }
  override func applicationWillEnterForeground(_ application: UIApplication) {
    bootLog("APP_WILL_ENTER_FOREGROUND")
  }
  override func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
    bootLog("APP_MEMORY_WARNING")
  }
  override func applicationWillTerminate(_ application: UIApplication) {
    bootLog("APP_WILL_TERMINATE")
  }

  /// Forwards a local-notification click to the Flutter notification activation receiver.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    guard let activation = userInfo["operitNotificationActivation"] as? [String: Any] else {
      completionHandler()
      return
    }
    AppleRuntimeChannel.receiveNotificationActivation(activation)
    completionHandler()
  }
}
