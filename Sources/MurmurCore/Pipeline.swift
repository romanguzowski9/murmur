import Foundation

public protocol TextGenerator {
    func complete(system: String, user: String) async throws -> String
}

/// One dictation, plus the context captured from the focused text field.
public struct DictationRequest {
    public var raw: String
    public var category: AppCategory
    public var style: WritingStyle
    public var cleanup: CleanupLevel
    public var dictionary: [DictionaryEntry]
    public var snippets: [Snippet]
    public var language: String
    public var appName: String?
    public var beforeText: String?
    public var selectedText: String?
    public var afterText: String?

    public init(raw: String, category: AppCategory, style: WritingStyle, cleanup: CleanupLevel,
                dictionary: [DictionaryEntry] = [], snippets: [Snippet] = [], language: String = "en",
                appName: String? = nil, beforeText: String? = nil, selectedText: String? = nil, afterText: String? = nil) {
        self.raw = raw
        self.category = category
        self.style = style
        self.cleanup = cleanup
        self.dictionary = dictionary
        self.snippets = snippets
        self.language = language
        self.appName = appName
        self.beforeText = beforeText
        self.selectedText = selectedText
        self.afterText = afterText
    }

    var formatContext: FormatContext {
        FormatContext(category: category, style: style, cleanup: cleanup, dictionary: dictionary, snippets: snippets,
                      language: language)
    }
}

public struct DictationResult {
    public var text: String
    public var localText: String
    public var usedLLM: Bool
    public var error: String?
}

public enum Pipeline {
    /// Utterances this short are formatted locally; an LLM round-trip is not worth the latency.
    static let minWordsForLLM = 3

    public static func dictate(_ request: DictationRequest, llm: TextGenerator?) async -> DictationResult {
        let ctx = request.formatContext
        let local = LocalFormatter.format(request.raw, ctx)
        func finish(_ text: String, usedLLM: Bool, error: String? = nil) -> DictationResult {
            let joined = ContextJoiner.join(text, before: request.beforeText, after: request.afterText,
                                            keepCase: ctx.keepCase)
            return DictationResult(text: joined, localText: local, usedLLM: usedLLM, error: error)
        }
        guard let llm, request.cleanup != .none, request.raw.wordCount >= minWordsForLLM else {
            return finish(local, usedLLM: false)
        }

        // Snippets are protected as visible tokens the model is told to keep.
        var protector = Protector()
        var pre = LocalFormatter.applySnippets(request.raw, request.snippets, &protector)
        pre = LocalFormatter.applyDictionary(pre, request.dictionary)
        pre = regexReplace(pre, "\u{E000}(\\d+)\u{E001}", template: "⟦S$1⟧", [])

        do {
            var out = try await llm.complete(system: Prompts.dictationSystem(request),
                                             user: Prompts.dictationUser(pre, request))
            out = Prompts.sanitize(out)
            out = regexReplace(out, "⟦S(\\d+)⟧", template: "\u{E000}$1\u{E001}", [])
            out = protector.restore(out)
            out = LocalFormatter.applyDictionary(out, request.dictionary)
            guard !out.isEmpty, out.count <= request.raw.count * 3 + 200 else {
                return finish(local, usedLLM: false, error: "LLM output rejected")
            }
            return finish(out, usedLLM: true)
        } catch {
            return finish(local, usedLLM: false, error: "\(error)")
        }
    }

    /// Command Mode: apply a spoken instruction to the selected text (or write new text if nothing is selected).
    public static func command(instruction: String, selected: String?, appName: String?, llm: TextGenerator) async throws
        -> String {
        let out = try await llm.complete(system: Prompts.commandSystem,
                                         user: Prompts.commandUser(instruction: instruction, selected: selected,
                                                                   appName: appName))
        return Prompts.sanitize(out)
    }

    /// Transform/Polish: rewrite text using the built-in polish rules.
    public static func polish(_ text: String, style: WritingStyle, llm: TextGenerator) async throws -> String {
        let out = try await llm.complete(system: Prompts.polishSystem(style: style), user: "<text>\n\(text)\n</text>")
        return Prompts.sanitize(out)
    }
}
