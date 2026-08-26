import CoreGraphics
import CoreVideo
import Foundation

/// 사진 없이 정렬 기하를 검증한다.
///
/// 얼굴 사진이 없어도 확인할 수 있어야 하는 두 가지가 있다.
///   1. `SimilarityTransform` 이 5점을 canonical 위치로 정확히 옮기는가
///   2. 렌더 결과 비트맵이 **뒤집히지 않았는가** (눈이 위쪽 행에 오는가)
///
/// 2번이 특히 중요하다. CoreImage 는 좌하단 원점, 비트맵은 좌상단 원점이라
/// 한 번 뒤집히면 임베딩은 조용히 쓰레기가 된다 — 에러도 안 난다.
enum SelfTest {

    private static let markerColors: [(name: String, rgb: (UInt8, UInt8, UInt8))] = [
        ("왼쪽 눈",   (255, 40, 40)),
        ("오른쪽 눈", (40, 255, 40)),
        ("코",        (40, 40, 255)),
        ("왼쪽 입꼬리", (255, 255, 40)),
        ("오른쪽 입꼬리", (255, 40, 255)),
    ]

    static func run() -> Int32 {
        var failures = 0
        failures += transformResidualTest()
        failures += renderOrientationTest()

        print("")
        if failures == 0 {
            print("✅ 자체 검증 통과 — 정렬 기하와 상하 방향이 모두 정상입니다.")
        } else {
            print("❌ 실패 \(failures)건 — 위 출력을 확인하세요.")
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: 1. 변환 정확도

    /// canonical 5점에 알려진 회전·확대·이동을 걸어 "가짜 얼굴"을 만들고,
    /// 그걸 다시 풀었을 때 원래 canonical 로 돌아오는지 본다.
    private static func transformResidualTest() -> Int {
        print("▶ 유사변환 잔차 검사")

        let angle: CGFloat = 15 * .pi / 180
        let scale: CGFloat = 2.3
        let known = CGAffineTransform(a: scale * cos(angle), b: scale * sin(angle),
                                      c: -scale * sin(angle), d: scale * cos(angle),
                                      tx: 190, ty: 120)
        let source = ArcFaceCanonical.points.map { $0.applying(known) }

        guard let solved = SimilarityTransform.solve(from: source,
                                                     to: ArcFaceCanonical.points) else {
            print("  ❌ 변환을 풀지 못했습니다")
            return 1
        }

        var worst: CGFloat = 0
        for (i, point) in source.enumerated() {
            let mapped = point.applying(solved)
            let target = ArcFaceCanonical.points[i]
            let d = hypot(mapped.x - target.x, mapped.y - target.y)
            worst = max(worst, d)
        }
        print(String(format: "  최대 오차: %.6f px", worst))

        // 회전이 섞여 있으므로 부호(거울상)가 뒤집히면 여기서 크게 어긋난다.
        guard worst < 0.01 else {
            print("  ❌ 잔차가 너무 큽니다")
            return 1
        }
        print("  ✅ 통과")
        return 0
    }

    // MARK: 2. 렌더 방향

    /// 5점 위치에 색 마커를 찍은 합성 프레임을 실제 정렬 경로에 통과시키고,
    /// 각 마커가 canonical 픽셀 위치(좌상단 원점 행/열)에 왔는지 확인한다.
    private static func renderOrientationTest() -> Int {
        print("\n▶ 렌더 상하 방향 검사")

        let width = 640, height = 480

        // 실제 얼굴처럼 살짝 기울고 화면 중앙에 놓인 배치 (좌하단 원점 좌표).
        let angle: CGFloat = -8 * .pi / 180
        let scale: CGFloat = 1.9
        let placement = CGAffineTransform(a: scale * cos(angle), b: scale * sin(angle),
                                          c: -scale * sin(angle), d: scale * cos(angle),
                                          tx: 210, ty: 130)
        let source = ArcFaceCanonical.points.map { $0.applying(placement) }

        guard let buffer = makeFrame(width: width, height: height, markers: source) else {
            print("  ❌ 합성 프레임 생성 실패")
            return 1
        }

        let landmarks = FaceLandmarks5(leftEye: source[0], rightEye: source[1], nose: source[2],
                                       leftMouth: source[3], rightMouth: source[4])

        let aligner = FaceAligner()
        // 노출 정규화·CLAHE 는 색을 흔들어 마커 판별을 방해하므로 끈다.
        guard let pixels = aligner.alignedPixels(from: buffer, landmarks: landmarks,
                                                 applyCLAHE: false, normalize: false) else {
            print("  ❌ 정렬 실패")
            return 1
        }

        // ArcFace 원좌표(좌상단 원점) = 비트맵 행/열이어야 한다.
        let expected: [CGPoint] = [
            CGPoint(x: 38.2946, y: 51.6963),
            CGPoint(x: 73.5318, y: 51.5014),
            CGPoint(x: 56.0252, y: 71.7366),
            CGPoint(x: 41.5493, y: 92.3655),
            CGPoint(x: 70.7299, y: 92.2041),
        ]

        var failures = 0
        for (i, marker) in markerColors.enumerated() {
            guard let found = centroidOfColor(marker.rgb, in: pixels, size: FaceAligner.size) else {
                print("  ❌ \(marker.name): 마커를 찾지 못했습니다 (정렬 결과가 비었을 수 있음)")
                failures += 1
                continue
            }
            let target = expected[i]
            let d = hypot(found.x - target.x, found.y - target.y)
            let mark = d < 2.0 ? "✅" : "❌"
            print(String(format: "  %@ %@: 기대 (%.1f, %.1f) → 실제 (%.1f, %.1f), 오차 %.2f px",
                         mark, marker.name, target.x, target.y, found.x, found.y, d))
            if d >= 2.0 { failures += 1 }
        }

        if failures > 0 {
            print("  힌트: 모든 y 가 (112 - 기대값) 근처라면 비트맵이 상하 반전된 것입니다.")
        }
        return failures > 0 ? 1 : 0
    }

    // MARK: 합성 프레임

    /// 중간 회색 바탕에 색 사각형 마커를 찍은 BGRA 프레임.
    /// 좌표는 좌하단 원점(Vision/CoreImage 규약)으로 받는다.
    private static func makeFrame(width: Int, height: Int, markers: [CGPoint]) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
                == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.bindMemory(to: UInt8.self, capacity: stride * height)

        for row in 0..<height {
            for col in 0..<width {
                let o = row * stride + col * 4
                ptr[o + 0] = 128; ptr[o + 1] = 128; ptr[o + 2] = 128; ptr[o + 3] = 255
            }
        }

        // 정렬 배율(약 1.9배 축소)을 고려해 마커를 넉넉히 크게 찍는다.
        let radius = 4
        for (i, point) in markers.enumerated() {
            let (r, g, b) = markerColors[i].rgb
            let cx = Int(point.x.rounded())
            let row0 = height - 1 - Int(point.y.rounded())   // 좌하단 → 좌상단 행
            for dy in -radius...radius {
                for dx in -radius...radius {
                    let row = row0 + dy, col = cx + dx
                    guard row >= 0, row < height, col >= 0, col < width else { continue }
                    let o = row * stride + col * 4
                    ptr[o + 0] = b; ptr[o + 1] = g; ptr[o + 2] = r; ptr[o + 3] = 255
                }
            }
        }
        return buffer
    }

    /// RGBA 버퍼에서 주어진 색에 가장 가까운 픽셀들의 무게중심 (열, 행).
    private static func centroidOfColor(_ rgb: (UInt8, UInt8, UInt8),
                                        in pixels: [UInt8], size: Int) -> CGPoint? {
        var sumX = 0.0, sumY = 0.0, count = 0.0
        let (tr, tg, tb) = (Double(rgb.0), Double(rgb.1), Double(rgb.2))

        for row in 0..<size {
            for col in 0..<size {
                let o = (row * size + col) * 4
                let r = Double(pixels[o]), g = Double(pixels[o + 1]), b = Double(pixels[o + 2])
                // 보간 때문에 색이 흐려지므로 거리 허용치를 넉넉히 준다.
                let d = ((r - tr) * (r - tr) + (g - tg) * (g - tg) + (b - tb) * (b - tb)).squareRoot()
                guard d < 90 else { continue }
                sumX += Double(col); sumY += Double(row); count += 1
            }
        }
        guard count > 0 else { return nil }
        return CGPoint(x: sumX / count, y: sumY / count)
    }
}
