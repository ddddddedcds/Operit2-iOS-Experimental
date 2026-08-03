import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  // 诊断：roothide 下 Dart 不跑且设备无系统日志。把启动检查点【追加】写入 trace.log
  // （与 OperitTrace.m 的 native tracer 同一文件），SSH 可读。/tmp 兜底保证可写。
  private func bootLog(_ msg: String) {
    let stamp = "\(Date()) [operit-boot] \(msg)\n"
    let paths = [
      "/var/mobile/trace.log",
      "/var/mobile/.operit/trace.log",
      "/var/jb/var/mobile/.operit/trace.log",
      "/tmp/trace.log"
    ]
    let data = stamp.data(using: .utf8)!
    for p in paths {
      let dir = (p as NSString).deletingLastPathComponent
      try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      if let fh = FileHandle(forWritingAtPath: p) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
      } else {
        try? stamp.write(toFile: p, atomically: true, encoding: .utf8)
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
        bootLog("AFTER_CHANNEL_REG")
      } else {
        bootLog("NO_FLUTTER_VIEWCONTROLLER")
      }
      bootLog("BEFORE_SUPER")
      ret = super.application(application, didFinishLaunchingWithOptions: launchOptions)
      bootLog("AFTER_SUPER ret=\(ret)")
    } catch {
      bootLog("BOOT_EXCEPTION \(error)")
    }
    return ret
  }

  // ---- 全套生命周期诊断 ----
  override func applicationDidBecomeActive(_ application: UIApplication) {
    bootLog("APP_BECAME_ACTIVE")
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
}
