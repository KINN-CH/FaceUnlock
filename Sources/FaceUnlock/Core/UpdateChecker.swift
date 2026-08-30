import AppKit
import Foundation

/// 릴리스 페이지에서 읽어온 최신 버전.
struct ReleaseInfo: Sendable {
    /// 태그에서 앞의 `v` 를 뗀 것. `v0.2.0` → `0.2.0`.
    let version: String
    let url: URL
}

/// GitHub 릴리스를 확인해 새 버전이 나왔는지 알린다.
///
/// **왜 넣었나**: v0.1.0~0.1.4 에는 잠금화면에서 카메라가 새까만 프레임만 주는
/// 결함이 있었다. v0.1.5 에서 고치고 옛 DMG 를 내렸지만, *이미 그 버전을 쓰고 있는
/// 사람에게 알릴 방법이 없었다.* 다음에 같은 일이 생기면 이 경로로 닿는다.
///
/// **하지 않는 것**: 자동 내려받기와 자동 설치. 무공증·무서명 배포라 성립하지
/// 않는다(Sparkle 도 서명이 전제다). 여기서는 "새 버전이 있습니다 → 페이지 열기"
/// 까지만 하고 나머지는 사람이 한다.
///
/// **보내는 것**: 인증 없는 GET 하나. 토큰도, 기기 정보도, 사용자 식별자도 싣지
/// 않는다. GitHub 서버가 알 수 있는 것은 요청이 왔다는 사실과 IP 뿐이다.
@MainActor
final class UpdateChecker: ObservableObject {

    static let shared = UpdateChecker()

    /// 마지막 확인이 무엇으로 끝났는가.
    ///
    /// `lastCheckedAt` 만으로는 부족하다. 그 값은 **실패해도** 갱신되기 때문에,
    /// 시각만 보고 "최신입니다" 라고 말하면 오프라인일 때 거짓말이 된다.
    enum CheckResult {
        /// 아직 확인한 적 없음 (자동 확인을 꺼둔 경우 포함).
        case never
        case upToDate
        case newer(ReleaseInfo)
        /// 오프라인·요청 한도 초과 등. 사용자를 붙잡지 않고 조용히 둔다.
        case failed
        /// 새 버전이 있지만 사용자가 넘어가겠다고 했다.
        case skipped
    }

    @Published private(set) var result: CheckResult = .never
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var isChecking = false

    /// 새 릴리스가 있을 때만 채워진다.
    var available: ReleaseInfo? {
        if case .newer(let release) = result { return release }
        return nil
    }

    /// 실행 중인 버전. 설정 화면에 그대로 보여준다.
    let currentVersion: String

    // `fetchLatest()` 는 메인 액터 밖에서 도므로 주소도 격리 밖에 둔다.
    nonisolated private static let endpoint = URL(string:
        "https://api.github.com/repos/KINN-CH/FaceUnlock/releases/latest")!
    nonisolated private static let releasesPage = URL(string:
        "https://github.com/KINN-CH/FaceUnlock/releases/latest")!

    /// 자동 확인 간격. 잠금 해제 도구가 하루에 한 번보다 자주 밖을 볼 이유가 없다.
    private let interval: TimeInterval = 60 * 60 * 24

    private enum Key {
        static let lastChecked = "lastUpdateCheck"
        static let skipped     = "skippedVersion"
        static let knownLatest = "lastKnownLatestVersion"
    }

    private init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0.0.0"
        let defaults = UserDefaults.standard
        lastCheckedAt = defaults.object(forKey: Key.lastChecked) as? Date

