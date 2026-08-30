import AVFoundation
import Combine
import SwiftUI

/// 잠금 해제 없이 인식만 확인하는 드라이런.
///
/// 왜 따로 두는가: 실제 경로는 잠금 상태에서만 돌고, 성공하면 곧바로 비밀번호를
/// 주입한다. 그래서 "인식이 되는가"를 확인하려면 비밀번호를 먼저 등록해야 하고,
/// 그 말은 **첫 테스트가 곧 주입 테스트**가 된다는 뜻이다. 순서가 거꾸로다.
///
/// 이 화면은 같은 `AuthSession` 을 그대로 쓰되 결과를 화면에 표시만 한다.
/// `Unlocker` 를 부르지 않고, 비밀번호도 필요 없다.
/// 카메라 큐에서 지금 살아 있는 세션으로 프레임을 넘기는 중계.
///
/// 왜 필요한가: 미리보기는 **등록 정보를 다 불러오기 전에** 켜야 한다(안 그러면
/// 그 동안 창이 새까맣다). 그런데 카메라 콜백은 카메라 큐에서 오고 세션은
/// 메인 액터가 만든다. 콜백이 세션을 직접 붙들면 "아직 없는 세션" 을 잡을 수
/// 없으니, 중간에 자물쇠 하나를 두고 나중에 갈아끼운다.
private final class FrameRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var session: AuthSession?

    func attach(_ session: AuthSession?) {
        lock.lock(); self.session = session; lock.unlock()
    }

    func process(_ buffer: CVPixelBuffer) {
        lock.lock(); let session = self.session; lock.unlock()
        session?.process(frame: buffer)
    }
}

@MainActor
final class RecognitionTestController: ObservableObject {

    @Published private(set) var headline = T("카메라를 준비하는 중…", "Preparing the camera…")
    @Published private(set) var detail = ""
    @Published private(set) var score: Float?
    @Published private(set) var isRunning = false
    @Published private(set) var succeeded = false
    @Published private(set) var errorMessage: String?

    private let camera = CameraSession.shared
    private let router = FrameRouter()
    private var session: AuthSession?
    private var lockObserver: NSObjectProtocol?
    /// 등록 정보 복호화를 기다리는 구독. 자세한 사정은 [beginSessionWhenReady].
    private var loadWatcher: AnyCancellable?

    var threshold: Float { Settings.shared.matchThreshold }

