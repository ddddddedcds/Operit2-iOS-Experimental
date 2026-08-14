//
//  TCCServer.swift
//  Runner
//
//  权限全家桶服务：AI 工具（contacts_*/calendar_*/reminders_*/photos_*/health_*/location_*）
//   → Tools.Net.openUrl（Rust）→ 127.0.0.1:8891（OperitLocalServer，经 OpenURLServer "tcc " 前缀）→ 本服务 → 系统公开 API 读写。
//  协议（每连接一行，命令用空格分隔，参数用 | 分隔；响应单行 JSON）：
//    contacts list [limit]            —— 通讯录全部（名字/电话/邮箱）
//    contacts search <query>          —— 按名字/电话搜索通讯录
//    calendar list [days]             —— 未来 N 天（默认 7）日历事件
//    calendar create <title>|<startISO>|<endISO>   —— 建日历事件
//    reminders list                    —— 未完成提醒
//    reminders create <title>|<dueISO> —— 建提醒（无 due 则不限日期）
//    photos recent [n]                —— 最近 N 张照片元数据（默认 10，不含图像）
//    photos save <base64>             —— 保存图片（PNG/JPEG）到相册
//    health steps [days]              —— 最近 N 天（默认 7）每日步数
//    health hrt [n]                   —— 最近 N 条心率样本（默认 10）
//    location get                     —— 当前坐标（lat/lon）
//  全部走系统公开 API（EventKit/Contacts/Photos/HealthKit/CoreLocation），
//  首次调用弹 TCC 授权；越狱 + no-sandbox 下 AppSync 使 entitlement 生效。
//  注意：与 OpenURLServer 同款教训——iOS 16 KVC 不可靠，本文件全部用公开 API，
//  不裸 value(forKey:)，任何一步失败只降级返回 JSON error，绝不崩。
//

import Foundation
import Network
import UIKit
import EventKit
import Contacts
import Photos
import HealthKit
import CoreLocation

final class TCCServer: NSObject, CLLocationManagerDelegate {
  static let shared = TCCServer()

  private let eventStore = EKEventStore()
  private let contactStore = CNContactStore()
  private let healthStore = HKHealthStore()
  private let locManager = CLLocationManager()
  private var locCallback: ((CLLocation?) -> Void)?

  // MARK: - 连接/协议

  // internal：由 OperitLocalServer（单端口 8891，经 OpenURLServer "tcc " 前缀）路由至此
  private func reply(_ conn: NWConnection, _ obj: Any) {
    let json: String
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
      let s = String(data: d, encoding: .utf8)
    {
      json = s
    } else {
      json = "{\"ok\":false,\"error\":\"json encode failed\"}"
    }
    print("[TCCServer] reply: \(String(json.prefix(200)))")
    conn.send(
      content: Data((json + "\n").utf8),
      completion: .contentProcessed { _ in conn.cancel() }
    )
  }

  private func ok(_ conn: NWConnection, _ data: Any) {
    reply(conn, ["ok": true, "data": data])
  }

  private func fail(_ conn: NWConnection, _ err: String) {
    reply(conn, ["ok": false, "error": err])
  }

  private func iso(_ d: Date?) -> String {
    guard let d else { return "" }
    let f = ISO8601DateFormatter()
    return f.string(from: d)
  }

