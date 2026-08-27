import AVFoundation
import CoreGraphics
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
/// 더 나쁜 건 프레임이 잠깐 오다가 1~3초 뒤에 끊기는 경우다. "테스트가 두
/// 번은 되다가 세 번째부터 검은 화면" 이 그것이었다.
///
/// 그래서 이 클래스는 **자기가 켜졌다고 믿지 않는다.** 도는 동안 내내
/// 프레임이 실제로 들어오는지 감시하고([startWatchdog]), 첫 장이 안 오거나
/// 오던 게 끊기면 장치를 통째로 다시 연다([hardReset]). 껐다 켜는 것만으로는
/// 이 상태에서 빠져나오지 못하고 입력·출력을 떼어내야 장치가 살아난다.
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

    /// 프레임 솎는 간격 — 대략 20fps.
    ///
    /// 예전에는 10fps 였다. 전력을 아끼려는 값이었는데 **깜빡임을 놓친다.**
    /// 실측한 눈 감김 길이는 105·124·126·132·234·248ms 였다. 100ms 짜리
    /// 깜빡임은 10fps(100ms 간격)에서 눈 감긴 프레임이 한 장도 안 잡힐 수
    /// 있고, 그러면 사용자는 분명히 깜빡였는데 아무 일도 안 일어난다.
    /// 20fps면 가장 짧은 깜빡임도 2장쯤 잡힌다.
    ///
    /// 늦게 도착한 프레임은 버려지므로([alwaysDiscardsLateVideoFrames])
    /// 처리가 밀려도 큐에 쌓이지 않는다 — 느려질 뿐 고장나지 않는다.
    private let minimumFrameInterval: CFTimeInterval = 1.0 / 20.0
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
    /// 지금 열려 있는 장치. 포맷을 다시 고정할 때 쓴다 (탐색을 매번 돌리지 않는다).
    private var activeDevice: AVCaptureDevice?

    /// 켜져 있어야 하는가. `queue` 위에서만 만진다.
    ///
    /// `session.isRunning` 과 다르다. 이건 **의도**고 저건 현실이다.
    /// 둘이 어긋난 순간(= 우리가 끄지 않았는데 꺼진 순간)이 복구해야 할 때다.
    private var shouldBeRunning = false
    /// 자동 복구 시도 횟수. 카메라가 아예 없거나 다른 앱이 붙잡고 있으면
    /// 무한히 되살리려 들면서 로그만 채우므로 상한을 둔다.
    private var restartAttempts = 0
    private let maxRestartAttempts = 3

    /// 시작 시도 일련번호. 예정된 감시가 **그 시작에 대한 것인지** 구분한다.
    /// 이게 없으면 이미 정지·재시작된 뒤에 늦게 도착한 감시가 멀쩡히 도는
    /// 세션을 재개방해버린다.
    private var startGeneration = 0
    /// 이번 시작 시각. 첫 프레임을 얼마나 기다렸는지 재는 기준.
    private var startedAt: CFTimeInterval = 0
    /// 시작 후 이 시간 안에 첫 프레임이 안 오면 장치가 죽은 것으로 본다.
    /// 내장 카메라는 정상이면 0.3초 안에 첫 장이 온다.
    private let firstFrameTimeout: CFTimeInterval = 1.5
    /// 잘 오던 프레임이 이 시간 동안 끊기면 역시 죽은 것으로 본다.
    /// 20fps 로 받으므로 정상이라면 간격이 0.05초를 넘지 않는다 — 0.8초면
    /// 열여섯 장을 놓친 것이라 오탐이 아니다.
    ///
    /// 예전엔 2초였다. 잠금화면에서는 스트림이 1초쯤마다 먹통이 되는데
    /// (아래 [applyLightestFormat] 참조) 2초를 기다렸다가 0.7초를 더 쉬면
    /// 실제로 프레임을 받는 시간이 전체의 1/4도 안 됐다. 깜빡임 챌린지가
    /// 12초 안에 끝날 수가 없었다.
    private let stallTimeout: CFTimeInterval = 0.8
    /// 감시 주기.
    private let watchdogInterval: CFTimeInterval = 0.25
    /// 장치 재개방 시도 횟수.
    private var resetAttempts = 0
    private let maxResetAttempts = 3
    /// 화면 절전으로 프레임이 멈췄다는 안내를 이미 남겼는가.
    /// 0.5초마다 같은 줄을 찍으면 로그가 못 쓰게 된다.
    private var reportedDisplaySleepStall = false
    /// 이번 시작에서 받은 프레임 수. 복구 예산을 되돌릴지 판단한다.
    private var framesThisStart = 0
    /// 한 번의 시작에서 이만큼 받았으면 "장치는 살아 있다" 로 본다.
    ///
    /// 예전에는 **5초를 연속으로** 버텨야 예산을 되돌렸다. 그런데 잠금화면
    /// 에서는 시스템 필터가 1초 남짓마다 스트림을 삼켜버려서 5초를 채울
    /// 방법이 없었다. 그래서 세 번 만에 예산이 바닥나고 "카메라가 응답하지
    /// 않습니다" 로 끝났다 — 매번 프레임을 스무 장씩 잘 받아놓고도.
    ///
    /// 한 장도 못 받은 채 세 번 실패하는 **진짜 죽은 장치**와, 짧게라도
    /// 계속 주는 장치를 가르는 기준이 이것이다. 앞엣것은 여전히 포기하고,
    /// 뒤엣것은 될 때까지 다시 연다.
    private let usableBurstFrames = 5
    /// 재개방 중에는 다른 복구 경로가 끼어들면 안 된다.
    /// (재개방이 부르는 `stopRunning()` 이 중단 알림을 띄우고, 그걸 받은
    ///  [scheduleRestart] 가 동시에 세션을 다시 켜려 든다.)
    private var isResetting = false

    /// 미리보기를 보고 있는 화면 수. 0이면 변환 비용을 아예 들이지 않는다 —
    /// 잠금화면 인증에는 미리보기가 없다.
    private let previewLock = NSLock()
    private var previewViewers = 0
    private var lastPreviewTime: CFTimeInterval = 0
    /// 미리보기는 15fps면 눈에 부드럽다. 분석 프레임과 따로 솎는다.
    private let previewInterval: CFTimeInterval = 1.0 / 15.0

    var isRunning: Bool { session.isRunning }

    private override init() {
        super.init()
        // 구성 시점이 아니라 여기서 등록한다. 재개방하면 구성을 다시 하는데,
        // 그때 또 등록하면 옵저버가 중복돼 복구가 두 배로 돈다.
        observeSession()
    }

    // MARK: 미리보기

    /// 미리보기를 켠다. 화면이 사라지면 반드시 [endPreview] 를 부른다.
    ///
    /// 프레임을 세션에서 따로 뽑지 않고 **분석용과 같은 프레임**을 CGImage 로
    /// 복사해 [PreviewFeed] 로 보낸다. 왜 `AVCaptureVideoPreviewLayer` 를
    /// 버렸는지는 [PreviewFeed] 주석에 적어두었다 — 요약하면, 그 레이어는
    /// 장치를 다시 열면 되살아나지 않아서 검은 화면으로 남는다.
    func beginPreview() {
        previewLock.lock()
        previewViewers += 1
        previewLock.unlock()
    }

    func endPreview() {
        previewLock.lock()
        previewViewers = max(0, previewViewers - 1)
        let noneLeft = previewViewers == 0
        previewLock.unlock()
        if noneLeft { PreviewFeed.shared.clear() }
    }

    private var wantsPreview: Bool {
        previewLock.lock()
        defer { previewLock.unlock() }
        return previewViewers > 0
    }

    /// 프레임을 미리보기로 흘려보낸다. 보는 사람이 없으면 아무 일도 안 한다.
    private func publishPreview(_ buffer: CVPixelBuffer, now: CFTimeInterval) {
        guard wantsPreview, now - lastPreviewTime >= previewInterval else { return }
        lastPreviewTime = now
        guard let image = Self.makeImage(from: buffer) else { return }
        PreviewFeed.shared.publish(image)
    }

    /// BGRA 픽셀 버퍼를 CGImage 로 **복사**한다.
    ///
    /// `makeImage()` 는 비트맵을 복사하므로 버퍼를 놓아준 뒤에도 안전하다.
    /// 버퍼 자체는 곧 재사용되니 참조만 넘기면 화면이 찢어진다.
    private static func makeImage(from buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let context = CGContext(
            data: base,
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        return context?.makeImage()
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
        // 예정된 감시를 무효화한다.
        startGeneration &+= 1
        guard session.isRunning else { return }
        session.stopRunning()
        Log.camera.info("카메라 세션 정지")
    }

    private func startOnQueue() {
        guard Permissions.hasCamera else {
            onFailure?(T("카메라 권한이 없습니다.", "Camera permission is missing."))
            return
        }
        if !isConfigured {
            guard configure() else { return }
            isConfigured = true
        }
        guard !session.isRunning else { return }
        lastFrameTime = 0
        framesThisStart = 0
        startedAt = CACurrentMediaTime()
        frameLock.lock(); lastFrameAt = 0; frameLock.unlock()
        session.startRunning()

        // `startRunning()` 은 실패해도 에러를 던지지 않는다. 그냥 안 돌아간다.
        // 여기서 확인하지 않으면 "카메라 세션 시작" 이라고 로그만 찍어놓고
        // 프레임은 한 장도 안 오는 상태가 되고, 그게 곧 "카메라가 안 켜진다" 다.
        guard session.isRunning else {
            Log.camera.error("startRunning() 이후에도 세션이 돌지 않습니다")
            onFailure?(T("카메라를 시작하지 못했습니다. 다른 앱이 사용 중일 수 있습니다.", "Could not start the camera. Another app may be using it."))
            return
        }
        Log.camera.info("카메라 세션 시작")
        // **세션이 돈 뒤에** 포맷을 고정한다. 순서가 왜 중요한지는
        // [applyLightestFormat] 주석에 적어두었다.
        if let activeDevice { Self.applyLightestFormat(to: activeDevice) }
        startWatchdog()
    }

    // MARK: 프레임 감시

    /// `isRunning == true` 를 믿지 않고 프레임이 실제로 오는지 **계속** 확인한다.
    ///
    /// 처음에는 첫 프레임만 확인했는데, 그걸로는 부족했다. 실제 로그를 보면
    /// 카메라는 켜지고 프레임도 잠깐 오다가 **1~3초 뒤에 끊긴다.** 첫 장이
    /// 도착한 순간 검사가 끝나버리니 그 뒤의 죽음은 아무도 못 봤고,
    /// 한 번 검게 변하면 영영 돌아오지 않았다.
    private func startWatchdog() {
        reportedDisplaySleepStall = false
        startGeneration &+= 1
        scheduleWatchdogTick(startGeneration)
    }

    private func scheduleWatchdogTick(_ generation: Int) {
        queue.asyncAfter(deadline: .now() + watchdogInterval) { [weak self] in
            guard let self,
                  self.shouldBeRunning,
                  !self.isResetting,
                  generation == self.startGeneration else { return }

            if let idle = self.secondsSinceLastFrame {
                if idle > self.stallTimeout {
                    // 화면이 자면 카메라도 같이 잔다. 이건 고장이 아니라
                    // 정상이므로 장치를 다시 열어봐야 소용없다 — 실제로
                    // 잠금 버튼을 누를 때마다 재개방을 세 번 하고 실패했다.
                    // 복구 예산은 진짜 먹통이 된 장치를 위해 남겨둔다.
                    guard Self.anyDisplayAwake() else {
                        if !self.reportedDisplaySleepStall {
                            self.reportedDisplaySleepStall = true
                            Log.camera.info("화면이 꺼져 프레임이 멈췄습니다 — 정상, 화면이 켜지면 재개됩니다")
                        }
                        self.scheduleWatchdogTick(generation)
                        return
                    }
                    Log.camera.error("프레임이 \(Int(idle * 1000))ms 째 끊겼습니다 (\(Self.environmentSummary(), privacy: .public)) — 장치를 다시 엽니다")
                    self.hardReset()
                    return
                }
            } else if CACurrentMediaTime() - self.startedAt > self.firstFrameTimeout {
                Log.camera.error("시작 후 첫 프레임이 오지 않습니다 (\(Self.environmentSummary(), privacy: .public)) — 장치를 다시 엽니다")
                self.hardReset()
                return
            }
            self.scheduleWatchdogTick(generation)
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
            failure?(T("카메라가 응답하지 않습니다. 다른 앱이 카메라를 쓰고 있는지 확인해 주세요.", "The camera is not responding. Check whether another app is using it."))
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
        // 0.4초면 충분하다 (0.7초에서 줄였다 — 잠금화면에서는 이 쉬는 시간이
        // 곧 인증이 멈춰 있는 시간이다).
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
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
        center.addObserver(self, selector: #selector(sessionWasInterrupted(_:)),
                           name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                           name: AVCaptureSession.interruptionEndedNotification, object: session)
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

    /// 프레임이 끊긴 **순간의 주변 상황**. 원인을 좁히는 데 쓴다.
    ///
    /// 인식 테스트 창(화면 켜짐·잠금 해제)에서는 멀쩡한데 잠금화면에서만
    /// 0.7초 만에 끊긴다면, 카메라 자체가 아니라 잠금·절전 쪽에서 뭔가
    /// 장치를 가져가는 것이다. 그걸 구분하려고 남긴다.
    /// 켜져 있는 디스플레이가 하나라도 있는가.
    ///
    /// 목록을 못 얻으면 "켜져 있다" 로 센다. 여기서 "꺼졌다" 로 넘어가면
    /// 진짜 먹통이 된 장치를 복구하지 않고 넘어가게 된다.
    private static func anyDisplayAwake() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return true }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return true }
        return ids.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 }
    }

    private static func environmentSummary() -> String {
        var displays = "디스플레이 알 수 없음"
        var count: UInt32 = 0
        if CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            if CGGetActiveDisplayList(count, &ids, &count) == .success {
                let awake = ids.prefix(Int(count)).filter { CGDisplayIsAsleep($0) == 0 }.count
                displays = "디스플레이 \(awake)/\(count) 켜짐"
            }
        }
        let locked = LockMonitor.screenIsLockedNow() ? "잠김" : "해제됨"
        return "\(displays), 화면 \(locked)"
    }

    @objc private func sessionWasInterrupted(_ note: Notification) {
        // 이유 키(AVCaptureSessionInterruptionReasonKey)는 iOS 전용이라 여기서는
        // 못 쓴다. 그래도 "중단됐다" 는 사실만으로 우리 코드 문제인지
        // 시스템이 장치를 가져간 것인지 갈린다.
        Log.camera.error("카메라 세션 중단됨 (\(Self.environmentSummary(), privacy: .public))")
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        Log.camera.info("카메라 세션 중단 해제됨")
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
                failure?(T("카메라가 멈췄고 다시 시작하지 못했습니다.", "The camera stalled and could not be restarted."))
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

        guard let device = Self.preferredDevice() else {
            onFailure?(T("사용 가능한 카메라를 찾지 못했습니다.", "No usable camera was found."))
            Log.camera.error("카메라 장치 없음")
            return false
        }

        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onFailure?(T("카메라를 열 수 없습니다.", "Could not open the camera."))
            Log.camera.error("AVCaptureDeviceInput 생성 실패")
            return false
        }
        session.addInput(input)
        activeDevice = device

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        // 밀린 프레임을 붙잡고 있어봐야 낡은 얼굴이다. 최신 것만 본다.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(output) else {
            onFailure?(T("카메라 출력을 구성할 수 없습니다.", "Could not configure the camera output."))
            return false
        }
        session.addOutput(output)

        Log.camera.info("카메라 구성 완료: \(device.localizedName, privacy: .public)")
        return true
    }

    /// 장치를 **가장 가벼운 포맷**으로 고정한다.
    ///
    /// 예전에는 `sessionPreset = .vga640x480` 만 지정했다. 그런데 이 맥북의
    /// 내장 카메라에는 640×480 포맷이 아예 없다 (제일 작은 게 1280×720).
    /// 그러면 macOS 는 카메라를 **1920×1080 24fps** 로 돌리고 스케일러를
    /// 붙여 640×480 을 만들어 준다 — 우리가 쓰지도 않는 화소를 ISP 가
    /// 만들어내고, 그 위에 시스템의 시간축 잡음 필터(MLVNR/MCTF)까지 얹힌다.
    ///
    /// 잠금화면에서 바로 이 필터가 프레임마다 `-6689` 로 실패하면서 **입력
    /// 버퍼를 통째로 삼켰다.** 카메라는 24fps 로 멀쩡히 돌고 있는데 앱에는
    /// 한 장도 오지 않는 상태 — "잠금화면에서 해제가 안 된다" 가 이것이었다.
    /// (잠금 3초 동안 오류 37건, 잠금 해제 5초 동안 0건으로 확인했다.)
    ///
    /// 필터는 시스템 데몬 안에 있어 끌 수 없다. macOS 에서 켜고 끌 수 있는
    /// 효과는 센터 스테이지뿐이고 나머지는 읽기 전용이다. 그래서 우리가 쥔
    /// 손잡이는 **필터가 처리할 양** 하나뿐이다. 1280×720 20fps 는
    /// 1920×1080 24fps 의 1/2.7 이다. 덤으로 스케일러가 빠지고 전력도 준다.
    ///
    /// 20fps 인 이유: 분석도 20fps 로 솎으므로 남는 프레임을 안 만들고,
    /// 가장 짧은 깜빡임(실측 105ms)도 두 장쯤 잡힌다. 15fps 로 더 내리면
    /// 그 깜빡임이 한 장에 걸칠 수 있어 [minimumFrameInterval] 의 근거가
    /// 무너진다.
    ///
    /// ── **`startRunning()` 뒤에 불러야 한다** ────────────────────────────
    /// 세션 프리셋이 `.high` 로 남아 있으면 `commitConfiguration()` 이
    /// activeFormat 을 도로 1920×1080 으로 돌려놓는다. 프리셋을
    /// InputPriority 로 바꾸면 세션이 양보하지만, macOS 에서는
    /// `canSetSessionPreset` 이 그 프리셋에 false 를 준다 — 실제로 확인했다.
    ///
    /// 반면 **세션이 이미 돌고 있을 때 지정하면 그대로 남는다.** 로그로
    /// 확인한 순서는 이랬다:
    ///   구성 중 지정 → 커밋 후 1920×1080 (되돌아감)
    ///   시작 후 지정 → 1280×720, 실제 프레임도 1280×720 (유지됨)
    /// 그래서 [startOnQueue] 가 세션을 켠 다음에 이걸 부른다.
    private static func applyLightestFormat(to device: AVCaptureDevice) {
        guard let format = device.formats.min(by: { pixelCount(of: $0) < pixelCount(of: $1) }),
              (try? device.lockForConfiguration()) != nil else {
            Log.camera.info("포맷을 고정하지 못했습니다 — 시스템 기본값으로 진행합니다")
            return
        }
        defer { device.unlockForConfiguration() }

        device.activeFormat = format
        // 원하는 20fps 가 이 포맷의 지원 범위 밖일 수 있다. 범위 안으로 접는다.
        let ranges = format.videoSupportedFrameRateRanges
        let lowest = ranges.map(\.minFrameRate).min() ?? 20
        let highest = ranges.map(\.maxFrameRate).max() ?? 20
        let fps = min(max(20, lowest), highest)
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration

        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        Log.camera.info("포맷 고정: \(size.width)×\(size.height) @\(Int(fps.rounded()))fps")
    }

    private static func pixelCount(of format: AVCaptureDevice.Format) -> Int32 {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return size.width * size.height
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

        // 이번 시작에서 쓸 만큼 받았으면 복구 예산을 되돌린다. 근거는
        // [usableBurstFrames] 주석 참조 — 짧게 끊기더라도 프레임을 주는
        // 장치는 계속 다시 열어야 하고, 한 장도 안 주는 장치는 포기해야 한다.
        framesThisStart += 1
        if framesThisStart == usableBurstFrames {
            resetAttempts = 0
            restartAttempts = 0
        }

        guard now - lastFrameTime >= minimumFrameInterval else { return }
        lastFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        publishPreview(pixelBuffer, now: now)
        onFrame?(pixelBuffer)
    }
}
