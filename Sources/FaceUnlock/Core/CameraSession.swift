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
///
/// ── 카메라는 "켜졌다" 고 거짓말을 한다 ───────────────────────────────────
/// 세션을 하나로 합친 뒤에도 증상이 남았다. 짧은 간격으로 껐다 켜기를 반복하면
/// (인식 테스트 창의 "다시 시도") 서너 번째쯤에서 `startRunning()` 이 성공하고
/// `isRunning` 도 true 인데 **프레임이 한 장도 안 오는** 상태가 된다.
/// 미리보기는 검은 화면이고 얼굴은 영영 안 잡힌다. 런타임 오류 알림도,
/// 세션 중단 알림도 오지 않는다 — AVFoundation 은 이때 아무 말도 안 한다.
///
/// 그래서 이 클래스는 **자기가 켜졌다고 믿지 않는다.** 시작한 뒤
/// [firstFrameTimeout] 안에 프레임이 실제로 들어오는지 확인하고, 안 들어오면
/// 장치를 통째로 다시 연다([hardReset]). 껐다 켜는 것만으로는 이 상태에서
/// 빠져나오지 못하고 입력·출력을 떼어내야 장치가 살아난다.
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

    /// 시작 시도 일련번호. 예정된 첫 프레임 검사가 **그 시작에 대한 것인지**
    /// 구분한다. 이게 없으면 이미 정지·재시작된 뒤에 늦게 도착한 검사가
    /// 멀쩡히 도는 세션을 재개방해버린다.
    private var startGeneration = 0
    /// 시작 후 이 시간 안에 첫 프레임이 안 오면 장치가 죽은 것으로 본다.
    /// 내장 카메라는 정상이면 0.5초 안에 첫 장이 온다.
    private let firstFrameTimeout: CFTimeInterval = 2.0
    /// 장치 재개방 시도 횟수. 프레임이 한 장이라도 오면 0으로 돌아간다.
    private var resetAttempts = 0
    private let maxResetAttempts = 2
    /// 재개방 중에는 다른 복구 경로가 끼어들면 안 된다.
    /// (재개방이 부르는 `stopRunning()` 이 중단 알림을 띄우고, 그걸 받은
    ///  [scheduleRestart] 가 동시에 세션을 다시 켜려 든다.)
    private var isResetting = false

    /// 미리보기 레이어는 하나만 만들어 돌려 쓴다.
    ///
    /// 부를 때마다 새로 만들면 같은 세션에 연결만 계속 쌓인다. 쓰는 화면은
    /// 등록 마법사와 인식 테스트뿐이고 둘이 동시에 뜨지 않으므로 하나면 된다.
    private var previewLayer: AVCaptureVideoPreviewLayer?

    var isRunning: Bool { session.isRunning }

    private override init() {
        super.init()
        // 구성 시점이 아니라 여기서 등록한다. 재개방하면 구성을 다시 하는데,
        // 그때 또 등록하면 옵저버가 중복돼 복구가 두 배로 돈다.
        observeSession()
    }

    /// 등록 화면 미리보기용 레이어. 프레임 콜백과 별개로 동작한다.
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        if let previewLayer {
            // 레이어는 부모를 하나만 가진다. 이전 화면에서 떼어내야 새 화면에 붙는다.
            previewLayer.removeFromSuperlayer()
            return previewLayer
        }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        // 거울처럼 보여야 사용자가 자기 움직임을 직관적으로 맞출 수 있다.
        // 미리보기에만 적용되고 분석 프레임에는 영향이 없다.
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        previewLayer = layer
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
            self.resetAttempts = 0
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
            self.stopOnQueue()
        }
    }

    private func stopOnQueue() {
        owner = nil
        onFrame = nil
        onFailure = nil
        shouldBeRunning = false
        // 예정된 첫 프레임 검사를 무효화한다.
        startGeneration &+= 1
        guard session.isRunning else { return }
        session.stopRunning()
        Log.camera.info("카메라 세션 정지")
    }

    private func startOnQueue() {
        guard Permissions.hasCamera else {
            onFailure?("카메라 권한이 없습니다.")
            return
        }
        if !isConfigured {
            guard configure() else { return }
            isConfigured = true
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
        scheduleFirstFrameCheck()
    }

    // MARK: 첫 프레임 확인

    /// `isRunning == true` 를 믿지 않고 프레임이 실제로 오는지 확인한다.
    private func scheduleFirstFrameCheck() {
        startGeneration &+= 1
        let generation = startGeneration
        queue.asyncAfter(deadline: .now() + firstFrameTimeout) { [weak self] in
            guard let self,
                  self.shouldBeRunning,
                  generation == self.startGeneration else { return }
            // 한 장이라도 왔으면 장치는 살아 있다.
            guard self.secondsSinceLastFrame == nil else { return }
            Log.camera.error("세션은 도는데 프레임이 오지 않습니다 — 장치를 다시 엽니다")
            self.hardReset()
        }
    }

    /// 장치를 통째로 다시 연다.
    ///
    /// `stopRunning()` + `startRunning()` 만으로는 이 상태를 못 벗어난다.
    /// 입력·출력을 떼고 구성을 처음부터 다시 해야 장치가 실제로 열린다.
    private func hardReset() {
        guard !isResetting else { return }
        guard resetAttempts < maxResetAttempts else {
            Log.camera.error("장치를 다시 열지 못했습니다 — 포기")
            let failure = onFailure
            stopOnQueue()
            failure?("카메라가 응답하지 않습니다. 다른 앱이 카메라를 쓰고 있는지 확인해 주세요.")
            return
        }
        isResetting = true
        resetAttempts += 1
        Log.camera.info("장치 재개방 \(self.resetAttempts)/\(self.maxResetAttempts)")

        session.stopRunning()
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        isConfigured = false

        // 장치가 완전히 놓이기를 기다린다. 곧바로 다시 잡으면 같은 상태가 된다.
        queue.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            self.isResetting = false
            guard self.shouldBeRunning else { return }
            self.startOnQueue()
        }
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
            guard let self, self.shouldBeRunning,
                  !self.isResetting,          // 재개방이 알아서 다시 켠다
                  !self.session.isRunning else { return }
            guard self.restartAttempts < self.maxRestartAttempts else {
                Log.camera.error("카메라 복구 실패 — 재시도 상한 도달")
                let failure = self.onFailure
                self.stopOnQueue()
                failure?("카메라가 멈췄고 다시 시작하지 못했습니다.")
                return
            }
            self.restartAttempts += 1
            let attempt = self.restartAttempts
            Log.camera.info("카메라가 멈춰 다시 시작합니다 (\(attempt)/\(self.maxRestartAttempts))")
            // 장치가 놓이기를 잠깐 기다린다. 곧바로 다시 잡으면 또 실패한다.
            self.queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.shouldBeRunning, !self.isResetting else { return }
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
            stopOnQueue()
            return
        }

        frameLock.lock(); lastFrameAt = now; frameLock.unlock()
        // 프레임이 실제로 오고 있으니 복구 카운터를 되돌린다. 다음에 카메라가
        // 죽으면 다시 처음부터 시도할 수 있어야 한다.
        resetAttempts = 0
        restartAttempts = 0

        guard now - lastFrameTime >= minimumFrameInterval else { return }
        lastFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
