import Foundation
import SwiftUI

enum WxFomoTimeLabelStyle: Equatable {
  case prominent
  case compact

  var absoluteFont: Font {
    switch self {
    case .prominent:
      return .caption.monospacedDigit().weight(.semibold)
    case .compact:
      return .caption2.monospacedDigit().weight(.semibold)
    }
  }

  var relativeFont: Font {
    switch self {
    case .prominent:
      return .caption2.weight(.medium)
    case .compact:
      return .caption2.weight(.medium)
    }
  }

  var spacing: CGFloat {
    self == .prominent ? 2 : 1
  }
}

struct WxFomoTimeLabel: View {
  let date: Date
  let style: WxFomoTimeLabelStyle
  let alignment: HorizontalAlignment

  init(
    date: Date,
    style: WxFomoTimeLabelStyle = .compact,
    alignment: HorizontalAlignment = .leading
  ) {
    self.date = date
    self.style = style
    self.alignment = alignment
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      VStack(alignment: alignment, spacing: style.spacing) {
        Text(WxFomoTimeFormatting.absolute(date, relativeTo: context.date))
          .font(style.absoluteFont)
          .foregroundStyle(.primary)
        Text(WxFomoTimeFormatting.relative(date, relativeTo: context.date))
          .font(style.relativeFont)
          .foregroundStyle(WxFomoTheme.signal)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(WxFomoTimeFormatting.accessibilityLabel(date, relativeTo: context.date))
    }
    .help(WxFomoTimeFormatting.longDate(date))
  }
}

struct WxFomoTimePair: View {
  let title: String
  let date: Date

  var body: some View {
    HStack(alignment: .top, spacing: 7) {
      Text(title)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(width: 42, alignment: .leading)
      WxFomoTimeLabel(date: date, style: .compact, alignment: .leading)
    }
  }
}

private enum WxFomoTimeFormatting {
  static func absolute(_ date: Date, relativeTo now: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) {
      return date.formatted(.dateTime.hour().minute().second())
    }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
      return date.formatted(.dateTime.month().day().hour().minute().second())
    }
    return date.formatted(.dateTime.year().month().day().hour().minute().second())
  }

  static func relative(_ date: Date, relativeTo now: Date) -> String {
    let seconds = now.timeIntervalSince(date)
    guard seconds >= 0 else { return "即将" }
    if seconds < 10 { return "刚刚" }
    if seconds < 60 { return "\(Int(seconds)) 秒前" }

    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes) 分钟前" }

    let hours = minutes / 60
    if hours < 24 { return "\(hours) 小时前" }

    let days = hours / 24
    if days < 30 { return "\(days) 天前" }

    let months = days / 30
    if months < 12 { return "\(months) 个月前" }

    return "\(months / 12) 年前"
  }

  static func longDate(_ date: Date) -> String {
    date.formatted(date: .long, time: .standard)
  }

  static func accessibilityLabel(_ date: Date, relativeTo now: Date) -> String {
    "\(longDate(date))，\(relative(date, relativeTo: now))"
  }
}
