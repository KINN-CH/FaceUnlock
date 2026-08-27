import AppKit
import SwiftUI

struct EnrollmentView: View {
    @StateObject private var controller = EnrollmentController()
    @ObservedObject private var l10n = L10n.shared
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            header

            ZStack {
                CameraPreview()
                    .frame(width: 400, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(controller.canCapture ? Color.green : Color.secondary.opacity(0.5),
                                  lineWidth: 3)
                    .frame(width: 400, height: 300)
            }

            poseGrid

            Text(controller.guidance)
                .font(.title3)
                .frame(height: 28)

            if let error = controller.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }

            ProgressView(value: controller.progress)
                .frame(width: 400)

            footer
        }
        .padding(20)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(T("얼굴 등록", "Enroll a Face")).font(.title2).bold()
            Text(T("안내하는 자세를 취한 뒤 ‘촬영’을 누르세요. 총 \(FacePose.allCases.count)장을 등록합니다.",
                   "Follow the pose guidance, then press Capture. \(FacePose.allCases.count) shots in total."))
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(T("이름 (비워두면 자동)", "Name (optional)"), text: $controller.personName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
        }
    }

    /// 어떤 포즈가 끝났고 어떤 게 남았는지 한눈에 보여준다.
    private var poseGrid: some View {
        HStack(spacing: 6) {
            ForEach(FacePose.allCases, id: \.self) { pose in
                Circle()
                    .fill(color(for: pose))
                    .frame(width: 12, height: 12)
            }
        }
    }

    private func color(for pose: FacePose) -> Color {
        if controller.completed.contains(pose) { return .green }
        if pose == controller.currentPose { return .accentColor }
        return .secondary.opacity(0.3)
    }

    private var footer: some View {
        HStack {
            Button(T("취소", "Cancel")) {
                controller.stop()
                onClose()
            }
            Spacer()
            if controller.isFinished {
                Button(T("완료", "Done")) {
                    controller.commit()
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button(T("촬영", "Capture")) { controller.requestCapture() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!controller.canCapture)
            }
        }
        .frame(width: 400)
    }
}

@MainActor
final class EnrollmentWindowController {
    static let shared = EnrollmentWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            window.title = T("얼굴 등록", "Enroll a Face")
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: EnrollmentView { [weak self] in
            self?.close()
        })
        let win = NSWindow(contentViewController: hosting)
        win.title = T("얼굴 등록", "Enroll a Face")
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()

        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// 창을 닫으면 컨트롤러도 사라져 카메라가 꺼진다 (`onDisappear`).
    func close() {
        window?.close()
        window = nil
        AppState.shared.refreshStatus()
    }
}
