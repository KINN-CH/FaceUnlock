import CoreGraphics
import Foundation
import QuartzCore
import Vision

/// 한 프레임에서 잰 머리 자세.
///
/// 방향 이름은 전부 **사용자 본인 기준**이다("왼쪽" = 사용자의 왼쪽).
/// 카메라가 주는 버퍼는 좌우 반전이 걸려 있지 않다 — 미리보기만 거울처럼
/// 뒤집어 보여준다(`CameraPreview`). 그래서 사용자가 자기 왼쪽으로 고개를 돌리면
/// 이미지에서는 코가 **오른쪽(x 증가)** 으로 간다.
///
/// 세 값 모두 얼굴 크기로 정규화하므로 사람·거리에 무관하다. 절대 각도가 아니라
/// 비율이지만, 필요한 건 "기준 자세에서 얼마나 벗어났나" 뿐이라 이걸로 충분하다.
struct HeadPose {
    /// 눈 사이 거리로 나눈 코의 좌우 치우침. + = 사용자의 왼쪽으로 돌림.
    /// 각도로는 대략 `0.32 · tan(θ)` (코 돌출 20mm / 눈 사이 63mm 기준).
    var yaw: CGFloat
    /// 입–눈 사이에서 코가 놓인 위치(0 = 입, 1 = 눈). 코는 앞으로 튀어나와 있어
    /// 턱을 들면 위로, 당기면 아래로 움직인다. + 방향 = 턱을 듦.
    var pitch: CGFloat
    /// 두 눈을 잇는 선의 기울기(라디안). + = 사용자의 오른쪽으로 기울임.
    var roll: CGFloat
    /// 눈 사이 거리 ÷ 프레임 너비. 카메라와의 거리 대용.
    var scale: CGFloat

    /// yaw·pitch 는 눈 선을 축으로 삼아 재기 때문에 고개를 기울여도 값이 흔들리지 않는다.
    init?(observation: VNFaceObservation, imageSize: CGSize) {
        guard imageSize.width > 0,
              let lm = FaceLandmarks5(observation: observation, imageSize: imageSize)
        else { return nil }

        // Vision 의 leftEye/rightEye 라는 이름에 기대지 않는다(어느 쪽 기준인지
        // 문서가 모호하다). 이미지 x 순서로 다시 정하면 규칙이 명확해진다.
        let (a, b) = lm.leftEye.x <= lm.rightEye.x
            ? (lm.leftEye, lm.rightEye)
            : (lm.rightEye, lm.leftEye)

        let interocular = hypot(b.x - a.x, b.y - a.y)
        guard interocular > 4 else { return nil }

        // 얼굴 좌표계: u = 눈 선 방향(이미지 오른쪽), v = 그 수직(이미지 위쪽).
        let ux = (b.x - a.x) / interocular
        let uy = (b.y - a.y) / interocular
        let vx = -uy
        let vy = ux

        let eyeMid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let mouthMid = CGPoint(x: (lm.leftMouth.x + lm.rightMouth.x) / 2,
                               y: (lm.leftMouth.y + lm.rightMouth.y) / 2)

        let span = (eyeMid.x - mouthMid.x) * vx + (eyeMid.y - mouthMid.y) * vy
        guard span > 4 else { return nil }

        yaw = ((lm.nose.x - eyeMid.x) * ux + (lm.nose.y - eyeMid.y) * uy) / interocular
        pitch = ((lm.nose.x - mouthMid.x) * vx + (lm.nose.y - mouthMid.y) * vy) / span
        roll = atan2(b.y - a.y, b.x - a.x)
        scale = interocular / imageSize.width
    }
}

/// 오토 촬영 판정기.
///
/// 사용자가 포즈마다 버튼을 누르는 대신, **고개를 그 방향으로 돌리면 알아서 찍는다.**
/// 순서를 강제하지 않고 남은 포즈 전부를 매 프레임 후보로 놓기 때문에,
/// 안내와 다른 방향을 먼저 해도 그 칸이 채워진다.
///
/// 정면(`.center`)은 예외로 먼저 찍어야 한다. 사람마다 코 위치·눈매가 달라
/// "정면일 때의 값"을 알기 전에는 나머지를 판정할 수 없기 때문이다.
/// 정면을 찍는 순간의 값이 그 사람의 기준선(`baseline`)이 되고,
/// 이후 모든 판정은 기준선으로부터의 **변화량**으로 한다.
///
/// 카메라 큐에서 프레임마다 호출된다 — 스레드 보호는 호출자 몫이다.
struct PoseAutoCapture {

    /// 같은 자세를 이만큼 유지해야 찍는다. 지나가는 중에 찍히지 않게.
    static let holdSeconds: CFTimeInterval = 0.6
    /// 한 장 찍은 뒤의 휴식. 한 동작이 두 칸을 채우지 않게.
    static let cooldownSeconds: CFTimeInterval = 1.0

    // 기준선에서 이만큼 벗어나면 그 포즈로 본다. 3D 얼굴 모형에 회전을 걸어
    // 확인한 값으로, 각각 고개 22° / 턱 18° / 기울임 10° 에 해당한다.
    // "살짝 돌리세요" 로 사람이 실제로 하는 정도다. 더 올리면 안 찍힌다고 느끼고,
    // 더 내리면 정면을 잡고 있는 동안 옆 칸이 먼저 차버린다.
    private static let yawDelta: CGFloat = 0.115
    private static let pitchDelta: CGFloat = 0.075
    private static let rollDelta: CGFloat = 10 * .pi / 180
    private static let closerRatio: CGFloat = 1.16
    private static let fartherRatio: CGFloat = 0.87

