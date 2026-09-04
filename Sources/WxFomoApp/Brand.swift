import AppKit
import SwiftUI

enum WxFomoTheme {
  static let signal = Color(red: 0.15, green: 0.78, blue: 0.61)
  static let priority = Color(red: 1.00, green: 0.39, blue: 0.34)
  static let ink = Color(red: 0.08, green: 0.13, blue: 0.12)
  static let paper = Color(red: 0.96, green: 0.97, blue: 0.96)
}

struct WxFomoBrandMark: View {
  var body: some View {
    GeometryReader { proxy in
      let size = min(proxy.size.width, proxy.size.height)

      ZStack {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
          .fill(WxFomoTheme.ink)

        BrandBubbleShape()
          .fill(WxFomoTheme.paper)
          .frame(width: size * 0.68, height: size * 0.65)
          .offset(y: size * 0.015)

        Image(systemName: "dot.radiowaves.left.and.right")
          .font(.system(size: size * 0.28, weight: .bold))
          .foregroundStyle(WxFomoTheme.signal)
          .offset(y: -size * 0.035)

        Circle()
          .fill(WxFomoTheme.priority)
          .frame(width: size * 0.105, height: size * 0.105)
          .overlay {
            Circle().stroke(WxFomoTheme.paper, lineWidth: size * 0.035)
          }
          .offset(x: size * 0.28, y: -size * 0.27)
      }
      .frame(width: size, height: size)
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityHidden(true)
  }
}

struct WxFomoWindowChrome: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    WindowChromeReaderView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    (nsView as? WindowChromeReaderView)?.configureWindow()
  }
}

private final class WindowChromeReaderView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    configureWindow()
  }

  func configureWindow() {
    guard let window else { return }
    window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
    window.titleVisibility = .visible

    for buttonType in [
      NSWindow.ButtonType.closeButton,
      .miniaturizeButton,
      .zoomButton,
    ] {
      window.standardWindowButton(buttonType)?.isHidden = false
      window.standardWindowButton(buttonType)?.isEnabled = true
    }
  }
}

private struct BrandBubbleShape: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let body = CGRect(
      x: rect.width * 0.07,
      y: rect.height * 0.05,
      width: rect.width * 0.86,
      height: rect.height * 0.70
    )
    path.addRoundedRect(
      in: body,
      cornerSize: CGSize(width: rect.width * 0.20, height: rect.width * 0.20)
    )
    path.move(to: CGPoint(x: rect.width * 0.30, y: rect.height * 0.68))
    path.addLine(to: CGPoint(x: rect.width * 0.20, y: rect.height * 0.96))
    path.addLine(to: CGPoint(x: rect.width * 0.49, y: rect.height * 0.72))
    path.closeSubpath()
    return path
  }
}
