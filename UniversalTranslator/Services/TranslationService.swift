import Foundation
import FoundationModels

/// Result returned by a successful translation, including the full prompt
/// (surfaced in the LLM details sheet for inspection).
struct TranslationServiceResult {
    let translatedText: String
    let corrections: String
    let prompt: String
}

/// Translation service backed by Apple's on-device Foundation Model using `@Generable`
/// structured output with few-shot prompting.
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
    func translateStreaming(
        text: String,
        from source: Language,
        to target: Language,
        onPartial: @escaping (String) -> Void
    ) async throws -> TranslationServiceResult {
        print("[Translation] \(source.displayName) → \(target.displayName): '\(text)'")

        // IMPORTANT: Do NOT set maximumResponseTokens here. With @Generable, constrained
        // sampling terminates naturally when the JSON schema is complete. Setting a token
        // limit risks truncating the JSON mid-generation → decodingFailure.
        let options = GenerationOptions(
            sampling: .greedy,
            temperature: 0.0
        )

        // Try @Generable first (structured output with corrections field).
        do {
            let result = try await attemptTranslation(
                text: text,
                from: source,
                to: target,
                options: options,
                onPartial: onPartial
            )
            if !result.output.translatedText.isEmpty {
                print("[Translation] Result: '\(result.output.translatedText)' | Corrections: '\(result.output.corrections)'")
                return TranslationServiceResult(
                    translatedText: result.output.translatedText,
                    corrections: result.output.corrections,
                    prompt: result.transcriptDump
                )
            }
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:
                // Guardrails triggered — fall back to permissive plain-text mode.
                // Translation is a content transformation, not content generation,
                // so permissiveContentTransformations is the appropriate mode here.
                print("[Translation] Guardrail hit — retrying with permissive content transformations")
                if let result = try? await attemptPermissiveTranslation(
                    text: text, from: source, to: target, onPartial: onPartial
                ) {
                    return result
                }
                throw error
            case .refusal(let refusal, _):
                let explanation = await Self.refusalExplanation(refusal)
                print("[Translation] Model refused: \(explanation)")
                throw TranslationError.refused(explanation)
            default:
                print("[Translation] LLM error: \(error)")
                throw error
            }
        }

        throw TranslationError.emptyResponse
    }

    private func attemptTranslation(
        text: String,
        from source: Language,
        to target: Language,
        options: GenerationOptions,
        onPartial: @escaping (String) -> Void
    ) async throws -> (output: TranslationOutput, transcriptDump: String) {
        let transcript = buildFewShotTranscript(from: source, to: target)
        let session = LanguageModelSession(transcript: transcript)

        let stream = session.streamResponse(
            to: text,
            generating: TranslationOutput.self,
            options: options
        )

        var finalOutput = TranslationOutput(corrections: "", translatedText: "")
        var lastCorrections = ""
        var lastTranslation = ""

        for try await snapshot in stream {
            // Log every streaming delta so we can see the model's token-by-token output
            if let corrections = snapshot.content.corrections, corrections != lastCorrections {
                let delta = String(corrections.dropFirst(lastCorrections.count))
                print("[LLM] corrections += '\(delta)' → '\(corrections)'")
                lastCorrections = corrections
                finalOutput.corrections = corrections
            }
            if let partial = snapshot.content.translatedText, partial != lastTranslation {
                let delta = String(partial.dropFirst(lastTranslation.count))
                print("[LLM] translatedText += '\(delta)' → '\(partial)'")
                lastTranslation = partial
                finalOutput.translatedText = partial
                onPartial(cleanTranslation(partial))
            }
        }

        print("[LLM] Final corrections: '\(finalOutput.corrections)'")
        print("[LLM] Final translation: '\(finalOutput.translatedText)'")

        // Also dump the full transcript so we can see what the model saw
        for (i, entry) in session.transcript.enumerated() {
            print("[LLM] Transcript[\(i)]: \(entry)")
        }

        finalOutput.translatedText = cleanTranslation(finalOutput.translatedText)

        let transcriptDump = session.transcript.map { String(describing: $0) }.joined(separator: "\n---\n")
        return (finalOutput, transcriptDump)
    }

    /// Build a Transcript with instructions + few-shot example turns.
    ///
    /// Each example becomes a prompt→response pair in the conversation history, using
    /// `TranslationOutput` as the structured response type. The model sees these as
    /// prior turns and continues the pattern for the real request.
    private func buildFewShotTranscript(from source: Language, to target: Language) -> Transcript {
        let instructionText = """
        Translate text from \(source.displayName) to \(target.displayName). \
        The input is from speech recognition and may contain errors. \
        Note any corrections in the corrections field. \
        If the input is a question, translate the question — do NOT answer it.
        """

        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: [
                .text(Transcript.TextSegment(content: instructionText))
            ], toolDefinitions: []))
        ]

        // Add few-shot examples as prompt→response pairs
        if let sourceExamples = Self.examples[source],
           let targetExamples = Self.examples[target],
           sourceExamples.count >= 3,
           targetExamples.count >= 3 {
            for i in 0..<3 {
                let exampleOutput = TranslationOutput(
                    corrections: "",
                    translatedText: targetExamples[i]
                )
                entries.append(.prompt(Transcript.Prompt(segments: [
                    .text(Transcript.TextSegment(content: sourceExamples[i]))
                ], responseFormat: Transcript.ResponseFormat(type: TranslationOutput.self))))
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [
                    .structure(Transcript.StructuredSegment(
                        source: String(describing: TranslationOutput.self),
                        content: exampleOutput.generatedContent
                    ))
                ])))
            }
        }

        return Transcript(entries: entries)
    }

    /// Fallback: plain-text translation with `permissiveContentTransformations`.
    /// Used when @Generable hits guardrails on sensitive-but-legitimate translation input.
    /// This mode is designed for content transformation tasks (like translation) where
    /// the model needs to reason about sensitive source material without blocking it.
    private func attemptPermissiveTranslation(
        text: String,
        from source: Language,
        to target: Language,
        onPartial: @escaping (String) -> Void
    ) async throws -> TranslationServiceResult {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let instructions = buildPlainTextInstructions(from: source, to: target, textToTranslate: text)
        let session = LanguageModelSession(model: model, instructions: instructions)
        let options = GenerationOptions(sampling: .greedy, temperature: 0.0, maximumResponseTokens: 512)

        let stream = session.streamResponse(to: "Now output the \(target.displayName) translation.", options: options)
        var finalText = ""
        for try await snapshot in stream {
            let s = snapshot.content
            if !s.isEmpty {
                finalText = s
                onPartial(cleanTranslation(s))
            }
        }

        let cleaned = cleanTranslation(finalText)
        print("[Translation] Permissive fallback result: '\(cleaned)'")
        return TranslationServiceResult(
            translatedText: cleaned,
            corrections: "",
            prompt: "Permissive plain-text fallback: \(source.displayName) → \(target.displayName)"
        )
    }

    /// Extract the refusal explanation as a plain String.
    /// `Response<String>` isn't Sendable in the current SDK, so we wrap the call
    /// in a nonisolated Task to avoid crossing actor boundaries.
    private static func refusalExplanation(
        _ refusal: LanguageModelSession.GenerationError.Refusal
    ) async -> String {
        await Task.detached {
            do {
                let response = try await refusal.explanation
                return response.content
            } catch {
                return "The model declined to translate this request."
            }
        }.value
    }

    /// Full text-based prompt used by the permissive plain-text fallback path.
    /// Embeds the text to translate before the few-shot examples with clear delimiters.
    private func buildPlainTextInstructions(from source: Language, to target: Language, textToTranslate: String) -> String {
        var instructions = """
        You are a machine translator. Your ONLY job is to translate text from \(source.displayName) to \(target.displayName).

        The input text comes from a speech recognition (ASR) model, so it may contain \
        transcription errors, missing punctuation, homophones, or misheard words. Use context \
        to infer the speaker's intended words and translate that intended meaning. Silently \
        correct obvious errors as you translate. Do NOT mention the corrections.

        Strict rules:
        - Translate the text into natural, fluent \(target.displayName).
        - NEVER answer questions in the text. Translate the question itself.
        - NEVER add commentary, explanations, opinions, or disclaimers.
        - NEVER wrap output in quotes.
        - If the text is a question, translate it as a question. Do NOT answer it.
        - Output ONLY the \(target.displayName) translation. Nothing else.

        ===== TEXT TO TRANSLATE (\(source.displayName)) =====
        \(textToTranslate)
        ===== END OF TEXT TO TRANSLATE =====
        """

        if let sourceExamples = Self.examples[source],
           let targetExamples = Self.examples[target],
           sourceExamples.count >= 3,
           targetExamples.count >= 3 {
            instructions += "\n\nExamples:\n"
            for i in 0..<3 {
                instructions += "\(source.displayName): \(sourceExamples[i]) → \(target.displayName): \(targetExamples[i])\n"
            }
            instructions += "\nNow translate ONLY the text between the ===== markers above."
        }

        return instructions
    }

    /// Strip wrapping quotes the model occasionally adds, plus whitespace.
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
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse: "Translation returned no text"
        case .refused(let reason): reason
        }
    }
}
