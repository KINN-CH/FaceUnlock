import ServiceManagement
import SwiftUI

/// 진입점.
///
/// `App` 에 `@main` 을 직접 붙이면 SwiftUI 런루프가 시작된 뒤에야 코드가 돈다.
/// 창 하나 띄우지 않고 끝나야 하는 인자가 하나 있어서(아래), 그보다 앞에
/// 끼어들 자리를 만든다.
@main
struct AppLauncher {
    static func main() {
        // scripts/uninstall.command 가 쓴다. 로그인 항목 등록은 앱 자신만
        // 해제할 수 있는데(SMAppService.mainApp), 스크립트에는 그 수단이 없다.
        // 앱을 띄우지 않고 등록만 풀고 즉시 끝낸다.
        if CommandLine.arguments.contains("--unregister-login-item") {
            try? SMAppService.mainApp.unregister()
            exit(0)
        }
        FaceUnlockApp.main()
    }
}

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
