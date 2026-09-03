import ApplicationServices
import CoreGraphics
import Foundation
import QuartzCore

/// 잠금화면에 비밀번호를 주입해 실제로 잠금을 푼다.
///
/// macOS 에는 서드파티 앱이 화면 잠금을 직접 해제하는 공개 API 가 없다.
/// 그래서 저장해 둔 비밀번호를 HID 레벨 키 이벤트로 "타이핑"한다.
/// Secure Input 은 이벤트 탭의 *읽기* 만 막고 *주입* 은 막지 않아서 동작한다.
/// 이 방식은 **손쉬운 사용(Accessibility) 권한**을 요구한다.
///
/// ## 최악의 실패 모드
/// 이미 잠금이 풀린 화면에 주입하면 비밀번호가 눈앞에 그대로 타이핑되고,
/// 열려 있던 문서·터미널·채팅창에 그대로 들어간다. 그래서 주입 직전에 잠금 상태를
/// 한 번 더 확인하고, 확인에 실패하면 **주입하지 않는다**.
enum Unlocker {

    enum Failure: LocalizedError {
        case notLocked
        case noAccessibility
        case noPassword
        case eventCreationFailed
        case stillLocked

        var errorDescription: String? {
            switch self {
            case .notLocked:            return T("화면이 잠겨 있지 않습니다.", "The screen is not locked.")
            case .noAccessibility:      return T("손쉬운 사용 권한이 필요합니다.", "Accessibility permission is required.")
            case .noPassword:           return T("저장된 비밀번호가 없습니다.", "No password is stored.")
            case .eventCreationFailed:  return T("키 이벤트를 만들지 못했습니다.", "Could not create key events.")
            case .stillLocked:          return T("잠금 해제에 실패했습니다.", "Unlocking failed.")
            }
        }
    }

    private static let returnKey: CGKeyCode = 36
    private static let deleteKey: CGKeyCode = 51
    private static let aKey: CGKeyCode = 0

    /// Cmd+A 가 먹지 않았을 때를 대비한 지우개 횟수.
    ///
    /// 예전에는 32 번이었다. 한 번에 5ms 씩이라 그것만 160ms 였고, 그 시간이
    /// 그대로 "얼굴은 알아봤는데 안 열리는" 체감 지연으로 갔다. 지금은 아래
    /// [clearPasswordField] 에서 Cmd+A 를 **두 번** 보내 첫 키가 칸을 깨우는 데
    /// 쓰여 버리는 경우까지 덮으므로, 이 보험이 실제로 쓰일 일은 거의 없다.
    private static let clearBackspaces = 8

