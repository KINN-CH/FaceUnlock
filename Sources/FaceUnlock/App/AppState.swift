import AppKit
import Combine
import SwiftUI

/// 앱 전역 상태 + 각 모듈을 엮는 조정자.
@MainActor
final class AppState: ObservableObject {

    static let shared = AppState()

    enum Status: Equatable {
        case disabled           // 설정에서 꺼둠
        case needsSetup(String) // 권한/등록/모델 미비 — 사유 문자열
        case idle               // 준비 완료, 화면 잠기기를 기다리는 중
        case watching           // 잠김. 얼굴 찾는 중
        case matching           // 얼굴 일치 진행 중
        case blinkChallenge     // 얼굴 일치. 깜빡임 대기
        case unlocking          // 비밀번호 주입 중
        case failed(String)     // 이번 잠금 세션은 포기. 비밀번호로 로그인해야 함

        var menuBarSymbol: String {
            switch self {
            case .disabled:        return "faceid"
            case .needsSetup:      return "exclamationmark.triangle"
            case .idle:            return "faceid"
            case .watching:        return "eye"
            case .matching:        return "eye.fill"
            case .blinkChallenge:  return "eye.trianglebadge.exclamationmark"
            case .unlocking:       return "lock.open"
            case .failed:          return "lock.trianglebadge.exclamationmark"
            }
        }

        var label: String {
            switch self {
            case .disabled:            return "꺼짐"
            case .needsSetup(let why): return "설정 필요 — \(why)"
            case .idle:                return "대기 중"
            case .watching:            return "얼굴 찾는 중…"
            case .matching:            return "얼굴 확인 중…"
            case .blinkChallenge:      return "눈을 깜빡이세요"
            case .unlocking:           return "잠금 해제 중…"
            case .failed(let why):     return "실패 — \(why)"
            }
        }
    }

    @Published private(set) var status: Status = .disabled
    /// 마지막 인증 시도의 유사도 점수. 임계값 튜닝용으로 설정 화면에 보여준다.
    @Published private(set) var lastScore: Float?

    /// 권한 상태를 게시 속성으로 들고 있는 이유.
    ///
    /// `Permissions.hasCamera` / `hasAccessibility` 는 정적 계산 속성이라
    /// SwiftUI 가 변화를 관찰할 방법이 없다. 사용자가 시스템 설정에서 권한을 켜고
    /// 앱으로 돌아와도 화면이 그대로면 "허용했는데 왜 안 켜지지" 가 된다.
    /// 게다가 손쉬운 사용은 **시스템 설정을 떠나야** 반영되는 경우가 있어서,
    /// 창이 열려 있는 동안 주기적으로 다시 읽어야 한다.
    @Published private(set) var hasCamera = Permissions.hasCamera
    @Published private(set) var hasAccessibility = Permissions.hasAccessibility

    /// 저장된 비밀번호를 실제로 열 수 있는지. 열 수 없으면 잠금화면에서 조용히
    /// 실패하므로, 화면이 풀려 있는 지금 재등록을 안내해야 한다.
    @Published private(set) var vaultUnreadable = false

    private var permissionTimer: Timer?

    let settings = Settings.shared
    let store = FaceStore.shared
    let lockMonitor = LockMonitor()

    private let camera = CameraSession()
    private var session: AuthSession?
    private var model: EmbeddingModel?
    private var modelError: String?

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        Log.app.info("FaceUnlock 시작")

        camera.onFrame = { [weak self] buffer in
            // 카메라 큐. 여기서 메인으로 건너가면 프레임이 밀린다.
            self?.session?.process(frame: buffer)
        }
        camera.onFailure = { [weak self] reason in
            DispatchQueue.main.async { self?.abort(reason) }
        }

        lockMonitor.onLock = { [weak self] in self?.handleScreenLocked() }
        lockMonitor.onUnlock = { [weak self] in self?.handleScreenUnlocked() }
        lockMonitor.start()

