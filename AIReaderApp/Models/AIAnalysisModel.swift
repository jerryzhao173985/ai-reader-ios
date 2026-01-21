// AIAnalysisModel.swift
// SwiftData model for AI-generated analyses
//
// Stores analysis responses from OpenAI with threading support for conversations

import Foundation
import SwiftData

// MARK: - Analysis Types (matching web app)
enum AnalysisType: String, Codable, CaseIterable, Identifiable {
    case factCheck = "fact_check"
    case discussion = "discussion"
    case keyPoints = "key_points"
    case argumentMap = "argument_map"
    case counterpoints = "counterpoints"
    case customQuestion = "custom_question"
    case comment = "comment"

    var id: String { rawValue }

    /// Analysis types that can be run immediately without user input
    /// Excludes customQuestion (needs question text) and comment (needs comment text)
    static var quickAnalysisTypes: [AnalysisType] {
        [.factCheck, .discussion, .keyPoints, .argumentMap, .counterpoints]
    }

    var displayName: String {
        switch self {
        case .factCheck: return "Fact Check"
        case .discussion: return "Discussion"
        case .keyPoints: return "Key Points"
        case .argumentMap: return "Argument Map"
        case .counterpoints: return "Counterpoints"
        case .customQuestion: return "Custom Question"
        case .comment: return "Comment"
        }
    }

    var icon: String {
        switch self {
        case .factCheck: return "checkmark.circle"
        case .discussion: return "bubble.left.and.bubble.right"
        case .keyPoints: return "list.bullet"
        case .argumentMap: return "arrow.triangle.branch"
        case .counterpoints: return "arrow.left.arrow.right"
        case .customQuestion: return "questionmark.circle"
        case .comment: return "pencil"
        }
    }

    var colorHex: String {
        switch self {
        case .factCheck: return "#4CAF50"      // Green
        case .discussion: return "#2196F3"     // Blue
        case .keyPoints: return "#FF9800"      // Orange
        case .argumentMap: return "#9C27B0"    // Purple
        case .counterpoints: return "#F44336"  // Red
        case .customQuestion: return "#00BCD4" // Cyan
        case .comment: return "#FFEB3B"        // Yellow
        }
    }
}

@Model
final class AIAnalysisModel {
    // MARK: - Identifiers
    @Attribute(.unique) var id: UUID
    var highlight: HighlightModel?

    // MARK: - Analysis Content
    var analysisTypeRaw: String  // Store as String for SwiftData
    var prompt: String
    var response: String

    // MARK: - Threading for Conversations
    @Relationship(deleteRule: .cascade, inverse: \AnalysisThreadModel.analysis)
    var thread: AnalysisThreadModel?

    // MARK: - Timestamps
    var createdAt: Date

    // MARK: - Computed Properties
    var analysisType: AnalysisType {
        get { AnalysisType(rawValue: analysisTypeRaw) ?? .comment }
        set { analysisTypeRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        analysisType: AnalysisType,
        prompt: String,
        response: String
    ) {
        self.id = id
        self.analysisTypeRaw = analysisType.rawValue
        self.prompt = prompt
        self.response = response
        self.createdAt = Date()
    }
}

// MARK: - Analysis Thread (for multi-turn conversations)
@Model
final class AnalysisThreadModel {
    @Attribute(.unique) var id: UUID
    var analysis: AIAnalysisModel?

    @Relationship(deleteRule: .cascade, inverse: \AnalysisTurnModel.thread)
    var turns: [AnalysisTurnModel]

    var createdAt: Date

    init(id: UUID = UUID()) {
        self.id = id
        self.turns = []
        self.createdAt = Date()
    }
}

// MARK: - Analysis Turn (individual Q&A in a thread)
@Model
final class AnalysisTurnModel {
    @Attribute(.unique) var id: UUID
    var thread: AnalysisThreadModel?

    var question: String
    var answer: String
    var turnIndex: Int

    var createdAt: Date

    init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        turnIndex: Int
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.turnIndex = turnIndex
        self.createdAt = Date()
    }
}
