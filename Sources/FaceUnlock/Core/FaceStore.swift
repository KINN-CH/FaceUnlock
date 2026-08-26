import Foundation

/// 등록 때 채워야 하는 포즈 버킷. 한 각도만 등록하면 조금만 고개를 돌려도 인식이 깨진다.
enum FacePose: String, CaseIterable, Codable {
    case center, left, right, up, down, tiltLeft, tiltRight, closer, farther

    var instruction: String {
        switch self {
        case .center:    return "정면을 바라보세요"
        case .left:      return "고개를 왼쪽으로 살짝 돌리세요"
        case .right:     return "고개를 오른쪽으로 살짝 돌리세요"
        case .up:        return "턱을 살짝 드세요"
        case .down:      return "턱을 살짝 당기세요"
        case .tiltLeft:  return "고개를 왼쪽으로 기울이세요"
        case .tiltRight: return "고개를 오른쪽으로 기울이세요"
        case .closer:    return "화면에 조금 더 가까이 오세요"
        case .farther:   return "화면에서 조금 물러나세요"
        }
    }
}

struct FaceSample: Codable {
    var pose: FacePose
    var vector: [Float]
}

struct FaceProfile: Codable {
    var version: Int = 1
    var createdAt: Date = Date()
    var samples: [FaceSample] = []
    var centroid: [Float] = []

    var enrolledPoses: Set<FacePose> { Set(samples.map(\.pose)) }
    var isComplete: Bool { enrolledPoses.count >= FacePose.allCases.count }

    /// 카메라 큐에서도 호출해야 하므로 매칭은 값 타입 쪽에 둔다.
    func match(_ vector: [Float]) -> MatchResult? {
        guard !samples.isEmpty else { return nil }

        var best: Float = -1
        var bestPose: FacePose?
        for sample in samples {
            let similarity = VectorMath.cosineSimilarity(vector, sample.vector)
            if similarity > best {
                best = similarity
                bestPose = sample.pose
            }
        }
        let centroidScore = centroid.isEmpty ? -1 : VectorMath.cosineSimilarity(vector, centroid)
        return MatchResult(bestSample: best, centroid: centroidScore, pose: bestPose)
    }

    mutating func add(_ vector: [Float], pose: FacePose) {
        samples.removeAll { $0.pose == pose }
        samples.append(FaceSample(pose: pose, vector: vector))
        centroid = VectorMath.centroid(samples.map(\.vector))
    }
}

struct MatchResult {
    /// 개별 샘플 중 최고 유사도.
    let bestSample: Float
    /// 등록 얼굴 전체의 평균 방향과의 유사도.
    let centroid: Float
    let pose: FacePose?

    /// 둘 중 큰 값을 쓴다. centroid 는 안정적이지만 극단 포즈에서 떨어지고,
    /// 개별 최대값은 그 반대라 서로를 보완한다.
    var score: Float { max(bestSample, centroid) }

    func passes(threshold: Float) -> Bool { score >= threshold }
}

/// 등록된 얼굴 임베딩 저장소.
///
/// 임베딩은 원본 사진으로 복원되지는 않지만 그대로도 생체 식별자다.
/// 평문으로 두지 않고 [EnclaveCrypto] 로 봉인해 Application Support 에 파일로 둔다.
@MainActor
final class FaceStore: ObservableObject {

    static let shared = FaceStore()

    @Published private(set) var profile: FaceProfile?

    var isEnrolled: Bool { profile?.samples.isEmpty == false }
    var enrolledPoseCount: Int { profile?.samples.count ?? 0 }

    private let fileURL: URL

    private init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let appDir = dir.appendingPathComponent("FaceUnlock", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        fileURL = appDir.appendingPathComponent("faces.sealed")
        load()
    }

    // MARK: 입출력

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let sealed = try Data(contentsOf: fileURL)
            let plain = try EnclaveCrypto.open(sealed)
            profile = try JSONDecoder().decode(FaceProfile.self, from: plain)
            Log.face.info("등록 얼굴 로드됨 (샘플 \(self.profile?.samples.count ?? 0)개)")
        } catch {
            // 암호화 키가 바뀐 경우(앱 재서명 등) 여기로 온다. 조용히 무시하지 말고 알린다.
            Log.face.error("등록 얼굴을 읽지 못했습니다: \(error.localizedDescription, privacy: .public)")
            profile = nil
        }
    }

    private func persist() throws {
        guard let profile else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let plain = try JSONEncoder().encode(profile)
        let sealed = try EnclaveCrypto.seal(plain)
        try sealed.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: 등록

    func beginEnrollment() {
        profile = FaceProfile()
    }

    func record(_ vector: [Float], pose: FacePose) throws {
        var current = profile ?? FaceProfile()
        current.add(vector, pose: pose)
        profile = current
        try persist()
        Log.face.info("포즈 \(pose.rawValue, privacy: .public) 등록됨")
    }

    func deleteEnrollment() {
        profile = nil
        try? FileManager.default.removeItem(at: fileURL)
        Log.face.info("등록 얼굴 삭제됨")
    }

    // MARK: 매칭

    func match(_ vector: [Float]) -> MatchResult? { profile?.match(vector) }

    /// 카메라 큐로 넘겨 쓸 스냅샷. 인증 도중 등록 내용이 바뀌어도 세션은 흔들리지 않는다.
    func snapshot() -> FaceProfile? { profile }
}
