import AVFoundation
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var store = FaceStore.shared
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var updates = UpdateChecker.shared

    @State private var password = ""
    @State private var passwordMessage: String?
    @State private var passwordOK = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    @State private var uninstallStep: UninstallStep?

    /// 지금 꽂혀 있는 카메라들. 창이 열릴 때마다 다시 읽는다 — 웹캠은 중간에
    /// 꽂았다 뺐다 한다.
    @State private var cameras: [AVCaptureDevice] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                warningBox
                permissionsSection
                faceSection
                passwordSection
                behaviourSection
                updateSection
                languageSection
                uninstallSection
                aboutFooter
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(minWidth: 440)
        .onAppear {
            state.refreshStatus()
            cameras = CameraSession.availableDevices()
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
                Text(T("얼굴 인식 모델이 없습니다. DMG 의 '설치 도우미' 를 실행하거나, "
                       + "저장소에서 make model 후 다시 빌드해 주세요.",
                       "The recognition model is missing. Run 'Install Helper' from the DMG, "
                       + "or run `make model` in the repository and rebuild."))
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

            cameraPicker
                .disabled(!settings.faceUnlockEnabled)

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

    /// 쓸 카메라 고르기.
    ///
    /// 기본값(자동)은 내장 카메라를 우선한다. 맥북을 덮고 외장 모니터로 쓰면
    /// 그 내장 렌즈가 가려져 있어서, 자동에 맡기면 새까만 화면만 본다.
    private var cameraPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(T("카메라", "Camera"), selection: $settings.preferredCameraID) {
                Text(T("자동 (내장 카메라 우선)", "Automatic (built-in first)"))
                    .tag(String?.none)
                ForEach(cameras, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(String?.some(device.uniqueID))
                }
                // 고른 장치가 지금 안 보여도 목록에서 지우지 않는다. 조용히
                // '자동' 으로 돌아간 것처럼 보이면 설정이 안 먹는다고 오해한다.
                if let id = settings.preferredCameraID,
                   !cameras.contains(where: { $0.uniqueID == id }) {
                    Text(T("연결되지 않음 — \(settings.preferredCameraName ?? id)",
                           "Not connected — \(settings.preferredCameraName ?? id)"))
                        .foregroundStyle(.secondary)
                        .tag(String?.some(id))
                }
            }
            .onChange(of: settings.preferredCameraID) { _, id in
                settings.preferredCameraName = cameras.first { $0.uniqueID == id }?.localizedName
            }

            Text(T("고르는 즉시 바뀝니다. 그 카메라가 잠금 화면에서 안 보이면 내장 카메라로 되돌아갑니다.",
                   "Takes effect immediately. If that camera is missing at lock time, it falls back to the built-in one."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 업데이트

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("업데이트", "Updates")).font(.headline)

            HStack {
                Text(T("현재 버전 \(Self.appVersion)", "Version \(Self.appVersion)"))
                Spacer()
                if updates.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Button(T("지금 확인", "Check now")) { updates.checkNow() }
                }
            }

            if let release = updates.available {
                HStack {
                    Text(T("새 버전 \(release.version) 이 나왔습니다.",
                           "Version \(release.version) is available."))
                    Spacer()
                    Button(T("이 버전 넘기기", "Skip")) { updates.skipAvailable() }
                    Button(T("받으러 가기", "Get it")) { updates.openReleasePage() }
                }
            } else if let at = updates.lastCheckedAt {
                // 확인 시각만 보고 '최신입니다' 라고 쓰면 안 된다. 그 시각은
                // 오프라인으로 실패했을 때도 갱신된다.
                Text(lastCheckLine(at)).font(.caption).foregroundStyle(.secondary)
            }

            Toggle(T("자동으로 확인", "Check automatically"), isOn: $settings.checkForUpdates)

            // 무엇이 오가는지 숨기지 않는다. 잠금 해제 도구가 밖으로 요청을
            // 보낸다면 사용자는 그게 무엇인지 알 자격이 있다.
            Text(T("""
            하루 한 번 GitHub 릴리스 페이지에 인증 없는 요청을 하나 보내 최신 버전 번호만 \
            읽어옵니다. 계정 정보·얼굴·사용 기록은 보내지 않으며, GitHub 서버가 알 수 있는 \
            것은 접속 IP뿐입니다. 내려받기와 설치는 사용자가 직접 합니다.
            """, """
            Once a day this fetches the latest version number with a single unauthenticated \
            request to GitHub. No account details, faces or usage data are sent — GitHub sees \
            only your IP address. Downloading and installing stays up to you.
            """))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    // MARK: 완전 삭제

    /// 삭제 흐름에서 사용자에게 물어봐야 하는 순간들.
    ///
    /// 한 화면에 `.alert` 를 여러 개 붙이면 SwiftUI 가 어느 하나만 띄우는 일이
    /// 있어서, 상태 하나로 묶고 알림도 하나만 둔다.
    enum UninstallStep {
        /// 정말 지울지 확인.
        case confirm
        /// 데이터 일부를 못 지웠다. 앱까지 지울지 다시 묻는다.
        case dataFailed(String)
        /// 데이터는 지웠는데 앱 번들을 못 옮겼다. 사용자가 직접 해야 한다.
        case trashFailed(String)
    }

    /// 지우는 방법이 "터미널에 명령어를 붙여넣기" 뿐이면 대부분은 앱만 휴지통에
    /// 넣고 나머지를 남긴다. 남는 것 중에는 봉인된 로그인 비밀번호와 얼굴
    /// 임베딩이 있다 — 그건 지우기 제일 쉬워야 할 것들이다. 그래서 버튼으로 둔다.
    private var uninstallSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(T("완전 삭제", "Uninstall")).font(.headline)

            Text(T("""
            등록한 얼굴, 봉인된 로그인 비밀번호, 내려받은 얼굴 인식 모델, 설정값, \
            로그인 시 자동 실행 등록을 모두 지운 뒤 앱을 휴지통으로 옮기고 종료합니다.
            """, """
            Deletes your enrolled faces, the sealed login password, the downloaded \
            recognition model, your settings and the launch-at-login registration, then \
            moves the app to the Trash and quits.
            """))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(T("FaceUnlock 완전 삭제…", "Uninstall FaceUnlock…"), role: .destructive) {
                    uninstallStep = .confirm
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .alert(uninstallAlertTitle,
               isPresented: Binding(get: { uninstallStep != nil },
                                    set: { if !$0 { uninstallStep = nil } })) {
            switch uninstallStep {
            case .confirm:
                Button(T("취소", "Cancel"), role: .cancel) {}
                Button(T("삭제하고 종료", "Delete and Quit"), role: .destructive) {
                    performUninstall()
                }
            case .dataFailed:
                Button(T("취소", "Cancel"), role: .cancel) {}
                Button(T("그래도 앱 삭제", "Delete the App Anyway"), role: .destructive) {
                    trashApp()
                }
            case .trashFailed, .none:
                Button(T("확인", "OK"), role: .cancel) {}
            }
        } message: {
            Text(uninstallAlertMessage)
        }
    }

    private var uninstallAlertTitle: String {
        switch uninstallStep {
        case .confirm, .none:
            return T("FaceUnlock 을 완전히 삭제할까요?", "Uninstall FaceUnlock?")
        case .dataFailed, .trashFailed:
            return T("삭제 중 문제가 있었습니다", "Something could not be removed")
        }
    }

    private var uninstallAlertMessage: String {
        switch uninstallStep {
        case .confirm, .none:
            return T("""
                지워지는 것: 등록된 얼굴, 저장된 로그인 비밀번호, 내려받은 인식 모델, \
                설정값, 로그인 시 자동 실행 등록.

                앱은 휴지통으로 옮겨지고 곧바로 종료됩니다. macOS 계정 비밀번호 자체는 \
                바뀌지 않습니다.
                """, """
                This removes: enrolled faces, the saved login password, the downloaded \
                recognition model, your settings, and the launch-at-login registration.

                The app is moved to the Trash and quits immediately. Your actual macOS \
                account password is not changed.
                """)
        case .dataFailed(let detail):
            return T("""
                다음 항목을 지우지 못했습니다:

                \(detail)

                앱까지 지우면 이 버튼으로 다시 시도할 수 없습니다. 저장소의 \
                scripts/uninstall.command 로 남은 것을 지울 수 있습니다.
                """, """
                These could not be removed:

                \(detail)

                Once the app is gone you cannot retry from here. You can clean up the \
                rest with scripts/uninstall.command from the repository.
                """)
        case .trashFailed(let detail):
            return T("""
                데이터는 지워졌지만 앱을 휴지통으로 옮기지 못했습니다: \(detail)

                Finder 에서 응용 프로그램 폴더의 FaceUnlock 을 직접 휴지통에 넣어 주세요.
                """, """
                Your data was removed, but the app could not be moved to the Trash: \(detail)

                Please drag FaceUnlock from your Applications folder to the Trash yourself.
                """)
        }
    }

    /// 데이터를 먼저 지우고, 깨끗하면 앱 자신을 휴지통으로 보낸다.
    ///
    /// 남은 게 있으면 곧바로 앱을 지우지 않는다. 앱이 사라진 뒤에는 사용자가
    /// 이 버튼으로 다시 시도할 방법이 없기 때문이다.
    ///
    /// 알림 버튼에서 곧바로 실행하지 않고 한 턴 미루는 이유: 알림이 닫히는 도중에
    /// `uninstallStep` 을 새 값으로 바꾸면 SwiftUI 가 닫으면서 그 값을 nil 로
    /// 되돌려, 다음 알림이 나타나지 않는다.
    private func performUninstall() {
        DispatchQueue.main.async {
            let report = Uninstaller.removeUserData()
            guard report.isClean else {
                uninstallStep = .dataFailed(report.failed.joined(separator: "\n"))
                return
            }
            trashApp()
        }
    }

    private func trashApp() {
        Uninstaller.trashAppAndQuit { message in
            uninstallStep = .trashFailed(message)
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

    /// 마지막 확인의 결말을 그대로 적는다.
    private func lastCheckLine(_ at: Date) -> String {
        let when = at.formatted(date: .abbreviated, time: .shortened)
        switch updates.result {
        case .upToDate:
            return T("마지막 확인 \(when) — 최신입니다.", "Last checked \(when) — up to date.")
        case .failed:
            return T("마지막 확인 \(when) — 확인하지 못했습니다.",
                     "Last checked \(when) — couldn’t check.")
        case .skipped:
            return T("마지막 확인 \(when) — 넘어간 버전이 있습니다.",
                     "Last checked \(when) — a version was skipped.")
        case .never, .newer:
            return T("마지막 확인 \(when)", "Last checked \(when)")
        }
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
