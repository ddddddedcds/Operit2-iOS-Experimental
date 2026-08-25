import AVFoundation
import CoreLocation
import CoreBluetooth
import CoreMedia
import Darwin
import Flutter
import Foundation
import Network
import PhotosUI
import UserNotifications
import Vision
import UIKit
import UniformTypeIdentifiers
import Vision

final class AppleRuntimeChannel: NSObject {
  private static var shared: AppleRuntimeChannel?
  private static var pendingNotificationActivations: [[String: Any]] = []
  private static var notificationActivationReceiverReady = false
  private var channel: FlutterMethodChannel
  private let workQueue = DispatchQueue(label: "operit.runtime.apple", qos: .userInitiated)
  private var ttsSynthesisActive: [String: (AVSpeechSynthesizer, TtsSynthesisDelegate)] = [:]
  private var activePickers: [Any] = []
  private let fileInteractionDelegate = FileInteractionDelegate()
  private let watchQueue = DispatchQueue(label: "operit.runtime.apple.watch", qos: .utility)
  private let watchLock = NSLock()
  private var watchPumpRunning = false
  private var handle: UnsafeMutableRawPointer?
  private var audioPlayers: [String: AVAudioPlayer] = [:]
  private var musicPlayer: AVPlayer?
  private var musicSource: String?
  private var musicSourceType: String?
  private var musicTitle: String?
  private var musicArtist: String?
  private var musicVolume: Double = 1.0
  private var musicLoopPlayback = false
  private var musicState = "idle"
  private var musicMessage = "apple music player idle"
  private let speechSynthesizer = AVSpeechSynthesizer()
  private var ttsAudioPlayer: AVAudioPlayer?
  private var ttsAudioPaused = false
  private var ttsPath = ""
  private var configuredRuntimeRoot: URL?
  private var configuredWorkspaceRoot: URL?
  private lazy var bluetooth = AppleBluetoothController { [weak self] topic, data in
    self?.emitHostEvent(topic: topic, data: data)
  }
  private let hostEventQueue = DispatchQueue(label: "operit.runtime.apple.host-events", qos: .utility)
  private let networkMonitor = NWPathMonitor()
  private var hostEventObservers: [NSObjectProtocol] = []
  private var hostEventMonitoringInstalled = false
  private var lastBatteryLow: Bool?
  private var lastCalendarDay = Calendar.current.startOfDay(for: Date())
  private var lastTimeZoneIdentifier = TimeZone.current.identifier

  /// Attaches the process-level Runtime channel to the current Flutter engine.
  static func register(binaryMessenger: FlutterBinaryMessenger) {
    AppleCrashChannel.register(binaryMessenger: binaryMessenger)
    if let shared {
      shared.attach(binaryMessenger: binaryMessenger)
      return
    }
    shared = AppleRuntimeChannel(binaryMessenger: binaryMessenger)
  }

  /// Records one local-notification activation received by the application delegate.
  static func receiveNotificationActivation(_ activation: [String: Any]) {
    DispatchQueue.main.async {
      pendingNotificationActivations.append(activation)
      shared?.dispatchPendingNotificationActivations()
    }
  }

