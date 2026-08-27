import Foundation

/// 등록 때 채워야 하는 포즈 버킷. 한 각도만 등록하면 조금만 고개를 돌려도 인식이 깨진다.
enum FacePose: String, CaseIterable, Codable {
    case center, left, right, up, down, tiltLeft, tiltRight, closer, farther

    var instruction: String {
        switch self {
        case .center:    return T("정면을 바라보세요", "Look straight at the camera")
        case .left:      return T("고개를 왼쪽으로 살짝 돌리세요", "Turn your head slightly left")
        case .right:     return T("고개를 오른쪽으로 살짝 돌리세요", "Turn your head slightly right")
        case .up:        return T("턱을 살짝 드세요", "Tilt your chin up slightly")
        case .down:      return T("턱을 살짝 당기세요", "Tuck your chin down slightly")
        case .tiltLeft:  return T("고개를 왼쪽으로 기울이세요", "Tilt your head to the left")
        case .tiltRight: return T("고개를 오른쪽으로 기울이세요", "Tilt your head to the right")
        case .closer:    return T("화면에 조금 더 가까이 오세요", "Move a little closer")
        case .farther:   return T("화면에서 조금 물러나세요", "Move a little farther back")
        }
    }
}

struct FaceSample: Codable {
    var pose: FacePose
    var vector: [Float]
}

/// 등록된 사람 한 명. 이름은 구분용 표시일 뿐 인증에는 쓰이지 않는다.
struct EnrolledPerson: Codable, Identifiable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var samples: [FaceSample] = []
    var centroid: [Float] = []

    /// 이 사람의 등록 샘플들과 비교한 최고 점수.
    func match(_ vector: [Float]) -> MatchResult? {
        guard !samples.isEmpty else { return nil }

        var best: Float = -1
        for sample in samples {
            let similarity = VectorMath.cosineSimilarity(vector, sample.vector)
            if similarity > best { best = similarity }
        }
        let centroidScore = centroid.isEmpty ? -1 : VectorMath.cosineSimilarity(vector, centroid)
        return MatchResult(bestSample: best, centroid: centroidScore, personName: name)
    }
}

/// 등록된 사람들의 묶음. 저장 파일의 최상위 형식이기도 하다 (version 2).
struct FaceRoster: Codable {
    var version: Int = 2
    var people: [EnrolledPerson] = []

    var isEmpty: Bool { people.allSatisfy(\.samples.isEmpty) }
    var sampleCount: Int { people.reduce(0) { $0 + $1.samples.count } }

    /// 등록된 모든 사람과 비교해 가장 잘 맞는 결과를 돌려준다.
    ///
    /// 사람 수(≤3) × 포즈 수(9)의 코사인 유사도라 비용은 무시할 수준이다.
    /// 카메라 큐에서도 호출해야 하므로 값 타입에 둔다.
    func match(_ vector: [Float]) -> MatchResult? {
        people.compactMap { $0.match(vector) }.max { $0.score < $1.score }
    }
}

struct MatchResult {
    /// 개별 샘플 중 최고 유사도.
    let bestSample: Float
    /// 그 사람 등록 얼굴 전체의 평균 방향과의 유사도.
    let centroid: Float
    /// 가장 잘 맞은 사람의 이름.
    let personName: String

    /// 둘 중 큰 값을 쓴다. centroid 는 안정적이지만 극단 포즈에서 떨어지고,
    /// 개별 최대값은 그 반대라 서로를 보완한다.
    var score: Float { max(bestSample, centroid) }

    func passes(threshold: Float) -> Bool { score >= threshold }
}

/// 등록된 얼굴 임베딩 저장소. 최대 [maxPeople]명.
///
/// 임베딩은 원본 사진으로 복원되지는 않지만 그대로도 생체 식별자다.
/// 평문으로 두지 않고 [EnclaveCrypto] 로 봉인해 Application Support 에 파일로 둔다.
@MainActor
final class FaceStore: ObservableObject {

    static let shared = FaceStore()

    static let maxPeople = 3

    @Published private(set) var roster: FaceRoster?
    /// 첫 복호화가 끝났는지. 끝나기 전의 `roster == nil` 은 "등록 없음" 이 아니라
    /// "아직 모름" 이다. 이걸 구분하지 않으면 시작 직후 잠깐 미등록으로 보인다.
    @Published private(set) var isLoaded = false

    var isEnrolled: Bool { roster.map { !$0.isEmpty } ?? false }
    var people: [EnrolledPerson] { roster?.people ?? [] }
    var canAddPerson: Bool { people.count < Self.maxPeople }

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

