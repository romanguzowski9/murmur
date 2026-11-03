import Foundation

/// Trims long pauses out of the audio sent to the recognizer. Apple's recognizer treats a pause of about 1.5 s as the
/// end of an utterance and silently restarts its transcript, dropping everything said before it. Keeping only a short
/// gap (enough for punctuation) makes a held-key dictation look like one continuous utterance.
public final class SilenceGate {
    /// Silence kept after speech before the rest of a pause is dropped.
    public let keepSilence: Double
    /// Called (on the audio thread) once a pause reaches `sentencePause` seconds: the speaker ended a sentence.
    public var onLongPause: (() -> Void)?
    public var sentencePause = 1.2
    private var silentRun = 0.0
    private var noiseFloor: Float = 0.002

    public init(keepSilence: Double = 0.4) {
        self.keepSilence = keepSilence
    }

    /// Whether audio with this RMS level and duration should reach the recognizer.
    public func shouldPass(rms: Float, duration: Double) -> Bool {
        // Track the background noise: fall quickly, rise slowly, so speech doesn't raise the floor.
        if rms < noiseFloor {
            noiseFloor = max(rms, 0.0001)
        } else {
            noiseFloor += (rms - noiseFloor) * 0.005
        }
        if rms > max(0.003, noiseFloor * 3) {
            silentRun = 0
            return true
        }
        let before = silentRun
        silentRun += duration
        if before < sentencePause, silentRun >= sentencePause { onLongPause?() }
        return silentRun <= keepSilence
    }

    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
}

/// Safety net for recognizer restarts that still happen: keeps every utterance instead of only the latest one.
/// A restart shows up as the running text suddenly shrinking to a fresh start (revisions never halve it).
public struct TranscriptAccumulator {
    public private(set) var committed: [String] = []
    public private(set) var current = ""
    /// Word positions where the speaker paused long enough to end a sentence.
    private var sentenceEnds = Set<Int>()

    public init() {}

    /// The speaker paused: whatever has been said so far ends a sentence.
    public mutating func markSentenceEnd() {
        markSentenceEnd(afterWord: text.wordCount)
    }

    /// A sentence ends after the first `count` words (known from word timings).
    public mutating func markSentenceEnd(afterWord count: Int) {
        if count > 0 { sentenceEnds.insert(count) }
    }

    public mutating func update(_ text: String) {
        let new = text.trimmed
        guard !new.isEmpty else { return }
        let oldCount = current.wordCount
        let newCount = new.wordCount
        if oldCount > 0, newCount < oldCount, newCount <= max(2, oldCount / 2) {
            committed.append(current)
        }
        current = new
    }

    /// The whole dictation; utterances cut by a restart or a long pause end with a period.
    public var text: String {
        let parts = committed.map { part -> String in
            guard let last = part.last, !".!?,;:…".contains(last) else { return part }
            return part + "."
        } + [current]
        let joined = parts.filter { !$0.isEmpty }.joined(separator: " ")
        guard !sentenceEnds.isEmpty else { return joined }
        var words = joined.split(separator: " ").map(String.init)
        for end in sentenceEnds where end > 0 && end < words.count {
            if let last = words[end - 1].last, !".!?,;:…".contains(last) { words[end - 1] += "." }
            if words[end - 1].hasSuffix(".") || words[end - 1].hasSuffix("!") || words[end - 1].hasSuffix("?") {
                words[end] = words[end].prefix(1).uppercased() + words[end].dropFirst()
            }
        }
        return words.joined(separator: " ")
    }
}
