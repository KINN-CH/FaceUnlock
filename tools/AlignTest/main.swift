import AppKit
import CoreImage
import CoreVideo
import Foundation

// 정렬 파이프라인 눈으로 확인용 CLI.
//
//   make aligntest
//   ./build/aligntest 사진1.jpg 사진2.jpg ...
//
// 각 사진에 대해 <원본이름>.aligned.png 를 옆에 떨궈서 112×112 정렬 결과가
// 똑바로(눈이 위, 입이 아래) 나오는지 확인한다. 뒤집혀 있으면 임베딩은
// 조용히 쓰레기가 되므로 이 확인을 건너뛰면 안 된다.
//
// FACEUNLOCK_MODEL=Resources/Models/ArcFace.mlpackage 를 함께 주면
// 사진들 사이의 코사인 유사도 표까지 출력한다 (동일인 > 0.6, 타인 < 0.3 이 목표).

let arguments = Array(CommandLine.arguments.dropFirst())

// 사진 없이 기하만 검증하는 모드. 사진을 아직 못 구했을 때 여기부터 통과시킨다.
if arguments.first == "--selftest" {
    exit(SelfTest.run())
}

// 전처리 교차 검증용 — 고정 입력의 임베딩만 출력한다.
if arguments.first == "--dump-fixture" {
    exit(SelfTest.dumpFixtureEmbedding())
}

guard !arguments.isEmpty else {
    print("사용법: aligntest <이미지> [<이미지> ...]")
    print("        aligntest --selftest      # 사진 없이 정렬 기하/방향 검증")
    exit(2)
}

let ciContext = CIContext()

/// 파일을 CVPixelBuffer(BGRA)로 읽는다. 카메라 프레임과 같은 형식이어야
/// 실제 동작과 같은 경로를 탄다.
func loadPixelBuffer(_ url: URL) -> CVPixelBuffer? {
    guard let image = CIImage(contentsOf: url) else { return nil }
    let extent = image.extent
    let width = Int(extent.width), height = Int(extent.height)
    guard width > 0, height > 0 else { return nil }

    var buffer: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                              attributes as CFDictionary, &buffer) == kCVReturnSuccess,
          let buffer else { return nil }

    ciContext.render(image.transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                                             y: -extent.origin.y)),
                     to: buffer)
    return buffer
}

func writePNG(_ rgba: [UInt8], size: Int, to url: URL) {
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let cgImage = CGImage(width: size, height: size,
                                bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent) else {
        print("  PNG 생성 실패")
        return
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
}

let detector = FaceDetector()
let aligner = FaceAligner()

var model: EmbeddingModel?
if ProcessInfo.processInfo.environment["FACEUNLOCK_MODEL"] != nil {
    do { model = try EmbeddingModel() }
    catch { print("모델 로드 실패: \(error.localizedDescription)") }
}

var names: [String] = []
var vectors: [[Float]] = []

for path in arguments {
    let url = URL(fileURLWithPath: path)
    print("\n▶ \(url.lastPathComponent)")

    guard let buffer = loadPixelBuffer(url) else {
        print("  이미지를 읽지 못했습니다")
        continue
    }
    print("  크기: \(CVPixelBufferGetWidth(buffer))×\(CVPixelBufferGetHeight(buffer))")

    guard let face = detector.detectPrimaryFace(in: buffer) else {
        print("  얼굴 검출 실패")
        continue
    }
    let box = face.boundingBox
    print(String(format: "  얼굴 박스: x=%.3f y=%.3f w=%.3f h=%.3f", box.origin.x, box.origin.y, box.width, box.height))
    print("  품질 게이트: \(detector.passesQualityGate(face, in: buffer) ? "통과" : "탈락")")

    guard let pixels = aligner.alignedPixels(from: buffer, observation: face) else {
        print("  정렬 실패 (랜드마크 부족 또는 프레임 밖)")
        continue
    }

    let out = url.deletingPathExtension().appendingPathExtension("aligned.png")
    writePNG(pixels, size: FaceAligner.size, to: out)
    print("  정렬 결과 → \(out.lastPathComponent)")

    if let model, let vector = model.embed(alignedRGBA: pixels) {
        var norm: Float = 0
        for v in vector { norm += v * v }
        print(String(format: "  임베딩 %d차원 (L2=%.4f)", vector.count, norm.squareRoot()))
        names.append(url.deletingPathExtension().lastPathComponent)
        vectors.append(vector)
    }
}

if vectors.count >= 2 {
    print("\n=== 코사인 유사도 ===")
    for i in 0..<vectors.count {
        for j in (i + 1)..<vectors.count {
            let s = VectorMath.cosineSimilarity(vectors[i], vectors[j])
            let verdict = s >= 0.48 ? "동일인 판정" : "타인 판정"
            print(String(format: "  %@ ↔ %@ : %.4f  (%@)", names[i], names[j], s, verdict))
        }
    }
    print("\n  기준: 동일인 > 0.6, 타인 < 0.3 이면 모델 변환이 정상입니다.")
}
