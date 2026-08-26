import CoreVideo
import Foundation
import Vision

/// Vision 얼굴 검출 + 품질 게이트.
///
/// 품질 게이트가 있는 이유: 흐릿하거나, 너무 작거나, 프레임 밖으로 잘린 얼굴은
/// 임베딩이 크게 흔들린다. 그런 프레임으로 판정하면 오인식(타인 통과)과
/// 오거부(본인 실패)가 동시에 늘어난다. 애초에 버리는 편이 낫다.
final class FaceDetector {

    struct Config {
        /// 얼굴 한 변의 최소 픽셀 수.
        var minFacePixels = 64
        /// 프레임 가장자리에서 이만큼 떨어져 있어야 한다(잘린 얼굴 배제).
        var edgeMarginPixels = 5
        /// Vision 이 매기는 캡처 품질 하한.
        var minCaptureQuality: Float = 0.10
    }

    var config = Config()

    private let sequenceHandler = VNSequenceRequestHandler()

    /// 가장 큰 얼굴 하나만 돌려준다. 잠금 해제는 "화면 앞의 사람" 한 명만 상대한다.
    func detectPrimaryFace(in pixelBuffer: CVPixelBuffer) -> VNFaceObservation? {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3

        do {
            // 내장 카메라는 좌우 반전된 상을 주지만, 반전 여부는 등록/인증에서 동일하므로
            // 굳이 되돌리지 않는다. .up 으로 통일한다.
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: .up)
        } catch {
            Log.face.error("Vision 검출 실패: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let faces = request.results, !faces.isEmpty else { return nil }
        return faces.max { areaOf($0) < areaOf($1) }
    }

    private func areaOf(_ o: VNFaceObservation) -> CGFloat {
        o.boundingBox.width * o.boundingBox.height
    }

    /// 이 얼굴을 임베딩에 써도 되는지 판정한다.
    func passesQualityGate(_ observation: VNFaceObservation, in pixelBuffer: CVPixelBuffer) -> Bool {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bb = observation.boundingBox

        let faceW = Int(bb.width * CGFloat(w))
        let faceH = Int(bb.height * CGFloat(h))
        guard min(faceW, faceH) >= config.minFacePixels else { return false }

        // boundingBox 는 좌하단 원점 정규화 좌표.
        let left = Int(bb.minX * CGFloat(w))
        let right = Int(bb.maxX * CGFloat(w))
        let bottom = Int(bb.minY * CGFloat(h))
        let top = Int(bb.maxY * CGFloat(h))
        let m = config.edgeMarginPixels
        guard left >= m, bottom >= m, right <= w - m, top <= h - m else { return false }

        if let q = observation.faceCaptureQuality, q < config.minCaptureQuality { return false }
        return true
    }
}
