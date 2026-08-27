import SwiftUI

/// 카메라 미리보기.
///
/// [PreviewFeed] 가 흘려보내는 프레임을 그대로 그린다. AVFoundation 의
/// 미리보기 레이어를 쓰지 않는 이유는 [PreviewFeed] 주석에 적어두었다.
struct CameraPreview: View {

    @ObservedObject private var feed = PreviewFeed.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        ZStack {
            Color.black
            if let image = feed.frame {
                // CGImage 는 첫 행이 화면 위쪽이다. `.upMirrored` 로 좌우만
                // 뒤집어 거울처럼 보여준다 — 그래야 사용자가 자기 움직임을
                // 직관적으로 맞출 수 있다. 분석 프레임은 뒤집지 않는다.
                Image(decorative: image, scale: 1, orientation: .upMirrored)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // 검은 사각형만 두면 고장인지 준비 중인지 알 수 없다.
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(T("카메라를 켜는 중…", "Starting the camera…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // 화면이 살아 있는 동안에만 프레임을 CGImage 로 바꾼다. 잠금화면
        // 인증에는 미리보기가 없으므로 그 경로는 이 비용을 전혀 내지 않는다.
        .onAppear { CameraSession.shared.beginPreview() }
        .onDisappear { CameraSession.shared.endPreview() }
    }
}
