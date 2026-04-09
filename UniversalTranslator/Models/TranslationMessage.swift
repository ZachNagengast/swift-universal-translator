import Foundation

/// One completed pipeline run: original ASR text + its translation.
///
/// Stored in `TranslatorViewModel.messages` and rendered as a chat bubble.
/// Tap the bubble to replay TTS, long-press for the LLM details sheet.
struct TranslationMessage: Identifiable {
    let id = UUID()
    let originalText: String
    let translatedText: String
    let sourceLanguage: Language
    let targetLanguage: Language
    let timestamp: Date
    /// Which side of the device initiated the recording.
    let side: PanelSide
    /// The full prompt sent to the on-device LLM. Surfaced in the details sheet
    /// for inspection.
    var llmPrompt: String = ""
}

/// Identifies which colored mic button started a translation.
/// Left = red (your language), right = blue (their language).
enum PanelSide {
    case left
    case right
}
