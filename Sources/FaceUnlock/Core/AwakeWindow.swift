import Foundation
import IOKit.pwr_mgt

/// 잠긴 직후 잠깐 화면을 붙잡아 두는 장치.
///
/// ── 왜 필요한가 ─────────────────────────────────────────────────────────
/// 잠금 버튼을 누르면 macOS 는 5초쯤 뒤에 디스플레이를 끈다(실측: 잠김
/// 17:15:18.9 → `kCGSDisplayWillSleep` 17:15:24.6). 그런데 화면이 자면
/// 카메라도 같이 자서 프레임이 끊긴다 — [CameraSession] 의 감시견에 그
/// 상태를 따로 봐주는 가지가 있을 만큼 확실한 동작이다.
///
/// 즉 얼굴을 들이밀 수 있는 창이 5초뿐이고, 그 안에 못 맞추면 사용자는
/// 키보드를 눌러 화면을 깨워야 한다. "잠금 버튼 누른 직후에는 반응이 없고
/// 마우스로 깨워야 인식된다" 가 이것이다.
///
/// 그래서 잠긴 직후에만 짧게 화면을 붙잡는다. 인증이 끝나면 곧바로 놓는다.
///
/// ── 왜 짧게만 잡는가 ────────────────────────────────────────────────────
/// 이건 절전을 끄는 장치라서, 놓는 걸 잊으면 밤새 화면이 켜져 있는다.
/// 그래서 (1) 반드시 시한을 걸고, (2) 인증이 끝나면 시한 전에도 놓고,
/// (3) 다시 잡을 때 이전 것을 먼저 놓는다.
enum AwakeWindow {

    /// 0 은 "잡은 게 없다" 는 뜻으로 쓴다. IOKit 이 주는 유효한 ID 는 0 이 아니다.
    private static var assertion: IOPMAssertionID = 0
    private static var expiry: DispatchWorkItem?

    /// 화면을 `seconds` 동안 깨워 둔다. 이미 잡고 있으면 시한만 새로 준다.
    static func hold(for seconds: TimeInterval) {
        release()

        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "FaceUnlock 얼굴 인식 중" as CFString,
            &id)
        guard result == kIOReturnSuccess else {
            // 못 잡아도 인증 자체는 굴러간다. 화면이 꺼진 뒤 사용자가 깨우면
            // [AppState.handleScreensDidWake] 가 이어받는다.
            Log.app.error("화면 절전을 막지 못했습니다 (IOKit \(result))")
            return
        }
        assertion = id

        let work = DispatchWorkItem { release() }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    static func release() {
        expiry?.cancel()
        expiry = nil
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }
}
