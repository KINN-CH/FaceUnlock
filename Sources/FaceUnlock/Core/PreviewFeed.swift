import Combine
import CoreGraphics
import Foundation

/// 카메라가 **실제로 받은 프레임**을 미리보기 화면으로 흘려보내는 통로.
///
/// ── 왜 `AVCaptureVideoPreviewLayer` 를 안 쓰는가 ─────────────────────────
/// 원래는 그 레이어를 세션에 붙여 썼다. 그런데 그 레이어의 연결(connection)은
/// **세션에 입력이 붙는 순간 한 번 만들어지고 끝이다.** [CameraSession] 의
/// 재개방(hardReset)은 입력·출력을 전부 떼어냈다가 다시 붙이는데, 데이터
/// 출력은 재구성 때 새로 붙지만 미리보기 레이어의 연결은 **되살아나지 않는다.**
///
/// 그래서 얼굴 인식은 멀쩡히 돌아가는데 화면만 까맣게 남았다. 실제 로그를
/// 보면 그 시각 카메라는 24fps 로 프레임을 잘 넘기고 있었다 — "테스트를
/// 누르면 검은 화면" 의 정체가 이것이었다.
///
/// 지금은 미리보기도 분석과 **같은 프레임**을 받아 직접 그린다. 세션을 몇
/// 번을 다시 열든 상관없고, 덤으로 사용자는 인식기가 보는 그림을 그대로 본다.
final class PreviewFeed: ObservableObject {

    static let shared = PreviewFeed()

    /// 최신 프레임. 메인 스레드에서만 갱신된다.
    @Published private(set) var frame: CGImage?

    private init() {}

    func publish(_ image: CGImage) {
        DispatchQueue.main.async { [weak self] in self?.frame = image }
    }

    /// 보는 화면이 사라졌을 때 마지막 장면을 지운다. 남겨두면 다음에 열었을 때
    /// 몇 분 전 얼굴이 잠깐 비친다.
    func clear() {
        DispatchQueue.main.async { [weak self] in self?.frame = nil }
    }
}
