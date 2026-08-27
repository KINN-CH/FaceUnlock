import CoreML
import Foundation

/// ArcFace CoreML 래퍼.
///
/// 모델(.mlpackage)은 저장소에 없다 — InsightFace 가중치가 비상업 연구용 라이선스라
/// 재배포하지 않는다. `tools/fetch_arcface.py` 로 각자 받아 번들에 넣는다.
/// 컴파일은 실행 중에 `MLModel.compileModel(at:)` 으로 하므로 Xcode 가 필요 없다.
final class EmbeddingModel {

    enum LoadError: LocalizedError {
        case modelMissing
        case compileFailed(String)
        case badOutput(String)

        var errorDescription: String? {
            switch self {
            case .modelMissing:
                return T("ArcFace 모델이 없습니다. DMG 의 '설치 도우미' 를 실행하거나, "
                         + "저장소에서 make model 을 실행해 주세요.",
                         "The ArcFace model is missing. Run 'Install Helper' from the DMG, "
                         + "or run `make model` in the repository.")
            case .compileFailed(let m): return T("모델 컴파일 실패: \(m)", "Model compilation failed: \(m)")
            case .badOutput(let m):     return T("모델 출력이 예상과 다릅니다: \(m)", "Unexpected model output: \(m)")
            }
        }
    }

    static let embeddingDimension = 512

    private let model: MLModel
    private let inputName: String
    private let outputName: String

    /// 매 프레임 새로 할당하지 않도록 입력 텐서를 재사용한다.
    private let inputArray: MLMultiArray

    // MARK: 로딩

    init() throws {
        let compiled = try Self.compiledModelURL()

        let config = MLModelConfiguration()
        // 뉴럴 엔진을 쓰지 않는다 — 이 앱의 쓰임새에서는 CPU 가 더 빠르다.
        //
        // 같은 ArcFace.mlmodelc 로 실측한 값(M 시리즈, 초당 20프레임 기준):
        //
        //     .all (뉴럴 엔진)  로드 1662ms | 첫 추론    7ms | 이후 2.15ms
        //     .cpuAndGPU        로드  317ms | 첫 추론 1331ms | 이후 10.41ms
        //     .cpuOnly          로드  145ms | 첫 추론   14ms | 이후  8.76ms
        //
        // 프레임당으로 보면 뉴럴 엔진이 4배 빠르지만, 그 차이는 6.6ms 다.
        // 프레임 간격이 50ms 이므로 사용자가 느낄 수 있는 차이가 아니다.
        //
        // 정작 체감되는 건 **차가운 상태에서 첫 얼굴까지** 걸리는 시간인데,
        // 거기서는 뒤집힌다: 1.67초 대 0.16초, 10배 차이다. 게다가 뉴럴 엔진은
        // 한동안 안 쓰인 모델을 메모리에서 내리기 때문에(실측 로그에
        // `unloadModel` 이 그대로 찍힌다) 첫 추론이 6.3초까지 늘어난 적도 있다.
        // 이 앱은 잠금 사건이 올 때만 잠깐 도는 구조라 뉴럴 엔진은 **거의 항상
        // 차갑다** — 최악의 경우만 골라 밟는 셈이다.
        //
        // 예전에는 이걸 1분짜리 예열 타이머로 가렸다. CPU 는 내려갈 일이
        // 없으니 그 타이머도 함께 지웠다.
        //
        // 두 백엔드가 같은 답을 주는지도 확인했다 — 같은 입력에 대해 코사인
        // 유사도 평균 0.998052 / 최저 0.997287. 판정 임계 0.48 에 비하면
        // 무시할 수 있는 차이라, 이미 등록한 얼굴은 그대로 인식된다.
        config.computeUnits = .cpuOnly

        do {
            model = try MLModel(contentsOf: compiled, configuration: config)
        } catch {
            throw LoadError.compileFailed(error.localizedDescription)
        }

        let desc = model.modelDescription
        guard let input = desc.inputDescriptionsByName.keys.first else {
            throw LoadError.badOutput("입력이 없습니다")
        }
        guard let output = desc.outputDescriptionsByName.keys.first else {
            throw LoadError.badOutput("출력이 없습니다")
        }
        inputName = input
        outputName = output

        inputArray = try MLMultiArray(shape: [1, 3, 112, 112], dataType: .float32)
        Log.face.info("ArcFace 로드됨 (입력 \(input, privacy: .public) → 출력 \(output, privacy: .public))")
    }

