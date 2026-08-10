//
//  OperitLiveActivityWidget.swift
//  LiveActivityWidget
//
//  渲染 operit2 的实时活动（灵动岛 / 锁屏）。内容由主 app 经 ActivityKit
//  启动/更新（NotifyServer），本扩展只负责显示。iOS 16.1+。
//

import ActivityKit
import SwiftUI
import WidgetKit

/// 与主 app NotifyServer.swift 中相同的属性模型（各自编译一份，Codable 一致即可）。
struct OperitLiveActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var title: String
    var body: String
  }
  var name: String
}

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

@main
struct OperitLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
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
