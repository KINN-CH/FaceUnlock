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

    /// 잠금 해제를 시도한다. 실패하면 1회만 재시도하고 그만둔다.
    /// 무한 재시도는 계정 잠금으로 이어질 수 있다.
    @discardableResult
    static func unlock(allowRetry: Bool = true) -> Result<Void, Failure> {
        guard Permissions.hasAccessibility else {
            Log.unlock.error("손쉬운 사용 권한 없음 — 주입 중단")
            return .failure(.noAccessibility)
        }
        guard Vault.hasPassword else {
            Log.unlock.error("저장된 비밀번호 없음")
            return .failure(.noPassword)
        }
        guard LockMonitor.screenIsLockedNow() else {
            Log.unlock.error("잠금 상태가 아님 — 주입 중단")
            return .failure(.notLocked)
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

        try Vault.withPassword { units in
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
}
