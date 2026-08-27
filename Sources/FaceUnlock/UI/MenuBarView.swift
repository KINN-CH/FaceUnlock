import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Text(state.status.label)

        Divider()

        Toggle("얼굴로 잠금 해제", isOn: $settings.faceUnlockEnabled)

        if case .needsSetup(let why) = state.status {
            Button("‘\(why)’ 설정 열기") { openSettingsFor(why) }
        }

        Divider()

        Button("잠금화면 표시 미리보기") { LockOverlayController.shared.preview() }

        Button("설정…") { SettingsWindowController.shared.show() }
            .keyboardShortcut(",", modifiers: .command)

        Button("FaceUnlock 종료") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private func openSettingsFor(_ blocker: String) {
        switch blocker {
        case "카메라 권한":
            Task { _ = await Permissions.requestCamera(); state.refreshStatus() }
            Permissions.openCameraSettings()
        case "손쉬운 사용 권한":
            Permissions.checkAccessibility(prompt: true)
            Permissions.openAccessibilitySettings()
        case "얼굴 등록":
            EnrollmentWindowController.shared.show()
        default:
            // 모델 파일·비밀번호 등록은 앱 설정 창에서 처리한다.
            SettingsWindowController.shared.show()
        }
    }
}
