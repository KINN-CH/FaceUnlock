import AVFoundation
import SwiftUI

/// 잠금 해제 없이 인식만 확인하는 드라이런.
///
/// 왜 따로 두는가: 실제 경로는 잠금 상태에서만 돌고, 성공하면 곧바로 비밀번호를
/// 주입한다. 그래서 "인식이 되는가"를 확인하려면 비밀번호를 먼저 등록해야 하고,
/// 그 말은 **첫 테스트가 곧 주입 테스트**가 된다는 뜻이다. 순서가 거꾸로다.
///
/// 이 화면은 같은 `AuthSession` 을 그대로 쓰되 결과를 화면에 표시만 한다.
/// `Unlocker` 를 부르지 않고, 비밀번호도 필요 없다.
@MainActor
final class RecognitionTestController: ObservableObject {

    @Published private(set) var headline = "카메라를 준비하는 중…"
    @Published private(set) var detail = ""
    @Published private(set) var score: Float?
    @Published private(set) var isRunning = false
    @Published private(set) var succeeded = false
    @Published private(set) var errorMessage: String?

    private let camera = CameraSession()
    private var session: AuthSession?

    var threshold: Float { Settings.shared.matchThreshold }

    func makePreviewLayer() -> AVCaptureVideoPreviewLayer { camera.makePreviewLayer() }

    func start() {
        guard let profile = FaceStore.shared.snapshot(), !profile.samples.isEmpty else {
            errorMessage = "먼저 얼굴을 등록해 주세요."
            return
        }
        guard let model = AppState.shared.loadModelIfNeeded() else {
            errorMessage = "얼굴 인식 모델을 불러오지 못했습니다."
            return
        }

        errorMessage = nil
        succeeded = false
        score = nil
        headline = "얼굴을 찾는 중…"
        detail = ""

        var config = AuthSession.Config()
        config.threshold = Settings.shared.matchThreshold
        config.requireBlink = Settings.shared.requireBlink
        config.timeout = Settings.shared.recognitionTimeout

        let session = AuthSession(profile: profile, model: model, config: config)
        session.onProgress = { [weak self] progress in
            Task { @MainActor in self?.apply(progress) }
        }
        session.onOutcome = { [weak self] outcome in
            Task { @MainActor in self?.apply(outcome) }
        }
        session.begin()
        self.session = session

        camera.onFrame = { [weak session] buffer in session?.process(frame: buffer) }
        camera.onFailure = { [weak self] reason in
            Task { @MainActor in
                self?.errorMessage = reason
                self?.stop()
            }
        }
        camera.start()
        isRunning = true
    }

    func stop() {
        session?.cancel()
        session = nil
        camera.onFrame = nil
        camera.stop()
        isRunning = false
    }

    // MARK: 표시

    private func apply(_ progress: AuthSession.Progress) {
        switch progress {
        case .searching:
            headline = "얼굴을 찾는 중…"
            detail = ""
            score = nil
        case .faceDetected(let value):
            headline = "얼굴은 보이지만 일치하지 않습니다"
            score = value
            detail = value == nil
                ? "이 프레임에서는 특징을 뽑지 못했습니다 (너무 작거나 흐릿함)"
                : "임계값 \(String(format: "%.2f", threshold)) 미만"
        case .matching(let value):
            headline = "일치 — 확인 중"
            score = value
            detail = "연속 일치 프레임을 채우는 중입니다"
        case .blinkChallenge:
            headline = "눈을 한 번 깜빡여 주세요"
            detail = "정지 사진을 걸러내는 단계입니다"
        case .verifying:
            headline = "깜빡임 후 재확인 중…"
            detail = "눈 감긴 사이 얼굴이 바뀌지 않았는지 봅니다"
        }
    }

    private func apply(_ outcome: AuthSession.Outcome) {
        stop()
        switch outcome {
        case .authenticated:
            succeeded = true
            headline = "인식 성공"
            detail = "실제 잠금 상태였다면 여기서 잠금이 풀립니다. 지금은 아무것도 하지 않습니다."
        case .timedOut:
            headline = "시간 초과"
            detail = "제한 시간 안에 일치하지 않았습니다."
        case .cancelled:
            headline = "중단됨"
            detail = ""
        case .failed(let reason):
            headline = "실패"
            detail = reason
        }
    }
}

struct RecognitionTestView: View {
    @StateObject private var controller = RecognitionTestController()
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("인식 테스트")
                .font(.headline)
            Text("잠금 해제는 하지 않습니다. 인식이 되는지만 확인합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            CameraPreview { controller.makePreviewLayer() }
                .frame(width: 320, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(controller.succeeded ? Color.green : Color.secondary.opacity(0.4),
                                lineWidth: 3)
                )

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
                Button(controller.isRunning ? "중지" : "다시 시도") {
                    if controller.isRunning { controller.stop() } else { controller.start() }
                }
                Button("닫기", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }

    /// 점수와 임계값을 나란히 보여준다. 임계값을 어디에 둘지 정하려면
    /// 본인 얼굴이 보통 몇 점인지 눈으로 봐야 한다.
    private var scoreBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("유사도")
                    .font(.caption)
                Spacer()
                Text(controller.score.map { String(format: "%.3f", $0) } ?? "—")
                    .font(.system(.caption, design: .monospaced))
                Text("/ 임계 \(String(format: "%.2f", controller.threshold))")
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
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: RecognitionTestView { [weak self] in
            self?.close()
        })
        let win = NSWindow(contentViewController: hosting)
        win.title = "인식 테스트"
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