    /// 1인 시절(version 1)의 파일 형식. 읽기 전용 — 마이그레이션에만 쓴다.
    private struct LegacyProfile: Codable {
        var version: Int = 1
        var createdAt: Date = Date()
        var samples: [FaceSample] = []
        var centroid: [Float] = []
    }

    /// **메인 스레드에서 복호화하지 않는다.**
    ///
    /// 복호화는 Keychain 을 건드리고, Keychain 은 확인 창을 띄울 수 있다.
    /// 그 창이 메인에서 뜨면 앱이 통째로 멈춘다 — 메뉴바 아이콘조차 안 뜬다.
    /// 그래서 파일 읽기와 복호화는 백그라운드에서 하고 결과만 올린다.
    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            isLoaded = true
            return
        }
        let url = fileURL

        Task.detached(priority: .userInitiated) { [self] in
            var loaded: FaceRoster?
            var migrated = false
            do {
                let sealed = try Data(contentsOf: url)
                let plain = try EnclaveCrypto.open(sealed)
                if let roster = try? JSONDecoder().decode(FaceRoster.self, from: plain),
                   roster.version >= 2 {
                    loaded = roster
                } else {
                    // 1인 시절 파일. 첫 번째 사람으로 옮겨 담는다.
                    let legacy = try JSONDecoder().decode(LegacyProfile.self, from: plain)
                    loaded = FaceRoster(people: [EnrolledPerson(
                        name: T("사용자 1", "Person 1"),
                        createdAt: legacy.createdAt,
                        samples: legacy.samples,
                        centroid: legacy.centroid)])
                    migrated = true
                }
            } catch {
                // 암호화 키가 바뀐 경우(앱 재서명 등) 여기로 온다. 조용히 무시하지 말고 알린다.
                Log.face.error("등록 얼굴을 읽지 못했습니다: \(error.localizedDescription, privacy: .public)")
            }

            let result = loaded
            let needsPersist = migrated
            await MainActor.run {
                self.roster = result
                self.isLoaded = true
                if let result {
                    Log.face.info("등록 얼굴 로드됨 (\(result.people.count)명, 샘플 \(result.sampleCount)개)")
                }
                if needsPersist { try? self.persist() }
                AppState.shared.refreshStatus()
                // 잠금화면에서 앱이 시작된 경우, 잠김 처리가 이 로드보다 먼저
                // 끝나 걸러졌다. 준비가 됐으니 그 세션을 지금 시작한다.
                AppState.shared.resumeIfLocked()
            }
        }
    }

    private func persist() throws {
        guard let roster, !roster.people.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let plain = try JSONEncoder().encode(roster)
        let sealed = try EnclaveCrypto.seal(plain)
        try sealed.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: 등록

    /// 등록을 마친 사람을 추가한다.
    ///
    /// 등록 마법사는 9포즈를 다 모아 **완성된 사람**으로만 넘긴다. 포즈 하나마다
    /// 저장하던 예전 방식은 등록을 중간에 취소하면 반쪽짜리 등록이 남았다.
    func addPerson(name: String, samples: [FaceSample]) throws {
        var current = roster ?? FaceRoster()
        guard current.people.count < Self.maxPeople else {
            throw FaceStoreError.rosterFull
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let person = EnrolledPerson(
            name: trimmed.isEmpty
                ? T("사용자 \(current.people.count + 1)", "Person \(current.people.count + 1)")
                : trimmed,
            samples: samples,
            centroid: VectorMath.centroid(samples.map(\.vector)))
        current.people.append(person)
        roster = current
        try persist()
        Log.face.info("얼굴 등록됨: \(person.name, privacy: .public) (샘플 \(samples.count)개, 총 \(current.people.count)명)")
    }

    func deletePerson(id: UUID) {
        guard var current = roster else { return }
        current.people.removeAll { $0.id == id }
        roster = current.people.isEmpty ? nil : current
        try? persist()
        Log.face.info("등록 얼굴 1명 삭제됨 (남은 \(current.people.count)명)")
    }

    func deleteAll() {
        roster = nil
        try? FileManager.default.removeItem(at: fileURL)
        Log.face.info("등록 얼굴 전체 삭제됨")
    }

    // MARK: 매칭

    /// 카메라 큐로 넘겨 쓸 스냅샷. 인증 도중 등록 내용이 바뀌어도 세션은 흔들리지 않는다.
    func snapshot() -> FaceRoster? { roster }
}

enum FaceStoreError: LocalizedError {
    case rosterFull

    var errorDescription: String? {
        switch self {
        case .rosterFull:
            return T("최대 \(FaceStore.maxPeople)명까지 등록할 수 있습니다. 기존 등록을 지운 뒤 다시 시도해 주세요.",
                     "Up to \(FaceStore.maxPeople) people can be enrolled. Delete an existing person first.")
        }
    }
}