    // 정면 판정. 기준선이 없는 유일한 순간이라 절대값으로 볼 수밖에 없다.
    // 넉넉하게 잡는다 — 여기서 조금 비뚤어도 그 값이 그대로 기준선이 되어
    // 이후 판정은 전부 상대값이라 상쇄되고, 반대로 빡빡하게 잡으면
    // 얼굴이 살짝 비대칭인 사람은 첫 장부터 영영 안 찍힌다.
    private static let neutralYaw: CGFloat = 0.12
    private static let neutralRoll: CGFloat = 9 * .pi / 180
    /// 랜드마크가 엉킨 프레임만 걸러내는 안전장치. 사람마다 코 위치가 달라
    /// 이 값으로 자세를 판정할 수는 없다.
    private static let neutralPitchRange: ClosedRange<CGFloat> = 0.05...0.95

    enum Step {
        /// 지금은 어떤 포즈에도 해당하지 않는다.
        case idle
        /// 자세를 잡고 있는 중 (0…1 진행도).
        case holding(FacePose, Double)
        /// 지금 찍어야 한다.
        case fire(FacePose)
    }

    private(set) var baseline: HeadPose?

    private var remaining: [FacePose] = FacePose.allCases
    private var previous: HeadPose?
    private var holding: FacePose?
    private var holdSince: CFTimeInterval = 0
    private var readyAt: CFTimeInterval = 0

    /// 컨트롤러가 저장을 마칠 때마다 남은 목록을 다시 알려준다.
    mutating func setRemaining(_ poses: [FacePose]) {
        remaining = poses
        if let holding, !poses.contains(holding) { self.holding = nil }
    }

    /// 얼굴이 사라졌거나 품질이 떨어졌을 때. 잡고 있던 시간을 버린다.
    mutating func interrupt() {
        holding = nil
        previous = nil
    }

    mutating func update(_ pose: HeadPose, at now: CFTimeInterval) -> Step {
        let wasSteady = isSteady(pose)
        previous = pose

        guard now >= readyAt else { return .idle }

        guard let candidate = classify(pose) else {
            holding = nil
            return .idle
        }

        // 움직이는 중에는 시간이 쌓이지 않는다. 흔들린 프레임으로 등록하면
        // 그 뒤로 계속 오인식이 난다.
        if holding != candidate || !wasSteady {
            holding = candidate
            holdSince = now
        }

        let held = now - holdSince
        if held >= Self.holdSeconds { return .fire(candidate) }
        return .holding(candidate, min(1, held / Self.holdSeconds))
    }

    /// 실제로 한 장 저장했을 때 호출한다(오토·수동 공통).
    mutating func didCapture(_ pose: FacePose, at headPose: HeadPose, time now: CFTimeInterval) {
        if pose == .center { baseline = headPose }
        remaining.removeAll { $0 == pose }
        holding = nil
        readyAt = now + Self.cooldownSeconds
    }

    // MARK: 판정

    /// 지금 자세가 남은 포즈 중 어디에 해당하는지. 여러 개가 걸리면
    /// **가장 확실한 것**(문턱을 가장 크게 넘은 것)을 고른다 —
    /// 고개를 돌리면 눈 사이 거리도 줄어 `farther` 에 살짝 걸리는 식의
    /// 겹침이 있는데, 그때 의도한 쪽이 이긴다.
    private func classify(_ pose: HeadPose) -> FacePose? {
        guard let baseline else {
            return remaining.contains(.center) && isNeutral(pose) ? .center : nil
        }
        var best: (FacePose, CGFloat)?
        for candidate in remaining {
            guard let margin = margin(candidate, pose, baseline), margin >= 1 else { continue }
            if best == nil || margin > best!.1 { best = (candidate, margin) }
        }
        return best?.0
    }

    /// 문턱 대비 몇 배나 벗어났는지. 1 미만이면 해당 포즈가 아니다.
    private func margin(_ target: FacePose, _ p: HeadPose, _ base: HeadPose) -> CGFloat? {
        let dYaw = p.yaw - base.yaw
        let dPitch = p.pitch - base.pitch
        let dRoll = p.roll - base.roll
        let ratio = base.scale > 0 ? p.scale / base.scale : 1

        switch target {
        case .center:
            return nil          // 기준선이 이미 있으면 정면은 다 찍은 것이다.
        case .left:      return dYaw / Self.yawDelta
        case .right:     return -dYaw / Self.yawDelta
        case .up:        return dPitch / Self.pitchDelta
        case .down:      return -dPitch / Self.pitchDelta
        case .tiltRight: return dRoll / Self.rollDelta
        case .tiltLeft:  return -dRoll / Self.rollDelta
        case .closer, .farther:
            // 거리는 고개를 정면 가까이 두고 있을 때만 본다.
            guard abs(dYaw) < Self.yawDelta, abs(dPitch) < Self.pitchDelta else { return nil }
            return target == .closer
                ? (ratio - 1) / (Self.closerRatio - 1)
                : (1 - ratio) / (1 - Self.fartherRatio)
        }
    }

    private func isNeutral(_ p: HeadPose) -> Bool {
        abs(p.yaw) <= Self.neutralYaw
            && abs(p.roll) <= Self.neutralRoll
            && Self.neutralPitchRange.contains(p.pitch)
    }

    /// 직전 프레임과 견줘 거의 멈춰 있는가.
    private func isSteady(_ p: HeadPose) -> Bool {
        guard let previous else { return false }
        return abs(p.yaw - previous.yaw) < 0.03
            && abs(p.pitch - previous.pitch) < 0.03
            && abs(p.roll - previous.roll) < 0.05
            && abs(p.scale - previous.scale) < previous.scale * 0.05
    }
}
