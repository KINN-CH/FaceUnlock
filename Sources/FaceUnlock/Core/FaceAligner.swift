import Accelerate
import CoreImage
import CoreVideo
import Foundation
import Vision

/// 검출된 얼굴을 ArcFace 가 기대하는 112×112 정면 배치로 옮기고,
/// 조명 편차를 줄인 뒤 모델 입력 텐서로 만든다.
///
/// **등록과 인증이 완전히 같은 경로를 타야 한다.** 전처리가 한 단계라도 달라지면
/// 같은 얼굴의 임베딩이 서로 다른 곳에 찍힌다.
final class FaceAligner {

    static let size = 112
    private static let byteCount = size * size * 4   // RGBA8

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var pixels = [UInt8](repeating: 0, count: FaceAligner.byteCount)

    /// 정렬 + 정규화된 112×112 RGBA 픽셀. 반환 버퍼는 재사용되므로 즉시 소비해야 한다.
    func alignedPixels(from pixelBuffer: CVPixelBuffer,
                       observation: VNFaceObservation,
                       applyCLAHE: Bool = true,
                       normalize: Bool = true) -> [UInt8]? {

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let imageSize = CGSize(width: width, height: height)

        guard let landmarks = FaceLandmarks5(observation: observation, imageSize: imageSize) else {
            return nil
        }
        return alignedPixels(from: pixelBuffer, landmarks: landmarks,
                             applyCLAHE: applyCLAHE, normalize: normalize)
    }

    /// 랜드마크를 직접 넘기는 경로. 테스트 하네스가 합성 좌표로 기하 검증할 때 쓴다.
    /// 실제 동작과 **같은 코드**를 타야 검증에 의미가 있으므로 위 함수가 이걸 호출한다.
    func alignedPixels(from pixelBuffer: CVPixelBuffer,
                       landmarks: FaceLandmarks5,
                       applyCLAHE: Bool = true,
                       normalize: Bool = true) -> [UInt8]? {

        guard let transform = SimilarityTransform.solve(from: landmarks.asArray,
                                                        to: ArcFaceCanonical.points) else {
            return nil
        }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let aligned = source
            .transformed(by: transform)
            .cropped(to: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))

        // 얼굴이 프레임 가장자리에 걸쳐 정렬 결과가 비었으면 버린다.
        let extent = aligned.extent
        guard !extent.isEmpty,
              extent.origin.x.isFinite, extent.origin.y.isFinite,
              extent.size.width.isFinite, extent.size.height.isFinite else { return nil }

        pixels.withUnsafeMutableBytes { raw in
            ciContext.render(aligned,
                             toBitmap: raw.baseAddress!,
                             rowBytes: Self.size * 4,
                             bounds: CGRect(x: 0, y: 0, width: Self.size, height: Self.size),
                             format: .RGBA8,
                             colorSpace: CGColorSpaceCreateDeviceRGB())
        }

