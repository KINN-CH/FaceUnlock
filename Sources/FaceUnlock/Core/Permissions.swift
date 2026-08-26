import AVFoundation
import ApplicationServices
import AppKit

/// 이 앱이 동작하려면 사용자가 시스템 설정에서 직접 켜줘야 하는 두 가지 권한.
enum Permissions {

    // MARK: 카메라 (TCC)

    static var cameraStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static var hasCamera: Bool { cameraStatus == .authorized }

    /// 최초 1회만 시스템 다이얼로그가 뜬다. 이미 거부됐다면 다이얼로그는 뜨지 않으므로
    /// 호출부가 시스템 설정으로 안내해야 한다.
    static func requestCamera() async -> Bool {
        if cameraStatus == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .video)
    }

    // MARK: 손쉬운 사용 (Accessibility)

    /// 잠금 화면에 키 이벤트를 주입하려면 반드시 필요하다.
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// `prompt: true` 면 "손쉬운 사용에서 허용" 안내 다이얼로그를 띄운다.
    /// 사용자가 시스템 설정에서 켜기 전까지 `false` 를 계속 돌려준다.
    @discardableResult
    static func checkAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    // MARK: 시스템 설정 열기

    static func openCameraSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
