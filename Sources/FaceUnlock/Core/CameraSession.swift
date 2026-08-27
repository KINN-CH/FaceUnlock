import AVFoundation
import CoreVideo
import Foundation

/// 내장 카메라 세션. **앱 전체에서 하나뿐이다.**
///
/// **잠금 상태에서만 켠다.** 상시 가동하면 카메라 표시등이 계속 켜져 있어
/// 사용자가 감시당한다고 느끼고, 배터리도 그만큼 먹는다.
///
/// ── 왜 싱글턴인가 ────────────────────────────────────────────────────────
/// 카메라 장치는 하나인데 예전에는 `AVCaptureSession` 이 셋이었다 —
/// 잠금 해제 경로(AppState), 등록 마법사, 인식 테스트 창이 각자 만들었다.
/// 창을 닫았다 다시 열면 **이전 세션이 아직 장치를 놓지 않은 상태에서** 새
/// 세션이 `startRunning()` 을 부른다. 그러면 에러도 없이 표시등만 안 켜지고
/// 프레임이 한 장도 안 온다. "간헐적으로 카메라가 안 뜬다" 가 이것이었다.
///
/// 이제 세션은 하나고, 쓰는 쪽은 [start(owner:onFrame:onFailure:)] 로 빌린다.
/// 남이 빌려간 카메라를 실수로 끄지 않도록 [stop(owner:)] 는 소유자만 받는다.
final class CameraSession: NSObject {

    static let shared = CameraSession()