    /// 화면이 잠기면 카메라를 놓는다.
    ///
    /// 세션은 하나뿐이라 창을 열어둔 채 화면이 잠기면 이 창과 실제 해제
    /// 경로가 같은 카메라를 두고 소유권을 주고받게 된다. 그 사이 프레임 콜백이
    /// 오가면 정작 잠금을 풀어야 할 쪽이 인식을 처음부터 다시 시작한다.
    /// 진단용인 이쪽이 양보하는 게 맞다.
    func observeLock() {
        guard lockObserver == nil else { return }
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: LockMonitor.lockedNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    self.stop()
                    self.headline = T("중단됨", "Stopped")
                    self.detail = T("화면이 잠겨 카메라를 실제 잠금 해제 쪽에 넘겼습니다.",
                                    "The screen locked, so the camera was handed to the real unlock path.")
                }
            }
    }

    func stopObservingLock() {
        if let lockObserver {
            DistributedNotificationCenter.default().removeObserver(lockObserver)
        }
        lockObserver = nil
    }

    /// 카메라부터 켜고, 준비되는 대로 인식 세션을 붙인다.
    ///
    /// 예전에는 등록 정보가 아직 안 올라왔으면 여기서 그냥 돌아섰다. 그런데
    /// **새 버전을 처음 실행하면 그 복호화가 30초쯤 걸린다** — 키체인이 앱
    /// 서명이 바뀐 걸 보고 확인 창을 띄우고, 사용자가 답할 때까지 멈춰 있기
    /// 때문이다. 그 사이 이 창을 열면 카메라를 아예 켜지 않은 채 "먼저 얼굴을
    /// 등록해 주세요" 만 떠서, 등록을 마친 사람에게는 새까만 화면으로 보였다.
    /// 그래서 순서를 뒤집었다: 미리보기는 즉시 켜고, 세션은 준비되면 붙인다.
    func start() {
        errorMessage = nil
        succeeded = false
        score = nil
        detail = ""
        headline = T("카메라를 켜는 중…", "Turning the camera on…")

        camera.start(owner: self,
                     onFrame: { [router] buffer in router.process(buffer) },
                     onFailure: { [weak self] reason in
                         Task { @MainActor in
                             self?.errorMessage = reason
                             self?.stop()
                         }
                     })
        isRunning = true
        beginSessionWhenReady()
    }

    /// 등록 정보가 올라오면 세션을 시작한다. 아직이면 기다린다.
    private func beginSessionWhenReady() {
        let store = FaceStore.shared
        guard store.isLoaded else {
            headline = T("등록 정보를 불러오는 중…", "Loading enrolled faces…")
            detail = T("새 버전을 처음 실행하면 30초쯤 걸립니다. 키체인 확인 창이 뜨면 ‘항상 허용’을 눌러 주세요.",
                       "The first launch of a new version takes about 30 seconds. If a Keychain prompt appears, choose “Always Allow”.")
            loadWatcher = store.$isLoaded
                .filter { $0 }
                .first()
                .sink { [weak self] _ in
                    Task { @MainActor in self?.beginSessionWhenReady() }
                }
            return
        }
        loadWatcher = nil

        guard let roster = store.snapshot(), !roster.isEmpty else {
            errorMessage = T("먼저 얼굴을 등록해 주세요.", "Enroll a face first.")
            stop()
            return
        }
        guard let model = AppState.shared.loadModelIfNeeded() else {
            errorMessage = T("얼굴 인식 모델을 불러오지 못했습니다.", "Could not load the recognition model.")
            stop()
            return
        }

        headline = T("얼굴을 찾는 중…", "Looking for a face…")
        detail = ""

        var config = AuthSession.Config()
        config.threshold = Settings.shared.matchThreshold
        config.requireBlink = Settings.shared.requireBlink
        config.timeout = Settings.shared.recognitionTimeout

        let session = AuthSession(roster: roster, model: model, config: config)
        session.onProgress = { [weak self] progress in
            Task { @MainActor in self?.apply(progress) }
        }
        session.onOutcome = { [weak self] outcome in
            Task { @MainActor in self?.apply(outcome) }
        }
        session.begin()
        self.session = session
        router.attach(session)
    }

    func stop() {
        endRound(releaseCamera: true)
    }

    /// 한 회차를 끝낸다.
    ///
    /// `releaseCamera` 를 끄면 장치는 계속 돌아간다. 결과가 나올 때마다
    /// 카메라를 껐다가 "다시 시도" 에서 다시 켜는 게 바로 검은 화면의
    /// 원인이었다 — 장치가 그 짧은 껐다 켜기를 몇 번 겪으면 "돌긴 하는데
    /// 프레임은 안 오는" 상태로 빠진다. 창이 열려 있는 동안은 켜둔다.
    /// 미리보기가 계속 살아 있으니 결과를 읽는 동안 자기 모습도 보인다.
    private func endRound(releaseCamera: Bool) {
        loadWatcher = nil
        router.attach(nil)
        session?.cancel()
        session = nil
        if releaseCamera { camera.stop(owner: self) }
        isRunning = false
    }

    // MARK: 표시

    private func apply(_ progress: AuthSession.Progress) {
        switch progress {
        case .searching:
            headline = T("얼굴을 찾는 중…", "Looking for a face…")
            detail = ""
            score = nil
        case .faceDetected(let value):
            headline = T("얼굴은 보이지만 일치하지 않습니다", "Face visible, but no match")
            score = value
            detail = value == nil
                ? T("이 프레임에서는 특징을 뽑지 못했습니다 (너무 작거나 흐릿함)",
                    "Could not extract features from this frame (too small or blurry)")
                : T("임계값 \(String(format: "%.2f", threshold)) 미만",
                    "Below the \(String(format: "%.2f", threshold)) threshold")
        case .matching(let value):
            headline = T("일치 — 확인 중", "Match — confirming")
            score = value
            detail = T("연속 일치 프레임을 채우는 중입니다", "Filling consecutive matching frames")
        case .blinkChallenge:
            headline = T("눈을 한 번 깜빡여 주세요", "Blink once, please")
            detail = T("정지 사진을 걸러내는 단계입니다", "This step filters out still photos")
        case .verifying:
            headline = T("깜빡임 후 재확인 중…", "Re-verifying after the blink…")
            detail = T("눈 감긴 사이 얼굴이 바뀌지 않았는지 봅니다",
                       "Checking the face did not change while eyes were closed")
        }
    }

    private func apply(_ outcome: AuthSession.Outcome) {
        endRound(releaseCamera: false)
        switch outcome {
        case .authenticated(let person):
            succeeded = true
            headline = T("인식 성공 — \(person)", "Recognized — \(person)")
            detail = T("실제 잠금 상태였다면 여기서 잠금이 풀립니다. 지금은 아무것도 하지 않습니다.",
                       "On a real lock screen this would unlock now. Here it does nothing.")
        case .timedOut:
            headline = T("시간 초과", "Timed out")
            detail = T("제한 시간 안에 일치하지 않았습니다.", "No match within the time limit.")
        case .cancelled:
            headline = T("중단됨", "Stopped")
            detail = ""
        case .failed(let reason):
            headline = T("실패", "Failed")
            detail = reason
        }
    }
}

