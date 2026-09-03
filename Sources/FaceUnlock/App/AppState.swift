import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// 앱 전역 상태 + 각 모듈을 엮는 조정자.
@MainActor
final class AppState: ObservableObject {

    static let shared = AppState()

    /// 아직 채워지지 않은 선행 조건. 문자열 비교로 분기하지 않도록 형으로 둔다.
    enum SetupBlocker: Equatable {
        case cameraPermission
        case accessibilityPermission
        case model
        case loadingFaces
        case enrollment
        case password
        case passwordReenroll

        var label: String {
            switch self {
            case .cameraPermission:        return T("카메라 권한", "camera permission")
            case .accessibilityPermission: return T("손쉬운 사용 권한", "accessibility permission")
            case .model:                   return T("얼굴 인식 모델", "recognition model")
            case .loadingFaces:            return T("얼굴 정보 불러오는 중", "loading enrolled faces")
            case .enrollment:              return T("얼굴 등록", "face enrollment")
            case .password:                return T("비밀번호 등록", "password setup")
            case .passwordReenroll:        return T("비밀번호 재등록", "password re-entry")
            }
        }
    }

    enum Status: Equatable {
        case disabled                 // 설정에서 꺼둠
        case needsSetup(SetupBlocker) // 권한/등록/모델 미비
        case idle                     // 준비 완료, 화면 잠기기를 기다리는 중
        case watching                 // 잠김. 얼굴 찾는 중
        case matching                 // 얼굴 일치 진행 중
        case blinkChallenge           // 얼굴 일치. 깜빡임 대기
        case unlocking                // 비밀번호 주입 중
        case failed(String)           // 이번 잠금 세션은 포기. 비밀번호로 로그인해야 함

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
            case .disabled:            return T("꺼짐", "Off")
            case .needsSetup(let why): return T("설정 필요 — \(why.label)", "Setup needed — \(why.label)")
            case .idle:                return T("대기 중", "Standing by")
            case .watching:            return T("얼굴 찾는 중…", "Looking for a face…")
            case .matching:            return T("얼굴 확인 중…", "Verifying face…")
            case .blinkChallenge:      return T("눈을 깜빡이세요", "Blink now")
            case .unlocking:           return T("잠금 해제 중…", "Unlocking…")
            case .failed(let why):     return T("실패 — \(why)", "Failed — \(why)")
            }
        }
    }

    @Published private(set) var status: Status = .disabled

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

    // MARK: 인식 창(window)

    /// 이 앱이 일해야 하는 유일한 순간은 **잠긴 상태에서 화면이 켜지는 그때**다.
    ///
    /// 예전에는 "잠겨 있고 화면이 켜져 **있는가**" 라는 *상태* 로 판단했다.
    /// 그래서 조건이 유지되는 내내 카메라가 돌았다 — 무언가가 화면을 붙잡고
    /// 있으면(크롬의 "Video Wake Lock" 처럼) 그 몇 분 동안 계속. 실제 전원
    /// 로그에 4분 39초짜리 붙잡기가 남아 있다.
    ///
    /// 지금은 "화면이 켜**졌는가**" 라는 *사건* 으로 판단한다. 사건이 오면 창을
    /// 열고, 성공·실패·시간초과·화면 꺼짐 중 하나가 오면 닫는다.
    /// **창 밖에서는 카메라도 타이머도 예열도 전부 0이다.**
    ///
    /// 화면이 꺼진 동안 아무것도 안 돌려도 잃는 게 없다 — 화면이 자면 카메라도
    /// 같이 자서 프레임이 아예 안 온다([AwakeWindow] 에 실측이 있다).
    /// 원래부터 아무 일도 할 수 없는 구간이다.
    ///
    /// 창이 닫힐 시각. nil 이면 창이 닫혀 있다는 뜻이다.
    private var windowDeadline: CFTimeInterval?
    /// 창이 열려 있는 **동안에만** 도는 타이머. 카메라가 죽었는지 살피고,
    /// 준비가 늦게 끝났거나 주입이 한 번 빗나간 경우 세션을 다시 세운다.
    private var retryTimer: Timer?
    private let retryInterval: TimeInterval = 2
    /// 인식 제한시간 뒤로 더 주는 여유.
    ///
    /// [AuthSession] 의 제한시간은 **프레임이 들어와야** 확인된다. 카메라가
    /// 한 장도 못 주면 시간 초과조차 나지 않으므로, 창을 닫는 마지막
    /// 안전장치가 필요하다.
    private let windowGrace: TimeInterval = 10
    /// 사용자가 **직접 잠갔을 때** 곧바로 창을 열 것인가.
    ///
    /// 기본은 false — 직접 잠근 데는 이유가 있다. [handleScreenLocked] 참조.
    private let opensWindowOnManualLock = false

    /// 화면이 켜지는 순간.
    private var wakeObserver: NSObjectProtocol?
    /// 시스템 절전에서 깨어나는 순간.
    ///
    /// 덮개를 열 때 이 알림과 `screensDidWake` 중 어느 쪽이 먼저 올지는
    /// 상황마다 다르다. 이제 창을 여는 길이 사건뿐이라 하나만 듣다가 놓치면
    /// 그 잠금 동안 얼굴 인식이 통째로 죽는다. 그래서 양쪽을 다 듣는다.
    private var systemWakeObserver: NSObjectProtocol?
    /// 화면이 꺼지는 순간 — 창을 닫는 신호.
    /// 예전에는 이 알림을 안 듣고 2초마다 디스플레이 상태를 물어봤다.
    private var sleepObserver: NSObjectProtocol?
    private var systemSleepObserver: NSObjectProtocol?
    /// 예열을 끊는 타이머. [primeLimit] 참조.
    private var primeTimer: Timer?

    /// 이번 시도를 시작한 시각. 카메라 감시용.
    private var attemptStartedAt: CFTimeInterval?
    /// 이 시간 동안 프레임이 한 장도 안 오면 카메라가 죽은 것으로 본다.
    private let stallLimit: CFTimeInterval = 5

    /// 모델을 백그라운드에서 올리는 중인가. 앱 시작과 설정 구독 양쪽에서
    /// 불리므로, 막지 않으면 `.mlpackage` 를 두 번 올린다.
    private var preloadingModel = false
    /// 인증하는 동안 App Nap 을 막는 표. 자세한 이유는 [startAttempt].
    private var authActivity: NSObjectProtocol?

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

        // 창을 여닫는 세 가지 사건. 이제 이것 말고는 카메라를 켜는 길이 없다.
        let center = NSWorkspace.shared.notificationCenter
        wakeObserver = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWakeEvent("화면이 켜짐") }
            }
        systemWakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWakeEvent("절전에서 깨어남") }
            }
        sleepObserver = center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleScreensSlept() }
            }
        systemSleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleSystemWillSleep() }
            }

        settings.$faceUnlockEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatus()
                self?.preloadPipelineIfEnabled()
                self?.registerLoginItemOnce()
            }
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
            "자동 실행 \(SMAppService.mainApp.status == .enabled ? "등록됨" : "안 됨")",
        ].joined(separator: ", ")
        Log.app.info("준비 상태 — \(ready, privacy: .public)")

        recheckVault()
        preloadPipelineIfEnabled()

        // 새 버전 확인은 시작하고 조금 뒤에. 시작 경로에는 이미 모델 프리로드와
        // 키체인 확인이 몰려 있고, 이건 그 무엇보다 급하지 않다.
        Task {
            try? await Task.sleep(for: .seconds(3))
            UpdateChecker.shared.checkIfDue()
        }
    }

    // MARK: 모델 예열

    /// 모델을 앱 시작 때 **한 번만** 백그라운드에서 올린다.
    ///
    /// 예전에는 여기에 60초짜리 반복 타이머가 있었다. 뉴럴 엔진이 놀고 있는
    /// 모델을 메모리에서 쫓아내서, 오래 안 쓰면 첫 추론이 6.3초까지 걸렸기
    /// 때문이다(두 번째는 0.69초). 잠기지 않은 시간 내내 1분마다 앱을 깨우는
    /// 대가로 그 6.3초를 피한 셈이다.
    ///
    /// 지금은 [EmbeddingModel] 이 뉴럴 엔진을 쓰지 않는다. 쫓겨날 일이 없으니
    /// 다시 데울 일도 없다 — 그래서 타이머를 통째로 지웠다. 자세한 측정은
    /// [EmbeddingModel] 의 주석에 있다.
    /// 얼굴 잠금 해제를 **처음 켤 때** 로그인 항목으로 한 번 등록한다.
    ///
    /// 이 앱은 떠 있지 않으면 아무 일도 하지 않는다. 맥을 재시동하면 그 뒤로는
    /// 얼굴로 열리지 않는데, 원인이 "앱이 안 떠 있어서" 라는 걸 알아채기가
    /// 어렵다 — 설정은 그대로 켜져 있고 등록한 얼굴도 그대로이기 때문이다.
    ///
    /// 그렇다고 설치만 해보고 둘러본 사람의 로그인 항목까지 건드릴 이유는
    /// 없으므로, 기능을 **실제로 켠 순간**에 맞춘다.
    ///
    /// 딱 한 번만 한다. 그 뒤로는 설정창의 토글이 주인이다 — 사용자가 꺼둔 걸
    /// 다음 실행에서 되살리면 그건 고장이지 편의가 아니다.
    private func registerLoginItemOnce() {
        let key = "didRegisterLoginItem"
        guard settings.faceUnlockEnabled,
              !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            Log.app.info("로그인 시 자동 실행으로 등록했습니다")
        } catch {
            // 실패해도 앱은 그대로 돌아간다. 설정창 토글로 다시 시도할 수 있다.
            Log.app.error("로그인 항목 등록 실패: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func preloadPipelineIfEnabled() {
        guard settings.faceUnlockEnabled else { return }
        preloadPipeline()
    }

    /// 모델을 백그라운드에서 올린 뒤 한 번 돌려본다.
    ///
    /// `EmbeddingModel()` 은 컴파일본이 낡았으면 `.mlpackage` 를 다시
    /// 컴파일하느라 3초쯤 걸린다. 이걸 **첫 잠금 때 메인 스레드에서** 치르면
    /// 하필 사용자가 카메라 앞에서 기다리는 그 순간에 앱이 멈춘다.
    private func preloadPipeline() {
        if let model {
            Warmup.run(model: model)
            return
        }
        guard !preloadingModel else { return }
        preloadingModel = true
        DispatchQueue.global(qos: .utility).async {
            let loaded = try? EmbeddingModel()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.preloadingModel = false
                if let loaded, self.model == nil {
                    self.model = loaded
                    self.modelError = nil
                }
                Warmup.run(model: self.model)
            }
        }
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
        // 로드와 같은 탐색 규칙을 쓴다 — 번들 외에 DMG 사이드로드 경로도 포함.
        model != nil || EmbeddingModel.locateModel() != nil
    }

    // MARK: 잠금 전이

    /// 잠금이 걸렸다.
    ///
    /// **여기서는 카메라를 켜지 않는다.** 사용자가 직접 잠갔다면 이유가 있어서
    /// 잠근 것이다. 그런데 예전 코드는 잠기자마자 인식을 시작했고, 재시도
    /// 쿨다운도 없었다. 깜빡임 확인이 꺼진 기본 설정에서는 잠금 버튼을 누른
    /// 채 화면을 계속 보고 있으면 **1초쯤 뒤에 도로 풀렸다.** 잠금이 잠금
    /// 구실을 못 한 셈이다.
    ///
    /// 잠긴 뒤 macOS 는 5~6초 안에 화면을 끄므로(실측은 [AwakeWindow] 참조),
    /// 다시 쓰려고 키를 누르거나 트랙패드를 만지면 그때 화면이 켜지고
    /// [handleWakeEvent] 가 창을 연다. 즉 아무것도 잃지 않고 몇 초만 늦어진다.
    ///
    /// 잠그자마자 바로 얼굴로 풀고 싶다면 [opensWindowOnManualLock] 를 true 로
    /// 바꾸면 예전 동작으로 돌아간다.
    private func handleScreenLocked() {
        guard settings.faceUnlockEnabled else { return }
        guard opensWindowOnManualLock else {
            Log.app.info("잠김 — 화면이 다시 켜지면 인식을 시작합니다")
            // 인식은 화면이 켜질 때 하더라도 **장치는 지금 연다.** 이유는
            // [primeCamera] 에 적어두었다.
            primeCamera()
            return
        }
        guard anyDisplayAwake() else {
            Log.app.info("화면이 꺼진 채 잠김 — 화면이 켜지면 시작합니다")
            return
        }
        openWindow("잠김")
    }

    /// 화면이 켜졌거나 시스템이 절전에서 깨어났다 — 창을 열 유일한 사건.
    ///
    /// 두 알림을 모두 듣는다. 덮개를 열거나 시스템 절전에서 복귀할 때는
    /// `screensDidWake` 가 안 오고 `didWake` 만 오는 경우가 있고, 반대로 화면만
    /// 껐다 켜면 `didWake` 는 안 온다. 하나를 놓치면 그 상황에서 얼굴 인식이
    /// 통째로 죽으므로 둘 다 듣고, 창 쪽에서 중복을 걸러낸다.
    private func handleWakeEvent(_ reason: String) {
        guard settings.faceUnlockEnabled else { return }
        guard lockMonitor.isLocked || LockMonitor.screenIsLockedNow() else { return }
        // 주입이 진행 중이면 끼어들지 않는다. `performUnlock` 이 세션을 먼저
        // 비우기 때문에 `session == nil` 만 봐서는 통과해버린다. 게다가 주입
        // 전에 부르는 `caffeinate` 가 바로 이 알림을 일으키므로, 막지 않으면
        // **자기가 깨운 화면 때문에 두 번째 인증**이 시작된다.
        if case .unlocking = status { return }
        guard setupBlocker() == nil else { return }
        openWindow(reason)
    }

    // MARK: 창 여닫기

    /// 인식 창을 연다. 이미 열려 있으면 시한만 미룬다.
    ///
    /// 창이 열려 있는 동안에만 카메라와 재시도 타이머가 돈다.
    private func openWindow(_ reason: String) {
        let alreadyOpen = windowDeadline != nil
        windowDeadline = CACurrentMediaTime() + settings.recognitionTimeout + windowGrace

        // 잠금화면은 금방 다시 화면을 재운다. 인식하는 중에 꺼지면 카메라도
        // 같이 자므로 인식하는 동안은 화면을 붙잡아 둔다.
        //
        // 붙잡는 시간은 **인식 제한시간까지만**이다. 창의 시한에는 여유
        // 10초가 더 붙어 있지만, 그 여유는 프레임이 한 장도 안 올 때 창을
        // 닫으려고 둔 것이다 — 프레임이 안 오는 동안 화면을 켜둘 이유는 없다.
        // 인식이 끝나거나 실패하면 [closeWindow] 가 시한 전에 놓는다.
        // 진단 모드에서는 60초 관찰이 끝날 때까지 화면을 붙잡는다. 중간에
        // 화면이 꺼지면 카메라도 자면서 재려던 것이 사라진다.
        AwakeWindow.hold(for: CameraSession.diagnostics ? 90 : settings.recognitionTimeout)

        guard !alreadyOpen else { return }
        Log.app.info("인식 창 열림 — \(reason, privacy: .public)")

        // 카메라 첫 프레임까지 약 1초가 걸린다. 그동안 잠금화면은 시계만
        // 보여주므로 사용자 눈에는 아무 일도 일어나지 않는 것처럼 보인다.
        // 비밀번호 칸을 지금 띄워두면 그 1초가 "반응 없는 화면" 이 아니게 된다.
        // 키 이벤트에는 짧은 sleep 이 들어 있어 메인 스레드에서 부르지 않는다.
        DispatchQueue.global(qos: .userInitiated).async { Unlocker.summonPasswordField() }

        startAttempt()
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.retryTick() }
        }
    }

    /// 인식 창을 닫고 카메라·타이머·화면 붙잡기를 전부 놓는다.
    ///
    /// 창 밖에서 이 앱이 쓰는 자원은 0이어야 한다. 여러 경로(성공·실패·화면
    /// 꺼짐·잠금 해제)에서 불리므로 이미 닫혀 있으면 조용히 넘어간다.
    private func closeWindow(_ reason: String) {
        guard windowDeadline != nil else { return }
        windowDeadline = nil
        retryTimer?.invalidate()
        retryTimer = nil
        endSession(releaseCamera: true)
        // 진단 중에는 놓지 않는다. 인증은 20초에 시간 초과로 끝나지만
        // 관찰은 60초까지 이어져야 하고, 시한이 알아서 놓아준다.
        if !CameraSession.diagnostics { AwakeWindow.release() }
        Log.app.info("인식 창 닫힘 — \(reason, privacy: .public)")
        refreshStatus()
    }

    /// 창이 열려 있는 동안 2초마다. 창을 닫을 이유가 있는지 보고, 없으면
    /// 끊긴 세션을 다시 세운다.
    private func retryTick() {
        guard lockMonitor.isLocked || LockMonitor.screenIsLockedNow() else {
            closeWindow("잠금이 풀림")
            return
        }
        guard settings.faceUnlockEnabled else {
            closeWindow("기능이 꺼짐")
            return
        }
        // 화면이 꺼졌다면 카메라도 잔다 — 프레임이 안 오니 계속 켜둘 이유가 없다.
        // `screensDidSleep` 알림이 정상 경로지만, 놓쳤을 때를 대비한 확인이다.
        guard anyDisplayAwake() else {
            closeWindow("화면이 꺼짐")
            return
        }
        // 마지막 안전장치. 프레임이 한 장도 안 오면 [AuthSession] 의 제한시간이
        // 확인되지 않아 시간 초과조차 나지 않는다.
        if let deadline = windowDeadline, CACurrentMediaTime() > deadline {
            closeWindow("시간 초과")
            return
        }

        // 주입이 진행 중이면 절대 건드리지 않는다. performUnlock 은 세션을 먼저
        // 비우므로 여기서 session == nil 만 보면 통과해버리고, 카메라가 다시
        // 켜지면서 **두 번째 주입**까지 나간다.
        if case .unlocking = status { return }

        // 카메라만 죽고 세션은 살아 있는 상태를 걷어낸다.
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

    /// 켜져 있는 디스플레이가 하나라도 있는가.
    ///
    /// 메인 디스플레이만 보면 안 된다. 외장 모니터를 쓰면 잠글 때 그쪽이 먼저
    /// 대기로 들어가고 내장 화면은 아직 켜져 있다. 실제로 잠근 지 6초 만에
    /// "디스플레이 꺼짐" 으로 세션을 죽인 로그가 남았다 — 사용자는 그 앞에
    /// 앉아 있었다.
    private func anyDisplayAwake() -> Bool {
        var count: UInt32 = 0
        // 호출 실패와 "켜진 화면 0개" 를 나눈다 — [CameraSession.anyDisplayAwake] 참조.
        // 목록을 못 얻은 것은 판단 불가라 켜진 쪽으로 세지만, 목록이 비었다는 건
        // 켜진 화면이 없다는 **답** 이다. 덮개를 닫으면 실제로 0 이 나온다.
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return true }
        guard count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return true }
        return ids.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 }
    }

    /// 인증 시도 1회. 실패해도 여기서는 아무것도 되돌리지 않는다 —
    /// 창이 열려 있는 동안의 재시도는 [retryTick] 이 맡는다.
    private func startAttempt() {
        // 잠겼는데 아무 일도 안 일어나면 이유를 알 수 있어야 한다.
        // 조용히 return 하면 사용자도 나도 왜 안 되는지 알 수 없다.
        guard settings.faceUnlockEnabled else {
            Log.app.info("화면 잠김 — 얼굴 잠금 해제가 꺼져 있어 넘어감")
            return
        }
        if let blocker = setupBlocker() {
            Log.app.error("화면 잠김 — 준비 안 됨: \(blocker.label, privacy: .public)")
            refreshStatus()
            return
        }
        guard let roster = store.snapshot(), !roster.isEmpty else {
            Log.app.error("화면 잠김 — 등록된 얼굴을 읽지 못했습니다")
            return
        }
        guard let model = loadModelIfNeeded() else {
            status = .needsSetup(.model)
            return
        }

        var config = AuthSession.Config()
        config.threshold = settings.matchThreshold
        config.requireBlink = settings.requireBlink
        config.timeout = settings.recognitionTimeout

        let session = AuthSession(roster: roster, model: model, config: config)
        session.onProgress = { [weak self] progress in self?.apply(progress) }
        session.onOutcome = { [weak self] outcome in self?.apply(outcome) }
        session.begin()
        self.session = session

        status = .watching
        attemptStartedAt = CACurrentMediaTime()

        // App Nap 을 끈다.
        //
        // 잠금화면에서 우리는 창 하나 없는 백그라운드 앱이다 — macOS 가
        // 절전 대상으로 삼기 딱 좋은 조건이라, 타이머가 뭉치고 QoS 가 내려간다.
        // 인증은 사용자가 눈앞에서 기다리는 작업이므로 그동안만 예외로 둔다.
        // 시스템 절전 자체는 막지 않는다(`AllowingIdleSystemSleep`) — 자리를
        // 비운 맥까지 깨워둘 이유는 없다.
        if authActivity == nil {
            authActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Face unlock authentication")
        }

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
        // 화면이 꺼져 있으면 켜질 때 [handleWakeEvent] 가 연다.
        guard anyDisplayAwake() else { return }
        Log.app.info("준비 완료 — 잠긴 상태라 인증 세션을 다시 시작합니다")
        openWindow("준비 완료")
    }

    /// 화면이 꺼졌다 — 창을 닫고 **장치도 놓는다.** 목표 동작이 이것이다.
    ///
    /// 화면이 꺼져 있는 동안 카메라가 돌면 안 되고, 표시등도 꺼져야 한다.
    /// 여기서 놓아도 다음 시동이 되는 이유는 [primeCamera] 에 적어두었다.
    private func handleScreensSlept() {
        closeWindow("화면이 꺼짐")
        primeTimer?.invalidate()
        primeTimer = nil
        camera.stop(owner: self)
        Log.app.info("화면이 꺼져 카메라를 놓습니다")
    }

    /// 시스템이 잔다 (덮개를 닫았거나 절전에 들어간다) — 장치를 놓는다.
    ///
    /// 맥북을 덮어 들고 나가는 경우가 정확히 이것이다. 여기서는 놓아도
    /// 안전하다. 덮개를 열면 시스템이 통째로 깨면서 카메라도 재초기화되고,
    /// 그때의 냉시동은 실제로 성공한다(16:16:16 — 얼굴 일치 → 잠금 해제).
    private func handleSystemWillSleep() {
        closeWindow("시스템 절전")
        primeTimer?.invalidate()
        primeTimer = nil
        camera.stop(owner: self)
        Log.app.info("시스템이 자므로 카메라를 놓습니다")
    }

    private func handleScreenUnlocked() {
        closeWindow("잠금이 풀림")
        primeTimer?.invalidate()
        primeTimer = nil
        // 창이 열린 적 없이 [primeCamera] 만 돌고 있었다면 `closeWindow` 가
        // 곧바로 되돌아간다(`windowDeadline == nil`). 그 경우까지 확실히
        // 놓아야 표시등이 켜진 채로 남지 않는다.
        camera.stop(owner: self)
        refreshStatus()
    }

    /// 잠기는 **순간** 장치를 몇 초 돌려놓는다(예열). 인식은 하지 않고
    /// 프레임은 버린다. 화면이 꺼지면 [handleScreensSlept] 가 곧 놓는다.
    ///
    /// **왜 필요한가.** 화면만 껐다 켠 직후의 냉시동은 프레임을 초당 13장
    /// 정상 속도로 내놓으면서 전 픽셀이 0이다. 5회 시도 전부 그랬다
    /// (15:40, 15:41, 16:21, 16:37, 16:38). 장치를 통째로 다시 열어도,
    /// 포맷을 시스템 기본값(1920×1080 @30fps)으로 되돌려도 같았다.
    ///
    /// 그런데 **잠길 때 한 번 스트리밍해두면**, 같은 잠금 세션 안에서는
    /// 껐다 켜도 정상으로 나온다(17:30, 17:33 — 둘 다 얼굴 일치 → 해제).
    /// 예열 없이 같은 절차를 밟은 5회는 전부 검은 프레임이었다. 이 둘의
    /// 차이는 잠금 직후의 5초짜리 스트리밍 하나뿐이다.
    ///
    /// 그래서 표시등은 잠긴 직후 몇 초만 켜졌다 꺼지고, 화면이 꺼져 있는
    /// 동안에는 꺼져 있으며, 맥도 평소대로 절전에 들어간다
    /// (돌아가는 캡처 세션은 시스템 유휴 절전을 막는다 — 실측 12분).
    /// 예열을 끊는 상한. 보통은 이 시간 전에 화면이 꺼지면서 놓는다.
    ///
    /// 잠근 뒤 화면이 꺼지기까지 실측 5~6초라 이 값에 닿는 일은 드물다.
    /// 잠근 채 마우스를 계속 만져 화면이 안 꺼지는 경우를 위한 안전장치다.
    private let primeLimit: TimeInterval = 30

    private func primeCamera() {
        // 권한이나 등록이 안 끝났으면 어차피 인식을 못 한다. 표시등만 켜는
        // 꼴이 되므로 그때는 열지 않는다.
        guard setupBlocker() == nil else { return }
        // 화면이 **이미** 꺼져 있으면 열지 않는다. 예열은 화면이 켜지기 전에
        // 장치를 데워두려는 것인데, 꺼진 뒤에 열면 프레임이 한 장도 오지 않는
        // 채로 장치만 붙잡고 있게 된다. 그 상태로 시스템이 자면 세션이 상해서
        // 깨어난 뒤 감시견이 알아채고 장치를 다시 여는 데 800ms 가 더 든다 —
        // 예열이 오히려 느리게 만든다. 실측 로그가 그대로 보여준다:
        //   17:49:45.067 화면이 꺼져 카메라를 놓습니다
        //   17:49:45.228 잠김 → 카메라를 잠깐 열어 예열합니다   ← 여기서 다시 염
        //   (39초 절전)
        //   17:50:24.722 첫 프레임이 오지 않습니다 — 장치를 다시 엽니다
        // 화면이 켜지면 어차피 인식 창이 열리면서 장치를 연다.
        guard anyDisplayAwake() else {
            Log.app.info("화면이 이미 꺼져 있어 예열을 건너뜁니다")
            return
        }
        Log.app.info("카메라를 잠깐 열어 예열합니다")
        primeTimer?.invalidate()
        primeTimer = Timer.scheduledTimer(withTimeInterval: primeLimit,
                                          repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endPrime() }
        }
        camera.start(owner: self,
                     onFrame: { _ in },
                     onFailure: { reason in
                         Log.camera.error("미리 열기 실패: \(reason, privacy: .public)")
                     })
    }

    /// 예열 상한에 닿았다. 인증 중이면 건드리지 않는다.
    private func endPrime() {
        primeTimer?.invalidate()
        primeTimer = nil
        guard session == nil, windowDeadline == nil else { return }
        Log.app.info("예열을 마치고 카메라를 놓습니다")
        camera.stop(owner: self)
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
        if let authActivity {
            ProcessInfo.processInfo.endActivity(authActivity)
            self.authActivity = nil
        }
        if releaseCamera { camera.stop(owner: self) }
    }

    // MARK: 세션 결과

    private func apply(_ progress: AuthSession.Progress) {
        switch progress {
        case .searching:      status = .watching
        case .faceDetected:   status = .watching
        case .matching:       status = .matching
        case .blinkChallenge: status = .blinkChallenge
        case .verifying:      status = .matching
        }
    }

    private func apply(_ outcome: AuthSession.Outcome) {
        switch outcome {
        case .authenticated(let person):
            Log.app.info("인증 성공: \(person, privacy: .public)")
            performUnlock()
        case .timedOut:
            abort(T("시간 초과 — 비밀번호로 로그인하세요", "Timed out — log in with your password"))
        case .cancelled:
            refreshStatus()
        case .failed(let reason):
            abort(reason)
        }
    }

    /// 인증이 실패하거나 제한시간을 넘겼다 — 창을 닫는다.
    ///
    /// 예전에는 여기서 카메라를 켜둔 채 2초 뒤 다시 시도했다. 잠겨 있는 한
    /// 끝이 없는 순환이라, 앞에 아무도 없어도 카메라가 계속 돌았다.
    /// 지금은 접는다. 창을 다시 붙잡던 화면도 놓으므로 macOS 가 곧 화면을
    /// 재우고, 사용자가 다시 다가와 화면을 깨우면 그 사건이 새 창을 연다.
    private func abort(_ reason: String) {
        Log.app.error("인증 중단: \(reason, privacy: .public)")
        closeWindow("인증 실패")
        status = .failed(reason)
    }

    // MARK: 잠금 해제

    private func performUnlock() {
        status = .unlocking
        // 카메라부터 끈다. 주입이 끝나면 화면이 열리므로 표시등을 계속 켜둘 이유가 없다.
        session = nil
        camera.stop(owner: self)
        // 여기서부터는 화면을 붙잡을 이유가 없다. Unlocker 가 직접 깨운다.
        AwakeWindow.release()

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
                        self.closeWindow("비밀번호 연속 거부")
                        Log.app.error("저장된 비밀번호가 연속 거부됨 — 자동 해제를 중단합니다")
                        self.status = .needsSetup(.passwordReenroll)
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
    func setupBlocker() -> SetupBlocker? {
        if !hasCamera        { return .cameraPermission }
        if !hasAccessibility { return .accessibilityPermission }
        if !modelAvailable               { return .model }
        if !store.isLoaded               { return .loadingFaces }
        if !store.isEnrolled             { return .enrollment }
        if !Vault.hasPassword            { return .password }
        if vaultUnreadable               { return .passwordReenroll }
        if passwordRejected              { return .passwordReenroll }
        return nil
    }
}
