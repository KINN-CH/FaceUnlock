import CoreGraphics
import Foundation
import Vision

/// 눈 깜빡임 챌린지.
///
/// 인쇄 사진이나 정지 이미지는 EAR(눈 종횡비)이 전혀 변하지 않으므로 걸러진다.
///
/// **한계를 분명히 해둔다**: 재생 영상(휴대폰으로 본인 영상 재생)은 이걸로 막지 못한다.
/// 그건 깊이 센서나 별도 안티스푸핑 모델이 있어야 하는 영역이고, 이 앱에는 없다.
/// README 경고에 그대로 적는다.
final class BlinkDetector {

    struct Config {
        /// 기준선 대비 이 비율 아래로 떨어지면 "감김".
        var closedRatio: Float = 0.62
        /// 기준선 대비 이 비율 위로 올라오면 "열림".
        var openRatio: Float = 0.80
        /// 하한은 검출 잡음(랜드마크가 한 프레임 튀는 것)을 거른다.
        var minClosedDuration: CFTimeInterval = 0.06
        /// 상한은 **사실상 없다시피** 둔다.
        ///
        /// "깜빡이세요" 라는 지시를 받으면 사람은 무의식적인 깜빡임(~150ms)이
        /// 아니라 의식적으로 꾹 감았다 뜨는 동작을 한다. 같은 사용자에게서
        /// 1256ms, 2418ms 가 실측됐고 1.6초 상한이 2418ms 를 거부해서
        /// "아무리 깜빡여도 안 열린다" 가 됐다.
        ///
        /// 상한을 조여봐야 얻는 게 없다. 정지 사진은 EAR 전이 자체가 없어서
        /// 애초에 이 단계에 오지 못하고, 영상 재생은 어차피 못 막는다(README 명시).
        /// 즉 상한은 스푸핑이 아니라 **본인만** 거부한다. 남겨둔 5초는
        /// "졸아서 눈을 감고 있다" 와 깜빡임을 가르는 정도의 의미만 있다.
        var maxClosedDuration: CFTimeInterval = 5.0
        /// 기준선을 세우기 전에 필요한 최소 프레임 수.
        var minBaselineSamples = 4
        /// 눈이 아예 감긴 상태로 시작한 경우를 걸러내기 위한 절대 하한.
        var minPlausibleBaseline: Float = 0.12
        /// 눈이 떠 있는 동안 기준선이 현재 EAR 쪽으로 끌려가는 비율(프레임당).
        /// 튄 값을 몇 초 안에 잊을 만큼은 빠르고, 한 번의 감김에 휩쓸리지는
        /// 않을 만큼은 느려야 한다.
        var baselineDecay: Float = 0.05
    }

    enum Event {
        /// 기준선을 세우는 중 — 아직 판정할 수 없다.
        case calibrating
        /// 관찰 중 (눈 뜬 상태).
        case watching
        /// 눈이 감긴 상태.
        case eyesClosed
        /// 깜빡임 1회 완료.
        case blinked
    }

    private enum State {
        case open
        case closed(since: CFTimeInterval)
    }

    private let config: Config
    private var baselineDecay: Float { config.baselineDecay }
    private var state: State = .open
    private var baseline: Float = 0
    private var sampleCount = 0

    private(set) var lastEAR: Float = 0

    init(config: Config = Config()) {
        self.config = config
    }

    func reset() {
        state = .open
        baseline = 0
        sampleCount = 0
        lastEAR = 0
    }

    // MARK: 판정

