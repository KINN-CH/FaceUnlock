import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var store = FaceStore.shared
    @ObservedObject private var l10n = L10n.shared

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
                languageSection
                aboutFooter
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(minWidth: 440)
        .onAppear {
            state.refreshStatus()
            // 사용자가 시스템 설정에서 권한을 켜는 동안 이 창은 열려 있다.
            // 다시 읽지 않으면 초록불이 영영 안 켜진다.
            state.startPermissionPolling()
        }
        .onDisappear { state.stopPermissionPolling() }
    }

    // MARK: 경고 — 숨기거나 접어두지 않는다

    private var warningBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(T("켜기 전에 읽어주세요", "Read this before enabling"),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text(T("""
            • 이 기능은 2D 웹캠만 사용합니다. Apple의 Face ID와 달리 깊이 센서가 없어, \
            재생되는 영상으로 뚫릴 수 있습니다.
            • 잠금 화면에 비밀번호를 입력하는 방식이라, 이 앱은 로그인 비밀번호를 \
            기기에 보관합니다(Secure Enclave 키로 봉인). 이 Mac을 물리적으로 다루는 \
            공격자에게는 방어가 되지 않습니다.
            • FileVault 부팅 화면에는 적용되지 않습니다. 로그인 후 화면 잠금에서만 동작합니다.
            """, """
            • This feature uses the 2D webcam only. Unlike Apple's Face ID there is no \
            depth sensor, so it can be defeated by a replayed video.
            • It works by typing your password into the lock screen, so this app keeps \
            your login password on this Mac (sealed with a Secure Enclave key). It is no \
            defense against an attacker with physical access.
            • It does not apply to the FileVault boot screen — only to the post-login lock screen.
            """))
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
            Text(T("권한", "Permissions")).font(.headline)

            permissionRow(
                title: T("카메라", "Camera"),
                detail: T("얼굴을 인식하는 데 사용합니다.", "Used to recognize your face."),
                granted: state.hasCamera
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
                title: T("손쉬운 사용", "Accessibility"),
                detail: T("잠금 화면에 비밀번호를 입력하는 데 사용합니다.",
                          "Used to type your password into the lock screen."),
                granted: state.hasAccessibility
            ) {
                Permissions.checkAccessibility(prompt: true)
                Permissions.openAccessibilitySettings()
            }

            // 이 앱을 직접 빌드해 쓰는 사람은 거의 반드시 한 번은 겪는다.
            // ad-hoc 서명의 지정 요구사항이 바이너리 해시라서, 다시 빌드하면
            // 시스템 설정 목록에는 체크된 채로 남는데 권한만 무효가 된다.
            if !state.hasAccessibility {
                Text(T("시스템 설정에서 이미 허용했는데도 위 표시가 켜지지 않는다면, "
                       + "목록에서 FaceUnlock 을 '−' 로 지우고 다시 추가해 주세요. "
                       + "앱을 다시 빌드하면 이전 항목이 무효가 됩니다. "
                       + "저장소의 scripts/make_signing_cert.sh 를 한 번 실행해 두면 "
                       + "다시 빌드해도 권한이 유지됩니다.",
                       "If you already allowed this in System Settings but the check above "
                       + "stays off, remove FaceUnlock from the list with '−' and add it again. "
                       + "Rebuilding the app invalidates the old entry. Running "
                       + "scripts/make_signing_cert.sh once keeps the permission across rebuilds."))
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
            if !granted { Button(T("허용하기", "Allow…"), action: action) }
        }
    }

    // MARK: 얼굴 등록 — 최대 3명

    private var faceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(T("등록된 얼굴", "Enrolled Faces")).font(.headline)
                Spacer()
                Text("\(store.people.count)/\(FaceStore.maxPeople)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if store.people.isEmpty {
                HStack {
                    Image(systemName: "circle").foregroundStyle(.secondary)
                    Text(T("등록된 얼굴이 없습니다", "No faces enrolled"))
                }
            } else {
                ForEach(store.people) { person in
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name)
                            Text(T("\(person.samples.count)장 · \(person.createdAt.formatted(date: .abbreviated, time: .omitted)) 등록",
                                   "\(person.samples.count) shots · enrolled \(person.createdAt.formatted(date: .abbreviated, time: .omitted))"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(T("삭제", "Delete")) {
                            store.deletePerson(id: person.id)
                            state.refreshStatus()
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button(T("얼굴 추가…", "Add a Face…")) {
                    EnrollmentWindowController.shared.show()
                }
                .disabled(!state.hasCamera || !state.modelAvailable || !store.canAddPerson)
            }
            if !store.canAddPerson {
                Text(T("최대 \(FaceStore.maxPeople)명까지 등록할 수 있습니다.",
                       "Up to \(FaceStore.maxPeople) people can be enrolled."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !state.modelAvailable {
                Text(T("얼굴 인식 모델이 없습니다. 저장소의 tools/fetch_arcface.py 를 실행해 "
                       + "Resources/Models/ArcFace.mlpackage 를 만든 뒤 다시 빌드해 주세요.",
                       "The recognition model is missing. Run tools/fetch_arcface.py to create "
                       + "Resources/Models/ArcFace.mlpackage, then rebuild."))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 비밀번호를 등록하기 **전에** 인식만 확인할 수 있어야 한다.
            // 안 그러면 첫 테스트가 곧 비밀번호 주입 테스트가 된다.
            if store.isEnrolled {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("인식 테스트", "Recognition Test"))
                        Text(T("잠금 해제 없이 인식만 확인합니다. 임계값을 정할 때 쓰세요.",
                               "Checks recognition without unlocking. Useful for tuning the threshold."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(T("테스트…", "Test…")) {
                        RecognitionTestWindowController.shared.show()
                    }
                    .disabled(!state.hasCamera || !state.modelAvailable)
                }
            }
        }
    }

    // MARK: 비밀번호

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(T("로그인 비밀번호", "Login Password")).font(.headline)

            Text(T("잠금 화면에 대신 입력해 주기 위해 필요합니다. Secure Enclave 키로 봉인해 "
                   + "이 Mac 에서만 열 수 있는 형태로 보관합니다.",
                   "Needed so the app can type it into the lock screen for you. Stored sealed "
                   + "with a Secure Enclave key so it can only be opened on this Mac."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if Vault.hasPassword {
                HStack {
                    Image(systemName: passwordHasProblem
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(passwordHasProblem ? .orange : .green)
                    Text(passwordStatusText)
                    Spacer()
                    Button(T("삭제", "Delete")) {
                        Vault.deletePassword()
                        passwordMessage = nil
                        state.recheckVault()
                    }
                }

                // 앱 서명이 바뀌면 예전에 저장한 항목의 Keychain ACL 이 맞지 않게 된다.
                // 잠금화면에서는 확인 창에 답할 수 없으니 그대로 실패한다 —
                // 화면이 풀려 있는 지금 고쳐야 한다.
                if state.vaultUnreadable {
                    Text(T("앱을 다시 서명한 뒤라 예전 Keychain 항목에 접근할 수 없습니다. "
                           + "위 '삭제' 를 누르고 비밀번호를 다시 등록해 주세요. "
                           + "이 상태로는 잠금 화면에서 해제되지 않습니다.",
                           "The app's signature changed, so the old Keychain entry is no longer "
                           + "accessible. Press Delete above and register the password again. "
                           + "Unlocking will not work in this state."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 저장된 값이 실제로 거부됐다. 계속 밀어 넣으면 macOS 오입력이
                // 쌓여 지연·재시작 요구로 이어지므로 자동 해제를 이미 멈춘 상태다.
                if state.passwordRejected {
                    Text(T("잠금 화면에서 이 비밀번호가 거부됐습니다. macOS 로그인 "
                           + "비밀번호를 바꾸셨다면 위 '삭제' 를 누르고 새 비밀번호로 "
                           + "다시 등록해 주세요. 틀린 비밀번호가 반복 입력되는 것을 막기 "
                           + "위해 자동 잠금 해제를 멈춰 두었습니다.",
                           "The lock screen rejected this password. If you changed your macOS "
                           + "login password, press Delete above and register the new one. "
                           + "Automatic unlocking is paused to avoid repeated wrong entries."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack {
                    SecureField(T("로그인 비밀번호", "Login password"), text: $password)
                        .onSubmit(savePassword)
                    Button(T("저장", "Save"), action: savePassword)
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

    private var passwordHasProblem: Bool {
        state.vaultUnreadable || state.passwordRejected
    }

    private var passwordStatusText: String {
        if state.vaultUnreadable {
            return T("저장되어 있으나 열 수 없습니다", "Stored, but cannot be opened")
        }
        if state.passwordRejected {
            return T("저장되어 있으나 거부되었습니다", "Stored, but was rejected")
        }
        return T("저장되어 있습니다", "Stored")
    }

    /// 실제 로그인 비밀번호가 맞는지 확인한 뒤에만 저장한다.
    /// 틀린 값을 넣어두면 잠금 화면에서 오입력이 반복된다.
    private func savePassword() {
        do {
            try Vault.store(password: password)
            password = ""
            passwordOK = true
            passwordMessage = T("확인 후 저장했습니다.", "Verified and saved.")
            state.recheckVault()
        } catch {
            passwordOK = false
            passwordMessage = error.localizedDescription
        }
    }

    // MARK: 동작

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(T("동작", "Behavior")).font(.headline)

            Toggle(T("얼굴로 잠금 해제", "Unlock with Face"), isOn: $settings.faceUnlockEnabled)

            Toggle(T("눈 깜빡임 확인 요구", "Require a blink"), isOn: $settings.requireBlink)
                .disabled(!settings.faceUnlockEnabled)
            Text(T("끄면 인쇄된 사진으로도 잠금이 열립니다. 켜두는 것을 강력히 권장합니다.",
                   "If turned off, a printed photo can unlock this Mac. Strongly recommended on."))
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading) {
                HStack {
                    Text(T("인식 엄격도", "Match strictness"))
                    Spacer()
                    Text(String(format: "%.2f", settings.matchThreshold))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $settings.matchThreshold, in: 0.35...0.65)
                Text(T("높일수록 타인이 열 확률은 줄지만, 본인도 더 자주 실패합니다.",
                       "Higher means strangers are less likely to unlock — and so are you."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!settings.faceUnlockEnabled)

            VStack(alignment: .leading) {
                HStack {
                    Text(T("인식 제한 시간", "Recognition timeout"))
                    Spacer()
                    Text(T("\(Int(settings.recognitionTimeout))초", "\(Int(settings.recognitionTimeout))s"))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $settings.recognitionTimeout, in: 5...60, step: 5)
                Text(T("이 시간이 지나면 포기하고 비밀번호 입력으로 넘어갑니다.",
                       "After this long the app gives up and leaves you to the password."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!settings.faceUnlockEnabled)

            Toggle(T("로그인 시 자동 실행", "Launch at login"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
        }
    }

    // MARK: 언어

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("언어", "Language")).font(.headline)
            Picker("", selection: $l10n.language) {
                Text(T("시스템 설정 따름", "Match system")).tag(AppLanguage.system)
                Text("한국어").tag(AppLanguage.korean)
                Text("English").tag(AppLanguage.english)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: 만든 사람

    /// 창 맨 아래의 작은 크레딧. 방해하지 않도록 본문보다 옅게 둔다.
    private var aboutFooter: some View {
        VStack(spacing: 2) {
            Divider().padding(.bottom, 6)
            Text("FaceUnlock \(Self.appVersion) · Cheolho Kim (KINN-CH)")
            Link("github.com/KINN-CH/FaceUnlock",
                 destination: URL(string: "https://github.com/KINN-CH/FaceUnlock")!)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
    }

    private static let appVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

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
