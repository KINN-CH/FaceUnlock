import AVFoundation
import CoreVideo
import Foundation
import QuartzCore
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
    /// 오토 촬영이 자세를 잡고 있는 중 — 어떤 포즈를 얼마나 (카메라 큐).
    var onAutoProgress: ((FacePose?, Double) -> Void)?
    /// 캡처가 처리되어 임베딩이 나왔을 때 (카메라 큐).
    var onCaptured: ((FacePose, [Float]) -> Void)?
    /// 캡처를 시도했으나 임베딩에 실패했을 때 (카메라 큐).
    var onCaptureFailed: (() -> Void)?

    private let detector = FaceDetector()
    private let aligner = FaceAligner()
    private let model: EmbeddingModel

    private let lock = NSLock()
    private var auto = PoseAutoCapture()
    private var manualRequest: FacePose?
    private var reportedPose: FacePose?
    private var reportedProgress: Double = 0

    init(model: EmbeddingModel) {
        self.model = model
    }

    /// 수동 촬영 버튼. 오토가 안 잡히는 자세를 사용자가 직접 밀어넣는 길.
    func requestCapture(for pose: FacePose) {
        lock.lock(); manualRequest = pose; lock.unlock()
    }

    /// 저장이 끝난 뒤 남은 포즈를 다시 알려준다.
    func setRemaining(_ poses: [FacePose]) {
        lock.lock(); auto.setRemaining(poses); lock.unlock()
    }

    func process(frame pixelBuffer: CVPixelBuffer) {
        guard let face = detector.detectPrimaryFace(in: pixelBuffer) else {
            interrupt(.noFace)
            return
        }
        guard detector.passesQualityGate(face, in: pixelBuffer),
              let head = HeadPose(observation: face,
                                  imageSize: CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                                    height: CVPixelBufferGetHeight(pixelBuffer)))
        else {
            interrupt(.poorQuality)
            return
        }
        onReadiness?(.ready)

        let now = CACurrentMediaTime()
        var target: FacePose?
        var progress: (FacePose?, Double) = (nil, 0)

        lock.lock()
        if let manual = manualRequest {
            // 요청을 읽으면서 동시에 내린다 — 한 번의 요청에 두 프레임이 잡히지 않도록.
            manualRequest = nil
            target = manual
        } else {
            switch auto.update(head, at: now) {
            case .idle:
                break
            case .holding(let pose, let fraction):
                progress = (pose, fraction)
            case .fire(let pose):
                target = pose
            }
        }
        lock.unlock()

        report(progress.0, progress.1)
        guard let target else { return }

        guard let pixels = aligner.alignedPixels(from: pixelBuffer, observation: face),
              let direct = model.embed(alignedRGBA: pixels),
              let mirrored = model.embed(alignedRGBA: pixels, mirrored: true) else {
            onCaptureFailed?()
            return
        }

        lock.lock(); auto.didCapture(target, at: head, time: now); lock.unlock()
        report(nil, 0)

        // 원본과 좌우 반전본의 평균. 한쪽만 빛을 받는 상황에서 조금 더 안정적이다.
        onCaptured?(target, VectorMath.centroid([direct, mirrored]))
    }

    private func interrupt(_ readiness: Readiness) {
        lock.lock(); auto.interrupt(); lock.unlock()
        onReadiness?(readiness)
        report(nil, 0)
    }

    /// 프레임마다 메인으로 넘기면 낭비라, 눈에 보이게 달라졌을 때만 알린다.
    private func report(_ pose: FacePose?, _ progress: Double) {
        lock.lock()
        let changed = pose != reportedPose || abs(progress - reportedProgress) >= 0.05
            || (progress == 0 && reportedProgress != 0)
        if changed {
            reportedPose = pose
            reportedProgress = progress
        }
        lock.unlock()
        guard changed else { return }
        onAutoProgress?(pose, progress)
    }
}

/// 얼굴 등록 마법사의 상태.
///
/// 포즈를 하나씩 안내하고, 품질 게이트를 통과한 프레임에서만 임베딩을 모은다.
/// 흐릿하거나 치우친 프레임을 등록해 두면 그 뒤로 계속 오인식이 난다.
///
/// 촬영은 **오토**다 — 안내대로 고개를 돌려 잠깐 멈추면 알아서 찍힌다.
/// 순서도 강제하지 않아서, 왼쪽을 안내하는 중에 고개를 들면 위쪽 칸이 먼저 채워진다.
/// (정면만은 예외로 맨 처음 찍는다. 그 값이 나머지 판정의 기준선이 된다.)
///
/// 모은 샘플은 여기 들고만 있다가 [commit] 에서 한 번에 저장한다.
/// 중간에 창을 닫으면 아무것도 남지 않는다 — 포즈마다 저장하던 예전 방식은
/// 취소해도 반쪽짜리 등록이 남아 기존 등록까지 망가뜨렸다.
@MainActor
final class EnrollmentController: ObservableObject {

