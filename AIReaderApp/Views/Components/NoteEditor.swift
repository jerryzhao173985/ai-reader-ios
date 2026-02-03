// NoteEditor.swift
// Inline note editor for highlights
//
// Mental Model: Notes are quick personal annotations, not AI analysis.
// Design: Tap to expand → edit → tap outside to collapse (auto-saves)

import SwiftUI
import UIKit

/// Inline note editor with collapsed/expanded states
/// - Collapsed: Shows note text or placeholder, tap to expand
/// - Expanded: Editable text field, auto-saves on change
struct NoteEditor: View {
    @Binding var note: String?
    let placeholder: String
    let accentColor: Color
    let backgroundColor: Color
    let textColor: Color

    @State private var isEditing = false
    @State private var localText = ""
    @FocusState private var isFocused: Bool

    init(
        note: Binding<String?>,
        placeholder: String = "Add a note...",
        accentColor: Color = .blue,
        backgroundColor: Color = .clear,
        textColor: Color = .primary
    ) {
        self._note = note
        self.placeholder = placeholder
        self.accentColor = accentColor
        self.backgroundColor = backgroundColor
        self.textColor = textColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEditing {
                expandedEditor
            } else {
                collapsedView
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isEditing)
        .onAppear {
            localText = note ?? ""
        }
        .onChange(of: note) { _, newValue in
            // Sync external changes (e.g., from another view)
            if !isEditing {
                localText = newValue ?? ""
            }
        }
    }

    // MARK: - Collapsed View
    private var collapsedView: some View {
        Button {
            localText = note ?? ""
            isEditing = true
            // Delay focus to allow animation
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                isFocused = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: hasNote ? "note.text" : "plus.circle")
                    .font(.subheadline)
                    .foregroundStyle(hasNote ? accentColor : .secondary)

                if hasNote {
                    Text(note!)
                        .font(.subheadline)
                        .foregroundStyle(textColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } else {
                    Text(placeholder)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if hasNote {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hasNote ? accentColor.opacity(0.08) : backgroundColor.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(hasNote ? accentColor.opacity(0.2) : Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded Editor
    private var expandedEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "note.text")
                    .font(.caption)
                    .foregroundStyle(accentColor)

                Text("Note")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    saveAndClose()
                } label: {
                    Text("Done")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(accentColor)
                }
            }

            TextField("Write your note...", text: $localText, axis: .vertical)
                .font(.subheadline)
                .foregroundStyle(textColor)
                .lineLimit(1...6)
                .focused($isFocused)
                .onSubmit {
                    saveAndClose()
                }
                .onChange(of: localText) { _, newValue in
                    // Auto-save as user types (debounced by SwiftUI)
                    // Trim whitespace to avoid saving blank notes
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    note = trimmed.isEmpty ? nil : trimmed
                }

            // Clear button (only if text exists)
            if !localText.isEmpty {
                Button {
                    localText = ""
                    note = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                        Text("Clear note")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accentColor.opacity(0.3), lineWidth: 1)
        )
        .onChange(of: isFocused) { _, focused in
            if !focused {
                saveAndClose()
            }
        }
    }

    // MARK: - Helpers
    private var hasNote: Bool {
        if let note, !note.isEmpty {
            return true
        }
        return false
    }

    private func saveAndClose() {
        // Guard against double-call from onChange(of: isFocused)
        guard isEditing else { return }

        let trimmed = localText.trimmingCharacters(in: .whitespacesAndNewlines)
        note = trimmed.isEmpty ? nil : trimmed
        isEditing = false
        isFocused = false
        // Light haptic feedback on save
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Preview
#Preview("Empty Note") {
    NoteEditor(
        note: .constant(nil),
        accentColor: .blue,
        backgroundColor: Color(.systemGray6),
        textColor: .primary
    )
    .padding()
}

#Preview("With Note") {
    NoteEditor(
        note: .constant("This is an important passage that reminds me of the central thesis."),
        accentColor: .orange,
        backgroundColor: Color(.systemGray6),
        textColor: .primary
    )
    .padding()
}
