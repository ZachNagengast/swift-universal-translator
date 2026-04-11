import FoundationModels

/// Structured output schema for the on-device translation LLM.
///
/// Properties are generated in declaration order: the model fills `corrections`
/// first (giving it a place to reason about ASR errors), then `translatedText`.
@Generable(description: "A translation of spoken text between two languages")
struct TranslationOutput {
    @Guide(description: "Empty string unless the ASR misheard an English word, e.g. 'rain man → ramen'. Do NOT put translations here.")
    var corrections: String

    @Guide(description: "The translated text in the target language")
    var translatedText: String
}
