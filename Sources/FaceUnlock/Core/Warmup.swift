import CoreVideo
import Foundation
import QuartzCore

/// 인식 파이프라인을 **잠기기 전에** 미리 데워 둔다.
///
/// ── 왜 필요한가 ─────────────────────────────────────────────────────────
/// 잠금 버튼을 누른 직후에는 반응이 없고, 화면을 깨워 두 번째 세션이 뜨면
/// 그때서야 인식된다는 신고가 있었다. 실제 로그를 재보니 원인이 분명했다.
///
/// ```
/// 17:15:18.946  화면 잠김
/// 17:15:18.972  카메라 세션 시작        ← 카메라는 26ms 만에 켜졌다
/// 17:15:25.247  얼굴 일치               ← 그런데 첫 일치까지 6.3초
/// 17:15:25.371  카메라 세션 시작        (화면이 켜지며 두 번째 세션)
/// 17:15:26.058  얼굴 일치               ← 이번엔 0.69초
/// ```
///
/// 카메라는 처음부터 잘 돌았다. 감시견이 한 번도 안 짖었으니 프레임도 계속
/// 들어왔다. 느린 건 **첫 추론**이다. 같은 구간의 시스템 로그를 보면 잠긴
/// 직후 1초 동안 `com.apple.espresso`·`com.apple.ane`·`com.apple.coreml` 이
/// 몰려서 뜬다 — Vision 의 얼굴 검출기와 ArcFace 가 그제서야 ANE 에 올라간다.
/// 두 번째 세션이 빨랐던 건 그 비용을 첫 세션이 이미 치렀기 때문이다.
///
/// 이 비용은 없앨 수 없지만 **옮길 수는 있다.** 잠긴 뒤에 치르면 사용자가
/// 눈앞에서 기다리고, 잠기기 전에 치르면 아무도 모른다.
///
/// ── 카메라는 켜지 않는다 ────────────────────────────────────────────────
/// 예열에 진짜 얼굴이 필요하지 않다. 검출기는 얼굴을 못 찾아도 모델을 올리고,
/// ArcFace 는 어떤 112×112 입력이든 한 번 돌면 컴파일이 끝난다. 그래서
/// 회색 버퍼 한 장이면 된다 — 표시등도 안 켜지고 사생활 문제도 없다.
///
/// ── 반복하지 않는다 ────────────────────────────────────────────────────
/// 예전에는 1분마다 반복했다. 뉴럴 엔진이 한동안 안 쓰인 모델을 내려서
/// (로그에 `unloadModel` 이 그대로 찍힌다) 한 번 데워도 금방 도로 차가워졌기
/// 때문이다. 지금은 [EmbeddingModel] 이 CPU 로 돌아 내려갈 일이 없으므로
/// 앱을 켤 때 **한 번만** 부른다. 잠기지 않은 시간 내내 1분마다 앱을 깨우던
/// 타이머는 [AppState] 에서 지웠다.
enum Warmup {

    /// 예열은 사용자를 기다리게 하지 않아야 하므로 항상 백그라운드에서 돈다.
    private static let queue = DispatchQueue(
        label: "io.github.kinnch.FaceUnlock.warmup", qos: .utility)

    /// 인증에 쓰는 것과 **같은 종류의** 검출기. 실제 경로와 다른 걸 데우면
    /// 의미가 없다.
    private static let detector = FaceDetector()

    /// 카메라가 주는 것과 같은 규격의 빈 프레임. 한 번 만들어 재사용한다.
    private static var blankFrame: CVPixelBuffer?

    /// 정렬을 마친 얼굴 자리에 넣을 더미. 값은 아무래도 좋고 크기만 맞으면 된다.
    private static let dummyFace = [UInt8](repeating: 128, count: 112 * 112 * 4)

    /// 예열이 겹쳐 돌지 않게 막는다. 모델 로드 직후 호출과 설정 변경 시
    /// 호출이 같은 순간에 걸릴 수 있다.
    private static var running = false

    static func run(model: EmbeddingModel?) {
        queue.async {
            guard !running else { return }
            running = true
            defer { running = false }

            let started = CACurrentMediaTime()
            if let frame = frame() {
                _ = detector.detectPrimaryFace(in: frame)
            }
            _ = model?.embed(alignedRGBA: dummyFace)
            let elapsed = Int((CACurrentMediaTime() - started) * 1000)

            // 이 줄이 매번 수백 ms 로 찍힌다면 예열이 유지되지 않고 있다는 뜻이다.
            // 데워진 뒤에는 한 자릿수~수십 ms 로 떨어진다.
            Log.face.info("인식 파이프라인 예열 \(elapsed)ms")
        }
    }

    /// 카메라가 내주는 것과 같은 1280×720 BGRA 버퍼.
    ///
    /// 규격을 맞추는 이유: Vision 은 픽셀 포맷·크기에 따라 다른 경로를 타므로,
    /// 실제와 다른 버퍼로 데우면 정작 필요한 경로는 차가운 채로 남는다.
    private static func frame() -> CVPixelBuffer? {
        if let blankFrame { return blankFrame }

        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary,
                                  &buffer) == kCVReturnSuccess,
              let created = buffer else { return nil }

        CVPixelBufferLockBaseAddress(created, [])
        if let base = CVPixelBufferGetBaseAddress(created) {
            memset(base, 128, CVPixelBufferGetBytesPerRow(created) * 720)
        }
        CVPixelBufferUnlockBaseAddress(created, [])

        blankFrame = created
        return created
    }
}