  /// Creates the process-level Runtime channel.
  private init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "operit/runtime", binaryMessenger: binaryMessenger)
    super.init()
    installMethodHandler()
  }

  /// Rebinds the existing Runtime to a replacement Flutter engine.
  private func attach(binaryMessenger: FlutterBinaryMessenger) {
    channel.setMethodCallHandler(nil)
    channel = FlutterMethodChannel(name: "operit/runtime", binaryMessenger: binaryMessenger)
    installMethodHandler()
  }

  /// Installs method dispatch on the currently attached Flutter channel.
  private func installMethodHandler() {
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  deinit {
    networkMonitor.cancel()
    for observer in hostEventObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    if let handle = handle {
      operit_flutter_bridge_destroy(handle)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    OperitTraceAppend("CHANNEL_CALL method=\(call.method)")
    switch call.method {
    case "call":
      callRuntime(call: call, result: result, nativeCall: operit_flutter_bridge_native_call)
    case "pushOpen":
      callRuntime(call: call, result: result, nativeCall: operit_flutter_bridge_push_open)
    case "pushItem":
      callRuntime(call: call, result: result, nativeCall: operit_flutter_bridge_push_item)
    case "pushClose":
      pushClose(call: call, result: result)
    case "watchSnapshot":
      callRuntime(call: call, result: result, nativeCall: operit_flutter_bridge_watch_snapshot)
    case "watchStream":
      watchStream(call: call, result: result)
    case "closeWatchStream":
      closeWatchStream(call: call, result: result)
    case "startWebAccessServer":
      startWebAccessServer(call: call, result: result)
    case "localRuntimeStorageDefaults":
      localRuntimeStorageDefaults(result: result)
    case "localRuntimeStoragePaths":
      localRuntimeStoragePaths(call: call, result: result)
    case "setLocalRuntimeStorage":
      setLocalRuntimeStorage(call: call, result: result)
    case "notificationActivationInitial":
      result(Self.takePendingNotificationActivation())
    case "notificationActivationReady":
      Self.notificationActivationReceiverReady = true
      dispatchPendingNotificationActivations()
      result(nil)
    case "hostOnboardingPermissionSnapshot":
      hostOnboardingPermissionSnapshot(call: call, result: result)
    case "hostOnboardingRequestPermission":
      hostOnboardingRequestPermission(call: call, result: result)
    case "stopWebAccessServer":
      runRuntime(result: result) { handle in
        self.takeString(operit_flutter_bridge_stop_web_access_server(handle))
      }
    case "ownerSystemCaptureScreenshot":
      ownerSystemCaptureScreenshot(result: result)
    case "captureScreenDirect":
      captureScreenDirect(result: result)
    case "getCurrentLocation":
      getCurrentLocation(result: result)
    case "ownerSystemDeviceAgentPing":
      ownerSystemDeviceAgentPing(result: result)
    case "ownerSystemDeviceAgentStatus":
      ownerSystemDeviceAgentStatus(result: result)
    case "ownerSystemDeviceAgentStart":
      ownerSystemDeviceAgentStart(result: result)
    case "ownerSystemDeviceAgentStop":
      ownerSystemDeviceAgentStop(result: result)
    case "ownerSystemDeviceAgentGoal":
      ownerSystemDeviceAgentGoal(call: call, result: result)
    case "ownerSystemRecognizeText":
      ownerSystemRecognizeText(call: call, result: result)
    case "ownerSystemOperation":
      ownerSystemOperation(call: call, result: result)
    case "ownerAudioPlay":
      ownerAudioPlay(call: call, result: result)
    case "ownerMusicPlayback":
      ownerMusicPlayback(call: call, result: result)
    case "ownerBluetooth":
      ownerBluetooth(call: call, result: result)
    case "ownerTtsSynthesize":
      ownerTtsSynthesize(call: call, result: result)
    case "ownerTtsPlayback":
      ownerTtsPlayback(call: call, result: result)
    case "ownerLocalInference":
      ownerLocalInference(call: call, result: result)
    case "syncDaemonConfig":
      syncDaemonConfig(call: call, result: result)
    case "hostOnboardingPermissionSnapshot":
      hostOnboardingPermissionSnapshot(result: result)
    case "hostOnboardingRequestPermission":
      hostOnboardingRequestPermission(result: result)
    case "pickImage":
      pickMedia(isVideo: false, result: result)
    case "pickVideo":
      pickMedia(isVideo: true, result: result)
    case "ownerFileOpen":
      ownerFileOpen(call: call, result: result)
    case "ownerFileShare":
      ownerFileShare(call: call, result: result)
    case "ownerSystemLanguageCode":
      ownerSystemLanguageCode(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func ensureRuntimeHandle() throws -> UnsafeMutableRawPointer {
    if let handle = handle {
      return handle
    }
    // Fall back to the platform default storage roots when the Flutter side has
    // not configured them yet. Without this, any runtime call issued before the
    // onboarding storage step (for example fetching the provider catalog) throws
    // "Runtime and workspace roots are not configured" and hard-crashes onboarding.
    var runtimeRoot = configuredRuntimeRoot
    var workspaceRoot = configuredWorkspaceRoot
    if runtimeRoot == nil || workspaceRoot == nil {
      let defaults = defaultStorageRoots()
      if runtimeRoot == nil { runtimeRoot = defaults.runtime }
      if workspaceRoot == nil { workspaceRoot = defaults.workspace }
    }
    guard let runtimeRoot, let workspaceRoot else {
      throw RuntimeChannelError.createFailed("Runtime and workspace roots are not configured")
    }
    guard let created = operit_flutter_bridge_create_with_storage_roots(
      runtimeRoot.path,
      workspaceRoot.path
    ) else {
      let error = takeString(operit_flutter_bridge_create_error())
      throw RuntimeChannelError.createFailed(error)
    }
    handle = created
    configuredRuntimeRoot = runtimeRoot
    configuredWorkspaceRoot = workspaceRoot
    installHostEventMonitoring()
    return created
  }

  /// Installs iOS network, battery, session, and Bluetooth event producers once.
  private func installHostEventMonitoring() {
    guard !hostEventMonitoringInstalled else { return }
    hostEventMonitoringInstalled = true
    networkMonitor.pathUpdateHandler = { [weak self] path in
      self?.emitNetworkPath(path)
    }
    networkMonitor.start(queue: hostEventQueue)
    UIDevice.current.isBatteryMonitoringEnabled = true
    hostEventObservers.append(
      NotificationCenter.default.addObserver(
        forName: UIDevice.batteryLevelDidChangeNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in self?.emitIosBatteryState() }
    )
    hostEventObservers.append(
      NotificationCenter.default.addObserver(
        forName: UIDevice.batteryStateDidChangeNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in self?.emitIosBatteryState() }
    )
    hostEventObservers.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        self?.emitHostEvent(topic: "system.session.lock", data: ["locked": true])
      }
    )
    hostEventObservers.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.protectedDataDidBecomeAvailableNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        self?.emitHostEvent(topic: "system.session.unlock", data: ["locked": false])
        self?.emitHostEvent(topic: "system.user.present", data: ["present": true])
      }
    )
    hostEventObservers.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.significantTimeChangeNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in self?.emitIosClockChanges() }
    )
    hostEventObservers.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: AVAudioSession.sharedInstance(),
        queue: nil
      ) { [weak self] _ in self?.emitIosHeadsetState() }
    )
    _ = bluetooth
    emitIosBatteryState()
    emitIosHeadsetState()
  }

  /// Emits the canonical iOS battery and external-power topic data.
  private func emitIosBatteryState() {
    let device = UIDevice.current
    let level = device.batteryLevel >= 0 ? Double(device.batteryLevel * 100) : nil
    let charging: Bool?
    switch device.batteryState {
    case .charging, .full:
      charging = true
    case .unplugged:
      charging = false
    case .unknown:
      charging = nil
    @unknown default:
      charging = nil
    }
    if let level {
      let low = level <= 20
      if lastBatteryLow != low {
        lastBatteryLow = low
        emitHostEvent(
          topic: low ? "system.battery.low" : "system.battery.okay",
          data: ["low": low, "level": level, "charging": charging ?? NSNull()]
        )
      }
    }
    if let charging {
      emitHostEvent(
        topic: charging ? "system.power.connected" : "system.power.disconnected",
        data: [
          "connected": charging,
          "source": charging ? "unknown" : "battery",
          "batteryLevel": level ?? NSNull(),
        ]
      )
    }
  }

  /// Emits canonical clock, date, and timezone changes reported by iOS.
  private func emitIosClockChanges() {
    let now = Date()
    let day = Calendar.current.startOfDay(for: now)
    let timeZoneIdentifier = TimeZone.current.identifier
    let data: [String: Any] = [
      "timestampMillis": now.timeIntervalSince1970 * 1000,
      "timezone": timeZoneIdentifier,
    ]
    emitHostEvent(topic: "system.time.tick", data: data)
    if day != lastCalendarDay {
      lastCalendarDay = day
      emitHostEvent(topic: "system.date.changed", data: data)
    }
    if timeZoneIdentifier != lastTimeZoneIdentifier {
      lastTimeZoneIdentifier = timeZoneIdentifier
      emitHostEvent(topic: "system.timezone.changed", data: data)
    }
  }

  /// Emits the canonical headset state derived from the active iOS audio route.
  private func emitIosHeadsetState() {
    let route = AVAudioSession.sharedInstance().currentRoute
    let headsetOutput = route.outputs.first { output in
      switch output.portType {
      case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
        return true
      default:
        return false
      }
    }
    let hasMicrophone = route.inputs.contains { input in
      switch input.portType {
      case .headsetMic, .bluetoothHFP, .bluetoothLE:
        return true
      default:
        return false
      }
    }
    emitHostEvent(
      topic: "system.headset.plug",
      data: [
        "connected": headsetOutput != nil,
        "deviceName": headsetOutput?.portName ?? NSNull(),
        "hasMicrophone": headsetOutput == nil ? NSNull() : hasMicrophone,
      ]
    )
  }

  /// Converts one Apple Network path into the shared network-change structure.
  private func emitNetworkPath(_ path: NWPath) {
    let networkType: String
    if path.status != .satisfied {
      networkType = "none"
    } else if path.usesInterfaceType(.wifi) {
      networkType = "wifi"
    } else if path.usesInterfaceType(.cellular) {
      networkType = "cellular"
    } else if path.usesInterfaceType(.wiredEthernet) {
      networkType = "ethernet"
    } else if path.usesInterfaceType(.other) {
      networkType = "other"
    } else {
      networkType = "other"
    }
    let interfaceName = path.availableInterfaces.first(where: { path.usesInterfaceType($0.type) })?.name
    emitHostEvent(
      topic: "system.network.changed",
      data: [
        "connected": path.status == .satisfied,
        "networkType": networkType,
        "metered": path.isExpensive,
        "interfaceName": interfaceName ?? NSNull(),
      ]
    )
  }

  /// Serializes and forwards one canonical iOS event through the existing native bridge.
  private func emitHostEvent(topic: String, data: [String: Any]) {
    workQueue.async { [weak self] in
      guard let self, let handle = self.handle else { return }
      let event: [String: Any] = [
        "domain": "host",
        "source": "ios.system",
        "topic": topic,
        "platform": "ios",
        "payload": data,
        "occurredAtMillis": Int64(Date().timeIntervalSince1970 * 1000),
      ]
      do {
        let encoded = try JSONSerialization.data(withJSONObject: event)
        guard let json = String(data: encoded, encoding: .utf8) else {
          throw RuntimeChannelError.invalidState("iOS host event JSON is not UTF-8")
        }
        let response = json.withCString { pointer in
          self.takeString(operit_flutter_bridge_emit_runtime_event(handle, pointer))
        }
        guard let value = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
              value["ok"] as? Bool == true else {
          throw RuntimeChannelError.invalidState("iOS host event delivery failed: \(response)")
        }
      } catch {
        NSLog("Operit iOS host event failed: %@", error.localizedDescription)
      }
    }
  }

  /// Resolves the operit data root at runtime, mirroring Rust's
  /// `operit_ios_env::data_root()` (core/crates/operit-ios-env/src/lib.rs).
  /// This is the SINGLE source of truth for where logs / sockets / config live.
  /// Keep it in sync with that Rust logic; do NOT hardcode `/var/jb` or
  /// `/var/mobile` anywhere else in this file.
  ///
  /// Rootless-only detection (must match Rust `detect_jailbreak`):
  /// 1. `/var/jb/usr/lib` exists ⇒ rootless (Dopamine/ElleKit).
  /// 2. writable `/var/mobile/.operit` ⇒ jailbroken, unknown flavour.
  /// 3. non-jailbreak — app sandbox `Documents/.operit`.
  ///
  /// The canonical data root is the REAL `/var/mobile/.operit` (matches Rust
  /// `operit_ios_env::data_root()`). The procursus-mirrored
  /// `/var/jb/var/mobile/.operit` is a different physical directory the app
  /// cannot write into (EACCES), so it is never used.
  ///
  /// The agent control channel + config travel over loopback TCP
  /// (127.0.0.1:8890).
  private static let resolvedDataRoot: String = computeIosDataRoot()

  private static func iosDataRoot() -> String { resolvedDataRoot }

  private static func computeIosDataRoot() -> String {
    // Rootless-only: the canonical data root is the REAL /var/mobile/.operit.
    // The procursus-mirrored /var/jb/var/mobile/.operit is a different physical
    // directory the app cannot write into (EACCES), so it is never used.
    let unsandboxedPath = "/var/mobile/.operit"
    let probe = (unsandboxedPath as NSString).appendingPathComponent(".writetest")
    if !FileManager.default.fileExists(atPath: unsandboxedPath) {
      try? FileManager.default.createDirectory(
        atPath: unsandboxedPath, withIntermediateDirectories: true)
    }
    if FileManager.default.createFile(atPath: probe, contents: nil) {
      try? FileManager.default.removeItem(atPath: probe)
      return unsandboxedPath
    }
    if let home = ProcessInfo.processInfo.environment["HOME"] {
      return (home as NSString).appendingPathComponent("Documents/.operit")
    }
    return unsandboxedPath
  }

  /// Returns the default Apple runtime and workspace roots.
  /// This app is installed no-sandbox (container-required=false), so the system
  /// never creates a per-app container UUID directory. The original
  /// applicationSupportDirectory path therefore does not exist and the Rust core
  /// panics on create_dir_all().unwrap(). Pre-create the (environment-resolved)
  /// data root before handing it to the runtime.
  private func defaultStorageRoots() -> (runtime: URL, workspace: URL) {
    let basePath = (Self.iosDataRoot() as NSString).appendingPathComponent("operit2")
    let base = URL(fileURLWithPath: basePath, isDirectory: true)
    let runtime = base.appendingPathComponent("runtime", isDirectory: true)
    let workspace = base.appendingPathComponent("workspaces", isDirectory: true)
    for url in [base, runtime, workspace] {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    return (runtime, workspace)
  }

  /// Returns whether two storage root URLs denote the same filesystem location.
  /// Resolves symlinks so `/var/mobile/...` and `/private/var/mobile/...` are
  /// treated as identical, preventing `RUNTIME_ALREADY_CREATED` false positives
  /// when Dart passes a symlink-resolved path while the configured root is not.
  private func areStorageRootsEqual(_ lhs: URL, _ rhs: URL) -> Bool {
    let resolvedLhs = lhs.resolvingSymlinksInPath().standardizedFileURL
    let resolvedRhs = rhs.resolvingSymlinksInPath().standardizedFileURL
    return resolvedLhs == resolvedRhs
  }

  /// Resolves one required Flutter-provided storage root.
  private func absoluteDirectory(from value: Any?, label: String) throws -> URL {
    guard let value = value as? String else {
      throw RuntimeChannelError.createFailed("\(label) must be a string")
    }
    let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
      throw RuntimeChannelError.createFailed("\(label) is required")
    }
    guard NSString(string: path).isAbsolutePath else {
      throw RuntimeChannelError.createFailed("\(label) must be an absolute path")
    }
    return URL(fileURLWithPath: path).standardizedFileURL
  }

  /// Returns the platform default runtime and workspace roots.
  private func localRuntimeStorageDefaults(result: @escaping FlutterResult) {
    let roots = defaultStorageRoots()
    result([
      "runtimeRoot": roots.runtime.path,
      "workspaceRoot": roots.workspace.path,
    ])
  }

  /// Returns normalized local runtime storage paths for requested roots.
  private func localRuntimeStoragePaths(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any?] else {
      result(FlutterError(code: "INVALID_ARGS", message: "localRuntimeStoragePaths expects arguments", details: nil))
      return
    }
    do {
      let runtimeRoot = try absoluteDirectory(from: arguments["runtimeRoot"] ?? nil, label: "runtimeRoot")
      let workspaceRoot = try absoluteDirectory(from: arguments["workspaceRoot"] ?? nil, label: "workspaceRoot")
      result([
        "runtimeRoot": runtimeRoot.path,
        "workspaceRoot": workspaceRoot.path,
      ])
    } catch {
      result(FlutterError(code: "INVALID_ARGS", message: error.localizedDescription, details: nil))
    }
  }

  /// Installs storage roots and accepts repeated identical configuration.
  private func setLocalRuntimeStorage(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any?] else {
      result(FlutterError(code: "INVALID_ARGS", message: "setLocalRuntimeStorage expects arguments", details: nil))
      return
    }
    do {
      let runtimeRoot = try absoluteDirectory(from: arguments["runtimeRoot"] ?? nil, label: "runtimeRoot")
      let workspaceRoot = try absoluteDirectory(from: arguments["workspaceRoot"] ?? nil, label: "workspaceRoot")
      if handle != nil {
        if let configuredRuntimeRoot,
           let configuredWorkspaceRoot,
           areStorageRootsEqual(configuredRuntimeRoot, runtimeRoot),
           areStorageRootsEqual(configuredWorkspaceRoot, workspaceRoot) {
          result(nil)
          return
        }
        result(FlutterError(code: "RUNTIME_ALREADY_CREATED", message: "Runtime and workspace roots cannot change after runtime creation", details: nil))
        return
      }
      configuredRuntimeRoot = runtimeRoot
      configuredWorkspaceRoot = workspaceRoot
      result(nil)
    } catch {
      result(FlutterError(code: "INVALID_ARGS", message: error.localizedDescription, details: nil))
    }
  }

  private func runRuntime(result: @escaping FlutterResult, _ body: @escaping (UnsafeMutableRawPointer) throws -> String) {
    workQueue.async {
      do {
        let handle = try self.ensureRuntimeHandle()
        let response = try body(handle)
        DispatchQueue.main.async { result(response) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "OPERIT_RUNTIME_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  /// Runs one binary Link operation and returns Flutter typed data.
  private func runRuntimeBytes(result: @escaping FlutterResult, _ body: @escaping (UnsafeMutableRawPointer) throws -> Data) {
    workQueue.async {
      do {
        let handle = try self.ensureRuntimeHandle()
        let response = try body(handle)
        DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: response)) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "OPERIT_RUNTIME_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func callRuntime(
    call: FlutterMethodCall,
    result: @escaping FlutterResult,
    nativeCall: @escaping (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt) -> OperitByteBuffer
  ) {
    guard let request = (call.arguments as? FlutterStandardTypedData)?.data else {
      result(FlutterError(code: "INVALID_ARGS", message: "\(call.method) expects MessagePack bytes", details: nil))
      return
    }
    runRuntimeBytes(result: result) { handle in
      request.withUnsafeBytes { bytes in
        self.takeBytes(nativeCall(handle, bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count)))
      }
    }
  }

  private func watchStream(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let request = (call.arguments as? FlutterStandardTypedData)?.data else {
      result(FlutterError(code: "INVALID_ARGS", message: "watchStream expects MessagePack bytes", details: nil))
      return
    }
    runRuntimeBytes(result: result) { handle in
      let response = request.withUnsafeBytes { bytes in
        self.takeBytes(operit_flutter_bridge_watch_stream(handle, bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count)))
      }
      self.ensureWatchPump()
      return response
    }
  }

  private func closeWatchStream(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let subscriptionId = call.arguments as? String else {
      result(FlutterError(code: "INVALID_ARGS", message: "closeWatchStream expects a subscription id", details: nil))
      return
    }
    runRuntimeBytes(result: result) { handle in
      self.takeBytes(operit_flutter_bridge_close_watch_stream(handle, subscriptionId))
    }
  }

  /// Closes one local Link push stream.
  private func pushClose(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let pushId = call.arguments as? String else {
      result(FlutterError(code: "INVALID_ARGS", message: "pushClose expects a push id", details: nil))
      return
    }
    runRuntimeBytes(result: result) { handle in
      self.takeBytes(operit_flutter_bridge_push_close(handle, pushId))
    }
  }

  private func ensureWatchPump() {
    watchLock.lock()
    if watchPumpRunning {
      watchLock.unlock()
      return
    }
    watchPumpRunning = true
    watchLock.unlock()
    watchQueue.async {
      while true {
        self.watchLock.lock()
        let running = self.watchPumpRunning
        self.watchLock.unlock()
        if !running {
          return
        }
        do {
          let handle = try self.ensureRuntimeHandle()
          let frameBuffer = operit_flutter_bridge_next_watch_channel_event(handle)
          guard frameBuffer.ptr != nil else {
            self.stopWatchPump()
            return
          }
          let frame = self.takeBytes(frameBuffer)
          DispatchQueue.main.async {
            self.channel.invokeMethod("watchChannelEvent", arguments: FlutterStandardTypedData(bytes: frame))
          }
        } catch {
          self.stopWatchPump()
          return
        }
      }
    }
  }

  private func stopWatchPump() {
    watchLock.lock()
    watchPumpRunning = false
    watchLock.unlock()
  }

  private func startWebAccessServer(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let bindAddress = args["bindAddress"] as? String,
      let token = args["token"] as? String,
      let shutdownToken = args["shutdownToken"] as? String,
      let webRoot = args["webRoot"] as? String,
      let deviceInfo = args["deviceInfo"] as? String,
      let enableWebAccess = args["enableWebAccess"] as? String,
      let enableDiscovery = args["enableDiscovery"] as? String
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "startWebAccessServer arguments are incomplete", details: nil))
      return
    }
    runRuntime(result: result) { handle in
      self.takeString(operit_flutter_bridge_start_web_access_server(
        handle,
        bindAddress,
        token,
        shutdownToken,
        webRoot,
        deviceInfo,
        enableWebAccess,
        enableDiscovery
      ))
    }
  }

  /// Returns and consumes the oldest notification activation received before Dart startup.
  private static func takePendingNotificationActivation() -> [String: Any]? {
    guard !pendingNotificationActivations.isEmpty else {
      return nil
    }
    return pendingNotificationActivations.removeFirst()
  }

  /// Emits every activation held until the Dart Runtime-channel receiver is ready.
  private func dispatchPendingNotificationActivations() {
    guard Self.notificationActivationReceiverReady else {
      return
    }
    while let activation = Self.takePendingNotificationActivation() {
      channel.invokeMethod("notificationActivation", arguments: activation)
    }
  }

  /// Returns the current iOS notification permission status for onboarding.
  private func hostOnboardingPermissionSnapshot(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let hostId = arguments["hostId"] as? String,
          hostId == "ios" else {
      result(FlutterError(code: "INVALID_HOST", message: "Invalid onboarding host", details: nil))
      return
    }
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let authorized =
        settings.authorizationStatus == .authorized ||
        settings.authorizationStatus == .provisional
      DispatchQueue.main.async {
        result([
          "ios.notifications": [
            "id": "ios.notifications",
            "status": authorized ? "Satisfied" : "Missing",
          ],
        ])
      }
    }
  }

  /// Requests the iOS notification permission selected from onboarding.
  private func hostOnboardingRequestPermission(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let hostId = arguments["hostId"] as? String,
          hostId == "ios",
          let requirementId = arguments["requirementId"] as? String,
          requirementId == "ios.notifications" else {
      result(FlutterError(code: "INVALID_ONBOARDING_REQUIREMENT", message: "Invalid onboarding notification requirement", details: nil))
      return
    }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, error in
      DispatchQueue.main.async {
        if let error {
          result(FlutterError(code: "IOS_NOTIFICATION_PERMISSION_ERROR", message: error.localizedDescription, details: nil))
          return
        }
        result(nil)
      }
    }
  }

  private func ownerSystemCaptureScreenshot(result: @escaping FlutterResult) {
    #if os(iOS)
    // On iOS the screenshot is produced by the Operit jailbreak SpringBoard tweak
    // (operit-sb) over its Unix socket; the sandboxed app cannot capture the screen
    // directly. The Rust host at hosts/ios/src/device_automation.rs drives the same
    // socket. See deb/DEBIAN/postinst for how the tweak is loaded on a rootless jailbreak.
    workQueue.async {
      do {
        // Route screenshot through the ios-mcp jailbreak tweak instead of the
        // operit-sb Unix socket. ios-mcp returns a base64 JPEG; re-encode to PNG
        // to keep the existing Dart contract (imagePng base64 + width/height).
        let reply = try Self.iosMcpCall(tool: "screenshot", arguments: [:])
        guard let content = reply["content"] as? [[String: Any]],
              let image = content.first(where: { ($0["type"] as? String) == "image" }),
              let dataB64 = image["data"] as? String,
              let jpegData = Data(base64Encoded: dataB64),
              let uiImage = UIImage(data: jpegData),
              let pngData = uiImage.pngData() else {
          throw NSError(domain: "operit", code: 1, userInfo: [NSLocalizedDescriptionKey: "ios-mcp screenshot: invalid image payload"])
        }
        let width = Int(uiImage.size.width * uiImage.scale)
        let height = Int(uiImage.size.height * uiImage.scale)
        DispatchQueue.main.async {
          // Field names/types MUST match the generated Dart model
          // RuntimeHostInteractionSystemCaptureScreenshotResponse (CoreProxyModels.g.dart).
          result([
            "imagePng": pngData.base64EncodedString(),
            "width": width,
            "height": height,
          ])
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "OWNER_SYSTEM_CAPTURE_SCREENSHOT_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    }
    #else
    result(FlutterError(code: "OWNER_SYSTEM_CAPTURE_SCREENSHOT_ERROR", message: "macOS screenshot capture is handled by the Rust system host", details: nil))
    #endif
  }

  /// Captures the full device screen using the private UIImage
  /// `_UICreateScreenUIImage()` API, entirely in-process — no jailbreak
  /// tweak socket (operit.sock) and no device-automation daemon. This is the
  /// user-facing "screen content" attachment on iOS after we dropped the
  /// host-interaction screenshot path ("our automation").
  private func captureScreenDirect(result: @escaping FlutterResult) {
    #if os(iOS)
    workQueue.async {
      let image: UIImage? = {
        let selector = NSSelectorFromString("_UICreateScreenUIImage")
        guard UIImage.responds(to: selector) else { return nil }
        return UIImage.perform(selector).takeRetainedValue() as? UIImage
      }()
      guard let image else {
        DispatchQueue.main.async {
          result(FlutterError(code: "SCREEN_CAPTURE_ERROR", message: "private screenshot API unavailable on this device", details: nil))
        }
        return
      }
      guard let pngData = image.pngData() else {
        DispatchQueue.main.async {
          result(FlutterError(code: "SCREEN_CAPTURE_ERROR", message: "failed to encode screenshot to PNG", details: nil))
        }
        return
      }
      let fileName = "operit_screen_\(Int64(Date().timeIntervalSince1970 * 1000)).png"
      let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
      do {
        try pngData.write(to: fileURL)
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        DispatchQueue.main.async {
          result(["path": fileURL.path, "width": width, "height": height])
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "SCREEN_CAPTURE_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    }
    #else
    result(FlutterError(code: "SCREEN_CAPTURE_ERROR", message: "screen capture is only available on iOS", details: nil))
    #endif
  }

  private func getCurrentLocation(result: @escaping FlutterResult) {
    #if os(iOS)
    DispatchQueue.main.async {
      _ = OneShotLocationFetcher(result: result)
    }
    #else
    result(FlutterError(code: "LOCATION_ERROR", message: "location is only available on iOS", details: nil))
    #endif
  }

  /// One-shot CoreLocation fetcher retained until first fix or timeout.
  private class OneShotLocationFetcher: NSObject, CLLocationManagerDelegate {
    let manager: CLLocationManager
    let result: FlutterResult
    var finished = false
    static var active: [OneShotLocationFetcher] = []

    init(result: @escaping FlutterResult) {
      self.result = result
      self.manager = CLLocationManager()
      super.init()
      manager.delegate = self
      manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
      manager.requestWhenInUseAuthorization()
      OneShotLocationFetcher.active.append(self)
      // If permission was already decided in a previous run, the request above
      // does NOT re-fire locationManagerDidChangeAuthorization. Act on the
      // current status immediately; only .notDetermined waits for the callback.
      let status: CLAuthorizationStatus
      if #available(iOS 14.0, *) {
        status = manager.authorizationStatus
      } else {
        status = CLLocationManager.authorizationStatus()
      }
      switch status {
      case .authorizedWhenInUse, .authorizedAlways:
        manager.requestLocation()
      case .denied, .restricted:
        complete(error: "location permission denied")
      default:
        break
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
        self?.complete(error: "location request timed out")
      }
    }

    @available(iOS 14.0, *)
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
      let status = manager.authorizationStatus
      switch status {
      case .authorizedWhenInUse, .authorizedAlways:
        manager.requestLocation()
      case .denied, .restricted:
        complete(error: "location permission denied")
      default:
        break
      }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
      guard let loc = locations.first, !finished else { return }
      let lat = loc.coordinate.latitude
      let lon = loc.coordinate.longitude
      let acc = loc.horizontalAccuracy
      let content = "当前位置\n纬度: \(String(format: "%.6f", lat))\n经度: \(String(format: "%.6f", lon))\n精度: \(String(format: "%.0f", acc)) 米\n时间: \(loc.timestamp)\n"
      let fileName = "operit_location_\(Int64(Date().timeIntervalSince1970 * 1000)).txt"
      let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
      do {
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        complete(path: fileURL.path, latitude: lat, longitude: lon)
      } catch {
        complete(error: error.localizedDescription)
      }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
      complete(error: error.localizedDescription)
    }

    private func complete(path: String? = nil, latitude: Double = 0, longitude: Double = 0, error: String? = nil) {
      guard !finished else { return }
      finished = true
      manager.stopUpdatingLocation()
      manager.delegate = nil
      OneShotLocationFetcher.active.removeAll { $0 === self }
      DispatchQueue.main.async {
        if let path = path {
          self.result(["path": path, "latitude": latitude, "longitude": longitude])
        } else {
          self.result(FlutterError(code: "LOCATION_ERROR", message: error ?? "unknown location error", details: nil))
        }
      }
    }
  }

  // MARK: - Host onboarding permissions (iOS)
  // On jailbroken iOS, capabilities are pre-granted by the app's entitlements at
  // install time; there are no runtime TCC prompts to satisfy. These handlers
  // exist so the "系统授权" panel never hits FlutterMethodNotImplemented (which
  // would crash the panel if onboardingRequirements is ever populated for iOS).
  private func hostOnboardingPermissionSnapshot(result: @escaping FlutterResult) {
    // Empty snapshot: no per-requirement runtime status to report.
    result([String: [String: String]]())
  }

  private func hostOnboardingRequestPermission(result: @escaping FlutterResult) {
    // Nothing to request on iOS; entitlements already grant everything.
    result(nil)
  }

  // MARK: - Operit jailbreak device daemon bridge (iOS)

  // MARK: ios-mcp jailbreak tweak bridge (iOS)
  // Routes screenshot / OCR through the `ios-mcp` tweak (HTTP MCP at 127.0.0.1:8090)
  // instead of the operit-sb Unix socket / in-process Vision. Protocol facts verified
  // against witchan/ios-mcp MCPServer.m (see hosts/ios/src/ios_mcp.rs on the Rust side).
  private static let iosMcpBaseURL = "http://127.0.0.1:8090/mcp"

  private static func iosMcpPost(url: URL, body: [String: Any]) throws -> [String: Any] {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    let sem = DispatchSemaphore(value: 0)
    var out: [String: Any]?
    var outErr: Error?
    let task = URLSession.shared.dataTask(with: req) { data, _, error in
      if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        out = obj
      } else {
        outErr = error
      }
      sem.signal()
    }
    task.resume()
    sem.wait()
    if let outErr { throw outErr }
    guard let out else {
      throw NSError(domain: "operit", code: 1, userInfo: [NSLocalizedDescriptionKey: "ios-mcp: empty response"])
    }
    return out
  }

  /// Calls an MCP tool and returns its `result` object.
  private static func iosMcpCall(tool: String, arguments: [String: Any]) throws -> [String: Any] {
    let url = URL(string: Self.iosMcpBaseURL)!
    // Best-effort handshake; the server stores the negotiated version globally.
    let _ = try? Self.iosMcpPost(url: url, body: [
      "jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": [
        "protocolVersion": "2025-11-25",
        "capabilities": [:],
        "clientInfo": ["name": "operit2", "version": "0.3.47"],
      ],
    ])
    let resp = try Self.iosMcpPost(url: url, body: [
      "jsonrpc": "2.0", "id": 2, "method": "tools/call",
      "params": ["name": tool, "arguments": arguments],
    ])
    if let error = resp["error"] as? [String: Any],
       let message = error["message"] as? String {
      throw NSError(domain: "operit", code: 1, userInfo: [NSLocalizedDescriptionKey: "ios-mcp \(tool) error: \(message)"])
    }
    guard let result = resp["result"] as? [String: Any] else {
      throw NSError(domain: "operit", code: 1, userInfo: [NSLocalizedDescriptionKey: "ios-mcp \(tool): missing result"])
    }
    return result
  }

  /// Parses an OCR result: prefers `structuredContent`, else `content[0].text` (JSON).
  /// Boxes are returned in normalized 0..1 (top-left) coordinates by dividing the
  /// screen-point rect by the reported screen size, matching the prior Vision output.
  private static func iosMcpOcrResult(_ result: [String: Any]) -> (text: String, boxes: [[String: Any]]) {
    var dict: [String: Any]? = result["structuredContent"] as? [String: Any]
    if dict == nil {
      if let content = result["content"] as? [[String: Any]],
         let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String,
         let data = text.data(using: .utf8),
         let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        dict = obj
      }
    }
    guard let dict else { return ("", []) }
    let texts = dict["texts"] as? [[String: Any]] ?? []
    let screen = dict["screen"] as? [String: Any]
    let sw = max((screen?["width"] as? Int) ?? 0, 1)
    let sh = max((screen?["height"] as? Int) ?? 0, 1)
    let text = texts.map { $0["text"] as? String ?? "" }.joined(separator: "\n")
    let boxes: [[String: Any]] = texts.compactMap { t in
      guard let rect = t["rect"] as? [String: Any],
            let rx = rect["x"] as? Double, let ry = rect["y"] as? Double,
            let rw = rect["width"] as? Double, let rh = rect["height"] as? Double else { return nil }
      return [
        "text": t["text"] as? String ?? "",
        "x": rx / Double(sw), "y": ry / Double(sh),
        "w": rw / Double(sw), "h": rh / Double(sh),
      ]
    }
    return (text, boxes)
  }

  // The agent control channel now runs over loopback TCP (127.0.0.1:8890) —
  // `operitSendLine` connects to the fixed loopback port; these path constants
  // are retained only for backward compatibility.
  private static let operitDeviceSocketPath: String = {
    (iosDataRoot() as NSString).appendingPathComponent("operit.sock")
  }()
  private static let operitAgentSocketPath: String = {
    (iosDataRoot() as NSString).appendingPathComponent("agent.sock")
  }()

  /// Sends one line command to the local agent daemon over TCP loopback
  /// (127.0.0.1:8890) and returns the full reply (read to EOF). The
  /// `socketPath` argument is retained for API compatibility but the address is
  /// fixed to the loopback port.
  private static func operitSendLine(_ command: String, socketPath: String) throws -> String {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(bigEndian: 8890)
    addr.sin_addr = in_addr(s_addr: 0x7F000001) // 127.0.0.1 in network byte order
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 {
      throw NSError(domain: "operit", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
    }
    defer { close(fd) }
    let connected = withUnsafePointer(to: addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if connected < 0 {
      throw NSError(domain: "operit", code: 1, userInfo: [NSLocalizedDescriptionKey: "connect 127.0.0.1:8890 failed"])
    }
    let cmdData = [UInt8](command.utf8)
    let sent = cmdData.withUnsafeBytes { write(fd, $0.baseAddress, cmdData.count) }
    if sent < 0 {
      throw NSError(domain: "operit", code: 1, userInfo: [NSLocalizedDescriptionKey: "write failed"])
    }
    var newline: UInt8 = 10
    _ = withUnsafeBytes(of: &newline) { write(fd, $0.baseAddress, 1) }
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let capacity = buffer.count
      let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, capacity) }
      if n <= 0 { break }
      reply.append(buffer, count: n)
    }
    guard let text = String(data: reply, encoding: .utf8) else {
      throw NSError(domain: "operit", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid utf8 reply"])
    }
    return text
  }

  /// Extracts width/height from a PNG IHDR block (bytes 16..24 after the 8-byte signature).
  private static func pngSize(_ data: Data) -> (UInt32, UInt32) {
    guard data.count >= 24, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 else {
      return (0, 0)
    }
    let w = (UInt32(data[16]) << 24) | (UInt32(data[17]) << 16) | (UInt32(data[18]) << 8) | UInt32(data[19])
    let h = (UInt32(data[20]) << 24) | (UInt32(data[21]) << 16) | (UInt32(data[22]) << 8) | UInt32(data[23])
    return (w, h)
  }

  private func ownerSystemDeviceAgentPing(result: @escaping FlutterResult) {
    deviceAgentControl(command: "ping", result: result)
  }

  private func ownerSystemDeviceAgentStatus(result: @escaping FlutterResult) {
    deviceAgentControl(command: "status", result: result)
  }

  private func ownerSystemDeviceAgentStart(result: @escaping FlutterResult) {
    deviceAgentControl(command: "start", result: result)
  }

  private func ownerSystemDeviceAgentStop(result: @escaping FlutterResult) {
    deviceAgentControl(command: "stop", result: result)
  }

  private func ownerSystemDeviceAgentGoal(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let goal = args["goal"] as? String, !goal.isEmpty else {
      result(FlutterError(code: "INVALID_ARGS", message: "ownerSystemDeviceAgentGoal expects a non-empty goal", details: nil))
      return
    }
    deviceAgentControl(command: "goal \(goal)", result: result)
  }

  private func deviceAgentControl(command: String, result: @escaping FlutterResult) {
    workQueue.async {
      do {
        let reply = try Self.operitSendLine(command, socketPath: Self.operitAgentSocketPath)
        DispatchQueue.main.async {
          result(reply.trimmingCharacters(in: .whitespacesAndNewlines))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "DEVICE_AGENT_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func ownerSystemRecognizeText(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard (call.arguments as? [String: Any]) != nil else {
      result(FlutterError(code: "INVALID_ARGS", message: "ownerSystemRecognizeText expects a payload", details: nil))
      return
    }
    workQueue.async {
      do {
        // ios-mcp `ocr_screen` always OCRs the live screen; imagePath is ignored on iOS.
        let reply = try Self.iosMcpCall(tool: "ocr_screen", arguments: [:])
        let (text, boxes) = Self.iosMcpOcrResult(reply)
        DispatchQueue.main.async { result(["text": text, "boxes": boxes]) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "OWNER_SYSTEM_RECOGNIZE_TEXT_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  /// Executes one Core-owned system operation through the iOS application host.
  private func ownerSystemOperation(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let payload = call.arguments as? [String: Any],
          let operation = payload["operation"] as? String,
          let paramsJson = payload["paramsJson"] as? String else {
      result(FlutterError(code: "INVALID_ARGS", message: "ownerSystemOperation expects operation and paramsJson", details: nil))
      return
    }
    guard operation == "send_notification" else {
      result(FlutterError(code: "OWNER_SYSTEM_OPERATION_ERROR", message: "unsupported system operation: \(operation)", details: nil))
      return
    }
    let title: String
    let message: String
    let activation: [String: Any]
    do {
      guard let paramsData = paramsJson.data(using: .utf8) else {
        throw RuntimeChannelError.invalidArgs("system notification paramsJson is not UTF-8")
      }
      guard let params = try JSONSerialization.jsonObject(with: paramsData) as? [String: Any],
            let parsedTitle = params["title"] as? String,
            let parsedMessage = params["message"] as? String,
            let parsedActivation = params["activation"] as? [String: Any],
            let activationType = parsedActivation["type"] as? String else {
        throw RuntimeChannelError.invalidArgs("system notification paramsJson requires title, message, and activation")
      }
      guard activationType == "open_application" ||
              (activationType == "open_chat" && parsedActivation["chatId"] is String) else {
        throw RuntimeChannelError.invalidArgs("system notification activation is invalid")
      }
      title = parsedTitle
      message = parsedMessage
      activation = parsedActivation
    } catch {
      result(FlutterError(code: "INVALID_ARGS", message: error.localizedDescription, details: nil))
      return
    }
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, authorizationError in
      if let authorizationError {
        DispatchQueue.main.async {
          result(FlutterError(code: "OWNER_SYSTEM_OPERATION_ERROR", message: authorizationError.localizedDescription, details: nil))
        }
        return
      }
      guard granted else {
        DispatchQueue.main.async {
          result(FlutterError(code: "OWNER_SYSTEM_OPERATION_ERROR", message: "iOS notification permission is not granted", details: nil))
        }
        return
      }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = message
      content.sound = .default
      content.userInfo = ["operitNotificationActivation": activation]
      let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
      center.add(request) { deliveryError in
        DispatchQueue.main.async {
          if let deliveryError {
            result(FlutterError(code: "OWNER_SYSTEM_OPERATION_ERROR", message: deliveryError.localizedDescription, details: nil))
            return
          }
          result(["resultJson": "{\"success\":true}"])
        }
      }
    }
  }

  private func ownerAudioPlay(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let payload = call.arguments as? [String: Any],
      let path = payload["path"] as? String
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "ownerAudioPlay expects path", details: nil))
      return
    }
    do {
      let url = URL(fileURLWithPath: path)
      let player = try AVAudioPlayer(contentsOf: url)
      let key = UUID().uuidString
      audioPlayers[key] = player
      player.delegate = self
      player.prepareToPlay()
      player.play()
      result(["path": url.path, "started": true, "details": "av_audio_player_started"])
    } catch {
      result(FlutterError(code: "OWNER_AUDIO_PLAY_ERROR", message: error.localizedDescription, details: nil))
    }
  }

  private func ownerMusicPlayback(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let payload = call.arguments as? [String: Any],
      let command = payload["command"] as? String
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "ownerMusicPlayback expects command", details: nil))
      return
    }
    do {
      result(try musicPlayback(command: command, payload: payload))
    } catch {
      result(FlutterError(code: "OWNER_MUSIC_PLAYBACK_ERROR", message: error.localizedDescription, details: nil))
    }
  }

  private func ownerBluetooth(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let payload = call.arguments as? [String: Any],
      let command = payload["command"] as? String
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "ownerBluetooth expects command", details: nil))
      return
    }
    workQueue.async {
      do {
        let params = try self.dictionaryFromJson(payload["paramsJson"] as? String)
        let value = try self.bluetooth.handle(command: command, params: params)
        DispatchQueue.main.async {
          result(["resultJson": self.jsonString(value)])
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "OWNER_BLUETOOTH_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  // MARK: - Owner TTS synthesize (offline to file)

  private func ownerTtsSynthesize(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let payload = call.arguments as? [String: Any],
          let text = payload["text"] as? String, !text.isEmpty else {
      result(FlutterError(code: "INVALID_ARGS", message: "ownerTtsSynthesize expects text", details: nil))
      return
    }
    let voiceId = payload["voiceId"] as? String
    let rate = Float(payload["rate"] as? Double ?? 0.5)
    DispatchQueue.main.async { [weak self] in
      self?.synthesizeSpeech(text: text, voiceId: voiceId, rate: rate, result: result)
    }
  }

  private func synthesizeSpeech(text: String, voiceId: String?, rate: Float, result: @escaping FlutterResult) {
    let fileName = "operit_tts_\(Int64(Date().timeIntervalSince1970 * 1000)).caf"
    let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
      try session.setActive(true)
    } catch {
      result(FlutterError(code: "OWNER_TTS_SYNTHESIZE_ERROR", message: "audio session: \(error.localizedDescription)", details: nil))
      return
    }
    let engine = AVAudioEngine()
    let outputFormat = engine.outputNode.outputFormat(forBus: 0)
    guard let file = try? AVAudioFile(forWriting: fileURL, settings: outputFormat.settings) else {
      result(FlutterError(code: "OWNER_TTS_SYNTHESIZE_ERROR", message: "cannot create audio file", details: nil))
      return
    }
    engine.outputNode.installTap(onBus: 0, bufferSize: 4096, format: outputFormat) { buffer, _ in
      try? file.write(from: buffer)
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      result(FlutterError(code: "OWNER_TTS_SYNTHESIZE_ERROR", message: "engine start: \(error.localizedDescription)", details: nil))
      return
    }
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    if let voiceId, let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
      utterance.voice = voice
    }
    utterance.rate = rate
    let delegate = TtsSynthesisDelegate { [weak engine] in
      engine?.stop()
      engine?.outputNode.removeTap(onBus: 0)
      try? session.setActive(false)
      result(["audioPath": fileURL.path])
    }
    synthesizer.delegate = delegate
    ttsSynthesisActive[fileURL.path] = (synthesizer, delegate)
    synthesizer.speak(utterance)
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
      guard let self else { return }
      if let task = self.ttsSynthesisActive.removeValue(forKey: fileURL.path) {
        task.0.stopSpeaking(at: .immediate)
        engine.stop()
        engine.outputNode.removeTap(onBus: 0)
        try? session.setActive(false)
        result(["audioPath": fileURL.path])
      }
    }
  }

  private class TtsSynthesisDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
      onFinish()
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
      onFinish()
    }
  }

  // MARK: - Media / file pickers

  private func topViewController() -> UIViewController? {
    if #available(iOS 13.0, *) {
      let scene = UIApplication.shared.connectedScenes
        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
      let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
      var root = window?.rootViewController
      while let presented = root?.presentedViewController {
        root = presented
      }
      return root
    } else {
      var root = UIApplication.shared.keyWindow?.rootViewController
      while let presented = root?.presentedViewController {
        root = presented
      }
      return root
    }
  }

  private func pickMedia(isVideo: Bool, result: @escaping FlutterResult) {
    #if os(iOS)
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard let vc = self.topViewController() else {
        result(FlutterError(code: "PICK_MEDIA_ERROR", message: "no root view controller", details: nil))
        return
      }
      if #available(iOS 14, *) {
        var configuration = PHPickerConfiguration()
        configuration.filter = isVideo ? .videos : .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        var delegate: MediaPickerDelegate!
        delegate = MediaPickerDelegate { [weak self] url, mediaType in
          defer { self?.activePickers.removeAll { ($0 as? MediaPickerDelegate) === delegate } }
          guard let url = url else {
            result(nil)
            return
          }
          let ext = mediaType == "video" ? "mp4" : "jpg"
          let destName = "operit_bg_\(Int64(Date().timeIntervalSince1970 * 1000)).\(ext)"
          let destURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(destName)
          do {
            if FileManager.default.fileExists(atPath: destURL.path) {
              try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: url, to: destURL)
            result(["path": destURL.path, "mediaType": mediaType])
          } catch {
            result(FlutterError(code: "PICK_MEDIA_ERROR", message: error.localizedDescription, details: nil))
          }
        }
        self.activePickers.append(delegate)
        picker.delegate = delegate
        vc.present(picker, animated: true, completion: nil)
      } else {
        result(FlutterError(code: "PICK_MEDIA_ERROR", message: "requires iOS 14+", details: nil))
      }
    }
    #else
    result(FlutterError(code: "PICK_MEDIA_ERROR", message: "picker is only available on iOS", details: nil))
    #endif
  }

  @available(iOS 14, *)
  private class MediaPickerDelegate: NSObject, PHPickerViewControllerDelegate {
    let completion: (URL?, String) -> Void
    init(completion: @escaping (URL?, String) -> Void) { self.completion = completion }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
      picker.dismiss(animated: true)
      guard let item = results.first else {
        completion(nil, "image")
        return
      }
      let isVideo = item.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
      let typeId = isVideo ? UTType.movie.identifier : UTType.image.identifier
      item.itemProvider.loadFileRepresentation(forTypeIdentifier: typeId) { url, _ in
        self.completion(url, isVideo ? "video" : "image")
      }
    }
  }

  private func ownerFileOpen(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let payload = call.arguments as? [String: Any],
          let path = payload["path"] as? String, !path.isEmpty else {
      result(FlutterError(code: "INVALID_ARGS", message: "ownerFileOpen expects path", details: nil))
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let url = URL(fileURLWithPath: path)
      guard let vc = self.topViewController() else {
        result(FlutterError(code: "FILE_OPEN_ERROR", message: "no root view controller", details: nil))
        return
      }
      let controller = UIDocumentInteractionController(url: url)
      self.fileInteractionDelegate.viewController = vc
      controller.delegate = self.fileInteractionDelegate
      if controller.presentOpenInMenu(from: vc.view.bounds, in: vc.view, animated: true) {
        result(nil)
      } else {
        result(FlutterError(code: "FILE_OPEN_ERROR", message: "cannot present open menu", details: nil))
      }
    }
  }

  private func ownerFileShare(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let payload = call.arguments as? [String: Any],
          let path = payload["path"] as? String, !path.isEmpty else {
      result(FlutterError(code: "INVALID_ARGS", message: "ownerFileShare expects path", details: nil))
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let url = URL(fileURLWithPath: path)
      guard let vc = self.topViewController() else {
        result(FlutterError(code: "FILE_SHARE_ERROR", message: "no root view controller", details: nil))
        return
      }
      let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      if let popover = activity.popoverPresentationController {
        popover.sourceView = vc.view
        popover.sourceRect = vc.view.bounds
      }
      vc.present(activity, animated: true) {
        result(nil)
      }
    }
  }

  private func ownerSystemLanguageCode(result: @escaping FlutterResult) {
    #if os(iOS)
    let code = Locale.preferredLanguages.first ?? "en"
    result(["languageCode": code])
    #else
    result(FlutterError(code: "LANG_ERROR", message: "language code is only available on iOS", details: nil))
    #endif
  }

  private class FileInteractionDelegate: NSObject, UIDocumentInteractionControllerDelegate {
    weak var viewController: UIViewController?
    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
      return viewController ?? UIViewController()
    }
  }

  /// Handles owner-host local inference commands.
  private func ownerLocalInference(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let payload = call.arguments as? [String: Any] else {
      result(FlutterError(code: "INVALID_ARGS", message: "ownerLocalInference expects payload", details: nil))
      return
    }
    workQueue.async {
      do {
        let response = try AppleLocalInferenceRunner.shared.run(payload: payload)
        DispatchQueue.main.async {
          result(response)
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "OWNER_LOCAL_INFERENCE_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  /// Mirrors the App's model-settings credentials into the jailbreak device
  /// daemon's shared config.plist, so the daemon (a separate process that only
  /// reads that fixed file) picks up the key typed in the App — no manual file
  /// editing on disk.
  private func syncDaemonConfig(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "INVALID_ARGS", message: "syncDaemonConfig expects arguments", details: nil))
      return
    }
    let apiKey = (args["apiKey"] as? String) ?? ""
    let provider = (args["provider"] as? String) ?? ""
    let baseUrl = (args["baseUrl"] as? String) ?? ""
    let model = (args["model"] as? String) ?? ""
    apiKey.withCString { ak in
      provider.withCString { pk in
        baseUrl.withCString { bk in
          model.withCString { mk in
            operit_flutter_bridge_sync_daemon_config(ak, pk, bk, mk)
          }
        }
      }
    }
    result(nil)
  }

  /// Handles owner-host system speech playback commands.
  private func ownerTtsPlayback(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let payload = call.arguments as? [String: Any],
      let command = payload["command"] as? String
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "ownerTtsPlayback expects command", details: nil))
      return
    }
    switch command {
    case "play":
      guard let path = payload["audioPath"] as? String, !path.isEmpty else {
        result(FlutterError(code: "INVALID_ARGS", message: "ownerTtsPlayback play expects audioPath", details: nil))
        return
      }
      do {
        speechSynthesizer.stopSpeaking(at: .immediate)
        stopTtsAudioPlayback()
        let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        player.delegate = self
        guard player.prepareToPlay(), player.play() else {
          throw RuntimeChannelError.invalidArgs("Apple TTS audio player failed to start")
        }
        ttsAudioPlayer = player
        ttsAudioPaused = false
        ttsPath = path
        result(ttsStatus(details: "apple_tts_audio_started"))
      } catch {
        result(FlutterError(code: "OWNER_TTS_PLAYBACK_ERROR", message: error.localizedDescription, details: nil))
      }
    case "speak":
      guard let text = payload["text"] as? String,
        let speed = payload["speed"] as? NSNumber,
        let pitch = payload["pitch"] as? NSNumber
      else {
        result(FlutterError(code: "INVALID_ARGS", message: "ownerTtsPlayback speak expects text, speed and pitch", details: nil))
        return
      }
      let utterance = AVSpeechUtterance(string: text)
      do {
        try configureSpeechUtterance(utterance, payload: payload, speed: speed, pitch: pitch)
      } catch {
        result(FlutterError(code: "OWNER_TTS_PLAYBACK_ERROR", message: error.localizedDescription, details: nil))
        return
      }
      let interrupt = (payload["interrupt"] as? Bool) == true
      if !interrupt, ttsAudioPlayer != nil || speechSynthesizer.isSpeaking {
        result(FlutterError(code: "OWNER_TTS_PLAYBACK_ERROR", message: "Apple TTS playback is busy", details: nil))
        return
      }
      if interrupt {
        speechSynthesizer.stopSpeaking(at: .immediate)
        stopTtsAudioPlayback()
      }
      ttsPath = "apple-tts"
      speechSynthesizer.speak(utterance)
      result(ttsStatus(details: "apple_tts_started"))
    case "pause":
      if let player = ttsAudioPlayer {
        player.pause()
        ttsAudioPaused = true
      } else {
        speechSynthesizer.pauseSpeaking(at: .word)
      }
      result(ttsStatus(details: "apple_tts_paused"))
    case "resume":
      if let player = ttsAudioPlayer {
        player.play()
        ttsAudioPaused = false
      } else {
        speechSynthesizer.continueSpeaking()
      }
      result(ttsStatus(details: "apple_tts_resumed"))
    case "stop":
      speechSynthesizer.stopSpeaking(at: .immediate)
      stopTtsAudioPlayback()
      result(ttsStatus(details: "apple_tts_stopped"))
    case "status":
      result(ttsStatus(details: "apple_tts_status"))
    default:
      result(FlutterError(code: "OWNER_TTS_PLAYBACK_ERROR", message: "unsupported tts command: \(command)", details: nil))
    }
  }

  /// Applies validated cross-platform voice settings to one Apple utterance.
  private func configureSpeechUtterance(
    _ utterance: AVSpeechUtterance,
    payload: [String: Any],
    speed: NSNumber,
    pitch: NSNumber
  ) throws {
    let speedMultiplier = speed.doubleValue
    guard speedMultiplier.isFinite, speedMultiplier > 0 else {
      throw RuntimeChannelError.invalidArgs("tts speed must be positive and finite")
    }
    let pitchMultiplier = pitch.doubleValue
    guard pitchMultiplier.isFinite, pitchMultiplier >= 0.5, pitchMultiplier <= 2.0 else {
      throw RuntimeChannelError.invalidArgs("tts pitch must be between 0.5 and 2.0")
    }
    let voiceName = (payload["voice"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let locale = (payload["locale"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !voiceName.isEmpty {
      guard let selectedVoice = AVSpeechSynthesisVoice.speechVoices().first(where: {
        $0.identifier == voiceName || $0.name == voiceName
      }) else {
        throw RuntimeChannelError.invalidArgs("tts voice not found: \(voiceName)")
      }
      if !locale.isEmpty,
        Locale.canonicalIdentifier(from: selectedVoice.language)
          != Locale.canonicalIdentifier(from: locale)
      {
        throw RuntimeChannelError.invalidArgs(
          "tts voice language \(selectedVoice.language) does not match locale \(locale)"
        )
      }
      utterance.voice = selectedVoice
    } else if !locale.isEmpty {
      guard let selectedVoice = AVSpeechSynthesisVoice(language: locale) else {
        throw RuntimeChannelError.invalidArgs("tts locale not supported: \(locale)")
      }
      utterance.voice = selectedVoice
    }
    let scaledRate = Double(AVSpeechUtteranceDefaultSpeechRate) * speedMultiplier
    guard scaledRate >= Double(AVSpeechUtteranceMinimumSpeechRate),
      scaledRate <= Double(AVSpeechUtteranceMaximumSpeechRate)
    else {
      throw RuntimeChannelError.invalidArgs("tts speed is outside the Apple speech rate range")
    }
    utterance.rate = Float(scaledRate)
    utterance.pitchMultiplier = Float(pitchMultiplier)
  }

  /// A single recognized text region with its bounding box, expressed in
  /// normalized screen coordinates (origin top-left, 0..1). These can be fed
  /// directly to device automation `tap`/`swipe`, which use the same convention
  /// as the SpringBoard tweak `act_tap` (see operit-sb.x: normalized 0..1,
  /// top-left origin, caller must supply already-normalized values).
  private struct RecognizedTextBox {
    let text: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double
  }

  /// Runs Vision text recognition and returns each detected string together with
  /// its bounding box. Vision's `boundingBox` uses a bottom-left origin, so the y
  /// coordinate is flipped to top-left to match the screen/tweak convention.
  private func recognizeText(imagePath: String) throws -> [RecognizedTextBox] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    let handler = VNImageRequestHandler(url: URL(fileURLWithPath: imagePath), options: [:])
    try handler.perform([request])
    guard let observations = request.results else {
      return []
    }
    return observations.compactMap { observation in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      let box = observation.boundingBox
      let w = Double(box.size.width)
      let h = Double(box.size.height)
      let x = Double(box.origin.x)
      let yTop = 1.0 - (Double(box.origin.y) + h)
      return RecognizedTextBox(text: candidate.string, x: x, y: yTop, w: w, h: h)
    }
  }

  private func musicPlayback(command: String, payload: [String: Any]) throws -> [String: Any?] {
    switch command {
    case "play":
      guard let source = payload["source"] as? String,
        let sourceType = payload["sourceType"] as? String
      else {
        throw RuntimeChannelError.invalidArgs("source and sourceType are required")
      }
      let url: URL
      switch sourceType {
      case "path":
        url = URL(fileURLWithPath: source)
      case "uri", "url":
        guard let parsed = URL(string: source) else {
          throw RuntimeChannelError.invalidArgs("music source URL is invalid")
        }
        url = parsed
      default:
        throw RuntimeChannelError.invalidArgs("unsupported music sourceType: \(sourceType)")
      }
      let player = AVPlayer(url: url)
      musicPlayer = player
      musicSource = source
      musicSourceType = sourceType
      musicTitle = payload["title"] as? String
      musicArtist = payload["artist"] as? String
      guard let volume = payload["volume"] as? NSNumber,
        let loopPlayback = payload["loopPlayback"] as? Bool,
        let position = payload["positionMs"] as? NSNumber
      else {
        throw RuntimeChannelError.invalidArgs("volume, loopPlayback and positionMs are required")
      }
      musicVolume = volume.doubleValue
      musicLoopPlayback = loopPlayback
      musicState = "playing"
      musicMessage = "apple music playback started"
      player.volume = Float(musicVolume)
      let startPositionMs = position.int64Value
      if startPositionMs > 0 {
        player.seek(to: CMTime(value: CMTimeValue(startPositionMs), timescale: 1000))
      }
      player.play()
      return musicStatus(message: musicMessage)
    case "pause":
      guard let player = musicPlayer else {
        throw RuntimeChannelError.invalidState("apple music player is not initialized")
      }
      player.pause()
      musicState = "paused"
      return musicStatus(message: "apple music playback paused")
    case "resume":
      guard let player = musicPlayer else {
        throw RuntimeChannelError.invalidState("apple music player is not initialized")
      }
      player.play()
      musicState = "playing"
      return musicStatus(message: "apple music playback resumed")
    case "stop":
      musicPlayer?.pause()
      musicPlayer = nil
      musicState = "stopped"
      return musicStatus(message: "apple music playback stopped")
    case "seek":
      guard let player = musicPlayer else {
        throw RuntimeChannelError.invalidState("apple music player is not initialized")
      }
      guard let position = payload["positionMs"] as? NSNumber else {
        throw RuntimeChannelError.invalidArgs("positionMs is required")
      }
      let positionMs = position.int64Value
      player.seek(to: CMTime(value: CMTimeValue(max(positionMs, 0)), timescale: 1000))
      return musicStatus(message: "apple music playback seeked")
    case "set_volume":
      guard let player = musicPlayer else {
        throw RuntimeChannelError.invalidState("apple music player is not initialized")
      }
      guard let volume = payload["volume"] as? NSNumber else {
        throw RuntimeChannelError.invalidArgs("volume is required")
      }
      musicVolume = volume.doubleValue
      player.volume = Float(musicVolume)
      return musicStatus(message: "apple music playback volume changed")
    case "status":
      return musicStatus(message: "apple music player status")
    default:
      throw RuntimeChannelError.invalidArgs("unsupported music command: \(command)")
    }
  }

  private func musicStatus(message: String) -> [String: Any?] {
    let positionSeconds: Double
    if let player = musicPlayer {
      positionSeconds = player.currentTime().seconds
    } else {
      positionSeconds = 0
    }
    let durationSeconds = musicPlayer?.currentItem?.duration.seconds
    return [
      "state": musicState,
      "source": musicSource,
      "sourceType": musicSourceType,
      "title": musicTitle,
      "artist": musicArtist,
      "durationMs": durationSeconds?.isFinite == true ? Int64(durationSeconds! * 1000) : nil,
      "positionMs": positionSeconds.isFinite ? Int64(positionSeconds * 1000) : 0,
      "bufferedPositionMs": positionSeconds.isFinite ? Int64(positionSeconds * 1000) : 0,
      "volume": musicVolume,
      "loopPlayback": musicLoopPlayback,
      "message": message,
    ]
  }

  /// Builds an authoritative Apple speech status snapshot.
  private func ttsStatus(details: String) -> [String: Any] {
    let audioActive = ttsAudioPlayer != nil
    return [
      "path": ttsPath,
      "active": audioActive || speechSynthesizer.isSpeaking,
      "paused": audioActive ? ttsAudioPaused : speechSynthesizer.isPaused,
      "details": details,
    ]
  }

  /// Stops and releases the active Apple TTS audio player.
  private func stopTtsAudioPlayback() {
    ttsAudioPlayer?.stop()
    ttsAudioPlayer = nil
    ttsAudioPaused = false
  }

  private func hasSubscriptionId(_ text: String) -> Bool {
    guard let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return false
    }
    return object["subscriptionId"] is String
  }

  private func jsonString(_ value: Any) -> String {
    do {
      let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
      guard let text = String(data: data, encoding: .utf8) else {
        return "{\"error\":\"json text encoding failed\"}"
      }
      return text
    } catch {
      return "{\"error\":\"json serialization failed: \(error.localizedDescription)\"}"
    }
  }

  private func dictionaryFromJson(_ text: String?) throws -> [String: Any] {
    guard let text = text, let data = text.data(using: .utf8) else {
      return [:]
    }
    let value = try JSONSerialization.jsonObject(with: data)
    guard let object = value as? [String: Any] else {
      throw RuntimeChannelError.invalidArgs("ownerBluetooth paramsJson must be an object")
    }
    return object
  }

  private func withUtf8Bytes<T>(_ text: String, _ body: (UnsafePointer<UInt8>?, Int) throws -> T) throws -> T {
    let bytes = Array(text.utf8)
    return try bytes.withUnsafeBufferPointer { buffer in
      try body(buffer.baseAddress, buffer.count)
    }
  }

  private func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    guard let pointer = pointer else {
      return ""
    }
    let value = String(cString: pointer)
    operit_flutter_bridge_free_string(pointer)
    return value
  }

  /// Copies and releases one owned Rust Link byte buffer.
  private func takeBytes(_ buffer: OperitByteBuffer) -> Data {
    guard let pointer = buffer.ptr else {
      return Data()
    }
    let data = Data(bytes: pointer, count: Int(buffer.len))
    operit_flutter_bridge_free_bytes(buffer)
    return data
  }
}