        if normalize { normalizeExposure(&pixels) }
        if applyCLAHE { Self.applyCLAHE(&pixels, size: Self.size) }
        return pixels
    }

    // MARK: 노출 정규화

    /// 밝기 평균/표준편차를 목표값으로 선형 이동시킨다.
    /// 잠금 화면은 조명이 제각각이라(밤중 화면 불빛만, 창가 역광 등) 이 보정이 없으면
    /// 같은 얼굴도 임베딩이 크게 흔들린다.
    private func normalizeExposure(_ buf: inout [UInt8]) {
        let targetMean: Double = 128
        let targetStd: Double = 52

        var sum = 0.0, sumSq = 0.0
        var count = 0.0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let y = 0.299 * Double(buf[i]) + 0.587 * Double(buf[i + 1]) + 0.114 * Double(buf[i + 2])
            sum += y
            sumSq += y * y
            count += 1
        }
        guard count > 0 else { return }
        let mean = sum / count
        let variance = max(sumSq / count - mean * mean, 1)
        let std = variance.squareRoot()

        // 지나친 증폭은 노이즈만 키운다.
        let gain = min(max(targetStd / std, 0.5), 2.5)
        let bias = targetMean - mean * gain

        for i in stride(from: 0, to: buf.count, by: 4) {
            for c in 0..<3 {
                let v = Double(buf[i + c]) * gain + bias
                buf[i + c] = UInt8(max(0, min(255, v.rounded())))
            }
        }
    }

    // MARK: CLAHE (Contrast Limited Adaptive Histogram Equalization)

    /// 국소 대비 평활화. 얼굴 절반만 빛을 받는 상황(스탠드 조명, 창가)에서
    /// 그늘진 쪽의 디테일을 살려준다. 휘도에만 적용하고 색은 비율로 되돌린다.
    static func applyCLAHE(_ buf: inout [UInt8], size: Int,
                           tiles: Int = 8, clipFactor: Double = 3.0) {
        let tileW = size / tiles
        let tileH = size / tiles
        guard tileW > 0, tileH > 0 else { return }

        // 1) 휘도 평면
        var luma = [Double](repeating: 0, count: size * size)
        for p in 0..<(size * size) {
            let i = p * 4
            luma[p] = 0.299 * Double(buf[i]) + 0.587 * Double(buf[i + 1]) + 0.114 * Double(buf[i + 2])
        }

        // 2) 타일별 클리핑 히스토그램 → 누적분포 LUT
        var luts = [[Double]](repeating: [Double](repeating: 0, count: 256),
                              count: tiles * tiles)
        let tilePixels = tileW * tileH
        let clipLimit = max(1.0, clipFactor * Double(tilePixels) / 256.0)

        for ty in 0..<tiles {
            for tx in 0..<tiles {
                var hist = [Double](repeating: 0, count: 256)
                for y in (ty * tileH)..<min((ty + 1) * tileH, size) {
                    for x in (tx * tileW)..<min((tx + 1) * tileW, size) {
                        hist[Int(max(0, min(255, luma[y * size + x])))] += 1
                    }
                }
                // 클리핑: 한계를 넘은 만큼 잘라 전체에 고르게 재분배한다.
                // (재분배 없이 자르기만 하면 밝기가 어두워진다)
                var excess = 0.0
                for b in 0..<256 where hist[b] > clipLimit {
                    excess += hist[b] - clipLimit
                    hist[b] = clipLimit
                }
                let share = excess / 256.0
                var cumulative = 0.0
                let total = Double(tilePixels)
                for b in 0..<256 {
                    cumulative += hist[b] + share
                    luts[ty * tiles + tx][b] = min(255.0, 255.0 * cumulative / total)
                }
            }
        }

        // 3) 픽셀마다 인접 타일 4개의 LUT 를 겹선형 보간 (타일 경계 계단 방지)
        for y in 0..<size {
            let fy = Double(y) / Double(tileH) - 0.5
            let ty0 = max(0, min(tiles - 1, Int(fy.rounded(.down))))
            let ty1 = max(0, min(tiles - 1, ty0 + 1))
            let wy = max(0.0, min(1.0, fy - Double(ty0)))

            for x in 0..<size {
                let fx = Double(x) / Double(tileW) - 0.5
                let tx0 = max(0, min(tiles - 1, Int(fx.rounded(.down))))
                let tx1 = max(0, min(tiles - 1, tx0 + 1))
                let wx = max(0.0, min(1.0, fx - Double(tx0)))

                let p = y * size + x
                let b = Int(max(0, min(255, luma[p])))
                let v00 = luts[ty0 * tiles + tx0][b]
                let v01 = luts[ty0 * tiles + tx1][b]
                let v10 = luts[ty1 * tiles + tx0][b]
                let v11 = luts[ty1 * tiles + tx1][b]
                let newY = (v00 * (1 - wx) + v01 * wx) * (1 - wy)
                          + (v10 * (1 - wx) + v11 * wx) * wy

                // 색상은 유지하고 밝기만 스케일한다.
                let oldY = max(luma[p], 1.0)
                let scale = newY / oldY
                let i = p * 4
                for c in 0..<3 {
                    buf[i + c] = UInt8(max(0, min(255, (Double(buf[i + c]) * scale).rounded())))
                }
            }
        }
    }
}
