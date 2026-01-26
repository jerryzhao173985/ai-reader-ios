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
/// Shows all analyses for a single highlight in a sheet
/// Mirrors AnalysisPanelView behavior but without reader context
struct HighlightDetailSheet: View {
    let highlight: HighlightModel
    let book: BookModel

    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// Currently expanded analysis (nil = show list)
    @State private var expandedAnalysis: AIAnalysisModel?

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
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Scroll anchor at the top - enables programmatic scrolling
                        Color.clear
                            .frame(height: 0)
                            .id("detail-top")

                        // Highlighted text
                        highlightTextSection

                        Divider()

                        // Analyses
                        if highlight.analyses.isEmpty {
                            noAnalysesView
                        } else if let analysis = expandedAnalysis {
                            // Show expanded analysis
                            expandedAnalysisView(analysis)
                        } else {
                            // Show analysis cards list
                            analysisCardsSection
                        }
                    }
                    .padding()
                }
                .onChange(of: expandedAnalysis) { _, _ in
                    // When expanding or collapsing an analysis, scroll to top instantly
                    // No animation prevents jarring visual jump
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo("detail-top", anchor: .top)
                    }
                }
                .onAppear {
                    // Reset scroll position when sheet first appears
                    // This prevents iOS from preserving scroll position from previous sheet presentations
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo("detail-top", anchor: .top)
                    }
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

                if expandedAnalysis != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedAnalysis = nil
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
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Highlight Text Section
    /// Color for the quote block - uses expanded analysis type color when viewing an analysis,
    /// otherwise uses the highlight's original color
    private var currentDisplayColor: Color {
        if let analysis = expandedAnalysis {
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

                // Show current analysis type indicator when expanded
                if let analysis = expandedAnalysis {
                    HStack(spacing: 4) {
                        Image(systemName: analysis.analysisType.iconName)
                            .font(.caption2)
                        Text(analysis.analysisType.displayName)
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
            .animation(.easeInOut(duration: 0.2), value: expandedAnalysis?.id)

            // Date
            Text(highlight.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
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
                        expandedAnalysis = analysis
                    }
                }
            }
        }
    }

    // MARK: - Expanded Analysis View
    /// Shows analysis content directly - type info is already shown in quote header
    private func expandedAnalysisView(_ analysis: AIAnalysisModel) -> some View {
        let typeColor = Color(hex: analysis.analysisType.colorHex) ?? .blue

        return VStack(alignment: .leading, spacing: 16) {
            // Analysis response - primary content (type already shown in quote header)
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

            // Thread turns (follow-up Q&A) - chat bubble style
            if let thread = analysis.thread, !thread.turns.isEmpty {
                // Section header
                HStack {
                    VStack { Divider() }
                    Text("Follow-up Q&A")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    VStack { Divider() }
                }
                .padding(.vertical, 4)

                ForEach(thread.turns.sorted(by: { $0.turnIndex < $1.turnIndex })) { turn in
                    VStack(alignment: .leading, spacing: 10) {
                        // User question - right-aligned with "You" label
                        HStack(alignment: .top) {
                            Spacer(minLength: 50)
                            VStack(alignment: .trailing, spacing: 4) {
                                HStack(spacing: 4) {
                                    Text("You")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.white.opacity(0.8))
                                    Image(systemName: "person.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                                Text(turn.question)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(settings.theme.accentColor)
                            )
                        }

                        // AI answer - left-aligned with "AI" label
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                        .font(.caption2)
                                        .foregroundStyle(typeColor)
                                    Text("AI")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(typeColor)
                                }
                                markdownText(turn.answer)
                                    .font(.subheadline)
                                    .foregroundStyle(settings.theme.textColor)
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(settings.theme.secondaryBackgroundColor)
                            )
                            Spacer(minLength: 50)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - No Analyses View
    private var noAnalysesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)

            Text("No Analyses Yet")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Open this highlight in the reader to add analyses.")
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

                // Preview of response (with markdown support)
                analysisPreviewText(analysis.response)
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
