import Accelerate
import Foundation

/// A compact description of a voice: the average shape of its spectrum (MFCCs) and how much it varies.
/// The call audio of each participant also passes through their own microphone and connection, which makes
/// people on a call easier to tell apart than people in one room.
public enum VoicePrint {
    static let rate = 16_000.0
    static let frameLength = 400   // 25 ms
    static let hop = 160           // 10 ms
    static let fftLength = 512
    static let melBands = 26
    static let coefficients = 13

    /// Typical values of each dimension in call audio (measured on recorded meetings), used when a meeting has
    /// too few passages to judge its own spread.
    public static let typicalMean: [Float] = [37.51, -0.5, 9.23, -1.08, -0.02, -3.64, -2.85, -1.19, -1.65, 0.55, 0.19, -0.41, 22.54, 14.24, 11.64, 9.1, 6.82, 7.07, 5.86, 5.26, 5.17, 4.72, 4.25, 3.92]
    public static let typicalDeviation: [Float] = [10.69, 5.93, 5.41, 4.62, 2.65, 3.0, 2.93, 2.65, 2.36, 2.64, 1.9, 2.0, 6.29, 2.56, 2.23, 2.03, 1.24, 1.1, 0.98, 0.88, 0.89, 0.85, 0.75, 0.81]

    /// Nil when there is too little speech (under about a second) to describe the voice.
    public static func embedding(_ samples: ArraySlice<Float>) -> [Float]? {
        let x = Array(samples)
        guard x.count >= frameLength * 2 else { return nil }
        var frames: [(energy: Float, mfcc: [Float])] = []
        var start = 0
        while start + frameLength <= x.count {
            let frame = Array(x[start..<start + frameLength])
            frames.append(analyse(frame))
            start += hop
        }
        // Keep the louder 60% of frames: speech, not the pauses between words.
        let sorted = frames.map(\.energy).sorted()
        let floor = sorted[Int(Double(sorted.count) * 0.4)]
        let voiced = frames.filter { $0.energy >= floor && $0.energy > 1e-7 }.map(\.mfcc)
        guard voiced.count >= 60 else { return nil }
        let n = Float(voiced.count)
        var mean = [Float](repeating: 0, count: coefficients - 1)
        var deviation = mean
        for v in voiced { for i in mean.indices { mean[i] += v[i] / n } }
        for v in voiced { for i in mean.indices { deviation[i] += (v[i] - mean[i]) * (v[i] - mean[i]) / n } }
        return mean + deviation.map { sqrt($0) }
    }

    private static let window: [Float] = vDSP.window(ofType: Float.self, usingSequence: .hamming, count: frameLength,
                                                     isHalfWindow: false)
    private static let dft = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftLength), .FORWARD)
    private static let filters: [[Float]] = {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let bins = fftLength / 2
        let points = (0...melBands + 1).map { hz(mel(80) + (mel(7600) - mel(80)) * Double($0) / Double(melBands + 1)) }
            .map { $0 / rate * Double(fftLength) }
        return (0..<melBands).map { b in
            (0..<bins).map { k in
                let k = Double(k)
                if k < points[b] || k > points[b + 2] { return 0 }
                return Float(k <= points[b + 1] ? (k - points[b]) / (points[b + 1] - points[b])
                                                : (points[b + 2] - k) / (points[b + 2] - points[b + 1]))
            }
        }
    }()

    private static func analyse(_ frame: [Float]) -> (Float, [Float]) {
        var x = vDSP.multiply(frame, window)
        x += [Float](repeating: 0, count: fftLength - frameLength)
        let half = fftLength / 2
        var evens = [Float](repeating: 0, count: half), odds = evens
        for i in 0..<half { evens[i] = x[2 * i]; odds[i] = x[2 * i + 1] }
        var re = [Float](repeating: 0, count: half), im = re
        vDSP_DFT_Execute(dft!, evens, odds, &re, &im)
        var power = [Float](repeating: 0, count: half)
        for k in 1..<half { power[k] = re[k] * re[k] + im[k] * im[k] }
        let energy = vDSP.sum(power)
        let logMel = filters.map { log(max(vDSP.dot($0, power), 1e-10)) }
        // DCT-II; the first coefficient (loudness) is dropped.
        let m = Float(melBands)
        let mfcc = (1..<coefficients).map { c in
            logMel.enumerated().reduce(Float(0)) { $0 + $1.element * cos(.pi * Float(c) * (Float($1.offset) + 0.5) / m) }
        }
        return (energy, mfcc)
    }
}

