// AnalysisPanelView.swift
// Right panel displaying AI analysis results and conversation threads
//
// Features: analysis types, streaming results, follow-up questions, history

import SwiftUI
import SwiftData

struct AnalysisPanelView: View {
    @Bindable var viewModel: ReaderViewModel

    @Environment(SettingsManager.self) private var settings

    @State private var followUpQuestion = ""
    @FocusState private var isQuestionFocused: Bool

    // MARK: - Markdown Text Helper
    /// Renders markdown text with fallback to plain text if parsing fails
    private func markdownText(_ string: String) -> Text {
        if let attributed = try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        } else {
            return Text(string)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let highlight = viewModel.selectedHighlight {
                        selectedTextSection(highlight)
                        analysisSection(highlight)
                    } else if !viewModel.selectedText.isEmpty {
                        pendingSelectionSection
                    } else {
                        emptyStateSection
                    }
                }
                .padding()
            }

            // Follow-up Question Input
            if viewModel.selectedHighlight != nil {
                followUpInputSection
            }
        }
        .background(settings.theme.secondaryBackgroundColor)
    }

    // MARK: - Header
    private var header: some View {
        HStack {
            Text("AI Analysis")
                .font(.headline)
                .foregroundStyle(settings.theme.textColor)

            Spacer()

            if viewModel.selectedHighlight != nil {
                Button {
                    viewModel.selectedHighlight = nil
                    viewModel.analysisResult = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(settings.theme.backgroundColor)
    }

    // MARK: - Selected Text Section
    private func selectedTextSection(_ highlight: HighlightModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Selected Text")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                // Quick analysis menu (excluding types that need user input) + Delete option
                Menu {
                    ForEach(AnalysisType.quickAnalysisTypes, id: \.self) { type in
                        Button {
                            viewModel.performAnalysis(
                                type: type,
                                text: highlight.selectedText,
                                context: highlight.fullContext
                            )
                        } label: {
                            Label(type.displayName, systemImage: type.iconName)
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            viewModel.deleteHighlight(highlight)
                        }
                    } label: {
                        Label("Delete Highlight", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(settings.theme.accentColor)
                }
            }

            // Selected text box (delete via ellipsis menu above)
            Text(highlight.selectedText)
                .font(.subheadline)
                .foregroundStyle(settings.theme.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: highlight.colorHex ?? "#ffff00")?.opacity(0.2) ?? Color.yellow.opacity(0.2))
                )

            // Quick Analysis Buttons + Delete
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AnalysisType.quickAnalysisTypes.prefix(4), id: \.self) { type in
                        analysisTypeButton(type, highlight: highlight)
                    }

                    // Delete button (same style as analysis buttons)
                    Button {
                        viewModel.deleteHighlight(highlight)
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(Color.red.opacity(0.15))
                            )
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func analysisTypeButton(_ type: AnalysisType, highlight: HighlightModel) -> some View {
        Button {
            viewModel.performAnalysis(
                type: type,
                text: highlight.selectedText,
                context: highlight.fullContext
            )
        } label: {
            Label(type.displayName, systemImage: type.iconName)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color(hex: type.colorHex)?.opacity(0.2) ?? settings.theme.accentColor.opacity(0.2))
                )
                .foregroundStyle(Color(hex: type.colorHex) ?? settings.theme.accentColor)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Analysis Section
    private func analysisSection(_ highlight: HighlightModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Current Analysis Area (loading or result)
            currentAnalysisView
                .animation(.easeInOut(duration: 0.2), value: viewModel.isAnalyzing)
                .animation(.easeInOut(duration: 0.2), value: viewModel.analysisResult != nil)

            // Previous Analyses
            if !highlight.analyses.isEmpty {
                Text("Previous Analyses")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                ForEach(highlight.analyses.sorted(by: { $0.createdAt > $1.createdAt })) { analysis in
                    previousAnalysisCard(analysis)
                }
            }
        }
    }

    // MARK: - Current Analysis View (loading or result)
    @ViewBuilder
    private var currentAnalysisView: some View {
        if viewModel.isAnalyzing {
            // Loading State
            HStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.8)

                Text("Analyzing...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(settings.theme.backgroundColor.opacity(0.5))
            )
            .transition(.opacity)
        } else if let result = viewModel.analysisResult {
            // Result View
            resultView(result)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private func resultView(_ result: String) -> some View {
        if result.hasPrefix("Error:") {
            // Error display with styled container
            VStack(alignment: .leading, spacing: 8) {
                Label("Error", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)

                Text(result.replacingOccurrences(of: "Error: ", with: ""))
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.textColor.opacity(0.8))
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
            )
        } else {
            // Normal result display
            VStack(alignment: .leading, spacing: 8) {
                if let type = viewModel.currentAnalysisType {
                    Label(type.displayName, systemImage: type.iconName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(hex: type.colorHex) ?? settings.theme.accentColor)
                }

                markdownText(result)
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.textColor)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(settings.theme.backgroundColor)
            )
        }
    }

    private func previousAnalysisCard(_ analysis: AIAnalysisModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(analysis.analysisType.displayName, systemImage: analysis.analysisType.iconName)
                    .font(.caption)
                    .foregroundStyle(Color(hex: analysis.analysisType.colorHex) ?? .secondary)

                Spacer()

                Text(analysis.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            markdownText(analysis.response)
                .font(.caption)
                .foregroundStyle(settings.theme.textColor)
                .lineLimit(4)

            // Conversation Thread
            if let thread = analysis.thread, !thread.turns.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(thread.turns.sorted(by: { $0.turnIndex < $1.turnIndex })) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Q: \(turn.question)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            (Text("A: ") + markdownText(turn.answer))
                                .font(.caption2)
                                .foregroundStyle(settings.theme.textColor)
                        }
                        .padding(.leading, 8)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(settings.theme.textColor.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Pending Selection Section
    private var pendingSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text Selected")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Text(viewModel.selectedText)
                .font(.subheadline)
                .foregroundStyle(settings.theme.textColor)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.yellow.opacity(0.2))
                )

            Text("Create a highlight to analyze this text")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Empty State Section
    private var emptyStateSection: some View {
        VStack(spacing: 16) {
            // Show current chapter highlights if any exist
            if !viewModel.currentChapterHighlights.isEmpty {
                chapterHighlightsSection
            } else {
                // Show intro when no highlights in chapter
                introSection
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Chapter Highlights Section
    private var chapterHighlightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Chapter Highlights", systemImage: "highlighter")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(viewModel.currentChapterHighlights.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(settings.theme.accentColor.opacity(0.2)))
            }

            ForEach(viewModel.currentChapterHighlights.sorted(by: { $0.startOffset < $1.startOffset })) { highlight in
                chapterHighlightRow(highlight)
            }

            // Hint to create more
            HStack {
                Image(systemName: "plus.circle")
                    .font(.caption)
                    .foregroundStyle(settings.theme.accentColor.opacity(0.6))

                Text("Select text in the chapter to add more highlights")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private func chapterHighlightRow(_ highlight: HighlightModel) -> some View {
        Button {
            viewModel.selectedHighlight = highlight
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(highlight.selectedText)
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.textColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 8) {
                    // Analysis type icons
                    if !highlight.analyses.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(Set(highlight.analyses.map(\.analysisType))), id: \.self) { type in
                                Image(systemName: type.iconName)
                                    .font(.caption2)
                                    .foregroundStyle(Color(hex: type.colorHex) ?? .secondary)
                            }
                        }
                    } else {
                        Text("No analysis yet")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: highlight.colorHex ?? "#ffff00")?.opacity(0.15) ?? Color.yellow.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(hex: highlight.colorHex ?? "#ffff00")?.opacity(0.3) ?? Color.yellow.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Intro Section (when no highlights)
    private var introSection: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [settings.theme.accentColor.opacity(0.6), settings.theme.accentColor.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 8) {
                Text("AI Reading Assistant")
                    .font(.headline)
                    .foregroundStyle(settings.theme.textColor.opacity(0.7))

                Text("Select text in the chapter to unlock powerful AI analysis")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "checkmark.seal", text: "Fact-check claims", color: .green)
                featureRow(icon: "list.bullet", text: "Extract key points", color: .blue)
                featureRow(icon: "bubble.left.and.bubble.right", text: "Start discussions", color: .purple)
                featureRow(icon: "questionmark.circle", text: "Ask custom questions", color: .orange)
            }
            .padding(.top, 8)
        }
        .padding(24)
    }

    private func featureRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(color)
                .frame(width: 24)

            Text(text)
                .font(.caption)
                .foregroundStyle(settings.theme.textColor.opacity(0.6))

            Spacer()
        }
    }

    // MARK: - Follow-up Input Section
    private var followUpInputSection: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                TextField("Ask a follow-up question...", text: $followUpQuestion, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .focused($isQuestionFocused)
                    .lineLimit(1...4)

                Button {
                    if !followUpQuestion.isEmpty, let highlight = viewModel.selectedHighlight {
                        viewModel.askFollowUpQuestion(highlight: highlight, question: followUpQuestion)
                        followUpQuestion = ""
                        isQuestionFocused = false
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            followUpQuestion.isEmpty
                            ? settings.theme.textColor.opacity(0.3)
                            : settings.theme.accentColor
                        )
                }
                .disabled(followUpQuestion.isEmpty || viewModel.isAnalyzing)
            }
            .padding(12)
            .background(settings.theme.backgroundColor)
        }
    }
}

// MARK: - Analysis Type Extensions
extension AnalysisType {
    var iconName: String {
        switch self {
        case .factCheck: return "checkmark.seal"
        case .discussion: return "bubble.left.and.bubble.right"
        case .keyPoints: return "list.bullet"
        case .argumentMap: return "chart.bar.doc.horizontal"
        case .counterpoints: return "arrow.left.arrow.right"
        case .customQuestion: return "questionmark.circle"
        case .comment: return "text.bubble"
        }
    }
}

#Preview {
    @Previewable @State var container = try! ModelContainer(for: BookModel.self)
    let book = BookModel(title: "Sample", authors: ["Author"])
    AnalysisPanelView(
        viewModel: ReaderViewModel(
            book: book,
            modelContext: container.mainContext
        )
    )
    .frame(width: 350)
}
