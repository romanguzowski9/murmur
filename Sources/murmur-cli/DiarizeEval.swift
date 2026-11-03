import AVFoundation
import Foundation
import MurmurCore

/// murmur-cli diarize-eval <audio.wav> <refined.ndjson> <exclude speaker id>
/// Scores Murmur's speaker grouping against another tool's speaker labels for the same audio
/// (e.g. a Wispr Flow meeting: its call-audio channel and its refined transcript).
enum DiarizeEval {
    static func run(_ args: [String]) -> Int32 {
        guard args.count >= 3, let file = try? AVAudioFile(forReading: URL(fileURLWithPath: args[0])),
              let lines = try? String(contentsOfFile: args[1], encoding: .utf8) else {
            print("usage: murmur-cli diarize-eval <audio.wav (16 kHz mono)> <refined.ndjson> <exclude speaker id>")
            return 2
        }
        let exclude = Int(args[2]) ?? -1
        // "--only 3": keep one true speaker (checks that one voice stays one group).
        let only = args.firstIndex(of: "--only").flatMap { Int(args[$0 + 1]) }
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try? file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let rate = file.processingFormat.sampleRate

        var rows: [(start: Double, speaker: Int)] = []
        for line in lines.split(separator: "\n") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ts = d["timestamp"] as? String, let sp = (d["speaker"] as? [String: Any])?["id"] as? Int else { continue }
            let parts = ts.split(separator: ":").compactMap { Double($0) }
            rows.append((parts.reduce(0) { $0 * 60 + $1 }, sp))
        }
        var segments: [(start: Double, end: Double, truth: Int)] = []
        for (i, r) in rows.enumerated() where r.speaker != exclude && (only == nil || r.speaker == only) {
            let end = min(i + 1 < rows.count ? rows[i + 1].start : r.start + 10, r.start + 30)
            if end > r.start { segments.append((r.start, end, r.speaker)) }
        }
        let started = Date()
        let prints: [[Float]?] = segments.map { s in
            let a = min(samples.count, Int(s.start * rate)), b = min(samples.count, Int(s.end * rate))
            return VoicePrint.embedding(samples[a..<b])
        }
        print(String(format: "%d passages, %d with a voice print, %.1f s", segments.count, prints.compactMap { $0 }.count,
                     Date().timeIntervalSince(started)))
        let weights = segments.map { $0.end - $0.start }
        if args.contains("--stats") {
            let known = prints.compactMap { $0 }
            let dims = known[0].count
            let mean = (0..<dims).map { d in known.reduce(Float(0)) { $0 + $1[d] } / Float(known.count) }
            let sd = (0..<dims).map { d in sqrt(known.reduce(Float(0)) { $0 + pow($1[d] - mean[d], 2) } / Float(known.count)) }
            Swift.print("STATS mean", mean.map { String(format: "%.3f", $0) }.joined(separator: ","))
            Swift.print("STATS sd", sd.map { String(format: "%.3f", $0) }.joined(separator: ","))
        }
        let truths = Set(segments.map(\.truth)).count
        for t in stride(from: Float(0.6), through: 1.25, by: 0.05) {
            Diarizer.threshold = t
            let labels = Diarizer.cluster(prints, weights: weights)
            print(String(format: "threshold %.1f: %@", t, score(labels, segments.map(\.truth), weights, truths)))
        }
        Diarizer.threshold = 1.1
        let capped = Diarizer.cluster(prints, weights: weights, maxSpeakers: truths)
        print("capped at \(truths) speakers: " + score(capped, segments.map(\.truth), weights, truths))
        return 0
    }

    /// Share of speech whose group's majority speaker is its true speaker, and the number of groups.
    static func score(_ labels: [Int], _ truth: [Int], _ weights: [Double], _ truths: Int) -> String {
        var table: [Int: [Int: Double]] = [:]
        for i in labels.indices { table[labels[i], default: [:]][truth[i], default: 0] += weights[i] }
        let correct = table.values.reduce(0.0) { $0 + ($1.values.max() ?? 0) }
        // Coverage: share of each true speaker's speech in their own biggest group (penalizes over-splitting).
        var byTruth: [Int: [Int: Double]] = [:]
        for i in labels.indices { byTruth[truth[i], default: [:]][labels[i], default: 0] += weights[i] }
        let covered = byTruth.values.reduce(0.0) { $0 + ($1.values.max() ?? 0) }
        let total = weights.reduce(0, +)
        return String(format: "%d groups (true %d), purity %.0f%%, coverage %.0f%%", table.count, truths,
                      correct / total * 100, covered / total * 100)
    }
}