/// Tells the voices in the call audio apart: groups passages by voice into "Speaker 1", "Speaker 2"…
public enum Diarizer {
    /// Cosine distance (on standardized voice prints) above which two groups are different people.
    public static var threshold: Float = 1.1

    /// One group index per voice print, numbered by first appearance; nil prints (too short to tell) get the
    /// group of the nearest earlier passage that has one. `maxSpeakers` caps the groups (e.g. the call's roster).
    public static func cluster(_ prints: [[Float]?], weights: [Double]? = nil, maxSpeakers: Int? = nil) -> [Int] {
        let known = prints.indices.filter { prints[$0] != nil }
        guard let dims = known.first.map({ prints[$0]!.count }), known.count > 1 else {
            return prints.map { _ in 0 }
        }
        // Standardize each dimension over the meeting so all of them count. With few passages the meeting's own
        // spread says little (two passages of one voice would look like opposites), so typical values weigh in.
        var mean = [Float](repeating: 0, count: dims), sd = mean
        for i in known { for d in 0..<dims { mean[d] += prints[i]![d] / Float(known.count) } }
        for i in known { for d in 0..<dims { sd[d] += pow(prints[i]![d] - mean[d], 2) / Float(known.count) } }
        if dims == VoicePrint.typicalMean.count {
            let n = Float(known.count), k: Float = 8
            for d in 0..<dims {
                mean[d] = (n * mean[d] + k * VoicePrint.typicalMean[d]) / (n + k)
                sd[d] = (n * sd[d] + k * pow(VoicePrint.typicalDeviation[d], 2)) / (n + k)
            }
        }
        let z = known.map { i in (0..<dims).map { (prints[i]![$0] - mean[$0]) / max(sqrt(sd[$0]), 1e-6) } }
        let w = known.map { weights?[$0] ?? 1 }

        // Average-linkage agglomerative clustering: the distance between two groups is the weighted mean distance
        // between their passages.
        func distance(_ a: [Float], _ b: [Float]) -> Float {
            1 - vDSP.dot(a, b) / max(sqrt(vDSP.sumOfSquares(a) * vDSP.sumOfSquares(b)), 1e-9)
        }
        let pair = z.map { a in z.map { distance(a, $0) } }
        var groups: [[Int]] = z.indices.map { [$0] }
        func linkage(_ a: [Int], _ b: [Int]) -> Float {
            var sum = 0.0, total = 0.0
            for i in a { for j in b { sum += Double(pair[i][j]) * w[i] * w[j]; total += w[i] * w[j] } }
            return Float(sum / total)
        }
        var link = groups.map { a in groups.map { linkage(a, $0) } }
        while groups.count > 1 {
            var best = (Float.greatestFiniteMagnitude, 0, 0)
            for a in 0..<groups.count {
                for b in a + 1..<groups.count where link[a][b] < best.0 { best = (link[a][b], a, b) }
            }
            let tooMany = maxSpeakers.map { groups.count > $0 } ?? false
            guard best.0 < threshold || tooMany else { break }
            groups[best.1] += groups[best.2]
            groups.remove(at: best.2)
            link.remove(at: best.2)
            for i in link.indices { link[i].remove(at: best.2) }
            for i in groups.indices { let d = linkage(groups[best.1], groups[i]); link[best.1][i] = d; link[i][best.1] = d }
        }
        // A group heard for only a moment is more likely a stray passage than a person: fold it into the nearest.
        let totalWeight = w.reduce(0, +)
        while groups.count > 1, let small = groups.indices.min(by: { groups[$0].reduce(0) { $0 + w[$1] } < groups[$1].reduce(0) { $0 + w[$1] } }),
              groups[small].reduce(0.0, { $0 + w[$1] }) < totalWeight * 0.03 {
            let target = groups.indices.filter { $0 != small }.min { linkage(groups[$0], groups[small]) < linkage(groups[$1], groups[small]) }!
            groups[target] += groups[small]
            groups.remove(at: small)
        }
        var label = [Int?](repeating: nil, count: prints.count)
        for (g, members) in groups.enumerated() { for m in members { label[known[m]] = g } }
        // Short passages inherit the previous labelled passage (people rarely switch for a single word).
        var last = label.compactMap { $0 }.first ?? 0
        for i in label.indices {
            if let l = label[i] { last = l } else { label[i] = last }
        }
        // Number groups by first appearance.
        var order: [Int: Int] = [:]
        return label.map { l in
            if order[l!] == nil { order[l!] = order.count }
            return order[l!]!
        }
    }
}
