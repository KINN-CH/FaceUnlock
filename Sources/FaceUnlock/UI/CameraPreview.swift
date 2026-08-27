import AVFoundation
import AppKit
import SwiftUI

/// AVCaptureVideoPreviewLayer 를 SwiftUI 에 얹는다.
struct CameraPreview: NSViewRepresentable {

    let makeLayer: () -> AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        let view = LayerHostingView()
        view.wantsLayer = true
        let preview = makeLayer()
        view.previewLayer = preview
        view.layer?.addSublayer(preview)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// 화면이 사라질 때 레이어를 떼어낸다.
    ///
    /// 미리보기 레이어는 `CameraSession` 이 하나만 만들어 돌려 쓴다. 여기서
    /// 떼지 않으면 닫힌 창의 레이어에 계속 붙어 있어서 다음 창에 붙지 않는다
    /// (레이어의 부모는 하나뿐이다) — 두 번째로 연 창이 검은 화면이 된다.
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        guard let view = nsView as? LayerHostingView else { return }
        view.previewLayer?.removeFromSuperlayer()
        view.previewLayer = nil
    }

    /// 레이어는 오토레이아웃을 따르지 않으므로 프레임을 직접 맞춰준다.
    final class LayerHostingView: NSView {
        var previewLayer: AVCaptureVideoPreviewLayer?

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}
