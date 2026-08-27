import AppKit
import SwiftUI

/// 메뉴바 전용 앱이라 SwiftUI `Settings` 씬을 쓸 수 없다. NSWindow 를 직접 관리한다.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            window.title = T("FaceUnlock 설정", "FaceUnlock Settings")
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView().environmentObject(AppState.shared)
        )
        let win = NSWindow(contentViewController: hosting)
        win.title = T("FaceUnlock 설정", "FaceUnlock Settings")
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 460, height: 520))
        win.center()

        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}