    func process(_ observation: VNFaceObservation, at time: CFTimeInterval) -> Event {
        guard let ear = Self.eyeAspectRatio(observation) else { return .calibrating }
        lastEAR = ear

        // 기준선은 "이 사람의 뜬 눈" 크기다. 사람마다 눈 모양이 달라서
        // 절대 임계값(0.25 등)을 그대로 쓰면 눈이 가는 사람은 항상 감긴 것으로 판정된다.
        //
        // 위로만 자라는 최대값을 쓰면 안 된다. 랜드마크가 한 프레임 튀거나 사용자가
        // 잠깐 눈을 크게 떴을 때 기준선이 **그 값에 영구히 박히고**, 그 뒤로는
        // 평상시 뜬 눈이 openRatio(0.80)를 못 넘겨서 "눈을 다시 떴다" 를 늦게
        // 알아채거나 아예 못 알아챈다. 감긴 시간이 2초대로 부풀거나, 깜빡임을
        // 통째로 놓치는 증상이 여기서 나온다.
        //
        // 그래서 눈이 떠 있다고 본 동안에만 기준선을 천천히 끌어내린다.
        // 감긴 동안(state == .closed) 내리면 기준선이 감긴 눈을 따라가서
        // 감김 자체를 못 알아채므로 그때는 건드리지 않는다.
        sampleCount += 1
        if ear > baseline {
            baseline = ear
        } else if case .open = state {
            baseline += (ear - baseline) * baselineDecay
        }

        guard sampleCount >= config.minBaselineSamples,
              baseline >= config.minPlausibleBaseline else {
            return .calibrating
        }

        switch state {
        case .open:
            if ear < baseline * config.closedRatio {
                state = .closed(since: time)
                return .eyesClosed
            }
            return .watching

        case .closed(let since):
            let duration = time - since
            if ear > baseline * config.openRatio {
                state = .open
                if duration >= config.minClosedDuration && duration <= config.maxClosedDuration {
                    Log.face.info("깜빡임 감지 (감긴 시간 \(Int(duration * 1000))ms)")
                    return .blinked
                }
                // 너무 짧으면 잡음, 너무 길면 그냥 눈 감고 있던 것 — 다시 관찰한다.
                let why = duration < config.minClosedDuration ? "너무 짧음" : "너무 긺"
                Log.face.info("깜빡임 무시 (감긴 시간 \(Int(duration * 1000))ms, \(why, privacy: .public))")
                return .watching
            }
            if duration > config.maxClosedDuration {
                return .eyesClosed   // 계속 감고 있음
            }
            return .eyesClosed
        }
    }

    // MARK: EAR

    /// 눈 영역의 종횡비. 좌우 눈 평균.
    ///
    /// 고전적인 6점 EAR 공식 대신 **눈꼬리 축 기준의 폭/높이 비**를 쓴다.
    /// Vision 이 주는 눈 점의 개수와 순서가 리비전마다 다르고, 고개를 기울이면
    /// 축 정렬 EAR 이 무너지기 때문이다. 이 방식은 회전에 불변이다.
    static func eyeAspectRatio(_ observation: VNFaceObservation) -> Float? {
        guard let landmarks = observation.landmarks else { return nil }
        let ratios = [landmarks.leftEye, landmarks.rightEye].compactMap { region -> Float? in
            guard let region else { return nil }
            return ratio(of: region.normalizedPoints)
        }
        guard !ratios.isEmpty else { return nil }
        return ratios.reduce(0, +) / Float(ratios.count)
    }

    private static func ratio(of points: [CGPoint]) -> Float? {
        guard points.count >= 4 else { return nil }

        // 눈꼬리 = x 축이 아니라 점들 중 가장 멀리 떨어진 두 점.
        var corner0 = points[0], corner1 = points[1]
        var longest: CGFloat = -1
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let d = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
                if d > longest {
                    longest = d
                    corner0 = points[i]
                    corner1 = points[j]
                }
            }
        }
        guard longest > 1e-6 else { return nil }

        let axis = CGPoint(x: (corner1.x - corner0.x) / longest,
                           y: (corner1.y - corner0.y) / longest)
        let normal = CGPoint(x: -axis.y, y: axis.x)

        var minN: CGFloat = .greatestFiniteMagnitude
        var maxN: CGFloat = -.greatestFiniteMagnitude
        for p in points {
            let n = (p.x - corner0.x) * normal.x + (p.y - corner0.y) * normal.y
            minN = min(minN, n)
            maxN = max(maxN, n)
        }
        return Float((maxN - minN) / longest)
    }
}
