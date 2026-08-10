//
//  AppLockUI.swift
//  Runner
//
//  Operit 应用锁的「原生 UIKit」用户界面（复刻苹果屏幕使用时间的交互，越狱实现）：
//  1. AppLockAuthorizeViewController —— 仿官方授权确认页（图标 + 说明 + 允许/不允许）。
//     越狱下不需要真授权（tweak 拦截直接生效），此页是用户确认入口。
//  2. AppLockPickerViewController  —— 仿官方"选取应用"列表：搜索 + 多选 + 全选，
//     完成后写锁名单 /var/mobile/.operit/app_lock.plist（tweak 读取拦截）。
//  3. AppListLoader / AppLockStore —— 已装应用枚举与名单读写。
//
import UIKit
import Foundation

// MARK: - 应用模型

struct AppInstalledApp {
  let bundleId: String
  let name: String
  let icon: UIImage?
}

// MARK: - 已安装应用枚举

enum AppListLoader {
  /// 枚举设备已安装应用（含图标与显示名）。LSApplicationWorkspace 在 MobileCoreServices。
  static func installedApps() -> [AppInstalledApp] {
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW)
    var apps: [AppInstalledApp] = []
    guard let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
      print("[AppLockUI] no LSApplicationWorkspace")
      return apps
    }
    guard let ws = cls.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() else {
      return apps
    }
    let all = ws.perform(NSSelectorFromString("allApplications"))?.takeUnretainedValue() as? [Any] ?? []
    for item in all {
      let proxy = item as AnyObject
      guard let bid = proxy.perform(NSSelectorFromString("bundleIdentifier"))?.takeUnretainedValue() as? String,
        !bid.isEmpty
      else { continue }
      if bid == "com.apple.springboard" { continue }
      let name = proxy.perform(NSSelectorFromString("localizedName"))?.takeUnretainedValue() as? String ?? bid
      let icon = proxy.perform(NSSelectorFromString("icon"))?.takeUnretainedValue() as? UIImage
      apps.append(AppInstalledApp(bundleId: bid, name: name, icon: icon))
    }
    return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
}

// MARK: - 锁名单读写（与 ScreenTimeServer / tweak 共享同一文件）

enum AppLockStore {
  static let path = "/var/mobile/.operit/app_lock.plist"

  static func load() -> [String: [String: String]] {
    (NSDictionary(contentsOfFile: path) as? [String: [String: String]]) ?? [:]
  }

  /// 保存一批应用的锁名单（文案统一；缺省用默认文案）。
  @discardableResult
  static func save(bundleIds: [String], title: String, subtitle: String, button: String) -> Bool {
    var dict = load()
    for bid in bundleIds {
      dict[bid] = ["title": title, "subtitle": subtitle, "button": button]
    }
    let ok = (dict as NSDictionary).write(toFile: path, atomically: true)
    print("[AppLockStore] save \(bundleIds.count) apps write=\(ok) total=\(dict.count)")
    return ok
  }
}

// MARK: - 授权确认页（仿官方，无面容 ID）

final class AppLockAuthorizeViewController: UIViewController {
  private let onResult: (Bool) -> Void
  private let appName: String

