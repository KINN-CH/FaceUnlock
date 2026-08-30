import Foundation

/// 사용자 설정. `UserDefaults` 백업.
///
/// 기본값 정책: **얼굴 잠금 해제는 꺼진 상태로 출고한다.** 사용자가 위험을 이해하고
/// 명시적으로 켜야만 동작한다.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    /// 얼굴 인식 잠금 해제 사용 여부. 기본 꺼짐.
    @Published var faceUnlockEnabled: Bool {
        didSet { defaults.set(faceUnlockEnabled, forKey: Key.faceUnlockEnabled) }
    }

    /// 깜빡임 챌린지 요구 여부. 기본 켜짐 — 끄면 인쇄 사진에도 열린다.
    @Published var requireBlink: Bool {
        didSet { defaults.set(requireBlink, forKey: Key.requireBlink) }
    }

    /// 코사인 유사도 임계값. 높을수록 엄격.
    @Published var matchThreshold: Float {
        didSet { defaults.set(matchThreshold, forKey: Key.matchThreshold) }
    }

    /// 인식 실패로 포기하기까지의 시간(초). 이후엔 비밀번호로만 열 수 있다.
    @Published var recognitionTimeout: Double {
        didSet { defaults.set(recognitionTimeout, forKey: Key.recognitionTimeout) }
    }

    /// 쓸 카메라의 `AVCaptureDevice.uniqueID`. `nil` 이면 자동(내장 우선).
    ///
    /// 맥북을 덮고 외장 모니터로 쓰면 내장 렌즈가 가려지는데, 자동 규칙은 내장을
    /// 우선하므로 그대로 두면 새까만 화면만 본다. 그래서 고를 수 있게 둔다.
    /// 바뀌면 곧바로 카메라 세션에 알린다. 저장만 해두면 **앱을 다시 켤 때까지
    /// 반영되지 않는다** — 세션은 한 번 구성한 장치를 계속 재사용하기 때문이다.
    @Published var preferredCameraID: String? {
        didSet {
            guard preferredCameraID != oldValue else { return }
            if let id = preferredCameraID {
                defaults.set(id, forKey: Settings.preferredCameraIDKey)
            } else {
                defaults.removeObject(forKey: Settings.preferredCameraIDKey)
            }
            CameraSession.shared.reconfigureForNewDevice()
        }
    }

    /// 고른 카메라의 표시 이름. 고를 때 같이 적어둔다.
    ///
    /// `uniqueID` 만으로는 그 장치가 지금 꽂혀 있지 않을 때 설정 화면에 보여줄
    /// 이름이 없다. 이름이 없으면 선택이 조용히 '자동' 으로 되돌아간 것처럼
    /// 보이고, 사용자는 설정이 안 먹는다고 오해한다.
    @Published var preferredCameraName: String? {
        didSet {
            if let name = preferredCameraName {
                defaults.set(name, forKey: Key.preferredCameraName)
            } else {
                defaults.removeObject(forKey: Key.preferredCameraName)
            }
        }
    }

    /// 새 버전이 나왔는지 GitHub 릴리스를 확인할지. 기본 켜짐.
    ///
    /// 기본을 끄면 이 기능의 목적 자체가 사라진다 — 결함이 있는 옛 버전을 쓰는
    /// 사람에게 닿는 것이 목적인데, 그 사람은 설정을 열어보지 않는다.
    /// 무엇이 오가는지는 설정 화면과 README 에 그대로 적어둔다.
    @Published var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: Key.checkForUpdates) }
    }

    /// 카메라 장치 선택은 **카메라 큐에서** 읽어야 한다
    /// ([CameraSession.preferredDevice]). 이 클래스는 `@MainActor` 라 거기서
    /// 건드릴 수 없으므로, 키만 밖으로 내어 `UserDefaults` 를 직접 읽게 한다.
    /// `UserDefaults` 자체는 스레드 안전하다.
    nonisolated static let preferredCameraIDKey = "preferredCameraID"

    private enum Key {
        static let faceUnlockEnabled  = "faceUnlockEnabled"
        static let requireBlink       = "requireBlink"
        static let matchThreshold     = "matchThreshold"
        static let recognitionTimeout = "recognitionTimeout"
        static let checkForUpdates    = "checkForUpdates"
        static let preferredCameraName = "preferredCameraName"
    }

    private init() {
        defaults.register(defaults: [
            Key.faceUnlockEnabled: false,
            Key.requireBlink: true,
            Key.matchThreshold: 0.48,
            Key.recognitionTimeout: 20.0,
            Key.checkForUpdates: true,
        ])
        faceUnlockEnabled  = defaults.bool(forKey: Key.faceUnlockEnabled)
        requireBlink       = defaults.bool(forKey: Key.requireBlink)
        matchThreshold     = defaults.float(forKey: Key.matchThreshold)
        recognitionTimeout = defaults.double(forKey: Key.recognitionTimeout)
        checkForUpdates    = defaults.bool(forKey: Key.checkForUpdates)
        preferredCameraID  = defaults.string(forKey: Settings.preferredCameraIDKey)
        preferredCameraName = defaults.string(forKey: Key.preferredCameraName)
    }
}
