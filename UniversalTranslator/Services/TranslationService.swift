import Foundation
import FoundationModels

/// Result returned by a successful translation, including the full prompt
/// (surfaced in the LLM details sheet for inspection).
struct TranslationServiceResult {
    let translatedText: String
    let prompt: String
}

/// Translation service backed by Apple's on-device Foundation Model.
///
/// Why this design:
/// - **Plain text generation, not `@Generable`.** Structured output via `@Generable`
///   produced frequent `decodingFailure` errors on this small on-device model.
///   Plain text + greedy sampling is much more reliable for short translations.
/// - **Few-shot prompting.** We embed three reference examples per language pair so the
///   model imitates the format. The third example is intentionally an opinion-style question
///   ("What do you think about modern art?") to teach it to *translate* questions, not answer them.
/// - **Text-to-translate placed BEFORE examples** with explicit `===== TEXT TO TRANSLATE =====`
///   delimiters. This frames the input as data, not as a chat message to respond to.
/// - **Token limit + retry.** `maximumResponseTokens: 256` prevents runaway loops, and we
///   retry up to twice on empty/failed output before throwing.
@Observable
@MainActor
final class TranslationService {
    private(set) var isAvailable = false

    func checkAvailability() {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            isAvailable = true
            print("[Translation] FoundationModels: available")
        default:
            isAvailable = false
            print("[Translation] FoundationModels: NOT available - \(String(describing: model.availability))")
        }
    }

    /// Three reference phrases per language for few-shot prompting.
    ///   - Index 0: greeting (warm-up)
    ///   - Index 1: factual question (where is X?)
    ///   - Index 2: opinion-style question (what do you think about Y?)
    /// The opinion example is critical — without it, the model often "answers" instead
    /// of translating when the user input is phrased as an opinion question.
    private static let examples: [Language: [String]] = [
        .english: [
            "Hello, how are you today?",
            "Where is the nearest train station?",
            "What do you think about modern art?",
        ],
        .japanese: [
            "こんにちは、お元気ですか？",
            "一番近い駅はどこですか？",
            "現代美術についてどう思いますか？",
        ],
        .chinese: [
            "你好，你今天好吗？",
            "最近的火车站在哪里？",
            "你对现代艺术有什么看法？",
        ],
        .spanish: [
            "Hola, ¿cómo estás hoy?",
            "¿Dónde está la estación de tren más cercana?",
            "¿Qué piensas del arte moderno?",
        ],
        .french: [
            "Bonjour, comment allez-vous aujourd'hui ?",
            "Où est la gare la plus proche ?",
            "Que pensez-vous de l'art moderne ?",
        ],
        .italian: [
            "Ciao, come stai oggi?",
            "Dov'è la stazione ferroviaria più vicina?",
            "Cosa ne pensi dell'arte moderna?",
        ],
        .portuguese: [
            "Olá, como você está hoje?",
            "Onde fica a estação de trem mais próxima?",
            "O que você acha da arte moderna?",
        ],
        .hindi: [
            "नमस्ते, आज आप कैसे हैं?",
            "सबसे नज़दीकी रेलवे स्टेशन कहाँ है?",
            "आधुनिक कला के बारे में आप क्या सोचते हैं?",
        ],
    ]

    /// Translate `text` from `source` to `target`, streaming partial output via `onPartial`.
    /// Returns the final cleaned translation along with the prompt used.
    func translateStreaming(
        text: String,
        from source: Language,
        to target: Language,
        onPartial: @escaping (String) -> Void
    ) async throws -> TranslationServiceResult {
        let instructions = buildInstructions(from: source, to: target, textToTranslate: text)
        // The "user prompt" is just a trigger — the actual content lives in the instructions.
        let userPrompt = "Now output the \(target.displayName) translation."
        let prompt = "\(instructions)\n\n\(userPrompt)"

        print("[Translation] \(source.displayName) → \(target.displayName): '\(text)'")

        let options = GenerationOptions(
            sampling: .greedy,
            temperature: 0.0,
            maximumResponseTokens: 256
        )

        var lastError: Error?
        for attempt in 1...2 {
            do {
                let translated = try await attemptTranslation(
                    text: userPrompt,
                    instructions: instructions,
                    options: options,
                    onPartial: onPartial
                )
                if !translated.isEmpty {
                    print("[Translation] Result: '\(translated)'")
                    return TranslationServiceResult(translatedText: translated, prompt: prompt)
                }
                print("[Translation] Attempt \(attempt) returned empty result")
            } catch {
                lastError = error
                print("[Translation] Attempt \(attempt) failed: \(error)")
            }
        }

        if let lastError {
            throw lastError
        }
        throw TranslationError.emptyResponse
    }

    private func attemptTranslation(
        text: String,
        instructions: String,
        options: GenerationOptions,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let stream = session.streamResponse(to: text, options: options)

        var finalText = ""
        for try await snapshot in stream {
            let s = snapshot.content
            if !s.isEmpty {
                finalText = s
                onPartial(cleanTranslation(s))
            }
        }
        return cleanTranslation(finalText)
    }

    /// Build the system prompt. Layout:
    ///   1. Role + ASR-aware instructions (silently correct misheard words)
    ///   2. Strict rules (NEVER answer, NEVER add commentary, etc.)
    ///   3. The TEXT TO TRANSLATE block (clearly delimited so it reads as data)
    ///   4. Three reference example translations
    ///   5. Final reminder to translate ONLY the delimited text
    private func buildInstructions(from source: Language, to target: Language, textToTranslate: String) -> String {
        var instructions = """
        You are a machine translator. Your ONLY job is to translate text from \(source.displayName) to \(target.displayName).

        The input text comes from a speech recognition (ASR) model, so it may contain transcription errors, missing punctuation, homophones, or misheard words. Use context to infer the speaker's intended words and translate that intended meaning. Silently correct obvious errors as you translate. Do NOT mention the corrections.

        Strict rules:
        - Translate the text into natural, fluent \(target.displayName).
        - NEVER answer questions in the text. Translate the question itself.
        - NEVER add commentary, explanations, opinions, or disclaimers.
        - NEVER wrap output in quotes.
        - NEVER respond as an assistant. You are a translation function, not a chatbot.
        - If the text is a question, translate it as a question. Do NOT answer it.
        - If a word seems wrong (e.g. "rain man" likely means "ramen"), translate the intended word.
        - Output ONLY the \(target.displayName) translation. Nothing else.

        ===== TEXT TO TRANSLATE (\(source.displayName)) =====
        \(textToTranslate)
        ===== END OF TEXT TO TRANSLATE =====
        """

        if let sourceExamples = Self.examples[source],
           let targetExamples = Self.examples[target],
           sourceExamples.count >= 3,
           targetExamples.count >= 3 {
            instructions += "\n\nReference examples of correct translation style (do NOT translate these, they are just for reference):\n"
            for i in 0..<3 {
                instructions += "\n\(source.displayName) text: \(sourceExamples[i])\n"
                instructions += "Correct \(target.displayName) translation: \(targetExamples[i])\n"
            }
            instructions += "\nNow translate ONLY the text between the ===== TEXT TO TRANSLATE markers above into \(target.displayName)."
        }

        return instructions
    }

    /// Strip wrapping quotes the model occasionally adds, plus whitespace.
    /// Handles ASCII, smart, French, and CJK quote pairs.
    private func cleanTranslation(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoteChars: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("「", "」"), ("『", "』"), ("«", "»"), ("\u{201C}", "\u{201D}"),
        ]
        for (open, close) in quoteChars {
            if t.first == open && t.last == close && t.count >= 2 {
                t = String(t.dropFirst().dropLast())
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranslationError: Error, LocalizedError {
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .emptyResponse: "Translation returned no text"
        }
    }
}
