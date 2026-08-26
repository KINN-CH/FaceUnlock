import AVFoundation
import CoreVideo
import Foundation

/// 내장 카메라 세션.
///
/// **잠금 상태에서만 켠다.** 상시 가동하면 카메라 표시등이 계속 켜져 있어
/// 사용자가 감시당한다고 느끼고, 배터리도 그만큼 먹는다.
final class CameraSession: NSObject {

    /// 프레임 콜백. `queue` 위에서 호출된다 (메인 스레드 아님).
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// 세션을 열지 못했을 때 한 번 호출된다.
    var onFailure: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "io.github.kinnch.FaceUnlock.camera")

    /// 얼굴 인식에 초당 30장은 필요 없다. 전력을 아끼려고 대략 10fps 로 솎는다.
    private let minimumFrameInterval: CFTimeInterval = 1.0 / 10.0
    private var lastFrameTime: CFTimeInterval = 0

    private var isConfigured = false

    var isRunning: Bool { session.isRunning }

    /// 등록 화면 미리보기용 레이어. 프레임 콜백과 별개로 동작한다.
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        // 거울처럼 보여야 사용자가 자기 움직임을 직관적으로 맞출 수 있다.
        // 미리보기에만 적용되고 분석 프레임에는 영향이 없다.
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        return layer
    }

    // MARK: 생명주기

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard Permissions.hasCamera else {
                self.onFailure?("카메라 권한이 없습니다.")
                return
            }
            if !self.isConfigured {
                guard self.configure() else { return }
                self.isConfigured = true
            }
            guard !self.session.isRunning else { return }
            self.lastFrameTime = 0
            self.session.startRunning()
            Log.camera.info("카메라 세션 시작")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            Log.camera.info("카메라 세션 정지")
        }
    }

    // MARK: 구성

    private func configure() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 640×480 이면 얼굴이 충분히 크게 잡히고 정렬 품질도 유지된다.
        session.sessionPreset = .vga640x480

        guard let device = Self.preferredDevice() else {
            onFailure?("사용 가능한 카메라를 찾지 못했습니다.")
            Log.camera.error("카메라 장치 없음")
            return false
        }

        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onFailure?("카메라를 열 수 없습니다.")
            Log.camera.error("AVCaptureDeviceInput 생성 실패")
            return false
        }
        session.addInput(input)

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        // 밀린 프레임을 붙잡고 있어봐야 낡은 얼굴이다. 최신 것만 본다.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(output) else {
            onFailure?("카메라 출력을 구성할 수 없습니다.")
            return false
        }
        session.addOutput(output)

        Log.camera.info("카메라 구성 완료: \(device.localizedName, privacy: .public)")
        return true
    }

    private static func preferredDevice() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .front)
        // 내장 카메라를 우선한다 — 외장 웹캠은 잠금 중에 꽂혀 있지 않을 수 있다.
        return discovery.devices.first { $0.deviceType == .builtInWideAngleCamera }
            ?? discovery.devices.first
            ?? AVCaptureDevice.default(for: .video)
    }
}

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= minimumFrameInterval else { return }
        lastFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
