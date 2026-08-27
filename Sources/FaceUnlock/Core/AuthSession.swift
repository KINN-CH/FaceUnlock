import CoreVideo
import Foundation
import QuartzCore
import Vision

/// 한 번의 잠금 동안 진행되는 인증 세션.
///
/// 카메라 프레임 → 검출 → 정렬 → 임베딩 → 매칭 → 깜빡임 → 결과.
/// 모든 무거운 작업은 카메라 큐에서 돌고, 콜백만 메인으로 올린다.
///
/// 성공/실패 콜백은 **정확히 한 번만** 불린다.
final class AuthSession {

    enum Progress {
        case searching                    // 얼굴이 안 보임
        /// 얼굴은 있으나 아직 불일치. 점수를 함께 싣는다 — 임계값을 조정하려면
        /// "안 맞음"이 아니라 "얼마나 안 맞는지"를 봐야 한다.
        /// 임베딩을 못 뽑은 프레임에서는 nil.
        case faceDetected(score: Float?)
        case matching(score: Float)       // 일치 진행 중 (연속 카운트 채우는 중)
        case blinkChallenge               // 얼굴 확인됨. 깜빡임 대기
        case verifying                    // 깜빡임 직후 재확인
    }

    enum Outcome {
        case authenticated
        case timedOut
        case cancelled
        case failed(String)
    }

    struct Config {
        var threshold: Float = 0.48
        /// 우연한 한 프레임 일치로 열리지 않도록 연속 일치를 요구한다.
        var requiredConsecutiveMatches = 3
        var requireBlink = true
        var timeout: TimeInterval = 20
        var blinkTimeout: TimeInterval = 8
        /// 깜빡임 직후 재확인에 주는 시간.
        ///
        /// 한 프레임만 보고 판정하면 안 된다. 깜빡임이 끝난 직후는 눈꺼풀이 아직
        /// 올라오는 중이라 임베딩 점수가 눈에 띄게 낮고, 그러면 깜빡임까지 성공해
        /// 놓고 매번 처음으로 되돌아간다. 창을 주되 짧게 준다 — 이 사이에도 얼굴은
        /// 계속 일치해야 하므로 "깜빡이는 동안 얼굴 바꿔치기" 방어는 그대로다.
        var reverifyWindow: TimeInterval = 2.0
    }

    var onProgress: ((Progress) -> Void)?
    var onOutcome: ((Outcome) -> Void)?

    private enum Phase {
        case identifying
        case awaitingBlink(deadline: CFTimeInterval)
        case verifyingAfterBlink(deadline: CFTimeInterval)
        case finished
    }

    private let profile: FaceProfile
    private let model: EmbeddingModel
    private let config: Config

    private let detector = FaceDetector()
    private let aligner = FaceAligner()
    private let blink = BlinkDetector()

    private var phase: Phase = .identifying
    private var consecutiveMatches = 0
    private var deadline: CFTimeInterval = 0
    private var lastProgress: String = ""

    init(profile: FaceProfile, model: EmbeddingModel, config: Config) {
        self.profile = profile
        self.model = model
        self.config = config
    }

    func begin() {
        deadline = CACurrentMediaTime() + config.timeout
        phase = .identifying
        consecutiveMatches = 0
        blink.reset()
    }

    func cancel() {
        if case .finished = phase { return }
        finish(.cancelled)
    }

    // MARK: 프레임 처리 (카메라 큐)

    func process(frame pixelBuffer: CVPixelBuffer) {
        if case .finished = phase { return }
        handle(frame: pixelBuffer)
    }

