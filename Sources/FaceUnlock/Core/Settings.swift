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

    private enum Key {
        static let faceUnlockEnabled  = "faceUnlockEnabled"
        static let requireBlink       = "requireBlink"
        static let matchThreshold     = "matchThreshold"
        static let recognitionTimeout = "recognitionTimeout"
    }

    private init() {
        defaults.register(defaults: [
            Key.faceUnlockEnabled: false,
            Key.requireBlink: true,
            Key.matchThreshold: 0.48,
            Key.recognitionTimeout: 20.0,
        ])
        faceUnlockEnabled  = defaults.bool(forKey: Key.faceUnlockEnabled)
        requireBlink       = defaults.bool(forKey: Key.requireBlink)
        matchThreshold     = defaults.float(forKey: Key.matchThreshold)
        recognitionTimeout = defaults.double(forKey: Key.recognitionTimeout)
    }
}
