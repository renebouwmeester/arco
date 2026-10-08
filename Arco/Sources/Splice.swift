// The splice on resuming (0.3.2, 8 Oct 2026 — René: "Arco heeft een klein hikje na play/pause"). The Music app doesn't
// resume exactly where its sound stopped, and it swells in; the hiccup came a few seconds after play, when Roon reached
// that point in the run. The same day AudioPi (Spotify into Roon) learned the cure: on resuming, send the player a
// little back, find the end of the run again in the new sound, and go on from the sample after it. Not sample for
// sample — the new sound isn't bit-identical — but by correlation: mono, first one in eight, then to the sample; of
// equal candidates the last (the sound after the jump back, not the bit played before it).
import Foundation

enum Splice {
    /// Frames of the run's end that are looked for (~45 ms at 96 kHz).
    static let tailFrames = 4096

    /// 24-bit little-endian stereo → Int32 samples (signed).
    static func int24(_ d: Data) -> [Int32] {
        var out = [Int32](repeating: 0, count: d.count / 3)
        d.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            for i in 0..<out.count {
                let v = Int32(b[i * 3]) | Int32(b[i * 3 + 1]) << 8 | Int32(b[i * 3 + 2]) << 16
                out[i] = (v << 8) >> 8
            }
        }
        return out
    }

    /// Where `tail` (stereo samples) fits best in `new`: the frame right after it, and how well (0–1).
    static func find(tail: [Int32], in new: [Int32]) -> (frame: Int, score: Double)? {
        func mono(_ s: [Int32], _ step: Int) -> [Double] {
            let n = s.count / 2 / step
            var out = [Double](repeating: 0, count: n)
            for i in 0..<n { var t = 0.0; for j in 0..<step { t += Double(s[(i * step + j) * 2]) + Double(s[(i * step + j) * 2 + 1]) }; out[i] = t }
            return out
        }
        func ncc(_ a: [Double], _ b: [Double], _ k: Int) -> Double {
            var ab = 0.0, aa = 0.0, bb = 0.0
            for i in 0..<b.count { let x = a[k + i], y = b[i]; ab += x * y; aa += x * x; bb += y * y }
            return aa > 0 && bb > 0 ? ab / (aa * bb).squareRoot() : 0
        }
        let a8 = mono(new, 8), b8 = mono(tail, 8)
        guard !b8.isEmpty, a8.count >= b8.count else { return nil }
        let coarse = (0...(a8.count - b8.count)).map { ncc(a8, b8, $0) }
        let top = coarse.max() ?? 0
        let k8 = coarse.lastIndex { $0 >= top - 0.01 } ?? 0
        let a1 = mono(new, 1), b1 = mono(tail, 1)
        var best = -1.0, at = k8 * 8
        for k in max(0, k8 * 8 - 16)...min(a1.count - b1.count, k8 * 8 + 16) {
            let v = ncc(a1, b1, k); if v > best { best = v; at = k }
        }
        return (at + b1.count, best)
    }
}
