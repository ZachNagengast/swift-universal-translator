import SwiftUI

/// Modal sheet for picking the language assigned to one side of the device.
/// Presented when the user taps a language pill in the conversation header.
struct LanguageSelectorView: View {
    @Binding var selectedLanguage: Language
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Language.allCases) { language in
                Button {
                    selectedLanguage = language
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text(language.flag)
                            .font(.title2)
                        Text(language.displayName)
                            .foregroundStyle(.primary)
                        Spacer()
                        if language == selectedLanguage {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                                .fontWeight(.semibold)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            #if os(macOS)
            .frame(minWidth: 280, minHeight: 350)
            #endif
            .navigationTitle("Select Language")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
