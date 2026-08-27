import AppKit
import Foundation

/// 화면 잠금 상태를 감시한다.
///
/// 두 가지 경로를 함께 쓴다:
///  1. `DistributedNotificationCenter` 의 `com.apple.screenIsLocked` / `screenIsUnlocked`
///     — 전이 시점을 즉시 알려주지만, 앱이 나중에 실행되면 놓친다.
///  2. `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`
///     — 지금 이 순간의 실제 상태. 비밀번호 주입 직전 재확인용으로 반드시 쓴다.
@MainActor
final class LockMonitor: ObservableObject {

    @Published private(set) var isLocked: Bool = false

    /// 잠김 전이. 얼굴 인식 세션을 시작할 시점.
    var onLock: (() -> Void)?
    /// 해제 전이. 카메라를 즉시 끄고 대기 중인 주입을 취소할 시점.
    var onUnlock: (() -> Void)?

    private let center = DistributedNotificationCenter.default()
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        center.addObserver(self, selector: #selector(handleLocked),
                           name: Self.lockedNotification, object: nil)
        center.addObserver(self, selector: #selector(handleUnlocked),
                           name: .init("com.apple.screenIsUnlocked"), object: nil)

        // 앱이 잠긴 상태에서 시작됐을 수도 있다.
        let now = Self.screenIsLockedNow()
        if now != isLocked {
            isLocked = now
            Log.lock.info("초기 상태: \(now ? "잠김" : "해제됨", privacy: .public)")
            if now { onLock?() }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        center.removeObserver(self)
    }

    @objc private func handleLocked() {
        guard !isLocked else { return }
        isLocked = true
        Log.lock.info("화면 잠김")
        onLock?()
    }

    @objc private func handleUnlocked() {
        guard isLocked else { return }
        isLocked = false
        Log.lock.info("화면 해제됨")
        onUnlock?()
    }

    /// 잠금 알림 이름. 카메라를 쓰는 다른 화면도 이걸 보고 장치를 양보한다.
    nonisolated static let lockedNotification = Notification.Name("com.apple.screenIsLocked")

    /// 지금 이 순간 화면이 잠겨 있는가.
    ///
    /// 판단할 수 없으면 `false`(= 잠겨 있지 않음)를 돌려준다. 호출부가 이 값을
    /// "비밀번호를 주입해도 되는가" 판정에 쓰기 때문에, 불확실할 때는 주입하지 않는 쪽이 안전하다.
    /// 해제된 화면에 주입하면 비밀번호가 눈앞에 그대로 타이핑된다.
    nonisolated static func screenIsLockedNow() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            Log.lock.error("CGSessionCopyCurrentDictionary 실패 — 잠기지 않은 것으로 간주")
            return false
        }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