        // 지난 실행에서 알아낸 결과를 되살린다. 이게 없으면 앱을 다시 켤 때마다
        // '모름' 으로 돌아가는데, 확인은 하루 한 번뿐이라 그 상태가 하루를 간다.
        // 새 버전 알림도 재시작 한 번에 사라져 버린다.
        if lastCheckedAt != nil, let known = defaults.string(forKey: Key.knownLatest) {
            if !Self.isNewer(known, than: currentVersion) {
                result = .upToDate
            } else if defaults.string(forKey: Key.skipped) == known {
                result = .skipped
            } else {
                result = .newer(ReleaseInfo(version: known, url: Self.releasesPage))
            }
        }
    }

    // MARK: 확인

    /// 앱 시작과 하루 한 번. 설정이 꺼져 있으면 아무것도 하지 않는다.
    func checkIfDue() {
        guard Settings.shared.checkForUpdates else { return }
        // 지난 결과를 모르면 간격과 상관없이 한 번 본다. 안 그러면 이 기능이 처음
        // 들어간 버전에서 메뉴가 하루 동안 아무 말도 하지 않는다.
        if case .never = result {
            check(manual: false)
            return
        }
        if let last = lastCheckedAt, Date().timeIntervalSince(last) < interval { return }
        check(manual: false)
    }

    /// 설정 창의 '지금 확인'. 사용자가 직접 눌렀으므로 간격도 건너뛴 버전도 무시한다.
    func checkNow() {
        check(manual: true)
    }

    private func check(manual: Bool) {
        guard !isChecking else { return }
        isChecking = true

        Task {
            let latest = await Self.fetchLatest()

            isChecking = false
            lastCheckedAt = Date()
            UserDefaults.standard.set(lastCheckedAt, forKey: Key.lastChecked)

            // 실패(오프라인, 요청 한도 초과)는 조용히 넘긴다. 잠금 해제 도구가
            // 네트워크 오류 창으로 사용자를 붙잡을 이유가 없다.
            guard let latest else {
                result = .failed
                return
            }
            UserDefaults.standard.set(latest.version, forKey: Key.knownLatest)

            guard Self.isNewer(latest.version, than: currentVersion) else {
                Log.app.info("최신 버전을 쓰고 있습니다 (\(self.currentVersion, privacy: .public))")
                result = .upToDate
                return
            }

            // 사용자가 넘어가겠다고 한 버전은 다시 꺼내지 않는다.
            // 직접 확인 버튼을 눌렀을 때는 그 결정을 무시하고 보여준다.
            let skipped = UserDefaults.standard.string(forKey: Key.skipped)
            if !manual, skipped == latest.version {
                result = .skipped
                return
            }

            Log.app.info("새 버전이 있습니다: \(latest.version, privacy: .public)")
            result = .newer(latest)
        }
    }

    // MARK: 사용자 동작

    func openReleasePage() {
        NSWorkspace.shared.open(available?.url ?? Self.releasesPage)
    }

    /// 이 버전은 다시 알리지 않는다.
    func skipAvailable() {
        guard let version = available?.version else { return }
        UserDefaults.standard.set(version, forKey: Key.skipped)
        // '최신입니다' 로 바꾸지 않는다 — 넘긴 것이지 최신인 게 아니다.
        result = .skipped
    }

    // MARK: 내부

    private struct LatestResponse: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    nonisolated private static func fetchLatest() async -> ReleaseInfo? {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub API 는 User-Agent 없는 요청을 403 으로 거절한다.
        request.setValue("FaceUnlock", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                Log.app.info("업데이트 확인 실패 — HTTP \(code)")
                return nil
            }
            let decoded = try JSONDecoder().decode(LatestResponse.self, from: data)
            guard let page = URL(string: decoded.htmlURL) else { return nil }
            let version = decoded.tagName.hasPrefix("v")
                ? String(decoded.tagName.dropFirst())
                : decoded.tagName
            return ReleaseInfo(version: version, url: page)
        } catch {
            Log.app.info("업데이트 확인 실패 — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// `0.2.0` 이 `0.1.10` 보다 새것인가.
    ///
    /// 반드시 숫자로 비교해야 한다. 문자열로 비교하면 `"0.1.10" < "0.1.9"` 가 되어,
    /// 자릿수가 늘어나는 순간부터 새 버전 알림이 조용히 안 뜬다.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        // `0.2.0-beta` 같은 꼬리표는 숫자 부분까지만 읽는다.
        func parts(_ text: String) -> [Int] {
            text.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate)
        let b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
