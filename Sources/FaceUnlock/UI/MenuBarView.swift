import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Text(state.status.label)

        Divider()

        Toggle(T("얼굴로 잠금 해제", "Unlock with Face"), isOn: $settings.faceUnlockEnabled)

        if case .needsSetup(let blocker) = state.status {
            Button(T("‘\(blocker.label)’ 설정 열기", "Set up ‘\(blocker.label)’…")) {
                openSettingsFor(blocker)
            }
        }

        Divider()

        Button(T("설정…", "Settings…")) { SettingsWindowController.shared.show() }
            .keyboardShortcut(",", modifiers: .command)

        Button(T("FaceUnlock 종료", "Quit FaceUnlock")) { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private func openSettingsFor(_ blocker: AppState.SetupBlocker) {
        switch blocker {
        case .cameraPermission:
            Task { _ = await Permissions.requestCamera(); state.refreshStatus() }
            Permissions.openCameraSettings()
        case .accessibilityPermission:
            Permissions.checkAccessibility(prompt: true)
            Permissions.openAccessibilitySettings()
        case .enrollment:
            EnrollmentWindowController.shared.show()
        case .model, .loadingFaces, .password, .passwordReenroll:
            // 모델 파일·비밀번호 등록은 앱 설정 창에서 처리한다.
            SettingsWindowController.shared.show()
        }
    }
}
