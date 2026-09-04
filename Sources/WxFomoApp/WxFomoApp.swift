import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

@main
struct WxFomoApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(model)
        .frame(minWidth: 920, minHeight: 620)
    }
    .defaultSize(width: 1120, height: 720)
    .windowStyle(.titleBar)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(after: .sidebar) {
        Button(model.isListening ? "停止监听" : "开始监听") {
          model.toggleListening()
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
      }
    }
  }
}
