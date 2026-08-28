//
//  OperitLiveActivityWidget.swift
//  LiveActivityWidget
//
//  渲染 operit2 的实时活动（灵动岛 / 锁屏）。内容由主 app 经 ActivityKit
//  启动/更新（NotifyServer），本扩展只负责显示。
//
//  实时活动 API（ActivityKit / ActivityConfiguration / DynamicIsland）仅 iOS 16.1+。
//  本扩展部署目标降到 15.0 后，用 @available(iOS 16.1, *) 守卫 16.1-only 代码，
//  iOS 15.x 设备上回退到一个空的静态 WidgetConfiguration（扩展仍可编译/安装，
//  但不渲染实时活动——实时活动本身在 15.x 上无意义）。

#if canImport(ActivityKit)
import ActivityKit
#endif
import SwiftUI
import WidgetKit

/// 与主 app NotifyServer.swift 中相同的属性模型（各自编译一份，Codable 一致即可）。
/// ActivityAttributes 协议本身仅 iOS 16.1+，故整个类型守卫。
@available(iOS 16.1, *)
struct OperitLiveActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var title: String
    var body: String
  }
  var name: String
}

@available(iOS 16.1, *)
struct OperitLiveActivityView: View {
  let context: ActivityViewContext<OperitLiveActivityAttributes>

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(context.state.title)
        .font(.headline)
        .lineLimit(1)
      if !context.state.body.isEmpty {
        Text(context.state.body)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding()
  }
}

/// iOS 15.x 回退用的空 TimelineProvider（StaticConfiguration 需要一个 provider）。
struct OperitLiveActivityFallbackProvider: TimelineProvider {
  func placeholder(in context: Context) -> EmptyView { EmptyView() }
  func getSnapshot(in context: Context, completion: @escaping (EmptyView) -> Void) {
    completion(EmptyView())
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<EmptyView>) -> Void) {
    completion(Timeline(entries: [], policy: .never))
  }
}

@main
struct OperitLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    widgetBody()
  }

  /// iOS 15.x 回退：空静态配置，使扩展在 15.0 上仍可编译/安装（不渲染实时活动）。
  private func fallbackConfig() -> some WidgetConfiguration {
    StaticConfiguration(
      kind: "com.ai.assistance.operit.liveactivity.fallback",
      provider: OperitLiveActivityFallbackProvider()
    ) { _ in
      EmptyView()
    }
    .configurationDisplayName("Operit")
    .supportedFamilies([])
  }

  private func widgetBody() -> any WidgetConfiguration {
    if #available(iOS 16.1, *) {
      return activityConfig()
    } else {
      return fallbackConfig()
    }
  }

  /// 16.1-only 的实时活动配置，整段守卫。
  @available(iOS 16.1, *)
  private func activityConfig() -> some WidgetConfiguration {
    ActivityConfiguration(for: OperitLiveActivityAttributes.self) { context in
      OperitLiveActivityView(context: context)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text(context.state.title)
            .font(.headline)
            .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text("AI")
            .font(.caption.bold())
        }
        DynamicIslandExpandedRegion(.bottom) {
          if !context.state.body.isEmpty {
            Text(context.state.body)
              .font(.caption)
              .lineLimit(2)
          }
        }
      } compactLeading: {
        Text(String(context.state.title.prefix(6)))
          .font(.caption2)
      } compactTrailing: {
        Text("AI")
          .font(.caption2)
      } minimal: {
        Text("AI")
          .font(.caption2)
      }
    }
  }
}
