import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        Text(state.status.label)

        // 확인이 끝났을 때만 한 줄 는다. 확인 전이거나 실패했으면(오프라인,
        // 자동 확인 꺼둠) 아무 말도 하지 않는다 — 모르는 것을 '최신입니다' 라고
        // 말하면 거짓말이 된다.
        switch updates.result {
        case .newer(let release):
            Button(T("새 버전 \(release.version) 받기", "Get version \(release.version)")) {
                updates.openReleasePage()
            }
        case .upToDate:
            Text(T("최신 버전입니다 (\(updates.currentVersion))",
                   "Up to date (\(updates.currentVersion))"))
        case .never, .failed, .skipped:
            EmptyView()
        }

        Divider()

        Toggle(T("얼굴로 잠금 해제", "Unlock with Face"), isOn: $settings.faceUnlockEnabled)

        // 복호화 대기는 사용자가 "설정" 에서 할 일이 없다. 대신 무엇을 기다리는지
        // 알려준다 — 새 버전을 처음 실행하면 키체인 확인 창이 한 번 뜨는데,
        // 그 창에 답하기 전까지는 등록 얼굴도 비밀번호도 읽지 못한다.
        if case .needsSetup(.loadingFaces) = state.status {
            Text(T("키체인 확인 창이 뜨면 ‘항상 허용’을 눌러 주세요.",
                   "If a Keychain prompt appears, choose “Always Allow”."))
        } else if case .needsSetup(let blocker) = state.status {
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
