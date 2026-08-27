import AppKit
import SwiftUI

struct EnrollmentView: View {
    @StateObject private var controller = EnrollmentController()
    @ObservedObject private var l10n = L10n.shared
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            header

            ZStack(alignment: .bottom) {
                CameraPreview()
                    .frame(width: 400, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(borderColor, lineWidth: 3)
                    .frame(width: 400, height: 300)

                // 오토 촬영이 자세를 잡고 있는 동안 차오르는 막대.
                // 사용자가 "얼마나 더 버텨야 하는지" 알 수 있어야 손이 안 움직인다.
                if controller.holdingPose != nil {
                    Capsule()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 360, height: 6)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: 360 * controller.holdProgress, height: 6)
                        }
                        .padding(.bottom, 12)
                }
            }
            .animation(.linear(duration: 0.12), value: controller.holdProgress)

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
            Text(T("안내하는 자세를 취하고 잠깐 멈추면 자동으로 찍힙니다. 총 \(FacePose.allCases.count)장.",
                   "Hold each pose for a moment and it captures itself. \(FacePose.allCases.count) shots in total."))
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
                    .overlay {
                        // 지금 잡고 있는 포즈는 테두리로 표시한다. 안내와 다른
                        // 자세를 취해도 그 칸이 채워지므로, 어디가 차는지 보여야 한다.
                        if pose == controller.holdingPose {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                                .frame(width: 18, height: 18)
                        }
                    }
                    .help(pose.label)
            }
        }
        .frame(height: 20)
    }

    private var borderColor: Color {
        if controller.holdingPose != nil { return .accentColor }
        return controller.canCapture ? .green : .secondary.opacity(0.5)
    }

    private func color(for pose: FacePose) -> Color {
        if controller.completed.contains(pose) { return .green }
        if pose == controller.currentPose { return .accentColor.opacity(0.6) }
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
                // 오토가 안 잡히는 자세(조명·안경 등)를 위한 탈출구.
                Button(T("직접 촬영", "Capture now")) { controller.requestCapture() }
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