  init(appName: String, onResult: @escaping (Bool) -> Void) {
    self.appName = appName
    self.onResult = onResult
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let icon = UIImageView(frame: CGRect(x: 0, y: 0, width: 96, height: 96))
    icon.center = CGPoint(x: view.bounds.midX, y: 160)
    icon.image = UIImage(named: "AppIcon") ?? UIImage(systemName: "lock.shield.fill")
    icon.layer.cornerRadius = 22
    icon.clipsToBounds = true
    icon.tintColor = .systemIndigo
    view.addSubview(icon)

    let title = UILabel(frame: CGRect(x: 32, y: 300, width: view.bounds.width - 64, height: 30))
    title.text = "允许访问应用限制"
    title.font = .systemFont(ofSize: 22, weight: .semibold)
    title.textAlignment = .center
    view.addSubview(title)

    let body = UILabel(frame: CGRect(x: 40, y: 344, width: view.bounds.width - 80, height: 80))
    body.text = "Operit 需要管理设备上的应用使用，以便实施 AI 设定的使用限制。\n（越狱实现，无需系统授权）"
    body.font = .systemFont(ofSize: 14)
    body.textColor = .secondaryLabel
    body.textAlignment = .center
    body.numberOfLines = 0
    view.addSubview(body)

    let allow = UIButton(type: .system)
    allow.frame = CGRect(x: view.bounds.midX - 100, y: view.bounds.height - 220, width: 200, height: 50)
    allow.setTitle("允许", for: .normal)
    allow.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
    allow.backgroundColor = .systemIndigo
    allow.setTitleColor(.white, for: .normal)
    allow.layer.cornerRadius = 25
    allow.addAction(UIAction { [weak self] _ in
      self?.onResult(true)
      self?.dismiss(animated: true)
    }, for: .touchUpInside)
    view.addSubview(allow)

    let deny = UIButton(type: .system)
    deny.frame = CGRect(x: view.bounds.midX - 100, y: view.bounds.height - 150, width: 200, height: 44)
    deny.setTitle("不允许", for: .normal)
    deny.titleLabel?.font = .systemFont(ofSize: 15)
    deny.addAction(UIAction { [weak self] _ in
      self?.onResult(false)
      self?.dismiss(animated: true)
    }, for: .touchUpInside)
    view.addSubview(deny)
  }
}

// MARK: - 选取应用列表（搜索 + 多选 + 全选）

final class AppLockPickerViewController: UITableViewController, UISearchResultsUpdating {
  private let onDone: ([String]) -> Void
  private let onCancel: () -> Void
  private var allApps: [AppInstalledApp] = []
  private var filtered: [AppInstalledApp] = []
  private var selected = Set<String>()
  private let search = UISearchController(searchResultsController: nil)

  init(onDone: @escaping ([String]) -> Void, onCancel: @escaping () -> Void) {
    self.onDone = onDone
    self.onCancel = onCancel
    super.init(style: .plain)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "选取要限制的应用"
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancelTapped))
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(doneTapped))
    toolbarItems = [
      UIBarButtonItem(title: "全选", style: .plain, target: self, action: #selector(selectAllTapped)),
      UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
      UIBarButtonItem(title: "清除", style: .plain, target: self, action: #selector(clearAllTapped)),
    ]
    navigationController?.isToolbarHidden = false

    search.searchResultsUpdater = self
    search.obscuresBackgroundDuringPresentation = false
    navigationItem.searchController = search

    allApps = AppListLoader.installedApps()
    filtered = allApps
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    print("[AppLockPicker] \(allApps.count) apps loaded")
  }

  @objc private func cancelTapped() { onCancel() }
  @objc private func doneTapped() {
    onDone(Array(selected).sorted())
    navigationController?.dismiss(animated: true)
  }
  @objc private func selectAllTapped() {
    selected = Set(filtered.map { $0.bundleId })
    tableView.reloadData()
  }
  @objc private func clearAllTapped() {
    selected.removeAll()
    tableView.reloadData()
  }

  // MARK: UITableViewDataSource

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    filtered.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
    let app = filtered[indexPath.row]
    cell.textLabel?.text = app.name
    cell.detailTextLabel?.text = app.bundleId
    cell.imageView?.image = app.icon ?? UIImage(systemName: "app.fill")
    cell.accessoryType = selected.contains(app.bundleId) ? .checkmark : .none
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let bid = filtered[indexPath.row].bundleId
    if selected.contains(bid) { selected.remove(bid) } else { selected.insert(bid) }
    tableView.reloadRows(at: [indexPath], with: .none)
  }

  // MARK: UISearchResultsUpdating

  func updateSearchResults(for searchController: UISearchController) {
    guard let text = searchController.searchBar.text, !text.isEmpty else {
      filtered = allApps
      tableView.reloadData()
      return
    }
    filtered = allApps.filter {
      $0.name.localizedCaseInsensitiveContains(text) || $0.bundleId.localizedCaseInsensitiveContains(text)
    }
    tableView.reloadData()
  }
}
