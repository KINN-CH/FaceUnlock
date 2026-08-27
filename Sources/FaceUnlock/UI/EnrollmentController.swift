import AVFoundation
import CoreVideo
import Foundation
import SwiftUI

/// 카메라 큐에서 도는 등록 캡처 로직.
///
/// 메인 액터 밖에 두는 이유: 프레임마다 검출·정렬·임베딩이 도는데
/// 이걸 메인에서 하면 등록 화면이 뚝뚝 끊긴다.
final class EnrollmentCapturer: @unchecked Sendable {

    enum Readiness {
        case ready
        case noFace
        case poorQuality
    }

    /// 매 프레임 호출 (카메라 큐).
    var onReadiness: ((Readiness) -> Void)?
    /// 캡처 요청이 처리되어 임베딩이 나왔을 때 (카메라 큐).
    var onCaptured: (([Float]) -> Void)?
    /// 캡처 요청은 있었으나 임베딩에 실패했을 때 (카메라 큐).
    var onCaptureFailed: (() -> Void)?

    private let detector = FaceDetector()
    private let aligner = FaceAligner()
    private let model: EmbeddingModel

    private let lock = NSLock()
    private var captureRequested = false

    init(model: EmbeddingModel) {
        self.model = model
    }

    func requestCapture() {
        lock.lock(); captureRequested = true; lock.unlock()
    }

    /// 요청을 읽으면서 동시에 내린다 — 한 번의 요청에 두 프레임이 잡히지 않도록.
    private func consumeRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard captureRequested else { return false }
        captureRequested = false
        return true
    }

    func process(frame pixelBuffer: CVPixelBuffer) {
        guard let face = detector.detectPrimaryFace(in: pixelBuffer) else {
            onReadiness?(.noFace)
            return
        }
        guard detector.passesQualityGate(face, in: pixelBuffer) else {
            onReadiness?(.poorQuality)
            return
        }
        onReadiness?(.ready)

        guard consumeRequest() else { return }

        guard let pixels = aligner.alignedPixels(from: pixelBuffer, observation: face),
              let direct = model.embed(alignedRGBA: pixels),
              let mirrored = model.embed(alignedRGBA: pixels, mirrored: true) else {
            onCaptureFailed?()
            return
        }

        // 원본과 좌우 반전본의 평균. 한쪽만 빛을 받는 상황에서 조금 더 안정적이다.
        onCaptured?(VectorMath.centroid([direct, mirrored]))
    }
}

/// 얼굴 등록 마법사의 상태.
///
/// 포즈를 하나씩 안내하고, 품질 게이트를 통과한 프레임에서만 임베딩을 저장한다.
/// 흐릿하거나 치우친 프레임을 등록해 두면 그 뒤로 계속 오인식이 난다.
@MainActor
final class EnrollmentController: ObservableObject {

    @Published private(set) var completed: Set<FacePose> = []
    @Published private(set) var canCapture = false
    @Published private(set) var guidance = "카메라를 준비하는 중…"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isFinished = false
    @Published private(set) var currentPose: FacePose = .center

    private let camera = CameraSession.shared
    private var capturer: EnrollmentCapturer?

    var progress: Double { Double(completed.count) / Double(FacePose.allCases.count) }

    func makePreviewLayer() -> AVCaptureVideoPreviewLayer { camera.makePreviewLayer() }

    // MARK: 생명주기

    func start() {
        guard let model = AppState.shared.loadModelIfNeeded() else {
            errorMessage = "얼굴 인식 모델을 불러오지 못했습니다. tools/fetch_arcface.py 를 실행했는지 확인해 주세요."
            return
        }

        // 새로 등록할 때는 기존 등록을 비운다. 섞이면 어느 얼굴인지 알 수 없다.
        FaceStore.shared.beginEnrollment()
        completed = []
        isFinished = false
        errorMessage = nil
        currentPose = .center
        guidance = currentPose.instruction

        let capturer = EnrollmentCapturer(model: model)
        capturer.onReadiness = { [weak self] readiness in
            Task { @MainActor in self?.apply(readiness) }
        }
        capturer.onCaptured = { [weak self] vector in
            Task { @MainActor in self?.record(vector) }
        }
        capturer.onCaptureFailed = { [weak self] in
            Task { @MainActor in
                self?.errorMessage = "이 프레임에서 얼굴 특징을 뽑지 못했습니다. 다시 시도해 주세요."
            }
        }
        self.capturer = capturer

        camera.start(owner: self,
                     onFrame: { [weak capturer] buffer in capturer?.process(frame: buffer) },
                     onFailure: { [weak self] reason in
                         Task { @MainActor in self?.errorMessage = reason }
                     })
    }

    func stop() {
        camera.stop(owner: self)
        capturer = nil
    }

    func requestCapture() {
        capturer?.requestCapture()
    }

    // MARK: 상태 갱신

    private func apply(_ readiness: EnrollmentCapturer.Readiness) {
        switch readiness {
        case .ready:
            canCapture = true
            guidance = currentPose.instruction
        case .noFace:
            canCapture = false
            guidance = "얼굴이 보이지 않습니다"
        case .poorQuality:
            canCapture = false
            guidance = "얼굴이 너무 작거나 화면 가장자리에 있습니다"
        }
    }

    private func record(_ vector: [Float]) {
        do {
            try FaceStore.shared.record(vector, pose: currentPose)
            completed.insert(currentPose)
        } catch {
            errorMessage = "저장 실패: \(error.localizedDescription)"
            return
        }

        guard let next = FacePose.allCases.first(where: { !completed.contains($0) }) else {
            isFinished = true
            guidance = "등록 완료"
            stop()
            AppState.shared.refreshStatus()
            return
        }
        currentPose = next
        guidance = next.instruction
    }
}
