import Accelerate
import Foundation

enum VectorMath {

    static func l2Normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = norm.squareRoot()
        guard norm > .ulpOfOne else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var divisor = norm
        vDSP_vsdiv(v, 1, &divisor, &out, 1, vDSP_Length(v.count))
        return out
    }

    /// 두 벡터가 모두 L2 정규화되어 있다면 내적이 곧 코사인 유사도다.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }

    /// 여러 임베딩의 평균을 다시 L2 정규화한 것. 등록된 얼굴들의 "중심".
    static func centroid(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first, !first.isEmpty else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == first.count {
            vDSP_vadd(sum, 1, v, 1, &sum, 1, vDSP_Length(first.count))
        }
        return l2Normalized(sum)
    }
}
