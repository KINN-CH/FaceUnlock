import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var store = FaceStore.shared

    @State private var password = ""
    @State private var passwordMessage: String?
    @State private var passwordOK = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                warningBox
                permissionsSection
                faceSection
                passwordSection
                behaviourSection
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(minWidth: 440)
        .onAppear { state.refreshStatus() }
    }

    // MARK: 경고 — 숨기거나 접어두지 않는다

    private var warningBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("켜기 전에 읽어주세요", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text("""
            • 이 기능은 2D 웹캠만 사용합니다. Apple의 Face ID와 달리 깊이 센서가 없어, \
            재생되는 영상으로 뚫릴 수 있습니다.
            • 잠금 화면에 비밀번호를 입력하는 방식이라, 이 앱은 로그인 비밀번호를 \
            기기에 보관합니다(Secure Enclave 키로 봉인). 이 Mac을 물리적으로 다루는 \
            공격자에게는 방어가 되지 않습니다.
            • FileVault 부팅 화면에는 적용되지 않습니다. 로그인 후 화면 잠금에서만 동작합니다.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 권한

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("권한").font(.headline)

            permissionRow(
                title: "카메라",
                detail: "얼굴을 인식하는 데 사용합니다.",
                granted: Permissions.hasCamera
            ) {
                // 최초 1회는 시스템 다이얼로그가 뜬다. 그 위로 설정 창까지 열면
                // 다이얼로그가 가려진다. 이미 거부된 뒤에만 설정으로 안내한다.
                Task {
                    let granted = await Permissions.requestCamera()
                    state.refreshStatus()
                    if !granted, Permissions.cameraStatus != .notDetermined {
                        Permissions.openCameraSettings()
                    }
                }
            }

            permissionRow(
                title: "손쉬운 사용",
                detail: "잠금 화면에 비밀번호를 입력하는 데 사용합니다.",
                granted: Permissions.hasAccessibility
            ) {
                Permissions.checkAccessibility(prompt: true)
                Permissions.openAccessibilitySettings()
            }

            // 이 앱을 직접 빌드해 쓰는 사람은 거의 반드시 한 번은 겪는다.
            // ad-hoc 서명의 지정 요구사항이 바이너리 해시라서, 다시 빌드하면
            // 시스템 설정 목록에는 체크된 채로 남는데 권한만 무효가 된다.
            if !Permissions.hasAccessibility {
                Text("시스템 설정에서 이미 허용했는데도 위 표시가 켜지지 않는다면, "
                     + "목록에서 FaceUnlock 을 '−' 로 지우고 다시 추가해 주세요. "
                     + "앱을 다시 빌드하면 이전 항목이 무효가 됩니다. "
                     + "저장소의 scripts/make_signing_cert.sh 를 한 번 실행해 두면 "
                     + "다시 빌드해도 권한이 유지됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
        }
    }

    private func permissionRow(title: String, detail: String,
                               granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("허용하기", action: action) }
        }
    }

    // MARK: 얼굴 등록

    private var faceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("등록된 얼굴").font(.headline)

            HStack {
                Image(systemName: store.isEnrolled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(store.isEnrolled ? .green : .secondary)
                Text(store.isEnrolled
                     ? "\(store.enrolledPoseCount)장 등록됨"
                     : "등록된 얼굴이 없습니다")
                Spacer()
                if store.isEnrolled {
                    Button("삭제") {
                        store.deleteEnrollment()
                        state.refreshStatus()
                    }
                }
                Button(store.isEnrolled ? "다시 등록" : "얼굴 등록…") {
                    EnrollmentWindowController.shared.show()
                }
                .disabled(!Permissions.hasCamera || !state.modelAvailable)
            }

            if !state.modelAvailable {
                Text("얼굴 인식 모델이 없습니다. 저장소의 tools/fetch_arcface.py 를 실행해 "
                     + "Resources/Models/ArcFace.mlpackage 를 만든 뒤 다시 빌드해 주세요.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 비밀번호를 등록하기 **전에** 인식만 확인할 수 있어야 한다.
            // 안 그러면 첫 테스트가 곧 비밀번호 주입 테스트가 된다.
            if store.isEnrolled {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("인식 테스트")
                        Text("잠금 해제 없이 인식만 확인합니다. 임계값을 정할 때 쓰세요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("테스트…") {
                        RecognitionTestWindowController.shared.show()
                    }
                    .disabled(!Permissions.hasCamera || !state.modelAvailable)
                }
            }
        }
    }

    // MARK: 비밀번호

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("로그인 비밀번호").font(.headline)

            Text("잠금 화면에 대신 입력해 주기 위해 필요합니다. Secure Enclave 키로 봉인해 "
                 + "이 Mac 에서만 열 수 있는 형태로 보관합니다.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if Vault.hasPassword {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("저장되어 있습니다")
                    Spacer()
                    Button("삭제") {
                        Vault.deletePassword()
                        passwordMessage = nil
                        state.refreshStatus()
                    }
                }
            } else {
                HStack {
                    SecureField("로그인 비밀번호", text: $password)
                        .onSubmit(savePassword)
                    Button("저장", action: savePassword)
                        .disabled(password.isEmpty)
                }
            }

            if let passwordMessage {
                Text(passwordMessage)
                    .font(.caption)
                    .foregroundStyle(passwordOK ? .green : .red)
            }
        }
    }

    /// 실제 로그인 비밀번호가 맞는지 확인한 뒤에만 저장한다.
    /// 틀린 값을 넣어두면 잠금 화면에서 오입력이 반복된다.
    private func savePassword() {
        do {
            try Vault.store(password: password)
            password = ""
            passwordOK = true
            passwordMessage = "확인 후 저장했습니다."
            state.refreshStatus()
        } catch {
            passwordOK = false
            passwordMessage = error.localizedDescription
        }
    }

    // MARK: 동작

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("동작").font(.headline)

            Toggle("얼굴로 잠금 해제", isOn: $settings.faceUnlockEnabled)

            Toggle("눈 깜빡임 확인 요구", isOn: $settings.requireBlink)
                .disabled(!settings.faceUnlockEnabled)
            Text("끄면 인쇄된 사진으로도 잠금이 열립니다. 켜두는 것을 강력히 권장합니다.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading) {
                HStack {
                    Text("인식 엄격도")
                    Spacer()
                    Text(String(format: "%.2f", settings.matchThreshold))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $settings.matchThreshold, in: 0.35...0.65)
                Text("높일수록 타인이 열 확률은 줄지만, 본인도 더 자주 실패합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!settings.faceUnlockEnabled)

            VStack(alignment: .leading) {
                HStack {
                    Text("인식 제한 시간")
                    Spacer()
                    Text("\(Int(settings.recognitionTimeout))초")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $settings.recognitionTimeout, in: 5...60, step: 5)
                Text("이 시간이 지나면 포기하고 비밀번호 입력으로 넘어갑니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!settings.faceUnlockEnabled)

            Toggle("로그인 시 자동 실행", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("자동 실행 설정 실패: \(error.localizedDescription, privacy: .public)")
            // 실제 상태와 토글을 다시 맞춘다.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