private enum AppleCrashChannel {
  private static var channel: FlutterMethodChannel?

  static func register(binaryMessenger: FlutterBinaryMessenger) {
    channel?.setMethodCallHandler(nil)
    let crashChannel = FlutterMethodChannel(name: "operit/crash", binaryMessenger: binaryMessenger)
    crashChannel.setMethodCallHandler { call, result in
      guard call.method == "present" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let details = arguments["details"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "present requires crash details", details: nil))
        return
      }
      DispatchQueue.main.async {
        guard let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let viewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
          result(FlutterError(code: "CRASH_VIEW_UNAVAILABLE", message: "native crash view is unavailable", details: nil))
          return
        }
        let alert = UIAlertController(title: "Operit2 has stopped", message: details, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Close", style: .destructive))
        viewController.present(alert, animated: true) {
          result(nil)
        }
      }
    }
    channel = crashChannel
  }
}

extension AppleRuntimeChannel: AVAudioPlayerDelegate {
  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    audioPlayers = audioPlayers.filter { $0.value !== player }
    if ttsAudioPlayer === player {
      ttsAudioPlayer = nil
      ttsAudioPaused = false
    }
  }
}

private final class AppleBluetoothController: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  private let callbackQueue = DispatchQueue(label: "operit.runtime.apple.bluetooth", qos: .userInitiated)
  private lazy var central = CBCentralManager(delegate: self, queue: callbackQueue)
  private let lock = NSLock()
  private var discovered: [UUID: CBPeripheral] = [:]
  private var sessions: [String: AppleBleSession] = [:]
  private var pendingConnects: [UUID: AppleBluetoothWaiter<CBPeripheral>] = [:]
  private var pendingDiscoveries: [String: AppleBluetoothWaiter<Void>] = [:]
  private var pendingReads: [String: AppleBluetoothWaiter<Data>] = [:]
  private var pendingWrites: [String: AppleBluetoothWaiter<Void>] = [:]
  private var connectedPeripheralIds: Set<UUID> = []
  private let eventSink: (String, [String: Any]) -> Void

  /// Creates the Apple Bluetooth controller with normalized event delivery.
  init(eventSink: @escaping (String, [String: Any]) -> Void) {
    self.eventSink = eventSink
    super.init()
  }

  func handle(command: String, params: [String: Any]) throws -> Any {
    switch command {
    case "request_permission":
      _ = central
      return "apple_bluetooth_permission_requested"
    case "state":
      return stateData()
    case "request_enable":
      _ = central
      return "apple_bluetooth_enable_controlled_by_system"
    case "bonded_devices":
      return ["devices": []]
    case "scan":
      return try scan(params: params)
    case "classic_connect", "classic_listen", "classic_accept", "classic_send", "classic_read", "classic_send_and_read":
      throw RuntimeChannelError.invalidState("Apple public Bluetooth API does not expose RFCOMM classic sessions")
    case "close":
      return try close(params: params)
    case "ble_connect":
      return try bleConnect(params: params)
    case "ble_discover_services":
      return try bleDiscoverServices(params: params)
    case "ble_read_characteristic":
      return try bleReadCharacteristic(params: params)
    case "ble_write_characteristic":
      return try bleWriteCharacteristic(params: params)
    case "ble_write_and_read_characteristic":
      try bleWriteCharacteristic(params: [
        "sessionId": requireString(params, "sessionId"),
        "serviceUuid": requireString(params, "writeServiceUuid"),
        "characteristicUuid": requireString(params, "writeCharacteristicUuid"),
        "text": params["text"] as Any,
        "dataBase64": params["dataBase64"] as Any,
      ])
      return try bleReadCharacteristic(params: [
        "sessionId": requireString(params, "sessionId"),
        "serviceUuid": requireString(params, "readServiceUuid"),
        "characteristicUuid": requireString(params, "readCharacteristicUuid"),
        "timeoutMs": params["timeoutMs"] as Any,
      ])
    case "ble_subscribe_characteristic":
      return try bleSubscribeCharacteristic(params: params)
    case "ble_read_notifications":
      return try bleReadNotifications(params: params)
    default:
      throw RuntimeChannelError.invalidArgs("unsupported Apple Bluetooth command: \(command)")
    }
  }

  /// Emits the normalized Bluetooth adapter power state.
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    eventSink(
      "bluetooth.adapter.powered_changed",
      ["powered": central.state == .poweredOn, "connected": !connectedPeripheralIds.isEmpty]
    )
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
    withLock {
      discovered[peripheral.identifier] = peripheral
    }
    eventSink(
      "bluetooth.device.found",
      bluetoothEventData(peripheral: peripheral, connected: peripheral.state == .connected, rssi: RSSI)
    )
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    withLock { connectedPeripheralIds.insert(peripheral.identifier) }
    eventSink(
      "bluetooth.device.connected",
      bluetoothEventData(peripheral: peripheral, connected: true, rssi: nil)
    )
    emitAdapterConnectionState()
    let waiter = withLock {
      pendingConnects.removeValue(forKey: peripheral.identifier)
    }
    waiter?.succeed(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    let waiter = withLock {
      pendingConnects.removeValue(forKey: peripheral.identifier)
    }
    waiter?.fail(error?.localizedDescription ?? "Apple BLE connect failed")
  }

  /// Emits normalized device and adapter state after a BLE disconnection.
  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    withLock { connectedPeripheralIds.remove(peripheral.identifier) }
    eventSink(
      "bluetooth.device.disconnected",
      bluetoothEventData(peripheral: peripheral, connected: false, rssi: nil)
    )
    emitAdapterConnectionState()
  }

  /// Builds the shared Bluetooth device event structure from CoreBluetooth state.
  private func bluetoothEventData(
    peripheral: CBPeripheral,
    connected: Bool,
    rssi: NSNumber?
  ) -> [String: Any] {
    return [
      "deviceAddress": peripheral.identifier.uuidString,
      "deviceName": peripheral.name ?? NSNull(),
      "connected": connected,
      "bonded": NSNull(),
      "rssi": rssi ?? NSNull(),
    ]
  }

  /// Emits whether any CoreBluetooth peripheral remains connected.
  private func emitAdapterConnectionState() {
    let connected = withLock { !connectedPeripheralIds.isEmpty }
    eventSink(
      "bluetooth.adapter.connection_state_changed",
      ["powered": central.state == .poweredOn, "connected": connected]
    )
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    let waiters = withLock {
      sessions.values
        .filter { $0.peripheral === peripheral }
        .compactMap { pendingDiscoveries.removeValue(forKey: $0.sessionId) }
    }
    for waiter in waiters {
      if let error = error {
        waiter.fail(error.localizedDescription)
      } else {
        waiter.succeed(())
      }
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    let waiters = withLock {
      sessions.values
        .filter { $0.peripheral === peripheral }
        .compactMap { session in
          let key = discoveryKey(sessionId: session.sessionId, serviceUuid: service.uuid.uuidString.lowercased())
          return pendingDiscoveries.removeValue(forKey: key)
        }
    }
    for waiter in waiters {
      if let error = error {
        waiter.fail(error.localizedDescription)
      } else {
        waiter.succeed(())
      }
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard let serviceUuid = characteristic.service?.uuid.uuidString else {
      return
    }
    let data = characteristic.value
    let waiters = withLock {
      var collected: [AppleBluetoothWaiter<Data>] = []
      for session in sessions.values where session.peripheral === peripheral {
        let key = characteristicKey(sessionId: session.sessionId, serviceUuid: serviceUuid, characteristicUuid: characteristic.uuid.uuidString)
        if let waiter = pendingReads.removeValue(forKey: key) {
          collected.append(waiter)
        } else if let data = data {
          session.notifications.append(notification(characteristicUuid: characteristic.uuid.uuidString.lowercased(), data: data))
        }
      }
      return collected
    }
    for waiter in waiters {
      if let error = error {
        waiter.fail(error.localizedDescription)
      } else if let data = data {
        waiter.succeed(data)
      } else {
        waiter.fail("Apple BLE characteristic value is missing")
      }
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    guard let serviceUuid = characteristic.service?.uuid.uuidString else {
      return
    }
    let waiters = withLock {
      var collected: [AppleBluetoothWaiter<Void>] = []
      for session in sessions.values where session.peripheral === peripheral {
        let key = characteristicKey(sessionId: session.sessionId, serviceUuid: serviceUuid, characteristicUuid: characteristic.uuid.uuidString)
        if let waiter = pendingWrites.removeValue(forKey: key) {
          collected.append(waiter)
        }
      }
      return collected
    }
    for waiter in waiters {
      if let error = error {
        waiter.fail(error.localizedDescription)
      } else {
        waiter.succeed(())
      }
    }
  }

  private func stateData() -> [String: Any] {
    switch central.state {
    case .poweredOn:
      return ["supported": true, "enabled": true, "state": "powered_on"]
    case .poweredOff:
      return ["supported": true, "enabled": false, "state": "powered_off"]
    case .unauthorized:
      return ["supported": true, "enabled": false, "state": "unauthorized"]
    case .unsupported:
      return ["supported": false, "enabled": false, "state": "unsupported"]
    case .resetting:
      return ["supported": true, "enabled": false, "state": "resetting"]
    case .unknown:
      return ["supported": true, "enabled": false, "state": "unknown"]
    @unknown default:
      return ["supported": true, "enabled": false, "state": "unknown"]
    }
  }

  private func scan(params: [String: Any]) throws -> [String: Any] {
    try ensurePoweredOn()
    let durationMs = intValue(params["durationMs"], name: "durationMs")
    withLock {
      discovered.removeAll()
    }
    central.scanForPeripherals(withServices: nil, options: nil)
    Thread.sleep(forTimeInterval: Double(max(durationMs, 0)) / 1000.0)
    central.stopScan()
    let devices = withLock {
      discovered.values.map { peripheral in
        [
          "name": peripheral.name as Any,
          "address": peripheral.identifier.uuidString,
          "type": "ble",
          "bondState": "unknown",
          "source": "apple.core_bluetooth",
          "rssi": NSNull(),
        ] as [String: Any]
      }
    }
    return ["devices": devices, "durationMs": durationMs, "includesBle": true]
  }

  private func bleConnect(params: [String: Any]) throws -> [String: Any] {
    try ensurePoweredOn()
    let address = try requireString(params, "address")
    guard let uuid = UUID(uuidString: address) else {
      throw RuntimeChannelError.invalidArgs("Apple BLE address must be a peripheral UUID")
    }
    guard let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
      throw RuntimeChannelError.invalidState("Apple BLE peripheral is not discovered: \(address)")
    }
    let waiter = AppleBluetoothWaiter<CBPeripheral>()
    withLock {
      pendingConnects[uuid] = waiter
    }
    central.connect(peripheral, options: nil)
    let connected = try waiter.wait(seconds: 20)
    connected.delegate = self
    let sessionId = "apple-ble-\(UUID().uuidString)"
    withLock {
      sessions[sessionId] = AppleBleSession(sessionId: sessionId, peripheral: connected)
    }
    return ["sessionId": sessionId, "address": connected.identifier.uuidString, "mode": "ble"]
  }

  private func bleDiscoverServices(params: [String: Any]) throws -> [String: Any] {
    let sessionId = try requireString(params, "sessionId")
    let timeoutMs = intValue(params["timeoutMs"], name: "timeoutMs")
    let session = try requireSession(sessionId)
    let waiter = AppleBluetoothWaiter<Void>()
    withLock {
      pendingDiscoveries[sessionId] = waiter
    }
    session.peripheral.discoverServices(nil)
    try waiter.wait(seconds: seconds(timeoutMs))
    var services: [[String: Any]] = []
    for service in session.peripheral.services ?? [] {
      let serviceUuid = service.uuid.uuidString.lowercased()
      let key = discoveryKey(sessionId: sessionId, serviceUuid: serviceUuid)
      let characteristicWaiter = AppleBluetoothWaiter<Void>()
      withLock {
        pendingDiscoveries[key] = characteristicWaiter
      }
      session.peripheral.discoverCharacteristics(nil, for: service)
      try characteristicWaiter.wait(seconds: seconds(timeoutMs))
      var characteristicItems: [[String: Any]] = []
      withLock {
        for characteristic in service.characteristics ?? [] {
          session.characteristics[characteristicKey(sessionId: sessionId, serviceUuid: serviceUuid, characteristicUuid: characteristic.uuid.uuidString)] = characteristic
          characteristicItems.append([
            "uuid": characteristic.uuid.uuidString.lowercased(),
            "properties": propertyNames(characteristic.properties),
          ])
        }
      }
      services.append(["uuid": serviceUuid, "characteristics": characteristicItems])
    }
    return ["sessionId": sessionId, "services": services]
  }

  private func bleReadCharacteristic(params: [String: Any]) throws -> [String: Any] {
    let sessionId = try requireString(params, "sessionId")
    let serviceUuid = try requireString(params, "serviceUuid")
    let characteristicUuid = try requireString(params, "characteristicUuid")
    let timeoutMs = intValue(params["timeoutMs"], name: "timeoutMs")
    let session = try requireSession(sessionId)
    let characteristic = try requireCharacteristic(session, serviceUuid: serviceUuid, characteristicUuid: characteristicUuid)
    let key = characteristicKey(sessionId: sessionId, serviceUuid: serviceUuid, characteristicUuid: characteristicUuid)
    let waiter = AppleBluetoothWaiter<Data>()
    withLock {
      pendingReads[key] = waiter
    }
    session.peripheral.readValue(for: characteristic)
    let data = try waiter.wait(seconds: seconds(timeoutMs))
    return readData(sessionId: sessionId, data: data)
  }

  private func bleWriteCharacteristic(params: [String: Any]) throws -> [String: Any] {
    let sessionId = try requireString(params, "sessionId")
    let serviceUuid = try requireString(params, "serviceUuid")
    let characteristicUuid = try requireString(params, "characteristicUuid")
    let data = try payloadData(params)
    let session = try requireSession(sessionId)
    let characteristic = try requireCharacteristic(session, serviceUuid: serviceUuid, characteristicUuid: characteristicUuid)
    let key = characteristicKey(sessionId: sessionId, serviceUuid: serviceUuid, characteristicUuid: characteristicUuid)
    let waiter = AppleBluetoothWaiter<Void>()
    withLock {
      pendingWrites[key] = waiter
    }
    session.peripheral.writeValue(data, for: characteristic, type: .withResponse)
    try waiter.wait(seconds: 20)
    return ["sessionId": sessionId, "bytesWritten": data.count]
  }

  private func bleSubscribeCharacteristic(params: [String: Any]) throws -> [String: Any] {
    let sessionId = try requireString(params, "sessionId")
    let serviceUuid = try requireString(params, "serviceUuid")
    let characteristicUuid = try requireString(params, "characteristicUuid")
    let enable = try requireBool(params, "enable")
    let session = try requireSession(sessionId)
    let characteristic = try requireCharacteristic(session, serviceUuid: serviceUuid, characteristicUuid: characteristicUuid)
    session.peripheral.setNotifyValue(enable, for: characteristic)
    return ["sessionId": sessionId, "bytesWritten": 0]
  }

  private func bleReadNotifications(params: [String: Any]) throws -> [String: Any] {
    let sessionId = try requireString(params, "sessionId")
    let limit = intValue(params["limit"], name: "limit")
    return try withLock {
      guard let session = sessions[sessionId] else {
        throw RuntimeChannelError.invalidState("Apple BLE session is not available: \(sessionId)")
      }
      let count = min(max(limit, 0), session.notifications.count)
      let entries = Array(session.notifications.prefix(count))
      session.notifications.removeFirst(count)
      return ["sessionId": sessionId, "notifications": entries]
    }
  }

  private func close(params: [String: Any]) throws -> String {
    let sessionId = try requireString(params, "sessionId")
    let session = withLock {
      sessions.removeValue(forKey: sessionId)
    }
    if let session = session {
      central.cancelPeripheralConnection(session.peripheral)
    }
    return "apple_bluetooth_session_closed:\(sessionId)"
  }

  private func ensurePoweredOn() throws {
    if central.state != .poweredOn {
      throw RuntimeChannelError.invalidState("Apple Bluetooth is not powered on: \(central.state.rawValue)")
    }
  }

  private func requireSession(_ sessionId: String) throws -> AppleBleSession {
    let session = withLock {
      sessions[sessionId]
    }
    guard let session = session else {
      throw RuntimeChannelError.invalidState("Apple BLE session is not available: \(sessionId)")
    }
    return session
  }

  private func requireCharacteristic(_ session: AppleBleSession, serviceUuid: String, characteristicUuid: String) throws -> CBCharacteristic {
    let key = characteristicKey(sessionId: session.sessionId, serviceUuid: serviceUuid, characteristicUuid: characteristicUuid)
    let characteristic = withLock {
      session.characteristics[key]
    }
    guard let characteristic = characteristic else {
      throw RuntimeChannelError.invalidState("Apple BLE characteristic is not discovered: \(serviceUuid)/\(characteristicUuid)")
    }
    return characteristic
  }

  private func propertyNames(_ properties: CBCharacteristicProperties) -> [String] {
    var names: [String] = []
    if (properties.rawValue & CBCharacteristicProperties.read.rawValue) != 0 { names.append("read") }
    if (properties.rawValue & CBCharacteristicProperties.write.rawValue) != 0 { names.append("write") }
    if (properties.rawValue & CBCharacteristicProperties.writeWithoutResponse.rawValue) != 0 { names.append("write_without_response") }
    if (properties.rawValue & CBCharacteristicProperties.notify.rawValue) != 0 { names.append("notify") }
    if (properties.rawValue & CBCharacteristicProperties.indicate.rawValue) != 0 { names.append("indicate") }
    return names
  }

  private func payloadData(_ params: [String: Any]) throws -> Data {
    let text = params["text"] as? String
    let dataBase64 = params["dataBase64"] as? String
    if let text = text, dataBase64 == nil {
      return Data(text.utf8)
    }
    if text == nil, let dataBase64 = dataBase64, let data = Data(base64Encoded: dataBase64) {
      return data
    }
    throw RuntimeChannelError.invalidArgs("Provide exactly one of text or dataBase64")
  }

  private func readData(sessionId: String, data: Data) -> [String: Any] {
    [
      "sessionId": sessionId,
      "bytesRead": data.count,
      "text": String(data: data, encoding: .utf8) as Any,
      "dataBase64": data.base64EncodedString(),
    ]
  }

  private func notification(characteristicUuid: String, data: Data) -> [String: Any] {
    [
      "characteristicUuid": characteristicUuid,
      "bytesRead": data.count,
      "text": String(data: data, encoding: .utf8) as Any,
      "dataBase64": data.base64EncodedString(),
      "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
    ]
  }

  private func seconds(_ timeoutMs: Int) -> TimeInterval {
    TimeInterval(max(timeoutMs, 1)) / 1000.0
  }

  private func characteristicKey(sessionId: String, serviceUuid: String, characteristicUuid: String) -> String {
    "\(sessionId):\(serviceUuid.lowercased()):\(characteristicUuid.lowercased())"
  }

  private func discoveryKey(sessionId: String, serviceUuid: String) -> String {
    "\(sessionId):\(serviceUuid.lowercased())"
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}

private final class AppleBleSession {
  let sessionId: String
  let peripheral: CBPeripheral
  var characteristics: [String: CBCharacteristic] = [:]
  var notifications: [[String: Any]] = []

  init(sessionId: String, peripheral: CBPeripheral) {
    self.sessionId = sessionId
    self.peripheral = peripheral
  }
}

private final class AppleBluetoothWaiter<T> {
  private let semaphore = DispatchSemaphore(value: 0)
  private var value: T?
  private var error: String?

  func succeed(_ value: T) {
    self.value = value
    semaphore.signal()
  }

  func fail(_ message: String) {
    error = message
    semaphore.signal()
  }

  func wait(seconds: TimeInterval) throws -> T {
    if semaphore.wait(timeout: .now() + seconds) == .timedOut {
      throw RuntimeChannelError.invalidState("Apple Bluetooth operation timed out")
    }
    if let error = error {
      throw RuntimeChannelError.invalidState(error)
    }
    guard let value = value else {
      throw RuntimeChannelError.invalidState("Apple Bluetooth operation completed without a result")
    }
    return value
  }
}

private func requireString(_ params: [String: Any], _ key: String) throws -> String {
  guard let value = params[key] as? String, !value.isEmpty else {
    throw RuntimeChannelError.invalidArgs("\(key) is required")
  }
  return value
}

private func requireBool(_ params: [String: Any], _ key: String) throws -> Bool {
  guard let value = params[key] as? Bool else {
    throw RuntimeChannelError.invalidArgs("\(key) is required")
  }
  return value
}

private func intValue(_ value: Any?, name: String) -> Int {
  if let number = value as? NSNumber {
    return number.intValue
  }
  if let string = value as? String, let int = Int(string) {
    return int
  }
  return 0
}

private enum RuntimeChannelError: LocalizedError {
  case createFailed(String)
  case invalidArgs(String)
  case invalidState(String)

  var errorDescription: String? {
    switch self {
    case .createFailed(let message):
      return message
    case .invalidArgs(let message):
      return message
    case .invalidState(let message):
      return message
    }
  }
}