    /// 모델 탐색 — 실제 로드와 UI 표시(`AppState.modelAvailable`)가 반드시 같은
    /// 규칙을 쓰도록 한 곳에 둔다. 서로 다른 규칙을 쓰면 "모델은 로드되는데
    /// 설정창은 없다고 표시"하는 식으로 어긋난다.
    ///
    /// 탐색 순서: 환경변수(테스트) → 앱 번들(소스 빌드) → Application Support(DMG 배포).
    /// InsightFace 가중치는 비상업 연구용 라이선스라 DMG 에 동봉하지 않는다.
    /// DMG 사용자는 '설치 도우미'가 변환한 .mlpackage 를
    /// ~/Library/Application Support/FaceUnlock/Models/ 에 넣는다.
    static func locateModel() -> URL? {
        // CLI 테스트 하네스는 앱 번들이 없으므로 경로를 환경변수로 넘긴다.
        let override = ProcessInfo.processInfo.environment["FACEUNLOCK_MODEL"].map {
            URL(fileURLWithPath: $0)
        }
        let sideloaded = supportDirectory?
            .appendingPathComponent("Models/ArcFace.mlpackage", isDirectory: true)
        return override
            ?? Bundle.main.url(forResource: "ArcFace", withExtension: "mlpackage",
                               subdirectory: "Models")
            ?? Bundle.main.url(forResource: "ArcFace", withExtension: "mlpackage")
            ?? sideloaded.flatMap {
                FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
            }
    }

    private static var supportDirectory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("FaceUnlock", isDirectory: true)
    }

    /// 번들의 .mlpackage 를 캐시 디렉터리에 컴파일해 두고 재사용한다.
    /// 컴파일은 수 초 걸리므로 매 실행마다 하지 않는다.
    private static func compiledModelURL() throws -> URL {
        guard let packaged = locateModel(), let cacheDir = supportDirectory else {
            throw LoadError.modelMissing
        }
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cached = cacheDir.appendingPathComponent("ArcFace.mlmodelc", isDirectory: true)

        // 번들 모델이 캐시보다 새로우면 다시 컴파일한다.
        if FileManager.default.fileExists(atPath: cached.path),
           let cachedDate = try? cached.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           let sourceDate = try? packaged.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           cachedDate >= sourceDate {
            return cached
        }

        Log.face.info("ArcFace 컴파일 중…")
        let compiled = try MLModel.compileModel(at: packaged)
        try? FileManager.default.removeItem(at: cached)
        try FileManager.default.moveItem(at: compiled, to: cached)
        Log.face.info("ArcFace 컴파일 완료")
        return cached
    }

    // MARK: 추론

    /// 정렬된 112×112 RGBA 픽셀에서 L2 정규화된 512차원 임베딩을 뽑는다.
    ///
    /// - Parameter mirrored: 좌우 반전 입력. 등록 때 원본과 반전본을 평균 내면
    ///   좌우 비대칭 조명에 조금 더 강해진다.
    func embed(alignedRGBA pixels: [UInt8], mirrored: Bool = false) -> [Float]? {
        fillInput(from: pixels, mirrored: mirrored)

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [inputName: inputArray]),
              let result = try? model.prediction(from: provider),
              let out = result.featureValue(for: outputName)?.multiArrayValue else {
            Log.face.error("임베딩 추론 실패")
            return nil
        }

        let count = out.count
        guard count == Self.embeddingDimension else {
            Log.face.error("임베딩 차원 불일치: \(count)")
            return nil
        }

        var vector = [Float](repeating: 0, count: count)
        let ptr = out.dataPointer.bindMemory(to: Float.self, capacity: count)
        for i in 0..<count { vector[i] = ptr[i] }
        return VectorMath.l2Normalized(vector)
    }

    /// RGBA8 → NCHW float32, 값 범위 (x − 127.5) / 127.5.
    /// ArcFace 학습 때의 전처리와 같아야 한다.
    private func fillInput(from pixels: [UInt8], mirrored: Bool) {
        let size = FaceAligner.size
        let ptr = inputArray.dataPointer.bindMemory(to: Float.self, capacity: 3 * size * size)
        let plane = size * size

        for y in 0..<size {
            for x in 0..<size {
                let srcX = mirrored ? (size - 1 - x) : x
                let src = (y * size + srcX) * 4
                let dst = y * size + x
                ptr[0 * plane + dst] = (Float(pixels[src + 0]) - 127.5) / 127.5  // R
                ptr[1 * plane + dst] = (Float(pixels[src + 1]) - 127.5) / 127.5  // G
                ptr[2 * plane + dst] = (Float(pixels[src + 2]) - 127.5) / 127.5  // B
            }
        }
    }
}