    /// 프레임 콜백. `queue` 위에서 호출된다 (메인 스레드 아님).
    private var onFrame: ((CVPixelBuffer) -> Void)?
    /// 세션을 열지 못했을 때 한 번 호출된다.
    private var onFailure: ((String) -> Void)?
    /// 지금 카메라를 빌려간 쪽. `queue` 위에서만 만진다.
    private weak var owner: AnyObject?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "io.github.kinnch.FaceUnlock.camera")

    /// 얼굴 인식에 초당 30장은 필요 없다. 전력을 아끼려고 대략 10fps 로 솎는다.
    private let minimumFrameInterval: CFTimeInterval = 1.0 / 10.0
    private var lastFrameTime: CFTimeInterval = 0

    /// 마지막으로 실제 프레임이 들어온 시각. 카메라 큐에서 쓰고 메인에서 읽으므로
    /// 잠금으로 감싼다.
    private let frameLock = NSLock()
    private var lastFrameAt: CFTimeInterval = 0

    /// 마지막 프레임 이후 지난 시간. 시작한 뒤 한 장도 못 받았으면 nil.
    ///
    /// 바깥에서 "카메라가 켜졌다고 해놓고 실제로는 죽어 있는" 상태를 알아내는
    /// 유일한 수단이다. `isRunning` 은 이때도 true 다.
    var secondsSinceLastFrame: CFTimeInterval? {
        frameLock.lock()
        defer { frameLock.unlock() }
        guard lastFrameAt > 0 else { return nil }
        return CACurrentMediaTime() - lastFrameAt
    }

    private var isConfigured = false

    /// 켜져 있어야 하는가. `queue` 위에서만 만진다.
    ///
    /// `session.isRunning` 과 다르다. 이건 **의도**고 저건 현실이다.
    /// 둘이 어긋난 순간(= 우리가 끄지 않았는데 꺼진 순간)이 복구해야 할 때다.
    private var shouldBeRunning = false
    /// 자동 복구 시도 횟수. 카메라가 아예 없거나 다른 앱이 붙잡고 있으면
    /// 무한히 되살리려 들면서 로그만 채우므로 상한을 둔다.
    private var restartAttempts = 0
    private let maxRestartAttempts = 3

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

    /// 카메라를 빌린다.
    ///
    /// 이미 다른 쪽이 쓰고 있으면 **넘겨받는다**. 마지막에 요청한 쪽이 이긴다 —
    /// 실제 잠금 해제 경로가 진단용 창보다 나중에 시작되는 게 정상 순서다.
    /// (인식 테스트 창은 화면이 잠기면 스스로 놓기도 한다.)
    func start(owner: AnyObject,
               onFrame: @escaping (CVPixelBuffer) -> Void,
               onFailure: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if let previous = self.owner, previous !== owner {
                Log.camera.info("카메라 소유자 교체")
            }
            self.owner = owner
            self.onFrame = onFrame
            self.onFailure = onFailure
            self.shouldBeRunning = true
            self.restartAttempts = 0
            self.startOnQueue()
        }
    }

    /// 빌린 쪽만 끌 수 있다. 남이 쓰는 중이면 아무 일도 하지 않는다.
    func stop(owner: AnyObject) {
        queue.async { [weak self] in
            guard let self else { return }
            // 소유자가 이미 사라졌으면(창이 닫히며 해제됨) 아무나 끌 수 있어야 한다.
            // 그렇지 않으면 표시등이 켜진 채로 남는다.
            guard self.owner == nil || self.owner === owner else { return }
            self.owner = nil
            self.onFrame = nil
            self.onFailure = nil
            self.shouldBeRunning = false
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            Log.camera.info("카메라 세션 정지")
        }
    }

    private func startOnQueue() {
        guard Permissions.hasCamera else {
            onFailure?("카메라 권한이 없습니다.")
            return
        }
        if !isConfigured {
            guard configure() else { return }
            isConfigured = true
            observeSession()
        }
        guard !session.isRunning else { return }
        lastFrameTime = 0
        frameLock.lock(); lastFrameAt = 0; frameLock.unlock()
        session.startRunning()

        // `startRunning()` 은 실패해도 에러를 던지지 않는다. 그냥 안 돌아간다.
        // 여기서 확인하지 않으면 "카메라 세션 시작" 이라고 로그만 찍어놓고
        // 프레임은 한 장도 안 오는 상태가 되고, 그게 곧 "카메라가 안 켜진다" 다.
        guard session.isRunning else {
            Log.camera.error("startRunning() 이후에도 세션이 돌지 않습니다")
            onFailure?("카메라를 시작하지 못했습니다. 다른 앱이 사용 중일 수 있습니다.")
            return
        }
        Log.camera.info("카메라 세션 시작")
    }

    // MARK: 자동 복구

    /// 카메라는 우리가 끄지 않아도 꺼진다.
    ///
    /// 절전에서 깨어날 때, 다른 앱(FaceTime·Photo Booth·회의 앱)이 장치를
    /// 가져갈 때, 외장 카메라가 빠질 때 세션이 조용히 멈춘다. 예전에는 그걸
    /// 아무도 알아채지 못해서 표시등이 안 켜진 채로 계속 기다리기만 했다.
    private func observeSession() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                           name: .AVCaptureSessionRuntimeError, object: session)
        center.addObserver(self, selector: #selector(sessionDidStopRunning(_:)),
                           name: .AVCaptureSessionDidStopRunning, object: session)
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let reason = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?
            .localizedDescription ?? "알 수 없음"
        Log.camera.error("카메라 런타임 오류: \(reason, privacy: .public)")
        scheduleRestart()
    }

    @objc private func sessionDidStopRunning(_ note: Notification) {
        scheduleRestart()
    }

    private func scheduleRestart() {
        queue.async { [weak self] in
            guard let self, self.shouldBeRunning, !self.session.isRunning else { return }
            guard self.restartAttempts < self.maxRestartAttempts else {
                Log.camera.error("카메라 복구 실패 — 재시도 상한 도달")
                self.shouldBeRunning = false
                self.onFailure?("카메라가 멈췄고 다시 시작하지 못했습니다.")
                return
            }
            self.restartAttempts += 1
            let attempt = self.restartAttempts
            Log.camera.info("카메라가 멈춰 다시 시작합니다 (\(attempt)/\(self.maxRestartAttempts))")
            // 장치가 놓이기를 잠깐 기다린다. 곧바로 다시 잡으면 또 실패한다.
            self.queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.shouldBeRunning else { return }
                self.startOnQueue()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        // 빌려간 쪽이 stop 도 못 부르고 사라졌다. 표시등을 끄고 나온다.
        if owner == nil && shouldBeRunning {
            Log.camera.info("카메라 소유자가 사라져 세션을 정지합니다")
            shouldBeRunning = false
            session.stopRunning()
            onFrame = nil
            onFailure = nil
            return
        }

        frameLock.lock(); lastFrameAt = now; frameLock.unlock()

        guard now - lastFrameTime >= minimumFrameInterval else { return }
        lastFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
