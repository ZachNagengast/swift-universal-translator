import Foundation

/// Languages supported by the full ASR → Translation → TTS pipeline.
///
/// The set is the intersection of:
/// - Whisper's transcription languages
/// - Apple FoundationModels translation capability
/// - Kokoro TTS voices
///
/// To add a language, extend the enum and provide its WhisperKit code and Kokoro voice ID.
enum Language: String, CaseIterable, Identifiable, Codable {
    case english = "en"
    case japanese = "ja"
    case chinese = "zh"
    case spanish = "es"
    case french = "fr"
    case italian = "it"
    case portuguese = "pt"
    case hindi = "hi"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: "English"
        case .japanese: "Japanese"
        case .chinese: "Chinese"
        case .spanish: "Spanish"
        case .french: "French"
        case .italian: "Italian"
        case .portuguese: "Portuguese"
        case .hindi: "Hindi"
        }
    }

    /// Country flag emoji for UI display.
    var flag: String {
        switch self {
        case .english: "\u{1F1FA}\u{1F1F8}"
        case .japanese: "\u{1F1EF}\u{1F1F5}"
        case .chinese: "\u{1F1E8}\u{1F1F3}"
        case .spanish: "\u{1F1EA}\u{1F1F8}"
        case .french: "\u{1F1EB}\u{1F1F7}"
        case .italian: "\u{1F1EE}\u{1F1F9}"
        case .portuguese: "\u{1F1E7}\u{1F1F7}"
        case .hindi: "\u{1F1EE}\u{1F1F3}"
        }
    }

    /// ISO 639-1 code passed to `WhisperKit.DecodingOptions.language`.
    var whisperCode: String { rawValue }

    /// Default Kokoro voice ID for this language.
    ///
    /// Kokoro auto-detects the language from the voice prefix (`a` = American English,
    /// `j` = Japanese, `z` = Chinese, etc.) so we don't need to pass a separate language code.
    /// See: https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md
    var kokoroVoice: String {
        switch self {
        case .english: "af_heart"
        case .japanese: "jf_alpha"
        case .chinese: "zf_xiaobei"
        case .spanish: "ef_dora"
        case .french: "ff_siwis"
        case .italian: "if_sara"
        case .portuguese: "pf_dora"
        case .hindi: "hf_alpha"
        }
    }
}
