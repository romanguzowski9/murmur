import Foundation

/// Puts names on the voices told apart in a meeting ("Speaker 1" → "Maria"), the way Wispr Flow does: from what
/// the call app showed (its active-speaker marker), from the AI reading the conversation, and from the user.
public enum SpeakerNames {
    /// "Maria Nowak (Acme PL)" and "maria nowak" are the same person.
    public static func isSame(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            s.replacingOccurrences(of: "\\(.*\\)", with: "", options: .regularExpression)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmed
        }
        return !key(a).isEmpty && key(a) == key(b)
    }

    /// Votes, for each speaker label, for the name the call app marked as speaking while that speaker talked.
    /// A label gets a name when it won at least two observations and 60% of them, and no other label won it.
    public static func fromObservations(segments: [TranscriptSegment], observations: [SpeakingObservation],
                                        me: String) -> [String: String] {
        let useful = observations.filter { $0.names.count == 1 && !isSame($0.names[0], me) }
        guard !useful.isEmpty else { return [:] }
        var votes: [String: [String: Int]] = [:]
        for (i, s) in segments.enumerated() where s.speaker == .others {
            guard let label = s.label else { continue }
            let end = s.start + (s.duration ?? min(Double(s.text.wordCount) * 0.4, 30))
            let nextStart = segments[(i + 1)...].first?.start ?? .greatestFiniteMagnitude
            for o in useful where o.time >= s.start && o.time <= min(end, nextStart) {
                votes[label, default: [:]][o.names[0], default: 0] += 1
            }
        }
        var names: [String: String] = [:]
        var taken: Set<String> = []
        // Most certain labels first.
        let ranked = votes.compactMap { label, v -> (String, String, Int, Double)? in
            guard let (name, n) = v.max(by: { $0.value < $1.value }) else { return nil }
            return (label, name, n, Double(n) / Double(v.values.reduce(0, +)))
        }.sorted { $0.2 > $1.2 }
        for (label, name, n, share) in ranked where n >= 2 && share >= 0.6 && !taken.contains(name) {
            names[label] = name
            taken.insert(name)
        }
        return names
    }

    /// Splits a "Speaker names: Speaker 1 = Maria; Speaker 2 = Ilya" line off an AI summary.
    public static func extract(_ summary: String) -> (names: [String: String], summary: String) {
        var names: [String: String] = [:]
        var kept: [String] = []
        for line in summary.components(separatedBy: "\n") {
            let plain = line.replacingOccurrences(of: "*", with: "").trimmed
            guard plain.lowercased().hasPrefix("speaker names:") else { kept.append(line); continue }
            for pair in plain.dropFirst("speaker names:".count).components(separatedBy: CharacterSet(charactersIn: ";,")) {
                let parts = pair.components(separatedBy: "=").map(\.trimmed)
                guard parts.count == 2, parts[0].hasPrefix("Speaker "), !parts[1].isEmpty,
                      !["?", "unknown", "nieznany"].contains(parts[1].lowercased()) else { continue }
                names[parts[0]] = parts[1]
            }
        }
        return (names, kept.joined(separator: "\n").trimmed)
    }

    /// Replaces a speaker label as a whole word: "Speaker 1" but not "Speaker 10".
    public static func replace(_ label: String, with name: String, in text: String) -> String {
        let pattern = "(?<![\\p{L}\\d])" + NSRegularExpression.escapedPattern(for: label) + "(?![\\p{L}\\d])"
        return text.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: name),
                                         options: .regularExpression)
    }
}
