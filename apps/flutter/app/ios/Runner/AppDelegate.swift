import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  // 诊断：roothide 下 Dart 不跑，且设备无系统日志。把启动检查点写文件，SSH 可读。
  private func bootLog(_ msg: String) {
    let stamp = "\(Date()) [operit-boot] \(msg)\n"
    let paths = [
      "/var/mobile/.operit/boot.log",
      "/var/jb/var/mobile/.operit/boot.log",
      "/tmp/boot.log"
    ]
    for p in paths {
      let dir = (p as NSString).deletingLastPathComponent
      try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try? stamp.write(toFile: p, atomically: true, encoding: .utf8)
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
}
