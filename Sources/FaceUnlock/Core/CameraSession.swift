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

    /// 초당 프레임 수와 평균 밝기. 카메라 큐에서만 만진다.
    ///
    /// 왜 밝기까지 재는가: "검은 화면" 신고가 두 가지 전혀 다른 상태를
    /// 가리킨다. 프레임이 아예 안 오는 것과, **프레임은 오는데 내용이
    /// 새까만 것**이다. 앞엣것은 장치 문제고 뒤엣것은 노출 문제라 고칠
    /// 곳이 다른데, 로그만 봐서는 구분이 안 됐다. 밝기 한 숫자면 갈린다.
    /// (0=완전한 검정, 255=완전한 흰색. 실내 얼굴은 보통 60~140 근처다.)
    private var healthTickStartedAt: CFTimeInterval = 0
    private var framesInHealthTick = 0
    private var brightnessSum = 0.0
    /// **프레임은 정상 속도로 오는데 내용만 새까만** 상태를 세는 칸.
    ///
    /// 감시견은 프레임이 *끊겼을 때만* 장치를 다시 연다. 그런데 잠금화면에서
    /// 냉시동한 세션은 초당 13~15장을 주면서 평균 밝기 0을 15초 내내 유지했다
    /// — 감시견이 보기에는 완벽히 건강한 스트림이라 아무 일도 하지 않았고,
    /// 사용자에게는 "그냥 안 된다" 로만 보였다. 최소한 말은 해야 한다.
    /// 진단 모드. `defaults write io.github.kinnch.FaceUnlock diagnostics -bool YES`
    ///
    /// 켜면 새까만 프레임을 만났을 때 바로 포기하지 않고, 60초 동안 매초
    /// 장치·연결·세션 상태를 남기면서 5·15·30초에 장치를 다시 연다.
    /// 짧은 간격(0.4초) 재개방은 이미 실패로 확인됐으므로 간격을 벌렸다.
    static let diagnostics = UserDefaults.standard.bool(forKey: "diagnostics")

    private var blackProbeStartedAt: CFTimeInterval = 0
    private var blackProbeResets = 0

    private var blackTicks = 0
    private let blackTickLimit = 4
    private var failingOnBlackFrames = false

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
        let count = previewViewers
        previewLock.unlock()
        Log.camera.info("미리보기 켜짐 (보는 화면 \(count)개)")
    }

    func endPreview() {
        previewLock.lock()
        previewViewers = max(0, previewViewers - 1)
        let noneLeft = previewViewers == 0
        let count = previewViewers
        previewLock.unlock()
        Log.camera.info("미리보기 꺼짐 (보는 화면 \(count)개)")
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
        guard let image = Self.makeImage(from: buffer) else {
            Log.camera.error("미리보기 프레임을 이미지로 바꾸지 못했습니다")
            return
        }
        if !publishedPreviewFrame {
            publishedPreviewFrame = true
            Log.camera.info("미리보기 첫 프레임 \(image.width)×\(image.height)")
        }
        PreviewFeed.shared.publish(image)
    }

    /// 이번 시작에서 미리보기로 한 장이라도 내보냈는가. 로그를 한 번만 찍기 위한 것.
    private var publishedPreviewFrame = false

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

    /// 고를 카메라가 바뀌었다. 지금 구성을 버리고 다시 고르게 한다.
    ///
    /// **왜 필요한가**: 세션 구성은 한 번만 하고 그 뒤로는 재사용한다
    /// ([startOnQueue] 의 `isConfigured`). 그래서 설정에서 카메라를 바꿔도 이미
    /// 열린 장치가 그대로 다시 열렸다 — 아이폰 카메라를 한 번 고르면 내장으로
    /// 되돌려도 앱을 다시 켜기 전까지 계속 아이폰이 켜졌다.
    ///
    /// 돌고 있던 중이면 그 자리에서 다시 켠다. 인식 테스트 창을 열어둔 채
    /// 카메라를 바꾸면 미리보기가 바로 바뀌어야 고른 게 먹었는지 알 수 있다.
    func reconfigureForNewDevice() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isConfigured else { return }

            // 재개방과 같은 절차다. 도는 동안 감시견이 끼어들지 않게 막는다.
            self.isResetting = true
            self.session.stopRunning()
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.session.commitConfiguration()
            self.isConfigured = false
            self.activeDevice = nil
            Log.camera.info("카메라 설정이 바뀌어 구성을 버립니다")

            // 장치가 완전히 놓이기를 기다린다 — [hardReset] 과 같은 이유.
            self.queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                self.isResetting = false
                guard self.shouldBeRunning else { return }
                self.resetAttempts = 0
                self.startOnQueue()
            }
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
        publishedPreviewFrame = false
        healthTickStartedAt = CACurrentMediaTime()
        framesInHealthTick = 0
        brightnessSum = 0
        blackTicks = 0
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
        // 포맷은 건드리지 않는다 — 시스템 기본값(1920×1080)으로 둔다.
        // 이유는 [logActiveFormat] 주석 참조.
        if let activeDevice { Self.logActiveFormat(of: activeDevice) }
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
                // 화면이 자는 동안 연 장치는 첫 프레임을 주지 않는다. 그건
                // 고장이 아니다. 여기서 예산을 태우면 화면이 켜졌을 때
                // 쓸 재개방이 남지 않는다 — 덮개 실측(16:16:01~09)에서
                // 정확히 세 번을 다 쓰고 포기했다.
                guard Self.anyDisplayAwake() else {
                    if !self.reportedDisplaySleepStall {
                        self.reportedDisplaySleepStall = true
                        Log.camera.info("화면이 꺼져 있어 첫 프레임을 기다립니다 — 정상")
                    }
                    self.scheduleWatchdogTick(generation)
                    return
                }
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
            let black = failingOnBlackFrames
            failingOnBlackFrames = false
            stopOnQueue()
            // 원인이 다르면 안내도 달라야 한다. 검은 프레임을 두고
            // "다른 앱이 쓰는 중" 이라고 하면 엉뚱한 데를 찾게 된다.
            if black {
                failure?(T("카메라가 검은 화면만 보내고 있습니다. 맥을 다시 시작하면 대부분 해결됩니다.",
                           "The camera is only sending black frames. Restarting your Mac usually clears this."))
            } else {
                failure?(T("카메라가 응답하지 않습니다. 다른 앱이 카메라를 쓰고 있는지 확인해 주세요.", "The camera is not responding. Check whether another app is using it."))
            }
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
        let info = note.userInfo?.map { "\($0.key)=\($0.value)" }.joined(separator: " ") ?? "정보 없음"
        Log.camera.error("카메라 세션 중단됨 (\(Self.environmentSummary(), privacy: .public)) userInfo: \(info, privacy: .public)")
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

    /// 활성 포맷을 로그로 남기기만 한다. **바꾸지 않는다.**
    ///
    /// 한때 여기서 가장 가벼운 포맷(1280×720 @20fps)으로 고정했다. 이유는
    /// 이랬다 — 이 맥북에는 640×480 포맷이 없어서 `.vga640x480` 프리셋을
    /// 주면 macOS 가 1920×1080 24fps 로 돌리고 스케일러를 붙인다. 그 위에
    /// 시스템 시간축 잡음 필터(MLVNR/MCTF)가 얹히는데, 잠금화면에서 그게
    /// 프레임마다 `-6689` 로 실패하며 입력 버퍼를 통째로 삼켰다. 화소를
    /// 줄이면 필터가 처리할 양이 줄어 증상이 사라졌다.
    ///
    /// 그런데 고정한 뒤로 **다른 증상**이 나타났다. 화면만 껐다 켠 직후에
    /// 장치를 열면 프레임은 초당 13~15장 정상으로 오는데 전 픽셀이 0이다
    /// (2026-08-28 16:21:49~58 실측). 장치를 통째로 다시 열어도 안 뚫린다.
    ///
    /// 결정적인 대조군: 같은 카메라를 **기본 포맷 그대로** 쓰는 별도
    /// 프로세스(CamProbe)는 잠금 전·잠금 중·잠금 경계를 넘나들며 단 한 번도
    /// 검게 나온 적이 없다(밝기 125, 24~25fps). 두 코드의 남은 차이가
    /// 포맷 고정 하나뿐이라 그것을 뺀다.
    ///
    /// **되돌리기 전에 확인할 것**: 이걸 다시 켜서 해결하려는 증상이
    /// "프레임이 아예 안 온다" 인지 "프레임은 오는데 새까맣다" 인지 보라.
    /// 둘은 원인이 다르고, 포맷 고정은 앞의 것만 고친다.
    private static func logActiveFormat(of device: AVCaptureDevice) {
        let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let fps = Int((1.0 / CMTimeGetSeconds(device.activeVideoMinFrameDuration)).rounded())
        Log.camera.info("활성 포맷: \(size.width)×\(size.height) @\(fps)fps (시스템 기본값)")
    }

    /// 고를 수 있는 카메라 목록. 설정 화면의 선택 목록도 이 함수를 쓴다 —
    /// 목록을 만드는 곳과 고르는 곳이 갈라지면 언젠가 어긋난다.
    ///
    /// `position` 을 `.front` 로 좁히면 **외장 웹캠이 통째로 빠진다.**
    /// 외장 장치는 위치를 `.unspecified` 로 보고하기 때문이다. 예전 코드는
    /// `.front` 로 찾아놓고 그 뒤에서 외장으로 폴백하려 했는데, 그 폴백은
    /// 애초에 걸릴 장치가 없어 한 번도 동작하지 않았다.
    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified).devices
    }

    /// 지금 규칙대로면 어느 장치를 열게 되는가.
    ///
    /// 설정 화면과 인식 테스트 창도 이 함수를 불러 "지금 쓰는 카메라" 를
    /// 표시한다. 표시용 규칙을 따로 만들면 실제로 열리는 장치와 어긋난다.
    static func preferredDevice() -> AVCaptureDevice? {
        let devices = availableDevices()

        // 사용자가 고른 장치가 있으면 그것을 쓴다. 이 함수는 카메라 큐에서
        // 불리고 `Settings` 는 @MainActor 라 여기서 읽을 수 없으므로,
        // 스레드 안전한 UserDefaults 를 같은 키 상수로 직접 본다.
        if let chosen = UserDefaults.standard.string(forKey: Settings.preferredCameraIDKey) {
            if let device = devices.first(where: { $0.uniqueID == chosen }) {
                return device
            }
            // 지정한 웹캠을 빼놓고 잠갔다고 얼굴 해제가 통째로 죽으면 안 된다.
            // 자동 규칙으로 물러서되, 왜 다른 카메라가 켜졌는지는 남긴다.
            Log.camera.info("지정한 카메라가 연결되어 있지 않아 자동 선택으로 물러섭니다")
        }

        // 내장 카메라를 우선한다 — 외장 웹캠은 잠금 중에 꽂혀 있지 않을 수 있다.
        return devices.first { $0.deviceType == .builtInWideAngleCamera }
            ?? devices.first
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
            failingOnBlackFrames = false
            restartAttempts = 0
        }

        guard now - lastFrameTime >= minimumFrameInterval else { return }
        lastFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        logFrameHealth(pixelBuffer, now: now)
        publishPreview(pixelBuffer, now: now)
        onFrame?(pixelBuffer)
    }

    /// 초당 한 줄로 "몇 장이 얼마나 밝게 들어왔는지" 를 남긴다.
    ///
    /// 밝기는 전수로 재면 프레임마다 100만 픽셀을 훑게 되므로 가로·세로
    /// 16픽셀 간격으로 성기게 뽑는다 (1280×720 기준 3600점). 값의 절대
    /// 정확도는 필요 없고 "새까만가 아닌가" 만 알면 된다.
    private func logFrameHealth(_ buffer: CVPixelBuffer, now: CFTimeInterval) {
        framesInHealthTick += 1
        brightnessSum += Self.meanBrightness(of: buffer)

        guard now - healthTickStartedAt >= 1 else { return }
        let mean = Int((brightnessSum / Double(max(1, framesInHealthTick))).rounded())
        // 시작 직후 몇 초와, 진짜 새까만 프레임만 남긴다. 계속 찍으면 초당
        // 한 줄씩 쌓여 정작 볼 것을 덮는다.
        if now - startedAt < 3 || mean < 8 {
            Log.camera.info("프레임 \(self.framesInHealthTick)장/초, 평균 밝기 \(mean)")
        }
        healthTickStartedAt = now
        framesInHealthTick = 0
        brightnessSum = 0

        if Self.diagnostics, blackProbeStartedAt > 0 {
            runBlackProbe(now: now, mean: mean)
            return
        }

        // 화면이 자면 카메라도 자고 프레임도 까매진다. 그건 고장이 아니다.
        guard Self.anyDisplayAwake(), mean == 0 else { blackTicks = 0; return }
        blackTicks += 1
        guard blackTicks >= blackTickLimit else { return }
        blackTicks = 0
        guard !failingOnBlackFrames else { return }
        failingOnBlackFrames = true
        // 여기서 장치를 다시 열어봤다. 안 뚫린다 — 재개방 두 번을 하고도
        // 밝기 0이 계속됐다(16:21:54, 16:21:58 실측). 게다가 검은 것도
        // 프레임이라 복구 예산이 매번 0으로 되돌아가서 "1/3" 을 무한히
        // 반복했다. 그래서 재개방하지 않고 한 번만 사실대로 남긴다.
        // 이 상태에 빠지지 않는 것이 유일한 대책이고, 그건 잠기기 전부터
        // 장치를 붙잡고 있는 것이다 — AppState.warmCamera 참조.
        guard !Self.diagnostics else {
            blackProbeStartedAt = now
            blackProbeResets = 0
            Log.camera.error("[진단] 새까만 프레임 확인 — 60초 동안 상태를 기록합니다")
            dumpState(label: "검게 나온 직후")
            return
        }
        Log.camera.error("화면은 켜져 있는데 새까만 프레임만 옵니다 — 이번 잠금은 비밀번호로 열어야 합니다")
        // 기다려봐야 소용없다는 걸 아는데 20초 제한시간까지 세워둘 이유가
        // 없다. 바로 알리고 비밀번호로 넘긴다.
        onFailure?(T("카메라가 검은 화면만 보냅니다 — 비밀번호로 로그인하세요.",
                     "The camera is only sending black frames — log in with your password."))
    }

    /// 진단 모드에서 매초. 60초 동안 상태를 남기고 5·15·30초에 다시 연다.
    private func runBlackProbe(now: CFTimeInterval, mean: Int) {
        let elapsed = now - blackProbeStartedAt
        guard elapsed <= 60 else { return }
        dumpState(label: "+\(Int(elapsed))초 밝기 \(mean)")
        // 간격을 크게 벌린 재개방. 0.4초 간격은 이미 실패로 확인됐다.
        let schedule: [Double] = [5, 15, 30]
        guard blackProbeResets < schedule.count,
              elapsed >= schedule[blackProbeResets] else { return }
        blackProbeResets += 1
        Log.camera.error("[진단] \(Int(elapsed))초 경과 — 장치를 다시 엽니다")
        resetAttempts = 0
        hardReset()
    }

    /// 장치·연결·세션이 스스로 뭐라고 말하는지 그대로 받아 적는다.
    private func dumpState(label: String) {
        let device = activeDevice
        let conn = output.connection(with: .video)
        let dims = device.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
        let state = "세션(돌아감=\(session.isRunning))"
            + " 장치(연결됨=\(device?.isConnected ?? false) 중지됨=\(device?.isSuspended ?? false)"
            + " 타앱사용=\(device?.isInUseByAnotherApplication ?? false)"
            + " 포맷=\(dims?.width ?? 0)×\(dims?.height ?? 0))"
            + " 연결(있음=\(conn != nil) 켜짐=\(conn?.isEnabled ?? false) 활성=\(conn?.isActive ?? false))"
        Log.camera.error("[진단] \(label, privacy: .public) \(state, privacy: .public)")
    }

    private static func meanBrightness(of buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        var total = 0
        var samples = 0
        for y in Swift.stride(from: 0, to: height, by: 16) {
            let row = pixels + y * stride
            for x in Swift.stride(from: 0, to: width, by: 16) {
                // BGRA. 사람 눈에 맞춘 가중치까지 갈 필요 없이 평균이면 충분하다.
                let p = row + x * 4
                total += Int(p[0]) + Int(p[1]) + Int(p[2])
                samples += 3
            }
        }
        return samples > 0 ? Double(total) / Double(samples) : 0
    }
}
