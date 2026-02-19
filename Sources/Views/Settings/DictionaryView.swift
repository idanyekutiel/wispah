import SwiftUI

struct DictionaryView: View {
    @EnvironmentObject var appState: AppState
    @State private var vocabularyInput: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictionary")
                        .font(.title2.bold())
                    Text("Words and phrases to preserve during transcription and post-processing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextEditor(text: $vocabularyInput)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200, maxHeight: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .onChange(of: vocabularyInput) { newValue in
                        appState.customVocabulary = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    }

                Text("Separate entries with commas, new lines, or semicolons. These terms are sent as hints to the transcription model and used by post-processing to correct spelling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .onAppear {
            vocabularyInput = appState.customVocabulary
        }
    }
}
