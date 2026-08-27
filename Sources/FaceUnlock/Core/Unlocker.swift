import ApplicationServices
import CoreGraphics
import Foundation

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
            case .notLocked:            return "화면이 잠겨 있지 않습니다."
            case .noAccessibility:      return "손쉬운 사용 권한이 필요합니다."
            case .noPassword:           return "저장된 비밀번호가 없습니다."
            case .eventCreationFailed:  return "키 이벤트를 만들지 못했습니다."
            case .stillLocked:          return "잠금 해제에 실패했습니다."
            }
        }
    }

    private static let returnKey: CGKeyCode = 36
    private static let deleteKey: CGKeyCode = 51
    private static let aKey: CGKeyCode = 0

    /// Cmd+A 가 먹지 않았을 때를 대비한 지우개 횟수.
    /// 화면을 깨우려고 키보드를 두드린 정도는 보통 열 자 남짓이라 넉넉하다.
    private static let clearBackspaces = 32

    /// 잠금 해제를 시도한다. 실패하면 1회만 재시도하고 그만둔다.
    /// 무한 재시도는 계정 잠금으로 이어질 수 있다.
    @discardableResult
    static func unlock(allowRetry: Bool = true) -> Result<Void, Failure> {
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

        wakeDisplay()
        Thread.sleep(forTimeInterval: 0.2)

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

        Thread.sleep(forTimeInterval: 0.8)
        if !LockMonitor.screenIsLockedNow() {
            Log.unlock.info("잠금 해제 성공")
            return .success(())
        }

        guard allowRetry else {
            Log.unlock.error("재시도 후에도 잠금 상태 — 중단")
            return .failure(.stillLocked)
        }

        Log.unlock.info("1회 재시도")
        Thread.sleep(forTimeInterval: 0.4)
        return unlock(allowRetry: false)
    }

    // MARK: 디스플레이 깨우기

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
