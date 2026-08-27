import AppKit
import CoreGraphics
import SwiftUI

/// 잠금화면 위에 현재 상태를 띄우는 작은 표시.
///
/// 이게 없으면 사용자는 FaceUnlock 이 켜져 있는지, 얼굴을 보고 있는지, 지금
/// 깜빡여야 하는지를 알 방법이 없다. 카메라 표시등 하나로는 부족하다.
///
/// ## 반드시 지켜야 하는 것: 포커스를 가져가지 않는다
/// 이 창이 키 윈도우가 되면 [Unlocker] 가 주입한 비밀번호가 잠금화면이 아니라
/// **여기로 들어간다.** 그래서 non-activating 패널로 만들고, `canBecomeKey` 와
/// `canBecomeMain` 을 명시적으로 막고, 마우스 이벤트도 통째로 무시한다.
/// `makeKeyAndOrderFront` 대신 `orderFrontRegardless` 만 쓴다.
///
/// ## 한계
/// macOS 는 잠금화면 위에 일반 앱 창을 띄우는 걸 보장하지 않는다. 잠금화면은
/// loginwindow 가 그리고, 사용자 세션 창은 대개 그 아래로 가려진다.
/// 차폐 윈도우(`CGShieldingWindowLevel`) 위 레벨로 올려 두지만 **버전에 따라
/// 보이지 않을 수 있다.** 안 보여도 잠금 해제 동작 자체에는 영향이 없다.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class LockOverlayController {

    static let shared = LockOverlayController()

    private var panel: OverlayPanel?
    private var hosting: NSHostingView<LockOverlayView>?

    private init() {}

    /// 상태가 바뀔 때마다 불린다. 띄울 문구가 없으면 감춘다.
    ///
    /// `locked` 를 인자로 받는 이유. 예전엔 여기서 직접
    /// `LockMonitor.screenIsLockedNow()` 를 불렀는데, 그 값은
    /// `CGSSessionScreenIsLocked` 를 그대로 읽는 것이라 잠긴 **직후** 잠깐
    /// false 로 보인다. 그 틈에 상태 전이가 전부 지나가버리면 표시가 영영
    /// 안 뜬다. 실제로 그렇게 됐다. 알림 기반 플래그와 OR 로 묶는다.
    ///
    /// 느슨하게 잡아도 안전하다. 이 창은 포커스를 못 가져가고, 화면이 풀리면
    /// 상태가 `.idle` 이 되어 `lockScreenText` 가 nil 이라 곧바로 사라진다.
    func update(for status: AppState.Status, locked: Bool) {
        guard let text = status.lockScreenText else {
            hide()
            return
        }
        guard locked else {
            Log.app.debug("잠금화면 표시 보류 — 잠김으로 보이지 않음")
            hide()
            return
        }
        show(text: text, symbol: status.lockScreenSymbol)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// 잠그지 않고 모양·위치만 확인한다. 메뉴에서 직접 부를 때만 쓴다.
    ///
    /// 잠금 확인을 건너뛰지만 위험하지 않다. 이 창은 어떤 상태에서도 포커스를
    /// 가져가지 않고, [Unlocker] 는 잠긴 화면에서만 주입하기 때문이다.
    func preview(seconds: TimeInterval = 3) {
        show(text: AppState.Status.blinkChallenge.lockScreenText ?? "",
             symbol: AppState.Status.blinkChallenge.lockScreenSymbol)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            // 미리보기 사이에 실제로 잠겼다면 그쪽 표시를 지우면 안 된다.
            guard !LockMonitor.screenIsLockedNow() else { return }
            hide()
        }
    }

    private func show(text: String, symbol: String) {
        let view = LockOverlayView(text: text, symbol: symbol)

        if let hosting, let panel {
            hosting.rootView = view
            layout(panel: panel, hosting: hosting)
            panel.orderFrontRegardless()
            return
        }

        let hostingView = NSHostingView(rootView: view)
        let win = OverlayPanel(contentRect: .zero,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered,
                               defer: false)
        win.contentView = hostingView
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false

        // 차폐 윈도우(스크린세이버·잠금화면) 바로 위. 이보다 낮으면 확실히 가려진다.
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                  .fullScreenAuxiliary, .ignoresCycle]

        panel = win
        hosting = hostingView
        layout(panel: win, hosting: hostingView)
        win.orderFrontRegardless()

        // "안 보인다" 는 신고가 들어왔을 때 창이 아예 안 만들어진 건지,
        // 만들어졌는데 잠금화면에 가려진 건지 구분할 수 있어야 한다.
        Log.app.info("잠금화면 표시 생성 — 위치 \(NSStringFromRect(win.frame), privacy: .public), 레벨 \(win.level.rawValue)")
    }

    /// 카메라 근처(화면 상단 중앙)에 놓는다. 사용자가 그쪽을 보게 되므로
    /// 시선이 자연스럽게 렌즈로 향한다.
    private func layout(panel: NSWindow, hosting: NSView) {
        guard let screen = NSScreen.main else { return }
        let size = hosting.fittingSize
        let frame = screen.frame
        let origin = NSPoint(x: frame.midX - size.width / 2,
                             y: frame.maxY - size.height - 120)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

private struct LockOverlayView: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
            Text(text)
                .font(.system(size: 15, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .padding(8)   // 그림자·테두리가 잘리지 않도록 여유
    }
}