    /// 잠금 해제를 시도한다. 실패하면 1회만 재시도하고 그만둔다.
    /// 무한 재시도는 계정 잠금으로 이어질 수 있다.
    ///
    /// `cautious` 는 **재시도에서만** 켠다. 첫 시도가 실패했다는 건 잠금화면이
    /// 아직 키를 받을 준비가 안 됐다는 뜻일 수 있으므로, 두 번째는 빠른 길을
    /// 버리고 화면을 확실히 깨우고 넉넉히 기다린 뒤에 넣는다. 실측 로그에서
    /// 첫 시도와 재시도가 **같은 조건으로** 연달아 실패한 적이 있는데
    /// (16:55:49.6 / 16:55:51.2), 조건이 같으면 재시도가 새로 얻는 정보가 없다.
    @discardableResult
    static func unlock(allowRetry: Bool = true, cautious: Bool = false) -> Result<Void, Failure> {
        // 잠금 확인이 가장 앞이다. 다른 가드보다 뒤에 두면 그 가드들이 먼저 반환할 때
        // 잠금 확인이 아예 실행되지 않아, 정작 제일 중요한 검사가 조건부가 되어버린다.
        guard LockMonitor.screenIsLockedNow() else {
            Log.unlock.error("잠금 상태가 아님 — 주입 중단")
            return .failure(.notLocked)
        }
        guard Permissions.hasAccessibility else {
            Log.unlock.error("손쉬운 사용 권한 없음 — 주입 중단")
            return .failure(.noAccessibility)
        }
        guard Vault.hasPassword else {
            Log.unlock.error("저장된 비밀번호 없음")
            return .failure(.noPassword)
        }

        let started = CACurrentMediaTime()

        // 덮개를 열어 들어온 경우처럼 화면이 이미 켜져 있으면 깨울 것이 없다.
        // 예전에는 무조건 caffeinate 를 띄우고 0.2초를 기다렸는데, 그 0.2초는
        // 사용자가 눈앞에서 그대로 세는 시간이다. 그리고 얼굴이 일치했다는 건
        // 카메라가 프레임을 받고 있었다는 뜻이라 화면이 켜져 있는 쪽이 흔하다.
        if cautious {
            wakeDisplay()
            Thread.sleep(forTimeInterval: 0.4)
        } else if anyDisplayAwake() {
            // 그래도 아주 짧게는 둔다. 켜졌다는 신호와 잠금화면이 키를 받을
            // 준비가 끝나는 시점이 정확히 같지는 않다.
            Thread.sleep(forTimeInterval: 0.05)
        } else {
            wakeDisplay()
            Thread.sleep(forTimeInterval: 0.2)
        }

        // ── 마지막 안전 확인. 깨우는 사이에 사용자가 직접 풀었을 수 있다. ──
        guard LockMonitor.screenIsLockedNow() else {
            Log.unlock.info("깨우는 사이 잠금이 해제됨 — 주입하지 않음")
            return .failure(.notLocked)
        }

        do {
            try typePassword()
        } catch let failure as Failure {
            // 사유를 그대로 돌려준다. 특히 .notLocked 는 재시도하면 안 되는
            // 신호라서 .eventCreationFailed 로 뭉뚱그리면 위험하다.
            Log.unlock.error("주입 실패: \(failure.localizedDescription, privacy: .public)")
            return .failure(failure)
        } catch {
            Log.unlock.error("주입 실패")
            return .failure(.eventCreationFailed)
        }

        // 여기까지가 사용자가 기다리는 구간이다. 느리다는 말이 나오면 이 숫자부터 본다.
        Log.unlock.info("주입 완료 \(Int((CACurrentMediaTime() - started) * 1000))ms")

        Thread.sleep(forTimeInterval: 0.8)
        if !LockMonitor.screenIsLockedNow() {
            Log.unlock.info("잠금 해제 성공")
            return .success(())
        }

        guard allowRetry else {
            Log.unlock.error("재시도 후에도 잠금 상태 — 중단")
            return .failure(.stillLocked)
        }

        Log.unlock.info("1회 재시도 — 이번에는 화면을 깨우고 넉넉히 기다립니다")
        Thread.sleep(forTimeInterval: 0.4)
        return unlock(allowRetry: false, cautious: true)
    }

    // MARK: 디스플레이 깨우기