struct RecognitionTestView: View {
    @StateObject private var controller = RecognitionTestController()
    @ObservedObject private var l10n = L10n.shared
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(T("인식 테스트", "Recognition Test"))
                .font(.headline)
            Text(T("잠금 해제는 하지 않습니다. 인식이 되는지만 확인합니다.",
                   "Does not unlock anything — only checks recognition."))
                .font(.caption)
                .foregroundStyle(.secondary)

            CameraPreview()
                .frame(width: 320, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(controller.succeeded ? Color.green : Color.secondary.opacity(0.4),
                                lineWidth: 3)
                )

            // 설정에서 고른 카메라가 실제로 쓰이는지 눈으로 확인할 수 있어야 한다.
            if let name = CameraSession.preferredDevice()?.localizedName {
                Text(T("카메라: \(name)", "Camera: \(name)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                Text(controller.headline)
                    .font(.title3)
                if !controller.detail.isEmpty {
                    Text(controller.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(height: 56)

            scoreBar

            if let error = controller.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button(controller.isRunning ? T("중지", "Stop") : T("다시 시도", "Try Again")) {
                    if controller.isRunning { controller.stop() } else { controller.start() }
                }
                Button(T("닫기", "Close"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            controller.observeLock()
            controller.start()
        }
        .onDisappear {
            controller.stopObservingLock()
            controller.stop()
        }
    }

    /// 점수와 임계값을 나란히 보여준다. 임계값을 어디에 둘지 정하려면
    /// 본인 얼굴이 보통 몇 점인지 눈으로 봐야 한다.
    private var scoreBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(T("유사도", "Similarity"))
                    .font(.caption)
                Spacer()
                Text(controller.score.map { String(format: "%.3f", $0) } ?? "—")
                    .font(.system(.caption, design: .monospaced))
                Text(T("/ 임계 \(String(format: "%.2f", controller.threshold))",
                       "/ threshold \(String(format: "%.2f", controller.threshold))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(passing ? Color.green : Color.orange)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, controller.score ?? 0))))
                    // 임계선
                    Rectangle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 2)
                        .offset(x: geo.size.width * CGFloat(controller.threshold))
                }
            }
            .frame(height: 10)
        }
    }

    private var passing: Bool {
        (controller.score ?? 0) >= controller.threshold
    }
}

@MainActor
final class RecognitionTestWindowController {
    static let shared = RecognitionTestWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            window.title = T("인식 테스트", "Recognition Test")
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: RecognitionTestView { [weak self] in
            self?.close()
        })
        let win = NSWindow(contentViewController: hosting)
        win.title = T("인식 테스트", "Recognition Test")
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()

        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }
}
