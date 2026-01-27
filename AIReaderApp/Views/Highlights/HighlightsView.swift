// HighlightsView.swift
// View displaying all highlights for a book with export functionality
//
// Features: highlight list, filtering, export to Markdown/JSON, delete

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct HighlightsView: View {
    let book: BookModel

    @Environment(SettingsManager.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAnalysisType: AnalysisType?
    @State private var searchText = ""
    @State private var showingExportOptions = false
    @State private var exportDocument: HighlightsExportDocument?
    @State private var showingExportSheet = false
    /// Highlight selected for detail view (shows analyses in sheet)
    @State private var selectedHighlightForDetail: HighlightModel?

    private var filteredHighlights: [HighlightModel] {
        var highlights = book.highlights.sorted(by: { $0.createdAt > $1.createdAt })

        if !searchText.isEmpty {
            highlights = highlights.filter {
                $0.selectedText.localizedCaseInsensitiveContains(searchText)
            }
        }

        if let type = selectedAnalysisType {
            highlights = highlights.filter {
                $0.analyses.contains(where: { $0.analysisType == type })
            }
        }

        return highlights
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter Bar
                filterBar

                // Highlights List
                if filteredHighlights.isEmpty {
                    emptyState
                } else {
                    highlightsList
                }
            }
            .background(settings.theme.backgroundColor)
            .navigationTitle("Highlights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            exportToMarkdown()
                        } label: {
                            Label("Export as Markdown", systemImage: "doc.text")
                        }

                        Button {
                            exportToJSON()
                        } label: {
                            Label("Export as JSON", systemImage: "curlybraces")
                        }

                        Button {
                            copyToClipboard()
                        } label: {
                            Label("Copy to Clipboard", systemImage: "doc.on.doc")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(book.highlights.isEmpty)
                }
            }
            .searchable(text: $searchText, prompt: "Search highlights")
            .fileExporter(
                isPresented: $showingExportSheet,
                document: exportDocument,
                contentType: exportDocument?.contentType ?? .plainText,
                defaultFilename: exportDocument?.filename ?? "highlights"
            ) { result in
                exportDocument = nil
            }
        }
    }

    // MARK: - Filter Bar
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    title: "All",
                    isSelected: selectedAnalysisType == nil,
                    color: settings.theme.accentColor
                ) {
                    selectedAnalysisType = nil
                }

                ForEach(AnalysisType.allCases, id: \.self) { type in
                    FilterChip(
                        title: type.displayName,
                        isSelected: selectedAnalysisType == type,
                        color: Color(hex: type.colorHex) ?? settings.theme.accentColor
                    ) {
                        selectedAnalysisType = type
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(settings.theme.secondaryBackgroundColor)
    }

    // MARK: - Highlights List
    private var highlightsList: some View {
        List {
            ForEach(filteredHighlights) { highlight in
                HighlightRow(highlight: highlight, settings: settings)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Show analyses for this highlight in a detail sheet
                        selectedHighlightForDetail = highlight
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteHighlight(highlight)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    // CRITICAL: Hide white separators and use theme-colored background
                    .listRowSeparator(.hidden)
                    .listRowBackground(settings.theme.backgroundColor)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)  // Hide default List white background
        .background(settings.theme.backgroundColor)
        .sheet(item: $selectedHighlightForDetail) { highlight in
            HighlightDetailSheet(highlight: highlight, book: book)
                .environment(settings)
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "highlighter")
                .font(.system(size: 50))
                .foregroundStyle(settings.theme.textColor.opacity(0.3))

            Text(searchText.isEmpty && selectedAnalysisType == nil
                 ? "No Highlights Yet"
                 : "No Matching Highlights")
                .font(.headline)
                .foregroundStyle(settings.theme.textColor.opacity(0.5))

            Text(searchText.isEmpty && selectedAnalysisType == nil
                 ? "Highlight text while reading to save and analyze passages."
                 : "Try adjusting your search or filters.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Actions
    private func deleteHighlight(_ highlight: HighlightModel) {
        modelContext.delete(highlight)
        try? modelContext.save()
    }

    private func exportToMarkdown() {
        let markdown = generateMarkdown()
        exportDocument = HighlightsExportDocument(
            content: markdown,
            contentType: .plainText,
            filename: "\(book.title)-highlights.md"
        )
        showingExportSheet = true
    }

    private func exportToJSON() {
        let json = generateJSON()
        exportDocument = HighlightsExportDocument(
            content: json,
            contentType: .json,
            filename: "\(book.title)-highlights.json"
        )
        showingExportSheet = true
    }

    private func copyToClipboard() {
        let markdown = generateMarkdown()
        UIPasteboard.general.string = markdown
    }

    private func generateMarkdown() -> String {
        var output = "# Highlights from \(book.title)\n\n"
        output += "By \(book.authorDisplay)\n\n"
        output += "Exported on \(Date().formatted(date: .long, time: .shortened))\n\n"
        output += "---\n\n"

        // Group by chapter
        let grouped = Dictionary(grouping: filteredHighlights) { $0.chapterIndex }
        let sortedKeys = grouped.keys.sorted()

        for chapterIndex in sortedKeys {
            guard let highlights = grouped[chapterIndex] else { continue }

            if let chapter = book.chapters.first(where: { $0.order == chapterIndex }) {
                output += "## \(chapter.title)\n\n"
            } else {
                output += "## Chapter \(chapterIndex + 1)\n\n"
            }

            for highlight in highlights.sorted(by: { $0.startOffset < $1.startOffset }) {
                output += "> \(highlight.selectedText)\n\n"

                for analysis in highlight.analyses {
                    output += "**\(analysis.analysisType.displayName):**\n"
                    output += "\(analysis.response)\n\n"
                }

                if let note = highlight.note, !note.isEmpty {
                    output += "*Note: \(note)*\n\n"
                }

                output += "---\n\n"
            }
        }

        return output
    }

    private func generateJSON() -> String {
        let highlights = filteredHighlights.map { highlight -> [String: Any] in
            [
                "id": highlight.id.uuidString,
                "text": highlight.selectedText,
                "chapterIndex": highlight.chapterIndex,
                "createdAt": ISO8601DateFormatter().string(from: highlight.createdAt),
                "note": highlight.note ?? "",
                "analyses": highlight.analyses.map { analysis in
                    [
                        "type": analysis.analysisType.rawValue,
                        "response": analysis.response,
                        "createdAt": ISO8601DateFormatter().string(from: analysis.createdAt)
                    ]
                }
            ]
        }

        let data: [String: Any] = [
            "book": [
                "title": book.title,
                "author": book.authorDisplay
            ],
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "highlights": highlights
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }

        return "{}"
    }
}

// MARK: - Filter Chip
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? color.opacity(0.2) : Color.clear)
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? color : color.opacity(0.3), lineWidth: 1)
                )
                .foregroundStyle(isSelected ? color : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Highlight Row
/// Styled to match Reader's chapterHighlightRow in AnalysisPanelView
struct HighlightRow: View {
    let highlight: HighlightModel
    let settings: SettingsManager

    private var highlightColor: Color {
        Color(hex: highlight.colorHex ?? "#FFEB3B") ?? .yellow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Text
            Text(highlight.selectedText)
                .font(.subheadline)
                .foregroundStyle(settings.theme.textColor)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            // Metadata
            HStack(spacing: 8) {
                // Analysis Types + Count
                if !highlight.analyses.isEmpty {
                    HStack(spacing: 6) {
                        // Type icons (unique types only)
                        HStack(spacing: 4) {
                            ForEach(Array(Set(highlight.analyses.map(\.analysisType))), id: \.self) { type in
                                Image(systemName: type.iconName)
                                    .font(.caption2)
                                    .foregroundStyle(Color(hex: type.colorHex) ?? .secondary)
                            }
                        }

                        // Analysis count badge - shows total number of analysis threads
                        Text("\(highlight.analyses.count)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(highlightColor)
                            )
                    }
                } else {
                    Text("No analysis yet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Date
                Text(highlight.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(highlightColor.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(highlightColor.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Highlight Detail Sheet
/// Shows all analyses for a single highlight in a sheet with full analysis capabilities
/// Supports: new analyses, follow-up questions, streaming display
/// Works independently of ReaderViewModel via HighlightAnalysisManager
struct HighlightDetailSheet: View {
    let highlight: HighlightModel
    let book: BookModel

    @Environment(SettingsManager.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Analysis manager - handles all analysis operations for this highlight
    @State private var manager: HighlightAnalysisManager?

    /// Follow-up question text field
    @State private var followUpQuestion = ""
    @FocusState private var isQuestionFocused: Bool

    private var chapterTitle: String {
        book.chapters.first(where: { $0.order == highlight.chapterIndex })?.title
            ?? "Chapter \(highlight.chapterIndex + 1)"
    }

    // MARK: - Markdown Text Helper
    /// Renders markdown text with fallback to plain text if parsing fails
    /// Aligned with AnalysisPanelView's markdownText() helper
    private func markdownText(_ string: String) -> Text {
        if let attributed = try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        } else {
            return Text(string)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Scroll anchor at the top - enables programmatic scrolling
                            Color.clear
                                .frame(height: 0)
                                .id("detail-top")

                            // Highlighted text with analysis type buttons
                            highlightTextSection

                            Divider()

                            // Analyses content
                            analysisContentSection
                        }
                        .padding()
                    }
                    .onChange(of: manager?.selectedAnalysis?.id) { _, _ in
                        scrollToTop(proxy)
                    }
                    .onChange(of: manager?.isAnalyzing) { wasAnalyzing, isAnalyzing in
                        // Scroll to top when starting a new analysis
                        if isAnalyzing == true && wasAnalyzing != true {
                            scrollToTop(proxy)
                        }
                    }
                }

                // Follow-up input section (always visible when manager exists)
                if manager != nil {
                    followUpInputSection
                }
            }
            .background(settings.theme.backgroundColor)
            .navigationTitle("Highlight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                if manager?.selectedAnalysis != nil || manager?.isAnalyzing == true {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                manager?.selectedAnalysis = nil
                                manager?.analysisResult = nil
                                manager?.isAnalyzing = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                        }
                    }
                }
            }
            .onAppear {
                // Initialize manager when sheet appears
                manager = HighlightAnalysisManager(highlight: highlight, modelContext: modelContext)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo("detail-top", anchor: .top)
        }
    }

    // MARK: - Highlight Text Section
    /// Color for the quote block - uses current analysis type color when viewing an analysis,
    /// otherwise uses the highlight's original color
    private var currentDisplayColor: Color {
        if let type = manager?.currentAnalysisType {
            return Color(hex: type.colorHex) ?? .blue
        }
        if let analysis = manager?.selectedAnalysis {
            return Color(hex: analysis.analysisType.colorHex) ?? .blue
        }
        return Color(hex: highlight.colorHex ?? "#FFEB3B") ?? .yellow
    }

    private var highlightTextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Chapter info
            HStack {
                Text(chapterTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                // Show current analysis type indicator when selected or analyzing
                if let type = manager?.currentAnalysisType {
                    HStack(spacing: 4) {
                        Image(systemName: type.iconName)
                            .font(.caption2)
                        Text(type.displayName)
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(currentDisplayColor)
                }
            }

            // Highlighted text with dynamic color that syncs with current analysis
            // Uses colored tint + border to match Reader's styling pattern
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(currentDisplayColor)
                    .frame(width: 4)

                Text(highlight.selectedText)
                    .font(.body)
                    .foregroundStyle(settings.theme.textColor)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(currentDisplayColor.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(currentDisplayColor.opacity(0.3), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.2), value: manager?.selectedAnalysis?.id)
            .animation(.easeInOut(duration: 0.2), value: manager?.currentAnalysisType)

            // Analysis type buttons - enables creating new analyses from library view
            analysisTypeButtonsSection

            // Date
            Text(highlight.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Analysis Type Buttons
    /// Shows all quick analysis types + custom question option
    private var analysisTypeButtonsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // All quick analysis types (Fact Check, Discussion, Key Points, Argument Map, Counterpoints)
                ForEach(AnalysisType.quickAnalysisTypes, id: \.self) { type in
                    analysisTypeButton(type)
                }

                // Custom Question button - creates NEW custom question thread
                // Prepares UI for fresh question and blocks ongoing jobs from updating display
                Button {
                    manager?.prepareForNewCustomQuestion()
                    isQuestionFocused = true
                } label: {
                    Label("Ask Question", systemImage: AnalysisType.customQuestion.iconName)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color(hex: AnalysisType.customQuestion.colorHex)?.opacity(0.2) ?? settings.theme.accentColor.opacity(0.2))
                        )
                        .foregroundStyle(Color(hex: AnalysisType.customQuestion.colorHex) ?? settings.theme.accentColor)
                }
                .buttonStyle(.plain)
                // No .disabled - allow starting new custom question even during streaming
                // This enables parallel job workflow: user can initiate new question anytime
            }
        }
    }

    private func analysisTypeButton(_ type: AnalysisType) -> some View {
        Button {
            manager?.performAnalysis(type: type)
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
        // No .disabled - allow parallel jobs (e.g., run Key Points while streaming Fact Check)
    }

    // MARK: - Analysis Content Section
    @ViewBuilder
    private var analysisContentSection: some View {
        if manager?.isAnalyzing == true {
            // Streaming/loading state
            streamingAnalysisView
        } else if let analysis = manager?.selectedAnalysis {
            // Show selected analysis with conversation
            expandedAnalysisView(analysis)
        } else if highlight.analyses.isEmpty {
            // No analyses yet
            noAnalysesView
        } else {
            // Show analysis cards list
            analysisCardsSection
        }
    }

    // MARK: - Streaming Analysis View
    /// Shows streaming content with full conversation context
    private var streamingAnalysisView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Show the analysis type header
            if let type = manager?.currentAnalysisType {
                Label(type.displayName, systemImage: type.iconName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(hex: type.colorHex) ?? settings.theme.accentColor)
            }

            // If following up on existing analysis, show the prior context first
            if let analysis = manager?.selectedAnalysis {
                // Show the original analysis content
                if analysis.analysisType == .customQuestion {
                    // Custom question: show original Q&A in bubbles
                    userMessageBubble(analysis.prompt)
                    aiMessageBubble(analysis.response)
                } else if analysis.analysisType == .comment {
                    // Comment: show user's note (no initial AI response)
                    commentBubble(analysis.prompt)
                    if !analysis.response.isEmpty {
                        aiMessageBubble(analysis.response)
                    }
                } else {
                    // Other types: show the analysis result
                    markdownText(analysis.response)
                        .font(.subheadline)
                        .foregroundStyle(settings.theme.textColor)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(settings.theme.secondaryBackgroundColor.opacity(0.5))
                        )
                }

                // Show existing thread turns
                if let thread = analysis.thread, !thread.turns.isEmpty {
                    // Show separator for non-bubble analyses
                    if analysis.analysisType != .customQuestion && analysis.analysisType != .comment {
                        followUpsDivider
                    }
                    ForEach(thread.turns.sorted(by: { $0.turnIndex < $1.turnIndex })) { turn in
                        userMessageBubble(turn.question)
                        aiMessageBubble(turn.answer)
                    }
                }

                // Show separator before new follow-up if needed (for non-bubble types)
                if analysis.analysisType != .customQuestion && analysis.analysisType != .comment && (analysis.thread?.turns.isEmpty ?? true) {
                    followUpsDivider
                }
            }

            // Show the current question being asked
            if let question = manager?.currentQuestion, !question.isEmpty {
                userMessageBubble(question)
            }

            // Show streaming response or thinking indicator
            if let result = manager?.analysisResult, !result.isEmpty {
                aiMessageBubble(result, isStreaming: true)
            } else {
                thinkingBubble
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(settings.theme.backgroundColor)
        )
    }

    // MARK: - Chat Bubble Components
    /// User message bubble - right-aligned with accent color
    private func userMessageBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(settings.theme.accentColor)
                )
        }
    }

    /// AI message bubble - left-aligned with secondary background
    private func aiMessageBubble(_ text: String, isStreaming: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                markdownText(text)
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.textColor)
                    .textSelection(.enabled)

                if isStreaming {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Thinking...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(settings.theme.secondaryBackgroundColor)
            )
            Spacer(minLength: 40)
        }
    }

    /// Comment bubble - right-aligned with comment color (distinct from user questions)
    /// Shows the user's personal note/comment on the highlighted text
    private func commentBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(hex: AnalysisType.comment.colorHex) ?? settings.theme.accentColor)
            )
        }
    }

    /// Thinking indicator bubble - shown when AI is processing but no output yet
    private var thinkingBubble: some View {
        HStack {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Thinking...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(settings.theme.secondaryBackgroundColor)
            )
            Spacer(minLength: 40)
        }
    }

    /// Visual separator for follow-ups section
    private var followUpsDivider: some View {
        HStack {
            VStack { Divider() }
            Text("Follow-ups")
                .font(.caption2)
                .foregroundStyle(.secondary)
            VStack { Divider() }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Analysis Cards Section
    private var analysisCardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Analyses (\(highlight.analyses.count))")
                .font(.headline)
                .foregroundStyle(settings.theme.textColor)

            ForEach(highlight.analyses.sorted(by: { $0.createdAt > $1.createdAt })) { analysis in
                AnalysisCard(analysis: analysis, settings: settings) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        manager?.selectAnalysis(analysis)
                    }
                }
            }
        }
    }

    // MARK: - Expanded Analysis View
    /// Shows analysis content with conversation thread
    /// For custom questions: displays as conversation bubbles
    /// For comments: displays comment bubble (user's note, no initial AI response)
    /// For other types: displays analysis result, then any follow-up bubbles
    private func expandedAnalysisView(_ analysis: AIAnalysisModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Initial content depends on analysis type
            if analysis.analysisType == .customQuestion {
                // Custom questions: show initial Q&A as chat bubbles
                userMessageBubble(analysis.prompt)
                aiMessageBubble(analysis.response)
            } else if analysis.analysisType == .comment {
                // Comments: show user's note as comment bubble (no initial AI response)
                commentBubble(analysis.prompt)
                // If response is not empty (shouldn't happen for new comments), show it
                if !analysis.response.isEmpty {
                    aiMessageBubble(analysis.response)
                }
            } else {
                // Other types (Fact Check, Discussion, etc.): show the analysis result
                VStack(alignment: .leading, spacing: 10) {
                    markdownText(analysis.response)
                        .font(.body)
                        .foregroundStyle(settings.theme.textColor)
                        .textSelection(.enabled)

                    // Analysis creation date (subtle)
                    Text(analysis.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(settings.theme.secondaryBackgroundColor)
                )
            }

            // Thread turns (follow-up Q&A) - chat bubble style
            if let thread = analysis.thread, !thread.turns.isEmpty {
                // Show separator for non-bubble analyses (not custom question or comment)
                if analysis.analysisType != .customQuestion && analysis.analysisType != .comment {
                    followUpsDivider
                }

                ForEach(thread.turns.sorted(by: { $0.turnIndex < $1.turnIndex })) { turn in
                    userMessageBubble(turn.question)
                    aiMessageBubble(turn.answer)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(settings.theme.backgroundColor)
        )
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
                    if !followUpQuestion.isEmpty {
                        manager?.askFollowUpQuestion(followUpQuestion)
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
                .disabled(followUpQuestion.isEmpty || manager?.isAnalyzing == true)
            }
            .padding(12)
            .background(settings.theme.secondaryBackgroundColor)
        }
    }

    // MARK: - No Analyses View
    private var noAnalysesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.largeTitle)
                .foregroundStyle(
                    LinearGradient(
                        colors: [settings.theme.accentColor.opacity(0.6), settings.theme.accentColor.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("No Analyses Yet")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Tap an analysis type above to get started!")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Analysis Card (for list view)
/// Styled with colored tint + border to match Reader's highlight cards
struct AnalysisCard: View {
    let analysis: AIAnalysisModel
    let settings: SettingsManager
    let onTap: () -> Void

    private var typeColor: Color {
        Color(hex: analysis.analysisType.colorHex) ?? .blue
    }

    /// Renders markdown text with fallback - aligned with HighlightDetailSheet
    private func analysisPreviewText(_ string: String) -> Text {
        if let attributed = try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        } else {
            return Text(string)
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack {
                    Image(systemName: analysis.analysisType.iconName)
                        .font(.subheadline)
                        .foregroundStyle(typeColor)

                    Text(analysis.analysisType.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(settings.theme.textColor)

                    Spacer()

                    // Thread count badge if has follow-ups
                    if let thread = analysis.thread, !thread.turns.isEmpty {
                        Text("\(thread.turns.count)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(typeColor)
                            )
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Preview of content (with markdown support)
                // Comments: show prompt (user's text), Others: show response (AI result)
                analysisPreviewText(analysis.analysisType == .comment ? analysis.prompt : analysis.response)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(typeColor.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(typeColor.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Export Document
struct HighlightsExportDocument: FileDocument {
    let content: String
    let contentType: UTType
    let filename: String

    static var readableContentTypes: [UTType] { [.plainText, .json] }

    init(content: String, contentType: UTType, filename: String) {
        self.content = content
        self.contentType = contentType
        self.filename = filename
    }

    init(configuration: ReadConfiguration) throws {
        content = ""
        contentType = .plainText
        filename = "highlights"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = content.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
    }
}

#Preview {
    HighlightsView(book: BookModel(title: "Sample Book", authors: ["Author"]))
        .environment(SettingsManager())
        .modelContainer(for: BookModel.self)
}