    /// 켜져 있는 디스플레이가 하나라도 있는가.
    ///
    /// 판정이 안 되면 "켜져 있다" 가 아니라 **"꺼져 있다"** 로 센다. 여기서
    /// 틀리면 꺼진 화면에 키를 쏘아 비밀번호가 통째로 허공으로 가므로,
    /// 모르겠으면 깨우고 기다리는 쪽이 맞다.
    /// (같은 판정이 [CameraSession] 과 [AppState] 에도 있는데, 그쪽은 "복구를
    ///  건너뛰지 않는" 것이 목적이라 모를 때의 기본값이 반대다.)
    private static func anyDisplayAwake() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 }
    }

    /// 화면이 꺼져 있으면 키 이벤트가 잠금화면까지 닿지 않는다.
    private static func wakeDisplay() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-t", "1"]
        do {
            try process.run()
        } catch {
            Log.unlock.error("caffeinate 실행 실패: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: 주입

    /// 비밀번호를 한 번에 유니코드 문자열로 넣고 Return 을 친다.
    /// 문자마다 키코드로 쪼개면 키보드 레이아웃(한/영, 콜맥 등)에 따라 글자가 달라진다.
    private static func typePassword() throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw Failure.eventCreationFailed
        }

        // 여기서 한 번 더 확인하는 이유는 아래 지우기 동작 때문이다.
        // Cmd+A → Delete 는 **파괴적**이다. 잠금이 풀린 화면으로 새어 나가면
        // 포커스를 잡고 있던 문서 내용을 통째로 지운다. 호출부에도 확인이
        // 있지만, 파괴적인 동작 바로 앞에 하나 더 두는 값이 충분히 크다.
        guard LockMonitor.screenIsLockedNow() else {
            Log.unlock.error("주입 직전 잠금이 풀림 — 지우기/주입 모두 중단")
            throw Failure.notLocked
        }

        // 필드가 비어 있다는 보장이 없다. 아래 clearPasswordField 주석 참조.
        clearPasswordField(source: source)

        // 잠금화면에서는 Keychain 확인 창에 답할 수 없다. 물어보게 두면 여기서
        // 영원히 멈추므로, 물어봐야 하는 상황이면 차라리 즉시 실패시킨다.
        try Vault.withPassword(allowInteraction: false) { units in
            guard !units.isEmpty else { throw Failure.noPassword }

            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw Failure.eventCreationFailed
            }

            units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }

            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }

        // 필드가 문자열을 반영할 짬을 준다. 너무 빨리 Return 을 치면 빈 채로 제출된다.
        Thread.sleep(forTimeInterval: 0.12)

        guard let enterDown = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let enterUp = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
            throw Failure.eventCreationFailed
        }
        enterDown.post(tap: .cghidEventTap)
        enterUp.post(tap: .cghidEventTap)
    }

    // MARK: 비밀번호 칸 비우기

    /// 주입 **직전에** 비밀번호 칸을 비운다.
    ///
    /// 사람들은 꺼진 화면을 깨우려고 아무 키나 두드린다. 그 문자는 그대로
    /// 비밀번호 칸에 남고, 우리가 뒤에 이어 붙이면 `asdf` + 실제 비밀번호가
    /// 되어 **반드시 틀린다.** 얼굴 인식은 성공했는데 잠금은 안 풀리고,
    /// 게다가 오입력 횟수만 쌓인다. 비우지 않으면 이 버그는 항상 재현된다.
    ///
    /// 두 가지를 겹쳐서 쓴다. 칸의 내용을 읽을 방법이 없어서(Secure Input 이
    /// 읽기를 막는다) 지워졌는지 확인할 수가 없기 때문이다.
    ///   1. Cmd+A → Delete — 길이에 상관없이 한 번에 지운다
    ///   2. Backspace 여러 번 — 1 이 먹지 않았을 때의 보험.
    ///      빈 칸에서 Backspace 는 아무 일도 하지 않으므로 겹쳐도 해가 없다
    ///
    /// 잠금화면에는 비밀번호 칸 말고 포커스를 받을 것이 없으므로 Cmd+A 가
    /// 엉뚱한 곳에 걸릴 일도 없다.
    private static func clearPasswordField(source: CGEventSource) {
        // Cmd+A 를 두 번 보낸다. 화면이 막 켜진 직후에는 첫 키 하나가 비밀번호
        // 칸을 띄우고 포커스를 주는 데 쓰이고 사라진다 — 그래서 예전에는 첫
        // Cmd+A 가 헛돌고 뒤의 Backspace 32 번에 기대야 했다. 두 번째는 포커스가
        // 잡힌 뒤에 닿으므로, 칸에 무엇이 몇 자 들어 있든 한 번에 지워진다.
        tap(source: source, key: aKey, flags: .maskCommand)
        tap(source: source, key: aKey, flags: .maskCommand)
        tap(source: source, key: deleteKey)
        for _ in 0..<clearBackspaces {
            tap(source: source, key: deleteKey)
        }
        // 칸이 비워진 걸 반영할 짬을 준다.
        Thread.sleep(forTimeInterval: 0.06)
    }

    /// 키 하나를 눌렀다 뗀다. loginwindow 는 너무 빠른 연속 이벤트를 흘리므로
    /// 사이에 짧은 간격을 둔다.
    private static func tap(source: CGEventSource, key: CGKeyCode, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.005)
    }
}
