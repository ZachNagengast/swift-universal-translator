import FoundationModels

/// Generable schema for FoundationModels structured output.
///
/// Currently unused in the active pipeline (we settled on plain text generation
/// because the on-device model produces more reliable output without a JSON schema constraint),
/// but kept here as a reference for `@Generable` usage.
@Generable
struct TranslationOutput {
    @Guide(description: "The translated text in the target language")
    var translatedText: String
}
