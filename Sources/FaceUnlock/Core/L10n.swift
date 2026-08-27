import Foundation

/// 앱 표시 언어.
enum AppLanguage: String, CaseIterable {
    /// macOS 시스템 언어를 따른다. 한국어가 아니면 영어로 표시한다.
    case system
    case korean
    case english
}

/// 언어 설정과 현재 해석값.
///
/// 문자열 테이블(.strings) 대신 코드에 한/영 쌍을 나란히 두는 [T] 방식을 쓴다.
/// 이 앱은 Makefile 로 조립하는 단일 바이너리라 lproj 번들 관리가 오히려
/// 번거롭고, 무엇보다 번역이 원문 바로 옆에 있어야 어긋나지 않는다.
@MainActor
final class L10n: ObservableObject {

    static let shared = L10n()

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.key)
            Self.updateResolved(language)
        }
    }

    private static let key = "appLanguage"

    /// 카메라 큐 등 메인 밖에서도 문자열을 만들어야 하므로(오류 메시지),
    /// 해석 결과만 잠금으로 감싸 어디서든 읽게 둔다.
    nonisolated private static let resolvedLock = NSLock()
    nonisolated(unsafe) private static var resolvedKorean = true

    nonisolated static var isKorean: Bool {
        resolvedLock.lock(); defer { resolvedLock.unlock() }
        return resolvedKorean
    }

    nonisolated private static func updateResolved(_ language: AppLanguage) {
        let korean: Bool
        switch language {
        case .korean:  korean = true
        case .english: korean = false
        case .system:
            korean = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
        }
        resolvedLock.lock(); resolvedKorean = korean; resolvedLock.unlock()
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key)
        language = saved.flatMap(AppLanguage.init(rawValue:)) ?? .system
        Self.updateResolved(language)
    }
}

/// 한국어/영어 문자열 쌍. 현재 언어에 맞는 쪽을 돌려준다.
///
/// 어느 스레드에서든 호출해도 된다.
func T(_ ko: String, _ en: String) -> String {
    L10n.isKorean ? ko : en
}
