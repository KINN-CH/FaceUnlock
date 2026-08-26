import CoreGraphics
import Foundation
import Vision

/// ArcFace 가 학습 때 쓴 112×112 정렬 기준점 5개.
///
/// 원 논문/InsightFace 구현의 좌표는 좌상단 원점 기준이다. Vision 과 CoreImage 는
/// 좌하단 원점을 쓰므로 y 를 뒤집어 둔다.
enum ArcFaceCanonical {
    static let size: CGFloat = 112

    static let points: [CGPoint] = [
        CGPoint(x: 38.2946, y: size - 51.6963),  // 왼쪽 눈
        CGPoint(x: 73.5318, y: size - 51.5014),  // 오른쪽 눈
        CGPoint(x: 56.0252, y: size - 71.7366),  // 코
        CGPoint(x: 41.5493, y: size - 92.3655),  // 왼쪽 입꼬리
        CGPoint(x: 70.7299, y: size - 92.2041),  // 오른쪽 입꼬리
    ]
}

/// 얼굴에서 뽑아낸 5개 기준점 (이미지 픽셀 좌표, 좌하단 원점).
struct FaceLandmarks5 {
    var leftEye: CGPoint
    var rightEye: CGPoint
    var nose: CGPoint
    var leftMouth: CGPoint
    var rightMouth: CGPoint

    var asArray: [CGPoint] { [leftEye, rightEye, nose, leftMouth, rightMouth] }

    init(leftEye: CGPoint, rightEye: CGPoint, nose: CGPoint,
         leftMouth: CGPoint, rightMouth: CGPoint) {
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.nose = nose
        self.leftMouth = leftMouth
        self.rightMouth = rightMouth
    }

    /// Vision 관찰 결과에서 5점을 추출한다.
    ///
    /// Vision 은 눈/코/입을 여러 점의 영역으로 준다. 영역별로 대표점 하나를 고르되,
    /// **등록과 인증이 반드시 같은 규칙을 쓰도록** 이 한 곳에서만 정의한다.
    /// (규칙이 달라지면 같은 얼굴인데도 임베딩이 어긋난다.)
    init?(observation: VNFaceObservation, imageSize: CGSize) {
        guard let lm = observation.landmarks,
              let leftEyeRegion = lm.leftEye,
              let rightEyeRegion = lm.rightEye,
              let noseRegion = lm.nose,
              let lipsRegion = lm.outerLips
        else { return nil }

        func centroid(_ region: VNFaceLandmarkRegion2D) -> CGPoint? {
            let pts = region.pointsInImage(imageSize: imageSize)
            guard !pts.isEmpty else { return nil }
            let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
        }

        guard let le = centroid(leftEyeRegion),
              let re = centroid(rightEyeRegion),
              let no = centroid(noseRegion)
        else { return nil }

        // 입꼬리는 가장 왼쪽/오른쪽 점. 중심점보다 회전에 민감해서 정렬 정확도가 높다.
        let lipPts = lipsRegion.pointsInImage(imageSize: imageSize)
        guard let lm0 = lipPts.min(by: { $0.x < $1.x }),
              let rm0 = lipPts.max(by: { $0.x < $1.x })
        else { return nil }

        self.leftEye = le
        self.rightEye = re
        self.nose = no
        self.leftMouth = lm0
        self.rightMouth = rm0
    }
}

/// 5점을 ArcFace 기준 배치로 옮기는 유사변환(회전 + 균일 배율 + 평행이동)을 구한다.
///
/// 2D 유사변환은 복소수 한 번의 곱셈과 같으므로 SVD 없이 닫힌 형태로 최소제곱해가 나온다.
/// `w ≈ α·z + β` 에서
///     α = Σ conj(z_i - z̄)(w_i - w̄) / Σ |z_i - z̄|²
///     β = w̄ - α·z̄
/// 반사(거울상)를 허용하지 않는 Umeyama 해와 동일하다.
enum SimilarityTransform {
    static func solve(from source: [CGPoint], to destination: [CGPoint]) -> CGAffineTransform? {
        guard source.count == destination.count, source.count >= 2 else { return nil }
        let n = CGFloat(source.count)

        let srcMean = source.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let dstMean = destination.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let zBar = CGPoint(x: srcMean.x / n, y: srcMean.y / n)
        let wBar = CGPoint(x: dstMean.x / n, y: dstMean.y / n)

        var numRe: CGFloat = 0, numIm: CGFloat = 0, den: CGFloat = 0
        for (s, d) in zip(source, destination) {
            let zx = s.x - zBar.x, zy = s.y - zBar.y
            let wx = d.x - wBar.x, wy = d.y - wBar.y
            // conj(z) * w = (zx - i·zy)(wx + i·wy)
            numRe += zx * wx + zy * wy
            numIm += zx * wy - zy * wx
            den += zx * zx + zy * zy
        }
        guard den > .ulpOfOne else { return nil }

        let ar = numRe / den   // α 의 실수부 = s·cosθ
        let ai = numIm / den   // α 의 허수부 = s·sinθ
        let bx = wBar.x - (ar * zBar.x - ai * zBar.y)
        let by = wBar.y - (ai * zBar.x + ar * zBar.y)

        // CGAffineTransform: x' = a·x + c·y + tx,  y' = b·x + d·y + ty
        return CGAffineTransform(a: ar, b: ai, c: -ai, d: ar, tx: bx, ty: by)
    }
}
