import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Cross-platform clipboard helper.
private func copyToClipboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

/// One translation as a chat bubble.
///   - **Tap** to replay the TTS for that translation.
///   - **Long press** for a context menu (copy original/translation, view LLM debug sheet).
/// Aligned left or right depending on which mic button initiated the recording.
struct MessageBubbleView: View {
    let message: TranslationMessage
    let onTap: () -> Void

    @State private var showDebug = false

    var body: some View {
        VStack(alignment: message.side == .left ? .leading : .trailing, spacing: 4) {
            Text(message.originalText)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
                .textSelection(.enabled)

            Text(message.translatedText)
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    message.side == .left
                        ? Color.red.opacity(0.15)
                        : Color.blue.opacity(0.15)
                )
        )
        .frame(maxWidth: .infinity, alignment: message.side == .left ? .leading : .trailing)
        .onTapGesture {
            onTap()
        }
        .contextMenu {
            Button {
                copyToClipboard(message.translatedText)
            } label: {
                Label("Copy Translation", systemImage: "doc.on.doc")
            }
            Button {
                copyToClipboard(message.originalText)
            } label: {
                Label("Copy Original", systemImage: "doc.on.doc")
            }
            Button {
                showDebug = true
            } label: {
                Label("Show LLM Details", systemImage: "brain")
            }
        }
        .sheet(isPresented: $showDebug) {
            LLMDebugView(message: message)
        }
    }
}

/// Sheet shown when the user long-presses a bubble and selects "Show LLM Details".
/// Surfaces the full prompt and the model's raw output so the user can inspect
/// exactly what the on-device LLM saw and produced.
private struct LLMDebugView: View {
    let message: TranslationMessage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Section("Pipeline") {
                        debugRow("Source Language", message.sourceLanguage.displayName)
                        debugRow("Target Language", message.targetLanguage.displayName)
                        debugRow("TTS Voice", message.targetLanguage.kokoroVoice)
                    }

                    Section("ASR Output") {
                        Text(message.originalText)
                            .font(.body.monospaced())
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gray.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Section("LLM Prompt") {
                        Text(message.llmPrompt)
                            .font(.caption.monospaced())
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gray.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    if !message.corrections.isEmpty {
                        Section("ASR Corrections") {
                            Text(message.corrections)
                                .font(.body.monospaced())
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    Section("LLM Output (translatedText)") {
                        Text(message.translatedText)
                            .font(.body.monospaced())
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gray.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding()
                .textSelection(.enabled)
            }
            .navigationTitle("Translation Details")
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

    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

/// Lightweight section header used inside the LLM details sheet.
/// (Shadows the SwiftUI `Section` name on purpose so we don't get list styling.)
private struct Section<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
    }
}