        settings.$faceUnlockEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatus() }
            .store(in: &cancellables)

        refreshStatus()

        // 시작 진단. 사용자가 "왜 안 되지" 할 때 `make log` 한 줄로 답이 나와야 한다.
        // 번들 안에 모델이 들어갔는지는 조용히 실패하는 종류라 특히 명시한다.
        let ready = [
            "얼굴 잠금 해제 \(settings.faceUnlockEnabled ? "켜짐" : "꺼짐")",
            "모델 \(modelAvailable ? "있음" : "없음")",
            "얼굴 \(store.isLoaded ? (store.isEnrolled ? "등록됨" : "미등록") : "불러오는 중")",
            "비밀번호 \(Vault.hasPassword ? "등록됨" : "미등록")",
            "카메라 권한 \(Permissions.hasCamera ? "허용" : "없음")",
            "손쉬운 사용 \(Permissions.hasAccessibility ? "허용" : "없음")",
        ].joined(separator: ", ")
        Log.app.info("준비 상태 — \(ready, privacy: .public)")

        recheckVault()
    }

    /// 복호화 경로를 화면이 풀려 있는 동안 한 번 돌려본다.
    ///
    /// Keychain 확인 창은 잠금화면에서 뜨면 답할 방법이 없다. 그래서 답할 수 있는
    /// 지금 미리 뜨게 만든다. 메인에서 부르면 그 창이 앱 전체를 멈추므로
    /// 반드시 백그라운드로 보낸다.
    func recheckVault() {
        DispatchQueue.global(qos: .utility).async {
            let readable = Vault.hasPassword ? Vault.warmUp() : true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.vaultUnreadable = !readable
                if !readable {
                    Log.app.error("비밀번호 금고를 열 수 없습니다 — 설정에서 재등록이 필요합니다")
                }
                self.refreshStatus()
            }
        }
    }

    /// 설정 창이 열려 있는 동안에만 권한을 다시 읽는다.
    /// 항상 돌리면 잠들어 있어야 할 앱이 1초마다 깨어난다.
    func startPermissionPolling() {
        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in AppState.shared.pollPermissions() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
        pollPermissions()
    }

    func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    private func pollPermissions() {
        let camera = Permissions.hasCamera
        let accessibility = Permissions.hasAccessibility
        guard camera != hasCamera || accessibility != hasAccessibility else { return }

        if accessibility != hasAccessibility {
            Log.app.info("손쉬운 사용 권한 \(accessibility ? "허용됨" : "해제됨", privacy: .public)")
        }
        hasCamera = camera
        hasAccessibility = accessibility
        refreshStatus()
    }

    // MARK: 모델

    /// 첫 사용 시점에 로드한다. 앱 시작 때 로드하면 쓰지도 않을 메모리를 계속 잡는다.
    @discardableResult
    func loadModelIfNeeded() -> EmbeddingModel? {
        if let model { return model }
        do {
            let loaded = try EmbeddingModel()
            model = loaded
            modelError = nil
            return loaded
        } catch {
            modelError = error.localizedDescription
            Log.app.error("모델 로드 실패: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    var modelAvailable: Bool {
        model != nil || Bundle.main.url(forResource: "ArcFace", withExtension: "mlpackage",
                                        subdirectory: "Models") != nil
    }

    // MARK: 잠금 전이

    private func handleScreenLocked() {
        // 잠겼는데 아무 일도 안 일어나면 이유를 알 수 있어야 한다.
        // 조용히 return 하면 사용자도 나도 왜 안 되는지 알 수 없다.
        guard settings.faceUnlockEnabled else {
            Log.app.info("화면 잠김 — 얼굴 잠금 해제가 꺼져 있어 넘어감")
            return
        }
        if let blocker = setupBlocker() {
            Log.app.error("화면 잠김 — 준비 안 됨: \(blocker, privacy: .public)")
            refreshStatus()
            return
        }
        guard let profile = store.snapshot(), !profile.samples.isEmpty else {
            Log.app.error("화면 잠김 — 등록된 얼굴을 읽지 못했습니다")
            return
        }
        guard let model = loadModelIfNeeded() else {
            status = .needsSetup("얼굴 인식 모델")
            return
        }

        var config = AuthSession.Config()
        config.threshold = settings.matchThreshold
        config.requireBlink = settings.requireBlink
        config.timeout = settings.recognitionTimeout

        let session = AuthSession(profile: profile, model: model, config: config)
        session.onProgress = { [weak self] progress in self?.apply(progress) }
        session.onOutcome = { [weak self] outcome in self?.apply(outcome) }
        session.begin()
        self.session = session

        status = .watching
        camera.start()
        Log.app.info("인증 세션 시작")
    }

    private func handleScreenUnlocked() {
        endSession()
        refreshStatus()
    }

    private func endSession() {
        session?.cancel()
        session = nil
        camera.stop()
    }

    // MARK: 세션 결과

    private func apply(_ progress: AuthSession.Progress) {
        switch progress {
        case .searching:      status = .watching
        case .faceDetected(let score):
            lastScore = score
            status = .watching
        case .matching(let score):
            lastScore = score
            status = .matching
        case .blinkChallenge: status = .blinkChallenge
        case .verifying:      status = .matching
        }
    }

    private func apply(_ outcome: AuthSession.Outcome) {
        switch outcome {
        case .authenticated:
            performUnlock()
        case .timedOut:
            abort("시간 초과 — 비밀번호로 로그인하세요")
        case .cancelled:
            refreshStatus()
        case .failed(let reason):
            abort(reason)
        }
    }

    private func abort(_ reason: String) {
        Log.app.error("인증 중단: \(reason, privacy: .public)")
        endSession()
        status = .failed(reason)
    }

    // MARK: 잠금 해제

    private func performUnlock() {
        status = .unlocking
        // 카메라부터 끈다. 주입이 끝나면 화면이 열리므로 표시등을 계속 켜둘 이유가 없다.
        session = nil
        camera.stop()

        // Unlocker 는 sleep 으로 타이밍을 맞춘다. 메인 스레드에서 돌리면 UI 가 멈춘다.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Unlocker.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    self.refreshStatus()
                case .failure(let error):
                    self.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: 상태 계산

    func refreshStatus() {
        hasCamera = Permissions.hasCamera
        hasAccessibility = Permissions.hasAccessibility

        guard settings.faceUnlockEnabled else {
            status = .disabled
            return
        }
        if let blocker = setupBlocker() {
            status = .needsSetup(blocker)
            return
        }
        status = lockMonitor.isLocked ? .watching : .idle
    }

    /// 아직 채워지지 않은 선행 조건 중 첫 번째. 없으면 nil.
    func setupBlocker() -> String? {
        if !hasCamera        { return "카메라 권한" }
        if !hasAccessibility { return "손쉬운 사용 권한" }
        if !modelAvailable               { return "얼굴 인식 모델" }
        if !store.isLoaded               { return "얼굴 정보 불러오는 중" }
        if !store.isEnrolled             { return "얼굴 등록" }
        if !Vault.hasPassword            { return "비밀번호 등록" }
        if vaultUnreadable               { return "비밀번호 재등록" }
        return nil
    }
}