    private func handle(frame pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard now < deadline else {
            Log.face.info("인증 시간 초과")
            finish(.timedOut)
            return
        }

        guard let face = detector.detectPrimaryFace(in: pixelBuffer) else {
            report(.searching)
            // 얼굴이 사라지면 연속 카운트를 버린다. 다른 사람으로 바꿔치는 걸 막는다.
            consecutiveMatches = 0
            blink.reset()
            return
        }

        guard detector.passesQualityGate(face, in: pixelBuffer) else {
            report(.faceDetected(score: nil))
            consecutiveMatches = 0
            return
        }

        switch phase {
        case .identifying:
            identify(face: face, in: pixelBuffer)

        case .awaitingBlink(let blinkDeadline):
            if now > blinkDeadline {
                Log.face.info("깜빡임 대기 시간 초과")
                finish(.failed("깜빡임이 감지되지 않았습니다"))
                return
            }
            report(.blinkChallenge)
            if case .blinked = blink.process(face, at: now) {
                phase = .verifyingAfterBlink(deadline: now + config.reverifyWindow)
            }

        case .verifyingAfterBlink(let verifyDeadline):
            // 눈 감긴 사이 얼굴이 바뀌었을 수 있으므로 한 번 더 확인한다.
            report(.verifying)

            if let result = embedAndMatch(face: face, in: pixelBuffer),
               result.passes(threshold: config.threshold) {
                Log.face.info("깜빡임 후 재확인 통과 (\(result.score, format: .fixed(precision: 3)))")
                finish(.authenticated)
                return
            }

            // 아직 창이 남아 있으면 다음 프레임을 기다린다. 눈이 완전히 떠지면 통과한다.
            guard now > verifyDeadline else { return }
            Log.face.error("깜빡임 후 재확인 실패 — 처음부터 다시")
            phase = .identifying
            consecutiveMatches = 0
            blink.reset()

        case .finished:
            break
        }
    }

    private func identify(face: VNFaceObservation, in pixelBuffer: CVPixelBuffer) {
        guard let result = embedAndMatch(face: face, in: pixelBuffer) else {
            report(.faceDetected(score: nil))
            consecutiveMatches = 0
            return
        }

        guard result.passes(threshold: config.threshold) else {
            consecutiveMatches = 0
            report(.faceDetected(score: result.score))
            return
        }

        consecutiveMatches += 1
        report(.matching(score: result.score))

        guard consecutiveMatches >= config.requiredConsecutiveMatches else { return }

        if config.requireBlink {
            Log.face.info("얼굴 일치 — 깜빡임 대기 시작")
            blink.reset()
            phase = .awaitingBlink(deadline: CACurrentMediaTime() + config.blinkTimeout)
            report(.blinkChallenge)
        } else {
            Log.face.info("얼굴 일치 (깜빡임 확인 없음)")
            finish(.authenticated)
        }
    }

    private func embedAndMatch(face: VNFaceObservation, in pixelBuffer: CVPixelBuffer) -> MatchResult? {
        guard let pixels = aligner.alignedPixels(from: pixelBuffer, observation: face),
              let vector = model.embed(alignedRGBA: pixels) else { return nil }
        return profile.match(vector)
    }

    // MARK: 콜백

    /// 같은 진행 상태를 매 프레임 올리면 UI 가 계속 갱신된다. 바뀔 때만 보낸다.
    private func report(_ progress: Progress) {
        // 점수가 실린 상태는 점수를 키에 넣는다. 안 그러면 첫 프레임 이후
        // 점수가 변해도 UI 가 갱신되지 않아 임계값 조정에 쓸 수 없다.
        let key: String
        switch progress {
        case .searching:              key = "searching"
        case .faceDetected(let s):    key = "face:\(s.map { String(format: "%.2f", $0) } ?? "-")"
        case .matching(let s):        key = "matching:\(String(format: "%.2f", s))"
        case .blinkChallenge:         key = "blink"
        case .verifying:              key = "verify"
        }
        guard key != lastProgress else { return }
        lastProgress = key

        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(progress)
        }
    }

    private func finish(_ outcome: Outcome) {
        if case .finished = phase { return }   // 결과는 정확히 한 번만 통지한다
        phase = .finished
        DispatchQueue.main.async { [weak self] in
            self?.onOutcome?(outcome)
        }
    }
}
