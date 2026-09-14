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

    /// 품질 게이트 탈락 사유.
    ///
    /// 사유를 남기는 이유: 게이트가 조용히 떨어뜨리면 로그에는 "얼굴 12,
    /// 임베딩 0" 같은 줄만 남아서, 얼굴이 작아서인지 잘려서인지 흐려서인지
    /// 알 수가 없다. 2026-09-08 의 8.6초 해제를 조사할 때 그래서 막혔다.
    enum Rejection {
        /// 얼굴 한 변이 [Config.minFacePixels] 보다 작다.
        case tooSmall
        /// 프레임 가장자리에 닿아 잘렸다.
        case touchesEdge
        /// Vision 이 매긴 캡처 품질이 [Config.minCaptureQuality] 미만이다.
        case lowQuality

        var label: String {
            switch self {
            case .tooSmall: return "작음"
            case .touchesEdge: return "잘림"
            case .lowQuality: return "흐림"
            }
        }
    }

    /// 이 얼굴을 임베딩에 써도 되는지 판정한다.
    func passesQualityGate(_ observation: VNFaceObservation, in pixelBuffer: CVPixelBuffer) -> Bool {
        qualityRejection(observation, in: pixelBuffer) == nil
    }

    /// 통과하면 nil, 아니면 떨어뜨린 이유.
    func qualityRejection(_ observation: VNFaceObservation, in pixelBuffer: CVPixelBuffer) -> Rejection? {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bb = observation.boundingBox

        let faceW = Int(bb.width * CGFloat(w))
        let faceH = Int(bb.height * CGFloat(h))
        guard min(faceW, faceH) >= config.minFacePixels else { return .tooSmall }

        guard alignmentPointsAreInFrame(observation, width: w, height: h) else { return .touchesEdge }

        if let q = observation.faceCaptureQuality, q < config.minCaptureQuality { return .lowQuality }
        return nil
    }

    /// 정렬에 실제로 쓰는 5점이 프레임 안에 있는지 본다.
    ///
    /// **바운딩 박스가 아니라 5점을 보는 이유.** 예전에는 `observation.boundingBox`
    /// 의 네 변이 모두 프레임 안에 있는지 봤다. 그런데 ArcFace 정렬은 박스를
    /// 아예 쓰지 않는다 — [FaceAligner] 는 눈·코·입꼬리 5점으로 유사변환을 풀
    /// 뿐이다(`FaceLandmarks5` → `SimilarityTransform.solve`). 반면 Vision 의
    /// 얼굴 박스는 이마 위·턱 아래·귀 바깥까지 넉넉히 잡아서, 노트북 앞에
    /// 평범하게 앉아 있어도 박스만 화면 밖으로 나가는 일이 흔하다. 그러면
    /// **정렬에 필요한 점은 전부 프레임 안에 있는데도** 임베딩을 아예 못 만든다.
    ///
    /// 2026-09-09 09:07 해제 로그가 그 경우였다. 검출된 얼굴 41장 중 40장이
    /// 이 검사에 걸려 버려졌고(평균 밝기 105~151 — 조명 문제가 아니다),
    /// 5.8초 걸린 해제의 4초 넘는 시간이 여기서 샜다.
    ///
    /// 정말 못 쓰게 잘린 얼굴은 그대로 걸러진다. 5점 중 하나라도 프레임 밖이면
    /// 여기서 떨어지고, 그러고도 정렬이 망가지는 경우는 [FaceAligner] 가
    /// `aligned.extent` 로 한 번 더 막는다.
    private func alignmentPointsAreInFrame(_ observation: VNFaceObservation,
                                           width: Int, height: Int) -> Bool {
        let size = CGSize(width: width, height: height)
        guard let landmarks = FaceLandmarks5(observation: observation, imageSize: size) else {
            // 5점을 못 뽑으면 정렬 자체가 불가능하다. 굳이 통과시킬 이유가 없으니
            // 예전처럼 박스로 판단한다.
            return boundingBoxIsInFrame(observation, width: width, height: height)
        }
        let m = CGFloat(config.edgeMarginPixels)
        return landmarks.asArray.allSatisfy { p in
            p.x >= m && p.y >= m && p.x <= CGFloat(width) - m && p.y <= CGFloat(height) - m
        }
    }

    private func boundingBoxIsInFrame(_ observation: VNFaceObservation,
                                      width: Int, height: Int) -> Bool {
        // boundingBox 는 좌하단 원점 정규화 좌표.
        let bb = observation.boundingBox
        let m = config.edgeMarginPixels
        return Int(bb.minX * CGFloat(width)) >= m
            && Int(bb.minY * CGFloat(height)) >= m
            && Int(bb.maxX * CGFloat(width)) <= width - m
            && Int(bb.maxY * CGFloat(height)) <= height - m
    }

    /// 진단용 — 버려진 얼굴의 실제 기하를 한 줄로 적는다.
    ///
    /// 이 앱은 잠금화면에서 돌기 때문에 재현이 어렵다. 다음에 같은 증상이 오면
    /// 숫자부터 보고 시작할 수 있게, 버린 프레임의 박스와 5점 범위를 남긴다.
    func geometryNote(_ observation: VNFaceObservation, in pixelBuffer: CVPixelBuffer) -> String {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bb = observation.boundingBox
        let box = "박스 \(Int(bb.minX * CGFloat(w)))~\(Int(bb.maxX * CGFloat(w)))"
            + "×\(Int(bb.minY * CGFloat(h)))~\(Int(bb.maxY * CGFloat(h)))"
        guard let lm = FaceLandmarks5(observation: observation,
                                      imageSize: CGSize(width: w, height: h)) else {
            return "\(box) / 5점 없음 (\(w)×\(h))"
        }
        let xs = lm.asArray.map(\.x), ys = lm.asArray.map(\.y)
        let pts = "5점 \(Int(xs.min()!))~\(Int(xs.max()!))×\(Int(ys.min()!))~\(Int(ys.max()!))"
        return "\(box) / \(pts) (\(w)×\(h))"
    }
}
