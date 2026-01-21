// HighlightModel.swift
// SwiftData model for user highlights with AI analyses
//
// Stores selected text passages with context and associated AI analyses

import Foundation
import SwiftData

@Model
final class HighlightModel {
    // MARK: - Identifiers
    @Attribute(.unique) var id: UUID
    var book: BookModel?
    var chapterIndex: Int

    // MARK: - Text Content
    var selectedText: String
    var contextBefore: String
    var contextAfter: String

    // MARK: - Position Tracking
    var startOffset: Int
    var endOffset: Int

    // MARK: - Visual Style
    var colorHex: String  // Color based on analysis type

    // MARK: - User Notes
    var note: String?  // Optional user-added note

    // MARK: - Relationships
    @Relationship(deleteRule: .cascade, inverse: \AIAnalysisModel.highlight)
    var analyses: [AIAnalysisModel]

    // MARK: - Timestamps
    var createdAt: Date

    // MARK: - Computed Properties
    var fullContext: String {
        "\(contextBefore)\(selectedText)\(contextAfter)"
    }

    var primaryAnalysisType: AnalysisType? {
        analyses.first?.analysisType
    }

    init(
        id: UUID = UUID(),
        chapterIndex: Int,
        selectedText: String,
        contextBefore: String = "",
        contextAfter: String = "",
        startOffset: Int = 0,
        endOffset: Int = 0,
        colorHex: String = "#FFEB3B"
    ) {
        self.id = id
        self.chapterIndex = chapterIndex
        self.selectedText = selectedText
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.colorHex = colorHex
        self.analyses = []
        self.createdAt = Date()
    }
}
