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