  // internal：OpenURLServer 通过 "tcc " 前缀转发命令过来（同进程直调）
  func dispatch(_ line: String, conn: NWConnection) {
    let parts = line.split(separator: " ").map(String.init)
    let cmd = parts.first ?? ""
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      switch cmd {
      case "contacts":
        if parts.count >= 2 && parts[1] == "search" {
          let q = parts.dropFirst(2).joined(separator: " ")
          self.contactsSearch(q, conn: conn)
        } else {
          let limit = parts.count >= 2 ? Int(parts[1]) ?? 50 : 50
          self.contactsList(limit, conn: conn)
        }
      case "calendar":
        if parts.count >= 2 && parts[1] == "create" {
          let rest = parts.dropFirst(2).joined(separator: " ")
          self.calendarCreate(rest, conn: conn)
        } else {
          let days = parts.count >= 2 ? Int(parts[1]) ?? 7 : 7
          self.calendarList(days, conn: conn)
        }
      case "reminders":
        if parts.count >= 2 && parts[1] == "create" {
          let rest = parts.dropFirst(2).joined(separator: " ")
          self.reminderCreate(rest, conn: conn)
        } else {
          self.reminderList(conn: conn)
        }
      case "photos":
        if parts.count >= 2 && parts[1] == "save" {
          let b64 = parts.dropFirst(2).joined(separator: " ")
          self.photoSave(b64, conn: conn)
        } else {
          let n = parts.count >= 2 ? Int(parts[1]) ?? 10 : 10
          self.photosRecent(n, conn: conn)
        }
      case "health":
        if parts.count >= 2 && parts[1] == "hrt" {
          let n = parts.count >= 3 ? Int(parts[2]) ?? 10 : 10
          self.healthHeartrate(n, conn: conn)
        } else {
          let days = parts.count >= 2 ? Int(parts[1]) ?? 7 : 7
          self.healthSteps(days, conn: conn)
        }
      case "location":
        self.locationGet(conn: conn)
      default:
        self.fail(conn, "unknown cmd: \(line)")
      }
    }
  }

  // MARK: - 通讯录 (Contacts)

  private func contactKeys() -> [CNKeyDescriptor] {
    [
      CNContactGivenNameKey as CNKeyDescriptor,
      CNContactFamilyNameKey as CNKeyDescriptor,
      CNContactOrganizationNameKey as CNKeyDescriptor,
      CNContactPhoneNumbersKey as CNKeyDescriptor,
      CNContactEmailAddressesKey as CNKeyDescriptor,
    ]
  }

  private func contactsList(_ limit: Int, conn: NWConnection) {
    contactStore.requestAccess(for: .contacts) { [weak self] granted, err in
      guard let self else { return }
      guard granted else {
        self.fail(conn, "contacts denied: \(err?.localizedDescription ?? "no auth")")
        return
      }
      var out: [[String: Any]] = []
      do {
        let req = CNContactFetchRequest(keysToFetch: self.contactKeys())
        try self.contactStore.enumerateContacts(with: req) { c, _ in
          guard out.count < min(limit, 200) else { return }
          let name = (c.givenName + " " + c.familyName).trimmingCharacters(in: .whitespaces)
          out.append([
            "name": name.isEmpty ? (c.organizationName.isEmpty ? "?" : c.organizationName) : name,
            "phones": c.phoneNumbers.map { $0.value.stringValue },
            "emails": c.emailAddresses.map { $0.value as String },
          ])
        }
      } catch {
        self.fail(conn, "contacts fetch failed: \(error.localizedDescription)")
        return
      }
      self.ok(conn, out)
    }
  }

  private func contactsSearch(_ query: String, conn: NWConnection) {
    contactStore.requestAccess(for: .contacts) { [weak self] granted, err in
      guard let self else { return }
      guard granted else {
        self.fail(conn, "contacts denied: \(err?.localizedDescription ?? "no auth")")
        return
      }
      var out: [[String: Any]] = []
      do {
        let req = CNContactFetchRequest(keysToFetch: self.contactKeys())
        try self.contactStore.enumerateContacts(with: req) { c, _ in
          guard out.count < 50 else { return }
          let name = (c.givenName + " " + c.familyName).trimmingCharacters(in: .whitespaces)
          let phones = c.phoneNumbers.map { $0.value.stringValue }
          let hit = name.localizedCaseInsensitiveContains(query)
            || phones.contains { $0.localizedCaseInsensitiveContains(query) }
            || c.organizationName.localizedCaseInsensitiveContains(query)
          if hit {
            out.append([
              "name": name.isEmpty ? (c.organizationName.isEmpty ? "?" : c.organizationName) : name,
              "phones": phones,
              "emails": c.emailAddresses.map { $0.value as String },
            ])
          }
        }
      } catch {
        self.fail(conn, "contacts search failed: \(error.localizedDescription)")
        return
      }
      self.ok(conn, out)
    }
  }

  // MARK: - 日历 (EventKit events)

  private func calendarList(_ days: Int, conn: NWConnection) {
    eventStore.requestAccess(to: .event) { [weak self] granted, err in
      guard let self else { return }
      guard granted else {
        self.fail(conn, "calendar denied: \(err?.localizedDescription ?? "no auth")")
        return
      }
      let start = Date()
      let end = Date().addingTimeInterval(TimeInterval(days) * 86400)
      let pred = self.eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
      let events = self.eventStore.events(matching: pred).sorted { $0.startDate < $1.startDate }
      let out: [[String: Any]] = events.prefix(100).map {
        [
          "title": $0.title ?? "",
          "calendar": $0.calendar.title,
          "start": self.iso($0.startDate),
          "end": self.iso($0.endDate),
          "location": $0.location ?? "",
        ]
      }
      self.ok(conn, out)
    }
  }

  private func calendarCreate(_ arg: String, conn: NWConnection) {
    let parts = arg.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 3, !parts[0].isEmpty else {
      self.fail(conn, "calendar create usage: <title>|<startISO>|<endISO>")
      return
    }
    let f = ISO8601DateFormatter()
    guard let start = f.date(from: parts[1]), let end = f.date(from: parts[2]) else {
      self.fail(conn, "bad ISO date: \(parts[1]) / \(parts[2])")
      return
    }
    eventStore.requestAccess(to: .event) { [weak self] granted, err in
      guard let self else { return }
      guard granted else {
        self.fail(conn, "calendar denied: \(err?.localizedDescription ?? "no auth")")
        return
      }
      let ev = EKEvent(eventStore: self.eventStore)
      ev.title = parts[0]
      ev.startDate = start
      ev.endDate = end
      ev.calendar = self.eventStore.defaultCalendarForNewEvents
        ?? self.eventStore.calendars(for: .event).first
      do {
        try self.eventStore.save(ev, span: .thisEvent)
        self.ok(conn, ["id": ev.eventIdentifier, "title": ev.title ?? "", "start": self.iso(start), "end": self.iso(end)])
      } catch {
        self.fail(conn, "calendar save failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - 提醒 (EventKit reminders)

  private func reminderList(conn: NWConnection) {
    eventStore.requestAccess(to: .reminder) { [weak self] granted, err in
      guard let self else { return }
      guard granted else {
        self.fail(conn, "reminders denied: \(err?.localizedDescription ?? "no auth")")
        return
      }
      let pred = self.eventStore.predicateForIncompleteReminders(
        withDueDateStarting: nil, ending: nil, calendars: nil)
      self.eventStore.fetchReminders(matching: pred) { reminders in
        let out: [[String: Any]] = (reminders ?? []).prefix(100).map {
          [
            "title": $0.title ?? "",
            "due": self.iso($0.dueDateComponents?.date),
            "priority": $0.priority,
            "completed": $0.isCompleted,
          ]
        }
        self.ok(conn, out)
      }
    }
  }

  private func reminderCreate(_ arg: String, conn: NWConnection) {
    let parts = arg.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard let title = parts.first, !title.isEmpty else {
      self.fail(conn, "reminders create usage: <title>|<dueISO>")
      return
    }
    eventStore.requestAccess(to: .reminder) { [weak self] granted, err in
      guard let self else { return }
      guard granted else {
        self.fail(conn, "reminders denied: \(err?.localizedDescription ?? "no auth")")
        return
      }
      let r = EKReminder(eventStore: self.eventStore)
      r.title = title
      r.calendar = self.eventStore.defaultCalendarForNewReminders()
        ?? self.eventStore.calendars(for: .reminder).first
      if parts.count >= 2, let due = ISO8601DateFormatter().date(from: parts[1]) {
        r.dueDateComponents = Calendar.current.dateComponents(
          [.year, .month, .day, .hour, .minute], from: due)
      }
      do {
        try self.eventStore.save(r, commit: true)
        self.ok(conn, ["id": r.calendarItemIdentifier, "title": title, "due": parts.count >= 2 ? parts[1] : ""])
      } catch {
        self.fail(conn, "reminder save failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - 照片 (Photos)

  private func photosRecent(_ n: Int, conn: NWConnection) {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard status == .authorized || status == .limited else {
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] s in
        guard let self else { return }
        if s == .authorized || s == .limited {
          self.photosRecentInner(n, conn: conn)
        } else {
          self.fail(conn, "photos denied")
        }
      }
      return
    }
    photosRecentInner(n, conn: conn)
  }

  private func photosRecentInner(_ n: Int, conn: NWConnection) {
    let opts = PHFetchOptions()
    opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    opts.fetchLimit = min(max(n, 1), 50)
    let assets = PHAsset.fetchAssets(with: .image, options: opts)
    var out: [[String: Any]] = []
    assets.enumerateObjects { a, _, _ in
      out.append([
        "filename": a.value(forKey: "filename") as? String ?? "",
        "date": self.iso(a.creationDate),
        "w": a.pixelWidth,
        "h": a.pixelHeight,
        "loc": a.location != nil ? [a.location!.coordinate.latitude, a.location!.coordinate.longitude] : [],
      ])
    }
    ok(conn, out)
  }

  private func photoSave(_ b64: String, conn: NWConnection) {
    guard let data = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]), !data.isEmpty else {
      self.fail(conn, "bad base64")
      return
    }
    PHPhotoLibrary.shared().performChanges({
      let req = PHAssetCreationRequest.forAsset()
      req.addResource(with: .photo, data: data, options: nil)
    }) { okk, err in
      if okk {
        self.ok(conn, ["saved": true, "bytes": data.count])
      } else {
        self.fail(conn, "photo save failed: \(err?.localizedDescription ?? "unknown")")
      }
    }
  }

  // MARK: - 健康 (HealthKit)

  private func healthSteps(_ days: Int, conn: NWConnection) {
    guard HKHealthStore.isHealthDataAvailable(),
      let type = HKQuantityType.quantityType(forIdentifier: .stepCount)
    else {
      self.fail(conn, "health unavailable")
      return
    }
    let read: Set<HKObjectType> = [type]
    healthStore.requestAuthorization(toShare: [], read: read) { [weak self] okk, err in
      guard let self else { return }
      guard okk else {
        self.fail(conn, "health denied: \(err?.localizedDescription ?? "no auth")")
        return
      }
      let cal = Calendar.current
      let now = Date()
      let startDay = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: now))!
      let anchor = cal.startOfDay(for: now)
      var interval = DateComponents()
      interval.day = 1
      let query = HKStatisticsCollectionQuery(
        quantityType: type, quantitySamplePredicate: nil,
        options: [.cumulativeSum], anchorDate: anchor, intervalComponents: interval)
      query.initialResultsHandler = { _, results, err in
        guard let results else {
          self.fail(conn, "health query failed: \(err?.localizedDescription ?? "unknown")")
          return
        }
        var out: [[String: Any]] = []
        results.enumerateStatistics(from: startDay, to: now) { stat, _ in
          let v = stat.sumQuantity()?.doubleValue(for: HKUnit.count()) ?? 0
          out.append(["date": self.iso(stat.startDate), "steps": Int(v)])
        }
        self.ok(conn, out)
      }
      self.healthStore.execute(query)
    }
  }

  private func healthHeartrate(_ n: Int, conn: NWConnection) {
    guard HKHealthStore.isHealthDataAvailable(),
      let type = HKQuantityType.quantityType(forIdentifier: .heartRate)
    else {
      self.fail(conn, "health unavailable")
      return
    }
    let read: Set<HKObjectType> = [type]
    healthStore.requestAuthorization(toShare: [], read: read) { [weak self] okk, err in
      guard let self else { return }
      guard okk else {
        self.fail(conn, "health denied: \(err?.localizedDescription ?? "no auth")")
        return
      }
      let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
      let q = HKSampleQuery(
        sampleType: type, predicate: nil, limit: min(max(n, 1), 100), sortDescriptors: [sort]
      ) { _, samples, err in
        guard let samples else {
          self.fail(conn, "health query failed: \(err?.localizedDescription ?? "unknown")")
          return
        }
        let out: [[String: Any]] = samples.map {
          let v = ($0 as? HKQuantitySample)?.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) ?? 0
          return ["date": self.iso($0.startDate), "bpm": Int(v)]
        }
        self.ok(conn, out)
      }
      self.healthStore.execute(q)
    }
  }

  // MARK: - 定位 (CoreLocation)

  private func locationGet(conn: NWConnection) {
    locManager.delegate = self
    locManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    let status = locManager.authorizationStatus
    locCallback = { loc in
      if let loc {
        self.ok(conn, [
          "lat": loc.coordinate.latitude,
          "lon": loc.coordinate.longitude,
          "ts": self.iso(loc.timestamp),
        ])
      } else {
        self.fail(conn, "location unavailable")
      }
    }
    if status == .notDetermined {
      locManager.requestWhenInUseAuthorization() // 弹窗 → delegate 继续
      return
    }
    guard status == .authorizedWhenInUse || status == .authorizedAlways else {
      locCallback = nil
      self.fail(conn, "location denied")
      return
    }
    locManager.requestLocation()
  }

  // CLLocationManagerDelegate
  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    locCallback?(locations.last)
    locCallback = nil
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    locCallback?(nil)
    locCallback = nil
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = locManager.authorizationStatus
    if status == .authorizedWhenInUse || status == .authorizedAlways {
      if locCallback != nil { manager.requestLocation() }
    } else if status == .denied || status == .restricted {
      locCallback?(nil)
      locCallback = nil
    }
  }
}
