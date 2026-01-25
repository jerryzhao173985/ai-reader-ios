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
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteHighlight(highlight)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
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
struct HighlightRow: View {
    let highlight: HighlightModel
    let settings: SettingsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Text
            Text(highlight.selectedText)
                .font(.subheadline)
                .foregroundStyle(settings.theme.textColor)
                .lineLimit(3)

            // Metadata
            HStack {
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
                                    .fill(Color(hex: highlight.colorHex ?? "#888888") ?? .gray)
                            )
                    }
                }

                Spacer()

                // Date
                Text(highlight.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: highlight.colorHex ?? "#ffff00")?.opacity(0.1) ?? Color.yellow.opacity(0.1))
        )
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
