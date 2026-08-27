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

    /// 저장된 비밀번호가 잠금화면에서 거부됐다. 보통 macOS 로그인 비밀번호를
    /// 바꿨는데 여기에 반영하지 않은 경우다.
    @Published private(set) var passwordRejected = false

    /// 연속 주입 실패 횟수.
    ///
    /// 재시도 루프가 생기면서 필요해졌다. 저장된 비밀번호가 낡으면 루프가
    /// **틀린 비밀번호를 무한히** 밀어 넣는다. macOS 는 오입력이 쌓이면 지연을
    /// 걸고, FileVault 환경에서는 재시작을 요구할 수 있다. 한 번의 unlock 호출은
    /// 내부 재시도까지 쳐서 최대 2회를 제출하므로, 2연속이면 4회다. 거기서 끊는다.
    private var injectionFailures = 0
    private let maxInjectionFailures = 2

    private var permissionTimer: Timer?

    /// 잠겨 있는 동안 계속 다시 시도하기 위한 타이머.
    ///
    /// 예전에는 잠금 1회당 세션 1회였다. 깜빡임을 놓치거나 얼굴을 못 찾아서
    /// 한 번 시간이 초과되면, 그 잠금이 풀릴 때까지 **다시는 시도하지 않았다.**
    /// 사용자 입장에서는 "아무리 깜빡여도 안 열린다" 로 보인다.
    private var retryTimer: Timer?
    /// 화면이 켜지는 순간을 알려주는 옵저버.
    private var wakeObserver: NSObjectProtocol?
    /// 모든 디스플레이가 꺼진 시점. 켜져 있으면 nil.
    private var displaysSleptAt: CFTimeInterval?
    /// 화면이 다 꺼진 뒤에도 계속 시도할 시간.
    ///
    /// 예전에는 120초였다. 잠금 버튼을 누르고 얼굴을 들이미는 시간을 넉넉히
    /// 덮으려는 의도였는데, 두 가지 이유로 잘못된 값이다.
    ///
    /// 1. **화면이 자는 동안에는 카메라가 어차피 프레임을 안 준다.** 잠긴 직후
    ///    0.7초만 프레임이 오고 끊기는 게 로그에 그대로 남았다. 장치를 다시
    ///    열어도 똑같다. 그 시간 동안 카메라를 켜둬봐야 배터리와 표시등만 쓴다.
    /// 2. 밤새 자리를 비운 경우와 구분되지 않는다.
    ///
    /// 그래서 짧게만 준다 — 잠김/절전 전환 중에 상태가 한두 번 튀는 걸
    /// 견디는 정도다. 화면이 다시 켜지면 [handleScreensDidWake] 가 즉시
    /// 카메라를 되살린다.
    private let graceAfterDisplaySleep: CFTimeInterval = 5
    /// 이번 시도를 시작한 시각. 카메라 감시용.
    private var attemptStartedAt: CFTimeInterval?
    /// 이 시간 동안 프레임이 한 장도 안 오면 카메라가 죽은 것으로 본다.
    private let stallLimit: CFTimeInterval = 5
    private let retryInterval: TimeInterval = 2

    let settings = Settings.shared
    let store = FaceStore.shared
    let lockMonitor = LockMonitor()

    private let camera = CameraSession.shared
    private var session: AuthSession?
    private var model: EmbeddingModel?
    private var modelError: String?

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        Log.app.info("FaceUnlock 시작")

        lockMonitor.onLock = { [weak self] in self?.handleScreenLocked() }
        lockMonitor.onUnlock = { [weak self] in self?.handleScreenUnlocked() }
        lockMonitor.start()

        // 화면이 켜지는 순간을 잡는다.
        //
        // 재시도 타이머만으로도 결국 다시 켜지지만 최대 2초가 밀린다.
        // 사용자가 키를 눌러 화면을 깨우고 카메라를 쳐다보는 그 2초는
        // "왜 안 켜지지" 로 느껴진다.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleScreensDidWake() }
            }

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
                // 비밀번호를 다시 등록했으면 거부 기록도 같이 지운다.
                self.passwordRejected = false
                self.injectionFailures = 0
                if !readable {
                    Log.app.error("비밀번호 금고를 열 수 없습니다 — 설정에서 재등록이 필요합니다")
                }
                self.refreshStatus()
                self.resumeIfLocked()
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
        // 새 잠금은 유예 시간을 새로 준다. 잠금 버튼으로 잠그면 화면이 바로
        // 꺼지는데, 직전 잠금에서 쓴 유예가 남아 있으면 안 된다.
        displaysSleptAt = nil
        startAttempt()
        startRetryLoop()
    }

    /// 화면이 켜졌다. 잠겨 있다면 곧바로 카메라를 되살린다.
    ///
    /// 화면이 자는 동안에는 카메라를 꺼두므로(배터리·표시등), 깨어난 이 시점이
    /// 얼굴 인식을 시작할 시점이다.
    private func handleScreensDidWake() {
        displaysSleptAt = nil
        guard settings.faceUnlockEnabled, session == nil else { return }
        guard lockMonitor.isLocked || LockMonitor.screenIsLockedNow() else { return }
        guard setupBlocker() == nil else { return }
        Log.app.info("화면이 켜짐 — 인증 세션을 시작합니다")
        startAttempt()
        startRetryLoop()
    }

    // MARK: 재시도 루프

    /// 잠겨 있는 한 계속 다시 시도한다.
    ///
    /// 화면이 완전히 꺼진 채로 오래 지나면 멈춘다 — 밤새 카메라를 돌리며
    /// 배터리를 먹고 렌즈 옆 표시등을 켜둘 이유가 없다. 다만 "꺼졌다" 를
    /// 곧바로 "아무도 없다" 로 읽으면 안 된다. 자세한 이유는
    /// [peopleMightBeHere] 참조.
    private func startRetryLoop() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.retryTick() }
        }
    }

    private func stopRetryLoop() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func retryTick() {
        guard lockMonitor.isLocked || LockMonitor.screenIsLockedNow() else {
            stopRetryLoop()
            return
        }
        guard settings.faceUnlockEnabled else {
            stopRetryLoop()
            return
        }

        // 사람이 없을 법한 상태가 충분히 이어졌으면 접고 기다린다.
        guard peopleMightBeHere() else {
            if session != nil {
                Log.app.info("디스플레이가 꺼진 채 오래 지남 — 시도를 접고 대기")
                endSession()
                refreshStatus()
            }
            return
        }

        // 주입이 진행 중이면 절대 건드리지 않는다. performUnlock 은 세션을 먼저
        // 비우므로 여기서 session == nil 만 보면 통과해버리고, 카메라가 다시
        // 켜지면서 **두 번째 주입**까지 나간다.
        if case .unlocking = status { return }

        // 카메라만 죽고 세션은 살아 있는 상태를 걷어낸다.
        //
        // AuthSession 의 제한시간은 **프레임이 들어와야** 확인된다. 프레임이 한
        // 장도 안 오면 시간 초과조차 나지 않고, 세션은 nil 이 되지 않으며,
        // 아래 `session == nil` 가드에 계속 걸려서 잠금이 풀릴 때까지 그대로
        // 멈춰 있는다. 표시등도 안 켜진다 — "가끔 카메라가 안 뜬다" 가 이것이다.
        if session != nil, cameraLooksStalled() {
            Log.app.error("카메라에서 프레임이 오지 않습니다 — 인증 세션을 새로 시작합니다")
            // 카메라는 건드리지 않는다. 죽었다면 CameraSession 이 스스로
            // 장치를 다시 열고 있고, 여기서 또 껐다 켜면 그 복구를 방해한다.
            endSession(releaseCamera: false)
            refreshStatus()
            return
        }

        guard session == nil else { return }   // 이미 시도 중
        // 준비가 안 됐으면 조용히 넘긴다. startAttempt 를 부르면 2초마다
        // 같은 오류가 로그를 채운다.
        guard setupBlocker() == nil else { return }

        startAttempt()
    }

    /// 지금 카메라 앞에 사람이 있을 가능성이 있는가.
    ///
    /// 이전에는 `CGDisplayIsAsleep(CGMainDisplayID())` 하나만 봤는데, 그게
    /// 두 가지를 다 틀렸다.
    ///
    /// 1. **메인 디스플레이 하나만** 봤다. 외장 모니터를 쓰면 잠글 때 그쪽이
    ///    먼저 대기 상태로 들어가고 내장 화면은 아직 켜져 있다. 실제로 잠근 지
    ///    6초 만에 "디스플레이 꺼짐" 으로 세션을 죽인 로그가 남았다 —
    ///    사용자는 그 앞에 앉아 있었다.
    /// 2. **잠금 버튼 직후를 못 쓰게 만들었다.** 잠금 버튼은 잠금과 동시에
    ///    화면을 끈다. 그 순간이 바로 사용자가 얼굴을 들이미는 때인데,
    ///    화면이 꺼졌다는 이유로 시도를 안 했다.
    ///
    /// 그래서 (a) 켜진 화면이 **하나라도** 있으면 사람이 있다고 보고,
    /// (b) 전부 꺼졌더라도 꺼진 직후 [graceAfterDisplaySleep] 동안은 계속
    /// 시도한다. 유예는 전환 중에 상태가 튀는 걸 견디는 용도지, 꺼진 화면
    /// 앞에서 얼굴을 기다리는 용도가 아니다 — 그건 어차피 안 된다.
    private func peopleMightBeHere() -> Bool {
        if anyDisplayAwake() {
            displaysSleptAt = nil
            return true
        }
        let now = CACurrentMediaTime()
        let since = displaysSleptAt ?? now
        displaysSleptAt = since
        return now - since < graceAfterDisplaySleep
    }

    /// 카메라가 켜져 있다고 해놓고 실제로는 프레임을 못 주고 있는가.
    private func cameraLooksStalled() -> Bool {
        guard let started = attemptStartedAt else { return false }
        let now = CACurrentMediaTime()
        // 시작 직후에는 장치가 준비될 시간을 준다. 여기서 성급하게 끊으면
        // 세션을 계속 새로 만들면서 오히려 카메라를 못 잡는다.
        guard now - started > stallLimit else { return false }
        guard let idle = camera.secondsSinceLastFrame else { return true }
        return idle > stallLimit
    }

    private func anyDisplayAwake() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            // 목록을 못 얻었다. 여기서 "꺼졌다" 로 넘어가면 얼굴 인식이 통째로
            // 멈추므로, 판단 불가는 켜져 있는 쪽으로 센다.
            return true
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return true }
        return ids.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 }
    }

    /// 인증 시도 1회. 실패해도 여기서는 아무것도 되돌리지 않는다 —
    /// 재시도는 [startRetryLoop] 가 맡는다.
    private func startAttempt() {
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
        attemptStartedAt = CACurrentMediaTime()
        camera.start(owner: self,
                     onFrame: { [weak self] buffer in
                         // 카메라 큐. 여기서 메인으로 건너가면 프레임이 밀린다.
                         self?.session?.process(frame: buffer)
                     },
                     onFailure: { [weak self] reason in
                         DispatchQueue.main.async { self?.abort(reason) }
                     })
        Log.app.info("인증 세션 시작")
    }

    /// 잠긴 상태에서 준비가 **뒤늦게** 끝났을 때 세션을 다시 시작한다.
    ///
    /// 앱이 잠금화면에서 실행되면(재부팅·재시작 직후) 등록 얼굴 복호화가
    /// 잠김 처리보다 늦게 끝난다. 그때 한 번 걸러진 뒤 재시도가 없으면
    /// 그 잠금 세션 동안은 얼굴로 열리지 않는다.
    func resumeIfLocked() {
        guard session == nil, LockMonitor.screenIsLockedNow() else { return }
        guard setupBlocker() == nil else { return }
        Log.app.info("준비 완료 — 잠긴 상태라 인증 세션을 다시 시작합니다")
        handleScreenLocked()
    }

    private func handleScreenUnlocked() {
        stopRetryLoop()
        endSession()
        refreshStatus()
    }

    /// 인증 시도를 끝낸다.
    ///
    /// `releaseCamera` 를 끄면 장치는 계속 돌아간다. 잠긴 동안 2초마다 시도를
    /// 반복하는데 그때마다 카메라를 껐다 켜면, 장치가 그 짧은 껐다 켜기를
    /// 견디지 못하고 "돌긴 하는데 프레임이 안 오는" 상태로 빠진다 —
    /// 검은 화면의 원인이었다. 다음 시도가 곧바로 이어질 상황이면 켜둔다.
    private func endSession(releaseCamera: Bool = true) {
        session?.cancel()
        session = nil
        attemptStartedAt = nil
        if releaseCamera { camera.stop(owner: self) }
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
        // 아직 잠겨 있으면 2초 뒤에 또 시도한다. 그 사이 카메라를 껐다 켜봐야
        // 장치만 흔들린다. 화면이 풀리거나 사람이 없다고 판단되면 그때 끈다.
        let stillLocked = lockMonitor.isLocked || LockMonitor.screenIsLockedNow()
        endSession(releaseCamera: !stillLocked)
        status = .failed(reason)
    }

    // MARK: 잠금 해제

    private func performUnlock() {
        status = .unlocking
        // 카메라부터 끈다. 주입이 끝나면 화면이 열리므로 표시등을 계속 켜둘 이유가 없다.
        session = nil
        camera.stop(owner: self)

        // Unlocker 는 sleep 으로 타이밍을 맞춘다. 메인 스레드에서 돌리면 UI 가 멈춘다.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Unlocker.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    self.injectionFailures = 0
                    self.refreshStatus()

                case .failure(.stillLocked):
                    // 비밀번호를 실제로 제출했는데 안 열렸다 = 틀렸다는 뜻이다.
                    // 이것만 센다. 다른 실패는 제출 자체가 없었으므로 무해하다.
                    self.injectionFailures += 1
                    if self.injectionFailures >= self.maxInjectionFailures {
                        self.passwordRejected = true
                        self.stopRetryLoop()
                        self.endSession()
                        Log.app.error("저장된 비밀번호가 연속 거부됨 — 자동 해제를 중단합니다")
                        self.status = .needsSetup("비밀번호 재등록")
                    } else {
                        self.status = .failed(Unlocker.Failure.stillLocked.localizedDescription)
                    }

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
        if passwordRejected              { return "비밀번호 재등록" }
        return nil
    }
}
