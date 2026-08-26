import SwiftUI

@main
struct FaceUnlockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(state)
        } label: {
            Image(systemName: state.status.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 메뉴바 전용 앱. Dock 아이콘·앱 전환기에 나타나지 않는다.
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { AppState.shared.start() }
    }
}