    @Published private(set) var completed: Set<FacePose> = []
    @Published private(set) var canCapture = false
    @Published private(set) var guidance = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isFinished = false
    @Published private(set) var currentPose: FacePose = .center
    /// 지금 오토 촬영이 잡고 있는 포즈와 그 진행도(0…1).
    @Published private(set) var holdingPose: FacePose?
    @Published private(set) var holdProgress: Double = 0
    /// 등록할 사람 이름. 비워두면 저장 시점에 "사용자 N" 이 붙는다.
    @Published var personName = ""

    private let camera = CameraSession.shared
    private var capturer: EnrollmentCapturer?
    private var samples: [FaceSample] = []
    private var lastReadiness: EnrollmentCapturer.Readiness = .noFace

    var progress: Double { Double(completed.count) / Double(FacePose.allCases.count) }

    // MARK: 생명주기

    func start() {
        guard FaceStore.shared.canAddPerson else {
            errorMessage = FaceStoreError.rosterFull.localizedDescription
            return
        }
        guard let model = AppState.shared.loadModelIfNeeded() else {
            errorMessage = T("얼굴 인식 모델을 불러오지 못했습니다. tools/fetch_arcface.py 를 실행했는지 확인해 주세요.",
                             "Could not load the face recognition model. Make sure you ran tools/fetch_arcface.py.")
            return
        }

        samples = []
        personName = ""
        completed = []
        lastReadiness = .noFace
        isFinished = false
        errorMessage = nil
        currentPose = .center
        holdingPose = nil
        holdProgress = 0
        guidance = currentPose.instruction

        let capturer = EnrollmentCapturer(model: model)
        capturer.onReadiness = { [weak self] readiness in
            Task { @MainActor in self?.apply(readiness) }
        }
        capturer.onAutoProgress = { [weak self] pose, fraction in
            Task { @MainActor in self?.applyHold(pose, fraction) }
        }
        capturer.onCaptured = { [weak self] pose, vector in
            Task { @MainActor in self?.record(pose, vector) }
        }
        capturer.onCaptureFailed = { [weak self] in
            Task { @MainActor in
                self?.errorMessage = T("이 프레임에서 얼굴 특징을 뽑지 못했습니다. 다시 시도해 주세요.",
                                       "Could not extract face features from this frame. Please try again.")
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
        holdingPose = nil
        holdProgress = 0
    }

    func requestCapture() {
        capturer?.requestCapture(for: currentPose)
    }

    /// 모은 9포즈를 한 사람으로 저장한다. 완료 버튼에서만 부른다.
    func commit() {
        guard isFinished else { return }
        do {
            try FaceStore.shared.addPerson(name: personName, samples: samples)
            AppState.shared.refreshStatus()
        } catch {
            errorMessage = T("저장 실패: \(error.localizedDescription)",
                             "Failed to save: \(error.localizedDescription)")
            isFinished = false
        }
    }

    // MARK: 상태 갱신

    private func apply(_ readiness: EnrollmentCapturer.Readiness) {
        canCapture = (readiness == .ready)
        lastReadiness = readiness
        refreshGuidance()
    }

    private func applyHold(_ pose: FacePose?, _ fraction: Double) {
        holdingPose = pose
        holdProgress = fraction
        refreshGuidance()
    }

    private func refreshGuidance() {
        guard !isFinished else { return }
        switch lastReadiness {
        case .noFace:
            guidance = T("얼굴이 보이지 않습니다", "No face visible")
        case .poorQuality:
            guidance = T("얼굴이 너무 작거나 화면 가장자리에 있습니다",
                         "Face is too small or too close to the edge")
        case .ready:
            if let holdingPose {
                guidance = T("\(holdingPose.label) — 그대로 유지하세요",
                             "\(holdingPose.label) — hold still")
            } else {
                guidance = currentPose.instruction
            }
        }
    }

    private func record(_ pose: FacePose, _ vector: [Float]) {
        errorMessage = nil
        samples.removeAll { $0.pose == pose }
        samples.append(FaceSample(pose: pose, vector: vector))
        completed.insert(pose)
        holdingPose = nil
        holdProgress = 0

        let remaining = FacePose.allCases.filter { !completed.contains($0) }
        capturer?.setRemaining(remaining)

        guard let next = remaining.first else {
            isFinished = true
            guidance = T("촬영 완료 — ‘완료’를 누르면 저장됩니다", "All poses captured — press Done to save")
            stop()
            return
        }
        currentPose = next
        refreshGuidance()
    }
}
